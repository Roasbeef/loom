//// Cleanup tests cross the real pool retirement state machine.
//// The controlled wire withholds native exit independently of transport close.

import broker/exec
import broker/framing
import client/evolution/retirement
import gleam/erlang/process
import gleam/result
import gleeunit/should

pub fn late_native_exit_retries_original_pool_and_deletion_only_test() {
  let calls = process.new_subject()
  let assert Ok(pool) =
    exec.start_pool(size: 1, spawn: fn() {
      let config =
        exec.default_config(
          exec.ChannelTransport(send: fn(_) { Nil }, close: fn() { Nil }),
        )
      let assert Ok(helper) =
        exec.start(exec.HelperConfig(..config, heartbeat_interval_ms: 0))
        as "controlled native transport starts"
      let assert Ok(hello) =
        framing.encode(framing.Frame(
          id: 1,
          body: framing.Hello(
            proto: framing.exec_protocol_version,
            peer: "exec-helper",
            features: [],
          ),
        ))
        as "native hello encodes"
      process.send(exec.wire(helper), exec.WireBytes(hello))
      exec.await_ready(helper, waiting: 1000) |> should.equal(Ok([]))
      Ok(helper)
    })
    as "pool owns the controlled native helper"
  let assert Ok(helper) = exec.checkout(pool, waiting: 1000)
    as "pool admits its one helper"
  let delete =
    retirement.first(
      fn() {
        process.send(calls, "delete blocked")
        Error("directory removal withheld")
      },
      fn() {
        process.send(calls, "delete retry")
        Ok(Nil)
      },
    )
  let task =
    retirement.sequence(
      retirement.first(
        fn() {
          process.send(calls, "executor first close")
          exec.close_pool(pool, waiting: 10)
          |> result.map_error(fn(_) { "native exit pending" })
        },
        fn() {
          process.send(calls, "pool retry")
          exec.close_pool(pool, waiting: 1000)
          |> result.map_error(fn(_) { "native exit pending" })
        },
      ),
      delete,
    )
  let assert Error(pending) = retirement.perform(task)
    as "missing native exit retains the original pool"
  process.receive(calls, 1000) |> should.equal(Ok("executor first close"))
  process.receive(calls, 0) |> should.equal(Error(Nil))
  process.is_alive(exec.pool_pid(pool)) |> should.be_true

  // The late native exit settles the original inventory, not a replacement
  // pool. The next failure owns deletion alone after physical close consumes it.
  process.send(exec.wire(helper), exec.WireClosed(0))
  let assert Error(deletion) = retirement.perform(pending.retry)
    as "directory refusal follows confirmed native retirement"
  process.receive(calls, 1000) |> should.equal(Ok("pool retry"))
  process.receive(calls, 1000) |> should.equal(Ok("delete blocked"))
  process.is_alive(exec.pool_pid(pool)) |> should.be_false
  retirement.perform(deletion.retry) |> should.equal(Ok(Nil))
  process.receive(calls, 1000) |> should.equal(Ok("delete retry"))
  process.receive(calls, 0) |> should.equal(Error(Nil))
}

pub fn missing_runtime_report_does_not_defer_independent_native_retirement_test() {
  let calls = process.new_subject()
  let task =
    retirement.join([
      retirement.first(
        fn() {
          process.send(calls, "runtime report missing")
          Error("runtime ledger gone")
        },
        fn() {
          process.send(calls, "runtime retry only")
          Error("runtime ledger gone")
        },
      ),
      retirement.repeat(fn() {
        process.send(calls, "native retirement confirmed")
        Ok(Nil)
      }),
    ])
  let assert Error(failed) = retirement.perform(task)
    as "runtime uncertainty remains after independent native cleanup"
  process.receive(calls, 1000)
  |> should.equal(Ok("runtime report missing"))
  process.receive(calls, 1000)
  |> should.equal(Ok("native retirement confirmed"))
  retirement.perform(failed.retry) |> should.be_error
  process.receive(calls, 1000) |> should.equal(Ok("runtime retry only"))
  process.receive(calls, 0) |> should.equal(Error(Nil))
}
