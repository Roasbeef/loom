//// Slice 6: tapes, labels, the verdict computation and the `auto` gate.
////
//// The tests follow the slice's exit criteria. A/A on one tape is not called
//// either way beyond the instrument's bound, a planted admission flip reads
//// `Harmed`, a verdict goes stale when any part of its pin changes and the
//// pair returns to `observe`, `auto` is refused without a current passing
//// verdict across a restart, and a tape holds the thread as it stood.

import evalstat/verdict as stat
import gleam/dict
import gleam/int
import gleam/list
import gleam/string
import project/codec
import project/engine
import project/event.{type Event}
import project/gate
import project/judge
import project/model.{ShouldAccept, ShouldNotAccept, TriggerId}
import project/snapshot
import project/standing
import project/state.{type State}
import project/tape
import qcheck
import support/world.{arrival, fresh, run, source}

/// The seed of the A/A property. It is fixed so the gate is deterministic.
const aa_seed = 6001

/// Plans drawn by the A/A property.
const aa_plans = 300

fn id(index: Int) -> String {
  "t" <> string.pad_start(int.to_string(index), 2, "0")
}

fn text_of(trigger: model.TriggerId) -> String {
  "text of " <> trigger.value
}

// A project with `count` inferred triggers from one rule, each on its own
// thread. Even ones the router accepted (so `observe` recorded them) and odd
// ones it ignored. Every trigger carries the label that agrees with what the
// router did, so the recording is right everywhere.
fn recorded(count: Int) -> State {
  let events =
    list.index_map(list.repeat(Nil, count), fn(_, index) {
      let trigger =
        model.Trigger(
          ..world.overheard(id(index), "th" <> id(index)),
          actor: model.ActorId("pat" <> id(index)),
          at_ms: 1000 + index,
        )
      let decision = case index % 2 == 0 {
        True -> world.accept(id(index))
        False -> event.RoutedIgnore(TriggerId(id(index)))
      }
      [arrival(trigger), decision, event.RouterTurnEnded]
    })
    |> list.flatten
  let labels =
    list.index_map(list.repeat(Nil, count), fn(_, index) {
      event.Labelled(
        TriggerId(id(index)),
        case index % 2 == 0 {
          True -> ShouldAccept
          False -> ShouldNotAccept
        },
        model.PrincipalId("owner"),
      )
    })
  run(fresh(), [event.ModeSet(source, world.rule, model.Observe), ..events])
  |> run(labels)
}

fn tape_of(current: State) -> tape.Tape {
  tape.record(current, source, world.rule, text_of)
}

// --- tapes --------------------------------------------------------------------

pub fn a_tape_holds_the_thread_as_it_stood_test() {
  let first = world.overheard("a", "shared")
  let second =
    model.Trigger(
      ..world.overheard("b", "shared"),
      actor: model.ActorId("quin"),
    )
  let early =
    run(fresh(), [
      event.ModeSet(source, world.rule, model.Observe),
      arrival(first),
      event.RoutedIgnore(TriggerId("a")),
      event.RouterTurnEnded,
      arrival(second),
    ])
  let before = tape_of(early)

  // A comment arrives on the same thread after the recording.
  let later =
    model.Trigger(..world.overheard("c", "shared"), actor: model.ActorId("rae"))
  let after_comment =
    run(early, [
      event.RoutedIgnore(TriggerId("b")),
      event.RouterTurnEnded,
      arrival(later),
    ])
  let after = tape_of(after_comment)

  // The thread itself now holds the later comment, so the check below is not
  // vacuous.
  let assert Ok(thread) =
    dict.get(after_comment.threads, model.ThreadId("shared"))
  assert list.any(thread.entries, fn(entry) { entry.trigger == TriggerId("c") })

  // The earlier trigger's frame holds only itself, and the second one's holds
  // itself and the first. Neither names the later comment.
  let assert [frame_a, frame_b, ..] = after.frames
  assert list.map(frame_a.thread, fn(entry) { entry.trigger.value }) == ["a"]
  assert list.map(frame_b.thread, fn(entry) { entry.trigger.value })
    == ["b", "a"]
  assert !list.any(after.frames, fn(frame) {
    frame.trigger.id != TriggerId("c")
    && list.any(frame.thread, fn(entry) { entry.trigger == TriggerId("c") })
  })

  // Recording again after the comment gives the same frame for the earlier
  // triggers, apart from what the router has since answered.
  let assert [early_a, ..] = before.frames
  assert early_a.thread == frame_a.thread
  assert early_a.relation == frame_a.relation
}

