//// Reads and replies for the side surfaces: notes, the held-input queue,
//// the worktree diff, live jobs, context, the advisor's pending nudges and
//// the session goal.
////
//// Each surface asks the daemon for its data through a read that shares
//// the session channel's command slot, and some share one server worker
//// slot. A surface therefore records that it wants a read, and the
//// matching `service_*_read` sends it only when the channel is ready and
//// no other read holds the worker. The tick calls every service after
//// draining the socket, and a key that opens a surface calls its service
//// directly.
////
//// Replies are checked against the attachment that asked (`queue_owner`)
//// before they are applied, so a board that arrives after a session or
//// strand switch is dropped rather than shown against the wrong target.
//// The `sync_*` functions compare the session state before and after an
//// event and decide whether that event makes a surface's data stale; the
//// three together are the shared step's settle (`session_view/step`).
////
//// The reads (`service_*`), the receivers (`receive_jobs`,
//// `receive_goal`, `receive_advisor_nudges`, `retire_delivered_nudges`,
//// `retire_nudges_delivered_since_board` and `refuse_goal`), the `sync_*` edges and the goal commands
//// (`submit_goal_action`, `confirming`) take and return the shared record
//// alone
//// (`session_view/model`), so a second host of the session can run them with
//// its own handle bindings. The surfaces they feed are the terminal's, and
//// what a read or a reply means for them is recorded rather than written: a
//// dropped queued-input read appends a `queue_request.Dropped` notice, and a
//// goal board or a failed goal read appends a `GoalObservation`. The
//// terminal stores each result through `tui_model.hold_shared` or
//// `tui_model.run_shared`, which shows those at the point of the call. The
//// live-jobs cursor is the one surface write that depends on the terminal's
//// own state, the job selected before the board changed, so the terminal
//// moves it itself after `receive_jobs` (`inbound`'s `receive_jobs`). The
//// functions that open a surface, move its cursor or decide a surface's
//// target read the terminal's state, take the whole model, and live in the
//// terminal (`tui/side_surfaces`).
////
//// ## Flow
////
//// `sync_context` → `service_context_read` → `receive_jobs` → `receive_goal` → `refuse_goal`
////
//// Each surface follows one cycle, and the module repeats it per surface:
//// want, service, receive, refuse.
////
//// 1. A host or a `sync_*` edge records that a surface wants data, or one is
////    opened. `sync_context`, `sync_goal` and `sync_advisor_nudges` compare the
////    state before and after an event and mark a surface stale; `context_refresh_due`
////    decides whether the context is worth another read.
//// 2. The tick calls each `service_*_read` after draining the socket:
////    `service_notes_read`, `service_queue_read`, `service_worktree_read`,
////    `service_jobs_read`, `service_context_read` and `service_goal_read`. Each
////    sends its frame only when the channel is ready and no other read holds the
////    worker slot.
//// 3. A read that can no longer go out is dropped with a notice
////    (`drop_queue_read`, `unreachable_goal`) rather than left standing.
//// 4. A reply is checked against the attachment that asked, then taken by its
////    receiver: `receive_jobs`, `receive_goal` through `report_goal`, and
////    `receive_advisor_nudges`. A reply for an older attachment is dropped.
//// 5. `refuse_goal` and `retire_delivered_nudges` close the cycle when a read
////    fails or a committed entry delivers what a nudge announced.
//// 6. `goal_action`, `submit_goal_action` and `confirming` are the commands the
////    goal panel sends, over the same shared record.
////
//// For goal observations, `goal_action` and `sync_goal` mark an edge read due.
//// `service_goal_read` waits for the lane; `unreachable_goal` reports no lane.
//// `confirming` arms a mutation report before `submit_goal_action` sends it.
//// `receive_goal` checks attachment ownership, then `owns_goal_report` before
//// `report_goal` prints anything. `refuse_goal` checks the issued request ID.
//// Both accepted replies record observations for a host to apply in order.
//// Lane-owned goal invalidation reads use the same reply and refusal reducers.

import core/entry
import gleam/bool
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import session_view/advisor_pending
import session_view/block_summary
import session_view/command
import session_view/context_view
import session_view/goal_view
import session_view/live_jobs
import session_view/model.{
  type Shared, Attached, ConfirmGoal, Disconnected, GoalObserved,
  GoalUnavailable, HoldGoalReport, OverlaySubmission, Preview, Replaying,
  ReportGoal, Shared,
} as session_model
import session_view/outbound
import session_view/protocol
import session_view/queue_request
import session_view/remembered
import session_view/session_channel
import session_view/shared_set
import session_view/transcript_lines
import session_view/worktree_view

/// What one model transition asks of the pending-nudge panel.
///
/// Named rather than answered with a pair of booleans, because the three
/// cases are genuinely different events and a caller reading `False, True`
/// would have to remember which question each half asked.
pub type NudgeAction {
  /// The primary is running. Anything the panel holds is no longer a
  /// pending queue, because a run start drains it into that run.
  DropNudges

  /// The primary is idle at a boundary worth exactly one observation.
  ReadNudges

  /// Nothing the panel depends on moved.
  HoldNudges
}

