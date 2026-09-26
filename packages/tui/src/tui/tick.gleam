//// The periodic tick: drain every inbox, service pending reads, and decide
//// when to paint.
////
//// `update_tick` drains the replay, the attachment candidate, daemon
//// control, the session switch, reconnection and a bounded batch of
//// socket traffic, and then hands the drained model to `settle_tick`,
//// which services the side-surface reads and advances the session
//// channel's timers. `settle_tick` takes the drained model as a parameter
//// on purpose: see the comment above it. The frame cache and the viewport
//// pacing that decide whether a tick repaints live here as well, as does
//// the Herdr pane reporter.

import etui/geometry
import gleam/bool
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import host/bootstrap as host_bootstrap
import tui/attachment
import tui/attempt_replay
import tui/cache_miss
import tui/effect
import tui/herdr
import tui/history_view
import tui/inbound
import tui/interaction
import tui/layout
import tui/model.{
  type Model, ControlEvent, FrameCache, Model, ReconnectAttempting,
  ReconnectIdle, ReconnectSpent, Replaying,
} as tui_model
import tui/pacing
import tui/render
import tui/session_channel
import tui/session_control.{ReconnectEvent}
import tui/sessions
import tui/surfaces

fn drain_reconnect(model: Model) -> Model {
  case model.reconnect {
    ReconnectIdle | ReconnectSpent -> model
    ReconnectAttempting(replies:, ..) ->
      case process.receive(replies, 0) {
        Error(Nil) -> model
        Ok(reply) ->
          session_control.accept_reconnect_event(
            model,
            ReconnectEvent(replies, reply),
          )
      }
  }
}

fn drain_control(model: Model) -> Model {
  case model.control_request {
    None -> model
    Some(run) ->
      case process.receive(run.replies, 0) {
        Error(Nil) -> model
        Ok(reply) ->
          session_control.accept_control_event(
            model,
            ControlEvent(run.replies, reply),
          )
      }
  }
}

/// Starts the Herdr pane reporter when the launch environment carries a
/// pane. Started here rather than in `main` so the launchers that are not
/// terminal applications — `ext`, `replay`, `sessions` — never grow a
/// process, and so the model the loop runs is the only one that owns it.
/// A refused start is silent by design: the reporter is a convenience for
/// the pane around the terminal, and the session must never learn it
/// exists by failing.
///
/// The sequence seed is the wall clock rather than the presentation clock,
/// which every other timing in the loop uses. Herdr's `seq` is an unsigned
/// integer, and the BEAM monotonic clock is an arbitrary-offset counter that
/// is negative on this platform, so a monotonic seed would make the daemon
/// reject every report. Seeding from the wall clock also puts a reporter
/// restarted in the same pane above the last sequence Herdr saw.
@internal
pub fn start_herdr_reporter(model: Model) -> Model {
  case herdr.configure(host_bootstrap.system_time_ms()) {
    None -> model
    Some(config) ->
      case herdr.start(config) {
        Ok(reporter) -> Model(..model, herdr_reporter: Some(reporter))
        Error(_) -> model
      }
  }
}

/// Queues a report of the pane state to Herdr when — and only when — it
/// changed. The runtime sends it after the step; `herdr_published` records
/// the decision here, so the next step compares against what was queued.
///
/// Nothing is published before a session is attached. The terminal reaches
/// this function at the session picker, where `model.session` is still
/// empty, and a report carrying an empty `agent_session_id` names no
/// session for `herdr session` to resume.
///
/// The report derives from the same fields the frame does, so the pane
/// cannot tell the operator something the screen disagrees with. A session
/// switch is reported even at an unchanged state, because the session id is
/// what resume keys on, and the switch re-announces: the announcement
/// follows the session identity, so it is sent when that identity first
/// becomes known and again every time it moves. Publishing on every event
/// is deliberately cheap: the comparison is two fields and the send is one
/// message to a local process.
@internal
pub fn publish_herdr(model: Model) -> Model {
  case model.herdr_reporter, model.session {
    None, _ -> model
    Some(_), "" -> model
    Some(reporter), session -> {
      let next =
        herdr.Publication(
          state: herdr.state_for(model.strands, model.approvals),
          session:,
        )
      case herdr.changed(model.herdr_published, next) {
        False -> model
        True -> {
          // The announcement is queued ahead of the report, so Herdr knows
          // which session a state belongs to before it hears the state.
          let model = case herdr.announces(model.herdr_published, next) {
            True ->
              tui_model.emit(model, effect.AnnounceHerdr(reporter, session))
            False -> model
          }
          Model(..model, herdr_published: Some(next))
          |> tui_model.emit(effect.ReportHerdr(
            reporter,
            next.state,
            next.session,
            "",
          ))
        }
      }
    }
  }
}

