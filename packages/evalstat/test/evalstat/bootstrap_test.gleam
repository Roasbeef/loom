//// The nested bootstrap keeps the pairing and is reproducible from its
//// seed.

import evalstat/bootstrap
import evalstat/pairing.{type Paired}
import evalstat/trial.{Fail, Pass}
import gleam/float
import gleam/list
import support/fixture

/// Arms that agree on every pair have a per-pair difference of zero
/// everywhere, so a bootstrap that redraws the same positions from both
/// arms sees a mean of exactly zero in every resample and a zero-width
/// interval. The same fates with the candidate's shuffled within each
/// task have the same marginal rates and a positive width, so the zero
/// width is the pairing and not the data; drawing the arms' positions
/// independently would turn the first interval into the second.
///
/// Duplicating every task's pairs in both arms leaves the centre where it
/// was, since each task's rates are unchanged.
pub fn bootstrap_keeps_pairing_test() {
  let agreeing = [
    fixture.task("a", [#(Pass, Pass), #(Fail, Fail), #(Pass, Pass)]),
    fixture.task("b", [#(Fail, Fail), #(Fail, Fail), #(Pass, Pass)]),
    fixture.task("c", [#(Pass, Pass), #(Pass, Pass), #(Fail, Fail)]),
    fixture.task("d", [#(Fail, Fail), #(Pass, Pass), #(Pass, Pass)]),
  ]
  assert bootstrap.interval(fixture.paired(agreeing), 500, "plan")
    == Ok(#(0.0, 0.0))

  // Each task's candidate column rotated by one position: marginals equal,
  // pairs broken in the data itself.
  let unpaired = [
    fixture.task("a", [#(Pass, Pass), #(Fail, Pass), #(Pass, Fail)]),
    fixture.task("b", [#(Fail, Pass), #(Fail, Fail), #(Pass, Fail)]),
    fixture.task("c", [#(Pass, Fail), #(Pass, Pass), #(Fail, Pass)]),
    fixture.task("d", [#(Fail, Pass), #(Pass, Fail), #(Pass, Pass)]),
  ]
  assert width(fixture.paired(unpaired), "plan") >. 0.0

  // A real effect, then the same data with every pair duplicated.
  let effect = [
    fixture.task("a", [#(Fail, Pass), #(Fail, Pass), #(Pass, Pass)]),
    fixture.task("b", [#(Fail, Fail), #(Fail, Pass), #(Pass, Pass)]),
    fixture.task("c", [#(Pass, Fail), #(Fail, Pass), #(Fail, Pass)]),
    fixture.task("d", [#(Fail, Pass), #(Pass, Pass), #(Fail, Fail)]),
    fixture.task("e", [#(Fail, Pass), #(Fail, Fail), #(Fail, Pass)]),
  ]
  let doubled =
    list.map(effect, fn(task) {
      fixture.task(task.task, list.append(fates(task), fates(task)))
    })
  let single = bootstrap.interval(fixture.paired(effect), 2000, "plan")
  let twice = bootstrap.interval(fixture.paired(doubled), 2000, "plan")
  assert float.absolute_value(centre(single) -. centre(twice)) <. 0.05
}

/// The same seed gives the same interval; a different seed may not.
pub fn bootstrap_is_reproducible_from_seed_test() {
  let data =
    fixture.paired([
      fixture.task("a", [#(Fail, Pass), #(Fail, Fail), #(Pass, Pass)]),
      fixture.task("b", [#(Fail, Fail), #(Fail, Pass), #(Pass, Fail)]),
      fixture.task("c", [#(Pass, Fail), #(Fail, Pass), #(Fail, Pass)]),
    ])
  assert bootstrap.interval(data, 200, "plan-1")
    == bootstrap.interval(data, 200, "plan-1")
  assert bootstrap.interval(data, 0, "plan-1") == Error(Nil)
  assert bootstrap.interval(fixture.paired([]), 200, "plan-1") == Error(Nil)
}

fn fates(task: pairing.TaskPairs) -> List(#(trial.Fate, trial.Fate)) {
  list.map(task.pairs, fn(pair) { #(pair.baseline, pair.candidate) })
}

fn width(data: Paired, seed: String) -> Float {
  case bootstrap.interval(data, 500, seed) {
    Ok(#(low, high)) -> high -. low
    Error(Nil) -> -1.0
  }
}

fn centre(interval: Result(#(Float, Float), Nil)) -> Float {
  case interval {
    Ok(#(low, high)) -> { low +. high } /. 2.0
    Error(Nil) -> -10.0
  }
}
