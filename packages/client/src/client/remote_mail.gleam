//// The vocabulary of what a child on another orchestrator sends its parent, and
//// of the answers that settle it (protocol-change/084, phase 2).
////
//// Phase 1 spoke in one direction. The parent's orchestrator, the laptop, asked
//// and the remote, the box, answered, so every message was a request that the
//// asker could resend until it was answered. Phase 2 adds messages the box
//// originates: a child's mail to its parent (`ChildMail`) and its progress
//// (`ChildProgress`). They are constructors of the orchestrator port's `Message`
//// (`client/remote/orchestrator_port`) served by the laptop's `ChildHost`, and
//// this module holds the plain data they carry and the answers they get. It has
//// no process in it and does no I/O, as `client/remote_spawn` has none, so both
//// orchestrators compile the same module and a value built here crosses the
//// pinned connection as an ordinary term.
////
//// ## Who is asking
////
//// A message from the box names the child by the strand name the box gave it
//// (`remote_child.Stub.name`) and the parent as a session and a strand, as a
//// message from the laptop does (`remote_spawn.Parent`). The laptop takes the
//// box's identity from the connection, the node of the process that sent it, and
//// it admits the message only if that node is the configured node of the
//// orchestrator the child's stub names. Among pinned peers a claimed origin is
//// not proven by the connection, so this bounds an honest peer, as the spawn
//// policy does in the other direction.
////
//// ## Answers
////
//// The laptop answers a `ChildMail` with a `Receipt` or a `ChildRefusal`. A
//// `Receipt` is final and says what became of the message: `Delivered` into the
//// parent's open run, or `Declined` because the parent had no run open. A
//// `ChildRefusal` says the laptop could not decide, and exactly one of the four
//// is worth asking again: `ParentSessionNotOpen`, the parent session being saved
//// and not resident, which its owner ends by opening it.
////
//// ## Flow
////
//// `retryable` → `describe_refusal` → `encode_receipt` → `decode_receipt` →
//// `encode_landing` → `decode_landing`
////
//// 1. `retryable` says whether a refusal leaves the box's row pending.
//// 2. `describe_refusal` words a refusal for a log line or the child's receipt.
//// 3. `encode_receipt` and `decode_receipt` are the codec of a mail receipt, which
////    the laptop stores and the box keeps on its outbox row.
//// 4. `encode_landing` and `decode_landing` are the codec of how a downward send
////    landed in the child, which the box stores as the send's receipt and the
////    laptop reads back.

import core/corruption
import core/ids.{type EntryId, type OpId}
import core/json.{type JsonValue}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// What became of a message the laptop admitted. It is the final answer: the box
/// settles its outbox row on it and never sends the message again.
pub type Receipt {
  /// The message was steered into the parent's open run, in the commit that
  /// wrote the receipt.
  Delivered

  /// The parent had no run open, so nothing was delivered. A finished parent is
  /// never woken for a child's message, because no human is present to read what
  /// it would do. The box keeps the reason on its row.
  Declined(
    /// Why, in words for the child that sent it.
    reason: String,
  )
}

/// Why the laptop could not decide about a message. Every variant is an answer,
/// and only `ParentSessionNotOpen` leaves the sender's row pending.
pub type ChildRefusal {
  /// No stub of the parent session names this child. The box can only name a
  /// child the parent asked for, so this is a box that outlived the parent's
  /// records or a message for another daemon; asking again changes nothing.
  UnknownChild

  /// The parent session is in this daemon's catalogue but not resident. Its
  /// owner ends the wait by opening it, so the sender asks again.
  ParentSessionNotOpen

  /// The message came from a node that is not the configured node of the
  /// orchestrator the child's stub names.
  OriginMismatch

  /// The laptop's store could not record the decision.
  StoreFailure(
    /// What failed.
    reason: String,
  )
}

/// Whether a refusal leaves the sender's row pending, to be sent again.
///
/// Only the parent session being closed does. The other three are the laptop
/// saying the message will not be admitted however often it is sent, and a row
/// that kept being sent would cost a round trip every pass for ever. A store
/// failure is definitive for the same reason a `Declined` receipt is: the box
/// settles on an answer, and a laptop whose store is failing has answered.
///
/// ## Examples
///
/// ```gleam
/// assert remote_mail.retryable(remote_mail.ParentSessionNotOpen)
/// assert !remote_mail.retryable(remote_mail.UnknownChild)
/// ```
pub fn retryable(refusal: ChildRefusal) -> Bool {
  case refusal {
    ParentSessionNotOpen -> True
    UnknownChild | OriginMismatch | StoreFailure(..) -> False
  }
}

/// A refusal as a sentence for a log line or a child's receipt.
///
/// ## Examples
///
/// ```gleam
/// assert remote_mail.describe_refusal(remote_mail.UnknownChild)
///   == "the parent session has no record of this child"
/// ```
pub fn describe_refusal(refusal: ChildRefusal) -> String {
  case refusal {
    UnknownChild -> "the parent session has no record of this child"
    ParentSessionNotOpen -> "the parent session is not open"
    OriginMismatch ->
      "the message did not come from the orchestrator that runs this child"
    StoreFailure(reason:) -> "the parent's store failed: " <> reason
  }
}

