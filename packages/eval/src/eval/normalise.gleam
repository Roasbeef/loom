//// The semantic view of a provider request, for the replay lane.
////
//// The replay lane asks one question of every request a replayed trial makes:
//// is this the request the tape was recorded against? Comparing raw bytes
//// would answer "no" for reasons that have nothing to do with the harness
//// under test, because a request carries things that legitimately differ run
//// to run: the trial's scratch directory, the clock, and the credentials and
//// request ids in its headers. This module reduces a request to the part that
//// is meaningful (the method, the URL path, and the JSON body) and removes
//// those differences before anything is hashed.
////
//// The reduction is a list of leaves, one per scalar in the body, each named
//// by its path (`body.system`, `body.messages[2].role`). The digest is a
//// SHA-256 of the full leaf text; the tape keeps only a length and a short
//// fingerprint per leaf. That is enough to say *where* two requests first
//// differ without ever writing a prompt, or a credential somebody pasted
//// into one, to disk.
////
//// What is deliberately not in the view:
////
//// - Headers, entirely. They carry the API key and per-request ids, and the
////   transport contract already keeps them out of every returned structure.
//// - The URL's host and query. The query is where credentials sometimes ride
////   when a header is not available.
//// - Any object key that names a secret, at any depth.
////
//// ## Flow
////
//// - `view`: request to leaves plus digest
//// - `request_digest`: the digest alone
//// - `summary`: where two leaf lists first differ, redacted

import client/evolution/trace
import client/mcp
import core/json.{type JsonValue}
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import gleam/uri
import provider/http.{type HttpRequest}

/// One scalar of the normalised request, reduced to what a diff needs.
///
/// A leaf never carries the value it stands for: the fingerprint is a short
/// prefix of a hash, so two leaves are equal exactly when their text was,
/// and nothing can be read back from it.
pub type Leaf {
  Leaf(
    /// Where the scalar sat: `method`, `path`, or `body` followed by keys
    /// and array indexes.
    path: String,
    /// The scalar's length in graphemes, after normalisation.
    length: Int,
    /// The first twelve hex digits of the SHA-256 of the scalar's text.
    fingerprint: String,
  )
}

/// A request reduced to its semantic content.
pub type View {
  View(
    /// The SHA-256, in hex, of every leaf's path and full text in order.
    digest: String,
    /// The leaves the digest was taken over, with their text discarded.
    leaves: List(Leaf),
  )
}

/// Reduces a request to its semantic view.
///
/// `root` is the trial's workspace directory: every occurrence in the URL
/// path or body is rewritten to `<root>` so a replay in a different scratch
/// directory is the same request. A body that is not JSON is normalised as
/// one text leaf.
///
/// ## Examples
///
/// ```gleam
/// let request = http.HttpRequest("POST", "https://h/v1/messages", [], "{}")
/// assert normalise.view(request, "/work").digest
///   == normalise.request_digest(request, "/work")
/// ```
///
pub fn view(request: HttpRequest, root: String) -> View {
  let named = [
    #("method", request.method),
    #("path", text(url_path(request.url), root)),
    ..body_leaves(request.body, root)
  ]
  let lines =
    list.map(named, fn(pair) { pair.0 <> "\t" <> pair.1 })
    |> string.join("\n")

  View(digest: mcp.sha256_hex(lines), leaves: list.map(named, leaf))
}

/// The digest of a request's semantic view.
///
/// Headers never contribute: two requests differing only in credentials or
/// request ids digest identically.
///
/// ## Examples
///
/// ```gleam
/// let a = http.HttpRequest("POST", "https://h/m", [#("x-api-key", "one")], "{}")
/// let b = http.HttpRequest("POST", "https://h/m", [#("x-api-key", "two")], "{}")
/// assert normalise.request_digest(a, "/w") == normalise.request_digest(b, "/w")
/// ```
///
pub fn request_digest(request: HttpRequest, root: String) -> String {
  view(request, root).digest
}

/// Rewrites every absolute path under `root` to `<root>` and every ISO-8601
/// date or date-time to `<date>`.
///
/// An empty root rewrites nothing: replacing the empty string would insert
/// the marker between every pair of characters.
///
/// ## Examples
///
/// ```gleam
/// assert normalise.text("see /w/a.txt at 2026-01-02T03:04:05Z", "/w")
///   == "see <root>/a.txt at <date>"
/// ```
///
pub fn text(text: String, root: String) -> String {
  let trimmed = trim_root(root)

  // An empty root names no directory, and replacing it would corrupt the text.
  let rooted = case trimmed {
    "" -> text
    _ -> string.replace(text, trimmed, "<root>")
  }

  rooted
  |> string.to_graphemes
  |> dates([])
  |> string.concat
}

