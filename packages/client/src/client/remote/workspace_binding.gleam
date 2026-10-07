//// Durable owner reservation for complete semantic workspace invocations.
////
//// `new` binds one administrative scope, supervised custodian and trusted UUID
//// mint. `reserve` reads retained child identity before encoding a candidate,
//// so retries compare canonical bytes containing the original UUID. Admission
//// commits both those bytes and the full configured result allowance before a
//// sendable Reservation escapes. A concurrent candidate may conflict safely.
////
//// `receive` validates the completion against the retained Request, rechecks
//// the exact original UUID and full invocation, then commits exact completion
//// bytes before creating an Acknowledgement. `recover` reads that same link and
//// optional receipt. Neither path executes tools or reconstructs ToolOutcome;
//// final parent custody stays with the existing custodian.
////
//// Tool calls use their original operation/step and source-index/digest. A
//// distinct Workspace ordinal cannot alias Compile, Launch or Capability.
//// Named system callers retain explicit system origin, without a fake ToolKey.
//// This boundary has no transport or path rewriting. Assembly must bound the
//// number and aggregate bytes of concurrent callers to the custodian mailbox.

import client/remote/custodian
import core/ids
import core/remote_tool
import core/workspace as scope
import gleam/bit_array
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import storage/owner_custody as custody
import tools/workspace
import tools/workspace_codec as codec

/// Immutable authority for one registered session workspace.
pub opaque type Binding {
  /// Trusted construction precedes every reservation or recovery.
  Binding(
    /// Exact host registration and both authority epochs.
    scope: scope.Scope,
    /// The supervised durable owner, independent of a connection.
    owner: custodian.Handle,
    /// Trusted UUIDv7 mint, used only when no child is retained.
    mint: fn() -> ids.EntryId,
  )
}

/// A sendable invocation constructed only after durable owner reservation.
pub opaque type Reservation {
  /// No external constructor can replace expected request or original bytes.
  Reservation(
    /// The owner whose commit permits acknowledgement.
    owner: custodian.Handle,
    /// Original child address and immutable ToolKey or system provenance.
    child: remote_tool.ChildOrigin,
    /// The entire canonical semantic invocation.
    invocation: workspace.Invocation,
    /// Exact durable outgoing bytes, including the reserved UUID.
    bytes: BitArray,
  )
}

/// Authority to acknowledge the digest of an exactly committed completion.
pub opaque type Acknowledgement {
  /// Constructed only after the exact durable child receipt commits.
  Acknowledgement(
    /// Original reserved UUID, never a connection identity.
    request_id: ids.EntryId,
    /// SHA-256 of exact completion bytes retained by the owner.
    digest: BitArray,
  )
}

/// Captures immutable scope and trusted identity capability without performing I/O.
///
/// ## Examples
///
/// `new(scope, owner, mint)` never resolves paths or opens a socket.
pub fn new(
  scope: scope.Scope,
  owner: custodian.Handle,
  mint: fn() -> ids.EntryId,
) -> Binding {
  Binding(scope:, owner:, mint:)
}

/// Commits a full Invocation before returning an opaque sendable reservation.
/// Retained candidates are reconstructed with the original UUID and compared
/// byte for byte; the mint is never called on that retry path.
///
/// ## Examples
///
/// An exact retry returns the original UUID even if the trusted mint would change.
pub fn reserve(
  binding: Binding,
  child: remote_tool.ChildOrigin,
  operation: ids.OpId,
  step: scope.Step,
  origin: workspace.Origin,
  request: workspace.Request,
) -> Result(Reservation, custody.Error) {
  use Nil <- result.try(provenance(
    binding.scope,
    child,
    operation,
    step,
    origin,
  ))
  use retained <- result.try(existing(binding.owner, child))
  let id = case retained {
    Some(row) -> row.0
    None -> binding.mint()
  }
  let invocation =
    workspace.invocation(binding.scope, operation, step, origin, id, request)
  use bytes <- result.try(codec.encode_invocation(invocation) |> codec_error)
  use Nil <- result.try(case retained {
    Some(row) -> equal(bytes, row.1)
    None -> Ok(Nil)
  })

  // SQLite compares ID and content atomically. A race loser cannot use another
  // fresh UUID or normalize a changed candidate into the retained invocation.
  use Nil <- result.try(custodian.reserve_workspace_child(
    binding.owner,
    child,
    id,
    bytes,
  ))
  let reservation = Reservation(binding.owner, child, invocation, bytes)
  use _ <- result.try(recheck(reservation))
  Ok(reservation)
}

