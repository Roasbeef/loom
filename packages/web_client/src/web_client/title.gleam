//// `<loom-title>`: sets the tab's title to the session's name, with the count
//// of strands that wait on the person in front of it.
////
//// The session page's document is fixed text, so its title can only say
//// `Loom` until a component has connected. The server draws this element as
//// the last child of the bar, hidden and empty. When it connects it reads the
//// bar's heading, the `h1` the session's name is drawn in, and the frame's
//// `needing` attribute, both of which are already in the page, and writes the
//// title `web_client/title_rule` words from them. It sends the server nothing
//// and takes nothing from it that the page does not already show.
////
//// The title follows the page: a mutation observer watches the heading's text
//// and the frame's `needing` attribute, so a renamed session or a strand that
//// starts waiting changes the tab without a reload. The observer is
//// disconnected when the element leaves the page. The name is text the
//// browser stores as it is; it is never assigned to markup or to an
//// attribute (protocol-change/051, the addendum on the session switcher).

import gleam/result
import lustre
import lustre/component
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import web_client/internal/ffi_dom.{type Observer}
import web_client/title_rule

/// The element's tag.
pub const name = "loom-title"

/// What the element holds: the observer that watches the page, once started.
pub type Model {
  Model(observer: Result(Observer, Nil))
}

/// Everything the element can be told.
pub type Msg {
  /// The element joined the page.
  Connected

  /// The element left the page.
  Disconnected

  /// The observer is watching.
  Watching(observer: Observer)
}

/// Registers the element with the browser.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(Nil) = title.register()
/// ```
pub fn register() -> Result(Nil, lustre.Error) {
  lustre.component(init, update, view, [
    component.on_connect(Connected),
    component.on_disconnect(Disconnected),
  ])
  |> lustre.register(name)
}

fn init(_: Nil) -> #(Model, Effect(Msg)) {
  #(Model(observer: Error(Nil)), effect.none())
}

// Connecting starts one observer, which also writes the first title. The
// observer is kept so leaving the page stops it.
fn update(model: Model, message: Msg) -> #(Model, Effect(Msg)) {
  case message {
    Connected -> #(model, watch())
    Watching(observer:) -> #(Model(observer: Ok(observer)), effect.none())
    Disconnected -> #(Model(observer: Error(Nil)), stop(model.observer))
  }
}

// Writes the title now and again after every change to the heading's text or
// the frame's count. The bar is drawn in the same tree as this element, so the
// pieces are looked up from the root the element is attached under, after the
// paint that put it there.
fn watch() -> Effect(Msg) {
  use dispatch, root <- effect.after_paint
  let page = ffi_dom.root_node(ffi_dom.host(ffi_dom.as_element(root)))
  let observer = ffi_dom.mutation_observer(fn() { write(page) })

  case ffi_dom.query_selector(page, ".session-head h1") {
    Ok(heading) -> ffi_dom.observe_text(observer, heading)
    Error(Nil) -> Nil
  }

  case ffi_dom.query_selector(page, "loom-shell") {
    Ok(frame) -> ffi_dom.observe_attribute(observer, frame, "needing")
    Error(Nil) -> Nil
  }

  write(page)
  dispatch(Watching(observer))
}

// The title from what the page shows. A page whose bar has no heading yet
// writes the product's name alone.
fn write(page: ffi_dom.Element) -> Nil {
  let name =
    ffi_dom.query_selector(page, ".session-head h1")
    |> result.map(ffi_dom.text_content)
    |> result.unwrap("")
  let needing =
    ffi_dom.query_selector(page, "loom-shell")
    |> result.try(ffi_dom.attribute(_, "needing"))
    |> result.map(title_rule.needing_from)
    |> result.unwrap(0)

  ffi_dom.set_title(title_rule.session(name, needing))
}

fn stop(observer: Result(Observer, Nil)) -> Effect(Msg) {
  case observer {
    Ok(observer) -> {
      use _ <- effect.from
      ffi_dom.disconnect(observer)
    }
    Error(Nil) -> effect.none()
  }
}

// The element draws nothing: it exists for what it does to the document.
fn view(_: Model) -> Element(Msg) {
  element.none()
}
