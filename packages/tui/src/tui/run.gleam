//// `loom run -p`: one prompt, one session, one JSON line on standard output.
////
//// The interactive client keeps a person in front of a session; a harness
//// that scores an agent needs the opposite shape: start, ask once, wait for
//// the run to end, read a verdict from the exit status, and leave nothing
//// running. This module is that client. It is a client of the daemon
//// protocol like the terminal is, not a second server runtime: it reaches
//// the daemon through the same discovery and launch ladder, creates a
//// session under a one-shot creation key, attaches the same credited
//// session lane (`session_view/session_channel`) the terminal drives, sends
//// one `prompt`, and waits for the `main` strand's durable terminal
//// `last_result`. Nothing here decides what an agent may do; the daemon's
//// broker and sandbox still do.
////
//// Standard output carries exactly one JSON object and nothing else, so a
//// caller can parse it without scraping. Everything a person might want to
//// read goes to standard error. The exit status is the verdict: `0` the
//// run completed, `1` it failed or was aborted (or the session could not be
//// made), `2` the arguments were bad, `3` no daemon could be reached or
//// started, `124` the deadline passed (the convention of `timeout(1)`).
////
//// The jail posture is mandatory in the report because a score earned with
//// a degraded jail means something different from one earned with all of
//// it. The daemon does not report its enforcement to a client (neither
//// `hello` nor the snapshot carries it), so `loom run` runs the sandbox
//// helper's own `--self-test` once, from the helper beside the server
//// executable it resolves, and labels the result `enforced` (every probe
//// passed), `degraded` (the helper ran but skipped probes) or `unverified`
//// (the self-test could not be run or failed). `unverified` is the honest
//// answer when the label cannot be earned, and it is never omitted.
////
//// `session_db` is printed only when the file exists at the path the
//// daemon's layout gives (`<state_dir>/sessions/<id>.db`); the control
//// reply does not name the path, so the field is left out rather than
//// guessed.
////
//// ## Flow
////
//// `parse` → `conduct` → `drive` → `settle` → `render`
////
//// 1. `parse` turns the words after the verb into a `Request` or a refusal
////    that exits `2` before any daemon is touched.
//// 2. `conduct` measures the posture, reaches the daemon, creates and
////    attaches the session, and answers a `Conduct`; `execute` prints it and
////    maps it to an exit status.
//// 3. `drive` is the receive loop: it feeds the lane, performs its outputs,
////    and submits the optional model switch and then the prompt once the
////    first cut is held.
//// 4. `settle` reduces a captured cut to a verdict: the main strand's
////    last result, or no verdict yet.
//// 5. `render` writes the report as one compact JSON object.

import core/codec
import core/entry
import core/json
import core/message
import core/register
import filepath
import gleam/bit_array
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap as host_bootstrap
import host/endpoint
import machine/codec as machine_codec
import machine/operation
import machine/strand
import session_view/connection_event
import session_view/protocol as session_protocol
import session_view/session_channel
import session_view/snapshot
import session_view/snapshot_view
import simplifile
import tui/bootstrap
import tui/connection
import tui/daemon
import tui/daemon/protocol
import tui/daemon/selection
import tui/internal/ffi_terminal
import tui/placement
import weft/poll

/// Exit status when arguments were refused before any work began.
pub const exit_bad_arguments = 2

/// Exit status when no daemon could be reached or started.
pub const exit_no_daemon = 3

/// Exit status when the deadline passed before the run ended.
pub const exit_timeout = 124

// The deadline when the caller names none. An hour is longer than any
// scored run is meant to take and shorter than forever, so a wedged run
// still ends and reports.
const default_timeout_seconds = 3600

// The strand a one-shot run prompts. A new session has exactly this one.
const main_strand = "main"

/// Whether the session outlives the command.
pub type Retention {
  /// Stop the session before exiting. The default: a harness leaves nothing
  /// resident.
  StopAtExit

  /// Leave the session resident (`--keep`), so its database can be read
  /// while the daemon still holds it.
  KeepSession
}

/// What the command line asked for.
pub type Request {
  Request(
    /// The daemon options shared with every local launch: workspace, server,
    /// state directory, catalogue and model profile.
    options: bootstrap.Options,
    /// The one user turn. Never empty.
    prompt: String,
    /// The most the run may take, in milliseconds, from the moment the
    /// session is attached.
    timeout_ms: Int,
    /// A catalogue model name to switch the `main` strand to before the
    /// prompt, or `None` to run the configuration's own choice.
    model: Option(String),
    /// Whether the session is stopped at exit.
    retention: Retention,
  )
}

