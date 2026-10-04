//// The Session tab of the strand panel: the session's goal, its live jobs,
//// the attached viewers and its estimated cost, drawn as a key and value list
//// on both pages.
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
//// and a page passes `None` where it does not show the row.
////
//// Schedules are not a row: the shared record keeps a schedule listing only as
//// transcript lines the page does not draw, so there is nothing to show.
////
//// The pane is drawn whether or not the Session tab shows (`view/panel`), and
//// always has its heading and the cost row, so its place in the panel never
//// moves. Below the list it has two more children: the owner's invitation
//// control (`view/share`), or an empty node on a page that has none, and the
//// operator's session controls (`view/controls`), or an empty node.
////
//// Job lines, which carry a command excerpt, viewer names and the goal's
//// objective, are session and principal text: each is drawn as a text node,
//// never as an attribute, a class or a key, and every class is a literal. The rows carry no handler; the invitation control's are its own.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import session_view/session_summary.{
  type Jobs, type Viewer, type Viewers, Another, Live, Unread, You,
}

/// The Session pane: the goal, the jobs, the viewers where the page shows them,
/// the estimated cost, and, below them, the invitation control where the page
/// has one.
///
/// `goal` is the terminal's goal row as its words (`goal_view.row`), empty when
/// no goal is pinned or none was read. `cost` is the session's running total
/// worded as the top bar words it. The list of rows is memoized on all four, so
/// a page whose rows did not change diffs nothing. `share` is the invitation
/// control (`web_view/view/share`), which only an owner's page draws and which
/// is `element.none()` everywhere else. It is the pane's third child, after the
/// title and the list, and it stays there, so the path of its handlers
/// (`component.invite_path`) does not depend on what the rows hold. `controls`
/// is the operator's goal buttons and Fork form (`view/controls.session`), or
/// `element.none()` on an observer's page. It is the pane's fourth child,
/// after the invitation control and not before it, so that adding it moved no
/// path the socket admits.
///
/// ## Examples
///
/// ```gleam
/// // session_tab.view([], "est $0.12", component.jobs(model), Some(component.viewers(model)), element.none(), element.none())
/// ```
pub fn view(
  goal: List(String),
  cost: String,
  jobs: Jobs,
  viewers: Option(Viewers),
  share: Element(message),
  controls: Element(message),
) -> Element(message) {
  html.section(
    [
      attribute.class("pane"),
      attribute.class("pane-session"),
      attribute.aria_label("Session"),
    ],
    [
      html.h2([attribute.class("panel-title")], [html.text("Session")]),
      rows(goal, cost, jobs, viewers),
      share,
      controls,
    ],
  )
}

// The key and value list, memoized on what it is drawn from.
fn rows(
  goal: List(String),
  cost: String,
  jobs: Jobs,
  viewers: Option(Viewers),
) -> Element(message) {
  use <- element.memo([
    element.ref(goal),
    element.ref(cost),
    element.ref(jobs),
    element.ref(viewers),
  ])
  html.dl(
    [attribute.class("session-list")],
    list.flatten([
      goal_row(goal),
      jobs_row(jobs),
      viewers_row(viewers),
      [term("Est. cost"), value([html.p([], [html.text(cost)])])],
    ]),
  )
}

// The goal row: the terminal's words for a pinned goal, or that there is none.
fn goal_row(goal: List(String)) -> List(Element(message)) {
  case goal {
    [] -> [
      term("Goal"),
      value([html.p([attribute.class("session-quiet")], [html.text("none")])]),
    ]
    lines -> [
      term("Goal"),
      value(list.map(lines, fn(line) { html.p([], [html.text(line)]) })),
    ]
  }
}

// The jobs row: the count and the daemon's board, or that none was read.
fn jobs_row(jobs: Jobs) -> List(Element(message)) {
  case jobs {
    Unread -> [
      term("Jobs"),
      value([
        html.p([attribute.class("session-quiet")], [html.text("not read yet")]),
      ]),
    ]
    Live(total: 0, ..) -> [
      term("Jobs"),
      value([
        html.p([], [html.text("none live")]),
        html.p([attribute.class("session-quiet")], [
          html.text("at last refresh"),
        ]),
      ]),
    ]
    Live(total:, rows:, omitted:) -> [
      term("Jobs"),
      value([
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
      ]),
    ]
  }
}

// The viewers row, or nothing for a page that does not show them.
fn viewers_row(viewers: Option(Viewers)) -> List(Element(message)) {
  case viewers {
    None -> []
    Some(viewers) -> [
      term("Viewers"),
      value([
        html.p([], [html.text(int.to_string(viewers.total) <> " attached")]),
        html.ul(
          [attribute.class("session-viewers")],
          list.map(viewers.rows, viewer),
        ),
        more(viewers.total - list.length(viewers.rows), " more not shown"),
      ]),
    ]
  }
}

fn viewer(viewer: Viewer) -> Element(message) {
  html.li([], [
    html.text(viewer.name),
    html.span([attribute.class("session-quiet")], [
      html.text(
        " · "
        <> viewer.role
        <> case viewer.whose {
          You -> " · you"
          Another -> ""
        },
      ),
    ]),
  ])
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

fn term(label: String) -> Element(message) {
  html.dt([attribute.class("session-term")], [html.text(label)])
}

fn value(children: List(Element(message))) -> Element(message) {
  html.dd([attribute.class("session-value")], children)
}
