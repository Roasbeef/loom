//// The sender's outbox for peer mail: one durable row per message, and the
//// pure rules that move a row between its three states.
////
//// Peer admission is idempotent on the recipient. `peer_mail.deliver` commits
//// the message and a receipt keyed by (source session, source strand, message
//// id) in one transaction, and a repeat of the same request returns that
//// receipt. What the recipient cannot do is answer while its owner is
//// unreachable, and a sender that only retries in memory loses the message
//// when it restarts. The outbox closes that gap on the sender: `peers.send`
//// records the request before the first attempt, so a message that could not
//// be delivered is still owed after a restart, and the drainer
//// (`client/peer_outbox_drain`) keeps attempting it. The receipt is the only
//// acknowledgement. A lost reply is the ordinary case, and the retry returns
//// the stored receipt, so delivery is exactly once in effect.
////
//// The rows live in the sending session's own store under
//// `client/peers/outbox/<digest(strand, session, message id)>`, beside the
//// link authority and the sender identity they depend on. They are not in the
//// catalogue, and a session moved to another orchestrator carries its pending
//// messages with it.
////
//// This module is pure. It decides what a claim means, when a row has room,
//// how an attempt's outcome changes a row, and when a row has waited too
//// long. `client/internal/peer_outbox_store` applies those decisions to the
//// session store, and `client/peer_mail` exposes them as endpoint commands so
//// that they run in the sender's serialized Agency actor.
////
//// ## Flow
////
//// `claim` → `room` → `settle` → `expire`
////
//// 1. `claim` compares the row that is stored for a message with the request
////    being sent, and says whether to write it, resume it, answer from it, or
////    refuse because the message id names different content.
//// 2. `room` applies the per-strand bound before a new row is written, and
////    names the oldest finished row to evict when the strand is at the bound.
//// 3. `settle` applies one attempt's outcome to a pending row. A finished row
////    never moves again.
//// 4. `expire` turns a pending row that has waited longer than the pending
////    limit into a refusal, so that an owner that never returns stops being
////    attempted.

import core/json.{type JsonValue}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import tools/blob

/// The reserved key prefix every outbox row lives under.
pub const key_prefix = "client/peers/outbox/"

/// The most rows one sending strand keeps. It matches the link bound
/// (`peer_mail.outgoing_link_limit`), so a strand that may address 64
/// recipients may hold one message to each at most before rows are evicted.
pub const row_limit = 64

/// How long a message may stay pending, in milliseconds. After one hour the
/// drainer stops attempting it and the row records a refusal.
pub const pending_ttl_ms = 3_600_000

/// Where a message stands.
pub type State {
  /// Not yet admitted or refused. The text is kept because the drainer must
  /// be able to send the message again without the model's help.
  Pending(text: String)

  /// The recipient returned a receipt. The receipt is kept so that
  /// `peer_sent_receipt` can answer without asking the recipient's owner.
  Admitted(receipt: JsonValue)

  /// The recipient refused definitively, or the message expired. The reason is
  /// the recipient's, worded for the model.
  Refused(reason: String)
}

/// One outgoing message and its state. The key is derived from `strand`,
/// `session` and `message_id`, so those three never change after the row is
/// written.
pub type Row {
  Row(
    /// The sending strand.
    strand: String,
    /// The recipient's canonical session identity.
    session: String,
    /// The exported strand in the recipient.
    target_strand: String,
    /// The sender-chosen request identity.
    message_id: String,
    /// When the row was first written, in the session clock's milliseconds.
    queued_at: Int,
    /// Where the message stands.
    state: State,
  )
}

/// What one delivery attempt found.
pub type Outcome {
  /// The recipient returned this receipt.
  Receipt(receipt: JsonValue)

  /// The recipient refused definitively. Retrying the same request cannot
  /// succeed until something outside the message changes.
  Rejected(reason: String)

  /// Nobody answered: the recipient's owner is unreachable. The row stays
  /// pending and the drainer attempts it again.
  Unanswered
}

/// What a claim of a message id means, given the row already stored for it.
pub type Claim {
  /// Write the wanted row. There is no row, or the earlier attempt was
  /// refused and this is a new attempt.
  Insert

  /// The same message is already pending. Attempt it without writing.
  Resume

  /// The same message was already admitted. Answer with its receipt.
  Settled(receipt: JsonValue)

  /// The message id was used for different content or a different target.
  Conflict
}

/// Whether a strand may take one more row.
pub type Room {
  /// The strand is under the bound.
  Free

  /// The strand is at the bound; delete this finished row first.
  Evict(key: String)

  /// The strand is at the bound and every row is pending.
  Full
}

