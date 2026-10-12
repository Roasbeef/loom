//// Inline markup for prose strings.
////
//// Paragraph text across the site is written as plain strings with three
//// marks: `code` in backticks, **bold** in double asterisks, and
//// [links](target). This keeps the copy readable in the source and lets the
//// same text appear in the figures, the landing page and the documentation
//// files without a second format.

import gleam/list
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html

/// Renders inline marks to elements.
///
/// ## Examples
///
/// ```gleam
/// render("Run `loom` in a [project](https://example.com).")
/// ```
pub fn render(text: String) -> List(Element(msg)) {
  scan(string.to_graphemes(text), "", [])
}

/// Renders inline marks inside a paragraph.
pub fn paragraph(text: String) -> Element(msg) {
  html.p([], render(text))
}

fn scan(
  chars: List(String),
  plain: String,
  done: List(Element(msg)),
) -> List(Element(msg)) {
  case chars {
    [] -> list.reverse(flush(plain, done))

    ["`", ..rest] ->
      case take_until(rest, ["`"]) {
        Ok(#(inner, after)) ->
          scan(after, "", [
            html.code([], [element.text(string.concat(inner))]),
            ..flush(plain, done)
          ])
        Error(Nil) -> scan(rest, plain <> "`", done)
      }

    ["*", "*", ..rest] ->
      case take_until(rest, ["*", "*"]) {
        Ok(#(inner, after)) ->
          scan(after, "", [
            html.strong([], scan(inner, "", [])),
            ..flush(plain, done)
          ])
        Error(Nil) -> scan(rest, plain <> "**", done)
      }

    ["[", ..rest] ->
      case take_until(rest, ["]", "("]) {
        Ok(#(label, after)) ->
          case take_until(after, [")"]) {
            Ok(#(target, after_link)) ->
              scan(after_link, "", [
                link(string.concat(target), scan(label, "", [])),
                ..flush(plain, done)
              ])
            Error(Nil) -> scan(rest, plain <> "[", done)
          }
        Error(Nil) -> scan(rest, plain <> "[", done)
      }

    [char, ..rest] -> scan(rest, plain <> char, done)
  }
}

fn flush(plain: String, done: List(Element(msg))) -> List(Element(msg)) {
  case plain {
    "" -> done
    _ -> [element.text(plain), ..done]
  }
}

/// A link. Targets that start with `http` open in a new tab.
fn link(target: String, children: List(Element(msg))) -> Element(msg) {
  case string.starts_with(target, "http") {
    True ->
      html.a(
        [
          attribute.href(target),
          attribute.target("_blank"),
          attribute.rel("noopener"),
        ],
        children,
      )
    False -> html.a([attribute.href(target)], children)
  }
}

/// Splits the list at the first occurrence of `stop`, returning what came
/// before it and what follows it. Fails when `stop` never occurs.
fn take_until(
  chars: List(String),
  stop: List(String),
) -> Result(#(List(String), List(String)), Nil) {
  take_until_loop(chars, stop, [])
}

fn take_until_loop(
  chars: List(String),
  stop: List(String),
  before: List(String),
) -> Result(#(List(String), List(String)), Nil) {
  case starts_with(chars, stop) {
    True -> Ok(#(list.reverse(before), list.drop(chars, list.length(stop))))
    False ->
      case chars {
        [] -> Error(Nil)
        [char, ..rest] -> take_until_loop(rest, stop, [char, ..before])
      }
  }
}

fn starts_with(chars: List(String), prefix: List(String)) -> Bool {
  case chars, prefix {
    _, [] -> True
    [c, ..cs], [p, ..ps] if c == p -> starts_with(cs, ps)
    _, _ -> False
  }
}
