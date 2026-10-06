//// The lane fold: what the adopted session lane's updates, and a replay's
//// recorded changes, do to the session state.
////
//// `apply_channel_update` folds one `session_channel.Update` into the shared
//// record: a captured cut (`reconcile_cut`, `render_cut`), a history page,
//// an approval lookup, a refusal, an acknowledgement, a pushed fragment, a
//// lost lane. `apply_replay_change` does the same for one change a replayed
//// attempt event produced. Both take and return `Shared` alone and read no
//// host state; a pushed event goes on to `event_fold.apply_event`.
////
//// The host keeps the loop. It takes the lane's updates from `tick`,
//// `receive` or `cancel_unsent` (and a replay's changes from
//// `take_replayed`) and applies them one at a time. Before each update it
//// passes the `Surroundings` a decision inside the update reads (whether a
//// diff or a notes surface is shown, and the approval under review), and
//// after each it applies the `SurfaceFact` values the update recorded, so an
//// update sees every host write an earlier one caused, as it did when the
//// fold wrote the host's state itself (`docs/design-notes/step-extraction.md`,
//// question 11). The terminal's loop is in `tui/inbound`, and a host with no
//// surfaces of its own runs the same loop with no facts to apply.
////
//// ## Flow
////
//// `tick` / `receive` → `apply_channel_update` → `fold_update` → `reconcile_cut` → `apply_cut` → `render_cut`
////
//// 1. `tick`, `receive` and `cancel_unsent` give the lane its time or a socket
////    message and return the `session_channel.Update` values it produced; the
////    host applies them one at a time.
//// 2. `apply_channel_update` calls `fold_update` for the update's own effect,
////    then keeps a reply's words apart so a later event cannot write
////    them over; `host_read` says which refusals are no command's outcome.
//// 3. `fold_update` dispatches by update. A captured cut goes to
////    `reconcile_cut`, a history page to `receive_history`, a refusal to
////    `apply_request_refused`, and a pushed event on to `event_fold.apply_event`.
//// 4. `reconcile_cut` leaves an unchanged cut alone and otherwise calls
////    `apply_cut`, then asks for the worktree and for any pending approval that
////    vanished (`request_visible_worktree`, `request_decisions`).
//// 5. `apply_cut` projects the cut's approvals, calls `render_cut` to rebuild
////    the transcript and surfaces, and `close_settled_approval` shuts a dialog
////    whose question was answered elsewhere.
//// 6. `receive_unlaned` and `service_history` serve a host before or between
////    lanes: a connection event, and the history read a paging control wants.
//// 7. `take_replayed` and `apply_replay_change` are the same fold for a replay:
////    each recorded change goes through `apply_replay_change` in place of a
////    live update.

import core/message
import core/origin
import gleam/bool
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set
import gleam/string
import machine/strand as machine_strand
import session_view/advisor_history
import session_view/advisor_pending
import session_view/agent_messages
import session_view/agent_roster
import session_view/agent_view
import session_view/approval
import session_view/attempt_replay
import session_view/block_summary
import session_view/cache_watch
import session_view/completion_summary
import session_view/connection_event
import session_view/context_view
import session_view/event_fold
import session_view/history_view
import session_view/inbox
import session_view/model.{
  type Interrupt, type Peer, type Shared, type UnconfirmedSubmission,
  AgentMessagesCaptured, ApprovalSettled, ApprovalsPresented, Attached,
  ConnectionLost, Disconnected, GoalReleased, HistoryReleased, HoldGoalReport,
  LookupAnswered, NewSession, OutlookCleared, Preview, QueueRowsCaptured,
  ReplayAdopted, Replaying, SameSession, Shared, UnconfirmedSubmission,
} as session_model
import session_view/notice_words
import session_view/outbound
import session_view/protocol
import session_view/queue_request
import session_view/reviewer_status
import session_view/session_channel
import session_view/shared_set
import session_view/snapshot
import session_view/snapshot_view
import session_view/surfaces
import session_view/todo_board
import session_view/transcript_line.{Line, System}
import session_view/transcript_lines
import session_view/worktree_view

/// What the host shows that decides a shared write inside one update.
///
/// The lane fold reads no host state, but three of its decisions used to:
/// whether a diff is on screen (a new cut then asks for a fresh worktree),
/// whether a notes surface is open (a refused notes read is then reported),
/// and which approval the operator is reviewing (a cut that shows it settled
/// elsewhere then closes the dialog with a line). The host reads these before
/// each update and passes them in. None of them changes during an update:
/// the diff and the notes surface are written only by keys, and the
/// approval under review changes only through the facts an update records,
/// which the host applies after it.
@internal
pub type Surroundings {
  Surroundings(
    /// Whether captured edits are on screen.
    worktree: WorktreeView,
    /// Whether a notes surface is open.
    notes: NotesView,
    /// The approval the host's inspector shows, as it captured it.
    reviewing: Option(approval.Review),
    /// The approval the operator asked to inspect whose lookup has not
    /// answered yet (`/approvals <id>`).
    wanted: Option(String),
  )
}

/// Whether the host shows captured edits.
@internal
pub type WorktreeView {
  WorktreeShown
  WorktreeHidden
}

/// Whether the host shows a notes surface.
@internal
pub type NotesView {
  NotesShown
  NotesHidden
}

/// What a host with no diff, no notes surface and no approval inspector
/// shows, such as a test driving the lane directly.
///
/// ## Examples
///
/// ```gleam
/// lane_fold.apply_channel_update(shared, update, lane_fold.nothing_shown())
/// ```
@internal
pub fn nothing_shown() -> Surroundings {
  Surroundings(
    worktree: WorktreeHidden,
    notes: NotesHidden,
    reviewing: None,
    wanted: None,
  )
}

/// Advances the session channel's timers and returns the updates they
/// produce, for the host to apply one at a time.
///
/// ## Examples
///
/// ```gleam
/// let #(shared, updates) = lane_fold.tick(shared)
/// ```
@internal
pub fn tick(
  shared: Shared(socket, recorder, source, replay_source),
) -> #(
  Shared(socket, recorder, source, replay_source),
  List(session_channel.Update),
) {
  case shared.channel {
    None -> #(shared, [])
    Some(channel) -> {
      let #(channel, updates) =
        session_channel.tick(channel, now: shared.stamp.transport_ms)
      #(session_model.hold_channel(shared, channel), updates)
    }
  }
}

