//// The original writer slot is bound once before publication permits recovery.
//// Real session SQLite and the existing provider fixture establish ordering,
//// restart identity and old-root refusal without a second Effects holder.

import core/clock
import core/json
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleam/erlang/reference
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import runtime/api
import runtime/effects
import runtime/supervisor
import session/session
import simplifile
import support/fake
import support/harness
import support/internal/ffi_memory
import support/recorder
import weft/poll
import weft/registry as address

pub fn original_binding_precedes_publication_and_survives_restarts_test() {
  let #(sess, retire) = sql_session("ordering")
  let rec = recorder.start()
  let seed_rec = recorder.start()
  let assert Ok(seed) =
    api.open(
      sess,
      fake.effects(seed_rec, clock.fixed(3000), [], fn(_) { fake.Hang }, fn(_) {
        fake.ToolHang
      }),
      options(),
    )
    as "The original session can retain unfinished work."
  let assert Ok(operation) = api.accept_quietly(seed, [fake.user("recover")])
    as "The actual writer commits the recovery input."
  assert supervisor.shutdown(seed.tree, grace_ms: 1000) == Ok(Nil)
  let hooks = process.new_subject()
  let captured = process.new_subject()
  let parked = process.new_subject()
  let opened = process.new_subject()
  let base = answers(rec)
  let owner =
    process.spawn_unlinked(fn() {
      process.trap_exits(True)
      let outcome =
        api.open_fact_effects_published(
          sess,
          base,
          options(),
          fn(facts) {
            let _count = recorder.bump(rec, "bind")
            process.send(captured, facts)
            let prior = base.hooks
            Ok(
              effects.Effects(
                ..base,
                clock: clock.fixed(9999),
                entropy: fn() { 0 },
                hooks: effects.Hooks(..prior, run_start: fn(_) {
                  process.send(
                    hooks,
                    api.fact_cell_with(facts, "session/construction"),
                  )
                  []
                }),
              ),
            )
          },
          fn(runtime) {
            let permit = process.new_subject()
            process.send(parked, #(runtime, permit))
            process.receive_forever(permit)
          },
        )
      process.send(opened, outcome)
      process.receive_forever(process.new_subject())
    })
  let assert Ok(facts) = process.receive(captured, 1000)
    as "The binder receives the original slot before publication."
  let assert Ok(#(published, permit)) = process.receive(parked, 1000)
    as "The original root publishes before recovery."
  assert api.fact_cell_with(facts, "session/construction")
    == Error(api.RuntimeUnavailable)
  assert address.lookup(published.tree.writer) == Error(Nil)
  assert recorder.read(rec, "bind") == 1
  assert recorder.read(rec, "provider") == 0
  assert process.receive(hooks, 0) == Error(Nil)
  let #(now, _) = clock.read(published.effects.clock)
  assert now == 3000
  let before_entropy = recorder.read(rec, "entropy")
  let _original_entropy = published.effects.entropy()
  assert recorder.read(rec, "entropy") == before_entropy + 1
  process.send(permit, Ok(Nil))
  let assert Ok(Ok(runtime)) = process.receive(opened, 1000)
    as "Actual acknowledgement starts the same finished Effects."
  let assert Ok(Ok(None)) = process.receive(hooks, 1000)
    as "The recovered hook can read the original writer immediately."
  let assert Ok(outcome) = api.await_result(runtime, operation, within_ms: 5000)
    as "Previously unfinished work recovers after publication."
  harness.assert_completed(outcome)
  assert api.put_reserved_fact(
      runtime,
      "session/construction",
      json.String("original"),
    )
    == Ok(Nil)
  let assert Ok(Some(cell)) = api.fact_cell_with(facts, "session/construction")
    as "Bound facts observe the actual same-writer cell."
  assert api.fact_cell(runtime, "session/construction") == Ok(Some(cell))
  let assert Ok(_) =
    api.create_idle_strand(runtime, "peer", harness.configuration(), None)
    as "A second strand shares the finished Effects."
  restart_writer(runtime)
  let assert Ok(op) = api.prompt(runtime, [fake.user("after restart")])
    as "The replacement writer admits one ordinary run."
  let assert Ok(_) = api.await_result(runtime, op, within_ms: 5000)
    as "The restarted strand finishes."
  let assert Ok(Ok(Some(observed))) = process.receive(hooks, 1000)
    as "Restart uses the original binding, not a renewed binder."
  assert observed == cell
  let assert Ok(factory) =
    supervisor.factory_pid(runtime.tree, runtime.tree.strands)
    as "The original primary factory exists."
  process.kill(factory)
  assert poll.until(within: 1000, every: 5, attempt: fn() {
      case supervisor.factory_pid(runtime.tree, runtime.tree.strands) {
        Ok(current) if current != factory -> poll.Done(Nil)
        Ok(_) | Error(_) -> poll.Retry
      }
    })
    == poll.Answered(Nil)
  let assert 1 = recorder.read(rec, "bind")
    as "Driver and factory restarts must retain the original one-time binding."
  assert api.fact_cell_with(facts, "session/construction") == Ok(Some(cell))
  assert api.close(runtime) == Ok(Nil)
  assert retire() == Ok(Nil)
  process.kill(owner)
  let #(next_session, next_retire) = sql_session("different-root")
  let assert Ok(next) = api.open(next_session, answers(rec), options())
    as "A new original root has a distinct namespace."
  assert api.put_reserved_fact(
      next,
      "session/construction",
      json.String("replacement"),
    )
    == Ok(Nil)
  assert api.fact_cell_with(facts, "session/construction")
    == Error(api.RuntimeUnavailable)
  assert api.close(next) == Ok(Nil)
  assert next_retire() == Ok(Nil)
}

pub fn refused_binding_disposes_namespace_before_any_publication_test() {
  let #(sess, retire) = sql_session("bind-refusal")
  let rec = recorder.start()
  let captured = process.new_subject()
  let replied = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      process.trap_exits(True)
      let outcome =
        api.open_fact_effects_published(
          sess,
          answers(rec),
          options(),
          fn(facts) {
            process.send(captured, facts)
            Error("binding refused")
          },
          fn(_) {
            let _ = recorder.bump(rec, "published")
            Ok(Nil)
          },
        )
      process.send(replied, outcome)
      process.receive_forever(process.new_subject())
    })
  let assert Ok(facts) = process.receive(captured, 1000)
    as "The one refused construction exposed only its original slot."
  let assert Ok(Error(_)) = process.receive(replied, 1000)
    as "A refused bind cannot return a live Runtime."
  assert process.is_alive(owner)
  assert original_links(owner) == 0
  assert recorder.read(rec, "published") == 0
  assert recorder.read(rec, "provider") == 0
  assert api.fact_cell_with(facts, "session/construction")
    == Error(api.RuntimeUnavailable)
  assert session.close(sess) == Ok(Nil)
  assert retire() == Ok(Nil)
  process.kill(owner)
}

