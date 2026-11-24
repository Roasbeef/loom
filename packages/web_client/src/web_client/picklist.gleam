//// `<loom-picklist>`: the keyboard of the new-session composer's folder list,
//// with no round trip.
////
//// The server draws the Code chip's list inside this element, a search field and
//// a column of rows (`web_view/view/new_session`), and the element is on the page
//// exactly while the list is open. It does three things that depend only on the
//// browser: it puts the focus in the search field when the list opens, so the
//// way to a folder is to type and press Enter; it moves the focus down and up the
//// column with the arrow keys (`picklist_rule.after_key`); and it closes the list
//// on Escape by pressing the list's own scrim, the full-page button the server
//// drew behind it, so the close is the ordinary click the server already
//// answers.
////
//// The element draws a slot and nothing else, as `<loom-popover>` does, and keeps
//// no state but its one document listener. Keys are heard in the capture phase on
//// the document, because Escape must be decided before the shell's own Escape
//// (back to `main`) runs, and a consumed key is stopped and cancelled. The arrows
//// act only when the focus is already inside the list. The element sends the
//// server nothing and reads no attribute from it, and every row it moves between
//// is a button or field the server drew.

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
import web_client/picklist_rule

/// The element's tag.
pub const name = "loom-picklist"

// The items the keyboard moves between, in page order: the search field, then
// each row that is a button. A row that cannot be chosen is not a button.
const items = ".search-field, button.opt"

// The button behind the list that closes it, inside the chips' row.
const scrim = ".pop-scrim"

/// What the element holds: the document's key listener while it is connected.
pub type Model {
  Model(listener: Option(Listener))
}

/// Everything the element can be told.
pub type Msg {
  /// The element joined the page.
  Connected

  /// The element left the page.
  Disconnected

  /// The document's listener is in place.
  Listening(listener: Listener)
}

/// Registers the element with the browser.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(Nil) = picklist.register()
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
/// assert picklist.init_model().listener == option.None
/// ```
pub fn init_model() -> Model {
  Model(listener: None)
}

/// Applies one message.
///
/// ## Examples
///
/// ```gleam
/// assert picklist.update(picklist.init_model(), picklist.Disconnected).0
///   == picklist.init_model()
/// ```
pub fn update(model: Model, message: Msg) -> #(Model, Effect(Msg)) {
  case message {
    // One listener per connection: moving the element stops the old one before
    // it starts another, and the field takes the focus once it is painted.
    Connected -> #(model, effect.batch([stop(model.listener), listen()]))

    // `listen` registers after the paint, so this can arrive after a later
    // `Connected`; the listener the model still holds is stopped as the new one
    // is kept. A disconnect inside that one paint leaves a listener whose keys
    // reach a detached element, which finds no items and does nothing.
    Listening(listener:) -> #(
      Model(listener: Some(listener)),
      stop(model.listener),
    )
    Disconnected -> #(Model(listener: None), stop(model.listener))
  }
}

/// Focuses the search field once the list is painted and starts listening for keys
/// on the document, reporting the listener back as `Listening` so it can be
/// removed.
fn listen() -> Effect(Msg) {
  use dispatch, root <- effect.after_paint
  let host = ffi_dom.host(ffi_dom.as_element(root))

  // The list opens with the cursor in the field, so a person types at once.
  case ffi_dom.query_selector(host, ".search-field") {
    Ok(field) -> ffi_dom.focus(field)
    Error(Nil) -> Nil
  }

  let key =
    ffi_dom.add_capture_listener(ffi_dom.get_document(), "keydown", fn(event) {
      keyed(host, event)
    })
  dispatch(Listening(key))
}

/// Decides one key at once, since stopping an event cannot wait for a message. The
/// column is read from the page at the key, so it is the rows as they are now, not
/// as they were when the list opened.
fn keyed(host: ffi_dom.Element, event: Dynamic) -> Nil {
  // A key with no name is not one of ours.
  case decode.run(event, decode.at(["key"], decode.string)) {
    Error(_) -> Nil
    Ok(key) -> {
      let column = ffi_dom.query_selector_all(host, items)
      let move =
        picklist_rule.after_key(
          key,
          position_of(host, column, event),
          list.length(column),
        )

      // The rule's verdict is carried out: an arrow moves the focus, Escape closes
      // the list, and either spends the key.
      case move {
        picklist_rule.Ignore -> Nil
        picklist_rule.Focus(index:) -> {
          consume(event)
          focus_at(column, index)
        }
        picklist_rule.Close -> {
          consume(event)
          close(host)
        }
      }
    }
  }
}

/// The index of the item the event's target is, or `-1` when the target is not an
/// item of the list.
fn position_of(
  host: ffi_dom.Element,
  column: List(ffi_dom.Element),
  event: Dynamic,
) -> Int {
  case ffi_dom.composed_path(event) {
    [target, ..] ->
      case ffi_dom.contains(host, target) {
        True -> index_of(column, target, 0)
        False -> -1
      }
    [] -> -1
  }
}

/// The index of `target` in the column from `at` on, or `-1` when it is not there.
fn index_of(
  column: List(ffi_dom.Element),
  target: ffi_dom.Element,
  at: Int,
) -> Int {
  case column {
    [] -> -1
    [item, ..rest] ->
      case ffi_dom.same(item, target) {
        True -> at
        False -> index_of(rest, target, at + 1)
      }
  }
}

fn focus_at(column: List(ffi_dom.Element), index: Int) -> Nil {
  case list.drop(column, index) {
    [item, ..] -> ffi_dom.focus(item)
    [] -> Nil
  }
}

/// Presses the scrim, which the server answers as it answers any press outside the
/// list.
fn close(host: ffi_dom.Element) -> Nil {
  let pressed = {
    use chips <- result.try(ffi_dom.closest(host, ".place-chips"))
    ffi_dom.query_selector(chips, scrim)
  }

  // With no scrim to press there is nothing to close.
  case pressed {
    Ok(button) -> ffi_dom.click(button)
    Error(Nil) -> Nil
  }
}

// A key the list spent: nothing else on the page may act on it.
fn consume(event: Dynamic) -> Nil {
  ffi_dom.stop_propagation(event)
  ffi_dom.prevent_default(event)
}

/// Removes the document's key listener when one is held.
fn stop(listener: Option(Listener)) -> Effect(Msg) {
  // A model that never registered one has nothing to remove.
  case listener {
    None -> effect.none()
    Some(key) -> {
      use _ <- effect.from
      ffi_dom.remove_capture_listener(ffi_dom.get_document(), "keydown", key)
    }
  }
}

// The element draws a slot, so the server's list is its light DOM.
fn view(_: Model) -> Element(Msg) {
  component.default_slot([], [])
}