/// What one model transition asks of the goal panel.
pub type GoalAction {
  /// The goal may have moved; one read is worth its round trip.
  ReadGoal

  /// Nothing the panel depends on moved.
  HoldGoal
}

/// Sends the pending todo seed as an ordinary `notes` read once the read
/// lane is free. An operator's own notes read goes first, and its reply
/// seeds the board just the same when it is for the same strand.
///
/// Over the shared record alone; the terminal's tick runs it through
/// `tui_model.run_shared`.
///
/// ## Examples
///
/// ```gleam
/// surfaces.service_todo_seed(model.shared)
/// ```
@internal
pub fn service_todo_seed(
  shared: Shared(socket, recorder, source, replay_source),
) -> Shared(socket, recorder, source, replay_source) {
  case shared.todo_seed {
    None -> shared
    Some(strand) ->
      case dict.has_key(shared.todo_boards, strand) {
        // Another read or a fresh result already brought the board, so the
        // seed has nothing left to find.
        True -> shared_set.todo_seed(shared, None)
        False -> send_seed_when_free(shared, strand)
      }
  }
}

// An operator's own notes read goes first, and a seed with no attached
// channel waits; session replacement clears it either way.
fn send_seed_when_free(
  shared: Shared(socket, recorder, source, replay_source),
  strand: String,
) -> Shared(socket, recorder, source, replay_source) {
  case shared.notes_requested, shared.channel, shared.peer {
    None, Some(channel), Attached ->
      case session_channel.ready_for_read(channel) {
        True -> send_todo_seed(shared, strand)
        False -> shared
      }
    Some(_), _, _ | None, None, _ | None, Some(_), _ -> shared
  }
}

fn send_todo_seed(
  shared: Shared(socket, recorder, source, replay_source),
  strand: String,
) -> Shared(socket, recorder, source, replay_source) {
  outbound.send_frame(
    shared_set.todo_seed(shared, None),
    protocol.notes(shared.next_id, strand),
  )
}

/// Reads coalesce to the latest inspected target while the existing channel
/// owns an earlier command. Old replies may be retained, but never relabelled.
///
/// Over the shared record alone; a terminal caller stores the result through
/// `tui_model.run_shared`.
///
/// ## Examples
///
/// ```gleam
/// surfaces.service_notes_read(model.shared)
/// ```
@internal
pub fn service_notes_read(
  shared: Shared(socket, recorder, source, replay_source),
) -> Shared(socket, recorder, source, replay_source) {
  case shared.notes_requested, shared.channel {
    None, _ -> shared
    Some(target), Some(channel) -> {
      case session_channel.ready_for_read(channel) {
        False -> shared
        True ->
          outbound.send_frame(
            shared_set.notes_requested(shared, None),
            protocol.notes(shared.next_id, target),
          )
      }
    }
    Some(target), None ->
      outbound.send_frame(
        shared_set.notes_requested(shared, None),
        protocol.notes(shared.next_id, target),
      )
  }
}

/// Sends a requested queued-input read once the channel is ready for it,
/// or drops the request when the attachment changed since it was made.
///
/// Over the shared record alone. A dropped read cannot write the terminal's
/// queue editor, so it appends a `queue_request.Dropped` notice, which
/// `tui_model.hold_shared` shows in the editor at the point of the call.
///
/// ## Examples
///
/// ```gleam
/// surfaces.service_queue_read(model.shared)
/// ```
@internal
pub fn service_queue_read(
  shared: Shared(socket, recorder, source, replay_source),
) -> Shared(socket, recorder, source, replay_source) {
  case shared.channel, shared.queue_request.fetch {
    Some(channel), Some(fetch) ->
      case session_channel.ready_for_read(channel) {
        True ->
          case session_model.queue_owner(shared) == fetch.owner {
            True ->
              outbound.send_frame(
                shared_set.queue_request(
                  shared,
                  queue_request.State(
                    ..shared.queue_request,
                    fetch: None,
                    awaiting: Some(fetch),
                  ),
                ),
                protocol.queued_input(shared.next_id, fetch.strand, fetch.id),
              )
            False ->
              drop_queue_read(
                shared,
                "Attachment changed; select the input again",
              )
          }
        False -> shared
      }
    None, Some(_) ->
      drop_queue_read(
        shared,
        "Queue editing requires a live conversation attachment",
      )
    _, None -> shared
  }
}

// A wanted read that can no longer be sent is forgotten, and the editor that
// wanted it is told why.
fn drop_queue_read(
  shared: Shared(socket, recorder, source, replay_source),
  message: String,
) -> Shared(socket, recorder, source, replay_source) {
  shared
  |> shared_set.queue_request(
    queue_request.State(..shared.queue_request, fetch: None),
  )
  |> shared_set.queue_notices(
    list.append(shared.queue_notices, [
      queue_request.Dropped(message),
    ]),
  )
}

