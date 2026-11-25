//// `<loom-picklist>`: the keyboard of the new-session composer's folder list,
//// with no round trip.
////
//// The server draws the Code chip's list inside this element, a search field and
//// a column of rows (`web_view/view/new_session`), and the element is on the page
//// exactly while the list is open. It does four things that depend only on the
//// browser: it puts the focus in the search field when the list opens, so the
//// way to a folder is to type and press Enter; it moves the focus down and up the
//// column with the arrow keys (`picklist_rule.after_key`); it closes the list on
//// Escape by pressing the list's own scrim, the full-page button the server drew
//// behind it, so the close is the ordinary click the server already answers; and
//// it puts the focus back in the search field when the list returns from the
//// folder picker, whose field is a new element.
////
//// The element draws a slot and nothing else, as `<loom-popover>` does. Keys are
//// heard in the capture phase on the document, because Escape must be decided
//// before the shell's own Escape (back to `main`) runs, and a consumed key is
//// stopped and cancelled. A key that belongs to an input method's composition is
//// left alone, since Escape cancels one. The arrows act only when the focus is
//// already inside the list. A mutation observer on the element's text notices a
//// search field that is not the one last focused and focuses it. The element sends
//// the server nothing and reads no attribute from it, and every row it moves
//// between is a button or field the server drew.

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

/// What the element holds while it is connected: the document's key listener, the
/// observer that notices a new search field, and the field it last focused.
pub type Model {
  Model(
    listener: Option(Listener),
    observer: Option(ffi_dom.Observer),
    field: Option(ffi_dom.Element),
  )
}

/// Everything the element can be told.
pub type Msg {
  /// The element joined the page.
  Connected

  /// The element left the page.
  Disconnected

  /// The document's listener and the observer are in place.
  Listening(listener: Listener, observer: ffi_dom.Observer)

  /// The list's content changed.
  Changed

  /// The search field was focused.
  Focused(field: ffi_dom.Element)
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
  Model(listener: None, observer: None, field: None)
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
    Connected -> #(model, effect.batch([stop(model), listen()]))

    // `listen` registers after the paint, so this can arrive after a later
    // `Connected`; what the model still holds is stopped as the new is kept. A
    // disconnect inside that one paint leaves a listener whose keys reach a
    // detached element, which finds no items and does nothing.
    Listening(listener:, observer:) -> #(
      Model(..model, listener: Some(listener), observer: Some(observer)),
      stop(model),
    )
    Disconnected -> #(init_model(), stop(model))
    Changed -> #(model, refocus(model.field))
    Focused(field:) -> #(Model(..model, field: Some(field)), effect.none())
  }
}

/// Focuses the search field once the list is painted, starts listening for keys on
/// the document and watching the list for a new field, and reports both back as
/// `Listening` so they can be removed.
fn listen() -> Effect(Msg) {
  use dispatch, root <- effect.after_paint
  let host = ffi_dom.host(ffi_dom.as_element(root))

  // The list opens with the cursor in the field, so a person types at once.
  case ffi_dom.query_selector(host, ".search-field") {
    Ok(field) -> {
      ffi_dom.focus(field)
      dispatch(Focused(field))
    }
    Error(Nil) -> Nil
  }

  let key =
    ffi_dom.add_capture_listener(ffi_dom.get_document(), "keydown", fn(event) {
      keyed(host, event)
    })
  let observer = ffi_dom.mutation_observer(fn() { dispatch(Changed) })
  ffi_dom.observe_text(observer, host)
  dispatch(Listening(key, observer))
}

/// Focuses the search field when it is not the one that was last focused, which is
/// what the list shows again after the folder picker was open. A field the person
/// has already been in is left alone, so a press elsewhere is not undone.
fn refocus(last: Option(ffi_dom.Element)) -> Effect(Msg) {
  use dispatch, root <- effect.after_paint
  let host = ffi_dom.host(ffi_dom.as_element(root))

  // The field is looked for in the list as it is now.
  case ffi_dom.query_selector(host, ".search-field"), last {
    Ok(field), Some(held) ->
      case ffi_dom.same(field, held) {
        True -> Nil
        False -> {
          ffi_dom.focus(field)
          dispatch(Focused(field))
        }
      }
    Ok(field), None -> {
      ffi_dom.focus(field)
      dispatch(Focused(field))
    }
    Error(Nil), _ -> Nil
  }
}

/// Decides one key at once, since stopping an event cannot wait for a message. The
/// column is read from the page at the key, so it is the rows as they are now, not
/// as they were when the list opened.
fn keyed(host: ffi_dom.Element, event: Dynamic) -> Nil {
  // A key with no name is not one of ours, and a key that belongs to an input
  // method's composition (Escape cancels one) is the method's.
  let composing =
    decode.run(event, decode.at(["isComposing"], decode.bool))
    |> result.unwrap(False)

  // The key is acted on only when it is a plain key with a name.
  case decode.run(event, decode.at(["key"], decode.string)), composing {
    Error(_), _ | _, True -> Nil
    Ok(key), False -> {
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

/// Focuses the item at an index of the column, and nothing for an index past it.
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

/// Removes the document's key listener and the observer when held.
fn stop(model: Model) -> Effect(Msg) {
  use _ <- effect.from

  // A model that never registered either has nothing to remove.
  case model.listener {
    Some(key) ->
      ffi_dom.remove_capture_listener(ffi_dom.get_document(), "keydown", key)
    None -> Nil
  }

  // Whatever was registered is removed, and nothing else is touched.
  case model.observer {
    Some(observer) -> ffi_dom.disconnect(observer)
    None -> Nil
  }
}

// The element draws a slot, so the server's list is its light DOM.
fn view(_: Model) -> Element(Msg) {
  component.default_slot([], [])
}
