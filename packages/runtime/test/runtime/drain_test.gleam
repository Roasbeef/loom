//// The graceful daemon drain (issue #392): a running turn is not lost.
////
//// The load-bearing clause is that a drain leaves an `Aborted` terminal for
//// the turn that was in flight, rather than the turn simply vanishing when
//// the tree is torn down. `runtime/api.drain` requests an abort on every
//// live strand and waits for the terminals inside one shared budget; this
//// fixture proves the first half by parking a provider, draining, and
//// reading the terminal back.

import core/clock
import gleam/erlang/process
import runtime/api
import session/session
import support/fake
import support/harness
import support/recorder

// A turn whose provider never settles: the strand is parked mid-generation,
/// which is exactly the state a daemon drain must resolve rather than drop.
fn parked_effects(rec) {
  fake.effects(
    rec,
    clock.stepping(from: 2_000_000, by: 25),
    [],
    fn(_spec) { fake.Hang },
    fn(_run) {
      fake.ToolReply(text: "unused", is_error: False, terminate: False)
    },
  )
}

pub fn a_drain_aborts_the_in_flight_turn_test() {
  let rec = recorder.start()
  let assert Ok(sess) =
    session.open_memory(clock.stepping(from: 1_000_000, by: 7))
    as "the memory session must open"
  let assert Ok(rt) =
    api.open(
      sess,
      parked_effects(rec),
      api.default_options(harness.configuration()),
    )
    as "the session tree must boot"

  let assert Ok(op) =
    api.accept_quietly(rt, [fake.user("work that will be interrupted")])
    as "acceptance must succeed"

  // The drain requests the abort and then waits for the terminal inside its
  // own budget. That it returns at all under a *parked* provider is the
  // proof that it did not merely drop the turn.
  api.drain(rt, within_ms: 10_000)

  let assert Ok(last) = api.await_result(rt, op, within_ms: 10_000)
    as "the drained turn must reach a terminal result"
  harness.assert_aborted(last)

  process.kill(rt.tree.supervisor)
}

pub fn a_drain_with_nothing_running_returns_promptly_test() {
  let rec = recorder.start()
  let assert Ok(sess) =
    session.open_memory(clock.stepping(from: 1_000_000, by: 7))
    as "the memory session must open"
  let assert Ok(rt) =
    api.open(
      sess,
      parked_effects(rec),
      api.default_options(harness.configuration()),
    )
    as "the session tree must boot"

  // No strand is running anything, so the drain has no terminal to await and
  // must not spend its budget: the shared deadline is only consumed by
  // strands that were observed with a live operation.
  api.drain(rt, within_ms: 10_000)

  process.kill(rt.tree.supervisor)
}
