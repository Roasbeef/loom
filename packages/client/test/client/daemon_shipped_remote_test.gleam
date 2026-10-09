//// The distributed runtime against the shipped daemon: an orchestrator and an
//// executor, two real `bin/loomd` processes that trust each other over TLS
//// distribution (issue #697, protocol-change/078).
////
//// The fixture mints a certificate authority and a leaf per node with
//// `openssl`, writes each node's cookie at that node's own `$HOME`, writes the
//// orchestrator's and the executor's `loom.toml`, renders each daemon's
//// distribution options with `loomd distribution options`, and starts both
//// daemons from the shipment with `LOOM_DISTRIBUTION_OPTFILE` set. The
//// executor's checkout is a directory of its own, registered as
//// `[workspaces.repo]`. The orchestrator has no copy of it and is told only
//// the name `repo`. The orchestrator's model is a scripted Anthropic peer on
//// loopback (`support/provider_http`), so a session runs a real turn.
////
//// ## What it proves
////
//// `daemon_shipped_remote_test_`, one registered session through its life.
////
//// - Both daemons boot as TLS distribution members and register with `epmd`.
//// - A wrong pin keeps a connection out in each direction: a daemon whose
////   pin for the executor is a decoy cannot dial it, a probe that pins a decoy
////   for the executor cannot connect to it, and a probe presenting a leaf the
////   daemons never pinned is refused by both. Before any session exists, no
////   daemon has dialed the executor.
//// - `sessions.create` with `executor: "box", workspace: "repo"` is accepted,
////   stores both names verbatim, and its opening settles `resident`.
////   `executor_unknown` is refused.
//// - The scripted model writes a file with `fs_write`, reads it with `bash`
////   and with `fs_read`, and answers. Each tool result reaches the model. The
////   file is under the executor's checkout and nothing named like it, and no
////   directory named `repo`, exists on the orchestrator.
//// - The orchestrator's own connection to the executor is observed from the
////   executor's side, with no probe asked to dial.
//// - Stopping the session closes the executor's scope `closed` with
////   `all_retired` at incarnation 1. Opening it again attaches at incarnation
////   2, a `bash` call there reads the earlier file, and a second stop closes
////   incarnation 2 the same way.
////
//// `daemon_shipped_remote_restart_test_` and
//// `daemon_shipped_remote_partition_test_`, a remote `bash` call that outlives
//// its connection. The call is `echo ran >> ran.log; sleep 8; echo finished;
//// echo done >> ran.log`, so the side-effect file counts how many times it ran.
////
//// - Restart: the orchestrator is killed with `SIGKILL` while the call runs
////   and started again on the same state. The session is opened again once
////   the dead daemon's writer lease expires, recovers the call from the
////   executor's ledger, and the model receives its stored outcome.
//// - Partition: the probe has the orchestrator drop its connection to the
////   executor while the call runs. Both daemons stay up; the orchestrator
////   repairs the connection and sends the same call again.
//// - Either way the side-effect file holds `ran` and `done` once each, and the
////   provider saw one tool result for the call.
////
//// ## The probe
////
//// The test VM cannot join a cluster: it is not booted for distribution and the
//// other suites in it must stay non-distributed. So each daemon also lists a
//// third node, the probe (`support/remote_probe`), that a short-lived emulator
//// plays, and the test reads back what the probe saw. The probe holds full
//// distribution privileges over the daemons that list it, which is why its
//// pin appears only in configuration files inside this fixture's own
//// directory.
////
//// ## Running it
////
//// ```sh
//// make server-shipment
//// make sandbox && install -m 0755 packages/sandbox/loom-exec bin/loom-exec
//// export LOOM_BOOTSTRAP_E2E_SERVER=$PWD/bin/loomd
//// export LOOM_TEST_PROVIDER_KEY=loom-provider-fixture-key
//// bash scripts/test.sh client --match 'client@daemon_shipped_remote_test:'
//// ```
////
//// Without the variable the test prints a skip line and passes. It needs
//// `openssl`, `erl` and `epmd` on `PATH`, the sandbox helper beside the
//// launcher (the executor refuses to start without one), and permission to
//// listen on loopback. The coordinator retains every daemon's endpoint outside
//// the bounded body, so a failed assertion still retires the daemons it
//// started.

