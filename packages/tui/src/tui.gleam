//// A pure-Gleam Loom terminal client built on etui.
////
//// The terminal process owns one immutable `Model`. Keyboard, mouse, paste,
//// websocket, and periodic inbox events each reduce that model before `view`
//// renders the next frame; no widget owns hidden conversation state. The
//// websocket actor owns transport I/O, while this process alone decides which
//// frozen ClientGateway command an operator action means. Durable entries
//// replace matching transient streams, keeping replay and live output from
//// appearing twice at the settlement boundary.
////
//// This module holds the entry points (`main` and the launch parsing,
//// `new_model`, `loop`, `run_script`, `replay_steps`, `connect_remote`) and
//// the event dispatch (`update`, `apply_input`, `settle_update`). The work
//// each event does lives in the modules under `tui/`, which form a strict
//// import order because Gleam forbids cycles and none of them may import
//// this one: `tui/model` holds the `Model` record and its types;
//// `tui/transcript_lines` builds transcript lines; `tui/layout` computes
//// screen geometry and `tui/render` paints it; `tui/outbound` sends command
//// frames; `tui/surfaces` services the side-surface reads; `tui/inbound`
//// applies channel traffic; `tui/session_control` runs daemon control
//// requests; `tui/projection` maintains the transcript row caches;
//// `tui/submit` handles composer submission; `tui/interaction` handles keys,
//// pastes and the mouse; and `tui/tick` drains the inboxes on each tick.
////
//// The split is also a compile-time measure. Gleam compiles every module
//// with the Erlang inliner, which never attempts a call into another
//// module, so a long chain of steps applied to an expensive expression is
//// only a hazard inside one module. `docs/execution.md` §8 has the history.

import argv
import etui/app
import etui/backend
import etui/backend/default
import etui/buffer
import etui/geometry
import etui/keys
import etui/widgets/textarea as text_area
import gleam/bit_array
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import gleam/string
import host/bootstrap as host_bootstrap
import host/build_identity
import host/endpoint
import simplifile
import tui/advisor_history
import tui/agent_strip
import tui/agents
import tui/appearance
import tui/attachment
import tui/attempt
import tui/attempt_replay
import tui/bootstrap
import tui/completion_summary
import tui/connection
import tui/context_view
import tui/daemon
import tui/daemon/protocol as control_protocol
import tui/daemon/selection as daemon_selection
import tui/effect
import tui/frame
import tui/history_view
import tui/inbound
import tui/interaction
import tui/internal/ffi_terminal
import tui/layout
import tui/model.{
  type Model, Assistant, DiffAutomatic, Disconnected, HoldGoalReport, Line,
  Model, Newer, NoClipboard, NoOverlay, Older, Preview, PromptNext, Reasoning,
  ReconnectIdle, Replaying, System, TerminalClipboard, ToolResult,
} as tui_model
import tui/note_panel
import tui/pacing
import tui/projection
import tui/queue_editor
import tui/recording
import tui/render
import tui/runtime
import tui/session_channel
import tui/session_control
import tui/sessions
import tui/summary_panel
import tui/surfaces
import tui/text_hygiene
import tui/tick
import tui/update
import tui/update/download
import tui/update/options as update_options
import tui/virtual_backend
import tui/workspace
import tui/worktree_view

type Launch {
  // Build reporting reads launcher metadata without opening a terminal or daemon.
  Version

  Demo
  Local(bootstrap.Options, selected: String)
  Remote(address: String, session: String, token: String)
  Invalid(reason: String)

  // `loom ext …` is not a terminal application at all: it is a
  // passthrough to `loomd`, whose own `ext` subcommand owns every verb.
  // Forwarding rather than reimplementing is what stops the launcher and
  // the server disagreeing about what an install did.
  Forward(arguments: List(String))

  // Updates run before terminal setup and own their daemon restart policy.
  Update(arguments: List(String))

  // `loom replay …` is not one either: it installs no terminal state and
  // opens no socket. It plays a recording through the virtual backend and
  // prints frames, which is how an agent with no terminal sees what the
  // client would have drawn.
  //
  // Only the last frame is reproducible across runs. The client renders a
  // paced event's frame or leaves the previous one on screen depending on
  // how long ago it last drew, so which of the two `--at` and `--all` show
  // for a key press depends on the machine; the settling tick before the
  // last frame is a flush point, so that one is always the current frame.
  // A recording's own first `resize` also supersedes `--width`/`--height`,
  // which therefore only size the frames before it.
  Replay(path: String, frames: FrameSelection, size: backend.TerminalSize)

  // `loom sessions …` installs no terminal state either. It reaches the
  // control endpoint as the owner over the same bootstrap ladder the picker
  // uses, prints one line per row or one line of outcome, and exits with a
  // status. Listing and deleting are the two things the picker could do that
  // a person with no terminal open still needs.
  Sessions(options: bootstrap.Options, command: SessionsCommand)
}

// The two catalogue verbs the launcher owns. `rm` carries its consent so the
// parser settles the question and the runner never re-derives it from flags.
type SessionsCommand {
  ListRegistrations
  RemoveRegistration(session_id: String, consent: Consent)
}

// Whether the person has already agreed to lose a conversation. `--yes` is
// the whole of the second variant; without it the runner asks, and refuses
// when there is no terminal to ask.
type Consent {
  AskAtTerminal
  GivenOnCommandLine
}

// Which of a replay's frames to print. A recording produces one frame per
// event, and the interesting one is almost always the last, so that is the
// default rather than a flag.
type FrameSelection {
  LastFrame
  FrameAt(index: Int)
  AllFrames
}

// The replay flags, gathered before a Launch is built so an unparseable
// combination is one Invalid rather than a half-applied set.
type ReplayOptions {
  ReplayOptions(frames: FrameSelection, width: Int, height: Int)
}

