//// The session directory's Khepri cluster losing its majority and losing a
//// member's disk, against the shipped daemon (protocol-change/080): three real
//// `bin/loomd` processes, two orchestrators and one executor, that are the
//// cluster's members and trust each other over TLS distribution.
////
//// The cluster has three members, so it commits a write while any two of them
//// run. These tests take two away and bring them back, and take one member's
//// directory store away while it is stopped.
////
//// ## What it proves
////
//// `a_member_without_a_majority_keeps_serving_and_refuses_records_test_`
////
//// - `alpha` and the executor are killed, leaving `bravo` alone. `bravo` still
////   answers `not_owner` naming `alpha` for `alpha`'s session, quickly, from
////   its own copy of the records.
//// - A local session on `bravo` keeps working: it stops and opens again.
////   Opening asks nothing of the directory. (That a remote session opens with
////   no store at all is proven in the VM by
////   `client/directory/daemon_record_test`; here the executor such a session
////   needs is one of the two members that went away.)
//// - Creating a remote session is refused with `no_quorum`, because its record
////   cannot be written, and the reservation stays.
//// - A move of `bravo`'s remote session to `alpha` is accepted and stalls: the
////   session reports `moving` and not `moved`, since the record of the move
////   cannot be written.
//// - The executor is started again. Two members are a majority, so the refused
////   creation completes under the same request key, and the move goes on until
////   it needs `alpha`. `alpha` is started again and the move finishes on its
////   own: `bravo` reports it `moved` to `alpha`, and `alpha` opens the session.
////
//// `a_member_that_lost_its_disk_rejoins_as_a_non_voter_test_`
////
//// - `alpha` is stopped and its directory store is deleted, as a replaced disk
////   would leave it. `loomd directory bootstrap` on `alpha` is refused, because
////   another member it reaches runs a store: running it would have started a
////   second cluster.
//// - `alpha` is started and joins the cluster by itself, through the join path
////   (its log says `daemon.directory_joined`), and is counted as a voter once it
////   has caught up. Its copy holds the record `bravo` wrote, so it redirects to
////   `bravo`, and it records a remote session of its own.
////
//// ## Running it
////
//// ```sh
//// make server-shipment
//// make sandbox && install -m 0755 packages/sandbox/loom-exec bin/loom-exec
//// export LOOM_BOOTSTRAP_E2E_SERVER=$PWD/bin/loomd
//// export LOOM_TEST_PROVIDER_KEY=loom-provider-fixture-key
//// bash scripts/test.sh client --match 'client@daemon_shipped_directory_quorum_test:'
//// ```
////
//// The daemons, the credentials and the configuration come from
//// `support/remote_duo`, which also retires every daemon outside the body's
//// deadline. No model turn is taken.

import client/tui_e2e_test.{type EunitTest}
import core/json.{type JsonValue}
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap as native
import simplifile
import support/remote_daemons
import support/remote_duo

const quorum_label = "shipped directory quorum loss"

const rejoin_label = "shipped directory rejoin"

// A lookup answered from a member's own copy ends well inside this.
const local_read_ms = 6000

// Half-second polls a move gets to finish once the members it needs are back.
const move_polls = 240

