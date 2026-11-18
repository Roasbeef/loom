//// The daemon's three acts on one attention record: read it, answer an ask,
//// close a find (protocol-change/120).
////
//// Each act is the same walk. Who the caller is comes from the registry, read
//// afresh, and never from the request. The session must be resident, because
//// reading a record needs its store open and the daemon never opens a saved
//// session for a read. The record is read through the session's own Agency
//// actor with the revision of its cell, and the act names that revision when it
//// writes, so an answer to a record that has since changed is refused rather
//// than written over it.
////
//// ## Flow
////
//// `read`, `answer` and `close_find`, each through `held`, `endpoint_of` and
//// `fetch`
////
//// 1. `held` asks the registry for the caller's authority over the session. A
////    session the caller does not hold is `not_found`, as an unknown one is.
//// 2. `endpoint_of` resolves the resident session's peer endpoint, or says it
////    is `not_resident`.
//// 3. `fetch` reads the record and its revision through `AttentionRead`.
//// 4. `answer` validates the answer against the record
////    (`core/attention_answer`), delivers one prompt to the asking strand, and
////    only then settles the record. `close_find` settles directly.
////
//// ## Why delivery comes before settling
////
//// If the record were settled first and the prompt then refused, the ask would
//// leave the inbox while the agent never saw the answer. Delivering first has
//// the weaker failure: a prompt arrives and the record stays open, so the ask
//// is still listed and a second answer is accepted, the later one standing. The
//// prompt in the strand's transcript is the authoritative copy.
////
//// ## What this module does not decide
////
//// It does not open a session, does not deliver anything itself (the caller
//// hands it a send, so the home page's gateway and a control socket's are the
//// same code), and does not list. The feed is `server.home_attention` and the
//// control command's.

import client/attention
import client/attention_feed
import client/daemon/manager
import client/peer_mail
import core/attention as records
import core/attention_answer
import core/json.{type JsonValue}
import gleam/list
import gleam/option.{type Option}
import gleam/result
import storage/access
import web_view/thread_send

/// Why an act was refused before anything was written, in the control
/// protocol's own words: a code the socket sends, and fixed words for a person.
pub type Refusal {
  Refusal(
    /// `forbidden`, `not_found`, `not_resident`, `bad_request`, `conflict` or
    /// `unavailable`.
    code: String,
    /// Words for the refusal. They name a question key at most, never text the
    /// person typed or a session wrote.
    words: String,
  )
}

/// What the daemon needs to act on a session's records as one caller.
pub type Reach(instance) {
  Reach(
    /// The registry that answers authority and residency.
    registry: manager.Manager(instance),
    /// The caller's credential, whose authority is read afresh.
    digest: access.Digest,
    /// Projects a resident's address-only peer endpoint.
    endpoint: fn(instance) -> Option(peer_mail.Endpoint),
  )
}

/// What an answer did: how the gateway took the prompt, and the ask's revision
/// once settled.
pub type Answered {
  Answered(delivery: thread_send.Admission, revision: Int)
}

/// Why an answer did not complete.
pub type AnswerFault {
  /// Refused before any prompt was sent, for a reason of the daemon's own.
  Declined(Refusal)

  /// The gateway or the session would not take the prompt, so the ask stays
  /// open. The refusal is the send's, unchanged in kind.
  NotSent(thread_send.Refusal)

  /// The prompt was delivered and the settling write then failed. The ask may
  /// still be open, and the prompt is in the strand's transcript.
  Unsettled(Refusal)
}

// --- read -------------------------------------------------------------------------

/// Reads one record in full, in the shape `attention.read` answers: the record,
/// its revision and whether the caller may act on it.
///
/// ## Examples
///
/// ```gleam
/// // attention_door.read(reach, "0198...", "ask-3f9c01a2b4")
/// ```
pub fn read(
  reach: Reach(instance),
  session: String,
  id: String,
) -> Result(JsonValue, Refusal) {
  use authority <- result.try(held(reach, session))
  use stored <- result.map(fetch(reach, session, id))
  attention_feed.record_json(stored, handling(authority))
}

// --- answer -----------------------------------------------------------------------

