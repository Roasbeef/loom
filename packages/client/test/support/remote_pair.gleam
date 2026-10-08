//// One orchestrator and one executor, booted for a single end-to-end test of
//// the distributed runtime (issue #697), with the parts every such test
//// repeats already assembled.
////
//// `support/remote_daemons` is the vocabulary of the shipped two-daemon
//// fixture: credentials, configuration tables, daemon start and retirement,
//// control commands and the terminal. This module is the arrangement a test
//// that boots exactly one pair reaches for, so that a test file states only
//// what it checks.
////
//// ## What one test gets
////
//// 1. `shipped` gates the test on the host (the shipment under test and a
////    jail that enforces a policy), makes a short private directory, and runs
////    the body under a deadline. Both daemons are retired by their recorded
////    identity after the body, whether it passed or not, and the directory is
////    removed only when it passed.
//// 2. `provision` mints the authority, one leaf per node and the shared
////    cookie, and `configure` writes both `loom.toml` files and their
////    distribution options. The orchestrator's models point at the scripted
////    provider; the executor's `[workspaces.repo]` row is the only place the
////    checkout's path is written.
//// 3. `open_registered` starts the executor and then the orchestrator, and
////    settles one session registered on the executor. `converse_for` and
////    `stop_and_close` drive it; `reopen` brings the stopped session back.
//// 4. `session_fact` and `session_socket` read the orchestrator's side of the
////    session: a reserved fact from its store, and the commands a client
////    sends on the session socket.
////
//// ## Why the directory is under /var/tmp
////
//// The executor binds code mode's capability socket below its state root, and
//// an AF_UNIX path has a budget of about a hundred bytes that a worktree's
//// `packages/client/build/...` spends before the socket's own name. It is
//// `/var/tmp` and not `/tmp` because the jail replaces `/tmp` with its scratch
//// tmpfs.

import broker/token
import client/codemode
import client/daemon_server_test as wire
import client/tui_e2e_test.{type EunitTest, Timeout}
import core/codec
import core/json.{type JsonValue}
import gleam/bit_array
import gleam/dynamic/decode
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap as native
import simplifile
import sqlight
import storage/exec_ledger
import support/enforcement
import support/internal/ffi_ws
import support/remote_daemons.{
  type Control, type Identity, type Layout, type Running, Trust,
}
import support/tui_driver
import tui/daemon
import weft

/// The executor's name for its checkout, and the name a session uses for it.
pub const workspace_name = "repo"

/// The orchestrator's name for the executor, an `[executors.<name>]` key.
pub const executor_name = "box"

/// How long a terminal waits for a turn to finish. A background job's wake and
/// a hook around each call add round trips a plain turn does not have.
pub const turn_ms = 120_000

/// Everything the body needs to be retired, fixed before anything starts.
pub type Pair {
  Pair(
    /// The private directory holding everything of this test.
    directory: String,
    /// The orchestrator's layout.
    orchestrator: Layout,
    /// The executor's layout.
    executor: Layout,
    /// The executor's checkout, which the orchestrator is never told about.
    checkout: String,
  )
}

/// The two nodes of the trust graph, with every credential they need.
pub type Credentials {
  Credentials(
    authority: remote_daemons.Authority,
    orchestrator: Identity,
    executor: Identity,
  )
}

/// A session that is resident on the executor, and the way to command it.
pub type Opened {
  Opened(
    /// The running orchestrator.
    orchestrator: Running,
    /// Its owner control socket.
    control: Control,
    /// The registered session.
    session: String,
  )
}

/// The body of a test: it receives the pair it should boot.
pub type Body =
  fn(Pair) -> Nil

/// The longest the body may run, in milliseconds. The fixture's own deadline,
/// so a hung body fails with a message rather than at the runner's timeout.
const body_ms = 420_000

/// The EUnit timeout, which the runner scales by ten.
const eunit_seconds = 60

/// How long the provider's callback may run: past `body_ms` would let the
/// fixture's deadline fire first and hide the provider's own report.
pub const callback_ms = 380_000

