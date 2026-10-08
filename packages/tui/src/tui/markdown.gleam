//// Markdown-to-etui rendering for assistant output.
////
//// `session_view/markdown` owns parsing, and the web view draws the same
//// tree, so the two hosts agree on what an answer's Markdown means. This
//// module is a presentation adapter over that tree, emitting styled etui
//// spans without routing model text through HTML or an ANSI renderer.
////
//// The parser is linear in its input and bounds the tree's depth. That is
//// what the terminal needs from it: a live answer is parsed again on every
//// delta, and the parser this module used before, mork, took time
//// exponential in a run of unclosed `[`, so an answer holding one hung the
//// terminal.
////
//// Rendering takes the available width because one construct cannot be laid
//// out without it. A table is a grid whose column widths are decided against
//// the cells a reader will actually see, and a grid too wide for the terminal
//// has to be narrowed before it is drawn rather than clipped after. Every
//// other block ignores the width here and is reflowed by `wrap_lines`, which
//// is the stage that knows how many cells a prefix has already consumed.
////
//// ## Flow
////
//// `render` → `render_sanitized` → `render_block` → `inline_lines` → `wrap_lines`
////
//// 1. `render` strips control characters with `text_hygiene.multiline`, and
////    `render_sanitized` does the same job for text already known to be safe: it
////    parses with `tree.parse` and renders each block in order.
//// 2. `render_block` dispatches on the block: headings and paragraphs go through
////    `inline_lines`, code blocks through `code_spans`, quotes and alerts through
////    `render_quote` and `render_alert`, lists through `render_list`, tables
////    through `render_table`.
//// 3. `inline_lines` turns inline nodes into styled parts (`inline_parts`) and
////    `parts_to_lines` folds them into lines at each break.
//// 4. `render_table` is the only stage that needs the width: `table_lines`
////    measures columns (`measure_columns`, `fit_columns`) and draws a grid
////    (`grid_lines`) or, when the grid cannot fit, records (`record_lines`).
//// 5. Rendering leaves long rows whole; `wrap_lines` reflows them with
////    `wrap_line`, which classifies each row (`row_kind`) as code, fixed or
////    flowing, and `rewrap` resumes the previous row when a live answer grows.
////    `wrap_code_row` segments spans once with `cell_spans`; `code_rows` carries
////    their remaining graphemes across rows without rescanning the suffix.
//// 6. `diff` is the sibling entry for patches, with numbered rows from
////    `numbered_diff_row`.

import etui/span
import etui/style
import etui/text
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import session_view/code_tokens.{
  type CodePart, CodeAdded, CodeComment, CodeDiffMeta, CodeKeyword, CodeNumber,
  CodePart, CodePlain, CodePunctuation, CodeRemoved, CodeString, CodeType,
}
import session_view/markdown as tree
import session_view/text_hygiene
import tui/theme

// A span is segmented and measured once before hard wrapping. Continuations
// retain the unconsumed list tail, so a huge row never rebuilds or remeasures
// the entire suffix for each screen row.
type CellSpan {
  CellSpan(template: span.Span, graphemes: List(String), cells: Int)
}

type InlinePart {
  Styled(span.Span)
  Break
}

// How a finished row must be treated once the viewport width is known.
type RowKind {
  // Preformatted source under a gutter: hard-wrapped at the width with the
  // gutter repeated, because a word wrapper would collapse its indentation.
  CodeRow

  // Already laid out against the width, such as a table's grid or a
  // reasoning digest. Re-wrapping would destroy the alignment.
  FixedRow

  // Flowing prose, word-wrapped at the width.
  FlowingRow
}

// Whether a record row carries the marker that opens a source row's fields.
// The two cases differ only in their leading glyph, but a bare `Bool` at the
// call site would say nothing about which row it names.
type RecordField {
  FirstField
  LaterField
}

// The gutter drawn down the left of a code block.
//
// Code and block quotes were both `│ ` and differed only in hue, which left
// them indistinguishable in a styleless frame dump and for any reader who
// cannot separate the two colours. A solid half block reads as a rule rather
// than a quotation bar, and `row_kind` recognises a code row by this glyph
// instead of by comparing styles, which a theme change would have broken.
const code_gutter = "▎ "

// The gutter drawn down the left of a block quote.
const quote_gutter = "│ "

// The mark that opens a collapsed reasoning digest row.
//
// The digest is the one row whose height is a stated invariant: its live and
// its settled form have to occupy exactly one row so that a settle changes
// words and not the transcript's height. Its caller lays it out against the
// pane width itself, so `wrap_lines` has to recognise it and leave it alone.
// Row kinds are read off the glyphs the renderer emitted, which is why the
// glyph run naming that row is declared here beside the other gutters rather
// than in the caller that draws it.
pub const digest_mark = "∴ Reasoning · "

// The narrowest a grid column may become. Below three cells a wrapped word
// makes no progress against the punctuation around it, so a grid that cannot
// give every column this much is abandoned for the record form instead.
const min_column = 3

/// Parses model markdown and returns wrapped-ready styled terminal lines.
///
/// `width` is the number of cells the rows will occupy, and only the table
/// grid consults it: a grid wider than that is narrowed, and one that cannot
/// be narrowed far enough falls back to a labelled record per source row.
/// A width of zero or less is no room rather than no constraint — every way
/// a caller reaches it subtracts a prefix from a pane that was already
/// narrow — so a grid given nothing to spend takes the record form too.
///
/// ## Examples
///
/// ```gleam
/// let lines = markdown.render("**bounded** output", 80)
/// ```
pub fn render(markdown: String, width: Int) -> List(span.Line) {
  render_sanitized(text_hygiene.multiline(markdown), width)
}

/// `render` for text that has already been through
/// `text_hygiene.multiline`.
///
/// The live tail sanitizes a growing answer piece by piece and keeps what it
/// has already cleaned, so running the whole of it through the hygiene pass
/// again on every frame would put back the cost that saving it removed. The
/// pass is idempotent, so for text it has already cleaned this is `render`
/// exactly.
///
/// ## Examples
///
/// ```gleam
/// let safe = text_hygiene.multiline("**bounded** output")
/// assert markdown.render_sanitized(safe, 80) == markdown.render(safe, 80)
/// ```
@internal
pub fn render_sanitized(safe: String, width: Int) -> List(span.Line) {
  safe
  |> tree.parse
  |> list.flat_map(render_block(_, width))
}

/// `render` for a tool's detail rows, which draws the labels of the
/// harness's own fences as highlighting and never as a row.
///
/// The harness fences the JSON result and call list it shows under Ctrl+G
/// with `json` and `text`, the program with `gleam`, and an edit's patch
/// with `diff`, so the viewer can highlight the source; those four labels
/// are dropped. Detail rows also carry text a model or another agent wrote,
/// such as advice, a sub-agent's report or a message body, and a fence in
/// that text keeps whatever label its author gave it. A fence with no label
/// has no label row to drop, so a first line that reads `json` stays.
///
/// ## Examples
///
/// ```gleam
/// let rows = markdown.render_detail("```json\n1\n```", 80)
/// assert list.length(rows) == list.length(markdown.render("```\n1\n```", 80))
/// ```
@internal
pub fn render_detail(markdown: String, width: Int) -> List(span.Line) {
  text_hygiene.multiline(markdown)
  |> tree.parse
  |> list.flat_map(fn(block) {
    let rows = render_block(block, width)
    case block {
      tree.CodeBlock(language: Some(label), ..) ->
        case harness_label(label) {
          True -> list.drop(rows, 1)
          False -> rows
        }
      tree.CodeBlock(language: None, ..)
      | tree.Heading(..)
      | tree.Paragraph(..)
      | tree.Quote(..)
      | tree.Alert(..)
      | tree.BulletList(..)
      | tree.OrderedList(..)
      | tree.Table(..)
      | tree.Footnote(..)
      | tree.Rule -> rows
    }
  })
}

