//// The pinned todo panel: the strand's current task list, drawn between
//// the conversation and the composer.
////
//// The board comes from the transcript, not from a read of its own. Every
//// successful `todo` call settles with the landed board in its result's
//// `details`, decoded here through `core/todo_list.decode`, the same total
//// decoder the tool itself uses, so the panel can never disagree with the
//// tool about what a stored board means. The latest result wins. The model
//// keeps the last board it saw across snapshot cuts, so a cut whose window
//// no longer reaches the last `todo` call does not blank the panel.
////
//// The panel answers one question at a glance: what is the agent doing now,
//// and how much is left. So it shows the phase that holds the active task
//// with every task in it, and folds every other phase into one summary
//// row. Each status has its own glyph as well as its own color, so the
//// panel still reads on a terminal without color: `✓` done, `▸` active,
//// `○` pending, `⊘` blocked, `–` dropped. A board whose tasks are all
//// closed collapses to a single row.
////
//// This module is pure: it renders lines for a width and a row budget, and
//// the caller decides where they go and how many rows it can spare. Which
//// board a strand has, and the one-line summaries a `todo` call gets in the
//// transcript, are `session_view/todo_board`'s, which draws nothing.

import core/todo_list.{
  type Board, type Phase, type Task, Active, Blocked, Done, Dropped, Pending,
}
import etui/span
import etui/style
import etui/text
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import session_view/text_hygiene
import tui/theme

/// The most rows the panel asks for, however long the focused phase is.
pub const max_rows = 8

/// How many rows the panel wants, within `budget`. An empty board, or no
/// board, wants none, so the panel costs nothing until the agent makes a
/// list.
///
/// ## Examples
///
/// ```gleam
/// assert todo_panel.height(option.None, 8) == 0
/// ```
pub fn height(board: Option(Board), budget: Int) -> Int {
  case board {
    None -> 0
    Some(board) -> int.min(int.min(wanted(board), max_rows), int.max(budget, 0))
  }
}

// One header row, the focused phase's tasks, and one summary row when any
// other phase exists. A finished board is one row.
/// Computes desired row count for the todo panel.
fn wanted(board: Board) -> Int {
  // Determine row budget based on active phases and completion.
  case board.phases, finished(board) {
    [], _ -> 0
    _, True -> 1
    [_, ..], False -> {
      // Count tasks in focused phase.
      let tasks = case todo_list.focus(board) {
        Some(phase) -> list.length(phase.tasks)
        None -> 0
      }

      1 + tasks + others_rows(board)
    }
  }
}

fn others_rows(board: Board) -> Int {
  case list.length(board.phases) > 1 {
    True -> 1
    False -> 0
  }
}

fn finished(board: Board) -> Bool {
  let #(closed, total) = todo_list.count(board)
  closed == total
}

/// Renders the panel in exactly `rows` rows of `width` cells. `rows` is
/// normally what `height` answered; fewer rows keep the header and as much
/// of the focused phase as fits around its active task.
///
/// ## Examples
///
/// ```gleam
/// // todo_panel.lines(board, 80, todo_panel.height(Some(board), 8))
/// ```
pub fn lines(board: Board, width: Int, rows: Int) -> List(span.Line) {
  // Format todo lines according to available rows and board focus.
  case rows <= 0, todo_list.focus(board), finished(board) {
    True, _, _ | _, None, _ -> []
    False, Some(_), True -> [done_line(board, width)]
    False, Some(phase), False -> {
      // Check whether summary line for other phases fits.
      let summary = case others_rows(board) > 0 && rows >= 3 {
        True -> [others_line(board, phase, width)]
        False -> []
      }

      let task_rows = rows - 1 - list.length(summary)
      [header(board, phase, width), ..task_lines(phase, width, task_rows)]
      |> list.append(summary)
    }
  }
}

// --- rows --------------------------------------------------------------------

/// Formats the top header line showing phase name and progress tally.
fn header(board: Board, phase: Phase, width: Int) -> span.Line {
  let #(closed, total) = todo_list.count(board)
  let #(phase_closed, phase_total) = todo_list.tally(phase.tasks)
  let right = count(closed, total) <> " done"
  let left = [
    span.span_styled("TODO", theme.signal_bold()),
    span.span_styled("  " <> clean(phase.name), bold(theme.paper)),
    span.span_styled(
      " " <> count(phase_closed, phase_total),
      theme.quiet_text(),
    ),
  ]
  justify(left, [span.span_styled(right, theme.quiet_text())], width)
}

/// Formats single completion line when all tasks on board are closed.
fn done_line(board: Board, width: Int) -> span.Line {
  let #(_, total) = todo_list.count(board)
  let phases = list.length(board.phases)
  let detail =
    "  all "
    <> int.to_string(total)
    <> plural(total, " task", " tasks")
    <> " closed"
    <> case phases > 1 {
      True -> " across " <> int.to_string(phases) <> " phases"
      False -> ""
    }
  fit(
    [
      span.span_styled("TODO ", theme.signal_bold()),
      span.span_styled("✓", theme.success_text()),
      span.span_styled(detail, theme.quiet_text()),
    ],
    width,
  )
}

