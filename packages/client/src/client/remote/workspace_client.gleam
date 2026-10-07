//// Concrete owner consumer for bounded semantic workspace exchanges.
////
//// `new` checks the complete endpoint scope before constructing the durable
//// binding. `invoke` reserves canonical bytes before Submit can reach TLS;
//// `recover` only observes the original request. Neither path mints a retry ID.
//// A recovered Accepted request remains pending until a future explicit resume
//// authority exists, including when a crash happened before its first Submit.
////
//// `settle` transfers exact completion custody before ACK. A retained receipt
//// can answer even when the executor is unavailable. ACK uncertainty describes
//// executor collection only: it never erases a usable owner completion. An
//// executor ACK without an owner receipt is an invariant failure, never replay.
//// Final parent ToolOutcome custody still belongs to the existing custodian.
////
//// `new_system` retains actual original registered authority and selected route.
//// `system_read_plan` fixes a complete Read/Text intent before admission, and
//// `invoke_system` alone joins actual Fresh admission to the first Submit.
//// `verify_system_intent` compares that whole plan before `admit_system` calls
//// the serialized writer through the pure `encode_system_read` encoder.
//// `verify_registered_receipt` compares exact bytes and original association
//// before ACK or Completed. Retained admission observes without re-execution.
////
//// One managed task bounds owner storage, codecs and all exchanges together.
//// Exchanges also subtract elapsed monotonic time from the same finite budget.
//// Polling uses weft; expiry grants no fresh effect identity. Assembly MUST cap
//// simultaneous invocations at four. This module has one synchronous exchange
//// per caller, not a global admission actor. Owner quotas bound durable retained
//// bytes separately; these bounds do not claim a resident-memory ceiling.

import client/daemon/deployment
import client/remote/custodian
import client/remote/workspace_binding as binding
import core/generation
import core/ids
import core/msgpack as mp
import core/remote_tool
import core/workspace as scope
import executor/remote/beam_endpoint as connection
import executor/remote/distribution
import executor/remote/identity
import executor/remote/internal/beam_protocol as transport
import executor/remote/workspace_journal as journal
import gleam/bit_array
import gleam/int
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import storage/owner_custody as custody
import tools/workspace
import tools/workspace_codec as codec
import tools/workspace_local as local
import weft
import weft/poll

/// One immutable workspace binding and its checked concrete TLS endpoint.
pub opaque type Config {
  /// Created only after full-scope and finite transport validation.
  Config(
    /// Durable identity and receipt authority for the exact configured scope.
    binding: binding.Binding,
    /// Endpoint retained so each exchange can deduct elapsed call time.
    endpoint: connection.Config,
    /// Finite total reconciliation budget, in monotonic milliseconds.
    within_ms: Int,
  )
}

/// Original registered authority for closed workspace-administration reads.
/// Construction proves immutable identity, not executor activation.
@internal
pub opaque type SystemConfig {
  /// No caller can replace this original owner or selected endpoint.
  SystemConfig(
    /// Actual original pinned custodian; it cannot follow a reopened actor.
    owner: custodian.Handle,
    /// Full committed original association, never latest generation.
    association: generation.GenerationAssociation,
    /// Immutable administrative snapshot retained for fresh-send revalidation.
    table: deployment.Table,
    /// Original canonical enrollment checked against the selected route.
    pin: deployment.PinnedEnrollment,
    /// Concrete endpoint with exact scope and generation.
    endpoint: connection.Config,
    /// Existing assembly profile for pure encoding preflight only.
    limits: custody.Limits,
    /// Finite whole observation budget, within the fixed plan deadline.
    within_ms: Int,
  )
}

/// Complete fixed read selection retained before any child allocation.
@internal
pub opaque type SystemReadPlan {
  /// A plan grants no live permission and cannot manufacture Fresh.
  SystemReadPlan(
    /// Full original scope and original owner-use identity.
    association: generation.GenerationAssociation,
    /// Already durable caller address, fixed before admission.
    address: String,
    /// Original operation belonging to this administration occurrence.
    operation: ids.OpId,
    /// Original closed phase belonging to this administration occurrence.
    step: scope.Step,
    /// Once-retained UUID, never minted during invocation or retry.
    request_id: ids.EntryId,
    /// Checked executor-relative path; never opened on the owner.
    path: scope.RelativePath,
    /// Original live-incarnation monotonic deadline, never renewed.
    deadline_ms: Int,
    /// Canonical complete bounded intent metadata, containing no source body.
    bytes: BitArray,
  )
}

