//// What `<loom-switch>` decides (`web_client/switch_rule`): the one address
//// shape the browser may be sent to.

import gleam/list
import gleam/string
import web_client/switch_rule

const session = "0198a2f4-7c3b-7e10-8d5a-3f9b2c4e6a71"

fn ticket() -> String {
  string.repeat("ab12", 16)
}

fn exchange(identity: String, ticket: String) -> String {
  "/ui/sessions/" <> identity <> "?ticket=" <> ticket
}

pub fn a_ticket_exchange_for_a_session_is_an_address_test() {
  let address = exchange(session, ticket())
  assert switch_rule.target(address) == Ok(address)
}

// Upper-case digits are hexadecimal too, and the daemon's own identities and
// tickets are lower-case, so only the shape is checked.
pub fn hexadecimal_digits_of_either_case_are_accepted_test() {
  let address = exchange(string.uppercase(session), string.uppercase(ticket()))
  assert switch_rule.target(address) == Ok(address)
}

// Everything that is not exactly a ticket exchange is refused, whether it
// names another origin, another path on this one, or has the right words in
// the wrong place.
pub fn any_other_value_is_refused_test() {
  list.each(
    [
      "",
      "/",
      "https://elsewhere.example/ui/sessions/"
        <> session
        <> "?ticket="
        <> ticket(),
      "//elsewhere.example" <> exchange(session, ticket()),
      "javascript:alert(1)",
      "x" <> exchange(session, ticket()),
      exchange(session, ticket()) <> "&next=/elsewhere",
      exchange(session, ticket()) <> "#fragment",
      exchange(session, ticket()) <> "0",
      exchange(session, string.drop_end(ticket(), 1)),
      exchange(session, string.repeat("zz", 32)),
      exchange(session, ""),
      exchange("", ticket()),
      exchange("not-a-session", ticket()),
      exchange(string.drop_end(session, 1), ticket()),
      exchange(session <> "-", ticket()),
      exchange("../" <> session, ticket()),
      "/ui/p/key/sessions/" <> session,
      "/ui/sessions/" <> session,
      "/ui/sessions/" <> session <> "?ticket",
      "/ui/sessions/" <> session <> "/ws?ticket=" <> ticket(),
    ],
    fn(value) {
      assert switch_rule.target(value) == Error(Nil)
    },
  )
}
