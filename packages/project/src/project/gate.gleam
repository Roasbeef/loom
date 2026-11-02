//// The gate: a pure decision about a trigger's strength and about whether
//// inferred work may be accepted.
////
//// Strength is the one fact the whole authority model rests on, so exactly
//// one function sets it and it reads only what the source supplied: the
//// sender's class from literal allowlists, whether the message addressed the
//// agent, whether it follows up on the sender's own ticket, and the rule
//// that matched. No model output reaches this module, and a routing event
//// has no field that could carry a strength. A router can therefore not
//// accept something "as explicit".
////
//// Two questions live here. `classify` answers who may start what: the
//// authority table, plus the generation limit that stops the project's own
//// output from feeding itself. `acceptance` answers whether an inferred
//// trigger may become work: only in `Auto`, with a matching rule and a
//// current passing verdict. `Observe` records what would have happened and
//// acts on nothing.

import gleam/option.{type Option, None, Some}
import project/model.{
  type ApprovalGrant, type Basis, type Mode, type RuleId, type Strength,
  type Trigger, ApprovalsNotGranted, Auto, Explicit, FromAddressed,
  FromAutomation, FromComposer, FromFollowUp, FromOverheard, FromRule, Inferred,
  Observe, Off,
}

/// The most hops of the project's own output that may still produce inferred
/// work. A pull request that fails CI opens a ticket (generation 1), whose
/// pull request fails CI and opens another (generation 2); past this limit the
/// gate refuses to infer, so the loop ends. Explicit requests ignore it.
pub const max_generation: Int = 2

/// Whether the sender already owns a ticket on the trigger's thread.
pub type ThreadRelation {
  /// No ticket of the sender subscribes to the thread.
  UnrelatedThread

  /// A ticket of the sender subscribes to the thread.
  OwnTicketThread
}

/// Why a trigger was not admitted.
pub type Withheld {
  /// The sender is not listed and no rule admits them.
  SenderUnlisted

  /// The trigger descends from the project's own output too many times.
  PastGenerationLimit

  /// The project's own bot wrote it. The engine drops it before the gate.
  OwnOutput
}

/// The gate's verdict on a trigger.
pub type Admission {
  /// The trigger is let through at this strength.
  Admitted(
    /// Explicit or inferred.
    strength: Strength,
    /// Why.
    basis: Basis,
    /// What the matching rule grants beyond admission.
    approvals: ApprovalGrant,
  )

  /// The trigger is recorded on its thread and never delivered.
  NotAdmitted(
    /// Why.
    reason: Withheld,
  )
}

/// Decide a trigger's admission. First matching row of the authority table
/// wins; the generation limit applies to inferred rows only.
///
/// ## Examples
///
/// ```gleam
/// let trigger = model.Trigger(
///   id: model.TriggerId("c1"),
///   source: model.SourceId("composer"),
///   thread: model.ThreadId("th"),
///   actor: model.ActorId("me"),
///   inputs: model.Inputs(model.Owner, model.Addressed, option.None),
///   generation: 0,
///   at_ms: 0,
/// )
/// assert gate.classify(trigger, gate.UnrelatedThread)
///   == gate.Admitted(model.Explicit, model.FromComposer, model.ApprovalsNotGranted)
/// ```
pub fn classify(trigger: Trigger, relation: ThreadRelation) -> Admission {
  let inputs = trigger.inputs

  // The sender's class selects the row of the authority table.
  let approvals = case inputs.rule {
    Some(matched) -> matched.approvals
    None -> ApprovalsNotGranted
  }

  // A person is explicit when following up on their own ticket or addressing
  // the agent, and inferred otherwise.
  case inputs.sender {
    model.Owner -> Admitted(Explicit, FromComposer, approvals)
    model.Person ->
      case relation, inputs.addressing {
        OwnTicketThread, _ -> Admitted(Explicit, FromFollowUp, approvals)
        UnrelatedThread, model.Addressed ->
          Admitted(Explicit, FromAddressed, approvals)
        UnrelatedThread, model.Unaddressed ->
          inferred(trigger, FromOverheard, approvals)
      }
    model.ListedBot -> inferred(trigger, FromAutomation, approvals)
    model.CiFailure -> inferred(trigger, FromAutomation, approvals)
    model.Unlisted ->
      case inputs.rule {
        Some(matched) -> inferred(trigger, FromRule(matched.rule), approvals)
        None -> NotAdmitted(SenderUnlisted)
      }
  }
}

