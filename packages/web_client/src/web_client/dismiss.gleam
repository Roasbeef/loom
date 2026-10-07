//// `<loom-dismiss>`: closes the bar's context disclosure when a press lands
//// outside it or Escape is pressed, with no round trip.
////
//// The bar's context figure is a native `<details>` that the server draws
//// inside the bar's `figures` span, with this empty element after it
//// (`web_view/view/heading`). It is a sibling and not a wrapper so that the
//// disclosure keeps its place in the page's tree, and with it the path at which
//// the observer's socket admits the Refresh button's click. The browser opens
//// and closes the disclosure from its summary, and this element adds the two
//// ways out a disclosure panel is expected to have. It keeps no state: the
//// disclosure's own `open` attribute is the fact, and removing it from a closed
//// one changes nothing, so a verdict to close is applied without asking whether
//// it is open. The server never writes `open`, so a re-render does not undo the
//// person's choice either way.
////
//// A click on the document is read only by the `data-dismiss` marks of the nodes
//// it passed through (`dismiss_rule.after_click`), which is how a press on the
//// panel's own buttons is told from one elsewhere. Escape is read by its key
//// name and is not consumed, because nothing else on the page takes that key
//// outside the composer. Both listeners are on the document, one pair per
//// connection, and are removed when the element leaves the page. The element
//// sends the server nothing and reads no attribute from it.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import lustre
import lustre/component
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import web_client/dismiss_rule.{type Verdict}
import web_client/internal/ffi_dom.{type Listener}

/// The element's tag.
pub const name = "loom-dismiss"

/// What the element holds: the document listeners while it is connected.
pub type Model {
  Model(listeners: Option(Listeners))
}

/// The element's two document listeners, which `remove_listener` needs to name
/// to stop them.
pub type Listeners {
  Listeners(click: Listener, key: Listener)
}

/// Everything the element can be told.
pub type Msg {
  /// A click reached the document, having passed through nodes with these
  /// marks.
  Clicked(marks: List(dismiss_rule.Mark))

  /// A key was pressed.
  Keyed(key: String)

  /// The element joined the page.
  Connected

  /// The element left the page.
  Disconnected

  /// The document's listeners are in place.
  Listening(listeners: Listeners)
}

/// Registers the element with the browser.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(Nil) = dismiss.register()
/// ```
pub fn register() -> Result(Nil, lustre.Error) {
  lustre.component(init, update, view, [
    component.on_connect(Connected),
    component.on_disconnect(Disconnected),
  ])
  |> lustre.register(name)
}

fn init(_: Nil) -> #(Model, Effect(Msg)) {
  #(init_model(), effect.none())
}

/// The starting model, for a test that drives `update`.
///
/// ## Examples
///
/// ```gleam
/// assert dismiss.init_model().listeners == option.None
/// ```
pub fn init_model() -> Model {
  Model(listeners: None)
}

/// Applies one message.
///
/// A verdict to close becomes the one effect that removes `open` from the
/// disclosure; a verdict to keep is no effect.
///
/// ## Examples
///
/// ```gleam
/// assert dismiss.update(dismiss.init_model(), dismiss.Keyed("a")).1
///   == effect.none()
/// ```
pub fn update(model: Model, message: Msg) -> #(Model, Effect(Msg)) {
  case message {
    Clicked(marks:) -> #(model, apply(dismiss_rule.after_click(marks)))
    Keyed(key:) -> #(model, apply(dismiss_rule.after_key(key)))

    // One listener pair per connection: moving the element stops the old pair
    // before it starts another.
    Connected -> #(model, effect.batch([stop(model.listeners), listen()]))

    // `listen` registers after the paint, so this can arrive after a later
    // `Connected` has run; the pair the model still holds is stopped as the new
    // one is kept. The window is one paint, and the cost of losing it is a
    // listener whose messages reach a detached element, so it is left as it is.
    Listening(listeners:) -> #(
      Model(listeners: Some(listeners)),
      stop(model.listeners),
    )
    Disconnected -> #(Model(listeners: None), stop(model.listeners))
  }
}

// A verdict as an effect: closing removes `open` from the disclosure, which is
// the only thing the browser reads to draw it open.
fn apply(verdict: Verdict) -> Effect(Msg) {
  case verdict {
    dismiss_rule.Keep -> effect.none()
    dismiss_rule.Close -> {
      use _, root <- effect.after_paint
      let host = ffi_dom.host(ffi_dom.as_element(root))
      let found = {
        use figures <- result.try(ffi_dom.closest(host, ".figures"))
        ffi_dom.query_selector(figures, "details[data-dismiss]")
      }
      case found {
        Ok(disclosure) -> ffi_dom.remove_attribute(disclosure, "open")
        Error(Nil) -> Nil
      }
    }
  }
}

// Listens for `click` and `keydown` on the document, which hears a press
// wherever it lands. The click is reduced to the marks of the nodes it passed
// through before it is dispatched, and a key to its name.
fn listen() -> Effect(Msg) {
  use dispatch, _ <- effect.after_paint
  let click =
    ffi_dom.add_listener(ffi_dom.get_document(), "click", fn(event) {
      dispatch(Clicked(marks_of(event)))
    })
  let key =
    ffi_dom.add_listener(ffi_dom.get_document(), "keydown", fn(event) {
      case decode.run(event, decode.at(["key"], decode.string)) {
        Ok(key) -> dispatch(Keyed(key))
        Error(_) -> Nil
      }
    })
  dispatch(Listening(Listeners(click:, key:)))
}

fn marks_of(event: Dynamic) -> List(dismiss_rule.Mark) {
  ffi_dom.composed_path(event)
  |> list.filter_map(fn(node) {
    ffi_dom.attribute(node, "data-dismiss")
    |> result.try(dismiss_rule.mark)
  })
}

// Removes the document's listeners, if a pair is in place.
fn stop(listeners: Option(Listeners)) -> Effect(Msg) {
  case listeners {
    None -> effect.none()
    Some(Listeners(click:, key:)) -> {
      use _ <- effect.from
      ffi_dom.remove_listener(ffi_dom.get_document(), "click", click)
      ffi_dom.remove_listener(ffi_dom.get_document(), "keydown", key)
    }
  }
}

// The element draws nothing: the disclosure it acts on is not its child.
fn view(_: Model) -> Element(Msg) {
  element.none()
}
