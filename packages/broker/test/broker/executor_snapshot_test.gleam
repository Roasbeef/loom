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
import broker/framing
import broker/relay
import broker/support/fake_helper
import broker/support/planes
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

fn plane(script: fake_helper.Script, size size: Int) -> planes.Plane {
  planes.start_scripted(size:, script: fn() { fake_helper.start_helper(script) })
}

fn service_of(plane: planes.Plane) -> executor.Executor {
  plane.service
}

fn call(plane: planes.Plane, deadline_ms: Int) {
  call_spec(
    plane,
    planes.spec(planes.op(), argv: ["/bin/echo", "hi"], deadline_ms:),
  )
}

fn call_spec(plane: planes.Plane, spec: broker.CallSpec) {
  let events = process.new_subject()
  let assert Ok(handle) =
    broker.clear_call(plane.broker, spec, events:, waiting: 2000)
  #(handle, events)
}

// Polls the snapshot until `holds`, so a test reads state the service has
// reached and not state it is about to reach.
fn snapshot_where(
  plane: planes.Plane,
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
  let assert [broker.CallSettled(_)] = planes.collect(events, within: 2000)
  planes.stop(plane)
}

/// A cancel is visible on the row as a cause and, once the execution has
/// settled, as a cancel-to-settle sample and in the recent ring.
pub fn a_cancel_is_measured_to_its_settlement_test() {
  let plane = plane(fake_helper.SleepUntilCancel, size: 1)
  let #(handle, events) = call(plane, 100_000)
  let _ = snapshot_where(plane, fn(snapshot) { snapshot.live != [] })

  broker.cancel(plane.broker, handle)
  let assert [broker.CallSettled(_)] = planes.collect(events, within: 2000)
  let snapshot =
    snapshot_where(plane, fn(snapshot) { snapshot.metrics.completed == 1 })

  assert snapshot.live == []
  assert snapshot.metrics.cancel_to_settle.samples == 1
  let assert [settled] = snapshot.recent
  assert settled.cancel == execution.Asked(execution.ByBroker)
  let assert executor_view.Completed(..) = settled.outcome
  planes.stop(plane)
}

/// Output is reported to the service on the first chunk and then at most
/// once per `progress_interval_ms`, so forty chunks emitted at once leave
/// the live row somewhere between the first chunk and the last, while the
/// counters are exact at settlement.
pub fn progress_is_thinned_and_exact_at_settlement_test() {
  let plane = plane(fake_helper.ChunksThenSleep(40), size: 1)
  let #(handle, events) = call(plane, 100_000)
  let snapshot =
    snapshot_where(plane, fn(snapshot) {
      case snapshot.live {
        [row] -> row.output.chunks >= 1
        _ -> False
      }
    })
  let assert [row] = snapshot.live
  assert row.output.chunks <= 40
  assert row.output.stdout_bytes > 0

  broker.cancel(plane.broker, handle)
  let _ = planes.collect(events, within: 2000)
  let snapshot =
    snapshot_where(plane, fn(snapshot) { snapshot.metrics.completed == 1 })
  let assert [settled] = snapshot.recent
  assert settled.stdout_bytes == 40
  assert snapshot.metrics.output_bytes == 40
  planes.stop(plane)
}

/// A flood of chunks inside one `progress_interval_ms` costs the service the
/// first report and, at the very most, one more if the window rolls over;
/// without the time bound it would be one report per sixteen chunks.
pub fn a_chunk_flood_casts_at_most_two_progress_reports_test() {
  let reports = process.new_subject()
  let link =
    relay.Link(
      cancel: fn() { Nil },
      may_settle: fn(_verdict) { relay.Granted },
      progress: fn(progress) { process.send(reports, progress) },
    )
  let assert Ok(started) =
    relay.start(relay.Config(
      caller: None,
      helper: process.self(),
      clock: clock.fixed(at: 1000),
      deadline_ms: 0,
      deliver: fn(_chunk) { Nil },
      settle: fn(_terminal) { Nil },
      link:,
    ))
  list.repeat(Nil, 320)
  |> list.each(fn(_) {
    process.send(
      started.events,
      exec.Output(
        stream: framing.Stdout,
        data: <<"x">>,
        total_bytes: 1,
        truncated: False,
      ),
    )
  })

  // Wait for the relay to have read them all before counting.
  process.sleep(150)
  let casts = drain_count(reports, 0)
  assert casts >= 1
  assert casts <= 2
  process.kill(started.pid)
}

fn drain_count(subject: process.Subject(relay.Progress), seen: Int) -> Int {
  case process.receive(subject, 0) {
    Ok(_) -> drain_count(subject, seen + 1)
    Error(Nil) -> seen
  }
}

// --- history is bounded -------------------------------------------------------

