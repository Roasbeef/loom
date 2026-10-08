//// The orchestrator's record of its scope on an executor: which incarnation
//// it attached under, and how the last close of that incarnation ended
//// (protocol-change/078, "Execution ledger").
////
//// The executor keeps one ledger row per session, the scope, and gives it one
//// monotonic incarnation. The orchestrator is the only party that can decide
//// when a session is reopened, so it keeps the other half of that fact in its
//// own store, beside the conversation, as one reserved cell. A session that is
//// restored on a different machine from a backup of that store carries the
//// cell with it, which is what lets the next orchestrator attach at the right
//// incarnation.
////
//// ## What an open attaches at
////
//// Three cases cover every stored shape, and they are the executor's own
//// rules seen from this side:
////
//// | The cell holds | Attach at | The executor does |
//// | --- | --- | --- |
//// | nothing | 1 | creates the scope |
//// | a clean close | the stored incarnation plus one | reopens the scope |
//// | anything else | the stored incarnation | rebinds the open scope |
////
//// A close that ended with unknown cleanup, a close that was never recorded
//// because the orchestrator died first, and a plain open all fall in the last
//// row. The executor decides what to do with them: it rebinds an open scope
//// and refuses a scope whose cleanup it could not prove. The orchestrator
//// never guesses that a scope is reusable.
////
//// ## Writes bypass the writer, on purpose
////
//// Both writes commit straight to the session's store, the way
//// `client/session_git` does, and so are legal only while no runtime owns the
//// store. The open is recorded after the attach and before the runtime opens.
//// The close is recorded by the workspace's custody cleanup, which runs after
//// the runtime and the services have drained and before the store is
//// released. The cell is never written while a writer is running.

import client/remote/protocol.{type CloseOutcome}
import core/json.{type JsonValue}
import core/register
import core/tx
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import session/session.{type Session}
import storage/storage

/// The reserved key of the cell. The `client/` prefix keeps it out of reach of
/// a model's `put_fact`.
pub const key = "client/remote/scope"

/// What the orchestrator knows of its scope on the executor.
pub type Scope {
  Scope(
    /// The incarnation of the latest attach.
    incarnation: Int,
    /// How that incarnation's close ended, or `None` while it has not been
    /// closed or the close was not recorded.
    closed: Option(CloseOutcome),
  )
}

/// Reads the cell. A cell that is present and malformed is an error and not
/// absence, because attaching at incarnation one over a scope that is really
/// at five would only be refused by the executor with a less useful message.
///
/// ## Examples
///
/// ```gleam
/// // scope.read(opened) == Ok(None) for a session that never attached
/// ```
pub fn read(opened: Session) -> Result(Option(Scope), String) {
  case storage.get_register(opened.store, register.FactCustom, key) {
    Error(error) ->
      Error("the remote scope record is unreadable: " <> string.inspect(error))
    Ok(None) -> Ok(None)
    Ok(Some(cell)) -> decode(cell.value.payload) |> result.map(Some)
  }
}

/// The incarnation an open attaches at, from what the cell holds.
///
/// ## Examples
///
/// ```gleam
/// assert scope.attach_at(None) == 1
/// assert scope.attach_at(Some(scope.Scope(3, Some(protocol.AllRetired)))) == 4
/// assert scope.attach_at(Some(scope.Scope(3, None))) == 3
/// ```
pub fn attach_at(found: Option(Scope)) -> Int {
  case found {
    None -> 1
    Some(Scope(incarnation:, closed: Some(protocol.AllRetired))) ->
      incarnation + 1
    Some(Scope(incarnation:, closed: Some(protocol.UnknownCleanup(..)))) ->
      incarnation
    Some(Scope(incarnation:, closed: None)) -> incarnation
  }
}

/// Records the scope, replacing the cell. See the module doc for when this may
/// be called.
///
/// ## Examples
///
/// ```gleam
/// // scope.write(opened, scope.Scope(incarnation: 1, closed: None))
/// ```
pub fn write(opened: Session, scope: Scope) -> Result(Nil, String) {
  storage.commit(
    opened.store,
    tx.Tx(
      writes: [
        tx.SetRegister(register.FactCustom, key, register.value(encode(scope))),
      ],
      expected: [],
    ),
  )
  |> result.replace(Nil)
  |> result.map_error(fn(error) {
    "the remote scope record was not written: " <> string.inspect(error)
  })
}

fn encode(scope: Scope) -> JsonValue {
  let closed = case scope.closed {
    None -> [#("closed", json.Null)]
    Some(protocol.AllRetired) -> [#("closed", json.String("all_retired"))]
    Some(protocol.UnknownCleanup(count:)) -> [
      #("closed", json.String("unknown")),
      #("unknown_children", json.Int(count)),
    ]
  }
  json.Object([#("incarnation", json.Int(scope.incarnation)), ..closed])
}

fn decode(payload: JsonValue) -> Result(Scope, String) {
  case payload {
    json.Object(fields) -> {
      use incarnation <- result.try(case list.key_find(fields, "incarnation") {
        Ok(json.Int(incarnation)) if incarnation >= 1 -> Ok(incarnation)
        _ -> Error("incarnation is not a positive integer")
      })
      use closed <- result.map(closure(fields))
      Scope(incarnation:, closed:)
    }
    _ -> Error("the record is not an object")
  }
  |> result.map_error(fn(reason) {
    "the remote scope record is malformed: " <> reason
  })
}

fn closure(
  fields: List(#(String, JsonValue)),
) -> Result(Option(CloseOutcome), String) {
  case list.key_find(fields, "closed") {
    Ok(json.Null) | Error(Nil) -> Ok(None)
    Ok(json.String("all_retired")) -> Ok(Some(protocol.AllRetired))
    Ok(json.String("unknown")) ->
      case list.key_find(fields, "unknown_children") {
        Ok(json.Int(count)) if count >= 0 ->
          Ok(Some(protocol.UnknownCleanup(count:)))
        _ -> Error("an unknown close names no count")
      }
    Ok(other) ->
      Error("closed is not a known outcome: " <> string.inspect(other))
  }
}
