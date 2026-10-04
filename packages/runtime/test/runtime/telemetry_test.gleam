//// Structured-logging coverage for the drive loop (spec §3.4): a run
//// through the runtime emits correlated records, and the correlation
//// survives the effect sandwich's spawns.
////
//// The logger is injected, so these assert on captured records rather
//// than on anything the VM printed — which is also the point of the
//// seam: a package under test never has to emit to be observed.

import core/clock
import core/ids
import gleam/erlang/atom
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import runtime/api
import runtime/effects
import runtime/supervisor
import session/session.{type Session}
import support/fake
import support/harness
import support/internal/ffi_memory
import support/recorder
import telemetry/level
import telemetry/log
import telemetry/record.{type Record}

fn boot(
  provider: fn(effects.RequestSpec) -> fake.ProviderResult,
) -> #(Session, api.Runtime, Subject(Record)) {
  let rec = recorder.start()
  let inbox = process.new_subject()
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
      idle_poll_interval_ms: 40,
      tolerance: supervisor.Tolerance(intensity: 100, period: 10),
      logger: log.new(sink: log.to_subject(inbox), threshold: level.Debug),
    )
  let assert Ok(rt) = api.open(sess, eff, options)
    as "the session tree must boot"
  #(sess, rt, inbox)
}

fn drain(inbox: Subject(Record), acc: List(Record)) -> List(Record) {
  case process.receive(inbox, within: 200) {
    Ok(entry) -> drain(inbox, [entry, ..acc])
    Error(Nil) -> list.reverse(acc)
  }
}

fn events(entries: List(Record)) -> List(String) {
  list.map(entries, fn(entry) { entry.event })
}

fn first(entries: List(Record), event: String) -> Option(Record) {
  list.find(entries, fn(entry) { entry.event == event })
  |> option.from_result
}

pub fn a_run_emits_correlated_records_test() {
  let #(_sess, rt, inbox) =
    boot(fn(spec) {
      case fake.turn(spec) {
        0 -> fake.Reply(fake.answer("Answered", 3))
        _ -> fake.Reply(fake.answer("unexpected", 1))
      }
    })
  let assert Ok(op) = api.accept_quietly(rt, [fake.user("Hello")])
    as "acceptance must succeed"
  let assert Ok(outcome) = api.await_result(rt, op, within_ms: 3000)
    as "the run must converge"
  harness.assert_completed(outcome)
  let entries = drain(inbox, [])

  // The strand names itself on every line it writes, from the moment it
  // starts — before any operation exists.
  let assert Some(started) = first(entries, "strand.started")
    as "the driver must announce itself"
  assert started.context.strand == Some("main")
  assert started.context.op == None

  // The dispatch of the provider effect is correlated to the operation
  // and the step it belongs to; without both, two interleaved strands'
  // lines cannot be told apart.
  let assert Some(dispatched) = first(entries, "effect.dispatched")
    as "the provider dispatch must be logged"
  assert dispatched.level == level.Debug
  assert dispatched.context.strand == Some("main")
  assert dispatched.context.op != None
  assert dispatched.context.step != None

  // ... and its settlement carries the same coordinates.
  let assert Some(settled) = first(entries, "effect.settled")
    as "the provider settlement must be logged"
  assert settled.context.op == dispatched.context.op
  assert settled.context.step == dispatched.context.step

  // One `info` line per durable state change, and the operation's end
  // is one of them.
  let assert Some(finished) = first(entries, "operation.settled")
    as "the operation's settlement must be logged"
  assert finished.level == level.Info
  assert finished.context.op == dispatched.context.op

  process.kill(rt.tree.supervisor)
}

pub fn nothing_is_logged_below_the_threshold_test() {
  // The level policy is enforced by the seam, not by the call sites:
  // an `info` logger must not receive the drive loop's `debug` traffic.
  let rec = recorder.start()
  let inbox = process.new_subject()
  let assert Ok(sess) =
    session.open_memory(clock.stepping(from: 1_000_000, by: 7))
    as "the memory session must open"
  let eff =
    fake.effects(
      rec,
      clock.stepping(from: 2_000_000, by: 25),
      [],
      fn(spec) {
        case fake.turn(spec) {
          0 -> fake.Reply(fake.answer("Answered", 3))
          _ -> fake.Reply(fake.answer("unexpected", 1))
        }
      },
      fn(_run) {
        fake.ToolReply(text: "unused", is_error: False, terminate: False)
      },
    )
  let base = api.default_options(harness.configuration())
  let options =
    api.Options(
      ..base,
      poll_interval_ms: 40,
      idle_poll_interval_ms: 40,
      tolerance: supervisor.Tolerance(intensity: 100, period: 10),
      logger: log.new(sink: log.to_subject(inbox), threshold: level.Info),
    )
  let assert Ok(rt) = api.open(sess, eff, options)
    as "the session tree must boot"
  let assert Ok(op) = api.accept_quietly(rt, [fake.user("Hello")])
    as "acceptance must succeed"
  let assert Ok(_) = api.await_result(rt, op, within_ms: 3000)
    as "the run must converge"
  let entries = drain(inbox, [])
  assert !list.contains(events(entries), "effect.dispatched")
  assert list.contains(events(entries), "operation.settled")
  process.kill(rt.tree.supervisor)
}

pub fn the_default_runtime_logs_nothing_test() {
  // A host that injected no logger gets the discarding one, so a
  // library test never has to tolerate output it did not ask for.
  assert log.threshold(api.default_options(harness.configuration()).logger)
    == level.Error
}

pub fn the_strand_driver_labels_itself_for_the_ownership_inspector_test() {
  // The driver adopts its logger as `strand_driver`, so an inspector that
  // reads `process_info(Pid, label)` can attribute the driver's memory to
  // its session and strand (protocol-change/065).
  let #(_sess, rt, _inbox) =
    boot(fn(_spec) { fake.Reply(fake.answer("unused", 1)) })
  let assert Ok(subject) = supervisor.strand_subject(rt.tree, "main")
    as "the main strand's driver must be running"
  let assert Ok(driver) = process.subject_owner(subject)
    as "the driver owns its subject"
  let label =
    ffi_memory.process_info(driver, atom.create("label")) |> string.inspect
  assert string.contains(label, "PickglassOwner")
  assert string.contains(label, "strand_driver")
  assert string.contains(label, "main")
  assert string.contains(label, ids.session_id_to_string(api.session_id(rt)))

  process.kill(rt.tree.supervisor)
}