/// Runs the interactive terminal client.
///
/// ## Examples
///
/// ```sh
/// loom --addr ws://127.0.0.1:8080/v1/ws --session demo
/// ```
pub fn main() {
  // `--record` is answered here rather than inside `parse_launch` because
  // it qualifies every interactive launch rather than choosing one, and
  // the local-option parser refuses flags it does not own.
  //
  // The two launches that are not interactive keep their arguments
  // untouched. `loom ext` is a pipe to the server and every word of it is
  // the server's, so a launcher that removed a pair because it recognised
  // the name would silently change what the server was asked to do; a
  // subcommand taking a `--record` of its own is the day that bites, and
  // the passthrough is meant to be the one place that cannot happen.
  // `replay` has its own parser and no recorder to open.
  let raw = argv.load().arguments
  case help_for(raw) {
    Some(usage) -> io.println(usage)
    None -> {
      // Help has already returned. Suppress logger output for launches that
      // may enter the terminal; rejected launches still exit directly without
      // installing terminal state.
      ffi_terminal.silence_logger()

      let #(record, arguments) = case raw {
        ["ext", ..]
        | ["replay", ..]
        | ["sessions", ..]
        | ["update", ..]
        | ["version", ..]
        | ["--version", ..] -> #("", raw)
        _other -> take_flag(raw, "--record")
      }
      let launch = parse_launch(arguments)
      case launch {
        // The passthrough runs before a single line of terminal setup: this
        // process is a pipe for the duration and then it is gone.
        Version -> print_version()
        Forward(arguments:) -> forward(arguments)
        Update(arguments:) -> run_update(arguments)
        Replay(path:, frames:, size:) -> replay(path, frames, size)
        Sessions(options:, command:) -> run_sessions(options, command)
        Invalid(reason) -> rejected_launch(reason)
        Demo | Local(..) | Remote(..) -> interactive_terminal(launch, record)
      }
    }
  }
}

// The launcher owns these values; inspecting another checkout or a live daemon
// here could report a different build than the executable the operator invoked.
fn print_version() -> Nil {
  let identity = build_identity.current()
  let platform =
    host_bootstrap.getenv("LOOM_BUILD_PLATFORM") |> result.unwrap("unknown")
  io.println(
    "loom "
    <> identity.version
    <> "\ncommit "
    <> identity.commit
    <> "\nplatform "
    <> platform,
  )
}

fn version_usage() -> String {
  "usage: loom version\n       loom --version\n\n"
  <> "Print this client's release version, full build commit and platform.\n"
  <> "Runs without starting a terminal or connecting to the daemon.\n"
}

// Update admission has no terminal dependency; its failures retain a shell status.
fn run_update(arguments: List(String)) -> Nil {
  let outcome = {
    use choices <- result.try(update_options.parse(arguments))
    let platform =
      host_bootstrap.getenv("LOOM_BUILD_PLATFORM")
      |> result.unwrap("")
    let temporary = host_bootstrap.getenv("TMPDIR") |> result.unwrap("/tmp")
    update.run(choices, platform, temporary, download.fetch)
  }
  case outcome {
    Ok(Nil) -> Nil
    Error(reason) -> rejected_launch("update: " <> reason)
  }
}

// Reject a detached launch before it can start a daemon or claim the screen.
// The backend also handles later EOF, since a terminal can close after startup.
fn interactive_terminal(launch: Launch, record: String) -> Nil {
  case ffi_terminal.require_terminal() {
    Ok(Nil) -> interactive(launch, record)
    Error(reason) -> rejected_launch(reason)
  }
}

// Help is selected before the logger or the interactive backend exist. A
// command that only describes an invocation must not claim terminal state or
// reach the daemon it is describing. The `--help` and `-h` flags win
// wherever they appear in argv: a launcher that answered them only in
// first position would report the flags before them as unknown, and the
// conventional reading — `loom --demo --help` asks about the launch —
// costs nothing here because every topic usage is a static string.
//
// The bare word `help` is recognised in first position only. Anywhere
// else it is a plausible value — a session id, a recording path, an
// extension name — and intercepting it would break the `loom ext`
// passthrough's promise that every word of it is the server's.
//
// The topic is the first recognised subcommand word anywhere in argv, so
// `loom replay rec.jsonl --help` describes `replay` rather than the whole
// launcher. A help request with no topic word answers the top-level
// usage, which is also what `loom help help` gets: `help` is a
// dispatcher, not a topic.
fn help_for(arguments: List(String)) -> Option(String) {
  let asks = case arguments {
    ["help", ..] -> True
    _ -> list.contains(arguments, "--help") || list.contains(arguments, "-h")
  }
  case asks {
    False -> None
    True ->
      case list.find(arguments, is_topic) {
        Ok("replay") -> Some(replay_usage())
        Ok("sessions") -> Some(sessions_usage())
        Ok("ext") -> Some(extension_usage())
        Ok("update") -> Some(update_options.usage())
        Ok("version") -> Some(version_usage())
        Ok(_other) | Error(Nil) -> Some(launch_usage())
      }
  }
}

fn is_topic(word: String) -> Bool {
  case word {
    "replay" | "sessions" | "ext" | "update" | "version" -> True
    _ -> False
  }
}

// A rejected launch has not earned an alternate-screen session. Reporting it
// directly preserves the shell's stdout/stderr and exit-status contract.
fn rejected_launch(reason: String) -> Nil {
  io.println_error("loom: " <> reason)
  ffi_terminal.halt(1)
  Nil
}

// Removes one `--flag value` pair from an argument list, answering its
// value and what is left. Absence is the empty string rather than an
// error: every caller here treats a missing flag as a default.
fn take_flag(arguments: List(String), flag: String) -> #(String, List(String)) {
  case arguments {
    [] | [_] -> #("", arguments)
    [name, value, ..rest] ->
      case name == flag {
        True -> #(value, rest)
        False -> {
          let #(found, remaining) = take_flag([value, ..rest], flag)
          #(found, [name, ..remaining])
        }
      }
  }
}

// Runs `loomd` with the arguments this launcher was given, streaming its
// output through and exiting with its status. The daemon is located by the
// same ladder an implicit local launch uses, so `loom ext` and an
// auto-started session cannot end up talking to two different binaries.
fn forward(arguments: List(String)) -> Nil {
  case bootstrap.server_executable(flag_or_empty(arguments, "--server")) {
    Error(reason) -> {
      io.println_error("loom ext: " <> reason)
      ffi_terminal.halt(1)
      Nil
    }
    Ok(server) ->
      case ffi_terminal.run_forwarding(server, ["ext", ..arguments]) {
        Ok(status) -> {
          ffi_terminal.halt(status)
          Nil
        }
        Error(reason) -> {
          io.println_error(
            "loom ext: could not run " <> server <> ": " <> reason,
          )
          ffi_terminal.halt(1)
          Nil
        }
      }
  }
}

