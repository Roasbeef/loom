//// The session state every host of a session holds, and the types that
//// record names.
////
//// `Shared` is what a host showing a session needs to show it and act on it
//// correctly: what the daemon said, what this client has sent and not yet
//// seen committed, and the reads in flight
//// (`docs/design-notes/step-extraction.md`, section 1). The shared step's
//// reducers, the folds in `session_view/event_fold` and
//// `session_view/lane_fold`, the commands in `session_view/commands` and the
//// reads in `session_view/surfaces`, take and return it alone, so any host
//// can run them. The record lives in `session_view`, the package lint's R6
//// holds to the portable subset, so it names no etui type, no job slot and
//// no `Subject`: the four host handles it carries, the adopted lane's socket
//// and recorder and the sources of its two inboxes, are type parameters.
//// The terminal binds them in `tui/model` (`TerminalShared`) and holds the
//// record beside its own `View`; the web view binds them to its relay
//// and `Nil`.
////
//// Four fields are presentation revisions rather than session facts:
//// `render_revision`, `frame_revision`, `activity_revision` and
//// `record_cache_epoch`, with the `record_cache_valid` flag beside them.
//// The reducers bump them when they change what a host draws, so a host
//// compares a revision with the one it last drew instead of comparing the
//// whole record after every event. A host that rebuilds its view on every
//// update may ignore them (`docs/design-notes/step-extraction.md`, question
//// 3).
////
//// ## Flow
////
//// `hold_channel` → `record_surface` → `invalidate_transcript` → `invalidate_frame` → `mark_activity` → `presentation`
////
//// 1. `hold_channel` stores the adopted lane after every transition, moving the
////    outputs the lane queued into the shared outbox so none is lost when the
////    lane is replaced.
//// 2. `record_surface` appends a `SurfaceFact` for the host's own surfaces to
////    follow, in the order the reducers decided it; `record_arrival` queues the
////    recording line for a message that came with no lane.
//// 3. `append_error` and `append_notice` add a transcript line and the notice,
////    then `invalidate_transcript` and `invalidate_frame` advance the revisions
////    a host compares with the ones it last drew.
//// 4. `mark_activity` says that something happened; the host decides what that
////    means for its idle pacing.
//// 5. The readers (`queue_rows`, `queue_owner`, `active_strand_live`,
////    `active_strand_phase`, `strand_running`, `is_known_strand`) answer
////    questions about the record without changing it.
//// 6. `presentation` gives the transcript's line builders the fields they read.
////
//// The state and observation types precede the operations over `Shared`.
//// `hold_channel` moves lane outputs into the host-performed effect queue.
//// `active_queue_halted` combines `active_strand_live` with the current cut.
//// `active_strand_phase` and `active_interrupt` describe different facts:
//// a retained queue belongs to the cut, while an interrupt names one operation.
//// `presentation` collects the shared facts that transcript builders consume.

