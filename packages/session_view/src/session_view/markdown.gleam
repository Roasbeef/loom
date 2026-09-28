//// Markdown as a closed tree, for a host that draws an answer as elements
//// rather than as terminal rows.
////
//// The web view has to show an assistant's bold text, lists and code fences
//// the way the terminal does, and it may only put session text into the page
//// as text nodes (protocol-change/051, "Nothing from the session becomes
//// markup"). So the model's Markdown is parsed here, into `Block` and
//// `Inline` values whose every string is text to be shown, and the view maps
//// each variant to an element. No variant carries HTML: a tag in the source
//// is ordinary text, and a link keeps its destination as a string the view
//// prints rather than a URL it follows.
////
//// The parser is Loom's own and deliberately small. The terminal renders
//// through mork, a full CommonMark parser, but mork's link parsing
//// backtracks: a run of unclosed `[` takes time exponential in its length
//// (twenty of them took most of a second when this module was written), and
//// a model can emit that run. A page must not stall on its own transcript,
//// so this parser is written to a budget instead of to the whole
//// specification. Every step consumes input or finishes a construct; the
//// two scans that look ahead (a code span's closing run and a link's
//// destination) are arranged so that no character is scanned more than a
//// fixed number of times. The work is linear in the length of the text.
////
//// Nesting is bounded as well. Block containers, quotes and list items,
//// stop being recognised `max_depth` levels down, where their markers become
//// paragraph text, so a thousand `>` produce eight quotes and the text of the
//// rest. Emphasis stops opening at `max_emphasis` open delimiters, and a link
//// cannot contain a link, so the inline tree is shallow too. A view that
//// recurses over the result recurses a bounded number of levels.
////
//// What it recognises: ATX and setext headings, paragraphs, fenced and
//// indented code, block quotes, bullet and ordered lists with task boxes,
//// thematic breaks, GitHub pipe tables, code spans, emphasis, strong
//// emphasis, strikethrough, links, images, autolinks, backslash escapes and
//// hard breaks. What it leaves as text: HTML, entity references, link
//// reference definitions, footnotes and emoji shortcodes.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// One block of a Markdown document.
pub type Block {
  /// Running text.
  Paragraph(inlines: List(Inline))

  /// A heading, from `#` lines or from a setext underline.
  Heading(level: Level, inlines: List(Inline))

  /// Preformatted source. `language` is the first word of a fence's info
  /// string, kept as text for a label and never as a class or attribute.
  CodeBlock(language: Option(String), text: String)

  /// A block quote and the blocks inside it.
  Quote(blocks: List(Block))

  /// An unordered list; each item is the blocks inside it.
  BulletList(items: List(List(Block)))

  /// An ordered list whose first item carries `start`; each item is the
  /// blocks inside it.
  OrderedList(start: Int, items: List(List(Block)))

  /// A pipe table. Every row has exactly as many cells as the header.
  Table(header: List(Cell), rows: List(List(Cell)))

  /// A thematic break.
  Rule
}

/// A heading's level. A closed type rather than an `Int`, so a view maps
/// each level to a fixed class with no range to check.
pub type Level {
  /// `#`, or text underlined with `=`.
  H1

  /// `##`, or text underlined with `-`.
  H2

  /// `###`.
  H3

  /// `####`.
  H4

  /// `#####`.
  H5

  /// `######`.
  H6
}

/// One table cell and the alignment its column's delimiter row asked for.
pub type Cell {
  Cell(align: Align, inlines: List(Inline))
}

/// A table column's alignment.
pub type Align {
  /// A delimiter cell of dashes only.
  Unaligned

  /// `:--`.
  Left

  /// `:-:`.
  Center

  /// `--:`.
  Right
}

/// A span of text inside a block.
pub type Inline {
  /// Plain text.
  Text(text: String)

  /// A code span's text, spaces normalized as CommonMark does.
  Code(text: String)

  /// Emphasis, from `*` or `_`.
  Emphasis(children: List(Inline))

  /// Strong emphasis, from `**` or `__`.
  Strong(children: List(Inline))

  /// Struck text, from `~~`.
  Strikethrough(children: List(Inline))

  /// A link's label and its destination as written. The destination is
  /// session text like any other; a view prints it and never follows it.
  Link(label: List(Inline), destination: String)

  /// An image's alternative text and its destination, both as text.
  Image(alt: String, destination: String)

  /// A hard line break.
  Break
}

/// How many levels of quotes and list items are recognised. A container
/// marker deeper than this is paragraph text.
pub const max_depth = 8

/// How many emphasis delimiters may be open at once. A delimiter that would
/// open past this is text.
pub const max_emphasis = 8

/// Parses Markdown into blocks.
///
/// Total: every input produces a tree, and an unclosed construct becomes
/// text or, for a code fence, runs to the end of the input. The time taken is
/// linear in the input's length, and the tree's depth is bounded by
/// `max_depth` and `max_emphasis`.
///
/// ## Examples
///
/// ```gleam
/// assert markdown.parse("**bold**")
///   == [markdown.Paragraph([markdown.Strong([markdown.Text("bold")])])]
/// ```
pub fn parse(text: String) -> List(Block) {
  text
  |> string.replace("\r\n", "\n")
  |> string.replace("\r", "\n")
  |> string.split("\n")
  |> list.map(expand_leading_tabs)
  |> blocks(0)
}

/// The text of inlines with their markup removed, as an image's alternative
/// text is written.
///
/// ## Examples
///
/// ```gleam
/// assert markdown.plain([markdown.Strong([markdown.Text("a")]), markdown.Code("b")])
///   == "ab"
/// ```
pub fn plain(inlines: List(Inline)) -> String {
  inlines
  |> list.map(plain_one)
  |> string.concat
}

fn plain_one(inline: Inline) -> String {
  case inline {
    Text(text:) | Code(text:) -> text
    Emphasis(children:) | Strong(children:) | Strikethrough(children:) ->
      plain(children)
    Link(label:, ..) -> plain(label)
    Image(alt:, ..) -> alt
    Break -> " "
  }
}

// A tab in a line's indentation counts as four columns. Only the leading run
// is expanded, since indentation is all the block parser measures, and a
// line whose indentation holds no tab is returned as it came.
fn expand_leading_tabs(line: String) -> String {
  let #(width, rest) = indentation(line, 0)
  case string.byte_size(rest) + width == string.byte_size(line) {
    True -> line
    False -> string.repeat(" ", width) <> rest
  }
}

