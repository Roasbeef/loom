//// `<loom-expand>`: a row shown compact or in full, chosen in the browser
//// with no round trip to the server.
////
//// The terminal's `Ctrl+g` shows a call's whole program and result and a
//// reasoning block's whole text, where the transcript shows a few lines.
//// The page holds the same records, so the server draws both forms of a row
//// that has more to show (`web_view/view/lane`): the compact rows in a child
//// marked `slot="compact"`, the full rows, cut to the page's budget, in a
//// child marked `slot="full"`. This element owns only which of them is
//// shown. Its shadow root holds one button and one slot; every word the
//// reader sees of the session is the server's light-DOM children projected
//// through that slot. The element takes no attribute and renders no session
//// text of its own, and its button carries fixed words (`expand_rule`).
////
//// The row starts compact on every page, and the reader's choice survives
//// the server's later patches, because the server never renders the state.
//// The button is a real button, so a keyboard opens it as it opens any
//// button; the element handles no key itself.
////
//// Each toggle dispatches `fold.toggled_event`, the event `<loom-fold>`
//// sends, so `<loom-follow>` takes the size change that follows as the
//// reader's own doing: expanding the newest row at the bottom does not
//// scroll the page past the button the reader just pressed.

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
  /// The reader pressed the button.
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
  #(expand_rule.Compact, effect.none())
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
        attribute.aria_expanded(shown == expand_rule.Full),
        event.on_click(Toggled),
      ],
      [
        html.span([attribute.class("fold-glyph"), attribute.aria_hidden(True)], [
          html.text(expand_rule.glyph(shown)),
        ]),
        html.text(expand_rule.words(shown)),
      ],
    ),
    component.named_slot(expand_rule.slot(shown), [], []),
  ])
}