/// A terminal tick is the only idle-time event. Visible socket traffic marks
/// activity while it is drained; otherwise the accumulated quiet time advances
/// by the timeout that led to this tick. A live operation animates at this
/// cadence but does not by itself force the fast polling regime forever.
@internal
pub fn update_tick(model: Model) -> Model {
  let animated =
    inbound.tick_strip(advance_activity_indicator(drain_replay(model)))
  let switched = drain_candidate(drain_control(drain_session_switch(animated)))
  let switched = drain_reconnect(switched)
  let switched = session_control.drain_activity(switched)
  let drained = inbound.drain_connection(switched, 64)
  settle_tick(model, drained)
}

// Keep the read-service chain on a parameter, as `settle_update` does for
// event dispatch. Otherwise each inlining attempt revisits the entire drain
// expression; adding another service can double compilation time. The
// services now live in `tui/surfaces` and `tui/inbound`, and a cross-module
// call is never inlined, but the drains in `update_tick` and
// `advance_cache_outlook` are still local calls, so the parameter boundary
// is what keeps a new local step from revisiting the drain expression.
// Preserve the original model for the quiet-time comparison after all
// reads settle.
fn settle_tick(model: Model, drained: Model) -> Model {
  let drained =
    drained
    |> surfaces.service_queue_read
    |> surfaces.service_worktree_read
    |> surfaces.service_notes_read
    |> surfaces.service_todo_seed
    |> surfaces.service_jobs_read
    |> surfaces.service_context_read
    |> surfaces.service_advisor_nudges_read
    |> surfaces.service_goal_read
    |> session_control.service_activity
    |> inbound.tick_channel
    |> advance_cache_outlook
  let quiet_for_ms =
    pacing.next_quiet_for(
      model.quiet_for_ms,
      terminal_poll_timeout(model),
      drained.activity_revision != model.activity_revision,
    )
  Model(..drained, quiet_for_ms:)
}

