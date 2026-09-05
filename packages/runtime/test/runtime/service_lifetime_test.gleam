//// A long-lived host must reclaim runtime routing after each closed session.
////
//// These cycles use the real runtime, writer, factories and strand driver.
//// Each session completes a scripted turn before closing, so the measured
//// lifetime includes execution rather than only allocation of empty handles.

import core/clock
import core/register
import core/tx
import gleam/erlang/process
import gleam/int
import runtime/api
import runtime/effects
import runtime/supervisor
import runtime/writer
import session/session
import support/fake
import support/harness
import support/recorder
import weft/registry as address

type Counter {
  AtomCount
}

@external(erlang, "erlang", "system_info")
fn system_count(counter: Counter) -> Int

pub fn unavailable_writer_is_retryable_before_admission_test() {
  let rec = recorder.start()
  let effects =
    fake.effects(
      rec,
      clock.fixed(at: 1_000_000),
      [],
      fn(_spec) { fake.Reply(fake.answer("finished", 1)) },
      fn(_run) { fake.ToolReply("unused", False, False) },
    )
  let assert Ok(session) = session.open_memory(clock.fixed(at: 1_000_000))
    as "the memory session must open"
  let assert Ok(runtime) =
    api.open(session, effects, api.default_options(harness.configuration()))
    as "the runtime must open"

  // An unbound address represents the exact gap between writer incarnations,
  // without racing the supervisor's restart speed. The real runtime remains
  // healthy so the same admission can then prove that nothing was enqueued.
  let absent = address.new_address(runtime.tree.namespace)
  let unavailable =
    api.Runtime(
      ..runtime,
      tree: supervisor.SessionTree(..runtime.tree, writer: absent),
    )
  assert writer.get_register(absent, register.FactCustom, "probe")
    == Error(writer.Unavailable)
  assert writer.commit(absent, tx.Tx(writes: [], expected: []))
    == Error(writer.Unavailable)
  assert api.accept_quietly(unavailable, [fake.user("work")])
    == Error(api.RuntimeUnavailable)
  let assert Ok(operation) = api.prompt(runtime, [fake.user("work")])
    as "retry against the available writer must admit once"
  let assert Ok(result) = api.await_result(runtime, operation, within_ms: 5000)
    as "the retried admission must complete"
  harness.assert_completed(result)
  assert harness.final_projection(session)
    == ["user:work", "assistant:stop:finished"]
  assert api.close(runtime) == Ok(Nil)
}

pub fn repeated_sessions_execute_and_close_without_atom_growth_test() {
  let rec = recorder.start()
  let effects =
    fake.effects(
      rec,
      clock.fixed(at: 1_000_000),
      [],
      fn(_spec) { fake.Reply(fake.answer("finished", 1)) },
      fn(_run) { fake.ToolReply("unused", False, False) },
    )

  // Warm the complete execution and loop paths in this VM, independently of
  // which tests ran before us. The measured cycles still start fresh runtimes.
  int.range(from: 0, to: 1, with: Nil, run: fn(_, _) { cycle(effects) })
  let before = system_count(AtomCount)
  int.range(from: 0, to: 50, with: Nil, run: fn(_, _) { cycle(effects) })
  assert system_count(AtomCount) == before
    as "closed sessions must not leave permanent routing atoms"
}

fn cycle(effects: effects.Effects) -> Nil {
  let assert Ok(session) = session.open_memory(clock.fixed(at: 1_000_000))
    as "the memory session must open"
  let assert Ok(runtime) =
    api.open(session, effects, api.default_options(harness.configuration()))
    as "the runtime must open"
  let assert Ok(operation) = api.prompt(runtime, [fake.user("work")])
    as "the real writer must admit the prompt"
  let assert Ok(result) = api.await_result(runtime, operation, within_ms: 5000)
    as "the scripted turn must complete"
  harness.assert_completed(result)
  let assert Ok(driver) = supervisor.strand_subject(runtime.tree, "main")
    as "the live strand must resolve"
  let assert Ok(driver_pid) = process.subject_owner(driver)
    as "the strand must have an owner"
  let namespace = address.owner(runtime.tree.namespace)

  assert api.close(runtime) == Ok(Nil)
  assert !process.is_alive(runtime.tree.supervisor)
  assert !process.is_alive(driver_pid)
  assert !process.is_alive(namespace)
  assert address.lookup(runtime.tree.writer) == Error(Nil)
  assert address.lookup(runtime.tree.registry) == Error(Nil)
}
