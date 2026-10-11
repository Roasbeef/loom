//// The owner's command to hand a session to another orchestrator, across the real
//// control socket (protocol-change/078, phase 5). The session registry is real
//// and the session assembly is inert, so these tests prove what the socket does:
//// who may ask, what it refuses, what the reply and the session's view carry
//// while the move is in flight and after it, and which refusals name the new
//// owner. The mover itself is `session_mover_test`, and the two daemons are
//// `daemon_shipped_remote_move_test`.

import client/daemon/limits
import client/daemon/manager
import client/daemon/root
import client/daemon_server_test as wire
import client/orchestrators
import client/remote/orchestrator_port
import client/session_directory.{type Directory, Directory, Elsewhere}
import client/session_movers
import core/clock
import core/ids
import core/json
import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap
import simplifile
import storage/access
import storage/catalogue
import storage/domain
import support/internal/ffi_ws
import weft/actor

fn field(value, key) {
  let assert json.Object(fields) = value as "envelope is an object"
  let assert Ok(value) = list.key_find(fields, key)
    as "expected field is present"
  value
}

fn has(value, key) -> Bool {
  case value {
    json.Object(fields) -> list.key_find(fields, key) != Error(Nil)
    _ -> False
  }
}

fn laptop() -> orchestrators.Orchestrator {
  orchestrators.Orchestrator(
    name: "laptop",
    node: "laptop@10.0.0.7",
    address: Some("wss://laptop.example.com:8443/v2/control"),
  )
}

// What the movers were told, in order. The wire fixture runs its body in a
// worker and not in the test process, and a subject can be read only by its
// owner, so the record is an actor either side can reach.
type Note {
  Began(move: catalogue.Pending)
  Drain(reply: process.Subject(List(catalogue.Pending)))
}

fn record(
  told: List(catalogue.Pending),
  note: Note,
) -> actor.Next(List(catalogue.Pending), Note) {
  case note {
    Began(move:) -> actor.continue([move, ..told])
    Drain(reply:) -> {
      process.send(reply, list.reverse(told))
      actor.continue([])
    }
  }
}

fn recorder() -> process.Subject(Note) {
  let assert Ok(started) =
    actor.new([]) |> actor.on_message(record) |> actor.start
    as "the recorder starts"
  started.data
}

fn told(recorder: process.Subject(Note)) -> List(catalogue.Pending) {
  process.call(recorder, 1000, Drain)
}

// What the orchestrator a session was imported from answers when this daemon
// asks it whether it holds the session. The test changes the answer as the
// origin's own move advances, and the daemon's ask is made from a process of
// its own, so the answer lives in an actor either side can reach.
type Origin {
  Answer(Result(orchestrator_port.Ownership, Nil))
  Ask(reply: process.Subject(Result(orchestrator_port.Ownership, Nil)))
}

fn origin() -> process.Subject(Origin) {
  let assert Ok(started) =
    actor.new(Error(Nil))
    |> actor.on_message(fn(held, message) {
      case message {
        Answer(next) -> actor.continue(next)
        Ask(reply:) -> {
          process.send(reply, held)
          actor.continue(held)
        }
      }
    })
    |> actor.start
    as "the origin starts"
  started.data
}

fn moving(
  run: fn(root.Ready(String), Int, String, process.Subject(Note)) -> Nil,
) {
  moving_from(origin(), run)
}

// A fixture whose directory answers `laptop` for any session it is asked about,
// as a daemon holding a tombstone for it would, and whose movers list `laptop`
// and `desk`, record what they are told, and ask `desk` through `desk_says`.
fn moving_from(
  desk_says: process.Subject(Origin),
  run: fn(root.Ready(String), Int, String, process.Subject(Note)) -> Nil,
) {
  let told = recorder()
  let asking =
    Directory(
      ..session_directory.none(),
      lookup: fn(_session) { Ok(Elsewhere(laptop())) },
      activate: fn(_, _) { Error(Nil) },
    )
  let movers =
    session_movers.Control(
      orchestrators: [laptop(), orchestrators.plain("desk", "desk@10.0.0.8")],
      begin: fn(move) { process.send(told, Began(move)) },
      holds: fn(_, _) { process.call(desk_says, 1000, Ask) },
    )
  wire.fixture_moving(
    limits.defaults,
    fn(_) { None },
    fn(record, _domain, _services, _owner, _directory) { Ok(record.id) },
    asking,
    movers,
    fn(_, ready, port, credential) { run(ready, port, credential, told) },
  )
}

const import_op = "0192f3c1-7b0e-7d2a-9c11-4f5a6b7c8d9e"

