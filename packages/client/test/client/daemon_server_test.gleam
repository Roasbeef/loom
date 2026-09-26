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
import client/peer_mail
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
import simplifile
import storage/access
import storage/catalogue
import support/internal/ffi_daemon_socket
import support/internal/ffi_ws.{type Socket}
import tui/connection
import tui/daemon/protocol as terminal_protocol
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
/// ## Examples
///
/// ```gleam
/// // daemon_server_test.reply(socket, 100, "prompt", body, within_ms: 1000)
/// ```
@internal
pub fn reply(socket, id, command, body, within_ms within_ms: Int) {
  answered(socket, send(socket, id, command, body, within_ms:), 16, within_ms)
}

fn answered(socket, value, remaining: Int, within_ms: Int) {
  assert remaining > 0 as "the reply arrives within a bounded run of notices"
  let assert json.Object(fields) = value as "the wire value is an object"
  case list.key_find(fields, "reply_to") {
    Ok(_) -> value
    Error(Nil) ->
      answered(socket, frame(socket, within_ms:), remaining - 1, within_ms)
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
    let credential = "member-wire-token"
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
        manager.Creation("visible", ready.state_root, "Visible", ""),
        directory: ready.sessions_directory,
        generator: ids.generator(clock.fixed(0), 100),
      )
      as "owner reserves one visible session"
    let assert Ok(hidden) =
      manager.create(
        ready.registry,
        manager.Creation("hidden", ready.state_root, "Hidden", ""),
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
    let credential = "member-delete-token"
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
        manager.Creation("member-visible", ready.state_root, "Visible", ""),
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
        manager.Creation("source", ready.state_root, "Source", ""),
        directory: ready.sessions_directory,
        generator: ids.generator(clock.fixed(0), 400),
      )
      as "source session is created"
    let assert Ok(target) =
      manager.create(
        ready.registry,
        manager.Creation("target", ready.state_root, "Target", ""),
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
          | peer_mail.Overview -> Ok(json.Null)
        }
      }),
    )
  }
  fixture_with_peers(limits.defaults, endpoint, fn(_, ready, port, owner) {
    let assert Ok(source) =
      manager.create(
        ready.registry,
        manager.Creation("cli-source", ready.state_root, "Source", ""),
        directory: ready.sessions_directory,
        generator: ids.generator(clock.fixed(0), 701),
      )
      as "source session exists"
    let assert Ok(target) =
      manager.create(
        ready.registry,
        manager.Creation("cli-target", ready.state_root, "Target", ""),
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
    let member_token = "peer-cli-member-token"
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
      == Error("unavailable")
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
        manager.Creation("paged-cli-source", ready.state_root, "Source", ""),
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
