//// Current note values arrive as a bounded auxiliary view, separate from the
//// historical conversation. Its revision is evidence of when the values were
//// read; a run-start digest is never relabelled as the current blackboard.
////
//// Most cells are free-form, so they are shown through one generic
//// JSON-to-Markdown projection. The `todo` cell is the exception: its shape
//// is fixed by `core/todo_list`, and the generic projection turns a board
//// into nested `Phases`/`Name`/`Tasks` bullets that hide the one thing a
//// reader wants from it, which is how far along the work is. A complete
//// `todo` cell that decodes is therefore drawn as a phased checklist with
//// the pinned panel's glyphs. Anything else, an excerpt included, keeps the
//// generic projection, because an excerpt may end mid-value and a board
//// that fails the total decoder is exactly the case a reader needs to see
//// as it was stored.

import core/json
import core/todo_list.{Active, Blocked, Done, Dropped, Pending}
import gleam/bool
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import tui/text_hygiene

/// Presents complete structured notes as Markdown while retaining plain prose.
///
/// Parsing changes presentation only. Callers keep the original text for raw
/// inspection, and excerpts must remain literal because they may end mid-value.
///
/// ## Examples
///
/// ```gleam
/// assert notes_view.readable("\"A readable note\"") == "A readable note"
/// ```
pub fn readable(text: String) -> String {
  case json.parse(text) {
    Ok(value) -> structured(note_value(value), 0)
    Error(_) -> text
  }
  |> text_hygiene.multiline
}

/// The strand-relative key of the cell holding a strand's todo board.
pub const todo_key = "todo"

/// The todo board a note holds, when it is the complete `todo` cell and its
/// value passes the board's total decoder.
///
/// An excerpt is never parsed: its text may stop partway through a task, and
/// a board read from it would silently drop the tasks past the cut.
///
/// ## Examples
///
/// ```gleam
/// // notes_view.todo_board(notes_view.Note("todo", 3, text, notes_view.Complete))
/// ```
pub fn todo_board(note: Note) -> Result(todo_list.Board, Nil) {
  use <- bool.guard(note.key != todo_key || note.extent == Excerpt, Error(Nil))
  use value <- result.try(json.parse(note.text) |> result.replace_error(Nil))
  note_value(value) |> todo_list.decode |> result.replace_error(Nil)
}

/// The readable body of one note: a phased checklist for a decodable todo
/// board, and the generic projection for every other note.
///
/// ## Examples
///
/// ```gleam
/// // notes_view.readable_note(note)
/// ```
pub fn readable_note(note: Note) -> String {
  case todo_board(note) {
    Ok(board) -> checklist(board) |> text_hygiene.multiline
    Error(Nil) -> readable(note.text)
  }
}

/// The text a note's list row summarises: board progress for a decodable
/// todo board, the readable projection for other complete notes, and the
/// literal text of an excerpt.
///
/// ## Examples
///
/// ```gleam
/// // notes_view.summary(todo_note) == "3/8 done · active: Wire the panel"
/// ```
pub fn summary(note: Note) -> String {
  case todo_board(note), note.extent {
    Ok(board), _ -> progress(board)
    Error(Nil), Complete -> readable(note.text)
    Error(Nil), Excerpt -> note.text
  }
}

