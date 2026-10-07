//// The Session tab of the strand panel: the session's workspace, the attached
//// viewers, its goal and live jobs and its estimated cost, drawn on both
//// pages as groups that each lead with a heading in the panel's eyebrow style.
//// A viewer is a principal, not an attachment: one person's three pages are
//// one line that counts them.
////
//// The groups read in this order: Session (the name with its Rename control,
//// then the workspace), People (the viewers and the invitation buttons), Goal
//// (the pinned goal and its buttons), Fork, Jobs and Cost. The pane's
//// children are not in that order and cannot be. The invitation control, the
//// operator's controls and the rename control are the pane's third, fourth
//// and fifth children, at the paths the page socket admits events beneath
//// (`component.invite_path`, `component.session_controls_path`,
//// `component.rename_path`), and a path is a position, so moving a child
//// would move what the socket admits. The reading order is the stylesheet's:
//// `.pane-session` is a column whose children carry an `order`, and the rows
//// wrapper and the controls section are `display:contents`, so each group
//// and control is placed on its own. This module draws the groups and the
//// stylesheet places them; a test pins each group's class and the pane's
//// child count. `reading-flow:flex-visual` on the pane makes keyboard focus
//// follow the visual order in browsers that support it.
////
//// The rows are `session_view`'s wherever it words them
//// (`session_summary`, `goal_view.row`), so the terminal can draw the same
//// words. The goal row is the terminal's own line for a pinned goal, which
//// the component reads from `goal_view`; the cost is the figure the top bar
//// shows, the session's running total across strands. Jobs are a read-only
//// `live_jobs` read the page makes on its tick and are the daemon's board at
//// its last refresh, which the line says. Viewers are the presence rows of the
//// capture. The web design note draws viewers on an operator's page only, on
//// the reasoning that an observer link is handed to someone who may only
//// watch, and who else is watching is not theirs to learn (the same ruling
//// that keeps the session list off an observer's page). This module keeps that
//// policy out of the summary: the caller hands in `Some(viewers)` or `None`,
//// and a page passes `None` where it does not show the group.
////
//// Schedules are not a row: the shared record keeps a schedule listing only as
//// transcript lines the page does not draw, so there is nothing to show. The
//// session's creation time is not a row either: the page holds no such
//// reading, and drawing one would take a catalogue field the wire does not
//// carry.
////
//// The pane is drawn whether or not the Session tab shows (`view/panel`), and
//// always has its heading and the Goal, Jobs and Cost groups, so its place in
//// the panel never moves. After the rows it has three more children: the
//// owner's invitation control (`view/share`), or an empty node on a page that
//// has none, the operator's session controls (`view/controls`), or an empty
//// node, the owner's rename control (`view/rename`), or an empty node, and the
//// operator's list of remembered permissions (`view/remembered`), or an empty
//// node.
////
//// Job lines, which carry a command excerpt, viewer names and the goal's
//// objective, are session and principal text: each is drawn as a text node,
//// never as an attribute, a class or a key, and every class is a literal. The
//// workspace is the catalogue's validated directory, drawn as a text node and
//// also as a `title`, as the top bar does. The rows carry no handler; the
//// controls' are their own.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import session_view/session_summary.{
  type Jobs, type Viewer, type Viewers, Another, Live, Unread, You,
}

/// The Session pane: the workspace, the viewers where the page shows them,
/// the goal, the jobs and the estimated cost, and, after them, the invitation
/// control where the page has one.
///
/// `goal` is the terminal's goal row as its words (`goal_view.row`), empty when
/// no goal is pinned or none was read. `cost` is the session's running total
/// as a figure (`$0.12`), without the word `est`, which the group's note says.
/// `workspace` is the working directory the catalogue gives the session, or
/// `None` when the label was not read, which draws no workspace group. The
/// rows are memoized on all five, so a page whose rows did not change diffs
/// nothing. `share` is the invitation control (`web_view/view/share`), which
/// only an owner's page draws and which is `element.none()` everywhere else.
/// It is the pane's third child, after the title and the rows, and it stays
/// there, so the path of its handlers (`component.invite_path`) does not
/// depend on what the rows hold. `controls` is the operator's goal buttons and
/// Fork form (`view/controls.session`), or `element.none()` on an observer's
/// page. It is the pane's fourth child, after the invitation control and not
/// before it, so that adding it moved no path the socket admits. `rename` is
/// the owner's rename control (`view/rename`), or `element.none()` on any
/// other page, and is the pane's fifth child for the same reason. `remembered`
/// is the operator's list of what "Allow for this session" kept
/// (`view/remembered`), or `element.none()` on an observer's page, and is the
/// pane's sixth and last child, beneath `component.remembered_path`.
///
/// ## Examples
///
/// ```gleam
/// // session_tab.view([], "$0.12", component.jobs(model), Some(component.viewers(model)), Some("/src/loom"), element.none(), element.none(), element.none(), element.none())
/// ```
pub fn view(
  goal: List(String),
  cost: String,
  jobs: Jobs,
  viewers: Option(Viewers),
  workspace: Option(String),
  share: Element(message),
  controls: Element(message),
  rename: Element(message),
  remembered: Element(message),
) -> Element(message) {
  html.section(
    [
      attribute.class("pane"),
      attribute.class("pane-session"),
      attribute.aria_label("Session"),
    ],
    [
      html.h2([attribute.class("panel-title")], [html.text("Session")]),
      rows(goal, cost, jobs, viewers, workspace),
      share,
      controls,
      rename,
      remembered,
    ],
  )
}

