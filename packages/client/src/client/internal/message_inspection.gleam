//// Caller-owned views over the existing durable delivery stores.
////
//// Inspection never drains a queue. Two captures discover candidate IDs and
//// then copy payloads together with their current ownership cells. Consumption
//// between captures removes an item from the answer rather than exposing an
//// unrelated strand's pending payload. Peer admission history is independent
//// of operation cleanup and continues to mean admission, never model reading.

import core/codec as core_codec
import core/entry
import core/ids
import core/json.{type JsonValue}
import core/message
import core/register
import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import machine/codec
import machine/operation
import session/session
import storage/snapshot
import storage/storage

/// Reads up to twelve currently owned pending inputs without consuming them.
/// `after` is an exclusive ID cursor, empty for the first page. `total` counts
/// current queue membership. Continue through `next` even on an empty page.
/// A concurrent consume can shorten the discovered page; exact lookup remains
/// available for every ID. Oversized answers fail rather than truncate bodies.
///
/// ## Examples
///
/// ```gleam
/// // message_inspection.inbox(session, "main", "", 12)
/// ```
pub fn inbox(
  tree: session.Session,
  strand: String,
  after: String,
  limit: Int,
) -> Result(JsonValue, String) {
  use Nil <- result.try(valid_limit(limit, 12))
  use first <- result.try(capture(tree, strand, []))
  use candidates <- result.try(owned(first, strand))
  let eligible =
    candidates
    |> list.filter(fn(item) { string.compare(item.0, after) == order.Gt })
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  let selected = eligible |> list.take(limit) |> list.map(fn(item) { item.0 })
  let next = case list.length(eligible) > limit, list.last(selected) {
    True, Ok(id) -> json.String(id)
    _, _ -> json.Null
  }
  inspect(tree, strand, selected, next)
}

/// Reads a caller-owned pending input or materialized user input by ID.
/// The second ownership capture also carries the caller's leaf, so consumption
/// between discovery and payload lookup falls through to that same branch.
/// Missing IDs and another strand's inputs return JSON null.
///
/// ## Examples
///
/// ```gleam
/// // message_inspection.inbox_get(session, "main", id)
/// ```
pub fn inbox_get(
  tree: session.Session,
  strand: String,
  id: String,
) -> Result(JsonValue, String) {
  use first <- result.try(capture(tree, strand, []))
  use candidates <- result.try(owned(first, strand))
  let selected = case list.key_find(candidates, id) {
    Ok(_) -> [id]
    Error(Nil) -> []
  }
  use cut <- result.try(capture(tree, strand, selected))
  use current <- result.try(owned(cut, strand))
  case list.key_find(current, id), selected {
    Ok(queue), [_] -> pending_row(cut, id, queue) |> result.try(bounded)
    _, _ -> transcript_get(tree, cut, strand, id)
  }
}

fn pending_row(
  cut: snapshot.Cut,
  id: String,
  queue: String,
) -> Result(JsonValue, String) {
  use payload <- result.try(cell(cut, register.PendingEntry, id))
  use decoded <- result.try(
    codec.decode_pending_entry(payload) |> result.map_error(string.inspect),
  )
  Ok(
    json.Object([
      #("id", json.String(id)),
      #("queue", json.String(queue)),
      #("payload", codec.encode_pending_entry(decoded)),
    ]),
  )
}

fn inspect(
  tree: session.Session,
  strand: String,
  selected: List(String),
  next: JsonValue,
) -> Result(JsonValue, String) {
  use cut <- result.try(capture(tree, strand, selected))
  use current <- result.try(owned(cut, strand))
  use rows <- result.try(
    list.try_map(selected, fn(id) {
      case list.key_find(current, id) {
        Error(Nil) -> Ok(None)
        Ok(queue) -> pending_row(cut, id, queue) |> result.map(Some)
      }
    }),
  )
  let rows = list.filter_map(rows, option.to_result(_, Nil))
  bounded(
    json.Object([
      #("revision", json.Int(cut.next_seq - 1)),
      #("items", json.Array(rows)),
      #("total", json.Int(list.length(current))),
      #("next", next),
    ]),
  )
}

fn capture(
  tree: session.Session,
  strand: String,
  pending: List(String),
) -> Result(snapshot.Cut, String) {
  tree.snapshot_reader.capture(
    snapshot.Plan(
      selections: [
        snapshot.ExactKey(register.StrandState, strand),
        snapshot.ExactKey(register.StrandLeaf, strand),
        ..list.map(pending, fn(id) {
          snapshot.ExactKey(register.PendingEntry, id)
        })
      ],
      references: [
        snapshot.FromField(
          register.StrandState,
          "currentOperationId",
          register.OpState,
        ),
      ],
      recent_entries: 0,
    ),
    5000,
  )
  |> result.map_error(string.inspect)
}

