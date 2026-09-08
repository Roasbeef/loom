//// The daemon's own credentials are out of reach of a jailed tool in a
//// shipped session. The self-test probe proves that of a policy the
//// helper is handed directly; this fixture proves it of the policy the
//// shipped daemon actually builds, through the shipped `bash` tool, on a
//// state root the daemon canonicalized itself.
////
//// Two workspaces and two sessions. B is created first so that its
//// conversation database exists under `state/sessions/` before A runs
//// anything; A is the session whose tool calls do the reading. Four
//// foreground `bash` calls: the owner token, the catalogue, B's database,
//// and one positive that writes a marker inside A's own workspace and
//// reads it back.
////
//// ## Why the assertions are about the secret rather than the error
////
//// A masked path does not refuse the same way on both platforms. On Linux
//// a protected *file* is bound to `/dev/null`, so `cat owner.token`
//// succeeds and yields zero bytes, while a protected *directory* becomes a
//// read-only tmpfs, so `state/sessions/<id>.db` is ENOENT. On Darwin all
//// three are `deny file-read*`, which is EPERM. A fixture asserting "the
//// read failed" would fail against a correct Linux jail, and one asserting
//// "the output was empty" would fail against a correct Darwin jail. So each
//// negative asserts that the secret did not come out: the token's own bytes,
//// which the harness reads from outside the jail, and the SQLite file header
//// that every readable conversation database begins with.
////
//// ## Why the host-side pre-assertion exists
////
//// If the state root's layout moved, all three reads would fail for the
//// wrong reason and the fixture would pass having proved nothing. So it
//// checks from outside the jail that all three files exist before the
//// negatives run, and fails as "path absent on host" when one does not.
////
//// ## Why the whole fixture is gated on measured enforcement
////
//// On a host whose helper cannot enforce a policy the reads succeed, and
//// that is not a weaker test but a different one. The file declines with
//// the same measured verdict `support/enforcement` gives the other shipped
//// fixtures.

import broker/token
import client/tui_e2e_test.{type EunitTest, Timeout}
import client/tui_v2_test
import core/entry
import core/json
import core/message
import etui/backend
import gleam/bit_array
import gleam/erlang/process
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import host/bootstrap as native
import host/endpoint
import simplifile
import support/enforcement
import support/provider_http as provider
import support/tui_driver
import tui/bootstrap
import tui/daemon
import tui/daemon/selection
import tui/session_channel
import tui/workspace
import weft
import weft/actor
import weft/poll

/// The label the enforcement skip is printed under, so one declaration
/// covers the file wherever a census reads its output.
const live_label = "shipped confinement"

/// The first bytes of every SQLite database file. Its absence from a tool's
/// output is what says the database did not come out; asserting on an error
/// code instead would be wrong on one platform or the other.
const sqlite_header = "SQLite format 3"

/// Where each command's own exit status is written in its output, so a
/// refusal and an empty read can be told apart without the tool result
/// having to be an error result.
const status_marker = "|status="

/// What the positive call writes and reads back inside A's workspace.
const owned_file = "owned.txt"

/// Proves the daemon's credentials are unreachable from a jailed tool in a
/// shipped session, and that the same tool still reads its own workspace.
///
/// ## Examples
///
/// `scripts/test.sh client --match daemon_shipped_confinement`.
pub fn daemon_shipped_confinement_test_() -> EunitTest {
  // The runner scales this EUnit timeout by ten. The 60-second body and its
  // independent native cleanup stay inside the resulting 90 seconds.
  Timeout(9, fn() {
    case prerequisites() {
      None -> Nil
      Some(server) -> fixture(server)
    }
  })
}

