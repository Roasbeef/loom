//// Current note values arrive as a bounded auxiliary view, separate from the
//// historical conversation. Its revision is evidence of when the values were
//// read; a run-start digest is never relabelled as the current blackboard.

import core/json
import gleam/bool
import gleam/dict
import gleam/list
import gleam/result
import gleam/string

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
