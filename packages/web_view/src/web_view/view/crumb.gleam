//// The breadcrumb above the transcript while a strand other than `main` is in
//// focus: `session name ▸ strand name`, and an `All strands` link that puts
//// the page back on `main`.
////
//// It is the first child of the centre column, so the transcript's path
//// (`component.older_path`) is the same whether the breadcrumb is drawn or
//// the empty node the component puts in its place. The link is a control with
//// no handler: it carries `data-loom-focus` with the position of `main`'s
//// card, which is always zero, and `<loom-shell>` hears the click and clicks
//// that card (protocol-change/051, the addendum on the marker relay). Focusing
//// `main` is `All strands`, the one state the engine has for no strand in
//// focus (docs/design-notes/web-design.md, section 3.2).
////
//// The whole breadcrumb carries `data-loom-crumb`, which the shell's `Esc`
//// looks for so that a key does nothing when there is no strand to leave, and
//// a hint after the link says that `Esc` does the same. The key is the
//// shell's (protocol-change/051, the addendum on the keyboard); the hint is a
//// word and holds nothing. Both are fixed here.
////
//// The session's name is the catalogue's label, worded as the top bar words
//// it, and the strand's name is the roster's; each is drawn as a text node
//// and never as an attribute, a class or a key.

import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import web_view/view/strip

/// The name of the attribute that marks the breadcrumb. It is fixed here, and
/// `<loom-shell>` reads the same word.
pub const marker = "loom-crumb"

/// The breadcrumb for the page named `session` while the strand called
/// `strand` is in focus.
///
/// ## Examples
///
/// ```gleam
/// // crumb.view("web ui", "sub:tests")
/// ```
pub fn view(session: String, strand: String) -> Element(message) {
  html.nav(
    [
      attribute.class("crumb"),
      attribute.aria_label("Focused strand"),
      attribute.data(marker, ""),
    ],
    [
      html.span([attribute.class("crumb-session")], [html.text(session)]),
      html.span([attribute.class("crumb-sep"), attribute.aria_hidden(True)], [
        html.text("▸"),
      ]),
      html.b([attribute.class("crumb-strand")], [html.text(strand)]),
      html.span([attribute.class("crumb-spacer")], []),
      html.button(
        [
          attribute.type_("button"),
          attribute.class("crumb-all"),
          strip.focus_attribute(0),
        ],
        [html.text("All strands")],
      ),
      html.kbd([attribute.class("crumb-hint")], [html.text("Esc")]),
    ],
  )
}