/// How the run ended, as the exit status will say it.
pub type Verdict {
  /// The run finished normally.
  Completed

  /// The run failed or the session could not carry it. The text is a
  /// bounded diagnostic and never carries a credential.
  Failed(reason: String)

  /// The run was cancelled and reconciled.
  Aborted

  /// The deadline passed first.
  TimedOut
}

/// What the helper's self-test earned the run to say about its jail.
pub type Posture {
  /// Every probe passed.
  Enforced(layers: Int)

  /// The helper ran but skipped probes, so some layers were not verified.
  Degraded(enforced: Int, skipped: Int)

  /// The self-test could not be run or did not pass; nothing is claimed.
  Unverified(reason: String)
}

/// Everything the one JSON line says.
pub type Report {
  Report(
    /// The session's canonical identity.
    session_id: String,
    /// The daemon's private state root.
    state_dir: String,
    /// The session database when it exists at the layout's path.
    session_db: Option(String),
    /// How the run ended.
    verdict: Verdict,
    /// Assistant messages on the main branch in the retained window.
    turns: Int,
    /// The session's cumulative usage from the last cut, when one arrived.
    usage: Option(message.Usage),
    /// Milliseconds from attachment to verdict.
    elapsed_ms: Int,
    /// The jail label.
    posture: Posture,
    /// The model the main strand was configured with in the last cut.
    model: Option(strand.ModelIdentity),
  )
}

