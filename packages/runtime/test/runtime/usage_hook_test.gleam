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

import core/accounting
import core/clock
import core/entry
import core/message
import core/usage_evidence
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import provider/stream
import runtime/api
import runtime/effects
import session/session
import storage/storage
import support/fake
import support/harness
import support/recorder

pub fn a_committed_usage_row_is_announced_once_test() {
  let seen: Subject(#(Int, Int)) = process.new_subject()
  let assert Ok(#(runtime, opened)) =
    driven(seen, fake.Reply(fake.answer("the full answer", 7)))
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
  outcome: fake.ProviderResult,
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
      fn(_spec) { outcome },
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

pub fn fallback_request_announces_one_total_but_preserves_final_context_test() {
  let seen: Subject(#(Int, Int)) = process.new_subject()
  let final = fake.answer("final", 7)
  let report =
    accounting.from_usage(fake.usage(11)) |> accounting.append(fake.usage(7))
  let assert Ok(#(runtime, opened)) =
    driven(seen, fake.ReplyAccounted(final, report))
    as "The session tree must boot."
  let assert Ok(op) = api.accept_quietly(runtime, [fake.user("work")])
    as "The run must be accepted."
  api.nudge(runtime)
  let assert Ok(_last) = api.await_result(runtime, op, within_ms: 10_000)
    as "The fallback request must settle."
  let assert Ok(rows) = storage.scan_usage(opened.store, storage.usage_scan())
    as "The durable ledger must be readable."
  let assert [row] = rows
    as "Fallback attempts must produce one logical request row."
  assert accounting.decode_row(row) == Ok(report)
  assert list.map(drain(seen, []), fn(pair) { pair.1 }) == [18]
  let assert Ok(entries) =
    storage.scan_entries(opened.store, storage.entry_scan())
    as "The final context must be readable."
  let assistants =
    list.filter_map(entries, fn(value) {
      case value {
        entry.MessageEntry(
          message: message.AssistantMessage(..) as assistant,
          ..,
        ) -> Ok(assistant)
        entry.MessageEntry(..)
        | entry.CompactionEntry(..)
        | entry.BranchSummaryEntry(..)
        | entry.CustomEntry(..) -> Error(Nil)
      }
    })
  assert assistants == [final]
  process.kill(runtime.tree.supervisor)
}

pub fn failed_request_retains_known_consumption_and_unknown_final_attempt_test() {
  let seen: Subject(#(Int, Int)) = process.new_subject()
  let uncertain = accounting.unknown_usage(usage_evidence.Other)
  let report =
    accounting.from_usage(fake.usage(11)) |> accounting.append(uncertain)
  let error = stream.HttpError(400, "invalid_request_error", "failed", None)
  let assert Ok(#(runtime, opened)) =
    driven(seen, fake.RefuseAccounted(error, report))
    as "The session tree must boot."
  let assert Ok(op) = api.accept_quietly(runtime, [fake.user("work")])
    as "The run must be accepted."
  api.nudge(runtime)
  let assert Ok(_last) = api.await_result(runtime, op, within_ms: 10_000)
    as "The failure must drain normally."
  let assert Ok(rows) = storage.scan_usage(opened.store, storage.usage_scan())
    as "The durable ledger must be readable."
  let assert [row] = rows
    as "A failed fallback request must produce one logical row."
  assert accounting.decode_row(row) == Ok(report)
  assert list.map(drain(seen, []), fn(pair) { pair.1 }) == [11]
  assert row.usage.evidence
    == usage_evidence.with_price(
      usage_evidence.partial(usage_evidence.Other),
      usage_evidence.ApiRates,
    )
  let synthetic =
    effects.settle_failure(error, harness.configuration(), 0, report)
  let assert message.AssistantMessage(usage:, ..) = synthetic
    as "Failure conversion must preserve the final attempt."
  assert usage == uncertain
  assert accounting.last(report) == Some(usage)
  let assert Ok(entries) =
    storage.scan_entries(opened.store, storage.entry_scan())
    as "The durable failure must be readable."
  let assistants =
    list.filter_map(entries, fn(value) {
      case value {
        entry.MessageEntry(message: message.AssistantMessage(usage:, ..), ..) ->
          Ok(usage)
        entry.MessageEntry(..)
        | entry.CompactionEntry(..)
        | entry.BranchSummaryEntry(..)
        | entry.CustomEntry(..) -> Error(Nil)
      }
    })
  assert assistants == [uncertain]
  process.kill(runtime.tree.supervisor)
}

fn drain(seen: Subject(answer), collected: List(answer)) -> List(answer) {
  case process.receive(seen, within: 0) {
    Ok(answer) -> drain(seen, [answer, ..collected])
    Error(Nil) -> list.reverse(collected)
  }
}
