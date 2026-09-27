//// Turns etui's input event into the client's own event.
////
//// This is the whole of what stands between etui and the reducer, and it
//// only parses: a key's text becomes the `keys.Key` it names, a wheel
//// notch's `up` flag becomes a direction, and the rest are renamed. It
//// binds no key to a command. What Escape does depends on whether a
//// submission is waiting and which overlay is open, so that decision stays
//// in the reducer, which has the model; a translator that read the model to
//// decide it would be a second reducer running ahead of the first.
////
//// The translation is total and pure. The one input it takes from outside
//// the event is what reading a pasted path found, which the host reads
//// before the step (`runtime.message`) because reading a file is I/O.

import etui/backend
import etui/keys
import gleam/option.{type Option}
import tui/msg.{type Event}
import tui/pasted_image
import tui/recording

/// The client event an etui input event is.
///
/// `pasted` is what reading the path a paste names found; it is used only
/// for a paste, and a host passes `Ok(None)` for every other event.
///
/// ## Examples
///
/// ```gleam
/// assert keymap.translate(backend.Tick, Ok(None)) == msg.Ticked
/// assert keymap.translate(backend.KeyPress("esc"), Ok(None))
///   == msg.KeyPressed("esc", keys.Escape)
/// ```
@internal
pub fn translate(
  event: backend.InputEvent,
  pasted: Result(Option(pasted_image.Image), String),
) -> Event {
  case event {
    backend.KeyPress(text) -> msg.KeyPressed(text:, key: keys.match(text))
    backend.Paste(text) -> msg.Pasted(text:, image: pasted)
    backend.Resize(width, height) -> msg.Resized(width:, height:)
    backend.MouseScroll(x, y, True) ->
      msg.Scrolled(x:, y:, direction: recording.ScrollUp)
    backend.MouseScroll(x, y, False) ->
      msg.Scrolled(x:, y:, direction: recording.ScrollDown)
    backend.MousePress(x, y, button) -> msg.Pressed(x:, y:, button:)
    backend.MouseDrag(x, y, button) -> msg.Dragged(x:, y:, button:)
    backend.MouseRelease(x, y, button) -> msg.Released(x:, y:, button:)
    backend.MouseMove(x, y) -> msg.Moved(x:, y:)
    backend.Tick -> msg.Ticked
  }
}
