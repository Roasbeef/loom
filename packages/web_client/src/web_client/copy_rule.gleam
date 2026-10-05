//// What `<loom-copy>` decides: which texts it may put on the clipboard,
//// what it says on its button, and what it says when the browser refuses.
////
//// The owner's page shows an invitation once, and the owner copies two texts
//// from it: the command the invitee runs and the claim token
//// (protocol-change/051, the addendum on inviting from the session page). The
//// element writes one of them to the system clipboard when the owner presses
//// its button. What lands on the clipboard is then pasted into a chat window
//// or a terminal, so the element copies only a value of the exact shape the
//// daemon writes for its subject and nothing else. A `loom claim` command is
//// `loom claim --addr ` and an address made of the characters an address
//// has; a token is `loomclaim_` and 64 hexadecimal digits. Anything else,
//// including text with a newline, a control character or a second command
//// after a semicolon, is no value, and the element offers no button for it.
//// A newline is the case that matters most: pasted into a terminal, it runs
//// what came before it.
////
//// The document an ended page gets offers a third text, the command that mints
//// a fresh link: `loom ui`, alone or with `--session` and a session identity,
//// which is hexadecimal digits and hyphens. It has the same rule: nothing else
//// is copied.
////
//// The home page's sign-ins offer a fourth: the link that signs in another
//// device (protocol-change/065, PR 8), an address on this daemon's loopback host
//// for the ticket exchange, `http://` and the host, `/ui/home?ticket=` and 64
//// lowercase hexadecimal digits. The ticket is a secret that lives ten minutes,
//// so the element copies exactly that shape and nothing a page could have
//// altered into another address.
////
//// The claim box offers a fifth: the address a person without `loom` opens to
//// claim in a browser, `http://`, a loopback host and port and `/ui/claim`
//// (protocol-change/065, the addendum on the browser claim). It holds no
//// secret, and it has the same rule: exactly that shape, so a page cannot
//// alter it into another address.
////
//// A sixth is the bookmark a remembered login's home draws, so the person can
//// keep it (protocol-change/065, the browser login): the daemon's address, the
//// login's path `/ui/l/` and the login key, 32 lowercase hexadecimal digits,
//// then `/home`. The address is `http://` and a host and port made of the same
//// characters a device link's are. The bookmark is a bearer address: whoever
//// holds it can resume the login while it lasts, so the element copies exactly
//// that shape and nothing else.
////
//// The module imports neither Lustre nor the DOM binding, so the tests load
//// it under Node.

import gleam/list
import gleam/string

/// Which text the element holds, chosen by the fixed word the server writes in its `subject` attribute.
pub type Subject {
  /// The command the invitee runs, `loom claim --addr ...`.
  Command

  /// The claim token the invitee pastes at the command's prompt.
  Token

  /// The command that mints a fresh page link, `loom ui` or
  /// `loom ui --session <id>`, which the document an ended page gets offers
  /// (protocol-change/065, the addendum on the home list).
  Link

  /// The address that signs in another device: `http://`, a loopback host and
  /// port, `/ui/home?ticket=` and the ticket's 64 lowercase hexadecimal digits
  /// (protocol-change/065, PR 8).
  Device

  /// The address that claims in a browser: `http://`, a loopback host and port
  /// and `/ui/claim`, with nothing after it.
  ClaimPage

  /// The address that resumes a remembered login's home page: `http://`, a
  /// loopback host and port, `/ui/l/`, the login key's 32 lowercase
  /// hexadecimal digits and `/home`.
  Bookmark
}

/// What the button has done so far.
pub type Copying {
  /// Nothing has been copied, or the text changed since.
  Idle

  /// The browser accepted the write.
  Copied

  /// The browser refused the write: the page is not a secure context, the
  /// clipboard is not permitted, or the press was not a user's own. The text
  /// is still on screen to select.
  Failed
}

const command_prefix = "loom claim --addr "

