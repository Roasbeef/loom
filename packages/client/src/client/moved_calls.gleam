//// The calls a session held pending when it moved away from a directory on its
//// source orchestrator (protocol-change/107, addendum of 2026-11-16).
////
//// A session that moves while a turn is running is stopped with a tool call
//// in flight. The stop kills the turn before the call's outcome is staged, so
//// the file the destination receives holds the call as effect-pending. When the
//// session worked in a directory on the source, the call ran there, under a
//// local placement, and no executor ever saw it. The destination places the
//// session on an executor, and its recovery asks that executor's ledger, which
//// would answer with a fence that the call never started. That answer is true
//// for the executor and false for the session: the call ran and may have
//// written files. For a call that must not run twice it is the harmful
//// direction, because a model told "did not run" runs it again.
////
//// ## What is recorded, and when
////
//// The checkout step of the move (`client/move_checkout`) writes this cell in
//// the same commit as its own progress cell, while the session is stopped and
//// before the file is cut. It lists every call that the file holds
//// effect-pending with the policy `ReplayNever`, by operation, step and source
//// index. The pending set cannot change while the session is stopped, and the
//// destination is told of the session only after the checkout step is done, so
//// every file a destination activates from a local source carries the list.
//// Each write recomputes the list from the file, so a move that was abandoned
//// and asked for again records the calls pending at the later attempt.
////
//// ## What the destination does with it
////
//// `workspace.recover_by_placement` answers a listed call with
//// `OutcomeUnknown` and does not ask the executor. That is the answer a local
//// session gives the same call after a restart in place, and the answer an
//// owner-side call already gets. A call dispatched under a local placement had
//// no route to any executor, so there is no stale `Run` for a fence to stop.
//// `ReplaySafe` calls are not listed: the executor's "no row" sends them to the
//// planner's replay, which is correct for a call that is safe to repeat.
////
//// ## Why an old list is harmless
////
//// A listed key is pending again only if the same operation, step and index
//// are dispatched again. Keys are never reused, and a `ReplayNever` orphan is
//// never replayed, so once the destination stages a listed call's outcome the
//// key stays settled. A list left in the file by an earlier move therefore never
//// describes a call the destination dispatched itself, and those calls keep the
//// executor's fenced answer.

import core/ids
import core/json.{type JsonValue}
import core/register
import core/tx
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import machine/codec
import machine/operation
import runtime/effects.{type ToolRun}
import session/session.{type Session}
import storage/storage

/// The reserved key of the cell. The `client/` prefix keeps it out of reach of
/// a model's `put_fact`.
pub const key = "client/move/interrupted"

/// One call that was pending when the session stopped for a move.
pub type Call {
  Call(
    /// The operation's id, as text.
    op: String,
    /// The tool batch's step, the turn id of the response that asked for it.
    step: String,
    /// The call's index in that response's content.
    source_index: Int,
  )
}

/// The write that records the `ReplayNever` calls the file holds pending. The
/// caller commits it with its own cell, while no writer holds the file.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(write) = moved_calls.record(opened)
/// // storage.commit(opened.store, tx.Tx(writes: [write, ..], expected: []))
/// ```
pub fn record(opened: Session) -> Result(tx.Write, String) {
  use calls <- result.map(pending(opened))
  tx.SetRegister(register.FactCustom, key, register.value(encode(calls)))
}

/// The calls the cell lists, or none when the session never moved from a
/// directory. A cell that is present and malformed is an error.
///
/// ## Examples
///
/// ```gleam
/// // moved_calls.read(opened) == Ok([]) for a session that never moved
/// ```
pub fn read(opened: Session) -> Result(List(Call), String) {
  // An absent cell is a session that never moved from a directory.
  case storage.get_register(opened.store, register.FactCustom, key) {
    Error(error) ->
      Error("the moved calls record is unreadable: " <> string.inspect(error))
    Ok(None) -> Ok([])
    Ok(Some(cell)) -> decode(cell.value.payload)
  }
}

