//// The `[executors.<name>]` tables: the machines an orchestrator may place a
//// session's workspace on (protocol-change/078).
////
//// A session created with an `executor` names a workspace that is registered
//// on another machine, so the orchestrator has to know which executors exist
//// before it reserves anything. This module is that list and nothing else. An
//// executor is a name the operator chooses and the peer node that answers to
//// it, and the node has to be one of the `[[distribution.peers]]` the operator
//// already pinned, so a reference here can only point at a machine the daemon
//// trusts as an Erlang peer. It opens no connection and reads no file; the
//// slices that attach a workspace use the node this table names.
////
//// Like `[distribution]` and `[peers]`, the daemon reads the table once, when
//// it starts, and never rereads it: a running daemon's executors are the ones
//// its owner configured before it listened. The catalogue parser validates the
//// same table (`client/catalog`), so a typo is refused wherever the file is
//// read rather than only at startup.
////
//// Absence is the safe answer. With no `[executors]` table every creation that
//// names an executor is refused, and every creation that does not is exactly
//// what it was before this table existed.

import client/distribution
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import storage/catalogue
import tom

/// One configured executor: the name sessions refer to it by and the pinned
/// peer node that serves it.
pub type Executor {
  Executor(
    /// The `[executors.<name>]` key, which satisfies
    /// `catalogue.is_executor_name`.
    name: String,
    /// The peer's full node name, one of the `[[distribution.peers]]` nodes.
    node: String,
  )
}

/// Reads the executors from configuration text, for callers that hold no
/// parsed document.
///
/// ## Examples
///
/// ```gleam
/// assert executors.parse("") == Ok([])
/// ```
pub fn parse(text: String) -> Result(List(Executor), String) {
  use document <- result.try(
    tom.parse(text)
    |> result.map_error(fn(error) {
      "invalid daemon configuration: " <> string.inspect(error)
    }),
  )
  from_document(document)
}

/// Validates the `[executors.<name>]` tables of a parsed configuration
/// document and returns the executors sorted by name.
///
/// Omission is an empty list. Each table names exactly one key, `node`, and
/// the node must be a configured distribution peer, so a document with
/// executors and no `[distribution]` table is refused rather than left to fail
/// when a session is created. A name outside the executor grammar, a key it
/// does not know and a value of the wrong type are each refused with the key's
/// full name, so the owner can find the line.
///
/// ## Examples
///
/// ```gleam
/// assert executors.from_document(dict.new()) == Ok([])
/// ```
pub fn from_document(
  document: Dict(String, tom.Toml),
) -> Result(List(Executor), String) {
  case dict.get(document, "executors") {
    Error(Nil) -> Ok([])
    Ok(tom.Table(tables)) -> {
      use configured <- result.try(
        dict.to_list(tables)
        |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
        |> list.try_map(fn(entry) { row(entry.0, entry.1) }),
      )
      use peers <- result.try(peer_nodes(document))
      use Nil <- result.try(
        list.try_each(configured, fn(executor) {
          case list.contains(peers, executor.node) {
            True -> Ok(Nil)
            False ->
              Error(
                "executors."
                <> executor.name
                <> ".node "
                <> executor.node
                <> " is not a node in [[distribution.peers]]",
              )
          }
        }),
      )
      Ok(configured)
    }
    Ok(_) -> Error("executors must be a table of [executors.<name>] tables")
  }
}

/// Finds the executor with this name.
///
/// ## Examples
///
/// ```gleam
/// assert executors.find([], "build-box") == Error(Nil)
/// ```
pub fn find(configured: List(Executor), name: String) -> Result(Executor, Nil) {
  list.find(configured, fn(executor) { executor.name == name })
}

// The pinned peers an executor may name. An executor with no distribution
// table has no peer to be served by, which is a different mistake from a
// mistyped node, so it is worded as the missing table.
fn peer_nodes(
  document: Dict(String, tom.Toml),
) -> Result(List(String), String) {
  use found <- result.try(distribution.from_document(document))
  case found {
    Some(settings) -> Ok(distribution.peer_nodes(settings))
    None -> Error("executors needs a [distribution] table naming its peers")
  }
}

fn row(name: String, value: tom.Toml) -> Result(Executor, String) {
  use Nil <- result.try(case catalogue.is_executor_name(name) {
    True -> Ok(Nil)
    False ->
      Error(
        "executors."
        <> name
        <> " is not an executor name: lowercase letters, numbers, _ and -, "
        <> "starting with a letter, at most 32 characters",
      )
  })
  case value {
    tom.Table(fields) -> {
      use Nil <- result.try(known_keys(
        dict.keys(fields),
        ["node"],
        "[executors." <> name <> "]",
      ))
      case dict.get(fields, "node") {
        Ok(tom.String(node)) -> Ok(Executor(name:, node:))
        Ok(_) -> Error("executors." <> name <> ".node must be a string")
        Error(Nil) -> Error("executors." <> name <> ".node is required")
      }
    }
    _ -> Error("executors." <> name <> " must be a table")
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