pub fn a_tape_round_trips_and_its_decoder_is_total_test() {
  let found = tape_of(recorded(6))
  assert tape.decode(tape.encode(found)) == Ok(found)
  assert tape.decode("") == Error(tape.Malformed)
  assert tape.decode("{\"source\":\"s\"}") == Error(tape.Malformed)
  assert tape.decode(string.replace(tape.encode(found), "took", "ate"))
    == Error(tape.Malformed)
}

pub fn a_tape_selects_one_source_and_rule_test() {
  let current =
    run(recorded(4), [
      arrival(
        model.Trigger(
          ..world.overheard("z", "thz"),
          source: model.SourceId("slack"),
        ),
      ),
    ])
  assert list.length(tape_of(current).frames) == 4
}

// --- labels -------------------------------------------------------------------

pub fn only_a_trigger_a_rule_matched_can_be_labelled_test() {
  let current = recorded(2)
  let owner_trigger = world.owner("o1")
  let with_owner = run(current, [arrival(owner_trigger)])
  assert engine.apply(
      with_owner,
      event.Labelled(TriggerId("o1"), ShouldAccept, model.PrincipalId("owner")),
    )
    == Error(event.NotLabellable(TriggerId("o1")))
  assert engine.apply(
      with_owner,
      event.Labelled(
        TriggerId("ghost"),
        ShouldAccept,
        model.PrincipalId("owner"),
      ),
    )
    == Error(event.NotLabellable(TriggerId("ghost")))
}

pub fn a_later_label_replaces_the_earlier_one_and_counts_once_test() {
  let current = recorded(3)
  assert state.labelled(current, source, world.rule) == 3
  let flipped =
    run(current, [
      event.Labelled(
        TriggerId(id(0)),
        ShouldNotAccept,
        model.PrincipalId("owner"),
      ),
    ])
  assert state.labelled(flipped, source, world.rule) == 3
  assert dict.get(flipped.labels, TriggerId(id(0))) == Ok(ShouldNotAccept)
}

pub fn retention_keeps_a_labelled_trigger_test() {
  let current = recorded(4)
  let #(kept_all, dropped_none) = snapshot.retire(current, 1_000_000)
  assert dropped_none == []
  assert dict.size(kept_all.triggers) == 4

  // The same state without labels loses every settled trigger.
  let unlabelled = state.State(..current, labels: dict.new())
  let #(_, dropped) = snapshot.retire(unlabelled, 1_000_000)
  assert list.length(dropped) == 4
}

pub fn labels_and_pins_survive_a_snapshot_test() {
  let current =
    run(recorded(4), [
      event.RouterPinSet("rev", "model-x"),
      world.verdict(source, world.rule, "v1", model.VerdictFailed),
    ])
  let written = snapshot.encode(current)
  assert snapshot.decode(world.config(), written) == Ok(current)
}

// --- the computation ----------------------------------------------------------

pub fn fewer_labels_than_the_instrument_needs_is_refused_test() {
  let current = recorded(10)
  let samples =
    judge.replay_samples(tape_of(current), current.labels, gate.classify)
  assert judge.judge(samples, model.Replay)
    == Error(judge.NotEnoughLabels(10, 30))
}

pub fn replay_with_an_unchanged_gate_decides_what_was_recorded_test() {
  let current = recorded(30)
  let samples =
    judge.replay_samples(tape_of(current), current.labels, gate.classify)
  assert list.all(samples, fn(each) { each.candidate == [each.recorded] })
  let assert Ok(finding) = judge.judge(samples, model.Replay)

  // Nothing differs between the arms, so the instrument has no spread to
  // measure and says so. It is not called either way, and the replay lane
  // passes because no decision changed.
  assert finding.covers.changed == 0
  assert case finding.measured {
    stat.Underpowered(..) -> True
    _ -> False
  }
  assert finding.outcome == model.VerdictPassed
}

