//// CommonMark-to-etui rendering for assistant output.
////
//// Mork owns parsing. This module is a deliberately small presentation
//// adapter over its public document tree, emitting styled etui spans without
//// routing model text through HTML or an ANSI renderer.

import etui/span
import etui/style
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some, unwrap}
import gleam/string
import mork
import mork/document.{
  type Block, type Cell, type Destination, type Document, type Inline,
  type LinkData, type ListItem, type THead, Absolute, Anchor, Autolink,
  BlockQuote, BulletList, Cell, Checkbox, Code, CodeSpan, Delim, Document,
  EmailAutolink, Emphasis, Empty, Footnote, FullImage, FullLink, HardBreak,
  Heading, Highlight, HtmlBlock, InlineFootnote, InlineHtml, LinkData, ListItem,
  Newline, OrderedList, Paragraph, RawHtml, RefImage, RefLink, Relative,
  SoftBreak, Strikethrough, Strong, THead, Table, Text, ThematicBreak,
  lookup_link,
}
import tui_gleam/text_hygiene
import tui_gleam/theme

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
}

type CodeCharacter {
  SpaceCharacter
  IdentifierCharacter
  NumberCharacter
  QuoteCharacter
  PunctuationCharacter
}

/// Parses model markdown and returns wrapped-ready styled terminal lines.
pub fn render(markdown: String) -> List(span.Line) {
  let safe = text_hygiene.multiline(markdown)
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
  list.flat_map(blocks, render_block(document, _))
}

fn render_block(document: Document, block: Block) -> List(span.Line) {
  case block {
    Heading(level:, inlines:, ..) ->
      inline_lines(document, inlines, heading_style(level))
      |> prefix_lines([span.span_styled("▌ ", theme.current_bold())], [
        span.span_plain("  "),
      ])
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
          span.span_styled("│ ", theme.signal_bold()),
          ..code_spans(lang, line)
        ])
      })
      |> prepend_code_language(lang)
      |> trailing_blank
    BlockQuote(blocks:) ->
      blocks
      |> list.flat_map(render_block(document, _))
      |> prefix_lines([span.span_styled("│ ", theme.current_bold())], [
        span.span_styled("│ ", theme.current_bold()),
      ])
    BulletList(items:, ..) -> render_list(document, items, None)
    OrderedList(items:, start:, ..) ->
      render_list(document, items, Some(unwrap(start, 1)))
    Table(header:, rows:) -> render_table(document, header, rows)
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
        _ -> [span.span_styled(line, code_style())]
      }
    None -> [span.span_styled(line, code_style())]
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
  }
  span.span_styled(text, rendered)
}

fn render_list(
  document: Document,
  items: List(ListItem),
  ordered_start: Option(Int),
) -> List(span.Line) {
  items
  |> list.index_map(fn(item, index) {
    let ListItem(blocks:, ..) = item
    let marker = case ordered_start {
      Some(start) -> int.to_string(start + index) <> ". "
      None -> "• "
    }
    blocks
    |> list.flat_map(render_block(document, _))
    |> trim_trailing_blank
    |> prefix_lines([span.span_styled(marker, theme.signal_bold())], [
      span.span_plain(string.repeat(" ", string.length(marker))),
    ])
  })
  |> list.flatten
  |> trailing_blank
}

fn render_table(
  document: Document,
  header: List(THead),
  rows: List(List(Cell)),
) -> List(span.Line) {
  let header_line =
    header
    |> list.map(fn(cell) {
      let THead(inlines:, ..) = cell
      inline_spans(document, inlines, theme.current_bold())
    })
    |> table_row
  let body =
    rows
    |> list.map(fn(row) {
      row
      |> list.map(fn(cell) {
        let Cell(inlines:, ..) = cell
        inline_spans(document, inlines, style.default_style())
      })
      |> table_row
    })
  [
    header_line,
    span.line_new([span.span_styled("  ────────────────", theme.quiet_text())]),
    ..body
  ]
  |> trailing_blank
}

fn table_row(cells: List(List(span.Span))) -> span.Line {
  span.line_new([
    span.span_styled("  ", theme.quiet_text()),
    ..join_span_groups(cells, [
      span.span_styled(" │ ", theme.quiet_text()),
    ])
  ])
}

fn join_span_groups(
  groups: List(List(span.Span)),
  separator: List(span.Span),
) -> List(span.Span) {
  case groups {
    [] -> []
    [first, ..rest] ->
      list.fold(rest, first, fn(joined, group) {
        list.append(joined, list.append(separator, group))
      })
  }
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
    CodeSpan(value) -> [Styled(span.span_styled(value, code_style()))]
    Emphasis(children) ->
      nested_parts(document, children, style.add_modifier(base, style.italic()))
    Strong(children) ->
      nested_parts(document, children, style.add_modifier(base, style.bold()))
    Highlight(children) ->
      nested_parts(document, children, style.with_fg(base, theme.signal))
    Strikethrough(children) ->
      nested_parts(document, children, style.add_modifier(base, style.dim()))
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
    Some(value) -> [
      span.line_new([
        span.span_styled("┌ ", theme.signal_bold()),
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
