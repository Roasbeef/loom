//// A strand's todo board, as the transcript carries it.
////
//// Every successful `todo` call settles with the landed board in its
//// result's `details`, decoded here through `core/todo_list.decode`, the
//// same total decoder the tool itself uses, so nothing here can disagree
//// with the tool about what a stored board means. The latest result wins,
//// and a strand keeps the last board it saw across snapshot cuts, so a cut
//// whose window no longer reaches the last `todo` call does not lose it.
////
//// The module draws nothing. `tui/todo_panel` draws the board, and the
//// transcript uses `call_summary` and `result_summary` for a `todo` call's
//// one row, so the board and its summaries sit apart from any renderer.

import core/entry
import core/json.{type JsonValue}
import core/message.{type AgentMessage}
import core/todo_list.{type Board}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import gleam/string
import session_view/notes_view
import session_view/protocol
import session_view/text_hygiene

/// The tool name whose results carry a board.
pub const tool_name = "todo"

/// The board a message carries, when it is a successful `todo` result.
///
/// A failed call leaves the board where it was, so an error result
/// carries nothing here even when it has details.
///
/// ## Examples
///
/// ```gleam
/// // todo_board.from_message(result) == Some(board)
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
/// // todo_board.from_details(json.Object([#("todo", board_json)]))
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
/// assert todo_board.newest([]) == option.None
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
/// assert todo_board.remember(dict.new(), []) == dict.new()
/// ```
pub fn remember(
  boards: Dict(String, Board),
  records: List(protocol.EntryRecord),
) -> Dict(String, Board) {
  // Records are newest first, so the first board met for a strand is its
  // newest; `seen` stops an older one later in the list replacing it.
  let #(boards, _) =
    list.fold(records, #(boards, set.new()), fn(acc, record) {
      let #(boards, seen) = acc
      case set.contains(seen, record.strand), newest([record]) {
        False, Some(board) -> #(
          dict.insert(boards, record.strand, board),
          set.insert(seen, record.strand),
        )
        True, _ | False, None -> acc
      }
    })
  boards
}

/// Seeds a strand's board from a notes read, when the read carries the
/// complete `todo` cell and the strand has no board yet.
///
/// This is the recovery path for a capture whose window no longer reaches
/// the last `todo` call, which is the common case after reattaching to a
/// long session. A board already known from the transcript is newer than
/// or equal to the read, so it is never replaced; an excerpted cell is
/// never parsed.
///
/// ## Examples
///
/// ```gleam
/// // todo_board.seed(boards, notes_board)
/// ```
pub fn seed(
  boards: Dict(String, Board),
  notes: notes_view.Board,
) -> Dict(String, Board) {
  let found = list.find_map(notes.notes, notes_view.todo_board)
  case found, dict.has_key(boards, notes.strand) {
    Ok(board), False -> dict.insert(boards, notes.strand, board)
    Ok(_), True | Error(Nil), _ -> boards
  }
}

/// The note key, relative to a strand's namespace, that holds its board.
pub const note_key = notes_view.todo_key

/// Whether a strand should have its board read from its notes: it has no
/// board from the transcript, and it has not been asked about before in
/// this session. One read per strand keeps an agent that never makes a
/// list from costing a read on every capture.
///
/// ## Examples
///
/// ```gleam
/// assert todo_board.needs_seed(dict.new(), set.new(), "main")
/// ```
pub fn needs_seed(
  boards: Dict(String, Board),
  asked: Set(String),
  strand: String,
) -> Bool {
  !dict.has_key(boards, strand) && !set.contains(asked, strand)
}

/// The one-line summary of a `todo` call for the compact transcript. The
/// pinned panel already shows the whole board, so the transcript says only
/// what this call changed. A call with no `op` changed nothing, because the
/// tool refuses it, and reads `todo · invalid arguments`.
///
/// ## Examples
///
/// ```gleam
/// assert todo_board.call_summary(json.Object([#("op", json.String("view"))]))
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
  let target = case field("task"), field("phase") {
    Some(task), _ -> " " <> string.inspect(task)
    None, Some(phase) -> " phase " <> string.inspect(phase)
    None, None -> ""
  }
  case field("op") {
    Some(op) -> "todo · " <> op <> target
    None -> "todo · " <> invalid_call
  }
}

/// What a transcript row says for a `todo` call that carries no `op`. The
/// tool refuses such a call whatever else it holds, so the row can say so
/// before the result arrives.
pub const invalid_call = "invalid arguments"

/// The progress a successful `todo` result reports, for the end of its
/// transcript row.
///
/// ## Examples
///
/// ```gleam
/// // todo_board.result_summary(details) == Some("3/8 done")
/// ```
pub fn result_summary(details: JsonValue) -> Option(String) {
  use board <- option.map(from_details(details))
  let #(closed, total) = todo_list.count(board)
  count(closed, total) <> " done"
}

fn count(closed: Int, total: Int) -> String {
  int.to_string(closed) <> "/" <> int.to_string(total)
}

fn clean(text: String) -> String {
  text_hygiene.single_line(text)
}