/// Answers an open ask.
///
/// `send` delivers one prompt to a strand of the session and answers what the
/// gateway said, as `ui_socket.message_to` does for a home page. The daemon
/// walks the steps of protocol-change/120 in order and stops at the first
/// refusal: authority, residency, the record, its state, its revision, the
/// answer's validity, delivery, and last the settling write.
///
/// ## Examples
///
/// ```gleam
/// // attention_door.answer(reach, send, "0198...", "ask-3f9c01a2b4", 41, wire)
/// ```
pub fn answer(
  reach: Reach(instance),
  send: fn(String, String) -> thread_send.Answer,
  session: String,
  ask_id: String,
  revision: Int,
  wire: JsonValue,
) -> Result(Answered, AnswerFault) {
  use #(principal, _authority) <- result.try(
    held_for_acting(reach, session) |> result.map_error(Declined),
  )
  use stored <- result.try(
    fetch(reach, session, ask_id) |> result.map_error(Declined),
  )
  use ask <- result.try(
    open_ask(stored, revision) |> result.map_error(Declined),
  )
  use values <- result.try(
    attention_answer.check(ask, wire)
    |> result.map_error(fn(rejection) {
      Declined(Refusal("bad_request", rejection.key <> ": " <> rejection.reason))
    }),
  )
  deliver_then_settle(reach, send, session, ask, revision, values, principal)
}

/// The ask a stored record is, when it can be answered at `revision`: an open
/// ask routed to the owner that has not moved since it was read.
fn open_ask(
  stored: attention.Stored,
  revision: Int,
) -> Result(records.Ask, Refusal) {
  case stored {
    attention.StoredFind(..) ->
      Error(Refusal("bad_request", "that record is a find, not an ask"))
    attention.StoredAsk(ask:, revision: read_at) ->
      case ask.header.routing, ask.state, read_at == revision {
        records.ToStrand(_), _, _ ->
          Error(Refusal("bad_request", "that ask is for a strand, not a person"))
        records.ToOwner, records.Answered(..), _ ->
          Error(Refusal("conflict", "that ask was already answered"))
        records.ToOwner, records.AskOpen, False ->
          Error(Refusal("conflict", "that ask changed since it was read"))
        records.ToOwner, records.AskOpen, True -> Ok(ask)
      }
  }
}

