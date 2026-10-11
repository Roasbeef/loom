//// A small Markdown reader for the documentation files.
////
//// The pages under `public/content/` are plain Markdown, so the owner can
//// edit them without touching Gleam. This module reads the subset those
//// pages use and nothing more: a title, `##` and `###` headings, paragraphs,
//// bullet and numbered lists, tables, fenced code, `>` notes, and a
//// `::figure name` line that embeds one of the explainer figures. Prose goes
//// through `site/inline` for code, bold and links.

import gleam/list
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import site/inline

/// One block of a page.
pub type Block {
  Title(String)
  Heading(level: Int, id: String, text: String)
  Para(String)
  Code(lang: String, text: String)
  Table(head: List(String), rows: List(List(String)))
  Bullets(List(String))
  Numbered(List(String))
  Note(String)
  Figure(String)
}

/// Reads a document into blocks.
pub fn parse(text: String) -> List(Block) {
  text
  |> string.replace("\r\n", "\n")
  |> string.split("\n")
  |> blocks([])
}

/// The `##` headings of a document, for the page outline.
pub fn outline(blocks: List(Block)) -> List(#(String, String)) {
  list.filter_map(blocks, fn(block) {
    case block {
      Heading(2, id, text) -> Ok(#(id, text))
      _ -> Error(Nil)
    }
  })
}

/// The title of a document, if it has one.
pub fn title(blocks: List(Block)) -> Result(String, Nil) {
  list.find_map(blocks, fn(block) {
    case block {
      Title(text) -> Ok(text)
      _ -> Error(Nil)
    }
  })
}

fn blocks(lines: List(String), done: List(Block)) -> List(Block) {
  case lines {
    [] -> list.reverse(done)

    ["", ..rest] -> blocks(rest, done)

    ["```" <> lang, ..rest] -> {
      let #(body, after) = list.split_while(rest, fn(line) { line != "```" })
      blocks(list.drop(after, 1), [
        Code(string.trim(lang), string.join(body, "\n")),
        ..done
      ])
    }

    ["# " <> text, ..rest] -> blocks(rest, [Title(text), ..done])
    ["## " <> text, ..rest] ->
      blocks(rest, [Heading(2, slug(text), text), ..done])
    ["### " <> text, ..rest] ->
      blocks(rest, [Heading(3, slug(text), text), ..done])

    ["::figure " <> name, ..rest] ->
      blocks(rest, [Figure(string.trim(name)), ..done])

    ["|" <> _, ..] -> {
      let #(rows, after) = list.split_while(lines, string.starts_with(_, "|"))
      blocks(after, [table(rows), ..done])
    }

    ["- " <> _, ..] -> {
      let #(items, after) = list_items(lines, "- ")
      blocks(after, [Bullets(items), ..done])
    }

    [line, ..] ->
      case numbered(line) {
        True -> {
          let #(items, after) = numbered_items(lines)
          blocks(after, [Numbered(items), ..done])
        }
        False ->
          case string.starts_with(line, ">") {
            True -> {
              let #(quoted, after) =
                list.split_while(lines, string.starts_with(_, ">"))
              let text =
                quoted
                |> list.map(fn(q) { string.trim(string.drop_start(q, 1)) })
                |> string.join(" ")
              blocks(after, [Note(text), ..done])
            }
            False -> {
              let #(para, after) = list.split_while(lines, is_paragraph_line)
              blocks(after, [Para(string.join(para, " ")), ..done])
            }
          }
      }
  }
}

fn is_paragraph_line(line: String) -> Bool {
  line != ""
  && !string.starts_with(line, "```")
  && !string.starts_with(line, "#")
  && !string.starts_with(line, "|")
  && !string.starts_with(line, "- ")
  && !string.starts_with(line, ">")
  && !string.starts_with(line, "::figure")
  && !numbered(line)
}

fn numbered(line: String) -> Bool {
  case string.split_once(line, ". ") {
    Ok(#(digits, _)) ->
      digits != "" && list.all(string.to_graphemes(digits), is_digit)
    Error(Nil) -> False
  }
}

fn is_digit(char: String) -> Bool {
  string.contains("0123456789", char)
}

/// Collects `- ` items; a following line indented by two spaces continues
/// the previous item.
fn list_items(lines: List(String), marker: String) -> #(List(String), List(String)) {
  collect_items(lines, fn(line) { string.starts_with(line, marker) }, marker, [])
}

fn numbered_items(lines: List(String)) -> #(List(String), List(String)) {
  collect_items(lines, numbered, ". ", [])
}

