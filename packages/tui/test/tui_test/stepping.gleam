//// Steps a model with an etui input event, as the shipped loop would.
////
//// `tui.step` takes the client's own message (`tui/msg`), which the host
//// builds with `runtime.message`: it translates the event and reads the
//// clocks and any pasted file into it. A test that wants to inspect one
//// transition without acting on it usually wants none of those reads, so
//// this builds the message at the time the model already carries, with no
//// pasted file read. A test that needs another time sets `Model.stamp`
//// first; a test that needs a paste's read builds the `msg.Pasted` itself.

import etui/backend
import gleam/option.{None}
import tui
import tui/effect
import tui/keymap
import tui/model as tui_model
import tui/msg

/// The step the shipped loop takes for `event`, at `model.stamp`, with the
/// effects it decided returned rather than performed.
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
  tui.step(message(event, model), model)
}

/// The message the shipped loop builds for `event`, at `model.stamp`, with
/// no pasted file read.
///
/// ## Examples
///
/// ```gleam
/// let message = stepping.message(backend.Tick, model)
/// ```
pub fn message(event: backend.InputEvent, model: tui_model.Model) -> msg.Msg {
  msg.Msg(model.stamp, keymap.translate(event, Ok(None)))
}
