//// Server Session time remains in the original elapsed clock, with unchanged policy.
//// Both pre-dispatch and actual helper Run refuse lost authority; ordinary native
//// calls and finite collection retain their existing positive wall-time contract.

import broker/dispatch
import broker/exec
import broker/executor
import broker/framing
import broker/policy
import broker/protocol_credit_test as peer
import core/clock
import gleam/erlang/process
import gleam/option.{Some}
import telemetry/log
import weft/actor

fn request(wall: Int) -> exec.ExecRequest {
  let original = peer.request()
  let assert Some(base) = original.policy
    as "The original fixture has a concrete policy."
  exec.ExecRequest(
    ..original,
    policy: Some(
      policy.SandboxPolicy(
        ..base,
        limits: policy.Limits(..base.limits, cpu_s: 0, wall_s: wall),
      ),
    ),
  )
}

pub fn zero_wall_server_requires_original_bounded_elapsed_authority_test() {
  let session = request(0)
  assert exec.protocol_native_wall_fits(
    session,
    framing.ServerProtocol,
    clock.fixed(0),
    1000,
  )
  assert exec.protocol_native_wall_fits(
    session,
    framing.ServerProtocol,
    clock.fixed(-1000),
    -1,
  )
  assert exec.protocol_native_wall_fits(
    session,
    framing.ServerProtocol,
    clock.fixed(0),
    43_200_000,
  )
  assert !exec.protocol_native_wall_fits(
    session,
    framing.ServerProtocol,
    clock.fixed(0),
    43_200_001,
  )
  assert !exec.protocol_native_wall_fits(
    session,
    framing.ServerProtocol,
    clock.fixed(0),
    0,
  )
  assert !exec.protocol_native_wall_fits(
    session,
    framing.ServerProtocol,
    clock.fixed(1000),
    1000,
  )
  assert !exec.protocol_native_wall_fits(
    session,
    framing.ServerProtocol,
    clock.fixed(1001),
    1000,
  )
  assert !exec.protocol_native_wall_fits(
    session,
    framing.FiniteCollected,
    clock.fixed(0),
    1000,
  )
  assert !exec.native_wall_fits(session, clock.fixed(0), 1000)
  assert exec.native_wall_fits(session, clock.fixed(0), 0)
}

pub fn positive_wall_protocols_preserve_exact_existing_native_seconds_test() {
  assert exec.protocol_native_wall_fits(
    request(1),
    framing.ServerProtocol,
    clock.fixed(0),
    1000,
  )
  assert !exec.protocol_native_wall_fits(
    request(1),
    framing.ServerProtocol,
    clock.fixed(1),
    1000,
  )
  assert exec.protocol_native_wall_fits(
    request(43_200),
    framing.ServerProtocol,
    clock.fixed(0),
    43_200_000,
  )
  assert !exec.protocol_native_wall_fits(
    request(43_201),
    framing.ServerProtocol,
    clock.fixed(0),
    43_201_000,
  )
  assert exec.protocol_native_wall_fits(
    request(60),
    framing.FiniteCollected,
    clock.fixed(0),
    60_000,
  )
  assert !exec.protocol_native_wall_fits(
    request(61),
    framing.FiniteCollected,
    clock.fixed(0),
    61_000,
  )
  assert !exec.protocol_native_wall_fits(
    request(60),
    framing.FiniteCollected,
    clock.fixed(1),
    60_000,
  )
}

type Tick {
  Tick(process.Subject(Int))
  Stop
}

pub fn elapsed_authority_is_rechecked_at_actual_helper_run_test() {
  let #(helper, outbound) = peer.peer([framing.protocol_credit_feature])
  let assert Ok(pool) = exec.start_pool(1, fn() { Ok(helper) })
    as "The original helper has actual pool custody."
  let assert Ok(service) =
    executor.start_with_retirement(
      executor.ExecutorConfig(
        fn() { exec.checkout(pool, waiting: 1000) },
        fn(helper) { exec.checkin(pool, helper) },
        fn() { exec.pool_custody(pool, waiting: 1000) },
        fn(ms) { exec.close_pool(pool, waiting: ms) },
        13,
        log.discard(),
      ),
      fn(helper, done) { exec.prepare_borrowed_retirement(pool, helper, done) },
    )
    as "The existing trusted ServerProtocol constructor owns original retirement."
  let retired = process.new_subject()
  let assert Ok(dispatcher) =
    executor.dispatcher_protocol_retiring_with_native_deadline(
      service,
      fn(_, verdict) { process.send(retired, verdict) },
    )
    as "Only actual original pool custody constructs the retiring dispatcher."
  let assert Ok(time) =
    actor.new(0)
    |> actor.on_message(fn(tick, message) {
      case message {
        Tick(reply) -> {
          process.send(reply, tick)
          actor.continue(1000)
        }
        Stop -> actor.stop()
      }
    })
    |> actor.start
    as "The bounded fixture clock fixes the two independent samples."
  let time = time.data
  let original_clock =
    clock.from_function(fn() { process.call(time, 1000, Tick) })
  let events = process.new_subject()
  let assert Error(executor.ProtocolNotStarted(dispatch.NotStarted)) =
    executor.start_protocol(
      dispatcher,
      executor.ProtocolDispatch(
        1,
        request(0),
        original_clock,
        1000,
        events,
        process.self(),
      ),
    )
    as "Pre-dispatch passes, then actual Run sees expiry and refuses without rewriting policy."
  let shutdown = peer.next(outbound)
  let assert framing.Shutdown = shutdown.body
    as "Definite actual Run refusal retires the original helper."
  assert process.receive(events, 0) == Error(Nil)
  assert process.receive(retired, 0) == Error(Nil)
  process.send(exec.wire(helper), exec.WireClosed(0))
  assert process.receive(retired, 1000) == Ok(Ok(Nil))
  assert executor.close(service, draining: 1000, helpers: 3000) == Ok(Nil)
  process.send(time, Stop)
}
