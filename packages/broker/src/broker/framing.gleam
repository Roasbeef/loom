//// The effect-plane wire protocol from the implementation spec, Part 1.4
//// (frozen), broker side:
////
//// ```
//// frame    := u32_be length ++ msgpack(map)
//// map keys := "v":1, "id":u64, "kind":str, "body":map
//// kinds    : hello, exec_start, exec_stdin, exec_out, exec_exit,
////            cap_call, cap_result, hook_call, hook_result, cancel,
////            heartbeat, error
//// ```
////
//// Two versions travel here and they are not the same number. `v` is
//// `envelope_version`, the container format above, and has never moved.
//// `hello.proto` is `exec_protocol_version`, the vocabulary *inside*
//// `body` on the exec channel, and every protocol change to that
//// vocabulary bumps it. Keeping them apart is what lets a stale helper
//// be diagnosed rather than merely rejected: its frames still decode, so
//// the broker can read its `hello`, see which side is behind, and say so.
////
//// `hook_call` and `hook_result` are the one pair that flows the other
//// way: the harness asks and the satellite answers
//// (`protocol-change/012-hook-call.md`). They exist because a satellite
//// that lives for a session has nothing to pull against after its first
//// answer, and because a hook fires on the harness's timeline rather than
//// the program's. They never cross the exec channel, so the Go helper
//// neither sends nor parses them.
////
//// Every inbound frame is parsed and validated as data (two-channel
//// doctrine, design §5.6). Decoding is total: a malformed frame is a
//// value describing the fault — the caller closes the channel and settles
//// the effect in-band per spec §3.3 invariant 6 — never a crash. An
//// unknown but well-formed kind is reported separately so the caller can
//// answer with an in-band `error` frame and keep the channel (forward
//// compatibility, mirroring the helper).
////
//// The incremental `Deframer` is pure: bytes in, frames out, remainder
//// carried. Frame boundaries never depend on how the transport chunks
//// its reads.
////
//// ## Flow
////
//// Outbound: `encode` → `encode_payload` → `body_to_msgpack`
////
//// Raw terminal inbound: `decode_raw_envelope` → `raw_pairs` →
//// `validate_envelope`, with `raw_body` handed to the terminal decoder.
////
//// Inbound: `push` → `push_loop` → `take_frame` → `decode_payload` →
//// `decode_body` → `push_decoded`
////
//// 1. `encode` prefixes the msgpack payload from `encode_payload` with its
////    u32 length and refuses one over the maximum frame size; `encode_payload`
////    writes the envelope, and `body_to_msgpack` writes the body its `kind_name`
////    names.
//// 2. `push` is the deframer's only way in. A deframer that already faulted
////    answers the same fault; otherwise the bytes join the carried buffer and
////    `push_loop` scans it.
//// 3. `push_loop` reads a length prefix, and `take_frame` cuts one payload
////    once enough bytes have arrived, so frame boundaries never depend on how
////    the transport chunked its reads.
//// 4. `decode_payload` checks the envelope (version, id, kind), and
////    `decode_body` dispatches on the kind to one `decode_*` function per body.
//// 5. `push_decoded` decides what a decode result means: a frame is `Known`, an
////    unknown kind is reported and scanning goes on, and a broken envelope
////    poisons the deframer through `faulted`.
//// 6. `carry` ends a scan that ran out of bytes, keeping the buffer for the
////    next `push`.

import broker/policy.{type Limits, type SandboxPolicy}
import core/corruption.{type CorruptionReport}
import core/internal/msgpack_scan
import core/msgpack.{type MsgPackValue}
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// The frame envelope's own version, stamped as `v` on every frame of
/// every effect-plane channel and rejected on sight when it differs.
///
/// It describes the *container* — a `u32_be` length prefix around a
/// msgpack map of exactly `v`, `id`, `kind`, `body` — and says nothing
/// about what is inside `body`. No protocol change has altered that
/// shape, which is why this has stayed 1 while `exec_protocol_version`
/// has moved. The exec helper (`sandbox/internal/framing.EnvelopeVersion`)
/// and the satellite prelude (`cap/internal/wire.protocol_version`) pin
/// the same literal.
pub const envelope_version = 1

/// The version of the exec channel's *body* vocabulary: what
/// `exec_start`, `exec_exit`, `shutdown` and the rest carry. The helper
/// announces it as `hello.proto`, the broker answers with its own, and
/// either side refuses a peer that does not match.
///
/// This is the number a protocol change moves. **A `protocol-change`
/// that adds, removes, or makes-required a key on a frame the exec
/// helper sends or receives — or adds a kind to that channel — bumps
/// this constant on both sides in the same commit.** Before that rule
/// existed a stale helper failed as an anonymous decoder error on some
/// later frame (issue #61); now it fails at the handshake, naming both
/// numbers.
///
/// The history the current value back-fills:
///
/// - **1** — the vocabulary frozen in spec Part 1.4 as first shipped.
/// - **2** — `protocol-change/006`: `exec_exit` gained a required
///   `cancelled` key, so a helper at 1 cannot produce a frame a broker
///   at 2 will accept.
/// - **3** — `protocol-change/014`: the harness-to-helper `shutdown`
///   frame, which a helper at 2 answers as an unknown kind rather than
///   by retiring.
///
/// - **4** — `protocol-change/076`: opt-in credited protocol frames.
///
/// Two accepted changes touch Part 1.4 and are deliberately *not*
/// counted. `protocol-change/012`'s `hook_call`/`hook_result` pair
/// crosses only the capability socket, which carries no `hello` and so
/// no `proto` — the exec helper neither sends nor parses those frames.
/// `protocol-change/004` is still PROPOSED and unimplemented.
pub const exec_protocol_version = 4

/// The cap on a frame's msgpack payload, mirroring the Go helper's
/// 16 MiB `MaxFrameLen`: a corrupt or hostile length prefix must not
/// make the broker allocate gigabytes.
pub const max_frame_bytes = 16_777_216

/// One protocol frame: the envelope id plus a typed body. `id`
/// correlates request and response — `exec_out`/`exec_exit` reuse their
/// `exec_start`'s id, heartbeat echoes reuse the heartbeat's. Invariant:
/// `0 <= id < 2^64` (a u64 on the wire).
pub type Frame {
  Frame(id: Int, body: Body)
}

/// Which output stream an `exec_out` chunk belongs to.
pub type OutputStream {
  Stdout
  Stderr
}

/// The feature both hello messages require before credited execution.
pub const protocol_credit_feature = "protocol-credit-v1"

/// The two protocol lifetimes. Server mode requires exact helper retirement.
pub type ProtocolMode {
  /// A session-owned protocol server; finite reuse is forbidden.
  ServerProtocol

  /// One bounded collector with empty EOF input and consumed reuse evidence.
  FiniteCollected
}

/// Whether a credited input seals the child's stdin queue.
pub type InputEnd {
  /// More admitted input may follow.
  InputContinues

  /// Queue admission seals input after this frame.
  InputEOF
}

/// Whether the producer reached its per-stream output ceiling.
pub type OutputDisposition {
  /// The chunk remains within the producer ceiling.
  OutputComplete

  /// The final producer chunk reached the ceiling.
  OutputTruncated
}

/// The checked credited protocol outcome, separate from native exit status.
pub type ProtocolDisposition {
  /// All offered output was consumed and workers joined.
  ProtocolComplete

  /// Credit or transport failed; a retained prefix is not complete.
  ProtocolFailed
}

/// The closed reason for refusing one exact input admission.
pub type InputRefusal {
  /// Original identity or ordinal did not match.
  InputIdentity

  /// Input has already ended or failed.
  InputSealed

  /// The execution's one admission slot is occupied.
  InputPending

  /// A chunk or lifetime ceiling was exceeded.
  InputLimit

  /// Finite collectors accept only their one empty EOF.
  FiniteInput

  /// The existing stdin queue definitely rejected admission.
  QueueRejected
}

