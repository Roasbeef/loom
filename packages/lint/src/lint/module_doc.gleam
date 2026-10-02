//// The module doc as lines with byte offsets, for the rules that read it.
////
//// `glance` drops every comment, so the `////` block a module opens with is
//// invisible to the AST. R13 (the flow spine) and R14 (transition tables)
//// are rules about what that block says, which means reading it from the
//// token stream. Lexing rather than splitting the text is what keeps a line
//// of a multi-line string that happens to begin `////` from being mistaken
//// for documentation: the lexer has already decided it is part of a string
//// token, and only genuine module-comment tokens come out here.
////
//// Everything is reported with the byte offset of the line's `////`, because
//// `lint` converts offsets to lines in one merged pass and a rule that
//// decided in lines would need the conversion run backwards.
////
//// The module is pure and knows nothing about either rule. It cuts the doc
//// into lines, a named section, and backtick spans; what a span must resolve
//// to is the caller's business.

import gleam/list
import gleam/string
import glexer
import glexer/token

/// One line of the module doc.
pub type DocLine {
  DocLine(
    /// The byte offset of the line's `////` in the source.
    offset: Int,
    /// What follows the `////`, minus one leading space and any trailing
    /// whitespace, so `//// ## Flow` reads `## Flow` and a bare `////` reads
    /// the empty string.
    text: String,
  )
}

/// A heading and the doc lines under it.
pub type Section {
  Section(
    /// The heading line itself, where a finding about the section as a
    /// whole is reported.
    heading: DocLine,
    /// The lines after the heading up to, not including, the next heading
    /// of level 1 or 2, or to the end of the module doc.
    body: List(DocLine),
  )
}

/// Every module-doc line of a source, in source order.
///
/// ## Examples
///
/// ```gleam
/// let doc = module_doc.lines("//// ## Flow\n////\n//// `a`\n\npub fn a() { 1 }\n")
/// assert list.map(doc, fn(line) { line.text }) == ["## Flow", "", "`a`"]
/// ```
///
/// ```gleam
/// // A string that spans lines is not documentation.
/// assert module_doc.lines("const s = \"\n//// no\n\"\n") == []
/// ```
///
pub fn lines(code: String) -> List(DocLine) {
  glexer.new(code)
  |> glexer.discard_whitespace
  |> glexer.lex
  |> doc_lines([])
}

fn doc_lines(
  tokens: List(#(token.Token, glexer.Position)),
  found: List(DocLine),
) -> List(DocLine) {
  case tokens {
    [] -> list.reverse(found)
    [#(token.CommentModule(text), position), ..rest] ->
      doc_lines(rest, [DocLine(position.byte_offset, tidy(text)), ..found])
    [_, ..rest] -> doc_lines(rest, found)
  }
}

/// Drop the one space the convention puts after `////` and any trailing
/// whitespace, so a comparison with `## Flow` does not depend on how the
/// author's editor treats line ends.
fn tidy(text: String) -> String {
  let text = case string.starts_with(text, " ") {
    True -> string.drop_start(text, 1)
    False -> text
  }
  string.trim_end(text)
}

/// The section whose heading line is exactly `heading` (`## Flow`), if the
/// doc has one.
///
/// The section runs to the next heading of level 1 or 2, so a `### Detail`
/// subheading stays inside it. A heading is recognised by its text alone,
/// without tracking code fences, because a fenced `## ` line in a module doc
/// is not something this tree writes and R13 forbids fences in the one
/// section where it would matter.
///
/// ## Examples
///
/// ```gleam
/// let doc = module_doc.lines("//// ## Flow\n//// `a`\n//// ## Other\n//// `b`\n")
/// let assert Ok(section) = module_doc.section(doc, "## Flow")
/// assert list.map(section.body, fn(line) { line.text }) == ["`a`"]
/// ```
///
pub fn section(doc: List(DocLine), heading: String) -> Result(Section, Nil) {
  case doc {
    [] -> Error(Nil)
    [line, ..rest] if line.text == heading ->
      Ok(Section(line, list.take_while(rest, fn(next) { !is_boundary(next) })))
    [_, ..rest] -> section(rest, heading)
  }
}

fn is_boundary(line: DocLine) -> Bool {
  case line.text {
    "#" | "##" -> True
    text -> string.starts_with(text, "# ") || string.starts_with(text, "## ")
  }
}

/// The contents of every complete single-backtick span on a line, in order.
///
/// A span is a pair of backticks on one line. Splitting on the backtick
/// leaves spans at the odd positions, and the last fragment is never one: it
/// follows the final backtick, so an unpaired trailing backtick leaves prose
/// where a span would have been and is dropped with it.
///
/// ## Examples
///
/// ```gleam
/// assert module_doc.code_spans("`a` then `b(1)` and a stray `c")
///   == ["a", "b(1)"]
/// ```
///
pub fn code_spans(text: String) -> List(String) {
  let pieces = string.split(text, "`")
  let last = list.length(pieces) - 1
  pieces
  |> list.index_map(fn(piece, index) { #(index, piece) })
  |> list.filter(fn(pair) { pair.0 % 2 == 1 && pair.0 < last })
  |> list.map(fn(pair) { pair.1 })
}
