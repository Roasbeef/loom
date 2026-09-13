//// Markdown rendering tests pin semantic text and terminal-safety properties.

import etui/span
import etui/style
import etui/text
import gleam/list
import gleam/string
import gleeunit/should
import snapshot_test
import tui/markdown
import tui/text_hygiene
import tui/theme

pub fn headings_lists_and_code_keep_semantic_text_test() {
  let rendered =
    markdown.render(
      "# Result\n\n- first\n- **second**\n\n```gleam\npub fn main() {}\n```",
      80,
    )
    |> visible_text

  rendered |> string.contains("Result") |> should.be_true
  rendered |> string.contains("• first") |> should.be_true
  rendered |> string.contains("• second") |> should.be_true
  rendered |> string.contains("gleam") |> should.be_true
  rendered |> string.contains("pub fn main() {}") |> should.be_true
}

// Claude Code marks a heading with weight alone, and the bar this renderer
// used to draw said nothing the bold did not while costing two cells.
pub fn headings_carry_weight_without_a_bar_test() {
  let rows =
    markdown.render("## Result\n\nbody", 80)
    |> list.map(line_text)
  assert list.contains(rows, "Result")
  assert !list.contains(rows, "▌ Result")
}

pub fn gleam_code_distinguishes_tokens_without_changing_text_test() {
  let rendered =
    markdown.render(
      "```gleam\npub fn main() -> report.Outcome {\n  // exact bytes\n  report.text(\"live\")\n}\n```",
      80,
    )
    |> markdown.wrap_lines(80)
  let spans =
    list.flat_map(rendered, fn(line) {
      let span.Line(spans:, ..) = line
      spans
    })
  let assert Ok(span.Span(style: keyword_style, ..)) =
    list.find(spans, fn(value) { value.content == "pub" })
    as "a keyword survives tokenising"
  let assert Ok(span.Span(style: string_style, ..)) =
    list.find(spans, fn(value) { value.content == "\"live\"" })
    as "a string literal survives tokenising"
  let assert Ok(span.Span(style: comment_style, ..)) =
    list.find(spans, fn(value) { value.content == "// exact bytes" })
    as "a comment survives tokenising"

  assert keyword_style != string_style
  assert string_style != comment_style
  assert visible_text(rendered)
    |> string.contains("  // exact bytes\n▎   report.text(\"live\")")
}

pub fn links_remain_clickable_test() {
  let links =
    markdown.render("read [the docs](https://example.com/docs)", 80)
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
  markdown.render("first  \nsecond", 80)
  |> list.map(line_text)
  |> should.equal(["first", "second", ""])
}

pub fn leading_thematic_break_does_not_hide_chat_content_test() {
  let rendered =
    markdown.render("---\nvisible: true\n---\nbody", 80)
    |> visible_text

  rendered |> string.contains("visible: true") |> should.be_true
  rendered |> string.contains("body") |> should.be_true
}

// ─────────────────────────────────────────────────────────────────
// Tables

pub fn tables_render_as_a_bordered_grid_test() {
  markdown.render("| a | b |\n|---|---|\n| 1 | 2 |", 40)
  |> list.map(line_text)
  |> should.equal([
    "┌───┬───┐", "│ a │ b │", "├───┼───┤", "│ 1 │ 2 │", "└───┴───┘", "",
  ])
}

// The delimiter row's markers describe the data, so the body honours them
// while the header stays centred over its column.
pub fn grid_cells_honour_each_column_alignment_test() {
  let rows =
    markdown.render(
      "| left | center | right |\n|:---|:---:|---:|\n| a | b | c |",
      40,
    )
    |> list.map(line_text)
  assert list.contains(rows, "│ left │ center │ right │")
  assert list.contains(rows, "│ a    │   b    │     c │")
}

// Column widths are measured in terminal cells, not graphemes. A grid sized
// with `string.length` gives a double-width column half the room it needs, so
// the header splits across two rows and stops matching the rule above it.
pub fn a_wide_glyph_is_measured_in_terminal_cells_test() {
  let rows =
    markdown.render("| 世界 | ok |\n|---|---|\n| ✅ | y |", 40)
    |> list.map(line_text)
    |> list.filter(fn(row) { row != "" })
  let assert [top, header, ..] = rows
    as "the grid opens with a border and a single header row"
  top |> should.equal("┌──────┬────┐")
  header |> should.equal("│ 世界 │ ok │")

  // How wide an emoji is remains etui's decision. What this pins is that the
  // renderer asks etui rather than counting graphemes, so every row lands on
  // the same closing column whichever answer comes back.
  list.map(rows, text.cell_width) |> list.unique |> should.equal([13])
}

