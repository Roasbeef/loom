//// The session sidebar: the principal's sessions, grouped by workspace and
//// newest first, on the operator's page only.
////
//// The sidebar draws a list the daemon's catalogue supplied
//// (`web_view/sessions`) and decides nothing. It is read-only: no row is a
//// link, a button or a handler, because a page is bound to one session by its
//// key and opening another needs a link the page cannot make
//// (protocol-change/051, the addendum on the session sidebar). It is the
//// second child of the page's frame (`view/shell`), between the top bar and
//// the centre column, and the left column of the stylesheet's grid. It has
//// no handler, so the paths `component.older_path` and
//// `component.strip_path` name are those of regions after it, and they count
//// on it keeping its place as `element.none()` when it is not drawn.
////
//// Every name is drawn as a text node, and a workspace's whole path as a
//// `title` attribute that Lustre escapes. The catalogue's fields are written
//// by the owner and the host and never by a session's agent, but nothing here
//// is built from transcript text either way. The session on screen is marked
//// by `aria-current` and a class, and a session with no name is named by its
//// identity's first eight characters, as the heading names it. The classes
//// are complete literals, so Tailwind finds them.
////
//// The module takes `sessions.Group`s and the current identity, and imports
//// nothing from `web_view/component`, which imports it.

import gleam/int
import gleam/list
import gleam/result
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import web_view/sessions.{type Entry, type Group, Live, Saved}

/// The sidebar for `groups`, with the session named `current` marked.
///
/// With no group it is `element.none()`, so a page whose daemon listed
/// nothing, or could not, draws no empty column. The result is memoized on
/// the groups and the identity, so a page that re-read an unchanged list
/// diffs nothing.
///
/// ## Examples
///
/// ```gleam
/// // sidebar.view(component.session_groups(model), component.session_id(model))
/// ```
pub fn view(groups: List(Group), current: String) -> Element(message) {
  use <- element.memo([element.ref(groups), element.ref(current)])
  case groups {
    [] -> element.none()
    [_, ..] ->
      html.aside(
        [attribute.class("sidebar"), attribute.aria_label("Sessions")],
        [
          html.h2([attribute.class("sidebar-title")], [html.text("Sessions")]),
          ..list.map(groups, group(_, current))
        ],
      )
  }
}

fn group(group: Group, current: String) -> Element(message) {
  html.section([attribute.class("workspace-group")], [
    html.h3([attribute.class("workspace"), attribute.title(group.workspace)], [
      html.text(basename(group.workspace)),
      html.span([attribute.class("group-count")], [
        html.text(int.to_string(list.length(group.entries))),
      ]),
    ]),
    html.ul(
      [attribute.class("sessions")],
      list.map(group.entries, entry(_, current)),
    ),
  ])
}

fn entry(entry: Entry, current: String) -> Element(message) {
  let residency = case entry.residency {
    Live -> #("live", "●", "resident")
    Saved -> #("saved", "○", "saved")
  }
  let attributes = case entry.id == current {
    True -> [
      attribute.class("session"),
      attribute.class("current"),
      attribute.attribute("aria-current", "true"),
    ]
    False -> [attribute.class("session")]
  }
  html.li(attributes, [
    html.span([attribute.class("session-name")], [html.text(name(entry))]),
    html.span([attribute.class("residency"), attribute.class(residency.0)], [
      html.span([attribute.class("glyph"), attribute.aria_hidden(True)], [
        html.text(residency.1),
      ]),
      html.text(residency.2),
    ]),
  ])
}

// A session with no name is named by its identity's first eight characters.
fn name(entry: Entry) -> String {
  case entry.name {
    "" -> "Session " <> string.slice(entry.id, 0, 8)
    named -> named
  }
}

fn basename(path: String) -> String {
  string.split(path, "/")
  |> list.filter(fn(segment) { segment != "" })
  |> list.last
  |> result.unwrap(path)
}
