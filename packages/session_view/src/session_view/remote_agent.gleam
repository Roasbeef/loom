//// A child that runs on another orchestrator, as an agent strip shows it
//// (protocol-change/090, observation of a remote child).
////
//// A local child is a strand of the session, and its row on the strip comes
//// from the session's own capture (`agent_view`). A child on another
//// orchestrator has no strand here. What the parent's session holds is the
//// stub the daemon keeps for it (`client/remote_child`), with the standing the
//// spawn has reached and the newest glance the other orchestrator pushed. The
//// daemon projects each stub into one `RemoteAgent` and sends the list in a
//// `remote_children` snapshot, which it pushes when a stub changes and once
//// when a client subscribes. This module is that list's wire form.
//// `agent_roster.remote_rows` turns each entry into an `agent_view.Row` with
//// its placement set, so the terminal's strip and the web view's chips list a
//// remote child beside the local ones and call it `<child> @ <orchestrator>`.
//// That rule sits in the roster because the protocol imports this module and
//// `agent_view` imports the protocol.
////
//// Nothing here talks to the other orchestrator. The row is drawn from what
//// the stub already holds, so while the parent's daemon cannot reach the
//// orchestrator the strip keeps the last glance and says how old it is, and
//// no host sends anything to refresh it. The age is measured on one clock:
//// the daemon reports how long ago, on its own clock, the glance reached it,
//// and a host adds the time it has itself held the report (`agent_roster`).
////
//// Every string is model text or configuration from another machine and is
//// drawn as a text node. The decoder bounds the list and every string, so a
//// damaged or oversized snapshot is refused and never drawn in part.
////
//// ## Flow
////
//// `encode` → `standing_word` → `within_bound` → `decode_all` → `decode`
////
//// 1. `encode` is the daemon's wire form of one entry, with `standing_word`
////    for its standing, and `within_bound` cuts a list to what one pushed
////    frame may carry.
//// 2. `decode_all` reads the bounded list a remote children snapshot carries,
////    through `decode` for each entry.

import core/json.{type JsonValue}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// The most entries one snapshot carries. A parent's remote children are
/// bounded by the fan-out caps of the orchestrators that run them, so the
/// bound is a decoder's limit and not a figure a session reaches.
pub const max_children = 64

/// The most bytes a row's words carry: its title, summary and model. A strip
/// draws one line of each, so the daemon clips them to this.
pub const max_text_bytes = 256

/// The most bytes a row's names carry: the child's strand name, the parent
/// strand and the orchestrator. Names are identities and are never clipped,
/// so this is only the decoder's bound.
pub const max_name_bytes = 512

/// The most bytes the encoded list of one snapshot carries. The list reaches a
/// client as one pushed frame, which the gateway bounds at 64 KiB, so the list
/// leaves room under it for the envelope.
pub const list_bytes_limit = 60_000

/// How far a remote child's spawn has got, as the parent's stub records it.
pub type Standing {
  /// The spawn was sent and not yet answered. The child may exist.
  Starting

  /// The orchestrator started the child and its deadline has not passed.
  Running

  /// The orchestrator started the child and its deadline has passed without a
  /// join reporting how it ended.
  Expired

  /// A join reported the child's run finished normally.
  Completed

  /// A join reported the child's run ended any other way.
  Stopped

  /// The orchestrator refused the spawn and made no child.
  Refused
}

/// One remote child as a strip lists it.
pub type RemoteAgent {
  RemoteAgent(
    /// The strand name the child has on the other orchestrator. It is the
    /// row's identity, and it never names a strand of this session, because a
    /// remote child's name holds the reference `^` that no local strand does.
    id: String,
    /// The parent strand in this session that asked for the child.
    parent: String,
    /// The `[orchestrators.<name>]` the child runs on.
    orchestrator: String,
    /// How far the spawn has got.
    standing: Standing,
    /// The newest glance's title, or the purpose the spawn asked for.
    title: String,
    /// The newest glance's one-line summary, empty before the first.
    summary: String,
    /// The child's context size from the newest glance, zero when unknown.
    tokens: Int,
    /// The catalogue name of the model the child runs on, empty while the
    /// spawn is unanswered.
    model: String,
    /// How long before the snapshot, on the daemon's clock, the newest glance
    /// reached the parent's daemon, or `None` before the first glance.
    age_ms: Option(Int),
  )
}

/// An entry as its wire object.
///
/// ## Examples
///
/// ```gleam
/// // remote_agent.encode(agent)
/// // == {"id": "sub:^main/build-1a2b", "parent": "main", "orchestrator": "box",
/// //     "standing": "running", "title": "build", "summary": "", "tokens": 0,
/// //     "model": "fast", "age_ms": null}
/// ```
pub fn encode(agent: RemoteAgent) -> JsonValue {
  json.Object([
    #("id", json.String(agent.id)),
    #("parent", json.String(agent.parent)),
    #("orchestrator", json.String(agent.orchestrator)),
    #("standing", json.String(standing_word(agent.standing))),
    #("title", json.String(agent.title)),
    #("summary", json.String(agent.summary)),
    #("tokens", json.Int(agent.tokens)),
    #("model", json.String(agent.model)),
    #("age_ms", case agent.age_ms {
      Some(age) -> json.Int(age)
      None -> json.Null
    }),
  ])
}

/// The wire word of a standing.
///
/// ## Examples
///
/// ```gleam
/// assert remote_agent.standing_word(remote_agent.Running) == "running"
/// ```
pub fn standing_word(standing: Standing) -> String {
  case standing {
    Starting -> "starting"
    Running -> "running"
    Expired -> "expired"
    Completed -> "completed"
    Stopped -> "stopped"
    Refused -> "refused"
  }
}

