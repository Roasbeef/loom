//// Production HTTP transport ownership tests.

import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/list
import gleam/string
import provider/http

@external(erlang, "provider_http_test_ffi", "start_hanging_server")
fn start_hanging_server(
  on_accepted: fn() -> Nil,
  on_closed: fn() -> Nil,
) -> #(Int, Pid)

@external(erlang, "provider_http_test_ffi", "start_malformed_server")
fn start_malformed_server() -> #(Int, Pid)

@external(erlang, "provider_http_test_ffi", "start_redirect_pair")
fn start_redirect_pair(on_target_accepted: fn() -> Nil) -> #(Int, List(Pid))

@external(erlang, "provider_http_test_ffi", "stop_servers")
fn stop_servers(servers: List(Pid)) -> Nil

@external(erlang, "provider_http_test_ffi", "suspend_active_handlers")
fn suspend_active_handlers() -> List(Pid)

@external(erlang, "provider_http_test_ffi", "resume_handlers")
fn resume_handlers(handlers: List(Pid)) -> Nil

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
  let handlers = suspend_active_handlers()
  assert !list.is_empty(handlers)

  http.cancel(running)

  process.sleep(50)
  assert process.is_alive(http.owner(running))
    as "the custodian must wait for native handler acknowledgement"
  assert process.receive(closed, within: 20) == Error(Nil)
  resume_handlers(handlers)

  let assert Ok(Nil) = process.receive(closed, within: 2000)
    as "httpc cancellation must close the active loopback request"
  let assert Ok(True) =
    process.new_selector()
    |> process.select_specific_monitor(owner_monitor, fn(_down) { True })
    |> process.selector_receive(2000)
    as "the transport owner must retire only after native closure"
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

pub fn production_cancel_never_follows_a_redirect_to_hanging_peer_test() {
  let target_accepted = process.new_subject()
  let #(port, servers) =
    start_redirect_pair(fn() { process.send(target_accepted, Nil) })
  let events = process.new_subject()
  let http.Transport(start_streaming:) = http.httpc_transport()
  let assert Ok(running) =
    start_streaming(
      http.HttpRequest(
        method: "GET",
        url: "http://127.0.0.1:" <> int.to_string(port) <> "/redirect",
        headers: [],
        body: "",
      ),
      events,
    )
  let owner_monitor = process.monitor(http.owner(running))
  let assert Ok(http.ResponseStatus(status: 302, ..)) =
    process.receive(events, within: 2000)
    as "the redirect must be returned instead of migrated to a new handler"

  http.cancel(running)

  assert process.receive(target_accepted, within: 100) == Error(Nil)
    as "the production transport must not open the redirect target socket"
  let assert Ok(True) =
    process.new_selector()
    |> process.select_specific_monitor(owner_monitor, fn(_down) { True })
    |> process.selector_receive(2000)
  stop_servers(servers)
}