/// A cleared start, preserving the ordinary request field vocabulary.
pub type ProtocolRequest {
  ProtocolRequest(
    /// The nonempty cleared program and arguments.
    argv: List(String),
    /// The allowlist-constructed environment.
    env: List(#(String, String)),
    /// The cleared physical working directory.
    cwd: String,
    /// The cleared per-execution sandbox policy.
    policy: Option(SandboxPolicy),
    /// The nonempty original capability token.
    token: BitArray,
    /// The existing optional limits override.
    limits: Option(Limits),
  )
}

/// Native terminal fields decoded through the unchanged ordinary exit decoder.
/// The opaque wrapper can contain only a checked ExecExit, never another body.
pub opaque type ProtocolTerminal {
  ProtocolTerminal(exit: Body)
}

/// The typed body of each frame kind. Field vocabulary matches the Go
/// helper's structs byte for byte on the wire.
pub type Body {
  /// Opt-in cleared execution with a closed lifecycle mode.
  ProtocolStart(
    /// Original cleared native request fields.
    request: ProtocolRequest,
    /// Lifecycle fixed by trusted native assembly.
    mode: ProtocolMode,
  )

  /// One original bounded queue-admission request.
  ProtocolInput(
    /// The immutable original wire execution identity.
    execution_id: Int,
    /// The exact contiguous credit ordinal.
    ordinal: Int,
    /// The independent original input frame identity.
    frame_id: Int,
    /// The bounded admitted payload.
    data: BitArray,
    /// Whether this admitted input seals stdin.
    end: InputEnd,
  )

  /// Queue admission of that exact original frame.
  ProtocolInputAccepted(
    /// The immutable original wire execution identity.
    execution_id: Int,
    /// The exact contiguous credit ordinal.
    ordinal: Int,
    /// The independent original input frame identity.
    frame_id: Int,
  )

  /// Definite refusal of that exact original frame.
  ProtocolInputRefused(
    /// The immutable original wire execution identity.
    execution_id: Int,
    /// The exact contiguous credit ordinal.
    ordinal: Int,
    /// The independent original input frame identity.
    frame_id: Int,
    /// The definite refusal of this original admission.
    reason: InputRefusal,
  )

  /// One shared-credit output chunk with cumulative per-stream bytes.
  ProtocolOutput(
    /// The immutable original wire execution identity.
    execution_id: Int,
    /// The exact contiguous credit ordinal.
    ordinal: Int,
    /// The producer stream sharing this output credit.
    stream: OutputStream,
    /// The bounded admitted payload.
    data: BitArray,
    /// Cumulative admitted bytes for this stream, including this chunk.
    bytes: Int,
    /// The checked producer or protocol outcome.
    disposition: OutputDisposition,
  )

  /// Final bounded-consumer admission of that exact chunk.
  ProtocolOutputConsumed(
    /// The immutable original wire execution identity.
    execution_id: Int,
    /// The exact contiguous credit ordinal.
    ordinal: Int,
  )

  /// Post-waitDone evidence, still requiring trusted consumer validation.
  ProtocolReusable(
    /// The immutable original wire execution identity.
    execution_id: Int,
  )

  /// Credited-only terminal disposition, independent of finite reuse.
  ProtocolExit(
    /// Native terminal fields checked through the ordinary decoder.
    terminal: ProtocolTerminal,
    /// The checked producer or protocol outcome.
    disposition: ProtocolDisposition,
  )

  /// The handshake: the helper sends its hello first; the broker must
  /// answer with its own before any other frame. `proto` is the peer's
  /// `exec_protocol_version`, and a mismatch is fatal to the channel on
  /// both sides.
  Hello(proto: Int, peer: String, features: List(String))

  /// Starts an execution. `policy` overrides the helper's fd-3 base
  /// policy for this execution when present; `limits` is reserved for
  /// per-exec overrides (the helper accepts and ignores it today).
  /// Invariant: `argv` non-empty, `token` non-empty.
  ExecStart(
    argv: List(String),
    env: List(#(String, String)),
    cwd: String,
    policy: Option(SandboxPolicy),
    token: BitArray,
    limits: Option(Limits),
  )

  /// A chunk of stdin for the running execution; `eof: True` closes the
  /// child's stdin after `data` is written. Writes after eof are
  /// refused by the helper.
  ExecStdin(data: BitArray, eof: Bool)

  /// One chunk of child output. `bytes` is the cumulative per-stream
  /// count including this chunk; `truncated` marks the single final
  /// chunk emitted when the per-stream `output_bytes` cap is hit.
  ExecOut(stream: OutputStream, data: BitArray, bytes: Int, truncated: Bool)

  /// The completed execution. `enforcement` lists what was actually
  /// applied (e.g. "bwrap", "mounts:ro=2,...", "landlock:abi=5",
  /// "skip:landlock: ...") — ground truth, checked over hello features.
  /// `signal` is 0 on a normal exit. `cancelled` reports that the helper
  /// stopped the execution rather than the execution ending of its own
  /// accord (protocol-change/006); `timed_out` separates the two causes.
  ExecExit(
    code: Int,
    signal: Int,
    stdout_bytes: Int,
    stderr_bytes: Int,
    stdout_truncated: Bool,
    stderr_truncated: Bool,
    enforcement: List(String),
    degraded: Bool,
    wall_ms: Int,
    timed_out: Bool,
    cancelled: Bool,
  )

  /// A capability RPC from a satellite: `{token, cap, args,
  /// deadline_ms}`. The broker checks the token on every call.
  CapCall(token: BitArray, cap: String, args: MsgPackValue, deadline_ms: Int)

  /// The answer to a `cap_call`.
  CapResult(outcome: CapOutcome, usage: Option(MsgPackValue))

  /// The harness asking a persistent satellite to answer one invocation
  /// (`protocol-change/012`). Harness → satellite, and the only frame
  /// that travels in that direction.
  ///
  /// `token` is the token minted for *this* invocation: the satellite
  /// presents it on every `cap_call` it makes while answering, and a
  /// `cap_call` made outside an open invocation therefore carries a
  /// revoked token and is refused. That is what keeps a satellite which
  /// outlives one execution from acting between them.
  ///
  /// `kind` is `"tool"` or `"event"` on the wire and becomes a
  /// two-variant type at each edge; `name` is the tool or event name;
  /// `args` is that row's payload; `deadline_ms` has the semantics of
  /// `cap_call.deadline_ms`, and letting it pass costs the satellite its
  /// node.
  HookCall(
    token: BitArray,
    kind: String,
    name: String,
    args: MsgPackValue,
    deadline_ms: Int,
  )

  /// The answer to a `hook_call`, correlated by the same frame `id`.
  /// Satellite → harness. At most one is outstanding per satellite: a
  /// `hook_result` with no pending call is a protocol fault the harness
  /// destroys the node over, never a frame it tries to match up.
  HookResult(outcome: CapOutcome)

  /// Cancels the running execution. Idempotent; the receiver must kill
  /// its pgroup within 2s or the broker escalates to SIGKILL of the
  /// whole helper.
  Cancel

  /// Retires an exec helper after it cancels and joins its current jail.
  /// The empty body has no acknowledgement; native exit is the witness.
  Shutdown

  /// A liveness probe; the receiver echoes it with the same id.
  Heartbeat

  /// An in-band protocol-level error correlated to the offending
  /// frame's id (0 when there is none).
  ErrorBody(code: String, message: String)
}

/// The outcome half of a `cap_result` body.
pub type CapOutcome {
  /// The capability call succeeded with this value.
  CapOk(value: MsgPackValue)

  /// The capability call failed in-band.
  CapErr(code: String, message: String)
}

/// Why an inbound frame could not be accepted. `Malformed` and
/// `UnsupportedVersion` require closing the channel (spec §3.3.6);
/// `UnknownKind` is answered in-band and the channel stays open.
pub type FrameError {
  /// The bytes were not a well-formed frame of this protocol.
  Malformed(report: CorruptionReport)

  /// The envelope carried a version other than `envelope_version`. A
  /// peer whose *container* format differs is unreadable; a peer whose
  /// body vocabulary differs is not, and is caught by `hello.proto`
  /// instead so the failure can name both numbers.
  UnsupportedVersion(version: Int)

  /// A well-formed frame of a kind this broker does not know.
  UnknownKind(id: Int, kind: String)
}

// --- encoding -----------------------------------------------------------

/// Encodes a frame to its wire bytes, including the u32_be length
/// prefix.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(<<_length:size(32), _payload:bytes>>) =
///   framing.encode(framing.Frame(id: 1, body: framing.Heartbeat))
/// ```
///
pub fn encode(frame: Frame) -> Result(BitArray, msgpack.EncodeError) {
  use payload <- result.try(encode_payload(frame))
  let size = bit_array.byte_size(payload)
  case size > max_frame_bytes {
    True -> Error(msgpack.UnencodableLength(length: size))
    False -> Ok(<<size:size(32), payload:bits>>)
  }
}

/// Encodes a frame's msgpack payload without the length prefix. Kept
/// public for golden-fixture tests; `encode` is the wire form.
pub fn encode_payload(frame: Frame) -> Result(BitArray, msgpack.EncodeError) {
  case frame.id < 0 {
    True -> Error(msgpack.IntegerOutOfRange(value: frame.id))
    False ->
      msgpack.encode(
        msgpack.MapValue([
          #(msgpack.StringValue("v"), msgpack.IntValue(envelope_version)),
          #(msgpack.StringValue("id"), msgpack.IntValue(frame.id)),
          #(
            msgpack.StringValue("kind"),
            msgpack.StringValue(kind_name(frame.body)),
          ),
          #(msgpack.StringValue("body"), body_to_msgpack(frame.body)),
        ]),
      )
  }
}

fn kind_name(body: Body) -> String {
  case body {
    ProtocolStart(..) -> "protocol_start"
    ProtocolInput(..) -> "protocol_input"
    ProtocolInputAccepted(..) -> "protocol_input_accepted"
    ProtocolInputRefused(..) -> "protocol_input_refused"
    ProtocolOutput(..) -> "protocol_output"
    ProtocolOutputConsumed(..) -> "protocol_output_consumed"
    ProtocolReusable(..) -> "protocol_reusable"
    ProtocolExit(..) -> "exec_exit"
    Hello(..) -> "hello"
    ExecStart(..) -> "exec_start"
    ExecStdin(..) -> "exec_stdin"
    ExecOut(..) -> "exec_out"
    ExecExit(..) -> "exec_exit"
    CapCall(..) -> "cap_call"
    CapResult(..) -> "cap_result"
    HookCall(..) -> "hook_call"
    HookResult(..) -> "hook_result"
    Cancel -> "cancel"
    Shutdown -> "shutdown"
    Heartbeat -> "heartbeat"
    ErrorBody(..) -> "error"
  }
}

fn body_to_msgpack(body: Body) -> MsgPackValue {
  case body {
    ProtocolStart(request: r, mode:) -> {
      let entries =
        map_entries(
          body_to_msgpack(ExecStart(
            r.argv,
            r.env,
            r.cwd,
            r.policy,
            r.token,
            r.limits,
          )),
        )
      msgpack.MapValue(
        list.append(entries, [
          entry("mode", msgpack.StringValue(mode_name(mode))),
        ]),
      )
    }
    ProtocolInput(execution_id:, ordinal:, frame_id:, data:, end:) ->
      msgpack.MapValue(
        list.append(input_identity(execution_id, ordinal, frame_id), [
          entry("data", msgpack.BinaryValue(data)),
          entry("eof", msgpack.BoolValue(end == InputEOF)),
        ]),
      )
    ProtocolInputAccepted(execution_id:, ordinal:, frame_id:) ->
      msgpack.MapValue(input_identity(execution_id, ordinal, frame_id))
    ProtocolInputRefused(execution_id:, ordinal:, frame_id:, reason:) ->
      msgpack.MapValue(
        list.append(input_identity(execution_id, ordinal, frame_id), [
          entry("reason", msgpack.StringValue(refusal_name(reason))),
        ]),
      )
    ProtocolOutput(
      execution_id:,
      ordinal:,
      stream:,
      data:,
      bytes:,
      disposition:,
    ) ->
      msgpack.MapValue(
        list.append(output_identity(execution_id, ordinal), [
          entry("stream", msgpack.StringValue(stream_name(stream))),
          entry("data", msgpack.BinaryValue(data)),
          entry("bytes", msgpack.IntValue(bytes)),
          entry("truncated", msgpack.BoolValue(disposition == OutputTruncated)),
        ]),
      )
    ProtocolOutputConsumed(execution_id:, ordinal:) ->
      msgpack.MapValue(output_identity(execution_id, ordinal))
    ProtocolReusable(execution_id:) ->
      msgpack.MapValue([entry("execution_id", msgpack.IntValue(execution_id))])
    ProtocolExit(terminal: ProtocolTerminal(exit), disposition:) -> {
      let entries = map_entries(body_to_msgpack(exit))
      msgpack.MapValue(
        list.append(entries, [
          entry(
            "protocol",
            msgpack.StringValue(case disposition {
              ProtocolComplete -> "complete"
              ProtocolFailed -> "failed"
            }),
          ),
        ]),
      )
    }

    Hello(proto:, peer:, features:) ->
      msgpack.MapValue([
        #(msgpack.StringValue("proto"), msgpack.IntValue(proto)),
        #(msgpack.StringValue("peer"), msgpack.StringValue(peer)),
        #(msgpack.StringValue("features"), string_array(features)),
      ])
    ExecStart(argv:, env:, cwd:, policy: exec_policy, token:, limits:) -> {
      let base = [
        #(msgpack.StringValue("argv"), string_array(argv)),
        #(
          msgpack.StringValue("env"),
          msgpack.MapValue(
            list.map(env, fn(pair) {
              #(msgpack.StringValue(pair.0), msgpack.StringValue(pair.1))
            }),
          ),
        ),
        #(msgpack.StringValue("cwd"), msgpack.StringValue(cwd)),
        #(msgpack.StringValue("token"), msgpack.BinaryValue(token)),
      ]
      let with_policy = case exec_policy {
        None -> base
        Some(value) ->
          list.append(base, [
            #(msgpack.StringValue("policy"), policy.to_msgpack(value)),
          ])
      }
      case limits {
        None -> msgpack.MapValue(with_policy)
        Some(value) ->
          msgpack.MapValue(
            list.append(with_policy, [
              #(msgpack.StringValue("limits"), limits_to_msgpack(value)),
            ]),
          )
      }
    }
    ExecStdin(data:, eof:) ->
      msgpack.MapValue([
        #(msgpack.StringValue("data"), msgpack.BinaryValue(data)),
        #(msgpack.StringValue("eof"), msgpack.BoolValue(eof)),
      ])
    ExecOut(stream:, data:, bytes:, truncated:) ->
      msgpack.MapValue([
        #(
          msgpack.StringValue("stream"),
          msgpack.StringValue(stream_name(stream)),
        ),
        #(msgpack.StringValue("data"), msgpack.BinaryValue(data)),
        #(msgpack.StringValue("bytes"), msgpack.IntValue(bytes)),
        #(msgpack.StringValue("truncated"), msgpack.BoolValue(truncated)),
      ])
    ExecExit(
      code:,
      signal:,
      stdout_bytes:,
      stderr_bytes:,
      stdout_truncated:,
      stderr_truncated:,
      enforcement:,
      degraded:,
      wall_ms:,
      timed_out:,
      cancelled:,
    ) ->
      msgpack.MapValue([
        #(msgpack.StringValue("code"), msgpack.IntValue(code)),
        #(msgpack.StringValue("signal"), msgpack.IntValue(signal)),
        #(msgpack.StringValue("stdout_bytes"), msgpack.IntValue(stdout_bytes)),
        #(msgpack.StringValue("stderr_bytes"), msgpack.IntValue(stderr_bytes)),
        #(
          msgpack.StringValue("stdout_truncated"),
          msgpack.BoolValue(stdout_truncated),
        ),
        #(
          msgpack.StringValue("stderr_truncated"),
          msgpack.BoolValue(stderr_truncated),
        ),
        #(msgpack.StringValue("enforcement"), string_array(enforcement)),
        #(msgpack.StringValue("degraded"), msgpack.BoolValue(degraded)),
        #(msgpack.StringValue("wall_ms"), msgpack.IntValue(wall_ms)),
        #(msgpack.StringValue("timed_out"), msgpack.BoolValue(timed_out)),
        #(msgpack.StringValue("cancelled"), msgpack.BoolValue(cancelled)),
      ])
    CapCall(token:, cap:, args:, deadline_ms:) ->
      msgpack.MapValue([
        #(msgpack.StringValue("token"), msgpack.BinaryValue(token)),
        #(msgpack.StringValue("cap"), msgpack.StringValue(cap)),
        #(msgpack.StringValue("args"), args),
        #(msgpack.StringValue("deadline_ms"), msgpack.IntValue(deadline_ms)),
      ])
    CapResult(outcome:, usage:) -> {
      let base = outcome_entries(outcome)
      case usage {
        None -> msgpack.MapValue(base)
        Some(value) ->
          msgpack.MapValue(
            list.append(base, [#(msgpack.StringValue("usage"), value)]),
          )
      }
    }
    HookCall(token:, kind:, name:, args:, deadline_ms:) ->
      msgpack.MapValue([
        #(msgpack.StringValue("token"), msgpack.BinaryValue(token)),
        #(msgpack.StringValue("kind"), msgpack.StringValue(kind)),
        #(msgpack.StringValue("name"), msgpack.StringValue(name)),
        #(msgpack.StringValue("args"), args),
        #(msgpack.StringValue("deadline_ms"), msgpack.IntValue(deadline_ms)),
      ])
    HookResult(outcome:) -> outcome_to_msgpack(outcome)
    Cancel -> msgpack.MapValue([])
    Shutdown -> msgpack.MapValue([])
    Heartbeat -> msgpack.MapValue([])
    ErrorBody(code:, message:) ->
      msgpack.MapValue([
        #(msgpack.StringValue("code"), msgpack.StringValue(code)),
        #(msgpack.StringValue("msg"), msgpack.StringValue(message)),
      ])
  }
}

