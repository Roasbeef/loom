//// `<loom-fold>`: a turn's work, folded under its divider, opened and closed
//// in the browser with no round trip to the server.
////
//// The server component renders the fold with two kinds of child: the
//// divider's words in a child marked `slot="summary"`, and the work itself
//// as the rest. This element owns only whether the work is shown. Its shadow
//// root holds one button, which carries the summary slot, and, while the
//// fold is open, the default slot. Every word the reader sees is the
//// server's light-DOM children projected through those slots; the element
//// takes no attribute and renders no session text of its own.
////
//// The fold starts closed on every page, as the spec asks, and a reader's
//// choice survives the server's later patches, because the server never
//// renders the state and the element is keyed by the turn it folds. The
//// button is a real button, so a keyboard opens it as it opens any button;
//// the element handles no key itself.
////
//// Each toggle dispatches `toggled_event` from the element, bubbling and
//// composed, with no data. `<loom-follow>` hears it and takes the growth
//// that follows as the reader's own doing, so opening the newest turn's
//// fold does not scroll the page past the divider the reader just pressed.

import gleam/json
import lustre
import lustre/attribute
import lustre/component
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

/// The element's tag.
pub const name = "loom-fold"

/// The event the element dispatches from itself each time it opens or
/// closes. It carries no data.
pub const toggled_event = "loom-fold-toggled"

/// Whether the work is shown.
pub type Model {
  /// Only the divider is shown.
  Closed

  /// The divider and the work are shown.
  Opened
}

/// Everything the element can be told.
pub type Msg {
  /// The reader pressed the divider.
  Toggled
}

/// Registers the element with the browser.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(Nil) = fold.register()
/// ```
pub fn register() -> Result(Nil, lustre.Error) {
  lustre.component(init, update, view, [])
  |> lustre.register(name)
}

fn init(_: Nil) -> #(Model, Effect(Msg)) {
  #(Closed, effect.none())
}

/// Applies one message.
///
/// ## Examples
///
/// ```gleam
/// assert fold.update(fold.Closed, fold.Toggled).0 == fold.Opened
/// ```
pub fn update(model: Model, message: Msg) -> #(Model, Effect(Msg)) {
  case message, model {
    Toggled, Closed -> #(Opened, announce())
    Toggled, Opened -> #(Closed, announce())
  }
}

// Lustre performs this effect in the same turn as the update and renders
// on the next animation frame, so the event reaches `<loom-follow>` before
// the fold's size changes.
fn announce() -> Effect(Msg) {
  event.emit(toggled_event, json.null())
}

fn view(model: Model) -> Element(Msg) {
  let #(glyph, expanded) = case model {
    Closed -> #("▸", False)
    Opened -> #("▾", True)
  }
  element.fragment([
    html.button(
      [
        attribute.type_("button"),
        attribute.class("fold-toggle"),
        attribute.aria_expanded(expanded),
        event.on_click(Toggled),
      ],
      [
        html.span([attribute.class("fold-glyph"), attribute.aria_hidden(True)], [
          html.text(glyph),
        ]),
        component.named_slot("summary", [], []),
      ],
    ),
    case model {
      Opened -> component.default_slot([attribute.class("fold-body")], [])
      Closed -> element.none()
    },
  ])
}
