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
import client/remote/native_envelope
import client/remote/workspace_command_binding
import core/generation
import core/ids
import core/msgpack as mp
import core/remote_tool
import core/workspace
import executor/remote/beam_endpoint as connection
import executor/remote/dispatcher
import executor/remote/identity
import executor/remote/wire
import gleam/bit_array
import gleam/option.{type Option, None, Some}
import gleam/result
import storage/owner_custody as custody

/// A validated, immutable assembly binding; callbacks cannot replace its scope.
pub opaque type Binding {
  /// Every capability is supplied by trusted owner assembly, outside transport.
  Binding(
    /// The supervised address holding durable outgoing requests and receipts.
    owner: custodian.Handle,
    /// Registered dispatch retains the original verified bundle, never latest lookup.
    registered: Option(
      #(generation.GenerationAssociation, enrollment.SessionEnrollment),
    ),
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
        registered: None,
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

/// Captures the original ready registered owner before constructing dispatch.
/// HistoryOnly cannot supply this opaque value; activation remains an assembly step.
/// The connection must name exactly this association's scope and generation.
///
/// ## Examples
///
/// `new_registered(ready, connection, prepare, mint, now, 1, 5000, fence)` creates no Broker.
pub fn new_registered(
  owner: custodian.RegisteredOwner,
  connection: connection.Config,
  prepare: fn(dispatch.Dispatch) -> Result(wire.Prepared, Nil),
  mint: fn() -> ids.EntryId,
  now: fn() -> Int,
  incarnation: Int,
  reconcile_ms: Int,
  fatal_fence: fn(custody.Error) -> Nil,
) -> Result(Binding, custody.Error) {
  let #(pinned, pin, associated) = custodian.registered_fields(owner)
  let #(scope, _, number) =
    generation.key_fields(generation.association_key(associated))
  let #(session, name, executor, session_epoch, workspace_epoch) =
    identity.scope_fields(connection.scope)
  use projected <- result.try(
    workspace.scope_from_fields(
      session,
      name,
      executor,
      session_epoch,
      workspace_epoch,
    )
    |> result.replace_error(custody.Conflict),
  )
  use Nil <- result.try(
    case projected == scope && number == connection.generation {
      True -> Ok(Nil)
      False -> Error(custody.Conflict)
    },
  )
  use enrolled <- result.try(
    enrollment.decode(custody.enrollment_fields(pin).4)
    |> result.replace_error(custody.Conflict),
  )
  use binding <- result.try(new(
    pinned,
    connection,
    prepare,
    mint,
    now,
    incarnation,
    reconcile_ms,
    fatal_fence,
  ))
  Ok(Binding(..binding, registered: Some(#(associated, enrolled))))
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
  use Nil <- result.try(case binding.registered {
    None -> Ok(Nil)
    Some(#(_, original)) ->
      enrollment.matches(original, enrolled)
      |> result.replace_error(custody.Conflict)
  })
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

/// Installs finite Git recipes beside the existing Compile/Launch/system lanes.
/// Only trusted executor assembly supplies the resolved enrolled executable.
///
/// ## Examples
///
/// `with_workspace_commands(binding, enrolled, git)` keeps Initialize disabled.
pub fn with_workspace_commands(
  binding: Binding,
  enrolled: enrollment.SessionEnrollment,
  git: String,
) -> Result(dispatcher.Config, custody.Error) {
  use associated <- result.try(option.to_result(
    binding.registered,
    custody.Frozen,
  ))
  use Nil <- result.try(
    enrollment.matches(associated.1, enrolled)
    |> result.replace_error(custody.Conflict),
  )
  use commands <- result.try(workspace_command_binding.new(
    binding.owner,
    enrolled,
    binding.connection.owner,
    binding.connection.scope,
    git,
    binding.prepare,
    binding.mint,
  ))
  use original <- result.try(with_commands(binding, enrolled))
  Ok(
    dispatcher.Config(
      ..original,
      reserve: fn(request: dispatch.Dispatch) {
        use origin <- result.try(option.to_result(request.context.origin, Nil))
        use semantic <- result.try(workspace_capability_route(binding, origin))
        case semantic {
          True -> workspace_command_binding.reserve(commands, request)
          False -> original.reserve(request)
        }
      },
      receive: fn(origin, key, digest, outputs, terminal) {
        use semantic <- result.try(workspace_receipt_route(binding, origin))
        case semantic {
          True ->
            workspace_command_binding.receive(
              commands,
              origin,
              key,
              digest,
              outputs,
              terminal,
            )
          False -> original.receive(origin, key, digest, outputs, terminal)
        }
      },
    ),
  )
}

fn workspace_capability_route(
  binding: Binding,
  origin: remote_tool.ChildOrigin,
) -> Result(Bool, Nil) {
  case remote_tool.child_fields(origin) {
    remote_tool.ToolFields(
      key,
      remote_tool.AdmittedCapability(name, ordinal, remote_tool.NativeCommand),
    ) -> {
      use parent <- result.try(
        remote_tool.tool_child(
          key,
          remote_tool.AdmittedCapability(
            name,
            ordinal,
            remote_tool.SemanticWorkspace,
          ),
        )
        |> failed,
      )

      // Only absent semantic evidence identifies ordinary proc.run. Existing
      // malformed bytes or a cancellation fence must never open that lane.
      case custodian.child(binding.owner, parent) {
        Ok(_) -> Ok(True)
        Error(custody.Missing) -> Ok(False)
        Error(_) -> Error(Nil)
      }
    }
    remote_tool.WorkspaceCommandFields(_, _) ->
      Ok(workspace_command_binding.is_origin(origin))
    remote_tool.ToolFields(_, _) | remote_tool.SystemFields(_, _, _) ->
      Ok(False)
  }
}

fn workspace_receipt_route(
  binding: Binding,
  origin: remote_tool.ChildOrigin,
) -> Result(Bool, Nil) {
  case remote_tool.child_fields(origin) {
    remote_tool.ToolFields(
      _,
      remote_tool.AdmittedCapability(_, _, remote_tool.NativeCommand),
    ) -> {
      use stored <- result.try(custodian.child(binding.owner, origin) |> failed)
      use Nil <- result.try(case bit_array.byte_size(stored.1) <= 131_072 {
        True -> Ok(Nil)
        False -> Error(Nil)
      })
      use value <- result.try(wire.decode_value(stored.1) |> failed)

      // Historical custody chooses the decoder. Later semantic evidence cannot
      // reinterpret an already retained ordinary native envelope.
      case value {
        mp.ArrayValue([
          mp.IntValue(1),
          mp.StringValue("workspace-native"),
          _,
          _,
          _,
          _,
          _,
          _,
        ]) -> Ok(True)
        _ -> Ok(False)
      }
    }
    remote_tool.WorkspaceCommandFields(_, _) ->
      Ok(workspace_command_binding.is_origin(origin))
    remote_tool.ToolFields(_, _) | remote_tool.SystemFields(_, _, _) ->
      Ok(False)
  }
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
      False -> cancel_original(binding, request, origin)
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
  // A failed static projection must not leave the original one-use permission
  // available for a later attempt. Only this binding's original subject and
  // context origin may close that permission; a foreign binding's refusal must
  // leave the actual original permission usable. Its durable charge remains.
  let outcome = reserve_checked(binding, request)
  case outcome, request.system_reservation {
    Error(Nil), Some(_) -> {
      let _closed = {
        use origin <- result.try(original_origin(binding, request))
        cancel_original(binding, request, origin) |> failed
      }
      outcome
    }
    _, _ -> outcome
  }
}

fn reserve_checked(
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
  use envelope <- result.try(case request.system_reservation {
    None -> encode_envelope(binding, request.context.operation, prepared)
    Some(_) ->
      native_envelope.encode_cleared(
        binding.connection.owner,
        binding.connection.scope,
        request.context.operation,
        prepared,
        request.deadline_ms,
      )
  })

  case request.system_reservation {
    Some(ref) ->
      reserve_system(binding, request, origin, ref, prepared, envelope)
    None -> reserve_ordinary(binding, origin, request, prepared, envelope)
  }
}

fn reserve_system(
  binding: Binding,
  request: dispatch.Dispatch,
  origin: remote_tool.ChildOrigin,
  ref: dispatch.SystemReservationRef,
  prepared: wire.Prepared,
  envelope: BitArray,
) -> Result(dispatcher.Reserved, Nil) {
  use _ <- result.try(option.to_result(binding.registered, Nil))
  use Nil <- result.try(
    custodian.system_ref_matches(binding.owner, ref) |> failed,
  )
  let #(_, _, expected, uuid) = dispatch.system_reservation_fields(ref)
  use Nil <- result.try(case origin == expected {
    True -> Ok(Nil)
    False -> Error(Nil)
  })
  let actual =
    dispatch.ClearedSystemCommand(
      request.request,
      request.context.operation,
      request.context.step,
      request.deadline_ms,
      request.caller,
    )
  use stored <- result.try(dispatch.reserve_system(ref, actual, envelope, 5000))
  use Nil <- result.try(case stored == #(uuid, envelope) {
    True -> Ok(Nil)
    False -> Error(Nil)
  })
  use id <- result.try(
    identity.request_id(ids.entry_id_to_string(uuid)) |> failed,
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

fn reserve_ordinary(
  binding: Binding,
  origin: remote_tool.ChildOrigin,
  request: dispatch.Dispatch,
  prepared: wire.Prepared,
  envelope: BitArray,
) -> Result(dispatcher.Reserved, Nil) {
  use Nil <- result.try(
    case remote_tool.child_fields(origin), binding.registered {
      remote_tool.WorkspaceCommandFields(_, _), _ -> Error(Nil)
      remote_tool.SystemFields(_, _, _), Some(_) -> Error(Nil)
      _, _ -> Ok(Nil)
    },
  )

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
  use Nil <- result.try(
    custodian.receive_child(binding.owner, origin, stored.0, receipt) |> failed,
  )
  case binding.registered {
    None -> Ok(Nil)
    Some(#(associated, _)) -> {
      use readback <- result.try(
        custodian.receipt_generation(binding.owner, origin, stored.0) |> failed,
      )
      case readback == #(receipt, associated) {
        True -> Ok(Nil)
        False -> Error(Nil)
      }
    }
  }
}

fn cancel_reserved(binding: Binding, request: dispatch.Dispatch) -> Nil {
  let outcome = {
    use origin <- result.try(
      original_origin(binding, request)
      |> result.replace_error(custody.Invalid("missing or foreign child origin")),
    )
    cancel_original(binding, request, origin)
  }
  case outcome {
    Ok(Nil) -> Nil
    Error(error) -> binding.fatal_fence(error)
  }
}

fn cancel_original(
  binding: Binding,
  request: dispatch.Dispatch,
  origin: remote_tool.ChildOrigin,
) -> Result(Nil, custody.Error) {
  case request.system_reservation {
    Some(ref) -> {
      use Nil <- result.try(custodian.system_ref_matches(binding.owner, ref))
      let #(_, _, expected, _) = dispatch.system_reservation_fields(ref)
      use Nil <- result.try(case expected == origin {
        True -> Ok(Nil)
        False -> Error(custody.Conflict)
      })
      dispatch.cancel_system(ref, 5000) |> result.replace_error(custody.Frozen)
    }
    None ->
      case remote_tool.child_fields(origin), binding.registered {
        remote_tool.SystemFields(_, _, _), Some(_) -> Error(custody.Frozen)
        _, _ -> custodian.cancel_child(binding.owner, origin)
      }
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
  native_envelope.encode(
    binding.connection.owner,
    binding.connection.scope,
    operation,
    prepared,
  )
}

fn decode_envelope(
  binding: Binding,
  bytes: BitArray,
) -> Result(#(ids.OpId, wire.Prepared), Nil) {
  native_envelope.decode(
    binding.connection.owner,
    binding.connection.scope,
    bytes,
  )
}

fn failed(value: Result(a, e)) -> Result(a, Nil) {
  result.replace_error(value, Nil)
}
