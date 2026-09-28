//// The terminal client's `Model` and the types it names.
////
//// Every other part of the client is a function over this record, so it
//// sits at the bottom of the module graph: `tui` and each module under it
//// import `Model` from here, and this module imports none of them. Gleam
//// forbids import cycles, which is what keeps the order fixed; a type the
//// record names has to live here or below, never in a module that reduces
//// or paints the record.
////
//// The model is two records, `Model(shared: TerminalShared, view: View)`.
//// `Shared`, defined in `tui/session_model` with the types it names, is the
//// session state: what the daemon said, what this client has sent and not
//// yet seen committed, the reads in flight, and the revision
//// counters that tell a host its projection is stale. `View` is the
//// terminal's own state: the screen size, the composer and its history, the
//// panels, overlays and their cursors, the row projection's outputs, frame
//// pacing, the host clocks, the daemon-control and attachment job slots, and
//// the etui render caches. The terminal owns both today. The split is there
//// because the web view shows the same sessions and should run the same
//// reducers rather than its own copies (issue #569): a second host holds a
//// `Shared` beside a view record of its own, and nothing in `Shared` names an
//// etui type, a terminal surface or a job slot. Three records held both
//// kinds of state and are cut in two: a parked strand's history window is
//// `Shared.parked_scrollback` beside the editor in `View.strand_workspaces`,
//// the agent strip's roster is `Shared.roster` beside its keyboard focus
//// in `View.strip_focus`, and the queue editor's requests on the lane are
//// `Shared.queue_request` beside the editor in `View.queue_editor`. The
//// daemon's build is `Shared.daemon_build` beside the control connection in
//// `View.daemon_host`, and a held prompt the daemon returns waits in
//// `Shared.returned_drafts` until the terminal moves it into an editor.
////
//// The record is shaped by the first two slices of moving the client
//// step into `session_view` (`docs/design-notes/step-extraction.md`).
//// `Shared` holds four host handles, the adopted lane (`channel`), the
//// connection and replay inboxes (`inbox`, `replay_inbox`) and the
//// recorder, and names none of them with a terminal type: it is
//// `Shared(socket, recorder, source, replay_source)`. The terminal binds
//// the parameters to its connection, its recording and the two subjects it
//// reads in `TerminalShared`, which is the type of `Model.shared`. Most
//// reducers still take the whole `Model` and read a field through the half
//// that holds it. The reducer cut (issue #569, S3) moves them one layer at a
//// time, from the helpers they call upward, to functions over `Shared`
//// alone, which a later slice moves into `session_view`, where the web view
//// can drive them with its own bindings.
////
//// The step's effect queue is `View.outbox`. It holds the terminal's
//// effects, jobs and the attachment among them, in one order with the
//// session effects wrapped as `effect.Step`. A function over `Shared` alone
//// queues its session effects on `Shared.outbox` instead, and the terminal
//// stores its result through `hold_shared`, which moves them into
//// `View.outbox` at the point of the call. So the step still has one order
//// of effects, and `Shared.outbox` is empty whenever the terminal holds the
//// model.
////
//// Besides the types, the module holds the small operations that nearly
//// every reducer needs. Those that change only session state (appending a
//// system or error line, the transcript and frame revisions, the activity
//// mark, storing the lane, recording a channelless arrival) are defined
//// over `Shared` in `tui/session_model`; the functions of the same names
//// here are their forms over the whole model, each a `hold_shared` of the
//// shared call, for the reducers that still take the whole model. The
//// terminal's own operations, queuing a terminal effect, starting a job and
//// opening a step, are defined here alone.

import etui/buffer
import etui/geometry.{type Rect}
import etui/span
import etui/widgets/textarea as text_area
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import host/build_identity
import session_view/attempt
import session_view/composer
import session_view/connection_event
import session_view/history_view
import session_view/session_channel
import session_view/transcript_line.{type Line}
import session_view/worktree_view
import tui/agent_strip
import tui/agents
import tui/appearance
import tui/approval_panel
import tui/attachment
import tui/bootstrap
import tui/connection
import tui/effect
import tui/focused_goal_panel
import tui/herdr
import tui/job
import tui/job_runner
import tui/live_tail
import tui/model_selector
import tui/msg
import tui/note_panel
import tui/outbound
import tui/pacing
import tui/peer_links
import tui/queue_editor
import tui/recording
import tui/selection
import tui/session_model.{type Shared, Shared}
import tui/session_selector
import tui/summary_panel
import tui/terminal_lane
import tui/transcript_anchor
import weft

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

/// Scroll direction names the operation without carrying a Boolean polarity
/// through the two independently scrollable reading surfaces.
@internal
pub type ScrollDirection {
  Older
  Newer
}