/// Hands one socket message to the adopted lane and returns the updates it
/// produces, for the host to apply one at a time.
///
/// ## Examples
///
/// ```gleam
/// let #(shared, updates) = lane_fold.receive(shared, channel, message)
/// ```
@internal
pub fn receive(
  shared: Shared(socket, recorder, source, replay_source),
  channel: session_channel.Channel(socket, recorder),
  incoming: connection_event.Message,
) -> #(
  Shared(socket, recorder, source, replay_source),
  List(session_channel.Update),
) {
  let #(channel, updates) =
    session_channel.receive(channel, incoming, now: shared.stamp.transport_ms)
  #(session_model.hold_channel(shared, channel), updates)
}

/// Cancels every unsent frame on the lane with `reason` and returns the
/// updates the cancellation produces. With no lane, the pending submission's
/// marker is dropped and there is nothing to apply.
///
/// ## Examples
///
/// ```gleam
/// let #(shared, updates) = lane_fold.cancel_unsent(shared, "cancelled")
/// ```
@internal
pub fn cancel_unsent(
  shared: Shared(socket, recorder, source, replay_source),
  reason: String,
) -> #(
  Shared(socket, recorder, source, replay_source),
  List(session_channel.Update),
) {
  case shared.channel {
    None -> #(shared_set.pending_submission(shared, None), [])
    Some(channel) -> {
      let #(channel, updates) = session_channel.cancel_unsent(channel, reason)
      #(session_model.hold_channel(shared, channel), updates)
    }
  }
}

/// Folds one conversation-channel update into the session state.
///
/// One update is the unit the host applies: it reads its `Surroundings`
/// before the call and applies the surface facts the call recorded after it,
/// before the next update.
///
/// ## Examples
///
/// ```gleam
/// let shared = lane_fold.apply_channel_update(shared, update, around)
/// ```
@internal
pub fn apply_channel_update(
  shared: Shared(socket, recorder, source, replay_source),
  update: session_channel.Update,
  around: Surroundings,
) -> Shared(socket, recorder, source, replay_source) {
  let folded = fold_update(shared, update, around)

  // A reply to a command the lane sent is the one kind of update whose
  // words are an answer rather than news: the lane has one request out at a
  // time, so an acknowledgement, a refusal or a lost reply is the outcome of
  // the command that asked. Any later event may write the notice over, so
  // the reply's words are kept apart in `answer`, where only another reply
  // replaces them. An acknowledgement always words itself. A refusal of one
  // of the host's own automatic reads is no command's outcome, and some are
  // deliberately silent, so neither is an answer; nor is a refusal whose arm
  // left the notice as it was.
  case update {
    session_channel.Acknowledged(..) -> shared_set.answer(folded, folded.notice)
    session_channel.RequestRefused(command:, ..) ->
      case host_read(command) || folded.notice == shared.notice {
        True -> folded
        False -> shared_set.answer(folded, folded.notice)
      }
    session_channel.UnknownOutcome(..) ->
      shared_set.answer(folded, folded.notice)
    _ -> folded
  }
}

// The reads the host issues on its own account: the automatic reads, the
// pending-decisions lookup a capture triggers, the decided-approvals read a
// page makes when it opens, and the history read a host's own paging control
// asks for. A refusal of one is no command's outcome.
fn host_read(command: String) -> Bool {
  case command {
    "history" | "escalations_get" | "escalations_decided" -> True
    _ -> session_channel.is_read(command)
  }
}

