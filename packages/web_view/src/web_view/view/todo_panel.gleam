//// The todo panel: the active strand's task list and its reviewer band,
//// drawn in the dock on both pages.
////
//// The terminal pins the same two things above its composer
//// (`tui/todo_panel` and the reviewer band of `tui/layout`), and this
//// module draws them with the same semantics. The board is the strand's
//// newest, decoded by `core/todo_list.decode` and kept in the shared record
//// by `session_view/todo_board`; the band's lines are
//// `session_view/reviewer_status.lines`, which the terminal also draws. The
//// panel decides nothing about either. It answers the terminal's one
//// question at a glance, what the agent is doing now and how much is left:
//// the phase that holds the active task is drawn with every task in it, and
//// every other phase is folded into one summary row. A board whose tasks
//// are all closed is one row.
////
//// Each status has its own glyph as well as its own colour, so the panel
//// still reads without colour: `✓` done, `▸` active, `○` pending, `⊘`
//// blocked, `–` dropped. The glyph is hidden from assistive technology and
//// the status is spoken as a word instead.
////
//// Everything the panel draws is session text: the phase names, the task
//// texts, a blocked reason, a reviewer's strand name and its task brief.
//// Each is drawn as a text node, after the same hygiene the terminal
//// applies, and never as an attribute, a class or a key. Every class is a
//// complete literal, chosen from a closed type, so Tailwind finds it and no
//// session text can name one. The panel carries no handler.
////
//// The panel takes the board and the band's lines as plain values, because
//// `web_view/component` imports this module to lay the page out and a
//// module the component imports cannot import the component back. It draws
//// `element.none()` when there is neither a board nor a reviewer line, so
//// the dock's children keep their places.

import core/todo_list.{
  type Board, type Phase, type Status, type Task, Active, Blocked, Done, Dropped,
  Pending,
}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import session_view/text_hygiene

/// The panel: the board, when the strand has one, and the reviewer band's
/// lines, when a reviewer is running.
///
/// The board and the lines are memoized together, so a render that changed
/// neither, such as one for a streaming answer, leaves the panel's subtree
/// alone. A board with no phases is no board, as in the terminal.
///
/// ## Examples
///
/// ```gleam
/// // todo_panel.view(Some(board), reviewer_status.lines(rows, "main"))
/// ```
pub fn view(board: Option(Board), reviewers: List(String)) -> Element(message) {
  use <- element.memo([element.ref(board), element.ref(reviewers)])
  let drawn = board_elements(board)

  case drawn, reviewers {
    [], [] -> element.none()
    _, _ ->
      html.section(
        [
          attribute.class("todo-panel"),
          attribute.aria_label("Plan and reviewers"),
        ],
        list.append(drawn, band(reviewers)),
      )
  }
}

// The board's element, or nothing when there is no board or it has no phase
// to look at. A board whose tasks are all closed is one row.
fn board_elements(board: Option(Board)) -> List(Element(message)) {
  case board {
    None -> []
    Some(board) -> {
      let #(closed, total) = todo_list.count(board)

      case todo_list.focus(board), closed == total {
        None, _ -> []
        Some(_), True -> [finished(board, total)]
        Some(phase), False -> [open(board, phase, closed, total)]
      }
    }
  }
}

// --- an open board -------------------------------------------------------------

// The header, the focused phase's tasks in order, and the folded rest. The
// tasks are one list in the phase's order with the active one marked, so the
// panel scrolls inside its capped height rather than windowing around it.
fn open(
  board: Board,
  phase: Phase,
  closed: Int,
  total: Int,
) -> Element(message) {
  html.div([attribute.class("todo-board")], [
    header(phase, closed, total),
    html.ul([attribute.class("todo-tasks")], list.map(phase.tasks, task_item)),
    others(board, phase),
  ])
}

fn header(phase: Phase, closed: Int, total: Int) -> Element(message) {
  let #(phase_closed, phase_total) = todo_list.tally(phase.tasks)

  html.p([attribute.class("todo-head")], [
    html.span([attribute.class("todo-label")], [html.text("TODO")]),
    html.span([attribute.class("todo-phase")], [html.text(clean(phase.name))]),
    html.span([attribute.class("todo-quiet")], [
      html.text(count(phase_closed, phase_total)),
    ]),
    html.span([attribute.class("todo-total")], [
      html.text(count(closed, total) <> " done"),
    ]),
  ])
}

