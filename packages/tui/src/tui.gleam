//// A pure-Gleam Loom terminal client built on etui.
////
//// The terminal process owns one immutable `Model`. Keyboard, mouse, paste,
//// websocket, and periodic inbox events each reduce that model before `view`
//// renders the next frame; no widget owns hidden conversation state. The
//// websocket actor owns transport I/O, while this process alone decides which
//// frozen ClientGateway command an operator action means. Durable entries
//// replace matching transient streams, keeping replay and live output from
//// appearing twice at the settlement boundary.

import argv
import etui/app
import etui/backend
import etui/backend/default
import etui/buffer
import etui/geometry
import etui/keys
import etui/widgets/textarea as text_area
import gleam/bit_array
import gleam/bool
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap as host_bootstrap
import host/build_identity
import host/endpoint
import simplifile
import tui/agents
import tui/appearance
import tui/attachment
import tui/attempt
import tui/attempt_replay
import tui/bootstrap
import tui/cache_miss
import tui/completion_summary
import tui/connection
import tui/context_view
import tui/daemon
import tui/daemon/protocol as control_protocol
import tui/daemon/selection as daemon_selection
import tui/frame
import tui/herdr
import tui/history_view
import tui/inbound
import tui/interaction
import tui/internal/ffi_terminal
import tui/layout
import tui/model.{
  type Model, Assistant, ControlEvent, DiffAutomatic, Disconnected, FrameCache,
  HoldGoalReport, Line, Model, Newer, NoClipboard, NoOverlay, Older, Preview,
  PromptNext, Reasoning, ReconnectAttempting, ReconnectIdle, ReconnectSpent,
  Replaying, System, TerminalClipboard, ToolResult,
} as tui_model
import tui/note_panel
import tui/pacing
import tui/projection
import tui/queue_editor
import tui/recording
import tui/render
import tui/session_channel
import tui/session_control.{ReconnectEvent}
import tui/sessions
import tui/summary_panel
import tui/surfaces
import tui/text_hygiene
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
    |> start_herdr_reporter

  let _ =
    app.run_buffered_cursor_adaptive(
      default.new_with_options(backend.Options(mouse: True, paste: True)),
      initial,
      render.view,
      update,
      fn(model) { model.quit },
      terminal_poll_timeout,
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
    poll_timeout: terminal_poll_timeout,
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

fn drain_reconnect(model: Model) -> Model {
  case model.reconnect {
    ReconnectIdle | ReconnectSpent -> model
    ReconnectAttempting(replies:, ..) ->
      case process.receive(replies, 0) {
        Error(Nil) -> model
        Ok(reply) ->
          session_control.accept_reconnect_event(
            model,
            ReconnectEvent(replies, reply),
          )
      }
  }
}

fn drain_control(model: Model) -> Model {
  case model.control_request {
    None -> model
    Some(run) ->
      case process.receive(run.replies, 0) {
        Error(Nil) -> model
        Ok(reply) ->
          session_control.accept_control_event(
            model,
            ControlEvent(run.replies, reply),
          )
      }
  }
}

/// Applies one terminal event to the model.
///
/// ## Examples
///
/// ```gleam
/// let next = tui.update(backend.Tick, model)
/// ```
@internal
pub fn update(event: backend.InputEvent, model: Model) -> Model {
  // Before the event is interpreted, so a recording holds what the client
  // was given rather than what it made of it.
  recording.note_input(model.recorder, event)

  let updated = apply_input(event, model)
  settle_update(event, model, updated)
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
// generated module before doing so.
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
    backend.Tick -> update_tick(model)

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
  let published = publish_herdr(updated)

  // The snap runs after the projection, because a gesture closes the
  // backlog against the row count this event produced rather than the one
  // the previous frame was built from.
  let settled =
    projection.refresh_render_cache(model, published)
    |> interaction.request_history_for_view
    |> snap_viewport_for(event)
  refresh_frame_cache(
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

// Starts the Herdr pane reporter when the launch environment carries a
// pane. Started here rather than in `main` so the launchers that are not
// terminal applications — `ext`, `replay`, `sessions` — never grow a
// process, and so the model the loop runs is the only one that owns it.
// A refused start is silent by design: the reporter is a convenience for
// the pane around the terminal, and the session must never learn it
// exists by failing.
//
// The sequence seed is the wall clock rather than `model.monotonic_time_ms`,
// which every other timing in the loop uses. Herdr's `seq` is an unsigned
// integer, and the BEAM monotonic clock is an arbitrary-offset counter that
// is negative on this platform, so a monotonic seed would make the daemon
// reject every report. Seeding from the wall clock also puts a reporter
// restarted in the same pane above the last sequence Herdr saw.
fn start_herdr_reporter(model: Model) -> Model {
  case herdr.configure(host_bootstrap.system_time_ms()) {
    None -> model
    Some(config) ->
      case herdr.start(config) {
        Ok(reporter) -> Model(..model, herdr_reporter: Some(reporter))
        Error(_) -> model
      }
  }
}

// Reports the pane state to Herdr when — and only when — it changed.
//
// Nothing is published before a session is attached. The terminal reaches
// this function at the session picker, where `model.session` is still
// empty, and a report carrying an empty `agent_session_id` names no
// session for `herdr session` to resume.
//
// The report derives from the same fields the frame does, so the pane
// cannot tell the operator something the screen disagrees with. A session
// switch is reported even at an unchanged state, because the session id is
// what resume keys on, and the switch re-announces: the announcement
// follows the session identity, so it is sent when that identity first
// becomes known and again every time it moves. Publishing on every event
// is deliberately cheap: the comparison is two fields and the send is one
// message to a local process.
fn publish_herdr(model: Model) -> Model {
  case model.herdr_reporter, model.session {
    None, _ -> model
    Some(_), "" -> model
    Some(_), session -> {
      let next =
        herdr.Publication(
          state: herdr.state_for(model.strands, model.approvals),
          session:,
        )
      case herdr.changed(model.herdr_published, next) {
        False -> model
        True -> {
          case herdr.announces(model.herdr_published, next) {
            True -> herdr.announce(model.herdr_reporter, session)
            False -> Nil
          }
          herdr.report(model.herdr_reporter, next.state, next.session, "")
          Model(..model, herdr_published: Some(next))
        }
      }
    }
  }
}

// A terminal tick is the only idle-time event. Visible socket traffic marks
// activity while it is drained; otherwise the accumulated quiet time advances
// by the timeout that led to this tick. A live operation animates at this
// cadence but does not by itself force the fast polling regime forever.
fn update_tick(model: Model) -> Model {
  let animated = advance_activity_indicator(drain_replay(model))
  let switched = drain_candidate(drain_control(drain_session_switch(animated)))
  let switched = drain_reconnect(switched)
  let drained = inbound.drain_connection(switched, 64)
  settle_tick(model, drained)
}

// Keep the read-service chain on a parameter, as `settle_update` does for
// event dispatch. Otherwise each inlining attempt revisits the entire drain
// expression; adding another service can double compilation time. Preserve
// the original model for the quiet-time comparison after all reads settle.
fn settle_tick(model: Model, drained: Model) -> Model {
  let drained =
    drained
    |> surfaces.service_queue_read
    |> surfaces.service_worktree_read
    |> surfaces.service_notes_read
    |> surfaces.service_jobs_read
    |> surfaces.service_context_read
    |> surfaces.service_advisor_nudges_read
    |> surfaces.service_goal_read
    |> inbound.tick_channel
    |> advance_cache_outlook
  let quiet_for_ms =
    pacing.next_quiet_for(
      model.quiet_for_ms,
      terminal_poll_timeout(model),
      drained.activity_revision != model.activity_revision,
    )
  Model(..drained, quiet_for_ms:)
}

fn drain_replay(model: Model) -> Model {
  case model.peer, process.receive(model.replay_inbox, 0) {
    Replaying, Ok(event) ->
      case attempt_replay.apply(model.replay_state, event) {
        Error(reason) ->
          tui_model.append_error(
            Model(..model, replay_error: Some(reason), quit: True),
            reason,
          )
        Ok(#(state, changes)) ->
          list.fold(
            changes,
            Model(..model, replay_state: state),
            apply_replay_change,
          )
      }
    _, _ -> model
  }
}

fn apply_replay_change(model: Model, change: attempt_replay.Change) -> Model {
  case change {
    attempt_replay.RequestedHistory(before) ->
      Model(
        ..model,
        scrollback: history_view.sent(
          history_view.freeze(model.scrollback),
          before,
        ),
      )
    attempt_replay.Rejected(reason) ->
      tui_model.append_error(model, "open session: " <> reason)
    attempt_replay.Adopt(cut, view) -> {
      let model =
        inbound.select_workspace(
          model,
          cut.attachment.expected.session,
          case model.session == cut.attachment.expected.session {
            True -> model.active_strand
            False -> "main"
          },
        )
      Model(
        ..model,
        session: cut.attachment.expected.session,
        captured: None,
        scrollback: case model.session == cut.attachment.expected.session {
          True -> history_view.cancel(model.scrollback)
          False -> model.scrollback
        },
        note_board: None,
        note_selected: None,
        notes_requested: None,
        approvals: [],
        prompted_approvals: [],
        inspecting_approval: None,
        records: [],
        streams: [],
        tool_tails: [],
        models: [],
        skills: [],
        current_model: "loading…",
        active_strand: case model.session == cut.attachment.expected.session {
          True -> model.active_strand
          False -> "main"
        },
        scroll_offset: case model.session == cut.attachment.expected.session {
          True -> model.scroll_offset
          False -> 0
        },
        record_cache_valid: False,
        submitting: None,
        interrupt: None,
      )
      |> inbound.apply_cut(cut, view)
      // Every update, cuts included, goes through the live reducer. A cut used
      // to be special-cased into `apply_cut`, which always invalidates the
      // transcript and restarts the activity indicator; `reconcile_cut`'s
      // equal-cut fast path is what the live client does instead, and a replay
      // that rendered frames the live client did not is not a replay. The
      // outbound half of that path is made inert by `request_decisions`, which
      // sends nothing while the peer is `Replaying`.
    }
    attempt_replay.Update(update) -> inbound.apply_channel_update(model, update)
  }
}

// The tick is the one place the clock is read, so the elapsed count and
// the glyph advance together and rendering stays a pure function of the
// model. Going idle clears the clock, so the next activity starts from
// zero rather than from wherever the last one stopped.
fn advance_activity_indicator(model: Model) -> Model {
  case tui_model.active_strand_live(model) {
    False -> Model(..model, activity_started_ms: None, activity_elapsed_s: 0)
    True -> {
      let now = model.monotonic_time_ms()
      let started = option.unwrap(model.activity_started_ms, now)
      let activity_elapsed_s = { now - started } / 1000
      let activity_frame = model.activity_frame + 1
      let advanced =
        Model(
          ..model,
          activity_frame:,
          activity_started_ms: Some(started),
          activity_elapsed_s:,
        )
      case
        layout.activity_glyph(model.activity_frame)
        == layout.activity_glyph(activity_frame)
        && activity_elapsed_s == model.activity_elapsed_s
      {
        True -> advanced
        False -> tui_model.invalidate_frame(advanced)
      }
    }
  }
}

// The tick is also where the cache outlook's clock is read, for the same
// reason the elapsed count lives here: rendering stays a pure function of
// the model, and the label repaints only when the reading actually moved.
//
// The reading is suppressed while the active strand is running. A request
// in flight re-writes the prefix whatever the label says, so a countdown
// shown mid-generation would name an expiry the request in progress is
// about to reset — and the miss row, not the label, is the thing that
// reports what the pause before the request cost.
fn advance_cache_outlook(model: Model) -> Model {
  let label = case tui_model.active_strand_live(model) {
    False ->
      model.cache_watch
      |> dict.get(model.active_strand)
      |> option.from_result
      |> cache_miss.outlook(model.monotonic_time_ms())
      |> option.map(cache_miss.outlook_label)
      |> option.unwrap("")
    True -> ""
  }
  case label == model.cache_outlook {
    True -> model
    False -> tui_model.invalidate_frame(Model(..model, cache_outlook: label))
  }
}

// Rendering is pure, so caching the completed frame inside the next immutable
// model gives etui the exact same Buffer term on unchanged iterations. The
// cache key stays scalar and screen-local; no complete Model comparison sits
// on the idle path.
//
// The cache is also where a burst is paced. Etui applies up to sixty-four
// queued events before drawing, but each event still calls this update path and
// a longer burst can span batches. A stale cache inside the pacing interval is
// left in place and recorded as debt; the next tick, which cannot arrive before
// the queue has drained, renders the final state once.
fn refresh_frame_cache(model: Model, boundary: pacing.FrameBoundary) -> Model {
  let screen = geometry.rect_new(0, 0, model.width, model.height)
  let freshness = case viewport_pacing(model) {
    // Rows the model holds but the viewport has not shown make the painted
    // frame stale by definition, whatever the revision says. Without this
    // the walk would stop after one step: revealing a row changes the frame
    // without changing any of the inputs the revision counts.
    pacing.ViewportCatchingUp -> pacing.FrameStale
    pacing.ViewportSettled ->
      case model.frame_cache {
        Some(FrameCache(screen: cached_screen, revision:, ..))
          if cached_screen == screen && revision == model.frame_revision
        -> pacing.FrameCurrent
        None | Some(_) -> pacing.FrameStale
      }
  }

  // The clock is read once per event and only compared against itself, so a
  // wall-clock step cannot stretch or collapse the interval.
  let now = model.monotonic_time_ms()
  case pacing.frame_decision(boundary, freshness, now - model.last_frame_ms) {
    pacing.KeepCachedFrame -> model
    pacing.DeferFrame -> Model(..model, frame_debt: pacing.FrameDeferred)
    pacing.RenderFrame -> {
      // The step is taken before the frame is built, so the frame that is
      // cached and the position it was built from are the same moment.
      let paced = advance_viewport(model)
      Model(
        ..paced,
        frame_debt: pacing.FrameSettled,
        last_frame_ms: now,
        frame_cache: Some(FrameCache(
          screen:,
          revision: paced.frame_revision,
          rendered: render.render_frame(paced, screen),
          selection_gutters: interaction.selection_gutters_on_display(paced),
        )),
      )
    }
  }
}

// The snap bound is the viewport rather than a constant: what makes a jump
// worth smoothing is that the reader can still see where the text came
// from, and a growth taller than the screen leaves nothing of it.
fn pace_policy(model: Model) -> pacing.PacePolicy {
  pacing.policy(snap_above: layout.transcript_viewport_height(model))
}

/// Reports whether the viewport still has rows to reveal.
///
/// A full-width changes view is the one surface painted without the paced
/// offset, so rows held back behind it are not on their way to any screen
/// and the frame they would make stale shows none of them. Answering
/// settled there keeps the loop off a sixteen millisecond repaint of a
/// frame the walk cannot change. Help and notes are not exempt: both are
/// painted through the same offset as the transcript, so a backlog under
/// them is a position the reader is actually being shown.
///
/// ## Examples
///
/// ```gleam
/// assert tui.viewport_pacing(model) == tui.ViewportSettled
/// ```
@internal
pub fn viewport_pacing(model: Model) -> pacing.ViewportPacing {
  use <- bool.guard(layout.main_shows_diff(model), pacing.ViewportSettled)
  pacing.viewport_pacing(backlog: tui_model.viewport_backlog(model))
}

// One step of the walk, taken as the frame it belongs to is rendered. Tying
// it to the render rather than to the tick is what bounds the shift between
// two consecutive frames: a tick that renders nothing reveals nothing.
//
// An idle strand holds no rows back at all. The walk exists to smooth output
// that is still arriving, and a viewport lagging a source that has stopped
// producing shows the reader stale text for no gain. It is also why a
// replayed or scripted run settles on the complete frame rather than on
// however far a fixed number of ticks happened to walk.
fn advance_viewport(model: Model) -> Model {
  case tui_model.active_strand_live(model) {
    False -> Model(..model, revealed_rows: model.rendered_row_count)
    True ->
      Model(
        ..model,
        revealed_rows: pacing.pace(
          model.revealed_rows,
          model.rendered_row_count,
          pace_policy(model),
        ),
      )
  }
}

/// The wait this model would ask a terminal for before its next poll.
///
/// ## Examples
///
/// ```gleam
/// assert tui.terminal_poll_timeout(model) == 40
/// ```
@internal
pub fn terminal_poll_timeout(model: Model) -> Int {
  let ordinary = pacing.paced_poll_timeout(model.frame_debt, model.quiet_for_ms)

  // A loading session candidate is read from disk rather than from the
  // socket, so its short wait survives a backlog: nothing it drains can
  // lengthen the walk.
  let ordinary = case attachment.busy(model.candidate) {
    True -> int.min(ordinary, 8)
    False -> ordinary
  }
  case viewport_pacing(model) {
    // A backlog is work the loop owes the screen with nothing left to wake
    // it: the deltas that produced those rows are already drained. One row
    // is revealed per rendered frame, so the wait between wakes is the
    // interval between rows, and the shorter in-flight wait is deliberately
    // not taken — draining the socket sooner would only lengthen a backlog
    // the viewport has yet to show.
    pacing.ViewportCatchingUp -> int.min(ordinary, pacing.frame_interval_ms)
    pacing.ViewportSettled ->
      case model.channel {
        Some(channel) ->
          case session_channel.in_flight(channel) {
            True -> int.min(ordinary, 8)
            False -> int.min(ordinary, 250)
          }
        None -> ordinary
      }
  }
}

fn drain_candidate(model: Model) -> Model {
  let #(candidate, outcome) = attachment.poll(model.candidate)
  interaction.candidate_outcome(model, candidate, outcome)
}

fn drain_session_switch(model: Model) -> Model {
  case sessions.receive(model.session_switch) {
    Error(Nil) -> model
    Ok(message) -> inbound.handle_session_switch_message(model, message)
  }
}