pub fn an_escaped_pipe_stays_inside_its_cell_test() {
  let rows =
    markdown.render("| a \\| b | c |\n|---|---|\n| x | y |", 40)
    |> list.map(line_text)
  assert list.contains(rows, "│ a | b │ c │")
}

pub fn inline_markup_inside_a_cell_keeps_its_own_styles_test() {
  let cells =
    markdown.render("| **bold** `code` | y |\n|---|---|\n| x | z |", 40)
    |> list.flat_map(fn(line) { line.spans })
  let assert Ok(bold) =
    list.find(cells, fn(value) { string.starts_with(value.content, "bold") })
    as "the emphasised cell text survives"
  let assert Ok(code) = list.find(cells, fn(value) { value.content == "code" })
    as "the code span inside the cell survives"
  assert bold.style != code.style
  assert code.style == theme.inline_code()
}

// A grid too wide for the terminal narrows its widest columns and lets the
// cells wrap inside their own boxes, so one source row becomes several
// terminal rows without the grid losing its shape.
pub fn a_grid_wider_than_the_terminal_wraps_its_cells_test() {
  let rows =
    markdown.render(
      "| | Committed | Your version |\n|---|---|---|\n| Transport | fire-and-forget | cancellable handle |",
      30,
    )
    |> list.map(line_text)
    |> list.filter(fn(row) { row != "" })
  let widths = list.map(rows, text.cell_width) |> list.unique
  widths |> should.equal([30])
  assert list.length(rows) > 5
}

// The boundary between the two forms, from the grid's side. Three columns
// cost ten cells of border, so at width nineteen the budget is exactly nine,
// which is three columns of the three cells a column must have. One cell
// narrower is the record form; this width is the last grid.
pub fn a_grid_at_exactly_the_minimum_budget_still_draws_test() {
  let rows =
    markdown.render(
      "| | Committed | Your version |\n|---|---|---|\n| Transport | fire-and-forget | cancellable handle |",
      19,
    )
    |> list.map(line_text)
    |> list.filter(fn(row) { row != "" })
  let assert [top, ..] = rows as "the grid opens with a border"
  assert string.starts_with(top, "┌")
    as "at the minimum budget the grid is still drawn"
  list.map(rows, text.cell_width) |> list.unique |> should.equal([19])
}

// Below three cells a column cannot hold a word, so the grid is abandoned for
// the labelled record form, which needs no horizontal budget at all.
pub fn a_grid_that_cannot_be_narrowed_falls_back_to_records_test() {
  markdown.render(
    "| | Committed | Your version |\n|---|---|---|\n| Transport | fire-and-forget | cancellable handle |",
    15,
  )
  |> visible_text
  |> should.equal(
    "▌ Transport\n  Committed: fire-and-forget\n  Your version: cancellable handle\n",
  )
}

// ─────────────────────────────────────────────────────────────────
// Code and quotes

// The two used to be the same glyph in two colours, which left them
// indistinguishable in a styleless dump and for a colour-blind reader.
pub fn code_and_block_quotes_use_different_gutters_test() {
  let code = markdown.render("    indented source", 40) |> list.map(line_text)
  let quoted = markdown.render("> quoted prose", 40) |> list.map(line_text)
  assert list.contains(code, "▎ indented source")
  assert list.contains(quoted, "│ quoted prose")
}

// A code row is recognised by its gutter glyph, so it is hard-wrapped on cell
// boundaries instead of word-wrapped: an unclosed fence during streaming used
// to leave every following row unwrapped and the layout bounced when it
// closed.
pub fn a_long_code_row_wraps_and_keeps_its_gutter_test() {
  let rows =
    markdown.render("```\n    let value = compute(everything)\n```", 20)
    |> markdown.wrap_lines(20)
    |> list.map(line_text)
    |> list.filter(fn(row) { string.starts_with(row, "▎ ") })
  rows
  |> should.equal(["▎     let value = co", "▎ mpute(everything)"])
}

// ─────────────────────────────────────────────────────────────────
// Inline styles

pub fn inline_code_is_not_styled_like_prose_test() {
  let spans =
    markdown.render("call `render` now", 80)
    |> list.flat_map(fn(line) { line.spans })
  let assert Ok(prose) =
    list.find(spans, fn(value) { value.content == "call " })
    as "the surrounding prose survives"
  let assert Ok(code) =
    list.find(spans, fn(value) { value.content == "render" })
    as "the code span survives"
  assert code.style != prose.style
  assert code.style == theme.inline_code()
}

