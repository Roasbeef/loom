//// The exact sign test over discordant pairs: the significance half of the
//// decision rule.
////
//// Two arms that ran the same `(task, index)` either agreed or did not. The
//// agreeing pairs carry no information about which arm is better; only the
//// discordant ones do, and under the null of no difference each discordant
//// pair favours either arm with probability one half. The test is
//// therefore a fair-coin test on the discordant count, computed exactly
//// from `binomial.half_cdf` because the count is tens, where a normal
//// approximation (the classical McNemar statistic) is at its worst.
////
//// The pairing is what makes this valid. Trials on the same task share the
//// task's difficulty, and comparing a pass rate across arms without pairing
//// would charge that shared difficulty to the arms. Comparing within a pair
//// cancels it, which is why `pairing` keeps the same index on both arms and
//// why `bootstrap` resamples the index for both arms at once.

import evalstat/binomial
import evalstat/pairing.{type Paired}
import evalstat/trial
import gleam/float
import gleam/int
import gleam/list

/// The discordant counts, in the design note's letters: `b` is a baseline
/// pass the candidate failed, `c` is a candidate pass the baseline failed.
pub type Discordant {
  Discordant(
    /// `b`: pairs where only the baseline passed.
    baseline_only: Int,
    /// `c`: pairs where only the candidate passed.
    candidate_only: Int,
  )
}

/// Counts the discordant pairs across every task.
///
/// ## Examples
///
/// ```gleam
/// let pairs = [Pair(0, trial.Pass, trial.Fail), Pair(1, trial.Fail, trial.Pass), Pair(2, trial.Pass, trial.Pass)]
/// assert mcnemar.discordant(Paired([TaskPairs("t", pairs)], 0, 0)) == Discordant(1, 1)
/// ```
pub fn discordant(paired: Paired) -> Discordant {
  list.flat_map(paired.tasks, fn(task) { task.pairs })
  |> list.fold(Discordant(0, 0), fn(counts, pair) {
    case pair.baseline, pair.candidate {
      trial.Pass, trial.Fail ->
        Discordant(..counts, baseline_only: counts.baseline_only + 1)
      trial.Fail, trial.Pass ->
        Discordant(..counts, candidate_only: counts.candidate_only + 1)
      trial.Pass, trial.Pass -> counts
      trial.Fail, trial.Fail -> counts
    }
  })
}

/// The exact two-sided p-value: `min(1, 2 · P[X ≤ min(b, c)])` with
/// `X ~ Binomial(b + c, ½)`. No discordant pairs is no evidence, so `p = 1`.
///
/// ## Examples
///
/// ```gleam
/// assert mcnemar.p_value(Discordant(0, 0)) == 1.0
/// ```
///
/// ```gleam
/// assert mcnemar.p_value(Discordant(0, 5)) == 0.0625
/// ```
pub fn p_value(counts: Discordant) -> Float {
  let Discordant(b, c) = counts
  let tail = binomial.half_cdf(b + c, int.min(b, c))
  float.min(1.0, 2.0 *. tail)
}
