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
//// panel's own buttons is told from one elsewhere.
////
//// Escape is heard in the capture phase, before the shell's own Escape (back
//// to `main`) on the document's bubbling phase, and decided on the spot, since
//// stopping an event cannot wait for a message. With the panel open, the key
//// closes it and is stopped and cancelled (`dismiss_rule.on_key`), so the shell
//// never sees it. With the panel shut it is not touched at all. Both listeners
//// are on the document, one pair per connection, and are removed when the
//// element leaves the page. The element sends the server nothing and reads no
//// attribute from it.

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
/// assert dismiss.update(dismiss.init_model(), dismiss.Disconnected).0
///   == dismiss.init_model()
/// ```
pub fn update(model: Model, message: Msg) -> #(Model, Effect(Msg)) {
  case message {
    Clicked(marks:) -> #(model, apply(dismiss_rule.after_click(marks)))

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
      case disclosure_of(ffi_dom.host(ffi_dom.as_element(root))) {
        Ok(disclosure) -> ffi_dom.remove_attribute(disclosure, "open")
        Error(Nil) -> Nil
      }
    }
  }
}

// The disclosure this element belongs to: the marked `<details>` in the same
// `figures` span as the element.
fn disclosure_of(host: ffi_dom.Element) -> Result(ffi_dom.Element, Nil) {
  use figures <- result.try(ffi_dom.closest(host, ".figures"))
  ffi_dom.query_selector(figures, "details[data-dismiss]")
}

// Listens for `click` on the document, which hears a press wherever it lands,
// reduced to the marks of the nodes it passed through before it is dispatched,
// and for `keydown` in the capture phase, which is decided where it is heard.
fn listen() -> Effect(Msg) {
  use dispatch, root <- effect.after_paint
  let host = ffi_dom.host(ffi_dom.as_element(root))
  let click =
    ffi_dom.add_listener(ffi_dom.get_document(), "click", fn(event) {
      dispatch(Clicked(marks_of(event)))
    })
  let key =
    ffi_dom.add_capture_listener(ffi_dom.get_document(), "keydown", fn(event) {
      escaped(host, event)
    })
  dispatch(Listening(Listeners(click:, key:)))
}

// One keydown, in the capture phase. Only an Escape that finds the panel open
// is touched: it closes the panel and is stopped and cancelled, so the shell's
// Escape never runs for it.
fn escaped(host: ffi_dom.Element, event: Dynamic) -> Nil {
  let key = decode.run(event, decode.at(["key"], decode.string))
  case key, disclosure_of(host) {
    Ok(key), Ok(disclosure) ->
      case dismiss_rule.on_key(key, showing(disclosure)) {
        dismiss_rule.Consume -> {
          ffi_dom.remove_attribute(disclosure, "open")
          ffi_dom.stop_propagation(event)
          ffi_dom.prevent_default(event)
        }
        dismiss_rule.PassOn -> Nil
      }
    Ok(_), Error(Nil) | Error(_), _ -> Nil
  }
}

fn showing(disclosure: ffi_dom.Element) -> dismiss_rule.Disclosure {
  case ffi_dom.attribute(disclosure, "open") {
    Ok(_) -> dismiss_rule.Showing
    Error(Nil) -> dismiss_rule.Shut
  }
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
      ffi_dom.remove_capture_listener(ffi_dom.get_document(), "keydown", key)
    }
  }
}

// The element draws nothing: the disclosure it acts on is not its child.
fn view(_: Model) -> Element(Msg) {
  element.none()
}