// The row has room for one clause after the count, and the active task is
// the one that says what the agent is doing now. A board with no active
// task has nothing better to name than its count.
fn progress(board: todo_list.Board) -> String {
  let #(closed, total) = todo_list.count(board)
  let done = int.to_string(closed) <> "/" <> int.to_string(total) <> " done"
  case board.phases, todo_list.active(board) {
    [], _ -> "no tasks"
    _, Some(#(_, task)) ->
      done <> " · active: " <> text_hygiene.single_line(task.text)
    _, None -> done
  }
}

// Each phase is a heading carrying its own closed count, so a reader can
// see which phases are finished without reading their tasks.
fn checklist(board: todo_list.Board) -> String {
  case board.phases {
    [] -> "No tasks."
    phases ->
      phases
      |> list.map(fn(phase) {
        let #(closed, total) = todo_list.tally(phase.tasks)
        let heading =
          "### "
          <> escape(phase.name)
          <> " · "
          <> int.to_string(closed)
          <> "/"
          <> int.to_string(total)
        case phase.tasks {
          [] -> heading
          tasks ->
            heading <> "\n\n" <> string.join(list.map(tasks, task_item), "\n")
        }
      })
      |> string.join("\n\n")
  }
}

// The glyphs are the pinned panel's, so a status reads the same in both
// places, and each still reads on a terminal without color. Strikethrough
// and bold stand in for the panel's struck and highlighted text.
fn task_item(task: todo_list.Task) -> String {
  let text = escape(task.text)
  "- "
  <> case task.status {
    Done -> "✓ ~~" <> text <> "~~"
    Dropped -> "– ~~" <> text <> "~~"
    Active -> "▸ **" <> text <> "**"
    Pending -> "○ " <> text
    Blocked(Some(reason)) -> "⊘ " <> text <> " · " <> escape(reason)
    Blocked(None) -> "⊘ " <> text
  }
}

// Task text is written by the model, so every Markdown delimiter in it is
// escaped: a stray `*` or `~~` must not restyle the rest of the row.
fn escape(value: String) -> String {
  value
  |> text_hygiene.single_line
  |> string.replace("\\", "\\\\")
  |> string.replace("*", "\\*")
  |> string.replace("_", "\\_")
  |> string.replace("~", "\\~")
  |> string.replace("`", "\\`")
  |> string.replace("[", "\\[")
  |> string.replace("]", "\\]")
  |> string.replace("<", "\\<")
}

/// Renders complete cells from a historical run-start digest.
///
/// A truncated final cell stays literal and labelled; complete earlier cells
/// can still be decoded without claiming the digest is a current board.
///
/// ## Examples
///
/// ```gleam
/// // notes_view.historical("plan = {\"done\": [\"built\"]}")
/// ```
@internal
pub fn historical(payload: String) -> String {
  payload
  |> string.split("\n")
  |> list.map(fn(line) {
    case string.split_once(line, " = ") {
      Ok(#(key, value)) -> {
        let heading = "### " <> field_label(key) <> "\n\n"
        case json.parse(value) {
          Ok(_) -> heading <> readable(value)
          Error(_) -> heading <> "Incomplete historical excerpt:\n\n" <> line
        }
      }
      Error(_) -> line
    }
  })
  |> string.join("\n\n")
}

// Some note tools accept a JSON document as a string value. Unwrap that
// document once at the note boundary, rather than exposing escaped JSON.
fn note_value(value: json.JsonValue) -> json.JsonValue {
  case value {
    json.String(text) ->
      case json.parse(text) {
        Ok(json.Object(_) as nested) | Ok(json.Array(_) as nested) -> nested
        Ok(_) | Error(_) -> value
      }
    _ -> value
  }
}

fn structured(value: json.JsonValue, depth: Int) -> String {
  case depth >= 6, value {
    True, _ -> json.to_string(value)
    False, json.String(text) -> text
    False, json.Object(fields) ->
      fields
      |> list.map(fn(pair) {
        let label = "- **" <> field_label(pair.0) <> "**"
        let body = structured(pair.1, depth + 1)
        case pair.1 {
          json.Object(_) | json.Array(_) -> label <> "\n" <> indent(body)
          _ -> label <> ": " <> string.replace(body, "\n", "\n  ")
        }
      })
      |> string.join("\n")
    False, json.Array(values) ->
      values
      |> list.map(fn(item) {
        "- " <> string.replace(structured(item, depth + 1), "\n", "\n  ")
      })
      |> string.join("\n")
    False, json.Int(_)
    | False, json.Float(_)
    | False, json.Bool(_)
    | False, json.Null
    -> json.to_string(value)
  }
}

fn indent(text: String) -> String {
  "  " <> string.replace(text, "\n", "\n  ")
}

fn field_label(key: String) -> String {
  let label = text_hygiene.single_line(key) |> string.replace("_", " ")
  let label =
    string.uppercase(string.slice(label, 0, 1)) <> string.drop_start(label, 1)
  label
  |> string.replace("\\", "\\\\")
  |> string.replace("*", "\\*")
  |> string.replace("[", "\\[")
  |> string.replace("]", "\\]")
  |> string.replace("`", "\\`")
}

/// One current, bounded view of a strand's durable blackboard.
pub type Board {
  Board(
    /// The strand whose notes were requested.
    strand: String,
    /// Latest session revision visible to the read.
    as_of: Int,
    /// Total cells in the board, including rows omitted by the display budget.
    total: Int,
    /// Newest-written first, as supplied by the host.
    notes: List(Note),
  )
}

/// One note's value and the revision which last changed it.
pub type Note {
  Note(
    /// Strand-relative blackboard key.
    key: String,
    /// Durable revision of this value.
    seq: Int,
    /// The complete value or its explicitly labelled bounded excerpt.
    text: String,
    /// Whether the display contains the whole value.
    extent: Extent,
  )
}

/// A display excerpt never claims to contain the complete stored value.
pub type Extent {
  /// The complete text rendering of the stored JSON value.
  Complete

  /// A bounded prefix; the durable value remains intact.
  Excerpt
}

/// Validates one board before the terminal replaces its previous view.
///
/// ## Examples
///
/// ```gleam
/// // notes_view.decode(body)
/// ```
pub fn decode(value: json.JsonValue) -> Result(Board, String) {
  use fields <- result.try(object(value))
  use strand <- result.try(text(fields, "strand"))
  use as_of <- result.try(number(fields, "as_of"))
  use total <- result.try(number(fields, "total"))
  use raw <- result.try(field(fields, "notes"))
  use rows <- result.try(array(raw))
  use <- bool.guard(
    list.drop(rows, 1024) != [],
    Error("too many displayed notes"),
  )
  use notes <- result.try(list.try_map(rows, note))
  let keys = dict.from_list(list.map(notes, fn(note) { #(note.key, Nil) }))
  use <- bool.guard(
    total < list.length(notes)
      || dict.size(keys) != list.length(notes)
      || list.any(notes, fn(note) { note.seq > as_of }),
    Error("inconsistent notes snapshot"),
  )
  Ok(Board(strand, as_of, total, notes))
}

fn note(value) {
  use fields <- result.try(object(value))
  use key <- result.try(text(fields, "key"))
  use seq <- result.try(number(fields, "seq"))
  use content <- result.try(text(fields, "text"))
  use extent <- result.try(text(fields, "extent"))
  use <- bool.guard(
    string.byte_size(content) > 4096,
    Error("oversized note excerpt"),
  )
  case extent {
    "complete" -> Ok(Note(key, seq, content, Complete))
    "excerpt" -> Ok(Note(key, seq, content, Excerpt))
    _ -> Error("invalid note extent")
  }
}

fn object(value) {
  case value {
    json.Object(fields) -> Ok(fields)
    _ -> Error("expected notes object")
  }
}

fn array(value) {
  case value {
    json.Array(rows) -> Ok(rows)
    _ -> Error("expected notes array")
  }
}

fn field(fields, name) {
  list.key_find(fields, name) |> result.replace_error("missing notes field")
}

fn text(fields, name) {
  use value <- result.try(field(fields, name))
  case value {
    json.String(text) -> Ok(text)
    _ -> Error("expected notes text")
  }
}

fn number(fields, name) {
  use value <- result.try(field(fields, name))
  case value {
    json.Int(value) if value >= 0 -> Ok(value)
    _ -> Error("expected notes revision")
  }
}
