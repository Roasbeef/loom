import broker/exec
import broker/framing
import broker/support/fake_helper
import core/msgpack
import gleam/erlang/process
import gleam/option.{None}

// The wire is deliberately silent until the test supplies native exit. A
// transport-close notification is independent from that exit witness.
fn controlled() -> #(
  exec.Helper,
  process.Subject(BitArray),
  process.Subject(Nil),
) {
  let sent = process.new_subject()
  let closed = process.new_subject()
  let transport =
    exec.ChannelTransport(
      send: fn(bytes) { process.send(sent, bytes) },
      close: fn() { process.send(closed, Nil) },
    )
  let helper = ready_controlled(transport)
  let assert Ok(_) = process.receive(sent, 1000)
    as "broker hello precedes shutdown"
  #(helper, sent, closed)
}

fn ready_controlled(transport: exec.Transport) -> exec.Helper {
  let config = exec.default_config(transport)
  let assert Ok(helper) =
    exec.start(exec.HelperConfig(..config, heartbeat_interval_ms: 0))
    as "helper starts"
  let assert Ok(hello) =
    framing.encode(framing.Frame(
      id: 1,
      body: framing.Hello(proto: 1, peer: "exec-helper", features: []),
    ))
    as "hello encodes"
  process.send(exec.wire(helper), exec.WireBytes(hello))
  assert exec.await_ready(helper, waiting: 1000) == Ok([])
  helper
}

pub fn shutdown_requires_native_exit_without_closing_port_test() {
  let #(helper, sent, closed) = controlled()
  assert exec.close(helper, waiting: 20) == Error(exec.RetirementPending)
  let assert Ok(bytes) = process.receive(sent, 1000) as "shutdown was written"
  let framing.Pushed(inbound:, fault:, ..) =
    framing.push(framing.deframer(), bytes)
  assert fault == None
  let assert [framing.Known(framing.Frame(body: framing.Shutdown, ..))] =
    inbound
    as "empty shutdown frame"
  assert process.receive(closed, 0) == Error(Nil)
  assert process.is_alive(exec.pid(helper))

  // Only the selected exit-status event permits the BEAM actor to retire.
  process.send(exec.wire(helper), exec.WireClosed(0))
  assert exec.close(helper, waiting: 1000) == Ok(Nil)
  assert !process.is_alive(exec.pid(helper))
}

pub fn nonzero_native_exit_is_not_orderly_retirement_test() {
  let #(helper, _, _) = controlled()
  process.send(exec.wire(helper), exec.WireClosed(137))
  assert exec.close(helper, waiting: 1000) == Error(exec.RetirementExit(137))
  assert process.is_alive(exec.pid(helper))
}

pub fn discarded_transport_cannot_gain_proof_from_late_exit_test() {
  let #(helper, _, closed) = controlled()
  process.send(exec.wire(helper), exec.WireBytes(<<0, 0, 0, 1, 0xc1>>))
  assert process.receive(closed, 1000) == Ok(Nil)
  process.send(exec.wire(helper), exec.WireClosed(0))
  assert exec.close(helper, waiting: 1000) == Error(exec.RetirementProofLost)
}

pub fn dead_beam_actor_is_not_native_retirement_test() {
  let #(helper, _, _) = controlled()
  process.unlink(exec.pid(helper))
  process.kill(exec.pid(helper))
  assert exec.close(helper, waiting: 1000) == Error(exec.RetirementOwnerGone)
}

pub fn pool_joins_idle_and_borrowed_helper_owners_test() {
  let assert Ok(pool) =
    exec.start_pool(size: 2, spawn: fn() {
      Ok(fake_helper.start_helper(fake_helper.EchoArgv))
    })
    as "pool starts"
  let assert Ok(idle) = exec.checkout(pool, waiting: 1000) as "first checkout"
  let assert Ok(borrowed) = exec.checkout(pool, waiting: 1000)
    as "second checkout"
  exec.checkin(pool, idle)
  assert exec.close_pool(pool, waiting: 1000) == Ok(Nil)
  assert !process.is_alive(exec.pid(idle))
  assert !process.is_alive(exec.pid(borrowed))
  assert !process.is_alive(exec.pool_pid(pool))
}

pub fn pool_retains_helper_after_checkout_caller_times_out_test() {
  let spawned = process.new_subject()
  let assert Ok(pool) =
    exec.start_pool(size: 1, spawn: fn() {
      process.sleep(50)
      let helper = fake_helper.start_helper(fake_helper.EchoArgv)
      process.send(spawned, helper)
      Ok(helper)
    })
    as "pool starts"
  assert exec.checkout(pool, waiting: 5) == Error(exec.PoolUnavailable)
  assert exec.close_pool(pool, waiting: 1000) == Ok(Nil)
  let assert Ok(helper) = process.receive(spawned, 1000)
    as "late helper was registered"
  assert !process.is_alive(exec.pid(helper))
}

