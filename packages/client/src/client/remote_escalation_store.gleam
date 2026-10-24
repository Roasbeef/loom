//// Where a parent session files the requests of its children on other
//// orchestrators (protocol-change/089).
////
//// A child on the box that is refused by its sandbox raises an escalation record
//// there, and the box tells the parent's orchestrator (`ChildEscalation`). The
//// parent session files what it hears under `remote-escalation/{orchestrator}/{id}`,
//// one cell for each request, holding the protocol's own record
//// (`protocol.encode_escalation`) with the orchestrator as its placement. The
//// gateway reads these cells to show them, and the cut a terminal or a page
//// reads selects the ones still `pending`, exactly as it selects the session's
//// own.
////
//// ## Newest `seq` wins
////
//// The box sends a record each time it changes: raised, re-raised, decided. They
//// are separate messages from separate processes, and distribution orders only
//// the messages of one sender to one receiver, so a decided record may be
//// followed by a late copy of the pending one that raised it. The record's `seq`
//// is the box's own register sequence for it and only grows, so `keep` writes a
//// record only if its `seq` is above the filed one, under a compare-and-set on
//// the cell. An older or equal record is acknowledged and changes nothing, which
//// is also what makes a resend harmless.
////
//// Nothing here is under the session's own `escalation/` prefix. That prefix is
//// scanned and spent by this session's tool clearance, and a question that
//// belongs to another machine must never be spendable here.
////
//// ## Flow
////
//// `keep` → `find` → `all` → `clear`
////
//// 1. `keep` files a record the box sent, if it is newer than the filed one.
//// 2. `find` reads one request by the identity its clients were shown, and `all`
////    reads every request of the session.
//// 3. `clear` removes the requests filed for a spawn the orchestrator refused, so
////    a card whose child never existed does not wait for an answer nobody can
////    use. A child that finished keeps its requests: the box still takes a
////    decision on them, and the decision wakes the child into a run that
////    spends an approval by re-issuing the call.

import client/protocol.{type EscalationRecord}
import client/remote_escalation
import core/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import runtime/api

/// The largest record `keep` files, in bytes of its JSON. A record is bounded by
/// the box (a preview of two kilobytes and a short grant list), so this only
/// bounds a box that is not the one we know.
pub const max_record_bytes = 65_536

/// How many times `keep` rereads and tries again after losing a race to another
/// write of the same cell. The cell has one writer in practice, the parent's
/// Agency.
const attempts = 3

/// Files a record the box sent, if it is newer than the one filed.
///
/// The record is filed under the orchestrator the child's stub names, with that
/// name as its placement and its identity prefixed by it. An older or equal
/// `seq` is acknowledged and changes nothing.
///
/// ## Examples
///
/// ```gleam
/// // remote_escalation_store.keep(runtime, "box", record) == Ok(Nil)
/// ```
pub fn keep(
  runtime: api.Runtime,
  orchestrator: String,
  record: EscalationRecord,
) -> Result(Nil, String) {
  let placed = remote_escalation.placed(orchestrator, record)
  let encoded = protocol.encode_escalation(placed)

  // This match resolves string.byte_size(json.to_string(encoded)) before the enclosing validation continues.
  use Nil <- result.try(case string.byte_size(json.to_string(encoded)) {
    size if size <= max_record_bytes -> Ok(Nil)
    _ -> Error("the request is larger than a request may be")
  })

  keep_loop(
    runtime,
    remote_escalation.key(orchestrator, record.escalation_id),
    placed,
    encoded,
    attempts,
  )
}

/// Keep loop keeps this client operation’s decoding or state decision in one place.
fn keep_loop(
  runtime: api.Runtime,
  key: String,
  record: EscalationRecord,
  encoded: json.JsonValue,
  left: Int,
) -> Result(Nil, String) {
  use cell <- result.try(
    api.fact_cell(runtime, key) |> result.map_error(string.inspect),
  )

  // This match resolves cell before the enclosing validation continues.
  let newer = case cell {
    None -> True
    Some(held) ->
      // This match resolves protocol.decode_escalation(held.value) before the surrounding protocol step continues.
      case protocol.decode_escalation(held.value) {
        Ok(filed) -> record.seq > filed.seq

        // A cell that does not decode is replaced: it is a record nobody can
        // show, and the box's copy is the one that can be.
        Error(_) -> True
      }
  }

  // This match resolves newer before the surrounding protocol step continues.
  // This match resolves newer before the enclosing validation continues.
  case newer {
    False -> Ok(Nil)
    True ->
      case
        api.put_reserved_fact_expecting(
          runtime,
          key,
          encoded,
          expected: option.map(cell, fn(held) { held.seq }),
        )
      {
        Ok(_) -> Ok(Nil)
        Error(api.FactConflict(..)) if left > 1 ->
          keep_loop(runtime, key, record, encoded, left - 1)
        Error(error) -> Error(string.inspect(error))
      }
  }
}

/// Removes every request filed for one child of an orchestrator, and answers how
/// many there were. The session calls it when a child's spawn is recorded as
/// refused: no child was made, so an operator answering the card afterwards
/// could only be told the question moved. A request is the child's when its
/// record names the child's strand.
///
/// ## Examples
///
/// ```gleam
/// // remote_escalation_store.clear(runtime, "box", "sub:^main/build-0123") == Ok(1)
/// ```
pub fn clear(
  runtime: api.Runtime,
  orchestrator: String,
  child: String,
) -> Result(Int, String) {
  use cells <- result.try(
    api.reserved_facts(runtime, prefix: remote_escalation.key(orchestrator, ""))
    |> result.map_error(string.inspect),
  )
  let ours =
    list.filter(cells, fn(cell) {
      // This match resolves protocol.decode_escalation(cell.1) before the surrounding protocol step continues.
      // This match resolves protocol.decode_escalation(cell.1) before the enclosing validation continues.
      case protocol.decode_escalation(cell.1) {
        Ok(record) -> record.strand == child
        Error(_) -> False
      }
    })
  use Nil <- result.map(
    list.try_each(ours, fn(cell) {
      api.delete_reserved_fact(runtime, cell.0)
      |> result.map_error(string.inspect)
    }),
  )
  list.length(ours)
}

/// Reads one filed request by the identity its clients were shown
/// (`<orchestrator>/<id>`), or `None` when there is none.
///
/// ## Examples
///
/// ```gleam
/// // remote_escalation_store.find(runtime, "box/policy-ab")
/// ```
pub fn find(
  runtime: api.Runtime,
  client_id: String,
) -> Result(Option(EscalationRecord), String) {
  use cell <- result.try(
    api.fact_cell(runtime, "remote-escalation/" <> client_id)
    |> result.map_error(string.inspect),
  )

  // This match resolves cell before the surrounding protocol step continues.
  // This match resolves cell before the enclosing validation continues.
  case cell {
    None -> Ok(None)
    Some(held) -> protocol.decode_escalation(held.value) |> result.map(Some)
  }
}

/// Every filed request, in key order. A cell that does not decode is left out:
/// it is a request nobody can show.
///
/// ## Examples
///
/// ```gleam
/// // remote_escalation_store.all(runtime) == Ok([])
/// ```
pub fn all(runtime: api.Runtime) -> Result(List(EscalationRecord), String) {
  use cells <- result.map(
    api.reserved_facts(runtime, prefix: api.remote_escalation_fact_prefix)
    |> result.map_error(string.inspect),
  )
  list.filter_map(cells, fn(cell) {
    protocol.decode_escalation(cell.1) |> result.replace_error(Nil)
  })
}
