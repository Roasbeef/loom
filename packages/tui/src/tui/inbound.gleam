//// Applies what the session channel delivers to the model.
////
//// The websocket actor owns transport I/O; this module owns what the
//// traffic means. `drain_connection` takes a bounded batch from the
//// connection inbox, and `apply_channel_update` folds each channel update
//// into the model. A captured snapshot cut is projected by `render_cut` into
//// the transcript, approvals, workspaces and cache watches.
////
//// Each pushed event (stream fragments, tool output tails, durable entries,
//// strand phases, usage and the replies to side-surface reads) goes to the
//// shared event fold, `event_fold.apply_event`, which takes the session
//// state alone. `run_event` calls it and then applies what it recorded for
//// the terminal's own surfaces (`settle_surfaces`): the editor on a
//// workspace switch, the model selector, the cache outlook, the notes panel,
//// the summary's job cursor and a returned draft.

import core/json
import core/message
import core/origin
import core/register
import etui/widgets/textarea as text_area
import gleam/bool
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import gleam/string
import host/build_identity
import machine/strand as machine_strand
import session_view/advisor_history
import session_view/agent_roster
import session_view/agent_view
import session_view/approval
import session_view/block_summary
import session_view/cache_watch
import session_view/command
import session_view/connection_event
import session_view/context_view
import session_view/history_view
import session_view/notes_view
import session_view/operator
import session_view/protocol
import session_view/reviewer_status
import session_view/session_channel
import session_view/snapshot
import session_view/snapshot_view
import session_view/todo_board
import session_view/transcript_line.{type Line, Line, System}
import session_view/transcript_lines
import session_view/worktree_view
import tui/agent_message_panel
import tui/agent_messages
import tui/agent_strip
import tui/agents
import tui/approval_panel
import tui/bootstrap
import tui/buffered
import tui/completion_summary
import tui/event_fold
import tui/job
import tui/layout
import tui/model.{
  type Model, type Reconnect, type StrandWorkspace, AgentInspector,
  ApprovalInspector, DaemonSelector, GoalInspector, Model, ModelSelector,
  NoOverlay, PeerLinkManager, PromptNext, ReconnectAttempting, ReconnectIdle,
  ReconnectSpent, StrandWorkspace, View,
} as tui_model
import tui/model_selector
import tui/note_panel
import tui/outbound
import tui/queue_editor
import tui/queue_panel
import tui/queue_request
import tui/render
import tui/session_model.{
  type Interrupt, type Peer, type UnconfirmedSubmission, Attached, Disconnected,
  HoldGoalReport, Preview, Replaying, ReturnedDraft, Shared,
  UnconfirmedSubmission,
}
import tui/summary_panel
import tui/surfaces

/// The authenticated build belongs to the retained control host. Projecting
/// its mismatch on every coherent cut keeps attachment and later captures from
/// erasing the update notice when they replace the transcript presentation.
/// `theirs` is `Shared.daemon_build`, `None` until a control connection is
/// adopted and when the daemon's `hello` named no build. `ours` is
/// `Shared.client_build`, read when the model was created, so a cut reads no
/// environment variable.
///
/// ## Examples
///
/// ```gleam
/// let lines =
///   inbound.daemon_build_lines(
///     model.shared.daemon_build,
///     model.shared.client_build,
///   )
/// ```
@internal
pub fn daemon_build_lines(
  theirs: Option(build_identity.Identity),
  ours: build_identity.Identity,
) -> List(Line) {
  case theirs {
    None -> []
    Some(theirs) ->
      case build_identity.matches(ours, theirs) {
        True -> []
        False -> [
          Line(
            System,
            "daemon build "
              <> build_identity.describe(theirs)
              <> " differs from this client's "
              <> build_identity.describe(ours)
              <> "; the daemon runs the build it was started with, so "
              <> "restart it to pick up an update",
          ),
        ]
      }
  }
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

// What the decision above produced: the work to do, or the reason there is
// none. The reason is carried rather than dropped so the caller can say why
// rather than leaving the operator with a silent terminal.
type ReconnectDecision {
  ReconnectWanted(session: String, options: bootstrap.Options)

  ReconnectRefused(reason: String)
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
        shared: Shared(
          ..model.shared,
          notice: "reconnecting to session " <> session,
        ),
        view: View(
          ..model.view,
          reconnect: ReconnectAttempting(job.awaiting(key)),
        ),
      )
      |> tui_model.invalidate_frame
    }
  }
}

/// Advances the session channel's timers and applies every update they
/// produce, then services a pending history read.
@internal
pub fn tick_channel(model: Model) -> Model {
  case model.shared.channel {
    None -> model
    Some(channel) -> {
      let #(channel, updates) =
        session_channel.tick(channel, now: model.shared.stamp.transport_ms)
      list.fold(
        updates,
        tui_model.hold_channel(model, channel),
        apply_channel_update,
      )
      |> service_history
    }
  }
}