import broker/token
import client/tui_e2e_test.{type EunitTest, Timeout}
import core/json
import gleam/bit_array
import gleam/erlang/process
import gleam/io
import gleam/list
import gleam/string
import host/bootstrap as native
import simplifile
import storage/exec_ledger
import support/enforcement
import support/provider_http as provider
import support/remote_daemons.{type Identity, type Layout, type Running, Trust}
import support/tui_driver
import tui/daemon
import weft
import weft/poll

// The executor's name for its checkout, and the name the orchestrator's
// sessions use for it. They are the same string on purpose: a session names a
// workspace by the executor's name for it.
const workspace_name = "repo"

// The orchestrator's name for the executor, an `[executors.<name>]` key.
const executor_name = "box"

// The side-effect file the restart drill's `bash` call appends to.
const ran_log = "ran.log"

// The prompt of the restart drill and the text the model answers with.
const slow_prompt = "run the slow command"

const slow_answer = "slow done"

/// Starts an orchestrator and an executor from the shipment and takes one
/// registered session through opening, a scripted turn, a stop and a reopen.
///
/// ## Examples
///
/// `bash scripts/test.sh client --match 'client@daemon_shipped_remote_test:'`.
pub fn daemon_shipped_remote_test_() -> EunitTest {
  // The runner scales EUnit timeouts by ten: 300 seconds around the 240-second
  // body, which boots three daemons and three probe emulators, and the
  // independent native cleanup after it.
  shipped(registered_session)
}

/// Kills the orchestrator while a remote `bash` call runs and starts it again.
///
/// ## Examples
///
/// `bash scripts/test.sh client --match 'client@daemon_shipped_remote_test:'`.
pub fn daemon_shipped_remote_restart_test_() -> EunitTest {
  shipped(restart_drill)
}

/// Drops the distribution connection between the daemons while a remote `bash`
/// call runs.
///
/// ## Examples
///
/// `bash scripts/test.sh client --match 'client@daemon_shipped_remote_test:'`.
pub fn daemon_shipped_remote_partition_test_() -> EunitTest {
  shipped(partition_drill)
}

