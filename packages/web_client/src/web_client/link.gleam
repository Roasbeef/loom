//// `<loom-link>`: a link a model wrote, made clickable in the browser after
//// the browser has checked where it goes.
////
//// The server draws a Markdown link as this element with two text-only
//// children (`web_view/markdown_view`): the label in `<span class="ll-text">`
//// and the destination in `<span class="ll-url" hidden>`. An `href` is an
//// attribute, and session text is never an attribute (protocol-change/051),
//// so the server cannot write one. This element reads the destination from
//// its own child text, hands it to `web_client/link_rule`, and only when that
//// accepts it draws the link.
////
//// ## A real anchor, in the shadow root
////
//// The element draws `<a href target="_blank" rel="noopener noreferrer">`
//// around a slot that projects the server's label. The alternative was a
//// `role=link` span with a click and an Enter handler that calls
//// `window.open`. The anchor is smaller and does more: the browser supplies
//// focus, Enter, middle click, Control or Command click, "copy link address"
//// and the status-bar destination, and `rel` keeps the new tab from holding
//// a handle on the Loom page. The element listens for no event at all.
////
//// The `href` and the `title` are attributes on an element this component
//// itself drew, set from a value `link_rule` approved; that is the one place
//// session-derived text becomes an attribute, and it happens in the browser,
//// after validation, never in the server's markup (protocol-change/051, the
//// addendum on clickable links). The `title` is the real destination, so a
//// label that says one thing and a link that goes to another can be told
//// apart by hovering.
////
//// A destination the rule refuses draws only the slot: the label stays the
//// server's plain text, and the hidden destination stays hidden. The element
//// watches its own children, so a label or destination the server patches
//// later is read again.

import gleam/result
import lustre
import lustre/attribute
import lustre/component
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import web_client/internal/ffi_dom.{type Observer}
import web_client/link_rule

/// The element's tag.
pub const name = "loom-link"

/// What the element holds: the destination `link_rule` approved, if any; for
/// a destination it refused, the text to show after the label as a hint (empty
/// when there is none); and the observer that watches its children.
pub type Model {
  Model(
    destination: Result(String, Nil),
    refused: String,
    observer: Result(Observer, Nil),
  )
}

/// Everything the element can be told.
pub type Msg {
  /// The element joined the page.
  Connected

  /// The element left the page.
  Disconnected

  /// The observer is watching.
  Watching(observer: Observer)

  /// The children were read: the approved destination, or none, and the hint
  /// text for a refused one.
  Read(destination: Result(String, Nil), refused: String)
}

/// Registers the element with the browser.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(Nil) = link.register()
/// ```
pub fn register() -> Result(Nil, lustre.Error) {
  lustre.component(init, update, view, [
    component.on_connect(Connected),
    component.on_disconnect(Disconnected),
  ])
  |> lustre.register(name)
}

fn init(_: Nil) -> #(Model, Effect(Msg)) {
  #(
    Model(destination: Error(Nil), refused: "", observer: Error(Nil)),
    effect.none(),
  )
}

fn update(model: Model, message: Msg) -> #(Model, Effect(Msg)) {
  case message {
    Connected -> #(model, watch())
    Watching(observer:) -> #(
      Model(..model, observer: Ok(observer)),
      stop(model.observer),
    )
    Read(destination:, refused:) -> #(
      Model(..model, destination:, refused:),
      effect.none(),
    )
    Disconnected -> #(
      Model(..model, observer: Error(Nil)),
      stop(model.observer),
    )
  }
}

// Reads the destination now, after the paint that put the server's children
// in place, and again after every change to them.
fn watch() -> Effect(Msg) {
  use dispatch, root <- effect.after_paint
  let host = ffi_dom.host(ffi_dom.as_element(root))
  let observer = ffi_dom.mutation_observer(fn() { dispatch(read(host)) })

  ffi_dom.observe_text(observer, host)
  dispatch(read(host))
  dispatch(Watching(observer))
}

// What the element's `ll-url` and `ll-text` children say: the approved
// destination, or none, and for a refused one the hint to show after the
// label.
fn read(host: ffi_dom.Element) -> Msg {
  let text = fn(selector) {
    ffi_dom.query_selector(host, selector)
    |> result.map(ffi_dom.text_content)
    |> result.unwrap("")
  }
  let raw = text(".ll-url")

  case link_rule.destination(raw) {
    Ok(url) -> Read(destination: Ok(url), refused: "")
    Error(Nil) ->
      Read(
        destination: Error(Nil),
        refused: link_rule.hint(text(".ll-text"), raw),
      )
  }
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

// The slot until a destination is approved, followed by the refused
// destination as quiet text when there is one to show: a relative path such
// as `docs/README.md` is the most common link a model writes, and the reader
// should see where it pointed. With an approved destination, the anchor around
// the slot and a glyph that marks the link as leaving the page.
fn view(model: Model) -> Element(Msg) {
  case model.destination {
    Error(Nil) ->
      case model.refused {
        "" -> component.default_slot([], [])
        hint ->
          element.fragment([
            component.default_slot([], []),
            html.span([attribute.class("link-refused")], [
              html.text(" (" <> hint <> ")"),
            ]),
          ])
      }
    Ok(url) ->
      html.a(
        [
          attribute.class("link-anchor"),
          attribute.href(url),
          attribute.target("_blank"),
          attribute.rel("noopener noreferrer"),
          attribute.title(url),
        ],
        [
          component.default_slot([], []),
          html.span(
            [attribute.class("link-glyph"), attribute.aria_hidden(True)],
            [
              html.text("↗"),
            ],
          ),
        ],
      )
  }
}