import core/entry
import core/json
import core/message
import core/todo_list
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import session_view/advisor_history
import session_view/advisor_pending
import session_view/agent_messages
import session_view/agent_roster
import session_view/agent_view
import session_view/approval
import session_view/attempt
import session_view/attempt_replay
import session_view/block_summary
import session_view/cache_watch
import session_view/command
import session_view/completion_summary
import session_view/composer
import session_view/connection_event
import session_view/context_view
import session_view/goal_view
import session_view/history_view
import session_view/inbox
import session_view/live_jobs
import session_view/msg
import session_view/notes_view
import session_view/protocol
import session_view/queue_request
import session_view/remembered
import session_view/reviewer_status
import session_view/session_channel
import session_view/snapshot
import session_view/snapshot_view
import session_view/step_effect
import session_view/tool_activity
import session_view/transcript_line.{
  type CacheNotice, type Line, type Stream, type Submission, type ToolTail,
  Failure, Line, System,
}
import session_view/transcript_lines
import session_view/worktree_view

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
    /// Held prompts the daemon handed back unsent (protocol-change/038),
    /// oldest first, which no host's editor has taken yet. Shared because
    /// the returned text is the prompt's last copy and every host must keep
    /// it; each host moves it into its own editor, the terminal in
    /// `inbound.restore_returned_drafts`, and empties the list.
    returned_drafts: List(ReturnedDraft),
    /// Ownership marker only; the unsent encoded intent belongs to Channel.
    pending_submission: Option(SubmissionSource),
    /// How many composer drafts the lane has sent. `outbound.apply_submission`
    /// bumps it when a frame marked `ComposerSubmission` is sent, and empties
    /// `attachments` with it; a host empties its own editor when it moves,
    /// which the terminal does in `tui_model.hold_shared`.
    drafts_sent: Int,
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
    /// The daemon's latest reply to a command this lane sent, worded as the
    /// notice was when the reply was folded: an acknowledgement, a refusal
    /// or an outcome that could not be confirmed. Unlike `notice`, which any
    /// event replaces, nothing but another reply writes it, so a host that
    /// wants only command outcomes, as the web page does, reads this and
    /// the terminal, which reads `notice`, is unaffected. A host may reset
    /// it to empty when it starts a command of its own.
    answer: String,
    /// Current Git observation and independent file-navigation state.
    worktree: worktree_view.State,
    /// The local clock's offset from UTC in minutes, when the host knows
    /// it. A message's heading shows its clock time only then: a host that
    /// cannot say which zone its reader is in draws no time rather than a
    /// time in the wrong zone.
    clock_offset: Option(Int),
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
    /// What the session remembers for its operator and who approved it
    /// (protocol-change/073), as the daemon last listed it. `None` is "not
    /// read", never "nothing remembered".
    remembered: Option(remembered.Board),
    /// One remembered-permissions read waiting for a free command lane.
    remembered_refresh: worktree_view.Refresh,
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
    /// The operator report, with a mutation bound to its issued request ID.
    goal_report: GoalReport,
    /// What happened to the goal board that a host's goal surface has not
    /// shown yet, oldest first: a correlated board, or the reason a read or
    /// command could not refresh it. The terminal's `tui_model.hold_shared`
    /// hands each to an open goal inspector and empties the list.
    goal_observations: List(GoalObservation),
    /// Latest explicit read of the notes board, with its own revision.
    note_board: Option(notes_view.Board),
    /// Latest explicit notes target waiting for the existing command lane.
    notes_requested: Option(String),
    /// The queue editor's reads and saves on the lane: the read waiting for
    /// a free lane, the read issued, and the request ID a refusal is
    /// matched against. Shared because the lane's replies, refusals and
    /// failures settle it; the editor it fills is `View.queue_editor`.
    queue_request: queue_request.State,
    /// What the lane did with the queue editor's requests that the editor
    /// has not shown yet, oldest first. The terminal's
    /// `tui_model.hold_shared` hands each to `queue_editor.show` and empties
    /// the list.
    queue_notices: List(queue_request.Notice),
    /// What the event fold did that a host's own surfaces have to follow,
    /// oldest first: a workspace switch, a listed model catalogue, a notes
    /// board, a jobs board and the like (`SurfaceFact`). The terminal's
    /// `inbound.settle_surfaces` applies each after the call that recorded
    /// it and empties the list.
    surface_facts: List(SurfaceFact),
    /// The models the daemon listed.
    models: List(protocol.ModelInfo),
    /// Slash commands loaded by the currently attached daemon.
    skills: List(command.Suggestion),
    /// The model the active strand runs on, as the daemon reported it.
    current_model: String,
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
    /// Why the adopted lane ended, as the lane reported it: a closed
    /// socket's reason, a protocol violation or an expired deadline. `None`
    /// while the lane lives, and again once another lane is adopted. The
    /// transcript carries the same reason in a line; a host that states the
    /// connection's condition in a place of its own, as the web view's
    /// heading does, reads it here rather than parsing that line.
    ended: Option(String),
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
    /// The build-mismatch notice every coherent cut draws: a system line
    /// naming the daemon's build and this client's when they differ, and
    /// nothing when they match or the daemon named no build. Reading and
    /// comparing the two builds is the host's work, because the client's
    /// build comes from the environment (`host/build_identity`), so the host
    /// writes these lines when it adopts a daemon's control connection and
    /// a cut only splices them into the transcript.
    build_notice: List(Line),
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
    /// Effects the functions over this record decided, newest first: the
    /// adopted lane's outputs and the recording line of a channelless
    /// arrival. A host takes them after each call into those functions and
    /// appends them to its own queue at that point, so they keep their
    /// order with the effects the host decides itself; the terminal does
    /// this in `tui_model.hold_shared`. Between two such calls it is empty.
    outbox: List(step_effect.Effect(socket, recorder)),
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

