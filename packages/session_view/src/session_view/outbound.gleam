//// The one path an encoded command frame takes to the daemon.
////
//// Every reducer that asks the daemon for something calls `send_frame`.
//// With a session channel attached, the channel decides whether the frame
//// is sent, held until the channel is ready, or refused, and
//// `apply_submission` folds that decision back into the session state: the
//// surface that asked records its request ID, a composer submission counts
//// as a sent draft only once it was sent, and a frame that was definitely
//// not sent restores the draft with an error. Without a channel the frame
//// goes nowhere: only the channel holds a socket. The write itself happens
//// after the step, in the host (the terminal's `tui/runtime`).
////
//// `mutation_refusal` is the check made before encoding a command that
//// changes session state, so a read-only or unsynchronized attachment
//// keeps the draft rather than losing it to a refusal.
////
//// Every function here takes and returns the shared record alone
//// (`session_view/model`), so any host of the session can send through it
//// with its own handle bindings. What a send means for a host's editors
//// is recorded rather than written: a sent composer draft bumps
//// `Shared.drafts_sent`, and a refusal appends a `queue_request.Refused`
//// notice for the queue editor. The terminal stores each result through
//// `tui_model.hold_shared`, which empties its composer and shows the notice
//// at the point of the call, where this module used to write them itself.
//// Its forms of `send_frame`, `send_via` and `apply_submission`, for the
//// reducers that still take the whole model, are in `tui/model`.
////
//// ## Flow
////
//// `send_frame` enters `send_via`, which stores the lane and applies its
//// disposition through `apply_submission`.
//// `record_sent` binds the actual issued ID to the surface that asked.
//// Waiting keeps a draft locked; `has_unsent` checks the lane, not the notice.
//// `mutation_refusal` checks authority before a caller encodes a mutation.
//// A queued goal confirmation has no request ID until `record_sent` binds it.

import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import session_view/command
import session_view/context_view
import session_view/model.{
  type Shared, Attached, ComposerSubmission, ConfirmGoal, Disconnected,
  HoldGoalReport, OverlaySubmission, Preview, Replaying, ReportGoal, Shared,
} as session_model
import session_view/notice_words
import session_view/queue_request
import session_view/session_channel
import session_view/shared_set
import session_view/worktree_view

/// Sends one encoded command frame. With a session channel the channel
/// decides whether it is sent, queued or refused; without one nothing is
/// written. Nothing reaches the wire until the host performs the lane's
/// outputs, which this queues on `Shared.outbox`.
///
/// ## Examples
///
/// ```gleam
/// outbound.send_frame(shared, protocol.goal_get(shared.next_id))
/// ```
@internal
pub fn send_frame(
  shared: Shared(socket, recorder, source, replay_source),
  frame: String,
) -> Shared(socket, recorder, source, replay_source) {
  send_via(shared, fn(lane, now) { session_channel.submit(lane, frame, now:) })
}

/// Submits through the adopted lane with `arm`, one of the engine's command
/// arms (`session_view/operator`) or a plain `session_channel.submit`, and
/// folds the lane's disposition back into the session state as `send_frame`
/// does.
///
/// The arm is given the lane and the step's transport time and returns the
/// transitioned lane, which is stored through `session_model.hold_channel`
/// so its queued write joins the shared outbox. Without a lane nothing is
/// written.
///
/// ## Examples
///
/// ```gleam
/// outbound.send_via(shared, fn(lane, now) {
///   operator.submit(lane, shared.next_id, "main", text, operator.Prompt, now)
/// })
/// ```
@internal
pub fn send_via(
  shared: Shared(socket, recorder, source, replay_source),
  arm: fn(session_channel.Channel(socket, recorder), Int) ->
    #(session_channel.Channel(socket, recorder), session_channel.Disposition),
) -> Shared(socket, recorder, source, replay_source) {
  case shared.channel {
    Some(channel) -> {
      let #(channel, disposition) = arm(channel, shared.stamp.transport_ms)
      apply_submission(session_model.hold_channel(shared, channel), disposition)
    }

    // No lane means nowhere to write. An attached peer always has its lane,
    // so this is the preview, a replay, or a launch that has not adopted a
    // session yet, and none of them may pretend to have sent anything.
    None -> shared
  }
}

