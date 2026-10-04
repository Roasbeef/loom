//// Real ephemeral mTLS fixtures exercise the production primitive and hostile
//// frames without a fake socket or insecure production escape. Every listener
//// uses an ephemeral port and each test creates its own CA and keys.

import executor/remote/tls
import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/result
import gleam/string

pub type Credentials {
  Credentials(ca: BitArray, certificate: BitArray, key: BitArray, pin: BitArray)
}

pub type Fixture {
  Fixture(
    server: Credentials,
    client: Credentials,
    wrong_server: Credentials,
    wrong_client: Credentials,
    foreign: Credentials,
    expired: Credentials,
  )
}

/// Reuses ephemeral real mTLS credentials across executor component regressions.
///
/// ## Examples
///
/// `fixture()` mints a separate CA and leaf keys for each test.
@external(erlang, "executor_remote_tls_test_ffi", "fixture")
pub fn fixture() -> Fixture

@external(erlang, "executor_remote_tls_test_ffi", "raw_send")
fn raw_send(connection: tls.Connection, bytes: BitArray) -> Result(Nil, Nil)

@external(erlang, "executor_remote_tls_test_ffi", "missing_certificate")
fn missing_certificate(ca: BitArray, port: Int) -> Result(Nil, Nil)

type TcpSocket

@external(erlang, "executor_remote_tls_test_ffi", "tcp_connect")
fn tcp_connect(port: Int) -> Result(TcpSocket, Nil)

@external(erlang, "executor_remote_tls_test_ffi", "tcp_close")
fn tcp_close(socket: TcpSocket) -> Nil

// Test-only instrumentation runs the public connect path in a separate VM;
// the production node and its callers never load the instrumented module.
@external(erlang, "executor_remote_tls_test_ffi", "connect_deadline")
fn connect_deadline(
  connect: fn(Int) -> Result(tls.Connection, tls.Error),
) -> Result(Nil, Nil)

fn settings(
  local: Credentials,
  peer: Credentials,
  frame_ms: Int,
) -> tls.Settings {
  let assert Ok(settings) =
    tls.settings(
      local.ca,
      local.certificate,
      local.key,
      peer.pin,
      2000,
      frame_ms,
      200,
    )
    as "Fixture credentials must parse."
  settings
}

fn reader(
  server: tls.Settings,
) -> #(tls.Listener, Int, process.Subject(Result(BitArray, tls.Error))) {
  let assert Ok(listener) = tls.listen(server, tls.Loopback, 0)
    as "Real TLS loopback must listen; sandbox denial is a failure."
  let assert Ok(port) = tls.port(listener) as "Listener must have a port."
  let done = process.new_subject()
  let _pid =
    process.spawn_unlinked(fn() {
      let outcome = {
        use connection <- result.try(tls.accept(listener))
        let body = tls.receive(connection)
        tls.close(connection)
        body
      }
      process.send(done, outcome)
    })
  #(listener, port, done)
}

fn finish(
  listener: tls.Listener,
  done: process.Subject(Result(BitArray, tls.Error)),
) -> Result(BitArray, tls.Error) {
  let assert Ok(outcome) = process.receive(done, 3000)
    as "Server readiness and completion remain bounded."
  tls.close_listener(listener)
  tls.close_listener(listener)
  outcome
}

