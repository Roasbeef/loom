//// Dominance between two arms: outcome first and lexically, then Pareto
//// on the secondary scores.
////
//// A cheaper arm is not a better arm if it fails more tasks, and a cheaper
//// arm that is cheaper because it abandons work fails the verifier, so the
//// outcome verdict is read before any score is. An arm the decision rule
//// found `Harmed` is `Dominated` whatever it cost; one found `Improved`
//// `Dominates` whatever it cost. Any arm not shown harmful on outcome,
//// `Indistinguishable` or `Underpowered` alike, goes to the scores, and
//// there the vote is Pareto: the candidate dominates if it is at least as
//// good on every shared score and strictly better on one. Anything else
//// is a trade-off the report shows and no rule resolves, because resolving
//// it would need a weighting the design declined to invent. An
//// `Incomplete` outcome ranks nothing, and so does a pair of score vectors
//// with no name in common: both are the absence of a comparison, not a
//// tie.
////
//// Scores are compared by name, on the names both vectors carry, oriented
//// higher-is-better by the caller (`cost_inv = 1 / (1 + dollars)` and the
//// like), so this module never needs to know what a score means. A score
//// that is not a number (`is_number`) ranks below every number: the BEAM
//// has no NaN float, but the JavaScript target does, and its
//// `float.compare` would otherwise call it greater than everything.

import evalstat/verdict.{type Verdict}
import gleam/float
import gleam/list
import gleam/order.{type Order}

/// Where a dominance ruling came from.
pub type Ground {
  /// The outcome verdict settled it before the scores were read.
  Outcome

  /// The outcome was not harmful and the score vector settled it.
  Scores
}

/// How the candidate stands against the baseline.
pub type Dominance {
  /// The candidate is better, on the named ground.
  Dominates(Ground)

  /// The candidate is worse, on the named ground.
  Dominated(Ground)

  /// Outcome not harmful and every shared score equal.
  Tie

  /// Outcome not harmful and the scores disagree: better on some, worse on
  /// others, each listed by name.
  Tradeoff(better: List(String), worse: List(String))

  /// Nothing to compare: the outcome verdict was `Incomplete`, or the two
  /// score vectors share no name.
  Undecided
}

/// Ranks the candidate against the baseline from the outcome verdict of
/// their comparison and each arm's score vector.
///
/// ## Examples
///
/// ```gleam
/// let harmed = verdict.Harmed(-0.3, #(-0.4, -0.2), 0.001, 0.1)
/// assert dominance.compare(harmed, [#("cost_inv", 0.9)], [#("cost_inv", 0.5)])
///   == Dominated(Outcome)
/// ```
///
/// ```gleam
/// let same = verdict.Indistinguishable(0.0, #(-0.1, 0.1), 1.0, 0.1)
/// assert dominance.compare(same, [#("cost_inv", 0.9)], [#("cost_inv", 0.5)])
///   == Dominates(Scores)
/// ```
pub fn compare(
  outcome: Verdict,
  candidate: List(#(String, Float)),
  baseline: List(#(String, Float)),
) -> Dominance {
  case outcome {
    verdict.Improved(..) -> Dominates(Outcome)
    verdict.Harmed(..) -> Dominated(Outcome)
    verdict.Indistinguishable(..) -> pareto(candidate, baseline)
    verdict.Underpowered(..) -> pareto(candidate, baseline)
    verdict.Incomplete(..) -> Undecided
  }
}

/// Pareto comparison of the candidate's scores against the baseline's over
/// the names both carry.
///
/// ## Examples
///
/// ```gleam
/// assert dominance.pareto([#("a", 1.0), #("b", 0.0)], [#("a", 0.0), #("b", 1.0)])
///   == Tradeoff(better: ["a"], worse: ["b"])
/// ```
///
/// ```gleam
/// assert dominance.pareto([#("a", 1.0)], [#("b", 1.0)]) == Undecided
/// ```
pub fn pareto(
  candidate: List(#(String, Float)),
  baseline: List(#(String, Float)),
) -> Dominance {
  let shared =
    list.filter_map(candidate, fn(score) {
      let #(name, ours) = score

      // A score only one arm reports has nothing to be compared against.
      case list.key_find(baseline, name) {
        Ok(theirs) -> Ok(#(name, compare_scores(ours, theirs)))
        Error(Nil) -> Error(Nil)
      }
    })
  let named = fn(wanted: Order) {
    list.filter_map(shared, fn(entry) {
      case entry.1 == wanted {
        True -> Ok(entry.0)
        False -> Error(Nil)
      }
    })
  }
  let better = named(order.Gt)
  let worse = named(order.Lt)

  // No shared name is no comparison. Otherwise: strictly better somewhere
  // and nowhere worse is dominance; the mirror is being dominated; neither
  // better nor worse anywhere is a tie; both is the trade-off no rule
  // resolves.
  case shared, better, worse {
    [], _, _ -> Undecided
    [_, ..], [], [] -> Tie
    [_, ..], [_, ..], [] -> Dominates(Scores)
    [_, ..], [], [_, ..] -> Dominated(Scores)
    [_, ..], [_, ..], [_, ..] -> Tradeoff(better:, worse:)
  }
}

/// `float.compare` with a non-number ranked below every number. A NaN is
/// the one float that is not greater than or equal to itself, which is the
/// only test for it the language offers without a target-specific external.
///
/// ## Examples
///
/// ```gleam
/// assert dominance.compare_scores(0.5, 0.25) == order.Gt
/// ```
pub fn compare_scores(ours: Float, theirs: Float) -> Order {
  case is_number(ours), is_number(theirs) {
    True, True -> float.compare(ours, theirs)
    True, False -> order.Gt
    False, True -> order.Lt
    False, False -> order.Eq
  }
}

fn is_number(x: Float) -> Bool {
  x >=. x
}