// The fence labels `session_view/transcript_lines` writes into detail rows.
fn harness_label(label: String) -> Bool {
  case string.lowercase(string.trim(label)) {
    "json" | "text" | "gleam" | "diff" -> True
    _ -> False
  }
}

/// Wraps flowing Markdown, hard-wrapping code and leaving fixed rows alone.
///
/// Etui's word wrapper discards leading separators and collapses runs of
/// spaces, which would destroy source indentation, so a code row is split on
/// cell boundaries instead and its gutter is repeated on every continuation.
/// A table's grid rows were already measured against this width by `render`
/// and are passed through untouched.
///
/// ## Examples
///
/// ```gleam
/// let wrapped = markdown.wrap_lines(markdown.render("one two", 4), 4)
/// ```
@internal
pub fn wrap_lines(lines: List(span.Line), width: Int) -> List(span.Line) {
  list.flat_map(lines, wrap_line(_, width))
}

/// The rows one line of `render`'s output occupies at `width`: the step
/// `wrap_lines` applies to each line, which never looks at a neighbour.
///
/// ## Examples
///
/// ```gleam
/// let rows = markdown.wrap_line(span.line_plain("one two"), 4)
/// ```
@internal
pub fn wrap_line(line: span.Line, width: Int) -> List(span.Line) {
  case width <= 0 {
    True -> []
    False ->
      case row_kind(line) {
        CodeRow -> wrap_code_row(line, width)
        FixedRow -> [line]
        FlowingRow -> wrap_indented(line, width)
      }
  }
}

/// `wrap_line(line, width)`, reusing the rows an earlier line was wrapped
/// into when `line` only extends it.
///
/// `previous` is a line and the rows `wrap_line` gave it at `width`. A live
/// answer grows at its end, and its last paragraph is one flowing line that
/// grows with it, so wrapping that line from its start on every frame costs
/// the paragraph's length per frame. The word wrapper is greedy: it closes a
/// row when the next word does not fit, and it looks at nothing after that
/// word. So a row followed by a complete word is final, and the wrap can
/// resume at the start of the row after it. The rows from there on are
/// rebuilt from that row's own spans followed by the text `line` added, which
/// is the same sequence of words and separators the full wrap reads. Anything
/// else, an edit before the end, a different style, a change of width or an
/// indented line, is wrapped from the start.
///
/// ## Examples
///
/// ```gleam
/// let before = span.line_plain("one two three")
/// let after = span.line_plain("one two three four")
/// let rows = markdown.rewrap(#(before, markdown.wrap_line(before, 8)), after, 8)
/// assert rows == markdown.wrap_line(after, 8)
/// ```
@internal
pub fn rewrap(
  previous: #(span.Line, List(span.Line)),
  line: span.Line,
  width: Int,
) -> List(span.Line) {
  let #(before, rows) = previous
  let resumed = case width > 0 && before.alignment == line.alignment {
    True -> {
      use Nil <- result.try(flowing_at_margin(before))
      use Nil <- result.try(flowing_at_margin(line))
      use growth <- result.try(extension(before.spans, line.spans))
      resume(rows, growth, width, line.alignment)
    }
    False -> Error(Nil)
  }
  result.lazy_unwrap(resumed, fn() { wrap_line(line, width) })
}

// Only a flowing line with no leading indentation goes straight to the word
// wrapper, so only that line's rows are the wrapper's rows and nothing else.
fn flowing_at_margin(line: span.Line) -> Result(Nil, Nil) {
  case row_kind(line), leading_cells(line) {
    FlowingRow, 0 -> Ok(Nil)
    FlowingRow, _ | CodeRow, _ | FixedRow, _ -> Error(Nil)
  }
}

// Whether the old line's last word was followed by a space in it. The
// wrapper drops a line's trailing spaces, so its rows cannot say this, and
// it decides whether the text that follows lengthens that word or starts a
// new one.
type WordEnd {
  // The old line ended inside its last word, which new text may lengthen.
  InsideWord

  // Spaces followed the last word, so it is complete.
  AfterWord
}

// How a line grew from the one its rows were wrapped for.
type Growth {
  Growth(
    // The old last span. It holds the last word's final piece, so the last
    // row's final span has its style.
    last: span.Span,
    // Everything the new line has after `last`'s content: the rest of the
    // span that continues it, starting with any spaces it dropped, then
    // every later span.
    added: List(span.Span),
    ended: WordEnd,
  )
}

// How `line` extends `before`: every span of `before` but its last is
// repeated unchanged, the last is repeated with the same style and link and
// with its content possibly lengthened, and more spans may follow.
//
// The old last span must hold a word, not only spaces. The rows keep a
// word's pieces but drop the separators after it, so the added text is
// joined to the last row's final span, and that span has the old last
// span's style only if the last word ends in it.
fn extension(
  before: List(span.Span),
  after: List(span.Span),
) -> Result(Growth, Nil) {
  case before, after {
    [last], [grown, ..more] -> {
      let old = last.content
      let size = string.byte_size(old)
      let kept = size - trailing_spaces(bit_array.from_string(old), size - 1, 0)
      let same_style =
        span.Span(..last, content: "") == span.Span(..grown, content: "")
      case same_style && kept > 0 && string.starts_with(grown.content, old) {
        True -> {
          use added <- result.try(bytes_after(grown.content, kept))
          let ended = case kept == size {
            True -> InsideWord
            False -> AfterWord
          }
          Ok(Growth(
            last:,
            added: [span.Span(..grown, content: added), ..more],
            ended:,
          ))
        }
        False -> Error(Nil)
      }
    }
    [first, ..rest], [same, ..more] if first == same ->
      case joins_a_cluster(first, rest) {
        True -> Error(Nil)
        False -> extension(rest, more)
      }
    _, _ -> Error(Nil)
  }
}

// Whether `first` and the span after it split one grapheme cluster between
// them, which a re-wrap cannot reproduce. A row does not keep the joins
// inside a word: the wrapper merges adjacent pieces of one style into one
// span, and draws a word too wide for any row in its first piece's style as
// one span. A resume that re-reads the row then sees the word as fewer
// pieces than the full wrap sees. The wrapper measures a word piece by piece
// and splits a span on spaces only between clusters, so where a cluster
// crosses the join — a letter and its combining mark, an emoji and its
// skin tone, a space and a mark, two halves of a flag — the two readings
// differ, and such a line is wrapped from the start.
fn joins_a_cluster(first: span.Span, rest: List(span.Span)) -> Bool {
  case rest {
    [next, ..] -> clusters_across(first.content, next.content)
    [] -> False
  }
}