/// A held prompt the daemon returned, addressed to the editor of the strand
/// that submitted it.
@internal
pub type ReturnedDraft {
  ReturnedDraft(
    /// The session the prompt was submitted in, when it came back.
    session: String,
    /// The strand the prompt was submitted to; the return follows it even
    /// when the operator has opened another strand since.
    strand: String,
    /// The prompt's text; attachments do not come back with it.
    text: String,
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

/// Which operator report is owed by a goal command's own reply.
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
  /// is bound to its issued request and held until that board arrives,
  /// because a server that refuses the command answers with a refusal: a
  /// confirmation printed on the way out would sit above the sentence
  /// saying it did not happen.
  ConfirmGoal(
    /// The line owed only after this mutation succeeds.
    line: String,
    /// The mutation's issued lane ID, absent while it waits behind a read.
    request: Option(Int),
  )

  /// An automatic refresh. The row is updated and nothing is printed.
  HoldGoalReport
}

/// Something that happened to the goal board which a host showing a goal
/// surface has to reflect there.
///
/// The goal's receivers take the shared record alone, so they cannot write
/// the terminal's goal inspector. They record one of these in
/// `Shared.goal_observations` instead, and the terminal applies it to the
/// inspector, if one is open, at the point of the call that recorded it.
@internal
pub type GoalObservation {
  /// A board answering this client's goal read or command arrived.
  GoalObserved(board: goal_view.Board)

  /// A goal read or command could not refresh the board, for `reason`: the
  /// daemon refused it, or no conversation was attached to ask.
  GoalUnavailable(reason: String)
}

/// Something the event fold, the lane fold or a command did that a host's
/// own surfaces have to follow.
///
/// The folds (`event_fold`, `lane_fold`) and the commands (`commands`) take
/// the shared record alone, so they cannot write the
/// terminal's editor, overlays or footer. Where an event, an update or a
/// command used to write them at the point it was applied, the shared
/// function records one of these in `Shared.surface_facts`, and the terminal
/// applies it after the call that recorded it, in the order recorded, before
/// the next update.
@internal
pub type SurfaceFact {
  /// The session state moved from `departing` to `arriving`, each a session
  /// and strand. The host parks its editor and viewport under `departing`
  /// and restores `arriving`'s. `previous_session` is the session before the
  /// switch, which says whether the session itself changed.
  WorkspaceSwitched(
    departing: #(String, String),
    arriving: #(String, String),
    previous_session: String,
  )

  /// A full snapshot replaced every row of the transcript, so the host's
  /// gutters and scroll position describe rows that are gone.
  SessionSynchronized

  /// The daemon listed its models; an open model selector lists them, with
  /// `current` the active strand's model at that moment.
  ModelsListed(models: List(protocol.ModelInfo), current: String)

  /// The active strand's cache watch was forgotten, so the outlook a host
  /// shows for it is gone.
  OutlookCleared

  /// A notes board arrived. The host decides whether a notes surface shows
  /// its strand, and if so takes it as `Shared.note_board`.
  NotesArrived(board: notes_view.Board)

  /// A live-jobs board answering this attachment's read replaced
  /// `previous`; a host cursor over the old board follows its job.
  JobsReplaced(previous: Option(live_jobs.Board), board: live_jobs.Board)

  /// An approval lookup answered. The host opens the record the operator
  /// asked to inspect when it is among `records`, and forgets the request
  /// when it is among `missing` or a dialog is already open.
  LookupAnswered(records: List(approval.Review), missing: List(String))

  /// The approval the host's dialog shows was settled elsewhere; the fold
  /// has written the line saying so, and the host closes the dialog.
  ApprovalSettled

  /// The captured approvals may hold a pending question the host has not
  /// offered yet; the host presents it if no overlay is open.
  ApprovalsPresented

  /// A cut replaced the active strand's pending inputs, `previous` before
  /// and `rows` after. A host selection over the old rows follows its row.
  QueueRowsCaptured(
    previous: List(snapshot_view.PendingInput),
    rows: List(snapshot_view.PendingInput),
  )

  /// A cut listed `strands` for `session`; a parked editor of a strand no
  /// longer listed releases its reading position.
  HistoryReleased(session: String, strands: List(protocol.Strand))

  /// A cut replaced the agent messages; a host browsing them keeps its
  /// selection valid.
  AgentMessagesCaptured

  /// The lane failed and released the goal board; a host's goal surface
  /// closes.
  GoalReleased

  /// The conversation was lost; the host starts its one bounded reconnect
  /// if it can.
  ConnectionLost

  /// A replay adopted a recorded attempt. The host forgets its note
  /// selection and approval prompts, and returns its viewport to the tail
  /// when the session changed.
  ReplayAdopted(session: SessionChange)

  /// The operator's interrupt of the active strand was decided and its
  /// `abort` handed to the lane. Input typed next is released with the held
  /// input rather than steered into the stopping turn, so a host that offers
  /// a steer returns its composer to prompting.
  InterruptRequested

  /// A decision for the approval a host's dialog showed was handed to the
  /// lane. The host closes the dialog; a refused decision leaves it open,
  /// with the reason in the transcript.
  ReviewAnswered

  /// A submitted draft was consumed as it was dispatched, rather than when
  /// the lane sends it: the submission was not locked behind the lane, so
  /// nothing later will move `drafts_sent` for it. `taking` says what the
  /// draft became, and so what a host's editor keeps.
  ///
  /// The two records exclude each other, which is what clears a draft once
  /// and never twice: `commands.take_draft` records no `DraftTaken` for a
  /// submission marked `ComposerSubmission`, and `outbound.apply_submission`
  /// moves `drafts_sent` only for one so marked.
  DraftTaken(taking: DraftTaking)

  /// `/clear` emptied this client's transcript; a host's gutters describe
  /// rows that are gone.
  TranscriptCleared

  /// `/approvals <id>` asked the lane for the record `id`; a host that
  /// opens a dialog when the lookup answers remembers which record it wants.
  LookupRequested(id: String)
}

/// What a draft consumed at dispatch became.
@internal
pub type DraftTaking {
  /// A command that is not a prompt: the host empties its editor and keeps
  /// the text in its input history.
  TakenByCommand

  /// A prompt, a steer or a follow-up: the host also returns its composer
  /// to prompting. The attachments the draft carried are emptied in the
  /// session state, because they went with it.
  TakenAsPrompt
}

/// Whether a change of attachment kept the session.
@internal
pub type SessionChange {
  /// The same session, attached again.
  SameSession

  /// A different session.
  NewSession
}

// --- the operations over the shared record -----------------------------------
//
// Every function below takes and returns `Shared` alone and reads no terminal
// state, so a second host can call it with its own handle bindings. The
// terminal calls the writers through `tui_model.hold_shared`, which moves
// what they queued into the step's outbox and carries the activity mark to
// the terminal's idle timer.

/// Records a fact the host's own surfaces have to follow, after any already
/// recorded.
///
/// ## Examples
///
/// ```gleam
/// let shared = session_model.record_surface(shared, OutlookCleared)
/// ```
@internal
pub fn record_surface(
  shared: Shared(socket, recorder, source, replay_source),
  fact: SurfaceFact,
) -> Shared(socket, recorder, source, replay_source) {
  Shared(..shared, surface_facts: list.append(shared.surface_facts, [fact]))
}

/// Appends a system line to the transcript and shows it as the notice.
///
/// ## Examples
///
/// ```gleam
/// let shared = session_model.append_system(shared, "attached")
/// ```
@internal
pub fn append_system(
  shared: Shared(socket, recorder, source, replay_source),
  text: String,
) -> Shared(socket, recorder, source, replay_source) {
  Shared(
    ..shared,
    transcript: list.append(shared.transcript, [Line(System, text)]),
    record_cache_valid: False,
    notice: text,
  )
  |> invalidate_transcript
  |> invalidate_frame
}

/// Appends a failure line to the transcript and shows it as the notice.
///
/// ## Examples
///
/// ```gleam
/// let shared = session_model.append_error(shared, "network: closed")
/// ```
@internal
pub fn append_error(
  shared: Shared(socket, recorder, source, replay_source),
  text: String,
) -> Shared(socket, recorder, source, replay_source) {
  Shared(
    ..shared,
    transcript: list.append(shared.transcript, [Line(Failure, text)]),
    record_cache_valid: False,
    notice: text,
  )
  |> invalidate_transcript
  |> invalidate_frame
}

/// Appends a line that informs without alarm, in the System speaker, and
/// shows it as the notice. A build mismatch is reported this way: the attach
/// has already succeeded when it is called, and the line explains the pair
/// rather than reporting a refusal.
///
/// ## Examples
///
/// ```gleam
/// let shared = session_model.append_notice(shared, "daemon build differs")
/// ```
@internal
pub fn append_notice(
  shared: Shared(socket, recorder, source, replay_source),
  text: String,
) -> Shared(socket, recorder, source, replay_source) {
  Shared(
    ..shared,
    transcript: list.append(shared.transcript, [Line(System, text)]),
    record_cache_valid: False,
    notice: text,
  )
  |> invalidate_transcript
  |> invalidate_frame
}

/// Marks the transcript's rows stale, for a change to the data they are
/// built from.
///
/// The revision advances only beside a change to the projection's source
/// data. Keeping it apart from the terminal's ticks is what stops a long
/// session's history from costing CPU while nothing happens.
///
/// ## Examples
///
/// ```gleam
/// let shared = session_model.invalidate_transcript(shared)
/// ```
@internal
pub fn invalidate_transcript(
  shared: Shared(socket, recorder, source, replay_source),
) -> Shared(socket, recorder, source, replay_source) {
  Shared(..shared, render_revision: shared.render_revision + 1)
}

/// Marks the painted frame stale, for a change the cached frame does not
/// show.
///
/// A host compares the revision with the one its last frame was painted at
/// and repaints when they differ, so what matters is that it moved, not by
/// how much.
///
/// ## Examples
///
/// ```gleam
/// let shared = session_model.invalidate_frame(shared)
/// ```
@internal
pub fn invalidate_frame(
  shared: Shared(socket, recorder, source, replay_source),
) -> Shared(socket, recorder, source, replay_source) {
  Shared(..shared, frame_revision: shared.frame_revision + 1)
}

/// Records operator or traffic activity by bumping `activity_revision`.
///
/// The session only says that activity happened. What a host does about it
/// is its own: the terminal resets the quiet time its idle pacing reads,
/// which `tui_model.hold_shared` does when it sees the revision move.
///
/// ## Examples
///
/// ```gleam
/// let shared = session_model.mark_activity(shared)
/// ```
@internal
pub fn mark_activity(
  shared: Shared(socket, recorder, source, replay_source),
) -> Shared(socket, recorder, source, replay_source) {
  Shared(..shared, activity_revision: shared.activity_revision + 1)
}

/// Stores `channel` as the adopted lane, moving what it queued into the
/// shared outbox.
///
/// Every function that transitions the adopted lane stores the result
/// through this, so the lane's writes, closes and recording notes are
/// queued at the point they were decided. The stored lane therefore holds
/// no outputs between two calls, and replacing or dropping it can lose
/// nothing it decided.
///
/// ## Examples
///
/// ```gleam
/// let #(channel, updates) = session_channel.receive(channel, message, now:)
/// let shared = session_model.hold_channel(shared, channel)
/// ```
@internal
pub fn hold_channel(
  shared: Shared(socket, recorder, source, replay_source),
  channel: session_channel.Channel(socket, recorder),
) -> Shared(socket, recorder, source, replay_source) {
  let #(channel, outputs) = session_channel.take_outputs(channel)
  let outbox =
    list.fold(outputs, shared.outbox, fn(outbox, output) {
      [step_effect.Lane(output), ..outbox]
    })
  Shared(..shared, channel: Some(channel), outbox:)
}

/// Queues the recording line for a message that arrived while the record
/// held no lane, if the host is recording.
///
/// A message with no lane has no attempt to note it under, so it is
/// recorded as the untagged arrival the preview peer has always written.
///
/// ## Examples
///
/// ```gleam
/// let shared = session_model.record_arrival(shared, connection_event.Connected)
/// ```
@internal
pub fn record_arrival(
  shared: Shared(socket, recorder, source, replay_source),
  message: connection_event.Message,
) -> Shared(socket, recorder, source, replay_source) {
  case shared.recorder {
    Some(recorder) ->
      Shared(..shared, outbox: [
        step_effect.Recorded(recorder, message),
        ..shared.outbox
      ])
    None -> shared
  }
}

/// The active strand's pending inputs in the captured cut.
///
/// ## Examples
///
/// ```gleam
/// let rows = session_model.queue_rows(shared)
/// ```
@internal
pub fn queue_rows(
  shared: Shared(socket, recorder, source, replay_source),
) -> List(snapshot_view.PendingInput) {
  case shared.captured {
    Some(#(_, view)) ->
      option.unwrap(view.pending_inputs, [])
      |> list.filter(fn(row) { row.strand == shared.active_strand })
    None -> []
  }
}

/// The identity of the current attachment, used to reject a queue, job or
/// goal reply that arrives after the attachment changed. Empty when nothing
/// is captured.
///
/// ## Examples
///
/// ```gleam
/// let owner = session_model.queue_owner(model.shared)
/// ```
@internal
pub fn queue_owner(
  shared: Shared(socket, recorder, source, replay_source),
) -> String {
  case shared.captured {
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

/// The captured attachment's session, epoch and incarnation as a JSON
/// array, or an empty string when nothing is captured.
///
/// ## Examples
///
/// ```gleam
/// let namespace = session_model.queue_namespace(model.shared)
/// ```
@internal
pub fn queue_namespace(
  shared: Shared(socket, recorder, source, replay_source),
) -> String {
  case shared.captured {
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

/// Whether the active strand's queue waits for an explicit submission.
/// A prompt already being submitted outranks the retained idle cut.
///
/// ## Examples
///
/// ```gleam
/// let held = session_model.active_queue_halted(model.shared)
/// ```
@internal
pub fn active_queue_halted(
  shared: Shared(socket, recorder, source, replay_source),
) -> Bool {
  // A prompt in flight outranks the idle cut it was sent against. Once no
  // submission or operation is live, only captured rows establish a hold;
  // the transient Interrupt belongs to the operation that has retired.
  !active_strand_live(shared)
  && case shared.captured {
    None -> False
    Some(#(_, view)) -> snapshot_view.queue_halted(view, shared.active_strand)
  }
}

/// Reports whether the active strand is submitting or running.
///
/// ## Examples
///
/// ```gleam
/// let live = session_model.active_strand_live(model.shared)
/// ```
@internal
pub fn active_strand_live(
  shared: Shared(socket, recorder, source, replay_source),
) -> Bool {
  case active_strand_phase(shared) {
    Some(_) -> True
    None -> False
  }
}

/// The active strand's live phase, or `submitting` while its prompt is on
/// the way.
///
/// ## Examples
///
/// ```gleam
/// let phase = session_model.active_strand_phase(model.shared)
/// ```
@internal
pub fn active_strand_phase(
  shared: Shared(socket, recorder, source, replay_source),
) -> Option(String) {
  case shared.submitting {
    Some(strand) if strand == shared.active_strand -> Some("submitting")
    _ ->
      shared.strands
      |> list.find_map(fn(strand) {
        let protocol.Strand(id:, live_phase:, ..) = strand
        case id == shared.active_strand, live_phase {
          True, Some(phase) -> Ok(phase)
          _, _ -> Error(Nil)
        }
      })
      |> result.map(Some)
      |> result.unwrap(None)
  }
}

/// The active strand, if an interrupt for it is outstanding.
///
/// ## Examples
///
/// ```gleam
/// let held = session_model.active_interrupt(model.shared)
/// ```
@internal
pub fn active_interrupt(
  shared: Shared(socket, recorder, source, replay_source),
) -> Option(String) {
  case shared.interrupt {
    Some(Interrupt(strand:, ..)) ->
      case strand == shared.active_strand {
        True -> Some(strand)
        False -> None
      }
    None -> None
  }
}

/// Whether one named strand has work in flight. Unlike `active_strand_phase`
/// this asks about a strand the operator may not be looking at, and it counts
/// a local submission the server has not yet reported a phase for.
///
/// ## Examples
///
/// ```gleam
/// let busy = session_model.strand_running(model.shared, "main")
/// ```
@internal
pub fn strand_running(
  shared: Shared(socket, recorder, source, replay_source),
  target: String,
) -> Bool {
  shared.submitting == Some(target)
  || list.any(shared.strands, fn(strand) {
    let protocol.Strand(id:, live_phase:, ..) = strand
    id == target && live_phase != None
  })
}

/// Reports whether `name` is one of the listed strands.
///
/// ## Examples
///
/// ```gleam
/// let known = session_model.is_known_strand(model.shared.strands, "main")
/// ```
@internal
pub fn is_known_strand(strands: List(protocol.Strand), name: String) -> Bool {
  list.any(strands, fn(strand) {
    let protocol.Strand(id:, ..) = strand
    id == name
  })
}

/// What the transcript's line builders read of the shared record.
///
/// The builders take this record rather than a host's model, so that they
/// need nothing of any host; this is the one place that knows which fields
/// they read.
///
/// ## Examples
///
/// ```gleam
/// // transcript_lines.display_streams(session_model.presentation(model.shared))
/// ```
pub fn presentation(
  shared: Shared(socket, recorder, source, replay_source),
) -> transcript_lines.Presentation {
  transcript_lines.Presentation(
    active_strand: shared.active_strand,
    extent: transcript_lines.details_extent(shared.details_expanded),
    captured: shared.captured,
    records: shared.records,
    streams: shared.streams,
    tool_tails: shared.tool_tails,
    queued: shared.queued,
    awaiting_outcome: shared.awaiting_outcome,
    cache_notices: shared.cache_notices,
    summaries: shared.summaries,
    compact_entry_cache: shared.compact_entry_cache,
    compact_call_cache: shared.compact_call_cache,
    worktree: shared.worktree,
    clock: shared.clock_offset,
  )
}
