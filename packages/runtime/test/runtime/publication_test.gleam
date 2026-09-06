//// Runtime publication must precede recovery, not merely the open reply.
//// These tests hold the first child-start callback while an unfinished
//// operation is durable, then exercise admission, refusal and opener death.

import core/clock
import gleam/erlang/process
import gleam/result
import runtime/api
import runtime/effects
import runtime/supervisor
import session/session
import support/fake
import support/harness
import support/recorder
import weft
import weft/poll
import weft/registry as address

pub fn publication_precedes_recovery_and_is_not_repeated_on_restart_test() {
  let #(session, operation) = unfinished_session()
  let rec = recorder.start()
  let published = process.new_subject()
  let opened = process.new_subject()
  let _opener =
    process.spawn_unlinked(fn() {
      let outcome =
        api.open_published(session, answers(rec), options(), fn(runtime) {
          let release = process.new_subject()
          let _count = recorder.bump(rec, "published")
          process.send(published, #(runtime, release))
          process.receive_forever(release)
        })
      process.send(opened, outcome)
    })

  // Publication is acknowledged only after the test has inspected the
  // parked root. Even a recovered operation cannot reach its provider yet.
  let assert Ok(#(parked, release)) = process.receive(published, within: 1000)
    as "the runtime must publish before recovering"
  assert address.lookup(parked.tree.writer) == Error(Nil)
  assert process.is_alive(parked.tree.supervisor)
  assert recorder.read(rec, "provider") == 0
  process.send(release, Ok(Nil))
  let assert Ok(Ok(runtime)) = process.receive(opened, within: 1000)
    as "acknowledged publication must let startup finish"
  assert runtime.tree.supervisor == parked.tree.supervisor
  assert runtime.tree.drains == parked.tree.drains
  let assert Ok(outcome) = api.await_result(runtime, operation, within_ms: 5000)
    as "the previously unfinished operation must recover"
  harness.assert_completed(outcome)

  // Rest-for-one replaces the writer and drivers below the published
  // witness. It must not invoke a second, now-unserviced publication gate.
  let assert Ok(old_writer) = address.lookup(runtime.tree.writer)
    as "the live writer must resolve"
  let assert Ok(old_pid) = process.subject_owner(old_writer)
    as "the writer must have an owner"
  process.kill(old_pid)
  assert poll.until(within: 1000, every: 5, attempt: fn() {
      case address.lookup(runtime.tree.writer) {
        Ok(current) if current != old_writer -> poll.Done(Nil)
        Ok(_) | Error(Nil) -> poll.Retry
      }
    })
    == poll.Answered(Nil)
  let assert Ok(next) = api.prompt(runtime, [fake.user("after restart")])
    as "the replacement writer must accept work"
  let assert Ok(outcome) = api.await_result(runtime, next, within_ms: 5000)
    as "the replacement drivers must execute work"
  harness.assert_completed(outcome)
  assert recorder.read(rec, "published") == 1
  assert api.close(runtime) == Ok(Nil)
}

pub fn refused_publication_never_recovers_and_retires_routing_test() {
  let #(session, _operation) = unfinished_session()
  let rec = recorder.start()
  let published = process.new_subject()
  let refused = process.new_subject()

  // Session owners trap child exits while assembling resources. A failed
  // OTP root also sends its shutdown exit along the startup link, so observe
  // the refusal in the same owner context rather than killing the test runner.
  let _owner =
    process.spawn_unlinked(fn() {
      process.trap_exits(True)
      let outcome =
        api.open_published(session, answers(rec), options(), fn(runtime) {
          process.send(published, runtime)
          Error("custody refused")
        })
      process.send(refused, outcome)
    })
  let assert Ok(outcome) = process.receive(refused, within: 1000)
    as "the owner must receive the refused startup result"
  assert result.is_error(outcome)
  let assert Ok(runtime) = process.receive(published, within: 1000)
    as "even a refusal must retain the exact cleanup handles"
  assert_retired(runtime)
  assert recorder.read(rec, "provider") == 0
  assert session.close(session) == Ok(Nil)
}

pub fn owner_death_during_publication_drains_without_recovery_test() {
  let #(session, _operation) = unfinished_session()
  let rec = recorder.start()
  let published = process.new_subject()
  let custody = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let run =
        weft.new_prepared([
          weft.managed(fn(ledger) {
            api.open_published(session, answers(rec), options(), fn(runtime) {
              let assert Ok(drains) = process.subject_owner(runtime.tree.drains)
                as "the newly published witness must have an owner"
              case
                weft.adopt(ledger, owner: drains, cancel: fn() {
                  process.kill(runtime.tree.supervisor)
                })
              {
                weft.Refused -> Error("custody refused")
                weft.Adopted -> {
                  let never = process.new_subject()
                  process.send(published, runtime)
                  process.receive_forever(never)
                }
              }
            })
          }),
        ])
        |> weft.start_witnessed
      process.send(custody, weft.witness_pid(run))
      process.receive_forever(process.new_subject())
    })

  // The root traps exits and is blocked inside its startup callback. The
  // link alone cannot cancel it here; the independently adopted drain owner
  // gives Weft the cancellation handle even after the session owner dies.
  let assert Ok(runtime) = process.receive(published, within: 1000)
    as "the owner must publish while the root is parked"
  let assert Ok(custodian) = process.receive(custody, within: 1000)
    as "the independent scope must remain observable"
  let monitor = process.monitor(custodian)
  process.kill(owner)
  let assert Ok(process.ProcessDown(reason: process.Normal, ..)) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(1000)
    as "normal scope exit must prove the worker and adopted witness drained"
  assert_retired(runtime)
  assert recorder.read(rec, "provider") == 0
  assert session.close(session) == Ok(Nil)
}

