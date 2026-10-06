//// The periodic tick: drain every inbox, service pending reads, and decide
//// when to paint.
////
//// `update_tick` drains the replay, the attachment candidate, daemon
//// control, reconnection, the activity poll, a session creation's
//// configuration and a bounded batch of socket traffic, and then hands the
//// drained model to `settle_tick`, which services the side-surface reads
//// and advances the session channel's timers. Every drain takes from what
//// the runtime received before the step rather than from a mailbox.
//// `settle_tick` takes the drained model as a parameter on purpose: see
//// the comment above it. The frame cache
//// and the viewport pacing that decide whether a tick repaints live here
//// as well, as does the Herdr pane reporter.

import etui/geometry
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import host/bootstrap as host_bootstrap
import session_view/attempt_replay
import session_view/cache_miss
import session_view/cache_watch
import session_view/lane_fold
import session_view/model as session_model
import session_view/session_channel
import session_view/shared_set
import session_view/step as session_step
import session_view/surfaces
import tui/attachment
import tui/buffered
import tui/effect
import tui/herdr
import tui/image_drain
import tui/inbound
import tui/interaction
import tui/job_runner
import tui/layout
import tui/model.{type Model, Caches, FrameCache, Model, View} as tui_model
import tui/pacing
import tui/render
import tui/session_control
import tui/view_set

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
        Ok(reporter) ->
          Model(
            ..model,
            view: view_set.herdr_reporter(model.view, Some(reporter)),
          )
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
/// session at all, so there is nothing to report and no resume command
/// to attach.
///
/// The report derives from the same fields the frame does, so the pane
/// cannot tell the operator something the screen disagrees with. A session
/// switch is reported even at an unchanged state, because the resume
/// command names the session the pane must reopen, and the switch
/// re-announces: the announcement follows the session identity, so it is
/// sent when that identity first becomes known and again every time it
/// moves. A blocked report names the pending approval in its message,
/// the field Herdr shows beside a pane that is waiting on the operator.
/// Publishing on every event is deliberately cheap: the comparison is
/// three fields and the send is one effect queued to a local process.
@internal
pub fn publish_herdr(model: Model) -> Model {
  // A quitting step publishes nothing. The quit path has already queued
  // the release at the point this runs, and a report emitted after it in
  // the same outbox would re-mark a pane the release just cleared: the
  // state settles on the drained connection of the very step that quits,
  // so a transition observed alongside the Ctrl-C would otherwise land on
  // Herdr after the goodbye.
  case model.shared.quit, model.view.herdr_reporter, model.shared.session {
    True, _, _ -> model
    False, None, _ -> model
    False, Some(_), "" -> model
    False, Some(reporter), session -> {
      let next =
        herdr.Publication(
          state: herdr.state_for(model.shared.strands, model.shared.approvals),
          session:,
          message: herdr.message_for(model.shared.approvals),
        )
      case herdr.changed(model.view.herdr_published, next) {
        False -> model
        True -> {
          // The announcement is queued ahead of the report, so Herdr knows
          // which session a state belongs to before it hears the state.
          let model = case herdr.announces(model.view.herdr_published, next) {
            True ->
              tui_model.emit(model, effect.AnnounceHerdr(reporter, session))
            False -> model
          }
          Model(..model, view: View(..model.view, herdr_published: Some(next)))
          |> tui_model.emit(effect.ReportHerdr(
            reporter,
            next.state,
            next.session,
            next.message,
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
  let switched = drain_candidate(session_control.drain_control(animated))
  let switched = session_control.drain_reconnect(switched)
  let switched = session_control.drain_activity(switched)
  let switched = session_control.drain_configuration(switched)
  let switched = image_drain.drain(switched)
  let drained = inbound.drain_connection(switched, tui_model.connection_batch)
  settle_tick(model, drained)
}

// Keep the read-service chain on a parameter, as `settle_update` does for
// event dispatch. Otherwise each inlining attempt revisits the entire drain
// expression; adding another service can double compilation time. The
// services now live in `session_view/surfaces` and `tui/inbound`, and a cross-module
// call is never inlined, but the drains in `update_tick` and
// `advance_cache_outlook` are still local calls, so the parameter boundary
// is what keeps a new local step from revisiting the drain expression.
// Preserve the original model for the quiet-time comparison after all
// reads settle.
//
// The first eight reads (`session_step.service_reads`) take the shared
// record alone and read nothing of the terminal, so they run as one chain
// over `Shared` and are held once, before
// the terminal's activity poll. One hold moves their effects into the outbox
// in the order the chain decided them and applies their editor notices after
// the last, and since none of the eight reads what a notice changes, the
// model is the same as if each had been held on its own.
fn settle_tick(model: Model, drained: Model) -> Model {
  let drained =
    drained
    |> tui_model.run_shared(session_step.service_reads)
    |> session_control.service_activity
    |> tui_model.run_shared(surfaces.service_block_summaries)
    |> inbound.tick_channel
    |> advance_cache_outlook
  let quiet_for_ms =
    pacing.next_quiet_for(
      model.view.quiet_for_ms,
      terminal_poll_timeout(model),
      drained.shared.activity_revision != model.shared.activity_revision,
    )
  Model(
    shared: shared_set.connection_backlog(
      drained.shared,
      adopted_backlog(model, drained),
    ),
    view: View(..drained.view, quiet_for_ms:),
  )
}

/// What a tick leaves `Model.connection_backlog` as, given the model before
/// and after it.
///
/// An adoption in the tick installed the candidate's inbox. A candidate
/// stops reading its frames at its capture, so frames its socket filed
/// after that are still in the mailbox, and their wakes were spent on ticks
/// that could not read them; one more batch is owed at once. Without an
/// adoption the drain's own answer stands.
///
/// ## Examples
///
/// ```gleam
/// assert tick.adopted_backlog(model, model) == model.connection_backlog
/// ```
@internal
pub fn adopted_backlog(
  before: Model,
  after: Model,
) -> session_model.ConnectionBacklog {
  case
    buffered.sender(after.shared.inbox) == buffered.sender(before.shared.inbox)
  {
    True -> after.shared.connection_backlog
    False -> session_model.MailboxMayHoldMore
  }
}

// One recorded attempt event per tick, taken from what the runtime received
// before the step by the shared `lane_fold.take_replayed`. Its changes are
// applied one at a time, each as the host's unit of the lane fold: the
// terminal reads what it shows before each change and settles the surface
// facts the change recorded after it, as `inbound.apply_channel_update` does
// for a live update.
fn drain_replay(model: Model) -> Model {
  let #(shared, changes) = lane_fold.take_replayed(model.shared)
  list.fold(changes, tui_model.hold_shared(model, shared), apply_replay_change)
}

/// Applies one change of a replayed attempt event: the shared
/// `lane_fold.apply_replay_change`, given what the terminal shows, and then
/// the surface facts it recorded.
///
/// ## Examples
///
/// ```gleam
/// let model = tick.apply_replay_change(model, change)
/// ```
@internal
pub fn apply_replay_change(
  model: Model,
  change: attempt_replay.Change,
) -> Model {
  let around = inbound.surroundings(model)
  inbound.run_settled(model, lane_fold.apply_replay_change(_, change, around))
}

// The activity indicator has a session half and a terminal half. The
// elapsed readings are session state a second host shows too, so
// `session_step.advance_activity_clocks` moves them over the shared record
// alone; the
// glyph's animation frame is the terminal's, so it advances here, after the
// shared call. Each half marks the frame stale for its own change. When both
// change in one tick the frame revision moves twice, which nothing can see:
// its one reader, `refresh_frame_cache`, runs after the whole event and asks
// only whether the revision differs from the one it last painted.
//
// The glyph reads `active_strand_live` after the hold rather than a surface
// fact the clocks record. A fact would be recorded and cleared on every tick
// of a live strand, two copies of the shared record, which measured as 190
// more words on the idle tick; the read gives the same answer because the
// clocks change nothing it reads.
fn advance_activity_indicator(model: Model) -> Model {
  let model =
    tui_model.hold_shared(
      model,
      session_step.advance_activity_clocks(model.shared),
    )
  case session_model.active_strand_live(model.shared) {
    False -> model
    True -> {
      let activity_frame = model.view.activity_frame + 1
      let advanced = Model(..model, view: View(..model.view, activity_frame:))
      case
        layout.activity_glyph(model.view.activity_frame)
        == layout.activity_glyph(activity_frame)
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
// The reading is suppressed while the active strand is running
// (`cache_watch.shown` says why), which the web view's rings follow too.
fn advance_cache_outlook(model: Model) -> Model {
  let activity = case session_model.active_strand_live(model.shared) {
    True -> cache_watch.Running
    False -> cache_watch.Resting
  }
  let label =
    cache_watch.shown(
      model.shared.cache,
      model.shared.active_strand,
      activity,
      model.shared.stamp.now_ms,
    )
    |> option.map(cache_miss.outlook_label)
    |> option.unwrap("")
  case label == model.view.cache_outlook {
    True -> model
    False ->
      tui_model.invalidate_frame(
        Model(..model, view: view_set.cache_outlook(model.view, label)),
      )
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
  let screen = geometry.rect_new(0, 0, model.view.width, model.view.height)
  let freshness = case viewport_pacing(model) {
    // Rows the model holds but the viewport has not shown make the painted
    // frame stale by definition, whatever the revision says. Without this
    // the walk would stop after one step: revealing a row changes the frame
    // without changing any of the inputs the revision counts.
    pacing.ViewportCatchingUp -> pacing.FrameStale
    pacing.ViewportSettled ->
      case model.view.caches.frame_cache {
        Some(FrameCache(screen: cached_screen, revision:, ..))
          if cached_screen == screen && revision == model.shared.frame_revision
        -> pacing.FrameCurrent
        None | Some(_) -> pacing.FrameStale
      }
  }

  // The event's stamp is compared only against earlier stamps of the same
  // monotonic clock, so a wall-clock step cannot stretch or collapse the
  // interval.
  let now = model.shared.stamp.now_ms
  case
    pacing.frame_decision(boundary, freshness, now - model.view.last_frame_ms)
  {
    pacing.KeepCachedFrame -> model
    pacing.DeferFrame ->
      Model(
        ..model,
        view: view_set.frame_debt(model.view, pacing.FrameDeferred),
      )
    pacing.RenderFrame -> {
      // The step is taken before the frame is built, so the frame that is
      // cached and the position it was built from are the same moment.
      let paced = advance_viewport(model)
      Model(
        ..paced,
        view: View(
          ..{
            paced.view
            |> view_set.frame_debt(pacing.FrameSettled)
            |> view_set.caches(
              Caches(
                ..paced.view.caches,
                frame_cache: Some(FrameCache(
                  screen:,
                  revision: paced.shared.frame_revision,
                  rendered: render.render_frame(paced, screen),
                  selection_gutters: interaction.selection_gutters_on_display(
                    paced,
                  ),
                )),
              ),
            )
          },
          last_frame_ms: now,
        ),
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
  use <- bool.guard(
    layout.diff_covers_transcript(model),
    pacing.ViewportSettled,
  )
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
  case session_model.active_strand_live(model.shared) {
    False ->
      Model(
        ..model,
        view: view_set.revealed_rows(model.view, model.view.rendered_row_count),
      )
    True ->
      Model(
        ..model,
        view: view_set.revealed_rows(
          model.view,
          pacing.pace(
            model.view.revealed_rows,
            model.view.rendered_row_count,
            pace_policy(model),
          ),
        ),
      )
  }
}

/// The longest the loop waits for input when nothing is due sooner, in
/// milliseconds.
///
/// Socket traffic wakes the loop itself (`connection.connect_waking`) and
/// the lane names its own next deadline (`session_channel.next_due`), so
/// this ceiling is not what delivers either. It bounds what nothing else
/// announces: etui notices a resized window only when its loop runs, and a
/// time-driven label with nothing live under it, such as a cache countdown,
/// moves only on a tick. A second keeps both within a second while an idle
/// terminal wakes once a second instead of four times.
pub const idle_poll_ceiling_ms = 1000

/// The longest the loop waits while it `wakes_itself`, in milliseconds.
///
/// It is the cap the loop had on every wait before socket traffic woke
/// it, so what moves with time keeps the cadence it had: the activity
/// glyph advances one step per tick, and a strand running with no traffic
/// would otherwise animate at the 400 ms quiet poll. Job replies keep the
/// latency they had for the same reason.
pub const self_wake_ceiling_ms = 250

/// The wait this model would ask a terminal for before its next poll.
///
/// Arriving frames do not need the poll: the socket wakes the loop after it
/// files them, and the wake ends etui's input wait with a `Tick`. What the
/// poll is for is everything a wake does not announce, and its answer is the
/// first of these that applies:
///
/// - A drain that stopped at its batch polls at once, since the mailbox
///   holds frames whose wakes were spent on the ticks before.
/// - A viewport walking toward its newest row polls at the frame interval,
///   one row a frame.
/// - A lane with a request in flight polls at 8 ms. Its reply usually lands
///   within a wake interval of the wake that let the loop send the request,
///   so the socket holds that reply's wake to the interval's end; the short
///   poll takes the reply as soon as it did before wakes existed.
/// - A model that wakes itself (`wakes_itself`: something drawn moves with
///   time, a job is running, or frames are held) takes the paced poll,
///   capped at `self_wake_ceiling_ms` and by the lane's next deadline.
/// - Anything else sleeps until the lane's next deadline or refresh
///   (`session_channel.next_due`), capped at `idle_poll_ceiling_ms`.
///
/// A loading attachment candidate keeps its 8 ms wait throughout, because
/// it reads from disk as well as from its socket.
///
/// ## Examples
///
/// ```gleam
/// assert tui.terminal_poll_timeout(model) == 40
/// ```
@internal
pub fn terminal_poll_timeout(model: Model) -> Int {
  let ordinary =
    pacing.paced_poll_timeout(model.view.frame_debt, model.view.quiet_for_ms)

  // A loading session candidate is read from disk rather than from the
  // socket, so its short wait survives a backlog: nothing it drains can
  // lengthen the walk.
  let ordinary = case attachment.busy(model.view.candidate) {
    True -> int.min(ordinary, 8)
    False -> ordinary
  }

  // A drain that stopped at its batch left frames in the mailbox whose
  // wakes were spent on the ticks before, so the next batch is taken at
  // once. The ticks this costs are the batches the burst needs anyway, and
  // frame pacing still paints at most one frame per interval.
  use <- bool.guard(
    model.shared.connection_backlog == session_model.MailboxMayHoldMore,
    0,
  )
  case viewport_pacing(model) {
    // A backlog is work the loop owes the screen with nothing left to wake
    // it: the deltas that produced those rows are already drained. One row
    // is revealed per rendered frame, so the wait between wakes is the
    // interval between rows, and the shorter in-flight wait is deliberately
    // not taken — draining the socket sooner would only lengthen a backlog
    // the viewport has yet to show.
    pacing.ViewportCatchingUp -> int.min(ordinary, pacing.frame_interval_ms)
    pacing.ViewportSettled -> {
      let lane = lane_wait(model)
      case in_flight(model), wakes_itself(model) {
        True, _ -> int.min(ordinary, 8)
        False, True -> int.min(ordinary, int.min(lane, self_wake_ceiling_ms))
        False, False ->
          case attachment.busy(model.view.candidate) {
            True -> int.min(ordinary, lane)
            False -> lane
          }
      }
    }
  }
}

fn in_flight(model: Model) -> Bool {
  case model.shared.channel {
    Some(channel) -> session_channel.in_flight(channel)
    None -> False
  }
}

// How long until the adopted lane next has something for `tick` to do,
// measured from the step's transport reading, which is the clock the lane's
// deadlines are set on. A lane already due answers zero, and one with
// nothing due, or no lane at all, answers the ceiling.
fn lane_wait(model: Model) -> Int {
  let due = case model.shared.channel {
    Some(channel) -> session_channel.next_due(channel)
    None -> None
  }
  case due {
    Some(due) ->
      int.clamp(
        due - model.shared.stamp.transport_ms,
        min: 0,
        max: idle_poll_ceiling_ms,
      )
    None -> idle_poll_ceiling_ms
  }
}

/// Whether the loop must keep its paced poll rather than sleep until the
/// lane's next deadline.
///
/// Each clause is a thing that changes with time, or waits on a message,
/// without a socket wake to announce it:
///
/// - A strand running anywhere: the activity glyph, the generation clock
///   and the strip's elapsed times advance on ticks.
/// - A deferred frame: the tick after a burst is where it is painted.
/// - A running job: its replies arrive on the job's own subjects, which
///   wake nothing, and a tick is where they are taken.
/// - Frames the buffer still holds, as it does after an Escape that
///   cancelled before draining, or a drain that stopped at its batch
///   (`Model.connection_backlog`): their wakes may already have been spent
///   on earlier ticks.
///
/// ## Examples
///
/// ```gleam
/// assert tick.wakes_itself(idle_attached_model) == False
/// ```
@internal
pub fn wakes_itself(model: Model) -> Bool {
  list.any(model.shared.strands, fn(strand) { strand.live_phase != None })
  || session_model.active_strand_live(model.shared)
  || model.view.frame_debt == pacing.FrameDeferred
  || job_runner.size(model.view.running) > 0
  || buffered.held(model.shared.inbox) > 0
  || model.shared.connection_backlog == session_model.MailboxMayHoldMore
}

fn drain_candidate(model: Model) -> Model {
  interaction.advance_candidate(
    model,
    attachment.poll(model.view.candidate, now: model.shared.stamp.transport_ms),
  )
}