/// Formats visible task lines within the available row window.
fn task_lines(phase: Phase, width: Int, rows: Int) -> List(span.Line) {
  let tasks = phase.tasks
  let count = list.length(tasks)

  // Determine windowing if tasks exceed available rows.
  case rows <= 0, count <= rows {
    True, _ -> []
    False, True -> list.map(tasks, task_line(_, width))
    False, False -> {
      let anchor = anchor_index(tasks)
      let shown = int.max(rows - 1, 1)
      let start = int.clamp(anchor - 1, 0, count - shown)
      let visible =
        tasks
        |> list.drop(start)
        |> list.take(shown)
        |> list.map(task_line(_, width))
      let above = start
      let below = count - start - shown
      list.append(visible, [
        fit(
          [
            span.span_styled(
              "  ⋯ " <> hidden_label(above, below),
              theme.quiet_text(),
            ),
          ],
          width,
        ),
      ])
      |> list.take(rows)
    }
  }
}

/// Formats hidden task counts above and below visible window.
fn hidden_label(above: Int, below: Int) -> String {
  case above, below {
    0, _ -> int.to_string(below) <> " more below"
    _, 0 -> int.to_string(above) <> " earlier above"
    _, _ ->
      int.to_string(above) <> " above · " <> int.to_string(below) <> " below"
  }
}

/// Finds index of active or first open task to anchor the viewport.
fn anchor_index(tasks: List(Task)) -> Int {
  let indexed = list.index_map(tasks, fn(task, index) { #(index, task) })
  let find = fn(wanted: fn(Task) -> Bool) {
    list.find(indexed, fn(entry) { wanted(entry.1) })
  }

  // Locate active task or fallback to first open task.
  case find(fn(task) { task.status == Active }) {
    Ok(#(index, _)) -> index
    Error(Nil) ->
      case find(todo_list.is_open) {
        Ok(#(index, _)) -> index
        Error(Nil) -> 0
      }
  }
}

/// Formats a single styled task row.
fn task_line(task: Task, width: Int) -> span.Line {
  let text = clean(task.text)

  // Style task marker and text according to status.
  let spans = case task.status {
    Done -> [
      span.span_styled("  ✓ ", theme.success_text()),
      span.span_styled(text, struck(theme.quiet)),
    ]
    Dropped -> [
      span.span_styled("  – ", theme.quiet_text()),
      span.span_styled(text, struck(theme.quiet)),
    ]
    Active -> [
      span.span_styled("  ▸ ", theme.signal_bold()),
      span.span_styled(text, bold(theme.signal)),
    ]
    Pending -> [
      span.span_styled("  ○ ", theme.quiet_text()),
      span.span_styled(text, plain(theme.paper)),
    ]
    Blocked(reason) -> [
      span.span_styled("  ⊘ ", theme.danger_text()),
      span.span_styled(text, plain(theme.danger)),
      ..case reason {
        Some(reason) -> [
          span.span_styled(" · " <> clean(reason), theme.quiet_text()),
        ]
        None -> []
      }
    ]
  }

  fit(spans, width)
}

/// Formats summary row showing progress across all other phases.
fn others_line(board: Board, focus: Phase, width: Int) -> span.Line {
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
  fit(
    [span.span_styled("  " <> string.join(parts, " · "), theme.quiet_text())],
    width,
  )
}

// --- helpers -----------------------------------------------------------------

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

fn plain(color: style.Color) -> style.Style {
  style.new(color, style.Default, style.none())
}

fn bold(color: style.Color) -> style.Style {
  style.new(color, style.Default, style.bold())
}

fn struck(color: style.Color) -> style.Style {
  style.add_modifier(plain(color), style.strikethrough())
}

/// Truncates and pads spans to fit exact line width.
fn fit(spans: List(span.Span), width: Int) -> span.Line {
  let #(kept, used) =
    list.fold(spans, #([], 0), fn(acc, each) {
      let #(kept, used) = acc
      let room = width - used
      let size = text.cell_width(each.content)

      // Truncate span if it overflows remaining width.
      case room <= 0, size <= room {
        True, _ -> acc
        False, True -> #([each, ..kept], used + size)
        False, False -> {
          let cut = text.truncate(each.content, room, "…")
          #(
            [span.Span(..each, content: cut), ..kept],
            used + text.cell_width(cut),
          )
        }
      }
    })

  // Pad remaining width with blank space.
  let pad = case width - used > 0 {
    True -> [span.span_plain(string.repeat(" ", width - used))]
    False -> []
  }

  span.line_new(list.append(list.reverse(kept), pad))
}

/// Justifies left and right span groups across line width.
fn justify(
  left: List(span.Span),
  right: List(span.Span),
  width: Int,
) -> span.Line {
  let left_width =
    list.fold(left, 0, fn(sum, each) { sum + text.cell_width(each.content) })
  let right_width =
    list.fold(right, 0, fn(sum, each) { sum + text.cell_width(each.content) })

  // Check whether both left and right groups fit.
  case left_width + 2 + right_width <= width {
    True ->
      fit(
        list.flatten([
          left,
          [
            span.span_plain(string.repeat(" ", width - left_width - right_width)),
          ],
          right,
        ]),
        width,
      )
    False -> fit(left, width)
  }
}
