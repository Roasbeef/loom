//// Structural reloads reuse the payload already returned by their listing.
//// The counted storage boundary proves that a large preparation reaches the
//// summary provider and is cleaned up without a second point-read transfer.

import core/clock
import core/register
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/string
import machine/operation.{
  BranchSummaryPreparation, FileOperations, NavigationLastResult,
  StructuralCompleted,
}
import machine/planner
import runtime/api
import runtime/effects
import session/session
import storage/storage
import support/fake
import support/harness
import support/recorder

pub fn preparation_listing_supplies_the_summary_without_rereading_test() {
  let rec = recorder.start()
  let seen = process.new_subject()
  let assert Ok(original) = session.open_memory(clock.fixed(1000))
    as "the synthetic session opens"
  let get_register = original.store.get_register
  let list_registers = original.store.list_registers
  let store =
    storage.Storage(
      ..original.store,
      get_register: fn(handle, ns, key) {
        case ns {
          register.OpPreparation -> {
            let _ = recorder.bump(rec, "preparation-point-reads")
            get_register(handle, ns, key)
          }
          _ -> get_register(handle, ns, key)
        }
      },
      list_registers: fn(handle, ns, prefix) {
        case ns {
          register.OpPreparation -> {
            let _ = recorder.bump(rec, "preparation-list-reads")
            list_registers(handle, ns, prefix)
          }
          _ -> list_registers(handle, ns, prefix)
        }
      },
    )
  let sess = session.Session(..original, store:)
  let preparation =
    BranchSummaryPreparation(
      messages: [fake.user(string.repeat("synthetic \"line\"\n", 20_000))],
      file_ops: FileOperations(read: [], written: [], edited: []),
      total_tokens: 10,
    )
  let base =
    fake.effects(
      rec,
      clock.stepping(from: 2_000_000, by: 25),
      [],
      fn(spec) {
        case spec {
          effects.SummaryRequest(preparation: supplied, ..) ->
            process.send(seen, supplied)
          effects.GenerationRequest(..) | effects.PollRequest(..) -> Nil
        }
        fake.Reply(fake.answer("summary", 3))
      },
      fn(_) { fake.ToolReply("unused", False, False) },
    )
  let eff =
    effects.Effects(
      ..base,
      hooks: effects.Hooks(..base.hooks, structural_decision: fn(_, _) {
        planner.VerdictGenerate
      }),
    )
  let assert Ok(rt) =
    api.open(sess, eff, api.default_options(harness.configuration()))
    as "the runtime opens against the counted store"
  let assert Ok(seed) = api.prompt(rt, [fake.user("seed")])
    as "the initial run gives navigation a leaf to leave"
  let assert Ok(seed_outcome) = api.await_result(rt, seed, within_ms: 5000)
    as "the initial run completes"
  harness.assert_completed(seed_outcome)
  let assert Ok(Some(session.Cell(value: target, ..))) =
    session.strand_leaf(sess, "main")
    as "the first run leaves a durable navigation target"
  let assert Ok(second) = api.prompt(rt, [fake.user("second")])
    as "another run moves away from the target"
  let assert Ok(second_outcome) = api.await_result(rt, second, within_ms: 5000)
    as "the second run completes"
  harness.assert_completed(second_outcome)
  let assert Ok(op) =
    api.navigate(
      rt,
      to: target,
      summarize: True,
      label: None,
      custom_instructions: None,
      preparation: Some(preparation),
    )
    as "navigation admits the frozen summary input"
  let outcome = api.await_result(rt, op, within_ms: 5000)
  let supplied = process.receive(seen, within: 1000)
  let points = recorder.read(rec, "preparation-point-reads")
  let listings = recorder.read(rec, "preparation-list-reads")
  let remaining =
    storage.list_registers(original.store, register.OpPreparation, None)
  let closed = api.close(rt)

  // Check after draining so a regression cannot leave the fixture running.
  assert closed == Ok(Nil)
  let assert Ok(NavigationLastResult(outcome: StructuralCompleted, ..)) =
    outcome
    as "the supplied preparation completes its structural operation"
  assert supplied == Ok(Some(preparation))
  assert listings > 0
  assert points == 0
  assert remaining == Ok([])
}
