//// Real SQLite and WebSocket tests exercise the v2 control boundary.
//// The assembly is inert: these tests establish routing and authorization,
//// not native session cleanup, which the owned assembly suite tests separately.

import broker/token
import client/daemon/domain as domain_service
import client/daemon/limits
import client/daemon/manager
import client/daemon/peer_cli
import client/daemon/root
import client/daemon/server
import client/gateway_test
import client/peer_mail
import client/peers
import core/clock
import core/ids
import core/json
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import mist
import runtime/api
import simplifile
import storage/access
import storage/catalogue
import support/internal/ffi_daemon_socket
import support/internal/ffi_ws.{type Socket}
import tui/connection
import tui/daemon/protocol as terminal_protocol
import web_view/sessions
import weft
import weft/poll

/// Runs a bounded wire test with real SQLite and an inert session assembly.
///
/// ## Examples
///
/// ```gleam
/// // fixture(fn(root, ready, port, credential) { check(root, ready, port, credential) })
/// ```
@internal
pub fn fixture(
  run: fn(root.Root(String), root.Ready(String), Int, String) -> Nil,
) {
  fixture_with_limits(limits.defaults, run)
}

fn fixture_with_limits(connection_limits: limits.Limits, run) {
  fixture_with_peers(connection_limits, fn(_) { None }, run)
}

fn fixture_with_peers(connection_limits: limits.Limits, peer_endpoint, run) {
  let directory =
    "build/test_db/daemon-wire-"
    <> bit_array.base16_encode(token.production_entropy()(8))
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
    as "private fixture directory exists"
  let assert Ok(daemon) =
    root.start(
      root.Config(directory, "Owner", 2, connection_limits),
      manager.Assembly(
        domain_build: fn(_, _, _) { Ok(domain_service.inert()) },
        build: fn(record, _domain, _services, _, _directory) { Ok(record.id) },
        drain: fn(_, _) { Nil },
        fatal: fn(_) { [] },
      ),
    )
    as "daemon is prepared"
  let assert Ok(ready) = root.ready(daemon, within: 5000)
    as "durable owner and empty registry are ready"
  let assert Ok(credential) = root.listener_credential(daemon)
    as "only the fixture receives plaintext owner credential"
  let config =
    server.Config(
      peer_endpoint:,
      daemon:,
      domain_configuration: "",
      generator: fn() { ids.generator(clock.fixed(1_700_000_000_000), 123) },
      session_upgrade: fn(_, _) {
        response.new(501)
        |> response.set_body(
          mist.Bytes(bytes_tree.from_string("v2 conversation adapter absent")),
        )
      },
      ui: None,
    )
  let ports = process.new_subject()
  let assert Ok(listener) =
    mist.new(fn(request) { server.handle(config, request) })
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(port, _, _) { process.send(ports, port) })
    |> mist.start
    as "one listener serves the daemon router"
  process.unlink(listener.pid)
  let assert Ok(port) = process.receive(ports, 1000) as "listener port is known"

  // The body runs on its own task because a failed assertion kills the process
  // running it. The listener is unlinked, so on the eunit test process that
  // failure left the listener, the daemon root, its lock and the SQLite writer
  // lease alive for the rest of the VM. A task turns that death into an
  // outcome and lets the teardown below run either way.
  let outcomes =
    weft.new([fn() { Ok(run(daemon, ready, port, credential)) }])
    |> weft.deadline(40_000)
    |> weft.start
  assert root.shutdown(daemon, within: 5000) == Ok(Nil)
  process.kill(listener.pid)

  // The outcome is read only once every owner has retired, so a failing test
  // reports its own assertion rather than a teardown that never happened.
  let assert [weft.Completed(0, _)] = outcomes
    as "the wire fixture body ran to completion inside its own deadline"
  Nil
}

@internal
pub fn connect(port, credential, path) {
  let assert Ok(socket) =
    ffi_daemon_socket.connect(
      #(127, 0, 0, 1),
      port,
      [ffi_ws.Binary, ffi_ws.Active(False)],
      1000,
    )
    as "raw TCP client connects"
  let handshake =
    "GET "
    <> path
    <> " HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nAuthorization: Bearer "
    <> credential
    <> "\r\n\r\n"
  assert ffi_daemon_socket.send(socket, bit_array.from_string(handshake))
    == Ok(Nil)
  #(socket, headers(socket, "", 4096))
}

fn headers(socket, accumulated, remaining) {
  case string.ends_with(accumulated, "\r\n\r\n"), remaining {
    True, _ -> accumulated
    False, 0 -> panic as "HTTP header exceeds fixture budget"
    False, _ -> {
      let assert Ok(byte) = ffi_ws.tcp_receive(socket, 1, 1000)
        as "header arrives within deadline"
      let assert Ok(text) = bit_array.to_string(byte)
        as "HTTP response is ASCII"
      headers(socket, accumulated <> text, remaining - 1)
    }
  }
}

/// Reads one complete WebSocket text frame and decodes its JSON body.
///
/// `within_ms` is the caller's budget, not this module's: an in-process
/// fixture answers inside its own event loop turn, so every in-file test
/// passes `1000` explicitly. A fixture that attaches to the *shipped* daemon
/// answers past a real admission handshake first — `session_socket.admit`
/// spends a one-second root permit transfer and a five-second gateway
/// attach before the first reply can be written — so that caller passes a
/// wider budget of its own derivation instead of inheriting this one.
///
/// ## Examples
///
/// ```gleam
/// // frame(socket, within_ms: 1000)
/// ```
@internal
pub fn frame(socket: Socket, within_ms within_ms: Int) {
  let assert Ok(<<0x81, marker>>) = ffi_ws.tcp_receive(socket, 2, within_ms)
    as "server sends a text frame"
  let size = case marker {
    126 -> {
      let assert Ok(<<size:16>>) = ffi_ws.tcp_receive(socket, 2, within_ms)
        as "extended frame length arrives"
      size
    }
    size if size < 126 -> size
    _ -> panic as "control response exceeds fixture frame budget"
  }
  let assert Ok(bytes) = ffi_ws.tcp_receive(socket, size, within_ms)
    as "complete response arrives"
  let assert Ok(text) = bit_array.to_string(bytes) as "response is UTF-8"
  let assert Ok(value) = json.parse(text) as "response is total JSON"
  value
}

/// Sends one v2 command and reads back the very next frame, whatever it is.
///
/// See `frame`'s doc for why `within_ms` is the caller's to set: this
/// forwards it unchanged to the read that follows the write.
@internal
pub fn send(socket, id, command, body, within_ms within_ms: Int) {
  let text =
    json.to_string(
      json.Object([
        #("v", json.Int(2)),
        #("id", json.Int(id)),
        #("cmd", json.String(command)),
        #("body", body),
      ]),
    )
  let bytes = bit_array.from_string(text)
  let size = bit_array.byte_size(bytes)
  let masked = case size < 126 {
    True -> <<0x81, 1:1, size:7, 0:32, bytes:bits>>
    False -> <<0x81, 0xfe, size:16, 0:32, bytes:bits>>
  }
  assert ffi_daemon_socket.send(socket, masked) == Ok(Nil)
  frame(socket, within_ms:)
}

/// One request, answered past whatever the daemon pushed around it.
///
/// Since `protocol-change/018` a session socket also receives frames that
/// answer no command — a `committed` notice, a delta, the roster — and one
/// can land before the reply if the hint won the race to the hub, or after
/// it if the request did. Correlation is what separates them, which is the
/// whole reason a reply carries `reply_to` and a push does not. Use this
/// wherever a fixture commits between two requests; `send` stays the raw
/// "next frame" for a fixture asserting on the pushes themselves.
///
/// A socket nobody reads between requests collects every push meanwhile:
/// a roster for each peer that joins (`protocol-change/054`), and a notice
/// and deltas for each commit. The skip is bounded at `push_backlog` so a
/// reply that never comes fails the fixture rather than reading forever.
///
/// ## Examples
///
/// ```gleam
/// // daemon_server_test.reply(socket, 100, "prompt", body, within_ms: 1000)
/// ```
@internal
pub fn reply(socket, id, command, body, within_ms within_ms: Int) {
  answered(
    socket,
    send(socket, id, command, body, within_ms:),
    push_backlog,
    within_ms,
  )
}

// How many unread pushes a fixture socket may skip before the frame it is
// waiting for. It bounds a read loop, not a protocol limit, so it is sized
// for the busiest fixture: several peers joining and a whole provider turn
// pushed to a socket that is only read again at its next request.
const push_backlog = 64

fn answered(socket, value, remaining: Int, within_ms: Int) {
  assert remaining > 0 as "the reply arrives within a bounded run of notices"
  let assert json.Object(fields) = value as "the wire value is an object"
  case list.key_find(fields, "reply_to") {
    Ok(_) -> value
    Error(Nil) ->
      answered(socket, frame(socket, within_ms:), remaining - 1, within_ms)
  }
}