/// The modal surface that owns focus, if any.
@internal
pub type Overlay {
  NoOverlay
  ModelSelector(model_selector.State)
  AgentInspector(selected: agents.Inspector)
  GoalInspector(state: focused_goal_panel.State)
  DaemonSelector(session_selector.State)
  PeerLinkManager(peer_links.State)
  ApprovalInspector(approval_panel.State)
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

/// The picker's one daemon control job: the slot that waits for its
/// replies, and the outcome received before its relay said it was done.
///
/// A control job's relay sends the outcome and then `AllDelivered`, and
/// the outcome is applied only at `AllDelivered`, so it is kept here in
/// between.
@internal
pub type ControlRequest {
  ControlRequest(
    /// The job's key and the replies received for it.
    job: job.Awaiting(job.ControlReply),
    /// The outcome already received, applied when the relay finishes.
    result: Option(Result(job.ControlOutcome, String)),
  )
}

/// The session picker's activity poll, which asks the daemon what each
/// resident session on the open page is doing.
///
/// It is its own slot rather than a `ControlRequest` because the picker's one
/// control job is what paging, renames and deletes wait on, and a poll that
/// held it through a slow resident would turn an operator's keypress into a
/// "catalogue action is already running" refusal. Each poll also runs on a
/// control connection of its own for the same reason: the borrowed control
/// has one outstanding request.
@internal
pub type ActivityPoll {
  /// Ask at the next tick that finds the picker open on resident rows.
  ActivityDue

  /// The last poll settled; the next is not asked before this monotonic time.
  ActivityResting(until_ms: Int)

  /// One request is in flight for exactly these identities.
  ActivityAsking(
    /// The job's key and the replies received for it.
    job: job.Awaiting(job.ActivityReply),
    /// The identities the request named, which `observe` needs to tell an
    /// omitted identity from one that was never asked about.
    asked: List(String),
  )
}

/// The last completed frame, keyed by the screen and revision it was for.
@internal
pub type FrameCache {
  FrameCache(
    screen: Rect,
    revision: Int,
    rendered: #(buffer.Buffer, Result(geometry.Position, Nil)),
    /// Viewport copy metadata for these exact rendered cells.
    selection_gutters: List(#(Int, Int)),
  )
}

/// Local editing and reading state belongs to an exact session and strand.
///
/// A parked workspace holds the editor itself, including its cursor, rather
/// than only its text. Neither inspecting another agent nor reconnecting can
/// turn that draft into input for another recipient.
///
/// This is the terminal's half of a parked strand. The history window parked
/// with it is session state and is kept under the same key in
/// `Shared.parked_scrollback`; `inbound.select_workspace` parks and restores
/// both halves together.
@internal
pub type StrandWorkspace {
  StrandWorkspace(
    /// The complete editor, including cursor and selection state.
    input: text_area.TextAreaState,
    /// Exact unsent text and image attachments.
    attachments: List(composer.Attachment),
    /// Submitted command history for this recipient.
    history: List(String),
    /// Current position in the recipient's command history.
    history_index: Int,
    /// Draft displaced while browsing command history.
    history_draft: String,
    /// Whether this recipient's next message queues or steers.
    submission_mode: SubmissionMode,
    /// Frozen transient content held while reading above the live tail.
    reading_lines: Option(List(Line)),
    /// Bottom-relative viewport offset at departure.
    offset: Int,
    /// Durable row identities used to restore the same reading position.
    anchors: List(Option(transcript_anchor.Row)),
    /// Unanchored row count below those durable identities.
    prefix: Int,
    /// Original viewport height for anchor relocation after a resize.
    height: Int,
  )
}

/// The terminal's etui render caches: the rows and frames a projection or
/// a paint built from the model, in etui's own types.
///
/// They are the `caches` field of the terminal's `View`. Everything else on
/// the model is state a reducer decides; these are what the terminal's paint
/// derived from it, kept so the next paint can reuse them. A reducer that
/// needs them rebuilt says so through the shared revisions and
/// `Shared.record_cache_epoch`, and the projection reads those, so no reducer
/// outside the projection, the frame cache and the mouse selection writes
/// here. A second host keeps its own view state beside the same shared
/// record (ADR-014, the third blocker).
@internal
pub type Caches {
  Caches(
    /// The wrapped rows of the whole transcript, durable and live.
    rendered_rows: List(span.Line),
    /// The wrapped rows of the durable records alone.
    record_rows: List(span.Line),
    /// What the last projection decided about the live answer's rows, so
    /// the next one reprocesses only the text that arrived since. It holds
    /// the fragment list it last drew and checks it against the stream on
    /// every projection, so a stream that restarts or collapses finds the
    /// cache stale here and no reducer has to drop it.
    live_tail: live_tail.Cache,
    /// Wrapped rows keyed by the complete presentation line. A rebuild keeps
    /// only the current projection, so old branches and outcomes are released.
    record_line_cache: Dict(Line, List(span.Line)),
    /// Cached newest-first diff rows. Stream fragments cannot make the
    /// changes pane reparse settled edit results.
    diff_rows: List(span.Line),
    /// Current diff lines retain layout across captures at the same width.
    /// Rebuilding keeps only the newly captured projection's keys.
    diff_line_cache: Dict(Line, List(span.Line)),
    /// The last completed frame and the screen and revision it was for.
    frame_cache: Option(FrameCache),
    /// The selected pane stays on its original cells until the selection ends.
    selection_frame: Option(buffer.Buffer),
    /// The `Shared.record_cache_epoch` the record rows were built at. A
    /// reducer that clears the transcript bumps the model's epoch, and the
    /// next projection drops the record rows and their line cache rather
    /// than reusing rows for lines that are gone.
    record_cache_epoch: Int,
  )
}

/// Render caches with nothing cached, for a new model.
///
/// ## Examples
///
/// ```gleam
/// let caches = tui_model.empty_caches()
/// ```
@internal
pub fn empty_caches() -> Caches {
  Caches(
    rendered_rows: [],
    record_rows: [],
    live_tail: live_tail.new(),
    record_line_cache: dict.new(),
    diff_rows: [],
    diff_line_cache: dict.new(),
    frame_cache: None,
    selection_frame: None,
    record_cache_epoch: 0,
  )
}

/// The terminal's model: the session state and the terminal's own state, as
/// two records.
///
/// A reducer reads a field through the half that holds it, `model.shared.x`
/// or `model.view.x`, and writes by updating that half:
/// `Model(..model, shared: Shared(..model.shared, notice: text))`. A reducer
/// that writes both halves updates both in the one expression, from the same
/// `model`, so neither update can drop the other's write.
///
/// Published `@internal` so the virtual-backend harness can build a model by
/// hand and drive the real loop over it. Nothing outside this package sees
/// it.
@internal
pub type Model {
  Model(
    /// Session state: what a second host would need to show or act on the
    /// session, with the host handles bound to the terminal's types.
    shared: TerminalShared,
    /// The terminal's own state.
    view: View,
  )
}

/// The session state with its host handles bound to the terminal's types:
/// the adopted lane writes to a `connection.Connection` and notes to a
/// `recording.Recorder`, and each inbox is a `tui/buffered` inbox, whose
/// source is the subject this process created and reads before each step.
@internal
pub type TerminalShared =
  Shared(
    connection.Connection,
    recording.Recorder,
    Subject(connection_event.Message),
    Subject(attempt.Event),
  )

/// The terminal's own state: what only the terminal reads, or what names an
/// etui type, a terminal surface, a daemon-control job or the pane reporter.
///
/// It holds the screen size and the composer, the panels and overlays with
/// their cursors and scroll offsets, the row projection's outputs, frame
/// pacing, the host clocks, the daemon-control, reconnect and provisional
/// attachment job slots, the step's effect queue, the runtime's job table,
/// and the etui render caches.
/// A second host keeps its own view state beside the same `Shared`.
@internal
pub type View {
  View(
    /// The terminal's width in cells.
    width: Int,
    /// The terminal's height in cells.
    height: Int,
    /// Launch-time color capability, never read while rendering.
    palette: appearance.Palette,
    /// The composer's editor, including its cursor and selection.
    input: text_area.TextAreaState,
    /// Unsent drafts and reading endpoints never cross session identities.
    strand_workspaces: Dict(#(String, String), StrandWorkspace),
    /// The saved endpoint being restored on the next row-cache rebuild.
    restored_workspace: Option(StrandWorkspace),
    /// Prompts submitted from this composer, newest first.
    history: List(String),
    /// The position in `history` while browsing it; zero is the draft.
    history_index: Int,
    /// The draft displaced while browsing `history`.
    history_draft: String,
    /// The slash-command palette's cursor.
    command_selected: Int,
    /// What Enter does with the next draft while an operation is live.
    submission_mode: SubmissionMode,
    /// The footer's cache label for the active strand, as of the last tick:
    /// what `cache_miss.outlook` says rendered as text, or `""` when it
    /// says nothing. Held as a string rather than an `Outlook` so the tick
    /// can compare the new label against the old and repaint only when the
    /// reading actually changed — the reading moves once a minute at most
    /// until a countdown reaches its final stretch.
    cache_outlook: String,
    /// A complete queue draft never borrows the ordinary composer.
    queue_editor: queue_editor.State,
    /// Details visibility does not borrow the composer.
    summary_surface: queue_editor.Surface,
    /// Independent detailed-summary scroll offset.
    summary_scroll: Int,
    /// Focused evidence section in the completion summary.
    summary_tab: summary_panel.Tab,
    /// Stable-index projection of the selected current job.
    summary_job_selected: Int,
    /// Whether the help panel is open.
    help_open: Bool,
    /// Whether the notes panel is open.
    notes_open: Bool,
    /// A dedicated view of captured edit diffs, without tool retries.
    diff_view: DiffVisibility,
    /// Diff scrolling is independent of conversation scrolling, including
    /// while a narrow terminal temporarily shows only the changes.
    diff_scroll_offset: Int,
    /// The row count belongs to the cached diff projection and its width.
    diff_row_count: Int,
    /// The observation and selection that produced the cached patch rows.
    /// Compare against the cache source even when a driver applied a reply
    /// before the next terminal update.
    diff_worktree_source: #(Option(worktree_view.Board), Int),
    /// Stable cell key within the inspected notes board.
    note_selected: Option(String),
    /// Selected note representation, independent of transcript detail mode.
    note_mode: note_panel.Mode,
    /// Selected note body offset, independent of transcript reading position.
    note_scroll: Int,
    /// The modal surface that has the keyboard, if any.
    overlay: Overlay,
    /// Whether the pinned agent strip or the composer has the keyboard, and
    /// the strip's cursor.
    strip_focus: agent_strip.Focus,
    /// The local launch's options, which session creation and the
    /// reconnect reuse; `None` for a remote attachment.
    local_options: Option(bootstrap.Options),
    /// One provisional replacement, whose original deadline includes capture.
    candidate: attachment.Status,
    /// Terminal-owned daemon control, independent of the selected session.
    daemon_host: Option(job.Daemon),
    /// One bounded metadata page request; no catalogue accumulation.
    control_request: Option(ControlRequest),
    /// The session picker's activity poll, separate from the control job.
    activity_poll: ActivityPoll,
    /// The one reconnect an unexpected daemon death is allowed, and whether it
    /// has already been spent. Kept in the model rather than beside the loop so
    /// the decision not to reconnect twice is made from the state the operator
    /// can see.
    reconnect: Reconnect,
    /// Retained after an uncertain create so another key cannot duplicate it.
    creation_key: Option(String),
    /// The configuration job a session creation waits for before it
    /// retains a creation key, while one is running. The creation resolves
    /// its configuration from the local launch options first, so a local
    /// failure sends nothing and retains no key; the resolution reads the
    /// file system, so it runs as a job and the creation continues when
    /// `session_control.drain_configuration` takes the reply.
    configuring: Option(job.Awaiting(job.ConfigurationReply)),
    /// Questions already presented locally, keyed by their exact durable sequence.
    prompted_approvals: List(#(String, Int)),
    /// Exact decision currently requested for local inspection, if any.
    inspecting_approval: Option(String),
    /// Next terminal-local attachment identity, independent of server IDs.
    next_attempt: Int,
    /// Whether the agent rail beside the transcript is shown.
    agent_rail_visible: Bool,
    /// Toggled by an action that replaces most of the viewport, so the
    /// next paint writes every vacated cell (`render.repaint_canvas`).
    repaint_phase: Bool,
    /// The activity indicator's animation frame.
    activity_frame: Int,
    /// Transient rows captured when leaving the live tail. Durable history has
    /// its own frozen ancestry; this keeps in-flight reasoning stationary too.
    reading_lines: Option(List(Line)),
    /// The transcript viewport's offset from the bottom, in rows.
    scroll_offset: Int,
    /// The `Shared.render_revision` the rendered rows were built at.
    rendered_revision: Int,
    /// How many rows the last projection produced.
    rendered_row_count: Int,
    /// How many of `rendered_rows` the bottom-anchored viewport has shown.
    /// Never above `rendered_row_count`; the difference is the backlog the
    /// pacing walk is working off, and a gesture closes it at once.
    revealed_rows: Int,
    /// Durable provenance for wrapped rows; transient rows have no anchor.
    rendered_anchors: List(Option(transcript_anchor.Row)),
    /// Copy gutters aligned with `rendered_rows`, built in the same pass.
    rendered_gutters: List(Int),
    /// Durable copy gutters, aligned with `view.record_rows`.
    record_gutters: List(Int),
    /// The width the cached record rows were wrapped at.
    record_cache_width: Int,
    /// The strand the cached record rows were built for.
    record_cache_strand: String,
    /// The details setting the cached record rows were built with.
    record_cache_details: Bool,
    /// Whether the cached frame shows every visible change, or a change
    /// is waiting for the pacing interval.
    frame_debt: pacing.FrameDebt,
    /// The presentation clock, shared by pacing, activity, and throughput.
    /// Scripts inject this clock without changing transport deadlines. Only
    /// the runtime calls it: `runtime.message`, once per event, when it
    /// builds the step's message, and `runtime.stamp` for a caller that
    /// drives a reducer outside the step.
    monotonic_time_ms: fn() -> Int,
    /// The transport clock the session channel's deadlines and refresh are
    /// measured on. It is the host's monotonic clock in a live terminal and
    /// a test driver holding a live socket; a fixture that puts a socketless
    /// replay lane on a model freezes it, so the lane's timers cannot depend
    /// on where the host's arbitrary monotonic origin happens to sit. Only
    /// the runtime calls it, as it does the presentation clock.
    transport_time_ms: fn() -> Int,
    /// This terminal's identity in a session creation key: the OS process
    /// and the BEAM process that created the model, read once at creation.
    terminal: String,
    /// The host's wall clock when the current event was read, stored by
    /// `start_step` beside `Shared.stamp`. Only a session creation key reads
    /// it, and that key is built by the terminal's daemon control, so the
    /// reading is terminal state and the shared stamp does not carry it.
    wall_ms: Int,
    /// When the last frame was painted, on the presentation clock.
    last_frame_ms: Int,
    /// How long the terminal has gone without activity, which sets the
    /// idle poll interval.
    quiet_for_ms: Int,
    /// The mouse selection being dragged or left highlighted after a copy.
    /// Held in screen cells over the frame on display, so it is cleared by
    /// the next key, wheel notch, paste or resize rather than tracked
    /// through a reflow.
    selection: Option(selection.Selection),
    /// Screen row and transcript gutter captured with `view.selection_frame`.
    selection_gutters: List(#(Int, Int)),
    /// Whether a finished selection reaches the terminal's clipboard.
    clipboard: Clipboard,
    /// The Herdr pane reporter, when this terminal runs inside one. Held
    /// in the model for the same reason the recorder is: the publish runs
    /// where the lifecycle events just landed, which is inside `update`.
    herdr_reporter: Option(herdr.Reporter),
    /// The pane state and session last reported, so only a change sends.
    herdr_published: Option(herdr.Publication),
    /// Effects this step has decided on, newest first, and the only queue a
    /// step has. The reducer only appends here, through `emit`, `record`,
    /// `record_arrival` and `hold_channel`; `runtime.take` empties it at the
    /// end of every step, so between two `update` calls it is empty. A
    /// caller that runs a reducer outside `update` leaves its effects here
    /// until it calls `runtime.flush` or the next step collects them.
    ///
    /// It is the terminal's queue, so it lives here rather than in `Shared`:
    /// it holds terminal effects (jobs, the attachment, the clipboard,
    /// Herdr) in one order with the session reducers' `effect.Step`
    /// effects, and one queue is what keeps that order. While every reducer
    /// takes the whole model, the session reducers append here too.
    outbox: List(effect.Effect),
    /// The key the next background job is given. Keys are never reused,
    /// so a reply tagged with one belongs to exactly one job.
    next_job: job.Key,
    /// The runtime's table of running jobs, by key. No reducer reads or
    /// writes it: `runtime.perform` changes it after the step and
    /// `runtime.receive` reads it before the next one. It is on the model
    /// because the model is the only state the loop keeps between events.
    running: job_runner.Running,
    /// The terminal's etui render caches.
    caches: Caches,
  )
}

/// The most connection messages one step reduces: a tick's drain, and the
/// drain a key, a wheel notch or a drag runs before it acts. The runtime
/// tops `Model.inbox` up to this many before each step, so the step can
/// always reach its full batch and the buffer never holds more.
pub const connection_batch = 64

/// Whether this terminal may reconnect itself to a restarted daemon.
///
/// The attempt is offered once per daemon death and only to a local launch.
/// A local launch names the launcher state root and the session it opened, so
/// there is a launch to re-run and an identity to reattach; a remote
/// attachment has neither, and a session with no identity has nothing to
/// reattach. An operator quit is not a daemon death, and a terminal that has
/// already spent its attempt waits for the operator instead of looping.
@internal
pub type Reconnect {
  /// No attempt is running and one may still be started.
  ReconnectIdle

  /// One bounded relaunch is in flight; its outcome is drained by the tick.
  /// The terminal cancels it by its key when it quits.
  ReconnectAttempting(
    /// The job's key and the replies received for it.
    job: job.Awaiting(job.ReconnectReply(job.Daemon)),
  )

  /// This daemon death has had its one attempt. Nothing runs again until an
  /// attachment is adopted, which is what proves the reconnect worked.
  ReconnectSpent
}

/// The pinned agent strip in the shape `agent_strip` takes it: the
/// terminal's keyboard focus with the shared roster.
///
/// The model holds the two apart because the roster is session state and
/// the focus is the terminal's; `store_strip` writes a strip back the same
/// way, so a key the strip answers keeps both halves in step.
///
/// ## Examples
///
/// ```gleam
/// agent_strip.lines(tui_model.strip(model), rows, model.shared.active_strand)
/// ```
@internal
pub fn strip(model: Model) -> agent_strip.State {
  agent_strip.State(focus: model.view.strip_focus, roster: model.shared.roster)
}

/// Stores a strip `agent_strip` returned: its roster in the shared record
/// and its focus in the view.
///
/// ## Examples
///
/// ```gleam
/// tui_model.store_strip(model, agent_strip.leave(tui_model.strip(model)))
/// ```
@internal
pub fn store_strip(model: Model, strip: agent_strip.State) -> Model {
  Model(
    shared: Shared(..model.shared, roster: strip.roster),
    view: View(..model.view, strip_focus: strip.focus),
  )
}

/// Rows held back from the bottom-anchored viewport. Added to the scroll
/// offset, which counts from the same end, this is what walks the view down
/// to the tail a frame at a time.
@internal
pub fn viewport_backlog(model: Model) -> Int {
  int.max(0, model.view.rendered_row_count - model.view.revealed_rows)
}

/// Records operator or traffic activity, which resets the quiet-time
/// counter that idle pacing reads.
///
/// The terminal's form of `session_model.mark_activity`, for a reducer
/// that still takes the whole model.
///
/// ## Examples
///
/// ```gleam
/// tui_model.mark_activity(model)
/// ```
@internal
pub fn mark_activity(model: Model) -> Model {
  hold_shared(model, session_model.mark_activity(model.shared))
}

/// Stores the result of a function over the shared record, moving what it
/// queued into the step's outbox.
///
/// Every call from a terminal reducer into a function over `Shared` stores
/// its result through this. The shared outbox is moved into `View.outbox`
/// at the point of the call, so a lane close the shared function decided, a
/// terminal `Discard` queued after it and a lane write decided after that
/// are still performed in that order. `Shared.outbox` is empty again when
/// this returns, so no effect can be queued twice or wait past the call
/// that decided it.
///
/// Some terminal consequences of a session fact have to follow every call
/// rather than wait for the end of the step, because any function that
/// sends a frame can cause them and they used to be written at that point:
///
/// - The idle timer. A shared function records activity by bumping
///   `activity_revision`, and this resets `View.quiet_for_ms` when the
///   revision moved, as the terminal's `mark_activity` always did.
/// - The composer. A sent composer draft moves `drafts_sent`, and this
///   empties the editor and remembers its text in the input history, as
///   `clear_composer` did inside the send.
/// - The queue editor. Each `queue_request.Notice` the call recorded is
///   shown by `queue_editor.show`, oldest first.
/// - The goal inspector. Each `GoalObservation` the call recorded is applied
///   to the inspector when it is open, oldest first, and dropped otherwise.
///
/// ## Examples
///
/// ```gleam
/// tui_model.hold_shared(model, session_model.append_error(model.shared, text))
/// ```
@internal
pub fn hold_shared(model: Model, shared: TerminalShared) -> Model {
  let view = case shared.activity_revision == model.shared.activity_revision {
    True -> model.view
    False -> View(..model.view, quiet_for_ms: 0)
  }
  let held = case shared.outbox {
    [] -> Model(shared:, view:)
    decided ->
      Model(
        shared: Shared(..shared, outbox: []),
        view: View(
          ..view,
          outbox: list.append(list.map(decided, effect.Step), view.outbox),
        ),
      )
  }

  // The three surface edges read only what this call recorded, so a call
  // that recorded nothing, which is nearly every call, costs three checks.
  let held = case shared.drafts_sent == model.shared.drafts_sent {
    True -> held
    False -> clear_composer(held)
  }
  held
  |> show_queue_notices
  |> show_goal_observations
}

/// Stores the result of `reducer`, a function over the shared record alone,
/// applied to this model's shared record, through `hold_shared`.
///
/// It is `hold_shared(model, reducer(model.shared))`, written so that a
/// pipeline of such calls holds each result before the next call runs,
/// which keeps their effects in the order they were decided.
///
/// ## Examples
///
/// ```gleam
/// tui_model.run_shared(model, outbound.discard_own_turn)
@internal
pub fn run_shared(
  model: Model,
  reducer: fn(TerminalShared) -> TerminalShared,
) -> Model {
  hold_shared(model, reducer(model.shared))
}

// The queue editor is the terminal's, so a shared send or read records what
// it has to show and the terminal shows it here, at the point of that call.
fn show_queue_notices(model: Model) -> Model {
  case model.shared.queue_notices {
    [] -> model
    notices ->
      Model(
        shared: Shared(..model.shared, queue_notices: []),
        view: View(
          ..model.view,
          queue_editor: list.fold(
            notices,
            model.view.queue_editor,
            queue_editor.show,
          ),
        ),
      )
  }
}

// The goal inspector follows the board only while it is open; an
// observation that arrives with the inspector closed has nothing to update,
// and the next `/goal` builds the panel from `Shared.goal`.
fn show_goal_observations(model: Model) -> Model {
  case model.shared.goal_observations {
    [] -> model
    observations -> {
      let overlay = case model.view.overlay {
        GoalInspector(panel) ->
          GoalInspector(list.fold(observations, panel, observe_goal))
        other -> other
      }
      Model(
        shared: Shared(..model.shared, goal_observations: []),
        view: View(..model.view, overlay:),
      )
    }
  }
}

// A board replaces the panel's board and its label; a failed refresh keeps
// the board and says why it was not refreshed.
fn observe_goal(
  panel: focused_goal_panel.State,
  observation: session_model.GoalObservation,
) -> focused_goal_panel.State {
  case observation {
    session_model.GoalObserved(board:) ->
      focused_goal_panel.observe(panel, board)
    session_model.GoalUnavailable(reason:) ->
      focused_goal_panel.unavailable(panel, reason)
  }
}

/// Sends one encoded command frame and stores the result.
///
/// The terminal's form of `outbound.send_frame`, for a reducer that still
/// takes the whole model. `hold_shared` empties the composer when the frame
/// was the composer's own and was sent, and shows a refusal to the queue
/// editor.
///
/// ## Examples
///
/// ```gleam
/// tui_model.send_frame(model, protocol.goal_get(model.shared.next_id))
/// ```
@internal
pub fn send_frame(model: Model, frame: String) -> Model {
  hold_shared(model, outbound.send_frame(model.shared, frame))
}

/// Submits through the adopted lane with `arm` and stores the result.
///
/// The terminal's form of `outbound.send_via`, for a reducer that still
/// takes the whole model.
///
/// ## Examples
///
/// ```gleam
/// tui_model.send_via(model, fn(lane, now) {
///   operator.submit(lane, model.shared.next_id, "main", text, operator.Prompt, now)
/// })
/// ```
@internal
pub fn send_via(
  model: Model,
  arm: fn(terminal_lane.Lane, Int) ->
    #(terminal_lane.Lane, session_channel.Disposition),
) -> Model {
  hold_shared(model, outbound.send_via(model.shared, arm))
}

/// Folds the session channel's disposition for a submitted frame back into
/// the model.
///
/// The terminal's form of `outbound.apply_submission`, for a reducer that
/// still takes the whole model.
///
/// ## Examples
///
/// ```gleam
/// tui_model.apply_submission(model, disposition)
/// ```
@internal
pub fn apply_submission(
  model: Model,
  disposition: session_channel.Disposition,
) -> Model {
  hold_shared(model, outbound.apply_submission(model.shared, disposition))
}

/// Clears the composer text, its attachments and its submission mode.
///
/// The composer is the terminal's; its attachments are session state,
/// because they are what the next submission carries.
///
/// ## Examples
///
/// ```gleam
/// tui_model.clear_composer(model)
/// ```
@internal
pub fn clear_composer(model: Model) -> Model {
  let cleared = clear_composer_text(model)
  Model(
    shared: Shared(..cleared.shared, attachments: []),
    view: View(..cleared.view, submission_mode: PromptNext),
  )
}

/// Clears the composer text after remembering it in the input history.
///
/// ## Examples
///
/// ```gleam
/// tui_model.clear_composer_text(model)
/// ```
@internal
pub fn clear_composer_text(model: Model) -> Model {
  let remembered = remember_submission(model, text_area.value(model.view.input))
  Model(
    ..remembered,
    view: View(
      ..remembered.view,
      input: text_area.state_new(),
      history_index: 0,
      history_draft: "",
    ),
  )
}

// Submitted text is newest-first so Up is a constant-time move to the common
// case. Consecutive duplicates collapse because resend remains available
// without allowing accidental double-enter presses to crowd out useful history.
fn remember_submission(model: Model, text: String) -> Model {
  case string.trim(text), model.view.history {
    "", _ -> model
    value, [latest, ..] if value == latest -> model
    value, history ->
      Model(..model, view: View(..model.view, history: [value, ..history]))
  }
}

/// Stores `channel` as the adopted lane, moving what it queued into the
/// outbox.
///
/// The terminal's form of `session_model.hold_channel`, for a reducer that
/// still takes the whole model. The lane's outputs reach `View.outbox`
/// through `hold_shared`, at the point the lane decided them.
///
/// ## Examples
///
/// ```gleam
/// let #(channel, updates) = session_channel.receive(channel, message, now:)
/// tui_model.hold_channel(model, channel)
/// ```
@internal
pub fn hold_channel(model: Model, channel: terminal_lane.Lane) -> Model {
  hold_shared(model, session_model.hold_channel(model.shared, channel))
}

/// Records the daemon whose control connection the terminal now holds.
///
/// The connection and its key are the terminal's and go in
/// `View.daemon_host`; the build the daemon's `hello` named is data every
/// coherent cut compares with this client's build, so it also goes in
/// `Shared.daemon_build`, where the build-mismatch notice reads it. Both
/// places that adopt a control connection, the launch and the reconnect,
/// write through this function, so the two fields always describe the same
/// daemon.
///
/// ## Examples
///
/// ```gleam
/// tui_model.adopt_daemon(model, daemon)
/// ```
@internal
pub fn adopt_daemon(model: Model, daemon: job.Daemon) -> Model {
  let daemon_build =
    option.map(daemon.build, fn(build) {
      build_identity.Identity(build.version, build.commit)
    })
  Model(
    shared: Shared(..model.shared, daemon_build:),
    view: View(..model.view, daemon_host: Some(daemon)),
  )
}

/// Queues the release of what a job reply holds, when nobody will take it.
///
/// Most replies are data. Two hold a resource nobody else will release: an
/// attachment's `Prepared` holds an open socket and names its frames
/// subject, and a relaunch's `Completed(host)` holds a control connection.
/// For those this queues `CloseSocket` then `Discard`, or `CloseControl`,
/// which the runtime performs after the step. `runtime.hold` calls it for a
/// reply no slot admits, and `release_reconnect` for the replies a cleared
/// relaunch slot still held, so a reply is released the same way whether
/// it was dropped on arrival or with its slot.
///
/// ## Examples
///
/// ```gleam
/// let model = tui_model.release(model, arrival)
/// ```
@internal
pub fn release(model: Model, arrival: job.Arrival(job.Daemon)) -> Model {
  case arrival {
    job.AttachArrived(reply: job.Published(prepared), ..) ->
      model
      |> emit(effect.CloseSocket(prepared.socket))
      |> emit(effect.Discard(prepared.frames))
    job.ReconnectArrived(
      reply: weft.PulledOutcome(weft.Completed(value: host, ..)),
      ..,
    ) -> emit(model, effect.CloseControl(host.control))
    job.AttachArrived(reply: job.Settled(_), ..)
    | job.AttachArrived(reply: job.Finished(_), ..)
    | job.ReconnectArrived(..)
    | job.ControlArrived(..)
    | job.ActivityArrived(..)
    | job.ConfigurationArrived(..) -> model
  }
}

/// Releases what a relaunch slot still holds, for a reducer about to clear
/// it.
///
/// A relaunch that completed carries the control connection it opened.
/// When its outcome was admitted but not yet taken, and the slot is then
/// cleared, by an adoption earlier in the same tick or by a quit, the
/// connection would leave the model with the slot and stay open until the
/// terminal exited.
///
/// ## Examples
///
/// ```gleam
/// let model = tui_model.release_reconnect(model, awaiting)
/// ```
@internal
pub fn release_reconnect(
  model: Model,
  awaiting: job.Awaiting(job.ReconnectReply(job.Daemon)),
) -> Model {
  list.fold(job.held(awaiting), model, fn(model, reply) {
    release(model, job.ReconnectArrived(job.key(awaiting), reply))
  })
}

/// Queues one output of the provisional attachment.
///
/// An `Abandon` names an attempt whose job may still be running, so the job
/// is cancelled by its key first and the attempt's own cleanup follows: the
/// cancel stops the worker and closes a socket it published that the
/// runtime had not yet admitted, and the `Abandon` closes what the attempt
/// holds. `interaction.advance_candidate` and `submit.quit` queue every
/// attachment output through this, so no abandoned attempt leaves its job
/// running.
///
/// ## Examples
///
/// ```gleam
/// tui_model.emit_attachment(model, attachment.Abandon(model.candidate))
/// ```
@internal
pub fn emit_attachment(model: Model, output: attachment.Out) -> Model {
  case output {
    attachment.Abandon(status) ->
      case attachment.job_key(status) {
        Some(key) ->
          emit(emit(model, effect.CancelJob(key)), effect.Attachment(output))
        None -> emit(model, effect.Attachment(output))
      }
    attachment.FromChannel(_) | attachment.Acknowledge(_) ->
      emit(model, effect.Attachment(output))
  }
}

/// Queues one line for the model's recording, if the terminal is recording.
///
/// `start_step` queues each input's line through this. A message that
/// arrived with no lane is queued by `record_arrival` instead.
///
/// ## Examples
///
/// ```gleam
/// tui_model.record(model, recording.Key("enter"))
/// ```
@internal
pub fn record(model: Model, event: recording.Recorded) -> Model {
  case model.shared.recorder {
    Some(recorder) -> emit(model, effect.Record(recorder, event))
    None -> model
  }
}

/// Queues the recording line for a message that arrived while the model
/// held no lane, if the terminal is recording.
///
/// The terminal's form of `session_model.record_arrival`, for a reducer
/// that still takes the whole model.
///
/// ## Examples
///
/// ```gleam
/// tui_model.record_arrival(model, connection_event.Connected)
/// ```
@internal
pub fn record_arrival(
  model: Model,
  message: connection_event.Message,
) -> Model {
  hold_shared(model, session_model.record_arrival(model.shared, message))
}

/// Opens a step for one input: stores the instant it is applied at and
/// queues its recording line, if it is one that replays and the terminal
/// is recording.
///
/// `tui.step` calls this before the reducer runs, so every reducer reads
/// the input's time from `Model.shared.stamp`, or the wall clock from
/// `Model.view.wall_ms`, and the input's line is the first effect of its
/// step and precedes every line the input causes.
///
/// ## Examples
///
/// ```gleam
/// let model =
///   tui_model.start_step(model, model.shared.stamp, model.view.wall_ms, msg.Ticked)
/// ```
@internal
pub fn start_step(
  model: Model,
  at: msg.Stamp,
  wall_ms: Int,
  event: msg.Event,
) -> Model {
  let model =
    Model(
      shared: Shared(..model.shared, stamp: at),
      view: View(..model.view, wall_ms:),
    )
  case msg.recorded(event) {
    Some(recorded) -> record(model, recorded)
    None -> model
  }
}

/// Queues an effect for the runtime to perform after this step.
///
/// This is how a reducer asks for I/O. It never performs the effect
/// itself, so the step stays a function of its event and model, and a
/// replay or a test decides what happens to what it asked for.
///
/// ## Examples
///
/// ```gleam
/// tui_model.emit(model, effect.WriteClipboard(sequence))
/// ```
@internal
pub fn emit(model: Model, requested: effect.Effect) -> Model {
  Model(
    ..model,
    view: View(..model.view, outbox: [requested, ..model.view.outbox]),
  )
}

/// Allocates the next job key without starting anything.
///
/// `start_job` is this followed by queuing the start. A test that stands a
/// slot in for a running job allocates its key here and admits replies to
/// it through `runtime.hold`.
///
/// ## Examples
///
/// ```gleam
/// let #(model, key) = tui_model.allocate_job(model)
/// ```
@internal
pub fn allocate_job(model: Model) -> #(Model, job.Key) {
  let #(key, next_job) = job.allocate(model.view.next_job)
  #(Model(..model, view: View(..model.view, next_job:)), key)
}

/// Allocates a key and queues the start of the job `spec` describes under
/// it, returning the key for the slot that will wait for its replies.
///
/// The step starts nothing: the runtime starts the job after the step,
/// when it performs the `StartJob` this queues.
///
/// ## Examples
///
/// ```gleam
/// let #(model, key) = tui_model.start_job(model, job.Reconnect(options))
/// let model = Model(..model, reconnect: ReconnectAttempting(job.awaiting(key)))
/// ```
@internal
pub fn start_job(model: Model, spec: job.Spec) -> #(Model, job.Key) {
  let #(model, key) = allocate_job(model)
  #(emit(model, effect.StartJob(key, spec)), key)
}

/// Marks the cached frame stale so the next paint redraws it.
///
/// The terminal's form of `session_model.invalidate_frame`, for a reducer
/// that still takes the whole model.
///
/// ## Examples
///
/// ```gleam
/// tui_model.invalidate_frame(model)
/// ```
@internal
pub fn invalidate_frame(model: Model) -> Model {
  hold_shared(model, session_model.invalidate_frame(model.shared))
}

/// Reading mode owns the endpoint even at offset zero, so a frozen viewport at
/// the tail is not the live tail: returning to live output is an explicit
/// gesture rather than a consequence of scrolling back down to the newest row.
/// The offset covers the converse, a viewport lifted off the tail before any
/// endpoint was frozen.
@internal
pub fn reading_history(model: Model) -> Bool {
  model.shared.scrollback.mode == history_view.Reading
  || model.view.scroll_offset > 0
}

/// Appends a system line to the transcript and shows it as the notice.
///
/// The terminal's form of `session_model.append_system`, for a reducer
/// that still takes the whole model.
///
/// ## Examples
///
/// ```gleam
/// tui_model.append_system(model, "attached")
/// ```
@internal
pub fn append_system(model: Model, text: String) -> Model {
  hold_shared(model, session_model.append_system(model.shared, text))
}

/// Appends a failure line to the transcript and shows it as the notice.
///
/// The terminal's form of `session_model.append_error`, for a reducer
/// that still takes the whole model.
///
/// ## Examples
///
/// ```gleam
/// tui_model.append_error(model, "network: closed")
/// ```
@internal
pub fn append_error(model: Model, text: String) -> Model {
  hold_shared(model, session_model.append_error(model.shared, text))
}

/// Appends an informing line in the System speaker and shows it as the
/// notice.
///
/// The terminal's form of `session_model.append_notice`, for a reducer
/// that still takes the whole model.
///
/// ## Examples
///
/// ```gleam
/// tui_model.append_notice(model, "daemon build differs")
/// ```
@internal
pub fn append_notice(model: Model, text: String) -> Model {
  hold_shared(model, session_model.append_notice(model.shared, text))
}

/// Marks the transcript's rows stale.
///
/// The terminal's form of `session_model.invalidate_transcript`, for a reducer
/// that still takes the whole model.
///
/// ## Examples
///
/// ```gleam
/// tui_model.invalidate_transcript(model)
/// ```
@internal
pub fn invalidate_transcript(model: Model) -> Model {
  hold_shared(model, session_model.invalidate_transcript(model.shared))
}
