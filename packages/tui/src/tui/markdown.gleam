//// CommonMark-to-etui rendering for assistant output.
////
//// Mork owns parsing. This module is a deliberately small presentation
//// adapter over its public document tree, emitting styled etui spans without
//// routing model text through HTML or an ANSI renderer.
////
//// Rendering takes the available width because one construct cannot be laid
//// out without it. A table is a grid whose column widths are decided against
//// the cells a reader will actually see, and a grid too wide for the terminal
//// has to be narrowed before it is drawn rather than clipped after. Every
//// other block ignores the width here and is reflowed by `wrap_lines`, which
//// is the stage that knows how many cells a prefix has already consumed.

import etui/span
import etui/style
import etui/text
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some, unwrap}
import gleam/result
import gleam/string
import mork
import mork/document.{
  type Alignment, type Block, type Cell, type Destination, type Document,
  type Inline, type LinkData, type ListItem, type THead, Absolute, Anchor,
  Autolink, BlockQuote, BulletList, Cell, Center, Checkbox, Code, CodeSpan,
  Delim, Document, EmailAutolink, Emphasis, Empty, Footnote, FullImage, FullLink,
  HardBreak, Heading, Highlight, HtmlBlock, InlineFootnote, InlineHtml, Left,
  LinkData, ListItem, Newline, OrderedList, Paragraph, RawHtml, RefImage,
  RefLink, Relative, Right, SoftBreak, Strikethrough, Strong, THead, Table, Text,
  ThematicBreak, lookup_link,
}
import session_view/text_hygiene
import tui/theme

type InlinePart {
  Styled(span.Span)
  Break
}

// Code blocks keep the model's bytes but give common Gleam token classes
// enough contrast to scan quickly. This is presentation, not parsing: the
// compiler remains the only authority on whether a program is valid.
type CodePart {
  CodePart(text: String, kind: CodeKind)
}

type CodeKind {
  CodePlain
  CodeKeyword
  CodeType
  CodeString
  CodeNumber
  CodeComment
  CodePunctuation
  CodeAdded
  CodeRemoved
  CodeDiffMeta
}

type CodeCharacter {
  SpaceCharacter
  IdentifierCharacter
  NumberCharacter
  QuoteCharacter
  PunctuationCharacter
}

// How a finished row must be treated once the viewport width is known.
type RowKind {
  // Preformatted source under a gutter: hard-wrapped at the width with the
  // gutter repeated, because a word wrapper would collapse its indentation.
  CodeRow

  // Already laid out against the width, such as a table's grid or a user
  // block's shaded body. Re-wrapping would destroy the alignment.
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

// A GitHub-flavoured alert: a block quote whose first paragraph opens with
// one of five bracketed markers. Mork does not model these, so the marker is
// recognised here, on the inlines the quote's first paragraph parsed into.
type Alert {
  Note
  Tip
  Important
  Warning
  Caution
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
  // Chat output is content, not a document envelope. Enable the extensions
  // that affect presentation without treating a leading thematic break as
  // frontmatter and silently discarding model text.
  let options =
    mork.configure()
    |> mork.tables(True)
    |> mork.tasklists(True)
    |> mork.heading_ids(True)
    |> mork.emojis(True)
    |> mork.autolinks(True)
  let document = mork.parse_with_options(options, safe)
  let Document(blocks:, ..) = document
  list.flat_map(blocks, render_block(document, _, width))
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
    True -> code_rows(source, [], width, [])
    False -> code_rows(source, prefix, budget, [])
  }
}

fn code_rows(
  source: List(span.Span),
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
  let shaded = list.any(spans, is_user_body_span)

  // The code gutter is tested first because a grid glyph is a single
  // character and a tokenised code row emits every punctuation character as
  // its own span, so a box-drawn diagram inside a fence produces a span that
  // is exactly the grid's vertical bar. Reading that row as a grid row would
  // cost it both its hard wrap and its continuation gutter. The converse
  // cannot happen: a grid row never carries the code gutter.
  case code, grid, digest, shaded {
    True, _, _, _ -> CodeRow
    _, True, _, _ | _, _, True, _ | _, _, _, True -> FixedRow
    False, False, False, False -> FlowingRow
  }
}

