//// `<loom-reveal>`: scrolls the section it sits in into view once, when it
//// appears.
////
//// The admin page draws a claim, which the owner must copy and send, under the
//// form or the row that asked for it (`web_view/view/admin_claim`). That place
//// can be below the page's scroll position, and the claim is shown once, so a
//// claim the owner has to go looking for is a claim they may miss. The server
//// cannot scroll a browser, so it draws this empty element as the first child of
//// the claim's box, and when the element is connected it asks the browser to
//// show the box, by the least scrolling that shows all of it. A box already on
//// screen does not move.
////
//// The element takes no attribute, draws nothing and sends the server nothing.
//// It is connected once, when the box is inserted: a later read that leaves the
//// box in place patches nothing and so scrolls nothing, and the owner who has
//// scrolled away is not pulled back.

import gleam/result
import lustre
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import web_client/internal/ffi_dom

/// The element's tag.
pub const name = "loom-reveal"

/// Registers the element with the browser.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(Nil) = reveal.register()
/// ```
pub fn register() -> Result(Nil, lustre.Error) {
  lustre.component(init, update, view, [])
  |> lustre.register(name)
}

// The box is the nearest `section` around the element. The scroll runs after the
// first paint, when the box has its height, so "the least that shows all of it"
// is measured on the finished box.
fn init(_: Nil) -> #(Nil, Effect(Nil)) {
  #(Nil, {
    use _, root <- effect.after_paint
    let _ = {
      use box <- result.map(ffi_dom.closest(
        ffi_dom.host(ffi_dom.as_element(root)),
        "section",
      ))
      ffi_dom.scroll_into_view(box)
    }
    Nil
  })
}

// Nothing is sent to the element, so there is nothing to apply.
fn update(model: Nil, _: Nil) -> #(Nil, Effect(Nil)) {
  #(model, effect.none())
}

fn view(_: Nil) -> Element(Nil) {
  element.none()
}