/// Subscribes to a session and answers the reply, having also read the
/// roster the hub pushes to the newcomer.
///
/// Since `protocol-change/054` a successful subscribe hands the socket two
/// frames: the reply, and the subscriber's own copy of the `presence`
/// roster that every subscribed peer is pushed when one joins. They leave
/// the hub by different paths, so either may be written first. This reads
/// until it holds both, skipping any other push as `reply` does, so a test
/// that goes on reading the socket starts after the join. A subscribe that
/// is refused pushes no roster; read its answer with `reply`.
///
/// ## Examples
///
/// ```gleam
/// // daemon_server_test.subscribe(socket, 1, session, within_ms: 1000)
/// ```
@internal
pub fn subscribe(socket, id, session: String, within_ms within_ms: Int) {
  let first =
    send(
      socket,
      id,
      "subscribe",
      json.Object([#("session", json.String(session))]),
      within_ms:,
    )
  joined(socket, first, None, None, push_backlog, within_ms)
}

// The reply and the roster, collected in whichever order they arrive. The
// roster is recognised by its event name on a frame with no `reply_to`.
fn joined(socket, value, reply, roster, remaining: Int, within_ms: Int) {
  assert remaining > 0 as "the reply and the join arrive within a bounded run"
  let assert json.Object(fields) = value as "the wire value is an object"
  let #(reply, roster) = case
    list.key_find(fields, "reply_to"),
    list.key_find(fields, "event")
  {
    Ok(_), _ -> #(Some(value), roster)
    Error(Nil), Ok(json.String("presence")) -> #(reply, Some(value))
    Error(Nil), _ -> #(reply, roster)
  }
  case reply, roster {
    Some(reply), Some(_) -> reply
    _, _ ->
      joined(
        socket,
        frame(socket, within_ms:),
        reply,
        roster,
        remaining - 1,
        within_ms,
      )
  }
}

fn field(value, key) {
  let assert json.Object(fields) = value as "envelope is an object"
  let assert Ok(value) = list.key_find(fields, key)
    as "expected field is present"
  value
}

pub fn owner_control_uses_v2_and_never_implicitly_opens_test() {
  fixture(fn(_, ready, port, credential) {
    let #(socket, response) = connect(port, credential, "/v2/control")
    assert string.contains(response, "101 Switching Protocols")
    let hello = frame(socket, within_ms: 1000)
    assert field(hello, "v") == json.Int(2)
    assert field(hello, "event") == json.String("hello")
    let status = send(socket, 1, "status", json.Object([]), within_ms: 1000)
    assert field(status, "reply_to") == json.Int(1)
    assert field(field(status, "body"), "occupied") == json.Int(0)
    assert field(field(status, "body"), "domain_capacity") == json.Int(2)
    assert field(field(status, "body"), "domain_occupied") == json.Int(0)
    assert field(field(status, "body"), "domain_blocked") == json.Int(0)
    let listing =
      send(
        socket,
        2,
        "sessions.list",
        json.Object([#("after", json.String(""))]),
        within_ms: 1000,
      )
    assert field(field(listing, "body"), "sessions") == json.Array([])
    let stale =
      send(
        socket,
        3,
        "daemon.shutdown",
        json.Object([#("epoch", json.String("previous-epoch"))]),
        within_ms: 1000,
      )
    assert field(field(stale, "body"), "code") == json.String("stale_epoch")
    assert manager.summary(ready.registry)
      |> fn(result) {
        case result {
          Ok(summary) -> summary.occupied == 0
          Error(_) -> False
        }
      }
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn rejected_credentials_and_v1_paths_do_not_upgrade_test() {
  fixture(fn(_, _, port, credential) {
    let #(socket, response) = connect(port, "wrong", "/v2/control")
    assert string.contains(response, "401")
    let _ = ffi_ws.tcp_close(socket)
    let #(socket, response) = connect(port, credential, "/v1/ws")
    assert string.contains(response, "404")
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn member_authority_is_checked_again_on_each_control_request_test() {
  fixture(fn(_, ready, port, _) {
    let credential = string.repeat("1", 64)
    let assert Ok(digest) =
      credential
      |> bit_array.from_string
      |> bootstrap.sha256
      |> bit_array.base16_encode
      |> string.lowercase
      |> access.credential_digest
      as "member digest is valid"
    let assert Ok(store) = catalogue.open(ready.state_root <> "/catalogue.db")
      as "fixture administration opens the same durable catalogue"
    let assert Ok(member) =
      access.create_member(store, "wire-member", "Member", digest)
      as "member has no implicit session grants"
    let assert Ok(visible) =
      manager.create(
        ready.registry,
        manager.Creation("visible", ready.state_root, "Visible", "", None),
        directory: ready.sessions_directory,
        generator: ids.generator(clock.fixed(0), 100),
      )
      as "owner reserves one visible session"
    let assert Ok(hidden) =
      manager.create(
        ready.registry,
        manager.Creation("hidden", ready.state_root, "Hidden", "", None),
        directory: ready.sessions_directory,
        generator: ids.generator(clock.fixed(0), 101),
      )
      as "owner reserves another unrelated session"
    assert access.grant(
        store,
        member.id,
        visible.registration.id,
        access.Observer,
      )
      == Ok(Nil)
    let #(socket, response) = connect(port, credential, "/v2/control")
    assert string.contains(response, "101")
    let _hello = frame(socket, within_ms: 1000)
    let denied =
      send(
        socket,
        1,
        "sessions.default",
        json.Object([#("workspace", json.String(ready.state_root))]),
        within_ms: 1000,
      )
    assert field(field(denied, "body"), "code") == json.String("forbidden")
    let listing =
      send(
        socket,
        2,
        "sessions.list",
        json.Object([#("after", json.String(""))]),
        within_ms: 1000,
      )
    let assert json.Array([only]) = field(field(listing, "body"), "sessions")
      as "authorization precedes list pagination"
    assert field(only, "session_id") == json.String(visible.registration.id)
    assert !string.contains(json.to_string(listing), hidden.registration.id)
    let denied =
      send(
        socket,
        3,
        "sessions.open",
        json.Object([
          #("session_id", json.String(visible.registration.id)),
          #("epoch", json.String(ready.epoch)),
        ]),
        within_ms: 1000,
      )
    assert field(field(denied, "body"), "code") == json.String("forbidden")
    let peer_fields = [
      #("source_session", json.String(visible.registration.id)),
      #("source_strand", json.String("main")),
      #("target_session", json.String(hidden.registration.id)),
      #("target_strand", json.String("main")),
      #("wake", json.String("may_wake")),
      #("message_id", json.String("message-1")),
      #("text", json.String("finding")),
      #("epoch", json.String(ready.epoch)),
    ]
    list.each(["peers.link", "peers.unlink", "peers.send"], fn(command) {
      let denied =
        send(socket, 30, command, json.Object(peer_fields), within_ms: 1000)
      assert field(field(denied, "body"), "code") == json.String("forbidden")
        as "session membership cannot mutate peer communication authority"
    })
    assert access.revoke_credential(store, digest) == Ok(Nil)
    let revoked = send(socket, 4, "status", json.Object([]), within_ms: 1000)
    assert field(field(revoked, "body"), "code") == json.String("unauthorized")
    let _ = ffi_ws.tcp_close(socket)
    assert catalogue.close(store) == Ok(Nil)
  })
}

pub fn explicit_creation_default_operation_and_stop_roundtrip_test() {
  creation_default_operation_and_stop_roundtrip("/loom.toml")
}

pub fn inherited_configuration_creation_default_and_stop_roundtrip_test() {
  creation_default_operation_and_stop_roundtrip("")
}

fn creation_default_operation_and_stop_roundtrip(configuration: String) {
  fixture(fn(_, ready, port, credential) {
    assert simplifile.write(ready.state_root <> "/loom.toml", "") == Ok(Nil)
    let #(socket, _) = connect(port, credential, "/v2/control")
    let _hello = frame(socket, within_ms: 1000)
    let creation =
      json.Object([
        #("request_key", json.String("wire-create")),
        #("workspace", json.String(ready.state_root)),
        #("name", json.String("Wire session")),
        #(
          "configuration",
          json.String(case configuration {
            "" -> ""
            suffix -> ready.state_root <> suffix
          }),
        ),
      ])
    let created = send(socket, 1, "sessions.create", creation, within_ms: 1000)
    assert field(created, "event") == json.String("sessions.create")
    let assert json.String(id) = field(field(created, "body"), "session_id")
      as "creation exposes its reserved canonical identity"
    let assert Ok(saved) = manager.get(ready.registry, id)
      as "the creation reply follows durable registration"
    assert saved.registration.configuration
      == case configuration {
        "" -> ""
        suffix -> ready.state_root <> suffix
      }
    let retried = send(socket, 2, "sessions.create", creation, within_ms: 1000)
    assert field(field(retried, "body"), "session_id") == json.String(id)
    let selected =
      send(
        socket,
        3,
        "sessions.set_default",
        json.Object([
          #("workspace", json.String(ready.state_root)),
          #("session_id", json.String(id)),
        ]),
        within_ms: 1000,
      )
    assert field(selected, "event") == json.String("sessions.set_default")
    let selected =
      send(
        socket,
        4,
        "sessions.default",
        json.Object([
          #("workspace", json.String(ready.state_root)),
        ]),
        within_ms: 1000,
      )
    assert field(field(selected, "body"), "session_id") == json.String(id)

    let assert poll.Answered(incarnation) =
      poll.until(within: 2000, every: 1, attempt: fn() {
        case manager.get(ready.registry, id) {
          Ok(manager.View(status: manager.Resident(incarnation), ..)) ->
            poll.Done(incarnation)
          Ok(_) -> poll.Retry
          Error(error) -> poll.Fail(error)
        }
      })
      as "explicit creation completes its controlled assembly"
    let operation =
      send(
        socket,
        5,
        "operations.get",
        json.Object([
          #("session_id", json.String(id)),
          #("operation", json.String(incarnation)),
          #("epoch", json.String(ready.epoch)),
        ]),
        within_ms: 1000,
      )
    assert field(operation, "event") == json.String("operations.get")
    let stopped =
      send(
        socket,
        6,
        "sessions.stop",
        json.Object([
          #("session_id", json.String(id)),
          #("epoch", json.String(ready.epoch)),
        ]),
        within_ms: 1000,
      )
    assert field(stopped, "event") == json.String("sessions.stop")
    let assert poll.Answered(Nil) =
      poll.until(within: 2000, every: 1, attempt: fn() {
        case manager.get(ready.registry, id) {
          Ok(manager.View(status: manager.Saved, ..)) -> poll.Done(Nil)
          Ok(_) -> poll.Retry
          Error(error) -> poll.Fail(error)
        }
      })
      as "ordered stop returns metadata to saved"
    let stale =
      send(
        socket,
        7,
        "operations.get",
        json.Object([
          #("session_id", json.String(id)),
          #("operation", json.String(incarnation)),
          #("epoch", json.String(ready.epoch)),
        ]),
        within_ms: 1000,
      )
    assert field(field(stale, "body"), "code") == json.String("stale_operation")
    let #(attachment, response) =
      connect(port, credential, "/v2/sessions/" <> id <> "/ws")
    assert string.contains(response, "409")
    let _ = ffi_ws.tcp_close(attachment)
    let assert Ok(manager.View(status: manager.Saved, ..)) =
      manager.get(ready.registry, id)
      as "session route did not reopen saved runtime"
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn control_rejects_v1_and_oversized_frame_header_test() {
  fixture(fn(_, _, port, credential) {
    let #(socket, _) = connect(port, credential, "/v2/control")
    let _hello = frame(socket, within_ms: 1000)
    let text = "{\"v\":1,\"id\":1,\"cmd\":\"status\",\"body\":{}}"
    let bytes = bit_array.from_string(text)
    assert ffi_daemon_socket.send(socket, <<
        0x81,
        1:1,
        bit_array.byte_size(bytes):7,
        0:32,
        bytes:bits,
      >>)
      == Ok(Nil)
    assert field(field(frame(socket, within_ms: 1000), "body"), "code")
      == json.String("unsupported_version")
    assert ffi_daemon_socket.send(socket, <<0x81, 0xff, 1_000_000:64>>)
      == Ok(Nil)
    assert ffi_ws.tcp_receive(socket, 4, 1000) == Ok(<<0x88, 2, 1009:16>>)
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn owner_deletes_only_a_stopped_session_and_unlinks_its_files_test() {
  fixture(fn(_, ready, port, credential) {
    assert simplifile.write(ready.state_root <> "/loom.toml", "") == Ok(Nil)
    let #(socket, _) = connect(port, credential, "/v2/control")
    let _hello = frame(socket, within_ms: 1000)
    let created =
      send(
        socket,
        1,
        "sessions.create",
        json.Object([
          #("request_key", json.String("wire-delete")),
          #("workspace", json.String(ready.state_root)),
          #("name", json.String("Doomed session")),
          #("configuration", json.String(ready.state_root <> "/loom.toml")),
        ]),
        within_ms: 1000,
      )
    let assert json.String(id) = field(field(created, "body"), "session_id")
      as "creation exposes its reserved canonical identity"

    // The database path is read from the registration rather than rebuilt
    // here, so the test unlinks whatever the daemon actually registered.
    let assert Ok(view) = manager.get(ready.registry, id)
      as "the new registration is readable"
    let path = view.registration.path

    // The fixture's assembly is inert, so it registers a path without ever
    // creating a file there. The database family is written by hand so this
    // test is about what delete unlinks rather than what assembly wrote.
    assert simplifile.write(to: path, contents: "conversation") == Ok(Nil)
    assert simplifile.write(to: path <> "-wal", contents: "wal") == Ok(Nil)
    assert simplifile.write(to: path <> "-shm", contents: "shm") == Ok(Nil)

    // A live reservation must refuse deletion outright. Waiting for the
    // assembly to publish is what makes this the busy case rather than a
    // race against a session that has not started yet.
    let assert poll.Answered(Nil) =
      poll.until(within: 2000, every: 1, attempt: fn() {
        case manager.get(ready.registry, id) {
          Ok(manager.View(status: manager.Resident(_), ..)) -> poll.Done(Nil)
          Ok(_) -> poll.Retry
          Error(error) -> poll.Fail(error)
        }
      })
      as "explicit creation completes its controlled assembly"
    let refused =
      send(
        socket,
        2,
        "sessions.delete",
        json.Object([
          #("session_id", json.String(id)),
          #("epoch", json.String(ready.epoch)),
        ]),
        within_ms: 1000,
      )
    assert field(field(refused, "body"), "code") == json.String("busy")
    assert simplifile.is_file(path) == Ok(True)

    let _stopped =
      send(
        socket,
        3,
        "sessions.stop",
        json.Object([
          #("session_id", json.String(id)),
          #("epoch", json.String(ready.epoch)),
        ]),
        within_ms: 1000,
      )
    let assert poll.Answered(Nil) =
      poll.until(within: 2000, every: 1, attempt: fn() {
        case manager.get(ready.registry, id) {
          Ok(manager.View(status: manager.Saved, ..)) -> poll.Done(Nil)
          Ok(_) -> poll.Retry
          Error(error) -> poll.Fail(error)
        }
      })
      as "ordered stop returns metadata to saved"

    let deleted =
      send(
        socket,
        4,
        "sessions.delete",
        json.Object([
          #("session_id", json.String(id)),
          #("epoch", json.String(ready.epoch)),
        ]),
        within_ms: 1000,
      )
    assert field(deleted, "event") == json.String("sessions.delete")
    assert field(field(deleted, "body"), "session_id") == json.String(id)

    // The registration, the listing row and the whole database family go
    // together; a surviving sidecar would be adopted by a later session
    // that reused the identity.
    assert manager.get(ready.registry, id)
      == Error(manager.Catalogue(catalogue.Missing))
    assert simplifile.is_file(path) == Ok(False)
    assert simplifile.is_file(path <> "-wal") == Ok(False)
    assert simplifile.is_file(path <> "-shm") == Ok(False)
    let listing =
      send(
        socket,
        5,
        "sessions.list",
        json.Object([#("after", json.String(""))]),
        within_ms: 1000,
      )
    assert field(field(listing, "body"), "sessions") == json.Array([])

    let missing =
      send(
        socket,
        6,
        "sessions.delete",
        json.Object([
          #("session_id", json.String(id)),
          #("epoch", json.String(ready.epoch)),
        ]),
        within_ms: 1000,
      )
    assert field(field(missing, "body"), "code") == json.String("not_found")

    let stale =
      send(
        socket,
        7,
        "sessions.delete",
        json.Object([
          #("session_id", json.String(id)),
          #("epoch", json.String("previous-epoch")),
        ]),
        within_ms: 1000,
      )
    assert field(field(stale, "body"), "code") == json.String("stale_epoch")
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn a_member_cannot_delete_a_session_it_can_read_test() {
  fixture(fn(_, ready, port, _) {
    let credential = string.repeat("2", 64)
    let assert Ok(digest) =
      credential
      |> bit_array.from_string
      |> bootstrap.sha256
      |> bit_array.base16_encode
      |> string.lowercase
      |> access.credential_digest
      as "member digest is valid"
    let assert Ok(store) = catalogue.open(ready.state_root <> "/catalogue.db")
      as "fixture administration opens the same durable catalogue"
    let assert Ok(member) =
      access.create_member(store, "delete-member", "Member", digest)
      as "member has no implicit session grants"
    let assert Ok(visible) =
      manager.create(
        ready.registry,
        manager.Creation(
          "member-visible",
          ready.state_root,
          "Visible",
          "",
          None,
        ),
        directory: ready.sessions_directory,
        generator: ids.generator(clock.fixed(0), 200),
      )
      as "owner reserves one visible session"
    assert access.grant(
        store,
        member.id,
        visible.registration.id,
        access.Observer,
      )
      == Ok(Nil)

    // Membership is enough to read this row and not enough to remove it:
    // deletion is the owner's, because the files belong to the state root.
    let #(socket, _) = connect(port, credential, "/v2/control")
    let _hello = frame(socket, within_ms: 1000)
    let denied =
      send(
        socket,
        1,
        "sessions.delete",
        json.Object([
          #("session_id", json.String(visible.registration.id)),
          #("epoch", json.String(ready.epoch)),
        ]),
        within_ms: 1000,
      )
    assert field(field(denied, "body"), "code") == json.String("forbidden")
    assert manager.get(ready.registry, visible.registration.id)
      |> result.is_ok
    let _ = ffi_ws.tcp_close(socket)
    assert catalogue.close(store) == Ok(Nil)
  })
}

pub fn owner_archives_and_restores_through_the_control_socket_test() {
  fixture(fn(_, ready, port, credential) {
    let assert Ok(store) = catalogue.open(ready.state_root <> "/catalogue.db")
      as "the fixture seeds saved metadata in the daemon catalogue"
    let #(identity, _) = ids.mint_session(ids.generator(clock.fixed(1000), 891))
    let id = ids.session_id_to_string(identity)
    let path = ready.sessions_directory <> "/" <> id <> ".db"
    let registration =
      catalogue.Registration(
        id,
        path,
        ready.state_root,
        "Retained session",
        "",
        1000,
        "wire-archive",
        catalogue.Reserved,
        profile: option.None,
        subtitle: option.None,
      )
    assert catalogue.reserve(store, registration) == Ok(registration)
    let assert Ok(_) = catalogue.confirm(store, id) as "the fixture is saved"
    assert simplifile.write(path, "preserved conversation bytes") == Ok(Nil)
    let #(socket, _) = connect(port, credential, "/v2/control")
    let _hello = frame(socket, within_ms: 1000)
    let body =
      json.Object([
        #("session_id", json.String(id)),
        #("epoch", json.String(ready.epoch)),
      ])

    let archived = send(socket, 1, "sessions.archive", body, within_ms: 1000)
    let assert Ok(terminal_protocol.Answer(
      1,
      "sessions.archive",
      terminal_protocol.SessionReply(saved),
    )) = terminal_protocol.decode(json.to_string(archived))
      as "the terminal decodes the actual archive response"
    assert saved.session_id == id
    assert simplifile.read(path) == Ok("preserved conversation bytes")
    let active =
      send(
        socket,
        2,
        "sessions.list",
        json.Object([#("after", json.String(""))]),
        within_ms: 1000,
      )
    assert field(field(active, "body"), "sessions") == json.Array([])
    let hidden =
      send(
        socket,
        3,
        "sessions.archived",
        json.Object([#("after", json.String(""))]),
        within_ms: 1000,
      )
    let assert Ok(terminal_protocol.Answer(
      3,
      "sessions.archived",
      terminal_protocol.SessionsReply(page),
    )) = terminal_protocol.decode(json.to_string(hidden))
      as "archive listings use the terminal's bounded page codec"
    assert list.map(page.sessions, fn(session) { session.session_id }) == [id]
    let refused = send(socket, 4, "sessions.open", body, within_ms: 1000)
    assert field(field(refused, "body"), "code")
      == json.String("session_archived")

    let restored = send(socket, 5, "sessions.restore", body, within_ms: 1000)
    let assert Ok(terminal_protocol.Answer(
      5,
      "sessions.restore",
      terminal_protocol.SessionReply(restored),
    )) = terminal_protocol.decode(json.to_string(restored))
      as "restoration uses the same typed metadata without attaching"
    assert restored.session_id == id
    assert simplifile.read(path) == Ok("preserved conversation bytes")
    let assert Ok(view) = manager.get(ready.registry, id)
      as "restored metadata remains saved"
    assert view.status == manager.Saved
    let assert Ok(summary) = manager.summary(ready.registry)
      as "runtime occupancy is readable"
    assert summary.occupied == 0
    assert catalogue.close(store) == Ok(Nil)
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn hello_advertises_the_configured_connection_limits_test() {
  let configured = limits.Limits(7, 100_000_000)
  fixture_with_limits(configured, fn(_, _, port, credential) {
    let #(socket, _headers) = connect(port, credential, "/v2/control")
    let hello = frame(socket, within_ms: 2000)
    let advertised = field(field(hello, "body"), "limits")
    assert field(advertised, "connections") == json.Int(7)
    assert field(advertised, "reserved_message_bytes") == json.Int(100_000_000)
    ffi_ws.tcp_close(socket)
  })
}

pub fn terminal_reports_connection_admission_refusal_without_actor_wrapper_test() {
  fixture_with_limits(limits.Limits(1, 100_000_000), fn(_, _, port, credential) {
    let #(socket, _headers) = connect(port, credential, "/v2/control")
    let _hello = frame(socket, within_ms: 2000)
    let address = "ws://127.0.0.1:" <> int.to_string(port) <> "/v2/control"
    let assert Error(reason) =
      connection.connect(address, credential, connection.new_inbox())
      as "the real second handshake exceeds the configured count"
    assert string.contains(reason, "max_connections")
    assert string.contains(reason, "max_reserved_message_bytes")
    assert !string.contains(reason, "InitFailed")
    ffi_ws.tcp_close(socket)
  })
}

pub fn peer_control_mutations_are_epoch_fenced_before_resolution_test() {
  fixture(fn(_, _, port, credential) {
    let #(socket, response) = connect(port, credential, "/v2/control")
    assert string.contains(response, "101")
    let _hello = frame(socket, within_ms: 1000)
    let #(id, _) = ids.mint_session(ids.generator(clock.fixed(1), 13))
    let fields = [
      #("source_session", json.String(ids.session_id_to_string(id))),
      #("source_strand", json.String("main")),
      #("target_session", json.String(ids.session_id_to_string(id))),
      #("target_strand", json.String("main")),
      #("wake", json.String("may_wake")),
      #("message_id", json.String("message-1")),
      #("text", json.String("finding")),
      #("epoch", json.String("stale")),
    ]
    list.each(["peers.link", "peers.unlink", "peers.send"], fn(command) {
      let refused =
        send(socket, 1, command, json.Object(fields), within_ms: 1000)
      assert field(field(refused, "body"), "code") == json.String("stale_epoch")
    })
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn peer_send_control_routes_bound_identity_and_refuses_unlinked_or_saved_test() {
  let generator = ids.generator(clock.fixed(0), 401)
  let #(target, _) = ids.mint_session(generator)
  let target_id = ids.session_id_to_string(target)
  let delivered = process.new_subject()
  let endpoint = fn(session) {
    Some(
      peer_mail.Endpoint(session, fn(command) {
        case command {
          peer_mail.Links("main") ->
            Ok(
              json.Array([
                json.Object([
                  #("session", json.String(target_id)),
                  #("strand", json.String("reviewer")),
                ]),
              ]),
            )
          peer_mail.Links(_) -> Ok(json.Array([]))
          peer_mail.Activity(_) -> Ok(json.Object([]))
          peer_mail.Deliver(source, target, id, text) -> {
            process.send(delivered, #(session, source, target, id, text))
            Ok(json.Object([#("message_id", json.String(id))]))
          }
          _ -> Error("unexpected peer command")
        }
      }),
    )
  }
  fixture_with_peers(limits.defaults, endpoint, fn(_, ready, port, credential) {
    let assert Ok(source) =
      manager.create(
        ready.registry,
        manager.Creation("source", ready.state_root, "Source", "", None),
        directory: ready.sessions_directory,
        generator: ids.generator(clock.fixed(0), 400),
      )
      as "source session is created"
    let assert Ok(target) =
      manager.create(
        ready.registry,
        manager.Creation("target", ready.state_root, "Target", "", None),
        directory: ready.sessions_directory,
        generator: generator,
      )
      as "target session is created"
    assert target.registration.id == target_id
    list.each([source.registration.id, target_id], fn(id) {
      let assert poll.Answered(_) =
        poll.until(within: 2000, every: 1, attempt: fn() {
          case manager.resolve(ready.registry, id) {
            Ok(instance) -> poll.Done(instance)
            Error(_) -> poll.Retry
          }
        })
        as "both endpoints become resident"
    })
    let #(socket, _) = connect(port, credential, "/v2/control")
    let _hello = frame(socket, within_ms: 1000)
    let fields = [
      #("source_session", json.String(source.registration.id)),
      #("target_session", json.String(target_id)),
      #("target_strand", json.String("reviewer")),
      #("message_id", json.String("review-1")),
      #("text", json.String("finding")),
      #("epoch", json.String(ready.epoch)),
      #("metadata", json.String("forged metadata")),
    ]
    let denied =
      send(
        socket,
        1,
        "peers.send",
        json.Object([#("source_strand", json.String("unlinked")), ..fields]),
        within_ms: 1000,
      )
    assert field(denied, "event") == json.String("error")
    let body = json.Object([#("source_strand", json.String("main")), ..fields])
    let accepted = send(socket, 2, "peers.send", body, within_ms: 1000)
    assert field(accepted, "event") == json.String("peers.send")
    assert field(field(accepted, "body"), "message_id")
      == json.String("review-1")
    let stopped =
      send(
        socket,
        3,
        "sessions.stop",
        json.Object([
          #("session_id", json.String(target_id)),
          #("epoch", json.String(ready.epoch)),
        ]),
        within_ms: 1000,
      )
    assert field(stopped, "event") == json.String("sessions.stop")
    let assert poll.Answered(Nil) =
      poll.until(within: 2000, every: 1, attempt: fn() {
        case manager.get(ready.registry, target_id) {
          Ok(manager.View(status: manager.Saved, ..)) -> poll.Done(Nil)
          _ -> poll.Retry
        }
      })
      as "the recipient becomes saved"
    let refused = send(socket, 4, "peers.send", body, within_ms: 1000)
    assert field(refused, "event") == json.String("error")
    assert result.is_error(manager.resolve(ready.registry, target_id))
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
  let #(source, _) = ids.mint_session(ids.generator(clock.fixed(0), 400))
  let source_id = ids.session_id_to_string(source)

  // The subject belongs to this test process, not the fixture's worker.
  let assert Ok(#(session, sender, strand, id, text)) =
    process.receive(delivered, 1000)
    as "delivery reaches the selected recipient endpoint"
  assert session == target_id
  assert sender.session == source_id
  assert sender.strand == "main"
  assert strand == "reviewer"
  assert id == "review-1"
  assert text == "finding"
  assert !string.contains(json.to_string(sender.metadata), "forged metadata")
  assert string.contains(json.to_string(sender.metadata), "Source")
  assert process.receive(delivered, 0) == Error(Nil)
}

pub fn peer_cli_routes_inspect_link_send_and_partial_unlink_test() {
  let #(source_id, _) = ids.mint_session(ids.generator(clock.fixed(0), 701))
  let source_id = ids.session_id_to_string(source_id)
  let #(target_id, _) = ids.mint_session(ids.generator(clock.fixed(0), 702))
  let target_id = ids.session_id_to_string(target_id)
  let observed = process.new_subject()
  let endpoint = fn(session) {
    Some(
      peer_mail.Endpoint(session, fn(command) {
        process.send(observed, #(session, command))
        case command {
          peer_mail.Links("main") ->
            Ok(
              json.Array([
                json.Object([
                  #("session", json.String(target_id)),
                  #("strand", json.String("reviewer")),
                ]),
              ]),
            )
          peer_mail.Grants("main") ->
            Ok(
              json.Array([
                json.Object([
                  #("source_session", json.String(target_id)),
                  #("source_strand", json.String("reviewer")),
                  #("target_strand", json.String("main")),
                  #("wake", json.String("busy_only")),
                ]),
              ]),
            )
          peer_mail.Roster(_, _) ->
            Ok(
              json.Array([
                json.Object([
                  #("strand", json.String("reviewer")),
                  #("wake", json.String("may_wake")),
                ]),
              ]),
            )
          peer_mail.Activity(_) -> Ok(json.Object([]))
          peer_mail.Deliver(_, _, id, _) ->
            Ok(json.Object([#("message_id", json.String(id))]))
          peer_mail.Revoke(_) -> Error("recipient unavailable")
          peer_mail.Allow(_)
          | peer_mail.Link(_, _, _)
          | peer_mail.Unlink(_, _, _)
          | peer_mail.Describe(_, _)
          | peer_mail.Links(_)
          | peer_mail.Grants(_)
          | peer_mail.Overview
          | peer_mail.Inbox(..)
          | peer_mail.InboxGet(..)
          | peer_mail.History(..)
          | peer_mail.Received(..)
          | peer_mail.ReceivedGet(..)
          | peer_mail.SentReceipt(..) -> Ok(json.Null)
        }
      }),
    )
  }
  fixture_with_peers(limits.defaults, endpoint, fn(_, ready, port, owner) {
    let assert Ok(source) =
      manager.create(
        ready.registry,
        manager.Creation("cli-source", ready.state_root, "Source", "", None),
        directory: ready.sessions_directory,
        generator: ids.generator(clock.fixed(0), 701),
      )
      as "source session exists"
    let assert Ok(target) =
      manager.create(
        ready.registry,
        manager.Creation("cli-target", ready.state_root, "Target", "", None),
        directory: ready.sessions_directory,
        generator: ids.generator(clock.fixed(0), 702),
      )
      as "target session exists"
    assert source.registration.id == source_id
    assert target.registration.id == target_id
    list.each([source_id, target_id], fn(id) {
      let assert poll.Answered(_) =
        poll.until(within: 2000, every: 1, attempt: fn() {
          case manager.resolve(ready.registry, id) {
            Ok(instance) -> poll.Done(instance)
            Error(_) -> poll.Retry
          }
        })
        as "CLI endpoints become resident"
    })
    let address = "ws://127.0.0.1:" <> int.to_string(port) <> "/v2/control"
    let assert Ok(inspect) = peer_cli.parse(["inspect", source_id, "main"])
    let assert Ok(view) =
      peer_cli.exchange(address, owner, ready.epoch, inspect)
      as "owner can inspect the exact source strand"
    let body = field(view, "result")
    assert field(body, "source_session") == json.String(source_id)
    let assert json.Array([outgoing]) = field(body, "outgoing")
      as "one outgoing target is visible"
    assert field(outgoing, "target_strand") == json.String("reviewer")
    assert field(outgoing, "wake") == json.String("may_wake")
    let assert json.Array([incoming]) = field(body, "incoming")
      as "recipient-owned incoming grants are visible"
    assert field(incoming, "wake") == json.String("busy_only")
    assert field(field(incoming, "metadata"), "session_id")
      == json.String(target_id)

    let assert Ok(link) =
      peer_cli.parse([
        "link", source_id, "main", target_id, "reviewer", "--wake", "may_wake",
      ])
    assert peer_cli.exchange(address, owner, "stale", link)
      == Error("control handshake failed; request not sent")
      as "a stale published epoch prevents the CLI from sending a mutation"
    let member_token = string.repeat("3", 64)
    let assert Ok(digest) =
      member_token
      |> bit_array.from_string
      |> bootstrap.sha256
      |> bit_array.base16_encode
      |> string.lowercase
      |> access.credential_digest
      as "member digest is valid"
    let assert Ok(store) = catalogue.open(ready.state_root <> "/catalogue.db")
      as "member authority can be added through the real catalogue"
    let assert Ok(member) =
      access.create_member(store, "peer-cli-member", "Member", digest)
      as "member credential is durable"
    assert access.grant(store, member.id, source_id, access.Operator) == Ok(Nil)
    assert peer_cli.exchange(address, member_token, ready.epoch, inspect)
      == Error("forbidden")
    assert peer_cli.exchange(address, member_token, ready.epoch, link)
      == Error("forbidden")
    assert catalogue.close(store) == Ok(Nil)
    let assert Ok(linked) = peer_cli.exchange(address, owner, ready.epoch, link)
      as "the owner grant uses real control routing"
    assert field(linked, "command") == json.String("peers.link")
    assert field(linked, "wake") == json.String("may_wake")
    let assert Ok(peer_send) =
      peer_cli.parse([
        "send", source_id, "main", target_id, "reviewer", "--message-id",
        "review-7", "--text", "finding",
      ])
    let assert Ok(receipt) =
      peer_cli.exchange(address, owner, ready.epoch, peer_send)
      as "owner send reaches the resident recipient"
    assert field(receipt, "message_id") == json.String("review-7")
    assert field(field(receipt, "result"), "message_id")
      == json.String("review-7")
    let assert Ok(retried) =
      peer_cli.exchange(address, owner, ready.epoch, peer_send)
      as "an explicit retry retains its message identity"
    assert field(retried, "message_id") == json.String("review-7")

    let assert Ok(unlink_resident) =
      peer_cli.parse(["unlink", source_id, "main", target_id, "reviewer"])
    let assert Ok(partial_resident) =
      peer_cli.exchange(address, owner, ready.epoch, unlink_resident)
      as "a failed recipient revocation retains the source unlink result"
    assert field(partial_resident, "partial") == json.Bool(True)
    assert field(field(partial_resident, "result"), "outgoing_link_removed")
      == json.Bool(True)
    assert field(field(partial_resident, "result"), "recipient_grant")
      == json.String("revoke failed: recipient unavailable")
    let assert Ok(_) = peer_cli.exchange(address, owner, ready.epoch, link)
      as "the source link is restored for saved-recipient inspection"

    let #(socket, _) = connect(port, owner, "/v2/control")
    let _hello = frame(socket, within_ms: 1000)
    let stopped =
      send(
        socket,
        1,
        "sessions.stop",
        json.Object([
          #("session_id", json.String(target_id)),
          #("epoch", json.String(ready.epoch)),
        ]),
        within_ms: 1000,
      )
    let _ = ffi_ws.tcp_close(socket)
    assert field(stopped, "event") == json.String("sessions.stop")
    let assert poll.Answered(Nil) =
      poll.until(within: 2000, every: 1, attempt: fn() {
        case manager.get(ready.registry, target_id) {
          Ok(manager.View(status: manager.Saved, ..)) -> poll.Done(Nil)
          _ -> poll.Retry
        }
      })
      as "recipient is saved"
    let assert Ok(saved_view) =
      peer_cli.exchange(address, owner, ready.epoch, inspect)
      as "inspection describes a saved recipient without opening it"
    let assert json.Array([saved_target]) =
      field(field(saved_view, "result"), "outgoing")
      as "the outgoing link remains visible"
    assert field(saved_target, "wake") == json.Null
    assert field(field(field(saved_target, "metadata"), "status"), "state")
      == json.String("saved")
    assert peer_cli.exchange(address, owner, ready.epoch, peer_send)
      == Error(peers.not_running)
    assert result.is_error(manager.resolve(ready.registry, target_id))
    let assert Ok(unlink) =
      peer_cli.parse(["unlink", source_id, "main", target_id, "reviewer"])
    let assert Ok(partial) =
      peer_cli.exchange(address, owner, ready.epoch, unlink)
      as "outgoing authority is removed without opening the target"
    assert field(partial, "partial") == json.Bool(True)
    assert field(field(partial, "result"), "outgoing_link_removed")
      == json.Bool(True)
  })
}

pub fn peer_cli_collects_bounded_inspection_pages_test() {
  let #(source_id, _) = ids.mint_session(ids.generator(clock.fixed(0), 703))
  let source_id = ids.session_id_to_string(source_id)
  let grants =
    list.index_map(list.repeat(Nil, 800), fn(_, offset) {
      json.Object([
        #("source_session", json.String("source-" <> int.to_string(offset))),
        #("source_strand", json.String("main")),
        #("target_strand", json.String("main")),
        #("wake", json.String("busy_only")),
      ])
    })
  let endpoint = fn(session) {
    Some(
      peer_mail.Endpoint(session, fn(command) {
        case command {
          peer_mail.Activity(_) -> Ok(json.Object([]))
          peer_mail.Links(_) -> Ok(json.Array([]))
          peer_mail.Grants(_) -> Ok(json.Array(grants))
          _ -> Error("unexpected peer command")
        }
      }),
    )
  }
  fixture_with_peers(limits.defaults, endpoint, fn(_, ready, port, owner) {
    let assert Ok(source) =
      manager.create(
        ready.registry,
        manager.Creation(
          "paged-cli-source",
          ready.state_root,
          "Source",
          "",
          None,
        ),
        directory: ready.sessions_directory,
        generator: ids.generator(clock.fixed(0), 703),
      )
    assert source.registration.id == source_id
    let assert poll.Answered(_) =
      poll.until(within: 2000, every: 1, attempt: fn() {
        case manager.resolve(ready.registry, source_id) {
          Ok(instance) -> poll.Done(instance)
          Error(_) -> poll.Retry
        }
      })
    let address = "ws://127.0.0.1:" <> int.to_string(port) <> "/v2/control"
    let assert Ok(command) = peer_cli.parse(["inspect", source_id, "main"])
    let assert Ok(reply) =
      peer_cli.exchange(address, owner, ready.epoch, command)
    let assert json.Array(incoming) = field(field(reply, "result"), "incoming")
    assert list.length(incoming) == 800
  })
}

pub fn session_activity_reports_residents_and_omits_saved_sessions_test() {
  let #(idle, _) = ids.mint_session(ids.generator(clock.fixed(0), 801))
  let #(stuck, _) = ids.mint_session(ids.generator(clock.fixed(0), 802))
  let #(other, _) = ids.mint_session(ids.generator(clock.fixed(0), 804))
  let idle_id = ids.session_id_to_string(idle)
  let stuck_id = ids.session_id_to_string(stuck)
  let other_id = ids.session_id_to_string(other)
  let runtime = gateway_test.reserved_fixture(idle).runtime
  let other_runtime = gateway_test.reserved_fixture(other).runtime

  // The first resident answers from a real runtime through the same handler
  // its Agency actor runs, and so does a third, which the membership cases
  // below ask about. The second never answers, which is what the request
  // deadline is for.
  let endpoint = fn(instance) {
    case instance == idle_id, instance == other_id {
      True, _ ->
        Some(
          peer_mail.Endpoint(instance, fn(command) {
            peer_mail.handle(runtime, clock.fixed(0), command)
          }),
        )
      False, True ->
        Some(
          peer_mail.Endpoint(instance, fn(command) {
            peer_mail.handle(other_runtime, clock.fixed(0), command)
          }),
        )
      False, False ->
        Some(
          peer_mail.Endpoint(instance, fn(_) {
            process.sleep_forever()
            Error("never answers")
          }),
        )
    }
  }
  fixture_with_peers(limits.defaults, endpoint, fn(_, ready, port, credential) {
    list.each([#(idle_id, 801), #(stuck_id, 802)], fn(pair) {
      let assert Ok(created) =
        manager.create(
          ready.registry,
          manager.Creation(pair.0, ready.state_root, pair.0, "", None),
          directory: ready.sessions_directory,
          generator: ids.generator(clock.fixed(0), pair.1),
        )
        as "the session is created"
      assert created.registration.id == pair.0
      let assert poll.Answered(_) =
        poll.until(within: 2000, every: 1, attempt: fn() {
          case manager.resolve(ready.registry, pair.0) {
            Ok(instance) -> poll.Done(instance)
            Error(_) -> poll.Retry
          }
        })
        as "the session becomes resident"
    })
    let #(never, _) = ids.mint_session(ids.generator(clock.fixed(0), 803))
    let never_id = ids.session_id_to_string(never)
    let #(socket, _) = connect(port, credential, "/v2/control")
    let _hello = frame(socket, within_ms: 1000)
    let request = fn(sessions, epoch) {
      json.Object([
        #("sessions", json.Array(list.map(sessions, json.String))),
        #("epoch", json.String(epoch)),
      ])
    }

    // The idle resident answers, the silent one becomes unknown once the
    // deadline passes, and an identity with no registration is left out.
    let reply =
      send(
        socket,
        1,
        "sessions.activity",
        request([idle_id, never_id, stuck_id], ready.epoch),
        within_ms: 5000,
      )
    assert field(reply, "event") == json.String("sessions.activity")
    let assert json.Array([first, second]) =
      field(field(reply, "body"), "activity")
      as "one row per resident, in request order"
    assert field(first, "session_id") == json.String(idle_id)
    assert field(first, "state") == json.String("idle")
    assert field(first, "model") == json.String("loom-1")
    assert second
      == json.Object([
        #("session_id", json.String(stuck_id)),
        #("state", json.String("unknown")),
      ])

    // Once stopped, the silent session is saved and is not asked at all.
    // A pending approval on the other moves it to needs_you.
    let stopped =
      send(
        socket,
        2,
        "sessions.stop",
        json.Object([
          #("session_id", json.String(stuck_id)),
          #("epoch", json.String(ready.epoch)),
        ]),
        within_ms: 1000,
      )
    assert field(stopped, "event") == json.String("sessions.stop")
    let assert poll.Answered(Nil) =
      poll.until(within: 2000, every: 1, attempt: fn() {
        case manager.get(ready.registry, stuck_id) {
          Ok(manager.View(status: manager.Saved, ..)) -> poll.Done(Nil)
          _ -> poll.Retry
        }
      })
      as "the silent session becomes saved"
    let assert Ok(Nil) = api.raise_escalation(runtime, "esc-1", json.Object([]))
      as "an approval is pending"
    let reply =
      send(
        socket,
        3,
        "sessions.activity",
        request([stuck_id, idle_id], ready.epoch),
        within_ms: 1000,
      )
    let assert json.Array([only]) = field(field(reply, "body"), "activity")
      as "the saved session is absent"
    assert field(only, "session_id") == json.String(idle_id)
    assert field(only, "state") == json.String("needs_you")
    assert field(only, "approvals") == json.Int(1)

    // Malformed identity lists are refused whole, before authorization.
    let many =
      list.index_map(list.repeat(Nil, 25), fn(_, seed) {
        let #(id, _) = ids.mint_session(ids.generator(clock.fixed(0), seed))
        ids.session_id_to_string(id)
      })
    list.each(
      [
        request(many, ready.epoch),
        request([idle_id, idle_id], ready.epoch),
        request([], ready.epoch),
      ],
      fn(body) {
        let refused =
          send(socket, 4, "sessions.activity", body, within_ms: 1000)
        assert field(field(refused, "body"), "code")
          == json.String("bad_request")
      },
    )
    let stale =
      send(
        socket,
        5,
        "sessions.activity",
        request([idle_id], "previous-epoch"),
        within_ms: 1000,
      )
    assert field(field(stale, "body"), "code") == json.String("stale_epoch")
    let _ = ffi_ws.tcp_close(socket)

    // The registry holds two residents, so the silent one, now stopped, made
    // room for a third that answers. Nobody holds it yet.
    let assert Ok(_) =
      manager.create(
        ready.registry,
        manager.Creation(other_id, ready.state_root, other_id, "", None),
        directory: ready.sessions_directory,
        generator: ids.generator(clock.fixed(0), 804),
      )
      as "the third session is created"
    let assert poll.Answered(_) =
      poll.until(within: 2000, every: 1, attempt: fn() {
        case manager.resolve(ready.registry, other_id) {
          Ok(instance) -> poll.Done(instance)
          Error(_) -> poll.Retry
        }
      })
      as "the third session becomes resident"

    // A member is answered only for the sessions it holds, at any role. An
    // identity it does not hold is left out as an unknown one is, so the reply
    // is the same whether the session is another's or is not running.
    let member = string.repeat("4", 64)
    let assert Ok(digest) =
      member
      |> bit_array.from_string
      |> bootstrap.sha256
      |> bit_array.base16_encode
      |> string.lowercase
      |> access.credential_digest
      as "member digest is valid"
    let assert Ok(store) = catalogue.open(ready.state_root <> "/catalogue.db")
      as "fixture administration opens the durable catalogue"
    let assert Ok(principal) =
      access.create_member(store, "activity-member", "Member", digest)
      as "member exists"
    assert access.grant(store, principal.id, idle_id, access.Operator)
      == Ok(Nil)
    let #(socket, _) = connect(port, member, "/v2/control")
    let _hello = frame(socket, within_ms: 1000)
    let answered =
      send(
        socket,
        1,
        "sessions.activity",
        request([stuck_id, idle_id], ready.epoch),
        within_ms: 1000,
      )
    let assert json.Array([mine]) = field(field(answered, "body"), "activity")
      as "only the held session has a row"
    assert field(mine, "session_id") == json.String(idle_id)
    assert field(mine, "state") == json.String("needs_you")

    // The stopped session is another's; asking for it alone
    // gives the same empty reply as an identity nobody has.
    let others =
      send(
        socket,
        2,
        "sessions.activity",
        request([stuck_id], ready.epoch),
        within_ms: 1000,
      )
    let unknown =
      send(
        socket,
        3,
        "sessions.activity",
        request([never_id], ready.epoch),
        within_ms: 1000,
      )
    assert field(others, "body") == field(unknown, "body")
    assert field(field(others, "body"), "activity") == json.Array([])

    // The discriminating cases: `other_id` is resident and answers, so only
    // the membership filter keeps it out. A member asking for it and for a
    // held resident is answered for the held one alone.
    let both =
      send(
        socket,
        4,
        "sessions.activity",
        request([other_id, idle_id], ready.epoch),
        within_ms: 1000,
      )
    let assert json.Array([only_held]) = field(field(both, "body"), "activity")
      as "the unheld resident has no row"
    assert field(only_held, "session_id") == json.String(idle_id)
    let _ = ffi_ws.tcp_close(socket)

    // A member with no grant asking for a resident session gets the reply an
    // identity nobody has gets.
    let bystander = string.repeat("8", 64)
    let assert Ok(bystander_digest) =
      bystander
      |> bit_array.from_string
      |> bootstrap.sha256
      |> bit_array.base16_encode
      |> string.lowercase
      |> access.credential_digest
      as "bystander digest is valid"
    let assert Ok(_) =
      access.create_member(
        store,
        "activity-bystander",
        "Bystander",
        bystander_digest,
      )
      as "bystander exists"
    let #(socket, _) = connect(port, bystander, "/v2/control")
    let _hello = frame(socket, within_ms: 1000)
    let resident =
      send(
        socket,
        1,
        "sessions.activity",
        request([idle_id], ready.epoch),
        within_ms: 1000,
      )
    let nobody =
      send(
        socket,
        2,
        "sessions.activity",
        request([never_id], ready.epoch),
        within_ms: 1000,
      )
    assert field(field(resident, "body"), "activity") == json.Array([])
    assert field(resident, "body") == field(nobody, "body")
    let _ = ffi_ws.tcp_close(socket)
    assert catalogue.close(store) == Ok(Nil)
  })
}

// A home page's activity read is the control command's read reduced to a state
// word for each session that answered: a resident that answers is idle, then
// needs you once an approval is pending, a resident that never answers and an
// identity with no resident are left out, and nothing but the state leaves the
// daemon. A member is answered only for the sessions it holds, and a session it
// does not hold reads as an identity nobody has.
pub fn a_homes_activity_read_is_a_state_word_for_each_held_answer_test() {
  let #(idle, _) = ids.mint_session(ids.generator(clock.fixed(0), 811))
  let #(stuck, _) = ids.mint_session(ids.generator(clock.fixed(0), 812))
  let #(absent, _) = ids.mint_session(ids.generator(clock.fixed(0), 813))
  let idle_id = ids.session_id_to_string(idle)
  let stuck_id = ids.session_id_to_string(stuck)
  let absent_id = ids.session_id_to_string(absent)
  let runtime = gateway_test.reserved_fixture(idle).runtime
  let endpoint = fn(instance) {
    case instance == idle_id {
      True ->
        Some(
          peer_mail.Endpoint(instance, fn(command) {
            peer_mail.handle(runtime, clock.fixed(0), command)
          }),
        )
      False ->
        Some(
          peer_mail.Endpoint(instance, fn(_) {
            process.sleep_forever()
            Error("never answers")
          }),
        )
    }
  }
  fixture_with_peers(
    limits.defaults,
    endpoint,
    fn(daemon, ready, _, credential) {
      list.each([#(idle_id, 811), #(stuck_id, 812)], fn(pair) {
        let assert Ok(_) =
          manager.create(
            ready.registry,
            manager.Creation(pair.0, ready.state_root, pair.0, "", None),
            directory: ready.sessions_directory,
            generator: ids.generator(clock.fixed(0), pair.1),
          )
          as "the session is created"
        let assert poll.Answered(_) =
          poll.until(within: 2000, every: 1, attempt: fn() {
            case manager.resolve(ready.registry, pair.0) {
              Ok(instance) -> poll.Done(instance)
              Error(_) -> poll.Retry
            }
          })
          as "the session becomes resident"
      })
      let config =
        server.Config(
          peer_endpoint: endpoint,
          daemon:,
          domain_configuration: "",
          generator: fn() { ids.generator(clock.fixed(1_700_000_000_000), 123) },
          session_upgrade: fn(_, _) {
            response.new(501)
            |> response.set_body(mist.Bytes(bytes_tree.from_string("absent")))
          },
          ui: None,
        )
      let digest_of = fn(token) {
        let assert Ok(digest) =
          token
          |> bit_array.from_string
          |> bootstrap.sha256
          |> bit_array.base16_encode
          |> string.lowercase
          |> access.credential_digest
          as "digest is valid"
        digest
      }
      let assert Ok(store) = catalogue.open(ready.state_root <> "/catalogue.db")
        as "fixture administration opens the durable catalogue"
      let assert Ok(holder) =
        access.create_member(
          store,
          "holder",
          "Holder",
          digest_of("holder-token"),
        )
        as "member exists"
      let assert Ok(_) =
        access.create_member(
          store,
          "bystander",
          "Bystander",
          digest_of("bystander-token"),
        )
        as "member exists"
      assert access.grant(store, holder.id, idle_id, access.Observer) == Ok(Nil)
      assert catalogue.close(store) == Ok(Nil)
      let asked = [idle_id, stuck_id, absent_id]

      // The owner: only the idle resident answers; the rest leave no entry.
      let read =
        server.home_activity(config, ready.registry, digest_of(credential))
      assert read(asked) == [#(idle_id, sessions.Idle)]

      // A pending approval moves it to needs you.
      let assert Ok(Nil) =
        api.raise_escalation(runtime, "esc-1", json.Object([]))
        as "an approval is pending"
      assert read([idle_id]) == [#(idle_id, sessions.NeedsYou)]

      // A member holding the session, at any role, is answered for it, and for
      // nothing else it was asked about.
      let held =
        server.home_activity(config, ready.registry, digest_of("holder-token"))
      assert held(asked) == [#(idle_id, sessions.NeedsYou)]

      // A member holding nothing gets exactly what an unknown identity gets: no
      // row, so a reply cannot tell "not yours" from "not running".
      let bystander =
        server.home_activity(
          config,
          ready.registry,
          digest_of("bystander-token"),
        )
      assert bystander([idle_id]) == []
      assert bystander([absent_id]) == read([absent_id])

      // A credential the catalogue does not know reads nothing.
      assert server.home_activity(config, ready.registry, digest_of("nobody"))(
          asked,
        )
        == []
    },
  )
}

fn sha256_hex(text: String) -> String {
  text
  |> bit_array.from_string
  |> bootstrap.sha256
  |> bit_array.base16_encode
  |> string.lowercase
}

fn digest_of(text: String) -> access.Digest {
  let assert Ok(digest) = access.credential_digest(sha256_hex(text))
    as "fixture digest is valid"
  digest
}

// A bearer is refused on its shape before it is hashed. Each malformed string
// below is registered as a member's credential first, so a daemon that skipped
// the shape check and hashed it would find the row and admit it: the 401 is
// the check, not a missing credential.
pub fn a_bearer_that_is_not_64_lowercase_hex_is_refused_before_any_lookup_test() {
  fixture(fn(_, ready, port, _) {
    let valid = string.repeat("a", 64)
    let malformed = [
      string.repeat("a", 63),
      string.repeat("a", 65),
      string.repeat("A", 64),
      string.repeat("g", 64),
      "loomb1:" <> string.repeat("a", 57),
    ]
    let assert Ok(store) = catalogue.open(ready.state_root <> "/catalogue.db")
      as "fixture administration opens the same durable catalogue"
    let assert Ok(_) =
      access.create_member(store, "shaped", "Shaped", digest_of(valid))
      as "the well-formed member exists"
    list.index_map(malformed, fn(token, index) {
      let assert Ok(_) =
        access.create_member(
          store,
          "malformed-" <> int.to_string(index),
          "Malformed",
          digest_of(token),
        )
        as "a member holds a credential whose plaintext is malformed"
      Nil
    })
    assert catalogue.close(store) == Ok(Nil)

    let #(socket, response) = connect(port, valid, "/v2/control")
    assert string.contains(response, "101")
    let _ = ffi_ws.tcp_close(socket)
    list.each(malformed, fn(token) {
      let #(socket, response) = connect(port, token, "/v2/control")
      assert string.contains(response, "401")
        as "a malformed bearer never authenticates, whatever row its hash names"
      let _ = ffi_ws.tcp_close(socket)
      Nil
    })
  })
}

// 065's attack. A browser login's row is keyed by the digest of the token's
// public identifier, so every holder of the cookie can compute the key. The
// identifier, the whole token and that digest, each presented as a bearer on
// /v2/control, must stay 401 while the row exists.
pub fn a_browser_row_authenticates_on_no_v2_route_test() {
  fixture(fn(_, ready, port, owner_credential) {
    let identifier = string.repeat("5", 64)
    let token = "loomb1:" <> identifier <> "." <> string.repeat("6", 64)
    let assert Ok(claim) = access.claim_digest(string.repeat("7", 64))
      as "claim digest is valid"
    let assert Ok(store) = catalogue.open(ready.state_root <> "/catalogue.db")
      as "fixture administration opens the same durable catalogue"
    let assert Ok(visible) =
      manager.create(
        ready.registry,
        manager.Creation("visible", ready.state_root, "Visible", "", None),
        directory: ready.sessions_directory,
        generator: ids.generator(clock.fixed(0), 100),
      )
      as "a session for the membership"
    let assert Ok(member) =
      access.invite_member(
        store,
        "login-holder",
        "Login holder",
        access.ClaimEnrollment(claim, 4_000_000_000_000),
        visible.registration.id,
        access.Operator,
      )
      as "the member awaits its claim"
    let assert Ok(login) = access.browser_digest(sha256_hex(identifier))
      as "the login's digest is valid"
    let assert Ok(_) =
      access.claim_login(
        store,
        claim,
        login,
        None,
        1,
        4_000_000_000_000,
        fn(a, b) { a == b },
      )
      as "the browser row is bound"
    assert access.authenticate(store, login) == Ok(member)
    assert catalogue.close(store) == Ok(Nil)

    list.each([identifier, token, sha256_hex(identifier)], fn(presented) {
      let #(socket, response) = connect(port, presented, "/v2/control")
      assert string.contains(response, "401")
        as "nothing derived from a browser login authenticates as a bearer"
      let _ = ffi_ws.tcp_close(socket)
      Nil
    })

    // The owner's bearer is unaffected by the row's existence.
    let #(socket, response) = connect(port, owner_credential, "/v2/control")
    assert string.contains(response, "101")
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

// --- profiles (protocol-change/076) -----------------------------------------

const profiled_catalogue =
  "
[models.base]
dialect = \"anthropic\"
api_key_env = \"UNUSED_TEST_KEY\"
model_id = \"base-model\"
context_window = 1000
max_output_tokens = 100
[models.alt]
dialect = \"openai\"
api_key_env = \"UNUSED_TEST_KEY\"
model_id = \"alt-model\"
context_window = 2000
max_output_tokens = 200
[roles]
main = [\"base\"]
[profiles.alt.roles]
main = [\"alt\"]
[profiles.other.roles]
main = [\"alt\"]
"

fn profiled_creation(
  ready: root.Ready(String),
  key: String,
  profile: List(#(String, json.JsonValue)),
) -> json.JsonValue {
  json.Object([
    #("request_key", json.String(key)),
    #("workspace", json.String(ready.state_root)),
    #("name", json.String("Profiled")),
    #("configuration", json.String(ready.state_root <> "/profiled.toml")),
    ..profile
  ])
}

pub fn a_creation_stores_its_profile_and_a_retry_must_repeat_it_test() {
  fixture(fn(_, ready, port, credential) {
    assert simplifile.write(
        ready.state_root <> "/profiled.toml",
        profiled_catalogue,
      )
      == Ok(Nil)
    let #(socket, _) = connect(port, credential, "/v2/control")
    let _hello = frame(socket, within_ms: 1000)
    let named =
      profiled_creation(ready, "profiled", [
        #("profile", json.String("alt")),
      ])
    let created = send(socket, 1, "sessions.create", named, within_ms: 1000)
    assert field(created, "event") == json.String("sessions.create")
    let assert json.String(id) = field(field(created, "body"), "session_id")
      as "creation exposes its identity"

    // The registration holds the name, which a resume resolves again.
    let assert Ok(saved) = manager.get(ready.registry, id)
      as "the creation reply follows durable registration"
    assert saved.registration.profile == Some("alt")

    // The same request is the same session, and a different profile under the
    // same key is a different request.
    let retried = send(socket, 2, "sessions.create", named, within_ms: 1000)
    assert field(field(retried, "body"), "session_id") == json.String(id)
    let changed =
      send(
        socket,
        3,
        "sessions.create",
        profiled_creation(ready, "profiled", [
          #("profile", json.String("other")),
        ]),
        within_ms: 1000,
      )
    assert field(changed, "event") == json.String("error")
    assert field(field(changed, "body"), "code") == json.String("conflict")
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn an_unknown_profile_is_refused_naming_the_known_ones_and_stores_nothing_test() {
  fixture(fn(_, ready, port, credential) {
    assert simplifile.write(
        ready.state_root <> "/profiled.toml",
        profiled_catalogue,
      )
      == Ok(Nil)
    let #(socket, _) = connect(port, credential, "/v2/control")
    let _hello = frame(socket, within_ms: 1000)
    let refused =
      send(
        socket,
        1,
        "sessions.create",
        profiled_creation(ready, "unknown", [
          #("profile", json.String("alt2")),
        ]),
        within_ms: 1000,
      )
    assert field(refused, "event") == json.String("error")
    let body = field(refused, "body")
    assert field(body, "code") == json.String("unknown_profile")
    assert field(body, "message")
      == json.String(
        "unknown profile \"alt2\"; the configuration defines: alt, other",
      )

    // No identity was reserved for the refused request.
    let assert Ok(page) = catalogue_page(ready)
    assert page == []

    // A name that is not a profile name is a malformed request, not a lookup.
    let malformed =
      send(
        socket,
        2,
        "sessions.create",
        profiled_creation(ready, "malformed", [
          #("profile", json.String("Not A Name")),
        ]),
        within_ms: 1000,
      )
    assert field(malformed, "event") == json.String("error")
    assert field(field(malformed, "body"), "code") == json.String("bad_request")
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn a_profile_with_no_config_file_names_the_missing_file_test() {
  fixture(fn(_, ready, port, credential) {
    let #(socket, _) = connect(port, credential, "/v2/control")
    let _hello = frame(socket, within_ms: 1000)
    let refused =
      send(
        socket,
        1,
        "sessions.create",
        json.Object([
          #("request_key", json.String("no-file")),
          #("workspace", json.String(ready.state_root)),
          #("name", json.String("No file")),
          #("configuration", json.String("")),
          #("profile", json.String("alt")),
        ]),
        within_ms: 1000,
      )
    let body = field(refused, "body")
    assert field(body, "code") == json.String("unknown_profile")
    assert field(body, "message")
      == json.String(
        "unknown profile \"alt\"; the configuration defines no profiles",
      )
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

fn catalogue_page(ready: root.Ready(String)) {
  manager.page(ready.registry, after: "")
  |> result.map(fn(page) { page.1 })
}