// Both prerequisites are environmental. An absent shipment means the suite
// was asked to test something nobody built, and an absent enforcement layer
// means this host cannot confine a jailed command at all.
fn prerequisites() -> Option(String) {
  case native.getenv("LOOM_BOOTSTRAP_E2E_SERVER") {
    Error(Nil) -> {
      io.println_error(
        "SKIP shipped confinement: LOOM_BOOTSTRAP_E2E_SERVER is unset",
      )
      None
    }

    Ok(server) -> {
      assert native.getenv("LOOM_TEST_PROVIDER_KEY") == Ok(provider.dummy_key)
      case enforcement.probe(server, live_label) {
        enforcement.EnforcementAbsent -> None
        enforcement.EnforcementLive -> Some(server)
      }
    }
  }
}

fn fixture(server: String) -> Nil {
  let directory = private_root()
  let assert Ok(paths) = endpoint.paths(directory <> "/state")
    as "cleanup retains its endpoint before launch"
  io.println_error("shipped confinement fixture: " <> directory)
  let outcomes =
    weft.new([
      fn() {
        exercise(server, directory, paths)
        Ok(Nil)
      },
    ])
    |> weft.deadline(60_000)
    |> weft.start

  // Native cleanup runs outside the body's deadline and before the outcome
  // is read, so a body that failed mid-drive still retires its VM.
  retire_native(paths)
  let assert [weft.Completed(0, Nil)] = outcomes
    as "the shipped confinement body completes without crashing or timing out"
  Nil
}

fn private_root() -> String {
  let directory =
    "build/shipped-confinement-"
    <> bit_array.base16_encode(token.production_entropy()(16))
  let assert Ok(Nil) = native.ensure_private_directory(directory)
    as "the native fixture has private state"
  let assert Ok(directory) = native.canonical_directory(directory)
    as "the fixture uses canonical paths"
  directory
}

// The daemon boots before the provider does, because the script names B's
// database by path and B's identity is minted by the running daemon. The
// configuration is rewritten with the real provider address once the script
// exists, and A registers against the rewritten file.
fn exercise(server: String, directory: String, paths: endpoint.Paths) -> Nil {
  let workspaces = prepare(directory)
  let connected = connect(server, directory, workspaces.b, paths)
  let config = config_of(directory)

  // B is created before A exists so that its conversation database is
  // already under `state/sessions/` when A's jailed tool reaches for it.
  let targets =
    targets_of(paths, create(connected, "confinement-b", workspaces.b, config))
  let secret = witnessed_token(paths)
  let #(Nil, report) =
    provider.with_server(script(targets, workspaces.marker), fn(url) {
      drive(connected, directory, workspaces.a, url)
    })
  let assert Ok(requests) = report
    as "only the eight scripted provider requests occur"
  assert_evidence(requests, secret, workspaces.marker)
  daemon.close(connected.control)
}

// The two workspaces and the marker the positive call proves itself with.
// The marker is minted per run so a stale file from an earlier fixture in
// the same checkout could not satisfy the positive.
type Workspaces {
  Workspaces(a: String, b: String, marker: String)
}

fn prepare(directory: String) -> Workspaces {
  let a = directory <> "/a"
  let b = directory <> "/b"
  assert simplifile.create_directory_all(a) == Ok(Nil)
  assert simplifile.create_directory_all(b) == Ok(Nil)

  // Nothing reaches this address. B is created before the provider exists
  // and never takes a model turn, so its configuration only has to parse.
  assert simplifile.write(
      config_of(directory),
      configuration("http://127.0.0.1:1/unused"),
    )
    == Ok(Nil)
  let marker = bit_array.base16_encode(token.production_entropy()(8))
  Workspaces(a, b, marker)
}

/// The three daemon-owned paths A's tool calls attempt, each of which has
/// been witnessed on the host before any of them is attempted.
type Targets {
  Targets(owner_token: String, catalogue: String, session: String)
}

// `endpoint.paths` is the same module the daemon derives its own layout
// from, so the token and catalogue names are read rather than spelled here.
// The session database is `<sessions>/<id>.db`, which is how the manager
// builds it, and the host-side existence check below is what makes a moved
// layout a loud failure rather than a vacuous pass.
fn targets_of(paths: endpoint.Paths, session: String) -> Targets {
  let targets =
    Targets(
      owner_token: paths.token,
      catalogue: paths.catalogue,
      session: paths.root <> "/sessions/" <> session <> ".db",
    )
  present(targets.owner_token)
  present(targets.catalogue)
  present(targets.session)
  targets
}

