//// The one path an encoded command frame takes to the daemon.
////
//// Every reducer that asks the daemon for something calls `send_frame`.
//// With a session channel attached, the channel decides whether the frame
//// is sent, held until the channel is ready, or refused, and
//// `apply_submission` folds that decision back into the model: the
//// surface that asked records its request ID, a composer submission
//// clears the draft only once it was sent, and a frame that was
//// definitely not sent restores the draft with an error. Without a
//// channel, the frame goes straight to the socket when the peer is
//// attached, and nowhere otherwise.
////
//// `mutation_refusal` is the check made before encoding a command that
//// changes session state, so a read-only or unsynchronized attachment
//// keeps the draft rather than losing it to a refusal.

import etui/widgets/textarea as text_area
import gleam/bool
import gleam/option.{type Option, None, Some}
import gleam/string
import tui/command
import tui/connection
import tui/context_view
import tui/model.{
  type Model, Attached, ComposerSubmission, ConfirmGoal, Disconnected,
  HoldGoalReport, Model, OverlaySubmission, Preview, PromptNext, Replaying,
  ReportGoal,
} as tui_model
import tui/queue_editor
import tui/session_channel
import tui/worktree_view

/// Sets the notice shown while a submission waits for the channel.
@internal
pub fn waiting_notice(model: Model) -> Model {
  Model(..model, notice: "Waiting to send · draft locked · Esc cancels")
}

/// The reason a command may not be sent now, if there is one. The draft is
/// retained in every refusal.
@internal
pub fn mutation_refusal(
  model: Model,
  command: command.Command,
) -> Option(String) {
  let mutates = mutating_submission(model, command)
  use <- bool.guard(
    mutates
      && model.captured != None
      && !tui_model.is_known_strand(model.strands, model.active_strand),
    Some("recipient unavailable; draft retained for " <> model.active_strand),
  )
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

/// Reports whether `command` changes session state, and so needs a live,
/// writable attachment and a known recipient.
@internal
pub fn mutating_submission(model: Model, command: command.Command) -> Bool {
  case command {
    command.Prompt(_)
    | command.Model(_)
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
    command.Empty -> model.attachments != []
    command.Help
    | command.Models
    | command.Strands
    | command.Schedules
    | command.Agents
    | command.PeerLinks
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
    | command.GoalStatus
    | command.GoalBudgetInvalid(_)
    | command.GoalObjectiveTooLong(_)
    | command.GoalCheckTooLong(_)
    | command.Clear
    | command.Quit
    | command.Unknown(_)
    | command.MissingArgument(_) -> False
  }
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

/// The daemon refused it, or it never reached the wire. No entry is coming,
/// so the echo goes away with the submission rather than outliving it.
@internal
pub fn discard_own_turn(model: Model) -> Model {
  case model.awaiting_outcome {
    Some(_) ->
      Model(..model, awaiting_outcome: None) |> tui_model.invalidate_transcript
    None -> model
  }
}

/// Sends one encoded command frame. With a session channel the channel
/// decides whether it is sent, queued or refused; without one it goes
/// straight to the preview peer, if that peer has a socket.
@internal
pub fn send_frame(model: Model, frame: String) -> Model {
  case model.channel {
    Some(channel) -> {
      let #(channel, disposition) = session_channel.submit(channel, frame)
      apply_submission(Model(..model, channel: Some(channel)), disposition)
    }
    None -> send_preview_frame(model, frame)
  }
}

/// Folds the session channel's disposition for a submitted frame back into
/// the model: a waiting frame locks the draft, a sent frame records its
/// request ID in the surface that asked, and a frame that was definitely not
/// sent restores the draft with an error.
@internal
pub fn apply_submission(
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
        "advisor_pending" -> Model(..model, nudges_request: Some(request_id))

        // Every goal command is answered with a board, so a mutation owns
        // the same slot its read does: the server renders the fresh panel
        // into the mutation's reply rather than making the terminal ask.
        "goal_get"
        | "goal_set"
        | "goal_check"
        | "goal_clear"
        | "goal_pause"
        | "goal_resume" ->
          Model(
            ..model,
            goal_request: Some(request_id),
            goal_awaiting: Some(tui_model.queue_owner(model)),
          )
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
          "goal_get" ->
            case sent.goal_report {
              HoldGoalReport -> sent.notice
              ReportGoal | ConfirmGoal(..) -> command <> " sent"
            }
          _ -> command <> " sent"
        },
      )
      |> tui_model.invalidate_frame
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
      tui_model.append_error(
        Model(
          ..discard_own_turn(model),
          queue_editor: queue_editor.refused(model.queue_editor, reason),
        ),
        "Not sent: " <> reason <> "; draft retained",
      )
    }
  }
}

/// Clears the composer text, its attachments and its submission mode.
@internal
pub fn clear_composer(model: Model) -> Model {
  let cleared = clear_composer_text(model)
  Model(..cleared, attachments: [], submission_mode: PromptNext)
}

/// Clears the composer text after remembering it in the input history.
@internal
pub fn clear_composer_text(model: Model) -> Model {
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