/// Assembly runs in a transient builder process and the tree is
/// deliberately unlinked from it, so a builder that dies abnormally
/// cannot take a serving session down. The service namespace is the
/// *routing* to that same tree and was the half without the transfer: it
/// is spawn-linked to whoever started it, so the builder's death used to
/// leave every strand, the writer and the factories running while their
/// addresses resolved to nothing — `RuntimeUnavailable` from every api
/// call for ever, and a halted strand at its next commit.
pub fn builder_death_leaves_the_service_namespace_addressable_test() {
  let assert Ok(session) =
    session.open_memory(clock.stepping(from: 1000, by: 1))
    as "the durable store must open"
  let rec = recorder.start()
  let opened = process.new_subject()
  let builder =
    process.spawn_unlinked(fn() {
      let assert Ok(runtime) = api.open(session, answers(rec), options())
        as "the builder must open a runtime"
      process.send(opened, runtime)
      process.receive_forever(process.new_subject())
    })
  let assert Ok(runtime) = process.receive(opened, within: 1000)
    as "the builder must hand over its assembled runtime"
  let routing = process.monitor(address.owner(runtime.tree.namespace))
  let assembly = process.monitor(builder)
  process.kill(builder)
  let assert Ok(process.ProcessDown(..)) =
    process.new_selector()
    |> process.select_specific_monitor(assembly, fn(down) { down })
    |> process.selector_receive(1000)
    as "the builder must be gone before the tree is judged"

  // A property about something *not* happening needs a window. An exit
  // signal travelling the old link would already be in flight when the
  // builder's own `Down` arrived, and nothing orders two senders'
  // signals against each other — but under that link the namespace died
  // in microseconds, so a window that sees no `Down` at all is decisive.
  assert process.new_selector()
    |> process.select_specific_monitor(routing, fn(down) { down })
    |> process.selector_receive(200)
    == Error(Nil)
  let assert Ok(_writer) = address.lookup(runtime.tree.writer)
    as "the session writer must still resolve"
  let assert Ok(_registry) = address.lookup(runtime.tree.registry)
    as "the strand registry must still resolve"
  let assert Ok(operation) = api.prompt(runtime, [fake.user("orphaned")])
    as "an orphaned tree must still admit work"
  let assert Ok(outcome) = api.await_result(runtime, operation, within_ms: 5000)
    as "an orphaned tree must still execute work"
  harness.assert_completed(outcome)
  assert api.close(runtime) == Ok(Nil)
  assert session.close(session) == Ok(Nil)
}

fn assert_retired(runtime: api.Runtime) -> Nil {
  let assert Ok(drains) = process.subject_owner(runtime.tree.drains)
    as "the direct drain subject must retain its owner identity"
  assert poll.until(within: 1000, every: 5, attempt: fn() {
      case
        process.is_alive(runtime.tree.supervisor)
        || process.is_alive(drains)
        || process.is_alive(address.owner(runtime.tree.namespace))
      {
        True -> poll.Retry
        False -> poll.Done(Nil)
      }
    })
    == poll.Answered(Nil)
}

fn unfinished_session() {
  let assert Ok(session) =
    session.open_memory(clock.stepping(from: 1000, by: 1))
    as "the fixture's durable store must open"
  let rec = recorder.start()
  let effects =
    fake.effects(
      rec,
      clock.stepping(from: 2000, by: 1),
      [],
      fn(_) { fake.Hang },
      fn(_) { fake.ToolHang },
    )
  let assert Ok(runtime) = api.open(session, effects, options())
    as "the fixture runtime must start"
  let assert Ok(operation) = api.accept_quietly(runtime, [fake.user("recover")])
    as "the fixture must durably accept an operation"

  // Stop execution without closing the durable store. Whether the original
  // driver reached its hanging provider or not, recovery still owes a result.
  assert supervisor.shutdown(runtime.tree, grace_ms: 1000) == Ok(Nil)
  assert api.await_result(runtime, operation, within_ms: 0) == Error(Nil)
  #(session, operation)
}

fn answers(rec: process.Subject(recorder.Message)) -> effects.Effects {
  fake.effects(
    rec,
    clock.stepping(from: 3000, by: 1),
    [],
    fn(_) { fake.Reply(fake.answer("recovered", 3)) },
    fn(_) { fake.ToolHang },
  )
}

fn options() -> api.Options {
  api.default_options(harness.configuration())
}
