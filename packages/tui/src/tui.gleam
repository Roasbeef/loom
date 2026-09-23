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
import core/entry
import core/ids
import core/json
import core/message
import core/origin
import core/register
import etui/app
import etui/backend
import etui/backend/default
import etui/buffer
import etui/geometry.{type Rect}
import etui/keys
import etui/span
import etui/widgets/textarea as text_area
import gleam/bit_array
import gleam/bool
import gleam/dict.{type Dict}
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
import machine/strand as machine_strand
import simplifile
import tui/agent_message_panel
import tui/agent_messages
import tui/agent_view
import tui/agents
import tui/appearance
import tui/approval
import tui/approval_panel
import tui/attachment
import tui/attempt
import tui/attempt_replay
import tui/bootstrap
import tui/cache_miss
import tui/collaboration_view
import tui/command
import tui/completion_summary
import tui/composer
import tui/connection
import tui/context_panel
import tui/context_view
import tui/daemon
import tui/daemon/protocol as control_protocol
import tui/daemon/selection as daemon_selection
import tui/focused_goal_panel
import tui/frame
import tui/herdr
import tui/history_view
import tui/image_drop
import tui/internal/ffi_terminal
import tui/layout
import tui/markdown
import tui/model.{
  type Clipboard, type ControlEvent, type Interrupt, type Line, type Model,
  type Peer, type Reconnect, type ScrollDirection, type StrandWorkspace,
  type Stream, type Submission, type ToolTail, type UnconfirmedSubmission,
  AgentInspector, ApprovalInspector, Assistant, Attached, CacheNotice,
  CacheObservation, ComposerSubmission, ControlEvent, ControlRequest,
  DaemonSelector, DiffAutomatic, DiffHidden, DiffVisible, Disconnected, Failure,
  FrameCache, GoalInspector, HeldPrompt, HoldGoalReport, Interjection, Interrupt,
  Line, Model, ModelSelector, Newer, NoClipboard, NoOverlay, Older,
  OverlaySubmission, PageLoaded, Preview, PromptNext, Reasoning, ReasoningDigest,
  ReconnectAttempting, ReconnectIdle, ReconnectSpent, Replaying, SessionArchived,
  SessionDeleted, SessionRenamed, SessionRestored, SessionSelector, Spacer,
  SteerNow, StrandWorkspace, Stream, System, TerminalClipboard, ToolCall,
  ToolDetail, ToolFailure, ToolPatch, ToolResult, ToolTail,
  UnconfirmedSubmission, User,
} as tui_model
import tui/model_selector
import tui/note_panel
import tui/outbound
import tui/pacing
import tui/protocol.{ModelInfo, Strand}
import tui/queue_editor
import tui/queue_panel
import tui/recording
import tui/render
import tui/reviewer_status
import tui/selection
import tui/session_channel
import tui/session_selector
import tui/sessions
import tui/snapshot
import tui/snapshot_view
import tui/stream_identity
import tui/summary_panel
import tui/surfaces
import tui/text_hygiene
import tui/tool_activity
import tui/transcript_anchor
import tui/transcript_lines.{
  BetweenEntries, Projected, Transient, WithinResponse,
}
import tui/update
import tui/update/download
import tui/update/options as update_options
import tui/virtual_backend
import tui/workspace
import tui/worktree_view
import weft

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
  case flag_value(arguments, flag) {
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
  let strands = demo_strands()
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
    models: demo_models(),
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
    usage: zero_usage(),
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
      case flag_value(arguments, "--addr"), flag_value(arguments, "--session") {
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
  case flag_value(arguments, "--token-file") {
    Ok(path) ->
      simplifile.read(path)
      |> result.map(string.trim)
      |> result.map_error(fn(error) {
        "cannot read --token-file " <> path <> ": " <> string.inspect(error)
      })
    Error(Nil) -> Ok(flag_value(arguments, "--token") |> result.unwrap(""))
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
        "" -> load_catalogue(model, "", None)
        id -> begin_open(model, id)
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
          transcript: daemon_build_lines(Some(host)),
        )
      case selected {
        "" -> load_catalogue(model, "", None)
        id -> begin_open(model, id)
      }
    }
  }
}

// The authenticated build belongs to the retained control host. Projecting
// its mismatch on every coherent cut keeps attachment and later captures from
// erasing the update notice when they replace the transcript presentation.
fn daemon_build_lines(host: Option(daemon_selection.Host)) -> List(Line) {
  case host {
    None -> []
    Some(host) ->
      build_mismatch_lines(daemon.hello(daemon_selection.control(host)).build)
  }
}

fn build_mismatch_lines(build: Option(control_protocol.Build)) -> List(Line) {
  case build {
    None -> []
    Some(theirs) -> {
      let ours = build_identity.current()
      let theirs = build_identity.Identity(theirs.version, theirs.commit)
      case build_identity.matches(ours, theirs) {
        True -> []
        False -> [
          Line(
            System,
            "daemon build "
              <> build_identity.describe(theirs)
              <> " differs from this client's "
              <> build_identity.describe(ours)
              <> "; the daemon runs the build it was started with, so "
              <> "restart it to pick up an update",
          ),
        ]
      }
    }
  }
}

// The bounded relaunch budget. It is the same ninety seconds the initial
// local launch is allowed, because the work is the same: a launch lock, a
// daemon start, and two authenticated probes.
const reconnect_timeout_ms = 90_000

/// Decides whether one unexpected daemon death earns a reconnect.
///
/// The decision is a pure read of the terminal's own state, taken at the
/// moment the transport reported the loss, so it can be reasoned about (and
/// tested) without a daemon. The three refusals are each a different fact:
/// an operator quit is not a failure to recover from, a remote attachment has
/// no launch to re-run, and an attempt already spent means the operator is
/// owed an error rather than a loop.
fn reconnect_decision(model: Model) -> ReconnectDecision {
  case model.quit {
    True -> ReconnectRefused("the terminal is closing")
    False ->
      case model.session {
        "" -> ReconnectRefused("no session is attached")
        session ->
          case model.local_options {
            None -> ReconnectRefused("this attachment was not launched locally")
            Some(options) ->
              reconnect_state_decision(model.reconnect, session, options)
          }
      }
  }
}

// The innermost question, split out so the decision above reads as the
// three facts it is deciding between rather than four nested cases. A
// terminal that has already spent its one attempt waits for the operator
// instead of looping, and one whose attempt is still running must not
// start a second beside it.
fn reconnect_state_decision(
  reconnect: Reconnect,
  session: String,
  options: bootstrap.Options,
) -> ReconnectDecision {
  case reconnect {
    ReconnectIdle -> ReconnectWanted(session, options)
    ReconnectAttempting(..) ->
      ReconnectRefused("a reconnect is already running")
    ReconnectSpent -> ReconnectRefused("the attempt was already made")
  }
}

// What the decision above produced: the work to do, or the reason there is
// none. The reason is carried rather than dropped so the caller can say why
// rather than leaving the operator with a silent terminal.
type ReconnectDecision {
  ReconnectWanted(session: String, options: bootstrap.Options)

  ReconnectRefused(reason: String)
}

// Enters the one bounded reconnect an unexpected daemon death is allowed.
//
// Called from the two places a live conversation reports its loss — the
// directly attached socket and the credited session channel — so the
// decision is made once, at the transition, rather than at each caller. The
// transcript is deliberately untouched: the model already holds it, and a
// relaunch that fails must leave it exactly where the operator left it.
fn begin_reconnect(model: Model) -> Model {
  case reconnect_decision(model) {
    ReconnectRefused(_) -> model
    ReconnectWanted(session, options) -> {
      let cancel = weft.cancel_signal()
      let replies = process.new_subject()

      // The relaunch runs in its own bounded task because it blocks: it may
      // take the launch lock, start a daemon, and authenticate two sockets.
      // Nothing but the two scalars it needs is captured, because weft copies
      // a fun's environment into the worker — and a closure over a model
      // field would copy the transcript, the row caches and the cached frame
      // with it.
      let owner = process.self()
      let _relay =
        weft.new([
          fn() {
            daemon_selection.relaunch(options, owner, reconnect_timeout_ms)
          },
        ])
        |> weft.deadline(reconnect_timeout_ms)
        |> weft.cancel_with(cancel)
        |> weft.start_relayed(replies)
      Model(
        ..model,
        reconnect: ReconnectAttempting(cancel, replies),
        notice: "reconnecting to session " <> session,
      )
      |> tui_model.invalidate_frame
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
          accept_reconnect_event(model, ReconnectEvent(replies, reply))
      }
  }
}

/// One relayed relaunch outcome, selected by the terminal and its driver.
@internal
pub type ReconnectEvent {
  ReconnectEvent(
    source: Subject(weft.Pulled(daemon_selection.Host, String)),
    reply: weft.Pulled(daemon_selection.Host, String),
  )
}

/// Applies one relaunch outcome, bounded to the attempt which produced it.
///
/// A success reattaches the same session through the shipped open path, which
/// is what gives the operator a working channel again; the transcript it
/// already had is merged rather than replaced. A failure is terminal: the
/// attempt is marked spent and the reason is written to the transcript, so a
/// relaunch that cannot succeed is reported once instead of being retried.
/// Every `weft.Pulled` variant is named rather than swept up, because each is a
/// different fact about the attempt and a catch-all would hide a new one.
///
/// ## Examples
///
/// ```gleam
/// // tui.accept_reconnect_event(model, event)
/// ```
@internal
pub fn accept_reconnect_event(model: Model, event: ReconnectEvent) -> Model {
  case model.reconnect {
    ReconnectIdle | ReconnectSpent -> model
    ReconnectAttempting(replies: source, ..) if source != event.source -> model
    ReconnectAttempting(..) ->
      case event.reply {
        weft.NotYet -> model
        weft.PulledOutcome(weft.Completed(value: host, ..)) -> {
          let model = Model(..model, reconnect: ReconnectSpent)
          let model = Model(..model, daemon_host: Some(host))
          reattach_after_reconnect(model)
        }
        weft.PulledOutcome(weft.Failed(error:, ..)) ->
          reconnect_failed(model, error)
        weft.PulledOutcome(weft.Crashed(reason:, ..))
        | weft.PulledOutcome(weft.DrainProofLost(reason:, ..)) ->
          reconnect_failed(model, string.inspect(reason))
        weft.PulledOutcome(weft.Abandoned(..))
        | weft.PulledOutcome(weft.NeverStarted(..))
        | weft.PulledOutcome(weft.CancellationUnconfirmed(..)) ->
          reconnect_failed(model, "the daemon relaunch did not complete")
        weft.RunLost(reason) -> reconnect_failed(model, string.inspect(reason))
        weft.AllDelivered ->
          reconnect_failed(
            model,
            "the daemon relaunch ended without an outcome",
          )
      }
  }
}

// Reattaches the session the terminal was already showing. The identity comes
// from the model, so the operator's transcript and the daemon's registration
// are the same session; `begin_open` is the shipped path that resolves the
// current epoch and incarnation through control and adopts the new socket.
fn reattach_after_reconnect(model: Model) -> Model {
  case model.session {
    "" -> Model(..model, notice: "daemon reconnected; no session was attached")
    session ->
      tui_model.append_system(
        begin_open(
          Model(..model, notice: "reattaching to " <> session),
          session,
        ),
        "daemon restarted; reattaching to " <> session,
      )
  }
}

// The terminal failure of one reconnect. The attempt is spent either way, so
// the operator gets the reason and the standing Disconnected advice rather
// than a loop; `/sessions` remains the explicit way back.
fn reconnect_failed(model: Model, reason: String) -> Model {
  tui_model.append_error(
    Model(..model, reconnect: ReconnectSpent),
    "reconnect failed: " <> reason <> "; press /sessions to reconnect",
  )
}

fn begin_open(model: Model, session: String) -> Model {
  let model = cancel_pending(model, "target change from " <> model.session)
  case attachment.busy(model.candidate), model.daemon_host {
    True, _ ->
      tui_model.append_error(model, "a session switch is already in progress")
    False, None ->
      tui_model.append_error(model, "daemon control is disconnected")
    False, Some(host) ->
      Model(
        ..model,
        overlay: NoOverlay,
        next_attempt: model.next_attempt + 1,
        candidate: attachment.start_recorded(
          fn() {
            use host <- daemon_selection.with_live_control(host)
            daemon_selection.open(host, session)
          },
          90_000,
          recording.trace(model.recorder, attempt.Id(model.next_attempt)),
        ),
        notice: "opening session " <> session,
      )
  }
}

// Paging observes only authorized metadata in the requested revision.
fn load_catalogue(model: Model, after: String, revision: Option(Int)) -> Model {
  load_catalogue_collection(model, after, revision, session_selector.Active)
}

// Collection belongs to the request, so a late page cannot be relabelled by
// a key pressed while its one bounded control job is still outstanding.
fn load_catalogue_collection(
  model: Model,
  after: String,
  revision: Option(Int),
  collection: session_selector.Collection,
) -> Model {
  let command = case collection {
    session_selector.Active -> control_protocol.ListSessions(after, revision)
    session_selector.Archived ->
      control_protocol.ListArchivedSessions(after, revision)
  }
  case model.control_request, model.daemon_host {
    Some(_), _ ->
      tui_model.append_error(model, "a catalogue page is already loading")
    None, None ->
      tui_model.append_error(model, "daemon control is disconnected")
    None, Some(host) -> {
      let cancel = weft.cancel_signal()
      let replies = process.new_subject()

      // The two scalars the worker needs are bound here rather than read off
      // `model` inside the closure. A closure over a field captures the whole
      // record, and weft copies a fun's environment into the worker: that
      // would send the transcript, the row caches and the cached frame — an
      // 8 MiB retained window at its bound — to a process that wants a
      // session id and a path.
      let session = model.session
      let workspace = model.workspace.path
      let _relay =
        weft.new([
          fn() {
            use host <- daemon_selection.with_live_control(host)
            use reply <- result.try(
              daemon.request(daemon_selection.control(host), command, 5000)
              |> result.map_error(daemon_selection.failure),
            )
            use page <- result.try(case reply {
              control_protocol.SessionsReply(page) -> Ok(page)
              control_protocol.StatusReply(_)
              | control_protocol.SessionReply(_)
              | control_protocol.LifecycleReply(_)
              | control_protocol.DeletedReply(_)
              | control_protocol.ShutdownReply ->
                Error("catalogue returned an unexpected control reply")
            })
            let selected = case session {
              "" -> default_selection(host, workspace)
              id -> id
            }
            Ok(PageLoaded(page, selected, collection))
          },
        ])
        |> weft.deadline(12_000)
        |> weft.cancel_with(cancel)
        |> weft.start_relayed(replies)
      Model(
        ..model,
        control_request: Some(ControlRequest(cancel, replies, None)),
        notice: "loading authorized session metadata",
      )
    }
  }
}

// Deletion shares the picker's one control job slot with paging, so a delete
// while a page is in flight is refused rather than queued behind it. The
// identity is bound outside the closure for the same reason the page job
// binds its two scalars: weft copies the fun's environment, and a reference
// to a model field would copy the whole presentation state with it.
// The reply owns the displayed name. A timeout leaves the outcome unknown
// and never causes the metadata mutation to be sent a second time.
fn begin_rename(model: Model, session: String, name: String) -> Model {
  case model.control_request, model.daemon_host {
    Some(_), _ ->
      tui_model.append_error(model, "a catalogue action is already running")
    None, None ->
      tui_model.append_error(model, "daemon control is disconnected")
    None, Some(host) -> {
      let cancel = weft.cancel_signal()
      let replies = process.new_subject()
      let _relay =
        weft.new([
          fn() {
            use host <- daemon_selection.with_live_control(host)
            use reply <- result.try(
              daemon.request(
                daemon_selection.control(host),
                control_protocol.RenameSession(session, name),
                5000,
              )
              |> result.map_error(daemon_selection.failure),
            )
            case reply {
              control_protocol.SessionReply(row) if row.session_id == session ->
                Ok(SessionRenamed(row))
              _ -> Error("rename returned an unexpected control reply")
            }
          },
        ])
        |> weft.deadline(12_000)
        |> weft.cancel_with(cancel)
        |> weft.start_relayed(replies)
      Model(
        ..model,
        control_request: Some(ControlRequest(cancel, replies, None)),
        notice: "renaming session",
      )
    }
  }
}

fn begin_delete(model: Model, session: String) -> Model {
  begin_removal(model, session, PermanentlyDelete)
}

// The ADT keeps a confirmed permanent deletion distinct from reversible
// archive and restore requests while they share one bounded job slot.
type Removal {
  Archive
  Restore
  PermanentlyDelete
}

fn begin_removal(model: Model, session: String, removal: Removal) -> Model {
  case model.control_request, model.daemon_host {
    Some(_), _ ->
      tui_model.append_error(model, "a catalogue request is already running")
    None, None ->
      tui_model.append_error(model, "daemon control is disconnected")
    None, Some(host) -> {
      let cancel = weft.cancel_signal()
      let replies = process.new_subject()
      let _relay =
        weft.new([
          fn() {
            use host <- daemon_selection.with_live_control(host)
            case removal {
              Archive ->
                result.map(
                  daemon_selection.archive(host, session),
                  SessionArchived,
                )
              Restore ->
                result.map(
                  daemon_selection.restore(host, session),
                  SessionRestored,
                )
              PermanentlyDelete ->
                result.map(
                  daemon_selection.delete(host, session),
                  SessionDeleted,
                )
            }
          },
        ])
        |> weft.deadline(85_000)
        |> weft.cancel_with(cancel)
        |> weft.start_relayed(replies)
      Model(
        ..model,
        control_request: Some(ControlRequest(cancel, replies, None)),
        notice: case removal {
          Archive -> "stopping and archiving session " <> session
          Restore -> "restoring session " <> session
          PermanentlyDelete ->
            "stopping and permanently deleting session " <> session
        },
      )
    }
  }
}

fn default_selection(host, workspace) {
  case
    daemon.request(
      daemon_selection.control(host),
      control_protocol.WorkspaceDefault(workspace),
      5000,
    )
  {
    Ok(control_protocol.SessionReply(row)) -> row.session_id
    _ -> ""
  }
}

fn drain_control(model: Model) -> Model {
  case model.control_request {
    None -> model
    Some(run) ->
      case process.receive(run.replies, 0) {
        Error(Nil) -> model
        Ok(reply) ->
          accept_control_event(model, ControlEvent(run.replies, reply))
      }
  }
}

/// Applies a selected control job response before later terminal messages.
///
/// ## Examples
///
/// ```gleam
/// // tui.accept_control_event(model, event)
/// ```
@internal
pub fn accept_control_event(model: Model, event: ControlEvent) -> Model {
  case model.control_request {
    None -> model
    Some(run) if run.replies != event.source -> model
    Some(run) ->
      case event.reply {
        weft.NotYet -> model
        weft.PulledOutcome(weft.Completed(value:, ..)) ->
          Model(
            ..model,
            control_request: Some(
              ControlRequest(..run, result: Some(Ok(value))),
            ),
          )
        weft.PulledOutcome(weft.Failed(error:, ..)) ->
          Model(
            ..model,
            control_request: Some(
              ControlRequest(..run, result: Some(Error(error))),
            ),
          )
        weft.PulledOutcome(weft.Crashed(reason:, ..))
        | weft.PulledOutcome(weft.DrainProofLost(reason:, ..)) ->
          Model(
            ..model,
            control_request: Some(
              ControlRequest(..run, result: Some(Error(string.inspect(reason)))),
            ),
          )
        weft.PulledOutcome(weft.Abandoned(..))
        | weft.PulledOutcome(weft.NeverStarted(..))
        | weft.PulledOutcome(weft.CancellationUnconfirmed(..)) ->
          Model(
            ..model,
            control_request: Some(
              ControlRequest(
                ..run,
                result: Some(Error("control request did not complete")),
              ),
            ),
          )
        weft.RunLost(reason) ->
          tui_model.append_error(
            Model(..model, control_request: None),
            string.inspect(reason),
          )
        weft.AllDelivered ->
          finish_control(Model(..model, control_request: None), run.result)
      }
  }
}

