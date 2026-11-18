//// What a session's pending approvals are, worded as evidence a person can read
//// on Home before opening the session's own page (protocol-change/120, the
//// addendum "Approval evidence").
////
//// An approval is decided on the session's page, from the card that page draws,
//// and nowhere else. This module is the read half only: it lists the session's
//// pending escalation records with the revision of each, and for each the tool,
//// a bounded rendering of the action, what held it and which grants it wants.
//// It never decides, consumes or claims a record.
////
//// The record carries no raise time. Its scope names the operation that held
//// the claim, and an operation can run for hours before it raises, so no age is
//// worded from it (120 rejects the same idea for the feed). An item therefore
//// has no `raised_at`, and a page prints no age for an approval.
////
//// ## Flow
////
//// `read` → `item` → `wanted_line`
////
//// 1. `read` lists the escalation records and keeps the pending ones in id
////    order, at most `max_items`, with the total as a count.
//// 2. `item` words one record at the revision of its cell.
//// 3. `wanted_line` turns one wanted grant, in the escalation vocabulary, into a
////    kind and a short detail.
////
//// ## Bounds
////
//// Every text is cut on a grapheme boundary (`core/glance.clip`), at most
//// `max_wanted` grants are listed for a record, and the number of records is
//// `max_items`, so a reply stays far under one frame whatever the session
//// holds. The tool, preview and denial reason were written by the harness and
//// the model, so the page draws them as text nodes and nowhere else.

import core/glance
import core/json.{type JsonValue}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import runtime/api
import runtime/escalation.{type Escalation}

/// The most pending records one read lists.
pub const max_items = 4

/// The most wanted grants one record lists.
pub const max_wanted = 6

/// The longest tool name, in bytes.
pub const tool_bytes = 64

/// The longest action preview, in bytes. The record bounds its own preview, so
/// this is a ceiling on what the reply repeats.
pub const preview_bytes = 400

/// The longest denial reason, in bytes.
pub const reason_bytes = 300

/// The longest detail of one wanted grant, in bytes.
pub const detail_bytes = 160

/// The session's pending approvals as one reply object:
/// `{"approvals": {"count", "items": [...]}}`. A record that cannot be read at
/// its cell is left out of the items and still counted.
///
/// ## Examples
///
/// ```gleam
/// // approval_evidence.read(runtime)
/// ```
pub fn read(runtime: api.Runtime) -> Result(JsonValue, String) {
  use records <- result.map(
    api.escalations(runtime) |> result.map_error(string.inspect),
  )

  // Only a record that still awaits a decision is evidence for a person.
  let pending =
    records
    |> list.filter(fn(record) { record.status == escalation.Pending })
    |> list.sort(fn(left, right) { string.compare(left.id, right.id) })
  let items =
    pending
    |> list.take(max_items)
    |> list.filter_map(fn(record) { item(runtime, record) })

  json.Object([
    #(
      "approvals",
      json.Object([
        #("count", json.Int(list.length(pending))),
        #("items", json.Array(items)),
      ]),
    ),
  ])
}

/// One pending record worded at the revision of its cell, or nothing when the
/// cell cannot be read again, which happens only when it was decided between
/// the listing and this read.
fn item(runtime: api.Runtime, record: Escalation) -> Result(JsonValue, Nil) {
  use cell <- result.map(
    api.escalation_cell(runtime, record.id) |> result.replace_error(Nil),
  )
  let record = cell.record

  json.Object([
    #("id", json.String(glance.clip(record.id, 64))),
    #("revision", json.Int(cell.seq)),
    #("tool", json.String(glance.clip(tool_of(record), tool_bytes))),
    #("preview", case record.preview {
      Some(text) -> json.String(glance.clip(text, preview_bytes))
      None -> json.Null
    }),
    #("source", json.String(source_of(record.denial))),
    #(
      "reason",
      json.String(glance.clip(reason_of(record.denial), reason_bytes)),
    ),
    #("wanted", json.Array(wanted_of(record.denial))),
    #("asked", json.Int(record.asked)),
  ])
}

/// The tool the record was raised for. A record raised through a door that
/// names no action has none, which the page words as unknown.
fn tool_of(record: Escalation) -> String {
  option.unwrap(record.tool, "")
}

/// The denial's source word, `policy` or `execution`, or empty when the stored
/// denial has none.
fn source_of(denial: JsonValue) -> String {
  field_text(denial, "source")
}

/// The denial's reason, or empty when the stored denial has none.
fn reason_of(denial: JsonValue) -> String {
  field_text(denial, "reason")
}

/// A text member of a stored object, or empty.
fn field_text(value: JsonValue, name: String) -> String {
  case value {
    json.Object(fields) ->
      case list.key_find(fields, name) {
        Ok(json.String(text)) -> text
        Ok(_) | Error(Nil) -> ""
      }
    json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> ""
  }
}

/// The wanted grants of a denial as `{kind, detail}` objects, in order and at
/// most `max_wanted`.
fn wanted_of(denial: JsonValue) -> List(JsonValue) {
  let wanted = case denial {
    json.Object(fields) ->
      case list.key_find(fields, "wanted") {
        Ok(json.Array(items)) -> items
        Ok(_) | Error(Nil) -> []
      }
    json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> []
  }

  wanted |> list.take(max_wanted) |> list.map(wanted_line)
}

/// One wanted grant as a kind and a short detail: the path of a root, the mode
/// of a network, the name of an environment variable, a limit's field and
/// value, a scratch's word. A grant of a shape this module does not know is
/// `other`, with nothing to say about it.
///
/// ## Examples
///
/// ```gleam
/// // approval_evidence.wanted_line(json.Object([#("grant", json.String("env")), #("name", json.String("HOME"))]))
/// ```
pub fn wanted_line(grant: JsonValue) -> JsonValue {
  let kind = field_text(grant, "grant")
  let detail = case kind {
    "writable_root" | "readable_root" -> field_text(grant, "path")
    "env" -> field_text(grant, "name")
    "scratch" -> field_text(grant, "scratch")
    "limit" -> field_text(grant, "field") <> " " <> field_number(grant, "value")
    "network" -> network_mode(grant)
    _ -> ""
  }

  json.Object([
    #("kind", json.String(glance.clip(kind, 32))),
    #("detail", json.String(glance.clip(detail, detail_bytes))),
  ])
}

/// The mode of a network grant: `off`, `loopback`, `full` or `proxy`.
fn network_mode(grant: JsonValue) -> String {
  case grant {
    json.Object(fields) ->
      case list.key_find(fields, "network") {
        Ok(network) -> field_text(network, "mode")
        Error(Nil) -> ""
      }
    json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> ""
  }
}

/// An integer member of a stored object as text, or empty.
fn field_number(value: JsonValue, name: String) -> String {
  case value {
    json.Object(fields) ->
      case list.key_find(fields, name) {
        Ok(json.Int(number)) -> json.to_string(json.Int(number))
        Ok(_) | Error(Nil) -> ""
      }
    json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> ""
  }
}
