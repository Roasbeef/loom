//// Markdown as a closed tree, which both hosts draw: the terminal as styled
//// rows (`tui/markdown`) and the web view as elements
//// (`web_view/markdown_view`).
////
//// The web view may only put session text into the page as text nodes
//// (protocol-change/051, "Nothing from the session becomes markup"). So the
//// model's Markdown is parsed here, into `Block` and `Inline` values whose
//// every string is text to be shown, and each host maps each variant to its
//// own output. No variant carries HTML: a tag in the source is ordinary
//// text, and a link keeps its destination as a string. The terminal hands
//// that string to the terminal as a hyperlink; the web view prints it.
////
//// The parser is Loom's own and deliberately small. Both hosts used to be
//// able to reach mork, a full CommonMark parser, but mork's link parsing
//// backtracks: a run of unclosed `[` takes time exponential in its length
//// (twenty of them took most of a second, thirty would take minutes), and a
//// model can emit that run. The terminal re-renders a live answer on every
//// delta, so such an answer hung it. Neither a page nor a terminal may stall
//// on its own transcript, so this parser is written to a budget instead of
//// to the whole specification. Every step consumes input or finishes a
//// construct, and every scan that looks ahead is arranged so that no
//// character is scanned more than a fixed number of times. The work is
//// linear in the length of the text.
////
//// Nesting is bounded as well. Block containers, quotes, list items and
//// footnote definitions, stop being recognised `max_depth` levels down,
//// where their markers become paragraph text, so a thousand `>` produce
//// eight quotes and the text of the rest. Emphasis stops opening at
//// `max_emphasis` open delimiters, and a link cannot contain a link, so the
//// inline tree is shallow too. A host that recurses over the result recurses
//// a bounded number of levels.
////
//// What it recognises: ATX and setext headings, paragraphs, fenced and
//// indented code, block quotes and GitHub alerts, bullet and ordered lists
//// with task boxes, thematic breaks, GitHub pipe tables, code spans,
//// emphasis, strong emphasis, strikethrough, links with or without a title,
//// reference links and their definitions, footnote references and their
//// definitions, images, autolinks in angle brackets and bare `http://`,
//// `https://` and `www.` links, backslash escapes and hard breaks. What it
//// leaves as text: HTML, entity references, emoji shortcodes and inline
//// footnotes (`^[...]`).
////
//// Reference links are the one construct whose meaning crosses blocks: a
//// label used in the first paragraph may be defined in the last. The
//// definitions are therefore collected first, in one pass over the lines
//// that builds a map from label to destination, and every later lookup is
//// one map access. A definition line whose label is in that map is dropped
//// from the output wherever it stands; any other line that merely looks
//// like one is paragraph text.

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string

/// One block of a Markdown document.
pub type Block {
  /// Running text.
  Paragraph(inlines: List(Inline))

  /// A heading, from `#` lines or from a setext underline. A trailing
  /// `{#id}` on a `#` heading is dropped, as the heading-id extension has it.
  Heading(level: Level, inlines: List(Inline))

  /// Preformatted source. `language` is the first word of a fence's info
  /// string, kept as text for a label and never as a class or attribute.
  CodeBlock(language: Option(String), text: String)

  /// A block quote and the blocks inside it.
  Quote(blocks: List(Block))

  /// A GitHub alert: a block quote whose first line is one of the five
  /// markers `[!NOTE]`, `[!TIP]`, `[!IMPORTANT]`, `[!WARNING]` and
  /// `[!CAUTION]`, in any case. The marker is removed and `blocks` is the
  /// rest of the quote.
  Alert(kind: AlertKind, blocks: List(Block))

  /// An unordered list; each item is the blocks inside it.
  BulletList(items: List(List(Block)))

  /// An ordered list whose first item carries `start`; each item is the
  /// blocks inside it.
  OrderedList(start: Int, items: List(List(Block)))

  /// A pipe table. Every row has exactly as many cells as the header.
  Table(header: List(Cell), rows: List(List(Cell)))

  /// A footnote's definition, `[^label]: text`, drawn where it was written.
  /// `label` is the text between `[^` and `]`, and `blocks` is the text
  /// after the colon with the lines indented under it.
  Footnote(label: String, blocks: List(Block))

  /// A thematic break.
  Rule
}

/// Which of GitHub's five alerts a quote is.
pub type AlertKind {
  /// `[!NOTE]`.
  Note

  /// `[!TIP]`.
  Tip

  /// `[!IMPORTANT]`.
  Important

  /// `[!WARNING]`.
  Warning

  /// `[!CAUTION]`.
  Caution
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

  /// A task list item's box. It opens the first paragraph of the item whose
  /// first line began with `[ ] `, `[x] ` or `[X] `.
  Task(state: TaskState)

  /// A reference to a footnote, `[^label]`, whose definition appears
  /// somewhere in the same text. A reference to a label nothing defines is
  /// text.
  FootnoteRef(label: String)

  /// A hard line break.
  Break
}