fn indentation(line: String, width: Int) -> #(Int, String) {
  case line {
    " " <> rest -> indentation(rest, width + 1)
    "\t" <> rest -> indentation(rest, width + 4)
    _ -> #(width, line)
  }
}

// ---------------------------------------------------------------- blocks

// What one line can start, decided from the line alone. The block loop reads
// a line's kind and then consumes as many following lines as that block owns.
type Line {
  BlankLine
  FenceLine(indent: Int, mark: String, length: Int, info: String)
  HeadingLine(level: Level, text: String)
  RuleLine
  QuoteLine(content: String)
  ItemLine(item: Item)
  TextLine(indent: Int, text: String)
}

// A list item's first line. `width` is the column its content starts at,
// which every continuation line must reach to stay inside the item.
type Item {
  Item(marker: Marker, width: Int, content: String)
}

// Which list an item belongs to. Two items are siblings only when their
// markers agree: the same bullet character, or the same ordinal delimiter.
type Marker {
  Bullet(mark: String)
  Ordinal(number: Int, delimiter: String)
}

// Whether a line may continue the paragraph above it.
type Continuation {
  Continues
  Interrupts
}

fn blocks(lines: List(String), depth: Int) -> List(Block) {
  collect(lines, depth, [])
}

fn collect(lines: List(String), depth: Int, done: List(Block)) -> List(Block) {
  case lines {
    [] -> list.reverse(done)
    [line, ..rest] -> {
      let #(block, rest) = next_block(classify(line, depth), line, rest, depth)
      case block {
        Some(block) -> collect(rest, depth, [block, ..done])
        None -> collect(rest, depth, done)
      }
    }
  }
}

// One block from its first line and the lines after it, with the lines the
// block did not take.
fn next_block(
  kind: Line,
  line: String,
  rest: List(String),
  depth: Int,
) -> #(Option(Block), List(String)) {
  case kind {
    BlankLine -> #(None, rest)

    // An unclosed fence runs to the end of the lines it was given, which
    // for a quote or a list item is the end of that container and for a
    // transcript row is the end of the row. It never reaches a later row.
    FenceLine(indent:, mark:, length:, info:) -> {
      let #(body, rest) = fence_body(rest, indent, mark, length, [])
      #(Some(CodeBlock(language(info), string.join(body, "\n"))), rest)
    }

    HeadingLine(level:, text:) -> #(Some(Heading(level, inlines(text))), rest)
    RuleLine -> #(Some(Rule), rest)

    // A container's lines are gathered with their markers removed and
    // parsed again one level down, where `classify` stops recognising
    // containers once `max_depth` is reached.
    QuoteLine(content:) -> {
      let #(inner, rest) = quoted(rest, [content])
      #(Some(Quote(blocks(inner, depth + 1))), rest)
    }

    ItemLine(item:) -> {
      let #(items, rest) = list_items(item, rest, depth, [])
      #(Some(list_block(item.marker, items)), rest)
    }

    TextLine(indent:, ..) if indent >= 4 -> indented_code([line, ..rest], [])
    TextLine(..) -> paragraph(line, rest, depth)
  }
}

fn classify(line: String, depth: Int) -> Line {
  let #(indent, rest) = indentation(line, 0)
  case string.trim_end(rest) {
    "" -> BlankLine
    _ if indent >= 4 -> TextLine(indent:, text: rest)
    _ -> block_line(indent, rest, depth)
  }
}

fn block_line(indent: Int, rest: String, depth: Int) -> Line {
  fence_line(indent, rest)
  |> result.lazy_or(fn() { heading_line(rest) })
  |> result.lazy_or(fn() { rule_line(rest) })
  |> result.lazy_or(fn() { quote_line(rest, depth) })
  |> result.lazy_or(fn() { item_line(indent, rest, depth) })
  |> result.lazy_unwrap(fn() { TextLine(indent:, text: rest) })
}

fn fence_line(indent: Int, rest: String) -> Result(Line, Nil) {
  case rest {
    "```" <> _ -> fence_of(indent, rest, "`")
    "~~~" <> _ -> fence_of(indent, rest, "~")
    _ -> Error(Nil)
  }
}

// A backtick fence's info string may not hold a backtick, which is what
// keeps an inline code span at the start of a line from opening a fence.
fn fence_of(indent: Int, rest: String, mark: String) -> Result(Line, Nil) {
  let #(length, info) = run(rest, mark, 0)
  let info = string.trim(info)
  case mark == "`" && string.contains(info, "`") {
    True -> Error(Nil)
    False -> Ok(FenceLine(indent:, mark:, length:, info:))
  }
}

// The length of the run of `mark` that opens `text`, and what follows it.
fn run(text: String, mark: String, count: Int) -> #(Int, String) {
  case string.pop_grapheme(text) {
    Ok(#(grapheme, rest)) if grapheme == mark -> run(rest, mark, count + 1)
    _ -> #(count, text)
  }
}

fn language(info: String) -> Option(String) {
  case string.split_once(info, " ") {
    Ok(#(word, _)) -> Some(word)
    Error(Nil) if info == "" -> None
    Error(Nil) -> Some(info)
  }
}

fn fence_body(
  lines: List(String),
  indent: Int,
  mark: String,
  length: Int,
  body: List(String),
) -> #(List(String), List(String)) {
  case lines {
    [] -> #(list.reverse(body), [])
    [line, ..rest] ->
      case closes_fence(line, mark, length) {
        True -> #(list.reverse(body), rest)
        False ->
          fence_body(rest, indent, mark, length, [
            drop_spaces(line, indent),
            ..body
          ])
      }
  }
}

fn closes_fence(line: String, mark: String, length: Int) -> Bool {
  let #(indent, rest) = indentation(line, 0)
  let #(count, after) = run(rest, mark, 0)
  indent < 4 && count >= length && string.trim(after) == ""
}

// Up to `count` leading spaces removed, and no more: a code line indented
// less than its fence keeps what it has.
fn drop_spaces(line: String, count: Int) -> String {
  case count > 0, line {
    True, " " <> rest -> drop_spaces(rest, count - 1)
    _, _ -> line
  }
}

fn heading_line(rest: String) -> Result(Line, Nil) {
  let #(count, after) = run(rest, "#", 0)
  use level <- result.try(level_of(count))
  case after {
    "" -> Ok(HeadingLine(level:, text: ""))
    " " <> text -> Ok(HeadingLine(level:, text: heading_text(text)))
    _ -> Error(Nil)
  }
}