fn flag_or_empty(arguments: List(String), flag: String) -> String {
  case session_control.flag_value(arguments, flag) {
    Ok(value) -> value
    Error(Nil) -> ""
  }
}

/// A fresh presentation state for one terminal process.
///
/// The inbox and the discovered workspace are the only two facts a model
/// cannot derive, so they are what a caller supplies. Published `@internal`
/// because the virtual-backend harness needs the same starting point the
/// interactive launch uses; a snapshot then overrides the fields it is
/// about with an ordinary record update.
///
/// ## Examples
///
/// ```gleam
/// let model = tui.new_model(connection.new_inbox(), workspace.discover())
/// ```
@internal
pub fn new_model(
  inbox: Subject(connection.Message),
  project: workspace.Context,
) -> Model {
  new_model_with_clock(inbox, project, host_bootstrap.monotonic_time_ms)
}

/// Creates a presentation state whose timing is controlled by its caller.
///
/// The clock seeds the first frame and measures every later presentation
/// interval in the same era. A test may advance it between events without
/// sleeping. Network and bootstrap deadlines retain their real clocks.
///
/// ## Examples
///
/// ```gleam
/// let model = tui.new_model_with_clock(inbox, project, fn() { -10_000 })
/// assert model.last_frame_ms == -10_000
/// ```
@internal
pub fn new_model_with_clock(
  inbox: Subject(connection.Message),
  project: workspace.Context,
  monotonic_time_ms: fn() -> Int,
) -> Model {
  let strands = interaction.demo_strands()
  Model(
    quit: False,
    width: 80,
    height: 24,
    palette: appearance.Dark,
    input: text_area.state_new(),
    strand_workspaces: dict.new(),
    restored_workspace: None,
    attachments: [],
    history: [],
    history_index: 0,
    history_draft: "",
    command_selected: 0,
    submission_mode: PromptNext,
    pending_submission: None,
    interrupt: None,
    submitting: None,
    queued: [],
    awaiting_outcome: None,
    transcript: [
      Line(System, "etui input and gateway paths ready"),
      Line(
        Reasoning,
        "Mapped the frozen ClientGateway events onto one immutable view model.",
      ),
      Line(ToolResult, "read · packages/client/CLAUDE.md"),
      Line(
        Assistant,
        "## Native client\n\nThe pure-Gleam path is live. Use `/model` to switch models or `/help` for the command map.",
      ),
    ],
    records: [],
    cache_watch: dict.new(),
    cache_seen_seq: dict.new(),
    cache_pending: dict.new(),
    cache_fence: dict.new(),
    cache_notices: [],
    cache_outlook: "",
    scrollback: history_view.empty(),
    notice: "interactive design preview",
    queue_editor: queue_editor.new(),
    worktree: worktree_view.new(),
    context: context_view.new(),
    completion: completion_summary.new(),
    completion_owner: "",
    summary_surface: queue_editor.Closed,
    summary_scroll: 0,
    summary_tab: summary_panel.Completion,
    summary_job_selected: 0,
    jobs: None,
    jobs_observed_ms: None,
    jobs_refresh: worktree_view.Settled,
    jobs_awaiting: None,
    jobs_request: None,
    jobs_notice: "Live jobs unavailable; /summary requests a current observation",
    nudges: None,
    nudges_refresh: worktree_view.Settled,
    nudges_awaiting: None,
    nudges_request: None,
    goal: None,
    goal_refresh: worktree_view.Settled,
    goal_awaiting: None,
    goal_request: None,
    goal_report: HoldGoalReport,
    help_open: False,
    notes_open: False,
    diff_view: DiffAutomatic,
    diff_scroll_offset: 0,
    diff_rows: [],
    diff_line_cache: dict.new(),
    diff_row_count: 0,
    diff_worktree_source: #(None, 0),
    note_board: None,
    note_selected: None,
    note_mode: note_panel.Readable,
    note_scroll: 0,
    notes_requested: None,
    overlay: NoOverlay,
    models: interaction.demo_models(),
    skills: [],
    current_model: "baseten-kimi-k3",
    workspace: project,
    strands:,
    agent_summary: agents.summary(strands),
    reviewer_rows: [],
    agent_rows: [],
    agent_messages: [],
    advisor_history: advisor_history.Board(items: [], unloaded: None),
    strip: agent_strip.new(),
    todo_boards: dict.new(),
    todo_seed: None,
    todo_asked: set.new(),
    active_strand: "main",
    session: "demo",
    session_label: None,
    local_options: None,
    inbox:,
    peer: Preview,
    session_switch: sessions.Idle,
    candidate: attachment.idle(),
    channel: None,
    captured: None,
    last_capture: session_channel.Requested,
    notices: 0,
    daemon_host: None,
    control_request: None,
    activity_poll: tui_model.ActivityDue,
    reconnect: ReconnectIdle,
    creation_key: None,
    approvals: [],
    prompted_approvals: [],
    inspecting_approval: None,
    unconfirmed: None,
    next_attempt: 1,
    replay_state: attempt_replay.new(),
    replay_inbox: process.new_subject(),
    replay_error: None,
    next_id: 1,
    usage: inbound.zero_usage(),
    generation_started_ms: None,
    output_rate_tps: None,
    agent_rail_visible: False,
    details_expanded: False,
    repaint_phase: False,
    activity_frame: 0,
    activity_started_ms: None,
    activity_elapsed_s: 0,
    streams: [],
    reading_lines: None,
    tool_tails: [],
    scroll_offset: 0,
    render_revision: 0,
    rendered_revision: -1,
    rendered_row_count: 0,
    rendered_rows: [],
    revealed_rows: 0,
    rendered_anchors: [],
    rendered_gutters: [],
    record_rows: [],
    record_gutters: [],
    record_line_cache: dict.new(),
    compact_call_cache: dict.new(),
    compact_entry_cache: dict.new(),
    pending_records: [],
    record_cache_valid: False,
    record_cache_width: 0,
    record_cache_strand: "",
    record_cache_details: False,
    frame_revision: 0,
    frame_cache: None,
    frame_debt: pacing.FrameSettled,
    monotonic_time_ms:,
    last_frame_ms: monotonic_time_ms(),
    activity_revision: 0,
    quiet_for_ms: pacing.quiet_after_ms,
    recorder: None,
    herdr_reporter: None,
    herdr_published: None,
    outbox: [],
    selection: None,
    selection_frame: None,
    selection_gutters: [],
    clipboard: NoClipboard,
  )
}

