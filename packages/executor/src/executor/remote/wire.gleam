//// Closed protocol-067 execution envelopes over pinned mTLS, never Erlang terms.
////
//// An envelope is [1, schema, role, owner, executor, generation, scope, body].
//// Schema is an exact revision string; role is 0 owner or 1 executor. Scope is
//// journal_codec's canonical administrative binding, compared before decoding
//// commands. The configured TLS leaf pin authenticates the configured label.
//// Generation is positive, bounded, and fences mutation independently of keys.
//// Body tags: 0 hello(native proto 3/policy 2), 1 challenge request(key),
//// 2 challenge(key,nonce,W), 3 submit(key,prepared,nonce,B), 4 query(key,cursor),
//// 5 stdin(key,ordinal,data,eof), 6 cancel(key), 7 receipt(key,result digest),
//// 8 close scope, 9 evidence(key,phase,deadline), 10 output(key,ordinal,bytes),
//// 11 terminal(key,bytes), 12 retirement, 13 rejected(reason).
//// Keys encode journal_codec.Admit and bind full request digest. Prepared is
//// [step,registration digest,lifetime,demand,native ExecStart payload,stream]. Finite
//// lifetime carries original ceiling milliseconds; session lifetime is explicit.
//// Native materialization is exact, including token, policy, argv and env. The
//// registration adapter must validate it before admission and again at launch.
//// Native helper frames use the existing total broker decoder, after a stricter
//// bounded-msgpack preflight: depth 16, 2048 nodes, arrays/maps 128 entries,
//// strings 8192 bytes, binary 128 KiB, total frame 256 KiB. Stdin is 8 KiB;
//// output payloads 16 KiB; terminal 32 KiB. Unknown/extra fields fail closed.

import broker/dispatch
import broker/exec
import broker/framing
import core/msgpack as mp
import core/workspace
import executor/remote/identity
import executor/remote/journal_codec as codec
import executor/remote/tls
import gleam/bit_array
import gleam/crypto
import gleam/list
import gleam/option.{None, Some}
import gleam/result

/// The exact schema revision exchanged before any mutation.
pub const schema = "loom.remote.native/1"

/// Authenticated administrative endpoint role.
pub type Role {
  /// The owner retains approval and pooled budget authority.
  Owner

  /// The executor owns physical native resources.
  Executor
}

/// Original authority, independent of attempt authorization and clock offsets.
pub type Lifetime {
  /// A finite original operation ceiling in milliseconds.
  Finite(
    /// The original finite resource authority, independent of attempt budget.
    ceiling_ms: Int,
  )

  /// Explicit disconnected session authority under the scope's original epochs.
  Session
}

/// Exact materialized command already cleared beside the registered executor.
pub type StreamPolicy {
  /// Ordinary logs preserve the helper's explicit truncation flags.
  Logs

  /// Protocol bytes are indivisible; any truncation breaks the stream.
  ProtocolStream
}

/// Exact materialized command already cleared beside the registered executor.
pub type Prepared {
  /// Fields are revalidated against the configured registration at native launch.
  Prepared(
    /// The exact cleared step, validated before remote admission.
    step: String,
    /// Digest of the administrative region/toolchain registration contract.
    registration: identity.Digest,
    /// Original finite or explicit session authority, unchanged on reconnect.
    lifetime: Lifetime,
    /// The exact already-prepared broker-cleared argv/environment/policy/token.
    request: exec.ExecRequest,
    /// Ordinary log truncation or fatal loss of structured protocol bytes.
    stream: StreamPolicy,
  )
}

