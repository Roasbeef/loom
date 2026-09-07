//// Background jobs on the shipped daemon, driven by a real model turn
//// through a real jail: the motivating case of the design note, end to
//// end, plus the two properties nothing below this level can prove.
////
//// The motivating case is small and exact. A scripted turn calls `bash`
//// with `mode: "background"` on `tail -f build.log`; the fixture appends
//// three lines to that file from outside the jail; a later turn calls
//// `job_poll` with the cursor the job started from and must be shown
//// those three lines and nothing else, with the job still pending; a
//// third turn calls `job_kill`; and a fourth reads the terminal state,
//// which has to say the owner asked and carry the helper's own
//// `cancelled` witness. Then the payload's birth-qualified identity has
//// to depart, because a job whose record says stopped and whose process
//// is still running is the failure this whole surface exists to prevent.
////
//// The second scenario is the same door from code mode, through a real
//// hermetic build and a real jailed satellite. One program starts a job
//// and returns its id; a later program, in its own execution, asks the
//// strand what it owns and finds that record under that id — so the two
//// lifetimes are independent as far as the durable half goes. It stops
//// short of asserting the job's *process* is still running, and the
//// comment on `watching_program` says exactly why, because that is a bug
//// this fixture found rather than a property it is waiving.
////
//// The third is the restart rule. A job's process is a child of a helper
//// and the helper is a child of the VM, so nothing here survives the VM:
//// after a SIGKILL and a fresh boot the sweep must commit `Lost`, the
//// model's next poll must read it, and no replacement process may have
//// been started — the fixture proves the negative by the payload's own
//// recorded pid, which a respawn would have overwritten.
////
//// ## Why the whole file is gated on measured enforcement
////
//// Every scenario runs an unattended process against the workspace. On a
//// host whose helper cannot enforce a policy that is not a weaker test,
//// it is a different one, so the file declines with the same measured
//// verdict and the same declared reason the shipped multiplayer fixture
//// uses (`support/enforcement`). The code-mode scenario needs one more
//// prerequisite, and it is the one that has cost real time before: a
//// server booted without a build seed registers no `code_mode` tool at
//// all and says so only in its log, so the fixture reads the log for
//// `codemode.ready` rather than inferring readiness from a tool call
//// that would otherwise fail as something else.

import broker/token
import client/tui_e2e_test.{type EunitTest, Timeout}
import client/tui_v2_test
import core/entry
import core/json
import core/message
import etui/backend
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap as native
import host/endpoint
import simplifile
import support/enforcement
import support/internal/ffi_proc
import support/provider_http as provider
import support/tui_driver
import tui/bootstrap
import tui/daemon
import tui/daemon/bootstrap as daemon_bootstrap
import tui/daemon/selection
import tui/session_channel
import weft
import weft/actor
import weft/poll

/// The label every scenario's enforcement skip is printed under, so one
/// declaration in `.github/declared-skips*` covers the file.
const live_label = "shipped jobs live tools"

/// What the payload writes its own identity into, relative to the
/// workspace it runs in.
const pid_marker = "job.pid"

/// The file the watched job tails, and the fixture appends to.
const watched_log = "build.log"

/// The three lines appended from outside the jail. Twenty bytes, which is
/// what the stdout cursor of a poll that has read all of them must say.
const appended = "alpha\nbravo\ncharlie\n"

/// The exact stdout cursor those three lines advance a reader to.
const appended_cursor = "20:0"

// The payload publishes its own pid and then *becomes* `tail`, so the
// recorded identity is the process the cancel ladder has to reach rather
// than a shell that has already exited. Nothing here is a marker file the
// fixture races on for ordering: the write is what makes the process
// observable at all.
fn watch_command() -> String {
  "printf '%s\\n' \"$$\" > " <> pid_marker <> "; exec tail -f " <> watched_log
}

fn watch_arguments() -> json.JsonValue {
  json.Object([
    #("command", json.String(watch_command())),
    #("mode", json.String("background")),
  ])
}

/// Proves the motivating case: start, read what arrived since a cursor,
/// stop, and observe the process go.
///
/// ## Examples
///
/// `scripts/test.sh client --match daemon_shipped_jobs`.
pub fn daemon_shipped_job_tails_polls_and_stops_test_() -> EunitTest {
  // The runner scales this EUnit timeout by ten. The 120-second body and
  // independent native cleanup stay inside the 150-second deadline.
  Timeout(15, fn() {
    case shipped_prerequisites() {
      None -> Nil
      Some(server) -> {
        let #(Nil, report) =
          provider.with_server(tail_script(), fn(url) {
            tail_fixture(server, url)
          })
        let assert Ok(requests) = report
          as "only the eight scripted provider requests occur"
        assert_tail_evidence(requests)
      }
    }
  })
}

