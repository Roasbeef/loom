//// The shared step's own units: what every event does to the session state
//// after its handler has run, and what every tick does to it.
////
//// Three surfaces decide whether an event made their data stale by
//// comparing the session state before the event with the state after it:
//// the context panel (`surfaces.sync_context`), the advisor's pending
//// nudges (`surfaces.sync_advisor_nudges`) and the session goal
//// (`surfaces.sync_goal`). Each reads and writes the shared record alone,
//// so the three together are the settle a second host's step runs after
//// every event, as the terminal's `settle_update` does
//// (`docs/design-notes/step-extraction.md`, section 3, the seventh cut).
////
//// A tick has two session units besides the lane's. The side surfaces'
//// reads (`service_reads`) send whichever waiting read the lane's one
//// command slot allows, in a fixed order, and the clocks
//// (`advance_activity_clocks`) move the elapsed readings a host shows to
//// the stamp. The terminal's tick calls each at its place in its own chain
//// of drains (`tui/tick`); both read and write the shared record alone, so a
//// second host's tick runs the same ones.
////
//// `update` is the entry point for a host with no surfaces of its own, the
//// web view: one call for a whole event. `focus` is its other one, the change
//// of strand, which is not an event of the lane's and so not a message. It composes the units above with
//// the lane's, in the order the terminal's tick runs them, and it drops the
//// facts such a host has no surface for. The terminal does not call it. Its
//// tick applies its own surfaces' facts between the drain's updates and
//// places its own drains among the shared ones, so it keeps calling the
//// units, and a test holds `update` to that order
//// (`docs/design-notes/step-extraction.md`, question 12).

import core/message
import gleam/bool
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/set
import session_view/admission
import session_view/advisor_history
import session_view/agent_roster
import session_view/attempt
import session_view/attempt_replay
import session_view/block_summary
import session_view/cache_watch
import session_view/commands
import session_view/completion_summary
import session_view/connection_event
import session_view/context_view
import session_view/history_view
import session_view/inbox.{type Inbox}
import session_view/lane_fold
import session_view/model.{type Shared, Shared} as session_model
import session_view/msg
import session_view/operator
import session_view/queue_request
import session_view/session_channel
import session_view/shared_set
import session_view/step_effect
import session_view/surfaces
import session_view/worktree_view

/// Runs the shared edges for one event, from `before` to `after`: the
/// context read, the pending-nudge read or clear, and the goal read, in that
/// order.
///
/// Each edge compares `before` with the state the previous edge left, and
/// none of them writes what a later one compares, so the order is the one
/// the terminal has always run them in rather than one they depend on. The
/// three calls go to another module and apply to the parameter `after`,
/// which keeps them out of the Erlang inliner's reach in the terminal's
/// settle chain (the comment above `apply_input` in `tui.gleam`).
///
/// ## Examples
///
/// ```gleam
/// let shared = session_step.settle(before.shared, after.shared)
/// ```
@internal
pub fn settle(
  before: Shared(socket, recorder, source, replay_source),
  after: Shared(socket, recorder, source, replay_source),
) -> Shared(socket, recorder, source, replay_source) {
  surfaces.sync_context(before, after)
  |> surfaces.sync_advisor_nudges(before, _)
  |> surfaces.sync_goal(before, _)
}

/// Sends whichever of the side surfaces' waiting reads the lane allows, in
/// the order the tick has always serviced them: the queue, the worktree,
/// the notes, the todo seed, the live jobs, the context, the advisor's
/// pending nudges and the goal.
///
/// The reads share the lane's one command slot, so the order decides which
/// waiting read is sent first. Each reads and writes the shared record
/// alone, so the eight run as one chain and a host stores the result once.
///
/// ## Examples
///
/// ```gleam
/// let shared = session_step.service_reads(model.shared)
/// ```
@internal
pub fn service_reads(
  shared: Shared(socket, recorder, source, replay_source),
) -> Shared(socket, recorder, source, replay_source) {
  shared
  |> surfaces.service_queue_read
  |> surfaces.service_worktree_read
  |> surfaces.service_notes_read
  |> surfaces.service_todo_seed
  |> surfaces.service_jobs_read
  |> surfaces.service_context_read
  |> surfaces.service_advisor_nudges_read
  |> surfaces.service_goal_read
}