// The `{ok, value}` / `{ok, error}` pair both result kinds carry. Shared
// so `cap_result` and `hook_result` cannot drift into two spellings of
// one shape — 012 specifies the second as mirroring the first.
fn outcome_entries(outcome: CapOutcome) -> List(#(MsgPackValue, MsgPackValue)) {
  case outcome {
    CapOk(value:) -> [
      #(msgpack.StringValue("ok"), msgpack.BoolValue(True)),
      #(msgpack.StringValue("value"), value),
    ]
    CapErr(code:, message:) -> [
      #(msgpack.StringValue("ok"), msgpack.BoolValue(False)),
      #(
        msgpack.StringValue("error"),
        msgpack.MapValue([
          #(msgpack.StringValue("code"), msgpack.StringValue(code)),
          #(msgpack.StringValue("msg"), msgpack.StringValue(message)),
        ]),
      ),
    ]
  }
}

fn outcome_to_msgpack(outcome: CapOutcome) -> MsgPackValue {
  msgpack.MapValue(outcome_entries(outcome))
}

fn limits_to_msgpack(limits: Limits) -> MsgPackValue {
  msgpack.MapValue([
    #(msgpack.StringValue("cpu_s"), msgpack.IntValue(limits.cpu_s)),
    #(msgpack.StringValue("fsize_bytes"), msgpack.IntValue(limits.fsize_bytes)),
    #(msgpack.StringValue("mem_bytes"), msgpack.IntValue(limits.mem_bytes)),
    #(
      msgpack.StringValue("output_bytes"),
      msgpack.IntValue(limits.output_bytes),
    ),
    #(msgpack.StringValue("pids"), msgpack.IntValue(limits.pids)),
    #(msgpack.StringValue("wall_s"), msgpack.IntValue(limits.wall_s)),
  ])
}