/// Folds the session channel's disposition for a submitted frame back into
/// the session state: a waiting frame locks the draft, a sent frame records
/// its request ID in the surface that asked, and a frame that was definitely
/// not sent restores the draft with an error.
///
/// A sent frame marked `ComposerSubmission` consumes the composer's draft:
/// its attachments are emptied here and `drafts_sent` moves, so each host
/// empties its own editor. A frame that was not sent appends a
/// `queue_request.Refused` notice, so a queue editor waiting on a save is
/// unlocked, as every refusal did before the editor left this function.
///
/// ## Examples
///
/// ```gleam
/// outbound.apply_submission(shared, session_channel.Sent("prompt", 7))
/// ```
@internal
pub fn apply_submission(
  shared: Shared(socket, recorder, source, replay_source),
  disposition: session_channel.Disposition,
) -> Shared(socket, recorder, source, replay_source) {
  case disposition {
    session_channel.Waiting(_) ->
      case has_unsent(shared) {
        True ->
          waiting_notice(
            shared
            |> shared_set.pending_submission(
              Some(option.unwrap(shared.pending_submission, OverlaySubmission)),
            )
            |> shared_set.submitting(None),
          )
        False -> shared
      }

    session_channel.Sent(command, request_id) ->
      record_sent(shared, command, request_id)

    session_channel.DefinitelyNotSent(reason) -> {
      let shared = case has_unsent(shared) {
        True -> shared
        False ->
          shared
          |> shared_set.pending_submission(None)
          |> shared_set.submitting(None)
      }

      // The frame never reached the wire, so no entry answers it.
      let discarded = discard_own_turn(shared)
      discarded
      |> shared_set.queue_request(queue_request.new())
      |> shared_set.queue_notices(
        list.append(discarded.queue_notices, [
          queue_request.Refused(reason),
        ]),
      )
      |> session_model.append_error(
        "Not sent: " <> reason <> "; draft retained",
      )
    }
  }
}

// A sent frame settles the submission that carried it. The surface that
// asked keeps the lane's request ID, so its reply, or a refusal naming that
// ID, can be matched to it later. The composer's draft is consumed only when
// the frame was the composer's own, so a selector action sent while the
// operator is typing leaves the draft alone.
fn record_sent(
  shared: Shared(socket, recorder, source, replay_source),
  command: String,
  request_id: Int,
) -> Shared(socket, recorder, source, replay_source) {
  // Admission can queue a mutation behind an older goal read. Its report
  // gains an owner only when the lane actually issues that mutation.
  // ConfirmGoal(request: None) is admitted intent; Some(request_id) is the
  // issued command. The goal_get arm below records a read ID without binding
  // a waiting mutation's confirmation to that older read.
  let goal_report = case command, shared.goal_report {
    "goal_set", ConfirmGoal(line:, ..)
    | "goal_check", ConfirmGoal(line:, ..)
    | "goal_clear", ConfirmGoal(line:, ..)
    | "goal_pause", ConfirmGoal(line:, ..)
    | "goal_resume", ConfirmGoal(line:, ..)
    -> ConfirmGoal(line:, request: Some(request_id))
    _, _ -> shared.goal_report
  }

  let shared = case command {
    "queued_input" | "edit_queued_input" ->
      shared_set.queue_request(
        shared,
        queue_request.State(
          ..shared.queue_request,
          request_id: Some(request_id),
        ),
      )
    "context" ->
      shared_set.context(shared, context_view.sent(shared.context, request_id))
    "live_jobs" -> shared_set.jobs_request(shared, Some(request_id))
    "advisor_pending" -> shared_set.nudges_request(shared, Some(request_id))

    // Every goal command is answered with a board, so a mutation owns
    // the same slot its read does: the server renders the fresh panel
    // into the mutation's reply rather than making the terminal ask.
    "goal_get"
    | "goal_set"
    | "goal_check"
    | "goal_clear"
    | "goal_pause"
    | "goal_resume" ->
      shared
      |> shared_set.goal_request(Some(request_id))
      |> shared_set.goal_report(goal_report)
      |> shared_set.goal_awaiting(Some(session_model.queue_owner(shared)))
    "worktree_diff" ->
      shared_set.worktree(
        shared,
        worktree_view.sent(shared.worktree, request_id),
      )
    _ -> shared
  }

  let #(attachments, drafts_sent) = case shared.pending_submission {
    Some(ComposerSubmission) -> #([], shared.drafts_sent + 1)
    Some(OverlaySubmission) | None -> #(shared.attachments, shared.drafts_sent)
  }
  let submitting = case command, shared.pending_submission {
    "prompt", Some(ComposerSubmission) -> Some(shared.active_strand)
    _, _ -> shared.submitting
  }
  Shared(
    ..{
      shared
      |> shared_set.attachments(attachments)
      |> shared_set.submitting(submitting)
      |> shared_set.pending_submission(None)
      |> shared_set.next_id(shared.next_id + 1)
      |> shared_set.notice(case command {
        // Automatic observation must not erase a user's command outcome.
        "context" -> shared.notice
        "goal_get" ->
          case shared.goal_report {
            HoldGoalReport -> shared.notice
            ReportGoal | ConfirmGoal(..) -> notice_words.sent(command)
          }
        _ -> notice_words.sent(command)
      })
    },
    drafts_sent:,
  )
  |> session_model.invalidate_frame
}

