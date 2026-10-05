//// What `<loom-link>` decides (`web_client/link_rule`): which destination
//// texts the browser may open.

import gleam/string
import web_client/link_rule

pub fn http_and_https_addresses_are_accepted_test() {
  assert link_rule.destination("https://example.com/a?b=1#c")
    == Ok("https://example.com/a?b=1#c")
  assert link_rule.destination("http://localhost:8080")
    == Ok("http://localhost:8080")
  assert link_rule.destination("https://[::1]:3000/x")
    == Ok("https://[::1]:3000/x")
}

// The browser reads the scheme without regard to case, so the rule does too;
// the text is returned as it came.
pub fn the_scheme_may_be_in_any_case_test() {
  assert link_rule.destination("HTTPS://Example.com")
    == Ok("HTTPS://Example.com")
}

pub fn other_schemes_are_refused_test() {
  assert link_rule.destination("javascript:alert(1)") == Error(Nil)
  assert link_rule.destination("JaVaScRiPt:alert(1)") == Error(Nil)
  assert link_rule.destination("data:text/html,<b>x</b>") == Error(Nil)
  assert link_rule.destination("file:///etc/passwd") == Error(Nil)
  assert link_rule.destination("vbscript:msgbox(1)") == Error(Nil)
  assert link_rule.destination("mailto:a@x.test") == Error(Nil)
  assert link_rule.destination("ftp://example.com/") == Error(Nil)
}

pub fn an_address_with_no_scheme_is_refused_test() {
  assert link_rule.destination("//example.com/a") == Error(Nil)
  assert link_rule.destination("example.com") == Error(Nil)
  assert link_rule.destination("/relative/path") == Error(Nil)
  assert link_rule.destination("http:example.com") == Error(Nil)
  assert link_rule.destination("") == Error(Nil)
}

// The browser's `URL` constructor strips these, so a parse-then-test check
// would pass them. The text must already be plain.
pub fn whitespace_and_control_characters_are_refused_test() {
  assert link_rule.destination(" https://example.com") == Error(Nil)
  assert link_rule.destination("\thttps://example.com") == Error(Nil)
  assert link_rule.destination("\nhttps://example.com") == Error(Nil)
  assert link_rule.destination("https://example.com ") == Error(Nil)
  assert link_rule.destination("java\tscript:alert(1)") == Error(Nil)
  assert link_rule.destination("https://exa\nmple.com") == Error(Nil)
  assert link_rule.destination("https://example.com/\u{0000}") == Error(Nil)
  assert link_rule.destination("https://example.com/a b") == Error(Nil)
  assert link_rule.destination("https://example.com/\u{200b}") == Error(Nil)
  assert link_rule.destination("\u{00a0}https://example.com") == Error(Nil)
}

pub fn a_backslash_is_refused_test() {
  assert link_rule.destination("https://good.test\\@evil.test/") == Error(Nil)
  assert link_rule.destination("https:\\\\example.com") == Error(Nil)
}

pub fn credentials_are_refused_test() {
  assert link_rule.destination("https://user:pw@example.com/") == Error(Nil)
  assert link_rule.destination("https://user@example.com/") == Error(Nil)
  assert link_rule.destination("https://good.test@evil.test/") == Error(Nil)
}

// An `@` after the first slash belongs to the path, not the authority.
pub fn an_at_sign_in_the_path_is_allowed_test() {
  assert link_rule.destination("https://example.com/@user")
    == Ok("https://example.com/@user")
  assert link_rule.destination("https://example.com?to=a@b")
    == Ok("https://example.com?to=a@b")
}

pub fn an_address_with_no_host_is_refused_test() {
  assert link_rule.destination("https://") == Error(Nil)
  assert link_rule.destination("https:///path") == Error(Nil)
  assert link_rule.destination("https://:80/") == Error(Nil)
  assert link_rule.destination("https://?x=1") == Error(Nil)
}

pub fn a_destination_at_the_limit_is_accepted_and_one_over_is_refused_test() {
  let at = "https://example.com/" <> string.repeat("a", link_rule.limit - 20)
  assert string.length(at) == link_rule.limit
  assert link_rule.destination(at) == Ok(at)
  assert link_rule.destination(at <> "a") == Error(Nil)
}

pub fn a_very_long_destination_is_refused_test() {
  let long = "https://example.com/" <> string.repeat("a", 100_000)
  assert link_rule.destination(long) == Error(Nil)
}

// Bidi isolates and other invisible characters can reorder or hide part of an
// address as the hover title draws it.
pub fn invisible_and_bidi_characters_are_refused_test() {
  assert link_rule.destination("https://example.com/\u{2066}a") == Error(Nil)
  assert link_rule.destination("https://example.com/\u{2069}") == Error(Nil)
  assert link_rule.destination("https://example.com/\u{2060}") == Error(Nil)
  assert link_rule.destination("https://example.com/\u{2065}") == Error(Nil)
  assert link_rule.destination("https://exam\u{00ad}ple.com/") == Error(Nil)
  assert link_rule.destination("https://example.com/\u{061c}") == Error(Nil)
}

pub fn a_refused_destination_is_shown_as_a_hint_test() {
  assert link_rule.hint("README", "docs/README.md") == "docs/README.md"
  assert link_rule.hint("click", "javascript:alert(1)") == "javascript:alert(1)"
}

pub fn a_hint_that_repeats_the_label_is_dropped_test() {
  assert link_rule.hint("", "") == ""
  assert link_rule.hint("x.test", "x.test") == ""
  assert link_rule.hint("www.x.test", "http://www.x.test") == ""
  assert link_rule.hint("me@x.test", "mailto:me@x.test") == ""
}

pub fn a_long_hint_is_cut_test() {
  let long = string.repeat("a", link_rule.limit + 50)
  assert string.length(link_rule.hint("x", long)) == link_rule.limit
}
