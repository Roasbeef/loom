//// Physical helper concurrency preserves per-checkout identity and cancellation.
//// A controlled peer captures every frame and supplies terminal evidence, so
//// multiplex tests exercise the real actor without depending on OS scheduling.

import broker/exec
import broker/framing
import gleam/erlang/process
import gleam/option.{None, Some}
import weft/poll
import weft/timer

type Peer {
  Attach(process.Subject(exec.WireEvent))
  Bytes(BitArray)
  Closed
}

type Arming {
  Arming(Int, fn() -> Nil)
}

fn peer(inbox, wire, sent) {
  let assert Ok(message) = process.receive(inbox, 5000)
    as "controlled peer receives"
  case message {
    Bytes(bytes) -> {
      let pushed = framing.push(framing.deframer(), bytes)
      let assert [framing.Known(frame)] = pushed.inbound
        as "whole frame written"
      process.send(sent, frame)
      case frame.body {
        framing.Shutdown -> process.send(wire, exec.WireClosed(0))
        _ -> Nil
      }
      peer(inbox, wire, sent)
    }
    Closed -> process.send(wire, exec.WireClosed(137))
    Attach(_) -> peer(inbox, wire, sent)
  }
}

fn controlled(sent, grace) {
  let ready = process.new_subject()
  process.spawn(fn() {
    let inbox = process.new_subject()
    process.send(ready, inbox)
    let assert Ok(Attach(wire)) = process.receive(inbox, 1000)
      as "peer attached"
    peer(inbox, wire, sent)
  })
  let assert Ok(inbox) = process.receive(ready, 1000) as "peer starts"
  let config =
    exec.default_config(
      exec.ChannelTransport(
        send: fn(bytes) { process.send(inbox, Bytes(bytes)) },
        close: fn() { process.send(inbox, Closed) },
      ),
    )
  let assert Ok(helper) =
    exec.start(
      exec.HelperConfig(
        ..config,
        heartbeat_interval_ms: 0,
        cancel_grace_ms: grace,
      ),
    )
    as "helper starts"
  process.send(inbox, Attach(exec.wire(helper)))
  inject(
    helper,
    framing.Frame(
      id: 0,
      body: framing.Hello(
        proto: framing.exec_protocol_version,
        peer: "exec-helper",
        features: [],
        max_concurrency: Some(4),
      ),
    ),
  )
  assert exec.await_ready(helper, waiting: 1000) == Ok([])
  let assert Ok(framing.Frame(body: framing.Hello(..), ..)) =
    process.receive(sent, 1000)
    as "broker hello written"
  helper
}

fn inject(helper, frame) {
  let assert Ok(bytes) = framing.encode(frame) as "frame encodes"
  process.send(exec.wire(helper), exec.WireBytes(bytes))
}

fn request() {
  exec.ExecRequest(
    argv: ["/bin/cat"],
    env: [],
    cwd: "/work",
    policy: None,
    token: <<0:size(32)-unit(8)>>,
    demand: exec.BestEffort,
  )
}

fn start(helper, events, sent) {
  assert exec.run(helper, request(), events:, waiting: 1000) == Ok(Nil)
  let assert Ok(framing.Frame(id, framing.ExecStart(..))) =
    process.receive(sent, 1000)
    as "run written"
  id
}

fn exited(helper, id) {
  inject(
    helper,
    framing.Frame(
      id:,
      body: framing.ExecExit(
        code: 0,
        signal: 0,
        stdout_bytes: 0,
        stderr_bytes: 0,
        stdout_truncated: False,
        stderr_truncated: False,
        enforcement: [],
        degraded: False,
        wall_ms: 0,
        timed_out: False,
        cancelled: False,
      ),
    ),
  )
}

fn drain(pool) {
  assert exec.close_pool(pool, waiting: 2000) == Ok(Nil)
}

