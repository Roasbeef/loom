//// The `[orchestrators.<name>]` tables: the other orchestrators this daemon
//// asks which of them owns a session it has no record of
//// (protocol-change/078, phase 3).
////
//// Two orchestrators each keep their own catalogue, and a session is created
//// on, and owned by, the orchestrator the client was connected to. A client
//// that connects to the other one and names that session gets no answer from
//// the catalogue, so the daemon has to ask its peers. This module is the list
//// of peers it asks and nothing else. An orchestrator is a name the operator
//// chooses, the peer node that answers to it, and optionally the control
//// address a client uses to reach that machine. The node has to be one of the
//// `[[distribution.peers]]` the operator already pinned, so a reference here
//// can only point at a machine the daemon trusts as an Erlang peer. The table
//// opens no connection and reads no file.
////
//// The address is advertised by the asking side, not by the owner. A daemon
//// binds loopback only, so it has no routable address of its own to announce;
//// whatever reaches it (a tunnel, a Tailscale name, `--ui-origin`) is the
//// operator's knowledge, and it belongs in the file of the daemon that tells a
//// client where to go. The address is optional because a deployment may have
//// no address a client can use, and the refusal then names the orchestrator
//// alone.
////
//// Like `[distribution]` and `[executors]`, the daemon reads the table once,
//// when it starts, and never rereads it. The catalogue parser validates the
//// same table (`client/catalog`), so a typo is refused wherever the file is
//// read. Absence is the safe answer: with no `[orchestrators]` table the
//// daemon asks nobody, and every session it does not know is `not_found`,
//// exactly as before this table existed.
////
//// ## Flow
////
//// `from_document` → `row` → `address_of`
////
//// 1. `from_document` reads the table and requires the distribution table.
//// 2. `row` validates one entry's name and keys.
//// 3. `address_of` reads the optional address, which has to be a control
////    address a client may send a bearer to (`host/claim.remote_address`).
//// 4. `find` and `by_node` resolve a configured orchestrator.

import client/distribution
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/claim
import storage/catalogue
import tom

/// One configured orchestrator.
pub type Orchestrator {
  Orchestrator(
    /// The `[orchestrators.<name>]` key, which satisfies
    /// `catalogue.is_profile_name`. It is the name a `not_owner` refusal
    /// carries.
    name: String,
    /// The peer's full node name, one of the `[[distribution.peers]]` nodes.
    node: String,
    /// The control address a client uses to reach this orchestrator, in the
    /// form `loom --addr` takes, or `None` when the operator configured none.
    address: Option(String),
  )
}

/// An orchestrator that configures no address.
///
/// ## Examples
///
/// ```gleam
/// assert orchestrators.plain("alpha", "alpha@10.0.0.2").address == None
/// ```
pub fn plain(name: String, node: String) -> Orchestrator {
  Orchestrator(name:, node:, address: None)
}

/// Reads the orchestrators from configuration text, for callers that hold no
/// parsed document.
///
/// ## Examples
///
/// ```gleam
/// assert orchestrators.parse("") == Ok([])
/// ```
pub fn parse(text: String) -> Result(List(Orchestrator), String) {
  use document <- result.try(
    tom.parse(text)
    |> result.map_error(fn(error) {
      "invalid daemon configuration: " <> string.inspect(error)
    }),
  )
  from_document(document)
}

/// Validates the `[orchestrators.<name>]` tables of a parsed configuration
/// document and returns the orchestrators sorted by name.
///
/// Omission is an empty list. Each table names `node`, which must be a
/// configured distribution peer, and may give an `address`. A document with
/// orchestrators and no `[distribution]` table is refused rather than left to
/// fail when a session is looked up. A name outside the grammar, a key the
/// table does not know, a value of the wrong type, an address a client could
/// not safely send a bearer to, and two names for one node are each refused
/// with the key's full name, so the owner can find the line.
///
/// ## Examples
///
/// ```gleam
/// assert orchestrators.from_document(dict.new()) == Ok([])
/// ```
pub fn from_document(
  document: Dict(String, tom.Toml),
) -> Result(List(Orchestrator), String) {
  case dict.get(document, "orchestrators") {
    Error(Nil) -> Ok([])
    Ok(tom.Table(tables)) -> {
      use configured <- result.try(
        dict.to_list(tables)
        |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
        |> list.try_map(fn(entry) { row(entry.0, entry.1) }),
      )
      use peers <- result.try(peer_nodes(document))
      use Nil <- result.try(
        list.try_each(configured, fn(orchestrator) {
          case list.contains(peers, orchestrator.node) {
            True -> Ok(Nil)
            False ->
              Error(
                "orchestrators."
                <> orchestrator.name
                <> ".node "
                <> orchestrator.node
                <> " is not a node in [[distribution.peers]]",
              )
          }
        }),
      )
      use Nil <- result.map(distinct_nodes(configured))
      configured
    }
    Ok(_) ->
      Error("orchestrators must be a table of [orchestrators.<name>] tables")
  }
}

