//// What the daemon's `sessions.attention` row says one session needs from a
//// person, as the home page holds it (protocol-change/120).
////
//// The daemon answers one row for each session it read, and the page needs
//// typed values to draw: how many asks wait, which finds are open, which
//// strands stopped on a failure. This module is those types and the one total
//// decoder from the row's JSON. It draws nothing and performs no I/O.
////
//// ## Flow
////
//// `decode_row` → `section` → `ask`, `find` and `stuck_item`
////
//// 1. The daemon decodes each reply row with `decode_row`. A row that is not
////    a row of a state this page knows, or whose counts are damaged, is no row.
//// 2. `section` reads one list's count and decodes its items alone with `ask`,
////    `find` or `stuck_item`, so one damaged item costs only itself and the
////    count still says how many were read.
////
//// ## What every field means
////
//// A `count` is the number of records the session read, and `items` may hold
//// fewer, because the row sheds items to fit its bound. A page words a count
//// as what was read and never as what exists. Every text here, a head and a
//// strand name, is untrusted model text, drawn only as a text node.

import core/attention
import core/json.{type JsonValue}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// One open ask routed to the owner.
pub type Ask {
  Ask(
    /// The ask's identifier, `ask-` and ten hexadecimal digits.
    id: String,
    /// The strand that asked, cut by the daemon.
    strand: String,
    /// When the ask was recorded, in Unix milliseconds.
    created_at: Int,
    /// The first question's prompt, cut to 120 bytes.
    head: String,
    /// How many questions the ask holds.
    questions: Int,
  )
}

/// One open find.
pub type Find {
  Find(
    /// The find's identifier, `find-` and ten hexadecimal digits.
    id: String,
    /// The strand that noticed it, cut by the daemon.
    strand: String,
    /// What the agent calls it.
    kind: attention.FindKind,
    /// When the find was recorded, in Unix milliseconds.
    created_at: Int,
    /// The find's text, cut to 120 bytes.
    head: String,
    /// The path the find is about, when the row carries it.
    path: Option(String),
    /// The line in `path`, which a row carries only with its path.
    line: Option(Int),
  )
}

/// One strand that stopped on a failed run and has not run since
/// (protocol-change/120, the addendum on stuck strands).
pub type Stuck {
  Stuck(
    /// The strand, cut by the daemon.
    strand: String,
    /// When the failed response was recorded, in Unix milliseconds: the exact
    /// time of the entry the run ended on. Absent when the daemon had no such
    /// entry to read, and for a daemon that predates the field. A page that has
    /// no time draws none.
    failed_at: Option(Int),
    /// The run's error code, the harness's own word (`provider_error`,
    /// `context_overflow`, ...) and never model text. Absent for a daemon that
    /// predates the field.
    reason: Option(String),
    /// The provider's minimum wait before a retry, in milliseconds, when the
    /// failed response carried one.
    retry_after_ms: Option(Int),
    /// The strand that spawned this one, which is session text and drawn as
    /// text only. Absent when the daemon read no lineage for it.
    parent: Option(String),
  )
}

/// A count of the records a session read, and the ones the row has room for.
pub type Section(item) {
  Section(
    /// Every record of the kind that was read.
    count: Int,
    /// The items the row kept, newest first. Never more than `count`.
    items: List(item),
  )
}

/// What one running session needs from a person.
pub type Row {
  Row(
    /// The creation time of the oldest open ask routed to the owner, or nothing
    /// when there is none. It is the age of an ask and says nothing about an
    /// approval.
    waiting_since: Option(Int),
    /// The open asks routed to the owner.
    asks: Section(Ask),
    /// The open finds.
    finds: Section(Find),
    /// The stuck strands.
    stuck: Section(Stuck),
  )
}

