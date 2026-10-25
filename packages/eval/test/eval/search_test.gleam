import eval/arm.{Any, Target, TaskPrefix}
import eval/search.{
  type Event, Candidate, Judgement, Reflection, Refusal, Run, Stop,
}
import eval/split
import evalstat/dominance
import evalstat/prng
import evalstat/trial as stat
import evalstat/verdict
import gleam/list
import gleam/option.{None, Some}
import gleam/string

const seed = "0000000000000000000000000000000000000000000000000000000000000001"

const child = "0000000000000000000000000000000000000000000000000000000000000002"

const grandchild =
  "0000000000000000000000000000000000000000000000000000000000000003"

const plan_a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

const plan_b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

const plan_c = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

const plan_d = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"

const plan_e = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"

fn improved() -> verdict.Verdict {
  verdict.Improved(effect: 0.5, ci: #(0.2, 0.8), p: 0.01, mde: 0.3)
}

// A complete one-step search: seed validated, parent minibatch, reflection,
// child, child minibatch, validate, verdict, confirm run, confirm verdict, stop.
fn one_step() -> List(Event) {
  [
    Candidate(seed, None, 0, search.Seed, None),
    Run(seed, split.Validate, plan_a, 0, search.ValidateRun, 0.0),
    Run(seed, split.Tune, plan_b, 1, search.ParentMinibatch, 0.0),
    Reflection(
      1,
      "fixture",
      "fixture",
      "anthropic-messages",
      0.001,
      "in",
      "out",
    ),
    Candidate(child, Some(seed), 1, search.Reflected, Some("task_prefix:x")),
    Run(child, split.Tune, plan_c, 1, search.ChildMinibatch, 0.0),
    Run(child, split.Validate, plan_d, 1, search.ValidateRun, 0.0),
    Judgement(child, seed, split.Validate, improved(), search.Incumbent),
    Run(child, split.Validate, plan_e, 1, search.Confirm, 0.0),
    Judgement(child, seed, split.Validate, improved(), search.Confirmed),
    Stop(search.Steps),
  ]
}

pub fn every_row_kind_round_trips_through_the_codec_test() {
  let rows =
    list.append(one_step(), [
      Refusal(2, "", "the reflector answered nothing"),
      Refusal(2, grandchild, "per-role profiles need protocol-change 101"),
      Judgement(
        child,
        seed,
        split.Tune,
        verdict.Incomplete("screened out on the tune minibatch"),
        search.ScreenedOut,
      ),
      Judgement(
        child,
        seed,
        split.Validate,
        verdict.Underpowered(mde: 0.4, needed_tasks: 30, reason: "few tasks"),
        search.ParetoOnly,
      ),
      Judgement(
        child,
        seed,
        split.Validate,
        verdict.Harmed(effect: -0.5, ci: #(-0.8, -0.2), p: 0.01, mde: 0.3),
        search.Harmed,
      ),
    ])

  list.each(rows, fn(row) {
    assert search.decode_line(search.encode_line(row)) == Ok(row)
  })

  // A whole log parses back to its rows, and a holdout split is refused.
  let text = string.join(list.map(rows, search.encode_line), "\n") <> "\n"
  assert search.parse(text) == Ok(rows)
  let assert Error(reason) =
    search.decode_line(
      "{\"v\":1,\"kind\":\"run\",\"arm\":\""
      <> seed
      <> "\",\"split\":\"holdout\",\"plan\":\""
      <> plan_a
      <> "\",\"step\":0,\"role\":\"validate\"}",
    )
  assert string.contains(reason, "holdout")
}

pub fn a_complete_log_replays_to_a_stopped_search_test() {
  let assert Ok(state) = search.replay(one_step())

  assert state.pool == [seed, child]
  assert state.incumbent == child
  assert state.step == 1
  assert state.open == None
  assert state.stopped == Some(search.Steps)
  assert state.reflections == 1
  assert search.children(state) == 1
  let assert Some(search.Confirmation(best:, plan:, verdict: Some(_))) =
    state.confirmation
  assert best == child && plan == plan_e
}

pub fn a_deleted_run_row_refuses_replay_test() {
  // Each run row of the step, deleted alone, is caught by the row that
  // presupposes it, with the message `eval report` uses for a plan row.
  list.each([plan_a, plan_b, plan_c, plan_d], fn(deleted) {
    let rows =
      list.filter(one_step(), fn(row) {
        case row {
          Run(plan:, ..) -> plan != deleted
          _ -> True
        }
      })
    let assert Error(reason) = search.replay(rows)
    assert string.contains(reason, "search row missing")
  })

  // The seed's validate run in particular is named.
  let assert Error(reason) =
    search.replay(
      list.filter(one_step(), fn(row) {
        row != Run(seed, split.Validate, plan_a, 0, search.ValidateRun, 0.0)
      }),
    )
  assert string.contains(reason, "search row missing: the seed's validate run")
}

pub fn a_log_cut_inside_a_step_replays_to_an_open_step_test() {
  let prefix = list.take(one_step(), 6)
  let assert Ok(state) = search.replay(prefix)

  let assert Some(progress) = state.open
  assert progress.step == 1
  assert progress.parent == seed
  assert progress.child == Some(child)
  assert progress.child_minibatch == Some(plan_c)
  assert progress.validate == None
  assert state.pool == [seed]
}

pub fn a_lax_row_is_refused_test() {
  let prefix = list.take(one_step(), 7)
  let flat =
    verdict.Indistinguishable(effect: 0.0, ci: #(-0.1, 0.1), p: 1.0, mde: 0.05)

  // A disposition that does not follow from its verdict.
  let assert Error(contradiction) =
    search.replay(
      list.append(prefix, [
        Judgement(child, seed, split.Validate, improved(), search.ParetoOnly),
      ]),
    )
  assert string.contains(contradiction, "does not follow from its verdict")

  // A settlement on the tune split, and a screen on the validate split.
  let assert Error(wrong_split) =
    search.replay(
      list.append(prefix, [
        Judgement(child, seed, split.Tune, flat, search.ParetoOnly),
      ]),
    )
  assert string.contains(wrong_split, "does not follow")

  // Two steps: the second child's parent is the first child, which is not
  // the incumbent, so an `incumbent` settlement needs the incumbent row,
  // and may carry it only once.
  let two_steps =
    list.flatten([
      list.take(one_step(), 8),
      [
        Run(seed, split.Tune, plan_b, 2, search.ParentMinibatch, 0.0),
        Reflection(
          2,
          "fixture",
          "fixture",
          "anthropic-messages",
          0.001,
          "i",
          "o",
        ),
        Candidate(grandchild, Some(seed), 2, search.Reflected, Some("s")),
        Run(grandchild, split.Tune, plan_c, 2, search.ChildMinibatch, 0.0),
        Run(grandchild, split.Validate, plan_e, 2, search.ValidateRun, 0.0),
      ],
    ])
  let incumbent_row =
    Judgement(grandchild, child, split.Validate, flat, search.Unsettled)
  let settles =
    Judgement(grandchild, seed, split.Validate, improved(), search.Incumbent)
  let assert Error(missing) = search.replay(list.append(two_steps, [settles]))
  assert string.contains(
    missing,
    "search row missing: the verdict against the incumbent",
  )
  let assert Error(twice) =
    search.replay(list.append(two_steps, [incumbent_row, incumbent_row]))
  assert string.contains(twice, "a second verdict against the incumbent")
  let assert Ok(state) =
    search.replay(list.append(two_steps, [incumbent_row, settles]))
  assert state.incumbent == grandchild
}

pub fn a_pareto_only_child_ranks_below_its_parent_test() {
  let line = fn(arm, disposition, step, found) {
    search.Ranked(arm:, disposition:, step:, dominance: found, tasks_led: 1)
  }
  let lines = [
    line(
      "c-pareto",
      search.ParetoOnly,
      2,
      dominance.Dominates(dominance.Scores),
    ),
    line("b-joined", search.Joined, 1, dominance.Tradeoff(["x"], ["y"])),
    line("a-seed", search.Incumbent, 0, dominance.Tie),
  ]

  // The joined member and the seed both stand above the Pareto child,
  // whatever its point-estimate dominance says.
  assert list.map(search.rank(lines, "a-seed"), fn(each) { each.arm })
    == ["a-seed", "b-joined", "c-pareto"]
  assert list.map(search.rank(lines, "b-joined"), fn(each) { each.arm })
    == ["b-joined", "a-seed", "c-pareto"]
}

pub fn a_row_after_the_stop_is_refused_test() {
  let assert Error(reason) =
    search.replay(list.append(one_step(), [Stop(search.Steps)]))
  assert string.contains(reason, "follows the stop row")
}

pub fn an_empty_log_or_a_wrong_first_row_is_refused_test() {
  assert search.replay([]) == Error("search row missing: the seed candidate")
  let assert Error(reason) = search.replay([Stop(search.Steps)])
  assert string.contains(reason, "begin with the seed candidate")
}

// --- selection -------------------------------------------------------------------

fn trial(task: String, arm: String, index: Int, passed: Bool) -> stat.Trial {
  stat.Trial(
    task:,
    arm:,
    index:,
    reward: case passed {
      True -> 1.0
      False -> 0.0
    },
    scores: [],
    outcome: case passed {
      True -> stat.Passed
      False -> stat.VerifierFailed
    },
    cost: stat.Cost(0, 0.0, 0, 0, 0),
  )
}

pub fn per_task_means_count_failures_and_exclude_infrastructure_test() {
  let rows = [
    trial("t1", "a", 0, True),
    trial("t1", "a", 1, False),
    stat.Trial(..trial("t1", "a", 2, True), outcome: stat.Infrastructure),
    trial("t2", "a", 0, False),
  ]

  // t1: one pass of two counted; t2: none; t3: no row at all scores zero.
  assert search.per_task_means(rows, ["t1", "t2", "t3"])
    == [#("t1", 0.5), #("t2", 0.0), #("t3", 0.0)]
}

pub fn the_front_keeps_leaders_within_one_sample_and_prunes_dominated_test() {
  // K = 3, so a member within a third of the best on a task leads it.
  let members = [
    #("a", [#("t1", 1.0), #("t2", 0.0), #("t3", 0.667)]),
    #("b", [#("t1", 0.667), #("t2", 1.0), #("t3", 0.333)]),
    #("c", [#("t1", 0.333), #("t2", 0.0), #("t3", 0.0)]),
  ]
  let leaders = search.front(members, 3)

  // c leads nothing and is dropped; a leads t1 and t3 (b is within 1/3 on
  // t1), b leads t1 and t2.
  assert list.map(leaders, fn(leader) { #(leader.arm, leader.tasks_led) })
    == [#("a", 2), #("b", 2)]

  // A member dominated on every task by another is pruned even if it ties
  // one of them within tolerance.
  let dominated = [
    #("a", [#("t1", 1.0), #("t2", 1.0)]),
    #("d", [#("t1", 0.9), #("t2", 0.9)]),
  ]
  assert list.map(search.front(dominated, 3), fn(leader) { leader.arm })
    == ["a"]
}

pub fn the_parent_draw_is_proportional_and_reproducible_test() {
  let leaders = [
    search.Leader("a", 3, []),
    search.Leader("b", 1, []),
  ]
  let draws =
    list.index_map(list.repeat(Nil, 400), fn(_, i) { i + 1 })
    |> list.map(fn(step) {
      let assert Ok(#(arm, _)) =
        search.draw_parent(
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
    search.draw_parent(leaders, prng.from_string("s/1"))
  let assert Ok(#(again, _)) =
    search.draw_parent(leaders, prng.from_string("s/1"))
  assert first == again
  assert search.draw_parent([], prng.from_string("s/1")) == Error(Nil)
}

pub fn the_minibatch_draws_without_replacement_test() {
  let tasks = ["a", "b", "c", "d", "e", "f"]
  let #(drawn, _) = search.minibatch(tasks, 4, prng.from_string("x"))

  assert list.length(drawn) == 4
  assert list.length(list.unique(drawn)) == 4
  assert list.all(drawn, list.contains(tasks, _))

  // A minibatch wider than the split is the whole split, shuffled.
  let #(all, _) = search.minibatch(tasks, 10, prng.from_string("x"))
  assert list.sort(all, string.compare) == tasks
}

pub fn slots_rotate_round_robin_from_step_one_test() {
  let target = Target("p", "m", "api", Any)
  let slots = [arm.SystemSuffix(target), TaskPrefix(target)]

  assert search.slot_for(1, slots) == Ok(arm.SystemSuffix(target))
  assert search.slot_for(2, slots) == Ok(TaskPrefix(target))
  assert search.slot_for(3, slots) == Ok(arm.SystemSuffix(target))
  assert search.slot_for(1, []) == Error(Nil)
  assert search.slot_name(TaskPrefix(target)) == "task_prefix:p/m/api/any"
}

pub fn the_screen_passes_a_child_no_worse_than_its_parent_test() {
  let parent = [trial("t1", "p", 0, True), trial("t2", "p", 0, False)]
  let better = [trial("t1", "c", 0, True), trial("t2", "c", 0, True)]
  let same = [trial("t1", "c", 0, False), trial("t2", "c", 0, True)]
  let worse = [trial("t1", "c", 0, False), trial("t2", "c", 0, False)]

  assert search.screen(parent, better, ["t1", "t2"]) == search.Passed
  assert search.screen(parent, same, ["t1", "t2"]) == search.Passed
  assert search.screen(parent, worse, ["t1", "t2"]) == search.Failed
}

pub fn dispositions_follow_the_verdict_and_the_incumbent_test() {
  let flat =
    verdict.Indistinguishable(effect: 0.0, ci: #(-0.1, 0.1), p: 1.0, mde: 0.05)
  let weak = verdict.Underpowered(mde: 0.4, needed_tasks: 30, reason: "few")
  let harmed =
    verdict.Harmed(effect: -0.5, ci: #(-0.8, -0.2), p: 0.01, mde: 0.3)

  // Improved over the parent, which is the incumbent, leading more tasks.
  assert search.dispose(improved(), None, 5, 3) == search.Incumbent

  // Improved over the parent but not leading more tasks than the incumbent.
  assert search.dispose(improved(), None, 3, 3) == search.Joined

  // Improved over the parent, harmed against the incumbent.
  assert search.dispose(improved(), Some(harmed), 9, 3) == search.Joined

  // Improved over the parent, indistinguishable from the incumbent, leading more.
  assert search.dispose(improved(), Some(flat), 5, 3) == search.Incumbent

  assert search.dispose(flat, None, 9, 0) == search.ParetoOnly
  assert search.dispose(weak, None, 9, 0) == search.ParetoOnly
  assert search.dispose(harmed, None, 9, 0) == search.Harmed
  assert search.dispose(verdict.Incomplete("x"), None, 9, 0) == search.Unsettled
}
