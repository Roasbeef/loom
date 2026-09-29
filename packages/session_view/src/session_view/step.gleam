//// The shared step's own units: what every event does to the session state
//// after its handler has run, and what every tick does to it.
////
//// Three surfaces decide whether an event made their data stale by
//// comparing the session state before the event with the state after it:
//// the context panel (`surfaces.sync_context`), the advisor's pending
//// nudges (`surfaces.sync_advisor_nudges`) and the session goal
//// (`surfaces.sync_goal`). Each reads and writes the shared record alone,
//// so the three together are the settle a second host's step runs after
//// every event, as the terminal's `settle_update` does
//// (`docs/design-notes/step-extraction.md`, section 3, the seventh cut).
////
//// A tick has two session units besides the lane's. The side surfaces'
//// reads (`service_reads`) send whichever waiting read the lane's one
//// command slot allows, in a fixed order, and the clocks
//// (`advance_activity_clocks`) move the elapsed readings a host shows to
//// the stamp. The terminal's tick calls each at its place in its own chain
//// of drains (`tui/tick`); both read and write the shared record alone, so a
//// second host's tick runs the same ones.
////
//// The module holds these units alone for now. The step's entry points,
//// which a host with no surfaces of its own can drive whole, are to join
//// them here (`docs/design-notes/step-extraction.md`, section 2, and
//// question 12).

import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import session_view/model.{type Shared, Shared} as session_model
import session_view/surfaces

/// Runs the shared edges for one event, from `before` to `after`: the
/// context read, the pending-nudge read or clear, and the goal read, in that
/// order.
///
/// Each edge compares `before` with the state the previous edge left, and
/// none of them writes what a later one compares, so the order is the one
/// the terminal has always run them in rather than one they depend on. The
/// three calls go to another module and apply to the parameter `after`,
/// which keeps them out of the Erlang inliner's reach in the terminal's
/// settle chain (the comment above `apply_input` in `tui.gleam`).
///
/// ## Examples
///
/// ```gleam
/// let shared = session_step.settle(before.shared, after.shared)
/// ```
@internal
pub fn settle(
  before: Shared(socket, recorder, source, replay_source),
  after: Shared(socket, recorder, source, replay_source),
) -> Shared(socket, recorder, source, replay_source) {
  surfaces.sync_context(before, after)
  |> surfaces.sync_advisor_nudges(before, _)
  |> surfaces.sync_goal(before, _)
}

/// Sends whichever of the side surfaces' waiting reads the lane allows, in
/// the order the tick has always serviced them: the queue, the worktree,
/// the notes, the todo seed, the live jobs, the context, the advisor's
/// pending nudges and the goal.
///
/// The reads share the lane's one command slot, so the order decides which
/// waiting read is sent first. Each reads and writes the shared record
/// alone, so the eight run as one chain and a host stores the result once.
///
/// ## Examples
///
/// ```gleam
/// let shared = session_step.service_reads(model.shared)
/// ```
@internal
pub fn service_reads(
  shared: Shared(socket, recorder, source, replay_source),
) -> Shared(socket, recorder, source, replay_source) {
  shared
  |> surfaces.service_queue_read
  |> surfaces.service_worktree_read
  |> surfaces.service_notes_read
  |> surfaces.service_todo_seed
  |> surfaces.service_jobs_read
  |> surfaces.service_context_read
  |> surfaces.service_advisor_nudges_read
  |> surfaces.service_goal_read
}

/// Advances the active strand's activity clock and the generation clock to
/// the stamp.
///
/// The tick is the one place the elapsed counts move, so rendering stays a
/// pure function of the record. The time is the event's stamp. Going idle
/// clears the start, so the next activity counts from zero rather than from
/// wherever the last one stopped. The frame is marked stale when the count a
/// host shows has moved; the terminal's glyph is advanced by its own half,
/// after this call.
///
/// ## Examples
///
/// ```gleam
/// let shared = session_step.advance_activity_clocks(model.shared)
/// ```
@internal
pub fn advance_activity_clocks(
  shared: Shared(socket, recorder, source, replay_source),
) -> Shared(socket, recorder, source, replay_source) {
  let shared = advance_generation_clock(shared)
  case session_model.active_strand_live(shared) {
    False -> Shared(..shared, activity_started_ms: None, activity_elapsed_s: 0)
    True -> {
      let now = shared.stamp.now_ms
      let started = option.unwrap(shared.activity_started_ms, now)
      let activity_elapsed_s = { now - started } / 1000
      let advanced =
        Shared(
          ..shared,
          activity_started_ms: Some(started),
          activity_elapsed_s:,
        )
      case activity_elapsed_s == shared.activity_elapsed_s {
        True -> advanced
        False -> session_model.invalidate_frame(advanced)
      }
    }
  }
}

// A live reasoning row shows how long the generation has run, read from the
// generation clock the event fold starts and stops and the event's stamp, so
// the step reads no clock of its own. The reading moves once a second, and
// only a change repaints; the repaint rebuilds the transient rows and reuses
// every durable one, because the record cache's inputs have not moved. A
// generation with no reasoning row on screen is read but not repainted,
// since nothing drawn depends on the figure.
fn advance_generation_clock(
  shared: Shared(socket, recorder, source, replay_source),
) -> Shared(socket, recorder, source, replay_source) {
  let elapsed = case shared.generation_started_ms {
    None -> 0
    Some(started) -> int.max({ shared.stamp.now_ms - started } / 1000, 0)
  }
  use <- bool.guard(
    when: elapsed == shared.generation_elapsed_s,
    return: shared,
  )

  let advanced = Shared(..shared, generation_elapsed_s: elapsed)
  let reasoning_shown =
    !shared.details_expanded
    && list.any(shared.streams, fn(stream) {
      stream.strand == shared.active_strand && stream.kind == "thinking"
    })
  case reasoning_shown {
    False -> advanced
    True ->
      advanced
      |> session_model.invalidate_transcript
      |> session_model.invalidate_frame
  }
}