// Whether the last character of `left` and the first of `right` fall in one
// grapheme cluster. Two ASCII characters never do, since the pass the text
// went through turned carriage returns into line feeds, so the common join
// is decided by two bytes. Otherwise the last codepoint of `left` and the
// first cluster of `right` are measured together. A regional indicator
// pairs with its neighbour according to how many precede it, which one
// codepoint of context cannot say, so a join to one always counts.
fn clusters_across(left: String, right: String) -> Bool {
  let left_bits = bit_array.from_string(left)
  let size = bit_array.byte_size(left_bits)
  case bit_array.slice(left_bits, size - 1, 1), bit_array.from_string(right) {
    Ok(<<last>>), <<first, _:bytes>> if last < 0x80 && first < 0x80 -> False
    Ok(_), <<0xF0, 0x9F, 0x87, fourth, _:bytes>>
      if fourth >= 0xA6 && fourth <= 0xBF
    -> True
    Ok(_), <<_, _:bytes>> ->
      case last_codepoint(left_bits, size - 1), string.pop_grapheme(right) {
        Ok(character), Ok(#(opening, _)) ->
          string.drop_start(character <> opening, 1) == ""
        Error(Nil), _ | _, Error(Nil) -> False
      }
    Ok(_), _ | Error(Nil), _ -> False
  }
}

// The last character of the text in `bits`, found by stepping back from
// `index` over continuation bytes to the byte that starts it.
fn last_codepoint(bits: BitArray, index: Int) -> Result(String, Nil) {
  case bit_array.slice(bits, index, 1) {
    Ok(<<byte>>) if byte >= 0x80 && byte < 0xC0 ->
      last_codepoint(bits, index - 1)
    Ok(_) ->
      bit_array.slice(bits, index, bit_array.byte_size(bits) - index)
      |> result.try(bit_array.to_string)
    Error(Nil) -> Error(Nil)
  }
}

// The wrap of the extended line: the final rows of `rows`, then the
// remainder rebuilt from the spans of the rows that are not final and the
// text that was added.
//
// The last row holds the end of the old line. If its first word is complete
// — the row holds more than one word, or the old line ended after its last
// word — every earlier row is final and the wrap resumes at its start. If it
// holds a single word the new text may lengthen, and a longer word can
// change where the row above it broke, so the wrap resumes one row earlier.
// That is only sound when the row above ends before the word: the word must
// stand whole on the last row rather than be the tail of a word too wide for
// any row, and the space before it must come from the old last span, which
// then supplies the separator's style.
fn resume(
  rows: List(span.Line),
  growth: Growth,
  width: Int,
  alignment: text.Alignment,
) -> Result(List(span.Line), Nil) {
  case list.reverse(rows) {
    [final_row, ..earlier] -> {
      let final_text = row_text(final_row)
      use Nil <- result.try(opens_on_word(final_text))
      case string.contains(final_text, " "), growth.ended, earlier {
        True, _, _ | False, AfterWord, _ -> {
          use source <- result.try(extended(final_row.spans, growth))
          Ok(rewrapped(earlier, source, width, alignment))
        }
        False, InsideWord, [above, ..settled] ->
          resume_above(above, settled, final_row, growth, width, alignment)
        False, InsideWord, [] -> Error(Nil)
      }
    }
    [] -> Error(Nil)
  }
}

// The single-word case of `resume`: the wrap restarts at the row above the
// last, joined to the last word by the space the old last span held before
// it.
fn resume_above(
  above: span.Line,
  settled: List(span.Line),
  final_row: span.Line,
  growth: Growth,
  width: Int,
  alignment: text.Alignment,
) -> Result(List(span.Line), Nil) {
  // The final row holds one word and no space, so the old last span ending
  // with a space and then exactly that row's text says both that the word
  // stands whole on the row and that the space before it is the span's.
  use Nil <- result.try(opens_on_word(row_text(above)))
  case string.ends_with(growth.last.content, " " <> row_text(final_row)) {
    True -> {
      use source <- result.try(extended(final_row.spans, growth))
      let separator = span.Span(..growth.last, content: " ")
      Ok(rewrapped(
        settled,
        list.append(above.spans, [separator, ..source]),
        width,
        alignment,
      ))
    }
    False -> Error(Nil)
  }
}

// A row the wrapper built starts with a word. An empty row or one opening
// with a space only arises when a single grapheme is wider than the whole
// row, where the wrapper's state at the row's start is not a fresh row's.
fn opens_on_word(text: String) -> Result(Nil, Nil) {
  case text == "" || string.starts_with(text, " ") {
    True -> Error(Nil)
    False -> Ok(Nil)
  }
}

// How many space bytes end `bits` at or before `index`. Only the space
// character separates words for the wrapper, so other whitespace is a word.
fn trailing_spaces(bits: BitArray, index: Int, count: Int) -> Int {
  case bit_array.slice(bits, index, 1) {
    Ok(<<32>>) -> trailing_spaces(bits, index - 1, count + 1)
    Ok(_) | Error(Nil) -> count
  }
}

// The text after the first `bytes` bytes of `text`, which end on a
// character boundary.
fn bytes_after(text: String, bytes: Int) -> Result(String, Nil) {
  bit_array.from_string(text)
  |> bit_array.slice(bytes, string.byte_size(text) - bytes)
  |> result.try(bit_array.to_string)
}

// The kept rows, newest first, followed by the wrap of what comes after them.
fn rewrapped(
  settled: List(span.Line),
  source: List(span.Span),
  width: Int,
  alignment: text.Alignment,
) -> List(span.Line) {
  list.reverse(settled)
  |> list.append(span.wrap_line(span.Line(spans: source, alignment:), width))
}

// A row's spans followed by the added text.
//
// After a complete word the added text begins with the separator the old
// line ended with, and is placed after the row as it is. Inside a word the
// first added span carries on the old last span's content, so it is joined
// to the row's last span rather than placed beside it: the wrapper measures
// a word piece by piece, and a grapheme cut across two pieces, a flag or a
// letter and its combining mark, would be measured as two. That join is
// only the old span continuing if the row's last span still has its style:
// the tail of a word too wide for any row is drawn in the style of the
// word's first piece, and the wrap of the grown word would repaint the added
// text in it too, which is not a resume.
fn extended(
  row: List(span.Span),
  growth: Growth,
) -> Result(List(span.Span), Nil) {
  case growth.ended, list.reverse(row), growth.added {
    AfterWord, _, _ -> Ok(list.append(row, growth.added))
    InsideWord, [tail, ..before], [first, ..more] ->
      case
        span.Span(..tail, content: "") == span.Span(..growth.last, content: "")
      {
        True ->
          Ok(
            list.reverse(before)
            |> list.append([
              span.Span(..tail, content: tail.content <> first.content),
              ..more
            ]),
          )
        False -> Error(Nil)
      }
    InsideWord, [], _ | InsideWord, _, [] -> Error(Nil)
  }
}

fn row_text(row: span.Line) -> String {
  row.spans |> list.map(fn(value) { value.content }) |> string.concat
}

// The leading whitespace of a line, counted in graphemes. The trim is a
// grapheme-wise scan that stops at the first non-space, and the part it
// removed is sliced by bytes, so the cost is the indentation's length rather
// than the line's. Counting the whole line and then the trimmed remainder
// gave the same number at the cost of reading every grapheme twice, which on
// a long paragraph was most of what wrapping it cost.
fn leading_cells(line: span.Line) -> Int {
  let text = row_text(line)
  let trimmed = string.trim_start(text)
  let bytes = string.byte_size(text) - string.byte_size(trimmed)
  case bytes {
    0 -> 0
    _ ->
      bit_array.from_string(text)
      |> bit_array.slice(0, bytes)
      |> result.try(bit_array.to_string)
      |> result.map(string.length)
      |> result.unwrap(0)
  }
}

// The word wrapper discards leading separators, so the source line's own
// leading indentation is re-applied to every row it returns, the first row
// included. Wrapping happens at the narrowed width, which is what keeps a
// nested note's hierarchy aligned instead of letting continuations fall back
// to the left margin.
fn wrap_indented(line: span.Line, width: Int) -> List(span.Line) {
  let leading = leading_cells(line)
  let indent = int.min(leading, int.max(0, width - 1))
  case indent, line.spans {
    0, _ | _, [] -> span.wrap_line(line, width)
    _, [first, ..] -> {
      let prefix = span.Span(..first, content: string.repeat(" ", indent))

      // A whitespace-only source line wraps to one empty row. The prefix
      // inherits the first span's style, so gutter cells on such a row would
      // paint that style's background as a short bar where the reader expects
      // a blank line. There is nothing to align, so it is left empty.
      span.wrap_line(line, width - indent)
      |> list.map(fn(row) {
        case list.all(row.spans, fn(value) { value.content == "" }) {
          True -> row
          False -> span.Line(..row, spans: [prefix, ..row.spans])
        }
      })
    }
  }
}

// A code row is everything after the innermost code gutter; the gutter and
// whatever nesting precedes it is the prefix every continuation row repeats.
// Splitting on the last gutter span rather than the first is what keeps a
// fenced block inside a quoted list under both of its outer bars.
fn wrap_code_row(line: span.Line, width: Int) -> List(span.Line) {
  let #(prefix, source) = split_at_code_gutter(line.spans)
  let budget = width - spans_width(prefix)
  case budget <= 0 {
    // At very narrow widths the gutter would hide every source cell. Drop
    // the whole prefix rather than clipping a line number into a false one.
    True -> code_rows(cell_spans(source), [], width, [])
    False -> code_rows(cell_spans(source), prefix, budget, [])
  }
}

fn code_rows(
  source: List(CellSpan),
  prefix: List(span.Span),
  budget: Int,
  complete: List(span.Line),
) -> List(span.Line) {
  let #(head, tail) = take_span_cells(source, budget, [])
  let row = span.line_new(list.append(prefix, head))
  case tail {
    [] -> list.reverse([row, ..complete])
    _ -> code_rows(tail, prefix, budget, [row, ..complete])
  }
}

fn split_at_code_gutter(
  spans: List(span.Span),
) -> #(List(span.Span), List(span.Span)) {
  do_split_at_gutter(list.reverse(spans), [])
}

