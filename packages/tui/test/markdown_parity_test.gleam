//// The terminal's Markdown after its move from mork to the shared parser.
////
//// Two groups of tests live here. The first holds the inputs that hung the
//// terminal: mork's link parsing took time exponential in a run of unclosed
//// `[`, and the terminal parses a live answer again on every delta, so an
//// answer holding such a run stopped the terminal drawing. Each run is
//// 50,000 characters, rendered through both of the renderer's entry points
//// and streamed through the live tail as a growing answer; EUnit's
//// five-second limit is the bound they are held to. The second group pins
//// what mork drew for the constructs only it used to recognise, reference
//// links, footnotes, task boxes and bare links, so that the terminal lost
//// none of them in the move.

import etui/span
import etui/style
import gleam/int
import gleam/list
import gleam/string
import session_view/text_hygiene
import session_view/transcript_line.{Assistant, Line}
import tui/live_tail
import tui/markdown
import tui/render
import tui/theme

// ------------------------------------------------------------ hostile input

fn hostile_runs() -> List(String) {
  [
    string.repeat("[", 50_000),
    string.repeat("![", 25_000),
    string.repeat("[a](", 12_500),
  ]
}

fn line_text(line: span.Line) -> String {
  line.spans |> list.map(fn(value) { value.content }) |> string.concat
}

pub fn a_hostile_run_renders_as_its_text_test() {
  list.each(hostile_runs(), fn(source) {
    let rows = markdown.render(source, 80)
    assert list.map(rows, line_text) == [source, ""]
    let safe = text_hygiene.multiline(source)
    assert markdown.render_sanitized(safe, 80) == rows
  })
}

// A model streams such a run a piece at a time, and the live tail renders
// the text again for each piece. Fifty growing prefixes of each run go
// through both entry points.
pub fn a_hostile_run_rerenders_as_a_growing_prefix_test() {
  list.each(hostile_runs(), fn(source) {
    let step = string.length(source) / 50
    list.each(upto(1, 50), fn(count) {
      let text = string.slice(source, 0, step * count)
      assert list.map(markdown.render(text, 80), line_text) == [text, ""]
        as { "prefix " <> int.to_string(count) <> " renders as its text" }
      assert list.map(markdown.render_sanitized(text, 80), line_text)
        == [text, ""]
        as { "prefix " <> int.to_string(count) <> " renders as its text" }
    })
  })
}

// The same runs streamed through the live tail, which also wraps each
// frame's rows and keeps its cache from frame to frame as the projection
// does. Each run is broken into words here: etui's word wrapper breaks a
// word wider than the row in time quadratic in the word's length, a cost of
// the wrapper rather than of Markdown, and a single 50,000-character word
// would measure that instead. The last frame must still be what a full
// render draws.
pub fn a_hostile_answer_streams_through_the_live_tail_test() {
  [
    string.repeat("[a ", 17_000),
    string.repeat("![a ", 12_500),
    string.repeat("[a]( ", 10_000),
  ]
  |> list.each(fn(source) {
    let step = string.length(source) / 50
    stream(source, step, 1, [], live_tail.new())
  })
}

fn stream(
  source: String,
  step: Int,
  count: Int,
  fragments: List(String),
  cache: live_tail.Cache,
) -> Nil {
  let text = string.slice(source, 0, step * count)
  let fragments = [
    string.slice(source, step * { count - 1 }, step),
    ..fragments
  ]
  let layout =
    live_tail.Layout(
      room: render.markdown_room(Assistant, 80),
      finish: fn(rows, run) {
        render.finish_markdown_rows(Assistant, rows, run)
      },
    )
  let #(rows, pass) =
    live_tail.rows(live_tail.begin(cache), Assistant, text, fragments, layout)

  case count >= 50 {
    True -> {
      assert rows == render.render_line(Line(Assistant, text), 80)
        as "the last frame draws what a full render draws"
      Nil
    }
    False -> stream(source, step, count + 1, fragments, live_tail.finish(pass))
  }
}