pub fn remote_tls_binary_roundtrip_and_authenticated_pins_test() {
  let f = fixture()
  let assert Ok(Nil) = tls.start() as "SSL starts explicitly at boot."
  let server = settings(f.server, f.client, 1000)
  let client = settings(f.client, f.server, 1000)
  let assert Ok(listener) = tls.listen(server, tls.Loopback, 0) as "Listen."
  let assert Ok(port) = tls.port(listener) as "Port."
  let done = process.new_subject()
  let body = <<0, 255, 0, 128, 42>>
  let _pid =
    process.spawn_unlinked(fn() {
      let assert Ok(connection) = tls.accept(listener) as "Authenticate client."
      assert tls.peer_pin(connection) == f.client.pin
      let assert Ok(received) = tls.receive(connection) as "Read binary body."
      assert received == body
      let assert Ok(Nil) = tls.send(connection, received) as "Echo binary body."
      tls.close(connection)
      process.send(done, Nil)
    })
  let assert Ok(connection) = tls.connect(client, "localhost", port)
    as "Authenticate server."
  assert tls.peer_pin(connection) == f.server.pin
  assert tls.send(connection, <<>>) == Error(tls.InvalidFrame)
  assert tls.send(connection, <<1:size(1)>>) == Error(tls.InvalidFrame)
  let large = bit_array.from_string(string.repeat("x", tls.max_frame_bytes + 1))
  assert tls.send(connection, large) == Error(tls.FrameTooLarge)
  assert tls.send(connection, body) == Ok(Nil)
  assert tls.receive(connection) == Ok(body)
  tls.close(connection)
  tls.close(connection)
  let assert Ok(Nil) = process.receive(done, 3000) as "Echo completed."
  tls.close_listener(listener)
}

pub fn remote_tls_wrong_same_ca_client_rejected_before_application_frame_test() {
  let f = fixture()
  let #(listener, port, done) = reader(settings(f.server, f.client, 1000))
  // TLS 1.3 may publish the client socket before its authentication is rejected
  // by the server; the server must never publish an application body.
  case
    tls.connect(settings(f.wrong_client, f.server, 1000), "localhost", port)
  {
    Ok(connection) -> {
      let _attempt = raw_send(connection, <<0, 0, 0, 1, 42>>)
      tls.close(connection)
    }
    Error(_) -> Nil
  }
  assert finish(listener, done) == Error(tls.AuthenticationFailed)
}

pub fn remote_tls_wrong_same_ca_server_rejected_test() {
  let f = fixture()
  let #(listener, port, done) = reader(settings(f.wrong_server, f.client, 1000))
  assert tls.connect(settings(f.client, f.server, 1000), "localhost", port)
    == Error(tls.AuthenticationFailed)
  assert finish(listener, done) |> result.is_error
}

pub fn remote_tls_foreign_ca_client_rejected_before_frame_test() {
  let f = fixture()
  let #(listener, port, done) = reader(settings(f.server, f.foreign, 1000))
  let assert Ok(client) =
    tls.settings(
      f.server.ca,
      f.foreign.certificate,
      f.foreign.key,
      f.server.pin,
      2000,
      1000,
      200,
    )
    as "Foreign client trusts server CA."
  case tls.connect(client, "localhost", port) {
    Ok(connection) -> {
      let _attempt = raw_send(connection, <<0, 0, 0, 1, 42>>)
      tls.close(connection)
    }
    Error(_) -> Nil
  }
  assert finish(listener, done) == Error(tls.AuthenticationFailed)
}

pub fn remote_tls_foreign_ca_server_rejected_test() {
  let f = fixture()
  let assert Ok(server) =
    tls.settings(
      f.client.ca,
      f.foreign.certificate,
      f.foreign.key,
      f.client.pin,
      2000,
      1000,
      200,
    )
    as "Server trusts client CA."
  let #(listener, port, done) = reader(server)
  assert tls.connect(settings(f.client, f.foreign, 1000), "localhost", port)
    == Error(tls.AuthenticationFailed)
  assert finish(listener, done) |> result.is_error
}

pub fn remote_tls_missing_client_certificate_rejected_test() {
  let f = fixture()
  let #(listener, port, done) = reader(settings(f.server, f.client, 1000))
  assert missing_certificate(f.server.ca, port) == Ok(Nil)
  assert finish(listener, done) == Error(tls.AuthenticationFailed)
}

pub fn remote_tls_hostname_mismatch_rejected_test() {
  let f = fixture()
  let #(listener, port, done) = reader(settings(f.server, f.client, 1000))
  assert tls.connect(settings(f.client, f.server, 1000), "127.0.0.1", port)
    == Error(tls.AuthenticationFailed)
  assert finish(listener, done) |> result.is_error
}