fn level_of(count: Int) -> Result(Level, Nil) {
  case count {
    1 -> Ok(H1)
    2 -> Ok(H2)
    3 -> Ok(H3)
    4 -> Ok(H4)
    5 -> Ok(H5)
    6 -> Ok(H6)
    _ -> Error(Nil)
  }
}

// A closing run of `#` is dropped when a space separates it from the text,
// so `# Title ##` is "Title" but `# C#` keeps its sharp. The run is measured
// on the reversed text, once, rather than trimmed one character at a time.
fn heading_text(text: String) -> String {
  let trimmed = string.trim(text)
  let #(closing, reversed) = run(string.reverse(trimmed), "#", 0)
  let without = string.reverse(reversed)
  case closing > 0 && { without == "" || string.ends_with(without, " ") } {
    True -> string.trim_end(without)
    False -> trimmed
  }
}

fn rule_line(rest: String) -> Result(Line, Nil) {
  case rest {
    "-" <> _ -> rule_of(rest, "-")
    "*" <> _ -> rule_of(rest, "*")
    "_" <> _ -> rule_of(rest, "_")
    _ -> Error(Nil)
  }
}

fn rule_of(rest: String, mark: String) -> Result(Line, Nil) {
  case rule_marks(rest, mark, 0) {
    Ok(count) if count >= 3 -> Ok(RuleLine)
    _ -> Error(Nil)
  }
}

fn rule_marks(text: String, mark: String, count: Int) -> Result(Int, Nil) {
  case string.pop_grapheme(text) {
    Error(Nil) -> Ok(count)
    Ok(#(" ", rest)) -> rule_marks(rest, mark, count)
    Ok(#(grapheme, rest)) if grapheme == mark ->
      rule_marks(rest, mark, count + 1)
    Ok(_) -> Error(Nil)
  }
}

fn quote_line(rest: String, depth: Int) -> Result(Line, Nil) {
  case depth >= max_depth {
    True -> Error(Nil)
    False ->
      result.map(quote_content(rest), fn(content) { QuoteLine(content:) })
  }
}

fn quote_content(rest: String) -> Result(String, Nil) {
  case rest {
    "> " <> content | ">" <> content -> Ok(content)
    _ -> Error(Nil)
  }
}

fn item_line(indent: Int, rest: String, depth: Int) -> Result(Line, Nil) {
  case depth >= max_depth {
    True -> Error(Nil)
    False -> result.map(item_of(indent, rest), fn(item) { ItemLine(item:) })
  }
}

// The content starts after the marker and the spaces that follow it, unless
// there are five or more: then the item's content starts one space in and
// the rest is indentation that belongs to the content, as CommonMark has it.
fn item_of(indent: Int, rest: String) -> Result(Item, Nil) {
  use #(marker, marker_width, after) <- result.try(marker_of(rest))
  let #(spaces, content) = indentation(after, 0)
  let gap = case spaces >= 1 && spaces <= 4 && content != "" {
    True -> spaces
    False -> 1
  }
  let content = case gap == spaces {
    True -> content
    False -> drop_spaces(after, 1)
  }
  Ok(Item(marker:, width: indent + marker_width + gap, content:))
}

fn marker_of(rest: String) -> Result(#(Marker, Int, String), Nil) {
  case rest {
    "-" <> after -> bullet("-", after)
    "*" <> after -> bullet("*", after)
    "+" <> after -> bullet("+", after)
    _ -> ordinal(rest)
  }
}

fn bullet(mark: String, after: String) -> Result(#(Marker, Int, String), Nil) {
  case after {
    "" | " " <> _ -> Ok(#(Bullet(mark:), 1, after))
    _ -> Error(Nil)
  }
}

// At most nine digits, as CommonMark allows, which also keeps the number a
// small integer whatever the model wrote.
fn ordinal(rest: String) -> Result(#(Marker, Int, String), Nil) {
  let #(digits, after) = take_digits(rest, "", 0)
  use number <- result.try(int.parse(digits))
  let width = string.length(digits) + 1
  case after {
    "." <> tail -> ordinal_end(Ordinal(number:, delimiter: "."), width, tail)
    ")" <> tail -> ordinal_end(Ordinal(number:, delimiter: ")"), width, tail)
    _ -> Error(Nil)
  }
}

fn ordinal_end(
  marker: Marker,
  width: Int,
  tail: String,
) -> Result(#(Marker, Int, String), Nil) {
  case tail {
    "" | " " <> _ -> Ok(#(marker, width, tail))
    _ -> Error(Nil)
  }
}

fn take_digits(text: String, digits: String, count: Int) -> #(String, String) {
  case count < 9, string.pop_grapheme(text) {
    True, Ok(#(grapheme, rest)) ->
      case is_digit(grapheme) {
        True -> take_digits(rest, digits <> grapheme, count + 1)
        False -> #(digits, text)
      }
    _, _ -> #(digits, text)
  }
}

// The character classes below are tested by containment in a string of
// ASCII characters. A grapheme is one user-perceived character, and no
// grapheme is made of two of these, so containment is membership.
fn is_digit(grapheme: String) -> Bool {
  string.contains("0123456789", grapheme)
}

// The lines of a quote after its first. Each must carry its own `>`: a line
// without one ends the quote, where CommonMark would sometimes continue it
// lazily. Models write the marker on every line.
fn quoted(
  lines: List(String),
  inner: List(String),
) -> #(List(String), List(String)) {
  case lines {
    [] -> #(list.reverse(inner), [])
    [line, ..rest] -> {
      let #(indent, text) = indentation(line, 0)
      case indent < 4, quote_content(text) {
        True, Ok(content) -> quoted(rest, [content, ..inner])
        _, _ -> #(list.reverse(inner), lines)
      }
    }
  }
}

fn list_items(
  item: Item,
  lines: List(String),
  depth: Int,
  items: List(List(Block)),
) -> #(List(List(Block)), List(String)) {
  let #(body, rest) = item_body(lines, item.width, depth, [task(item.content)])
  let items = [blocks(body, depth + 1), ..items]
  case rest {
    [] -> #(list.reverse(items), [])
    [line, ..more] ->
      case sibling(classify(line, depth), item.marker) {
        Ok(next) -> list_items(next, more, depth, items)
        Error(Nil) -> #(list.reverse(items), rest)
      }
  }
}

fn sibling(kind: Line, marker: Marker) -> Result(Item, Nil) {
  case kind, marker {
    ItemLine(item: Item(marker: Bullet(mark: next), ..) as item), Bullet(mark:)
      if next == mark
    -> Ok(item)
    ItemLine(item: Item(marker: Ordinal(delimiter: next, ..), ..) as item),
      Ordinal(delimiter:, ..)
      if next == delimiter
    -> Ok(item)
    _, _ -> Error(Nil)
  }
}

// A task item's box is drawn as a glyph, as the terminal draws it.
fn task(content: String) -> String {
  case content {
    "[ ] " <> rest -> "☐ " <> rest
    "[x] " <> rest | "[X] " <> rest -> "☑ " <> rest
    _ -> content
  }
}

fn list_block(marker: Marker, items: List(List(Block))) -> Block {
  case marker {
    Bullet(..) -> BulletList(items:)
    Ordinal(number:, ..) -> OrderedList(start: number, items:)
  }
}

// The lines of an item after its first: those indented to its content
// column, blank lines followed by such a line, and paragraph text that
// directly continues a non-blank line (a lazy continuation). The lines are
// returned with the item's indentation removed.
fn item_body(
  lines: List(String),
  width: Int,
  depth: Int,
  body: List(String),
) -> #(List(String), List(String)) {
  case lines {
    [] -> #(list.reverse(body), [])
    [line, ..rest] -> {
      let #(indent, text) = indentation(line, 0)
      case string.trim_end(text), indent >= width {
        "", _ -> after_blank(lines, width, depth, body)
        _, True ->
          item_body(rest, width, depth, [drop_spaces(line, width), ..body])
        _, False -> lazy_line(line, rest, width, depth, body)
      }
    }
  }
}

// Blank lines belong to the item only when the item goes on after them.
// Either way they are consumed, so a sibling item after a blank line is the
// next line the list sees.
fn after_blank(
  lines: List(String),
  width: Int,
  depth: Int,
  body: List(String),
) -> #(List(String), List(String)) {
  let #(blanks, rest) = list.split_while(lines, is_blank)
  case rest {
    [next, ..] ->
      case indentation(next, 0).0 >= width {
        True ->
          item_body(
            rest,
            width,
            depth,
            list.append(list.map(blanks, fn(_) { "" }), body),
          )
        False -> #(list.reverse(body), rest)
      }
    [] -> #(list.reverse(body), [])
  }
}

