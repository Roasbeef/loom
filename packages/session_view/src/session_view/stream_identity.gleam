//// A streamed response hands its presentation to one reserved durable entry.
//// Provider completion precedes that entry's publication, so completion alone
//// cannot remove text which the reader has already seen. Older servers and
//// summary requests carry no response entry and retain their existing behavior.

import core/ids
import core/json
import gleam/option.{type Option, None}

/// Reads the reserved response entry from a generation or poll identity.
///
/// Unknown identity shapes stay opaque. A malformed identifier cannot acquire
/// ownership of a durable transcript entry.
///
/// ## Examples
///
/// ```gleam
/// assert response_entry("legacy-request") == None
/// ```
@internal
pub fn response_entry(identity: String) -> Option(ids.EntryId) {
  let parsed = json.parse(identity)
  case parsed {
    Ok(json.Array([
      json.String(kind),
      json.String(_),
      json.Int(attempt),
      json.String(entry),
    ]))
      if attempt >= 0 && { kind == "generation" || kind == "poll" }
    -> ids.parse_entry_id(entry) |> option.from_result
    _ -> None
  }
}