fn do_split_at_gutter(
  reversed: List(span.Span),
  source: List(span.Span),
) -> #(List(span.Span), List(span.Span)) {
  case reversed {
    [] -> #([], source)
    [first, ..rest] ->
      case first.content == code_gutter {
        True -> #(list.reverse([first, ..rest]), source)
        False -> do_split_at_gutter(rest, [first, ..source])
      }
  }
}

// Row kinds are read off the glyphs the renderer itself emitted rather than
// off style equality. A style sentinel broke silently whenever the palette
// moved, and it could not tell a code gutter from a quotation bar because
// both were the same character in two colours.
fn row_kind(line: span.Line) -> RowKind {
  let span.Line(spans:, ..) = line
  let code = list.any(spans, fn(value) { value.content == code_gutter })
  let grid = list.any(spans, is_grid_span)
  let digest = list.any(spans, fn(value) { value.content == digest_mark })

  // The code gutter is tested first because a grid glyph is a single
  // character and a tokenised code row emits every punctuation character as
  // its own span, so a box-drawn diagram inside a fence produces a span that
  // is exactly the grid's vertical bar. Reading that row as a grid row would
  // cost it both its hard wrap and its continuation gutter. The converse
  // cannot happen: a grid row never carries the code gutter.
  case code, grid, digest {
    True, _, _ -> CodeRow
    _, True, _ | _, _, True -> FixedRow
    False, False, False -> FlowingRow
  }
}

fn is_grid_span(value: span.Span) -> Bool {
  case value.content {
    "│" | "┌" | "┬" | "┐" | "├" | "┼" | "┤" | "└" | "┴" | "┘" -> True
    _ -> False
  }
}

fn render_block(block: tree.Block, width: Int) -> List(span.Line) {
  case block {
    // Claude Code, and every other terminal renderer a reader is likely to
    // have seen, marks a heading with weight alone. The bar that used to sit
    // here said nothing the bold did not and cost two cells of every row.
    tree.Heading(level:, inlines:) ->
      inline_lines(inlines, heading_style(level))
      |> trailing_blank
    tree.Paragraph(inlines:) ->
      inline_lines(inlines, style.default_style())
      |> trailing_blank
    tree.CodeBlock(language:, text:) ->
      source_lines(text)
      |> list.map(fn(line) {
        span.line_new([
          span.span_styled(code_gutter, theme.signal_bold()),
          ..code_spans(language, line)
        ])
      })
      |> prepend_code_language(language)
      |> trailing_blank

    // A quote's bar costs two cells of every row it covers, and quotes nest,
    // so the inner width is floored at one: a block measured against a width
    // of zero or less would have no room at all to lay itself out. An alert
    // indents its body by the same two cells.
    tree.Quote(blocks:) -> render_quote(blocks, int.max(1, width - 2))
    tree.Alert(kind:, blocks:) ->
      render_alert(kind, blocks, int.max(1, width - 2))
    tree.BulletList(items:) -> render_list(items, None, width)
    tree.OrderedList(start:, items:) -> render_list(items, Some(start), width)
    tree.Table(header:, rows:) -> render_table(header, rows, width)
    tree.Footnote(label:, blocks:) -> render_footnote(label, blocks, width)
    tree.Rule -> [
      span.line_new([span.span_styled("────────────────", theme.quiet_text())]),
      span.line_plain(""),
    ]
  }
}

// A code block's rows. The parser keeps a block's text without the line
// feed that ended its last line, so every line of the text is a row, the
// last included, and an empty block has none.
fn source_lines(text: String) -> List(String) {
  case text {
    "" -> []
    _ -> string.split(text, "\n")
  }
}

fn render_quote(blocks: List(tree.Block), width: Int) -> List(span.Line) {
  blocks
  |> list.flat_map(render_block(_, width))
  |> prefix_lines([span.span_styled(quote_gutter, theme.current_bold())], [
    span.span_styled(quote_gutter, theme.current_bold()),
  ])
}

