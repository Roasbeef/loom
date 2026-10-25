//// The cluster bootstrap keeps the pairing and is reproducible from its
//// seed.

import evalstat/bootstrap
import evalstat/paired
import evalstat/pairing
import evalstat/trial.{Fail, Pass}
import gleam/list
import support/fixture

/// Tasks whose per-arm rates differ a great deal but whose paired
/// difference is the same everywhere: each task's candidate rate is its
/// baseline rate plus one quarter. A bootstrap that redraws tasks and takes
/// each drawn task's own `d_t` sees the same mean in every resample and a
/// zero-width interval. Drawing the two arms' tasks independently would
/// pair one task's candidate rate with another task's baseline rate and
/// spread the resampled means across the rates' whole range; so would
/// resampling pairs inside a task, since the pairs disagree within each
/// task. Duplicating every task's pairs in both arms leaves the centre
/// where it was, since each task's rates are unchanged.
pub fn bootstrap_keeps_pairing_test() {
  let rising = [
    fixture.task("a", [
      #(Fail, Fail),
      #(Fail, Fail),
      #(Fail, Fail),
      #(Fail, Pass),
    ]),
    fixture.task("b", [
      #(Fail, Pass),
      #(Pass, Pass),
      #(Fail, Fail),
      #(Fail, Fail),
    ]),
    fixture.task("c", [
      #(Pass, Pass),
      #(Pass, Pass),
      #(Fail, Pass),
      #(Fail, Fail),
    ]),
    fixture.task("d", [
      #(Pass, Pass),
      #(Pass, Pass),
      #(Pass, Pass),
      #(Fail, Pass),
    ]),
  ]
  let data = fixture.paired(rising)
  assert bootstrap.interval(data, 500, "plan") == Ok(#(0.25, 0.25))

  // The marginal rates really do differ across tasks, which is what an
  // unpaired resample would have mixed.
  let assert [first, _, _, last] = data.tasks as "four tasks"
  assert paired.rate(first, pairing.Baseline) == 0.0
  assert paired.rate(last, pairing.Baseline) == 0.75

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
  assert single == twice
  assert centre(single) >. 0.2 && centre(single) <. 0.6
}

/// The same seed gives the same interval, the percentile ranks are
/// symmetric, and the degenerate inputs refuse.
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

  // Two tasks, d = 1 and d = 0, resampled 40 times: the means are 0, 0.5 or
  // 1, and the 2.5 % ranks from either end (the first and the last) are the
  // extremes, so the interval is the whole range however the draws fall.
  let coin =
    fixture.paired([
      fixture.task("a", [#(Fail, Pass)]),
      fixture.task("b", [#(Fail, Fail)]),
    ])
  assert bootstrap.interval(coin, 40, "plan-1") == Ok(#(0.0, 1.0))
}

fn fates(task: pairing.TaskPairs) -> List(#(trial.Fate, trial.Fate)) {
  list.map(task.pairs, fn(pair) { #(pair.baseline, pair.candidate) })
}

fn centre(interval: Result(#(Float, Float), Nil)) -> Float {
  case interval {
    Ok(#(low, high)) -> { low +. high } /. 2.0
    Error(Nil) -> -10.0
  }
}
