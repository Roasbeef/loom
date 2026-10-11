//// Applies `client/peer_outbox`'s decisions to the sending session's store.
////
//// Every function here runs inside the sender's Agency actor, reached
//// through the `Outbox*` commands of `client/peer_mail`. That actor handles
//// one command at a time, so a read of a row followed by a write of it cannot
//// interleave with another outbox command. The writes still go through
//// `put_reserved_fact_expecting`, which makes the claim a compare-and-set on
//// the row's sequence: a second writer that is ever added fails with a
//// conflict instead of replacing a row it did not read.
////
//// The rows are reserved facts under `peer_outbox.key_prefix`, so a model
//// cannot read or write them through the blackboard tools, and they are
//// included in the session's own backup and movement with no separate step.

import client/peer_outbox.{type Outcome, type Row}
import core/json.{type JsonValue}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import runtime/api

/// The text of the refusal for a message id that names different content. It
/// is the recipient's own wording (`peer_mail.same_receipt`), so the model
/// reads one message whichever side noticed.
pub const id_reused =
  "message id was already used for different content or target"

/// The text of the refusal for a strand whose rows are all pending.
pub const outbox_full = "outbox_full"

/// Records `wanted` as pending, unless a stored row answers for the message.
///
/// The reply is `{"state": "pending"}` when the caller should attempt
/// delivery, and `{"state": "admitted", "receipt": ...}` when the message was
/// already admitted and the stored receipt is the answer. A new row is written
/// with the compare-and-set that expects the key to be absent, so a repeat
/// that arrives while the first is being written cannot create two rows.
///
/// ## Examples
///
/// ```gleam
/// // peer_outbox_store.claim(runtime, "source-session", row)
/// ```
pub fn claim(
  runtime: api.Runtime,
  source_session: String,
  wanted: Row,
) -> Result(JsonValue, String) {
  let key = peer_outbox.key(wanted.strand, wanted.session, wanted.message_id)
  use cell <- result.try(
    api.fact_cell(runtime, key) |> result.map_error(string.inspect),
  )
  use existing <- result.try(case cell {
    Some(cell) -> peer_outbox.decode(cell.value) |> result.map(Some)
    None -> Ok(None)
  })
  case peer_outbox.claim(existing, wanted, source_session) {
    peer_outbox.Conflict -> Error(id_reused)
    peer_outbox.Resume -> Ok(state_reply("pending"))
    peer_outbox.Settled(receipt:) ->
      Ok(
        json.Object([
          #("state", json.String("admitted")),
          #("receipt", receipt),
        ]),
      )
    peer_outbox.Insert -> {
      use Nil <- result.try(make_room(runtime, existing, wanted.strand))
      let expected = option.map(cell, fn(cell) { cell.seq })
      api.put_reserved_fact_expecting(
        runtime,
        key,
        peer_outbox.encode(wanted),
        expected:,
      )
      |> result.replace(state_reply("pending"))
      |> result.map_error(string.inspect)
    }
  }
}

// A row that replaces a refused one takes no new slot, so only a first row for
// the message is held to the bound.
fn make_room(
  runtime: api.Runtime,
  existing: Option(Row),
  strand: String,
) -> Result(Nil, String) {
  case existing {
    Some(_) -> Ok(Nil)
    None -> {
      use stored <- result.try(rows(runtime))
      case peer_outbox.room(stored, strand) {
        peer_outbox.Free -> Ok(Nil)
        peer_outbox.Full -> Error(outbox_full)
        peer_outbox.Evict(key:) ->
          api.delete_reserved_fact(runtime, key)
          |> result.map_error(string.inspect)
      }
    }
  }
}

/// Records what one delivery attempt found. A row that is already finished,
/// or was removed by an unlink while the attempt was in flight, is left as it
/// is: the first outcome stands.
///
/// ## Examples
///
/// ```gleam
/// // peer_outbox_store.settle(runtime, "main", session, "m1", outcome)
/// ```
pub fn settle(
  runtime: api.Runtime,
  strand: String,
  session: String,
  message_id: String,
  outcome: Outcome,
) -> Result(Nil, String) {
  settle_key(runtime, peer_outbox.key(strand, session, message_id), fn(row) {
    peer_outbox.settle(row, outcome)
  })
  |> result.replace(Nil)
}