pub fn remote_tls_expired_peer_rejected_test() {
  let f = fixture()
  let #(listener, port, done) = reader(settings(f.expired, f.client, 1000))
  assert tls.connect(settings(f.client, f.expired, 1000), "localhost", port)
    == Error(tls.AuthenticationFailed)
  assert finish(listener, done) |> result.is_error
}

pub fn remote_tls_fragmented_header_and_body_test() {
  let f = fixture()
  let #(listener, port, done) = reader(settings(f.server, f.client, 1000))
  let assert Ok(connection) =
    tls.connect(settings(f.client, f.server, 1000), "localhost", port)
    as "Verified connection."
  list.each([<<0>>, <<0>>, <<0>>, <<3>>, <<0>>, <<255>>, <<42>>], fn(fragment) {
    assert raw_send(connection, fragment) == Ok(Nil)
    process.sleep(10)
  })
  assert finish(listener, done) == Ok(<<0, 255, 42>>)
  tls.close(connection)
}

pub fn remote_tls_oversize_header_refused_without_body_test() {
  let f = fixture()
  let #(listener, port, done) = reader(settings(f.server, f.client, 1000))
  let assert Ok(connection) =
    tls.connect(settings(f.client, f.server, 1000), "localhost", port)
    as "Verified connection."
  assert raw_send(connection, <<262_145:size(32)>>) == Ok(Nil)
  assert finish(listener, done) == Error(tls.FrameTooLarge)
  assert tls.receive(connection) |> result.is_error
  tls.close(connection)
}

pub fn remote_tls_zero_length_frame_rejected_test() {
  let f = fixture()
  let #(listener, port, done) = reader(settings(f.server, f.client, 1000))
  let assert Ok(connection) =
    tls.connect(settings(f.client, f.server, 1000), "localhost", port)
    as "Verified connection."
  assert raw_send(connection, <<0:size(32)>>) == Ok(Nil)
  assert finish(listener, done) == Error(tls.InvalidFrame)
  tls.close(connection)
}

pub fn remote_tls_frame_deadline_is_cumulative_test() {
  let f = fixture()
  let #(listener, port, done) = reader(settings(f.server, f.client, 250))
  let assert Ok(connection) =
    tls.connect(settings(f.client, f.server, 1000), "localhost", port)
    as "Verified connection."
  // Prefix and body each arrive within 250 ms of the previous piece, but the
  // body arrives after the complete frame's budget, which cannot be renewed.
  process.sleep(160)
  assert raw_send(connection, <<1:size(32)>>) == Ok(Nil)
  process.sleep(160)
  let _late_body = raw_send(connection, <<42>>)
  assert finish(listener, done) == Error(tls.Timeout)
  tls.close(connection)
}

pub fn remote_tls_truncated_body_and_header_rejected_test() {
  let f = fixture()
  list.each([<<0, 0>>, <<4:size(32), 1, 2>>], fn(bytes) {
    let #(listener, port, done) = reader(settings(f.server, f.client, 1000))
    let assert Ok(connection) =
      tls.connect(settings(f.client, f.server, 1000), "localhost", port)
      as "Verified connection."
    assert raw_send(connection, bytes) == Ok(Nil)
    tls.close(connection)
    assert finish(listener, done) == Error(tls.Closed)
  })
}