pub fn a_planted_admission_flip_reads_harmed_test() {
  let current = recorded(30)
  let refuse_everyone = fn(_, _) { gate.NotAdmitted(gate.SenderUnlisted) }
  let samples =
    judge.replay_samples(tape_of(current), current.labels, refuse_everyone)
  let assert Ok(finding) = judge.judge(samples, model.Replay)
  assert case finding.measured {
    stat.Harmed(..) -> True
    _ -> False
  }
  assert finding.outcome == model.VerdictFailed
  assert finding.covers.changed == 15
}

pub fn a_flip_that_helps_does_not_fail_the_pair_test() {
  // The recording was wrong on fifteen triggers: it took them on although the
  // label says not to. A gate that now refuses them agrees with the labels
  // more often than the recording did.
  let balanced =
    list.index_map(list.repeat(Nil, 30), fn(_, index) {
      case index < 15 {
        True ->
          judge.Sample(TriggerId(id(index)), ShouldNotAccept, judge.Take, [
            judge.Pass,
          ])
        False ->
          judge.Sample(TriggerId(id(index)), ShouldAccept, judge.Take, [
            judge.Take,
          ])
      }
    })
  let assert Ok(found) = judge.judge(balanced, model.Replay)
  assert case found.measured {
    stat.Improved(..) -> True
    _ -> False
  }
  assert found.outcome == model.VerdictPassed
}

