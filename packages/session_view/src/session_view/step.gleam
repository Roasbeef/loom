//// The shared step's own settle: what every event does to the session
//// state after its handler has run.
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
//// The module holds that settle alone for now. A later slice moves it into
//// `session_view/step` beside the step's entry points.

import tui/session_model.{type Shared}
import tui/surfaces

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
