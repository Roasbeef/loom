//// R22, `///` documentation comments on public functions and non-trivial
//// private helpers.
////
//// `CLAUDE.md` ("Literate code") and `docs/gleam-style.md` Part II ("Doc
//// comments") require `///` documentation on every public function and
//// prose explaining the contract of each helper beyond a trivial one-liner.
//// Without a rule, a module can pass every other check with zero function
//// documentation (`client/mcp/http.gleam` in PR #1077 had three private
//// helpers spanning 19 to 52 lines with no `///` or `//` comment on any of
//// them).
////
//// Two classes of functions are checked:
////
//// 1. **Public functions (`pub fn`)** in any module that carries a `////`
////    module doc, or any public function whose body spans strictly more than
////    `policy.function_doc_lines` lines (except `main` entry points and
////    `_test` functions under test policy).
//// 2. **Referenced private helpers (`fn`)** whose definition spans strictly
////    more than `policy.function_doc_lines` lines (default 6, where R18's
////    short-helper census leaves off).
////
//// Documentation is lexed from `glexer`'s `CommentDoc` (`///`) tokens rather
//// than matched as text so a `///` inside a multi-line string literal never
//// silences a missing doc comment, and neither a plain `//` comment nor a
//// `////` module comment counts as an item doc comment.

import glance
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import gleam/string
import glexer
import glexer/token
import lint/calls
import lint/finding
import lint/module_doc.{type DocLine}
import lint/policy.{type Policy}
import lint/scan.{type Raw, Raw}
import lint/source.{type Lines}

/// Every R22 finding this rule makes about one parsed module.
///
/// ## Examples
///
/// ```gleam
/// let code = "//// Module doc.\n\npub fn run(x: Int) -> Int {\n  x + 1\n}\n"
/// let assert Ok(parsed) = glance.module(code)
/// let lines = source.classify(code)
/// let found = function_doc.findings(parsed, code, lines, policy.default(), "x")
/// assert list.length(found) == 1
/// ```
///
pub fn findings(
  module: glance.Module,
  code: String,
  lines: Lines,
  policy: Policy,
  own_path: String,
) -> List(Raw) {
  findings_with_doc(
    module,
    code,
    module_doc.lines(code),
    lines,
    policy,
    own_path,
  )
}

/// `findings`, taking the already-lexed module doc lines so `lint.check_with`
/// lexes `////` comments once per file.
///
/// ## Examples
///
/// ```gleam
/// let code = "//// Module doc.\n\n/// Adds one.\npub fn run(x: Int) -> Int {\n  x + 1\n}\n"
/// let assert Ok(parsed) = glance.module(code)
/// let doc = module_doc.lines(code)
/// let lines = source.classify(code)
/// assert function_doc.findings_with_doc(parsed, code, doc, lines, policy.default(), "x") == []
/// ```
///
pub fn findings_with_doc(
  module: glance.Module,
  code: String,
  doc: List(DocLine),
  lines: Lines,
  policy: Policy,
  own_path: String,
) -> List(Raw) {
  let _ = own_path
  let #(doc_lines, attr_starts) = lex_doc_and_attributes(code, lines)
  let referenced_private =
    module
    |> calls.private_helpers
    |> list.map(fn(helper) { helper.function.name })
    |> set.from_list

  module.functions
  |> list.sort(fn(left, right) {
    int.compare(left.definition.location.start, right.definition.location.start)
  })
  |> list.filter_map(fn(definition) {
    check_function(
      definition,
      doc,
      lines,
      policy,
      referenced_private,
      doc_lines,
      attr_starts,
    )
  })
}

/// Checks one function definition and returns an R22 finding when it owes a
/// `///` doc comment and has none.
fn check_function(
  definition: glance.Definition(glance.Function),
  doc: List(DocLine),
  lines: Lines,
  policy: Policy,
  referenced_private: Set(String),
  doc_lines: Set(Int),
  attr_starts: Dict(Int, Int),
) -> Result(Raw, Nil) {
  let function = definition.definition
  let span = span_lines(function, lines)

  // Decide whether this function owes a `///` doc comment before checking
  // the lines above it.
  case
    owes_doc(function, doc, span, policy, referenced_private),
    has_doc_comment(definition, lines, doc_lines, attr_starts)
  {
    True, False -> Ok(missing_doc_finding(function, span))
    _, _ -> Error(Nil)
  }
}

/// Whether `function` is required to carry a `///` doc comment under `policy`.
fn owes_doc(
  function: glance.Function,
  doc: List(DocLine),
  span: Int,
  policy: Policy,
  referenced_private: Set(String),
) -> Bool {
  // Test entry points (`main` and `*_test` under test policy) do not carry
  // API doc comments.
  case is_exempt_entry(function, policy) {
    True -> False
    False ->
      case function.publicity {
        glance.Public -> doc != [] || span > policy.function_doc_lines
        glance.Private ->
          set.contains(referenced_private, function.name)
          && span > policy.function_doc_lines
      }
  }
}

/// Whether `function` is a CLI/test `main` entry point or a test function
/// linted under `policy.for_tests`.
fn is_exempt_entry(function: glance.Function, policy: Policy) -> Bool {
  function.name == "main"
  || { policy.allow_panic && string.ends_with(function.name, "_test") }
}

/// Whether `definition` is immediately preceded by at least one `///` doc
/// comment line, either directly above `fn`/`pub fn` or directly above its
/// leading `@` attributes.
fn has_doc_comment(
  definition: glance.Definition(glance.Function),
  lines: Lines,
  doc_lines: Set(Int),
  attr_starts: Dict(Int, Int),
) -> Bool {
  let function = definition.definition
  let fn_line = source.line_of(lines.starts, function.location.start)

  // Attributes sit between the `///` block and `pub fn`/`fn`, so check both
  // the line above the first attribute and the line above `fn`.
  let header_line = case dict.get(attr_starts, function.location.start) {
    Ok(attr_offset) -> source.line_of(lines.starts, attr_offset)
    Error(Nil) -> fn_line
  }

  set.contains(doc_lines, fn_line - 1)
  || set.contains(doc_lines, header_line - 1)
}

