//// Loom's side of the search: the row codec, the adapter that feeds a
//// Loom log to the `gepa` fold, the ledger-to-score aggregation, and the
//// one thing the extraction must not have changed, the draws.

import eval/arm.{Any, Target, TaskPrefix}
import eval/search.{
  type Event, Candidate, Judgement, Reflection, Refusal, Run, Stop,
}
import eval/split
import evalstat/prng as theirs
import evalstat/trial as stat
import evalstat/verdict
import gepa
import gepa/prng as ours
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
      gepa.Complete,
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

/// A store with no directory behind it: every arm has one slot whose text
/// is its id.
fn bare_store() -> search.Store {
  search.Store(components: fn(id) { Ok([#("task_prefix:x", id)]) })
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

pub fn a_reflection_row_without_a_finish_reads_as_unknown_test() {
  // A row written before the key existed decodes, and says it did not
  // know how its answer ended; a new row carries the word.
  let old =
    "{\"v\":1,\"kind\":\"reflection\",\"step\":1,\"provider\":\"fixture\","
    <> "\"model\":\"fixture\",\"api\":\"anthropic-messages\",\"dollars\":0.001,"
    <> "\"input_digest\":\"in\",\"output_digest\":\"out\"}"
  let assert Ok(Reflection(finish: gepa.Unknown, ..)) = search.decode_line(old)

  let truncated =
    Reflection(
      1,
      "fixture",
      "fixture",
      "anthropic-messages",
      0.001,
      "in",
      "out",
      gepa.Truncated,
    )
  assert string.contains(
    search.encode_line(truncated),
    "\"finish\":\"truncated\"",
  )
  assert search.decode_line(search.encode_line(truncated)) == Ok(truncated)

  // The library's row carries the finish through, as the one proposal of
  // a width-one step.
  let assert Ok(gepa.Reflected(finish: gepa.Truncated, proposal: 1, of: 1, ..)) =
    search.to_gepa(truncated, bare_store())
}

pub fn a_loom_log_replays_through_the_library_test() {
  let assert Ok(state) = search.replay(one_step(), bare_store())

  // The library's state carries the pool and the incumbent; Loom's
  // wrapper keeps the confirm verdict the headline prints.
  assert state.search.pool == [seed, child]
  assert state.search.incumbent == child
  assert state.search.step == 1
  assert state.search.open == None
  assert search.stopped(state) == Some(search.Steps)
  assert state.search.reflections == 1
  assert state.search.spent_reflecting == 0.001
  assert gepa.children(state.search) == 1
  let assert Some(search.Confirmation(best:, plan:, verdict: Some(found))) =
    state.confirmation
  assert best == child && plan == plan_e && found == improved()

  // The Loom-shaped projections name plans and dispositions as before.
  let assert [first, second] = search.members(state)
  assert first.arm == seed && first.validate_plan == Some(plan_a)
  assert second.parent == Some(seed) && second.validate_plan == Some(plan_d)
  assert second.disposition == Some(search.Incumbent)
  assert search.plan_of(state, 1, search.ChildMinibatch) == Ok(plan_c)
  assert search.recorded_cap(state, plan_b) == Ok(0.0)
  assert list.length(search.runs(state)) == 5

  // A child's components are the parent's with the slot replaced, which
  // the store's arm files agree with.
  let assert Ok(minted) =
    list.find(state.search.members, fn(m) { m.candidate == child })
  assert minted.components == [#("task_prefix:x", child)]
}

pub fn a_deleted_run_row_still_refuses_replay_test() {
  // Each run row of the step, deleted alone, is caught by the row that
  // presupposes it, through the adapter as it was before it.
  list.each([plan_a, plan_b, plan_c, plan_d], fn(deleted) {
    let rows =
      list.filter(one_step(), fn(row) {
        case row {
          Run(plan:, ..) -> plan != deleted
          _ -> True
        }
      })
    let assert Error(reason) = search.replay(rows, bare_store())
    assert string.contains(reason, "search row missing")
  })

  // A contradicting disposition and a row after the stop are refused.
  let assert Error(contradiction) =
    search.replay(
      list.append(list.take(one_step(), 7), [
        Judgement(child, seed, split.Validate, improved(), search.ParetoOnly),
      ]),
      bare_store(),
    )
  assert string.contains(contradiction, "does not follow")
  let assert Error(after) =
    search.replay(list.append(one_step(), [Stop(search.Steps)]), bare_store())
  assert string.contains(after, "follows the stop row")
  assert search.replay([], bare_store())
    == Error("search row missing: the seed candidate")

  // A cut log is an open step at the stage its rows reached.
  let assert Ok(cut) = search.replay(list.take(one_step(), 6), bare_store())
  let assert Some(progress) = cut.search.open
  assert progress.reached == gepa.ChildMeasured && progress.child == Some(child)
}

pub fn the_adapter_refuses_what_the_old_fold_refused_test() {
  // A run whose split does not match its role, and a candidate after the
  // seed that is not a reflection into a slot: neither has a library
  // counterpart, and the old fold refused both.
  let refused = fn(events: List(Event), naming: String) {
    let assert Error(reason) = search.replay(events, bare_store())
    assert string.contains(reason, naming)
  }

  refused(
    list.append(list.take(one_step(), 2), [
      Run(seed, split.Validate, plan_b, 1, search.ParentMinibatch, 0.0),
    ]),
    "parent_minibatch run draws from the tune split",
  )
  refused(
    list.append(list.take(one_step(), 6), [
      Run(child, split.Tune, plan_d, 1, search.ValidateRun, 0.0),
    ]),
    "validate run draws from the validate split",
  )
  refused(
    list.append(list.take(one_step(), 4), [
      Candidate(child, Some(seed), 1, search.Seed, Some("task_prefix:x")),
    ]),
    "must be reflected from a parent into a slot",
  )
  refused(
    list.append(list.take(one_step(), 4), [
      Candidate(child, Some(seed), 1, search.Reflected, None),
    ]),
    "must be reflected from a parent into a slot",
  )
  refused(
    list.append(list.take(one_step(), 4), [
      Candidate(child, None, 1, search.Reflected, None),
    ]),
    "step 0, from the seed",
  )
}

pub fn the_library_s_words_round_trip_with_loom_s_test() {
  list.each(
    [
      search.Incumbent,
      search.Joined,
      search.ParetoOnly,
      search.Harmed,
      search.Unsettled,
      search.Refused,
      search.ScreenedOut,
      search.Confirmed,
      search.Unconfirmed,
    ],
    fn(disposition) {
      assert search.disposition_from_gepa(search.disposition_to_gepa(
          disposition,
        ))
        == disposition
    },
  )
  list.each(
    [search.Steps, search.Dollars, search.Reflections, search.Candidates],
    fn(reason) {
      assert search.stop_from_gepa(search.stop_to_gepa(reason)) == reason
    },
  )
}

pub fn the_library_s_generator_draws_what_evalstat_s_does_test() {
  // The library carries its own copy of the generator so it needs no
  // Loom package; the copy must stay the same stream, or a search log
  // written before the extraction would draw other parents on resume.
  list.each(["search/1", "search/2", "", "plan-7", "ünï"], fn(seed_text) {
    let mine =
      list.repeat(Nil, 200)
      |> list.map_fold(ours.from_string(seed_text), fn(state, _) {
        let #(value, state) = ours.next(state)
        #(state, value)
      })
    let evalstat =
      list.repeat(Nil, 200)
      |> list.map_fold(theirs.from_string(seed_text), fn(state, _) {
        let #(value, state) = theirs.next(state)
        #(state, value)
      })

    assert mine.1 == evalstat.1
    assert ours.below(ours.from_string(seed_text), 7).0
      == theirs.below(theirs.from_string(seed_text), 7).0
  })
}

// --- an arm and a ledger as the library sees them ---------------------------------

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

  // t1: one pass of two counted; t2: a measured zero; t3, with no counted
  // row at all, is left out rather than scored, so the screen's tie rule
  // cannot read it as a failure the child fixed (the front still reads a
  // missing task as zero).
  assert search.per_task_means(rows, ["t1", "t2", "t3"])
    == [#("t1", 0.5), #("t2", 0.0)]
  assert search.per_task_means([], ["t1"]) == []
}

pub fn an_arm_is_a_component_map_keyed_by_slot_name_test() {
  let target = Target("p", "m", "api", Any)
  let candidate =
    arm.Arm(
      id: "",
      name: "n",
      components: [#(TaskPrefix(target), "Be brief."), #(arm.PromptPack, "")],
      knobs: arm.Knobs(roles: [], thinking: [], disabled_tools: []),
    )

  assert search.slot_name(TaskPrefix(target)) == "task_prefix:p/m/api/any"
  assert search.component_map(candidate)
    == [#("task_prefix:p/m/api/any", "Be brief."), #("prompt_pack", "")]
}