/// Gates a test on the host and runs `body` against a fresh pair.
///
/// `label` names the skip line a host without the prerequisites prints, so one
/// declaration can cover a file. `requires` lists programs the executor's
/// jailed tools run (`rg` for the search tool, `git` for a repository), and the
/// first one missing from `PATH` skips the test with a line naming it.
///
/// ## Examples
///
/// ```gleam
/// pub fn a_remote_tools_test_() -> EunitTest {
///   remote_pair.shipped("shipped remote tools", ["rg"], drive)
/// }
/// ```
pub fn shipped(label: String, requires: List(String), body: Body) -> EunitTest {
  Timeout(eunit_seconds, fn() {
    case native.getenv("LOOM_BOOTSTRAP_E2E_SERVER") {
      Error(Nil) ->
        io.println_error(
          "SKIP " <> label <> ": LOOM_BOOTSTRAP_E2E_SERVER is unset",
        )

      // The executor jails every call, so a host whose helper cannot enforce a
      // policy declines the fixture under the label and reason the other
      // shipped fixtures declare.
      Ok(server) ->
        case enforcement.probe(server, label) {
          enforcement.EnforcementAbsent -> Nil
          enforcement.EnforcementLive ->
            case list.find(requires, missing) {
              Ok(program) ->
                io.println_error(
                  "SKIP " <> label <> ": " <> program <> " is not on PATH",
                )
              Error(Nil) -> fixture(label, body)
            }
        }
    }
  })
}

fn missing(program: String) -> Bool {
  result.is_error(native.find_executable(program))
}

fn fixture(label: String, body: Body) -> Nil {
  let directory =
    "/var/tmp/loom-rt-"
    <> string.lowercase(bit_array.base16_encode(token.production_entropy()(4)))
  let assert Ok(Nil) = native.ensure_private_directory(directory)
    as "the fixture's state stays private"
  let assert Ok(directory) = native.canonical_directory(directory)
    as "the daemons receive absolute paths"
  let prepared =
    Pair(
      directory:,
      orchestrator: remote_daemons.layout(directory, "orchestrator"),
      executor: remote_daemons.layout(directory, "executor"),
      checkout: directory <> "/executor-checkout",
    )
  io.println_error(label <> " fixture: " <> directory)
  let outcomes =
    weft.new([
      fn() {
        body(prepared)
        Ok(Nil)
      },
    ])
    |> weft.deadline(body_ms)
    |> weft.start

  // Native cleanup runs outside the body's deadline and before the outcome is
  // read, so a body that failed mid-drive still retires every daemon.
  list.each([prepared.orchestrator, prepared.executor], fn(l) {
    remote_daemons.retire(l.paths)
  })
  let assert [weft.Completed(0, Nil)] = outcomes
    as "the shipped remote body completes before native teardown"
  let _removed = simplifile.delete_all([prepared.directory])
  Nil
}

/// Mints the credentials of the pair and the cookie both nodes share.
///
/// ## Examples
///
/// ```gleam
/// // let keys = remote_pair.provision(pair)
/// ```
pub fn provision(prepared: Pair) -> Credentials {
  let secrets = prepared.directory <> "/credentials"
  let assert Ok(Nil) = native.ensure_private_directory(secrets)
    as "the credentials directory is private"
  let authority = remote_daemons.mint_authority(secrets)
  let suffix = remote_daemons.random_hex(4)
  let name = fn(role) { "loom_e2e_" <> role <> "_" <> suffix <> "@127.0.0.1" }
  let keys =
    Credentials(
      authority:,
      orchestrator: remote_daemons.issue(
        authority,
        secrets,
        "orchestrator",
        name("orch"),
        prepared.orchestrator.home,
      ),
      executor: remote_daemons.issue(
        authority,
        secrets,
        "executor",
        name("exec"),
        prepared.executor.home,
      ),
    )

  // One cookie for the whole cluster. Each VM reads it from its own home.
  let cookie = "loom-e2e-cookie-" <> remote_daemons.random_hex(16)
  list.each([keys.orchestrator, keys.executor], fn(identity) {
    remote_daemons.write_cookie(identity, cookie)
  })
  keys
}

/// What a test adds to the two `loom.toml` files beyond the common tables.
pub type Tables {
  Tables(
    /// The `[models]` and `[roles]` tables of the orchestrator, rendered by
    /// `models` for the provider's URL.
    models: String,
    /// Further tables of the orchestrator's file.
    orchestrator: String,
    /// Further tables of the executor's file, where machine configuration
    /// such as a language server lives.
    executor: String,
  )
}

