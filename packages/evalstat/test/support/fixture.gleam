//// Row builders the evalstat tests share, so each test spells only the
//// coordinates and the outcome it is about.

import evalstat/pairing.{type Paired, type TaskPairs, Pair, Paired, TaskPairs}
import evalstat/trial.{type Fate, type Outcome, type Trial, Cost, Trial}
import gleam/list

/// A trial with the given coordinates and outcome, zero cost and reward.
pub fn row(task: String, arm: String, index: Int, outcome: Outcome) -> Trial {
  Trial(
    task:,
    arm:,
    index:,
    reward: 0.0,
    scores: [],
    outcome:,
    cost: Cost(tokens: 0, dollars: 0.0, turns: 0, tool_errors: 0, wall_ms: 0),
  )
}

/// The outcome a fate came from, for building rows from fate pairs.
pub fn outcome_of(fate: Fate) -> Outcome {
  case fate {
    trial.Pass -> trial.Passed
    trial.Fail -> trial.VerifierFailed
  }
}

/// A task's pairs from a list of `(baseline, candidate)` fates, indexed in
/// order.
pub fn task(name: String, fates: List(#(Fate, Fate))) -> TaskPairs {
  TaskPairs(
    name,
    list.index_map(fates, fn(pair, i) { Pair(i, pair.0, pair.1) }),
  )
}

/// A `Paired` with nothing dropped.
pub fn paired(tasks: List(TaskPairs)) -> Paired {
  Paired(tasks:, infrastructure_rows: 0, dropped_pairs: 0)
}

/// Rows on arms `"a"` and `"b"` realising a list of tasks given as
/// `(task, [(baseline, candidate)])`, indexed in order.
pub fn rows_of(tasks: List(#(String, List(#(Fate, Fate))))) -> List(Trial) {
  list.flat_map(tasks, fn(entry) {
    let #(name, fates) = entry
    list.index_map(fates, fn(pair, i) {
      [
        row(name, "a", i, outcome_of(pair.0)),
        row(name, "b", i, outcome_of(pair.1)),
      ]
    })
    |> list.flatten
  })
}

/// The plan behind `rows_of`: every task with as many indices as it has
/// fate pairs.
pub fn plan_of(
  tasks: List(#(String, List(#(Fate, Fate)))),
) -> List(#(String, Int)) {
  list.flat_map(tasks, fn(entry) {
    list.index_map(entry.1, fn(_, i) { #(entry.0, i) })
  })
}