/// System errors preserve the caller's original retained intent for observation.
@internal
pub type SystemError {
  /// Fixed plan or retained intent disagrees before any admission or transport.
  InvalidSystemPlan

  /// Observation expired; an admission or receipt may already be durable.
  SystemObservationExpired

  /// The bounded observer died without reporting authoritative evidence.
  SystemObservationLost

  /// Original custody could not establish exact admission or readback.
  SystemOwnerUnavailable(
    /// Failure does not grant permission to submit or allocate a replacement.
    reason: custody.Error,
  )
}

// The ordinary consumer needs no association. Registered settlement retains only
// the original receipt writer and expected complete association, not a callback.
type ReceiptAuthority {
  Ordinary
  Registered(custodian.Handle, generation.GenerationAssociation)
}

type Consumer {
  Consumer(endpoint: connection.Config, authority: ReceiptAuthority)
}

/// Construction fails before reservation or any network activity.
pub type ConfigurationError {
  /// Endpoint scope or transport settings do not match the owner binding.
  InvalidConfiguration
}

/// Failed observation retains the logical child for durable reconciliation.
pub type Error {
  /// The whole-call deadline ended observation, not a queued custody write.
  ObservationExpired(
    /// Recover this original child; expiry grants no replacement identity.
    child: remote_tool.ChildOrigin,
  )

  /// The observer crashed without reporting an authoritative outcome.
  ObservationLost(
    /// Recover this original child; observer death is not effect refusal.
    child: remote_tool.ChildOrigin,
  )

  /// A read or reservation failed; a timed-out reservation may have committed.
  OwnerUnavailable(
    /// The original child to recover, without minting replacement identity.
    child: remote_tool.ChildOrigin,
    /// Exact custody failure, without converting it to a start refusal.
    reason: custody.Error,
  )
}

/// Executor collection evidence is separate from owner completion custody.
pub type AckState {
  /// Executor reported the exact durable owner's receipt digest.
  Confirmed

  /// Owner completion is durable; executor collection was not confirmed.
  Retained
}

/// A bounded observation can preserve different kinds of uncertainty.
pub type PendingReason {
  /// No exact terminal evidence was available within the call budget.
  AwaitingEvidence

  /// A concrete exchange failed after transmission could have become possible.
  TransportUncertain

  /// Exact completion was seen, but owner durable receipt was not established.
  ReceiptUncertain
}

/// Every post-reservation answer keeps evidence without authorizing replay.
pub type Outcome {
  /// A validated completion already has durable owner custody.
  Completed(
    /// Existing semantic result, directly usable by future tool consumers.
    completion: Result(local.Completed, workspace.ServiceError),
    /// Whether executor payload collection was reconciled.
    acknowledgement: AckState,
  )

  /// Original identity remains available for future observation.
  Pending(
    /// Exact durable request; callers must recover this identity.
    reservation: binding.Reservation,
    /// The last bounded observation's uncertainty.
    reason: PendingReason,
  )

  /// Durable executor cancellation before a first claim fences this request.
  Cancelled(
    /// The retained identity must never be replaced or submitted anew.
    reservation: binding.Reservation,
  )

  /// Executor collected a receipt the owner cannot establish, or ACK disagreed.
  InvariantFailure(
    /// Original reservation remains the only permissible reconciliation target.
    reservation: binding.Reservation,
  )
}

/// Binds full owner scope to one validated endpoint without performing effects.
///
/// ## Examples
///
/// A different workspace epoch returns `Error(InvalidConfiguration)`.
pub fn new(
  bound: scope.Scope,
  owner: custodian.Handle,
  mint: fn() -> ids.EntryId,
  endpoint: connection.Config,
  within_ms: Int,
) -> Result(Config, ConfigurationError) {
  let fields = identity.scope_fields(endpoint.scope)
  use semantic <- result.try(
    scope.scope_from_fields(fields.0, fields.1, fields.2, fields.3, fields.4)
    |> result.replace_error(InvalidConfiguration),
  )
  use _ <- result.try(
    connection.validate(endpoint) |> result.replace_error(InvalidConfiguration),
  )
  case
    semantic == bound
    && within_ms > 0
    && within_ms <= 30_000
    && endpoint.within_ms <= within_ms
  {
    True -> Ok(Config(binding.new(bound, owner, mint), endpoint, within_ms))
    False -> Error(InvalidConfiguration)
  }
}

