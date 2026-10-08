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

import broker/token
import client/tui_e2e_test.{type EunitTest, Timeout}
import core/json.{type JsonValue}
import gleam/bit_array
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap as native
import simplifile
import support/enforcement
import support/remote_daemons.{Trust}
import weft

const skip_label = "shipped remote directory"

// The address `bravo`'s configuration holds for `alpha`. It is never bound, so
// that the test can tell a configured address from the daemon's real one.
const alphas_address = "wss://alpha.example.test:8443/v2/control"

// A canonical identity no catalogue holds.
const nobody_has = "0198c0de-0000-7000-8000-0000000000ff"

// The longest the body may run, and the EUnit timeout, which the runner scales
// by ten.
const body_ms = 420_000

const eunit_seconds = 60

// A lookup that cannot reach its peer must end well inside this, which is
// the directory's own two-second deadline with room for the connection attempt.
const unreachable_ms = 6000

type Duo {
  Duo(
    directory: String,
    alpha: remote_daemons.Layout,
    bravo: remote_daemons.Layout,
  )
}

type Credentials {
  Credentials(
    authority: remote_daemons.Authority,
    alpha: remote_daemons.Identity,
    bravo: remote_daemons.Identity,
  )
}

// Gates the test on the host and runs `body` against a fresh duo, retiring both
// daemons by their recorded identity afterward whether it passed or not.
fn shipped(body: fn(Duo) -> Nil) -> EunitTest {
  Timeout(eunit_seconds, fn() {
    case native.getenv("LOOM_BOOTSTRAP_E2E_SERVER") {
      Error(Nil) ->
        io.println_error(
          "SKIP " <> skip_label <> ": LOOM_BOOTSTRAP_E2E_SERVER is unset",
        )
      Ok(server) ->
        case enforcement.probe(server, skip_label) {
          enforcement.EnforcementAbsent -> Nil
          enforcement.EnforcementLive -> fixture(body)
        }
    }
  })
}

fn fixture(body: fn(Duo) -> Nil) -> Nil {
  let directory =
    "/var/tmp/loom-rt-"
    <> string.lowercase(bit_array.base16_encode(token.production_entropy()(4)))
  let assert Ok(Nil) = native.ensure_private_directory(directory)
    as "the fixture's state stays private"
  let assert Ok(directory) = native.canonical_directory(directory)
    as "the daemons receive absolute paths"
  let duo =
    Duo(
      directory:,
      alpha: remote_daemons.layout(directory, "alpha"),
      bravo: remote_daemons.layout(directory, "bravo"),
    )
  io.println_error(skip_label <> " fixture: " <> directory)
  let outcomes =
    weft.new([
      fn() {
        body(duo)
        Ok(Nil)
      },
    ])
    |> weft.deadline(body_ms)
    |> weft.start

  // Native cleanup runs outside the body's deadline and before the outcome is
  // read, so a body that failed mid-drive still retires every daemon. A daemon
  // the body already killed has no process to retire, which `retire` accepts.
  list.each([duo.alpha, duo.bravo], fn(layout) {
    remote_daemons.retire(layout.paths)
  })
  let assert [weft.Completed(0, Nil)] = outcomes
    as "the shipped directory body completes before native teardown"
  let _removed = simplifile.delete_all([directory])
  Nil
}

// Mints the authority, one leaf per node and the cookie both share.
fn provision(duo: Duo) -> Credentials {
  let secrets = duo.directory <> "/credentials"
  let assert Ok(Nil) = native.ensure_private_directory(secrets)
    as "the credentials directory is private"
  let authority = remote_daemons.mint_authority(secrets)
  let suffix = remote_daemons.random_hex(4)
  let name = fn(role) { "loom_e2e_" <> role <> "_" <> suffix <> "@127.0.0.1" }
  let keys =
    Credentials(
      authority:,
      alpha: remote_daemons.issue(
        authority,
        secrets,
        "alpha",
        name("alpha"),
        duo.alpha.home,
      ),
      bravo: remote_daemons.issue(
        authority,
        secrets,
        "bravo",
        name("bravo"),
        duo.bravo.home,
      ),
    )
  let cookie = "loom-e2e-cookie-" <> remote_daemons.random_hex(16)
  list.each([keys.alpha, keys.bravo], fn(identity) {
    remote_daemons.write_cookie(identity, cookie)
  })
  keys
}

// Writes both configuration files. Each daemon lists the other, `alpha`'s row
// for `bravo` with no address and `bravo`'s row for `alpha` with one, so both
// shapes of the refusal are exercised.
fn configure(duo: Duo, keys: Credentials) -> Nil {
  let write = fn(layout: remote_daemons.Layout, text) {
    let assert Ok(Nil) = simplifile.write(layout.config, text)
      as "the daemon configuration is written"
    remote_daemons.write_options(layout)
  }
  write(
    duo.alpha,
    string.join(
      [
        remote_daemons.model_table("http://127.0.0.1:9"),
        remote_daemons.distribution_table(keys.alpha, keys.authority, [
          Trust(keys.bravo.node, keys.bravo.pin),
        ]),
        remote_daemons.orchestrator_table("bravo", keys.bravo.node, None),
      ],
      "\n",
    ),
  )
  write(
    duo.bravo,
    string.join(
      [
        remote_daemons.model_table("http://127.0.0.1:9"),
        remote_daemons.distribution_table(keys.bravo, keys.authority, [
          Trust(keys.alpha.node, keys.alpha.pin),
        ]),
        remote_daemons.orchestrator_table(
          "alpha",
          keys.alpha.node,
          Some(alphas_address),
        ),
      ],
      "\n",
    ),
  )
}

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

pub fn a_session_is_found_on_the_orchestrator_that_owns_it_test_() -> EunitTest {
  shipped(fn(duo) {
    let keys = provision(duo)
    configure(duo, keys)
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
    let read = get(on_bravo, 10, session)
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
    let found = get(on_bravo, 30, session)
    assert code_of(found) == json.String("not_owner")
    assert remote_daemons.field(body_of(found), "orchestrator")
      == json.String("alpha")
    Nil
  })
}