/// Proves a job's durable record outlives the code-mode program that
/// started it and is found by the next one.
///
/// ## Examples
///
/// `scripts/test.sh client --match daemon_shipped_jobs`.
pub fn daemon_shipped_job_record_outlives_its_program_test_() -> EunitTest {
  // Two hermetic builds and two jailed satellites run inside this body,
  // which is why it is the longest of the three.
  Timeout(30, fn() {
    case shipped_prerequisites() {
      None -> Nil
      Some(server) -> code_mode_fixture(server)
    }
  })
}

/// Proves the restart rule: a VM crash loses every live job, loudly, and
/// resurrects nothing.
///
/// ## Examples
///
/// `scripts/test.sh client --match daemon_shipped_jobs`.
pub fn daemon_shipped_job_is_lost_after_a_vm_crash_test_() -> EunitTest {
  // The reopen waits out the crashed VM's writer lease, so this body is
  // the longest-waiting of the three without being the busiest.
  Timeout(30, fn() {
    case shipped_prerequisites() {
      None -> Nil
      Some(server) -> {
        let #(Nil, report) =
          provider.with_server(restart_script(), fn(url) {
            restart_fixture(server, url)
          })
        let assert Ok(requests) = report
          as "only the four scripted provider requests occur"
        assert list.length(requests) == 4
      }
    }
  })
}