fn is_grid_span(value: span.Span) -> Bool {
  case value.content {
    "│" | "┌" | "┬" | "┐" | "├" | "┼" | "┤" | "└" | "┴" | "┘" -> True
    _ -> False
  }
}

// User rows have a three-space gutter painted on a shaded background.
// Additional leading whitespace is source indentation; word wrapping would
// collapse it and the alignment it carries.
fn is_user_body_span(value: span.Span) -> Bool {
  let span.Span(content:, style: row_style, ..) = value
  row_style == style.new(theme.paper, theme.user_background, style.none())
  && string.starts_with(content, "    ")
}

fn render_block(
  document: Document,
  block: Block,
  width: Int,
) -> List(span.Line) {
  case block {
    // Claude Code, and every other terminal renderer a reader is likely to
    // have seen, marks a heading with weight alone. The bar that used to sit
    // here said nothing the bold did not and cost two cells of every row.
    Heading(level:, inlines:, ..) ->
      inline_lines(document, inlines, heading_style(level))
      |> trailing_blank
    Paragraph(inlines:, ..) ->
      inline_lines(document, inlines, style.default_style())
      |> trailing_blank
    Code(lang:, text:) ->
      text
      |> string.split("\n")
      |> drop_final_empty
      |> list.map(fn(line) {
        span.line_new([
          span.span_styled(code_gutter, theme.signal_bold()),
          ..code_spans(lang, line)
        ])
      })
      |> prepend_code_language(lang)
      |> trailing_blank
    BlockQuote(blocks:) -> {
      // A quote's bar costs two cells of every row it covers, and quotes
      // nest, so the inner width is floored at one: a block measured against
      // a width of zero or less would have no room at all to lay itself out.
      let inner = int.max(1, width - 2)
      alert_of(blocks)
      |> result.map(fn(found) {
        render_alert(document, found.0, found.1, inner)
      })
      |> result.lazy_unwrap(fn() { render_quote(document, blocks, inner) })
    }
    BulletList(items:, ..) -> render_list(document, items, None, width)
    OrderedList(items:, start:, ..) ->
      render_list(document, items, Some(unwrap(start, 1)), width)
    Table(header:, rows:) -> render_table(document, header, rows, width)
    ThematicBreak -> [
      span.line_new([span.span_styled("────────────────", theme.quiet_text())]),
      span.line_plain(""),
    ]
    HtmlBlock(raw:) -> [
      span.line_new([span.span_styled(raw, theme.quiet_text())]),
      span.line_plain(""),
    ]
    Empty | Newline -> []
  }
}

fn render_quote(
  document: Document,
  blocks: List(Block),
  width: Int,
) -> List(span.Line) {
  blocks
  |> list.flat_map(render_block(document, _, width))
  |> prefix_lines([span.span_styled(quote_gutter, theme.current_bold())], [
    span.span_styled(quote_gutter, theme.current_bold()),
  ])
}

// An alert is a titled callout, not a quotation, so it drops the quote bar and
// carries its kind on a heading row instead. The body is indented under that
// title so the callout reads as one unit even where colour is unavailable.
fn render_alert(
  document: Document,
  alert: Alert,
  blocks: List(Block),
  width: Int,
) -> List(span.Line) {
  let title =
    span.line_new([
      span.span_styled("▌ ", alert_style(alert)),
      span.span_styled(alert_title(alert), alert_style(alert)),
    ])
  let body =
    blocks
    |> list.flat_map(render_block(document, _, width))
    |> prefix_lines([span.span_plain("  ")], [span.span_plain("  ")])
  [title, ..body]
}