// An alert is a titled callout, not a quotation, so it drops the quote bar and
// carries its kind on a heading row instead. The body is indented under that
// title so the callout reads as one unit even where colour is unavailable.
fn render_alert(
  alert: tree.AlertKind,
  blocks: List(tree.Block),
  width: Int,
) -> List(span.Line) {
  let title =
    span.line_new([
      span.span_styled("▌ ", alert_style(alert)),
      span.span_styled(alert_title(alert), alert_style(alert)),
    ])
  let body =
    blocks
    |> list.flat_map(render_block(_, width))
    |> prefix_lines([span.span_plain("  ")], [span.span_plain("  ")])
  [title, ..body]
}

// The palette has no violet, so `Important` takes the strongest neutral the
// theme offers rather than borrowing a hue that already means something else.
fn alert_style(alert: tree.AlertKind) -> style.Style {
  case alert {
    tree.Note -> theme.current_bold()
    tree.Tip -> theme.success_text()
    tree.Important -> style.new(theme.paper, style.Default, style.bold())
    tree.Warning -> theme.signal_bold()
    tree.Caution -> theme.danger_text()
  }
}

fn alert_title(alert: tree.AlertKind) -> String {
  case alert {
    tree.Note -> "Note"
    tree.Tip -> "Tip"
    tree.Important -> "Important"
    tree.Warning -> "Warning"
    tree.Caution -> "Caution"
  }
}

// A footnote's definition is laid out as a list item whose marker is its
// label in brackets, in the quiet colour its references are drawn in, so a
// reader can match `[1]` in the text to `[1]` here.
fn render_footnote(
  label: String,
  blocks: List(tree.Block),
  width: Int,
) -> List(span.Line) {
  let marker = "[" <> label <> "] "
  let inner = int.max(1, width - string.length(marker))
  blocks
  |> list.flat_map(render_block(_, inner))
  |> trim_trailing_blank
  |> prefix_lines([span.span_styled(marker, theme.quiet_text())], [
    span.span_plain(string.repeat(" ", string.length(marker))),
  ])
  |> trailing_blank
}

fn heading_style(level: tree.Level) -> style.Style {
  case level {
    tree.H1 | tree.H2 -> theme.current_bold()
    tree.H3 | tree.H4 | tree.H5 | tree.H6 ->
      style.new(theme.paper, style.Default, style.bold())
  }
}

fn code_style() -> style.Style {
  style.new(theme.paper, style.Default, style.none())
}

// Code blocks keep the model's bytes and give each class of token a style.
// The classes come from the scanner `session_view/code_tokens` shares with
// the web view; only the look of each class is the terminal's.
fn code_spans(language: Option(String), line: String) -> List(span.Span) {
  code_tokens.line(language, line)
  |> list.map(code_span)
}

fn diff_span(line: String) -> span.Span {
  code_span(CodePart(line, code_tokens.diff_kind(line)))
}

/// Renders patch bytes directly, keeping indentation and addition/removal colors.
/// File contents cannot terminate a Markdown fence because no parser runs here.
///
/// ## Examples
///
/// ```gleam
/// let rows = markdown.diff("-old\n+new")
/// ```
pub fn diff(patch: String) -> List(span.Line) {
  let #(_, rows) =
    patch
    |> text_hygiene.multiline
    |> string.split("\n")
    |> list.map_fold(None, numbered_diff_row)
  let width =
    list.fold(rows, 0, fn(width, row) { int.max(width, string.length(row.0)) })

  // Numbers precede the code gutter so hard wraps retain the source line's
  // coordinate, including when the patch is nested in a transcript prefix.
  list.map(rows, fn(row) {
    let prefix = case width {
      0 -> []
      _ -> [
        span.span_styled(
          string.pad_start(row.0, width, " ") <> " ",
          theme.quiet_text(),
        ),
      ]
    }
    span.line_new(
      list.append(prefix, [
        span.span_styled(code_gutter, theme.signal_bold()),
        row.1,
      ]),
    )
  })
}

// Hunk counts bound coordinate assignment. Metadata, truncated patches and
// unfamiliar formats remain visible without inventing file line numbers.
type DiffHunk {
  DiffHunk(old: Int, new: Int, old_left: Int, new_left: Int)
}

fn numbered_diff_row(
  hunk: Option(DiffHunk),
  line: String,
) -> #(Option(DiffHunk), #(String, span.Span)) {
  case diff_hunk(line) {
    Some(next) -> #(Some(next), #("", diff_span(line)))
    None -> numbered_diff_body(hunk, line)
  }
}

fn numbered_diff_body(
  hunk: Option(DiffHunk),
  line: String,
) -> #(Option(DiffHunk), #(String, span.Span)) {
  case hunk, line {
    Some(h), "-" <> _ if h.old_left > 0 -> #(
      Some(DiffHunk(..h, old: h.old + 1, old_left: h.old_left - 1)),
      #(int.to_string(h.old), code_span(CodePart(line, CodeRemoved))),
    )
    Some(h), "+" <> _ if h.new_left > 0 -> #(
      Some(DiffHunk(..h, new: h.new + 1, new_left: h.new_left - 1)),
      #(int.to_string(h.new), code_span(CodePart(line, CodeAdded))),
    )
    Some(h), " " <> _ if h.old_left > 0 && h.new_left > 0 -> #(
      Some(DiffHunk(h.old + 1, h.new + 1, h.old_left - 1, h.new_left - 1)),
      #(int.to_string(h.new), code_span(CodePart(line, CodePlain))),
    )

    // This marker describes the preceding source row and consumes neither
    // file's coordinate, even between a removal and its replacement.
    _, "\\ No newline at end of file" -> #(hunk, #("", diff_span(line)))
    _, _ -> #(None, #("", diff_span(line)))
  }
}

fn diff_hunk(line: String) -> Option(DiffHunk) {
  case string.split(line, " ") {
    ["@@", "-" <> old, "+" <> new, "@@", ..] -> {
      use old <- option.then(diff_range(old))
      use new <- option.then(diff_range(new))
      Some(DiffHunk(old.0, new.0, old.1, new.1))
    }
    _ -> None
  }
}