const token_prefix = "loomclaim_"

const link_prefix = "loom ui --session "

// The longest session identity a link command may carry, in characters.
const identity_limit = 64

const token_digits = 64

const device_scheme = "http://"

const device_path = "/ui/home?ticket="

const claim_page_path = "/ui/claim"

const bookmark_path = "/ui/l/"

const bookmark_tail = "/home"

const key_digits = 32

// The characters a loopback host and port are made of: letters, digits and the
// punctuation of a name, an address and a port. No slash, no space, no quote.
const host_characters =
  "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:.-[]"

// The longest host and port a device link may carry, in characters.
const host_limit = 64

// The longest address a command may carry, in characters.
const address_limit = 256

// The characters a `ws` or `wss` address is made of: letters, digits and the
// punctuation of a scheme, a host, a port and a path. No space, no quote, no
// shell metacharacter and no control character is among them.
const address_characters =
  "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:/.-_[]"

/// The subject a `subject` attribute names, or a refusal for any other value.
/// Decoding is total: an unknown word is no subject.
///
/// ## Examples
///
/// ```gleam
/// assert copy_rule.subject("token") == Ok(copy_rule.Token)
/// ```
pub fn subject(value: String) -> Result(Subject, Nil) {
  case value {
    "command" -> Ok(Command)
    "token" -> Ok(Token)
    "link" -> Ok(Link)
    "device" -> Ok(Device)
    "claim-address" -> Ok(ClaimPage)
    "bookmark" -> Ok(Bookmark)
    _ -> Error(Nil)
  }
}

/// The text the element may copy for `subject`, or a refusal for a value that
/// is not exactly the shape the daemon writes.
///
/// ## Examples
///
/// ```gleam
/// assert copy_rule.text(copy_rule.Command, "loom claim --addr ws://127.0.0.1:4000/v2/control")
///   == Ok("loom claim --addr ws://127.0.0.1:4000/v2/control")
/// ```
pub fn text(subject: Subject, value: String) -> Result(String, Nil) {
  let shaped = case subject {
    Command -> command(value)
    Token -> token(value)
    Link -> link(value)
    Device -> device(value)
    ClaimPage -> claim_page(value)
    Bookmark -> bookmark(value)
  }
  case shaped {
    True -> Ok(value)
    False -> Error(Nil)
  }
}