/// The reserved key of one message's row.
///
/// ## Examples
///
/// ```gleam
/// assert peer_outbox.key("main", "s2", "m1")
///   == peer_outbox.key("main", "s2", "m1")
/// ```
///
/// ```gleam
/// assert peer_outbox.key("main", "s2", "m1")
///   != peer_outbox.key("main", "s2", "m2")
/// ```
pub fn key(strand: String, session: String, message_id: String) -> String {
  key_prefix
  <> blob.ref_for(<<
    json.to_string(
      json.Array([
        json.String(strand),
        json.String(session),
        json.String(message_id),
      ]),
    ):utf8,
  >>)
}

/// A pending row for a message about to be sent.
///
/// ## Examples
///
/// ```gleam
/// // peer_outbox.pending("main", "s2", "main", "m1", "hello", 0)
/// ```
pub fn pending(
  strand: String,
  session: String,
  target_strand: String,
  message_id: String,
  text: String,
  now: Int,
) -> Row {
  Row(
    strand:,
    session:,
    target_strand:,
    message_id:,
    queued_at: now,
    state: Pending(text),
  )
}

/// Whether the row still needs an attempt.
///
/// ## Examples
///
/// ```gleam
/// assert peer_outbox.is_pending(peer_outbox.pending("m", "s", "m", "1", "t", 0))
/// ```
pub fn is_pending(row: Row) -> Bool {
  case row.state {
    Pending(..) -> True
    Admitted(..) | Refused(..) -> False
  }
}

/// The request the recipient stores in its receipt for this message, as
/// `peer_mail.deliver` builds it. A pending row's text completes it; a
/// finished row has no text and so no request.
///
/// ## Examples
///
/// ```gleam
/// // peer_outbox.request("source-session", row)
/// ```
pub fn request(source_session: String, row: Row) -> Option(JsonValue) {
  case row.state {
    Pending(text:) ->
      Some(
        json.Object([
          #("source_session", json.String(source_session)),
          #("source_strand", json.String(row.strand)),
          #("target_strand", json.String(row.target_strand)),
          #("message_id", json.String(row.message_id)),
          #("body", json.String(text)),
        ]),
      )
    Admitted(..) | Refused(..) -> None
  }
}

/// Decides what a request to send `wanted` means when `existing` is the row
/// stored under its key.
///
/// A refused row is not final: nothing was admitted, and the cause may have
/// passed (the recipient was opened, the grant was made), so the same id may
/// be sent again and the row is replaced. A pending or admitted row answers
/// for the message, and only the same content may reuse it. This is the
/// recipient's own rule, applied before the recipient is asked.
///
/// ## Examples
///
/// ```gleam
/// let row = peer_outbox.pending("main", "s2", "main", "m1", "hello", 0)
/// assert peer_outbox.claim(None, row, "s1") == peer_outbox.Insert
/// ```
///
/// ```gleam
/// let row = peer_outbox.pending("main", "s2", "main", "m1", "hello", 0)
/// assert peer_outbox.claim(Some(row), row, "s1") == peer_outbox.Resume
/// ```
pub fn claim(
  existing: Option(Row),
  wanted: Row,
  source_session: String,
) -> Claim {
  let wanted_request = request(source_session, wanted)
  case existing {
    None -> Insert
    Some(Row(state: Refused(..), ..)) -> Insert
    Some(Row(state: Pending(..), ..) as stored) ->
      case request(source_session, stored) == wanted_request {
        True -> Resume
        False -> Conflict
      }
    Some(Row(state: Admitted(receipt:), ..)) ->
      case field(receipt, "request") |> option.from_result == wanted_request {
        True -> Settled(receipt)
        False -> Conflict
      }
  }
}

