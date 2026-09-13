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
import core/register
import etui/app
import etui/backend
import etui/backend/default
import etui/buffer
import etui/geometry.{type Rect, Fill, Length}
import etui/keys
import etui/span
import etui/style
import etui/text
import etui/widgets/block
import etui/widgets/paragraph
import etui/widgets/statusbar
import etui/widgets/textarea as text_area
import gleam/bit_array
import gleam/bool
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap as host_bootstrap
import host/endpoint
import machine/strand as machine_strand
import simplifile
import tui/agents
import tui/approval
import tui/approval_panel
import tui/attachment
import tui/attempt
import tui/attempt_replay
import tui/bootstrap
import tui/command
import tui/completion_summary
import tui/composer
import tui/connection
import tui/context_view
import tui/daemon
import tui/daemon/protocol as control_protocol
import tui/daemon/selection as daemon_selection
import tui/file_read_view
import tui/frame
import tui/herdr
import tui/history_view
import tui/image_drop
import tui/internal/ffi_terminal
import tui/live_jobs
import tui/markdown
import tui/model_selector
import tui/notes_view
import tui/pacing
import tui/protocol.{ModelInfo, Strand}
import tui/queue_editor
import tui/recording
import tui/reviewer_status
import tui/selection
import tui/session_channel
import tui/session_selector
import tui/sessions
import tui/snapshot
import tui/snapshot_view
import tui/text_hygiene
import tui/theme
import tui/tool_activity
import tui/transcript_anchor
import tui/virtual_backend
import tui/workspace
import tui/worktree_view
import weft

/// Who a transcript line belongs to, which is the whole of its styling.
@internal
pub type Speaker {
  System
  User
  Assistant
  Reasoning

  /// One reasoning block stood in for by a single literal row.
  ///
  /// The digest bypasses the Markdown renderer, so a fence or a list
  /// marker inside the model's own prose cannot turn the indicator into
  /// several rows. That is what lets a reasoning block hold one height
  /// from its first live fragment through to its settle.
  ReasoningDigest

  ToolCall
  ToolResult
  ToolDetail

  /// Literal patch content, rendered without interpreting Markdown fences.
  ToolPatch

  ToolFailure
  Failure
}

/// Whether the transcript area is showing captured edits.
@internal
pub type DiffVisibility {
  /// Show a side pane when wide enough, preserving conversation on narrow screens.
  DiffAutomatic

  /// Show conversation history.
  DiffHidden

  /// Show successful edits from the retained history window.
  DiffVisible
}

// Scroll direction names the operation without carrying a Boolean polarity
// through the two independently scrollable reading surfaces.
type ScrollDirection {
  Older
  Newer
}

/// One rendered transcript line before markdown and wrapping.
@internal
pub type Line {
  Line(speaker: Speaker, text: String)
}

// A stream stays separate from durable entries because the server may replay
// the settled entry after its fragments. Keeping both in one list would render
// the same assistant answer twice at the exact moment it becomes durable.
/// The most text one live stream keeps on screen, in bytes.
///
/// The same 24 KiB the snapshot's sampled preview is clipped to, because the
/// two are representations of the same thing and a live answer that could
/// outgrow its own sample would be the only unbounded region in the model.
/// The cost of exceeding it is not only the bytes: every paint reflows the
/// whole live region, so an unbounded one makes the terminal slower the
/// longer the answer runs, until it can no longer drain its socket.
@internal
pub const live_stream_limit = 24_576

/// The undurable fragments of one strand-and-kind generation.
///
/// A request owns its text, thinking and tool-call fragments. Operation IDs
/// alone cannot separate requests around tool batches or retries. An `end`
/// observation keeps an empty marker until the next request so an older cut's
/// sampled preview cannot resurrect a completed answer.
///
/// `bytes` is what the fragments weigh, carried rather than recomputed: the
/// budget is checked once per delta and a delta arrives per provider token,
/// so counting the list each time would make a bounded question cost the
/// length of the answer.
@internal
pub type Stream {
  Stream(
    strand: String,
    operation: String,
    generation: String,
    kind: String,
    fragments: List(String),
    bytes: Int,
  )
}

/// The rolling tail of one output stream of a tool call that is still
/// running, as the daemon last pushed it (`protocol-change/031`).
///
/// It is kept apart from `Stream` because the two grow differently: a
/// stream is appended to fragment by fragment, while a tail is *replaced*
/// whole on every frame, keyed by `{strand, operation, step, source_index,
/// call_id, stream}`. The daemon bounds `text` at a few kilobytes and this terminal keeps one
/// tail per key, so however long a command runs the region stays the size
/// of the last frame. It is cleared with the strand's streams — on an
/// entry landing and on the operation reaching `done` — and a capture
/// drops it once that call's durable result is visible. A fixed global cap
/// also bounds tails whose matching capture was missed or evicted.
@internal
pub type ToolTail {
  ToolTail(
    strand: String,
    operation: String,
    step: String,
    source_index: Int,
    call_id: String,
    stream: String,
    text: String,
    total_bytes: Int,
  )
}

/// The modal surface that owns focus, if any.
@internal
pub type Overlay {
  NoOverlay
  ModelSelector(model_selector.State)
  AgentInspector(selected: Int)
  SessionSelector(sessions.State)
  DaemonSelector(session_selector.State)
  ApprovalInspector(approval_panel.State)
}

/// The latest unconfirmed submission, not proof that earlier uncertainty cleared.
@internal
pub type UnconfirmedSubmission {
  UnconfirmedSubmission(
    /// Session whose command was sent, retained across later attachment changes.
    session: String,
    /// Command kind only; no prompt body, grants or credentials are retained.
    command: String,
    /// Original connection-local request identity for this unknown outcome.
    request_id: Int,
  )
}

/// Only composer-originated sends consume the visible draft.
@internal
pub type SubmissionSource {
  /// Text, attachments and mode remain in the existing composer until send.
  ComposerSubmission

  /// A selector action must preserve unrelated composer text.
  OverlaySubmission
}

