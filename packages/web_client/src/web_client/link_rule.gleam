//// What `<loom-link>` decides: whether the destination text the server sent
//// is an address the browser may open, and which one.
////
//// A model's Markdown link carries a destination the model chose. The server
//// never turns session text into an attribute (protocol-change/051), so it
//// draws the destination as hidden text inside `<loom-link>`; the element
//// reads that text and calls `destination` before it makes anything
//// clickable. This module is the whole decision, kept free of Lustre and the
//// DOM so the tests load it under Node (`scripts/web_client_test.sh` checks
//// that).
////
//// The rule is a text check, not a parse, and it is stricter than the
//// browser's own `URL` constructor on purpose. The constructor forgives what
//// a hostile destination can use: it strips leading and trailing whitespace,
//// removes tabs and newlines from inside, reads a backslash as a slash and
//// accepts `user:pass@host`. A check that parsed first and tested the result
//// would approve a string the page then handed the browser unchanged, so the
//// string itself must already be a plain absolute address:
////
//// - it starts with `http://` or `https://`, in any letter case, with
////   nothing before it, so `javascript:`, `data:`, `file:`, `vbscript:`, a
////   scheme-relative `//host` and a relative path are all refused;
//// - it holds no space, control character or invisible separator anywhere,
////   and no backslash;
//// - its authority, the text between `//` and the first `/`, `?` or `#`, is
////   not empty, does not start with a port and has no `@`, so a link cannot
////   dress one host up as another with credentials;
//// - it is at most `limit` characters long.
////
//// What passes is returned unchanged, so the address the person sees in the
//// hover title is exactly the one the browser opens.

import gleam/list
import gleam/result
import gleam/string

/// The longest destination accepted, in characters. It is the usual ceiling
/// browsers and servers agree on for an address.
pub const limit = 2048

/// The address to open for a destination the server sent as text, or an error
/// when the text is not a plain absolute `http` or `https` address. The text
/// is returned exactly as given.
///
/// ## Examples
///
/// ```gleam
/// assert link_rule.destination("https://example.com/a?b=1#c")
///   == Ok("https://example.com/a?b=1#c")
/// assert link_rule.destination("javascript:alert(1)") == Error(Nil)
/// assert link_rule.destination("https://user:pw@example.com/") == Error(Nil)
/// ```
pub fn destination(text: String) -> Result(String, Nil) {
  let codepoints = string.to_utf_codepoints(text)

  use _ <- result.try(within_limit(codepoints))
  use _ <- result.try(plain(codepoints))
  use authority <- result.try(authority(text))
  use _ <- result.try(host_only(authority))
  Ok(text)
}

// The text is not longer than the limit, counted in code points.
fn within_limit(codepoints: List(a)) -> Result(Nil, Nil) {
  case list.length(codepoints) > limit {
    True -> Error(Nil)
    False -> Ok(Nil)
  }
}

// No character the browser would drop, rewrite or hide: whitespace and
// control characters, a backslash, and the invisible separators.
fn plain(codepoints: List(UtfCodepoint)) -> Result(Nil, Nil) {
  case
    list.all(codepoints, fn(point) {
      allowed(string.utf_codepoint_to_int(point))
    })
  {
    True -> Ok(Nil)
    False -> Error(Nil)
  }
}

fn allowed(code: Int) -> Bool {
  case code {
    _ if code <= 0x20 -> False
    _ if code == 0x5c -> False
    _ if code >= 0x7f && code <= 0xa0 -> False
    _ if code >= 0x2060 && code <= 0x2069 -> False
    _ if code >= 0x2000 && code <= 0x200f -> False
    _ if code >= 0x2028 && code <= 0x202f -> False
    0xad | 0x61c | 0x3000 | 0xfeff -> False
    _ -> True
  }
}

// The authority of an `http` or `https` address: what follows the scheme and
// `//`, up to the first `/`, `?` or `#`. The scheme is matched in any case
// because the browser reads it that way; nothing else may stand before it.
fn authority(text: String) -> Result(String, Nil) {
  let lowered = string.lowercase(text)
  use rest <- result.try(case string.starts_with(lowered, "https://") {
    True -> Ok(string.drop_start(text, 8))
    False ->
      case string.starts_with(lowered, "http://") {
        True -> Ok(string.drop_start(text, 7))
        False -> Error(Nil)
      }
  })
  Ok(until_path(string.to_graphemes(rest), []))
}

fn until_path(rest: List(String), kept: List(String)) -> String {
  case rest {
    [] | ["/", ..] | ["?", ..] | ["#", ..] -> string.concat(list.reverse(kept))
    [next, ..more] -> until_path(more, [next, ..kept])
  }
}

// A host to go to and nothing that names another: not empty, not a bare
// port, and no credentials.
fn host_only(authority: String) -> Result(Nil, Nil) {
  case authority == "" || string.starts_with(authority, ":") {
    True -> Error(Nil)
    False ->
      case string.contains(authority, "@") {
        True -> Error(Nil)
        False -> Ok(Nil)
      }
  }
}

/// The text to show after a label whose destination `destination` refused: the
/// destination itself, cut to `limit` characters, or nothing when it is empty
/// or only repeats the label (a bare `www.` address or an email carries the
/// scheme the parser added).
///
/// ## Examples
///
/// ```gleam
/// assert link_rule.hint("README", "docs/README.md") == "docs/README.md"
/// assert link_rule.hint("x.test", "http://x.test") == ""
/// ```
pub fn hint(label: String, destination: String) -> String {
  let repeats =
    destination == ""
    || destination == label
    || destination == "http://" <> label
    || destination == "mailto:" <> label
  case repeats {
    True -> ""
    False -> string.slice(destination, 0, limit)
  }
}
