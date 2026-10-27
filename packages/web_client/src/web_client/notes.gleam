//// The notes reader's focus and scroll custody. The index stays mounted on
//// the server, while this empty element remembers where the reader entered.
//// All selectors are fixed or use numeric row marks assigned by the page.
//// Escape is heard only inside notes, before the shell's strand navigation.

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

/// The element's state contains only browser geometry and listener handles.
pub type Model {
  Model(
    /// The row the reader opened, as a numeric mark.
    row: Option(String),
    /// The pane's scroll position before opening the note.
    top: Float,
    /// The two listeners installed on the enclosing notes region.
    listeners: Option(#(Listener, Listener)),
  )
}

/// Messages carry no session text or authority.
pub type Msg {
  /// The element was attached.
  Connected

  /// The element was removed.
  Disconnected

  /// Listeners were attached to the notes region.
  Listening(click: Listener, key: Listener)

  /// A row click saved its browser position before the server patch.
  Entered(row: String, top: Float)

  /// The server opened or closed the reader.
  ModeChanged(mode: String)
}

/// Registers the notes navigation helper.
///
/// ## Examples
///
/// ```gleam
/// // let _ = notes.register()
/// ```
pub fn register() -> Result(Nil, lustre.Error) {
  lustre.component(init, update, view, [
    component.on_connect(Connected),
    component.on_disconnect(Disconnected),
    component.on_attribute_change("mode", fn(mode) { Ok(ModeChanged(mode)) }),
  ])
  |> lustre.register("loom-notes")
}

fn init(_: Nil) -> #(Model, Effect(Msg)) {
  #(Model(None, 0.0, None), effect.none())
}

/// Applies DOM listener registrations and mode switches to notes model.
fn update(model: Model, message: Msg) -> #(Model, Effect(Msg)) {
  case message {
    Connected -> #(model, effect.batch([stop(model.listeners), listen()]))
    Listening(click, key) -> #(
      Model(..model, listeners: Some(#(click, key))),
      stop(model.listeners),
    )
    Disconnected -> #(Model(..model, listeners: None), stop(model.listeners))
    Entered(row, top) -> #(Model(..model, row: Some(row), top:), effect.none())
    ModeChanged(mode) -> #(model, restore(model, mode))
  }
}

fn region(host: ffi_dom.Element) -> Result(ffi_dom.Element, Nil) {
  ffi_dom.closest(host, ".strand-notes")
}

/// Attaches capture event listeners for note item click and keyboard navigation.
fn listen() -> Effect(Msg) {
  use dispatch, root <- effect.after_paint
  let host = ffi_dom.host(ffi_dom.as_element(root))
  let _ = {
    use notes <- result.map(region(host))
    let click =
      ffi_dom.add_capture_listener(notes, "click", fn(event) {
        let _ = {
          use row <- result.try(
            ffi_dom.composed_path(event)
            |> list.find_map(fn(node) {
              ffi_dom.attribute(node, "data-note-row")
            }),
          )
          use pane <- result.map(ffi_dom.closest(notes, "aside.panel"))
          dispatch(Entered(row, ffi_dom.scroll_top(pane)))
        }
        Nil
      })
    let key =
      ffi_dom.add_capture_listener(notes, "keydown", fn(event) {
        escaped(notes, event)
      })
    dispatch(Listening(click, key))
  }
  Nil
}

/// Handles Escape keypress in notes panel by triggering back navigation.
fn escaped(notes: ffi_dom.Element, event: Dynamic) -> Nil {
  let key = decode.run(event, decode.at(["key"], decode.string))
  let editor =
    ffi_dom.composed_path(event)
    |> list.any(fn(node) {
      case ffi_dom.tag_name(node) {
        Ok("input") | Ok("textarea") | Ok("select") -> True
        _ -> result.unwrap(ffi_dom.is_content_editable(node), False)
      }
    })

  // Propagate Escape to back button when event did not originate in an editor.
  case key, editor, ffi_dom.query_selector(notes, ".notes-back") {
    Ok("Escape"), False, Ok(back) -> {
      ffi_dom.stop_propagation(event)
      ffi_dom.prevent_default(event)
      ffi_dom.click(back)
    }
    _, _, _ -> Nil
  }
}

/// Restores scroll position and focuses active note item after mode switch.
fn restore(model: Model, mode: String) -> Effect(Msg) {
  use _, root <- effect.after_paint
  let host = ffi_dom.host(ffi_dom.as_element(root))
  let _ = {
    use notes <- result.try(region(host))

    // Focus back button in detail mode or restore row button focus in index mode.
    case mode, model.row {
      "detail", _ ->
        result.map(ffi_dom.query_selector(notes, ".notes-back"), ffi_dom.focus)
      "index", Some(row) -> {
        use button <- result.try(ffi_dom.query_selector(
          notes,
          "[data-note-row=\"" <> row <> "\"]",
        ))
        use pane <- result.map(ffi_dom.closest(notes, "aside.panel"))
        ffi_dom.focus(button)
        ffi_dom.set_scroll_top(pane, model.top)
      }
      _, _ -> Ok(Nil)
    }
  }
  Nil
}

/// Removes capture event listeners from notes panel DOM elements.
fn stop(listeners: Option(#(Listener, Listener))) -> Effect(Msg) {
  // Remove registered capture listeners when present.
  case listeners {
    None -> effect.none()
    Some(#(click, key)) -> {
      use _, root <- effect.after_paint
      let _ = {
        use notes <- result.map(region(ffi_dom.host(ffi_dom.as_element(root))))
        ffi_dom.remove_capture_listener(notes, "click", click)
        ffi_dom.remove_capture_listener(notes, "keydown", key)
      }
      Nil
    }
  }
}

fn view(_: Model) -> Element(Msg) {
  element.none()
}
