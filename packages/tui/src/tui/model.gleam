//// The terminal client's `Model` and the types it names.
////
//// Every other part of the client is a function over this record, so it
//// sits at the bottom of the module graph: `tui` and each module under it
//// import `Model` from here, and this module imports none of them. Gleam
//// forbids import cycles, which is what keeps the order fixed; a type the
//// record names has to live here or below, never in a module that reduces
//// or paints the record.
////
//// The model is two records, `Model(shared: Shared, view: View)`. `Shared`
//// is the session state: what the daemon said, what this client has sent
//// and not yet seen committed, the reads in flight, and the revision
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
//// and the agent strip's roster is `Shared.roster` beside its keyboard focus
//// in `View.strip_focus`. The queue editor stays whole in `View` for now,
//// because its lane correlation and its editor are updated together in too
//// many places to cut mechanically.
////
//// This is the first slice of moving the client step into `session_view`
//// (`docs/design-notes/step-extraction.md`). Every reducer still takes the
//// whole `Model` and reads a field through the half that holds it. The four
//// host handles, `inbox`, `channel`, `replay_inbox` and `recorder`, sit in
//// `Shared` with their terminal types until the next slice makes them type
//// parameters; a later slice moves `Shared` and the reducers over it into
//// `session_view`, where the web view can drive them.
////
//// Besides the types, the module holds the small operations that nearly
//// every reducer needs and that read or bump only the record itself:
//// appending a system or error line, the transcript and frame revision
//// counters, the activity mark idle pacing reads, the attachment identity
//// that replies are checked against, and the active strand's live phase.
//// Keeping them here stops every module above from depending on whichever
//// sibling first defined them.

import core/entry
import core/json
import core/message
import core/todo_list
import etui/buffer
import etui/geometry.{type Rect}
import etui/span
import etui/widgets/textarea as text_area
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import host/build_identity
import session_view/advisor_history
import session_view/advisor_pending
import session_view/agent_roster
import session_view/agent_view
import session_view/approval
import session_view/attempt
import session_view/block_summary
import session_view/cache_watch
import session_view/command
import session_view/composer
import session_view/connection_event
import session_view/context_view
import session_view/goal_view
import session_view/history_view
import session_view/live_jobs
import session_view/notes_view
import session_view/protocol.{Strand}
import session_view/reviewer_status
import session_view/session_channel
import session_view/snapshot
import session_view/snapshot_view
import session_view/tool_activity
import session_view/transcript_line.{
  type CacheNotice, type Line, type Stream, type Submission, type ToolTail,
  Failure, Line, System,
}
import session_view/transcript_lines
import session_view/worktree_view
import tui/agent_messages
import tui/agent_strip
import tui/agents
import tui/appearance
import tui/approval_panel
import tui/attachment
import tui/attempt_replay
import tui/bootstrap
import tui/buffered
import tui/completion_summary
import tui/effect
import tui/focused_goal_panel
import tui/herdr
import tui/job
import tui/job_runner
import tui/live_tail
import tui/model_selector
import tui/msg
import tui/note_panel
import tui/pacing
import tui/peer_links
import tui/queue_editor
import tui/recording
import tui/selection
import tui/session_selector
import tui/summary_panel
import tui/terminal_lane
import tui/transcript_anchor
import tui/workspace
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
  /// A live ClientGateway conversation. Commands are written through the
  /// adopted session channel, which holds the socket, and the server's own
  /// events come back as transcript. The socket is not repeated here: a
  /// second copy of the handle is what let a reducer write to a socket with
  /// no lane in front of it, a state the shipped client never reaches.
  Attached

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
    /// session.
    shared: Shared,
    /// The terminal's own state.
    view: View,
  )
}