fn lazy_line(
  line: String,
  rest: List(String),
  width: Int,
  depth: Int,
  body: List(String),
) -> #(List(String), List(String)) {
  let continues = case body, classify(line, depth) {
    [previous, ..], TextLine(..) -> !is_blank(previous)
    _, _ -> False
  }
  case continues {
    True -> item_body(rest, width, depth, [string.trim_start(line), ..body])
    False -> #(list.reverse(body), [line, ..rest])
  }
}

fn is_blank(line: String) -> Bool {
  string.trim(line) == ""
}

fn indented_code(
  lines: List(String),
  body: List(String),
) -> #(Option(Block), List(String)) {
  case lines {
    [line, ..rest] ->
      case is_blank(line) || indentation(line, 0).0 >= 4 {
        True -> indented_code(rest, [drop_spaces(line, 4), ..body])
        False -> code_from(body, lines)
      }
    [] -> code_from(body, [])
  }
}

// Blank lines at the end of an indented block separate it from what comes
// next rather than belonging to it.
fn code_from(
  body: List(String),
  rest: List(String),
) -> #(Option(Block), List(String)) {
  let text =
    body
    |> list.drop_while(is_blank)
    |> list.reverse
    |> string.join("\n")
  #(Some(CodeBlock(language: None, text:)), rest)
}

fn paragraph(
  line: String,
  rest: List(String),
  depth: Int,
) -> #(Option(Block), List(String)) {
  case table(line, rest) {
    Ok(#(block, rest)) -> #(Some(block), rest)
    Error(Nil) -> prose(rest, depth, [string.trim_start(line)])
  }
}

fn prose(
  lines: List(String),
  depth: Int,
  text: List(String),
) -> #(Option(Block), List(String)) {
  case lines {
    [] -> #(Some(Paragraph(inlines(joined(text)))), [])
    [line, ..rest] ->
      case setext(line) {
        Ok(level) -> #(Some(Heading(level, inlines(joined(text)))), rest)
        Error(Nil) -> prose_line(line, rest, depth, text)
      }
  }
}

fn prose_line(
  line: String,
  rest: List(String),
  depth: Int,
  text: List(String),
) -> #(Option(Block), List(String)) {
  case text, heads_table(text, line) {
    // A delimiter row under the paragraph's last line makes that line a
    // table header, as GitHub has it: the paragraph ends before it and the
    // header goes back to the block loop, which parses the table. A
    // paragraph of one line never reaches here with a table under it,
    // since `paragraph` tried that first, and handing its only line back
    // would parse it again forever; the guard on `earlier` rules that out.
    [header, ..earlier], Ok(Nil) if earlier != [] -> #(
      Some(Paragraph(inlines(joined(earlier)))),
      [header, line, ..rest],
    )
    _, _ ->
      case continuation(classify(line, depth)) {
        Continues -> prose(rest, depth, [string.trim_start(line), ..text])
        Interrupts -> #(Some(Paragraph(inlines(joined(text)))), [line, ..rest])
      }
  }
}

// Whether `line` is a delimiter row for the most recent line of `text`.
fn heads_table(text: List(String), line: String) -> Result(Nil, Nil) {
  case text {
    [header, ..] ->
      case string.contains(header, "|"), alignments(line) {
        True, Ok(aligns) ->
          case list.length(aligns) == list.length(cells(header)) {
            True -> Ok(Nil)
            False -> Error(Nil)
          }
        _, _ -> Error(Nil)
      }
    [] -> Error(Nil)
  }
}

// An ordered item interrupts a paragraph only when it starts at one, and an
// empty item never does, so a sentence that happens to open with "2024." is
// still a sentence.
fn continuation(kind: Line) -> Continuation {
  case kind {
    TextLine(..) -> Continues
    ItemLine(item: Item(content: "", ..)) -> Continues
    ItemLine(item: Item(marker: Ordinal(number:, ..), ..)) if number != 1 ->
      Continues
    BlankLine
    | FenceLine(..)
    | HeadingLine(..)
    | RuleLine
    | QuoteLine(..)
    | ItemLine(..) -> Interrupts
  }
}