/// Sends the prompt to the asking strand and, once the gateway has taken it,
/// settles the record as answered by the caller.
fn deliver_then_settle(
  reach: Reach(instance),
  send: fn(String, String) -> thread_send.Answer,
  session: String,
  ask: records.Ask,
  revision: Int,
  values: List(#(String, records.Value)),
  principal: access.Principal,
) -> Result(Answered, AnswerFault) {
  let text = attention_answer.prompt_text(ask.header.id, values)
  use admission <- result.try(case send(ask.header.strand, text) {
    thread_send.Delivered(admission) -> Ok(admission)
    thread_send.Refused(refusal) -> Error(NotSent(refusal))
  })
  let settlement =
    attention.Answering(records.Answer(values:, by: principal.id))
  settle(reach, session, ask.header.id, revision, settlement)
  |> result.map(fn(settled) { Answered(admission, settled) })
  |> result.map_error(fn(refusal) {
    case refusal.code {
      "conflict" ->
        Unsettled(Refusal("conflict", "delivered; the record changed"))
      _ ->
        Unsettled(Refusal(refusal.code, "delivered; the record was not settled"))
    }
  })
}

// --- close ------------------------------------------------------------------------

/// Closes an open find as the caller says. Nothing is sent to any strand: a
/// closure is the person's statement that the work was done or the issue filed,
/// and Loom checks neither.
///
/// ## Examples
///
/// ```gleam
/// // attention_door.close_find(reach, "0198...", "find-77d0a1c9e2", 52, records.Filed)
/// ```
pub fn close_find(
  reach: Reach(instance),
  session: String,
  find_id: String,
  revision: Int,
  outcome: records.Closure,
) -> Result(Int, Refusal) {
  use #(principal, _authority) <- result.try(held_for_acting(reach, session))
  use stored <- result.try(fetch(reach, session, find_id))
  use Nil <- result.try(open_find(stored, revision))
  settle(
    reach,
    session,
    find_id,
    revision,
    attention.Closing(outcome, principal.id),
  )
}

/// Whether a stored record is a find that can be closed at `revision`.
fn open_find(stored: attention.Stored, revision: Int) -> Result(Nil, Refusal) {
  case stored {
    attention.StoredAsk(..) ->
      Error(Refusal("bad_request", "that record is an ask, not a find"))
    attention.StoredFind(find:, revision: read_at) ->
      case find.state, read_at == revision {
        records.Closed(..), _ ->
          Error(Refusal("conflict", "that find was already closed"))
        records.FindOpen, False ->
          Error(Refusal("conflict", "that find changed since it was read"))
        records.FindOpen, True -> Ok(Nil)
      }
  }
}

// --- the walk ---------------------------------------------------------------------

/// The caller's authority over the session, read from the registry now. A
/// session the caller does not hold is `not_found`, the word an unknown one
/// gets.
fn held(
  reach: Reach(instance),
  session: String,
) -> Result(access.Authority, Refusal) {
  manager.session_authority(reach.registry, reach.digest, session)
  |> result.map(fn(held) { held.1 })
  |> result.replace_error(Refusal("not_found", "no such session"))
}

/// The caller and its authority, for an act that writes: the owner, or a member
/// holding the session as an Operator. An observer is refused here, so it never
/// reaches the record.
fn held_for_acting(
  reach: Reach(instance),
  session: String,
) -> Result(#(access.Principal, access.Authority), Refusal) {
  use held <- result.try(
    manager.session_authority(reach.registry, reach.digest, session)
    |> result.replace_error(Refusal("not_found", "no such session")),
  )
  case held.1 {
    access.Owner | access.Participant(access.Operator) -> Ok(held)
    access.Participant(access.Observer) ->
      Error(Refusal("forbidden", "an observer cannot change a record"))
  }
}

/// Whether a caller of this authority may act on what it reads.
fn handling(authority: access.Authority) -> attention_feed.Handling {
  case authority {
    access.Owner | access.Participant(access.Operator) -> attention_feed.CanAct
    access.Participant(access.Observer) -> attention_feed.ReadOnly
  }
}

/// The resident session's peer endpoint, or `not_resident`. A saved session, one
/// that is opening or stopping, and one with no endpoint are all the same to a
/// caller: nothing is running that could read its store.
fn endpoint_of(
  reach: Reach(instance),
  session: String,
) -> Result(peer_mail.Endpoint, Refusal) {
  let none = Refusal("not_resident", "the session is not running")
  use resident <- result.try(
    manager.resolve(reach.registry, session) |> result.replace_error(none),
  )
  reach.endpoint(resident) |> option.to_result(none)
}

/// Reads the record and its revision through the session's Agency actor. An id
/// with no record's shape is `bad_request`, and a record that is not there, or
/// does not decode, is `not_found`.
fn fetch(
  reach: Reach(instance),
  session: String,
  id: String,
) -> Result(attention.Stored, Refusal) {
  use Nil <- result.try(case records.is_ask_id(id) || records.is_find_id(id) {
    True -> Ok(Nil)
    False -> Error(Refusal("bad_request", "not the identifier of a record"))
  })
  use endpoint <- result.try(endpoint_of(reach, session))
  use reply <- result.try(call(endpoint, peer_mail.AttentionRead(id)))
  decode_stored(id, reply)
}

/// The record in a reply `{"revision", "record"}`, typed by the id's prefix.
fn decode_stored(
  id: String,
  reply: JsonValue,
) -> Result(attention.Stored, Refusal) {
  let missing = Refusal("not_found", "no such record")
  case reply {
    json.Object(fields) ->
      case list.key_find(fields, "revision"), list.key_find(fields, "record") {
        Ok(json.Int(revision)), Ok(record) ->
          case records.is_ask_id(id) {
            True ->
              records.decode_ask(record)
              |> result.map(attention.StoredAsk(_, revision))
              |> result.replace_error(missing)
            False ->
              records.decode_find(record)
              |> result.map(attention.StoredFind(_, revision))
              |> result.replace_error(missing)
          }
        Ok(_), Ok(_) | Ok(_), Error(Nil) | Error(Nil), _ -> Error(missing)
      }
    json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error(missing)
  }
}

/// Settles a record through the session's Agency actor and answers its new
/// revision.
fn settle(
  reach: Reach(instance),
  session: String,
  id: String,
  revision: Int,
  settlement: attention.Settlement,
) -> Result(Int, Refusal) {
  use endpoint <- result.try(endpoint_of(reach, session))
  use reply <- result.try(call(
    endpoint,
    peer_mail.AttentionSettle(id, revision, settlement),
  ))
  case reply {
    json.Object(fields) ->
      case list.key_find(fields, "revision") {
        Ok(json.Int(settled)) -> Ok(settled)
        Ok(_) | Error(Nil) ->
          Error(Refusal("unavailable", "the session gave no revision"))
      }
    json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error(Refusal("unavailable", "the session gave no revision"))
  }
}

/// One call to the session's endpoint. The words an Agency answers with for a
/// refusal of its own, `not_found`, `conflict` and `bad_request`, become the
/// daemon's codes; every other reason is the store's and is `unavailable`.
fn call(
  endpoint: peer_mail.Endpoint,
  command: peer_mail.Command,
) -> Result(JsonValue, Refusal) {
  case endpoint.call(command) {
    Ok(reply) -> Ok(reply)
    Error(peer_mail.Refused("not_found")) ->
      Error(Refusal("not_found", "no such record"))
    Error(peer_mail.Refused("conflict")) ->
      Error(Refusal("conflict", "the record changed"))
    Error(peer_mail.Refused("bad_request")) ->
      Error(Refusal("bad_request", "not a record of that kind"))
    Error(peer_mail.Refused(_)) ->
      Error(Refusal("unavailable", "the session could not read its records"))
    Error(peer_mail.Unreachable) | Error(peer_mail.NotOpen) ->
      Error(Refusal("not_resident", "the session is not running"))
  }
}
