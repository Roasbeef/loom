//// The checkpoint poll's two periods, from the outside: a strand with an
//// operation open ticks at `poll_interval_ms`, a strand between turns ticks
//// at `idle_poll_interval_ms`, and exactly one chain of ticks is live
//// whichever of the two it is running.
////
//// The point of the long period is hibernation. `weft/actor.hibernate_after`
//// is a receive timeout, so it fires only if the mailbox is genuinely quiet
//// for `runtime/residency.hibernate_after_ms`; a strand that re-armed a
//// 200 ms tick unconditionally could never be, and the strand is the actor
//// holding the largest `Effects` heap in a session assembly. The tests below
//// do not wait out the residency interval — the client package's opt-in
//// `assembly_heap_census_test` observes the sleep itself — they assert the
//// property that makes it reachable, which is that an idle strand stops
//// arming short ticks.
////
//// Both periods are observed through the injected `Timers` seam by their
//// exact delays, which is why the two constants below are numbers no other
//// timer in the tree picks: the retry ladder, the abort pacing delay and the
//// writer's lease renewal all arm on their own values.

import core/clock
import gleam/erlang/process.{type Subject}
import runtime/api
import runtime/effects
import runtime/residency
import runtime/supervisor
import session/session.{type Session}
import support/fake
import support/harness
import support/recorder

// The period an occupied strand ticks at in these tests.
const short_poll_ms = 37

// The period an idle strand falls back to. Long enough that no test here can
// pass by waiting for it, so anything that does complete was woken by a
// doorbell, and short enough that the suite can watch a chain that runs at it.
const long_poll_ms = 2731

// Long enough for several short ticks to have fired had the chain still been
// running at the short period, and well under the long one.
const quiet_window_ms = 400

fn boot(
  provider: fn(effects.RequestSpec) -> fake.ProviderResult,
) -> #(Session, api.Runtime, Subject(recorder.Message)) {
  let rec = recorder.start()
  let assert Ok(sess) =
    session.open_memory(clock.stepping(from: 1_000_000, by: 7))
    as "the memory session must open"
  let base =
    fake.effects(
      rec,
      clock.stepping(from: 2_000_000, by: 25),
      [],
      provider,
      fn(_run) {
        fake.ToolReply(text: "unused", is_error: False, terminate: False)
      },
    )
  let eff = effects.Effects(..base, timers: counted_timers(rec))
  let options =
    api.Options(
      ..api.default_options(harness.configuration()),
      poll_interval_ms: short_poll_ms,
      idle_poll_interval_ms: long_poll_ms,
      tolerance: supervisor.Tolerance(intensity: 10_000, period: 10),
    )
  let assert Ok(rt) = api.open(sess, eff, options)
    as "the session tree must boot"
  #(sess, rt, rec)
}

// The real timer seam with a counter in front of it. Every arm still fires,
// because these tests are about which period the strand chose and not about
// withholding its wakes.
fn counted_timers(rec: Subject(recorder.Message)) -> effects.Timers {
  let real = effects.real_timers()
  effects.Timers(after: fn(delay_ms, wake) {
    let _counted = case delay_ms {
      delay if delay == short_poll_ms -> recorder.bump(rec, "poll.short")
      delay if delay == long_poll_ms -> recorder.bump(rec, "poll.long")
      _ -> 0
    }
    real.after(delay_ms, wake)
  })
}

fn answers_once(spec: effects.RequestSpec) -> fake.ProviderResult {
  case fake.turn(spec) {
    0 -> fake.Reply(fake.answer("Done", 3))
    _ -> fake.Reply(fake.answer("Done again", 3))
  }
}

/// A strand that has finished its turn stops arming short ticks and arms the
/// long one instead. This is the whole memory result: the mailbox falls quiet,
/// so the residency interval can expire and the strand can shed its heap.
pub fn a_finished_strand_stops_ticking_at_the_short_period_test() {
  let #(_sess, rt, rec) = boot(answers_once)
  let assert Ok(op) = api.prompt(rt, [fake.user("Hello")]) as "prompt accepted"
  let assert Ok(outcome) = api.await_result(rt, op, within_ms: 5000)
    as "the run must complete"
  harness.assert_completed(outcome)

  // One short tick after the run settles is expected and is the tick that
  // discovers the strand is idle; from there the chain must be the long one.
  wait_for(fn() { recorder.read(rec, "poll.long") >= 1 }, 3000)
  let settled = recorder.read(rec, "poll.short")
  process.sleep(quiet_window_ms)

  // At the short period this window would have armed ten more.
  assert recorder.read(rec, "poll.short") == settled
  process.kill(rt.tree.supervisor)
}

