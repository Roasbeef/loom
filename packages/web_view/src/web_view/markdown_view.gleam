//// Draws `session_view/markdown`'s tree as HTML elements.
////
//// The terminal renders an assistant's Markdown, and before this module the
//// page showed the same text raw, asterisks and fences included. The parse
//// happens in `session_view/markdown`, which returns a closed tree; this
//// module maps each variant to a fixed element and puts every string the
//// session wrote into a text node. The rules it keeps are 051's ("Nothing
//// from the session becomes markup") and `docs/lustre.md` section 3:
////
//// - No attribute takes its value from session text. Classes come from a
////   `case` over a closed type: a heading's level, a cell's alignment.
//// - A link is drawn as its label followed by its destination in plain
////   text. There is no `<a href>`: the page follows nothing the agent
////   wrote, and a `javascript:` destination is only characters.
//// - An ordered list's numbers are text in each item rather than a `start`
////   attribute, so the number the model wrote never reaches an attribute.
//// - A code fence's language is a text label, never a class. It also picks
////   the scanner that colours the fence (`code_view`), which draws token
////   classes from a closed type and every token's text as a text node.
////
//// The tree is bounded in depth by the parser (`markdown.max_depth`,
//// `markdown.max_emphasis`), so the recursion here is too.

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import session_view/markdown.{type Block, type Inline}
import web_view/code_view

/// The elements for a parsed Markdown tree, one per top-level block.
///
/// The tree comes from `session_view/markdown.parse`, which the component
/// runs in `update` when a capture lands, so drawing a row costs no parse.
///
/// ## Examples
///
/// ```gleam
/// let children = markdown_view.blocks(markdown.parse("**bold**"))
/// ```
pub fn blocks(tree: List(Block)) -> List(Element(message)) {
  list.map(tree, block_element)
}

/// The first line of a text's Markdown as inline elements, flattened to one
/// row and cut at `limit` characters of visible text.
///
/// A preview of a longer text (a sub-agent's report under its who-line, the
/// latest answer of a strand) is the text's opening line with its bold and code
/// kept, so the preview reads as the text does once opened and shows no
/// asterisks or backticks. The opening is the first block that has words: a
/// paragraph or heading, the first item of a list, the first line of a code
/// block. A hard break inside it is a space. A cut ends in an ellipsis, made
/// on the parsed spans so it never leaves a marker unclosed. Every string
/// reaches the page as a text node, as in `blocks`.
///
/// ## Examples
///
/// ```gleam
/// let children = markdown_view.line("**Done:** `calc.py` has `mul`", 140)
/// ```
pub fn line(text: String, limit: Int) -> List(Element(message)) {
  let first =
    text
    |> string.split("\n")
    |> list.find(fn(line) { string.trim(line) != "" })
    |> result.unwrap("")

  // The first line alone is the preview. A line that is only the start of a
  // construct, such as the opening of a code fence, has no words of its own, so
  // the whole text is read for them.
  markdown.parse(first)
  |> list.find_map(opening)
  |> result.lazy_or(fn() { list.find_map(markdown.parse(text), opening) })
  |> result.unwrap([])
  |> unbroken
  |> clip(limit)
  |> list.map(inline_element)
}

// The inlines of the first block that has any, looking inside quotes, notes and
// lists, and nothing for a table or a rule.
fn opening(block: Block) -> Result(List(Inline), Nil) {
  case block {
    markdown.Paragraph(inlines:) | markdown.Heading(inlines:, ..) ->
      case inlines {
        [] -> Error(Nil)
        [_, ..] -> Ok(inlines)
      }

    // A fence's first line stands for it, in the code face.
    markdown.CodeBlock(text:, ..) ->
      case string.split(string.trim(text), "\n") {
        [""] | [] -> Error(Nil)
        [first, ..] -> Ok([markdown.Code(string.trim(first))])
      }

    markdown.Quote(blocks:)
    | markdown.Alert(blocks:, ..)
    | markdown.Footnote(blocks:, ..) -> list.find_map(blocks, opening)

    markdown.BulletList(items:) | markdown.OrderedList(items:, ..) ->
      list.find_map(list.flatten(items), opening)

    markdown.Table(..) | markdown.Rule -> Error(Nil)
  }
}

// A hard break in a line that stays on one row is a space.
fn unbroken(inlines: List(Inline)) -> List(Inline) {
  list.map(inlines, fn(inline) {
    case inline {
      markdown.Break -> markdown.Text(" ")
      markdown.Emphasis(children:) -> markdown.Emphasis(unbroken(children))
      markdown.Strong(children:) -> markdown.Strong(unbroken(children))
      markdown.Strikethrough(children:) ->
        markdown.Strikethrough(unbroken(children))
      markdown.Link(label:, destination:) ->
        markdown.Link(unbroken(label), destination)
      markdown.Text(..)
      | markdown.Code(..)
      | markdown.Image(..)
      | markdown.Task(..)
      | markdown.FootnoteRef(..) -> inline
    }
  })
}

