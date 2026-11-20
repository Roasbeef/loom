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
////
//// The review pane draws the same lines in a variant (`view_review`), which the
//// final design shows for a file's hunk: one line-number column, a column for the
//// marker of a find, and the function's name as the hunk's header. It is the same
//// drawer with the same colours: the tints and the red and the green are the
//// classes every diff takes, so a change to them reaches the review pane too. Only
//// the gutter's layout differs, and only through the class `diff-review`.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
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
  view_with(lines, cut, fn(_, _) { [] })
}

/// A diff's lines as one box, with whatever `after` returns drawn beneath each
/// line, given the line's position in `lines` and the line. The review pane
/// uses it to pin a find under the line it names. A file header line draws
/// nothing, and nothing is drawn under it.
///
/// ## Examples
///
/// ```gleam
/// // diff.view_with(lines, 0, fn(_, _) { [] })
/// ```
pub fn view_with(
  lines: List(Line),
  cut: Int,
  after: fn(Int, Line) -> List(Element(message)),
) -> Element(message) {
  let rows =
    lines
    |> list.index_map(fn(line, index) {
      case row(line) {
        Ok(drawn) -> [drawn, ..after(index, line)]
        Error(Nil) -> []
      }
    })
    |> list.flatten

  html.div([attribute.class("diff")], list.append(rows, note(cut)))
}

/// The review pane's variant of the drawer. Each line has one number, the line's
/// number in the new file, or in the old file for a removed line, then a cell for
/// the marker of a find, then the sign and the text. `marker` says, for the line
/// at a position, the glyph of the find that is pinned to it, which also rings the
/// line. A hunk's header is the name of the function it sits in, which the parser
/// keeps after the second `@@`, and is the range itself when there is none.
///
/// ## Examples
///
/// ```gleam
/// // diff.view_review(lines, 0, fn(_, _) { None }, fn(_, _) { [] })
/// ```
pub fn view_review(
  lines: List(Line),
  cut: Int,
  marker: fn(Int, Line) -> Option(String),
  after: fn(Int, Line) -> List(Element(message)),
) -> Element(message) {
  let rows =
    lines
    |> list.index_map(fn(line, index) {
      case review_row(line, marker(index, line)) {
        Ok(drawn) -> [drawn, ..after(index, line)]
        Error(Nil) -> []
      }
    })
    |> list.flatten

  html.div(
    [attribute.class("diff"), attribute.class("diff-review")],
    list.append(rows, note(cut)),
  )
}

/// One line of the review variant, or nothing for a file header.
fn review_row(
  line: Line,
  marker: Option(String),
) -> Result(Element(message), Nil) {
  case line.kind {
    diff_view.FileHeader -> Error(Nil)
    diff_view.Added | diff_view.Removed | diff_view.Context ->
      Ok(
        html.div(
          [
            attribute.class("diff-row"),
            kind_class(line.kind),
            case marker {
              Some(_) -> attribute.class("diff-marked")
              None -> attribute.none()
            },
          ],
          [
            html.span([attribute.class("diff-no")], [
              html.text(
                diff_view.number_text(case line.kind {
                  diff_view.Removed -> line.old
                  _ -> line.new
                }),
              ),
            ]),
            html.span([attribute.class("diff-pin")], [
              case marker {
                Some(glyph) ->
                  html.span([attribute.class("diff-pin-mark")], [
                    html.text(glyph),
                  ])
                None -> element.none()
              },
            ]),
            html.span([attribute.class("diff-text")], [
              html.text(sign(line.kind) <> line.text),
            ]),
          ],
        ),
      )
    diff_view.Hunk ->
      Ok(
        html.div([attribute.class("diff-row"), kind_class(line.kind)], [
          html.span([attribute.class("diff-text")], [
            html.text(function_name(line.text)),
          ]),
        ]),
      )
    diff_view.NoNewline ->
      Ok(
        html.div([attribute.class("diff-row"), kind_class(line.kind)], [
          html.span([attribute.class("diff-text")], [html.text(line.text)]),
        ]),
      )
  }
}

/// The name a hunk header carries after its range (`@@ -1,4 +1,6 @@ replay_from`),
/// or the header itself when it carries none.
///
/// ## Examples
///
/// ```gleam
/// assert diff.function_name("@@ -1,4 +1,6 @@ replay_from") == "replay_from"
/// assert diff.function_name("@@ -1,4 +1,6 @@") == "@@ -1,4 +1,6 @@"
/// ```
pub fn function_name(header: String) -> String {
  case string.split(header, "@@") {
    ["", _range, name] ->
      case string.trim(name) {
        "" -> header
        found -> found
      }
    _ -> header
  }
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

/// One line, or nothing for a file header. A hunk header and the no-newline
/// note are their text alone; the others carry the two numbers and the sign before it, in one
/// gutter cell. The gutter is the part of a row that stays at the box's left
/// edge while a long line scrolls (`position:sticky`), so it is one element
/// and not three that would each need an offset to stack against.
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

/// Sign helper.
fn sign(kind: Kind) -> String {
  case kind {
    diff_view.Added -> "+"
    diff_view.Removed -> "−"
    _ -> " "
  }
}

/// The class of a line's kind, a literal from a closed set.
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

/// The line that says lines were left out, or nothing.
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