fn present(path: String) -> Nil {
  let assert Ok(True) = simplifile.is_file(path)
    as { "path absent on host: " <> path }
  Nil
}

// Read from outside the jail, which is the only place it can be read. This
// is the value the negative asserts did not come back out of one.
fn witnessed_token(paths: endpoint.Paths) -> String {
  let assert Ok(secret) = simplifile.read(paths.token)
    as "the fixture owner reads its private credential from the host"
  let secret = string.trim(secret)
  assert secret != "" as "the owner credential is not empty"
  secret
}

// --- what the model is scripted to do ---------------------------------------

// Every command ends in an `echo`, so the tool result is a success whatever
// the read did, and the read's own status travels in the text instead. A
// non-zero exit would render as an error result, which the script's
// `AwaitToolResult` steps do not match: the refusal being measured would
// then look like a broken script.
fn reading(path: String) -> String {
  "cat -- '" <> path <> "' 2>&1; echo \"" <> status_marker <> "$?\""
}

// Fifteen bytes is the SQLite header exactly, which keeps a database's
// arbitrary binary content out of the tool's output entirely: what comes
// back is either that ASCII header or nothing worth decoding.
fn header_reading(path: String) -> String {
  "head -c 15 -- '" <> path <> "' 2>&1; echo \"" <> status_marker <> "$?\""
}

fn owned_reading(marker: String) -> String {
  "printf '%s' '"
  <> marker
  <> "' > "
  <> owned_file
  <> "; cat -- "
  <> owned_file
  <> " 2>&1; echo \""
  <> status_marker
  <> "$?\""
}