pub fn multiplex_leases_route_control_and_reject_stale_handles_test() {
  let sent = process.new_subject()
  let physical = controlled(sent, 500)
  let assert Ok(pool) = exec.start_pool(size: 4, spawn: fn() { Ok(physical) })
    as "pool starts"
  let assert Ok(first) = exec.checkout(pool, waiting: 1000) as "first lease"
  let assert Ok(second) = exec.checkout(pool, waiting: 1000) as "second lease"
  assert exec.pid(first) == exec.pid(second)
  let first_events = process.new_subject()
  let second_events = process.new_subject()
  let first_id = start(first, first_events, sent)
  let second_id = start(second, second_events, sent)
  assert first_id != second_id
  exec.stdin(second, data: <<"second">>, eof: True)
  let assert Ok(framing.Frame(
    id: stdin_id,
    body: framing.ExecStdin(exec_id: target, data: <<"second">>, eof: True),
  )) = process.receive(sent, 1000)
    as "stdin routes to second lease"
  assert target == second_id
  assert stdin_id != second_id
  exec.cancel(first)
  let assert Ok(framing.Frame(
    id: cancel_id,
    body: framing.CancelExecution(target),
  )) = process.receive(sent, 1000)
    as "cancel routes to first lease"
  assert target == first_id
  assert cancel_id != first_id
  assert cancel_id != stdin_id
  inject(
    second,
    framing.Frame(
      id: second_id,
      body: framing.ExecOut(
        stream: framing.Stdout,
        data: <<"live">>,
        bytes: 4,
        truncated: False,
      ),
    ),
  )
  let assert Ok(exec.Output(data: <<"live">>, ..)) =
    process.receive(second_events, 1000)
    as "sibling output survives cancellation"
  exited(first, first_id)
  let assert Ok(exec.Exited(_)) = process.receive(first_events, 1000)
    as "first settles"
  exec.checkin(pool, first)
  let assert Ok(third) = exec.checkout(pool, waiting: 1000)
    as "replacement lease"
  assert exec.pid(third) == exec.pid(first)

  // Both a returned lease and its delayed checkin remain powerless against
  // the fresh lease even though all three handles share one physical actor.
  exec.checkin(pool, first)
  assert exec.run(first, request(), events: first_events, waiting: 1000)
    == Error(exec.HelperBusy)
  let third_events = process.new_subject()
  let third_id = start(third, third_events, sent)
  exec.cancel(first)
  exec.stdin(first, data: <<"stale">>, eof: True)
  assert process.receive(sent, 30) == Error(Nil)
  exited(second, second_id)
  exited(third, third_id)
  let assert Ok(exec.Exited(_)) = process.receive(second_events, 1000)
    as "second settles"
  let assert Ok(exec.Exited(_)) = process.receive(third_events, 1000)
    as "third settles"
  assert process.receive(first_events, 0) == Error(Nil)
  exec.checkin(pool, second)
  exec.checkin(pool, third)
  drain(pool)
}

pub fn multiplex_failure_settles_all_and_retains_execution_quota_test() {
  let sent = process.new_subject()
  let physical = controlled(sent, 100)
  let assert Ok(pool) = exec.start_pool(size: 2, spawn: fn() { Ok(physical) })
    as "pool starts"
  let assert Ok(first) = exec.checkout(pool, waiting: 1000) as "first lease"
  let assert Ok(second) = exec.checkout(pool, waiting: 1000) as "second lease"
  assert exec.checkout(pool, waiting: 1000) == Error(exec.AllBusy(size: 2))
  let first_events = process.new_subject()
  let second_events = process.new_subject()
  let _ = start(first, first_events, sent)
  let _ = start(second, second_events, sent)

  // Returning a live lease withdraws the physical helper. Even orderly
  // retirement must settle every accepted sibling exactly once first.
  exec.checkin(pool, first)
  let assert Ok(exec.Failed(_)) = process.receive(first_events, 1000)
    as "first fails in band"
  let assert Ok(exec.Failed(_)) = process.receive(second_events, 1000)
    as "sibling fails in band"
  assert process.receive(first_events, 0) == Error(Nil)
  assert process.receive(second_events, 0) == Error(Nil)
  drain(pool)
}

