//// Real SQLite and WebSocket tests exercise the v2 control boundary.
//// The assembly is inert: these tests establish routing and authorization,
//// not native session cleanup, which the owned assembly suite tests separately.

import broker/token
import client/daemon/domain as domain_service
import client/daemon/manager
import client/daemon/root
import client/daemon/server
import core/clock
import core/ids
import core/json
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/response
import gleam/list
import gleam/string
import host/bootstrap
import mist
import simplifile
import storage/access
import storage/catalogue
import support/internal/ffi_daemon_socket
import support/internal/ffi_ws.{type Socket}
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
  let directory =
    "build/test_db/daemon-wire-"
    <> bit_array.base16_encode(token.production_entropy()(8))
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
    as "private fixture directory exists"
  let assert Ok(daemon) =
    root.start(
      root.Config(directory, "Owner", 2),
      manager.Assembly(
        domain_build: fn(_, _, _) { Ok(domain_service.inert()) },
        build: fn(record, _domain, _services, _) { Ok(record.id) },
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

@internal
pub fn frame(socket: Socket) {
  let assert Ok(<<0x81, marker>>) = ffi_ws.tcp_receive(socket, 2, 1000)
    as "server sends a text frame"
  let size = case marker {
    126 -> {
      let assert Ok(<<size:16>>) = ffi_ws.tcp_receive(socket, 2, 1000)
        as "extended frame length arrives"
      size
    }
    size if size < 126 -> size
    _ -> panic as "control response exceeds fixture frame budget"
  }
  let assert Ok(bytes) = ffi_ws.tcp_receive(socket, size, 1000)
    as "complete response arrives"
  let assert Ok(text) = bit_array.to_string(bytes) as "response is UTF-8"
  let assert Ok(value) = json.parse(text) as "response is total JSON"
  value
}

@internal
pub fn send(socket, id, command, body) {
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
  frame(socket)
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
/// // daemon_server_test.reply(socket, 100, "prompt", body)
/// ```
@internal
pub fn reply(socket, id, command, body) {
  answered(socket, send(socket, id, command, body), 16)
}

fn answered(socket, value, remaining: Int) {
  assert remaining > 0 as "the reply arrives within a bounded run of notices"
  let assert json.Object(fields) = value as "the wire value is an object"
  case list.key_find(fields, "reply_to") {
    Ok(_) -> value
    Error(Nil) -> answered(socket, frame(socket), remaining - 1)
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
    let hello = frame(socket)
    assert field(hello, "v") == json.Int(2)
    assert field(hello, "event") == json.String("hello")
    let status = send(socket, 1, "status", json.Object([]))
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
      )
    assert field(field(listing, "body"), "sessions") == json.Array([])
    let stale =
      send(
        socket,
        3,
        "daemon.shutdown",
        json.Object([#("epoch", json.String("previous-epoch"))]),
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
    let _hello = frame(socket)
    let denied =
      send(
        socket,
        1,
        "sessions.default",
        json.Object([#("workspace", json.String(ready.state_root))]),
      )
    assert field(field(denied, "body"), "code") == json.String("forbidden")
    let listing =
      send(
        socket,
        2,
        "sessions.list",
        json.Object([#("after", json.String(""))]),
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
      )
    assert field(field(denied, "body"), "code") == json.String("forbidden")
    assert access.revoke_credential(store, digest) == Ok(Nil)
    let revoked = send(socket, 4, "status", json.Object([]))
    assert field(field(revoked, "body"), "code") == json.String("unauthorized")
    let _ = ffi_ws.tcp_close(socket)
    assert catalogue.close(store) == Ok(Nil)
  })
}

pub fn explicit_creation_default_operation_and_stop_roundtrip_test() {
  fixture(fn(_, ready, port, credential) {
    assert simplifile.write(ready.state_root <> "/loom.toml", "") == Ok(Nil)
    let #(socket, _) = connect(port, credential, "/v2/control")
    let _hello = frame(socket)
    let creation =
      json.Object([
        #("request_key", json.String("wire-create")),
        #("workspace", json.String(ready.state_root)),
        #("name", json.String("Wire session")),
        #("configuration", json.String(ready.state_root <> "/loom.toml")),
      ])
    let created = send(socket, 1, "sessions.create", creation)
    assert field(created, "event") == json.String("sessions.create")
    let assert json.String(id) = field(field(created, "body"), "session_id")
      as "creation exposes its reserved canonical identity"
    let retried = send(socket, 2, "sessions.create", creation)
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
    let _hello = frame(socket)
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
    assert field(field(frame(socket), "body"), "code")
      == json.String("unsupported_version")
    assert ffi_daemon_socket.send(socket, <<0x81, 0xff, 1_000_000:64>>)
      == Ok(Nil)
    assert ffi_ws.tcp_receive(socket, 4, 1000) == Ok(<<0x88, 2, 1009:16>>)
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}