// What the drive stops with: the verdict and the last cut the lane held.
type Finish {
  Finish(
    verdict: Verdict,
    view: Option(#(snapshot.Captured, snapshot_view.View)),
  )
}

// Where the one-shot conversation stands. Each pending stage waits for the
// lane to be able to take a mutation; each awaiting stage waits for the
// daemon's acknowledgement, because the lane holds one request at a time.
type Stage {
  NeedsModel(name: String)
  AwaitingModel
  NeedsPrompt
  AwaitingPrompt
}

type Lane =
  session_channel.Channel(connection.Connection, Nil)

type Drive {
  Drive(
    lane: Lane,
    stage: Stage,
    view: Option(#(snapshot.Captured, snapshot_view.View)),
    ended: Option(Verdict),
  )
}

/// How a conducted run ended, before anything is printed.
pub type Conduct {
  /// No daemon could be reached or started.
  NoDaemon(reason: String)

  /// A daemon answered but no session could be made.
  NoSession(reason: String)

  /// A session existed and the run reached a verdict.
  Ran(report: Report)
}

/// Parses the words after `loom run`.
///
/// `-p`/`--prompt` is required. The daemon options (`--workspace`,
/// `--server`, `--state-dir`, `--config`, `--model-profile`) mean what they
/// mean for a local launch. `--model` names a catalogue entry for the main
/// strand, `--timeout` is whole seconds, `--keep` leaves the session
/// resident, and `--json` is accepted because the output is always JSON.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(request) = run.parse(["-p", "hello", "--timeout", "30"])
/// assert request.prompt == "hello"
/// assert request.timeout_ms == 30_000
/// let assert Error(_) = run.parse(["--keep"])
/// ```
pub fn parse(arguments: List(String)) -> Result(Request, String) {
  let start =
    Request(
      options: bootstrap.Options("", "", "", "", "", "", placement.OnThisHost),
      prompt: "",
      timeout_ms: default_timeout_seconds * 1000,
      model: None,
      retention: StopAtExit,
    )
  use request <- result.try(parse_words(arguments, start))

  // A prompt is the whole point; an empty one would start a session to send
  // nothing.
  case string.trim(request.prompt) {
    "" -> Error("run needs a prompt: loom run -p <text>")
    _ -> Ok(request)
  }
}

/// Folds the words after `run` into a request, one switch or one flag with its value at a time.
fn parse_words(
  arguments: List(String),
  request: Request,
) -> Result(Request, String) {
  // Each leading word is a switch, a flag with its value, or a dangling flag.
  case arguments {
    [] -> Ok(request)
    ["--keep", ..rest] ->
      parse_words(rest, Request(..request, retention: KeepSession))
    ["--json", ..rest] -> parse_words(rest, request)
    [flag] -> Error("missing value for " <> flag)
    [flag, value, ..rest] -> {
      use request <- result.try(apply_flag(request, flag, value))
      parse_words(rest, request)
    }
  }
}

/// Lands one flag's value in the request, or refuses a flag this verb does not have.
fn apply_flag(
  request: Request,
  flag: String,
  value: String,
) -> Result(Request, String) {
  let options = request.options

  // Which flag this is decides which part of the request its value lands in.
  case flag {
    "-p" | "--prompt" -> Ok(Request(..request, prompt: value))
    "--model" -> Ok(Request(..request, model: Some(value)))
    "--timeout" ->
      timeout_seconds(value) |> result.map(with_timeout(request, _))
    "--workspace" ->
      Ok(
        Request(
          ..request,
          options: bootstrap.Options(..options, workspace: value),
        ),
      )
    "--server" ->
      Ok(
        Request(..request, options: bootstrap.Options(..options, server: value)),
      )
    "--state-dir" ->
      Ok(
        Request(
          ..request,
          options: bootstrap.Options(..options, state_directory: value),
        ),
      )
    "--config" ->
      Ok(
        Request(..request, options: bootstrap.Options(..options, config: value)),
      )
    "--model-profile" ->
      Ok(
        Request(
          ..request,
          options: bootstrap.Options(..options, profile: value),
        ),
      )
    _ -> Error("unknown run option " <> flag)
  }
}

fn with_timeout(request: Request, seconds: Int) -> Request {
  Request(..request, timeout_ms: seconds * 1000)
}

/// Reads `--timeout`; zero or a non-number is refused rather than meaning no deadline.
fn timeout_seconds(text: String) -> Result(Int, String) {
  case int.parse(text) {
    Ok(seconds) if seconds > 0 -> Ok(seconds)
    Ok(_) | Error(Nil) ->
      Error("--timeout needs a whole number of seconds above zero")
  }
}

/// The exit status a verdict is reported with.
///
/// ## Examples
///
/// ```gleam
/// assert run.exit_code(run.Completed) == 0
/// assert run.exit_code(run.TimedOut) == 124
/// assert run.exit_code(run.Aborted) == 1
/// ```
pub fn exit_code(verdict: Verdict) -> Int {
  case verdict {
    Completed -> 0
    Failed(..) | Aborted -> 1
    TimedOut -> exit_timeout
  }
}

/// The outcome word the report carries.
///
/// ## Examples
///
/// ```gleam
/// assert run.outcome_word(run.Failed("x")) == "failed"
/// ```
pub fn outcome_word(verdict: Verdict) -> String {
  case verdict {
    Completed -> "completed"
    Failed(..) -> "failed"
    Aborted -> "aborted"
    TimedOut -> "timeout"
  }
}

/// Reads the `main` strand's terminal run result out of one captured cut.
///
/// A session made for this command has no earlier run, so any durable
/// `RunLastResult` on `main` is the answer to the prompt. A cut that holds
/// none, or holds a compaction or navigation result, says nothing yet.
///
/// ## Examples
///
/// ```gleam
/// // run.settle(view) == Some(run.Completed)
/// ```
pub fn settle(view: snapshot_view.View) -> Option(Verdict) {
  view.cells
  |> list.find(fn(cell) {
    cell.namespace == register.StrandLastResult && cell.key == main_strand
  })
  |> result.replace_error(Nil)
  |> result.try(fn(cell) {
    machine_codec.decode_last_result(cell.value) |> result.replace_error(Nil)
  })
  |> result.map(verdict_of)
  |> option.from_result
  |> option.flatten
}

/// Maps a durable last result to the verdict it ends the run with; structural results end nothing.
fn verdict_of(result: operation.LastResult) -> Option(Verdict) {
  case result {
    operation.RunLastResult(outcome: operation.RunCompleted(..), ..) ->
      Some(Completed)
    operation.RunLastResult(outcome: operation.RunFailed(error:), ..) ->
      Some(Failed("the run failed: " <> error.code))
    operation.RunLastResult(outcome: operation.RunAborted, ..) -> Some(Aborted)
    operation.CompactionLastResult(..) | operation.NavigationLastResult(..) ->
      None
  }
}

/// Reads the jail label out of one self-test run.
///
/// `status` is the helper's exit status and `report` its combined output.
/// Only a zero status with the helper's own `RESULT: OK` line earns a label;
/// the counts come from its `enforced (N)` and `skipped (N)` summary lines.
///
/// ## Examples
///
/// ```gleam
/// assert run.posture_of(0, "enforced (10):\nRESULT: OK") == run.Enforced(10)
/// ```
pub fn posture_of(status: Int, report: String) -> Posture {
  // Only a clean exit carrying the helper's own verdict line earns a label.
  case status == 0 && string.contains(report, "RESULT: OK") {
    False -> Unverified("self-test exited " <> int.to_string(status))
    True -> {
      let enforced = summary_count(report, "enforced (")

      // Skipped probes mean some layers were never verified, so the label drops.
      case summary_count(report, "skipped (") {
        0 -> Enforced(enforced)
        skipped -> Degraded(enforced, skipped)
      }
    }
  }
}

/// Reads the count out of the helper's `enforced (N)` or `skipped (N)` summary line, zero when absent.
fn summary_count(report: String, prefix: String) -> Int {
  report
  |> string.split("\n")
  |> list.find_map(fn(line) {
    let trimmed = string.trim(line)

    // Only the summary line that opens with the prefix carries the count.
    case string.starts_with(trimmed, prefix) {
      False -> Error(Nil)
      True ->
        string.drop_start(trimmed, string.length(prefix))
        |> string.split(")")
        |> list.first
        |> result.try(int.parse)
    }
  })
  |> result.unwrap(0)
}

/// Renders the report as the one compact JSON object printed on stdout.
///
/// ## Examples
///
/// ```gleam
/// // run.render(report) -> "{\"session_id\":\"…\",…}"
/// ```
pub fn render(report: Report) -> String {
  // A database is named only when the file was found on disk.
  let database = case report.session_db {
    Some(path) -> [#("session_db", json.String(path))]
    None -> []
  }

  // Only a failure carries a reason; the other verdicts say it all in the word.
  let reason = case report.verdict {
    Failed(reason:) -> [#("reason", json.String(reason))]
    Completed | Aborted | TimedOut -> []
  }

  json.Object(
    list.flatten([
      [#("session_id", json.String(report.session_id))],
      database,
      [
        #("state_dir", json.String(report.state_dir)),
        #("outcome", json.String(outcome_word(report.verdict))),
      ],
      reason,
      [
        #("turns", json.Int(report.turns)),
        #(
          "usage",
          option.map(report.usage, codec.encode_usage)
            |> option.unwrap(json.Null),
        ),
        #("elapsed_ms", json.Int(report.elapsed_ms)),
        #("jail", render_posture(report.posture)),
        #("model", render_model(report.model)),
      ],
    ]),
  )
  |> json.to_string
}

/// The `jail` member: the label plus what the self-test measured or why it could not.
fn render_posture(posture: Posture) -> json.JsonValue {
  case posture {
    Enforced(layers:) ->
      json.Object([
        #("posture", json.String("enforced")),
        #(
          "selftest",
          json.Object([
            #("enforced", json.Int(layers)),
            #("skipped", json.Int(0)),
          ]),
        ),
      ])
    Degraded(enforced:, skipped:) ->
      json.Object([
        #("posture", json.String("degraded")),
        #(
          "selftest",
          json.Object([
            #("enforced", json.Int(enforced)),
            #("skipped", json.Int(skipped)),
          ]),
        ),
      ])
    Unverified(reason:) ->
      json.Object([
        #("posture", json.String("unverified")),
        #("selftest", json.Object([#("reason", json.String(reason))])),
      ])
  }
}

/// The `model` member, or null when no cut ever reported the strand's configuration.
fn render_model(model: Option(strand.ModelIdentity)) -> json.JsonValue {
  case model {
    Some(strand.ModelIdentity(provider:, model_id:)) ->
      json.Object([
        #("provider", json.String(provider)),
        #("model_id", json.String(model_id)),
      ])
    None -> json.Null
  }
}

// --- the effectful half ------------------------------------------------------

/// Runs the whole command and answers its exit status.
///
/// It prints the report on standard output when a session existed, and a
/// diagnostic line on standard error otherwise. The caller halts with the
/// returned status.
///
/// ## Examples
///
/// ```gleam
/// // let status = run.execute(request)
/// ```
pub fn execute(request: Request) -> Int {
  // The conducted outcome decides what is printed and which status is returned.
  case conduct(request) {
    NoDaemon(reason:) -> {
      io.println_error("loom run: " <> reason)
      exit_no_daemon
    }
    NoSession(reason:) -> {
      io.println_error("loom run: " <> reason)
      1
    }
    Ran(report:) -> {
      io.println(render(report))
      exit_code(report.verdict)
    }
  }
}

/// Does everything `execute` does except print and exit, so a test can run it
/// in-process against a real daemon and read the report as data.
///
/// ## Examples
///
/// ```gleam
/// // let assert run.Ran(report) = run.conduct(request)
/// ```
pub fn conduct(request: Request) -> Conduct {
  // No daemon means nothing was created, so there is no session to report.
  case reach_daemon(request.options) {
    Error(reason) -> NoDaemon(reason)
    Ok(#(host, root)) -> {
      // The self-test runs after the daemon is reached because its output
      // file lives in the state root, which exists only from then on.
      let posture = measure_posture(request.options, root)
      let conducted = run_session(request, host, root, posture)
      daemon.close(selection.control(host))
      conducted
    }
  }
}

/// Resolves the shared daemon and the owner credential, the way `loom sessions` does.
///
/// The daemon is reached the way `loom sessions` reaches it: the shared
/// discovery and launch ladder, then the owner credential from the state
/// root. Any failure here means no usable daemon, so the caller exits `3`.
/// `loom acp` reaches the daemon through the same function, so both headless
/// clients authenticate and launch identically.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(#(host, state_root)) = run.reach_daemon(options)
/// ```
pub fn reach_daemon(
  options: bootstrap.Options,
) -> Result(#(selection.Host, String), String) {
  use connected <- result.try(bootstrap.resolve_daemon(
    options,
    process.self(),
    90_000,
  ))
  use address <- result.try(endpoint.address(connected.record))
  use bytes <- result.try(host_bootstrap.read_private_bounded(
    connected.paths.token,
    65,
  ))
  use token <- result.try(
    bit_array.to_string(bytes)
    |> result.replace_error("invalid owner credential encoding"),
  )
  use host <- result.map(selection.host(
    connected.control,
    address,
    string.trim(token),
  ))
  #(host, connected.paths.root)
}

/// Creates the session, drives it to a verdict and retires it, in that order.
fn run_session(
  request: Request,
  host: selection.Host,
  root: String,
  posture: Posture,
) -> Conduct {
  // A refused creation has no session; an attached one always has a report.
  case create_target(request, host) {
    Error(reason) -> NoSession(reason)
    Ok(target) -> {
      let session = target.expected.session
      let report = attach_and_drive(request, target, root, posture)
      retire(request.retention, host, session)
      Ran(report)
    }
  }
}

/// Creates the session under a one-shot key; the key is never reused, so a retry cannot adopt a stale one.
fn create_target(
  request: Request,
  host: selection.Host,
) -> Result(selection.Target, String) {
  let options = request.options
  use workspace <- result.try(
    host_bootstrap.canonical_directory(case options.workspace {
      "" -> "."
      path -> path
    })
    |> result.map_error(fn(reason) { "resolve workspace: " <> reason }),
  )
  use configuration <- result.try(bootstrap.session_configuration(options))
  let key =
    "loom-run-"
    <> int.to_string(host_bootstrap.current_process_id())
    <> "-"
    <> int.to_string(host_bootstrap.system_time_ms())

  selection.create_named(
    host,
    key,
    workspace,
    bootstrap.workspace_name(workspace),
    configuration,
    options.profile,
    "",
    "",
  )
}

/// Opens the session socket, runs the receive loop under the deadline and closes the socket, reporting what it saw.
fn attach_and_drive(
  request: Request,
  target: selection.Target,
  root: String,
  posture: Posture,
) -> Report {
  let started = host_bootstrap.monotonic_time_ms()
  let session = target.expected.session

  // A socket that cannot be opened is a failed run with no cut to report.
  let finish = case connect(target) {
    Error(reason) -> Finish(Failed(reason), None)
    Ok(#(inbox, socket)) -> {
      let deadline = started + request.timeout_ms
      let finish = drive(request, inbox, socket, target.expected, deadline)
      connection.close(socket)
      finish
    }
  }

  build_report(
    session,
    root,
    finish,
    posture,
    host_bootstrap.monotonic_time_ms() - started,
  )
}

/// Opens the session socket with an inbox this process reads.
fn connect(
  target: selection.Target,
) -> Result(
  #(process.Subject(connection_event.Message), connection.Connection),
  String,
) {
  let inbox = connection.new_inbox()
  use socket <- result.map(connection.connect(
    target.address,
    target.token,
    inbox,
  ))
  #(inbox, socket)
}

/// Joins the drive's finish with the last cut it held into the report.
fn build_report(
  session: String,
  root: String,
  finish: Finish,
  posture: Posture,
  elapsed_ms: Int,
) -> Report {
  let database = filepath.join(root, "sessions/" <> session <> ".db")

  // Without a cut the report carries zero turns and no usage or model.
  let #(turns, usage, model) = case finish.view {
    Some(#(captured, view)) -> #(
      count_turns(view, captured.window),
      Some(view.usage),
      main_model(view),
    )
    None -> #(0, None, None)
  }

  Report(
    session_id: session,
    state_dir: root,
    session_db: case host_bootstrap.path_exists(database) {
      True -> Some(database)
      False -> None
    },
    verdict: finish.verdict,
    turns:,
    usage:,
    elapsed_ms:,
    posture:,
    model:,
  )
}

fn main_model(view: snapshot_view.View) -> Option(strand.ModelIdentity) {
  dict.get(view.configurations, main_strand)
  |> result.map(fn(configured) { configured.configuration.model })
  |> option.from_result
}

/// Counts assistant messages on the main branch in the retained window.
fn count_turns(view: snapshot_view.View, window: snapshot.Window) -> Int {
  snapshot_view.branch(view, window, main_strand).records
  |> list.count(fn(record) {
    case record.entry {
      entry.MessageEntry(message: message.AssistantMessage(..), ..) -> True
      _ -> False
    }
  })
}

// --- the receive loop --------------------------------------------------------

/// Starts the lane and runs the receive loop until a verdict or the deadline.
fn drive(
  request: Request,
  inbox: process.Subject(connection_event.Message),
  socket: connection.Connection,
  expected: snapshot.Expected,
  deadline: Int,
) -> Finish {
  let now = host_bootstrap.monotonic_time_ms()

  // The optional model switch goes first; otherwise the prompt is first.
  let stage = case request.model {
    Some(name) -> NeedsModel(name)
    None -> NeedsPrompt
  }

  let lane = session_channel.start(socket, expected, now:)

  Drive(lane:, stage:, view: None, ended: None)
  |> flush
  |> loop(request, inbox, deadline)
}

/// One turn of the receive loop: stop on a verdict or the deadline, else receive, advance and flush.
fn loop(
  state: Drive,
  request: Request,
  inbox: process.Subject(connection_event.Message),
  deadline: Int,
) -> Finish {
  let now = host_bootstrap.monotonic_time_ms()

  // A verdict already reached wins over the deadline that may also have passed.
  case state.ended, deadline - now <= 0 {
    Some(verdict), _ -> Finish(verdict, state.view)
    None, True -> Finish(TimedOut, state.view)
    None, False -> {
      let wait = int.min(deadline - now, wake_in(state.lane, now))
      let state =
        step(state, inbox, wait, now)
        |> advance(request, now)
        |> flush

      loop(state, request, inbox, deadline)
    }
  }
}

// How long the loop may sleep: until the lane's next due reading, never
// longer than a quarter second so the deadline and the lane are both
// re-read promptly.
fn wake_in(lane: Lane, now: Int) -> Int {
  case session_channel.next_due(lane) {
    Some(due) -> int.max(1, int.min(due - now, 250))
    None -> 250
  }
}

/// Reduces one event: a frame through the lane, or a tick when the interval passed quietly.
///
/// One event: a frame reduces through the lane, and a quiet interval ticks it.
fn step(
  state: Drive,
  inbox: process.Subject(connection_event.Message),
  wait: Int,
  now: Int,
) -> Drive {
  // A frame reduces through the lane; a quiet interval ticks it instead.
  let #(lane, updates) = case process.receive(inbox, wait) {
    Ok(message) -> session_channel.receive(state.lane, message, now:)
    Error(Nil) -> session_channel.tick(state.lane, now:)
  }

  list.fold(updates, Drive(..state, lane:), absorb)
}

