//// Pairing: the step that turns a bag of trial rows into the paired
//// observations every estimator reads, and the step that decides whether
//// the bag is complete enough to be read at all.
////
//// The plan is the denominator. A plan declares `K` trials per task for
//// each arm, so for two arms it declares a set of `(task, index)` pairs,
//// and the caller passes that set in. The rows are checked against it, not
//// the other way round: a trial that never ran leaves no row, and a
//// pairing built from the rows alone would shrink `n` without a trace,
//// reporting a pass rate over whatever happened to finish. That is the
//// quietest way an instrument lies, so a missing row, a duplicate row, or a
//// row the plan never declared each stop the pairing with an error the
//// decision rule turns into `Incomplete`.
////
//// Within the plan, one more exclusion applies. A pair in which either
//// side ended in `Infrastructure` is not evidence about either arm
//// (`trial.standing`), so it is dropped from the pairs and counted in
//// `dropped_pairs`, with the raw row count in `infrastructure_rows`. The
//// pair is dropped whole, because a paired estimator needs both sides of
//// each observation, and keeping the healthy side would unpair it.
//// `excluded` is the per-row count behind `infrastructure_rows`, and
//// `compare_keys` is the `(task, index)` order every traversal here uses.
////
//// A task whose every pair was dropped contributes no `TaskPairs`; the
//// clustered estimators then see fewer clusters, which is honest, and the
//// report sees the dropped count, which says why.

import evalstat/trial.{type Fate, type Trial}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/order.{type Order}
import gleam/result
import gleam/string

/// Which arm of a comparison a value belongs to. The decision rule's
/// effect is always `candidate − baseline`.
pub type Side {
  /// The arm being compared against, `A` in the design note.
  Baseline

  /// The arm under test, `B` in the design note.
  Candidate
}

/// One paired observation: the same `(task, index)` on both arms.
pub type Pair {
  Pair(
    /// The trial index the two rows share.
    index: Int,
    /// The baseline arm's fate at that index.
    baseline: Fate,
    /// The candidate arm's fate at that index.
    candidate: Fate,
  )
}

/// A task's surviving pairs, in index order. Never empty: a task with no
/// surviving pair is absent from `Paired.tasks`.
pub type TaskPairs {
  TaskPairs(
    /// The task id, the cluster the paired estimators are clustered on.
    task: String,
    /// Its pairs, ascending by index.
    pairs: List(Pair),
  )
}

/// The paired view of a complete plan.
pub type Paired {
  Paired(
    /// Tasks with at least one surviving pair, ascending by task id.
    tasks: List(TaskPairs),
    /// Rows on either arm that ended in `Infrastructure`.
    infrastructure_rows: Int,
    /// Planned pairs dropped because at least one side was `Infrastructure`.
    dropped_pairs: Int,
  )
}

/// Why rows could not be paired. Each carries the coordinates of the first
/// offending row in a deterministic traversal, so a report can name it.
pub type PairingError {
  /// The plan declared this trial and no row for it exists on `arm`.
  MissingRow(task: String, index: Int, arm: String)

  /// Two rows claim the same `(task, index)` on `arm`.
  DuplicateRow(task: String, index: Int, arm: String)

  /// A row exists for a `(task, index)` the plan never declared.
  UnplannedRow(task: String, index: Int, arm: String)
}

