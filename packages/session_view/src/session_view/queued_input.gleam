//// A queued input's complete authoritative document, as the daemon sends it.
////
//// The document is separate from `tui/queue_editor`, which edits it in a
//// multiline editor, because the protocol decodes it wherever a queue read
//// is answered and that decode needs no editor. It carries the identity and
//// revision every replacement must compare, so a stale or already admitted
//// item cannot become a new submission.

import core/json
import gleam/bool
import gleam/list
import gleam/result
import gleam/string

/// Complete text and the exact queue revision fetched for editing.
pub type Document {
  Document(
    /// Opaque queue identity, independent of its text and list position.
    id: String,
    /// Strand whose held queue still owns this input.
    strand: String,
    /// The version every replacement must compare before changing text.
    revision: Int,
    /// Original scheduling priority, preserved by every edit.
    kind: Kind,
    /// All textual content, with no excerpt substitution.
    text: String,
    /// Image blocks which stay on the server and survive replacement.
    attachment_count: Int,
  )
}

/// Editing never changes the original input's priority.
pub type Kind {
  /// Ordinary input waits behind submitted steering.
  Queue

  /// Steering precedes ordinary held input.
  Steer
}

/// Checks the full encoded document bound before admitting an editor value.
///
/// ## Examples
///
/// ```gleam
/// // queued_input.decode(board)
/// ```
pub fn decode(value: json.JsonValue) -> Result(Document, String) {
  use <- bool.guard(
    string.byte_size(json.to_string(value)) > 48_000,
    Error("complete queued input exceeds the editor bound"),
  )
  use fields <- result.try(object(value))
  use id <- result.try(text(fields, "id"))
  use strand <- result.try(text(fields, "strand"))
  use revision <- result.try(number(fields, "revision"))
  use name <- result.try(text(fields, "kind"))
  use kind <- result.try(case name {
    "queue" -> Ok(Queue)
    "steer" -> Ok(Steer)
    _ -> Error("unknown queued input priority")
  })
  use content <- result.try(text(fields, "text"))
  use attachment_count <- result.try(number(fields, "attachment_count"))
  use <- bool.guard(
    id == ""
      || strand == ""
      || string.byte_size(id) > 512
      || string.byte_size(strand) > 512,
    Error("invalid queued input identity"),
  )
  Ok(Document(id, strand, revision, kind, content, attachment_count))
}

fn object(value) {
  case value {
    json.Object(fields) -> Ok(fields)
    _ -> Error("expected queued input object")
  }
}

fn text(fields, name) {
  case list.key_find(fields, name) {
    Ok(json.String(value)) -> Ok(value)
    _ -> Error("missing queued input text field: " <> name)
  }
}

fn number(fields, name) {
  case list.key_find(fields, name) {
    Ok(json.Int(value)) if value >= 0 -> Ok(value)
    _ -> Error("invalid queued input number: " <> name)
  }
}