// The inlines unchanged when their visible text fits, and otherwise cut where
// the budget runs out, with an ellipsis in place of the rest.
fn clip(inlines: List(Inline), limit: Int) -> List(Inline) {
  case string.length(markdown.plain(inlines)) > limit {
    False -> inlines
    True -> clipped(inlines, limit).0
  }
}

// The spans that fit in `left` characters, and what is left of the budget. A
// negative budget means the cut was made, so nothing after it is kept.
fn clipped(inlines: List(Inline), left: Int) -> #(List(Inline), Int) {
  case inlines, left < 0 {
    [], _ | _, True -> #([], left)
    [first, ..rest], False -> {
      let #(kept, left) = clip_one(first, left)
      let #(more, left) = clipped(rest, left)
      #(list.append(kept, more), left)
    }
  }
}

// One span against the budget: a text or code span is cut where the budget
// ends, a span that wraps others is cut inside, and an atom is kept whole or
// replaced by the ellipsis.
fn clip_one(inline: Inline, left: Int) -> #(List(Inline), Int) {
  case inline {
    markdown.Text(text:) -> cut_text(text, left, markdown.Text)
    markdown.Code(text:) -> cut_text(text, left, markdown.Code)
    markdown.Emphasis(children:) -> {
      let #(kept, left) = clipped(children, left)
      #([markdown.Emphasis(kept)], left)
    }
    markdown.Strong(children:) -> {
      let #(kept, left) = clipped(children, left)
      #([markdown.Strong(kept)], left)
    }
    markdown.Strikethrough(children:) -> {
      let #(kept, left) = clipped(children, left)
      #([markdown.Strikethrough(kept)], left)
    }
    markdown.Link(label:, destination:) -> {
      let #(kept, left) = clipped(label, left)
      #([markdown.Link(kept, destination)], left)
    }
    markdown.Break
    | markdown.Image(..)
    | markdown.Task(..)
    | markdown.FootnoteRef(..) -> {
      let width = string.length(markdown.plain([inline]))
      case width <= left {
        True -> #([inline], left - width)
        False -> #([markdown.Text("…")], -1)
      }
    }
  }
}

fn cut_text(
  text: String,
  left: Int,
  span: fn(String) -> Inline,
) -> #(List(Inline), Int) {
  let width = string.length(text)
  case width <= left {
    True -> #([span(text)], left - width)
    False -> #([span(at_word(text, left) <> "…")], -1)
  }
}

// The first `left` characters of a text backed up to the end of the last whole
// word, so the ellipsis follows a word and not half of one. A cut that lands on
// a word's end and a text with no space in it keep every character.
fn at_word(text: String, left: Int) -> String {
  let cut = string.slice(text, 0, left)
  case string.slice(text, left, 1), list.reverse(string.split(cut, " ")) {
    " ", _ -> cut
    _, [_partial, first, ..rest] ->
      string.trim_end(string.join(list.reverse([first, ..rest]), " "))
    _, _ -> string.trim_end(cut)
  }
}

fn block_element(block: Block) -> Element(message) {
  case block {
    markdown.Paragraph(inlines:) ->
      html.p([attribute.class("md-p")], list.map(inlines, inline_element))

    // A heading inside an answer is a styled paragraph, not an `h1`–`h6`:
    // the page's outline is the page's, and the agent does not get to add
    // entries to it.
    markdown.Heading(level:, inlines:) ->
      html.p(
        [attribute.class("md-heading"), level_class(level)],
        list.map(inlines, inline_element),
      )

    markdown.CodeBlock(language:, text:) ->
      html.div([attribute.class("md-code")], [
        case language {
          Some(language) ->
            html.span([attribute.class("md-code-lang")], [html.text(language)])
          None -> element.none()
        },
        html.pre([], [code_view.block(language, text)]),
      ])

    markdown.Quote(blocks:) ->
      html.blockquote(
        [attribute.class("md-quote")],
        list.map(blocks, block_element),
      )

    // An alert is a quote with its kind as a title line. The title is one
    // of five fixed words chosen by a `case`, never text from the session.
    markdown.Alert(kind:, blocks:) ->
      html.blockquote([attribute.class("md-quote")], [
        html.p([attribute.class("md-heading"), attribute.class("md-h4")], [
          html.text(alert_title(kind)),
        ]),
        ..list.map(blocks, block_element)
      ])

    markdown.BulletList(items:) ->
      html.ul(
        [attribute.class("md-list")],
        list.map(items, fn(blocks) { item("•", blocks) }),
      )

    markdown.OrderedList(start:, items:) ->
      html.ol(
        [attribute.class("md-list")],
        list.index_map(items, fn(blocks, index) {
          item(int.to_string(start + index) <> ".", blocks)
        }),
      )

    // A wide table scrolls inside its own box instead of widening the page.
    markdown.Table(header:, rows:) ->
      html.div([attribute.class("md-table-wrap")], [
        html.table([attribute.class("md-table")], [
          html.thead([], [html.tr([], list.map(header, header_cell))]),
          html.tbody(
            [],
            list.map(rows, fn(row) { html.tr([], list.map(row, body_cell)) }),
          ),
        ]),
      ])

    // A footnote's definition is drawn where the model wrote it, laid out
    // as a list item whose marker is its label in brackets. The label is
    // text in the marker, never an id or an anchor.
    markdown.Footnote(label:, blocks:) ->
      html.div([attribute.class("md-item")], [
        html.span([attribute.class("md-marker")], [
          html.text("[" <> label <> "]"),
        ]),
        html.div(
          [attribute.class("md-item-body")],
          list.map(blocks, block_element),
        ),
      ])

    markdown.Rule -> html.hr([attribute.class("md-rule")])
  }
}

