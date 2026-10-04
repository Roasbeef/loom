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