fn interactive(launch: Launch, record: String) -> Nil {
  let inbox = connection.new_inbox()
  let base = new_model(inbox, workspace.discover())

  // The recording is opened on the model the launch produced, not on the
  // one it started from: a connected model replaces the transcript and
  // the notice wholesale, so a recorder opened before the connect
  // reported a failed `--record` onto a transcript that was then thrown
  // away, and the operator ran a whole session believing it was being
  // recorded.
  let launched = case launch {
    // Unreachable: `main` answers these before it builds a model.
    Version | Forward(..) | Update(..) | Replay(..) | Sessions(..) | Demo ->
      base
    Local(options, selected) -> {
      // The footer names the workspace the session was launched for, which
      // is only the current directory when no `--workspace` was given; a
      // later `/sessions` switch derives it the same way from its choice.
      let local =
        Model(
          ..base,
          local_options: Some(options),
          workspace: case options.workspace {
            "" -> base.workspace
            path -> workspace.discover_from(path)
          },
        )
      case bootstrap.resolve_daemon(options, process.self(), 90_000) {
        Error(reason) ->
          tui_model.append_error(
            Model(..local, peer: Disconnected, notice: "daemon startup failed"),
            reason,
          )
        Ok(connected) ->
          attach_daemon(
            local,
            connected.control,
            endpoint.address(connected.record),
            connected.paths.token,
            selected,
          )
      }
    }
    Invalid(reason) ->
      tui_model.append_error(Model(..base, notice: "invalid launch"), reason)
    Remote(address, session, token) ->
      connect_remote(base, inbox, address, session, token)
  }

  // Only here does a copy reach a terminal: every other way of running the
  // loop shares stdout with something that is not one.
  let initial =
    open_recording(
      Model(
        ..launched,
        clipboard: TerminalClipboard,
        palette: appearance.detect(
          host_bootstrap.getenv("COLORTERM") |> result.unwrap(""),
          host_bootstrap.getenv("TERM") |> result.unwrap(""),
          host_bootstrap.getenv("COLORFGBG") |> result.unwrap(""),
          host_bootstrap.getenv("NO_COLOR") |> option.from_result,
        ),
      ),
      record,
    )
    |> tick.start_herdr_reporter

  let _ =
    app.run_buffered_cursor_adaptive(
      default.new_with_options(backend.Options(mouse: True, paste: True)),
      initial,
      render.view,
      update,
      fn(model) { model.quit },
      tick.terminal_poll_timeout,
    )
  Nil
}

/// This client's side of etui's loop, for a run under the virtual backend.
///
/// The four functions are exactly the ones `interactive` hands etui, so a
/// scripted run exercises the shipped loop rather than a second one written
/// for tests.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(run) = virtual_backend.run_script(tui.loop(), model, script)
/// ```
@internal
pub fn loop() -> virtual_backend.Loop(Model) {
  virtual_backend.Loop(
    update: update,
    view: render.view,
    should_quit: fn(model: Model) { model.quit },
    poll_timeout: tick.terminal_poll_timeout,
  )
}

/// Drives one script through the real loop and returns the frames it drew.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(run) = tui.run_script(model, script)
/// ```
@internal
pub fn run_script(
  model: Model,
  script: virtual_backend.Script,
) -> Result(virtual_backend.Run(Model), String) {
  virtual_backend.run_script(loop(), model, script)
}

// A failed recording is a visible local error rather than a refused
// launch: the session is still worth having, and the operator is told on
// the frame that nothing is being written.
fn open_recording(model: Model, record: String) -> Model {
  case record {
    "" -> model
    path ->
      case recording.start(path) {
        Ok(recorder) ->
          Model(
            ..model,
            recorder: Some(recorder),
            notice: "recording",
            candidate: attachment.with_trace(
              model.candidate,
              recording.trace(
                Some(recorder),
                attempt.Id(model.next_attempt - 1),
              ),
            ),
          )
        Error(reason) -> tui_model.append_error(model, reason)
      }
  }
}

/// Opens the same post-launch recorder used by the interactive terminal.
///
/// Initial candidate mail is still terminal-owned and cannot be consumed
/// before this binding. The native driver uses this seam to prove fast startup.
///
/// ## Examples
///
/// ```gleam
/// // tui.with_recording(launched, path)
/// ```
@internal
pub fn with_recording(model: Model, path: String) -> Model {
  open_recording(model, path)
}

fn parse_launch(arguments: List(String)) -> Launch {
  case arguments {
    [] -> Local(default_bootstrap_options(), "")
    ["--demo"] -> Demo
    ["version"] | ["--version"] -> Version
    ["version", ..] | ["--version", ..] -> Invalid(version_usage())
    ["ext", ..rest] -> Forward(arguments: rest)
    ["update", ..rest] -> Update(arguments: rest)
    ["help", "ext"] -> Forward(arguments: ["--help"])
    ["replay", ..rest] -> parse_replay(rest)
    ["sessions", ..rest] -> parse_sessions(rest)
    _ ->
      case
        session_control.flag_value(arguments, "--addr"),
        session_control.flag_value(arguments, "--session")
      {
        Ok(address), Ok(session) ->
          case launch_token(arguments) {
            Ok(token) -> Remote(address:, session:, token:)
            Error(reason) -> Invalid(reason)
          }
        Ok(_), Error(_) -> Invalid(launch_usage())
        Error(_), selection ->
          case parse_local_options(arguments, default_bootstrap_options()) {
            Ok(options) -> Local(options, result.unwrap(selection, ""))
            Error(reason) -> Invalid(reason <> "\n" <> launch_usage())
          }
      }
  }
}

