//// What `<loom-copy>` decides: which two texts it may put on the clipboard,
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
//// The module imports neither Lustre nor the DOM binding, so the tests load
//// it under Node.

import gleam/list
import gleam/string

/// Which of the invitation's two texts the element holds, chosen by the fixed
/// word the server writes in its `subject` attribute.
pub type Subject {
  /// The command the invitee runs, `loom claim --addr ...`.
  Command

  /// The claim token the invitee pastes at the command's prompt.
  Token
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

const token_digits = 64

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
    Idle, Command -> "Copy command"
    Idle, Token -> "Copy token"
    Copied, Command -> "Command copied"
    Copied, Token -> "Token copied"
    Failed, Command | Failed, Token ->
      "Copy failed. Select the text and copy it."
  }
}
