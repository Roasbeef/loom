//// The words of the rail's Trace and Session tabs.
////
//// Strands is the agent row renderer's and Changes is the changes panel's;
//// these two tabs are text, and this module is where it is decided. Each is a
//// function of the model and a width that gives rows, so `tui/rail_view` only
//// has to scroll and paint them, and the keys can ask how many rows a tab has
//// without painting it.
////
//// Trace is the latest code-mode program of the strand on screen, from
//// `session_view/trace_view`: whether it is running or how it ended, the
//// opening lines of its source, its result, and its calls. It shows no
//// timing, because per-call timing is its own piece of work. Session is the
//// session's goal, jobs, viewers and cost, from the same rows the web view's
//// Session tab draws (`session_summary`, `goal_view.row`); the web view shows
//// viewers on an operator's page only, and the terminal is always one.
////
//// ## Flow
////
//// `rows` → `trace_rows` or `session_rows` → `fitted`
////
//// 1. `rows` is the rows of one tab at one width, nothing for the tabs
////    drawn elsewhere.
//// 2. `trace_rows` and `session_rows` build their rows as plain lines with a
////    tone each.
//// 3. `fitted` cuts every row to the width with an ellipsis, so a long
////    program line, a job's command or a viewer's name never wraps into the
////    next row.

import etui/geometry
import etui/span
import etui/style
import etui/text
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import session_view/goal_view
import session_view/session_summary
import session_view/trace_view
import session_view/transcript_lines
import tui/layout
import tui/model.{type Model}
import tui/rail
import tui/theme

/// The rows of a tab at a width. Strands and Changes are drawn elsewhere and
/// have none here.
///
/// ## Examples
///
/// ```gleam
/// assert rail_tabs.rows(model, rail.Strands, 44) == []
/// ```
pub fn rows(model: Model, tab: rail.Tab, width: Int) -> List(span.Line) {
  case tab {
    rail.Trace -> fitted(trace_rows(model), width)
    rail.Session -> fitted(session_rows(model), width)
    rail.Strands | rail.Changes -> []
  }
}

/// How far the tab on the rail can scroll: the rows it has beyond what its
/// content area shows. Zero for the tabs drawn elsewhere.
///
/// ## Examples
///
/// ```gleam
/// assert rail_tabs.scroll_limit(model) >= 0
/// ```
pub fn scroll_limit(model: Model) -> Int {
  let screen = geometry.rect_new(0, 0, model.view.width, model.view.height)
  let content = layout.rail_content_area(screen, model)
  let rows = rows(model, layout.rail_tab(model), content.size.width)
  int.max(0, list.length(rows) - content.size.height)
}

// How a row is drawn.
type Tone {
  Heading
  Plain
  Quiet
  Good
  Bad
  Live
}

type Row {
  Row(tone: Tone, text: String)
}

fn trace_rows(model: Model) -> List(Row) {
  let strand = model.shared.active_strand
  case trace_view.newest(model.shared.records, strand) {
    None -> [
      Row(Heading, "TRACE · latest program"),
      Row(Quiet, "No program yet on this strand."),
    ]
    Some(found) -> {
      let program = found.program
      list.flatten([
        [Row(Heading, "TRACE · latest program"), state_row(program.state)],
        [Row(Plain, ""), Row(Heading, "PROGRAM")],
        list.map(found.source, fn(line) { Row(Quiet, line) }),
        [Row(Plain, ""), Row(Heading, "RESULT")],
        case program.excerpt {
          Some(value) -> [Row(Plain, value)]
          None -> [Row(Quiet, "none yet")]
        },
        case program.calls {
          [] -> []
          rows -> [Row(Plain, ""), ..list.map(rows, call_row)]
        },
      ])
    }
  }
}

fn state_row(state: trace_view.State) -> Row {
  case state {
    trace_view.Running -> Row(Live, "◐ running · awaiting its result")
    trace_view.Completed -> Row(Good, "✓ completed")
    trace_view.Errored
    | trace_view.Rejected
    | trace_view.CompileFailed
    | trace_view.RunFailed
    | trace_view.Failed -> Row(Bad, "× " <> trace_view.state_title(state))
  }
}

// The call section's rows carry their glyph first, so the glyph says the
// colour: a failure is the danger colour, a settled call the success one.
fn call_row(line: String) -> Row {
  let tone = case
    string.starts_with(line, "CALLS ·"),
    string.starts_with(line, "× "),
    string.starts_with(line, "✓ ")
  {
    True, _, _ -> Heading
    False, True, _ -> Bad
    False, False, True -> Good
    False, False, False -> Plain
  }
  Row(tone, line)
}

fn session_rows(model: Model) -> List(Row) {
  let goal = case model.shared.goal {
    Some(board) ->
      case goal_view.row(board) {
        [] -> [Row(Quiet, "Goal    none pinned")]
        [first, ..rest] ->
          list.flatten([
            [Row(Plain, "Goal    " <> first)],
            list.map(rest, fn(line) { Row(Quiet, "        " <> line) }),
          ])
      }
    None -> [Row(Quiet, "Goal    none pinned")]
  }
  let jobs = case
    session_summary.jobs(model.shared.jobs, model.shared.active_strand)
  {
    session_summary.Unread -> [Row(Quiet, "Jobs    not read · /summary")]
    session_summary.Live(total:, rows:, omitted:) ->
      list.flatten([
        [Row(Plain, "Jobs    " <> int.to_string(total) <> " live")],
        list.map(rows, fn(line) { Row(Quiet, "  " <> line) }),
        case omitted {
          0 -> []
          n -> [Row(Quiet, "  … " <> int.to_string(n) <> " more")]
        },
      ])
  }
  let viewers = session_summary.viewers(model.shared.captured)
  let attached = case viewers.rows {
    [] -> [Row(Quiet, "Viewers none attached")]
    rows ->
      list.flatten([
        [Row(Plain, "Viewers " <> int.to_string(viewers.total))],
        list.map(rows, fn(viewer) {
          let whose = case viewer.whose {
            session_summary.You -> " · you"
            session_summary.Another -> ""
          }
          Row(
            Quiet,
            "  "
              <> viewer.name
              <> " · "
              <> string.join(viewer.roles, ", ")
              <> whose,
          )
        }),
      ])
  }
  list.flatten([
    [Row(Heading, "SESSION")],
    goal,
    jobs,
    attached,
    [
      Row(
        Plain,
        "Cost    est $" <> transcript_lines.money(model.shared.usage.cost.total),
      ),
    ],
  ])
}

// Each row cut to the width, one cell short so no text meets the edge, and
// drawn in its tone behind a one-cell margin.
fn fitted(rows: List(Row), width: Int) -> List(span.Line) {
  list.map(rows, fn(row) {
    let words = text.truncate(row.text, int.max(0, width - 2), "…")
    span.line_new([span.span_styled(" " <> words, style_of(row.tone))])
  })
}

fn style_of(tone: Tone) -> style.Style {
  case tone {
    Heading -> theme.quiet_text()
    Plain -> style.new(theme.paper, style.Default, style.none())
    Quiet -> theme.quiet_text()
    Good -> theme.success_text()
    Bad -> theme.danger_text()
    Live -> theme.current_bold()
  }
}
