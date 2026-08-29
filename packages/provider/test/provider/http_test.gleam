//// Production HTTP transport ownership tests.

import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/string
import provider/http

@external(erlang, "provider_http_test_ffi", "start_hanging_server")
fn start_hanging_server(
  on_accepted: fn() -> Nil,
  on_closed: fn() -> Nil,
) -> #(Int, Pid)

@external(erlang, "provider_http_test_ffi", "start_malformed_server")
fn start_malformed_server() -> #(Int, Pid)

@external(erlang, "erlang", "suspend_process")
fn suspend_process(pid: Pid) -> Bool

pub fn production_cancel_retires_owner_and_closes_socket_test() {
  let accepted = process.new_subject()
  let closed = process.new_subject()
  let events = process.new_subject()
  let #(port, server) =
    start_hanging_server(fn() { process.send(accepted, Nil) }, fn() {
      process.send(closed, Nil)
    })
  let http.Transport(start_streaming:) = http.httpc_transport()
  let assert Ok(running) =
    start_streaming(
      http.HttpRequest(
        method: "GET",
        url: "http://127.0.0.1:" <> int.to_string(port) <> "/",
        headers: [],
        body: "",
      ),
      events,
    )
    as "the production transport owner must start"
  let owner_monitor = process.monitor(http.owner(running))
  let server_monitor = process.monitor(server)
  let assert Ok(Nil) = process.receive(accepted, within: 2000)
    as "the loopback peer must accept the production request"

  assert suspend_process(http.owner(running))
  http.cancel(running)

  let assert Ok(True) =
    process.new_selector()
    |> process.select_specific_monitor(owner_monitor, fn(_down) { True })
    |> process.selector_receive(2000)
    as "cancellation must retire the transport owner"
  let assert Ok(Nil) = process.receive(closed, within: 2000)
    as "httpc cancellation must close the active loopback request"
  let assert Ok(True) =
    process.new_selector()
    |> process.select_specific_monitor(server_monitor, fn(_down) { True })
    |> process.selector_receive(2000)
    as "the loopback peer must retire after observing socket closure"
  assert process.receive(events, within: 20) == Error(Nil)
}

pub fn production_transport_redacts_raw_httpc_errors_test() {
  let #(port, server) = start_malformed_server()
  let events = process.new_subject()
  let http.Transport(start_streaming:) = http.httpc_transport()
  let assert Ok(running) =
    start_streaming(
      http.HttpRequest(
        method: "GET",
        url: "http://127.0.0.1:" <> int.to_string(port) <> "/",
        headers: [#("authorization", "Bearer SECRET_TOKEN")],
        body: "",
      ),
      events,
    )
  let assert Ok(http.RequestFailed(reason:)) =
    process.receive(events, within: 2000)
    as "the malformed peer response must fail the production transport"
  assert reason == "http transport failed"
  assert !string.contains(reason, "SECRET_TOKEN")
  let server_monitor = process.monitor(server)
  let assert Ok(True) =
    process.new_selector()
    |> process.select_specific_monitor(server_monitor, fn(_down) { True })
    |> process.selector_receive(2000)
  http.cancel(running)
}