fn joined(text: List(String)) -> String {
  text
  |> list.reverse
  |> string.join("\n")
  |> string.trim_end
}

fn setext(line: String) -> Result(Level, Nil) {
  let #(indent, rest) = indentation(line, 0)
  let rest = string.trim_end(rest)
  case indent < 4, rest {
    True, "=" <> _ -> underline(rest, "=", H1)
    True, "-" <> _ -> underline(rest, "-", H2)
    _, _ -> Error(Nil)
  }
}

fn underline(rest: String, mark: String, level: Level) -> Result(Level, Nil) {
  case run(rest, mark, 0) {
    #(_, "") -> Ok(level)
    _ -> Error(Nil)
  }
}

// ---------------------------------------------------------------- tables

// A table is a header line holding a `|`, then a delimiter row with the same
// number of cells, then every following non-blank line that holds a `|`.
fn table(
  line: String,
  rest: List(String),
) -> Result(#(Block, List(String)), Nil) {
  case string.contains(line, "|"), rest {
    True, [delimiter, ..body] -> {
      let header = cells(line)
      use aligns <- result.try(alignments(delimiter))
      case list.length(aligns) == list.length(header) {
        True -> {
          let #(rows, rest) = table_rows(body, aligns, [])
          Ok(#(Table(header: row(aligns, header), rows:), rest))
        }
        False -> Error(Nil)
      }
    }
    _, _ -> Error(Nil)
  }
}

fn table_rows(
  lines: List(String),
  aligns: List(Align),
  rows: List(List(Cell)),
) -> #(List(List(Cell)), List(String)) {
  case lines {
    [line, ..rest] ->
      case !is_blank(line) && string.contains(line, "|") {
        True -> table_rows(rest, aligns, [row(aligns, cells(line)), ..rows])
        False -> #(list.reverse(rows), lines)
      }
    [] -> #(list.reverse(rows), [])
  }
}

// A row is cut or padded to the header's width, as GitHub does.
fn row(aligns: List(Align), texts: List(String)) -> List(Cell) {
  case aligns, texts {
    [], _ -> []
    [align, ..aligns], [text, ..texts] -> [
      Cell(align:, inlines: inlines(text)),
      ..row(aligns, texts)
    ]
    [align, ..aligns], [] -> [Cell(align:, inlines: []), ..row(aligns, [])]
  }
}

fn alignments(line: String) -> Result(List(Align), Nil) {
  case string.contains(line, "-") {
    True -> list.try_map(cells(line), align_of)
    False -> Error(Nil)
  }
}

fn align_of(cell: String) -> Result(Align, Nil) {
  let left = string.starts_with(cell, ":")
  let right = string.ends_with(cell, ":")
  let dashes = case run(string.replace(cell, ":", ""), "-", 0) {
    #(count, "") if count > 0 -> Ok(Nil)
    _ -> Error(Nil)
  }
  use Nil <- result.try(dashes)
  case left, right {
    True, True -> Ok(Center)
    True, False -> Ok(Left)
    False, True -> Ok(Right)
    False, False -> Ok(Unaligned)
  }
}

// A row's cells: the outer pipes dropped, split on every pipe a backslash
// does not escape, each cell trimmed. An escaped pipe becomes a plain one.
fn cells(line: String) -> List(String) {
  let trimmed = string.trim(line)
  let trimmed = case trimmed {
    "|" <> rest -> rest
    _ -> trimmed
  }
  let trimmed = case
    string.ends_with(trimmed, "|") && !string.ends_with(trimmed, "\\|")
  {
    True -> string.drop_end(trimmed, 1)
    False -> trimmed
  }
  split_cells(string.to_graphemes(trimmed), [], [])
}

fn split_cells(
  input: List(String),
  cell: List(String),
  done: List(String),
) -> List(String) {
  case input {
    [] -> list.reverse([finish_cell(cell), ..done])
    ["\\", "|", ..rest] -> split_cells(rest, ["|", ..cell], done)
    ["|", ..rest] -> split_cells(rest, [], [finish_cell(cell), ..done])
    [grapheme, ..rest] -> split_cells(rest, [grapheme, ..cell], done)
  }
}

fn finish_cell(cell: List(String)) -> String {
  cell |> list.reverse |> string.concat |> string.trim
}

// ---------------------------------------------------------------- inlines

// An emphasis delimiter that is waiting for its closer.
type Delim {
  StarOne
  StarTwo
  UnderOne
  UnderTwo
  Tilde
}

// What an open bracket becomes when its `](destination)` arrives.
type Target {
  ToLink
  ToImage
}

// What opened a frame of the inline stack. `epoch` is how many links had
// been formed when a bracket opened: a link bracket opened before the most
// recent link is inactive, which is how a link is kept out of a link.
type Opener {
  Root
  Delimited(delim: Delim)
  Bracket(target: Target, epoch: Int)
}

// One open construct and what has been read inside it, most recent first.
type Frame {
  Frame(opener: Opener, pieces: List(Piece))
}

// A frame's contents. A frame that never closes is spliced into its parent
// as one `Spliced` piece behind its opener's text, which costs nothing
// however much it holds; the pieces are flattened into inlines once, when
// the construct around them closes or the input ends. Moving the contents
// instead would copy them once per enclosing frame, which is quadratic in a
// run of unclosed brackets.
type Piece {
  Chars(reversed: List(String))
  Literal(text: String)
  Node(inline: Inline)
  Spliced(pieces: List(Piece))
}

// Whether a delimiter run may open or close emphasis where it stands.
type Ability {
  Able
  Unable
}

// What sits on one side of a delimiter run, which is all the flanking rules
// look at.
type Neighbour {
  Space
  Punctuation
  Word
}

type Scan {
  Scan(
    frame: Frame,
    below: List(Frame),
    pending: List(String),
    open: Dict(Delim, Int),
    delims: Int,
    brackets: Int,
    epoch: Int,
    ticks: Dict(Int, List(Int)),
    unclosed: Int,
  )
}

