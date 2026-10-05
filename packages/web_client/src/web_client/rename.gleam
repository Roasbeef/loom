//// `<loom-rename>`: the rename field, opened holding the session's current
//// name.
////
//// The server draws the field inside this element, and draws the session's
//// name as a text node in the form's lead, in an element marked
//// `data-loom-name`, inside a container marked `data-loom-renames`. A name is
//// never an attribute (protocol-change/051), so the server cannot write it as
//// the field's `value`; this element reads the text node the page already
//// holds and writes it into the field in the browser, once, when the form
//// appears. The server learns nothing: the form still sends whatever the owner
//// leaves in the field as one submit, decoded as before.
////
//// It takes no attribute and draws nothing of its own: its shadow root holds
//// only the default slot, so the field is the server's own child and the
//// element stays out of the form's handler paths. The form is replaced, and
//// this element with it, after every successful rename, so the next form opens
//// on the new name. `web_client/rename_rule` decides whether and what to copy.

import gleam/result
import lustre
import lustre/component
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import web_client/internal/ffi_dom
import web_client/rename_rule

/// The element's tag.
pub const name = "loom-rename"

/// Registers the element with the browser.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(Nil) = rename.register()
/// ```
pub fn register() -> Result(Nil, lustre.Error) {
  lustre.component(init, update, view, [])
  |> lustre.register(name)
}

// The element is told nothing: it acts once, as it connects.
fn init(_: Nil) -> #(Nil, Effect(Nil)) {
  #(Nil, filling())
}

fn update(model: Nil, _: Nil) -> #(Nil, Effect(Nil)) {
  #(model, effect.none())
}

fn view(_: Nil) -> Element(Nil) {
  component.default_slot([], [])
}

// Copies the name's text node into the field. It runs after the first paint,
// when the server's children are in place, and finds the name in the nearest
// container marked for it: the form on the home, the Session pane's region on a
// session page. A page without the marked name, or a field already holding text,
// is left as the server drew it.
fn filling() -> Effect(Nil) {
  use _, root <- effect.after_paint
  let filled = {
    let host = ffi_dom.host(ffi_dom.as_element(root))
    use scope <- result.try(ffi_dom.closest(host, "[data-loom-renames]"))
    use named <- result.try(ffi_dom.query_selector(scope, "[data-loom-name]"))
    use field <- result.try(ffi_dom.query_selector(host, "input"))
    use text <- result.map(rename_rule.copy(
      ffi_dom.text_content(named),
      ffi_dom.value(field),
    ))
    ffi_dom.set_value(field, text)
    ffi_dom.focus(field)
  }
  result.unwrap(filled, or: Nil)
}