/// Decides whether `strand` may take a new row, given every row stored in the
/// session as `#(key, row)`.
///
/// At the bound the oldest finished row is evicted, so the outbox keeps the
/// recent history `peer_sent_receipt` is asked about. Pending rows are never
/// evicted, because each is a message still owed. When all are pending the
/// send is refused with `outbox_full`, which is the bound saying that the
/// owner has been unreachable for 64 messages.
///
/// ## Examples
///
/// ```gleam
/// assert peer_outbox.room([], "main") == peer_outbox.Free
/// ```
pub fn room(rows: List(#(String, Row)), strand: String) -> Room {
  let mine = list.filter(rows, fn(pair) { { pair.1 }.strand == strand })

  // A list that still has elements after dropping all but one slot is at the
  // bound, which is decided without walking the rest of it.
  case list.drop(mine, row_limit - 1) {
    [] -> Free
    [_, ..] -> {
      let finished =
        list.filter(mine, fn(pair) { !is_pending(pair.1) })
        |> list.sort(fn(a, b) { oldest_first(a, b) })
      case finished {
        [#(oldest, _), ..] -> Evict(oldest)
        [] -> Full
      }
    }
  }
}

// Orders by age, and by key between rows written in the same millisecond, so
// the eviction choice does not depend on the order the store listed them in.
fn oldest_first(a: #(String, Row), b: #(String, Row)) -> order.Order {
  case a.1.queued_at == b.1.queued_at {
    True -> string.compare(a.0, b.0)
    False ->
      case a.1.queued_at < b.1.queued_at {
        True -> order.Lt
        False -> order.Gt
      }
  }
}

/// Applies one attempt's outcome to a row. Only a pending row moves, so the
/// first outcome recorded is the final one, and an attempt that raced another
/// (the inline send and the drainer can both be in flight) cannot overwrite it.
/// `None` means there is nothing to write.
///
/// ## Examples
///
/// ```gleam
/// let row = peer_outbox.pending("main", "s2", "main", "m1", "hello", 0)
/// assert peer_outbox.settle(row, peer_outbox.Unanswered) == None
/// ```
pub fn settle(row: Row, outcome: Outcome) -> Option(Row) {
  case row.state, outcome {
    Pending(..), Receipt(receipt:) -> Some(Row(..row, state: Admitted(receipt)))
    Pending(..), Rejected(reason:) -> Some(Row(..row, state: Refused(reason)))
    Pending(..), Unanswered -> None
    Admitted(..), _ | Refused(..), _ -> None
  }
}

/// Turns a pending row that has waited longer than `pending_ttl_ms` into a
/// refusal worded with `reason`. A row that is not yet old, or is finished,
/// is left alone.
///
/// ## Examples
///
/// ```gleam
/// let row = peer_outbox.pending("main", "s2", "main", "m1", "hello", 0)
/// assert peer_outbox.expire(row, 1000, "owner unreachable") == None
/// ```
pub fn expire(row: Row, now: Int, reason: String) -> Option(Row) {
  case is_pending(row) && now - row.queued_at > pending_ttl_ms {
    True -> settle(row, Rejected(reason))
    False -> None
  }
}

/// Encodes a row as the value stored in the session.
///
/// ## Examples
///
/// ```gleam
/// // peer_outbox.decode(peer_outbox.encode(row)) == Ok(row)
/// ```
pub fn encode(row: Row) -> JsonValue {
  let state = case row.state {
    Pending(text:) -> [
      #("state", json.String("pending")),
      #("text", json.String(text)),
    ]
    Admitted(receipt:) -> [
      #("state", json.String("admitted")),
      #("receipt", receipt),
    ]
    Refused(reason:) -> [
      #("state", json.String("refused")),
      #("reason", json.String(reason)),
    ]
  }
  json.Object(list.append(
    [
      #("strand", json.String(row.strand)),
      #("session", json.String(row.session)),
      #("target_strand", json.String(row.target_strand)),
      #("message_id", json.String(row.message_id)),
      #("queued_at", json.Int(row.queued_at)),
    ],
    state,
  ))
}

/// Decodes a stored row. A value of any other shape is an error naming the
/// field, never a crash: the store is durable and may hold a row from a later
/// version.
///
/// ## Examples
///
/// ```gleam
/// assert peer_outbox.decode(json.Null) == Error("expected outbox object")
/// ```
pub fn decode(value: JsonValue) -> Result(Row, String) {
  use strand <- result.try(text(value, "strand"))
  use session <- result.try(text(value, "session"))
  use target_strand <- result.try(text(value, "target_strand"))
  use message_id <- result.try(text(value, "message_id"))
  use queued_at <- result.try(case field(value, "queued_at") {
    Ok(json.Int(at)) -> Ok(at)
    _ -> Error("expected outbox queued_at")
  })
  use word <- result.try(text(value, "state"))
  use state <- result.try(case word {
    "pending" -> text(value, "text") |> result.map(Pending)
    "admitted" -> field(value, "receipt") |> result.map(Admitted)
    "refused" -> text(value, "reason") |> result.map(Refused)
    _ -> Error("unknown outbox state")
  })
  Ok(Row(strand:, session:, target_strand:, message_id:, queued_at:, state:))
}

fn field(value: JsonValue, name: String) -> Result(JsonValue, String) {
  case value {
    json.Object(fields) ->
      list.key_find(fields, name)
      |> result.replace_error("missing outbox field")
    _ -> Error("expected outbox object")
  }
}

fn text(value: JsonValue, name: String) -> Result(String, String) {
  use found <- result.try(field(value, name))
  case found {
    json.String(text) -> Ok(text)
    _ -> Error("expected outbox text")
  }
}
