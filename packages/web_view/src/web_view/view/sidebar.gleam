//// The session sidebar: the principal's sessions, grouped by workspace and
//// newest first, on the operator's page only.
////
//// The sidebar draws a list the daemon's catalogue supplied
//// (`web_view/sessions`) and decides nothing. A page is bound to one session
//// by its key, so opening another is a navigation to a new page
//// (protocol-change/051, the addendum on switching sessions), and the row of a
//// session that can be opened is a button whose one handler sends the
//// message its caller gave, naming that row's session. A row is a button only
//// where pressing it can work: a session that a process runs and that is not
//// the one on screen. The session on screen and a saved session are text, so
//// the sidebar never offers a press the daemon would refuse or that would do
//// nothing. The session named by a button's message is the catalogue's
//// identity, drawn when the tree was, and never a value the browser sends.
////
//// The sidebar is the second child of the page's frame (`view/shell`),
//// between the top bar and the centre column, in the frame's `left` slot.
//// `component.sidebar_path` names its path, and the paths `component.older_path`
//// and `component.strip_path` name are those of regions after it, so it keeps
//// its place as `element.none()` when it is not drawn.
////
//// Each workspace is a section with its own label, which the stylesheet draws
//// as a small eyebrow above the group and separates from the next group by a
//// hairline. The list's own heading, "Sessions", is in the page for
//// assistive technology and is not drawn.
////
//// Every name is drawn as a text node, and a workspace's whole path as a
//// `title` attribute that Lustre escapes. The catalogue's fields are written
//// by the owner and the host and never by a session's agent, but nothing here
//// is built from transcript text either way. The session on screen is marked
//// by `aria-current` and a class, and a session with no name is named by its
//// identity's first eight characters, as the heading names it. The classes
//// are complete literals, so Tailwind finds them.
////
//// The home page draws the same column through `home` (protocol-change/065):
//// a "Home" entry above the groups, marked as the page on screen, and every
//// row text. `Rows` is how the two differ: a row is a button that sends the
//// caller's message, or text, and the column, the groups and the row's words
//// are written once.
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
import lustre/event
import web_view/sessions.{type Entry, type Group, Live, Saved}

/// The sidebar for `groups`, with the session named `current` marked, and
/// `open` the message a press of another live session's row sends, given that
/// session's identity.
///
/// With no group it is `element.none()`, so a page whose daemon listed
/// nothing, or could not, draws no empty column. The result is memoized on
/// the groups and the identity, so a page that re-read an unchanged list
/// diffs nothing. `open` is not part of the memo's key, so a caller passes
/// the same function every time, as a constructor is.
///
/// ## Examples
///
/// ```gleam
/// // sidebar.view(component.session_groups(model), component.session_id(model), Opening)
/// ```
pub fn view(
  groups: List(Group),
  current: String,
  open: fn(String) -> message,
) -> Element(message) {
  use <- element.memo([element.ref(groups), element.ref(current)])
  column(groups, [], current, Pressable(open))
}

/// The sidebar the home page draws (protocol-change/065): the same groups, with
/// a "Home" entry above them marked as the page on screen, and every row
/// text. No row names a session as current and none carries a handler, so
/// the sidebar adds no path a browser frame could name; the home's rows open
/// nothing until a later change gives them a press.
///
/// With no group it is `element.none()`, as `view` is.
///
/// ## Examples
///
/// ```gleam
/// // sidebar.home(home.groups(model))
/// ```
pub fn home(groups: List(Group)) -> Element(message) {
  use <- element.memo([element.ref(groups)])
  column(
    groups,
    [
      html.p(
        [
          attribute.class("sidebar-home"),
          attribute.attribute("aria-current", "page"),
        ],
        [html.text("Home")],
      ),
    ],
    "",
    Plain,
  )
}

// What a row may be: a button that sends a message naming its session, or
// text.
type Rows(message) {
  Pressable(open: fn(String) -> message)
  Plain
}

// The column itself: its title, `lead` (what sits above the groups), and one
// section per group, or nothing when there is no group.
fn column(
  groups: List(Group),
  lead: List(Element(message)),
  current: String,
  rows: Rows(message),
) -> Element(message) {
  case groups {
    [] -> element.none()
    [_, ..] ->
      html.aside(
        [
          attribute.class("sidebar"),
          attribute.aria_label("Sessions"),
          attribute.attribute("slot", "left"),
        ],
        [
          html.h2([attribute.class("sidebar-title")], [html.text("Sessions")]),
          ..list.append(lead, list.map(groups, group(_, current, rows)))
        ],
      )
  }
}

fn group(
  group: Group,
  current: String,
  rows: Rows(message),
) -> Element(message) {
  html.section([attribute.class("workspace-group")], [
    html.h3([attribute.class("workspace"), attribute.title(group.workspace)], [
      html.text(basename(group.workspace)),
      html.span([attribute.class("group-count")], [
        html.text(int.to_string(list.length(group.entries))),
      ]),
    ]),
    html.ul(
      [attribute.class("sessions")],
      list.map(group.entries, entry(_, current, rows)),
    ),
  ])
}

// One row. The session on screen is marked and is text. Another session that
// a process runs is a button, since a page for it can be opened; a saved
// session is text, since the daemon would refuse a ticket for it and a page
// opened for it would have nothing to show.
fn entry(
  entry: Entry,
  current: String,
  rows: Rows(message),
) -> Element(message) {
  let residency = case entry.residency {
    Live -> #("live", "●", "resident")
    Saved -> #("saved", "○", "saved")
  }
  let words = [
    html.span([attribute.class("session-name")], [
      html.text(sessions.label(entry)),
    ]),
    html.span([attribute.class("residency"), attribute.class(residency.0)], [
      html.span([attribute.class("glyph"), attribute.aria_hidden(True)], [
        html.text(residency.1),
      ]),
      html.text(residency.2),
    ]),
  ]
  case entry.id == current, entry.residency, rows {
    True, _, _ ->
      html.li(
        [
          attribute.class("session"),
          attribute.class("current"),
          attribute.attribute("aria-current", "true"),
        ],
        words,
      )
    False, Live, Pressable(open) ->
      html.li([attribute.class("session")], [
        html.button(
          [
            attribute.type_("button"),
            attribute.class("session-open"),
            attribute.title("Open this session"),
            event.on_click(open(entry.id)),
          ],
          words,
        ),
      ])
    False, Live, Plain | False, Saved, _ ->
      html.li([attribute.class("session")], words)
  }
}

fn basename(path: String) -> String {
  string.split(path, "/")
  |> list.filter(fn(segment) { segment != "" })
  |> list.last
  |> result.unwrap(path)
}
