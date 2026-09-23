//// The terminal client's one `Model` record and the types it names.
////
//// Every other part of the client is a function over this record, so it
//// sits at the bottom of the module graph: `tui` and each module under it
//// import `Model` from here, and this module imports none of them. Gleam
//// forbids import cycles, which is what keeps the order fixed; a type the
//// record names has to live here or below, never in a module that reduces
//// or paints the record.
////
//// Besides the types, the module holds the small operations that nearly
//// every reducer needs and that read or bump only the record itself:
//// appending a system or error line, the transcript and frame revision
//// counters, the activity mark idle pacing reads, the attachment identity
//// that replies are checked against, and the active strand's live phase.
//// Keeping them here stops every module above from depending on whichever
//// sibling first defined them.

import core/entry
import core/ids
import core/json
import core/message
import etui/buffer
import etui/geometry.{type Rect}
import etui/span
import etui/widgets/textarea as text_area
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import tui/advisor_pending
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
import tui/command
import tui/completion_summary
import tui/composer
import tui/connection
import tui/context_view
import tui/daemon/protocol as control_protocol
import tui/daemon/selection as daemon_selection
import tui/focused_goal_panel
import tui/goal_view
import tui/herdr
import tui/history_view
import tui/live_jobs
import tui/model_selector
import tui/note_panel
import tui/notes_view
import tui/pacing
import tui/protocol.{Strand}
import tui/queue_editor
import tui/recording
import tui/reviewer_status
import tui/selection
import tui/session_channel
import tui/session_selector
import tui/sessions
import tui/snapshot
import tui/snapshot_view
import tui/summary_panel
import tui/tool_activity
import tui/transcript_anchor
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

  /// One blank row, placed by the projection that knows it is needed.
  ///
  /// Every other block closes itself with a blank, but the tool family is
  /// excluded from that so a call's summary can never be split from the
  /// patch, result or note rows beneath it. The gap between one call and the
  /// next is therefore nobody's trailing blank, and only a fold that can see
  /// where one group ends and another begins is in a position to emit it.
  /// This is the row it emits.
  Spacer
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

/// Scroll direction names the operation without carrying a Boolean polarity
/// through the two independently scrollable reading surfaces.
@internal
pub type ScrollDirection {
  Older
  Newer
}

/// One rendered transcript line before markdown and wrapping.
@internal
pub type Line {
  Line(speaker: Speaker, text: String)
}

/// The undurable fragments of one strand-and-kind generation.
///
/// A request owns its text, thinking and tool-call fragments. Operation IDs
/// alone cannot separate requests around tool batches or retries. An `end`
/// observation keeps an identity marker so an older captured preview cannot
/// resurrect a completed answer. When the request names its reserved response
/// entry, its bounded fragments remain visible until that entry arrives.
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
  AgentInspector(selected: agents.Inspector)
  GoalInspector(state: focused_goal_panel.State)
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
  PageLoaded(
    page: control_protocol.Page,
    selected: String,
    collection: session_selector.Collection,
  )

  /// The daemon removed this registration and its database.
  SessionDeleted(session_id: String)

  /// Acknowledged archive preserves files while removing the active row.
  SessionArchived(session_id: String)

  /// Acknowledged restoration removes the row from the archive page.
  SessionRestored(session_id: String)

  /// The daemon acknowledged a rename with its canonical catalogue row.
  SessionRenamed(row: control_protocol.Session)
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
    /// Viewport copy metadata for these exact rendered cells.
    selection_gutters: List(#(Int, Int)),
  )
}

/// A prompt-cache miss already rendered as its transcript row.
///
/// The row belongs inside the transcript rather than at the end of it, so
/// the notice names the entry it follows. A usage event arrives after the
/// entry whose request it bills, which is what puts the row under the turn
/// that missed; naming the entry rather than a position is what survives the
/// compact projection, which joins a call to a result several entries later
/// and must not be cut between them.
@internal
pub type CacheNotice {
  CacheNotice(
    /// The strand whose transcript shows the row.
    strand: String,
    /// The last entry that strand held when the row was raised.
    after_entry: ids.EntryId,
    /// The operator-facing line, already formatted.
    text: String,
  )
}

