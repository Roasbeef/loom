//// The executor service's operational surface: the snapshot an operator
//// reads when an execution looks stuck, the counters and rings behind it,
//// and the lines the service writes. The properties pinned here are the
//// ones S3 promised: the snapshot is bounded, it is true, and it carries
//// nothing a request held.

import broker/broker
import broker/dispatch
import broker/exec
import broker/execution
import broker/executor
import broker/executor_view
import broker/relay
import broker/support/fake_helper
import broker/support/lanes
import core/clock
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import telemetry/level
import telemetry/log
import telemetry/record
import weft/poll

// --- fixtures -------------------------------------------------------------

fn plane(script: fake_helper.Script, size size: Int) -> lanes.Plane {
  lanes.start_scripted(lanes.Service, size:, script: fn() {
    fake_helper.start_helper(script)
  })
}

fn service_of(plane: lanes.Plane) -> executor.Executor {
  let assert Some(service) = plane.service as "a service-lane plane"
  service
}

fn call(plane: lanes.Plane, deadline_ms: Int) {
  call_spec(
    plane,
    lanes.spec(lanes.op(), argv: ["/bin/echo", "hi"], deadline_ms:),
  )
}

fn call_spec(plane: lanes.Plane, spec: broker.CallSpec) {
  let events = process.new_subject()
  let assert Ok(handle) =
    broker.clear_call(plane.broker, spec, events:, waiting: 2000)
  #(handle, events)
}

// Polls the snapshot until `holds`, so a test reads state the service has
// reached and not state it is about to reach.
fn snapshot_where(
  plane: lanes.Plane,
  holds: fn(executor_view.Snapshot) -> Bool,
) -> executor_view.Snapshot {
  let assert poll.Answered(snapshot) =
    poll.until(within: 5000, every: 10, attempt: fn() {
      case executor.snapshot(service_of(plane), waiting: 2000) {
        Ok(snapshot) ->
          case holds(snapshot) {
            True -> poll.Done(snapshot)
            False -> poll.Retry
          }
        Error(unreachable) -> poll.Fail(unreachable)
      }
    })
    as "the snapshot reached the expected shape"
  snapshot
}

// --- a live row -------------------------------------------------------------

/// A running execution is one row naming its identity, mode, enforcement
/// demand, deadline, helper generation and age, and the pool's custody of
/// that helper agrees with it.
pub fn a_live_execution_is_one_true_row_test() {
  let plane = plane(fake_helper.SleepUntilCancel, size: 2)
  let #(handle, events) = call(plane, 100_000)
  let snapshot = snapshot_where(plane, fn(snapshot) { snapshot.live != [] })

  assert snapshot.incarnation == 1
  assert snapshot.phase == executor_view.Serving
  let assert [row] = snapshot.live
  assert dispatch.seq(row.id) == 1
  assert row.status == executor_view.Running
  assert row.mode == execution.Streaming
  assert row.cancel == execution.NotAsked
  assert row.demand == exec.BestEffort
  assert row.deadline_ms > 0
  assert row.age_ms >= 0
  assert row.helper_ordinal == Some(1)

  let assert Ok(custody) = snapshot.pool
  let assert [view] =
    list.filter(custody.helpers, fn(v) { v.pid == row.helper })
  assert view.lending == exec.Lent
  assert view.custody == exec.Held
  assert snapshot.metrics.started == 1

  broker.cancel(plane.broker, handle)
  let assert [broker.CallSettled(_)] = lanes.collect(events, within: 2000)
  lanes.stop(plane)
}

/// A cancel is visible on the row as a cause and, once the execution has
/// settled, as a cancel-to-settle sample and in the recent ring.
pub fn a_cancel_is_measured_to_its_settlement_test() {
  let plane = plane(fake_helper.SleepUntilCancel, size: 1)
  let #(handle, events) = call(plane, 100_000)
  let _ = snapshot_where(plane, fn(snapshot) { snapshot.live != [] })

  broker.cancel(plane.broker, handle)
  let assert [broker.CallSettled(_)] = lanes.collect(events, within: 2000)
  let snapshot =
    snapshot_where(plane, fn(snapshot) { snapshot.metrics.completed == 1 })

  assert snapshot.live == []
  assert snapshot.metrics.cancel_to_settle.samples == 1
  let assert [settled] = snapshot.recent
  assert settled.cancel == execution.Asked(execution.ByBroker)
  let assert executor_view.Completed(..) = settled.outcome
  lanes.stop(plane)
}

