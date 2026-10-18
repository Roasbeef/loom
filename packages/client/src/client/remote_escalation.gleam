//// The vocabulary of a child's request for more authority and of the answer to
//// it, between two orchestrators (protocol-change/089).
////
//// A child that runs on the box can be refused by its sandbox. The refusal
//// becomes an escalation record in the box's delegate session, and when the
//// spawner has an approval ceiling the box tells the parent's orchestrator, the
//// laptop (`ChildEscalation`), and the laptop's operator answers with `Resolve`.
//// This module holds the plain data those two messages carry and the names of
//// the keys the laptop files the request under. It has no process in it and does
//// no I/O, as `client/remote_mail` has none, so both orchestrators compile the
//// same module and a value built here crosses the pinned connection as an
//// ordinary term.
////
//// ## Who decides what
////
//// The record is the box's. The laptop keeps the newest copy it has heard of
//// under `remote-escalation/{orchestrator}/{id}` and draws it for its operator,
//// and the operator's answer names the box's `seq` for the question, so an answer
//// to a question that has since changed is refused with the record as it now is.
//// The single-consume state machine that makes an approval spend once is
//// `broker/escalation`'s and runs on the box. Nothing here adds a transition to
//// it, which is why protocol-change/089 needs no model of its own.
////
//// `decided_by` is the laptop's account of who answered. It is the principal's
//// digest and display name as text, kept on the box as provenance and never
//// resolved to a principal of the box's own: it authenticates nothing there.
////
//// ## Flow
////
//// `key` → `client_id` → `box_id` → `describe_refusal`
////
//// 1. `key` is where the laptop files a request, and `client_id` is the identity
////    its operator's client sees, which names the orchestrator so that two boxes
////    cannot collide.
//// 2. `box_id` recovers the box's own identity from the client's.
//// 3. `describe_refusal` words a refusal for the operator.

import broker/policy.{type Grant}
import client/protocol.{type EscalationRecord}
import core/message
import gleam/option
import gleam/string

/// How long an approval lasts.
pub type Scope {
  /// One re-execution of the one call that asked.
  Once

  /// The same, and the grants are remembered in the delegate session, so a later
  /// call of any child of that parent on the box finds them standing.
  Session
}

/// What the operator on the laptop decided.
pub type Decision {
  /// Approve some or all of what was asked. `grants` must be drawn from the
  /// record's wanted list, and `action` echoes the record's action digest, so the
  /// approval binds to what the operator was shown.
  Approve(
    /// The grants approved.
    grants: List(Grant),
    /// The action digest the operator was shown.
    action: String,
    /// For how long.
    scope: Scope,
  )

  /// Reject the question.
  Deny

  /// Withdraw a grant that an earlier session approval from this spawner left
  /// standing. The box admits it only for a grant that carries this spawner's
  /// provenance.
  Forget(
    /// The remembered grant.
    grant: Grant,
  )
}

/// The box's answer to a `Resolve`. Every variant is final for that request.
pub type Answer {
  /// The decision committed, and this is the record afterwards.
  Decided(record: EscalationRecord)

  /// A `Forget` withdrew the remembered grant.
  Forgotten

  /// The question is not the one the operator answered: its `seq` or action
  /// moved, or the record is no longer pending. The record is as the box has it
  /// now, so the laptop can show the current question.
  Stale(
    /// The box's current record.
    record: EscalationRecord,
    /// What differed.
    reason: String,
  )

  /// The box would not admit the decision, with the reason: it is outside the
  /// approval ceiling, the child is not this parent's, or the record is unknown.
  /// A request outside the ceiling stays pending for the box's owner.
  Refused(
    /// Why.
    reason: String,
  )
}

/// The reason a decision outside the ceiling is refused with.
pub const outside_the_ceiling = "outside the spawner's approval ceiling"

/// The key under which the laptop files a request, in the parent session.
///
/// ## Examples
///
/// ```gleam
/// assert remote_escalation.key("box", "policy-ab") == "remote-escalation/box/policy-ab"
/// ```
pub fn key(orchestrator: String, id: String) -> String {
  "remote-escalation/" <> client_id(orchestrator, id)
}

/// The identity of a request as the parent's clients see it: the orchestrator,
/// a slash and the box's identity. Orchestrator names do not contain a slash,
/// and the box's identities never begin with one, so the first slash divides
/// them.
///
/// ## Examples
///
/// ```gleam
/// assert remote_escalation.client_id("box", "policy-ab") == "box/policy-ab"
/// ```
pub fn client_id(orchestrator: String, id: String) -> String {
  orchestrator <> "/" <> id
}

/// The box's identity of a request from the one its clients were shown. A text
/// with no slash is a local identity and answers itself.
///
/// ## Examples
///
/// ```gleam
/// assert remote_escalation.box_id("box/policy-ab") == "policy-ab"
/// assert remote_escalation.box_id("policy-ab") == "policy-ab"
/// ```
pub fn box_id(client_id: String) -> String {
  case string.split_once(client_id, "/") {
    Ok(#(_orchestrator, id)) -> id
    Error(Nil) -> client_id
  }
}

/// The record as the parent's clients see it: filed under the orchestrator, with
/// its identity prefixed by the placement.
///
/// ## Examples
///
/// ```gleam
/// // remote_escalation.placed("box", record).escalation_id == "box/" <> record.escalation_id
/// ```
pub fn placed(
  orchestrator: String,
  record: EscalationRecord,
) -> EscalationRecord {
  protocol.EscalationRecord(
    ..record,
    escalation_id: client_id(orchestrator, record.escalation_id),
    placement: option.Some(orchestrator),
  )
}

/// Who answered on the laptop, as the text the box keeps: the principal's
/// identity and its display name at the time. It is provenance only.
pub type Decider {
  Decider(
    /// The principal's stable identity on the laptop.
    principal: String,
    /// The display name the principal had when it answered.
    name: String,
  )
}

/// The decider as the origin a record and a remembered grant carry.
///
/// ## Examples
///
/// ```gleam
/// assert remote_escalation.origin_of(remote_escalation.Decider("ab12", "Ola"))
///   == message.Origin("ab12", "Ola")
/// ```
pub fn origin_of(decider: Decider) -> message.Origin {
  message.Origin(principal: decider.principal, name: decider.name)
}

/// A refusal as a sentence for the operator.
///
/// ## Examples
///
/// ```gleam
/// assert remote_escalation.describe_refusal(remote_escalation.Refused("no")) == "no"
/// ```
pub fn describe_refusal(answer: Answer) -> String {
  case answer {
    Decided(..) -> "the decision was committed"
    Forgotten -> "the permission was withdrawn"
    Stale(reason:, ..) -> reason
    Refused(reason:) -> reason
  }
}