fn collect_items(
  lines: List(String),
  is_item: fn(String) -> Bool,
  marker: String,
  items: List(String),
) -> #(List(String), List(String)) {
  case lines {
    [line, ..rest] ->
      case is_item(line) {
        True -> {
          let text = case string.split_once(line, marker) {
            Ok(#(_, text)) -> text
            Error(Nil) -> line
          }
          collect_items(rest, is_item, marker, [text, ..items])
        }
        False ->
          case string.starts_with(line, "  "), items {
            True, [last, ..others] ->
              collect_items(rest, is_item, marker, [
                last <> " " <> string.trim(line),
                ..others
              ])
            _, _ -> #(list.reverse(items), lines)
          }
      }
    [] -> #(list.reverse(items), [])
  }
}

fn table(rows: List(String)) -> Block {
  let cells = list.map(rows, split_row)
  case cells {
    [head, _separator, ..body] -> Table(head, body)
    [head] -> Table(head, [])
    [] -> Table([], [])
  }
}

fn split_row(row: String) -> List(String) {
  row
  |> string.trim
  |> string.drop_start(1)
  |> string.drop_end(1)
  |> string.split("|")
  |> list.map(string.trim)
}

/// A heading id: lowercase letters and digits joined by hyphens.
pub fn slug(text: String) -> String {
  text
  |> string.lowercase
  |> string.to_graphemes
  |> list.map(fn(char) {
    case string.contains("abcdefghijklmnopqrstuvwxyz0123456789", char) {
      True -> char
      False -> "-"
    }
  })
  |> string.concat
  |> string.split("-")
  |> list.filter(fn(part) { part != "" })
  |> string.join("-")
}

/// Renders blocks. `figure` builds the element for a `::figure` line.
pub fn render(
  blocks: List(Block),
  figure: fn(String) -> Element(msg),
) -> List(Element(msg)) {
  list.map(blocks, fn(block) {
    case block {
      Title(text) -> html.h1([], [element.text(text)])
      Heading(level, id, text) -> heading(level, id, text)
      Para(text) -> inline.paragraph(text)
      Code(lang, text) ->
        html.pre([attribute.attribute("data-lang", lang)], [
          html.code([], [element.text(text)]),
        ])
      Table(head, rows) -> render_table(head, rows)
      Bullets(items) -> html.ul([], list.map(items, item))
      Numbered(items) -> html.ol([], list.map(items, item))
      Note(text) -> html.aside([attribute.class("note")], inline.render(text))
      Figure(name) -> figure(name)
    }
  })
}

fn item(text: String) -> Element(msg) {
  html.li([], inline.render(text))
}

fn heading(level: Int, id: String, text: String) -> Element(msg) {
  // Headings carry an id for the page outline and for `#/docs/page/section`
  // links. They are not rendered as `#id` links, because a bare fragment
  // would replace the route.
  case level {
    2 -> html.h2([attribute.id(id)], inline.render(text))
    _ -> html.h3([attribute.id(id)], inline.render(text))
  }
}

fn render_table(head: List(String), rows: List(List(String))) -> Element(msg) {
  html.div([attribute.class("table-wrap")], [
    html.table([], [
      html.thead([], [
        html.tr(
          [],
          list.map(head, fn(cell) { html.th([], inline.render(cell)) }),
        ),
      ]),
      html.tbody(
        [],
        list.map(rows, fn(row) {
          html.tr(
            [],
            list.map(row, fn(cell) { html.td([], inline.render(cell)) }),
          )
        }),
      ),
    ]),
  ])
}