/// Output is reported to the service on the first chunk and every
/// `progress_chunks`-th, not on each: forty chunks leave the live row at
/// thirty-two, and the counters are exact at settlement.
pub fn progress_is_thinned_and_exact_at_settlement_test() {
  let plane = plane(fake_helper.ChunksThenSleep(40), size: 1)
  let #(handle, events) = call(plane, 100_000)
  let snapshot =
    snapshot_where(plane, fn(snapshot) {
      case snapshot.live {
        [row] -> row.output.chunks >= 2 * relay.progress_chunks
        _ -> False
      }
    })
  let assert [row] = snapshot.live
  assert row.output.chunks == 2 * relay.progress_chunks
  assert row.output.stdout_bytes > 0

  broker.cancel(plane.broker, handle)
  let _ = lanes.collect(events, within: 2000)
  let snapshot =
    snapshot_where(plane, fn(snapshot) { snapshot.metrics.completed == 1 })
  let assert [settled] = snapshot.recent
  assert settled.stdout_bytes == 40
  assert snapshot.metrics.output_bytes == 40
  lanes.stop(plane)
}

// --- history is bounded -------------------------------------------------------

/// Seventy executions leave sixty-four in the recent ring and sixty-four
/// execution samples, while the counters keep counting.
pub fn the_recent_ring_holds_sixty_four_test() {
  let plane = plane(fake_helper.EchoArgv, size: 1)
  list.each(list.repeat(Nil, 70), fn(_) {
    let #(_handle, events) = call(plane, 0)
    let assert [_, ..] = lanes.collect(events, within: 3000)
    Nil
  })
  let snapshot =
    snapshot_where(plane, fn(snapshot) { snapshot.metrics.completed == 70 })

  assert list.length(snapshot.recent) == executor_view.ring_size
  assert executor_view.ring_size == 64
  assert snapshot.metrics.started == 70
  assert snapshot.metrics.execution.samples == 64
  assert snapshot.metrics.launch.samples == 64

  // Newest first: the head is the last execution, sequence seventy.
  let assert [newest, ..] = snapshot.recent
  assert dispatch.seq(newest.id) == 70
  lanes.stop(plane)
}

/// A lost execution is a failure the snapshot remembers, with its identity.
pub fn the_last_failure_names_the_lost_execution_test() {
  let plane = plane(fake_helper.SleepUntilCancel, size: 1)
  let #(handle, events) = call(plane, 100_000)
  let _ = snapshot_where(plane, fn(snapshot) { snapshot.live != [] })
  let assert Ok(relay_pid) =
    broker.relay_pid(plane.broker, handle, waiting: 1000)

  process.kill(relay_pid)
  let _ = lanes.collect(events, within: 2000)
  let snapshot =
    snapshot_where(plane, fn(snapshot) { snapshot.metrics.lost == 1 })

  let assert Some(failure) = snapshot.last_failure
  assert failure.outcome == executor_view.Lost(cause: exec.RelayDown)
  assert dispatch.seq(failure.id) == 1
  lanes.stop(plane)
}

/// A start refused for want of a helper is counted by its reason.
pub fn refused_starts_are_counted_by_reason_test() {
  let plane = plane(fake_helper.SleepUntilCancel, size: 1)
  let #(handle, events) = call(plane, 100_000)
  let _ = snapshot_where(plane, fn(snapshot) { snapshot.live != [] })

  let refused =
    broker.clear_call(
      plane.broker,
      lanes.spec(lanes.op(), argv: ["/bin/echo", "hi"], deadline_ms: 100_000),
      events: process.new_subject(),
      waiting: 200,
    )
  assert refused == Error(broker.NoHelper(error: exec.AllBusy(size: 1)))
  let snapshot =
    snapshot_where(plane, fn(snapshot) { snapshot.metrics.all_busy >= 1 })
  assert snapshot.metrics.started == 1
  assert snapshot.metrics.pool_unavailable == 0

  broker.cancel(plane.broker, handle)
  let _ = lanes.collect(events, within: 2000)
  lanes.stop(plane)
}

// --- nothing a request held ------------------------------------------------------

const marker = "MARKER-4f1c9e77a0b3"

