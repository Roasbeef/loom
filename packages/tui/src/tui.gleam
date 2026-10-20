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
//// each event does lives in the modules under `tui/` and, for the session's
//// half of it, in `session_view`, which form a strict import order because
//// Gleam forbids cycles and none of them may import this one. The shared
//// step is in `session_view`: `session_view/model` holds the session state,
//// `session_view/outbound` sends command frames, `session_view/surfaces`
//// services the side-surface reads, `session_view/event_fold` and
//// `session_view/lane_fold` fold pushed events and lane updates,
//// `session_view/commands` carries out an operator's commands, and
//// `session_view/transcript_lines` builds transcript lines. The terminal's
//// half is under `tui/`: `tui/model` holds the `Model` record, its `View`
//// and the binding of the shared record's handles; `tui/layout` computes
//// screen geometry and `tui/render` paints it; `tui/inbound` runs the loop
//// over the lane's updates and applies what each recorded for the
//// terminal's surfaces; `tui/session_control` runs daemon control
//// requests; `tui/projection` maintains the transcript row caches;
//// `tui/submit` handles composer submission; `tui/interaction` handles keys,
//// pastes and the mouse; and `tui/tick` drains the inboxes on each tick.
////
//// The split is also a compile-time measure. Gleam compiles every module
//// with the Erlang inliner, which never attempts a call into another
//// module, so a long chain of steps applied to an expensive expression is
//// only a hazard inside one module. `docs/execution.md` §8 has the history.
////
//// ## Flow
////
//// `main` → `parse_launch` → `interactive` → `update` → `step` → `reduce` → `settle_update`
////
//// 1. `main` answers help first (`help_for`), peels `--record` off the arguments,
////    and lets `parse_launch` classify what is left into a `Launch`.
//// 2. Launches that are not a terminal (version, update, ext, distribution,
////    `replay`, sessions, claim, enroll, access, view) run to completion in
////    their own functions. `loom sessions list` is `list_registrations`, which
////    ends with the other orchestrators' sessions unless `--local` is given,
////    and `loom sessions elsewhere` is `elsewhere_registrations`.
//// 3. `interactive_terminal` refuses a detached stdin, then `interactive` builds
////    the model with `new_model` and connects it: `attach_daemon` for a local
////    daemon, `connect_remote` for a remote address.
//// 4. `interactive` opens the recording, starts the Herdr reporter and hands
////    `update`, `render.view` and the quit test to etui's loop.
//// 5. `update` turns one input into a message and calls `step`, which admits
////    arrivals or sends an input through `reduce`.
//// 6. `reduce` starts the step, dispatches the event in `apply_input`, and
////    `settle_update` finishes what every event shares before the effects are
////    taken for the loop to perform.

import argv
import core/accounting
import core/json
import etui/app
import etui/backend
import etui/backend/default
import etui/buffer
import etui/geometry
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
import gleam/time/calendar
import gleam/time/duration
import host/bootstrap as host_bootstrap
import host/build_identity
import host/claim as claim_token
import host/endpoint
import host/login
import session_view/advisor_history
import session_view/agent_roster
import session_view/attempt
import session_view/attempt_replay
import session_view/block_summary
import session_view/btw
import session_view/cache_watch
import session_view/completion_summary
import session_view/connection_event
import session_view/context_view
import session_view/generation_rate
import session_view/history_view
import session_view/model.{
  Disconnected, HoldGoalReport, Preview, Replaying, Shared,
} as session_model
import session_view/move_candidates
import session_view/msg as session_msg
import session_view/queue_request
import session_view/remote_transcript
import session_view/session_channel
import session_view/shared_set
import session_view/step as session_step
import session_view/text_hygiene
import session_view/transcript_line.{
  Assistant, Line, Reasoning, System, ToolResult,
}
import session_view/worktree_view
import tui/access as access_command
import tui/admission
import tui/agent_strip
import tui/appearance
import tui/attachment
import tui/bootstrap
import tui/buffered
import tui/claim
import tui/connection
import tui/daemon
import tui/daemon/protocol as control_protocol
import tui/daemon/selection as daemon_selection
import tui/demo_image
import tui/deployment_view
import tui/device_code
import tui/directory_view
import tui/effect
import tui/elsewhere_view
import tui/frame
import tui/image_plan
import tui/image_shown
import tui/image_support
import tui/inbound
import tui/interaction
import tui/internal/ffi_terminal
import tui/job
import tui/job_runner
import tui/layout
import tui/layout_save
import tui/model.{
  type Model, DiffHidden, Model, Newer, NoClipboard, NoOverlay, Older,
  PromptNext, ReconnectIdle, TerminalClipboard,
} as tui_model
import tui/msg
import tui/note_panel
import tui/pacing
import tui/placement
import tui/projection
import tui/queue_editor
import tui/recording
import tui/render
import tui/runtime
import tui/session_control
import tui/session_table
import tui/submit
import tui/summary_panel
import tui/tick
import tui/update
import tui/update/download
import tui/update/options as update_options
import tui/view_link
import tui/view_set
import tui/virtual_backend
import tui/workspace

type Launch {
  // Build reporting reads launcher metadata without opening a terminal or daemon.
  Version

  Demo
  Local(bootstrap.Options, selected: String)

  // `loom ui --session <id>` prints a link that opens the session's web
  // view (protocol-change/051), an observer's page unless `--operate` asks
  // for an operator's, and with `--open` also opens it. It installs no
  // terminal state. `--ui` anywhere in argv is the older spelling of the
  // same command.
  View(request: ViewRequest)
  Remote(address: String, session: String, token: String)
  Invalid(reason: String)

  // `loom ext …`, `loom distribution …` (`dist` for short) and
  // `loom executor …` are not
  // terminal applications at all: they are passthroughs to `loomd`, whose
  // own subcommand owns every verb. Forwarding rather than reimplementing
  // is what stops the launcher and the server disagreeing about what an
  // install did, or about which certificate a provisioned node holds. The
  // `verb` is the server subcommand, spelled the way the server spells it.
  Forward(verb: String, arguments: List(String))

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
  Replay(
    path: String,
    frames: FrameSelection,
    size: backend.TerminalSize,
    colour: Colour,
  )

  // `loom claim …` and `loom enroll …` are the invitee's side of an owner's
  // invitation (protocol-change/053). Neither installs terminal state; claim
  // opens one short socket to `/v2/claim`, and enroll opens none.
  ClaimAccess(arguments: List(String))
  Enroll(arguments: List(String))

  // `loom access …` is the owner's side: the same commands as `loomd access`,
  // from the client shipment, against the local daemon or, with `--addr` and
  // `--token-file`, a remote one. It installs no terminal state either.
  Access(arguments: List(String))

  // `loom sessions …` installs no terminal state either. It reaches the
  // control endpoint as the owner over the same bootstrap ladder the picker
  // uses, prints one line per row or one line of outcome, and exits with a
  // status. Listing and deleting are the two things the picker could do that
  // a person with no terminal open still needs.
  Sessions(options: bootstrap.Options, command: SessionsCommand)

  // `loom deployment …` reads the machines the daemon is configured with
  // (protocol-change/085). It is the same kind of command as `sessions`: no
  // terminal state, one control connection as the owner, and one printed
  // answer or one failure with an exit status.
  Deployment(options: bootstrap.Options, command: DeploymentCommand)

  // `loom directory status` reads the session directory's cluster view from the
  // daemon (protocol-change/083). It is the same kind of command as `deployment`:
  // no terminal state, one control connection as the owner, and one printed
  // answer or one failure with an exit status.
  Directory(options: bootstrap.Options, output: Output)
}

// The two catalogue verbs the launcher owns. `rm` carries its consent so the
// parser settles the question and the runner never re-derives it from flags.
// `list` carries its own `Showing` for the same reason: the parser is the
// one place `--all` is read, so the runner never re-derives the question
// from flags either.
@internal
pub type SessionsCommand {
  ListRegistrations(showing: Showing, reach: Reach)
  RemoveRegistration(session_id: String, consent: Consent)

  // Hands a session to the orchestrator the daemon's `[orchestrators.<name>]`
  // table calls `to` (protocol-change/078, phase 5).
  MoveRegistration(session_id: String, to: String)

  // Says which orchestrators could take a session, for `move` given no
  // destination (protocol-change/085, the addendum on Move and Abandon). It
  // moves nothing and exits nonzero, since the command the person meant has not
  // run.
  ListDestinations(session_id: String)

  // Gives up the move of a session now, with `--abandon`. Only a directory
  // member accepts it.
  AbandonRegistration(session_id: String)

  // Reads the sessions the daemon's other orchestrators list, a page of each,
  // or with a key and a cursor the next page of one (protocol-change/085).
  ListElsewhere(
    orchestrator: Option(String),
    after: Option(String),
    output: Output,
  )
}

/// Whose sessions `loom sessions list` prints.
@internal
pub type Reach {
  /// The daemon's own, followed by the sessions its other orchestrators list.
  AllOrchestrators

  /// The daemon's own and nothing else, which is what `--local` selects and
  /// what a script that parses the lines wants.
  ThisDaemonOnly
}

/// The two views of `deployment.status` the launcher prints.
@internal
pub type DeploymentCommand {
  /// The verdict, the nodes and the links among them, or with a `node` the one
  /// configured node that key names and its long lists.
  ShowDeployment(node: Option(String), output: Output)

  /// The executors and pools a session may be created on, with their states.
  ShowExecutors(output: Output)
}

/// How a deployment view is printed.
@internal
pub type Output {
  /// The table, drawn by `tui/deployment_view`.
  AsText

  /// The daemon's reply body as it sent it, for a script.
  AsJson
}

// Whether the person has already agreed to lose a conversation. `--yes` is
// the whole of the second variant; without it the runner asks, and refuses
// when there is no terminal to ask.
@internal
pub type Consent {
  AskAtTerminal
  GivenOnCommandLine
}

/// Which rows `loom sessions list` prints.
///
/// The resident track is the daemon's active catalogue: a runtime that is
/// up, one starting or stopping, and a stuck cleanup all belong to it,
/// because each still occupies the daemon rather than sitting idle. A
/// saved registration and a bare reservation are the idle remainder, and
/// stay out of the default view until `--all` asks for the whole
/// catalogue.
@internal
pub type Showing {
  ResidentOnly
  Every
}

// Which of a replay's frames to print. A recording produces one frame per
// event, and the interesting one is almost always the last, so that is the
// default rather than a flag.
type FrameSelection {
  LastFrame
  FrameAt(index: Int)
  AllFrames
}

// Whether one-shot output keeps the colour its frame was drawn with. The
// default follows the terminal: a person watching gets the styled frame, and
// a pipe, a file, or a golden-file comparison gets plain text with no escape
// sequences. `--plain` forces the second for a terminal that cannot show the
// first.
type Colour {
  FollowTerminal
  PlainText
}

// The replay flags, gathered before a Launch is built so an unparseable
// combination is one Invalid rather than a half-applied set.
type ReplayOptions {
  ReplayOptions(frames: FrameSelection, width: Int, height: Int, colour: Colour)
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
        | ["distribution", ..]
        | ["dist", ..]
        | ["executor", ..]
        | ["replay", ..]
        | ["sessions", ..]
        | ["deployment", ..]
        | ["directory", ..]
        | ["claim", ..]
        | ["enroll", ..]
        | ["access", ..]
        | ["ui", ..]
        | ["--ui", ..]
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
        Forward(verb:, arguments:) -> forward(verb, arguments)
        Update(arguments:) -> run_update(arguments)
        Replay(path:, frames:, size:, colour:) ->
          replay(path, frames, size, colour)
        Sessions(options:, command:) -> run_sessions(options, command)
        Deployment(options:, command:) -> run_deployment(options, command)
        Directory(options:, output:) -> run_directory(options, output)
        ClaimAccess(arguments:) -> claim.claim_main(arguments)
        Enroll(arguments:) -> claim.enroll_main(arguments)
        Access(arguments:) -> access_command.main(arguments)
        View(request:) -> run_view(request)
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
      case arguments {
        // `access` is a topic only in first position, or after `help`. It is
        // also a plausible session name or principal display name, so
        // finding it anywhere would steal `--help` from another command.
        ["access", ..] | ["help", "access", ..] -> Some(access_command.usage())
        _ -> help_topic(arguments)
      }
  }
}

fn help_topic(arguments: List(String)) -> Option(String) {
  case list.find(arguments, is_topic) {
    Ok("replay") -> Some(replay_usage())
    Ok("sessions") -> Some(sessions_usage())
    Ok("deployment") -> Some(deployment_usage())
    Ok("directory") -> Some(directory_usage())
    Ok("claim") | Ok("enroll") -> Some(claim.usage)
    Ok("ext") -> Some(extension_usage())
    Ok("distribution") | Ok("dist") -> Some(distribution_usage())
    Ok("executor") -> Some(executor_usage())
    Ok("update") -> Some(update_options.usage())
    Ok("version") -> Some(version_usage())
    Ok("ui") | Ok("--ui") -> Some(ui_usage())
    Ok(_other) | Error(Nil) -> Some(launch_usage())
  }
}