// Inline parsing is one pass over the graphemes with a stack of open frames.
// Code spans are matched through `ticks`, the positions of every backtick
// run by length, found in a first pass: an opener takes the next run of its
// length after it, and positions already passed are dropped, so each is
// looked at once.
fn inlines(text: String) -> List(Inline) {
  let graphemes = string.to_graphemes(text)
  let start =
    Scan(
      frame: Frame(opener: Root, pieces: []),
      below: [],
      pending: [],
      open: dict.new(),
      delims: 0,
      brackets: 0,
      epoch: 0,
      ticks: tick_runs(graphemes, 0, dict.new()),
      unclosed: 0,
    )
  scan(graphemes, 0, "", start)
}

fn tick_runs(
  input: List(String),
  position: Int,
  found: Dict(Int, List(Int)),
) -> Dict(Int, List(Int)) {
  case input {
    [] -> dict.map_values(found, fn(_, positions) { list.reverse(positions) })
    ["`", ..] -> {
      let #(length, rest) = count_run(input, "`", 0)
      let found =
        dict.upsert(found, length, fn(existing) {
          [position, ..option.unwrap(existing, [])]
        })
      tick_runs(rest, position + length, found)
    }
    [_, ..rest] -> tick_runs(rest, position + 1, found)
  }
}

fn count_run(
  input: List(String),
  mark: String,
  count: Int,
) -> #(Int, List(String)) {
  case input {
    [grapheme, ..rest] if grapheme == mark -> count_run(rest, mark, count + 1)
    _ -> #(count, input)
  }
}

// `position` counts graphemes from the start of the text and `previous` is
// the grapheme before `input`, which the flanking rules read.
fn scan(
  input: List(String),
  position: Int,
  previous: String,
  state: Scan,
) -> List(Inline) {
  case input {
    [] -> finish(state)
    ["\\", next, ..rest] -> escaped(next, rest, position, state)
    ["`", ..] -> code_span(input, position, state)
    ["*", ..] -> delimiter_run(input, "*", position, previous, state)
    ["_", ..] -> delimiter_run(input, "_", position, previous, state)
    ["~", ..] -> delimiter_run(input, "~", position, previous, state)
    ["!", "[", ..rest] ->
      scan(
        rest,
        position + 2,
        "[",
        open_frame(state, Bracket(ToImage, state.epoch)),
      )
    ["[", ..rest] ->
      scan(
        rest,
        position + 1,
        "[",
        open_frame(state, Bracket(ToLink, state.epoch)),
      )
    ["]", ..rest] -> close_bracket(rest, position, state)
    ["<", ..rest] -> autolink(rest, position, state)
    ["\n", ..rest] -> scan(rest, position + 1, "\n", line_break(state))
    [grapheme, ..rest] ->
      scan(
        rest,
        position + 1,
        grapheme,
        Scan(..state, pending: [grapheme, ..state.pending]),
      )
  }
}

// A backslash before ASCII punctuation makes it text, and before a line
// break makes the break hard. Before anything else it is itself text.
fn escaped(
  next: String,
  rest: List(String),
  position: Int,
  state: Scan,
) -> List(Inline) {
  case next, is_punctuation(next) {
    "\n", _ -> scan(rest, position + 2, "\n", push_node(state, Break))
    _, True ->
      scan(
        rest,
        position + 2,
        next,
        Scan(..state, pending: [next, ..state.pending]),
      )
    _, False ->
      scan(
        [next, ..rest],
        position + 1,
        "\\",
        Scan(..state, pending: ["\\", ..state.pending]),
      )
  }
}

fn is_punctuation(grapheme: String) -> Bool {
  string.contains("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~", grapheme)
}

fn code_span(input: List(String), position: Int, state: Scan) -> List(Inline) {
  let #(length, after) = count_run(input, "`", 0)
  case closer(state.ticks, length, position + length) {
    Ok(#(at, ticks)) -> {
      let #(content, rest) = list.split(after, at - position - length)
      let state = Scan(..state, ticks:)
      scan(
        list.drop(rest, length),
        at + length,
        "`",
        push_node(state, Code(code_text(content))),
      )
    }
    Error(ticks) -> {
      let pending = list.append(list.repeat("`", length), state.pending)
      scan(after, position + length, "`", Scan(..state, ticks:, pending:))
    }
  }
}

