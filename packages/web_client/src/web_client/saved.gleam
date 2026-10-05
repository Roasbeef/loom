//// `<loom-saved>`: folds and unfolds the sidebar's saved sessions from the
//// quiet "N saved" line, with no round trip.
////
//// The sidebar draws the saved sessions after the running ones, in a panel the
//// stylesheet hides, and the "N saved" line as a button inside this element
//// (`web_view/view/sidebar`, its light child, drawn through one slot). The
//// element keeps one fact, whether the panel is showing
//// (`saved_rule.State`), and publishes it as the custom state `shown` on
//// itself, which the stylesheet reads to show the panel under the line, and as
//// the button's `aria-expanded`. The server never renders for it, and a
//// re-render of the list cannot undo it.
////
//// A press on the line, which reaches the element's own shadow tree through
//// the slot, flips the state and writes it to the browser's storage under one
//// item (`saved_rule.key`), so the next page the person opens keeps the choice.
//// When the element joins the page it reads the item once, after the first
//// paint. A blocked or missing storage is the default, hidden, and the press
//// still works for the page in front of the person. The element takes no
//// attribute and sends the server nothing, so it adds no socket admission, and
//// the saved sessions stay in the document while folded, which is how the
//// session switcher still lists them.

import lustre
import lustre/component
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import web_client/internal/ffi_dom
import web_client/saved_rule.{type State}

/// The element's tag.
pub const name = "loom-saved"

/// What the element holds: whether the saved sessions are showing.
pub type Model {
  Model(state: State)
}

/// Everything the element can be told.
pub type Msg {
  /// The element joined the page, so the stored choice is read.
  Connected

  /// The storage answered: the state it names, or hidden.
  Restored(state: State)

  /// The line was pressed.
  Pressed
}

/// Registers the element with the browser.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(Nil) = saved.register()
/// ```
pub fn register() -> Result(Nil, lustre.Error) {
  lustre.component(init, update, view, [component.on_connect(Connected)])
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
/// assert saved.init_model().state == saved_rule.Hidden
/// ```
pub fn init_model() -> Model {
  Model(state: saved_rule.Hidden)
}

/// Applies one message.
///
/// A message that changes the state publishes it: the custom state the
/// stylesheet reads and the line's `aria-expanded`. A press also writes the
/// choice to the storage. A restored state is not written back, since it is
/// what the storage already holds.
///
/// ## Examples
///
/// ```gleam
/// assert saved.update(saved.init_model(), saved.Restored(saved_rule.Shown)).0.state
///   == saved_rule.Shown
/// ```
pub fn update(model: Model, message: Msg) -> #(Model, Effect(Msg)) {
  case message {
    Connected -> #(model, read())

    Restored(state:) -> shown(model, state, effect.none())

    // The choice is saved in the same turn it is made, so a reload after the
    // press shows what the person chose.
    Pressed -> {
      let state = saved_rule.flipped(model.state)
      shown(model, state, save(state))
    }
  }
}

// The model with a new state, and the effects that publish it when it is not
// the state it already had, followed by `extra`.
fn shown(
  model: Model,
  state: State,
  extra: Effect(Msg),
) -> #(Model, Effect(Msg)) {
  case state == model.state {
    True -> #(model, effect.none())
    False -> #(Model(state:), effect.batch([publish(state), extra]))
  }
}

fn publish(state: State) -> Effect(Msg) {
  effect.batch([
    case state {
      saved_rule.Shown -> component.set_pseudo_state(saved_rule.shown_state)
      saved_rule.Hidden -> component.remove_pseudo_state(saved_rule.shown_state)
    },
    expand(state),
  ])
}

// The line's `aria-expanded`, which the server drew as `false` and never draws
// again, so its diff cannot overwrite what this writes.
fn expand(state: State) -> Effect(Msg) {
  use _, root <- effect.after_paint
  let host = ffi_dom.host(ffi_dom.as_element(root))
  case ffi_dom.query_selector(host, "[data-saved=toggle]") {
    Ok(button) ->
      ffi_dom.set_attribute(button, "aria-expanded", saved_rule.expanded(state))
    Error(Nil) -> Nil
  }
}

// Reads the stored choice once the element is on the page.
fn read() -> Effect(Msg) {
  use dispatch, _ <- effect.after_paint
  dispatch(Restored(saved_rule.restored(ffi_dom.storage_read(saved_rule.key))))
}

// Writes the choice. A refused write is dropped: the page in front of the
// person is right and the next one starts folded.
fn save(state: State) -> Effect(Msg) {
  use _ <- effect.from
  let _ = ffi_dom.storage_write(saved_rule.key, saved_rule.encode(state))
  Nil
}

// The line's button, projected through the one slot, under the press handler.
// The wrapper draws no box of its own.
fn view(_: Model) -> Element(Msg) {
  html.div([event.on_click(Pressed)], [component.default_slot([], [])])
}
