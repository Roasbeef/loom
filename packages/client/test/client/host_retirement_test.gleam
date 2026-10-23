//// Native retirement is reported by the same host that owns teardown.
//// These tests distinguish its explicit witness from merely observing exit.

import client/evolution/retirement
import client/host
import gleam/erlang/process
import gleeunit/should

pub fn reported_retirement_preserves_native_failure_and_tears_down_once_test() {
  let calls = process.new_subject()
  let assert Ok(owner) =
    host.adopt_reported(
      boot: fn(_stops, owner) { Ok(owner) },
      fatal: fn(_owner) { [] },
      teardown: fn(_owner) {
        process.send(calls, Nil)
        Error("helper retirement withheld")
      },
    )
    as "host must boot"
  host.retire_reported(owner)
  |> should.equal(Error("helper retirement withheld"))
  process.receive(calls, 1000) |> should.equal(Ok(Nil))

  // A later orderly stop waits on the completed owner instead of rerunning
  // the callback. Its exit alone never supplies a native retirement result.
  host.retire(owner)
  process.receive(calls, 10) |> should.equal(Error(Nil))
  host.retire_reported(owner) |> should.be_error()
}

pub fn reported_retirement_returns_success_after_native_close_test() {
  let completed = process.new_subject()
  let assert Ok(owner) =
    host.adopt_reported(
      boot: fn(_stops, owner) { Ok(owner) },
      fatal: fn(_owner) { [] },
      teardown: fn(_owner) {
        process.send(completed, Nil)
        Ok(Nil)
      },
    )
    as "host must boot"
  host.retire_reported(owner) |> should.equal(Ok(Nil))
  process.receive(completed, 1000) |> should.equal(Ok(Nil))
  host.retire(owner)
  process.is_alive(host.pid(owner)) |> should.be_false()
}

pub fn typed_retirement_transfers_remaining_task_before_host_exit_test() {
  let calls = process.new_subject()
  let assert Ok(owner) =
    host.adopt_task(
      boot: fn(_stops, owner) { Ok(owner) },
      fatal: fn(_) { [] },
      teardown: fn(_) {
        retirement.sequence(
          retirement.first(
            fn() {
              process.send(calls, "first close")
              Error("late native exit")
            },
            fn() {
              process.send(calls, "remaining close")
              Ok(Nil)
            },
          ),
          retirement.repeat(fn() {
            process.send(calls, "following phase")
            Ok(Nil)
          }),
        )
      },
    )
    as "typed host owns teardown"
  let assert Error(failed) = retirement.perform(host.retire_task(owner))
    as "host transfers its native continuation"
  process.receive(calls, 1000) |> should.equal(Ok("first close"))
  host.retire(owner)
  process.is_alive(host.pid(owner)) |> should.be_false
  retirement.perform(failed.retry) |> should.equal(Ok(Nil))
  process.receive(calls, 1000) |> should.equal(Ok("remaining close"))
  process.receive(calls, 1000) |> should.equal(Ok("following phase"))
  process.receive(calls, 0) |> should.equal(Error(Nil))
}