/// Folds one conversation-channel update into the model.
///
/// Public because it is the boundary a test drives to deliver a daemon reply
/// without standing up a socket; nothing outside this module calls it in a
/// running client.
pub fn apply_channel_update(
  model: Model,
  update: session_channel.Update,
) -> Model {
  case update {
    session_channel.Submission(disposition) ->
      tui_model.apply_submission(model, disposition)
    session_channel.Captured(cut, view, trigger) ->
      reconcile_cut(model, cut, view, trigger)
    session_channel.HistoryPage(window, before, after) ->
      receive_history(model, window, before, after)
    session_channel.LookedUp(records, missing) -> {
      let inspected = inspect_looked_up(model, records, missing)
      let updated =
        Model(
          ..inspected,
          shared: Shared(
            ..inspected.shared,
            approvals: approval.decisions(
              model.shared.approvals,
              records,
              missing,
            ),
          ),
        )

      // A lookup can be the first to report the open question resolved, for
      // instance when another client answered it, so the reply settles the
      // dialog the same way a cut does rather than waiting for the next one.
      let updated = case updated.shared.captured {
        Some(#(cut, view)) ->
          render_cut(updated, cut, view, updated.shared.approvals)
          |> close_settled_approval
          |> present_pending_approval
        None -> updated
      }
      case missing {
        [] -> updated
        _ ->
          tui_model.append_system(
            updated,
            "Decisions not available: " <> string.join(missing, ", "),
          )
      }
    }
    session_channel.Auxiliary(event) -> run_event(model, event)
    session_channel.RequestRefused("history", _, code, message) ->
      tui_model.append_error(
        Model(
          ..model,
          shared: Shared(
            ..model.shared,
            scrollback: history_view.cancel(model.shared.scrollback),
          ),
        ),
        "Older history: " <> code <> ": " <> message,
      )
    session_channel.RequestRefused(command, request_id, code, message) ->
      apply_request_refused(model, command, request_id, code, message)

    // Nothing here is visible, and that is the point: the count moves for
    // every notice the daemon pushed, including the ones a held sequence or
    // an in-flight refresh made redundant. The rendered frame is untouched,
    // so this cannot invalidate it.
    session_channel.Noticed(_) ->
      Model(
        ..model,
        shared: Shared(..model.shared, notices: model.shared.notices + 1),
      )

    // A pushed fragment is the same thing the directly attached client
    // receives as a stream delta, so it lands in the same live-stream region
    // by the same route rather than through a second renderer.
    session_channel.Streamed(strand:, operation:, generation:, kind:, text:) ->
      run_event(
        model,
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
      run_event(
        model,
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
    // than writing a second copy of the same news.
    session_channel.Acknowledged("edit_queued_input", "queued") ->
      Model(
        shared: Shared(
          ..model.shared,
          notice: "queued input updated",
          queue_request: queue_request.new(),
        ),
        view: View(..model.view, queue_editor: queue_editor.new()),
      )
      |> tui_model.invalidate_frame
    session_channel.Acknowledged("prompt", "queued") ->
      {
        let settled = tui_model.run_shared(model, event_fold.settle_own_turn)
        Model(
          ..settled,
          shared: Shared(
            ..settled.shared,
            submitting: None,
            notice: "prompt queued for the next turn",
          ),
        )
      }
      |> tui_model.invalidate_frame

    // An abort ends the run, and with it every steer and follow-up the run
    // had not started yet: the queue drains those without committing them,
    // so no entry will ever arrive to retire their interjections. A held
    // prompt is not the run's to cancel — it waits in the gateway and drains
    // once the strand is idle — so the abort drops the interjections and
    // leaves the prompt echoes standing.
    session_channel.Acknowledged("abort", status) ->
      {
        let abandoned =
          tui_model.run_shared(model, event_fold.abandon_interjections)
        Model(
          ..abandoned,
          shared: Shared(..abandoned.shared, notice: "abort " <> status),
        )
      }
      |> tui_model.invalidate_frame

    // Every other acknowledgement settles its submission the same way: a
    // steer answered `admitted` will commit the entry its interjection is
    // waiting for. Commands that record nothing leave `awaiting_outcome`
    // empty and pass through untouched.
    session_channel.Acknowledged(command, status) ->
      {
        let settled = tui_model.run_shared(model, event_fold.settle_own_turn)
        Model(
          ..settled,
          shared: Shared(..settled.shared, notice: command <> " " <> status),
        )
      }
      |> tui_model.invalidate_frame
    session_channel.UnknownOutcome(command, request_id) ->
      tui_model.append_error(
        Model(
          shared: Shared(
            ..model.shared,
            unconfirmed: Some(UnconfirmedSubmission(
              model.shared.session,
              command,
              request_id,
            )),
          ),
          view: View(..model.view, queue_editor: case command {
            "edit_queued_input" -> queue_editor.unknown(model.view.queue_editor)
            _ -> model.view.queue_editor
          }),
        ),
        "Last unconfirmed submission: " <> command <> "; not retried",
      )
    session_channel.Failed(reason) ->
      tui_model.append_error(
        {
          let discarded = tui_model.run_shared(model, outbound.discard_own_turn)
          Model(
            shared: Shared(
              ..discarded.shared,
              peer: after_close(model.shared.peer),
              scrollback: history_view.cancel(model.shared.scrollback),
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
              worktree: case model.shared.worktree.awaiting {
                Some(id) ->
                  worktree_view.receive(
                    model.shared.worktree,
                    session_model.queue_owner(model.shared),
                    worktree_view.Failed(id, "conversation disconnected"),
                  )
                None -> model.shared.worktree
              },
              queue_request: queue_request.new(),
            ),
            view: View(
              ..discarded.view,
              queue_editor: queue_editor.refused(
                model.view.queue_editor,
                "Disconnected; draft retained",
              ),
              overlay: case model.view.overlay {
                GoalInspector(_) -> NoOverlay
                other -> other
              },
            ),
          )
        },
        "conversation: " <> reason,
      )
      |> begin_reconnect
  }
}

fn reconcile_cut(
  model: Model,
  cut: snapshot.Captured,
  view: snapshot_view.View,
  trigger: session_channel.Capture,
) -> Model {
  // Equal metadata still advances transport credit, but must not continually
  // restart animation or invalidate a transcript which has not changed. The
  // provenance is recorded only on the arm that paints: a notice-driven
  // catch-up that finds nothing new must not claim the answer a refresh
  // already painted, or a fixture reading it would call polling "push".
  case model.shared.captured {
    Some(#(previous, _))
      if previous.next_seq == cut.next_seq && previous.metadata == cut.metadata
    ->
      Model(
        ..model,
        shared: Shared(..model.shared, captured: Some(#(cut, view))),
      )
      |> close_settled_approval
      |> present_pending_approval
    Some(_) | None -> {
      let updated =
        apply_cut(
          Model(..model, shared: Shared(..model.shared, last_capture: trigger)),
          cut,
          view,
        )
      let updated = case model.shared.captured {
        Some(#(previous, _)) if previous.next_seq == cut.next_seq -> updated
        Some(_) | None -> request_visible_worktree(updated)
      }
      let disappeared =
        model.shared.approvals
        |> list.filter(fn(old) {
          old.status == approval.Pending
          && !list.any(updated.shared.approvals, fn(new) { new.id == old.id })
        })
        |> list.map(fn(record) { record.id })
      let updated = case list.take(disappeared, 8) {
        [] -> updated
        ids -> request_decisions(updated, ids)
      }
      case list.drop(disappeared, 8) {
        [] -> updated
        _ ->
          tui_model.append_system(
            updated,
            "Additional resolutions are not loaded; use /approvals <id>.",
          )
      }
    }
  }
}

/// Asks the session channel to look up the approval records named by
/// `ids`. A replay performs no lookup.
@internal
pub fn request_decisions(model: Model, ids: List(String)) -> Model {
  case model.shared.peer {
    // A replay performs no outbound effect and invents no line the live
    // client was not shown. Whatever the live client learned about these
    // decisions is already in the recording; a "conversation is not
    // attached" error here would be a line no live session ever produced.
    Replaying -> model

    Attached | Disconnected | Preview ->
      case model.shared.channel {
        None -> tui_model.append_error(model, "conversation is not attached")
        Some(channel) ->
          case
            session_channel.lookup(
              channel,
              ids,
              now: model.shared.stamp.transport_ms,
            )
          {
            Ok(channel) -> tui_model.hold_channel(model, channel)
            Error(reason) ->
              tui_model.append_error(
                model,
                "decision lookup not sent: " <> reason,
              )
          }
      }
  }
}

/// Applies a captured snapshot cut to the model and then presents any
/// approval the cut left pending.
@internal
pub fn apply_cut(
  model: Model,
  cut: snapshot.Captured,
  view: snapshot_view.View,
) -> Model {
  let reviews = case approval.records(view.cells) {
    Ok(current) -> approval.project(model.shared.approvals, current)
    Error(_) -> []
  }
  render_cut(model, cut, view, reviews)
  |> close_settled_approval
  |> present_pending_approval
}

// Another client attached to the same session can answer the question this
// panel is showing, and nothing the operator does here would then be
// meaningful: the request is no longer pending. The panel closes once the cut
// holds no pending record with its ID, whether the register now reads as
// resolved or has gone. The check is by ID rather than by exact sequence
// because a pending request whose sequence moved is still the question on
// screen, and the panel deliberately keeps the revision it captured. A panel
// opened on a record that was already resolved is a deliberate inspection
// through /approvals, and it stays open whatever the cut says. Closing runs
// before presentation so that the next unseen question opens in the same step.
fn close_settled_approval(model: Model) -> Model {
  case model.view.overlay {
    ApprovalInspector(panel) -> {
      let asked = approval_panel.review(panel)

      // Both projections keep one record per escalation ID, so the first
      // match is the only one.
      let current =
        list.find(model.shared.approvals, fn(record) { record.id == asked.id })
      case asked.status, current {
        approval.Pending, Ok(approval.Review(status: approval.Pending, ..))
        | approval.Approved, _
        | approval.Rejected, _
        | approval.Consumed, _
        -> model

        // The resolved register names its decider when it carries one. A
        // register that has gone names nobody yet; the decision lookup the
        // cut starts adds the author to the approval lines when it returns.
        approval.Pending, Ok(approval.Review(origin: Some(author), ..)) ->
          settle_elsewhere(model, asked, " by " <> origin.display_label(author))
        approval.Pending, Ok(approval.Review(origin: None, ..))
        | approval.Pending, Error(Nil)
        -> settle_elsewhere(model, asked, "")
      }
    }
    NoOverlay
    | ModelSelector(_)
    | AgentInspector(_)
    | GoalInspector(_)
    | DaemonSelector(_)
    | PeerLinkManager(_) -> model
  }
}

fn settle_elsewhere(
  model: Model,
  asked: approval.Review,
  decider: String,
) -> Model {
  tui_model.append_system(
    Model(..model, view: View(..model.view, overlay: NoOverlay)),
    "Approval "
      <> asked.id
      <> " ("
      <> asked.tool
      <> ") was settled elsewhere"
      <> decider
      <> "; its dialog is closed.",
  )
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
          Model(..model, view: View(..model.view, prompted_approvals: seen))
        Ok(record) ->
          Model(
            ..model,
            view: View(
              ..model.view,
              prompted_approvals: [#(record.id, record.seq), ..seen],
              overlay: ApprovalInspector(captured_approval_panel(model, record)),
            ),
          )
      }
    }
    _, _ -> model
  }
}

fn render_cut(
  model: Model,
  cut: snapshot.Captured,
  view: snapshot_view.View,
  reviews: List(approval.Review),
) -> Model {
  // A disappearing strand never retargets a draft. The composer keeps its
  // identity and submission is refused until that target is available again.
  let active = model.shared.active_strand
  let model = observe_completion(model, cut, view, active)
  let model = retain_queue_selection(model, view, active)
  let same_operation = case model.shared.captured {
    Some(#(_, previous)) ->
      model.shared.active_strand == active
      && dict.get(previous.operations, model.shared.active_strand)
      == dict.get(view.operations, active)
    None -> False
  }
  let history =
    history_view.capture(model.shared.scrollback, cut.window, view, active)
  let branch = history_view.branch(history, view)
  let current_model = case dict.get(view.configurations, active) {
    Ok(config) -> config.configuration.model.model_id
    Error(Nil) -> "unconfigured"
  }
  let cache =
    cache_watch.capture(
      model.shared.cache,
      option.map(model.shared.captured, fn(shown) { shown.1 }),
      view,
    )
  let cache_outlook = case dict.get(cache.watches, active) {
    Ok(_) -> model.view.cache_outlook
    Error(Nil) -> ""
  }
  let role = case cut.attachment.role {
    snapshot.Owner -> "owner"
    snapshot.Operator -> "operator"
    snapshot.Observer -> "observer · read-only"
  }

  // The same coherent presence test governs both turn labels and the
  // attachment banner. A lone owner needs no redundant name or role; every
  // other attachment retains the full identity and participant count.
  let #(notice, attachment_banner) = case
    transcript_lines.solo_owner(Some(#(cut, view)))
  {
    Some(_) -> #("1 present", "Attached · 1 present")
    None -> {
      let identity =
        origin.display_label(cut.attachment.origin)
        <> " · "
        <> role
        <> " · "
        <> int.to_string(list.length(view.peers))
        <> " present"
      #(identity, "Attached as: " <> identity)
    }
  }
  let boundary = case branch.unloaded {
    None -> "Beginning of this conversation."
    Some(_) ->
      case history.request {
        history_view.Wanted | history_view.Pending(_) ->
          "Loading older conversation…"
        history_view.Quiet -> "Scroll up to load older conversation."
      }
  }
  let transcript = [
    Line(System, boundary),
    Line(System, attachment_banner),
    ..list.append(
      daemon_build_lines(model.shared.daemon_build, model.shared.client_build),
      list.append(
        configuration_lines(view, active),
        list.append(
          unconfirmed_lines(model.shared.unconfirmed),
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
    model.shared.record_cache_valid
    && model.shared.active_strand == active
    && model.shared.records == branch.records
    && model.shared.advisor_history == advisor_history
    && model.shared.transcript == transcript
    && transcript_lines.solo_owner(model.shared.captured)
    == transcript_lines.solo_owner(Some(#(cut, view)))

  // Request-scoped pushes outrun captures: a cut may have started before
  // the request that is streaming now. Retain those observations, including
  // terminal markers, until an exact durable last result proves retirement.
  // An unrelated idle cut cannot retire a newer request. This fallback also
  // covers relay failures which bypass the optional presentation observer.
  // Legacy recordings retain their operation-based law.
  let operation = dict.get(view.operations, active)
  let live =
    list.filter(model.shared.streams, fn(stream) {
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
    list.filter(model.shared.tool_tails, fn(tail) {
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
  let summaries = case model.shared.records == branch.records {
    True -> model.shared.summaries
    False ->
      block_summary.want(
        model.shared.summaries,
        transcript_lines.summary_keys(branch.records, active),
      )
  }
  let summaries =
    block_summary.retain_live(summaries, fn(generation) {
      list.any(model.shared.streams, fn(stream) {
        stream.generation == generation
      })
      || transcript_lines.response_recorded(branch.records, generation)
    })

  // Retired strands keep unsent drafts but release their bounded reading
  // windows. A future appearance must rebuild history from its own capture.
  let workspaces =
    prune_workspace_history(
      model.view.strand_workspaces,
      model.shared.session,
      view.strands,
    )
  let parked_scrollback =
    prune_parked_scrollback(
      model.shared.parked_scrollback,
      model.shared.session,
      view.strands,
    )
  let reviewers =
    reviewer_status.observe(model.shared.reviewer_rows, cut.window, view)
  let rows =
    agent_view.observe(model.shared.agent_rows, cut.window, view, reviewers)
  let captured_messages =
    agent_messages.capture(model.shared.agent_messages, view, cut.window)

  // A strand whose capture reaches no `todo` call may still have a board
  // in its notes, the usual case after reattaching to a long session, so
  // its first capture asks for one notes read to seed the panel.
  let boards = todo_board.remember(model.shared.todo_boards, branch.records)
  let #(todo_seed, todo_asked) = case
    todo_board.needs_seed(boards, model.shared.todo_asked, active)
  {
    True -> #(Some(active), set.insert(model.shared.todo_asked, active))
    False -> #(model.shared.todo_seed, model.shared.todo_asked)
  }
  Model(
    shared: Shared(
      ..model.shared,
      captured: Some(#(cut, view)),
      approvals: reviews,
      active_strand: active,
      strands: view.strands,
      reviewer_rows: reviewers,
      agent_rows: rows,
      roster: agent_roster.observe(
        model.shared.roster,
        view,
        model.shared.stamp.now_ms,
      ),
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
        True -> model.shared.activity_started_ms
        False -> None
      },
      activity_elapsed_s: case same_operation {
        True -> model.shared.activity_elapsed_s
        False -> 0
      },
      usage: view.usage,
      current_model: current_model,
      cache:,
      streams: live,
      tool_tails: live_tails,
      interrupt: reconcile_interrupt(model.shared.interrupt, view.operations),
      queued: case view.pending_inputs {
        Some(_) -> []
        None -> model.shared.queued
      },
      submitting: None,
      record_cache_valid:,
      // Presence already has its own banner. Repeated metadata captures must
      // not alternate that banner with streaming or operator feedback below.
      notice: case model.shared.captured {
        None -> notice
        Some(_) -> model.shared.notice
      },
      transcript:,
    ),
    view: View(..model.view, strand_workspaces: workspaces, cache_outlook:),
  )
  |> tui_model.run_shared(event_fold.settle_pending_cache(_, cut.next_seq))
  |> reconcile_agent_message_selection
  |> tui_model.invalidate_transcript
  // A completed cut can make the operation idle before the next animation
  // tick. Invalidate the painted frame too; rebuilding transcript rows alone
  // leaves the old buffer current until an unrelated key or resize arrives.
  |> tui_model.invalidate_frame
  |> tui_model.mark_activity
}

fn configuration_lines(view: snapshot_view.View, active: String) {
  let configuration = case dict.get(view.configurations, active) {
    Ok(config) -> [
      Line(
        System,
        "Strand configuration: "
          <> config.configuration.model.model_id
          <> " · effort "
          <> thinking_name(config.configuration.thinking_level)
          <> changed_by(config.origin),
      ),
    ]
    Error(Nil) -> []
  }
  [
    Line(System, code_mode_status(view, active)),
    Line(
      System,
      "Shared settings: "
        <> view.settings.queue_mode
        <> " · "
        <> view.settings.tool_execution
        <> changed_by(view.settings.origin),
    ),
    ..list.append(configuration, case view.tools {
      None -> []
      Some(tools) ->
        list.map(tools.extension_refusals, fn(reason) { Line(System, reason) })
    })
  ]
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

fn thinking_name(level: machine_strand.ThinkingLevel) {
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

fn inspect_looked_up(model: Model, records, missing) {
  // A lookup started before automatic presentation may finish while the
  // operator is reviewing another question. The visible record owns consent
  // until that dialog closes, including its selection and scroll position.
  case model.view.overlay, model.view.inspecting_approval {
    ApprovalInspector(_), _ ->
      Model(..model, view: View(..model.view, inspecting_approval: None))
    _, Some(id) ->
      case list.find(records, fn(record: approval.Review) { record.id == id }) {
        Ok(record) ->
          Model(
            ..model,
            view: View(
              ..model.view,
              overlay: ApprovalInspector(captured_approval_panel(model, record)),
              inspecting_approval: None,
            ),
          )
        Error(Nil) ->
          case list.contains(missing, id) {
            True ->
              Model(
                ..model,
                view: View(..model.view, inspecting_approval: None),
              )
            False -> model
          }
      }
    _, None -> model
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

/// The panel returns its captured review. Looking the ID up again here would
/// replace the displayed question with a newer record the operator never saw.
@internal
pub fn decide_captured_approval(
  model: Model,
  record: approval.Review,
  choice: approval_panel.Choice,
) -> Model {
  case outbound.mutation_refusal(model.shared, command.Approve(record.id)) {
    Some(reason) -> tui_model.append_error(model, reason)
    None -> {
      let choice = case choice {
        approval_panel.AllowOnce -> operator.AllowOnce
        approval_panel.AllowSession -> operator.AllowForSession
        approval_panel.Deny -> operator.Deny
      }
      case operator.decision(model.shared.next_id, record, choice) {
        Error(reason) -> tui_model.append_error(model, reason)
        Ok(frame) ->
          tui_model.send_frame(
            Model(..model, view: View(..model.view, overlay: NoOverlay)),
            frame,
          )
      }
    }
  }
}

/// Encodes and sends a decision for the displayed approval `id`. A decision
/// that is not on screen is refused, so the operator only answers what they
/// have seen.
@internal
pub fn decide(model: Model, id: String, choice: operator.Choice) -> Model {
  case list.find(model.shared.approvals, fn(record) { record.id == id }) {
    Error(Nil) ->
      tui_model.append_error(
        model,
        "decision is not displayed; load /approvals " <> id <> " first",
      )
    Ok(record) ->
      case operator.decision(model.shared.next_id, record, choice) {
        Error(reason) -> tui_model.append_error(model, reason)
        Ok(frame) -> tui_model.send_frame(model, frame)
      }
  }
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
      Model(..drained, shared: Shared(..drained.shared, connection_backlog:))
  }
}

// The oldest message the adopted inbox holds, taken from whatever inbox the
// model holds now, so a drain that follows an adoption reads the new one.
fn take_connection(
  model: Model,
) -> #(Model, Result(connection_event.Message, Nil)) {
  let #(inbox, next) = buffered.take(model.shared.inbox)
  #(Model(..model, shared: Shared(..model.shared, inbox:)), next)
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

fn handle_connection_message(
  model: Model,
  incoming: connection_event.Message,
) -> Model {
  case model.shared.channel {
    Some(channel) -> {
      let #(channel, updates) =
        session_channel.receive(
          channel,
          incoming,
          now: model.shared.stamp.transport_ms,
        )
      list.fold(
        updates,
        tui_model.hold_channel(model, channel),
        apply_channel_update,
      )
    }

    // A message with no channel has no attempt to note it under, so it is
    // recorded as the untagged arrival the preview peer has always written.
    None ->
      tui_model.record_arrival(model, incoming)
      |> handle_presentation_message(incoming)
  }
}

fn handle_presentation_message(
  model: Model,
  incoming: connection_event.Message,
) -> Model {
  case incoming {
    connection_event.Connected ->
      Model(..model, shared: Shared(..model.shared, notice: "connected"))
      |> tui_model.mark_activity
      |> tui_model.invalidate_frame
    connection_event.Closed(reason) ->
      tui_model.append_error(
        Model(
          ..model,
          shared: Shared(
            ..model.shared,
            peer: after_close(model.shared.peer),
            streams: [],
            tool_tails: [],
          ),
        ),
        "connection closed: " <> reason,
      )
      |> begin_reconnect
      |> tui_model.mark_activity
    connection_event.NetworkFault(reason) ->
      tui_model.append_error(model, "network: " <> reason)
      |> tui_model.mark_activity
    connection_event.Incoming(text) ->
      case protocol.decode_event(text) {
        Ok(event) -> run_event(model, event)
        Error(reason) ->
          tui_model.append_error(model, "protocol: " <> reason)
          |> tui_model.mark_activity
      }
  }
}

// One pushed event, applied through the shared event fold
// (`event_fold.apply_event`) and settled into the terminal's surfaces. The
// fold records what the terminal's editor, overlays and footer have to
// follow, and `settle_surfaces` applies it here, after this event and
// before the next one, which is where the fold used to write that state.
fn run_event(model: Model, event: protocol.Event) -> Model {
  tui_model.run_shared(model, event_fold.apply_event(_, event))
  |> settle_surfaces(model, _)
}

// Applies what a call into the event fold recorded for the terminal's
// surfaces, oldest first, and then moves any returned drafts into the
// editors.
//
// `before` is the model the shared call started from and `held` the model
// once its result was held. These writes used to happen inside the call, at
// the point each fact is recorded. Applying them after the call gives the
// same model because nothing the fold does after recording a fact reads the
// terminal state the fact writes. They run here rather than in
// `settle_update`, at the end of the step, because one step applies many
// events and a later event reads what an earlier one wrote: a stream
// fragment replaces the notice a notes board set, and a returned draft has
// to be in the composer before a later switch parks it.
fn settle_surfaces(before: Model, held: Model) -> Model {
  let settled = case held.shared.surface_facts {
    [] -> held
    facts ->
      list.fold(
        facts,
        Model(..held, shared: Shared(..held.shared, surface_facts: [])),
        fn(model, fact) { show_surface(before, model, fact) },
      )
  }
  case settled.shared.returned_drafts {
    [] -> settled
    _ -> restore_returned_drafts(settled)
  }
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
        view: View(..model.view, record_gutters: [], scroll_offset: 0),
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
        ApprovalInspector(panel) -> ApprovalInspector(panel)
      }
      Model(..model, view: View(..model.view, overlay:))
    }

    session_model.OutlookCleared ->
      Model(..model, view: View(..model.view, cache_outlook: ""))

    session_model.NotesArrived(board:) -> show_notes(model, board)

    // The summary's cursor follows the job it pointed at in the board being
    // replaced.
    session_model.JobsReplaced(previous:, board:) ->
      Model(
        ..model,
        view: View(
          ..model.view,
          summary_job_selected: summary_panel.follow_selected_job(
            model.view.summary_job_selected,
            previous,
            board,
          ),
        ),
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
  case board.strand == surfaces.notes_target(model) {
    False -> model
    True -> {
      let previous = case model.shared.note_board {
        Some(old) if old.strand == board.strand ->
          render.selected_note(model, old)
        _ -> model.view.note_selected
      }
      let selected =
        render.selected_note(
          Model(..model, view: View(..model.view, note_selected: previous)),
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
              shared: Shared(..model.shared, note_board: Some(board)),
              view: View(..model.view, note_selected: selected),
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
          notice: case surfaces.notes_surface(model) {
            True -> "notes refreshed for " <> board.strand
            False -> model.shared.notice
          },
        ),
        view: View(..model.view, note_selected: selected, note_scroll: scroll),
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
        True -> View(..view, input: append_returned_text(view.input, text))
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
          View(
            ..view,
            strand_workspaces: dict.insert(view.strand_workspaces, owner, saved),
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

/// Records the strand's current model, forgetting the cache watch when the
/// model changed, since a cache written by one model does not serve another.
///
/// The terminal's form of `event_fold.select_model`, which also clears the
/// footer's outlook when the active strand's watch was forgotten.
///
/// ## Examples
///
/// ```gleam
/// let model = inbound.select_model(model, "claude-sonnet")
/// ```
@internal
pub fn select_model(model: Model, name: String) -> Model {
  tui_model.run_shared(model, event_fold.select_model(_, name))
  |> settle_surfaces(model, _)
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
        view: View(
          ..model.view,
          overlay: AgentInspector(select_inspector_message(
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
  render.prepared_notes(model, surfaces.notes_target(model), area)
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
@internal
pub fn cancel_pending(model: Model, reason: String) -> Model {
  case model.shared.channel {
    None ->
      Model(..model, shared: Shared(..model.shared, pending_submission: None))
    Some(channel) -> {
      let #(channel, updates) = session_channel.cancel_unsent(channel, reason)
      list.fold(
        updates,
        tui_model.hold_channel(model, channel),
        apply_channel_update,
      )
    }
  }
}

/// History shares the existing correlated read lane. A busy lane leaves one
/// demand pending without blocking input, spawning a worker, or opening a socket.
@internal
pub fn service_history(model: Model) -> Model {
  case history_view.range(model.shared.scrollback), model.shared.channel {
    Some(#(after, before)), Some(channel) -> {
      case
        session_channel.history(
          channel,
          after,
          before,
          now: model.shared.stamp.transport_ms,
        )
      {
        Error(_) -> model
        Ok(channel) -> {
          let held = tui_model.hold_channel(model, channel)
          Model(
            ..held,
            shared: Shared(
              ..held.shared,
              scrollback: history_view.sent(model.shared.scrollback, before),
            ),
          )
        }
      }
    }
    _, _ -> model
  }
}

fn receive_history(
  model: Model,
  window: snapshot.Window,
  before: Int,
  after: Int,
) -> Model {
  case model.shared.captured {
    None -> model
    Some(#(cut, view)) -> {
      let history =
        history_view.accept(
          model.shared.scrollback,
          window,
          before,
          after,
          view,
        )
      let model =
        apply_cut(
          Model(..model, shared: Shared(..model.shared, scrollback: history)),
          cut,
          view,
        )
      Model(
        ..model,
        shared: Shared(
          ..model.shared,
          render_revision: model.shared.render_revision + 1,
        ),
      )
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

// Keep draft ownership across sessions while retaining history only for
// strands still present in the current session. Draft text is never evicted.
fn prune_workspace_history(
  workspaces: Dict(#(String, String), StrandWorkspace),
  session: String,
  strands: List(protocol.Strand),
) -> Dict(#(String, String), StrandWorkspace) {
  dict.map_values(workspaces, fn(owner, saved) {
    case retains_history(owner, session, strands) {
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

// A parked strand keeps its history window while it belongs to the current
// session and the capture still lists it.
fn retains_history(
  owner: #(String, String),
  session: String,
  strands: List(protocol.Strand),
) -> Bool {
  owner.0 == session && session_model.is_known_strand(strands, owner.1)
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
  tui_model.run_shared(model, event_fold.select_workspace(_, session, strand))
  |> settle_surfaces(model, _)
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
        view: View(..before.view, overlay:),
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
    shared: Shared(..model.shared, attachments: restored.attachments),
    view: View(
      ..model.view,
      overlay:,
      strand_workspaces: dict.delete(parked, arriving),
      restored_workspace: saved,
      input: restored.input,
      history: restored.history,
      history_index: restored.history_index,
      history_draft: restored.history_draft,
      command_selected: 0,
      submission_mode: restored.submission_mode,
      reading_lines: restored.reading_lines,
      scroll_offset: restored.offset,
      strip_focus: case same_session {
        True -> model.view.strip_focus
        False -> agent_strip.Composing
      },
    ),
  )
}

/// Cuts and width transitions request at most one pending refresh. No timer or
/// background Git loop is needed when the workspace and conversation are idle.
@internal
pub fn request_visible_worktree(model: Model) -> Model {
  case model.shared.peer, layout.diff_shown(model) {
    Attached, True -> refresh_worktree(model)
    Attached, False | Preview, _ | Replaying, _ | Disconnected, _ -> model
  }
}

/// Asks for a fresh worktree diff when a live conversation is attached.
@internal
pub fn refresh_worktree(model: Model) -> Model {
  case model.shared.peer, model.shared.channel {
    Attached, Some(_) ->
      Model(
        ..model,
        shared: Shared(
          ..model.shared,
          worktree: worktree_view.request(
            model.shared.worktree,
            session_model.queue_owner(model.shared),
          ),
        ),
      )
      |> tui_model.run_shared(surfaces.service_worktree_read)
    _, _ ->
      Model(
        ..model,
        shared: Shared(
          ..model.shared,
          worktree: worktree_view.new(),
          notice: "Captured edits · live worktree observation unavailable",
        ),
      )
  }
}

fn observe_completion(
  model: Model,
  cut: snapshot.Captured,
  view: snapshot_view.View,
  active: String,
) -> Model {
  let owner =
    session_model.queue_owner(
      Shared(..model.shared, captured: Some(#(cut, view))),
    )
  let previous = case model.shared.completion_owner == owner {
    True -> model.shared.completion
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
  Model(
    ..model,
    shared: Shared(
      ..model.shared,
      completion:,
      completion_owner: owner,
      worktree: case model.shared.worktree.owner == owner {
        True -> model.shared.worktree
        False -> worktree_view.new()
      },
      jobs: case model.shared.completion_owner == owner {
        True -> model.shared.jobs
        False -> None
      },
      jobs_awaiting: case model.shared.completion_owner == owner {
        True -> model.shared.jobs_awaiting
        False -> None
      },
      jobs_refresh: case changed {
        True -> worktree_view.Requested
        False -> model.shared.jobs_refresh
      },
    ),
  )
}

fn retain_queue_selection(
  model: Model,
  view: snapshot_view.View,
  active: String,
) -> Model {
  let old =
    layout.queue_rows(model)
    |> list.drop(model.view.queue_editor.selected)
    |> list.first
  let rows =
    option.unwrap(view.pending_inputs, [])
    |> list.filter(fn(row) { row.strand == active })
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
                  ..model,
                  view: View(
                    ..model.view,
                    queue_editor: queue_editor.State(
                      ..model.view.queue_editor,
                      selected:,
                    ),
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
    view: View(
      ..model.view,
      queue_editor: queue_editor.State(
        ..model.view.queue_editor,
        selected:,
        preview_scroll:,
      ),
    ),
  )
}

fn apply_request_refused(
  model: Model,
  command: String,
  request_id: Int,
  code: String,
  message: String,
) -> Model {
  use <- bool.lazy_guard(command == "context", fn() {
    Model(
      ..model,
      shared: Shared(
        ..model.shared,
        context: context_view.refused(
          model.shared.context,
          request_id,
          code,
          message,
        ),
      ),
    )
    |> tui_model.invalidate_frame
  })

  // Every goal command is refused worded and nowhere else: an older daemon
  // refuses all five, and an operator watching a panel fail to appear has
  // no way to tell that from a session with no goal.
  use <- bool.lazy_guard(string.starts_with(command, "goal_"), fn() {
    tui_model.run_shared(model, surfaces.refuse_goal(
      _,
      command,
      request_id,
      code,
      message,
    ))
  })

  // Labels are optional presentation read with no operator keystroke. An
  // older daemon refuses the read outright, and a row reporting it would
  // be the one visible trace of a feature the operator never asked for, so
  // the terminal stops asking for this attachment and says nothing.
  use <- bool.lazy_guard(command == "block_summaries", fn() {
    Model(
      ..model,
      shared: Shared(
        ..model.shared,
        summaries: block_summary.refused(model.shared.summaries),
      ),
    )
  })

  // A notes read refused while no notes surface is open was the todo
  // panel's seed. An older daemon refuses it, and an error row would report
  // a read the operator never asked for.
  use <- bool.lazy_guard(
    command == "notes" && !surfaces.notes_surface(model),
    fn() { model },
  )
  let reason = code <> ": " <> message
  let updated = case command {
    "queued_input" | "edit_queued_input" ->
      case model.shared.queue_request.request_id == Some(request_id) {
        True ->
          Model(
            shared: Shared(..model.shared, queue_request: queue_request.new()),
            view: View(
              ..model.view,
              queue_editor: queue_editor.refused(
                model.view.queue_editor,
                reason,
              ),
            ),
          )
        False -> model
      }
    "live_jobs" ->
      case model.shared.jobs_request == Some(request_id) {
        True ->
          Model(
            ..model,
            shared: Shared(
              ..model.shared,
              jobs_request: None,
              jobs_awaiting: None,
              jobs_notice: "Live jobs unavailable: " <> reason,
            ),
          )
        False -> model
      }

    // A refused observation draws nothing. The panel is unobtrusive context
    // beside the composer, and an error line there would cost a row of the
    // conversation to report a read the operator never asked for; an older
    // daemon that does not know the command refuses every one of them.
    "advisor_pending" ->
      case model.shared.nudges_request == Some(request_id) {
        True ->
          Model(
            ..model,
            shared: Shared(
              ..model.shared,
              nudges: None,
              nudges_request: None,
              nudges_awaiting: None,
            ),
          )
        False -> model
      }
    "worktree_diff" ->
      Model(
        ..model,
        shared: Shared(
          ..model.shared,
          worktree: worktree_view.receive(
            model.shared.worktree,
            session_model.queue_owner(model.shared),
            worktree_view.Failed(request_id, reason),
          ),
        ),
      )
    _ -> model
  }
  run_event(updated, protocol.ServerError(code, message))
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
  case layout.strip_height(model) > 0 {
    False -> model
    True -> {
      let #(roster, repaint) =
        agent_roster.tick(model.shared.roster, model.shared.stamp.now_ms)
      let model = Model(..model, shared: Shared(..model.shared, roster:))
      case repaint {
        agent_roster.Changed -> tui_model.invalidate_frame(model)
        agent_roster.Unchanged -> model
      }
    }
  }
}