// `--yes` and the verb are read before the shared local options, because
// `parse_local_options` refuses a flag it does not own and both of these are
// the sessions parser's.
fn parse_sessions(arguments: List(String)) -> Launch {
  let #(consent, rest) = case take_switch(arguments, "--yes") {
    #(True, remaining) -> #(GivenOnCommandLine, remaining)
    #(False, remaining) -> #(AskAtTerminal, remaining)
  }
  case rest {
    ["list", ..flags] -> sessions_launch(flags, ListRegistrations)
    ["rm", id, ..flags] ->
      sessions_launch(flags, RemoveRegistration(id, consent))
    ["rm"] -> Invalid("sessions rm needs a session id\n" <> sessions_usage())
    _unknown -> Invalid(sessions_usage())
  }
}

fn sessions_launch(flags: List(String), command: SessionsCommand) -> Launch {
  case parse_local_options(flags, default_bootstrap_options()) {
    Ok(options) -> Sessions(options:, command:)
    Error(reason) -> Invalid(reason <> "\n" <> sessions_usage())
  }
}

// Removes one valueless flag, answering whether it was present and what is
// left. `take_flag` cannot serve here: it consumes the following word, and
// `--yes` is followed by the verb.
fn take_switch(arguments: List(String), flag: String) -> #(Bool, List(String)) {
  case arguments {
    [] -> #(False, [])
    [name, ..rest] ->
      case name == flag {
        True -> #(True, rest)
        False -> {
          let #(found, remaining) = take_switch(rest, flag)
          #(found, [name, ..remaining])
        }
      }
  }
}

fn sessions_usage() -> String {
  "usage: loom sessions list [--state-dir <path>] [--server <path>]\n"
  <> "       loom sessions rm <session-id> [--yes] [--state-dir <path>]\n"
  <> "  rm asks for confirmation unless --yes is given, and refuses a\n"
  <> "  session the daemon still holds open; stop it first"
}

// One catalogue action over a control connection this process owns for the
// length of the command. Nothing is retained: the connection closes before
// the exit status is chosen, so a refusal and a success leave the daemon in
// the same state as far as this launcher is concerned.
fn run_sessions(options: bootstrap.Options, command: SessionsCommand) -> Nil {
  case sessions_host(options) {
    Error(reason) -> sessions_failed(reason)
    Ok(#(control, host)) -> {
      let outcome = case command {
        ListRegistrations -> list_registrations(host)
        RemoveRegistration(session_id:, consent:) ->
          remove_registration(host, session_id, consent)
      }
      daemon.close(control)
      case outcome {
        Ok(report) -> io.println(report)
        Error(reason) -> sessions_failed(reason)
      }
    }
  }
}

fn sessions_failed(reason: String) -> Nil {
  io.println_error("loom sessions: " <> reason)
  ffi_terminal.halt(1)
  Nil
}

// The picker's own ladder: resolve or start the shared daemon, read the
// owner credential from the state root, and authenticate one control socket.
fn sessions_host(options: bootstrap.Options) {
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
  use host <- result.map(daemon_selection.host(
    connected.control,
    address,
    string.trim(token),
  ))
  #(connected.control, host)
}

fn list_registrations(host: daemon_selection.Host) -> Result(String, String) {
  use rows <- result.map(registration_rows(host, "", [], 100))
  case rows {
    [] -> "no sessions"
    rows -> string.join(list.map(rows, registration_line), "\n")
  }
}

// Pagination is followed to its end so the listing is the whole catalogue
// rather than its first hundred rows. The page budget is what stops a daemon
// answering with a cursor that never advances from looping here forever.
fn registration_rows(
  host: daemon_selection.Host,
  after: String,
  accumulated: List(control_protocol.Session),
  remaining: Int,
) -> Result(List(control_protocol.Session), String) {
  case remaining > 0 {
    False -> Error("session listing did not terminate")
    True -> {
      use page <- result.try(daemon_selection.list(host, after))
      let rows = list.append(accumulated, page.sessions)
      case page.after {
        None -> Ok(rows)
        Some(next) -> registration_rows(host, next, rows, remaining - 1)
      }
    }
  }
}

fn registration_line(row: control_protocol.Session) -> String {
  row.session_id
  <> "  "
  <> registration_state(row.status)
  <> "  "
  <> row.workspace
  <> "  "
  <> text_hygiene.single_line(row.name)
}

fn registration_state(status: control_protocol.Lifecycle) -> String {
  case status {
    control_protocol.Saved -> "saved"
    control_protocol.Reserved -> "reserved"
    control_protocol.Opening(_) -> "opening"
    control_protocol.Resident(_) -> "resident"
    control_protocol.Stopping(_) -> "stopping"
    control_protocol.RecoveryBlocked -> "blocked"
  }
}

fn remove_registration(
  host: daemon_selection.Host,
  session_id: String,
  consent: Consent,
) -> Result(String, String) {
  use Nil <- result.try(case consent {
    GivenOnCommandLine -> Ok(Nil)
    AskAtTerminal -> asked(session_id)
  })
  use deleted <- result.map(daemon_selection.delete(host, session_id))
  "deleted " <> deleted
}

// Anything but an explicit yes cancels, including an empty line, so the
// default of a mistyped answer is to keep the conversation.
fn asked(session_id: String) -> Result(Nil, String) {
  use reply <- result.try(ffi_terminal.read_console_reply(
    "delete " <> session_id <> " and its conversation database? [y/N] ",
  ))
  case string.lowercase(string.trim(reply)) {
    "y" | "yes" -> Ok(Nil)
    _refused -> Error("cancelled; nothing was deleted")
  }
}

fn default_bootstrap_options() -> bootstrap.Options {
  bootstrap.Options("", "", "", "", "")
}

