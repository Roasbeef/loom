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
//// An item carries the time its question was put to a person when the record has
//// one (protocol-change/124), the network the call would have and the session's
//// policy today, and for a `code_mode` program the capability call and command
//// its source names (protocol-change/120, the addendum on approval words). A
//// record from before the raise time was stored has none, and no page words an
//// age for it. The tool, the preview, the reason, the call and the command were
//// written by the harness and the model, so a page draws them as text nodes
//// only.
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

/// The network a call would have if it were approved.
pub type Network {
  /// The session's policy lets tools out, or the call wants a network grant.
  NetworkOn

  /// Tools have no network and the call asks for none.
  NetworkOff
}

/// The sandbox and network the session runs its tools under today, in the
/// daemon's words.
pub type Policy {
  Policy(
    /// `workspace-write` or `read-only`.
    sandbox: String,
    /// `off`, `loopback`, `proxy` or `on`.
    network: String,
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
    /// When the question was put to a person, in Unix milliseconds. Absent for
    /// a record written before the field existed, and a page then draws no age.
    raised_at: Option(Int),
    /// The network the call would have, when the daemon could tell.
    network: Option(Network),
    /// The session's sandbox and network policy at the moment of the read.
    policy: Option(Policy),
    /// The capability a `code_mode` program calls, such as `proc.run`. Text
    /// taken from a program's source.
    call: Option(String),
    /// The command that program runs, one line. Text taken from a program's
    /// source, drawn as a text node.
    command: Option(String),
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
    raised_at: case number(fields, "raised_at") {
      Ok(at) if at >= 0 -> option.Some(at)
      Ok(_) | Error(Nil) -> option.None
    },
    network: case text(fields, "network") {
      Ok("on") -> option.Some(NetworkOn)
      Ok("off") -> option.Some(NetworkOff)
      Ok(_) | Error(Nil) -> option.None
    },
    policy: option.from_result(policy(fields)),
    call: option.from_result(text(fields, "call")),
    command: option.from_result(text(fields, "command")),
  ))
}

/// The policy object of an item, or nothing for a member that is not one with
/// both words.
fn policy(fields: List(#(String, JsonValue))) -> Result(Policy, Nil) {
  use inner <- result.try(list.key_find(fields, "policy"))
  use inner <- result.try(object(inner))
  use sandbox <- result.try(text(inner, "sandbox"))
  use network <- result.map(text(inner, "network"))
  Policy(sandbox:, network:)
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
