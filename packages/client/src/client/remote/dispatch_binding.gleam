//// Durable owner custody for the remote dispatcher's physical child requests.
////
//// `new` captures one immutable administrative connection and the assembly's
//// trusted preparation, identity and fatal-fence capabilities. `configuration`
//// projects the dispatcher's callbacks without introducing transport, actors or
//// retries. `with_commands` installs explicit closed compiler callbacks over
//// the same owner/scope/prepare/mint, and `is_command_origin` preserves other lanes.
//// Preparation preserves the exact broker-cleared request and actual
//// physical operation/step; a parent ToolKey cannot reconstruct those coordinates.
////
//// Reservation commits a closed envelope containing the owner, full scope,
//// physical operation/step and encoded Prepared before returning a sendable key.
//// Exact retries use the original child UUID. Receipt verifies that same child,
//// ID, scope, operation and prepared digest before committing ordered output and
//// terminal bytes. Only that durable acknowledgement permits DurableReceipt.
////
//// Uncertain I/O leaves the existing reservation retained. There is no separate
//// uncertainty status or reconciliation service here. Cancellation persists the
//// original origin even before reservation; failed persistence invokes the
//// mandatory assembly fence rather than acknowledging a durable cancellation.

import broker/dispatch
import broker/enrollment
import client/remote/command_binding
import client/remote/custodian
import core/ids
import core/msgpack as mp
import core/remote_tool
import executor/remote/beam_endpoint as connection
import executor/remote/dispatcher
import executor/remote/identity
import executor/remote/journal_codec
import executor/remote/wire
import gleam/bit_array
import gleam/option.{None, Some}
import gleam/result
import storage/owner_custody as custody

/// A validated, immutable assembly binding; callbacks cannot replace its scope.
pub opaque type Binding {
  /// Every capability is supplied by trusted owner assembly, outside transport.
  Binding(
    /// The supervised address holding durable outgoing requests and receipts.
    owner: custodian.Handle,
    /// The exact configured connection and administrative session/workspace scope.
    connection: connection.Config,
    /// Materializes explicit stream, lifetime and registration without rewriting clearance.
    prepare: fn(dispatch.Dispatch) -> Result(wire.Prepared, Nil),
    /// Mints a fresh candidate UUID; duplicates retain the original stored UUID.
    mint: fn() -> ids.EntryId,
    /// The local monotonic clock shared with the dispatcher.
    now: fn() -> Int,
    /// Transient execution-handle incarnation, never a durable request identity.
    incarnation: Int,
    /// The bounded live callback window, independent of later recovery.
    reconcile_ms: Int,
    /// Must fence managed dispatch when durable cancellation cannot commit.
    fatal_fence: fn(custody.Error) -> Nil,
  )
}

/// Validates connection coordinates and finite budgets before exposing callbacks.
/// The mandatory fatal fence must disable managed dispatch on storage failure;
/// returning from that callback does not establish durable cancellation.
///
/// ## Examples
///
/// ```gleam
/// // dispatch_binding.new(owner, connection, prepare, mint, now, 1, 5000, fence)
/// // -> Ok(binding), when the provisioned labels and finite budgets agree.
/// ```
pub fn new(
  owner owner: custodian.Handle,
  connection connection: connection.Config,
  prepare prepare: fn(dispatch.Dispatch) -> Result(wire.Prepared, Nil),
  mint mint: fn() -> ids.EntryId,
  now now: fn() -> Int,
  incarnation incarnation: Int,
  reconcile_ms reconcile_ms: Int,
  fatal_fence fatal_fence: fn(custody.Error) -> Nil,
) -> Result(Binding, custody.Error) {
  use Nil <- result.try(
    connection.validate(connection)
    |> result.replace_error(custody.Invalid("invalid remote executor endpoint")),
  )
  case incarnation > 0 && reconcile_ms > 0 && reconcile_ms <= 86_400_000 {
    True ->
      Ok(Binding(
        owner:,
        connection:,
        prepare:,
        mint:,
        now:,
        incarnation:,
        reconcile_ms:,
        fatal_fence:,
      ))
    False -> Error(custody.Invalid("invalid remote dispatch binding"))
  }
}

/// Projects the production callbacks over the same immutable custody binding.
/// This adapter performs no network I/O; the executor dispatcher owns transport.
///
/// ## Examples
///
/// ```gleam
/// // let remote = dispatcher.dispatcher(dispatch_binding.configuration(binding))
/// ```
pub fn configuration(binding: Binding) -> dispatcher.Config {
  dispatcher.Config(
    connection: binding.connection,
    incarnation: binding.incarnation,
    reconcile_ms: binding.reconcile_ms,
    reserve: reserve(binding, _),
    receive: fn(origin, key, digest, outputs, terminal) {
      receive(binding, origin, key, digest, outputs, terminal)
    },
    uncertain: fn(_key, _digest) { Nil },
    cancel_reserved: cancel_reserved(binding, _),
    now: binding.now,
  )
}