pub fn pool_timeout_keeps_custody_until_native_exit_test() {
  let assert Ok(pool) =
    exec.start_pool(size: 1, spawn: fn() {
      let helper =
        ready_controlled(
          exec.ChannelTransport(send: fn(_) { Nil }, close: fn() { Nil }),
        )
      Ok(helper)
    })
    as "pool starts"
  let assert Ok(helper) = exec.checkout(pool, waiting: 1000)
    as "helper borrowed"
  assert exec.close_pool(pool, waiting: 20) == Error(exec.RetirementPending)
  assert exec.checkout(pool, waiting: 1000) == Error(exec.PoolUnavailable)
  assert process.is_alive(exec.pool_pid(pool))
  assert process.is_alive(exec.pid(helper))
  process.send(exec.wire(helper), exec.WireClosed(0))
  assert exec.close_pool(pool, waiting: 1000) == Ok(Nil)
}

pub fn pool_native_failure_retains_capacity_test() {
  let assert Ok(pool) =
    exec.start_pool(size: 1, spawn: fn() {
      Ok(fake_helper.start_helper(fake_helper.EchoArgv))
    })
    as "pool starts"
  let assert Ok(helper) = exec.checkout(pool, waiting: 1000)
    as "helper borrowed"
  process.send(exec.wire(helper), exec.WireClosed(137))
  exec.checkin(pool, helper)
  assert exec.checkout(pool, waiting: 1000) == Error(exec.AllBusy(1))
  assert exec.close_pool(pool, waiting: 1000) == Error(exec.RetirementExit(137))
}

pub fn shutdown_body_requires_an_empty_map_test() {
  let payload =
    msgpack.MapValue([
      #(msgpack.StringValue("v"), msgpack.IntValue(1)),
      #(msgpack.StringValue("id"), msgpack.IntValue(0)),
      #(msgpack.StringValue("kind"), msgpack.StringValue("shutdown")),
      #(
        msgpack.StringValue("body"),
        msgpack.MapValue([
          #(msgpack.StringValue("unexpected"), msgpack.IntValue(1)),
        ]),
      ),
    ])
  let assert Ok(bytes) = msgpack.encode(payload) as "payload encodes"
  let assert Error(_) = framing.decode_payload(bytes)
    as "shutdown rejects fields"
}

pub fn prepared_helper_has_no_acquisition_before_begin_test() {
  let acquired = process.new_subject()
  let config =
    exec.default_config(
      exec.DeferredTransport(fn() {
        process.send(acquired, Nil)
        Ok(exec.ChannelTransport(send: fn(_) { Nil }, close: fn() { Nil }))
      }),
    )
  let assert Ok(helper) = exec.prepare(config) as "parked owner starts"
  assert process.receive(acquired, 0) == Error(Nil)
  exec.begin(helper)
  exec.begin(helper)
  assert process.receive(acquired, 1000) == Ok(Nil)
  let assert Ok(hello) =
    framing.encode(framing.Frame(
      id: 1,
      body: framing.Hello(proto: 1, peer: "exec-helper", features: []),
    ))
    as "hello encodes"
  process.send(exec.wire(helper), exec.WireBytes(hello))
  assert exec.await_ready(helper, waiting: 1000) == Ok([])
  assert process.receive(acquired, 0) == Error(Nil)
  process.send(exec.wire(helper), exec.WireClosed(0))
  assert exec.close(helper, waiting: 1000) == Ok(Nil)
}

pub fn prepared_helper_close_never_acquires_transport_test() {
  let acquired = process.new_subject()
  let config =
    exec.default_config(
      exec.DeferredTransport(fn() {
        process.send(acquired, Nil)
        Error("must not acquire")
      }),
    )
  let assert Ok(helper) = exec.prepare(config) as "parked owner starts"
  assert exec.close(helper, waiting: 1000) == Ok(Nil)
  assert process.receive(acquired, 0) == Error(Nil)
  assert !process.is_alive(exec.pid(helper))
}

pub fn prepared_helper_stops_when_preparer_exits_normally_test() {
  let acquired = process.new_subject()
  let ready = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let finish = process.new_subject()
      let config =
        exec.default_config(
          exec.DeferredTransport(fn() {
            process.send(acquired, Nil)
            Error("must not acquire")
          }),
        )
      let assert Ok(helper) = exec.prepare(config) as "parked owner starts"
      process.send(ready, #(helper, finish))
      let assert Ok(Nil) = process.receive(finish, 1000)
        as "test releases the preparer"
      Nil
    })
  let assert Ok(#(helper, finish)) = process.receive(ready, 1000)
    as "preparer publishes its parked helper"
  let monitor = process.monitor(exec.pid(helper))
  process.send(finish, Nil)
  assert_helper_stopped(monitor)
  assert process.receive(acquired, 0) == Error(Nil)

  // Only the live owner can attest that no transport was acquired. Its
  // normal exit is a lifetime bound, not a replacement retirement witness.
  assert exec.close(helper, waiting: 1000) == Error(exec.RetirementOwnerGone)
}

