//// What a session's pending approvals are, as Home holds them: the tool, a
//// bounded rendering of the action, what held it and the grants it wants
//// (protocol-change/120, the addendum "Approval evidence").
////
//// The daemon answers `approval.read` with a list of pending records at the
//// revision of each. This module is the types and one total decoder from that
//// reply. It draws nothing, decides nothing and performs no I/O. An approval is
//// decided on the session's own page, from the card that page draws, and this
//// evidence is only what a person reads on the way there.
////
//// The record carries no raise time, so no item here has one and no page words
//// an age for an approval. The tool, the preview and the reason were written by
//// the harness and the model, so a page draws them as text nodes only.
////
//// ## Flow
////
//// `decode` → `item` → `wanted`
////
//// 1. `decode` reads the reply's count and its items.
//// 2. `item` reads one record alone, so one damaged record costs only itself.
//// 3. `wanted` reads one wanted grant as a kind and a detail.

import core/json.{type JsonValue}
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/result

/// One grant a held call wants.
pub type Wanted {
  Wanted(
    /// `network`, `writable_root`, `readable_root`, `env`, `limit`, `scratch`
    /// or `other`.
    kind: String,
    /// A path, a mode, a name or a limit, cut by the daemon. Model-influenced
    /// text, drawn as a text node.
    detail: String,
  )
}

/// One pending approval.
pub type Item {
  Item(
    /// The escalation's identifier, a comparison key that is never drawn into
    /// an attribute.
    id: String,
    /// The revision of the record when it was read.
    revision: Int,
    /// The tool the call was made through, or empty when the record names none.
    tool: String,
    /// A bounded rendering of the call's arguments, when the record has one.
    preview: Option(String),
    /// What held the call: `policy` or `execution`, or empty.
    source: String,
    /// The denial's reason, or empty.
    reason: String,
    /// The grants the call wants, in order.
    wanted: List(Wanted),
    /// How many times the record has put its question to a person.
    asked: Int,
  )
}

/// What one read says: how many records are pending and the items it kept.
pub type Evidence {
  Evidence(
    /// Every pending record the session holds.
    count: Int,
    /// The records the reply carries, never more than `count`.
    items: List(Item),
  )
}

/// What the page has of a session's approval evidence.
pub type Seen {
  /// The daemon answered with this evidence.
  Seen(evidence: Evidence)

  /// The daemon refused or did not answer. The words are its fixed ones.
  Unseen(words: String)
}

/// The evidence a reply carries, or nothing for a reply that is not one.
///
/// ## Examples
///
/// ```gleam
/// assert approval_evidence.decode(json.Null) == Error(Nil)
/// ```
pub fn decode(value: JsonValue) -> Result(Evidence, Nil) {
  use fields <- result.try(object(value))
  use inner <- result.try(list.key_find(fields, "approvals"))
  use inner <- result.try(object(inner))

  // A count is a whole number of records, and anything else is no count.
  use count <- result.try(case list.key_find(inner, "count") {
    Ok(json.Int(count)) if count >= 0 -> Ok(count)
    Ok(_) | Error(Nil) -> Error(Nil)
  })

  // Each item decodes alone, and one that does not is left out.
  let items = case list.key_find(inner, "items") {
    Ok(json.Array(raw)) -> list.filter_map(raw, item)
    Ok(_) | Error(Nil) -> []
  }

  Ok(Evidence(count: int.max(count, list.length(items)), items:))
}

/// One record, or nothing for one missing its identifier or revision.
fn item(value: JsonValue) -> Result(Item, Nil) {
  use fields <- result.try(object(value))
  use id <- result.try(text(fields, "id"))
  use revision <- result.try(number(fields, "revision"))

  Ok(Item(
    id:,
    revision:,
    tool: option.unwrap(option.from_result(text(fields, "tool")), ""),
    preview: option.from_result(text(fields, "preview")),
    source: option.unwrap(option.from_result(text(fields, "source")), ""),
    reason: option.unwrap(option.from_result(text(fields, "reason")), ""),
    wanted: case list.key_find(fields, "wanted") {
      Ok(json.Array(raw)) -> list.filter_map(raw, wanted)
      Ok(_) | Error(Nil) -> []
    },
    asked: option.unwrap(option.from_result(number(fields, "asked")), 0),
  ))
}

/// One wanted grant, or nothing for one with no kind.
fn wanted(value: JsonValue) -> Result(Wanted, Nil) {
  use fields <- result.try(object(value))
  use kind <- result.map(text(fields, "kind"))
  Wanted(
    kind:,
    detail: option.unwrap(option.from_result(text(fields, "detail")), ""),
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
