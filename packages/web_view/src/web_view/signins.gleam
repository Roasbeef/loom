//// The home page's sign-ins: the browsers signed in as the page's principal,
//// what the daemon answers when the page signs one out or asks for a link to
//// sign in another device, and the fixed words for each refusal
//// (protocol-change/065, the eighth pull request).
////
//// A browser signed in with `loom ui` holds a login, a thirty-day credential
//// whose only record on the daemon is one catalogue row (`host/login`,
//// `storage/access`). The home lists those rows for its own principal so the
//// person can see every browser that can come back without `loom`, which of
//// them is this one, when each last came back, and when each ends, and can end
//// one ("sign out") or all of them ("sign out everywhere"). Each row is a
//// fingerprint, which identifies a login and authenticates nothing; the token
//// and its nonce are in the browser and nowhere on the daemon, so the page can
//// draw nothing a thief of the page could sign in with.
////
//// A page opened by a `loom ui` exchange (a fresh home) may also make a link
//// that signs in another device. The link is a ticket, shown once, whose
//// exchange sets a login on the device that opens it. A home the bookmark
//// resumed draws no such control and the daemon refuses the request from it:
//// a stolen bookmark must not be able to make a second credential.
////
//// This module holds the vocabulary the page and the daemon share, so the page
//// learns nothing else about the daemon.

import gleam/int
import gleam/option.{type Option}

/// The most sign-ins one list draws: the daemon's own page bound.
pub const listed_limit = 100

/// One browser signed in as the principal, as the catalogue holds it.
pub type Signin {
  Signin(
    /// The first sixteen hexadecimal digits of the login's digest.
    fingerprint: String,
    /// When the login was made, in Unix milliseconds.
    issued_at_ms: Int,
    /// When the login last minted a home page, if it has. It is recorded at
    /// most once an hour, so it says when a login was last used and not how
    /// often.
    last_resumed_ms: Option(Int),
    /// When the login ends, if the daemon recorded it.
    expires_at_ms: Option(Int),
    /// The fingerprint of the login whose device link made this one.
    issued_by: Option(String),
  )
}

/// What one read of the page's sign-ins gave.
pub type Listing {
  /// The principal's active, unexpired logins in the daemon's order.
  Listed(rows: List(Signin))

  /// The registry did not answer. The page keeps the list it has.
  Unread
}

/// What the daemon answers to a request to sign a browser out or to make a
/// device link.
pub type Answer {
  /// The sign-in was ended. The page reads its list again.
  Revoked

  /// A device link was made. `address` is the whole link, the daemon's address
  /// as this browser reached it and the ticket's exchange, which the page shows
  /// once in a box to copy. The ticket is single use and lives ten minutes.
  Linked(address: String)

  /// Nothing was done. Every page shows the fixed words for the reason
  /// (`reason_words`) and never the daemon's own text.
  Declined(reason: Reason)
}

/// Why the daemon did nothing.
pub type Reason {
  /// No such sign-in is the principal's, or it was already ended.
  NotFound

  /// The page is not one a `loom ui` exchange opened, so it may not make a
  /// device link.
  NotFresh

  /// This credential has made as many device links as it may recently. The
  /// count is the daemon's and is kept for the credential and not for the page,
  /// so opening another page does not reset it.
  TooMany

  /// The daemon could not answer: it was starting, stopping or slow.
  Unavailable
}

/// The words a page shows for a refusal. They are fixed here, one per reason,
/// so nothing the daemon wrote reaches a browser.
///
/// ## Examples
///
/// ```gleam
/// assert signins.reason_words(signins.TooMany)
///   == "You have made many links this hour. Try again later."
/// ```
pub fn reason_words(reason: Reason) -> String {
  case reason {
    NotFound -> "That sign-in has already ended."
    NotFresh ->
      "Only a page you opened with `loom ui` can sign in another device. Run `loom ui` and use that page."
    TooMany -> "You have made many links this hour. Try again later."
    Unavailable -> "The daemon could not do that. Try again."
  }
}

/// How long until `then`, as `now` sees it, both in Unix milliseconds: "under a
/// minute", then minutes, hours and days, each rounded up. A person told a
/// sign-in lasts 30 days should read `30d` on one made a moment ago, and a
/// floor would show `29d` for thirty days less one second. A `then` that is not
/// after `now` is "ended".
///
/// ## Examples
///
/// ```gleam
/// assert signins.ends_in(0, 5_183_999_000) == "60d"
/// ```
pub fn ends_in(now: Int, then: Int) -> String {
  let seconds = up(int.max(then - now, 0), 1000)
  let minutes = up(seconds, 60)
  let hours = up(seconds, 3600)
  case seconds {
    0 -> "ended"
    _ if seconds < 60 -> "under a minute"
    _ if minutes < 60 -> int.to_string(minutes) <> "m"
    _ if hours < 24 -> int.to_string(hours) <> "h"
    _ -> int.to_string(up(seconds, 86_400)) <> "d"
  }
}

// `count` divided by `unit`, rounded up, for a non-negative count.
fn up(count: Int, unit: Int) -> Int {
  { count + unit - 1 } / unit
}