/// The orchestrator's models for a scripted provider at `url`, with a second
/// scripted provider serving the advisor role when `advisor_url` is given.
///
/// ## Examples
///
/// ```gleam
/// // remote_pair.models(url, None)
/// ```
pub fn models(url: String, advisor_url: Option(String)) -> String {
  case advisor_url {
    None -> remote_daemons.model_table(url)
    Some(advisor) ->
      "[models.fixture]\ndialect = \"anthropic\"\napi_key_env = \"LOOM_TEST_PROVIDER_KEY\"\nbase_url = \""
      <> url
      <> "\"\nmodel_id = \"fixture\"\ncontext_window = 100000\nmax_output_tokens = 4096\n"
      <> "[models.adviser]\ndialect = \"anthropic\"\napi_key_env = \"LOOM_TEST_PROVIDER_KEY\"\nbase_url = \""
      <> advisor
      <> "\"\nmodel_id = \"fixture\"\ncontext_window = 100000\nmax_output_tokens = 4096\n"
      <> "[roles]\nmain = [\"fixture\"]\nadvisor = [\"adviser\"]\n[memory]\ndistill = \"off\"\n"
  }
}

/// The orchestrator's models for a scripted provider at `url`, with the
/// summarizing role routed to a model on a closed port.
///
/// A session with a child strand runs the glance loop, which asks the
/// `summarize` role for a one-line title of the child. Unrouted, that request
/// falls back to the main model and so reaches the scripted provider, whose
/// next step it is not. Routing the role to a port nothing listens on makes
/// every glance fail where the loop expects failure, logs it at warning level
/// and backs off. The child's own turns and the title are unrelated, so the
/// script lists only the conversation the test is about.
///
/// ## Examples
///
/// ```gleam
/// // remote_pair.models_without_glance(url)
/// ```
pub fn models_without_glance(url: String) -> String {
  "[models.fixture]\ndialect = \"anthropic\"\napi_key_env = \"LOOM_TEST_PROVIDER_KEY\"\nbase_url = \""
  <> url
  <> "\"\nmodel_id = \"fixture\"\ncontext_window = 100000\nmax_output_tokens = 4096\n"
  <> "[models.sink]\ndialect = \"anthropic\"\napi_key_env = \"LOOM_TEST_PROVIDER_KEY\"\nbase_url = \"http://127.0.0.1:9\"\nmodel_id = \"fixture\"\ncontext_window = 100000\nmax_output_tokens = 4096\n"
  <> "[roles]\nmain = [\"fixture\"]\nsummarize = [\"sink\"]\n[memory]\ndistill = \"off\"\n"
}

/// Tables with the orchestrator's models for `url` and nothing else.
///
/// ## Examples
///
/// ```gleam
/// // remote_pair.plain(url)
/// ```
pub fn plain(url: String) -> Tables {
  Tables(models: models(url, None), orchestrator: "", executor: "")
}

/// Writes both daemons' configuration and distribution options.
///
/// ## Examples
///
/// ```gleam
/// // remote_pair.configure(pair, keys, remote_pair.plain(url))
/// ```
pub fn configure(prepared: Pair, keys: Credentials, tables: Tables) -> Nil {
  configure_trusting(prepared, keys, tables, [])
}

/// Writes both daemons' configuration as `configure` does, with each daemon
/// also pinning every identity in `others`.
///
/// A test that asks the cluster a question from outside, or cuts a link, adds
/// the probe's identity here. The probe holds full privileges over any node
/// that lists it, so the pin appears only in the files of this fixture's own
/// directory.
///
/// ## Examples
///
/// ```gleam
/// // remote_pair.configure_trusting(pair, keys, remote_pair.plain(url), [probe])
/// ```
pub fn configure_trusting(
  prepared: Pair,
  keys: Credentials,
  tables: Tables,
  others: List(Identity),
) -> Nil {
  // The executor refuses to start when a registered root is not a directory,
  // so the checkout exists before the first daemon does.
  let assert Ok(Nil) = simplifile.create_directory_all(prepared.checkout)
    as "the executor checkout is created"
  let write = fn(layout: Layout, text) {
    let assert Ok(Nil) = simplifile.write(layout.config, text)
      as "the daemon configuration is written"
    remote_daemons.write_options(layout)
  }
  let also = list.map(others, fn(each) { Trust(each.node, each.pin) })
  write(
    prepared.executor,
    string.join(
      [
        remote_daemons.model_table("http://127.0.0.1:9"),
        remote_daemons.distribution_table(keys.executor, keys.authority, [
          Trust(keys.orchestrator.node, keys.orchestrator.pin),
          ..also
        ]),
        remote_daemons.workspace_table(workspace_name, prepared.checkout),
        tables.executor,
      ],
      "\n",
    ),
  )
  write(
    prepared.orchestrator,
    string.join(
      [
        tables.models,
        remote_daemons.distribution_table(keys.orchestrator, keys.authority, [
          Trust(keys.executor.node, keys.executor.pin),
          ..also
        ]),
        remote_daemons.executor_table(executor_name, keys.executor.node),
        tables.orchestrator,
      ],
      "\n",
    ),
  )
}

