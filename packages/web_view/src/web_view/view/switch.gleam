//// The element that moves the browser to another page: the hidden
//// `<loom-switch>` both the session page and the home page draw as the last
//// child of their centre column.
////
//// It holds nothing the reader sees and carries an address in its `to`
//// attribute only after the daemon has minted a ticket for one
//// (`web_client/switch`, which checks the address again before it
//// navigates). The address is the daemon's and never the browser's or the
//// transcript's. It is drawn last so that no admitted path moves with it.
////
//// The module takes the address as a plain value, so the session page's
//// component and the home page's both use it without either importing the
//// other.

import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}

/// The `<loom-switch>` element for the address a ticket produced, or the
/// bare element when there is none yet. Either way it is one child, so the
/// children before it keep their places.
///
/// ## Examples
///
/// ```gleam
/// // switch.view(Some("/exchange?ticket=..."))
/// // switch.view(None)
/// ```
pub fn view(address: Option(String)) -> Element(message) {
  element.element(
    "loom-switch",
    [
      attribute.attribute("hidden", ""),
      ..case address {
        Some(address) -> [attribute.attribute("to", address)]
        None -> []
      }
    ],
    [],
  )
}

/// The session switcher's element (`web_client/switcher`), drawn after
/// `<loom-switch>` as the centre's last child on the pages that have a sidebar
/// of openable sessions: the operator's page and the home. It carries no
/// attribute and no text. In the browser it reads the sidebar's session buttons
/// as text when Command or Control and K is pressed, lists them in a popover,
/// and presses the chosen one's own button, so a switch from it is the
/// sidebar's switch and the daemon mints the ticket as it always does. It draws
/// nothing until the shortcut opens it, and holds no handler of the server's, so
/// no admitted path moves with it.
///
/// ## Examples
///
/// ```gleam
/// // switch.switcher()
/// ```
pub fn switcher() -> Element(message) {
  element.element("loom-switcher", [], [])
}