/// A second turn admitted while the strand is idle does not start a tick
/// chain beside the pending one. The chain replaces itself and nothing else
/// joins it, so the count of armed ticks over a whole second turn stays at
/// what one chain produces: were a message to arm as well, each chain would
/// go on arming its own successor and the count would run at two rates.
pub fn a_second_turn_does_not_start_a_second_tick_chain_test() {
  let #(_sess, rt, rec) = boot(answers_once)
  let assert Ok(first) = api.prompt(rt, [fake.user("Hello")])
    as "the first prompt must be accepted"
  let assert Ok(_settled) = api.await_result(rt, first, within_ms: 5000)
    as "the first run must complete"
  wait_for(fn() { recorder.read(rec, "poll.long") >= 1 }, 3000)

  // A second turn, whose doorbell arrives while the pending tick is the long
  // one. It drives on the doorbell, and the pending tick is left alone.
  let armed_before = recorder.read(rec, "poll.short")
  let assert Ok(second) = api.prompt(rt, [fake.user("Again")])
    as "the second prompt must be accepted"
  let assert Ok(_settled) = api.await_result(rt, second, within_ms: 5000)
    as "the second run must complete"
  assert recorder.read(rec, "poll.short") == armed_before

  // The pending long tick is what discovers the second turn and puts the
  // chain back onto the short period, and quiet puts it back onto the long
  // one. One chain throughout: the short count holds still once idle.
  wait_for(fn() { recorder.read(rec, "poll.long") >= 2 }, 3 * long_poll_ms)
  let settled = recorder.read(rec, "poll.short")
  process.sleep(quiet_window_ms)
  assert recorder.read(rec, "poll.short") == settled
  process.kill(rt.tree.supervisor)
}

/// A doorbell wakes a strand whose only pending tick is minutes away. Every
/// test here that completes a run from idle proves this, because the long
/// period outlasts every deadline in the file; this one states it directly by
/// admitting the work with the doorbell and nothing else.
pub fn a_doorbell_wakes_a_strand_on_the_long_period_test() {
  let #(_sess, rt, rec) = boot(answers_once)
  let assert Ok(first) = api.prompt(rt, [fake.user("Hello")])
    as "the first prompt must be accepted"
  let assert Ok(_settled) = api.await_result(rt, first, within_ms: 5000)
    as "the first run must complete"
  wait_for(fn() { recorder.read(rec, "poll.long") >= 1 }, 3000)

  // The pending tick is now `long_poll_ms` away, which is longer than this
  // deadline. The run can only start because the prompt rang the doorbell.
  let assert Ok(second) = api.prompt(rt, [fake.user("Again")])
    as "the second prompt must be accepted"
  let assert Ok(outcome) = api.await_result(rt, second, within_ms: 1500)
    as "the doorbell must wake the idle strand"
  harness.assert_completed(outcome)
  process.kill(rt.tree.supervisor)
}

/// The quiet acceptance an operator's own tooling never rings for: the run is
/// durable and nothing woke the strand, so only the idle tick can find it. The
/// backstop is kept at the long period rather than dropped, which is what
/// keeps a doorbell lost between a commit and its nudge costing latency
/// instead of the work.
pub fn a_quiet_acceptance_is_still_polled_up_test() {
  let #(_sess, rt, _rec) = boot(answers_once)
  let assert Ok(op) = api.accept_quietly(rt, [fake.user("Hello")])
    as "the quiet acceptance must succeed"
  let assert Ok(outcome) =
    api.await_result(rt, op, within_ms: long_poll_ms + 5000)
    as "the idle checkpoint tick must find the accepted run"
  harness.assert_completed(outcome)
  process.kill(rt.tree.supervisor)
}

/// A strand that reboots with nothing to do goes straight to the long period.
/// Recovery drives before it arms anything, which is what lets a restart read
/// the period out of durable state rather than spending a turn's worth of
/// ticks discovering it — and what keeps the short period for the restart that
/// matters, the one restoring an operation that was open when it died.
pub fn a_restarted_idle_strand_arms_the_long_period_test() {
  let #(_sess, rt, rec) = boot(answers_once)
  let assert Ok(op) = api.prompt(rt, [fake.user("Hello")]) as "prompt accepted"
  let assert Ok(_settled) = api.await_result(rt, op, within_ms: 5000)
    as "the run must complete"
  wait_for(fn() { recorder.read(rec, "poll.long") >= 1 }, 3000)

  let long_before = recorder.read(rec, "poll.long")
  let short_before = recorder.read(rec, "poll.short")
  let assert Ok(subject) = supervisor.strand_subject(rt.tree, "main")
    as "the strand driver must be registered"
  let assert Ok(pid) = process.subject_owner(subject)
    as "the strand driver must be alive"
  process.kill(pid)

  // The replacement's recovery drive finds no open operation, so the one tick
  // it arms is the idle one and no short tick is ever armed.
  wait_for(fn() { recorder.read(rec, "poll.long") > long_before }, 5000)
  assert recorder.read(rec, "poll.long") > long_before
  assert recorder.read(rec, "poll.short") == short_before
  process.kill(rt.tree.supervisor)
}

/// The two periods are only useful together if the long one clears the
/// residency interval, because hibernation is a receive timeout and a mailbox
/// woken inside it never sleeps. Production's own numbers are asserted here
/// rather than argued in a comment.
pub fn the_default_idle_period_outlasts_the_residency_interval_test() {
  let options = api.default_options(harness.configuration())
  assert options.idle_poll_interval_ms > residency.hibernate_after_ms
  assert options.poll_interval_ms < residency.hibernate_after_ms
}

// Polls `ready` until it holds or the deadline passes. A test that depends on
// the answer asserts it afterwards; this only bounds the wait.
fn wait_for(ready: fn() -> Bool, deadline_ms: Int) -> Nil {
  case ready(), deadline_ms <= 0 {
    True, _ -> Nil
    False, True -> Nil
    False, False -> {
      process.sleep(10)
      wait_for(ready, deadline_ms - 10)
    }
  }
}