fn is_topic(word: String) -> Bool {
  case word {
    "replay"
    | "sessions"
    | "deployment"
    | "directory"
    | "ext"
    | "distribution"
    | "dist"
    | "executor"
    | "update"
    | "version"
    | "claim"
    | "enroll"
    | "ui"
    | "--ui" -> True
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
fn forward(verb: String, arguments: List(String)) -> Nil {
  case bootstrap.server_executable(flag_or_empty(arguments, "--server")) {
    Error(reason) -> {
      io.println_error("loom " <> verb <> ": " <> reason)
      ffi_terminal.halt(1)
      Nil
    }
    Ok(server) ->
      case ffi_terminal.run_forwarding(server, [verb, ..arguments]) {
        Ok(status) -> {
          ffi_terminal.halt(status)
          Nil
        }
        Error(reason) -> {
          io.println_error(
            "loom " <> verb <> ": could not run " <> server <> ": " <> reason,
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
  inbox: Subject(connection_event.Message),
  project: workspace.Context,
) -> Model {
  let model =
    new_model_with_clock(inbox, project, host_bootstrap.monotonic_time_ms)

  // The reader's zone is read once, when the terminal starts, so a message's
  // heading can show the local time it arrived. A model built for a test
  // keeps no offset and draws no times, which keeps its frames the same in
  // every zone.
  let offset =
    calendar.local_offset()
    |> duration.to_seconds_and_nanoseconds
    |> fn(pair) { pair.0 / 60 }
  Model(..model, shared: shared_set.clock_offset(model.shared, Some(offset)))
}

/// Creates a presentation state whose timing is controlled by its caller.
///
/// The clock seeds the first frame and measures every later presentation
/// interval in the same era. A test may advance it between events without
/// sleeping. Network and bootstrap deadlines retain their real clocks.
///
/// The model starts stamped with one reading of each clock, so a reducer
/// driven before the first event, or a test that calls `step` directly,
/// runs at the time the model was created.
///
/// ## Examples
///
/// ```gleam
/// let model = tui.new_model_with_clock(inbox, project, fn() { -10_000 })
/// assert model.last_frame_ms == -10_000
/// ```
@internal
pub fn new_model_with_clock(
  inbox: Subject(connection_event.Message),
  project: workspace.Context,
  monotonic_time_ms: fn() -> Int,
) -> Model {
  let strands = interaction.demo_strands()
  let stamp =
    runtime.read_stamp(monotonic_time_ms, host_bootstrap.monotonic_time_ms)
  Model(
    shared: Shared(
      clock_offset: None,
      quit: False,
      parked_scrollback: dict.new(),
      attachments: [],
      returned_drafts: [],
      pending_submission: None,
      drafts_sent: 0,
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
      cache: cache_watch.new(),
      cache_notices: [],
      scrollback: history_view.empty(),
      notice: "interactive design preview",
      answer: "",
      worktree: worktree_view.new(),
      context: context_view.new(),
      peek: remote_transcript.Closed,
      btw: btw.new(),
      completion: completion_summary.new(),
      completion_owner: "",
      jobs: None,
      jobs_observed_ms: None,
      jobs_refresh: worktree_view.Settled,
      jobs_awaiting: None,
      jobs_request: None,
      jobs_notice: "Live jobs unavailable; /summary requests a current observation",
      remembered: None,
      remembered_refresh: worktree_view.Settled,
      proposals: None,
      proposals_refresh: worktree_view.Settled,
      proposals_notice: "",
      memory: None,
      memory_refresh: worktree_view.Settled,
      memory_notice: "",
      memory_read_ms: None,
      memory_watch: session_model.NotWatchingMemory,
      nudges: None,
      nudges_refresh: worktree_view.Settled,
      nudges_awaiting: None,
      nudges_request: None,
      summaries: block_summary.new(),
      goal: None,
      goal_refresh: worktree_view.Settled,
      goal_awaiting: None,
      goal_request: None,
      goal_report: HoldGoalReport,
      goal_observations: [],
      note_board: None,
      notes_requested: None,
      queue_request: queue_request.new(),
      queue_notices: [],
      surface_facts: [],
      models: interaction.demo_models(),
      skills: [],
      current_model: "baseten-kimi-k3",
      strands:,
      reviewer_rows: [],
      agent_rows: [],
      roster: agent_roster.new(),
      agent_messages: [],
      advisor_history: advisor_history.Board(items: [], unloaded: None),
      todo_boards: dict.new(),
      todo_seed: None,
      todo_asked: set.new(),
      active_strand: "main",
      session: "demo",
      session_label: None,
      inbox: buffered.new(inbox),
      peer: Preview,
      ended: None,
      channel: None,
      captured: None,
      last_capture: session_channel.Requested,
      notices: 0,
      approvals: [],
      unconfirmed: None,
      replay_state: attempt_replay.new(),
      replay_inbox: buffered.new(process.new_subject()),
      replay_error: None,
      next_id: 1,
      usage: accounting.zero_usage(),
      remote_usage: [],
      generation_rates: generation_rate.new(),
      details_expanded: False,
      activity_started_ms: None,
      generation_elapsed_s: 0,
      activity_elapsed_s: 0,
      streams: [],
      tool_tails: [],
      render_revision: 0,
      compact_call_cache: dict.new(),
      compact_entry_cache: dict.new(),
      pending_records: [],
      record_cache_valid: False,
      frame_revision: 0,
      stamp:,
      build_notice: [],
      activity_revision: 0,
      connection_backlog: session_model.MailboxDrained,
      recorder: None,
      record_cache_epoch: 0,
      outbox: [],
    ),
    view: tui_model.View(
      width: 80,
      height: 24,
      palette: appearance.Dark,
      image_support: image_support.TextOnly(image_support.NotProbed),
      images: image_shown.new(),
      layout_target: None,
      input: text_area.state_new(),
      strand_workspaces: dict.new(),
      restored_workspace: None,
      history: [],
      history_index: 0,
      history_draft: "",
      command_selected: 0,
      submission_mode: PromptNext,
      cache_outlook: "",
      queue_editor: queue_editor.new(),
      summary_surface: queue_editor.Closed,
      summary_scroll: 0,
      summary_tab: summary_panel.Completion,
      summary_job_selected: 0,
      help_open: False,
      notes_open: False,
      diff_view: DiffHidden,
      diff_scroll_offset: 0,
      diff_row_count: 0,
      diff_worktree_source: #(None, 0),
      note_selected: None,
      note_mode: note_panel.Readable,
      note_scroll: 0,
      overlay: NoOverlay,
      strip_focus: agent_strip.Composing,
      local_options: None,
      launch_note: None,
      workspace: project,
      candidate: attachment.idle(),
      daemon_host: None,
      client_build: build_identity.current(),
      control_request: None,
      activity_poll: tui_model.ActivityDue,
      reconnect: ReconnectIdle,
      creation_key: None,
      configuring: None,
      opening_image: None,
      prompted_approvals: [],
      inspecting_approval: None,
      next_attempt: 1,
      rail: None,
      rail_tab: None,
      sheet: tui_model.SheetClosed,
      rail_focus: tui_model.FocusComposer,
      rail_scroll: 0,
      repaint_phase: False,
      activity_frame: 0,
      reading_lines: None,
      scroll_offset: 0,
      rendered_revision: -1,
      rendered_row_count: 0,
      revealed_rows: 0,
      rendered_anchors: [],
      rendered_gutters: [],
      record_gutters: [],
      record_cache_width: 0,
      record_cache_height: 0,
      record_cache_strand: "",
      record_cache_details: False,
      frame_debt: pacing.FrameSettled,
      monotonic_time_ms:,
      transport_time_ms: host_bootstrap.monotonic_time_ms,
      terminal: runtime.terminal_identity(),
      wall_ms: host_bootstrap.system_time_ms(),
      last_frame_ms: stamp.now_ms,
      quiet_for_ms: pacing.quiet_after_ms,
      herdr_reporter: None,
      herdr_published: None,
      outbox: [],
      next_job: job.first(),
      running: job_runner.new(),
      selection: None,
      selection_gutters: [],
      clipboard: NoClipboard,
      caches: tui_model.empty_caches(),
    ),
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
    Version
    | Forward(..)
    | Update(..)
    | Replay(..)
    | Sessions(..)
    | Deployment(..)
    | Directory(..)
    | ClaimAccess(..)
    | Enroll(..)
    | Access(..)
    | View(..) -> base

    // The demo has no session, so the one image it shows is seeded into its
    // entries (`demo_image`), where a box finds the data to draw.
    Demo -> demo_image.seed(base)
    Local(options, selected) -> {
      // The footer names the workspace the session was launched for, which
      // is only the current directory when no `--workspace` was given; a
      // later `/sessions` switch derives it the same way from its choice.
      let local =
        Model(
          ..base,
          view: base.view
            |> view_set.local_options(Some(options))
            |> view_set.workspace(case options.placement, options.workspace {
              // A registered name is no directory here, so it is never probed
              // for a repository: the footer shows the name as given.
              placement.OnExecutor(workspace: name, ..), _
              | placement.InPool(workspace: name, ..), _
              -> workspace.Context(path: name, branch: None)
              placement.OnThisHost, "" -> base.view.workspace
              placement.OnThisHost, path -> workspace.discover_from(path)
            }),
        )
      case bootstrap.resolve_daemon(options, process.self(), 90_000) {
        Error(reason) ->
          tui_model.append_error(
            Model(
              ..local,
              shared: local.shared
                |> shared_set.peer(Disconnected)
                |> shared_set.notice("daemon startup failed"),
            ),
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
      tui_model.append_error(
        Model(..base, shared: shared_set.notice(base.shared, "invalid launch")),
        reason,
      )
    Remote(address, session, token) ->
      connect_remote(base, inbox, address, session, token)
  }

  // Only here does a copy reach a terminal: every other way of running the
  // loop shares stdout with something that is not one.
  let initial =
    open_recording(
      Model(
        ..launched,
        view: tui_model.View(
          ..launched.view,
          clipboard: TerminalClipboard,
          palette: appearance.detect(
            host_bootstrap.getenv("COLORTERM") |> result.unwrap(""),
            host_bootstrap.getenv("TERM") |> result.unwrap(""),
            host_bootstrap.getenv("COLORFGBG") |> result.unwrap(""),
            host_bootstrap.getenv("NO_COLOR") |> option.from_result,
          ),
        ),
      ),
      record,
    )
    |> start_herdr_reporter_for(launch)

  // Only a launch that is a real session remembers its layout. The rest
  // print and exit, replay, or show the demo, and read and write no file.
  let initial = case launch {
    Local(options, _) ->
      layout_save.remember_launch(initial, options.state_directory)
    Remote(..) -> layout_save.remember_launch(initial, "")
    Version
    | Forward(..)
    | Update(..)
    | Replay(..)
    | Sessions(..)
    | Deployment(..)
    | Directory(..)
    | ClaimAccess(..)
    | Enroll(..)
    | Access(..)
    | View(..)
    | Demo
    | Invalid(..) -> initial
  }

  // The probe has to run in this process, because it leaves the terminal in
  // raw mode for the backend that follows, and before that backend enters
  // the alternate screen, because its replies are read raw and must not be
  // drawn. It is the last thing before the loop so that nothing printed
  // earlier can be mistaken for a reply, and the plain-palette rule is
  // applied first, inside `probe_terminal`.
  let initial =
    Model(
      ..initial,
      view: tui_model.View(
        ..initial.view,
        image_support: image_support.probe_terminal(
          initial.view.palette,
          host_bootstrap.getenv,
        ),
      ),
    )
  let _ =
    app.run_buffered_cursor_adaptive(
      default.new_with_options(backend.Options(mouse: True, paste: True)),
      initial,
      render.view,
      update,
      fn(model) { model.shared.quit },
      tick.terminal_poll_timeout,
    )
  Nil
}

// The demo launch never reports to a Herdr pane. Its model carries the
// placeholder session "demo" with live demo strands, so a reporter would
// publish a state for a session that does not exist and, worse, a resume
// command Herdr 0.9.2+ would actuate after a server restart, replaying
// `loom --session demo` into a pane that opens nothing. Every other
// launch names a real session or none at all.
fn start_herdr_reporter_for(model: Model, launch: Launch) -> Model {
  case launch {
    Demo -> model
    _ -> tick.start_herdr_reporter(model)
  }
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
    should_quit: fn(model: Model) { model.shared.quit },
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
            shared: model.shared
              |> shared_set.recorder(Some(recorder))
              |> shared_set.notice("recording"),
            view: view_set.candidate(
              model.view,
              attachment.with_trace(
                model.view.candidate,
                recording.trace(
                  Some(recorder),
                  attempt.Id(model.view.next_attempt - 1),
                ),
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
  parse_words(hoist_daemon_options(arguments))
}

// The daemon options a subcommand shares with a local launch, written before
// the subcommand: `loom --server X sessions list` means the same as `loom
// sessions list --server X`. The subcommand parsers read their options after
// the verb, so the leading pairs are moved behind it here, once, and no parser
// learns a second spelling. Only the subcommands whose usage lists the options
// take them this way; a launch, and the forwarded verbs that own their own
// flags, are left exactly as written. A flag with no value, or one that looks
// like the next flag, ends the leading run, so the subcommand parser then
// reports it the way it does for the trailing spelling.
fn hoist_daemon_options(arguments: List(String)) -> List(String) {
  let #(leading, rest) = leading_daemon_options(arguments, [])
  case leading, rest {
    [], _ -> arguments
    _, [verb, ..after] ->
      case list.contains(["sessions", "deployment", "directory", "ui"], verb) {
        True -> list.flatten([[verb], after, leading])
        False -> arguments
      }
    _, [] -> arguments
  }
}

fn leading_daemon_options(
  arguments: List(String),
  taken: List(String),
) -> #(List(String), List(String)) {
  case arguments {
    [flag, value, ..rest]
      if flag == "--server" || flag == "--state-dir" || flag == "--config"
    ->
      case string.starts_with(value, "-") {
        True -> #(list.reverse(taken), arguments)
        False -> leading_daemon_options(rest, [value, flag, ..taken])
      }
    _ -> #(list.reverse(taken), arguments)
  }
}

fn parse_words(arguments: List(String)) -> Launch {
  case arguments {
    [] -> Local(default_bootstrap_options(), "")
    ["--demo"] -> Demo
    ["version"] | ["--version"] -> Version
    ["version", ..] | ["--version", ..] -> Invalid(version_usage())
    ["ext", ..rest] -> Forward(verb: "ext", arguments: rest)
    ["distribution", ..rest] | ["dist", ..rest] -> forward_distribution(rest)
    ["executor", ..rest] -> Forward(verb: "executor", arguments: rest)
    ["update", ..rest] -> Update(arguments: rest)
    ["help", "ext"] -> Forward(verb: "ext", arguments: ["--help"])
    ["help", "distribution"] | ["help", "dist"] ->
      Forward(verb: "distribution", arguments: ["--help"])
    ["help", "executor"] -> Forward(verb: "executor", arguments: ["--help"])
    ["replay", ..rest] -> parse_replay(rest)
    ["ui", ..rest] -> view_launch(rest)
    ["sessions", ..rest] -> parse_sessions(rest)
    ["deployment", ..rest] -> parse_deployment(rest)
    ["directory", ..rest] -> parse_directory(rest)
    ["claim", ..rest] -> ClaimAccess(arguments: rest)
    ["enroll", ..rest] -> Enroll(arguments: rest)
    ["access", ..rest] -> Access(arguments: rest)

    // `--ui` is the web view command's older spelling, kept so existing
    // scripts keep working. It is looked for anywhere rather than only first,
    // because the daemon options it shares with a local launch are as likely
    // to be written before it as after; a first-position match is what made
    // `loom --state-dir X --ui --session Z` a refused local launch.
    _ ->
      case take_switch(arguments, "--ui") {
        #(True, rest) -> view_launch(rest)
        #(False, _) -> parse_terminal_launch(arguments)
      }
  }
}

// The web view command, from the words that follow `ui` or that remain once
// `--ui` is taken out. Both spellings reach this one parser, so they accept
// the same options in the same orders.
fn view_launch(arguments: List(String)) -> Launch {
  case view_request(arguments) {
    Ok(request) -> View(request:)
    Error(reason) -> Invalid(reason)
  }
}

/// Classifies a whole argument vector as the launcher does, answering the
/// web view request when it names one and the refusal otherwise. It is the
/// test seam for the routing in front of `view_request`: which spellings
/// reach it, and that options before `--ui` are still read.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(request) = tui.launch_view(["ui", "--session", "s"])
/// assert request.session == "s"
/// let assert Error(_) = tui.launch_view(["--demo"])
/// ```
@internal
pub fn launch_view(arguments: List(String)) -> Result(ViewRequest, String) {
  case parse_launch(arguments) {
    View(request:) -> Ok(request)
    Invalid(reason) -> Error(reason)
    _other -> Error("not a web view launch")
  }
}

/// Classifies a terminal launch's words the way the launcher does, answering the
/// local options it parsed (`--workspace`, `--server`, `--state-dir`, `--config`
/// and `--model-profile`) or the refusal. It is the test seam for those flags.
/// The launcher's own `--profile` (BEAM profiling) is a different flag, consumed
/// before the application starts, so the model profile has its own spelling.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(options) = tui.launch_options(["--model-profile", "deepseek"])
/// assert options.profile == "deepseek"
/// ```
@internal
pub fn launch_options(
  arguments: List(String),
) -> Result(bootstrap.Options, String) {
  case parse_launch(arguments) {
    Local(options, _) -> Ok(options)
    Invalid(reason) -> Error(reason)
    _other -> Error("not a terminal launch")
  }
}

/// Classifies the words after `loom sessions` the way the launcher does,
/// answering the parsed command when they name one and the refusal
/// otherwise. It is the test seam for `--all`, `--yes`, and the shared
/// local options, none of which the runner re-parses once this has settled
/// them onto the command.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(tui.ListRegistrations(tui.Every, tui.AllOrchestrators)) =
///   tui.launch_sessions(["list", "--all"])
/// let assert Ok(tui.ListRegistrations(tui.ResidentOnly, tui.ThisDaemonOnly)) =
///   tui.launch_sessions(["list", "--local"])
/// ```
@internal
pub fn launch_sessions(
  arguments: List(String),
) -> Result(SessionsCommand, String) {
  case parse_launch(["sessions", ..arguments]) {
    Sessions(command:, ..) -> Ok(command)
    Invalid(reason) -> Error(reason)
    _other -> Error("not a sessions launch")
  }
}

/// Classifies a whole argument vector that names a `sessions`, `deployment` or
/// `directory` command, answering the daemon options it settled on or the
/// refusal. It is the test seam for the options written before the verb.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(options) =
///   tui.launch_daemon_options(["--server", "/bin/loomd", "sessions", "list"])
/// assert options.server == "/bin/loomd"
/// ```
@internal
pub fn launch_daemon_options(
  arguments: List(String),
) -> Result(bootstrap.Options, String) {
  case parse_launch(arguments) {
    Sessions(options:, ..)
    | Deployment(options:, ..)
    | Directory(options:, ..) -> Ok(options)
    Invalid(reason) -> Error(reason)
    _other -> Error("not a daemon command launch")
  }
}

// An interactive launch: a remote session when `--addr` is given, otherwise
// a local one over the bootstrap ladder.
fn parse_terminal_launch(arguments: List(String)) -> Launch {
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
      case parse_local_launch(arguments, result.unwrap(selection, "")) {
        Ok(local) -> local
        Error(reason) -> Invalid(reason <> "\n" <> launch_usage())
      }
  }
}

// A local terminal launch: the shared local options, and the placement that
// `--executor` or `--pool` and `--workspace` name together. They are read here
// and not by `parse_local_options`, so `loom ui` and `loom sessions`, which have
// no session to create, refuse them as the unknown options they are for them.
// With an executor or a pool the `--workspace` value is a registered name and
// not a directory, so it is taken out of the words before the options parser
// can store it as one: the launcher canonicalizes `Options.workspace`, and a
// name must never reach that.
fn parse_local_launch(
  arguments: List(String),
  selected: String,
) -> Result(Launch, String) {
  use #(executor, rest) <- result.try(take_value(arguments, "--executor"))
  use #(pool, rest) <- result.try(take_value(rest, "--pool"))
  use #(registered, rest) <- result.try(case option.or(executor, pool) {
    Some(_) -> take_value(rest, "--workspace")
    None -> Ok(#(None, rest))
  })
  use Nil <- result.try(case option.or(executor, pool), selected {
    Some(_), "" | None, _ -> Ok(Nil)
    Some(_), _ ->
      Error(
        "--executor and --pool name where a new session is created; --session opens an existing one",
      )
  })
  use chosen <- result.try(placement.new(executor, pool, registered))
  use options <- result.map(parse_local_options(
    rest,
    default_bootstrap_options(),
  ))
  Local(bootstrap.Options(..options, placement: chosen), selected)
}

// Removes one `flag value` pair from the words and answers the value, or none
// when the flag is absent. A flag given twice, or last with no value, or whose
// value looks like the next flag, is refused rather than guessed at.
fn take_value(
  arguments: List(String),
  flag: String,
) -> Result(#(Option(String), List(String)), String) {
  case list.count(arguments, fn(word) { word == flag }) {
    0 -> Ok(#(None, arguments))
    1 ->
      case session_control.flag_value(arguments, flag) {
        Ok(value) ->
          case string.starts_with(value, "-") {
            True -> Error(flag <> " needs a value, got " <> value)
            False -> Ok(#(Some(value), without_flag(arguments, flag)))
          }
        Error(Nil) -> Error("missing value for " <> flag)
      }
    _ -> Error(flag <> " was given more than once")
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
    ["list", ..flags] -> {
      let #(all, remaining) = take_switch(flags, "--all")
      let showing = case all {
        True -> Every
        False -> ResidentOnly
      }
      let #(local, remaining) = take_switch(remaining, "--local")
      let reach = case local {
        True -> ThisDaemonOnly
        False -> AllOrchestrators
      }
      sessions_launch(remaining, ListRegistrations(showing, reach))
    }
    ["elsewhere", ..flags] -> parse_elsewhere(flags)
    ["rm", id, ..flags] ->
      sessions_launch(flags, RemoveRegistration(id, consent))
    ["rm"] -> Invalid("sessions rm needs a session id\n" <> sessions_usage())
    ["move", id, ..flags] -> parse_move(id, flags)
    ["move"] ->
      Invalid("sessions move needs a session id\n" <> sessions_usage())
    _unknown -> Invalid(sessions_usage())
  }
}

// `loom sessions elsewhere [--orchestrator <key> [--after <id>]] [--json]`. A
// cursor follows one orchestrator's rows, so it is refused without the key it
// belongs to, and the key is checked against the grammar of a configuration key
// here, before any daemon is started or asked.
fn parse_elsewhere(arguments: List(String)) -> Launch {
  let #(as_json, rest) = take_switch(arguments, "--json")
  let output = case as_json {
    True -> AsJson
    False -> AsText
  }
  let parsed = {
    use #(key, rest) <- result.try(take_value(rest, "--orchestrator"))
    use #(after, rest) <- result.try(take_value(rest, "--after"))
    use Nil <- result.map(elsewhere_names(key, after))
    #(key, after, rest)
  }
  case parsed {
    Error(reason) -> Invalid(reason <> "\n" <> sessions_usage())
    Ok(#(key, after, flags)) ->
      sessions_launch(flags, ListElsewhere(key, after, output))
  }
}

fn elsewhere_names(
  key: Option(String),
  after: Option(String),
) -> Result(Nil, String) {
  case key, after {
    None, Some(_) -> Error("--after needs --orchestrator")
    None, None -> Ok(Nil)
    Some(name), _ ->
      case placement.is_orchestrator_name(name) {
        True -> Ok(Nil)
        False ->
          Error(
            "--orchestrator must be the name of an orchestrator in the daemon's configuration, got "
            <> name,
          )
      }
  }
}

// `loom sessions move <id> --to <orchestrator>`. The destination is required and
// is a name from the daemon's configuration, not an address, so it is refused here
// if it is not the shape of one, before any daemon is started or asked.
fn parse_move(id: String, flags: List(String)) -> Launch {
  let #(abandoning, flags) = take_switch(flags, "--abandon")
  case abandoning, take_value(flags, "--to") {
    _, Error(reason) -> Invalid(reason <> "\n" <> sessions_usage())
    True, Ok(#(Some(_), _)) ->
      Invalid(
        "--abandon and --to cannot be used together\n" <> sessions_usage(),
      )
    True, Ok(#(None, rest)) -> sessions_launch(rest, AbandonRegistration(id))

    // With no destination the command moves nothing: it says which
    // orchestrators could take the session.
    False, Ok(#(None, rest)) -> sessions_launch(rest, ListDestinations(id))
    False, Ok(#(Some(to), rest)) ->
      case placement.is_orchestrator_name(to) {
        True -> sessions_launch(rest, MoveRegistration(id, to))
        False ->
          Invalid(
            "--to must be the name of an orchestrator in the daemon's configuration, got "
            <> to
            <> "\n"
            <> sessions_usage(),
          )
      }
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
  "usage: loom sessions list [--all] [--local] [--state-dir <path>] [--server <path>]\n"
  <> "       loom sessions elsewhere [--orchestrator <key> [--after <session-id>]] [--json]\n"
  <> "       loom sessions rm <session-id> [--yes] [--state-dir <path>]\n"
  <> "       loom sessions move <session-id> [--to <orchestrator> | --abandon] [--state-dir <path>]\n"
  <> "  list shows the resident track by default; --all adds every saved\n"
  <> "  registration and reservation. When the daemon has other orchestrators it\n"
  <> "  ends with the sessions they list, one section for each, and says so when\n"
  <> "  one did not answer; --local leaves that section out, which a script that\n"
  <> "  parses the lines wants\n"
  <> "  elsewhere shows only those sessions: a page of each orchestrator, or with\n"
  <> "  --orchestrator the next page of one, after the last session you saw\n"
  <> "  resident: running in the daemon now\n"
  <> "  saved: has a database, not running; opens when selected\n"
  <> "  reserved: a creation that never finished, an id with no database\n"
  <> "  behind it; retry the create or remove it\n"
  <> "  rm asks for confirmation unless --yes is given, and refuses a\n"
  <> "  session the daemon still holds open; stop it first\n"
  <> "  move hands a session on an executor to the orchestrator the daemon's\n"
  <> "  [orchestrators.<name>] table calls <orchestrator>. It returns once the\n"
  <> "  daemon has accepted the move, which it then carries out; the session\n"
  <> "  cannot be opened here until the move ends, and afterward it is opened on\n"
  <> "  the other orchestrator. Without --to it moves nothing and lists which\n"
  <> "  orchestrators could take the session and why the others cannot, and exits\n"
  <> "  nonzero. --abandon gives up a move in flight, on a directory member only;\n"
  <> "  if the receiver has already taken the session the move finishes instead"
}

// `loom deployment status [--node <key>]|executors [--json]` and the shared
// local options. `--json` is a switch and may stand anywhere after the verb, like
// `--yes` for `sessions`, so it is taken before the shared options are parsed.
// `--node` takes the next word and is read before them for the same reason; the
// key is checked against the grammar of a configuration key here, and whether it
// names anything is the daemon's configuration to say.
fn parse_deployment(arguments: List(String)) -> Launch {
  let #(as_json, rest) = take_switch(arguments, "--json")
  let output = case as_json {
    True -> AsJson
    False -> AsText
  }
  let named_one = list.contains(rest, "--node")
  let #(key, rest) = take_flag(rest, "--node")
  let node = case named_one, placement.is_orchestrator_name(key) {
    False, _ -> Ok(None)
    True, True -> Ok(Some(key))
    True, False -> Error("--node takes a key of [executors] or [orchestrators]")
  }
  case rest, node {
    _, Error(reason) -> Invalid(reason <> "\n" <> deployment_usage())
    ["status", ..flags], Ok(node) ->
      deployment_launch(flags, ShowDeployment(node:, output:))
    ["executors", ..flags], Ok(None) ->
      deployment_launch(flags, ShowExecutors(output))
    ["executors", ..], Ok(Some(_)) ->
      Invalid("--node applies to status only\n" <> deployment_usage())
    _, Ok(_) -> Invalid(deployment_usage())
  }
}

fn deployment_launch(
  flags: List(String),
  command: DeploymentCommand,
) -> Launch {
  case parse_local_options(flags, default_bootstrap_options()) {
    Ok(options) -> Deployment(options:, command:)
    Error(reason) -> Invalid(reason <> "\n" <> deployment_usage())
  }
}

fn deployment_usage() -> String {
  "usage: loom deployment status [--node <key>] [--json] [--state-dir <path>] [--server <path>]\n"
  <> "       loom deployment executors [--json] [--state-dir <path>] [--server <path>]\n"
  <> "  status shows which of the machines in the daemon's [executors.<name>]\n"
  <> "  and [orchestrators.<name>] tables it can reach, what each says of itself,\n"
  <> "  and the links between it and each. Every statement is from the daemon\n"
  <> "  you are connected to: a node is ok when that daemon connected to it just\n"
  <> "  now and received its report, degraded when the report names a reason, and\n"
  <> "  down when it did not, with a one-word reason\n"
  <> "  --node <key> reads one node, named by its [executors.<name>] or\n"
  <> "  [orchestrators.<name>] key, and adds its workspaces, the scopes that need\n"
  <> "  a release and its moves\n"
  <> "  executors shows the executors and pools a session may be created on,\n"
  <> "  with the state of each, so a choice can be made before the session is\n"
  <> "  created; it does not stop you from choosing one that is down\n"
  <> "  --json prints the daemon's reply as it was sent"
}

// `loom directory status [--json]` and the shared local options.
fn parse_directory(arguments: List(String)) -> Launch {
  let #(as_json, rest) = take_switch(arguments, "--json")
  let output = case as_json {
    True -> AsJson
    False -> AsText
  }
  case rest {
    ["status", ..flags] ->
      case parse_local_options(flags, default_bootstrap_options()) {
        Ok(options) -> Directory(options:, output:)
        Error(reason) -> Invalid(reason <> "\n" <> directory_usage())
      }
    _unknown -> Invalid(directory_usage())
  }
}

fn directory_usage() -> String {
  "usage: loom directory status [--json] [--state-dir <path>] [--server <path>]\n"
  <> "  status shows the session directory's cluster as the daemon you are\n"
  <> "  connected to sees it: its members, which of them vote, the leader and\n"
  <> "  the last log index this member has applied. It is answered only by a\n"
  <> "  daemon that is a directory member\n"
  <> "  --json prints the daemon's reply as it was sent"
}

/// Classifies the words after `loom deployment` the way the launcher does,
/// answering the parsed command when they name one and the refusal otherwise.
/// It is the test seam for the verbs and `--json`, which the runner does not
/// re-parse once this has settled them onto the command.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(tui.ShowDeployment(None, tui.AsJson)) =
///   tui.launch_deployment(["status", "--json"])
/// let assert Ok(tui.ShowExecutors(tui.AsText)) =
///   tui.launch_deployment(["executors"])
/// ```
@internal
pub fn launch_deployment(
  arguments: List(String),
) -> Result(DeploymentCommand, String) {
  case parse_launch(["deployment", ..arguments]) {
    Deployment(command:, ..) -> Ok(command)
    Invalid(reason) -> Error(reason)
    Version
    | Demo
    | Local(..)
    | View(..)
    | Remote(..)
    | Forward(..)
    | Update(..)
    | Replay(..)
    | ClaimAccess(..)
    | Enroll(..)
    | Access(..)
    | Directory(..)
    | Sessions(..) -> Error("not a deployment launch")
  }
}

/// Classifies the words after `loom directory` the way the launcher does,
/// answering how the reply is to be printed when they name `status` and the
/// refusal otherwise. It is the test seam for the verb and `--json`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(tui.AsJson) = tui.launch_directory(["status", "--json"])
/// let assert Error(_) = tui.launch_directory([])
/// ```
@internal
pub fn launch_directory(arguments: List(String)) -> Result(Output, String) {
  case parse_launch(["directory", ..arguments]) {
    Directory(output:, ..) -> Ok(output)
    Invalid(reason) -> Error(reason)
    Version
    | Demo
    | Local(..)
    | View(..)
    | Remote(..)
    | Forward(..)
    | Update(..)
    | Replay(..)
    | ClaimAccess(..)
    | Enroll(..)
    | Access(..)
    | Deployment(..)
    | Sessions(..) -> Error("not a directory launch")
  }
}

// One deployment read over a control connection this process owns for the
// length of the command, printed the way a sessions command prints.
fn run_deployment(
  options: bootstrap.Options,
  command: DeploymentCommand,
) -> Nil {
  case sessions_host(options) {
    Error(reason) -> command_failed("deployment", reason)
    Ok(#(control, host)) -> {
      let node = case command {
        ShowDeployment(node:, ..) -> node
        ShowExecutors(..) -> None
      }
      let outcome =
        daemon_selection.deployment(host, node)
        |> result.try(format_deployment(_, command))
      daemon.close(control)
      print_outcome("deployment", outcome)
    }
  }
}

// One directory read over a control connection this process owns for the length
// of the command.
fn run_directory(options: bootstrap.Options, output: Output) -> Nil {
  case sessions_host(options) {
    Error(reason) -> command_failed("directory", reason)
    Ok(#(control, host)) -> {
      let outcome =
        daemon_selection.directory(host)
        |> result.try(format_directory(_, output))
      daemon.close(control)
      print_outcome("directory", outcome)
    }
  }
}

/// Renders a `directory.status` reply body: the daemon's own document for
/// `--json`, and for text the table `tui/directory_view` draws. A body that is
/// not shaped as the protocol says is an `Error` naming what was wrong, and is
/// never drawn partly.
///
/// ## Examples
///
/// ```gleam
/// let assert Error(_) = tui.format_directory(json.Object([]), tui.AsText)
/// ```
@internal
pub fn format_directory(
  document: json.JsonValue,
  output: Output,
) -> Result(String, String) {
  case output {
    AsJson -> Ok(json.to_string(document))
    AsText ->
      directory_view.decode(document)
      |> result.map(directory_view.status_text)
      |> result.map_error(fn(reason) {
        "the daemon's directory reply was not understood: "
        <> text_hygiene.single_line(reason)
      })
  }
}

/// Renders a `deployment.status` reply body for one command: the daemon's own
/// document for `--json`, and for text the table `tui/deployment_view` draws.
/// A body that is not shaped as the protocol says is an `Error` naming what was
/// wrong, and is never drawn partly.
///
/// ## Examples
///
/// ```gleam
/// let assert Error(_) =
///   tui.format_deployment(json.Object([]), tui.ShowDeployment(None, tui.AsText))
/// ```
@internal
pub fn format_deployment(
  document: json.JsonValue,
  command: DeploymentCommand,
) -> Result(String, String) {
  case command {
    ShowDeployment(output: AsJson, ..) | ShowExecutors(output: AsJson) ->
      Ok(json.to_string(document))
    ShowDeployment(output: AsText, ..) ->
      deployment_view.decode(document)
      |> result.map(deployment_view.status_text)
      |> result.map_error(unreadable_deployment)
    ShowExecutors(output: AsText) ->
      deployment_view.decode(document)
      |> result.map(deployment_view.executors_text)
      |> result.map_error(unreadable_deployment)
  }
}

fn unreadable_deployment(reason: String) -> String {
  "the daemon's deployment reply was not understood: "
  <> text_hygiene.single_line(reason)
}

/// What `loom ui` was asked for: the daemon options, the session to link
/// (`None` for the home page, protocol-change/065), which page to link, which
/// origin the link is built on, which ticket it carries, and whether to open
/// the link as well as print it.
@internal
pub type ViewRequest {
  ViewRequest(
    options: bootstrap.Options,
    session: Option(String),
    page: control_protocol.WebPage,
    /// Whether the home's exchange also sets a browser login, which
    /// `--no-remember` declines (protocol-change/065).
    remember: control_protocol.Remembering,
    delivery: view_link.Delivery,
    /// The origin the printed link starts with: the loopback listener, or one
    /// of the daemon's listed `https` origins (protocol-change/052).
    origin: LinkOrigin,
    /// Which ticket the link carries: a page's sixty-second ticket, or a
    /// device link's ten-minute one (`--device`).
    ticket: LinkTicket,
  )
}

/// The origin a `loom ui` link is built on.
@internal
pub type LinkOrigin {
  /// The daemon's loopback listener over `http`, for a browser on this
  /// machine. The default.
  LoopbackOrigin

  /// One of the `https` origins the daemon's `hello` lists from `[daemon]
  /// ui_origins`: the one `--origin` named, or, with `None`, the only one
  /// listed. A link for another machine reaches the daemon through the
  /// proxy that serves that origin.
  ListedOrigin(asked: Option(String))
}

/// The ticket a `loom ui` link carries.
@internal
pub type LinkTicket {
  /// The page's own ticket, redeemable for sixty seconds.
  PageTicket

  /// A device link (`--device`): the home's ticket, redeemable for ten
  /// minutes and always setting a browser login, printed with a QR code
  /// for a phone to scan.
  DeviceTicket
}

/// Parses the words after `loom ui` (or what is left of argv once `--ui`
/// is taken out): an optional `--session <id>`, an optional `--operate` or
/// `--observe`, an optional `--no-remember`, an optional `--open`, and the shared local options
/// `--state-dir`, `--config`, `--server` and `--workspace`, in any order.
///
/// With no `--session` the request is for the home page, which is a link for
/// oneself and so an operator's page unless `--observe` asks for a read-only
/// one. With `--session` it is that session's page, which is the link a
/// person hands to someone else and so is read-only unless `--operate` asks
/// for an operator's. In both the daemon still caps the page with the
/// principal's membership. `--operate` and `--observe` together are refused.
///
/// The switches are taken out first because they have no value, and the local
/// option parser reads its arguments in flag-and-value pairs.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(request) = tui.view_request(["--session", "s", "--open"])
/// assert request.delivery == view_link.OpenInBrowser
/// assert request.page == control_protocol.ObserverPage
/// let assert Ok(home) = tui.view_request(["--open"])
/// assert home.session == None
/// assert home.page == control_protocol.OperatorPage
/// ```
@internal
pub fn view_request(arguments: List(String)) -> Result(ViewRequest, String) {
  let #(operate, arguments) = take_switch(arguments, "--operate")
  let #(observe, arguments) = take_switch(arguments, "--observe")
  let #(forget, arguments) = take_switch(arguments, "--no-remember")
  let #(device, arguments) = take_switch(arguments, "--device")
  let #(open, rest) = take_switch(arguments, "--open")
  let delivery = case open {
    True -> view_link.OpenInBrowser
    False -> view_link.PrintLink
  }
  use session <- result.try(view_session(rest))
  use asked <- result.try(view_origin(rest))
  use remember <- result.try(case session, forget {
    Some(_), True ->
      Error(
        "--no-remember applies to the home page, which no --session names\n"
        <> ui_usage(),
      )
    None, True -> Ok(control_protocol.Forget)
    _, False -> Ok(control_protocol.Remember)
  })

  // A device link signs a browser in to the home, so it names no session and
  // cannot decline the login. It is for another machine, so it is built on a
  // listed origin even when `--origin` does not name one.
  use #(origin, ticket) <- result.try(case device, session, forget, asked {
    True, Some(_), _, _ ->
      Error(
        "--device signs another device in to your home page, which no "
        <> "--session names\n"
        <> ui_usage(),
      )
    True, None, True, _ ->
      Error(
        "--device always signs the device in, so it takes no --no-remember\n"
        <> ui_usage(),
      )
    True, None, False, _ -> Ok(#(ListedOrigin(asked), DeviceTicket))
    False, _, _, Some(_) -> Ok(#(ListedOrigin(asked), PageTicket))
    False, _, _, None -> Ok(#(LoopbackOrigin, PageTicket))
  })
  let asked = case operate, observe {
    True, True -> AskedBoth
    True, False -> AskedOperator
    False, True -> AskedObserver
    False, False -> AskedNeither
  }
  use page <- result.try(view_page(session, asked))
  case
    parse_local_options(
      without_flag(without_flag(rest, "--session"), "--origin"),
      default_bootstrap_options(),
    )
  {
    Ok(options) ->
      Ok(ViewRequest(
        options:,
        session:,
        page:,
        remember:,
        delivery:,
        origin:,
        ticket:,
      ))
    Error(reason) -> Error(reason <> "\n" <> ui_usage())
  }
}

// The origin `--origin` names, or none. A `--origin` with no value after it
// is an error, so a forgotten origin never falls back to loopback.
fn view_origin(arguments: List(String)) -> Result(Option(String), String) {
  case list.contains(arguments, "--origin") {
    False -> Ok(None)
    True ->
      session_control.flag_value(arguments, "--origin")
      |> result.map(Some)
      |> result.map_error(fn(_) {
        "loom ui needs an origin after --origin, such as "
        <> "https://box.example.ts.net:8443\n"
        <> ui_usage()
      })
  }
}

/// The listed origin a link is built on, from the origins the daemon's
/// `hello` lists and the one `--origin` asked for (protocol-change/052).
///
/// With none listed it refuses and names the configuration key, since the
/// daemon would refuse the link's `Host` anyway. With one listed and none
/// asked, that one. With several and none asked, it refuses and lists them.
/// An asked origin is compared after the daemon's own normalization, the
/// scheme and host lowercased and a trailing `/` and the default `:443`
/// dropped, and must be listed.
///
/// ## Examples
///
/// ```gleam
/// assert tui.listed_origin(["https://box.example:8443"], None)
///   == Ok("https://box.example:8443")
/// let assert Error(_) = tui.listed_origin([], None)
/// ```
@internal
pub fn listed_origin(
  listed: List(String),
  asked: Option(String),
) -> Result(String, String) {
  case listed, asked {
    [], _ ->
      Error(
        "the daemon lists no web view origin for another machine. Add the "
        <> "https origin your proxy serves, such as "
        <> "https://box.example.ts.net:8443, to ui_origins in the [daemon] "
        <> "table of the daemon's loom.toml and restart the daemon.",
      )
    [only], None -> Ok(only)
    [_, _, ..], None ->
      Error(
        "the daemon lists several web view origins ("
        <> string.join(listed, ", ")
        <> "); pick one with --origin.",
      )
    _, Some(wanted) -> {
      let wanted = normalized_origin(wanted)
      list.find(listed, fn(origin) { origin == wanted })
      |> result.map_error(fn(_) {
        "the daemon does not list "
        <> wanted
        <> " as a web view origin; it lists "
        <> string.join(listed, ", ")
        <> "."
      })
    }
  }
}

// The daemon's normalization of an origin (`client/daemon/ui_origin`), so
// `--origin HTTPS://Box.example:443/` finds the listed `https://box.example`.
fn normalized_origin(origin: String) -> String {
  let origin = string.lowercase(origin)
  let origin = case string.ends_with(origin, "/") {
    True -> string.drop_end(origin, 1)
    False -> origin
  }
  case string.ends_with(origin, ":443") {
    True -> string.drop_end(origin, 4)
    False -> origin
  }
}

// The session `--session` names, or none for the home. A `--session` with no
// value after it is an error, so a forgotten id is never read as a request
// for the home.
fn view_session(arguments: List(String)) -> Result(Option(String), String) {
  case list.contains(arguments, "--session") {
    False -> Ok(None)
    True ->
      session_control.flag_value(arguments, "--session")
      |> result.map(Some)
      |> result.map_error(fn(_) {
        "loom ui needs a session id after --session\n" <> ui_usage()
      })
  }
}

// Which of the two ceiling switches `loom ui` was given.
type PageAsked {
  AskedOperator
  AskedObserver
  AskedBoth
  AskedNeither
}

// The page's ceiling: the home is an operator's page unless `--observe`, and a
// session's an observer's unless `--operate`, as `view_request` says why.
fn view_page(
  session: Option(String),
  asked: PageAsked,
) -> Result(control_protocol.WebPage, String) {
  case asked, session {
    AskedBoth, _ ->
      Error("loom ui takes --operate or --observe, not both\n" <> ui_usage())
    AskedOperator, _ | AskedNeither, None -> Ok(control_protocol.OperatorPage)
    AskedObserver, _ | AskedNeither, Some(_) ->
      Ok(control_protocol.ObserverPage)
  }
}

fn without_flag(arguments: List(String), flag: String) -> List(String) {
  case arguments {
    [] -> []
    [name, _value, ..rest] if name == flag -> without_flag(rest, flag)
    [name, ..rest] -> [name, ..without_flag(rest, flag)]
  }
}

// Resolves the daemon (starting it with `--ui` when none runs), refuses a
// running daemon that does not serve the view, opens the session if it is
// not resident (a home link names none), and prints the link its `ui.link`
// returns. It never stops
// or relaunches a running daemon: other people's terminals may be on it.
//
// Once the link is minted the command succeeds whatever the opener does.
// The link is printed before any opener runs, and the ticket in it is
// written nowhere but standard output and the opener's argument vector.
fn run_view(request: ViewRequest) -> Nil {
  let ViewRequest(
    options:,
    session:,
    page:,
    remember:,
    delivery:,
    origin: asked_origin,
    ticket:,
  ) = request
  let outcome = {
    use connected <- result.try(bootstrap.resolve_viewing_daemon(
      options,
      process.self(),
      90_000,
    ))
    let control = connected.control
    let linked = {
      let view = daemon.hello(control).view
      use Nil <- result.try(view_served(view))

      // The origin is chosen before anything is minted, so a link for an
      // origin the daemon does not list is refused without spending a
      // ticket.
      use origin <- result.try(case asked_origin {
        LoopbackOrigin -> web_origin(connected.record)
        ListedOrigin(asked) -> listed_origin(view_origins(view), asked)
      })
      use host <- result.try(view_host(
        connected.record,
        connected.paths.token,
        control,
      ))
      use Nil <- result.try(opened_for_link(host, session))
      let command = case ticket {
        PageTicket -> control_protocol.UiLink(session, page, remember)
        DeviceTicket -> control_protocol.UiDeviceLink(page)
      }
      use reply <- result.try(
        daemon.request(control, command, 5000)
        |> result.map_error(daemon_selection.failure),
      )
      case reply {
        control_protocol.UiLinkReply(path:, expires_in_ms:) ->
          Ok(#(origin <> path, expires_in_ms))
        _other -> Error("ui.link returned an unexpected control reply")
      }
    }
    daemon.close(control)
    linked
  }
  case outcome {
    Ok(#(link, expires_in_ms)) -> {
      view_link.deliver(
        link,
        delivery,
        view_link.system_opener(),
        print_view_output,
      )
      case ticket {
        PageTicket -> Nil
        DeviceTicket -> print_device_code(link, expires_in_ms)
      }
    }
    Error(reason) -> {
      io.println_error("loom ui: " <> reason)
      ffi_terminal.halt(1)
      Nil
    }
  }
}

// The listed origins a running daemon's `hello` names, which only a daemon
// that serves the view can name.
fn view_origins(view: control_protocol.WebView) -> List(String) {
  case view {
    control_protocol.WebViewAt(origins:, ..) -> origins
    control_protocol.NoWebView -> []
  }
}

// A device link's QR code and how long it lasts, on standard error: the link
// on standard output stays the command's one line for a script, and the code
// is for the person holding a phone up to this terminal.
fn print_device_code(link: String, expires_in_ms: Int) -> Nil {
  case device_code.render(link) {
    Ok(code) -> io.println_error(code)
    Error(Nil) ->
      io.println_error("loom ui: the link is too long for a QR code")
  }
  io.println_error(
    "loom ui: open the link on the other device within "
    <> device_lifetime(expires_in_ms)
    <> "; it signs that browser in to your home page for 30 days.",
  )
}

/// How long a device link lasts, in the words `loom ui --device` prints:
/// whole minutes when it lasts a minute or more, seconds otherwise. A daemon
/// that predates device links mints its sixty-second home ticket instead, and
/// this is how the person learns that.
///
/// ## Examples
///
/// ```gleam
/// assert tui.device_lifetime(600_000) == "10 minutes"
/// assert tui.device_lifetime(30_000) == "30 seconds"
/// ```
@internal
pub fn device_lifetime(expires_in_ms: Int) -> String {
  let seconds = expires_in_ms / 1000
  case seconds >= 60 {
    True ->
      case seconds / 60 {
        1 -> "1 minute"
        minutes -> int.to_string(minutes) <> " minutes"
      }
    False -> int.to_string(seconds) <> " seconds"
  }
}

// A session's link needs the session to be resident, so it is opened first. The
// home is bound to no session and opens none.
fn opened_for_link(host, session: Option(String)) -> Result(Nil, String) {
  case session {
    None -> Ok(Nil)
    Some(id) -> daemon_selection.open(host, id) |> result.replace(Nil)
  }
}

// The link is the command's output, so it is the first line of standard
// output, where a script can take it; a note about the opener is a
// diagnostic. With `--open` the opener's own output is forwarded to
// standard output after the link, so a script wants the first line only.
fn print_view_output(output: view_link.Output) -> Nil {
  case output {
    view_link.Link(link) -> io.println(link)
    view_link.Note(note) -> io.println_error("loom ui: " <> note)
  }
}

/// Whether a running daemon serves the web view, and what to tell the
/// operator when it does not.
///
/// ## Examples
///
/// ```gleam
/// assert view_served(control_protocol.WebViewAt("/ui", [])) == Ok(Nil)
/// ```
@internal
pub fn view_served(view: control_protocol.WebView) -> Result(Nil, String) {
  case view {
    control_protocol.WebViewAt(..) -> Ok(Nil)
    control_protocol.NoWebView ->
      Error(
        "the running daemon was started without --ui. Stop it and run "
        <> "loom ui again to start one that serves the web view. It was "
        <> "left running because other terminals may be attached to it.",
      )
  }
}

// The page's origin: the listener's loopback address over http.
fn web_origin(record: endpoint.Endpoint) -> Result(String, String) {
  case record {
    endpoint.Ready(host: "::1", port:, ..) ->
      Ok("http://[::1]:" <> int.to_string(port))
    endpoint.Ready(host:, port:, ..) ->
      Ok("http://" <> host <> ":" <> int.to_string(port))
    endpoint.Starting(..) -> Error("the daemon has not published its address")
  }
}

fn view_host(record: endpoint.Endpoint, token_file: String, control) {
  use address <- result.try(endpoint.address(record))
  use bytes <- result.try(host_bootstrap.read_private_bounded(token_file, 65))
  use token <- result.try(
    bit_array.to_string(bytes)
    |> result.replace_error("invalid owner credential encoding"),
  )
  daemon_selection.host(control, address, string.trim(token))
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
        ListRegistrations(showing:, reach:) ->
          list_registrations(host, showing, reach)
        ListElsewhere(orchestrator:, after:, output:) ->
          elsewhere_registrations(host, orchestrator, after, output)
        RemoveRegistration(session_id:, consent:) ->
          remove_registration(host, session_id, consent)
        MoveRegistration(session_id:, to:) ->
          move_registration(host, session_id, to)
        ListDestinations(session_id:) -> list_destinations(host, session_id)
        AbandonRegistration(session_id:) ->
          abandon_registration(host, session_id)
      }
      daemon.close(control)
      print_outcome("sessions", outcome)
    }
  }
}

fn sessions_failed(reason: String) -> Nil {
  command_failed("sessions", reason)
}

// The one place a launcher subcommand's answer leaves the process: a report is
// one printed answer, and a failure is one line on standard error naming the
// subcommand and a nonzero exit status. `sessions` and `deployment` share it so
// that a script sees the same contract from both.
fn print_outcome(verb: String, outcome: Result(String, String)) -> Nil {
  case outcome {
    Ok(report) -> io.println(report)
    Error(reason) -> command_failed(verb, reason)
  }
}

fn command_failed(verb: String, reason: String) -> Nil {
  io.println_error("loom " <> verb <> ": " <> reason)
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

// A terminal gets the aligned, coloured table; anything else gets the one
// line per row that scripts already parse, byte for byte as before. The
// default view narrows both to the resident track; `--all` widens either
// back to the whole catalogue.
fn list_registrations(
  host: daemon_selection.Host,
  showing: Showing,
  reach: Reach,
) -> Result(String, String) {
  use rows <- result.map(registration_rows(host, "", [], 100))
  let listing = format_listing(rows, showing, ffi_terminal.require_terminal())
  case reach {
    ThisDaemonOnly -> listing
    AllOrchestrators -> listing <> other_orchestrators(host)
  }
}

// The section the other orchestrators add to a listing: nothing for a daemon
// that has none to ask or predates the command, a blank line and the section
// when it has, and a line saying so when the read failed, because the listing
// above it is still true and a missing section would read as "none".
fn other_orchestrators(host: daemon_selection.Host) -> String {
  case daemon_selection.elsewhere(host, None, None) {
    Error(daemon_selection.NoElsewhereViews) -> ""
    Error(daemon_selection.ElsewhereFailed(reason)) ->
      "\n\nother orchestrators were not read: "
      <> text_hygiene.single_line(reason)
    Ok(document) ->
      case elsewhere_view.decode(document) {
        Ok([]) -> ""
        Ok(groups) -> "\n\n" <> elsewhere_view.section_text(groups)
        Error(reason) ->
          "\n\nother orchestrators were not read: "
          <> text_hygiene.single_line(reason)
      }
  }
}

// One read of the other orchestrators' sessions, printed as text or as the
// daemon's reply body.
fn elsewhere_registrations(
  host: daemon_selection.Host,
  orchestrator: Option(String),
  after: Option(String),
  output: Output,
) -> Result(String, String) {
  use document <- result.try(
    daemon_selection.elsewhere(host, orchestrator, after)
    |> result.map_error(fn(failure) {
      case failure {
        daemon_selection.NoElsewhereViews ->
          "this daemon does not have views of other orchestrators"
        daemon_selection.ElsewhereFailed(reason) -> reason
      }
    }),
  )
  format_elsewhere(document, output)
}

/// Renders a `sessions.elsewhere` reply body: the daemon's own document for
/// `--json`, and for text the section `tui/elsewhere_view` draws. A body that is
/// not shaped as the protocol says is an `Error` naming what was wrong, and is
/// never drawn partly.
///
/// ## Examples
///
/// ```gleam
/// let assert Error(_) = tui.format_elsewhere(json.Object([]), tui.AsText)
/// ```
@internal
pub fn format_elsewhere(
  document: json.JsonValue,
  output: Output,
) -> Result(String, String) {
  case output {
    AsJson -> Ok(json.to_string(document))
    AsText ->
      elsewhere_view.decode(document)
      |> result.map(elsewhere_view.section_text)
      |> result.map_error(fn(reason) {
        "the daemon's reply about other orchestrators was not understood: "
        <> text_hygiene.single_line(reason)
      })
  }
}

/// Renders `loom sessions list` exactly as it would print, given the
/// daemon's full page of rows, which of them to show, and whether standard
/// output is a terminal.
///
/// Kept apart from `list_registrations` so the formatting — the filter, the
/// hidden-count note, and the plain fallback — can be exercised without a
/// daemon to list from.
///
/// ## Examples
///
/// ```gleam
/// let rows = [session_row(control_protocol.Saved)]
/// assert tui.format_listing(rows, tui.ResidentOnly, Error("not a tty"))
///   == "no sessions"
/// ```
@internal
pub fn format_listing(
  rows: List(control_protocol.Session),
  showing: Showing,
  terminal: Result(Nil, String),
) -> String {
  let visible = visible_rows(rows, showing)
  case terminal {
    Error(_) -> plain_listing(visible)
    Ok(Nil) -> terminal_listing(visible, rows, showing)
  }
}

// The rows a `Showing` keeps. `Every` is the identity; `ResidentOnly` drops
// exactly the two lifecycles `session_table.resident_track` calls idle.
fn visible_rows(
  rows: List(control_protocol.Session),
  showing: Showing,
) -> List(control_protocol.Session) {
  case showing {
    Every -> rows
    ResidentOnly ->
      list.filter(rows, fn(row) { session_table.resident_track(row.status) })
  }
}

// The plain, script-parsed format: one line per visible row, byte for byte
// as before. No hidden-count note here — a line a parser was not expecting
// would break it, and a script that wants every row already has `--all`.
fn plain_listing(visible: List(control_protocol.Session)) -> String {
  case visible {
    [] -> "no sessions"
    rows -> string.join(list.map(rows, registration_line), "\n")
  }
}

// The styled, terminal format: the table (or an empty-catalogue notice),
// followed by the hidden-count note when `--all` would add rows.
fn terminal_listing(
  visible: List(control_protocol.Session),
  all_rows: List(control_protocol.Session),
  showing: Showing,
) -> String {
  let body = case visible {
    [] -> empty_notice(showing)
    rows -> frame.buffer_to_styled(session_table.render(rows))
  }
  case hidden_summary(all_rows, showing) {
    "" -> body
    summary -> body <> "\n" <> summary
  }
}

fn empty_notice(showing: Showing) -> String {
  case showing {
    Every -> "no sessions"
    ResidentOnly -> "no resident sessions"
  }
}

// The two lifecycles `--all` alone reveals: a saved registration and a bare
// reservation. Naming each by its own count, rather than one combined
// figure, is what lets a person tell stale history apart from a stuck
// creation without reaching for `--all` first.
fn hidden_summary(
  rows: List(control_protocol.Session),
  showing: Showing,
) -> String {
  case showing {
    Every -> ""
    ResidentOnly -> {
      let saved =
        list.count(rows, fn(row) { row.status == control_protocol.Saved })
      let reserved =
        list.count(rows, fn(row) { row.status == control_protocol.Reserved })
      case
        list.filter_map(
          [#(saved, "saved"), #(reserved, "reserved")],
          hidden_word,
        )
      {
        [] -> ""
        parts -> string.join(parts, ", ") <> " not shown (use --all)"
      }
    }
  }
}

fn hidden_word(count: #(Int, String)) -> Result(String, Nil) {
  case count.0 {
    0 -> Error(Nil)
    n -> Ok(int.to_string(n) <> " " <> count.1)
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
  <> session_table.state_token(row.status)
  <> "  "
  <> placement.label(row.executor, row.workspace)
  <> "  "
  <> text_hygiene.single_line(row.name)
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

fn move_registration(
  host: daemon_selection.Host,
  session_id: String,
  to: String,
) -> Result(String, String) {
  use #(op, destination) <- result.map(daemon_selection.move(
    host,
    session_id,
    to,
  ))
  "moving "
  <> session_id
  <> " to "
  <> destination
  <> " (operation "
  <> op
  <> ")"
}

// `move` given no destination. It reads the session's executor and the
// deployment, judges each configured orchestrator by the rule the web home
// uses, and fails with the list, since the move the person meant has not run.
// A session with no executor has nowhere to go, and says so.
fn list_destinations(
  host: daemon_selection.Host,
  session_id: String,
) -> Result(String, String) {
  use executor <- result.try(daemon_selection.executor_of(host, session_id))
  use document <- result.try(daemon_selection.deployment(host, None))
  use found <- result.try(deployment_view.candidates(document, executor))
  case executor {
    None -> Error(session_id <> ": " <> move_candidates.no_executor_words())
    Some(_) ->
      Error(
        "choose a destination with --to\n"
        <> deployment_view.candidates_text(session_id, found),
      )
  }
}

fn abandon_registration(
  host: daemon_selection.Host,
  session_id: String,
) -> Result(String, String) {
  use op <- result.map(daemon_selection.abandon(host, session_id))
  "giving up the move of "
  <> session_id
  <> " (operation "
  <> op
  <> "); if the receiver has taken the session, the move finishes instead"
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
  bootstrap.Options("", "", "", "", "", "", placement.OnThisHost)
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
        "--model-profile" ->
          case string.starts_with(value, "-") {
            // A value that looks like the next flag is a forgotten name, and
            // taking it would swallow that flag.
            True -> Error("--model-profile needs a profile name, got " <> value)
            False ->
              parse_local_options(
                rest,
                bootstrap.Options(..options, profile: value),
              )
          }
        _ -> Error("unknown local launch option " <> flag)
      }
  }
}

/// The bearer a remote launch presents, from `--token-file` or `--token`.
///
/// The file is read the way the page launch reads its token: through
/// `read_private_bounded`, which refuses a link, a file owned by another
/// user, and a file any other user can read. Either form refuses a
/// claim-shaped value (protocol-change/053): a claim authenticates nothing,
/// and the invitee redeems it with `loom claim`. Neither refusal repeats the
/// value it refused.
///
/// ## Examples
///
/// ```gleam
/// let assert Error(_) = tui.launch_token(["--token", "loomclaim_00"])
/// ```
@internal
pub fn launch_token(arguments: List(String)) -> Result(String, String) {
  use token <- result.try(
    case session_control.flag_value(arguments, "--token-file") {
      Ok(path) -> {
        use bytes <- result.try(
          host_bootstrap.read_private_bounded(path, 65)
          |> result.map_error(fn(reason) {
            "cannot read --token-file " <> path <> ": " <> reason
          }),
        )
        bit_array.to_string(bytes)
        |> result.map(string.trim)
        |> result.map_error(fn(_) { "--token-file " <> path <> " is not text" })
      }
      Error(Nil) ->
        Ok(
          session_control.flag_value(arguments, "--token") |> result.unwrap(""),
        )
    },
  )
  case claim_token.is_claim_shaped(token), login.is_login_shaped(token) {
    True, _ ->
      Error(
        "that is a claim token, not a credential; redeem it with "
        <> "`loom claim --addr ADDRESS` and pass the credential file it writes",
      )
    False, True ->
      Error(
        "that is a browser login, not a credential; a browser signs in with "
        <> "`loom ui`, and the terminal's credential is the owner token or the "
        <> "one `loom claim` wrote",
      )
    False, False -> Ok(token)
  }
}

fn launch_usage() -> String {
  "usage: loom [--workspace <path>] [--session <id>] "
  <> "[--server <path>] [--state-dir <path>] [--config <loom.toml>] "
  <> "[--model-profile <name>]\n"
  <> "       loom --executor <name> --workspace <registered name> "
  <> "[--config <loom.toml>] [--model-profile <name>]\n"
  <> "       loom --pool <name> --workspace <registered name> "
  <> "[--config <loom.toml>] [--model-profile <name>]\n"
  <> "       loom <command> [options]\n\n"
  <> "commands:\n"
  <> "  version            Print version, build commit and platform.\n"
  <> "  update [TAG|COMMIT]  Install a release and restart the daemon.\n"
  <> "  replay <path>       Render a recorded terminal session.\n"
  <> "  sessions list|rm    List or remove saved sessions.\n"
  <> "  deployment status|executors\n"
  <> "                      Show which configured machines the daemon reaches.\n"
  <> "  directory status    Show the session directory's cluster.\n"
  <> "  ui [--session <id>] [--operate | --observe] [--open]\n"
  <> "                      Print a link to your home page (sessions by\n"
  <> "                      workspace), or with --session to one session,\n"
  <> "                      which is read-only unless --operate. --open also\n"
  <> "                      opens it in the default browser. --ui is still\n"
  <> "                      accepted as another spelling.\n"
  <> "  ui --device [--origin <https-origin>]\n"
  <> "                      Print a link and QR code that sign a phone or\n"
  <> "                      another computer in to your home page, through\n"
  <> "                      an origin listed in [daemon] ui_origins.\n"
  <> "  access <command>    Owner access: list, show, invite, rotate, revoke.\n"
  <> "                      Runs against the local daemon, or a remote one\n"
  <> "                      with --addr and --token-file.\n"
  <> "  ext <command>       Manage daemon extensions.\n"
  <> "  distribution <command>\n"
  <> "                      Provision trusted distribution between daemons\n"
  <> "                      (init, provision, install, show). `dist` is short.\n"
  <> "  executor release SESSION\n"
  <> "                      Release a scope an executor will not reopen itself.\n\n"
  <> "  --config defaults to <state-dir>/loom.toml when that file exists\n"
  <> "  --model-profile names a [profiles.<name>] table of that file whose\n"
  <> "       roles a newly created session uses; a resumed session keeps its own\n"
  <> "  --executor creates new sessions in a workspace registered on that\n"
  <> "       [executors.<name>] of the daemon's configuration; --workspace is\n"
  <> "       then the registered name, not a path, and is never resolved on this\n"
  <> "       machine. It cannot be combined with --session\n"
  <> "  --pool is the same for a [pools.<name>]: the daemon picks the executor\n"
  <> "       when the session first opens. It cannot be combined with --executor\n"
  <> "  --record <path> writes every event to a replayable recording\n"
  <> "       loom --addr <websocket-url> --session <id> "
  <> "[--token-file <path> | --token <bearer>]\n"
  <> "       loom replay <path> [--at <frame>] [--all] "
  <> "[--width <w>] [--height <h>] [--plain]\n"
  <> "  the last frame is reproducible; a frame before a settling tick "
  <> "may differ between runs\n"
  <> "  --width/--height size the replay until the recording's own first "
  <> "resize supersedes them"
}

fn ui_usage() -> String {
  "usage: loom ui [--session <id>] [--operate | --observe] [--no-remember] "
  <> "[--device] [--origin <https-origin>] "
  <> "[--open] [--state-dir <path>] [--config <loom.toml>] "
  <> "[--server <path>]\n"
  <> "  Print a link to the web view, starting a daemon that serves it when\n"
  <> "  none runs. With no --session the link opens your home page, which\n"
  <> "  lists your sessions by workspace and is an operator's page unless\n"
  <> "  --observe asks for a read-only one. With --session it opens that\n"
  <> "  session, read-only unless --operate asks for an operator's, which is\n"
  <> "  the link to hand to someone who may only watch. --open also opens the\n"
  <> "  link in the default browser. The home page also signs the browser in for\n"
  <> "  30 days, so its bookmark works without `loom ui`; --no-remember opens\n"
  <> "  the page and signs nothing in. --origin builds the link on one of the\n"
  <> "  https origins the daemon lists in [daemon] ui_origins, for a browser\n"
  <> "  on another machine that reaches the daemon through a proxy such as\n"
  <> "  Tailscale Serve. --device prints a link and a QR code that sign\n"
  <> "  another device in to your home page; it lasts ten minutes and uses the\n"
  <> "  only listed origin unless --origin picks one. Options may come in any\n"
  <> "  order.\n"
  <> "  `loom --ui ...` is the same command."
}

fn replay_usage() -> String {
  "usage: loom replay <path> [--at <frame>] [--all] "
  <> "[--width <w>] [--height <h>] [--plain]\n"
  <> "  Render the last frame by default; --all prints every frame.\n"
  <> "  Frames keep their colour on a terminal; --plain drops it."
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
  <> "  verify <name>\n"
  <> "  check <name> [--home <dir>] [--helper <path>] [--best-effort]\n\n"
  <> "A source is a local path, an https:// .tar.gz, or an\n"
  <> "https://github.com/<owner>/<repo> URL. Extensions install under\n"
  <> "<home>/.loom/extensions."
}

// The help text of `loom distribution`, held here for the reason
// `extension_usage` is: the launcher must describe the command when `loomd` is
// absent, and the terminal package cannot import the daemon package. The shipped
// acceptance compares this text with `loomd distribution --help` so the two
// literals cannot silently drift.
fn distribution_usage() -> String {
  "usage: loom distribution <command>   (also: loomd distribution, and `dist` for short)

Provision a trusted Erlang distribution between Loom daemons with one plan, one
file per machine, and one command on each machine. No openssl is needed. The
deployment's membership is a signed ledger, so `enroll`, `revoke` and `renew`
change it later without provisioning the other nodes again.

commands:
  init [PATH]                     Write an example plan (default
                                  distribution-plan.toml). Refuses to overwrite.
  provision PLAN OUT [--force] [--drop-authority] [--passphrase-file PATH]
            [--home DIR] [--static]
                                  Read PLAN (.toml or .json), mint the CA, the
                                  node certificates and the shared cookie, and
                                  write OUT/<node>.loombundle (mode 0600) for
                                  each node plus OUT/system.json (no secrets).
                                  The bundles carry a signed membership ledger
                                  (also written to OUT/ledger.log), and the CA
                                  key is sealed under a passphrase in
                                  DIR/.loom/authority/<deployment id> (DIR
                                  defaults to $HOME) so that the ledger can be
                                  extended. The passphrase is asked for twice on
                                  the terminal, or read from PATH, a file only
                                  you can read. --drop-authority keeps no key,
                                  and the ledger can then never change. Only
                                  `loomd distribution provision` can ask on the
                                  terminal; `loom distribution provision` needs
                                  --passphrase-file or --drop-authority.
                                  --static writes the older bundles instead:
                                  each lists its peers' pins, the key is
                                  discarded, and adding a node means
                                  provisioning again. Refuses a non-empty OUT
                                  without --force.
  show OUT                        Print OUT/system.json as a table.
  install BUNDLE [--home DIR] [--config PATH] [--force]
                                  Run on the node's machine. Installs the
                                  credentials, the cookie at DIR/.erlang.cookie
                                  (default $HOME), the [distribution] and role
                                  tables in PATH (default DIR/.loom/loom.toml)
                                  and the TLS options file, then prints the
                                  command that starts the daemon. A ledger
                                  bundle also writes the ledger beside the
                                  credentials, and the node trusts that snapshot
                                  until it syncs with a peer that holds more.
                                  Running it again with the same bundle changes
                                  nothing. A different existing cookie,
                                  credential file or table is refused unless
                                  --force.
  enroll NAME --node N --role orchestrator|executor [--host H] [--port P]
         [--links A,B] [--directory voter|learner|none]
         [--workspace NAME=ROOT]... [--bundle-dir DIR]
         [--out DIR] [--force] [--wait SECONDS] [COMMON]
                                  Run on the operator's machine. Mints a
                                  certificate for N under the kept authority,
                                  signs a `member` entry, appends it to the
                                  operator's copy of the ledger, hands it to a
                                  daemon, writes OUT/NAME.loombundle (default
                                  OUT: the current directory) and prints which
                                  members hold the new head, after at most
                                  SECONDS (default 10). --links names the
                                  members NAME may connect to; an executor
                                  needs at least one orchestrator there, and
                                  --workspace to serve anything. --directory
                                  seats the node in the session directory:
                                  voter for a machine that is always on (the
                                  directory takes three to seven voters),
                                  learner for one that only reads it, none
                                  (the default) for a laptop.
  revoke NAME [--reason TEXT] [--force] [--wait SECONDS] [COMMON]
                                  Signs a `revoke`, hands it to a daemon and
                                  prints confirmations. Refuses when the revoke
                                  would leave an executor with no orchestrator
                                  linked to it, cut members off from the rest,
                                  strand sessions (NAME owns some, or for an
                                  executor, some are placed on it), or leave the
                                  session directory with fewer than three
                                  voters, unless --force. An orchestrator that
                                  does not answer is unknown and also needs
                                  --force.
  renew NAME [--bundle-dir DIR] [--out DIR] [--force] [--wait SECONDS]
         [COMMON]
                                  Mints a new certificate for a member, signs a
                                  `member` entry with the new pin and writes a
                                  new bundle. Install it with --force on the
                                  node and restart the daemon. Connections to
                                  the node are dropped when the entry is
                                  applied. Give the same --bundle-dir the node
                                  was enrolled with, so the bundle installs
                                  over its credentials in place.
  log [--json] [--config PATH] [COMMON]
                                  Print the ledger's entries with their
                                  identities, then the last refusal and each
                                  member's reported head when a daemon answers.
                                  Reads the operator's copy, or the ledger that
                                  the [distribution] table of PATH names.
  import FILE [--state-dir DIR | --addr URL --token-file PATH]
                                  Feed the lines of a ledger file to the local
                                  daemon, for a node nothing else can reach.
  options CONFIG OUTPUT           Render the TLS distribution options file for
                                  the [distribution] table of CONFIG (mode
                                  0600). `install` does this for you.

COMMON is [--home DIR] [--deployment ID] [--passphrase-file PATH]
[--state-dir DIR | --addr URL --token-file PATH]. The key is found under
DIR/.loom/authority (DIR defaults to $HOME); --deployment picks one when
several are kept. The passphrase is asked for on the terminal, which only
`loomd distribution` can do; `loom distribution enroll`, `revoke` and `renew`
need --passphrase-file. The daemon is the one on this host, found through its
state directory (default $HOME/.loom), unless --addr names another.

A .loombundle holds the node's private key and the deployment's cookie. Copy it
to its machine over a channel you trust, and delete it there after installing.

Example:
  loom dist init plan.toml
  loom dist provision plan.toml out --passphrase-file ~/.loom-passphrase
  scp out/devbox.loombundle devbox:
  ssh devbox loom dist install devbox.loombundle
  loom dist enroll laptop2 --node loom@laptop2.example --role orchestrator --links devbox --passphrase-file ~/.loom-passphrase"
}

// The help text of `loom executor`, held here for the reason
// `distribution_usage` is, and compared with `loomd executor --help` by the
// same shipped acceptance.
fn executor_usage() -> String {
  "usage: loom executor release SESSION [--state-dir PATH]   (also: loomd executor release)

Release a scope on this machine's executor that the executor will not reopen by
itself. Run it on the executor, with the executor daemon stopped.

An executor refuses to attach a session to a scope that closed with unknown
cleanup, or that was left closing when the daemon ended mid-close, because it
cannot prove the scope's processes are gone. After the executor restarts, every
session that closes ends this way. `release` is the operator saying the
processes are gone: it closes the scope as retired and records that it did, in
the executor's ledger. The session's next open then reopens the scope at the
next incarnation.

SESSION is the orchestrator's session id, as the refused open names it.
--state-dir is the executor daemon's state directory (default ~/.loom), where
exec-ledger.db lives.

Check that nothing from the session still runs on this machine first. The
command refuses a scope that is open, and a scope that is already closed
cleanly.

While it runs it holds the state directory's daemon reservation, and it leaves
that record behind when it exits. A daemon started during the release is
refused and must be started again, and `loom` may report that the daemon is
still starting until the next daemon starts.

Example:
  loom executor release 7f3a9c1e --state-dir /var/lib/loom"
}

/// The arguments `loom` would hand to the server for a passthrough command,
/// or `None` when the command is the launcher's own. `loom ext` and
/// `loom distribution` (with its `dist` shorthand) and `loom executor` are
/// passthroughs, and the
/// server sees the subcommand spelled the way it spells it.
///
/// ## Examples
///
/// ```gleam
/// assert tui.server_arguments(["dist", "init"]) == Some(["distribution", "init"])
/// ```
@internal
pub fn server_arguments(arguments: List(String)) -> Option(List(String)) {
  case parse_launch(arguments) {
    Forward(verb:, arguments:) -> Some([verb, ..arguments])
    _other -> None
  }
}

// `loom distribution` forwards to `loomd`, with one refusal made here. The
// forwarded child's stdin is a pipe, so a command that opens or seals the
// authority key cannot ask for the passphrase on the terminal, and would fail
// only after the server booted. Those are `provision` (ledger mode, which is the
// default) and `enroll`, `revoke` and `renew`. Refusing up front gives the
// operator the same answer and the way out, and leaves the prompt to
// `loomd distribution`, which owns the terminal.
fn forward_distribution(arguments: List(String)) -> Launch {
  let has = fn(rest, flag) { list.contains(rest, flag) }
  case arguments {
    ["provision", ..rest] ->
      case
        has(rest, "--static")
        || has(rest, "--passphrase-file")
        || has(rest, "--drop-authority")
        || has(rest, "--help")
        || has(rest, "-h")
      {
        True -> Forward(verb: "distribution", arguments:)
        False ->
          Invalid(
            "distribution provision needs --passphrase-file PATH, "
            <> "--drop-authority or --static here; the passphrase prompt works "
            <> "only when run as `loomd distribution provision`",
          )
      }
    [verb, ..rest] if verb == "enroll" || verb == "revoke" || verb == "renew" ->
      case
        has(rest, "--passphrase-file") || has(rest, "--help") || has(rest, "-h")
      {
        True -> Forward(verb: "distribution", arguments:)
        False ->
          Invalid(
            "distribution "
            <> verb
            <> " needs --passphrase-file PATH here; the passphrase prompt "
            <> "works only when run as `loomd distribution "
            <> verb
            <> "`",
          )
      }
    _other -> Forward(verb: "distribution", arguments:)
  }
}

fn parse_replay(arguments: List(String)) -> Launch {
  case arguments {
    [] -> Invalid("replay needs a recording path\n" <> launch_usage())
    [path, ..options] ->
      case
        parse_replay_options(
          options,
          ReplayOptions(
            frames: LastFrame,
            width: 80,
            height: 24,
            colour: FollowTerminal,
          ),
        )
      {
        Ok(ReplayOptions(frames:, width:, height:, colour:)) ->
          Replay(
            path:,
            frames:,
            size: backend.TerminalSize(width:, height:),
            colour:,
          )
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
    ["--plain", ..rest] ->
      parse_replay_options(rest, ReplayOptions(..options, colour: PlainText))
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
  colour: Colour,
) -> Nil {
  case replay_recording(path, size) {
    Ok(rendered) -> print_frames(rendered, frames, frame_printer(colour))
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
  let model = {
    let fresh =
      new_model(inbox, workspace.Context(path: "replay", branch: None))
    Model(
      ..fresh,
      shared: Shared(
        ..fresh.shared,
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
        reviewer_rows: [],
        notice: "replaying",
      ),
    )
  }
  use run <- result.try(run_script(
    model,
    virtual_backend.script(size, steps, inbox)
      |> virtual_backend.with_attempts(buffered.sender(
        model.shared.replay_inbox,
      )),
  ))
  case run.final.shared.replay_error {
    None -> Ok(run.frames)
    Some(reason) -> Error(reason)
  }
}

// The terminal question is asked once, before any frame is printed, so an
// `--all` run cannot switch rendering partway through. Standard input is
// part of the check because the one probe the launcher already has asks
// about both ends; a replay whose input is redirected prints plain text,
// which costs a person nothing they asked for.
fn frame_printer(colour: Colour) -> fn(buffer.Buffer) -> String {
  case colour, ffi_terminal.require_terminal() {
    FollowTerminal, Ok(Nil) -> frame.buffer_to_styled
    FollowTerminal, Error(_) | PlainText, _ -> frame.buffer_to_text
  }
}

fn print_frames(
  frames: List(buffer.Buffer),
  selection: FrameSelection,
  render: fn(buffer.Buffer) -> String,
) -> Nil {
  case selection {
    AllFrames ->
      list.index_fold(frames, Nil, fn(_acc, drawn, index) {
        io.println(frame_separator(index))
        io.println(render(drawn))
      })

    // A missing frame is a real failure rather than an empty print: it
    // means the recording had fewer events than the caller believed.
    LastFrame ->
      print_one(list.last(frames), "the recording drew no frames", render)
    FrameAt(index:) ->
      print_one(
        list.drop(frames, index) |> list.first,
        "the recording has no frame " <> int.to_string(index),
        render,
      )
  }
}

fn print_one(
  frame_result: Result(buffer.Buffer, Nil),
  missing: String,
  render: fn(buffer.Buffer) -> String,
) -> Nil {
  case frame_result {
    Ok(drawn) -> io.println(render(drawn))
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
/// let inbox = buffered.sender(model.inbox)
/// let attached = tui.connect_remote(model, inbox, address, session, token)
/// ```
@internal
pub fn connect_remote(
  base: Model,
  inbox: Subject(connection_event.Message),
  address: String,
  session: String,
  token: String,
) -> Model {
  let base =
    live_base(
      Model(..base, shared: shared_set.inbox(base.shared, buffered.new(inbox))),
    )
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
      let model = runtime.adopt_control(base, host)

      // The first request starts before the loop does, as it did when the
      // reducer started jobs itself: the flush performs the `StartJob` the
      // catalogue load queued rather than leaving it for the first event.
      case session {
        "" -> session_control.load_catalogue(model, "", None)
        id -> session_control.begin_open(model, id)
      }
      |> runtime.flush
    }
  }
}

fn live_base(base: Model) -> Model {
  Model(
    ..base,
    shared: base.shared
      |> shared_set.peer(Disconnected)
      |> shared_set.session("")
      |> shared_set.models([])
      |> shared_set.skills([])
      |> shared_set.strands([])
      |> shared_set.records([])
      |> shared_set.streams([])
      |> shared_set.tool_tails([])
      |> shared_set.transcript([])
      |> shared_set.current_model("unconfigured")
      |> shared_set.reviewer_rows([])
      |> shared_set.advisor_history(advisor_history.Board(
        items: [],
        unloaded: None,
      ))
      |> shared_set.notice("select a saved session or create one"),
  )
}

/// Attaches a local launch to the daemon it resolved, opening `selected` when
/// one was named and the picker otherwise.
///
/// This is the path `loom` and `loom --session <id>` take. It reads the owner
/// credential, adopts the control connection, and opens the chosen session
/// through `session_control.open_chosen`, which says when `--model-profile`
/// was ignored because the session already existed.
///
/// ## Examples
///
/// ```gleam
/// let attached = tui.attach_daemon(model, control, Ok(address), token_path, "")
/// ```
@internal
pub fn attach_daemon(
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
      let model = runtime.adopt_control(base, host)
      let model =
        Model(
          ..model,
          shared: shared_set.transcript(model.shared, model.shared.build_notice),
        )

      // Flushed for the reason `connect_remote` gives: the first request
      // starts at launch rather than at the loop's first event.
      case selected {
        "" -> session_control.load_catalogue(model, "", None)
        id -> session_control.open_chosen(model, id)
      }
      |> runtime.flush
    }
  }
}

/// Applies one terminal event and performs the effects it decided on.
///
/// This is the function etui and the virtual backend call:
/// `runtime.message`, which translates the event into the client's own
/// message and reads the clocks and any pasted file into it,
/// `runtime.receive`, which moves the waiting traffic and job replies into
/// the model, then `step`, then `runtime.settle`, which performs what the
/// step returned and stores the job table it leaves. Everything that
/// inspects a transition without acting on it calls `step` instead.
///
/// ## Examples
///
/// ```gleam
/// let next = tui.update(backend.Tick, model)
/// ```
@internal
pub fn update(event: backend.InputEvent, model: Model) -> Model {
  runtime.settle(step(runtime.message(event, model), runtime.receive(model)))
}

/// Applies one message and returns the effects it decided on, without
/// performing them.
///
/// The reducer queues its I/O as `effect.Effect` values rather than doing
/// it, and this collects them, together with whatever was still queued
/// from a caller that drove a reducer outside the loop. The returned model
/// has an empty outbox. Recording appends are effects like the rest: the
/// input's own line comes first in the list, and every line it caused
/// follows in the order it was decided. The control, reconnect, activity,
/// attachment and configuration jobs are started and cancelled by
/// `StartJob` and `CancelJob` effects.
///
/// The step reads no file. A pasted image is read by `runtime.message`
/// when it builds the message, and the step attaches what that read found,
/// so a test that builds a `msg.Pasted` itself chooses what the read found.
///
/// The step reads the connection, replay and attachment inboxes, and every
/// job's messages, only through what `runtime.receive` put in the model, so
/// a test that calls `step` directly and wants it to see queued traffic
/// receives first, or hands it a job message with `runtime.hold`.
///
/// The step reads no clock. It applies an input's event at the input's
/// stamp, which it stores as `Model.stamp` before any reducer runs; a test
/// that builds a message chooses the time with it.
///
/// Traffic the host received arrives as `msg.Arrived`, which the step only
/// admits (`admission.admit`): each message goes into the buffer or slot
/// that waits for it, nothing is reduced, and no effect is returned. The
/// drains still run at a tick or a key, in their fixed order, so Escape
/// still acts before any traffic is reduced. A reply dropped at admission
/// that holds a socket or a control connection queues its release, which
/// the next input's step returns, as `runtime.hold` did in phase 2.
///
/// ## Examples
///
/// ```gleam
/// let #(next, effects) =
///   tui.step(
///     msg.Input(
///       model.shared.stamp,
///       model.view.wall_ms,
///       msg.KeyPressed("enter", keys.Enter),
///     ),
///     model,
///   )
/// ```
@internal
pub fn step(message: msg.Msg, model: Model) -> #(Model, List(effect.Effect)) {
  case message {
    msg.Input(at:, wall_ms:, event:) -> reduce(at, wall_ms, event, model)
    msg.Arrived(arrivals:) -> #(admission.admit(model, arrivals), [])
  }
}

// One input's step. Recorded before the event is interpreted, so a
// recording holds what the client was given rather than what it made of it,
// and the input's line is ahead of every line the reducer queues for it.
fn reduce(
  at: session_msg.Stamp,
  wall_ms: Int,
  event: msg.Event,
  model: Model,
) -> #(Model, List(effect.Effect)) {
  let model = tui_model.start_step(model, at, wall_ms, event)
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
fn apply_input(event: msg.Event, model: Model) -> Model {
  case event {
    // A selection is screen cells over a layout the resize just replaced,
    // so it goes with the old layout rather than surviving as a highlight
    // over whatever now occupies those cells.
    msg.Resized(width:, height:) ->
      Model(
        ..model,
        view: model.view
          |> view_set.width(width)
          |> view_set.height(height)
          |> view_set.selection(None)
          |> view_set.selection_gutters([])
          |> view_set.caches(
            tui_model.Caches(..model.view.caches, selection_frame: None),
          ),
      )
      |> image_plan.resized
      |> submit.hand_off_sheet
      |> tui_model.mark_activity
      |> tui_model.invalidate_frame
    msg.Ticked -> tick.update_tick(model)

    // A keyboard burst can arrive before an idle tick even when the final
    // server reply is already queued. Apply bounded ready progress before
    // interpreting the action, without starting another periodic capture.
    msg.KeyPressed(key:, ..) ->
      interaction.update_ready_key(key, model)
      |> tui_model.mark_activity
      |> tui_model.invalidate_frame
    msg.Pasted(text:, image:) ->
      interaction.handle_paste(interaction.clear_selection(model), text, image)
      |> tui_model.mark_activity
      |> tui_model.invalidate_frame

    // A wheel flick delivers notches faster than any poll timeout, so no
    // tick arrives until the hand pauses. Draining here, as a key does,
    // keeps the history page this gesture asked for from waiting on that
    // pause and then landing with every capture queued behind it.
    msg.Scrolled(x:, y:, direction:) ->
      inbound.drain_connection(model, tui_model.connection_batch)
      |> interaction.clear_selection
      |> interaction.scroll_at(geometry.Position(x, y), case direction {
        recording.ScrollUp -> Older
        recording.ScrollDown -> Newer
      })
      |> tui_model.mark_activity
      |> tui_model.invalidate_frame

    // The left button is the selection button, as in every terminal. The
    // other two are listed so a new etui button is a compile error here.
    msg.Pressed(x:, y:, button: backend.MouseLeft) ->
      interaction.begin_selection(model, geometry.Position(x, y))
      |> tui_model.mark_activity
      |> tui_model.invalidate_frame

    // A held drag is the other gesture that outruns the poll timeout, for as
    // long as the button is down. The selection reads the frame it began
    // on, so the traffic applied here cannot move the cells under it.
    msg.Dragged(x:, y:, button: backend.MouseLeft) ->
      inbound.drain_connection(model, tui_model.connection_batch)
      |> interaction.extend_selection(geometry.Position(x, y))
      |> tui_model.mark_activity
      |> tui_model.invalidate_frame
    msg.Released(x:, y:, button: backend.MouseLeft) ->
      interaction.finish_selection(model, geometry.Position(x, y))
      |> tui_model.mark_activity
      |> tui_model.invalidate_frame
    msg.Pressed(button: backend.MouseMiddle, ..)
    | msg.Pressed(button: backend.MouseRight, ..)
    | msg.Dragged(button: backend.MouseMiddle, ..)
    | msg.Dragged(button: backend.MouseRight, ..)
    | msg.Released(button: backend.MouseMiddle, ..)
    | msg.Released(button: backend.MouseRight, ..)
    | msg.Moved(..) -> model
  }
}

// Everything an event does after its own handler: the worktree request a
// newly shown diff needs, the shared step's settle (`session_step.settle`),
// the Herdr report, the transcript projection, the viewport snap and the
// frame decision. `model` is the state before the event and `updated` the
// state its handler produced.
fn settle_update(event: msg.Event, model: Model, updated: Model) -> Model {
  let updated = case !layout.diff_shown(model) && layout.diff_shown(updated) {
    True -> inbound.request_visible_worktree(updated)
    False -> updated
  }

  // The shared step's own settle: the context, pending-nudge and goal
  // edges, which compare the session state alone.
  let updated =
    tui_model.run_shared(updated, session_step.settle(model.shared, _))
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
        before: model.shared.render_revision,
        after: settled.shared.render_revision,
      ),
    ),
  )
  |> image_plan.settle
  |> layout_save.settle
}

// A gesture aimed at the transcript owns the viewport outright: pacing
// exists to smooth output the reader did not ask for, and making a scroll,
// a page key or a resize wait on it would put the walk in front of the
// hand.
fn snap_viewport_for(model: Model, event: msg.Event) -> Model {
  case pacing.viewport_address(event) {
    pacing.AddressesElsewhere -> model
    pacing.AddressesTranscript ->
      Model(
        ..model,
        view: view_set.revealed_rows(model.view, model.view.rendered_row_count),
      )
  }
}