fn parse_local_options(
  arguments: List(String),
  options: bootstrap.Options,
) -> Result(bootstrap.Options, String) {
  case arguments {
    [] -> Ok(options)
    [flag] -> Error("missing value for " <> flag)
    [flag, value, ..rest] ->
      case flag {
        "--workspace" ->
          parse_local_options(
            rest,
            bootstrap.Options(..options, workspace: value),
          )
        "--session" -> parse_local_options(rest, options)
        "--server" ->
          parse_local_options(rest, bootstrap.Options(..options, server: value))
        "--state-dir" ->
          parse_local_options(
            rest,
            bootstrap.Options(..options, state_directory: value),
          )
        "--config" ->
          parse_local_options(rest, bootstrap.Options(..options, config: value))
        _ -> Error("unknown local launch option " <> flag)
      }
  }
}

fn launch_token(arguments: List(String)) -> Result(String, String) {
  case session_control.flag_value(arguments, "--token-file") {
    Ok(path) ->
      simplifile.read(path)
      |> result.map(string.trim)
      |> result.map_error(fn(error) {
        "cannot read --token-file " <> path <> ": " <> string.inspect(error)
      })
    Error(Nil) ->
      Ok(session_control.flag_value(arguments, "--token") |> result.unwrap(""))
  }
}

fn launch_usage() -> String {
  "usage: loom [--workspace <path>] [--session <id>] "
  <> "[--server <path>] [--state-dir <path>] [--config <loom.toml>]\n"
  <> "       loom <command> [options]\n\n"
  <> "commands:\n"
  <> "  version            Print version, build commit and platform.\n"
  <> "  update [TAG|COMMIT]  Install a release and restart the daemon.\n"
  <> "  replay <path>       Render a recorded terminal session.\n"
  <> "  sessions list|rm    List or remove saved sessions.\n"
  <> "  ext <command>       Manage daemon extensions.\n\n"
  <> "  --config defaults to <state-dir>/loom.toml when that file exists\n"
  <> "  --record <path> writes every event to a replayable recording\n"
  <> "       loom --addr <websocket-url> --session <id> "
  <> "[--token-file <path> | --token <bearer>]\n"
  <> "       loom replay <path> [--at <frame>] [--all] "
  <> "[--width <w>] [--height <h>]\n"
  <> "  the last frame is reproducible; a frame before a settling tick "
  <> "may differ between runs\n"
  <> "  --width/--height size the replay until the recording's own first "
  <> "resize supersedes them"
}

fn replay_usage() -> String {
  "usage: loom replay <path> [--at <frame>] [--all] "
  <> "[--width <w>] [--height <h>]\n"
  <> "  Render the last frame by default; --all prints every frame."
}

// This copy deliberately stays private to the client-only shipment. `loom`
// must describe extension commands even when `loomd` is absent, while the
// terminal package cannot import the daemon package without reversing the
// dependency boundary. The shipped acceptance compares this text with
// `loomd ext --help` so the two literals cannot silently drift.
fn extension_usage() -> String {
  "usage: loom ext <command>\n"
  <> "  install <source> [--rev <r>] [--home <dir>] [--helper <path>]\n"
  <> "                   [--codemode-seed <dir>] [--best-effort]\n"
  <> "  list\n"
  <> "  remove <name>\n"
  <> "  verify <name>\n\n"
  <> "A source is a local path, an https:// .tar.gz, or an\n"
  <> "https://github.com/<owner>/<repo> URL. Extensions install under\n"
  <> "<home>/.loom/extensions."
}

fn parse_replay(arguments: List(String)) -> Launch {
  case arguments {
    [] -> Invalid("replay needs a recording path\n" <> launch_usage())
    [path, ..options] ->
      case
        parse_replay_options(
          options,
          ReplayOptions(frames: LastFrame, width: 80, height: 24),
        )
      {
        Ok(ReplayOptions(frames:, width:, height:)) ->
          Replay(path:, frames:, size: backend.TerminalSize(width:, height:))
        Error(reason) -> Invalid(reason <> "\n" <> launch_usage())
      }
  }
}

// `--all` takes no value, so the list is walked one element at a time and
// the flags that do take one consume the next themselves.
fn parse_replay_options(
  arguments: List(String),
  options: ReplayOptions,
) -> Result(ReplayOptions, String) {
  case arguments {
    [] -> Ok(options)
    ["--all", ..rest] ->
      parse_replay_options(rest, ReplayOptions(..options, frames: AllFrames))
    [flag] -> Error("missing value for " <> flag)
    [flag, value, ..rest] -> {
      use options <- result.try(replay_option(options, flag, value))
      parse_replay_options(rest, options)
    }
  }
}

fn replay_option(
  options: ReplayOptions,
  flag: String,
  value: String,
) -> Result(ReplayOptions, String) {
  use number <- result.try(
    int.parse(value)
    |> result.map_error(fn(_) {
      flag <> " needs a number, not \"" <> value <> "\""
    }),
  )

  // Each range is checked where the flag is read. `list.drop` treats a
  // negative count as none, so a negative `--at` would print the first
  // frame rather than the worded error its own arm promises, and a screen
  // of no cells renders nothing to compare.
  case flag {
    "--at" ->
      case number >= 0 {
        True -> Ok(ReplayOptions(..options, frames: FrameAt(index: number)))
        False -> Error("--at cannot be negative, got " <> value)
      }
    "--width" ->
      case number > 0 {
        True -> Ok(ReplayOptions(..options, width: number))
        False -> Error("--width needs at least one cell, got " <> value)
      }
    "--height" ->
      case number > 0 {
        True -> Ok(ReplayOptions(..options, height: number))
        False -> Error("--height needs at least one cell, got " <> value)
      }
    _ -> Error("unknown replay option " <> flag)
  }
}

// The agent-facing surface: a recording in, frames out, and a non-zero
// status with a worded reason for anything that stops that happening.
fn replay(
  path: String,
  frames: FrameSelection,
  size: backend.TerminalSize,
) -> Nil {
  case replay_recording(path, size) {
    Ok(rendered) -> print_frames(rendered, frames)
    Error(reason) -> {
      io.println_error("loom replay: " <> reason)
      ffi_terminal.halt(1)
      Nil
    }
  }
}

fn replay_recording(
  path: String,
  size: backend.TerminalSize,
) -> Result(List(buffer.Buffer), String) {
  use moments <- result.try(recording.decode_file(path))
  replay_steps(recording.to_steps(moments), size)
}

