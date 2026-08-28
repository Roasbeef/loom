//// `mcp/name` — mangling a server-chosen MCP name into a Gleam
//// identifier, totally and reversibly enough to audit.
////
//// The generated `cap/mcp/<server>` façades (issue #106) need Gleam
//// function names and argument labels for tool and parameter names an
//// untrusted server chose. Wire identity is never at stake here — the
//// generated bodies close over the *original* names as string literals —
//// so a mangled name is a display artifact, and the only hard
//// requirements are that it is a valid Gleam name and that two different
//// originals never silently become one.
////
//// The second requirement is what the digest suffix is for: whenever
//// mangling changed anything at all (or the name ran past the length
//// cap), the result carries `_` plus the first 8 lowercase hex characters
//// of a digest of the *original* name, so `createIssue` and
//// `create_issue` stay distinct and names differing only in case cannot
//// collide. The digest function is injected rather than computed here:
//// this package is pure over `gleam_stdlib` and `core`, and the tree's
//// SHA-256 lives behind FFI in packages this one must not depend on. The
//// contract is lowercase hex over the original's UTF-8 bytes — SHA-256 in
//// production — and only the first 8 characters are used.
////
//// A residual collision after mangling (byte-identical originals, or an
//// engineered digest near-miss) is not repaired; `first_collision` finds
//// it so the caller can refuse the whole module naming the pair.

import gleam/dict.{type Dict}
import gleam/list
import gleam/string

/// Every Gleam keyword: a mangled name landing on one of these gains a
/// trailing underscore (and, having changed, a digest suffix).
const keywords = [
  "as", "assert", "auto", "case", "const", "delegate", "derive", "echo", "else",
  "fn", "if", "implement", "import", "let", "macro", "opaque", "panic", "pub",
  "test", "todo", "type", "use",
]

/// A mangled name longer than this is truncated before the digest suffix
/// is appended, so no generated identifier grows without bound.
const max_length = 32

/// Mangles an original tool or server name into a Gleam function or
/// module-segment name.
///
/// Steps, in order: ASCII letters lowercase (an uppercase following a
/// lowercase or digit first gains `_`), digits kept, every other
/// codepoint becomes `_`, runs of `_` collapse and edges are trimmed; an
/// empty or digit-led result gains a `t_` prefix; a Gleam keyword gains a
/// trailing `_`. If any step changed anything, or the result ran past 32
/// characters (truncated first), the result carries `_` plus the first 8
/// lowercase hex characters of `digest(original)`.
///
/// ## Examples
///
/// ```gleam
/// // name.mangle("create_issue", digest) == "create_issue"
/// // name.mangle("createIssue", digest) == "create_issue_" <> first8
/// ```
///
pub fn mangle(original: String, digest: fn(String) -> String) -> String {
  mangle_against(original, keywords, digest)
}

/// Mangles an original parameter name into a Gleam argument label. The
/// same function as `mangle` with one more reserved word: `options`, the
/// label every generated façade spends on its optional-parameters
/// argument.
///
/// ## Examples
///
/// ```gleam
/// // name.mangle_label("options", digest) == "options_" <> first8
/// ```
///
pub fn mangle_label(original: String, digest: fn(String) -> String) -> String {
  mangle_against(original, ["options", ..keywords], digest)
}

