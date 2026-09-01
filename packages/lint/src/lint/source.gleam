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
////
//// The line classification below is the other thing that lives here, and it
//// is here for the same reason the offsets are: R10 and R11 are questions
//// about *layout*, and layout is the one property `glance` throws away.
//// The parser drops comments and blank lines entirely — a formatter-shaped
//// AST cannot tell you whether two statements were written as one paragraph
//// or two — so the rules that ask about stanzas have to read the file as
//// text alongside the tree. Classifying once per file, into a table both
//// rules index, is what keeps that from becoming a scan per statement.

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/string
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

// --- lines, as a reader sees them -------------------------------------------

/// What one line of a file is, for the two rules that care how the file was
/// laid out rather than what it parses to.
pub type LineKind {
  /// Nothing but whitespace. The stanza break.
  Blank
  /// A `//`, `///` or `////` comment and nothing before it. A comment
  /// *after* code on the same line is `Code`: it annotates the line it sits
  /// on rather than opening a stanza, and the house rule forbids it anyway.
  CommentLine
  /// Anything else, including a line that is only a closing bracket of a
  /// literal the formatter wrapped.
  Code
}

/// A file's lines, classified once and indexed by line number.
///
/// `starts` is `line_starts`' output, kept here so a caller that has
/// classified a file does not walk it a second time to locate findings.
pub type Lines {
  Lines(
    starts: List(Int),
    kinds: Dict(Int, LineKind),
    /// Line number to the byte offset it begins at — the inverse of
    /// `lines_of`, and what lets a finding about line *k* point at a byte.
    offsets: Dict(Int, Int),
  )
}

/// Classify every line of a file.
///
/// The comment test is over `glexer`'s tokens rather than over the text, for
/// the reason the keyword scan is: a line of a multi-line string beginning
/// `// …` is a string, and a rule that told its author to put a blank line
/// above it would be wrong in a way no one could act on. Requiring both a
/// comment token on the line *and* a leading `//` in the text is what
/// separates a comment that opens a stanza from one trailing a statement.
///
/// ## Examples
///
/// ```gleam
/// let lines = source.classify("let x = 1\n\n// why\nlet y = 2\n")
/// assert source.kind_of(lines, 2) == source.Blank
/// assert source.kind_of(lines, 3) == source.CommentLine
/// ```
///
pub fn classify(code: String) -> Lines {
  let texts = string.split(code, "\n")
  classify_loop(
    texts,
    comment_offsets(code),
    1,
    0,
    Lines(starts: [], kinds: dict.new(), offsets: dict.new()),
  )
}

fn classify_loop(
  texts: List(String),
  comments: List(Int),
  line: Int,
  offset: Int,
  found: Lines,
) -> Lines {
  case texts {
    [] -> Lines(..found, starts: list.reverse(found.starts))
    [text, ..rest] -> {
      // A line owns the offsets from where it begins up to its newline, so
      // the comment cursor advances past every token that started on it
      // before the next line is asked about.
      let limit = offset + string.byte_size(text)
      let #(commented, comments) = consume(comments, limit)
      let found =
        Lines(
          // Line 1 begins at 0, which `line_starts` does not report; every
          // later line begins one byte past the newline that ended the one
          // before, which is exactly what it does report.
          starts: case line {
            1 -> found.starts
            _ -> [offset, ..found.starts]
          },
          kinds: dict.insert(found.kinds, line, kind_of_text(text, commented)),
          offsets: dict.insert(found.offsets, line, offset),
        )
      classify_loop(rest, comments, line + 1, limit + 1, found)
    }
  }
}

/// Drop every comment offset that begins before `limit`, and say whether
/// there was one. Ascending offsets against ascending lines, so the whole
/// file costs one walk rather than a search per line.
fn consume(comments: List(Int), limit: Int) -> #(Bool, List(Int)) {
  case comments {
    [first, ..rest] if first < limit -> #(True, drop_before(rest, limit))
    _ -> #(False, comments)
  }
}

fn drop_before(comments: List(Int), limit: Int) -> List(Int) {
  case comments {
    [first, ..rest] if first < limit -> drop_before(rest, limit)
    _ -> comments
  }
}

fn kind_of_text(text: String, commented: Bool) -> LineKind {
  case string.trim(text), commented {
    "", _ -> Blank
    trimmed, True ->
      case string.starts_with(trimmed, "//") {
        True -> CommentLine
        False -> Code
      }
    _, False -> Code
  }
}

/// What kind of line this is. A line number outside the file reads as
/// `Code`, which is the answer that makes the callers right: R10 asks about
/// the line above a comment, and a comment on line 1 has nothing above it
/// that a blank line could be added to.
pub fn kind_of(lines: Lines, line: Int) -> LineKind {
  case dict.get(lines.kinds, line) {
    Ok(kind) -> kind
    Error(Nil) -> Code
  }
}

/// The byte offset a line begins at, for a finding that was decided in line
/// numbers and has to be reported in offsets like every other.
pub fn offset_of(lines: Lines, line: Int) -> Int {
  case dict.get(lines.offsets, line) {
    Ok(offset) -> offset
    Error(Nil) -> 0
  }
}

/// The line each of these byte offsets falls on, as a lookup table.
///
/// The offsets arrive in whatever order an AST walk produced them, so they
/// are sorted here and resolved in the one merged pass `lines_of` performs.
/// This is the whole reason `lint/layout` emits offsets and asks about lines
/// afterwards rather than converting as it walks: a `line_of` per statement
/// would be a walk of the file per statement.
pub fn line_map(starts: List(Int), offsets: List(Int)) -> Dict(Int, Int) {
  let ordered = list.sort(list.unique(offsets), int.compare)
  list.fold(
    list.zip(ordered, lines_of(starts, ordered)),
    dict.new(),
    fn(found, pair) { dict.insert(found, pair.0, pair.1) },
  )
}

/// Where the token stream says a comment begins, in source order.
///
/// Written as a walk over the token list rather than a filter over one
/// token, so the catch-all is over a *list shape* the way `externals`' is
/// and not over `glexer`'s sixty-variant token type.
fn comment_offsets(text: String) -> List(Int) {
  glexer.new(text)
  |> glexer.discard_whitespace
  |> glexer.lex
  |> comments([])
}

fn comments(
  tokens: List(#(token.Token, glexer.Position)),
  found: List(Int),
) -> List(Int) {
  case tokens {
    [] -> list.reverse(found)
    [#(token.CommentDoc(_), position), ..rest]
    | [#(token.CommentNormal(_), position), ..rest]
    | [#(token.CommentModule(_), position), ..rest] ->
      comments(rest, [position.byte_offset, ..found])
    [_, ..rest] -> comments(rest, found)
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
