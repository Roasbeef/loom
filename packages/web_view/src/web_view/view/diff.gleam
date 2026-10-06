//// A diff drawn in colour, the one drawer every diff on the page goes
//// through: the opened edit step in the transcript and the Changes tab.
////
//// `session_view/diff_view` reads the diff into lines and decides each one's
//// kind; a whole diff's file header lines (`diff --git`, `index`, `---`,
//// `+++`) are not drawn, since the file row above a diff already names the
//// file and the change and the object ids are noise to a reader. This module
//// draws a line as its own element, a gutter of the old and
//// new line numbers and the sign, and the text. An added line is tinted green
//// with a green `+`, a removed line red with a red `−`, a hunk header sits in
//// a quiet band, and a context line is plain. The box scrolls sideways, so a
//// long line is never wrapped mid-token.
////
//// A line's text is a file's own text: it is drawn only as a text node. Its
//// class is chosen from `diff_view.Kind`, a closed type, and every class here
//// is a complete literal, so no diff can name one. The numbers in the gutter
//// are integers the parser read and are written by `int.to_string`. A diff
//// holds no handler, so an observer's page draws it as an operator's does.
//// The parser bounds the lines; a cut is drawn as a line saying how many were
//// left out.

import gleam/int
import gleam/list
import gleam/option.{type Option}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import session_view/diff_view.{type Kind, type Line}

/// A diff's lines as one box, followed by a note when `cut` lines were left
/// out.
///
/// ## Examples
///
/// ```gleam
/// // diff.view(diff_view.of_lines(["@@ -1 +1 @@", "-a", "+b"]), 0)
/// ```
pub fn view(lines: List(Line), cut: Int) -> Element(message) {
  html.div(
    [attribute.class("diff")],
    list.append(list.filter_map(lines, row), note(cut)),
  )
}

/// A diff read from its text, drawn bounded (`diff_view.max_lines`).
///
/// ## Examples
///
/// ```gleam
/// // diff.of_text("@@ -1 +1 @@\n-a\n+b")
/// ```
pub fn of_text(text: String) -> Element(message) {
  let diff_view.Diff(lines:, cut:) = diff_view.parse(text)
  view(lines, cut)
}

// One line, or nothing for a file header. A hunk header and the no-newline
// note are their text alone; the others carry the two numbers and the sign before it, in one
// gutter cell. The gutter is the part of a row that stays at the box's left
// edge while a long line scrolls (`position:sticky`), so it is one element
// and not three that would each need an offset to stack against.
fn row(line: Line) -> Result(Element(message), Nil) {
  case line.kind {
    diff_view.FileHeader -> Error(Nil)
    diff_view.Added | diff_view.Removed | diff_view.Context ->
      Ok(
        html.div([attribute.class("diff-row"), kind_class(line.kind)], [
          html.span([attribute.class("diff-gutter")], [
            number(line.old),
            number(line.new),
            html.span([attribute.class("diff-sign")], [
              html.text(sign(line.kind)),
            ]),
          ]),
          html.span([attribute.class("diff-text")], [html.text(line.text)]),
        ]),
      )
    diff_view.Hunk | diff_view.NoNewline ->
      Ok(
        html.div([attribute.class("diff-row"), kind_class(line.kind)], [
          html.span([attribute.class("diff-text")], [html.text(line.text)]),
        ]),
      )
  }
}

fn number(value: Option(Int)) -> Element(message) {
  html.span([attribute.class("diff-num")], [
    html.text(diff_view.number_text(value)),
  ])
}

fn sign(kind: Kind) -> String {
  case kind {
    diff_view.Added -> "+"
    diff_view.Removed -> "−"
    _ -> " "
  }
}

// The class of a line's kind, a literal from a closed set.
fn kind_class(kind: Kind) -> attribute.Attribute(message) {
  case kind {
    diff_view.Hunk -> attribute.class("diff-hunk")
    diff_view.Added -> attribute.class("diff-added")
    diff_view.Removed -> attribute.class("diff-removed")
    diff_view.Context -> attribute.class("diff-context")
    diff_view.FileHeader -> attribute.class("diff-file")
    diff_view.NoNewline -> attribute.class("diff-note")
  }
}

// The line that says lines were left out, or nothing.
fn note(cut: Int) -> List(Element(message)) {
  case cut {
    0 -> []
    left -> [
      html.p([attribute.class("diff-cut")], [
        html.text(int.to_string(left) <> " more lines not shown"),
      ]),
    ]
  }
}
