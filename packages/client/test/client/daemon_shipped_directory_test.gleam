//// Two orchestrators, against the shipped daemon: two real `bin/loomd`
//// processes that trust each other over TLS distribution and list each other
//// under `[orchestrators.<name>]` (issue #697, protocol-change/078, the
//// addendum on two orchestrators).
////
//// Each orchestrator keeps its own catalogue. A session is created on, and owned
//// by, the orchestrator the client is connected to, and nothing registers it with
//// the other. What this proves is what the other one does when the client names
//// that session anyway.
////
//// ## What it proves
////
//// `a_session_is_found_on_the_orchestrator_that_owns_it_test_`
////
//// - A session is created on `alpha` and settles resident. `bravo`'s catalogue
////   has no record of it, and `bravo` was never told it exists.
//// - `sessions.get` and `sessions.open` on `bravo` answer `not_owner` naming
////   `alpha` and the address `bravo`'s own configuration holds for it. Nothing
////   `alpha` sends carries that address. Asked the other way, `alpha` answers
////   `not_owner` naming `bravo` for a session created there, and its row has no
////   address, so the member is absent from the body.
//// - An identity that neither catalogue holds is `not_found` on both, and a
////   session each daemon holds itself is answered without any redirect.
//// - With `alpha` killed, `bravo` answers `owner_unreachable` naming `alpha`,
////   quickly, for the session and for an unknown identity alike, since the
////   daemon that cannot be asked might hold either.
//// - `alpha` is started again and `bravo`'s next lookup finds it: the lookup
////   connects on demand and keeps no failed attempt.
////
//// `a_session_is_listed_by_the_other_orchestrator_and_silence_is_not_empty_test_`
////
//// `sessions.elsewhere` (protocol-change/085) between the same two daemons.
////
//// - A session is created on each. `bravo` lists `alpha`'s session under
////   `alpha`, answered, with the address its configuration holds for `alpha`
////   and without its own session, and `alpha` lists `bravo`'s the same way.
//// - A key the configuration lacks is `not_found`.
//// - With `alpha` killed, `bravo` still lists the group, `silent` with no rows,
////   inside the fan-out's own bound. Silent is not an empty group.
////
//// `a_remote_session_is_found_through_the_directory_test_`
////
//// The same questions with the session directory's Khepri cluster
//// (protocol-change/083): `alpha`, `bravo` and an executor are its members, and
//// the sessions are remote ones on that executor, each recorded with its owner
//// by the orchestrator that created it.
////
//// - `bravo` answers `not_owner` naming `alpha`, with the address its own
////   configuration holds, for `alpha`'s session, and `alpha` answers the same
////   for `bravo`'s without an address. Each answer is read from the member's own
////   copy of the records; nobody is asked.
//// - A local session is recorded too, as a lookup hint written after it is
////   created, so `bravo` answers `not_owner` naming `alpha` for `alpha`'s local
////   session once the record lands, and a message from a session on `bravo`
////   to it is delivered exactly once. An identity nobody holds is `not_found`.
//// - `directory.status` on each member lists the three members as voters.
//// - With `alpha` killed, `bravo` still answers `not_owner` naming `alpha`,
////   quickly, and `not_found` for an unknown identity: a lookup never needs the
////   owner to answer. Two members of three are a majority, so `bravo` creates
////   another remote session meanwhile.
//// - `alpha` is started again, rejoins with three voters, and serves its own
////   session from its catalogue.
////
//// `the_admin_page_lists_each_machine_of_the_deployment_test_`
////
//// The Admin page's machines list (protocol-change/085, the addendum of
//// 2026-10-16) over the same three members. `alpha` answers `deployment.status`
//// over its control socket, the page's decoder reads the document, and the
//// Deployment section draws a row for the asking daemon, its peer orchestrator
//// and the executor. The browser's socket chain is not driven: no shipped
//// fixture has a WebSocket client for the page's ticket exchange.
////
//// ## Prerequisites and skips
////
//// Sessions here are local, so the daemons run a helper pool and the host has to
//// enforce a policy. A host whose helper cannot prints `SKIP shipped remote
//// directory: ...` and passes, as the other shipped fixtures do. No model turn is
//// taken.
////
//// ## Running it
////
//// ```sh
//// make server-shipment
//// make sandbox && install -m 0755 packages/sandbox/loom-exec bin/loom-exec
//// export LOOM_BOOTSTRAP_E2E_SERVER=$PWD/bin/loomd
//// export LOOM_TEST_PROVIDER_KEY=loom-provider-fixture-key
//// bash scripts/test.sh client --match 'client@daemon_shipped_directory_test:'
//// ```
////
//// The credentials, the daemons and the control commands are the vocabulary of
//// `support/remote_daemons`. The directory is under `/var/tmp` and short, as the
//// other shipped remote fixtures use, because a daemon binds unix sockets below
//// its state root.