fn drain_replay(model: Model) -> Model {
  case model.peer, process.receive(model.replay_inbox, 0) {
    Replaying, Ok(event) ->
      case attempt_replay.apply(model.replay_state, event) {
        Error(reason) ->
          tui_model.append_error(
            Model(..model, replay_error: Some(reason), quit: True),
            reason,
          )
        Ok(#(state, changes)) ->
          list.fold(
            changes,
            Model(..model, replay_state: state),
            apply_replay_change,
          )
      }
    _, _ -> model
  }
}

fn apply_replay_change(model: Model, change: attempt_replay.Change) -> Model {
  case change {
    attempt_replay.RequestedHistory(before) ->
      Model(
        ..model,
        scrollback: history_view.sent(
          history_view.freeze(model.scrollback),
          before,
        ),
      )
    attempt_replay.Rejected(reason) ->
      tui_model.append_error(model, "open session: " <> reason)
    attempt_replay.Adopt(cut, view) -> {
      let model =
        inbound.select_workspace(
          model,
          cut.attachment.expected.session,
          case model.session == cut.attachment.expected.session {
            True -> model.active_strand
            False -> "main"
          },
        )
      Model(
        ..model,
        session: cut.attachment.expected.session,
        captured: None,
        scrollback: case model.session == cut.attachment.expected.session {
          True -> history_view.cancel(model.scrollback)
          False -> model.scrollback
        },
        note_board: None,
        note_selected: None,
        notes_requested: None,
        approvals: [],
        prompted_approvals: [],
        inspecting_approval: None,
        records: [],
        streams: [],
        tool_tails: [],
        models: [],
        skills: [],
        current_model: "loading…",
        active_strand: case model.session == cut.attachment.expected.session {
          True -> model.active_strand
          False -> "main"
        },
        scroll_offset: case model.session == cut.attachment.expected.session {
          True -> model.scroll_offset
          False -> 0
        },
        record_cache_valid: False,
        submitting: None,
        interrupt: None,
      )
      |> inbound.apply_cut(cut, view)
      // Every update, cuts included, goes through the live reducer. A cut used
      // to be special-cased into `apply_cut`, which always invalidates the
      // transcript and restarts the activity indicator; `reconcile_cut`'s
      // equal-cut fast path is what the live client does instead, and a replay
      // that rendered frames the live client did not is not a replay. The
      // outbound half of that path is made inert by `request_decisions`, which
      // sends nothing while the peer is `Replaying`.
    }
    attempt_replay.Update(update) -> inbound.apply_channel_update(model, update)
  }
}

// The tick is the one place the elapsed count moves, so it and the glyph
// advance together and rendering stays a pure function of the model. The
// time is the event's stamp. Going idle clears the start, so the next
// activity starts from zero rather than from wherever the last one stopped.
fn advance_activity_indicator(model: Model) -> Model {
  case tui_model.active_strand_live(model) {
    False -> Model(..model, activity_started_ms: None, activity_elapsed_s: 0)
    True -> {
      let now = model.stamp.now_ms
      let started = option.unwrap(model.activity_started_ms, now)
      let activity_elapsed_s = { now - started } / 1000
      let activity_frame = model.activity_frame + 1
      let advanced =
        Model(
          ..model,
          activity_frame:,
          activity_started_ms: Some(started),
          activity_elapsed_s:,
        )
      case
        layout.activity_glyph(model.activity_frame)
        == layout.activity_glyph(activity_frame)
        && activity_elapsed_s == model.activity_elapsed_s
      {
        True -> advanced
        False -> tui_model.invalidate_frame(advanced)
      }
    }
  }
}

// The tick is also where the cache outlook is recomputed from the stamp,
// for the same reason the elapsed count lives here: rendering stays a pure
// function of the model, and the label repaints only when the reading
// actually moved.
//
// The reading is suppressed while the active strand is running. A request
// in flight re-writes the prefix whatever the label says, so a countdown
// shown mid-generation would name an expiry the request in progress is
// about to reset — and the miss row, not the label, is the thing that
// reports what the pause before the request cost.
fn advance_cache_outlook(model: Model) -> Model {
  let label = case tui_model.active_strand_live(model) {
    False ->
      model.cache_watch
      |> dict.get(model.active_strand)
      |> option.from_result
      |> cache_miss.outlook(model.stamp.now_ms)
      |> option.map(cache_miss.outlook_label)
      |> option.unwrap("")
    True -> ""
  }
  case label == model.cache_outlook {
    True -> model
    False -> tui_model.invalidate_frame(Model(..model, cache_outlook: label))
  }
}

/// Rendering is pure, so caching the completed frame inside the next immutable
/// model gives etui the exact same Buffer term on unchanged iterations. The
/// cache key stays scalar and screen-local; no complete Model comparison sits
/// on the idle path.
///
/// The cache is also where a burst is paced. Etui applies up to sixty-four
/// queued events before drawing, but each event still calls this update path and
/// a longer burst can span batches. A stale cache inside the pacing interval is
/// left in place and recorded as debt; the next tick, which cannot arrive before
/// the queue has drained, renders the final state once.
@internal
pub fn refresh_frame_cache(
  model: Model,
  boundary: pacing.FrameBoundary,
) -> Model {
  let screen = geometry.rect_new(0, 0, model.width, model.height)
  let freshness = case viewport_pacing(model) {
    // Rows the model holds but the viewport has not shown make the painted
    // frame stale by definition, whatever the revision says. Without this
    // the walk would stop after one step: revealing a row changes the frame
    // without changing any of the inputs the revision counts.
    pacing.ViewportCatchingUp -> pacing.FrameStale
    pacing.ViewportSettled ->
      case model.frame_cache {
        Some(FrameCache(screen: cached_screen, revision:, ..))
          if cached_screen == screen && revision == model.frame_revision
        -> pacing.FrameCurrent
        None | Some(_) -> pacing.FrameStale
      }
  }

  // The event's stamp is compared only against earlier stamps of the same
  // monotonic clock, so a wall-clock step cannot stretch or collapse the
  // interval.
  let now = model.stamp.now_ms
  case pacing.frame_decision(boundary, freshness, now - model.last_frame_ms) {
    pacing.KeepCachedFrame -> model
    pacing.DeferFrame -> Model(..model, frame_debt: pacing.FrameDeferred)
    pacing.RenderFrame -> {
      // The step is taken before the frame is built, so the frame that is
      // cached and the position it was built from are the same moment.
      let paced = advance_viewport(model)
      Model(
        ..paced,
        frame_debt: pacing.FrameSettled,
        last_frame_ms: now,
        frame_cache: Some(FrameCache(
          screen:,
          revision: paced.frame_revision,
          rendered: render.render_frame(paced, screen),
          selection_gutters: interaction.selection_gutters_on_display(paced),
        )),
      )
    }
  }
}

// The snap bound is the viewport rather than a constant: what makes a jump
// worth smoothing is that the reader can still see where the text came
// from, and a growth taller than the screen leaves nothing of it.
fn pace_policy(model: Model) -> pacing.PacePolicy {
  pacing.policy(snap_above: layout.transcript_viewport_height(model))
}

/// Reports whether the viewport still has rows to reveal.
///
/// A full-width changes view is the one surface painted without the paced
/// offset, so rows held back behind it are not on their way to any screen
/// and the frame they would make stale shows none of them. Answering
/// settled there keeps the loop off a sixteen millisecond repaint of a
/// frame the walk cannot change. Help and notes are not exempt: both are
/// painted through the same offset as the transcript, so a backlog under
/// them is a position the reader is actually being shown.
///
/// ## Examples
///
/// ```gleam
/// assert tui.viewport_pacing(model) == tui.ViewportSettled
/// ```
@internal
pub fn viewport_pacing(model: Model) -> pacing.ViewportPacing {
  use <- bool.guard(layout.main_shows_diff(model), pacing.ViewportSettled)
  pacing.viewport_pacing(backlog: tui_model.viewport_backlog(model))
}

// One step of the walk, taken as the frame it belongs to is rendered. Tying
// it to the render rather than to the tick is what bounds the shift between
// two consecutive frames: a tick that renders nothing reveals nothing.
//
// An idle strand holds no rows back at all. The walk exists to smooth output
// that is still arriving, and a viewport lagging a source that has stopped
// producing shows the reader stale text for no gain. It is also why a
// replayed or scripted run settles on the complete frame rather than on
// however far a fixed number of ticks happened to walk.
fn advance_viewport(model: Model) -> Model {
  case tui_model.active_strand_live(model) {
    False -> Model(..model, revealed_rows: model.rendered_row_count)
    True ->
      Model(
        ..model,
        revealed_rows: pacing.pace(
          model.revealed_rows,
          model.rendered_row_count,
          pace_policy(model),
        ),
      )
  }
}

/// The wait this model would ask a terminal for before its next poll.
///
/// ## Examples
///
/// ```gleam
/// assert tui.terminal_poll_timeout(model) == 40
/// ```
@internal
pub fn terminal_poll_timeout(model: Model) -> Int {
  let ordinary = pacing.paced_poll_timeout(model.frame_debt, model.quiet_for_ms)

  // A loading session candidate is read from disk rather than from the
  // socket, so its short wait survives a backlog: nothing it drains can
  // lengthen the walk.
  let ordinary = case attachment.busy(model.candidate) {
    True -> int.min(ordinary, 8)
    False -> ordinary
  }
  case viewport_pacing(model) {
    // A backlog is work the loop owes the screen with nothing left to wake
    // it: the deltas that produced those rows are already drained. One row
    // is revealed per rendered frame, so the wait between wakes is the
    // interval between rows, and the shorter in-flight wait is deliberately
    // not taken — draining the socket sooner would only lengthen a backlog
    // the viewport has yet to show.
    pacing.ViewportCatchingUp -> int.min(ordinary, pacing.frame_interval_ms)
    pacing.ViewportSettled ->
      case model.channel {
        Some(channel) ->
          case session_channel.in_flight(channel) {
            True -> int.min(ordinary, 8)
            False -> int.min(ordinary, 250)
          }
        None -> ordinary
      }
  }
}

fn drain_candidate(model: Model) -> Model {
  interaction.advance_candidate(model, attachment.poll(model.candidate))
}

fn drain_session_switch(model: Model) -> Model {
  case sessions.receive(model.session_switch) {
    Error(Nil) -> model
    Ok(message) -> inbound.handle_session_switch_message(model, message)
  }
}
