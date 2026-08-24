//// The websocket transport: auth gating, the local token file, and a
//// live HTTP smoke test against a served (empty) gateway.

import client/gateway
import client/server
import gleam/erlang/process
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/string
import simplifile

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
  let name = process.new_name(prefix: "loom_gateway_absent")
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
  let name = process.new_name(prefix: "loom_gateway_bad_token")
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

  let name = process.new_name(prefix: "loom_gateway_symlink")
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
  let name = process.new_name(prefix: "loom_gateway_http")
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