/// Lines from `pub fn` or `fn` to the closing brace, inclusive.
fn span_lines(function: glance.Function, lines: Lines) -> Int {
  let first = source.line_of(lines.starts, function.location.start)
  let last = source.line_of(lines.starts, function.location.end)
  last - first + 1
}

/// Constructs the R22 finding for a function missing its `///` doc comment.
fn missing_doc_finding(function: glance.Function, span: Int) -> Raw {
  // Tailor the advice to whether the function is part of the module's public
  // surface or a private helper.
  let detail = case function.publicity {
    glance.Public ->
      "public function `"
      <> function.name
      <> "` has no `///` doc comment; document its contract and add an "
      <> "`## Examples` section (CLAUDE.md, \"Literate code\")"
    glance.Private ->
      "private function `"
      <> function.name
      <> "` spans "
      <> int.to_string(span)
      <> " lines and has no `///` doc comment; document what the helper "
      <> "establishes so a reader does not have to reconstruct it from the "
      <> "body (CLAUDE.md, \"Literate code\")"
  }

  Raw(
    rule: finding.FunctionDoc,
    offset: function.location.start,
    function: function.name,
    detail:,
  )
}

/// Lexes the source once to collect:
/// 1. The set of 1-based line numbers holding a leading `///` (`CommentDoc`)
///    token.
/// 2. A map from a function's `pub`/`fn` byte offset to the byte offset of the
///    first `@` attribute attached to that function.
fn lex_doc_and_attributes(
  code: String,
  lines: Lines,
) -> #(Set(Int), Dict(Int, Int)) {
  let tokens =
    glexer.new(code)
    |> glexer.discard_whitespace
    |> glexer.lex
  let #(doc_offsets, attr_starts) = scan_tokens(tokens, 0, None, [], dict.new())
  let doc_line_numbers =
    doc_offsets
    |> list.reverse
    |> source.lines_of(lines.starts, _)
    |> list.filter(fn(line) {
      source.kind_of(lines, line) == source.CommentLine
    })
    |> set.from_list
  #(doc_line_numbers, attr_starts)
}

/// Walks the token stream tracking parenthesis/brace depth so top-level `@`
/// attributes are paired with the `pub fn` or `fn` they precede.
fn scan_tokens(
  tokens: List(#(token.Token, glexer.Position)),
  depth: Int,
  pending_attr: Option(Int),
  doc_offsets: List(Int),
  attr_starts: Dict(Int, Int),
) -> #(List(Int), Dict(Int, Int)) {
  // Dispatch on the leading token at bracket depth zero to pair attributes
  // with their function definitions while recording `CommentDoc` offsets.
  case tokens {
    [] -> #(doc_offsets, attr_starts)

    [#(token.CommentDoc(_), position), ..rest] ->
      scan_tokens(
        rest,
        depth,
        pending_attr,
        [position.byte_offset, ..doc_offsets],
        attr_starts,
      )

    [#(token.CommentNormal(_), _), ..rest]
    | [#(token.CommentModule(_), _), ..rest] ->
      scan_tokens(rest, depth, pending_attr, doc_offsets, attr_starts)

    [#(token.LeftParen, _), ..rest]
    | [#(token.LeftBrace, _), ..rest]
    | [#(token.LeftSquare, _), ..rest] ->
      scan_tokens(rest, depth + 1, pending_attr, doc_offsets, attr_starts)

    [#(token.RightParen, _), ..rest]
    | [#(token.RightBrace, _), ..rest]
    | [#(token.RightSquare, _), ..rest] ->
      scan_tokens(
        rest,
        int.max(0, depth - 1),
        pending_attr,
        doc_offsets,
        attr_starts,
      )

    [#(token.At, position), ..rest] if depth == 0 -> {
      // Preserve the first `@` offset when a function carries stacked
      // attributes.
      let first_attr = case pending_attr {
        Some(existing) -> Some(existing)
        None -> Some(position.byte_offset)
      }

      scan_tokens(rest, depth, first_attr, doc_offsets, attr_starts)
    }

    [#(token.Pub, position), #(token.Fn, _), ..rest] if depth == 0 -> {
      let next_starts =
        record_attr(attr_starts, position.byte_offset, pending_attr)
      scan_tokens(rest, depth, None, doc_offsets, next_starts)
    }

    [#(token.Fn, position), ..rest] if depth == 0 -> {
      let next_starts =
        record_attr(attr_starts, position.byte_offset, pending_attr)
      scan_tokens(rest, depth, None, doc_offsets, next_starts)
    }

    [#(token.Pub, _), ..rest]
      | [#(token.Type, _), ..rest]
      | [#(token.Opaque, _), ..rest]
      | [#(token.Const, _), ..rest]
      | [#(token.Import, _), ..rest]
      if depth == 0
    -> scan_tokens(rest, depth, None, doc_offsets, attr_starts)

    [_, ..rest] ->
      scan_tokens(rest, depth, pending_attr, doc_offsets, attr_starts)
  }
}

/// Associates `fn_offset` with `pending_attr` when an attribute preceded the
/// function.
fn record_attr(
  attr_starts: Dict(Int, Int),
  fn_offset: Int,
  pending_attr: Option(Int),
) -> Dict(Int, Int) {
  case pending_attr {
    Some(attr_offset) -> dict.insert(attr_starts, fn_offset, attr_offset)
    None -> attr_starts
  }
}