pub fn strikethrough_uses_the_strikethrough_modifier_test() {
  let spans =
    markdown.render("this is ~~gone~~ now", 80)
    |> list.flat_map(fn(line) { line.spans })
  let assert Ok(struck) =
    list.find(spans, fn(value) { value.content == "gone" })
    as "the struck text survives"
  struck.style
  |> should.equal(style.add_modifier(
    style.default_style(),
    style.strikethrough(),
  ))
}

// A matched run leaves no tildes behind once the cell's edges are trimmed,
// and an unmatched one is the source's own text rather than emphasis.
pub fn table_cells_resolve_strikethrough_without_stray_tildes_test() {
  let rows =
    markdown.render("| ~~gone~~ | ~~open |\n|---|---|\n| x | y |", 40)
    |> list.map(line_text)
  assert list.contains(rows, "│ gone │ ~~open │")
  let spans =
    markdown.render("| ~~gone~~ | ~~open |\n|---|---|\n| x | y |", 40)
    |> list.flat_map(fn(line) { line.spans })
  let assert Ok(struck) =
    list.find(spans, fn(value) { value.content == "gone" })
    as "the matched run resolves to text without its delimiters"
  let assert Ok(open) =
    list.find(spans, fn(value) { value.content == "~~open" })
    as "the unmatched delimiter is kept as ordinary source text"
  assert struck.style
    == style.add_modifier(theme.current_bold(), style.strikethrough())
  assert open.style == theme.current_bold()
}

// ─────────────────────────────────────────────────────────────────
// Alerts

pub fn gfm_alerts_render_as_titled_callouts_test() {
  [
    #("NOTE", "Note"),
    #("TIP", "Tip"),
    #("IMPORTANT", "Important"),
    #("WARNING", "Warning"),
    #("CAUTION", "Caution"),
  ]
  |> list.each(fn(pair) {
    let rows =
      markdown.render("> [!" <> pair.0 <> "]\n> mind this", 40)
      |> list.map(line_text)
    assert list.contains(rows, "▌ " <> pair.1)
    assert list.contains(rows, "  mind this")
  })
}

pub fn each_alert_kind_has_its_own_colour_test() {
  let styles =
    ["NOTE", "TIP", "IMPORTANT", "WARNING", "CAUTION"]
    |> list.filter_map(fn(kind) {
      markdown.render("> [!" <> kind <> "]\n> body", 40)
      |> list.flat_map(fn(line) { line.spans })
      |> list.find(fn(value) { value.content == "▌ " })
      |> fn(found) {
        case found {
          Ok(value) -> Ok(value.style)
          Error(Nil) -> Error(Nil)
        }
      }
    })
    |> list.unique
  list.length(styles) |> should.equal(5)
}

pub fn a_quote_that_is_not_an_alert_keeps_its_bar_test() {
  let rows =
    markdown.render("> [!NOTED]\n> still a quote", 40)
    |> list.map(line_text)
  assert list.contains(rows, "│ [!NOTED] still a quote")
}

// ─────────────────────────────────────────────────────────────────
// The whole surface

// A frame is read, not counted. This golden holds one document carrying every
// construct whose layout changed, so a regression in any of them shows up as
// a diff of the screen rather than as an assertion about one helper.
pub fn a_rendered_document_matches_its_golden_test() {
  let source =
    "# Report\n\n"
    <> "Inline `code_span`, **bold**, and ~~struck~~ text.\n\n"
    <> "| Rule | Name | Tier |\n"
    <> "|:---|:---:|---:|\n"
    <> "| R0 | unparseable source | error |\n"
    <> "| R10 | comment with no blank line above it | error |\n\n"
    <> "> [!WARNING]\n> Ship nothing on a red gate.\n\n"
    <> "```gleam\npub fn main() -> Nil\n```\n"
  snapshot_test.assert_snapshot(
    "markdown-rendered-document",
    markdown.render(source, 44)
      |> markdown.wrap_lines(44)
      |> visible_text,
  )
}

// ─────────────────────────────────────────────────────────────────
// Terminal safety

