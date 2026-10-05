//// The home page's top bar: the brand, the page's name, who the page is
//// for, and the connection's status. The admin page (protocol-change/065, the
//// fifth pull request) draws the same bar under its own name.
////
//// It is the bar a session's page draws (`view/heading`) with the home's
//// facts in place of a session's: there is no workspace, no session name and
//// no figure to show, because the home is bound to none. The classes are the
//// bar's own, so the stylesheet lays it out as it does a session's, and the
//// status is the same pill, coloured by the same `Tone`, so the two pages
//// read as one product. Nothing on this bar is monospaced, since it holds no
//// figure.
////
//// The principal is the bar's third child, and `with` draws whatever element
//// the page gives it there. The admin page gives plain text (`view`). The home
//// gives `account`: the principal's name as a button inside a `<loom-popover>`,
//// which opens the account panel (the sign-ins, the bookmark and the device
//// link) that the home draws as the centre's third child. The panel is far from
//// the button in the tree, so the button carries the fixed mark
//// `data-popover="toggle"` and the element toggles the panel in the browser,
//// with no handler here and no state on the server. A home that may do all its
//// principal may says nothing beside the name; a read-only link (`loom ui
//// --observe`) draws the quiet pill `read-only link`, because that is the one
//// page whose limit is not the person's own.
////
//// The notice a page that ended draws is the last child the bar had before the
//// owner's control, so the regions after it keep their place whether or not
//// the page ended. The owner's home draws one more child after it, the button
//// that opens the admin page, and every other page draws an empty node in its
//// place; the button's path is the one the home's socket admits for it
//// (`home.admin_path`).
////
//// Every value is the daemon's or the component's own words: the principal's
//// display name is a catalogue field the owner chose, drawn as a text node,
//// and the pill and status are fixed words. Nothing a session's agent wrote
//// can reach this region, and it holds no handler of its own.
////
//// The module takes plain strings, so it needs nothing from `web_view/home`,
//// which imports it.

import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import web_view/view/heading.{type Tone}

/// The bar for the admin page: the principal's name as text, and the most the
/// page may do as a quiet pill beside it. `title` is the page's name, `name`
/// is the principal's display name, `ceiling` the fixed word for what the page
/// may do, `status` the connection's word with the `tone` that colours it,
/// `notice` the ended page's notice or `element.none()`, and `trailing` the
/// owner's control after it or `element.none()`. An empty `ceiling` draws no
/// pill.
///
/// ## Examples
///
/// ```gleam
/// // home_bar.view("Admin", "Alice", "operator", "connected", heading.Live, element.none(), element.none())
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
  let who =
    html.span([attribute.class("home-who")], [
      html.text(name),
      badge(ceiling, "The most this page may do"),
    ])
  with(title:, who:, status:, tone:, notice:, trailing:)
}

/// What the server asks of the account panel the name opens.
pub type Panel {
  /// Nothing: the person opens and closes it.
  Closed

  /// Open it now. The home asks while a device link is on show, so the link is
  /// on screen when it arrives; the person may still close it.
  Open
}

/// The principal's place in the home's bar: the display name as a button that
/// opens the account panel, wrapped in the `<loom-popover>` that toggles it in
/// the browser, and, for a read-only link, the pill that says so. `ceiling` is
/// the pill's words, and empty for a page that may do all the principal may,
/// which is the normal case and says nothing.
///
/// The button carries the fixed marks the element reads (`data-popover`), and
/// its `aria-expanded` is the element's to write after this draws it closed.
/// The name is the owner's chosen display name, so it is a text node.
///
/// ## Examples
///
/// ```gleam
/// // home_bar.account("Alice", "", home_bar.Closed)
/// ```
pub fn account(
  name: String,
  ceiling: String,
  panel: Panel,
) -> Element(message) {
  html.span([attribute.class("home-who")], [
    element.element(
      "loom-popover",
      [
        attribute.attribute("wanted", case panel {
          Closed -> "closed"
          Open -> "open"
        }),
      ],
      [
        html.button(
          [
            attribute.type_("button"),
            attribute.class("home-who-button"),
            attribute.attribute("data-popover", "toggle"),
            attribute.attribute("aria-haspopup", "true"),
            attribute.attribute("aria-expanded", "false"),
            attribute.title(
              "Your sign-ins, and the link to sign in another device",
            ),
          ],
          [
            html.text(name),
            html.span(
              [
                attribute.class("home-who-chevron"),
                attribute.aria_hidden(True),
              ],
              [html.text("▾")],
            ),
          ],
        ),
      ],
    ),
    badge(ceiling, "This link can only watch"),
  ])
}

/// The bar itself, around a `who` element: the brand, the page's name, the
/// principal, the connection's status, the ended page's notice and the owner's
/// control. The principal is always the third child, the status the fourth,
/// and the notice and the control the fifth and sixth, whichever page draws it.
///
/// ## Examples
///
/// ```gleam
/// // home_bar.with("Home", home_bar.account("Alice", "", home_bar.Closed), "connected", heading.Live, element.none(), element.none())
/// ```
pub fn with(
  title title: String,
  who who: Element(message),
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
      who,
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

// The quiet pill beside the name, or nothing for no words. The words are fixed
// by the page; the title says what they mean.
fn badge(words: String, title: String) -> Element(message) {
  case words {
    "" -> element.none()
    _ ->
      html.span([attribute.class("home-badge"), attribute.title(title)], [
        html.text(words),
      ])
  }
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
