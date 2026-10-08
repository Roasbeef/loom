//// Explicit access to a result beyond the transcript's bounded preview.
////
//// The transcript carries an immutable result identity, never another copy of
//// its bytes. These same-origin links ask the daemon to authorize each read.
//// The viewer draws one escaped text window of the stored JSON record; the
//// download returns that complete record as an attachment.

import core/ids
import gleam/int
import lustre/attribute
import lustre/element
import lustre/element/html
import web_view/page

/// The byte stride of one requested result page.
pub const page_bytes = 16_000

/// Where a drawn step's first result page lives, relative to its session page.
///
/// ## Examples
///
/// ```gleam
/// // tool_result.address("session", ids.entry_id_to_string(result_id))
/// ```
pub fn address(session: String, ref: String) -> String {
  session <> "/result/" <> ref <> "/page/0"
}

/// The bounded lane's two explicit access controls.
///
/// ## Examples
///
/// ```gleam
/// // tool_result.links("session", result_id)
/// ```
pub fn links(session: String, id: ids.EntryId) -> element.Element(message) {
  let ref = ids.entry_id_to_string(id)
  html.div([attribute.class("tool-result-links")], [
    html.a(
      [
        attribute.href(address(session, ref)),
        attribute.target("_blank"),
        attribute.rel("noopener"),
      ],
      [html.text("View full result")],
    ),
    html.text(" · "),
    html.a([attribute.href(session <> "/result/" <> ref <> "/download")], [
      html.text("Download result"),
    ]),
  ])
}

/// Draws one result page with local navigation and a full-record download.
/// Every byte of result text is escaped through a text node.
///
/// ## Examples
///
/// ```gleam
/// // tool_result.document("{...}", 0, 2, 32000)
/// ```
pub fn document(text: String, index: Int, pages: Int, bytes: Int) -> String {
  let nav =
    html.nav([attribute.aria_label("Result pages")], [
      case index > 0 {
        True ->
          html.a([attribute.href(int.to_string(index - 1))], [
            html.text("Previous page"),
          ])
        False -> element.none()
      },
      html.text(
        " · Page "
        <> int.to_string(index + 1)
        <> " of "
        <> int.to_string(pages)
        <> " · ",
      ),
      case index + 1 < pages {
        True ->
          html.a([attribute.href(int.to_string(index + 1))], [
            html.text("Next page"),
          ])
        False -> element.none()
      },
      html.text(" · "),
      html.a([attribute.href("../download")], [
        html.text(
          "Download complete JSON (" <> int.to_string(bytes) <> " bytes)",
        ),
      ]),
    ])
  "<!doctype html>"
  <> element.to_string(
    html.html([attribute.lang("en")], [
      html.head([], [
        html.meta([attribute.charset("utf-8")]),
        html.meta([
          attribute.name("viewport"),
          attribute.content("width=device-width, initial-scale=1"),
        ]),
        html.title([], "Tool result · Loom"),
        html.link([
          attribute.rel("stylesheet"),
          attribute.href(page.asset_path(page.stylesheet_asset)),
        ]),
      ]),
      html.body([], [
        html.main([attribute.class("tool-result-page")], [
          html.h1([], [html.text("Tool result")]),
          html.p([], [
            html.text(
              "Complete stored result as JSON. This view loads one page at a time.",
            ),
          ]),
          nav,
          html.pre([attribute.class("tool-result-text")], [html.text(text)]),
          nav,
        ]),
      ]),
    ]),
  )
}