pub fn model_controls_never_reach_terminal_spans_test() {
  [
    "\u{1b}[31mred",
    "left\u{202e}right",
    "zero\u{200b}width",
    "bell\u{7}noise",
  ]
  |> list.each(fn(hostile) {
    let rendered = markdown.render(hostile, 80) |> visible_text
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

pub fn source_tabs_render_as_spaces_without_admitting_controls_test() {
  text_hygiene.multiline("\tif ready {\n\t\twork()\n}\u{7}")
  |> should.equal("    if ready {\n        work()\n}�")
}

pub fn equality_comparisons_do_not_highlight_intervening_prose_test() {
  let text = "If mode == Ready, wait until count == 0."
  let rendered = markdown.render(text, 80)
  rendered |> visible_text |> should.equal(text <> "\n")
  let plain = markdown.render("ordinary prose", 80)
  let assert [span.Line(spans: [sample], ..), ..] = plain
    as "plain prose supplies the expected text style"
  rendered
  |> list.flat_map(fn(line) { line.spans })
  |> list.each(fn(part) { part.style |> should.equal(sample.style) })
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

// Literal fences inside patches must never hide later rows or their colors.
pub fn direct_patch_keeps_tabs_fences_and_change_styles_test() {
  let rows = markdown.diff("-\told\n+\tnew\n ```\n unchanged")
  assert visible_text(rows) == "▎ -    old\n▎ +    new\n▎  ```\n▎  unchanged"
  let parts = list.flat_map(rows, fn(row) { row.spans })
  let assert Ok(removed) =
    list.find(parts, fn(part) { part.content == "-    old" })
    as "the removed source survives"
  let assert Ok(added) =
    list.find(parts, fn(part) { part.content == "+    new" })
    as "the added source survives"
  assert removed.style != added.style
}

pub fn nested_list_indentation_survives_word_wrapping_test() {
  let rows =
    markdown.render(
      "- **Done**\n  - built first module with a long explanation\n  - tested second module\n- **Next**\n  - publish",
      24,
    )
    |> markdown.wrap_lines(24)
    |> list.map(line_text)
  assert list.contains(rows, "• Done")
  assert list.contains(rows, "  • built first module")
  assert list.contains(rows, "  with a long")
  assert list.contains(rows, "  explanation")
  assert list.contains(rows, "  • publish")
}

// The indent is re-applied as a span copied from the row's first span, so on
// a row with no text those cells would paint that span's background as a
// short bar where the source had a blank line.
pub fn a_blank_indented_row_wraps_without_a_painted_gutter_test() {
  let rows =
    [span.line_plain("    "), span.line_plain("    indented prose")]
    |> markdown.wrap_lines(20)
    |> list.map(line_text)
  assert list.contains(rows, "")
  assert list.contains(rows, "    indented prose")
}

// A grid glyph is a single character and the Gleam tokeniser emits every
// punctuation character as its own span, so a box-drawn diagram inside a
// fence produces a span that is exactly the grid's vertical bar. Classifying
// that row as a grid row would cost it both its hard wrap and its
// continuation gutter, which is the clipping the row kinds exist to avoid.
pub fn a_box_glyph_inside_a_fence_stays_a_code_row_test() {
  let rows =
    markdown.render("```gleam\nroot │ left │ right │ leaf\n```", 20)
    |> markdown.wrap_lines(20)
    |> list.map(line_text)
    |> list.filter(fn(row) { string.starts_with(row, "▎ ") })
  assert list.length(rows) > 1
    as "a code row wider than the pane is hard-wrapped, not clipped"
  list.each(rows, fn(row) {
    assert text.cell_width(row) <= 20
  })
}

// Four cells with two quote bars around it leaves the table exactly nothing.
// Every way a caller reaches a width of zero or less subtracts a prefix from
// a pane that was already narrow, so it means no room rather than no
// constraint. A grid let through on the other reading would be drawn at its
// natural width and, being a fixed row, would stay there.
pub fn a_table_nested_in_quotes_narrows_instead_of_overrunning_test() {
  let rendered =
    markdown.render(
      "> > | Rule | Name |\n> > |---|---|\n> > | R0 | unparseable source |",
      4,
    )
  let records = list.map(rendered, line_text)
  assert list.all(records, fn(row) { !string.contains(row, "┌") })
    as "a grid with nothing to spend falls back to the record form"
  assert list.any(records, fn(row) { string.contains(row, "Rule: R0") })
    as "the record form still carries the source row"

  // The record rows are flowing rows, so the wrapper can bring them inside
  // the pane. A grid drawn here would be a fixed row and would stay wide.
  markdown.wrap_lines(rendered, 4)
  |> list.each(fn(row) {
    assert text.cell_width(line_text(row)) <= 4
  })
}
