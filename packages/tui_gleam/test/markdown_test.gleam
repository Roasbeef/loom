//// Markdown rendering tests pin semantic text and terminal-safety properties.

import etui/span
import gleam/list
import gleam/string
import gleeunit/should
import tui_gleam/markdown
import tui_gleam/text_hygiene

pub fn headings_lists_and_code_keep_semantic_text_test() {
  let rendered =
    markdown.render(
      "# Result\n\n- first\n- **second**\n\n```gleam\npub fn main() {}\n```",
    )
    |> visible_text

  rendered |> string.contains("Result") |> should.be_true
  rendered |> string.contains("• first") |> should.be_true
  rendered |> string.contains("• second") |> should.be_true
  rendered |> string.contains("gleam") |> should.be_true
  rendered |> string.contains("pub fn main() {}") |> should.be_true
}

pub fn gleam_code_distinguishes_tokens_without_changing_text_test() {
  let rendered =
    markdown.render(
      "```gleam\npub fn main() -> report.Outcome {\n  // exact bytes\n  report.text(\"live\")\n}\n```",
    )
    |> markdown.wrap_lines(80)
  let spans =
    list.flat_map(rendered, fn(line) {
      let span.Line(spans:, ..) = line
      spans
    })
  let assert Ok(span.Span(style: keyword_style, ..)) =
    list.find(spans, fn(value) { value.content == "pub" })
  let assert Ok(span.Span(style: string_style, ..)) =
    list.find(spans, fn(value) { value.content == "\"live\"" })
  let assert Ok(span.Span(style: comment_style, ..)) =
    list.find(spans, fn(value) { value.content == "// exact bytes" })

  assert keyword_style != string_style
  assert string_style != comment_style
  assert visible_text(rendered)
    |> string.contains("  // exact bytes\n│   report.text(\"live\")")
}

pub fn links_remain_clickable_test() {
  let links =
    markdown.render("read [the docs](https://example.com/docs)")
    |> list.flat_map(fn(line) {
      let span.Line(spans:, ..) = line
      spans
    })
    |> list.filter_map(fn(value) {
      let span.Span(link:, ..) = value
      case link {
        "" -> Error(Nil)
        uri -> Ok(uri)
      }
    })

  links |> should.equal(["https://example.com/docs"])
}

pub fn hard_break_becomes_a_terminal_row_test() {
  markdown.render("first  \nsecond")
  |> list.map(line_text)
  |> should.equal(["first", "second", ""])
}

pub fn leading_thematic_break_does_not_hide_chat_content_test() {
  let rendered =
    markdown.render("---\nvisible: true\n---\nbody")
    |> visible_text

  rendered |> string.contains("visible: true") |> should.be_true
  rendered |> string.contains("body") |> should.be_true
}

pub fn tables_stack_each_row_as_a_labelled_record_test() {
  let rendered =
    markdown.render(
      "| | Committed | Your version |\n|---|---|---|\n| Transport | fire-and-forget | cancellable handle |",
    )
    |> visible_text

  rendered
  |> should.equal(
    "▌ Transport\n  Committed: fire-and-forget\n  Your version: cancellable handle\n",
  )
}

pub fn model_controls_never_reach_terminal_spans_test() {
  [
    "\u{1b}[31mred",
    "left\u{202e}right",
    "zero\u{200b}width",
    "bell\u{7}noise",
  ]
  |> list.each(fn(hostile) {
    let rendered = markdown.render(hostile) |> visible_text
    rendered |> string.contains("\u{1b}") |> should.be_false
    rendered |> string.contains("\u{202e}") |> should.be_false
    rendered |> string.contains("\u{200b}") |> should.be_false
    rendered |> string.contains("\u{7}") |> should.be_false
  })
}

pub fn single_line_replaces_row_breaks_and_controls_test() {
  text_hygiene.single_line("one\r\ntwo\u{1b}")
  |> should.equal("one two�")
}

pub fn terminal_formatting_sequences_leave_no_visible_residue_test() {
  text_hygiene.multiline(
    "\u{1b}[38;2;226;224;216mstyled\u{1b}[0m\n\u{1b}[?25lready\u{1b}[?25h\u{1b}]0;title\u{7}",
  )
  |> should.equal("styled\nready")
}

pub fn c1_terminal_formatting_sequences_leave_no_visible_residue_test() {
  text_hygiene.multiline("\u{9b}31mred\u{9b}0m\u{9d}0;title\u{9c}ready")
  |> should.equal("redready")
}

pub fn incomplete_terminal_sequences_remain_visibly_inert_test() {
  text_hygiene.multiline("before\u{1b}[38;")
  |> should.equal("before�[38;")
}

pub fn malformed_csi_does_not_consume_following_text_test() {
  text_hygiene.multiline("before\u{1b}[31🙂hello")
  |> should.equal("before�[31🙂hello")
}

fn visible_text(lines: List(span.Line)) -> String {
  lines |> list.map(line_text) |> string.join("\n")
}

fn line_text(line: span.Line) -> String {
  let span.Line(spans:, ..) = line
  spans
  |> list.map(fn(value) {
    let span.Span(content:, ..) = value
    content
  })
  |> string.concat
}
