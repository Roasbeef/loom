//// What children on other orchestrators cost a session, as a snapshot carries
//// it and a status bar words it (protocol-change/084, phase 2).
////
//// A child that runs on another orchestrator spends tokens there, and its
//// parent's session sees none of them in its own usage ledger. The daemon sums
//// the usage each settled child reported (`client/remote_child.usage_by_orchestrator`)
//// and sends one entry for each orchestrator in the full snapshot's optional
//// `remote_usage` field, so a status bar and the context panel can show what
//// the session has spent elsewhere beside what it has spent here. The field is
//// additive: a daemon that has no remote children omits it, a client that does
//// not know it ignores it, and an absent field decodes to no entries.
////
//// The figures are the other orchestrator's own, priced by its gateway, and a
//// host shows tokens and leaves the dollar figure to the clients that want it.
//// The orchestrator's name is configuration, not model text, but it is drawn as
//// a text node all the same.
////
//// ## Flow
////
//// `encode` and `decode` are the wire form of one entry, `decode_all` reads the
//// optional list a snapshot body carries, and `tokens` is the figure a total is
//// built from. The words a status bar shows are in the remote usage words module, apart
//// from this module because they need the roster's count labels, which sit above
//// the protocol in the import graph.

import core/json.{type JsonValue}
import gleam/int
import gleam/list
import gleam/result

/// The tokens and dollar cost the settled children of one orchestrator used.
///
/// Constructor invariants: every count is nonnegative, which `decode` checks.
pub type RemoteUsage {
  RemoteUsage(
    /// The `[orchestrators.<name>]` the children ran on.
    orchestrator: String,
    /// Uncached input tokens.
    input: Int,
    /// Generated tokens.
    output: Int,
    /// Input tokens served from the provider cache.
    cache_read: Int,
    /// Input tokens written to the provider cache.
    cache_write: Int,
    /// The cost in dollars, priced by the orchestrator that ran the children.
    cost: Float,
  )
}

/// The tokens one entry counts against a budget: input plus output, the figure a
/// goal's budget and a spawner's day cap both use.
///
/// ## Examples
///
/// ```gleam
/// assert remote_usage.tokens(RemoteUsage("box", 100, 20, 5, 7, 0.5)) == 120
/// ```
pub fn tokens(usage: RemoteUsage) -> Int {
  usage.input + usage.output
}

/// An entry as its wire object.
///
/// ## Examples
///
/// ```gleam
/// // remote_usage.encode(RemoteUsage("box", 100, 20, 5, 7, 0.5))
/// // == {"orchestrator": "box", "input": 100, "output": 20, "cache_read": 5,
/// //     "cache_write": 7, "cost": 0.5}
/// ```
pub fn encode(usage: RemoteUsage) -> JsonValue {
  json.Object([
    #("orchestrator", json.String(usage.orchestrator)),
    #("input", json.Int(usage.input)),
    #("output", json.Int(usage.output)),
    #("cache_read", json.Int(usage.cache_read)),
    #("cache_write", json.Int(usage.cache_write)),
    #("cost", json.Float(usage.cost)),
  ])
}

/// One entry from its wire object. A missing or mistyped field, a negative
/// count and an empty orchestrator name are each an error, so a damaged entry is
/// reported and never read as zero spend.
///
/// ## Examples
///
/// ```gleam
/// assert remote_usage.decode(remote_usage.encode(usage)) == Ok(usage)
/// ```
pub fn decode(value: JsonValue) -> Result(RemoteUsage, String) {
  case value {
    json.Object(fields) -> {
      use orchestrator <- result.try(
        case list.key_find(fields, "orchestrator") {
          Ok(json.String(name)) if name != "" -> Ok(name)
          Ok(_) | Error(Nil) ->
            Error("remote_usage.orchestrator must be a nonempty string")
        },
      )
      use input <- result.try(count(fields, "input"))
      use output <- result.try(count(fields, "output"))
      use cache_read <- result.try(count(fields, "cache_read"))
      use cache_write <- result.try(count(fields, "cache_write"))
      use cost <- result.map(case list.key_find(fields, "cost") {
        Ok(json.Float(cost)) if cost >=. 0.0 -> Ok(cost)
        Ok(json.Int(cost)) if cost >= 0 -> Ok(int.to_float(cost))
        Ok(_) | Error(Nil) ->
          Error("remote_usage.cost must be a nonnegative number")
      })
      RemoteUsage(
        orchestrator:,
        input:,
        output:,
        cache_read:,
        cache_write:,
        cost:,
      )
    }
    _ -> Error("remote_usage entry must be an object")
  }
}

/// The optional `remote_usage` list of a snapshot body: no entries when the field
/// is absent, which is every daemon that has no remote children and every daemon
/// that predates the field, and an error when it is present and malformed.
///
/// ## Examples
///
/// ```gleam
/// assert remote_usage.decode_all([]) == Ok([])
/// ```
pub fn decode_all(
  fields: List(#(String, JsonValue)),
) -> Result(List(RemoteUsage), String) {
  case list.key_find(fields, "remote_usage") {
    Error(Nil) -> Ok([])
    Ok(json.Array(items)) -> list.try_map(items, decode)
    Ok(_) -> Error("remote_usage must be an array")
  }
}

// A nonnegative integer field.
fn count(
  fields: List(#(String, JsonValue)),
  name: String,
) -> Result(Int, String) {
  case list.key_find(fields, name) {
    Ok(json.Int(value)) if value >= 0 -> Ok(value)
    Ok(_) | Error(Nil) ->
      Error("remote_usage." <> name <> " must be a nonnegative integer")
  }
}
