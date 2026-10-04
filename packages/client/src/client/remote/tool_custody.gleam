//// Managed remote tools retain their original runtime identity and report.
////
//// `wrap` preserves clearance, replay declaration and scheduling metadata.
//// The owner hashes the runtime's effective arguments and binds the exact
//// configured authority bytes plus original call metadata in the request.
//// `hex` renders the host digest in canonical lowercase form.
//// Recovery never invokes the runner: child-only evidence remains unknown.
//// `custodian` alone owns admission, supervised work and final persistence.

import client/remote/custodian
import core/ids
import core/json
import core/msgpack
import core/remote_tool
import gleam/bit_array
import gleam/option
import gleam/result
import gleam/string
import host/bootstrap
import runtime/effects
import storage/owner_custody

/// Explicit assembly choice, separate from authorization and replay policy.
pub type Mode {
  /// Preserve the existing local surface.
  Local

  /// Every invocation uses the configured owner journal and authority bytes.
  Managed(
    /// The runtime's durable session identity.
    session: ids.SessionId,
    /// Full immutable workspace/authority scope, encoded by owner assembly.
    scope: BitArray,
    /// A reclaimable supervised custodian address.
    owner: custodian.Handle,
  )
}

/// Canonical inputs to an immutable owner reservation.
pub type Invocation {
  /// Constructed from original ToolRun coordinates, never a transport attempt.
  Invocation(
    /// Opaque logical identity passed unchanged to the injected remote runner.
    key: remote_tool.ToolKey,
    /// Canonical effective argument bytes.
    arguments: BitArray,
    /// Exact scope and provider call metadata retained before any remote send.
    request: BitArray,
  )
}

/// Wraps a real runtime surface without changing its authorization metadata.
///
/// ## Examples
///
/// ```gleam
/// // tool_custody.wrap(surface, tool_custody.Managed(session, scope, owner))
/// ```
pub fn wrap(surface: effects.ToolSurface, mode: Mode) -> effects.ToolSurface {
  case mode {
    Local -> surface
    Managed(session, scope, owner) ->
      effects.ToolSurface(
        ..surface,
        run: fn(run) { invoke(owner, session, scope, run) },
        recover: fn(run, _complete) { recover(owner, session, scope, run) },
      )
  }
}

/// Builds the complete immutable identity and bounded request envelope.
/// The digest uses host/bootstrap.sha256 over canonical JSON UTF-8 bytes.
///
/// ## Examples
///
/// ```gleam
/// // tool_custody.invocation(session, immutable_scope, original_run)
/// ```
pub fn invocation(
  session: ids.SessionId,
  scope: BitArray,
  run: effects.ToolRun,
) -> Result(Invocation, String) {
  use Nil <- result.try(bounded(scope, 131_072))
  let arguments =
    run.arguments |> json.canonical |> json.to_string |> bit_array.from_string
  use Nil <- result.try(bounded(arguments, 262_144))
  let digest = arguments |> bootstrap.sha256 |> hex
  use key <- result.try(remote_tool.key(
    session,
    run.operation,
    run.step_id,
    run.source_index,
    digest,
    run.result_entry,
  ))

  // Provider IDs, names and optional metadata are immutable even when the
  // pre-request hook supplied different effective argument bytes.
  let request =
    msgpack.ArrayValue([
      msgpack.BinaryValue(scope),
      msgpack.StringValue(run.strand),
      msgpack.StringValue(run.call.id),
      msgpack.StringValue(run.call.name),
      msgpack.StringValue(json.to_string(json.canonical(run.call.arguments))),
      metadata(run.call.thought_signature),
      metadata(run.call.namespace),
    ])
  use request <- result.try(
    msgpack.encode(request) |> result.replace_error("invalid owner request"),
  )
  use Nil <- result.try(bounded(request, 262_144))
  Ok(Invocation(key:, arguments:, request:))
}

fn invoke(
  owner: custodian.Handle,
  session: ids.SessionId,
  scope: BitArray,
  run: effects.ToolRun,
) -> effects.ToolOutcome {
  let outcome = {
    use invocation <- result.try(invocation(session, scope, run))
    custodian.execute(
      owner,
      invocation.key,
      invocation.arguments,
      invocation.request,
      run,
    )
    |> result.replace_error("managed remote outcome unknown; evidence retained")
  }
  case outcome {
    Ok(outcome) -> outcome
    Error(reason) -> effects.ToolFailed(reason)
  }
}

fn recover(
  owner: custodian.Handle,
  session: ids.SessionId,
  scope: BitArray,
  run: effects.ToolRun,
) -> effects.ToolRecovery {
  let evidence = {
    use invocation <- result.try(invocation(session, scope, run))
    custodian.lookup(
      owner,
      invocation.key,
      invocation.arguments,
      invocation.request,
    )
    |> result.replace_error(
      "managed custody missing, conflicting or unavailable",
    )
  }
  case evidence {
    Ok(owner_custody.FinalOutcome(payload)) ->
      case effects.decode_tool_outcome(owner_custody.bytes(payload)) {
        Ok(outcome) -> effects.RecoveredOutcome(outcome)
        Error(reason) -> effects.UnknownOutcome(reason)
      }
    Ok(owner_custody.AwaitingFinal(..)) ->
      effects.UnknownOutcome(
        "original admission retained without exact final ToolOutcome",
      )
    Ok(owner_custody.Collected) ->
      effects.UnknownOutcome(
        "collected fence requires reserved session entry readback",
      )
    Error(reason) -> effects.UnknownOutcome(reason)
  }
}

fn bounded(bytes: BitArray, maximum: Int) -> Result(Nil, String) {
  case
    bit_array.bit_size(bytes) % 8 == 0 && bit_array.byte_size(bytes) <= maximum
  {
    True -> Ok(Nil)
    False -> Error("owner invocation exceeds byte bound")
  }
}

fn hex(bytes: BitArray) -> String {
  bytes |> bit_array.base16_encode |> string.lowercase
}

fn metadata(value: option.Option(String)) -> msgpack.MsgPackValue {
  case value {
    option.None -> msgpack.NilValue
    option.Some(text) -> msgpack.StringValue(text)
  }
}
