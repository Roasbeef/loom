//// A daemon asked about a session its own catalogue lacks consults its session
//// directory before it answers (protocol-change/078, phase 3). The directory is
//// a stub here, so these tests prove only what the control socket does with its
//// answer: which commands ask, which principals are redirected, what the two new
//// refusals carry, and that the common paths never ask at all. The real fan-out
//// is `session_directory_test`, and the two daemons are
//// `daemon_shipped_directory_test`.

import client/daemon/limits
import client/daemon/main
import client/daemon/manager
import client/daemon/root
import client/daemon_server_test as wire
import client/orchestrators
import client/remote/orchestrator_port.{NotOwned, Owned}
import client/session_directory.{
  type Directory, Directory, Elsewhere, Here, Unknown, Unreachable,
}
import core/clock
import core/ids
import core/json
import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap
import storage/access
import storage/catalogue
import support/internal/ffi_ws
import weft/actor

// The session no catalogue here holds, in the canonical form the decoder
// requires.
const unheld = "0198c0de-0000-7000-8000-000000000001"

fn field(value, key) {
  let assert json.Object(fields) = value as "envelope is an object"
  let assert Ok(value) = list.key_find(fields, key)
    as "expected field is present"
  value
}

fn body(frame) {
  assert field(frame, "event") == json.String("error")
  field(frame, "body")
}

// What the directory was asked, in order. The wire fixture runs its body in a
// worker, which is not the test process that built the stub, and a subject can
// be read only by its owner, so the record is an actor either side can reach.
type Note {
  Asked(session: String)
  Drain(reply: process.Subject(List(String)))
}

