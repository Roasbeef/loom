//// Applies what the session channel delivers to the model.
////
//// The websocket actor owns transport I/O; this module owns what the
//// traffic means. `drain_connection` takes a bounded batch from the
//// connection inbox, `apply_channel_update` folds each channel update into
//// the model, and `apply_event` handles each pushed event: stream
//// fragments, tool output tails, durable entries, strand phases, usage and
//// the replies to side-surface reads. A captured snapshot cut is projected
//// by `render_cut` into the transcript, approvals, workspaces and cache
//// watches.
////
//// Live streams stay separate from durable entries because the server may
//// replay the settled entry after its fragments; the stream is dropped
//// when its entry lands, so the answer is never shown twice. Usage and
//// prompt-cache accounting live here too, since both are observed on the
//// same events.

import core/entry
import core/ids
import core/json
import core/message
import core/origin
import core/register
import etui/widgets/textarea as text_area
import gleam/bit_array
import gleam/bool
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import gleam/string
import host/build_identity
import machine/strand as machine_strand
import tui/advisor_history
import tui/agent_message_panel
import tui/agent_messages
import tui/agent_strip
import tui/agent_view
import tui/agents
import tui/approval
import tui/approval_panel
import tui/bootstrap
import tui/cache_miss
import tui/command
import tui/completion_summary
import tui/composer
import tui/connection
import tui/context_view
import tui/daemon
import tui/daemon/protocol as control_protocol
import tui/daemon/selection as daemon_selection
import tui/history_view
import tui/layout
import tui/model.{
  type Interrupt, type Line, type Model, type Peer, type Reconnect,
  type StrandWorkspace, type Stream, type Submission, type ToolTail,
  type UnconfirmedSubmission, AgentInspector, ApprovalInspector, Assistant,
  Attached, CacheNotice, CacheObservation, DaemonSelector, Disconnected,
  GoalInspector, HeldPrompt, HoldGoalReport, Interjection, Interrupt, Line,
  Model, ModelSelector, NoOverlay, PeerLinkManager, Preview, PromptNext,
  ReconnectAttempting, ReconnectIdle, ReconnectSpent, Replaying, SessionSelector,
  StrandWorkspace, Stream, System, ToolTail, UnconfirmedSubmission, User,
} as tui_model
import tui/model_selector
import tui/note_panel
import tui/outbound
import tui/protocol.{Strand}
import tui/queue_editor
import tui/queue_panel
import tui/recording
import tui/render
import tui/reviewer_status
import tui/session_channel
import tui/sessions
import tui/snapshot
import tui/snapshot_view
import tui/stream_identity
import tui/surfaces
import tui/todo_panel
import tui/transcript_lines
import tui/workspace
import tui/worktree_view
import weft

/// The authenticated build belongs to the retained control host. Projecting
/// its mismatch on every coherent cut keeps attachment and later captures from
/// erasing the update notice when they replace the transcript presentation.
@internal
pub fn daemon_build_lines(host: Option(daemon_selection.Host)) -> List(Line) {
  case host {
    None -> []
    Some(host) ->
      build_mismatch_lines(daemon.hello(daemon_selection.control(host)).build)
  }
}

