//// `<loom-switch to="/ui/sessions/...">`: the element that moves the browser
//// to another session's page.
////
//// A page belongs to one session by its key, cookie and nonce, so opening
//// another session is a navigation to a new page (protocol-change/051, the
//// addendum on switching sessions). The server component cannot navigate the
//// browser, and Loom's page has no script that hears an event the server
//// emits (`docs/lustre.md`), so the operator's page draws this element and
//// writes its `to` attribute when the daemon has minted a ticket for the
//// session the operator chose. The attribute is the whole interface: the
//// element reads it, asks `switch_rule.target` whether it is exactly a ticket
//// exchange for a canonical session identity, and if so moves the browser
//// there. A value the rule refuses, an empty attribute and a removed one all
//// do nothing.
////
//// The element has no shadow content, renders nothing, takes no focus and
//// listens for no event. It sends the server nothing: the navigation is a
//// same-origin request the browser makes, whose answer is a new page. The
//// ticket is single use and lives 60 seconds, so a value the page left in the
//// attribute after the navigation is spent.

import gleam/result
import lustre
import lustre/component
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import web_client/internal/ffi_dom
import web_client/switch_rule

/// The element's tag.
pub const name = "loom-switch"

/// Everything the element can be told.
pub type Msg {
  /// The server wrote an address that is a ticket exchange, and the browser
  /// is to move there.
  Addressed(address: String)
}

/// Registers the element with the browser.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(Nil) = switch.register()
/// ```
pub fn register() -> Result(Nil, lustre.Error) {
  lustre.component(init, update, view, [
    component.on_attribute_change("to", to),
  ])
  |> lustre.register(name)
}

// The attribute decoded totally: an address the rule accepts is a message, and
// anything else is none.
fn to(value: String) -> Result(Msg, Nil) {
  switch_rule.target(value) |> result.map(Addressed)
}

fn init(_: Nil) -> #(Nil, Effect(Msg)) {
  #(Nil, effect.none())
}

// The one message navigates. The model holds nothing, because the address is
// already in the attribute and the page it names replaces this one.
fn update(model: Nil, message: Msg) -> #(Nil, Effect(Msg)) {
  case message {
    Addressed(address:) -> #(model, navigate(address))
  }
}

fn navigate(address: String) -> Effect(Msg) {
  use _ <- effect.from
  ffi_dom.assign_location(address)
}

fn view(_: Nil) -> Element(Msg) {
  element.none()
}