// A session on the daemon's executor that arrived from `desk`, as an import
// leaves it: saved, with the file in place and the custody row `imported`.
fn imported(ready: root.Ready(String), seed: Int) -> String {
  let #(minted, _) =
    ids.mint_session(ids.generator(clock.fixed(1_700_000_000_000), seed))
  let id = ids.session_id_to_string(minted)
  let registration =
    catalogue.Registration(
      id:,
      path: ready.sessions_directory <> "/" <> id <> ".db",
      workspace: "repo",
      name: "Imported",
      configuration: "",
      profile: None,
      model: None,
      executor: "build-box",
      pool: "",
      created_at: 1_700_000_000_000,
      request_key: "import-" <> import_op,
      state: catalogue.Reserved,
      subtitle: None,
    )
  let received = ready.state_root <> "/received-" <> id
  let assert Ok(Nil) = simplifile.write(received, "the session file")
    as "the copy is written"
  let assert Ok(_) =
    manager.import_session(
      ready.registry,
      manager.Import(
        registration:,
        mapping: manager.session_only_domain(registration, "", ready.state_root),
        op: import_op,
        from: "desk",
        received:,
        subtitle: None,
      ),
    )
    as "the session is imported"
  id
}

// A session on the daemon's one configured executor, and a local one.
fn remote(ready: root.Ready(String), key: String) -> String {
  let assert Ok(view) =
    manager.create_scoped(
      ready.registry,
      manager.Creation(key, "repo", "Remote", "", None, None, "build-box", ""),
      directory: ready.sessions_directory,
      generator: ids_for(key),
      scope: domain.SessionOnly,
      configuration: "",
    )
    as "the owner creates a session on an executor"
  view.registration.id
}

fn local(ready: root.Ready(String), key: String) -> String {
  let assert Ok(view) =
    manager.create(
      ready.registry,
      manager.Creation(key, ready.state_root, "Local", "", None, None, "", ""),
      directory: ready.sessions_directory,
      generator: ids_for(key),
    )
    as "the owner creates a local session"
  view.registration.id
}

fn ids_for(key: String) {
  ids.generator(clock.fixed(0), string.length(key) * 7 + 11)
}

fn move(socket, id, session, to, epoch) {
  wire.send(
    socket,
    id,
    "sessions.move",
    json.Object([
      #("session_id", json.String(session)),
      #("to", json.String(to)),
      #("epoch", json.String(epoch)),
    ]),
    within_ms: 1000,
  )
}