/// Sends a requested worktree diff once the channel is ready and no
/// context read holds the shared worker slot.
///
/// Over the shared record alone; a terminal caller stores the result through
/// `tui_model.run_shared`.
///
/// ## Examples
///
/// ```gleam
/// surfaces.service_worktree_read(model.shared)
/// ```
@internal
pub fn service_worktree_read(
  shared: Shared(socket, recorder, source, replay_source),
) -> Shared(socket, recorder, source, replay_source) {
  // Both observations borrow the same server worker slot. An acknowledged
  // context read still owns it until its final push arrives.
  use <- bool.guard(context_in_flight(shared.context), shared)
  case shared.channel, shared.worktree.refresh, shared.worktree.awaiting {
    Some(channel), worktree_view.Requested, None ->
      case session_channel.ready_for_read(channel) {
        True ->
          outbound.send_frame(shared, protocol.worktree_diff(shared.next_id))
        False -> shared
      }
    _, _, _ -> shared
  }
}

/// Sends a requested live-jobs read once the channel is ready for it.
///
/// Over the shared record alone; a terminal caller stores the result through
/// `tui_model.run_shared`.
///
/// ## Examples
///
/// ```gleam
/// surfaces.service_jobs_read(model.shared)
/// ```
@internal
pub fn service_jobs_read(
  shared: Shared(socket, recorder, source, replay_source),
) -> Shared(socket, recorder, source, replay_source) {
  case shared.channel, shared.jobs_refresh, shared.peer {
    Some(channel), worktree_view.Requested, Attached ->
      case session_channel.ready_for_read(channel) {
        True ->
          outbound.send_frame(
            shared
              |> shared_set.jobs_refresh(worktree_view.Settled)
              |> shared_set.jobs_awaiting(
                Some(#(session_model.queue_owner(shared), shared.active_strand)),
              )
              |> shared_set.jobs_notice(
                "Refreshing live jobs; previous observation may be stale",
              ),
            protocol.live_jobs(shared.next_id, shared.active_strand),
          )
        False -> shared
      }
    _, worktree_view.Requested, _ ->
      shared
      |> shared_set.jobs_refresh(worktree_view.Settled)
      |> shared_set.jobs_notice(
        "Live jobs unavailable without a live conversation attachment",
      )
    _, worktree_view.Settled, _ -> shared
  }
}

/// Sends a requested read of what the session remembers once the channel is
/// ready for it.
///
/// Over the shared record alone. Only a host that asked for the read sets
/// `remembered_refresh`, and the read is the operator's: the gateway refuses
/// it to an observer (protocol-change/073), so a host asks only where it may
/// approve. A read that cannot be sent now stays requested for the next tick.
///
/// ## Examples
///
/// ```gleam
/// surfaces.service_remembered_read(model.shared)
/// ```
@internal
pub fn service_remembered_read(
  shared: Shared(socket, recorder, source, replay_source),
) -> Shared(socket, recorder, source, replay_source) {
  case shared.channel, shared.remembered_refresh, shared.peer {
    Some(channel), worktree_view.Requested, Attached ->
      case session_channel.ready_for_read(channel) {
        True ->
          outbound.send_frame(
            shared_set.remembered_refresh(shared, worktree_view.Settled),
            protocol.permissions(shared.next_id),
          )
        False -> shared
      }
    _, worktree_view.Requested, _ | _, worktree_view.Settled, _ -> shared
  }
}

/// Forgets remembered permissions, as the host listed them.
///
/// Forgetting needs what an approval needs: a live attachment that may
/// mutate. The request echoes the sequence the host's list carried, so the
/// daemon refuses it when the list has moved, and a refusal asks the host to
/// read again (`lane_fold.refuse`).
///
/// ## Examples
///
/// ```gleam
/// let shared = surfaces.forget_remembered(shared, remembered.ForgetEverything(None))
/// ```
@internal
pub fn forget_remembered(
  shared: Shared(socket, recorder, source, replay_source),
  forget: remembered.Forget,
) -> Shared(socket, recorder, source, replay_source) {
  case outbound.mutation_refusal(shared, command.Approve("")) {
    Some(reason) -> session_model.append_error(shared, reason)
    None ->
      outbound.send_frame(
        shared,
        protocol.permission_forget(shared.next_id, forget),
      )
  }
}

// --- the advisor's pending nudges -------------------------------------------

/// Whether this transition is worth a pending-nudge read, a clear, or
/// neither.
///
/// Three edges are worth a read and no others: the primary's own operation
/// settling, a review settling while the primary waits — which is where a
/// nudge is queued in the first place — and the primary appearing in the
/// roster at all, which is the first snapshot after an attachment or a
/// session switch. Everything else holds, a phase change on an unrelated
/// strand included, because the queue cannot have grown without the advisor
/// finishing a review.
///
/// Whether there is an attachment to ask is deliberately not asked here.
/// `service_advisor_nudges_read` refuses to send without one and a closed
/// conversation clears the board outright, so this function answers only
/// about the conversation's own edges.
///
/// ## Examples
///
/// ```gleam
/// surfaces.advisor_nudges_action(before.shared, after.shared)
/// ```
@internal
pub fn advisor_nudges_action(
  before: Shared(socket, recorder, source, replay_source),
  after: Shared(socket, recorder, source, replay_source),
) -> NudgeAction {
  let primary_started =
    !session_model.strand_running(before, advisor_pending.primary_strand)
    && session_model.strand_running(after, advisor_pending.primary_strand)
  let review_settled =
    session_model.strand_running(before, advisor_pending.advisor_strand)
    && !session_model.strand_running(after, advisor_pending.advisor_strand)
  case review_settled, primary_started {
    // When both edges share one snapshot, the new review may have queued
    // advice after the primary drained its older queue. Read the current
    // board instead of losing that edge behind the run start.
    True, _ -> ReadNudges

    // A new run drains the old queue. An already-running primary can still
    // receive a new nudge when the advisor settles, so its running phase
    // alone must not erase or suppress that observation.
    False, True -> DropNudges

    False, False -> nudge_boundary(before, after)
  }
}

/// Applies `advisor_nudges_action` for the step from `before` to `after`.
///
/// Over the shared record alone; it is one of the three edges
/// `session_step.settle` runs after every event.
///
/// ## Examples
///
/// ```gleam
/// let shared = surfaces.sync_advisor_nudges(before.shared, after.shared)
/// ```
@internal
pub fn sync_advisor_nudges(
  before: Shared(socket, recorder, source, replay_source),
  after: Shared(socket, recorder, source, replay_source),
) -> Shared(socket, recorder, source, replay_source) {
  case advisor_nudges_action(before, after) {
    HoldNudges -> after

    DropNudges ->
      after
      |> shared_set.nudges(None)
      |> shared_set.nudges_refresh(worktree_view.Settled)
      |> shared_set.nudges_awaiting(None)
      |> shared_set.nudges_request(None)

    ReadNudges -> {
      let started =
        !session_model.strand_running(before, advisor_pending.primary_strand)
        && session_model.strand_running(after, advisor_pending.primary_strand)
      after
      |> shared_set.nudges(case started {
        True -> None
        False -> after.nudges
      })
      |> shared_set.nudges_refresh(worktree_view.Requested)
    }
  }
}

/// The read waits for a free command lane like every other observation, so a
/// queued prompt is never held up behind an advisory panel.
///
/// Over the shared record alone; the terminal's tick runs it through
/// `tui_model.run_shared`.
///
/// ## Examples
///
/// ```gleam
/// surfaces.service_advisor_nudges_read(model.shared)
/// ```
@internal
pub fn service_advisor_nudges_read(
  shared: Shared(socket, recorder, source, replay_source),
) -> Shared(socket, recorder, source, replay_source) {
  case shared.channel, shared.nudges_refresh, shared.peer {
    Some(channel), worktree_view.Requested, Attached ->
      case session_channel.ready_for_read(channel) {
        True ->
          outbound.send_frame(
            shared
              |> shared_set.nudges_refresh(worktree_view.Settled)
              |> shared_set.nudges_awaiting(
                Some(session_model.queue_owner(shared)),
              ),
            protocol.advisor_pending(shared.next_id),
          )
        False -> shared
      }

    // A request that cannot be sent is dropped rather than left standing:
    // the next attachment reaches an idle primary and raises it again.
    _, worktree_view.Requested, _ ->
      shared_set.nudges_refresh(shared, worktree_view.Settled)

    _, worktree_view.Settled, _ -> shared
  }
}

/// Retires the board when a committed entry shows the queue was drained.
///
/// The daemon drains the queue at more doors than the run start the roster
/// can see: a checkpoint inside a long run, a follow-up placed on an ending
/// run, a steer into an open one. None of those moves a phase, so a board
/// read while the primary worked would otherwise stay on screen as
/// "pending, not delivered" beside the very entry that delivered it. The
/// delivered nudges frame on the primary's branch is the one observable
/// every door shares, so it clears the board and asks for a fresh read:
/// advice queued after the drain is still waiting and must stay visible.
/// An earlier read still in flight is disowned, as `DropNudges` disowns
/// one, so its reply cannot land after the fresh read and hide it.
///
/// Over the shared record alone; a terminal caller stores the result through
/// `tui_model.run_shared`.
///
/// ## Examples
///
/// ```gleam
/// // surfaces.retire_delivered_nudges(model.shared, record)
/// ```
@internal
pub fn retire_delivered_nudges(
  shared: Shared(socket, recorder, source, replay_source),
  record: protocol.EntryRecord,
) -> Shared(socket, recorder, source, replay_source) {
  case drains_queue(record) {
    True -> retire_board(shared)
    False -> shared
  }
}

/// Retires the board when a captured cut carries a delivery the board
/// predates.
///
/// A network terminal is told the primary's branch moved by a `committed`
/// notice and reads the branch in a capture, so the delivered frame arrives
/// inside a cut and never as a pushed entry. `retire_delivered_nudges` sees
/// only the latter, which left a board read before the drain on screen as
/// "pending, not delivered" beside the row that delivered it. This applies the
/// same rule to the cut's records, `records` being the primary's branch,
/// newest first.
///
/// One pass, and only while a board is held. The daemon stamps each entry and
/// the board with its own clock, so the walk stops at the first message older
/// than the board: an older frame was already drained when the board was read,
/// and the board does not list it. A frame stamped in the same millisecond as
/// the board retires it, because a needless re-read costs one request and a
/// stale board costs the symptom this exists to prevent. Diffing the cut
/// against the previous records instead would be quadratic in a branch of
/// thousands of entries.
///
/// ## Examples
///
/// ```gleam
/// surfaces.retire_nudges_delivered_since_board(shared, branch.records)
/// ```
@internal
pub fn retire_nudges_delivered_since_board(
  shared: Shared(socket, recorder, source, replay_source),
  records: List(protocol.EntryRecord),
) -> Shared(socket, recorder, source, replay_source) {
  case shared.nudges {
    None -> shared
    Some(board) ->
      case delivery_since(records, board.observed_at_ms) {
        True -> retire_board(shared)
        False -> shared
      }
  }
}

// Whether a primary-strand nudges frame stamped at or after `since` heads the
// records. Newest first, so the first message older than `since` ends the
// search; entries that are not messages carry no frame and are stepped over.
fn delivery_since(records: List(protocol.EntryRecord), since: Int) -> Bool {
  case records {
    [] -> False

    [record, ..older] ->
      case record.entry {
        entry.MessageEntry(ts:, ..) if ts < since -> False

        entry.MessageEntry(..)
        | entry.CompactionEntry(..)
        | entry.BranchSummaryEntry(..)
        | entry.CustomEntry(..) ->
          drains_queue(record) || delivery_since(older, since)
      }
  }
}

// Whether the record is the delivered frame of the primary's queue.
fn drains_queue(record: protocol.EntryRecord) -> Bool {
  case record {
    protocol.EntryRecord(strand:, entry: entry.MessageEntry(message: value, ..))
      if strand == advisor_pending.primary_strand
    ->
      case transcript_lines.advisor_payload(value) {
        Some(transcript_lines.Nudges(..)) -> True
        Some(_) | None -> False
      }

    protocol.EntryRecord(..) -> False
  }
}

// Clears the held board and asks for a fresh read, so advice queued after
// the drain stays visible. A read still in flight is disowned and the
// transcript and frame are marked stale.
fn retire_board(
  shared: Shared(socket, recorder, source, replay_source),
) -> Shared(socket, recorder, source, replay_source) {
  shared
  |> shared_set.nudges(None)
  |> shared_set.nudges_refresh(worktree_view.Requested)
  |> shared_set.nudges_awaiting(None)
  |> session_model.invalidate_transcript
  |> session_model.invalidate_frame
}

/// Sends the next exact-key read of summarizer labels the transcript's long
/// blocks lack (protocol 050), once the read lane is free.
///
/// The reads are what a reattaching terminal needs: a label written before
/// this attachment was pushed to nobody who is watching now. Each block is
/// asked about once per attachment, thirty-two to a read, and a block the
/// daemon has no label for keeps its first-line digest until a push brings
/// one. A read waits behind every other observation's, because a label is
/// the least urgent thing on screen.
///
/// Over the shared record alone; the terminal's tick runs it through
/// `tui_model.run_shared`.
///
/// ## Examples
///
/// ```gleam
/// surfaces.service_block_summaries(model.shared)
/// ```
@internal
pub fn service_block_summaries(
  shared: Shared(socket, recorder, source, replay_source),
) -> Shared(socket, recorder, source, replay_source) {
  case shared.channel, shared.peer {
    Some(channel), Attached ->
      case session_channel.ready_for_read(channel) {
        False -> shared
        True ->
          case block_summary.next_read(shared.summaries) {
            None -> shared
            Some(#(keys, summaries)) ->
              outbound.send_frame(
                shared_set.summaries(shared, summaries),
                protocol.block_summaries(shared.next_id, keys),
              )
          }
      }
    Some(_), Disconnected | Some(_), Preview | Some(_), Replaying | None, _ ->
      shared
  }
}

/// Only the attachment that asked may be answered. Request ids restart with an
/// attachment, so the owner is what tells a fresh board from a stale one.
///
/// Over the shared record alone; a terminal caller stores the result through
/// `tui_model.run_shared`.
///
/// ## Examples
///
/// ```gleam
/// // surfaces.receive_advisor_nudges(model.shared, board)
/// ```
@internal
pub fn receive_advisor_nudges(
  shared: Shared(socket, recorder, source, replay_source),
  board: advisor_pending.Board,
) -> Shared(socket, recorder, source, replay_source) {
  let current = session_model.queue_owner(shared)
  case shared.nudges_awaiting {
    Some(owner) ->
      case owner == current {
        True ->
          shared
          |> shared_set.nudges(Some(board))
          |> shared_set.nudges_awaiting(None)
          |> shared_set.nudges_request(None)
          |> session_model.invalidate_transcript
          |> session_model.invalidate_frame

        False -> shared
      }

    None -> shared
  }
}

/// Whether this transition is worth one goal read.
///
/// The three edges the pending-nudge panel reads on are all goal edges too:
/// the primary settling is where a continuation is decided, a review
/// settling is where the `complete` verdict lands, and the primary first
/// appearing in the roster is the attachment edge where nothing is known
/// yet. The goal adds one the queue does not have — the primary *starting*
/// a run — because a goal continuation is exactly such a start, and it is
/// the transition that moves `continuations`, the accounting and, at the
/// bounds, the status.
///
/// Unlike the nudge queue, no transition clears the board: a goal is pinned
/// until the operator unpins it, and a run in flight is the goal working
/// rather than evidence that it is gone.
///
/// ## Examples
///
/// ```gleam
/// surfaces.goal_action(before.shared, after.shared)
/// ```
@internal
pub fn goal_action(
  before: Shared(socket, recorder, source, replay_source),
  after: Shared(socket, recorder, source, replay_source),
) -> GoalAction {
  let started =
    before.session != after.session
    || {
      !session_model.strand_running(before, advisor_pending.primary_strand)
      && session_model.strand_running(after, advisor_pending.primary_strand)
    }

  case started, advisor_nudges_action(before, after) {
    True, _ -> ReadGoal
    False, ReadNudges -> ReadGoal
    False, DropNudges | False, HoldNudges -> HoldGoal
  }
}

/// Applies `goal_action` for the step from `before` to `after`.
///
/// Over the shared record alone; it is one of the three edges
/// `session_step.settle` runs after every event.
///
/// ## Examples
///
/// ```gleam
/// let shared = surfaces.sync_goal(before.shared, after.shared)
/// ```
@internal
pub fn sync_goal(
  before: Shared(socket, recorder, source, replay_source),
  after: Shared(socket, recorder, source, replay_source),
) -> Shared(socket, recorder, source, replay_source) {
  case goal_action(before, after) {
    HoldGoal -> after
    ReadGoal -> shared_set.goal_refresh(after, worktree_view.Requested)
  }
}

/// Arms the one line a committed goal mutation prints. The board that
/// commits it is the mutation's own reply. Admission may queue it behind a
/// read, so the report has no request owner until the lane issues the mutation.
///
/// Over the shared record alone.
///
/// ## Examples
///
/// ```gleam
/// let shared = surfaces.confirming(shared, "the session goal is cleared")
/// ```
@internal
pub fn confirming(
  shared: Shared(socket, recorder, source, replay_source),
  line: String,
) -> Shared(socket, recorder, source, replay_source) {
  shared_set.goal_report(shared, ConfirmGoal(line:, request: None))
}

/// Slash commands and inspector keys enter one gate. The pending-submission
/// marker tells the shared send path whether a composer draft belongs to this
/// command; an inspector action supplies `OverlaySubmission`, so the draft is
/// never cleared as though the operator had submitted it.
///
/// Over the shared record alone; a terminal caller stores the result through
/// `tui_model.run_shared`.
///
/// ## Examples
///
/// ```gleam
/// let shared = surfaces.submit_goal_action(shared, command.GoalPause)
/// ```
@internal
pub fn submit_goal_action(
  shared: Shared(socket, recorder, source, replay_source),
  action: command.Session,
) -> Shared(socket, recorder, source, replay_source) {
  case outbound.mutation_refusal(shared, action) {
    Some(reason) -> session_model.append_error(shared, reason)
    None -> {
      let prepared = case shared.pending_submission {
        Some(_) -> shared
        None -> shared_set.pending_submission(shared, Some(OverlaySubmission))
      }
      case action {
        command.GoalPause ->
          outbound.send_frame(
            confirming(prepared, "the session goal is held"),
            protocol.goal_pause(prepared.next_id),
          )
        command.GoalResume ->
          outbound.send_frame(
            confirming(prepared, "the session goal continues"),
            protocol.goal_resume(prepared.next_id),
          )
        _ -> prepared
      }
    }
  }
}

/// The read waits for a free command lane like every other observation.
///
/// Over the shared record alone. A read that cannot be sent appends a
/// `GoalUnavailable` observation, which `tui_model.hold_shared` applies to
/// the terminal's goal inspector, if it is open, at the point of the call.
///
/// ## Examples
///
/// ```gleam
/// surfaces.service_goal_read(model.shared)
/// ```
@internal
pub fn service_goal_read(
  shared: Shared(socket, recorder, source, replay_source),
) -> Shared(socket, recorder, source, replay_source) {
  case shared.channel, shared.goal_refresh, shared.peer {
    Some(channel), worktree_view.Requested, Attached ->
      case session_channel.ready_for_read(channel) {
        True ->
          outbound.send_frame(
            shared_set.goal_refresh(shared, worktree_view.Settled),
            protocol.goal_get(shared.next_id),
          )
        False -> shared
      }

    // A request that cannot be sent is dropped rather than left standing,
    // and an operator who asked for the panel is told why it is not coming
    // instead of watching for it.
    _, worktree_view.Requested, _ -> unreachable_goal(shared)

    _, worktree_view.Settled, _ -> shared
  }
}

// A disconnected host cannot turn Requested into a board. Settle the local
// read request and record unavailability; an open inspector retains its last
// observation with that reason, while automatic reads stay transcript-silent.
fn unreachable_goal(
  shared: Shared(socket, recorder, source, replay_source),
) -> Shared(socket, recorder, source, replay_source) {
  let settled =
    shared
    |> shared_set.goal_refresh(worktree_view.Settled)
    |> shared_set.goal_observations(
      list.append(shared.goal_observations, [
        GoalUnavailable("no conversation is attached"),
      ]),
    )
  case shared.goal_report {
    HoldGoalReport -> settled

    ReportGoal | ConfirmGoal(..) ->
      session_model.append_error(
        shared_set.goal_report(settled, HoldGoalReport),
        "the session goal cannot be read: no conversation is attached",
      )
  }
}

/// The lane correlates every board to its adopted attachment's read. A
/// lane-owned invalidation read has no operator slot and quietly replaces
/// the observation. An older read cannot settle a queued mutation's report.
///
/// Over the shared record alone. An answered board appends a `GoalObserved`
/// observation, which `tui_model.hold_shared` applies to the terminal's goal
/// inspector, if it is open, at the point of the call.
///
/// ## Examples
///
/// ```gleam
/// // surfaces.receive_goal(model.shared, board)
/// ```
@internal
pub fn receive_goal(
  shared: Shared(socket, recorder, source, replay_source),
  board: goal_view.Board,
) -> Shared(socket, recorder, source, replay_source) {
  case
    shared.goal_awaiting == None
    || shared.goal_awaiting == Some(session_model.queue_owner(shared))
  {
    False -> shared

    True -> {
      let observed =
        shared
        |> shared_set.goal(Some(board))
        |> shared_set.goal_awaiting(None)
        |> shared_set.goal_request(None)
        |> shared_set.goal_observations(
          list.append(shared.goal_observations, [
            GoalObserved(board),
          ]),
        )

      // Ownership is tested against the pre-reply record. The new record
      // has already cleared that read's slot, but a queued mutation's report
      // must survive until its own Sent update and reply.
      case owns_goal_report(shared) {
        True -> report_goal(observed, board)
        False -> session_model.invalidate_frame(observed)
      }
    }
  }
}

// A queued mutation can replace an explicit read's report before that read
// answers. Only the mutation's issued ID owns its confirmation; an older
// valid board still replaces the observation without consuming that report.
fn owns_goal_report(
  shared: Shared(socket, recorder, source, replay_source),
) -> Bool {
  case shared.goal_report {
    ConfirmGoal(request: Some(id), ..) -> shared.goal_request == Some(id)
    ConfirmGoal(request: None, ..) | HoldGoalReport -> False
    ReportGoal -> shared.goal_request != None
  }
}

// The operator's own question is answered in the transcript, in the system
// voice, because the status block is several lines and the band beside the
// composer holds one. An automatic refresh updates the row and prints
// nothing.
fn report_goal(
  shared: Shared(socket, recorder, source, replay_source),
  board: goal_view.Board,
) -> Shared(socket, recorder, source, replay_source) {
  case shared.goal_report {
    HoldGoalReport -> session_model.invalidate_frame(shared)

    // A committed mutation prints its one line here and nothing else. The
    // fresh board is already in the model, so the row beside the composer
    // carries the new state and a second block would repeat it.
    ConfirmGoal(line:, ..) ->
      shared_set.goal_report(shared, HoldGoalReport)
      |> session_model.append_system(line)
      |> session_model.invalidate_frame

    ReportGoal ->
      goal_view.lines(board)
      |> list.fold(
        shared_set.goal_report(shared, HoldGoalReport),
        session_model.append_system,
      )
      |> session_model.invalidate_frame
  }
}

/// A refused goal command, worded once. A refusal answering a request this
/// terminal no longer owns says nothing about the goal it is watching now.
///
/// Over the shared record alone. A refusal it accepts appends a
/// `GoalUnavailable` observation, which `tui_model.hold_shared` applies to
/// the terminal's goal inspector, if it is open, at the point of the call.
///
/// ## Examples
///
/// ```gleam
/// // surfaces.refuse_goal(model.shared, "goal_get", 7, "unsupported", text)
/// ```
@internal
pub fn refuse_goal(
  shared: Shared(socket, recorder, source, replay_source),
  command: String,
  request_id: Int,
  code: String,
  message: String,
) -> Shared(socket, recorder, source, replay_source) {
  // A snapshot_failed reply is a refusal of an observation, not evidence
  // that the last displayed board still describes the durable cell. Its
  // request ID must match before clearing the shared board or notifying a host.
  use <- bool.guard(shared.goal_request != Some(request_id), shared)
  let cleared =
    shared
    |> shared_set.goal(None)
    |> shared_set.goal_request(None)
    |> shared_set.goal_awaiting(None)
    |> shared_set.goal_report(case owns_goal_report(shared) {
      True -> HoldGoalReport
      False -> shared.goal_report
    })
    |> shared_set.goal_observations(
      list.append(shared.goal_observations, [
        GoalUnavailable(goal_view.refusal(code, message)),
      ]),
    )

  // An automatic refresh the operator never asked for stays silent: an
  // older daemon refuses every one of them, and a row per idle boundary
  // would be a scrolling complaint about a feature this session lacks. A
  // mutation and an explicit `/goal` are always the operator's own.
  use <- bool.guard(!owns_goal_report(shared) && command == "goal_get", cleared)

  session_model.append_error(cleared, goal_view.refusal(code, message))
}

/// Applies a live-jobs board if it answers the outstanding read for the
/// current attachment.
///
/// Over the shared record alone. The summary's job cursor is the terminal's
/// and follows the job it selected, which only the terminal knows, so the
/// terminal moves it after this call when `jobs_awaiting` shows the board
/// was taken (`summary_panel.follow_selected_job`).
///
/// ## Examples
///
/// ```gleam
/// // surfaces.receive_jobs(model.shared, board)
/// ```
@internal
pub fn receive_jobs(
  shared: Shared(socket, recorder, source, replay_source),
  board: live_jobs.Board,
) -> Shared(socket, recorder, source, replay_source) {
  case shared.jobs_awaiting {
    Some(#(owner, strand)) if strand == board.strand ->
      case owner == session_model.queue_owner(shared) {
        True ->
          Shared(
            ..{
              shared
              |> shared_set.jobs(Some(board))
              |> shared_set.jobs_awaiting(None)
              |> shared_set.jobs_request(None)
              |> shared_set.jobs_notice(
                "Live jobs observed separately from operation completion",
              )
            },
            jobs_observed_ms: Some(shared.stamp.now_ms),
          )
          |> session_model.invalidate_transcript
        False -> shared
      }
    Some(_) | None -> shared
  }
}

/// Context follows the server's selected configuration and the end of the
/// active strand's operation, never scrollback retention and no longer the
/// leaf. The leaf moves once per committed entry, so a refresh keyed on it
/// cost the server a full branch scan per tool call: a thirty-tool turn ran
/// about sixty of them for a percentage nobody reads until the turn ends.
/// Streaming tokens and unrelated captures start no read.
///
/// Over the shared record alone; it is one of the three edges
/// `session_step.settle` runs after every event.
///
/// ## Examples
///
/// ```gleam
/// let shared = surfaces.sync_context(before.shared, after.shared)
/// ```
@internal
pub fn sync_context(
  before: Shared(socket, recorder, source, replay_source),
  after: Shared(socket, recorder, source, replay_source),
) -> Shared(socket, recorder, source, replay_source) {
  let selected =
    context_view.select(
      after.context,
      session_model.queue_owner(after),
      after.active_strand,
    )
  let changed = context_refresh_due(before, after)
  let context = case after.peer {
    Attached ->
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
  shared_set.context(after, context)
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
/// surfaces.context_refresh_due(before.shared, after.shared)
/// ```
@internal
pub fn context_refresh_due(
  before: Shared(socket, recorder, source, replay_source),
  after: Shared(socket, recorder, source, replay_source),
) -> Bool {
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
fn operation_settled(
  before: Shared(socket, recorder, source, replay_source),
  after: Shared(socket, recorder, source, replay_source),
) -> Bool {
  session_model.active_strand_live(before)
  && !session_model.active_strand_live(after)
}

/// Sends a requested context read once the channel is ready and no
/// worktree observation holds the shared worker slot.
///
/// Over the shared record alone; a terminal caller stores the result through
/// `tui_model.run_shared`.
///
/// ## Examples
///
/// ```gleam
/// surfaces.service_context_read(model.shared)
/// ```
@internal
pub fn service_context_read(
  shared: Shared(socket, recorder, source, replay_source),
) -> Shared(socket, recorder, source, replay_source) {
  // A worktree acknowledgement releases the command lane, not its worker.
  // Wait for that observation before borrowing the shared slot for context.
  use <- bool.guard(shared.worktree.awaiting != None, shared)
  case shared.channel, shared.context.request, shared.peer, shared.captured {
    Some(channel), context_view.Requested, Attached, Some(_) ->
      case session_channel.ready_for_read(channel) {
        True ->
          outbound.send_frame(
            shared,
            protocol.context(shared.next_id, shared.active_strand),
          )
        False -> shared
      }
    _, _, _, _ -> shared
  }
}

fn context_in_flight(state: context_view.State) -> Bool {
  case state.request {
    context_view.Awaiting(_) | context_view.RefreshAfter(_) -> True
    context_view.Idle | context_view.Requested | context_view.Unavailable ->
      False
  }
}

// A review can add advice while the primary is still running. Its end is the
// read edge; the primary's end and a fresh attachment are recovery edges.
fn nudge_boundary(
  before: Shared(socket, recorder, source, replay_source),
  after: Shared(socket, recorder, source, replay_source),
) -> NudgeAction {
  let primary_settled =
    session_model.strand_running(before, advisor_pending.primary_strand)
    && !session_model.strand_running(after, advisor_pending.primary_strand)
  let newly_listed =
    !session_model.is_known_strand(
      before.strands,
      advisor_pending.primary_strand,
    )
    && session_model.is_known_strand(
      after.strands,
      advisor_pending.primary_strand,
    )

  let session_changed = before.session != after.session
  case primary_settled || newly_listed || session_changed {
    True -> ReadNudges
    False -> HoldNudges
  }
}