/// The row a reply carries for one session, or nothing for a row that is not an
/// `ok` row. A row whose state this page does not know, `unknown` included,
/// was not read, and is treated as no row.
///
/// ## Examples
///
/// ```gleam
/// assert attention_feed.decode_row(json.Object([#("state", json.String("unknown"))]))
///   == Error(Nil)
/// ```
pub fn decode_row(value: JsonValue) -> Result(Row, Nil) {
  use fields <- result.try(object(value))
  use state <- result.try(list.key_find(fields, "state"))

  // Only an `ok` row was read; any other state is no row.
  use Nil <- result.try(case state {
    json.String("ok") -> Ok(Nil)
    json.String(_)
    | json.Object(_)
    | json.Array(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error(Nil)
  })

  use asks <- result.try(section(fields, "asks", ask))
  use finds <- result.try(section(fields, "finds", find))
  use stuck <- result.map(section(fields, "stuck", stuck_item))
  Row(waiting_since: option_int(fields, "waiting_since"), asks:, finds:, stuck:)
}

/// A section of the row: its count, and the items that decode.
fn section(
  fields: List(#(String, JsonValue)),
  name: String,
  decode: fn(JsonValue) -> Result(item, Nil),
) -> Result(Section(item), Nil) {
  use inner <- result.try(list.key_find(fields, name))
  use inner <- result.try(object(inner))

  // A count is a whole number of records.
  use count <- result.try(case list.key_find(inner, "count") {
    Ok(json.Int(count)) if count >= 0 -> Ok(count)
    Ok(_) | Error(Nil) -> Error(Nil)
  })

  // Each item decodes alone, and one that does not is left out.
  let items = case list.key_find(inner, "items") {
    Ok(json.Array(raw)) -> list.filter_map(raw, decode)
    Ok(_) | Error(Nil) -> []
  }

  // A count below the items it came with could only be a damaged row, and the
  // honest reading is the larger.
  Ok(Section(count: int.max(count, list.length(items)), items:))
}

/// An ask item, or nothing for one missing a field.
fn ask(value: JsonValue) -> Result(Ask, Nil) {
  use fields <- result.try(object(value))
  use id <- result.try(text(fields, "id"))
  use strand <- result.try(text(fields, "strand"))
  use created_at <- result.try(number(fields, "created_at"))
  use head <- result.try(text(fields, "head"))
  use questions <- result.map(number(fields, "questions"))
  Ask(id:, strand:, created_at:, head:, questions:)
}

/// A find item, or nothing for one missing a field or naming a kind this page
/// does not know.
fn find(value: JsonValue) -> Result(Find, Nil) {
  use fields <- result.try(object(value))
  use id <- result.try(text(fields, "id"))
  use strand <- result.try(text(fields, "strand"))
  use kind <- result.try(text(fields, "kind"))
  use kind <- result.try(attention.parse_find_kind(kind))
  use created_at <- result.try(number(fields, "created_at"))
  use head <- result.map(text(fields, "head"))
  let path = option_text(fields, "path")

  // A line without its path is a line of nothing, so it is dropped with it.
  let line = case path {
    Some(_) -> option_int(fields, "line")
    None -> None
  }

  Find(id:, strand:, kind:, created_at:, head:, path:, line:)
}

/// A stuck item, or nothing for one without a strand.
fn stuck_item(value: JsonValue) -> Result(Stuck, Nil) {
  use fields <- result.try(object(value))
  use strand <- result.map(text(fields, "strand"))
  Stuck(
    strand:,
    failed_at: option_int(fields, "failed_at"),
    reason: option_text(fields, "reason"),
    retry_after_ms: option_int(fields, "retry_after_ms"),
    parent: option_text(fields, "parent"),
  )
}

/// The fields of an object.
fn object(value: JsonValue) -> Result(List(#(String, JsonValue)), Nil) {
  case value {
    json.Object(fields) -> Ok(fields)
    json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error(Nil)
  }
}

/// A string field.
fn text(
  fields: List(#(String, JsonValue)),
  name: String,
) -> Result(String, Nil) {
  case list.key_find(fields, name) {
    Ok(json.String(value)) -> Ok(value)
    Ok(_) | Error(Nil) -> Error(Nil)
  }
}

/// An integer field.
fn number(
  fields: List(#(String, JsonValue)),
  name: String,
) -> Result(Int, Nil) {
  case list.key_find(fields, name) {
    Ok(json.Int(value)) -> Ok(value)
    Ok(_) | Error(Nil) -> Error(Nil)
  }
}

/// A string field that may be absent, or damaged, which is the same.
fn option_text(
  fields: List(#(String, JsonValue)),
  name: String,
) -> Option(String) {
  option.from_result(text(fields, name))
}

/// An integer field that may be absent, or damaged, which is the same.
fn option_int(fields: List(#(String, JsonValue)), name: String) -> Option(Int) {
  option.from_result(number(fields, name))
}
