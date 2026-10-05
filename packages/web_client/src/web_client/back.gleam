//// `<loom-back>Home</loom-back>`: a button that goes one step back in the
//// tab's history.
////
//// Every keyed page is a history entry (`web_client/switch`), so the way from
//// the admin page to the home the owner came from is Back. The admin page
//// has no control that mints a ticket for the home, because a ticket minted
//// there would carry the admin page's fifteen-minute deadline; this control
//// mints nothing. It takes no attribute and no address, so nothing the server
//// writes can steer it anywhere: `history.back()` reaches only a page the tab
//// already visited, and the page it reaches connects with the nonce it kept
//// for itself (protocol-change/051, the addendum on navigation).
////
//// The button's label is the element's light content, projected through a
//// slot, so the server (or the ended document's fixed HTML) says what the
//// button is called and the element decides only what pressing it does. A tab
//// with no earlier entry does nothing when pressed, which is the browser's
//// answer to Back in a tab that has none.

import lustre
import lustre/attribute
import lustre/component
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import web_client/internal/ffi_dom

/// The element's tag.
pub const name = "loom-back"

/// Everything the element can be told.
pub type Msg {
  /// The button was pressed.
  Pressed
}

/// Registers the element with the browser.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(Nil) = back.register()
/// ```
pub fn register() -> Result(Nil, lustre.Error) {
  lustre.component(init, update, view, [])
  |> lustre.register(name)
}

fn init(_: Nil) -> #(Nil, Effect(Msg)) {
  #(Nil, effect.none())
}

// The one message goes back. The model holds nothing, because the browser's
// history is the state and the element only asks it to move.
fn update(model: Nil, message: Msg) -> #(Nil, Effect(Msg)) {
  case message {
    Pressed -> #(model, go_back())
  }
}

fn go_back() -> Effect(Msg) {
  use _ <- effect.from
  ffi_dom.history_back()
}

fn view(_: Nil) -> Element(Msg) {
  html.button(
    [
      attribute.type_("button"),
      attribute.class("ended-back"),
      event.on_click(Pressed),
    ],
    [component.default_slot([], [])],
  )
}
