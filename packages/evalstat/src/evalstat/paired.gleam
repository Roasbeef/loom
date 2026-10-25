//// The paired estimators: effect, clustered standard error, interval,
//// minimum detectable effect, and the variance decomposition that says
//// which budget to spend next.
////
//// The unit of analysis is the task, not the trial. Trials nest inside
//// tasks and share the task's difficulty, so treating `T·K` trials as
//// independent would understate the error by roughly `√K` and the decision
//// rule would call noise a result. Every quantity here is therefore built
//// from the per-task differences `d_t = p̂_tB − p̂_tA`: their mean is the
//// effect, their spread over `T(T − 1)` is the clustered standard error
//// (Miller 2024 §4), and the interval and minimum detectable effect follow
//// from that one standard error.
////
//// Two readers rely on the shape of the answers. The decision rule needs
//// an `Error` when `T < 2`, because a variance over one cluster does not
//// exist and a zero in its place would make a single task look infinitely
//// precise. The report needs `needed_tasks` and `decompose`, which turn the
//// same per-task numbers into advice: how many tasks would make the target
//// effect visible, and whether the remaining noise is between tasks (buy
//// tasks) or within them (buy trials).

import evalstat/pairing.{type Paired, type TaskPairs}
import evalstat/trial
import gleam/bool
import gleam/float
import gleam/int
import gleam/list

/// The two-sided 95 % normal quantile. Fixed because the design fixes
/// `α = 0.05`; another level needs a z table, which the cut list excludes.
pub const z_alpha = 1.96

/// The one-sided 80 % normal quantile the minimum detectable effect uses.
pub const z_power = 0.84

/// Which input shrinks the error faster.
pub type Lever {
  /// Between-task variance dominates: sample more tasks.
  MoreTasks

  /// Within-task variance dominates: run more trials per task.
  MoreTrials
}

/// The variance of the mean difference split into its two sources, both
/// already divided by `T` so they sum to the estimated `Var(d̄)`.
pub type Decomposition {
  Decomposition(
    /// `(1/T) · Var_t(E[d | t])`: how much tasks differ in their effect.
    between: Float,
    /// `(1/T) · E_t(Var(d | t) / n_t)`: how much trials differ within a
    /// task, already shrunk by the trials each task ran.
    within: Float,
    /// Which component is larger.
    lever: Lever,
  )
}

/// One arm's pass rate on one task, over the task's surviving pairs.
///
/// ## Examples
///
/// ```gleam
/// let pairs = [Pair(0, trial.Pass, trial.Fail), Pair(1, trial.Pass, trial.Pass)]
/// assert paired.rate(TaskPairs("t", pairs), pairing.Candidate) == 0.5
/// ```
pub fn rate(task: TaskPairs, side: pairing.Side) -> Float {
  let passes =
    list.fold(task.pairs, 0.0, fn(sum, pair) {
      sum +. trial.indicator(pairing.side(pair, side))
    })
  passes /. int.to_float(list.length(task.pairs))
}

/// `d_t`: the candidate's rate minus the baseline's on one task.
///
/// ## Examples
///
/// ```gleam
/// let pairs = [Pair(0, trial.Pass, trial.Fail), Pair(1, trial.Pass, trial.Pass)]
/// assert paired.difference(TaskPairs("t", pairs)) == -0.5
/// ```
pub fn difference(task: TaskPairs) -> Float {
  rate(task, pairing.Candidate) -. rate(task, pairing.Baseline)
}

/// Every task's `d_t`, in task order.
///
/// ## Examples
///
/// ```gleam
/// assert paired.differences(Paired([], 0, 0)) == []
/// ```
pub fn differences(paired: Paired) -> List(Float) {
  list.map(paired.tasks, difference)
}

/// The arithmetic mean, zero for an empty list. Callers that need to tell
/// "no data" from "no effect" check `T` first; the estimators here do.
///
/// ## Examples
///
/// ```gleam
/// assert paired.mean([0.5, 1.0]) == 0.75
/// ```
pub fn mean(values: List(Float)) -> Float {
  use <- bool.guard(when: values == [], return: 0.0)
  float.sum(values) /. int.to_float(list.length(values))
}

