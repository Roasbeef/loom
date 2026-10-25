//// The statistical acceptance as a value the host supplies, and the
//// simple rule shipped so the library is usable alone.
////
//// The search decides with four words (`verdict.Acceptance`); how the
//// words are earned is the host's. Loom decides with a paired task-level
//// rule over trial rows and keeps its effect sizes, intervals and power
//// in its own log; another host may decide with a threshold on the mean.
//// The library therefore takes the rule as a function over paired
//// per-task scores, and `sign_test` is the default: the exact two-sided
//// sign test over the per-task differences at `alpha`, with the direction
//// read from the mean. It weights every task equally, which is the
//// property a paired rule must have and the one a pooled trial count
//// loses when tasks ran different numbers of trials.
////
//// A pair exists only where both sides have a score. `pairs` drops tasks
//// missing on either side, and `next` in the state machine reads fewer
//// pairs than tasks as `Incomplete` before the judge is asked, so a judge
//// never sees a hole and mistakes it for a zero.

import gepa/verdict.{type Acceptance}
import gleam/float
import gleam/int
import gleam/list

/// One task's score under the baseline and under the candidate.
pub type Pair {
  Pair(
    /// The task id.
    task: String,
    /// The baseline's score on it.
    baseline: Float,
    /// The candidate's score on it.
    candidate: Float,
  )
}

/// The host's acceptance rule over paired per-task scores.
pub type Judge =
  fn(List(Pair)) -> Acceptance

/// The level the default sign test decides at.
pub const alpha = 0.05

/// The pairs of `tasks` for which both vectors carry a score, in task
/// order.
///
/// ## Examples
///
/// ```gleam
/// assert judge.pairs(["t"], [#("t", 0.0)], [#("t", 1.0)]) == [judge.Pair("t", 0.0, 1.0)]
/// assert judge.pairs(["t"], [], [#("t", 1.0)]) == []
/// ```
///
pub fn pairs(
  tasks: List(String),
  baseline: List(#(String, Float)),
  candidate: List(#(String, Float)),
) -> List(Pair) {
  list.filter_map(tasks, fn(task) {
    // A task scored on one side only is a hole, not a pair.
    case list.key_find(baseline, task), list.key_find(candidate, task) {
      Ok(theirs), Ok(ours) -> Ok(Pair(task:, baseline: theirs, candidate: ours))
      Error(Nil), _ | _, Error(Nil) -> Error(Nil)
    }
  })
}

/// The default rule: `Improved` when the mean difference is positive and
/// the exact two-sided sign test over the nonzero per-task differences has
/// `p < alpha`; `Harmed` in the mirror case; `Inconclusive` otherwise;
/// `Incomplete` with no pairs at all. Ties are dropped from the test, as
/// the sign test prescribes, but counted in the mean.
///
/// ## Examples
///
/// ```gleam
/// // Six tasks, every one better: p = 2 / 64 < 0.05.
/// assert judge.sign_test(list.map(tasks, fn(t) { judge.Pair(t, 0.0, 1.0) })) == verdict.Improved
/// assert judge.sign_test([]) == verdict.Incomplete
/// ```
///
pub fn sign_test(paired: List(Pair)) -> Acceptance {
  let differences =
    list.map(paired, fn(pair) { pair.candidate -. pair.baseline })
  let positive = list.count(differences, fn(d) { d >. 0.0 })
  let negative = list.count(differences, fn(d) { d <. 0.0 })

  // The mean of nothing is zero, so no pairs cannot read as a direction.
  let mean = case differences {
    [] -> 0.0
    [_, ..] ->
      list.fold(differences, 0.0, float.add)
      /. int.to_float(list.length(differences))
  }

  let p = sign_p_value(positive, negative)

  // The direction is the mean's; the test says whether the direction is
  // more than chance at this many tasks.
  case paired, p <. alpha, mean >. 0.0, mean <. 0.0 {
    [], _, _, _ -> verdict.Incomplete
    [_, ..], True, True, _ -> verdict.Improved
    [_, ..], True, _, True -> verdict.Harmed
    [_, ..], _, _, _ -> verdict.Inconclusive
  }
}

/// The exact two-sided sign test: `min(1, 2 · P[X ≤ min(+, −)])` for
/// `X ~ Binomial(+ + −, 1/2)`. One with no nonzero difference: nothing
/// to test.
///
/// ## Examples
///
/// ```gleam
/// assert judge.sign_p_value(5, 0) == 0.0625
/// assert judge.sign_p_value(0, 0) == 1.0
/// ```
///
pub fn sign_p_value(positive: Int, negative: Int) -> Float {
  let n = positive + negative
  let smaller = int.min(positive, negative)

  // The lower tail, summed term by term from the exact binomial mass.
  let tail = lower_tail(n, smaller, 0, 0.0) /. float_power_of_two(n)

  float.min(1.0, 2.0 *. tail)
}

/// `sum over k in [0, upto] of (n choose k)`, accumulated from `k`.
fn lower_tail(n: Int, upto: Int, k: Int, sum: Float) -> Float {
  // Each term is one binomial coefficient; the walk ends past `upto`.
  case k > upto {
    True -> sum
    False -> lower_tail(n, upto, k + 1, sum +. choose(n, k))
  }
}

/// `n choose k` as a float, by the multiplicative formula, exact enough
/// for the task counts a search has.
fn choose(n: Int, k: Int) -> Float {
  choose_from(n, k, 1, 1.0)
}

/// The multiplicative formula, one factor `(n - k + i) / i` at a time.
fn choose_from(n: Int, k: Int, i: Int, product: Float) -> Float {
  // The product closes once every factor up to `k` is in.
  case i > k {
    True -> product
    False ->
      choose_from(
        n,
        k,
        i + 1,
        product *. int.to_float(n - k + i) /. int.to_float(i),
      )
  }
}

/// `2^n` as a float.
fn float_power_of_two(n: Int) -> Float {
  list.repeat(2.0, n) |> list.fold(1.0, float.multiply)
}
