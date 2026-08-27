//// Byte offsets to line numbers, and the one token scan the linter keeps.
////
//// `glance` reports positions as byte offsets; a reader wants a line. The
//// index is built once per file and consumed in a single merged pass over
//// offset-sorted findings, so a file costs one walk rather than a search per
//// finding.
////
//// The keyword scan is the linter's only use of `glexer`. It exists for one
//// rule: R4 is a policy rule, so a `panic` the parser silently dropped would
//// be a hole in the policy rather than a missed suggestion. Scanning tokens
//// rather than raw text is what keeps it from firing on the word `panic`
//// inside a string or a comment — those lex to a single token that never
//// decomposes into the keyword. It is the same fail-closed shape
//// `codemode/vet` uses for `@external`, narrowed to the rule that needs it.

import gleam/bit_array
import gleam/list
import glexer
import glexer/token

/// The byte offset at which each line after the first begins, ascending.
pub fn line_starts(source: String) -> List(Int) {
  source
  |> bit_array.from_string
  |> newlines(0, [])
  |> list.reverse
}

fn newlines(bytes: BitArray, offset: Int, found: List(Int)) -> List(Int) {
  case bytes {
    <<0x0A, rest:bits>> -> newlines(rest, offset + 1, [offset + 1, ..found])
    <<_, rest:bits>> -> newlines(rest, offset + 1, found)
    _ -> found
  }
}

/// The lines of an ascending list of byte offsets, in the same order.
///
/// One merged walk of two ascending sequences: the cost is the file, not the
/// file once per offset.
pub fn lines_of(starts: List(Int), offsets: List(Int)) -> List(Int) {
  walk(offsets, starts, 1, [])
}

fn walk(
  offsets: List(Int),
  starts: List(Int),
  line: Int,
  found: List(Int),
) -> List(Int) {
  case offsets {
    [] -> list.reverse(found)
    [offset, ..rest] -> {
      let #(starts, line) = advance(starts, line, offset)
      walk(rest, starts, line, [line, ..found])
    }
  }
}

fn advance(starts: List(Int), line: Int, offset: Int) -> #(List(Int), Int) {
  case starts {
    [next, ..rest] if next <= offset -> advance(rest, line + 1, offset)
    _ -> #(starts, line)
  }
}

/// The line of one byte offset.
pub fn line_of(starts: List(Int), offset: Int) -> Int {
  case lines_of(starts, [offset]) {
    [line, ..] -> line
    [] -> 1
  }
}

/// Where the token stream says `panic` and `let assert` appear.
///
/// Public so the backstop it feeds can be tested directly: a scanner that
/// quietly saw nothing would make the cross-check vacuous.
///
/// ## Examples
///
/// ```gleam
/// assert source.keyword_offsets("fn f() { panic }").panics == [9]
/// ```
///
/// ```gleam
/// // Not a keyword: a string lexes to one token, never to `panic`.
/// assert source.keyword_offsets("const c = \"panic\"").panics == []
/// ```
///
pub fn keyword_offsets(text: String) -> Keywords {
  glexer.new(text)
  |> glexer.discard_whitespace
  |> glexer.discard_comments
  |> glexer.lex
  |> scan(Keywords([], []))
}

/// Where the token stream says `@external` appears, in source order.
///
/// R6's `@external` half reads tokens rather than the AST, and this is the
/// whole of it. Two reasons, both the same one `codemode/vet` scans tokens
/// for: an external in a file `glance` cannot parse must still be reported
/// rather than reduced to an R0 warning, because R6 is a policy rule and a
/// parser miss there would be a hole in the policy; and the word inside a
/// string or a comment lexes to a single token that never decomposes into
/// `@` followed by `external`, so a text search's false positives never
/// arise.
///
/// ## Examples
///
/// ```gleam
/// let src = "@external(erlang, \"m\", \"f\")\npub fn f() -> Int\n"
/// assert source.external_offsets(src) == [0]
/// ```
///
/// ```gleam
/// // Not an attribute: a string lexes to one token.
/// assert source.external_offsets("const c = \"@external\"") == []
/// ```
///
pub fn external_offsets(text: String) -> List(Int) {
  glexer.new(text)
  |> glexer.discard_whitespace
  |> glexer.discard_comments
  |> glexer.lex
  |> externals([])
}

fn externals(
  tokens: List(#(token.Token, glexer.Position)),
  found: List(Int),
) -> List(Int) {
  case tokens {
    [] -> list.reverse(found)
    [#(token.At, position), #(token.Name("external"), _), ..rest] ->
      externals(rest, [position.byte_offset, ..found])
    [_, ..rest] -> externals(rest, found)
  }
}

/// Byte offsets of the two constructs R4 forbids, in source order.
pub type Keywords {
  Keywords(panics: List(Int), let_asserts: List(Int))
}

fn scan(
  tokens: List(#(token.Token, glexer.Position)),
  found: Keywords,
) -> Keywords {
  case tokens {
    [] -> Keywords(list.reverse(found.panics), list.reverse(found.let_asserts))
    [#(token.Panic, position), ..rest] ->
      scan(
        rest,
        Keywords(..found, panics: [position.byte_offset, ..found.panics]),
      )
    [#(token.Let, position), #(token.Assert, _), ..rest] ->
      scan(
        rest,
        Keywords(..found, let_asserts: [
          position.byte_offset,
          ..found.let_asserts
        ]),
      )
    [_, ..rest] -> scan(rest, found)
  }
}