fn closer(
  ticks: Dict(Int, List(Int)),
  length: Int,
  from: Int,
) -> Result(#(Int, Dict(Int, List(Int))), Dict(Int, List(Int))) {
  let later =
    dict.get(ticks, length)
    |> result.unwrap([])
    |> list.drop_while(fn(at) { at < from })
  case later {
    [at, ..rest] -> Ok(#(at, dict.insert(ticks, length, rest)))
    [] -> Error(dict.insert(ticks, length, []))
  }
}

// Line endings in a code span are spaces, and one space is stripped from
// each end when both have one, so `` ` `` ` `` can show a backtick.
fn code_text(content: List(String)) -> String {
  let text = content |> string.concat |> string.replace("\n", " ")
  case
    string.starts_with(text, " ")
    && string.ends_with(text, " ")
    && string.trim(text) != ""
  {
    True -> text |> string.drop_start(1) |> string.drop_end(1)
    False -> text
  }
}

fn delimiter_run(
  input: List(String),
  mark: String,
  position: Int,
  previous: String,
  state: Scan,
) -> List(Inline) {
  let #(length, after) = count_run(input, mark, 0)
  let next = case after {
    [grapheme, ..] -> grapheme
    [] -> ""
  }
  let before = neighbour(previous)
  let beyond = neighbour(next)
  let can_open = opens(mark, before, beyond)
  let can_close = closes(mark, before, beyond)
  let state = case delims_of(mark, length, can_close) {
    Ok(delims) ->
      list.fold(delims, state, fn(state, delim) {
        delimiter(state, delim, can_open, can_close)
      })
    Error(Nil) ->
      Scan(
        ..state,
        pending: list.append(list.repeat(mark, length), state.pending),
      )
  }
  scan(after, position + length, mark, state)
}

// The delimiters a run stands for. A run of three is emphasis and strong
// emphasis together, opened in that order and closed in the other; longer
// runs, and a lone or tripled tilde, are text.
fn delims_of(
  mark: String,
  length: Int,
  closes: Ability,
) -> Result(List(Delim), Nil) {
  case mark, length, closes {
    "*", 1, _ -> Ok([StarOne])
    "*", 2, _ -> Ok([StarTwo])
    "*", 3, Able -> Ok([StarTwo, StarOne])
    "*", 3, Unable -> Ok([StarOne, StarTwo])
    "_", 1, _ -> Ok([UnderOne])
    "_", 2, _ -> Ok([UnderTwo])
    "_", 3, Able -> Ok([UnderTwo, UnderOne])
    "_", 3, Unable -> Ok([UnderOne, UnderTwo])
    "~", 2, _ -> Ok([Tilde])
    _, _, _ -> Error(Nil)
  }
}

fn neighbour(grapheme: String) -> Neighbour {
  case grapheme {
    "" | " " | "\n" | "\t" -> Space
    _ ->
      case is_punctuation(grapheme) {
        True -> Punctuation
        False -> Word
      }
  }
}

// A run opens when text follows it and closes when text precedes it. An
// underscore also refuses to open after a word character or close before
// one, so `snake_case_name` stays one word.
fn opens(mark: String, before: Neighbour, after: Neighbour) -> Ability {
  case after, before, mark {
    Space, _, _ -> Unable
    _, Word, "_" -> Unable
    _, _, _ -> Able
  }
}

fn closes(mark: String, before: Neighbour, after: Neighbour) -> Ability {
  case before, after, mark {
    Space, _, _ -> Unable
    _, Word, "_" -> Unable
    _, _, _ -> Able
  }
}

fn delimiter(
  state: Scan,
  delim: Delim,
  opens: Ability,
  closes: Ability,
) -> Scan {
  let waiting = dict.get(state.open, delim) |> result.unwrap(0)
  case closes, waiting > 0, opens, state.delims < max_emphasis {
    Able, True, _, _ -> close_delim(state, delim)
    _, _, Able, True -> open_frame(state, Delimited(delim))
    _, _, _, _ ->
      Scan(..state, pending: prepend_text(delim_text(delim), state.pending))
  }
}

fn delim_text(delim: Delim) -> String {
  case delim {
    StarOne -> "*"
    StarTwo -> "**"
    UnderOne -> "_"
    UnderTwo -> "__"
    Tilde -> "~~"
  }
}

fn opener_text(opener: Opener) -> String {
  case opener {
    Root -> ""
    Delimited(delim:) -> delim_text(delim)
    Bracket(target: ToLink, ..) -> "["
    Bracket(target: ToImage, ..) -> "!["
  }
}

fn prepend_text(text: String, pending: List(String)) -> List(String) {
  list.append(list.reverse(string.to_graphemes(text)), pending)
}

// Closing emphasis ends every construct opened inside it: each is spliced
// back into its parent as text behind its opener, then the emphasis itself
// becomes a node.
fn close_delim(state: Scan, delim: Delim) -> Scan {
  state
  |> flush
  |> dissolve_until(Delimited(delim))
  |> close_frame(fn(children) { wrap(delim, children) })
}

fn wrap(delim: Delim, children: List(Inline)) -> Inline {
  case delim {
    StarOne | UnderOne -> Emphasis(children:)
    StarTwo | UnderTwo -> Strong(children:)
    Tilde -> Strikethrough(children:)
  }
}

fn open_frame(state: Scan, opener: Opener) -> Scan {
  let state = flush(state)
  Scan(..state, frame: Frame(opener:, pieces: []), below: [
    state.frame,
    ..state.below
  ])
  |> counted(opener, 1)
}

fn counted(state: Scan, opener: Opener, change: Int) -> Scan {
  case opener {
    Root -> state
    Delimited(delim:) ->
      Scan(
        ..state,
        delims: state.delims + change,
        open: dict.upsert(state.open, delim, fn(count) {
          option.unwrap(count, 0) + change
        }),
      )
    Bracket(..) -> Scan(..state, brackets: state.brackets + change)
  }
}

fn flush(state: Scan) -> Scan {
  case state.pending {
    [] -> state
    pending -> {
      let frame =
        Frame(..state.frame, pieces: [Chars(pending), ..state.frame.pieces])
      Scan(..state, frame:, pending: [])
    }
  }
}

fn push_node(state: Scan, inline: Inline) -> Scan {
  let state = flush(state)
  let frame = Frame(..state.frame, pieces: [Node(inline), ..state.frame.pieces])
  Scan(..state, frame:)
}

// The top frame, unclosed, becomes text in its parent: its opener's text,
// then everything read inside it. The root has no parent and stays.
fn dissolve(state: Scan) -> Scan {
  case state.below {
    [] -> state
    [parent, ..below] -> {
      let Frame(opener:, pieces:) = state.frame
      let pieces = [
        Spliced(pieces),
        Literal(opener_text(opener)),
        ..parent.pieces
      ]
      Scan(..state, frame: Frame(..parent, pieces:), below:)
      |> counted(opener, -1)
    }
  }
}

fn dissolve_until(state: Scan, target: Opener) -> Scan {
  case state.frame.opener == target || state.below == [] {
    True -> state
    False -> dissolve_until(dissolve(state), target)
  }
}

fn dissolve_to_bracket(state: Scan) -> Scan {
  case state.frame.opener, state.below {
    Bracket(..), _ | _, [] -> state
    _, _ -> dissolve_to_bracket(dissolve(state))
  }
}

// The top frame, closed, becomes one node in its parent.
fn close_frame(state: Scan, build: fn(List(Inline)) -> Inline) -> Scan {
  case state.below {
    [] -> state
    [parent, ..below] -> {
      let Frame(opener:, pieces:) = state.frame
      let node = Node(build(flatten(pieces)))
      Scan(
        ..state,
        frame: Frame(..parent, pieces: [node, ..parent.pieces]),
        below:,
      )
      |> counted(opener, -1)
    }
  }
}

fn close_bracket(
  rest: List(String),
  position: Int,
  state: Scan,
) -> List(Inline) {
  case state.brackets > 0 {
    True ->
      bracket_closes(rest, position, state |> flush |> dissolve_to_bracket)
    False ->
      scan(
        rest,
        position + 1,
        "]",
        Scan(..state, pending: ["]", ..state.pending]),
      )
  }
}

// The top frame is the nearest open bracket. It becomes a link or an image
// when a destination follows and, for a link, when no link has formed since
// it opened. Otherwise it is text, and so is the `]`.
fn bracket_closes(
  rest: List(String),
  position: Int,
  state: Scan,
) -> List(Inline) {
  let active = case state.frame.opener {
    Bracket(target: ToLink, epoch:) -> epoch == state.epoch
    Bracket(target: ToImage, ..) -> True
    Root | Delimited(..) -> False
  }
  let found = case active {
    True -> destination(rest, position + 2, state.unclosed)
    False -> Error(state.unclosed)
  }
  case found {
    Ok(#(target, after, next)) -> scan(after, next, ")", linked(state, target))
    Error(unclosed) -> {
      let state = dissolve(Scan(..state, unclosed:))
      scan(
        rest,
        position + 1,
        "]",
        Scan(..state, pending: ["]", ..state.pending]),
      )
    }
  }
}

fn linked(state: Scan, target: String) -> Scan {
  case state.frame.opener {
    Bracket(target: ToImage, ..) ->
      close_frame(state, fn(children) {
        Image(alt: plain(children), destination: target)
      })
    Bracket(target: ToLink, ..) | Root | Delimited(..) -> {
      let state =
        close_frame(state, fn(children) {
          Link(label: children, destination: target)
        })
      Scan(..state, epoch: state.epoch + 1)
    }
  }
}

// A link's destination: `(` directly after the `]`, then everything up to
// the `)` that balances it, with no whitespace. Balanced parentheses inside
// are kept, so `javascript:alert(1)` and a Wikipedia title arrive whole.
// `start` is where the destination would begin.
//
// A scan that fails has reached a whitespace or the end at `unclosed`, and a
// later scan that starts before that point reads the same characters up to
// it, so it is refused without looking. That is what keeps a run of `](`
// from rescanning the same text once per bracket. The refusal is not always
// what CommonMark would do: when a failed scan ran through a later `](`, as
// in `[a]([b](c) d)`, that later link could have closed at a `)` the first
// scan counted as an inner one or passed on its way to the whitespace, and
// it is drawn as text instead. That costs a link, never the time bound.
fn destination(
  rest: List(String),
  start: Int,
  unclosed: Int,
) -> Result(#(String, List(String), Int), Int) {
  case rest {
    ["(", ..after] if start >= unclosed -> destination_text(after, start, 0, [])
    _ -> Error(unclosed)
  }
}

fn destination_text(
  input: List(String),
  position: Int,
  depth: Int,
  text: List(String),
) -> Result(#(String, List(String), Int), Int) {
  case input, depth {
    [")", ..rest], 0 ->
      Ok(#(text |> list.reverse |> string.concat, rest, position + 1))
    [")", ..rest], _ ->
      destination_text(rest, position + 1, depth - 1, [")", ..text])
    ["(", ..rest], _ ->
      destination_text(rest, position + 1, depth + 1, ["(", ..text])
    [], _ -> Error(position)
    [grapheme, ..rest], _ ->
      case neighbour(grapheme) {
        Space -> Error(position)
        Punctuation | Word ->
          destination_text(rest, position + 1, depth, [grapheme, ..text])
      }
  }
}

// `<scheme:rest>` is a link whose label is its destination. The scan stops
// at the first whitespace, `<` or `>`, so two scans never cover the same
// text, and anything that is not an absolute URI, an HTML tag above all,
// stays text.
fn autolink(rest: List(String), position: Int, state: Scan) -> List(Inline) {
  case angle(rest, []) {
    Ok(#(uri, after, used)) ->
      case is_uri(uri) {
        True ->
          scan(
            after,
            position + used + 2,
            ">",
            push_node(state, Link([Text(uri)], uri)),
          )
        False ->
          scan(
            rest,
            position + 1,
            "<",
            Scan(..state, pending: ["<", ..state.pending]),
          )
      }
    Error(Nil) ->
      scan(
        rest,
        position + 1,
        "<",
        Scan(..state, pending: ["<", ..state.pending]),
      )
  }
}

fn angle(
  input: List(String),
  text: List(String),
) -> Result(#(String, List(String), Int), Nil) {
  case input {
    [">", ..rest] ->
      Ok(#(text |> list.reverse |> string.concat, rest, list.length(text)))
    ["<", ..] | [] -> Error(Nil)
    [grapheme, ..rest] ->
      case neighbour(grapheme) {
        Space -> Error(Nil)
        Punctuation | Word -> angle(rest, [grapheme, ..text])
      }
  }
}

fn is_uri(text: String) -> Bool {
  case string.split_once(text, ":") {
    Ok(#(scheme, rest)) -> is_scheme(scheme) && rest != ""
    Error(Nil) -> False
  }
}

fn is_scheme(scheme: String) -> Bool {
  let length = string.length(scheme)
  length >= 2
  && length <= 32
  && list.all(string.to_graphemes(scheme), fn(grapheme) {
    string.contains(
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+.-",
      grapheme,
    )
  })
}

// A line ending inside a paragraph is a space, unless two spaces end the
// line, which makes it a hard break. The spaces themselves are dropped.
fn line_break(state: Scan) -> Scan {
  let #(spaces, pending) = list.split_while(state.pending, fn(g) { g == " " })
  case spaces {
    [_, _, ..] -> push_node(Scan(..state, pending:), Break)
    _ -> Scan(..state, pending: [" ", ..pending])
  }
}

fn finish(state: Scan) -> List(Inline) {
  let state = state |> flush |> dissolve_until(Root)
  flatten(state.frame.pieces)
}

// Pieces are stored most recent first, so the walk starts from the end of
// the text and prepends. Runs of text are gathered as segments and joined
// once, where a node or the start of the text ends them.
fn flatten(pieces: List(Piece)) -> List(Inline) {
  let #(texts, out) = gather(pieces, [], [])
  emit(texts, out)
}

fn gather(
  pieces: List(Piece),
  texts: List(String),
  out: List(Inline),
) -> #(List(String), List(Inline)) {
  case pieces {
    [] -> #(texts, out)
    [piece, ..rest] -> {
      let #(texts, out) = gather_piece(piece, texts, out)
      gather(rest, texts, out)
    }
  }
}

fn gather_piece(
  piece: Piece,
  texts: List(String),
  out: List(Inline),
) -> #(List(String), List(Inline)) {
  case piece {
    Chars(reversed:) -> #([string.concat(list.reverse(reversed)), ..texts], out)
    Literal(text:) -> #([text, ..texts], out)
    Node(inline:) -> #([], [inline, ..emit(texts, out)])
    Spliced(pieces:) -> gather(pieces, texts, out)
  }
}

fn emit(texts: List(String), out: List(Inline)) -> List(Inline) {
  case string.concat(texts) {
    "" -> out
    text -> [Text(text), ..out]
  }
}