fn finish_control(model: Model, result) {
  case result {
    Some(Ok(PageLoaded(page, selected, collection))) -> {
      let selector =
        session_selector.new(
          session_selector.prioritize(page, model.workspace.path),
          selected,
        )
      Model(
        ..model,
        overlay: DaemonSelector(session_selector.State(..selector, collection:)),
        notice: case collection {
          session_selector.Active ->
            "Enter opens · d archives · a shows archived sessions"
          session_selector.Archived ->
            "Enter restores · d permanently deletes · a shows active sessions"
        },
      )
      |> tui_model.invalidate_frame
    }

    Some(Ok(SessionRenamed(row))) ->
      Model(
        ..model,
        session_label: case row.session_id == model.session {
          True -> Some(#(row.session_id, row.name))
          False -> model.session_label
        },
        overlay: case model.overlay {
          DaemonSelector(selector) ->
            DaemonSelector(session_selector.renamed(selector, row))
          NoOverlay
          | ModelSelector(_)
          | AgentInspector(_)
          | GoalInspector(_)
          | ApprovalInspector(_)
          | SessionSelector(_) -> model.overlay
        },
        notice: "renamed session to " <> row.name,
      )
      |> tui_model.invalidate_frame

    // The row is dropped from the page already on screen rather than by
    // re-listing: the reply proves this identity is gone, and a fresh page
    // would move every other row under the operator's cursor.
    Some(Ok(SessionDeleted(id))) ->
      catalogue_removed(model, id, "deleted session ")
    Some(Ok(SessionArchived(id))) ->
      catalogue_removed(model, id, "archived session ")
    Some(Ok(SessionRestored(id))) ->
      catalogue_removed(model, id, "restored session ")
    Some(Error(reason)) -> tui_model.append_error(model, reason)
    None ->
      tui_model.append_error(model, "control job ended without an outcome")
  }
}

// Acknowledgements update only the collection already on screen. Restoring a
// row never opens it, and no metadata acknowledgement retargets attachment.
fn catalogue_removed(model: Model, id: String, description: String) -> Model {
  Model(
    ..model,
    overlay: case model.overlay {
      DaemonSelector(selector) ->
        DaemonSelector(session_selector.without(selector, id))
      NoOverlay
      | ModelSelector(_)
      | AgentInspector(_)
      | GoalInspector(_)
      | ApprovalInspector(_)
      | SessionSelector(_) -> model.overlay
    },
    notice: description <> id,
  )
  |> tui_model.invalidate_frame
}

fn create_session(model: Model) -> Model {
  // Resolve local paths before retaining a creation key: a local failure sent
  // nothing and must leave the operator free to correct the invocation.
  //
  // Resolution runs per attempt, so a retained key retried after a lost reply
  // carries whatever `<state-root>/loom.toml` says at that moment, and
  // `reserve_creation` answers `Conflict` if the answer changed. That is
  // accepted rather than cached: the file would have to appear inside a single
  // lost-reply window, and the operator sees a named conflict, not a session
  // created under a catalogue they did not ask for.
  let configuration = case model.local_options {
    Some(options) -> bootstrap.session_configuration(options)
    None -> Ok("")
  }
  case configuration {
    Error(reason) -> tui_model.append_error(model, reason)
    Ok(config) -> create_session_configured(model, config)
  }
}

fn create_session_configured(model: Model, config: String) -> Model {
  let model = cancel_pending(model, "target change from " <> model.session)
  case model.creation_key, model.daemon_host, attachment.busy(model.candidate) {
    Some(key), _, _ ->
      tui_model.append_error(
        model,
        "reconcile prior creation key before creating again: " <> key,
      )
    None, None, _ ->
      tui_model.append_error(model, "daemon control is disconnected")
    None, Some(_), True ->
      tui_model.append_error(model, "a session switch is already in progress")
    None, Some(host), False -> {
      let key =
        "tui-"
        <> int.to_string(host_bootstrap.current_process_id())
        <> "-"
        <> string.inspect(process.self())
        <> "-"
        <> int.to_string(host_bootstrap.system_time_ms())
        <> "-"
        <> int.to_string(model.next_id)

      // Bound outside the closure for the same reason the catalogue job binds
      // its two: a reference to `model.workspace` would put the whole
      // presentation state, cached frame included, in the worker's copied
      // environment.
      let workspace = model.workspace.path
      let name = workspace.session_name(model.workspace)
      Model(
        ..model,
        creation_key: Some(key),
        overlay: NoOverlay,
        next_id: model.next_id + 1,
        next_attempt: model.next_attempt + 1,
        candidate: attachment.start_recorded(
          fn() {
            use host <- daemon_selection.with_live_control(host)
            daemon_selection.create_named(host, key, workspace, name, config)
          },
          90_000,
          recording.trace(model.recorder, attempt.Id(model.next_attempt)),
        ),
        notice: "creating a new session",
      )
    }
  }
}

fn flag_value(arguments: List(String), flag: String) -> Result(String, Nil) {
  case arguments {
    [] | [_] -> Error(Nil)
    [name, value, ..rest] ->
      case name == flag {
        True -> Ok(value)
        False -> flag_value([value, ..rest], flag)
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
      update_ready_key(keys.match(key), model)
      |> tui_model.mark_activity
      |> tui_model.invalidate_frame
    backend.Paste(text) ->
      handle_paste(clear_selection(model), text)
      |> tui_model.mark_activity
      |> tui_model.invalidate_frame

    // A wheel flick delivers notches faster than any poll timeout, so no
    // tick arrives until the hand pauses. Draining here, as a key does,
    // keeps the history page this gesture asked for from waiting on that
    // pause and then landing with every capture queued behind it.
    backend.MouseScroll(x, y, up) ->
      drain_connection(model, 64)
      |> clear_selection
      |> scroll_at(geometry.Position(x, y), case up {
        True -> Older
        False -> Newer
      })
      |> tui_model.mark_activity
      |> tui_model.invalidate_frame

    // The left button is the selection button, as in every terminal. The
    // other two are listed so a new etui button is a compile error here.
    backend.MousePress(x, y, backend.MouseLeft) ->
      begin_selection(model, geometry.Position(x, y))
      |> tui_model.mark_activity
      |> tui_model.invalidate_frame

    // A held drag is the other gesture that outruns the poll timeout, for as
    // long as the button is down. The selection reads the frame it began
    // on, so the traffic applied here cannot move the cells under it.
    backend.MouseDrag(x, y, backend.MouseLeft) ->
      drain_connection(model, 64)
      |> extend_selection(geometry.Position(x, y))
      |> tui_model.mark_activity
      |> tui_model.invalidate_frame
    backend.MouseRelease(x, y, backend.MouseLeft) ->
      finish_selection(model, geometry.Position(x, y))
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
    True -> request_visible_worktree(updated)
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
    refresh_render_cache(model, published)
    |> request_history_for_view
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
  let drained = drain_connection(switched, 64)
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
    |> tick_channel
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
        select_workspace(
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
      |> apply_cut(cut, view)
      // Every update, cuts included, goes through the live reducer. A cut used
      // to be special-cased into `apply_cut`, which always invalidates the
      // transcript and restarts the activity indicator; `reconcile_cut`'s
      // equal-cut fast path is what the live client does instead, and a replay
      // that rendered frames the live client did not is not a replay. The
      // outbound half of that path is made inert by `request_decisions`, which
      // sends nothing while the peer is `Replaying`.
    }
    attempt_replay.Update(update) -> apply_channel_update(model, update)
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
          selection_gutters: selection_gutters_on_display(paced),
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

// Terminal polling still produces idle ticks so the websocket inbox can be
// drained, but those ticks must not compare or wrap the durable transcript.
// Event handlers increment a scalar revision at the mutation boundary, which
// keeps an idle cache check constant-time regardless of session length.
fn refresh_render_cache(before: Model, after: Model) -> Model {
  let changed =
    after.render_revision != after.rendered_revision
    || tui_model.reading_history(before) != tui_model.reading_history(after)
    || before.width != after.width
    || before.agent_rail_visible != after.agent_rail_visible
    || before.details_expanded != after.details_expanded
    || before.help_open != after.help_open
    || before.notes_open != after.notes_open
    || before.diff_view != after.diff_view
    || layout.diff_borrow_eligible(before) != layout.diff_borrow_eligible(after)
    || before.active_strand != after.active_strand
    || before.session != after.session
    || before.nudges != after.nudges
    || viewport_height_changed(
      layout.transcript_viewport_height(before),
      layout.transcript_viewport_height(after),
    )
  case changed {
    True -> {
      let width = layout.transcript_width(after)
      let same_workspace =
        before.active_strand == after.active_strand
        && before.session == after.session
      let reading_lines = case
        tui_model.reading_history(after),
        same_workspace,
        before.reading_lines,
        after.reading_lines
      {
        False, _, _, _ -> None
        True, True, Some(lines), _ -> Some(lines)
        True, _, _, Some(lines) -> Some(lines)
        True, _, _, None -> Some(transient_lines(after))
      }
      let cached =
        refresh_diff_cache(before, Model(..after, reading_lines:))
        |> refresh_record_cache(width)
      let #(rendered_rows, rendered_gutters) =
        rendered_layout_for(cached, width)
      let rendered_row_count = list.length(rendered_rows)

      // Source anchors belong to the durable row cache. Metadata and live
      // fragments invalidate the outer projection even while reading frozen
      // history, but do not change these identities. Rebuilding them there
      // re-projects and sanitizes every retained message on every update.
      // An empty anchor list also covers entering history or returning from
      // help, whose rows have no durable identities to reuse.
      let rendered_anchors = case
        after.help_open || after.notes_open || !tui_model.reading_history(after),
        record_cache_matches(after, width)
        && list.is_empty(after.pending_records)
        && before.active_strand == after.active_strand
        && before.session == after.session,
        before.rendered_anchors
      {
        True, _, _ -> []
        False, True, [_, ..] -> before.rendered_anchors
        False, _, _ -> record_anchors_for(cached, width)
      }
      let endpoint = case after.restored_workspace {
        Some(saved) -> #(saved.anchors, saved.height, saved.prefix)
        None ->
          case
            before.active_strand == after.active_strand
            && before.session == after.session
          {
            True -> #(
              before.rendered_anchors,
              layout.transcript_viewport_height(before),
              before.rendered_row_count - list.length(before.rendered_anchors),
            )
            False -> #([], layout.transcript_viewport_height(after), 0)
          }
      }
      let anchored = case tui_model.reading_history(after) {
        False -> 0
        True ->
          transcript_anchor.relocate(
            endpoint.0,
            rendered_anchors,
            after.scroll_offset,
            endpoint.1,
            endpoint.2,
            rendered_row_count - list.length(rendered_anchors),
          )
          |> option.unwrap(after.scroll_offset)
      }

      // A notebook opens at its index and selected cell heading, rather than
      // at the end of a long value. Paging then uses the ordinary copy-safe
      // row viewport; unrelated stream updates cannot reset that position.
      let anchored = case
        after.notes_open
        && {
          !before.notes_open
          || before.note_selected != after.note_selected
          || { before.note_board == None && after.note_board != None }
        }
      {
        True -> rendered_row_count
        False -> anchored
      }

      // Reading history owns the viewport through the scroll offset, and a
      // strand or session switch replaced the rows rather than extending
      // them: neither has a tail to walk toward. Otherwise the count only
      // needs clamping, since a shrunk projection must not leave the
      // viewport claiming rows that no longer exist.
      let revealed_rows = case
        tui_model.reading_history(after)
        || after.notes_open
        || before.active_strand != after.active_strand
        || before.session != after.session
      {
        True -> rendered_row_count
        False -> int.min(after.revealed_rows, rendered_row_count)
      }
      Model(
        ..cached,
        restored_workspace: None,
        rendered_revision: cached.render_revision,
        rendered_row_count:,
        rendered_rows:,
        revealed_rows:,
        rendered_anchors:,
        rendered_gutters:,
        scroll_offset: case notes_surface(after) {
          True -> after.scroll_offset
          False ->
            bounded_scroll_offset(
              anchored,
              rendered_row_count,
              layout.transcript_viewport_height(after),
            )
        },
      )
    }
    False -> after
  }
}

fn notes_surface(model: Model) -> Bool {
  case model.notes_open, model.overlay {
    True, _
    | False, AgentInspector(agents.Inspector(detail: agents.Notes, ..))
    -> True
    False, NoOverlay
    | False, ModelSelector(_)
    | False, GoalInspector(_)
    | False, SessionSelector(_)
    | False, DaemonSelector(_)
    | False, AgentInspector(_)
    | False, ApprovalInspector(_)
    -> False
  }
}

// File selection and received observations invalidate the render revision even
// when the conversation is unchanged. The outer render cache must admit those
// transitions before this independent patch cache can inspect its own inputs.
// Diff rows have their own width and scroll position. Reuse the projection
// while only live fragments or composer text changed: admitted records already
// invalidate the durable cache, and pending legacy entries name an append.
// Closing the view releases its rows rather than retaining a hidden history.
fn refresh_diff_cache(before: Model, after: Model) -> Model {
  let cached = case layout.diff_shown(after) {
    False ->
      Model(
        ..after,
        diff_rows: [],
        diff_line_cache: dict.new(),
        diff_row_count: 0,
        diff_worktree_source: #(None, 0),
      )
    True -> {
      let matches =
        layout.diff_shown(before)
        && after.record_cache_valid
        && after.record_cache_strand == after.active_strand
        && list.is_empty(after.pending_records)
        && after.diff_worktree_source
        == #(after.worktree.board, after.worktree.selected)
        && layout.diff_width(before) == layout.diff_width(after)
      case matches {
        True -> after
        False -> {
          let #(rows, line_cache, _) =
            transcript_lines.diff_content(after)
            |> cached_record_lines(
              layout.diff_width(after),
              previous_diff_layout(before, after),
            )
          let count = list.length(rows)
          Model(
            ..after,
            diff_rows: rows,
            diff_line_cache: line_cache,
            diff_row_count: count,
            diff_worktree_source: #(
              after.worktree.board,
              after.worktree.selected,
            ),
            diff_scroll_offset: anchored_scroll_offset(
              after.diff_scroll_offset,
              before.diff_row_count,
              count,
            ),
          )
        }
      }
    }
  }
  Model(
    ..cached,
    diff_scroll_offset: bounded_scroll_offset(
      cached.diff_scroll_offset,
      cached.diff_row_count,
      layout.diff_patch_height(cached),
    ),
  )
}

fn previous_diff_layout(
  before: Model,
  after: Model,
) -> Dict(Line, List(span.Line)) {
  case
    layout.diff_shown(before)
    && layout.diff_width(before) == layout.diff_width(after)
  {
    True -> after.diff_line_cache
    False -> dict.new()
  }
}

/// Reports whether prompt layout changed the transcript's usable height.
@internal
pub fn viewport_height_changed(before: Int, after: Int) -> Bool {
  before != after
}

// Durable rows survive live stream fragments. Compact tool groups can change
// when a result arrives, so their projection is rebuilt from current entries.
// Unchanged presentation lines reuse their wrapped rows within the same width;
// a changed outcome has a different key and cannot retain its pending label.
// Expanded append-only history still extends the row list as one small batch.
// Both wrapped rows and their source anchors share this layout key. Pending
// records are checked separately: rows can append them, while anchors need a
// complete rebuild so repeated text still names its own durable entry.
fn record_cache_matches(model: Model, width: Int) -> Bool {
  model.record_cache_valid
  && model.record_cache_width == width
  && model.record_cache_strand == model.active_strand
  && model.record_cache_details == model.details_expanded
}

fn refresh_record_cache(model: Model, width: Int) -> Model {
  // Expanded history is append-only, so a pending record there can only add
  // rows. Compact history groups consecutive calls, and `tool_activity`
  // answers which records can rewrite a group already projected; the rest —
  // prose, a user turn, structural history — end the group with the rows it
  // already had and keep the append path.
  // A new primary record may have been committed before an advisor item
  // already in the cached window. Rebuild that mixed sequence instead of
  // prepending the primary row above every advisor row.
  let regrouped =
    {
      !model.details_expanded
      && list.any(model.pending_records, fn(record) {
        tool_activity.regroups(record.entry)
      })
    }
    || {
      model.active_strand == "main"
      && model.advisor_history.items != []
      && model.pending_records != []
    }
  let cache_matches = record_cache_matches(model, width) && !regrouped
  case cache_matches, model.pending_records {
    False, _ -> {
      let previous = case model.record_cache_width == width {
        True -> model.record_line_cache
        False -> dict.new()
      }
      let #(lines, compact_call_cache, compact_entry_cache) =
        transcript_lines.record_lines(
          model.records,
          model,
          transcript_lines.active_notices(model),
        )
      let #(record_rows, record_line_cache, record_gutters) =
        model.transcript
        |> list.append(lines)
        |> cached_record_lines(width, previous)
      Model(
        ..model,
        record_rows:,
        record_gutters:,
        record_line_cache:,
        compact_call_cache:,
        compact_entry_cache:,
        pending_records: [],
        record_cache_valid: True,
        record_cache_width: width,
        record_cache_strand: model.active_strand,
        record_cache_details: model.details_expanded,
      )
    }
    True, [] -> model
    True, pending -> {
      let #(lines, calls, narratives) =
        transcript_lines.record_lines(pending, model, [])
      let #(newest_rows, appended, newest_gutters) =
        lines
        |> separated_from_screen(model)
        |> cached_record_lines(width, model.record_line_cache)

      // Every cache here describes the current projection, and the appended
      // records have just joined it. Merging rather than replacing keeps the
      // hints for the rows already on screen, which this path never rebuilds;
      // the release of retired text belongs to the full rebuild.
      Model(
        ..model,
        record_rows: list.append(newest_rows, model.record_rows),
        record_gutters: list.append(newest_gutters, model.record_gutters),
        record_line_cache: dict.merge(model.record_line_cache, appended),
        compact_call_cache: dict.merge(model.compact_call_cache, calls),
        compact_entry_cache: dict.merge(model.compact_entry_cache, narratives),
        pending_records: [],
      )
    }
  }
}

// The entry-level separation at the one seam the fold above cannot see.
//
// `record_lines` separates the entries handed to it, but the append path
// hands it a suffix: the entry above the first new one was projected on an
// earlier pass and is no longer in reach. The row it drew is, though, and a
// drawn row answers the same question `closes_bare` answers about a speaker
// — a blank row already separates whatever follows it, a drawn one does not
// — so the seam is decided from the screen rather than from a second copy of
// the projection. Compact history applies the same rule between its items,
// so the seam is the same in both views.
//
// The live tail sits on the same seam and asks the same question of it: a
// reasoning row still streaming under a settled result must stand where its
// settled form will, or the transcript moves a row when it lands.
fn separated_from_screen(lines: List(Line), model: Model) -> List(Line) {
  let drawn = case list.first(model.record_rows) {
    Ok(row) -> span.line_width(row) > 0
    Error(Nil) -> False
  }
  let wanted = drawn && transcript_lines.opens_bare(lines, BetweenEntries)

  case wanted {
    True -> [Line(Spacer, ""), ..lines]
    False -> lines
  }
}

// Each line is rendered independently, including its speaker prefix and
// trailing blank rows. Reusing that complete result preserves wrapping and
// styling without parsing or measuring unchanged text again. The next map is
// built only from current lines; hints from a replaced cut do not become an
// ever-growing store of discarded history.
fn cached_record_lines(
  lines: List(Line),
  width: Int,
  previous: Dict(Line, List(span.Line)),
) -> #(List(span.Line), Dict(Line, List(span.Line)), List(Int)) {
  list.fold(lines, #([], dict.new(), []), fn(acc, line) {
    let #(rows, cached, gutters) = acc
    let rendered =
      dict.get(previous, line)
      |> result.lazy_unwrap(fn() { render.render_line(line, width) })
    let rendered_count = list.length(rendered)
    let line_gutters =
      list.index_map(rendered, fn(_, index) {
        copy_gutter(line, index, rendered_count)
      })
    #(
      list.append(list.reverse(rendered), rows),
      dict.insert(cached, line, rendered),
      list.append(list.reverse(line_gutters), gutters),
    )
  })
}

