//// The Session rows a read or the presence roster supplies: the live jobs and
//// the attached viewers, drawn as a collapsed section on the pages.
////
//// The rows are `session_view/session_summary`'s, so the terminal can draw
//// the same words. Jobs are a read-only `live_jobs` read the page makes on its
//// tick and are the daemon's board at its last refresh, which the line says.
//// Viewers are the presence rows of the capture. The web design note draws
//// viewers on an operator's page only, on the reasoning that an observer link
//// is handed to someone who may only watch, and who else is watching is not
//// theirs to learn (the same ruling that keeps the session list off an
//// observer's page). This module keeps that policy out of the summary: the
//// caller hands in `Some(viewers)` or `None`, and a page passes `None`
//// where it does not show the row.
////
//// The tabbed right panel of the design note will hold these rows in its
//// Session tab with the goal, schedules and cost; until it exists the section
//// is a `<details>` the page draws below the transcript, and this module is
//// written to move as it is.
////
//// Job lines, which carry a command excerpt, and viewer names are session
//// and principal text: each is drawn as a text node, never as an attribute, a
//// class or a key, and every class is a literal. The view carries no
//// handler. It is `element.none()` when there is nothing to say, an observer's
//// page with no board read, so such a page draws no empty section.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import session_view/session_summary.{
  type Jobs, type Viewer, type Viewers, Another, Live, Unread, You,
}

/// The section for the jobs and, where the page shows them, the viewers.
///
/// It is memoized on both, so a page whose rows did not change diffs
/// nothing.
///
/// ## Examples
///
/// ```gleam
/// // session_tab.view(component.jobs(model), Some(component.viewers(model)))
/// ```
pub fn view(jobs: Jobs, viewers: Option(Viewers)) -> Element(message) {
  use <- element.memo([element.ref(jobs), element.ref(viewers)])
  case jobs, viewers {
    Unread, None -> element.none()
    _, _ ->
      html.details([attribute.class("session-rows")], [
        html.summary([attribute.class("session-rows-summary")], [
          html.text("Session"),
        ]),
        html.dl(
          [attribute.class("session-list")],
          list.append(jobs_row(jobs), viewers_row(viewers)),
        ),
      ])
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
