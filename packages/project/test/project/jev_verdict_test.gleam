//// What a live Jev verdict reports from its trials: how they ended, the
//// coverage and agreement across attach bars, and the comparison with the
//// router's record. Nothing here sends a request; the trials are built by hand
//// from answers.

import gleam/list
import gleam/option.{None, Some}
import project/jev
import project/jev_verdict.{
  Abstained, Decided, Elsewhere, Entry, Failed, Health, Opened, Row, Silver,
  Trial,
}
import project/model.{Explicit, ShouldAccept, ShouldNotAccept, TriggerId}
import support/world.{accept, arrival, fresh, owner, run, ticket_of}

fn answers(clear: Int, continues: option.Option(Int)) -> jev.Answers {
  jev.Answers(
    asks_for_work: None,
    clear_alone: clear,
    continues:,
    which_ticket: None,
    decline_reason: None,
    agent: None,
  )
}

// A shape that lists one explicit ticket, so the attach bar is in play.
fn listed() -> jev.Shape {
  let current = run(fresh(), [arrival(owner("c1")), accept("c1")])
  jev.shape(current, Explicit, [])
}

fn bars(percent: Int) -> jev.Bars {
  let assert Ok(found) = jev.bars(percent) as "the percent is a bar"
  found
}

// A trial whose answers are decided at the default bar, as the run does.
fn trial(clear: Int, continues: option.Option(Int)) -> jev_verdict.Trial {
  let found = answers(clear, continues)
  Trial(
    jev_verdict.outcome_of(jev.decide(listed(), bars(80), found)),
    listed(),
    Some(found),
    Some("jev-1.14.0"),
  )
}

fn failed() -> jev_verdict.Trial {
  Trial(Failed(jev.Unavailable), listed(), None, None)
}

pub fn the_trials_are_counted_by_how_they_ended_test() {
  let entry =
    Entry(TriggerId("a"), ShouldAccept, Elsewhere, [
      trial(9500, Some(500)),
      trial(1000, Some(500)),
      failed(),
    ])
  assert jev_verdict.health([entry]) == Health(1, 1, 1)
  assert jev_verdict.health([]) == Health(0, 0, 0)
}

pub fn only_service_failures_count_against_the_health_bar_test() {
  // Abstaining is intended behaviour and is not a failure.
  assert jev_verdict.service_healthy(Health(
    decided: 10,
    abstained: 80,
    failed: 4,
  ))
  assert !jev_verdict.service_healthy(Health(
    decided: 90,
    abstained: 0,
    failed: 10,
  ))
  assert jev_verdict.service_healthy(Health(0, 0, 0))
}

pub fn a_higher_attach_bar_settles_fewer_attaches_test() {
  // The message continues the listed ticket with probability 0.85, so it
  // attaches at a bar of 80 or less and falls back above it.
  let entry =
    Entry(TriggerId("a"), ShouldAccept, Elsewhere, [trial(9500, Some(8500))])
  let assert [low, high] = jev_verdict.sweep([entry], [80, 90])
  assert low == Row(percent: 80, decided: 1, trials: 1, agreeing: 1)
  assert high == Row(percent: 90, decided: 0, trials: 1, agreeing: 0)
}

pub fn a_failed_trial_settles_nothing_at_any_bar_and_stays_in_the_total_test() {
  let entry =
    Entry(TriggerId("a"), ShouldAccept, Elsewhere, [failed(), failed()])
  let assert [row] = jev_verdict.sweep([entry], [80])
  assert row == Row(percent: 80, decided: 0, trials: 2, agreeing: 0)
}

pub fn agreement_is_with_the_label_not_with_taking_work_test() {
  // New work is taken, so it agrees with an accept label and not a reject one.
  let work = trial(9500, Some(500))
  let accepted = Entry(TriggerId("a"), ShouldAccept, Elsewhere, [work])
  let rejected = Entry(TriggerId("b"), ShouldNotAccept, Elsewhere, [work])
  let assert [row] = jev_verdict.sweep([accepted, rejected], [80])
  assert row == Row(percent: 80, decided: 2, trials: 2, agreeing: 1)
}

pub fn a_bar_that_is_not_a_bar_is_left_out_of_the_sweep_test() {
  let entry =
    Entry(TriggerId("a"), ShouldAccept, Elsewhere, [trial(9500, None)])
  assert list.length(jev_verdict.sweep([entry], [50, 80, 101])) == 1
}

pub fn jev_is_compared_with_the_router_only_where_both_chose_test() {
  let opens = trial(9500, Some(500))
  let agreeing =
    Entry(TriggerId("a"), ShouldAccept, Opened, [opens, opens, opens])
  let differing =
    Entry(TriggerId("b"), ShouldAccept, jev_verdict.Ignored, [
      opens,
      opens,
      opens,
    ])
  let undecided =
    Entry(TriggerId("c"), ShouldAccept, Opened, [trial(1000, None)])
  let elsewhere = Entry(TriggerId("d"), ShouldAccept, Elsewhere, [opens])
  let found = jev_verdict.silver([agreeing, differing, undecided, elsewhere])
  assert found.compared == 2
  assert found.agreeing == 1
  assert found.disagreements
    == [
      jev_verdict.Disagreement(TriggerId("b"), jev: "open", router: "ignore"),
    ]
  assert jev_verdict.silver([]) == Silver(0, 0, [])
}

pub fn a_triggers_decision_is_the_one_most_of_its_trials_made_test() {
  let attach = trial(9500, Some(8500))
  let opens = trial(9500, Some(500))
  let entry =
    Entry(
      TriggerId("a"),
      ShouldAccept,
      jev_verdict.AttachedTo(ticket_of("c1")),
      [
        attach,
        opens,
        attach,
      ],
    )
  let found = jev_verdict.silver([entry])
  assert found == Silver(compared: 1, agreeing: 1, disagreements: [])
}

pub fn the_outcome_of_a_fallback_is_an_abstention_test() {
  assert jev_verdict.outcome_of(jev.Fallback(jev.LowClarity))
    == Abstained(jev.LowClarity)
  assert jev_verdict.outcome_of(jev.New(None)) == Decided(jev.New(None))
}

pub fn shares_are_basis_points_rounded_down_test() {
  assert jev_verdict.points(1, 3) == 3333
  assert jev_verdict.points(5, 0) == 0
}
