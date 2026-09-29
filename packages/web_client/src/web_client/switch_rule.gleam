//// What `<loom-switch>` decides: whether the address the server wrote is one
//// the browser may be sent to.
////
//// The operator's page opens another session by navigating to the ticket
//// exchange of that session (protocol-change/051, the addendum on switching
//// sessions). The server mints the ticket and writes the exchange's address
//// into the element's `to` attribute, and the element moves the browser
//// there. That is the one place a script acts on a value the server chose,
//// so the value is held to the exact shape the daemon writes and nothing
//// else: a path on this origin, `/ui/sessions/<id>?ticket=<ticket>`, where
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

const ticket_marker = "?ticket="

const ticket_digits = 64

// The lengths of a canonical session identity's five hexadecimal groups.
const identity_groups = [8, 4, 4, 4, 12]

/// The address to navigate to, or a refusal for a value that is not exactly
/// a ticket exchange for a canonical session identity.
///
/// ## Examples
///
/// ```gleam
/// assert switch_rule.target("https://elsewhere.example/") == Error(Nil)
/// ```
pub fn target(value: String) -> Result(String, Nil) {
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
