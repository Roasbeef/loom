//// Remote admission survives checkout and helper-mailbox delay unchanged.
//// The fake helper speaks the native framing protocol, so an accidental launch
//// is visible as output even when the original caller has stopped waiting.

import broker/dispatch
import broker/exec
import broker/executor
import broker/policy
import broker/support/bench_host
import broker/support/fake_helper
import broker/support/planes
import core/clock
import gleam/erlang/process
import gleam/option.{None, Some}
import telemetry/log
import weft/actor

type TimeMessage {
  Read(reply: process.Subject(Int))
  Set(now: Int, reply: process.Subject(Nil))
  Stop
}

fn test_clock() -> #(clock.Clock, process.Subject(TimeMessage)) {
  let assert Ok(started) =
    actor.new(1000)
    |> actor.on_message(fn(now, message) {
      case message {
        Read(reply) -> {
          process.send(reply, now)
          actor.continue(now)
        }
        Set(next, reply) -> {
          process.send(reply, Nil)
          actor.continue(next)
        }
        Stop -> actor.stop()
      }
    })
    |> actor.start
    as "The controlled clock starts."
  let subject = started.data
  #(
    clock.from_function(fn() {
      process.call(subject, waiting: 1000, sending: Read)
    }),
    subject,
  )
}

fn advance(subject: process.Subject(TimeMessage), now: Int) -> Nil {
  process.call(subject, waiting: 1000, sending: Set(now, _))
}

fn request(wall_s: Int) -> exec.ExecRequest {
  let base = policy.workspace_default("/work")
  exec.ExecRequest(
    argv: ["echo", "must-not-replay"],
    env: [],
    cwd: "/work",
    policy: Some(
      policy.SandboxPolicy(
        ..base,
        limits: policy.Limits(..base.limits, wall_s:),
      ),
    ),
    token: <<0:size(256)>>,
    demand: exec.BestEffort,
  )
}

pub fn native_wall_requires_explicit_matching_lifetime_test() {
  let time = clock.fixed(1000)
  assert exec.native_wall_fits(request(2), time, 3000)
  assert !exec.native_wall_fits(request(2), time, 2999)
  assert !exec.native_wall_fits(request(0), time, 3000)
  assert !exec.native_wall_fits(request(2), time, 0)
  assert exec.native_wall_fits(request(0), time, 0)
  assert !exec.native_wall_fits(
    exec.ExecRequest(..request(2), policy: None),
    time,
    0,
  )
}

pub fn queued_run_rechecks_time_after_the_caller_stopped_waiting_test() {
  let helper = fake_helper.start_helper(fake_helper.EchoArgv)
  let #(time, control) = test_clock()
  let events = process.new_subject()
  bench_host.suspend(exec.pid(helper))
  assert exec.run_before(
      helper,
      request(2),
      time,
      4000,
      events: events,
      waiting: 20,
    )
    == Error(exec.HelperUnresponsive)

  // The events owner stays alive. Its liveness alone cannot fence a Run which
  // waited through the entire admission window in the suspended actor.
  advance(control, 5000)
  bench_host.resume(exec.pid(helper))
  let assert exec.StatusReady(_) = exec.status(helper, waiting: 1000)
    as "The queued request was refused without taking the idle helper."
  assert process.receive(events, 50) == Error(Nil)
  exec.shutdown(helper)
  process.send(control, Stop)
}

pub fn checkout_expiry_returns_helper_without_starting_a_relay_test() {
  let helper = fake_helper.start_helper(fake_helper.EchoArgv)
  let #(time, control) = test_clock()
  let returned = process.new_subject()
  let settlements = process.new_subject()
  let assert Ok(service) =
    executor.start(executor.ExecutorConfig(
      checkout: fn() {
        advance(control, 5000)
        Ok(helper)
      },
      checkin: fn(value) { process.send(returned, exec.pid(value)) },
      custody: fn() { Error(exec.PoolUnavailable) },
      close_helpers: fn(_) {
        exec.shutdown(helper)
        Ok(Nil)
      },
      incarnation: 1,
      log: log.discard(),
    ))
    as "The bounded dispatcher starts."
  let call =
    dispatch.Dispatch(
      context: dispatch.CallContext(planes.op(), "deadline", None),
      request: request(2),
      seq: 1,
      deadline_ms: 4000,
      clock: time,
      caller: Some(process.self()),
      deliver: fn(_) { Nil },
      settle: fn(terminal) { process.send(settlements, terminal) },
    )
  assert executor.dispatcher_with_native_deadline(service).start(call)
    == Error(dispatch.NotStarted)
  assert process.receive(returned, 1000) == Ok(exec.pid(helper))
  assert process.receive(settlements, 50) == Error(Nil)
  let assert exec.StatusReady(_) = exec.status(helper, waiting: 1000)
    as "Checkout expiry must leave the helper idle."
  assert executor.close(service, draining: 1000, helpers: 1000) == Ok(Nil)
  process.send(control, Stop)
}