/// The rows that still need an attempt, after refusing any that have waited
/// longer than `peer_outbox.pending_ttl_ms`. The drainer asks this at each
/// pass, so expiry needs no timer of its own.
///
/// ## Examples
///
/// ```gleam
/// // peer_outbox_store.due(runtime, now, "owner unreachable")
/// ```
pub fn due(
  runtime: api.Runtime,
  now: Int,
  expired_reason: String,
) -> Result(List(Row), String) {
  use stored <- result.try(rows(runtime))
  list.filter(stored, fn(pair) { peer_outbox.is_pending(pair.1) })
  |> list.try_fold([], fn(due, pair) {
    use expired <- result.try(
      settle_key(runtime, pair.0, fn(row) {
        peer_outbox.expire(row, now, expired_reason)
      }),
    )
    case expired {
      Some(_) -> Ok(due)
      None -> Ok([pair.1, ..due])
    }
  })
  |> result.map(list.reverse)
}

/// The receipt of an admitted message, or `Null` when this session has no
/// admitted row for it.
///
/// ## Examples
///
/// ```gleam
/// // peer_outbox_store.receipt(runtime, "main", session, "m1")
/// ```
pub fn receipt(
  runtime: api.Runtime,
  strand: String,
  session: String,
  message_id: String,
) -> Result(JsonValue, String) {
  use cell <- result.try(
    api.fact_cell(runtime, peer_outbox.key(strand, session, message_id))
    |> result.map_error(string.inspect),
  )
  case cell {
    None -> Ok(json.Null)
    Some(cell) -> {
      use row <- result.try(peer_outbox.decode(cell.value))
      case row.state {
        peer_outbox.Admitted(receipt:) -> Ok(receipt)
        peer_outbox.Pending(..) | peer_outbox.Refused(..) -> Ok(json.Null)
      }
    }
  }
}

/// Deletes the pending rows for one link, which the owner has just removed. A
/// message the owner has withdrawn authority for must not be delivered later.
/// Finished rows stay, because they are the sender's record of what happened.
///
/// ## Examples
///
/// ```gleam
/// // peer_outbox_store.forget_pending(runtime, "main", session, "main")
/// ```
pub fn forget_pending(
  runtime: api.Runtime,
  strand: String,
  session: String,
  target_strand: String,
) -> Result(Nil, String) {
  use stored <- result.try(rows(runtime))
  list.filter(stored, fn(pair) {
    let row = pair.1
    peer_outbox.is_pending(row)
    && row.strand == strand
    && row.session == session
    && row.target_strand == target_strand
  })
  |> list.try_each(fn(pair) {
    api.delete_reserved_fact(runtime, pair.0)
    |> result.map_error(string.inspect)
  })
}

// Reads one row, applies `change`, and writes the result against the sequence
// that was read. `None` from `change` writes nothing. The answer is the row
// that was written, if any.
fn settle_key(
  runtime: api.Runtime,
  key: String,
  change: fn(Row) -> Option(Row),
) -> Result(Option(Row), String) {
  use cell <- result.try(
    api.fact_cell(runtime, key) |> result.map_error(string.inspect),
  )
  case cell {
    None -> Ok(None)
    Some(cell) -> {
      use row <- result.try(peer_outbox.decode(cell.value))
      case change(row) {
        None -> Ok(None)
        Some(next) ->
          api.put_reserved_fact_expecting(
            runtime,
            key,
            peer_outbox.encode(next),
            expected: Some(cell.seq),
          )
          |> result.replace(Some(next))
          |> result.map_error(string.inspect)
      }
    }
  }
}

// Every readable row. A value that does not decode is left out rather than
// failing the listing: the store is durable and may hold a row a later version
// wrote, and one such row must not stop every send from the session.
fn rows(runtime: api.Runtime) -> Result(List(#(String, Row)), String) {
  use stored <- result.try(
    api.reserved_facts(runtime, peer_outbox.key_prefix)
    |> result.map_error(string.inspect),
  )
  Ok(
    list.filter_map(stored, fn(pair) {
      peer_outbox.decode(pair.1) |> result.map(fn(row) { #(pair.0, row) })
    }),
  )
}

fn state_reply(word: String) -> JsonValue {
  json.Object([#("state", json.String(word))])
}
