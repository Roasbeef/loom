//// pass@k and pass^k against brute-force subset enumeration.

import evalstat/passk
import evalstat/trial
import gleam/float
import gleam/int
import gleam/list
import qcheck
import support/fixture

/// How many `(n, c, k)` triples the brute-force property draws, and the
/// qcheck seed they come from. Fixed so the gate is deterministic.
const subset_count = 300

const subset_seed = 17

/// Over every `n ≤ 8`, `0 ≤ c ≤ n`, `1 ≤ k ≤ n`: the closed forms equal the
/// fraction of the `C(n, k)` subsets of trial positions (the first `c` of
/// which pass) that hold at least one pass, and that hold only passes.
/// The biased `1 − (1 − c/n)^k` disagrees on, for instance, `(4, 2, 2)`:
/// 0.75 against the unbiased 0.8333.
pub fn pass_at_k_unbiased_vs_bruteforce_test() {
  let triples =
    qcheck.bounded_int(1, 8)
    |> qcheck.bind(fn(n) {
      qcheck.map2(qcheck.bounded_int(0, n), qcheck.bounded_int(1, n), fn(c, k) {
        #(n, c, k)
      })
    })
  qcheck.default_config()
  |> qcheck.with_test_count(subset_count)
  |> qcheck.with_seed(qcheck.seed(subset_seed))
  |> qcheck.run(triples, fn(triple) {
    let #(n, c, k) = triple
    let #(any, all) = brute_force(n, c, k)
    assert close_result(passk.pass_at_k(n, c, k), any)
    assert close_result(passk.pass_pow_k(n, c, k), all)
  })
}

/// A plan that ran fewer trials than `k` asks for cannot answer, and says
/// so rather than reporting zero.
pub fn pass_at_k_refuses_k_above_n_test() {
  assert passk.pass_at_k(2, 1, 3) == Error(passk.KExceedsTrials(2, 3))
  assert passk.pass_pow_k(2, 1, 3) == Error(passk.KExceedsTrials(2, 3))
  assert passk.pass_at_k(2, 1, 0) == Error(passk.KNotPositive(0))
  assert passk.pass_at_k(2, 3, 1) == Error(passk.PassesOutOfRange(2, 3))
}

/// Per task, then averaged, with `Infrastructure` rows out of `n` and a
/// timeout counted as a failure.
pub fn arm_pass_at_k_averages_over_tasks_test() {
  let rows = [
    fixture.row("t1", "a", 0, trial.Passed),
    fixture.row("t1", "a", 1, trial.AgentTimeout),
    fixture.row("t1", "a", 2, trial.Infrastructure),
    fixture.row("t2", "a", 0, trial.Passed),
    fixture.row("t2", "a", 1, trial.Passed),
    fixture.row("t2", "b", 0, trial.VerifierFailed),
  ]
  assert passk.task_counts(rows, "a") == [#("t1", 2, 1), #("t2", 2, 2)]

  // t1: 1 − C(1,1)/C(2,1) = 0.5; t2: 1.0; mean 0.75.
  assert passk.arm_pass_at_k(rows, "a", 1) == Ok(0.75)
  assert passk.arm_pass_pow_k(rows, "a", 2) == Ok(0.5)
  assert passk.arm_pass_at_k(rows, "a", 3) == Error(passk.KExceedsTrials(2, 3))
  assert passk.arm_pass_at_k(rows, "c", 1) == Error(passk.NoTasks)
}

/// Enumerates the `k`-subsets of `n` positions as bitmasks and counts those
/// with at least one pass and those with only passes, where the passes are
/// positions below `c`.
fn brute_force(n: Int, c: Int, k: Int) -> #(Float, Float) {
  let masks = int.range(0, int.bitwise_shift_left(1, n), [], list.prepend)
  let subsets = list.filter(masks, fn(mask) { popcount(mask) == k })
  let passes_in = fn(mask) {
    popcount(int.bitwise_and(mask, int.bitwise_shift_left(1, c) - 1))
  }
  let total = int.to_float(list.length(subsets))
  let any = list.count(subsets, fn(mask) { passes_in(mask) > 0 })
  let all = list.count(subsets, fn(mask) { passes_in(mask) == k })
  #(int.to_float(any) /. total, int.to_float(all) /. total)
}

fn popcount(mask: Int) -> Int {
  case mask {
    0 -> 0
    _ -> mask % 2 + popcount(mask / 2)
  }
}

fn close_result(
  actual: Result(Float, passk.PassKError),
  expected: Float,
) -> Bool {
  case actual {
    Ok(value) -> float.loosely_equals(value, expected, 0.000000001)
    Error(_) -> False
  }
}
