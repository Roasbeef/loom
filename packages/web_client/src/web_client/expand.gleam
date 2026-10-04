//// `<loom-expand>`: a row with a line and a body, the body opened and closed
//// in the browser with no round trip to the server.
////
//// A step of a turn reads as one line (`Edit calc.py +3 −1`) and has more
//// behind it: the program, the result, the whole reasoning. The server draws
//// both (`web_view/view/fold_row`), the line in a child marked `slot="head"`
//// and the rest in a child marked `slot="body"`. This element owns only
//// whether the body is shown. Its shadow root holds one button, which carries
//// the chevron and the head slot, and, while the row is open, the body slot.
//// Every word the reader sees is the server's light-DOM children projected
//// through those slots; the element takes no attribute, renders no session
//// text of its own and has no words of its own (`expand_rule`).
////
//// The row starts closed on every page, and the reader's choice survives the
//// server's later patches, because the server never renders the state. The
//// button is a real button, so a keyboard opens it as it opens any button;
//// the element handles no key itself. The row's line is the button's
//// accessible name.
////
//// Each toggle dispatches `fold.toggled_event`, the event `<loom-fold>`
//// sends, so `<loom-follow>` takes the size change that follows as the
//// reader's own doing: opening the newest row at the bottom does not scroll
//// the page past the line the reader just pressed.

import gleam/json
import lustre
import lustre/attribute
import lustre/component
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import web_client/expand_rule.{type Shown}
import web_client/fold

/// The element's tag.
pub const name = "loom-expand"

/// Everything the element can be told.
pub type Msg {
  /// The reader pressed the row's line.
  Toggled
}

/// Registers the element with the browser.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(Nil) = expand.register()
/// ```
pub fn register() -> Result(Nil, lustre.Error) {
  lustre.component(init, update, view, [])
  |> lustre.register(name)
}

fn init(_: Nil) -> #(Shown, Effect(Msg)) {
  #(expand_rule.Closed, effect.none())
}

fn update(shown: Shown, message: Msg) -> #(Shown, Effect(Msg)) {
  case message {
    // The event is emitted in the turn of this update and the render
    // follows on the next animation frame, so `<loom-follow>` hears it
    // before the row's size changes, as it does for a fold.
    Toggled -> #(
      expand_rule.toggled(shown),
      event.emit(fold.toggled_event, json.null()),
    )
  }
}

fn view(shown: Shown) -> Element(Msg) {
  element.fragment([
    html.button(
      [
        attribute.type_("button"),
        attribute.class("expand-toggle"),
        attribute.aria_expanded(shown == expand_rule.Open),
        event.on_click(Toggled),
      ],
      [
        html.span([attribute.class("fold-glyph"), attribute.aria_hidden(True)], [
          html.text(expand_rule.glyph(shown)),
        ]),
        component.named_slot("head", [], []),
      ],
    ),
    case shown {
      expand_rule.Open -> component.named_slot("body", [], [])
      expand_rule.Closed -> element.none()
    },
  ])
}