/// Reserves exact original content before a possible first submission.
/// Existing child content must compare exactly before any network observation.
///
/// ## Examples
///
/// An exact retry returns retained completion or observes its original UUID.
pub fn invoke(
  config: Config,
  child: remote_tool.ChildOrigin,
  operation: ids.OpId,
  step: scope.Step,
  origin: workspace.Origin,
  request: workspace.Request,
) -> Result(Outcome, Error) {
  use deadline <- bounded(config, child)
  let consumer = Consumer(config.endpoint, Ordinary)
  use retained <- result.try(
    existing(config.binding, child) |> owner_error(child),
  )
  use reservation <- result.try(
    binding.reserve(config.binding, child, operation, step, origin, request)
    |> owner_error(child),
  )
  case retained {
    Some(#(_, Some(bytes))) ->
      Ok(retained_receipt(consumer, reservation, bytes, deadline))
    Some(#(_, None)) -> Ok(observe(consumer, child, reservation, deadline))
    None -> {
      // A concurrent reservation may have won after the read. Submit still uses
      // exactly its retained UUID; the executor journal grants only one claim.
      let submitted =
        exchange(consumer, reservation, transport.Submit, deadline)
      Ok(await_status(consumer, child, reservation, submitted, deadline))
    }
  }
}

/// Observes retained invocation and receipt without submitting or minting an ID.
///
/// ## Examples
///
/// A recovered Started request returns evidence or explicit bounded uncertainty.
pub fn recover(
  config: Config,
  child: remote_tool.ChildOrigin,
) -> Result(Outcome, Error) {
  use deadline <- bounded(config, child)
  let consumer = Consumer(config.endpoint, Ordinary)
  use retained <- result.try(
    binding.recover(config.binding, child) |> owner_error(child),
  )
  let #(reservation, receipt) = retained
  Ok(case receipt {
    Some(bytes) -> retained_receipt(consumer, reservation, bytes, deadline)
    None -> observe(consumer, child, reservation, deadline)
  })
}

/// Captures the actual original registered owner and immutable selected endpoint.
/// The supplied Limits only preflight the pure encoder; the serialized owner
/// independently enforces its own retained quota during admission.
///
/// ## Examples
///
/// `new_system(ready, table, endpoint, limits, 5000)` performs no exchange.
@internal
pub fn new_system(
  owner: custodian.RegisteredOwner,
  table: deployment.Table,
  endpoint: connection.Config,
  limits: custody.Limits,
  within_ms: Int,
) -> Result(SystemConfig, ConfigurationError) {
  let #(original, stored, associated) = custodian.registered_fields(owner)
  let #(_, bound, _, _, _) = custody.enrollment_fields(stored)
  use selected <- result.try(
    deployment.select(table, bound)
    |> result.replace_error(InvalidConfiguration),
  )
  use pin <- result.try(
    deployment.pinned(selected, stored)
    |> result.replace_error(InvalidConfiguration),
  )
  let fields = identity.scope_fields(endpoint.scope)
  use projected <- result.try(
    scope.scope_from_fields(fields.0, fields.1, fields.2, fields.3, fields.4)
    |> result.replace_error(InvalidConfiguration),
  )
  let #(bound_scope, descriptor, number) =
    generation.key_fields(generation.association_key(associated))
  let #(_, _, original_descriptor, digest, _) =
    custody.enrollment_fields(stored)
  use _ <- result.try(
    connection.validate(endpoint) |> result.replace_error(InvalidConfiguration),
  )

  // Pinned enrollment verifies canonical content, scope, native digest and route.
  // The association additionally fixes generation and original enrollment bytes.
  case
    projected == bound_scope
    && descriptor == original_descriptor
    && generation.association_fields(associated).1 == digest
    && endpoint.generation == number
    && endpoint.owner == deployment.owner(table)
    && distribution.name(endpoint.peer)
    == deployment.selected_fields(selected).1
    && within_ms > 0
    && within_ms <= 30_000
    && endpoint.within_ms <= within_ms
  {
    True ->
      Ok(SystemConfig(
        original,
        associated,
        table,
        pin,
        endpoint,
        limits,
        within_ms,
      ))
    False -> Error(InvalidConfiguration)
  }
}

/// Encodes complete fixed Read/Text metadata before the caller retains its intent.
/// The monotonic deadline belongs to this original live incarnation; historical
/// metadata never recreates send authority, even if another VM's clock is lower.
///
/// ## Examples
///
/// `system_read_plan(config, address, op, phase, id, path, deadline)` opens no file.
@internal
pub fn system_read_plan(
  config: SystemConfig,
  work_address: String,
  operation: ids.OpId,
  step: scope.Step,
  request_id: ids.EntryId,
  path: scope.RelativePath,
  deadline_ms: Int,
) -> Result(SystemReadPlan, custody.Error) {
  use Nil <- result.try(
    require_system(fn() {
      string.byte_size(work_address) > 0
      && string.byte_size(work_address) <= 1024
      && !string.contains(work_address, "\u{0000}")
      && string.byte_size(scope.step_string(step)) <= 128
    }),
  )
  use bytes <- result.try(
    mp.encode(
      mp.ArrayValue([
        mp.StringValue("registered-workspace-read-v1"),
        generation.association_value(config.association),
        mp.StringValue(work_address),
        mp.StringValue("workspace-administration"),
        mp.StringValue(ids.op_id_to_string(operation)),
        mp.StringValue(scope.step_string(step)),
        mp.StringValue(ids.entry_id_to_string(request_id)),
        mp.StringValue(scope.path_string(path)),
        mp.StringValue("text"),
        mp.IntValue(deadline_ms),
      ]),
    )
    |> result.replace_error(custody.Conflict),
  )
  use Nil <- result.try(
    require_system(fn() { bit_array.byte_size(bytes) <= 8192 }),
  )
  Ok(SystemReadPlan(
    config.association,
    work_address,
    operation,
    step,
    request_id,
    path,
    deadline_ms,
    bytes,
  ))
}

/// Projects only the complete metadata to retain through the original custodian.
/// Source bytes belong to the later workspace receipt, never to this intent.
///
/// ## Examples
///
/// `system_read_content(plan)` is the exact payload for retain_system_intent.
@internal
pub fn system_read_content(plan: SystemReadPlan) -> BitArray {
  plan.bytes
}

/// Owns serialized admission and the sole possible first Submit for a fixed read.
/// Repeated admissions observe; failed replies cannot replay. Caller death ends
/// observation while the original semantic service owns any admitted read.
///
/// ## Examples
///
/// `invoke_system(config, plan, intent)` never accepts a Fresh flag or origin.
@internal
pub fn invoke_system(
  config: SystemConfig,
  plan: SystemReadPlan,
  intent: custody.IntentReadback,
) -> Result(Outcome, SystemError) {
  use Nil <- result.try(
    verify_system_intent(config, plan, intent)
    |> result.replace_error(InvalidSystemPlan),
  )
  let remaining =
    int.min(config.within_ms, plan.deadline_ms - poll.monotonic().now())
  use Nil <- result.try(case remaining > 0 {
    True -> Ok(Nil)
    False -> Error(SystemObservationExpired)
  })
  let deadline = int.min(plan.deadline_ms, poll.monotonic().now() + remaining)
  let task = fn() { admit_system(config, plan, intent, deadline) }
  case weft.new([task]) |> weft.deadline(remaining) |> weft.start {
    [weft.Completed(_, outcome)] -> Ok(outcome)
    [weft.Failed(_, reason)] -> Error(reason)
    [weft.Abandoned(_)] | [weft.NeverStarted(_)] ->
      Error(SystemObservationExpired)
    _ -> Error(SystemObservationLost)
  }
}

fn verify_system_intent(
  config: SystemConfig,
  plan: SystemReadPlan,
  intent: custody.IntentReadback,
) -> Result(Nil, custody.Error) {
  let #(associated, address, service, operation, step, id, bytes) =
    custody.system_intent_fields(intent)
  require_system(fn() {
    config.association == plan.association
    && associated == plan.association
    && address == plan.address
    && service == custody.WorkspaceAdministration
    && operation == plan.operation
    && step == scope.step_string(plan.step)
    && id == plan.request_id
    && bytes == plan.bytes
  })
}

fn admit_system(
  config: SystemConfig,
  plan: SystemReadPlan,
  intent: custody.IntentReadback,
  deadline: Int,
) -> Result(Outcome, SystemError) {
  // The encoder captures only immutable plan projections and the preflight
  // profile. It executes inside the existing writer and performs no actor call.
  let limits = config.limits
  let scope = generation.key_scope(generation.association_key(plan.association))
  let operation = plan.operation
  let step = plan.step
  let path = plan.path
  let build = fn(origin, id) {
    encode_system_read(limits, scope, operation, step, path, origin, id)
  }
  use admitted <- result.try(
    custodian.admit_system_child(config.owner, intent, build)
    |> result.map_error(SystemOwnerUnavailable),
  )
  let invocation =
    workspace.invocation(
      scope,
      operation,
      step,
      workspace.System(workspace.WorkspaceAdministration),
      admitted.request_id,
      workspace.Read(path, workspace.Text),
    )
  use expected_payload <- result.try(
    build(admitted.origin, admitted.request_id)
    |> result.map_error(SystemOwnerUnavailable),
  )
  use Nil <- result.try(
    require_system(fn() {
      admitted.request_id == plan.request_id
      && admitted.payload == expected_payload
      && admitted.generation == generation.association_key(plan.association)
    })
    |> result.map_error(SystemOwnerUnavailable),
  )
  use reserved <- result.try(
    binding.system_reservation(config.owner, admitted, invocation)
    |> result.map_error(SystemOwnerUnavailable),
  )
  use actual <- result.try(
    custodian.child_generation(config.owner, admitted.origin)
    |> result.map_error(SystemOwnerUnavailable),
  )
  use Nil <- result.try(
    require_system(fn() { actual == plan.association })
    |> result.map_error(SystemOwnerUnavailable),
  )
  let consumer =
    Consumer(config.endpoint, Registered(config.owner, plan.association))

  // Only this invocation's actual Fresh admission can cross the first-send door.
  // Retained history cannot revive a deadline from this or an earlier VM.
  case admitted.admission {
    custody.Retained -> {
      use receipt <- result.try(
        binding.retained_completion(reserved)
        |> result.map_error(SystemOwnerUnavailable),
      )
      Ok(case receipt {
        Some(bytes) -> retained_receipt(consumer, reserved, bytes, deadline)
        None -> observe(consumer, admitted.origin, reserved, deadline)
      })
    }
    custody.Fresh -> {
      use Nil <- result.try(
        deployment.revalidate(config.table, config.pin)
        |> result.replace_error(SystemOwnerUnavailable(custody.Conflict)),
      )
      let submitted = exchange(consumer, reserved, transport.Submit, deadline)
      Ok(await_status(consumer, admitted.origin, reserved, submitted, deadline))
    }
  }
}

fn encode_system_read(
  limits: custody.Limits,
  bound: scope.Scope,
  operation: ids.OpId,
  step: scope.Step,
  path: scope.RelativePath,
  origin: remote_tool.ChildOrigin,
  id: ids.EntryId,
) -> Result(custody.SystemReservationPayload, custody.Error) {
  let #(session, _) = scope.scope_fields(bound)
  use Nil <- result.try(
    require_system(fn() {
      case remote_tool.child_fields(origin) {
        remote_tool.SystemFields(actual_session, "workspace-administration", _) ->
          actual_session == session
        remote_tool.SystemFields(_, _, _)
        | remote_tool.ToolFields(_, _)
        | remote_tool.WorkspaceCommandFields(_, _) -> False
      }
    }),
  )
  let invocation =
    workspace.invocation(
      bound,
      operation,
      step,
      workspace.System(workspace.WorkspaceAdministration),
      id,
      workspace.Read(path, workspace.Text),
    )
  use bytes <- result.try(
    codec.encode_invocation(invocation)
    |> result.replace_error(custody.Conflict),
  )
  custody.workspace_request(limits, bytes)
  |> result.map(custody.WorkspaceSystem)
}

fn require_system(condition: fn() -> Bool) -> Result(Nil, custody.Error) {
  case condition() {
    True -> Ok(Nil)
    False -> Error(custody.Conflict)
  }
}

// One managed task bounds storage, codecs and transport together. Killing the
// observer cannot retract an already queued reservation or receipt, so expiry
// carries the original child rather than claiming that its effect was refused.
fn bounded(
  config: Config,
  child: remote_tool.ChildOrigin,
  work: fn(Int) -> Result(Outcome, Error),
) -> Result(Outcome, Error) {
  let deadline = poll.monotonic().now() + config.within_ms
  let task = fn() { work(deadline) }
  case weft.new([task]) |> weft.deadline(config.within_ms) |> weft.start {
    [weft.Completed(_, outcome)] -> Ok(outcome)
    [weft.Failed(_, error)] -> Error(error)
    [weft.Abandoned(_)] | [weft.NeverStarted(_)] ->
      Error(ObservationExpired(child))
    _ -> Error(ObservationLost(child))
  }
}

fn existing(binding: binding.Binding, child: remote_tool.ChildOrigin) {
  case binding.recover(binding, child) {
    Ok(retained) -> Ok(Some(retained))
    Error(custody.Missing) -> Ok(None)
    Error(reason) -> Error(reason)
  }
}

fn observe(
  config: Consumer,
  child: remote_tool.ChildOrigin,
  reservation: binding.Reservation,
  deadline: Int,
) {
  let answer =
    poll.fold_until(
      clock: poll.monotonic(),
      within: int.max(0, deadline - poll.monotonic().now()),
      every: poll.Fixed(25),
      from: AwaitingEvidence,
      attempt: fn(last) {
        // Poll makes a final attempt at expiry. Preserve its last observation
        // without sending another request after the shared budget is exhausted.
        use Nil <- or_expired(deadline, last)
        case exchange(config, reservation, transport.Query, deadline) {
          Ok(journal.Finished(bytes)) -> poll.Settled(bytes)
          Ok(journal.Accepted) | Ok(journal.Unknown) ->
            poll.Pending(AwaitingEvidence)
          Error(_) -> poll.Pending(TransportUncertain)
          Ok(journal.Cancelled) -> poll.Broken(Cancelled(reservation))
          Ok(journal.Acknowledged(_)) ->
            poll.Broken(reconcile_ack(config, child, reservation, deadline))
        }
      },
    )
  case answer {
    poll.Answer(bytes) -> settle(config, reservation, bytes, deadline)
    poll.Failure(outcome) -> outcome
    poll.RanOut(reason) -> Pending(reservation, reason)
  }
}

fn await_status(config, child, reservation, submitted, deadline) {
  case submitted {
    Ok(journal.Finished(bytes)) -> settle(config, reservation, bytes, deadline)
    Ok(journal.Cancelled) -> Cancelled(reservation)
    Ok(journal.Acknowledged(_)) ->
      reconcile_ack(config, child, reservation, deadline)
    Ok(journal.Accepted) | Ok(journal.Unknown) ->
      observe(config, child, reservation, deadline)
    Error(_) -> {
      use Nil <- or_uncertain(deadline, reservation)
      observe(config, child, reservation, deadline)
    }
  }
}

fn reconcile_ack(
  config: Consumer,
  _child: remote_tool.ChildOrigin,
  reservation: binding.Reservation,
  deadline: Int,
) {
  // Another caller can commit the exact receipt while this caller is querying.
  // The authoritative owner read precedes an invariant-failure classification.
  case binding.retained_completion(reservation) {
    Ok(Some(bytes)) -> retained_receipt(config, reservation, bytes, deadline)
    Ok(None) -> InvariantFailure(reservation)
    Error(_) -> Pending(reservation, ReceiptUncertain)
  }
}

fn settle(
  config: Consumer,
  reservation: binding.Reservation,
  bytes: BitArray,
  deadline: Int,
) {
  use completion <- or_pending(
    codec.decode_completion(
      workspace.request(binding.invocation(reservation)),
      bytes,
    ),
    reservation,
  )
  use ack <- or_pending(binding.receive(reservation, bytes), reservation)
  use Nil <- or_pending(
    verify_registered_receipt(config, reservation, bytes),
    reservation,
  )
  acknowledge(config, reservation, completion, ack, deadline)
}

fn retained_receipt(
  config: Consumer,
  reservation: binding.Reservation,
  bytes: BitArray,
  deadline: Int,
) {
  use completion <- or_pending(
    codec.decode_completion(
      workspace.request(binding.invocation(reservation)),
      bytes,
    ),
    reservation,
  )

  // Recovery already read validated exact durable receipt bytes. A failed
  // idempotent write withholds ACK authority without discarding that completion.
  case binding.receive(reservation, bytes) {
    Ok(ack) -> {
      use Nil <- or_pending(
        verify_registered_receipt(config, reservation, bytes),
        reservation,
      )
      acknowledge(config, reservation, completion, ack, deadline)
    }
    Error(_) ->
      case config.authority {
        Ordinary -> Completed(completion, Retained)
        Registered(_, _) -> Pending(reservation, ReceiptUncertain)
      }
  }
}

// The original receipt transaction already validates request, UUID and its
// own generation link. Registered consumers also compare that link against the
// original assembly association before ACK or releasing usable source bytes.
fn verify_registered_receipt(
  config: Consumer,
  reservation: binding.Reservation,
  bytes: BitArray,
) -> Result(Nil, custody.Error) {
  case config.authority {
    Ordinary -> Ok(Nil)
    Registered(owner, expected) -> {
      let #(_, _, _, _, id) =
        workspace.invocation_identity(binding.invocation(reservation))

      // The opaque reservation retains its original system origin; this
      // continuation never asks a current generation to replace it.
      use origin <- result.try(binding.system_origin(reservation))
      use actual <- result.try(custodian.receipt_generation(owner, origin, id))
      require_system(fn() { actual.0 == bytes && actual.1 == expected })
    }
  }
}

fn acknowledge(
  config: Consumer,
  reservation: binding.Reservation,
  completion: Result(local.Completed, workspace.ServiceError),
  ack: binding.Acknowledgement,
  deadline: Int,
) {
  let digest = binding.acknowledgement(ack).1
  use digest <- or_pending(identity.digest(digest), reservation)
  let expected_digest = identity.digest_bytes(digest)
  case exchange(config, reservation, transport.Acknowledge(digest), deadline) {
    Ok(journal.Acknowledged(received)) if received == expected_digest ->
      Completed(completion, Confirmed)
    Ok(journal.Acknowledged(_)) -> InvariantFailure(reservation)
    Ok(journal.Accepted)
    | Ok(journal.Unknown)
    | Ok(journal.Finished(_))
    | Ok(journal.Cancelled)
    | Error(_) -> Completed(completion, Retained)
  }
}

fn exchange(
  config: Consumer,
  reservation: binding.Reservation,
  command: transport.WorkspaceCommand,
  deadline: Int,
) {
  let remaining = deadline - poll.monotonic().now()
  use Nil <- result.try(case remaining > 0 {
    True -> Ok(Nil)
    False -> Error(connection.Uncertain)
  })
  let endpoint =
    connection.Config(
      ..config.endpoint,
      within_ms: int.min(config.endpoint.within_ms, remaining),
    )
  connection.workspace_exchange(endpoint, command, binding.content(reservation))
}

fn or_pending(
  value: Result(a, e),
  reservation: binding.Reservation,
  then: fn(a) -> Outcome,
) -> Outcome {
  case value {
    Ok(value) -> then(value)
    Error(_) -> Pending(reservation, ReceiptUncertain)
  }
}

fn owner_error(
  value: Result(a, custody.Error),
  child: remote_tool.ChildOrigin,
) {
  result.map_error(value, fn(reason) { OwnerUnavailable(child, reason) })
}

fn or_expired(
  deadline: Int,
  last: PendingReason,
  then: fn(Nil) -> poll.Pass(a, e, PendingReason),
) -> poll.Pass(a, e, PendingReason) {
  case deadline - poll.monotonic().now() > 0 {
    True -> then(Nil)
    False -> poll.Pending(last)
  }
}

fn or_uncertain(
  deadline: Int,
  reservation: binding.Reservation,
  then: fn(Nil) -> Outcome,
) -> Outcome {
  case deadline - poll.monotonic().now() > 0 {
    True -> then(Nil)
    False -> Pending(reservation, TransportUncertain)
  }
}
