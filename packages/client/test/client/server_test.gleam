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
