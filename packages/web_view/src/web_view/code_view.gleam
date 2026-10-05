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
//// - `block` splits a fence's body into lines and draws one `span` per line.
//// - `line_children` draws one line's tokens, with the newline that ends it.
//// - `kind_class` is the one place a class name is chosen.
////
//// ## Cost
////
//// A streamed block grows at its tail and each line is its own `span`, so
//// the page patches the line being written and inserts the new ones, and
//// the lines that did not change are skipped by position. Scanning a line is
//// linear in its length. The enclosing row is memoized by the lane
//// (`lane.rows`), so a finished block is scanned when its row first draws
//// and again only if the row's text changes, never on a delta to another row.

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
      html.span([], line_children(code_tokens.line(language, line), ending))
    }),
  )
}

// One line's children. A line that is a single plain run is a text node, so
// a block with nothing to colour costs no more markup than it did before the
// scanner. Otherwise each token is a span and the newline follows the last
// one as a text node of its own, which sits beside a span and so never
// merges with a neighbouring text node.
fn line_children(
  parts: List(CodePart),
  ending: String,
) -> List(Element(message)) {
  case parts {
    [CodePart(text:, kind: CodePlain)] -> [html.text(text <> ending)]
    [] ->
      case ending {
        "" -> []
        _ -> [html.text(ending)]
      }
    _ ->
      case ending {
        "" -> list.map(parts, token)
        _ -> list.append(list.map(parts, token), [html.text(ending)])
      }
  }
}

// One token: a span with its class, and its text as a text node.
fn token(part: CodePart) -> Element(message) {
  html.span(kind_class(part.kind), [html.text(part.text)])
}

/// The class attribute a kind of token is drawn with, or none for plain text.
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
    CodePunctuation -> [attribute.class("tok-punct")]
    CodeAdded -> [attribute.class("tok-add")]
    CodeRemoved -> [attribute.class("tok-del")]
    CodeDiffMeta -> [attribute.class("tok-meta")]
  }
}