/// Finds the orchestrator with this name.
///
/// ## Examples
///
/// ```gleam
/// assert orchestrators.find([], "alpha") == Error(Nil)
/// ```
pub fn find(
  configured: List(Orchestrator),
  name: String,
) -> Result(Orchestrator, Nil) {
  list.find(configured, fn(orchestrator) { orchestrator.name == name })
}

/// Finds the orchestrator that a peer node answers to.
///
/// ## Examples
///
/// ```gleam
/// assert orchestrators.by_node([], "alpha@10.0.0.2") == Error(Nil)
/// ```
pub fn by_node(
  configured: List(Orchestrator),
  node: String,
) -> Result(Orchestrator, Nil) {
  list.find(configured, fn(orchestrator) { orchestrator.node == node })
}

// The pinned peers an orchestrator may name. An orchestrator with no
// distribution table has no peer to be asked, which is a different mistake
// from a mistyped node, so it is worded as the missing table.
fn peer_nodes(
  document: Dict(String, tom.Toml),
) -> Result(List(String), String) {
  use found <- result.try(distribution.from_document(document))
  case found {
    Some(settings) -> Ok(distribution.peer_nodes(settings))
    None -> Error("orchestrators needs a [distribution] table naming its peers")
  }
}

// Two names for one node would let a lookup answer with whichever name sorts
// first, so the file cannot say it. Names are sorted, so the second of a
// pair is the one reported.
fn distinct_nodes(configured: List(Orchestrator)) -> Result(Nil, String) {
  case configured {
    [] -> Ok(Nil)
    [first, ..rest] ->
      case by_node(rest, first.node) {
        Ok(other) ->
          Error(
            "orchestrators."
            <> other.name
            <> ".node "
            <> other.node
            <> " is already the node of orchestrators."
            <> first.name,
          )
        Error(Nil) -> distinct_nodes(rest)
      }
  }
}

fn row(name: String, value: tom.Toml) -> Result(Orchestrator, String) {
  use Nil <- result.try(case catalogue.is_profile_name(name) {
    True -> Ok(Nil)
    False ->
      Error(
        "orchestrators."
        <> name
        <> " is not an orchestrator name: lowercase letters, numbers, _ and -, "
        <> "starting with a letter, at most 32 characters",
      )
  })
  case value {
    tom.Table(fields) -> {
      use Nil <- result.try(known_keys(
        dict.keys(fields),
        ["node", "address"],
        "[orchestrators." <> name <> "]",
      ))
      use node <- result.try(case dict.get(fields, "node") {
        Ok(tom.String(node)) -> Ok(node)
        Ok(_) -> Error("orchestrators." <> name <> ".node must be a string")
        Error(Nil) -> Error("orchestrators." <> name <> ".node is required")
      })
      use address <- result.map(address_of(fields, "orchestrators." <> name))
      Orchestrator(name:, node:, address:)
    }
    _ -> Error("orchestrators." <> name <> " must be a table")
  }
}

// Reads the optional `address` key of an orchestrator row. `place` is the
// table's full name, such as `orchestrators.alpha`, so a refusal names the key.
//
// The address is the control endpoint a client passes to `loom --addr`, and
// that client sends a bearer to it, so the rule is the one every other remote
// control address meets: `wss` to any host, or `ws` only to a literal loopback
// host, with the path `/v2/control` and no credentials, query or fragment.
fn address_of(
  fields: Dict(String, tom.Toml),
  place: String,
) -> Result(Option(String), String) {
  let words =
    place
    <> ".address must be a control address of the form "
    <> "wss://<host>[:<port>]/v2/control (ws:// only for a loopback host)"
  case dict.get(fields, "address") {
    Error(Nil) -> Ok(None)
    Ok(tom.String(address)) ->
      case claim.remote_address(address) {
        Ok(Nil) -> Ok(Some(address))
        Error(_) -> Error(words)
      }
    Ok(_) -> Error(words)
  }
}

fn known_keys(
  present: List(String),
  allowed: List(String),
  place: String,
) -> Result(Nil, String) {
  case list.find(present, fn(key) { !list.contains(allowed, key) }) {
    Error(Nil) -> Ok(Nil)
    Ok(unknown) ->
      Error(
        "unknown key `"
        <> unknown
        <> "` in "
        <> place
        <> " (allowed: "
        <> string.join(allowed, ", ")
        <> ")",
      )
  }
}