fn command(text: String) -> json.JsonValue {
  json.Object([#("command", json.String(text))])
}

fn script(targets: Targets, marker: String) -> List(provider.Exchange) {
  [
    call("own the workspace", "owned-call", owned_reading(marker)),
    answered("owned-call", "owned"),
    call("read the token", "token-call", reading(targets.owner_token)),
    answered("token-call", "token"),
    call(
      "read the catalogue",
      "catalogue-call",
      header_reading(targets.catalogue),
    ),
    answered("catalogue-call", "catalogue"),
    call(
      "read the other session",
      "session-call",
      header_reading(targets.session),
    ),
    answered("session-call", "session"),
  ]
}

fn call(prompt: String, call_id: String, text: String) -> provider.Exchange {
  provider.ToolUseExchange(prompt, call_id, "bash", command(text))
}

// A tool result whose text the fixture cannot predict, answered with a
// fixed word so the transcript the driver waits on stays exact.
fn answered(call_id: String, text: String) -> provider.Exchange {
  provider.ComputedExchange(provider.AwaitToolResult(call_id), fn(_seen) {
    provider.ReplyText(text)
  })
}

// --- driving A --------------------------------------------------------------

fn drive(
  connected: Connected,
  directory: String,
  workspace: String,
  url: String,
) -> Nil {
  let config = config_of(directory)
  assert simplifile.write(config, configuration(url)) == Ok(Nil)
  let session = attach(connected, "confinement-a", workspace, config)
  ask(session, "own the workspace", ["owned"])
  ask(session, "read the token", ["token", "owned"])
  ask(session, "read the catalogue", ["catalogue", "token", "owned"])
  ask(session, "read the other session", [
    "session", "catalogue", "token", "owned",
  ])
  stop_driver(session)
}

// One turn: the prompt, then the barrier on every answer the transcript
// carries, newest first. Waiting on the settled answers rather than on a
// message count keeps the barrier honest across turns that carry a call.
fn ask(
  session: actor.Started(process.Subject(tui_driver.Message)),
  prompt: String,
  answers: List(String),
) -> Nil {
  let _ =
    tui_driver.play(session.data, [
      backend.Paste(prompt),
      backend.KeyPress("enter"),
    ])
  let _ =
    tui_v2_test.await(session.data, fn(sample) {
      writable(sample)
      && assistant_texts(sample) == answers
      && sample.model.streams == []
      && list.any(sample.model.strands, fn(strand) {
        strand.id == "main" && strand.live_phase == None
      })
    })
  Nil
}

// --- what the model was shown -----------------------------------------------

// The provider's evidence is where the exact bytes the model was given
// live, so every assertion is made against it rather than against a
// rendered terminal.
fn assert_evidence(
  requests: List(provider.ObservedRequest),
  secret: String,
  marker: String,
) -> Nil {
  let assert [
    provider.ObservedRequest(
      latest: provider.UserPrompt("own the workspace"),
      ..,
    ),
    provider.ObservedRequest(
      latest: provider.SuccessfulToolResult("owned-call", owned),
      ..,
    ),
    provider.ObservedRequest(latest: provider.UserPrompt("read the token"), ..),
    provider.ObservedRequest(
      latest: provider.SuccessfulToolResult("token-call", token),
      ..,
    ),
    provider.ObservedRequest(
      latest: provider.UserPrompt("read the catalogue"),
      ..,
    ),
    provider.ObservedRequest(
      latest: provider.SuccessfulToolResult("catalogue-call", catalogue),
      ..,
    ),
    provider.ObservedRequest(
      latest: provider.UserPrompt("read the other session"),
      ..,
    ),
    provider.ObservedRequest(
      latest: provider.SuccessfulToolResult("session-call", session),
      ..,
    ),
  ] = requests
    as "the eight scripted requests occur in their scripted order"
  assert_owned(owned, marker)
  assert_token(token, secret)
  assert_masked(catalogue)
  assert_absent(session)
}

// The positive. A jail that ran nothing, or that could not write the
// workspace, fails here rather than passing the three negatives for free.
fn assert_owned(text: String, marker: String) -> Nil {
  let #(payload, status) = parts(text)
  assert payload == marker
  assert status == "0"
}

// Zero bytes on Linux, where the file is bound to `/dev/null`; a refusal on
// Darwin, where it is denied. Neither is asserted: what is asserted is that
// the credential the harness holds did not appear in what the model saw.
fn assert_token(text: String, secret: String) -> Nil {
  let #(payload, _status) = parts(text)
  assert !string.contains(payload, secret)
}

// The same reading for the catalogue: whatever the platform did, the file's
// own header did not reach the model, so neither did the database.
fn assert_masked(text: String) -> Nil {
  let #(payload, _status) = parts(text)
  assert !string.contains(payload, sqlite_header)
}

// B's database sits under a masked *directory*, which is a read-only tmpfs
// on Linux and a denial on Darwin, so unlike the two files it is never
// merely empty: the open itself has to have failed, or produced nothing.
fn assert_absent(text: String) -> Nil {
  let #(payload, status) = parts(text)
  assert !string.contains(payload, sqlite_header)
  assert status != "0" || payload == ""
}

// Every command's output ends in the status line the command itself wrote,
// so the read's own bytes and its exit status are separable without the
// tool result having had to be an error.
fn parts(text: String) -> #(String, String) {
  let assert Ok(#(payload, status)) = string.split_once(text, on: status_marker)
    as "each scripted command reports its own exit status"
  #(string.trim(payload), string.trim(status))
}

// --- sessions ---------------------------------------------------------------

// An authenticated VM with no attachment yet. One connection here carries
// both sessions and outlives every driver bound to it.
type Connected {
  Connected(control: daemon.Connection, address: String, owner: String)
}

fn config_of(directory: String) -> String {
  directory <> "/fixture.toml"
}

fn configuration(url: String) -> String {
  "[models.fixture]\ndialect = \"anthropic\"\napi_key_env = \"LOOM_TEST_PROVIDER_KEY\"\nbase_url = \""
  <> url
  <> "\"\nmodel_id = \"fixture\"\ncontext_window = 100000\nmax_output_tokens = 4096\n[roles]\nmain = [\"fixture\"]\n[memory]\ndistill = \"off\"\n"
}

fn connect(
  server: String,
  directory: String,
  workspace: String,
  paths: endpoint.Paths,
) -> Connected {
  let assert Ok(connected) =
    bootstrap.resolve_daemon(
      bootstrap.Options(workspace, "", server, paths.root, config_of(directory)),
      process.self(),
      40_000,
    )
    as "ordinary bootstrap starts and authenticates the shipped daemon"
  let assert Ok(address) = endpoint.address(connected.record)
    as "the native endpoint is ready"
  let assert Ok(secret) = simplifile.read(connected.paths.token)
    as "the fixture owner reads its private credential"
  Connected(connected.control, address, string.trim(secret))
}

// Explicit durable creation, which is what initializes a session's store.
// B is created and never attached: its database is the whole reason it
// exists here, and a session with no terminal still owns one.
fn create(
  connected: Connected,
  key: String,
  directory: String,
  config: String,
) -> String {
  let assert Ok(host) =
    selection.host(connected.control, connected.address, connected.owner)
    as "the owner has an authenticated selector"
  let assert Ok(created) =
    selection.create_named(
      host,
      key,
      directory,
      workspace.session_name(workspace.Context(directory, None)),
      config,
    )
    as "the session is explicitly created"
  created.expected.session
}

fn attach(
  connected: Connected,
  key: String,
  directory: String,
  config: String,
) -> actor.Started(process.Subject(tui_driver.Message)) {
  let session = create(connected, key, directory, config)
  let assert Ok(started) =
    tui_driver.start(connected.address, connected.owner, session)
    as "the fixture attaches over the actual session socket"
  let _ = tui_v2_test.await(started.data, writable)
  started
}

// --- reading the terminal ---------------------------------------------------

fn assistant_texts(sample: tui_driver.Sample) -> List(String) {
  list.filter_map(messages(sample), fn(item) {
    case item {
      message.AssistantMessage(
        content: [message.AssistantText(text, None)],
        stop_reason: message.Stop,
        ..,
      ) -> Ok(text)
      _ -> Error(Nil)
    }
  })
}

fn messages(sample: tui_driver.Sample) -> List(message.AgentMessage) {
  list.filter_map(sample.model.records, fn(record) {
    case record.entry {
      entry.MessageEntry(message:, ..) -> Ok(message)
      _ -> Error(Nil)
    }
  })
}

fn writable(sample: tui_driver.Sample) -> Bool {
  case sample.model.channel {
    Some(channel) -> session_channel.mutation_available(channel)
    None -> False
  }
}

fn stop_driver(
  driver: actor.Started(process.Subject(tui_driver.Message)),
) -> Nil {
  let monitor = process.monitor(driver.pid)
  tui_driver.stop(driver.data)
  let assert Ok(process.ProcessDown(reason: process.Normal, ..)) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(2000)
    as "the original native driver retires normally"
  Nil
}

fn retire_native(paths: endpoint.Paths) -> Nil {
  let assert Ok(record) = endpoint.load(paths)
    as "cleanup decodes only this fixture's private endpoint"
  case record {
    None -> Nil
    Some(record) -> {
      assert record.fence.pid != native.current_process_id()
      let assert Ok(present) = endpoint.is_present(record.fence)
        as "cleanup checks original PID birth before signalling"
      case present {
        True -> native.terminate_process_group(record.fence.pid)
        False -> Nil
      }
      departed(record.fence)
    }
  }
}

fn departed(fence: endpoint.Fence) -> Nil {
  let assert poll.Answered(Nil) =
    poll.until(within: 10_000, every: 25, attempt: fn() {
      case endpoint.is_present(fence) {
        Ok(False) -> poll.Done(Nil)
        Ok(True) -> poll.Retry
        Error(reason) -> poll.Fail(reason)
      }
    })
    as "actual native departure is witnessed before the fixture completes"
  Nil
}
