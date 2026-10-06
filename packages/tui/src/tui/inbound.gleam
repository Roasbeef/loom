//// Applies what the session channel delivers to the model.
////
//// The websocket actor owns transport I/O; this module owns what the
//// traffic means. `drain_connection` takes a bounded batch from the
//// connection inbox, and `apply_channel_update` folds each channel update
//// into the model. A captured snapshot cut reaches the transcript,
//// approvals, workspaces and cache watches through `apply_cut`.
////
//// Each pushed event (stream fragments, tool output tails, durable entries,
//// strand phases, usage and the replies to side-surface reads) goes to the
//// shared event fold, `event_fold.apply_event`, which takes the session
//// state alone. `run_settled` calls a fold and then applies what it recorded
//// for the terminal's own surfaces (`settle_surfaces`): the editor on a
//// workspace switch, the model selector, the cache outlook, the notes panel,
//// the summary's job cursor and a returned draft.
////
//// ## Flow
////
//// `drain_connection` → `handle_connection_message` → `apply_channel_update`
//// → `run_settled` → `settle_surfaces` → `show_surface`
////
//// 1. `drain_connection` takes a batch from the adopted inbox with
////    `take_connection` and records whether it stopped at the batch.
//// 2. `handle_connection_message` gives one message to the session channel
////    through `lane_fold.receive`, which answers with channel updates.
//// 3. `tick_channel` is the timer's way in: `lane_fold.tick` yields the same
////    updates when a deadline or the idle refresh falls due.
//// 4. `apply_channel_update` reads `surroundings`, then folds one update
////    through `run_settled`, which holds the result and settles it.
//// 5. `settle_surfaces` replays each recorded fact through `show_surface`,
////    then `restore_returned_drafts` moves returned drafts to the editors.
//// 6. `show_surface` writes one fact to the terminal; a lost connection ends
////    in `begin_reconnect`, which asks `reconnect_decision` if one is owed.

import core/json
import core/message
import core/register
import etui/widgets/textarea as text_area
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import session_view/agent_messages
import session_view/agent_roster
import session_view/approval
import session_view/commands
import session_view/connection_event
import session_view/event_fold
import session_view/lane_fold
import session_view/model.{ReturnedDraft, Shared} as session_model
import session_view/msg
import session_view/notes_view
import session_view/operator
import session_view/protocol
import session_view/session_channel
import session_view/shared_set
import session_view/snapshot
import session_view/snapshot_view
import tui/agent_message_panel
import tui/agent_strip
import tui/agents
import tui/approval_panel
import tui/bootstrap
import tui/buffered
import tui/job
import tui/layout
import tui/model.{
  type Model, type Reconnect, type StrandWorkspace, AccessManager,
  AgentInspector, ApprovalInspector, DaemonSelector, GoalInspector, Model,
  ModelSelector, NoOverlay, PeerLinkManager, PromptNext, ReconnectAttempting,
  ReconnectIdle, ReconnectSpent, StrandWorkspace, View,
} as tui_model
import tui/model_selector
import tui/note_panel
import tui/queue_editor
import tui/queue_panel
import tui/render
import tui/side_surfaces
import tui/summary_panel
import tui/view_set

// What `reconnect_decision` produced: the work to do, or the reason there is
// none. The reason is carried rather than dropped so the caller can say why
// rather than leaving the operator with a silent terminal.
type ReconnectDecision {
  ReconnectWanted(session: String, options: bootstrap.Options)

  ReconnectRefused(reason: String)
}

/// Decides whether one unexpected daemon death earns a reconnect.
///
/// The decision is a pure read of the terminal's own state, taken at the
/// moment the transport reported the loss, so it can be reasoned about (and
/// tested) without a daemon. The three refusals are each a different fact:
/// an operator quit is not a failure to recover from, a remote attachment has
/// no launch to re-run, and an attempt already spent means the operator is
/// owed an error rather than a loop.
fn reconnect_decision(model: Model) -> ReconnectDecision {
  case model.shared.quit {
    True -> ReconnectRefused("the terminal is closing")
    False ->
      case model.shared.session {
        "" -> ReconnectRefused("no session is attached")
        session ->
          case model.view.local_options {
            None -> ReconnectRefused("this attachment was not launched locally")
            Some(options) ->
              reconnect_state_decision(model.view.reconnect, session, options)
          }
      }
  }
}

// The innermost question, split out so the decision above reads as the
// three facts it is deciding between rather than four nested cases. A
// terminal that has already spent its one attempt waits for the operator
// instead of looping, and one whose attempt is still running must not
// start a second beside it.
fn reconnect_state_decision(
  reconnect: Reconnect,
  session: String,
  options: bootstrap.Options,
) -> ReconnectDecision {
  case reconnect {
    ReconnectIdle -> ReconnectWanted(session, options)
    ReconnectAttempting(..) ->
      ReconnectRefused("a reconnect is already running")
    ReconnectSpent -> ReconnectRefused("the attempt was already made")
  }
}