// Mork parses `[!NOTE]` as three adjacent text inlines, so the marker is
// matched on that shape and then removed along with the separator that
// followed it. A quote whose first paragraph does not open this way, or whose
// marker names no known kind, stays an ordinary quotation.
fn alert_of(blocks: List(Block)) -> Result(#(Alert, List(Block)), Nil) {
  case blocks {
    [
      Paragraph(inlines: [Text("["), Text(marker), Text("]"), ..rest], ..),
      ..tail
    ] -> {
      use alert <- result.try(alert_kind(marker))
      Ok(#(alert, alert_body(rest, tail)))
    }
    _ -> Error(Nil)
  }
}

// A marker alone on its line leaves an empty paragraph behind, which would
// render as a blank row between the title and the body.
fn alert_body(rest: List(Inline), tail: List(Block)) -> List(Block) {
  case drop_leading_break(rest) {
    [] -> tail
    inlines -> [Paragraph(raw: "", inlines:), ..tail]
  }
}

fn drop_leading_break(inlines: List(Inline)) -> List(Inline) {
  case inlines {
    [SoftBreak, ..rest] -> drop_leading_break(rest)
    [Text(value), ..rest] -> drop_leading_space(value, rest)
    _ -> inlines
  }
}

fn drop_leading_space(value: String, rest: List(Inline)) -> List(Inline) {
  case string.trim_start(value) {
    "" -> drop_leading_break(rest)
    trimmed -> [Text(trimmed), ..rest]
  }
}

fn alert_kind(marker: String) -> Result(Alert, Nil) {
  case string.lowercase(marker) {
    "!note" -> Ok(Note)
    "!tip" -> Ok(Tip)
    "!important" -> Ok(Important)
    "!warning" -> Ok(Warning)
    "!caution" -> Ok(Caution)
    _ -> Error(Nil)
  }
}

// The palette has no violet, so `Important` takes the strongest neutral the
// theme offers rather than borrowing a hue that already means something else.
fn alert_style(alert: Alert) -> style.Style {
  case alert {
    Note -> theme.current_bold()
    Tip -> theme.success_text()
    Important -> style.new(theme.paper, style.Default, style.bold())
    Warning -> theme.signal_bold()
    Caution -> theme.danger_text()
  }
}

fn alert_title(alert: Alert) -> String {
  case alert {
    Note -> "Note"
    Tip -> "Tip"
    Important -> "Important"
    Warning -> "Warning"
    Caution -> "Caution"
  }
}

fn heading_style(level: Int) -> style.Style {
  case level <= 2 {
    True -> theme.current_bold()
    False -> style.new(theme.paper, style.Default, style.bold())
  }
}

fn code_style() -> style.Style {
  style.new(theme.paper, style.Default, style.none())
}

fn code_spans(language: Option(String), line: String) -> List(span.Span) {
  case language {
    Some(name) ->
      case string.lowercase(string.trim(name)) {
        "gleam" ->
          line
          |> string.to_graphemes
          |> gleam_parts([])
          |> list.map(code_span)
        "diff" -> [diff_span(line)]
        _ -> [span.span_styled(line, code_style())]
      }
    None -> [span.span_styled(line, code_style())]
  }
}

fn diff_span(line: String) -> span.Span {
  let kind = case line {
    "+++" <> _ | "---" <> _ | "@@" <> _ | "diff " <> _ | "*** " <> _ ->
      CodeDiffMeta
    "+" <> _ -> CodeAdded
    "-" <> _ -> CodeRemoved
    _ -> CodePlain
  }
  code_span(CodePart(line, kind))
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

fn gleam_parts(
  characters: List(String),
  accumulated: List(CodePart),
) -> List(CodePart) {
  case characters {
    [] -> list.reverse(accumulated)
    ["/", "/", ..rest] ->
      list.reverse([
        CodePart("//" <> string.concat(rest), CodeComment),
        ..accumulated
      ])
    [character, ..rest] ->
      case code_character(character) {
        QuoteCharacter -> {
          let #(text, remaining) = quoted_text(rest, [character], False)
          gleam_parts(remaining, [CodePart(text, CodeString), ..accumulated])
        }
        SpaceCharacter -> {
          let #(tail, remaining) =
            take_code_characters(rest, SpaceCharacter, [])
          let text = string.concat([character, ..tail])
          gleam_parts(remaining, [CodePart(text, CodePlain), ..accumulated])
        }
        IdentifierCharacter -> {
          let #(tail, remaining) = take_identifier_characters(rest, [])
          let text = string.concat([character, ..tail])
          gleam_parts(remaining, [
            CodePart(text, word_kind(text)),
            ..accumulated
          ])
        }
        NumberCharacter -> {
          let #(tail, remaining) = take_number_characters(rest, [])
          let text = string.concat([character, ..tail])
          gleam_parts(remaining, [CodePart(text, CodeNumber), ..accumulated])
        }
        PunctuationCharacter ->
          gleam_parts(rest, [
            CodePart(character, CodePunctuation),
            ..accumulated
          ])
      }
  }
}

fn code_character(character: String) -> CodeCharacter {
  case character {
    " " | "\t" -> SpaceCharacter
    "\"" -> QuoteCharacter
    _ ->
      case
        string.contains(
          "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_@",
          character,
        )
      {
        True -> IdentifierCharacter
        False ->
          case string.contains("0123456789", character) {
            True -> NumberCharacter
            False -> PunctuationCharacter
          }
      }
  }
}

fn take_code_characters(
  characters: List(String),
  wanted: CodeCharacter,
  accumulated: List(String),
) -> #(List(String), List(String)) {
  case characters {
    [character, ..rest] ->
      case code_character(character) == wanted {
        True -> take_code_characters(rest, wanted, [character, ..accumulated])
        False -> #(list.reverse(accumulated), characters)
      }
    [] -> #(list.reverse(accumulated), [])
  }
}

fn take_identifier_characters(
  characters: List(String),
  accumulated: List(String),
) -> #(List(String), List(String)) {
  case characters {
    [character, ..rest] ->
      case code_character(character) {
        IdentifierCharacter | NumberCharacter ->
          take_identifier_characters(rest, [character, ..accumulated])
        SpaceCharacter | QuoteCharacter | PunctuationCharacter -> #(
          list.reverse(accumulated),
          characters,
        )
      }
    [] -> #(list.reverse(accumulated), [])
  }
}

