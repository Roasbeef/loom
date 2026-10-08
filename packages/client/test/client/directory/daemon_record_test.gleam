//// The control socket of a daemon that is a session directory member
//// (protocol-change/079), over the real registry and a one-member Khepri store
//// in the test VM. These tests prove what the socket does with the record:
//// a remote creation writes it before the session can be served, a remote
//// delete marks the session, deletes the record and only then the
//// registration, a record that names someone else refuses the delete and
//// clears the mark, and a write without a quorum is refused `no_quorum` and
//// leaves the mark so nothing opens the session, and opening a session the
//// daemon holds needs no store at all. The store is a VM-wide
//// singleton, so the module is declared serial.

import client/daemon/limits
import client/daemon/manager
import client/daemon/root
import client/daemon_server_test as wire
import client/directory/member
import client/directory/ownership.{type Ownership, Ownership}
import client/directory/record.{Moving, Record, Serving}
import client/directory/store
import client/session_directory
import core/json
import gleam/list
import gleam/option.{None, Some}
import support/internal/ffi_ws
import support/remote_fixtures
import weft/poll

const alpha = "alpha@10.0.0.1"

const bravo = "bravo@10.0.0.4"

fn field(value, key) {
  let assert json.Object(fields) = value as "envelope is an object"
  let assert Ok(value) = list.key_find(fields, key)
    as "expected field is present"
  value
}

fn code(frame) -> json.JsonValue {
  assert field(frame, "event") == json.String("error")
  field(field(frame, "body"), "code")
}

fn with_store(body: fn() -> Nil) -> Nil {
  let directory = remote_fixtures.scratch("daemon-record") <> "/directory"
  let assert Ok(Nil) = store.start_system(directory) as "the Ra system starts"
  let assert Ok(Nil) = store.boot(10_000) as "a one-member store starts"
  body()
  store.stop()
}

// A daemon whose directory reads the store and writes through `writes`.
fn member_daemon(
  writes: Ownership,
  run: fn(root.Ready(String), Int, String) -> Nil,
) {
  let directory =
    session_directory.khepri([], alpha, store.read)
    |> session_directory.as_member(Some(writes), fn() { status() })
  wire.fixture_directing(
    limits.defaults,
    fn(_) { None },
    fn(record, _domain, _services, _owner, _directory) { Ok(record.id) },
    directory,
    fn(_, ready, port, credential) { run(ready, port, credential) },
  )
}

fn status() -> member.Status {
  member.Status(
    members: [alpha, bravo, "exec@10.0.0.3"],
    joining: member.Joined,
    ra: store.membership(),
    applied_index: store.applied_index(),
  )
}

// Ownership whose writes never commit, as on a member cut off from the majority.
fn quorumless() -> Ownership {
  let refused = Error(store.NoQuorum("the directory has no quorum"))
  Ownership(
    ..ownership.over_store(alpha),
    create: fn(_) { refused },
    release: fn(_) { refused },
  )
}

fn creation(key: String) -> json.JsonValue {
  json.Object([
    #("request_key", json.String(key)),
    #("workspace", json.String("repo")),
    #("name", json.String("Remote")),
    #("configuration", json.String("")),
    #("executor", json.String("build-box")),
  ])
}

fn command(socket, id, name, session, epoch) {
  wire.send(
    socket,
    id,
    name,
    json.Object([
      #("session_id", json.String(session)),
      #("epoch", json.String(epoch)),
    ]),
    within_ms: 2000,
  )
}

// Creates a remote session over the socket and waits until it has stopped, so
// a delete finds no slot open.
fn saved_remote(socket, ready: root.Ready(String), key: String) -> String {
  let created =
    wire.send(socket, 1, "sessions.create", creation(key), within_ms: 5000)
  assert field(created, "event") == json.String("sessions.create")
  let assert json.String(id) = field(field(created, "body"), "session_id")
    as "the creation names the session"
  let assert poll.Answered(Nil) =
    poll.until(within: 15_000, every: 20, attempt: fn() {
      case manager.get(ready.registry, id) {
        Ok(manager.View(status: manager.Saved, ..)) -> poll.Done(Nil)
        // A session stopped while it is still opening is cancelled before its
        // registration is confirmed, so the stop waits for it to be resident.
        Ok(manager.View(status: manager.Resident(..), ..)) -> {
          let _stopped = manager.stop_session(ready.registry, id)
          poll.Retry
        }
        _ -> poll.Retry
      }
    })
    as "the session stops"
  id
}

