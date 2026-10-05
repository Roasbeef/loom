//// `<loom-popover wanted="open">`: opens and closes the home's account panel
//// from the person's name in the bar, with no round trip.
////
//// The home draws the person's name as a button in the bar, and the panel it
//// opens (the sign-ins, the bookmark, the device link) as the centre's third
//// child, where the socket admits its clicks (`home.signins_path`). The two are
//// far apart in the tree, so this element is the only thing that joins them. It
//// wraps the name's button in the light DOM, draws that child through a slot
//// and nothing else, and keeps one fact: whether the panel is open
//// (`popover_rule.State`). The fact is published as the custom state `open` on
//// the element itself, and the stylesheet shows the panel while the page's
//// frame holds an element in that state (`loom-shell:has(loom-popover:state(open))`),
//// so the server never renders for it and a re-render of the panel cannot undo
//// it. The button's `aria-expanded` is written to match.
////
//// A click on the document is read only by the `data-popover` marks of the
//// nodes it passed through (`popover_rule.after_click`), so one listener serves
//// the toggle, a press inside the panel that must leave it open, and a press
//// anywhere else that closes it. Escape closes it too. Both listeners are on the
//// document, one pair per connection, and are removed when the element leaves
//// the page. The element sends the server nothing and reads from it one
//// attribute, `wanted`, which holds `open` while a device link is on show so the
//// link is on screen when it arrives.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import lustre
import lustre/component
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import web_client/internal/ffi_dom.{type Listener}
import web_client/popover_rule.{type State}

/// The element's tag.
pub const name = "loom-popover"

/// What the element holds: whether the panel is open, and the document
/// listeners while the element is connected.
pub type Model {
  Model(state: State, listeners: Option(Listeners))
}

/// The element's two document listeners, which `remove_listener` needs to name
/// to stop them.
pub type Listeners {
  Listeners(click: Listener, key: Listener)
}

/// Everything the element can be told.
pub type Msg {
  /// The server wrote `open`.
  Wanted

  /// A click reached the document, having passed through nodes with these
  /// marks.
  Clicked(marks: List(popover_rule.Mark))

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
/// // let assert Ok(Nil) = popover.register()
/// ```
pub fn register() -> Result(Nil, lustre.Error) {
  lustre.component(init, update, view, [
    component.on_attribute_change("wanted", wanted),
    component.on_connect(Connected),
    component.on_disconnect(Disconnected),
  ])
  |> lustre.register(name)
}

// The attribute decoded totally: only `open` is a message.
fn wanted(value: String) -> Result(Msg, Nil) {
  popover_rule.wanted(value) |> result.replace(Wanted)
}

fn init(_: Nil) -> #(Model, Effect(Msg)) {
  #(init_model(), effect.none())
}

/// The starting model, for a test that drives `update`.
///
/// ## Examples
///
/// ```gleam
/// assert popover.init_model().state == popover_rule.Closed
/// ```
pub fn init_model() -> Model {
  Model(state: popover_rule.Closed, listeners: None)
}

/// Applies one message.
///
/// A message that changes the state publishes it: the custom state the
/// stylesheet reads and the toggle's `aria-expanded`. One that leaves it as it
/// was publishes nothing.
///
/// ## Examples
///
/// ```gleam
/// assert popover.update(popover.init_model(), popover.Wanted).0.state
///   == popover_rule.Open
/// ```
pub fn update(model: Model, message: Msg) -> #(Model, Effect(Msg)) {
  case message {
    Wanted -> shown(model, popover_rule.Open)
    Clicked(marks:) ->
      shown(model, popover_rule.after_click(model.state, marks))
    Keyed(key:) -> shown(model, popover_rule.after_key(model.state, key))

    // One listener pair per connection: moving the element stops the old pair
    // before it starts another.
    Connected -> #(model, effect.batch([stop(model.listeners), listen()]))

    // `listen` registers after the paint, so this can arrive after a later
    // `Connected` or a `Disconnected` has run. Whatever pair the model still
    // holds is stopped as the new one is kept.
    Listening(listeners:) -> #(
      Model(..model, listeners: Some(listeners)),
      stop(model.listeners),
    )
    Disconnected -> #(Model(..model, listeners: None), stop(model.listeners))
  }
}

// The model with a new state, and the effect that publishes it when it is not
// the state it already had.
fn shown(model: Model, state: State) -> #(Model, Effect(Msg)) {
  case state == model.state {
    True -> #(model, effect.none())
    False -> #(Model(..model, state:), publish(state))
  }
}

fn publish(state: State) -> Effect(Msg) {
  effect.batch([
    case state {
      popover_rule.Open -> component.set_pseudo_state(popover_rule.open_state)
      popover_rule.Closed ->
        component.remove_pseudo_state(popover_rule.open_state)
    },
    expand(state),
  ])
}

// The toggle's `aria-expanded`, which the server drew as `false` and never
// draws again, so its diff cannot overwrite what this writes.
fn expand(state: State) -> Effect(Msg) {
  use _, root <- effect.after_paint
  let host = ffi_dom.host(ffi_dom.as_element(root))
  case ffi_dom.query_selector(host, "[data-popover=toggle]") {
    Ok(button) ->
      ffi_dom.set_attribute(
        button,
        "aria-expanded",
        popover_rule.expanded(state),
      )
    Error(Nil) -> Nil
  }
}

// Listens for `click` and `keydown` on the document, which hears a press
// wherever it lands, the panel and the rest of the page alike. The click is
// reduced to the marks of the nodes it passed through before it is dispatched,
// and a key to its name.
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

fn marks_of(event: Dynamic) -> List(popover_rule.Mark) {
  ffi_dom.composed_path(event)
  |> list.filter_map(fn(node) {
    ffi_dom.attribute(node, "data-popover")
    |> result.try(popover_rule.mark)
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

// The name's button, projected through the one slot.
fn view(_: Model) -> Element(Msg) {
  component.default_slot([], [])
}