fn stream_name(stream: OutputStream) -> String {
  case stream {
    Stdout -> "stdout"
    Stderr -> "stderr"
  }
}

fn string_array(items: List(String)) -> MsgPackValue {
  msgpack.ArrayValue(list.map(items, msgpack.StringValue))
}

// --- decoding -----------------------------------------------------------

/// Decodes one frame's msgpack payload (without the length prefix),
/// totally and strictly: the envelope must carry exactly `v`, `id`,
/// `kind`, and `body`, the version must match, and each known kind's
/// body must carry exactly its required keys with the right types.
///
/// ## Examples
///
/// ```gleam
/// let frame = framing.Frame(id: 7, body: framing.Heartbeat)
/// let assert Ok(payload) = framing.encode_payload(frame)
/// assert framing.decode_payload(payload) == Ok(frame)
/// ```
///
pub fn decode_payload(payload: BitArray) -> Result(Frame, FrameError) {
  use value <- result.try(
    msgpack.decode(payload) |> result.map_error(Malformed),
  )
  use #(id, kind, body_value) <- result.try(validate_envelope(value))
  use body <- result.try(decode_body(id, kind, body_value))
  Ok(Frame(id:, body:))
}

/// A validated envelope header and its exact, structurally bounded body bytes.
/// Body UTF-8, duplicate keys, float validity and kind-specific semantics have
/// not been checked. Callers must validate the body before constructing terms.
pub opaque type RawEnvelope {
  /// Retains checked header facts beside the untouched encoded body.
  RawEnvelope(
    /// The validated original nonnegative envelope identity.
    id: Int,
    /// The validated kind, independent of whether the broker knows it.
    kind: String,
    /// The original encoded value, never the header-check placeholder.
    body: BitArray,
  )
}

/// Validates the transport header without decoding its body into a value tree.
/// Arbitrary field order and nonminimal header encodings retain wire semantics.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(payload) = framing.encode_payload(framing.Frame(0, framing.Heartbeat))
/// let assert Ok(raw) = framing.decode_raw_envelope(payload)
/// assert framing.raw_kind(raw) == "heartbeat"
/// ```
pub fn decode_raw_envelope(
  payload: BitArray,
) -> Result(RawEnvelope, FrameError) {
  use #(prefix, count, remaining) <- result.try(
    msgpack_scan.transport_map(payload) |> result.map_error(Malformed),
  )
  use #(header, body) <- result.try(raw_pairs(remaining, count, prefix, None))
  use value <- result.try(msgpack.decode(header) |> result.map_error(Malformed))
  use #(id, kind, _) <- result.try(validate_envelope(value))
  use body <- result.try(
    body |> option.to_result(malformed("frame", "required key body", "missing")),
  )
  Ok(RawEnvelope(id:, kind:, body:))
}

/// Reads the validated transport kind, without interpreting body semantics.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(payload) = framing.encode_payload(framing.Frame(0, framing.Heartbeat))
/// let assert Ok(raw) = framing.decode_raw_envelope(payload)
/// assert framing.raw_kind(raw) == "heartbeat"
/// ```
pub fn raw_kind(envelope: RawEnvelope) -> String {
  envelope.kind
}

/// Reads the exact original body slice for its owning decoder's preflight.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(payload) = framing.encode_payload(framing.Frame(0, framing.Heartbeat))
/// let assert Ok(raw) = framing.decode_raw_envelope(payload)
/// assert framing.raw_body(raw) == <<0x80>>
/// ```
pub fn raw_body(envelope: RawEnvelope) -> BitArray {
  envelope.body
}

fn raw_pairs(
  bytes: BitArray,
  count: Int,
  header: BitArray,
  body: Option(BitArray),
) -> Result(#(BitArray, Option(BitArray)), FrameError) {
  case count {
    0 ->
      case bytes == <<>> {
        True -> Ok(#(header, body))
        False -> Error(malformed("frame", "no trailing bytes", ""))
      }
    _ -> {
      use #(key_bytes, remaining) <- result.try(
        msgpack_scan.transport_string(bytes) |> result.map_error(Malformed),
      )
      use key <- result.try(
        msgpack.decode(key_bytes) |> result.map_error(Malformed),
      )
      use #(value, rest) <- result.try(raw_field(key, remaining))

      // Every original pair survives into the small header, including duplicates.
      // Only a body value is replaced; the generic header decoder rejects keys
      // whose alternative wire encodings denote the same string.
      let #(checked, body) = case key {
        msgpack.StringValue("body") -> #(<<0x80>>, Some(value))
        _ -> #(value, body)
      }
      raw_pairs(
        rest,
        count - 1,
        <<header:bits, key_bytes:bits, checked:bits>>,
        body,
      )
    }
  }
}