fn take_number_characters(
  characters: List(String),
  accumulated: List(String),
) -> #(List(String), List(String)) {
  case characters {
    [character, ..rest] ->
      case code_character(character) {
        NumberCharacter ->
          take_number_characters(rest, [character, ..accumulated])
        IdentifierCharacter if character == "_" ->
          take_number_characters(rest, [character, ..accumulated])
        SpaceCharacter
        | IdentifierCharacter
        | QuoteCharacter
        | PunctuationCharacter -> #(list.reverse(accumulated), characters)
      }
    [] -> #(list.reverse(accumulated), [])
  }
}

fn quoted_text(
  characters: List(String),
  accumulated: List(String),
  escaped: Bool,
) -> #(String, List(String)) {
  case characters, escaped {
    [], _ -> #(string.concat(list.reverse(accumulated)), [])
    [character, ..rest], True ->
      quoted_text(rest, [character, ..accumulated], False)
    ["\\", ..rest], False -> quoted_text(rest, ["\\", ..accumulated], True)
    ["\"", ..rest], False -> #(
      string.concat(list.reverse(["\"", ..accumulated])),
      rest,
    )
    [character, ..rest], False ->
      quoted_text(rest, [character, ..accumulated], False)
  }
}

fn word_kind(word: String) -> CodeKind {
  case
    list.contains(
      [
        "as", "assert", "case", "const", "echo", "fn", "if", "import", "let",
        "opaque", "panic", "pub", "todo", "type", "use",
      ],
      word,
    )
  {
    True -> CodeKeyword
    False ->
      case string.to_graphemes(word) {
        [first, ..] ->
          case string.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ", first) {
            True -> CodeType
            False -> CodePlain
          }
        [] -> CodePlain
      }
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
  document: Document,
  items: List(ListItem),
  ordered_start: Option(Int),
  width: Int,
) -> List(span.Line) {
  items
  |> list.index_map(fn(item, index) {
    let ListItem(blocks:, ..) = item
    let marker = case ordered_start {
      Some(start) -> int.to_string(start + index) <> ". "
      None -> "• "
    }

    // The marker is a prefix on every row of the item, so anything measured
    // inside it, a table above all, has that many fewer cells to work with.
    // Floored at one for the same reason a nested quote is.
    let inner = int.max(1, width - string.length(marker))

    blocks
    |> list.flat_map(render_block(document, _, inner))
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
  document: Document,
  header: List(THead),
  rows: List(List(Cell)),
  width: Int,
) -> List(span.Line) {
  case header {
    [] -> []
    _ -> table_lines(document, header, rows, width)
  }
}

fn table_lines(
  document: Document,
  header: List(THead),
  rows: List(List(Cell)),
  width: Int,
) -> List(span.Line) {
  let columns = list.length(header)
  let alignments =
    list.map(header, fn(cell) {
      let THead(align:, ..) = cell
      align
    })
  let headings =
    list.map(header, fn(cell) {
      let THead(inlines:, ..) = cell
      inline_spans(document, inlines, theme.current_bold()) |> trim_span_edges
    })
  let body =
    list.map(rows, fn(row) {
      row
      |> list.map(fn(cell) {
        let Cell(inlines:, ..) = cell
        inline_spans(document, inlines, style.default_style())
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
  alignments: List(Alignment),
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

// Mork rejects a source row whose pipe count disagrees with the header, so a
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
  alignments: List(Alignment),
  widths: List(Int),
) -> List(span.Line) {
  let columns =
    list.map2(widths, alignments, fn(width, alignment) { #(width, alignment) })
  let centred = list.map(widths, fn(width) { #(width, Center) })
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
  columns: List(#(Int, Alignment)),
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
  columns: List(#(Int, Alignment)),
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
  alignment: Alignment,
) -> List(span.Span) {
  let slack = int.max(0, width - spans_width(cell))
  let #(before, after) = case alignment {
    Left -> #(0, slack)
    Right -> #(slack, 0)
    Center -> #(slack / 2, slack - slack / 2)
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
  let #(head, _) = take_span_cells(spans, width, [])
  head
}

// Splitting on cell boundaries rather than on words is what preserves a code
// row's indentation; the caller supplies the budget already reduced by
// whatever gutter it intends to repeat.
fn take_span_cells(
  spans: List(span.Span),
  budget: Int,
  taken: List(span.Span),
) -> #(List(span.Span), List(span.Span)) {
  case spans {
    [] -> #(list.reverse(taken), [])
    [first, ..rest] -> take_span_cell(first, rest, budget, taken)
  }
}

fn take_span_cell(
  first: span.Span,
  rest: List(span.Span),
  budget: Int,
  taken: List(span.Span),
) -> #(List(span.Span), List(span.Span)) {
  let width = text.cell_width(first.content)
  case width <= budget {
    True -> take_span_cells(rest, budget - width, [first, ..taken])
    False -> {
      let #(head, tail) = split_content(first.content, budget)
      #(list.reverse([span.Span(..first, content: head), ..taken]), [
        span.Span(..first, content: tail),
        ..rest
      ])
    }
  }
}

fn split_content(content: String, budget: Int) -> #(String, String) {
  case budget <= 0 {
    True -> #("", content)
    False -> take_graphemes(string.to_graphemes(content), budget, [])
  }
}

// A positive budget always consumes at least one grapheme. Without that a
// column one cell wide facing a two-cell glyph would hand the caller an empty
// row and the same remainder, and the wrapping loop would never terminate.
fn take_graphemes(
  graphemes: List(String),
  budget: Int,
  taken: List(String),
) -> #(String, String) {
  case graphemes {
    [] -> #(joined(taken), "")
    [first, ..rest] ->
      case text.grapheme_cell_width(first) <= budget || taken == [] {
        True ->
          take_graphemes(rest, budget - text.grapheme_cell_width(first), [
            first,
            ..taken
          ])
        False -> #(joined(taken), string.concat(graphemes))
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
/// A paragraph's lines are its inline parts in order, one span each, and a
/// soft break is a single space in the paragraph's plain style; nothing
/// merges the spans on either side of it. Mork trims the trailing
/// whitespace of the plain text a line ends with when a soft break follows,
/// and keeps it when the paragraph ends there, so `head`'s last span, which
/// was parsed as the end of a paragraph, is trimmed the same way and dropped
/// if nothing is left. So when neither side's parse can reach into the
/// other, the paragraph's line is `head`'s spans so trimmed, the space, then
/// `next`'s. The live tail uses this to add the lines that just arrived to a
/// long paragraph without parsing its start again, and it is the only place
/// that knows what a soft break draws as.
///
/// ## Examples
///
/// ```gleam
/// let joined =
///   markdown.join_soft_break(span.line_plain("one "), span.line_plain("two"))
/// // "one", " ", "two"
/// ```
@internal
pub fn join_soft_break(head: span.Line, next: span.Line) -> span.Line {
  let plain = style.default_style()
  let kept = case list.reverse(head.spans) {
    [last, ..before] if last.style == plain && last.link == "" ->
      case string.trim_end(last.content) {
        "" -> list.reverse(before)
        trimmed -> list.reverse([span.Span(..last, content: trimmed), ..before])
      }
    _ -> head.spans
  }
  span.Line(
    ..head,
    spans: list.append(kept, [span.span_styled(" ", plain), ..next.spans]),
  )
}

fn inline_lines(
  document: Document,
  inlines: List(Inline),
  base: style.Style,
) -> List(span.Line) {
  inlines
  |> list.flat_map(inline_parts(document, _, base))
  |> parts_to_lines([], [])
}

fn inline_spans(
  document: Document,
  inlines: List(Inline),
  base: style.Style,
) -> List(span.Span) {
  inlines
  |> list.flat_map(inline_parts(document, _, base))
  |> list.filter_map(fn(part) {
    case part {
      Styled(value) -> Ok(value)
      Break -> Error(Nil)
    }
  })
}

fn inline_parts(
  document: Document,
  inline: Inline,
  base: style.Style,
) -> List(InlinePart) {
  case inline {
    Text(value) -> [Styled(span.span_styled(value, base))]

    // An inline code span painted in the prose colour with no modifier was
    // prose as far as the reader was concerned. The cold hue separates a
    // symbol from the sentence around it without adding a background that
    // would break up a wrapped paragraph.
    CodeSpan(value) -> [Styled(span.span_styled(value, theme.inline_code()))]
    Emphasis(children) ->
      nested_parts(document, children, style.add_modifier(base, style.italic()))
    Strong(children) ->
      nested_parts(document, children, style.add_modifier(base, style.bold()))

    // Mork recognizes paired == delimiters even in ordinary comparisons.
    // Preserve those operators as text instead of coloring unrelated prose.
    Highlight(children) ->
      list.append(
        [
          Styled(span.span_styled("==", base)),
          ..nested_parts(document, children, base)
        ],
        [Styled(span.span_styled("==", base))],
      )

    // Dim was a poor stand-in: it is also what quiet metadata uses, so struck
    // text and an aside were the same grey, and an unmatched `~~` run nearby
    // rendered in the base style and read as the emphasised one.
    Strikethrough(children) ->
      nested_parts(
        document,
        children,
        style.add_modifier(base, style.strikethrough()),
      )
    FullLink(text:, data:) -> link_parts(document, text, data, base)
    RefLink(text:, label:) ->
      case lookup_link(document, label) {
        Ok(data) -> link_parts(document, text, data, base)
        Error(Nil) -> nested_parts(document, text, base)
      }
    Autolink(uri:, text:) -> [
      link_span(unwrap(text, uri), uri, base) |> Styled,
    ]
    EmailAutolink(mail:) -> [link_span(mail, "mailto:" <> mail, base) |> Styled]
    FullImage(text:, data:) -> image_parts(document, text, data, base)
    RefImage(text:, label:) ->
      case lookup_link(document, label) {
        Ok(data) -> image_parts(document, text, data, base)
        Error(Nil) -> [
          Styled(span.span_styled("[image: " <> label <> "]", base)),
        ]
      }
    Footnote(num:, ..) -> [
      Styled(span.span_styled(
        "[" <> int.to_string(num) <> "]",
        theme.quiet_text(),
      )),
    ]
    InlineFootnote(num:, text:) ->
      [
        Styled(span.span_styled(
          "[" <> int.to_string(num) <> ": ",
          theme.quiet_text(),
        )),
        ..nested_parts(document, text, theme.quiet_text())
      ]
      |> list.append([Styled(span.span_styled("]", theme.quiet_text()))])
    Checkbox(checked:) -> [
      Styled(span.span_styled(
        case checked {
          True -> "☑ "
          False -> "☐ "
        },
        theme.signal_bold(),
      )),
    ]
    InlineHtml(children:, ..) -> nested_parts(document, children, base)
    RawHtml(raw) -> [Styled(span.span_styled(raw, theme.quiet_text()))]
    SoftBreak -> [Styled(span.span_styled(" ", base))]
    HardBreak -> [Break]
    Delim(style: delimiter, len:, ..) -> [
      Styled(span.span_styled(string.repeat(delimiter, len), base)),
    ]
  }
}

fn nested_parts(
  document: Document,
  inlines: List(Inline),
  base: style.Style,
) -> List(InlinePart) {
  list.flat_map(inlines, inline_parts(document, _, base))
}

fn link_parts(
  document: Document,
  text: List(Inline),
  data: LinkData,
  base: style.Style,
) -> List(InlinePart) {
  let LinkData(dest:, ..) = data
  let uri = destination(dest)
  nested_parts(document, text, link_style(base))
  |> list.map(fn(part) {
    case part {
      Styled(value) -> Styled(span.with_link(value, uri))
      Break -> Break
    }
  })
}

fn image_parts(
  document: Document,
  text: List(Inline),
  data: LinkData,
  base: style.Style,
) -> List(InlinePart) {
  let LinkData(dest:, ..) = data
  [
    Styled(span.span_styled("[image: ", theme.quiet_text())),
    ..nested_parts(document, text, base)
  ]
  |> list.append([
    Styled(span.span_styled(
      " · " <> destination(dest) <> "]",
      theme.quiet_text(),
    )),
  ])
}

fn link_span(label: String, uri: String, base: style.Style) -> span.Span {
  span.span_styled(label, link_style(base)) |> span.with_link(uri)
}

fn link_style(base: style.Style) -> style.Style {
  base
  |> style.with_fg(theme.current)
  |> style.add_modifier(style.underline())
}

fn destination(value: Destination) -> String {
  case value {
    Absolute(uri) | Relative(uri) -> uri
    Anchor(id) -> "#" <> id
  }
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

fn drop_final_empty(lines: List(String)) -> List(String) {
  case list.reverse(lines) {
    ["", ..rest] -> list.reverse(rest)
    _ -> lines
  }
}