// Performs what the lane decided to write or close, in its decision order.
fn flush(state: Drive) -> Drive {
  let #(lane, outputs) = session_channel.take_outputs(state.lane)
  list.each(outputs, perform)
  Drive(..state, lane:)
}

/// Performs one lane output; recording notes are ignored because this client keeps no recording.
fn perform(output: session_channel.Out(connection.Connection, Nil)) -> Nil {
  case output {
    session_channel.Transmit(socket, frame) -> connection.send(socket, frame)
    session_channel.Shut(socket) -> connection.close(socket)
    session_channel.Note(..) -> Nil
  }
}

/// Folds one lane update into the drive; refusals and losses end the run with a reason.
///
/// Folds one lane update into the drive. Refusals and losses end the run with
/// a reason; a cut after the prompt was sent may carry the terminal result.
fn absorb(state: Drive, update: session_channel.Update) -> Drive {
  case update {
    session_channel.Captured(cut:, view:, ..) ->
      observe(Drive(..state, view: Some(#(cut, view))), view)
    session_channel.Acknowledged(..) -> acknowledged(state)
    session_channel.Failed(reason:) -> ended(state, Failed(reason))
    session_channel.RequestRefused(command:, code:, ..) ->
      ended(state, Failed(command <> " refused: " <> code))
    session_channel.UnknownOutcome(command:, ..) ->
      ended(state, Failed(command <> " reply was lost"))
    session_channel.Submission(session_channel.DefinitelyNotSent(reason:)) ->
      ended(state, Failed(reason))
    session_channel.Submission(session_channel.Waiting(..))
    | session_channel.Submission(session_channel.Sent(..))
    | session_channel.HistoryPage(..)
    | session_channel.LineagePage(..)
    | session_channel.LookedUp(..)
    | session_channel.Auxiliary(..)
    | session_channel.Streamed(..)
    | session_channel.ToolStreamed(..)
    | session_channel.Noticed(..) -> state
  }
}

fn ended(state: Drive, verdict: Verdict) -> Drive {
  case state.ended {
    Some(_) -> state
    None -> Drive(..state, ended: Some(verdict))
  }
}

/// Reads a cut for the terminal result, but only once the prompt has been sent.
///
/// A result is only meaningful once the prompt has gone out; before that the
/// session has no run, so a cut is only remembered.
fn observe(state: Drive, view: snapshot_view.View) -> Drive {
  case state.stage {
    AwaitingPrompt ->
      case settle(view) {
        Some(verdict) -> ended(state, verdict)
        None -> state
      }
    NeedsModel(..) | AwaitingModel | NeedsPrompt -> state
  }
}

/// Advances the stage on the daemon's acknowledgement of the request in flight.
fn acknowledged(state: Drive) -> Drive {
  case state.stage {
    AwaitingModel -> Drive(..state, stage: NeedsPrompt)
    AwaitingPrompt -> observe_latest(state)
    NeedsModel(..) | NeedsPrompt -> state
  }
}

// The acknowledgement and the cut that holds the result can arrive in
// either order, so the latest cut is read again when the prompt is acked.
fn observe_latest(state: Drive) -> Drive {
  case state.view {
    Some(#(_, view)) -> observe(state, view)
    None -> state
  }
}

/// Sends the next command when the lane can take a mutation.
///
/// Sends the next command once the lane can take a mutation.
fn advance(state: Drive, request: Request, now: Int) -> Drive {
  let ready =
    session_channel.synchronized(state.lane)
    && session_channel.mutation_available(state.lane)

  // The next command goes out only when the lane can take a mutation.
  case ready, state.stage {
    False, _ -> state
    True, NeedsModel(name:) ->
      submit(
        state,
        session_protocol.set_model(2, main_strand, name),
        AwaitingModel,
        now,
      )
    True, NeedsPrompt ->
      submit(
        state,
        session_protocol.prompt(3, main_strand, request.prompt),
        AwaitingPrompt,
        now,
      )
    True, AwaitingModel | True, AwaitingPrompt -> state
  }
}

/// Admits one frame to the lane and moves to the stage that awaits its acknowledgement.
fn submit(state: Drive, frame: String, next: Stage, now: Int) -> Drive {
  let #(lane, disposition) = session_channel.submit(state.lane, frame, now:)
  let state = Drive(..state, lane:, stage: next)

  // A refused submission ends the run; an admitted one waits for its ack.
  case disposition {
    session_channel.DefinitelyNotSent(reason:) -> ended(state, Failed(reason))
    session_channel.Waiting(..) | session_channel.Sent(..) -> state
  }
}

// --- retiring the session ----------------------------------------------------

// How long the daemon may take to release a stopped session.
const stop_wait_ms = 30_000

/// Stops the session unless the caller asked to keep it; a failed stop is reported, never fatal.
fn retire(retention: Retention, host: selection.Host, session: String) -> Nil {
  case retention {
    KeepSession -> Nil
    StopAtExit ->
      case stop(host, session) {
        Ok(Nil) -> Nil
        Error(reason) ->
          io.println_error(
            "loom run: session " <> session <> " not stopped: " <> reason,
          )
      }
  }
}

/// Asks the daemon to stop the session and waits until it reports it saved.
///
/// One stop request, then reads of the registration until the daemon reports
/// it saved: the daemon's own proof that ordered cleanup released the slot.
/// `loom acp` retires the sessions it created the same way.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(Nil) = run.stop(host, session_id)
/// ```
pub fn stop(host: selection.Host, session: String) -> Result(Nil, String) {
  use host <- selection.with_live_control(host)
  let request = fn(command, within) {
    daemon.request(selection.control(host), command, within)
    |> result.map_error(selection.failure)
  }
  use reply <- result.try(request(protocol.StopSession(session), 10_000))

  // Only an acknowledged stop in flight needs the wait for the saved state.
  case reply {
    protocol.LifecycleReply(protocol.Stopping(_)) ->
      await_saved(session, request)
    protocol.LifecycleReply(protocol.Saved) -> Ok(Nil)
    _ -> Error("stop returned an unexpected reply")
  }
}

/// Reads the registration until it is saved, the daemon's proof that cleanup released the slot, or the wait runs out.
fn await_saved(
  session: String,
  request: fn(protocol.Command, Int) -> Result(protocol.Reply, String),
) -> Result(Nil, String) {
  let outcome =
    poll.until(within: stop_wait_ms, every: 50, attempt: fn() {
      case request(protocol.GetSession(session), 5000) {
        Ok(protocol.SessionReply(protocol.Session(status: protocol.Saved, ..))) ->
          poll.Done(Nil)
        Ok(_) -> poll.Retry
        Error(reason) -> poll.Fail(reason)
      }
    })

  // The daemon reports the session saved once cleanup released its slot.
  case outcome {
    poll.Answered(Nil) -> Ok(Nil)
    poll.Failed(reason) -> Error(reason)
    poll.Expired -> Error("the session was still stopping")
  }
}

// --- the jail label ----------------------------------------------------------

/// Finds the helper beside the server executable the launcher resolves and runs its self-test, or says why it cannot.
///
/// Runs `<helper> --self-test` once with its output written to a file under
/// the state root, so none of it reaches standard output, which belongs to the
/// report. `sh` only redirects; the helper is a positional argument, never
/// spliced into the script text.
fn measure_posture(options: bootstrap.Options, scratch: String) -> Posture {
  // Without a resolvable server there is no helper to ask.
  case bootstrap.server_executable(options.server) {
    Error(_) -> Unverified("no server executable to find the helper beside")
    Ok(server) -> {
      let helper = filepath.join(filepath.directory_name(server), "loom-exec")

      // Without the sibling helper there is nothing to run the self-test with.
      case host_bootstrap.is_executable_file(helper) {
        False -> Unverified("no loom-exec beside the server executable")
        True -> self_test(helper, scratch)
      }
    }
  }
}

/// Runs `<helper> --self-test` with its output in a file under the state root and labels the result.
fn self_test(helper: String, scratch: String) -> Posture {
  let output =
    filepath.join(
      scratch,
      "run-selftest-"
        <> int.to_string(host_bootstrap.current_process_id())
        <> ".txt",
    )
  let status =
    ffi_terminal.run_forwarding("/bin/sh", [
      "-c",
      "\"$1\" --self-test >\"$2\" 2>&1",
      "loom-run",
      helper,
      output,
    ])
  let report = read_report(output)

  // A helper that could not even start leaves the jail unverified.
  case status {
    Ok(code) -> posture_of(code, report)
    Error(reason) -> Unverified("self-test did not run: " <> reason)
  }
}

// The report is read once and the file removed; a missing file reads as an
// empty report, which `posture_of` refuses to label.
fn read_report(path: String) -> String {
  let text = simplifile.read(path) |> result.unwrap("")
  let _ = simplifile.delete(path)
  text
}