/// Issues the probe's credentials: a third node, with a home of its own and the
/// cluster's cookie, that `drop_link` boots as a throwaway emulator.
///
/// The identity is for `configure_trusting`. Both daemons must list it before
/// they start, because they read their peers once at boot.
///
/// ## Examples
///
/// ```gleam
/// // let probe = remote_pair.probe_identity(pair, keys)
/// ```
pub fn probe_identity(prepared: Pair, keys: Credentials) -> Identity {
  let home = prepared.directory <> "/probe-home"
  let assert Ok(Nil) = native.ensure_private_directory(home)
    as "the probe has a home of its own"
  let identity =
    remote_daemons.issue(
      keys.authority,
      prepared.directory <> "/credentials",
      "probe",
      "loom_e2e_probe_" <> remote_daemons.random_hex(4) <> "@127.0.0.1",
      home,
    )
  let assert Ok(cookie) =
    simplifile.read(keys.orchestrator.home <> "/.erlang.cookie")
    as "the orchestrator's cookie is readable"
  remote_daemons.write_cookie(identity, cookie)
  identity
}

/// Has the orchestrator drop its distribution connection to the executor, and
/// asserts that it held one.
///
/// Both daemons stay up and neither chose the partition. Each side sees the
/// other's processes go down with `noconnection`. The probe boots, connects to
/// the orchestrator, runs `erlang:disconnect_node` there and ends, which takes a
/// second or two, so a call that runs longer than that is cut in flight. The
/// orchestrator's session surface repairs the connection by itself afterwards.
///
/// ## Examples
///
/// ```gleam
/// // remote_pair.drop_link(pair, keys, probe)
/// ```
pub fn drop_link(prepared: Pair, keys: Credentials, probe: Identity) -> Nil {
  let orch = keys.orchestrator.node
  let exec = keys.executor.node
  let cutter =
    remote_daemons.probe(
      prepared.orchestrator.launcher,
      prepared.directory,
      "cutter",
      probe,
      keys.authority,
      [Trust(orch, keys.orchestrator.pin), Trust(exec, keys.executor.pin)],
    )
  assert remote_daemons.run_probe(cutter, prepared.directory, [
      "connect " <> orch,
      "drop " <> orch <> " " <> exec,
    ])
    == [
      "RESULT connect " <> orch <> " connected",
      "RESULT drop " <> orch <> " " <> exec <> " dropped",
    ]
}