/// Advances the active strand's activity clock and the generation clock to
/// the stamp.
///
/// The tick is the one place the elapsed counts move, so rendering stays a
/// pure function of the record. The time is the event's stamp. Going idle
/// clears the start, so the next activity counts from zero rather than from
/// wherever the last one stopped. The frame is marked stale when the count a
/// host shows has moved; the terminal's glyph is advanced by its own half,
/// after this call.
///
/// ## Examples
///
/// ```gleam
/// let shared = session_step.advance_activity_clocks(model.shared)
/// ```
@internal
pub fn advance_activity_clocks(
  shared: Shared(socket, recorder, source, replay_source),
) -> Shared(socket, recorder, source, replay_source) {
  let shared = advance_generation_clock(shared)
  case session_model.active_strand_live(shared) {
    False ->
      shared
      |> shared_set.activity_started_ms(None)
      |> shared_set.activity_elapsed_s(0)
    True -> {
      let now = shared.stamp.now_ms
      let started = option.unwrap(shared.activity_started_ms, now)
      let activity_elapsed_s = { now - started } / 1000
      let advanced =
        shared
        |> shared_set.activity_started_ms(Some(started))
        |> shared_set.activity_elapsed_s(activity_elapsed_s)
      case activity_elapsed_s == shared.activity_elapsed_s {
        True -> advanced
        False -> session_model.invalidate_frame(advanced)
      }
    }
  }
}

// A live reasoning row shows how long the generation has run, read from the
// generation clock the event fold starts and stops and the event's stamp, so
// the step reads no clock of its own. The reading moves once a second, and
// only a change repaints; the repaint rebuilds the transient rows and reuses
// every durable one, because the record cache's inputs have not moved. A
// generation with no reasoning row on screen is read but not repainted,
// since nothing drawn depends on the figure.
fn advance_generation_clock(
  shared: Shared(socket, recorder, source, replay_source),
) -> Shared(socket, recorder, source, replay_source) {
  let elapsed = case shared.generation_started_ms {
    None -> 0
    Some(started) -> int.max({ shared.stamp.now_ms - started } / 1000, 0)
  }
  use <- bool.guard(
    when: elapsed == shared.generation_elapsed_s,
    return: shared,
  )

  let advanced = Shared(..shared, generation_elapsed_s: elapsed)
  let reasoning_shown =
    !shared.details_expanded
    && list.any(shared.streams, fn(stream) {
      stream.strand == shared.active_strand && stream.kind == "thinking"
    })
  case reasoning_shown {
    False -> advanced
    True ->
      advanced
      |> session_model.invalidate_transcript
      |> session_model.invalidate_frame
  }
}