pub fn remote_tls_settings_and_endpoint_bounds_test() {
  let f = fixture()
  assert tls.settings(
      <<>>,
      f.server.certificate,
      f.server.key,
      f.client.pin,
      2000,
      1000,
      200,
    )
    == Error(tls.InvalidSettings)
  assert tls.settings(
      f.server.ca,
      f.server.certificate,
      f.server.key,
      <<1>>,
      2000,
      1000,
      200,
    )
    == Error(tls.InvalidSettings)
  let large = bit_array.from_string(string.repeat("x", 16_385))
  assert tls.settings(
      large,
      f.server.certificate,
      f.server.key,
      f.client.pin,
      2000,
      1000,
      200,
    )
    == Error(tls.InvalidSettings)
  assert tls.settings(
      f.server.ca,
      <<42>>,
      f.server.key,
      f.client.pin,
      2000,
      1000,
      200,
    )
    == Error(tls.InvalidSettings)
  list.each([0, -1, 5001], fn(ms) {
    assert tls.settings(
        f.server.ca,
        f.server.certificate,
        f.server.key,
        f.client.pin,
        ms,
        1000,
        200,
      )
      == Error(tls.InvalidDeadline)
    assert tls.settings(
        f.server.ca,
        f.server.certificate,
        f.server.key,
        f.client.pin,
        2000,
        ms,
        200,
      )
      == Error(tls.InvalidDeadline)
  })
  assert tls.settings(
      f.server.ca,
      f.server.certificate,
      f.server.key,
      f.client.pin,
      2000,
      1000,
      1001,
    )
    == Error(tls.InvalidDeadline)
  let client = settings(f.client, f.server, 1000)
  list.each(["", "a\u{0}", "é", "a b", string.repeat("x", 254)], fn(name) {
    assert tls.connect(client, name, 443) == Error(tls.InvalidEndpoint)
  })
  list.each([-1, 65_536], fn(port) {
    assert tls.listen(client, tls.Loopback, port) == Error(tls.InvalidEndpoint)
  })
  assert tls.connect(client, "localhost", 0) == Error(tls.InvalidEndpoint)
}

pub fn remote_tls_explicit_ownership_transfer_test() {
  let f = fixture()
  let #(listener, port, done) = reader(settings(f.server, f.client, 1000))
  let assert Ok(connection) =
    tls.connect(settings(f.client, f.server, 1000), "localhost", port)
    as "Verified connection."
  let ready = process.new_subject()
  let confirmed = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let target = process.new_subject()
      process.send(ready, target)
      let assert Ok(connection) = process.receive(target, 2000)
        as "Wait for custody."
      assert tls.send(connection, <<42>>) == Ok(Nil)
      tls.close(connection)
      process.send(confirmed, Nil)
    })
  let assert Ok(target) = process.receive(ready, 2000) as "New owner is ready."
  assert tls.transfer(connection, owner) == Ok(Nil)
  process.send(target, connection)
  assert finish(listener, done) == Ok(<<42>>)
  let assert Ok(Nil) = process.receive(confirmed, 2000)
    as "New owner completed."
}

pub fn remote_tls_expired_client_rejected_before_frame_test() {
  let f = fixture()
  let #(listener, port, done) = reader(settings(f.server, f.expired, 1000))
  case tls.connect(settings(f.expired, f.server, 1000), "localhost", port) {
    Ok(connection) -> {
      let _attempt = raw_send(connection, <<0, 0, 0, 1, 42>>)
      tls.close(connection)
    }
    Error(_) -> Nil
  }
  assert finish(listener, done) == Error(tls.AuthenticationFailed)
}

pub fn remote_tls_maximum_body_boundary_test() {
  let f = fixture()
  let #(listener, port, done) = reader(settings(f.server, f.client, 1000))
  let assert Ok(connection) =
    tls.connect(settings(f.client, f.server, 1000), "localhost", port)
    as "Verified connection."
  let body = bit_array.from_string(string.repeat("x", tls.max_frame_bytes))
  assert tls.send(connection, body) == Ok(Nil)
  assert finish(listener, done) == Ok(body)
  tls.close(connection)
  assert tls.send(connection, <<42>>) |> result.is_error
  tls.close(connection)
}

pub fn remote_tls_accept_and_handshake_share_a_deadline_test() {
  let f = fixture()
  let assert Ok(server) =
    tls.settings(
      f.server.ca,
      f.server.certificate,
      f.server.key,
      f.client.pin,
      250,
      1000,
      200,
    )
    as "Short bounded handshake."
  let #(listener, port, done) = reader(server)
  // Delaying the TCP arrival consumes accept time; a peer which then stalls TLS
  // must use only the remainder, rather than gaining another full 250 ms.
  process.sleep(160)
  let assert Ok(socket) = tcp_connect(port) as "Real TCP connection."
  let assert Ok(outcome) = process.receive(done, 170)
    as "Accept and handshake cannot each receive a fresh budget."
  assert outcome == Error(tls.Timeout)
  tcp_close(socket)
  tls.close_listener(listener)
}

