//// Durable structured notes shared by code-mode calls and agent_note.
//// A put updates the caller's own cell. Reads address any agent's cell in
//// this session, using keys relative to agent/, such as main/analysis.
//// Values survive satellite exit and compaction; KV scratch may not.
//// Writes do not notify readers. These are session notes, not repository
//// memory, and concurrent writes to one cell are last-write-wins.

import cap/internal/channel.{type CallError, Denied, Unreachable}
import cap/internal/dispatch
import cap/internal/wire
import cap/report.{type Value}
import gleam/option.{type Option, None, Some}
import gleam/result

/// A storage, validation, admission, or transport refusal.
pub type NotesError {
  /// The host refused this call, retaining its error code and explanation.
  NotesDenied(code: String, message: String)

  /// The host could not be reached or answered with an invalid value.
  NotesUnavailable(reason: String)
}

/// Stores JSON-compatible data under the caller's own key. Reusing a key
/// replaces its current value; a child's result key retains schema checks.
/// Capability: notes.put. The execution allows at most 256 calls.
///
/// ## Examples
///
/// ```gleam
/// notes.put("analysis", report.object([#("count", report.int(3))]))
/// ```
pub fn put(key: String, value: Value) -> Result(Nil, NotesError) {
  dispatch.call(
    "notes.put",
    wire.args([#("key", wire.string(key)), #("value", value)]),
  )
  |> result.replace(Nil)
  |> result.map_error(map_error)
}

/// Reads one exact shared key, relative to agent/. A missing key returns
/// None; a stored JSON null returns Some(report.null()).
/// Capability: notes.get. The execution allows at most 64 calls.
///
/// ## Examples
///
/// ```gleam
/// notes.get("main/analysis")
/// ```
pub fn get(key: String) -> Result(Option(Value), NotesError) {
  use value <- result.try(
    dispatch.call("notes.get", wire.args([#("key", wire.string(key))]))
    |> result.map_error(map_error),
  )
  use found <- result.try(
    wire.bool_field(value, "found") |> result.map_error(NotesUnavailable),
  )
  case found {
    False -> Ok(None)
    True ->
      wire.field(value, "value")
      |> result.map(Some)
      |> result.map_error(NotesUnavailable)
  }
}

/// Reads cells matching a relative prefix. Returned keys can be passed
/// directly to get, or prefixed with note:// for cap/fs.read. None scans
/// the session's shared agent notes. Oversized replies fail explicitly.
/// Capability: notes.list. The execution allows at most 64 calls.
///
/// ## Examples
///
/// ```gleam
/// notes.list(Some("main/"))
/// ```
pub fn list(
  prefix: Option(String),
) -> Result(List(#(String, Value)), NotesError) {
  let prefix = case prefix {
    None -> report.null()
    Some(text) -> report.string(text)
  }
  use value <- result.try(
    dispatch.call("notes.list", wire.args([#("prefix", prefix)]))
    |> result.map_error(map_error),
  )
  wire.array_of(value, "notes", of: decode_note)
  |> result.map_error(NotesUnavailable)
}

fn decode_note(value: Value) -> Result(#(String, Value), String) {
  use key <- result.try(wire.string_field(value, "key"))
  use held <- result.try(wire.field(value, "value"))
  Ok(#(key, held))
}

fn map_error(error: CallError) -> NotesError {
  case error {
    Denied(code:, message:) -> NotesDenied(code:, message:)
    Unreachable(reason:) -> NotesUnavailable(reason:)
  }
}