/// An inferred admission, unless the trigger is too many hops from the
/// person who started the chain.
fn inferred(
  trigger: Trigger,
  basis: Basis,
  approvals: ApprovalGrant,
) -> Admission {
  case trigger.generation > max_generation {
    True -> NotAdmitted(PastGenerationLimit)
    False -> Admitted(Inferred, basis, approvals)
  }
}

/// Whether a verdict is current for a source and rule pair.
pub type VerdictState {
  /// A passing verdict measured under the policy version in force.
  VerdictCurrent

  /// No such verdict: none recorded, a failing one, or a stale version.
  VerdictMissing
}

/// What the gate needs to know about a source and rule pair.
pub type Pair {
  Pair(
    /// The rule that matched the trigger, if any.
    rule: Option(RuleId),
    /// The pair's mode.
    mode: Mode,
    /// Whether its verdict is current.
    verdict: VerdictState,
  )
}

/// Why an inferred trigger may not be accepted.
pub type AcceptRefusal {
  /// No rule matched.
  NoMatchingRule

  /// The pair is `Off`.
  ModeIsOff

  /// The pair is `Auto` without a current passing verdict.
  NoCurrentVerdict
}

/// What accepting a trigger should do.
pub type Acceptance {
  /// Go ahead.
  Proceed

  /// Record that this would have been accepted, and act on nothing.
  RecordOnly

  /// Refuse.
  Refuse(
    /// Why.
    reason: AcceptRefusal,
  )
}

/// Decide whether a trigger of this strength may be accepted. Explicit
/// requests work in every mode. Inferred ones need a matching rule and, to act,
/// `Auto` with a current verdict.
///
/// ## Examples
///
/// ```gleam
/// let pair = gate.Pair(option.Some(model.RuleId("r")), model.Auto, gate.VerdictMissing)
/// assert gate.acceptance(model.Inferred, pair)
///   == gate.Refuse(gate.NoCurrentVerdict)
/// ```
///
/// ```gleam
/// let pair = gate.Pair(option.None, model.Off, gate.VerdictMissing)
/// assert gate.acceptance(model.Explicit, pair) == gate.Proceed
/// ```
pub fn acceptance(strength: Strength, pair: Pair) -> Acceptance {
  case strength, pair.rule {
    Explicit, _ -> Proceed
    Inferred, None -> Refuse(NoMatchingRule)
    Inferred, Some(_) ->
      case pair.mode, pair.verdict {
        Off, _ -> Refuse(ModeIsOff)
        Observe, _ -> RecordOnly
        Auto, VerdictCurrent -> Proceed
        Auto, VerdictMissing -> Refuse(NoCurrentVerdict)
      }
  }
}

/// Whether a mode may be set for a pair with this verdict. `Auto` needs a
/// current passing verdict; the other modes need nothing.
///
/// ## Examples
///
/// ```gleam
/// assert gate.mode_allowed(model.Auto, gate.VerdictMissing) == Error(Nil)
/// ```
///
/// ```gleam
/// assert gate.mode_allowed(model.Observe, gate.VerdictMissing) == Ok(Nil)
/// ```
pub fn mode_allowed(mode: Mode, verdict: VerdictState) -> Result(Nil, Nil) {
  case mode, verdict {
    Auto, VerdictMissing -> Error(Nil)
    Auto, VerdictCurrent -> Ok(Nil)
    Observe, _ -> Ok(Nil)
    Off, _ -> Ok(Nil)
  }
}