/// Adds closed Compile command custody to the original session dispatcher.
/// Missing command custody never falls through to ordinary child reservation.
/// Root assembly retains its one Broker and original PhaseIdentity/clearance;
/// this projection creates no Broker, transport, grants or per-call registry.
/// SatelliteCommand explicitly refuses until its closed Launch assembly exists.
///
/// ## Examples
///
/// ```gleam
/// assert result.is_ok(dispatch_binding.with_commands(binding, enrolled))
/// ```
pub fn with_commands(
  binding: Binding,
  enrolled: enrollment.SessionEnrollment,
) -> Result(dispatcher.Config, custody.Error) {
  use commands <- result.try(command_binding.new(
    binding.owner,
    enrolled,
    binding.connection.scope,
    binding.prepare,
    binding.mint,
  ))
  let original = configuration(binding)
  Ok(
    dispatcher.Config(
      ..original,
      reserve: fn(request) { reserve_with_commands(binding, commands, request) },
      receive: fn(origin, key, digest, outputs, terminal) {
        case is_command_origin(origin) {
          True ->
            command_binding.receive(
              commands,
              origin,
              key,
              digest,
              outputs,
              terminal,
            )
            |> failed
          False -> receive(binding, origin, key, digest, outputs, terminal)
        }
      },
      cancel_reserved: fn(request) {
        cancel_with_commands(binding, commands, request)
      },
    ),
  )
}

fn reserve_with_commands(
  binding: Binding,
  commands: command_binding.Binding,
  request: dispatch.Dispatch,
) -> Result(dispatcher.Reserved, Nil) {
  use origin <- result.try(original_origin(binding, request))
  case is_command_origin(origin) {
    False -> reserve(binding, request)
    True -> {
      case command_binding.reserve(commands, request) {
        Ok(reserved) -> Ok(reserved)
        Error(custody.Missing) -> {
          // Legitimate dispatch starts after offer custody. Missing evidence
          // cannot reconstruct its full service key or permit generic fallback.
          binding.fatal_fence(custody.Missing)
          Error(Nil)
        }
        Error(_) -> Error(Nil)
      }
    }
  }
}

fn cancel_with_commands(
  binding: Binding,
  commands: command_binding.Binding,
  request: dispatch.Dispatch,
) -> Nil {
  let outcome = {
    use origin <- result.try(
      original_origin(binding, request)
      |> result.replace_error(custody.Invalid("missing or foreign child origin")),
    )
    case is_command_origin(origin) {
      True -> command_binding.cancel(commands, origin)
      False -> custodian.cancel_child(binding.owner, origin)
    }
  }
  case outcome {
    Ok(Nil) -> Nil
    Error(error) -> binding.fatal_fence(error)
  }
}

fn is_command_origin(origin: remote_tool.ChildOrigin) -> Bool {
  case remote_tool.child_role(origin) {
    Ok(remote_tool.CompileCommand)
    | Ok(remote_tool.CompileRewriteCommand)
    | Ok(remote_tool.SatelliteCommand) -> True
    Ok(remote_tool.Compile)
    | Ok(remote_tool.CompileRewrite)
    | Ok(remote_tool.Launch)
    | Ok(remote_tool.AdmittedCapability(_, _, _))
    | Ok(remote_tool.Capability(_))
    | Ok(remote_tool.Workspace(_))
    | Error(_) -> False
  }
}

fn reserve(
  binding: Binding,
  request: dispatch.Dispatch,
) -> Result(dispatcher.Reserved, Nil) {
  use origin <- result.try(original_origin(binding, request))
  use prepared <- result.try(binding.prepare(request))
  use Nil <- result.try(
    case
      prepared.request == request.request
      && prepared.step == request.context.step
    {
      True -> Ok(Nil)
      False -> Error(Nil)
    },
  )
  use envelope <- result.try(encode_envelope(
    binding,
    request.context.operation,
    prepared,
  ))

  // The candidate is allocated outside transport. The custodian compares the
  // entire immutable envelope and returns the original UUID on an exact retry.
  let candidate = binding.mint()
  use stored <- result.try(
    custodian.reserve_child(binding.owner, origin, candidate, envelope)
    |> failed,
  )
  use Nil <- result.try(case stored.1 == envelope {
    True -> Ok(Nil)
    False -> Error(Nil)
  })
  use id <- result.try(
    identity.request_id(ids.entry_id_to_string(stored.0)) |> failed,
  )
  Ok(dispatcher.Reserved(
    identity.request_key(
      binding.connection.scope,
      request.context.operation,
      id,
    ),
    prepared,
  ))
}