/// Converts the actual serialized system admission into its exact reservation.
/// The caller owns the Fresh decision; this helper never allocates or mints.
/// Canonical expected bytes and actual original child readback must agree.
///
/// ## Examples
///
/// `system_reservation(owner, admitted, expected)` refuses a changed Read path.
@internal
pub fn system_reservation(
  owner: custodian.Handle,
  admitted: custody.SystemReservationReadback,
  expected: workspace.Invocation,
) -> Result(Reservation, custody.Error) {
  let #(bound, operation, step, origin, id) =
    workspace.invocation_identity(expected)
  use Nil <- result.try(require(fn() { id == admitted.request_id }))
  use Nil <- result.try(case admitted.payload {
    custody.WorkspaceSystem(_) -> Ok(Nil)
    custody.NativeSystem(_) -> Error(custody.Conflict)
  })
  use Nil <- result.try(provenance(
    bound,
    admitted.origin,
    operation,
    step,
    origin,
  ))
  use bytes <- result.try(codec.encode_invocation(expected) |> codec_error)
  let reservation = Reservation(owner, admitted.origin, expected, bytes)
  use _ <- result.try(recheck(reservation))
  Ok(reservation)
}

/// Rechecks the exact original UUID and canonical request before reading receipt.
/// This projects existing custody without creating an acknowledgement.
///
/// ## Examples
///
/// `retained_completion(reserved)` returns `Ok(None)` before receipt custody.
@internal
pub fn retained_completion(
  reserved: Reservation,
) -> Result(Option(BitArray), custody.Error) {
  recheck(reserved)
}

/// Projects original system provenance for the registered receipt continuation.
/// Tool and derived workspace-command origins cannot enter this path.
///
/// ## Examples
///
/// `system_origin(reserved)` supplies the same original used during admission.
@internal
pub fn system_origin(
  reserved: Reservation,
) -> Result(remote_tool.ChildOrigin, custody.Error) {
  case remote_tool.child_fields(reserved.child) {
    remote_tool.SystemFields(_, _, _) -> Ok(reserved.child)
    remote_tool.ToolFields(_, _) | remote_tool.WorkspaceCommandFields(_, _) ->
      Error(custody.Conflict)
  }
}

/// Projects exactly the stored Invocation for a future bounded semantic sender.
///
/// ## Examples
///
/// `invocation(reserved)` contains the original request UUID and bound scope.
pub fn invocation(reserved: Reservation) -> workspace.Invocation {
  reserved.invocation
}

/// Projects the exact retained canonical bytes without recomputing identity.
///
/// ## Examples
///
/// `content(reserved)` is the complete outgoing content for a future transport.
pub fn content(reserved: Reservation) -> BitArray {
  reserved.bytes
}

/// Validates response projection and commits exact completion before granting ACK.
/// A changed receipt conflicts; any failed read or write remains uncertainty.
///
/// ## Examples
///
/// Calling `receive(reserved, bytes)` twice with identical bytes is idempotent.
pub fn receive(
  reserved: Reservation,
  completion: BitArray,
) -> Result(Acknowledgement, custody.Error) {
  use _ <- result.try(
    codec.decode_completion(workspace.request(reserved.invocation), completion)
    |> codec_error,
  )
  use _ <- result.try(recheck(reserved))
  let #(_, _, _, _, id) = workspace.invocation_identity(reserved.invocation)

  // This ask is the custody transfer. A timeout or SQLite refusal grants no
  // acknowledgement, even when the executor may already have performed work.
  use Nil <- result.try(custodian.receive_workspace_child(
    reserved.owner,
    reserved.child,
    id,
    completion,
  ))
  Ok(Acknowledgement(id, bootstrap.sha256(completion)))
}

/// Projects the original UUID and exact result digest for executor journal ACK.
///
/// ## Examples
///
/// `acknowledgement(received)` supplies data; only `receive` creates authority.
pub fn acknowledgement(ack: Acknowledgement) -> #(ids.EntryId, BitArray) {
  #(ack.request_id, ack.digest)
}