/// One pushed usage row waiting for a capture that covers its sequence.
///
/// The capture supplies the model configuration against which a cache
/// comparison is safe. Only the latest row per strand is retained; losing an
/// intermediate comparison can omit a warning but cannot invent one.
@internal
pub type CacheObservation {
  CacheObservation(
    /// Durable sequence of the observed usage row.
    seq: Int,
    /// Provider operation, when the gateway could attribute the row.
    operation: Option(String),
    /// Fixed-shape provider counters for this request.
    usage: message.Usage,
    /// Terminal-clock instant when the push arrived.
    at: Int,
  )
}

/// Local editing and reading state belongs to an exact session and strand.
///
/// A parked workspace holds the editor itself, including its cursor, rather
/// than only its text. Neither inspecting another agent nor reconnecting can
/// turn that draft into input for another recipient.
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
    /// The bounded ancestry window and its live/reading mode.
    scrollback: history_view.State,
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
    /// Launch-time color capability, never read while rendering.
    palette: appearance.Palette,
    input: text_area.TextAreaState,
    /// Unsent drafts and reading endpoints never cross session identities.
    strand_workspaces: Dict(#(String, String), StrandWorkspace),
    /// The saved endpoint being restored on the next row-cache rebuild.
    restored_workspace: Option(StrandWorkspace),
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
    /// The last provider usage row each strand billed, with the instant it
    /// arrived, which is all the prompt-cache detector remembers. Keyed by
    /// strand because a sub-agent's request says nothing about whether the
    /// primary's cached prefix survived the operator's pause.
    cache_watch: Dict(String, cache_miss.Watch),
    /// Highest live usage observation already folded on each strand. A
    /// capture owns cumulative totals; this cursor prevents a delayed push
    /// from reporting the same settlement twice.
    cache_seen_seq: Dict(String, Int),
    /// Latest row per strand awaiting a capture that covers its sequence.
    cache_pending: Dict(String, CacheObservation),
    /// A model switch fences the first observed operation on that strand.
    /// Every row from it may bill the old provider, so only a later operation
    /// can establish the new provider's baseline.
    cache_fence: Dict(String, Option(String)),
    /// Cache-miss notices raised on this connection, oldest first. They are
    /// transient by design: a reattach rebuilds the durable transcript and
    /// these do not come back, which is acceptable for a notice about the
    /// moment it happened, and is what keeps them out of the store.
    cache_notices: List(CacheNotice),
    /// The footer's cache label for the active strand, as of the last tick:
    /// what `cache_miss.outlook` says rendered as text, or `""` when it
    /// says nothing. Held as a string rather than an `Outlook` so the tick
    /// can compare the new label against the old and repaint only when the
    /// reading actually changed — the reading moves once a minute at most
    /// until a countdown reaches its final stretch.
    cache_outlook: String,
    /// Bounded scrollback is independent of the authoritative live cut.
    scrollback: history_view.State,
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
    /// Focused evidence section in the completion summary.
    summary_tab: summary_panel.Tab,
    /// Stable-index projection of the selected current job.
    summary_job_selected: Int,
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
    /// Stable cell key within the inspected notes board.
    note_selected: Option(String),
    /// Selected note representation, independent of transcript detail mode.
    note_mode: note_panel.Mode,
    /// Selected note body offset, independent of transcript reading position.
    note_scroll: Int,
    /// Latest explicit notes target waiting for the existing command lane.
    notes_requested: Option(String),
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
    /// Stable, operation-owned summaries of the captured agent roster.
    agent_rows: List(agent_view.Row),
    /// At most twenty provenance-verified sends observed in this attachment.
    agent_messages: List(agent_messages.Item),
    active_strand: String,
    session: String,
    /// One catalogue display name, paired with the identity that owns it.
    session_label: Option(#(String, String)),
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
    /// The one reconnect an unexpected daemon death is allowed, and whether it
    /// has already been spent. Kept in the model rather than beside the loop so
    /// the decision not to reconnect twice is made from the state the operator
    /// can see.
    reconnect: Reconnect,
    /// Retained after an uncertain create so another key cannot duplicate it.
    creation_key: Option(String),
    /// Current pending requests and at most sixteen bounded resolved summaries.
    approvals: List(approval.Review),
    /// Questions already presented locally, keyed by their exact durable sequence.
    prompted_approvals: List(#(String, Int)),
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
    /// Copy gutters aligned with `rendered_rows`, built in the same pass.
    rendered_gutters: List(Int),
    record_rows: List(span.Line),
    /// Durable copy gutters, aligned with `record_rows`.
    record_gutters: List(Int),
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
    /// Screen row and transcript gutter captured with `selection_frame`.
    selection_gutters: List(#(Int, Int)),
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
  ReconnectAttempting(
    /// The signal that stops a relaunch whose outcome outlives the operator's
    /// patience, cancelled when the terminal quits.
    cancel: weft.Cancel,
    /// Terminal-owned mailbox for the relayed outcome.
    replies: Subject(weft.Pulled(daemon_selection.Host, String)),
  )

  /// This daemon death has had its one attempt. Nothing runs again until an
  /// attachment is adopted, which is what proves the reconnect worked.
  ReconnectSpent
}

/// Rows held back from the bottom-anchored viewport. Added to the scroll
/// offset, which counts from the same end, this is what walks the view down
/// to the tail a frame at a time.
@internal
pub fn viewport_backlog(model: Model) -> Int {
  int.max(0, model.rendered_row_count - model.revealed_rows)
}

/// Records operator or traffic activity, which resets the quiet-time
/// counter that idle pacing reads.
@internal
pub fn mark_activity(model: Model) -> Model {
  Model(
    ..model,
    activity_revision: model.activity_revision + 1,
    quiet_for_ms: 0,
  )
}

/// Marks the cached frame stale so the next paint redraws it.
@internal
pub fn invalidate_frame(model: Model) -> Model {
  Model(..model, frame_revision: model.frame_revision + 1)
}

/// Reading mode owns the endpoint even at offset zero, so a frozen viewport at
/// the tail is not the live tail: returning to live output is an explicit
/// gesture rather than a consequence of scrolling back down to the newest row.
/// The offset covers the converse, a viewport lifted off the tail before any
/// endpoint was frozen.
@internal
pub fn reading_history(model: Model) -> Bool {
  model.scrollback.mode == history_view.Reading || model.scroll_offset > 0
}

/// The active strand, if an interrupt for it is outstanding.
@internal
pub fn active_interrupt(model: Model) -> Option(String) {
  case model.interrupt {
    Some(Interrupt(strand:, ..)) ->
      case strand == model.active_strand {
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
    transcript: list.append(model.transcript, [Line(System, text)]),
    record_cache_valid: False,
    notice: text,
  )
  |> invalidate_transcript
  |> invalidate_frame
}

/// Appends a failure line to the transcript and shows it as the notice.
@internal
pub fn append_error(model: Model, text: String) -> Model {
  Model(
    ..model,
    transcript: list.append(model.transcript, [Line(Failure, text)]),
    record_cache_valid: False,
    notice: text,
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
    transcript: list.append(model.transcript, [Line(System, text)]),
    record_cache_valid: False,
    notice: text,
  )
  |> invalidate_transcript
  |> invalidate_frame
}

/// Transcript revisions advance only beside mutations of the projection's
/// source data. Keeping the invalidation token separate from terminal ticks
/// prevents session history from becoming an idle-time CPU cost.
@internal
pub fn invalidate_transcript(model: Model) -> Model {
  Model(..model, render_revision: model.render_revision + 1)
}

/// The identity of the current attachment, used to reject a queue, job or
/// goal reply that arrives after the attachment changed. Empty when nothing
/// is captured.
@internal
pub fn queue_owner(model: Model) -> String {
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