// One task: the status glyph, the status as a word for a screen reader, the
// text, and a blocked task's reason after it.
fn task_item(task: Task) -> Element(message) {
  let #(class, glyph) = mark(task.status)
  let reason = case task.status {
    Blocked(reason: Some(reason)) -> [
      html.span([attribute.class("todo-quiet")], [
        html.text(" · " <> clean(reason)),
      ]),
    ]
    Blocked(reason: None) | Active | Done | Dropped | Pending -> []
  }

  html.li(
    [attribute.class("todo-task"), attribute.class(class)],
    list.flatten([
      [
        html.span([attribute.class("todo-glyph"), attribute.aria_hidden(True)], [
          html.text(glyph),
        ]),
        html.span([attribute.class("todo-status")], [
          html.text(todo_list.status_name(task.status) <> ": "),
        ]),
        html.span([attribute.class("todo-text")], [html.text(clean(task.text))]),
      ],
      reason,
    ]),
  )
}

// A status's class and glyph, the terminal's table. The class is a literal
// from this closed set, never derived from the status's name.
fn mark(status: Status) -> #(String, String) {
  case status {
    Done -> #("todo-done", "✓")
    Dropped -> #("todo-dropped", "–")
    Active -> #("todo-active", "▸")
    Pending -> #("todo-pending", "○")
    Blocked(..) -> #("todo-blocked", "⊘")
  }
}

// Every phase but the focused one, in order, on one row: a finished phase is
// a check, anything else its closed count, so the row reads as the road
// behind and ahead of the phase being worked. A board of one phase has no
// such row.
fn others(board: Board, focus: Phase) -> Element(message) {
  let parts =
    board.phases
    |> list.filter(fn(phase) { phase.name != focus.name })
    |> list.map(fn(phase) {
      let #(closed, total) = todo_list.tally(phase.tasks)
      clean(phase.name)
      <> case closed == total {
        True -> " ✓"
        False -> " " <> count(closed, total)
      }
    })

  case parts {
    [] -> element.none()
    [_, ..] ->
      html.p([attribute.class("todo-others")], [
        html.text(string.join(parts, " · ")),
      ])
  }
}

// --- a finished board ----------------------------------------------------------

fn finished(board: Board, total: Int) -> Element(message) {
  let phases = list.length(board.phases)
  let detail =
    "all "
    <> int.to_string(total)
    <> plural(total, " task", " tasks")
    <> " closed"
    <> case phases > 1 {
      True -> " across " <> int.to_string(phases) <> " phases"
      False -> ""
    }

  html.div([attribute.class("todo-board")], [
    html.p([attribute.class("todo-head")], [
      html.span([attribute.class("todo-label")], [html.text("TODO")]),
      html.span([attribute.class("todo-done")], [html.text("✓")]),
      html.span([attribute.class("todo-quiet")], [html.text(detail)]),
    ]),
  ])
}

// --- the reviewer band ---------------------------------------------------------

// The band is the terminal's lines as they are: two per reviewer, where the
// second, the task brief, is indented, and a last line counting the rest.
// The indent is kept as whitespace the stylesheet preserves, so the page
// reads as the terminal does and this module parses nothing back out of a
// line. The lines come from session text already cleaned by
// `reviewer_status.lines`, and are drawn as text nodes.
fn band(lines: List(String)) -> List(Element(message)) {
  case lines {
    [] -> []
    [_, ..] -> [
      html.div(
        [attribute.class("todo-reviewers")],
        list.map(lines, fn(line) { html.p([], [html.text(line)]) }),
      ),
    ]
  }
}

// --- helpers -------------------------------------------------------------------

fn count(closed: Int, total: Int) -> String {
  int.to_string(closed) <> "/" <> int.to_string(total)
}

fn plural(count: Int, one: String, many: String) -> String {
  case count {
    1 -> one
    _ -> many
  }
}

fn clean(text: String) -> String {
  text_hygiene.single_line(text)
}
