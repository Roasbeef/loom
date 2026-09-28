//// The session state the terminal shares with any other host of a
//// session, and the types that record names.
////
//// `Shared` is the half of the terminal's model that a second host showing
//// the same session would need (`docs/design-notes/step-extraction.md`,
//// section 1). It sits in its own module, below `tui/model`, because the
//// reducers being cut down to it (issue #569) need functions over `Shared`
//// alone, and those functions cannot live beside the terminal's own
//// helpers of the same names in `tui/model`. This module imports nothing of
//// the terminal: no etui type, no job slot, no `Subject`. A later slice
//// moves it into `session_view` as `session_view/model`.

import core/entry
import core/message
import core/todo_list
import gleam/dict.{type Dict}
import gleam/option.{type Option}
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
import session_view/inbox
import session_view/live_jobs
import session_view/notes_view
import session_view/protocol
import session_view/reviewer_status
import session_view/session_channel
import session_view/snapshot
import session_view/snapshot_view
import session_view/tool_activity
import session_view/transcript_line.{
  type CacheNotice, type Line, type Stream, type Submission, type ToolTail,
}
import session_view/worktree_view
import tui/agent_messages
import tui/attempt_replay
import tui/completion_summary
import tui/msg
import tui/workspace

/// The session state: what a second host showing the same session would need
/// to show it or act on it correctly.
///
/// It holds what the daemon said, what this client has sent and not yet seen
/// committed, the bookkeeping the lane's reads and the reads in flight need,
/// and the revision counters shared reducers bump so a host can tell that a
/// projection is stale without comparing the whole record. The step
/// extraction design (`docs/design-notes/step-extraction.md`) gives the
/// reason for each field's placement.
///
/// The record also holds the host's handles: the adopted lane, the two
/// inboxes and the recorder. The reducers that will move with this record
/// name those handles, in the effects they queue and in the inbox they file
/// a frame into, but never act on them, so their types are parameters that
/// the host binds:
///
/// - `socket` is the connection a lane writes to and closes, in
///   `channel` and `replay_state`.
/// - `recorder` is the recording handle a lane notes attempts to and a
///   channelless arrival is written to, in `channel`, `replay_state` and
///   `recorder`.
/// - `source` identifies where the connection inbox's frames were read from;
///   admission compares it to drop a frame from a socket the model no longer
///   reads.
/// - `replay_source` identifies where the replay inbox's recorded events are
///   read from. Nothing compares it: admission files every replayed event,
///   and the source is only the subject the runtime reads before a step.
///
/// The two inboxes need separate source parameters because the terminal
/// reads each from a subject typed by its message, `Subject(Message)` for
/// frames and `Subject(attempt.Event)` for a replay, and one parameter
/// cannot be both. The terminal binds all four in `TerminalShared`; a host
/// with no mailboxes and no recording, such as the web view, would bind the
/// last three to `Nil`.
@internal
pub type Shared(socket, recorder, source, replay_source) {
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
    inbox: inbox.Inbox(source, connection_event.Message),
    /// Where commands go: a live lane, nowhere, the preview or a replay.
    peer: Peer,
    /// Serial credited state for the adopted socket only.
    channel: Option(session_channel.Channel(socket, recorder)),
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
    replay_state: attempt_replay.State(socket, recorder),
    /// Filled one event at a time, since a tick applies at most one.
    replay_inbox: inbox.Inbox(replay_source, attempt.Event),
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
    recorder: Option(recorder),
    /// Bumped by a reducer that empties the transcript (`/clear`, a new
    /// session), so the view drops its record rows at the next projection.
    record_cache_epoch: Int,
  )
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

/// Only composer-originated sends consume the visible draft.
@internal
pub type SubmissionSource {
  /// Text, attachments and mode remain in the existing composer until send.
  ComposerSubmission

  /// A selector action must preserve unrelated composer text.
  OverlaySubmission
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