// `loom claim --addr ` and an address after it.
fn command(value: String) -> Bool {
  case string.split_once(value, command_prefix) {
    Ok(#("", address)) ->
      address != "" && !longer_than(address, address_limit) && made_of(address)
    Ok(#(_, _)) | Error(Nil) -> False
  }
}

// `loom ui`, alone or with `--session` and a canonical identity: hexadecimal
// digits and hyphens, no longer than a session identity can be.
fn link(value: String) -> Bool {
  case value {
    "loom ui" -> True
    _ ->
      case string.split_once(value, link_prefix) {
        Ok(#("", identity)) ->
          identity != ""
          && !longer_than(identity, identity_limit)
          && list.all(string.to_graphemes(identity), fn(character) {
            string.contains("0123456789abcdefABCDEF-", character)
          })
        Ok(#(_, _)) | Error(Nil) -> False
      }
  }
}

// `http://`, a loopback host, `/ui/home?ticket=` and exactly 64 lowercase
// hexadecimal digits.
fn device(value: String) -> Bool {
  case string.split_once(value, device_scheme) {
    Ok(#("", rest)) ->
      case string.split_once(rest, device_path) {
        Ok(#(host, ticket)) ->
          host != ""
          && !longer_than(host, host_limit)
          && list.all(string.to_graphemes(host), fn(character) {
            string.contains(host_characters, character)
          })
          && exactly(ticket, token_digits)
          && list.all(string.to_graphemes(ticket), fn(digit) {
            string.contains("0123456789abcdef", digit)
          })
        Error(Nil) -> False
      }
    Ok(_) | Error(Nil) -> False
  }
}

// `http://`, a loopback host and `/ui/claim`, and nothing after it.
fn claim_page(value: String) -> Bool {
  case string.split_once(value, device_scheme) {
    Ok(#("", rest)) ->
      case string.split_once(rest, claim_page_path) {
        Ok(#(host, "")) ->
          host != ""
          && !longer_than(host, host_limit)
          && list.all(string.to_graphemes(host), fn(character) {
            string.contains(host_characters, character)
          })
        Ok(#(_, _)) | Error(Nil) -> False
      }
    Ok(_) | Error(Nil) -> False
  }
}

// `http://`, a loopback host, `/ui/l/`, exactly 32 lowercase hexadecimal digits
// and `/home`, with nothing after it.
fn bookmark(value: String) -> Bool {
  case string.split_once(value, device_scheme) {
    Ok(#("", rest)) ->
      case string.split_once(rest, bookmark_path) {
        Ok(#(host, after)) ->
          host != ""
          && !longer_than(host, host_limit)
          && list.all(string.to_graphemes(host), fn(character) {
            string.contains(host_characters, character)
          })
          && case string.split_once(after, bookmark_tail) {
            Ok(#(key, "")) ->
              exactly(key, key_digits)
              && list.all(string.to_graphemes(key), fn(digit) {
                string.contains("0123456789abcdef", digit)
              })
            Ok(#(_, _)) | Error(Nil) -> False
          }
        Error(Nil) -> False
      }
    Ok(_) | Error(Nil) -> False
  }
}

// `loomclaim_` and exactly 64 hexadecimal digits.
fn token(value: String) -> Bool {
  case string.split_once(value, token_prefix) {
    Ok(#("", digits)) ->
      exactly(digits, token_digits)
      && list.all(string.to_graphemes(digits), fn(digit) {
        string.contains("0123456789abcdefABCDEF", digit)
      })
    Ok(#(_, _)) | Error(Nil) -> False
  }
}

// Whether `text` has more than `limit` characters, which only needs the
// characters after the limit.
fn longer_than(text: String, limit: Int) -> Bool {
  string.drop_start(text, limit) != ""
}

// Whether `text` has exactly `count` characters.
fn exactly(text: String, count: Int) -> Bool {
  !longer_than(text, count) && longer_than(text, count - 1)
}

fn made_of(address: String) -> Bool {
  list.all(string.to_graphemes(address), fn(character) {
    string.contains(address_characters, character)
  })
}

/// The state after the browser answers the write.
///
/// ## Examples
///
/// ```gleam
/// assert copy_rule.after(Ok(Nil)) == copy_rule.Copied
/// ```
pub fn after(outcome: Result(Nil, Nil)) -> Copying {
  case outcome {
    Ok(Nil) -> Copied
    Error(Nil) -> Failed
  }
}

/// The button's words. They name what pressing copies and what came of it,
/// and hold nothing from the invitation.
///
/// ## Examples
///
/// ```gleam
/// assert copy_rule.words(copy_rule.Token, copy_rule.Idle) == "Copy token"
/// ```
pub fn words(subject: Subject, copying: Copying) -> String {
  case copying, subject {
    Idle, Command | Idle, Link -> "Copy command"
    Idle, Token -> "Copy token"
    Idle, Device -> "Copy link"
    Idle, ClaimPage -> "Copy address"
    Idle, Bookmark -> "Copy bookmark"
    Copied, Command | Copied, Link -> "Command copied"
    Copied, Token -> "Token copied"
    Copied, Device -> "Link copied"
    Copied, ClaimPage -> "Address copied"
    Copied, Bookmark -> "Bookmark copied"
    Failed, Command
    | Failed, Token
    | Failed, Link
    | Failed, Device
    | Failed, ClaimPage
    | Failed, Bookmark
    -> "Copy failed. Select the text and copy it."
  }
}
