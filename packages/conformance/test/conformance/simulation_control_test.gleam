//// `control.attempt`'s three outcomes, tested for the property the
//// simulation depends on: which of them a real clock decides.
////
//// Anything reaching into a session tree that may be mid-restart goes
//// through `attempt`, and for a long time every way of not getting an
//// answer cost the caller its whole millisecond budget — including the
//// common one, where the process carrying the action simply died. A
//// budget is a wall clock, a wall clock is not part of the seed, and a
//// seeded corpus whose verdicts move with host load is not an oracle
//// (issue #44). So the death is observed through a monitor now, and the
//// clock is left holding only the case nothing is expected to reach.
////
//// The two budgets below are chosen to make a regression loud rather
//// than subtle. `raises_without_waiting_on_the_clock_test` gives the
//// attempt a full minute and expects it back at once: put the clock back
//// on that path and the test does not fail an assertion, it hangs past
//// the framework's own timeout.

import conformance/simulation/control
import conformance/simulation/script.{type Trigger}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/string

// A death that is nobody's fault: the action addresses a named process
// that is not registered, which is what every api call into a tree
// mid-restart does.
fn raising_action() -> Int {
  let absent: process.Name(Int) = process.new_name("no-such-process-here")
  process.call_forever(process.named_subject(absent), fn(_reply) { 0 })
}

/// An action that answers is answered, and a run that only ever answered
/// has nothing to say about its own timing.
pub fn answered_records_nothing_test() {
  let ctl = control.start()
  let outcome =
    control.attempt(ctl, at: "test", action: fn() { 41 + 1 }, within_ms: 1000)
  let waits = control.waits(ctl)
  control.stop(ctl)
  assert outcome == control.Answered(42)
  assert waits == []
}

/// The carrier dying is a monitored event, not a timeout. The budget
/// here is a minute; the test must finish in milliseconds.
pub fn raises_without_waiting_on_the_clock_test() {
  let ctl = control.start()
  let outcome =
    control.attempt(
      ctl,
      at: "unregistered",
      action: raising_action,
      within_ms: 60_000,
    )
  let waits = control.waits(ctl)
  control.stop(ctl)
  assert outcome == control.Raised
    as "a carrier that raised must come back as Raised, not as a timeout"
  assert waits == ["raised@unregistered"]
}

/// The one path a real clock still decides: a carrier that neither
/// answers nor dies. It is reported as its own outcome and recorded, so
/// a failing seed can say the wall clock was involved.
pub fn expiry_is_reported_and_recorded_test() {
  let ctl = control.start()
  let outcome =
    control.attempt(
      ctl,
      at: "wedged",
      action: fn() {
        process.sleep(60_000)
        Nil
      },
      within_ms: 20,
    )
  let waits = control.waits(ctl)
  control.stop(ctl)
  assert outcome == control.Expired
  assert waits == ["expired@wedged"]
}

/// A claimed intervention opens a debt and settling it closes the debt,
/// so a run can tell "this scripted turn was admitted" from "this
/// scripted turn was claimed by a process that never came back". The
/// second is what the runner reports as harness damage rather than as a
/// behaviour difference.
pub fn a_claimed_intervention_brackets_its_admission_test() {
  let ctl = control.start()
  let first = control.claim_intervention(ctl, "steer@turn1", "steer")
  control.intervened(ctl, "steer")
  let again = control.claim_intervention(ctl, "steer@turn1", "steer")
  let waits = control.waits(ctl)
  control.stop(ctl)
  assert first as "the first claim must succeed"
  assert !again as "a one-shot intervention must not be claimable twice"
  assert waits == ["intervening@steer", "intervened@steer"]
}

/// An intervention claimed and never settled leaves the opening on its
/// own, which is exactly the shape the runner looks for.
pub fn an_unsettled_intervention_leaves_its_opening_test() {
  let ctl = control.start()
  let _claimed = control.claim_intervention(ctl, "followup@turn1", "follow-up")
  let waits = control.waits(ctl)
  control.stop(ctl)
  assert list.any(waits, string.starts_with(_, "intervening@"))
  assert !list.any(waits, string.starts_with(_, "intervened@"))
}

/// A live effect cannot resume while its scripted payload is still queued.
/// The runner owns the release, so the settlement that follows the wait can
/// never overtake the intervention because an unrelated wall clock expired.
pub fn an_intervention_waits_for_the_runner_release_test() {
  let ctl = control.start()
  let finished: Subject(Nil) = process.new_subject()
  let _waiter =
    process.spawn_unlinked(fn() {
      control.await_intervention(ctl, script.DuringTurn(turn: 1))
      process.send(finished, Nil)
    })
  let pending = await_pending(ctl, attempts: 100)
  assert process.receive(finished, within: 0) == Error(Nil)
    as "the waiting effect must not resume before the runner releases it"
  let assert [#(script.DuringTurn(turn: 1), release)] = pending
    as "the runner must receive the registered intervention"
  process.send(release, Nil)
  assert process.receive(finished, within: 1000) == Ok(Nil)
    as "the effect must resume after the runner releases it"
  control.stop(ctl)
}

fn await_pending(
  ctl: control.Control,
  attempts attempts: Int,
) -> List(#(Trigger, Subject(Nil))) {
  case control.take_pending_interventions(ctl), attempts > 0 {
    [_, ..] as pending, _ -> pending
    [], True -> {
      process.sleep(1)
      await_pending(ctl, attempts: attempts - 1)
    }
    [], False -> []
  }
}