fn get(socket, id, session) {
  wire.send(
    socket,
    id,
    "sessions.get",
    json.Object([#("session_id", json.String(session))]),
    within_ms: 1000,
  )
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
    within_ms: 1000,
  )
}

fn code(frame) -> json.JsonValue {
  assert field(frame, "event") == json.String("error")
  field(field(frame, "body"), "code")
}

pub fn the_owner_moves_a_session_and_is_told_the_move_and_where_it_goes_test() {
  moving(fn(ready, port, credential, recorder) {
    let session = remote(ready, "movable")
    let #(socket, _) = wire.connect(port, credential, "/v2/control")
    let _hello = wire.frame(socket, within_ms: 1000)
    let reply = move(socket, 1, session, "laptop", ready.epoch)
    assert field(reply, "event") == json.String("sessions.move")
    let body = field(reply, "body")
    assert field(body, "session_id") == json.String(session)
    assert field(body, "to") == json.String("laptop")
    assert field(body, "state") == json.String("moving")
    let assert json.String(op) = field(body, "op")

    // The movers were told once, with the operation the reply named, after the
    // row was committed.
    assert told(recorder) == [catalogue.Pending(session:, op:, to: "laptop")]
    assert manager.custody(ready.registry, session)
      == Ok(catalogue.Moving(op:, to: "laptop"))

    // The same request again is the same move: it names the stored operation,
    // and the movers are told again, which they ignore.
    let again = move(socket, 2, session, "laptop", ready.epoch)
    assert field(field(again, "body"), "op") == json.String(op)
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn a_session_imported_from_a_source_that_has_not_retired_cannot_move_on_test() {
  let desk = origin()
  moving_from(desk, fn(ready, port, credential, recorder) {
    let session = imported(ready, 5)
    let #(socket, _) = wire.connect(port, credential, "/v2/control")
    let _hello = wire.frame(socket, within_ms: 1000)

    // The source still holds the session as moving, so its activation can yet
    // arrive here again. Beginning a move now would replace the `imported` row.
    process.send(desk, Answer(Ok(orchestrator_port.Owned)))
    assert code(move(socket, 1, session, "laptop", ready.epoch))
      == json.String("not_movable")

    // Silence from the source decides nothing, and nor does a source that does
    // not know the session.
    process.send(desk, Answer(Error(Nil)))
    assert code(move(socket, 2, session, "laptop", ready.epoch))
      == json.String("not_movable")
    process.send(desk, Answer(Ok(orchestrator_port.NotOwned)))
    assert code(move(socket, 3, session, "laptop", ready.epoch))
      == json.String("not_movable")
    assert told(recorder) == []
    assert manager.custody(ready.registry, session)
      == Ok(catalogue.Imported(op: import_op, from: "desk"))

    // Once the source has retired it answers with its tombstone, and the move
    // is admitted over the imported row.
    process.send(desk, Answer(Ok(orchestrator_port.Moved(to: "here"))))
    let admitted = move(socket, 4, session, "laptop", ready.epoch)
    assert field(admitted, "event") == json.String("sessions.move")
    let assert json.String(op) = field(field(admitted, "body"), "op")
    assert told(recorder) == [catalogue.Pending(session:, op:, to: "laptop")]
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn a_session_imported_from_a_source_that_has_not_retired_cannot_be_deleted_test() {
  let desk = origin()
  moving_from(desk, fn(ready, port, credential, _recorder) {
    let session = imported(ready, 6)
    let #(socket, _) = wire.connect(port, credential, "/v2/control")
    let _hello = wire.frame(socket, within_ms: 1000)

    // The source still holds the session as moving. A delete here would remove
    // the row its retry depends on, and the retry would import the session
    // again, so the delete is refused as busy while the source holds it, is
    // silent, or does not know the session.
    process.send(desk, Answer(Ok(orchestrator_port.Owned)))
    assert code(command(socket, 1, "sessions.delete", session, ready.epoch))
      == json.String("busy")
    process.send(desk, Answer(Error(Nil)))
    assert code(command(socket, 2, "sessions.delete", session, ready.epoch))
      == json.String("busy")
    process.send(desk, Answer(Ok(orchestrator_port.NotOwned)))
    assert code(command(socket, 3, "sessions.delete", session, ready.epoch))
      == json.String("busy")
    assert manager.custody(ready.registry, session)
      == Ok(catalogue.Imported(op: import_op, from: "desk"))

    // Once the source has retired, the session is this daemon's alone.
    process.send(desk, Answer(Ok(orchestrator_port.Moved(to: "here"))))
    let deleted = command(socket, 4, "sessions.delete", session, ready.epoch)
    assert field(deleted, "event") == json.String("sessions.delete")
    assert manager.get(ready.registry, session)
      == Error(manager.Catalogue(catalogue.Missing))
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn the_session_get_shows_a_move_in_flight_and_one_that_finished_test() {
  moving(fn(ready, port, credential, _recorder) {
    let session = remote(ready, "viewed")
    let #(socket, _) = wire.connect(port, credential, "/v2/control")
    let _hello = wire.frame(socket, within_ms: 1000)

    // A session that is not moving carries neither member, so its view is what
    // it was before moves existed.
    let plain = field(get(socket, 1, session), "body")
    assert !has(plain, "moving")
    assert !has(plain, "moved")
    let reply = move(socket, 2, session, "laptop", ready.epoch)
    let assert json.String(op) = field(field(reply, "body"), "op")
    let moving = field(get(socket, 3, session), "body")
    assert field(moving, "moving")
      == json.Object([
        #("op", json.String(op)),
        #("to", json.String("laptop")),
      ])
    assert !has(moving, "moved")
    let assert Ok(_) = manager.finish_move(ready.registry, session, op:)
    let moved = field(get(socket, 4, session), "body")
    assert field(moved, "moved")
      == json.Object([#("to", json.String("laptop"))])
    assert !has(moved, "moving")
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn a_session_in_flight_cannot_be_opened_and_says_where_it_is_going_test() {
  moving(fn(ready, port, credential, _recorder) {
    let session = remote(ready, "in-flight")
    let #(socket, _) = wire.connect(port, credential, "/v2/control")
    let _hello = wire.frame(socket, within_ms: 1000)
    let reply = move(socket, 1, session, "laptop", ready.epoch)
    let assert json.String(op) = field(field(reply, "body"), "op")

    let opened = command(socket, 2, "sessions.open", session, ready.epoch)
    assert code(opened) == json.String("moving")
    assert field(field(opened, "body"), "orchestrator") == json.String("laptop")
    assert field(field(opened, "body"), "op") == json.String(op)

    // Archiving and deleting it are refused for the same reason.
    assert code(command(socket, 3, "sessions.archive", session, ready.epoch))
      == json.String("moving")
    assert code(command(socket, 4, "sessions.delete", session, ready.epoch))
      == json.String("moving")
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn open_archive_restore_and_delete_name_the_new_owner_after_the_move_test() {
  moving(fn(ready, port, credential, _recorder) {
    let session = remote(ready, "moved-away")
    let #(socket, _) = wire.connect(port, credential, "/v2/control")
    let _hello = wire.frame(socket, within_ms: 1000)
    let reply = move(socket, 1, session, "laptop", ready.epoch)
    let assert json.String(op) = field(field(reply, "body"), "op")
    let assert Ok(_) = manager.finish_move(ready.registry, session, op:)

    // Each answers `not_owner` with the orchestrator and the address the
    // operator configured for it, from the tombstone.
    list.each(
      [
        #(2, "sessions.open"),
        #(3, "sessions.restore"),
        #(4, "sessions.archive"),
        #(6, "sessions.delete"),
      ],
      fn(each) {
        let refused = command(socket, each.0, each.1, session, ready.epoch)
        assert code(refused) == json.String("not_owner")
        let body = field(refused, "body")
        assert field(body, "orchestrator") == json.String("laptop")
        assert field(body, "address")
          == json.String("wss://laptop.example.com:8443/v2/control")
      },
    )

    // A second move is refused the same way.
    assert code(move(socket, 7, session, "laptop", ready.epoch))
      == json.String("not_owner")
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn a_move_is_refused_for_each_reason_it_cannot_start_test() {
  moving(fn(ready, port, credential, recorder) {
    let session = remote(ready, "refused")
    let plain = local(ready, "refused-local")
    let #(socket, _) = wire.connect(port, credential, "/v2/control")
    let _hello = wire.frame(socket, within_ms: 1000)

    // A stale epoch, a destination this daemon does not list, a local session
    // and an identity nobody holds each end the request before any mover runs.
    assert code(move(socket, 1, session, "laptop", "an-epoch-from-before"))
      == json.String("stale_epoch")
    assert code(move(socket, 2, session, "elsewhere", ready.epoch))
      == json.String("orchestrator_unknown")
    assert code(move(socket, 3, plain, "laptop", ready.epoch))
      == json.String("not_movable")
    assert code(move(
        socket,
        4,
        "0198c0de-0000-7000-8000-0000000000ff",
        "laptop",
        ready.epoch,
      ))
      == json.String("not_found")
    assert told(recorder) == []
    assert manager.custody(ready.registry, session) == Ok(catalogue.Resident)

    // A move toward one orchestrator and then toward another is a conflict.
    let first = move(socket, 5, session, "laptop", ready.epoch)
    assert field(first, "event") == json.String("sessions.move")
    assert code(move(socket, 6, session, "desk", ready.epoch))
      == json.String("conflict")
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn a_member_may_not_move_a_session_test() {
  moving(fn(ready, port, _credential, recorder) {
    let session = remote(ready, "members")
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
      as "fixture administration opens the durable catalogue"
    let assert Ok(_) = access.create_member(store, "mover", "M", digest)
      as "the member exists"
    let assert Ok(_) = access.grant(store, "mover", session, access.Operator)
      as "the member operates the session"
    let #(socket, _) = wire.connect(port, member_token, "/v2/control")
    let _hello = wire.frame(socket, within_ms: 1000)
    assert code(move(socket, 1, session, "laptop", ready.epoch))
      == json.String("forbidden")
    assert told(recorder) == []
    assert manager.custody(ready.registry, session) == Ok(catalogue.Resident)
    let _ = ffi_ws.tcp_close(socket)
    assert catalogue.close(store) == Ok(Nil)
  })
}

pub fn a_daemon_that_lists_no_orchestrator_has_nowhere_to_send_a_session_test() {
  let asking: Directory = session_directory.none()
  wire.fixture_moving(
    limits.defaults,
    fn(_) { None },
    fn(record, _domain, _services, _owner, _directory) { Ok(record.id) },
    asking,
    session_movers.idle(),
    fn(_, ready, port, credential) {
      let session = remote(ready, "nowhere")
      let #(socket, _) = wire.connect(port, credential, "/v2/control")
      let _hello = wire.frame(socket, within_ms: 1000)
      assert code(move(socket, 1, session, "laptop", ready.epoch))
        == json.String("orchestrator_unknown")
      let _ = ffi_ws.tcp_close(socket)
      Nil
    },
  )
}
