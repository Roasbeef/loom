//// The orchestrator's record of its scope on an executor: which executor
//// holds it, which incarnation it attached under, and how the last close of
//// that incarnation ended (protocol-change/078, "Execution ledger").
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
//// ## Which executor
////
//// The cell also names the executor that holds the scope, and it is written
//// before the attach is sent. A session placed in a pool has no executor until
//// its first open picks one, and an attach whose reply is lost may have created
//// a scope the orchestrator never heard about. Naming the executor first means
//// the next open goes back to that machine, where the ledger's rebind makes the
//// retry converge, instead of choosing again and leaving a second scope on
//// another machine. A cell that names an executor is the only candidate the
//// session ever has. A cell from before pools existed names none, and the
//// session's registration, which names exactly one executor, supplies it.
////
//// ## Writes bypass the writer, on purpose
////
//// The writes commit straight to the session's store, the way
//// `client/session_git` does, and so are legal only while no runtime owns the
//// store. The open is recorded after the connection and before the attach, and
//// so before the runtime opens. A first open that an executor refuses for
//// capacity removes the cell again, because that refusal proves no scope was
//// created. The close is recorded by the workspace's custody cleanup, which runs
//// after the runtime and the services have drained and before the store is
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
import storage/catalogue
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
    /// The `[executors.<name>]` that holds the scope, or `None` in a cell
    /// written before the executor was recorded.
    executor: Option(String),
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
/// assert scope.attach_at(Some(scope.Scope(3, Some(protocol.AllRetired), None)))
///   == 4
/// assert scope.attach_at(Some(scope.Scope(3, None, None))) == 3
/// ```
pub fn attach_at(found: Option(Scope)) -> Int {
  case found {
    None -> 1
    Some(Scope(incarnation:, closed: Some(protocol.AllRetired), ..)) ->
      incarnation + 1
    Some(Scope(incarnation:, closed: Some(protocol.UnknownCleanup(..)), ..)) ->
      incarnation
    Some(Scope(incarnation:, closed: None, ..)) -> incarnation
  }
}

/// The executor a cell names, or `None` when there is no cell or the cell
/// predates the executor field.
///
/// ## Examples
///
/// ```gleam
/// assert scope.executor_of(None) == None
/// assert scope.executor_of(Some(scope.Scope(1, None, Some("box")))) == Some("box")
/// ```
pub fn executor_of(found: Option(Scope)) -> Option(String) {
  option.then(found, fn(cell) { cell.executor })
}

/// Records the scope, replacing the cell. See the module doc for when this may
/// be called.
///
/// ## Examples
///
/// ```gleam
/// // scope.write(opened, scope.Scope(1, None, Some("box")))
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

/// Removes the cell, for a first open that an executor refused for capacity.
///
/// The refusal proves the executor created no scope, so nothing remains to be
/// found again, and keeping a cell that names the full executor would send the
/// next open back to it instead of letting the pool choose. See the module doc
/// for when this may be called.
///
/// ## Examples
///
/// ```gleam
/// // scope.clear(opened)
/// ```
pub fn clear(opened: Session) -> Result(Nil, String) {
  storage.commit(
    opened.store,
    tx.Tx(writes: [tx.DeleteRegister(register.FactCustom, key)], expected: []),
  )
  |> result.replace(Nil)
  |> result.map_error(fn(error) {
    "the remote scope record was not cleared: " <> string.inspect(error)
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
  let executor = case scope.executor {
    None -> []
    Some(name) -> [#("executor", json.String(name))]
  }
  json.Object(
    list.flatten([
      [#("incarnation", json.Int(scope.incarnation))],
      closed,
      executor,
    ]),
  )
}

fn decode(payload: JsonValue) -> Result(Scope, String) {
  case payload {
    json.Object(fields) -> {
      use incarnation <- result.try(case list.key_find(fields, "incarnation") {
        Ok(json.Int(incarnation)) if incarnation >= 1 -> Ok(incarnation)
        _ -> Error("incarnation is not a positive integer")
      })
      use closed <- result.try(closure(fields))
      use executor <- result.map(named_executor(fields))
      Scope(incarnation:, closed:, executor:)
    }
    _ -> Error("the record is not an object")
  }
  |> result.map_error(fn(reason) {
    "the remote scope record is malformed: " <> reason
  })
}

// A cell from before the executor was recorded has no such field, which reads
// as no executor. A field that is present has to be a name the configuration
// could have given, so a damaged cell is an error and never a different
// executor.
fn named_executor(
  fields: List(#(String, JsonValue)),
) -> Result(Option(String), String) {
  case list.key_find(fields, "executor") {
    Error(Nil) | Ok(json.Null) -> Ok(None)
    Ok(json.String(name)) ->
      case catalogue.is_executor_name(name) {
        True -> Ok(Some(name))
        False -> Error("executor is not an executor name")
      }
    Ok(other) -> Error("executor is not a string: " <> string.inspect(other))
  }
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
