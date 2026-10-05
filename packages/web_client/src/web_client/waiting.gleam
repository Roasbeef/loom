//// `<loom-waiting><p>...</p></loom-waiting>`: what a page shows while it has
//// no socket, and what it shows once it has had none for five seconds.
////
//// The shell's first document holds only the server component and a fixed
//// paragraph inside it. Lustre's client runtime attaches the component's
//// shadow root when the first tree arrives, and a shadow root with no slot
//// hides its host's light content, so the paragraph is on screen exactly
//// while the page has no session. A page whose socket the daemon refuses, or
//// whose tab lost its nonce, therefore sat on one grey sentence at the top
//// left of an empty window, with nothing to press.
////
//// This element wraps that paragraph. For the first five seconds it projects
//// the paragraph through its slot, which is what a browser without scripts
//// and a page still loading show. After five it draws the ended document's
//// shape instead (the brand, a headline, the advice, and a copy box for
//// `loom ui`), from words fixed here, with the same classes the daemon's own
//// ended documents use. A page that connects hides all of it with the rest of
//// the host's light content, so the timer costs a connected page nothing and
//// the element needs no check of whether the socket opened.
////
//// It takes no attribute and no content from the server beyond the paragraph
//// it projects, listens for no event and sends the server nothing.

import lustre
import lustre/attribute
import lustre/component
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import web_client/internal/ffi_dom

/// The element's tag.
pub const name = "loom-waiting"

// How long a page waits for its socket before it says more than the
// paragraph does, in milliseconds.
const patience = 5000

/// Where the wait stands.
pub type Phase {
  /// The paragraph is shown.
  Fresh

  /// Five seconds have passed with no session drawn over the element, so the
  /// document is shown.
  Stalled
}

/// Everything the element can be told.
pub type Msg {
  /// The element joined the page and starts waiting.
  Connected

  /// The wait's time ran out.
  Waited
}

/// Registers the element with the browser.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(Nil) = waiting.register()
/// ```
pub fn register() -> Result(Nil, lustre.Error) {
  lustre.component(init, update, view, [component.on_connect(Connected)])
  |> lustre.register(name)
}

fn init(_: Nil) -> #(Phase, Effect(Msg)) {
  #(Fresh, effect.none())
}

// Connecting starts the one timer; its fire is the only way to `Stalled`.
fn update(phase: Phase, message: Msg) -> #(Phase, Effect(Msg)) {
  case message {
    Connected -> #(phase, wait())
    Waited -> #(Stalled, effect.none())
  }
}

fn wait() -> Effect(Msg) {
  use dispatch <- effect.from
  ffi_dom.after(patience, fn() { dispatch(Waited) })
}

fn view(phase: Phase) -> Element(Msg) {
  case phase {
    Fresh -> component.default_slot([], [])
    Stalled -> document()
  }
}

// The ended document's shape: the daemon's `ended_document` in page.gleam
// draws the same classes and the same copy box, so one rule of the stylesheet
// styles both.
fn document() -> Element(Msg) {
  html.main([attribute.class("ended-page")], [
    html.section([attribute.class("ended-document"), attribute.role("alert")], [
      html.p([attribute.class("ended-brand")], [html.text("Loom")]),
      html.p([attribute.class("ended-headline")], [
        html.text("This page is not connected to the daemon."),
      ]),
      html.p([attribute.class("ended-advice")], [
        html.text(
          "The daemon may still be starting, this page may have ended, or "
          <> "this tab may have lost its key for the page. Reload it.",
        ),
      ]),
      html.p([attribute.class("ended-advice")], [
        html.text(
          "If it stays like this, run this in a terminal for a fresh link.",
        ),
      ]),
      element.element(
        "loom-copy",
        [
          attribute.attribute("subject", "link"),
          attribute.attribute("text", "loom ui"),
        ],
        [html.code([attribute.class("ended-command")], [html.text("loom ui")])],
      ),
    ]),
  ])
}