// Cached wrapping is reused here; identity is supplied by the durable entry,
// never inferred from text equality. Equal user messages keep distinct anchors.
fn record_anchors_for(
  model: Model,
  width: Int,
) -> List(Option(transcript_anchor.Row)) {
  let entries =
    transcript_lines.strand_entries(model.records, model.active_strand)
  let notices = transcript_lines.active_notices(model)
  let blocks = case model.details_expanded {
    True -> {
      // The compact projection owns call/result association, including reused
      // provider IDs. Borrow that association rather than guessing it again.
      // The rewritten result block deliberately carries the call block's own
      // anchor id, which is what lets a compact row relocate into expanded
      // output; `transcript_anchor.relocate` resolves the resulting tie to the
      // result block, so the worst drift is one call block's height.
      let results =
        entries
        |> tool_activity.project
        |> list.flat_map(fn(item) {
          case item {
            tool_activity.Narrative(_) -> []
            tool_activity.Tools(calls) ->
              list.filter_map(calls, fn(call) {
                use source <- result.try(option.to_result(
                  call.result_source,
                  Nil,
                ))
                Ok(#(
                  ids.entry_id_to_string(source),
                  ids.entry_id_to_string(call.source)
                    <> "/call/"
                    <> call.invocation.id,
                ))
              })
          }
        })
        |> dict.from_list

      // The mirror of the entry-level separation `record_lines` applies in
      // this mode. It runs over the flattened blocks rather than over whole
      // entries, which reaches the same boundaries and no others: within a
      // response `anchored_entry_blocks` has already placed every spacer a
      // wider rule would ask for, and a spacer's own last row is blank, so a
      // second pass can only decline.
      entries
      |> transcript_lines.splice_notices(notices, transcript_lines.entry_holds)
      |> list.flat_map(fn(spliced) {
        case spliced {
          Transient(text, seq) -> #(seq, [#("", [Line(System, text)])])
          Projected(value) ->
            anchored_entry_blocks(value, model)
            |> list.map(fn(block) {
              #(dict.get(results, block.0) |> result.unwrap(block.0), block.1)
            })
            |> fn(blocks) { #(value.seq, blocks) }
        }
      })
      |> transcript_lines.separated_tool_blocks(BetweenEntries)
    }

    // The mirror of the item-level separation `record_lines` applies in
    // compact history. Inside a group or a response every spacer is already
    // placed, and a spacer's own row is blank, so this pass adds only the
    // gaps between items.
    False ->
      entries
      |> tool_activity.project
      |> transcript_lines.splice_notices(notices, transcript_lines.item_holds)
      |> list.flat_map(fn(spliced) {
        case spliced {
          Transient(text, seq) -> #(seq, [#("", [Line(System, text)])])
          Projected(tool_activity.Narrative(value)) -> #(
            value.seq,
            anchored_entry_blocks(value, model),
          )
          Projected(tool_activity.Tools(calls)) -> {
            let heading = [transcript_lines.activity_heading(calls)]
            let called =
              list.map(calls, fn(call) {
                #(
                  ids.entry_id_to_string(call.source)
                    <> "/call/"
                    <> call.invocation.id,
                  dict.get(model.compact_call_cache, call)
                    |> result.lazy_unwrap(fn() {
                      transcript_lines.activity_call_lines(call)
                    }),
                )
              })
            [
              #("", heading),
              ..transcript_lines.separated_tool_blocks(called, WithinResponse)
            ]
          }
        }
      })
      |> transcript_lines.separated_tool_blocks(BetweenEntries)
  }
  [#("", model.transcript), ..blocks]
  |> list.flat_map(fn(block) {
    block.1
    |> list.index_map(fn(line, part) { #(line, part) })
    |> list.flat_map(fn(pair) {
      let rendered =
        dict.get(model.record_line_cache, pair.0)
        |> result.lazy_unwrap(fn() { render.render_line(pair.0, width) })
      list.index_map(rendered, fn(_, wrapped) {
        case block.0 {
          "" -> None
          id -> Some(transcript_anchor.Row(id, pair.1, wrapped))
        }
      })
    })
  })
  |> list.reverse
}

// Tool calls keep the same block identity in compact and expanded views.
// Provider IDs are qualified by their durable owner, since a later response
// may legitimately reuse them. Text and reasoning use their source index.
fn anchored_entry_blocks(value: entry.Entry, model: Model) {
  let details = model.details_expanded
  let owner = transcript_lines.solo_owner(model.captured)
  let id = ids.entry_id_to_string(value.id)
  case value {
    entry.MessageEntry(
      message: message.AssistantMessage(
        content:,
        error_message:,
        stop_reason:,
        ..,
      ),
      ..,
    ) -> {
      let blocks =
        list.index_map(content, fn(block, index) {
          let key = case block {
            message.AssistantToolCall(call) -> id <> "/call/" <> call.id
            message.AssistantText(..) | message.AssistantThinking(..) ->
              id <> "/block/" <> int.to_string(index)
          }
          #(key, transcript_lines.assistant_block_lines(block, details))
        })
        |> transcript_lines.separated_tool_blocks(WithinResponse)
      let terminal =
        transcript_lines.assistant_terminal_lines(stop_reason, error_message)
      case terminal {
        [] -> blocks
        _ -> list.append(blocks, [#(id <> "/terminal", terminal)])
      }
    }
    _ -> [#(id, transcript_lines.entry_lines(value, details, owner))]
  }
}

// The live tail is parsed afresh on every call rather than memoized: a memo
// would pin one more generation of the live region than the retained-bytes
// gate on streaming has headroom for, and it would save a few parses a
// second rather than one per frame.
//
// The viewport consumes rows newest-first. Keeping that order in the cache
// makes each live frame prepend only the small transient stream projection.
fn rendered_layout_for(
  model: Model,
  width: Int,
) -> #(List(span.Line), List(Int)) {
  case model.help_open, model.notes_open {
    True, _ -> {
      let rows =
        render.help_content().lines
        |> markdown.wrap_lines(width)
        |> list.reverse
      #(rows, list.repeat(0, list.length(rows)))
    }
    False, True -> {
      // Notes render against their actual rectangle in `render_transcript`.
      #([], [])
    }
    False, False -> {
      let lines =
        option.lazy_unwrap(model.reading_lines, fn() { transient_lines(model) })
      let #(transient_rows, transient_gutters) = rendered_lines(lines, width)
      #(
        transient_rows |> list.reverse |> list.append(model.record_rows),
        transient_gutters |> list.reverse |> list.append(model.record_gutters),
      )
    }
  }
}

// Rows and copy gutters are emitted together so a live stream is parsed and
// wrapped once. The metadata is an integer per row, not another text tree.
fn rendered_lines(
  lines: List(Line),
  width: Int,
) -> #(List(span.Line), List(Int)) {
  list.fold(lines, #([], []), fn(acc, line) {
    let #(rows, gutters) = acc
    let rendered = render.render_line(line, width)
    let rendered_count = list.length(rendered)
    let line_gutters =
      list.index_map(rendered, fn(_, index) {
        copy_gutter(line, index, rendered_count)
      })
    #(list.append(rows, rendered), list.append(gutters, line_gutters))
  })
}

// Only prefixes whose ownership is explicit in `speaker_rows` are removed.
// Assistant Markdown and user blocks can contain arbitrary leading spaces;
// those begin after these fixed cells and are never inspected here.
fn copy_gutter(line: Line, index: Int, row_count: Int) -> Int {
  case line.speaker {
    Assistant | Reasoning if index > 1 -> 2
    User if index == 1 -> 1
    User if index > 1 && index < row_count - 1 -> 3
    ToolDetail -> 2
    System
    | User
    | Assistant
    | Reasoning
    | ReasoningDigest
    | ToolCall
    | ToolResult
    | ToolPatch
    | ToolFailure
    | Failure
    | Spacer -> 0
  }
}

// The live tail is a bounded, disposable observation. Scrollback retains one
// immutable projection so later fragments cannot reflow text under the reader.
fn transient_lines(model: Model) -> List(Line) {
  transcript_lines.stream_lines(
    transcript_lines.display_streams(model),
    model.active_strand,
    transcript_lines.details_extent(model.details_expanded),
  )
  |> list.append(transcript_lines.tool_tail_lines(model))
  |> list.append(transcript_lines.pending_input_lines(model))
  |> list.append(pending_nudge_lines(model))
  |> separated_from_screen(model)
}

// Advisor-only commentary is visible beside the primary's captured entries.
// The advisor's own branch retains its ordinary transcript instead.
fn visible_advisor_history(model: Model) -> advisor_history.Board {
  case model.active_strand {
    "main" -> model.advisor_history
    _ -> advisor_history.Board([], None)
  }
}

fn advisor_history_label(annotation: advisor_history.Annotation) -> String {
  case annotation {
    advisor_history.AdvisorUpdate -> "Advisor · commentary"
    advisor_history.RequestedQuiet -> "Advisor · quiet requested"
    advisor_history.RequestedNudge -> "Advisor · nudge requested"
    advisor_history.RequestedBlock -> "Advisor · block requested"
    advisor_history.RequestedContinue -> "Advisor · continue requested"
    advisor_history.RequestedComplete -> "Advisor · complete requested"
  }
}

// Pending advice is a labeled, disposable observation in the scrollable tail.
// It is never appended to durable records, and inspecting it does not deliver
// it. Keeping its complete body here prevents a long queue from taking the
// composer offscreen while still making every received line readable.
fn pending_nudge_lines(model: Model) -> List(Line) {
  case model.nudges {
    Some(board) if board.strand == model.active_strand && board.pending != [] -> {
      let heading =
        "Advisor · pending, not delivered · "
        <> int.to_string(board.total)
        <> " nudges"
      let rows =
        list.flat_map(board.pending, fn(body) {
          [Line(System, "Pending advisor nudge"), Line(ToolDetail, body)]
        })
      let omitted = case board.total > list.length(board.pending) {
        True -> [
          Line(
            System,
            "Additional nudges were not included in this observation",
          ),
        ]
        False -> []
      }
      [Line(System, heading), ..list.append(rows, omitted)]
    }
    Some(_) | None -> []
  }
}

// The rename overlay owns pasted text just as it owns character keys. It
// must never leave a pasted title in the hidden conversation composer.
fn handle_paste(model: Model, text: String) -> Model {
  case model.overlay {
    DaemonSelector(
      session_selector.State(prompt: session_selector.Renaming(..), ..) as selector,
    ) -> update_daemon_selector(keys.Char(text), model, selector)
    NoOverlay ->
      case layout.diff_shown(model), model.worktree.focus {
        True, worktree_view.Navigator -> model
        _, _ -> handle_underlay_paste(model, text)
      }
    AgentInspector(agents.Inspector(focus: agents.Composing, ..)) ->
      handle_underlay_paste(model, text)
    AgentInspector(_)
    | ModelSelector(_)
    | GoalInspector(_)
    | SessionSelector(_)
    | DaemonSelector(_)
    | ApprovalInspector(_) -> model
  }
}

fn handle_underlay_paste(model: Model, text: String) -> Model {
  use <- bool.guard(model.context.surface != context_view.Hidden, model)
  case model.queue_editor.surface {
    queue_editor.Editor ->
      edit_queue_text(model, fn(input) { insert_queue_paste(input, text) })
    queue_editor.Inspector -> model
    queue_editor.Closed ->
      case model.summary_surface {
        queue_editor.Closed -> handle_composer_paste(model, text)
        queue_editor.Editor | queue_editor.Inspector -> model
      }
  }
}

fn handle_composer_paste(model: Model, text: String) -> Model {
  case model.pending_submission {
    Some(_) -> outbound.waiting_notice(model)
    None -> paste_unlocked(model, text)
  }
}

fn paste_unlocked(model: Model, text: String) -> Model {
  case image_drop.load_paste(text) {
    Error(reason) -> tui_model.append_error(model, reason)
    Ok(Some(image)) -> add_attachment(model, composer.ImageAttachment(image))
    Ok(None) ->
      case composer.classify(text) {
        composer.Inline(text) -> {
          // Paste follows the editor's insertion path so an existing draft
          // and the cursor's suffix remain part of the next prompt.
          let editor = text_area.textarea_new() |> text_area.with_max_lines(0)
          let input =
            list.fold(string.to_graphemes(text), model.input, fn(state, char) {
              case char {
                "\n" -> text_area.newline(editor, state)
                _ -> text_area.insert_char(editor, state, char)
              }
            })
          Model(
            ..model,
            input:,
            history_index: 0,
            history_draft: text_area.value(input),
          )
        }
        composer.Compact(attachment) -> add_attachment(model, attachment)
      }
  }
}

fn add_attachment(model: Model, attachment: composer.Attachment) -> Model {
  case composer.admit_attachment(model.attachments, attachment) {
    Error(reason) -> tui_model.append_error(model, reason)
    Ok(attachments) -> {
      let notice =
        composer.summary(attachments) |> option.unwrap("pasted content")
      Model(..model, attachments:, notice:)
    }
  }
}

fn drain_candidate(model: Model) -> Model {
  let #(candidate, outcome) = attachment.poll(model.candidate)
  candidate_outcome(model, candidate, outcome)
}

/// Applies one driver-selected candidate event before later queued traffic.
///
/// ## Examples
///
/// ```gleam
/// // tui.accept_candidate_event(model, event)
/// ```
@internal
pub fn accept_candidate_event(model: Model, event: attachment.Event) -> Model {
  let #(candidate, outcome) = attachment.accept(model.candidate, event)
  candidate_outcome(model, candidate, outcome)
}

/// Applies the terminal's selected candidate result without changing its owner.
///
/// ## Examples
///
/// ```gleam
/// // tui.candidate_outcome(model, candidate, outcome)
/// ```
@internal
pub fn candidate_outcome(model: Model, candidate, outcome) -> Model {
  let model = Model(..model, candidate: candidate)
  case outcome {
    None -> model
    Some(attachment.Failed(reason)) ->
      tui_model.append_error(
        cancel_pending(model, "target change from " <> model.session),
        "open session: " <> reason,
      )
    Some(attachment.Adopted(
      channel,
      cut,
      view,
      inbox,
      workspace,
      name,
      creation_key,
    )) -> {
      // `cancel_pending` below appends its own "Not sent: … ; draft retained"
      // notice, but `render_cut` replaces the whole transcript with the new
      // session's, so that line does not survive this arm. The fact still has
      // to reach the operator, so it is re-issued after the cut. Reading the
      // draft here rather than afterwards is what makes that possible: by
      // then the pending slot is already cleared.
      let cancelled = case model.pending_submission {
        Some(_) ->
          Some(
            "Not sent: target changed from "
            <> model.session
            <> "; draft retained",
          )
        None -> None
      }
      let model = cancel_pending(model, "target change from " <> model.session)

      // Retirement runs while the old channel's session is still the visible
      // one: its outcome is reported against the identity that produced it,
      // and a sent request keeps that identity rather than acquiring the new
      // session's.
      let model = retire_previous(model)
      let target_strand = case
        model.session == cut.attachment.expected.session
      {
        True -> model.active_strand
        False -> "main"
      }
      let model =
        select_workspace(model, cut.attachment.expected.session, target_strand)

      let model =
        Model(..model, scrollback: history_view.cancel(model.scrollback))

      // Only then is the old inbox drained. Draining first would discard
      // frames the retirement is entitled to reduce.
      sessions.discard(model.inbox)
      let adopted =
        Model(
          ..model,
          inbox: inbox,
          peer: case session_channel.socket(channel) {
            Some(socket) -> Attached(socket)
            None -> Replaying
          },
          channel: Some(channel),
          captured: None,
          note_board: None,
          note_selected: None,
          notes_requested: None,
          approvals: [],
          prompted_approvals: [],
          overlay: NoOverlay,
          creation_key: case creation_key {
            Some(key) if model.creation_key == Some(key) -> None
            Some(_) | None -> model.creation_key
          },
          workspace: workspace,
          active_strand: target_strand,
          agent_rows: case model.session == cut.attachment.expected.session {
            True -> model.agent_rows
            False -> []
          },
          session: cut.attachment.expected.session,
          session_label: Some(#(cut.attachment.expected.session, name)),
          records: [],
          streams: [],
          tool_tails: [],
          interrupt: None,
          submitting: None,
          // The new attachment's cut replaces the transcript wholesale, and
          // the submissions waiting here were made against the old one.
          queued: [],
          awaiting_outcome: None,
          models: [],
          skills: [],
          next_id: 1,
          record_cache_valid: False,
          // Every session's primary strand is named `main`, so a watch or a
          // notice carried over from the old session would be judged
          // against the wrong baseline: the new session's first usage row
          // would be compared to the old session's last one and drawn as a
          // miss that never happened.
          cache_watch: dict.new(),
          cache_seen_seq: dict.new(),
          cache_pending: dict.new(),
          cache_fence: dict.new(),
          cache_notices: [],
          cache_outlook: "",
          scroll_offset: case model.scrollback.mode {
            history_view.Reading -> model.scroll_offset
            history_view.Live -> 0
          },
        )
        |> apply_cut(cut, view)

      // The adoption marker is written after the cut, not before it. ADR-009
      // makes that ordering a correctness rule: a recording is replayed by
      // the same reducer, and a marker ahead of its cut would move the
      // visible session before the frames that justify it.
      session_channel.adopted(channel)
      let adopted =
        adopted
        |> outbound.send_frame(protocol.models(1))
        |> request_visible_worktree
      let adopted = Model(..adopted, reconnect: ReconnectIdle)
      case cancelled {
        Some(notice) -> tui_model.append_system(adopted, notice)
        None -> adopted
      }
    }
  }
}

// Consume the old channel's outcome while its session identity is still the
// visible one. Closing an already-sent request cannot imply it was rejected.
fn retire_previous(model: Model) -> Model {
  case model.channel {
    Some(previous) -> {
      let #(closed, updates) =
        session_channel.retire(previous, "attachment replaced")
      list.fold(
        updates,
        Model(..model, channel: Some(closed)),
        apply_channel_update,
      )
    }
    None -> {
      case model.peer {
        Attached(previous) -> connection.close(previous)
        Disconnected | Preview | Replaying -> Nil
      }
      model
    }
  }
}

fn tick_channel(model: Model) -> Model {
  case model.channel {
    None -> model
    Some(channel) -> {
      let #(channel, updates) = session_channel.tick(channel)
      list.fold(
        updates,
        Model(..model, channel: Some(channel)),
        apply_channel_update,
      )
      |> service_history
    }
  }
}

/// Folds one conversation-channel update into the model.
///
/// Public because it is the boundary a test drives to deliver a daemon reply
/// without standing up a socket; nothing outside this module calls it in a
/// running client.
pub fn apply_channel_update(
  model: Model,
  update: session_channel.Update,
) -> Model {
  case update {
    session_channel.Submission(disposition) ->
      outbound.apply_submission(model, disposition)
    session_channel.Captured(cut, view, trigger) ->
      reconcile_cut(model, cut, view, trigger)
    session_channel.HistoryPage(window, before, after) ->
      receive_history(model, window, before, after)
    session_channel.LookedUp(records, missing) -> {
      let inspected = inspect_looked_up(model, records, missing)
      let updated =
        Model(
          ..inspected,
          approvals: approval.decisions(model.approvals, records, missing),
        )
      let updated = case updated.captured {
        Some(#(cut, view)) -> render_cut(updated, cut, view, updated.approvals)
        None -> updated
      }
      case missing {
        [] -> updated
        _ ->
          tui_model.append_system(
            updated,
            "Decisions not available: " <> string.join(missing, ", "),
          )
      }
    }
    session_channel.Auxiliary(event) -> apply_event(model, event)
    session_channel.RequestRefused("history", _, code, message) ->
      tui_model.append_error(
        Model(..model, scrollback: history_view.cancel(model.scrollback)),
        "Older history: " <> code <> ": " <> message,
      )
    session_channel.RequestRefused(command, request_id, code, message) ->
      apply_request_refused(model, command, request_id, code, message)

    // Nothing here is visible, and that is the point: the count moves for
    // every notice the daemon pushed, including the ones a held sequence or
    // an in-flight refresh made redundant. The rendered frame is untouched,
    // so this cannot invalidate it.
    session_channel.Noticed(_) -> Model(..model, notices: model.notices + 1)

    // A pushed fragment is the same thing the directly attached client
    // receives as a stream delta, so it lands in the same live-stream region
    // by the same route rather than through a second renderer.
    session_channel.Streamed(strand:, operation:, generation:, kind:, text:) ->
      apply_event(
        model,
        protocol.StreamDelta(strand:, operation:, generation:, kind:, text:),
      )
    session_channel.ToolStreamed(
      strand:,
      operation:,
      step:,
      source_index:,
      call_id:,
      stream:,
      text:,
      total_bytes:,
    ) ->
      apply_event(
        model,
        protocol.ToolOutput(
          strand:,
          operation:,
          step:,
          source_index:,
          call_id:,
          stream:,
          text:,
          total_bytes:,
        ),
      )

    // A prompt aimed at a busy strand used to come back as a conflict, with
    // the draft still the operator's problem. The daemon now holds it and
    // runs it on the strand's next turn, so the composer is done with it, and
    // nothing is running here yet, which is why the submitting indicator
    // clears rather than spinning until the held prompt starts. The transcript
    // already shows the line and says it is queued — the echo went in when the
    // frame was written — so this confirms the booking in the footer rather
    // than writing a second copy of the same news.
    session_channel.Acknowledged("edit_queued_input", "queued") ->
      Model(
        ..model,
        queue_editor: queue_editor.new(),
        notice: "queued input updated",
      )
      |> tui_model.invalidate_frame
    session_channel.Acknowledged("prompt", "queued") ->
      Model(
        ..settle_own_turn(model),
        submitting: None,
        notice: "prompt queued for the next turn",
      )
      |> tui_model.invalidate_frame

    // An abort ends the run, and with it every steer and follow-up the run
    // had not started yet: the queue drains those without committing them,
    // so no entry will ever arrive to retire their interjections. A held
    // prompt is not the run's to cancel — it waits in the gateway and drains
    // once the strand is idle — so the abort drops the interjections and
    // leaves the prompt echoes standing.
    session_channel.Acknowledged("abort", status) ->
      Model(..abandon_interjections(model), notice: "abort " <> status)
      |> tui_model.invalidate_frame

    // Every other acknowledgement settles its submission the same way: a
    // steer answered `admitted` will commit the entry its interjection is
    // waiting for. Commands that record nothing leave `awaiting_outcome`
    // empty and pass through untouched.
    session_channel.Acknowledged(command, status) ->
      Model(..settle_own_turn(model), notice: command <> " " <> status)
      |> tui_model.invalidate_frame
    session_channel.UnknownOutcome(command, request_id) ->
      tui_model.append_error(
        Model(
          ..model,
          queue_editor: case command {
            "edit_queued_input" -> queue_editor.unknown(model.queue_editor)
            _ -> model.queue_editor
          },
          unconfirmed: Some(UnconfirmedSubmission(
            model.session,
            command,
            request_id,
          )),
        ),
        "Last unconfirmed submission: " <> command <> "; not retried",
      )
    session_channel.Failed(reason) ->
      tui_model.append_error(
        Model(
          ..outbound.discard_own_turn(model),
          peer: after_close(model.peer),
          scrollback: history_view.cancel(model.scrollback),
          streams: [],
          tool_tails: [],
          queue_editor: queue_editor.refused(
            model.queue_editor,
            "Disconnected; draft retained",
          ),
          jobs_refresh: worktree_view.Settled,
          jobs_awaiting: None,
          jobs_notice: "Live jobs unavailable: conversation disconnected",
          nudges: None,
          nudges_refresh: worktree_view.Settled,
          nudges_awaiting: None,
          nudges_request: None,
          goal: None,
          goal_refresh: worktree_view.Settled,
          goal_awaiting: None,
          goal_request: None,
          goal_report: HoldGoalReport,
          overlay: case model.overlay {
            GoalInspector(_) -> NoOverlay
            other -> other
          },
          worktree: case model.worktree.awaiting {
            Some(id) ->
              worktree_view.receive(
                model.worktree,
                tui_model.queue_owner(model),
                worktree_view.Failed(id, "conversation disconnected"),
              )
            None -> model.worktree
          },
        ),
        "conversation: " <> reason,
      )
      |> begin_reconnect
  }
}

fn reconcile_cut(
  model: Model,
  cut: snapshot.Captured,
  view: snapshot_view.View,
  trigger: session_channel.Capture,
) -> Model {
  // Equal metadata still advances transport credit, but must not continually
  // restart animation or invalidate a transcript which has not changed. The
  // provenance is recorded only on the arm that paints: a notice-driven
  // catch-up that finds nothing new must not claim the answer a refresh
  // already painted, or a fixture reading it would call polling "push".
  case model.captured {
    Some(#(previous, _))
      if previous.next_seq == cut.next_seq && previous.metadata == cut.metadata
    -> present_pending_approval(Model(..model, captured: Some(#(cut, view))))
    Some(_) | None -> {
      let updated = apply_cut(Model(..model, last_capture: trigger), cut, view)
      let updated = case model.captured {
        Some(#(previous, _)) if previous.next_seq == cut.next_seq -> updated
        Some(_) | None -> request_visible_worktree(updated)
      }
      let disappeared =
        model.approvals
        |> list.filter(fn(old) {
          old.status == approval.Pending
          && !list.any(updated.approvals, fn(new) { new.id == old.id })
        })
        |> list.map(fn(record) { record.id })
      let updated = case list.take(disappeared, 8) {
        [] -> updated
        ids -> request_decisions(updated, ids)
      }
      case list.drop(disappeared, 8) {
        [] -> updated
        _ ->
          tui_model.append_system(
            updated,
            "Additional resolutions are not loaded; use /approvals <id>.",
          )
      }
    }
  }
}

fn request_decisions(model: Model, ids: List(String)) -> Model {
  case model.peer {
    // A replay performs no outbound effect and invents no line the live
    // client was not shown. Whatever the live client learned about these
    // decisions is already in the recording; a "conversation is not
    // attached" error here would be a line no live session ever produced.
    Replaying -> model

    Attached(_) | Disconnected | Preview ->
      case model.channel {
        None -> tui_model.append_error(model, "conversation is not attached")
        Some(channel) ->
          case session_channel.lookup(channel, ids) {
            Ok(channel) -> Model(..model, channel: Some(channel))
            Error(reason) ->
              tui_model.append_error(
                model,
                "decision lookup not sent: " <> reason,
              )
          }
      }
  }
}

fn apply_cut(
  model: Model,
  cut: snapshot.Captured,
  view: snapshot_view.View,
) -> Model {
  let reviews = case approval.records(view.cells) {
    Ok(current) -> approval.project(model.approvals, current)
    Error(_) -> []
  }
  render_cut(model, cut, view, reviews) |> present_pending_approval
}

// A question is offered once per exact sequence. Deferring one leaves it in
// /approvals, while a reopened request with the same ID is a new question.
fn present_pending_approval(model: Model) -> Model {
  case model.overlay, model.captured {
    NoOverlay, Some(#(cut, _)) if cut.attachment.role != snapshot.Observer -> {
      let seen =
        list.filter(model.prompted_approvals, fn(identity) {
          list.any(model.approvals, fn(record) {
            #(record.id, record.seq) == identity
          })
        })
      let unseen =
        list.find(model.approvals, fn(record) {
          record.status == approval.Pending
          && !list.contains(seen, #(record.id, record.seq))
        })
      case unseen {
        Error(Nil) -> Model(..model, prompted_approvals: seen)
        Ok(record) ->
          Model(
            ..model,
            prompted_approvals: [#(record.id, record.seq), ..seen],
            overlay: ApprovalInspector(captured_approval_panel(model, record)),
          )
      }
    }
    _, _ -> model
  }
}

fn render_cut(
  model: Model,
  cut: snapshot.Captured,
  view: snapshot_view.View,
  reviews: List(approval.Review),
) -> Model {
  // A disappearing strand never retargets a draft. The composer keeps its
  // identity and submission is refused until that target is available again.
  let active = model.active_strand
  let model = observe_completion(model, cut, view, active)
  let model = retain_queue_selection(model, view, active)
  let same_operation = case model.captured {
    Some(#(_, previous)) ->
      model.active_strand == active
      && dict.get(previous.operations, model.active_strand)
      == dict.get(view.operations, active)
    None -> False
  }
  let history = history_view.capture(model.scrollback, cut.window, view, active)
  let branch = history_view.branch(history, view)
  let current_model = case dict.get(view.configurations, active) {
    Ok(config) -> config.configuration.model.model_id
    Error(Nil) -> "unconfigured"
  }
  let #(cache_watch, cache_fence) = cache_watches_for_cut(model, view)
  let cache_outlook = case dict.get(cache_watch, active) {
    Ok(_) -> model.cache_outlook
    Error(Nil) -> ""
  }
  let role = case cut.attachment.role {
    snapshot.Owner -> "owner"
    snapshot.Operator -> "operator"
    snapshot.Observer -> "observer · read-only"
  }

  // The same coherent presence test governs both turn labels and the
  // attachment banner. A lone owner needs no redundant name or role; every
  // other attachment retains the full identity and participant count.
  let #(notice, attachment_banner) = case
    transcript_lines.solo_owner(Some(#(cut, view)))
  {
    Some(_) -> #("1 present", "Attached · 1 present")
    None -> {
      let identity =
        origin.display_label(cut.attachment.origin)
        <> " · "
        <> role
        <> " · "
        <> int.to_string(list.length(view.peers))
        <> " present"
      #(identity, "Attached as: " <> identity)
    }
  }
  let boundary = case branch.unloaded {
    None -> "Beginning of this conversation."
    Some(_) ->
      case history.request {
        history_view.Wanted | history_view.Pending(_) ->
          "Loading older conversation…"
        history_view.Quiet -> "Scroll up to load older conversation."
      }
  }
  let transcript = [
    Line(System, boundary),
    Line(System, attachment_banner),
    ..list.append(
      daemon_build_lines(model.daemon_host),
      list.append(
        configuration_lines(view, active),
        list.append(
          unconfirmed_lines(model.unconfirmed),
          approval_lines(reviews),
        ),
      ),
    )
  ]

  // Everything the record projection reads, so a cut that moved only usage,
  // phases or timestamps leaves the cache standing. Cuts arrive on a
  // quarter-second cadence throughout a turn, and invalidating on every one
  // of them made each a full re-projection of the whole session.
  let advisor_history = advisor_history.project(view, cut.window)
  let record_cache_valid =
    model.record_cache_valid
    && model.active_strand == active
    && model.records == branch.records
    && model.advisor_history == advisor_history
    && model.transcript == transcript
    && transcript_lines.solo_owner(model.captured)
    == transcript_lines.solo_owner(Some(#(cut, view)))

  // Request-scoped pushes outrun captures: a cut may have started before
  // the request that is streaming now. Retain those observations, including
  // terminal markers, until an exact durable last result proves retirement.
  // An unrelated idle cut cannot retire a newer request. This fallback also
  // covers relay failures which bypass the optional presentation observer.
  // Legacy recordings retain their operation-based law.
  let operation = dict.get(view.operations, active)
  let live =
    list.filter(model.streams, fn(stream) {
      stream.strand == active
      && { stream.generation != "" || operation == Ok(stream.operation) }
      && !snapshot_view.has_result(view, active, stream.operation)
      && !transcript_lines.response_recorded(branch.records, stream.generation)
    })

  // A captured tool-result names the exact provider call, so one completed
  // call can retire without removing its still-running peers. The operation's
  // last-result register remains the fallback when the bounded history window
  // no longer retains that entry.
  let live_tails =
    list.filter(model.tool_tails, fn(tail) {
      !snapshot_view.has_tool_result(
        view,
        cut.window,
        tail.strand,
        tail.call_id,
      )
      && !snapshot_view.has_result(view, tail.strand, tail.operation)
    })

  // Retired strands keep unsent drafts but release their bounded reading
  // windows. A future appearance must rebuild history from its own capture.
  let workspaces =
    prune_workspace_history(
      model.strand_workspaces,
      model.session,
      view.strands,
    )
  let reviewers = reviewer_status.observe(model.reviewer_rows, cut.window, view)
  let rows = agent_view.observe(model.agent_rows, cut.window, view, reviewers)
  let captured_messages =
    agent_messages.capture(model.agent_messages, view, cut.window)
  Model(
    ..model,
    captured: Some(#(cut, view)),
    approvals: reviews,
    active_strand: active,
    strands: view.strands,
    agent_summary: agents.summary_rows(rows),
    reviewer_rows: reviewers,
    agent_rows: rows,
    agent_messages: captured_messages,
    advisor_history:,
    records: branch.records,
    scrollback: history,
    strand_workspaces: workspaces,
    activity_started_ms: case same_operation {
      True -> model.activity_started_ms
      False -> None
    },
    activity_elapsed_s: case same_operation {
      True -> model.activity_elapsed_s
      False -> 0
    },
    usage: view.usage,
    current_model: current_model,
    cache_watch:,
    cache_fence:,
    cache_outlook:,
    streams: live,
    tool_tails: live_tails,
    interrupt: reconcile_interrupt(model.interrupt, view.operations),
    queued: case view.pending_inputs {
      Some(_) -> []
      None -> model.queued
    },
    submitting: None,
    record_cache_valid:,
    // Presence already has its own banner. Repeated metadata captures must
    // not alternate that banner with streaming or operator feedback below.
    notice: case model.captured {
      None -> notice
      Some(_) -> model.notice
    },
    transcript:,
  )
  |> settle_pending_cache(cut.next_seq)
  |> reconcile_agent_message_selection
  |> tui_model.invalidate_transcript
  // A completed cut can make the operation idle before the next animation
  // tick. Invalidate the painted frame too; rebuilding transcript rows alone
  // leaves the old buffer current until an unrelated key or resize arrives.
  |> tui_model.invalidate_frame
  |> tui_model.mark_activity
}

fn configuration_lines(view: snapshot_view.View, active: String) {
  let configuration = case dict.get(view.configurations, active) {
    Ok(config) -> [
      Line(
        System,
        "Strand configuration: "
          <> config.configuration.model.model_id
          <> " · effort "
          <> thinking_name(config.configuration.thinking_level)
          <> changed_by(config.origin),
      ),
    ]
    Error(Nil) -> []
  }
  [
    Line(System, code_mode_status(view, active)),
    Line(
      System,
      "Shared settings: "
        <> view.settings.queue_mode
        <> " · "
        <> view.settings.tool_execution
        <> changed_by(view.settings.origin),
    ),
    ..configuration
  ]
}

// Availability comes from the live registry; enabling comes from this strand's
// captured configuration. A missing tool must never be described as ready.
fn code_mode_status(view: snapshot_view.View, active: String) -> String {
  case view.tools {
    None -> "code mode · host availability not reported"
    Some(tools) -> {
      let enabled = case dict.get(view.configurations, active) {
        Ok(config) ->
          list.contains(config.configuration.active_tool_names, "code_mode")
        Error(Nil) -> False
      }
      case list.contains(tools.registered, "code_mode"), enabled {
        True, True ->
          "code mode enabled · batches of reads, searches, and checks"
        True, False -> "code mode · disabled for this strand"
        False, _ ->
          "code mode unavailable · "
          <> option.unwrap(tools.code_mode_issue, "not registered by this host")
      }
    }
  }
}

fn changed_by(author: Option(message.Origin)) {
  case author {
    Some(author) -> " · changed by " <> origin.display_label(author)
    None -> ""
  }
}

fn thinking_name(level: machine_strand.ThinkingLevel) {
  case level {
    machine_strand.ThinkingOff -> "off"
    machine_strand.ThinkingMinimal -> "minimal"
    machine_strand.ThinkingLow -> "low"
    machine_strand.ThinkingMedium -> "medium"
    machine_strand.ThinkingHigh -> "high"
    machine_strand.ThinkingXHigh -> "xhigh"
    machine_strand.ThinkingMax -> "max"
  }
}

fn unconfirmed_lines(unconfirmed: Option(UnconfirmedSubmission)) {
  case unconfirmed {
    None -> []
    Some(last) -> [
      Line(
        System,
        "Last unconfirmed submission: session "
          <> last.session
          <> " · "
          <> last.command
          <> " #"
          <> int.to_string(last.request_id)
          <> "; not retried. Earlier unknown outcomes may remain.",
      ),
    ]
  }
}

fn inspect_looked_up(model: Model, records, missing) {
  // A lookup started before automatic presentation may finish while the
  // operator is reviewing another question. The visible record owns consent
  // until that dialog closes, including its selection and scroll position.
  case model.overlay, model.inspecting_approval {
    ApprovalInspector(_), _ -> Model(..model, inspecting_approval: None)
    _, Some(id) ->
      case list.find(records, fn(record: approval.Review) { record.id == id }) {
        Ok(record) ->
          Model(
            ..model,
            overlay: ApprovalInspector(captured_approval_panel(model, record)),
            inspecting_approval: None,
          )
        Error(Nil) ->
          case list.contains(missing, id) {
            True -> Model(..model, inspecting_approval: None)
            False -> model
          }
      }
    _, None -> model
  }
}

fn approval_lines(reviews: List(approval.Review)) {
  let lines =
    reviews
    |> list.take(8)
    |> list.map(fn(record) {
      let state = case record.status {
        approval.Pending -> "pending"
        approval.Approved -> "approved"
        approval.Rejected -> "rejected"
        approval.Consumed -> "consumed"
      }
      let author = case record.origin {
        Some(author) -> " · " <> origin.display_label(author)
        None -> ""
      }
      Line(
        System,
        "Approval "
          <> record.id
          <> " · "
          <> state
          <> author
          <> " · "
          <> string.slice(record.preview, 0, 256),
      )
    })
  case list.drop(reviews, 8) {
    [] -> lines
    _ ->
      list.append(lines, [
        Line(
          System,
          "More decisions are captured; /approvals <id> loads an exact decision.",
        ),
      ])
  }
}

// The panel returns its captured review. Looking the ID up again here would
// replace the displayed question with a newer record the operator never saw.
fn decide_captured_approval(
  model: Model,
  record: approval.Review,
  choice: approval_panel.Choice,
) -> Model {
  case outbound.mutation_refusal(model, command.Approve(record.id)) {
    Some(reason) -> tui_model.append_error(model, reason)
    None -> {
      let encoded = case choice {
        approval_panel.AllowOnce -> approval.approve(model.next_id, record)
        approval_panel.AllowSession ->
          approval.approve_for_session(model.next_id, record)
        approval_panel.Deny -> approval.deny(model.next_id, record)
      }
      case encoded {
        Error(reason) -> tui_model.append_error(model, reason)
        Ok(frame) ->
          outbound.send_frame(Model(..model, overlay: NoOverlay), frame)
      }
    }
  }
}

fn decide(
  model: Model,
  id: String,
  encode: fn(Int, approval.Review) -> Result(String, String),
) -> Model {
  case list.find(model.approvals, fn(record) { record.id == id }) {
    Error(Nil) ->
      tui_model.append_error(
        model,
        "decision is not displayed; load /approvals " <> id <> " first",
      )
    Ok(record) ->
      case encode(model.next_id, record) {
        Error(reason) -> tui_model.append_error(model, reason)
        Ok(frame) -> outbound.send_frame(model, frame)
      }
  }
}

fn drain_session_switch(model: Model) -> Model {
  case sessions.receive(model.session_switch) {
    Error(Nil) -> model
    Ok(message) -> handle_session_switch_message(model, message)
  }
}

fn handle_session_switch_message(
  model: Model,
  message: sessions.Message,
) -> Model {
  case message {
    sessions.Failed(session, reason) ->
      tui_model.append_error(
        Model(..model, session_switch: sessions.Idle),
        "open session " <> session <> ": " <> reason,
      )
      |> tui_model.mark_activity
    sessions.WorkerCrashed(session, reason) ->
      tui_model.append_error(
        Model(..model, session_switch: sessions.Idle),
        "open session " <> session <> " crashed: " <> reason,
      )
      |> tui_model.mark_activity
    sessions.Ready(choice, options, target, inbox, socket) ->
      case connection.adopt(socket) {
        Error(reason) -> {
          connection.close(socket)
          sessions.discard(inbox)
          tui_model.append_error(
            Model(..model, session_switch: sessions.Idle),
            "open session " <> target.session <> ": " <> reason,
          )
          |> tui_model.mark_activity
        }
        Ok(Nil) -> adopt_session(model, choice, options, target, inbox, socket)
      }
  }
}

fn adopt_session(
  model: Model,
  choice: bootstrap.SessionChoice,
  options: bootstrap.Options,
  target: bootstrap.Target,
  inbox: Subject(connection.Message),
  socket: connection.Connection,
) -> Model {
  let model = select_workspace(model, target.session, "main")
  case model.peer {
    Attached(socket: previous) -> connection.close(previous)
    Preview | Replaying | Disconnected -> Nil
  }

  // Frames the old socket already delivered would otherwise sit unread in
  // the terminal mailbox for every later selective receive to scan past. The
  // close notice it sends after this point is the only residue, one frame.
  sessions.discard(model.inbox)
  Model(
    ..model,
    help_open: False,
    notes_open: False,
    note_board: None,
    note_selected: None,
    notes_requested: None,
    overlay: NoOverlay,
    session: target.session,
    local_options: Some(options),
    inbox:,
    peer: Attached(socket:),
    session_switch: sessions.Idle,
    next_id: 4,
    transcript: [Line(System, "connecting to session " <> target.session)],
    records: [],
    models: [],
    skills: [],
    queued: [],
    awaiting_outcome: None,
    current_model: "loading…",
    workspace: workspace.discover_from(choice.workspace),
    strands: [],
    agent_summary: agents.summary([]),
    reviewer_rows: [],
    active_strand: "main",
    usage: zero_usage(),
    interrupt: None,
    submitting: None,
    streams: [],
    reading_lines: None,
    tool_tails: [],
    scroll_offset: 0,
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
    frame_cache: None,
    notice: "connecting to session " <> target.session,
    repaint_phase: !model.repaint_phase,
  )
  |> tui_model.invalidate_transcript
  |> tui_model.mark_activity
  |> tui_model.invalidate_frame
}

fn drain_connection(model: Model, remaining: Int) -> Model {
  // The budget is checked before receiving: an eager second case subject
  // would remove and discard the first message belonging to the next batch.
  case remaining <= 0 {
    True -> model
    False ->
      case connection.receive(model.inbox) {
        Error(Nil) -> model
        Ok(message) ->
          drain_connection(
            handle_connection_message(model, message),
            remaining - 1,
          )
      }
  }
}

/// Applies an already selected socket message through the shipped reducer.
///
/// A driver calls this before running later ticks, rather than requeueing into
/// a concurrently written inbox and potentially placing newer traffic first.
///
/// ## Examples
///
/// ```gleam
/// // tui.accept_connection_message(model, incoming)
/// ```
@internal
pub fn accept_connection_message(
  model: Model,
  incoming: connection.Message,
) -> Model {
  handle_connection_message(model, incoming)
}

fn handle_connection_message(
  model: Model,
  incoming: connection.Message,
) -> Model {
  case model.channel {
    Some(channel) -> {
      let #(channel, updates) = session_channel.receive(channel, incoming)
      list.fold(
        updates,
        Model(..model, channel: Some(channel)),
        apply_channel_update,
      )
    }
    None -> {
      recording.note_message(model.recorder, incoming)
      handle_presentation_message(model, incoming)
    }
  }
}

fn handle_presentation_message(
  model: Model,
  incoming: connection.Message,
) -> Model {
  case incoming {
    connection.Connected ->
      Model(..model, notice: "connected")
      |> tui_model.mark_activity
      |> tui_model.invalidate_frame
    connection.Closed(reason) ->
      tui_model.append_error(
        Model(
          ..model,
          peer: after_close(model.peer),
          streams: [],
          tool_tails: [],
        ),
        "connection closed: " <> reason,
      )
      |> begin_reconnect
      |> tui_model.mark_activity
    connection.NetworkFault(reason) ->
      tui_model.append_error(model, "network: " <> reason)
      |> tui_model.mark_activity
    connection.Incoming(text) ->
      case protocol.decode_event(text) {
        Ok(event) -> apply_event(model, event)
        Error(reason) ->
          tui_model.append_error(model, "protocol: " <> reason)
          |> tui_model.mark_activity
      }
  }
}

fn apply_event(model: Model, event: protocol.Event) -> Model {
  let updated = case event {
    protocol.FullSnapshot(session:, strands:, entries:, usage:) -> {
      let target = case model.session == session {
        True -> model.active_strand
        False -> "main"
      }
      let model = select_workspace(model, session, target)
      Model(
        ..model,
        session:,
        active_strand: target,
        strands:,
        agent_summary: agents.summary(strands),
        usage:,
        records: list.reverse(entries),
        streams: [],
        tool_tails: [],
        record_rows: [],
        record_gutters: [],
        record_line_cache: dict.new(),
        compact_call_cache: dict.new(),
        compact_entry_cache: dict.new(),
        // The snapshot is the server's own account of the strand, so it
        // already carries every submission the daemon committed while this
        // client was away — the gateway holds its queue across a disconnect
        // and drains it regardless. An echo kept across the rebuild would sit
        // under the committed copy of itself.
        queued: [],
        awaiting_outcome: None,
        pending_records: [],
        record_cache_valid: False,
        submitting: None,
        scroll_offset: 0,
        notice: "session synchronized",
        transcript: [Line(System, "attached to session " <> session)],
      )
      |> tui_model.invalidate_transcript
    }
    protocol.StrandsSnapshot(strands:) -> {
      let summary = agents.summary(strands)
      Model(..model, strands:, agent_summary: summary)
    }
    protocol.SkillsSnapshot(page:) -> {
      let previous = case page.offset {
        0 -> []
        _ -> model.skills
      }
      case page.offset == list.length(previous) {
        False ->
          tui_model.append_error(
            model,
            "skill catalogue page arrived out of order",
          )
        True -> {
          let loaded =
            Model(..model, skills: list.append(previous, page.commands))
          case page.next {
            None -> loaded
            Some(offset) ->
              outbound.send_frame(
                loaded,
                protocol.skills(loaded.next_id, offset),
              )
          }
        }
      }
    }
    protocol.ModelsSnapshot(models:) -> {
      let overlay = case model.overlay {
        ModelSelector(selector) ->
          ModelSelector(model_selector.replace_models(
            selector,
            models,
            model.current_model,
          ))
        NoOverlay -> NoOverlay
        AgentInspector(selected) -> AgentInspector(selected)
        GoalInspector(state) -> GoalInspector(state)
        SessionSelector(selector) -> SessionSelector(selector)
        DaemonSelector(selector) -> DaemonSelector(selector)
        ApprovalInspector(panel) -> ApprovalInspector(panel)
      }
      Model(
        ..model,
        models:,
        overlay:,
        notice: int.to_string(list.length(models)) <> " models loaded",
      )
      |> outbound.send_frame(protocol.skills(model.next_id, 0))
    }
    protocol.SchedulesSnapshot(schedules:) -> append_schedules(model, schedules)
    protocol.ConfigSnapshot(model_name:, directories:) -> {
      let model = case model_name {
        Some(name) -> {
          let selected = select_model(model, name)
          Model(..selected, notice: "model: " <> name)
        }
        None -> model
      }
      case directories {
        None -> model
        Some(value) ->
          Model(
            ..model,
            notice: "Session directory access: " <> json.to_string(value),
          )
      }
    }
    protocol.LiveJobsSnapshot(board) -> surfaces.receive_jobs(model, board)
    protocol.AdvisorPendingSnapshot(board) ->
      surfaces.receive_advisor_nudges(model, board)
    protocol.GoalSnapshot(board) -> surfaces.receive_goal(model, board)
    protocol.ContextSnapshot(observation) ->
      Model(
        ..model,
        context: context_view.receive(
          model.context,
          tui_model.queue_owner(model),
          observation,
        ),
      )
    protocol.WorktreeSnapshot(observation) ->
      Model(
        ..model,
        worktree: worktree_view.receive(
          model.worktree,
          tui_model.queue_owner(model),
          observation,
        ),
      )
      |> tui_model.invalidate_transcript
    protocol.QueuedInputSnapshot(document) ->
      Model(
        ..model,
        queue_editor: queue_editor.receive(
          model.queue_editor,
          tui_model.queue_owner(model),
          tui_model.queue_namespace(model),
          document,
        ),
      )
    protocol.NotesSnapshot(board) ->
      case board.strand == surfaces.notes_target(model) {
        True -> {
          let previous = case model.note_board {
            Some(old) if old.strand == board.strand ->
              render.selected_note(model, old)
            _ -> model.note_selected
          }
          let selected =
            render.selected_note(Model(..model, note_selected: previous), board)
          let scroll = case model.note_board, selected == model.note_selected {
            Some(old), True if old.strand == board.strand ->
              int.min(
                model.note_scroll,
                note_max_scroll(
                  Model(
                    ..model,
                    note_board: Some(board),
                    note_selected: selected,
                  ),
                ),
              )
            None, True | Some(_), True | None, False | Some(_), False -> 0
          }
          tui_model.invalidate_transcript(
            Model(
              ..model,
              note_board: Some(board),
              note_selected: selected,
              note_scroll: scroll,
              notice: "notes refreshed for " <> board.strand,
            ),
          )
        }
        False -> model
      }
    protocol.EntryAdded(record:) -> {
      let protocol.EntryRecord(strand:, ..) = record
      let updated =
        Model(
          ..model,
          records: [record, ..model.records],
          streams: transcript_lines.clear_streams(model.streams, strand),
          tool_tails: retire_recorded_tail(model.tool_tails, record),
          pending_records: case strand == model.active_strand {
            True -> [record, ..model.pending_records]
            False -> model.pending_records
          },
          // A committed user turn on this strand is the daemon draining the
          // head of its queue, so the echo standing in for it goes away.
          queued: case strand == model.active_strand {
            True -> drained_echoes(model.queued, record)
            False -> model.queued
          },
        )
      case strand == model.active_strand {
        True -> tui_model.invalidate_transcript(updated)
        False -> updated
      }
    }
    protocol.StreamDelta(strand:, operation:, generation:, kind:, text:) -> {
      // The generation clock normally started when the strand entered
      // its `assistant` phase (see `OperationChanged`); a fragment that
      // finds it unset is the fallback, for a phase sequence that never
      // said so. Later fragments, and other strands, leave it alone.
      let generation_started_ms = generation_clock(model, strand)
      let updated =
        Model(
          ..model,
          streams: receive_stream(
            streams_before_end(model, strand, operation, generation, kind),
            strand,
            operation,
            generation,
            kind,
            text,
          ),
          generation_started_ms:,
          notice: case kind {
            "end" -> "request finished"
            _ -> "streaming " <> kind
          },
        )
      case strand == model.active_strand {
        True -> tui_model.invalidate_transcript(updated)
        False -> updated
      }
    }
    protocol.OperationChanged(strand:, phase:) -> {
      let submitting = case model.submitting {
        Some(target) if target == strand -> None
        other -> other
      }
      let strands = set_strand_phase(model.strands, strand, phase)

      // The rate's clock starts when the request goes out, not when the
      // first fragment lands. A provider that streams whole parts —
      // Gemini does — can deliver a short reply as one burst at the end
      // of a generation, and a clock started on that burst measured a
      // millisecond and reported six-figure tokens per second.
      let generation_started_ms = case phase {
        "assistant" -> generation_clock(model, strand)
        _other -> model.generation_started_ms
      }

      let updated =
        Model(
          ..model,
          submitting:,
          strands:,
          generation_started_ms:,
          agent_summary: agents.summary(strands),
          streams: case phase == "done" {
            True -> transcript_lines.clear_streams(model.streams, strand)
            False -> model.streams
          },
          tool_tails: case phase == "done" {
            True -> clear_tails(model.tool_tails, strand)
            False -> model.tool_tails
          },
          notice: strand <> ": " <> phase,
        )
      let settled = settle_interrupt(updated, strand, phase)
      case phase == "done" && strand == model.active_strand {
        True -> tui_model.invalidate_transcript(settled)
        False -> settled
      }
    }

    // A tail replaces the one it supersedes rather than joining a list:
    // the frame carries the whole window, so the newest is the only one
    // worth drawing, and the region cannot grow with the command's output.
    protocol.ToolOutput(
      strand:,
      operation:,
      step:,
      source_index:,
      call_id:,
      stream:,
      text:,
      total_bytes:,
    ) -> {
      let updated =
        Model(
          ..model,
          tool_tails: receive_tail(
            model.tool_tails,
            ToolTail(
              strand:,
              operation:,
              step:,
              source_index:,
              call_id:,
              stream:,
              text:,
              total_bytes:,
            ),
          ),
        )
      case strand == model.active_strand {
        True -> tui_model.invalidate_transcript(updated)
        False -> updated
      }
    }
    protocol.UsageChanged(strand:, seq:, operation:, usage: settled) ->
      case seq {
        Some(seq) ->
          receive_usage_observation(model, strand, seq, operation, settled)
        None -> receive_usage(model, strand, settled)
      }

    protocol.EscalationPending(id:, tool:, preview: _) ->
      tui_model.append_error(
        model,
        "approval required for " <> tool <> " [" <> id <> "]",
      )

    // The refusal answers whatever this terminal last submitted, because the
    // conversation channel carries one mutation at a time. A prompt refused
    // for a full hold queue commits no entry, so its echo is retired here or
    // never.
    protocol.ServerError(code:, message:) ->
      tui_model.append_error(
        Model(..outbound.discard_own_turn(model), submitting: None),
        code <> ": " <> message,
      )

    // A commit notice and a metadata change say only that the next capture
    // will differ. `tui/session_channel` acts on them by capturing; there is
    // nothing for a renderer to draw from the frame itself.
    protocol.Committed(..) | protocol.MetadataChanged -> model

    // A resumed marker names a stream that continues from a cut this
    // terminal already holds. The lane reports it as its own update, so a
    // frame arriving outside one is nothing to paint.
    protocol.Resumed(_) -> model
    protocol.Ignored(_) -> model

    // The draining daemon handed a held prompt back, unsent. The held
    // queue is memory-only, so this push is the draft's last copy: restore
    // it into the composer rather than letting the operator's text die
    // with the daemon. An empty composer takes the text outright; an
    // occupied one keeps what the operator is typing, and the return is
    // appended below it — both are theirs, and neither may be lost.
    // The return carries no attachment bytes. Its count tells the operator
    // which images must be reattached before submitting the restored draft.
    protocol.HeldInputReturned(strand:, kind:, text:, attachment_count:, ..) ->
      restore_returned_draft(model, strand, kind, text, attachment_count)
  }
  case event {
    protocol.Committed(..) | protocol.MetadataChanged -> updated
    protocol.Resumed(_) -> updated
    protocol.HeldInputReturned(..) -> updated
    protocol.Ignored(_) -> updated
    protocol.FullSnapshot(..)
    | protocol.StrandsSnapshot(..)
    | protocol.ModelsSnapshot(..)
    | protocol.SkillsSnapshot(..)
    | protocol.NotesSnapshot(..)
    | protocol.QueuedInputSnapshot(..)
    | protocol.ContextSnapshot(..)
    | protocol.WorktreeSnapshot(..)
    | protocol.LiveJobsSnapshot(..)
    | protocol.AdvisorPendingSnapshot(..)
    | protocol.GoalSnapshot(..)
    | protocol.SchedulesSnapshot(..)
    | protocol.ConfigSnapshot(..)
    | protocol.EntryAdded(..)
    | protocol.StreamDelta(..)
    | protocol.ToolOutput(..)
    | protocol.OperationChanged(..)
    | protocol.UsageChanged(..)
    | protocol.EscalationPending(..)
    | protocol.ServerError(..) ->
      updated
      |> tui_model.mark_activity
      |> tui_model.invalidate_frame
  }
}

// Restores a custody-returned prompt as a local draft (protocol-change/038).
//
// The daemon held the prompt only in memory, so the returned text must be
// retained before the socket closes. An untouched composer simply becomes the draft.
// A composer the operator is typing in keeps its text and grows the return
// below it, separated by a blank line: discarding either half would lose
// work the operator can see, and silently replacing the draft would move
// text out from under the cursor. The notice names the strand and the
// images the text cannot carry, so nothing about the return is invisible.
fn restore_returned_draft(
  model: Model,
  strand: String,
  kind: String,
  text: String,
  attachment_count: Int,
) -> Model {
  // A return follows the prompt's original recipient even if the operator
  // has opened another strand since submitting it. Only that owner's draft
  // can accept the returned text.
  let model = case strand == model.active_strand {
    True -> Model(..model, input: append_returned_text(model.input, text))
    False -> {
      let owner = #(model.session, strand)
      let saved =
        dict.get(model.strand_workspaces, owner)
        |> result.unwrap(empty_workspace())
      let saved =
        StrandWorkspace(..saved, input: append_returned_text(saved.input, text))
      Model(
        ..model,
        strand_workspaces: dict.insert(model.strand_workspaces, owner, saved),
      )
    }
  }
  let images = case attachment_count {
    0 -> ""
    n ->
      " · "
      <> int.to_string(n)
      <> " attachment(s) stayed on the dead daemon — re-attach them"
  }
  tui_model.append_notice(
    model,
    "daemon returned the "
      <> kind
      <> " prompt held for "
      <> strand
      <> " — restored as a draft"
      <> images,
  )
}

// Keep both copies when the owner has continued typing before custody returns.
fn append_returned_text(
  input: text_area.TextAreaState,
  returned: String,
) -> text_area.TextAreaState {
  let current = text_area.value(input)
  let restored = case string.trim(current) {
    "" -> returned
    _ -> current <> "\n\n" <> returned
  }
  text_area.state_from_string(restored)
}

// One line per schedule, in the listing's own order — the operator's
// standing tables first, then what the session grew. `owner` is printed
// rather than derived: "operator" and a strand that happens to be called
// something similar are told apart by the server and never here.
fn append_schedules(model: Model, rows: List(protocol.ScheduleRow)) -> Model {
  case rows {
    [] -> tui_model.append_system(model, "no schedules")
    rows -> {
      let listed =
        list.fold(rows, model, fn(model, row) {
          tui_model.append_system(model, schedule_line(row))
        })
      Model(..listed, notice: int.to_string(list.length(rows)) <> " schedules")
    }
  }
}

fn schedule_line(row: protocol.ScheduleRow) -> String {
  string.join(
    [
      row.name,
      row.target,
      row.owner,
      row.when,
      int.to_string(row.fired) <> " fired",
      case row.wake {
        protocol.WakesIdle -> "wakes"
        protocol.SteersOnly -> "steers"
      },
    ],
    "  ",
  )
}

fn set_strand_phase(
  strands: List(protocol.Strand),
  target: String,
  phase: String,
) -> List(protocol.Strand) {
  list.map(strands, fn(strand) {
    let Strand(id:, ..) = strand
    case id == target, phase {
      True, "done" -> Strand(..strand, live_phase: None)
      True, _ -> Strand(..strand, live_phase: Some(phase))
      False, _ -> strand
    }
  })
}

// A client attaching near completion may have only a sampled preview, with
// no later delta before end. Transfer that exact sample into the bounded live
// region before adding the end marker; an older request's sample cannot qualify.
fn streams_before_end(
  model: Model,
  strand: String,
  operation: String,
  generation: String,
  kind: String,
) -> List(Stream) {
  use <- bool.guard(
    kind != "end"
      || stream_identity.response_entry(generation) == None
      || list.any(model.streams, fn(stream) { stream.strand == strand }),
    model.streams,
  )
  let preview = option.then(model.captured, fn(captured) { captured.1.preview })
  case preview {
    Some(sample)
      if sample.operation == operation && sample.generation == generation
    ->
      case transcript_lines.response_recorded(model.records, generation) {
        True -> model.streams
        False -> [
          transcript_lines.preview_stream(strand, sample),
          ..model.streams
        ]
      }
    _ -> model.streams
  }
}

// A provider request owns all its fragment kinds. A new request replaces
// them together; an old terminal can retire only its own request. Completion
// comes from the same observer as deltas, independent of snapshot timing.
fn receive_stream(
  streams: List(Stream),
  strand: String,
  operation: String,
  generation: String,
  kind: String,
  text: String,
) -> List(Stream) {
  // Completion is final for this exact request. Late fragments cannot
  // reopen it, while a successor still replaces the whole old generation.
  use <- bool.guard(
    kind != "end"
      && list.any(streams, fn(stream) {
      stream.strand == strand
      && stream.operation == operation
      && stream.generation == generation
      && stream.kind == "end"
    }),
    streams,
  )
  case kind {
    "end" -> {
      let newer =
        list.any(streams, fn(stream) {
          stream.strand == strand
          && {
            stream.operation != operation || stream.generation != generation
          }
        })
      case newer {
        True -> streams
        False -> {
          // A named response remains visible until its exact record replaces
          // it. The marker suppresses stale previews without copying text.
          let retained =
            list.filter(streams, fn(stream) {
              stream.strand != strand
              || {
                stream.kind != "end"
                && stream_identity.response_entry(generation) != None
              }
            })
          [Stream(strand, operation, generation, "end", [], 0), ..retained]
        }
      }
    }
    _ -> {
      let retained =
        list.filter(streams, fn(stream) {
          stream.strand != strand
          || {
            stream.operation == operation
            && stream.generation == generation
            && stream.kind != "end"
          }
        })
      append_stream(retained, strand, operation, generation, kind, text)
    }
  }
}

fn append_stream(
  streams: List(Stream),
  strand: String,
  operation: String,
  generation: String,
  kind: String,
  fragment: String,
) -> List(Stream) {
  let fragment = owned(fragment)
  let width = string.byte_size(fragment)
  case streams {
    [] -> [
      Stream(
        strand:,
        operation:,
        generation:,
        kind:,
        fragments: [fragment],
        bytes: width,
      ),
    ]
    [
      Stream(
        strand: owner,
        operation: current_op,
        generation: current_generation,
        kind: stream_kind,
        fragments: current,
        bytes: held,
      ),
      ..rest
    ] ->
      case owner == strand && stream_kind == kind {
        // A fragment from a later operation replaces the previous answer
        // rather than continuing it. Tool-call fragments never accumulate at
        // all: only the latest name is renderable until the entry commits.
        True -> {
          let #(fragments, bytes) = case
            kind == "tool_call" || current_op != operation
          {
            True -> #([fragment], width)
            False -> bounded([fragment, ..current], held + width)
          }
          [
            Stream(strand:, operation:, generation:, kind:, fragments:, bytes:),
            ..rest
          ]
        }
        False -> [
          Stream(
            strand: owner,
            operation: current_op,
            generation: current_generation,
            kind: stream_kind,
            fragments: current,
            bytes: held,
          ),
          ..append_stream(rest, strand, operation, generation, kind, fragment)
        ]
      }
  }
}

// A delta's text is a slice of the whole frame the socket delivered, so a
// model that keeps the slice keeps the frame: an answer of a hundred thousand
// tokens pinned a hundred thousand frames, which is most of what the resident
// terminals were made of. Rebuilding the string owns its bytes and lets the
// frame go, and at token size the copy is a few dozen bytes. This is the same
// reason, and the same remedy, as `gateway.preview_text`.
fn owned(text: String) -> String {
  text |> string.to_utf_codepoints |> string.from_utf_codepoints
}

// Past the budget the fragments are collapsed into one holding the newest
// bytes. Dropping the oldest one at a time would be the length of the answer
// per token; collapsing pays that once per budget's worth of tokens and
// leaves a single fragment for the next batch to accumulate against. What the
// reader loses is the head of an answer that has not committed yet, and the
// durable record replaces the whole region the moment it does.
//
// The trigger is twice what the collapse keeps, and the headroom is the whole
// point: collapsing back to exactly the limit would put the next token over
// it again, and the amortised cost would be the copy paid per token rather
// than once per budget. So the region is bounded by twice `live_stream_limit`
// rather than by it, and that is the number the invariant states.
fn bounded(fragments: List(String), bytes: Int) -> #(List(String), Int) {
  case bytes <= transcript_lines.live_stream_limit * 2 {
    True -> #(fragments, bytes)
    False -> {
      let newest =
        fragments
        |> list.reverse
        |> string.concat
        |> newest_bytes(transcript_lines.live_stream_limit)
      #([newest], string.byte_size(newest))
    }
  }
}

// The trailing `limit` bytes, backing off to the next character boundary when
// the cut would land inside a multi-byte one. Four attempts covers the widest
// UTF-8 sequence.
fn newest_bytes(text: String, limit: Int) -> String {
  let bytes = bit_array.from_string(text)
  let size = bit_array.byte_size(bytes)
  newest_suffix(bytes, int.max(0, size - limit), 4)
}

fn newest_suffix(bytes: BitArray, from: Int, attempts: Int) -> String {
  case attempts {
    0 -> ""
    _ -> {
      let taken =
        bit_array.slice(bytes, from, bit_array.byte_size(bytes) - from)
        |> result.try(bit_array.to_string)
      case taken {
        Ok(text) -> text
        Error(_) -> newest_suffix(bytes, from + 1, attempts - 1)
      }
    }
  }
}

// The tails this strand's calls are printing, newest frame winning per
// `{strand, operation, step, source_index, call_id, stream}`. Order is kept stable — a
// replaced tail keeps its place and a new key goes to the end — so two
// streams of one command do not swap positions on screen every time one
// of them speaks.
fn receive_tail(tails: List(ToolTail), incoming: ToolTail) -> List(ToolTail) {
  let same_key = fn(tail: ToolTail) {
    tail.strand == incoming.strand
    && tail.operation == incoming.operation
    && tail.step == incoming.step
    && tail.source_index == incoming.source_index
    && tail.call_id == incoming.call_id
    && tail.stream == incoming.stream
  }
  case list.any(tails, same_key) {
    True ->
      list.map(tails, fn(tail) {
        case same_key(tail) {
          True -> incoming
          False -> tail
        }
      })
    False ->
      case list.length(tails) >= transcript_lines.max_tool_tails {
        True -> list.append(list.drop(tails, 1), [incoming])
        False -> list.append(tails, [incoming])
      }
  }
}

fn clear_tails(tails: List(ToolTail), strand: String) -> List(ToolTail) {
  list.filter(tails, fn(tail) { tail.strand != strand })
}

fn retire_recorded_tail(
  tails: List(ToolTail),
  record: protocol.EntryRecord,
) -> List(ToolTail) {
  let protocol.EntryRecord(strand:, entry:) = record
  case entry {
    entry.MessageEntry(
      message: message.ToolResultMessage(tool_call_id:, ..),
      ..,
    ) ->
      list.filter(tails, fn(tail) {
        tail.strand != strand || tail.call_id != tool_call_id
      })
    _ -> tails
  }
}

fn zero_usage() -> message.Usage {
  message.Usage(
    input: 0,
    output: 0,
    cache_read: 0,
    cache_write: 0,
    cache_write_1h: None,
    reasoning: None,
    total_tokens: 0,
    cost: message.UsageCost(
      input: 0.0,
      output: 0.0,
      cache_read: 0.0,
      cache_write: 0.0,
      total: 0.0,
    ),
  )
}

// Everything one usage row changes about the model.
//
// The row arrives once per settled generation, so this is both the moment
// the output rate is known and the moment the prompt cache can be judged.
// Both readings are per event rather than cumulative, which is why they sit
// here rather than in the status-line arithmetic over `model.usage`.
fn receive_usage(
  model: Model,
  strand: String,
  settled: message.Usage,
) -> Model {
  let usage = add_usage(model.usage, settled)
  let updated =
    settle_usage(
      model,
      strand,
      settled,
      transcript_lines.tokens(usage.total_tokens) <> " tokens",
    )
  watch_cache(Model(..updated, usage:), strand, settled)
}

// A network push is an observation of one durable row, not a second owner of
// session totals. A capture may already include its sequence, or a delayed
// push may arrive after that capture; only the capture sets cumulative usage.
// Sequence identity prevents duplicate pushes from resetting the cache clock.
// The cache comparison waits for a cut that covers this sequence, since a
// remote model change can reach the socket before its configuration capture.
fn receive_usage_observation(
  model: Model,
  strand: String,
  seq: Int,
  operation: Option(String),
  settled: message.Usage,
) -> Model {
  let seen = dict.get(model.cache_seen_seq, strand) |> result.unwrap(-1)
  use <- bool.guard(when: seq <= seen, return: model)

  // A first row already included in a capture may have belonged to an
  // operation accepted under the previous model. The gateway can deliver
  // its push after the cut, so it cannot seed this strand's cache baseline.
  let already_covered = case
    model.captured,
    dict.get(model.cache_seen_seq, strand)
  {
    Some(#(cut, _)), Error(Nil) if seq < cut.next_seq -> True
    _, _ -> False
  }
  let observed =
    Model(
      ..model,
      cache_seen_seq: dict.insert(model.cache_seen_seq, strand, seq),
      cache_pending: case already_covered {
        True -> model.cache_pending
        False ->
          dict.insert(
            model.cache_pending,
            strand,
            CacheObservation(
              seq:,
              operation:,
              usage: settled,
              at: model.monotonic_time_ms(),
            ),
          )
      },
    )
    |> settle_usage(
      strand,
      settled,
      transcript_lines.tokens(settled.total_tokens) <> " tokens this turn",
    )
  case observed.captured {
    Some(#(cut, _)) -> settle_pending_cache(observed, cut.next_seq)
    None -> observed
  }
}

// A cut covers every committed row below next_seq and supplies the model
// configuration needed to compare its usage safely. Keep newer observations
// pending; the committed notice or periodic refresh will fetch their cut.
fn settle_pending_cache(model: Model, next_seq: Int) -> Model {
  dict.to_list(model.cache_pending)
  |> list.fold(model, fn(current, item) {
    let #(strand, CacheObservation(seq:, operation:, usage:, at:)) = item
    case seq < next_seq {
      True ->
        observed_cache_row(
          Model(
            ..current,
            cache_pending: dict.delete(current.cache_pending, strand),
          ),
          strand,
          operation,
          usage,
          at,
        )
      False -> current
    }
  })
}

fn observed_cache_row(
  observed: Model,
  strand: String,
  operation: Option(String),
  settled: message.Usage,
  at: Int,
) -> Model {
  case dict.get(observed.cache_fence, strand), operation {
    Ok(None), Some(op) ->
      Model(
        ..observed,
        cache_fence: dict.insert(observed.cache_fence, strand, Some(op)),
      )
    Ok(None), None -> observed
    Ok(Some(old)), Some(op) if old == op -> observed
    Ok(Some(_)), Some(_) ->
      watch_cache_at(
        Model(
          ..observed,
          cache_fence: dict.delete(observed.cache_fence, strand),
        ),
        strand,
        settled,
        at,
      )
    Ok(Some(_)), None -> observed
    Error(Nil), _ -> watch_cache_at(observed, strand, settled, at)
  }
}

// The output rate and generation clock are per-row readings in both legacy
// replay and live observations. Their common settlement does not touch the
// cumulative usage figure, whose owner depends on the delivery path.
fn settle_usage(
  model: Model,
  strand: String,
  settled: message.Usage,
  notice: String,
) -> Model {
  // The settlement's own output count over the time since the request went
  // out. A settlement whose clock never started (a refusal, an empty turn)
  // leaves the last rate standing. `generation_clock` starts the clock only
  // for the active strand's own row, so only that strand's settlement may
  // read it or clear it — a sub-agent's row arriving mid-generation must
  // not report its own output over the primary's window, and must not stop
  // the primary's clock out from under it.
  let #(output_rate_tps, generation_started_ms) = case
    strand == model.active_strand,
    model.peer,
    model.generation_started_ms
  {
    False, _, _ -> #(model.output_rate_tps, model.generation_started_ms)

    // The window is this client's own clock from the request going out to
    // the settlement, and a replay spends that window playing a file rather
    // than waiting on a provider. `output_rate_min_ms` already discards the
    // short ones, so a brief replay would report nothing anyway; a long one
    // would report how fast the replay ran. Declining outright is the same
    // rule that stops a replay echoing a prompt.
    True, Replaying, _ | True, Disconnected, _ -> #(model.output_rate_tps, None)

    True, Attached(..), Some(started) | True, Preview, Some(started) -> #(
      transcript_lines.output_rate(
        settled.output,
        model.monotonic_time_ms() - started,
      ),
      None,
    )
    True, Attached(..), None | True, Preview, None -> #(
      model.output_rate_tps,
      None,
    )
  }
  Model(..model, generation_started_ms:, output_rate_tps:, notice:)
}

// Folds one row into its strand's cache watch and raises any notice it
// reveals.
//
// The clock is the terminal's own, the same one the frame pacing and the
// throughput reading use, because the gap being measured is wall time the
// operator spent away and no server field reports it. A replay plays its
// file far faster than the session originally ran, so the gaps it would
// measure are not the gaps that happened; it observes nothing.
fn watch_cache(model: Model, strand: String, settled: message.Usage) -> Model {
  watch_cache_at(model, strand, settled, model.monotonic_time_ms())
}

fn watch_cache_at(
  model: Model,
  strand: String,
  settled: message.Usage,
  at: Int,
) -> Model {
  use <- bool.lazy_guard(when: replaying(model), return: fn() { model })

  let held = dict.get(model.cache_watch, strand) |> option.from_result
  let #(miss, watch) = cache_miss.observe(held, settled, at)
  let watched =
    Model(..model, cache_watch: case watch {
      None -> model.cache_watch
      Some(value) -> dict.insert(model.cache_watch, strand, value)
    })
  case miss {
    None -> watched
    Some(value) -> note_cache_miss(watched, strand, value)
  }
}

// A watch describes one provider's prefix. A model change cannot inherit its
// horizon or compare the new provider's first row with the old provider's
// last row. Clear only the affected strand, leaving its historical notices
// and other strands' watches in place.
fn forget_cache(model: Model, strand: String) -> Model {
  Model(
    ..model,
    cache_watch: dict.delete(model.cache_watch, strand),
    cache_fence: dict.insert(model.cache_fence, strand, None),
    cache_outlook: case strand == model.active_strand {
      True -> ""
      False -> model.cache_outlook
    },
  )
}

fn select_model(model: Model, name: String) -> Model {
  let model = case name == model.current_model {
    True -> model
    False -> forget_cache(model, model.active_strand)
  }
  Model(..model, current_model: name)
}

// A captured configuration can change on another terminal. Compare the
// effective model per strand instead of the whole configuration: changing a
// directory or another setting does not erase a valid cache observation. An
// initially live strand is fenced too, since its operation may have started
// under a model selected before this terminal attached.
fn cache_watches_for_cut(
  model: Model,
  view: snapshot_view.View,
) -> #(Dict(String, cache_miss.Watch), Dict(String, Option(String))) {
  case model.captured {
    Some(#(_, previous)) if previous.configurations != view.configurations -> {
      let watches =
        dict.filter(model.cache_watch, fn(strand, _) {
          configured_model(previous, strand) == configured_model(view, strand)
        })
      let fences =
        dict.fold(view.configurations, model.cache_fence, fn(fences, strand, _) {
          case
            dict.has_key(previous.configurations, strand)
            && configured_model(previous, strand)
            != configured_model(view, strand)
          {
            True -> dict.insert(fences, strand, None)
            False -> fences
          }
        })
      let fences =
        dict.fold(view.operations, fences, fn(fences, strand, _) {
          case dict.has_key(previous.configurations, strand) {
            True -> fences
            False -> dict.insert(fences, strand, None)
          }
        })
      #(watches, fences)
    }
    Some(_) -> #(model.cache_watch, model.cache_fence)
    None -> #(
      model.cache_watch,
      dict.fold(view.operations, model.cache_fence, fn(fences, strand, _) {
        dict.insert(fences, strand, None)
      }),
    )
  }
}

fn configured_model(
  view: snapshot_view.View,
  strand: String,
) -> Option(machine_strand.ModelIdentity) {
  view.configurations
  |> dict.get(strand)
  |> option.from_result
  |> option.map(fn(config) { config.configuration.model })
}

// A replay has no idle time of its own to report.
fn replaying(model: Model) -> Bool {
  case model.peer {
    Replaying -> True
    Attached(..) | Preview | Disconnected -> False
  }
}

// Files one cache-miss row against the strand's transcript.
//
// The row is anchored to the records the strand already holds rather than
// appended to the local notice block, so it stays under the turn it
// explains as later entries arrive. A new row changes the projection, so
// the record cache is dropped whether or not the strand is the visible one:
// switching to it later must find the row in place.
fn note_cache_miss(
  model: Model,
  strand: String,
  miss: cache_miss.CacheMiss,
) -> Model {
  // A strand holding no record has nowhere to put the row: a window that
  // retained nothing, or a strand whose history this connection never
  // fetched. A notice anchored to no entry would never be drawn, so it is
  // not raised at all.
  case newest_record(model, strand) {
    None -> model
    Some(after_entry) ->
      Model(
        ..model,
        cache_notices: list.append(model.cache_notices, [
          CacheNotice(strand:, after_entry:, text: cache_miss_row(miss)),
        ]),
        record_cache_valid: False,
      )
      |> tui_model.invalidate_transcript
      |> tui_model.invalidate_frame
  }
}

// The newest retained entry of one strand. Records are held newest first,
// so the head of the filtered list is the turn a row raised now follows.
fn newest_record(model: Model, strand: String) -> Option(ids.EntryId) {
  model.records
  |> list.find(fn(record) { record.strand == strand })
  |> result.map(fn(record) { record.entry.id })
  |> option.from_result
}

// The notice as the operator reads it.
//
// Token counts use the status line's own abbreviation so the two figures
// can be compared without unit arithmetic, and the money is omitted rather
// than shown as zero when the model is unpriced: a confident "$0.00" would
// claim the pause was free.
fn cache_miss_row(miss: cache_miss.CacheMiss) -> String {
  "Cache miss after "
  <> cache_miss.idle_label(miss.idle_ms)
  <> " idle: "
  <> transcript_lines.tokens(miss.tokens)
  <> " tokens re-billed"
  <> case miss.estimate {
    None -> ""
    Some(amount) -> " (~$" <> transcript_lines.money(amount) <> ")"
  }
}

fn add_usage(left: message.Usage, right: message.Usage) -> message.Usage {
  let message.UsageCost(
    input: left_cost_input,
    output: left_cost_output,
    cache_read: left_cost_cache_read,
    cache_write: left_cost_cache_write,
    total: left_cost_total,
  ) = left.cost
  let message.UsageCost(
    input: right_cost_input,
    output: right_cost_output,
    cache_read: right_cost_cache_read,
    cache_write: right_cost_cache_write,
    total: right_cost_total,
  ) = right.cost
  message.Usage(
    input: left.input + right.input,
    output: left.output + right.output,
    cache_read: left.cache_read + right.cache_read,
    cache_write: left.cache_write + right.cache_write,
    cache_write_1h: add_optional_int(left.cache_write_1h, right.cache_write_1h),
    reasoning: add_optional_int(left.reasoning, right.reasoning),
    total_tokens: left.total_tokens + right.total_tokens,
    cost: message.UsageCost(
      input: left_cost_input +. right_cost_input,
      output: left_cost_output +. right_cost_output,
      cache_read: left_cost_cache_read +. right_cost_cache_read,
      cache_write: left_cost_cache_write +. right_cost_cache_write,
      total: left_cost_total +. right_cost_total,
    ),
  )
}

fn add_optional_int(left: Option(Int), right: Option(Int)) -> Option(Int) {
  case left, right {
    None, None -> None
    Some(value), None | None, Some(value) -> Some(value)
    Some(left), Some(right) -> Some(left + right)
  }
}

/// Formats the server-reported session usage for the terminal footer.
/// The generation clock after an event that may start it: started now
/// if the event is the active strand's and no clock is running, otherwise
/// left as it was. Two events may start it — the `assistant` phase, and
/// the first fragment as a fallback — and whichever comes first wins.
fn generation_clock(model: Model, strand: String) -> Option(Int) {
  case model.generation_started_ms, strand == model.active_strand {
    None, True -> Some(model.monotonic_time_ms())
    started, _ -> started
  }
}

fn update_key(key: keys.Key, model: Model) -> Model {
  case model.context.surface {
    context_view.Overview | context_view.All -> update_context_key(key, model)
    context_view.Hidden -> update_key_without_context(key, model)
  }
}

fn update_key_without_context(key: keys.Key, model: Model) -> Model {
  case model.queue_editor.surface {
    queue_editor.Inspector | queue_editor.Editor -> update_queue_key(key, model)
    queue_editor.Closed ->
      case model.summary_surface {
        queue_editor.Closed -> update_normal_key(key, model)
        queue_editor.Inspector | queue_editor.Editor ->
          update_summary_key(key, model)
      }
  }
}

fn update_normal_key(key: keys.Key, model: Model) -> Model {
  case key == keys.Ctrl("c") {
    True -> quit(model)
    False ->
      case model.overlay {
        ModelSelector(selector) -> update_model_selector(key, model, selector)
        AgentInspector(selected) -> update_agent_inspector(key, model, selected)
        GoalInspector(state) -> update_goal_inspector(key, model, state)
        SessionSelector(selector) ->
          update_session_selector(key, model, selector)
        DaemonSelector(selector) -> update_daemon_selector(key, model, selector)
        ApprovalInspector(panel) ->
          case approval_panel.update(key, panel) {
            approval_panel.Close -> Model(..model, overlay: NoOverlay)
            approval_panel.Continue(next) ->
              Model(..model, overlay: ApprovalInspector(next))
            approval_panel.Decide(record, choice) ->
              decide_captured_approval(model, record, choice)
          }
        NoOverlay -> update_main_key(key, model)
      }
  }
}

fn update_session_selector(
  key: keys.Key,
  model: Model,
  selector: sessions.State,
) -> Model {
  case sessions.update(key, selector) {
    sessions.Continue(next) -> Model(..model, overlay: SessionSelector(next))
    sessions.Close ->
      Model(
        ..model,
        overlay: NoOverlay,
        repaint_phase: !model.repaint_phase,
        notice: "session selection cancelled",
      )
    sessions.Choose(choice) -> begin_session_switch(model, choice)
  }
}

fn update_goal_inspector(
  key: keys.Key,
  model: Model,
  state: focused_goal_panel.State,
) -> Model {
  case
    focused_goal_panel.update(
      key,
      state,
      layout.model_goal_inspector_area(model),
      render.goal_availability(model),
    )
  {
    focused_goal_panel.Close ->
      Model(
        ..model,
        overlay: NoOverlay,
        repaint_phase: !model.repaint_phase,
        notice: "goal inspector closed",
      )
    focused_goal_panel.Continue(next) ->
      Model(..model, overlay: GoalInspector(next))
    focused_goal_panel.Refresh -> surfaces.request_goal_status(model)
    focused_goal_panel.Pause ->
      surfaces.submit_goal_action(model, command.GoalPause)
    focused_goal_panel.Resume ->
      surfaces.submit_goal_action(model, command.GoalResume)
  }
}

fn update_daemon_selector(
  key: keys.Key,
  model: Model,
  selector: session_selector.State,
) -> Model {
  case session_selector.update(key, selector) {
    session_selector.Continue(next) ->
      Model(..model, overlay: DaemonSelector(next))
    session_selector.Close ->
      Model(..model, overlay: NoOverlay, notice: "session selection cancelled")
    session_selector.Choose(row) -> begin_open(model, row.session_id)
    session_selector.NewSession -> create_session(model)
    session_selector.Delete(session_id) -> begin_delete(model, session_id)
    session_selector.Archive(session_id) ->
      begin_removal(model, session_id, Archive)
    session_selector.Restore(session_id) ->
      begin_removal(model, session_id, Restore)
    session_selector.ShowCollection(collection) ->
      load_catalogue_collection(model, "", None, collection)
    session_selector.Rename(session_id, name) ->
      begin_rename(model, session_id, name)
    session_selector.NextPage(after, revision) ->
      load_catalogue_collection(
        model,
        after,
        Some(revision),
        selector.collection,
      )
    session_selector.FirstPage ->
      load_catalogue_collection(model, "", None, selector.collection)
  }
}

fn update_model_selector(
  key: keys.Key,
  model: Model,
  selector: model_selector.State,
) -> Model {
  case model_selector.update(key, selector) {
    model_selector.Continue(next) ->
      Model(..model, overlay: ModelSelector(next))
    model_selector.Close ->
      Model(
        ..model,
        overlay: NoOverlay,
        repaint_phase: !model.repaint_phase,
        notice: "model selection cancelled",
      )
    model_selector.Choose(name) -> {
      let switched = select_model(model, name)
      let selected =
        Model(
          ..switched,
          overlay: NoOverlay,
          repaint_phase: !model.repaint_phase,
          notice: "model: " <> name,
        )
        |> outbound.send_frame(protocol.set_model(
          model.next_id,
          model.active_strand,
          name,
        ))
      tui_model.append_system(selected, "active model changed to " <> name)
    }
  }
}

fn open_agents(model: Model) -> Model {
  Model(
    ..model,
    overlay: AgentInspector(agents.inspect(model.active_strand)),
    repaint_phase: !model.repaint_phase,
    notice: "agent workspace",
  )
}

fn update_agent_inspector(
  key: keys.Key,
  model: Model,
  inspector: agents.Inspector,
) -> Model {
  use <- bool.lazy_guard(inspector.focus == agents.Composing, fn() {
    update_workspace_composer(key, model, inspector)
  })
  let rows = render.displayed_agents(model)
  let changed = case key {
    keys.Tab ->
      Model(
        ..model,
        help_open: False,
        notes_open: False,
        worktree: worktree_view.State(
          ..model.worktree,
          focus: worktree_view.Composer,
        ),
        overlay: AgentInspector(
          agents.Inspector(..inspector, focus: agents.Composing),
        ),
      )
    keys.Escape | keys.F(2) ->
      Model(
        ..model,
        overlay: NoOverlay,
        repaint_phase: !model.repaint_phase,
        notice: "agents closed",
      )
    keys.Up ->
      Model(
        ..model,
        overlay: AgentInspector(
          agents.navigate(inspector, rows, agents.Previous)
          |> select_inspector_message(model.agent_messages),
        ),
      )
    keys.Down ->
      Model(
        ..model,
        overlay: AgentInspector(
          agents.navigate(inspector, rows, agents.Next)
          |> select_inspector_message(model.agent_messages),
        ),
      )
    keys.Char("1") -> select_agent_detail(model, inspector, agents.Overview)
    keys.Char("2") -> select_agent_detail(model, inspector, agents.Messages)
    keys.Char("3") -> select_agent_detail(model, inspector, agents.Notes)
    keys.Char("4") ->
      select_agent_detail(model, inspector, agents.Collaboration)
    keys.Char("[") if inspector.detail == agents.Messages ->
      select_agent_message(model, inspector, -1)
    keys.Char("]") if inspector.detail == agents.Messages ->
      select_agent_message(model, inspector, 1)
    keys.Char("[") if inspector.detail == agents.Notes ->
      surfaces.select_note(model, -1)
    keys.Char("]") if inspector.detail == agents.Notes ->
      surfaces.select_note(model, 1)
    keys.Char("r") if inspector.detail == agents.Notes ->
      surfaces.refresh_notes(model)
    keys.Ctrl("g") if inspector.detail == agents.Notes -> toggle_note_mode(model)
    keys.Ctrl("g") -> toggle_details(model)
    keys.Char("n") ->
      Model(
        ..model,
        overlay: AgentInspector(
          agents.next_attention(inspector, rows)
          |> select_inspector_message(model.agent_messages),
        ),
      )
    keys.PageUp if inspector.detail == agents.Messages -> {
      let maximum = message_max_scroll(model, inspector)
      Model(
        ..model,
        overlay: AgentInspector(
          agents.Inspector(
            ..inspector,
            scroll: int.max(
              0,
              int.min(inspector.scroll, maximum) - message_page_step(model),
            ),
          ),
        ),
      )
    }
    keys.PageDown if inspector.detail == agents.Messages -> {
      let maximum = message_max_scroll(model, inspector)
      Model(
        ..model,
        overlay: AgentInspector(
          agents.Inspector(
            ..inspector,
            scroll: int.min(
              maximum,
              int.min(inspector.scroll, maximum) + message_page_step(model),
            ),
          ),
        ),
      )
    }
    keys.PageUp if inspector.detail == agents.Notes -> {
      let maximum = note_max_scroll(model)
      Model(
        ..model,
        note_scroll: int.max(
          0,
          int.min(model.note_scroll, maximum) - note_page_step(model),
        ),
      )
    }
    keys.PageDown if inspector.detail == agents.Notes ->
      Model(
        ..model,
        note_scroll: int.min(
          note_max_scroll(model),
          int.min(model.note_scroll, note_max_scroll(model))
            + note_page_step(model),
        ),
      )
    keys.PageUp ->
      Model(
        ..model,
        overlay: AgentInspector(
          agents.Inspector(
            ..inspector,
            scroll: int.max(0, inspector.scroll - 5),
          ),
        ),
      )
    keys.PageDown ->
      Model(
        ..model,
        overlay: AgentInspector(
          agents.Inspector(..inspector, scroll: inspector.scroll + 5),
        ),
      )
    keys.Char("a") -> inspect_agent_approval(model, inspector.selected)
    keys.Char("o") if inspector.detail == agents.Messages ->
      open_agent_message_sender(model, inspector)
    keys.Enter ->
      case tui_model.is_known_strand(model.strands, inspector.selected) {
        True -> switch_active_strand(model, inspector.selected)
        False ->
          Model(
            ..model,
            notice: "Selected agent is unavailable; recipient unchanged",
          )
      }
    _ -> model
  }
  case changed.overlay {
    AgentInspector(next)
      if next.detail == agents.Notes && next.selected != inspector.selected
    ->
      surfaces.refresh_notes(
        Model(
          ..changed,
          note_selected: None,
          note_scroll: 0,
          note_mode: note_panel.Readable,
        ),
      )
    _ -> changed
  }
}

fn select_inspector_message(
  inspector: agents.Inspector,
  messages: List(agent_messages.Item),
) -> agents.Inspector {
  case inspector.detail {
    agents.Overview | agents.Notes | agents.Collaboration -> inspector
    agents.Messages -> {
      let selected =
        messages
        |> agent_messages.for_strand(inspector.selected)
        |> agent_message_panel.selected(inspector.message)
        |> option.map(agent_message_panel.identity)
      let scroll = case selected == inspector.message {
        True -> inspector.scroll
        False -> 0
      }
      agents.Inspector(..inspector, message: selected, scroll:)
    }
  }
}

/// Reconciles a message browser after a new captured projection arrives.
///
/// ## Examples
///
/// ```gleam
/// // tui.reconcile_agent_message_selection(model)
/// ```
@internal
pub fn reconcile_agent_message_selection(model: Model) -> Model {
  case model.overlay {
    AgentInspector(inspector) if inspector.detail == agents.Messages ->
      Model(
        ..model,
        overlay: AgentInspector(select_inspector_message(
          inspector,
          model.agent_messages,
        )),
      )
    _ -> model
  }
}

fn message_page_step(model: Model) -> Int {
  agent_message_panel.page_step(layout.message_detail_area(model))
}

fn message_max_scroll(model: Model, inspector: agents.Inspector) -> Int {
  let area = layout.message_detail_area(model)
  model.agent_messages
  |> agent_messages.for_strand(inspector.selected)
  |> agent_message_panel.max_scroll(inspector.message, area)
}

fn note_page_step(model: Model) -> Int {
  case model.overlay {
    AgentInspector(_) -> note_panel.page_step(layout.message_detail_area(model))
    _ -> note_panel.page_step(layout.note_detail_area(model))
  }
}

fn note_max_scroll(model: Model) -> Int {
  let area = case model.overlay {
    AgentInspector(_) -> layout.message_detail_area(model)
    _ -> layout.note_detail_area(model)
  }
  render.prepared_notes(model, surfaces.notes_target(model), area)
  |> note_panel.max_scroll(model.note_selected)
}

fn toggle_note_mode(model: Model) -> Model {
  let mode = case model.note_mode {
    note_panel.Readable -> note_panel.Raw
    note_panel.Raw -> note_panel.Readable
  }
  Model(..model, note_mode: mode, note_scroll: 0)
  |> tui_model.invalidate_transcript
}

fn select_agent_detail(
  model: Model,
  inspector: agents.Inspector,
  detail: agents.Detail,
) -> Model {
  let message = case detail {
    agents.Messages ->
      agent_messages.for_strand(model.agent_messages, inspector.selected)
      |> agent_message_panel.selected(inspector.message)
      |> option.map(agent_message_panel.identity)
    agents.Overview | agents.Notes | agents.Collaboration -> inspector.message
  }
  let owner_changed = case model.note_board {
    Some(board) -> board.strand != inspector.selected
    None -> True
  }
  let selected =
    Model(
      ..model,
      note_selected: case detail, owner_changed {
        agents.Notes, True -> None
        _, _ -> model.note_selected
      },
      note_scroll: case detail, owner_changed {
        agents.Notes, True -> 0
        _, _ -> model.note_scroll
      },
      overlay: AgentInspector(
        agents.Inspector(..inspector, detail:, scroll: 0, message:),
      ),
    )
  case detail {
    agents.Notes -> surfaces.refresh_notes(selected)
    agents.Overview | agents.Messages -> selected
  }
}

fn select_agent_message(
  model: Model,
  inspector: agents.Inspector,
  amount: Int,
) -> Model {
  let messages =
    agent_messages.for_strand(model.agent_messages, inspector.selected)
  Model(
    ..model,
    overlay: AgentInspector(
      agents.Inspector(
        ..inspector,
        message: agent_message_panel.move(messages, inspector.message, amount),
        scroll: 0,
      ),
    ),
  )
}

// Opening a sender is an explicit workspace switch. Merely inspecting a send
// never moves the composer recipient or the transcript reading position.
fn open_agent_message_sender(
  model: Model,
  inspector: agents.Inspector,
) -> Model {
  let messages =
    agent_messages.for_strand(model.agent_messages, inspector.selected)
  case agent_message_panel.selected(messages, inspector.message) {
    None -> Model(..model, notice: "No observed message is selected")
    Some(item) ->
      case tui_model.is_known_strand(model.strands, item.source) {
        True -> switch_active_strand(model, item.source)
        False ->
          Model(
            ..model,
            notice: "Message sender is unavailable; recipient unchanged",
          )
      }
  }
}

// The editor uses the ordinary submission path and its existing owner. A
// command may open another surface; only an ordinary edit returns to inspection.
fn update_workspace_composer(
  key: keys.Key,
  model: Model,
  inspector: agents.Inspector,
) -> Model {
  case key {
    keys.Escape | keys.F(2) ->
      Model(
        ..model,
        overlay: AgentInspector(
          agents.Inspector(..inspector, focus: agents.Browsing),
        ),
      )
    _ -> {
      let next = update_main_key(key, Model(..model, overlay: NoOverlay))

      // Commands transfer keyboard ownership to their visible destination.
      // Retaining inspection would conceal help or a diff navigator while
      // that surface was already consuming the next key.
      let editing =
        !next.help_open
        && !next.notes_open
        && next.worktree.focus == worktree_view.Composer
        && next.diff_view == model.diff_view
        && next.context.surface == context_view.Hidden
        && next.queue_editor.surface == queue_editor.Closed
        && next.summary_surface == queue_editor.Closed
      case next.overlay, editing {
        NoOverlay, True -> Model(..next, overlay: AgentInspector(inspector))
        _, _ -> next
      }
    }
  }
}

// Owner context is read from the same exact escalation revision. A newer
// metadata cut cannot silently rename the request whose grants are displayed.
fn captured_approval_panel(model: Model, review: approval.Review) {
  let context = {
    use captured <- result.try(option.to_result(model.captured, Nil))
    use cell <- result.try(
      list.find(captured.1.cells, fn(cell) {
        cell.namespace == register.FactCustom
        && cell.key == "escalation/" <> review.id
        && cell.seq == review.seq
      }),
    )
    use fields <- result.try(case cell.value {
      json.Object(fields) -> Ok(fields)
      _ -> Error(Nil)
    })
    use scope <- result.try(list.key_find(fields, "scope"))
    use fields <- result.try(case scope {
      json.Object(fields) -> Ok(fields)
      _ -> Error(Nil)
    })
    use owner <- result.try(case list.key_find(fields, "strand") {
      Ok(json.String(owner)) -> Ok(owner)
      _ -> Error(Nil)
    })
    use operation <- result.try(case list.key_find(fields, "operation") {
      Ok(json.String(operation)) -> Ok(operation)
      _ -> Error(Nil)
    })
    Ok(#(owner, operation))
  }
  approval_panel.new(review)
  |> approval_panel.with_context(case context {
    Ok(#(owner, operation)) -> approval_panel.CapturedRequest(owner, operation)
    Error(_) ->
      approval_panel.RequestContextUnavailable(
        "Request owner unavailable in this capture",
      )
  })
}

// Inspection opens the existing exact-request panel. It never chooses or sends
// a decision, and a disappeared request cannot be replaced by a different one.
fn inspect_agent_approval(model: Model, strand: String) -> Model {
  let found =
    render.displayed_agents(model)
    |> list.find(fn(row) { row.id == strand })
    |> result.try(fn(row) { list.first(row.approvals) })
    |> result.try(fn(id) {
      list.find(model.approvals, fn(review) {
        review.id == id && review.status == approval.Pending
      })
    })
  case found {
    Ok(review) ->
      Model(
        ..model,
        overlay: ApprovalInspector(captured_approval_panel(model, review)),
      )
    Error(Nil) -> Model(..model, notice: "No current approval for this agent")
  }
}

fn update_main_key(key: keys.Key, model: Model) -> Model {
  case layout.diff_shown(model), model.worktree.focus, key {
    _, _, keys.Alt("q") -> open_queue(model)
    _, _, keys.F(2) -> open_agents(model)
    True, _, keys.Ctrl("d") ->
      Model(
        ..model,
        worktree: worktree_view.State(
          ..model.worktree,
          focus: case model.worktree.focus {
            worktree_view.Composer -> worktree_view.Navigator
            worktree_view.Navigator -> worktree_view.Composer
          },
        ),
      )
    True, worktree_view.Navigator, _ -> update_diff_key(key, model)
    _, _, _ -> update_palette_key(key, model)
  }
}

fn update_palette_key(key: keys.Key, model: Model) -> Model {
  let suggestions =
    command.suggestions_with_skills(text_area.value(model.input), model.skills)
  case suggestions, command_palette_escape(key), key {
    [_, ..], True, _ ->
      Model(
        ..model,
        input: text_area.state_new(),
        command_selected: 0,
        notice: "commands closed",
      )
    [_, ..], False, keys.Up ->
      Model(
        ..model,
        command_selected: command.move_selection(
          model.command_selected,
          list.length(suggestions),
          False,
        ),
      )
    [_, ..], False, keys.Down ->
      Model(
        ..model,
        command_selected: command.move_selection(
          model.command_selected,
          list.length(suggestions),
          True,
        ),
      )
    [_, ..], False, keys.Tab ->
      case command.selected(suggestions, model.command_selected) {
        Some(value) ->
          Model(
            ..model,
            input: text_area.state_from_string(value),
            command_selected: 0,
          )
        None -> model
      }

    // Enter takes the highlighted row. A row that still wants an argument
    // is completed into the editor, as Tab would; a complete one is
    // submitted at once, so `/effort` plus a highlighted level is one
    // keystroke, not Tab then Enter.
    [_, ..], False, keys.Enter ->
      case command.selected(suggestions, model.command_selected) {
        Some(value) -> {
          let completed =
            Model(
              ..model,
              input: text_area.state_from_string(value),
              command_selected: 0,
            )
          case string.ends_with(value, " ") {
            True -> completed
            False -> submit(completed)
          }
        }
        None -> submit(model)
      }
    _, _, _ -> update_main_key_without_palette(key, model)
  }
}

/// Reports whether Escape belongs to an open slash-command palette.
@internal
pub fn command_palette_escape(key: keys.Key) -> Bool {
  key == keys.Escape
}

fn update_main_key_without_palette(key: keys.Key, model: Model) -> Model {
  case key, model.diff_view {
    keys.Escape, DiffVisible ->
      Model(
        ..model,
        diff_view: DiffHidden,
        repaint_phase: !model.repaint_phase,
        notice: "changes closed",
      )
    _, _ -> update_conversation_key(key, model)
  }
}

fn update_conversation_key(key: keys.Key, model: Model) -> Model {
  case key, model.help_open, model.notes_open {
    keys.Char("r"), False, True -> surfaces.refresh_notes(model)
    keys.Char("["), False, True -> surfaces.select_note(model, -1)
    keys.Char("]"), False, True -> surfaces.select_note(model, 1)
    keys.Ctrl("g"), False, True -> toggle_note_mode(model)
    keys.Ctrl("g"), _, _ -> toggle_details(model)
    keys.PageUp, False, True -> {
      let maximum = note_max_scroll(model)
      Model(
        ..model,
        note_scroll: int.max(
          0,
          int.min(model.note_scroll, maximum) - note_page_step(model),
        ),
      )
    }
    keys.PageDown, False, True ->
      Model(
        ..model,
        note_scroll: int.min(
          note_max_scroll(model),
          int.min(model.note_scroll, note_max_scroll(model))
            + note_page_step(model),
        ),
      )
    keys.PageUp, _, _ -> scroll_reading_panel(model, Older, 10)
    keys.PageDown, _, _ -> scroll_reading_panel(model, Newer, 10)
    keys.Escape, True, _ ->
      Model(
        ..model,
        help_open: False,
        scroll_offset: 0,
        repaint_phase: !model.repaint_phase,
        notice: "help closed",
      )
    keys.Escape, False, True ->
      Model(
        ..model,
        notes_open: False,
        note_board: None,
        note_selected: None,
        note_mode: note_panel.Readable,
        note_scroll: 0,
        notes_requested: None,
        scroll_offset: 0,
        repaint_phase: !model.repaint_phase,
        notice: "agent notes closed",
      )
    keys.Escape, False, False -> interrupt_active(model)
    keys.Tab, False, False -> toggle_submission_mode(model)
    keys.BackTab, False, False -> toggle_agent_rail(model)
    keys.Up, False, False -> navigate_history(model, True)
    keys.Down, False, False -> navigate_history(model, False)
    keys.Enter, False, False -> submit(model)
    keys.Backspace, False, False ->
      case text_area.value(model.input), model.attachments {
        "", [_, ..] -> {
          let attachments = composer.drop_last(model.attachments)
          Model(
            ..model,
            attachments:,
            notice: composer.summary(attachments)
              |> option.unwrap("paste removed"),
          )
        }
        _, _ -> {
          let input = text_area.backspace(model.input)
          Model(
            ..model,
            input:,
            history_index: 0,
            history_draft: text_area.value(input),
            command_selected: 0,
          )
        }
      }
    keys.Left, False, False ->
      Model(..model, input: text_area.move_cursor_left(model.input))
    keys.Right, False, False ->
      Model(..model, input: text_area.move_cursor_right(model.input))
    keys.Home, False, False ->
      Model(..model, input: text_area.move_to_line_start(model.input))
    keys.End, False, False ->
      case
        text_area.value(model.input) == "" && tui_model.reading_history(model)
      {
        True -> scroll_transcript(model, False, model.rendered_row_count)
        False -> Model(..model, input: text_area.move_to_line_end(model.input))
      }
    keys.Alt(character), False, False -> interrupt_and_insert(model, character)
    keys.Char(character), False, False -> {
      let editor = text_area.textarea_new() |> text_area.with_max_lines(1)
      Model(
        ..model,
        input: text_area.insert_char(editor, model.input, character),
        history_index: 0,
        history_draft: text_area.value(model.input) <> character,
        command_selected: 0,
      )
    }
    _, _, _ -> model
  }
}

// Transcript movement has one definition for keyboard and wheel input. The
// offset is measured backward from the newest wrapped row, so moving toward
// the present clamps at zero and resumes tail following.
// A key while a selection is on screen: Escape only dismisses it, the way it
// closes any other surface before it reaches the interrupt. Detail expansion
// retains the chosen cells; editing and navigation dismiss the selection.
fn update_key_over_selection(key: keys.Key, model: Model) -> Model {
  case model.selection, key {
    Some(_), keys.Escape ->
      Model(..clear_selection(model), notice: "selection cleared")
    Some(_), keys.Ctrl("g") -> update_key(key, model)
    Some(_), _ | None, _ -> update_key(key, clear_selection(model))
  }
}

// Escape owns cancellation before a queued final reply can send the intent.
// Other input first observes bounded ready traffic, then the current lock.
fn update_ready_key(key: keys.Key, model: Model) -> Model {
  case model.pending_submission, key {
    Some(_), keys.Escape -> cancel_pending(model, "cancelled by Escape")
    Some(_), keys.Ctrl("c") -> quit(cancel_pending(model, "terminal closed"))
    _, _ -> {
      let model = drain_connection(model, 64)
      case model.pending_submission, key {
        None, _ -> update_key_over_selection(key, model)
        Some(_), keys.PageUp -> scroll_transcript(model, True, 10)
        Some(_), keys.PageDown -> scroll_transcript(model, False, 10)
        Some(_), _ -> outbound.waiting_notice(model)
      }
    }
  }
}

fn cancel_pending(model: Model, reason: String) -> Model {
  case model.channel {
    None -> Model(..model, pending_submission: None)
    Some(channel) -> {
      let #(channel, updates) = session_channel.cancel_unsent(channel, reason)
      list.fold(
        updates,
        Model(..model, channel: Some(channel)),
        apply_channel_update,
      )
    }
  }
}

fn clear_selection(model: Model) -> Model {
  Model(..model, selection: None, selection_frame: None, selection_gutters: [])
}

// A press starts over: whatever was highlighted is replaced by a fresh
// selection in the area the press landed in.
fn begin_selection(model: Model, at: geometry.Position) -> Model {
  let screen = geometry.rect_new(0, 0, model.width, model.height)
  let #(_, body, _, _) = layout.layout(screen, model)
  let #(conversation, queue) = layout.queue_body_layout(body, model)
  let #(transcript, _, _) = layout.body_layout(conversation, model)
  use <- bool.lazy_guard(
    tui_model.reading_history(model)
      && at.y == transcript.position.y
      && at.x < geometry.right(transcript),
    fn() {
      scroll_transcript(clear_selection(model), False, model.rendered_row_count)
    },
  )
  case queue_row_hit(model, queue, at) {
    Some(selected) ->
      Model(
        ..clear_selection(model),
        queue_editor: queue_editor.State(
          ..model.queue_editor,
          surface: queue_editor.Inspector,
          selected:,
          preview_scroll: 0,
        ),
        notice: "queued input selected",
      )
    None ->
      case layout.diff_navigation_hit(model, at) {
        Some(selected) ->
          Model(
            ..model,
            selection: None,
            selection_frame: None,
            selection_gutters: [],
            diff_scroll_offset: 0,
            worktree: worktree_view.State(
              ..model.worktree,
              selected:,
              focus: worktree_view.Navigator,
            ),
          )
          |> tui_model.invalidate_transcript
        None -> {
          let #(shown, selection_gutters) = selection_display(model)
          Model(
            ..model,
            selection: Some(selection.start(layout.hit_area(model, at), at)),
            selection_frame: Some(shown),
            selection_gutters:,
          )
        }
      }
  }
}

// A drag without a press this client saw, which a terminal that started
// reporting mid-gesture can produce, selects nothing.
fn extend_selection(model: Model, at: geometry.Position) -> Model {
  case model.selection {
    Some(selected) ->
      Model(..model, selection: Some(selection.extend(selected, at)))
    None -> model
  }
}

// The release is where the copy happens. A click, which selects nothing,
// dismisses a settled highlight; a drag copies the cells as the frame on
// display shows them and leaves the highlight up as confirmation until the
// next key or wheel notch.
fn finish_selection(model: Model, at: geometry.Position) -> Model {
  case model.selection {
    None -> model
    Some(selected) -> {
      let selected = selection.extend(selected, at)
      case selection.is_click(selected) {
        True ->
          Model(
            ..model,
            selection: None,
            selection_frame: None,
            selection_gutters: [],
          )
        False -> {
          let shown =
            option.lazy_unwrap(model.selection_frame, fn() {
              selection_display(model).0
            })
          let text = case selection_covers_transcript(model, selected) {
            True ->
              transcript_selection_text(
                shown,
                selected,
                model.selection_gutters,
              )
            False -> selection.text(shown, selected)
          }
          write_clipboard(model.clipboard, text)
          Model(
            ..model,
            selection: Some(selected),
            notice: selection.copied_notice(
              list.length(selection.rows(selected)),
            ),
          )
        }
      }
    }
  }
}

// Only the transcript has speaker gutters. Other selectable panels carry
// ordinary whitespace whose meaning this projection cannot reinterpret.
fn selection_covers_transcript(
  model: Model,
  selected: selection.Selection,
) -> Bool {
  let screen = geometry.rect_new(0, 0, model.width, model.height)
  let #(_, body_area, _, _) = layout.layout(screen, model)
  let #(conversation, _) = layout.queue_body_layout(body_area, model)
  let #(transcript_panel, _, _) = layout.body_layout(conversation, model)
  selected.area == layout.panel_inner(transcript_panel)
  && !layout.main_shows_diff(model)
}

/// Reads selected transcript cells without copying their visual left gutter.
///
/// Fixed gutter widths are captured from the private transcript layout which
/// painted the frame. Indentation after that prefix is authored text and
/// remains byte-for-byte intact. Rows remain separate because the frame does
/// not encode whether Markdown ended a block or wrapped one; guessing from row
/// width would join real newlines or split real paragraphs.
///
/// ## Examples
///
/// ```gleam
/// // tui.transcript_selection_text(frame, selected, gutters)
/// ```
@internal
pub fn transcript_selection_text(
  shown: buffer.Buffer,
  selected: selection.Selection,
  gutters: List(#(Int, Int)),
) -> String {
  selection.rows(selected)
  |> list.map(fn(row) {
    let prefix = list.key_find(gutters, row.position.y) |> result.unwrap(0)
    let gutter =
      int.clamp(
        selected.area.position.x + prefix - row.position.x,
        0,
        row.size.width,
      )
    frame.row_text(
      shown,
      row.position.x + gutter,
      row.position.y,
      row.size.width - gutter,
    )
  })
  |> string.join("\n")
}

// The transcript is bottom-addressed in `rendered_gutters`, while screen rows
// run top to bottom. This is the metadata twin of `render_rows`'s viewport
// slice and reverse; the completed frame caches this map beside its cells.
fn selection_gutters_on_display(model: Model) -> List(#(Int, Int)) {
  let screen = geometry.rect_new(0, 0, model.width, model.height)
  let #(_, body_area, _, _) = layout.layout(screen, model)
  let #(conversation, _) = layout.queue_body_layout(body_area, model)
  let #(transcript_panel, _, _) = layout.body_layout(conversation, model)
  let area = layout.panel_inner(transcript_panel)
  model.rendered_gutters
  |> list.drop(model.scroll_offset + tui_model.viewport_backlog(model))
  |> list.take(area.size.height)
  |> list.reverse
  |> list.index_map(fn(gutter, index) { #(area.position.y + index, gutter) })
}

// The frame and its copy layout come from one completed cache entry. A paced
// scroll may leave that entry deliberately stale; taking either half from the
// current model would pair old cells with new row metadata.
fn selection_display(model: Model) -> #(buffer.Buffer, List(#(Int, Int))) {
  let screen = geometry.rect_new(0, 0, model.width, model.height)
  case model.frame_cache {
    Some(FrameCache(rendered: #(shown, _), selection_gutters:, ..)) -> #(
      shown,
      selection_gutters,
    )
    None -> #(
      render.render_frame(model, screen).0,
      selection_gutters_on_display(model),
    )
  }
}

// Etui draws its frames with `io:put_chars`, so a sequence printed the same
// way lands on the same terminal in order with them.
fn write_clipboard(clipboard: Clipboard, text: String) -> Nil {
  case clipboard {
    TerminalClipboard -> io.print(selection.clipboard_sequence(text))
    NoClipboard -> Nil
  }
}

// The gesture starts from the row the reader is looking at, which is the
// stored offset plus whatever the paced walk is still holding back: the
// viewport is drawn from that sum, and measuring a scroll against the
// stored offset alone would answer a request for older text by jumping the
// backlog forward to the tail. Folding it in also leaves the paths that
// ask for the latest row landing at zero, since they scroll by the whole
// row count and the bound clamps there.
fn scroll_transcript(model: Model, older: Bool, rows: Int) -> Model {
  let offset =
    scroll_offset(
      model.scroll_offset + tui_model.viewport_backlog(model),
      older,
      rows,
    )
    |> bounded_scroll_offset(
      model.rendered_row_count,
      layout.transcript_viewport_height(model),
    )
  let model =
    Model(..model, scroll_offset: offset, notice: case offset == 0 && !older {
      True -> "following output"
      False -> "scrollback · End returns to latest (empty prompt)"
    })
  case model.help_open || model.notes_open, model.captured {
    True, _ | _, None -> model
    False, Some(#(cut, view)) -> {
      case offset == 0 && !older {
        True -> {
          let history = history_view.resume(model.scrollback)
          apply_cut(Model(..model, scrollback: history), cut, view)
        }
        False -> {
          let history = history_view.freeze(model.scrollback)
          let history = case
            older
            && offset + layout.transcript_viewport_height(model)
            >= model.rendered_row_count - history_prefetch_rows(model)
          {
            True ->
              history_view.older(
                history,
                history_view.branch(history, view).unloaded,
              )
            False -> history
          }
          service_history(Model(..model, scrollback: history))
        }
      }
    }
  }
}

// Start the existing bounded read two screens before the loaded boundary,
// leaving time for the reply while the reader continues scrolling.
fn history_prefetch_rows(model: Model) -> Int {
  int.max(10, 2 * layout.transcript_viewport_height(model))
}

// A page can contain only other strands, and collapsing details can leave
// fewer rows than one screen. Continue the bounded demand until older rows
// exist above this viewport. A busy lane keeps Wanted for the next event;
// the user does not need another wheel gesture to retry the same read.
//
// The guard repeats the two scalars `history_view.older` itself tests. This
// runs on every terminal event, including idle ticks, and the ancestry
// projection below walks the whole retained window to produce an argument a
// pending or exhausted request would discard.
fn request_history_for_view(model: Model) -> Model {
  use <- bool.guard(
    model.scrollback.mode != history_view.Reading
      || model.scrollback.request != history_view.Quiet
      || model.scrollback.before_seq <= 1
      || model.help_open
      || model.notes_open
      || model.scroll_offset + layout.transcript_viewport_height(model)
      < model.rendered_row_count - history_prefetch_rows(model),
    model,
  )
  case model.captured {
    None -> model
    Some(#(_, view)) ->
      Model(
        ..model,
        scrollback: history_view.older(
          model.scrollback,
          history_view.branch(model.scrollback, view).unloaded,
        ),
      )
  }
}

// History shares the existing correlated read lane. A busy lane leaves one
// demand pending without blocking input, spawning a worker, or opening a socket.
fn service_history(model: Model) -> Model {
  case history_view.range(model.scrollback), model.channel {
    Some(#(after, before)), Some(channel) -> {
      case session_channel.history(channel, after, before) {
        Error(_) -> model
        Ok(channel) ->
          Model(
            ..model,
            channel: Some(channel),
            scrollback: history_view.sent(model.scrollback, before),
          )
      }
    }
    _, _ -> model
  }
}

fn receive_history(
  model: Model,
  window: snapshot.Window,
  before: Int,
  after: Int,
) -> Model {
  case model.captured {
    None -> model
    Some(#(cut, view)) -> {
      let history =
        history_view.accept(model.scrollback, window, before, after, view)
      let model = apply_cut(Model(..model, scrollback: history), cut, view)
      Model(..model, render_revision: model.render_revision + 1)
    }
  }
}

// Page keys follow the reading surface's focus. The default side pane never
// takes scrollback keys from a person typing in the conversation composer.
fn scroll_reading_panel(
  model: Model,
  direction: ScrollDirection,
  rows: Int,
) -> Model {
  case
    layout.main_shows_diff(model)
    || model.worktree.focus == worktree_view.Navigator
  {
    True -> scroll_diff(model, direction, layout.diff_patch_height(model))
    False -> scroll_transcript(model, direction == Older, rows)
  }
}

fn scroll_at(
  model: Model,
  position: geometry.Position,
  direction: ScrollDirection,
) -> Model {
  use <- bool.lazy_guard(model.context.surface != context_view.Hidden, fn() {
    scroll_context(model, case direction {
      Older -> -3
      Newer -> 3
    })
  })
  case
    layout.main_shows_diff(model)
    || {
      layout.diff_shown(model)
      && geometry.contains(layout.active_diff_panel(model), position)
    }
  {
    True -> scroll_diff(model, direction, 3)
    False -> scroll_transcript(model, direction == Older, 3)
  }
}

fn scroll_diff(model: Model, direction: ScrollDirection, rows: Int) -> Model {
  let current =
    bounded_scroll_offset(
      model.diff_scroll_offset,
      model.diff_row_count,
      layout.diff_patch_height(model),
    )
  let offset =
    scroll_offset(current, direction == Older, rows)
    |> bounded_scroll_offset(
      model.diff_row_count,
      layout.diff_patch_height(model),
    )
  Model(
    ..model,
    diff_scroll_offset: offset,
    notice: "scrolling captured changes",
  )
}

/// Moves a transcript offset without allowing it to cross the live tail.
///
/// This is internal because transcript offsets belong to the terminal model;
/// it is public only so the input law can be pinned without running a PTY.
///
/// ## Examples
///
/// ```gleam
/// assert tui.scroll_offset(3, False, 10) == 0
/// assert tui.scroll_offset(3, True, 10) == 13
/// ```
@internal
pub fn scroll_offset(offset: Int, older: Bool, rows: Int) -> Int {
  case older {
    True -> offset + rows
    False -> int.max(0, offset - rows)
  }
}

/// Clamps scrollback to the oldest full viewport that actually exists.
@internal
pub fn bounded_scroll_offset(
  offset: Int,
  total_rows: Int,
  viewport_rows: Int,
) -> Int {
  int.min(int.max(0, offset), int.max(0, total_rows - viewport_rows))
}

/// Keeps a historical viewport anchored as rows are appended or replaced.
///
/// A zero offset follows the live tail. A non-zero offset is measured from the
/// tail, so rows arriving below the reader must move it by the same amount or
/// the text they are reading slides up the screen.
///
/// Rows leaving the bottom are a different event. Stream fragments are
/// transient: they are replaced by the settled entry, and a detail toggle or a
/// cleared generation can retire several rows at once. Following those
/// downwards walks the reader towards the live tail a fragment at a time and,
/// from a shallow offset, drops them out of scrollback entirely. The offset
/// therefore holds when the bottom shrinks; `bounded_scroll_offset` still
/// clamps it to the rows that exist when the frame is built.
///
/// ## Examples
///
/// ```gleam
/// assert tui.anchored_scroll_offset(0, 20, 23) == 0
/// assert tui.anchored_scroll_offset(8, 20, 23) == 11
/// assert tui.anchored_scroll_offset(8, 20, 17) == 8
/// ```
@internal
pub fn anchored_scroll_offset(offset: Int, before: Int, after: Int) -> Int {
  case offset == 0, after >= before {
    True, _ -> 0
    False, True -> offset + after - before
    False, False -> offset
  }
}

fn submit(model: Model) -> Model {
  case
    outbound.mutation_refusal(
      model,
      command.parse_with_skills(text_area.value(model.input), model.skills),
    )
  {
    Some(reason) -> tui_model.append_error(model, reason)
    None -> {
      // This marker scopes the synchronous encoder call and, only if queued,
      // the later send. The draft itself never leaves its existing fields.
      let prepared = case
        outbound.mutating_submission(
          model,
          command.parse_with_skills(text_area.value(model.input), model.skills),
        ),
        model.peer
      {
        True, Attached(_) ->
          Model(..model, pending_submission: Some(ComposerSubmission))
        _, _ -> model
      }
      let after = submit_admitted(prepared)
      case after.channel {
        Some(channel) ->
          case session_channel.has_unsent(channel) {
            True -> after
            False -> Model(..after, pending_submission: None)
          }
        None -> Model(..after, pending_submission: None)
      }
    }
  }
}

fn submit_admitted(model: Model) -> Model {
  case composer.has_images(model.attachments) {
    True -> submit_with_images(model)
    False -> submit_text(model)
  }
}

fn open_session_selector(model: Model) -> Model {
  case model.daemon_host {
    Some(_) -> load_catalogue(model, "", None)
    None ->
      tui_model.append_error(
        model,
        "daemon control is unavailable; reconnect explicitly",
      )
  }
}

/// Historical host-fixture selector; live terminals always use daemon control.
///
/// ## Examples
///
/// ```gleam
/// // tui.open_legacy_session_selector(fixture)
/// ```
@internal
pub fn open_legacy_session_selector(model: Model) -> Model {
  case model.peer {
    // The selector is built from the local launcher catalogue, which a
    // recording does not carry and a replaying machine need not have. It
    // says so in the notice rather than inventing a listing or an error
    // the live client never showed.
    Replaying -> Model(..model, notice: "/sessions is not replayed")

    Attached(..) | Preview | Disconnected ->
      case model.local_options {
        None ->
          tui_model.append_error(
            model,
            "/sessions is available only for local attachments",
          )
        Some(options) -> open_local_session_selector(model, options)
      }
  }
}

fn open_local_session_selector(
  model: Model,
  options: bootstrap.Options,
) -> Model {
  case sessions.busy(model.session_switch) {
    True ->
      tui_model.append_error(model, "a session switch is already in progress")
    False ->
      case bootstrap.discover_sessions(options) {
        Error(reason) -> tui_model.append_error(model, reason)
        Ok([]) ->
          tui_model.append_error(model, "no locally managed sessions found")
        Ok(choices) -> {
          let current =
            bootstrap.session_file(options)
            |> result.unwrap("")
          Model(
            ..model,
            overlay: SessionSelector(sessions.new(choices, current)),
            repaint_phase: !model.repaint_phase,
            notice: "session selector",
          )
        }
      }
  }
}

fn begin_session_switch(
  model: Model,
  choice: bootstrap.SessionChoice,
) -> Model {
  let model = cancel_pending(model, "target change from " <> model.session)
  case model.peer, model.local_options {
    // Unreachable: a replay never opens the selector this arrives from.
    // Enumerated rather than swept up, so a future path into it starts no
    // daemon and opens no socket.
    Replaying, _ -> Model(..model, overlay: NoOverlay)

    Attached(..), None | Preview, None | Disconnected, None ->
      tui_model.append_error(
        Model(..model, overlay: NoOverlay),
        "/sessions is available only for local attachments",
      )
    Attached(..), Some(options)
    | Preview, Some(options)
    | Disconnected, Some(options)
    ->
      Model(
        ..model,
        overlay: NoOverlay,
        session_switch: sessions.start(choice, options),
        repaint_phase: !model.repaint_phase,
        notice: "opening session " <> choice.session,
      )
  }
}

fn submit_text(model: Model) -> Model {
  let input = text_area.value(model.input)
  let expanded = composer.expand(input, model.attachments)
  let cleared = case model.pending_submission {
    Some(ComposerSubmission) -> model
    Some(OverlaySubmission) | None -> outbound.clear_composer_text(model)
  }
  let prompt_cleared = case model.pending_submission {
    Some(ComposerSubmission) -> cleared
    Some(OverlaySubmission) | None ->
      Model(..cleared, attachments: [], submission_mode: PromptNext)
  }
  case command.parse_with_skills(input, model.skills) {
    command.Empty ->
      case model.attachments {
        [] -> cleared
        _ -> send_prompt(prompt_cleared, expanded)
      }
    command.Quit -> quit(cleared)
    command.Help ->
      Model(
        ..cleared,
        help_open: True,
        notes_open: False,
        note_board: None,
        note_selected: None,
        notes_requested: None,
        scroll_offset: 0,
        repaint_phase: !cleared.repaint_phase,
        notice: "/help",
      )
    command.Clear ->
      Model(
        ..cleared,
        transcript: [],
        records: [],
        record_rows: [],
        record_gutters: [],
        record_line_cache: dict.new(),
        compact_call_cache: dict.new(),
        compact_entry_cache: dict.new(),
        pending_records: [],
        record_cache_valid: False,
        // `/clear` empties the local view, and an echo is part of that view
        // rather than something it is drawn over.
        queued: [],
        awaiting_outcome: None,
        notice: "local view cleared",
      )
      |> tui_model.invalidate_transcript
    command.Models -> {
      let opened =
        Model(
          ..cleared,
          overlay: ModelSelector(model_selector.new(
            model.models,
            model.current_model,
          )),
          repaint_phase: !cleared.repaint_phase,
          notice: "model selector",
        )
      outbound.send_frame(opened, protocol.models(opened.next_id))
    }
    command.Model(name) -> {
      let switched =
        select_model(cleared, name)
        |> outbound.send_frame(protocol.set_model(
          cleared.next_id,
          cleared.active_strand,
          name,
        ))
      tui_model.append_system(switched, "active model changed to " <> name)
    }
    command.Strands | command.Agents -> open_agents(cleared)
    command.Schedules ->
      outbound.send_frame(cleared, protocol.schedules(cleared.next_id))
    command.Unschedule(name:, target:) -> {
      // An absent target means the strand the operator is looking at,
      // which is the row the listing above the prompt just printed. A
      // schedule a parent set onto a subagent needs the second word.
      let target = option.unwrap(target, cleared.active_strand)
      outbound.send_frame(
        tui_model.append_system(
          cleared,
          "cancelling schedule " <> name <> " on " <> target,
        ),
        protocol.schedule_cancel(cleared.next_id, target, name),
      )
    }
    command.Sessions -> open_session_selector(cleared)
    command.Rename(name) ->
      case cleared.session {
        "" -> tui_model.append_error(cleared, "no session is attached")
        id -> begin_rename(cleared, id, name)
      }
    command.Approvals(None) ->
      list.fold(approval_lines(cleared.approvals), cleared, fn(model, line) {
        tui_model.append_system(model, line.text)
      })
    command.Approvals(Some(id)) ->
      request_decisions(Model(..cleared, inspecting_approval: Some(id)), [id])
    command.AddDirectory(path, access) ->
      outbound.send_frame(
        cleared,
        protocol.add_directory(cleared.next_id, path, access),
      )
    command.Approve(id) -> decide(cleared, id, approval.approve)
    command.Deny(id) -> decide(cleared, id, approval.deny)
    command.Notes ->
      surfaces.refresh_notes(
        Model(
          ..cleared,
          help_open: False,
          diff_view: DiffHidden,
          worktree: worktree_view.State(
            ..cleared.worktree,
            focus: worktree_view.Composer,
          ),
          notes_open: True,
          note_mode: note_panel.Readable,
          note_scroll: 0,
          scroll_offset: 0,
          repaint_phase: !cleared.repaint_phase,
          notice: "agent notes",
        ),
      )
    command.QueueInspect -> open_queue(cleared)
    command.Summary -> surfaces.open_summary(cleared)
    command.Context -> surfaces.open_context(cleared, context_view.Overview)
    command.ContextAll -> surfaces.open_context(cleared, context_view.All)
    command.Diff -> open_diff(cleared)
    command.Details -> toggle_details(cleared)
    command.Strand(name) ->
      case tui_model.is_known_strand(cleared.strands, name) {
        True ->
          tui_model.append_system(
            switch_active_strand(cleared, name),
            "active strand: " <> name,
          )
        False -> tui_model.append_error(cleared, "unknown strand: " <> name)
      }
    command.Fork(name) ->
      outbound.send_frame(
        tui_model.append_system(cleared, "fork queued: " <> name),
        protocol.fork(cleared.next_id, cleared.active_strand, name),
      )
    command.Effort(level) ->
      outbound.send_frame(
        tui_model.append_system(
          cleared,
          "reasoning level for " <> cleared.active_strand <> ": " <> level,
        ),
        protocol.set_thinking(cleared.next_id, cleared.active_strand, level),
      )
    command.GoalStatus -> surfaces.request_goal_status(cleared)

    // Each mutation's confirmation waits for the board that commits it.
    // The server answers every goal mutation with the fresh board or with
    // a refusal, so the line belongs on the reply: printed on the way out
    // it claimed a goal was pinned and was then followed by the sentence
    // saying no advisor is routed.
    command.GoalSet(objective:, token_budget:) ->
      outbound.send_frame(
        surfaces.confirming(
          cleared,
          "goal pinned · budget "
            <> int.to_string(token_budget)
            <> " tokens · /goal --budget N sets it",
        ),
        protocol.goal_set(cleared.next_id, objective, token_budget),
      )

    // The confirmation names the command back, because an operator who
    // mistyped it should see what the harness will run before the reviewer
    // is shown its result.
    command.GoalCheck(command: Some(check)) ->
      outbound.send_frame(
        surfaces.confirming(cleared, "the goal check is " <> check),
        protocol.goal_check(cleared.next_id, Some(check)),
      )
    command.GoalCheck(command: None) ->
      outbound.send_frame(
        surfaces.confirming(cleared, "the goal check is cleared"),
        protocol.goal_check(cleared.next_id, None),
      )
    command.GoalClear ->
      outbound.send_frame(
        surfaces.confirming(cleared, "the session goal is cleared"),
        protocol.goal_clear(cleared.next_id),
      )
    command.GoalPause -> surfaces.submit_goal_action(cleared, command.GoalPause)
    command.GoalResume ->
      surfaces.submit_goal_action(cleared, command.GoalResume)

    // The word is shown back because the operator has to see which of
    // their words was read as the budget, and a goal must never be pinned
    // to a spend nobody chose.
    command.GoalBudgetInvalid(word) ->
      tui_model.append_error(
        cleared,
        "/goal --budget needs a positive token count, not \""
          <> word
          <> "\" · /goal <objective> pins the default budget instead",
      )

    // The count is shown because the operator has to know how much to cut,
    // and the objective is not sent: the server refuses it on the same
    // bound, and a round trip to be told so is a round trip wasted.
    // The count is shown for the reason the objective's is: the operator has
    // to know how much to cut, and the two bounds are different numbers.
    command.GoalCheckTooLong(count) ->
      tui_model.append_error(
        cleared,
        "/goal check command is "
          <> int.to_string(count)
          <> " characters; the most a goal check may carry is "
          <> int.to_string(command.check_limit),
      )
    command.GoalObjectiveTooLong(count) ->
      tui_model.append_error(
        cleared,
        "/goal objective is "
          <> int.to_string(count)
          <> " characters; the most a goal may carry is "
          <> int.to_string(command.objective_limit),
      )
    command.Compact ->
      outbound.send_frame(
        tui_model.append_system(
          cleared,
          "compaction queued for " <> cleared.active_strand,
        ),
        protocol.compact(cleared.next_id, cleared.active_strand),
      )
    command.Abort ->
      outbound.send_frame(
        tui_model.append_system(
          cleared,
          "abort queued for " <> cleared.active_strand,
        ),
        protocol.abort(cleared.next_id, cleared.active_strand),
      )
    command.Steer(text) ->
      send_explicit_steer(
        prompt_cleared,
        composer.expand(text, model.attachments),
        model,
      )
    command.Queue(text) ->
      send_follow_up(prompt_cleared, composer.expand(text, model.attachments))
    command.Unknown(name) ->
      tui_model.append_error(cleared, "unknown command /" <> name)
    command.MissingArgument(name) ->
      tui_model.append_error(cleared, "/" <> name <> " needs an argument")
    command.Prompt(_) -> send_user_text(prompt_cleared, expanded, model)
  }
}

// Images are new prompt content, never live-turn steering, and `prompt_content`
// is the only frame that carries them. A slash command therefore has nowhere to
// put an attachment; refusing before the editor is cleared preserves both the
// instruction and every local attachment. Liveness is not this client's
// question: `prompt` on a busy strand is held by the daemon and drained when
// the run settles, so an image prompt goes out and comes back `queued`.
fn submit_with_images(model: Model) -> Model {
  let input = text_area.value(model.input)
  case command.parse_with_skills(input, model.skills) {
    command.Empty | command.Prompt(_) -> send_image_prompt(model, input)
    command.QueueInspect
    | command.Diff
    | command.Summary
    | command.Context
    | command.ContextAll -> submit_text(model)
    command.Help
    | command.Models
    | command.Model(_)
    | command.Strands
    | command.Schedules
    | command.Unschedule(..)
    | command.Agents
    | command.Sessions
    | command.Rename(_)
    | command.Approvals(_)
    | command.AddDirectory(..)
    | command.Approve(_)
    | command.Deny(_)
    | command.Notes
    | command.Details
    | command.Strand(_)
    | command.Fork(_)
    | command.Effort(_)
    | command.GoalStatus
    | command.GoalSet(..)
    | command.GoalCheck(..)
    | command.GoalClear
    | command.GoalPause
    | command.GoalResume
    | command.GoalBudgetInvalid(_)
    | command.GoalObjectiveTooLong(_)
    | command.GoalCheckTooLong(_)
    | command.Compact
    | command.Abort
    | command.Steer(_)
    | command.Queue(_)
    | command.Clear
    | command.Quit
    | command.Unknown(_)
    | command.MissingArgument(_) ->
      tui_model.append_error(
        model,
        "image attachments can only accompany an ordinary prompt",
      )
  }
}

fn send_image_prompt(model: Model, input: String) -> Model {
  let expanded = composer.expand(input, model.attachments)
  let images = composer.images(model.attachments)
  let content = image_prompt_content(expanded, images)
  let cleared = case model.pending_submission {
    Some(ComposerSubmission) -> model
    Some(OverlaySubmission) | None -> outbound.clear_composer(model)
  }
  send_prompt_content(cleared, content, expanded, images)
}

/// Builds one ordered user turn without exposing local image paths.
@internal
pub fn image_prompt_content(
  text: String,
  images: List(image_drop.Image),
) -> List(message.UserBlock) {
  let text_blocks = case text {
    "" -> []
    _ -> [message.UserText(text, None)]
  }
  let image_blocks =
    list.map(images, fn(image) {
      let image_drop.Image(data:, mime_type:, ..) = image
      message.UserImage(data, mime_type)
    })
  list.append(text_blocks, image_blocks)
}

fn send_prompt_content(
  model: Model,
  content: List(message.UserBlock),
  text: String,
  images: List(image_drop.Image),
) -> Model {
  let sent =
    Model(
      ..expect_own_turn(model, HeldPrompt(text)),
      submitting: Some(model.active_strand),
      notice: "image prompt sent to " <> model.active_strand,
    )
  case model.peer {
    Attached(..) ->
      outbound.send_frame(
        sent,
        protocol.prompt_content(model.next_id, model.active_strand, content),
      )

    // A replay stops exactly where the live client's local work stopped.
    // The turn it produced is in the recording and arrives as an entry.
    Replaying -> sent
    Disconnected -> tui_model.append_error(model, "no conversation is attached")
    Preview ->
      Model(
        ..model,
        transcript: list.append(model.transcript, [
          Line(User, image_prompt_preview(text, images, model.details_expanded)),
          Line(Assistant, "Design-preview echo received."),
        ]),
        record_cache_valid: False,
        notice: "image prompt accepted",
      )
      |> tui_model.invalidate_transcript
  }
}

fn image_prompt_preview(
  text: String,
  images: List(image_drop.Image),
  details_expanded: Bool,
) -> String {
  let text = case text {
    "" -> []
    _ -> [composer.transcript_text(text, details_expanded)]
  }
  let image_labels =
    list.map(images, fn(image) {
      let image_drop.Image(filename:, mime_type:, byte_size:, ..) = image
      "[image: "
      <> text_hygiene.single_line(filename)
      <> " · "
      <> mime_type
      <> " · "
      <> int.to_string(byte_size)
      <> " B]"
    })
  list.append(text, image_labels) |> string.join("\n")
}

// The draft is captured exactly once when navigation leaves the live editor.
// Returning past the newest history item restores those unsent bytes rather
// than replacing them with an empty prompt.
fn navigate_history(model: Model, older: Bool) -> Model {
  let #(history_index, history_draft, value) =
    history_selection(
      model.history,
      model.history_index,
      model.history_draft,
      text_area.value(model.input),
      older,
    )
  Model(
    ..model,
    input: text_area.state_from_string(value),
    history_index:,
    history_draft:,
  )
}

/// Selects the next prompt-history value without owning terminal state.
///
/// ## Examples
///
/// ```gleam
/// assert tui.history_selection(["new", "old"], 0, "", "draft", True)
///   == #(1, "draft", "new")
/// assert tui.history_selection(["new"], 1, "draft", "new", False)
///   == #(0, "draft", "draft")
/// ```
@internal
pub fn history_selection(
  history: List(String),
  index: Int,
  draft: String,
  current: String,
  older: Bool,
) -> #(Int, String, String) {
  let saved_draft = case index == 0, older {
    True, True -> current
    _, _ -> draft
  }
  let target = case older {
    True -> int.min(list.length(history), index + 1)
    False -> int.max(0, index - 1)
  }
  case target {
    0 -> #(0, saved_draft, saved_draft)
    _ ->
      case history_item(history, target - 1) {
        Some(value) -> #(target, saved_draft, value)
        None -> #(index, saved_draft, current)
      }
  }
}

fn history_item(history: List(String), index: Int) -> Option(String) {
  case history, index {
    [item, ..], 0 -> Some(item)
    [_, ..rest], index -> history_item(rest, index - 1)
    [], _ -> None
  }
}

fn send_user_text(cleared: Model, text: String, before: Model) -> Model {
  case tui_model.active_interrupt(before) {
    Some(strand) -> hold_or_send_interrupt(cleared, before, strand, text)
    None ->
      case tui_model.active_strand_live(before), before.submission_mode {
        False, _ -> send_prompt(cleared, text)

        // A prompt aimed at a running strand is held by the daemon and run
        // when that strand settles, so this is the same frame as the idle
        // case and needs no command of its own. Only the local echo differs.
        True, PromptNext -> send_prompt(cleared, text)
        True, SteerNow -> send_steer(cleared, text)
      }
  }
}

// `/steer` is an explicit instruction about ordering, so a pending interrupt
// does not quietly turn it into a prompt. The gateway holds a steer at its own
// priority and a release keeps that priority, which is what the operator asked
// for (`protocol-change/033`). Only a legacy host without a gateway queue falls
// back to the client-side hold.
fn send_explicit_steer(cleared: Model, text: String, before: Model) -> Model {
  use <- bool.lazy_guard(before.channel != None, fn() {
    send_steer(cleared, text)
  })
  case tui_model.active_interrupt(before) {
    Some(strand) -> hold_or_send_interrupt(cleared, before, strand, text)
    None -> send_steer(cleared, text)
  }
}

// After an Escape the daemon halts everything it holds for the strand and
// waits for the operator (`protocol-change/033`). What the operator types
// next is an ordinary prompt: the gateway appends it to the halted queue and
// releases the whole batch, so it runs after the held input rather than
// ahead of it as a steer would. A legacy host without a gateway queue keeps
// the older client-side hold until the terminal transition.
fn hold_or_send_interrupt(
  cleared: Model,
  before: Model,
  strand: String,
  text: String,
) -> Model {
  use <- bool.lazy_guard(before.channel != None, fn() {
    send_prompt_to(cleared, strand, text)
  })
  case tui_model.active_strand_live(before) {
    False -> send_prompt_to(Model(..cleared, interrupt: None), strand, text)
    True -> {
      let pending = case before.interrupt {
        Some(Interrupt(pending: Some(earlier), ..)) ->
          Some(earlier <> "\n\n" <> text)
        _ -> Some(text)
      }
      Model(
        ..cleared,
        interrupt: Some(Interrupt(strand:, operation: None, pending:)),
        notice: "steer captured; waiting for stop",
      )
    }
  }
}

fn send_prompt(model: Model, text: String) -> Model {
  send_prompt_to(model, model.active_strand, text)
}

// The local submitting marker closes the interval between writing a prompt
// frame and receiving its first operation transition. Websocket ordering then
// lets an immediate Escape place abort after prompt on the same connection,
// even though the server's live phase has not reached the view yet.
fn send_prompt_to(model: Model, strand: String, text: String) -> Model {
  let sent =
    Model(
      ..expect_own_turn(model, HeldPrompt(text)),
      submitting: Some(strand),
      notice: "prompt sent to " <> strand,
    )
  case model.peer {
    Attached(..) ->
      outbound.send_frame(sent, protocol.prompt(model.next_id, strand, text))

    // The server echoed this turn back as an entry, and the recording has
    // it. Drawing a local copy here would show the operator's line twice.
    Replaying -> sent
    Disconnected -> tui_model.append_error(model, "no conversation is attached")
    Preview ->
      Model(
        ..model,
        transcript: list.append(model.transcript, [
          Line(User, composer.transcript_text(text, model.details_expanded)),
          Line(Assistant, "Design-preview echo received."),
        ]),
        record_cache_valid: False,
        notice: "prompt accepted",
      )
      |> tui_model.invalidate_transcript
  }
}

// Records one submission this terminal made to a running active strand, so
// that the entry it eventually produces is accounted for.
//
// For a `HeldPrompt` the record is also what the operator sees. A prompt
// submitted to a running strand does not become an entry until the daemon
// drains it, which is a whole turn away. Without a local copy the operator's
// line simply vanishes for as long as the run lasts, and the natural reading
// is that the keystroke was lost — which is what sent people looking for the
// bug this answers. The echo is drawn under the live tail and retired by the
// entry it stands for.
//
// `Preview` draws its own echo and `Disconnected` sent nothing, so neither
// records anything here. An idle strand does not either: nothing is held, its
// entry is already on its way back, and two copies would be worse than a slow
// one.
// An attached submission waits in `awaiting_outcome` for the daemon's answer,
// because a refusal is a real outcome here and the echo has to go back with
// it. A replay has no daemon to answer, so its submission joins the list at
// once and the recording's own entry retires it.
fn expect_own_turn(model: Model, submission: Submission) -> Model {
  case model.peer, tui_model.active_strand_live(model) {
    Attached(..), True ->
      Model(..model, awaiting_outcome: Some(submission))
      |> tui_model.invalidate_transcript
    Replaying, True ->
      Model(..model, queued: in_commit_order(model.queued, submission))
      |> tui_model.invalidate_transcript
    Attached(..), False | Replaying, False | Preview, _ | Disconnected, _ ->
      model
  }
}

// The daemon took the submission: it will commit an entry, so the submission
// joins the list that waits for one.
fn settle_own_turn(model: Model) -> Model {
  case model.awaiting_outcome {
    Some(submission) ->
      Model(
        ..model,
        queued: in_commit_order(model.queued, submission),
        awaiting_outcome: None,
      )
    None -> model
  }
}

// Forgets the submissions an abort cancelled, keeping the ones it does not
// reach.
//
// The invariant this restores is the queue's: every submission in the list is
// owed an entry. An abort breaks that for interjections alone, because the
// steer and follow-up items still queued on the run are discarded with the
// run instead of being committed. Left in place they would absorb the entries
// the held prompts produce, and each prompt's echo would outlive the line it
// stood for.
fn abandon_interjections(model: Model) -> Model {
  let held =
    list.filter(model.queued, fn(submission) {
      case submission {
        Interjection -> False
        HeldPrompt(..) -> True
      }
    })

  // A submission still awaiting its outcome was sent to the same run, so an
  // interjection there is cancelled on the same grounds. A prompt keeps
  // waiting for the reply that is still coming for it.
  let awaiting = case model.awaiting_outcome {
    Some(Interjection) -> None
    Some(HeldPrompt(..)) | None -> model.awaiting_outcome
  }

  Model(..model, queued: held, awaiting_outcome: awaiting)
  |> tui_model.invalidate_transcript
}

// Places one submission where the daemon will commit it.
//
// Submission order is not commit order, which is the trap here. An
// interjection joins the run that is already open and commits during it,
// while every held prompt waits for that run to settle — so a steer typed
// after a prompt was queued still commits first. Keeping the list in commit
// order is what lets `drained_echoes` stay a drop of the head, and it is the
// list's whole invariant: interjections first, in the order they were made,
// then the held prompts in the order the daemon drains them.
fn in_commit_order(
  queued: List(Submission),
  submission: Submission,
) -> List(Submission) {
  case submission {
    HeldPrompt(..) -> list.append(queued, [submission])
    Interjection -> {
      let #(interjections, held) =
        list.split_while(queued, fn(earlier) {
          case earlier {
            Interjection -> True
            HeldPrompt(..) -> False
          }
        })
      list.flatten([interjections, [submission], held])
    }
  }
}

// Retires the oldest outstanding submission when a user turn commits on the
// strand it was made on.
//
// `in_commit_order` holds the list in the order the daemon commits these, so
// the head is what the entry belongs to, and an interjection at the head
// absorbs the entry without touching the echo behind it — which is the whole
// reason steers and follow-ups are recorded here at all. Matching on the text
// instead would have to reproduce the server's authorship prefix and its
// block layout, and would still pick the wrong entry for two identical
// prompts.
//
// A second operator's prompt or steer on the same strand still retires the
// head early. That costs a queued marker one turn of visibility, and the
// entry it stood for still arrives in its place.
fn drained_echoes(
  queued: List(Submission),
  record: protocol.EntryRecord,
) -> List(Submission) {
  let protocol.EntryRecord(entry: value, ..) = record
  case value {
    entry.MessageEntry(message: message.UserMessage(..), ..) ->
      list.drop(queued, 1)
    entry.MessageEntry(..)
    | entry.CompactionEntry(..)
    | entry.BranchSummaryEntry(..)
    | entry.CustomEntry(..) -> queued
  }
}

// A steer draws no echo, but the entry it commits is indistinguishable from a
// drained prompt's, so it is recorded as an interjection: without that, a
// steer typed while a prompt is held retires the prompt's echo and the
// operator watches their own line disappear, which is the symptom the echo
// exists to prevent.
fn send_steer(model: Model, text: String) -> Model {
  outbound.send_frame(
    Model(
      ..expect_own_turn(model, steering_submission(model, text)),
      notice: "steered " <> model.active_strand,
    ),
    protocol.steer(model.next_id, model.active_strand, text),
  )
}

// Both controls transfer input custody to the modern host queue. Older
// recordings still account for their original in-operation interjections.
fn send_follow_up(model: Model, text: String) -> Model {
  outbound.send_frame(
    Model(
      ..expect_own_turn(model, steering_submission(model, text)),
      notice: "queued after " <> model.active_strand,
    ),
    protocol.follow_up(model.next_id, model.active_strand, text),
  )
}

fn steering_submission(model: Model, text: String) -> Submission {
  case model.channel {
    Some(_) -> HeldPrompt(text)
    None -> Interjection
  }
}

fn toggle_submission_mode(model: Model) -> Model {
  case
    tui_model.active_interrupt(model),
    tui_model.active_strand_live(model),
    model.submission_mode
  {
    Some(_), _, _ -> Model(..model, notice: "interrupt steer is already armed")
    None, False, _ ->
      Model(..model, notice: "steering is available while an agent runs")
    None, True, PromptNext ->
      Model(..model, submission_mode: SteerNow, notice: "steer now")
    None, True, SteerNow ->
      Model(..model, submission_mode: PromptNext, notice: "queue for next turn")
  }
}

fn interrupt_active(model: Model) -> Model {
  case tui_model.active_strand_phase(model), tui_model.active_interrupt(model) {
    None, _ -> Model(..model, notice: "nothing is running")
    Some(_), Some(_) -> Model(..model, notice: "interrupt already requested")
    Some(_), None -> {
      let strand = model.active_strand
      outbound.send_frame(
        Model(
          ..model,
          interrupt: Some(Interrupt(
            strand:,
            operation: captured_operation(model, strand),
            pending: None,
          )),
          submission_mode: PromptNext,
          notice: "stopping; held input waits · enter sends it with your message",
        ),
        protocol.abort(model.next_id, strand),
      )
    }
  }
}

// Terminals encode Alt+character as Escape followed by that character. If a
// user begins typing immediately after Escape, the backend cannot distinguish
// the two intentions before its disambiguation timeout. The client reserves no
// Alt shortcuts, so preserving both actions here avoids dropping the first
// byte of a replacement steer.
fn interrupt_and_insert(model: Model, character: String) -> Model {
  let interrupted = interrupt_active(model)
  let editor = text_area.textarea_new() |> text_area.with_max_lines(1)
  Model(
    ..interrupted,
    input: text_area.insert_char(editor, interrupted.input, character),
  )
}

fn settle_interrupt(model: Model, strand: String, phase: String) -> Model {
  case phase == "done", model.interrupt {
    True, Some(Interrupt(strand: target, pending:, ..)) ->
      case target == strand, pending {
        True, Some(text) ->
          send_prompt_to(Model(..model, interrupt: None), target, text)
        True, None ->
          Model(..model, interrupt: None, notice: target <> ": interrupted")
        False, _ -> model
      }
    _, _ -> model
  }
}

// A coherent cut may skip the idle interval between two queued turns. Match
// the operation, not just the strand's busy flag, when retiring the stop UI.
fn reconcile_interrupt(
  interrupt: Option(Interrupt),
  operations: Dict(String, String),
) -> Option(Interrupt) {
  case interrupt {
    None -> None
    Some(stopped) ->
      case dict.get(operations, stopped.strand), stopped.operation {
        Error(Nil), _ -> None
        Ok(current), Some(previous) if current != previous -> None
        Ok(_), _ -> interrupt
      }
  }
}

fn captured_operation(model: Model, strand: String) -> Option(String) {
  case model.captured {
    Some(#(_, view)) -> dict.get(view.operations, strand) |> option.from_result
    None -> None
  }
}

fn toggle_agent_rail(model: Model) -> Model {
  let visible = !model.agent_rail_visible
  Model(
    ..model,
    agent_rail_visible: visible,
    repaint_phase: !model.repaint_phase,
    notice: case visible {
      True -> "agent rail shown"
      False -> "agent rail hidden"
    },
  )
}

fn toggle_details(model: Model) -> Model {
  let expanded = !model.details_expanded
  Model(
    ..model,
    details_expanded: expanded,
    repaint_phase: !model.repaint_phase,
    notice: case expanded {
      True -> "details expanded"
      False -> "details collapsed"
    },
  )
}

// Live transport loss retains the transcript without becoming a design demo.
// A replay remains a replay and cannot fabricate responses after recorded loss.
fn after_close(peer: Peer) -> Peer {
  case peer {
    Attached(..) | Disconnected -> Disconnected
    Preview -> Preview
    Replaying -> Replaying
  }
}

fn quit(model: Model) -> Model {
  sessions.cancel(model.session_switch)
  attachment.cancel(model.candidate)
  case model.control_request {
    None -> Nil
    Some(run) -> weft.cancel(run.cancel)
  }

  // A relaunch may be mid-start when the operator quits. Cancelling it stops
  // spawning a daemon nobody will talk to, and the close below covers the
  // control owner it may already have minted.
  case model.reconnect {
    ReconnectIdle | ReconnectSpent -> Nil
    ReconnectAttempting(cancel:, ..) -> weft.cancel(cancel)
  }
  case model.daemon_host {
    None -> Nil
    Some(host) -> daemon.close(daemon_selection.control(host))
  }
  case model.channel {
    Some(channel) -> session_channel.close(channel)
    None ->
      case model.peer {
        Attached(socket:) -> connection.close(socket)
        Preview | Replaying | Disconnected -> Nil
      }
  }
  Model(..model, quit: True)
}

// Keep draft ownership across sessions while retaining history only for
// strands still present in the current session. Draft text is never evicted.
fn prune_workspace_history(
  workspaces: Dict(#(String, String), StrandWorkspace),
  session: String,
  strands: List(protocol.Strand),
) -> Dict(#(String, String), StrandWorkspace) {
  dict.map_values(workspaces, fn(owner, saved) {
    case owner.0 == session && tui_model.is_known_strand(strands, owner.1) {
      True -> saved
      False ->
        StrandWorkspace(
          ..saved,
          scrollback: history_view.empty(),
          reading_lines: None,
          offset: 0,
          anchors: [],
          prefix: 0,
        )
    }
  })
}

// New destinations begin with their own editor and an empty history window.
fn empty_workspace() -> StrandWorkspace {
  StrandWorkspace(
    text_area.state_new(),
    [],
    [],
    0,
    "",
    PromptNext,
    history_view.empty(),
    None,
    0,
    [],
    0,
    1,
  )
}

// Save before changing identity; both empty drafts and submission mode belong
// to the destination, so a first visit starts with a fresh editor.
fn select_workspace(model: Model, session: String, strand: String) -> Model {
  use <- bool.guard(
    model.session == session && model.active_strand == strand,
    model,
  )

  // Session observations belong to the attachment that read them. Reusing
  // the common strand name "main" cannot transfer advice or a goal.
  let model = case model.session == session {
    True -> model
    False ->
      Model(
        ..model,
        nudges: None,
        nudges_refresh: worktree_view.Settled,
        nudges_awaiting: None,
        nudges_request: None,
        goal: None,
        goal_refresh: worktree_view.Settled,
        goal_awaiting: None,
        goal_request: None,
        goal_report: HoldGoalReport,
        overlay: case model.overlay {
          GoalInspector(_) -> NoOverlay
          other -> other
        },
      )
  }

  // Before the first attachment there is no previous session to park in.
  // Bind that unassigned editor to the explicitly chosen session once;
  // later switches keep their existing session identities and own drafts.
  let draft_session = case model.session {
    "" -> session
    previous -> previous
  }
  let parked =
    dict.insert(
      model.strand_workspaces,
      #(draft_session, model.active_strand),
      StrandWorkspace(
        model.input,
        model.attachments,
        model.history,
        model.history_index,
        model.history_draft,
        model.submission_mode,
        model.scrollback,
        model.reading_lines,
        model.scroll_offset,
        model.rendered_anchors,
        model.rendered_row_count - list.length(model.rendered_anchors),
        layout.transcript_viewport_height(model),
      ),
    )
  let saved = dict.get(parked, #(session, strand)) |> option.from_result
  let restored = option.unwrap(saved, empty_workspace())
  Model(
    ..model,
    strand_workspaces: dict.delete(parked, #(session, strand)),
    agent_rows: case model.session == session {
      True -> model.agent_rows
      False -> []
    },
    agent_messages: case model.session == session {
      True -> model.agent_messages
      False -> []
    },
    advisor_history: case model.session == session {
      True -> model.advisor_history
      False -> advisor_history.Board(items: [], unloaded: None)
    },
    reviewer_rows: case model.session == session {
      True -> model.reviewer_rows
      False -> []
    },
    restored_workspace: saved,
    input: restored.input,
    attachments: restored.attachments,
    history: restored.history,
    history_index: restored.history_index,
    history_draft: restored.history_draft,
    command_selected: 0,
    submission_mode: restored.submission_mode,
    scrollback: history_view.cancel(restored.scrollback),
    reading_lines: restored.reading_lines,
    scroll_offset: restored.offset,
  )
}

fn switch_active_strand(model: Model, strand: String) -> Model {
  let model = cancel_pending(model, "target change from " <> model.session)
  let model = select_workspace(model, model.session, strand)
  let selected =
    Model(
      ..model,
      overlay: NoOverlay,
      active_strand: strand,
      queued: [],
      awaiting_outcome: None,
      cache_outlook: "",
      current_model: "loading…",
      record_cache_valid: False,
      repaint_phase: !model.repaint_phase,
      notice: "active strand: " <> strand,
    )
    |> tui_model.invalidate_transcript
  case model.captured {
    Some(#(cut, view)) -> apply_cut(selected, cut, view)
    None ->
      outbound.send_frame(selected, protocol.config(model.next_id, strand))
  }
}

fn demo_models() -> List(protocol.ModelInfo) {
  [
    ModelInfo(
      name: "baseten-kimi-k3",
      dialect: "openai",
      model_id: "moonshotai/Kimi-K3",
      roles: ["default"],
      active: ["default"],
    ),
    ModelInfo(
      name: "baseten-deepseek-v4-flash",
      dialect: "openai",
      model_id: "deepseek-ai/DeepSeek-V4-Flash-0731",
      roles: ["fast"],
      active: [],
    ),
    ModelInfo(
      name: "baseten-glm-5-3",
      dialect: "openai",
      model_id: "zai-org/GLM-5.3",
      roles: ["deep"],
      active: [],
    ),
    ModelInfo(
      name: "baseten-glm-5-3-flash",
      dialect: "openai",
      model_id: "zai-org/GLM-5.3-Flash",
      roles: ["fast"],
      active: [],
    ),
  ]
}

fn demo_strands() -> List(protocol.Strand) {
  [
    Strand(id: "main", name: Some("main"), live_phase: Some("streaming")),
    Strand(
      id: "sub:main/catalog-audit-27af",
      name: Some("catalog audit"),
      live_phase: Some("running tools"),
    ),
    Strand(
      id: "sub:main/terminal-qa-8c1e",
      name: Some("terminal qa"),
      live_phase: None,
    ),
  ]
}

/// Opens held-input inspection without touching composer text or attachments.
///
/// ## Examples
///
/// ```gleam
/// // tui.open_queue(model)
/// ```
@internal
pub fn open_queue(model: Model) -> Model {
  Model(..model, queue_editor: queue_editor.open(model.queue_editor))
  |> tui_model.invalidate_frame
}

// Mouse selection reuses the rectangle already reserved for rendering. The
// passive card maps one visible message per row; the wide inspector maps its
// left-hand list after the heading. Compact inspection shows only the selected
// preview, so a click there leaves identity unchanged.
fn queue_row_hit(
  model: Model,
  area: Rect,
  at: geometry.Position,
) -> Option(Int) {
  use <- bool.guard(!geometry.contains(layout.panel_inner(area), at), None)
  let rows = layout.queue_rows(model)
  let inner = layout.panel_inner(area)
  let index = case model.queue_editor.surface {
    queue_editor.Closed -> at.y - inner.position.y
    queue_editor.Inspector -> {
      let content = layout.queue_content_area(area)
      let list_width = int.min(36, { content.size.width * 2 } / 5)
      let visible = int.max(1, content.size.height - 1)
      let list_area =
        geometry.rect_new(
          content.position.x,
          content.position.y + 1,
          list_width,
          int.min(visible, list.length(rows)),
        )
      case
        content.size.width >= 70
        && content.size.height >= 6
        && geometry.contains(list_area, at)
      {
        True -> {
          let offset =
            int.min(
              model.queue_editor.selected,
              int.max(0, list.length(rows) - visible),
            )
          offset + at.y - list_area.position.y
        }
        False -> -1
      }
    }
    queue_editor.Editor -> -1
  }
  let visible = case model.queue_editor.surface {
    queue_editor.Closed -> int.min(3, list.length(rows))
    queue_editor.Inspector -> list.length(rows)
    queue_editor.Editor -> 0
  }
  case index >= 0 && index < visible {
    True -> Some(index)
    False -> None
  }
}

fn update_queue_key(key: keys.Key, model: Model) -> Model {
  let state = model.queue_editor
  case key, state.surface {
    keys.Ctrl("c"), _ -> quit(model)
    keys.Escape, queue_editor.Editor ->
      Model(
        ..model,
        queue_editor: queue_editor.State(
          ..state,
          surface: queue_editor.Inspector,
          fetch: None,
          awaiting: None,
        ),
      )
    keys.Escape, queue_editor.Inspector ->
      Model(
        ..model,
        queue_editor: queue_editor.State(
          ..state,
          surface: queue_editor.Closed,
          fetch: None,
          awaiting: None,
        ),
      )
    keys.Up, queue_editor.Inspector ->
      Model(
        ..model,
        queue_editor: queue_editor.State(
          ..state,
          selected: int.max(0, state.selected - 1),
          preview_scroll: 0,
        ),
      )
    keys.Down, queue_editor.Inspector ->
      Model(
        ..model,
        queue_editor: queue_editor.State(
          ..state,
          selected: int.min(
            int.max(0, list.length(layout.queue_rows(model)) - 1),
            state.selected + 1,
          ),
          preview_scroll: 0,
        ),
      )
    keys.PageUp, queue_editor.Inspector -> {
      let area = layout.queue_preview_area(model)
      let maximum =
        queue_panel.max_scroll(layout.queue_rows(model), state.selected, area)
      Model(
        ..model,
        queue_editor: queue_editor.State(
          ..state,
          preview_scroll: int.max(
            0,
            int.min(state.preview_scroll, maximum) - queue_panel.page_rows(area),
          ),
        ),
      )
    }
    keys.PageDown, queue_editor.Inspector -> {
      let area = layout.queue_preview_area(model)
      let maximum =
        queue_panel.max_scroll(layout.queue_rows(model), state.selected, area)
      Model(
        ..model,
        queue_editor: queue_editor.State(
          ..state,
          preview_scroll: int.min(
            maximum,
            int.min(state.preview_scroll, maximum) + queue_panel.page_rows(area),
          ),
        ),
      )
    }
    keys.Char("e"), queue_editor.Inspector -> resume_queue_draft(model)
    keys.Enter, queue_editor.Inspector -> select_queue_input(model)
    keys.Ctrl("r"), queue_editor.Editor -> reconcile_queue_draft(model)
    keys.Ctrl("s"), queue_editor.Editor -> save_queue_draft(model)
    _, queue_editor.Editor ->
      edit_queue_text(model, fn(input) { queue_text_key(key, input) })
    _, queue_editor.Closed | _, queue_editor.Inspector -> model
  }
}

fn resume_queue_draft(model: Model) -> Model {
  case model.queue_editor.draft {
    Some(_) ->
      Model(
        ..model,
        queue_editor: queue_editor.State(
          ..model.queue_editor,
          surface: queue_editor.Editor,
          fetch: None,
          awaiting: None,
          request_id: None,
          message: "Retained draft resumed · Ctrl+s saves · Esc returns to inspection",
        ),
      )
    None ->
      Model(
        ..model,
        queue_editor: queue_editor.State(
          ..model.queue_editor,
          message: "No retained queue draft to resume",
        ),
      )
  }
}

fn select_queue_input(model: Model) -> Model {
  let state = model.queue_editor
  case list.first(list.drop(layout.queue_rows(model), state.selected)) {
    Ok(row) ->
      case
        retained_other_draft(state.draft, row, tui_model.queue_namespace(model)),
        row.editing
      {
        True, _ ->
          Model(
            ..model,
            queue_editor: queue_editor.State(
              ..state,
              message: "Retained draft belongs to another input · e resumes it; browsing remains available",
            ),
          )
        False, snapshot_view.Editable -> {
          let fetch =
            queue_editor.Fetch(
              tui_model.queue_owner(model),
              tui_model.queue_namespace(model),
              row.strand,
              row.id,
            )
          surfaces.service_queue_read(
            Model(
              ..model,
              queue_editor: queue_editor.State(
                ..state,
                fetch: Some(fetch),
                awaiting: None,
                request_id: None,
                message: "Waiting for the full queued input…",
              ),
            ),
          )
        }
        False, snapshot_view.ReadOnly ->
          Model(
            ..model,
            queue_editor: queue_editor.State(
              ..state,
              message: "This queued input is read-only for this attachment",
            ),
          )
      }
    Error(Nil) -> model
  }
}

fn retained_other_draft(
  draft: Option(queue_editor.Draft),
  row: snapshot_view.PendingInput,
  namespace: String,
) -> Bool {
  case draft {
    Some(draft) -> {
      let dirty =
        text_area.value(draft.input) != draft.document.text
        || draft.delivery != queue_editor.Editable
      dirty
      && {
        draft.namespace != namespace
        || draft.document.id != row.id
        || draft.document.strand != row.strand
      }
    }
    None -> False
  }
}

fn reconcile_queue_draft(model: Model) -> Model {
  let state = model.queue_editor
  case state.draft {
    Some(draft) if draft.delivery != queue_editor.Saving -> {
      use <- bool.guard(
        draft.namespace != tui_model.queue_namespace(model),
        Model(
          ..model,
          queue_editor: queue_editor.State(
            ..state,
            message: "Queue namespace changed; this retained draft cannot be rebound",
          ),
        ),
      )
      let fetch =
        queue_editor.Fetch(
          tui_model.queue_owner(model),
          tui_model.queue_namespace(model),
          draft.document.strand,
          draft.document.id,
        )
      surfaces.service_queue_read(
        Model(
          ..model,
          queue_editor: queue_editor.State(
            ..state,
            fetch: Some(fetch),
            message: "Explicitly reconciling with the current queue…",
          ),
        ),
      )
    }
    Some(_) | None -> model
  }
}

fn save_queue_draft(model: Model) -> Model {
  case model.queue_editor.draft, model.channel {
    Some(draft), Some(channel) if draft.delivery == queue_editor.Editable -> {
      let available =
        session_channel.mutation_available(channel)
        && tui_model.queue_owner(model) == draft.owner
        && tui_model.queue_namespace(model) == draft.namespace
      case available {
        True ->
          outbound.send_frame(
            Model(
              ..model,
              pending_submission: Some(OverlaySubmission),
              queue_editor: queue_editor.State(
                ..model.queue_editor,
                draft: Some(
                  queue_editor.Draft(..draft, delivery: queue_editor.Saving),
                ),
                message: "Saving this revision…",
              ),
            ),
            protocol.edit_queued_input(
              model.next_id,
              draft.document,
              text_area.value(draft.input),
            ),
          )
        False ->
          Model(
            ..model,
            queue_editor: queue_editor.State(
              ..model.queue_editor,
              message: "Attachment changed or command lane is busy; draft retained",
            ),
          )
      }
    }
    _, _ -> model
  }
}

fn edit_queue_text(
  model: Model,
  edit: fn(text_area.TextAreaState) -> text_area.TextAreaState,
) -> Model {
  case model.queue_editor.draft {
    Some(draft) if draft.delivery == queue_editor.Editable ->
      Model(
        ..model,
        queue_editor: queue_editor.State(
          ..model.queue_editor,
          draft: Some(queue_editor.Draft(..draft, input: edit(draft.input))),
        ),
      )
    Some(_) | None -> model
  }
}

fn queue_text_key(
  key: keys.Key,
  input: text_area.TextAreaState,
) -> text_area.TextAreaState {
  case key {
    keys.Enter ->
      text_area.newline(
        text_area.textarea_new() |> text_area.with_max_lines(0),
        input,
      )
    keys.Backspace -> text_area.backspace(input)
    keys.Left -> text_area.move_cursor_left(input)
    keys.Right -> text_area.move_cursor_right(input)
    keys.Up -> text_area.move_cursor_up(input)
    keys.Down -> text_area.move_cursor_down(input)
    keys.Home | keys.Ctrl("a") -> text_area.move_to_line_start(input)
    keys.End | keys.Ctrl("e") -> text_area.move_to_line_end(input)
    keys.Char(value) ->
      text_area.insert_char(text_area.textarea_new(), input, value)
    _ -> input
  }
}

fn insert_queue_paste(
  input: text_area.TextAreaState,
  text: String,
) -> text_area.TextAreaState {
  list.fold(string.to_graphemes(text), input, fn(state, char) {
    case char {
      "\n" -> queue_text_key(keys.Enter, state)
      _ -> queue_text_key(keys.Char(char), state)
    }
  })
}

/// Opens current worktree inspection without changing composer ownership.
///
/// ## Examples
///
/// ```gleam
/// // tui.open_diff(model)
/// ```
@internal
pub fn open_diff(model: Model) -> Model {
  case layout.diff_shown(model) {
    True -> Model(..model, diff_view: DiffHidden)
    False ->
      refresh_worktree(
        Model(
          ..model,
          diff_view: DiffVisible,
          diff_scroll_offset: 0,
          help_open: False,
          notes_open: False,
        ),
      )
  }
  |> tui_model.invalidate_transcript
  |> tui_model.invalidate_frame
}

// Cuts and width transitions request at most one pending refresh. No timer or
// background Git loop is needed when the workspace and conversation are idle.
fn request_visible_worktree(model: Model) -> Model {
  case model.peer, layout.diff_shown(model) {
    Attached(_), True -> refresh_worktree(model)
    Attached(_), False | Preview, _ | Replaying, _ | Disconnected, _ -> model
  }
}

fn refresh_worktree(model: Model) -> Model {
  case model.peer, model.channel {
    Attached(_), Some(_) ->
      surfaces.service_worktree_read(
        Model(
          ..model,
          worktree: worktree_view.request(
            model.worktree,
            tui_model.queue_owner(model),
          ),
        ),
      )
    _, _ ->
      Model(
        ..model,
        worktree: worktree_view.new(),
        notice: "Captured edits · live worktree observation unavailable",
      )
  }
}

fn update_diff_key(key: keys.Key, model: Model) -> Model {
  case key {
    keys.Ctrl("c") -> quit(model)
    keys.Up -> select_diff_file(model, -1)
    keys.Down -> select_diff_file(model, 1)
    keys.Enter ->
      Model(
        ..model,
        worktree: worktree_view.State(
          ..model.worktree,
          focus: worktree_view.Composer,
        ),
      )
    keys.Char("r") -> refresh_worktree(model)
    keys.Escape ->
      Model(
        ..model,
        diff_view: DiffHidden,
        worktree: worktree_view.State(
          ..model.worktree,
          focus: worktree_view.Composer,
        ),
      )
    keys.PageUp -> scroll_diff(model, Older, layout.diff_patch_height(model))
    keys.PageDown -> scroll_diff(model, Newer, layout.diff_patch_height(model))
    _ -> model
  }
}

fn select_diff_file(model: Model, delta: Int) -> Model {
  let selected =
    int.clamp(
      model.worktree.selected + delta,
      0,
      list.length(worktree_view.labels(model.worktree)) - 1,
    )
  Model(
    ..model,
    worktree: worktree_view.State(..model.worktree, selected:),
    diff_scroll_offset: 0,
  )
  |> tui_model.invalidate_transcript
}

fn observe_completion(
  model: Model,
  cut: snapshot.Captured,
  view: snapshot_view.View,
  active: String,
) -> Model {
  let owner =
    tui_model.queue_owner(Model(..model, captured: Some(#(cut, view))))
  let previous = case model.completion_owner == owner {
    True -> model.completion
    False -> completion_summary.new()
  }
  let entries =
    list.filter_map(cut.window.items, fn(item) {
      case item {
        snapshot.Loaded(entry, _) -> Ok(entry)
        snapshot.Unloaded(..) -> Error(Nil)
      }
    })
  let completion = completion_summary.observe(previous, view.cells, entries)
  let changed =
    completion_summary.latest(previous, active)
    != completion_summary.latest(completion, active)
  Model(
    ..model,
    completion:,
    completion_owner: owner,
    worktree: case model.worktree.owner == owner {
      True -> model.worktree
      False -> worktree_view.new()
    },
    jobs: case model.completion_owner == owner {
      True -> model.jobs
      False -> None
    },
    jobs_awaiting: case model.completion_owner == owner {
      True -> model.jobs_awaiting
      False -> None
    },
    jobs_refresh: case changed {
      True -> worktree_view.Requested
      False -> model.jobs_refresh
    },
  )
}

fn retain_queue_selection(
  model: Model,
  view: snapshot_view.View,
  active: String,
) -> Model {
  let old =
    layout.queue_rows(model)
    |> list.drop(model.queue_editor.selected)
    |> list.first
  let rows =
    option.unwrap(view.pending_inputs, [])
    |> list.filter(fn(row) { row.strand == active })
  let selected = case old {
    Ok(row) ->
      rows
      |> list.index_map(fn(item, index) { #(item.id, index) })
      |> list.key_find(row.id)
      |> result.unwrap(0)
    Error(Nil) -> 0
  }
  let preview_scroll = case old {
    Ok(row) ->
      case list.first(list.drop(rows, selected)) {
        Ok(current) if current.id == row.id ->
          int.min(
            model.queue_editor.preview_scroll,
            queue_panel.max_scroll(
              rows,
              selected,
              layout.queue_preview_area_for(
                Model(
                  ..model,
                  queue_editor: queue_editor.State(
                    ..model.queue_editor,
                    selected:,
                  ),
                ),
                rows,
              ),
            ),
          )
        Ok(_) | Error(Nil) -> 0
      }
    Error(Nil) -> 0
  }
  Model(
    ..model,
    queue_editor: queue_editor.State(
      ..model.queue_editor,
      selected:,
      preview_scroll:,
    ),
  )
}

fn update_summary_key(key: keys.Key, model: Model) -> Model {
  let screen = layout.model_screen(model)
  let body = layout.summary_body_area(screen)
  let viewport = body.size.height
  let maximum =
    int.max(
      0,
      list.length(render.summary_lines(model, body.size.width)) - viewport,
    )
  let current = int.min(model.summary_scroll, maximum)
  case key {
    keys.Ctrl("c") -> quit(model)
    keys.Escape -> Model(..model, summary_surface: queue_editor.Closed)
    keys.Char("r") ->
      surfaces.service_jobs_read(
        Model(..model, jobs_refresh: worktree_view.Requested, summary_scroll: 0),
      )
    keys.Char("1") ->
      Model(..model, summary_tab: summary_panel.Completion, summary_scroll: 0)
    keys.Char("2") ->
      Model(..model, summary_tab: summary_panel.Usage, summary_scroll: 0)
    keys.Char("3") ->
      Model(..model, summary_tab: summary_panel.Jobs, summary_scroll: 0)
    keys.Char("[") -> select_summary_job(model, -1)
    keys.Char("]") -> select_summary_job(model, 1)
    keys.Up -> Model(..model, summary_scroll: int.max(0, current - 1))
    keys.Down -> Model(..model, summary_scroll: int.min(maximum, current + 1))
    keys.PageUp ->
      Model(..model, summary_scroll: int.max(0, current - viewport))
    keys.PageDown ->
      Model(..model, summary_scroll: int.min(maximum, current + viewport))
    _ -> model
  }
}

fn select_summary_job(model: Model, delta: Int) -> Model {
  case model.summary_tab, model.jobs {
    summary_panel.Jobs, Some(board) if board.strand == model.active_strand ->
      Model(
        ..model,
        summary_job_selected: int.clamp(
          model.summary_job_selected + delta,
          0,
          int.max(0, list.length(board.jobs) - 1),
        ),
        summary_scroll: 0,
      )
    summary_panel.Completion, _
    | summary_panel.Usage, _
    | summary_panel.Jobs, None
    | summary_panel.Jobs, Some(_)
    -> model
  }
}

fn apply_request_refused(
  model: Model,
  command: String,
  request_id: Int,
  code: String,
  message: String,
) -> Model {
  use <- bool.lazy_guard(command == "context", fn() {
    Model(
      ..model,
      context: context_view.refused(model.context, request_id, code, message),
    )
    |> tui_model.invalidate_frame
  })

  // Every goal command is refused worded and nowhere else: an older daemon
  // refuses all five, and an operator watching a panel fail to appear has
  // no way to tell that from a session with no goal.
  use <- bool.lazy_guard(string.starts_with(command, "goal_"), fn() {
    surfaces.refuse_goal(model, command, request_id, code, message)
  })
  let reason = code <> ": " <> message
  let updated = case command {
    "queued_input" | "edit_queued_input" ->
      case model.queue_editor.request_id == Some(request_id) {
        True ->
          Model(
            ..model,
            queue_editor: queue_editor.refused(model.queue_editor, reason),
          )
        False -> model
      }
    "live_jobs" ->
      case model.jobs_request == Some(request_id) {
        True ->
          Model(
            ..model,
            jobs_request: None,
            jobs_awaiting: None,
            jobs_notice: "Live jobs unavailable: " <> reason,
          )
        False -> model
      }

    // A refused observation draws nothing. The panel is unobtrusive context
    // beside the composer, and an error line there would cost a row of the
    // conversation to report a read the operator never asked for; an older
    // daemon that does not know the command refuses every one of them.
    "advisor_pending" ->
      case model.nudges_request == Some(request_id) {
        True ->
          Model(
            ..model,
            nudges: None,
            nudges_request: None,
            nudges_awaiting: None,
          )
        False -> model
      }
    "worktree_diff" ->
      Model(
        ..model,
        worktree: worktree_view.receive(
          model.worktree,
          tui_model.queue_owner(model),
          worktree_view.Failed(request_id, reason),
        ),
      )
    _ -> model
  }
  apply_event(updated, protocol.ServerError(code, message))
}

fn update_context_key(key: keys.Key, model: Model) -> Model {
  let state = model.context
  let viewport = layout.panel_inner(layout.model_screen(model)).size.height
  case key {
    keys.Ctrl("c") -> quit(model)
    keys.Escape ->
      Model(
        ..model,
        context: context_view.State(..state, surface: context_view.Hidden),
      )
    keys.Char("r") ->
      surfaces.service_context_read(
        Model(
          ..model,
          context: context_view.State(
            ..context_view.invalidate(state),
            scroll: 0,
          ),
        ),
      )
    keys.Char("a") ->
      Model(
        ..model,
        context: context_view.State(
          ..state,
          scroll: 0,
          surface: case state.surface {
            context_view.All -> context_view.Overview
            context_view.Overview | context_view.Hidden -> context_view.All
          },
        ),
      )
    keys.Up -> scroll_context(model, -1)
    keys.Down -> scroll_context(model, 1)
    keys.PageUp -> scroll_context(model, 0 - viewport)
    keys.PageDown -> scroll_context(model, viewport)
    _ -> model
  }
}

fn scroll_context(model: Model, delta: Int) -> Model {
  let inner = layout.panel_inner(layout.model_screen(model))
  let maximum =
    int.max(
      0,
      list.length(context_panel.lines(model.context, inner.size.width))
        - inner.size.height,
    )
  let current = int.min(model.context.scroll, maximum)
  Model(
    ..model,
    context: context_view.State(
      ..model.context,
      scroll: int.clamp(current + delta, 0, maximum),
    ),
  )
}
