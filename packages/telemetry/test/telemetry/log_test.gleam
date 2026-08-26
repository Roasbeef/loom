//// The logger seam: an injected sink (§0.2 — tests capture rather than
//// emit), a threshold that drops what it does not permit, and the
//// context-propagation decision under test.
////
//// The propagation test is the load-bearing one. The effect sandwich
//// runs the interesting work on *spawned* processes, and Erlang's
//// `logger` metadata does not survive a spawn, so a metadata-only
//// design would produce uncorrelated lines exactly where correlation
//// matters. These tests pin the chosen answer: the context is a value
//// carried by the `Logger` the spawn closure captures.

import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import telemetry/context
import telemetry/field
import telemetry/level
import telemetry/log
import telemetry/record

fn capture() -> #(log.Logger, process.Subject(record.Record)) {
  let inbox = process.new_subject()
  #(log.new(sink: log.to_subject(inbox), threshold: level.Debug), inbox)
}

fn drain(
  inbox: process.Subject(record.Record),
  acc: List(record.Record),
) -> List(record.Record) {
  case process.receive(inbox, within: 200) {
    Ok(entry) -> drain(inbox, [entry, ..acc])
    Error(Nil) -> list.reverse(acc)
  }
}

pub fn an_injected_sink_captures_instead_of_emitting_test() {
  let #(logger, inbox) = capture()
  log.info(logger, "session.opened", [field.ident(key: "db", value: "mem")])
  let assert [entry] = drain(inbox, []) as "the sink must have seen one record"
  assert entry.level == level.Info
  assert entry.event == "session.opened"
  assert entry.fields == [field.ident(key: "db", value: "mem")]
}

pub fn a_threshold_drops_what_it_does_not_permit_test() {
  let inbox = process.new_subject()
  let logger = log.new(sink: log.to_subject(inbox), threshold: level.Warning)
  log.debug(logger, "drive.planned", [])
  log.info(logger, "operation.opened", [])
  log.warn(logger, "provider.retry", [])
  log.error(logger, "commit.faulted", [])
  let events = list.map(drain(inbox, []), fn(entry) { entry.event })
  assert events == ["provider.retry", "commit.faulted"]
}

pub fn the_discarding_logger_emits_nothing_test() {
  // The default a package uses when the host injected nothing.
  log.debug(log.discard(), "drive.planned", [])
  log.error(log.discard(), "commit.faulted", [])
}

pub fn scoping_narrows_the_context_without_losing_the_wider_one_test() {
  let #(logger, inbox) = capture()
  let strand = log.for_strand(logger, "reviewer")
  let step = log.for_step(strand, op: "op-3", step: "step-1")
  log.info(step, "effect.dispatched", [])
  let assert [entry] = drain(inbox, []) as "one record"
  assert entry.context.strand == Some("reviewer")
  assert entry.context.op == Some("op-3")
  assert entry.context.step == Some("step-1")
  // The wider logger is unchanged: scoping returns a new value.
  log.info(logger, "strand.idle", [])
  let assert [wider] = drain(inbox, []) as "one more record"
  assert wider.context.op == None
}

pub fn context_reaches_a_spawned_effect_process_test() {
  // This is the whole point of the decision. The logger is a value, so
  // the spawn closure captures it and the effect process logs under the
  // same `{session, strand, op, step}` as the driver that spawned it —
  // with no inheritance to rely on and nothing to install.
  let inbox = process.new_subject()
  let logger =
    log.new(sink: log.to_subject(inbox), threshold: level.Debug)
    |> log.scoped(
      context.for_session("sess-77")
      |> context.with_strand("main")
      |> context.with_op("op-12")
      |> context.with_step("step-4"),
    )
  let _pid =
    process.spawn_unlinked(fn() {
      log.debug(logger, "tool.started", [field.text(key: "tool", value: "bash")])
    })
  let assert Ok(entry) = process.receive(inbox, within: 2000)
    as "the spawned process must have logged"
  assert entry.context
    == context.for_session("sess-77")
    |> context.with_strand("main")
    |> context.with_op("op-12")
    |> context.with_step("step-4")
}

pub fn adopting_stamps_the_context_on_this_process_test() {
  // The second half of the decision: a spawned process also stamps its
  // context into `logger`'s own process metadata, so lines we do not
  // author — OTP crash reports, third-party libraries — land correlated
  // too. Nothing reads it back except the handler, and this test.
  let #(logger, _inbox) = capture()
  let scoped =
    log.scoped(
      logger,
      context.for_session("sess-88") |> context.with_strand("planner"),
    )
  let reply = process.new_subject()
  let _pid =
    process.spawn_unlinked(fn() {
      log.adopt(scoped)
      process.send(reply, log.process_context())
    })
  let assert Ok(seen) = process.receive(reply, within: 2000)
    as "the spawned process must report its stamped context"
  assert seen.session == Some("sess-88")
  assert seen.strand == Some("planner")
  assert seen.op == None
}

pub fn a_process_that_never_adopted_reports_an_empty_context_test() {
  let reply = process.new_subject()
  let _pid =
    process.spawn_unlinked(fn() { process.send(reply, log.process_context()) })
  let assert Ok(seen) = process.receive(reply, within: 2000)
    as "a fresh process must answer"
  assert seen == context.anonymous
}

pub fn tee_fans_one_record_out_to_two_sinks_test() {
  // The OpenTelemetry seam: an exporter is another `Sink`, composed
  // here rather than special-cased inside the logger.
  let first = process.new_subject()
  let second = process.new_subject()
  let logger =
    log.new(
      sink: log.tee(log.to_subject(first), log.to_subject(second)),
      threshold: level.Info,
    )
  log.info(logger, "operation.settled", [])
  let assert Ok(a) = process.receive(first, within: 200) as "first sink"
  let assert Ok(b) = process.receive(second, within: 200) as "second sink"
  assert a.event == "operation.settled"
  assert b.event == "operation.settled"
}