pub fn a_remote_creation_records_this_daemon_as_owner_test() {
  use <- with_store
  member_daemon(ownership.over_store(alpha), fn(ready, port, credential) {
    let #(socket, _) = wire.connect(port, credential, "/v2/control")
    let _hello = wire.frame(socket, within_ms: 1000)
    let id = saved_remote(socket, ready, "recorded")
    assert store.read(id) == Ok(Some(Record(owner: alpha, state: Serving)))

    // A retry under the same key finds the record already naming this daemon.
    let again =
      wire.send(
        socket,
        2,
        "sessions.create",
        creation("recorded"),
        within_ms: 5000,
      )
    assert field(field(again, "body"), "session_id") == json.String(id)
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn a_remote_creation_without_a_quorum_is_refused_and_not_served_test() {
  use <- with_store
  member_daemon(quorumless(), fn(ready, port, credential) {
    let #(socket, _) = wire.connect(port, credential, "/v2/control")
    let _hello = wire.frame(socket, within_ms: 1000)
    let refused =
      wire.send(
        socket,
        1,
        "sessions.create",
        creation("quorumless"),
        within_ms: 5000,
      )
    assert code(refused) == json.String("no_quorum")

    // The reservation stays, unopened, so the same key can complete it later.
    let assert Ok(#(_, views)) = manager.page(ready.registry, after: "")
      as "the page reads"
    assert list.all(views, fn(view) { view.status == manager.Reserved })
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn a_remote_delete_removes_the_record_then_the_registration_test() {
  use <- with_store
  member_daemon(ownership.over_store(alpha), fn(ready, port, credential) {
    let #(socket, _) = wire.connect(port, credential, "/v2/control")
    let _hello = wire.frame(socket, within_ms: 1000)
    let id = saved_remote(socket, ready, "deleted")
    let deleted = command(socket, 3, "sessions.delete", id, ready.epoch)
    assert field(deleted, "event") == json.String("sessions.delete")
    assert store.read(id) == Ok(None)
    assert manager.deleting_sessions(ready.registry) == Ok([])
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn a_delete_of_a_session_the_record_gives_to_another_is_refused_test() {
  use <- with_store
  member_daemon(ownership.over_store(alpha), fn(ready, port, credential) {
    let #(socket, _) = wire.connect(port, credential, "/v2/control")
    let _hello = wire.frame(socket, within_ms: 1000)
    let id = saved_remote(socket, ready, "theirs")

    // The record says bravo owns it; this daemon's catalogue still has it.
    let assert Ok(Nil) =
      store.swap(
        id,
        Record(owner: alpha, state: Serving),
        Record(owner: bravo, state: Serving),
        store.write_ms,
      )
      as "the record moves to bravo"
    let refused = command(socket, 3, "sessions.delete", id, ready.epoch)
    assert code(refused) == json.String("not_owner")

    // The mark is cleared and the registration is untouched.
    assert manager.deleting_sessions(ready.registry) == Ok([])
    let assert Ok(_) = manager.get(ready.registry, id) as "still registered"
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn a_delete_of_a_session_this_daemon_is_moving_is_refused_as_moving_test() {
  use <- with_store
  member_daemon(ownership.over_store(alpha), fn(ready, port, credential) {
    let #(socket, _) = wire.connect(port, credential, "/v2/control")
    let _hello = wire.frame(socket, within_ms: 1000)
    let id = saved_remote(socket, ready, "moving")
    let assert Ok(Nil) =
      store.swap(
        id,
        Record(owner: alpha, state: Serving),
        Record(
          owner: alpha,
          state: Moving(op: "0192f3c1-0000-7000-8000-000000000001", to: bravo),
        ),
        store.write_ms,
      )
      as "the record says this daemon is moving it"
    let refused = command(socket, 3, "sessions.delete", id, ready.epoch)
    assert code(refused) == json.String("moving")
    assert manager.deleting_sessions(ready.registry) == Ok([])
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn a_delete_without_a_quorum_keeps_the_mark_and_the_session_closed_test() {
  use <- with_store
  member_daemon(ownership.over_store(alpha), fn(ready, port, credential) {
    let #(socket, _) = wire.connect(port, credential, "/v2/control")
    let _hello = wire.frame(socket, within_ms: 1000)
    let id = saved_remote(socket, ready, "stuck")

    // The record write is refused by stopping the store under the running
    // daemon, as a member cut off from the majority would refuse it.
    store.stop()
    let refused = command(socket, 3, "sessions.delete", id, ready.epoch)
    assert code(refused) == json.String("no_quorum")
    assert manager.deleting_sessions(ready.registry) == Ok([id])

    // Nothing opens a session whose deletion has begun.
    let opened = command(socket, 4, "sessions.open", id, ready.epoch)
    assert code(opened) == json.String("busy")
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn a_recorded_session_opens_with_the_store_stopped_test() {
  use <- with_store
  member_daemon(ownership.over_store(alpha), fn(ready, port, credential) {
    let #(socket, _) = wire.connect(port, credential, "/v2/control")
    let _hello = wire.frame(socket, within_ms: 1000)
    let id = saved_remote(socket, ready, "opens")

    // Opening a session this daemon holds asks nothing of the directory, so a
    // member with no store at all, as one cut off from the majority, opens it.
    store.stop()
    let opened = command(socket, 3, "sessions.open", id, ready.epoch)
    assert field(opened, "event") == json.String("sessions.open")
    let assert poll.Answered(Nil) =
      poll.until(within: 15_000, every: 20, attempt: fn() {
        case manager.get(ready.registry, id) {
          Ok(manager.View(status: manager.Resident(..), ..)) -> poll.Done(Nil)
          _ -> poll.Retry
        }
      })
      as "the session opens without the store"
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn directory_status_reports_the_members_and_the_store_test() {
  use <- with_store
  member_daemon(ownership.over_store(alpha), fn(_ready, port, credential) {
    let #(socket, _) = wire.connect(port, credential, "/v2/control")
    let _hello = wire.frame(socket, within_ms: 1000)
    let reply =
      wire.send(socket, 1, "directory.status", json.Object([]), within_ms: 5000)
    assert field(reply, "event") == json.String("directory.status")
    let body = field(reply, "body")
    assert field(body, "joined") == json.Bool(True)
    assert field(body, "members")
      == json.Array([
        json.String(alpha),
        json.String(bravo),
        json.String("exec@10.0.0.3"),
      ])
    let assert json.Array([_]) = field(body, "ra_members")
      as "one Ra member in the test VM"
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn directory_status_on_a_daemon_that_is_not_a_member_is_not_found_test() {
  wire.fixture(fn(_, _ready, port, credential) {
    let #(socket, _) = wire.connect(port, credential, "/v2/control")
    let _hello = wire.frame(socket, within_ms: 1000)
    let reply =
      wire.send(socket, 1, "directory.status", json.Object([]), within_ms: 2000)
    assert code(reply) == json.String("not_found")
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

fn abandon(socket, id, session, epoch) {
  wire.send(
    socket,
    id,
    "sessions.move",
    json.Object([
      #("session_id", json.String(session)),
      #("epoch", json.String(epoch)),
      #("abandon", json.Bool(True)),
    ]),
    within_ms: 2000,
  )
}

pub fn abandoning_a_session_that_is_not_moving_is_a_conflict_test() {
  use <- with_store
  member_daemon(ownership.over_store(alpha), fn(ready, port, credential) {
    let #(socket, _) = wire.connect(port, credential, "/v2/control")
    let _hello = wire.frame(socket, within_ms: 1000)
    let id = saved_remote(socket, ready, "still")
    assert code(abandon(socket, 3, id, ready.epoch)) == json.String("conflict")
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn a_daemon_that_is_not_a_member_cannot_abandon_a_move_test() {
  wire.fixture(fn(_, ready, port, credential) {
    let #(socket, _) = wire.connect(port, credential, "/v2/control")
    let _hello = wire.frame(socket, within_ms: 1000)
    assert code(abandon(
        socket,
        1,
        "0198c0de-0000-7000-8000-000000000009",
        ready.epoch,
      ))
      == json.String("not_movable")
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}