/// A session record for a host with no surfaces of its own, before any lane
/// is adopted.
///
/// Nothing is attached: the peer is `Disconnected`, there is no lane and no
/// recorder, and every board and cache is empty. The host adopts a lane
/// with `session_model.hold_channel` and sets `peer` to `Attached`, since
/// what a lane's socket is belongs to the host. The terminal builds its own
/// record, with a demonstration transcript and catalogue that a real host
/// has no use for.
///
/// `strand` is the strand the host's composer addresses, and `session` the
/// session it shows.
///
/// ## Examples
///
/// ```gleam
/// let shared =
///   step.new("main", "session-1", msg.Stamp(0, 0), inbox.new(Nil), inbox.new(Nil))
/// ```
@internal
pub fn new(
  strand: String,
  session: String,
  at: msg.Stamp,
  inbox: Inbox(source, connection_event.Message),
  replay_inbox: Inbox(replay_source, attempt.Event),
) -> Shared(socket, recorder, source, replay_source) {
  Shared(
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
    transcript: [],
    records: [],
    cache: cache_watch.new(),
    cache_notices: [],
    scrollback: history_view.empty(),
    notice: "",
    answer: "",
    worktree: worktree_view.new(),
    context: context_view.new(),
    completion: completion_summary.new(),
    completion_owner: "",
    jobs: None,
    jobs_observed_ms: None,
    jobs_refresh: worktree_view.Settled,
    jobs_awaiting: None,
    jobs_request: None,
    jobs_notice: "",
    nudges: None,
    nudges_refresh: worktree_view.Settled,
    nudges_awaiting: None,
    nudges_request: None,
    summaries: block_summary.new(),
    goal: None,
    goal_refresh: worktree_view.Settled,
    goal_awaiting: None,
    goal_request: None,
    goal_report: session_model.HoldGoalReport,
    goal_observations: [],
    note_board: None,
    notes_requested: None,
    queue_request: queue_request.new(),
    queue_notices: [],
    surface_facts: [],
    models: [],
    skills: [],
    current_model: "",
    strands: [],
    reviewer_rows: [],
    agent_rows: [],
    roster: agent_roster.new(),
    agent_messages: [],
    advisor_history: advisor_history.Board(items: [], unloaded: None),
    todo_boards: dict.new(),
    todo_seed: None,
    todo_asked: set.new(),
    active_strand: strand,
    session:,
    session_label: None,
    inbox:,
    peer: session_model.Disconnected,
    ended: None,
    channel: None,
    captured: None,
    last_capture: session_channel.Requested,
    notices: 0,
    approvals: [],
    unconfirmed: None,
    replay_state: attempt_replay.new(),
    replay_inbox:,
    replay_error: None,
    next_id: 1,
    usage: message.Usage(
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
    ),
    generation_started_ms: None,
    output_rate_tps: None,
    details_expanded: False,
    activity_started_ms: None,
    activity_elapsed_s: 0,
    generation_elapsed_s: 0,
    streams: [],
    tool_tails: [],
    render_revision: 0,
    compact_call_cache: dict.new(),
    compact_entry_cache: dict.new(),
    pending_records: [],
    record_cache_valid: False,
    frame_revision: 0,
    stamp: at,
    build_notice: [],
    activity_revision: 0,
    connection_backlog: session_model.MailboxDrained,
    recorder: None,
    record_cache_epoch: 0,
    outbox: [],
  )
}

/// Reduces one message for a host with no surfaces of its own, and returns
/// the effects it decided, oldest first.
///
/// An `Arrived` files the traffic into the record's buffers and reduces
/// nothing, as the terminal's admission does. An `Input` stores its stamp
/// and then reduces one event.
///
/// A `Ticked` runs the units the terminal's tick runs, in its order and with
/// its surfaces left out: the activity and generation clocks, the agent
/// roster's clock, the drain of every held frame, the side surfaces' reads,
/// and the lane's own tick with the history read it may owe. Each update the
/// drain and the tick produce is applied on its own, with
/// `lane_fold.nothing_shown`, because a host with no diff, notes surface or
/// approval inspector shows none of the three. The settle then compares the
/// record with the one the event started from, as `session_step.settle` does
/// after each of the terminal's events, and the facts such a host has no
/// surface for are dropped (`forget_surfaces`). A prompt the daemon handed
/// back stays in `Shared.returned_drafts` for the host to take.
///
/// What the terminal alone does in its tick is absent: the recorded replay,
/// its daemon-control drains, the activity poll and the footer's cache label.
/// The read of summary labels (`surfaces.service_block_summaries`) runs
/// between the side surfaces' reads and the lane's tick, where the terminal
/// sends it. The daemon may run a summarizer for a label it is asked for, so
/// the read is sent only for blocks the host has marked wanted
/// (`block_summary.want`), and the web view marks the reasoning blocks it
/// draws.
///
/// An `Acted` runs the command (`commands.act`) and settles, and leaves the
/// facts the command recorded on the record. The host that acted knows which
/// of its controls the command consumed, and reads `DraftTaken` for the
/// composer; it then calls `forget_surfaces`.
///
/// A tick with no adopted lane drains nothing, and the frames it would have
/// taken stay held. A host that files traffic before it adopts a lane should
/// not tick until it has one, because the terminal's tick reads a frame that
/// arrives with no lane as the preview peer's traffic.
///
/// The step reads no clock and performs no effect. The lane's writes and
/// closes come back for the host to perform, in the order the step decided
/// them.
///
/// ## Examples
///
/// ```gleam
/// let #(shared, effects) =
///   step.update(shared, msg.Input(msg.Stamp(now, now), msg.Ticked))
/// ```
@internal
pub fn update(
  shared: Shared(socket, recorder, source, replay_source),
  message: msg.Msg(source),
) -> #(
  Shared(socket, recorder, source, replay_source),
  List(step_effect.Effect(socket, recorder)),
) {
  let reduced = case message {
    msg.Arrived(arrivals:) -> list.fold(arrivals, shared, file)
    msg.Input(at:, event: msg.Ticked) -> tick(shared_set.stamp(shared, at))
    msg.Input(at:, event: msg.Acted(command:)) -> {
      let started = shared_set.stamp(shared, at)
      settle(started, commands.act(started, command))
    }
  }
  #(shared_set.outbox(reduced, []), list.reverse(reduced.outbox))
}