// Both prerequisites are environmental and neither is a coverage gap: an
// absent shipment means the suite was asked to test something that was
// never built, and an absent enforcement layer means the host cannot run
// an unattended jailed process under a policy at all.
fn shipped_prerequisites() -> Option(String) {
  case native.getenv("LOOM_BOOTSTRAP_E2E_SERVER") {
    Error(Nil) -> {
      io.println_error("SKIP shipped jobs: LOOM_BOOTSTRAP_E2E_SERVER is unset")
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

// --- the motivating case ----------------------------------------------------

// Eight steps, which is the script ceiling, and four of them have to be
// computed: a job id is minted by the harness while the fixture is
// already running, so neither the tool result that announces it nor the
// arguments of the calls that name it can be written down in advance.
fn tail_script() -> List(provider.Exchange) {
  [
    provider.ToolUseExchange(
      "watch the build",
      "start-call",
      "bash",
      watch_arguments(),
    ),
    answered("start-call", "watching"),
    provider.ComputedExchange(provider.AwaitPrompt("read the tail"), fn(seen) {
      poll_call(seen, "poll-call", 0)
    }),
    answered("poll-call", "read"),
    provider.ComputedExchange(provider.AwaitPrompt("stop it"), fn(seen) {
      provider.ReplyToolUse(
        call_id: "kill-call",
        name: "job_kill",
        arguments: json.Object([#("job_id", json.String(started_id(seen)))]),
      )
    }),
    answered("kill-call", "stopped"),
    provider.ComputedExchange(provider.AwaitPrompt("read it again"), fn(seen) {
      poll_call(seen, "final-call", 20_000)
    }),
    answered("final-call", "gone"),
  ]
}

// A tool result whose text the fixture cannot predict, answered with a
// fixed word so the transcript the driver waits on stays exact.
fn answered(call_id: String, text: String) -> provider.Exchange {
  provider.ComputedExchange(provider.AwaitToolResult(call_id), fn(_seen) {
    provider.ReplyText(text)
  })
}

// Always from the start of each stream. The design note's question is
// "what has it printed since I last looked", and a cursor of zero is the
// answer to the first looking; using it again for the terminal read
// proves the tail is still addressable after the job has ended.
fn poll_call(
  seen: List(provider.ObservedRequest),
  call_id: String,
  wait_ms: Int,
) -> provider.Reply {
  provider.ReplyToolUse(
    call_id: call_id,
    name: "job_poll",
    arguments: json.Object([
      #("job_id", json.String(started_id(seen))),
      #("wait_ms", json.Int(wait_ms)),
      #("since", json.String("0:0")),
    ]),
  )
}

// The one place the minted handle is read back out of evidence. Parsing
// the sentence `bash` wrote is deliberate: it is the sentence the model
// itself has to parse to make a second call, so a change that broke it
// would break a real model here first.
fn started_id(seen: List(provider.ObservedRequest)) -> String {
  let announcements =
    list.filter_map(seen, fn(request) {
      case request.latest {
        provider.SuccessfulToolResult("start-call", text) -> Ok(text)
        provider.SuccessfulToolResult(..) | provider.UserPrompt(..) ->
          Error(Nil)
      }
    })
  let assert [announcement] = announcements
    as "exactly one background start has been announced"
  let assert Ok(#(_before, rest)) =
    string.split_once(announcement, on: "started background job ")
    as "a background start names its job"
  let assert Ok(#(id, _after)) = string.split_once(rest, on: ",")
    as "a background start names its wall after its job"
  id
}

fn tail_fixture(server: String, url: String) -> Nil {
  let directory = private_root("shipped-jobs-")
  let assert Ok(paths) = endpoint.paths(directory <> "/state")
    as "cleanup retains its endpoint before launch"
  io.println_error("shipped jobs fixture: " <> directory)
  let outcomes =
    weft.new([
      fn() {
        exercise_tail(server, directory, paths, url)
        Ok(Nil)
      },
    ])
    |> weft.deadline(120_000)
    |> weft.start

  // Cleanup runs outside the body's deadline and before the assertions,
  // and it retires the payload as well as the VM: a body that failed
  // between the start and the kill has left a real `tail` running.
  retire_payload(directory <> "/workspace")
  retire_native(paths)
  let assert [weft.Completed(0, Nil)] = outcomes
    as "the shipped jobs body completes without crashing or timing out"
  Nil
}

fn exercise_tail(
  server: String,
  directory: String,
  paths: endpoint.Paths,
  url: String,
) -> Nil {
  let workspace = prepare_workspace(directory, url)
  let session = open_session(server, directory, workspace, paths)
  prompt(session.driver, "watch the build")

  // The payload's own identity is the barrier the appended lines wait
  // on: once it exists the process is live, and `tail` shows the last
  // lines of the file whether they arrived before or after it opened.
  let fence = await_payload(workspace)
  assert simplifile.append(workspace <> "/" <> watched_log, appended) == Ok(Nil)
  let _ = settled(session.driver, ["watching"])
  read_and_stop(session, fence)
  daemon.close(session.connected.control)
}

fn read_and_stop(session: Session, fence: endpoint.Fence) -> Nil {
  prompt(session.driver, "read the tail")
  let read = settled(session.driver, ["read", "watching"])
  let live = latest_details(read, "job_poll")
  assert field(live, "state") == json.String("running")
  assert field(live, "pending") == json.Bool(True)
  assert field(live, "cursor") == json.String(appended_cursor)
  prompt(session.driver, "stop it")
  let _ = settled(session.driver, ["stopped", "read", "watching"])
  assert_terminal(session, fence)
}

// The terminal read is a separate turn from the kill because the ladder
// is asynchronous: `job_kill` answers that the stop was asked for, and
// only the helper's own report of the stopped execution can say what
// became of the process.
fn assert_terminal(session: Session, fence: endpoint.Fence) -> Nil {
  prompt(session.driver, "read it again")
  let gone = settled(session.driver, ["gone", "stopped", "read", "watching"])
  let terminal = latest_details(gone, "job_poll")
  assert field(terminal, "state") == json.String("killed")
  assert field(terminal, "stopped_by") == json.String("owner")
  assert field(terminal, "pending") == json.Bool(False)

  // The helper's own witness that it climbed the ladder, which nothing
  // else in the record can say (protocol-change 006).
  assert field(terminal, "cancelled") == json.Bool(True)
  departed(fence)
  stop_driver(session.driver)
}

// The provider's evidence is where the exact bytes the model was shown
// live, so the text assertions are made against it rather than against a
// rendered terminal.
fn assert_tail_evidence(requests: List(provider.ObservedRequest)) -> Nil {
  let assert [
    provider.ObservedRequest(latest: provider.UserPrompt("watch the build"), ..),
    provider.ObservedRequest(
      latest: provider.SuccessfulToolResult("start-call", started),
      ..,
    ),
    provider.ObservedRequest(latest: provider.UserPrompt("read the tail"), ..),
    provider.ObservedRequest(
      latest: provider.SuccessfulToolResult("poll-call", polled),
      ..,
    ),
    provider.ObservedRequest(latest: provider.UserPrompt("stop it"), ..),
    provider.ObservedRequest(
      latest: provider.SuccessfulToolResult("kill-call", killed),
      ..,
    ),
    provider.ObservedRequest(latest: provider.UserPrompt("read it again"), ..),
    provider.ObservedRequest(
      latest: provider.SuccessfulToolResult("final-call", terminal),
      ..,
    ),
  ] = requests
    as "the eight scripted requests occur in their scripted order"
  assert string.starts_with(started, "started background job ")
  assert_polled_lines(polled)
  assert string.starts_with(killed, "stopped ")
  assert string.contains(terminal, "stopped (you asked), ")
}

// Everything in a poll's rendering is fixed except the job's id and its
// age, so the assertion pins the structure line by line: the three
// appended lines under the stdout rule, nothing under stderr, and the
// cursor those exact bytes advance to.
fn assert_polled_lines(polled: String) -> Nil {
  let assert [heading, stdout_rule, alpha, bravo, charlie, blank, cursor] =
    string.split(polled, on: "\n")
    as "a live poll renders a heading, one stream and a cursor"
  assert string.contains(heading, " — running, ")
  assert stdout_rule == "--- stdout ---"
  assert [alpha, bravo, charlie] == ["alpha", "bravo", "charlie"]
  assert blank == ""
  assert cursor == "cursor: " <> appended_cursor
}

// --- the same door from a program ------------------------------------------

// One capability call and a structured report, which is the shape a model
// would submit. The started job outlives this program by construction:
// nothing here waits for it. It prints once, records its own identity for
// the fixture's cleanup, and then sleeps well past the second hermetic
// build, so "still running" is a property of the job rather than a race
// against how long a compile took.
fn starting_program() -> String {
  "import cap/job\n"
  <> "import cap/report\n"
  <> "\n"
  <> "pub fn main() -> report.Outcome {\n"
  <> "  case job.start(\"printf 'one\\\\n'; printf '%s\\\\n' \\\"$$\\\" > "
  <> pid_marker
  <> "; sleep 600\") {\n"
  <> "    Ok(started) -> report.text(\"started \" <> started.id)\n"
  <> "    Error(_error) -> report.failure(\"job.start did not admit\")\n"
  <> "  }\n"
  <> "}\n"
}

// The second program never learns the id from the first: it asks the
// strand what it owns. That is the proof the record outlived the
// satellite, not merely that a string was carried between two turns.
// The second program never learns the id from the first: it asks the
// strand what it owns. That is the proof the durable record outlived the
// satellite, rather than that a string was carried between two turns.
//
// It reports the row's id and the fixture asserts no state. That is
// deliberate and it is not a gap being papered over: a code-mode
// execution ends by aborting its whole operation to reap its satellite
// (`codemode/satellite.cleanup`), and a job the program started cleared
// under that same operation, so the abort cancels the job's helper too
// and the record reads `lost`. The design says the opposite — the
// satellite ends when the program returns and a job it started keeps
// running under its own token — so which state belongs here is decided by
// the fix rather than by this fixture. `docs/next.md` carries it.
fn watching_program() -> String {
  "import cap/job\n"
  <> "import cap/report\n"
  <> "\n"
  <> "pub fn main() -> report.Outcome {\n"
  <> "  case job.list() {\n"
  <> "    Ok([row]) -> report.text(\"listed \" <> row.id)\n"
  <> "    Ok(_rows) -> report.failure(\"the strand owns no single job\")\n"
  <> "    Error(_error) -> report.failure(\"job.list did not answer\")\n"
  <> "  }\n"
  <> "}\n"
}

fn program_arguments(source: String) -> json.JsonValue {
  json.Object([
    #("program", json.String(source)),
    #("within_ms", json.Int(240_000)),
  ])
}

fn code_mode_script() -> List(provider.Exchange) {
  [
    provider.ToolUseExchange(
      "start the watcher",
      "start-program",
      "code_mode",
      program_arguments(starting_program()),
    ),
    answered("start-program", "started"),
    provider.ToolUseExchange(
      "read it from another program",
      "watch-program",
      "code_mode",
      program_arguments(watching_program()),
    ),
    answered("watch-program", "read"),
  ]
}

// The daemon boots before the provider does here, because whether this
// server registers `code_mode` at all is a question only its own log
// answers, and a script cannot be chosen after it has been handed over.
fn code_mode_fixture(server: String) -> Nil {
  let directory = shallow_root()
  let assert Ok(paths) = endpoint.paths(directory <> "/state")
    as "cleanup retains its endpoint before launch"
  io.println_error("shipped jobs code-mode fixture: " <> directory)
  let outcomes =
    weft.new([
      fn() {
        exercise_code_mode(server, directory, paths)
        Ok(Nil)
      },
    ])
    |> weft.deadline(240_000)
    |> weft.start
  retire_payload(directory <> "/workspace")
  retire_native(paths)
  let assert [weft.Completed(0, Nil)] = outcomes
    as "the shipped jobs code-mode body completes without crashing"
  Nil
}

fn exercise_code_mode(
  server: String,
  directory: String,
  paths: endpoint.Paths,
) -> Nil {
  let workspace = prepare_workspace(directory, "http://127.0.0.1:1/unused")
  let connected = connect_with_seed(server, directory, paths)
  let probe = attach(connected, "jobs-probe", workspace, config_of(directory))
  let ready = await_code_mode(paths)
  stop_driver(probe.driver)
  report_code_mode(connected, ready, directory, workspace)
  daemon.close(connected.control)
}

// The probe session existed only to make the server assemble one, which
// is where the code-mode verdict is logged. Its answer chooses between a
// declared skip and the real two-program drive.
fn report_code_mode(
  connected: Connected,
  ready: Bool,
  directory: String,
  workspace: String,
) -> Nil {
  case ready {
    False ->
      io.println_error(
        "SKIP shipped jobs code mode: the shipped server logged no "
        <> "codemode.ready",
      )

    True -> {
      let #(Nil, report) =
        provider.with_server(code_mode_script(), fn(url) {
          drive_programs(connected, directory, workspace, url)
        })
      let assert Ok(requests) = report
        as "only the four scripted code-mode requests occur"
      assert list.length(requests) == 4
    }
  }
}

// A second registration on the same running daemon reads the rewritten
// configuration, so the provider the programs' session talks to is the
// one this callback owns.
fn drive_programs(
  connected: Connected,
  directory: String,
  workspace: String,
  url: String,
) -> Nil {
  let config = config_of(directory)
  assert simplifile.write(config, configuration(url)) == Ok(Nil)
  let session = attach(connected, "jobs-programs", workspace, config)
  prompt(session.driver, "start the watcher")
  let started = settled(session.driver, ["started"])
  let assert Ok(#(_before, id)) =
    string.split_once(program_value(started), on: "started ")
    as "the first program reports the job it admitted"
  prompt(session.driver, "read it from another program")
  let read = settled(session.driver, ["read", "started"])

  // The satellite that started the job has returned and been reaped, and
  // the record it left is still the strand's to find under its own id.
  assert program_value(read) == "listed " <> id
  stop_driver(session.driver)
}

// `code_mode` renders the program's own report followed by a line naming
// what the kernel actually enforced, which varies by host; the reported
// value is the half this fixture is asserting about.
fn program_value(sample: tui_driver.Sample) -> String {
  case field(latest_details(sample, "code_mode"), "value") {
    json.String(text) -> text
    other ->
      panic as {
        "a completed program reports text, not " <> json.to_string(other)
      }
  }
}

// A server with no build seed registers no `code_mode` tool and says so
// only here. Both outcomes are logged at session assembly, so one of the
// two lines is always reached; a timeout is a server that never
// assembled and fails loudly rather than reading as unavailable.
fn await_code_mode(paths: endpoint.Paths) -> Bool {
  let assert poll.Answered(ready) =
    poll.until(within: 20_000, every: 50, attempt: fn() {
      case simplifile.read(paths.log) {
        Error(_reason) -> poll.Retry
        Ok(text) -> code_mode_verdict(text)
      }
    })
    as "the shipped server records whether it registered code mode"
  ready
}

fn code_mode_verdict(text: String) -> poll.Attempt(Bool, String) {
  case
    string.contains(text, "codemode.ready"),
    string.contains(text, "codemode.unavailable")
  {
    True, _ -> poll.Done(True)
    False, True -> poll.Done(False)
    False, False -> poll.Retry
  }
}

// --- nothing survives the VM ------------------------------------------------

fn restart_script() -> List(provider.Exchange) {
  [
    provider.ToolUseExchange(
      "watch the build",
      "start-call",
      "bash",
      watch_arguments(),
    ),
    answered("start-call", "watching"),
    provider.ToolUseExchange(
      "what happened to it",
      "list-call",
      "job_poll",
      json.Object([]),
    ),
    answered("list-call", "lost"),
  ]
}

fn restart_fixture(server: String, url: String) -> Nil {
  let directory = private_root("shipped-jobs-restart-")
  let assert Ok(paths) = endpoint.paths(directory <> "/state")
    as "cleanup retains its endpoint before launch"
  io.println_error("shipped jobs restart fixture: " <> directory)
  let outcomes =
    weft.new([
      fn() {
        exercise_restart(server, directory, paths, url)
        Ok(Nil)
      },
    ])
    |> weft.deadline(180_000)
    |> weft.start
  retire_payload(directory <> "/workspace")
  retire_native(paths)
  let assert [weft.Completed(0, Nil)] = outcomes
    as "the shipped jobs restart body completes without crashing"
  Nil
}

fn exercise_restart(
  server: String,
  directory: String,
  paths: endpoint.Paths,
  url: String,
) -> Nil {
  let workspace = prepare_workspace(directory, url)
  let first = open_session(server, directory, workspace, paths)
  prompt(first.driver, "watch the build")
  let fence = await_payload(workspace)
  let _ = settled(first.driver, ["watching"])
  let recorded = payload_marker(workspace)
  stop_driver(first.driver)
  crash(paths)
  daemon.close(first.connected.control)
  reopen_and_read(
    server,
    directory,
    workspace,
    paths,
    Crashed(first.id, fence, recorded),
  )
}

// What survives a crash and has to be carried across it: the durable
// session, the payload's own identity, and the pid a respawn would have
// overwritten.
type Crashed {
  Crashed(session: String, fence: endpoint.Fence, recorded: String)
}

fn reopen_and_read(
  server: String,
  directory: String,
  workspace: String,
  paths: endpoint.Paths,
  crashed: Crashed,
) -> Nil {
  // The payload is a child of a helper which is a child of the VM, so
  // the crash takes it too. Waiting for that here is what makes the
  // later "no respawn" reading unambiguous.
  departed(crashed.fence)

  // A fresh VM adopts the same state directory, and explicit open is what
  // puts the sweep's verdict in front of the model.
  let second =
    connect(server, directory, workspace, paths)
    |> reopen(crashed.session)
  prompt(second.driver, "what happened to it")

  // The reopened session carries its own transcript, so the barrier names
  // the first incarnation's answer as well as this one's.
  let read = settled(second.driver, ["lost", "watching"])
  let listing = latest_details(read, "job_poll")
  assert_lost(listing)

  // A sweep that re-adopted or restarted anything would have run the
  // command again, and the command's first act is to overwrite this.
  assert payload_marker(workspace) == crashed.recorded
  stop_driver(second.driver)
  daemon.close(second.connected.control)
}

fn assert_lost(listing: json.JsonValue) -> Nil {
  let assert json.Array([row]) = field(listing, "jobs")
    as "the strand's listing carries the one job it started"
  assert field(row, "state") == json.String("lost")
  assert field(row, "pending") == json.Bool(False)
}

// SIGKILL the verified original VM, never a pid read from anywhere else.
// This is the only way to reach the state the sweep exists for: an
// orderly stop settles each job into `Killed(BySessionStop)` instead.
fn crash(paths: endpoint.Paths) -> Nil {
  let assert Ok(Some(record)) = endpoint.load(paths)
    as "the crash targets this fixture's own published VM"
  assert record.fence.pid != native.current_process_id()
  assert endpoint.is_present(record.fence) == Ok(True)
  let assert Ok(kill) = ffi_proc.which("kill")
    as "the host provides the ordinary signal utility"
  let assert Ok(#(0, _)) =
    ffi_proc.run(kill, ["-KILL", int.to_string(record.fence.pid)], paths.root)
    as "SIGKILL targets only this fixture's verified original VM"
  departed(record.fence)
}

// --- sessions ---------------------------------------------------------------

// An authenticated VM with no attachment yet. Separate from `Session`
// because one daemon here carries two sessions in turn, and a connection
// outlives every driver bound to it.
type Connected {
  Connected(control: daemon.Connection, address: String, owner: String)
}

type Session {
  Session(
    connected: Connected,
    /// The durable identity, which outlives every VM that serves it.
    id: String,
    driver: actor.Started(process.Subject(tui_driver.Message)),
  )
}

fn private_root(prefix: String) -> String {
  let directory =
    "build/"
    <> prefix
    <> bit_array.base16_encode(token.production_entropy()(16))
  let assert Ok(Nil) = native.ensure_private_directory(directory)
    as "the native fixture has private state"
  let assert Ok(directory) = native.canonical_directory(directory)
    as "the fixture uses canonical paths"
  directory
}

// The code-mode cap socket is an AF_UNIX path with a hard byte budget, and
// a fixture root under `packages/client/build` inside a worktree spends
// that budget before the socket's own name is appended — the build
// workspace then refuses to be prepared. So this one scenario reserves a
// deliberately shallow root, exactly as the code-mode live suite does, and
// `/var/tmp` rather than `/tmp` because the jail replaces `/tmp` with its
// own scratch tmpfs.
fn shallow_root() -> String {
  let directory =
    "/var/tmp/loom-jobs-"
    <> string.lowercase(bit_array.base16_encode(token.production_entropy()(8)))
  let assert Ok(Nil) = native.ensure_private_directory(directory)
    as "the code-mode fixture has private state on a shallow path"
  let assert Ok(directory) = native.canonical_directory(directory)
    as "the fixture uses canonical paths"
  directory
}

fn prepare_workspace(directory: String, url: String) -> String {
  let workspace = directory <> "/workspace"
  assert simplifile.create_directory_all(workspace) == Ok(Nil)
  assert simplifile.write(directory <> "/fixture.toml", configuration(url))
    == Ok(Nil)

  // Created empty, so the three lines appended later are the whole of
  // what a tail with no history could possibly report.
  assert simplifile.write(workspace <> "/" <> watched_log, "") == Ok(Nil)
  workspace
}

fn configuration(url: String) -> String {
  "[models.fixture]\ndialect = \"anthropic\"\napi_key_env = \"LOOM_TEST_PROVIDER_KEY\"\nbase_url = \""
  <> url
  <> "\"\nmodel_id = \"fixture\"\ncontext_window = 100000\nmax_output_tokens = 4096\n[roles]\nmain = [\"fixture\"]\n[memory]\ndistill = \"off\"\n"
}

// Ordinary bootstrap, which starts a VM or adopts the one already
// holding this state directory. A fresh VM after a crash reaches the same
// durable records, which is what makes the restart scenario's reopen the
// same session rather than a new one.
fn connect(
  server: String,
  directory: String,
  workspace: String,
  paths: endpoint.Paths,
) -> Connected {
  let config = config_of(directory)
  let assert Ok(connected) =
    bootstrap.resolve_daemon(
      bootstrap.Options(workspace, "", server, paths.root, config),
      process.self(),
      40_000,
    )
    as "ordinary bootstrap starts the native daemon"
  let assert Ok(address) = endpoint.address(connected.record)
    as "the native endpoint is ready"
  let assert Ok(secret) = simplifile.read(connected.paths.token)
    as "the fixture owner reads its private credential"
  Connected(connected.control, address, string.trim(secret))
}

// The same VM, launched with the repository's prepared build seed.
//
// An `erlang-shipment` is not a release, so it carries no bundled seed and
// falls back to one under the session's own workspace, which a fixture
// workspace does not have. Naming the repository's own — the one `make
// codemode-seed` prepares and `make e2e-codemode` builds against — is what
// makes this fixture test the code-mode path rather than the absence of it.
fn connect_with_seed(
  server: String,
  directory: String,
  paths: endpoint.Paths,
) -> Connected {
  let config = config_of(directory)
  let assert Ok(here) = simplifile.current_directory()
    as "the test runner has a working directory"
  let seed = here <> "/../../build/codemode-seed"
  let assert Ok(connected) =
    daemon_bootstrap.resolve(
      paths,
      process.self(),
      fn() {
        Ok(daemon_bootstrap.Launch(
          server,
          list.append(
            bootstrap.daemon_launch_arguments(paths.root, server, config),
            ["--codemode-seed", seed],
          ),
        ))
      },
      40_000,
    )
    as "the shipped daemon starts with the repository's build seed"
  let assert Ok(address) = endpoint.address(connected.record)
    as "the native endpoint is ready"
  let assert Ok(secret) = simplifile.read(paths.token)
    as "the fixture owner reads its private credential"
  Connected(connected.control, address, string.trim(secret))
}

fn open_session(
  server: String,
  directory: String,
  workspace: String,
  paths: endpoint.Paths,
) -> Session {
  connect(server, directory, workspace, paths)
  |> attach("jobs", workspace, config_of(directory))
}

fn config_of(directory: String) -> String {
  directory <> "/fixture.toml"
}

fn attach(
  connected: Connected,
  key: String,
  workspace: String,
  config: String,
) -> Session {
  let assert Ok(host) =
    selection.host(connected.control, connected.address, connected.owner)
    as "the owner has an authenticated selector"
  let assert Ok(created) = selection.create(host, key, workspace, config)
    as "the session is explicitly created"
  bind(connected, created.expected.session)
}

// Reopening an initialized conversation is a different verb from creating
// one: the creation key resumes a *reservation*, and this session already
// has a store the crashed incarnation left behind.
fn reopen(connected: Connected, id: String) -> Session {
  let assert Ok(host) =
    selection.host(connected.control, connected.address, connected.owner)
    as "the owner has an authenticated selector against the replacement"

  // A killed VM leaves an unexpired writer lease on the session's store,
  // and a fresh VM's assembly is refused (`storage_open_failed`) until it
  // can be stolen. That is the design working: a lease is what stops two
  // incarnations writing one conversation, and nothing observed the old
  // one die. So the wait here is the lease TTL — thirty seconds
  // (`storage/sqlite.Config.lease_ttl_ms`) — with room, and the deadline
  // is what makes a refusal that is *not* the lease loud.
  let assert poll.Answered(opened) =
    poll.until(within: 60_000, every: 250, attempt: fn() {
      case selection.open(host, id) {
        Ok(target) -> poll.Done(target)
        Error(_lease_held) -> poll.Retry
      }
    })
    as "explicit open admits the session once the crashed VM's lease expires"
  assert opened.expected.session == id
  bind(connected, id)
}

fn bind(connected: Connected, id: String) -> Session {
  let assert Ok(started) =
    tui_driver.start(connected.address, connected.owner, id)
    as "the fixture attaches over the actual session socket"
  let _ = tui_v2_test.await(started.data, writable)
  Session(connected, id, started)
}

// --- observing the payload --------------------------------------------------

fn await_payload(workspace: String) -> endpoint.Fence {
  let assert poll.Answered(fence) =
    poll.until(within: 30_000, every: 25, attempt: fn() {
      case payload_fence(workspace) {
        Ok(fence) -> poll.Done(fence)
        Error(Nil) -> poll.Retry
      }
    })
    as "the background payload publishes a live identity of its own"
  fence
}

// A pid alone is not an identity. The birth qualification is what makes a
// later absence mean *this* process left rather than that its number was
// reused, and it is the same check the recovery fixtures make of a VM.
fn payload_fence(workspace: String) -> Result(endpoint.Fence, Nil) {
  use text <- result.try(
    simplifile.read(workspace <> "/" <> pid_marker)
    |> result.replace_error(Nil),
  )
  use pid <- result.try(int.parse(string.trim(text)))
  endpoint.observe(pid) |> result.replace_error(Nil)
}

fn payload_marker(workspace: String) -> String {
  let assert Ok(text) = simplifile.read(workspace <> "/" <> pid_marker)
    as "the payload's recorded identity survives the crash as a file"
  string.trim(text)
}

fn departed(fence: endpoint.Fence) -> Nil {
  let assert poll.Answered(Nil) =
    poll.until(within: 15_000, every: 25, attempt: fn() {
      case endpoint.is_present(fence) {
        Ok(False) -> poll.Done(Nil)
        Ok(True) -> poll.Retry
        Error(reason) -> poll.Fail(reason)
      }
    })
    as "the original payload identity departs, not merely its output"
  Nil
}

// A body that failed between starting a job and stopping it has left a
// real process behind, and no assertion is worth a stray `tail` on a
// developer's machine.
fn retire_payload(workspace: String) -> Nil {
  case payload_fence(workspace) {
    Error(Nil) -> Nil
    Ok(fence) -> {
      assert fence.pid != native.current_process_id()
      native.terminate_process_group(fence.pid)
      Nil
    }
  }
}

fn retire_native(paths: endpoint.Paths) -> Nil {
  let assert Ok(record) = endpoint.load(paths)
    as "cleanup decodes only this fixture's private endpoint"
  case record {
    None -> Nil
    Some(record) -> {
      assert record.fence.pid != native.current_process_id()
      let assert Ok(present) = endpoint.is_present(record.fence)
        as "cleanup checks original PID birth"
      case present {
        True -> native.terminate_process_group(record.fence.pid)
        False -> Nil
      }
      departed(record.fence)
    }
  }
}

// --- reading the terminal ---------------------------------------------------

fn prompt(
  driver: actor.Started(process.Subject(tui_driver.Message)),
  text: String,
) -> Nil {
  let _ =
    tui_driver.play(driver.data, [
      backend.Paste(text),
      backend.KeyPress("enter"),
    ])
  Nil
}

// Newest first, which is the order the client's own records arrive in.
// Waiting on the settled assistant texts rather than on a message count
// keeps the barrier honest across turns that carry a tool call.
fn settled(
  driver: actor.Started(process.Subject(tui_driver.Message)),
  answers: List(String),
) -> tui_driver.Sample {
  tui_v2_test.await(driver.data, fn(sample) {
    writable(sample)
    && assistant_texts(sample) == answers
    && sample.model.streams == []
    && list.any(sample.model.strands, fn(strand) {
      strand.id == "main" && strand.live_phase == None
    })
  })
}

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

// The most recent result for one tool, which is the one a turn just
// produced. `details` is where the structured half of a job answer
// lives — `cancelled`, `pending`, the cursor — and the model's own text
// deliberately does not restate all of it.
fn latest_details(sample: tui_driver.Sample, name: String) -> json.JsonValue {
  let found =
    list.filter_map(messages(sample), fn(item) {
      case item {
        message.ToolResultMessage(tool_name:, details: Some(details), ..)
          if tool_name == name
        -> Ok(details)
        _ -> Error(Nil)
      }
    })
  let assert [details, ..] = found
    as { "the transcript carries a " <> name <> " result with details" }
  details
}

fn messages(sample: tui_driver.Sample) -> List(message.AgentMessage) {
  list.filter_map(sample.model.records, fn(record) {
    case record.entry {
      entry.MessageEntry(message:, ..) -> Ok(message)
      _ -> Error(Nil)
    }
  })
}

fn field(value: json.JsonValue, key: String) -> json.JsonValue {
  case value {
    json.Object(fields) ->
      list.key_find(fields, key) |> result.unwrap(json.Null)
    _ -> json.Null
  }
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