type Launch {
  Demo
  Local(bootstrap.Options, selected: String)
  Remote(address: String, session: String, token: String)
  Invalid(reason: String)

  // `loom ext …` is not a terminal application at all: it is a
  // passthrough to `loomd`, whose own `ext` subcommand owns every verb.
  // Forwarding rather than reimplementing is what stops the launcher and
  // the server disagreeing about what an install did.
  Forward(arguments: List(String))

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

/// What Enter does to a draft while an operation is live.
///
/// The two are different requests, not two shades of one. A steer is folded
/// into the run that is already going, which is what an operator wants when
/// they are correcting it; a prompt is a turn of its own, held by the daemon
/// until the run settles, which is what they want the rest of the time. The
/// common case is the default and `tab` reaches the other one for a single
/// draft.
@internal
pub type SubmissionMode {
  /// Send `prompt`. On a busy strand the daemon holds it and runs it next.
  PromptNext

  /// Send `steer`, folding the draft into the run that is already going.
  SteerNow
}

/// One submission this terminal made that the daemon answers with a user
/// entry of its own.
///
/// The list of these is what tells a drained prompt's entry apart from the
/// entry a steer commits. Both arrive as an ordinary `UserMessage` on the
/// active strand and neither reply carries an entry id — the gateway rewrites
/// a steer's entry reply to a bare `mutation_outcome` before it reaches the
/// wire — so the only discriminator left is the order this terminal issued
/// them in, which is the order the daemon commits them in: a steer joins the
/// run that is already open, and a held prompt is drained only once that run
/// has settled.
@internal
pub type Submission {
  /// A prompt aimed at a busy strand. The daemon holds it and runs it on
  /// that strand's next turn, so it is drawn under the live tail until the
  /// entry it stands for commits.
  HeldPrompt(text: String)

  /// A steer or a follow-up. It is folded into the answer already on screen
  /// and so draws nothing of its own, but its entry still commits, and that
  /// entry is not the one a held prompt is waiting for.
  Interjection
}

// Interrupt state belongs to the client because the server's abort contract
// deliberately drains queued steer entries. Holding one instruction here until
// the durable operation settles preserves the operator's intent without racing
// a steer admission against cancellation.
/// Where this client's commands go, and what stands in for a server when
/// they go nowhere.
///
/// This is one type rather than an optional socket because the absence of a
/// socket means two opposite things. A design preview has no server and
/// answers a submitted prompt itself, so the layout can be seen; a replay
/// has no server *and must not invent one*, because every line the server
/// would have sent is already in the recording and a locally fabricated
/// echo would appear beside the real one. An `Option` collapses those two
/// into the same `None`, which is exactly the bug this replaced.
@internal
pub type Peer {
  /// A live ClientGateway websocket. Commands are written to it and the
  /// server's own events come back as transcript.
  Attached(socket: connection.Connection)

  /// A live launch without an adopted socket; never fabricates preview replies.
  Disconnected

  /// The `--demo` preview. A submitted prompt is echoed locally, because
  /// there is nothing else to draw.
  Preview

  /// A replay of a recording. Inbound traffic and rendering are
  /// reproduced; nothing is sent and nothing is invented. A submit does
  /// only what the live path does *locally* — clear the draft, mark the
  /// strand submitting, set the notice — and waits for the recorded
  /// server events like the live client did.
  Replaying
}

/// Where a finished mouse selection is copied to.
///
/// A copy is an escape sequence written to the terminal, and only a real
/// terminal should receive one: a scripted run under the virtual backend
/// shares stdout with the test runner, and an OSC 52 printed there would
/// overwrite the developer's clipboard with a fixture. The interactive
/// launch is the one place that turns this on.
@internal
pub type Clipboard {
  /// Write OSC 52 to the terminal etui is drawing on.
  TerminalClipboard

  /// Discard the copy. The selection and its notice still happen, so a
  /// replay draws the same frames the live client drew.
  NoClipboard
}

/// One held instruction, waiting for the operation it interrupted to settle.
@internal
pub type Interrupt {
  Interrupt(
    /// The strand whose current work was stopped.
    strand: String,
    /// The observed operation; a successor completes this interrupt too.
    operation: Option(String),
    /// Legacy recordings retain replacement text until their terminal event.
    pending: Option(String),
  )
}

/// What a finished picker control job produced.
///
/// The picker can page or delete, never both at once, so the two share one
/// job slot and are told apart here rather than by a second set of fields
/// that could both be occupied.
@internal
pub type ControlOutcome {
  /// One authorized page and the identity to highlight in it.
  PageLoaded(page: control_protocol.Page, selected: String)

  /// The daemon removed this registration and its database.
  SessionDeleted(session_id: String)
}

/// One relayed control job, selected by the terminal and its actor-backed driver.
@internal
pub type ControlRequest {
  ControlRequest(
    cancel: weft.Cancel,
    replies: Subject(weft.Pulled(ControlOutcome, String)),
    result: Option(Result(ControlOutcome, String)),
  )
}

/// An already selected control job message retains its original source tag.
@internal
pub type ControlEvent {
  ControlEvent(
    source: Subject(weft.Pulled(ControlOutcome, String)),
    reply: weft.Pulled(ControlOutcome, String),
  )
}

/// The last completed frame, keyed by the screen and revision it was for.
@internal
pub type FrameCache {
  FrameCache(
    screen: Rect,
    revision: Int,
    rendered: #(buffer.Buffer, Result(geometry.Position, Nil)),
  )
}

/// The immutable presentation state.
///
/// Published `@internal` so the virtual-backend harness can build a state
/// by hand and drive the real loop over it. Nothing outside this package
/// sees it.
@internal
pub type Model {
  Model(
    quit: Bool,
    width: Int,
    height: Int,
    input: text_area.TextAreaState,
    attachments: List(composer.Attachment),
    history: List(String),
    history_index: Int,
    history_draft: String,
    command_selected: Int,
    submission_mode: SubmissionMode,
    /// Ownership marker only; the unsent encoded intent belongs to Channel.
    pending_submission: Option(SubmissionSource),
    interrupt: Option(Interrupt),
    submitting: Option(String),
    /// Submissions to the active strand whose entries have not committed
    /// yet, oldest first, which is the order the daemon commits them in.
    /// The held prompts among them are drawn under the live tail; the
    /// interjections draw nothing and are here to consume the entries they
    /// produce, so that a steer cannot retire a prompt's echo.
    queued: List(Submission),
    /// The submission whose reply has not arrived, if any. A prompt the
    /// daemon refuses — a fifth held prompt meets `code_conflict` — commits
    /// no entry and so has nothing to retire it later; keeping it here until
    /// the daemon says it took it is what stops a refusal leaving an echo on
    /// screen for the rest of the session. There is at most one because the
    /// conversation channel carries one mutation at a time.
    awaiting_outcome: Option(Submission),
    transcript: List(Line),
    records: List(protocol.EntryRecord),
    /// Bounded scrollback is independent of the authoritative live cut.
    scrollback: history_view.State,
    /// Retained scrollback of every strand other than the active one, keyed
    /// by strand name. The window is per strand because ancestry is: the
    /// projection walks one leaf's parent chain, and the six hundred
    /// descriptors retained for `main` say nothing about a sub-agent. A
    /// switch therefore has to put one window down and pick another up.
    /// Parking here rather than holding a window per strand inside
    /// `history_view` keeps that module owning exactly one reading endpoint,
    /// which is what `freeze`, `older` and `accept` are written against;
    /// only the switch knows that two endpoints exist. `history_view.capture`
    /// still discards a window whose strand does not match, which remains the
    /// safety net for every path that changes strands without coming through
    /// here.
    parked_scrollback: dict.Dict(String, history_view.State),
    notice: String,
    /// A complete queue draft never borrows the ordinary composer.
    queue_editor: queue_editor.State,
    /// Current Git observation and independent file-navigation state.
    worktree: worktree_view.State,
    /// Server-observed current context and independent inspector state.
    context: context_view.State,
    /// Attachment-local terminal result provenance.
    completion: completion_summary.State,
    /// Exact attachment which owns the remembered operation boundaries.
    completion_owner: String,
    /// Details visibility does not borrow the composer.
    summary_surface: queue_editor.Surface,
    /// Independent detailed-summary scroll offset.
    summary_scroll: Int,
    /// Current job observation is separate from the result timestamp.
    jobs: Option(live_jobs.Board),
    /// Local receipt time; server and terminal clocks are never subtracted.
    jobs_observed_ms: Option(Int),
    /// One explicit job read deferred behind the mutation lane.
    jobs_refresh: worktree_view.Refresh,
    /// Attachment and strand for the one issued roster read.
    jobs_awaiting: Option(#(String, String)),
    /// Actual lane request ID; unrelated refusals cannot settle this read.
    jobs_request: Option(Int),
    /// Missing observations are unavailable, never a zero-job assertion.
    jobs_notice: String,
    help_open: Bool,
    notes_open: Bool,
    /// A dedicated view of captured edit diffs, without tool retries.
    diff_view: DiffVisibility,
    /// Diff scrolling is independent of conversation scrolling, including
    /// while a narrow terminal temporarily shows only the changes.
    diff_scroll_offset: Int,
    /// Cached newest-first diff rows. Stream fragments cannot make the
    /// changes pane reparse settled edit results.
    diff_rows: List(span.Line),
    /// Current diff lines retain layout across captures at the same width.
    /// Rebuilding keeps only the newly captured projection's keys.
    diff_line_cache: Dict(Line, List(span.Line)),
    /// The row count belongs to the cached diff projection and its width.
    diff_row_count: Int,
    /// The observation and selection that produced the cached patch rows.
    /// Compare against the cache source even when a driver applied a reply
    /// before the next terminal update.
    diff_worktree_source: #(Option(worktree_view.Board), Int),
    /// Latest explicit read of the notes board, with its own revision.
    note_board: Option(notes_view.Board),
    overlay: Overlay,
    models: List(protocol.ModelInfo),
    /// Slash commands loaded by the currently attached daemon.
    skills: List(command.Suggestion),
    current_model: String,
    workspace: workspace.Context,
    strands: List(protocol.Strand),
    agent_summary: String,
    /// Current reviewer progress, with operation-owned task excerpts.
    reviewer_rows: List(reviewer_status.Row),
    active_strand: String,
    session: String,
    local_options: Option(bootstrap.Options),
    inbox: Subject(connection.Message),
    peer: Peer,
    session_switch: sessions.SwitchStatus,
    /// One provisional replacement, whose original deadline includes capture.
    candidate: attachment.Status,
    /// Serial credited state for the adopted socket only.
    channel: Option(session_channel.Channel),
    /// Last complete raw cut and its coherent metadata projection.
    captured: Option(#(snapshot.Captured, snapshot_view.View)),
    /// What made the lane ask for the last cut that changed something
    /// visible: a pushed frame, the idle refresh, or the terminal's own
    /// command. Live delivery is the difference between the first two, and
    /// this is where a fixture reads it. A capture that painted nothing
    /// leaves it alone.
    last_capture: session_channel.Capture,
    /// How many commit notices this terminal's lane has received, including
    /// the ones that asked for no capture. A notice can name a sequence the
    /// terminal already holds, or arrive while the idle refresh's catch-up is
    /// already in flight, and in neither case does it paint anything — which
    /// is why `last_capture` cannot say whether the daemon pushed. This can:
    /// it counts arrivals, so it is the fixture's witness that live delivery
    /// reaches this terminal.
    notices: Int,
    /// Terminal-owned daemon control, independent of the selected session.
    daemon_host: Option(daemon_selection.Host),
    /// One bounded metadata page request; no catalogue accumulation.
    control_request: Option(ControlRequest),
    /// Retained after an uncertain create so another key cannot duplicate it.
    creation_key: Option(String),
    /// Current pending requests and at most sixteen bounded resolved summaries.
    approvals: List(approval.Review),
    /// Exact decision currently requested for local inspection, if any.
    inspecting_approval: Option(String),
    /// Last sent mutation whose outcome was not observed; survives adoption.
    unconfirmed: Option(UnconfirmedSubmission),
    /// Next terminal-local attachment identity, independent of server IDs.
    next_attempt: Int,
    /// Two-slot effect-free replay state and its terminal-owned delivery lane.
    replay_state: attempt_replay.State,
    replay_inbox: Subject(attempt.Event),
    /// A malformed local recording stops replay rather than skipping a frame.
    replay_error: Option(String),
    next_id: Int,
    usage: message.Usage,
    /// When the active strand's streaming generation produced its first
    /// fragment, on the monotonic clock; `None` between generations.
    /// Paired with the output count the settlement's usage reports, it
    /// yields the rate. Usage reports carry no strand, so the figure is
    /// exact only while one strand streams at a time; a child settling
    /// under a streaming parent skews one reading, which a footer can
    /// bear.
    generation_started_ms: Option(Int),
    /// Output tokens per second of the last settled generation, for the
    /// footer. `None` until one generation has both streamed and settled.
    output_rate_tps: Option(Int),
    agent_rail_visible: Bool,
    details_expanded: Bool,
    repaint_phase: Bool,
    activity_frame: Int,
    /// When the active strand's current activity began, on the monotonic
    /// clock; `None` while it is idle. Set and cleared on the indicator's
    /// tick so the render stays pure.
    activity_started_ms: Option(Int),
    /// Whole seconds the active strand has been busy, recomputed on the
    /// tick and shown beside the phase so a long think reads as time
    /// passing rather than as a stall.
    activity_elapsed_s: Int,
    streams: List(Stream),
    /// Transient rows captured when leaving the live tail. Durable history has
    /// its own frozen ancestry; this keeps in-flight reasoning stationary too.
    reading_lines: Option(List(Line)),
    tool_tails: List(ToolTail),
    scroll_offset: Int,
    render_revision: Int,
    rendered_revision: Int,
    rendered_row_count: Int,
    rendered_rows: List(span.Line),
    /// How many of `rendered_rows` the bottom-anchored viewport has shown.
    /// Never above `rendered_row_count`; the difference is the backlog the
    /// pacing walk is working off, and a gesture closes it at once.
    revealed_rows: Int,
    /// Durable provenance for wrapped rows; transient rows have no anchor.
    rendered_anchors: List(Option(transcript_anchor.Row)),
    record_rows: List(span.Line),
    /// Wrapped rows keyed by the complete presentation line. A rebuild keeps
    /// only the current projection, so old branches and outcomes are released.
    record_line_cache: Dict(Line, List(span.Line)),
    /// Compact invocation rows keyed by their complete immutable outcome.
    /// Rebuilds retain only calls in the current projection.
    compact_call_cache: Dict(tool_activity.Call, List(Line)),
    /// Narrative presentation retains only the current entries and owner.
    compact_entry_cache: Dict(
      #(entry.Entry, Option(message.Origin)),
      List(Line),
    ),
    pending_records: List(protocol.EntryRecord),
    record_cache_valid: Bool,
    record_cache_width: Int,
    record_cache_strand: String,
    record_cache_details: Bool,
    frame_revision: Int,
    frame_cache: Option(FrameCache),
    frame_debt: pacing.FrameDebt,
    /// The presentation clock, shared by pacing, activity, and throughput.
    /// Scripts inject this clock without changing transport deadlines.
    monotonic_time_ms: fn() -> Int,
    last_frame_ms: Int,
    activity_revision: Int,
    quiet_for_ms: Int,
    /// The open `--record` file, when the launch asked for one. Present
    /// in the model rather than beside the loop because the inbox is
    /// drained inside `update_tick`, so there is no other point at which
    /// both a websocket message and the recording are in scope.
    recorder: Option(recording.Recorder),
    /// The mouse selection being dragged or left highlighted after a copy.
    /// Held in screen cells over the frame on display, so it is cleared by
    /// the next key, wheel notch, paste or resize rather than tracked
    /// through a reflow.
    selection: Option(selection.Selection),
    /// The selected pane stays on its original cells until the selection ends.
    selection_frame: Option(buffer.Buffer),
    /// Whether a finished selection reaches the terminal's clipboard.
    clipboard: Clipboard,
    /// The Herdr pane reporter, when this terminal runs inside one. Held
    /// in the model for the same reason the recorder is: the publish runs
    /// where the lifecycle events just landed, which is inside `update`.
    herdr_reporter: Option(herdr.Reporter),
    /// The pane state and session last reported, so only a change sends.
    herdr_published: Option(herdr.Publication),
  )
}

/// Runs the interactive terminal client.
///
/// ## Examples
///
/// ```sh
/// loom --addr ws://127.0.0.1:8080/v1/ws --session demo
/// ```
pub fn main() {
  // Nothing but the rendered frame may write to this terminal from here on.
  ffi_terminal.silence_logger()

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
  let #(record, arguments) = case raw {
    ["ext", ..] | ["replay", ..] | ["sessions", ..] -> #("", raw)
    _other -> take_flag(raw, "--record")
  }
  let launch = parse_launch(arguments)
  case launch {
    // The passthrough runs before a single line of terminal setup: this
    // process is a pipe for the duration and then it is gone.
    Forward(arguments:) -> forward(arguments)
    Replay(path:, frames:, size:) -> replay(path, frames, size)
    Sessions(options:, command:) -> run_sessions(options, command)
    Demo | Local(..) | Remote(..) | Invalid(..) -> interactive(launch, record)
  }
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
    input: text_area.state_new(),
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
    scrollback: history_view.empty(),
    parked_scrollback: dict.new(),
    notice: "interactive design preview",
    queue_editor: queue_editor.new(),
    worktree: worktree_view.new(),
    context: context_view.new(),
    completion: completion_summary.new(),
    completion_owner: "",
    summary_surface: queue_editor.Closed,
    summary_scroll: 0,
    jobs: None,
    jobs_observed_ms: None,
    jobs_refresh: worktree_view.Settled,
    jobs_awaiting: None,
    jobs_request: None,
    jobs_notice: "Live jobs unavailable; /summary requests a current observation",
    help_open: False,
    notes_open: False,
    diff_view: DiffAutomatic,
    diff_scroll_offset: 0,
    diff_rows: [],
    diff_line_cache: dict.new(),
    diff_row_count: 0,
    diff_worktree_source: #(None, 0),
    note_board: None,
    overlay: NoOverlay,
    models: demo_models(),
    skills: [],
    current_model: "baseten-kimi-k3",
    workspace: project,
    strands:,
    agent_summary: agents.summary(strands),
    reviewer_rows: [],
    active_strand: "main",
    session: "demo",
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
    creation_key: None,
    approvals: [],
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
    record_rows: [],
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
    Forward(..) | Replay(..) | Sessions(..) | Demo -> base
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
          append_error(
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
      append_error(Model(..base, notice: "invalid launch"), reason)
    Remote(address, session, token) ->
      connect_remote(base, inbox, address, session, token)
  }

  // Only here does a copy reach a terminal: every other way of running the
  // loop shares stdout with something that is not one.
  let initial =
    open_recording(Model(..launched, clipboard: TerminalClipboard), record)
    |> start_herdr_reporter

  let _ =
    app.run_buffered_cursor_adaptive(
      default.new_with_options(backend.Options(mouse: True, paste: True)),
      initial,
      view,
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
    view: view,
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
        Error(reason) -> append_error(model, reason)
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
    ["ext", ..rest] -> Forward(arguments: rest)
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
    Error(reason) -> append_error(base, reason)
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
      append_error(base, reason)
    }
    Ok(host) -> {
      let model = Model(..base, daemon_host: Some(host))
      case selected {
        "" -> load_catalogue(model, "", None)
        id -> begin_open(model, id)
      }
    }
  }
}

fn begin_open(model: Model, session: String) -> Model {
  let model = cancel_pending(model, "target change from " <> model.session)
  case attachment.busy(model.candidate), model.daemon_host {
    True, _ -> append_error(model, "a session switch is already in progress")
    False, None -> append_error(model, "daemon control is disconnected")
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

fn load_catalogue(model: Model, after: String, revision: Option(Int)) -> Model {
  load_catalogue_after(model, after, revision, None)
}

// Rename and its refreshed page share the existing bounded metadata worker.
// The mutation is sent once; a lost response never triggers an automatic retry.
fn load_catalogue_after(
  model: Model,
  after: String,
  revision: Option(Int),
  rename: Option(control_protocol.Command),
) -> Model {
  case model.control_request, model.daemon_host {
    Some(_), _ -> append_error(model, "a catalogue page is already loading")
    None, None -> append_error(model, "daemon control is disconnected")
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
            use Nil <- result.try(case rename {
              None -> Ok(Nil)
              Some(command) ->
                daemon.request(daemon_selection.control(host), command, 5000)
                |> result.map_error(daemon_selection.failure)
                |> result.replace(Nil)
            })
            use reply <- result.try(
              daemon.request(
                daemon_selection.control(host),
                control_protocol.ListSessions(after, revision),
                5000,
              )
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
            Ok(PageLoaded(page, selected))
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
fn begin_delete(model: Model, session: String) -> Model {
  case model.control_request, model.daemon_host {
    Some(_), _ -> append_error(model, "a catalogue request is already running")
    None, None -> append_error(model, "daemon control is disconnected")
    None, Some(host) -> {
      let cancel = weft.cancel_signal()
      let replies = process.new_subject()
      let _relay =
        weft.new([
          fn() {
            use host <- daemon_selection.with_live_control(host)
            use id <- result.map(daemon_selection.delete(host, session))
            SessionDeleted(id)
          },
        ])
        |> weft.deadline(85_000)
        |> weft.cancel_with(cancel)
        |> weft.start_relayed(replies)
      Model(
        ..model,
        control_request: Some(ControlRequest(cancel, replies, None)),
        notice: "stopping and deleting session " <> session,
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
          append_error(
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
    Some(Ok(PageLoaded(page, selected))) ->
      Model(
        ..model,
        overlay: DaemonSelector(session_selector.new(
          session_selector.prioritize(page, model.workspace.path),
          selected,
        )),
        notice: "Enter opens the highlighted session · n creates · d deletes",
      )
      |> invalidate_frame

    // The row is dropped from the page already on screen rather than by
    // re-listing: the reply proves this identity is gone, and a fresh page
    // would move every other row under the operator's cursor.
    Some(Ok(SessionDeleted(id))) ->
      Model(
        ..model,
        overlay: case model.overlay {
          DaemonSelector(selector) ->
            DaemonSelector(session_selector.without(selector, id))
          NoOverlay
          | ModelSelector(_)
          | AgentInspector(_)
          | ApprovalInspector(_)
          | SessionSelector(_) -> model.overlay
        },
        notice: "deleted session " <> id,
      )
      |> invalidate_frame
    Some(Error(reason)) -> append_error(model, reason)
    None -> append_error(model, "control job ended without an outcome")
  }
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
    Error(reason) -> append_error(model, reason)
    Ok(config) -> create_session_configured(model, config)
  }
}

fn create_session_configured(model: Model, config: String) -> Model {
  let model = cancel_pending(model, "target change from " <> model.session)
  case model.creation_key, model.daemon_host, attachment.busy(model.candidate) {
    Some(key), _, _ ->
      append_error(
        model,
        "reconcile prior creation key before creating again: " <> key,
      )
    None, None, _ -> append_error(model, "daemon control is disconnected")
    None, Some(_), True ->
      append_error(model, "a session switch is already in progress")
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

// The frame on screen is whatever `refresh_frame_cache` last decided to
// render, including a frame it deliberately left stale to pace a burst. The
// view therefore never consults the revision: rendering here would undo the
// deferral, and would also build a frame nobody caches. Only a screen etui
// reports that the cache was not drawn for falls through to a fresh render.
/// Returns the frame for one screen, cached or freshly rendered.
///
/// ## Examples
///
/// ```gleam
/// let #(frame, cursor) = tui.view(model, geometry.rect_new(0, 0, 80, 24))
/// ```
@internal
pub fn view(
  model: Model,
  screen: Rect,
) -> #(buffer.Buffer, Result(geometry.Position, Nil)) {
  case model.frame_cache {
    Some(FrameCache(screen: cached_screen, rendered:, ..)) ->
      cached_frame(rendered, cached_screen, screen, fn() {
        render_frame(model, screen)
      })
    None -> render_frame(model, screen)
  }
}

/// Reuses a completed frame while it was rendered for this screen.
///
/// The cached tuple is returned directly rather than reconstructed, preserving
/// the Buffer term identity that etui uses as its constant-time diff fast path.
/// Whether the cache is current or deliberately stale is `frame_decision`'s
/// question, answered when the event was handled, not here.
@internal
pub fn cached_frame(
  cached: #(buffer.Buffer, Result(geometry.Position, Nil)),
  cached_screen: Rect,
  screen: Rect,
  build: fn() -> #(buffer.Buffer, Result(geometry.Position, Nil)),
) -> #(buffer.Buffer, Result(geometry.Position, Nil)) {
  case cached_screen == screen {
    True -> cached
    False -> build()
  }
}

fn render_frame(
  model: Model,
  screen: Rect,
) -> #(buffer.Buffer, Result(geometry.Position, Nil)) {
  let #(header_area, body_area, input_area, footer_area) = layout(screen, model)
  let #(transcript_panel, agent_panel, changes_panel) =
    body_layout(body_area, model)
  let transcript_area = panel_inner(transcript_panel)
  let #(pending_area, composer_area) =
    pending_layout(panel_inner(input_area), model)
  let #(paste_area, editor_area) =
    input_layout(composer_area, model.attachments)

  // The editor is wrapped to the cells the chip leaves it, never resized to
  // fit: the source text and cursor stay exactly what history will replay.
  let input_view = input_view_state(model.input, editor_area.size.width)
  let editor =
    text_area.textarea_new()
    |> text_area.with_max_lines(0)
    |> text_area.with_colors(theme.paper, style.Default)
    |> text_area.with_cursor_style(style.new(
      theme.graphite,
      theme.signal,
      style.bold(),
    ))

  // Paint order is also z-order: the canvas owns every cell, the panels draw
  // only their borders over it, and the palette and overlays land last.
  let base =
    repaint_canvas(screen, model.repaint_phase)
    |> render_header(header_area, model)
    |> render_panel_border(
      transcript_panel,
      transcript_title(model),
      theme.quiet,
    )
    |> render_transcript(transcript_area, model)
    |> render_agent_rail(agent_panel, model)
    |> render_changes_panel(changes_panel, model)
    |> render_panel_border(input_area, input_title(model), theme.signal)
    |> render_pending_band(pending_area, model)
    |> render_paste_chip(paste_area, model.attachments)
    |> text_area.render(editor_area, editor, input_view)
    |> render_footer(footer_area, model)
    |> render_command_palette(body_area, model)
  let rendered = case model.overlay {
    NoOverlay -> base
    ModelSelector(selector) -> model_selector.render(base, screen, selector)
    AgentInspector(selected) ->
      agents.render_overlay(
        base,
        screen,
        model.strands,
        model.active_strand,
        selected,
      )
    SessionSelector(selector) -> sessions.render(base, screen, selector)
    DaemonSelector(selector) -> session_selector.render(base, screen, selector)
    ApprovalInspector(panel) -> approval_panel.render(base, screen, panel)
  }

  // Selected cells keep their original contents. A growing pending/reviewer
  // band may shrink the pane, so restore only its current intersection; the
  // selected transcript must never paint over newly visible controls.
  let rendered = case model.selection {
    Some(selected) -> {
      let current_area =
        [
          transcript_area,
          panel_inner(agent_panel),
          panel_inner(changes_panel),
          panel_inner(input_area),
        ]
        |> list.find(fn(area) { area.position == selected.area.position })
        |> result.unwrap(selected.area)
      case
        model.selection_frame,
        geometry.intersect(selected.area, current_area)
      {
        Some(original), Ok(area) ->
          buffer.blit(
            rendered,
            selection.highlight(original, selected),
            area,
            area.position,
          )
        None, _ -> selection.highlight(rendered, selected)
        Some(_), Error(Nil) -> rendered
      }
    }
    None -> rendered
  }
  let cursor = case model.overlay {
    NoOverlay -> text_area.cursor_screen_pos(input_view, editor_area)
    ModelSelector(_)
    | AgentInspector(_)
    | SessionSelector(_)
    | DaemonSelector(_)
    | ApprovalInspector(_) -> Error(Nil)
  }
  let #(rendered, cursor) =
    render_summary_surface(rendered, cursor, screen, model)
  let #(rendered, cursor) =
    render_context_surface(rendered, cursor, screen, model)
  render_queue_surface(rendered, cursor, screen, model)
}

/// The area inside a one-cell rounded border.
///
/// ## Examples
///
/// ```gleam
/// assert tui.panel_inner(geometry.rect_new(0, 1, 10, 5))
///   == geometry.rect_new(1, 2, 8, 3)
/// ```
@internal
pub fn panel_inner(area: Rect) -> Rect {
  geometry.rect_new(
    area.position.x + 1,
    area.position.y + 1,
    int.max(0, area.size.width - 2),
    int.max(0, area.size.height - 2),
  )
}

/// Draws a rounded border and a left-aligned title, leaving the interior alone.
///
/// This is etui's `block.render` without its interior clear. That clear walks
/// every inner cell, repainting an area the canvas already owns; `make
/// bench-tui` measures the area-dependent work this removes. Leaving the
/// interior to the canvas also keeps its repaint phase on vacated cells, which
/// is what lets a detail-mode toggle rewrite positions the diff would otherwise
/// retain. The bytes on the wire for a steady frame are the same as the
/// block's; the test pins that.
///
/// ## Examples
///
/// ```gleam
/// let screen = geometry.rect_new(0, 0, 12, 3)
/// buffer.buffer_new(screen)
/// |> tui.render_panel_border(screen, " title ", theme.quiet)
/// ```
@internal
pub fn render_panel_border(
  buf: buffer.Buffer,
  area: Rect,
  title: String,
  color: style.Color,
) -> buffer.Buffer {
  let width = area.size.width
  let height = area.size.height
  case width < 2 || height < 2 {
    True -> buf
    False -> {
      let x0 = area.position.x
      let y0 = area.position.y
      let x_right = geometry.right(area) - 1
      let y_bottom = geometry.bottom(area) - 1
      let border = style.new(color, style.Default, style.none())
      let horizontal = string.repeat("─", width - 2)

      // One string write per edge row is one array pass each, and the two
      // verticals are one cell per row: a few dozen writes for the whole
      // frame of the panel instead of one per interior cell.
      let framed =
        buf
        |> buffer.set_string(
          geometry.Position(x0, y0),
          "╭" <> horizontal <> "╮",
          border,
        )
        |> buffer.set_string(
          geometry.Position(x0, y_bottom),
          "╰" <> horizontal <> "╯",
          border,
        )
        |> render_vertical_edges(x0, x_right, y0 + 1, y_bottom, border)

      // The title sits one cell in from the corner and is cut to the top
      // edge with an ellipsis, exactly where the block would have put it.
      let title_width = width - 2
      buffer.set_string(
        framed,
        geometry.Position(x0 + 1, y0),
        text.truncate(title, title_width, "…"),
        border,
      )
    }
  }
}

fn render_vertical_edges(
  buf: buffer.Buffer,
  x_left: Int,
  x_right: Int,
  y: Int,
  y_end: Int,
  border: style.Style,
) -> buffer.Buffer {
  case y >= y_end {
    True -> buf
    False ->
      buf
      |> buffer.set_string(geometry.Position(x_left, y), "│", border)
      |> buffer.set_string(geometry.Position(x_right, y), "│", border)
      |> render_vertical_edges(x_left, x_right, y + 1, y_end, border)
  }
}

fn layout(screen: Rect, model: Model) -> #(Rect, Rect, Rect, Rect) {
  case
    geometry.split_v(screen, [
      Length(1),
      Fill,
      Length(input_height(model)),
      Length(footer_height(screen.size.width)),
    ])
  {
    [header, body, input, footer] -> #(header, body, input, footer)
    _ -> #(screen, screen, screen, screen)
  }
}

// The changes pane gets a readable column without squeezing the conversation
// below sixty-eight cells. It borrows the optional rail's place; closing it
// restores the operator's rail preference rather than changing that setting.
fn body_layout(body: Rect, model: Model) -> #(Rect, Rect, Rect) {
  let changes = diff_pane_width(model)
  let rail = case model.agent_rail_visible && model.width >= 100 {
    True -> 34
    False -> 0
  }
  let secondary = case changes > 0 {
    True -> changes
    False -> rail
  }
  case geometry.split_h(body, [Fill, Length(secondary)]) {
    [main, side] if changes > 0 -> #(main, geometry.rect_zero(), side)
    [main, side] -> #(main, side, geometry.rect_zero())
    _ -> #(body, geometry.rect_zero(), geometry.rect_zero())
  }
}

fn diff_pane_width(model: Model) -> Int {
  case model.diff_view != DiffHidden && model.width >= 140 {
    True -> int.min(72, model.width / 2)
    False -> 0
  }
}

fn diff_shown(model: Model) -> Bool {
  model.diff_view == DiffVisible || diff_pane_width(model) > 0
}

fn main_shows_diff(model: Model) -> Bool {
  model.diff_view == DiffVisible && diff_pane_width(model) == 0
}

fn render_changes_panel(
  buf: buffer.Buffer,
  area: Rect,
  model: Model,
) -> buffer.Buffer {
  case area.size.width > 0 {
    True ->
      buf
      |> render_panel_border(area, diff_title(model), theme.quiet)
      |> render_diff_view(panel_inner(area), model)
    False -> buf
  }
}

fn render_agent_rail(
  buf: buffer.Buffer,
  area: Rect,
  model: Model,
) -> buffer.Buffer {
  case area.size.width > 0 {
    True -> agents.render_rail(buf, area, model.strands, model.active_strand)
    False -> buf
  }
}

fn render_header(
  buf: buffer.Buffer,
  area: Rect,
  model: Model,
) -> buffer.Buffer {
  let bar =
    statusbar.statusbar_new()
    |> statusbar.with_style(theme.paper, theme.graphite)
    |> statusbar.with_left([
      span.line_new([span.span_styled(" ◆ ", theme.signal_bold())]),
    ])
    |> statusbar.with_center([
      span.line_new([
        span.span_styled("session ", theme.quiet_text()),
        span.span_plain(text_hygiene.single_line(model.session)),
      ]),
    ])
    |> statusbar.with_right([
      span.line_new([
        span.span_styled(
          " "
            <> text_hygiene.single_line(model.current_model)
            <> " · "
            <> int.to_string(model.width)
            <> "×"
            <> int.to_string(model.height)
            <> " ",
          theme.quiet_text(),
        ),
      ]),
    ])
  statusbar.render(buf, area, bar)
}

fn render_transcript(
  buf: buffer.Buffer,
  area: Rect,
  model: Model,
) -> buffer.Buffer {
  case main_shows_diff(model) {
    True -> render_diff_view(buf, area, model)
    False ->
      render_rows(
        buf,
        area,
        model.rendered_rows,
        model.scroll_offset + viewport_backlog(model),
      )
  }
}

fn render_rows(
  buf: buffer.Buffer,
  area: Rect,
  rows: List(span.Line),
  offset: Int,
) -> buffer.Buffer {
  let visible =
    rows
    |> list.drop(offset)
    |> list.take(area.size.height)
    |> list.reverse
    |> list.map(fn(line) {
      case line.spans {
        [first, ..] if first.style.bg == theme.user_background ->
          span.Line(
            ..line,
            spans: list.append(line.spans, [
              span.span_styled(
                string.repeat(
                  " ",
                  int.max(0, area.size.width - span.line_width(line)),
                ),
                first.style,
              ),
            ]),
          )
        _ -> line
      }
    })
  paragraph.render_styled(buf, area, visible)
}

fn transcript_title(model: Model) -> String {
  let surface = case model.help_open, model.notes_open, main_shows_diff(model) {
    True, _, _ -> "help"
    False, True, _ -> "agent notes"
    False, False, True -> diff_title(model)
    False, False, False -> "transcript"
  }
  " "
  <> surface
  <> " / "
  <> text_hygiene.single_line(model.active_strand)
  <> " "
}

fn transcript_content(lines: List(Line), width: Int) -> span.Text {
  lines
  |> list.flat_map(render_line(_, width))
  |> span.text_new
}

fn render_line(line: Line, width: Int) -> List(span.Line) {
  let #(mark, mark_style) = case line.speaker {
    System -> #("◇ ", theme.quiet_text())
    User -> #("› ", theme.signal_bold())
    Assistant -> #("◆ Agent  ", theme.current_bold())
    Reasoning -> #("∴ Reasoning  ", theme.quiet_text())
    ReasoningDigest -> #(markdown.digest_mark, theme.quiet_text())
    ToolCall -> #("● ", theme.success_text())
    ToolResult -> #("└ ", theme.quiet_text())
    ToolDetail | ToolPatch -> #("  ", theme.quiet_text())
    ToolFailure -> #("└ × ", theme.danger_text())
    Failure -> #("! error  ", theme.danger_text())
  }
  case line.speaker {
    User -> {
      let body_style =
        style.new(theme.paper, theme.user_background, style.none())
      let label_style =
        style.new(theme.signal, theme.user_background, style.bold())

      // A separate label and shaded block identify the speaker without
      // depending on hue. Wrapped rows retain the same background, and copy
      // continues to read the exact visible frame rather than another layout.
      [
        span.line_plain(""),
        span.line_new([span.span_styled(" › User", label_style)]),
        ..line.text
        |> text_hygiene.multiline
        |> string.split("\n")
        |> list.map(fn(text) {
          span.line_new([span.span_styled("   " <> text, body_style)])
        })
        |> list.append([span.line_plain("")])
      ]
    }
    Assistant | Reasoning -> [
      span.line_plain(""),
      ..markdown.render(line.text, width - string.length(mark))
      |> prefix_rendered_lines(mark, mark_style)
    ]
    ToolPatch -> markdown.diff(line.text)

    // A digest stands in for a whole reasoning block, and the one property
    // it has to keep is its height: the collapsed live row and the
    // collapsed settled row are the same row with different words in it.
    // So it is drawn literally, with no blank above or below it and no
    // Markdown pass which could answer a stray fence with a second row.
    ReasoningDigest -> [digest_row(line.text, mark, mark_style, width)]

    ToolDetail ->
      markdown.render(line.text, width - string.length(mark))
      |> prefix_rendered_lines(mark, mark_style)
    System | ToolCall | ToolResult | ToolFailure | Failure ->
      line.text
      |> text_hygiene.multiline
      |> string.split("\n")
      |> list.index_map(fn(text, index) {
        let prefix = case index == 0 {
          True -> mark
          False -> string.repeat(" ", string.length(mark))
        }
        span.line_new([
          span.span_styled(prefix, mark_style),
          span.span_plain(text),
        ])
      })
      |> list.append(case line.speaker {
        ToolCall | ToolResult | ToolFailure -> []
        System
        | User
        | Reasoning
        | ReasoningDigest
        | Failure
        | Assistant
        | ToolDetail
        | ToolPatch -> [
          span.line_plain(""),
        ]
      })
  }
}

// One row, whatever the pane is. Clipping rather than wrapping is what makes
// the height invariant hold at every width: bounding the digest text by a
// character count only moves the width at which it wraps, because the mark
// and the expand hint are a further thirty-four cells the count knows nothing
// about. The hint is the part a reader acts on, so the opening line gives up
// cells for it; when the pane cannot hold even the hint, the whole body is
// clipped and the hint goes with it rather than crowding out the words.
fn digest_row(
  text: String,
  mark: String,
  mark_style: style.Style,
  width: Int,
) -> span.Line {
  let body = text_hygiene.single_line(text)
  let room = width - text.cell_width(mark)
  let #(opening, hint) = case string.ends_with(body, expand_hint) {
    True -> #(string.drop_end(body, string.length(expand_hint)), expand_hint)
    False -> #(body, "")
  }
  let for_opening = room - text.cell_width(hint)
  let clipped = case for_opening > 0 {
    True -> text.truncate(opening, for_opening, "…") <> hint
    False -> text.truncate(body, room, "…")
  }
  span.line_new([
    span.span_styled(mark, mark_style),
    span.span_plain(clipped),
  ])
}

fn prefix_rendered_lines(
  lines: List(span.Line),
  mark: String,
  mark_style: style.Style,
) -> List(span.Line) {
  lines
  |> list.index_map(fn(line, index) {
    let span.Line(spans:, alignment:) = line
    let prefix = case index == 0 {
      True -> mark
      False -> string.repeat(" ", string.length(mark))
    }
    span.Line(
      spans: [span.span_styled(prefix, mark_style), ..spans],
      alignment:,
    )
  })
}

fn help_content() -> span.Text {
  let command_lines =
    command.help_text()
    |> string.split("\n")
    |> list.map(fn(line) {
      case string.split_once(line, " ") {
        Ok(#(name, rest)) ->
          span.line_new([
            span.span_styled(name, theme.signal_bold()),
            span.span_plain(" " <> rest),
          ])
        Error(Nil) -> span.line_plain(line)
      }
    })
  span.text_new([
    span.line_new([
      span.span_styled("SLASH COMMANDS", theme.current_bold()),
      span.span_styled(" · press esc to close", theme.quiet_text()),
    ]),
    span.line_plain(""),
    ..command_lines
  ])
}

fn refresh_notes(model: Model) -> Model {
  send_frame(
    Model(..model, notice: "refreshing notes"),
    protocol.notes(model.next_id, model.active_strand),
  )
}

fn notes_content(model: Model, width: Int) -> span.Text {
  case model.note_board {
    None -> historical_notes_content(model, width)
    Some(board) -> current_notes_content(board, model, width)
  }
}

fn note_read_status(board: notes_view.Board, model: Model) -> String {
  case model.captured {
    Some(#(cut, _)) if cut.next_seq - 1 > board.as_of ->
      "Session advanced since this read · r refreshes. Saved plans may need correction."
    _ ->
      "Last observed note values. Saved plans may need correction as work progresses."
  }
}

// Only the accepted operation's own revision establishes that a note predates
// this turn. Unrelated session activity says nothing about the note's accuracy.
fn note_turn_relation(seq: Int, model: Model) -> String {
  case model.captured {
    None -> ""
    Some(#(_, view)) -> {
      let started = {
        use current <- result.try(dict.get(view.operations, model.active_strand))
        list.find(view.cells, fn(cell) {
          cell.namespace == register.OpMeta && cell.key == current
        })
      }
      case started {
        Ok(cell) if seq < cell.seq -> " · written before current turn"
        _ -> ""
      }
    }
  }
}

// Raw inspection keeps the JSON representation but gives its structure rows.
// Excerpts never enter this path because a cut value may not parse completely.
fn raw_note_line(text: String) -> Line {
  case json.parse(text) {
    Ok(value) ->
      Line(ToolDetail, "```json\n" <> pretty_json(value, 0) <> "\n```")
    Error(_) -> Line(ToolResult, text)
  }
}

fn current_notes_content(
  board: notes_view.Board,
  model: Model,
  width: Int,
) -> span.Text {
  let active_strand = model.active_strand
  case board.strand == active_strand {
    False ->
      transcript_content([Line(System, "refresh notes for this strand")], width)
    True -> {
      let heading =
        "notes for "
        <> board.strand
        <> " · read at revision "
        <> int.to_string(board.as_of)
        <> " · r to refresh"
      let rows =
        list.flat_map(board.notes, fn(note) {
          let extent = case note.extent {
            notes_view.Complete -> ""
            notes_view.Excerpt -> " · excerpt"
          }
          [
            Line(
              System,
              note.key
                <> " · updated at revision "
                <> int.to_string(note.seq)
                <> note_turn_relation(note.seq, model)
                <> extent,
            ),
            case model.details_expanded, note.extent {
              _, notes_view.Excerpt -> Line(ToolResult, note.text)
              True, notes_view.Complete -> raw_note_line(note.text)
              False, notes_view.Complete ->
                Line(ToolDetail, notes_view.readable(note.text))
            },
          ]
        })
      let omitted = board.total - list.length(board.notes)
      let tail = case omitted > 0 {
        True -> [
          Line(
            System,
            int.to_string(omitted) <> " more notes exceed this display budget",
          ),
        ]
        False -> []
      }
      transcript_content(
        [
          Line(System, heading),
          Line(System, note_read_status(board, model)),
          ..list.append(rows, tail)
        ],
        width,
      )
    }
  }
}

fn historical_notes_content(model: Model, width: Int) -> span.Text {
  let latest =
    model.records
    |> list.find_map(fn(record) {
      let protocol.EntryRecord(strand:, entry:) = record
      case strand == model.active_strand, entry {
        True, entry.MessageEntry(message: value, ..) ->
          agent_notes_payload(value) |> option.to_result(Nil)
        _, _ -> Error(Nil)
      }
    })
    |> result.map(Some)
    |> result.unwrap(None)
  case latest {
    Some(payload) ->
      transcript_content(
        [
          Line(System, "historical run-start digest · r to fetch current notes"),
          case model.details_expanded {
            True -> Line(ToolDetail, "```text\n" <> payload <> "\n```")
            False -> Line(ToolDetail, notes_view.historical(payload))
          },
        ],
        width,
      )
    None ->
      transcript_content(
        [
          Line(
            System,
            "no agent notes are available for " <> model.active_strand,
          ),
        ],
        width,
      )
  }
}

fn render_footer(
  buf: buffer.Buffer,
  area: Rect,
  model: Model,
) -> buffer.Buffer {
  let #(project, model_name, usage, status, combined) = footer_sections(model)
  case area.size.height {
    1 -> render_single_footer(buf, area, project, usage, combined)
    2 -> render_stacked_footer(buf, area, project, model_name, usage, status)
    _ -> render_split_footer(buf, area, project, model_name, usage, status)
  }
}

fn footer_sections(
  model: Model,
) -> #(span.Line, span.Line, span.Line, span.Line, span.Line) {
  let project_text =
    model.workspace |> workspace.label |> text_hygiene.single_line
  let model_text = text_hygiene.single_line(model.current_model)
  let status_text = model |> model_footer_status |> text_hygiene.single_line
  let project =
    span.line_new([
      span.span_styled(
        " " <> compact(project_text, footer_project_limit(model.width)) <> " ",
        theme.footer_text(),
      ),
    ])
  let model_name =
    span.line_new([
      span.span_styled(
        " " <> compact(model_text, 28) <> " ",
        theme.footer_text(),
      ),
    ])
  let usage =
    span.line_new([
      span.span_styled(
        " "
          <> compact(
          context_view.footer(model.context)
            <> " · "
            <> usage_summary(model.usage)
            <> output_rate_label(model.output_rate_tps),
          footer_usage_limit(model.width),
        )
          <> " ",
        theme.footer_text(),
      ),
    ])
  let status =
    span.line_new([
      span.span_styled(" " <> status_text <> " ", theme.footer_text()),
    ])
  let combined =
    span.line_new([
      span.span_styled(
        " " <> compact(model_text, 28) <> " · " <> status_text <> " ",
        theme.footer_text(),
      ),
    ])
  #(project, model_name, usage, status, combined)
}

fn model_footer_status(model: Model) -> String {
  footer_status(
    model.agent_summary,
    model.notice,
    footer_status_limit(model.width),
  )
}

/// Preserves transient operator feedback beside the agent summary, within
/// the cells the footer's layout leaves it.
///
/// ## Examples
///
/// ```gleam
/// assert tui.footer_status("0 live", "copied 2 lines", 40)
///   == "0 live · copied 2 lines"
/// ```
@internal
pub fn footer_status(
  agent_summary: String,
  notice: String,
  limit: Int,
) -> String {
  let safe_summary = text_hygiene.single_line(agent_summary)
  let safe_notice = text_hygiene.single_line(notice)
  case string.starts_with(safe_notice, "model: ") {
    True -> compact(safe_summary, limit)
    False -> compact(safe_summary <> " · " <> safe_notice, limit)
  }
}

/// The cells the footer's workspace label may take at a terminal width.
///
/// On one row the label shares the row with usage and the model, so its
/// cap holds. On two or three rows it shares the primary row with the model
/// alone, and every column past the two caps is otherwise idle: a long
/// `path (branch)` cut to sixty-eight cells beside fifty blank ones was the
/// same fixed cap outliving its reason that `footer_status_limit` retired.
///
/// ## Examples
///
/// ```gleam
/// assert tui.footer_project_limit(213) == 68
/// assert tui.footer_project_limit(150) == 118
/// ```
@internal
pub fn footer_project_limit(width: Int) -> Int {
  let floor = footer_project_cells - 2
  case footer_rows(width) {
    1 -> floor
    _ -> int.max(floor, width - footer_model_cells - 2)
  }
}

/// The cells the footer status may take at a terminal width.
///
/// The row count is decided from fixed caps so it cannot flap with the
/// notice text, and the status keeps the cap's forty cells as a floor. A
/// terminal wider than the single row needs hands the status every spare
/// cell, because a notice such as `steer captured; waiting for stop` cut
/// to forty cells on a 246-column screen was the fixed cap outliving its
/// reason. On two rows the status shares its row with usage; on three it
/// has the row to itself.
///
/// ## Examples
///
/// ```gleam
/// assert tui.footer_status_limit(213) == 40
/// assert tui.footer_status_limit(246) == 73
/// ```
@internal
pub fn footer_status_limit(width: Int) -> Int {
  let floor = footer_status_cells - 2
  case footer_rows(width) {
    1 -> floor + width - footer_single_row_cells()
    2 -> int.max(floor, width - footer_usage_cells - 2)
    _ -> int.max(floor, width - 2)
  }
}

/// The cells the footer's cumulative usage may take at a terminal width.
///
/// On one and two rows the section shares its row with others and the fixed
/// cap is what keeps the row count decidable from the width alone. On three
/// rows the usage has the row to itself and that row can be narrower than
/// the cap, so the cap comes down to the width: at fifty columns a cap of
/// sixty-eight never fired, and the render buffer clipped the last digit of
/// `cache 0/0` with no ellipsis to say anything had been dropped.
///
/// ## Examples
///
/// ```gleam
/// assert tui.footer_usage_limit(213) == 68
/// assert tui.footer_usage_limit(50) == 48
/// ```
@internal
pub fn footer_usage_limit(width: Int) -> Int {
  let cap = footer_usage_cells - 2
  case footer_rows(width) {
    1 | 2 -> cap
    _ -> int.min(cap, width - 2)
  }
}

fn footer_height(width: Int) -> Int {
  footer_rows(width)
}

/// The most cells each footer section may take, including the space each
/// side of it. `footer_sections` compacts every section to these, so the
/// row count below can be decided from the width alone.
const footer_project_cells = 70

const footer_model_cells = 30

const footer_usage_cells = 70

const footer_status_cells = 42

// Every section plus one separating cell: the width at which the footer
// fits on one row. A function because a Gleam constant cannot add.
fn footer_single_row_cells() -> Int {
  footer_project_cells
  + footer_model_cells
  + footer_usage_cells
  + footer_status_cells
  + 1
}

/// The rows the footer takes at a terminal width — one, two or three —
/// decided from the width and the sections' fixed caps, never from what
/// the sections happen to say.
///
/// That is the whole point of the caps. Measuring the rendered text
/// instead made the footer flip between one row and two as a turn ran:
/// `main: assistant` is wider than `main: done`, a `tok/s` suffix appears
/// once a generation settles, and each change pushed the total across
/// the threshold and moved the prompt box up or down under the operator's
/// hands. A layout that depends only on the window can only change when
/// the window does.
///
/// ## Examples
///
/// ```gleam
/// assert tui.footer_rows(213) == 1
/// assert tui.footer_rows(133) == 2
/// assert tui.footer_rows(40) == 3
/// ```
///
@internal
pub fn footer_rows(width: Int) -> Int {
  let single = footer_single_row_cells()
  let pair =
    int.max(
      footer_project_cells + footer_model_cells,
      footer_usage_cells + footer_status_cells,
    )
  case width >= single, width >= pair {
    True, _ -> 1
    False, True -> 2
    False, False -> 3
  }
}

fn render_single_footer(
  buf: buffer.Buffer,
  area: Rect,
  left: span.Line,
  usage: span.Line,
  right: span.Line,
) -> buffer.Buffer {
  let bar =
    statusbar.statusbar_new()
    |> statusbar.with_style(theme.paper, theme.graphite)
    |> statusbar.with_left([left])
    |> statusbar.with_center([usage])
    |> statusbar.with_right([right])
  statusbar.render(buf, area, bar)
}

fn render_stacked_footer(
  buf: buffer.Buffer,
  area: Rect,
  project: span.Line,
  model_name: span.Line,
  usage: span.Line,
  status: span.Line,
) -> buffer.Buffer {
  let primary =
    statusbar.statusbar_new()
    |> statusbar.with_style(theme.paper, theme.graphite)
    |> statusbar.with_left([project])
    |> statusbar.with_right([model_name])
  let usage_bar =
    statusbar.statusbar_new()
    |> statusbar.with_style(theme.paper, theme.graphite)
    |> statusbar.with_left([usage])
    |> statusbar.with_right([status])
  case geometry.split_v(area, [Length(1), Length(1)]) {
    [primary_area, usage_area] ->
      buf
      |> statusbar.render(primary_area, primary)
      |> statusbar.render(usage_area, usage_bar)
    _ -> statusbar.render(buf, area, primary)
  }
}

fn render_split_footer(
  buf: buffer.Buffer,
  area: Rect,
  project: span.Line,
  model_name: span.Line,
  usage: span.Line,
  status: span.Line,
) -> buffer.Buffer {
  let primary =
    statusbar.statusbar_new()
    |> statusbar.with_style(theme.paper, theme.graphite)
    |> statusbar.with_left([project])
    |> statusbar.with_right([model_name])
  let usage_bar =
    statusbar.statusbar_new()
    |> statusbar.with_style(theme.paper, theme.graphite)
    |> statusbar.with_left([usage])
  let status_bar =
    statusbar.statusbar_new()
    |> statusbar.with_style(theme.paper, theme.graphite)
    |> statusbar.with_left([status])
  case geometry.split_v(area, [Length(1), Length(1), Length(1)]) {
    [primary_area, usage_area, status_area] ->
      buf
      |> statusbar.render(primary_area, primary)
      |> statusbar.render(usage_area, usage_bar)
      |> statusbar.render(status_area, status_bar)
    _ -> statusbar.render(buf, area, primary)
  }
}

// Etui's incremental diff can retain cells when one action replaces most of
// the viewport. Detail mode is exactly that action: bounded tool summaries
// become full stack traces in one frame. Alternating an invisible modifier on
// otherwise blank canvas cells makes those vacated positions explicit diff
// writes without forcing every steady streaming frame to repaint.
fn repaint_canvas(screen: Rect, phase: Bool) -> buffer.Buffer {
  let modifier = case phase {
    True -> style.dim()
    False -> style.none()
  }
  buffer.buffer_new_filled(
    screen,
    " ",
    style.new(style.Default, style.Default, modifier),
  )
}

/// Divides the prompt panel's interior between attachment chips and the editor.
///
/// The chip row is stacked above the editor rather than placed beside it. A
/// chip summary carries a filename, a mime type and a byte count, so a side by
/// side split gave the chip most of the panel and left the editor a column or
/// two — the operator could no longer read the sentence they were typing. A
/// full width editor with one row of chips above it costs a single terminal
/// row and never depends on how long the filename is.
///
/// ## Examples
///
/// ```gleam
/// let #(chips, editor) = tui.input_layout(area, [])
/// assert chips == geometry.rect_zero()
/// assert editor == area
/// ```
///
@internal
pub fn input_layout(
  area: Rect,
  attachments: List(composer.Attachment),
) -> #(Rect, Rect) {
  case composer.summary(attachments) {
    None -> #(geometry.rect_zero(), area)

    // A panel one row tall has nothing to give the chip row. Yielding the
    // whole area to the editor keeps the prompt usable; the chip is dropped
    // for this frame rather than the text the operator is writing.
    Some(_) ->
      case geometry.split_v(area, [Length(1), Fill]) {
        [chip_area, editor_area] -> #(chip_area, editor_area)
        [] | [_] | [_, _, _, ..] -> #(geometry.rect_zero(), area)
      }
  }
}

// The editor owns the unwrapped source text, while its view is wrapped to the
// current terminal width. Keeping this transformation render-only preserves
// the exact prompt bytes used by editing, history, and submission.
@internal
pub fn input_view_state(
  state: text_area.TextAreaState,
  available_width: Int,
) -> text_area.TextAreaState {
  let width = int.max(2, available_width)
  let text_area.TextAreaState(lines:, cursor_x:, cursor_y:) = state
  let current_line =
    lines |> list.drop(cursor_y) |> list.first |> result.unwrap("")
  let cursor_prefix = text.truncate(current_line, cursor_x, "")
  let #(cursor_row, wrapped_cursor_x) = wrapped_cursor(cursor_prefix, width, 0)
  let rows_before =
    lines
    |> list.take(cursor_y)
    |> list.flat_map(hard_wrap_line(_, width))
    |> list.length
  let wrapped_lines =
    lines
    |> list.index_map(fn(line, index) {
      let wrapped = hard_wrap_line(line, width)
      case index == cursor_y, list.drop(wrapped, cursor_row) {
        True, [] -> list.append(wrapped, [""])
        _, _ -> wrapped
      }
    })
    |> list.flatten
  text_area.TextAreaState(
    lines: wrapped_lines,
    cursor_x: wrapped_cursor_x,
    cursor_y: rows_before + cursor_row,
  )
}

fn hard_wrap_line(line: String, width: Int) -> List(String) {
  case line {
    "" -> [""]
    _ -> hard_wrap_nonempty(line, width, [])
  }
}

fn hard_wrap_nonempty(
  line: String,
  width: Int,
  rows: List(String),
) -> List(String) {
  case line {
    "" -> list.reverse(rows)
    _ -> {
      let chunk = text.truncate(line, width, "")
      let rest = string.drop_start(line, string.length(chunk))
      hard_wrap_nonempty(rest, width, [chunk, ..rows])
    }
  }
}

fn wrapped_cursor(prefix: String, width: Int, rows: Int) -> #(Int, Int) {
  let prefix_width = text.cell_width(prefix)
  case prefix_width < width {
    True -> #(rows, prefix_width)
    False -> {
      let chunk = text.truncate(prefix, width, "")
      let rest = string.drop_start(prefix, string.length(chunk))
      wrapped_cursor(rest, width, rows + 1)
    }
  }
}

fn input_height(model: Model) -> Int {
  // The chip row is the height `input_layout` will take off the top of the
  // panel. Counting it here is what stops the split from stealing a row the
  // editor was already drawing text into.
  let chip_rows = case model.attachments {
    [] -> 0
    [_, ..] -> 1
  }

  let content_rows =
    model.input
    |> input_view_state(editor_content_width(model))
    |> text_area.line_count
    |> int.max(1)
    |> int.min(4)

  content_rows + 2 + chip_rows + pending_height(model)
}

fn pending_height(model: Model) -> Int {
  list.length(composer_status_lines(model))
}

fn composer_status_lines(model: Model) -> List(String) {
  let pending = case pending_status(model) {
    None -> []
    Some(text) -> [text]
  }
  list.append(
    reviewer_status.lines(model.reviewer_rows, model.active_strand),
    pending,
  )
}

fn pending_layout(area: Rect, model: Model) -> #(Rect, Rect) {
  case geometry.split_v(area, [Length(pending_height(model)), Fill]) {
    [status, composer] -> #(status, composer)
    _ -> #(geometry.rect_zero(), area)
  }
}

// Receipt is a server fact; sending and waiting for a free channel are local
// facts. Naming them separately prevents an accepted queue from looking lost.
fn pending_status(model: Model) -> Option(String) {
  case model.pending_submission, model.awaiting_outcome {
    Some(_), _ -> Some("Not sent yet · waiting for session sync · Esc cancels")
    None, Some(_) -> Some("Sent · waiting for receipt")
    None, None -> {
      case queue_rows(model) {
        [] -> None
        [first, ..rest] ->
          Some(
            "Received · "
            <> case first.kind {
              snapshot_view.Queue -> "queued after this turn"
              snapshot_view.Steer -> "steer before queued turns"
            }
            <> case rest {
              [] -> ""
              more -> " · +" <> int.to_string(list.length(more)) <> " pending"
            }
            <> " · /queue edits · "
            <> text_hygiene.single_line(first.text),
          )
      }
    }
  }
}

fn render_pending_band(
  buf: buffer.Buffer,
  area: Rect,
  model: Model,
) -> buffer.Buffer {
  paragraph.render_styled(
    buf,
    area,
    list.map(composer_status_lines(model), fn(status) {
      span.line_new([
        span.span_styled(compact(status, area.size.width), theme.quiet_text()),
      ])
    }),
  )
}

// Stacking the chips leaves the editor the full interior width, so the wrap
// the operator sees no longer depends on what is attached.
fn editor_content_width(model: Model) -> Int {
  int.max(2, model.width - 2)
}

fn input_title(model: Model) -> String {
  use <- bool.guard(
    model.peer == Disconnected,
    " Disconnected · /sessions to reconnect · draft retained ",
  )
  use <- bool.guard(
    reading_history(model),
    " ↓ Scrollback · click for latest · End with empty prompt ",
  )
  case
    active_interrupt(model),
    active_status_label(model),
    model.submission_mode
  {
    Some(_), _, _ -> " interrupting · enter steers after stop "
    None, None, _ -> " prompt · / commands "
    None, Some(_), SteerNow -> " steer this turn · enter steers · tab queues "
    None, Some(status), PromptNext ->
      " "
      <> activity_glyph(model.activity_frame)
      <> " "
      <> status
      <> " · turn"
      <> elapsed_label(model.activity_elapsed_s)
      <> " · enter queues · tab steers "
  }
}

/// How long the active strand has been busy, in the shape the prompt
/// border shows beside its phase: empty in the first second, then `(7s)`,
/// then `(1m 05s)` once a minute has passed.
///
/// ## Examples
///
/// ```gleam
/// assert tui.elapsed_label(0) == ""
/// assert tui.elapsed_label(7) == " (7s)"
/// assert tui.elapsed_label(65) == " (1m 05s)"
/// ```
///
@internal
pub fn elapsed_label(seconds: Int) -> String {
  case seconds <= 0, seconds >= 60 {
    True, _ -> ""
    False, False -> " (" <> int.to_string(seconds) <> "s)"
    False, True -> {
      let rest = seconds % 60
      let padded = case rest < 10 {
        True -> "0" <> int.to_string(rest)
        False -> int.to_string(rest)
      }
      " (" <> int.to_string(seconds / 60) <> "m " <> padded <> "s)"
    }
  }
}

/// Returns the low-motion activity indicator used by the prompt border.
@internal
pub fn activity_glyph(frame: Int) -> String {
  case int.modulo(frame / 3, 4) |> result.unwrap(0) {
    0 -> "◐"
    1 -> "◓"
    2 -> "◑"
    _ -> "◒"
  }
}

// The operation phase is authoritative for liveness, while the latest stream
// kind supplies the finer distinction the protocol phase cannot express. In
// particular, `assistant` begins before the first reasoning delta, so treating
// it as a completed response would make a steerable turn look stuck.
fn active_status_label(model: Model) -> Option(String) {
  case active_strand_phase(model) {
    None -> None
    Some("assistant") ->
      Some(case active_stream_kind(model) {
        Some("text") -> "responding"
        Some("tool_call") -> "calling tool"
        _ -> "thinking"
      })
    Some("tools") -> Some(running_tool_label(model))
    Some("starting") -> Some("starting")
    Some("checkpoint") -> Some("checkpointing")
    Some("compacting") -> Some("compacting")
    Some("awaiting_deferred") -> Some("waiting")
    Some("failure_drain") -> Some("finishing failure")
    Some("cancel_requested") -> Some("stopping")
    Some(phase) -> Some(text_hygiene.single_line(phase))
  }
}

fn running_tool_label(model: Model) -> String {
  let calls = case model.captured {
    None -> []
    Some(#(_, view)) ->
      case dict.get(view.operations, model.active_strand) {
        Error(Nil) -> []
        Ok(current) ->
          tool_activity.running(
            view.cells,
            list.map(model.records, fn(record) { record.entry }),
            current,
          )
      }
  }
  case calls {
    [] -> "preparing tools"
    [call, ..rest] ->
      compact(tool_call_summary(call.name, call.arguments, False), 72)
      <> case rest {
        [] -> ""
        more -> " + " <> int.to_string(list.length(more)) <> " running"
      }
  }
}

fn active_stream_kind(model: Model) -> Option(String) {
  display_streams(model)
  |> list.reverse
  |> list.find(fn(stream) {
    let Stream(strand:, ..) = stream
    strand == model.active_strand && stream.kind != "end"
  })
  |> result.map(fn(stream) {
    let Stream(kind:, ..) = stream
    kind
  })
  |> result.map(Some)
  |> result.unwrap(None)
}

fn render_paste_chip(
  buf: buffer.Buffer,
  area: Rect,
  attachments: List(composer.Attachment),
) -> buffer.Buffer {
  case
    composer.summary(attachments),
    area.size.width > 0 && area.size.height > 0
  {
    Some(summary), True -> {
      // The chip owns its whole row now, so a long summary would run off the
      // panel instead of pushing the editor aside. Truncating to the row less
      // its two brackets keeps the ellipsis inside the border.
      let truncated =
        text.truncate(summary, int.max(0, area.size.width - 2), "…")

      paragraph.render_styled(buf, area, [
        span.line_new([
          span.span_styled("[" <> truncated <> "]", theme.signal_bold()),
        ]),
      ])
    }
    Some(_), False | None, True | None, False -> buf
  }
}

fn render_command_palette(
  buf: buffer.Buffer,
  body: Rect,
  model: Model,
) -> buffer.Buffer {
  let suggestions =
    command.suggestions_with_skills(text_area.value(model.input), model.skills)
  case suggestions, model.overlay {
    [], _
    | _, ModelSelector(_)
    | _, AgentInspector(_)
    | _, SessionSelector(_)
    | _, DaemonSelector(_)
    | _, ApprovalInspector(_)
    -> buf
    _, NoOverlay -> {
      let width = int.max(1, int.min(72, body.size.width - 4))
      let height = int.max(1, int.min(10, list.length(suggestions) + 2))
      let selected =
        int.min(model.command_selected, list.length(suggestions) - 1)
      let offset = int.max(0, selected - { height - 3 })
      let area =
        geometry.rect_new(
          body.position.x + 2,
          geometry.bottom(body) - height,
          width,
          height,
        )
      let frame =
        block.block_new()
        |> block.with_border(block.Rounded)
        |> block.with_colors(theme.signal, theme.graphite)
        |> block.with_bg_fill
        |> block.with_title_styled(
          [
            span.span_styled(" commands ", theme.overlay_signal()),
          ],
          block.Top,
        )
      let lines =
        suggestions
        |> list.drop(offset)
        |> list.take(height - 2)
        |> list.index_map(fn(suggestion, relative) {
          let command.Suggestion(command: name, description:, ..) = suggestion
          let is_selected = offset + relative == selected
          let signal = theme.overlay_signal()
          let current = theme.overlay_current()
          let quiet = theme.overlay_quiet()
          span.line_new([
            span.span_styled(
              case is_selected {
                True -> "▸ "
                False -> "  "
              },
              case is_selected {
                True -> signal
                False -> quiet
              },
            ),
            span.span_styled(name, case is_selected {
              True -> signal
              False -> current
            }),
            span.span_styled("  " <> description, quiet),
          ])
        })
      buf
      |> buffer.clear(area)
      |> block.render(area, frame)
      |> paragraph.render_styled(block.inner(area, frame), lines)
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
      Model(..model, width:, height:, selection: None, selection_frame: None)
      |> mark_activity
      |> invalidate_frame
    backend.Tick -> update_tick(model)

    // A keyboard burst can arrive before an idle tick even when the final
    // server reply is already queued. Apply bounded ready progress before
    // interpreting the action, without starting another periodic capture.
    backend.KeyPress(key) ->
      update_ready_key(keys.match(key), model)
      |> mark_activity
      |> invalidate_frame
    backend.Paste(text) ->
      handle_paste(clear_selection(model), text)
      |> mark_activity
      |> invalidate_frame
    backend.MouseScroll(x, y, up) ->
      scroll_at(clear_selection(model), geometry.Position(x, y), case up {
        True -> Older
        False -> Newer
      })
      |> mark_activity
      |> invalidate_frame

    // The left button is the selection button, as in every terminal. The
    // other two are listed so a new etui button is a compile error here.
    backend.MousePress(x, y, backend.MouseLeft) ->
      begin_selection(model, geometry.Position(x, y))
      |> mark_activity
      |> invalidate_frame
    backend.MouseDrag(x, y, backend.MouseLeft) ->
      extend_selection(model, geometry.Position(x, y))
      |> mark_activity
      |> invalidate_frame
    backend.MouseRelease(x, y, backend.MouseLeft) ->
      finish_selection(model, geometry.Position(x, y))
      |> mark_activity
      |> invalidate_frame
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
  let updated = case !diff_shown(model) && diff_shown(updated) {
    True -> request_visible_worktree(updated)
    False -> updated
  }
  let updated = sync_context(model, updated)
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
  let drained = drain_connection(switched, 64)
  let drained =
    tick_channel(
      service_context_read(
        service_jobs_read(service_worktree_read(service_queue_read(drained))),
      ),
    )
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
          append_error(
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
      append_error(model, "open session: " <> reason)
    attempt_replay.Adopt(cut, view) ->
      Model(
        ..model,
        session: cut.attachment.expected.session,
        captured: None,
        scrollback: case model.session == cut.attachment.expected.session {
          True -> history_view.cancel(model.scrollback)
          False -> history_view.empty()
        },
        parked_scrollback: case
          model.session == cut.attachment.expected.session
        {
          True -> model.parked_scrollback
          False -> dict.new()
        },
        note_board: None,
        approvals: [],
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
    attempt_replay.Update(update) -> apply_channel_update(model, update)
  }
}

// The tick is the one place the clock is read, so the elapsed count and
// the glyph advance together and rendering stays a pure function of the
// model. Going idle clears the clock, so the next activity starts from
// zero rather than from wherever the last one stopped.
fn advance_activity_indicator(model: Model) -> Model {
  case active_strand_live(model) {
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
        activity_glyph(model.activity_frame) == activity_glyph(activity_frame)
        && activity_elapsed_s == model.activity_elapsed_s
      {
        True -> advanced
        False -> invalidate_frame(advanced)
      }
    }
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
          rendered: render_frame(paced, screen),
        )),
      )
    }
  }
}

