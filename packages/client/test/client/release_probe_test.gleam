//// Control-plane acceptance run by the release's own bundled emulator.
////
//// The build copies this test module beside, not into, the release. Smoke can
//// therefore exercise real session admission without a host Erlang, a second
//// WebSocket implementation, or a test command in the production CLI. All
//// imports below are already in the server's production dependency closure.

import argv
import client/install
import client/serve
import core/json
import gleam/bit_array
import gleam/erlang/process
import gleam/io
import gleam/list
import gleam/option.{Some}
import gleam/string
import host/bootstrap
import host/endpoint
import host/websocket
import storage/catalogue
import storage/domain
import weft/poll

/// Opens two real sessions after proving that daemon startup opened none.
/// Leaves the second resident so the shell must prove SIGTERM drains it.
///
/// ## Examples
///
/// The smoke invokes this module with its private state root and workspace.
pub fn main() -> Nil {
  let assert [directory, workspace, configuration] = argv.load().arguments
    as "release probe requires state root, workspace and test configuration"
  let assert Ok(paths) = endpoint.paths(directory)
    as "private paths must resolve"
  let assert Ok(Some(endpoint.Ready(_, _, _, epoch) as record)) =
    endpoint.load(paths)
    as "daemon must publish a ready native endpoint"
  let assert Ok(address) = endpoint.address(record)
    as "endpoint must be loopback"
  let assert Ok(bytes) = bootstrap.read_private_bounded(paths.token, 64)
    as "owner credential must be private and bounded"
  let assert Ok(token) = bit_array.to_string(bytes) as "credential must be text"
  let inbox = websocket.new_inbox()
  let assert Ok(socket) = websocket.connect(address, token, inbox)
    as "bundled transport must connect to the daemon"

  let hello = next_frame(inbox)
  assert field(hello, "event") == json.String("hello")
  assert field(field(hello, "body"), "epoch") == json.String(epoch)
  let initial = request(socket, inbox, "status", [])
  assert field(initial, "ready") == json.Bool(True)
  assert field(initial, "epoch") == json.String(epoch)
  assert field(initial, "occupied") == json.Int(0)
  assert field(initial, "resident") == json.Int(0)

  // Creating sessions is explicit. No prompt is sent, so maintenance over the
  // empty transcripts must complete without making a provider request.
  let first = create(socket, inbox, workspace, configuration, "release-first")
  let second = create(socket, inbox, workspace, configuration, "release-second")
  let current = request(socket, inbox, "status", [])
  assert field(current, "resident") == json.Int(2)
  verify_helper(paths.root, workspace, configuration, first)

  let _stopping =
    request(socket, inbox, "sessions.stop", [
      #("session_id", json.String(first)),
      #("epoch", json.String(epoch)),
    ])
  await_state(socket, inbox, first, "saved")
  let sibling =
    request(socket, inbox, "sessions.get", [
      #("session_id", json.String(second)),
    ])
  assert field(field(sibling, "status"), "state") == json.String("resident")
  websocket.close(socket)
  io.println(
    "release probe: two sessions admitted; sibling survived first close",
  )
}

fn create(socket, inbox, workspace, configuration, key) {
  let created =
    request(socket, inbox, "sessions.create", [
      #("request_key", json.String(key)),
      #("workspace", json.String(workspace)),
      #("name", json.String(key)),
      #("configuration", json.String(configuration)),
    ])
  let assert json.String(id) = field(created, "session_id")
    as "creation must return canonical identity"
  await_state(socket, inbox, id, "resident")
  id
}

// This uses the same managed resolver the daemon invokes on admission. Missing
// explicit helpers must fail rather than falling through to the bundled one.
fn verify_helper(directory, workspace, configuration, id) {
  let registration =
    catalogue.Registration(
      id,
      directory <> "/sessions/" <> id <> ".db",
      workspace,
      "release probe",
      configuration,
      1,
      "release-probe-resolution",
      catalogue.Saved,
    )
  let selected =
    domain.Domain(
      domain.key(domain.WorkspacePrivate, workspace, id),
      domain.WorkspacePrivate,
      workspace,
      configuration,
      directory <> "/probe-resolution/memory.db",
      directory <> "/probe-resolution/search.db",
    )
  let assert Ok(settings) =
    serve.resolve_managed(["--best-effort"], registration, selected, directory)
    as "bundled managed resolver must find its own helper"
  assert settings.helper_path == install.root() <> "/bin/loom-exec"
  let assert Error(reason) =
    serve.resolve_managed(
      ["--best-effort", "--helper", "/nonexistent/loom-exec"],
      registration,
      selected,
      directory,
    )
    as "an explicit missing helper must not fall back"
  assert string.contains(reason, "/nonexistent/loom-exec")
  io.println(
    "release probe: bundled helper found; explicit missing helper refused",
  )
}

fn await_state(socket, inbox, id, expected) -> Nil {
  let assert poll.Answered(Nil) =
    poll.until(within: 30_000, every: 25, attempt: fn() {
      let view =
        request(socket, inbox, "sessions.get", [
          #("session_id", json.String(id)),
        ])
      case field(field(view, "status"), "state") == json.String(expected) {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
    as "session must reach the expected lifecycle state before its deadline"
  Nil
}

// Requests are strictly sequential, so one correlation ID is sufficient. A
// missing reply fails instead of retrying a mutation with an unknown outcome.
fn request(socket, inbox, command, fields) {
  let envelope =
    json.Object([
      #("v", json.Int(2)),
      #("id", json.Int(1)),
      #("cmd", json.String(command)),
      #("body", json.Object(fields)),
    ])
  websocket.send(socket, json.to_string(envelope))
  let reply = next_frame(inbox)
  case field(reply, "event") {
    json.String("error") -> io.println_error(json.to_string(reply))
    _event -> Nil
  }
  assert field(reply, "v") == json.Int(2)
  assert field(reply, "reply_to") == json.Int(1)
  assert field(reply, "event") == json.String(command)
  field(reply, "body")
}

fn next_frame(inbox) {
  let assert Ok(message) = process.receive(inbox, 5000)
    as "control frame must arrive before its deadline"
  let message = case message {
    websocket.Connected -> {
      let assert Ok(next) = process.receive(inbox, 5000)
        as "hello must follow transport connection"
      next
    }
    incoming -> incoming
  }
  let assert websocket.Incoming(text) = message
    as "control must remain connected"
  assert string.byte_size(text) <= 65_536
  let assert Ok(value) = json.parse(text) as "control frame must decode"
  value
}

fn field(value, name) {
  let assert json.Object(fields) = value as "control value must be an object"
  let assert Ok(value) = list.key_find(fields, name)
    as "control field must be present"
  value
}