/// The session state: what a second host showing the same session would need
/// to show it or act on it correctly.
///
/// It holds what the daemon said, what this client has sent and not yet seen
/// committed, the bookkeeping the lane's reads and the reads in flight need,
/// and the revision counters shared reducers bump so a host can tell that a
/// projection is stale without comparing the whole record. The four host
/// handles, `inbox`, `channel`, `replay_inbox` and `recorder`, are here with
/// their concrete terminal types for now, because the reducers that will
/// move with this record name them in the effects they queue; they become
/// type parameters in the next slice. The step extraction design
/// (`docs/design-notes/step-extraction.md`) gives the reason for each
/// field's placement.
@internal
pub type Shared {
  Shared(
    /// Set when the operator or the session ends the loop; the runtime
    /// stops after the step that set it.
    quit: Bool,
    /// The history window of each session and strand the operator has left,
    /// keyed like `View.strand_workspaces`. A strand with no entry here
    /// restores an empty window.
    parked_scrollback: Dict(#(String, String), history_view.State),
    /// Images the next submission carries, taken from the composer.
    attachments: List(composer.Attachment),
    /// Ownership marker only; the unsent encoded intent belongs to Channel.
    pending_submission: Option(SubmissionSource),
    /// The interrupt held until the operation it stopped settles.
    interrupt: Option(Interrupt),
    /// The strand whose prompt is on its way to the daemon, if any.
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
    /// The client's own lines: the banner, build, configuration, approval
    /// and error lines drawn with the session's records.
    transcript: List(Line),
    /// The active strand's entries from the last capture.
    records: List(protocol.EntryRecord),
    /// The prompt-cache ledger: each strand's last billed row, the pushed
    /// rows waiting for a capture that covers them, and the strands a model
    /// switch has fenced (`session_view/cache_watch`).
    cache: cache_watch.Ledger,
    /// Cache-miss notices raised on this connection, oldest first. They are
    /// transient by design: a reattach rebuilds the durable transcript and
    /// these do not come back, which is acceptable for a notice about the
    /// moment it happened, and is what keeps them out of the store.
    cache_notices: List(CacheNotice),
    /// Bounded scrollback is independent of the authoritative live cut.
    scrollback: history_view.State,
    /// The last line said to the operator, shown in the footer.
    notice: String,
    /// Current Git observation and independent file-navigation state.
    worktree: worktree_view.State,
    /// Server-observed current context and independent inspector state.
    context: context_view.State,
    /// Attachment-local terminal result provenance.
    completion: completion_summary.State,
    /// Exact attachment which owns the remembered operation boundaries.
    completion_owner: String,
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
    /// The advisor's undelivered nudge queue, observed while the primary is
    /// idle. `None` is "nothing observed", never "the queue is empty".
    nudges: Option(advisor_pending.Board),
    /// One pending-nudge read waiting for a free command lane.
    nudges_refresh: worktree_view.Refresh,
    /// Attachment which owns the one issued nudge read; a board answering an
    /// attachment that has gone describes a session nobody is watching.
    nudges_awaiting: Option(String),
    /// Actual lane request ID, so an unrelated refusal cannot settle it.
    nudges_request: Option(Int),
    /// Summarizer labels for long reasoning blocks and delivered advisor
    /// messages, stored and live, and the exact-key reads this attachment
    /// still owes (protocol 050). Cleared with the attachment.
    summaries: block_summary.Labels,
    /// The session goal as the server last rendered it. `None` is "nothing
    /// observed", never "no goal is pinned" — that claim is a `NoGoal`
    /// board, and only the server can make it.
    goal: Option(goal_view.Board),
    /// One goal read waiting for a free command lane.
    goal_refresh: worktree_view.Refresh,
    /// Attachment which owns the one issued goal command, read or mutation
    /// alike, since both are answered with a board.
    goal_awaiting: Option(String),
    /// Actual lane request ID, so an unrelated refusal cannot settle it.
    goal_request: Option(Int),
    /// Whether the next board is the operator's own `/goal` question.
    goal_report: GoalReport,
    /// Latest explicit read of the notes board, with its own revision.
    note_board: Option(notes_view.Board),
    /// Latest explicit notes target waiting for the existing command lane.
    notes_requested: Option(String),
    /// The models the daemon listed.
    models: List(protocol.ModelInfo),
    /// Slash commands loaded by the currently attached daemon.
    skills: List(command.Suggestion),
    /// The model the active strand runs on, as the daemon reported it.
    current_model: String,
    /// The session's working directory and branch.
    workspace: workspace.Context,
    /// The strands the last capture listed.
    strands: List(protocol.Strand),
    /// Current reviewer progress, with operation-owned task excerpts.
    reviewer_rows: List(reviewer_status.Row),
    /// Stable, operation-owned summaries of the captured agent roster.
    agent_rows: List(agent_view.Row),
    /// The agent roster's memory between captures: the daemon's glances,
    /// and the per-operation clocks and context sizes the strip's rows show.
    roster: agent_roster.Roster,
    /// At most twenty provenance-verified sends observed in this attachment.
    agent_messages: List(agent_messages.Item),
    /// Full advisor-only commentary from the bounded captured ancestry.
    advisor_history: advisor_history.Board,
    /// Each strand's newest todo board seen in a capture or an arriving
    /// entry. Kept across cuts so a window that has moved past the last
    /// `todo` call does not blank the pinned panel; released with the
    /// session.
    todo_boards: Dict(String, todo_list.Board),
    /// A strand whose board should be read from its notes because its
    /// capture reached no `todo` call; sent when the read lane is free.
    todo_seed: Option(String),
    /// Strands already asked about in this session, so each costs at most
    /// one read.
    todo_asked: set.Set(String),
    /// The strand the transcript shows and the composer addresses.
    active_strand: String,
    /// The session this client is attached to, or showing.
    session: String,
    /// One catalogue display name, paired with the identity that owns it.
    session_label: Option(#(String, String)),
    /// The adopted connection's socket traffic, with what the runtime already
    /// received from it for the next step. An adoption replaces the whole
    /// value, so the old socket's held messages leave the model with it.
    inbox: buffered.Inbox(connection_event.Message),
    /// Where commands go: a live lane, nowhere, the preview or a replay.
    peer: Peer,
    /// Serial credited state for the adopted socket only.
    channel: Option(terminal_lane.Lane),
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
    /// Current pending requests and at most sixteen bounded resolved summaries.
    approvals: List(approval.Review),
    /// Last sent mutation whose outcome was not observed; survives adoption.
    unconfirmed: Option(UnconfirmedSubmission),
    /// Two-slot effect-free replay state and its terminal-owned delivery lane.
    replay_state: attempt_replay.State,
    /// Filled one event at a time, since a tick applies at most one.
    replay_inbox: buffered.Inbox(attempt.Event),
    /// A malformed local recording stops replay rather than skipping a frame.
    replay_error: Option(String),
    /// The request identity the next command is encoded with.
    next_id: Int,
    /// The token usage the last capture or settlement reported.
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
    /// Whether transcript lines are drawn with their full details. The
    /// shared line builders read it through `presentation`, and the generation
    /// clock checks it.
    details_expanded: Bool,
    /// When the active strand's current activity began, on the monotonic
    /// clock; `None` while it is idle. Set and cleared on the indicator's
    /// tick so the render stays pure.
    activity_started_ms: Option(Int),
    /// Whole seconds the active strand has been busy, recomputed on the
    /// tick and shown beside the phase so a long think reads as time
    /// passing rather than as a stall.
    activity_elapsed_s: Int,
    /// Whole seconds since `generation_started_ms`, recomputed on the tick
    /// and shown on a live reasoning row. A reading of the generation clock
    /// rather than a clock of its own: zero while no generation runs.
    generation_elapsed_s: Int,
    /// The live answers still streaming, one per generation.
    streams: List(Stream),
    /// The live output tails of tools still running.
    tool_tails: List(ToolTail),
    /// Bumped by every change to the data the transcript rows are built
    /// from; the projection rebuilds when it differs from
    /// `View.rendered_revision`.
    render_revision: Int,
    /// Compact invocation rows keyed by their complete immutable outcome.
    /// Rebuilds retain only calls in the current projection.
    compact_call_cache: Dict(tool_activity.Call, List(Line)),
    /// Narrative presentation retains only the current entries and owner.
    /// The key carries the summarizer labels the entry's rows show, so a
    /// label arriving misses the cache for that entry alone.
    compact_entry_cache: Dict(
      #(entry.Entry, Option(message.Origin), List(#(Int, String))),
      List(Line),
    ),
    /// Entries committed on the active strand since the record rows were
    /// last built, which the projection appends instead of rebuilding.
    pending_records: List(protocol.EntryRecord),
    /// Cleared by a reducer that changes the durable records in a way an
    /// append cannot express; the projection sets it again when it rebuilds
    /// the record rows.
    record_cache_valid: Bool,
    /// Bumped by a change the cached frame does not show; the paint redraws
    /// when it differs from the frame cache's revision.
    frame_revision: Int,
    /// The clock readings the current event is applied at. The step copies
    /// them from its message before any reducer runs, and every reducer that
    /// needs the time reads them here, so a step reads no clock.
    stamp: msg.Stamp,
    /// The build this client runs, which the build-mismatch notice compares
    /// with the daemon's. It comes from two environment variables that do
    /// not change while the process runs, so it is read once, when the model
    /// is created, rather than on every coherent cut that draws the notice.
    client_build: build_identity.Identity,
    /// Bumped by operator or traffic activity (`mark_activity`); idle pacing
    /// reads it.
    activity_revision: Int,
    /// Whether the last connection drain stopped at its batch rather than
    /// at an empty buffer, so the mailbox may still hold frames whose wakes
    /// were already spent on earlier ticks (`inbound.drain_connection`).
    connection_backlog: ConnectionBacklog,
    /// The open `--record` file, when the launch asked for one. Present in
    /// the model because the reducers that decide recording lines, input
    /// and channelless messages alike, name it in the effects they queue.
    recorder: Option(recording.Recorder),
    /// Effects this step has decided on, newest first, and the only queue a
    /// step has. The reducer only appends here, through `emit`, `record` and
    /// `hold_channel`; `runtime.take` empties it at the end of every step,
    /// so between two `update` calls it is empty. A caller that runs a
    /// reducer outside `update` leaves its effects here until it calls
    /// `runtime.flush` or the next step collects them.
    outbox: List(effect.Effect),
    /// Bumped by a reducer that empties the transcript (`/clear`, a new
    /// session), so the view drops its record rows at the next projection.
    record_cache_epoch: Int,
  )
}

/// The terminal's own state: what only the terminal reads, or what names an
/// etui type, a terminal surface, a daemon-control job or the pane reporter.
///
/// It holds the screen size and the composer, the panels and overlays with
/// their cursors and scroll offsets, the row projection's outputs, frame
/// pacing, the host clocks, the daemon-control, reconnect and provisional
/// attachment job slots, the runtime's job table, and the etui render caches.
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
    /// The footer's agent count, derived from the strands or agent rows
    /// when they change.
    agent_summary: String,
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

/// What the last connection drain says about the mailbox behind it.
///
/// The socket wakes the loop after the frames it files, one wake per
/// `connection.wake_interval_ms`, so a burst of more frames than one drain
/// takes can outrun its wakes: two wakes, two batches, and the rest of the
/// burst left in the mailbox with no wake behind it. A drain that stopped at
/// its batch records that here, and the loop keeps its own short poll until
/// a drain finds the buffer empty.
@internal
pub type ConnectionBacklog {
  /// The last drain emptied the buffer before its batch ran out, so the
  /// mailbox held nothing more when the step began; anything filed since
  /// has a wake of its own behind it.
  MailboxDrained

  /// The last drain took a whole batch, so the mailbox may hold more.
  MailboxMayHoldMore
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
@internal
pub fn mark_activity(model: Model) -> Model {
  Model(
    shared: Shared(
      ..model.shared,
      activity_revision: model.shared.activity_revision + 1,
    ),
    view: View(..model.view, quiet_for_ms: 0),
  )
}

/// Stores `channel` as the adopted lane, moving what it queued into the
/// outbox.
///
/// Every reducer that transitions the adopted lane stores the result
/// through this, so the lane's writes, closes and recording notes join the
/// step's one queue at the point they were decided, in order with every
/// other effect the step queues. The model's lane therefore holds no
/// outputs between two reducer calls, and replacing or dropping it can lose
/// nothing it decided.
///
/// ## Examples
///
/// ```gleam
/// let #(channel, updates) = session_channel.receive(channel, message, now:)
/// tui_model.hold_channel(model, channel)
/// ```
@internal
pub fn hold_channel(model: Model, channel: terminal_lane.Lane) -> Model {
  let #(channel, outputs) = session_channel.take_outputs(channel)
  let outbox =
    list.fold(outputs, model.shared.outbox, fn(outbox, output) {
      [effect.Channel(output), ..outbox]
    })
  Model(
    ..model,
    shared: Shared(..model.shared, channel: Some(channel), outbox:),
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
/// ## Examples
///
/// ```gleam
/// tui_model.record(model, recording.Arrived(connection_event.Connected))
/// ```
@internal
pub fn record(model: Model, event: recording.Recorded) -> Model {
  case model.shared.recorder {
    Some(recorder) -> emit(model, effect.Record(recorder, event))
    None -> model
  }
}

/// Opens a step for one input: stores the instant it is applied at and
/// queues its recording line, if it is one that replays and the terminal
/// is recording.
///
/// `tui.step` calls this before the reducer runs, so every reducer reads
/// the input's time from `Model.stamp`, and the input's line is the first
/// effect of its step and precedes every line the input causes.
///
/// ## Examples
///
/// ```gleam
/// let model = tui_model.start_step(model, model.stamp, msg.Ticked)
/// ```
@internal
pub fn start_step(model: Model, at: msg.Stamp, event: msg.Event) -> Model {
  let model = Model(..model, shared: Shared(..model.shared, stamp: at))
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
    shared: Shared(..model.shared, outbox: [requested, ..model.shared.outbox]),
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
@internal
pub fn invalidate_frame(model: Model) -> Model {
  Model(
    ..model,
    shared: Shared(
      ..model.shared,
      frame_revision: model.shared.frame_revision + 1,
    ),
  )
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

/// The active strand, if an interrupt for it is outstanding.
@internal
pub fn active_interrupt(model: Model) -> Option(String) {
  case model.shared.interrupt {
    Some(Interrupt(strand:, ..)) ->
      case strand == model.shared.active_strand {
        True -> Some(strand)
        False -> None
      }
    None -> None
  }
}

/// Reports whether the active strand is submitting or running.
@internal
pub fn active_strand_live(model: Model) -> Bool {
  case active_strand_phase(model) {
    Some(_) -> True
    None -> False
  }
}

/// The active strand's live phase, or `submitting` while its prompt is on
/// the way.
@internal
pub fn active_strand_phase(model: Model) -> Option(String) {
  case model.shared.submitting {
    Some(strand) if strand == model.shared.active_strand -> Some("submitting")
    _ ->
      model.shared.strands
      |> list.find_map(fn(strand) {
        let Strand(id:, live_phase:, ..) = strand
        case id == model.shared.active_strand, live_phase {
          True, Some(phase) -> Ok(phase)
          _, _ -> Error(Nil)
        }
      })
      |> result.map(Some)
      |> result.unwrap(None)
  }
}

/// Reports whether `name` is one of the listed strands.
@internal
pub fn is_known_strand(strands: List(protocol.Strand), name: String) -> Bool {
  list.any(strands, fn(strand) {
    let Strand(id:, ..) = strand
    id == name
  })
}

/// Appends a system line to the transcript and shows it as the notice.
@internal
pub fn append_system(model: Model, text: String) -> Model {
  Model(
    ..model,
    shared: Shared(
      ..model.shared,
      transcript: list.append(model.shared.transcript, [Line(System, text)]),
      record_cache_valid: False,
      notice: text,
    ),
  )
  |> invalidate_transcript
  |> invalidate_frame
}

/// Appends a failure line to the transcript and shows it as the notice.
@internal
pub fn append_error(model: Model, text: String) -> Model {
  Model(
    ..model,
    shared: Shared(
      ..model.shared,
      transcript: list.append(model.shared.transcript, [Line(Failure, text)]),
      record_cache_valid: False,
      notice: text,
    ),
  )
  |> invalidate_transcript
  |> invalidate_frame
}

/// A transcript line that informs without alarm, in the System speaker, so
/// a build mismatch reads as a notice rather than a failure. The attach has
/// already succeeded when this is called; the line explains the pair, it
/// does not report a refusal.
@internal
pub fn append_notice(model: Model, text: String) -> Model {
  Model(
    ..model,
    shared: Shared(
      ..model.shared,
      transcript: list.append(model.shared.transcript, [Line(System, text)]),
      record_cache_valid: False,
      notice: text,
    ),
  )
  |> invalidate_transcript
  |> invalidate_frame
}

/// Transcript revisions advance only beside mutations of the projection's
/// source data. Keeping the invalidation token separate from terminal ticks
/// prevents session history from becoming an idle-time CPU cost.
@internal
pub fn invalidate_transcript(model: Model) -> Model {
  Model(
    ..model,
    shared: Shared(
      ..model.shared,
      render_revision: model.shared.render_revision + 1,
    ),
  )
}

/// The identity of the current attachment, used to reject a queue, job or
/// goal reply that arrives after the attachment changed. Empty when nothing
/// is captured.
@internal
pub fn queue_owner(model: Model) -> String {
  case model.shared.captured {
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

// --- the session goal -------------------------------------------------------

/// Whether the board that arrives next is the operator's own question.
///
/// A named set rather than a boolean field, because the cases are
/// different events: the operator asked `/goal` and is owed a block in the
/// transcript, the operator asked for a change and is owed one line once it
/// is committed, or the terminal refreshed the row beside the composer on
/// its own and owes them nothing.
pub type GoalReport {
  /// The operator typed `/goal`; the next board is printed for them.
  ReportGoal

  /// The operator asked for a mutation and this line confirms it. The line
  /// is held until the board arrives rather than printed at send time,
  /// because a server that refuses the command answers with a refusal: a
  /// confirmation printed on the way out would sit above the sentence
  /// saying it did not happen.
  ConfirmGoal(line: String)

  /// An automatic refresh. The row is updated and nothing is printed.
  HoldGoalReport
}

/// The captured attachment's session, epoch and incarnation as a JSON
/// array, or an empty string when nothing is captured.
@internal
pub fn queue_namespace(model: Model) -> String {
  case model.shared.captured {
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

/// What the transcript's line builders read of this model.
///
/// The builders take this record rather than the model, so that they need
/// nothing of the terminal; this is the one place that knows which model
/// fields they read.
///
/// ## Examples
///
/// ```gleam
/// // transcript_lines.display_streams(tui_model.presentation(model))
/// ```
pub fn presentation(model: Model) -> transcript_lines.Presentation {
  transcript_lines.Presentation(
    active_strand: model.shared.active_strand,
    extent: transcript_lines.details_extent(model.shared.details_expanded),
    captured: model.shared.captured,
    records: model.shared.records,
    streams: model.shared.streams,
    tool_tails: model.shared.tool_tails,
    queued: model.shared.queued,
    awaiting_outcome: model.shared.awaiting_outcome,
    cache_notices: model.shared.cache_notices,
    summaries: model.shared.summaries,
    compact_entry_cache: model.shared.compact_entry_cache,
    compact_call_cache: model.shared.compact_call_cache,
    worktree: model.shared.worktree,
  )
}