/// The task-clustered standard error of the mean difference,
/// `√(Σ (d_t − d̄)² / (T(T − 1)))`, or `Error` when fewer than two tasks
/// leave the variance undefined.
///
/// ## Examples
///
/// ```gleam
/// assert paired.clustered_se([0.0, 1.0]) == Ok(0.5)
/// ```
///
/// ```gleam
/// assert paired.clustered_se([0.3]) == Error(Nil)
/// ```
pub fn clustered_se(differences: List(Float)) -> Result(Float, Nil) {
  let t = list.length(differences)
  use <- bool.guard(when: t < 2, return: Error(Nil))
  let variance = sample_variance(differences)
  float.square_root(variance /. int.to_float(t))
}

/// `d̄ ± z_alpha · SE`.
///
/// ## Examples
///
/// ```gleam
/// assert paired.interval(0.1, 0.05) == #(0.002, 0.198)
/// ```
pub fn interval(effect: Float, se: Float) -> #(Float, Float) {
  #(effect -. z_alpha *. se, effect +. z_alpha *. se)
}

/// The minimum detectable effect at `α = 0.05` and power 0.8,
/// `(z_alpha + z_power) · SE`: the smallest true difference this many
/// tasks would catch four times in five.
///
/// ## Examples
///
/// ```gleam
/// assert paired.mde(0.1) == 0.28
/// ```
pub fn mde(se: Float) -> Float {
  { z_alpha +. z_power } *. se
}

/// The smallest task count at which the minimum detectable effect, from
/// the observed per-task variance, would be at or below `target`. Never
/// below two, because no variance exists below two; two when the observed
/// variance is zero or the target is not positive.
///
/// ## Examples
///
/// ```gleam
/// // Sample variance 0.5: MDE(T) = 2.8 · √(0.5 / T) ≤ 0.2 needs T ≥ 98.
/// assert paired.needed_tasks([0.0, 1.0], 0.2) == 98
/// ```
pub fn needed_tasks(differences: List(Float), target: Float) -> Int {
  needed_tasks_for_variance(sample_variance(differences), target)
}

/// `needed_tasks` for a per-task variance given directly, which is how the
/// plug-in floor is turned into a task count when the observed variance is
/// zero.
///
/// ## Examples
///
/// ```gleam
/// assert paired.needed_tasks_for_variance(0.5, 0.2) == 98
/// ```
pub fn needed_tasks_for_variance(variance: Float, target: Float) -> Int {
  use <- bool.guard(when: target <=. 0.0 || variance <=. 0.0, return: 2)

  // Solving `(z_alpha + z_power) · √(s² / T) ≤ target` for `T`.
  let scale = { z_alpha +. z_power } /. target
  let needed = float.ceiling(scale *. scale *. variance)
  int.max(2, float.round(needed))
}

/// The binomial plug-in variance of one task's difference, the floor the
/// decision rule uses when the observed spread between tasks is zero: a
/// Bernoulli outcome with pooled pass rate `p̄` over `K̄` pairs per task
/// cannot have a smaller difference variance than `2 · p̄(1 − p̄) / K̄`.
/// When the pooled rate is itself zero or one, nothing varies at all and
/// the least informative value, `p̄(1 − p̄) = 1/4`, stands in: a plan with no
/// variation has not shown that it could see any effect.
///
/// ## Examples
///
/// ```gleam
/// // 5/5 against 0/5, one pair per task: pooled rate 1/2, so 2 · 1/4 / 1.
/// let tasks = list.map(["a", "b", "c", "d", "e"], fn(t) { TaskPairs(t, [Pair(0, trial.Fail, trial.Pass)]) })
/// assert paired.plugin_variance(Paired(tasks, 0, 0)) == 0.5
/// ```
pub fn plugin_variance(paired: Paired) -> Float {
  let pairs = list.flat_map(paired.tasks, fn(task) { task.pairs })
  let count = int.to_float(list.length(pairs))
  use <- bool.guard(when: pairs == [], return: 0.5)
  let passes =
    list.fold(pairs, 0.0, fn(sum, pair) {
      sum +. trial.indicator(pair.baseline) +. trial.indicator(pair.candidate)
    })
  let pooled = passes /. { 2.0 *. count }
  let spread = pooled *. { 1.0 -. pooled }

  // A pooled rate of exactly zero or one means every trial on both arms
  // agreed; the floor then takes the maximum Bernoulli variance.
  let spread = case spread <=. 0.0 {
    True -> 0.25
    False -> spread
  }

  let mean_pairs = count /. int.to_float(list.length(paired.tasks))
  2.0 *. spread /. mean_pairs
}

