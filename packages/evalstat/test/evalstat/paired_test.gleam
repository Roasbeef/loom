//// The paired estimators: the clustered standard error, the interval, the
//// minimum detectable effect and the variance decomposition.

import evalstat/paired
import evalstat/pairing
import evalstat/trial.{Fail, Pass}
import gleam/float
import gleam/list
import support/fixture

/// Tasks whose pairs all agree within the task carry no within-task
/// variance, so the clustered standard error must equal the between-task
/// formula `√(Var(d_t) / T)` computed directly from the per-task
/// differences. Moving pairs between tasks keeps every per-pair difference
/// and changes the clustered error, where a per-pair (unclustered) error
/// would not move at all: that is the mutation this test catches.
pub fn paired_se_is_clustered_test() {
  let constant =
    fixture.paired([
      fixture.task("a", [#(Fail, Pass), #(Fail, Pass), #(Fail, Pass)]),
      fixture.task("b", [#(Pass, Pass), #(Pass, Pass), #(Pass, Pass)]),
      fixture.task("c", [#(Pass, Fail), #(Pass, Fail), #(Pass, Fail)]),
      fixture.task("d", [#(Fail, Fail), #(Fail, Fail), #(Fail, Fail)]),
    ])
  let differences = paired.differences(constant)
  assert differences == [1.0, 0.0, -1.0, 0.0]
  let between = float.square_root(paired.sample_variance(differences) /. 4.0)
  assert paired.clustered_se(differences) == between

  // The same twelve pairs with one pair of task a swapped into task c and
  // one of c into a: d_a and d_c move toward each other and the clustered
  // error shrinks, though the multiset of per-pair differences is unchanged.
  let shuffled =
    fixture.paired([
      fixture.task("a", [#(Fail, Pass), #(Fail, Pass), #(Pass, Fail)]),
      fixture.task("b", [#(Pass, Pass), #(Pass, Pass), #(Pass, Pass)]),
      fixture.task("c", [#(Pass, Fail), #(Pass, Fail), #(Fail, Pass)]),
      fixture.task("d", [#(Fail, Fail), #(Fail, Fail), #(Fail, Fail)]),
    ])
  let moved = paired.clustered_se(paired.differences(shuffled))
  assert moved != paired.clustered_se(differences)
  assert close(moved, float.square_root(2.0 /. 9.0 /. 3.0 /. 4.0))
}

/// Below two tasks there is no variance to estimate.
pub fn clustered_se_needs_two_tasks_test() {
  assert paired.clustered_se([]) == Error(Nil)
  assert paired.clustered_se([0.4]) == Error(Nil)
  assert paired.clustered_se([0.0, 1.0]) == Ok(0.5)
}

/// Interval and minimum detectable effect are the design's constants
/// applied to one standard error.
pub fn interval_and_mde_use_the_fixed_quantiles_test() {
  let #(low, high) = paired.interval(0.1, 0.05)
  assert float.loosely_equals(low, 0.002, 0.000000001)
  assert float.loosely_equals(high, 0.198, 0.000000001)
  assert float.loosely_equals(paired.mde(0.1), 0.28, 0.000000001)
}

/// `needed_tasks` solves the MDE formula for T and never answers below two.
pub fn needed_tasks_solves_for_t_test() {
  // s² = 0.5 (values 0 and 1): T ≥ (2.8 / 0.2)² · 0.5 = 98.
  assert paired.needed_tasks([0.0, 1.0], 0.2) == 98
  assert paired.needed_tasks([0.5, 0.5], 0.2) == 2
  assert paired.needed_tasks([0.0, 1.0], 0.0) == 2
  assert paired.needed_tasks([0.0, 1.0], 10.0) == 2
}

/// All the variance between tasks when pairs agree within each task; all
/// of it within when every task has the same mixed pairs.
pub fn decompose_attributes_variance_test() {
  let between_only =
    fixture.paired([
      fixture.task("a", [#(Fail, Pass), #(Fail, Pass)]),
      fixture.task("b", [#(Fail, Fail), #(Fail, Fail)]),
    ])
  assert paired.decompose(between_only)
    == Ok(paired.Decomposition(0.25, 0.0, paired.MoreTasks))

  let within_only =
    fixture.paired(
      list.map(["a", "b", "c", "d"], fn(name) {
        fixture.task(name, [#(Fail, Pass), #(Fail, Fail)])
      }),
    )
  let within = paired.decompose(within_only)
  assert within == Ok(paired.Decomposition(0.0, 0.0625, paired.MoreTrials))
  assert paired.decompose(fixture.paired([])) == Error(Nil)
}

/// Per-task rates on each side and the arm means over tasks.
pub fn rates_are_per_task_then_averaged_test() {
  let data =
    fixture.paired([
      fixture.task("a", [#(Pass, Fail), #(Pass, Pass)]),
      fixture.task("b", [
        #(Fail, Fail),
        #(Fail, Fail),
        #(Fail, Fail),
        #(Fail, Pass),
      ]),
    ])
  let assert [a, b] = data.tasks as "the fixture has two tasks"
  assert paired.rate(a, pairing.Baseline) == 1.0
  assert paired.rate(a, pairing.Candidate) == 0.5
  assert paired.rate(b, pairing.Candidate) == 0.25
  assert paired.arm_rates(data) == #(0.5, 0.375)
}

fn close(actual: Result(Float, Nil), expected: Result(Float, Nil)) -> Bool {
  case actual, expected {
    Ok(a), Ok(e) -> float.loosely_equals(a, e, 0.000000001)
    _, _ -> False
  }
}
