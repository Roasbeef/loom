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

// The idle period the occupied-chain test boots with. That test watches a
// chain run at the short period across an idle tick's own deadline, so the
// deadline has to land inside the block the provider holds; `long_poll_ms`
// would outlast it. It is still far longer than the short period, which is
// the only other relation the test depends on.
const brief_idle_poll_ms = 431

// How long the occupied-chain test's provider blocks before it answers. It
// must outlast `brief_idle_poll_ms` plus the window that test samples the
// short chain over, because the assertion is about ticks that fire while the
// operation is still open.
const occupied_block_ms = 1500

// The window the occupied-chain test samples the short chain over. Several
// short periods, and short enough that `occupied_block_ms` still has room
// left when it ends.
const occupied_sample_ms = 200

fn boot(
  provider: fn(effects.RequestSpec) -> fake.ProviderResult,
) -> #(Session, api.Runtime, Subject(recorder.Message)) {
  boot_with(provider, long_poll_ms)
}

// Boots a tree whose idle period is the caller's. Only the occupied-chain
// test needs anything other than `long_poll_ms`, and it needs the counter to
// key on the period it actually asked for, which is why the delay travels to
// `counted_timers` rather than being read from a constant there.
fn boot_with(
  provider: fn(effects.RequestSpec) -> fake.ProviderResult,
  idle_poll_ms: Int,
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
  let eff = effects.Effects(..base, timers: counted_timers(rec, idle_poll_ms))
  let options =
    api.Options(
      ..api.default_options(harness.configuration()),
      poll_interval_ms: short_poll_ms,
      idle_poll_interval_ms: idle_poll_ms,
      tolerance: supervisor.Tolerance(intensity: 10_000, period: 10),
    )
  let assert Ok(rt) = api.open(sess, eff, options)
    as "the session tree must boot"
  #(sess, rt, rec)
}

