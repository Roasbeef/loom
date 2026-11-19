//// The daemon's read of one session's recent work, for Home's inbox
//// (protocol-change/125).
////
//// The brief is computed inside the session by its own Agency actor
//// (`client/session_brief`), from the session's own stores. This module decides
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
//// 3. `reserved` takes one of the credential's brief reads, counted by
////    the per-credential brief read limit, so opening more sockets
////    does not buy more of them.
//// 4. `read` then asks the resident's peer endpoint for the brief. A saved
////    session is refused as not running, because the daemon never opens one for
////    a read.
////
//// ## Who may read
////
//// The owner, and a member at any role: the rule `attention.read` follows and no
//// wider. A member's Home and an observer's follow it too, because the brief is
//// what the session's own page shows an observer.
////
//// ## What a refusal says
////
//// A fixed code and fixed words. A session's own text is never in one.

import client/daemon/attention_door.{type Reach, type Refusal, Refusal}
import client/peer_mail
import core/json.{type JsonValue}
import gleam/result
import web_view/session_brief

/// What a brief read needs beside the attention door's reach.
pub type Allowance {
  Allowance(
    /// Takes one of the credential's brief reads, or refuses. The place is not
    /// given back.
    reserve: fn() -> Result(Nil, Nil),
  )
}

/// Reads a session's brief as the reply object `{"brief": {...}}`, with the peer
/// messages recorded after `since`.
///
/// ## Examples
///
/// ```gleam
/// // brief_door.read(reach, allowance, "0198...", 0)
/// ```
pub fn read(
  reach: Reach(instance),
  allowance: Allowance,
  session: String,
  since: Int,
) -> Result(JsonValue, Refusal) {
  use _authority <- result.try(attention_door.held(reach, session))
  use Nil <- result.try(reserved(allowance))
  use endpoint <- result.try(attention_door.endpoint_of(reach, session))
  attention_door.call(endpoint, peer_mail.SessionBrief(since))
}

/// Reads a session's brief as the typed value the page draws, for a caller in
/// this process. The reply is decoded by the page's own decoder, so a reply it
/// cannot read is `unavailable`.
///
/// ## Examples
///
/// ```gleam
/// // brief_door.read_typed(reach, allowance, "0198...", 0)
/// ```
pub fn read_typed(
  reach: Reach(instance),
  allowance: Allowance,
  session: String,
  since: Int,
) -> Result(session_brief.Brief, Refusal) {
  use reply <- result.try(read(reach, allowance, session, since))
  session_brief.decode(reply)
  |> result.replace_error(Refusal(
    "unavailable",
    "The session's brief could not be read.",
  ))
}

/// Takes one of the credential's brief reads, or refuses with fixed words. The
/// place is not given back.
///
/// ## Examples
///
/// ```gleam
/// assert brief_door.reserved(brief_door.Allowance(fn() { Ok(Nil) })) == Ok(Nil)
/// ```
pub fn reserved(allowance: Allowance) -> Result(Nil, Refusal) {
  allowance.reserve()
  |> result.replace_error(Refusal("unavailable", busy_words))
}

/// The words of a refusal for the allowance.
pub const busy_words = "The session was read a moment ago; try again shortly."
