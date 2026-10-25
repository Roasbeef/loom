//// pass@k and pass^k: what a budget of `k` attempts buys, and how reliably
//// a single attempt lands.
////
//// Both are per-task estimators computed from `n` counted trials of which
//// `c` passed, then averaged over tasks, because a task is the unit the
//// instrument samples and averaging raw trials would weight a task by how
//// many of its trials survived exclusion.
////
//// pass@k is the unbiased estimator of Chen et al. (2021): the chance that
//// at least one of `k` trials drawn without replacement from the `n`
//// passes, `1 − C(n − c, k) / C(n, k)`. The naive `1 − (1 − c/n)^k`
//// overstates it, and `pass_at_k_unbiased_vs_bruteforce_test` is the
//// mutation that tells them apart. pass^k is τ-bench's reliability
//// estimator, `C(c, k) / C(n, k)`: the chance that all `k` pass.
////
//// Both refuse `k > n` with an `Error` rather than answering zero. A zero
//// would read as "never passes", which is a claim about the arm; the truth
//// is that the plan did not run enough trials to ask the question.

import evalstat/trial.{type Trial}
import gleam/bool
import gleam/dict
import gleam/float
import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// Why an estimate could not be formed. Every variant is a defect of the
/// question, not of the arm.
pub type PassKError {
  /// `k` is below one.
  KNotPositive(k: Int)

  /// A task has fewer counted trials than `k`.
  KExceedsTrials(n: Int, k: Int)

  /// The pass count lies outside `[0, n]`.
  PassesOutOfRange(n: Int, c: Int)

  /// The arm has no counted trial on any task.
  NoTasks
}

/// Unbiased pass@k for one task with `n` counted trials and `c` passes.
///
/// ## Examples
///
/// ```gleam
/// assert passk.pass_at_k(n: 4, c: 2, k: 2) == Ok(0.8333333333333334)
/// ```
///
/// ```gleam
/// assert passk.pass_at_k(n: 2, c: 1, k: 3) == Error(KExceedsTrials(2, 3))
/// ```
pub fn pass_at_k(n n: Int, c c: Int, k k: Int) -> Result(Float, PassKError) {
  use Nil <- result.try(check(n, c, k))

  // Fewer failures than draws means every draw of `k` holds a pass.
  use <- bool.guard(when: n - c < k, return: Ok(1.0))
  Ok(1.0 -. falling_ratio(n - c, n, k))
}

/// pass^k for one task: the chance all `k` of `k` trials drawn without
/// replacement pass.
///
/// ## Examples
///
/// ```gleam
/// assert passk.pass_pow_k(n: 4, c: 2, k: 2) == Ok(0.16666666666666666)
/// ```
///
/// ```gleam
/// assert passk.pass_pow_k(n: 4, c: 1, k: 2) == Ok(0.0)
/// ```
pub fn pass_pow_k(n n: Int, c c: Int, k k: Int) -> Result(Float, PassKError) {
  use Nil <- result.try(check(n, c, k))

  // Fewer passes than draws means no draw of `k` is all passes.
  use <- bool.guard(when: c < k, return: Ok(0.0))
  Ok(falling_ratio(c, n, k))
}

/// pass@k of one arm over a ledger: per task, then averaged. Rows of other
/// arms and `Infrastructure` rows are not counted; a task must still have
/// at least `k` counted trials or the whole estimate refuses.
///
/// ## Examples
///
/// ```gleam
/// assert passk.arm_pass_at_k([], "a", 1) == Error(NoTasks)
/// ```
pub fn arm_pass_at_k(
  rows: List(Trial),
  arm: String,
  k: Int,
) -> Result(Float, PassKError) {
  average_over_tasks(rows, arm, fn(n, c) { pass_at_k(n, c, k) })
}

/// pass^k of one arm over a ledger, per task then averaged, under the same
/// exclusions as `arm_pass_at_k`.
///
/// ## Examples
///
/// ```gleam
/// assert passk.arm_pass_pow_k([], "a", 1) == Error(NoTasks)
/// ```
pub fn arm_pass_pow_k(
  rows: List(Trial),
  arm: String,
  k: Int,
) -> Result(Float, PassKError) {
  average_over_tasks(rows, arm, fn(n, c) { pass_pow_k(n, c, k) })
}

/// `(n, c)` per task for one arm, counted trials only, in task-id order.
///
/// ## Examples
///
/// ```gleam
/// assert passk.task_counts([], "a") == []
/// ```
pub fn task_counts(
  rows: List(Trial),
  arm: String,
) -> List(#(String, Int, Int)) {
  list.filter(rows, fn(row) { row.arm == arm })
  |> list.filter_map(fn(row) {
    // Only counted rows reach the tally; an excluded row is not a trial.
    case trial.standing(row.outcome) {
      trial.Counted(fate) -> Ok(#(row.task, fate))
      trial.Excluded -> Error(Nil)
    }
  })
  |> list.group(fn(entry) { entry.0 })
  |> dict.to_list
  |> list.sort(fn(left, right) { string.compare(left.0, right.0) })
  |> list.map(fn(entry) {
    let #(task, fates) = entry
    let passes = list.count(fates, fn(fate) { fate.1 == trial.Pass })
    #(task, list.length(fates), passes)
  })
}

/// Applies a per-task estimator to every task of an arm and averages,
/// refusing when there is nothing to average.
fn average_over_tasks(
  rows: List(Trial),
  arm: String,
  estimate: fn(Int, Int) -> Result(Float, PassKError),
) -> Result(Float, PassKError) {
  let counts = task_counts(rows, arm)
  use <- bool.guard(when: counts == [], return: Error(NoTasks))
  use values <- result.try(
    list.try_map(counts, fn(entry) { estimate(entry.1, entry.2) }),
  )
  Ok(float.sum(values) /. int.to_float(list.length(values)))
}

/// Refuses the questions the estimators cannot answer.
fn check(n: Int, c: Int, k: Int) -> Result(Nil, PassKError) {
  use <- bool.guard(when: k < 1, return: Error(KNotPositive(k)))
  use <- bool.guard(when: c < 0 || c > n, return: Error(PassesOutOfRange(n, c)))
  use <- bool.guard(when: k > n, return: Error(KExceedsTrials(n, k)))
  Ok(Nil)
}

/// `C(m, k) / C(n, k)` as the product `∏_{i<k} (m − i) / (n − i)`, which
/// never forms a coefficient and so cannot overflow; each factor is in
/// `[0, 1]`, so the product is exact to a few units in the last place for
/// `n ≤ 1000`. Requires `k ≤ m ≤ n`.
fn falling_ratio(m: Int, n: Int, k: Int) -> Float {
  int.range(0, k, 1.0, fn(product, i) {
    product *. int.to_float(m - i) /. int.to_float(n - i)
  })
}