pub fn remote_tls_connect_and_handshake_share_a_deadline_test() {
  let f = fixture()
  let assert Ok(client) =
    tls.settings(
      f.client.ca,
      f.client.certificate,
      f.client.key,
      f.server.pin,
      400,
      1000,
      200,
    )
    as "Short bounded outbound handshake."

  // A real TCP socket is delayed before production receives it. The fixture
  // checks the actual SSL timeout argument and peer closure, not just elapsed
  // time after an immediate loopback connect. It also exhausts the TCP budget
  // to prove that an unupgraded raw socket is closed without beginning TLS.
  assert connect_deadline(fn(port) { tls.connect(client, "localhost", port) })
    == Ok(Nil)
}

pub fn remote_tls_prefix_deadline_closes_idle_connection_test() {
  let f = fixture()
  let #(listener, port, done) = reader(settings(f.server, f.client, 100))
  let assert Ok(connection) =
    tls.connect(settings(f.client, f.server, 1000), "localhost", port)
    as "Verified connection."
  assert finish(listener, done) == Error(tls.Timeout)
  assert tls.receive(connection) |> result.is_error
  tls.close(connection)
}

pub fn remote_tls_nonreading_peer_send_is_finite_and_closes_test() {
  let f = fixture()
  let assert Ok(listener) =
    tls.listen(settings(f.server, f.client, 1000), tls.Loopback, 0)
    as "Listen for stalled peer."
  let assert Ok(port) = tls.port(listener) as "Port."
  let ready = process.new_subject()
  let stopped = process.new_subject()
  let completed = process.new_subject()
  let _peer =
    process.spawn_unlinked(fn() {
      let assert Ok(connection) = tls.accept(listener) as "Authenticate client."
      let stop = process.new_subject()
      process.send(ready, stop)
      let assert Ok(Nil) = process.receive(stop, 6000)
        as "Stalled fixture has a deadline."
      tls.close(connection)
      process.send(stopped, Nil)
    })
  let assert Ok(connection) =
    tls.connect(settings(f.client, f.server, 1000), "localhost", port)
    as "Authenticate stalled server."
  let assert Ok(stop) = process.receive(ready, 2000)
    as "Peer is deliberately not reading."
  let body = bit_array.from_string(string.repeat("x", tls.max_frame_bytes))
  let writer_ready = process.new_subject()
  let writer =
    process.spawn_unlinked(fn() {
      let begin = process.new_subject()
      process.send(writer_ready, begin)
      let assert Ok(connection) = process.receive(begin, 2000)
        as "Writer gets custody."
      let failed = send_until_blocked(connection, body, 128)
      let subsequent = tls.send(connection, <<42>>)
      tls.close(connection)
      process.send(completed, #(failed, subsequent))
    })
  let assert Ok(begin) = process.receive(writer_ready, 2000)
    as "Writer is ready."
  assert tls.transfer(connection, writer) == Ok(Nil)
  process.send(begin, connection)
  let assert Ok(#(failure, subsequent)) = process.receive(completed, 3000)
    as "A nonreading peer cannot block the writer indefinitely."
  assert failure |> result.is_error
  assert subsequent |> result.is_error
  process.send(stop, Nil)
  let assert Ok(Nil) = process.receive(stopped, 1000)
    as "Stalled fixture is retired."
  tls.close_listener(listener)
}

fn send_until_blocked(
  connection: tls.Connection,
  body: BitArray,
  remaining: Int,
) -> Result(Nil, tls.Error) {
  case remaining {
    0 -> Ok(Nil)
    _ -> {
      use Nil <- result.try(tls.send(connection, body))
      send_until_blocked(connection, body, remaining - 1)
    }
  }
}