/// Makes `strand` the active strand for a host with no surfaces of its own,
/// and returns the effects it decided, oldest first.
///
/// This is the terminal's change of strand (`tui/submit.switch_active_strand`)
/// with the terminal's parts left out. The session's half is three units, run
/// in the terminal's order: the lane's unsent frames are cancelled, so none of
/// them can reach the new target (`lane_fold.cancel_unsent`, each update it
/// produces applied on its own), the record moves to the strand
/// (`commands.focus`), and the captured cut is shown for it, or its
/// configuration is asked for when nothing is captured
/// (`commands.load_strand`). The settle then compares the record with the one
/// the change started from, so the context read, the pending-nudge read and
/// the goal read follow the strand as they follow an event, and the facts such
/// a host has no surface for are dropped (`forget_surfaces`).
///
/// The strand must be one the session lists, and it must not be the active
/// one; a host checks both before it calls, because a refusal is worded for
/// its own surface. A change to the strand already shown would cancel the
/// lane's unsent frames for a target that did not change.
///
/// The change is a page-side focus and nothing else: it sends no command, and
/// the frames it may queue are reads (a strand's configuration), which the
/// gateway admits from an observer's attachment.
///
/// ## Examples
///
/// ```gleam
/// let #(shared, effects) = step.focus(shared, "advisor", msg.Stamp(now, now))
/// ```
@internal
pub fn focus(
  shared: Shared(socket, recorder, source, replay_source),
  strand: String,
  at: msg.Stamp,
) -> #(
  Shared(socket, recorder, source, replay_source),
  List(step_effect.Effect(socket, recorder)),
) {
  let started = shared_set.stamp(shared, at)
  let #(cancelled, updates) =
    lane_fold.cancel_unsent(started, "target change from " <> shared.session)
  let focused =
    list.fold(updates, cancelled, apply_update)
    |> commands.focus(strand)
    |> commands.load_strand(strand, lane_fold.nothing_shown())
  let reduced = settle(started, focused) |> forget_surfaces
  #(shared_set.outbox(reduced, []), list.reverse(reduced.outbox))
}

/// Drops what the record's reducers noted for surfaces a host does not have:
/// the surface facts, the queue editor's notices and the goal board's
/// observations.
///
/// The record accumulates these until a host applies them and empties the
/// lists, and a host with no surface for them would otherwise grow them for
/// the life of the session. The held prompts the daemon handed back are not
/// dropped. A returned prompt is the prompt's last copy, so losing it is a
/// loss whichever host it is, and a host that has somewhere to put it (the
/// web view keeps it for the composer's element, since question 12 of
/// `docs/design-notes/step-extraction.md` was reopened) takes it out of
/// `Shared.returned_drafts` and empties the list, as the terminal does. A host
/// with nowhere to put one must empty the list itself.
///
/// ## Examples
///
/// ```gleam
/// let shared = step.forget_surfaces(shared)
/// ```
@internal
pub fn forget_surfaces(
  shared: Shared(socket, recorder, source, replay_source),
) -> Shared(socket, recorder, source, replay_source) {
  shared
  |> shared_set.surface_facts([])
  |> shared_set.queue_notices([])
  |> shared_set.goal_observations([])
}