/// Reads the retained original invocation and exact optional completion.
/// Recovery validates content and provenance but never executes a tool body.
/// Recovered receipts can be passed to `receive` for an idempotent durable ACK.
///
/// ## Examples
///
/// `recover(binding, child)` retains the same request UUID after custodian reopen.
pub fn recover(
  binding: Binding,
  child: remote_tool.ChildOrigin,
) -> Result(#(Reservation, Option(BitArray)), custody.Error) {
  use row <- result.try(custodian.child(binding.owner, child))
  use invocation <- result.try(codec.decode_invocation(row.1) |> codec_error)
  let #(stored_scope, operation, step, origin, id) =
    workspace.invocation_identity(invocation)
  use Nil <- result.try(
    require(fn() { stored_scope == binding.scope && id == row.0 }),
  )
  use Nil <- result.try(provenance(
    binding.scope,
    child,
    operation,
    step,
    origin,
  ))
  use Nil <- result.try(case row.2 {
    None -> Ok(Nil)
    Some(bytes) ->
      codec.decode_completion(workspace.request(invocation), bytes)
      |> codec_error
      |> result.replace(Nil)
  })
  Ok(#(Reservation(binding.owner, child, invocation, row.1), row.2))
}

fn existing(owner: custodian.Handle, child: remote_tool.ChildOrigin) {
  case custodian.child(owner, child) {
    Ok(row) -> Ok(Some(row))
    Error(custody.Missing) -> Ok(None)
    Error(error) -> Error(error)
  }
}

fn recheck(reserved: Reservation) {
  use row <- result.try(custodian.child(reserved.owner, reserved.child))
  let #(_, _, _, _, id) = workspace.invocation_identity(reserved.invocation)
  use Nil <- result.try(require(fn() { row.0 == id }))
  use Nil <- result.try(equal(row.1, reserved.bytes))
  Ok(row.2)
}

fn provenance(
  bound: scope.Scope,
  child: remote_tool.ChildOrigin,
  operation: ids.OpId,
  step: scope.Step,
  origin: workspace.Origin,
) -> Result(Nil, custody.Error) {
  let #(session, _) = scope.scope_fields(bound)
  use Nil <- result.try(
    require(fn() { remote_tool.child_session(child) == session }),
  )
  case origin {
    workspace.Tool(source) -> {
      use key <- result.try(remote_tool.child_tool(child) |> conflict)
      use role <- result.try(remote_tool.child_role(child) |> conflict)
      use Nil <- result.try(case role {
        remote_tool.Workspace(_)
        | remote_tool.AdmittedCapability(_, _, remote_tool.SemanticWorkspace) ->
          Ok(Nil)
        remote_tool.Compile
        | remote_tool.CompileRewrite
        | remote_tool.CompileRewriteCommand
        | remote_tool.Launch
        | remote_tool.CompileCommand
        | remote_tool.SatelliteCommand
        | remote_tool.Capability(_)
        | remote_tool.AdmittedCapability(_, _, remote_tool.NativeCommand) ->
          Error(custody.Conflict)
      })
      let #(index, digest) = workspace.tool_origin_fields(source)
      let hex = digest |> bit_array.base16_encode |> string.lowercase
      require(fn() {
        remote_tool.operation(key) == operation
        && remote_tool.step(key) == scope.step_string(step)
        && remote_tool.provenance(key) == #(index, hex)
      })
    }
    workspace.System(caller) -> {
      use Nil <- result.try(case remote_tool.child_fields(child) {
        remote_tool.SystemFields(_, _, _) -> Ok(Nil)
        remote_tool.ToolFields(_, _)
        | remote_tool.WorkspaceCommandFields(_, _) -> Error(custody.Conflict)
      })
      use expected <- result.try(
        remote_tool.system_child(session, system_service(caller), 0)
        |> conflict,
      )
      require(fn() {
        remote_tool.child_parent(child) == remote_tool.child_parent(expected)
      })
    }
  }
}

fn system_service(caller: workspace.SystemCaller) -> String {
  case caller {
    workspace.CommandPreparation -> "command-preparation"
    workspace.Compiler -> "compiler"
    workspace.SatelliteLaunch -> "satellite-launch"
    workspace.LanguageServer -> "lsp"
    workspace.WorktreeObservation -> "worktree-observation"
    workspace.WorkspaceAdministration -> "workspace-administration"
  }
}

fn require(condition: fn() -> Bool) -> Result(Nil, custody.Error) {
  case condition() {
    True -> Ok(Nil)
    False -> Error(custody.Conflict)
  }
}

fn equal(expected: BitArray, actual: BitArray) -> Result(Nil, custody.Error) {
  case expected == actual {
    True -> Ok(Nil)
    False -> Error(custody.Conflict)
  }
}

fn codec_error(value: Result(a, codec.CodecError)) -> Result(a, custody.Error) {
  result.replace_error(value, custody.Invalid("invalid workspace content"))
}

fn conflict(value: Result(a, e)) -> Result(a, custody.Error) {
  result.replace_error(value, custody.Conflict)
}