// The snap bound is the viewport rather than a constant: what makes a jump
// worth smoothing is that the reader can still see where the text came
// from, and a growth taller than the screen leaves nothing of it.
fn pace_policy(model: Model) -> pacing.PacePolicy {
  pacing.policy(snap_above: transcript_viewport_height(model))
}

// Rows held back from the bottom-anchored viewport. Added to the scroll
// offset, which counts from the same end, this is what walks the view down
// to the tail a frame at a time.
fn viewport_backlog(model: Model) -> Int {
  int.max(0, model.rendered_row_count - model.revealed_rows)
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
  use <- bool.guard(main_shows_diff(model), pacing.ViewportSettled)
  pacing.viewport_pacing(backlog: viewport_backlog(model))
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
  case active_strand_live(model) {
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

fn mark_activity(model: Model) -> Model {
  Model(
    ..model,
    activity_revision: model.activity_revision + 1,
    quiet_for_ms: 0,
  )
}

fn invalidate_frame(model: Model) -> Model {
  Model(..model, frame_revision: model.frame_revision + 1)
}

// Reading mode owns the endpoint even at offset zero, so a frozen viewport at
// the tail is not the live tail: returning to live output is an explicit
// gesture rather than a consequence of scrolling back down to the newest row.
// The offset covers the converse, a viewport lifted off the tail before any
// endpoint was frozen.
fn reading_history(model: Model) -> Bool {
  model.scrollback.mode == history_view.Reading || model.scroll_offset > 0
}

// Terminal polling still produces idle ticks so the websocket inbox can be
// drained, but those ticks must not compare or wrap the durable transcript.
// Event handlers increment a scalar revision at the mutation boundary, which
// keeps an idle cache check constant-time regardless of session length.
fn refresh_render_cache(before: Model, after: Model) -> Model {
  let changed =
    after.render_revision != after.rendered_revision
    || reading_history(before) != reading_history(after)
    || before.width != after.width
    || before.agent_rail_visible != after.agent_rail_visible
    || before.details_expanded != after.details_expanded
    || before.help_open != after.help_open
    || before.notes_open != after.notes_open
    || before.diff_view != after.diff_view
    || before.active_strand != after.active_strand
    || viewport_height_changed(
      transcript_viewport_height(before),
      transcript_viewport_height(after),
    )
  case changed {
    True -> {
      let width = transcript_width(after)
      let reading_lines = case reading_history(after) {
        False -> None
        True ->
          case before.reading_lines {
            Some(lines)
              if before.active_strand == after.active_strand
              && before.session == after.session
            -> Some(lines)
            Some(_) | None -> Some(transient_lines(before))
          }
      }
      let cached =
        refresh_diff_cache(before, Model(..after, reading_lines:))
        |> refresh_record_cache(width)
      let rendered_rows = rendered_rows_for(cached, width)
      let rendered_row_count = list.length(rendered_rows)

      // Source anchors are needed only while reading older output. Building
      // them for every live fragment repeats the whole durable projection.
      // The first scroll into history captures them before later updates.
      let rendered_anchors = case
        after.help_open || after.notes_open || !reading_history(after)
      {
        True -> []
        False -> record_anchors_for(cached, width)
      }
      let anchored = case reading_history(after) {
        False -> 0
        True ->
          transcript_anchor.relocate(
            before.rendered_anchors,
            rendered_anchors,
            after.scroll_offset,
            transcript_viewport_height(before),
            before.rendered_row_count - list.length(before.rendered_anchors),
            rendered_row_count - list.length(rendered_anchors),
          )
          |> option.unwrap(after.scroll_offset)
      }

      // Reading history owns the viewport through the scroll offset, and a
      // strand or session switch replaced the rows rather than extending
      // them: neither has a tail to walk toward. Otherwise the count only
      // needs clamping, since a shrunk projection must not leave the
      // viewport claiming rows that no longer exist.
      let revealed_rows = case
        reading_history(after)
        || before.active_strand != after.active_strand
        || before.session != after.session
      {
        True -> rendered_row_count
        False -> int.min(after.revealed_rows, rendered_row_count)
      }
      Model(
        ..cached,
        rendered_revision: cached.render_revision,
        rendered_row_count:,
        rendered_rows:,
        revealed_rows:,
        rendered_anchors:,
        scroll_offset: bounded_scroll_offset(
          anchored,
          rendered_row_count,
          transcript_viewport_height(after),
        ),
      )
    }
    False -> after
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
  let cached = case diff_shown(after) {
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
        diff_shown(before)
        && after.record_cache_valid
        && after.record_cache_strand == after.active_strand
        && list.is_empty(after.pending_records)
        && after.diff_worktree_source
        == #(after.worktree.board, after.worktree.selected)
        && diff_width(before) == diff_width(after)
      case matches {
        True -> after
        False -> {
          let #(rows, line_cache) =
            diff_content(after)
            |> cached_record_lines(
              diff_width(after),
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
      diff_patch_height(cached),
    ),
  )
}

fn previous_diff_layout(
  before: Model,
  after: Model,
) -> Dict(Line, List(span.Line)) {
  case diff_shown(before) && diff_width(before) == diff_width(after) {
    True -> after.diff_line_cache
    False -> dict.new()
  }
}

fn diff_width(model: Model) -> Int {
  case diff_pane_width(model) {
    0 -> transcript_width(model)
    width -> int.max(1, width - 2)
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
fn refresh_record_cache(model: Model, width: Int) -> Model {
  // Expanded history is append-only, so a pending record there can only add
  // rows. Compact history groups consecutive calls, and `tool_activity`
  // answers which records can rewrite a group already projected; the rest —
  // prose, a user turn, structural history — end the group with the rows it
  // already had and keep the append path.
  let regrouped =
    !model.details_expanded
    && list.any(model.pending_records, fn(record) {
      tool_activity.regroups(record.entry)
    })
  let cache_matches =
    model.record_cache_valid
    && model.record_cache_width == width
    && model.record_cache_strand == model.active_strand
    && model.record_cache_details == model.details_expanded
    && !regrouped
  case cache_matches, model.pending_records {
    False, _ -> {
      let previous = case model.record_cache_width == width {
        True -> model.record_line_cache
        False -> dict.new()
      }
      let #(lines, compact_call_cache, compact_entry_cache) =
        record_lines(model.records, model)
      let #(record_rows, record_line_cache) =
        model.transcript
        |> list.append(lines)
        |> cached_record_lines(width, previous)
      Model(
        ..model,
        record_rows:,
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
      let #(lines, calls, narratives) = record_lines(pending, model)
      let #(newest_rows, appended) =
        cached_record_lines(lines, width, model.record_line_cache)

      // Every cache here describes the current projection, and the appended
      // records have just joined it. Merging rather than replacing keeps the
      // hints for the rows already on screen, which this path never rebuilds;
      // the release of retired text belongs to the full rebuild.
      Model(
        ..model,
        record_rows: list.append(newest_rows, model.record_rows),
        record_line_cache: dict.merge(model.record_line_cache, appended),
        compact_call_cache: dict.merge(model.compact_call_cache, calls),
        compact_entry_cache: dict.merge(model.compact_entry_cache, narratives),
        pending_records: [],
      )
    }
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
) -> #(List(span.Line), Dict(Line, List(span.Line))) {
  list.fold(lines, #([], dict.new()), fn(acc, line) {
    let #(rows, cached) = acc
    let rendered =
      dict.get(previous, line)
      |> result.lazy_unwrap(fn() {
        render_line(line, width) |> markdown.wrap_lines(width)
      })
    #(
      list.append(list.reverse(rendered), rows),
      dict.insert(cached, line, rendered),
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
    model.records
    |> list.reverse
    |> list.filter(fn(record) { record.strand == model.active_strand })
    |> list.map(fn(record) { record.entry })
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
      list.flat_map(entries, fn(value) {
        anchored_entry_blocks(value, model)
        |> list.map(fn(block) {
          #(dict.get(results, block.0) |> result.unwrap(block.0), block.1)
        })
      })
    }
    False ->
      entries
      |> tool_activity.project
      |> list.flat_map(fn(item) {
        case item {
          tool_activity.Narrative(value) -> anchored_entry_blocks(value, model)
          tool_activity.Tools(calls) -> {
            let heading = [activity_heading(calls)]
            [
              #("", heading),
              ..list.map(calls, fn(call) {
                #(
                  ids.entry_id_to_string(call.source)
                    <> "/call/"
                    <> call.invocation.id,
                  dict.get(model.compact_call_cache, call)
                    |> result.lazy_unwrap(fn() { activity_call_lines(call) }),
                )
              })
            ]
          }
        }
      })
  }
  [#("", model.transcript), ..blocks]
  |> list.flat_map(fn(block) {
    block.1
    |> list.index_map(fn(line, part) { #(line, part) })
    |> list.flat_map(fn(pair) {
      let rendered =
        dict.get(model.record_line_cache, pair.0)
        |> result.lazy_unwrap(fn() {
          render_line(pair.0, width) |> markdown.wrap_lines(width)
        })
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
  let owner = solo_owner(model.captured)
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
          #(key, assistant_block_lines(block, details))
        })
      let terminal = assistant_terminal_lines(stop_reason, error_message)
      case terminal {
        [] -> blocks
        _ -> list.append(blocks, [#(id <> "/terminal", terminal)])
      }
    }
    _ -> [#(id, entry_lines(value, details, owner))]
  }
}

// The live tail is parsed afresh on every call rather than memoized: a memo
// would pin one more generation of the live region than the retained-bytes
// gate on streaming has headroom for, and it would save a few parses a
// second rather than one per frame.
//
// The viewport consumes rows newest-first. Keeping that order in the cache
// makes each live frame prepend only the small transient stream projection.
fn rendered_rows_for(model: Model, width: Int) -> List(span.Line) {
  case model.help_open, model.notes_open {
    True, _ ->
      help_content().lines |> markdown.wrap_lines(width) |> list.reverse
    False, True ->
      notes_content(model, width).lines
      |> markdown.wrap_lines(width)
      |> list.reverse
    False, False ->
      option.lazy_unwrap(model.reading_lines, fn() { transient_lines(model) })
      |> transcript_content(width)
      |> fn(content) { markdown.wrap_lines(content.lines, width) }
      |> list.reverse
      |> list.append(model.record_rows)
  }
}

// The live tail is a bounded, disposable observation. Scrollback retains one
// immutable projection so later fragments cannot reflow text under the reader.
fn transient_lines(model: Model) -> List(Line) {
  stream_lines(
    display_streams(model),
    model.active_strand,
    details_extent(model.details_expanded),
  )
  |> list.append(tool_tail_lines(model))
  |> list.append(pending_input_lines(model))
}

fn handle_paste(model: Model, text: String) -> Model {
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
    Some(_) -> waiting_notice(model)
    None -> paste_unlocked(model, text)
  }
}

fn paste_unlocked(model: Model, text: String) -> Model {
  case image_drop.load_paste(text) {
    Error(reason) -> append_error(model, reason)
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
    Error(reason) -> append_error(model, reason)
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
      append_error(
        cancel_pending(model, "target change from " <> model.session),
        "open session: " <> reason,
      )
    Some(attachment.Adopted(channel, cut, view, inbox, workspace, creation_key)) -> {
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

      // Parked windows are keyed by strand name alone, and two sessions reuse
      // the same names. Adopting a different session must drop them, or a
      // later switch to `main` would restore another session's ancestry.
      let model = case model.session == cut.attachment.expected.session {
        True ->
          Model(..model, scrollback: history_view.cancel(model.scrollback))
        False ->
          Model(
            ..model,
            scrollback: history_view.empty(),
            parked_scrollback: dict.new(),
          )
      }

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
          approvals: [],
          overlay: NoOverlay,
          creation_key: case creation_key {
            Some(key) if model.creation_key == Some(key) -> None
            Some(_) | None -> model.creation_key
          },
          workspace: workspace,
          session: cut.attachment.expected.session,
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
        adopted |> send_frame(protocol.models(1)) |> request_visible_worktree
      case cancelled {
        Some(notice) -> append_system(adopted, notice)
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
      apply_submission(model, disposition)
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
          append_system(
            updated,
            "Decisions not available: " <> string.join(missing, ", "),
          )
      }
    }
    session_channel.Auxiliary(event) -> apply_event(model, event)
    session_channel.RequestRefused("history", _, code, message) ->
      append_error(
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
      |> invalidate_frame
    session_channel.Acknowledged("prompt", "queued") ->
      Model(
        ..settle_own_turn(model),
        submitting: None,
        notice: "prompt queued for the next turn",
      )
      |> invalidate_frame

    // An abort ends the run, and with it every steer and follow-up the run
    // had not started yet: the queue drains those without committing them,
    // so no entry will ever arrive to retire their interjections. A held
    // prompt is not the run's to cancel — it waits in the gateway and drains
    // once the strand is idle — so the abort drops the interjections and
    // leaves the prompt echoes standing.
    session_channel.Acknowledged("abort", status) ->
      Model(..abandon_interjections(model), notice: "abort " <> status)
      |> invalidate_frame

    // Every other acknowledgement settles its submission the same way: a
    // steer answered `admitted` will commit the entry its interjection is
    // waiting for. Commands that record nothing leave `awaiting_outcome`
    // empty and pass through untouched.
    session_channel.Acknowledged(command, status) ->
      Model(..settle_own_turn(model), notice: command <> " " <> status)
      |> invalidate_frame
    session_channel.UnknownOutcome(command, request_id) ->
      append_error(
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
      append_error(
        Model(
          ..discard_own_turn(model),
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
          worktree: case model.worktree.awaiting {
            Some(id) ->
              worktree_view.receive(
                model.worktree,
                queue_owner(model),
                worktree_view.Failed(id, "conversation disconnected"),
              )
            None -> model.worktree
          },
        ),
        "conversation: " <> reason,
      )
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
    -> Model(..model, captured: Some(#(cut, view)))
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
          append_system(
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
        None -> append_error(model, "conversation is not attached")
        Some(channel) ->
          case session_channel.lookup(channel, ids) {
            Ok(channel) -> Model(..model, channel: Some(channel))
            Error(reason) ->
              append_error(model, "decision lookup not sent: " <> reason)
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
  render_cut(model, cut, view, reviews)
}

fn render_cut(
  model: Model,
  cut: snapshot.Captured,
  view: snapshot_view.View,
  reviews: List(approval.Review),
) -> Model {
  let active = case is_known_strand(view.strands, model.active_strand) {
    True -> model.active_strand
    False ->
      case view.strands {
        [first, ..] -> first.id
        [] -> "main"
      }
  }
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
  let role = case cut.attachment.role {
    snapshot.Owner -> "owner"
    snapshot.Operator -> "operator"
    snapshot.Observer -> "observer · read-only"
  }

  // The same coherent presence test governs both turn labels and the
  // attachment banner. A lone owner needs no redundant name or role; every
  // other attachment retains the full identity and participant count.
  let #(notice, attachment_banner) = case solo_owner(Some(#(cut, view))) {
    Some(_) -> #("1 present", "Attached · 1 present")
    None -> {
      let identity =
        cut.attachment.origin.name
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
      configuration_lines(view, active),
      list.append(unconfirmed_lines(model.unconfirmed), approval_lines(reviews)),
    )
  ]

  // Everything the record projection reads, so a cut that moved only usage,
  // phases or timestamps leaves the cache standing. Cuts arrive on a
  // quarter-second cadence throughout a turn, and invalidating on every one
  // of them made each a full re-projection of the whole session.
  let record_cache_valid =
    model.record_cache_valid
    && model.active_strand == active
    && model.records == branch.records
    && model.transcript == transcript
    && solo_owner(model.captured) == solo_owner(Some(#(cut, view)))

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

  // A strand the cut no longer carries cannot be selected again, so its
  // parked window is unreachable. Dropping it here is what bounds the
  // dictionary over a long session that retires sub-agents continuously.
  let parked =
    dict.filter(model.parked_scrollback, fn(strand, _) {
      is_known_strand(view.strands, strand)
    })
  Model(
    ..model,
    captured: Some(#(cut, view)),
    approvals: reviews,
    active_strand: active,
    strands: view.strands,
    agent_summary: agents.summary(view.strands),
    reviewer_rows: reviewer_status.observe(
      model.reviewer_rows,
      cut.window,
      view,
    ),
    records: branch.records,
    scrollback: history,
    parked_scrollback: parked,
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
    streams: live,
    tool_tails: live_tails,
    interrupt: reconcile_interrupt(model.interrupt, view.operations),
    queued: case view.pending_inputs {
      Some(_) -> []
      None -> model.queued
    },
    submitting: None,
    record_cache_valid:,
    notice: notice,
    transcript:,
  )
  |> invalidate_transcript
  // A completed cut can make the operation idle before the next animation
  // tick. Invalidate the painted frame too; rebuilding transcript rows alone
  // leaves the old buffer current until an unrelated key or resize arrives.
  |> invalidate_frame
  |> mark_activity
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
    Some(author) -> " · changed by " <> author.name
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
  case model.inspecting_approval {
    Some(id) ->
      case list.find(records, fn(record: approval.Review) { record.id == id }) {
        Ok(record) ->
          Model(
            ..model,
            overlay: ApprovalInspector(approval_panel.new(record)),
            inspecting_approval: None,
          )
        Error(Nil) ->
          case list.contains(missing, id) {
            True -> Model(..model, inspecting_approval: None)
            False -> model
          }
      }
    None -> model
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
        Some(origin) -> " · " <> origin.name
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

fn decide(
  model: Model,
  id: String,
  encode: fn(Int, approval.Review) -> Result(String, String),
) -> Model {
  case list.find(model.approvals, fn(record) { record.id == id }) {
    Error(Nil) ->
      append_error(
        model,
        "decision is not displayed; load /approvals " <> id <> " first",
      )
    Ok(record) ->
      case encode(model.next_id, record) {
        Error(reason) -> append_error(model, reason)
        Ok(frame) -> send_frame(model, frame)
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
      append_error(
        Model(..model, session_switch: sessions.Idle),
        "open session " <> session <> ": " <> reason,
      )
      |> mark_activity
    sessions.WorkerCrashed(session, reason) ->
      append_error(
        Model(..model, session_switch: sessions.Idle),
        "open session " <> session <> " crashed: " <> reason,
      )
      |> mark_activity
    sessions.Ready(choice, options, target, inbox, socket) ->
      case connection.adopt(socket) {
        Error(reason) -> {
          connection.close(socket)
          sessions.discard(inbox)
          append_error(
            Model(..model, session_switch: sessions.Idle),
            "open session " <> target.session <> ": " <> reason,
          )
          |> mark_activity
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
    record_rows: [],
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
  |> invalidate_transcript
  |> mark_activity
  |> invalidate_frame
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
      |> mark_activity
      |> invalidate_frame
    connection.Closed(reason) ->
      append_error(
        Model(
          ..model,
          peer: after_close(model.peer),
          streams: [],
          tool_tails: [],
        ),
        "connection closed: " <> reason,
      )
      |> mark_activity
    connection.NetworkFault(reason) ->
      append_error(model, "network: " <> reason)
      |> mark_activity
    connection.Incoming(text) ->
      case protocol.decode_event(text) {
        Ok(event) -> apply_event(model, event)
        Error(reason) ->
          append_error(model, "protocol: " <> reason)
          |> mark_activity
      }
  }
}

fn apply_event(model: Model, event: protocol.Event) -> Model {
  let updated = case event {
    protocol.FullSnapshot(session:, strands:, entries:, usage:) ->
      Model(
        ..model,
        session:,
        strands:,
        agent_summary: agents.summary(strands),
        usage:,
        records: list.reverse(entries),
        streams: [],
        tool_tails: [],
        record_rows: [],
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
      |> invalidate_transcript
    protocol.StrandsSnapshot(strands:) -> {
      let summary = agents.summary(strands)
      Model(..model, strands:, agent_summary: summary, notice: summary)
    }
    protocol.SkillsSnapshot(page:) -> {
      let previous = case page.offset {
        0 -> []
        _ -> model.skills
      }
      case page.offset == list.length(previous) {
        False ->
          append_error(model, "skill catalogue page arrived out of order")
        True -> {
          let loaded =
            Model(..model, skills: list.append(previous, page.commands))
          case page.next {
            None -> loaded
            Some(offset) ->
              send_frame(loaded, protocol.skills(loaded.next_id, offset))
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
      |> send_frame(protocol.skills(model.next_id, 0))
    }
    protocol.SchedulesSnapshot(schedules:) -> append_schedules(model, schedules)
    protocol.ConfigSnapshot(model_name:) ->
      case model_name {
        Some(name) ->
          Model(..model, current_model: name, notice: "model: " <> name)
        None -> model
      }
    protocol.LiveJobsSnapshot(board) -> receive_jobs(model, board)
    protocol.ContextSnapshot(observation) ->
      Model(
        ..model,
        context: context_view.receive(
          model.context,
          queue_owner(model),
          observation,
        ),
      )
    protocol.WorktreeSnapshot(observation) ->
      Model(
        ..model,
        worktree: worktree_view.receive(
          model.worktree,
          queue_owner(model),
          observation,
        ),
      )
      |> invalidate_transcript
    protocol.QueuedInputSnapshot(document) ->
      Model(
        ..model,
        queue_editor: queue_editor.receive(
          model.queue_editor,
          queue_owner(model),
          queue_namespace(model),
          document,
        ),
      )
    protocol.NotesSnapshot(board) ->
      invalidate_transcript(
        Model(..model, note_board: Some(board), notice: "notes refreshed"),
      )
    protocol.EntryAdded(record:) -> {
      let protocol.EntryRecord(strand:, ..) = record
      let updated =
        Model(
          ..model,
          records: [record, ..model.records],
          streams: clear_streams(model.streams, strand),
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
        True -> invalidate_transcript(updated)
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
            model.streams,
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
        True -> invalidate_transcript(updated)
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
            True -> clear_streams(model.streams, strand)
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
        True -> invalidate_transcript(settled)
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
        True -> invalidate_transcript(updated)
        False -> updated
      }
    }
    protocol.UsageChanged(usage: settled) -> {
      // Usage arrives once per settled generation, so this is the moment
      // the rate is known: the settlement's own output count over the
      // time since the request went out. A settlement whose clock never
      // started (a refusal, an empty turn) leaves the last rate standing.
      let output_rate_tps = case model.peer, model.generation_started_ms {
        // The window is this client's own clock from the request going
        // out to the settlement, and a replay spends that window playing
        // a file rather than waiting on a provider. `output_rate_min_ms`
        // already discards the short ones, so a brief replay would report
        // nothing anyway; a long one would report how fast the replay
        // ran. Declining outright is the same rule that stops a replay
        // echoing a prompt.
        Replaying, _ | Disconnected, _ -> model.output_rate_tps

        Attached(..), Some(started) | Preview, Some(started) ->
          output_rate(settled.output, model.monotonic_time_ms() - started)
        Attached(..), None | Preview, None -> model.output_rate_tps
      }
      let usage = add_usage(model.usage, settled)
      Model(
        ..model,
        usage:,
        generation_started_ms: None,
        output_rate_tps:,
        notice: tokens(usage.total_tokens) <> " tokens",
      )
    }
    protocol.EscalationPending(id:, tool:, preview: _) ->
      append_error(model, "approval required for " <> tool <> " [" <> id <> "]")

    // The refusal answers whatever this terminal last submitted, because the
    // conversation channel carries one mutation at a time. A prompt refused
    // for a full hold queue commits no entry, so its echo is retired here or
    // never.
    protocol.ServerError(code:, message:) ->
      append_error(
        Model(..discard_own_turn(model), submitting: None),
        code <> ": " <> message,
      )

    // A commit notice and a metadata change say only that the next capture
    // will differ. `tui/session_channel` acts on them by capturing; there is
    // nothing for a renderer to draw from the frame itself.
    protocol.Committed(..) | protocol.MetadataChanged -> model
    protocol.Ignored(_) -> model
  }
  case event {
    protocol.Committed(..) | protocol.MetadataChanged -> updated
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
      |> mark_activity
      |> invalidate_frame
  }
}

// One line per schedule, in the listing's own order — the operator's
// standing tables first, then what the session grew. `owner` is printed
// rather than derived: "operator" and a strand that happens to be called
// something similar are told apart by the server and never here.
fn append_schedules(model: Model, rows: List(protocol.ScheduleRow)) -> Model {
  case rows {
    [] -> append_system(model, "no schedules")
    rows -> {
      let listed =
        list.fold(rows, model, fn(model, row) {
          append_system(model, schedule_line(row))
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
        False -> [
          Stream(strand, operation, generation, "end", [], 0),
          ..list.filter(streams, fn(stream) { stream.strand != strand })
        ]
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
  case bytes <= live_stream_limit * 2 {
    True -> #(fragments, bytes)
    False -> {
      let newest =
        fragments
        |> list.reverse
        |> string.concat
        |> newest_bytes(live_stream_limit)
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
      case list.length(tails) >= max_tool_tails {
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

/// How many lines of a running command's tail the transcript shows. The
/// daemon's window is a few kilobytes; a terminal wants the last screenful
/// of lines from it, not the whole window pushing the composer away.
pub const tail_lines_shown = 8

/// Maximum distinct stream tails retained across every strand and call.
/// Exact durable reconciliation normally removes a tail first; this bound
/// covers a client which misses enough captures to evict the matching result.
pub const max_tool_tails = 128

/// What the transcript draws for the active strand's running tool calls,
/// which with details collapsed is nothing at all.
///
/// A tool call that succeeds settles without changing the transcript's
/// height. The durable projection already gives a running call one row — its
/// summary followed by `· awaiting result` — and a plain successful result
/// replaces that row one for one. Drawing the command's output window beside
/// it would add a heading and up to `tail_lines_shown` more rows and take
/// them away again two hundred milliseconds later, which is what made the
/// transcript jump by eight rows on every tool call of a turn and back. The
/// window is detail, so `Ctrl+g` is where it belongs, alongside the expanded
/// result the settle will draw in its place.
///
/// A result which carries something a reader has to see still costs the rows
/// it needs: a failure draws its summary and the result text under it, and
/// `fs_edit` and `context_remaining` draw their own rows. Suppressing those
/// would be trading the reader's information for a smooth scroll, which is
/// the wrong way round. What this removes is the growth that carried no
/// information — the window that appeared and vanished within a few hundred
/// milliseconds.
///
/// Expanded, the window is one `ToolResult` line per stream, headed by the
/// stream's name and how much it has carried, followed by the last
/// `tail_lines_shown` lines of it. A tail whose text is empty — a binary
/// stream, or a command that has printed nothing to that stream yet —
/// draws its heading alone, so the reader still sees that the command is
/// alive and how much it has written.
///
/// ## Examples
///
/// ```gleam
/// // tui.tool_tail_lines(tui.Model(..model, details_expanded: True))
/// //   == [tui.Line(tui.ToolResult, "stdout · 31 B so far\ncompiling core")]
/// ```
@internal
pub fn tool_tail_lines(model: Model) -> List(Line) {
  case details_extent(model.details_expanded) {
    notes_view.Excerpt -> []
    notes_view.Complete -> expanded_tool_tail_lines(model)
  }
}

// The window itself, once the reader has asked for detail.
fn expanded_tool_tail_lines(model: Model) -> List(Line) {
  model.tool_tails
  |> list.filter(fn(tail) { tail.strand == model.active_strand })
  |> list.map(fn(tail) {
    let heading =
      tail.stream <> " · " <> byte_count(tail.total_bytes) <> " so far"
    let shown =
      tail.text
      |> string.trim_end
      |> string.split("\n")
      |> list.filter(fn(line) { line != "" })
      |> last_lines(tail_lines_shown)
    Line(ToolResult, string.join([heading, ..shown], "\n"))
  })
}

// The last `count` of `lines`, in order.
fn last_lines(lines: List(String), count: Int) -> List(String) {
  let extra = list.length(lines) - count
  case extra > 0 {
    True -> list.drop(lines, extra)
    False -> lines
  }
}

// A byte count a reader can take in at a glance: bytes up to a kilobyte,
// whole kibibytes past it. The number tells the reader the window is a
// tail of something larger, which is all the precision it needs.
fn byte_count(bytes: Int) -> String {
  case bytes < 1024 {
    True -> int.to_string(bytes) <> " B"
    False -> int.to_string(bytes / 1024) <> " KiB"
  }
}

fn clear_streams(streams: List(Stream), strand: String) -> List(Stream) {
  list.filter(streams, fn(stream) {
    let Stream(strand: owner, ..) = stream
    owner != strand
  })
}

// The submission still awaiting its outcome is drawn with the ones the daemon
// has already acknowledged, and last, because it is the newest. Waiting for
// the reply before drawing it would cost the echo a round trip, which is most
// of what it is for.
//
// The echoes are the newest thing on screen: they were typed after the run
// that is streaming above them started, and they run after it finishes. One
// trailer under the group says what they are waiting for, rather than a
// marker repeated beside every line of it.
fn queued_lines(
  queued: List(Submission),
  awaiting: Option(Submission),
) -> List(Line) {
  let held =
    list.filter_map(
      list.append(queued, option.values([awaiting])),
      fn(submission) {
        case submission {
          HeldPrompt(text:) -> Ok(Line(User, text))

          // An interjection is on this list to consume an entry, not to be
          // read: the run it steered is already drawing its answer above.
          Interjection -> Error(Nil)
        }
      },
    )
  case held {
    [] -> []
    [_, ..] ->
      list.append(held, [
        Line(System, "queued · runs when this turn finishes"),
      ])
  }
}

// Modern cuts carry the complete host queue, including other peers' input.
// Replacing that list also removes drained rows after reconnect or a skipped
// idle interval, without matching repeated text against transcript entries.
fn pending_input_lines(model: Model) -> List(Line) {
  let pending = case model.captured {
    Some(#(_, view)) -> view.pending_inputs
    None -> None
  }
  case pending {
    None -> queued_lines(model.queued, model.awaiting_outcome)
    Some(rows) -> {
      let visible =
        list.filter(rows, fn(row) { row.strand == model.active_strand })
      let queued =
        list.flat_map(visible, fn(row) {
          [
            Line(User, row.text),
            Line(System, case row.kind {
              snapshot_view.Steer -> "steer · runs next"
              snapshot_view.Queue -> "queued · after this turn"
            }),
          ]
        })
      list.append(queued, queued_lines([], model.awaiting_outcome))
    }
  }
}

// Captured previews are standalone observations, never stored as delta
// history. Once pushed observations arrive they take precedence, including
// their empty terminal marker: unequal request identities do not prove that
// a captured preview is newer than the request whose end was just observed.
fn display_streams(model: Model) -> List(Stream) {
  let active =
    list.filter(model.streams, fn(stream) {
      stream.strand == model.active_strand
    })
  let preview = case model.captured {
    Some(#(_, view)) ->
      case view.preview, dict.get(view.operations, model.active_strand) {
        Some(sample), Ok(op) if op == sample.operation -> Some(sample)
        Some(_), Ok(_) | Some(_), Error(Nil) | None, _ -> None
      }
    None -> None
  }
  case active, preview {
    [], Some(sample) -> [preview_stream(model.active_strand, sample)]
    _, _ -> active
  }
}

fn preview_stream(strand: String, sample: snapshot_view.Preview) -> Stream {
  Stream(
    strand,
    sample.operation,
    sample.generation,
    sample.kind,
    [sample.text],
    string.byte_size(sample.text),
  )
}

fn stream_lines(
  streams: List(Stream),
  active_strand: String,
  extent: notes_view.Extent,
) -> List(Line) {
  streams
  |> list.filter_map(fn(stream) {
    let Stream(strand:, kind:, fragments:, ..) = stream
    case strand == active_strand && kind != "end" {
      False -> Error(Nil)
      True -> {
        let text = fragments |> list.reverse |> string.concat
        Ok(case kind {
          "thinking" -> live_reasoning_line(text, extent)
          "tool_call" -> Line(ToolCall, live_tool_call_summary(text))
          _ -> Line(Assistant, text)
        })
      }
    }
  })
}

// The live and settled forms of one reasoning block are drawn by different
// code paths a few hundred milliseconds apart — this one from the stream
// the provider is still writing, the other from the record the daemon has
// committed — so the two functions below are deliberately the same shape.
// Collapsed, each is exactly one `ReasoningDigest` row — clipped to the pane
// rather than wrapped, so the count holds at every width — and the settle
// therefore changes the row's words and not the transcript's height.
fn live_reasoning_line(text: String, extent: notes_view.Extent) -> Line {
  case extent {
    notes_view.Complete -> Line(Reasoning, text)
    notes_view.Excerpt -> Line(ReasoningDigest, live_reasoning_digest(text))
  }
}

fn settled_reasoning_line(text: String, extent: notes_view.Extent) -> Line {
  case extent {
    notes_view.Complete -> Line(Reasoning, text)
    notes_view.Excerpt -> Line(ReasoningDigest, settled_reasoning_digest(text))
  }
}

/// The collapsed stand-in for a reasoning block the provider is still
/// writing: how much of it has arrived, and nothing of what it says.
///
/// An excerpt would be the obvious thing to show and is the wrong one. The
/// opening words of a block that is still growing are rewritten under the
/// reader as fragments land, and a line that changes is far harder to
/// ignore than a counter that climbs.
///
/// ## Examples
///
/// ```gleam
/// assert tui.live_reasoning_digest("one thought") == "1 line so far"
/// ```
///
/// ```gleam
/// assert tui.live_reasoning_digest("one\ntwo") == "2 lines so far"
/// ```
@internal
pub fn live_reasoning_digest(text: String) -> String {
  let count = text |> string.split("\n") |> list.length
  int.to_string(count)
  <> case count {
    1 -> " line so far"
    _ -> " lines so far"
  }
}

/// The collapsed stand-in for a reasoning block the daemon has committed.
///
/// The block no longer moves, so the reader can be given something to
/// decide on: its opening line, clipped, and the key that opens the rest.
/// The row bypasses the Markdown renderer, so a line that only opens a
/// construct — a fence, or a heading's or a quotation's marker — would reach
/// the reader as punctuation standing in for a whole block of reasoning. A
/// fence line is skipped and the markers are stripped, leaving the first
/// line that actually says something. A block of only blank lines and
/// markers has no such line, and falls back to its own text so the row is
/// never empty.
///
/// ## Examples
///
/// ```gleam
/// assert tui.settled_reasoning_digest("First.\n\nSecond.")
///   == "First.  [Ctrl+G to expand]"
/// ```
///
/// ```gleam
/// assert tui.settled_reasoning_digest("## Plan")
///   == "Plan  [Ctrl+G to expand]"
/// ```
@internal
pub fn settled_reasoning_digest(text: String) -> String {
  let opening =
    text
    |> string.split("\n")
    |> list.filter_map(digest_opening_line)
    |> list.first
    |> result.unwrap(text)
  compact(opening, reasoning_digest_limit) <> expand_hint
}

// Whether one source line can open a digest, and what it reads as if it can.
// A blank line and a fence delimiter say nothing on their own; a heading or
// quotation marker says something only about the line that carries it, so it
// is shed and the remainder is judged again — a line of markers alone falls
// through to the next candidate.
fn digest_opening_line(line: String) -> Result(String, Nil) {
  let trimmed = string.trim(line)
  case trimmed {
    "" -> Error(Nil)
    "```" <> _ | "~~~" <> _ -> Error(Nil)
    "#" <> rest | ">" <> rest -> digest_opening_line(rest)
    body -> Ok(body)
  }
}

/// How much of a settled reasoning block's opening line a digest keeps.
///
/// A budget for the reader's attention, not for the layout: about a line of
/// prose is as much as a collapsed row should ask anyone to read. The row
/// holds its single row because it is clipped to the pane, so this limit
/// only decides how much of the opening line a wide terminal shows.
pub const reasoning_digest_limit = 64

/// How the transcript names the key that opens a collapsed row, in the
/// wording `composer` already uses for a bounded user turn.
pub const expand_hint = "  [Ctrl+G to expand]"

/// Bounds a partial tool call to its name until durable arguments arrive.
@internal
pub fn live_tool_call_summary(name: String) -> String {
  text_hygiene.single_line(name) <> " · preparing arguments…"
}

fn record_lines(
  records: List(protocol.EntryRecord),
  model: Model,
) -> #(
  List(Line),
  Dict(tool_activity.Call, List(Line)),
  Dict(#(entry.Entry, Option(message.Origin)), List(Line)),
) {
  let entries =
    records
    |> list.reverse
    |> list.filter(fn(record) { record.strand == model.active_strand })
    |> list.map(fn(record) { record.entry })
  let owner = solo_owner(model.captured)
  case model.details_expanded {
    True -> #(
      list.flat_map(entries, entry_lines(_, True, owner)),
      dict.new(),
      dict.new(),
    )
    False -> {
      let #(reversed, calls, narratives) =
        entries
        |> tool_activity.project
        |> list.fold(#([], dict.new(), dict.new()), fn(acc, item) {
          case item {
            tool_activity.Narrative(value) -> {
              let key = #(value, owner)
              let lines =
                dict.get(model.compact_entry_cache, key)
                |> result.lazy_unwrap(fn() { entry_lines(value, False, owner) })
              #(
                list.append(list.reverse(lines), acc.0),
                acc.1,
                dict.insert(acc.2, key, lines),
              )
            }
            tool_activity.Tools(calls) -> {
              let #(lines, cached) =
                cached_activity_lines(calls, model.compact_call_cache)
              #(
                list.append(list.reverse(lines), acc.0),
                dict.merge(acc.1, cached),
                acc.2,
              )
            }
          }
        })
      #(list.reverse(reversed), calls, narratives)
    }
  }
}

// Outcome identity is part of the key, so receiving a result replaces its
// pending row. The new map contains only visible calls and releases old cuts.
fn cached_activity_lines(
  calls: List(tool_activity.Call),
  previous: Dict(tool_activity.Call, List(Line)),
) -> #(List(Line), Dict(tool_activity.Call, List(Line))) {
  let #(reversed, cached) =
    list.fold(calls, #([], dict.new()), fn(acc, call) {
      let lines =
        dict.get(previous, call)
        |> result.lazy_unwrap(fn() { activity_call_lines(call) })
      #(
        list.append(list.reverse(lines), acc.0),
        dict.insert(acc.1, call, lines),
      )
    })
  #([activity_heading(calls), ..list.reverse(reversed)], cached)
}

// Compact mode folds arguments and results, never invocation history. Every
// call keeps its chronological row so scrolling can recover earlier work.
fn activity_heading(calls: List(tool_activity.Call)) -> Line {
  let failed =
    list.count(calls, fn(call) {
      case call.outcome {
        Some(message.ToolResultMessage(is_error: True, ..)) -> True
        _ -> False
      }
    })
  let count = list.length(calls)
  let heading =
    "tools · "
    <> int.to_string(count)
    <> case count {
      1 -> " call"
      _ -> " calls"
    }
    <> case failed {
      0 -> ""
      n -> " · " <> int.to_string(n) <> " failed"
    }
    <> " · Ctrl+g expands details"
  Line(System, heading)
}

fn activity_call_lines(call: tool_activity.Call) -> List(Line) {
  let summary =
    tool_call_summary(call.invocation.name, call.invocation.arguments, False)
  let rows = case call.outcome {
    None -> [Line(ToolCall, summary <> " · awaiting result")]
    Some(message.ToolResultMessage(is_error: True, content:, ..)) -> [
      Line(ToolFailure, summary),
      Line(
        ToolResult,
        content
          |> list.map(tool_result_text)
          |> string.join("\n")
          |> compact(110),
      ),
    ]
    Some(message.ToolResultMessage(
      is_error: False,
      details: Some(json.Object(fields)),
      ..,
    ))
      if call.invocation.name == "fs_edit"
    -> [Line(ToolCall, "✓ " <> summary), ..edit_patch_lines(fields, False)]
    Some(message.ToolResultMessage(
      is_error: False,
      content: content,
      details: details,
      ..,
    ))
      if call.invocation.name == "context_remaining"
    -> [
      Line(ToolCall, "✓ " <> summary),
      ..tool_result_lines(
        "context_remaining",
        content,
        details,
        is_error: False,
        details_expanded: False,
      )
    ]
    Some(message.ToolResultMessage(is_error: False, ..)) -> [
      Line(ToolCall, "✓ " <> summary),
    ]
    Some(message.UserMessage(..))
    | Some(message.AssistantMessage(..))
    | Some(message.CustomMessage(..)) -> [Line(ToolCall, summary)]
  }
  list.append(
    rows,
    note_call_lines(
      call.invocation.name,
      call.invocation.arguments,
      notes_view.Excerpt,
    ),
  )
}

// Notes are useful output, even when ordinary tool details are collapsed.
// Known note tools expose their value; arbitrary tool JSON keeps its own schema.
fn note_call_lines(
  name: String,
  arguments: json.JsonValue,
  extent: notes_view.Extent,
) -> List(Line) {
  let value = case name, arguments {
    "agent_note", json.Object(fields) -> list.key_find(fields, "value")
    "remember", json.Object(fields) -> list.key_find(fields, "note")
    "agent_send", json.Object(fields) -> list.key_find(fields, "message")
    _, _ -> Error(Nil)
  }
  case value {
    Ok(value) -> {
      let body = notes_view.readable(json.to_string(value))
      let body = case name, extent {
        "agent_send", notes_view.Excerpt -> message_excerpt(body)
        _, _ -> body
      }
      [Line(ToolDetail, body)]
    }
    Error(Nil) -> []
  }
}

// A message preview preserves Markdown paragraphs; expansion exposes the
// complete body from the same immutable call arguments.
fn message_excerpt(body: String) -> String {
  let lines = string.split(body, "\n")
  case list.drop(lines, 12) {
    [] -> body
    _ ->
      string.join(list.take(lines, 12), "\n")
      <> "\n\n… Ctrl+g shows the complete message"
  }
}

// These are captured tool diffs, not a claim about the worktree's current
// contents. Retention can omit earlier edits, and later external edits are
// outside this transcript's authority, so the panel names that boundary.
fn diff_content(model: Model) -> List(Line) {
  case model.worktree.board {
    Some(_) ->
      list.map(worktree_view.patches(model.worktree), fn(row) {
        case row {
          worktree_view.PatchHeading(text) -> Line(System, text)
          worktree_view.PatchBody(text) -> Line(ToolPatch, text)
        }
      })
    None -> [
      Line(System, model.worktree.message),
      ..captured_diff_content(model)
    ]
  }
}

fn captured_diff_content(model: Model) -> List(Line) {
  let edits =
    model.records
    |> list.reverse
    |> list.filter(fn(record) { record.strand == model.active_strand })
    |> list.flat_map(fn(record) {
      case record.entry {
        entry.MessageEntry(
          message: message.ToolResultMessage(
            tool_name: "fs_edit",
            is_error: False,
            details: Some(json.Object(fields)),
            ..,
          ),
          ..,
        ) ->
          case string_field(fields, "diff") {
            None -> []
            Some(diff) -> [
              Line(
                System,
                string_field(fields, "path")
                  |> option.unwrap("edited file"),
              ),
              Line(ToolPatch, diff),
            ]
          }
        _ -> []
      }
    })
  case edits {
    [] -> [
      Line(System, "No captured edit diffs in the retained history window."),
    ]
    [_, ..] -> [
      Line(
        System,
        "Captured edits in history order · PgUp/PgDn scroll · Esc returns",
      ),
      ..edits
    ]
  }
}

fn entry_lines(
  value: entry.Entry,
  details_expanded: Bool,
  local_owner: Option(message.Origin),
) -> List(Line) {
  case value {
    entry.MessageEntry(message: value, ..) ->
      value
      |> harness_message_lines(details_extent(details_expanded))
      |> option.lazy_unwrap(fn() {
        message_lines(value, details_expanded, local_owner)
      })
    entry.CompactionEntry(summary:, tokens_before:, ..) -> [
      Line(
        System,
        "compacted " <> tokens(tokens_before) <> " tokens · " <> summary,
      ),
    ]
    entry.BranchSummaryEntry(summary:, ..) -> [
      Line(System, "branch summary · " <> summary),
    ]
    entry.CustomEntry(custom_type:, data:, ..) -> [
      Line(System, "custom/" <> custom_type <> option_json(data)),
    ]
  }
}

const agent_notes_intro = "Your own notes for strand `"

/// Extracts the server-injected notes digest from a run-start message.
///
/// Run-start context is stored as an ordinary user-role message by the frozen
/// entry schema. The TUI recognizes the server-owned fenced preamble so this
/// machine context does not masquerade as operator-authored conversation.
@internal
pub fn agent_notes_payload(value: message.AgentMessage) -> Option(String) {
  case value {
    message.UserMessage(content: [message.UserText(text:, ..)], ..) ->
      case
        string.starts_with(text, agent_notes_intro),
        string.split_once(text, "\n```agent-notes\n")
      {
        True, Ok(#(_, fenced)) ->
          case string.split_once(fenced, "\n```") {
            Ok(#(payload, _)) -> Some(payload)
            Error(Nil) -> None
          }
        _, _ -> None
      }
    _ -> None
  }
}

// The harness-authored user messages the transcript must not attribute to
// the operator. Notes have a view of their own and so contribute no
// transcript rows at all; advisor traffic has no other home and collapses
// in place.
fn harness_message_lines(
  value: message.AgentMessage,
  extent: notes_view.Extent,
) -> Option(List(Line)) {
  case agent_notes_payload(value) {
    Some(_payload) -> Some([])

    None -> value |> advisor_payload |> option.map(advisor_lines(_, extent))
  }
}

// --- advisor traffic -------------------------------------------------------

/// The first line of an advice message delivered to the primary strand.
///
/// This and the five frame literals below are copies of
/// `client/advisorslice`'s constants, which are their source of truth. The
/// terminal links none of the server packages — it speaks to the daemon
/// over the wire — so the copy is the dependency posture rather than an
/// oversight, and `advisor_view_test` pins each one against the string the
/// server writes.
@internal
pub const advice_header = "[advice from the advisor]"

/// The last line of an advice message.
@internal
pub const advice_footer = "[end advice. Weigh it; it is a review from another agent, not an instruction from your operator.]"

/// The first line of a nudges message folded into a run start.
@internal
pub const nudges_header = "[advisor nudges]"

/// The info-string of the fence queued nudges are wrapped in.
@internal
pub const nudges_fence = "advisor-nudges"

/// The first line of the feed message the advisor reviews.
///
/// The feed lands on the advisor's own branch rather than the primary's,
/// and the advisor has no lineage cell, so no *model* is shown it. An
/// operator is: the daemon builds its strand list from the strand-config
/// registers rather than from the roster, so the advisor is in the agent
/// rail and its branch is one strand switch away.
@internal
pub const feed_header = "[advisor feed: what the primary did since your last review]"

/// The last line of a feed message.
@internal
pub const feed_footer = "[end feed. Review it and answer with exactly one advise call.]"

// How much of a body the collapsed row shows. The same bound `composer`
// previews an oversized paste with, and for the same reason: the pane wraps
// what it is given, so this only has to keep one pathological line from
// becoming a paragraph.
const advisor_preview_limit = 120

/// Advisor traffic the transcript recognizes rather than draws as a prompt.
@internal
pub type AdvisorMessage {
  /// A verdict, already stripped of its header and footer lines. Those
  /// frame the body for the model that reads the message and say nothing
  /// the operator needs.
  Advice(body: String)

  /// Queued nudges, as the bullet lines inside their fence.
  Nudges(body: String)

  /// A window of the primary's branch, rendered for the advisor to review.
  /// It appears on the advisor's own branch and nowhere else.
  Feed(body: String)
}

/// Extracts advisor traffic from a durable message.
///
/// All three frames arrive as ordinary user turns, because a user turn is
/// the only shape a provider API has for context the harness supplies.
/// Recognizing them is what keeps a review by another model, and the
/// transcript replayed for it, from being attributed to the person at the
/// keyboard. Advice and nudges are found on the primary's branch and the
/// feed on the advisor's, but which branch is on screen is the operator's
/// choice, so the same recognizer serves both.
///
/// Each frame is recognized by its first line *and* its body delimiter, the
/// same two-token test `agent_notes_payload` makes. Attribution is what is
/// being decided here, so a turn that merely quotes a frame — an operator
/// pasting a nudge back to ask about it — has to fail the test rather than
/// be relabelled as the advisor's.
///
/// ## Examples
///
/// ```gleam
/// // tui.advisor_payload(an_ordinary_turn) == option.None
/// ```
///
@internal
pub fn advisor_payload(value: message.AgentMessage) -> Option(AdvisorMessage) {
  case value {
    message.UserMessage(content: [message.UserText(text:, ..)], ..) ->
      advisor_frame(text)

    // `advisorslice` writes every frame as a single text block, so any
    // other shape is somebody else's message.
    message.UserMessage(..)
    | message.AssistantMessage(..)
    | message.ToolResultMessage(..)
    | message.CustomMessage(..) -> None
  }
}

fn advisor_frame(text: String) -> Option(AdvisorMessage) {
  // Each frame opens with a header line of its own and only the nudges
  // frame carries a fence, so no text satisfies two of these tests and the
  // order they are tried in decides nothing.
  use <- option.lazy_or(advice_frame(text))
  use <- option.lazy_or(nudges_frame(text))

  feed_frame(text)
}

fn advice_frame(text: String) -> Option(AdvisorMessage) {
  text |> framed_body(advice_header, advice_footer) |> option.map(Advice)
}

fn nudges_frame(text: String) -> Option(AdvisorMessage) {
  text |> nudges_body |> option.map(Nudges)
}

fn feed_frame(text: String) -> Option(AdvisorMessage) {
  text |> framed_body(feed_header, feed_footer) |> option.map(Feed)
}

// The body between a header line and its footer, or nothing when the text
// does not carry both.
//
// The server writes both tokens on every frame — the footer is appended
// after the body, and its byte caps bound a slice rather than a frame — so
// requiring the pair costs nothing a reader would have seen. What it buys
// is the case this recognizer exists for: a turn that merely quotes a
// header, an operator pasting a verdict back to ask about it, stays the
// operator's own prompt instead of being redrawn as harness speech.
fn framed_body(text: String, header: String, footer: String) -> Option(String) {
  use #(first, rest) <- option.then(
    text |> string.split_once("\n") |> option.from_result,
  )
  use <- bool.guard(when: first != header, return: None)

  rest
  |> string.split_once("\n" <> footer)
  |> option.from_result
  |> option.map(fn(halves) { halves.0 })
}

// The bullet lines inside the nudges fence. A fence opened but never closed
// still renders its remainder: losing the text because a byte cap cut the
// closing fence would be worse than showing a little more than was fenced.
fn nudges_body(text: String) -> Option(String) {
  use <- bool.guard(
    when: !string.starts_with(text, nudges_header),
    return: None,
  )
  use #(_before, rest) <- option.then(
    text
    |> string.split_once("\n```" <> nudges_fence <> "\n")
    |> option.from_result,
  )

  case string.split_once(rest, "\n```") {
    Ok(#(body, _after)) -> Some(body)
    Error(Nil) -> Some(rest)
  }
}

/// Renders advisor traffic as transcript lines.
///
/// Collapsed, the row is one attribution line, so a verdict the operator
/// has already read costs a line rather than a screen; expanded, the body
/// follows under the same heading. The frame lines appear in neither: they
/// address the model that reads the message.
///
/// ## Examples
///
/// ```gleam
/// // tui.advisor_lines(tui.Advice("rerun the test"), notes_view.Complete)
/// ```
///
@internal
pub fn advisor_lines(
  value: AdvisorMessage,
  extent: notes_view.Extent,
) -> List(Line) {
  let heading = advisor_heading(value)

  // `System` rather than `User` in both: the row is context the harness put
  // on this branch, and the shaded `› User` block a user turn is drawn in
  // would say the operator typed it.
  case extent {
    notes_view.Excerpt -> [
      Line(System, heading <> advisor_preview(value) <> composer.expand_hint),
    ]

    notes_view.Complete -> [Line(System, heading), Line(ToolDetail, value.body)]
  }
}

// What the row is, in the words the operator reads. The count belongs in a
// nudges heading because the bullets are the whole of the content: a reader
// deciding whether to expand wants to know there are three of them.
fn advisor_heading(value: AdvisorMessage) -> String {
  case value {
    Advice(..) -> "advisor"

    Nudges(body:) ->
      "advisor nudges (" <> int.to_string(nudge_count(body)) <> ")"

    Feed(..) -> "advisor feed"
  }
}

// The opening of a verdict or a feed, shown beside the heading while the
// row is collapsed. Nudges add nothing here; their count is already in the
// heading.
fn advisor_preview(value: AdvisorMessage) -> String {
  case value {
    Advice(body:) | Feed(body:) ->
      ": " <> compact(opening_line(body), advisor_preview_limit)

    Nudges(..) -> ""
  }
}

fn opening_line(body: String) -> String {
  case string.split_once(body, "\n") {
    Ok(#(first, _rest)) -> first
    Error(Nil) -> body
  }
}

// Each nudge is written as one `- ` bullet, so counting the markers counts
// the nudges even where one of them ran to several lines.
fn nudge_count(body: String) -> Int {
  body
  |> string.split("\n")
  |> list.count(string.starts_with(_, "- "))
}

fn message_lines(
  value: message.AgentMessage,
  details_expanded: Bool,
  local_owner: Option(message.Origin),
) -> List(Line) {
  case value {
    message.UserMessage(content:, origin:, ..) -> [
      Line(
        User,
        user_author_prefix(origin, local_owner)
          <> {
          content
          |> list.map(user_block_text)
          |> string.join("\n")
          |> composer.transcript_text(details_expanded)
        },
      ),
    ]
    message.AssistantMessage(content:, error_message:, stop_reason:, ..) -> {
      let lines =
        list.flat_map(content, assistant_block_lines(_, details_expanded))
      list.append(lines, assistant_terminal_lines(stop_reason, error_message))
    }
    message.ToolResultMessage(tool_name:, content:, details:, is_error:, ..) ->
      tool_result_lines(tool_name, content, details, is_error, details_expanded)
    message.CustomMessage(schema:, payload:) -> [
      Line(System, schema <> " · " <> json.to_string(payload)),
    ]
  }
}

// The durable stop reason distinguishes a user abort from a failed turn. A
// clean abort commits no diagnostic at all, so an `Aborted` message that
// carries one names a stop the harness could not establish: an unconfirmed
// provider cancellation, a lost drain proof, or an orphaned response settled
// across a restart. The provider may still be generating in all three, so the
// text stays visible at both extents. It is dim detail rather than the failure
// style because it describes the provider, not a failed turn.
fn assistant_terminal_lines(
  reason: message.StopReason,
  diagnostic: Option(String),
) -> List(Line) {
  case reason, diagnostic {
    message.Aborted, Some(text) -> [
      Line(System, "Stopped"),
      Line(ToolDetail, text),
    ]
    message.Aborted, None -> [Line(System, "Stopped")]
    _, Some(text) -> [Line(Failure, text)]
    _, None -> []
  }
}

// Only a coherent presence cut can establish that this terminal is alone.
// Matching the connection as well as the historical identity keeps remote
// authors and pre-rename messages attributed even after their peers leave.
fn solo_owner(
  captured: Option(#(snapshot.Captured, snapshot_view.View)),
) -> Option(message.Origin) {
  use #(cut, view) <- option.then(captured)
  case cut.attachment.role, view.peers {
    snapshot.Owner, [peer]
      if peer.connection_id == cut.attachment.connection_id
      && peer.origin == cut.attachment.origin
    -> Some(cut.attachment.origin)
    _, _ -> None
  }
}

fn user_author_prefix(
  origin: Option(message.Origin),
  local_owner: Option(message.Origin),
) -> String {
  case origin {
    None -> ""
    Some(author) if Some(author) == local_owner -> ""
    Some(author) -> text_hygiene.single_line(author.name) <> ":\n"
  }
}

fn user_block_text(block: message.UserBlock) -> String {
  case block {
    message.UserText(text:, ..) -> text
    message.UserImage(mime_type:, ..) -> "[image " <> mime_type <> "]"
  }
}

// Both questions have the same two answers: whether a row carries a whole
// value or a cut of it. The daemon's truncation flag already names them and
// the row builders below take that type, so the Ctrl+g state is converted to
// it here rather than at each call site.
fn details_extent(details_expanded: Bool) -> notes_view.Extent {
  case details_expanded {
    True -> notes_view.Complete
    False -> notes_view.Excerpt
  }
}

fn assistant_block_lines(
  block: message.AssistantBlock,
  details_expanded: Bool,
) -> List(Line) {
  case block {
    message.AssistantText(text:, ..) -> [Line(Assistant, text)]
    message.AssistantThinking(thinking:, redacted:, ..) ->
      case redacted {
        // A redacted block has no text behind the marker, so expanding it
        // would show the same row again. It stays one row in both modes.
        True -> [Line(ReasoningDigest, "redacted")]

        False -> [
          settled_reasoning_line(thinking, details_extent(details_expanded)),
        ]
      }
    message.AssistantToolCall(call:) -> {
      let message.ToolCall(name:, arguments:, ..) = call
      case
        code_mode_program(name, arguments, details_expanded),
        patch_program(name, arguments, details_expanded)
      {
        Some(program), _ -> [
          Line(ToolCall, "code_mode"),
          Line(ToolDetail, program),
        ]
        None, Some(program) -> [
          Line(ToolCall, "apply_patch"),
          Line(ToolDetail, program),
        ]
        None, None -> [
          Line(ToolCall, tool_call_summary(name, arguments, details_expanded)),
          ..note_call_lines(name, arguments, details_extent(details_expanded))
        ]
      }
    }
  }
}

fn patch_program(
  name: String,
  arguments: json.JsonValue,
  details_expanded: Bool,
) -> Option(String) {
  case name, arguments {
    "apply_patch", json.Object(fields) ->
      case string_field(fields, "patch") {
        Some(patch) -> {
          let source = case details_expanded {
            True -> patch
            False -> program_preview(patch, 24)
          }
          Some("```diff\n" <> source <> "\n```")
        }
        None -> None
      }
    _, _ -> None
  }
}

/// Renders a structured code-mode call as bounded fenced Gleam.
///
/// This is internal because the shape belongs to the transcript projection;
/// it is public only so the executed-program display law can be pinned.
///
/// ## Examples
///
/// ```gleam
/// let arguments = json.Object([#("program", json.String("pub fn main() {}"))])
/// let assert Some(source) = tui.code_mode_program("code_mode", arguments, True)
/// ```
@internal
pub fn code_mode_program(
  name: String,
  arguments: json.JsonValue,
  details_expanded: Bool,
) -> Option(String) {
  case name, arguments {
    "code_mode", json.Object(fields) ->
      case list.key_find(fields, "program") {
        Ok(json.String(program)) -> {
          let source = case details_expanded {
            True -> program
            False -> program_preview(program, 12)
          }
          Some(fenced_gleam(source))
        }
        Ok(_) | Error(Nil) -> None
      }
    _, _ -> None
  }
}

fn fenced_gleam(source: String) -> String {
  case string.ends_with(source, "\n") {
    True -> "```gleam\n" <> source <> "```"
    False -> "```gleam\n" <> source <> "\n```"
  }
}

fn program_preview(program: String, limit: Int) -> String {
  let lines = string.split(program, "\n")
  case list.drop(lines, limit) {
    [] -> program
    _ ->
      lines
      |> list.take(limit)
      |> list.append(["// …"])
      |> string.join("\n")
  }
}

/// Formats the operator-relevant part of a tool call without exposing the
/// transport JSON envelope as the primary UI.
@internal
pub fn tool_call_summary(
  name: String,
  arguments: json.JsonValue,
  details_expanded: Bool,
) -> String {
  // Full argument encoding belongs to the fallback. Eagerly encoding a
  // large patch or file body just to display its path wastes every repaint.
  case name, arguments {
    "bash", json.Object(fields) ->
      case string_field(fields, "command") {
        Some(command) ->
          case details_expanded {
            True -> "Bash($ " <> command <> ")"
            False -> "Bash(" <> compact(command, 112) <> ")"
          }
        None ->
          generic_tool_call(name, json.to_string(arguments), details_expanded)
      }
    "read", json.Object(fields)
    | "fs_read", json.Object(fields)
    | "fs_write", json.Object(fields)
    | "fs_edit", json.Object(fields)
    ->
      case string_field(fields, "path") {
        Some(path) -> name <> " · " <> compact(path, 112)
        None ->
          generic_tool_call(name, json.to_string(arguments), details_expanded)
      }
    "agent_spawn", json.Object(fields) ->
      case string_field(fields, "purpose") {
        Some(purpose) ->
          case details_expanded {
            True ->
              "agent_spawn\npurpose: "
              <> purpose
              <> option_text(string_field(fields, "brief"), "\nbrief: ")
            False -> "agent_spawn · " <> compact(purpose, 108)
          }
        None ->
          generic_tool_call(name, json.to_string(arguments), details_expanded)
      }
    "agent_send", json.Object(fields) ->
      case string_field(fields, "to") {
        Some(recipient) -> "Message to " <> recipient
        None ->
          generic_tool_call(name, json.to_string(arguments), details_expanded)
      }
    "agent_wait", json.Object(fields) ->
      case list.key_find(fields, "handles") {
        Ok(json.Array(handles)) ->
          "agent_wait · "
          <> int.to_string(list.length(handles))
          <> case handles {
            [_] -> " subagent"
            _ -> " subagents"
          }
        _ ->
          generic_tool_call(name, json.to_string(arguments), details_expanded)
      }
    "grep", json.Object(fields) ->
      "grep"
      <> option_text(string_field(fields, "pattern"), " · ")
      <> option_text(string_field(fields, "path"), " in ")
    "agent_note", json.Object(fields) ->
      "agent_note"
      <> option_text(string_field(fields, "key"), " · ")
      <> case details_expanded {
        True -> "\n" <> json.to_string(arguments)
        False -> ""
      }
    "remember", json.Object(_) ->
      case details_expanded {
        True -> "remember\n" <> json.to_string(arguments)
        False -> "remember · durable note"
      }
    "agent_notes", json.Object(fields) ->
      "agent_notes" <> option_text(string_field(fields, "prefix"), " · ")
    "context_remaining", json.Object(_) -> "context remaining"
    _, _ -> generic_tool_call(name, json.to_string(arguments), details_expanded)
  }
}

fn generic_tool_call(
  name: String,
  rendered: String,
  details_expanded: Bool,
) -> String {
  case details_expanded {
    True -> name <> "\n" <> rendered
    False -> name <> " · " <> compact(rendered, 120)
  }
}

fn option_text(value: Option(String), prefix: String) -> String {
  case value {
    Some(text) -> prefix <> text
    None -> ""
  }
}

fn string_field(
  fields: List(#(String, json.JsonValue)),
  name: String,
) -> Option(String) {
  case list.key_find(fields, name) {
    Ok(json.String(value)) -> Some(value)
    _ -> None
  }
}

fn tool_result_lines(
  tool_name: String,
  content: List(message.ToolResultBlock),
  details: Option(json.JsonValue),
  is_error is_error: Bool,
  details_expanded details_expanded: Bool,
) -> List(Line) {
  let result = content |> list.map(tool_result_text) |> string.join("\n")
  let result = case tool_name, is_error {
    "fs_read", False -> file_read_view.render(result)
    _, _ -> result
  }
  case tool_name, is_error, details {
    "code_mode", False, Some(json.Object(fields)) ->
      code_mode_result_lines(fields, result, details_expanded)
    "fs_edit", False, Some(json.Object(fields)) -> [
      Line(ToolResult, "fs_edit · " <> compact(result, 120)),
      ..edit_patch_lines(fields, details_expanded)
    ]
    "context_remaining", False, Some(json.Object(fields)) ->
      context_remaining_result_lines(
        fields,
        result,
        details_extent(details_expanded),
      )
    _, True, _ -> [
      Line(ToolFailure, case details_expanded {
        True -> tool_name <> "\n" <> result
        False -> tool_name <> " · " <> compact(result, 120)
      }),
    ]
    _, False, _ -> [
      Line(ToolResult, case details_expanded {
        True -> tool_name <> "\n" <> result
        False -> tool_name <> " · " <> compact(result, 120)
      }),
    ]
  }
}

// The tool's prose is guidance for the model. The transcript already has the
// measured fields, so show the operator the compact arithmetic instead.
fn context_remaining_result_lines(
  fields: List(#(String, json.JsonValue)),
  fallback: String,
  extent: notes_view.Extent,
) -> List(Line) {
  case context_remaining_summary(fields) {
    Some(summary) ->
      case extent {
        notes_view.Excerpt -> [Line(ToolResult, summary)]
        notes_view.Complete -> [
          Line(ToolResult, summary),
          Line(ToolDetail, context_remaining_boundary(fields)),
        ]
      }
    None -> [
      Line(ToolResult, case extent {
        notes_view.Complete -> "context_remaining\n" <> fallback
        notes_view.Excerpt -> "context_remaining · " <> compact(fallback, 120)
      }),
    ]
  }
}

fn context_remaining_summary(
  fields: List(#(String, json.JsonValue)),
) -> Option(String) {
  use window <- option.then(int_field(fields, "window"))
  use used <- option.then(int_field(fields, "used_tokens"))
  use capacity <- option.then(int_field(fields, "context_window"))
  use remaining <- option.then(int_field(fields, "remaining_tokens"))
  let boundary = case int_field(fields, "checkpoint_at") {
    Some(_) -> " until checkpoint"
    None -> " before context limit"
  }
  Some(
    "context remaining · window "
    <> int.to_string(window)
    <> " · "
    <> "~"
    <> tokens(used)
    <> " / "
    <> tokens(capacity)
    <> " used · ~"
    <> tokens(remaining)
    <> boundary,
  )
}

fn context_remaining_boundary(
  fields: List(#(String, json.JsonValue)),
) -> String {
  let checkpoint = case int_field(fields, "checkpoint_at") {
    Some(value) -> "checkpoint at " <> tokens(value)
    None -> "no checkpoint"
  }
  let notes = int_field(fields, "notes") |> option.unwrap(0)
  checkpoint <> " · " <> int.to_string(notes) <> " saved notes"
}

fn int_field(
  fields: List(#(String, json.JsonValue)),
  name: String,
) -> Option(Int) {
  case list.key_find(fields, name) {
    Ok(json.Int(value)) -> Some(value)
    _ -> None
  }
}

// An edit renders as the unified diff its details carry — what changed,
// coloured as a diff — under the tool's one-line summary. Collapsed, the
// first stretch of the diff is enough to recognise the edit; expanded,
// the whole of it. Details without a diff (an older record) fall back to
// the summary alone.
fn edit_patch_lines(
  fields: List(#(String, json.JsonValue)),
  details_expanded: Bool,
) -> List(Line) {
  case string_field(fields, "diff") {
    Some(diff) -> {
      let shown = case details_expanded {
        True -> diff
        False -> program_preview(diff, 24)
      }
      [Line(ToolPatch, shown)]
    }
    None -> []
  }
}

fn code_mode_result_lines(
  fields: List(#(String, json.JsonValue)),
  fallback: String,
  details_expanded: Bool,
) -> List(Line) {
  let status = string_field(fields, "status") |> option.unwrap("completed")
  let value = case list.key_find(fields, "value") {
    Ok(value) -> value
    Error(Nil) -> json.String(fallback)
  }
  let sandbox = sandbox_summary(fields)
  case details_expanded {
    False -> [
      Line(
        ToolResult,
        "code_mode · "
          <> status
          <> " · result "
          <> compact(json.to_string(value), 90)
          <> option_text(sandbox, " · "),
      ),
    ]
    True -> [
      Line(ToolResult, "code_mode · " <> status),
      Line(
        ToolDetail,
        "result\n\n```json\n" <> pretty_json(value, 0) <> "\n```",
      ),
      ..case sandbox {
        Some(summary) -> [Line(System, summary)]
        None -> []
      }
    ]
  }
}

fn sandbox_summary(fields: List(#(String, json.JsonValue))) -> Option(String) {
  case list.key_find(fields, "sandbox") {
    Ok(json.Object(sandbox)) -> {
      let build = enforcement_summary(sandbox, "build")
      let node = enforcement_summary(sandbox, "node")
      Some("sandbox · build " <> build <> " · satellite " <> node)
    }
    _ -> None
  }
}

fn enforcement_summary(
  sandbox: List(#(String, json.JsonValue)),
  name: String,
) -> String {
  case list.key_find(sandbox, name) {
    Ok(json.Object(report)) -> {
      let reported = case list.key_find(report, "reported") {
        Ok(json.Bool(value)) -> value
        _ -> False
      }
      let enforced = json_array_length(report, "enforced")
      let skipped = json_array_length(report, "skipped")
      case reported {
        True ->
          "enforced "
          <> int.to_string(enforced)
          <> " layers; skipped "
          <> int.to_string(skipped)
        False -> "not launched"
      }
    }
    _ -> "not reported"
  }
}

fn json_array_length(
  fields: List(#(String, json.JsonValue)),
  name: String,
) -> Int {
  case list.key_find(fields, name) {
    Ok(json.Array(items)) -> list.length(items)
    _ -> 0
  }
}

fn pretty_json(value: json.JsonValue, depth: Int) -> String {
  let indent = string.repeat("  ", depth)
  let child_indent = string.repeat("  ", depth + 1)
  case value {
    json.Object([]) -> "{}"
    json.Object(fields) ->
      fields
      |> list.map(fn(field) {
        let #(name, value) = field
        child_indent
        <> json.to_string(json.String(name))
        <> ": "
        <> pretty_json(value, depth + 1)
      })
      |> string.join(",\n")
      |> fn(body) { "{\n" <> body <> "\n" <> indent <> "}" }
    json.Array([]) -> "[]"
    json.Array(items) ->
      items
      |> list.map(fn(item) { child_indent <> pretty_json(item, depth + 1) })
      |> string.join(",\n")
      |> fn(body) { "[\n" <> body <> "\n" <> indent <> "]" }
    scalar -> json.to_string(scalar)
  }
}

fn compact(text: String, limit: Int) -> String {
  let one_line = text_hygiene.single_line(text)
  case string.drop_start(one_line, limit) {
    "" -> one_line
    _ -> string.slice(one_line, 0, limit - 1) <> "…"
  }
}

fn tool_result_text(block: message.ToolResultBlock) -> String {
  case block {
    message.ToolResultText(text:, ..) -> text
    message.ToolResultImage(mime_type:, ..) -> "[image " <> mime_type <> "]"
  }
}

fn option_json(value: Option(json.JsonValue)) -> String {
  case value {
    Some(data) -> " · " <> json.to_string(data)
    None -> ""
  }
}

fn tokens(value: Int) -> String {
  case value >= 1_000_000, value >= 1000 {
    True, _ -> int.to_string(value / 1_000_000) <> "m"
    False, True -> int.to_string(value / 1000) <> "k"
    False, False -> int.to_string(value)
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

/// The shortest generation a rate is reported for, in milliseconds. A
/// sub-second window is dominated by request latency and by how the
/// provider batches its stream, so the quotient says nothing about
/// throughput; the footer shows no rate rather than a wrong one.
pub const output_rate_min_ms = 1000

/// Output tokens per second from a settled generation's output count and
/// the milliseconds it took. A generation shorter than
/// `output_rate_min_ms` reports `None` rather than a rate divided by a
/// window too small to mean anything.
///
/// ## Examples
///
/// ```gleam
/// assert tui.output_rate(300, 2000) == option.Some(150)
/// ```
///
/// ```gleam
/// assert tui.output_rate(126, 1) == option.None
/// ```
///
@internal
pub fn output_rate(output_tokens: Int, elapsed_ms: Int) -> Option(Int) {
  case elapsed_ms >= output_rate_min_ms {
    True -> Some(output_tokens * 1000 / elapsed_ms)
    False -> None
  }
}

/// The footer's rate suffix: empty until a generation has been timed.
///
/// ## Examples
///
/// ```gleam
/// assert tui.output_rate_label(option.Some(87)) == " · 87 tok/s"
/// ```
///
/// ```gleam
/// assert tui.output_rate_label(option.None) == ""
/// ```
///
@internal
pub fn output_rate_label(rate: Option(Int)) -> String {
  case rate {
    Some(rate) -> " · " <> int.to_string(rate) <> " tok/s"
    None -> ""
  }
}

pub fn usage_summary(usage: message.Usage) -> String {
  "Total est $"
  <> money(usage.cost.total)
  <> " · in "
  <> tokens(usage.input)
  <> " · out "
  <> tokens(usage.output)
  <> " · cache "
  <> tokens(usage.cache_read)
  <> "/"
  <> tokens(usage.cache_write)
}

// Currency is display data. Round once to cents before splitting the whole
// and fractional parts, so binary floating point tails never reach the footer.
fn money(value: Float) -> String {
  let cents = int.max(0, float.round(value *. 100.0))
  int.to_string(cents / 100)
  <> "."
  <> string.pad_start(int.to_string(cents % 100), 2, "0")
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
        SessionSelector(selector) ->
          update_session_selector(key, model, selector)
        DaemonSelector(selector) -> update_daemon_selector(key, model, selector)
        ApprovalInspector(panel) ->
          case approval_panel.update(key, panel) {
            approval_panel.Close -> Model(..model, overlay: NoOverlay)
            approval_panel.Continue(next) ->
              Model(..model, overlay: ApprovalInspector(next))
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
    session_selector.NextPage(after, revision) ->
      load_catalogue(model, after, Some(revision))
    session_selector.FirstPage -> load_catalogue(model, "", None)
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
      let selected =
        Model(
          ..model,
          overlay: NoOverlay,
          current_model: name,
          repaint_phase: !model.repaint_phase,
          notice: "model: " <> name,
        )
        |> send_frame(protocol.set_model(
          model.next_id,
          model.active_strand,
          name,
        ))
      append_system(selected, "active model changed to " <> name)
    }
  }
}

fn update_agent_inspector(key: keys.Key, model: Model, selected: Int) -> Model {
  case key {
    keys.Escape | keys.Tab ->
      Model(
        ..model,
        overlay: NoOverlay,
        repaint_phase: !model.repaint_phase,
        notice: "agents closed",
      )
    keys.Up ->
      Model(
        ..model,
        overlay: AgentInspector(agents.move_selection(
          selected,
          list.length(model.strands),
          False,
        )),
      )
    keys.Down ->
      Model(
        ..model,
        overlay: AgentInspector(agents.move_selection(
          selected,
          list.length(model.strands),
          True,
        )),
      )
    keys.Enter ->
      case agents.selected_strand(model.strands, selected) {
        Some(strand) -> switch_active_strand(model, strand)
        None -> model
      }
    keys.PageUp
    | keys.PageDown
    | keys.Backspace
    | keys.Left
    | keys.Right
    | keys.Delete
    | keys.BackTab
    | keys.Home
    | keys.End
    | keys.Alt(_)
    | keys.Ctrl(_)
    | keys.Char(_)
    | keys.Insert
    | keys.F(_)
    | keys.Unknown(_) -> model
  }
}

fn update_main_key(key: keys.Key, model: Model) -> Model {
  case diff_shown(model), model.worktree.focus, key {
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
    keys.Char("r"), False, True -> refresh_notes(model)
    keys.Ctrl("g"), _, _ -> toggle_details(model)
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
      case text_area.value(model.input) == "" && reading_history(model) {
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
        Some(_), _ -> waiting_notice(model)
      }
    }
  }
}

fn waiting_notice(model: Model) -> Model {
  Model(..model, notice: "Waiting to send · draft locked · Esc cancels")
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
  Model(..model, selection: None, selection_frame: None)
}

// A press starts over: whatever was highlighted is replaced by a fresh
// selection in the area the press landed in.
fn begin_selection(model: Model, at: geometry.Position) -> Model {
  let screen = geometry.rect_new(0, 0, model.width, model.height)
  let #(_, _, input_area, _) = layout(screen, model)
  use <- bool.lazy_guard(
    reading_history(model) && at.y == input_area.position.y,
    fn() {
      scroll_transcript(clear_selection(model), False, model.rendered_row_count)
    },
  )
  case diff_navigation_hit(model, at) {
    Some(selected) ->
      Model(
        ..model,
        selection: None,
        selection_frame: None,
        diff_scroll_offset: 0,
        worktree: worktree_view.State(
          ..model.worktree,
          selected:,
          focus: worktree_view.Navigator,
        ),
      )
      |> invalidate_transcript
    None ->
      Model(
        ..model,
        selection: Some(selection.start(hit_area(model, at), at)),
        selection_frame: Some(frame_on_display(model)),
      )
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
        True -> Model(..model, selection: None, selection_frame: None)
        False -> {
          let text =
            selection.text(
              option.lazy_unwrap(model.selection_frame, fn() {
                frame_on_display(model)
              }),
              selected,
            )
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

// The frame the terminal is showing is the cached one, stale or not: a copy
// takes what the hand highlighted, not what a fresh render would draw.
fn frame_on_display(model: Model) -> buffer.Buffer {
  let screen = geometry.rect_new(0, 0, model.width, model.height)
  case model.frame_cache {
    Some(FrameCache(rendered: #(shown, _), ..)) -> shown
    None -> render_frame(model, screen).0
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

/// The area a press at this cell selects within.
///
/// The panels are tried innermost first, so a press on the transcript's text
/// selects transcript rows without the border glyphs; a press anywhere else,
/// a border or the header or footer, selects across the whole screen the way
/// a terminal would.
///
/// ## Examples
///
/// ```gleam
/// assert tui.hit_area(model, geometry.Position(2, 2))
///   == tui.panel_inner(transcript_panel)
/// ```
@internal
pub fn hit_area(model: Model, at: geometry.Position) -> Rect {
  let screen = geometry.rect_new(0, 0, model.width, model.height)
  let #(_, body_area, input_area, _) = layout(screen, model)
  let #(transcript_panel, agent_panel, changes_panel) =
    body_layout(body_area, model)
  [
    panel_inner(transcript_panel),
    panel_inner(agent_panel),
    panel_inner(changes_panel),
    panel_inner(input_area),
  ]
  |> list.find(fn(area) { geometry.contains(area, at) })
  |> result.unwrap(screen)
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
    scroll_offset(model.scroll_offset + viewport_backlog(model), older, rows)
    |> bounded_scroll_offset(
      model.rendered_row_count,
      transcript_viewport_height(model),
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
        True ->
          apply_cut(Model(..model, scrollback: history_view.empty()), cut, view)
        False -> {
          let history = history_view.freeze(model.scrollback)
          let history = case
            older
            && offset + transcript_viewport_height(model)
            >= model.rendered_row_count - 10
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
      || model.scroll_offset + transcript_viewport_height(model)
      < model.rendered_row_count - 10,
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
    main_shows_diff(model) || model.worktree.focus == worktree_view.Navigator
  {
    True -> scroll_diff(model, direction, rows)
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
  let screen = geometry.rect_new(0, 0, model.width, model.height)
  let #(_, body, _, _) = layout(screen, model)
  let #(_, _, changes) = body_layout(body, model)
  case main_shows_diff(model) || geometry.contains(changes, position) {
    True -> scroll_diff(model, direction, 3)
    False -> scroll_transcript(model, direction == Older, 3)
  }
}

fn scroll_diff(model: Model, direction: ScrollDirection, rows: Int) -> Model {
  let offset =
    scroll_offset(model.diff_scroll_offset, direction == Older, rows)
    |> bounded_scroll_offset(model.diff_row_count, diff_patch_height(model))
  Model(
    ..model,
    diff_scroll_offset: offset,
    notice: "scrolling captured changes",
  )
}

fn transcript_viewport_height(model: Model) -> Int {
  transcript_height(
    model.height,
    input_height(model),
    footer_height(model.width),
  )
}

/// Returns the transcript rows left after fixed terminal surfaces are reserved.
@internal
pub fn transcript_height(
  height: Int,
  input_rows: Int,
  footer_rows: Int,
) -> Int {
  // The header consumes one row and the transcript border consumes two.
  int.max(1, height - input_rows - footer_rows - 3)
}

fn transcript_width(model: Model) -> Int {
  let #(main, _, _) =
    body_layout(geometry.rect_new(0, 0, model.width, model.height), model)
  int.max(1, main.size.width - 2)
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
    mutation_refusal(
      model,
      command.parse_with_skills(text_area.value(model.input), model.skills),
    )
  {
    Some(reason) -> append_error(model, reason)
    None -> {
      // This marker scopes the synchronous encoder call and, only if queued,
      // the later send. The draft itself never leaves its existing fields.
      let prepared = case
        mutating_submission(
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

fn mutation_refusal(model: Model, command: command.Command) -> Option(String) {
  let mutates = mutating_submission(model, command)
  case mutates, model.peer, model.channel {
    False, _, _ -> None
    True, Disconnected, _ -> Some("no conversation is attached; draft retained")
    True, Attached(_), Some(channel) ->
      case session_channel.mutation_available(channel) {
        True -> None
        False ->
          Some(
            "attachment is read-only or its command slot is busy; draft retained",
          )
      }
    True, Attached(_), None ->
      Some("conversation has not synchronized; draft retained")
    True, Preview, _ | True, Replaying, _ -> None
  }
}

fn mutating_submission(model: Model, command: command.Command) -> Bool {
  case command {
    command.Prompt(_)
    | command.Model(_)
    | command.Unschedule(..)
    | command.Fork(_)
    | command.Effort(_)
    | command.Compact
    | command.Abort
    | command.Steer(_)
    | command.Queue(_) -> True
    command.Approve(_) | command.Deny(_) -> True
    command.Empty -> model.attachments != []
    command.Help
    | command.Models
    | command.Strands
    | command.Schedules
    | command.Agents
    | command.Sessions
    | command.Rename(_)
    | command.Approvals(_)
    | command.Notes
    | command.Diff
    | command.QueueInspect
    | command.Summary
    | command.Context
    | command.ContextAll
    | command.Details
    | command.Strand(_)
    | command.Clear
    | command.Quit
    | command.Unknown(_)
    | command.MissingArgument(_) -> False
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
      append_error(model, "daemon control is unavailable; reconnect explicitly")
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
          append_error(
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
    True -> append_error(model, "a session switch is already in progress")
    False ->
      case bootstrap.discover_sessions(options) {
        Error(reason) -> append_error(model, reason)
        Ok([]) -> append_error(model, "no locally managed sessions found")
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
      append_error(
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
    Some(OverlaySubmission) | None -> clear_composer_text(model)
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
      |> invalidate_transcript
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
      send_frame(opened, protocol.models(opened.next_id))
    }
    command.Model(name) -> {
      let switched =
        Model(..cleared, current_model: name)
        |> send_frame(protocol.set_model(
          cleared.next_id,
          cleared.active_strand,
          name,
        ))
      append_system(switched, "active model changed to " <> name)
    }
    command.Strands | command.Agents ->
      Model(
        ..cleared,
        overlay: AgentInspector(active_strand_index(
          cleared.strands,
          cleared.active_strand,
        )),
        repaint_phase: !cleared.repaint_phase,
        notice: "agent inspector",
      )
    command.Schedules ->
      send_frame(cleared, protocol.schedules(cleared.next_id))
    command.Unschedule(name:, target:) -> {
      // An absent target means the strand the operator is looking at,
      // which is the row the listing above the prompt just printed. A
      // schedule a parent set onto a subagent needs the second word.
      let target = option.unwrap(target, cleared.active_strand)
      send_frame(
        append_system(
          cleared,
          "cancelling schedule " <> name <> " on " <> target,
        ),
        protocol.schedule_cancel(cleared.next_id, target, name),
      )
    }
    command.Sessions -> open_session_selector(cleared)
    command.Rename(name) ->
      case cleared.session {
        "" -> append_error(cleared, "no session is attached")
        id ->
          load_catalogue_after(
            cleared,
            "",
            None,
            Some(control_protocol.RenameSession(id, name)),
          )
      }
    command.Approvals(None) ->
      list.fold(approval_lines(cleared.approvals), cleared, fn(model, line) {
        append_system(model, line.text)
      })
    command.Approvals(Some(id)) ->
      request_decisions(Model(..cleared, inspecting_approval: Some(id)), [id])
    command.Approve(id) -> decide(cleared, id, approval.approve)
    command.Deny(id) -> decide(cleared, id, approval.deny)
    command.Notes ->
      refresh_notes(
        Model(
          ..cleared,
          help_open: False,
          notes_open: True,
          scroll_offset: 0,
          repaint_phase: !cleared.repaint_phase,
          notice: "agent notes",
        ),
      )
    command.QueueInspect -> open_queue(cleared)
    command.Summary -> open_summary(cleared)
    command.Context -> open_context(cleared, context_view.Overview)
    command.ContextAll -> open_context(cleared, context_view.All)
    command.Diff -> open_diff(cleared)
    command.Details -> toggle_details(cleared)
    command.Strand(name) ->
      case is_known_strand(cleared.strands, name) {
        True ->
          append_system(
            switch_active_strand(cleared, name),
            "active strand: " <> name,
          )
        False -> append_error(cleared, "unknown strand: " <> name)
      }
    command.Fork(name) ->
      send_frame(
        append_system(cleared, "fork queued: " <> name),
        protocol.fork(cleared.next_id, cleared.active_strand, name),
      )
    command.Effort(level) ->
      send_frame(
        append_system(
          cleared,
          "reasoning level for " <> cleared.active_strand <> ": " <> level,
        ),
        protocol.set_thinking(cleared.next_id, cleared.active_strand, level),
      )
    command.Compact ->
      send_frame(
        append_system(
          cleared,
          "compaction queued for " <> cleared.active_strand,
        ),
        protocol.compact(cleared.next_id, cleared.active_strand),
      )
    command.Abort ->
      send_frame(
        append_system(cleared, "abort queued for " <> cleared.active_strand),
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
    command.Unknown(name) -> append_error(cleared, "unknown command /" <> name)
    command.MissingArgument(name) ->
      append_error(cleared, "/" <> name <> " needs an argument")
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
    | command.Approve(_)
    | command.Deny(_)
    | command.Notes
    | command.Details
    | command.Strand(_)
    | command.Fork(_)
    | command.Effort(_)
    | command.Compact
    | command.Abort
    | command.Steer(_)
    | command.Queue(_)
    | command.Clear
    | command.Quit
    | command.Unknown(_)
    | command.MissingArgument(_) ->
      append_error(
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
    Some(OverlaySubmission) | None -> clear_composer(model)
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
      send_frame(
        sent,
        protocol.prompt_content(model.next_id, model.active_strand, content),
      )

    // A replay stops exactly where the live client's local work stopped.
    // The turn it produced is in the recording and arrives as an entry.
    Replaying -> sent
    Disconnected -> append_error(model, "no conversation is attached")
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
      |> invalidate_transcript
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

// Submitted text is newest-first so Up is a constant-time move to the common
// case. Consecutive duplicates collapse because resend remains available
// without allowing accidental double-enter presses to crowd out useful history.
fn remember_submission(model: Model, text: String) -> Model {
  case string.trim(text), model.history {
    "", _ -> model
    value, [latest, ..] if value == latest -> model
    value, history -> Model(..model, history: [value, ..history])
  }
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
  case active_interrupt(before) {
    Some(strand) -> hold_or_send_interrupt(cleared, before, strand, text)
    None ->
      case active_strand_live(before), before.submission_mode {
        False, _ -> send_prompt(cleared, text)

        // A prompt aimed at a running strand is held by the daemon and run
        // when that strand settles, so this is the same frame as the idle
        // case and needs no command of its own. Only the local echo differs.
        True, PromptNext -> send_prompt(cleared, text)
        True, SteerNow -> send_steer(cleared, text)
      }
  }
}

fn send_explicit_steer(cleared: Model, text: String, before: Model) -> Model {
  case active_interrupt(before) {
    Some(strand) -> hold_or_send_interrupt(cleared, before, strand, text)
    None -> send_steer(cleared, text)
  }
}

// The server refuses steer admissions after cancel_requested and abort drains
// anything admitted before it. The client therefore retains the instruction
// until the terminal transition, then starts the replacement turn exactly once.
fn hold_or_send_interrupt(
  cleared: Model,
  before: Model,
  strand: String,
  text: String,
) -> Model {
  // Modern hosts keep human input outside the operation being cancelled.
  // Send it immediately so its priority is shared across attached terminals.
  use <- bool.lazy_guard(before.channel != None, fn() {
    send_steer(cleared, text)
  })
  case active_strand_live(before) {
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
      send_frame(sent, protocol.prompt(model.next_id, strand, text))

    // The server echoed this turn back as an entry, and the recording has
    // it. Drawing a local copy here would show the operator's line twice.
    Replaying -> sent
    Disconnected -> append_error(model, "no conversation is attached")
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
      |> invalidate_transcript
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
  case model.peer, active_strand_live(model) {
    Attached(..), True ->
      Model(..model, awaiting_outcome: Some(submission))
      |> invalidate_transcript
    Replaying, True ->
      Model(..model, queued: in_commit_order(model.queued, submission))
      |> invalidate_transcript
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

// The daemon refused it, or it never reached the wire. No entry is coming,
// so the echo goes away with the submission rather than outliving it.
fn discard_own_turn(model: Model) -> Model {
  case model.awaiting_outcome {
    Some(_) -> Model(..model, awaiting_outcome: None) |> invalidate_transcript
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
  |> invalidate_transcript
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
  send_frame(
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
  send_frame(
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
    active_interrupt(model),
    active_strand_live(model),
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
  case active_strand_phase(model), active_interrupt(model) {
    None, _ -> Model(..model, notice: "nothing is running")
    Some(_), Some(_) -> Model(..model, notice: "interrupt already requested")
    Some(_), None -> {
      let strand = model.active_strand
      send_frame(
        Model(
          ..model,
          interrupt: Some(Interrupt(
            strand:,
            operation: captured_operation(model, strand),
            pending: None,
          )),
          submission_mode: PromptNext,
          notice: "interrupt requested; type the replacement steer",
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

fn active_interrupt(model: Model) -> Option(String) {
  case model.interrupt {
    Some(Interrupt(strand:, ..)) ->
      case strand == model.active_strand {
        True -> Some(strand)
        False -> None
      }
    None -> None
  }
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

fn active_strand_live(model: Model) -> Bool {
  case active_strand_phase(model) {
    Some(_) -> True
    None -> False
  }
}

fn active_strand_phase(model: Model) -> Option(String) {
  case model.submitting {
    Some(strand) if strand == model.active_strand -> Some("submitting")
    _ ->
      model.strands
      |> list.find_map(fn(strand) {
        let Strand(id:, live_phase:, ..) = strand
        case id == model.active_strand, live_phase {
          True, Some(phase) -> Ok(phase)
          _, _ -> Error(Nil)
        }
      })
      |> result.map(Some)
      |> result.unwrap(None)
  }
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

fn send_frame(model: Model, frame: String) -> Model {
  case model.channel {
    Some(channel) -> {
      let #(channel, disposition) = session_channel.submit(channel, frame)
      apply_submission(Model(..model, channel: Some(channel)), disposition)
    }
    None -> send_preview_frame(model, frame)
  }
}

fn apply_submission(
  model: Model,
  disposition: session_channel.Disposition,
) -> Model {
  case disposition {
    session_channel.Waiting(_) -> {
      let pending = case model.channel {
        Some(channel) -> session_channel.has_unsent(channel)
        None -> False
      }
      case pending {
        True ->
          waiting_notice(
            Model(
              ..model,
              pending_submission: Some(option.unwrap(
                model.pending_submission,
                OverlaySubmission,
              )),
              submitting: None,
            ),
          )
        False -> model
      }
    }
    session_channel.Sent(command, request_id) -> {
      let model = case command {
        "queued_input" | "edit_queued_input" ->
          Model(
            ..model,
            queue_editor: queue_editor.State(
              ..model.queue_editor,
              request_id: Some(request_id),
            ),
          )
        "context" ->
          Model(..model, context: context_view.sent(model.context, request_id))
        "live_jobs" -> Model(..model, jobs_request: Some(request_id))
        "worktree_diff" ->
          Model(
            ..model,
            worktree: worktree_view.sent(model.worktree, request_id),
          )
        _ -> model
      }
      let sent = case model.pending_submission {
        Some(ComposerSubmission) -> clear_composer(model)
        Some(OverlaySubmission) | None -> model
      }
      let submitting = case command, model.pending_submission {
        "prompt", Some(ComposerSubmission) -> Some(model.active_strand)
        _, _ -> sent.submitting
      }
      Model(
        ..sent,
        submitting: submitting,
        pending_submission: None,
        next_id: sent.next_id + 1,
        notice: case command {
          // Automatic observation must not erase a user's command outcome.
          "context" -> sent.notice
          _ -> command <> " sent"
        },
      )
      |> invalidate_frame
    }
    session_channel.DefinitelyNotSent(reason) -> {
      let retained = case model.channel {
        Some(channel) -> session_channel.has_unsent(channel)
        None -> False
      }
      let model = case retained {
        True -> model
        False -> Model(..model, pending_submission: None, submitting: None)
      }

      // The frame never reached the wire, so no entry answers it.
      append_error(
        Model(
          ..discard_own_turn(model),
          queue_editor: queue_editor.refused(model.queue_editor, reason),
        ),
        "Not sent: " <> reason <> "; draft retained",
      )
    }
  }
}

fn clear_composer(model: Model) -> Model {
  let cleared = clear_composer_text(model)
  Model(..cleared, attachments: [], submission_mode: PromptNext)
}

fn clear_composer_text(model: Model) -> Model {
  let remembered = remember_submission(model, text_area.value(model.input))
  Model(
    ..remembered,
    input: text_area.state_new(),
    history_index: 0,
    history_draft: "",
  )
}

fn send_preview_frame(model: Model, frame: String) -> Model {
  case model.peer {
    Attached(socket:) -> {
      connection.send(socket, frame)
      Model(..model, next_id: model.next_id + 1)
    }

    // Neither peer has anywhere to write, and neither may pretend it does.
    Preview | Replaying | Disconnected -> model
  }
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

fn is_known_strand(strands: List(protocol.Strand), name: String) -> Bool {
  list.any(strands, fn(strand) {
    let Strand(id:, ..) = strand
    id == name
  })
}

fn switch_active_strand(model: Model, strand: String) -> Model {
  let model = cancel_pending(model, "target change from " <> model.session)

  // The outgoing strand's window is put down before the incoming one is
  // picked up, so the switch never discards loaded history. Without this the
  // only surviving history would be whatever `cut.window` holds, and that is
  // the newest hundred records of the whole session across every strand: with
  // two busy sub-agents running, a return to `main` would show one or two of
  // its own entries and then spend the rest of the session scanning the
  // global sequence space backwards to find the ancestry it already had.
  let parked =
    dict.insert(model.parked_scrollback, model.active_strand, model.scrollback)
  let restored = dict.get(parked, strand) |> result.unwrap(history_view.empty())

  // The incoming strand's window is held directly from here on, so its parked
  // copy is removed rather than left to go stale behind the live one.
  let parked = dict.delete(parked, strand)
  let selected =
    Model(
      ..model,
      overlay: NoOverlay,
      active_strand: strand,
      parked_scrollback: parked,
      scrollback: restored,
      queued: [],
      awaiting_outcome: None,
      current_model: "loading…",
      scroll_offset: 0,
      record_cache_valid: False,
      repaint_phase: !model.repaint_phase,
      notice: "active strand: " <> strand,
    )
    |> invalidate_transcript
  case model.captured {
    Some(#(cut, view)) -> apply_cut(selected, cut, view)
    None -> send_frame(selected, protocol.config(model.next_id, strand))
  }
}

fn active_strand_index(strands: List(protocol.Strand), active: String) -> Int {
  active_strand_index_loop(strands, active, 0)
}

fn active_strand_index_loop(
  strands: List(protocol.Strand),
  active: String,
  index: Int,
) -> Int {
  case strands {
    [] -> 0
    [Strand(id:, ..), ..rest] ->
      case id == active {
        True -> index
        False -> active_strand_index_loop(rest, active, index + 1)
      }
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

fn append_system(model: Model, text: String) -> Model {
  Model(
    ..model,
    transcript: list.append(model.transcript, [Line(System, text)]),
    record_cache_valid: False,
    notice: text,
  )
  |> invalidate_transcript
  |> invalidate_frame
}

fn append_error(model: Model, text: String) -> Model {
  Model(
    ..model,
    transcript: list.append(model.transcript, [Line(Failure, text)]),
    record_cache_valid: False,
    notice: text,
  )
  |> invalidate_transcript
  |> invalidate_frame
}

// Transcript revisions advance only beside mutations of the projection's
// source data. Keeping the invalidation token separate from terminal ticks
// prevents session history from becoming an idle-time CPU cost.
fn invalidate_transcript(model: Model) -> Model {
  Model(..model, render_revision: model.render_revision + 1)
}

fn queue_owner(model: Model) -> String {
  case model.captured {
    Some(#(cut, _)) -> {
      let expected = cut.attachment.expected
      expected.session
      <> ":"
      <> expected.epoch
      <> ":"
      <> expected.incarnation
      <> ":"
      <> cut.attachment.connection_id
    }
    None -> ""
  }
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
  |> invalidate_frame
}

fn queue_rows(model: Model) -> List(snapshot_view.PendingInput) {
  case model.captured {
    Some(#(_, view)) ->
      option.unwrap(view.pending_inputs, [])
      |> list.filter(fn(row) { row.strand == model.active_strand })
    None -> []
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
        ),
      )
    keys.Down, queue_editor.Inspector ->
      Model(
        ..model,
        queue_editor: queue_editor.State(
          ..state,
          selected: int.min(
            int.max(0, list.length(queue_rows(model)) - 1),
            state.selected + 1,
          ),
        ),
      )
    keys.Enter, queue_editor.Inspector -> select_queue_input(model)
    keys.Ctrl("r"), queue_editor.Editor -> reconcile_queue_draft(model)
    keys.Ctrl("s"), queue_editor.Editor -> save_queue_draft(model)
    _, queue_editor.Editor ->
      edit_queue_text(model, fn(input) { queue_text_key(key, input) })
    _, queue_editor.Closed | _, queue_editor.Inspector -> model
  }
}

fn select_queue_input(model: Model) -> Model {
  let state = model.queue_editor
  case list.first(list.drop(queue_rows(model), state.selected)) {
    Ok(row) if row.editing == snapshot_view.Editable -> {
      let fetch =
        queue_editor.Fetch(
          queue_owner(model),
          queue_namespace(model),
          row.strand,
          row.id,
        )
      service_queue_read(
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
    Ok(_) ->
      Model(
        ..model,
        queue_editor: queue_editor.State(
          ..state,
          message: "This queued input is read-only for this attachment",
        ),
      )
    Error(Nil) -> model
  }
}

fn reconcile_queue_draft(model: Model) -> Model {
  let state = model.queue_editor
  case state.draft {
    Some(draft) if draft.delivery != queue_editor.Saving -> {
      use <- bool.guard(
        draft.namespace != queue_namespace(model),
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
          queue_owner(model),
          queue_namespace(model),
          draft.document.strand,
          draft.document.id,
        )
      service_queue_read(
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

fn service_queue_read(model: Model) -> Model {
  case model.channel, model.queue_editor.fetch {
    Some(channel), Some(fetch) ->
      case session_channel.ready_for_read(channel) {
        True ->
          case queue_owner(model) == fetch.owner {
            True ->
              send_frame(
                Model(
                  ..model,
                  queue_editor: queue_editor.State(
                    ..model.queue_editor,
                    fetch: None,
                    awaiting: Some(fetch),
                  ),
                ),
                protocol.queued_input(model.next_id, fetch.strand, fetch.id),
              )
            False ->
              Model(
                ..model,
                queue_editor: queue_editor.State(
                  ..model.queue_editor,
                  fetch: None,
                  message: "Attachment changed; select the input again",
                ),
              )
          }
        False -> model
      }
    None, Some(_) ->
      Model(
        ..model,
        queue_editor: queue_editor.State(
          ..model.queue_editor,
          fetch: None,
          message: "Queue editing requires a live conversation attachment",
        ),
      )
    _, None -> model
  }
}

fn save_queue_draft(model: Model) -> Model {
  case model.queue_editor.draft, model.channel {
    Some(draft), Some(channel) if draft.delivery == queue_editor.Editable -> {
      let available =
        session_channel.mutation_available(channel)
        && queue_owner(model) == draft.owner
        && queue_namespace(model) == draft.namespace
      case available {
        True ->
          send_frame(
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

fn render_queue_surface(buf, cursor, screen, model: Model) {
  let state = model.queue_editor
  case state.surface {
    queue_editor.Closed -> #(buf, cursor)
    queue_editor.Inspector -> {
      let rows = queue_rows(model)
      let labels =
        list.index_map(rows, fn(row, index) {
          let prefix = case index == state.selected {
            True -> "> "
            False -> "  "
          }
          let access = case row.editing {
            snapshot_view.Editable -> "editable"
            snapshot_view.ReadOnly -> "read-only"
          }
          span.line_plain(
            prefix
            <> case row.kind {
              snapshot_view.Queue -> "queue "
              snapshot_view.Steer -> "steer "
            }
            <> text_hygiene.single_line(row.id)
            <> " · "
            <> access
            <> " · "
            <> text_hygiene.single_line(row.text),
          )
        })
      let labels = case labels {
        [] -> [
          span.line_plain("No queued inputs in the current captured view"),
        ]
        _ -> labels
      }
      let inner = panel_inner(screen)
      let body =
        geometry.rect_new(
          inner.position.x,
          inner.position.y + 2,
          inner.size.width,
          int.max(0, inner.size.height - 2),
        )
      let rendered =
        buffer.buffer_new(screen)
        |> render_panel_border(
          screen,
          " queued inputs · " <> model.active_strand <> " ",
          theme.signal,
        )
        |> paragraph.render_styled(inner, [span.line_plain(state.message)])
        |> paragraph.render_styled(
          body,
          list.drop(labels, int.max(0, state.selected - body.size.height + 1)),
        )
      #(rendered, Error(Nil))
    }
    queue_editor.Editor -> render_queue_draft(buf, screen, state)
  }
}

fn render_queue_draft(buf, screen, state: queue_editor.State) {
  case state.draft {
    None -> #(buf, Error(Nil))
    Some(draft) -> {
      let inner = panel_inner(screen)
      let area =
        geometry.rect_new(
          inner.position.x,
          inner.position.y + 2,
          inner.size.width,
          int.max(0, inner.size.height - 3),
        )

      // Presentation removes terminal controls while the full source remains
      // unchanged in the draft. Saving never round-trips displayed excerpts.
      let safe =
        text_area.TextAreaState(
          ..draft.input,
          lines: list.map(draft.input.lines, text_hygiene.single_line),
        )
      let input = input_view_state(safe, area.size.width)
      let rendered =
        buffer.buffer_new(screen)
        |> render_panel_border(
          screen,
          " queued input · "
            <> text_hygiene.single_line(draft.document.id)
            <> " · revision "
            <> int.to_string(draft.document.revision)
            <> " ",
          theme.signal,
        )
        |> paragraph.render_styled(inner, [
          span.line_plain(state.message),
          span.line_plain(
            int.to_string(draft.document.attachment_count)
            <> " image attachments retained",
          ),
        ])
        |> text_area.render(
          area,
          text_area.textarea_new() |> text_area.with_max_lines(0),
          input,
        )
      #(rendered, text_area.cursor_screen_pos(input, area))
    }
  }
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
  case diff_shown(model) {
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
  |> invalidate_transcript
  |> invalidate_frame
}

// Cuts and width transitions request at most one pending refresh. No timer or
// background Git loop is needed when the workspace and conversation are idle.
fn request_visible_worktree(model: Model) -> Model {
  case model.peer, diff_shown(model) {
    Attached(_), True -> refresh_worktree(model)
    Attached(_), False | Preview, _ | Replaying, _ | Disconnected, _ -> model
  }
}

fn refresh_worktree(model: Model) -> Model {
  case model.peer, model.channel {
    Attached(_), Some(_) ->
      service_worktree_read(
        Model(
          ..model,
          worktree: worktree_view.request(model.worktree, queue_owner(model)),
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

fn service_worktree_read(model: Model) -> Model {
  // Both observations borrow the same server worker slot. An acknowledged
  // context read still owns it until its final push arrives.
  use <- bool.guard(context_in_flight(model.context), model)
  case model.channel, model.worktree.refresh, model.worktree.awaiting {
    Some(channel), worktree_view.Requested, None ->
      case session_channel.ready_for_read(channel) {
        True -> send_frame(model, protocol.worktree_diff(model.next_id))
        False -> model
      }
    _, _, _ -> model
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
    keys.PageUp -> scroll_diff(model, Older, 10)
    keys.PageDown -> scroll_diff(model, Newer, 10)
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
  |> invalidate_transcript
}

fn diff_title(model: Model) -> String {
  case model.worktree.board {
    Some(_) -> " worktree changes "
    None -> " captured changes "
  }
}

fn render_diff_view(
  buf: buffer.Buffer,
  area: Rect,
  model: Model,
) -> buffer.Buffer {
  let height = int.min(6, int.max(1, area.size.height / 3))
  let nav =
    geometry.rect_new(
      area.position.x,
      area.position.y + 2,
      area.size.width,
      height,
    )
  let patch =
    geometry.rect_new(
      area.position.x,
      area.position.y + height + 2,
      area.size.width,
      int.max(0, area.size.height - height - 2),
    )
  let labels =
    worktree_view.labels(model.worktree)
    |> list.index_map(fn(label, index) {
      span.line_plain(
        case index == model.worktree.selected {
          True -> "> "
          False -> "  "
        }
        <> label,
      )
    })
  let focus = case model.worktree.focus {
    worktree_view.Composer ->
      "Ctrl+d: file navigation · PgUp/PgDn: patch · Esc: close"
    worktree_view.Navigator ->
      "↑/↓: files · r: refresh · Enter: composer · Esc: close"
  }
  buf
  |> paragraph.render_styled(area, [
    span.line_plain(model.worktree.message),
    span.line_plain(focus),
  ])
  |> paragraph.render_styled(
    nav,
    list.drop(labels, int.max(0, model.worktree.selected - height + 1)),
  )
  |> render_rows(patch, model.diff_rows, model.diff_scroll_offset)
}

fn observe_completion(
  model: Model,
  cut: snapshot.Captured,
  view: snapshot_view.View,
  active: String,
) -> Model {
  let owner = queue_owner(Model(..model, captured: Some(#(cut, view))))
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
    queue_rows(model) |> list.drop(model.queue_editor.selected) |> list.first
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
  Model(
    ..model,
    queue_editor: queue_editor.State(..model.queue_editor, selected:),
  )
}

/// Opens detailed completion evidence while preserving the ordinary composer.
///
/// ## Examples
///
/// ```gleam
/// // tui.open_summary(model)
/// ```
@internal
pub fn open_summary(model: Model) -> Model {
  service_jobs_read(
    Model(
      ..model,
      summary_surface: queue_editor.Inspector,
      summary_scroll: 0,
      jobs_refresh: worktree_view.Requested,
    ),
  )
  |> invalidate_frame
}

fn service_jobs_read(model: Model) -> Model {
  case model.channel, model.jobs_refresh, model.peer {
    Some(channel), worktree_view.Requested, Attached(_) ->
      case session_channel.ready_for_read(channel) {
        True ->
          send_frame(
            Model(
              ..model,
              jobs_refresh: worktree_view.Settled,
              jobs_awaiting: Some(#(queue_owner(model), model.active_strand)),
              jobs_notice: "Refreshing live jobs; previous observation may be stale",
            ),
            protocol.live_jobs(model.next_id, model.active_strand),
          )
        False -> model
      }
    _, worktree_view.Requested, _ ->
      Model(
        ..model,
        jobs_refresh: worktree_view.Settled,
        jobs_notice: "Live jobs unavailable without a live conversation attachment",
      )
    _, worktree_view.Settled, _ -> model
  }
}

fn receive_jobs(model: Model, board: live_jobs.Board) -> Model {
  case model.jobs_awaiting {
    Some(#(owner, strand)) if strand == board.strand ->
      case owner == queue_owner(model) {
        True ->
          Model(
            ..model,
            jobs: Some(board),
            jobs_observed_ms: Some(model.monotonic_time_ms()),
            jobs_awaiting: None,
            jobs_request: None,
            jobs_notice: "Live jobs observed separately from operation completion",
          )
          |> invalidate_transcript
        False -> model
      }
    Some(_) | None -> model
  }
}

fn queue_count_line(model: Model) -> String {
  case model.captured {
    Some(#(_, view)) ->
      case view.pending_inputs {
        Some(rows) ->
          "Queued inputs: "
          <> int.to_string(
            list.length(
              list.filter(rows, fn(row) { row.strand == model.active_strand }),
            ),
          )
        None -> "Queued input count unavailable"
      }
    None -> "Queued input count unavailable"
  }
}

fn jobs_brief(model: Model) -> String {
  case model.jobs {
    Some(board) if board.strand == model.active_strand ->
      "Live jobs: "
      <> int.to_string(board.total)
      <> case model.jobs_observed_ms {
        Some(observed) ->
          " · refreshed "
          <> live_jobs.duration(model.last_frame_ms - observed)
          <> " ago"
        None -> " · at last refresh"
      }
    Some(_) -> "Live jobs unavailable for this strand; /summary refreshes"
    None -> model.jobs_notice
  }
}

fn summary_lines(model: Model) -> List(String) {
  let completed = case
    completion_summary.latest(model.completion, model.active_strand)
  {
    None -> ["No completed operation captured for this strand"]
    Some(summary) -> completion_summary.lines(summary)
  }
  let jobs = case model.jobs {
    Some(board) if board.strand == model.active_strand -> [
      jobs_brief(model),
      ..list.drop(live_jobs.lines(board), 1)
    ]
    Some(_) -> ["Live jobs unavailable for this strand; r refreshes"]
    None -> [model.jobs_notice]
  }
  list.append(completed, [
    "",
    usage_summary(model.usage),
    "Cumulative tokens: uncached input "
      <> tokens(model.usage.input)
      <> " · cache read "
      <> tokens(model.usage.cache_read)
      <> " · cache write "
      <> tokens(model.usage.cache_write)
      <> " · output "
      <> tokens(model.usage.output)
      <> " (includes reasoning)",
    context_usage_line(model),
    "",
    queue_count_line(model),
    "",
    ..jobs
  ])
}

// Context belongs to one measured provider request. Session usage accumulates
// every request and strand, so it can never stand in for this number.
fn context_usage_line(model: Model) -> String {
  let records = case model.captured {
    Some(#(cut, view)) ->
      snapshot_view.branch(view, cut.window, model.active_strand).records
    None -> model.records
  }
  let measured =
    records
    |> list.find_map(fn(record) {
      case record.entry {
        entry.MessageEntry(message: message.AssistantMessage(usage:, ..), ..)
          if usage.total_tokens > 0
        -> Ok(usage)
        _ -> Error(Nil)
      }
    })
  case measured {
    Ok(usage) ->
      "Context at last measured request: "
      <> tokens(usage.input + usage.cache_read + usage.cache_write)
      <> " input tokens (including cache); output "
      <> tokens(usage.output)
      <> case usage.reasoning {
        Some(count) -> " (includes " <> tokens(count) <> " reasoning)"
        None -> ""
      }
    Error(Nil) -> "Context: no measured request loaded for this strand"
  }
}

fn update_summary_key(key: keys.Key, model: Model) -> Model {
  case key {
    keys.Ctrl("c") -> quit(model)
    keys.Escape -> Model(..model, summary_surface: queue_editor.Closed)
    keys.Char("r") ->
      service_jobs_read(Model(..model, jobs_refresh: worktree_view.Requested))
    keys.Up ->
      Model(..model, summary_scroll: int.max(0, model.summary_scroll - 1))
    keys.Down -> Model(..model, summary_scroll: model.summary_scroll + 1)
    keys.PageUp ->
      Model(..model, summary_scroll: int.max(0, model.summary_scroll - 10))
    keys.PageDown -> Model(..model, summary_scroll: model.summary_scroll + 10)
    _ -> model
  }
}

fn render_summary_surface(buf, cursor, screen, model: Model) {
  case model.summary_surface {
    queue_editor.Closed -> #(buf, cursor)
    queue_editor.Inspector | queue_editor.Editor -> {
      let inner = panel_inner(screen)
      let lines =
        summary_lines(model)
        |> list.flat_map(fn(text) {
          markdown.render(text_hygiene.multiline(text), inner.size.width)
        })
        |> markdown.wrap_lines(inner.size.width)
      let offset =
        int.min(
          model.summary_scroll,
          int.max(0, list.length(lines) - inner.size.height),
        )
      let rendered =
        buffer.buffer_new(screen)
        |> render_panel_border(
          screen,
          " latest completion · Esc: back · r: refresh live jobs ",
          theme.signal,
        )
        |> paragraph.render_styled(inner, list.drop(lines, offset))
      #(rendered, Error(Nil))
    }
  }
}

fn diff_patch_height(model: Model) -> Int {
  let available = transcript_viewport_height(model)
  int.max(0, available - int.min(6, int.max(1, available / 3)) - 2)
}

fn diff_navigation_hit(model: Model, at: geometry.Position) -> Option(Int) {
  use <- bool.guard(
    !diff_shown(model)
      || model.queue_editor.surface != queue_editor.Closed
      || model.summary_surface != queue_editor.Closed
      || model.context.surface != context_view.Hidden,
    None,
  )
  let screen = geometry.rect_new(0, 0, model.width, model.height)
  let #(_, body, _, _) = layout(screen, model)
  let #(main, _, changes) = body_layout(body, model)
  let area =
    panel_inner(case main_shows_diff(model) {
      True -> main
      False -> changes
    })
  let height = int.min(6, int.max(1, area.size.height / 3))
  let navigation =
    geometry.rect_new(
      area.position.x,
      area.position.y + 2,
      area.size.width,
      height,
    )
  use <- bool.guard(!geometry.contains(navigation, at), None)
  let index =
    int.max(0, model.worktree.selected - height + 1)
    + at.y
    - navigation.position.y
  case index < list.length(worktree_view.labels(model.worktree)) {
    True -> Some(index)
    False -> None
  }
}

fn queue_namespace(model: Model) -> String {
  case model.captured {
    Some(#(cut, _)) ->
      json.to_string(
        json.Array([
          json.String(cut.attachment.expected.session),
          json.String(cut.attachment.expected.epoch),
          json.String(cut.attachment.expected.incarnation),
        ]),
      )
    None -> ""
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
    |> invalidate_frame
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
    "worktree_diff" ->
      Model(
        ..model,
        worktree: worktree_view.receive(
          model.worktree,
          queue_owner(model),
          worktree_view.Failed(request_id, reason),
        ),
      )
    _ -> model
  }
  apply_event(updated, protocol.ServerError(code, message))
}

// Context follows the server's selected configuration and the end of the
// active strand's operation, never scrollback retention and no longer the
// leaf. The leaf moves once per committed entry, so a refresh keyed on it
// cost the server a full branch scan per tool call: a thirty-tool turn ran
// about sixty of them for a percentage nobody reads until the turn ends.
// Streaming tokens and unrelated captures start no read.
fn sync_context(before: Model, after: Model) -> Model {
  let selected =
    context_view.select(after.context, queue_owner(after), after.active_strand)
  let changed = context_refresh_due(before, after)
  let context = case after.peer {
    Attached(_) ->
      case changed {
        True -> context_view.invalidate(selected)
        False -> selected
      }
    Replaying -> selected
    Preview | Disconnected ->
      context_view.State(
        ..selected,
        board: None,
        request: context_view.Idle,
        notice: "Context observation requires a live connection",
      )
  }
  Model(..after, context:)
}

/// Whether this model transition is worth another automatic context read.
///
/// Four transitions are worth one: the first capture, a strand switch, a
/// configuration change, and the active strand's operation reaching `done`.
/// A leaf that moved while that operation is still running is not one of
/// them, which is what holds a thirty-tool turn to a single observation.
///
/// ## Examples
///
/// ```gleam
/// // tui.context_refresh_due(before, after)
/// ```
@internal
pub fn context_refresh_due(before: Model, after: Model) -> Bool {
  case before.captured, after.captured {
    Some(#(_, old)), Some(#(_, current)) ->
      before.active_strand != after.active_strand
      || dict.get(old.configurations, before.active_strand)
      != dict.get(current.configurations, after.active_strand)
      || operation_settled(before, after)
    None, Some(_) -> True
    _, None -> False
  }
}

// The settling edge of the active strand's operation: the phase this terminal
// already tracks for the agent roster leaves `Some(_)` exactly once per
// operation, when the server reports `done`. Reading on that edge gives one
// observation per turn instead of one per committed entry.
fn operation_settled(before: Model, after: Model) -> Bool {
  active_strand_live(before) && !active_strand_live(after)
}

fn service_context_read(model: Model) -> Model {
  // A worktree acknowledgement releases the command lane, not its worker.
  // Wait for that observation before borrowing the shared slot for context.
  use <- bool.guard(model.worktree.awaiting != None, model)
  case model.channel, model.context.request, model.peer, model.captured {
    Some(channel), context_view.Requested, Attached(_), Some(_) ->
      case session_channel.ready_for_read(channel) {
        True ->
          send_frame(
            model,
            protocol.context(model.next_id, model.active_strand),
          )
        False -> model
      }
    _, _, _, _ -> model
  }
}

/// Opens context inspection while retaining the composer's draft and selection.
///
/// ## Examples
///
/// ```gleam
/// // tui.open_context(model, context_view.Overview)
/// ```
@internal
pub fn open_context(model: Model, surface: context_view.Surface) -> Model {
  service_context_read(
    Model(
      ..model,
      context: context_view.State(
        ..context_view.invalidate(model.context),
        surface:,
        scroll: 0,
      ),
    ),
  )
}

fn update_context_key(key: keys.Key, model: Model) -> Model {
  let state = model.context
  case key {
    keys.Ctrl("c") -> quit(model)
    keys.Escape ->
      Model(
        ..model,
        context: context_view.State(..state, surface: context_view.Hidden),
      )
    keys.Char("r") ->
      service_context_read(
        Model(..model, context: context_view.invalidate(state)),
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
    keys.PageUp -> scroll_context(model, -10)
    keys.PageDown -> scroll_context(model, 10)
    _ -> model
  }
}

fn scroll_context(model: Model, delta: Int) -> Model {
  Model(
    ..model,
    context: context_view.State(
      ..model.context,
      scroll: int.max(0, model.context.scroll + delta),
    ),
  )
}

fn render_context_surface(buf, cursor, screen, model: Model) {
  case model.context.surface {
    context_view.Hidden -> #(buf, cursor)
    context_view.Overview | context_view.All -> {
      let inner = panel_inner(screen)
      let lines =
        context_view.lines(model.context)
        |> list.flat_map(fn(line) {
          markdown.render(text_hygiene.multiline(line), inner.size.width)
        })
        |> markdown.wrap_lines(inner.size.width)
      let offset =
        int.min(
          model.context.scroll,
          int.max(0, list.length(lines) - inner.size.height),
        )
      let rendered =
        buffer.buffer_new(screen)
        |> render_panel_border(
          screen,
          " context · Esc: back · r: refresh · a: detail ",
          theme.signal,
        )
        |> paragraph.render_styled(inner, list.drop(lines, offset))
      #(rendered, Error(Nil))
    }
  }
}

fn context_in_flight(state: context_view.State) -> Bool {
  case state.request {
    context_view.Awaiting(_) | context_view.RefreshAfter(_) -> True
    context_view.Idle | context_view.Requested | context_view.Unavailable ->
      False
  }
}