// Files one arrival into the buffer that waits for it. A frame from a source
// the record no longer reads came from a socket that was replaced, and a
// host with no waiting attempt to offer it to drops it.
fn file(
  shared: Shared(socket, recorder, source, replay_source),
  arrival: msg.Arrival(source),
) -> Shared(socket, recorder, source, replay_source) {
  case arrival {
    msg.Frame(source:, message:) ->
      case admission.file_frame(shared, source, message) {
        Ok(filed) -> filed
        Error(Nil) -> shared
      }
    msg.Replayed(event:) -> admission.file_replayed(shared, event)
  }
}

// The terminal's tick, less its surfaces, over the record the event started
// from. The units are applied to `shared`, a parameter, as `settle_tick` does
// for the terminal, and the settle compares against `started`.
fn tick(
  started: Shared(socket, recorder, source, replay_source),
) -> Shared(socket, recorder, source, replay_source) {
  let after =
    started
    |> advance_activity_clocks
    |> advance_roster
    |> drain_connection
    |> service_reads
    |> surfaces.service_block_summaries
    |> tick_lane
  settle(started, after) |> forget_surfaces
}

// The roster's clock moves with the stamp, and the frame is stale when a
// second a strip draws changed. The terminal advances it only while its
// strip is drawn; a host that always has one advances it on every tick.
fn advance_roster(
  shared: Shared(socket, recorder, source, replay_source),
) -> Shared(socket, recorder, source, replay_source) {
  let #(roster, repaint) = agent_roster.tick(shared.roster, shared.stamp.now_ms)
  let advanced = shared_set.roster(shared, roster)
  case repaint {
    agent_roster.Changed -> session_model.invalidate_frame(advanced)
    agent_roster.Unchanged -> advanced
  }
}

// Every held frame goes to the adopted lane, oldest first, through the
// engine's drain, and each update the lane produces is applied before the
// next frame is taken, so a frame sees everything an earlier one did.
fn drain_connection(
  shared: Shared(socket, recorder, source, replay_source),
) -> Shared(socket, recorder, source, replay_source) {
  case shared.channel {
    None -> shared
    Some(_) ->
      operator.drain(
        shared,
        inbox.held(shared.inbox),
        take_frame,
        receive_frame,
      )
  }
}

fn take_frame(
  shared: Shared(socket, recorder, source, replay_source),
) -> #(
  Shared(socket, recorder, source, replay_source),
  Result(connection_event.Message, Nil),
) {
  let #(taken, next) = inbox.take(shared.inbox)
  #(shared_set.inbox(shared, taken), next)
}

fn receive_frame(
  shared: Shared(socket, recorder, source, replay_source),
  incoming: connection_event.Message,
) -> Shared(socket, recorder, source, replay_source) {
  case shared.channel {
    Some(channel) -> {
      let #(shared, updates) = lane_fold.receive(shared, channel, incoming)
      list.fold(updates, shared, apply_update)
    }
    None -> lane_fold.receive_unlaned(shared, incoming)
  }
}

// One lane update, applied on its own. The three things a decision inside an
// update reads of the host's surfaces are all absent.
fn apply_update(
  shared: Shared(socket, recorder, source, replay_source),
  update: session_channel.Update,
) -> Shared(socket, recorder, source, replay_source) {
  lane_fold.apply_channel_update(shared, update, lane_fold.nothing_shown())
}

// The lane's own tick, where its idle refresh and deadlines are checked,
// followed by the history read the reduction may have left owed.
fn tick_lane(
  shared: Shared(socket, recorder, source, replay_source),
) -> Shared(socket, recorder, source, replay_source) {
  case shared.channel {
    None -> shared
    Some(_) -> {
      let #(ticked, updates) = lane_fold.tick(shared)
      list.fold(updates, ticked, apply_update)
      |> lane_fold.service_history
    }
  }
}
