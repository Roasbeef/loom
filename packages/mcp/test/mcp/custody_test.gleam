//// Staged startup and retirement evidence through the production client.
//// A close request and a native-close event are separate test inputs so an
//// owner cannot pass by treating its own cancellation request as completion.

import gleam/erlang/process
import mcp/client
import mcp/transport

pub fn preparation_has_no_transport_effects_test() {
  let opened = process.new_subject()
  let spec =
    transport.ChannelTransport(fn(inbound) {
      process.send(opened, inbound)
      transport.Connection(send: fn(_) { Ok(Nil) }, close: fn() { Nil })
    })
  let assert Ok(prepared) = client.prepare(spec) as "parked actor starts"
  assert process.receive(opened, 0) == Error(Nil)
  assert client.shutdown(prepared, within: 1000) == Ok(Nil)
  assert process.receive(opened, 0) == Error(Nil)
}

pub fn dead_owner_is_not_no_resource_proof_test() {
  let spec = transport.PortTransport(transport.spawn("/nonexistent/mcp", []))
  let assert Ok(prepared) = client.prepare(spec) as "preparation does not spawn"
  let watch = process.monitor(client.pid(prepared))
  process.kill(client.pid(prepared))
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down })
    |> process.selector_receive(1000)
    as "the killed owner exits"
  assert client.shutdown(prepared, within: 1000)
    == Error(client.RetirementUnconfirmed)
}

pub fn startup_refusal_retains_native_cleanup_until_exit_test() {
  let opened = process.new_subject()
  let requested = process.new_subject()
  let outcomes = process.new_subject()
  let spec =
    transport.ChannelTransport(fn(inbound) {
      process.send(opened, inbound)
      transport.Connection(send: fn(_) { Ok(Nil) }, close: fn() {
        process.send(requested, Nil)
      })
    })
  let assert Ok(prepared) = client.prepare(spec) as "parked actor starts"
  let original_watch = process.monitor(client.pid(prepared))
  let _ =
    process.spawn_unlinked(fn() {
      process.send(
        outcomes,
        client.connect(
          prepared,
          client.options("test") |> client.with_handshake_timeout(20),
        ),
      )
    })
  let assert Ok(inbound) = process.receive(opened, 1000)
    as "begin opens the published transport"
  let assert Ok(Error(client.HandshakeFailed(_))) =
    process.receive(outcomes, 1000)
    as "a silent handshake refuses without dropping custody"
  let assert Ok(Nil) = process.receive(requested, 1000)
    as "refusal requests transport termination"
  assert client.shutdown(prepared, within: 10)
    == Error(client.RetirementTimedOut)
  let down_selector =
    process.new_selector()
    |> process.select_specific_monitor(original_watch, fn(down) { down })
  assert process.selector_receive(down_selector, 0) == Error(Nil)

  // Even after the reporting deadline, the owner keeps its exact transport
  // and can finish the already-requested retirement when native exit arrives.
  process.send(inbound, transport.TransportClosed("selected native exit"))
  let assert Ok(process.ProcessDown(reason: process.Normal, ..)) =
    process.selector_receive(down_selector, 1000)
    as "native exit permits the original owner to retire normally"
}

pub fn failed_spawn_has_explicit_no_native_resource_proof_test() {
  let assert Ok(prepared) =
    client.prepare(
      transport.PortTransport(transport.spawn("/nonexistent/mcp", [])),
    )
    as "preparation only allocates an actor"
  let assert Error(client.TransportFailed(_)) =
    client.connect(prepared, client.options("test"))
    as "begin reports the absent executable"
  assert client.shutdown(prepared, within: 1000) == Ok(Nil)
}

pub fn published_parked_client_survives_builder_loss_test() {
  let custody = process.self()
  let published = process.new_subject()
  let opened = process.new_subject()
  let builder =
    process.spawn_unlinked(fn() {
      let spec =
        transport.ChannelTransport(fn(inbound) {
          process.send(opened, inbound)
          transport.Connection(send: fn(_) { Ok(Nil) }, close: fn() { Nil })
        })
      let assert Ok(prepared) = client.prepare_owned(spec, custody)
        as "prepare allocates only the owned actor"
      process.send(published, prepared)
      process.sleep_forever()
    })
  let assert Ok(prepared) = process.receive(published, 1000)
    as "the custodian receives cleanup before any transport starts"
  process.kill(builder)

  // The actor may see builder DOWN before or after this request. Either
  // ordering must return explicit no-resource proof rather than bare death.
  assert client.shutdown(prepared, within: 1000) == Ok(Nil)
  assert process.receive(opened, 0) == Error(Nil)
}

pub fn unclaimed_parked_client_stops_when_custodian_dies_test() {
  let published = process.new_subject()
  let custodian = process.spawn_unlinked(fn() { process.sleep_forever() })
  let builder =
    process.spawn_unlinked(fn() {
      let assert Ok(prepared) =
        client.prepare_owned(
          transport.PortTransport(transport.spawn("/nonexistent/mcp", [])),
          custodian,
        )
        as "prepare does not execute the absent binary"
      process.send(published, prepared)
      process.sleep_forever()
    })
  let assert Ok(prepared) = process.receive(published, 1000)
    as "the test receives the parked handle"
  let watch = process.monitor(client.pid(prepared))
  process.kill(builder)
  process.kill(custodian)
  let assert Ok(process.ProcessDown(reason: process.Normal, ..)) =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down })
    |> process.selector_receive(1000)
    as "an unclaimed no-resource actor does not remain orphaned"
}

pub fn active_client_keeps_native_custody_after_custodian_loss_test() {
  let opened = process.new_subject()
  let custodian = process.spawn_unlinked(fn() { process.sleep_forever() })
  let spec =
    transport.ChannelTransport(fn(inbound) {
      process.send(opened, inbound)
      transport.Connection(send: fn(_) { Ok(Nil) }, close: fn() { Nil })
    })
  let assert Ok(prepared) = client.prepare_owned(spec, custodian)
    as "the native owner starts before transport admission"
  let assert Error(client.HandshakeFailed(_)) =
    client.connect(
      prepared,
      client.options("test") |> client.with_handshake_timeout(1),
    )
    as "the silent peer refuses startup"
  let assert Ok(inbound) = process.receive(opened, 1000)
    as "the native-close event remains controlled by the transport"
  let watch = process.monitor(client.pid(prepared))
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down })
  process.kill(custodian)
  assert process.selector_receive(selector, 20) == Error(Nil)
  process.send(inbound, transport.TransportClosed("selected native exit"))
  let assert Ok(process.ProcessDown(reason: process.Normal, ..)) =
    process.selector_receive(selector, 1000)
    as "lost custody does not replace actual native retirement"
}
