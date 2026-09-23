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
//// The `sync_*` functions compare the model before and after an event and
//// decide whether that event makes a surface's data stale.

import gleam/bool
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import tui/advisor_pending
import tui/agents
import tui/command
import tui/context_view
import tui/focused_goal_panel
import tui/goal_view
import tui/layout
import tui/live_jobs
import tui/model.{
  type Model, AgentInspector, ApprovalInspector, Attached, ConfirmGoal,
  DaemonSelector, Disconnected, GoalInspector, HoldGoalReport, Model,
  ModelSelector, NoOverlay, OverlaySubmission, Preview, Replaying, ReportGoal,
  SessionSelector,
} as tui_model
import tui/outbound
import tui/protocol
import tui/queue_editor
import tui/render
import tui/session_channel
import tui/summary_panel
import tui/worktree_view

/// Inspection has its own target. Reading a worker's notes never changes the
/// active strand, its parked draft, or the next submitted message.
@internal
pub fn notes_target(model: Model) -> String {
  case model.overlay {
    AgentInspector(agents.Inspector(detail: agents.Notes, selected:, ..)) ->
      selected
    _ -> model.active_strand
  }
}

/// Whether a notes surface is on screen: standalone `/notes`, or the
/// agent inspector's Notes tab.
@internal
pub fn notes_surface(model: Model) -> Bool {
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

/// Sends the pending todo seed as an ordinary `notes` read once the read
/// lane is free. An operator's own notes read goes first, and its reply
/// seeds the board just the same when it is for the same strand.
@internal
pub fn service_todo_seed(model: Model) -> Model {
  case model.todo_seed, model.notes_requested, model.channel {
    None, _, _ | Some(_), Some(_), _ -> model
    Some(strand), None, Some(channel) ->
      case session_channel.ready_for_read(channel) {
        False -> model
        True -> send_todo_seed(model, strand)
      }
    Some(strand), None, None -> send_todo_seed(model, strand)
  }
}

fn send_todo_seed(model: Model, strand: String) -> Model {
  outbound.send_frame(
    Model(..model, todo_seed: None),
    protocol.notes(model.next_id, strand),
  )
}

/// Asks for a fresh read of the notes board for the strand the notes
/// surface is showing.
@internal
pub fn refresh_notes(model: Model) -> Model {
  service_notes_read(
    Model(
      ..model,
      notes_requested: Some(notes_target(model)),
      notice: "refreshing notes for " <> notes_target(model),
    ),
  )
}

/// Reads coalesce to the latest inspected target while the existing channel
/// owns an earlier command. Old replies may be retained, but never relabelled.
@internal
pub fn service_notes_read(model: Model) -> Model {
  case model.notes_requested, model.channel {
    None, _ -> model
    Some(target), Some(channel) -> {
      case session_channel.ready_for_read(channel) {
        False -> model
        True ->
          outbound.send_frame(
            Model(..model, notes_requested: None),
            protocol.notes(model.next_id, target),
          )
      }
    }
    Some(target), None ->
      outbound.send_frame(
        Model(..model, notes_requested: None),
        protocol.notes(model.next_id, target),
      )
  }
}

/// Moves the note selection by `direction`, clamped to the board.
@internal
pub fn select_note(model: Model, direction: Int) -> Model {
  let target = notes_target(model)
  case model.note_board {
    Some(board) if board.strand == target -> {
      let index =
        list.index_map(board.notes, fn(note, position) {
          #(Some(note.key), position)
        })
        |> list.key_find(render.selected_note(model, board))
        |> result.unwrap(0)
      let next =
        int.clamp(
          index + direction,
          0,
          int.max(0, list.length(board.notes) - 1),
        )
      let selected =
        list.drop(board.notes, next)
        |> list.first
        |> result.map(fn(note) { note.key })
        |> option.from_result

      // Note navigation moves only the surface that owns this key. The
      // transcript beneath an inspector retains its independent anchor.
      Model(..model, note_selected: selected, note_scroll: 0)
      |> tui_model.invalidate_transcript
    }
    _ -> model
  }
}

/// Sends a requested queued-input read once the channel is ready for it,
/// or drops the request when the attachment changed since it was made.
@internal
pub fn service_queue_read(model: Model) -> Model {
  case model.channel, model.queue_editor.fetch {
    Some(channel), Some(fetch) ->
      case session_channel.ready_for_read(channel) {
        True ->
          case tui_model.queue_owner(model) == fetch.owner {
            True ->
              outbound.send_frame(
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

/// Sends a requested worktree diff once the channel is ready and no
/// context read holds the shared worker slot.
@internal
pub fn service_worktree_read(model: Model) -> Model {
  // Both observations borrow the same server worker slot. An acknowledged
  // context read still owns it until its final push arrives.
  use <- bool.guard(context_in_flight(model.context), model)
  case model.channel, model.worktree.refresh, model.worktree.awaiting {
    Some(channel), worktree_view.Requested, None ->
      case session_channel.ready_for_read(channel) {
        True ->
          outbound.send_frame(model, protocol.worktree_diff(model.next_id))
        False -> model
      }
    _, _, _ -> model
  }
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
      summary_tab: summary_panel.Completion,
      summary_job_selected: 0,
      jobs_refresh: worktree_view.Requested,
    ),
  )
  |> tui_model.invalidate_frame
}

/// Sends a requested live-jobs read once the channel is ready for it.
@internal
pub fn service_jobs_read(model: Model) -> Model {
  case model.channel, model.jobs_refresh, model.peer {
    Some(channel), worktree_view.Requested, Attached(_) ->
      case session_channel.ready_for_read(channel) {
        True ->
          outbound.send_frame(
            Model(
              ..model,
              jobs_refresh: worktree_view.Settled,
              jobs_awaiting: Some(#(
                tui_model.queue_owner(model),
                model.active_strand,
              )),
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

// --- the advisor's pending nudges -------------------------------------------

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
/// // tui.advisor_nudges_action(before, after)
/// ```
@internal
pub fn advisor_nudges_action(before: Model, after: Model) -> NudgeAction {
  case layout.strand_running(after, advisor_pending.primary_strand) {
    // A run on the primary folds the whole queue into its first message, so
    // what the panel was showing has been delivered rather than discarded.
    // The local submit flag counts: it is the edge the operator sees, and
    // waiting for the server's phase would leave delivered advice on screen.
    True -> DropNudges

    False -> idle_boundary(before, after)
  }
}

// The primary is idle in `after`, so a primary that was running in `before`
// is one that just settled. The advisor needs both halves of its own edge,
// because it can still be mid-review and only a review's end adds to the
// queue.
fn idle_boundary(before: Model, after: Model) -> NudgeAction {
  let primary_settled =
    layout.strand_running(before, advisor_pending.primary_strand)
  let review_settled =
    layout.strand_running(before, advisor_pending.advisor_strand)
    && !layout.strand_running(after, advisor_pending.advisor_strand)
  let newly_listed =
    !layout.strand_listed(before, advisor_pending.primary_strand)
    && layout.strand_listed(after, advisor_pending.primary_strand)

  let session_changed = before.session != after.session
  case primary_settled || review_settled || newly_listed || session_changed {
    True -> ReadNudges
    False -> HoldNudges
  }
}

/// Applies `advisor_nudges_action` for the step from `before` to `after`.
@internal
pub fn sync_advisor_nudges(before: Model, after: Model) -> Model {
  case advisor_nudges_action(before, after) {
    HoldNudges -> after

    DropNudges ->
      Model(
        ..after,
        nudges: None,
        nudges_refresh: worktree_view.Settled,
        nudges_awaiting: None,
        nudges_request: None,
      )

    ReadNudges -> Model(..after, nudges_refresh: worktree_view.Requested)
  }
}

/// The read waits for a free command lane like every other observation, so a
/// queued prompt is never held up behind an advisory panel.
@internal
pub fn service_advisor_nudges_read(model: Model) -> Model {
  case model.channel, model.nudges_refresh, model.peer {
    Some(channel), worktree_view.Requested, Attached(_) ->
      case session_channel.ready_for_read(channel) {
        True ->
          outbound.send_frame(
            Model(
              ..model,
              nudges_refresh: worktree_view.Settled,
              nudges_awaiting: Some(tui_model.queue_owner(model)),
            ),
            protocol.advisor_pending(model.next_id),
          )
        False -> model
      }

    // A request that cannot be sent is dropped rather than left standing:
    // the next attachment reaches an idle primary and raises it again.
    _, worktree_view.Requested, _ ->
      Model(..model, nudges_refresh: worktree_view.Settled)

    _, worktree_view.Settled, _ -> model
  }
}

/// Only the attachment that asked may be answered. Request ids restart with an
/// attachment, so the owner is what tells a fresh board from a stale one.
@internal
pub fn receive_advisor_nudges(
  model: Model,
  board: advisor_pending.Board,
) -> Model {
  let current = tui_model.queue_owner(model)
  case model.nudges_awaiting {
    Some(owner) ->
      case owner == current {
        True ->
          Model(
            ..model,
            nudges: Some(board),
            nudges_awaiting: None,
            nudges_request: None,
          )
          |> tui_model.invalidate_transcript
          |> tui_model.invalidate_frame

        False -> model
      }

    None -> model
  }
}

/// What one model transition asks of the goal panel.
pub type GoalAction {
  /// The goal may have moved; one read is worth its round trip.
  ReadGoal

  /// Nothing the panel depends on moved.
  HoldGoal
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
/// // tui.goal_action(before, after)
/// ```
@internal
pub fn goal_action(before: Model, after: Model) -> GoalAction {
  let started =
    before.session != after.session
    || {
      !layout.strand_running(before, advisor_pending.primary_strand)
      && layout.strand_running(after, advisor_pending.primary_strand)
    }

  case started, advisor_nudges_action(before, after) {
    True, _ -> ReadGoal
    False, ReadNudges -> ReadGoal
    False, DropNudges | False, HoldNudges -> HoldGoal
  }
}

/// Applies `goal_action` for the step from `before` to `after`.
@internal
pub fn sync_goal(before: Model, after: Model) -> Model {
  case goal_action(before, after) {
    HoldGoal -> after
    ReadGoal -> Model(..after, goal_refresh: worktree_view.Requested)
  }
}

/// The operator's own `/goal` opens the retained observation immediately and
/// requests a current board. Its label distinguishes that retained board from
/// the correlated refresh which replaces it.
/// Arms the one line a committed goal mutation prints. The board that
/// commits it is the mutation's own reply, so nothing else has to be
/// scheduled: `report_goal` finds the line where `receive_goal` leaves it.
@internal
pub fn confirming(model: Model, line: String) -> Model {
  Model(..model, goal_report: ConfirmGoal(line:))
}

/// Slash commands and inspector keys enter one gate. The pending-submission
/// marker tells the shared send path whether a composer draft belongs to this
/// command; an inspector action supplies `OverlaySubmission`, so the draft is
/// never cleared as though the operator had submitted it.
@internal
pub fn submit_goal_action(model: Model, action: command.Command) -> Model {
  case outbound.mutation_refusal(model, action) {
    Some(reason) -> tui_model.append_error(model, reason)
    None -> {
      let prepared = case model.pending_submission {
        Some(_) -> model
        None -> Model(..model, pending_submission: Some(OverlaySubmission))
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

/// Opens the goal inspector and asks for a fresh goal board. The preview
/// mode shows an illustrative observation instead.
@internal
pub fn request_goal_status(model: Model) -> Model {
  let panel = case model.overlay {
    GoalInspector(state) -> state
    _ -> focused_goal_panel.new(model.goal, goal_observation(model))
  }
  case model.peer {
    Preview ->
      Model(
        ..model,
        overlay: GoalInspector(panel),
        goal_report: HoldGoalReport,
        repaint_phase: !model.repaint_phase,
        notice: "goal inspector · illustrative observation",
      )
    Attached(_) | Disconnected | Replaying ->
      Model(
        ..model,
        overlay: GoalInspector(panel),
        goal_refresh: worktree_view.Requested,
        goal_report: ReportGoal,
        repaint_phase: !model.repaint_phase,
      )
  }
}

fn goal_observation(model: Model) -> String {
  case model.goal, model.peer {
    Some(_), Attached(_) -> "Last server observation · refreshing"
    Some(_), Disconnected -> "Last server observation · disconnected"
    Some(_), Preview | Some(_), Replaying -> "Illustrative observation"
    None, Attached(_) -> "Reading current goal"
    None, Disconnected -> "Goal unavailable · disconnected"
    None, Preview | None, Replaying -> "Goal unavailable in this preview"
  }
}

/// The read waits for a free command lane like every other observation.
@internal
pub fn service_goal_read(model: Model) -> Model {
  case model.channel, model.goal_refresh, model.peer {
    Some(channel), worktree_view.Requested, Attached(_) ->
      case session_channel.ready_for_read(channel) {
        True ->
          outbound.send_frame(
            Model(..model, goal_refresh: worktree_view.Settled),
            protocol.goal_get(model.next_id),
          )
        False -> model
      }

    // A request that cannot be sent is dropped rather than left standing,
    // and an operator who asked for the panel is told why it is not coming
    // instead of watching for it.
    _, worktree_view.Requested, _ -> unreachable_goal(model)

    _, worktree_view.Settled, _ -> model
  }
}

fn unreachable_goal(model: Model) -> Model {
  let settled =
    Model(
      ..model,
      goal_refresh: worktree_view.Settled,
      overlay: case model.overlay {
        GoalInspector(state) ->
          GoalInspector(focused_goal_panel.unavailable(
            state,
            "no conversation is attached",
          ))
        other -> other
      },
    )
  case model.goal_report {
    HoldGoalReport -> settled

    ReportGoal | ConfirmGoal(..) ->
      tui_model.append_error(
        Model(..settled, goal_report: HoldGoalReport),
        "the session goal cannot be read: no conversation is attached",
      )
  }
}

/// Only the attachment that asked may be answered. Request ids restart with
/// an attachment, so the owner is what tells a fresh board from a stale one.
@internal
pub fn receive_goal(model: Model, board: goal_view.Board) -> Model {
  case model.goal_awaiting == Some(tui_model.queue_owner(model)) {
    False -> model

    True ->
      report_goal(
        Model(
          ..model,
          goal: Some(board),
          overlay: case model.overlay {
            GoalInspector(state) ->
              GoalInspector(focused_goal_panel.observe(state, board))
            other -> other
          },
          goal_awaiting: None,
          goal_request: None,
        ),
        board,
      )
  }
}

// The operator's own question is answered in the transcript, in the system
// voice, because the status block is several lines and the band beside the
// composer holds one. An automatic refresh updates the row and prints
// nothing.
fn report_goal(model: Model, board: goal_view.Board) -> Model {
  case model.goal_report {
    HoldGoalReport -> tui_model.invalidate_frame(model)

    // A committed mutation prints its one line here and nothing else. The
    // fresh board is already in the model, so the row beside the composer
    // carries the new state and a second block would repeat it.
    ConfirmGoal(line:) ->
      Model(..model, goal_report: HoldGoalReport)
      |> tui_model.append_system(line)
      |> tui_model.invalidate_frame

    ReportGoal ->
      goal_view.lines(board)
      |> list.fold(
        Model(..model, goal_report: HoldGoalReport),
        tui_model.append_system,
      )
      |> tui_model.invalidate_frame
  }
}

/// A refused goal command, worded once. A refusal answering a request this
/// terminal no longer owns says nothing about the goal it is watching now.
@internal
pub fn refuse_goal(
  model: Model,
  command: String,
  request_id: Int,
  code: String,
  message: String,
) -> Model {
  use <- bool.guard(model.goal_request != Some(request_id), model)
  let cleared =
    Model(
      ..model,
      goal: None,
      overlay: case model.overlay {
        GoalInspector(state) ->
          GoalInspector(focused_goal_panel.unavailable(
            state,
            goal_view.refusal(code, message),
          ))
        other -> other
      },
      goal_request: None,
      goal_awaiting: None,
      goal_report: HoldGoalReport,
    )

  // An automatic refresh the operator never asked for stays silent: an
  // older daemon refuses every one of them, and a row per idle boundary
  // would be a scrolling complaint about a feature this session lacks. A
  // mutation and an explicit `/goal` are always the operator's own.
  use <- bool.guard(
    model.goal_report == HoldGoalReport && command == "goal_get",
    cleared,
  )

  tui_model.append_error(cleared, goal_view.refusal(code, message))
}

/// Applies a live-jobs board if it answers the outstanding read for the
/// current attachment, keeping the selected job selected when it is still
/// listed.
@internal
pub fn receive_jobs(model: Model, board: live_jobs.Board) -> Model {
  case model.jobs_awaiting {
    Some(#(owner, strand)) if strand == board.strand ->
      case owner == tui_model.queue_owner(model) {
        True -> {
          let old = case model.jobs {
            Some(previous) if previous.strand == board.strand ->
              previous.jobs
              |> list.drop(model.summary_job_selected)
              |> list.first
            Some(_) | None -> Error(Nil)
          }
          let selected = case old {
            Ok(job) ->
              board.jobs
              |> list.index_map(fn(item, index) { #(item.id, index) })
              |> list.key_find(job.id)
              |> result.unwrap(0)
            Error(Nil) -> 0
          }
          Model(
            ..model,
            jobs: Some(board),
            summary_job_selected: selected,
            jobs_observed_ms: Some(model.monotonic_time_ms()),
            jobs_awaiting: None,
            jobs_request: None,
            jobs_notice: "Live jobs observed separately from operation completion",
          )
          |> tui_model.invalidate_transcript
        }
        False -> model
      }
    Some(_) | None -> model
  }
}

/// Context follows the server's selected configuration and the end of the
/// active strand's operation, never scrollback retention and no longer the
/// leaf. The leaf moves once per committed entry, so a refresh keyed on it
/// cost the server a full branch scan per tool call: a thirty-tool turn ran
/// about sixty of them for a percentage nobody reads until the turn ends.
/// Streaming tokens and unrelated captures start no read.
@internal
pub fn sync_context(before: Model, after: Model) -> Model {
  let selected =
    context_view.select(
      after.context,
      tui_model.queue_owner(after),
      after.active_strand,
    )
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
  tui_model.active_strand_live(before) && !tui_model.active_strand_live(after)
}

/// Sends a requested context read once the channel is ready and no
/// worktree observation holds the shared worker slot.
@internal
pub fn service_context_read(model: Model) -> Model {
  // A worktree acknowledgement releases the command lane, not its worker.
  // Wait for that observation before borrowing the shared slot for context.
  use <- bool.guard(model.worktree.awaiting != None, model)
  case model.channel, model.context.request, model.peer, model.captured {
    Some(channel), context_view.Requested, Attached(_), Some(_) ->
      case session_channel.ready_for_read(channel) {
        True ->
          outbound.send_frame(
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

fn context_in_flight(state: context_view.State) -> Bool {
  case state.request {
    context_view.Awaiting(_) | context_view.RefreshAfter(_) -> True
    context_view.Idle | context_view.Requested | context_view.Unavailable ->
      False
  }
}