// A call whose argv, environment and working directory all carry the marker.
fn marked_spec() -> broker.CallSpec {
  broker.CallSpec(
    ..lanes.spec(lanes.op(), argv: ["/bin/echo", marker], deadline_ms: 0),
    env: [#("PATH", "/usr/bin"), #("SECRET", marker)],
    cwd: "/work/" <> marker,
  )
}

fn assert_no_marker(rendered: String) -> Nil {
  assert !string.contains(rendered, marker)
  assert !string.contains(rendered, "SECRET")
}

/// While a request is live, the row that describes it carries none of it:
/// not the argv, the environment, the working directory, nor the token.
pub fn a_live_snapshot_carries_no_request_test() {
  let plane = plane(fake_helper.SleepUntilCancel, size: 1)
  let #(handle, events) = call_spec(plane, marked_spec())
  let snapshot = snapshot_where(plane, fn(snapshot) { snapshot.live != [] })
  let assert [_row] = snapshot.live
  assert_no_marker(string.inspect(snapshot))

  broker.cancel(plane.broker, handle)
  let _ = lanes.collect(events, within: 2000)
  lanes.stop(plane)
}

/// A request whose argv, environment, working directory and token all carry
/// a marker, and whose helper echoes the argv back as output, leaves no
/// trace of the marker in the settled snapshot or in any line the service
/// wrote.
pub fn the_settled_snapshot_and_the_log_carry_no_request_test() {
  let lines = process.new_subject()
  let logger = log.new(sink: log.to_subject(lines), threshold: level.Debug)
  let plane =
    lanes.start_logged(
      lanes.Service,
      size: 2,
      spawn: fn() { Ok(fake_helper.start_helper(fake_helper.EchoArgv)) },
      clock: clock.fixed(at: 1000),
      logger:,
    )

  // Through the broker: argv, environment and working directory.
  let #(_handle, events) = call_spec(plane, marked_spec())
  let assert [_, ..] = lanes.collect(events, within: 3000)

  // Directly: a capability token carrying the marker.
  let settlements = process.new_subject()
  let assert Ok(started) =
    executor.dispatcher(service_of(plane)).start(
      dispatch.Dispatch(
        request: exec.ExecRequest(
          argv: [marker],
          env: [#("SECRET", marker)],
          cwd: "/work/" <> marker,
          policy: None,
          token: <<marker:utf8>>,
          demand: exec.BestEffort,
        ),
        seq: 900,
        deadline_ms: 0,
        clock: clock.fixed(at: 1000),
        caller: None,
        deliver: fn(_chunk) { Nil },
        settle: fn(terminal) { process.send(settlements, terminal) },
      ),
    )
  let assert Ok(_) = process.receive(settlements, 3000)
  started.release()

  let snapshot =
    snapshot_where(plane, fn(snapshot) { list.length(snapshot.recent) == 2 })
  assert_no_marker(string.inspect(snapshot))

  // Two settlements, two lines, and neither carries the marker.
  let assert Ok(first) = process.receive(lines, 1000)
  let assert Ok(second) = process.receive(lines, 1000)
  assert first.event == "executor.settled"
  assert_no_marker(string.inspect(first))
  assert_no_marker(string.inspect(second))
  assert_no_marker(record.render(second))
  lanes.stop(plane)
}

/// A completed execution is an Info line and a lost one a Warning, each
/// carrying the identity and the outcome class.
pub fn settlement_lines_are_info_for_completions_and_warnings_otherwise_test() {
  let lines = process.new_subject()
  let logger = log.new(sink: log.to_subject(lines), threshold: level.Debug)
  let plane =
    lanes.start_logged(
      lanes.Service,
      size: 1,
      spawn: fn() { Ok(fake_helper.start_helper(fake_helper.SleepUntilCancel)) },
      clock: clock.fixed(at: 1000),
      logger:,
    )
  let #(handle, events) = call(plane, 100_000)
  let _ = snapshot_where(plane, fn(snapshot) { snapshot.live != [] })
  broker.cancel(plane.broker, handle)
  let _ = lanes.collect(events, within: 2000)
  let assert Ok(done) = process.receive(lines, 2000)
  assert done.level == level.Info
  assert string.contains(record.render(done), "\"outcome\":\"completed\"")
  assert string.contains(record.render(done), "1.1")

  let #(handle, events) = call(plane, 100_000)
  let _ = snapshot_where(plane, fn(snapshot) { snapshot.live != [] })
  let assert Ok(relay_pid) =
    broker.relay_pid(plane.broker, handle, waiting: 1000)
  process.kill(relay_pid)
  let _ = lanes.collect(events, within: 2000)
  let assert Ok(lost) = process.receive(lines, 2000)
  assert lost.level == level.Warning
  assert string.contains(record.render(lost), "\"outcome\":\"lost\"")
  lanes.stop(plane)
}

/// The close writes its verdict as a line of its own.
pub fn closing_logs_its_verdict_test() {
  let lines = process.new_subject()
  let logger = log.new(sink: log.to_subject(lines), threshold: level.Debug)
  let plane =
    lanes.start_logged(
      lanes.Service,
      size: 1,
      spawn: fn() { Ok(fake_helper.start_helper(fake_helper.EchoArgv)) },
      clock: clock.fixed(at: 1000),
      logger:,
    )
  assert executor.close(service_of(plane), draining: 500, helpers: 1000)
    == Ok(Nil)
  let assert Ok(closed) = process.receive(lines, 1000)
  assert closed.event == "executor.closed"
  assert closed.level == level.Info
  broker.stop(plane.broker)
}

/// A snapshot of a service that is gone is `Unreachable`, not a fault.
pub fn a_closed_service_is_unreachable_test() {
  let plane = plane(fake_helper.EchoArgv, size: 1)
  let service = service_of(plane)
  assert executor.close(service, draining: 500, helpers: 1000) == Ok(Nil)
  assert executor.snapshot(service, waiting: 300) == Error(executor.Unreachable)
  broker.stop(plane.broker)
}