// Enters the one bounded reconnect an unexpected daemon death is allowed.
//
// Called from the two places a live conversation reports its loss — the
// directly attached socket and the credited session channel — so the
// decision is made once, at the transition, rather than at each caller. The
// transcript is deliberately untouched: the model already holds it, and a
// relaunch that fails must leave it exactly where the operator left it.
fn begin_reconnect(model: Model) -> Model {
  case reconnect_decision(model) {
    ReconnectRefused(_) -> model
    ReconnectWanted(session, options) -> {
      // The relaunch runs as a job because it blocks: it may take the
      // launch lock, start a daemon, and authenticate two sockets. The
      // spec carries the launch options and nothing else of the model.
      let #(model, key) = tui_model.start_job(model, job.Reconnect(options))
      Model(
        shared: shared_set.notice(
          model.shared,
          "reconnecting to session " <> session,
        ),
        view: view_set.reconnect(
          model.view,
          ReconnectAttempting(job.awaiting(key)),
        ),
      )
      |> tui_model.invalidate_frame
    }
  }
}

/// Advances the session channel's timers and applies every update they
/// produce, one at a time, then services a pending history read.
///
/// ## Examples
///
/// ```gleam
/// let model = inbound.tick_channel(model)
/// ```
@internal
pub fn tick_channel(model: Model) -> Model {
  case model.shared.channel {
    None -> model
    Some(_) -> {
      let #(shared, updates) = lane_fold.tick(model.shared)
      list.fold(
        updates,
        tui_model.hold_shared(model, shared),
        apply_channel_update,
      )
      |> tui_model.run_shared(lane_fold.service_history)
    }
  }
}

/// Folds one conversation-channel update into the model: the shared lane
/// fold's `lane_fold.apply_channel_update`, given what the terminal shows,
/// and then the surface facts it recorded.
///
/// This is the host's unit of the lane fold. The terminal reads its
/// `Surroundings` before the update and applies the facts after it, so the
/// next update sees every terminal write this one caused. Public because it
/// is also the boundary a test drives to deliver a daemon reply without
/// standing up a socket.
///
/// ## Examples
///
/// ```gleam
/// let model = inbound.apply_channel_update(model, update)
/// ```
pub fn apply_channel_update(
  model: Model,
  update: session_channel.Update,
) -> Model {
  let around = surroundings(model)
  run_settled(model, lane_fold.apply_channel_update(_, update, around))
}

/// What the terminal shows that a decision inside one update reads: whether
/// captured edits or a notes surface are on screen, the approval the
/// inspector shows, and the approval `/approvals <id>` is waiting for.
///
/// ## Examples
///
/// ```gleam
/// let around = inbound.surroundings(model)
/// ```
@internal
pub fn surroundings(model: Model) -> lane_fold.Surroundings {
  lane_fold.Surroundings(
    worktree: worktree_view_of(model),
    notes: case side_surfaces.notes_surface(model) {
      True -> lane_fold.NotesShown
      False -> lane_fold.NotesHidden
    },
    reviewing: case model.view.overlay {
      ApprovalInspector(panel) -> Some(approval_panel.review(panel))
      NoOverlay
      | ModelSelector(_)
      | AgentInspector(_)
      | GoalInspector(_)
      | DaemonSelector(_)
      | PeerLinkManager(_)
      | AccessManager(_) -> None
    },
    wanted: model.view.inspecting_approval,
  )
}

// Whether captured edits are on screen, in the lane fold's terms.
fn worktree_view_of(model: Model) -> lane_fold.WorktreeView {
  case layout.diff_shown(model) {
    True -> lane_fold.WorktreeShown
    False -> lane_fold.WorktreeHidden
  }
}

/// Asks the session channel to look up the approval records named by
/// `ids`. A replay performs no lookup.
///
/// The terminal's form of `lane_fold.request_decisions`.
///
/// ## Examples
///
/// ```gleam
/// let model = inbound.request_decisions(model, ["esc-1"])
/// ```
@internal
pub fn request_decisions(model: Model, ids: List(String)) -> Model {
  tui_model.run_shared(model, lane_fold.request_decisions(_, ids))
}

/// Applies a captured snapshot cut to the model and then presents any
/// approval the cut left pending.
///
/// The terminal's form of `lane_fold.apply_cut`, which settles the facts
/// the cut recorded.
///
/// ## Examples
///
/// ```gleam
/// let model = inbound.apply_cut(model, cut, view)
/// ```
@internal
pub fn apply_cut(
  model: Model,
  cut: snapshot.Captured,
  view: snapshot_view.View,
) -> Model {
  let around = surroundings(model)
  run_settled(model, lane_fold.apply_cut(_, cut, view, around))
}