/// Writes files into the executor's checkout, creating their directories.
///
/// ## Examples
///
/// ```gleam
/// // remote_pair.write_files(pair.checkout, [#("README.md", "hi\n")])
/// ```
pub fn write_files(root: String, files: List(#(String, String))) -> Nil {
  list.each(files, fn(file) {
    let path = root <> "/" <> file.0
    let assert Ok(Nil) = simplifile.create_directory_all(parent(path))
      as "the file's directory is created"
    let assert Ok(Nil) = simplifile.write(path, file.1) as "the file is written"
    Nil
  })
}

fn parent(path: String) -> String {
  let segments = string.split(path, "/")
  segments
  |> list.take(list.length(segments) - 1)
  |> string.join("/")
}

/// The text of a file under `root`, asserting it exists.
///
/// ## Examples
///
/// ```gleam
/// // remote_pair.read_file(pair.checkout, "marker")
/// ```
pub fn read_file(root: String, path: String) -> String {
  let assert Ok(text) = simplifile.read(root <> "/" <> path)
    as { "the file exists: " <> path }
  text
}

/// Starts the executor and then the orchestrator, and settles one session
/// registered on the executor. The executor starts first so that the daemon
/// that dials it finds it up.
///
/// ## Examples
///
/// ```gleam
/// // let opened = remote_pair.open_registered(pair, [], "e2e-tools")
/// ```
pub fn open_registered(
  prepared: Pair,
  executor_flags: List(String),
  key: String,
) -> Opened {
  let _executor = remote_daemons.start_with(prepared.executor, executor_flags)
  let orchestrator = remote_daemons.start(prepared.orchestrator)
  let control = remote_daemons.open_control(orchestrator)
  let #(session, settled) =
    remote_daemons.create_and_settle(
      control,
      1,
      key,
      executor_name,
      workspace_name,
    )
  assert remote_daemons.settled_state(settled) == "resident"
  Opened(orchestrator:, control:, session:)
}

/// Registers a second session on the executor beside `first`, on the same
/// orchestrator and control socket.
///
/// `id` is the first control command id the creation may use. The control
/// protocol wants ids that grow, and a settling wait spends one per poll, so a
/// caller passes a number well past any id it has used.
///
/// ## Examples
///
/// ```gleam
/// // let second = remote_pair.register_another(first, 1000, "e2e-second")
/// ```
pub fn register_another(first: Opened, id: Int, key: String) -> Opened {
  let #(session, settled) =
    remote_daemons.create_and_settle(
      first.control,
      id,
      key,
      executor_name,
      workspace_name,
    )
  assert remote_daemons.settled_state(settled) == "resident"
  Opened(..first, session:)
}

/// Opens the stopped session again and asserts it is resident.
///
/// ## Examples
///
/// ```gleam
/// // remote_pair.reopen(opened, 2000)
/// ```
pub fn reopen(opened: Opened, id: Int) -> Nil {
  let settled =
    remote_daemons.reopen_session(opened.control, id, opened.session)
  assert remote_daemons.settled_state(settled) == "resident"
}

/// Sends one prompt and waits until the assistant's final texts are exactly
/// `answers`, oldest first.
///
/// A reopened session replays its whole transcript, so `answers` lists every
/// final text the session has produced so far.
///
/// ## Examples
///
/// ```gleam
/// // remote_pair.converse_for(opened, "do it", ["done"])
/// ```
pub fn converse_for(
  opened: Opened,
  prompt: String,
  answers: List(String),
) -> Nil {
  let terminal = remote_daemons.attach(opened.orchestrator, opened.session)
  remote_daemons.say(terminal, prompt)
  remote_daemons.await_answers(terminal, answers, turn_ms)
  tui_driver.stop(terminal)
}

/// Waits, with no prompt, until the assistant's final texts are exactly
/// `answers`. A run that a background job's end started is not preceded by any
/// prompt the test sends.
///
/// ## Examples
///
/// ```gleam
/// // remote_pair.await_answers(opened, ["started", "polled"])
/// ```
pub fn await_answers(opened: Opened, answers: List(String)) -> Nil {
  let terminal = remote_daemons.attach(opened.orchestrator, opened.session)
  remote_daemons.await_answers(terminal, answers, turn_ms)
  tui_driver.stop(terminal)
}

/// Stops the session and reads how the executor closed its scope at
/// `incarnation`.
///
/// ## Examples
///
/// ```gleam
/// // remote_pair.stop_and_close(pair, opened, 1)
/// ```
pub fn stop_and_close(prepared: Pair, opened: Opened, incarnation: Int) -> Nil {
  remote_daemons.stop_session(
    opened.orchestrator,
    opened.control,
    100 + incarnation * 10,
    opened.session,
  )
  let scope =
    remote_daemons.executor_scope(
      prepared.executor,
      prepared.directory <> "/ledger-copies",
      opened.session,
    )
  assert scope.incarnation == incarnation
  assert scope.state == exec_ledger.Closed(exec_ledger.AllRetired)
  assert scope.workspace == workspace_name
}

/// Closes the owner connections the test opened.
///
/// ## Examples
///
/// ```gleam
/// // remote_pair.close_daemons([opened.orchestrator])
/// ```
pub fn close_daemons(running: List(Running)) -> Nil {
  list.each(running, fn(each) { daemon.close(each.connected.control) })
}

/// The build seed code mode compiles against, or the first thing the host
/// lacks.
///
/// The seed is what `make codemode-seed` prepares at the repository root, two
/// levels above the package the tests run in. A test that runs a `code_mode`
/// program on the executor hands the path to the executor with
/// `--codemode-seed`, as an operator would, and prints a skip line naming the
/// reason when this answers an error, because a host without a toolchain
/// proves nothing about that route.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(seed) = remote_pair.code_mode_seed()
/// // remote_pair.open_registered(pair, ["--codemode-seed", seed], "e2e-program")
/// ```
pub fn code_mode_seed() -> Result(String, String) {
  use seed <- result.try(
    native.canonical_directory("../../build/codemode-seed")
    |> result.replace_error(
      "no seed at build/codemode-seed (run make codemode-seed)",
    ),
  )
  use _toolchain <- result.try(codemode.discover(seed))
  Ok(seed)
}

// --- the orchestrator's side of the session --------------------------------

/// A reserved fact of the session, read from a copy of the orchestrator's
/// store.
///
/// The orchestrator keeps running, so the store is read from a copy of the file
/// and its write-ahead log in the pair's own directory, never from the live
/// one. The copy is taken when the session is quiet, which is when a test asks
/// what the orchestrator recorded.
///
/// ## Examples
///
/// ```gleam
/// // remote_pair.session_fact(pair, session, "session/git-start")
/// ```
pub fn session_fact(
  prepared: Pair,
  session: String,
  key: String,
) -> Option(JsonValue) {
  let source =
    prepared.orchestrator.paths.root <> "/sessions/" <> session <> ".db"
  let scratch = prepared.directory <> "/store-copies"
  let assert Ok(Nil) = simplifile.create_directory_all(scratch)
    as "the store copy has a directory"
  let copy = scratch <> "/" <> remote_daemons.random_hex(4) <> ".db"
  list.each(["", "-wal", "-shm"], fn(suffix) {
    case simplifile.is_file(source <> suffix) {
      Ok(True) -> {
        let assert Ok(Nil) =
          simplifile.copy_file(source <> suffix, copy <> suffix)
          as "the store file is copied"
        Nil
      }
      _ -> Nil
    }
  })
  let assert Ok(connection) = sqlight.open(copy) as "the copied store opens"
  let cell = {
    use blob <- decode.field(0, decode.bit_array)
    decode.success(blob)
  }
  let assert Ok(rows) =
    sqlight.query(
      "SELECT value FROM registers WHERE ns = 'fact.custom' AND key = ?1",
      on: connection,
      with: [sqlight.text(key)],
      expecting: cell,
    )
    as "the register table answers"
  let assert Ok(Nil) = sqlight.close(connection) as "the copy closes"
  case rows {
    [] -> None
    [blob, ..] -> {
      let assert Ok(text) = bit_array.to_string(blob)
        as "a register payload is text"
      let assert Ok(parsed) = json.parse(text) as "a register payload is JSON"
      let assert Ok(value) = codec.decode_register_value(parsed)
        as "a register payload is a register value"
      Some(value.payload)
    }
  }
}

/// An authenticated socket on the session, past its `subscribe`.
pub type SessionSocket {
  SessionSocket(socket: ffi_ws.Socket, next_id: Int)
}

/// Opens the owner's socket on `session` and subscribes.
///
/// ## Examples
///
/// ```gleam
/// // let socket = remote_pair.session_socket(opened)
/// ```
pub fn session_socket(opened: Opened) -> SessionSocket {
  let #(socket, response) =
    wire.connect(
      opened.orchestrator.port,
      opened.orchestrator.owner,
      "/v2/sessions/" <> opened.session <> "/ws",
    )
  assert string.contains(response, "101 Switching Protocols")
  let begun = wire.subscribe(socket, 1, opened.session, within_ms: 15_000)
  assert remote_daemons.field(begun, "event") == json.String("snapshot_begin")
  SessionSocket(socket:, next_id: 2)
}

/// One command on the session socket and its correlated reply, with the
/// socket to use for the next.
///
/// ## Examples
///
/// ```gleam
/// // let #(reply, socket) = remote_pair.session_command(socket, "goal_get", json.Object([]))
/// ```
pub fn session_command(
  session: SessionSocket,
  name: String,
  body: JsonValue,
) -> #(JsonValue, SessionSocket) {
  let reply =
    wire.reply(session.socket, session.next_id, name, body, within_ms: 15_000)
  #(reply, SessionSocket(..session, next_id: session.next_id + 1))
}

/// The next frame the daemon sends on the session socket, whatever it is.
///
/// A worktree observation answers its command with a pending board and pushes
/// the finished one later, so a test that waits for it reads frames.
///
/// ## Examples
///
/// ```gleam
/// // let pushed = remote_pair.next_frame(socket)
/// ```
pub fn next_frame(session: SessionSocket) -> JsonValue {
  wire.frame(session.socket, within_ms: 15_000)
}

/// The text of the request, for an assertion that a string reached the model.
///
/// The whole request body is rendered as JSON, so a substring of any message,
/// system block or tool result is found.
///
/// ## Examples
///
/// ```gleam
/// // remote_pair.request_text(request)
/// ```
pub fn request_text(body: JsonValue) -> String {
  json.to_string(body)
}
