//// The search's draws and filters: the Pareto front over the validate
//// tasks, the parent drawn from it, the minibatch, the slot, the spend
//// filter, and the order the front is reported in.
////
//// Three decisions are the search's own and are stated here once.
////
//// - **Selection** follows GEPA's Algorithm 2 over the validate split: for
////   each task the leading set is every pool member whose per-task score
////   is within one sample's worth (`1 / k`) of the best, the union is
////   pruned by Pareto dominance over the per-task vectors, and the parent
////   is drawn in proportion to the tasks it leads from a generator seeded
////   by the search id and the step number, so a resumed search draws the
////   same parent.
//// - **The minibatch is a spend filter, not a decision rule.** A child
////   goes on to the validate split only when its mean score over the
////   minibatch tasks is strictly above the parent's, or ties it while
////   solving a task the parent scored zero on. With three or four tasks no
////   test can reach its level, so nothing is claimed at that size; the
////   screen only decides whether to pay for the stage that can, and a
////   child that merely matches its parent (nought of three against nought
////   of three is the common case) has shown nothing worth paying for. When
////   a step minted several children, `winner` picks the one passer that
////   validate is paid for: the highest minibatch mean, the earliest minted
////   on a tie.
//// - **The front is reported incumbent first**, then the members that
////   improved over their parent, then the Pareto members by minting step,
////   so a Pareto-only child never stands above its parent whatever its
////   point-estimate standing says.
////
//// Scores are per-task floats in `[0, 1]`, higher better, already
//// aggregated by the host over however many trials it ran; a task with no
//// score counts as zero, because the design owes every task a measurement
//// and a candidate that failed to produce one must not lead that task by
//// omission.

import gepa/prng.{type Prng}
import gepa/verdict.{type Disposition}
import gleam/float
import gleam/int
import gleam/list
import gleam/order
import gleam/result
import gleam/string

