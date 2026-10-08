//// The distributed runtime against the shipped daemon: an orchestrator and an
//// executor, two real `bin/loomd` processes that trust each other over TLS
//// distribution (issue #697, protocol-change/078).
////
//// The fixture mints a certificate authority and a leaf per node with
//// `openssl`, writes each node's cookie at that node's own `$HOME`, writes the
//// orchestrator's and the executor's `loom.toml`, renders each daemon's
//// distribution options with `loomd distribution options`, and starts both
//// daemons from the shipment with `LOOM_DISTRIBUTION_OPTFILE` set. The
//// executor's checkout is a directory of its own. The orchestrator has no
//// copy of it and is told only the name `repo`.
////
//// ## What it proves on this base
////
//// - Both daemons boot as TLS distribution members and register with `epmd`.
//// - A configured peer connects to each of them, and the orchestrator, asked
////   to dial the executor, does, with its own certificate and pins.
//// - A wrong pin keeps a connection out in each direction: a daemon whose
////   pin for the executor is a decoy cannot dial it, a probe that pins a decoy
////   for the executor cannot connect to it, and a probe presenting a leaf the
////   daemons never pinned is refused by both.
//// - `sessions.create` with `executor: "box", workspace: "repo"` is accepted
////   and stores both names verbatim, `executor_unknown` is refused, and the
////   opening fails with the `executor_unavailable:` reason the protocol
////   documents for a daemon that has no remote workspace assembly yet. Nothing
////   named `repo` appears on the orchestrator's host.
////
//// ## The probe
////
//// A daemon dials no peer yet, so its VM cannot report a connection. The test
//// VM cannot join a cluster either: it is not booted for distribution and the
//// other suites in it must stay non-distributed. So each daemon also lists a
//// third node, the probe (`support/remote_probe`), that a short-lived emulator
//// plays, and the test reads back what the probe saw and what it made a
//// daemon do. The probe holds full distribution privileges over the daemons
//// that list it, which is why its pin appears only in configuration files
//// inside this fixture's own directory.
////
//// ## What the follow-up changes
////
//// Search this file for `FOLLOW-UP`. When the executor role and the
//// orchestrator assembly land: turn on `executor_workspaces` so the executor
//// registers `repo`; replace `assert_opening_is_unavailable` with an assertion
//// that the opening settles `resident`; and call
//// `remote_daemons.drive_registered_session` inside
//// `provider_http.with_server(remote_daemons.registered_script(), ..)`, then
//// `assert_written_on_executor` and `assert_absent_from` over the
//// orchestrator's directories. Those helpers are written and not yet called.
////
//// ## Running it
////
//// ```sh
//// make server-shipment
//// export LOOM_BOOTSTRAP_E2E_SERVER=$PWD/bin/loomd
//// bash scripts/test.sh client --match 'client@daemon_shipped_remote_test:'
//// ```
////
//// Without the variable the test prints a skip line and passes. It needs
//// `openssl`, `erl` and `epmd` on `PATH`, and permission to listen on
//// loopback. The coordinator retains every daemon's endpoint outside the
//// bounded body, so a failed assertion still retires the daemons it started.

import broker/token
import client/tui_e2e_test.{type EunitTest, Timeout}
import core/json
import gleam/bit_array
import gleam/io
import gleam/list
import gleam/string
import host/bootstrap as native
import simplifile
import support/remote_daemons.{type Identity, type Layout, type Running, Trust}
import tui/daemon
import weft

// The executor's name for its checkout, and the name the orchestrator's
// sessions use for it. They are the same string on purpose: a session names a
// workspace by the executor's name for it.
const workspace_name = "repo"

// The orchestrator's name for the executor, an `[executors.<name>]` key.
const executor_name = "box"

// FOLLOW-UP: set this to `remote_daemons.WithWorkspaceRows` once the executor
// accepts a `[workspaces.<name>]` table. On this base the executor's
// configuration parser refuses the table, so the executor config omits it.
const executor_workspaces = remote_daemons.WithoutWorkspaceRows