// Thirty triggers, each with its own probability of the decision matching its
// label, and four uniforms: one for the recording and three for the candidate.
type Plan =
  List(#(Float, List(Float)))

fn plans(seed: Int, low: Float, high: Float) -> List(Plan) {
  let unit = qcheck.bounded_float(0.0, 1.0)
  let task =
    qcheck.map2(
      qcheck.bounded_float(low, high),
      qcheck.fixed_length_list_from(unit, 4),
      fn(p, draws) { #(p, draws) },
    )
  let plan = qcheck.fixed_length_list_from(task, 30)
  qcheck.generate(plan, aa_plans, qcheck.seed(seed)).0
}

// A plan as samples. The recording matches its label with the trigger's
// probability, and the candidate with that probability less `drop`.
fn samples_of(plan: Plan, drop: Float) -> List(judge.Sample) {
  list.index_map(plan, fn(task, index) {
    let choose = fn(draw, p) {
      case draw <. p {
        True -> judge.Take
        False -> judge.Pass
      }
    }
    let assert [first, ..rest] = task.1
    judge.Sample(
      TriggerId(id(index)),
      ShouldAccept,
      choose(first, task.0),
      list.map(rest, choose(_, task.0 -. drop)),
    )
  })
}

fn live_verdicts(plans: List(Plan), drop: Float) -> List(stat.Verdict) {
  list.map(plans, fn(plan) {
    let assert Ok(found) = judge.judge(samples_of(plan, drop), model.Live)
    found.measured
  })
}

fn count_harmed(verdicts: List(stat.Verdict)) -> Int {
  list.count(verdicts, fn(measured) {
    case measured {
      stat.Harmed(..) -> True
      _ -> False
    }
  })
}

/// Both arms draw from one probability per trigger, as in the instrument's own
/// A/A property. The pair must not be called better or worse more than the
/// instrument's bound of its plans. The bound is 6 percent of 300 plans, as in
/// the instrument's own test. On this seed the rule calls 5 of 300.
pub fn live_a_a_is_not_called_either_way_test() {
  let verdicts = live_verdicts(plans(aa_seed, 0.1, 0.9), 0.0)
  let called =
    list.count(verdicts, fn(measured) {
      case measured {
        stat.Improved(..) | stat.Harmed(..) -> True
        _ -> False
      }
    })
  assert called <= 18
}

fn live_outcomes(plans: List(Plan), drop: Float) -> List(model.VerdictOutcome) {
  list.map(plans, fn(plan) {
    let assert Ok(found) = judge.judge(samples_of(plan, drop), model.Live)
    found.outcome
  })
}

fn count_passed(outcomes: List(model.VerdictOutcome)) -> Int {
  list.count(outcomes, fn(each) { each == model.VerdictPassed })
}

/// What the interval rule alone would have decided, with the floor taken away.
/// Counting it beside the full outcome shows what the floor changes.
fn interval_outcomes(
  plans: List(Plan),
  drop: Float,
) -> List(model.VerdictOutcome) {
  list.map(plans, fn(plan) {
    let assert Ok(found) = judge.judge(samples_of(plan, drop), model.Live)
    judge.outcome_of(found.measured, found.covers, 100)
  })
}

/// A live run with no change passes on most plans, so `auto` is reachable. The
/// plans are a router that agrees with the labels on 75 to 100 percent of its
/// triggers, 87.5 on average. Measured on this seed: 283 of 300 plans pass,
/// all of them on the interval rule as well. The floor is 260.
pub fn a_live_run_with_no_change_usually_passes_test() {
  let outcomes = live_outcomes(plans(aa_seed, 0.75, 1.0), 0.0)
  assert count_passed(outcomes) >= 260
}

/// A thirty-point drop in a live run of thirty triggers, three trials each,
/// against the one recorded decision per trigger. The instrument's verdict
/// alone reads `Harmed` on only 179 of 300 plans on this seed, because the
/// recorded arm is a single decision per trigger. The instrument's own test
/// reaches 95 percent with three trials on both arms. A pass therefore also
/// needs the interval to stay above `judge.max_bound_points`, and with that
/// 13 of 300 plans pass. The ceiling is 30. A pass needs the floor as well, and
/// the drop leaves these plans below it, so none pass.
pub fn a_large_live_drop_rarely_passes_test() {
  let large = plans(6002, 0.35, 0.95)
  assert count_passed(interval_outcomes(large, 0.3)) <= 30
  assert count_passed(live_outcomes(large, 0.3)) == 0
  assert count_harmed(live_verdicts(large, 0.3)) >= 150
}

/// A fifteen-point drop sits inside the interval of a run this size. From a
/// router that agrees on 80 to 100 percent of triggers, 124 of 300 plans pass
/// the interval rule and 96 also reach the floor, and 163 read `Harmed`. This
/// is why a pass rules out a large regression and does not show parity. The
/// floor is 60 passes, and `Harmed` is held under 200.
pub fn a_small_live_drop_often_passes_test() {
  let small = plans(6003, 0.8, 1.0)
  assert count_passed(interval_outcomes(small, 0.15)) >= 100
  assert count_passed(live_outcomes(small, 0.15)) >= 60
  assert count_harmed(live_verdicts(small, 0.15)) <= 200
}

/// The case the floor is for. A router that agrees with the labels on about
/// half the triggers, and did so when it was recorded, shows no change on
/// either arm. The interval rule passes 249 of 300 such plans. The floor
/// fails all of them, and fails nearly all of the plans at 65 percent. A
/// router at 85 percent still passes on 278 of 300.
pub fn the_floor_fails_a_router_that_is_wrong_on_both_arms_test() {
  let guessing = plans(6004, 0.45, 0.55)
  assert count_passed(interval_outcomes(guessing, 0.0)) >= 200
  assert count_passed(live_outcomes(guessing, 0.0)) == 0
  let poor = plans(6004, 0.6, 0.7)
  assert count_passed(live_outcomes(poor, 0.0)) <= 20
  let good = plans(6004, 0.8, 0.9)
  assert count_passed(live_outcomes(good, 0.0)) >= 250
}

pub fn the_outcome_needs_an_unharmed_verdict_and_a_bounded_drop_test() {
  let within = model.Covers(model.Live, 30, 3, 5, 25)
  assert judge.outcome_of(stat.Underpowered(0.25, 100, "x"), within, 100)
    == model.VerdictPassed
  assert judge.outcome_of(
      stat.Indistinguishable(0.0, #(-0.2, 0.2), 0.9, 0.2),
      within,
      100,
    )
    == model.VerdictPassed
  let wide = model.Covers(..within, bound_points: 60)
  assert judge.outcome_of(stat.Underpowered(0.6, 100, "x"), wide, 100)
    == model.VerdictFailed
  assert judge.outcome_of(
      stat.Harmed(-0.4, #(-0.5, -0.3), 0.001, 0.2),
      within,
      100,
    )
    == model.VerdictFailed
  assert judge.outcome_of(stat.Incomplete("x"), within, 100)
    == model.VerdictFailed
}

/// A comparison cannot see a candidate that is as wrong as the recording was.
/// With no change, no drop and an interval inside the bound, a candidate whose
/// agreement is below the floor still fails, and one at the floor passes.
pub fn the_outcome_needs_the_candidate_to_agree_with_the_labels_test() {
  let within = model.Covers(model.Live, 30, 3, 0, 0)
  let quiet = stat.Underpowered(0.0, 100, "no spread")
  assert judge.min_agreement_points == 75
  assert judge.outcome_of(quiet, within, judge.min_agreement_points - 1)
    == model.VerdictFailed
  assert judge.outcome_of(quiet, within, judge.min_agreement_points)
    == model.VerdictPassed
  assert judge.outcome_of(quiet, within, 0) == model.VerdictFailed
}

/// A router that is wrong on half the triggers on both arms has not regressed,
/// and the finding reports that agreement and fails it.
pub fn a_candidate_that_matches_the_recording_but_not_the_labels_fails_test() {
  let wrong_alike =
    list.index_map(list.repeat(Nil, 30), fn(_, index) {
      case index < 15 {
        True ->
          judge.Sample(TriggerId(id(index)), ShouldNotAccept, judge.Take, [
            judge.Take,
            judge.Take,
            judge.Take,
          ])
        False ->
          judge.Sample(TriggerId(id(index)), ShouldAccept, judge.Take, [
            judge.Take,
            judge.Take,
            judge.Take,
          ])
      }
    })
  let assert Ok(found) = judge.judge(wrong_alike, model.Live)
  assert found.covers.changed == 0
  assert found.covers.bound_points == 0
  assert found.agreement_points == 50
  assert found.outcome == model.VerdictFailed
}

/// The figure is rounded down, so a run on the line is not counted in: 74 of
/// 99 trials is 74.7 points and reads 74.
pub fn agreement_is_rounded_down_test() {
  let samples =
    list.index_map(list.repeat(Nil, 33), fn(_, index) {
      let trials = case index < 25 {
        True -> [judge.Take, judge.Take, judge.Take]
        False -> [judge.Pass, judge.Pass, judge.Pass]
      }
      judge.Sample(TriggerId(id(index)), ShouldAccept, judge.Take, trials)
    })
  let assert Ok(found) = judge.judge(samples, model.Live)
  assert found.agreement_points == 75
  let one_short =
    list.index_map(samples, fn(each, index) {
      case index == 24 {
        True ->
          judge.Sample(..each, candidate: [judge.Take, judge.Take, judge.Pass])
        False -> each
      }
    })
  let assert Ok(near) = judge.judge(one_short, model.Live)
  assert near.agreement_points == 74
  assert near.outcome == model.VerdictFailed
}

// --- the pin and the gate -----------------------------------------------------

fn pinned(version: String, prompt: String, router_model: String) -> model.Pin {
  model.Pin(version, prompt, router_model)
}

pub fn a_replay_pass_does_not_unlock_auto_test() {
  let replay = model.Covers(model.Replay, 30, 1, 0, 0)
  let found =
    restart([
      event.RouterPinSet("rev1", "m1"),
      event.VerdictRecorded(
        source,
        world.rule,
        pinned("v1", "rev1", "m1"),
        model.VerdictPassed,
        replay,
      ),
    ])

  assert standing.of(found, source, world.rule) == standing.ReplayOnly(replay)
  assert state.verdict_of(found, source, world.rule) == gate.VerdictMissing
  let assert Error(_) =
    engine.apply(found, event.ModeSet(source, world.rule, model.Auto))
  assert string.contains(
    standing.refusal(found, source, world.rule),
    "only a live verdict",
  )
}

// A pair that passed under v1, prompt rev1 and model m1, and is in auto.
fn armed() -> List(Event) {
  [
    event.RouterPinSet("rev1", "m1"),
    event.VerdictRecorded(
      source,
      world.rule,
      pinned("v1", "rev1", "m1"),
      model.VerdictPassed,
      world.covers,
    ),
    event.ModeSet(source, world.rule, model.Auto),
  ]
}

// What a restart does: every event is written to the ledger and read back.
fn restart(events: List(Event)) -> State {
  let read =
    list.map(events, fn(each) {
      let assert Ok(back) = codec.decode(codec.encode(each))
      back
    })
  let assert Ok(rebuilt) = engine.replay(world.config(), read)
  rebuilt
}

pub fn a_changed_policy_prompt_or_model_returns_the_pair_to_observe_test() {
  let changes = [
    #(event.PolicyVersionSet("v2"), "the policy version"),
    #(event.RouterPinSet("rev2", "m1"), "the router prompt"),
    #(event.RouterPinSet("rev1", "m2"), "the router model"),
  ]
  list.each(changes, fn(change) {
    let events = list.append(armed(), [change.0])
    let current = restart(armed())
    assert state.mode_of(current, source, world.rule) == model.Auto
    assert state.verdict_of(current, source, world.rule) == gate.VerdictCurrent

    // The demotion is part of the ledger's fold, so it holds after a restart.
    let demoted = restart(events)
    assert state.mode_of(demoted, source, world.rule) == model.Observe
    assert state.verdict_of(demoted, source, world.rule) == gate.VerdictMissing
    let assert standing.Stale(_, why) = standing.of(demoted, source, world.rule)
    assert string.contains(why, change.1)
  })
}

pub fn announcing_the_same_pin_again_changes_nothing_test() {
  let events = list.append(armed(), [event.RouterPinSet("rev1", "m1")])
  assert state.mode_of(restart(events), source, world.rule) == model.Auto
}

pub fn auto_is_refused_with_no_failing_or_stale_verdict_test() {
  let refused = Error(event.VerdictRequired(source, world.rule))
  let ask = event.ModeSet(source, world.rule, model.Auto)

  // No verdict at all.
  assert engine.apply(restart([]), ask) == refused

  // A failing verdict under the pin in force.
  let failing =
    restart([
      event.RouterPinSet("rev1", "m1"),
      event.VerdictRecorded(
        source,
        world.rule,
        pinned("v1", "rev1", "m1"),
        model.VerdictFailed,
        world.covers,
      ),
    ])
  assert engine.apply(failing, ask) == refused

  // A passing verdict under a pin that has since changed.
  let stale =
    restart([
      event.RouterPinSet("rev1", "m1"),
      event.VerdictRecorded(
        source,
        world.rule,
        pinned("v1", "rev1", "m1"),
        model.VerdictPassed,
        world.covers,
      ),
      event.RouterPinSet("rev1", "m2"),
    ])
  assert engine.apply(stale, ask) == refused

  // A passing verdict under the pin in force, after a restart, is accepted.
  let current = restart(list.take(armed(), 2))
  let assert Ok(#(allowed, _)) = engine.apply(current, ask)
  assert state.mode_of(allowed, source, world.rule) == model.Auto
}

pub fn a_verdict_for_another_pair_does_not_allow_auto_test() {
  let other =
    restart([
      event.VerdictRecorded(
        source,
        model.RuleId("other"),
        pinned("v1", "", ""),
        model.VerdictPassed,
        world.covers,
      ),
    ])
  assert engine.apply(other, event.ModeSet(source, world.rule, model.Auto))
    == Error(event.VerdictRequired(source, world.rule))
}

pub fn the_refusal_says_what_is_missing_test() {
  let none = standing.refusal(recorded(12), source, world.rule)
  assert string.contains(none, "no verdict has been recorded")
  assert string.contains(none, "12 of 30")
  assert string.contains(none, "Label 18 more")

  let ready = standing.refusal(recorded(30), source, world.rule)
  assert string.contains(ready, "Run the verdict")

  let stale =
    restart(list.append(armed(), [event.PolicyVersionSet("v2")]))
    |> standing.refusal(source, world.rule)
  assert string.contains(stale, "stale")
  assert string.contains(stale, "the policy version")
}

pub fn what_a_pass_claims_is_said_in_words_test() {
  let replay = standing.claim(model.Covers(model.Replay, 30, 1, 2, 28))
  assert string.contains(
    replay,
    "says nothing about the router's prompt or model",
  )
  assert string.contains(replay, "28 points")
  let live = standing.claim(model.Covers(model.Live, 30, 3, 4, 19))
  assert string.contains(live, "rules out a drop of more than 19 points")
  assert string.contains(live, "does not show the router is as good as before")
}
