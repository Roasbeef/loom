//// The nested bootstrap: a percentile interval for the mean difference
//// that makes no normality assumption and keeps the pairing.
////
//// Each resample redraws the data the way the plan drew it. Tasks are
//// drawn with replacement, because the task is the sampled unit; within
//// each drawn task, pair positions are drawn with replacement, and the
//// same positions are taken from both arms at once. That last clause is
//// the whole reason this module exists beside the clustered normal
//// interval: drawing the two arms' trials independently would discard the
//// within-pair correlation and widen the interval, which
//// `bootstrap_keeps_pairing_test` turns into a check that perfectly
//// correlated arms give an interval of zero width.
////
//// The generator is seeded from the plan id (`prng.from_string`), so the
//// interval a report prints is a function of the ledger and the plan and
//// nothing else; a second run over the same inputs prints the same digits
//// on either target.

import evalstat/paired
import evalstat/pairing.{type Pair, type Paired, type TaskPairs}
import evalstat/prng.{type Prng}
import evalstat/trial
import gleam/bool
import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/result

/// The number of resamples the design fixes.
pub const default_resamples = 2000

/// One task prepared for resampling: its pairs indexed by position so a
/// drawn position is a dictionary lookup rather than a list walk.
type Indexed {
  Indexed(size: Int, pairs: Dict(Int, Pair))
}

/// The percentile 2.5 / 97.5 interval of the resampled mean difference,
/// over `resamples` draws seeded from `seed`. `Error` when there is no
/// task to resample or fewer than one resample is asked for.
///
/// ## Examples
///
/// ```gleam
/// assert bootstrap.interval(Paired([], 0, 0), 2000, "plan") == Error(Nil)
/// ```
///
/// ```gleam
/// // Every pair agrees inside its task, so every resample has the same mean.
/// let pairs = [Pair(0, trial.Fail, trial.Pass), Pair(1, trial.Fail, trial.Pass)]
/// let paired = Paired([TaskPairs("a", pairs), TaskPairs("b", pairs)], 0, 0)
/// assert bootstrap.interval(paired, 50, "plan") == Ok(#(1.0, 1.0))
/// ```
pub fn interval(
  paired: Paired,
  resamples: Int,
  seed: String,
) -> Result(#(Float, Float), Nil) {
  let tasks = list.map(paired.tasks, index_task)
  let count = list.length(tasks)
  use <- bool.guard(when: count == 0 || resamples < 1, return: Error(Nil))
  let by_position =
    list.index_fold(tasks, dict.new(), fn(table, task, i) {
      dict.insert(table, i, task)
    })

  // Each resample threads the generator forward, so resample `i` depends
  // on `i − 1` only through the generator state and the draws are one
  // reproducible stream from the seed.
  let #(_, means) =
    list.repeat(Nil, resamples)
    |> list.map_fold(prng.from_string(seed), fn(state, _) {
      let #(mean, state) = resample_mean(by_position, count, state)
      #(state, mean)
    })
  let sorted = list.sort(means, float.compare)
  use low <- result.try(percentile(sorted, resamples, 0.025))
  use high <- result.try(percentile(sorted, resamples, 0.975))
  Ok(#(low, high))
}

/// One resample's mean difference: `count` tasks drawn with replacement,
/// each resampled within itself.
fn resample_mean(
  tasks: Dict(Int, Indexed),
  count: Int,
  state: Prng,
) -> #(Float, Prng) {
  let #(state, differences) =
    list.repeat(Nil, count)
    |> list.map_fold(state, fn(state, _) {
      let #(which, state) = prng.below(state, count)

      // The position was drawn below `count`, so the lookup cannot miss;
      // an empty task in its place contributes a zero difference rather
      // than a crash, which keeps the function total.
      case dict.get(tasks, which) {
        Ok(task) -> {
          let #(d, state) = resample_task(task, state)
          #(state, d)
        }
        Error(Nil) -> #(state, 0.0)
      }
    })
  #(paired.mean(differences), state)
}

/// The mean per-pair difference of one task after drawing `size` positions
/// with replacement. Each drawn position yields both arms' fates, which is
/// where the pairing is kept.
fn resample_task(task: Indexed, state: Prng) -> #(Float, Prng) {
  let #(sum, state) =
    list.repeat(Nil, task.size)
    |> list.fold(#(0.0, state), fn(acc, _) {
      let #(sum, state) = acc
      let #(position, state) = prng.below(state, task.size)
      let d =
        dict.get(task.pairs, position)
        |> result.map(fn(pair) {
          trial.indicator(pair.candidate) -. trial.indicator(pair.baseline)
        })
        |> result.unwrap(0.0)
      #(sum +. d, state)
    })
  #(sum /. int.to_float(task.size), state)
}

/// Positions a task's pairs for lookup by drawn index.
fn index_task(task: TaskPairs) -> Indexed {
  let pairs =
    list.index_fold(task.pairs, dict.new(), fn(table, pair, i) {
      dict.insert(table, i, pair)
    })
  Indexed(size: list.length(task.pairs), pairs:)
}

/// The value at quantile `q` of an ascending list of `n`, by the nearest
/// rank below `q · (n − 1)`.
fn percentile(sorted: List(Float), n: Int, q: Float) -> Result(Float, Nil) {
  let rank = float.truncate(q *. int.to_float(n - 1))
  list.drop(sorted, rank) |> list.first
}
