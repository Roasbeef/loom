//// The home page's passkeys: the WebAuthn credentials the owner registered, what
//// the daemon answers when the page removes one, and the fixed words for each
//// refusal (protocol-change/127).
////
//// A passkey lets the owner sign a browser in at `/ui/signin` with no shell on
//// the daemon's machine. The daemon holds one catalogue row for each (`storage/
//// access`): a public key, a counter and a label. The home lists those rows for
//// the owner so the person can see which devices can sign in, and can remove one.
//// Each row is a fingerprint, which names a passkey on this page and authenticates
//// nothing, and a label the owner typed; the credential id and the key never
//// reach a page.
////
//// A page a `loom ui` exchange opened (a fresh home) is also offered "Add a
//// passkey", a link to the registration page, which is a document of its own
//// because creating a credential needs a script. A page a passkey or a bookmark
//// opened lists and removes but is not offered the link, and the daemon refuses
//// the registration from it all the same.
////
//// This module holds the vocabulary the page and the daemon share, so the page
//// learns nothing else about the daemon.

import gleam/option.{type Option}

/// The most passkeys one list draws: the catalogue's own bound per principal.
pub const listed_limit = 8

/// One passkey of the principal, as the catalogue holds it and as a page may see
/// it.
pub type Passkey {
  Passkey(
    /// The first sixteen hexadecimal digits of the SHA-256 of the credential id.
    fingerprint: String,
    /// The name the owner gave the passkey.
    label: String,
    /// When the passkey was added, in Unix milliseconds.
    created_at_ms: Int,
    /// When the passkey last signed a browser in, if it has.
    last_used_ms: Option(Int),
  )
}

/// What one read of the page's passkeys gave.
pub type Listing {
  /// The principal's passkeys, oldest first.
  Listed(rows: List(Passkey))

  /// The registry did not answer. The page keeps the list it has.
  Unread
}

/// What the daemon answers to a request to remove a passkey.
pub type Answer {
  /// The passkey was removed. The page reads its list again.
  Removed

  /// Nothing was done. Every page shows the fixed words for the reason
  /// (`reason_words`) and never the daemon's own text.
  Declined(reason: Reason)
}

/// Why the daemon did nothing.
pub type Reason {
  /// No such passkey is the principal's, or it was already removed.
  NotFound

  /// The page is not the owner's operating page, which is the only kind that
  /// may remove one.
  NotAllowed

  /// The daemon could not answer: it was starting, stopping or slow.
  Unavailable
}

/// The words a page shows for a refusal. They are fixed here, one per reason, so
/// nothing the daemon wrote reaches a browser.
///
/// ## Examples
///
/// ```gleam
/// assert passkeys.reason_words(passkeys.NotFound)
///   == "That passkey has already been removed."
/// ```
pub fn reason_words(reason: Reason) -> String {
  case reason {
    NotFound -> "That passkey has already been removed."
    NotAllowed -> "Only the owner's page can remove a passkey."
    Unavailable -> "The daemon could not do that. Try again."
  }
}
