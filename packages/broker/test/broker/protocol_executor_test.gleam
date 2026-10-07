//// The protocol executor holds the exact original pool borrow until consumption.
//// Ordinary release and late control traffic cannot substitute another command.

import broker/exec
import broker/executor
import broker/framing
import broker/protocol_credit_test as peer
import broker/support/bench_host
import core/clock
import gleam/erlang/process
import telemetry/log
import weft/poll

fn service(
  helper: exec.Helper,
  checked: process.Subject(exec.Helper),
) -> executor.Executor {
  let assert Ok(service) =
    executor.start(executor.ExecutorConfig(
      checkout: fn() { Ok(helper) },
      checkin: fn(helper) { process.send(checked, helper) },
      custody: fn() { Error(exec.PoolUnavailable) },
      close_helpers: fn(_) {
        exec.shutdown(helper)
        Ok(Nil)
      },
      incarnation: 9,
      log: log.discard(),
    ))
    as "executor starts over owned helper seam"
  service
}

pub fn executor_defers_original_checkin_and_fences_old_controls_test() {
  let #(helper, outbound) = peer.peer([framing.protocol_credit_feature])
  let checked = process.new_subject()
  let service = service(helper, checked)
  let dispatcher = executor.dispatcher_collected_with_native_deadline(service)
  let events = process.new_subject()
  let cleared =
    executor.ProtocolDispatch(
      seq: 7,
      request: peer.request(),
      clock: clock.fixed(0),
      deadline_ms: 10_000,
      events:,
      caller: process.self(),
    )
  let assert Ok(original) = executor.start_protocol(dispatcher, cleared)
    as "finite original starts"
  let first = peer.next(outbound)
  assert first.id == executor.protocol_execution_id(original)
  executor.release_protocol_execution(original)
  peer.terminal(helper, first.id, 0, 0)
  let assert Ok(exec.ProtocolTerminal(Ok(_), framing.ProtocolComplete)) =
    process.receive(events, 1000)
    as "terminal reaches original receiver"
  assert process.receive(checked, 0) == Error(Nil)
  peer.inbound(
    helper,
    framing.Frame(first.id, framing.ProtocolReusable(first.id)),
  )
  let assert Ok(exec.ProtocolReusable) = process.receive(events, 1000)
    as "reuse witness reaches retained consumer"
  assert process.receive(checked, 0) == Error(Nil)
  executor.protocol_reusable_consumed(original)
  let assert Ok(returned) = process.receive(checked, 1000)
    as "consumed original witness checks in once"
  assert returned == helper
  let assert Ok(successor) = executor.start_protocol(dispatcher, cleared)
    as "slot can hold a successor after original checkin"
  let second = peer.next(outbound)
  assert second.id != first.id
  executor.cancel_protocol(original)
  executor.release_protocol_execution(original)
  executor.protocol_reusable_consumed(original)
  let assert exec.StatusBusy(_) = exec.status(helper, waiting: 1000)
    as "late original controls cannot free or cancel successor"
  assert process.receive(outbound, 0) == Error(Nil)
  assert process.receive(checked, 0) == Error(Nil)
  executor.cancel_protocol(successor)
  let assert framing.Cancel = peer.next(outbound).body
    as "successor original cancel is emitted"
  exec.shutdown(helper)
}

pub fn protocol_server_constructor_requires_exact_retirement_owner_test() {
  let #(helper, _) = peer.peer([framing.protocol_credit_feature])
  let service = service(helper, process.new_subject())
  let assert Error(_) =
    executor.dispatcher_protocol_retiring_with_native_deadline(
      service,
      fn(_, _) { Nil },
    )
    as "raw service cannot supply server retirement"
  exec.shutdown(helper)
}

