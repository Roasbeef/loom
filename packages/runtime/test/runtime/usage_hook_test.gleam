//// The `usage` hook: one notification per committed cost-ledger row,
//// fired from the driver's own commit path.
////
//// The property worth pinning is the position rather than the payload.
//// The slot is called after `writer.commit` has returned, so the row it
//// is handed is durable and carries the seq storage assigned rather
//// than the placeholder the machine built it with. A test that only
//// asserted on the token counts would pass against a notification made
//// *before* the commit, which is the one arrangement that would let a
//// tracing extension report a cost the session never paid.

import core/clock
import core/entry
import gleam/erlang/process.{type Subject}
import gleam/list
import runtime/api
import runtime/effects
import session/session
import support/fake
import support/harness
import support/recorder

pub fn a_committed_usage_row_is_announced_once_test() {
  let seen: Subject(#(Int, Int)) = process.new_subject()
  let assert Ok(#(runtime, opened)) = driven(seen)
    as "the session tree must boot"
  let assert Ok(op) = api.accept_quietly(runtime, [fake.user("work")])
    as "acceptance must succeed"
  api.nudge(runtime)
  let assert Ok(_last) = api.await_result(runtime, op, within_ms: 10_000)
    as "the run must settle"

  // One turn, one provider report, one ledger row, one notification —
  // and the ledger agrees with what the hook was told.
  let announced = drain(seen, [])
  assert list.map(announced, fn(pair) { pair.1 }) == [7]
  assert harness.ledger_total(opened) == 7

  // The seq is storage's, not the placeholder zero the machine builds a
  // row with. That is the whole argument for announcing after the
  // commit rather than before it.
  assert list.all(announced, fn(pair) { pair.0 > 0 })
  process.kill(runtime.tree.supervisor)
}

// A session whose `usage` slot reports every row's seq and total to the
// test, with everything else the ordinary scripted fake.
fn driven(
  seen: Subject(#(Int, Int)),
) -> Result(#(api.Runtime, session.Session), String) {
  let rec = recorder.start()
  let assert Ok(opened) =
    session.open_memory(clock.stepping(from: 1_000_000, by: 7))
    as "the memory session must open"
  let scripted =
    fake.effects(
      rec,
      clock.stepping(from: 2_000_000, by: 25),
      [],
      fn(_spec) { fake.Reply(fake.answer("the full answer", 7)) },
      fn(_run) {
        fake.ToolReply(text: "unused", is_error: False, terminate: False)
      },
    )
  let watched =
    effects.Effects(
      ..scripted,
      hooks: effects.Hooks(
        ..scripted.hooks,
        usage: fn(_operation, row: entry.UsageRow) {
          process.send(seen, #(row.seq, row.usage.total_tokens))
        },
      ),
    )
  case api.open(opened, watched, api.default_options(harness.configuration())) {
    Ok(runtime) -> Ok(#(runtime, opened))
    Error(_reason) -> Error("the tree did not open")
  }
}

fn drain(seen: Subject(answer), collected: List(answer)) -> List(answer) {
  case process.receive(seen, within: 0) {
    Ok(answer) -> drain(seen, [answer, ..collected])
    Error(Nil) -> list.reverse(collected)
  }
}
