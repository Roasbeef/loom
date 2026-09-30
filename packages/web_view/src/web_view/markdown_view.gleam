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
//// - A code fence's language is a text label, never a class.
////
//// The tree is bounded in depth by the parser (`markdown.max_depth`,
//// `markdown.max_emphasis`), so the recursion here is too.

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import session_view/markdown.{type Block, type Inline}

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
        html.pre([], [code_lines(text)]),
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

// A fence's body as one span per line. A streamed block grows at its tail,
// and a single text node would be sent whole on every batch, which over a
// long block is quadratic. Lustre diffs unkeyed children by position, so the
// lines that did not change are skipped, the one still being written is
// patched, and the new ones are inserted as one trailing addition. Every
// span but the last carries its own newline, so the text a reader copies is
// the fence's text unchanged.
fn code_lines(text: String) -> Element(message) {
  let lines = string.split(text, "\n")
  let last = list.length(lines) - 1
  html.code(
    [],
    list.index_map(lines, fn(line, index) {
      let shown = case index == last {
        True -> line
        False -> line <> "\n"
      }
      html.span([], [html.text(shown)])
    }),
  )
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