/// Starts an orchestrator and an executor from the shipment and exercises
/// their trust, their registered-session creation and its refusal to open.
///
/// ## Examples
///
/// `bash scripts/test.sh client --match 'client@daemon_shipped_remote_test:'`.
pub fn daemon_shipped_remote_test_() -> EunitTest {
  // The runner scales EUnit timeouts by ten: 300 seconds around the 240-second
  // body, which boots three daemons and three probe emulators, and the
  // independent native cleanup after it.
  Timeout(30, fn() {
    case native.getenv("LOOM_BOOTSTRAP_E2E_SERVER") {
      Error(Nil) ->
        io.println_error(
          "SKIP shipped remote: LOOM_BOOTSTRAP_E2E_SERVER is unset",
        )
      Ok(_) -> fixture()
    }
  })
}

// Everything the body needs to be retired, fixed before anything starts.
type Fixture {
  Fixture(
    directory: String,
    orchestrator: Layout,
    executor: Layout,
    stray: Layout,
    checkout: String,
  )
}

fn fixture() -> Nil {
  let directory =
    "build/shipped-remote-"
    <> bit_array.base16_encode(token.production_entropy()(8))
  let assert Ok(Nil) = native.ensure_private_directory(directory)
    as "the fixture's state stays private"
  let assert Ok(directory) = native.canonical_directory(directory)
    as "the daemons receive absolute paths"
  let checkout = directory <> "/executor-checkout"
  let prepared =
    Fixture(
      directory:,
      orchestrator: remote_daemons.layout(directory, "orchestrator"),
      executor: remote_daemons.layout(directory, "executor"),
      stray: remote_daemons.layout(directory, "stray-orchestrator"),
      checkout:,
    )
  io.println_error("shipped remote fixture: " <> directory)
  let outcomes =
    weft.new([
      fn() {
        exercise(prepared)
        Ok(Nil)
      },
    ])
    |> weft.deadline(240_000)
    |> weft.start

  // Native cleanup runs outside the body's deadline and before the outcome is
  // read, so a body that failed mid-drive still retires every daemon.
  list.each([prepared.orchestrator, prepared.executor, prepared.stray], fn(l) {
    remote_daemons.retire(l.paths)
  })
  let assert [weft.Completed(0, Nil)] = outcomes
    as "the shipped remote body completes before native teardown"
  Nil
}

// The three nodes of the trust graph, with every credential they need.
//
// `stray` is a second orchestrator whose pin for the executor is the decoy's:
// the same node name, issued by the same authority, and a different
// certificate. It is the orchestrator with a wrong pin on its side of the
// connection. `wrong_leaf` has the probe's node name and a certificate no
// daemon pinned.
type Credentials {
  Credentials(
    authority: remote_daemons.Authority,
    orchestrator: Identity,
    executor: Identity,
    decoy: Identity,
    stray: Identity,
    probe: Identity,
    wrong_leaf: Identity,
  )
}

fn provision(prepared: Fixture) -> Credentials {
  let directory = prepared.directory
  let secrets = directory <> "/credentials"
  let assert Ok(Nil) = native.ensure_private_directory(secrets)
    as "the credentials directory is private"
  let authority = remote_daemons.mint_authority(secrets)
  let suffix = remote_daemons.random_hex(4)
  let probe_home = directory <> "/probe-home"
  let assert Ok(Nil) = native.ensure_private_directory(probe_home)
    as "the probe has a home of its own"
  let name = fn(role) { "loom_e2e_" <> role <> "_" <> suffix <> "@127.0.0.1" }
  let issue = fn(label, node, home) {
    remote_daemons.issue(authority, secrets, label, node, home)
  }
  let orchestrator =
    issue("orchestrator", name("orch"), prepared.orchestrator.home)
  let executor = issue("executor", name("exec"), prepared.executor.home)
  let probe = issue("probe", name("probe"), probe_home)
  let keys =
    Credentials(
      authority:,
      orchestrator:,
      executor:,
      decoy: issue("decoy", executor.node, prepared.executor.home),
      stray: issue("stray", name("stray"), prepared.stray.home),
      probe:,
      wrong_leaf: issue("wrong-leaf", probe.node, probe_home),
    )

  // One cookie for the whole cluster. Each VM reads it from its own home.
  let cookie = "loom-e2e-cookie-" <> remote_daemons.random_hex(16)
  list.each(
    [keys.orchestrator, keys.executor, keys.stray, keys.probe],
    fn(identity) { remote_daemons.write_cookie(identity, cookie) },
  )
  keys
}

