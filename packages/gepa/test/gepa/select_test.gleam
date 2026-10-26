//// Selection and the dispositions: the front, the draws, the screen and
//// the order of the reported front.

import gepa/prng
import gepa/select
import gepa/verdict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import qcheck

pub fn the_front_keeps_leaders_within_one_sample_and_prunes_dominated_test() {
  // K = 3, so a member within a third of the best on a task leads it.
  let members = [
    #("a", [#("t1", 1.0), #("t2", 0.0), #("t3", 0.667)]),
    #("b", [#("t1", 0.667), #("t2", 1.0), #("t3", 0.333)]),
    #("c", [#("t1", 0.333), #("t2", 0.0), #("t3", 0.0)]),
  ]
  let leaders = select.front(members, ["t1", "t2", "t3"], 3)

  // c leads nothing and is dropped; a leads t1 and t3 (b is within 1/3 on
  // t1), b leads t1 and t2.
  assert list.map(leaders, fn(leader) { #(leader.candidate, leader.tasks_led) })
    == [#("a", 2), #("b", 2)]

  // A member dominated on every task by another is pruned even if it ties
  // one of them within tolerance.
  let dominated = [
    #("a", [#("t1", 1.0), #("t2", 1.0)]),
    #("d", [#("t1", 0.9), #("t2", 0.9)]),
  ]
  assert list.map(select.front(dominated, ["t1", "t2"], 3), fn(l) {
      l.candidate
    })
    == ["a"]

  // A task missing from a member's scores counts as zero, in task order.
  let partial = [#("a", [#("t2", 1.0)])]
  let assert [only] = select.front(partial, ["t1", "t2"], 1)
  assert only.scores == [#("t1", 0.0), #("t2", 1.0)]
}

pub fn the_parent_draw_is_proportional_and_reproducible_test() {
  let leaders = [select.Leader("a", 3, []), select.Leader("b", 1, [])]
  let draws =
    list.index_map(list.repeat(Nil, 400), fn(_, i) { i + 1 })
    |> list.map(fn(step) {
      let assert Ok(#(arm, _)) =
        select.draw_parent(
          leaders,
          prng.from_string("search/" <> string.inspect(step)),
        )
      arm
    })
  let a = list.count(draws, fn(arm) { arm == "a" })

  // Three to one, within what 400 draws allow.
  assert a > 260 && a < 340

  // The same seed draws the same parent, every time.
  let assert Ok(#(first, _)) =
    select.draw_parent(leaders, prng.from_string("s/1"))
  let assert Ok(#(again, _)) =
    select.draw_parent(leaders, prng.from_string("s/1"))
  assert first == again
  assert select.draw_parent([], prng.from_string("s/1")) == Error(Nil)
}

pub fn the_minibatch_draws_without_replacement_test() {
  let tasks = ["a", "b", "c", "d", "e", "f"]
  let #(drawn, _) = select.minibatch(tasks, 4, prng.from_string("x"))

  assert list.length(drawn) == 4
  assert list.length(list.unique(drawn)) == 4
  assert list.all(drawn, list.contains(tasks, _))

  // A minibatch wider than the split is the whole split, shuffled.
  let #(all, _) = select.minibatch(tasks, 10, prng.from_string("x"))
  assert list.sort(all, string.compare) == tasks
}

pub fn slots_rotate_round_robin_from_step_one_test() {
  assert select.slot_for(1, ["s", "t"]) == Ok("s")
  assert select.slot_for(2, ["s", "t"]) == Ok("t")
  assert select.slot_for(3, ["s", "t"]) == Ok("s")
  assert select.slot_for(1, []) == Error(Nil)
}

pub fn the_screen_demands_strict_improvement_or_a_fixed_failure_test() {
  let parent = [#("t1", 1.0), #("t2", 0.0)]

  // Above the parent passes; below fails.
  assert select.screen(parent, [#("t1", 1.0), #("t2", 1.0)], ["t1", "t2"])
    == select.Passed
  assert select.screen(parent, [#("t1", 0.0), #("t2", 0.0)], ["t1", "t2"])
    == select.Failed

  // A tie that fixes a task the parent failed passes: the child solved t2,
  // which the parent scored zero on, and gave t1 back.
  assert select.screen(parent, [#("t1", 0.0), #("t2", 1.0)], ["t1", "t2"])
    == select.Passed

  // A tie without such a fix fails: the identical vector, nought of three
  // against nought of three, and a shuffle among partly solved tasks.
  assert select.screen(parent, parent, ["t1", "t2"]) == select.Failed
  let nought = [#("a", 0.0), #("b", 0.0), #("c", 0.0)]
  assert select.screen(nought, nought, ["a", "b", "c"]) == select.Failed
  let partly = [#("a", 0.5), #("b", 1.0)]
  assert select.screen(partly, [#("a", 1.0), #("b", 0.5)], ["a", "b"])
    == select.Failed

  // A task the child never scored is a zero, not a skipped task.
  assert select.screen(parent, [#("t1", 1.0)], ["t1", "t2"]) == select.Failed
  assert select.screen(parent, [#("t2", 0.0)], ["t1", "t2"]) == select.Failed
  assert select.screen([#("t1", 0.5)], [#("t1", 1.0)], ["t1", "t2"])
    == select.Passed
}

pub fn a_perfect_minibatch_is_every_task_at_one_test() {
  assert select.perfect([#("t1", 1.0), #("t2", 1.0)], ["t1", "t2"])
  assert !select.perfect([#("t1", 1.0), #("t2", 0.999)], ["t1", "t2"])

  // A task without a score is a zero, and no tasks is not perfect.
  assert !select.perfect([#("t1", 1.0)], ["t1", "t2"])
  assert !select.perfect([], [])
}

pub fn the_winner_is_the_best_passer_and_the_earliest_on_a_tie_test() {
  let tasks = ["a", "b"]
  let parent = [#("a", 0.0), #("b", 0.0)]
  let low = [#("a", 0.5), #("b", 0.0)]
  let high = [#("a", 1.0), #("b", 1.0)]

  // The highest mean among the passers wins, wherever it was minted.
  assert select.winner(parent, [#("c1", low), #("c2", high)], tasks) == Ok("c2")
  assert select.winner(parent, [#("c1", high), #("c2", low)], tasks) == Ok("c1")

  // A tie goes to the earliest minted; a failed screen is never the winner.
  assert select.winner(parent, [#("c1", low), #("c2", low)], tasks) == Ok("c1")
  assert select.winner(parent, [#("c1", parent), #("c2", low)], tasks)
    == Ok("c2")
  assert select.winner(parent, [#("c1", parent)], tasks) == Error(Nil)
  assert select.winner(parent, [], tasks) == Error(Nil)
}

pub fn dispositions_follow_the_acceptance_and_the_incumbent_test() {
  // Improved over the parent, which is the incumbent, leading more tasks.
  assert verdict.dispose(verdict.Improved, None, 5, 3) == verdict.Incumbent

  // Improved over the parent but not leading more tasks than the incumbent.
  assert verdict.dispose(verdict.Improved, None, 3, 3) == verdict.Joined

  // Improved over the parent, harmed against the incumbent.
  assert verdict.dispose(verdict.Improved, Some(verdict.Harmed), 9, 3)
    == verdict.Joined

  // Improved over the parent, inconclusive against the incumbent, leading more.
  assert verdict.dispose(verdict.Improved, Some(verdict.Inconclusive), 5, 3)
    == verdict.Incumbent

  assert verdict.dispose(verdict.Inconclusive, None, 9, 0) == verdict.ParetoOnly
  assert verdict.dispose(verdict.Harmed, None, 9, 0) == verdict.Discarded
  assert verdict.dispose(verdict.Incomplete, None, 9, 0) == verdict.Unsettled
  assert verdict.confirm(verdict.Improved) == verdict.Confirmed
  assert verdict.confirm(verdict.Incomplete) == verdict.Unconfirmed
}

pub fn every_spelling_round_trips_test() {
  list.each(
    [
      verdict.Incumbent,
      verdict.Joined,
      verdict.ParetoOnly,
      verdict.Discarded,
      verdict.Unsettled,
      verdict.Refused,
      verdict.ScreenedOut,
      verdict.Confirmed,
      verdict.Unconfirmed,
    ],
    fn(d) {
      assert verdict.parse_disposition(verdict.disposition_name(d)) == Ok(d)
    },
  )
  list.each(
    [verdict.Improved, verdict.Harmed, verdict.Inconclusive, verdict.Incomplete],
    fn(a) {
      assert verdict.parse_acceptance(verdict.acceptance_name(a)) == Ok(a)
    },
  )
  assert verdict.parse_basis("nope") |> result_is_error
}

fn result_is_error(found: Result(a, b)) -> Bool {
  case found {
    Ok(_) -> False
    Error(_) -> True
  }
}

pub fn a_pareto_only_child_ranks_below_its_parent_test() {
  let line = fn(arm, disposition, step, standing) {
    select.Ranked(candidate: arm, disposition:, step:, standing:, tasks_led: 1)
  }
  let lines = [
    line("c-pareto", verdict.ParetoOnly, 2, select.DominatesOnScores),
    line("b-joined", verdict.Joined, 1, select.Tradeoff),
    line("a-seed", verdict.Incumbent, 0, select.Tied),
  ]

  // The joined member and the seed both stand above the Pareto child,
  // whatever its point-estimate standing says.
  assert list.map(select.rank(lines, "a-seed"), fn(each) { each.candidate })
    == ["a-seed", "b-joined", "c-pareto"]
  assert list.map(select.rank(lines, "b-joined"), fn(each) { each.candidate })
    == ["b-joined", "a-seed", "c-pareto"]
}

/// A per-task score as a host reports it: a pass count over at most four
/// trials, so the means carry the thirds and quarters that a left fold
/// sums differently in a different order.
fn fraction() -> qcheck.Generator(Float) {
  use k <- qcheck.bind(qcheck.bounded_int(1, 4))
  use j <- qcheck.map(qcheck.bounded_int(0, k))
  int.to_float(j) /. int.to_float(k)
}

fn vector(tasks: List(String)) -> qcheck.Generator(List(#(String, Float))) {
  qcheck.map(
    qcheck.fixed_length_list_from(fraction(), list.length(tasks)),
    fn(scores) { list.zip(tasks, scores) },
  )
}

pub fn the_screen_and_the_winner_do_not_depend_on_the_task_order_test() {
  let tasks = ["a", "b", "c", "d", "e"]
  use #(parent, child, other, shuffle) <- qcheck.given(qcheck.tuple4(
    vector(tasks),
    vector(tasks),
    vector(tasks),
    qcheck.bounded_int(0, 1000),
  ))
  let permuted = fn(scores: List(#(String, Float))) {
    let #(front, back) = list.split(scores, shuffle % 5)
    list.append(back, list.reverse(front))
  }
  let tasks_too = list.map(permuted(parent), fn(entry) { entry.0 })

  // The same scores in any order screen the same way and crown the same
  // child.
  assert select.screen(permuted(parent), permuted(child), tasks_too)
    == select.screen(parent, child, tasks)
  assert select.winner(
      permuted(parent),
      [#("c1", permuted(child)), #("c2", permuted(other))],
      tasks_too,
    )
    == select.winner(parent, [#("c1", child), #("c2", other)], tasks)
}

pub fn an_ulp_of_summation_order_does_not_decide_a_screen_test() {
  // The two vectors hold the same thirds; a left fold sums them to floats
  // an ulp apart, and the screen must still call them a tie.
  let tasks = ["a", "b", "c"]
  let parent = [#("a", 1.0 /. 3.0), #("b", 2.0 /. 3.0), #("c", 1.0)]
  let child = [#("a", 1.0), #("b", 2.0 /. 3.0), #("c", 1.0 /. 3.0)]
  assert select.screen(parent, child, tasks) == select.Failed
  assert select.screen(child, parent, tasks) == select.Failed
  let tenths = [#("a", 0.1), #("b", 0.2), #("c", 0.3)]
  let reversed = [#("a", 0.3), #("b", 0.2), #("c", 0.1)]
  assert select.screen(tenths, reversed, tasks) == select.Failed
  assert select.screen(reversed, tenths, tasks) == select.Failed
  assert select.winner(tenths, [#("c1", reversed), #("c2", tenths)], tasks)
    == Error(Nil)
  assert select.winner(reversed, [#("c1", tenths), #("c2", reversed)], tasks)
    == Error(Nil)
  assert select.winner(
      [#("a", 0.0), #("b", 0.0), #("c", 0.0)],
      [#("c1", tenths), #("c2", reversed)],
      tasks,
    )
    == Ok("c1")

  // A task the parent never carried is a zero for the mean, but not a
  // failure the child fixed: nothing is known of it.
  assert select.screen([#("a", 1.0)], [#("a", 0.0), #("b", 1.0)], ["a", "b"])
    == select.Failed
  assert select.screen([#("a", 1.0), #("b", 0.0)], [#("a", 0.0), #("b", 1.0)], [
      "a",
      "b",
    ])
    == select.Passed
}