fn alert_title(kind: markdown.AlertKind) -> String {
  case kind {
    markdown.Note -> "Note"
    markdown.Tip -> "Tip"
    markdown.Important -> "Important"
    markdown.Warning -> "Warning"
    markdown.Caution -> "Caution"
  }
}

// The marker is text beside the item's blocks, as the terminal draws it,
// which also keeps an ordered list's numbers out of any attribute.
fn item(marker: String, blocks: List(Block)) -> Element(message) {
  html.li([attribute.class("md-item")], [
    html.span([attribute.class("md-marker")], [html.text(marker)]),
    html.div([attribute.class("md-item-body")], list.map(blocks, block_element)),
  ])
}

fn header_cell(cell: markdown.Cell) -> Element(message) {
  html.th([align_class(cell.align)], list.map(cell.inlines, inline_element))
}

fn body_cell(cell: markdown.Cell) -> Element(message) {
  html.td([align_class(cell.align)], list.map(cell.inlines, inline_element))
}

fn level_class(level: markdown.Level) -> attribute.Attribute(message) {
  case level {
    markdown.H1 -> attribute.class("md-h1")
    markdown.H2 -> attribute.class("md-h2")
    markdown.H3 -> attribute.class("md-h3")
    markdown.H4 -> attribute.class("md-h4")
    markdown.H5 -> attribute.class("md-h5")
    markdown.H6 -> attribute.class("md-h6")
  }
}

fn align_class(align: markdown.Align) -> attribute.Attribute(message) {
  case align {
    markdown.Unaligned -> attribute.none()
    markdown.Left -> attribute.class("md-left")
    markdown.Center -> attribute.class("md-center")
    markdown.Right -> attribute.class("md-right")
  }
}

fn inline_element(inline: Inline) -> Element(message) {
  case inline {
    markdown.Text(text:) -> html.text(text)
    markdown.Code(text:) ->
      html.code([attribute.class("md-code-span")], [html.text(text)])
    markdown.Emphasis(children:) ->
      html.em([], list.map(children, inline_element))
    markdown.Strong(children:) ->
      html.strong([], list.map(children, inline_element))
    markdown.Strikethrough(children:) ->
      html.s([], list.map(children, inline_element))
    markdown.Link(label:, destination:) -> link(label, destination)

    // An image is not loaded: the page fetches nothing the agent names. It
    // is drawn as the terminal draws it, its text and its destination.
    markdown.Image(alt:, destination:) ->
      html.span([attribute.class("md-image")], [
        html.text("[image: " <> alt <> " · " <> destination <> "]"),
      ])

    // A task box is the glyph the terminal draws, as text.
    markdown.Task(state: markdown.Open) -> html.text("☐ ")
    markdown.Task(state: markdown.Done) -> html.text("☑ ")

    // A footnote reference is its label in brackets, as text. It links to
    // nothing: an anchor would put the label into an attribute.
    markdown.FootnoteRef(label:) ->
      html.span([attribute.class("md-link-target")], [
        html.text("[" <> label <> "]"),
      ])

    markdown.Break -> html.br([])
  }
}

// The label, styled as a link, then the destination as text, in one
// unstyled span so the two stay one inline node and the underline does not
// reach the destination. An autolink's label is its destination, or its
// destination without the `http://` or `mailto:` the parser put in front of
// a bare `www.` link or an address, and an empty destination says nothing,
// so none of those repeats it.
fn link(label: List(Inline), destination: String) -> Element(message) {
  let shown = markdown.plain(label)
  let repeats =
    destination == ""
    || destination == shown
    || destination == "http://" <> shown
    || destination == "mailto:" <> shown
  let target = case repeats {
    True -> element.none()
    False ->
      html.span([attribute.class("md-link-target")], [
        html.text(" (" <> destination <> ")"),
      ])
  }
  html.span([], [
    html.span([attribute.class("md-link")], list.map(label, inline_element)),
    target,
  ])
}