// A question is offered once per exact sequence. Deferring one leaves it in
// /approvals, while a reopened request with the same ID is a new question.
fn present_pending_approval(model: Model) -> Model {
  case model.view.overlay, model.shared.captured {
    NoOverlay, Some(#(cut, _)) if cut.attachment.role != snapshot.Observer -> {
      let seen =
        list.filter(model.view.prompted_approvals, fn(identity) {
          list.any(model.shared.approvals, fn(record) {
            #(record.id, record.seq) == identity
          })
        })
      let unseen =
        list.find(model.shared.approvals, fn(record) {
          record.status == approval.Pending
          && !list.contains(seen, #(record.id, record.seq))
        })
      case unseen {
        Error(Nil) ->
          Model(..model, view: view_set.prompted_approvals(model.view, seen))
        Ok(record) ->
          Model(
            ..model,
            view: model.view
              |> view_set.prompted_approvals([#(record.id, record.seq), ..seen])
              |> view_set.overlay(
                ApprovalInspector(captured_approval_panel(model, record)),
              ),
          )
      }
    }
    _, _ -> model
  }
}

fn inspect_looked_up(model: Model, records, missing) {
  // A lookup started before automatic presentation may finish while the
  // operator is reviewing another question. The visible record owns consent
  // until that dialog closes, including its selection and scroll position.
  case model.view.overlay, model.view.inspecting_approval {
    ApprovalInspector(_), _ ->
      Model(..model, view: view_set.inspecting_approval(model.view, None))
    _, Some(id) ->
      case list.find(records, fn(record: approval.Review) { record.id == id }) {
        Ok(record) ->
          Model(
            ..model,
            view: model.view
              |> view_set.overlay(
                ApprovalInspector(captured_approval_panel(model, record)),
              )
              |> view_set.inspecting_approval(None),
          )
        Error(Nil) ->
          case list.contains(missing, id) {
            True ->
              Model(
                ..model,
                view: view_set.inspecting_approval(model.view, None),
              )
            False -> model
          }
      }
    _, None -> model
  }
}

/// The panel returns its captured review. Looking the ID up again here would
/// replace the displayed question with a newer record the operator never saw.
///
/// The terminal's form of `commands.decide_review`, which takes the panel's
/// choice in the session's terms. The dialog closes when the decision is
/// handed to the lane (`ReviewAnswered`) and stays open when it is refused.
///
/// ## Examples
///
/// ```gleam
/// let model =
///   inbound.decide_captured_approval(model, record, approval_panel.Deny)
/// ```
@internal
pub fn decide_captured_approval(
  model: Model,
  record: approval.Review,
  choice: approval_panel.Choice,
) -> Model {
  let choice = case choice {
    approval_panel.AllowOnce -> operator.AllowOnce
    approval_panel.AllowSession -> operator.AllowForSession
    approval_panel.Deny -> operator.Deny
  }
  run_settled(model, commands.act(_, msg.Decide(review: record, choice:)))
}

/// Applies at most `remaining` of the messages the runtime received into
/// the connection inbox before this step.
///
/// It reads no mailbox. A message that arrived during the step waits for
/// the next one, whose receive files it behind anything still held.
/// Each message is taken from whatever inbox the model holds at that
/// moment, so a drain that follows an adoption in the same step reads the
/// adopted inbox and never the one it replaced.
///
/// It also records whether it stopped at its batch
/// (`Model.connection_backlog`), which is what keeps the loop polling on
/// its own while a burst larger than one batch is still in the mailbox.
@internal
pub fn drain_connection(model: Model, remaining: Int) -> Model {
  // The runtime tops the buffer up to one batch before the step, so a buffer
  // holding at least what this drain may take is one whose read filled its
  // room and may have left frames in the mailbox.
  let connection_backlog = case buffered.held(model.shared.inbox) >= remaining {
    True -> session_model.MailboxMayHoldMore
    False -> session_model.MailboxDrained
  }
  let drained =
    operator.drain(model, remaining, take_connection, handle_connection_message)

  // The model is a wide record, so it is copied only when the answer moved,
  // which keeps an idle tick's allocation where it was.
  case drained.shared.connection_backlog == connection_backlog {
    True -> drained
    False ->
      Model(
        ..drained,
        shared: shared_set.connection_backlog(
          drained.shared,
          connection_backlog,
        ),
      )
  }
}

// The oldest message the adopted inbox holds, taken from whatever inbox the
// model holds now, so a drain that follows an adoption reads the new one.
fn take_connection(
  model: Model,
) -> #(Model, Result(connection_event.Message, Nil)) {
  let #(inbox, next) = buffered.take(model.shared.inbox)
  #(Model(..model, shared: shared_set.inbox(model.shared, inbox)), next)
}

/// Applies an already selected socket message through the shipped reducer.
///
/// A driver calls this before running later ticks, rather than requeueing into
/// a concurrently written inbox and potentially placing newer traffic first.
///
/// ## Examples
///
/// ```gleam
/// // tui.accept_connection_message(model, incoming)
/// ```
@internal
pub fn accept_connection_message(
  model: Model,
  incoming: connection_event.Message,
) -> Model {
  handle_connection_message(model, incoming)
}

// One socket message. With a lane, the lane turns it into updates and each
// is applied as its own unit. With none, it is the preview peer's traffic,
// applied as one call.
fn handle_connection_message(
  model: Model,
  incoming: connection_event.Message,
) -> Model {
  case model.shared.channel {
    Some(channel) -> {
      let #(shared, updates) =
        lane_fold.receive(model.shared, channel, incoming)
      list.fold(
        updates,
        tui_model.hold_shared(model, shared),
        apply_channel_update,
      )
    }
    None -> run_settled(model, lane_fold.receive_unlaned(_, incoming))
  }
}

/// Applies what a call into the event fold or the lane fold recorded for the
/// terminal's surfaces, oldest first, and then moves any returned drafts
/// into the editors.
///
/// `before` is the model the shared call started from and `held` the model
/// once its result was held. These writes used to happen inside the call, at
/// the point each fact is recorded. Applying them after the call gives the
/// same model because nothing the fold does after recording a fact reads the
/// terminal state the fact writes: the decisions inside an update that read
/// terminal state take it from the `Surroundings` read before the call. They
/// run after each update rather than in `settle_update`, at the end of the
/// step, because one step applies many updates and a later update reads
/// what an earlier one wrote: a cut presents a question that the next cut
/// may show settled elsewhere, a stream fragment replaces the notice a notes
/// board set, and a returned draft has to be in the composer before a later
/// switch parks it.
///
/// A call held without this leaves its facts for the next call that
/// settles, which would apply them against that call's `before`, so a call
/// that may record one goes through `run_settled`. The
/// terminal forms that hold without settling (`request_decisions`,
/// `service_history`, `request_visible_worktree`, `refresh_worktree`, the
/// lane's `tick`, `receive` and `cancel_unsent`, `commands.decide`,
/// `surfaces.submit_goal_action` and the step's settle) reach no function
/// that records a fact; one that starts to must settle too. The commands
/// that record one (`commands.interrupt_active`, `stop_strand`,
/// `decide_review`, `select_model`, `focus` and `load_strand`) are settled by
/// their terminal forms.
///
/// ## Examples
///
/// ```gleam
/// let model = inbound.settle_surfaces(model, tui_model.run_shared(model, f))
/// ```
@internal
pub fn settle_surfaces(before: Model, held: Model) -> Model {
  let settled = case held.shared.surface_facts {
    [] -> held
    facts ->
      list.fold(
        facts,
        Model(..held, shared: shared_set.surface_facts(held.shared, [])),
        fn(model, fact) { show_surface(before, model, fact) },
      )
  }
  case settled.shared.returned_drafts {
    [] -> settled
    _ -> restore_returned_drafts(settled)
  }
}

/// Runs `reducer`, a function over the shared record alone, on this model's
/// shared record, holds the result, and settles the surface facts it
/// recorded against `model`.
///
/// This is `settle_surfaces(model, tui_model.run_shared(model, reducer))`.
/// Every call into a fold or a command that may record a fact goes through
/// it, so no call can hold its result and leave its facts for a later call
/// to settle against the wrong `before`.
///
/// ## Examples
///
/// ```gleam
/// let model = inbound.run_settled(model, commands.interrupt_active)
/// ```
@internal
pub fn run_settled(
  model: Model,
  reducer: fn(tui_model.TerminalShared) -> tui_model.TerminalShared,
) -> Model {
  settle_surfaces(model, tui_model.run_shared(model, reducer))
}

// One fact, applied to the terminal state it stands for.
fn show_surface(
  before: Model,
  model: Model,
  fact: session_model.SurfaceFact,
) -> Model {
  case fact {
    session_model.WorkspaceSwitched(departing:, arriving:, previous_session:) ->
      switch_editor(before, model, departing, arriving, previous_session)
    session_model.SessionSynchronized ->
      Model(
        ..model,
        view: model.view
          |> view_set.record_gutters([])
          |> view_set.scroll_offset(0),
      )

    // An open model selector lists what the daemon just named.
    session_model.ModelsListed(models:, current:) -> {
      let overlay = case model.view.overlay {
        ModelSelector(selector) ->
          ModelSelector(model_selector.replace_models(selector, models, current))
        NoOverlay -> NoOverlay
        AgentInspector(selected) -> AgentInspector(selected)
        GoalInspector(state) -> GoalInspector(state)
        DaemonSelector(selector) -> DaemonSelector(selector)
        PeerLinkManager(state) -> PeerLinkManager(state)
        AccessManager(state) -> AccessManager(state)
        ApprovalInspector(panel) -> ApprovalInspector(panel)
      }
      Model(..model, view: view_set.overlay(model.view, overlay))
    }

    session_model.OutlookCleared ->
      Model(..model, view: view_set.cache_outlook(model.view, ""))

    session_model.NotesArrived(board:) -> show_notes(model, board)

    // The summary's cursor follows the job it pointed at in the board being
    // replaced.
    session_model.JobsReplaced(previous:, board:) ->
      Model(
        ..model,
        view: view_set.summary_job_selected(
          model.view,
          summary_panel.follow_selected_job(
            model.view.summary_job_selected,
            previous,
            board,
          ),
        ),
      )

    session_model.LookupAnswered(records:, missing:) ->
      inspect_looked_up(model, records, missing)

    // The fold has written the line; the dialog closes before the next
    // unseen question is presented.
    session_model.ApprovalSettled ->
      Model(..model, view: view_set.overlay(model.view, NoOverlay))
    session_model.ApprovalsPresented -> present_pending_approval(model)

    session_model.QueueRowsCaptured(previous:, rows:) ->
      follow_queue_selection(before, model, previous, rows)

    // Retired strands keep unsent drafts but release their bounded reading
    // windows, as the fold released their parked history.
    session_model.HistoryReleased(session:, strands:) ->
      Model(
        ..model,
        view: view_set.strand_workspaces(
          model.view,
          prune_workspace_history(
            model.view.strand_workspaces,
            session,
            strands,
          ),
        ),
      )
    session_model.AgentMessagesCaptured ->
      reconcile_agent_message_selection(model)

    session_model.GoalReleased ->
      Model(
        ..model,
        view: view_set.overlay(model.view, case model.view.overlay {
          GoalInspector(_) -> NoOverlay
          other -> other
        }),
      )
    session_model.ConnectionLost -> begin_reconnect(model)

    // Input typed after an interrupt is released with the held input, never
    // steered into the stopping turn.
    session_model.InterruptRequested ->
      Model(..model, view: view_set.submission_mode(model.view, PromptNext))

    // The decision is on its way, so the question leaves the screen.
    session_model.ReviewAnswered ->
      Model(..model, view: view_set.overlay(model.view, NoOverlay))

    // The dispatch consumed the draft. Its text goes into the input
    // history either way; a prompt also returns the composer to prompting,
    // as the session state has already dropped the attachments it carried.
    session_model.DraftTaken(taking:) -> {
      let cleared = tui_model.clear_composer_text(model)
      case taking {
        session_model.TakenByCommand -> cleared
        session_model.TakenAsPrompt ->
          Model(
            ..cleared,
            view: view_set.submission_mode(cleared.view, PromptNext),
          )
      }
    }

    // The rows the gutters were drawn beside are gone.
    session_model.TranscriptCleared ->
      Model(..model, view: view_set.record_gutters(model.view, []))

    // The dialog opens on this record when the lookup answers
    // (`LookupAnswered`).
    session_model.LookupRequested(id:) ->
      Model(..model, view: view_set.inspecting_approval(model.view, Some(id)))

    // A replay's adoption leaves nothing of the previous capture's prompts or
    // note selection, and a new session starts its transcript at the tail.
    session_model.ReplayAdopted(session:) ->
      Model(
        ..model,
        view: model.view
          |> view_set.note_selected(None)
          |> view_set.prompted_approvals([])
          |> view_set.inspecting_approval(None)
          |> view_set.scroll_offset(case session {
            session_model.SameSession -> model.view.scroll_offset
            session_model.NewSession -> 0
          }),
      )
  }
}

// A notes board belongs to the notes surface when it is for the strand that
// surface shows: the agent inspector's strand while its Notes tab is open,
// the active strand otherwise. That board replaces `note_board`, keeps the
// selection on the same note where it can, and keeps the scroll while the
// selection holds. Any other board only seeded the todo panel, which the
// event fold has already done.
fn show_notes(model: Model, board: notes_view.Board) -> Model {
  case board.strand == side_surfaces.notes_target(model) {
    False -> model
    True -> {
      let previous = case model.shared.note_board {
        Some(old) if old.strand == board.strand ->
          render.selected_note(model, old)
        _ -> model.view.note_selected
      }
      let selected =
        render.selected_note(
          Model(..model, view: view_set.note_selected(model.view, previous)),
          board,
        )
      let scroll = case
        model.shared.note_board,
        selected == model.view.note_selected
      {
        Some(old), True if old.strand == board.strand ->
          int.min(
            model.view.note_scroll,
            note_max_scroll(Model(
              shared: shared_set.note_board(model.shared, Some(board)),
              view: view_set.note_selected(model.view, selected),
            )),
          )
        None, True | Some(_), True | None, False | Some(_), False -> 0
      }
      tui_model.invalidate_transcript(Model(
        shared: Shared(
          ..model.shared,
          note_board: Some(board),
          // A read the terminal sent to seed the todo panel is not
          // news to an operator who has no notes surface open.
          notice: case side_surfaces.notes_surface(model) {
            True -> "notes refreshed for " <> board.strand
            False -> model.shared.notice
          },
        ),
        view: model.view
          |> view_set.note_selected(selected)
          |> view_set.note_scroll(scroll),
      ))
    }
  }
}

// Moves every returned draft the session state holds into the terminal's
// editors, oldest first, and empties `Shared.returned_drafts`.
//
// A return follows the prompt's original recipient even if the operator has
// opened another strand since submitting it, so only that strand's editor
// can accept the text: the composer when the strand is the one on screen,
// and its parked workspace otherwise. An untouched editor simply becomes the
// draft. One the operator is typing in keeps its text and grows the return
// below it, separated by a blank line: discarding either half would lose
// work the operator can see, and silently replacing the draft would move
// text out from under the cursor.
fn restore_returned_drafts(model: Model) -> Model {
  let view =
    list.fold(model.shared.returned_drafts, model.view, fn(view, returned) {
      let ReturnedDraft(session:, strand:, text:) = returned
      case
        session == model.shared.session && strand == model.shared.active_strand
      {
        True -> view_set.input(view, append_returned_text(view.input, text))
        False -> {
          let owner = #(session, strand)
          let saved =
            dict.get(view.strand_workspaces, owner)
            |> result.unwrap(empty_workspace())
          let saved =
            StrandWorkspace(
              ..saved,
              input: append_returned_text(saved.input, text),
            )
          view_set.strand_workspaces(
            view,
            dict.insert(view.strand_workspaces, owner, saved),
          )
        }
      }
    })
  Model(shared: Shared(..model.shared, returned_drafts: []), view:)
}

// Keep both copies when the owner has continued typing before custody returns.
fn append_returned_text(
  input: text_area.TextAreaState,
  returned: String,
) -> text_area.TextAreaState {
  let current = text_area.value(input)
  let restored = case string.trim(current) {
    "" -> returned
    _ -> current <> "\n\n" <> returned
  }
  text_area.state_from_string(restored)
}

/// A usage record with every counter at zero.
@internal
pub fn zero_usage() -> message.Usage {
  message.Usage(
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
  )
}

/// Keeps the agent inspector's selected message valid against the current
/// message list, resetting the scroll when the selection moved.
@internal
pub fn select_inspector_message(
  inspector: agents.Inspector,
  messages: List(agent_messages.Item),
) -> agents.Inspector {
  case inspector.detail {
    agents.Overview | agents.Notes | agents.Collaboration -> inspector
    agents.Messages -> {
      let selected =
        messages
        |> agent_messages.for_strand(inspector.selected)
        |> agent_message_panel.selected(inspector.message)
        |> option.map(agent_message_panel.identity)
      let scroll = case selected == inspector.message {
        True -> inspector.scroll
        False -> 0
      }
      agents.Inspector(..inspector, message: selected, scroll:)
    }
  }
}

/// Reconciles a message browser after a new captured projection arrives.
///
/// ## Examples
///
/// ```gleam
/// // tui.reconcile_agent_message_selection(model)
/// ```
@internal
pub fn reconcile_agent_message_selection(model: Model) -> Model {
  case model.view.overlay {
    AgentInspector(inspector) if inspector.detail == agents.Messages ->
      Model(
        ..model,
        view: view_set.overlay(
          model.view,
          AgentInspector(select_inspector_message(
            inspector,
            model.shared.agent_messages,
          )),
        ),
      )
    _ -> model
  }
}

/// The furthest the notes panel can scroll for the current selection.
@internal
pub fn note_max_scroll(model: Model) -> Int {
  let area = case model.view.overlay {
    AgentInspector(_) -> layout.message_detail_area(model)
    _ -> layout.note_detail_area(model)
  }
  render.prepared_notes(model, side_surfaces.notes_target(model), area)
  |> note_panel.max_scroll(model.view.note_selected)
}

/// Owner context is read from the same exact escalation revision. A newer
/// metadata cut cannot silently rename the request whose grants are displayed.
@internal
pub fn captured_approval_panel(model: Model, review: approval.Review) {
  let context = {
    use captured <- result.try(option.to_result(model.shared.captured, Nil))
    use cell <- result.try(
      list.find(captured.1.cells, fn(cell) {
        cell.namespace == register.FactCustom
        && cell.key == "escalation/" <> review.id
        && cell.seq == review.seq
      }),
    )
    use fields <- result.try(case cell.value {
      json.Object(fields) -> Ok(fields)
      _ -> Error(Nil)
    })
    use scope <- result.try(list.key_find(fields, "scope"))
    use fields <- result.try(case scope {
      json.Object(fields) -> Ok(fields)
      _ -> Error(Nil)
    })
    use owner <- result.try(case list.key_find(fields, "strand") {
      Ok(json.String(owner)) -> Ok(owner)
      _ -> Error(Nil)
    })
    use operation <- result.try(case list.key_find(fields, "operation") {
      Ok(json.String(operation)) -> Ok(operation)
      _ -> Error(Nil)
    })
    Ok(#(owner, operation))
  }
  approval_panel.new(review)
  |> approval_panel.with_context(case context {
    Ok(#(owner, operation)) -> approval_panel.CapturedRequest(owner, operation)
    Error(_) ->
      approval_panel.RequestContextUnavailable(
        "Request owner unavailable in this capture",
      )
  })
}

/// Cancels every unsent frame on the session channel with `reason` and
/// applies the updates the cancellation produces. Called when the operator
/// changes target, so a queued frame cannot reach the wrong session or strand.
///
/// ## Examples
///
/// ```gleam
/// let model = inbound.cancel_pending(model, "cancelled by Escape")
/// ```
@internal
pub fn cancel_pending(model: Model, reason: String) -> Model {
  let #(shared, updates) = lane_fold.cancel_unsent(model.shared, reason)
  list.fold(updates, tui_model.hold_shared(model, shared), apply_channel_update)
}

/// History shares the existing correlated read lane. A busy lane leaves one
/// demand pending without blocking input, spawning a worker, or opening a socket.
///
/// The terminal's form of `lane_fold.service_history`.
///
/// ## Examples
///
/// ```gleam
/// let model = inbound.service_history(model)
/// ```
@internal
pub fn service_history(model: Model) -> Model {
  tui_model.run_shared(model, lane_fold.service_history)
}

// Keep draft ownership across sessions while retaining history only for
// strands still present in the current session. Draft text is never evicted.
fn prune_workspace_history(
  workspaces: Dict(#(String, String), StrandWorkspace),
  session: String,
  strands: List(protocol.Strand),
) -> Dict(#(String, String), StrandWorkspace) {
  dict.map_values(workspaces, fn(owner, saved) {
    case lane_fold.retains_history(owner, session, strands) {
      True -> saved
      False ->
        StrandWorkspace(
          ..saved,
          reading_lines: None,
          offset: 0,
          anchors: [],
          prefix: 0,
        )
    }
  })
}

// New destinations begin with their own editor and an empty history window.
fn empty_workspace() -> StrandWorkspace {
  StrandWorkspace(
    text_area.state_new(),
    [],
    [],
    0,
    "",
    PromptNext,
    None,
    0,
    [],
    0,
    1,
  )
}

/// Save before changing identity; both empty drafts and submission mode belong
/// to the destination, so a first visit starts with a fresh editor.
///
/// The session state's half of the switch is `event_fold.select_workspace`;
/// the terminal parks and restores its editor, attachments and viewport when
/// it applies the switch that call records.
///
/// ## Examples
///
/// ```gleam
/// let model = inbound.select_workspace(model, model.shared.session, "worker")
/// ```
@internal
pub fn select_workspace(
  model: Model,
  session: String,
  strand: String,
) -> Model {
  run_settled(model, event_fold.select_workspace(_, session, strand))
}

// The terminal's half of a workspace switch: the editor, the attachments
// and the viewport park under the departing key, and the arriving key's are
// restored. A change of session also closes the goal inspector, whose board
// the session state has just released, and returns the strip's focus to the
// composer.
//
// The parked viewport height is measured on the model from before the
// shared half ran, with the boards and the goal inspector a session change
// releases already released, because layout reads both and the switch used
// to measure there: after releasing them and before anything else moved.
fn switch_editor(
  before: Model,
  model: Model,
  departing: #(String, String),
  arriving: #(String, String),
  previous_session: String,
) -> Model {
  let same_session = previous_session == arriving.0
  let overlay = case same_session, model.view.overlay {
    False, GoalInspector(_) -> NoOverlay
    _, other -> other
  }
  let measured = case same_session {
    True -> before
    False ->
      Model(
        shared: event_fold.leave_session(before.shared),
        view: view_set.overlay(before.view, overlay),
      )
  }
  let parked =
    dict.insert(
      model.view.strand_workspaces,
      departing,
      StrandWorkspace(
        model.view.input,
        model.shared.attachments,
        model.view.history,
        model.view.history_index,
        model.view.history_draft,
        model.view.submission_mode,
        model.view.reading_lines,
        model.view.scroll_offset,
        model.view.rendered_anchors,
        model.view.rendered_row_count - list.length(model.view.rendered_anchors),
        layout.transcript_viewport_height(measured),
      ),
    )
  let saved = dict.get(parked, arriving) |> option.from_result
  let restored = option.unwrap(saved, empty_workspace())
  Model(
    shared: shared_set.attachments(model.shared, restored.attachments),
    view: View(
      ..{
        model.view
        |> view_set.overlay(overlay)
        |> view_set.strand_workspaces(dict.delete(parked, arriving))
        |> view_set.input(restored.input)
        |> view_set.history(restored.history)
        |> view_set.history_index(restored.history_index)
        |> view_set.history_draft(restored.history_draft)
        |> view_set.command_selected(0)
        |> view_set.submission_mode(restored.submission_mode)
        |> view_set.scroll_offset(restored.offset)
        |> view_set.strip_focus(case same_session {
          True -> model.view.strip_focus
          False -> agent_strip.Composing
        })
      },
      restored_workspace: saved,
      reading_lines: restored.reading_lines,
    ),
  )
}

/// Cuts and width transitions request at most one pending refresh. No timer or
/// background Git loop is needed when the workspace and conversation are idle.
///
/// The terminal's form of `lane_fold.request_visible_worktree`, given
/// whether the terminal shows captured edits.
///
/// ## Examples
///
/// ```gleam
/// let model = inbound.request_visible_worktree(model)
/// ```
@internal
pub fn request_visible_worktree(model: Model) -> Model {
  let worktree = worktree_view_of(model)
  tui_model.run_shared(model, lane_fold.request_visible_worktree(_, worktree))
}

/// Asks for a fresh worktree diff when a live conversation is attached.
///
/// The terminal's form of `lane_fold.refresh_worktree`.
///
/// ## Examples
///
/// ```gleam
/// let model = inbound.refresh_worktree(model)
/// ```
@internal
pub fn refresh_worktree(model: Model) -> Model {
  tui_model.run_shared(model, lane_fold.refresh_worktree)
}

// The queue editor's selection follows the row it pointed at from the rows
// a cut replaced into the rows it brought, and its preview keeps its scroll
// while the same row stays selected.
//
// The preview's height depends on layout, which reads the model. The old
// code measured it inside the cut, before the cut wrote the session state
// layout reads (the captured cut, the agent rows, the strands) and after
// only the completion and job fields, which layout does not read. So it is
// measured here on the shared record from before the update and the
// terminal state as it stands, which holds every terminal write the update
// made before this fact.
fn follow_queue_selection(
  before: Model,
  model: Model,
  previous: List(snapshot_view.PendingInput),
  rows: List(snapshot_view.PendingInput),
) -> Model {
  let old =
    previous
    |> list.drop(model.view.queue_editor.selected)
    |> list.first
  let selected = case old {
    Ok(row) ->
      rows
      |> list.index_map(fn(item, index) { #(item.id, index) })
      |> list.key_find(row.id)
      |> result.unwrap(0)
    Error(Nil) -> 0
  }
  let preview_scroll = case old {
    Ok(row) ->
      case list.first(list.drop(rows, selected)) {
        Ok(current) if current.id == row.id ->
          int.min(
            model.view.queue_editor.preview_scroll,
            queue_panel.max_scroll(
              rows,
              selected,
              layout.queue_preview_area_for(
                Model(
                  shared: before.shared,
                  view: view_set.queue_editor(
                    model.view,
                    queue_editor.State(..model.view.queue_editor, selected:),
                  ),
                ),
                rows,
              ),
            ),
          )
        Ok(_) | Error(Nil) -> 0
      }
    Error(Nil) -> 0
  }
  Model(
    ..model,
    view: view_set.queue_editor(
      model.view,
      queue_editor.State(..model.view.queue_editor, selected:, preview_scroll:),
    ),
  )
}

/// Advances the agent strip's clock on the terminal tick.
///
/// The strip's elapsed figures are whole seconds, so the frame is rebuilt
/// only when one of them moves. A strip that is not drawn is left alone,
/// which keeps a single-agent session from repainting once a second for a
/// row nobody can see. This lives outside `tui/tick` so the tick's drain
/// chain gains a cross-module call, which the inliner never attempts,
/// rather than another local step for it to revisit.
///
/// ## Examples
///
/// ```gleam
/// // inbound.tick_strip(model)
/// ```
@internal
pub fn tick_strip(model: Model) -> Model {
  case layout.agents_drawn(model) {
    False -> model
    True -> {
      let #(roster, repaint) =
        agent_roster.tick(model.shared.roster, model.shared.stamp.now_ms)
      let model =
        Model(..model, shared: shared_set.roster(model.shared, roster))
      case repaint {
        agent_roster.Changed -> tui_model.invalidate_frame(model)
        agent_roster.Unchanged -> model
      }
    }
  }
}
