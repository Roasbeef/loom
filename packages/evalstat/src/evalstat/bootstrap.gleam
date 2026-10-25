//// The cluster bootstrap: a percentile interval for the mean difference
//// that makes no normality assumption and resamples the unit the plan
//// sampled.
////
//// Each resample draws `T` tasks with replacement and takes the mean of
//// their observed per-task differences `d_t`. The task is the cluster, and
//// each drawn task carries its whole observed difference, so the
//// within-task noise is already inside `d_t` once; redrawing trials inside
//// each drawn task as well would count that noise a second time and widen
//// the interval (Davison & Hinkley; Ren et al. 2010), which is why the
//// nested form the design note sketched is not what this module does. The
//// pairing is kept because `d_t` is a paired quantity: the same task's two
//// rates, never one arm's task against another arm's.
////
//// The generator is seeded from the plan id (`prng.from_string`) and tasks
//// are drawn by position in the package's one task order
//// (`pairing.compare_task_ids`), so the interval a report prints is a
//// function of the ledger and the plan and nothing else; a second run over
//// the same inputs prints the same digits on either target. The interval's
//// ends are read from the sorted resample means at the ranks
//// `percentile_ranks` fixes, symmetric about the two ends, by `at`.

import evalstat/paired
import evalstat/pairing.{type Paired}
import evalstat/prng.{type Prng}
import gleam/bool
import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/result

/// The number of resamples the design fixes.
pub const default_resamples = 2000

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
/// // Every task has the same difference, so every resample has the same mean.
/// let pairs = [Pair(0, trial.Fail, trial.Pass), Pair(1, trial.Fail, trial.Pass)]
/// let paired = Paired([TaskPairs("a", pairs), TaskPairs("b", pairs)], 0, 0)
/// assert bootstrap.interval(paired, 50, "plan") == Ok(#(1.0, 1.0))
/// ```
pub fn interval(
  paired: Paired,
  resamples: Int,
  seed: String,
) -> Result(#(Float, Float), Nil) {
  let differences = paired.differences(paired)
  let count = list.length(differences)
  use <- bool.guard(when: count == 0 || resamples < 1, return: Error(Nil))
  let by_position =
    list.index_fold(differences, dict.new(), fn(table, d, i) {
      dict.insert(table, i, d)
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
  let #(low_rank, high_rank) = percentile_ranks(resamples)
  use low <- result.try(at(sorted, low_rank))
  use high <- result.try(at(sorted, high_rank))
  Ok(#(low, high))
}

/// One resample's mean difference: `count` tasks drawn with replacement,
/// each contributing its observed `d_t`.
fn resample_mean(
  differences: Dict(Int, Float),
  count: Int,
  state: Prng,
) -> #(Float, Prng) {
  let #(state, drawn) =
    list.repeat(Nil, count)
    |> list.map_fold(state, fn(state, _) {
      let #(which, state) = prng.below(state, count)

      // The position was drawn below `count`, so the lookup cannot miss; a
      // zero in its place keeps the function total rather than crashing.
      #(state, result.unwrap(dict.get(differences, which), 0.0))
    })
  #(paired.mean(drawn), state)
}

/// The zero-based ranks of the 2.5th and 97.5th percentiles among `n`
/// sorted resamples, symmetric about the ends: the lower rank is the
/// `⌈0.025 · n⌉`-th smallest and the upper is the same count from the top,
/// so for 2000 resamples they are the 50th smallest and the 50th largest.
fn percentile_ranks(n: Int) -> #(Int, Int) {
  let from_end = float.round(float.ceiling(0.025 *. int.to_float(n)))
  let low = int.clamp(from_end - 1, 0, n - 1)
  #(low, n - 1 - low)
}

/// The element at a zero-based rank of an ascending list.
fn at(sorted: List(Float), rank: Int) -> Result(Float, Nil) {
  list.drop(sorted, rank) |> list.first
}