pub fn executor_lost_start_reply_keeps_unknown_original_custody_test() {
  let #(helper, outbound) = peer.peer([framing.protocol_credit_feature])
  let checked = process.new_subject()
  let service = service(helper, checked)
  let dispatcher = executor.dispatcher_collected_with_native_deadline(service)
  let events = process.new_subject()
  let reached = process.new_subject()
  let held =
    clock.from_function(fn() {
      // Checkout validation is the first clock read, in the executor owner.
      // The helper's read owns its own release subject and holds the Run reply.
      let release = process.new_subject()
      process.send(reached, #(process.self(), release))
      let assert Ok(Nil) = process.receive(release, 15_000)
        as "test releases the actual clock owner"
      0
    })
  let answer = process.new_subject()
  let original_caller = process.self()
  process.spawn(fn() {
    process.send(
      answer,
      executor.start_protocol(
        dispatcher,
        executor.ProtocolDispatch(
          11,
          peer.request(),
          held,
          10_000,
          events,
          original_caller,
        ),
      ),
    )
  })
  let assert Ok(#(_, checkout_release)) = process.receive(reached, 1000)
    as "checkout deadline check reaches held clock"
  process.send(checkout_release, Nil)
  let assert Ok(#(_, run_release)) = process.receive(reached, 1000)
    as "original helper Run reaches its held clock"
  let assert Ok(Error(executor.ProtocolStartUnknown(
    original,
    exec.HelperUnresponsive,
  ))) = process.receive(answer, 6000)
    as "production Run timeout retains unknown original handle"
  assert process.receive(checked, 0) == Error(Nil)
  process.send(run_release, Nil)
  let start = peer.next(outbound)
  assert start.id == executor.protocol_execution_id(original)
  let cancel = peer.next(outbound)
  assert cancel.id == start.id
  let assert framing.Cancel = cancel.body
    as "unknown start cancellation stays on its original id"
  executor.release_protocol_execution(original)
  assert process.receive(checked, 0) == Error(Nil)
  exec.shutdown(helper)
}

// Neither a protocol terminal nor a native exit alone retires a ServerLease.
// The original pool callback also waits for its exact helper owner's normal Down.
pub fn protocol_server_retirement_joins_original_native_and_owner_test() {
  let #(helper, outbound) = peer.peer([framing.protocol_credit_feature])
  let assert Ok(pool) = exec.start_pool(1, fn() { Ok(helper) })
    as "original protocol pool starts"
  let checked = process.new_subject()
  let retired = process.new_subject()
  let assert Ok(service) =
    executor.start_with_retirement(
      executor.ExecutorConfig(
        checkout: fn() { exec.checkout(pool, waiting: 1000) },
        checkin: fn(helper) { process.send(checked, helper) },
        custody: fn() { exec.pool_custody(pool, waiting: 1000) },
        close_helpers: fn(ms) { exec.close_pool(pool, waiting: ms) },
        incarnation: 13,
        log: log.discard(),
      ),
      fn(helper, done) { exec.prepare_borrowed_retirement(pool, helper, done) },
    )
    as "service retains exact original retirement inventory"
  let assert Ok(dispatcher) =
    executor.dispatcher_protocol_retiring_with_native_deadline(
      service,
      fn(id, result) { process.send(retired, #(id, result)) },
    )
    as "trusted server constructor installs native retirement custody"
  let events = process.new_subject()
  let assert Ok(original) =
    executor.start_protocol(
      dispatcher,
      executor.ProtocolDispatch(
        31,
        peer.request(),
        clock.fixed(0),
        10_000,
        events,
        process.self(),
      ),
    )
    as "original server starts under registered pool borrow"
  let start = peer.next(outbound)
  assert start.id == executor.protocol_execution_id(original)
  let assert framing.ProtocolStart(mode: framing.ServerProtocol, ..) =
    start.body
    as "trusted constructor fixes the server mode"
  peer.terminal(helper, start.id, 0, 0)
  let assert Ok(exec.ProtocolTerminal(Ok(_), framing.ProtocolComplete)) =
    process.receive(events, 1000)
    as "terminal is visible independently of retirement"
  assert process.receive(retired, 0) == Error(Nil)
  assert process.receive(checked, 0) == Error(Nil)
  executor.release_protocol_execution(original)
  let assert framing.Shutdown = peer.next(outbound).body
    as "server release retires the exact original helper"
  assert process.receive(retired, 0) == Error(Nil)
  bench_host.suspend(exec.pool_pid(pool))
  process.send(exec.wire(helper), exec.WireClosed(0))
  let assert exec.StatusDead(_) = exec.status(helper, waiting: 1000)
    as "exact original native exit is observed"
  bench_host.suspend(exec.pid(helper))
  bench_host.resume(exec.pool_pid(pool))
  let assert poll.Answered(Nil) =
    poll.until(1000, 5, fn() {
      case exec.pool_census(pool, waiting: 1000) {
        Ok(exec.PoolCensus(retiring: 1, ..)) -> poll.Done(Nil)
        _ -> poll.Retry
      }
    })
    as "native retirement remains held before original owner Down"
  assert process.receive(retired, 0) == Error(Nil)
  assert exec.checkout(pool, waiting: 1000) == Error(exec.AllBusy(1))
  bench_host.resume(exec.pid(helper))
  let assert Ok(#(_, Ok(Nil))) = process.receive(retired, 1000)
    as "exact native exit plus normal owner Down yields retirement witness"
  assert !process.is_alive(exec.pid(helper))
  executor.release_protocol_execution(original)
  assert process.receive(retired, 0) == Error(Nil)
  assert process.receive(checked, 0) == Error(Nil)
  assert exec.close_pool(pool, waiting: 1000) == Ok(Nil)
}