/// A pool member on the front: its per-task scores and how many tasks it
/// leads.
pub type Leader {
  Leader(
    /// The candidate id.
    candidate: String,
    /// The validate tasks on which it is within one sample of the best.
    tasks_led: Int,
    /// Its score per task, in the task order given to `front`, with a
    /// missing task scored zero.
    scores: List(#(String, Float)),
  )
}

/// Whether a child passed the spend filter.
pub type Screen {
  /// Its minibatch mean is above the parent's, or ties it while fixing a
  /// task the parent failed: pay for validate.
  Passed

  /// Not above the parent, and no failed task fixed: the step ends here.
  Failed
}

/// A member's standing against the seed, as the host's dominance rule
/// read it, for the front's order. The variants are listed best first.
pub type Standing {
  /// Shown better on the outcome the host decides on.
  DominatesOnOutcome

  /// Not shown worse on outcome, and better on every secondary score.
  DominatesOnScores

  /// Equal on every shared score.
  Tied

  /// Better on some scores and worse on others.
  Tradeoff

  /// Nothing to compare.
  Undecided

  /// Not shown worse on outcome, but worse on the secondary scores.
  DominatedOnScores

  /// Shown worse on the outcome.
  DominatedOnOutcome
}

/// One line of the reported front.
pub type Ranked {
  Ranked(
    /// The candidate id.
    candidate: String,
    /// How it joined the pool.
    disposition: Disposition,
    /// The step that minted it; the seed's is zero.
    step: Int,
    /// Its standing against the seed.
    standing: Standing,
    /// The tasks it leads.
    tasks_led: Int,
  )
}

/// The score of one task in a score vector, zero when absent.
///
/// ## Examples
///
/// ```gleam
/// assert select.score_for([#("t1", 0.5)], "t2") == 0.0
/// ```
///
pub fn score_for(scores: List(#(String, Float)), task: String) -> Float {
  result.unwrap(list.key_find(scores, task), 0.0)
}

/// The arithmetic mean of a list, zero of nothing.
///
/// ## Examples
///
/// ```gleam
/// assert select.mean([1.0, 0.0]) == 0.5
/// assert select.mean([]) == 0.0
/// ```
///
pub fn mean(values: List(Float)) -> Float {
  case values {
    [] -> 0.0
    [_, ..] ->
      list.fold(values, 0.0, float.add) /. int.to_float(list.length(values))
  }
}

/// GEPA's Algorithm 2 over the pool: the per-task leading sets, their union
/// pruned by Pareto dominance, and each survivor's count of tasks led. The
/// leading set of a task is every member within `1 / k` of its best score,
/// because one lucky sample out of `k` must not make a member the sole
/// leader of a task. Survivors come back in pool order, their scores
/// normalised to `tasks`.
///
/// ## Examples
///
/// ```gleam
/// // select.front([#("a", scores_a), #("b", scores_b)], ["t1", "t2"], 3)
/// // -> [Leader("a", 2, ..), Leader("b", 1, ..)]
/// ```
///
pub fn front(
  members: List(#(String, List(#(String, Float)))),
  tasks: List(String),
  k: Int,
) -> List(Leader) {
  let tolerance = 1.0 /. int.to_float(int.max(k, 1))
  let normalised =
    list.map(members, fn(member) {
      #(
        member.0,
        list.map(tasks, fn(task) { #(task, score_for(member.1, task)) }),
      )
    })

  // The best score per task, over every member, is the bar for leadership.
  let bests =
    list.map(tasks, fn(task) {
      #(
        task,
        list.fold(normalised, 0.0, fn(best, member) {
          float.max(best, score_for(member.1, task))
        }),
      )
    })
  let leading =
    list.filter(normalised, fn(member) { leads(member.1, bests, tolerance) > 0 })

  // A leader dominated on every task by another leader is pruned, even when
  // it ties one of them within tolerance.
  let survivors =
    list.filter(leading, fn(member) {
      !list.any(leading, fn(other) {
        other.0 != member.0 && dominated(member.1, other.1)
      })
    })

  list.map(survivors, fn(member) {
    Leader(
      candidate: member.0,
      tasks_led: leads(member.1, bests, tolerance),
      scores: member.1,
    )
  })
}

/// Whether `scores` is Pareto-dominated by `other`: no better on any task
/// and strictly worse on at least one. Both vectors carry the same tasks.
fn dominated(
  scores: List(#(String, Float)),
  other: List(#(String, Float)),
) -> Bool {
  let worse_somewhere =
    list.any(scores, fn(entry) { entry.1 <. score_for(other, entry.0) })
  let better_nowhere =
    list.all(scores, fn(entry) { entry.1 <=. score_for(other, entry.0) })

  worse_somewhere && better_nowhere
}

/// How many tasks a member leads: those on which it is within `tolerance`
/// of the best.
fn leads(
  scores: List(#(String, Float)),
  bests: List(#(String, Float)),
  tolerance: Float,
) -> Int {
  list.count(bests, fn(best) {
    score_for(scores, best.0) +. tolerance >=. best.1
  })
}

/// Draws the parent in proportion to tasks led, from the step's generator.
/// An empty front cannot happen for a non-empty pool (the seed leads at
/// least the tasks nobody beats it on), but the type says so rather than
/// the caller trusting it.
///
/// ## Examples
///
/// ```gleam
/// // select.draw_parent(leaders, prng.from_string("search/3")) -> Ok(#("a", prng))
/// ```
///
pub fn draw_parent(
  leaders: List(Leader),
  generator: Prng,
) -> Result(#(String, Prng), Nil) {
  let total = list.fold(leaders, 0, fn(sum, leader) { sum + leader.tasks_led })

  // A front that leads nothing has nothing to draw from.
  use Nil <- result.try(case total > 0 {
    True -> Ok(Nil)
    False -> Error(Nil)
  })

  let #(point, generator) = prng.below(generator, total)

  // Walk the leaders, each owning `tasks_led` points of the range.
  let chosen =
    list.fold_until(leaders, #(point, Error(Nil)), fn(held, leader) {
      case held.0 < leader.tasks_led {
        True -> list.Stop(#(held.0, Ok(leader.candidate)))
        False -> list.Continue(#(held.0 - leader.tasks_led, Error(Nil)))
      }
    })

  result.map(chosen.1, fn(candidate) { #(candidate, generator) })
}

/// Draws `size` tasks without replacement, in draw order. Fewer tasks than
/// `size` means all of them, shuffled.
///
/// ## Examples
///
/// ```gleam
/// // select.minibatch(["a", "b", "c"], 2, generator) -> #(["c", "a"], generator)
/// ```
///
pub fn minibatch(
  tasks: List(String),
  size: Int,
  generator: Prng,
) -> #(List(String), Prng) {
  draw_without_replacement(
    tasks,
    int.min(size, list.length(tasks)),
    generator,
    [],
  )
}

/// Takes `wanted` elements from `remaining` one index draw at a time, so
/// every element is drawn at most once and the order is the draw order.
fn draw_without_replacement(
  remaining: List(String),
  wanted: Int,
  generator: Prng,
  drawn: List(String),
) -> #(List(String), Prng) {
  // Each draw takes one element by index from what is left; the walk ends
  // when enough are drawn or none remain.
  case wanted <= 0 || remaining == [] {
    True -> #(list.reverse(drawn), generator)
    False -> {
      let #(index, generator) = prng.below(generator, list.length(remaining))
      let before = list.take(remaining, index)
      let after = list.drop(remaining, index)

      // The drawn element is the head of the tail; an empty tail cannot
      // happen for an index below the length, but the type says so.
      case after {
        [picked, ..rest] ->
          draw_without_replacement(
            list.append(before, rest),
            wanted - 1,
            generator,
            [picked, ..drawn],
          )
        [] -> #(list.reverse(drawn), generator)
      }
    }
  }
}

/// The slot a step rewrites: round robin over the mutable set, step 1
/// taking the first.
///
/// ## Examples
///
/// ```gleam
/// assert select.slot_for(3, ["a", "b"]) == Ok("a")
/// assert select.slot_for(1, []) == Error(Nil)
/// ```
///
pub fn slot_for(step: Int, slots: List(String)) -> Result(String, Nil) {
  // Round robin needs at least one slot; step 1 takes the first.
  case slots {
    [] -> Error(Nil)
    [_, ..] -> {
      let index = { int.max(step, 1) - 1 } % list.length(slots)

      list.drop(slots, index) |> list.first
    }
  }
}

/// The spend filter: the child goes on to validate when the mean over
/// `tasks` of its per-task score is strictly above the parent's, or equal
/// to it while the child scores above zero on a task the parent scored
/// zero on. Both vectors are read by task, so the comparison is over the
/// same tasks whatever order the scores arrived in.
///
/// The tie rule is the one exception to strictness, and it is narrow by
/// design. A parent's zero on a task is a task every trial failed; a child
/// that scores on it while giving the same amount back elsewhere is a
/// different point on the minibatch, and the Pareto front values exactly
/// that, leadership on a task, which only validate can weigh. A tie
/// without such a fix, the identical vector or a shuffle among partly
/// solved tasks, has shown nothing the parent had not, and nought out of
/// three against nought out of three must not buy a validate run.
///
/// ## Examples
///
/// ```gleam
/// assert select.screen([#("t", 0.5)], [#("t", 1.0)], ["t"]) == select.Passed
/// assert select.screen([#("t", 0.5)], [#("t", 0.5)], ["t"]) == select.Failed
/// assert select.screen([#("a", 0.0), #("b", 1.0)], [#("a", 1.0), #("b", 0.0)], ["a", "b"])
///   == select.Passed
/// ```
///
pub fn screen(
  parent: List(#(String, Float)),
  child: List(#(String, Float)),
  tasks: List(String),
) -> Screen {
  let parent_mean = list.map(tasks, score_for(parent, _)) |> mean
  let child_mean = list.map(tasks, score_for(child, _)) |> mean
  let fixes_a_failure =
    list.any(tasks, fn(task) {
      score_for(parent, task) == 0.0 && score_for(child, task) >. 0.0
    })

  // Strictly better pays; a tie pays only when it bought a task the
  // parent could not do at all.
  case child_mean >. parent_mean, child_mean == parent_mean && fixes_a_failure {
    True, _ | False, True -> Passed
    False, False -> Failed
  }
}

/// Whether a candidate scored one on every task of a minibatch: the
/// ceiling, above which no reflection can show anything. An empty
/// minibatch is not perfect; nothing was measured.
///
/// ## Examples
///
/// ```gleam
/// assert select.perfect([#("t1", 1.0), #("t2", 1.0)], ["t1", "t2"])
/// assert !select.perfect([#("t1", 1.0)], ["t1", "t2"])
/// assert !select.perfect([], [])
/// ```
///
pub fn perfect(scores: List(#(String, Float)), tasks: List(String)) -> Bool {
  tasks != [] && list.all(tasks, fn(task) { score_for(scores, task) == 1.0 })
}

/// The one child of a step that validate is paid for: among the children
/// that pass the screen against the parent, the highest minibatch mean,
/// and on a tie the earliest in `children`, which is minting order. The
/// earliest wins a tie because it is the order the log already fixes and
/// the proposal the reflector gave before it was shown its siblings; an
/// id comparison would make the choice depend on the host's hash.
/// `Error(Nil)` when no child passes.
///
/// ## Examples
///
/// ```gleam
/// // select.winner(parent, [#("c1", scores_1), #("c2", scores_2)], tasks) == Ok("c2")
/// assert select.winner([#("t", 1.0)], [#("c", [#("t", 0.0)])], ["t"]) == Error(Nil)
/// ```
///
pub fn winner(
  parent: List(#(String, Float)),
  children: List(#(String, List(#(String, Float)))),
  tasks: List(String),
) -> Result(String, Nil) {
  children
  |> list.filter(fn(child) { screen(parent, child.1, tasks) == Passed })
  |> list.fold(Error(Nil), fn(best, child) {
    let child_mean = list.map(tasks, score_for(child.1, _)) |> mean

    // Only a strictly higher mean displaces the earlier passer.
    case best {
      Ok(#(_, best_mean)) if best_mean >=. child_mean -> best
      Ok(_) | Error(Nil) -> Ok(#(child.0, child_mean))
    }
  })
  |> result.map(fn(found) { found.0 })
}

/// Orders pool members for the front: the incumbent first, then the
/// members that improved over their parent, then the Pareto-only members.
/// Within the improved tier the order is standing against the seed, then
/// tasks led; within the Pareto tier it is the minting step, so a
/// Pareto-only child never stands above its parent; the id makes every
/// order total.
///
/// ## Examples
///
/// ```gleam
/// // select.rank(lines, incumbent) -> [incumbent line, ..]
/// ```
///
pub fn rank(lines: List(Ranked), incumbent: String) -> List(Ranked) {
  list.sort(lines, fn(left, right) {
    // The incumbent outranks everything; among the rest the disposition
    // tier, then the tier's own order, then the id.
    case left.candidate == incumbent, right.candidate == incumbent {
      True, False -> order.Lt
      False, True -> order.Gt
      True, True | False, False ->
        int.compare(tier(left.disposition), tier(right.disposition))
        |> order.lazy_break_tie(fn() { within_tier(left, right) })
        |> order.lazy_break_tie(fn() {
          string.compare(left.candidate, right.candidate)
        })
    }
  })
}

/// The tier a disposition puts a member in: improved first, Pareto last.
fn tier(disposition: Disposition) -> Int {
  case disposition {
    verdict.Incumbent
    | verdict.Joined
    | verdict.Confirmed
    | verdict.Unconfirmed -> 0
    verdict.ParetoOnly -> 1
    verdict.Discarded
    | verdict.Unsettled
    | verdict.Refused
    | verdict.ScreenedOut -> 2
  }
}

/// The order inside one tier: a Pareto member by its step, an improved one
/// by standing against the seed and then tasks led.
fn within_tier(left: Ranked, right: Ranked) -> order.Order {
  case left.disposition {
    verdict.ParetoOnly -> int.compare(left.step, right.step)
    verdict.Incumbent
    | verdict.Joined
    | verdict.Confirmed
    | verdict.Unconfirmed
    | verdict.Discarded
    | verdict.Unsettled
    | verdict.Refused
    | verdict.ScreenedOut ->
      int.compare(standing_rank(left.standing), standing_rank(right.standing))
      |> order.lazy_break_tie(fn() {
        int.compare(right.tasks_led, left.tasks_led)
      })
  }
}

/// The rank of a standing, best first.
fn standing_rank(found: Standing) -> Int {
  case found {
    DominatesOnOutcome -> 0
    DominatesOnScores -> 1
    Tied -> 2
    Tradeoff -> 3
    Undecided -> 4
    DominatedOnScores -> 5
    DominatedOnOutcome -> 6
  }
}
