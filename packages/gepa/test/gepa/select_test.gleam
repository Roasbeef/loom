//// Selection and the dispositions: the front, the draws, the screen and
//// the order of the reported front.

import gepa/prng
import gepa/select
import gepa/verdict
import gleam/list
import gleam/option.{None, Some}
import gleam/string

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

pub fn the_screen_passes_a_child_no_worse_than_its_parent_test() {
  let parent = [#("t1", 1.0), #("t2", 0.0)]

  assert select.screen(parent, [#("t1", 1.0), #("t2", 1.0)], ["t1", "t2"])
    == select.Passed
  assert select.screen(parent, [#("t1", 0.0), #("t2", 1.0)], ["t1", "t2"])
    == select.Passed
  assert select.screen(parent, [#("t1", 0.0), #("t2", 0.0)], ["t1", "t2"])
    == select.Failed

  // A task the child never scored is a zero, not a skipped task.
  assert select.screen(parent, [#("t1", 1.0)], ["t1", "t2"]) == select.Passed
  assert select.screen(parent, [#("t2", 0.0)], ["t1", "t2"]) == select.Failed
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
