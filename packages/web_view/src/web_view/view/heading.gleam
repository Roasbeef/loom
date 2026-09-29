//// The page's top bar: the brand, the session's location (the workspace
//// and the name), the connection's status, and the two figures the engine
//// estimates for the session. It is the first region both pages draw.
////
//// The bar is the heading the page always had, moved to a full-width row
//// above the three columns (docs/design-notes/web-design.md, section 2.1).
//// It draws values the component hands it and decides nothing about the
//// session. Every value it draws comes from the daemon's catalogue or from
//// the component's own words, never from the session's transcript: the name
//// is the label the owner gave the session, the workspace is the directory
//// the host validated when the session was created, the status is the
//// component's, and the context and cost figures are the shared record's own
//// estimates as `session_view` words them. Each is drawn as a text node, or
//// as a `title` attribute that Lustre escapes and the browser never runs.
//// Transcript text must never reach this region, and no attribute here may
//// be built from it.
////
//// The ended page's notice is the bar's last child, so a page with no
//// session says why without moving any region after it. The stylesheet
//// wraps it onto a row of its own beneath the figures.
////
//// The heading takes plain values rather than the component's `Label` and
//// `Status`, because `web_view/component` imports this module to lay the
//// page out, and a module the component imports cannot import the
//// component back.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html

/// The page's top bar: the brand, the workspace and name that locate the
/// session, the connection's status, and the context and cost figures.
///
/// The name is the catalogue's label, or the session's identity shortened
/// to its first eight characters when it has none; the whole identity is
/// the heading's `title`. The workspace is drawn as its last path segment,
/// with the whole path in a `title`. Both are text nodes and attribute
/// values that Lustre escapes. The catalogue's fields are written by the
/// owner and the host, never by the session's agent, and a `title` is
/// inert, so neither needs the stricter handling transcript text gets.
///
/// `name` and `workspace` are the catalogue label's two fields, or `None`
/// when the host could not read the label; `status` is the connection's
/// status as the page words it. `context` and `cost` are the two estimates
/// the terminal's footer shows (`ctx ~41%` and `est $0.04`), already worded.
/// The cost is the session's running total across strands, and the bar's
/// label says so.
///
/// ## Examples
///
/// ```gleam
/// // heading.view("0192ab34cd", Some("docs"), Some("/src/loom"), "connected", "ctx ~41%", "est $0.04", element.none())
/// ```
pub fn view(
  session_id session_id: String,
  name name: Option(String),
  workspace workspace: Option(String),
  status status: String,
  context context: String,
  cost cost: String,
  notice notice: Element(message),
) -> Element(message) {
  html.header(
    [attribute.class("session-head"), attribute.attribute("slot", "bar")],
    [
      html.span([attribute.class("brand")], [html.text("Loom")]),
      workspace_element(workspace),
      html.h1([attribute.title(session_id)], [
        html.text(session_name(session_id, name)),
      ]),
      html.p([attribute.class("status"), attribute.role("status")], [
        html.text(status),
      ]),
      html.span([attribute.class("figures")], [
        html.span([attribute.class("figure")], [html.text(context)]),
        html.span(
          [
            attribute.class("figure"),
            attribute.title("Estimated cost of the session, across strands"),
          ],
          [html.text("session " <> cost)],
        ),
      ]),
      notice,
    ],
  )
}

/// A session with no name, or none the host could read, is named by its
/// identity's first eight characters. The whole identity is in the
/// heading's `title`, so the shortening loses nothing a reader can need. The
/// breadcrumb names the session the same way.
///
/// ## Examples
///
/// ```gleam
/// assert heading.session_name("0192ab34cd", None) == "Session 0192ab34"
/// assert heading.session_name("0192ab34cd", Some("docs")) == "docs"
/// ```
pub fn session_name(session_id: String, name: Option(String)) -> String {
  case name {
    Some("") | None -> "Session " <> string.slice(session_id, 0, 8)
    Some(name) -> name
  }
}

// The workspace's last path segment, or nothing when it is unknown. The
// bar keeps the same children either way, so the status line keeps its
// place in the tree.
fn workspace_element(workspace: Option(String)) -> Element(message) {
  case workspace {
    Some("") | None -> element.none()
    Some(workspace) ->
      html.span([attribute.class("workspace"), attribute.title(workspace)], [
        html.text(basename(workspace)),
      ])
  }
}

fn basename(path: String) -> String {
  string.split(path, "/")
  |> list.filter(fn(segment) { segment != "" })
  |> list.last
  |> result.unwrap(path)
}
