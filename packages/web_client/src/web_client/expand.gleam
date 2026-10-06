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
//// A reasoning block is drawn first as a live row and then as the settled row
//// that replaces it, and a reader who opened the first expects the second to
//// be open. An open live row leaves a note on the document, and only a
//// settled row the server marked `handoff="yes"` (the lane's newest settled
//// reasoning row) takes it (`expand_rule.takes`), so an older row that Load
//// older mounts never does. Known edge: the note names no block, so a page
//// switch within `expand_rule.handoff_window_ms` of an open live row leaving
//// can hand its state to the first marked row of the next page. Nothing
//// further guards that case.
////
//// Each toggle dispatches `fold.toggled_event`, the event `<loom-fold>`
//// sends, so `<loom-follow>` takes the size change that follows as the
//// reader's own doing: opening the newest row at the bottom does not scroll
//// the page past the line the reader just pressed.

import gleam/int
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
import web_client/internal/ffi_dom

/// The element's tag.
pub const name = "loom-expand"

/// What the element keeps: whether its body is shown and what the server
/// says the row is.
pub type Model {
  Model(shown: Shown, kind: expand_rule.Kind, mark: expand_rule.Mark)
}

/// Everything the element can be told.
pub type Msg {
  /// The reader pressed the row's line.
  Toggled

  /// The server's `kind` attribute arrived or changed.
  KindChanged(kind: expand_rule.Kind)

  /// The server's `handoff` attribute arrived or changed.
  MarkChanged(mark: expand_rule.Mark)

  /// A live reasoning row that was open left the page as this settled row
  /// arrived, so this one opens too.
  HandedOver

  /// The row left the page.
  Disconnected
}

// The page-wide note a live reasoning row leaves for its settled successor:
// the time until which an open live row's state is on offer, kept as an
// attribute of the document's element, which is the one place both rows can
// read it from.
const handoff_attribute = "data-reasoning-open-until"

/// Registers the element with the browser.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(Nil) = expand.register()
/// ```
pub fn register() -> Result(Nil, lustre.Error) {
  lustre.component(init, update, view, [
    component.on_attribute_change("kind", fn(value) {
      Ok(KindChanged(expand_rule.kind(value)))
    }),
    component.on_attribute_change("handoff", fn(value) {
      Ok(MarkChanged(expand_rule.mark(value)))
    }),
    component.on_disconnect(Disconnected),
  ])
  |> lustre.register(name)
}

fn init(_: Nil) -> #(Model, Effect(Msg)) {
  #(
    Model(
      shown: expand_rule.Closed,
      kind: expand_rule.Plain,
      mark: expand_rule.Unmarked,
    ),
    effect.none(),
  )
}

fn update(model: Model, message: Msg) -> #(Model, Effect(Msg)) {
  case message {
    // The event is emitted in the turn of this update and the render
    // follows on the next animation frame, so `<loom-follow>` hears it
    // before the row's size changes, as it does for a fold. An open live row
    // publishes that it is open, and a closed one withdraws the offer.
    Toggled -> {
      let shown = expand_rule.toggled(model.shown)
      #(
        Model(..model, shown:),
        effect.batch([
          event.emit(fold.toggled_event, json.null()),
          publish(model.kind, shown),
          opened(shown),
        ]),
      )
    }

    // A settled row the server marked takes the offer of a live row that was
    // open, once, so two settled rows do not both open for one live one. The
    // kind and the mark are separate attributes and arrive in either order, so
    // each is checked against the other.
    KindChanged(kind:) -> {
      let model = Model(..model, kind:)
      #(model, claim(model))
    }
    MarkChanged(mark:) -> {
      let model = Model(..model, mark:)
      #(model, claim(model))
    }
    HandedOver -> #(
      Model(..model, shown: expand_rule.Open),
      opened(expand_rule.Open),
    )

    // An open live row that leaves lets its offer run out in a moment, unless
    // the settled row took it first (the note is gone then).
    Disconnected -> #(model, case model.kind, model.shown {
      expand_rule.Live, expand_rule.Open -> expire_offer()
      _, _ -> effect.none()
    })
  }
}

// The custom state the stylesheet reads, set while the body is shown.
fn opened(shown: Shown) -> Effect(Msg) {
  case shown {
    expand_rule.Open -> component.set_pseudo_state(expand_rule.open_state)
    expand_rule.Closed -> component.remove_pseudo_state(expand_rule.open_state)
  }
}

fn publish(kind: expand_rule.Kind, shown: Shown) -> Effect(Msg) {
  use _ <- effect.from
  case kind, shown {
    expand_rule.Live, expand_rule.Open ->
      ffi_dom.set_attribute(
        ffi_dom.document_element(),
        handoff_attribute,
        int.to_string(expand_rule.standing),
      )
    expand_rule.Live, expand_rule.Closed ->
      ffi_dom.remove_attribute(ffi_dom.document_element(), handoff_attribute)
    _, _ -> Nil
  }
}

fn claim(model: Model) -> Effect(Msg) {
  case model.kind, model.mark {
    expand_rule.Settled, expand_rule.Marked -> take_offer(model.mark)
    _, _ -> effect.none()
  }
}

fn take_offer(mark: expand_rule.Mark) -> Effect(Msg) {
  use dispatch <- effect.from
  let root = ffi_dom.document_element()
  case ffi_dom.attribute(root, handoff_attribute) {
    Ok(deadline) ->
      case expand_rule.takes(mark, deadline, ffi_dom.now()) {
        True -> {
          ffi_dom.remove_attribute(root, handoff_attribute)
          dispatch(HandedOver)
        }
        False -> Nil
      }
    Error(Nil) -> Nil
  }
}

fn expire_offer() -> Effect(Msg) {
  use _ <- effect.from
  let root = ffi_dom.document_element()
  case ffi_dom.attribute(root, handoff_attribute) {
    Ok(_) ->
      ffi_dom.set_attribute(
        root,
        handoff_attribute,
        int.to_string(ffi_dom.now() + expand_rule.handoff_window_ms),
      )
    Error(Nil) -> Nil
  }
}

fn view(model: Model) -> Element(Msg) {
  let shown = model.shown
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