/// Runs a decoded recording through the real loop and returns its frames.
///
/// The starting workspace is a fixed placeholder rather than the current
/// directory: a recording carries no workspace, and a replay whose footer
/// changed with the shell it was run from would be a poor golden file and
/// a confusing answer.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(frames) =
///   tui.replay_steps(steps, backend.TerminalSize(width: 80, height: 24))
/// ```
@internal
pub fn replay_steps(
  steps: List(virtual_backend.Step),
  size: backend.TerminalSize,
) -> Result(List(buffer.Buffer), String) {
  let inbox = connection.new_inbox()
  let model =
    Model(
      ..new_model(inbox, workspace.Context(path: "replay", branch: None)),
      peer: Replaying,
      transcript: [],
      // The demo catalogue goes with the demo peer. `connect_remote`
      // empties it for the same reason: a client shows the models the
      // server named, and a replay whose recording never carried a
      // catalogue snapshot must show the empty selector the live client
      // showed, not four invented entries.
      models: [],
      skills: [],
      session: "replay",
      strands: [],
      agent_summary: agents.summary([]),
      reviewer_rows: [],
      notice: "replaying",
    )
  use run <- result.try(run_script(
    model,
    virtual_backend.script(size, steps, inbox)
      |> virtual_backend.with_attempts(model.replay_inbox),
  ))
  case run.final.replay_error {
    None -> Ok(run.frames)
    Some(reason) -> Error(reason)
  }
}

fn print_frames(frames: List(buffer.Buffer), selection: FrameSelection) -> Nil {
  case selection {
    AllFrames ->
      list.index_fold(frames, Nil, fn(_acc, drawn, index) {
        io.println(frame_separator(index))
        io.println(frame.buffer_to_text(drawn))
      })

    // A missing frame is a real failure rather than an empty print: it
    // means the recording had fewer events than the caller believed.
    LastFrame -> print_one(list.last(frames), "the recording drew no frames")
    FrameAt(index:) ->
      print_one(
        list.drop(frames, index) |> list.first,
        "the recording has no frame " <> int.to_string(index),
      )
  }
}

fn print_one(frame_result: Result(buffer.Buffer, Nil), missing: String) -> Nil {
  case frame_result {
    Ok(drawn) -> io.println(frame.buffer_to_text(drawn))
    Error(Nil) -> {
      io.println_error("loom replay: " <> missing)
      ffi_terminal.halt(1)
      Nil
    }
  }
}

fn frame_separator(index: Int) -> String {
  string.repeat("\u{2500}", 8) <> " frame " <> int.to_string(index) <> " "
}

/// Attaches a model through the same handshake as an interactive launch.
///
/// The caller owns the model's inbox and must run the terminal loop in
/// that process. Tests use this seam so their initial subscriptions cannot
/// drift from the subscriptions a shipped client sends.
///
/// ## Examples
///
/// ```gleam
/// let attached = tui.connect_remote(model, model.inbox, address, session, token)
/// ```
@internal
pub fn connect_remote(
  base: Model,
  inbox: Subject(connection.Message),
  address: String,
  session: String,
  token: String,
) -> Model {
  let base = live_base(Model(..base, inbox: inbox))
  let connected = {
    use address <- result.try(daemon_selection.control_address(address))
    use control <- result.try(
      daemon.connect(address, token, process.self(), 5000)
      |> result.map_error(daemon_selection.failure),
    )
    daemon_selection.host(control, address, token)
  }
  case connected {
    Error(reason) -> tui_model.append_error(base, reason)
    Ok(host) -> {
      let model = Model(..base, daemon_host: Some(host))
      case session {
        "" -> session_control.load_catalogue(model, "", None)
        id -> session_control.begin_open(model, id)
      }
    }
  }
}

fn live_base(base: Model) -> Model {
  Model(
    ..base,
    peer: Disconnected,
    session: "",
    models: [],
    skills: [],
    strands: [],
    records: [],
    streams: [],
    tool_tails: [],
    transcript: [],
    current_model: "unconfigured",
    agent_summary: agents.summary([]),
    reviewer_rows: [],
    advisor_history: advisor_history.Board(items: [], unloaded: None),
    notice: "select a saved session or create one",
  )
}

fn attach_daemon(
  base: Model,
  control: daemon.Connection,
  address: Result(String, String),
  token_path: String,
  selected: String,
) -> Model {
  let host = {
    use address <- result.try(address)
    use bytes <- result.try(host_bootstrap.read_private_bounded(token_path, 65))
    use token <- result.try(
      bit_array.to_string(bytes)
      |> result.replace_error("invalid owner credential encoding"),
    )
    daemon_selection.host(control, address, string.trim(token))
  }
  let base = live_base(base)
  case host {
    Error(reason) -> {
      daemon.close(control)
      tui_model.append_error(base, reason)
    }
    Ok(host) -> {
      let model =
        Model(
          ..base,
          daemon_host: Some(host),
          transcript: inbound.daemon_build_lines(Some(host)),
        )
      case selected {
        "" -> session_control.load_catalogue(model, "", None)
        id -> session_control.begin_open(model, id)
      }
    }
  }
}

/// Applies one terminal event and performs the effects it decided on.
///
/// This is the function etui and the virtual backend call: `step`, then
/// `runtime.perform` on what the step returned. Everything that inspects a
/// transition without acting on it calls `step` instead.
///
/// ## Examples
///
/// ```gleam
/// let next = tui.update(backend.Tick, model)
/// ```
@internal
pub fn update(event: backend.InputEvent, model: Model) -> Model {
  let #(model, effects) = step(event, model)
  runtime.perform(effects)
  model
}

/// Applies one terminal event and returns the effects it decided on,
/// without performing them.
///
/// The reducer queues its I/O as `effect.Effect` values rather than doing
/// it, and this collects them, together with whatever was still queued
/// from a caller that drove a reducer outside the loop. The returned model
/// has empty queues. Phase 1 of issue #530 covers the fire-and-forget
/// effects; mailbox drains, job starts, clock reads, file reads and
/// recording appends still happen during the step.
///
/// ## Examples
///
/// ```gleam
/// let #(next, effects) = tui.step(backend.KeyPress(enter), model)
/// ```
@internal
pub fn step(
  event: backend.InputEvent,
  model: Model,
) -> #(Model, List(effect.Effect)) {
  // Before the event is interpreted, so a recording holds what the client
  // was given rather than what it made of it.
  recording.note_input(model.recorder, event)

  let updated = apply_input(event, model)
  runtime.take(settle_update(event, model, updated))
}