/// Closed owner commands and executor observations. No remote closures or atoms.
pub type Body {
  /// Version handshake with native helper and policy versions.
  Hello

  /// Obtain single-use authorization for the exact logical content.
  ChallengeRequest(
    /// The original durably reserved logical request identity.
    key: identity.RequestKey,
    /// The SHA-256 evidence binding the complete immutable request.
    digest: identity.Digest,
  )

  /// A nonce expires on the executor's independent monotonic clock.
  Challenge(
    /// The original durably reserved logical request identity.
    key: identity.RequestKey,
    /// The SHA-256 evidence binding the complete immutable request.
    digest: identity.Digest,
    /// Exactly 32 single-use challenge bytes, or the explicit session sentinel.
    nonce: BitArray,
    /// The conservative 1000 ms executor-local challenge window.
    window_ms: Int,
  )

  /// Submit exact cleared materialization with an attempt budget.
  Submit(
    /// The original durably reserved logical request identity.
    key: identity.RequestKey,
    /// The SHA-256 evidence binding the complete immutable request.
    digest: identity.Digest,
    /// The exact command materialized beside the registered executor.
    prepared: Prepared,
    /// Exactly 32 single-use challenge bytes, or the explicit session sentinel.
    nonce: BitArray,
    /// Attempt duration after charging the challenge window and timer margin.
    budget_ms: Int,
  )

  /// Read retained evidence beginning at a bounded output cursor.
  Query(
    /// The original durably reserved logical request identity.
    key: identity.RequestKey,
    /// The SHA-256 evidence binding the complete immutable request.
    digest: identity.Digest,
    /// The next retained output ordinal in 0..64.
    cursor: Int,
  )

  /// Idempotent ordered bounded stdin; cumulative service bound is 1 MiB.
  Stdin(
    /// The original durably reserved logical request identity.
    key: identity.RequestKey,
    /// The SHA-256 evidence binding the complete immutable request.
    digest: identity.Digest,
    /// The bounded ordered item number, never a new logical request identity.
    ordinal: Int,
    /// Exact immutable encoded bytes, validated under the per-kind limit.
    bytes: BitArray,
    /// Whether this item permanently closes the native input stream.
    eof: dispatch.Eof,
  )

  /// Local native cancellation is independent of network delivery.
  Cancel(
    /// The original durably reserved logical request identity.
    key: identity.RequestKey,
    /// The SHA-256 evidence binding the complete immutable request.
    digest: identity.Digest,
  )

  /// The owner has durably committed the exact terminal bytes.
  DurableReceipt(
    /// The original durably reserved logical request identity.
    key: identity.RequestKey,
    /// The SHA-256 evidence binding the complete immutable request.
    digest: identity.Digest,
    /// The exact result digest or terminal persistence callback, as typed here.
    terminal: identity.Digest,
  )

  /// Permanently fence authority and request witnessed scoped native drain.
  CloseScope

  /// A phase code and first admission's frozen local deadline; zero is session.
  Evidence(
    /// The original durably reserved logical request identity.
    key: identity.RequestKey,
    /// The SHA-256 evidence binding the complete immutable request.
    digest: identity.Digest,
    /// The retained admission phase; it grants no new launch permission.
    phase: Int,
    /// The original frozen local monotonic deadline; zero requires Session.
    deadline_ms: Int,
  )

  /// Exact retained native output bytes at one ordinal.
  Output(
    /// The original durably reserved logical request identity.
    key: identity.RequestKey,
    /// The SHA-256 evidence binding the complete immutable request.
    digest: identity.Digest,
    /// The bounded ordered item number, never a new logical request identity.
    ordinal: Int,
    /// Exact immutable encoded bytes, validated under the per-kind limit.
    bytes: BitArray,
  )

  /// Exact terminal payload retained before advertisement.
  Terminal(
    /// The original durably reserved logical request identity.
    key: identity.RequestKey,
    /// The SHA-256 evidence binding the complete immutable request.
    digest: identity.Digest,
    /// Exact immutable encoded bytes, validated under the per-kind limit.
    bytes: BitArray,
  )

  /// Scoped native pool witnessed drain, separately from terminal exit.
  ScopeRetirement

  /// Fixed bounded error code with no peer-controlled diagnostic reflection.
  Rejected(
    /// A fixed error code that reflects no peer-controlled diagnostic text.
    reason: Int,
  )
}

/// An authenticated transport generation carrying one closed body.
pub type Envelope {
  /// Labels are configuration, never peer-asserted enrollment.
  Envelope(
    /// The authenticated owner or executor role expected at this boundary.
    role: Role,
    /// The provisioned owner label bound to the pinned peer certificate.
    owner: String,
    /// The provisioned executor label from the administrative scope.
    executor: String,
    /// The current monotone transport generation, separate from request identity.
    generation: Int,
    /// The exact session/workspace binding and original authority epochs.
    scope: identity.Scope,
    /// One closed role-specific command or immutable evidence observation.
    body: Body,
  )
}

/// Unsupported versions, roles, shapes or resource bounds.
pub type Error {
  /// Fail before admission or native mutation.
  Invalid
}