fn upto(from: Int, to: Int) -> List(Int) {
  case from > to {
    True -> []
    False -> [from, ..upto(from + 1, to)]
  }
}

// ------------------------------------------------- what mork used to draw

fn rows(source: String) -> List(span.Line) {
  markdown.render(source, 80)
}

fn link_style() -> style.Style {
  style.default_style()
  |> style.with_fg(theme.current)
  |> style.add_modifier(style.underline())
}

pub fn reference_links_are_links_and_their_definitions_vanish_test() {
  let drawn =
    rows("[text][ref], [Ref][] and [ref]\n\n[ref]: https://x.test \"Title\"")
  assert drawn
    == [
      span.line_new([
        span.span_styled("text", link_style())
          |> span.with_link("https://x.test"),
        span.span_plain(", "),
        span.span_styled("Ref", link_style())
          |> span.with_link("https://x.test"),
        span.span_plain(" and "),
        span.span_styled("ref", link_style())
          |> span.with_link("https://x.test"),
      ]),
      span.line_plain(""),
    ]
}

// A reference is drawn as its label in the quiet colour, as mork drew it,
// and its definition, which mork dropped from the terminal, is drawn where
// the model wrote it.
pub fn footnotes_draw_their_label_and_their_definition_test() {
  let drawn = rows("Claim[^1].\n\n[^1]: The source.")
  assert drawn
    == [
      span.line_new([
        span.span_plain("Claim"),
        span.span_styled("[1]", theme.quiet_text()),
        span.span_plain("."),
      ]),
      span.line_plain(""),
      span.line_new([
        span.span_styled("[1] ", theme.quiet_text()),
        span.span_plain("The source."),
      ]),
      span.line_plain(""),
    ]
}

pub fn task_boxes_keep_their_glyph_and_colour_test() {
  let drawn = rows("- [ ] open\n- [x] done")
  assert drawn
    == [
      span.line_new([
        span.span_styled("• ", theme.signal_bold()),
        span.span_styled("☐ ", theme.signal_bold()),
        span.span_plain("open"),
      ]),
      span.line_new([
        span.span_styled("• ", theme.signal_bold()),
        span.span_styled("☑ ", theme.signal_bold()),
        span.span_plain("done"),
      ]),
      span.line_plain(""),
    ]
}

pub fn bare_links_and_addresses_are_hyperlinks_test() {
  let drawn = rows("See www.x.test, https://x.test/a. or <me@x.test>")
  assert drawn
    == [
      span.line_new([
        span.span_plain("See "),
        span.span_styled("www.x.test", link_style())
          |> span.with_link("http://www.x.test"),
        span.span_plain(", "),
        span.span_styled("https://x.test/a", link_style())
          |> span.with_link("https://x.test/a"),
        span.span_plain(". or "),
        span.span_styled("me@x.test", link_style())
          |> span.with_link("mailto:me@x.test"),
      ]),
      span.line_plain(""),
    ]
}

// The live tail adds a paragraph's new lines to the line it already has
// with `join_soft_break`, so the join must give exactly the line the whole
// paragraph renders to, whichever side of the break is plain text.
pub fn a_soft_break_join_matches_the_whole_paragraph_test() {
  [
    #("one two", "three four"),
    #("see www.x.test", "then more"),
    #("plain words", "www.x.test ends it"),
    #("see https://a.test", "https://b.test"),
  ]
  |> list.each(fn(pair) {
    let #(head, next) = pair
    let assert [head_line, _] = markdown.render(head, 80)
      as "the head is one paragraph"
    let assert [next_line, _] = markdown.render(next, 80)
      as "the rest is one paragraph"
    let assert [whole, _] = markdown.render(head <> "\n" <> next, 80)
      as "the whole is one paragraph"
    assert markdown.join_soft_break(head_line, next_line) == whole
  })
}
