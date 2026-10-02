//// The operator's turn and the strand's answer, as whole frames.
////
//// An operator's turn is one shaded band opened by the prompt's mark, with
//// no title row: the band says who wrote it. A long line wraps under its own
//// first word rather than under the mark, and indentation the operator
//// typed stays where it was typed. An answer is the other way about: a
//// heading row naming the strand, `◆ main`, and the body under it with no
//// band at all. These tests paint whole frames at 120
//// and 80 columns, since the wrap is what changes between the two.

import etui/buffer
import etui/geometry.{Position}
import etui/span
import frame_scene
import gleam/list
import gleam/string
import session_view/transcript_line.{Assistant, Line}
import tui/frame
import tui/live_tail
import tui/render
import tui/theme

const prompt =
  "Review the herdr update with two adversarial reviewers and a docs check, then restructure the commits so each tells one part of the story."

fn lines_of(entries, width: Int, height: Int) {
  let shown =
    frame_scene.attach(frame_scene.model(), "fix readme badge", entries)
    |> frame_scene.screen(width, height)
  #(shown, frame.buffer_to_lines(shown))
}

fn row_of(lines: List(String), needle: String) -> Result(Int, Nil) {
  lines
  |> list.index_map(fn(line, y) { #(line, y) })
  |> list.find_map(fn(pair) {
    case string.contains(pair.0, needle) {
      True -> Ok(pair.1)
      False -> Error(Nil)
    }
  })
}

pub fn an_operator_turn_is_one_band_wrapped_under_itself_test() {
  [#(120, 40), #(80, 24)]
  |> list.each(fn(size) {
    let #(shown, lines) =
      lines_of([frame_scene.user(1, prompt)], size.0, size.1)
    let assert Ok(y) = row_of(lines, "› Review the herdr update")
      as "the turn opens with the prompt's mark and its own text"
    assert !list.any(lines, string.contains(_, "User"))

    // The second row continues the text two cells in, under the first
    // word, on the same band.
    let assert Ok(next) = list.drop(lines, y + 1) |> list.first
      as "a long turn wraps"
    assert string.starts_with(next, "   ")
    assert !string.starts_with(next, "    ")
    assert buffer.get_cell(shown, Position(1, y + 1)).style.bg
      == theme.user_background
    assert buffer.get_cell(shown, Position(size.0 - 2, y)).style.bg
      == theme.user_background
  })
}

pub fn an_operator_turn_keeps_its_line_breaks_and_indentation_test() {
  let #(_, lines) =
    lines_of(
      [frame_scene.user(1, "Apply this:\n    if ready {\n      go()\n    }")],
      120,
      40,
    )
  let assert Ok(y) = row_of(lines, "› Apply this:") as "the first line"
  let assert [first, second, third, ..] = list.drop(lines, y + 1)
    as "the typed lines follow"
  assert string.starts_with(first, "       if ready {")
  assert string.starts_with(second, "         go()")
  assert string.starts_with(third, "       }")
}

// An answer opens with a heading naming the strand that gave it, and its
// body sits under the heading at the gutter, with no band behind it.
pub fn an_answer_opens_under_its_strands_name_test() {
  [#(120, 40), #(80, 24)]
  |> list.each(fn(size) {
    let #(shown, lines) =
      lines_of(
        [
          frame_scene.user(1, "Check the subtract change."),
          frame_scene.assistant(2, "I will check it with a small program.", []),
        ],
        size.0,
        size.1,
      )
    let assert Ok(y) = row_of(lines, "◆ main") as "the answer's heading"
    let assert Ok(body) = list.drop(lines, y + 1) |> list.first
      as "the body follows"
    assert string.starts_with(body, "   I will check it with a small program.")
    assert buffer.get_cell(shown, Position(size.0 - 2, y + 1)).style.bg
      != theme.user_background
  })
}

// The heading is the answer's only mark, so the answer still streaming has
// it as well as the settled one: the live tail opens its first run with the
// same row `render_line` draws, on its first frame and on every later one.
pub fn the_live_and_settled_answer_both_carry_the_heading_test() {
  let text = "I will check it.\n\nThen I will run the tests."
  let settled = render.render_line(Line(Assistant, text), 80, "main")
  let assert [heading, ..] = settled as "a settled answer draws rows"
  assert row_text(heading) == "◆ main"
  let layout =
    live_tail.Layout(
      room: render.markdown_room(Assistant, 80),
      finish: fn(rows, run) {
        render.finish_markdown_rows(Assistant, rows, run, "main")
      },
    )
  let first = string.slice(text, 0, 8)
  let #(opening, pass) =
    live_tail.rows(
      live_tail.begin(live_tail.new()),
      Assistant,
      first,
      [first],
      layout,
    )
  let assert [live_heading, ..] = opening as "a live answer draws rows"
  assert row_text(live_heading) == "◆ main"
  let #(whole, _) =
    live_tail.rows(
      live_tail.begin(live_tail.finish(pass)),
      Assistant,
      text,
      [string.drop_start(text, 8), first],
      layout,
    )
  assert whole == settled
}

fn row_text(row: span.Line) -> String {
  row.spans |> list.map(fn(value) { value.content }) |> string.concat
}
