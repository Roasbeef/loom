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
//// One managed task bounds owner storage, codecs and all exchanges together.
//// Exchanges also subtract elapsed monotonic time from the same finite budget.
//// Polling uses weft; expiry grants no fresh effect identity. Assembly MUST cap
//// simultaneous invocations at four. This module has one synchronous exchange
//// per caller, not a global admission actor. Owner quotas bound durable retained
//// bytes separately; these bounds do not claim a resident-memory ceiling.

import client/remote/custodian
import client/remote/workspace_binding as binding
import core/ids
import core/remote_tool
import core/workspace as scope
import executor/remote/beam_endpoint as connection
import executor/remote/identity
import executor/remote/internal/beam_protocol as transport
import executor/remote/workspace_journal as journal
import gleam/int
import gleam/option.{None, Some}
import gleam/result
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
  use retained <- result.try(
    existing(config.binding, child) |> owner_error(child),
  )
  use reservation <- result.try(
    binding.reserve(config.binding, child, operation, step, origin, request)
    |> owner_error(child),
  )
  case retained {
    Some(#(_, Some(bytes))) ->
      Ok(retained_receipt(config, reservation, bytes, deadline))
    Some(#(_, None)) -> Ok(observe(config, child, reservation, deadline))
    None -> {
      // A concurrent reservation may have won after the read. Submit still uses
      // exactly its retained UUID; the executor journal grants only one claim.
      let submitted = exchange(config, reservation, transport.Submit, deadline)
      Ok(await_status(config, child, reservation, submitted, deadline))
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
  use retained <- result.try(
    binding.recover(config.binding, child) |> owner_error(child),
  )
  let #(reservation, receipt) = retained
  Ok(case receipt {
    Some(bytes) -> retained_receipt(config, reservation, bytes, deadline)
    None -> observe(config, child, reservation, deadline)
  })
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
  config: Config,
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
  config: Config,
  child: remote_tool.ChildOrigin,
  reservation: binding.Reservation,
  deadline: Int,
) {
  // Another caller can commit the exact receipt while this caller is querying.
  // The authoritative owner read precedes an invariant-failure classification.
  case binding.recover(config.binding, child) {
    Ok(#(_, Some(bytes))) ->
      retained_receipt(config, reservation, bytes, deadline)
    Ok(#(_, None)) -> InvariantFailure(reservation)
    Error(_) -> Pending(reservation, ReceiptUncertain)
  }
}

fn settle(
  config: Config,
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
  acknowledge(config, reservation, completion, ack, deadline)
}

fn retained_receipt(
  config: Config,
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
    Ok(ack) -> acknowledge(config, reservation, completion, ack, deadline)
    Error(_) -> Completed(completion, Retained)
  }
}

fn acknowledge(
  config: Config,
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
  config: Config,
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
