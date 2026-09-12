//// Current note values arrive as a bounded auxiliary view, separate from the
//// historical conversation. Its revision is evidence of when the values were
//// read; a run-start digest is never relabelled as the current blackboard.

import core/json
import gleam/bool
import gleam/dict
import gleam/list
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