/// Says where two views first differ, without echoing any value.
///
/// The answer names the path and the two lengths only. Paths come from
/// request keys, which a model can influence, so they pass through the
/// harness credential scrubber too.
///
/// ## Examples
///
/// ```gleam
/// let a = normalise.view(http.HttpRequest("POST", "https://h/m", [], "{\"system\":\"one\"}"), "/w")
/// let b = normalise.view(http.HttpRequest("POST", "https://h/m", [], "{\"system\":\"two!\"}"), "/w")
/// assert normalise.summary(a.leaves, b.leaves)
///   == "body.system changed (expected 5 chars, actual 6 chars)"
/// ```
///
pub fn summary(expected: List(Leaf), actual: List(Leaf)) -> String {
  case expected, actual {
    [], [] -> "no difference in the normalised request"

    [], [extra, ..] -> "unexpected " <> name(extra.path) <> " in the request"

    [missing, ..], [] -> "request ends before " <> name(missing.path)

    [one, ..rest_expected], [other, ..rest_actual] ->
      case one == other {
        True -> summary(rest_expected, rest_actual)
        False -> difference(one, other)
      }
  }
}

/// Describes how two leaves at the same position differ.
fn difference(expected: Leaf, actual: Leaf) -> String {
  case expected.path == actual.path {
    True ->
      name(expected.path)
      <> " changed (expected "
      <> int.to_string(expected.length)
      <> " chars, actual "
      <> int.to_string(actual.length)
      <> " chars)"
    False ->
      "structure differs: expected "
      <> name(expected.path)
      <> ", actual "
      <> name(actual.path)
  }
}

// A path is rendered through the credential scrubber because its keys are
// request content, not harness vocabulary.
fn name(path: String) -> String {
  trace.scrub_excerpt(path, 120)
}

/// Reduces a path and its text to a leaf: a length and a hash prefix.
fn leaf(pair: #(String, String)) -> Leaf {
  Leaf(
    path: pair.0,
    length: string.length(pair.1),
    fingerprint: string.slice(mcp.sha256_hex(pair.1), 0, 12),
  )
}

fn trim_root(root: String) -> String {
  case string.ends_with(root, "/") {
    True -> trim_root(string.drop_end(root, 1))
    False -> root
  }
}

/// The path of a URL, with host and query discarded.
/// Only the path of the URL is semantic. A URL the parser refuses is cut at
/// its query so a credential riding there still never reaches the digest.
fn url_path(url: String) -> String {
  case uri.parse(url) {
    Ok(parsed) -> parsed.path
    Error(Nil) ->
      string.split(url, "?")
      |> list.first
      |> result.unwrap(url)
  }
}

