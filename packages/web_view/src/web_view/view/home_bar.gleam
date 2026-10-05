//// The home page's top bar: the brand, the page's name, who the page is
//// for and the most it may do, and the connection's status. The admin page
//// (protocol-change/065, the fifth pull request) draws the same bar under its
//// own name.
////
//// It is the bar a session's page draws (`view/heading`) with the home's
//// facts in place of a session's: there is no workspace, no session name and
//// no figure to show, because the home is bound to none. The classes are the
//// bar's own, so the stylesheet lays it out as it does a session's, and the
//// status is the same pill, coloured by the same `Tone`, so the two pages
//// read as one product. The principal is written in the bar's sans face, with
//// the ceiling as a quiet pill beside it; nothing on this bar is monospaced,
//// since it holds no figure. The notice a page that ended draws is the last
//// child the bar had before the owner's control, so the regions after it keep
//// their place whether or not the page ended. The owner's home draws one more
//// child after it, the button that opens the admin page, and every other page
//// draws an empty node in its place; the button's path is the one the home's
//// socket admits for it (`home.admin_path`).
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
import lustre/event
import web_view/view/heading.{type Tone}

/// The bar for a home page or an admin page. `title` is the page's name, `name`
/// is the principal's display name, `ceiling` the fixed word for what the page
/// may do (`operator` or `read-only`), `status` the connection's word with the
/// `tone` that colours it, `notice` the ended page's notice or `element.none()`,
/// and `trailing` the owner's control after it or `element.none()`.
///
/// ## Examples
///
/// ```gleam
/// // home_bar.view("Home", "Alice", "operator", "connected", heading.Live, element.none(), element.none())
/// ```
pub fn view(
  title title: String,
  name name: String,
  ceiling ceiling: String,
  status status: String,
  tone tone: Tone,
  notice notice: Element(message),
  trailing trailing: Element(message),
) -> Element(message) {
  html.header(
    [attribute.class("session-head"), attribute.attribute("slot", "bar")],
    [
      html.span([attribute.class("brand")], [html.text("Loom")]),
      html.h1([], [html.text(title)]),
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
      html.p(
        [
          attribute.class("status"),
          attribute.class("pill"),
          attribute.class(heading.tone_class(tone)),
          attribute.role("status"),
        ],
        [html.text(status)],
      ),
      notice,
      trailing,
    ],
  )
}

/// The owner's "Admin" button, which sends `press` (protocol-change/065, the
/// fifth pull request). It is the bar's last child, so the paths of the bar's
/// other children are the same whether or not the page draws it.
///
/// ## Examples
///
/// ```gleam
/// // home_bar.admin(AdminRequested)
/// ```
pub fn admin(press: message) -> Element(message) {
  html.button(
    [
      attribute.type_("button"),
      attribute.class("home-admin"),
      attribute.title("Open the admin page: people, invitations and roles"),
      event.on_click(press),
    ],
    [html.text("Admin")],
  )
}