fn receive(
  binding: Binding,
  origin: remote_tool.ChildOrigin,
  key: identity.RequestKey,
  digest: identity.Digest,
  outputs: List(BitArray),
  terminal: BitArray,
) -> Result(Nil, Nil) {
  use Nil <- result.try(validate_session(binding, origin))
  use stored <- result.try(custodian.child(binding.owner, origin) |> failed)
  use content <- result.try(decode_envelope(binding, stored.1))
  use expected <- result.try(wire.prepared_digest(content.1) |> failed)
  let coordinates = identity.key_fields(key)
  use Nil <- result.try(
    case
      identity.key_scope(key) == binding.connection.scope
      && coordinates.0 == ids.op_id_to_string(content.0)
      && coordinates.1 == ids.entry_id_to_string(stored.0)
      && digest == expected
    {
      True -> Ok(Nil)
      False -> Error(Nil)
    },
  )

  // Receipt bytes retain output ordering and boundaries. A durable commit,
  // including an exact duplicate readback, must finish before success escapes.
  use receipt <- result.try(custodian.receipt(outputs, terminal) |> failed)
  custodian.receive_child(binding.owner, origin, stored.0, receipt) |> failed
}

fn cancel_reserved(binding: Binding, request: dispatch.Dispatch) -> Nil {
  let outcome = {
    use origin <- result.try(
      original_origin(binding, request)
      |> result.replace_error(custody.Invalid("missing or foreign child origin")),
    )
    custodian.cancel_child(binding.owner, origin)
  }
  case outcome {
    Ok(Nil) -> Nil
    Error(error) -> binding.fatal_fence(error)
  }
}

fn original_origin(
  binding: Binding,
  request: dispatch.Dispatch,
) -> Result(remote_tool.ChildOrigin, Nil) {
  use origin <- result.try(case request.context.origin {
    Some(origin) -> Ok(origin)
    None -> Error(Nil)
  })
  use Nil <- result.try(validate_session(binding, origin))
  Ok(origin)
}

fn validate_session(
  binding: Binding,
  origin: remote_tool.ChildOrigin,
) -> Result(Nil, Nil) {
  let scope = identity.scope_fields(binding.connection.scope)
  case ids.session_id_to_string(remote_tool.child_session(origin)) == scope.0 {
    True -> Ok(Nil)
    False -> Error(Nil)
  }
}

fn encode_envelope(
  binding: Binding,
  operation: ids.OpId,
  prepared: wire.Prepared,
) -> Result(BitArray, Nil) {
  use encoded <- result.try(wire.encode_prepared(prepared) |> failed)
  use decoded <- result.try(wire.decode_prepared(encoded) |> failed)
  use Nil <- result.try(case decoded == prepared {
    True -> Ok(Nil)
    False -> Error(Nil)
  })
  use envelope <- result.try(
    wire.encode_value(
      mp.ArrayValue([
        mp.IntValue(1),
        mp.StringValue(binding.connection.owner),
        mp.BinaryValue(journal_codec.binding(binding.connection.scope)),
        mp.StringValue(ids.op_id_to_string(operation)),
        mp.StringValue(prepared.step),
        mp.BinaryValue(encoded),
      ]),
    )
    |> failed,
  )

  // Scope and physical coordinates consume the same existing 128 KiB child
  // allowance. A Prepared that fits alone may still be refused as an envelope.
  case bit_array.byte_size(envelope) <= 131_072 {
    True -> Ok(envelope)
    False -> Error(Nil)
  }
}

fn decode_envelope(
  binding: Binding,
  bytes: BitArray,
) -> Result(#(ids.OpId, wire.Prepared), Nil) {
  use Nil <- result.try(case bit_array.byte_size(bytes) <= 131_072 {
    True -> Ok(Nil)
    False -> Error(Nil)
  })
  use value <- result.try(wire.decode_value(bytes) |> failed)
  use fields <- result.try(case value {
    mp.ArrayValue([
      mp.IntValue(1),
      mp.StringValue(owner),
      mp.BinaryValue(scope),
      mp.StringValue(operation),
      mp.StringValue(step),
      mp.BinaryValue(prepared),
    ]) -> Ok(#(owner, scope, operation, step, prepared))
    _ -> Error(Nil)
  })
  use Nil <- result.try(
    case
      fields.0 == binding.connection.owner
      && fields.1 == journal_codec.binding(binding.connection.scope)
    {
      True -> Ok(Nil)
      False -> Error(Nil)
    },
  )
  use operation <- result.try(ids.parse_op_id(fields.2) |> failed)
  use prepared <- result.try(wire.decode_prepared(fields.4) |> failed)
  use canonical <- result.try(encode_envelope(binding, operation, prepared))
  case fields.3 == prepared.step && canonical == bytes {
    True -> Ok(#(operation, prepared))
    False -> Error(Nil)
  }
}

fn failed(value: Result(a, e)) -> Result(a, Nil) {
  result.replace_error(value, Nil)
}
