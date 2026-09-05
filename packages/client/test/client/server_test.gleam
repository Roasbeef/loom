//// The websocket transport: auth gating, the local token file, and a
//// live HTTP smoke test against a served (empty) gateway.

import client/gateway
import client/server
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/result
import gleam/string
import simplifile
import support/addresses
import support/internal/ffi_ws
import tui/connection

fn entropy() -> fn() -> Int {
  // Deterministic but distinct per call: tests never need real entropy.
  let counter = process.new_subject()
  process.send(counter, 7919)
  fn() {
    let assert Ok(previous) = process.receive(counter, within: 100)
      as "the entropy counter subject must hold a value"
    process.send(counter, previous * 31 + 17)
    previous
  }
}

pub fn mint_token_shape_test() {
  let token = server.mint_token(entropy())
  assert string.length(token) == 32
}

pub fn local_auth_writes_a_0600_token_file_test() {
  let path = "build/server-test.token"
  let name = addresses.new()
  let assert Ok(served) =
    server.serve(server.Config(
      gateway: gateway.Gateway(name:),
      bind: "127.0.0.1",
      port: 0,
      auth: server.LocalAuth(token_path: path),
      entropy: entropy(),
    ))
  let assert Ok(stored) = simplifile.read(path)
  assert stored == served.token
  let assert Ok(info) = simplifile.file_info(path)
  // Owner read/write only (the low nine mode bits).
  assert info.mode % 0o1000 == 0o600
  server.stop(served)
  let assert Ok(Nil) = simplifile.delete(path)
}

// GW-token-timing: the bearer check must refuse both a same-length and a
// different-length wrong token, and accept the exact one. A plain HTTP
// request (no websocket handshake headers) is enough to probe the auth
// gate: `authorized` runs before `upgrade`, and mist answers a malformed
// (but authorized) upgrade attempt with 400, never 401 -- so 400 vs 401
// cleanly witnesses whether the token check passed, with no live gateway
// actor required.
pub fn authorized_refuses_wrong_length_and_content_test() {
  let correct = string.repeat("a", 32)
  let wrong_same_length = string.repeat("b", 32)
  let wrong_short = string.repeat("a", 5)
  let name = addresses.new()
  let assert Ok(served) =
    server.serve(server.Config(
      gateway: gateway.Gateway(name:),
      bind: "127.0.0.1",
      port: 0,
      auth: server.BearerAuth(token: correct),
      entropy: entropy(),
    ))
  let base = "http://127.0.0.1:" <> int.to_string(served.port)
  let probe = fn(token) {
    let assert Ok(request) = request.to(base <> "/v1/ws")
    let assert Ok(response) =
      request
      |> request.set_header("authorization", "Bearer " <> token)
      |> httpc.send
    response.status
  }
  assert probe(wrong_same_length) == 401
  assert probe(wrong_short) == 401
  // The correct token clears the auth gate: mist then answers 400
  // because this probe sends none of the websocket handshake headers,
  // never 401.
  assert probe(correct) == 400
  server.stop(served)
}

// GW-token-perms: a symlink pre-planted at the token path must never be
// written through -- write-then-chmod (`simplifile.write` truncates
// whatever `path` resolves to) follows it and clobbers the symlink's
// target; an atomic create-then-rename replaces the symlink itself,
// leaving the target untouched.
pub fn write_token_file_does_not_follow_a_symlink_test() {
  let target = "build/server-test-symlink-target.txt"
  let path = "build/server-test-symlink.token"
  let _ = simplifile.delete(target)
  let _ = simplifile.delete(path)
  let assert Ok(Nil) = simplifile.write(target, "pre-existing")
  let assert Ok(Nil) =
    simplifile.create_symlink(to: "server-test-symlink-target.txt", from: path)

  let name = addresses.new()
  let assert Ok(served) =
    server.serve(server.Config(
      gateway: gateway.Gateway(name:),
      bind: "127.0.0.1",
      port: 0,
      auth: server.LocalAuth(token_path: path),
      entropy: entropy(),
    ))

  let assert Ok(untouched) = simplifile.read(target)
  assert untouched == "pre-existing"
  let assert Ok(False) = simplifile.is_symlink(path)
  let assert Ok(stored) = simplifile.read(path)
  assert stored == served.token
  let assert Ok(info) = simplifile.file_info(path)
  assert info.mode % 0o1000 == 0o600

  server.stop(served)
  let assert Ok(Nil) = simplifile.delete(path)
  let assert Ok(Nil) = simplifile.delete(target)
}