/// A receipt as the value its cell holds, on the laptop under `remote-mail/` and
/// on the box beside the row that was settled by it.
///
/// ## Examples
///
/// ```gleam
/// assert remote_mail.encode_receipt(remote_mail.Delivered)
///   == json.Object([#("kind", json.String("delivered"))])
/// ```
pub fn encode_receipt(receipt: Receipt) -> JsonValue {
  case receipt {
    Delivered -> json.Object([#("kind", json.String("delivered"))])
    Declined(reason:) ->
      json.Object([
        #("kind", json.String("declined")),
        #("reason", json.String(reason)),
      ])
  }
}

/// Decodes a receipt. Total: anything malformed is an error that names what was
/// wrong, never a crash.
///
/// ## Examples
///
/// ```gleam
/// assert remote_mail.decode_receipt(remote_mail.encode_receipt(remote_mail.Delivered))
///   == Ok(remote_mail.Delivered)
/// ```
pub fn decode_receipt(value: JsonValue) -> Result(Receipt, String) {
  use fields <- result.try(object(value, "a mail receipt"))
  use kind <- result.try(text(fields, "kind"))
  case kind {
    "delivered" -> Ok(Delivered)
    "declined" -> text(fields, "reason") |> result.map(Declined)
    other -> Error("unknown mail receipt `" <> other <> "`")
  }
}

/// How a send from the parent landed in a child that runs on this orchestrator.
/// It is the receipt the box stores for the message id and the answer it gives
/// the laptop, so a send the laptop repeats is answered from it and is never
/// delivered twice.
pub type Landing {
  /// The child had an open run, and the message is a durable steer on it.
  Steered(
    /// The committed pending-message identity.
    entry: EntryId,
  )

  /// The child was idle, so the message started a fresh detached run.
  Started(
    /// The new run.
    operation: OpId,
    /// How long the run may last, as a duration on the box's clock, or `None`
    /// when it has no deadline. Clocks never cross as instants.
    remaining_ms: Option(Int),
  )

  /// The message was delivered by an earlier attempt, and the receipt kept only
  /// that it was admitted. The first attempt's answer was the one that said how.
  Admitted
}

/// A landing as the value a receipt cell holds and a reply carries.
///
/// ## Examples
///
/// ```gleam
/// assert remote_mail.encode_landing(remote_mail.Admitted)
///   == json.Object([#("delivery", json.String("admitted"))])
/// ```
pub fn encode_landing(landing: Landing) -> JsonValue {
  case landing {
    Steered(entry:) ->
      json.Object([
        #("delivery", json.String("steered")),
        #("entry", json.String(ids.entry_id_to_string(entry))),
      ])
    Started(operation:, remaining_ms:) ->
      json.Object([
        #("delivery", json.String("started")),
        #("operation", json.String(ids.op_id_to_string(operation))),
        #("remainingMs", case remaining_ms {
          Some(ms) -> json.Int(ms)
          None -> json.Null
        }),
      ])
    Admitted -> json.Object([#("delivery", json.String("admitted"))])
  }
}

/// Decodes a landing. Total, like every decoder at a durability or wire
/// boundary.
///
/// ## Examples
///
/// ```gleam
/// assert remote_mail.decode_landing(remote_mail.encode_landing(remote_mail.Admitted))
///   == Ok(remote_mail.Admitted)
/// ```
pub fn decode_landing(value: JsonValue) -> Result(Landing, String) {
  use fields <- result.try(object(value, "a landing"))
  use delivery <- result.try(text(fields, "delivery"))
  case delivery {
    "steered" -> {
      use raw <- result.try(text(fields, "entry"))
      ids.parse_entry_id(raw)
      |> result.map(Steered)
      |> result.map_error(corruption.describe)
    }
    "started" -> {
      use raw <- result.try(text(fields, "operation"))
      use operation <- result.try(
        ids.parse_op_id(raw) |> result.map_error(corruption.describe),
      )
      use remaining_ms <- result.map(case list.key_find(fields, "remainingMs") {
        Ok(json.Int(ms)) -> Ok(Some(ms))
        Ok(json.Null) | Error(Nil) -> Ok(None)
        Ok(_) -> Error("expected `remainingMs` to be an integer")
      })
      Started(operation:, remaining_ms:)
    }
    "admitted" -> Ok(Admitted)
    other -> Error("unknown landing `" <> other <> "`")
  }
}

fn object(
  value: JsonValue,
  what: String,
) -> Result(List(#(String, JsonValue)), String) {
  case value {
    json.Object(fields) -> Ok(fields)
    other -> Error("expected " <> what <> ", got " <> json.to_string(other))
  }
}

fn text(
  fields: List(#(String, JsonValue)),
  name: String,
) -> Result(String, String) {
  case list.key_find(fields, name) {
    Ok(json.String(found)) -> Ok(found)
    Ok(_) -> Error("expected `" <> name <> "` to be text")
    Error(Nil) -> Error("missing `" <> name <> "`")
  }
}