/// The first pair of originals whose mangled names collide, or `Ok(Nil)`
/// when every mangled name is distinct. Input pairs are
/// `#(original, mangled)`; the error carries the two *original* names, in
/// input order, so a refusal can name what the server actually sent.
///
/// ## Examples
///
/// ```gleam
/// assert name.first_collision([#("a", "a"), #("b", "b")]) == Ok(Nil)
/// assert name.first_collision([#("x", "a"), #("y", "a")])
///   == Error(#("x", "y"))
/// ```
///
pub fn first_collision(
  named: List(#(String, String)),
) -> Result(Nil, #(String, String)) {
  collision_loop(named, dict.new())
}

fn collision_loop(
  remaining: List(#(String, String)),
  seen: Dict(String, String),
) -> Result(Nil, #(String, String)) {
  case remaining {
    [] -> Ok(Nil)
    [#(original, mangled), ..rest] ->
      case dict.get(seen, mangled) {
        Ok(earlier) -> Error(#(earlier, original))
        Error(Nil) -> collision_loop(rest, dict.insert(seen, mangled, original))
      }
  }
}

// --- the pipeline ------------------------------------------------------------

fn mangle_against(
  original: String,
  reserved: List(String),
  digest: fn(String) -> String,
) -> String {
  let flattened = flatten(original)
  let fronted = front(flattened)
  let guarded = case list.contains(reserved, fronted) {
    True -> fronted <> "_"
    False -> fronted
  }
  // The bound test stops at the bound instead of walking a 200-char
  // name's whole length (lint R5).
  let oversize = string.drop_start(guarded, max_length) != ""
  case guarded == original && !oversize {
    True -> guarded
    False -> tag(clip(guarded, oversize), digest(original))
  }
}

// `t_` fronts a name that cannot lead: empty (every codepoint was
// mangled away) or digit-first (valid nowhere in a Gleam name's lead).
fn front(flattened: String) -> String {
  case flattened == "" || digit_led(flattened) {
    True -> "t_" <> flattened
    False -> flattened
  }
}

fn digit_led(text: String) -> Bool {
  case string.to_utf_codepoints(text) {
    [] -> False
    [first, ..] -> {
      let code = string.utf_codepoint_to_int(first)
      code >= 0x30 && code <= 0x39
    }
  }
}

fn clip(text: String, oversize: Bool) -> String {
  case oversize {
    True -> string.slice(text, 0, max_length)
    False -> text
  }
}

// The digest join never doubles an underscore: a keyword-guarded or
// truncation-cut base can already end in one.
fn tag(base: String, digest_hex: String) -> String {
  let suffix = string.lowercase(string.slice(digest_hex, 0, 8))
  case string.ends_with(base, "_") {
    True -> base <> suffix
    False -> base <> "_" <> suffix
  }
}

// --- codepoint translation ---------------------------------------------------

// Whether the previous *original* codepoint was a lowercase letter or a
// digit — the one fact the camelCase rule needs.
type Previous {
  LowerOrDigit
  Boundary
}

type Class {
  LowerCase
  Digit
  UpperCase
  Other
}

fn flatten(original: String) -> String {
  let #(pieces, _) =
    list.fold(string.to_utf_codepoints(original), #([], Boundary), step)
  pieces
  |> list.reverse
  |> string.concat
  |> collapse
}

fn step(
  state: #(List(String), Previous),
  codepoint: UtfCodepoint,
) -> #(List(String), Previous) {
  let #(pieces, previous) = state
  let code = string.utf_codepoint_to_int(codepoint)
  case classify(code), previous {
    LowerCase, _ -> #([ascii(code), ..pieces], LowerOrDigit)
    Digit, _ -> #([ascii(code), ..pieces], LowerOrDigit)
    UpperCase, LowerOrDigit -> #(["_" <> ascii(code + 32), ..pieces], Boundary)
    UpperCase, Boundary -> #([ascii(code + 32), ..pieces], Boundary)
    Other, _ -> #(["_", ..pieces], Boundary)
  }
}

fn classify(code: Int) -> Class {
  case code {
    _ if code >= 0x61 && code <= 0x7A -> LowerCase
    _ if code >= 0x30 && code <= 0x39 -> Digit
    _ if code >= 0x41 && code <= 0x5A -> UpperCase
    _ -> Other
  }
}

// Total by fallback: `step` only feeds ASCII codes, for which
// `string.utf_codepoint` cannot fail, but the seam stays panic-free.
fn ascii(code: Int) -> String {
  case string.utf_codepoint(code) {
    Ok(codepoint) -> string.from_utf_codepoints([codepoint])
    Error(Nil) -> "_"
  }
}

fn collapse(text: String) -> String {
  string.split(text, "_")
  |> list.filter(fn(part) { part != "" })
  |> string.join("_")
}
