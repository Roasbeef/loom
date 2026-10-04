//// The home page's top bar: the brand, the page's name, who the page is
//// for and the most it may do, and the connection's status.
////
//// It is the bar a session's page draws (`view/heading`) with the home's
//// facts in place of a session's: there is no workspace, no session name and
//// no figure to show, because the home is bound to none. The classes are the
//// bar's own, so the stylesheet lays it out as it does a session's, and the
//// notice a page that ended draws is its last child, so the regions after it
//// keep their place whether or not the page ended.
////
//// Every value is the daemon's or the component's own words: the principal's
//// display name is a catalogue field the owner chose, drawn as a text node,
//// and the ceiling and status are fixed words. Nothing a session's agent
//// wrote can reach this region, and it holds no handler.
////
//// The module takes plain strings, so it needs nothing from `web_view/home`,
//// which imports it.

import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html

/// The bar for a home page. `name` is the principal's display name, `ceiling`
/// the fixed word for what the page may do (`operator` or `read-only`),
/// `status` the connection's word, and `notice` the ended page's notice or
/// `element.none()`.
///
/// ## Examples
///
/// ```gleam
/// // home_bar.view("Alice", "operator", "connected", element.none())
/// ```
pub fn view(
  name name: String,
  ceiling ceiling: String,
  status status: String,
  notice notice: Element(message),
) -> Element(message) {
  html.header(
    [attribute.class("session-head"), attribute.attribute("slot", "bar")],
    [
      html.span([attribute.class("brand")], [html.text("Loom")]),
      html.h1([], [html.text("Home")]),
      html.span([attribute.class("home-who")], [
        html.text(name),
        html.span(
          [
            attribute.class("home-badge"),
            attribute.title("The most this page may do"),
          ],
          [html.text(ceiling)],
        ),
      ]),
      html.p([attribute.class("status"), attribute.role("status")], [
        html.text(status),
      ]),
      notice,
    ],
  )
}