pub fn multiplex_last_lease_starts_idle_retirement_test() {
  let sent = process.new_subject()
  let physical = controlled(sent, 100)
  let armings = process.new_subject()
  let timers =
    timer.Injected(after: fn(delay, wake) {
      process.send(armings, Arming(delay, wake))
    })
  let assert Ok(pool) =
    exec.start_pool_with_timers(size: 4, timers:, spawn: fn() { Ok(physical) })
    as "pool starts"
  let assert Ok(first) = exec.checkout(pool, waiting: 1000) as "first lease"
  let assert Ok(second) = exec.checkout(pool, waiting: 1000) as "second lease"
  exec.checkin(pool, first)
  let assert Ok(census) = exec.pool_census(pool, waiting: 1000)
    as "checkin observed"
  assert census.borrowed == 1
  assert process.receive(armings, 0) == Error(Nil)
  exec.checkin(pool, second)
  let assert Ok(Arming(60_000, wake)) = process.receive(armings, 1000)
    as "last lease arms idle retirement"
  wake()
  let assert poll.Answered(Nil) =
    poll.until(within: 2000, every: 1, attempt: fn() {
      case exec.pool_census(pool, waiting: 1000) {
        Ok(exec.PoolCensus(retired: 1, ..)) -> poll.Done(Nil)
        _ -> poll.Retry
      }
    })
    as "physical helper retires after final lease"
  drain(pool)
}

pub fn multiplex_cancel_deadlines_survive_sibling_settlement_test() {
  let sent = process.new_subject()
  let physical = controlled(sent, 40)
  let assert Ok(pool) = exec.start_pool(size: 4, spawn: fn() { Ok(physical) })
    as "pool starts"
  let assert Ok(first) = exec.checkout(pool, waiting: 1000) as "first lease"
  let assert Ok(second) = exec.checkout(pool, waiting: 1000) as "second lease"
  let first_events = process.new_subject()
  let second_events = process.new_subject()
  let first_id = start(first, first_events, sent)
  let _second_id = start(second, second_events, sent)
  exec.cancel(first)
  exec.cancel(second)
  let assert Ok(framing.Frame(body: framing.CancelExecution(_), ..)) =
    process.receive(sent, 1000)
    as "first cancel sent"
  let assert Ok(framing.Frame(body: framing.CancelExecution(_), ..)) =
    process.receive(sent, 1000)
    as "second cancel sent"
  exited(first, first_id)
  let assert Ok(exec.Exited(_)) = process.receive(first_events, 1000)
    as "first settles and cancels its own deadline"

  // Removing one runner's timer and admitting a sibling must leave the
  // other grace intact. Its escalation kills the shared physical helper.
  let assert Ok(third) = exec.checkout(pool, waiting: 1000) as "third lease"
  let third_events = process.new_subject()
  let _third_id = start(third, third_events, sent)
  let assert Ok(exec.Failed(exec.CancelEscalated)) =
    process.receive(second_events, 1000)
    as "second deadline remains armed"
  let assert Ok(exec.Failed(exec.CancelEscalated)) =
    process.receive(third_events, 1000)
    as "shared death settles newly admitted sibling"
  assert process.receive(first_events, 0) == Error(Nil)
  assert process.receive(second_events, 0) == Error(Nil)
  assert process.receive(third_events, 0) == Error(Nil)
  exec.checkin(pool, second)
  let assert poll.Answered(Nil) =
    poll.until(within: 1000, every: 1, attempt: fn() {
      case exec.pool_census(pool, waiting: 1000) {
        Ok(exec.PoolCensus(unconfirmed: 1, ..)) -> poll.Done(Nil)
        _ -> poll.Retry
      }
    })
    as "unconfirmed physical retirement is inventoried"

  // The physical helper carried all four execution slots; losing proof
  // cannot allow a replacement that doubles those potentially live jails.
  assert exec.checkout(pool, waiting: 1000) == Error(exec.AllBusy(size: 0))
  assert exec.close_pool(pool, waiting: 1000) == Error(exec.RetirementExit(137))
}
