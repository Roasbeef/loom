//// Production HTTP transport ownership tests.
////
//// Loopback peers make socket closure observable without using an external
//// network. Cancellation temporarily suspends only the handler linked to the
//// request's native owner: while that handler cannot acknowledge exit, the
//// public owner must remain alive. A second test freezes the owner during a
//// response callback and kills it, proving the callback tears down the handler
//// even though OTP catches ordinary callback exits. Both paths require socket
//// closure before the lifecycle is considered drained.

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

@external(erlang, "provider_http_test_ffi", "start_owner_death_server")
fn start_owner_death_server(
  on_accepted: fn() -> Nil,
  on_closed: fn() -> Nil,
) -> #(Int, Pid)

@external(erlang, "provider_http_test_ffi", "start_malformed_server")
fn start_malformed_server() -> #(Int, Pid)

@external(erlang, "provider_http_test_ffi", "start_fast_server")
fn start_fast_server() -> #(Int, Pid)

@external(erlang, "provider_http_test_ffi", "start_redirect_pair")
fn start_redirect_pair(on_target_accepted: fn() -> Nil) -> #(Int, List(Pid))

@external(erlang, "provider_http_test_ffi", "stop_servers")
fn stop_servers(servers: List(Pid)) -> Nil

@external(erlang, "provider_http_test_ffi", "with_suspended_request_handlers")
fn with_suspended_request_handlers(
  owner: Pid,
  check: fn(List(Pid)) -> Nil,
) -> Nil

@external(erlang, "provider_http_test_ffi", "await_owner_drain_wait")
fn await_owner_drain_wait(owner: Pid) -> Nil

@external(erlang, "provider_http_test_ffi", "kill_owner_during_delivery")
fn kill_owner_during_delivery(owner: Pid, server: Pid) -> Nil

@external(erlang, "provider_http_test_ffi", "restart_httpc_manager")
fn restart_httpc_manager() -> Nil

@external(erlang, "provider_http_test_ffi", "restart_httpc_handler_supervisor")
fn restart_httpc_handler_supervisor() -> Nil

