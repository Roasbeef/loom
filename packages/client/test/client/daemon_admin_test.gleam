//// Owner administration crosses the real control socket and shared transport.
//// These fixtures assemble no native resources; they prove authority, recovery,
//// and bearer handling rather than sandbox or provider behavior.

import client/daemon/admin
import client/daemon/manager
import client/daemon_server_test
import client/session_socket_test
import core/clock
import core/ids
import core/json
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import mist
import storage/access
import storage/catalogue
import storage/domain
import support/internal/ffi_daemon_socket
import support/internal/ffi_ws
import weft
import weft/poll

fn field(value, key) {
  let assert json.Object(fields) = value as "response is an object"
  let assert Ok(value) = list.key_find(fields, key) as "response field exists"
  value
}

fn parsed(arguments) {
  let assert Ok(request) = admin.parse(arguments) as "admin arguments are valid"
  request
}

pub fn admin_cli_has_no_implicit_identity_or_owner_role_test() {
  let assert Error(_) = admin.parse(["invite"])
    as "missing identity is not generated"
  let assert Error(_) = admin.parse(["rotate", "member\nforged"])
    as "recovery identifiers cannot inject terminal output"
  let assert Error(_) = admin.parse(["rotate", string.repeat("a", 129)])
    as "principal identifiers are bounded"
  let #(session, _) = ids.mint_session(ids.generator(clock.fixed(1), 1))
  let assert Error(_) =
    admin.parse([
      "invite",
      ids.session_id_to_string(session),
      "member",
      "owner",
      "Member",
    ])
    as "the CLI cannot request owner authority for a member"
}