/// Whether `run` is a call that was pending when the session moved from a
/// directory, so that no executor can know what it did. A cell that cannot be
/// read answers yes: the caller then says the outcome is unknown, which is
/// never false, where "did not run" could be.
///
/// ## Examples
///
/// ```gleam
/// // moved_calls.listed(opened, run)
/// ```
pub fn listed(opened: Session, run: ToolRun) -> Bool {
  let call =
    Call(
      op: ids.op_id_to_string(run.operation),
      step: run.step_id,
      source_index: run.source_index,
    )

  // An unreadable cell takes the answer that cannot be false.
  case read(opened) {
    Ok(calls) -> list.contains(calls, call)
    Error(_reason) -> True
  }
}

// Every effect-pending `ReplayNever` call of every operation in the file. Only
// a run in its tools phase holds calls, and only an effect-pending call may have
// started.
/// The calls of the file that a move would leave with an unknown outcome.
fn pending(opened: Session) -> Result(List(Call), String) {
  use cells <- result.try(
    storage.list_registers(opened.store, register.OpState, None)
    |> result.map_error(fn(error) {
      "the operations are unreadable: " <> string.inspect(error)
    }),
  )
  use states <- result.map(
    list.try_map(cells, fn(cell) {
      let #(op, held) = cell
      codec.decode_state(held.value.payload)
      |> result.map(fn(state) { #(op, state) })
      |> result.map_error(fn(report) {
        "the operation " <> op <> " is corrupt: " <> string.inspect(report)
      })
    }),
  )
  list.flat_map(states, fn(found) { calls_of(found.0, found.1) })
}

/// The effect-pending `ReplayNever` calls of one operation's state.
fn calls_of(op: String, state: operation.OperationState) -> List(Call) {
  // A run outside its tools phase, and any state that is not a run, hold no call.
  case state {
    operation.RunState(phase: operation.Tools(batch:), ..) ->
      list.filter_map(batch.calls, fn(call) {
        // Only a call that may have started can have done anything.
        case call {
          operation.CallEffectPending(
            source_index:,
            replay: operation.ReplayNever,
            ..,
          ) -> Ok(Call(op:, step: batch.turn_id, source_index:))
          operation.CallEffectPending(replay: operation.ReplaySafe, ..)
          | operation.CallPlanned(..)
          | operation.CallOutcomeReady(..)
          | operation.CallCompleted(..) -> Error(Nil)
        }
      })
    operation.RunState(..)
    | operation.CompactionState(..)
    | operation.NavigationState(..) -> []
  }
}

// --- the cell ----------------------------------------------------------------

/// The cell's payload: an object holding the list of calls.
fn encode(calls: List(Call)) -> JsonValue {
  json.Object([
    #(
      "calls",
      json.Array(
        list.map(calls, fn(call) {
          json.Object([
            #("op", json.String(call.op)),
            #("step", json.String(call.step)),
            #("source_index", json.Int(call.source_index)),
          ])
        }),
      ),
    ),
  ])
}

/// Reads the cell's payload, refusing one this module did not write.
fn decode(payload: JsonValue) -> Result(List(Call), String) {
  {
    use fields <- result.try(members(payload, "the record"))
    use items <- result.try(calls_member(fields))
    list.try_map(items, decode_call)
  }
  |> result.map_error(fn(reason) {
    "the moved calls record is malformed: " <> reason
  })
}

/// The members of a JSON object, or an error naming what was not one.
fn members(
  value: JsonValue,
  what: String,
) -> Result(List(#(String, JsonValue)), String) {
  // Any other JSON value was written by something else.
  case value {
    json.Object(fields) -> Ok(fields)
    _ -> Error(what <> " is not an object")
  }
}

/// The record's list of calls.
fn calls_member(
  fields: List(#(String, JsonValue)),
) -> Result(List(JsonValue), String) {
  // A member of another type is as good as an absent one.
  case list.key_find(fields, "calls") {
    Ok(json.Array(items)) -> Ok(items)
    _ -> Error("calls is not a list")
  }
}

/// One call of the cell's list.
fn decode_call(item: JsonValue) -> Result(Call, String) {
  use fields <- result.try(members(item, "a call"))

  // A call is the three members this module writes, each of its own type.
  case
    list.key_find(fields, "op"),
    list.key_find(fields, "step"),
    list.key_find(fields, "source_index")
  {
    Ok(json.String(op)), Ok(json.String(step)), Ok(json.Int(source_index)) ->
      Ok(Call(op:, step:, source_index:))
    _, _, _ -> Error("a call lacks its op, step or source_index")
  }
}