// A JSON body becomes one leaf per scalar; anything else is one text leaf,
// so a provider that sends form data still has a stable digest.
fn body_leaves(body: String, root: String) -> List(#(String, String)) {
  case json.parse(body) {
    Ok(value) -> walk(json.canonical(value), "body", root)
    Error(_) -> [#("body", text(body, root))]
  }
}

/// Flattens a canonical JSON value into path and text pairs, dropping every
/// object key that names a secret.
fn walk(
  value: JsonValue,
  path: String,
  root: String,
) -> List(#(String, String)) {
  case value {
    json.Object(fields:) ->
      case list.filter(fields, fn(field) { !secret_key(field.0) }) {
        [] -> [#(path, "{}")]
        kept ->
          list.flat_map(kept, fn(field) {
            walk(field.1, path <> "." <> field.0, root)
          })
      }

    json.Array(items: []) -> [#(path, "[]")]

    json.Array(items:) ->
      list.index_map(items, fn(item, index) {
        walk(item, path <> "[" <> int.to_string(index) <> "]", root)
      })
      |> list.flatten

    json.String(value:) -> [
      #(path, json.to_string(json.String(text(value, root)))),
    ]

    json.Int(..) | json.Float(..) | json.Bool(..) | json.Null -> [
      #(path, json.to_string(value)),
    ]
  }
}

const secret_keys = [
  "api_key", "apikey", "authorization", "x_api_key", "password", "secret",
  "client_secret", "access_token", "refresh_token", "id_token", "bearer",
  "cookie", "set_cookie", "proxy_authorization", "private_key", "credentials",
]

/// Whether an object key names a credential.
/// Whether an object key names a credential. The key is folded to lowercase
/// with underscores so `X-Api-Key` and `x_api_key` are one name. `token` alone
/// is not in the list: `max_tokens` is a semantic field, and dropping it would
/// hide a real change.
fn secret_key(key: String) -> Bool {
  let folded = key |> string.lowercase |> string.replace("-", "_")

  list.contains(secret_keys, folded)
  || string.ends_with(folded, "_secret")
  || string.ends_with(folded, "_api_key")
  || string.ends_with(folded, "_password")
}

/// Walks graphemes, replacing each ISO-8601 date or date-time with a marker.
/// A match must not directly follow a digit, so a longer number that merely
/// ends in date-shaped digits is left alone.
fn dates(chars: List(String), out: List(String)) -> List(String) {
  // A date is replaced only when it starts a number; otherwise the grapheme
  // is kept and the scan moves on.
  case follows_digit(out), iso_date(chars) {
    False, Ok(rest) -> dates(rest, ["<date>", ..out])
    True, Ok(_) | _, Error(Nil) -> advance(chars, out)
  }
}

/// Whether the most recently kept grapheme is a digit.
fn follows_digit(out: List(String)) -> Bool {
  // The scan keeps graphemes newest first, so the head is the previous one.
  case out {
    [last, ..] -> digit(last)
    [] -> False
  }
}

/// Keeps one grapheme and continues the scan, or finishes it.
fn advance(chars: List(String), out: List(String)) -> List(String) {
  // An empty input is the end of the scan; otherwise one grapheme is kept.
  case chars {
    [] -> list.reverse(out)
    [char, ..rest] -> dates(rest, [char, ..out])
  }
}

fn digit(char: String) -> Bool {
  list.contains(["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"], char)
}

/// Matches `YYYY-MM-DD` and any complete time and zone after it, returning the
/// text that follows.
/// `YYYY-MM-DD`, optionally followed by a time and a zone. The time and zone
/// are only consumed when complete, so prose that follows a bare date is kept.
fn iso_date(chars: List(String)) -> Result(List(String), Nil) {
  use rest <- result.try(digits(chars, 4))
  use rest <- result.try(literal(rest, "-"))
  use rest <- result.try(digits(rest, 2))
  use rest <- result.try(literal(rest, "-"))
  use rest <- result.try(digits(rest, 2))

  Ok(time(rest))
}

/// Consumes exactly `count` digits.
fn digits(chars: List(String), count: Int) -> Result(List(String), Nil) {
  case count, chars {
    0, _ -> Ok(chars)
    _, [char, ..rest] ->
      case digit(char) {
        True -> digits(rest, count - 1)
        False -> Error(Nil)
      }
    _, [] -> Error(Nil)
  }
}

fn literal(chars: List(String), expected: String) -> Result(List(String), Nil) {
  case chars {
    [char, ..rest] if char == expected -> Ok(rest)
    [_, ..] | [] -> Error(Nil)
  }
}

/// Consumes a complete `T` or space separated time and zone if one follows.
fn time(chars: List(String)) -> List(String) {
  case chars {
    ["T", ..after] | [" ", ..after] ->
      clock(after)
      |> result.map(zone)
      |> result.unwrap(chars)
    [_, ..] | [] -> chars
  }
}

/// Consumes `hh:mm` and optional seconds.
fn clock(chars: List(String)) -> Result(List(String), Nil) {
  use rest <- result.try(digits(chars, 2))
  use rest <- result.try(literal(rest, ":"))
  use rest <- result.try(digits(rest, 2))

  Ok(seconds(rest))
}

fn seconds(chars: List(String)) -> List(String) {
  literal(chars, ":")
  |> result.try(digits(_, 2))
  |> result.map(fraction)
  |> result.unwrap(chars)
}

/// Consumes a decimal fraction of a second if one is present.
fn fraction(chars: List(String)) -> List(String) {
  case chars {
    [".", next, ..rest] ->
      case digit(next) {
        True -> drop_digits(rest)
        False -> chars
      }
    [_, ..] | [] -> chars
  }
}

/// Consumes a run of digits.
fn drop_digits(chars: List(String)) -> List(String) {
  case chars {
    [char, ..rest] ->
      case digit(char) {
        True -> drop_digits(rest)
        False -> chars
      }
    [] -> chars
  }
}

/// Consumes `Z` or a numeric offset if one is present.
fn zone(chars: List(String)) -> List(String) {
  case chars {
    ["Z", ..rest] -> rest
    ["+", ..after] | ["-", ..after] ->
      offset(after)
      |> result.unwrap(chars)
    [_, ..] | [] -> chars
  }
}

/// Consumes the digits of a `+hh:mm` or `+hhmm` offset.
fn offset(chars: List(String)) -> Result(List(String), Nil) {
  use rest <- result.try(digits(chars, 2))

  // Both `+01:00` and `+0100` are ISO-8601 offsets.
  case literal(rest, ":") {
    Ok(after_colon) -> digits(after_colon, 2)
    Error(Nil) -> digits(rest, 2)
  }
}
