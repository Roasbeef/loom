//// What `<loom-switch>` decides: whether the address the server wrote is one
//// the browser may be sent to.
////
//// A page opens another session by navigating to the ticket exchange of that
//// session (protocol-change/051, the addendum on switching sessions), and a
//// page opened from a home goes back to the home by navigating to the home's
//// exchange (protocol-change/065), and the owner's home goes to the admin page
//// by navigating to the admin exchange (the fifth pull request). The server
//// mints the ticket and writes the exchange's address into the element's `to`
//// attribute, and the element moves the browser there. That is the one place a
//// script acts on a value the server chose, so the value is held to the exact
//// shapes the daemon writes and nothing else: a path on this origin, one of
//// `/ui/home?ticket=<ticket>`, `/ui/admin?ticket=<ticket>` or
//// `/ui/sessions/<id>?ticket=<ticket>`, where
//// the identity is the canonical form of eight, four, four, four and twelve
//// hexadecimal digits and the ticket is the 64 hexadecimal digits the
//// daemon's entropy source yields. Anything else, an absolute URL, a path
//// elsewhere on the origin, a second parameter, a fragment or a scheme, is no
//// address and the element does nothing.
////
//// The module imports neither Lustre nor the DOM binding, so the tests load
//// it under Node.

import gleam/list
import gleam/string

const prefix = "/ui/sessions/"

// The two exchanges that name no session, each followed by a ticket.
const bare_prefixes = ["/ui/home", "/ui/admin"]

const ticket_marker = "?ticket="

const ticket_digits = 64

// The lengths of a canonical session identity's five hexadecimal groups.
const identity_groups = [8, 4, 4, 4, 12]

/// The address to navigate to, or a refusal for a value that is not exactly
/// a ticket exchange for a canonical session identity, for the home page or
/// for the admin page.
///
/// ## Examples
///
/// ```gleam
/// assert switch_rule.target("https://elsewhere.example/") == Error(Nil)
/// ```
pub fn target(value: String) -> Result(String, Nil) {
  case list.find_map(bare_prefixes, fn(prefix) { bare_target(value, prefix) }) {
    Ok(address) -> Ok(address)
    Error(Nil) -> session_target(value)
  }
}

// An exchange that names no session: the prefix, then the ticket.
fn bare_target(value: String, prefix: String) -> Result(String, Nil) {
  case string.split_once(value, prefix <> ticket_marker) {
    Ok(#("", ticket)) ->
      case hexadecimal(ticket, ticket_digits) {
        True -> Ok(value)
        False -> Error(Nil)
      }
    Ok(#(_, _)) | Error(Nil) -> Error(Nil)
  }
}

// The session exchange's shape: the identity, then the ticket.
fn session_target(value: String) -> Result(String, Nil) {
  case string.split_once(value, prefix) {
    Ok(#("", rest)) ->
      case string.split_once(rest, ticket_marker) {
        Ok(#(identity, ticket)) ->
          case canonical(identity) && hexadecimal(ticket, ticket_digits) {
            True -> Ok(value)
            False -> Error(Nil)
          }
        Error(Nil) -> Error(Nil)
      }
    Ok(#(_, _)) | Error(Nil) -> Error(Nil)
  }
}

// A canonical session identity: five hyphen-separated groups of hexadecimal
// digits of the fixed lengths.
fn canonical(identity: String) -> Bool {
  let groups = string.split(identity, "-")
  list.length(groups) == list.length(identity_groups)
  && list.all(list.zip(groups, identity_groups), fn(pair) {
    hexadecimal(pair.0, pair.1)
  })
}

// Exactly `length` hexadecimal digits and nothing else.
fn hexadecimal(text: String, length: Int) -> Bool {
  string.length(text) == length
  && list.all(string.to_graphemes(text), fn(digit) {
    string.contains("0123456789abcdefABCDEF", digit)
  })
}
