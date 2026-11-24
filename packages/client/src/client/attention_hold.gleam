//// The daemon's half of an open ask holding its strand (protocol-change/119,
//// "Addendum 2026-11-23: an open ask holds the strand").
////
//// An ask ends the run and the answer arrives later as a new user message. The
//// runtime keeps automatic inputs from starting a run in the meantime
//// (`runtime/api.send_to_strand`). This module is what the rest of the daemon
//// does with the same fact: it words a reminder onto every request the strand
//// makes while an ask is open, and it answers the advisor's one question, which
//// is whether the primary is waiting on the owner.
////
//// ## Flow
////
//// `hooks` → `reminded` → `open_asks`
////
//// 1. `hooks` wraps the request-context slot, so the reminder is re-applied to each
////    request and stored nowhere.
//// 2. `reminded` finds the strand the request belongs to, reads its open asks
////    with `open_asks`, drops the ones the request already carries an answer
////    to, and appends the reminder as the request's last message.
//// 3. `holds` is `open_asks` asked as a yes or no, for a caller that decides
////    whether to wake the primary.
////
//// ## Why a transient message at the end of the request
////
//// A reminder stored in the transcript would be wrong the moment the owner
//// answered, would sit in the history until compaction summarised it, and
//// would add another copy at every wake. A request-time message is computed
//// from the records, so it is true as of the request, it survives compaction
//// because it is not part of what compaction keeps, and it disappears when the
//// last ask is answered. It goes last, as the near-limit reminder does
//// (`client/checkpoint`), so a provider's prompt cache keeps the whole
//// conversation as its prefix and only the reminder is new.
////
//// ## What a read that fails costs
////
//// A store that will not answer reads as no open ask. The reminder is then
//// missing for one request, and the advisor wakes the primary as it did before
//// asks held anything. Neither is worth stopping a run for.

import core/attention.{type Ask}
import core/attention_hold
import core/clock.{type Clock}
import core/ids.{type OpId}
import core/message.{type AgentMessage}
import core/register
import gleam/list
import gleam/option.{None, Some}
import harness/session_read
import runtime/effects
import session/session.{type Session}
import storage/storage

/// The open asks of `strand` that wait on the owner, oldest first.
///
/// ## Examples
///
/// ```gleam
/// // attention_hold.open_asks(session, "main") == [ask]
/// ```
pub fn open_asks(session: Session, strand: String) -> List(Ask) {
  case
    storage.list_registers(
      session.store,
      register.FactCustom,
      Some(attention.ask_prefix),
    )
  {
    Ok(rows) ->
      rows
      |> list.map(fn(row) { #(row.0, { row.1 }.value.payload) })
      |> attention_hold.holding(strand)
    Error(_unreadable) -> []
  }
}

/// Whether `strand` has an ask waiting on the owner.
///
/// ## Examples
///
/// ```gleam
/// // attention_hold.holds(session, "main") == True
/// ```
pub fn holds(session: Session, strand: String) -> Bool {
  open_asks(session, strand) != []
}

/// Adds the reminder to a hook record's `context` slot, preserving whatever was
/// already there.
///
/// Composition is by wrapping and never by setting: `hooks.with_context`
/// replaces the slot and would drop the layer installed before it.
///
/// ## Examples
///
/// ```gleam
/// // effects.Hooks(..built, ..) |> attention_hold.hooks(session, clock)
/// ```
pub fn hooks(
  built: effects.Hooks,
  session: Session,
  clock: Clock,
) -> effects.Hooks {
  // The closure captures the slot and not the record it came from, so each
  // wrapping layer does not double the record's flat size.
  let inner = built.context

  effects.Hooks(..built, context: fn(operation, projected) {
    reminded(session, clock, operation, inner(operation, projected))
  })
}

/// The request with the reminder as its last message, or the request unchanged
/// when its strand has no open ask.
fn reminded(
  session: Session,
  clock: Clock,
  operation: OpId,
  projected: List(AgentMessage),
) -> List(AgentMessage) {
  // An operation with no metadata belongs to no strand, so nothing is added.
  case session_read.strand_of(session, operation) {
    Error(Nil) -> projected
    Ok(strand) -> {
      let asks =
        open_asks(session, strand)
        |> attention_hold.unanswered(user_texts(projected))

      // No open ask leaves the request as it was.
      case attention_hold.reminder(asks) {
        Ok(text) -> list.append(projected, [reminder_message(clock, text)])
        Error(Nil) -> projected
      }
    }
  }
}

/// The text of every user block a person wrote, which is where an answer to an
/// ask the record still calls open can be found.
///
/// A message from a peer session, another strand or a trigger is skipped, since
/// anyone who can send one can choose its text, and a text that began with the
/// answer's line would otherwise remove the reminder. The answer itself reaches
/// the strand as the owner's message, with a human origin or none.
fn user_texts(messages: List(AgentMessage)) -> List(String) {
  list.flat_map(messages, fn(item) {
    case item {
      message.UserMessage(origin: Some(message.PeerOrigin(..)), ..) -> []
      message.UserMessage(origin: Some(message.StrandOrigin(..)), ..) -> []
      message.UserMessage(origin: Some(message.TriggerOrigin(..)), ..) -> []
      message.UserMessage(content:, origin: Some(message.Origin(..)), ..)
      | message.UserMessage(content:, origin: None, ..) ->
        list.filter_map(content, fn(block) {
          case block {
            message.UserText(text:, ..) -> Ok(text)
            message.UserImage(..) -> Error(Nil)
          }
        })
      message.AssistantMessage(..)
      | message.ToolResultMessage(..)
      | message.CustomMessage(..) -> []
    }
  })
}

/// The reminder as a user message stamped with the clock's time.
fn reminder_message(clock: Clock, text: String) -> AgentMessage {
  let #(now, _clock) = clock.read(clock)
  message.UserMessage(
    content: [message.UserText(text:, text_signature: None)],
    timestamp: now,
    origin: None,
  )
}
