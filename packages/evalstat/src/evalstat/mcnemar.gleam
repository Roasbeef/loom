//// The exact sign tests: over tasks, which decides, and over pairs, which
//// is reported.
////
//// The decision rule weights every task equally, as its clustered interval
//// does, so the test it reads is the task-level sign test: each task with
//// a non-zero difference `d_t` is one fair-coin flip under the null, and
//// the ties are dropped. A pair-level test weights pairs equally instead,
//// and when tasks have unequal pair counts (uneven `K`, or `Infrastructure`
//// drops) the two can point in opposite directions: ten one-pair tasks the
//// candidate won against one hundred-pair task it lost is a candidate
//// win by tasks and a baseline rout by pairs. The pair-level McNemar count
//// is still computed, because a report wants it, but it no longer decides.
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

/// The task-level counts: how many tasks the candidate won and lost.
pub type Signs {
  Signs(
    /// Tasks with `d_t > 0`: the candidate's rate was higher.
    positive: Int,
    /// Tasks with `d_t < 0`: the baseline's rate was higher.
    negative: Int,
  )
}

/// Counts the signs of the per-task differences; ties contribute nothing.
///
/// ## Examples
///
/// ```gleam
/// assert mcnemar.task_signs([0.5, -0.25, 0.0, 1.0]) == Signs(2, 1)
/// ```
pub fn task_signs(differences: List(Float)) -> Signs {
  list.fold(differences, Signs(0, 0), fn(signs, d) {
    case d >. 0.0, d <. 0.0 {
      True, _ -> Signs(..signs, positive: signs.positive + 1)
      False, True -> Signs(..signs, negative: signs.negative + 1)
      False, False -> signs
    }
  })
}

/// The exact two-sided task-level sign test:
/// `min(1, 2 · P[X ≤ min(positive, negative)])`, `X ~ Binomial(n, ½)` with
/// `n` the non-tied tasks. No non-tied task is no evidence, so `p = 1`.
///
/// ## Examples
///
/// ```gleam
/// assert mcnemar.sign_p_value(Signs(5, 0)) == 0.0625
/// ```
pub fn sign_p_value(signs: Signs) -> Float {
  two_sided(signs.positive, signs.negative)
}

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
  two_sided(counts.baseline_only, counts.candidate_only)
}

/// `min(1, 2 · P[X ≤ min(a, b)])` for `X ~ Binomial(a + b, ½)`.
fn two_sided(a: Int, b: Int) -> Float {
  let tail = binomial.half_cdf(a + b, int.min(a, b))
  float.min(1.0, 2.0 *. tail)
}