// The configuration of each daemon. The orchestrator and the executor trust
// each other and the probe. The stray orchestrator trusts the executor by the
// decoy's pin, and the executor trusts the stray by its real one, so the only
// reason the stray's dial can fail is the stray's own wrong pin.
fn configure(prepared: Fixture, keys: Credentials) -> Nil {
  let unused_provider = "http://127.0.0.1:9"
  let table = fn(identity, peers) {
    remote_daemons.distribution_table(identity, keys.authority, peers)
  }
  let trust = fn(identity: Identity) { Trust(identity.node, identity.pin) }
  let write = fn(layout: Layout, text) {
    let assert Ok(Nil) = simplifile.write(layout.config, text)
      as "the daemon configuration is written"
    remote_daemons.write_options(layout)
  }
  write(
    prepared.executor,
    string.join(
      [
        remote_daemons.model_table(unused_provider),
        table(keys.executor, [
          trust(keys.orchestrator),
          trust(keys.stray),
          trust(keys.probe),
        ]),
        remote_daemons.workspace_rows(
          executor_workspaces,
          workspace_name,
          prepared.checkout,
        ),
      ],
      "\n",
    ),
  )
  write(
    prepared.orchestrator,
    string.join(
      [
        remote_daemons.model_table(unused_provider),
        table(keys.orchestrator, [trust(keys.executor), trust(keys.probe)]),
        remote_daemons.executor_table(executor_name, keys.executor.node),
      ],
      "\n",
    ),
  )
  write(
    prepared.stray,
    string.join(
      [
        remote_daemons.model_table(unused_provider),
        table(keys.stray, [
          Trust(keys.executor.node, keys.decoy.pin),
          trust(keys.probe),
        ]),
      ],
      "\n",
    ),
  )
}

fn exercise(prepared: Fixture) -> Nil {
  let keys = provision(prepared)

  // The executor's checkout is its own directory, with one file in it. The
  // orchestrator is never told where it is.
  let assert Ok(Nil) = simplifile.create_directory_all(prepared.checkout)
    as "the executor checkout is created"
  let assert Ok(Nil) =
    simplifile.write(prepared.checkout <> "/README.md", "executor only\n")
    as "the executor checkout has a file"
  configure(prepared, keys)

  // The executor starts first so that the daemons which dial it find it up.
  let executor = remote_daemons.start(prepared.executor)
  let orchestrator = remote_daemons.start(prepared.orchestrator)
  let stray = remote_daemons.start(prepared.stray)
  assert_registered_with_epmd(keys)
  assert_trust(prepared, keys)
  assert_registered_session(prepared, orchestrator)
  list.each([executor, orchestrator, stray], fn(running) {
    daemon.close(running.connected.control)
  })
}

// Both daemons, and the stray, booted as distribution members.
fn assert_registered_with_epmd(keys: Credentials) -> Nil {
  let registered = remote_daemons.epmd_names()
  list.each(
    [keys.orchestrator, keys.executor, keys.stray],
    fn(identity: Identity) {
      let assert [short, ..] = string.split(identity.node, "@")
      assert list.contains(registered, short)
    },
  )
}

