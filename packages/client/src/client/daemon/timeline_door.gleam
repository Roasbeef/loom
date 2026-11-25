//// The daemon's read of one session's timeline, for Home's review and update
//// threads (protocol-change/134).
////
//// The cards are computed inside the session by its own Agency actor
//// (`client/timeline_read`), from the session's own store. This module decides
//// who may ask and how often, and nothing else. It runs no tool, opens no saved
//// session and writes nothing.
////
//// ## Flow
////
//// `read_typed` → `read` → `reserved`
////
//// 1. `read_typed` calls `read` and decodes the reply with the page's own
////    decoder.
//// 2. `read` asks the registry for the caller's authority over the session,
////    afresh and never from the request. A session the caller does not hold is
////    refused as an unknown one is.
//// 3. `reserved` takes one of the credential's brief reads, since a timeline
////    read costs the session a bounded walk of its records as a brief does, and
////    one allowance bounds both.
//// 4. `read` then asks the resident's peer endpoint for the page. A saved
////    session is refused as not running, because the daemon never opens one for
////    a read.
////
//// ## Who may read
////
//// The owner, and a member at any role: the rule `session.brief` follows and no
//// wider. An observer sees the same cards the owner does, because the cards say
//// what the session's own transcript already shows an observer.
////
//// ## What a refusal says
////
//// A fixed code and fixed words. A session's own text is never in one.

import client/daemon/attention_door.{type Reach, type Refusal, Refusal}
import client/daemon/brief_door.{type Allowance}
import client/peer_mail
import core/json.{type JsonValue}
import gleam/option.{type Option}
import gleam/result
import web_view/timeline_feed

/// Reads a session's timeline page as the reply object `{"timeline": {...}}`.
///
/// ## Examples
///
/// ```gleam
/// // timeline_door.read(reach, allowance, "0198...", None, 10)
/// ```
pub fn read(
  reach: Reach(instance),
  allowance: Allowance,
  session: String,
  before: Option(Int),
  limit: Int,
) -> Result(JsonValue, Refusal) {
  use _authority <- result.try(attention_door.held(reach, session))
  use Nil <- result.try(brief_door.reserved(allowance))
  use endpoint <- result.try(attention_door.endpoint_of(reach, session))
  attention_door.call(endpoint, peer_mail.SessionTimeline(before, limit))
}

/// Reads a session's timeline as the typed value the page draws, for a caller in
/// this process. The reply is decoded by the page's own decoder, so a reply it
/// cannot read is `unavailable`.
///
/// ## Examples
///
/// ```gleam
/// // timeline_door.read_typed(reach, allowance, "0198...", None, 10)
/// ```
pub fn read_typed(
  reach: Reach(instance),
  allowance: Allowance,
  session: String,
  before: Option(Int),
  limit: Int,
) -> Result(timeline_feed.Feed, Refusal) {
  use reply <- result.try(read(reach, allowance, session, before, limit))
  timeline_feed.decode(reply)
  |> result.replace_error(Refusal(
    "unavailable",
    "The session's timeline could not be read.",
  ))
}