fn fold_update(
  shared: Shared(socket, recorder, source, replay_source),
  update: session_channel.Update,
  around: Surroundings,
) -> Shared(socket, recorder, source, replay_source) {
  case update {
    session_channel.Submission(disposition) ->
      outbound.apply_submission(shared, disposition)
    session_channel.Captured(cut, view, trigger) ->
      reconcile_cut(shared, cut, view, trigger, around)
    session_channel.HistoryPage(window, before, after) ->
      receive_history(shared, window, before, after, around)
    session_channel.LookedUp(records, missing) -> {
      // A lookup started before automatic presentation may finish while the
      // operator is reviewing another question. The visible record owns
      // consent until that dialog closes. Otherwise the record the operator
      // asked for opens once it arrives, and the host does that when it
      // applies the fact; the close below judges the record it will show.
      let reviewing = case around.reviewing, around.wanted {
        Some(shown), _ -> Some(shown)
        None, Some(id) ->
          list.find(records, fn(record: approval.Review) { record.id == id })
          |> option.from_result
        None, None -> None
      }
      let updated =
        Shared(
          ..session_model.record_surface(
            shared,
            LookupAnswered(records:, missing:),
          ),
          approvals: approval.decisions(shared.approvals, records, missing),
        )

      // A lookup can be the first to report the open question resolved, for
      // instance when another client answered it, so the reply settles the
      // dialog the same way a cut does rather than waiting for the next one.
      let updated = case updated.captured {
        Some(#(cut, view)) ->
          render_cut(updated, cut, view, updated.approvals)
          |> close_settled_approval(reviewing)
        None -> updated
      }
      case missing {
        [] -> updated
        _ ->
          session_model.append_system(
            updated,
            "Decisions not available: " <> string.join(missing, ", "),
          )
      }
    }
    session_channel.Auxiliary(event) -> event_fold.apply_event(shared, event)
    session_channel.RequestRefused("history", _, code, message) ->
      session_model.append_error(
        shared_set.scrollback(shared, history_view.cancel(shared.scrollback)),
        "Older history: " <> code <> ": " <> message,
      )
    session_channel.RequestRefused(command, request_id, code, message) ->
      apply_request_refused(shared, command, request_id, code, message, around)

    // Nothing here is visible, and that is the point: the count moves for
    // every notice the daemon pushed, including the ones a held sequence or
    // an in-flight refresh made redundant. The rendered frame is untouched,
    // so this cannot invalidate it.
    session_channel.Noticed(_) -> Shared(..shared, notices: shared.notices + 1)

    // A pushed fragment is the same thing the directly attached client
    // receives as a stream delta, so it lands in the same live-stream region
    // by the same route rather than through a second renderer.
    session_channel.Streamed(strand:, operation:, generation:, kind:, text:) ->
      event_fold.apply_event(
        shared,
        protocol.StreamDelta(strand:, operation:, generation:, kind:, text:),
      )
    session_channel.ToolStreamed(
      strand:,
      operation:,
      step:,
      source_index:,
      call_id:,
      stream:,
      text:,
      total_bytes:,
    ) ->
      event_fold.apply_event(
        shared,
        protocol.ToolOutput(
          strand:,
          operation:,
          step:,
          source_index:,
          call_id:,
          stream:,
          text:,
          total_bytes:,
        ),
      )

    // A prompt aimed at a busy strand used to come back as a conflict, with
    // the draft still the operator's problem. The daemon now holds it and
    // runs it on the strand's next turn, so the composer is done with it, and
    // nothing is running here yet, which is why the submitting indicator
    // clears rather than spinning until the held prompt starts. The transcript
    // already shows the line and says it is queued — the echo went in when the
    // frame was written — so this confirms the booking in the footer rather
    // than writing a second copy of the same news. The saved draft leaves the
    // host's editor through the `Saved` notice.
    session_channel.Acknowledged("edit_queued_input", "queued") ->
      shared
      |> shared_set.notice(notice_words.outcome("edit_queued_input", "queued"))
      |> shared_set.queue_request(queue_request.new())
      |> shared_set.queue_notices(
        list.append(shared.queue_notices, [queue_request.Saved]),
      )
      |> session_model.invalidate_frame
    session_channel.Acknowledged("prompt", "queued") ->
      {
        let settled = event_fold.settle_own_turn(shared)
        settled
        |> shared_set.submitting(None)
        |> shared_set.notice(notice_words.outcome("prompt", "queued"))
      }
      |> session_model.invalidate_frame

    // An abort ends the run, and with it every steer and follow-up the run
    // had not started yet: the queue drains those without committing them,
    // so no entry will ever arrive to retire their interjections. A held
    // prompt is not the run's to cancel — it waits in the gateway and drains
    // once the strand is idle — so the abort drops the interjections and
    // leaves the prompt echoes standing.
    session_channel.Acknowledged("abort", status) ->
      {
        let abandoned = event_fold.abandon_interjections(shared)
        shared_set.notice(abandoned, notice_words.outcome("abort", status))
      }
      |> session_model.invalidate_frame

    // Every other acknowledgement settles its submission the same way: a
    // steer answered `admitted` will commit the entry its interjection is
    // waiting for. Commands that record nothing leave `awaiting_outcome`
    // empty and pass through untouched.
    session_channel.Acknowledged(command, status) ->
      {
        let settled = event_fold.settle_own_turn(shared)
        shared_set.notice(settled, notice_words.outcome(command, status))
      }
      |> session_model.invalidate_frame

    // A queue save whose outcome is unknown locks the editor's draft until
    // the operator refreshes it, through the `Unknown` notice.
    session_channel.UnknownOutcome(command, request_id) ->
      session_model.append_error(
        Shared(
          ..{
            shared
            |> shared_set.queue_notices(case command {
              "edit_queued_input" ->
                list.append(shared.queue_notices, [queue_request.Unknown])
              _ -> shared.queue_notices
            })
          },
          unconfirmed: Some(UnconfirmedSubmission(
            shared.session,
            command,
            request_id,
          )),
        ),
        "Last unconfirmed submission: " <> command <> "; not retried",
      )

    // A lost lane refuses the queue editor's save, closes a goal inspector
    // whose board it has just released, and asks the host for the one
    // reconnect a daemon death is allowed.
    session_channel.Failed(reason) ->
      session_model.append_error(
        {
          let discarded = outbound.discard_own_turn(shared)
          Shared(
            ..session_model.record_surface(discarded, GoalReleased),
            peer: after_close(shared.peer),
            ended: Some(reason),
            scrollback: history_view.cancel(shared.scrollback),
            streams: [],
            tool_tails: [],
            jobs_refresh: worktree_view.Settled,
            jobs_awaiting: None,
            jobs_notice: "Live jobs unavailable: conversation disconnected",
            nudges: None,
            nudges_refresh: worktree_view.Settled,
            nudges_awaiting: None,
            nudges_request: None,
            goal: None,
            goal_refresh: worktree_view.Settled,
            goal_awaiting: None,
            goal_request: None,
            goal_report: HoldGoalReport,
            worktree: case shared.worktree.awaiting {
              Some(id) ->
                worktree_view.receive(
                  shared.worktree,
                  session_model.queue_owner(shared),
                  worktree_view.Failed(id, "conversation disconnected"),
                )
              None -> shared.worktree
            },
            queue_request: queue_request.new(),
            queue_notices: list.append(discarded.queue_notices, [
              queue_request.Refused("Disconnected; draft retained"),
            ]),
          )
        },
        "conversation: " <> reason,
      )
      |> session_model.record_surface(ConnectionLost)
  }
}

fn reconcile_cut(
  shared: Shared(socket, recorder, source, replay_source),
  cut: snapshot.Captured,
  view: snapshot_view.View,
  trigger: session_channel.Capture,
  around: Surroundings,
) -> Shared(socket, recorder, source, replay_source) {
  // Equal metadata still advances transport credit, but must not continually
  // restart animation or invalidate a transcript which has not changed. The
  // provenance is recorded only on the arm that paints: a notice-driven
  // catch-up that finds nothing new must not claim the answer a refresh
  // already painted, or a fixture reading it would call polling "push".
  case shared.captured {
    Some(#(previous, _))
      if previous.next_seq == cut.next_seq && previous.metadata == cut.metadata
    ->
      shared_set.captured(shared, Some(#(cut, view)))
      |> close_settled_approval(around.reviewing)
    Some(_) | None -> {
      let updated =
        apply_cut(Shared(..shared, last_capture: trigger), cut, view, around)
      let updated = case shared.captured {
        Some(#(previous, _)) if previous.next_seq == cut.next_seq -> updated
        Some(_) | None -> request_visible_worktree(updated, around.worktree)
      }
      let disappeared =
        shared.approvals
        |> list.filter(fn(old) {
          old.status == approval.Pending
          && !list.any(updated.approvals, fn(new) { new.id == old.id })
        })
        |> list.map(fn(record) { record.id })
      let updated = case list.take(disappeared, 8) {
        [] -> updated
        ids -> request_decisions(updated, ids)
      }
      case list.drop(disappeared, 8) {
        [] -> updated
        _ ->
          session_model.append_system(
            updated,
            "Additional resolutions are not loaded; use /approvals <id>.",
          )
      }
    }
  }
}

/// Asks the session channel to look up the approval records named by
/// `ids`. A replay performs no lookup.
///
/// ## Examples
///
/// ```gleam
/// let shared = lane_fold.request_decisions(shared, ["esc-1"])
/// ```
@internal
pub fn request_decisions(
  shared: Shared(socket, recorder, source, replay_source),
  ids: List(String),
) -> Shared(socket, recorder, source, replay_source) {
  case shared.peer {
    // A replay performs no outbound effect and invents no line the live
    // client was not shown. Whatever the live client learned about these
    // decisions is already in the recording; a "conversation is not
    // attached" error here would be a line no live session ever produced.
    Replaying -> shared

    Attached | Disconnected | Preview ->
      case shared.channel {
        None ->
          session_model.append_error(shared, "conversation is not attached")
        Some(channel) ->
          case
            session_channel.lookup(channel, ids, now: shared.stamp.transport_ms)
          {
            Ok(channel) -> session_model.hold_channel(shared, channel)
            Error(reason) ->
              session_model.append_error(
                shared,
                "decision lookup not sent: " <> reason,
              )
          }
      }
  }
}

/// Applies a captured snapshot cut to the session state, closes the dialog
/// of an approval the cut shows settled elsewhere, and records that the host
/// should present any approval the cut left pending.
///
/// ## Examples
///
/// ```gleam
/// let shared = lane_fold.apply_cut(shared, cut, view, around)
/// ```
@internal
pub fn apply_cut(
  shared: Shared(socket, recorder, source, replay_source),
  cut: snapshot.Captured,
  view: snapshot_view.View,
  around: Surroundings,
) -> Shared(socket, recorder, source, replay_source) {
  let reviews = case approval.records(view.cells) {
    Ok(current) -> approval.project(shared.approvals, current)
    Error(_) -> []
  }
  render_cut(shared, cut, view, reviews)
  |> close_settled_approval(around.reviewing)
}

// Another client attached to the same session can answer the question the
// host's dialog is showing, and nothing the operator does there would then
// be meaningful: the request is no longer pending. The dialog closes once
// the cut holds no pending record with its ID, whether the register now
// reads as resolved or has gone. The check is by ID rather than by exact
// sequence because a pending request whose sequence moved is still the
// question on screen, and the dialog deliberately keeps the revision it
// captured. A dialog opened on a record that was already resolved is a
// deliberate inspection through /approvals, and it stays open whatever the
// cut says.
//
// The line is written here, at the point it always was, and the host closes
// the dialog when it applies `ApprovalSettled`. Presentation of the next
// unseen question follows either way, as `ApprovalsPresented`, so the host
// closes before it presents and the next question opens in the same update.
fn close_settled_approval(
  shared: Shared(socket, recorder, source, replay_source),
  reviewing: Option(approval.Review),
) -> Shared(socket, recorder, source, replay_source) {
  let settled = case reviewing {
    None -> shared
    Some(asked) -> {
      // Both projections keep one record per escalation ID, so the first
      // match is the only one.
      let current =
        list.find(shared.approvals, fn(record) { record.id == asked.id })
      case asked.status, current {
        approval.Pending, Ok(approval.Review(status: approval.Pending, ..))
        | approval.Approved, _
        | approval.Rejected, _
        | approval.Consumed, _
        -> shared

        // The resolved register names its decider when it carries one. A
        // register that has gone names nobody yet; the decision lookup the
        // cut starts adds the author to the approval lines when it returns.
        approval.Pending, Ok(approval.Review(origin: Some(author), ..)) ->
          settle_elsewhere(
            shared,
            asked,
            " by " <> origin.display_label(author),
          )
        approval.Pending, Ok(approval.Review(origin: None, ..))
        | approval.Pending, Error(Nil)
        -> settle_elsewhere(shared, asked, "")
      }
    }
  }
  session_model.record_surface(settled, ApprovalsPresented)
}

fn settle_elsewhere(
  shared: Shared(socket, recorder, source, replay_source),
  asked: approval.Review,
  decider: String,
) -> Shared(socket, recorder, source, replay_source) {
  session_model.append_system(
    session_model.record_surface(shared, ApprovalSettled),
    "Approval "
      <> asked.id
      <> " ("
      <> asked.tool
      <> ") was settled elsewhere"
      <> decider
      <> "; its dialog is closed.",
  )
}

fn render_cut(
  shared: Shared(socket, recorder, source, replay_source),
  cut: snapshot.Captured,
  view: snapshot_view.View,
  reviews: List(approval.Review),
) -> Shared(socket, recorder, source, replay_source) {
  // A disappearing strand never retargets a draft. The composer keeps its
  // identity and submission is refused until that target is available again.
  let active = shared.active_strand
  let shared = observe_completion(shared, cut, view, active)

  // The queue editor's selection follows the row it pointed at into the
  // cut's rows. The editor is the host's, so the rows before and after are
  // recorded here, where the selection used to move.
  let shared =
    session_model.record_surface(
      shared,
      QueueRowsCaptured(
        previous: session_model.queue_rows(shared),
        rows: option.unwrap(view.pending_inputs, [])
          |> list.filter(fn(row) { row.strand == active }),
      ),
    )
  let same_operation = case shared.captured {
    Some(#(_, previous)) ->
      shared.active_strand == active
      && dict.get(previous.operations, shared.active_strand)
      == dict.get(view.operations, active)
    None -> False
  }
  let history =
    history_view.capture(shared.scrollback, cut.window, view, active)
  let branch = history_view.branch(history, view)
  let current_model = case dict.get(view.configurations, active) {
    Ok(config) -> config.configuration.model.model_id
    Error(Nil) -> "unconfigured"
  }
  let cache =
    cache_watch.capture(
      shared.cache,
      option.map(shared.captured, fn(shown) { shown.1 }),
      view,
    )

  // The host's outlook describes the active strand's watch, so a cut that
  // leaves the strand with none clears it.
  let outlook = case dict.get(cache.watches, active) {
    Ok(_) -> []
    Error(Nil) -> [OutlookCleared]
  }
  let role = case cut.attachment.role {
    snapshot.Owner -> "owner"
    snapshot.Operator -> "operator"
    snapshot.Observer -> "observer · read-only"
  }

  // The same coherent presence test governs both turn labels and the
  // attachment banner. A lone owner needs no redundant name or role; every
  // other attachment retains the full identity and participant count.
  let attachment_banner = case transcript_lines.solo_owner(Some(#(cut, view))) {
    Some(_) -> "Attached · 1 present"
    None ->
      "Attached as: "
      <> origin.display_label(cut.attachment.origin)
      <> " · "
      <> role
      <> " · "
      <> int.to_string(list.length(view.peers))
      <> " present"
  }

  // A conversation the window holds from its first entry needs no row to
  // say so; only a trimmed one says where the older entries are.
  let boundary = case branch.unloaded {
    None -> []
    Some(_) ->
      case history.request {
        history_view.Wanted | history_view.Pending(_) -> [
          "Loading older conversation…",
        ]
        history_view.Quiet -> ["Scroll up to load older conversation."]
      }
  }

  // The session facts the head of the transcript states are one block of
  // at most three rows: where the older entries are, the attachment and the
  // shared run settings, and code mode. The model and effort are on the
  // terminal's identity line, so the strand configuration has no row of its
  // own; who last changed it is still said, beside the run settings.
  let head =
    Line(
      System,
      list.flatten([
        boundary,
        [
          attachment_banner
          <> " · "
          <> run_settings(view)
          <> configuration_author(view, active),
        ],
        [code_mode_status(view, active)],
      ])
        |> string.join("\n"),
    )
  let transcript = [
    head,
    ..list.append(
      shared.build_notice,
      list.append(
        extension_refusals(view),
        list.append(
          unconfirmed_lines(shared.unconfirmed),
          approval_lines(reviews),
        ),
      ),
    )
  ]

  // Everything the record projection reads, so a cut that moved only usage,
  // phases or timestamps leaves the cache standing. Cuts arrive on a
  // quarter-second cadence throughout a turn, and invalidating on every one
  // of them made each a full re-projection of the whole session.
  let advisor_history = advisor_history.project(view, cut.window)
  let record_cache_valid =
    shared.record_cache_valid
    && shared.active_strand == active
    && shared.records == branch.records
    && shared.advisor_history == advisor_history
    && shared.transcript == transcript
    && transcript_lines.solo_owner(shared.captured)
    == transcript_lines.solo_owner(Some(#(cut, view)))

  // Request-scoped pushes outrun captures: a cut may have started before
  // the request that is streaming now. Retain those observations, including
  // terminal markers, until an exact durable last result proves retirement.
  // An unrelated idle cut cannot retire a newer request. This fallback also
  // covers relay failures which bypass the optional presentation observer.
  // Legacy recordings retain their operation-based law.
  let operation = dict.get(view.operations, active)
  let live =
    list.filter(shared.streams, fn(stream) {
      stream.strand == active
      && { stream.generation != "" || operation == Ok(stream.operation) }
      && !snapshot_view.has_result(view, active, stream.operation)
      && !transcript_lines.response_recorded(branch.records, stream.generation)
    })

  // A captured tool-result names the exact provider call, so one completed
  // call can retire without removing its still-running peers. The operation's
  // last-result register remains the fallback when the bounded history window
  // no longer retains that entry.
  let live_tails =
    list.filter(shared.tool_tails, fn(tail) {
      !snapshot_view.has_tool_result(
        view,
        cut.window,
        tail.strand,
        tail.call_id,
      )
      && !snapshot_view.has_result(view, tail.strand, tail.operation)
    })

  // A cut that brought new records may bring long blocks this attachment
  // holds no label for. They are marked wanted here and read by exact key
  // when the lane is free; a cut whose records did not move asks nothing.
  // Live labels are kept while their stream is held, on any strand, or
  // while the committed response they would lend to is in the window.
  let summaries = case shared.records == branch.records {
    True -> shared.summaries
    False ->
      block_summary.want(
        shared.summaries,
        transcript_lines.summary_keys(branch.records, active),
      )
  }
  let summaries =
    block_summary.retain_live(summaries, fn(generation) {
      list.any(shared.streams, fn(stream) { stream.generation == generation })
      || transcript_lines.response_recorded(branch.records, generation)
    })

  // Retired strands keep unsent drafts but release their bounded reading
  // windows. A future appearance must rebuild history from its own capture.
  // The host releases the parked editors' reading positions on the same
  // condition when it applies `HistoryReleased`.
  let parked_scrollback =
    prune_parked_scrollback(
      shared.parked_scrollback,
      shared.session,
      view.strands,
    )
  let reviewers =
    reviewer_status.observe(shared.reviewer_rows, cut.window, view)
  let rows = agent_view.observe(shared.agent_rows, cut.window, view, reviewers)
  let captured_messages =
    agent_messages.capture(shared.agent_messages, view, cut.window)

  // A strand whose capture reaches no `todo` call may still have a board
  // in its notes, the usual case after reattaching to a long session, so
  // its first capture asks for one notes read to seed the panel.
  let boards = todo_board.remember(shared.todo_boards, branch.records)
  let #(todo_seed, todo_asked) = case
    todo_board.needs_seed(boards, shared.todo_asked, active)
  {
    True -> #(Some(active), set.insert(shared.todo_asked, active))
    False -> #(shared.todo_seed, shared.todo_asked)
  }
  let facts =
    list.append(outlook, [
      HistoryReleased(session: shared.session, strands: view.strands),
    ])
  Shared(
    ..shared,
    surface_facts: list.append(shared.surface_facts, facts),
    captured: Some(#(cut, view)),
    approvals: reviews,
    active_strand: active,
    strands: view.strands,
    reviewer_rows: reviewers,
    agent_rows: rows,
    roster: agent_roster.observe(shared.roster, view, shared.stamp.now_ms),
    agent_messages: captured_messages,
    advisor_history:,
    todo_boards: boards,
    todo_seed:,
    todo_asked:,
    summaries:,
    records: branch.records,
    scrollback: history,
    parked_scrollback:,
    activity_started_ms: case same_operation {
      True -> shared.activity_started_ms
      False -> None
    },
    activity_elapsed_s: case same_operation {
      True -> shared.activity_elapsed_s
      False -> 0
    },
    usage: view.usage,
    current_model: current_model,
    cache:,
    streams: live,
    tool_tails: live_tails,
    interrupt: reconcile_interrupt(shared.interrupt, view.operations),
    queued: case view.pending_inputs {
      Some(_) -> []
      None -> shared.queued
    },
    submitting: None,
    record_cache_valid:,
    // Presence has its own banner at the head of the transcript and is
    // identity rather than news, so a capture leaves the notice as it was.
    notice: shared.notice,
    transcript:,
  )
  |> event_fold.settle_pending_cache(cut.next_seq)
  |> retire_nudges_delivered_in_cut(cut, view)
  |> session_model.record_surface(AgentMessagesCaptured)
  |> session_model.invalidate_transcript
  // A completed cut can make the operation idle before the next animation
  // tick. Invalidate the painted frame too; rebuilding transcript rows alone
  // leaves the old buffer current until an unrelated key or resize arrives.
  |> session_model.invalidate_frame
  |> session_model.mark_activity
}

// A delivery frame inside the cut retires a held nudges board. The walk is
// over the cut's own main branch rather than the active strand's records:
// while the operator reads history on main, the displayed branch is a window
// frozen at the scroll, and a delivery committed since would never be seen
// there. The walk costs something only while a board is held.
fn retire_nudges_delivered_in_cut(
  shared: Shared(socket, recorder, source, replay_source),
  cut: snapshot.Captured,
  view: snapshot_view.View,
) -> Shared(socket, recorder, source, replay_source) {
  case shared.nudges {
    None -> shared

    Some(_) ->
      surfaces.retire_nudges_delivered_since_board(
        shared,
        snapshot_view.branch(view, cut.window, advisor_pending.primary_strand).records,
      )
  }
}

// The shared run settings, as the head's attachment row carries them.
fn run_settings(view: snapshot_view.View) -> String {
  view.settings.queue_mode
  <> " · "
  <> view.settings.tool_execution
  <> changed_by(view.settings.origin)
}

// Who last changed the strand's model or effort, when a person did. The
// identity line shows the values; this says whose they are.
fn configuration_author(view: snapshot_view.View, active: String) -> String {
  case dict.get(view.configurations, active) {
    Ok(config) ->
      case config.origin {
        Some(author) ->
          " · model and effort changed by " <> origin.display_label(author)
        None -> ""
      }
    Error(Nil) -> ""
  }
}

// An extension the host refused to load is a fact of its own, one row each.
fn extension_refusals(view: snapshot_view.View) -> List(transcript_line.Line) {
  case view.tools {
    None -> []
    Some(tools) ->
      list.map(tools.extension_refusals, fn(reason) { Line(System, reason) })
  }
}

// Availability comes from the live registry; enabling comes from this strand's
// captured configuration. A missing tool must never be described as ready.
fn code_mode_status(view: snapshot_view.View, active: String) -> String {
  case view.tools {
    None -> "code mode · host availability not reported"
    Some(tools) -> {
      let enabled = case dict.get(view.configurations, active) {
        Ok(config) ->
          list.contains(config.configuration.active_tool_names, "code_mode")
        Error(Nil) -> False
      }
      case list.contains(tools.registered, "code_mode"), enabled {
        True, True ->
          "code mode enabled · batches of reads, searches, and checks"
        True, False -> "code mode · disabled for this strand"
        False, _ ->
          "code mode unavailable · "
          <> option.unwrap(tools.code_mode_issue, "not registered by this host")
      }
    }
  }
}

fn changed_by(author: Option(message.Origin)) {
  case author {
    Some(author) -> " · changed by " <> origin.display_label(author)
    None -> ""
  }
}

/// The word a reasoning effort is shown as: `low`, `high`, `max`.
///
/// ## Examples
///
/// ```gleam
/// assert lane_fold.thinking_name(machine_strand.ThinkingLow) == "low"
/// ```
pub fn thinking_name(level: machine_strand.ThinkingLevel) -> String {
  case level {
    machine_strand.ThinkingOff -> "off"
    machine_strand.ThinkingMinimal -> "minimal"
    machine_strand.ThinkingLow -> "low"
    machine_strand.ThinkingMedium -> "medium"
    machine_strand.ThinkingHigh -> "high"
    machine_strand.ThinkingXHigh -> "xhigh"
    machine_strand.ThinkingMax -> "max"
  }
}

fn unconfirmed_lines(unconfirmed: Option(UnconfirmedSubmission)) {
  case unconfirmed {
    None -> []
    Some(last) -> [
      Line(
        System,
        "Last unconfirmed submission: session "
          <> last.session
          <> " · "
          <> last.command
          <> " #"
          <> int.to_string(last.request_id)
          <> "; not retried. Earlier unknown outcomes may remain.",
      ),
    ]
  }
}

/// Transcript lines listing up to eight captured approval decisions, with a
/// note when more are captured.
@internal
pub fn approval_lines(reviews: List(approval.Review)) {
  let lines =
    reviews
    |> list.take(8)
    |> list.map(fn(record) {
      let state = case record.status {
        approval.Pending -> "pending"
        approval.Approved -> "approved"
        approval.Rejected -> "rejected"
        approval.Consumed -> "consumed"
      }
      let author = case record.origin {
        Some(author) -> " · " <> origin.display_label(author)
        None -> ""
      }
      Line(
        System,
        "Approval "
          <> record.id
          <> " · "
          <> state
          <> author
          <> " · "
          <> string.slice(record.preview, 0, 256),
      )
    })
  case list.drop(reviews, 8) {
    [] -> lines
    _ ->
      list.append(lines, [
        Line(
          System,
          "More decisions are captured; /approvals <id> loads an exact decision.",
        ),
      ])
  }
}

/// Applies a socket message that arrived with no lane: the preview peer's
/// traffic, recorded as the untagged arrival it has always written.
///
/// A closed connection asks the host for the one reconnect a daemon death
/// is allowed, as `ConnectionLost`.
///
/// ## Examples
///
/// ```gleam
/// let shared = lane_fold.receive_unlaned(shared, connection_event.Connected)
/// ```
@internal
pub fn receive_unlaned(
  shared: Shared(socket, recorder, source, replay_source),
  incoming: connection_event.Message,
) -> Shared(socket, recorder, source, replay_source) {
  let shared = session_model.record_arrival(shared, incoming)
  case incoming {
    connection_event.Connected ->
      shared_set.notice(shared, "connected")
      |> session_model.mark_activity
      |> session_model.invalidate_frame
    connection_event.Closed(reason) ->
      session_model.append_error(
        shared
          |> shared_set.peer(after_close(shared.peer))
          |> shared_set.streams([])
          |> shared_set.tool_tails([]),
        "connection closed: " <> reason,
      )
      |> session_model.record_surface(ConnectionLost)
      |> session_model.mark_activity
    connection_event.NetworkFault(reason) ->
      session_model.append_error(shared, "network: " <> reason)
      |> session_model.mark_activity
    connection_event.Incoming(text) ->
      case protocol.decode_event(text) {
        Ok(event) -> event_fold.apply_event(shared, event)
        Error(reason) ->
          session_model.append_error(shared, "protocol: " <> reason)
          |> session_model.mark_activity
      }
  }
}

/// History shares the existing correlated read lane. A busy lane leaves one
/// demand pending without blocking input, spawning a worker, or opening a socket.
///
/// ## Examples
///
/// ```gleam
/// let shared = lane_fold.service_history(shared)
/// ```
@internal
pub fn service_history(
  shared: Shared(socket, recorder, source, replay_source),
) -> Shared(socket, recorder, source, replay_source) {
  case history_view.range(shared.scrollback), shared.channel {
    Some(#(after, before)), Some(channel) -> {
      case
        session_channel.history(
          channel,
          after,
          before,
          now: shared.stamp.transport_ms,
        )
      {
        Error(_) -> shared
        Ok(channel) -> {
          let held = session_model.hold_channel(shared, channel)
          shared_set.scrollback(
            held,
            history_view.sent(shared.scrollback, before),
          )
        }
      }
    }
    _, _ -> shared
  }
}

fn receive_history(
  shared: Shared(socket, recorder, source, replay_source),
  window: snapshot.Window,
  before: Int,
  after: Int,
  around: Surroundings,
) -> Shared(socket, recorder, source, replay_source) {
  case shared.captured {
    None -> shared
    Some(#(cut, view)) -> {
      let history =
        history_view.accept(shared.scrollback, window, before, after, view)
      let shared =
        apply_cut(shared_set.scrollback(shared, history), cut, view, around)
      shared_set.render_revision(shared, shared.render_revision + 1)
    }
  }
}

// A coherent cut may skip the idle interval between two queued turns. Match
// the operation, not just the strand's busy flag, when retiring the stop UI.
fn reconcile_interrupt(
  interrupt: Option(Interrupt),
  operations: Dict(String, String),
) -> Option(Interrupt) {
  case interrupt {
    None -> None
    Some(stopped) ->
      case dict.get(operations, stopped.strand), stopped.operation {
        Error(Nil), _ -> None
        Ok(current), Some(previous) if current != previous -> None
        Ok(_), _ -> interrupt
      }
  }
}

// Live transport loss retains the transcript without becoming a design demo.
// A replay remains a replay and cannot fabricate responses after recorded loss.
fn after_close(peer: Peer) -> Peer {
  case peer {
    Attached | Disconnected -> Disconnected
    Preview -> Preview
    Replaying -> Replaying
  }
}

// The shared half of the same pruning: a parked history window is emptied on
// the same condition that resets its workspace's reading position, so the two
// halves of a parked strand are released together.
fn prune_parked_scrollback(
  parked: Dict(#(String, String), history_view.State),
  session: String,
  strands: List(protocol.Strand),
) -> Dict(#(String, String), history_view.State) {
  dict.map_values(parked, fn(owner, scrollback) {
    case retains_history(owner, session, strands) {
      True -> scrollback
      False -> history_view.empty()
    }
  })
}

/// Whether a parked strand keeps its history window: it belongs to the
/// current session and the capture still lists it.
///
/// ## Examples
///
/// ```gleam
/// lane_fold.retains_history(#("s", "main"), "s", strands)
/// ```
@internal
pub fn retains_history(
  owner: #(String, String),
  session: String,
  strands: List(protocol.Strand),
) -> Bool {
  owner.0 == session && session_model.is_known_strand(strands, owner.1)
}

/// Cuts and width transitions request at most one pending refresh. No timer or
/// background Git loop is needed when the workspace and conversation are idle.
///
/// ## Examples
///
/// ```gleam
/// let shared = lane_fold.request_visible_worktree(shared, WorktreeShown)
/// ```
@internal
pub fn request_visible_worktree(
  shared: Shared(socket, recorder, source, replay_source),
  worktree: WorktreeView,
) -> Shared(socket, recorder, source, replay_source) {
  case shared.peer, worktree {
    Attached, WorktreeShown -> refresh_worktree(shared)
    Attached, WorktreeHidden | Preview, _ | Replaying, _ | Disconnected, _ ->
      shared
  }
}

/// Asks for a fresh worktree diff when a live conversation is attached.
///
/// ## Examples
///
/// ```gleam
/// let shared = lane_fold.refresh_worktree(shared)
/// ```
@internal
pub fn refresh_worktree(
  shared: Shared(socket, recorder, source, replay_source),
) -> Shared(socket, recorder, source, replay_source) {
  case shared.peer, shared.channel {
    Attached, Some(_) ->
      shared_set.worktree(
        shared,
        worktree_view.request(
          shared.worktree,
          session_model.queue_owner(shared),
        ),
      )
      |> surfaces.service_worktree_read
    _, _ ->
      shared
      |> shared_set.worktree(worktree_view.new())
      |> shared_set.notice(
        "Captured edits · live worktree observation unavailable",
      )
  }
}

fn observe_completion(
  shared: Shared(socket, recorder, source, replay_source),
  cut: snapshot.Captured,
  view: snapshot_view.View,
  active: String,
) -> Shared(socket, recorder, source, replay_source) {
  let owner =
    session_model.queue_owner(shared_set.captured(shared, Some(#(cut, view))))
  let previous = case shared.completion_owner == owner {
    True -> shared.completion
    False -> completion_summary.new()
  }
  let entries =
    list.filter_map(cut.window.items, fn(item) {
      case item {
        snapshot.Loaded(entry, _) -> Ok(entry)
        snapshot.Unloaded(..) -> Error(Nil)
      }
    })
  let completion = completion_summary.observe(previous, view.cells, entries)
  let changed =
    completion_summary.latest(previous, active)
    != completion_summary.latest(completion, active)
  Shared(
    ..{
      shared
      |> shared_set.worktree(case shared.worktree.owner == owner {
        True -> shared.worktree
        False -> worktree_view.new()
      })
      |> shared_set.jobs(case shared.completion_owner == owner {
        True -> shared.jobs
        False -> None
      })
      |> shared_set.jobs_awaiting(case shared.completion_owner == owner {
        True -> shared.jobs_awaiting
        False -> None
      })
      |> shared_set.jobs_refresh(case changed {
        True -> worktree_view.Requested
        False -> shared.jobs_refresh
      })
    },
    completion:,
    completion_owner: owner,
  )
}

fn apply_request_refused(
  shared: Shared(socket, recorder, source, replay_source),
  command: String,
  request_id: Int,
  code: String,
  message: String,
  around: Surroundings,
) -> Shared(socket, recorder, source, replay_source) {
  use <- bool.lazy_guard(command == "context", fn() {
    shared_set.context(
      shared,
      context_view.refused(shared.context, request_id, code, message),
    )
    |> session_model.invalidate_frame
  })

  // Every goal command is refused worded and nowhere else: an older daemon
  // refuses all five, and an operator watching a panel fail to appear has
  // no way to tell that from a session with no goal.
  use <- bool.lazy_guard(string.starts_with(command, "goal_"), fn() {
    surfaces.refuse_goal(shared, command, request_id, code, message)
  })

  // Labels are optional presentation read with no operator keystroke. An
  // older daemon refuses the read outright, and a row reporting it would
  // be the one visible trace of a feature the operator never asked for, so
  // the terminal stops asking for this attachment and says nothing.
  use <- bool.lazy_guard(command == "block_summaries", fn() {
    shared_set.summaries(shared, block_summary.refused(shared.summaries))
  })

  // The decided-approvals read a page makes when it opens is no command of
  // the operator's. An older daemon refuses it as unknown and a session over
  // the metadata budget refuses it as failed; either way the page keeps the
  // decisions it saw live and says nothing.
  use <- bool.lazy_guard(command == "escalations_decided", fn() { shared })

  // The read of what the session remembers is the page's own as well. A
  // daemon that does not know it leaves the page's list unread, which the
  // page says in its own words, and a footer error every half minute would
  // be the only other trace.
  use <- bool.lazy_guard(command == "permissions", fn() { shared })

  // A notes read refused while no notes surface is open was the todo
  // panel's seed. An older daemon refuses it, and an error row would report
  // a read the operator never asked for.
  use <- bool.lazy_guard(
    command == "notes" && around.notes == NotesHidden,
    fn() { shared },
  )
  let reason = code <> ": " <> message
  let updated = case command {
    "queued_input" | "edit_queued_input" ->
      case shared.queue_request.request_id == Some(request_id) {
        True ->
          shared
          |> shared_set.queue_request(queue_request.new())
          |> shared_set.queue_notices(
            list.append(shared.queue_notices, [
              queue_request.Refused(reason),
            ]),
          )
        False -> shared
      }

    // A forget that lost its guard changed nothing, and the list it was made
    // from is out of date, so the page reads it again.
    "permission_forget" ->
      shared_set.remembered_refresh(shared, worktree_view.Requested)
    "live_jobs" ->
      case shared.jobs_request == Some(request_id) {
        True ->
          shared
          |> shared_set.jobs_request(None)
          |> shared_set.jobs_awaiting(None)
          |> shared_set.jobs_notice("Live jobs unavailable: " <> reason)
        False -> shared
      }

    // A refused observation draws nothing. The panel is unobtrusive context
    // beside the composer, and an error line there would cost a row of the
    // conversation to report a read the operator never asked for; an older
    // daemon that does not know the command refuses every one of them.
    "advisor_pending" ->
      case shared.nudges_request == Some(request_id) {
        True ->
          shared
          |> shared_set.nudges(None)
          |> shared_set.nudges_request(None)
          |> shared_set.nudges_awaiting(None)
        False -> shared
      }
    "worktree_diff" ->
      shared_set.worktree(
        shared,
        worktree_view.receive(
          shared.worktree,
          session_model.queue_owner(shared),
          worktree_view.Failed(request_id, reason),
        ),
      )
    _ -> shared
  }
  event_fold.apply_event(updated, protocol.ServerError(code, message))
}

/// Takes the one recorded attempt event the runtime received before this
/// step and returns the changes it makes, for the host to apply one at a
/// time. A malformed event stops the replay with its reason.
///
/// The runtime reads the replay inbox only while the peer is `Replaying`,
/// but a host that delivers `msg.Arrived` itself can still admit an event
/// outside replay. That event is taken and dropped, as it always was, so it
/// cannot wait in the inbox for a later replay to apply.
///
/// ## Examples
///
/// ```gleam
/// let #(shared, changes) = lane_fold.take_replayed(shared)
/// ```
@internal
pub fn take_replayed(
  shared: Shared(socket, recorder, source, replay_source),
) -> #(
  Shared(socket, recorder, source, replay_source),
  List(attempt_replay.Change),
) {
  let #(replay_inbox, next) = inbox.take(shared.replay_inbox)
  let shared = shared_set.replay_inbox(shared, replay_inbox)
  case shared.peer, next {
    Replaying, Ok(event) ->
      case attempt_replay.apply(shared.replay_state, event) {
        Error(reason) -> #(
          session_model.append_error(
            Shared(
              ..{
                shared
                |> shared_set.quit(True)
              },
              replay_error: Some(reason),
            ),
            reason,
          ),
          [],
        )
        Ok(#(state, changes)) -> #(
          Shared(..shared, replay_state: state),
          changes,
        )
      }
    _, _ -> #(shared, [])
  }
}

/// Applies one change a replayed attempt event produced.
///
/// An adopted attempt switches the workspace to its session, resets what
/// belonged to the previous capture, and applies its cut; the host forgets
/// its note selection and approval prompts when it applies `ReplayAdopted`.
/// Every update, cuts included, goes through `apply_channel_update`, so a
/// replay renders the frames the live client did.
///
/// ## Examples
///
/// ```gleam
/// let shared = lane_fold.apply_replay_change(shared, change, around)
/// ```
@internal
pub fn apply_replay_change(
  shared: Shared(socket, recorder, source, replay_source),
  change: attempt_replay.Change,
  around: Surroundings,
) -> Shared(socket, recorder, source, replay_source) {
  case change {
    attempt_replay.RequestedHistory(before) ->
      shared_set.scrollback(
        shared,
        history_view.sent(history_view.freeze(shared.scrollback), before),
      )
    attempt_replay.Rejected(reason) ->
      session_model.append_error(shared, "open session: " <> reason)
    attempt_replay.Adopt(cut, view) -> {
      let session = cut.attachment.expected.session
      let same_session = shared.session == session
      let shared =
        event_fold.select_workspace(shared, session, case same_session {
          True -> shared.active_strand
          False -> "main"
        })
      Shared(
        ..session_model.record_surface(
          shared,
          ReplayAdopted(case same_session {
            True -> SameSession
            False -> NewSession
          }),
        ),
        session:,
        captured: None,
        scrollback: case same_session {
          True -> history_view.cancel(shared.scrollback)
          False -> shared.scrollback
        },
        note_board: None,
        notes_requested: None,
        approvals: [],
        records: [],
        streams: [],
        tool_tails: [],
        models: [],
        skills: [],
        current_model: "loading…",
        active_strand: case same_session {
          True -> shared.active_strand
          False -> "main"
        },
        record_cache_valid: False,
        submitting: None,
        interrupt: None,
      )
      |> apply_cut(cut, view, around)
      // Every update, cuts included, goes through the live reducer. A cut used
      // to be special-cased into `apply_cut`, which always invalidates the
      // transcript and restarts the activity indicator; `reconcile_cut`'s
      // equal-cut fast path is what the live client does instead, and a replay
      // that rendered frames the live client did not is not a replay. The
      // outbound half of that path is made inert by `request_decisions`, which
      // sends nothing while the peer is `Replaying`.
    }
    attempt_replay.Update(update) ->
      apply_channel_update(shared, update, around)
  }
}