fn record(asked: List(String), note: Note) -> actor.Next(List(String), Note) {
  case note {
    Asked(session:) -> actor.continue([session, ..asked])
    Drain(reply:) -> {
      process.send(reply, list.reverse(asked))
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

// Every identity asked about since the last call.
fn asked_about(asked: process.Subject(Note)) -> List(String) {
  process.call(asked, 1000, Drain)
}

// A directory that answers `answer` and records every identity it was asked
// about.
fn asking(
  answer: Result(session_directory.Owner, session_directory.Miss),
  asked: process.Subject(Note),
) -> Directory {
  Directory(..session_directory.none(), lookup: fn(session) {
    process.send(asked, Asked(session))
    answer
  })
}

fn beta_at() -> orchestrators.Orchestrator {
  orchestrators.Orchestrator(
    name: "beta",
    node: "beta@10.0.0.2",
    address: Some("wss://beta.example.com:8443/v2/control"),
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

fn open(socket, id, session, epoch) {
  wire.send(
    socket,
    id,
    "sessions.open",
    json.Object([
      #("session_id", json.String(session)),
      #("epoch", json.String(epoch)),
    ]),
    within_ms: 1000,
  )
}

fn directed(
  answer: Result(session_directory.Owner, session_directory.Miss),
  run: fn(root.Ready(String), Int, String, process.Subject(Note)) -> Nil,
) {
  let asked = recorder()
  wire.fixture_directing(
    limits.defaults,
    fn(_) { None },
    fn(record, _domain, _services, _owner, _directory) { Ok(record.id) },
    asking(answer, asked),
    fn(_, ready, port, credential) { run(ready, port, credential, asked) },
  )
}

pub fn an_owner_asking_for_a_session_held_elsewhere_is_told_who_has_it_test() {
  directed(Ok(Elsewhere(beta_at())), fn(ready, port, credential, asked) {
    let #(socket, _) = wire.connect(port, credential, "/v2/control")
    let _hello = wire.frame(socket, within_ms: 1000)

    // `sessions.get` and `sessions.open` redirect with the same code, naming
    // the orchestrator and the address the operator configured for it.
    let read = body(get(socket, 1, unheld))
    assert field(read, "code") == json.String("not_owner")
    assert field(read, "orchestrator") == json.String("beta")
    assert field(read, "address")
      == json.String("wss://beta.example.com:8443/v2/control")
    let opened = body(open(socket, 2, unheld, ready.epoch))
    assert field(opened, "code") == json.String("not_owner")
    assert field(opened, "orchestrator") == json.String("beta")

    // The directory was asked about exactly that identity, once per request.
    assert asked_about(asked) == [unheld, unheld]
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn an_orchestrator_with_no_configured_address_is_named_without_one_test() {
  let plain = orchestrators.plain("beta", "beta@10.0.0.2")
  directed(Ok(Elsewhere(plain)), fn(_ready, port, credential, _asked) {
    let #(socket, _) = wire.connect(port, credential, "/v2/control")
    let _hello = wire.frame(socket, within_ms: 1000)
    let read = body(get(socket, 1, unheld))
    assert field(read, "code") == json.String("not_owner")
    assert field(read, "orchestrator") == json.String("beta")
    assert list.key_find(
        case read {
          json.Object(fields) -> fields
          _ -> []
        },
        "address",
      )
      == Error(Nil)
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn an_unreachable_owner_is_reported_with_the_orchestrators_that_did_not_answer_test() {
  directed(
    Error(Unreachable(["beta", "gamma"])),
    fn(ready, port, credential, _asked) {
      let #(socket, _) = wire.connect(port, credential, "/v2/control")
      let _hello = wire.frame(socket, within_ms: 1000)
      let read = body(get(socket, 1, unheld))
      assert field(read, "code") == json.String("owner_unreachable")
      assert field(read, "orchestrators")
        == json.Array([json.String("beta"), json.String("gamma")])
      let opened = body(open(socket, 2, unheld, ready.epoch))
      assert field(opened, "code") == json.String("owner_unreachable")
      let _ = ffi_ws.tcp_close(socket)
      Nil
    },
  )
}

pub fn a_session_nobody_holds_stays_not_found_test() {
  directed(Error(Unknown), fn(ready, port, credential, asked) {
    let #(socket, _) = wire.connect(port, credential, "/v2/control")
    let _hello = wire.frame(socket, within_ms: 1000)
    assert field(body(get(socket, 1, unheld)), "code")
      == json.String("not_found")
    assert field(body(open(socket, 2, unheld, ready.epoch)), "code")
      == json.String("not_found")
    assert asked_about(asked) == [unheld, unheld]
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn a_directory_that_says_here_after_a_local_miss_leaves_not_found_test() {
  // The miss and the lookup are two reads, so the directory can find a session
  // the first read did not. The reply stays what the first read said; the
  // client's retry finds the session.
  directed(Ok(Here), fn(_ready, port, credential, _asked) {
    let #(socket, _) = wire.connect(port, credential, "/v2/control")
    let _hello = wire.frame(socket, within_ms: 1000)
    assert field(body(get(socket, 1, unheld)), "code")
      == json.String("not_found")
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn a_stale_epoch_is_refused_before_the_directory_is_asked_test() {
  directed(Ok(Elsewhere(beta_at())), fn(_ready, port, credential, asked) {
    let #(socket, _) = wire.connect(port, credential, "/v2/control")
    let _hello = wire.frame(socket, within_ms: 1000)
    let stale = body(open(socket, 1, unheld, "an-epoch-from-before"))
    assert field(stale, "code") == json.String("stale_epoch")
    assert asked_about(asked) == []
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn a_session_this_daemon_holds_never_asks_the_directory_test() {
  directed(Ok(Elsewhere(beta_at())), fn(ready, port, credential, asked) {
    let assert Ok(held) =
      manager.create(
        ready.registry,
        manager.Creation("held", ready.state_root, "Held", "", None, "", ""),
        directory: ready.sessions_directory,
        generator: ids.generator(clock.fixed(0), 700),
      )
      as "the owner creates a session here"
    let #(socket, _) = wire.connect(port, credential, "/v2/control")
    let _hello = wire.frame(socket, within_ms: 1000)
    let read = get(socket, 1, held.registration.id)
    assert field(read, "event") == json.String("sessions.get")
    assert asked_about(asked) == []
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn a_member_is_never_redirected_test() {
  // A member's standing on a session is the owning daemon's to judge, and this
  // daemon cannot vouch for it, so a session it does not hold is `not_found` to
  // a member and the directory is not asked.
  directed(Ok(Elsewhere(beta_at())), fn(ready, port, _credential, asked) {
    let member_token = string.repeat("2", 64)
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
    let assert Ok(_) =
      access.create_member(store, "redirect-member", "M", digest)
      as "the member exists"
    let #(socket, _) = wire.connect(port, member_token, "/v2/control")
    let _hello = wire.frame(socket, within_ms: 1000)
    assert field(body(get(socket, 1, unheld)), "code")
      == json.String("not_found")
    assert field(body(open(socket, 2, unheld, ready.epoch)), "code")
      == json.String("not_found")
    assert asked_about(asked) == []
    let _ = ffi_ws.tcp_close(socket)
    assert catalogue.close(store) == Ok(Nil)
  })
}

pub fn only_get_and_open_consult_the_directory_test() {
  directed(Ok(Elsewhere(beta_at())), fn(ready, port, credential, asked) {
    let #(socket, _) = wire.connect(port, credential, "/v2/control")
    let _hello = wire.frame(socket, within_ms: 1000)

    // Commands that name a session this daemon does not hold keep their old
    // answer. The redirect is for the two commands a client uses to reach a
    // session, and the others are not widened by it.
    let stopped =
      wire.send(
        socket,
        1,
        "sessions.stop",
        json.Object([
          #("session_id", json.String(unheld)),
          #("epoch", json.String(ready.epoch)),
        ]),
        within_ms: 1000,
      )
    assert field(body(stopped), "code") != json.String("not_owner")
    let operation =
      wire.send(
        socket,
        2,
        "operations.get",
        json.Object([
          #("session_id", json.String(unheld)),
          #("operation", json.String("op")),
          #("epoch", json.String(ready.epoch)),
        ]),
        within_ms: 1000,
      )
    assert field(body(operation), "code") == json.String("not_found")
    assert asked_about(asked) == []
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

// --- the catalogue's answer to a peer ------------------------------------------

pub fn the_catalogue_answers_owned_for_every_state_and_not_owned_for_absence_test() {
  wire.fixture(fn(_, ready, _port, _credential) {
    let holds = main.catalogue_holds(ready.registry)
    let assert Ok(store) = catalogue.open(ready.state_root <> "/catalogue.db")
      as "fixture administration opens the durable catalogue"

    // A reserved registration, whose database was never created: the owner of
    // a creation that has not reconciled is still the orchestrator that
    // reserved it, and its retry must reach the same daemon.
    let #(reserved, _) = ids.mint_session(ids.generator(clock.fixed(0), 810))
    let reserved = ids.session_id_to_string(reserved)
    let record =
      catalogue.Registration(
        id: reserved,
        path: "/never-opened-directory-test/" <> reserved <> ".db",
        workspace: "/workspace",
        name: "Reserved",
        configuration: "",
        profile: None,
        executor: "",
        pool: "",
        created_at: 0,
        request_key: reserved,
        state: catalogue.Reserved,
        subtitle: None,
      )
    assert catalogue.reserve(store, record) == Ok(record)
    assert holds(reserved) == Ok(Owned)

    // Confirming it, and archiving it, leave it held: an archived session is
    // still its orchestrator's to restore.
    let assert Ok(_) = catalogue.confirm(store, reserved)
    assert holds(reserved) == Ok(Owned)
    let assert Ok(_) =
      catalogue.set_visibility(store, reserved, catalogue.Archived)
    assert holds(reserved) == Ok(Owned)

    // An identity the catalogue has never seen is not held.
    assert holds(unheld) == Ok(NotOwned)
    assert catalogue.close(store) == Ok(Nil)
  })
}

pub fn a_session_that_moved_away_is_answered_as_moved_to_its_new_owner_test() {
  wire.fixture(fn(_, ready, _port, _credential) {
    let holds = main.catalogue_holds(ready.registry)
    let assert Ok(store) = catalogue.open(ready.state_root <> "/catalogue.db")
      as "fixture administration opens the durable catalogue"
    let #(moving, _) = ids.mint_session(ids.generator(clock.fixed(0), 811))
    let moving = ids.session_id_to_string(moving)
    let record =
      catalogue.Registration(
        id: moving,
        path: "/never-opened-directory-test/" <> moving <> ".db",
        workspace: "repo",
        name: "Moving",
        configuration: "",
        profile: None,
        executor: "box",
        pool: "",
        created_at: 0,
        request_key: moving,
        state: catalogue.Reserved,
        subtitle: None,
      )
    assert catalogue.reserve(store, record) == Ok(record)
    let assert Ok(_) = catalogue.confirm(store, moving)

    // While the move is in flight the session is still this daemon's.
    let op = "0192f3c1-7b0e-7d2a-9c11-4f5a6b7c8d9e"
    let assert Ok(_) = catalogue.begin_move(store, moving, op:, to: "laptop")
    assert holds(moving) == Ok(Owned)

    // Once it has moved, the registration remains as a tombstone, and the
    // answer is where the session went and not that this daemon holds it.
    let assert Ok(_) = catalogue.finish_move(store, moving, op:)
    assert holds(moving) == Ok(orchestrator_port.Moved(to: "laptop"))
    assert catalogue.close(store) == Ok(Nil)
  })
}