pub fn active_helper_parent_exit_is_not_retirement_proof_test() {
  let ready = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let finish = process.new_subject()
      let #(helper, _, _) = controlled()
      process.send(ready, #(helper, finish))
      let assert Ok(Nil) = process.receive(finish, 1000)
        as "test releases the active helper's parent"
      Nil
    })
  let assert Ok(#(helper, finish)) = process.receive(ready, 1000)
    as "parent publishes its active helper"
  let monitor = process.monitor(exec.pid(helper))
  process.send(finish, Nil)
  assert_helper_stopped(monitor)
  assert exec.close(helper, waiting: 1000) == Error(exec.RetirementOwnerGone)
}

fn assert_helper_stopped(monitor: process.Monitor) -> Nil {
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(1000)
    as "helper follows its preparer's normal exit"
  Nil
}

pub fn prepared_pool_acquisition_failure_has_no_native_resource_test() {
  let owners = process.new_subject()
  let assert Ok(pool) =
    exec.start_pool(size: 1, spawn: fn() {
      let config =
        exec.default_config(
          exec.DeferredTransport(fn() {
            Error("acquisition refused before opening any port")
          }),
        )
      let assert Ok(helper) = exec.prepare(config) as "parked owner starts"
      process.send(owners, helper)
      Ok(helper)
    })
    as "pool starts"
  assert exec.checkout(pool, waiting: 1000)
    == Error(exec.SpawnFailed(exec.HandshakeFailed(exec.SendFailed)))
  assert exec.close_pool(pool, waiting: 1000) == Ok(Nil)
  let assert Ok(helper) = process.receive(owners, 1000)
    as "prepared helper was inventoried"
  assert !process.is_alive(exec.pid(helper))
}

pub fn prepared_pool_handshake_failure_keeps_acquired_owner_test() {
  let owners = process.new_subject()
  let assert Ok(pool) =
    exec.start_pool(size: 1, spawn: fn() {
      let config =
        exec.default_config(
          exec.ChannelTransport(send: fn(_) { Nil }, close: fn() { Nil }),
        )
      let assert Ok(helper) =
        exec.prepare(exec.HelperConfig(..config, handshake_timeout_ms: 20))
        as "parked owner starts"
      process.send(owners, helper)
      Ok(helper)
    })
    as "pool starts"
  assert exec.checkout(pool, waiting: 1000)
    == Error(exec.SpawnFailed(exec.HandshakeFailed(exec.HandshakeTimeout)))
  assert exec.checkout(pool, waiting: 1000) == Error(exec.AllBusy(1))
  assert exec.close_pool(pool, waiting: 1000) == Error(exec.RetirementProofLost)
  let assert Ok(helper) = process.receive(owners, 1000)
    as "failed owner is retained"
  assert process.is_alive(exec.pid(helper))
}

pub fn pool_helper_actor_death_is_unconfirmed_test() {
  let assert Ok(pool) =
    exec.start_pool(size: 1, spawn: fn() {
      Ok(fake_helper.start_helper(fake_helper.EchoArgv))
    })
    as "pool starts"
  let assert Ok(helper) = exec.checkout(pool, waiting: 1000)
    as "helper borrowed"
  process.kill(exec.pid(helper))
  assert exec.close_pool(pool, waiting: 1000) == Error(exec.RetirementOwnerGone)
  assert process.is_alive(exec.pool_pid(pool))
}

pub fn pool_actor_death_is_unconfirmed_test() {
  let assert Ok(pool) =
    exec.start_pool(size: 1, spawn: fn() {
      Ok(fake_helper.start_helper(fake_helper.EchoArgv))
    })
    as "pool starts"
  process.unlink(exec.pool_pid(pool))
  process.kill(exec.pool_pid(pool))
  assert exec.close_pool(pool, waiting: 1000) == Error(exec.RetirementOwnerGone)
}

pub fn duplicate_checkin_does_not_lend_one_helper_twice_test() {
  let assert Ok(pool) =
    exec.start_pool(size: 1, spawn: fn() {
      Ok(fake_helper.start_helper(fake_helper.EchoArgv))
    })
    as "pool starts"
  let assert Ok(helper) = exec.checkout(pool, waiting: 1000)
    as "helper borrowed"
  exec.checkin(pool, helper)
  exec.checkin(pool, helper)
  let assert Ok(_) = exec.checkout(pool, waiting: 1000)
    as "one checkin makes one slot available"
  assert exec.checkout(pool, waiting: 1000) == Error(exec.AllBusy(1))
  assert exec.close_pool(pool, waiting: 1000) == Ok(Nil)
}