/// Splits the estimated `Var(d̄)` into its between-task and within-task
/// parts. The observed variance of `d_t` holds both, so the between part is
/// what remains once the within part, estimated from each task's own
/// pairs, is removed; it is floored at zero because an estimate cannot be
/// negative even when the sample says so. `Error` below two tasks.
///
/// ## Examples
///
/// ```gleam
/// // Every pair inside a task agrees with its siblings, so all the variance
/// // is between tasks.
/// let same = fn(task, fate) { TaskPairs(task, [Pair(0, trial.Fail, fate), Pair(1, trial.Fail, fate)]) }
/// let paired = Paired([same("a", trial.Pass), same("b", trial.Fail)], 0, 0)
/// assert paired.decompose(paired) == Ok(Decomposition(0.25, 0.0, MoreTasks))
/// ```
pub fn decompose(paired: Paired) -> Result(Decomposition, Nil) {
  let t = list.length(paired.tasks)
  use <- bool.guard(when: t < 2, return: Error(Nil))
  let t_float = int.to_float(t)
  let observed = sample_variance(differences(paired))

  // The within part of each `d_t` is the sample variance of the task's
  // per-pair differences over its `n_t` pairs; a task with one pair has no
  // within variance to estimate and contributes zero.
  let within_terms =
    list.map(paired.tasks, fn(task) {
      let per_pair =
        list.map(task.pairs, fn(pair) {
          trial.indicator(pair.candidate) -. trial.indicator(pair.baseline)
        })
      sample_variance(per_pair) /. int.to_float(list.length(per_pair))
    })
  let within_of_dt = mean(within_terms)
  let between_of_dt = float.max(0.0, observed -. within_of_dt)
  let between = between_of_dt /. t_float
  let within = within_of_dt /. t_float

  // More trials help only where the noise is inside tasks; otherwise the
  // next task is worth more than the next trial.
  let lever = case within >. between {
    True -> MoreTrials
    False -> MoreTasks
  }

  Ok(Decomposition(between:, within:, lever:))
}

/// The unbiased sample variance `Σ (x − x̄)² / (n − 1)`, zero below two
/// values so a one-task cluster cannot inflate a sum it appears in.
///
/// ## Examples
///
/// ```gleam
/// assert paired.sample_variance([0.0, 1.0]) == 0.5
/// ```
pub fn sample_variance(values: List(Float)) -> Float {
  let n = list.length(values)
  use <- bool.guard(when: n < 2, return: 0.0)
  let centre = mean(values)
  let squares =
    list.fold(values, 0.0, fn(sum, x) {
      let d = x -. centre
      sum +. d *. d
    })
  squares /. int.to_float(n - 1)
}

/// The two arms' overall rates, each the mean of its per-task rates, for
/// the report's first line.
///
/// ## Examples
///
/// ```gleam
/// assert paired.arm_rates(Paired([], 0, 0)) == #(0.0, 0.0)
/// ```
pub fn arm_rates(paired: Paired) -> #(Float, Float) {
  let tasks = paired.tasks
  let per_side = fn(side) {
    list.map(tasks, fn(task) { rate(task, side) }) |> mean
  }
  #(per_side(pairing.Baseline), per_side(pairing.Candidate))
}
