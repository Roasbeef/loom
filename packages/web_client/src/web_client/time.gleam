//// `<loom-time at="1790030460000">`: an instant, drawn as the time of day in
//// the browser's own zone.
////
//// The admin page's refusal of a fourth grant in an hour says when the next is
//// free. The daemon knows the instant and the server cannot know where the
//// person is, so the server writes the instant as an attribute and this element
//// draws it as `13:02` in the zone the browser reports (`web_client/time_rule`),
//// which is what the owner's clock reads. The server also writes the instant's
//// UTC time as the element's light text and its `title`. The light text is
//// projected through the default slot until the element has drawn a time, and
//// whenever `at` does not parse, so a page never shows an empty gap; the title
//// lets a person compare the two.
////
//// The attribute is an instant and not a duration, so a browser whose clock
//// disagrees with the daemon's still shows the daemon's instant correctly in
//// its zone. The element draws one text node in its own shadow root, from a
//// number the daemon wrote, never session text. It handles no key, takes no
//// focus and sends the server nothing.

import gleam/option.{type Option, None, Some}
import lustre
import lustre/component
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import web_client/internal/ffi_dom
import web_client/time_rule

/// The element's tag.
pub const name = "loom-time"

/// Everything the element can be told.
pub type Msg {
  /// The server wrote an instant.
  Instanted(milliseconds: Int)

  /// The browser answered with the clock time of the instant in its zone.
  Drawn(clock: String)
}

/// Registers the element with the browser.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(Nil) = time.register()
/// ```
pub fn register() -> Result(Nil, lustre.Error) {
  lustre.component(init, update, view, [
    component.on_attribute_change("at", instanted),
  ])
  |> lustre.register(name)
}

// An `at` that is not a whole number is ignored, which leaves the element
// showing what it showed; the server only ever writes digits.
fn instanted(value: String) -> Result(Msg, Nil) {
  case time_rule.instant(value) {
    Ok(milliseconds) -> Ok(Instanted(milliseconds))
    Error(Nil) -> Error(Nil)
  }
}

fn init(_: Nil) -> #(Option(String), Effect(Msg)) {
  #(None, effect.none())
}

/// Applies one message. The zone is read only inside an effect, so `update` is
/// a function of its messages.
///
/// ## Examples
///
/// ```gleam
/// assert time.update(None, time.Drawn("13:02")).0 == Some("13:02")
/// ```
pub fn update(
  model: Option(String),
  message: Msg,
) -> #(Option(String), Effect(Msg)) {
  case message {
    Instanted(milliseconds:) -> #(model, localise(milliseconds))
    Drawn(clock:) -> #(Some(clock), effect.none())
  }
}

fn localise(milliseconds: Int) -> Effect(Msg) {
  use dispatch <- effect.from
  dispatch(
    Drawn(time_rule.clock(
      milliseconds,
      ffi_dom.timezone_offset_minutes(milliseconds),
    )),
  )
}

fn view(model: Option(String)) -> Element(Msg) {
  case model {
    Some(clock) -> html.text(clock)
    None -> component.default_slot([], [])
  }
}