/// The `(task, index)` set a plan with `trials` trials per task declares,
/// which is what `pair` takes as its denominator.
///
/// ## Examples
///
/// ```gleam
/// assert pairing.plan(["a", "b"], 2) == [#("a", 0), #("a", 1), #("b", 0), #("b", 1)]
/// ```
pub fn plan(tasks: List(String), trials: Int) -> List(#(String, Int)) {
  // `int.range` counts down when its end is below its start, so a plan of
  // no trials is clamped to an empty range rather than one of index zero.
  let stop = int.max(trials, 0)
  list.flat_map(tasks, fn(task) {
    int.range(0, stop, [], fn(acc, i) { [#(task, i), ..acc] })
    |> list.reverse
  })
}

/// Pairs the rows of two arms over the plan's `(task, index)` set.
///
/// Rows for other arms are ignored, so the caller may pass the whole
/// ledger. Rows for the two named arms must match the plan exactly: a
/// missing, duplicated or undeclared row is an error, never a smaller `n`.
///
/// ## Examples
///
/// ```gleam
/// let rows = [row("t", "a", 0, trial.Passed), row("t", "b", 0, trial.VerifierFailed)]
/// assert pairing.pair(rows, "a", "b", pairing.plan(["t"], 1))
///   == Ok(Paired([TaskPairs("t", [Pair(0, trial.Pass, trial.Fail)])], 0, 0))
/// ```
///
/// ```gleam
/// let rows = [row("t", "a", 0, trial.Passed)]
/// assert pairing.pair(rows, "a", "b", pairing.plan(["t"], 1))
///   == Error(MissingRow("t", 0, "b"))
/// ```
pub fn pair(
  rows: List(Trial),
  baseline: String,
  candidate: String,
  expected: List(#(String, Int)),
) -> Result(Paired, PairingError) {
  let ours =
    list.filter(rows, fn(row) { row.arm == baseline || row.arm == candidate })
  use table <- result.try(index_rows(ours))
  use Nil <- result.try(reject_unplanned(ours, expected))

  // The plan is walked in a sorted order so the first error named is the
  // same on every run and on every target, whatever order the rows came in.
  let sorted = list.sort(list.unique(expected), compare_keys)
  use sides <- result.try(
    list.try_map(sorted, fn(key) {
      lookup_pair(table, key, baseline, candidate)
    }),
  )
  Ok(assemble(sides))
}

/// Puts the rows in a table keyed by `(task, index, arm)`, refusing the
/// first duplicate met.
fn index_rows(
  rows: List(Trial),
) -> Result(Dict(#(String, Int, String), Trial), PairingError) {
  list.try_fold(rows, dict.new(), fn(table, row) {
    let key = #(row.task, row.index, row.arm)

    // A second row at one coordinate would silently overwrite the first,
    // and which one survived would depend on ledger order.
    case dict.has_key(table, key) {
      True -> Error(DuplicateRow(row.task, row.index, row.arm))
      False -> Ok(dict.insert(table, key, row))
    }
  })
}

/// Refuses the first row whose `(task, index)` the plan never declared.
fn reject_unplanned(
  rows: List(Trial),
  declared: List(#(String, Int)),
) -> Result(Nil, PairingError) {
  let planned =
    list.fold(declared, dict.new(), fn(set, key) { dict.insert(set, key, Nil) })
  list.try_each(rows, fn(row) {
    case dict.has_key(planned, #(row.task, row.index)) {
      True -> Ok(Nil)
      False -> Error(UnplannedRow(row.task, row.index, row.arm))
    }
  })
}

/// Both rows of one planned pair, the baseline's first. A missing side is
/// the plan's denominator asserting itself.
fn lookup_pair(
  table: Dict(#(String, Int, String), Trial),
  key: #(String, Int),
  baseline: String,
  candidate: String,
) -> Result(#(#(String, Int), Trial, Trial), PairingError) {
  let #(task, index) = key
  let fetch = fn(arm: String) {
    dict.get(table, #(task, index, arm))
    |> result.replace_error(MissingRow(task, index, arm))
  }
  use a <- result.try(fetch(baseline))
  use b <- result.try(fetch(candidate))
  Ok(#(key, a, b))
}

/// Groups the planned pairs by task, dropping the pairs with an excluded
/// side and counting what was dropped. Input is sorted by `(task, index)`,
/// so grouping by task preserves index order within each task.
fn assemble(sides: List(#(#(String, Int), Trial, Trial))) -> Paired {
  let infrastructure =
    list.fold(sides, 0, fn(count, side) {
      count + excluded(side.1) + excluded(side.2)
    })
  let kept =
    list.filter_map(sides, fn(side) {
      let #(#(task, index), a, b) = side

      // Only a pair with two counted sides is a paired observation.
      case trial.standing(a.outcome), trial.standing(b.outcome) {
        trial.Counted(fa), trial.Counted(fb) -> Ok(#(task, Pair(index, fa, fb)))
        trial.Excluded, trial.Counted(_) -> Error(Nil)
        trial.Counted(_), trial.Excluded -> Error(Nil)
        trial.Excluded, trial.Excluded -> Error(Nil)
      }
    })
  let tasks =
    kept
    |> list.chunk(fn(entry) { entry.0 })
    |> list.filter_map(fn(chunk) {
      use first <- result.try(list.first(chunk))
      Ok(TaskPairs(first.0, list.map(chunk, fn(entry) { entry.1 })))
    })
  Paired(
    tasks:,
    infrastructure_rows: infrastructure,
    dropped_pairs: list.length(sides) - list.length(kept),
  )
}

/// One if the row is excluded evidence, else zero.
fn excluded(row: Trial) -> Int {
  case trial.standing(row.outcome) {
    trial.Excluded -> 1
    trial.Counted(_) -> 0
  }
}

/// Task id first, then index.
fn compare_keys(left: #(String, Int), right: #(String, Int)) -> Order {
  string.compare(left.0, right.0)
  |> order.break_tie(int.compare(left.1, right.1))
}

/// The number of surviving pairs across every task.
///
/// ## Examples
///
/// ```gleam
/// assert pairing.pair_count(Paired([], 0, 0)) == 0
/// ```
pub fn pair_count(paired: Paired) -> Int {
  list.fold(paired.tasks, 0, fn(count, task) { count + list.length(task.pairs) })
}

/// A pairing error as the sentence `Incomplete` carries.
///
/// ## Examples
///
/// ```gleam
/// assert pairing.describe(MissingRow("t", 2, "b"))
///   == "plan row (t, 2) has no trial on arm b"
/// ```
pub fn describe(error: PairingError) -> String {
  case error {
    MissingRow(task, index, arm) ->
      "plan row ("
      <> task
      <> ", "
      <> int.to_string(index)
      <> ") has no trial on arm "
      <> arm
    DuplicateRow(task, index, arm) ->
      "plan row ("
      <> task
      <> ", "
      <> int.to_string(index)
      <> ") has two trials on arm "
      <> arm
    UnplannedRow(task, index, arm) ->
      "trial ("
      <> task
      <> ", "
      <> int.to_string(index)
      <> ") on arm "
      <> arm
      <> " is not in the plan"
  }
}

/// The fate of one side of a pair.
///
/// ## Examples
///
/// ```gleam
/// assert pairing.side(Pair(0, trial.Pass, trial.Fail), pairing.Candidate) == trial.Fail
/// ```
pub fn side(pair: Pair, side: Side) -> Fate {
  case side {
    Baseline -> pair.baseline
    Candidate -> pair.candidate
  }
}
