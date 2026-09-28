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
        html.pre([], [html.code([], [html.text(text)])]),
      ])

    markdown.Quote(blocks:) ->
      html.blockquote(
        [attribute.class("md-quote")],
        list.map(blocks, block_element),
      )

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

    markdown.Rule -> html.hr([attribute.class("md-rule")])
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

    markdown.Break -> html.br([])
  }
}

// The label, styled as a link, then the destination as text, in one
// unstyled span so the two stay one inline node and the underline does not
// reach the destination. An autolink's
// label is its destination, and an empty destination says nothing, so
// neither repeats it.
fn link(label: List(Inline), destination: String) -> Element(message) {
  let target = case destination == "" || markdown.plain(label) == destination {
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