import client/tui_e2e_test.{type EunitTest}
import core/json.{type JsonValue}
import gleam/list
import gleam/option.{Some}
import gleam/string
import host/bootstrap as native
import lustre/element
import support/remote_daemons
import support/remote_duo
import web_view/machines
import web_view/view/admin_machines
import weft/poll

const skip_label = "shipped remote directory"

const member_label = "shipped remote directory with members"

// The address `bravo`'s configuration holds for `alpha`. It is never bound, so
// that the test can tell a configured address from the daemon's real one.
const alphas_address = "wss://alpha.example.test:8443/v2/control"

// A canonical identity no catalogue holds.
const nobody_has = "0198c0de-0000-7000-8000-0000000000ff"

// A lookup that cannot reach its peer must end well inside this, which is
// the directory's own two-second deadline with room for the connection attempt.
const unreachable_ms = 6000

fn body_of(reply: JsonValue) -> JsonValue {
  remote_daemons.field(reply, "body")
}

fn code_of(reply: JsonValue) -> JsonValue {
  assert remote_daemons.field(reply, "event") == json.String("error")
  remote_daemons.field(body_of(reply), "code")
}

fn get(control: remote_daemons.Control, id: Int, session: String) -> JsonValue {
  remote_daemons.command(
    control,
    id,
    "sessions.get",
    json.Object([#("session_id", json.String(session))]),
  )
}

fn open(
  control: remote_daemons.Control,
  id: Int,
  session: String,
) -> JsonValue {
  remote_daemons.command(
    control,
    id,
    "sessions.open",
    json.Object([
      #("session_id", json.String(session)),
      #("epoch", json.String(control.epoch)),
    ]),
  )
}

// Whether a refusal body has a member, for the one that is optional.
fn has_member(reply: JsonValue, key: String) -> Bool {
  let assert json.Object(fields) = body_of(reply)
    as "a refusal body is an object"
  list.key_find(fields, key) != Error(Nil)
}

// A lookup that reaches no one must end inside the directory's deadline and not
// at the socket's.
fn timed(attempt: fn() -> a) -> a {
  let started = native.monotonic_time_ms()
  let answer = attempt()
  assert native.monotonic_time_ms() - started < unreachable_ms
  answer
}

// The first `sessions.get` that asks a peer pays for the TLS distribution
// connection to it, because `bravo` connects on demand. A lookup gives that
// connection 1.5 s under a 2 s deadline, and a first handshake on a loaded
// host can outlast both: the lookup then reports the peer silent, which is
// `owner_unreachable`, while the handshake goes on in the background and
// completes. That answer says nothing about the redirect these tests exist to
// check, so the first read of a peer retries while it is `owner_unreachable`
// and returns the first answer that is not. Only that code is retried, so
// every other answer, a wrong one included, is returned at once, and a peer
// that stays unreachable fails the test at the bound. The later
// `owner_unreachable` assertions, made with the peer killed, do not use it.
fn get_once_reachable(
  control: remote_daemons.Control,
  first_id: Int,
  session: String,
) -> JsonValue {
  let verdict =
    poll.fold_until(
      clock: poll.monotonic(),
      within: 30_000,
      every: poll.Fixed(250),
      from: first_id,
      attempt: fn(id) {
        let read = get(control, id, session)
        case code_of_any(read) == json.String("owner_unreachable") {
          True -> poll.Pending(id + 1)
          False -> poll.Settled(read)
        }
      },
    )
  case verdict {
    poll.Answer(read) -> read
    poll.Failure(..) | poll.RanOut(..) ->
      panic as "the peer stayed unreachable for the whole bound"
  }
}

pub fn a_session_is_found_on_the_orchestrator_that_owns_it_test_() -> EunitTest {
  remote_duo.shipped(skip_label, fn(duo) {
    let keys = remote_duo.provision(duo)
    remote_duo.configure(duo, keys, Some(alphas_address))
    let alpha = remote_daemons.start(duo.alpha)
    let bravo = remote_daemons.start(duo.bravo)
    let on_alpha = remote_daemons.open_control(alpha)
    let on_bravo = remote_daemons.open_control(bravo)

    // A session is created on `alpha` and on `bravo`, each where the client
    // was connected, and neither is told about the other's.
    let #(session, settled) =
      remote_daemons.create_local_and_settle(
        on_alpha,
        1,
        "e2e-alpha",
        duo.alpha.workspace,
      )
    assert remote_daemons.settled_state(settled) == "resident"
    let #(bravos, settled) =
      remote_daemons.create_local_and_settle(
        on_bravo,
        1,
        "e2e-bravo",
        duo.bravo.workspace,
      )
    assert remote_daemons.settled_state(settled) == "resident"

    // `bravo` does not hold `alpha`'s session, and says who does with the
    // address its own configuration gives for `alpha`.
    let read = get_once_reachable(on_bravo, 10, session)
    assert code_of(read) == json.String("not_owner")
    assert remote_daemons.field(body_of(read), "orchestrator")
      == json.String("alpha")
    assert remote_daemons.field(body_of(read), "address")
      == json.String(alphas_address)
    let opened = open(on_bravo, 11, session)
    assert code_of(opened) == json.String("not_owner")
    assert remote_daemons.field(body_of(opened), "orchestrator")
      == json.String("alpha")
    assert remote_daemons.field(body_of(opened), "address")
      == json.String(alphas_address)

    // The redirect did not copy the session: `bravo` still holds only its own.
    let listed =
      remote_daemons.command(
        on_bravo,
        12,
        "sessions.list",
        json.Object([#("after", json.String(""))]),
      )
    let assert json.Array([only]) =
      remote_daemons.field(body_of(listed), "sessions")
      as "bravo lists only the session created on it"
    assert remote_daemons.field(only, "session_id") == json.String(bravos)

    // The other direction, whose row has no address: the member is absent.
    let read = get(on_alpha, 13, bravos)
    assert code_of(read) == json.String("not_owner")
    assert remote_daemons.field(body_of(read), "orchestrator")
      == json.String("bravo")
    assert !has_member(read, "address")

    // A session each daemon holds is answered by it, and one nobody holds is
    // `not_found` on both once both have answered that they do not.
    assert remote_daemons.field(get(on_alpha, 14, session), "event")
      == json.String("sessions.get")
    assert remote_daemons.field(get(on_bravo, 14, bravos), "event")
      == json.String("sessions.get")
    assert code_of(get(on_alpha, 15, nobody_has)) == json.String("not_found")
    assert code_of(get(on_bravo, 15, nobody_has)) == json.String("not_found")

    // `alpha` goes away without closing anything. `bravo` can no longer tell,
    // and says which orchestrator it could not ask, for the session and for an
    // identity that is nobody's alike.
    remote_daemons.crash(duo.alpha)
    let gone = timed(fn() { get(on_bravo, 20, session) })
    assert code_of(gone) == json.String("owner_unreachable")
    assert remote_daemons.field(body_of(gone), "orchestrators")
      == json.Array([json.String("alpha")])
    let gone = timed(fn() { open(on_bravo, 21, session) })
    assert code_of(gone) == json.String("owner_unreachable")
    let gone = timed(fn() { get(on_bravo, 22, nobody_has) })
    assert code_of(gone) == json.String("owner_unreachable")

    // Its own session is still `bravo`'s to answer without asking anyone.
    assert remote_daemons.field(get(on_bravo, 23, bravos), "event")
      == json.String("sessions.get")

    // `alpha` comes back, and the next lookup finds it again: `bravo` kept no
    // record of the failure and made no attempt of its own in between.
    let _alpha = remote_daemons.start(duo.alpha)
    let found = get_once_reachable(on_bravo, 30, session)
    assert code_of(found) == json.String("not_owner")
    assert remote_daemons.field(body_of(found), "orchestrator")
      == json.String("alpha")
    Nil
  })
}

// `sessions.elsewhere` on one orchestrator, read until the peer answers: the
// first read that dials a peer pays for the TLS connection to it, and a read that
// finds the peer silent while that handshake completes says nothing about the
// listing these tests exist to check.
fn elsewhere_once_reachable(
  control: remote_daemons.Control,
  first_id: Int,
  group: String,
) -> JsonValue {
  let verdict =
    poll.fold_until(
      clock: poll.monotonic(),
      within: 30_000,
      every: poll.Fixed(250),
      from: first_id,
      attempt: fn(id) {
        let read =
          remote_daemons.command(
            control,
            id,
            "sessions.elsewhere",
            json.Object([]),
          )
        case group_state(read, group) == json.String("silent") {
          True -> poll.Pending(id + 1)
          False -> poll.Settled(read)
        }
      },
    )
  case verdict {
    poll.Answer(read) -> read
    poll.Failure(..) | poll.RanOut(..) ->
      panic as "the peer stayed silent for the whole bound"
  }
}

// The group a `sessions.elsewhere` reply holds under a configuration key.
fn group_of(reply: JsonValue, key: String) -> JsonValue {
  let assert json.Array(groups) =
    remote_daemons.field(body_of(reply), "orchestrators")
    as "the reply lists orchestrators"
  let assert Ok(found) =
    list.find(groups, fn(group) {
      remote_daemons.field(group, "name") == json.String(key)
    })
    as "the reply has the group"
  found
}

fn group_state(reply: JsonValue, key: String) -> JsonValue {
  remote_daemons.field(group_of(reply, key), "state")
}

pub fn a_session_is_listed_by_the_other_orchestrator_and_silence_is_not_empty_test_() -> EunitTest {
  remote_duo.shipped(skip_label, fn(duo) {
    let keys = remote_duo.provision(duo)
    remote_duo.configure(duo, keys, Some(alphas_address))
    let alpha = remote_daemons.start(duo.alpha)
    let bravo = remote_daemons.start(duo.bravo)
    let on_alpha = remote_daemons.open_control(alpha)
    let on_bravo = remote_daemons.open_control(bravo)

    // One session on each orchestrator, created where the client was connected.
    let #(session, _) =
      remote_daemons.create_local_and_settle(
        on_alpha,
        1,
        "e2e-alpha",
        duo.alpha.workspace,
      )
    let #(bravos, _) =
      remote_daemons.create_local_and_settle(
        on_bravo,
        1,
        "e2e-bravo",
        duo.bravo.workspace,
      )

    // `bravo` lists `alpha`'s session under `alpha`, with the address its own
    // configuration holds for it, and not its own session.
    let read = elsewhere_once_reachable(on_bravo, 10, "alpha")
    assert remote_daemons.field(read, "event")
      == json.String("sessions.elsewhere")
    let group = group_of(read, "alpha")
    assert remote_daemons.field(group, "state") == json.String("answered")
    assert remote_daemons.field(group, "address") == json.String(alphas_address)
    assert remote_daemons.field(group, "more") == json.Bool(False)
    let assert json.Array([row]) = remote_daemons.field(group, "sessions")
      as "alpha lists its one session"
    assert remote_daemons.field(row, "session_id") == json.String(session)
    assert remote_daemons.field(row, "name") == json.String("local e2e-alpha")

    // The other direction lists `bravo`'s session, which has no address because
    // `alpha`'s configuration gives none for it.
    let read = elsewhere_once_reachable(on_alpha, 11, "bravo")
    let group = group_of(read, "bravo")
    let assert json.Array([row]) = remote_daemons.field(group, "sessions")
      as "bravo lists its one session"
    assert remote_daemons.field(row, "session_id") == json.String(bravos)

    // A key the configuration lacks is `not_found` and nobody is asked.
    let missing =
      remote_daemons.command(
        on_bravo,
        12,
        "sessions.elsewhere",
        json.Object([#("orchestrator", json.String("ghost"))]),
      )
    assert code_of(missing) == json.String("not_found")

    // `alpha` goes away without closing anything. `bravo` still lists the group,
    // as one silent line with no rows, which is not the same as `alpha` holding
    // nothing, and answers inside the fan-out's own bound.
    remote_daemons.crash(duo.alpha)
    let gone =
      timed(fn() {
        remote_daemons.command(
          on_bravo,
          20,
          "sessions.elsewhere",
          json.Object([]),
        )
      })
    let group = group_of(gone, "alpha")
    assert remote_daemons.field(group, "state") == json.String("silent")
    assert remote_daemons.field(group, "sessions") == json.Array([])
    assert remote_daemons.field(group, "more") == json.Bool(False)
    Nil
  })
}

pub fn a_remote_session_is_found_through_the_directory_test_() -> EunitTest {
  remote_duo.shipped(member_label, fn(duo) {
    let keys = remote_duo.provision(duo)
    remote_duo.configure_members(duo, keys, Some(alphas_address))
    let members = remote_duo.start_members(duo)
    let on_alpha = remote_daemons.open_control(members.alpha)
    let on_bravo = remote_daemons.open_control(members.bravo)

    // A remote session is created on each orchestrator, which records itself as
    // its owner before the session opens, and a local one on `alpha`, whose
    // record follows within one movers tick.
    let #(session, settled) = remote(on_alpha, 1, "e2e-alpha")
    assert remote_daemons.settled_state(settled) == "resident"
    let #(bravos, settled) = remote(on_bravo, 1, "e2e-bravo")
    assert remote_daemons.settled_state(settled) == "resident"
    let #(local, settled) =
      remote_daemons.create_local_and_settle(
        on_alpha,
        400,
        "e2e-local",
        duo.alpha.workspace,
      )
    assert remote_daemons.settled_state(settled) == "resident"

    // Every member lists the three as voters.
    let status = remote_daemons.directory_status(on_bravo, 800)
    assert remote_daemons.field(status, "members")
      == json.Array([
        json.String(keys.alpha.node),
        json.String(keys.bravo.node),
        json.String(keys.executor.node),
      ])

    // Each orchestrator names the other for the other's session, from its own
    // copy of the record and its own configuration of the address.
    let read = get(on_bravo, 810, session)
    assert code_of(read) == json.String("not_owner")
    assert remote_daemons.field(body_of(read), "orchestrator")
      == json.String("alpha")
    assert remote_daemons.field(body_of(read), "address")
      == json.String(alphas_address)
    let opened = open(on_bravo, 811, session)
    assert code_of(opened) == json.String("not_owner")
    assert remote_daemons.field(body_of(opened), "orchestrator")
      == json.String("alpha")
    let read = get(on_alpha, 812, bravos)
    assert code_of(read) == json.String("not_owner")
    assert remote_daemons.field(body_of(read), "orchestrator")
      == json.String("bravo")
    assert !has_member(read, "address")

    // `alpha`'s local session is recorded as a lookup hint, so `bravo` names
    // `alpha` for it once the record lands. An identity nobody holds is still
    // `not_found` on both, and the local session is `alpha`'s own to answer.
    let read = await_redirect(on_bravo, 2000, local)
    assert remote_daemons.field(body_of(read), "orchestrator")
      == json.String("alpha")
    assert remote_daemons.field(body_of(read), "address")
      == json.String(alphas_address)
    assert code_of(get(on_alpha, 814, nobody_has)) == json.String("not_found")
    assert code_of(get(on_bravo, 814, nobody_has)) == json.String("not_found")
    assert remote_daemons.field(get(on_alpha, 815, local), "event")
      == json.String("sessions.get")

    // A session on `bravo` mails `alpha`'s local session: the route is the
    // record, and the message lands once, however often it is sent.
    let linked = remote_daemons.peers_link(on_bravo, 816, bravos, local)
    assert remote_daemons.field(linked, "event") == json.String("peers.link")
    let sent =
      remote_daemons.peers_send(on_bravo, 817, bravos, local, "m1", "to local")
    assert remote_daemons.field(sent, "event") == json.String("peers.send")
    assert remote_daemons.field(body_of(sent), "admitted") == json.Bool(True)
    remote_duo.await_peer_messages(duo, duo.alpha, local, "to local", 1)
    let again =
      remote_daemons.peers_send(on_bravo, 818, bravos, local, "m1", "to local")
    assert remote_daemons.field(again, "event") == json.String("peers.send")
    assert remote_duo.peer_messages(duo, duo.alpha, local, "to local") == Ok(1)

    // `alpha` goes away. `bravo` reads the record from its own copy, so the
    // answer is still `not_owner` and is quick, and an unknown identity is
    // still `not_found`: the owner is never asked.
    remote_daemons.crash(duo.alpha)
    let gone = timed(fn() { get(on_bravo, 820, session) })
    assert code_of(gone) == json.String("not_owner")
    assert remote_daemons.field(body_of(gone), "orchestrator")
      == json.String("alpha")
    let gone = timed(fn() { get(on_bravo, 821, nobody_has) })
    assert code_of(gone) == json.String("not_found")
    let gone = timed(fn() { get(on_bravo, 822, local) })
    assert code_of(gone) == json.String("not_owner")

    // `bravo` and the executor are two of three members, a majority, so a
    // remote session can still be created and recorded.
    let #(_another, settled) = remote(on_bravo, 830, "e2e-meanwhile")
    assert remote_daemons.settled_state(settled) == "resident"

    // `alpha` comes back, rejoins with every voter, and serves its session.
    let alpha = remote_daemons.start(duo.alpha)
    let on_alpha = remote_daemons.open_control(alpha)
    let _status = remote_daemons.await_directory(on_alpha, 1200, 3)
    assert remote_daemons.field(get(on_alpha, 1300, session), "event")
      == json.String("sessions.get")
    Nil
  })
}

// Polls `sessions.get` on a member until it redirects for `session`, and
// returns the refusal. Each poll is a new request, numbered from `first_id`.
//
// The wait is for the owner's record of a local session to reach this member's
// copy of the store. The record is a lookup hint, so creating the session does
// not wait for it: the owner's movers write it on their next pass, which
// starts at most every five seconds and runs the seed and the deletions before
// it writes the record. Each step of a pass is bounded by its own Khepri
// deadline of a few seconds, the write is a majority commit among three
// members connected over TLS, and the member under test then applies it from
// the leader. On an idle host that is one tick. On a host running the whole
// client lane at once a pass that times out is retried only on the tick after
// it, so the record can take several passes, and the twenty seconds this poll
// used to allow was a count of requests, which stretches with the cost of each.
//
// The bound is a time, ninety seconds, which is a dozen or more passes. The
// body deadline is 420 seconds and the rest of this test needs far less than
// the remainder even on a loaded host, so a record that has not landed by then
// is a failure and not a slow run. The last reply is reported with the
// failure, because "the record never landed" and "the member answered
// something other than a redirect" are different bugs.
fn await_redirect(
  control: remote_daemons.Control,
  first_id: Int,
  session: String,
) -> JsonValue {
  let verdict =
    poll.fold_until(
      clock: poll.monotonic(),
      within: 90_000,
      every: poll.Fixed(250),
      from: #(first_id, json.Null),
      attempt: fn(state) {
        let #(id, _last) = state
        let read = get(control, id, session)
        case code_of_any(read) == json.String("not_owner") {
          True -> poll.Settled(read)
          False -> poll.Pending(#(id + 1, read))
        }
      },
    )
  case verdict {
    poll.Answer(read) -> read
    poll.Failure(..) -> panic as "a redirect poll has no failure of its own"
    poll.RanOut(state: #(_id, last)) ->
      panic as {
        "the local session's record did not land; the last reply was "
        <> json.to_string(last)
      }
  }
}

// The code of a reply that may not be an error yet.
fn code_of_any(reply: JsonValue) -> JsonValue {
  case remote_daemons.field(reply, "event") {
    json.String("error") -> remote_daemons.field(body_of(reply), "code")
    other -> other
  }
}

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

// The Admin page's machines list (protocol-change/085, the addendum of
// 2026-10-16) against the three real daemons: `alpha` is asked for the
// deployment over its control socket, the page's own decoder reads the reply the
// way the page's read does (`server.admin_deployment` makes this very read), and
// the Deployment section draws a row for each of the three nodes, the asking
// daemon, its peer orchestrator and the executor.
//
// No shipped fixture drives the browser's WebSocket and the page's ticket chain,
// so the page is not reached through them; the daemon's half of the read is the
// real one and the page's half is its real view over the real document.
pub fn the_admin_page_lists_each_machine_of_the_deployment_test_() -> EunitTest {
  remote_duo.shipped(member_label, fn(duo) {
    let keys = remote_duo.provision(duo)
    remote_duo.configure_members(duo, keys, Some(alphas_address))
    let members = remote_duo.start_members(duo)
    let on_alpha = remote_daemons.open_control(members.alpha)
    let reply =
      remote_daemons.command(on_alpha, 1, "deployment.status", json.Object([]))
    assert remote_daemons.field(reply, "event")
      == json.String("deployment.status")
    let assert Ok(snapshot) = machines.decode_overview(body_of(reply))
      as "the page's decoder reads the daemon's own document"
    let names = list.map(snapshot.machines, fn(machine) { machine.name })
    assert list.length(names) == 3
    assert list.contains(names, "bravo")
    assert list.contains(names, remote_duo.executor_name)
    let html =
      admin_machines.view(admin_machines.Section(
        held: machines.Known(snapshot),
        chosen: option.None,
        choose: fn(_) { Nil },
        page: element.none(),
      ))
      |> element.to_string
    list.each(names, fn(name) {
      assert string.contains(html, ">" <> name <> "<")
    })
    assert string.contains(html, "Deployment · 3 nodes")
    Nil
  })
}
