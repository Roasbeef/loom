//// The titled blocks a code-mode program is drawn in.
////
//// A program that is running, one that completed and one that failed are
//// all blocks: a rule across the top carrying the title, the body inside a
//// box, and a rule across the bottom carrying the foot. A running block
//// shows the opening lines of the program, since the program text and,
//// later, its one result are all the client receives. A completed one keeps
//// those lines, so its title and program rows stay put when the result
//// arrives, and it grows below them with the calls the program made and a
//// preview of its value; a failed one shows the error, with the source lines a compiler names
//// drawn as source. The border is drawn in the live colour for a program
//// still running, the success colour for one that completed and the danger
//// colour for one that failed, so the three read apart before a word of
//// any is read.
////
//// A line's text is laid out by `session_view/transcript_lines`: the title,
//// a newline, the foot, a newline, and the body. A body row holding a
//// number and a `│` gutter is drawn as source; any other row as text.

import etui/span
import etui/style
import etui/text
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import session_view/transcript_line.{
  type Speaker, ProgramFailure, ProgramSettled,
}
import tui/theme

/// The rows a program block draws in a pane `width` cells wide: the top
/// rule, the body, and the bottom rule, set two cells in and ending one
/// cell short of the pane's right edge. The block opens and closes bare,
/// as a call's row does, and the fold around it places the blank rows.
///
/// ## Examples
///
/// ```gleam
/// let rows =
///   program_rows.rows(
///     transcript_line.ProgramRunning,
///     "◐ code_mode · awaiting its result\nCtrl+g program\nPROGRAM · 1 line, 1 shown",
///     80,
///   )
/// ```
pub fn rows(speaker: Speaker, text: String, width: Int) -> List(span.Line) {
  let #(title, foot, body) = case string.split(text, "\n") {
    [title, foot, ..body] -> #(title, foot, body)
    [title] -> #(title, "", [])
    [] -> #("", "", [])
  }
  let edge = case speaker {
    ProgramFailure -> theme.danger
    ProgramSettled -> theme.added
    _ -> theme.current
  }
  let box = int.max(8, width - 3)
  let inside = box - 4
  let border = style.new(edge, style.Default, style.none())
  let heading = style.new(edge, style.Default, style.bold())
  let middle =
    list.index_map(body, fn(row, index) {
      span.line_new([
        span.span_styled("│ ", border),
        ..list.append(content(row, inside, role(speaker, index)), [
          span.span_styled(" │", border),
        ])
      ])
    })
  [
    rule("╭", title, "╮", box, border, heading),
    ..list.append(middle, [
      rule("╰", foot, "╯", box, border, theme.quiet_text()),
    ])
  ]
  |> list.map(fn(line) {
    span.Line(..line, spans: [span.span_plain("  "), ..line.spans])
  })
}

// A rule across the block with `words` set in it after one dash, and the
// rest of the rule filled to `box` cells. Words too long for the rule are
// cut, so the rule is always one row.
fn rule(
  open: String,
  words: String,
  close: String,
  box: Int,
  border: style.Style,
  words_style: style.Style,
) -> span.Line {
  let room = box - 5
  let words = case text.cell_width(words) > room {
    True -> text.truncate(words, int.max(0, room), "…")
    False -> words
  }
  let fill = int.max(0, box - 5 - text.cell_width(words))
  span.line_new(case words {
    "" -> [
      span.span_styled(open <> string.repeat("─", box - 2) <> close, border),
    ]
    _ -> [
      span.span_styled(open <> "─ ", border),
      span.span_styled(words, words_style),
      span.span_styled(" " <> string.repeat("─", fill) <> close, border),
    ]
  })
}

// What a body row is, apart from source, which its text shows.
type Role {
  // The opening row of a failure: the error's own heading.
  ErrorHeading

  // Any other row.
  BodyText
}

fn role(speaker: Speaker, index: Int) -> Role {
  case speaker, index {
    ProgramFailure, 0 -> ErrorHeading
    _, _ -> BodyText
  }
}

// One body row, cut or padded to `inside` cells. A source row is drawn on
// a raised ground with its number quiet; the opening row of a failure is
// the error's heading, in the danger colour; every other row is text.
fn content(row: String, inside: Int, role: Role) -> List(span.Span) {
  let cut = case text.cell_width(row) > inside {
    True -> text.truncate(row, inside, "…")
    False -> row
  }
  let padded =
    cut <> string.repeat(" ", int.max(0, inside - text.cell_width(cut)))
  case source_row(row), role {
    True, _ -> {
      let #(number, code) =
        string.split_once(padded, "│")
        |> result.unwrap(#("", padded))
      [
        span.span_styled(
          number,
          style.new(theme.quiet, theme.raised, style.none()),
        ),
        span.span_styled(
          "│",
          style.new(theme.divider, theme.raised, style.none()),
        ),
        span.span_styled(
          code,
          style.new(theme.paper, theme.raised, style.none()),
        ),
      ]
    }
    False, ErrorHeading -> [span.span_styled(padded, theme.danger_text())]
    False, BodyText -> [span.span_styled(padded, call_style(row))]
  }
}

// A row of the calls section opens with its call's ending, `✓` for a call
// that settled and `×` for one that failed, and takes that colour; any
// other row is quiet text.
fn call_style(row: String) -> style.Style {
  case string.first(row) {
    Ok("✓") -> theme.success_text()
    Ok("×") -> theme.danger_text()
    Ok(_) | Error(Nil) -> theme.quiet_text()
  }
}

// A row quoting source: a line number, or nothing but spaces, before the
// gutter. A compiler's caret row under a quoted line has no number.
fn source_row(row: String) -> Bool {
  case string.split_once(row, "│") {
    Ok(#(before, _)) -> {
      let before = string.trim(before)
      before == "" || result.is_ok(int.parse(before))
    }
    Error(Nil) -> False
  }
}
