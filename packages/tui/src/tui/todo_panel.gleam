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
//// the caller decides where they go and how many rows it can spare.

import core/entry
import core/json.{type JsonValue}
import core/message.{type AgentMessage}
import core/todo_list.{
  type Board, type Phase, type Task, Active, Blocked, Done, Dropped, Pending,
}
import etui/span
import etui/style
import etui/text
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import tui/protocol
import tui/text_hygiene
import tui/theme

/// The tool name whose results carry a board.
pub const tool_name = "todo"

/// The most rows the panel asks for, however long the focused phase is.
pub const max_rows = 8

/// The board a message carries, when it is a successful `todo` result.
///
/// A failed call leaves the board where it was, so an error result
/// carries nothing here even when it has details.
///
/// ## Examples
///
/// ```gleam
/// // todo_panel.from_message(result) == Some(board)
/// ```
pub fn from_message(message: AgentMessage) -> Option(Board) {
  case message {
    message.ToolResultMessage(
      tool_name: name,
      is_error: False,
      details: Some(details),
      ..,
    )
      if name == tool_name
    -> from_details(details)
    message.ToolResultMessage(..)
    | message.UserMessage(..)
    | message.AssistantMessage(..)
    | message.CustomMessage(..) -> None
  }
}

/// The board inside a `todo` result's `details` object.
///
/// ## Examples
///
/// ```gleam
/// // todo_panel.from_details(json.Object([#("todo", board_json)]))
/// ```
pub fn from_details(details: JsonValue) -> Option(Board) {
  case details {
    json.Object(fields) ->
      case list.key_find(fields, "todo") {
        Ok(value) -> todo_list.decode(value) |> option.from_result
        Error(Nil) -> None
      }
    json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> None
  }
}

/// The newest board in a newest-first record list, the order a captured
/// branch and `Model.records` both hold.
///
/// ## Examples
///
/// ```gleam
/// assert todo_panel.newest([]) == option.None
/// ```
pub fn newest(records: List(protocol.EntryRecord)) -> Option(Board) {
  list.find_map(records, fn(record) {
    case record.entry {
      entry.MessageEntry(message:, ..) ->
        from_message(message) |> option.to_result(Nil)
      entry.CompactionEntry(..)
      | entry.BranchSummaryEntry(..)
      | entry.CustomEntry(..) -> Error(Nil)
    }
  })
  |> option.from_result
}

/// Folds newest-first records into the per-strand boards, keeping each
/// strand's newest. A strand whose records carry no board keeps the board
/// it had, which is what stops a capture whose window has moved past the
/// last `todo` call from blanking the panel.
///
/// ## Examples
///
/// ```gleam
/// assert todo_panel.remember(dict.new(), []) == dict.new()
/// ```
pub fn remember(
  boards: Dict(String, Board),
  records: List(protocol.EntryRecord),
) -> Dict(String, Board) {
  records
  |> list.group(fn(record) { record.strand })
  |> dict.fold(boards, fn(boards, strand, owned) {
    case newest(owned) {
      Some(board) -> dict.insert(boards, strand, board)
      None -> boards
    }
  })
}

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
fn wanted(board: Board) -> Int {
  case board.phases, finished(board) {
    [], _ -> 0
    _, True -> 1
    [_, ..], False -> {
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
  case rows <= 0, todo_list.focus(board), finished(board) {
    True, _, _ | _, None, _ -> []
    False, Some(_), True -> [done_line(board, width)]
    False, Some(phase), False -> {
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

// The window keeps the active task in view with one task of context above
// it, and spends the last row on a count of what it left out on each side.
fn task_lines(phase: Phase, width: Int, rows: Int) -> List(span.Line) {
  let tasks = phase.tasks
  let count = list.length(tasks)
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

// Says which side of the window the hidden tasks are on, since the ones
// above are usually finished and the ones below are still ahead.
fn hidden_label(above: Int, below: Int) -> String {
  case above, below {
    0, _ -> int.to_string(below) <> " more below"
    _, 0 -> int.to_string(above) <> " earlier above"
    _, _ ->
      int.to_string(above) <> " above · " <> int.to_string(below) <> " below"
  }
}

// The active task if there is one, else the first open task, else the top.
fn anchor_index(tasks: List(Task)) -> Int {
  let indexed = list.index_map(tasks, fn(task, index) { #(index, task) })
  let find = fn(wanted: fn(Task) -> Bool) {
    list.find(indexed, fn(entry) { wanted(entry.1) })
  }
  case find(fn(task) { task.status == Active }) {
    Ok(#(index, _)) -> index
    Error(Nil) ->
      case find(todo_list.is_open) {
        Ok(#(index, _)) -> index
        Error(Nil) -> 0
      }
  }
}

fn task_line(task: Task, width: Int) -> span.Line {
  let text = clean(task.text)
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

// Every phase but the focused one, in order, on one row: a finished phase
// is a check, anything else is its closed count, so the row reads as the
// road behind and ahead of the phase being worked.
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

// --- the transcript row ------------------------------------------------------

/// The one-line summary of a `todo` call for the compact transcript. The
/// pinned panel already shows the whole board, so the transcript says only
/// what this call changed.
///
/// ## Examples
///
/// ```gleam
/// assert todo_panel.call_summary(json.Object([#("op", json.String("view"))]))
///   == "todo · view"
/// ```
pub fn call_summary(arguments: JsonValue) -> String {
  let field = fn(key) {
    case arguments {
      json.Object(fields) ->
        case list.key_find(fields, key) {
          Ok(json.String(value)) -> Some(clean(value))
          Ok(_) | Error(Nil) -> None
        }
      json.Array(_)
      | json.String(_)
      | json.Int(_)
      | json.Float(_)
      | json.Bool(_)
      | json.Null -> None
    }
  }
  let op = option.unwrap(field("op"), "?")
  let target = case field("task"), field("phase") {
    Some(task), _ -> " " <> string.inspect(task)
    None, Some(phase) -> " phase " <> string.inspect(phase)
    None, None -> ""
  }
  "todo · " <> op <> target
}

/// The progress a successful `todo` result reports, for the end of its
/// transcript row.
///
/// ## Examples
///
/// ```gleam
/// // todo_panel.result_summary(details) == Some("3/8 done")
/// ```
pub fn result_summary(details: JsonValue) -> Option(String) {
  use board <- option.map(from_details(details))
  let #(closed, total) = todo_list.count(board)
  count(closed, total) <> " done"
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

// Truncates a row's spans to the width, cutting the span that crosses the
// edge and dropping the rest, then pads so the row paints its whole width.
fn fit(spans: List(span.Span), width: Int) -> span.Line {
  let #(kept, used) =
    list.fold(spans, #([], 0), fn(acc, each) {
      let #(kept, used) = acc
      let room = width - used
      let size = text.cell_width(each.content)
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
  let pad = case width - used > 0 {
    True -> [span.span_plain(string.repeat(" ", width - used))]
    False -> []
  }
  span.line_new(list.append(list.reverse(kept), pad))
}

// Puts `right` flush against the right edge when both halves fit, and
// drops it when they do not, since the left half names the phase and the
// right half only repeats a count.
fn justify(
  left: List(span.Span),
  right: List(span.Span),
  width: Int,
) -> span.Line {
  let left_width =
    list.fold(left, 0, fn(sum, each) { sum + text.cell_width(each.content) })
  let right_width =
    list.fold(right, 0, fn(sum, each) { sum + text.cell_width(each.content) })
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