fn restart_writer(runtime: api.Runtime) -> Nil {
  let assert Ok(subject) = address.lookup(runtime.tree.writer)
    as "The original writer is live."
  let assert Ok(pid) = process.subject_owner(subject)
    as "Its actual PID is retained."
  process.kill(pid)
  assert poll.until(within: 1000, every: 5, attempt: fn() {
      case address.lookup(runtime.tree.writer) {
        Ok(current) if current != subject -> poll.Done(Nil)
        Ok(_) | Error(Nil) -> poll.Retry
      }
    })
    == poll.Answered(Nil)
  Nil
}

fn sql_session(name: String) {
  let assert Ok(cwd) = simplifile.current_directory()
    as "Portable fixture root."
  let path =
    cwd
    <> "/build/fact-effects-"
    <> name
    <> "-"
    <> string.inspect(reference.new()) |> string.replace("/", "_")
    <> ".db"
  let assert Ok(value) =
    session.open_sqlite_owned(path, "test", 30_000, clock.fixed(1000))
    as "The actual SQLite writer lease opens."
  value
}

fn answers(rec) -> effects.Effects {
  fake.effects(
    rec,
    clock.fixed(3000),
    [],
    fn(_) { fake.Reply(fake.answer("recovered", 3)) },
    fn(_) { fake.ToolHang },
  )
}

fn options() -> api.Options {
  api.default_options(harness.configuration())
}

// The refused binder runs before any root exists. Its sole startup link is
// the actual allocated namespace owner, so this census detects omitted disposal
// while keeping the original assembly process alive.
fn original_links(pid: process.Pid) -> Int {
  let assert Ok(links) =
    decode.run(
      ffi_memory.process_info(pid, atom.create("links")),
      decode.at([1], decode.list(decode.dynamic)),
    )
    as "The actual original owner's links can be counted."
  list.length(links)
}
