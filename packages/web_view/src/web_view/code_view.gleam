//// Draws a code block's lines with the token classes the terminal also uses.
////
//// A program in the lane (a `code_mode` call is a fenced `gleam` block) and
//// a fenced block in an answer both arrive here through `markdown_view`. The
//// scanner is `session_view/code_tokens`, shared with the terminal, so the
//// two hosts agree on what a keyword or a string is; this module owns only
//// what the page does with each class: a `span` carrying a fixed class that
//// the stylesheet colours, `tok-kw` and the rest.
////
//// The rules are 051's. The text of every token is a text node, so a program
//// that contains `</span><script>` draws those characters and nothing
//// else. A class comes from a `case` over the closed `CodeKind`, never from
//// the model's text, and the fence's language tag is read only by the
//// scanner to choose between Gleam, a diff and plain text; it never reaches
//// an attribute.
////
//// ## Flow
////
//// - `block` splits a fence's body into lines and draws one span per line.
//// - `line_element` scans one line under a memo and draws it with `merged`.
//// - `merged` joins adjacent runs, so plain text is one bare text node.
//// - `kind_class` is the one place a class name is chosen.
////
//// ## Cost
////
//// A streamed block grows at its tail and each line is its own `span`, so
//// the page patches the line being written and inserts the new ones, and the
//// lines that did not change are skipped by position. Each line is also its
//// own memo, keyed by the language and the line's text, so a delta to the
//// block scans the line it changed and reuses the others. That holds while
//// the enclosing row is redrawn, which a delta to this block does. When a
//// delta lands elsewhere, the lane's row memo hits and Lustre drops the memos
//// nested inside it (`lane.rows` says why), so the next change to this block
//// scans every line once. Scanning a line is linear in its length.
////
//// Markup is kept small by merging runs before drawing. Punctuation is drawn
//// as plain text, adjacent tokens of a kind are one run, and plain runs are
//// bare text nodes, so only the coloured kinds (keyword, type, string,
//// number, comment, diff) carry a span.

import gleam/list
import gleam/option.{type Option}
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import session_view/code_tokens.{
  type CodeKind, type CodePart, CodeAdded, CodeComment, CodeDiffMeta,
  CodeKeyword, CodeNumber, CodePart, CodePlain, CodePunctuation, CodeRemoved,
  CodeString, CodeType,
}

/// A fence's body as a `code` element, one `span` per line, each line's
/// tokens inside it.
///
/// Every span but the last carries its own newline, so the text a reader
/// copies is the fence's text unchanged. A line the scanner has no class for
/// (an unlabeled fence, an unknown language) is one text node, with no
/// token markup around it.
///
/// ## Examples
///
/// ```gleam
/// // The first line's `let` is `<span class="tok-kw">let</span>`.
/// let code = code_view.block(Some("gleam"), "let x = 1\nx")
/// ```
pub fn block(language: Option(String), text: String) -> Element(message) {
  let lines = string.split(text, "\n")
  let last = list.length(lines) - 1
  html.code(
    [],
    list.index_map(lines, fn(line, index) {
      let ending = case index == last {
        True -> ""
        False -> "\n"
      }
      line_element(language, line, ending)
    }),
  )
}

// One line as a span, memoized on the language and the line's text so a
// delta to the block scans only the lines it changed. The newline is a plain
// run after the tokens, so it merges into a last plain run and never makes a
// text node of its own beside another.
fn line_element(
  language: Option(String),
  line: String,
  ending: String,
) -> Element(message) {
  use <- element.memo([
    element.ref(language),
    element.ref(line),
    element.ref(ending),
  ])
  let parts = case ending {
    "" -> code_tokens.line(language, line)
    _ ->
      list.append(code_tokens.line(language, line), [
        CodePart(ending, CodePlain),
      ])
  }
  html.span([], list.map(merged(parts), token))
}

/// A line's tokens with runs merged: punctuation reads as plain, and
/// adjacent tokens of one kind become one run, so a line of `#("a", b),` is
/// a few runs and not a dozen.
///
/// ## Examples
///
/// ```gleam
/// assert code_view.merged(code_tokens.gleam_line("(a)"))
///   == [CodePart("(a)", CodePlain)]
/// ```
pub fn merged(parts: List(CodePart)) -> List(CodePart) {
  parts
  |> list.map(fn(part) {
    case part.kind {
      CodePunctuation -> CodePart(part.text, CodePlain)
      _ -> part
    }
  })
  |> list.fold([], fn(runs, part) {
    case runs {
      [CodePart(text:, kind:), ..rest] if kind == part.kind -> [
        CodePart(text <> part.text, kind),
        ..rest
      ]
      _ -> [part, ..runs]
    }
  })
  |> list.reverse
}

// One run: plain text is a text node and any other kind a span with its
// class.
fn token(part: CodePart) -> Element(message) {
  case part.kind {
    CodePlain -> html.text(part.text)
    _ -> html.span(kind_class(part.kind), [html.text(part.text)])
  }
}

/// The class attribute a kind of token is drawn with, or none for plain text
/// and punctuation, which `merged` draws as plain text.
///
/// Each name is a literal chosen by a `case` over the closed type, so no
/// string from the session can reach a class. The stylesheet's `tok-` rules
/// (`web_client.css`) give them colour.
///
/// ## Examples
///
/// ```gleam
/// assert code_view.kind_class(code_tokens.CodeKeyword)
///   == [attribute.class("tok-kw")]
/// assert code_view.kind_class(code_tokens.CodePlain) == []
/// ```
pub fn kind_class(kind: CodeKind) -> List(attribute.Attribute(message)) {
  case kind {
    CodePlain -> []
    CodeKeyword -> [attribute.class("tok-kw")]
    CodeType -> [attribute.class("tok-type")]
    CodeString -> [attribute.class("tok-str")]
    CodeNumber -> [attribute.class("tok-num")]
    CodeComment -> [attribute.class("tok-com")]
    CodePunctuation -> []
    CodeAdded -> [attribute.class("tok-add")]
    CodeRemoved -> [attribute.class("tok-del")]
    CodeDiffMeta -> [attribute.class("tok-meta")]
  }
}
