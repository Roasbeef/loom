//// A stop request names its observed operation across mailbox delay. The
//// successor is admitted quietly so the stale abort reaches its driver before
//// the successor's doorbell, without depending on scheduling or sleeps.

import core/clock
import gleam/erlang/process
import machine/operation
import runtime/api
import session/session
import support/fake
import support/harness
import support/recorder

pub fn stale_abort_cannot_cancel_the_next_queued_turn_test() {
  let rec = recorder.start()
  let assert Ok(sess) =
    session.open_memory(clock.stepping(from: 1_000_000, by: 7))
    as "the memory session must open"
  let eff =
    fake.effects(
      rec,
      clock.stepping(from: 2_000_000, by: 25),
      [],
      fn(_spec) { fake.Reply(fake.answer("complete", 7)) },
      fn(_run) {
        fake.ToolReply(text: "unused", is_error: False, terminate: False)
      },
    )
  let options =
    api.Options(
      ..api.default_options(harness.configuration()),
      poll_interval_ms: 600_000,
    )
  let assert Ok(rt) = api.open(sess, eff, options)
    as "the session tree must boot"
  let assert Ok(first) = api.prompt(rt, [fake.user("first")])
    as "the first operation must be accepted"
  let assert Ok(_) = api.await_result(rt, first, within_ms: 5000)
    as "the first operation must finish before its delayed stop arrives"

  // Both messages originate here and resolve to the same driver. The old
  // cancellation is therefore consumed before the new operation's nudge.
  let assert Ok(second) = api.accept_quietly(rt, [fake.user("second")])
    as "the queued successor must be admitted"
  api.abort_operation(rt, first)
  api.nudge(rt)
  let assert Ok(operation.RunLastResult(outcome: operation.RunCompleted(..), ..)) =
    api.await_result(rt, second, within_ms: 5000)
    as "a delayed stop must leave the successor free to finish"
  assert recorder.read(rec, "provider") == 2
    as "both operations must reach their provider"
  process.kill(rt.tree.supervisor)
}