fn shipped(body: fn(Fixture) -> Nil) -> EunitTest {
  Timeout(30, fn() {
    case native.getenv("LOOM_BOOTSTRAP_E2E_SERVER") {
      Error(Nil) ->
        io.println_error(
          "SKIP shipped remote: LOOM_BOOTSTRAP_E2E_SERVER is unset",
        )

      // The executor jails every `bash` call, so a host whose helper cannot
      // enforce a policy declines the whole fixture, as the other shipped
      // fixtures that run jailed tools do.
      Ok(server) ->
        case enforcement.probe(server, "shipped remote") {
          enforcement.EnforcementAbsent -> Nil
          enforcement.EnforcementLive -> fixture(body)
        }
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

fn fixture(body: fn(Fixture) -> Nil) -> Nil {
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
        body(prepared)
        Ok(Nil)
      },
    ])
    |> weft.deadline(240_000)
    |> weft.start

  // Native cleanup runs outside the body's deadline and before the outcome is
  // read, so a body that failed mid-drive still retires every daemon. A daemon
  // the body never started recorded no endpoint, and retiring it does nothing.
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
// reason the stray's dial can fail is the stray's own wrong pin. The
// orchestrator's one model is the scripted provider at `provider_url`.
fn configure(
  prepared: Fixture,
  keys: Credentials,
  provider_url: String,
) -> Nil {
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
        remote_daemons.workspace_table(workspace_name, prepared.checkout),
      ],
      "\n",
    ),
  )
  write(
    prepared.orchestrator,
    string.join(
      [
        remote_daemons.model_table(provider_url),
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

// The executor's checkout is its own directory, with one file in it. The
// orchestrator is never told where it is.
fn make_checkout(prepared: Fixture) -> Nil {
  let assert Ok(Nil) = simplifile.create_directory_all(prepared.checkout)
    as "the executor checkout is created"
  let assert Ok(Nil) =
    simplifile.write(prepared.checkout <> "/README.md", "executor only\n")
    as "the executor checkout has a file"
  Nil
}

// --- one registered session through its life --------------------------------

fn registered_session(prepared: Fixture) -> Nil {
  let keys = provision(prepared)
  make_checkout(prepared)
  let script =
    list.append(
      remote_daemons.registered_script(),
      remote_daemons.reopened_script(),
    )
  let #(Nil, report) =
    provider.with_server(script, fn(url) {
      configure(prepared, keys, url)

      // The executor starts first so that the daemons which dial it find it up.
      let executor = remote_daemons.start(prepared.executor)
      let orchestrator = remote_daemons.start(prepared.orchestrator)
      let stray = remote_daemons.start(prepared.stray)
      assert_registered_with_epmd(keys)
      assert_trust(prepared, keys)
      let session = assert_registered_session(prepared, orchestrator)
      assert_first_turn(prepared, orchestrator, session)
      assert_orchestrator_connected(prepared, keys)
      assert_reopened(prepared, orchestrator, session)
      list.each([executor, orchestrator, stray], fn(running) {
        daemon.close(running.connected.control)
      })
    })
  let assert Ok(requests) = report
    as "the provider saw exactly the scripted conversation"
  assert_tool_results(requests)
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

  // Correct pins everywhere. The probe reaches all three daemons. The stray,
  // whose pin for the executor is the decoy's, cannot dial it. No session
  // exists yet, so nobody but the probe is connected to the executor: a daemon
  // dials an executor only to open a session on it.
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
      "dial " <> stray <> " " <> exec,
      "hidden " <> exec,
    ])
  assert seen
    == [
      "RESULT connect " <> orch <> " connected",
      "RESULT connect " <> exec <> " connected",
      "RESULT connect " <> stray <> " connected",
      "RESULT dial " <> stray <> " " <> exec <> " refused",
      "RESULT hidden " <> exec <> " " <> keys.probe.node,
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

// Creation is accepted and remembered by name, the opening settles resident on
// the executor, and an unknown executor is refused. Returns the session.
fn assert_registered_session(
  prepared: Fixture,
  orchestrator: Running,
) -> String {
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

  // The opening is the orchestrator attaching to the executor over
  // distribution and building the session on what it reports.
  let settled = remote_daemons.await_operation(control, 2, session, operation)
  assert remote_daemons.field(settled, "event") == json.String("operations.get")
  assert remote_daemons.settled_state(settled) == "resident"

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

  // The executor's checkout is exactly what the fixture put there so far.
  assert visible(prepared) == ["README.md"]
  session
}

// The scripted model writes the note, reads it with `bash` and `fs_read`, and
// answers. The note lands under the executor's checkout and nowhere on the
// orchestrator.
fn assert_first_turn(
  prepared: Fixture,
  orchestrator: Running,
  session: String,
) -> Nil {
  remote_daemons.converse(orchestrator, session, remote_daemons.first_prompt, [
    remote_daemons.first_answer,
  ])
  remote_daemons.assert_written_on_executor(prepared.checkout)
  assert_orchestrator_has_no_copy(prepared, orchestrator)
}

// The orchestrator's host holds nothing named like the registered workspace or
// like the file the model wrote. The session database legitimately holds the
// text, so the check is by name.
fn assert_orchestrator_has_no_copy(
  prepared: Fixture,
  orchestrator: Running,
) -> Nil {
  list.each(
    [
      workspace_name,
      prepared.orchestrator.directory <> "/" <> workspace_name,
      prepared.orchestrator.workspace <> "/" <> workspace_name,
    ],
    fn(path) {
      assert simplifile.is_directory(path) == Ok(False)
      assert simplifile.is_file(path) == Ok(False)
    },
  )
  let roots = [orchestrator.layout.directory, orchestrator.layout.home]
  remote_daemons.assert_absent_from(roots, remote_daemons.note_path)
  remote_daemons.assert_absent_from(roots, workspace_name)
}

// The orchestrator's own connection to the executor, seen from the executor.
// No probe is asked to dial: the orchestrator connected when the session
// opened, and a fresh probe sees it in the executor's list.
fn assert_orchestrator_connected(prepared: Fixture, keys: Credentials) -> Nil {
  let after =
    remote_daemons.probe(
      prepared.orchestrator.launcher,
      prepared.directory,
      "after",
      keys.probe,
      keys.authority,
      [Trust(keys.executor.node, keys.executor.pin)],
    )
  let both =
    list.sort([keys.orchestrator.node, keys.probe.node], string.compare)
  assert remote_daemons.run_probe(after, prepared.directory, [
      "connect " <> keys.executor.node,
      "hidden " <> keys.executor.node,
    ])
    == [
      "RESULT connect " <> keys.executor.node <> " connected",
      "RESULT hidden " <> keys.executor.node <> " " <> string.join(both, ","),
    ]
}

// Stopping the session closes the executor's scope; opening it again attaches
// at the next incarnation, where a `bash` call reads the earlier file.
fn assert_reopened(
  prepared: Fixture,
  orchestrator: Running,
  session: String,
) -> Nil {
  let control = remote_daemons.open_control(orchestrator)
  remote_daemons.stop_session(orchestrator, control, 10, session)
  assert_scope_closed(prepared, session, 1)
  let settled = remote_daemons.reopen_session(control, 20, session)
  assert remote_daemons.settled_state(settled) == "resident"
  remote_daemons.converse(orchestrator, session, remote_daemons.second_prompt, [
    remote_daemons.first_answer,
    remote_daemons.second_answer,
  ])
  remote_daemons.stop_session(orchestrator, control, 30, session)
  assert_scope_closed(prepared, session, 2)
  assert visible(prepared) == ["README.md", remote_daemons.note_path]
}

// What is in the executor's checkout apart from the executor's own housekeeping,
// which the workspace plane keeps in dot-directories (`.blobs`, `.codemode`).
fn visible(prepared: Fixture) -> List(String) {
  let assert Ok(names) = simplifile.read_directory(prepared.checkout)
    as "the executor checkout can be listed"
  names
  |> list.filter(fn(name) { !string.starts_with(name, ".") })
  |> list.sort(string.compare)
}

// The executor's own record: this incarnation's scope is closed, and every
// helper it started was proven retired.
fn assert_scope_closed(
  prepared: Fixture,
  session: String,
  incarnation: Int,
) -> Nil {
  let scope =
    remote_daemons.executor_scope(
      prepared.executor,
      prepared.directory <> "/ledger-copies",
      session,
    )
  assert scope.incarnation == incarnation
  assert scope.state == exec_ledger.Closed(exec_ledger.AllRetired)
  assert scope.workspace == workspace_name
}

// What the model was handed back for each of its calls. The provider records
// the latest message of every request, so these are the tool results as the
// transcript holds them.
fn assert_tool_results(requests: List(provider.ObservedRequest)) -> Nil {
  let note = string.trim(remote_daemons.note_content)
  let wrote = remote_daemons.result_text(requests, "write-call")
  assert string.contains(wrote, remote_daemons.note_path)
  assert string.contains(remote_daemons.result_text(requests, "cat-call"), note)
  assert string.contains(
    remote_daemons.result_text(requests, "read-call"),
    note,
  )
  assert string.contains(
    remote_daemons.result_text(requests, "again-call"),
    note,
  )
}

// --- a remote call that outlives its connection ------------------------------

// One `bash` call that takes eight seconds, appends a line to a side-effect
// file when it starts and another when it ends, and prints `finished`. The
// side-effect file is how the tests count executions: a call that ran twice
// would leave `ran` twice.
fn slow_script() -> List(provider.Exchange) {
  let command =
    "echo ran >> "
    <> ran_log
    <> "; sleep 8; echo finished; echo done >> "
    <> ran_log
  [
    provider.ToolUseExchange(
      slow_prompt,
      "slow-call",
      "bash",
      json.Object([#("command", json.String(command))]),
    ),
    provider.ComputedExchange(provider.AwaitToolResult("slow-call"), fn(_seen) {
      provider.ReplyText(slow_answer)
    }),
  ]
}

// Starts the executor and the orchestrator, opens a registered session, sends
// the prompt, and returns once the call is running on the executor: its first
// line is in the side-effect file and its last is not.
fn start_slow_call(
  prepared: Fixture,
  keys: Credentials,
  url: String,
) -> #(Running, String, process.Subject(tui_driver.Message)) {
  configure(prepared, keys, url)
  let _executor = remote_daemons.start(prepared.executor)
  let orchestrator = remote_daemons.start(prepared.orchestrator)
  let control = remote_daemons.open_control(orchestrator)
  let #(session, settled) =
    remote_daemons.create_and_settle(
      control,
      1,
      "e2e-slow",
      executor_name,
      workspace_name,
    )
  assert remote_daemons.settled_state(settled) == "resident"
  let terminal = remote_daemons.attach(orchestrator, session)
  remote_daemons.say(terminal, slow_prompt)
  let path = prepared.checkout <> "/" <> ran_log
  let assert poll.Answered(Nil) =
    poll.until(within: 30_000, every: 25, attempt: fn() {
      case simplifile.is_file(path) {
        Ok(True) -> poll.Done(Nil)
        _ -> poll.Retry
      }
    })
    as "the remote call started on the executor"
  assert ran_lines(prepared) == "ran\n"
  #(orchestrator, session, terminal)
}

fn ran_lines(prepared: Fixture) -> String {
  let assert Ok(text) = simplifile.read(prepared.checkout <> "/" <> ran_log)
    as "the side-effect file exists"
  text
}

// The call ran once and its outcome reached the model once. The side-effect
// file holds the call's two lines and no more, the model saw one result for
// the call, and the provider saw the prompt and that result and nothing else.
fn assert_ran_once(
  prepared: Fixture,
  requests: List(provider.ObservedRequest),
) -> Nil {
  assert ran_lines(prepared) == "ran\ndone\n"
  assert string.contains(
    remote_daemons.result_text(requests, "slow-call"),
    "finished",
  )
  assert list.length(requests) == 2
}

// The orchestrator dies while the call runs and is started again on the same
// state. The executor sees the connection drop, leaves the run going and keeps
// its outcome in the ledger; the reopened session finds the call interrupted
// and asks the executor for the outcome instead of running it again.
fn restart_drill(prepared: Fixture) -> Nil {
  let keys = provision(prepared)
  make_checkout(prepared)
  let #(Nil, report) =
    provider.with_server(slow_script(), fn(url) {
      let #(_first, session, terminal) = start_slow_call(prepared, keys, url)
      remote_daemons.crash(prepared.orchestrator)
      tui_driver.stop(terminal)
      let second = remote_daemons.start(prepared.orchestrator)
      let control = remote_daemons.open_control(second)
      let recovered = remote_daemons.reopen_session(control, 10, session)
      assert remote_daemons.settled_state(recovered) == "resident"
      let terminal = remote_daemons.attach(second, session)
      remote_daemons.await_answers(terminal, [slow_answer], 60_000)
    })
  let assert Ok(requests) = report
    as "the provider saw the prompt and the recovered result, nothing else"
  assert_ran_once(prepared, requests)
}

// The two daemons stay up and the distribution connection between them is
// dropped while the call runs. The orchestrator's surface notices, repairs the
// connection and sends the same call again; the executor recognises the key and
// does not start it a second time.
fn partition_drill(prepared: Fixture) -> Nil {
  let keys = provision(prepared)
  make_checkout(prepared)
  let #(Nil, report) =
    provider.with_server(slow_script(), fn(url) {
      let #(_orchestrator, _session, terminal) =
        start_slow_call(prepared, keys, url)
      let orch = keys.orchestrator.node
      let exec = keys.executor.node
      let cutter =
        remote_daemons.probe(
          prepared.orchestrator.launcher,
          prepared.directory,
          "cutter",
          keys.probe,
          keys.authority,
          [
            Trust(orch, keys.orchestrator.pin),
            Trust(exec, keys.executor.pin),
          ],
        )
      assert remote_daemons.run_probe(cutter, prepared.directory, [
          "connect " <> orch,
          "drop " <> orch <> " " <> exec,
        ])
        == [
          "RESULT connect " <> orch <> " connected",
          "RESULT drop " <> orch <> " " <> exec <> " dropped",
        ]

      // The probe ran for a second or two and the call needs eight, so the
      // connection was lost with the call still running.
      assert ran_lines(prepared) == "ran\n"
      remote_daemons.await_answers(terminal, [slow_answer], 60_000)

      // Nothing but the orchestrator's own surface can have reconnected: the
      // daemons dial no peer on their own and the probe never dialled.
      assert_orchestrator_connected(prepared, keys)
    })
  let assert Ok(requests) = report
    as "the provider saw the prompt and the call's result, nothing else"
  assert_ran_once(prepared, requests)
}