// The dispatch on the event and the settling of its result are two functions
// rather than one body. `apply_input` is a readability split the build does
// not depend on. `settle_update` is load-bearing, and the property it
// carries is that its steps apply to a function parameter. The Erlang
// inliner tries to expand every local call, and an attempt it abandons for
// effort restores the state it started from, including its cache of visited
// expressions. When the settling steps sat in this body, each step's attempt
// visited the whole dispatched expression — every arm, and the tick's drain
// chain beneath it — and threw the visit away for the next step to repeat.
// Six steps made that about sixty-four visits, and the module took over a
// minute to compile. A parameter is cheap to re-visit, so the same steps in
// `settle_update` cost a constant number of visits and the module compiles
// in a few seconds. Hiding the dispatch behind a call while the steps stay
// in the caller does not help and measured worse. Folding the steps back
// into `update` restores the blow-up; measure with `erlc +time` on the
// generated module before doing so. Most settling steps are now calls into
// sibling modules, which the inliner never attempts. The boundary stays
// because `snap_viewport_for` is still a local step, and any local step
// added to `update` would reintroduce the cost.
fn apply_input(event: backend.InputEvent, model: Model) -> Model {
  case event {
    // A selection is screen cells over a layout the resize just replaced,
    // so it goes with the old layout rather than surviving as a highlight
    // over whatever now occupies those cells.
    backend.Resize(width, height) ->
      Model(
        ..model,
        width:,
        height:,
        selection: None,
        selection_frame: None,
        selection_gutters: [],
      )
      |> tui_model.mark_activity
      |> tui_model.invalidate_frame
    backend.Tick -> tick.update_tick(model)

    // A keyboard burst can arrive before an idle tick even when the final
    // server reply is already queued. Apply bounded ready progress before
    // interpreting the action, without starting another periodic capture.
    backend.KeyPress(key) ->
      interaction.update_ready_key(keys.match(key), model)
      |> tui_model.mark_activity
      |> tui_model.invalidate_frame
    backend.Paste(text) ->
      interaction.handle_paste(interaction.clear_selection(model), text)
      |> tui_model.mark_activity
      |> tui_model.invalidate_frame

    // A wheel flick delivers notches faster than any poll timeout, so no
    // tick arrives until the hand pauses. Draining here, as a key does,
    // keeps the history page this gesture asked for from waiting on that
    // pause and then landing with every capture queued behind it.
    backend.MouseScroll(x, y, up) ->
      inbound.drain_connection(model, 64)
      |> interaction.clear_selection
      |> interaction.scroll_at(geometry.Position(x, y), case up {
        True -> Older
        False -> Newer
      })
      |> tui_model.mark_activity
      |> tui_model.invalidate_frame

    // The left button is the selection button, as in every terminal. The
    // other two are listed so a new etui button is a compile error here.
    backend.MousePress(x, y, backend.MouseLeft) ->
      interaction.begin_selection(model, geometry.Position(x, y))
      |> tui_model.mark_activity
      |> tui_model.invalidate_frame

    // A held drag is the other gesture that outruns the poll timeout, for as
    // long as the button is down. The selection reads the frame it began
    // on, so the traffic applied here cannot move the cells under it.
    backend.MouseDrag(x, y, backend.MouseLeft) ->
      inbound.drain_connection(model, 64)
      |> interaction.extend_selection(geometry.Position(x, y))
      |> tui_model.mark_activity
      |> tui_model.invalidate_frame
    backend.MouseRelease(x, y, backend.MouseLeft) ->
      interaction.finish_selection(model, geometry.Position(x, y))
      |> tui_model.mark_activity
      |> tui_model.invalidate_frame
    backend.MousePress(_, _, backend.MouseMiddle)
    | backend.MousePress(_, _, backend.MouseRight)
    | backend.MouseDrag(_, _, backend.MouseMiddle)
    | backend.MouseDrag(_, _, backend.MouseRight)
    | backend.MouseRelease(_, _, backend.MouseMiddle)
    | backend.MouseRelease(_, _, backend.MouseRight)
    | backend.MouseMove(..) -> model
  }
}

// Everything an event does after its own handler: the worktree request a
// newly shown diff needs, the context sync, the Herdr report, the transcript
// projection, the viewport snap and the frame decision. `model` is the
// state before the event and `updated` the state its handler produced.
fn settle_update(
  event: backend.InputEvent,
  model: Model,
  updated: Model,
) -> Model {
  let updated = case !layout.diff_shown(model) && layout.diff_shown(updated) {
    True -> inbound.request_visible_worktree(updated)
    False -> updated
  }
  let updated = surfaces.sync_context(model, updated)
  let updated = surfaces.sync_advisor_nudges(model, updated)
  let updated = surfaces.sync_goal(model, updated)
  let published = tick.publish_herdr(updated)

  // The snap runs after the projection, because a gesture closes the
  // backlog against the row count this event produced rather than the one
  // the previous frame was built from.
  let settled =
    projection.refresh_render_cache(model, published)
    |> interaction.request_history_for_view
    |> snap_viewport_for(event)
  tick.refresh_frame_cache(
    settled,
    pacing.frame_boundary(
      event,
      pacing.tick_traffic(
        before: model.render_revision,
        after: settled.render_revision,
      ),
    ),
  )
}

// A gesture aimed at the transcript owns the viewport outright: pacing
// exists to smooth output the reader did not ask for, and making a scroll,
// a page key or a resize wait on it would put the walk in front of the
// hand.
fn snap_viewport_for(model: Model, event: backend.InputEvent) -> Model {
  case pacing.viewport_address(event) {
    pacing.AddressesElsewhere -> model
    pacing.AddressesTranscript ->
      Model(..model, revealed_rows: model.rendered_row_count)
  }
}
