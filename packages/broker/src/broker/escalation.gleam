//// Approval escalation as a pure state machine (design §5.3).
////
//// A sandbox denial — from the broker's policy check or from the
//// helper's enforcement report — produces a structured escalation
//// carrying the exact policy diff wanted ("wants: network to
//// registry.npmjs.org"). On approval, exactly *one* re-execution runs
//// under the widened policy; a second consume is refused. "Approve
//// similar for this session" is expressed by the caller applying the
//// approved grants to the session base policy explicitly — never
//// silently, and never by this module.
////
//// Every transition returns an `Event`. Durability is the caller's job:
//// the runtime (WP-E) records each event before acting on it, so the
//// transcript shows denial, decision, and the single re-execution.

import broker/policy.{type Grant}
import gleam/list

/// Where a denial came from.
pub type DenialSource {
  /// The broker's policy composition refused before dispatch (the tool
  /// required more than the session base allows, without a grant).
  PolicyDenial
  /// The helper's per-exec enforcement report showed the execution did
  /// not run under the demanded enforcement; entries are the helper's
  /// ground-truth list (e.g. "skip:landlock: ...").
  ExecutionDenial(enforcement: List(String))
}

/// A structured denial: why, from where, and the exact widening that
/// would satisfy it.
pub type Denial {
  Denial(reason: String, source: DenialSource, wanted: List(Grant))
}

/// The observable lifecycle position of an escalation.
pub type Status {
  /// Raised, awaiting a decision.
  StatusPending
  /// Approved with grants; the one re-execution has not run yet.
  StatusApproved
  /// Rejected; no re-execution will ever run.
  StatusRejected
  /// The single approved re-execution has been taken.
  StatusConsumed
}

/// One escalation. Opaque: transitions only through `approve`,
/// `reject`, and `consume`, so "exactly one re-execution" is enforced
/// by construction.
pub opaque type Escalation {
  /// Invariants: `id` is caller-assigned and stable; `phase` moves only
  /// Pending -> Approved -> Consumed or Pending -> Rejected.
  Escalation(id: String, denial: Denial, phase: Phase)
}

type Phase {
  Pending
  Approved(grants: List(Grant))
  Rejected
  Consumed(grants: List(Grant))
}

/// A lifecycle transition, for the caller to record durably (WP-E
/// callbacks) before acting on it.
pub type Event {
  /// A denial became an escalation awaiting decision.
  EscalationRaised(id: String, denial: Denial)
  /// The escalation was approved with exactly these grants.
  EscalationApproved(id: String, grants: List(Grant))
  /// The escalation was rejected.
  EscalationRejected(id: String)
  /// The single approved re-execution was taken under these grants.
  EscalationConsumed(id: String, grants: List(Grant))
}

/// Why a transition was refused.
pub type LifecycleError {
  /// `approve`/`reject` on an escalation that is not pending.
  NotPending(status: Status)
  /// `consume` on an escalation that is not approved — including one
  /// already consumed: the single re-execution is spent.
  NotApproved(status: Status)
  /// An approval tried to grant something the denial never asked for.
  /// Approvals answer the surfaced diff; a wider grant must be a new,
  /// explicit policy decision, not a rider on this one.
  GrantNotWanted(grant: Grant)
}

/// Raises an escalation from a denial.
///
/// ## Examples
///
/// ```gleam
/// let denial =
///   escalation.Denial("network off", escalation.PolicyDenial, wanted: [])
/// let #(_escalation, event) = escalation.raise("esc-1", denial)
/// assert event == escalation.EscalationRaised("esc-1", denial)
/// ```
///
pub fn raise(id: String, denial: Denial) -> #(Escalation, Event) {
  #(Escalation(id:, denial:, phase: Pending), EscalationRaised(id:, denial:))
}

/// Approves a pending escalation with `grants`, each of which must be
/// among the denial's wanted diff (a subset is allowed — partial
/// approval narrows what the re-execution gets).
pub fn approve(
  escalation: Escalation,
  grants: List(Grant),
) -> Result(#(Escalation, Event), LifecycleError) {
  case escalation.phase {
    Pending ->
      case
        list.find(grants, fn(grant) {
          !list.contains(escalation.denial.wanted, grant)
        })
      {
        Ok(grant) -> Error(GrantNotWanted(grant:))
        Error(Nil) ->
          Ok(#(
            Escalation(..escalation, phase: Approved(grants:)),
            EscalationApproved(id: escalation.id, grants:),
          ))
      }
    other -> Error(NotPending(status: phase_status(other)))
  }
}

/// Rejects a pending escalation. No re-execution will run.
pub fn reject(
  escalation: Escalation,
) -> Result(#(Escalation, Event), LifecycleError) {
  case escalation.phase {
    Pending ->
      Ok(#(
        Escalation(..escalation, phase: Rejected),
        EscalationRejected(id: escalation.id),
      ))
    other -> Error(NotPending(status: phase_status(other)))
  }
}

/// Takes the single approved re-execution, returning the grants to
/// compose into the widened policy. A second consume is refused: the
/// approval clears one run, not a standing permission.
pub fn consume(
  escalation: Escalation,
) -> Result(#(Escalation, List(Grant), Event), LifecycleError) {
  case escalation.phase {
    Approved(grants:) ->
      Ok(#(
        Escalation(..escalation, phase: Consumed(grants:)),
        grants,
        EscalationConsumed(id: escalation.id, grants:),
      ))
    other -> Error(NotApproved(status: phase_status(other)))
  }
}

/// The escalation's caller-assigned id.
pub fn id(escalation: Escalation) -> String {
  escalation.id
}

/// The denial this escalation was raised from.
pub fn denial(escalation: Escalation) -> Denial {
  escalation.denial
}

/// The escalation's lifecycle position.
pub fn status(escalation: Escalation) -> Status {
  phase_status(escalation.phase)
}

fn phase_status(phase: Phase) -> Status {
  case phase {
    Pending -> StatusPending
    Approved(grants: _) -> StatusApproved
    Rejected -> StatusRejected
    Consumed(grants: _) -> StatusConsumed
  }
}
