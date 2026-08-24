//// Boot smoke for the server entry point: `serve.boot` over a fresh
//// SQLite session with a scripted (dead-transport) provider gateway —
//// the demo rig pattern, injected through `Settings`' gateway seam —
//// then the served surface proven from outside: `/healthz` over plain
//// HTTP, and a real websocket upgrade + `subscribe` answered with the
//// full snapshot. No generation is driven and no tool runs, so the
//// provider transport never sends and the helper never spawns — which
//// is exactly the keyless-environment boot story the module documents.

import broker/exec
import client/catalog
import client/protocol
import client/serve
import core/clock
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/option.{None, Some}
import machine/strand as machine_strand
import provider/gateway as provider_gateway
import provider/http
import provider/model
import provider/secret
import simplifile
import support/internal/ffi_ws

const root = "build/serve-test"

// A one-entry catalogue whose gateway rides a transport that never
// answers: subscribe and healthz touch no provider, so the smoke boot
// needs reachability of the seam, not a live wire — and building the
// gateway *from* the catalogue is exactly what `resolve` does.
fn scripted_catalog() -> catalog.Catalog {
  catalog.Catalog(
    models: [
      catalog.CatalogModel(
        name: "acme",
        dialect: catalog.Anthropic,
        base_url: "https://acme.test",
        api_key_env: "ACME_KEY",
        model_id: "loom-1",
        context_window: 100_000,
        max_output_tokens: 4096,
        thinking: model.ThinkingOff,
      ),
    ],
    roles: [#(model.Main, ["acme"])],
  )
}

fn scripted_gateway() -> provider_gateway.Gateway {
  catalog.gateway(
    scripted_catalog(),
    transport: http.Transport(send_streaming: fn(_request, _subject) { Nil }),
    secrets: secret.from_list([#("ACME_KEY", "smoke-test-key")]),
    clock: clock.fixed(at: 0),
  )
}

fn settings() -> serve.Settings {
  serve.Settings(
    session_path: root <> "/session.db",
    bind_host: "127.0.0.1",
    bind_port: 0,
    token_path: root <> "/session.db.token",
    workspace: root <> "/work",
    // Never spawned: nothing in this test runs a tool, and the pool
    // spawns helpers lazily at first checkout.
    helper_path: "/bin/sh",
    session_id: "session",
    demand: exec.BestEffort,
    gateway: scripted_gateway(),
    catalog: scripted_catalog(),
    system: None,
    model: machine_strand.ModelIdentity(provider: "acme", model_id: "loom-1"),
    context_window: 100_000,
    max_output_tokens: 4096,
  )
}

pub fn boot_serves_healthz_and_ws_subscribe_test() {
  // A fresh root per run so the session always starts empty.
  let _stale = simplifile.delete(root)
  let assert Ok(booted) = serve.boot(settings())
    as "the server must boot on an ephemeral port"

  // The bearer token landed in the announced file, mode 0600.
  let assert Ok(token) = simplifile.read(root <> "/session.db.token")
  assert token == booted.served.token
  let assert Ok(info) = simplifile.file_info(root <> "/session.db.token")
  assert info.mode % 0o1000 == 0o600

  // /healthz answers without auth.
  let base = "http://127.0.0.1:" <> int.to_string(booted.served.port)
  let assert Ok(health) = request.to(base <> "/healthz")
  let assert Ok(health_response) = httpc.send(health)
  assert health_response.status == 200

  // A real websocket subscribe: upgrade with the token from the file,
  // send the command, and the reply is the full snapshot for the
  // session id the server derived from the file name.
  let subscribe =
    protocol.encode_command(protocol.CommandEnvelope(
      id: 1,
      command: protocol.Subscribe(session: "session", from_seq: None),
    ))
  let assert Ok(frame) =
    ffi_ws.ws_roundtrip("127.0.0.1", booted.served.port, token, subscribe)
    as "the websocket round trip must complete"
  let assert Ok(envelope) = protocol.decode_event(frame)
  assert envelope.reply_to == Some(1)
  let assert protocol.SnapshotEvent(protocol.FullSnapshot(..)) = envelope.event

  serve.shutdown(booted)
}