/// Whether a task item's box is ticked.
pub type TaskState {
  /// `[ ]`.
  Open

  /// `[x]` or `[X]`.
  Done
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
  let lines =
    text
    |> string.replace("\r\n", "\n")
    |> string.replace("\r", "\n")
    |> string.split("\n")
    |> list.map(expand_leading_tabs)
  blocks(lines, Context(depth: 0, refs: definitions(lines)))
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
    Task(..) -> ""
    FootnoteRef(label:) -> "[" <> label <> "]"
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

// What block parsing carries into every container: how many containers deep
// it is, and the definitions the first pass collected, which inline parsing
// resolves references against.
type Context {
  Context(depth: Int, refs: Refs)
}

// The labels the text defines. `links` maps a normalized link label to its
// destination, the first definition of a label winning, and `notes` holds
// every footnote label.
type Refs {
  Refs(links: Dict(String, String), notes: Set(String))
}

fn deeper(context: Context) -> Context {
  Context(..context, depth: context.depth + 1)
}

// What one line can start, decided from the line alone. The block loop reads
// a line's kind and then consumes as many following lines as that block owns.
type Line {
  BlankLine
  FenceLine(indent: Int, mark: String, length: Int, info: String)
  HeadingLine(level: Level, text: String)
  RuleLine
  QuoteLine(content: String)
  ItemLine(item: Item)

  // A link reference definition for a label the first pass collected. It
  // draws nothing.
  DefinitionLine

  // The first line of a footnote definition: its label and the text after
  // the colon.
  NoteLine(label: String, content: String)

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

fn blocks(lines: List(String), context: Context) -> List(Block) {
  collect(lines, context, [])
}

fn collect(
  lines: List(String),
  context: Context,
  done: List(Block),
) -> List(Block) {
  case lines {
    [] -> list.reverse(done)
    [line, ..rest] -> {
      let #(block, rest) =
        next_block(classify(line, context), line, rest, context)
      case block {
        Some(block) -> collect(rest, context, [block, ..done])
        None -> collect(rest, context, done)
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
  context: Context,
) -> #(Option(Block), List(String)) {
  case kind {
    BlankLine | DefinitionLine -> #(None, rest)

    // An unclosed fence runs to the end of the lines it was given, which
    // for a quote or a list item is the end of that container and for a
    // transcript row is the end of the row. It never reaches a later row.
    FenceLine(indent:, mark:, length:, info:) -> {
      let #(body, rest) = fence_body(rest, indent, mark, length, [])
      #(Some(CodeBlock(language(info), string.join(body, "\n"))), rest)
    }

    HeadingLine(level:, text:) -> #(
      Some(Heading(level, inlines(text, context.refs))),
      rest,
    )
    RuleLine -> #(Some(Rule), rest)

    // A container's lines are gathered with their markers removed and
    // parsed again one level down, where `classify` stops recognising
    // containers once `max_depth` is reached.
    QuoteLine(content:) -> {
      let #(inner, rest) = quoted(rest, [content], context)
      #(Some(quote_block(inner, deeper(context))), rest)
    }

    ItemLine(item:) -> {
      let #(items, rest) = list_items(item, rest, context, [])
      #(Some(list_block(item.marker, items)), rest)
    }

    // A footnote definition owns the lines indented under it, as a list
    // item four columns wide would.
    NoteLine(label:, content:) -> {
      let #(body, rest) = item_body(rest, 4, context, [content])
      #(Some(Footnote(label, blocks(body, deeper(context)))), rest)
    }

    TextLine(indent:, ..) if indent >= 4 -> indented_code([line, ..rest], [])
    TextLine(..) -> paragraph(line, rest, context)
  }
}

fn classify(line: String, context: Context) -> Line {
  let #(indent, rest) = indentation(line, 0)
  case is_blank(rest), indent >= 4 {
    True, _ -> BlankLine
    False, True -> TextLine(indent:, text: rest)
    False, False -> block_line(indent, rest, context)
  }
}

fn block_line(indent: Int, rest: String, context: Context) -> Line {
  fence_line(indent, rest)
  |> result.lazy_or(fn() { heading_line(rest) })
  |> result.lazy_or(fn() { rule_line(rest) })
  |> result.lazy_or(fn() { quote_line(rest, context.depth) })
  |> result.lazy_or(fn() { item_line(indent, rest, context.depth) })
  |> result.lazy_or(fn() { definition_line(rest, context) })
  |> result.lazy_unwrap(fn() { TextLine(indent:, text: rest) })
}

// A definition is recognised only for a label the first pass collected, so
// the two passes agree on which lines are definitions. A line that looks
// like one but defines nothing, because it sits where the first pass does
// not read, stays text rather than vanishing. A footnote definition is a
// container, so past `max_depth` it is text as well.
fn definition_line(rest: String, context: Context) -> Result(Line, Nil) {
  // Most text defines nothing, and a line opening with a bracket is then
  // paragraph text without reading it as a definition.
  let notes = set.is_empty(context.refs.notes)
  let links = dict.is_empty(context.refs.links)
  case rest, notes, links {
    "[^" <> _, False, _ -> {
      use #(label, content) <- result.try(note_definition(rest))
      case
        context.depth < max_depth && set.contains(context.refs.notes, label)
      {
        True -> Ok(NoteLine(label:, content:))
        False -> Error(Nil)
      }
    }
    "[" <> _, _, False -> {
      use #(label, _) <- result.try(link_definition(rest))
      case dict.has_key(context.refs.links, label) {
        True -> Ok(DefinitionLine)
        False -> Error(Nil)
      }
    }
    _, _, _ -> Error(Nil)
  }
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
  indent < 4 && count >= length && is_blank(after)
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
  |> without_anchor
}

// `# Title {#anchor}` is "Title": the heading-id extension's anchor names
// the heading for a link and is not part of its text. An anchor holding
// whitespace is not one, and stays.
fn without_anchor(text: String) -> String {
  case string.ends_with(text, "}") {
    False -> text
    True ->
      case string.split_once(string.reverse(text), "#{") {
        Ok(#("}" <> anchor, before)) ->
          case anchor != "" && !string.contains(anchor, " ") {
            True -> string.trim_end(string.reverse(before))
            False -> text
          }
        Ok(_) | Error(Nil) -> text
      }
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

// The character classes below are ranges of ASCII, tested on the byte of a
// one-byte grapheme or token. Anything longer than one byte belongs to none
// of them. Reading the byte costs nothing, where testing containment in a
// string of the class's characters built a search pattern for every
// character the parser looked at, which was a measurable part of a frame.
fn ascii(grapheme: String) -> Int {
  case bit_array.from_string(grapheme) {
    <<byte>> -> byte
    _ -> -1
  }
}

fn is_digit(grapheme: String) -> Bool {
  let byte = ascii(grapheme)
  byte >= 0x30 && byte <= 0x39
}

// The lines of a quote after its first. A line carrying its own `>` stays
// in the quote. A line without one continues the quote lazily, as CommonMark
// has it, when it is paragraph text and so was the quote's last line: that
// line can only be the quoted paragraph going on. Anything else ends the
// quote. The test reads the quote's last line alone, so a paragraph line
// after a quoted fence's body joins the fence, where CommonMark would end
// the quote; models close their fences, and the cost is where one line is
// drawn.
fn quoted(
  lines: List(String),
  inner: List(String),
  context: Context,
) -> #(List(String), List(String)) {
  case lines {
    [] -> #(list.reverse(inner), [])
    [line, ..rest] -> {
      let #(indent, text) = indentation(line, 0)
      case indent < 4, quote_content(text) {
        True, Ok(content) -> quoted(rest, [content, ..inner], context)
        _, _ ->
          case lazy_quote(line, inner, context) {
            Continues -> quoted(rest, [line, ..inner], context)
            Interrupts -> #(list.reverse(inner), lines)
          }
      }
    }
  }
}

fn lazy_quote(
  line: String,
  inner: List(String),
  context: Context,
) -> Continuation {
  case inner, classify(line, context) {
    [previous, ..], TextLine(..) ->
      case classify(previous, deeper(context)) {
        TextLine(indent:, ..) if indent < 4 -> Continues
        _ -> Interrupts
      }
    _, _ -> Interrupts
  }
}

// A quote whose first line is an alert marker is that alert. Text after the
// marker on the same line opens the alert's body, and a marker alone on its
// line is dropped with its line.
fn quote_block(inner: List(String), context: Context) -> Block {
  case inner {
    [first, ..rest] ->
      case alert_marker(first) {
        Ok(#(kind, "")) -> Alert(kind, blocks(rest, context))
        Ok(#(kind, after)) -> Alert(kind, blocks([after, ..rest], context))
        Error(Nil) -> Quote(blocks(inner, context))
      }
    [] -> Quote([])
  }
}

fn alert_marker(line: String) -> Result(#(AlertKind, String), Nil) {
  let #(indent, rest) = indentation(line, 0)
  use #(marker, after) <- result.try(case indent < 4, rest {
    True, "[!" <> tail -> string.split_once(tail, "]")
    _, _ -> Error(Nil)
  })
  use kind <- result.try(alert_kind(marker))
  Ok(#(kind, string.trim(after)))
}

fn alert_kind(marker: String) -> Result(AlertKind, Nil) {
  case string.lowercase(marker) {
    "note" -> Ok(Note)
    "tip" -> Ok(Tip)
    "important" -> Ok(Important)
    "warning" -> Ok(Warning)
    "caution" -> Ok(Caution)
    _ -> Error(Nil)
  }
}

fn list_items(
  item: Item,
  lines: List(String),
  context: Context,
  items: List(List(Block)),
) -> #(List(List(Block)), List(String)) {
  let #(state, content) = task(item.content)
  let #(body, rest) = item_body(lines, item.width, context, [content])
  let items = [ticked(blocks(body, deeper(context)), state), ..items]
  case rest {
    [] -> #(list.reverse(items), [])
    [line, ..more] ->
      case sibling(classify(line, context), item.marker) {
        Ok(next) -> list_items(next, more, context, items)
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

// A task item's box, taken off the item's first line so that the line
// parses as the text after it. The spaces after the box go with it: left on,
// four of them would make the rest an indented code block.
fn task(content: String) -> #(Option(TaskState), String) {
  case content {
    "[ ] " <> rest -> #(Some(Open), trim_start(rest))
    "[x] " <> rest | "[X] " <> rest -> #(Some(Done), trim_start(rest))
    _ -> #(None, content)
  }
}

// The box opens the item's first paragraph, or stands as a paragraph of its
// own when the item opens with something else.
fn ticked(blocks: List(Block), state: Option(TaskState)) -> List(Block) {
  case state, blocks {
    None, _ -> blocks
    Some(state), [Paragraph(inlines:), ..rest] -> [
      Paragraph([Task(state), ..inlines]),
      ..rest
    ]
    Some(state), _ -> [Paragraph([Task(state)]), ..blocks]
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
  context: Context,
  body: List(String),
) -> #(List(String), List(String)) {
  case lines {
    [] -> #(list.reverse(body), [])
    [line, ..rest] -> {
      let #(indent, text) = indentation(line, 0)
      case is_blank(text), indent >= width {
        True, _ -> after_blank(lines, width, context, body)
        False, True ->
          item_body(rest, width, context, [drop_spaces(line, width), ..body])
        False, False -> lazy_line(line, rest, width, context, body)
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
  context: Context,
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
            context,
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
  context: Context,
  body: List(String),
) -> #(List(String), List(String)) {
  let continues = case body, classify(line, context) {
    [previous, ..], TextLine(..) -> !is_blank(previous)
    _, _ -> False
  }
  case continues {
    True -> item_body(rest, width, context, [trim_start(line), ..body])
    False -> #(list.reverse(body), [line, ..rest])
  }
}

// Blank as CommonMark has it: nothing but spaces and tabs. These checks
// and the trims below read ASCII bytes rather than running a Unicode trim,
// which searched every line for every kind of whitespace and allocated as
// it went, on every line of every frame the terminal parses.
fn is_blank(line: String) -> Bool {
  blank_bytes(bit_array.from_string(line))
}

fn blank_bytes(bits: BitArray) -> Bool {
  case bits {
    <<>> -> True
    <<0x20, rest:bytes>> | <<0x09, rest:bytes>> -> blank_bytes(rest)
    _ -> False
  }
}

// The text without its leading spaces and tabs.
fn trim_start(text: String) -> String {
  case text {
    " " <> rest | "\t" <> rest -> trim_start(rest)
    _ -> text
  }
}

// The text without its trailing spaces, tabs and line feeds, read from the
// end, so the cost is what is trimmed rather than the text's length.
fn trim_end(text: String) -> String {
  let bits = bit_array.from_string(text)
  let size = bit_array.byte_size(bits)
  let kept = kept_bytes(bits, size)
  case kept == size {
    True -> text
    False ->
      bit_array.slice(bits, 0, kept)
      |> result.try(bit_array.to_string)
      |> result.unwrap(text)
  }
}

fn kept_bytes(bits: BitArray, size: Int) -> Int {
  case bit_array.slice(bits, size - 1, 1) {
    Ok(<<0x20>>) | Ok(<<0x09>>) | Ok(<<0x0A>>) -> kept_bytes(bits, size - 1)
    Ok(_) | Error(Nil) -> size
  }
}

fn trim(text: String) -> String {
  text |> trim_start |> trim_end
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
  context: Context,
) -> #(Option(Block), List(String)) {
  case table(line, rest, context.refs) {
    Ok(#(block, rest)) -> #(Some(block), rest)
    Error(Nil) -> prose(rest, context, [trim_start(line)])
  }
}

fn prose(
  lines: List(String),
  context: Context,
  text: List(String),
) -> #(Option(Block), List(String)) {
  case lines {
    [] -> #(Some(Paragraph(inlines(joined(text), context.refs))), [])
    [line, ..rest] ->
      case setext(line) {
        Ok(level) -> #(
          Some(Heading(level, inlines(joined(text), context.refs))),
          rest,
        )
        Error(Nil) -> prose_line(line, rest, context, text)
      }
  }
}

fn prose_line(
  line: String,
  rest: List(String),
  context: Context,
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
      Some(Paragraph(inlines(joined(earlier), context.refs))),
      [header, line, ..rest],
    )
    _, _ ->
      case continuation(classify(line, context)) {
        Continues -> prose(rest, context, [trim_start(line), ..text])
        Interrupts -> #(Some(Paragraph(inlines(joined(text), context.refs))), [
          line,
          ..rest
        ])
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
    | ItemLine(..)
    | DefinitionLine
    | NoteLine(..) -> Interrupts
  }
}

fn joined(text: List(String)) -> String {
  text
  |> list.reverse
  |> string.join("\n")
  |> trim_end
}

fn setext(line: String) -> Result(Level, Nil) {
  let #(indent, rest) = indentation(line, 0)
  let rest = trim_end(rest)
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
  refs: Refs,
) -> Result(#(Block, List(String)), Nil) {
  case string.contains(line, "|"), rest {
    True, [delimiter, ..body] -> {
      let header = cells(line)
      use aligns <- result.try(alignments(delimiter))
      case list.length(aligns) == list.length(header) {
        True -> {
          let #(rows, rest) = table_rows(body, aligns, refs, [])
          Ok(#(Table(header: row(aligns, header, refs), rows:), rest))
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
  refs: Refs,
  rows: List(List(Cell)),
) -> #(List(List(Cell)), List(String)) {
  case lines {
    [line, ..rest] ->
      case !is_blank(line) && string.contains(line, "|") {
        True ->
          table_rows(rest, aligns, refs, [
            row(aligns, cells(line), refs),
            ..rows
          ])
        False -> #(list.reverse(rows), lines)
      }
    [] -> #(list.reverse(rows), [])
  }
}

// A row is cut or padded to the header's width, as GitHub does.
fn row(aligns: List(Align), texts: List(String), refs: Refs) -> List(Cell) {
  case aligns, texts {
    [], _ -> []
    [align, ..aligns], [text, ..texts] -> [
      Cell(align:, inlines: inlines(text, refs)),
      ..row(aligns, texts, refs)
    ]
    [align, ..aligns], [] -> [
      Cell(align:, inlines: []),
      ..row(aligns, [], refs)
    ]
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
  let trimmed = trim(line)
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
  split_cells(tokens(trimmed), [], [])
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
  cell |> list.reverse |> string.concat |> trim
}

// ----------------------------------------------------------- definitions

// The longest label a reference or a definition may have, counted in tokens
// (in graphemes on a definition line), near the bound CommonMark sets. A label scan stops here whatever follows.
const max_label = 999

// Whether a label may hold whitespace: a link label may, a footnote label
// may not.
type Spacing {
  SpacesAllowed
  NoSpaces
}

// Whether the first pass is inside a fenced code block, and which fence
// closes it.
type Fencing {
  Unfenced
  Fenced(mark: String, length: Int)
}

// The first pass: every link reference definition and footnote definition
// in the text, read one line at a time. A quote's markers are stripped from
// a line before it is read, since a definition inside a quote defines its
// label for the whole text. Fenced code is skipped, since a definition
// written inside a fence is an example rather than a definition, and so is
// a line indented four or more columns, which is code. Each line is read
// once, so the pass is linear.
fn definitions(lines: List(String)) -> Refs {
  collect_definitions(
    lines,
    Unfenced,
    Refs(links: dict.new(), notes: set.new()),
  )
}

fn collect_definitions(
  lines: List(String),
  fencing: Fencing,
  refs: Refs,
) -> Refs {
  case lines {
    [] -> refs
    [line, ..rest] -> {
      let #(fencing, refs) = definition_step(unquoted(line), fencing, refs)
      collect_definitions(rest, fencing, refs)
    }
  }
}

fn definition_step(
  line: String,
  fencing: Fencing,
  refs: Refs,
) -> #(Fencing, Refs) {
  let #(indent, rest) = indentation(line, 0)
  case fencing {
    Fenced(mark:, length:) ->
      case closes_fence(line, mark, length) {
        True -> #(Unfenced, refs)
        False -> #(fencing, refs)
      }
    Unfenced if indent >= 4 -> #(Unfenced, refs)
    Unfenced ->
      case fence_line(indent, rest) {
        Ok(FenceLine(mark:, length:, ..)) -> #(Fenced(mark:, length:), refs)
        _ -> #(Unfenced, define(rest, refs))
      }
  }
}

// A line with every leading quote marker removed.
fn unquoted(line: String) -> String {
  let #(indent, rest) = indentation(line, 0)
  case indent < 4, quote_content(rest) {
    True, Ok(content) -> unquoted(content)
    _, _ -> line
  }
}

// A definition's label is closed by `]:`, so a line opening with a bracket
// but holding no such pair is passed over before it is read grapheme by
// grapheme.
fn define(rest: String, refs: Refs) -> Refs {
  case rest {
    "[" <> _ ->
      case string.contains(rest, "]:") {
        True -> defined(rest, refs)
        False -> refs
      }
    _ -> refs
  }
}

fn defined(rest: String, refs: Refs) -> Refs {
  case rest {
    "[^" <> _ ->
      case note_definition(rest) {
        Ok(#(label, _)) -> Refs(..refs, notes: set.insert(refs.notes, label))
        Error(Nil) -> refs
      }
    _ ->
      case link_definition(rest) {
        Ok(#(label, destination)) ->
          case dict.has_key(refs.links, label) {
            True -> refs
            False ->
              Refs(..refs, links: dict.insert(refs.links, label, destination))
          }
        Error(Nil) -> refs
      }
  }
}

// `[^label]: text`: the label and the text after the colon.
fn note_definition(rest: String) -> Result(#(String, String), Nil) {
  case string.to_graphemes(rest) {
    ["[", "^", ..tail] -> {
      use #(label, after, _) <- result.try(label_text(tail, NoSpaces, [], 0))
      case after {
        [":", ..content] ->
          Ok(#(label, string.trim_start(string.concat(content))))
        _ -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

// `[label]: destination "title"`, on one line: the normalized label and the
// destination. The destination is a run with no whitespace, or anything but
// `<` and `>` between angle brackets. The title, in double quotes, single
// quotes or parentheses, is optional and is dropped; anything else after
// the destination means the line is not a definition.
fn link_definition(rest: String) -> Result(#(String, String), Nil) {
  case string.to_graphemes(rest) {
    ["[", ..tail] -> {
      use #(raw, after, _) <- result.try(label_text(tail, SpacesAllowed, [], 0))
      use label <- result.try(normalized(raw))
      case after {
        [":", ..after] -> {
          use destination <- result.try(definition_target(after))
          Ok(#(label, destination))
        }
        _ -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

fn definition_target(input: List(String)) -> Result(String, Nil) {
  let #(_, input) = list.split_while(input, is_space)
  let #(destination, after) = case input {
    ["<", ..rest] -> angled(rest, [])
    _ -> {
      let #(run, after) = list.split_while(input, fn(g) { !is_space(g) })
      #(Ok(string.concat(run)), after)
    }
  }
  use destination <- result.try(destination)
  case destination != "" && is_title(string.trim(string.concat(after))) {
    True -> Ok(destination)
    False -> Error(Nil)
  }
}

fn angled(
  input: List(String),
  text: List(String),
) -> #(Result(String, Nil), List(String)) {
  case input {
    [">", ..rest] -> #(Ok(text |> list.reverse |> string.concat), rest)
    ["<", ..] | [] -> #(Error(Nil), input)
    [grapheme, ..rest] -> angled(rest, [grapheme, ..text])
  }
}

fn is_title(text: String) -> Bool {
  case text {
    "" -> True
    "\"" <> body -> body != "" && string.ends_with(body, "\"")
    "'" <> body -> body != "" && string.ends_with(body, "'")
    "(" <> body -> body != "" && string.ends_with(body, ")")
    _ -> False
  }
}

fn is_space(grapheme: String) -> Bool {
  neighbour(grapheme) == Space
}

// A label's text: the tokens before the first unescaped `]`, which must
// come after at least one token and within `max_label`. A `[` refuses the
// label, as does whitespace in a footnote label. The result is the label,
// the input after its `]`, and how many tokens the label took. The scan
// stops at the first bracket, so two label scans never read the same text.
fn label_text(
  input: List(String),
  spacing: Spacing,
  label: List(String),
  count: Int,
) -> Result(#(String, List(String), Int), Nil) {
  case input, spacing {
    _, _ if count > max_label -> Error(Nil)
    ["]", ..rest], _ if count > 0 ->
      Ok(#(label |> list.reverse |> string.concat, rest, count))
    ["]", ..], _ | ["[", ..], _ | [], _ -> Error(Nil)
    ["\\", next, ..rest], _ if next == "[" || next == "]" ->
      label_text(rest, spacing, [next, "\\", ..label], count + 2)
    [grapheme, ..rest], NoSpaces ->
      case is_space(grapheme) {
        True -> Error(Nil)
        False -> label_text(rest, spacing, [grapheme, ..label], count + 1)
      }
    [grapheme, ..rest], SpacesAllowed ->
      label_text(rest, spacing, [grapheme, ..label], count + 1)
  }
}

// Labels match without regard to case or to how whitespace inside them was
// written. A label of only whitespace names nothing.
fn normalized(label: String) -> Result(String, Nil) {
  let words =
    label
    |> string.lowercase
    |> string.replace("\t", " ")
    |> string.replace("\n", " ")
    |> string.split(" ")
    |> list.filter(fn(word) { word != "" })
  case words {
    [] -> Error(Nil)
    _ -> Ok(string.join(words, " "))
  }
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
// `holds` records whether a bracket's frame has ended inside this one, which
// decides whether its text may be read as a reference label.
type Frame {
  Frame(opener: Opener, pieces: List(Piece), holds: Holds)
}

// Whether a frame holds a bracket, closed or not. CommonMark does not let a
// reference label hold one, and reading the text of a frame that holds none
// is what keeps shortcut references linear: frames with no bracket inside
// cover text no other such frame covers.
type Holds {
  Flat
  Nested
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
    refs: Refs,
  )
}

// Inline parsing reads the text as tokens rather than graphemes. Every ASCII
// punctuation byte, space, tab and line feed is a token of its own, and every
// run of other bytes, letters, digits and all non-ASCII text, is one token.
// The scanner only ever tests a token against ASCII punctuation and
// whitespace, and UTF-8 never places an ASCII byte inside a multi-byte
// character, so cutting at those bytes never splits a character, and each
// test reads the same for a token as it did for a grapheme. A run is a
// slice of the source rather than a copy, and the text needs no grapheme
// segmentation, which was most of what parsing a frame allocated.
// CommonMark is defined over characters rather than grapheme clusters, so a
// combining mark after a delimiter no longer hides the delimiter, which is
// the specification's reading. Positions count tokens, which every scan that
// reads a position does alike.
fn tokens(text: String) -> List(String) {
  let bits = bit_array.from_string(text)
  tokenize(bits, bits, 0, 0, [])
}

fn tokenize(
  source: BitArray,
  rest: BitArray,
  index: Int,
  start: Int,
  out: List(String),
) -> List(String) {
  case rest {
    <<byte, rest:bytes>> ->
      case ascii_token(byte) {
        Ok(token) ->
          tokenize(source, rest, index + 1, index + 1, [
            token,
            ..run_token(source, start, index, out)
          ])
        Error(Nil) -> tokenize(source, rest, index + 1, start, out)
      }
    _ -> list.reverse(run_token(source, start, index, out))
  }
}

// The run of ordinary bytes from `start` up to `index`, if there is one,
// ahead of `out`. A run ends at an ASCII byte, so it holds whole characters
// and the conversion back to a string cannot fail.
fn run_token(
  source: BitArray,
  start: Int,
  index: Int,
  out: List(String),
) -> List(String) {
  case index > start {
    False -> out
    True ->
      case
        bit_array.slice(source, start, index - start)
        |> result.try(bit_array.to_string)
      {
        Ok(text) -> [text, ..out]
        Error(Nil) -> out
      }
  }
}

// The token a byte stands for on its own, as a literal so that it costs no
// allocation, or an error for a byte that belongs to a run.
fn ascii_token(byte: Int) -> Result(String, Nil) {
  case byte {
    0x09 -> Ok("\t")
    0x0A -> Ok("\n")
    0x20 -> Ok(" ")
    0x21 -> Ok("!")
    0x22 -> Ok("\"")
    0x23 -> Ok("#")
    0x24 -> Ok("$")
    0x25 -> Ok("%")
    0x26 -> Ok("&")
    0x27 -> Ok("'")
    0x28 -> Ok("(")
    0x29 -> Ok(")")
    0x2A -> Ok("*")
    0x2B -> Ok("+")
    0x2C -> Ok(",")
    0x2D -> Ok("-")
    0x2E -> Ok(".")
    0x2F -> Ok("/")
    0x3A -> Ok(":")
    0x3B -> Ok(";")
    0x3C -> Ok("<")
    0x3D -> Ok("=")
    0x3E -> Ok(">")
    0x3F -> Ok("?")
    0x40 -> Ok("@")
    0x5B -> Ok("[")
    0x5C -> Ok("\\")
    0x5D -> Ok("]")
    0x5E -> Ok("^")
    0x5F -> Ok("_")
    0x60 -> Ok("`")
    0x7B -> Ok("{")
    0x7C -> Ok("|")
    0x7D -> Ok("}")
    0x7E -> Ok("~")
    _ -> Error(Nil)
  }
}

// Inline parsing is one pass over the tokens with a stack of open frames.
// Code spans are matched through `ticks`, the positions of every backtick
// run by length, found in a first pass: an opener takes the next run of its
// length after it, and positions already passed are dropped, so each is
// looked at once.
fn inlines(text: String, refs: Refs) -> List(Inline) {
  let graphemes = tokens(text)
  let start =
    Scan(
      frame: Frame(opener: Root, pieces: [], holds: Flat),
      below: [],
      pending: [],
      open: dict.new(),
      delims: 0,
      brackets: 0,
      epoch: 0,
      ticks: tick_runs(graphemes, 0, dict.new()),
      unclosed: 0,
      refs:,
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

// `position` counts tokens from the start of the text and `previous` is the
// token before `input`, which the flanking rules read.
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
    ["[", "^", ..rest] -> footnote_ref(rest, position, state)
    ["[", ..rest] -> open_link(rest, position, state)
    ["]", ..rest] -> close_bracket(rest, position, state)
    ["<", ..rest] -> autolink(rest, position, state)
    ["\n", ..rest] -> scan(rest, position + 1, "\n", line_break(state))
    ["https", ..] | ["http", ..] | ["www", ..] ->
      bare_link(input, position, previous, state)
    [grapheme, ..rest] -> read_text(grapheme, rest, position, state)
  }
}

// One token with no meaning of its own, added to the text being read.
fn read_text(
  grapheme: String,
  rest: List(String),
  position: Int,
  state: Scan,
) -> List(Inline) {
  scan(
    rest,
    position + 1,
    grapheme,
    Scan(..state, pending: [grapheme, ..state.pending]),
  )
}

// A `[` that may become a link, `rest` being what follows it.
fn open_link(rest: List(String), position: Int, state: Scan) -> List(Inline) {
  scan(rest, position + 1, "[", open_frame(state, Bracket(ToLink, state.epoch)))
}

// `[^label]` is a footnote reference when the text defines `label`, and
// otherwise a `[` like any other. The label scan stops at the first bracket
// or whitespace, so the text it reads is text no other label scan reads.
fn footnote_ref(
  rest: List(String),
  position: Int,
  state: Scan,
) -> List(Inline) {
  let found = case set.is_empty(state.refs.notes) {
    True -> Error(Nil)
    False -> {
      use found <- result.try(label_text(rest, NoSpaces, [], 0))
      case set.contains(state.refs.notes, found.0) {
        True -> Ok(found)
        False -> Error(Nil)
      }
    }
  }
  case found {
    Ok(#(label, after, used)) ->
      scan(
        after,
        position + used + 3,
        "]",
        push_node(state, FootnoteRef(label)),
      )
    Error(Nil) -> open_link(["^", ..rest], position, state)
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

// ASCII punctuation: `!` to `/`, `:` to `@`, `[` to the backtick, and `{`
// to `~`.
fn is_punctuation(grapheme: String) -> Bool {
  let byte = ascii(grapheme)
  { byte >= 0x21 && byte <= 0x2F }
  || { byte >= 0x3A && byte <= 0x40 }
  || { byte >= 0x5B && byte <= 0x60 }
  || { byte >= 0x7B && byte <= 0x7E }
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
  Scan(..state, frame: Frame(opener:, pieces: [], holds: Flat), below: [
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
      let Frame(opener:, pieces:, holds:) = state.frame
      let pieces = [
        Spliced(pieces),
        Literal(opener_text(opener)),
        ..parent.pieces
      ]
      let holds = adopted(parent.holds, opener, holds)
      Scan(..state, frame: Frame(..parent, pieces:, holds:), below:)
      |> counted(opener, -1)
    }
  }
}

// What a frame holds once a child frame, opened by `opener` and holding
// `child`, has ended inside it, closed or not.
fn adopted(parent: Holds, opener: Opener, child: Holds) -> Holds {
  case parent, opener, child {
    Nested, _, _ | _, Bracket(..), _ | _, _, Nested -> Nested
    Flat, Root, Flat | Flat, Delimited(..), Flat -> Flat
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
      let Frame(opener:, pieces:, holds:) = state.frame
      let node = Node(build(flatten(pieces)))
      let frame =
        Frame(
          ..parent,
          pieces: [node, ..parent.pieces],
          holds: adopted(parent.holds, opener, holds),
        )
      Scan(..state, frame:, below:)
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
// when a destination or a defined reference follows and, for a link, when no
// link has formed since it opened. Otherwise it is text, and so is the `]`.
// A reference is tried after a destination fails, as CommonMark has it: in
// `[foo](not a link)` with `foo` defined, `[foo]` is a link and the rest is
// text.
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
      let state = Scan(..state, unclosed:)
      let referenced = case active {
        True -> reference(rest, state)
        False -> Error(Nil)
      }
      case referenced {
        Ok(#(target, after, used)) ->
          scan(after, position + 1 + used, "]", linked(state, target))
        Error(Nil) -> {
          let state = dissolve(state)
          scan(
            rest,
            position + 1,
            "]",
            Scan(..state, pending: ["]", ..state.pending]),
          )
        }
      }
    }
  }
}

// The destination a reference link names, when the bracket that just closed
// is one: `[text][label]`, `[label][]` or `[label]`. The result is the
// destination, the input after the reference, and how many tokens after
// the `]` the reference took.
//
// A full reference reads its label from the input, and that scan stops at
// the first bracket, so no two such scans read the same text. The collapsed
// and shortcut forms use the bracket's own text as the label, which is read
// only when the bracket holds no other bracket: two such brackets never
// overlap, so no text is read for a label twice.
fn reference(
  rest: List(String),
  state: Scan,
) -> Result(#(String, List(String), Int), Nil) {
  case dict.is_empty(state.refs.links), rest {
    True, _ -> Error(Nil)
    False, ["[", "]", ..after] -> {
      use target <- result.try(own_reference(state))
      Ok(#(target, after, 2))
    }
    False, ["[", ..tail] ->
      case label_text(tail, SpacesAllowed, [], 0) {
        Ok(#(raw, after, used)) -> {
          use target <- result.try(lookup(state.refs, raw))
          Ok(#(target, after, used + 2))
        }
        Error(Nil) -> shortcut(rest, state)
      }
    False, _ -> shortcut(rest, state)
  }
}

fn shortcut(
  rest: List(String),
  state: Scan,
) -> Result(#(String, List(String), Int), Nil) {
  use target <- result.try(own_reference(state))
  Ok(#(target, rest, 0))
}

// The destination the top bracket's own text names as a label. The text is
// the plain text of what the bracket holds, so a label written with markup
// inside it matches a definition only when the definition's label is
// written without that markup.
fn own_reference(state: Scan) -> Result(String, Nil) {
  case state.frame.holds {
    Nested -> Error(Nil)
    Flat -> {
      let label = plain(flatten(state.frame.pieces))
      case string.drop_start(label, max_label) == "" {
        True -> lookup(state.refs, label)
        False -> Error(Nil)
      }
    }
  }
}

fn lookup(refs: Refs, label: String) -> Result(String, Nil) {
  use label <- result.try(normalized(label))
  dict.get(refs.links, label)
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
        Space if depth == 0 -> titled(rest, position + 1, text)
        Space -> Error(position)
        Punctuation | Word ->
          destination_text(rest, position + 1, depth, [grapheme, ..text])
      }
  }
}

// What may stand between a destination and its `)`: whitespace, and a
// title in double quotes, single quotes or parentheses. Neither host shows
// a title, so it is read and dropped. A failure reports how far it read, as
// the destination's own scan does, since the refusal of later scans rests
// on that.
fn titled(
  input: List(String),
  position: Int,
  text: List(String),
) -> Result(#(String, List(String), Int), Int) {
  let #(input, position) = skip_spaces(input, position)
  case input {
    [")", ..rest] ->
      Ok(#(text |> list.reverse |> string.concat, rest, position + 1))
    ["\"", ..rest] -> title_end(rest, position + 1, "\"", text)
    ["'", ..rest] -> title_end(rest, position + 1, "'", text)
    ["(", ..rest] -> title_end(rest, position + 1, ")", text)
    _ -> Error(position)
  }
}

fn title_end(
  input: List(String),
  position: Int,
  closer: String,
  text: List(String),
) -> Result(#(String, List(String), Int), Int) {
  case input {
    [] -> Error(position)
    ["\\", _, ..rest] -> title_end(rest, position + 2, closer, text)
    [grapheme, ..rest] if grapheme == closer -> {
      let #(after, position) = skip_spaces(rest, position + 1)
      case after {
        [")", ..rest] ->
          Ok(#(text |> list.reverse |> string.concat, rest, position + 1))
        _ -> Error(position)
      }
    }
    [_, ..rest] -> title_end(rest, position + 1, closer, text)
  }
}

fn skip_spaces(input: List(String), position: Int) -> #(List(String), Int) {
  case input {
    [grapheme, ..rest] ->
      case is_space(grapheme) {
        True -> skip_spaces(rest, position + 1)
        False -> #(input, position)
      }
    [] -> #(input, position)
  }
}

// `<scheme:rest>` is a link whose label is its destination, and
// `<name@domain>` is a link to that address. The scan stops at the first
// whitespace, `<` or `>`, so two scans never cover the same text, and
// anything that is neither, an HTML tag above all, stays text.
fn autolink(rest: List(String), position: Int, state: Scan) -> List(Inline) {
  let found = {
    use #(uri, after, used) <- result.try(angle(rest, []))
    case is_uri(uri), is_email(uri) {
      True, _ -> Ok(#(uri, uri, after, used))
      False, True -> Ok(#(uri, "mailto:" <> uri, after, used))
      False, False -> Error(Nil)
    }
  }
  case found {
    Ok(#(label, target, after, used)) ->
      scan(
        after,
        position + used + 2,
        ">",
        push_node(state, Link([Text(label)], target)),
      )
    Error(Nil) ->
      scan(
        rest,
        position + 1,
        "<",
        Scan(..state, pending: ["<", ..state.pending]),
      )
  }
}

// An address as CommonMark's email autolink allows it: a local part of
// letters, digits and a fixed set of punctuation, an `@`, and a domain of
// dot-separated labels of letters, digits and inner hyphens.
fn is_email(text: String) -> Bool {
  case string.split_once(text, "@") {
    Ok(#(local, domain)) ->
      local != ""
      && list.all(string.to_graphemes(local), fn(grapheme) {
        is_alphanumeric(grapheme)
        || string.contains(".!#$%&'*+/=?^_`{|}~-", grapheme)
      })
      && list.all(string.split(domain, "."), is_domain_label)
    Error(Nil) -> False
  }
}

fn is_domain_label(label: String) -> Bool {
  let length = string.length(label)
  length >= 1
  && length <= 63
  && !string.starts_with(label, "-")
  && !string.ends_with(label, "-")
  && list.all(string.to_graphemes(label), fn(grapheme) {
    is_alphanumeric(grapheme) || grapheme == "-"
  })
}

// Whether every byte of a non-empty token is an ASCII letter or digit.
fn is_alphanumeric(text: String) -> Bool {
  text != "" && alphanumeric_bytes(bit_array.from_string(text))
}

fn alphanumeric_bytes(bits: BitArray) -> Bool {
  case bits {
    <<>> -> True
    <<byte, rest:bytes>> ->
      case
        { byte >= 0x30 && byte <= 0x39 }
        || { byte >= 0x41 && byte <= 0x5A }
        || { byte >= 0x61 && byte <= 0x7A }
      {
        True -> alphanumeric_bytes(rest)
        False -> False
      }
    _ -> False
  }
}

// A bare link, as GitHub's autolink extension has it: `http://`, `https://`
// or `www.`, directly after the start of the text, whitespace, or one of
// `*`, `_`, `~` and `(`, then a domain holding a dot. The link runs to the
// next whitespace or `<`, less the trailing punctuation that more likely
// ends the sentence than the link. A `www.` link's destination is its text
// behind `http://`.
//
// The domain is checked before the rest is read. A check that fails has
// read a run of letters, digits, `_` and `-` and the character after it,
// and no other link can start inside such a run, since every prefix holds a
// `.` or a `:`; so failed checks never read the same text twice, and a
// check that passes takes the whole link, whose text is not read again.
fn bare_link(
  input: List(String),
  position: Int,
  previous: String,
  state: Scan,
) -> List(Inline) {
  let found = {
    use Nil <- result.try(case previous {
      "" | " " | "\n" | "\t" | "*" | "_" | "~" | "(" -> Ok(Nil)
      _ -> Error(Nil)
    })
    use #(prefix, used, rest) <- result.try(link_prefix(input))
    use Nil <- result.try(domain(rest))
    let #(body, after) =
      list.split_while(rest, fn(grapheme) {
        grapheme != "<" && !is_space(grapheme)
      })
    let #(kept, dropped) = trimmed_link(list.reverse(body), parens(body), [])
    Ok(#(prefix, used, list.reverse(kept), list.append(dropped, after)))
  }
  case found, input {
    Ok(#(prefix, used, body, after)), _ -> {
      let label = prefix <> string.concat(body)
      let target = case prefix {
        "www." -> "http://" <> label
        _ -> label
      }
      let last = case list.last(body) {
        Ok(grapheme) -> grapheme
        Error(Nil) -> "."
      }
      scan(
        after,
        position + used + list.length(body),
        last,
        push_node(state, Link([Text(label)], target)),
      )
    }
    Error(Nil), [grapheme, ..rest] -> read_text(grapheme, rest, position, state)
    Error(Nil), [] -> finish(state)
  }
}

// The prefix, how many tokens it took, and the tokens after it.
fn link_prefix(
  input: List(String),
) -> Result(#(String, Int, List(String)), Nil) {
  case input {
    ["https", ":", "/", "/", ..rest] -> Ok(#("https://", 4, rest))
    ["http", ":", "/", "/", ..rest] -> Ok(#("http://", 4, rest))
    ["www", ".", ..rest] -> Ok(#("www.", 2, rest))
    _ -> Error(Nil)
  }
}

// A domain's start: a run of letters, digits, `_` and `-`, a `.`, and one
// more letter, digit, `.` or `-`.
fn domain(input: List(String)) -> Result(Nil, Nil) {
  let #(label, rest) = list.split_while(input, is_host_character)
  case label, rest {
    [_, ..], [".", next, ..] ->
      case is_alphanumeric(next) || next == "." || next == "-" {
        True -> Ok(Nil)
        False -> Error(Nil)
      }
    _, _ -> Error(Nil)
  }
}

fn is_host_character(grapheme: String) -> Bool {
  is_alphanumeric(grapheme) || grapheme == "_" || grapheme == "-"
}

// How many `(` and `)` a link's text holds, counted once so that trimming
// its closing parentheses costs nothing per parenthesis.
fn parens(body: List(String)) -> #(Int, Int) {
  list.fold(body, #(0, 0), fn(counts, grapheme) {
    case grapheme {
      "(" -> #(counts.0 + 1, counts.1)
      ")" -> #(counts.0, counts.1 + 1)
      _ -> counts
    }
  })
}

// Walks a bare link's text backwards, `reversed` being that text, dropping
// what GitHub drops: trailing `?`, `!`, `.`, `,`, `:`, `*`, `_` and `~`, a
// `)` with no `(` left to balance it, and a trailing entity reference such
// as `&amp;`. It returns the text kept, still reversed, and the text
// dropped, in order.
fn trimmed_link(
  reversed: List(String),
  counts: #(Int, Int),
  dropped: List(String),
) -> #(List(String), List(String)) {
  case reversed {
    [")", ..rest] if counts.1 > counts.0 ->
      trimmed_link(rest, #(counts.0, counts.1 - 1), [")", ..dropped])
    [";", ..rest] ->
      case entity_name(rest, []) {
        Ok(#(name, before)) -> #(
          before,
          list.flatten([["&"], name, [";"], dropped]),
        )
        Error(Nil) -> trimmed_link(rest, counts, [";", ..dropped])
      }
    [grapheme, ..rest] ->
      case string.contains("?!.,:*_~", grapheme) {
        True -> trimmed_link(rest, counts, [grapheme, ..dropped])
        False -> #(reversed, dropped)
      }
    [] -> #(reversed, dropped)
  }
}

// The letters and digits of an entity reference's name, read backwards from
// its `;` to its `&`, in order, with the text before the `&`.
fn entity_name(
  reversed: List(String),
  name: List(String),
) -> Result(#(List(String), List(String)), Nil) {
  case reversed {
    ["&", ..before] if name != [] -> Ok(#(name, before))
    [grapheme, ..rest] ->
      case is_alphanumeric(grapheme) {
        True -> entity_name(rest, [grapheme, ..name])
        False -> Error(Nil)
      }
    [] -> Error(Nil)
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
    is_alphanumeric(grapheme)
    || grapheme == "+"
    || grapheme == "."
    || grapheme == "-"
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
