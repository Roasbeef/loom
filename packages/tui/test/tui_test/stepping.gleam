//// Steps a model with an etui input event, as the shipped loop would.
////
//// `tui.step` takes the client's own message (`tui/msg`), which the host
//// builds with `runtime.message`: it translates the event and reads the
//// clocks and any pasted file into it. A test that wants to inspect one
//// transition without acting on it usually wants none of those reads, so
//// this builds the message at the time the model already carries, with no
//// pasted file read. A test that needs another time sets
//// `Model.shared.stamp`, or `Model.view.wall_ms` for the wall clock,
//// first; a test that needs a paste's read builds the `msg.Pasted` itself.

import etui/backend
import gleam/option.{None}
import tui
import tui/effect
import tui/keymap
import tui/model as tui_model
import tui/msg

/// The step the shipped loop takes for `event`, at `model.shared.stamp`,
/// with the effects it decided returned rather than performed.
///
/// It also checks, after every step it drives, that the shared record's
/// outbox is empty. A terminal reducer stores the result of each call into
/// a function over `Shared` through `tui_model.hold_shared`, which moves
/// what that call queued into the step's own outbox; a result stored any
/// other way leaves its effects on `Shared.outbox`, where the runtime never
/// looks, so they would never be performed. The queue editor's notices and
/// the goal inspector's observations are checked the same way.
///
/// ## Examples
///
/// ```gleam
/// let #(next, effects) = stepping.step(backend.Tick, model)
/// ```
pub fn step(
  event: backend.InputEvent,
  model: tui_model.Model,
) -> #(tui_model.Model, List(effect.Effect)) {
  let #(next, effects) = tui.step(message(event, model), model)
  assert next.shared.outbox == []
    as "a shared call's effects were stored without hold_shared"

  // The notices a shared call records for the terminal's queue editor and
  // goal inspector are shown and emptied by `hold_shared` too, so any left
  // after a step were stored without it and never reached the surface.
  assert next.shared.queue_notices == []
    as "a shared call's queue notices were stored without hold_shared"
  assert next.shared.goal_observations == []
    as "a shared call's goal observations were stored without hold_shared"
  #(next, effects)
}

/// The message the shipped loop builds for `event`, at `model.shared.stamp`
/// and `model.view.wall_ms`, with no pasted file read.
///
/// ## Examples
///
/// ```gleam
/// let message = stepping.message(backend.Tick, model)
/// ```
pub fn message(event: backend.InputEvent, model: tui_model.Model) -> msg.Msg {
  msg.Input(
    model.shared.stamp,
    model.view.wall_ms,
    keymap.translate(event, Ok(None)),
  )
}
