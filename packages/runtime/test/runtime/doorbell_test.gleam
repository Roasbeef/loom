//// Doorbell-drop tests: an admission committed without a nudge is still
//// picked up — the strand's periodic checkpoint poll finds the durable
//// work. A lost doorbell costs latency, never data (design §4.6).

import core/clock
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/string
import runtime/api
import runtime/effects
import runtime/supervisor
import session/session.{type Session}
import support/fake
import support/harness
import support/recorder

fn boot(
  provider: fn(effects.RequestSpec) -> fake.ProviderResult,
) -> #(Session, api.Runtime, Subject(recorder.Message)) {
  let rec = recorder.start()
  let assert Ok(sess) =
    session.open_memory(clock.stepping(from: 1_000_000, by: 7))
    as "the memory session must open"
  let eff =
    fake.effects(
      rec,
      clock.stepping(from: 2_000_000, by: 25),
      [],
      provider,
      fn(_run) {
        fake.ToolReply(text: "unused", is_error: False, terminate: False)
      },
    )
  let base = api.default_options(harness.configuration())
  let options =
    api.Options(
      ..base,
      poll_interval_ms: 40,
      tolerance: supervisor.Tolerance(intensity: 100, period: 10),
    )
  let assert Ok(rt) = api.open(sess, eff, options)
    as "the session tree must boot"
  #(sess, rt, rec)
}

pub fn accept_without_nudge_is_polled_up_test() {
  let #(_sess, rt, _rec) =
    boot(fn(spec) {
      case fake.turn(spec) {
        0 -> fake.Reply(fake.answer("Polled", 3))
        _ -> fake.Reply(fake.answer("unexpected", 1))
      }
    })
  let assert Ok(op) = api.accept_quietly(rt, [fake.user("Hello")])
    as "acceptance must succeed"
  // No nudge: only the checkpoint poll can find the accepted run.
  let assert Ok(outcome) = api.await_result(rt, op, within_ms: 3000)
    as "the poll tick must pick the accepted run up"
  harness.assert_completed(outcome)
  process.kill(rt.tree.supervisor)
}

pub fn steer_without_nudge_is_drained_test() {
  let #(sess, rt, _rec) =
    boot(fn(spec) {
      case fake.turn(spec) {
        0 -> fake.Reply(fake.answer("Saw the steer", 3))
        _ -> fake.Reply(fake.answer("unexpected", 1))
      }
    })
  let assert Ok(op) = api.accept_quietly(rt, [fake.user("Hello")])
    as "acceptance must succeed"
  let assert Ok(_entry) = api.steer_quietly(rt, fake.user("And this"))
    as "steer admission must succeed"
  // No nudge for either commit.
  let assert Ok(outcome) = api.await_result(rt, op, within_ms: 3000)
    as "the poll tick must pick the run and its steer up"
  harness.assert_completed(outcome)
  let projection = harness.final_projection(sess)
  assert list.any(projection, fn(line) {
    string.starts_with(line, "user:And this")
  })
  process.kill(rt.tree.supervisor)
}