fn build_mismatch_lines(build: Option(control_protocol.Build)) -> List(Line) {
  case build {
    None -> []
    Some(theirs) -> {
      let ours = build_identity.current()
      let theirs = build_identity.Identity(theirs.version, theirs.commit)
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
}

// The bounded relaunch budget. It is the same ninety seconds the initial
// local launch is allowed, because the work is the same: a launch lock, a
// daemon start, and two authenticated probes.
const reconnect_timeout_ms = 90_000

/// Decides whether one unexpected daemon death earns a reconnect.
///
/// The decision is a pure read of the terminal's own state, taken at the
/// moment the transport reported the loss, so it can be reasoned about (and
/// tested) without a daemon. The three refusals are each a different fact:
/// an operator quit is not a failure to recover from, a remote attachment has
/// no launch to re-run, and an attempt already spent means the operator is
/// owed an error rather than a loop.
fn reconnect_decision(model: Model) -> ReconnectDecision {
  case model.quit {
    True -> ReconnectRefused("the terminal is closing")
    False ->
      case model.session {
        "" -> ReconnectRefused("no session is attached")
        session ->
          case model.local_options {
            None -> ReconnectRefused("this attachment was not launched locally")
            Some(options) ->
              reconnect_state_decision(model.reconnect, session, options)
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
      let cancel = weft.cancel_signal()
      let replies = process.new_subject()

      // The relaunch runs in its own bounded task because it blocks: it may
      // take the launch lock, start a daemon, and authenticate two sockets.
      // Nothing but the two scalars it needs is captured, because weft copies
      // a fun's environment into the worker — and a closure over a model
      // field would copy the transcript, the row caches and the cached frame
      // with it.
      let owner = process.self()
      let _relay =
        weft.new([
          fn() {
            daemon_selection.relaunch(options, owner, reconnect_timeout_ms)
          },
        ])
        |> weft.deadline(reconnect_timeout_ms)
        |> weft.cancel_with(cancel)
        |> weft.start_relayed(replies)
      Model(
        ..model,
        reconnect: ReconnectAttempting(cancel, replies),
        notice: "reconnecting to session " <> session,
      )
      |> tui_model.invalidate_frame
    }
  }
}

/// Advances the session channel's timers and applies every update they
/// produce, then services a pending history read.
@internal
pub fn tick_channel(model: Model) -> Model {
  case model.channel {
    None -> model
    Some(channel) -> {
      let #(channel, updates) = session_channel.tick(channel)
      list.fold(
        updates,
        Model(..model, channel: Some(channel)),
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
      outbound.apply_submission(model, disposition)
    session_channel.Captured(cut, view, trigger) ->
      reconcile_cut(model, cut, view, trigger)
    session_channel.HistoryPage(window, before, after) ->
      receive_history(model, window, before, after)
    session_channel.LookedUp(records, missing) -> {
      let inspected = inspect_looked_up(model, records, missing)
      let updated =
        Model(
          ..inspected,
          approvals: approval.decisions(model.approvals, records, missing),
        )
      let updated = case updated.captured {
        Some(#(cut, view)) -> render_cut(updated, cut, view, updated.approvals)
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
    session_channel.Auxiliary(event) -> apply_event(model, event)
    session_channel.RequestRefused("history", _, code, message) ->
      tui_model.append_error(
        Model(..model, scrollback: history_view.cancel(model.scrollback)),
        "Older history: " <> code <> ": " <> message,
      )
    session_channel.RequestRefused(command, request_id, code, message) ->
      apply_request_refused(model, command, request_id, code, message)

    // Nothing here is visible, and that is the point: the count moves for
    // every notice the daemon pushed, including the ones a held sequence or
    // an in-flight refresh made redundant. The rendered frame is untouched,
    // so this cannot invalidate it.
    session_channel.Noticed(_) -> Model(..model, notices: model.notices + 1)

    // A pushed fragment is the same thing the directly attached client
    // receives as a stream delta, so it lands in the same live-stream region
    // by the same route rather than through a second renderer.
    session_channel.Streamed(strand:, operation:, generation:, kind:, text:) ->
      apply_event(
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
      apply_event(
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
        ..model,
        queue_editor: queue_editor.new(),
        notice: "queued input updated",
      )
      |> tui_model.invalidate_frame
    session_channel.Acknowledged("prompt", "queued") ->
      Model(
        ..settle_own_turn(model),
        submitting: None,
        notice: "prompt queued for the next turn",
      )
      |> tui_model.invalidate_frame

    // An abort ends the run, and with it every steer and follow-up the run
    // had not started yet: the queue drains those without committing them,
    // so no entry will ever arrive to retire their interjections. A held
    // prompt is not the run's to cancel — it waits in the gateway and drains
    // once the strand is idle — so the abort drops the interjections and
    // leaves the prompt echoes standing.
    session_channel.Acknowledged("abort", status) ->
      Model(..abandon_interjections(model), notice: "abort " <> status)
      |> tui_model.invalidate_frame

    // Every other acknowledgement settles its submission the same way: a
    // steer answered `admitted` will commit the entry its interjection is
    // waiting for. Commands that record nothing leave `awaiting_outcome`
    // empty and pass through untouched.
    session_channel.Acknowledged(command, status) ->
      Model(..settle_own_turn(model), notice: command <> " " <> status)
      |> tui_model.invalidate_frame
    session_channel.UnknownOutcome(command, request_id) ->
      tui_model.append_error(
        Model(
          ..model,
          queue_editor: case command {
            "edit_queued_input" -> queue_editor.unknown(model.queue_editor)
            _ -> model.queue_editor
          },
          unconfirmed: Some(UnconfirmedSubmission(
            model.session,
            command,
            request_id,
          )),
        ),
        "Last unconfirmed submission: " <> command <> "; not retried",
      )
    session_channel.Failed(reason) ->
      tui_model.append_error(
        Model(
          ..outbound.discard_own_turn(model),
          peer: after_close(model.peer),
          scrollback: history_view.cancel(model.scrollback),
          streams: [],
          tool_tails: [],
          queue_editor: queue_editor.refused(
            model.queue_editor,
            "Disconnected; draft retained",
          ),
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
          overlay: case model.overlay {
            GoalInspector(_) -> NoOverlay
            other -> other
          },
          worktree: case model.worktree.awaiting {
            Some(id) ->
              worktree_view.receive(
                model.worktree,
                tui_model.queue_owner(model),
                worktree_view.Failed(id, "conversation disconnected"),
              )
            None -> model.worktree
          },
        ),
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
  case model.captured {
    Some(#(previous, _))
      if previous.next_seq == cut.next_seq && previous.metadata == cut.metadata
    -> present_pending_approval(Model(..model, captured: Some(#(cut, view))))
    Some(_) | None -> {
      let updated = apply_cut(Model(..model, last_capture: trigger), cut, view)
      let updated = case model.captured {
        Some(#(previous, _)) if previous.next_seq == cut.next_seq -> updated
        Some(_) | None -> request_visible_worktree(updated)
      }
      let disappeared =
        model.approvals
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
  case model.peer {
    // A replay performs no outbound effect and invents no line the live
    // client was not shown. Whatever the live client learned about these
    // decisions is already in the recording; a "conversation is not
    // attached" error here would be a line no live session ever produced.
    Replaying -> model

    Attached(_) | Disconnected | Preview ->
      case model.channel {
        None -> tui_model.append_error(model, "conversation is not attached")
        Some(channel) ->
          case session_channel.lookup(channel, ids) {
            Ok(channel) -> Model(..model, channel: Some(channel))
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
    Ok(current) -> approval.project(model.approvals, current)
    Error(_) -> []
  }
  render_cut(model, cut, view, reviews) |> present_pending_approval
}

// A question is offered once per exact sequence. Deferring one leaves it in
// /approvals, while a reopened request with the same ID is a new question.
fn present_pending_approval(model: Model) -> Model {
  case model.overlay, model.captured {
    NoOverlay, Some(#(cut, _)) if cut.attachment.role != snapshot.Observer -> {
      let seen =
        list.filter(model.prompted_approvals, fn(identity) {
          list.any(model.approvals, fn(record) {
            #(record.id, record.seq) == identity
          })
        })
      let unseen =
        list.find(model.approvals, fn(record) {
          record.status == approval.Pending
          && !list.contains(seen, #(record.id, record.seq))
        })
      case unseen {
        Error(Nil) -> Model(..model, prompted_approvals: seen)
        Ok(record) ->
          Model(
            ..model,
            prompted_approvals: [#(record.id, record.seq), ..seen],
            overlay: ApprovalInspector(captured_approval_panel(model, record)),
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
  let active = model.active_strand
  let model = observe_completion(model, cut, view, active)
  let model = retain_queue_selection(model, view, active)
  let same_operation = case model.captured {
    Some(#(_, previous)) ->
      model.active_strand == active
      && dict.get(previous.operations, model.active_strand)
      == dict.get(view.operations, active)
    None -> False
  }
  let history = history_view.capture(model.scrollback, cut.window, view, active)
  let branch = history_view.branch(history, view)
  let current_model = case dict.get(view.configurations, active) {
    Ok(config) -> config.configuration.model.model_id
    Error(Nil) -> "unconfigured"
  }
  let #(cache_watch, cache_fence) = cache_watches_for_cut(model, view)
  let cache_outlook = case dict.get(cache_watch, active) {
    Ok(_) -> model.cache_outlook
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
      daemon_build_lines(model.daemon_host),
      list.append(
        configuration_lines(view, active),
        list.append(
          unconfirmed_lines(model.unconfirmed),
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
    model.record_cache_valid
    && model.active_strand == active
    && model.records == branch.records
    && model.advisor_history == advisor_history
    && model.transcript == transcript
    && transcript_lines.solo_owner(model.captured)
    == transcript_lines.solo_owner(Some(#(cut, view)))

  // Request-scoped pushes outrun captures: a cut may have started before
  // the request that is streaming now. Retain those observations, including
  // terminal markers, until an exact durable last result proves retirement.
  // An unrelated idle cut cannot retire a newer request. This fallback also
  // covers relay failures which bypass the optional presentation observer.
  // Legacy recordings retain their operation-based law.
  let operation = dict.get(view.operations, active)
  let live =
    list.filter(model.streams, fn(stream) {
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
    list.filter(model.tool_tails, fn(tail) {
      !snapshot_view.has_tool_result(
        view,
        cut.window,
        tail.strand,
        tail.call_id,
      )
      && !snapshot_view.has_result(view, tail.strand, tail.operation)
    })

  // Retired strands keep unsent drafts but release their bounded reading
  // windows. A future appearance must rebuild history from its own capture.
  let workspaces =
    prune_workspace_history(
      model.strand_workspaces,
      model.session,
      view.strands,
    )
  let reviewers = reviewer_status.observe(model.reviewer_rows, cut.window, view)
  let rows = agent_view.observe(model.agent_rows, cut.window, view, reviewers)
  let captured_messages =
    agent_messages.capture(model.agent_messages, view, cut.window)

  // A strand whose capture reaches no `todo` call may still have a board
  // in its notes, the usual case after reattaching to a long session, so
  // its first capture asks for one notes read to seed the panel.
  let boards = todo_panel.remember(model.todo_boards, branch.records)
  let #(todo_seed, todo_asked) = case
    todo_panel.needs_seed(boards, model.todo_asked, active)
  {
    True -> #(Some(active), set.insert(model.todo_asked, active))
    False -> #(model.todo_seed, model.todo_asked)
  }
  Model(
    ..model,
    captured: Some(#(cut, view)),
    approvals: reviews,
    active_strand: active,
    strands: view.strands,
    agent_summary: agents.summary_rows(rows),
    reviewer_rows: reviewers,
    agent_rows: rows,
    strip: agent_strip.observe(model.strip, view, model.monotonic_time_ms()),
    agent_messages: captured_messages,
    advisor_history:,
    todo_boards: boards,
    todo_seed:,
    todo_asked:,
    records: branch.records,
    scrollback: history,
    strand_workspaces: workspaces,
    activity_started_ms: case same_operation {
      True -> model.activity_started_ms
      False -> None
    },
    activity_elapsed_s: case same_operation {
      True -> model.activity_elapsed_s
      False -> 0
    },
    usage: view.usage,
    current_model: current_model,
    cache_watch:,
    cache_fence:,
    cache_outlook:,
    streams: live,
    tool_tails: live_tails,
    interrupt: reconcile_interrupt(model.interrupt, view.operations),
    queued: case view.pending_inputs {
      Some(_) -> []
      None -> model.queued
    },
    submitting: None,
    record_cache_valid:,
    // Presence already has its own banner. Repeated metadata captures must
    // not alternate that banner with streaming or operator feedback below.
    notice: case model.captured {
      None -> notice
      Some(_) -> model.notice
    },
    transcript:,
  )
  |> settle_pending_cache(cut.next_seq)
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
    ..configuration
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
  case model.overlay, model.inspecting_approval {
    ApprovalInspector(_), _ -> Model(..model, inspecting_approval: None)
    _, Some(id) ->
      case list.find(records, fn(record: approval.Review) { record.id == id }) {
        Ok(record) ->
          Model(
            ..model,
            overlay: ApprovalInspector(captured_approval_panel(model, record)),
            inspecting_approval: None,
          )
        Error(Nil) ->
          case list.contains(missing, id) {
            True -> Model(..model, inspecting_approval: None)
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
  case outbound.mutation_refusal(model, command.Approve(record.id)) {
    Some(reason) -> tui_model.append_error(model, reason)
    None -> {
      let encoded = case choice {
        approval_panel.AllowOnce -> approval.approve(model.next_id, record)
        approval_panel.AllowSession ->
          approval.approve_for_session(model.next_id, record)
        approval_panel.Deny -> approval.deny(model.next_id, record)
      }
      case encoded {
        Error(reason) -> tui_model.append_error(model, reason)
        Ok(frame) ->
          outbound.send_frame(Model(..model, overlay: NoOverlay), frame)
      }
    }
  }
}

/// Encodes and sends a decision for the displayed approval `id`. A decision
/// that is not on screen is refused, so the operator only answers what they
/// have seen.
@internal
pub fn decide(
  model: Model,
  id: String,
  encode: fn(Int, approval.Review) -> Result(String, String),
) -> Model {
  case list.find(model.approvals, fn(record) { record.id == id }) {
    Error(Nil) ->
      tui_model.append_error(
        model,
        "decision is not displayed; load /approvals " <> id <> " first",
      )
    Ok(record) ->
      case encode(model.next_id, record) {
        Error(reason) -> tui_model.append_error(model, reason)
        Ok(frame) -> outbound.send_frame(model, frame)
      }
  }
}

/// Applies a message from the local session-switch worker: a failure is
/// reported in the transcript, and a ready socket is adopted as the new
/// attachment.
@internal
pub fn handle_session_switch_message(
  model: Model,
  message: sessions.Message,
) -> Model {
  case message {
    sessions.Failed(session, reason) ->
      tui_model.append_error(
        Model(..model, session_switch: sessions.Idle),
        "open session " <> session <> ": " <> reason,
      )
      |> tui_model.mark_activity
    sessions.WorkerCrashed(session, reason) ->
      tui_model.append_error(
        Model(..model, session_switch: sessions.Idle),
        "open session " <> session <> " crashed: " <> reason,
      )
      |> tui_model.mark_activity
    sessions.Ready(choice, options, target, inbox, socket) ->
      case connection.adopt(socket) {
        Error(reason) -> {
          connection.close(socket)
          sessions.discard(inbox)
          tui_model.append_error(
            Model(..model, session_switch: sessions.Idle),
            "open session " <> target.session <> ": " <> reason,
          )
          |> tui_model.mark_activity
        }
        Ok(Nil) -> adopt_session(model, choice, options, target, inbox, socket)
      }
  }
}

fn adopt_session(
  model: Model,
  choice: bootstrap.SessionChoice,
  options: bootstrap.Options,
  target: bootstrap.Target,
  inbox: Subject(connection.Message),
  socket: connection.Connection,
) -> Model {
  let model = select_workspace(model, target.session, "main")
  case model.peer {
    Attached(socket: previous) -> connection.close(previous)
    Preview | Replaying | Disconnected -> Nil
  }

  // Frames the old socket already delivered would otherwise sit unread in
  // the terminal mailbox for every later selective receive to scan past. The
  // close notice it sends after this point is the only residue, one frame.
  sessions.discard(model.inbox)
  Model(
    ..model,
    help_open: False,
    notes_open: False,
    note_board: None,
    note_selected: None,
    notes_requested: None,
    overlay: NoOverlay,
    session: target.session,
    local_options: Some(options),
    inbox:,
    peer: Attached(socket:),
    session_switch: sessions.Idle,
    next_id: 4,
    transcript: [Line(System, "connecting to session " <> target.session)],
    records: [],
    models: [],
    skills: [],
    queued: [],
    awaiting_outcome: None,
    current_model: "loading…",
    workspace: workspace.discover_from(choice.workspace),
    strands: [],
    agent_summary: agents.summary([]),
    reviewer_rows: [],
    active_strand: "main",
    usage: zero_usage(),
    interrupt: None,
    submitting: None,
    streams: [],
    reading_lines: None,
    tool_tails: [],
    scroll_offset: 0,
    rendered_revision: -1,
    rendered_row_count: 0,
    rendered_rows: [],
    revealed_rows: 0,
    rendered_anchors: [],
    rendered_gutters: [],
    record_rows: [],
    record_gutters: [],
    record_line_cache: dict.new(),
    compact_call_cache: dict.new(),
    compact_entry_cache: dict.new(),
    pending_records: [],
    record_cache_valid: False,
    record_cache_width: 0,
    record_cache_strand: "",
    frame_cache: None,
    notice: "connecting to session " <> target.session,
    repaint_phase: !model.repaint_phase,
  )
  |> tui_model.invalidate_transcript
  |> tui_model.mark_activity
  |> tui_model.invalidate_frame
}

/// Applies at most `remaining` messages from the connection inbox.
@internal
pub fn drain_connection(model: Model, remaining: Int) -> Model {
  // The budget is checked before receiving: an eager second case subject
  // would remove and discard the first message belonging to the next batch.
  case remaining <= 0 {
    True -> model
    False ->
      case connection.receive(model.inbox) {
        Error(Nil) -> model
        Ok(message) ->
          drain_connection(
            handle_connection_message(model, message),
            remaining - 1,
          )
      }
  }
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
  incoming: connection.Message,
) -> Model {
  handle_connection_message(model, incoming)
}

fn handle_connection_message(
  model: Model,
  incoming: connection.Message,
) -> Model {
  case model.channel {
    Some(channel) -> {
      let #(channel, updates) = session_channel.receive(channel, incoming)
      list.fold(
        updates,
        Model(..model, channel: Some(channel)),
        apply_channel_update,
      )
    }
    None -> {
      recording.note_message(model.recorder, incoming)
      handle_presentation_message(model, incoming)
    }
  }
}

fn handle_presentation_message(
  model: Model,
  incoming: connection.Message,
) -> Model {
  case incoming {
    connection.Connected ->
      Model(..model, notice: "connected")
      |> tui_model.mark_activity
      |> tui_model.invalidate_frame
    connection.Closed(reason) ->
      tui_model.append_error(
        Model(
          ..model,
          peer: after_close(model.peer),
          streams: [],
          tool_tails: [],
        ),
        "connection closed: " <> reason,
      )
      |> begin_reconnect
      |> tui_model.mark_activity
    connection.NetworkFault(reason) ->
      tui_model.append_error(model, "network: " <> reason)
      |> tui_model.mark_activity
    connection.Incoming(text) ->
      case protocol.decode_event(text) {
        Ok(event) -> apply_event(model, event)
        Error(reason) ->
          tui_model.append_error(model, "protocol: " <> reason)
          |> tui_model.mark_activity
      }
  }
}

fn apply_event(model: Model, event: protocol.Event) -> Model {
  let updated = case event {
    protocol.FullSnapshot(session:, strands:, entries:, usage:) -> {
      let target = case model.session == session {
        True -> model.active_strand
        False -> "main"
      }
      let model = select_workspace(model, session, target)
      Model(
        ..model,
        session:,
        active_strand: target,
        strands:,
        agent_summary: agents.summary(strands),
        usage:,
        records: list.reverse(entries),
        streams: [],
        tool_tails: [],
        record_rows: [],
        record_gutters: [],
        record_line_cache: dict.new(),
        compact_call_cache: dict.new(),
        compact_entry_cache: dict.new(),
        // The snapshot is the server's own account of the strand, so it
        // already carries every submission the daemon committed while this
        // client was away — the gateway holds its queue across a disconnect
        // and drains it regardless. An echo kept across the rebuild would sit
        // under the committed copy of itself.
        queued: [],
        awaiting_outcome: None,
        pending_records: [],
        record_cache_valid: False,
        submitting: None,
        scroll_offset: 0,
        notice: "session synchronized",
        transcript: [Line(System, "attached to session " <> session)],
      )
      |> tui_model.invalidate_transcript
    }
    protocol.StrandsSnapshot(strands:) -> {
      let summary = agents.summary(strands)
      Model(..model, strands:, agent_summary: summary)
    }
    protocol.SkillsSnapshot(page:) -> {
      let previous = case page.offset {
        0 -> []
        _ -> model.skills
      }
      case page.offset == list.length(previous) {
        False ->
          tui_model.append_error(
            model,
            "skill catalogue page arrived out of order",
          )
        True -> {
          let loaded =
            Model(..model, skills: list.append(previous, page.commands))
          case page.next {
            None -> loaded
            Some(offset) ->
              outbound.send_frame(
                loaded,
                protocol.skills(loaded.next_id, offset),
              )
          }
        }
      }
    }
    protocol.ModelsSnapshot(models:) -> {
      let overlay = case model.overlay {
        ModelSelector(selector) ->
          ModelSelector(model_selector.replace_models(
            selector,
            models,
            model.current_model,
          ))
        NoOverlay -> NoOverlay
        AgentInspector(selected) -> AgentInspector(selected)
        GoalInspector(state) -> GoalInspector(state)
        SessionSelector(selector) -> SessionSelector(selector)
        DaemonSelector(selector) -> DaemonSelector(selector)
        PeerLinkManager(state) -> PeerLinkManager(state)
        ApprovalInspector(panel) -> ApprovalInspector(panel)
      }
      Model(
        ..model,
        models:,
        overlay:,
        notice: int.to_string(list.length(models)) <> " models loaded",
      )
      |> outbound.send_frame(protocol.skills(model.next_id, 0))
    }
    protocol.SchedulesSnapshot(schedules:) -> append_schedules(model, schedules)
    protocol.ConfigSnapshot(model_name:, directories:) -> {
      let model = case model_name {
        Some(name) -> {
          let selected = select_model(model, name)
          Model(..selected, notice: "model: " <> name)
        }
        None -> model
      }
      case directories {
        None -> model
        Some(value) ->
          Model(
            ..model,
            notice: "Session directory access: " <> json.to_string(value),
          )
      }
    }
    protocol.LiveJobsSnapshot(board) -> surfaces.receive_jobs(model, board)
    protocol.AdvisorPendingSnapshot(board) ->
      surfaces.receive_advisor_nudges(model, board)
    protocol.GoalSnapshot(board) -> surfaces.receive_goal(model, board)
    protocol.ContextSnapshot(observation) ->
      Model(
        ..model,
        context: context_view.receive(
          model.context,
          tui_model.queue_owner(model),
          observation,
        ),
      )
    protocol.WorktreeSnapshot(observation) ->
      Model(
        ..model,
        worktree: worktree_view.receive(
          model.worktree,
          tui_model.queue_owner(model),
          observation,
        ),
      )
      |> tui_model.invalidate_transcript
    protocol.QueuedInputSnapshot(document) ->
      Model(
        ..model,
        queue_editor: queue_editor.receive(
          model.queue_editor,
          tui_model.queue_owner(model),
          tui_model.queue_namespace(model),
          document,
        ),
      )
    protocol.NotesSnapshot(board) -> {
      // Every notes read may carry a strand's todo board, whichever surface
      // asked for it, so the panel is seeded before the notes view decides
      // whether this read is its own.
      let model =
        Model(..model, todo_boards: todo_panel.seed(model.todo_boards, board))
      case board.strand == surfaces.notes_target(model) {
        True -> {
          let previous = case model.note_board {
            Some(old) if old.strand == board.strand ->
              render.selected_note(model, old)
            _ -> model.note_selected
          }
          let selected =
            render.selected_note(Model(..model, note_selected: previous), board)
          let scroll = case model.note_board, selected == model.note_selected {
            Some(old), True if old.strand == board.strand ->
              int.min(
                model.note_scroll,
                note_max_scroll(
                  Model(
                    ..model,
                    note_board: Some(board),
                    note_selected: selected,
                  ),
                ),
              )
            None, True | Some(_), True | None, False | Some(_), False -> 0
          }
          tui_model.invalidate_transcript(
            Model(
              ..model,
              note_board: Some(board),
              note_selected: selected,
              note_scroll: scroll,
              // A read the terminal sent to seed the todo panel is not
              // news to an operator who has no notes surface open.
              notice: case surfaces.notes_surface(model) {
                True -> "notes refreshed for " <> board.strand
                False -> model.notice
              },
            ),
          )
        }
        False -> model
      }
    }
    protocol.EntryAdded(record:) -> {
      let protocol.EntryRecord(strand:, ..) = record
      let updated =
        Model(
          ..model,
          records: [record, ..model.records],
          todo_boards: todo_panel.remember(model.todo_boards, [record]),
          streams: transcript_lines.clear_streams(model.streams, strand),
          tool_tails: retire_recorded_tail(model.tool_tails, record),
          pending_records: case strand == model.active_strand {
            True -> [record, ..model.pending_records]
            False -> model.pending_records
          },
          // A committed user turn on this strand is the daemon draining the
          // head of its queue, so the echo standing in for it goes away.
          queued: case strand == model.active_strand {
            True -> drained_echoes(model.queued, record)
            False -> model.queued
          },
        )
      case strand == model.active_strand {
        True -> tui_model.invalidate_transcript(updated)
        False -> updated
      }
    }
    protocol.StreamDelta(strand:, operation:, generation:, kind:, text:) -> {
      // The generation clock normally started when the strand entered
      // its `assistant` phase (see `OperationChanged`); a fragment that
      // finds it unset is the fallback, for a phase sequence that never
      // said so. Later fragments, and other strands, leave it alone.
      let generation_started_ms = generation_clock(model, strand)
      let updated =
        Model(
          ..model,
          streams: receive_stream(
            streams_before_end(model, strand, operation, generation, kind),
            strand,
            operation,
            generation,
            kind,
            text,
          ),
          generation_started_ms:,
          notice: case kind {
            "end" -> "request finished"
            _ -> "streaming " <> kind
          },
        )
      case strand == model.active_strand {
        True -> tui_model.invalidate_transcript(updated)
        False -> updated
      }
    }
    protocol.OperationChanged(strand:, phase:) -> {
      let submitting = case model.submitting {
        Some(target) if target == strand -> None
        other -> other
      }
      let strands = set_strand_phase(model.strands, strand, phase)

      // The rate's clock starts when the request goes out, not when the
      // first fragment lands. A provider that streams whole parts —
      // Gemini does — can deliver a short reply as one burst at the end
      // of a generation, and a clock started on that burst measured a
      // millisecond and reported six-figure tokens per second.
      let generation_started_ms = case phase {
        "assistant" -> generation_clock(model, strand)
        _other -> model.generation_started_ms
      }

      let updated =
        Model(
          ..model,
          submitting:,
          strands:,
          generation_started_ms:,
          agent_summary: agents.summary(strands),
          streams: case phase == "done" {
            True -> transcript_lines.clear_streams(model.streams, strand)
            False -> model.streams
          },
          tool_tails: case phase == "done" {
            True -> clear_tails(model.tool_tails, strand)
            False -> model.tool_tails
          },
          notice: strand <> ": " <> phase,
        )
      let settled = settle_interrupt(updated, strand, phase)
      case phase == "done" && strand == model.active_strand {
        True -> tui_model.invalidate_transcript(settled)
        False -> settled
      }
    }

    // A tail replaces the one it supersedes rather than joining a list:
    // the frame carries the whole window, so the newest is the only one
    // worth drawing, and the region cannot grow with the command's output.
    protocol.ToolOutput(
      strand:,
      operation:,
      step:,
      source_index:,
      call_id:,
      stream:,
      text:,
      total_bytes:,
    ) -> {
      let updated =
        Model(
          ..model,
          tool_tails: receive_tail(
            model.tool_tails,
            ToolTail(
              strand:,
              operation:,
              step:,
              source_index:,
              call_id:,
              stream:,
              text:,
              total_bytes:,
            ),
          ),
        )
      case strand == model.active_strand {
        True -> tui_model.invalidate_transcript(updated)
        False -> updated
      }
    }
    protocol.UsageChanged(strand:, seq:, operation:, usage: settled) ->
      case seq {
        Some(seq) ->
          receive_usage_observation(model, strand, seq, operation, settled)
        None -> receive_usage(model, strand, settled)
      }

    protocol.EscalationPending(id:, tool:, preview: _) ->
      tui_model.append_error(
        model,
        "approval required for " <> tool <> " [" <> id <> "]",
      )

    // The refusal answers whatever this terminal last submitted, because the
    // conversation channel carries one mutation at a time. A prompt refused
    // for a full hold queue commits no entry, so its echo is retired here or
    // never.
    protocol.ServerError(code:, message:) ->
      tui_model.append_error(
        Model(..outbound.discard_own_turn(model), submitting: None),
        code <> ": " <> message,
      )

    // A commit notice and a metadata change say only that the next capture
    // will differ. `tui/session_channel` acts on them by capturing; there is
    // nothing for a renderer to draw from the frame itself.
    protocol.Committed(..) | protocol.MetadataChanged -> model

    // A resumed marker names a stream that continues from a cut this
    // terminal already holds. The lane reports it as its own update, so a
    // frame arriving outside one is nothing to paint.
    protocol.Resumed(_) -> model
    protocol.Ignored(_) -> model

    // The draining daemon handed a held prompt back, unsent. The held
    // queue is memory-only, so this push is the draft's last copy: restore
    // it into the composer rather than letting the operator's text die
    // with the daemon. An empty composer takes the text outright; an
    // occupied one keeps what the operator is typing, and the return is
    // appended below it — both are theirs, and neither may be lost.
    // The return carries no attachment bytes. Its count tells the operator
    // which images must be reattached before submitting the restored draft.
    protocol.HeldInputReturned(strand:, kind:, text:, attachment_count:, ..) ->
      restore_returned_draft(model, strand, kind, text, attachment_count)
  }
  case event {
    protocol.Committed(..) | protocol.MetadataChanged -> updated
    protocol.Resumed(_) -> updated
    protocol.HeldInputReturned(..) -> updated
    protocol.Ignored(_) -> updated
    protocol.FullSnapshot(..)
    | protocol.StrandsSnapshot(..)
    | protocol.ModelsSnapshot(..)
    | protocol.SkillsSnapshot(..)
    | protocol.NotesSnapshot(..)
    | protocol.QueuedInputSnapshot(..)
    | protocol.ContextSnapshot(..)
    | protocol.WorktreeSnapshot(..)
    | protocol.LiveJobsSnapshot(..)
    | protocol.AdvisorPendingSnapshot(..)
    | protocol.GoalSnapshot(..)
    | protocol.SchedulesSnapshot(..)
    | protocol.ConfigSnapshot(..)
    | protocol.EntryAdded(..)
    | protocol.StreamDelta(..)
    | protocol.ToolOutput(..)
    | protocol.OperationChanged(..)
    | protocol.UsageChanged(..)
    | protocol.EscalationPending(..)
    | protocol.ServerError(..) ->
      updated
      |> tui_model.mark_activity
      |> tui_model.invalidate_frame
  }
}

// Restores a custody-returned prompt as a local draft (protocol-change/038).
//
// The daemon held the prompt only in memory, so the returned text must be
// retained before the socket closes. An untouched composer simply becomes the draft.
// A composer the operator is typing in keeps its text and grows the return
// below it, separated by a blank line: discarding either half would lose
// work the operator can see, and silently replacing the draft would move
// text out from under the cursor. The notice names the strand and the
// images the text cannot carry, so nothing about the return is invisible.
fn restore_returned_draft(
  model: Model,
  strand: String,
  kind: String,
  text: String,
  attachment_count: Int,
) -> Model {
  // A return follows the prompt's original recipient even if the operator
  // has opened another strand since submitting it. Only that owner's draft
  // can accept the returned text.
  let model = case strand == model.active_strand {
    True -> Model(..model, input: append_returned_text(model.input, text))
    False -> {
      let owner = #(model.session, strand)
      let saved =
        dict.get(model.strand_workspaces, owner)
        |> result.unwrap(empty_workspace())
      let saved =
        StrandWorkspace(..saved, input: append_returned_text(saved.input, text))
      Model(
        ..model,
        strand_workspaces: dict.insert(model.strand_workspaces, owner, saved),
      )
    }
  }
  let images = case attachment_count {
    0 -> ""
    n ->
      " · "
      <> int.to_string(n)
      <> " attachment(s) stayed on the dead daemon — re-attach them"
  }
  tui_model.append_notice(
    model,
    "daemon returned the "
      <> kind
      <> " prompt held for "
      <> strand
      <> " — restored as a draft"
      <> images,
  )
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

// One line per schedule, in the listing's own order — the operator's
// standing tables first, then what the session grew. `owner` is printed
// rather than derived: "operator" and a strand that happens to be called
// something similar are told apart by the server and never here.
fn append_schedules(model: Model, rows: List(protocol.ScheduleRow)) -> Model {
  case rows {
    [] -> tui_model.append_system(model, "no schedules")
    rows -> {
      let listed =
        list.fold(rows, model, fn(model, row) {
          tui_model.append_system(model, schedule_line(row))
        })
      Model(..listed, notice: int.to_string(list.length(rows)) <> " schedules")
    }
  }
}

fn schedule_line(row: protocol.ScheduleRow) -> String {
  string.join(
    [
      row.name,
      row.target,
      row.owner,
      row.when,
      int.to_string(row.fired) <> " fired",
      case row.wake {
        protocol.WakesIdle -> "wakes"
        protocol.SteersOnly -> "steers"
      },
    ],
    "  ",
  )
}

fn set_strand_phase(
  strands: List(protocol.Strand),
  target: String,
  phase: String,
) -> List(protocol.Strand) {
  list.map(strands, fn(strand) {
    let Strand(id:, ..) = strand
    case id == target, phase {
      True, "done" -> Strand(..strand, live_phase: None)
      True, _ -> Strand(..strand, live_phase: Some(phase))
      False, _ -> strand
    }
  })
}

// A client attaching near completion may have only a sampled preview, with
// no later delta before end. Transfer that exact sample into the bounded live
// region before adding the end marker; an older request's sample cannot qualify.
fn streams_before_end(
  model: Model,
  strand: String,
  operation: String,
  generation: String,
  kind: String,
) -> List(Stream) {
  use <- bool.guard(
    kind != "end"
      || stream_identity.response_entry(generation) == None
      || list.any(model.streams, fn(stream) { stream.strand == strand }),
    model.streams,
  )
  let preview = option.then(model.captured, fn(captured) { captured.1.preview })
  case preview {
    Some(sample)
      if sample.operation == operation && sample.generation == generation
    ->
      case transcript_lines.response_recorded(model.records, generation) {
        True -> model.streams
        False -> [
          transcript_lines.preview_stream(strand, sample),
          ..model.streams
        ]
      }
    _ -> model.streams
  }
}

// A provider request owns all its fragment kinds. A new request replaces
// them together; an old terminal can retire only its own request. Completion
// comes from the same observer as deltas, independent of snapshot timing.
fn receive_stream(
  streams: List(Stream),
  strand: String,
  operation: String,
  generation: String,
  kind: String,
  text: String,
) -> List(Stream) {
  // Completion is final for this exact request. Late fragments cannot
  // reopen it, while a successor still replaces the whole old generation.
  use <- bool.guard(
    kind != "end"
      && list.any(streams, fn(stream) {
      stream.strand == strand
      && stream.operation == operation
      && stream.generation == generation
      && stream.kind == "end"
    }),
    streams,
  )
  case kind {
    "end" -> {
      let newer =
        list.any(streams, fn(stream) {
          stream.strand == strand
          && {
            stream.operation != operation || stream.generation != generation
          }
        })
      case newer {
        True -> streams
        False -> {
          // A named response remains visible until its exact record replaces
          // it. The marker suppresses stale previews without copying text.
          let retained =
            list.filter(streams, fn(stream) {
              stream.strand != strand
              || {
                stream.kind != "end"
                && stream_identity.response_entry(generation) != None
              }
            })
          [Stream(strand, operation, generation, "end", [], 0), ..retained]
        }
      }
    }
    _ -> {
      let retained =
        list.filter(streams, fn(stream) {
          stream.strand != strand
          || {
            stream.operation == operation
            && stream.generation == generation
            && stream.kind != "end"
          }
        })
      append_stream(retained, strand, operation, generation, kind, text)
    }
  }
}

fn append_stream(
  streams: List(Stream),
  strand: String,
  operation: String,
  generation: String,
  kind: String,
  fragment: String,
) -> List(Stream) {
  let fragment = owned(fragment)
  let width = string.byte_size(fragment)
  case streams {
    [] -> [
      Stream(
        strand:,
        operation:,
        generation:,
        kind:,
        fragments: [fragment],
        bytes: width,
      ),
    ]
    [
      Stream(
        strand: owner,
        operation: current_op,
        generation: current_generation,
        kind: stream_kind,
        fragments: current,
        bytes: held,
      ),
      ..rest
    ] ->
      case owner == strand && stream_kind == kind {
        // A fragment from a later operation replaces the previous answer
        // rather than continuing it. Tool-call fragments never accumulate at
        // all: only the latest name is renderable until the entry commits.
        True -> {
          let #(fragments, bytes) = case
            kind == "tool_call" || current_op != operation
          {
            True -> #([fragment], width)
            False -> bounded([fragment, ..current], held + width)
          }
          [
            Stream(strand:, operation:, generation:, kind:, fragments:, bytes:),
            ..rest
          ]
        }
        False -> [
          Stream(
            strand: owner,
            operation: current_op,
            generation: current_generation,
            kind: stream_kind,
            fragments: current,
            bytes: held,
          ),
          ..append_stream(rest, strand, operation, generation, kind, fragment)
        ]
      }
  }
}

// A delta's text is a slice of the whole frame the socket delivered, so a
// model that keeps the slice keeps the frame: an answer of a hundred thousand
// tokens pinned a hundred thousand frames, which is most of what the resident
// terminals were made of. Rebuilding the string owns its bytes and lets the
// frame go, and at token size the copy is a few dozen bytes. This is the same
// reason, and the same remedy, as `gateway.preview_text`.
fn owned(text: String) -> String {
  text |> string.to_utf_codepoints |> string.from_utf_codepoints
}

// Past the budget the fragments are collapsed into one holding the newest
// bytes. Dropping the oldest one at a time would be the length of the answer
// per token; collapsing pays that once per budget's worth of tokens and
// leaves a single fragment for the next batch to accumulate against. What the
// reader loses is the head of an answer that has not committed yet, and the
// durable record replaces the whole region the moment it does.
//
// The trigger is twice what the collapse keeps, and the headroom is the whole
// point: collapsing back to exactly the limit would put the next token over
// it again, and the amortised cost would be the copy paid per token rather
// than once per budget. So the region is bounded by twice `live_stream_limit`
// rather than by it, and that is the number the invariant states.
fn bounded(fragments: List(String), bytes: Int) -> #(List(String), Int) {
  case bytes <= transcript_lines.live_stream_limit * 2 {
    True -> #(fragments, bytes)
    False -> {
      let newest =
        fragments
        |> list.reverse
        |> string.concat
        |> newest_bytes(transcript_lines.live_stream_limit)
      #([newest], string.byte_size(newest))
    }
  }
}

// The trailing `limit` bytes, backing off to the next character boundary when
// the cut would land inside a multi-byte one. Four attempts covers the widest
// UTF-8 sequence.
fn newest_bytes(text: String, limit: Int) -> String {
  let bytes = bit_array.from_string(text)
  let size = bit_array.byte_size(bytes)
  newest_suffix(bytes, int.max(0, size - limit), 4)
}

fn newest_suffix(bytes: BitArray, from: Int, attempts: Int) -> String {
  case attempts {
    0 -> ""
    _ -> {
      let taken =
        bit_array.slice(bytes, from, bit_array.byte_size(bytes) - from)
        |> result.try(bit_array.to_string)
      case taken {
        Ok(text) -> text
        Error(_) -> newest_suffix(bytes, from + 1, attempts - 1)
      }
    }
  }
}

// The tails this strand's calls are printing, newest frame winning per
// `{strand, operation, step, source_index, call_id, stream}`. Order is kept stable — a
// replaced tail keeps its place and a new key goes to the end — so two
// streams of one command do not swap positions on screen every time one
// of them speaks.
fn receive_tail(tails: List(ToolTail), incoming: ToolTail) -> List(ToolTail) {
  let same_key = fn(tail: ToolTail) {
    tail.strand == incoming.strand
    && tail.operation == incoming.operation
    && tail.step == incoming.step
    && tail.source_index == incoming.source_index
    && tail.call_id == incoming.call_id
    && tail.stream == incoming.stream
  }
  case list.any(tails, same_key) {
    True ->
      list.map(tails, fn(tail) {
        case same_key(tail) {
          True -> incoming
          False -> tail
        }
      })
    False ->
      case list.length(tails) >= transcript_lines.max_tool_tails {
        True -> list.append(list.drop(tails, 1), [incoming])
        False -> list.append(tails, [incoming])
      }
  }
}

fn clear_tails(tails: List(ToolTail), strand: String) -> List(ToolTail) {
  list.filter(tails, fn(tail) { tail.strand != strand })
}

fn retire_recorded_tail(
  tails: List(ToolTail),
  record: protocol.EntryRecord,
) -> List(ToolTail) {
  let protocol.EntryRecord(strand:, entry:) = record
  case entry {
    entry.MessageEntry(
      message: message.ToolResultMessage(tool_call_id:, ..),
      ..,
    ) ->
      list.filter(tails, fn(tail) {
        tail.strand != strand || tail.call_id != tool_call_id
      })
    _ -> tails
  }
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

// Everything one usage row changes about the model.
//
// The row arrives once per settled generation, so this is both the moment
// the output rate is known and the moment the prompt cache can be judged.
// Both readings are per event rather than cumulative, which is why they sit
// here rather than in the status-line arithmetic over `model.usage`.
fn receive_usage(
  model: Model,
  strand: String,
  settled: message.Usage,
) -> Model {
  let usage = add_usage(model.usage, settled)
  let updated =
    settle_usage(
      model,
      strand,
      settled,
      transcript_lines.tokens(usage.total_tokens) <> " tokens",
    )
  watch_cache(Model(..updated, usage:), strand, settled)
}

// The context a generation leaves the agent holding: everything it sent,
// cached or not, plus what it wrote.
fn context_size(usage: message.Usage) -> Int {
  usage.input + usage.cache_read + usage.cache_write + usage.output
}

// A network push is an observation of one durable row, not a second owner of
// session totals. A capture may already include its sequence, or a delayed
// push may arrive after that capture; only the capture sets cumulative usage.
// Sequence identity prevents duplicate pushes from resetting the cache clock.
// The cache comparison waits for a cut that covers this sequence, since a
// remote model change can reach the socket before its configuration capture.
fn receive_usage_observation(
  model: Model,
  strand: String,
  seq: Int,
  operation: Option(String),
  settled: message.Usage,
) -> Model {
  let seen = dict.get(model.cache_seen_seq, strand) |> result.unwrap(-1)
  use <- bool.guard(when: seq <= seen, return: model)

  // A row newer than any this strand has shown is the agent's current
  // context size. The sequence guard above is what keeps a delayed push from
  // replacing a newer reading in the strip.
  let model =
    Model(
      ..model,
      strip: agent_strip.observe_usage(
        model.strip,
        strand,
        operation,
        context_size(settled),
      ),
    )

  // A first row already included in a capture may have belonged to an
  // operation accepted under the previous model. The gateway can deliver
  // its push after the cut, so it cannot seed this strand's cache baseline.
  let already_covered = case
    model.captured,
    dict.get(model.cache_seen_seq, strand)
  {
    Some(#(cut, _)), Error(Nil) if seq < cut.next_seq -> True
    _, _ -> False
  }
  let observed =
    Model(
      ..model,
      cache_seen_seq: dict.insert(model.cache_seen_seq, strand, seq),
      cache_pending: case already_covered {
        True -> model.cache_pending
        False ->
          dict.insert(
            model.cache_pending,
            strand,
            CacheObservation(
              seq:,
              operation:,
              usage: settled,
              at: model.monotonic_time_ms(),
            ),
          )
      },
    )
    |> settle_usage(
      strand,
      settled,
      transcript_lines.tokens(settled.total_tokens) <> " tokens this turn",
    )
  case observed.captured {
    Some(#(cut, _)) -> settle_pending_cache(observed, cut.next_seq)
    None -> observed
  }
}

// A cut covers every committed row below next_seq and supplies the model
// configuration needed to compare its usage safely. Keep newer observations
// pending; the committed notice or periodic refresh will fetch their cut.
fn settle_pending_cache(model: Model, next_seq: Int) -> Model {
  dict.to_list(model.cache_pending)
  |> list.fold(model, fn(current, item) {
    let #(strand, CacheObservation(seq:, operation:, usage:, at:)) = item
    case seq < next_seq {
      True ->
        observed_cache_row(
          Model(
            ..current,
            cache_pending: dict.delete(current.cache_pending, strand),
          ),
          strand,
          operation,
          usage,
          at,
        )
      False -> current
    }
  })
}

fn observed_cache_row(
  observed: Model,
  strand: String,
  operation: Option(String),
  settled: message.Usage,
  at: Int,
) -> Model {
  case dict.get(observed.cache_fence, strand), operation {
    Ok(None), Some(op) ->
      Model(
        ..observed,
        cache_fence: dict.insert(observed.cache_fence, strand, Some(op)),
      )
    Ok(None), None -> observed
    Ok(Some(old)), Some(op) if old == op -> observed
    Ok(Some(_)), Some(_) ->
      watch_cache_at(
        Model(
          ..observed,
          cache_fence: dict.delete(observed.cache_fence, strand),
        ),
        strand,
        settled,
        at,
      )
    Ok(Some(_)), None -> observed
    Error(Nil), _ -> watch_cache_at(observed, strand, settled, at)
  }
}

// The output rate and generation clock are per-row readings in both legacy
// replay and live observations. Their common settlement does not touch the
// cumulative usage figure, whose owner depends on the delivery path.
fn settle_usage(
  model: Model,
  strand: String,
  settled: message.Usage,
  notice: String,
) -> Model {
  // The settlement's own output count over the time since the request went
  // out. A settlement whose clock never started (a refusal, an empty turn)
  // leaves the last rate standing. `generation_clock` starts the clock only
  // for the active strand's own row, so only that strand's settlement may
  // read it or clear it — a sub-agent's row arriving mid-generation must
  // not report its own output over the primary's window, and must not stop
  // the primary's clock out from under it.
  let #(output_rate_tps, generation_started_ms) = case
    strand == model.active_strand,
    model.peer,
    model.generation_started_ms
  {
    False, _, _ -> #(model.output_rate_tps, model.generation_started_ms)

    // The window is this client's own clock from the request going out to
    // the settlement, and a replay spends that window playing a file rather
    // than waiting on a provider. `output_rate_min_ms` already discards the
    // short ones, so a brief replay would report nothing anyway; a long one
    // would report how fast the replay ran. Declining outright is the same
    // rule that stops a replay echoing a prompt.
    True, Replaying, _ | True, Disconnected, _ -> #(model.output_rate_tps, None)

    True, Attached(..), Some(started) | True, Preview, Some(started) -> #(
      transcript_lines.output_rate(
        settled.output,
        model.monotonic_time_ms() - started,
      ),
      None,
    )
    True, Attached(..), None | True, Preview, None -> #(
      model.output_rate_tps,
      None,
    )
  }
  Model(..model, generation_started_ms:, output_rate_tps:, notice:)
}

// Folds one row into its strand's cache watch and raises any notice it
// reveals.
//
// The clock is the terminal's own, the same one the frame pacing and the
// throughput reading use, because the gap being measured is wall time the
// operator spent away and no server field reports it. A replay plays its
// file far faster than the session originally ran, so the gaps it would
// measure are not the gaps that happened; it observes nothing.
fn watch_cache(model: Model, strand: String, settled: message.Usage) -> Model {
  watch_cache_at(model, strand, settled, model.monotonic_time_ms())
}

fn watch_cache_at(
  model: Model,
  strand: String,
  settled: message.Usage,
  at: Int,
) -> Model {
  use <- bool.lazy_guard(when: replaying(model), return: fn() { model })

  let held = dict.get(model.cache_watch, strand) |> option.from_result
  let #(miss, watch) = cache_miss.observe(held, settled, at)
  let watched =
    Model(..model, cache_watch: case watch {
      None -> model.cache_watch
      Some(value) -> dict.insert(model.cache_watch, strand, value)
    })
  case miss {
    None -> watched
    Some(value) -> note_cache_miss(watched, strand, value)
  }
}

// A watch describes one provider's prefix. A model change cannot inherit its
// horizon or compare the new provider's first row with the old provider's
// last row. Clear only the affected strand, leaving its historical notices
// and other strands' watches in place.
fn forget_cache(model: Model, strand: String) -> Model {
  Model(
    ..model,
    cache_watch: dict.delete(model.cache_watch, strand),
    cache_fence: dict.insert(model.cache_fence, strand, None),
    cache_outlook: case strand == model.active_strand {
      True -> ""
      False -> model.cache_outlook
    },
  )
}

/// Records the strand's current model, forgetting the cache watch when the
/// model changed, since a cache written by one model does not serve another.
@internal
pub fn select_model(model: Model, name: String) -> Model {
  let model = case name == model.current_model {
    True -> model
    False -> forget_cache(model, model.active_strand)
  }
  Model(..model, current_model: name)
}

// A captured configuration can change on another terminal. Compare the
// effective model per strand instead of the whole configuration: changing a
// directory or another setting does not erase a valid cache observation. An
// initially live strand is fenced too, since its operation may have started
// under a model selected before this terminal attached.
fn cache_watches_for_cut(
  model: Model,
  view: snapshot_view.View,
) -> #(Dict(String, cache_miss.Watch), Dict(String, Option(String))) {
  case model.captured {
    Some(#(_, previous)) if previous.configurations != view.configurations -> {
      let watches =
        dict.filter(model.cache_watch, fn(strand, _) {
          configured_model(previous, strand) == configured_model(view, strand)
        })
      let fences =
        dict.fold(view.configurations, model.cache_fence, fn(fences, strand, _) {
          case
            dict.has_key(previous.configurations, strand)
            && configured_model(previous, strand)
            != configured_model(view, strand)
          {
            True -> dict.insert(fences, strand, None)
            False -> fences
          }
        })
      let fences =
        dict.fold(view.operations, fences, fn(fences, strand, _) {
          case dict.has_key(previous.configurations, strand) {
            True -> fences
            False -> dict.insert(fences, strand, None)
          }
        })
      #(watches, fences)
    }
    Some(_) -> #(model.cache_watch, model.cache_fence)
    None -> #(
      model.cache_watch,
      dict.fold(view.operations, model.cache_fence, fn(fences, strand, _) {
        dict.insert(fences, strand, None)
      }),
    )
  }
}

fn configured_model(
  view: snapshot_view.View,
  strand: String,
) -> Option(machine_strand.ModelIdentity) {
  view.configurations
  |> dict.get(strand)
  |> option.from_result
  |> option.map(fn(config) { config.configuration.model })
}

// A replay has no idle time of its own to report.
fn replaying(model: Model) -> Bool {
  case model.peer {
    Replaying -> True
    Attached(..) | Preview | Disconnected -> False
  }
}

// Files one cache-miss row against the strand's transcript.
//
// The row is anchored to the records the strand already holds rather than
// appended to the local notice block, so it stays under the turn it
// explains as later entries arrive. A new row changes the projection, so
// the record cache is dropped whether or not the strand is the visible one:
// switching to it later must find the row in place.
fn note_cache_miss(
  model: Model,
  strand: String,
  miss: cache_miss.CacheMiss,
) -> Model {
  // A strand holding no record has nowhere to put the row: a window that
  // retained nothing, or a strand whose history this connection never
  // fetched. A notice anchored to no entry would never be drawn, so it is
  // not raised at all.
  case newest_record(model, strand) {
    None -> model
    Some(after_entry) ->
      Model(
        ..model,
        cache_notices: list.append(model.cache_notices, [
          CacheNotice(strand:, after_entry:, text: cache_miss_row(miss)),
        ]),
        record_cache_valid: False,
      )
      |> tui_model.invalidate_transcript
      |> tui_model.invalidate_frame
  }
}

// The newest retained entry of one strand. Records are held newest first,
// so the head of the filtered list is the turn a row raised now follows.
fn newest_record(model: Model, strand: String) -> Option(ids.EntryId) {
  model.records
  |> list.find(fn(record) { record.strand == strand })
  |> result.map(fn(record) { record.entry.id })
  |> option.from_result
}

// The notice as the operator reads it.
//
// Token counts use the status line's own abbreviation so the two figures
// can be compared without unit arithmetic, and the money is omitted rather
// than shown as zero when the model is unpriced: a confident "$0.00" would
// claim the pause was free.
fn cache_miss_row(miss: cache_miss.CacheMiss) -> String {
  "Cache miss after "
  <> cache_miss.idle_label(miss.idle_ms)
  <> " idle: "
  <> transcript_lines.tokens(miss.tokens)
  <> " tokens re-billed"
  <> case miss.estimate {
    None -> ""
    Some(amount) -> " (~$" <> transcript_lines.money(amount) <> ")"
  }
}

fn add_usage(left: message.Usage, right: message.Usage) -> message.Usage {
  let message.UsageCost(
    input: left_cost_input,
    output: left_cost_output,
    cache_read: left_cost_cache_read,
    cache_write: left_cost_cache_write,
    total: left_cost_total,
  ) = left.cost
  let message.UsageCost(
    input: right_cost_input,
    output: right_cost_output,
    cache_read: right_cost_cache_read,
    cache_write: right_cost_cache_write,
    total: right_cost_total,
  ) = right.cost
  message.Usage(
    input: left.input + right.input,
    output: left.output + right.output,
    cache_read: left.cache_read + right.cache_read,
    cache_write: left.cache_write + right.cache_write,
    cache_write_1h: add_optional_int(left.cache_write_1h, right.cache_write_1h),
    reasoning: add_optional_int(left.reasoning, right.reasoning),
    total_tokens: left.total_tokens + right.total_tokens,
    cost: message.UsageCost(
      input: left_cost_input +. right_cost_input,
      output: left_cost_output +. right_cost_output,
      cache_read: left_cost_cache_read +. right_cost_cache_read,
      cache_write: left_cost_cache_write +. right_cost_cache_write,
      total: left_cost_total +. right_cost_total,
    ),
  )
}

fn add_optional_int(left: Option(Int), right: Option(Int)) -> Option(Int) {
  case left, right {
    None, None -> None
    Some(value), None | None, Some(value) -> Some(value)
    Some(left), Some(right) -> Some(left + right)
  }
}

/// Formats the server-reported session usage for the terminal footer.
/// The generation clock after an event that may start it: started now
/// if the event is the active strand's and no clock is running, otherwise
/// left as it was. Two events may start it — the `assistant` phase, and
/// the first fragment as a fallback — and whichever comes first wins.
fn generation_clock(model: Model, strand: String) -> Option(Int) {
  case model.generation_started_ms, strand == model.active_strand {
    None, True -> Some(model.monotonic_time_ms())
    started, _ -> started
  }
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
  case model.overlay {
    AgentInspector(inspector) if inspector.detail == agents.Messages ->
      Model(
        ..model,
        overlay: AgentInspector(select_inspector_message(
          inspector,
          model.agent_messages,
        )),
      )
    _ -> model
  }
}

/// The furthest the notes panel can scroll for the current selection.
@internal
pub fn note_max_scroll(model: Model) -> Int {
  let area = case model.overlay {
    AgentInspector(_) -> layout.message_detail_area(model)
    _ -> layout.note_detail_area(model)
  }
  render.prepared_notes(model, surfaces.notes_target(model), area)
  |> note_panel.max_scroll(model.note_selected)
}

/// Owner context is read from the same exact escalation revision. A newer
/// metadata cut cannot silently rename the request whose grants are displayed.
@internal
pub fn captured_approval_panel(model: Model, review: approval.Review) {
  let context = {
    use captured <- result.try(option.to_result(model.captured, Nil))
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
  case model.channel {
    None -> Model(..model, pending_submission: None)
    Some(channel) -> {
      let #(channel, updates) = session_channel.cancel_unsent(channel, reason)
      list.fold(
        updates,
        Model(..model, channel: Some(channel)),
        apply_channel_update,
      )
    }
  }
}

/// History shares the existing correlated read lane. A busy lane leaves one
/// demand pending without blocking input, spawning a worker, or opening a socket.
@internal
pub fn service_history(model: Model) -> Model {
  case history_view.range(model.scrollback), model.channel {
    Some(#(after, before)), Some(channel) -> {
      case session_channel.history(channel, after, before) {
        Error(_) -> model
        Ok(channel) ->
          Model(
            ..model,
            channel: Some(channel),
            scrollback: history_view.sent(model.scrollback, before),
          )
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
  case model.captured {
    None -> model
    Some(#(cut, view)) -> {
      let history =
        history_view.accept(model.scrollback, window, before, after, view)
      let model = apply_cut(Model(..model, scrollback: history), cut, view)
      Model(..model, render_revision: model.render_revision + 1)
    }
  }
}

/// The local submitting marker closes the interval between writing a prompt
/// frame and receiving its first operation transition. Websocket ordering then
/// lets an immediate Escape place abort after prompt on the same connection,
/// even though the server's live phase has not reached the view yet.
@internal
pub fn send_prompt_to(model: Model, strand: String, text: String) -> Model {
  let sent =
    Model(
      ..expect_own_turn(model, HeldPrompt(text)),
      submitting: Some(strand),
      notice: "prompt sent to " <> strand,
    )
  case model.peer {
    Attached(..) ->
      outbound.send_frame(sent, protocol.prompt(model.next_id, strand, text))

    // The server echoed this turn back as an entry, and the recording has
    // it. Drawing a local copy here would show the operator's line twice.
    Replaying -> sent
    Disconnected -> tui_model.append_error(model, "no conversation is attached")
    Preview ->
      Model(
        ..model,
        transcript: list.append(model.transcript, [
          Line(User, composer.transcript_text(text, model.details_expanded)),
          Line(Assistant, "Design-preview echo received."),
        ]),
        record_cache_valid: False,
        notice: "prompt accepted",
      )
      |> tui_model.invalidate_transcript
  }
}

/// Records one submission this terminal made to a running active strand, so
/// that the entry it eventually produces is accounted for.
///
/// For a `HeldPrompt` the record is also what the operator sees. A prompt
/// submitted to a running strand does not become an entry until the daemon
/// drains it, which is a whole turn away. Without a local copy the operator's
/// line simply vanishes for as long as the run lasts, and the natural reading
/// is that the keystroke was lost — which is what sent people looking for the
/// bug this answers. The echo is drawn under the live tail and retired by the
/// entry it stands for.
///
/// `Preview` draws its own echo and `Disconnected` sent nothing, so neither
/// records anything here. An idle strand does not either: nothing is held, its
/// entry is already on its way back, and two copies would be worse than a slow
/// one.
/// An attached submission waits in `awaiting_outcome` for the daemon's answer,
/// because a refusal is a real outcome here and the echo has to go back with
/// it. A replay has no daemon to answer, so its submission joins the list at
/// once and the recording's own entry retires it.
@internal
pub fn expect_own_turn(model: Model, submission: Submission) -> Model {
  case model.peer, tui_model.active_strand_live(model) {
    Attached(..), True ->
      Model(..model, awaiting_outcome: Some(submission))
      |> tui_model.invalidate_transcript
    Replaying, True ->
      Model(..model, queued: in_commit_order(model.queued, submission))
      |> tui_model.invalidate_transcript
    Attached(..), False | Replaying, False | Preview, _ | Disconnected, _ ->
      model
  }
}

// The daemon took the submission: it will commit an entry, so the submission
// joins the list that waits for one.
fn settle_own_turn(model: Model) -> Model {
  case model.awaiting_outcome {
    Some(submission) ->
      Model(
        ..model,
        queued: in_commit_order(model.queued, submission),
        awaiting_outcome: None,
      )
    None -> model
  }
}

// Forgets the submissions an abort cancelled, keeping the ones it does not
// reach.
//
// The invariant this restores is the queue's: every submission in the list is
// owed an entry. An abort breaks that for interjections alone, because the
// steer and follow-up items still queued on the run are discarded with the
// run instead of being committed. Left in place they would absorb the entries
// the held prompts produce, and each prompt's echo would outlive the line it
// stood for.
fn abandon_interjections(model: Model) -> Model {
  let held =
    list.filter(model.queued, fn(submission) {
      case submission {
        Interjection -> False
        HeldPrompt(..) -> True
      }
    })

  // A submission still awaiting its outcome was sent to the same run, so an
  // interjection there is cancelled on the same grounds. A prompt keeps
  // waiting for the reply that is still coming for it.
  let awaiting = case model.awaiting_outcome {
    Some(Interjection) -> None
    Some(HeldPrompt(..)) | None -> model.awaiting_outcome
  }

  Model(..model, queued: held, awaiting_outcome: awaiting)
  |> tui_model.invalidate_transcript
}

// Places one submission where the daemon will commit it.
//
// Submission order is not commit order, which is the trap here. An
// interjection joins the run that is already open and commits during it,
// while every held prompt waits for that run to settle — so a steer typed
// after a prompt was queued still commits first. Keeping the list in commit
// order is what lets `drained_echoes` stay a drop of the head, and it is the
// list's whole invariant: interjections first, in the order they were made,
// then the held prompts in the order the daemon drains them.
fn in_commit_order(
  queued: List(Submission),
  submission: Submission,
) -> List(Submission) {
  case submission {
    HeldPrompt(..) -> list.append(queued, [submission])
    Interjection -> {
      let #(interjections, held) =
        list.split_while(queued, fn(earlier) {
          case earlier {
            Interjection -> True
            HeldPrompt(..) -> False
          }
        })
      list.flatten([interjections, [submission], held])
    }
  }
}

// Retires the oldest outstanding submission when a user turn commits on the
// strand it was made on.
//
// `in_commit_order` holds the list in the order the daemon commits these, so
// the head is what the entry belongs to, and an interjection at the head
// absorbs the entry without touching the echo behind it — which is the whole
// reason steers and follow-ups are recorded here at all. Matching on the text
// instead would have to reproduce the server's authorship prefix and its
// block layout, and would still pick the wrong entry for two identical
// prompts.
//
// A second operator's prompt or steer on the same strand still retires the
// head early. That costs a queued marker one turn of visibility, and the
// entry it stood for still arrives in its place.
fn drained_echoes(
  queued: List(Submission),
  record: protocol.EntryRecord,
) -> List(Submission) {
  let protocol.EntryRecord(entry: value, ..) = record
  case value {
    entry.MessageEntry(message: message.UserMessage(..), ..) ->
      list.drop(queued, 1)
    entry.MessageEntry(..)
    | entry.CompactionEntry(..)
    | entry.BranchSummaryEntry(..)
    | entry.CustomEntry(..) -> queued
  }
}

fn settle_interrupt(model: Model, strand: String, phase: String) -> Model {
  case phase == "done", model.interrupt {
    True, Some(Interrupt(strand: target, pending:, ..)) ->
      case target == strand, pending {
        True, Some(text) ->
          send_prompt_to(Model(..model, interrupt: None), target, text)
        True, None ->
          Model(..model, interrupt: None, notice: target <> ": interrupted")
        False, _ -> model
      }
    _, _ -> model
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
    Attached(..) | Disconnected -> Disconnected
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
    case owner.0 == session && tui_model.is_known_strand(strands, owner.1) {
      True -> saved
      False ->
        StrandWorkspace(
          ..saved,
          scrollback: history_view.empty(),
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
    history_view.empty(),
    None,
    0,
    [],
    0,
    1,
  )
}

/// Save before changing identity; both empty drafts and submission mode belong
/// to the destination, so a first visit starts with a fresh editor.
@internal
pub fn select_workspace(
  model: Model,
  session: String,
  strand: String,
) -> Model {
  use <- bool.guard(
    model.session == session && model.active_strand == strand,
    model,
  )

  // Session observations belong to the attachment that read them. Reusing
  // the common strand name "main" cannot transfer advice or a goal.
  let model = case model.session == session {
    True -> model
    False ->
      Model(
        ..model,
        nudges: None,
        nudges_refresh: worktree_view.Settled,
        nudges_awaiting: None,
        nudges_request: None,
        goal: None,
        goal_refresh: worktree_view.Settled,
        goal_awaiting: None,
        goal_request: None,
        goal_report: HoldGoalReport,
        overlay: case model.overlay {
          GoalInspector(_) -> NoOverlay
          other -> other
        },
      )
  }

  // Before the first attachment there is no previous session to park in.
  // Bind that unassigned editor to the explicitly chosen session once;
  // later switches keep their existing session identities and own drafts.
  let draft_session = case model.session {
    "" -> session
    previous -> previous
  }
  let parked =
    dict.insert(
      model.strand_workspaces,
      #(draft_session, model.active_strand),
      StrandWorkspace(
        model.input,
        model.attachments,
        model.history,
        model.history_index,
        model.history_draft,
        model.submission_mode,
        model.scrollback,
        model.reading_lines,
        model.scroll_offset,
        model.rendered_anchors,
        model.rendered_row_count - list.length(model.rendered_anchors),
        layout.transcript_viewport_height(model),
      ),
    )
  let saved = dict.get(parked, #(session, strand)) |> option.from_result
  let restored = option.unwrap(saved, empty_workspace())
  Model(
    ..model,
    strand_workspaces: dict.delete(parked, #(session, strand)),
    agent_rows: case model.session == session {
      True -> model.agent_rows
      False -> []
    },
    strip: case model.session == session {
      True -> model.strip
      False -> agent_strip.new()
    },
    agent_messages: case model.session == session {
      True -> model.agent_messages
      False -> []
    },
    advisor_history: case model.session == session {
      True -> model.advisor_history
      False -> advisor_history.Board(items: [], unloaded: None)
    },
    todo_boards: case model.session == session {
      True -> model.todo_boards
      False -> dict.new()
    },
    todo_seed: case model.session == session {
      True -> model.todo_seed
      False -> None
    },
    todo_asked: case model.session == session {
      True -> model.todo_asked
      False -> set.new()
    },
    reviewer_rows: case model.session == session {
      True -> model.reviewer_rows
      False -> []
    },
    restored_workspace: saved,
    input: restored.input,
    attachments: restored.attachments,
    history: restored.history,
    history_index: restored.history_index,
    history_draft: restored.history_draft,
    command_selected: 0,
    submission_mode: restored.submission_mode,
    scrollback: history_view.cancel(restored.scrollback),
    reading_lines: restored.reading_lines,
    scroll_offset: restored.offset,
  )
}

/// Cuts and width transitions request at most one pending refresh. No timer or
/// background Git loop is needed when the workspace and conversation are idle.
@internal
pub fn request_visible_worktree(model: Model) -> Model {
  case model.peer, layout.diff_shown(model) {
    Attached(_), True -> refresh_worktree(model)
    Attached(_), False | Preview, _ | Replaying, _ | Disconnected, _ -> model
  }
}

/// Asks for a fresh worktree diff when a live conversation is attached.
@internal
pub fn refresh_worktree(model: Model) -> Model {
  case model.peer, model.channel {
    Attached(_), Some(_) ->
      surfaces.service_worktree_read(
        Model(
          ..model,
          worktree: worktree_view.request(
            model.worktree,
            tui_model.queue_owner(model),
          ),
        ),
      )
    _, _ ->
      Model(
        ..model,
        worktree: worktree_view.new(),
        notice: "Captured edits · live worktree observation unavailable",
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
    tui_model.queue_owner(Model(..model, captured: Some(#(cut, view))))
  let previous = case model.completion_owner == owner {
    True -> model.completion
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
    completion:,
    completion_owner: owner,
    worktree: case model.worktree.owner == owner {
      True -> model.worktree
      False -> worktree_view.new()
    },
    jobs: case model.completion_owner == owner {
      True -> model.jobs
      False -> None
    },
    jobs_awaiting: case model.completion_owner == owner {
      True -> model.jobs_awaiting
      False -> None
    },
    jobs_refresh: case changed {
      True -> worktree_view.Requested
      False -> model.jobs_refresh
    },
  )
}

fn retain_queue_selection(
  model: Model,
  view: snapshot_view.View,
  active: String,
) -> Model {
  let old =
    layout.queue_rows(model)
    |> list.drop(model.queue_editor.selected)
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
            model.queue_editor.preview_scroll,
            queue_panel.max_scroll(
              rows,
              selected,
              layout.queue_preview_area_for(
                Model(
                  ..model,
                  queue_editor: queue_editor.State(
                    ..model.queue_editor,
                    selected:,
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
    queue_editor: queue_editor.State(
      ..model.queue_editor,
      selected:,
      preview_scroll:,
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
      context: context_view.refused(model.context, request_id, code, message),
    )
    |> tui_model.invalidate_frame
  })

  // Every goal command is refused worded and nowhere else: an older daemon
  // refuses all five, and an operator watching a panel fail to appear has
  // no way to tell that from a session with no goal.
  use <- bool.lazy_guard(string.starts_with(command, "goal_"), fn() {
    surfaces.refuse_goal(model, command, request_id, code, message)
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
      case model.queue_editor.request_id == Some(request_id) {
        True ->
          Model(
            ..model,
            queue_editor: queue_editor.refused(model.queue_editor, reason),
          )
        False -> model
      }
    "live_jobs" ->
      case model.jobs_request == Some(request_id) {
        True ->
          Model(
            ..model,
            jobs_request: None,
            jobs_awaiting: None,
            jobs_notice: "Live jobs unavailable: " <> reason,
          )
        False -> model
      }

    // A refused observation draws nothing. The panel is unobtrusive context
    // beside the composer, and an error line there would cost a row of the
    // conversation to report a read the operator never asked for; an older
    // daemon that does not know the command refuses every one of them.
    "advisor_pending" ->
      case model.nudges_request == Some(request_id) {
        True ->
          Model(
            ..model,
            nudges: None,
            nudges_request: None,
            nudges_awaiting: None,
          )
        False -> model
      }
    "worktree_diff" ->
      Model(
        ..model,
        worktree: worktree_view.receive(
          model.worktree,
          tui_model.queue_owner(model),
          worktree_view.Failed(request_id, reason),
        ),
      )
    _ -> model
  }
  apply_event(updated, protocol.ServerError(code, message))
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
      let #(strip, repaint) =
        agent_strip.tick(model.strip, model.monotonic_time_ms())
      case repaint {
        agent_strip.Changed ->
          tui_model.invalidate_frame(Model(..model, strip:))
        agent_strip.Unchanged -> Model(..model, strip:)
      }
    }
  }
}