// What each probe saw. The good probe is trusted by everyone and holds the
// right pins; the others each get one thing wrong.
fn assert_trust(prepared: Fixture, keys: Credentials) -> Nil {
  let launcher = prepared.orchestrator.launcher
  let directory = prepared.directory
  let right = [
    Trust(keys.orchestrator.node, keys.orchestrator.pin),
    Trust(keys.executor.node, keys.executor.pin),
    Trust(keys.stray.node, keys.stray.pin),
  ]
  let orch = keys.orchestrator.node
  let exec = keys.executor.node
  let stray = keys.stray.node

  // Correct pins everywhere. The probe reaches all three daemons. The
  // orchestrator, asked to dial the executor, does. The stray, whose pin for
  // the executor is the decoy's, does not. The executor ends up connected to
  // the orchestrator and the probe and to nobody else.
  let good =
    remote_daemons.probe(
      launcher,
      directory,
      "good",
      keys.probe,
      keys.authority,
      right,
    )
  let seen =
    remote_daemons.run_probe(good, directory, [
      "connect " <> orch,
      "connect " <> exec,
      "connect " <> stray,
      "dial " <> orch <> " " <> exec,
      "dial " <> stray <> " " <> exec,
      "hidden " <> exec,
    ])
  let both = list.sort([orch, keys.probe.node], string.compare)
  assert seen
    == [
      "RESULT connect " <> orch <> " connected",
      "RESULT connect " <> exec <> " connected",
      "RESULT connect " <> stray <> " connected",
      "RESULT dial " <> orch <> " " <> exec <> " connected",
      "RESULT dial " <> stray <> " " <> exec <> " refused",
      "RESULT hidden " <> exec <> " " <> string.join(both, ","),
    ]

  // A probe that pins the decoy for the executor cannot connect to it, and
  // the orchestrator is still reachable, so the refusal is about the pin.
  let wrong_pin =
    remote_daemons.probe(
      launcher,
      directory,
      "wrong-pin",
      keys.probe,
      keys.authority,
      [
        Trust(keys.orchestrator.node, keys.orchestrator.pin),
        Trust(keys.executor.node, keys.decoy.pin),
      ],
    )
  assert remote_daemons.run_probe(wrong_pin, directory, [
      "connect " <> orch,
      "connect " <> exec,
    ])
    == [
      "RESULT connect " <> orch <> " connected",
      "RESULT connect " <> exec <> " refused",
    ]

  // A probe with the right name and the right authority but a certificate no
  // daemon pinned is refused by both daemons.
  let wrong_leaf =
    remote_daemons.probe(
      launcher,
      directory,
      "wrong-leaf",
      keys.wrong_leaf,
      keys.authority,
      right,
    )
  assert remote_daemons.run_probe(wrong_leaf, directory, [
      "connect " <> orch,
      "connect " <> exec,
    ])
    == [
      "RESULT connect " <> orch <> " refused",
      "RESULT connect " <> exec <> " refused",
    ]
}

// The registered-session contract on this base: creation is accepted and
// remembered by name, an unknown executor is refused, and the opening fails.
fn assert_registered_session(prepared: Fixture, orchestrator: Running) -> Nil {
  let control = remote_daemons.open_control(orchestrator)
  let created =
    remote_daemons.create_registered(
      control,
      1,
      "e2e-registered",
      workspace_name,
      executor_name,
    )
  assert remote_daemons.field(created, "event")
    == json.String("sessions.create")
  let body = remote_daemons.field(created, "body")
  assert remote_daemons.field(body, "workspace") == json.String(workspace_name)
  assert remote_daemons.field(body, "executor") == json.String(executor_name)
  let assert json.String(session) = remote_daemons.field(body, "session_id")
    as "creation exposes the session identity"
  let assert json.String(operation) =
    remote_daemons.field(remote_daemons.field(body, "status"), "operation")
    as "creation starts one opening operation"
  assert_opening_is_unavailable(control, session, operation)

  // An executor the orchestrator's configuration does not define is refused
  // before anything is reserved.
  let unknown =
    remote_daemons.create_registered(
      control,
      900,
      "e2e-unknown",
      workspace_name,
      "nobody",
    )
  assert remote_daemons.field(remote_daemons.field(unknown, "body"), "code")
    == json.String("executor_unknown")

  // The orchestrator's host holds no directory for the registered name, and
  // the executor's checkout is exactly what the fixture put there.
  list.each(
    [
      workspace_name,
      prepared.orchestrator.directory <> "/" <> workspace_name,
      prepared.orchestrator.workspace <> "/" <> workspace_name,
    ],
    fn(path) {
      assert simplifile.is_directory(path) == Ok(False)
    },
  )
  assert simplifile.read_directory(prepared.checkout) == Ok(["README.md"])
}

// FOLLOW-UP: once the orchestrator can assemble a registered session this
// becomes "the operation settles resident", through the same
// `await_operation` poll, and the failing branch goes away.
fn assert_opening_is_unavailable(
  control: remote_daemons.Control,
  session: String,
  operation: String,
) -> Nil {
  let settled = remote_daemons.await_operation(control, 2, session, operation)
  assert remote_daemons.field(settled, "event") == json.String("error")
  let failure = remote_daemons.field(settled, "body")
  assert remote_daemons.field(failure, "code") == json.String("start_failed")
  let assert json.String(reason) = remote_daemons.field(failure, "message")
    as "a failed opening carries its bounded reason"
  assert string.starts_with(reason, "executor_unavailable: ")
}