fn raw_field(
  key: MsgPackValue,
  bytes: BitArray,
) -> Result(#(BitArray, BitArray), FrameError) {
  case key {
    msgpack.StringValue("v") | msgpack.StringValue("id") ->
      msgpack_scan.transport_integer(bytes) |> result.map_error(Malformed)
    msgpack.StringValue("kind") ->
      msgpack_scan.transport_string(bytes) |> result.map_error(Malformed)
    msgpack.StringValue("body") ->
      msgpack_scan.transport_value(bytes) |> result.map_error(Malformed)
    _ -> Error(malformed("frame", "known string keys", ""))
  }
}

fn validate_envelope(
  value: MsgPackValue,
) -> Result(#(Int, String, MsgPackValue), FrameError) {
  use entries <- result.try(envelope_map(value))
  use Nil <- result.try(check_keys(entries, ["v", "id", "kind", "body"]))
  use v <- result.try(envelope_int(entries, "v"))
  use Nil <- result.try(case v == envelope_version {
    True -> Ok(Nil)
    False -> Error(UnsupportedVersion(version: v))
  })
  use id <- result.try(envelope_int(entries, "id"))
  use Nil <- result.try(case id >= 0 {
    True -> Ok(Nil)
    False -> Error(malformed("id", "a u64", int.to_string(id)))
  })
  use kind <- result.try(envelope_string(entries, "kind"))
  use body <- result.try(envelope_field(entries, "body"))
  Ok(#(id, kind, body))
}

fn decode_body(
  id: Int,
  kind: String,
  value: MsgPackValue,
) -> Result(Body, FrameError) {
  use entries <- result.try(body_map(kind, value))
  case kind {
    "protocol_start" -> decode_protocol_start(entries)
    "protocol_input" -> decode_protocol_input(entries)
    "protocol_input_accepted" -> decode_input_ack(entries, "accepted")
    "protocol_input_refused" -> decode_input_ack(entries, "refused")
    "protocol_output" -> decode_protocol_output(entries)
    "protocol_output_consumed" -> decode_protocol_consumed(entries)
    "protocol_reusable" -> {
      use Nil <- result.try(check_keys(entries, ["execution_id"]))
      use execution_id <- result.try(positive_field(entries, "execution_id"))
      Ok(ProtocolReusable(execution_id))
    }
    "hello" -> decode_hello(entries)
    "exec_start" -> decode_exec_start(entries)
    "exec_stdin" -> decode_exec_stdin(entries)
    "exec_out" -> decode_exec_out(entries)
    "exec_exit" -> decode_terminal(entries)
    "cap_call" -> decode_cap_call(entries)
    "cap_result" -> decode_cap_result(entries)
    "hook_call" -> decode_hook_call(entries)
    "hook_result" -> decode_hook_result(entries)
    "cancel" -> Ok(Cancel)
    "shutdown" -> {
      use Nil <- result.try(check_keys(entries, []))
      Ok(Shutdown)
    }
    "heartbeat" -> Ok(Heartbeat)
    "error" -> decode_error_body(entries)
    _ -> Error(UnknownKind(id:, kind:))
  }
}

fn decode_hello(entries: Entries) -> Result(Body, FrameError) {
  use Nil <- result.try(check_keys(entries, ["proto", "peer", "features"]))
  use proto <- result.try(body_int(entries, "hello", "proto"))
  use peer <- result.try(body_string(entries, "hello", "peer"))
  use features <- result.try(body_strings(entries, "hello", "features"))
  Ok(Hello(proto:, peer:, features:))
}

fn decode_exec_start(entries: Entries) -> Result(Body, FrameError) {
  use Nil <- result.try(
    check_keys(entries, ["argv", "env", "cwd", "token", "policy", "limits"]),
  )
  use argv <- result.try(body_strings(entries, "exec_start", "argv"))
  use env_value <- result.try(body_field(entries, "exec_start", "env"))
  use env <- result.try(decode_env(env_value))
  use cwd <- result.try(body_string(entries, "exec_start", "cwd"))
  use token <- result.try(body_binary(entries, "exec_start", "token"))
  use exec_policy <- result.try(case find(entries, "policy") {
    Error(Nil) -> Ok(None)
    Ok(msgpack.NilValue) -> Ok(None)
    Ok(value) ->
      policy.from_msgpack(value)
      |> result.map(Some)
      |> result.map_error(Malformed)
  })
  use limits <- result.try(case find(entries, "limits") {
    Error(Nil) -> Ok(None)
    Ok(msgpack.NilValue) -> Ok(None)
    Ok(value) -> decode_limits(value) |> result.map(Some)
  })
  Ok(ExecStart(argv:, env:, cwd:, policy: exec_policy, token:, limits:))
}

fn decode_env(
  value: MsgPackValue,
) -> Result(List(#(String, String)), FrameError) {
  case value {
    msgpack.MapValue(entries:) -> list.try_map(entries, decode_env_pair)
    msgpack.NilValue -> Ok([])
    _ -> Error(malformed("exec_start.env", "a map of strings", ""))
  }
}

fn decode_env_pair(
  entry: #(MsgPackValue, MsgPackValue),
) -> Result(#(String, String), FrameError) {
  case entry {
    #(msgpack.StringValue(name), msgpack.StringValue(text)) -> Ok(#(name, text))
    _ -> Error(malformed("exec_start.env", "string pairs", ""))
  }
}

fn decode_limits(value: MsgPackValue) -> Result(Limits, FrameError) {
  case value {
    msgpack.MapValue(entries:) -> {
      use Nil <- result.try(
        check_keys(entries, [
          "cpu_s", "wall_s", "mem_bytes", "pids", "fsize_bytes", "output_bytes",
        ]),
      )
      use cpu_s <- result.try(body_int(entries, "limits", "cpu_s"))
      use wall_s <- result.try(body_int(entries, "limits", "wall_s"))
      use mem_bytes <- result.try(body_int(entries, "limits", "mem_bytes"))
      use pids <- result.try(body_int(entries, "limits", "pids"))
      use fsize_bytes <- result.try(body_int(entries, "limits", "fsize_bytes"))
      use output_bytes <- result.try(body_int(entries, "limits", "output_bytes"))
      Ok(policy.Limits(
        cpu_s:,
        wall_s:,
        mem_bytes:,
        pids:,
        fsize_bytes:,
        output_bytes:,
      ))
    }
    _ -> Error(malformed("exec_start.limits", "a map", ""))
  }
}

fn decode_exec_stdin(entries: Entries) -> Result(Body, FrameError) {
  use Nil <- result.try(check_keys(entries, ["data", "eof"]))
  use data <- result.try(body_binary(entries, "exec_stdin", "data"))
  use eof <- result.try(body_bool(entries, "exec_stdin", "eof"))
  Ok(ExecStdin(data:, eof:))
}

fn decode_exec_out(entries: Entries) -> Result(Body, FrameError) {
  use Nil <- result.try(
    check_keys(entries, ["stream", "data", "bytes", "truncated"]),
  )
  use stream_text <- result.try(body_string(entries, "exec_out", "stream"))
  use stream <- result.try(case stream_text {
    "stdout" -> Ok(Stdout)
    "stderr" -> Ok(Stderr)
    other -> Error(malformed("exec_out.stream", "stdout or stderr", other))
  })
  use data <- result.try(body_binary(entries, "exec_out", "data"))
  use bytes <- result.try(body_int(entries, "exec_out", "bytes"))
  use truncated <- result.try(body_bool(entries, "exec_out", "truncated"))
  Ok(ExecOut(stream:, data:, bytes:, truncated:))
}

fn decode_exec_exit(entries: Entries) -> Result(Body, FrameError) {
  use Nil <- result.try(
    check_keys(entries, [
      "code", "signal", "stdout_bytes", "stderr_bytes", "stdout_truncated",
      "stderr_truncated", "enforcement", "degraded", "wall_ms", "timed_out",
      "cancelled",
    ]),
  )
  use code <- result.try(body_int(entries, "exec_exit", "code"))
  use signal <- result.try(body_int(entries, "exec_exit", "signal"))
  use stdout_bytes <- result.try(body_int(entries, "exec_exit", "stdout_bytes"))
  use stderr_bytes <- result.try(body_int(entries, "exec_exit", "stderr_bytes"))
  use stdout_truncated <- result.try(body_bool(
    entries,
    "exec_exit",
    "stdout_truncated",
  ))
  use stderr_truncated <- result.try(body_bool(
    entries,
    "exec_exit",
    "stderr_truncated",
  ))
  use enforcement <- result.try(body_strings(
    entries,
    "exec_exit",
    "enforcement",
  ))
  use degraded <- result.try(body_bool(entries, "exec_exit", "degraded"))
  use wall_ms <- result.try(body_int(entries, "exec_exit", "wall_ms"))
  use timed_out <- result.try(body_bool(entries, "exec_exit", "timed_out"))

  // Required, not optional. A helper that omits it would otherwise read
  // as "not cancelled", which is the same allow-by-absence #54 is about;
  // both ends of this wire ship from one tree.
  use cancelled <- result.try(body_bool(entries, "exec_exit", "cancelled"))
  Ok(ExecExit(
    code:,
    signal:,
    stdout_bytes:,
    stderr_bytes:,
    stdout_truncated:,
    stderr_truncated:,
    enforcement:,
    degraded:,
    wall_ms:,
    timed_out:,
    cancelled:,
  ))
}

fn decode_cap_call(entries: Entries) -> Result(Body, FrameError) {
  use Nil <- result.try(
    check_keys(entries, ["token", "cap", "args", "deadline_ms"]),
  )
  use token <- result.try(body_binary(entries, "cap_call", "token"))
  use cap <- result.try(body_string(entries, "cap_call", "cap"))
  use args <- result.try(body_field(entries, "cap_call", "args"))
  use deadline_ms <- result.try(body_int(entries, "cap_call", "deadline_ms"))
  Ok(CapCall(token:, cap:, args:, deadline_ms:))
}

// Every field is required and there are no defaults, for the reason 006
// gave: both ends of this wire ship from one tree, so an omitted field is
// a bug to name rather than a shape to guess at. `kind` stays a string
// here and becomes a two-variant type at each edge, because the frozen
// wire vocabulary is what this module encodes.
fn decode_hook_call(entries: Entries) -> Result(Body, FrameError) {
  use Nil <- result.try(
    check_keys(entries, ["token", "kind", "name", "args", "deadline_ms"]),
  )
  use token <- result.try(body_binary(entries, "hook_call", "token"))
  use kind <- result.try(body_string(entries, "hook_call", "kind"))
  use name <- result.try(body_string(entries, "hook_call", "name"))
  use args <- result.try(body_field(entries, "hook_call", "args"))
  use deadline_ms <- result.try(body_int(entries, "hook_call", "deadline_ms"))
  Ok(HookCall(token:, kind:, name:, args:, deadline_ms:))
}

// The mirror of `cap_result` minus `usage`: a hook answer reserves no
// budget of its own, because everything an invocation spent it spent
// through the `cap_call`s it made under the invocation's token.
fn decode_hook_result(entries: Entries) -> Result(Body, FrameError) {
  use Nil <- result.try(check_keys(entries, ["ok", "value", "error"]))
  use ok <- result.try(body_bool(entries, "hook_result", "ok"))
  case ok {
    True -> {
      use value <- result.try(body_field(entries, "hook_result", "value"))
      Ok(HookResult(outcome: CapOk(value:)))
    }
    False -> {
      use error_value <- result.try(body_field(entries, "hook_result", "error"))
      use outcome <- result.try(decode_outcome_error(
        error_value,
        "hook_result.error",
      ))
      Ok(HookResult(outcome:))
    }
  }
}

fn decode_cap_result(entries: Entries) -> Result(Body, FrameError) {
  use Nil <- result.try(check_keys(entries, ["ok", "value", "error", "usage"]))
  use ok <- result.try(body_bool(entries, "cap_result", "ok"))
  let usage = case find(entries, "usage") {
    Error(Nil) -> None
    Ok(msgpack.NilValue) -> None
    Ok(value) -> Some(value)
  }
  case ok {
    True -> decode_cap_ok(entries, usage)
    False -> decode_cap_err(entries, usage)
  }
}

fn decode_cap_ok(
  entries: Entries,
  usage: Option(MsgPackValue),
) -> Result(Body, FrameError) {
  use value <- result.try(body_field(entries, "cap_result", "value"))
  Ok(CapResult(outcome: CapOk(value:), usage:))
}

fn decode_cap_err(
  entries: Entries,
  usage: Option(MsgPackValue),
) -> Result(Body, FrameError) {
  use error_value <- result.try(body_field(entries, "cap_result", "error"))
  use outcome <- result.try(decode_outcome_error(
    error_value,
    "cap_result.error",
  ))
  Ok(CapResult(outcome:, usage:))
}

// The `{code, msg}` map both result kinds carry their failure in. Shared
// with the encoder's `outcome_entries` so the two result kinds cannot
// disagree about what a failure looks like.
fn decode_outcome_error(
  value: MsgPackValue,
  place: String,
) -> Result(CapOutcome, FrameError) {
  case value {
    msgpack.MapValue(error_entries) -> {
      use Nil <- result.try(check_keys(error_entries, ["code", "msg"]))
      use code <- result.try(body_string(error_entries, place, "code"))
      use message <- result.try(body_string(error_entries, place, "msg"))
      Ok(CapErr(code:, message:))
    }

    msgpack.NilValue
    | msgpack.BoolValue(..)
    | msgpack.IntValue(..)
    | msgpack.FloatValue(..)
    | msgpack.StringValue(..)
    | msgpack.BinaryValue(..)
    | msgpack.ArrayValue(..) -> Error(malformed(place, "a map", ""))
  }
}

fn decode_error_body(entries: Entries) -> Result(Body, FrameError) {
  use Nil <- result.try(check_keys(entries, ["code", "msg"]))
  use code <- result.try(body_string(entries, "error", "code"))
  use message <- result.try(body_string(entries, "error", "msg"))
  Ok(ErrorBody(code:, message:))
}

// --- incremental deframing ----------------------------------------------

/// A pure incremental deframer: feed it transport chunks with `push`,
/// get complete frames out, with the partial remainder carried inside.
/// Once a fault is seen the deframer is dead — every later push reports
/// the same fault, matching the close-the-channel contract.
pub opaque type Deframer {
  /// Invariant: `buffer` holds bytes after the last complete frame;
  /// `fault`, once set, never clears.
  Deframer(buffer: BitArray, fault: Option(Fault))
}

/// One well-formed inbound frame, or a well-formed frame of an unknown
/// kind (answered in-band, channel kept).
pub type Inbound {
  /// A fully decoded frame.
  Known(frame: Frame)

  /// A structurally valid frame of a kind this broker does not speak.
  UnknownInbound(id: Int, kind: String)
}

/// A channel-fatal condition met while deframing. The caller must close
/// the channel and settle any in-flight effect as an in-band failure.
pub type Fault {
  /// A frame payload failed to parse.
  CorruptFrame(report: CorruptionReport)

  /// The peer speaks a different protocol version.
  VersionMismatch(version: Int)

  /// A length prefix exceeded `max_frame_bytes`.
  OversizedFrame(declared_bytes: Int)
}

/// The outcome of one `push`: the deframer to continue with, the frames
/// completed by this chunk in arrival order, and the fault that ended
/// the stream, if one did. Frames completed before the fault are still
/// delivered.
pub type Pushed {
  Pushed(deframer: Deframer, inbound: List(Inbound), fault: Option(Fault))
}

/// A fresh deframer with an empty carry.
///
/// ## Examples
///
/// ```gleam
/// assert framing.push(framing.deframer(), <<>>).inbound == []
/// ```
///
pub fn deframer() -> Deframer {
  Deframer(buffer: <<>>, fault: None)
}

/// Feeds one transport chunk to the deframer. Pure; chunking never
/// affects the frames produced — pushing a byte stream one byte at a
/// time yields exactly the frames of pushing it whole.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(bytes) =
///   framing.encode(framing.Frame(id: 1, body: framing.Cancel))
/// let pushed = framing.push(framing.deframer(), bytes)
/// assert pushed.inbound
///   == [framing.Known(framing.Frame(id: 1, body: framing.Cancel))]
/// ```
///
pub fn push(deframer: Deframer, bytes: BitArray) -> Pushed {
  case deframer.fault {
    Some(fault) -> Pushed(deframer:, inbound: [], fault: Some(fault))
    None -> {
      let buffer = bit_array.append(deframer.buffer, bytes)
      push_loop(buffer, [])
    }
  }
}

fn push_loop(buffer: BitArray, seen: List(Inbound)) -> Pushed {
  case buffer {
    <<size:size(32), rest:bits>> ->
      case size > max_frame_bytes {
        True -> faulted(buffer, seen, OversizedFrame(declared_bytes: size))
        False ->
          case take_frame(rest, size) {
            // Not enough bytes yet: carry and wait for more.
            Error(Nil) -> carry(buffer, seen)
            Ok(#(payload, remainder)) ->
              push_decoded(buffer, remainder, seen, decode_payload(payload))
          }
      }

    // Fewer than four bytes buffered: carry.
    _ -> carry(buffer, seen)
  }
}

// Applies one decoded payload to the scan. Well-formed but unrecognized
// is not a poisoning fault: the deframer keeps scanning `remainder`
// normally so later, understood frames still arrive — only a genuinely
// broken envelope poisons it via `faulted`, so every subsequent `push`
// reports the same fault instead of resuming the scan, matching the
// close-the-channel contract (spec §3.3 invariant 6). `buffer` (not
// `remainder`) is what a fault carries: once poisoned, `push` never
// looks at the deframer's buffer again, but the field still records the
// scan's position honestly.
fn push_decoded(
  buffer: BitArray,
  remainder: BitArray,
  seen: List(Inbound),
  decoded: Result(Frame, FrameError),
) -> Pushed {
  case decoded {
    Ok(frame) -> push_loop(remainder, [Known(frame:), ..seen])
    Error(UnknownKind(id:, kind:)) ->
      push_loop(remainder, [UnknownInbound(id:, kind:), ..seen])
    Error(Malformed(report:)) -> faulted(buffer, seen, CorruptFrame(report:))
    Error(UnsupportedVersion(version:)) ->
      faulted(buffer, seen, VersionMismatch(version:))
  }
}

// The carry-on-incomplete-data outcome: buffer kept as-is, no fault, the
// frames seen so far in arrival order.
fn carry(buffer: BitArray, seen: List(Inbound)) -> Pushed {
  Pushed(
    deframer: Deframer(buffer:, fault: None),
    inbound: list.reverse(seen),
    fault: None,
  )
}

fn faulted(buffer: BitArray, seen: List(Inbound), fault: Fault) -> Pushed {
  Pushed(
    deframer: Deframer(buffer:, fault: Some(fault)),
    inbound: list.reverse(seen),
    fault: Some(fault),
  )
}

fn take_frame(
  bytes: BitArray,
  size: Int,
) -> Result(#(BitArray, BitArray), Nil) {
  let available = bit_array.byte_size(bytes)
  case available >= size {
    False -> Error(Nil)
    True -> {
      use payload <- result.try(bit_array.slice(from: bytes, at: 0, take: size))
      use remainder <- result.try(bit_array.slice(
        from: bytes,
        at: size,
        take: available - size,
      ))
      Ok(#(payload, remainder))
    }
  }
}

// --- decoding plumbing --------------------------------------------------

type Entries =
  List(#(MsgPackValue, MsgPackValue))

fn malformed(subject: String, expected: String, context: String) -> FrameError {
  Malformed(report: corruption.report(
    at: "broker/framing.decode_payload",
    on: subject,
    expected:,
    context:,
  ))
}

fn envelope_map(value: MsgPackValue) -> Result(Entries, FrameError) {
  case value {
    msgpack.MapValue(entries:) -> Ok(entries)
    _ -> Error(malformed("frame", "a msgpack map envelope", ""))
  }
}

fn body_map(kind: String, value: MsgPackValue) -> Result(Entries, FrameError) {
  case value {
    msgpack.MapValue(entries:) -> Ok(entries)
    _ -> Error(malformed(kind <> ".body", "a msgpack map", ""))
  }
}

// Rejects any key outside `known`. Required keys are enforced by the
// per-field accessors; optional keys (exec_start.policy/limits,
// cap_result.value/error/usage) are simply absent from lookups.
fn check_keys(
  entries: Entries,
  known: List(String),
) -> Result(Nil, FrameError) {
  list.try_each(entries, fn(entry) {
    case entry.0 {
      msgpack.StringValue(key) ->
        case list.contains(known, key) {
          True -> Ok(Nil)
          False -> Error(malformed("frame", "no unknown keys", key))
        }
      _ -> Error(malformed("frame", "string keys", ""))
    }
  })
}

fn find(entries: Entries, key: String) -> Result(MsgPackValue, Nil) {
  list.find_map(entries, fn(entry) {
    case entry.0 == msgpack.StringValue(key) {
      True -> Ok(entry.1)
      False -> Error(Nil)
    }
  })
}

fn envelope_field(
  entries: Entries,
  key: String,
) -> Result(MsgPackValue, FrameError) {
  // map_error, not replace_error: this runs for every field of every
  // frame on the decode path, and `replace_error`'s argument is built on
  // every call whether the key was missing or not (house rule R1).
  find(entries, key)
  |> result.map_error(fn(_) {
    malformed("frame", "required key " <> key, "missing")
  })
}

fn envelope_int(entries: Entries, key: String) -> Result(Int, FrameError) {
  use value <- result.try(envelope_field(entries, key))
  case value {
    msgpack.IntValue(number) -> Ok(number)
    _ -> Error(malformed("frame." <> key, "an integer", ""))
  }
}

fn envelope_string(
  entries: Entries,
  key: String,
) -> Result(String, FrameError) {
  use value <- result.try(envelope_field(entries, key))
  case value {
    msgpack.StringValue(text) -> Ok(text)
    _ -> Error(malformed("frame." <> key, "a string", ""))
  }
}

fn body_field(
  entries: Entries,
  kind: String,
  key: String,
) -> Result(MsgPackValue, FrameError) {
  // map_error, not replace_error — see envelope_field (house rule R1).
  find(entries, key)
  |> result.map_error(fn(_) {
    malformed(kind, "required key " <> key, "missing")
  })
}

fn body_int(
  entries: Entries,
  kind: String,
  key: String,
) -> Result(Int, FrameError) {
  use value <- result.try(body_field(entries, kind, key))
  case value {
    msgpack.IntValue(number) -> Ok(number)
    _ -> Error(malformed(kind <> "." <> key, "an integer", ""))
  }
}

fn body_bool(
  entries: Entries,
  kind: String,
  key: String,
) -> Result(Bool, FrameError) {
  use value <- result.try(body_field(entries, kind, key))
  case value {
    msgpack.BoolValue(flag) -> Ok(flag)
    _ -> Error(malformed(kind <> "." <> key, "a bool", ""))
  }
}

fn body_string(
  entries: Entries,
  kind: String,
  key: String,
) -> Result(String, FrameError) {
  use value <- result.try(body_field(entries, kind, key))
  case value {
    msgpack.StringValue(text) -> Ok(text)
    _ -> Error(malformed(kind <> "." <> key, "a string", ""))
  }
}

// bin on the wire; nil accepted as empty because the Go encoder writes
// nil slices as msgpack nil.
fn body_binary(
  entries: Entries,
  kind: String,
  key: String,
) -> Result(BitArray, FrameError) {
  use value <- result.try(body_field(entries, kind, key))
  case value {
    msgpack.BinaryValue(bytes:) -> Ok(bytes)
    msgpack.NilValue -> Ok(<<>>)
    _ -> Error(malformed(kind <> "." <> key, "a binary", ""))
  }
}

// str array on the wire; nil accepted as empty (Go nil slices).
fn body_strings(
  entries: Entries,
  kind: String,
  key: String,
) -> Result(List(String), FrameError) {
  use value <- result.try(body_field(entries, kind, key))
  case value {
    msgpack.ArrayValue(items:) ->
      list.try_map(items, fn(item) {
        case item {
          msgpack.StringValue(text) -> Ok(text)
          _ -> Error(malformed(kind <> "." <> key, "string elements", ""))
        }
      })
    msgpack.NilValue -> Ok([])
    _ -> Error(malformed(kind <> "." <> key, "an array of strings", ""))
  }
}

// These entry builders retain the ordinary map ordering and field spellings.
fn entry(key: String, value: MsgPackValue) -> #(MsgPackValue, MsgPackValue) {
  #(msgpack.StringValue(key), value)
}

fn map_entries(value: MsgPackValue) -> Entries {
  case value {
    msgpack.MapValue(entries) -> entries
    _ -> []
  }
}

fn input_identity(id: Int, ordinal: Int, frame_id: Int) -> Entries {
  list.append(output_identity(id, ordinal), [
    entry("frame_id", msgpack.IntValue(frame_id)),
  ])
}

fn output_identity(id: Int, ordinal: Int) -> Entries {
  [
    entry("execution_id", msgpack.IntValue(id)),
    entry("ordinal", msgpack.IntValue(ordinal)),
  ]
}

fn mode_name(mode: ProtocolMode) -> String {
  case mode {
    ServerProtocol -> "server_protocol"
    FiniteCollected -> "finite_collected"
  }
}

fn refusal_name(reason: InputRefusal) -> String {
  case reason {
    InputIdentity -> "identity"
    InputSealed -> "sealed"
    InputPending -> "pending"
    InputLimit -> "limit"
    FiniteInput -> "finite_input"
    QueueRejected -> "queue_rejected"
  }
}

fn positive_field(entries: Entries, key: String) -> Result(Int, FrameError) {
  use value <- result.try(body_int(entries, "protocol", key))
  case value > 0 {
    True -> Ok(value)
    False -> Error(malformed("protocol", "positive identity", key))
  }
}

fn decode_protocol_start(entries: Entries) -> Result(Body, FrameError) {
  use mode <- result.try(body_string(entries, "protocol_start", "mode"))
  use mode <- result.try(case mode {
    "server_protocol" -> Ok(ServerProtocol)
    "finite_collected" -> Ok(FiniteCollected)
    _ -> Error(malformed("protocol_start", "closed mode", mode))
  })
  use start <- result.try(
    decode_exec_start(
      list.filter(entries, fn(pair) { pair.0 != msgpack.StringValue("mode") }),
    ),
  )
  case start {
    ExecStart(argv:, env:, cwd:, policy:, token:, limits:) ->
      Ok(ProtocolStart(
        ProtocolRequest(argv, env, cwd, policy, token, limits),
        mode,
      ))
    _ -> Error(malformed("protocol_start", "start fields", "decoder"))
  }
}

fn decode_protocol_input(entries: Entries) -> Result(Body, FrameError) {
  use Nil <- result.try(
    check_keys(entries, ["execution_id", "ordinal", "frame_id", "data", "eof"]),
  )
  use execution_id <- result.try(positive_field(entries, "execution_id"))
  use ordinal <- result.try(positive_field(entries, "ordinal"))
  use frame_id <- result.try(positive_field(entries, "frame_id"))
  use data <- result.try(body_binary(entries, "protocol_input", "data"))
  use eof <- result.try(body_bool(entries, "protocol_input", "eof"))
  case bit_array.byte_size(data) <= 8192 {
    True ->
      Ok(
        ProtocolInput(execution_id, ordinal, frame_id, data, case eof {
          True -> InputEOF
          False -> InputContinues
        }),
      )
    False -> Error(malformed("protocol_input", "8192 byte chunk", "data"))
  }
}

fn decode_input_ack(
  entries: Entries,
  kind: String,
) -> Result(Body, FrameError) {
  let keys = case kind {
    "accepted" -> ["execution_id", "ordinal", "frame_id"]
    _ -> ["execution_id", "ordinal", "frame_id", "reason"]
  }
  use Nil <- result.try(check_keys(entries, keys))
  use execution_id <- result.try(positive_field(entries, "execution_id"))
  use ordinal <- result.try(positive_field(entries, "ordinal"))
  use frame_id <- result.try(positive_field(entries, "frame_id"))
  case kind {
    "accepted" -> Ok(ProtocolInputAccepted(execution_id, ordinal, frame_id))
    _ -> {
      use reason <- result.try(body_string(
        entries,
        "protocol_input_refused",
        "reason",
      ))
      use reason <- result.try(case reason {
        "identity" -> Ok(InputIdentity)
        "sealed" -> Ok(InputSealed)
        "pending" -> Ok(InputPending)
        "limit" -> Ok(InputLimit)
        "finite_input" -> Ok(FiniteInput)
        "queue_rejected" -> Ok(QueueRejected)
        _ -> Error(malformed("protocol_input_refused", "closed reason", reason))
      })
      Ok(ProtocolInputRefused(execution_id, ordinal, frame_id, reason))
    }
  }
}

fn decode_protocol_output(entries: Entries) -> Result(Body, FrameError) {
  use Nil <- result.try(
    check_keys(entries, [
      "execution_id",
      "ordinal",
      "stream",
      "data",
      "bytes",
      "truncated",
    ]),
  )
  use execution_id <- result.try(positive_field(entries, "execution_id"))
  use ordinal <- result.try(positive_field(entries, "ordinal"))
  use out <- result.try(
    decode_exec_out(
      list.filter(entries, fn(pair) {
        pair.0 != msgpack.StringValue("execution_id")
        && pair.0 != msgpack.StringValue("ordinal")
      }),
    ),
  )
  case out {
    ExecOut(stream:, data:, bytes:, truncated:) ->
      case bit_array.byte_size(data) <= 32_768 && bytes >= 0 {
        True ->
          Ok(
            ProtocolOutput(
              execution_id,
              ordinal,
              stream,
              data,
              bytes,
              case truncated {
                True -> OutputTruncated
                False -> OutputComplete
              },
            ),
          )
        False ->
          Error(malformed(
            "protocol_output",
            "bounded cumulative output",
            "data",
          ))
      }
    _ -> Error(malformed("protocol_output", "output fields", "decoder"))
  }
}

fn decode_protocol_consumed(entries: Entries) -> Result(Body, FrameError) {
  use Nil <- result.try(check_keys(entries, ["execution_id", "ordinal"]))
  use execution_id <- result.try(positive_field(entries, "execution_id"))
  use ordinal <- result.try(positive_field(entries, "ordinal"))
  Ok(ProtocolOutputConsumed(execution_id, ordinal))
}

fn decode_terminal(entries: Entries) -> Result(Body, FrameError) {
  case find(entries, "protocol") {
    Error(Nil) -> decode_exec_exit(entries)
    Ok(msgpack.StringValue(value)) -> {
      use disposition <- result.try(case value {
        "complete" -> Ok(ProtocolComplete)
        "failed" -> Ok(ProtocolFailed)
        _ -> Error(malformed("exec_exit", "closed protocol disposition", value))
      })
      use exit <- result.try(
        decode_exec_exit(
          list.filter(entries, fn(pair) {
            pair.0 != msgpack.StringValue("protocol")
          }),
        ),
      )
      Ok(ProtocolExit(ProtocolTerminal(exit), disposition))
    }
    Ok(_) -> Error(malformed("exec_exit", "protocol string", "protocol"))
  }
}

/// The ordinary native terminal inside an opaque checked credited report.
///
/// ## Examples
///
/// `protocol_terminal_body(report)` returns the checked `ExecExit` fields.
pub fn protocol_terminal_body(terminal: ProtocolTerminal) -> Body {
  terminal.exit
}

/// Wraps only an ordinary native exit report for credited terminal encoding.
///
/// ## Examples
///
/// `protocol_terminal(exit)` refuses any body other than `ExecExit`.
pub fn protocol_terminal(exit: Body) -> Result(ProtocolTerminal, FrameError) {
  case exit {
    ExecExit(..) -> Ok(ProtocolTerminal(exit))
    _ -> Error(malformed("exec_exit", "native terminal", "protocol"))
  }
}