/// Seventy executions leave sixty-four in the recent ring and sixty-four
/// execution samples, while the counters keep counting.
pub fn the_recent_ring_holds_sixty_four_test() {
  let plane = plane(fake_helper.EchoArgv, size: 1)
  list.each(list.repeat(Nil, 70), fn(_) {
    let #(_handle, events) = call(plane, 0)
    let assert [_, ..] = planes.collect(events, within: 3000)
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
  planes.stop(plane)
}

/// A lost execution is a failure the snapshot remembers, with its identity.
pub fn the_last_failure_names_the_lost_execution_test() {
  let plane = plane(fake_helper.SleepUntilCancel, size: 1)
  let #(handle, events) = call(plane, 100_000)
  let _ = snapshot_where(plane, fn(snapshot) { snapshot.live != [] })
  let assert Ok(relay_pid) =
    broker.relay_pid(plane.broker, handle, waiting: 1000)

  process.kill(relay_pid)
  let _ = planes.collect(events, within: 2000)
  let snapshot =
    snapshot_where(plane, fn(snapshot) { snapshot.metrics.lost == 1 })

  let assert Some(failure) = snapshot.last_failure
  assert failure.outcome == executor_view.Lost(cause: exec.RelayDown)
  assert dispatch.seq(failure.id) == 1
  planes.stop(plane)
}

/// A start refused for want of a helper is counted by its reason.
pub fn refused_starts_are_counted_by_reason_test() {
  let plane = plane(fake_helper.SleepUntilCancel, size: 1)
  let #(handle, events) = call(plane, 100_000)
  let _ = snapshot_where(plane, fn(snapshot) { snapshot.live != [] })

  let refused =
    broker.clear_call(
      plane.broker,
      planes.spec(planes.op(), argv: ["/bin/echo", "hi"], deadline_ms: 100_000),
      events: process.new_subject(),
      waiting: 1000,
    )
  assert refused == Error(broker.NoHelper(error: exec.AllBusy(size: 1)))
  let snapshot =
    snapshot_where(plane, fn(snapshot) { snapshot.metrics.all_busy >= 1 })
  assert snapshot.metrics.started == 1
  assert snapshot.metrics.pool_unavailable == 0

  broker.cancel(plane.broker, handle)
  let _ = planes.collect(events, within: 2000)
  planes.stop(plane)
}

// --- nothing a request held ------------------------------------------------------

const marker = "MARKER-4f1c9e77a0b3"

// A call whose argv, environment and working directory all carry the marker.
fn marked_spec() -> broker.CallSpec {
  broker.CallSpec(
    ..planes.spec(planes.op(), argv: ["/bin/echo", marker], deadline_ms: 0),
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
  let _ = planes.collect(events, within: 2000)
  planes.stop(plane)
}

/// A request whose argv, environment, working directory and token all carry
/// a marker, and whose helper echoes the argv back as output, leaves no
/// trace of the marker in the settled snapshot or in any line the service
/// wrote.
pub fn the_settled_snapshot_and_the_log_carry_no_request_test() {
  let lines = process.new_subject()
  let logger = log.new(sink: log.to_subject(lines), threshold: level.Debug)
  let plane =
    planes.start_logged(
      size: 2,
      spawn: fn() { Ok(fake_helper.start_helper(fake_helper.EchoArgv)) },
      clock: clock.fixed(at: 1000),
      logger:,
    )

  // Through the broker: argv, environment and working directory.
  let #(_handle, events) = call_spec(plane, marked_spec())
  let assert [_, ..] = planes.collect(events, within: 3000)

  // Directly: a capability token carrying the marker.
  let settlements = process.new_subject()
  let assert Ok(started) =
    executor.dispatcher(service_of(plane)).start(
      dispatch.Dispatch(
        system_reservation: None,
        context: dispatch.CallContext(
          operation: planes.op(),
          step: "fixture",
          origin: None,
        ),
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
  planes.stop(plane)
}

/// A completed execution is an Info line and a lost one a Warning, each
/// carrying the identity and the outcome class.
pub fn settlement_lines_are_info_for_completions_and_warnings_otherwise_test() {
  let lines = process.new_subject()
  let logger = log.new(sink: log.to_subject(lines), threshold: level.Debug)
  let plane =
    planes.start_logged(
      size: 1,
      spawn: fn() { Ok(fake_helper.start_helper(fake_helper.SleepUntilCancel)) },
      clock: clock.fixed(at: 1000),
      logger:,
    )
  let #(handle, events) = call(plane, 100_000)
  let _ = snapshot_where(plane, fn(snapshot) { snapshot.live != [] })
  broker.cancel(plane.broker, handle)
  let _ = planes.collect(events, within: 2000)
  let assert Ok(done) = process.receive(lines, 2000)
  assert done.level == level.Info
  assert string.contains(record.render(done), "\"outcome\":\"completed\"")
  assert string.contains(record.render(done), "1.1")

  let #(handle, events) = call(plane, 100_000)
  let _ = snapshot_where(plane, fn(snapshot) { snapshot.live != [] })
  let assert Ok(relay_pid) =
    broker.relay_pid(plane.broker, handle, waiting: 1000)
  process.kill(relay_pid)
  let _ = planes.collect(events, within: 2000)
  let assert Ok(lost) = process.receive(lines, 2000)
  assert lost.level == level.Warning
  assert string.contains(record.render(lost), "\"outcome\":\"lost\"")
  planes.stop(plane)
}

/// The close writes its verdict as a line of its own.
pub fn closing_logs_its_verdict_test() {
  let lines = process.new_subject()
  let logger = log.new(sink: log.to_subject(lines), threshold: level.Debug)
  let plane =
    planes.start_logged(
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

/// An observer waiting on the pool delays nothing the service owes a caller.
/// The pool's custody is read in the observer's own process, so a pool that
/// is slow to answer holds the snapshot and no one else. The test holds the
/// custody query for two seconds, takes a snapshot into it, and cancels a
/// running call meanwhile: the settlement has to come back long before the
/// custody query does. A service that asked the pool from inside its own
/// serial loop would sit in the query, and the relay's request for leave to
/// settle would wait behind it.
pub fn a_snapshot_waiting_on_the_pool_does_not_delay_a_settlement_test() {
  let held = process.new_subject()
  let plane =
    planes.start_custody_intercepted(
      size: 1,
      spawn: fn() { Ok(fake_helper.start_helper(fake_helper.SleepUntilCancel)) },
      clock: clock.fixed(at: 1000),
      intercept: fn(custody) {
        process.send(held, Nil)
        process.sleep(2000)
        custody()
      },
    )
  let #(handle, events) = call(plane, 0)

  // The observer enters the custody query, and stays there.
  let answers = process.new_subject()
  process.spawn_unlinked(fn() {
    process.send(answers, executor.snapshot(service_of(plane), waiting: 5000))
  })
  let assert Ok(Nil) = process.receive(held, 1000)
    as "the snapshot reached the custody query"

  broker.cancel(plane.broker, handle)
  let asked_at = poll.monotonic().now()
  let assert [broker.CallSettled(_)] = planes.collect(events, within: 1500)
    as "the settlement came while the custody query was still held"
  assert poll.monotonic().now() - asked_at < 1000

  // The held snapshot then completes, with the pool's answer.
  let assert Ok(Ok(snapshot)) = process.receive(answers, 4000)
  let assert Ok(_custody) = snapshot.pool
  planes.stop(plane)
}

/// A snapshot of a service that is gone is `Unreachable`, not a fault.
pub fn a_closed_service_is_unreachable_test() {
  let plane = plane(fake_helper.EchoArgv, size: 1)
  let service = service_of(plane)
  assert executor.close(service, draining: 500, helpers: 1000) == Ok(Nil)
  assert executor.snapshot(service, waiting: 300) == Error(executor.Unreachable)
  broker.stop(plane.broker)
}

/// A pool whose custody answer is a spawn failure carrying helper-authored
/// text leaves the snapshot free of it: the service reduces the refusal to a
/// name before the snapshot is built.
pub fn a_spawn_failure_in_custody_leaves_no_payload_test() {
  let plane = plane(fake_helper.EchoArgv, size: 1)
  let assert Ok(service) =
    executor.start(executor.ExecutorConfig(
      checkout: fn() { exec.checkout(plane.pool, waiting: 1000) },
      checkin: fn(helper) { exec.checkin(plane.pool, helper) },
      custody: fn() {
        Error(
          exec.SpawnFailed(
            exec.HandshakeFailed(exec.RefusedByHelper(
              code: "refused",
              message: marker,
            )),
          ),
        )
      },
      close_helpers: fn(ms) { exec.close_pool(plane.pool, waiting: ms) },
      incarnation: 2,
      log: log.discard(),
    ))
  let assert Ok(snapshot) = executor.snapshot(service, waiting: 2000)
  assert snapshot.pool == Error(executor_view.PoolSpawnFailed)
  assert_no_marker(string.inspect(snapshot))
  planes.stop(plane)
}

/// A start refused because the service is closing is counted as a pool
/// refusal, so an operator asking why starts fail after close began sees it.
pub fn a_start_refused_while_closing_is_counted_test() {
  let plane = plane(fake_helper.IgnoreCancel, size: 1)
  let #(_handle, events) = call(plane, 0)
  let _ = snapshot_where(plane, fn(snapshot) { snapshot.live != [] })
  let verdicts = process.new_subject()
  process.spawn_unlinked(fn() {
    process.send(
      verdicts,
      executor.close(service_of(plane), draining: 800, helpers: 1500),
    )
  })
  process.sleep(200)

  let spec = planes.spec(planes.op(), argv: ["/usr/bin/true"], deadline_ms: 0)
  assert broker.clear_call(
      plane.broker,
      spec,
      events: process.new_subject(),
      waiting: 1000,
    )
    == Error(broker.NoHelper(error: exec.PoolUnavailable))
  let snapshot =
    snapshot_where(plane, fn(snapshot) {
      snapshot.metrics.pool_unavailable >= 1
    })
  assert snapshot.phase == executor_view.Closing
  assert snapshot.metrics.pool_unavailable == 1

  // A helper that ignores cancel is not retired, so the verdict is an
  // error; only that the close ended matters here.
  let assert Ok(_) = process.receive(verdicts, 4000)
  let _ = planes.collect(events, within: 1000)
  broker.stop(plane.broker)
}
