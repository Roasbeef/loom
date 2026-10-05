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
// The home's exchange is the one other address the daemon writes: a page
// opened from a home goes back to it (protocol-change/065).
pub fn a_ticket_exchange_for_the_home_is_an_address_test() {
  let address = "/ui/home?ticket=" <> ticket()
  assert switch_rule.target(address) == Ok(address)
  let upper = "/ui/home?ticket=" <> string.uppercase(ticket())
  assert switch_rule.target(upper) == Ok(upper)
}

// The admin page's exchange is the third: the owner's home goes to it
// (protocol-change/065, the fifth pull request), and it is as exact as the
// home's.
pub fn a_ticket_exchange_for_the_admin_page_is_an_address_test() {
  let address = "/ui/admin?ticket=" <> ticket()
  assert switch_rule.target(address) == Ok(address)
  list.each(
    [
      "/ui/admin",
      "/ui/admin?ticket=",
      "/ui/admin/?ticket=" <> ticket(),
      "/ui/admins?ticket=" <> ticket(),
      "/ui/admin?ticket=" <> string.drop_end(ticket(), 1),
      "/ui/admin?ticket=" <> ticket() <> "&next=/elsewhere",
      "/ui/admin?ticket=" <> ticket() <> "#fragment",
      "/ui/admin?ticket=" <> string.repeat("zz", 32),
      "//elsewhere.example/ui/admin?ticket=" <> ticket(),
      "https://elsewhere.example/ui/admin?ticket=" <> ticket(),
      "/ui/p/key/admin?ticket=" <> ticket(),
      "/ui/home/ui/admin?ticket=" <> ticket(),
      "/ui/admin?ticket=" <> ticket() <> "/ui/admin?ticket=" <> ticket(),
    ],
    fn(value) {
      assert switch_rule.target(value) == Error(Nil)
    },
  )
}

// The home shape is as exact as the session's: no other origin, path, query,
// fragment or ticket length reaches the browser through it.
pub fn any_other_home_value_is_refused_test() {
  list.each(
    [
      "/ui/home",
      "/ui/home?ticket=",
      "/ui/home/?ticket=" <> ticket(),
      "/ui/homes?ticket=" <> ticket(),
      "/ui/home?ticket=" <> string.drop_end(ticket(), 1),
      "/ui/home?ticket=" <> ticket() <> "0",
      "/ui/home?ticket=" <> ticket() <> "&next=/elsewhere",
      "/ui/home?ticket=" <> ticket() <> "#fragment",
      "/ui/home?ticket=" <> string.repeat("zz", 32),
      "x/ui/home?ticket=" <> ticket(),
      "//elsewhere.example/ui/home?ticket=" <> ticket(),
      "https://elsewhere.example/ui/home?ticket=" <> ticket(),
      "/ui/p/key/home?ticket=" <> ticket(),
      "/ui/home?ticket=" <> ticket() <> "/ui/home?ticket=" <> ticket(),
      "/ui/sessions/" <> session <> "/ui/home?ticket=" <> ticket(),
    ],
    fn(value) {
      assert switch_rule.target(value) == Error(Nil)
    },
  )
}

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