/// The longest head of `agents` whose encoded list fits `list_bytes_limit`,
/// and at most `max_children` entries. The daemon sends what this keeps, so a
/// session with many children whose words are at their bounds still has a
/// list that one pushed frame can carry; the rest are left off the strip.
///
/// ## Examples
///
/// ```gleam
/// assert remote_agent.within_bound([]) == []
/// ```
pub fn within_bound(agents: List(RemoteAgent)) -> List(RemoteAgent) {
  keep_within(list.take(agents, max_children), [], 2)
}

// Walks the entries in order, adding each one's encoded bytes and the comma
// before it, and stops before the one that would pass the bound. The two bytes
// the walk starts from are the brackets of the array.
fn keep_within(
  agents: List(RemoteAgent),
  kept: List(RemoteAgent),
  bytes: Int,
) -> List(RemoteAgent) {
  case agents {
    [] -> list.reverse(kept)
    [agent, ..rest] -> {
      let size = string.byte_size(json.to_string(encode(agent))) + 1
      case bytes + size > list_bytes_limit {
        True -> list.reverse(kept)
        False -> keep_within(rest, [agent, ..kept], bytes + size)
      }
    }
  }
}

/// The bounded `remote_children` list of a snapshot body. The list is
/// required: the snapshot exists to carry it, and an empty list is the
/// daemon's positive statement that the session has no remote child.
///
/// ## Examples
///
/// ```gleam
/// assert remote_agent.decode_all([#("remote_children", json.Array([]))]) == Ok([])
/// ```
pub fn decode_all(
  fields: List(#(String, JsonValue)),
) -> Result(List(RemoteAgent), String) {
  case list.key_find(fields, "remote_children") {
    Ok(json.Array(items)) ->
      case list.length(items) > max_children {
        True -> Error("remote_children holds more entries than its bound")
        False -> list.try_map(items, decode)
      }
    Ok(json.Object(..))
    | Ok(json.String(..))
    | Ok(json.Int(..))
    | Ok(json.Float(..))
    | Ok(json.Bool(..))
    | Ok(json.Null) -> Error("remote_children must be an array")
    Error(Nil) -> Error("remote_children is required")
  }
}

/// One entry from its wire object. A missing or mistyped field, an unknown
/// standing, a negative count and a string over its bound are each an
/// error, so a damaged entry is refused and never drawn in part.
///
/// ## Examples
///
/// ```gleam
/// assert remote_agent.decode(remote_agent.encode(agent)) == Ok(agent)
/// ```
pub fn decode(value: JsonValue) -> Result(RemoteAgent, String) {
  use fields <- result.try(case value {
    json.Object(fields) -> Ok(fields)
    json.Array(..)
    | json.String(..)
    | json.Int(..)
    | json.Float(..)
    | json.Bool(..)
    | json.Null -> Error("a remote child must be an object")
  })
  use id <- result.try(text(fields, "id", max_name_bytes))
  use Nil <- result.try(case id {
    "" -> Error("remote_children.id must not be empty")
    _ -> Ok(Nil)
  })
  use parent <- result.try(text(fields, "parent", max_name_bytes))
  use orchestrator <- result.try(text(fields, "orchestrator", max_name_bytes))
  use standing <- result.try(standing_of(fields))
  use title <- result.try(text(fields, "title", max_text_bytes))
  use summary <- result.try(text(fields, "summary", max_text_bytes))
  use tokens <- result.try(count(fields, "tokens"))
  use model <- result.try(text(fields, "model", max_text_bytes))
  use age_ms <- result.map(case list.key_find(fields, "age_ms") {
    Ok(json.Null) -> Ok(None)
    Ok(json.Int(age)) if age >= 0 -> Ok(Some(age))
    Ok(_) | Error(Nil) ->
      Error("remote_children.age_ms must be a nonnegative integer or null")
  })
  RemoteAgent(
    id:,
    parent:,
    orchestrator:,
    standing:,
    title:,
    summary:,
    tokens:,
    model:,
    age_ms:,
  )
}

fn standing_of(fields: List(#(String, JsonValue))) -> Result(Standing, String) {
  case list.key_find(fields, "standing") {
    Ok(json.String("starting")) -> Ok(Starting)
    Ok(json.String("running")) -> Ok(Running)
    Ok(json.String("expired")) -> Ok(Expired)
    Ok(json.String("completed")) -> Ok(Completed)
    Ok(json.String("stopped")) -> Ok(Stopped)
    Ok(json.String("refused")) -> Ok(Refused)
    Ok(_) | Error(Nil) -> Error("remote_children.standing is not a standing")
  }
}

// A string field within `bound` bytes.
fn text(
  fields: List(#(String, JsonValue)),
  name: String,
  bound: Int,
) -> Result(String, String) {
  case list.key_find(fields, name) {
    Ok(json.String(value)) ->
      case string.byte_size(value) > bound {
        True -> Error("remote_children." <> name <> " is over its bound")
        False -> Ok(value)
      }
    Ok(_) | Error(Nil) ->
      Error("remote_children." <> name <> " must be a string")
  }
}

fn count(
  fields: List(#(String, JsonValue)),
  name: String,
) -> Result(Int, String) {
  case list.key_find(fields, name) {
    Ok(json.Int(value)) if value >= 0 -> Ok(value)
    Ok(_) | Error(Nil) ->
      Error("remote_children." <> name <> " must be a nonnegative integer")
  }
}