// The real timer seam with a counter in front of it. Every arm still fires,
// because these tests are about which period the strand chose and not about
// withholding its wakes.
fn counted_timers(
  rec: Subject(recorder.Message),
  idle_poll_ms: Int,
) -> effects.Timers {
  let real = effects.real_timers()
  effects.Timers(after: fn(delay_ms, wake) {
    let _counted = case delay_ms {
      delay if delay == short_poll_ms -> recorder.bump(rec, "poll.short")
      delay if delay == idle_poll_ms -> recorder.bump(rec, "poll.long")
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

  // The long tick this waits for is the one boot's own recovery drive armed:
  // it found nothing to do, so the chain was on the long period before the
  // prompt arrived and the whole run happened inside that one period. No tick
  // fired, so the count of short arms here is zero rather than one.
  wait_for(fn() { recorder.read(rec, "poll.long") >= 1 }, 3000)
  assert recorder.read(rec, "poll.long") >= 1
  let settled = recorder.read(rec, "poll.short")
  process.sleep(quiet_window_ms)

  // At the short period this window would have armed ten more.
  assert recorder.read(rec, "poll.short") == settled
  process.kill(rt.tree.supervisor)
}

// A provider whose first generation holds the operation open for
// `occupied_block_ms` before it answers. The sleep runs in the spawned effect
// process, so the driver keeps handling ticks throughout it, which is the
// whole point: a tick has to fire while an operation is open.
fn answers_slowly(spec: effects.RequestSpec) -> fake.ProviderResult {
  case fake.turn(spec) {
    0 -> {
      process.sleep(occupied_block_ms)
      fake.Reply(fake.answer("Done", 3))
    }
    _ -> fake.Reply(fake.answer("Done again", 3))
  }
}

/// A tick that fires while an operation is open arms the short period, and
/// keeps arming it for as long as the operation stays open. This is the other
/// half of the two-period rule, and the half a run that finishes inside one
/// idle period never reaches: the deferred-permit rate is only the short one
/// if an occupied drive says so.
pub fn a_tick_over_an_open_operation_stays_short_test() {
  let #(_sess, rt, rec) = boot_with(answers_slowly, brief_idle_poll_ms)
  let assert Ok(op) = api.prompt(rt, [fake.user("Hello")]) as "prompt accepted"

  // The doorbell drove the strand to `Occupied`, and that drive armed the
  // short period as part of handling it — well inside the idle deadline that
  // was pending when the prompt arrived.
  wait_for(fn() { recorder.read(rec, "poll.short") >= 1 }, 3000)
  assert recorder.read(rec, "poll.short") >= 1

  // While the operation stays open the chain must keep choosing the short
  // period. One further arm is enough to say the chain did not fall back:
  // this window is several short periods wide and well inside the block.
  let occupied = recorder.read(rec, "poll.short")
  process.sleep(occupied_sample_ms)
  assert recorder.read(rec, "poll.short") > occupied

  // And the run settling puts it back: the first tick after the operation
  // closes finds the strand idle and arms the long period, after which the
  // short count holds still.
  let assert Ok(outcome) = api.await_result(rt, op, within_ms: 5000)
    as "the slow run must complete"
  harness.assert_completed(outcome)
  wait_for(fn() { recorder.read(rec, "poll.long") >= 2 }, 3000)
  assert recorder.read(rec, "poll.long") >= 2
  let settled = recorder.read(rec, "poll.short")
  process.sleep(quiet_window_ms)
  assert recorder.read(rec, "poll.short") == settled
  process.kill(rt.tree.supervisor)
}

/// A strand that restarts with an operation still open arms the short period,
/// not the idle one. Recovery drives before it arms, so the replacement reads
/// its period out of durable state; this is the restart that period is for,
/// and it is the one a restart-while-idle test cannot distinguish.
pub fn a_restart_with_an_open_operation_arms_the_short_period_test() {
  let #(_sess, rt, rec) = boot(fn(_spec) { fake.Hang })
  let assert Ok(_op) = api.prompt(rt, [fake.user("Hello")]) as "prompt accepted"
  wait_for(fn() { recorder.read(rec, "provider") >= 1 }, 3000)
  assert recorder.read(rec, "provider") >= 1

  // The prompt's own drive armed the short period and that chain has been
  // running ever since, so the count is not zero and what the replacement is
  // measured against is this snapshot rather than nothing. The chain dies with
  // the process it belongs to: `wake` drops a tick whose driver is gone, so
  // every arm counted past this point belongs to the replacement.
  let short_before_kill = recorder.read(rec, "poll.short")
  let assert Ok(subject) = supervisor.strand_subject(rt.tree, "main")
    as "the strand driver must be registered"
  let assert Ok(pid) = process.subject_owner(subject)
    as "the strand driver must be alive"
  process.kill(pid)

  // The replacement's recovery drive loads the operation the provider is
  // still hanging on, so the one tick it arms is the short one, and that
  // chain goes on arming while the operation stays open. The deadline is far
  // under `long_poll_ms` on purpose: a replacement that armed the idle period
  // instead would reach the short one eventually, once that idle tick fired
  // over the still-open operation, and a deadline past it would pass on the
  // recovery this test exists to distinguish.
  wait_for(
    fn() { recorder.read(rec, "poll.short") >= short_before_kill + 3 },
    1200,
  )
  assert recorder.read(rec, "poll.short") >= short_before_kill + 3
  process.kill(rt.tree.supervisor)
}

/// A second turn admitted while the strand is idle arms the short period at
/// once, and leaves one live chain behind rather than two.
///
/// Both halves are the claim. The arming is what makes the short period
/// reachable: a turn is shorter than the idle period, so a strand that had to
/// wait for the pending idle tick before its period could change would run
/// the whole turn without a short tick. The single chain is what the
/// generation stamp buys: the superseded idle tick still fires, and were it
/// to drive and arm a successor of its own the strand would tick at two
/// rates, which the quiet window at the end would see.
pub fn a_second_turn_does_not_start_a_second_tick_chain_test() {
  let #(_sess, rt, rec) = boot(answers_once)
  let assert Ok(first) = api.prompt(rt, [fake.user("Hello")])
    as "the first prompt must be accepted"
  let assert Ok(_settled) = api.await_result(rt, first, within_ms: 5000)
    as "the first run must complete"
  wait_for(fn() { recorder.read(rec, "poll.long") >= 1 }, 3000)
  assert recorder.read(rec, "poll.long") >= 1

  // A second turn, whose doorbell arrives while the pending tick is the long
  // one. The drive it causes finds the operation open and arms the short
  // period there and then, rather than inheriting the idle deadline.
  let armed_before = recorder.read(rec, "poll.short")
  let assert Ok(second) = api.prompt(rt, [fake.user("Again")])
    as "the second prompt must be accepted"
  let assert Ok(_settled) = api.await_result(rt, second, within_ms: 5000)
    as "the second run must complete"
  assert recorder.read(rec, "poll.short") > armed_before

  // The run settled, so the drive that settled it armed the long period again
  // and the strand is back on one long chain. The superseded idle tick from
  // before the turn arrives somewhere in here and is dropped: were it instead
  // to drive and arm, the two chains would keep arming and neither count
  // would hold still.
  wait_for(fn() { recorder.read(rec, "poll.long") >= 2 }, 3 * long_poll_ms)
  assert recorder.read(rec, "poll.long") >= 2
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
  assert recorder.read(rec, "poll.long") >= 1

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

/// A strand that becomes occupied arms the short period at once, rather than
/// waiting out the idle tick that was pending when the work arrived.
///
/// This is the property the two periods need and the one a run that finishes
/// inside a single idle period cannot show. The idle period here is
/// `long_poll_ms` and the deadline is a fraction of it, so a strand that had
/// inherited the pending idle deadline would have armed nothing short by the
/// time this gives up.
///
/// What waits on it in production is a quiet admission onto an open run —
/// `api.steer_marking`, the door a harness-side injector uses because its
/// claim and its admission must land in one transaction — and a deferred
/// suspension's next permit. Both are found by a tick and nothing else, and
/// both would otherwise have waited the idle period out: two minutes on
/// production's defaults, for a turn that will be over long before then.
pub fn an_occupied_strand_arms_the_short_period_without_waiting_test() {
  let #(_sess, rt, rec) = boot(fn(_spec) { fake.Hang })
  let assert Ok(_op) = api.prompt(rt, [fake.user("Hello")]) as "prompt accepted"

  // Three arms rather than one, so the assertion is about a chain running at
  // the short period and not about a single arm that happened to land.
  wait_for(fn() { recorder.read(rec, "poll.short") >= 3 }, long_poll_ms / 4)
  assert recorder.read(rec, "poll.short") >= 3

  // That the superseded idle tick leaves no second chain behind is
  // `a_second_turn_does_not_start_a_second_tick_chain_test`'s claim, whose
  // window is wide enough to see that tick arrive; this deadline is not.
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
  assert recorder.read(rec, "poll.long") >= 1

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
