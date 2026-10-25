//// Pairing: the task order is the same on both targets, and an arm is
//// never compared with itself.

import evalstat/pairing
import evalstat/passk
import evalstat/trial
import gleam/list
import gleam/order
import support/fixture

/// Task ids are ordered by code point, not by `string.compare`, which
/// orders UTF-8 bytes on the BEAM and UTF-16 code units on JavaScript and
/// so puts U+FF61 and U+1F600 in opposite orders on the two targets. The
/// bootstrap draws tasks by position, so the order has to be one order.
pub fn task_order_is_by_code_point_on_both_targets_test() {
  assert pairing.compare_task_ids("｡", "😀") == order.Lt
  assert pairing.compare_task_ids("😀", "｡") == order.Gt
  assert pairing.compare_task_ids("a", "a") == order.Eq
  assert pairing.compare_task_ids("a", "ab") == order.Lt

  let tasks = [
    #("😀", [#(trial.Fail, trial.Pass)]),
    #("a", [#(trial.Fail, trial.Pass)]),
    #("｡", [#(trial.Fail, trial.Pass)]),
  ]
  let rows = fixture.rows_of(tasks)
  let assert Ok(paired) = pairing.pair(rows, "a", "b", fixture.plan_of(tasks))
    as "three single-pair tasks pair"
  assert list.map(paired.tasks, fn(task) { task.task }) == ["a", "｡", "😀"]
  assert list.map(passk.task_counts(rows, "a"), fn(entry) { entry.0 })
    == ["a", "｡", "😀"]
}

/// Baseline and candidate must be different arms.
pub fn same_arm_is_refused_test() {
  let rows = [fixture.row("t", "a", 0, trial.Passed)]
  assert pairing.pair(rows, "a", "a", pairing.plan(["t"], 1))
    == Error(pairing.SameArm("a"))
  assert pairing.describe(pairing.SameArm("a"))
    == "baseline and candidate are both arm a"
}