// The groups, memoized on what they are drawn from. The wrapper is the pane's
// second child and the stylesheet makes it `display:contents`, so each group
// is placed in the pane's column by its own `order`.
fn rows(
  goal: List(String),
  cost: String,
  jobs: Jobs,
  viewers: Option(Viewers),
  workspace: Option(String),
) -> Element(message) {
  use <- element.memo([
    element.ref(goal),
    element.ref(cost),
    element.ref(jobs),
    element.ref(viewers),
    element.ref(workspace),
  ])
  html.div(
    [attribute.class("session-rows")],
    list.flatten([
      workspace_group(workspace),
      people_group(viewers),
      [
        group("goal", Some("Goal"), goal_rows(goal)),
        group("jobs", Some("Jobs"), jobs_rows(jobs)),
        group("cost", Some("Cost"), [
          cost_line(cost),
        ]),
      ],
    ]),
  )
}

// One group: an optional eyebrow heading and its rows. The class names the
// group, which is how the stylesheet places it. The Session group has no
// heading of its own, because the pane's title is its heading.
fn group(
  name: String,
  heading: Option(String),
  rows: List(Element(message)),
) -> Element(message) {
  html.div(
    [
      attribute.role("group"),
      attribute.class("session-group"),
      attribute.class("session-group-" <> name),
    ],
    case heading {
      Some(words) -> [
        html.h3([attribute.class("session-eyebrow")], [html.text(words)]),
        ..rows
      ]
      None -> rows
    },
  )
}

// The workspace of the Session group, or nothing when the label was not read.
// The name and its Rename control are the pane's last child, which the
// stylesheet draws first in the group.
fn workspace_group(workspace: Option(String)) -> List(Element(message)) {
  case workspace {
    None -> []
    Some(path) -> [
      group("workspace", None, [
        html.p([attribute.class("session-workspace"), attribute.title(path)], [
          html.text(path),
        ]),
      ]),
    ]
  }
}

// The People group: the viewers, or nothing for a page that does not show
// them. The invitation control, where there is one, follows it in the column.
fn people_group(viewers: Option(Viewers)) -> List(Element(message)) {
  case viewers {
    None -> []
    Some(viewers) -> [group("people", Some("People"), viewer_rows(viewers))]
  }
}

// The cost: the figure and the word that says it is an estimate. An unpriced
// session has no figure to qualify, so the dash stands alone.
fn cost_line(cost: String) -> Element(message) {
  case cost {
    "—" -> html.p([attribute.class("session-quiet")], [html.text(cost)])
    figure ->
      html.p([], [
        html.text(figure),
        html.span([attribute.class("session-quiet")], [html.text(" estimated")]),
      ])
  }
}

// The goal: the terminal's words for a pinned goal, or that there is none.
fn goal_rows(goal: List(String)) -> List(Element(message)) {
  case goal {
    [] -> [
      html.p([attribute.class("session-quiet")], [html.text("none")]),
    ]
    lines -> list.map(lines, fn(line) { html.p([], [html.text(line)]) })
  }
}

// The jobs: the count and the daemon's board, or that none was read.
fn jobs_rows(jobs: Jobs) -> List(Element(message)) {
  case jobs {
    Unread -> [
      html.p([attribute.class("session-quiet")], [html.text("not read yet")]),
    ]
    Live(total: 0, ..) -> [
      html.p([attribute.title("At the last refresh")], [html.text("none")]),
    ]
    Live(total:, rows:, omitted:) -> [
      html.p([], [
        html.text(int.to_string(total) <> " live"),
        html.span([attribute.class("session-quiet")], [
          html.text(" · at last refresh"),
        ]),
      ]),
      html.ul(
        [attribute.class("session-jobs")],
        list.map(rows, fn(row) { html.li([], [html.text(row)]) }),
      ),
      more(omitted, " more jobs not shown"),
    ]
  }
}

// The viewers: how many are attached and one line for each principal.
fn viewer_rows(viewers: Viewers) -> List(Element(message)) {
  [
    html.p([], [html.text(int.to_string(viewers.total) <> " attached")]),
    html.ul(
      [attribute.class("session-viewers")],
      list.map(viewers.rows, viewer),
    ),
    more(
      viewers.total - list.fold(viewers.rows, 0, fn(n, v) { n + v.pages }),
      " more not shown",
    ),
  ]
}

// One principal as `<name> · <role> · you`: the name, the role they hold in the
// session, how many tabs when more than one, and whether the page is theirs
// (`you`) or another person's (`viewing`). The role is one word in the terms
// the home uses. An owner who has a page open may operate it, so `owner` and
// `operator` are both `operator`, and only a principal whose every page is
// read-only is an `observer`. The engine's own terms for a grant's roles and
// attached pages never reach the line.
fn viewer(viewer: Viewer) -> Element(message) {
  html.li([], [
    html.text(viewer.name),
    html.span([attribute.class("session-quiet")], [
      html.text(
        " · "
        <> role_word(viewer.roles)
        <> case viewer.pages {
          1 -> ""
          pages -> " · " <> int.to_string(pages) <> " tabs"
        }
        <> case viewer.whose {
          You -> " · you"
          Another -> " · viewing"
        },
      ),
    ]),
  ])
}

fn role_word(roles: List(String)) -> String {
  case list.all(roles, fn(role) { role == "observer" }) {
    True -> "observer"
    False -> "operator"
  }
}

// The line that says rows were left out, or nothing.
fn more(left: Int, words: String) -> Element(message) {
  case left {
    0 -> element.none()
    _ ->
      html.p([attribute.class("session-quiet")], [
        html.text("+" <> int.to_string(left) <> words),
      ])
  }
}
