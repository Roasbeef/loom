//// Which orchestrators a session can be moved to, and why the others cannot
//// (protocol-change/085, the addendum on Move and Abandon).
////
//// A move hands a session on an executor to another orchestrator, which must
//// reach that executor after the move because the session's workspace stays
//// where it is. The daemon refuses a destination it does not list, but a
//// person choosing one needs to be told which listed orchestrators would work
//// before choosing. The terminal prints the answer and the web home draws it,
//// and both must give the same one, so the rule and its words live here, below
//// both hosts. The module is pure: the caller reads the deployment and
//// states what it found of each orchestrator as an `Offer`.
////
//// ## The rule
////
//// An orchestrator is a destination when the asking daemon reached it, it said
//// it accepts the sessions other orchestrators move to it (`Receiving`), and the
//// executors it serves include the session's. Anything else is a candidate that
//// is `Ineligible`, with the first reason that applies, so a person is told one
//// thing to fix and not a list. The asking daemon is not an offer: a session
//// does not move to the orchestrator it is on.
////
//// A caller gives `serves` and `executor` in one vocabulary, either the asking
//// daemon's configuration keys or full node names, and the rule compares them
//// as text.
////
//// ## Flow
////
//// `choose` judges each offer in turn, `eligible` lists the destinations that
//// can be asked for, and `reason_words`, `no_executor_words` and `none_words`
//// are the fixed words.

import gleam/list
import gleam/option.{type Option, None, Some}

/// Whether an orchestrator accepts the sessions another one moves to it.
pub type Receives {
  /// It runs an importer.
  Receiving

  /// It refuses every piece and activation.
  NotReceiving
}

/// What the asking daemon found of one orchestrator.
pub type Facts {
  /// The daemon did not reach it, or it did not answer.
  Silent

  /// It answered and gave no orchestrator report, as a build older than the
  /// report does.
  Unreported

  /// It answered with its report.
  Reported(
    /// Whether it accepts moved sessions.
    receives: Receives,
    /// The executors it serves.
    serves: List(String),
  )
}

/// One orchestrator the asking daemon lists, and what it found of it.
pub type Offer {
  Offer(
    /// The asking daemon's name for the orchestrator, which a move names it by.
    name: String,
    /// What was found.
    facts: Facts,
  )
}

/// Why an orchestrator cannot take the session.
pub type Reason {
  /// The asking daemon did not reach it.
  Unreachable

  /// It answered but states nothing the rule can judge.
  NoReport

  /// It reached the asking daemon and refuses moved sessions.
  NotAccepting

  /// It accepts moved sessions and does not serve the session's executor.
  NotServing
}

/// Whether an orchestrator can take the session.
pub type Eligibility {
  /// The move can be asked for.
  Eligible

  /// It cannot, and the reason says why.
  Ineligible(reason: Reason)
}

/// One orchestrator and whether the session can move to it.
pub type Candidate {
  Candidate(name: String, eligibility: Eligibility)
}

/// The candidates for a session placed on `executor`, one for each offer in
/// the offers' order. A session with no executor has none to compare, so every
/// reached orchestrator that accepts moves is `Ineligible(NotServing)`.
///
/// ## Examples
///
/// ```gleam
/// let offers = [
///   move_candidates.Offer("bravo", move_candidates.Reported(move_candidates.Receiving, ["box"])),
///   move_candidates.Offer("charlie", move_candidates.Silent),
/// ]
/// assert move_candidates.choose(offers, Some("box"))
///   == [
///     move_candidates.Candidate("bravo", move_candidates.Eligible),
///     move_candidates.Candidate(
///       "charlie",
///       move_candidates.Ineligible(move_candidates.Unreachable),
///     ),
///   ]
/// ```
pub fn choose(
  offers: List(Offer),
  executor: Option(String),
) -> List(Candidate) {
  list.map(offers, fn(offer) {
    Candidate(offer.name, judge(offer.facts, executor))
  })
}

/// The first reason that applies: reached, then reporting, then accepting, then
/// serving the executor.
fn judge(facts: Facts, executor: Option(String)) -> Eligibility {
  case facts, executor {
    Silent, _ -> Ineligible(Unreachable)
    Unreported, _ -> Ineligible(NoReport)
    Reported(receives: NotReceiving, ..), _ -> Ineligible(NotAccepting)
    Reported(receives: Receiving, ..), None -> Ineligible(NotServing)
    Reported(receives: Receiving, serves:), Some(executor) ->
      case list.contains(serves, executor) {
        True -> Eligible
        False -> Ineligible(NotServing)
      }
  }
}

/// The destinations that can be asked for, in the candidates' order.
///
/// ## Examples
///
/// ```gleam
/// assert move_candidates.eligible([]) == []
/// ```
pub fn eligible(candidates: List(Candidate)) -> List(String) {
  list.filter_map(candidates, fn(candidate) {
    case candidate.eligibility {
      Eligible -> Ok(candidate.name)
      Ineligible(..) -> Error(Nil)
    }
  })
}

/// The fixed words for a reason, as a sentence fragment that follows the
/// orchestrator's name.
///
/// ## Examples
///
/// ```gleam
/// assert move_candidates.reason_words(move_candidates.NotServing)
///   == "does not serve this session's executor"
/// ```
pub fn reason_words(reason: Reason) -> String {
  case reason {
    Unreachable -> "is not reachable"
    NoReport -> "gave no report"
    NotAccepting -> "does not accept moved sessions"
    NotServing -> "does not serve this session's executor"
  }
}

/// The words for a session that has no Move: why the row offers none. Only a
/// session on an executor can move, because a local session's checkout is a
/// directory on this machine, which does not travel.
///
/// ## Examples
///
/// ```gleam
/// assert move_candidates.no_executor_words()
///   == "Only a session on an executor can move."
/// ```
pub fn no_executor_words() -> String {
  "Only a session on an executor can move."
}

/// The words when no orchestrator is eligible, which the row says beside the
/// reasons.
///
/// ## Examples
///
/// ```gleam
/// assert move_candidates.none_words()
///   == "No orchestrator can take this session now."
/// ```
pub fn none_words() -> String {
  "No orchestrator can take this session now."
}