/// Encodes and validates a closed envelope under the TLS frame ceiling.
///
/// ## Examples
///
/// ```gleam
/// wire.encode(envelope) // -> bounded canonical msgpack.
/// ```
pub fn encode(envelope: Envelope) -> Result(BitArray, Error) {
  use body <- result.try(body_value(envelope.body))
  pack(
    mp.ArrayValue([
      mp.IntValue(1),
      mp.StringValue(schema),
      mp.IntValue(role_code(envelope.role)),
      mp.StringValue(envelope.owner),
      mp.StringValue(envelope.executor),
      mp.IntValue(envelope.generation),
      mp.BinaryValue(codec.binding(envelope.scope)),
      body,
    ]),
  )
}

/// Decodes against authenticated configuration, including exact scope and role.
/// It compares version/schema/labels before exposing any command to the service.
///
/// ## Examples
///
/// ```gleam
/// wire.decode(bytes, role, owner, executor, scope)
/// ```
pub fn decode(
  bytes: BitArray,
  role: Role,
  owner: String,
  executor: String,
  scope: identity.Scope,
) -> Result(Envelope, Error) {
  use value <- result.try(unpack(bytes))
  use fields <- result.try(case value {
    mp.ArrayValue([
      mp.IntValue(1),
      mp.StringValue(version),
      mp.IntValue(role_id),
      mp.StringValue(owner_id),
      mp.StringValue(executor_id),
      mp.IntValue(generation),
      mp.BinaryValue(binding),
      body,
    ])
      if version == schema
      && owner_id == owner
      && executor_id == executor
      && generation > 0
      && generation <= 2_147_483_647
    -> Ok(#(role_id, generation, binding, body))
    _ -> Error(Invalid)
  })
  let #(role_id, generation, binding, body) = fields
  use Nil <- result.try(
    case role_id == role_code(role) && binding == codec.binding(scope) {
      True -> Ok(Nil)
      False -> Error(Invalid)
    },
  )
  use body <- result.try(decode_body(body, scope))
  use Nil <- result.try(validate_body(body))
  use Nil <- result.try(case allowed(role, body) {
    True -> Ok(Nil)
    False -> Error(Invalid)
  })
  Ok(Envelope(role, owner, executor, generation, scope, body))
}

/// Computes content evidence over exact canonical prepared materialization.
/// Attempt nonce and remaining budget are deliberately excluded.
///
/// ## Examples
///
/// ```gleam
/// wire.prepared_digest(prepared) // -> exact policy/request evidence.
/// ```
pub fn prepared_digest(prepared: Prepared) -> Result(identity.Digest, Error) {
  use bytes <- result.try(encode_prepared(prepared))
  digest(bytes)
}

/// Hashes exact payload bytes using the installed SHA-256 implementation.
///
/// ## Examples
///
/// ```gleam
/// wire.digest(bytes) // -> a 32-byte evidence value.
/// ```
pub fn digest(bytes: BitArray) -> Result(identity.Digest, Error) {
  identity.digest(crypto.hash(crypto.Sha256, bytes))
  |> result.map_error(fn(_) { Invalid })
}

/// Encodes exact immutable request bytes for durable custody and recovery.
///
/// ## Examples
///
/// ```gleam
/// wire.encode_prepared(prepared)
/// ```
pub fn encode_prepared(prepared: Prepared) -> Result(BitArray, Error) {
  use value <- result.try(prepared_value(prepared))
  use bytes <- result.try(pack(value))
  use Nil <- result.try(case bit_array.byte_size(bytes) <= 131_072 {
    True -> Ok(Nil)
    False -> Error(Invalid)
  })
  Ok(bytes)
}

/// Recovers the original request through bounded decoders.
///
/// ## Examples
///
/// ```gleam
/// wire.decode_prepared(bytes)
/// ```
pub fn decode_prepared(bytes: BitArray) -> Result(Prepared, Error) {
  use value <- result.try(unpack(bytes))
  decode_prepared_value(value)
}

fn role_code(role: Role) -> Int {
  case role {
    Owner -> 0
    Executor -> 1
  }
}

fn allowed(role: Role, body: Body) -> Bool {
  case role, body {
    _, Hello -> True
    Owner, ChallengeRequest(_, _)
    | Owner, Submit(_, _, _, _, _)
    | Owner, Query(_, _, _)
    | Owner, Stdin(_, _, _, _, _)
    | Owner, Cancel(_, _)
    | Owner, DurableReceipt(_, _, _)
    | Owner, CloseScope
    -> True
    Executor, Challenge(_, _, _, _)
    | Executor, Evidence(_, _, _, _)
    | Executor, Output(_, _, _, _)
    | Executor, Terminal(_, _, _)
    | Executor, ScopeRetirement
    | Executor, Rejected(_)
    -> True
    _, _ -> False
  }
}

fn key_value(
  key: identity.RequestKey,
  digest: identity.Digest,
) -> mp.MsgPackValue {
  mp.BinaryValue(codec.encode(codec.Admit(key, digest)))
}

fn body_value(body: Body) -> Result(mp.MsgPackValue, Error) {
  let values = case body {
    Hello ->
      Ok([
        mp.IntValue(0),
        mp.IntValue(framing.exec_protocol_version),
        mp.IntValue(2),
      ])
    ChallengeRequest(key, digest) ->
      Ok([mp.IntValue(1), key_value(key, digest)])
    Challenge(key, digest, nonce, window) ->
      Ok([
        mp.IntValue(2),
        key_value(key, digest),
        mp.BinaryValue(nonce),
        mp.IntValue(window),
      ])
    Submit(key, digest, prepared, nonce, budget) -> {
      use value <- result.try(prepared_value(prepared))
      Ok([
        mp.IntValue(3),
        key_value(key, digest),
        value,
        mp.BinaryValue(nonce),
        mp.IntValue(budget),
      ])
    }
    Query(key, digest, cursor) ->
      Ok([mp.IntValue(4), key_value(key, digest), mp.IntValue(cursor)])
    Stdin(key, digest, ordinal, bytes, eof) ->
      Ok([
        mp.IntValue(5),
        key_value(key, digest),
        mp.IntValue(ordinal),
        mp.BinaryValue(bytes),
        mp.IntValue(case eof {
          dispatch.MoreInput -> 0
          dispatch.EndOfInput -> 1
        }),
      ])
    Cancel(key, digest) -> Ok([mp.IntValue(6), key_value(key, digest)])
    DurableReceipt(key, digest, terminal) ->
      Ok([
        mp.IntValue(7),
        key_value(key, digest),
        mp.BinaryValue(identity.digest_bytes(terminal)),
      ])
    CloseScope -> Ok([mp.IntValue(8)])
    Evidence(key, digest, phase, deadline) ->
      Ok([
        mp.IntValue(9),
        key_value(key, digest),
        mp.IntValue(phase),
        mp.IntValue(deadline),
      ])
    Output(key, digest, ordinal, bytes) ->
      Ok([
        mp.IntValue(10),
        key_value(key, digest),
        mp.IntValue(ordinal),
        mp.BinaryValue(bytes),
      ])
    Terminal(key, digest, bytes) ->
      Ok([mp.IntValue(11), key_value(key, digest), mp.BinaryValue(bytes)])
    ScopeRetirement -> Ok([mp.IntValue(12)])
    Rejected(reason) -> Ok([mp.IntValue(13), mp.IntValue(reason)])
  }
  use values <- result.try(values)
  Ok(mp.ArrayValue(values))
}

fn decode_body(
  value: mp.MsgPackValue,
  scope: identity.Scope,
) -> Result(Body, Error) {
  case value {
    mp.ArrayValue([mp.IntValue(0), mp.IntValue(3), mp.IntValue(2)]) -> Ok(Hello)
    mp.ArrayValue([mp.IntValue(1), key]) -> {
      use pair <- result.try(decode_key(key, scope))
      Ok(ChallengeRequest(pair.0, pair.1))
    }
    mp.ArrayValue([
      mp.IntValue(2),
      key,
      mp.BinaryValue(nonce),
      mp.IntValue(window),
    ])
      if window == 1000
    -> {
      use pair <- result.try(decode_key(key, scope))
      Ok(Challenge(pair.0, pair.1, nonce, window))
    }
    mp.ArrayValue([
      mp.IntValue(3),
      key,
      prepared,
      mp.BinaryValue(nonce),
      mp.IntValue(budget),
    ])
      if budget >= 0 && budget <= 86_400_000
    -> {
      use pair <- result.try(decode_key(key, scope))
      use prepared <- result.try(decode_prepared_value(prepared))
      Ok(Submit(pair.0, pair.1, prepared, nonce, budget))
    }
    mp.ArrayValue([mp.IntValue(4), key, mp.IntValue(cursor)])
      if cursor >= 0 && cursor <= 64
    -> {
      use pair <- result.try(decode_key(key, scope))
      Ok(Query(pair.0, pair.1, cursor))
    }
    mp.ArrayValue([
      mp.IntValue(5),
      key,
      mp.IntValue(ordinal),
      mp.BinaryValue(bytes),
      mp.IntValue(eof),
    ])
      if ordinal >= 0 && ordinal < 128 && eof >= 0 && eof <= 1
    -> {
      use pair <- result.try(decode_key(key, scope))
      Ok(
        Stdin(pair.0, pair.1, ordinal, bytes, case eof {
          0 -> dispatch.MoreInput
          _ -> dispatch.EndOfInput
        }),
      )
    }
    mp.ArrayValue([mp.IntValue(6), key]) -> {
      use pair <- result.try(decode_key(key, scope))
      Ok(Cancel(pair.0, pair.1))
    }
    mp.ArrayValue([mp.IntValue(7), key, mp.BinaryValue(bytes)]) -> {
      use pair <- result.try(decode_key(key, scope))
      use terminal <- result.try(
        identity.digest(bytes) |> result.map_error(fn(_) { Invalid }),
      )
      Ok(DurableReceipt(pair.0, pair.1, terminal))
    }
    mp.ArrayValue([mp.IntValue(8)]) -> Ok(CloseScope)
    mp.ArrayValue([
      mp.IntValue(9),
      key,
      mp.IntValue(phase),
      mp.IntValue(deadline),
    ])
      if phase >= 0 && phase <= 6
    -> {
      use pair <- result.try(decode_key(key, scope))
      Ok(Evidence(pair.0, pair.1, phase, deadline))
    }
    mp.ArrayValue([
      mp.IntValue(10),
      key,
      mp.IntValue(ordinal),
      mp.BinaryValue(bytes),
    ])
      if ordinal >= 0 && ordinal < 64
    -> {
      use pair <- result.try(decode_key(key, scope))
      Ok(Output(pair.0, pair.1, ordinal, bytes))
    }
    mp.ArrayValue([mp.IntValue(11), key, mp.BinaryValue(bytes)]) -> {
      use pair <- result.try(decode_key(key, scope))
      Ok(Terminal(pair.0, pair.1, bytes))
    }
    mp.ArrayValue([mp.IntValue(12)]) -> Ok(ScopeRetirement)
    mp.ArrayValue([mp.IntValue(13), mp.IntValue(reason)])
      if reason >= 0 && reason <= 32
    -> Ok(Rejected(reason))
    _ -> Error(Invalid)
  }
}

fn decode_key(
  value: mp.MsgPackValue,
  scope: identity.Scope,
) -> Result(#(identity.RequestKey, identity.Digest), Error) {
  case value {
    mp.BinaryValue(bytes) -> {
      use command <- result.try(
        codec.decode(bytes, scope) |> result.map_error(fn(_) { Invalid }),
      )
      case command {
        codec.Admit(key, digest) -> Ok(#(key, digest))
        _ -> Error(Invalid)
      }
    }
    _ -> Error(Invalid)
  }
}

fn prepared_value(prepared: Prepared) -> Result(mp.MsgPackValue, Error) {
  use _ <- result.try(
    workspace.step(prepared.step) |> result.map_error(fn(_) { Invalid }),
  )
  let request = prepared.request
  use Nil <- result.try(
    case
      request.argv != []
      && bit_array.byte_size(request.token) == 32
      && list.drop(request.argv, 128) == []
      && list.drop(request.env, 64) == []
    {
      True -> Ok(Nil)
      False -> Error(Invalid)
    },
  )
  use native <- result.try(
    framing.encode_payload(framing.Frame(
      0,
      framing.ExecStart(
        request.argv,
        request.env,
        request.cwd,
        request.policy,
        request.token,
        None,
      ),
    ))
    |> result.map_error(fn(_) { Invalid }),
  )
  let lifetime = case prepared.lifetime {
    Finite(ms) -> mp.IntValue(ms)
    Session -> mp.IntValue(0)
  }
  let demand = case request.demand {
    exec.FullEnforcement -> 0
    exec.PlatformEnforcement -> 1
    exec.BestEffort -> 2
  }
  Ok(
    mp.ArrayValue([
      mp.StringValue(prepared.step),
      mp.BinaryValue(identity.digest_bytes(prepared.registration)),
      lifetime,
      mp.IntValue(demand),
      mp.BinaryValue(native),
      mp.IntValue(case prepared.stream {
        Logs -> 0
        ProtocolStream -> 1
      }),
    ]),
  )
}

fn decode_prepared_value(value: mp.MsgPackValue) -> Result(Prepared, Error) {
  case value {
    mp.ArrayValue([
      mp.StringValue(step),
      mp.BinaryValue(reg),
      mp.IntValue(lifetime),
      mp.IntValue(demand),
      mp.BinaryValue(bytes),
      mp.IntValue(stream),
    ])
      if lifetime >= 0
      && lifetime <= 86_400_000
      && demand >= 0
      && demand <= 2
      && stream >= 0
      && stream <= 1
    -> {
      use _ <- result.try(
        workspace.step(step) |> result.map_error(fn(_) { Invalid }),
      )
      use registration <- result.try(
        identity.digest(reg) |> result.map_error(fn(_) { Invalid }),
      )
      use Nil <- result.try(case bit_array.byte_size(bytes) <= 131_072 {
        True -> Ok(Nil)
        False -> Error(Invalid)
      })
      use _ <- result.try(unpack(bytes))
      use frame <- result.try(
        framing.decode_payload(bytes) |> result.map_error(fn(_) { Invalid }),
      )
      case frame {
        framing.Frame(
          0,
          framing.ExecStart(argv, env, cwd, Some(policy), token, None),
        ) -> {
          use Nil <- result.try(case bit_array.byte_size(token) == 32 {
            True -> Ok(Nil)
            False -> Error(Invalid)
          })
          Ok(
            Prepared(
              step,
              registration,
              case lifetime {
                0 -> Session
                _ -> Finite(lifetime)
              },
              exec.ExecRequest(
                argv,
                env,
                cwd,
                Some(policy),
                token,
                case demand {
                  0 -> exec.FullEnforcement
                  1 -> exec.PlatformEnforcement
                  _ -> exec.BestEffort
                },
              ),
              case stream {
                0 -> Logs
                _ -> ProtocolStream
              },
            ),
          )
        }
        _ -> Error(Invalid)
      }
    }
    _ -> Error(Invalid)
  }
}

// Preflight checks raw lengths/counts before core/msgpack allocates containers.
// A binary cannot hide an unbounded native frame: that frame is checked again.
fn unpack(bytes: BitArray) -> Result(mp.MsgPackValue, Error) {
  use Nil <- result.try(
    case
      bit_array.byte_size(bytes) > 0
      && bit_array.byte_size(bytes) <= tls.max_frame_bytes
    {
      True -> Ok(Nil)
      False -> Error(Invalid)
    },
  )
  use parsed <- result.try(scan(bytes, 0, 2048))
  use Nil <- result.try(case parsed.0 == <<>> {
    True -> Ok(Nil)
    False -> Error(Invalid)
  })
  mp.decode(bytes) |> result.map_error(fn(_) { Invalid })
}

fn pack(value: mp.MsgPackValue) -> Result(BitArray, Error) {
  use bytes <- result.try(
    mp.encode(value) |> result.map_error(fn(_) { Invalid }),
  )
  use _ <- result.try(unpack(bytes))
  Ok(bytes)
}

fn scan(
  bytes: BitArray,
  depth: Int,
  nodes: Int,
) -> Result(#(BitArray, Int), Error) {
  use Nil <- result.try(case depth <= 16 && nodes > 0 {
    True -> Ok(Nil)
    False -> Error(Invalid)
  })
  case bytes {
    <<tag, rest:bits>>
      if tag <= 0x7f || tag >= 0xe0 || tag == 0xc0 || tag == 0xc2 || tag == 0xc3
    -> Ok(#(rest, nodes - 1))
    <<tag, rest:bits>> if tag >= 0xa0 && tag <= 0xbf ->
      skip(rest, tag - 0xa0, nodes - 1, 8192)
    <<tag, rest:bits>> if tag >= 0x90 && tag <= 0x9f ->
      scan_many(rest, tag - 0x90, depth + 1, nodes - 1)
    <<tag, rest:bits>> if tag >= 0x80 && tag <= 0x8f ->
      scan_many(rest, { tag - 0x80 } * 2, depth + 1, nodes - 1)
    <<0xdc, n:size(16), rest:bits>> if n <= 128 ->
      scan_many(rest, n, depth + 1, nodes - 1)
    <<0xdd, n:size(32), rest:bits>> if n <= 128 ->
      scan_many(rest, n, depth + 1, nodes - 1)
    <<0xde, n:size(16), rest:bits>> if n <= 128 ->
      scan_many(rest, n * 2, depth + 1, nodes - 1)
    <<0xdf, n:size(32), rest:bits>> if n <= 128 ->
      scan_many(rest, n * 2, depth + 1, nodes - 1)
    <<0xd9, n, rest:bits>> -> skip(rest, n, nodes - 1, 8192)
    <<0xda, n:size(16), rest:bits>> -> skip(rest, n, nodes - 1, 8192)
    <<0xdb, n:size(32), rest:bits>> -> skip(rest, n, nodes - 1, 8192)
    <<0xc4, n, rest:bits>> -> skip(rest, n, nodes - 1, 131_072)
    <<0xc5, n:size(16), rest:bits>> -> skip(rest, n, nodes - 1, 131_072)
    <<0xc6, n:size(32), rest:bits>> -> skip(rest, n, nodes - 1, 131_072)
    <<tag, rest:bits>> if tag == 0xcc || tag == 0xd0 ->
      skip(rest, 1, nodes - 1, 8)
    <<tag, rest:bits>> if tag == 0xcd || tag == 0xd1 ->
      skip(rest, 2, nodes - 1, 8)
    <<tag, rest:bits>> if tag == 0xce || tag == 0xd2 ->
      skip(rest, 4, nodes - 1, 8)
    <<tag, rest:bits>> if tag == 0xcf || tag == 0xd3 || tag == 0xcb ->
      skip(rest, 8, nodes - 1, 8)
    _ -> Error(Invalid)
  }
}

fn skip(
  bytes: BitArray,
  count: Int,
  nodes: Int,
  maximum: Int,
) -> Result(#(BitArray, Int), Error) {
  case bytes {
    <<_:bytes-size(count), rest:bits>> if count <= maximum -> Ok(#(rest, nodes))
    _ -> Error(Invalid)
  }
}

fn scan_many(
  bytes: BitArray,
  count: Int,
  depth: Int,
  nodes: Int,
) -> Result(#(BitArray, Int), Error) {
  case count {
    0 -> Ok(#(bytes, nodes))
    _ -> {
      use parsed <- result.try(scan(bytes, depth, nodes))
      scan_many(parsed.0, count - 1, depth, parsed.1)
    }
  }
}

fn validate_body(body: Body) -> Result(Nil, Error) {
  case body {
    Challenge(_, _, nonce, _) | Submit(_, _, _, nonce, _) ->
      case bit_array.byte_size(nonce) == 32 {
        True -> Ok(Nil)
        False -> Error(Invalid)
      }
    Stdin(_, _, _, bytes, _) ->
      case bit_array.byte_size(bytes) <= 8192 {
        True -> Ok(Nil)
        False -> Error(Invalid)
      }
    Output(_, _, _, bytes) ->
      case bit_array.byte_size(bytes) <= 16_384 {
        True -> Ok(Nil)
        False -> Error(Invalid)
      }
    Terminal(_, _, bytes) ->
      case bit_array.byte_size(bytes) <= 32_768 {
        True -> Ok(Nil)
        False -> Error(Invalid)
      }
    _ -> Ok(Nil)
  }
}

/// Applies bounded msgpack preflight before native payload decoding.
///
/// ## Examples
///
/// ```gleam
/// wire.decode_value(bytes)
/// ```
pub fn decode_value(bytes: BitArray) -> Result(mp.MsgPackValue, Error) {
  unpack(bytes)
}

/// Encodes bounded declarative native evidence with the same preflight.
///
/// ## Examples
///
/// ```gleam
/// wire.encode_value(value)
/// ```
pub fn encode_value(value: mp.MsgPackValue) -> Result(BitArray, Error) {
  pack(value)
}