fn owned(
  cut: snapshot.Cut,
  strand: String,
) -> Result(List(#(String, String)), String) {
  use payload <- result.try(cell(cut, register.StrandState, strand))
  use state <- result.try(
    codec.decode_strand_state(payload) |> result.map_error(string.inspect),
  )
  let next = tagged(state.pending_next_run, "next_run")
  case state.current_operation {
    None -> Ok(next)
    Some(id) -> {
      use payload <- result.try(cell(
        cut,
        register.OpState,
        ids.op_id_to_string(id),
      ))
      use op <- result.try(
        codec.decode_state(payload) |> result.map_error(string.inspect),
      )
      Ok(list.append(next, run_inputs(op)))
    }
  }
}

fn run_inputs(state: operation.OperationState) -> List(#(String, String)) {
  case state {
    operation.RunState(inbox:, control:, ..) -> {
      let cancelled = case control {
        operation.Running -> []
        operation.CancelRequested(drained_steer:, drained_follow_up:, ..) ->
          list.append(
            tagged(drained_steer, "cancelled_steer"),
            tagged(drained_follow_up, "cancelled_follow_up"),
          )
      }
      list.flatten([
        tagged(inbox.steer, "steer"),
        tagged(inbox.follow_up, "follow_up"),
        cancelled,
      ])
    }
    operation.CompactionState(..) | operation.NavigationState(..) -> []
  }
}

fn tagged(ids: List(ids.EntryId), queue: String) -> List(#(String, String)) {
  list.map(ids, fn(id) { #(ids.entry_id_to_string(id), queue) })
}

fn cell(
  cut: snapshot.Cut,
  namespace: register.RegisterNs,
  key: String,
) -> Result(JsonValue, String) {
  cut.cells
  |> list.find(fn(cell) { cell.namespace == namespace && cell.key == key })
  |> result.map(fn(cell) { cell.register.value.payload })
  |> result.map_error(fn(_) { "requested cell is absent" })
}

/// Refuses a result exceeding the capability frame budget without truncation.
///
/// ## Examples
///
/// ```gleam
/// assert message_inspection.bounded(json.Null) == Ok(json.Null)
/// ```
pub fn bounded(value: JsonValue) -> Result(JsonValue, String) {
  case string.byte_size(json.to_string(value)) <= 194_560 {
    True -> Ok(value)
    False ->
      Error("message inspection exceeds 194560 bytes; use an exact lookup")
  }
}

/// Validates the advertised finite page size before reading storage.
///
/// ## Examples
///
/// ```gleam
/// assert message_inspection.valid_limit(1, 12) == Ok(Nil)
/// ```
pub fn valid_limit(limit: Int, maximum: Int) -> Result(Nil, String) {
  case limit > 0 && limit <= maximum {
    True -> Ok(Nil)
    False -> Error("message inspection limit is out of range")
  }
}

// The captured leaf is the ownership boundary for immutable history. Looking
// up an arbitrary entry first supplies only its sequence; its payload is never
// returned unless the caller's branch index proves membership at that leaf.
fn transcript_get(
  tree: session.Session,
  cut: snapshot.Cut,
  strand: String,
  text: String,
) -> Result(JsonValue, String) {
  use id <- result.try(
    ids.parse_entry_id(text) |> result.map_error(string.inspect),
  )
  use leaf <- result.try(leaf(cut, strand))
  case leaf {
    None -> Ok(json.Null)
    Some(leaf) -> {
      use entries <- result.try(
        storage.get_entries(tree.store, [id])
        |> result.map_error(string.inspect),
      )
      case dict.get(entries, id) {
        Error(Nil) -> Ok(json.Null)
        Ok(found) -> {
          let query =
            storage.branch_scan(leaf)
            |> storage.branch_cursor(found.seq + 1)
            |> storage.branch_limit(1)
          use own <- result.try(
            storage.scan_branch(tree.store, query)
            |> result.map_error(string.inspect),
          )
          case own {
            [
              entry.MessageEntry(
                id: own_id,
                message: message.UserMessage(..),
                ..,
              ) as record,
            ]
              if own_id == id
            -> bounded(history_row(record))
            _ -> Ok(json.Null)
          }
        }
      }
    }
  }
}

/// Pages materialized user inputs on the caller's captured conversation branch.
/// `before` is an exclusive sequence cursor; zero starts at the current leaf.
/// `next` advances across scanned message entries even on an empty input page.
///
/// ## Examples
///
/// ```gleam
/// // message_inspection.history(session, "main", 0, 64)
/// ```
pub fn history(
  tree: session.Session,
  strand: String,
  before: Int,
  limit: Int,
) -> Result(JsonValue, String) {
  use Nil <- result.try(valid_limit(limit, 64))
  use Nil <- result.try(case before >= 0 {
    True -> Ok(Nil)
    False -> Error("history cursor must be nonnegative")
  })
  use cut <- result.try(capture(tree, strand, []))
  use leaf <- result.try(leaf(cut, strand))
  case leaf {
    None -> Ok(json.Object([#("items", json.Array([])), #("next", json.Null)]))
    Some(leaf) -> {
      let query =
        storage.branch_scan(leaf)
        |> storage.branch_kind(storage.Message)
        |> storage.branch_limit(limit + 1)
      let query = case before {
        0 -> query
        _ -> storage.branch_cursor(query, before)
      }
      use scanned <- result.try(
        storage.scan_branch(tree.store, query)
        |> result.map_error(string.inspect),
      )
      let page = list.take(scanned, limit)
      let rows =
        list.filter_map(page, fn(record) {
          case record {
            entry.MessageEntry(message: message.UserMessage(..), ..) ->
              Ok(history_row(record))
            _ -> Error(Nil)
          }
        })
      let next = case list.length(scanned) > limit, list.last(page) {
        True, Ok(record) -> json.Int(record.seq)
        _, _ -> json.Null
      }
      bounded(json.Object([#("items", json.Array(rows)), #("next", next)]))
    }
  }
}

fn leaf(
  cut: snapshot.Cut,
  strand: String,
) -> Result(Option(ids.EntryId), String) {
  use payload <- result.try(cell(cut, register.StrandLeaf, strand))
  register.read_leaf(register.value(payload))
  |> result.map_error(string.inspect)
}

fn history_row(record: entry.Entry) -> JsonValue {
  json.Object([
    #("id", json.String(ids.entry_id_to_string(record.id))),
    #("queue", json.String("materialized")),
    #("entry", core_codec.encode_entry(record)),
  ])
}