pub fn a_member_without_a_majority_keeps_serving_and_refuses_records_test_() -> EunitTest {
  remote_duo.shipped(quorum_label, fn(duo) {
    let keys = remote_duo.provision(duo)
    remote_duo.configure_members(duo, keys, None)
    let members = remote_duo.start_members(duo)
    let on_alpha = remote_daemons.open_control(members.alpha)
    let on_bravo = remote_daemons.open_control(members.bravo)

    // `alpha` records a session, and `bravo` records one it will move later,
    // stopped so that nothing runs on the executor when it goes away. A local
    // session on `bravo` is not recorded at all.
    let #(alphas, settled) = remote(on_alpha, 1, "e2e-alpha")
    assert remote_daemons.settled_state(settled) == "resident"
    let #(moving, settled) = remote(on_bravo, 1, "e2e-moving")
    assert remote_daemons.settled_state(settled) == "resident"
    remote_daemons.stop_session(members.bravo, on_bravo, 400, moving)
    let #(local, settled) =
      remote_daemons.create_local_and_settle(
        on_bravo,
        500,
        "e2e-local",
        duo.bravo.workspace,
      )
    assert remote_daemons.settled_state(settled) == "resident"

    // Two of the three members go away. `bravo` is alone and has no majority.
    remote_daemons.crash(duo.alpha)
    remote_daemons.crash(duo.executor)

    // A lookup reads `bravo`'s own copy, so it still names the owner.
    let read = timed(fn() { get(on_bravo, 900, alphas) })
    assert code_of(read) == json.String("not_owner")
    assert remote_daemons.field(body_of(read), "orchestrator")
      == json.String("alpha")

    // A session `bravo` serves keeps working, and opening it asks nothing of
    // the directory.
    remote_daemons.stop_session(members.bravo, on_bravo, 910, local)
    let reopened = remote_daemons.reopen_session(on_bravo, 920, local)
    assert remote_daemons.settled_state(reopened) == "resident"

    // A remote creation needs its record written, which cannot happen now.
    let refused =
      remote_daemons.create_registered(
        on_bravo,
        1300,
        "e2e-refused",
        remote_duo.workspace_name,
        remote_duo.executor_name,
      )
    assert code_of(refused) == json.String("no_quorum")

    // A move is accepted, since the move's own row is local, and then stalls
    // at the record of the move.
    let assert Some(accepted) =
      remote_daemons.begin_move(on_bravo, 1400, moving, "alpha", 30_000)
      as "bravo answers the move"
    assert remote_daemons.field(accepted, "event")
      == json.String("sessions.move")
    assert remote_daemons.field(body_of(accepted), "state")
      == json.String("moving")
    process.sleep(5000)
    assert !has_member(
      remote_daemons.session_record(on_bravo, 1410, moving),
      "moved",
    )

    // The executor returns: two members of three are a majority again. The
    // refused creation completes under the same key.
    let executor = remote_daemons.start(duo.executor)
    let _status =
      remote_daemons.await_directory(
        remote_daemons.open_control(executor),
        100,
        3,
      )
    let #(_completed, settled) = remote(on_bravo, 1500, "e2e-refused")
    assert remote_daemons.settled_state(settled) == "resident"

    // `alpha` returns, and the move finishes without being asked again.
    let alpha = remote_daemons.start(duo.alpha)
    let on_alpha = remote_daemons.open_control(alpha)
    let _status = remote_daemons.await_directory(on_alpha, 100, 3)
    let moved = remote_daemons.await_moved(on_bravo, 2000, moving, move_polls)
    assert moved == json.Object([#("to", json.String("alpha"))])
    let opened = remote_daemons.reopen_session(on_alpha, 2600, moving)
    assert remote_daemons.settled_state(opened) == "resident"
    Nil
  })
}

pub fn a_member_that_lost_its_disk_rejoins_as_a_non_voter_test_() -> EunitTest {
  remote_duo.shipped(rejoin_label, fn(duo) {
    let keys = remote_duo.provision(duo)
    remote_duo.configure_members(duo, keys, None)
    let members = remote_duo.start_members(duo)
    let on_bravo = remote_daemons.open_control(members.bravo)

    // `alpha` is stopped and its directory store removed, as a replaced disk
    // leaves a member: the catalogue and the sessions are still there.
    remote_daemons.retire(duo.alpha.paths)
    let store = duo.alpha.paths.root <> "/directory"
    let assert Ok(Nil) = simplifile.delete(store)
      as "alpha's directory store is removed"

    // `bravo` records a session while `alpha` is away.
    let #(bravos, settled) = remote(on_bravo, 1, "e2e-bravo")
    assert remote_daemons.settled_state(settled) == "resident"

    // Bootstrapping `alpha` now would start a second cluster, and is refused
    // because a member it reaches already runs one.
    let #(status, output) = remote_daemons.bootstrap_directory(duo.alpha)
    assert status != 0
    assert string.contains(output, "already runs a directory store")
    assert simplifile.is_directory(store) == Ok(False)

    // `alpha` starts and joins by itself, and is a voter once caught up.
    let alpha = remote_daemons.start(duo.alpha)
    let on_alpha = remote_daemons.open_control(alpha)
    let joined = remote_daemons.await_directory(on_alpha, 100, 3)
    assert remote_daemons.field(joined, "joined") == json.Bool(True)
    let assert Ok(log) = simplifile.read(duo.alpha.paths.log)
      as "alpha's log is readable"
    assert string.contains(log, "daemon.directory_joined")

    // Its copy holds what was written while it was away, and it writes again.
    let read = get(on_alpha, 300, bravos)
    assert code_of(read) == json.String("not_owner")
    assert remote_daemons.field(body_of(read), "orchestrator")
      == json.String("bravo")
    let #(alphas, settled) = remote(on_alpha, 400, "e2e-alpha")
    assert remote_daemons.settled_state(settled) == "resident"
    let read = get(on_bravo, 800, alphas)
    assert code_of(read) == json.String("not_owner")
    assert remote_daemons.field(body_of(read), "orchestrator")
      == json.String("alpha")
    Nil
  })
}

// --- control commands --------------------------------------------------------

// A remote session on the members' executor, created and settled.
fn remote(
  control: remote_daemons.Control,
  id: Int,
  key: String,
) -> #(String, JsonValue) {
  remote_daemons.create_and_settle(
    control,
    id,
    key,
    remote_duo.executor_name,
    remote_duo.workspace_name,
  )
}

fn get(control: remote_daemons.Control, id: Int, session: String) -> JsonValue {
  remote_daemons.command(
    control,
    id,
    "sessions.get",
    json.Object([#("session_id", json.String(session))]),
  )
}

fn body_of(reply: JsonValue) -> JsonValue {
  remote_daemons.field(reply, "body")
}

fn code_of(reply: JsonValue) -> JsonValue {
  assert remote_daemons.field(reply, "event") == json.String("error")
  remote_daemons.field(body_of(reply), "code")
}

// Whether an object has a member.
fn has_member(value: JsonValue, key: String) -> Bool {
  let assert json.Object(fields) = value as "the value is an object"
  list.key_find(fields, key) != Error(Nil)
}

// A lookup answered from the member's own copy, which must not wait on anyone.
fn timed(attempt: fn() -> a) -> a {
  let started = native.monotonic_time_ms()
  let answer = attempt()
  assert native.monotonic_time_ms() - started < local_read_ms
  answer
}