// Whether the lane still holds a frame it has not written, which keeps the
// draft locked behind it.
fn has_unsent(shared: Shared(socket, recorder, source, replay_source)) -> Bool {
  case shared.channel {
    Some(channel) -> session_channel.has_unsent(channel)
    None -> False
  }
}

/// Sets the notice shown while a submission waits for the channel.
///
/// ## Examples
///
/// ```gleam
/// outbound.waiting_notice(shared)
/// ```
@internal
pub fn waiting_notice(
  shared: Shared(socket, recorder, source, replay_source),
) -> Shared(socket, recorder, source, replay_source) {
  shared_set.notice(shared, "Waiting to send · draft locked · Esc cancels")
}

/// The daemon refused it, or it never reached the wire. No entry is coming,
/// so the echo goes away with the submission rather than outliving it.
///
/// ## Examples
///
/// ```gleam
/// outbound.discard_own_turn(shared)
/// ```
@internal
pub fn discard_own_turn(
  shared: Shared(socket, recorder, source, replay_source),
) -> Shared(socket, recorder, source, replay_source) {
  case shared.awaiting_outcome {
    Some(_) ->
      shared_set.awaiting_outcome(shared, None)
      |> session_model.invalidate_transcript
    None -> shared
  }
}

/// The reason a command may not be sent now, if there is one. The draft is
/// retained in every refusal.
///
/// ## Examples
///
/// ```gleam
/// outbound.mutation_refusal(model.shared, command.Compact)
/// ```
@internal
pub fn mutation_refusal(
  shared: Shared(socket, recorder, source, replay_source),
  command: command.Session,
) -> Option(String) {
  let mutates = mutating_submission(shared, command)
  use <- bool.guard(
    mutates
      && shared.captured != None
      && !session_model.is_known_strand(shared.strands, shared.active_strand),
    Some("recipient unavailable; draft retained for " <> shared.active_strand),
  )
  case mutates, shared.peer, shared.channel {
    False, _, _ -> None
    True, Disconnected, _ -> Some("no conversation is attached; draft retained")
    True, Attached, Some(channel) ->
      case session_channel.mutation_available(channel) {
        True -> None
        False ->
          Some(
            "attachment is read-only or its command slot is busy; draft retained",
          )
      }
    True, Attached, None ->
      Some("conversation has not synchronized; draft retained")
    True, Preview, _ | True, Replaying, _ -> None
  }
}

/// Reports whether `command` changes session state, and so needs a live,
/// writable attachment and a known recipient. Only a session command can:
/// every `command.Surface` command is the host's own, and none mutates.
///
/// ## Examples
///
/// ```gleam
/// outbound.mutating_submission(model.shared, command.Compact)
/// ```
@internal
pub fn mutating_submission(
  shared: Shared(socket, recorder, source, replay_source),
  command: command.Session,
) -> Bool {
  case command {
    command.Prompt(_)
    | command.Model(_)
    | command.ProfileSelect(_)
    | command.Unschedule(..)
    | command.Fork(_)
    | command.Effort(_)
    | command.GoalSet(..)
    | command.GoalCheck(..)
    | command.GoalClear
    | command.GoalPause
    | command.GoalResume
    | command.Compact
    | command.Abort
    | command.Steer(_)
    | command.Queue(_) -> True
    command.Approve(_) | command.Deny(_) | command.AddDirectory(..) -> True
    command.Empty -> shared.attachments != []
    command.Schedules
    | command.ProfileShow
    | command.Approvals(_)
    | command.GoalBudgetInvalid(_)
    | command.GoalObjectiveTooLong(_)
    | command.GoalCheckTooLong(_)
    | command.Clear
    | command.Unknown(_)
    | command.MissingArgument(_) -> False
  }
}