pub fn withheld_hello_reports_not_sent_and_sends_no_mutation_test() {
  let listeners = process.new_subject()

  // The listener and the assertions share one task: the subject that observes
  // the withheld mutation can only be received on by the process that owns it,
  // and a failed assertion must not leave a live loopback listener behind. The
  // pid is published before the body runs, so this process can retire the
  // listener whether the body passed, failed, or ran out of time.
  let outcomes =
    weft.new([
      fn() {
        let commands = process.new_subject()
        let ports = process.new_subject()
        let assert Ok(listener) =
          mist.new(fn(request) {
            mist.websocket_with_options(
              request:,
              options: mist.WebsocketOptions(
                65_536,
                65_536,
                mist.CompressionDisabled,
              ),
              on_init: fn(_) { #(Nil, None) },
              on_close: fn(_) { Nil },
              handler: fn(_, message, _) {
                case message {
                  mist.Text(text) -> {
                    process.send(commands, text)
                    mist.continue(Nil)
                  }
                  mist.Custom(Nil) -> mist.continue(Nil)
                  mist.Binary(_) | mist.Closed | mist.Shutdown -> mist.stop()
                }
              },
            )
          })
          |> mist.bind("127.0.0.1")
          |> mist.port(0)
          |> mist.after_start(fn(port, _, _) { process.send(ports, port) })
          |> mist.start
          as "the test listener upgrades but deliberately withholds its hello"
        process.send(listeners, listener.pid)
        process.unlink(listener.pid)
        let assert Ok(port) = process.receive(ports, 1000)
          as "listener reports its port"
        let address = "ws://127.0.0.1:" <> int.to_string(port) <> "/v2/control"
        assert admin.exchange(
            address,
            string.repeat("a", 64),
            "epoch",
            parsed(["rotate", "member"]),
          )
          == Error("control handshake failed; request not sent")
        assert process.receive(commands, 0) == Error(Nil)
        Ok(Nil)
      },
    ])
    |> weft.deadline(40_000)
    |> weft.start

  // The publication precedes everything that can fail, so this answers at once
  // for a listener that started. Only the case where the bind itself failed
  // waits, and it waits for a bounded moment rather than reading the empty
  // mailbox of a task whose send has not landed yet.
  case process.receive(listeners, 100) {
    Ok(pid) -> process.kill(pid)
    Error(Nil) -> Nil
  }
  let assert [weft.Completed(0, Nil)] = outcomes
    as "the withheld-hello exchange completed on its own task"
  Nil
}

pub fn owner_explicit_isolation_control_preserves_transcript_consent_test() {
  daemon_server_test.fixture(fn(_, ready, port, token) {
    let assert Ok(view) =
      manager.create(
        ready.registry,
        manager.Creation("isolate-wire", "/workspace", "Private", ""),
        directory: ready.sessions_directory,
        generator: ids.generator(clock.fixed(1), 906),
      )
      as "private session created"
    let session = view.registration.id
    let address = "ws://127.0.0.1:" <> int.to_string(port) <> "/v2/control"
    let invite = parsed(["invite", session, "shared", "observer", "Shared"])
    let assert Error(reason) =
      admin.exchange(address, token, ready.epoch, invite)
      as "private domain cannot invite"
    assert string.starts_with(reason, "isolation_required")
    let assert Error(_) = admin.parse(["isolate", session])
      as "consent cannot be inferred"
    let assert Ok(_) = manager.stop_session(ready.registry, session)
      as "stop requested"
    assert poll.until(within: 2000, every: 1, attempt: fn() {
        case manager.get(ready.registry, session) {
          Ok(manager.View(status: manager.Saved, ..)) -> poll.Done(Nil)
          Ok(_) -> poll.Retry
          Error(error) -> poll.Fail(error)
        }
      })
      == poll.Answered(Nil)
    let isolate = parsed(["isolate", session, "--share-existing-transcript"])
    let assert Ok(reply) = admin.exchange(address, token, ready.epoch, isolate)
      as "explicit isolation succeeds"
    assert field(reply, "domain_scope") == json.String("session_only")
    assert admin.exchange(address, token, ready.epoch, isolate) == Ok(reply)
    let assert Ok(_) = admin.exchange(address, token, ready.epoch, invite)
      as "invitation is now in declared session scope"
    Nil
  })
}

pub fn owner_admin_real_transport_rotates_and_revokes_members_test() {
  daemon_server_test.fixture(fn(_, ready, port, owner_token) {
    let assert Ok(view) =
      manager.create_scoped(
        ready.registry,
        manager.Creation("admin-session", "/workspace", "Session", ""),
        directory: ready.sessions_directory,
        generator: ids.generator(clock.fixed(1), 902),
        scope: domain.SessionOnly,
        configuration: "",
      )
      as "explicit creation registers one session"
    let session = view.registration.id
    let address = "ws://127.0.0.1:" <> int.to_string(port) <> "/v2/control"
    let invite = parsed(["invite", session, "alice", "observer", "Alice"])
    let assert Ok(invited) =
      admin.exchange(address, owner_token, ready.epoch, invite)
      as "owner invitation returns the only explicit bearer result"
    let assert json.String(first) = field(invited, "bearer")
      as "invitation returns a bearer"
    assert string.byte_size(first) == 64
    let rotate = parsed(["rotate", "alice"])
    assert admin.exchange(address, first, ready.epoch, rotate)
      == Error("forbidden")
    assert admin.exchange(address, owner_token, "previous-epoch", rotate)
      == Error("control handshake failed; request not sent")
    assert admin.exchange(address, owner_token, ready.epoch, invite)
      == Error("conflict")

    // Rotation uses only the retained principal ID, not the previous secret.
    let assert Ok(rotated) =
      admin.exchange(address, owner_token, ready.epoch, rotate)
      as "owner recovers the same principal through explicit rotation"
    let assert json.String(second) = field(rotated, "bearer")
      as "rotation returns a fresh bearer"
    assert second != first
    let #(old, rejected) =
      daemon_server_test.connect(port, first, "/v2/control")
    assert string.contains(rejected, "401")
    let _ = ffi_ws.tcp_close(old)
    let set_role = parsed(["set-role", session, "alice", "operator"])
    let assert Ok(changed) =
      admin.exchange(address, owner_token, ready.epoch, set_role)
      as "owner changes only the selected membership"
    let assert json.Object(changed_fields) = changed
      as "mutation response is an object"
    assert list.key_find(changed_fields, "bearer") == Error(Nil)
    let revoke = parsed(["revoke-credentials", "alice"])
    let assert Ok(_) = admin.exchange(address, owner_token, ready.epoch, revoke)
      as "owner revokes every active member credential"
    let #(old, rejected) =
      daemon_server_test.connect(port, second, "/v2/control")
    assert string.contains(rejected, "401")
    let _ = ffi_ws.tcp_close(old)
    Nil
  })
}

fn send_unread(socket, command, body) {
  let bytes =
    bit_array.from_string(
      json.to_string(
        json.Object([
          #("v", json.Int(2)),
          #("id", json.Int(21)),
          #("cmd", json.String(command)),
          #("body", body),
        ]),
      ),
    )
  let size = bit_array.byte_size(bytes)
  assert size < 65_536 as "the test mutation fits one bounded frame"
  assert ffi_daemon_socket.send(socket, <<
      0x81,
      0xfe,
      size:16,
      0:32,
      bytes:bits,
    >>)
    == Ok(Nil)
}

pub fn owner_role_change_closes_original_member_attachment_test() {
  session_socket_test.fixture(fn(port, owner_token, session, epoch, _) {
    let address = "ws://127.0.0.1:" <> int.to_string(port) <> "/v2/control"
    let invite = parsed(["invite", session, "observer", "observer", "Observer"])
    let assert Ok(invited) = admin.exchange(address, owner_token, epoch, invite)
      as "owner grants one observer membership"
    let assert json.String(member_token) = field(invited, "bearer")
      as "member receives its own credential"
    let #(socket, response) =
      daemon_server_test.connect(
        port,
        member_token,
        "/v2/sessions/" <> session <> "/ws",
      )
    assert string.contains(response, "101 Switching Protocols")
    let begin =
      daemon_server_test.send(
        socket,
        1,
        "subscribe",
        json.Object([
          #("session", json.String(session)),
        ]),
        within_ms: 1000,
      )
    assert field(field(begin, "body"), "role") == json.String("observer")
    let assert Ok(_) =
      admin.exchange(
        address,
        owner_token,
        epoch,
        parsed(["set-role", session, "observer", "operator"]),
      )
      as "owner changes the role after attachment"

    // A role change cannot silently enlarge the old attachment's parser budget.
    send_unread(
      socket,
      "snapshot_next",
      json.Object([
        #("snapshot_id", field(field(begin, "body"), "snapshot_id")),
        #("index", json.Int(0)),
      ]),
    )
    let assert Ok(<<0x88, size>>) = ffi_ws.tcp_receive(socket, 2, 1000)
      as "the next continuation closes the original role-bound socket"
    assert size <= 125
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn lost_invitation_reply_recovers_by_explicit_principal_rotation_test() {
  daemon_server_test.fixture(fn(_, ready, port, owner_token) {
    let assert Ok(view) =
      manager.create_scoped(
        ready.registry,
        manager.Creation("lost-invite-session", "/workspace", "Session", ""),
        directory: ready.sessions_directory,
        generator: ids.generator(clock.fixed(1), 903),
        scope: domain.SessionOnly,
        configuration: "",
      )
      as "explicit session metadata exists"
    let #(socket, response) =
      daemon_server_test.connect(port, owner_token, "/v2/control")
    assert string.contains(response, "101 Switching Protocols")
    let _ = daemon_server_test.frame(socket, within_ms: 1000)
    send_unread(
      socket,
      "sessions.invite",
      json.Object([
        #("session_id", json.String(view.registration.id)),
        #("principal_id", json.String("lost-reply")),
        #("name", json.String("Lost Reply")),
        #("role", json.String("observer")),
        #("epoch", json.String(ready.epoch)),
      ]),
    )

    // The invitation commits, but this caller never consumes its bearer reply.
    let assert Ok(observer) =
      catalogue.open(ready.state_root <> "/catalogue.db")
      as "a separate read connection can observe committed identity"
    let outcome =
      poll.until(within: 1000, every: 1, attempt: fn() {
        case access.get(observer, "lost-reply") {
          Ok(principal) -> poll.Done(principal)
          Error(catalogue.Missing) -> poll.Retry
          Error(_) -> poll.Fail(Nil)
        }
      })
    let assert poll.Answered(original) = outcome
      as "the first request committed before its response was discarded"
    assert catalogue.close(observer) == Ok(Nil)
    let _ = ffi_ws.tcp_close(socket)
    let address = "ws://127.0.0.1:" <> int.to_string(port) <> "/v2/control"
    let assert Ok(recovered) =
      admin.exchange(
        address,
        owner_token,
        ready.epoch,
        parsed(["rotate", original.id]),
      )
      as "explicit rotation recovers the existing principal without retrying invite"
    assert field(recovered, "principal_id") == json.String(original.id)
    let assert json.String(bearer) = field(recovered, "bearer")
      as "only the replacement bearer is returned to this caller"
    let #(socket, response) =
      daemon_server_test.connect(port, bearer, "/v2/control")
    assert string.contains(response, "101 Switching Protocols")
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}