fn diff_range(value: String) -> Option(#(Int, Int)) {
  let parts = case string.split(value, ",") {
    [start] -> Some(#(start, "1"))
    [start, count] -> Some(#(start, count))
    _ -> None
  }
  use parts <- option.then(parts)
  use start <- option.then(int.parse(parts.0) |> option.from_result)
  use count <- option.then(int.parse(parts.1) |> option.from_result)
  case start >= 0 && count >= 0 && { start > 0 || count == 0 } {
    True -> Some(#(start, count))
    False -> None
  }
}

fn code_span(part: CodePart) -> span.Span {
  let CodePart(text:, kind:) = part
  let rendered = case kind {
    CodePlain -> code_style()
    CodeKeyword -> theme.current_bold()
    CodeType -> style.new(theme.signal, style.Default, style.bold())
    CodeString | CodeNumber ->
      style.new(theme.signal, style.Default, style.none())
    CodeComment ->
      theme.quiet_text()
      |> style.add_modifier(style.italic())
    CodePunctuation -> theme.quiet_text()
    CodeAdded -> theme.diff_added()
    CodeRemoved -> theme.diff_removed()
    CodeDiffMeta -> theme.current_bold()
  }
  span.span_styled(text, rendered)
}

fn render_list(
  items: List(List(tree.Block)),
  ordered_start: Option(Int),
  width: Int,
) -> List(span.Line) {
  items
  |> list.index_map(fn(blocks, index) {
    let marker = case ordered_start {
      Some(start) -> int.to_string(start + index) <> ". "
      None -> "• "
    }

    // The marker is a prefix on every row of the item, so anything measured
    // inside it, a table above all, has that many fewer cells to work with.
    // Floored at one for the same reason a nested quote is.
    let inner = int.max(1, width - string.length(marker))

    blocks
    |> list.flat_map(render_block(_, inner))
    |> trim_trailing_blank
    |> prefix_lines([span.span_styled(marker, theme.signal_bold())], [
      span.span_plain(string.repeat(" ", string.length(marker))),
    ])
  })
  |> list.flatten
  |> trailing_blank
}

// A table is the one block whose shape is decided here rather than by the
// wrapper, because a grid's columns can only be measured once and have to be
// measured against the width the rows will be drawn in.
fn render_table(
  header: List(tree.Cell),
  rows: List(List(tree.Cell)),
  width: Int,
) -> List(span.Line) {
  case header {
    [] -> []
    _ -> table_lines(header, rows, width)
  }
}

fn table_lines(
  header: List(tree.Cell),
  rows: List(List(tree.Cell)),
  width: Int,
) -> List(span.Line) {
  let columns = list.length(header)
  let alignments = list.map(header, fn(cell) { cell.align })
  let headings =
    list.map(header, fn(cell) {
      inline_spans(cell.inlines, theme.current_bold()) |> trim_span_edges
    })
  let body =
    list.map(rows, fn(row) {
      row
      |> list.map(fn(cell) {
        inline_spans(cell.inlines, style.default_style())
        |> trim_span_edges
      })
      |> fit_row(columns)
    })

  // Every column costs a separator plus a space on each side of its content,
  // and the grid closes with one final separator.
  let frame = 3 * columns + 1
  let natural = measure_columns([headings, ..body], columns)
  let total = list.fold(natural, frame, int.add)

  // A width of zero or less reaches here from a prefix that consumed the
  // whole pane, so it is the narrowest case rather than an exemption from
  // measuring. Letting it through would draw the grid at its natural width
  // and, because grid rows are fixed rows, leave the wrapper no way to bring
  // it back inside the pane.
  case total <= width {
    True -> grid_lines(headings, body, alignments, natural)
    False ->
      narrowed_lines(
        headings,
        body,
        alignments,
        natural,
        width - frame,
        columns,
      )
  }
}

// Shrinking stops at the point where a column can no longer hold a word. Past
// that the grid is all border and no content, so the labelled record form,
// which needs no horizontal budget at all, carries the row instead.
fn narrowed_lines(
  headings: List(List(span.Span)),
  body: List(List(List(span.Span))),
  alignments: List(tree.Align),
  natural: List(Int),
  budget: Int,
  columns: Int,
) -> List(span.Line) {
  case budget < columns * min_column {
    True -> record_lines(headings, body)
    False ->
      grid_lines(headings, body, alignments, fit_columns(natural, budget))
  }
}

// The parser already cuts or pads every row to the header's width, so a
// ragged row should not reach here; padding and truncating keeps the grid
// rectangular regardless, because a short row would otherwise silently shift
// every later column left.
fn fit_row(
  cells: List(List(span.Span)),
  columns: Int,
) -> List(List(span.Span)) {
  let taken = list.take(cells, columns)
  list.append(taken, list.repeat([], columns - list.length(taken)))
}

// A column is at least one cell wide so that an empty header still draws a
// column the reader can see and the wrapper always has a budget to spend.
fn measure_columns(
  rows: List(List(List(span.Span))),
  columns: Int,
) -> List(Int) {
  list.fold(rows, list.repeat(1, columns), fn(widest, cells) {
    list.map2(widest, cells, fn(best, cell) { int.max(best, spans_width(cell)) })
  })
}

// Max-min fair allocation. Walking the columns narrowest first and handing
// each one the smaller of its natural width and an equal share of what is
// left means a narrow column is never padded at a wide column's expense, and
// the surplus a narrow column does not use flows on to the wider ones.
fn fit_columns(natural: List(Int), budget: Int) -> List(Int) {
  let ordered =
    natural
    |> list.index_map(fn(width, index) { #(index, width) })
    |> list.sort(fn(one, other) { int.compare(one.1, other.1) })
  let #(_, allocated) =
    list.map_fold(ordered, #(budget, list.length(natural)), fn(state, column) {
      let #(remaining, count) = state
      let taken = int.min(column.1, remaining / count)
      #(#(remaining - taken, count - 1), #(column.0, taken))
    })
  allocated
  |> list.sort(fn(one, other) { int.compare(one.0, other.0) })
  |> list.map(fn(column) { column.1 })
}

// Header cells are centred whatever the column's alignment says, which is how
// GitHub and Claude Code present them: the alignment marker describes the
// data, and a centred label sits over a right-aligned column without looking
// like a stray value.
fn grid_lines(
  headings: List(List(span.Span)),
  body: List(List(List(span.Span))),
  alignments: List(tree.Align),
  widths: List(Int),
) -> List(span.Line) {
  let columns =
    list.map2(widths, alignments, fn(width, alignment) { #(width, alignment) })
  let centred = list.map(widths, fn(width) { #(width, tree.Center) })
  list.flatten([
    [border_line(widths, "┌", "┬", "┐")],
    cell_lines(headings, centred),
    [border_line(widths, "├", "┼", "┤")],
    list.flat_map(body, cell_lines(_, columns)),
    [border_line(widths, "└", "┴", "┘")],
    [span.line_plain("")],
  ])
}

fn border_line(
  widths: List(Int),
  left: String,
  joint: String,
  right: String,
) -> span.Line {
  let bars =
    list.index_map(widths, fn(width, index) {
      let lead = case index {
        0 -> left
        _ -> joint
      }
      [grid_span(lead), span.span_styled(rule(width + 2), theme.quiet_text())]
    })
  span.line_new(list.append(list.flatten(bars), [grid_span(right)]))
}

fn rule(cells: Int) -> String {
  string.repeat("─", cells)
}

fn grid_span(glyph: String) -> span.Span {
  span.span_styled(glyph, theme.quiet_text())
}

// One source row becomes as many terminal rows as its tallest cell needs, so
// a narrowed column wraps inside its own box instead of pushing the grid wide.
fn cell_lines(
  cells: List(List(span.Span)),
  columns: List(#(Int, tree.Align)),
) -> List(span.Line) {
  let wrapped =
    list.map2(cells, columns, fn(cell, column) { wrap_cell(cell, column.0) })
  let height =
    list.fold(wrapped, 1, fn(tallest, rows) {
      int.max(tallest, list.length(rows))
    })
  wrapped
  |> list.map(fn(rows) {
    list.append(rows, list.repeat([], height - list.length(rows)))
  })
  |> transpose
  |> list.map(grid_line(_, columns))
}

// Cells are measured down their own column but drawn across the row, so the
// per-cell row lists are turned inside out once every cell has been padded to
// the tallest of them.
fn transpose(
  columns: List(List(List(span.Span))),
) -> List(List(List(span.Span))) {
  case list.all(columns, list.is_empty) {
    True -> []
    False -> {
      let heads =
        list.map(columns, fn(rows) { rows |> list.first |> result.unwrap([]) })
      [heads, ..transpose(list.map(columns, list.drop(_, 1)))]
    }
  }
}

fn wrap_cell(cell: List(span.Span), width: Int) -> List(List(span.Span)) {
  span.line_new(cell)
  |> span.wrap_line(width)
  |> list.map(fn(row) { clamp_spans(row.spans, width) })
}

fn grid_line(
  cells: List(List(span.Span)),
  columns: List(#(Int, tree.Align)),
) -> span.Line {
  let body =
    list.map2(cells, columns, fn(cell, column) {
      let #(width, alignment) = column
      list.flatten([
        [grid_span("│"), span.span_plain(" ")],
        align_cell(cell, width, alignment),
        [span.span_plain(" ")],
      ])
    })
  span.line_new(list.append(list.flatten(body), [grid_span("│")]))
}

fn align_cell(
  cell: List(span.Span),
  width: Int,
  alignment: tree.Align,
) -> List(span.Span) {
  let slack = int.max(0, width - spans_width(cell))
  let #(before, after) = case alignment {
    tree.Unaligned | tree.Left -> #(0, slack)
    tree.Right -> #(slack, 0)
    tree.Center -> #(slack / 2, slack - slack / 2)
  }
  list.flatten([pad_spans(before), cell, pad_spans(after)])
}

fn pad_spans(cells: Int) -> List(span.Span) {
  case cells {
    0 -> []
    _ -> [span.span_plain(string.repeat(" ", cells))]
  }
}

// Tables in chat are usually comparisons, and a terminal narrow enough to
// refuse even the minimum grid is too narrow to preserve source columns.
// Rendering each source row as one labelled record preserves the
// relationships without horizontal scrolling.
fn record_lines(
  headings: List(List(span.Span)),
  body: List(List(List(span.Span))),
) -> List(span.Line) {
  list.flat_map(body, fn(cells) {
    table_record(headings, cells, FirstField)
    |> list.append([span.line_plain("")])
  })
}

fn table_record(
  headings: List(List(span.Span)),
  cells: List(List(span.Span)),
  field: RecordField,
) -> List(span.Line) {
  case headings, cells {
    [], _ | _, [] -> []
    [heading, ..rest_headings], [cell, ..rest_cells] -> {
      let marker = case field {
        FirstField -> span.span_styled("▌ ", theme.signal_bold())
        LaterField -> span.span_plain("  ")
      }
      let label = case span_text(heading) {
        "" -> []
        _ -> list.append(heading, [span.span_styled(": ", theme.quiet_text())])
      }
      [
        span.line_new([marker, ..list.append(label, cell)]),
        ..table_record(rest_headings, rest_cells, LaterField)
      ]
    }
  }
}

fn span_text(spans: List(span.Span)) -> String {
  spans
  |> list.map(fn(value) {
    let span.Span(content:, ..) = value
    content
  })
  |> string.concat
  |> string.trim
}

fn spans_width(spans: List(span.Span)) -> Int {
  list.fold(spans, 0, fn(total, value) {
    total + text.cell_width(value.content)
  })
}

fn clamp_spans(spans: List(span.Span), width: Int) -> List(span.Span) {
  let #(head, _) = take_span_cells(cell_spans(spans), width, [])
  head
}

// Each original span pays for segmentation and width once. The template keeps
// its style, while completed rows materialize only the graphemes they consume.
fn cell_spans(spans: List(span.Span)) -> List(CellSpan) {
  list.map(spans, fn(value) {
    let graphemes = string.to_graphemes(value.content)
    let cells =
      list.fold(graphemes, 0, fn(total, grapheme) {
        total + text.grapheme_cell_width(grapheme)
      })
    CellSpan(span.Span(..value, content: ""), graphemes, cells)
  })
}

// Splitting on cell boundaries rather than on words preserves indentation.
// The returned cursor shares its unconsumed tail with the original list;
// neither segmentation nor whole-suffix concatenation occurs on continuation.
fn take_span_cells(
  spans: List(CellSpan),
  budget: Int,
  taken: List(span.Span),
) -> #(List(span.Span), List(CellSpan)) {
  case spans {
    [] -> #(list.reverse(taken), [])
    [first, ..rest] -> take_span_cell(first, rest, budget, taken)
  }
}

fn take_span_cell(
  first: CellSpan,
  rest: List(CellSpan),
  budget: Int,
  taken: List(span.Span),
) -> #(List(span.Span), List(CellSpan)) {
  case first.cells <= budget {
    True -> {
      let whole =
        span.Span(..first.template, content: string.concat(first.graphemes))
      take_span_cells(rest, budget - first.cells, [whole, ..taken])
    }
    False -> {
      let #(head, tail, remaining) = case budget <= 0 {
        True -> #("", first.graphemes, budget)
        False -> take_graphemes(first.graphemes, budget, [])
      }
      let consumed = budget - remaining
      let continuation =
        CellSpan(..first, graphemes: tail, cells: first.cells - consumed)
      #(list.reverse([span.Span(..first.template, content: head), ..taken]), [
        continuation,
        ..rest
      ])
    }
  }
}

// A positive budget always consumes at least one grapheme, including a wide
// glyph in a one-cell column. Returning the unused budget lets the cursor
// subtract the consumed width without walking the remaining input again.
fn take_graphemes(
  graphemes: List(String),
  budget: Int,
  taken: List(String),
) -> #(String, List(String), Int) {
  case graphemes {
    [] -> #(joined(taken), [], budget)
    [first, ..rest] -> {
      let cells = text.grapheme_cell_width(first)
      case cells <= budget || taken == [] {
        True -> take_graphemes(rest, budget - cells, [first, ..taken])
        False -> #(joined(taken), graphemes, budget)
      }
    }
  }
}

fn joined(reversed: List(String)) -> String {
  reversed |> list.reverse |> string.concat
}

// CommonMark keeps the padding around pipe-delimited cells. Removing only the
// outer edges retains meaningful spaces between differently styled inline
// spans while preventing the terminal labels from drifting apart.
fn trim_span_edges(spans: List(span.Span)) -> List(span.Span) {
  spans
  |> trim_span_start(string.trim_start)
  |> list.reverse
  |> trim_span_start(string.trim_end)
  |> list.reverse
}

fn trim_span_start(
  spans: List(span.Span),
  trim: fn(String) -> String,
) -> List(span.Span) {
  case spans {
    [] -> []
    [value, ..rest] -> {
      let span.Span(content:, ..) = value
      case trim(content) {
        "" -> trim_span_start(rest, trim)
        content -> [span.Span(..value, content:), ..rest]
      }
    }
  }
}

/// The line a paragraph draws when a soft line break joins text whose line
/// is `head` to text whose first line is `next`.
///
/// The parser turns a soft break into a space inside the text around it,
/// dropping the spaces that ended the line, so a run of plain text across a
/// line ending is one `Text` and draws as one span in the paragraph's plain
/// style. A span is plain when it has that style and no link. So when
/// neither side's parse can reach into the other, the paragraph's line is
/// `head`'s spans and `next`'s with the space between them, where the space
/// joins `head`'s last span if that span is plain and `next`'s first span if
/// that one is, and stands as a span of its own when neither is. `head` was
/// parsed as the end of a paragraph, which the parser trims, so its last
/// span has no trailing spaces to drop. The live tail uses this to add the
/// lines that just arrived to a long paragraph without parsing its start
/// again, and it is the only place that knows what a soft break draws as.
///
/// ## Examples
///
/// ```gleam
/// let joined =
///   markdown.join_soft_break(span.line_plain("one"), span.line_plain("two"))
/// // one span, "one two"
/// ```
@internal
pub fn join_soft_break(head: span.Line, next: span.Line) -> span.Line {
  let spans = case list.reverse(head.spans), next.spans {
    [last, ..before], [first, ..after] ->
      case is_plain(last), is_plain(first) {
        True, True ->
          list.reverse(before)
          |> list.append([
            span.Span(..last, content: last.content <> " " <> first.content),
            ..after
          ])
        True, False ->
          list.reverse(before)
          |> list.append([
            span.Span(..last, content: last.content <> " "),
            ..next.spans
          ])
        False, True ->
          list.append(head.spans, [
            span.Span(..first, content: " " <> first.content),
            ..after
          ])
        False, False -> spaced(head.spans, next.spans)
      }
    _, _ -> spaced(head.spans, next.spans)
  }
  span.Line(..head, spans:)
}

fn is_plain(value: span.Span) -> Bool {
  value.style == style.default_style() && value.link == ""
}

fn spaced(head: List(span.Span), next: List(span.Span)) -> List(span.Span) {
  list.append(head, [span.span_styled(" ", style.default_style()), ..next])
}

fn inline_lines(
  inlines: List(tree.Inline),
  base: style.Style,
) -> List(span.Line) {
  inlines
  |> list.flat_map(inline_parts(_, base))
  |> parts_to_lines([], [])
}

fn inline_spans(
  inlines: List(tree.Inline),
  base: style.Style,
) -> List(span.Span) {
  inlines
  |> list.flat_map(inline_parts(_, base))
  |> list.filter_map(fn(part) {
    case part {
      Styled(value) -> Ok(value)
      Break -> Error(Nil)
    }
  })
}

fn inline_parts(inline: tree.Inline, base: style.Style) -> List(InlinePart) {
  case inline {
    tree.Text(text:) -> [Styled(span.span_styled(text, base))]

    // An inline code span painted in the prose colour with no modifier was
    // prose as far as the reader was concerned. The cold hue separates a
    // symbol from the sentence around it without adding a background that
    // would break up a wrapped paragraph.
    tree.Code(text:) -> [Styled(span.span_styled(text, theme.inline_code()))]
    tree.Emphasis(children:) ->
      nested_parts(children, style.add_modifier(base, style.italic()))
    tree.Strong(children:) ->
      nested_parts(children, style.add_modifier(base, style.bold()))

    // Dim was a poor stand-in: it is also what quiet metadata uses, so struck
    // text and an aside were the same grey, and an unmatched `~~` run nearby
    // rendered in the base style and read as the emphasised one.
    tree.Strikethrough(children:) ->
      nested_parts(children, style.add_modifier(base, style.strikethrough()))

    // The destination becomes the span's OSC 8 hyperlink, so a terminal that
    // supports them opens it on a click and one that does not shows the
    // label alone.
    tree.Link(label:, destination:) ->
      nested_parts(label, link_style(base))
      |> list.map(fn(part) {
        case part {
          Styled(value) -> Styled(span.with_link(value, destination))
          Break -> Break
        }
      })

    tree.Image(alt:, destination:) -> image_parts(alt, destination, base)
    tree.Task(state:) -> [
      Styled(span.span_styled(task_box(state), theme.signal_bold())),
    ]
    tree.FootnoteRef(label:) -> [
      Styled(span.span_styled("[" <> label <> "]", theme.quiet_text())),
    ]
    tree.Break -> [Break]
  }
}

fn task_box(state: tree.TaskState) -> String {
  case state {
    tree.Open -> "☐ "
    tree.Done -> "☑ "
  }
}

fn nested_parts(
  inlines: List(tree.Inline),
  base: style.Style,
) -> List(InlinePart) {
  list.flat_map(inlines, inline_parts(_, base))
}

// A terminal draws no image, so one is its alternative text and its
// destination, framed in the quiet colour.
fn image_parts(
  alt: String,
  destination: String,
  base: style.Style,
) -> List(InlinePart) {
  let label = case alt {
    "" -> []
    _ -> [Styled(span.span_styled(alt, base))]
  }
  [
    Styled(span.span_styled("[image: ", theme.quiet_text())),
    ..list.append(label, [
      Styled(span.span_styled(" · " <> destination <> "]", theme.quiet_text())),
    ])
  ]
}

fn link_style(base: style.Style) -> style.Style {
  base
  |> style.with_fg(theme.current)
  |> style.add_modifier(style.underline())
}

fn parts_to_lines(
  parts: List(InlinePart),
  current: List(span.Span),
  complete: List(span.Line),
) -> List(span.Line) {
  case parts {
    [] ->
      [span.line_new(list.reverse(current)), ..complete]
      |> list.reverse
    [Styled(value), ..rest] ->
      parts_to_lines(rest, [value, ..current], complete)
    [Break, ..rest] ->
      parts_to_lines(rest, [], [
        span.line_new(list.reverse(current)),
        ..complete
      ])
  }
}

fn prefix_lines(
  lines: List(span.Line),
  first: List(span.Span),
  continuation: List(span.Span),
) -> List(span.Line) {
  lines
  |> list.index_map(fn(line, index) {
    let span.Line(spans:, alignment:) = line
    let prefix = case index == 0 {
      True -> first
      False -> continuation
    }
    span.Line(spans: list.append(prefix, spans), alignment:)
  })
}

fn prepend_code_language(
  lines: List(span.Line),
  language: Option(String),
) -> List(span.Line) {
  case language {
    // The label is part of the block, so it opens with the block's own
    // gutter. It used to open with a box corner, one glyph away from the one
    // the table grid draws and therefore a row the grid classifier could be
    // taught to misread; the gutter says the same thing and cannot be
    // confused with a grid.
    Some(value) -> [
      span.line_new([
        span.span_styled(code_gutter, theme.signal_bold()),
        span.span_styled(value, theme.quiet_text()),
      ]),
      ..lines
    ]
    None -> lines
  }
}

fn trailing_blank(lines: List(span.Line)) -> List(span.Line) {
  list.append(lines, [span.line_plain("")])
}

fn trim_trailing_blank(lines: List(span.Line)) -> List(span.Line) {
  case list.reverse(lines) {
    [span.Line(spans: [], ..), ..rest] -> list.reverse(rest)
    [span.Line(spans: [span.Span(content: "", ..)], ..), ..rest] ->
      list.reverse(rest)
    _ -> lines
  }
}