pub fn production_cancel_retires_owner_and_closes_socket_test() {
  let accepted = process.new_subject()
  let closed = process.new_subject()
  let events = process.new_subject()
  let #(port, server) =
    start_hanging_server(fn() { process.send(accepted, Nil) }, fn() {
      process.send(closed, Nil)
    })
  let http.Transport(prepare_streaming:) = http.httpc_transport()
  let assert Ok(http.PreparedRequest(running:, begin:)) =
    prepare_streaming(
      http.HttpRequest(
        method: "GET",
        url: "http://127.0.0.1:" <> int.to_string(port) <> "/",
        headers: [],
        body: "",
      ),
      events,
    )
    as "the production transport owner must start"
  begin()
  let owner_monitor = process.monitor(http.owner(running))
  let server_monitor = process.monitor(server)
  let assert Ok(Nil) = process.receive(accepted, within: 2000)
    as "the loopback peer must accept the production request"
  with_suspended_request_handlers(http.owner(running), fn(handlers) {
    assert !list.is_empty(handlers)
    http.cancel(running)
    await_owner_drain_wait(http.owner(running))
    assert process.is_alive(http.owner(running))
      as "the native owner must wait for handler acknowledgement"
    assert process.receive(closed, within: 20) == Error(Nil)
  })

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

pub fn production_fast_terminal_preserves_normal_drain_reason_test() {
  let #(port, server) = start_fast_server()
  let events = process.new_subject()
  let http.Transport(prepare_streaming:) = http.httpc_transport()
  let assert Ok(http.PreparedRequest(running:, begin:)) =
    prepare_streaming(
      http.HttpRequest(
        method: "GET",
        url: "http://127.0.0.1:" <> int.to_string(port) <> "/",
        headers: [],
        body: "",
      ),
      events,
    )
  let owner_monitor = process.monitor(http.owner(running))
  begin()

  let assert Ok(http.ResponseStatus(status: 200, ..)) =
    process.receive(events, within: 2000)
  assert process.receive(events, within: 2000) == Ok(http.ResponseChunk(<<>>))
  assert process.receive(events, within: 2000) == Ok(http.ResponseEnd)
  let assert Ok(process.ProcessDown(reason: process.Normal, ..)) =
    process.new_selector()
    |> process.select_specific_monitor(owner_monitor, fn(down) { down })
    |> process.selector_receive(2000)
    as "a fast terminal must retain the exact handler drain proof"
  stop_servers([server])
}

pub fn production_owner_death_during_delivery_closes_socket_test() {
  let accepted = process.new_subject()
  let closed = process.new_subject()
  let events = process.new_subject()
  let #(port, server) =
    start_owner_death_server(fn() { process.send(accepted, Nil) }, fn() {
      process.send(closed, Nil)
    })
  let http.Transport(prepare_streaming:) = http.httpc_transport()
  let assert Ok(http.PreparedRequest(running:, begin:)) =
    prepare_streaming(
      http.HttpRequest(
        method: "GET",
        url: "http://127.0.0.1:" <> int.to_string(port) <> "/",
        headers: [],
        body: "",
      ),
      events,
    )
  let owner_monitor = process.monitor(http.owner(running))
  let server_monitor = process.monitor(server)
  begin()
  let assert Ok(Nil) = process.receive(accepted, within: 2000)

  kill_owner_during_delivery(http.owner(running), server)

  let assert Ok(process.ProcessDown(reason: process.Killed, ..)) =
    process.new_selector()
    |> process.select_specific_monitor(owner_monitor, fn(down) { down })
    |> process.selector_receive(2000)
  let assert Ok(Nil) = process.receive(closed, within: 2000)
    as "owner death inside the response callback must close the handler socket"
  let assert Ok(True) =
    process.new_selector()
    |> process.select_specific_monitor(server_monitor, fn(_down) { True })
    |> process.selector_receive(2000)
}

/// Replacing `httpc_manager` must not erase the handler which still owns this
/// request's socket. The native owner addresses the captured handler directly
/// and remains alive until that exact process acknowledges termination.
pub fn production_cancel_survives_httpc_manager_restart_test() {
  let accepted = process.new_subject()
  let closed = process.new_subject()
  let events = process.new_subject()
  let #(port, server) =
    start_hanging_server(fn() { process.send(accepted, Nil) }, fn() {
      process.send(closed, Nil)
    })
  let http.Transport(prepare_streaming:) = http.httpc_transport()
  let assert Ok(http.PreparedRequest(running:, begin:)) =
    prepare_streaming(
      http.HttpRequest(
        method: "GET",
        url: "http://127.0.0.1:" <> int.to_string(port) <> "/",
        headers: [],
        body: "",
      ),
      events,
    )
  begin()
  let assert Ok(Nil) = process.receive(accepted, within: 2000)
  let owner_monitor = process.monitor(http.owner(running))
  with_suspended_request_handlers(http.owner(running), fn(handlers) {
    assert !list.is_empty(handlers)
    restart_httpc_manager()
    http.cancel(running)
    process.sleep(50)
    assert process.is_alive(http.owner(running))
      as "manager replacement cannot stand in for handler drain"
  })

  let assert Ok(Nil) = process.receive(closed, within: 2000)
  let assert Ok(True) =
    process.new_selector()
    |> process.select_specific_monitor(owner_monitor, fn(_down) { True })
    |> process.selector_receive(2000)
  stop_servers([server])
}

/// Replacing `httpc_handler_sup` must not hide an already-captured handler.
/// Cancellation addresses the retained PID rather than consulting the
/// replacement supervisor's empty child set.
pub fn production_cancel_survives_handler_supervisor_restart_test() {
  let accepted = process.new_subject()
  let closed = process.new_subject()
  let events = process.new_subject()
  let #(port, server) =
    start_hanging_server(fn() { process.send(accepted, Nil) }, fn() {
      process.send(closed, Nil)
    })
  let http.Transport(prepare_streaming:) = http.httpc_transport()
  let assert Ok(http.PreparedRequest(running:, begin:)) =
    prepare_streaming(
      http.HttpRequest(
        method: "GET",
        url: "http://127.0.0.1:" <> int.to_string(port) <> "/",
        headers: [],
        body: "",
      ),
      events,
    )
  begin()
  let assert Ok(Nil) = process.receive(accepted, within: 2000)
  let owner_monitor = process.monitor(http.owner(running))
  with_suspended_request_handlers(http.owner(running), fn(handlers) {
    assert !list.is_empty(handlers)
    restart_httpc_handler_supervisor()
    http.cancel(running)
    process.sleep(50)
    assert process.is_alive(http.owner(running))
      as "supervisor replacement cannot stand in for handler drain"
  })

  let assert Ok(Nil) = process.receive(closed, within: 2000)
  let assert Ok(True) =
    process.new_selector()
    |> process.select_specific_monitor(owner_monitor, fn(_down) { True })
    |> process.selector_receive(2000)
  stop_servers([server])
}

/// A busy handler for another request cannot delay ownership capture.
///
/// The first handler is suspended while the second request starts and stops.
/// Direct request-ID lookup must therefore avoid touching the unrelated
/// process entirely.
pub fn production_handler_capture_ignores_busy_unrelated_handler_test() {
  let first_accepted = process.new_subject()
  let first_closed = process.new_subject()
  let second_accepted = process.new_subject()
  let second_closed = process.new_subject()
  let #(first_port, first_server) =
    start_hanging_server(fn() { process.send(first_accepted, Nil) }, fn() {
      process.send(first_closed, Nil)
    })
  let #(second_port, second_server) =
    start_hanging_server(fn() { process.send(second_accepted, Nil) }, fn() {
      process.send(second_closed, Nil)
    })
  let http.Transport(prepare_streaming:) = http.httpc_transport()
  let assert Ok(http.PreparedRequest(running: first, begin: begin_first)) =
    prepare_streaming(
      http.HttpRequest(
        method: "GET",
        url: "http://127.0.0.1:" <> int.to_string(first_port) <> "/",
        headers: [],
        body: "",
      ),
      process.new_subject(),
    )
  begin_first()
  let assert Ok(Nil) = process.receive(first_accepted, within: 2000)

  with_suspended_request_handlers(http.owner(first), fn(handlers) {
    assert !list.is_empty(handlers)
    let assert Ok(http.PreparedRequest(running: second, begin: begin_second)) =
      prepare_streaming(
        http.HttpRequest(
          method: "GET",
          url: "http://127.0.0.1:" <> int.to_string(second_port) <> "/",
          headers: [],
          body: "",
        ),
        process.new_subject(),
      )
    begin_second()
    let assert Ok(Nil) = process.receive(second_accepted, within: 2000)
    let second_monitor = process.monitor(http.owner(second))

    http.cancel(second)

    let assert Ok(Nil) = process.receive(second_closed, within: 2000)
      as "a busy unrelated handler must not block exact request cancellation"
    let assert Ok(True) =
      process.new_selector()
      |> process.select_specific_monitor(second_monitor, fn(_down) { True })
      |> process.selector_receive(2000)
      as "exact handler cancellation must finish while another handler is busy"
    Nil
  })

  http.cancel(first)
  let assert Ok(Nil) = process.receive(first_closed, within: 2000)
  stop_servers([first_server, second_server])
}

pub fn production_transport_redacts_raw_httpc_errors_test() {
  let #(port, server) = start_malformed_server()
  let events = process.new_subject()
  let http.Transport(prepare_streaming:) = http.httpc_transport()
  let assert Ok(http.PreparedRequest(running:, begin:)) =
    prepare_streaming(
      http.HttpRequest(
        method: "GET",
        url: "http://127.0.0.1:" <> int.to_string(port) <> "/",
        headers: [#("authorization", "Bearer SECRET_TOKEN")],
        body: "",
      ),
      events,
    )
  begin()
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
  let http.Transport(prepare_streaming:) = http.httpc_transport()
  let assert Ok(http.PreparedRequest(running:, begin:)) =
    prepare_streaming(
      http.HttpRequest(
        method: "GET",
        url: "http://127.0.0.1:" <> int.to_string(port) <> "/redirect",
        headers: [],
        body: "",
      ),
      events,
    )
  begin()
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