pub fn http_surface_test() {
  let name = addresses.new()
  let assert Ok(served) =
    server.serve(server.Config(
      gateway: gateway.Gateway(name:),
      bind: "127.0.0.1",
      port: 0,
      auth: server.BearerAuth(token: "secret-token"),
      entropy: entropy(),
    ))
  let base = "http://127.0.0.1:" <> int.to_string(served.port)
  // Health endpoint answers without auth.
  let assert Ok(health) = request.to(base <> "/healthz")
  let assert Ok(health_response) = httpc.send(health)
  assert health_response.status == 200
  // The websocket endpoint refuses a tokenless upgrade attempt.
  let assert Ok(upgrade) = request.to(base <> "/v1/ws")
  let assert Ok(upgrade_response) = httpc.send(upgrade)
  assert upgrade_response.status == 401
  // Everything else is not found.
  let assert Ok(other) = request.to(base <> "/elsewhere")
  let assert Ok(other_response) = httpc.send(other)
  assert other_response.status == 404
  server.stop(served)
}

pub fn an_idle_socket_closes_when_its_gateway_is_unavailable_test() {
  let name = addresses.new()
  let assert Ok(served) =
    server.serve(server.Config(
      gateway: gateway.Gateway(name:),
      bind: "127.0.0.1",
      port: 0,
      auth: server.BearerAuth(token: "unavailable-gateway-test"),
      entropy: entropy(),
    ))
    as "the transport must start without a bound gateway"
  let inbox = connection.new_inbox()
  let attached =
    connection.connect(
      "ws://127.0.0.1:" <> int.to_string(served.port) <> "/v1/ws",
      served.token,
      inbox,
    )

  // Send no protocol frame. The server's post-transfer refusal message must
  // close an idle peer too. Closure may race the client's Connected notice.
  let closed = case process.receive(inbox, within: 1000) {
    Ok(connection.Connected) -> process.receive(inbox, within: 1000)
    other -> other
  }
  case attached {
    Ok(socket) -> connection.close(socket)
    Error(_already_closed) -> Nil
  }
  server.stop(served)
  let assert Ok(connection.Closed(_)) = closed
    as "an authenticated idle socket must observe closure, not a timeout"
  Nil
}

pub fn cancelling_a_withheld_handshake_closes_tcp_promptly_test() {
  let assert Ok(listener) =
    ffi_ws.tcp_listen(0, [ffi_ws.Binary, ffi_ws.Active(False)])
    as "the stalled peer must listen on an ephemeral port"
  let assert Ok(port) = ffi_ws.tcp_port(listener)
    as "the stalled peer must expose its bound port"
  let inbox = connection.new_inbox()
  let attempt =
    process.spawn_unlinked(fn() {
      let _ =
        connection.connect(
          "ws://127.0.0.1:" <> int.to_string(port) <> "/v1/ws",
          "stalled-handshake",
          inbox,
        )
      Nil
    })
  let assert Ok(peer) = ffi_ws.tcp_accept(listener, 1000)
    as "the client must actually open TCP before it is cancelled"
  let assert Ok(_request) = ffi_ws.tcp_receive(peer, 0, 1000)
    as "the client must send its upgrade request before cancellation"

  // Withhold the HTTP response. Cancellation must close the real TCP peer
  // within one second, not wait for Stratus's five-second handshake timeout.
  process.kill(attempt)
  let received = ffi_ws.tcp_receive(peer, 0, 1000)
  ffi_ws.tcp_close(peer)
  ffi_ws.tcp_close(listener)
  let assert Error(reason) = received
    as "the cancelled handshake must close its TCP connection"
  assert decode.run(reason, atom.decoder()) |> result.map(atom.to_string)
    == Ok("closed")
}
