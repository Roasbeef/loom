//// Page chrome shared by the landing page and the documentation.

import gleam/int
import lustre/attribute.{type Attribute, attribute}
import lustre/element.{type Element}
import lustre/element/html
import site/msg.{type Msg}
import site/route

/// The repository.
pub const repo = "https://github.com/Roasbeef/loom"

/// The woven mark, drawn inline so that its dark threads follow the text
/// colour in both themes. The geometry is `docs/images/loom-mark.svg`.
pub fn mark(size: Int) -> Element(Msg) {
  element.unsafe_raw_html(
    "http://www.w3.org/2000/svg",
    "svg",
    [
      attribute("viewBox", "0 0 240 240"),
      attribute("width", int.to_string(size)),
      attribute("height", int.to_string(size)),
      attribute("aria-hidden", "true"),
      attribute.class("mark"),
    ],
    "<defs>"
      <> "<mask id=\"warp-gaps\" maskUnits=\"userSpaceOnUse\" x=\"0\" y=\"0\" width=\"240\" height=\"240\">"
      <> "<rect width=\"240\" height=\"240\" fill=\"white\"/>"
      <> "<path d=\"M 99 83 H 139 V 121 H 99 Z M 49 139 H 89 V 177 H 49 Z M 149 139 H 189 V 177 H 149 Z\" fill=\"black\"/>"
      <> "</mask>"
      <> "<mask id=\"weft-gaps\" maskUnits=\"userSpaceOnUse\" x=\"0\" y=\"0\" width=\"240\" height=\"240\">"
      <> "<rect width=\"240\" height=\"240\" fill=\"white\"/>"
      <> "<path d=\"M 49 83 H 89 V 121 H 49 Z M 149 83 H 189 V 121 H 149 Z M 99 139 H 139 V 177 H 99 Z\" fill=\"black\"/>"
      <> "</mask></defs>"
      <> "<g class=\"mark-warp\" mask=\"url(#warp-gaps)\">"
      <> "<rect x=\"52\" y=\"44\" width=\"34\" height=\"172\" rx=\"17\"/>"
      <> "<rect x=\"102\" y=\"16\" width=\"34\" height=\"188\" rx=\"17\"/>"
      <> "<rect x=\"152\" y=\"44\" width=\"34\" height=\"172\" rx=\"17\"/></g>"
      <> "<g class=\"mark-weft\" mask=\"url(#weft-gaps)\">"
      <> "<rect x=\"18\" y=\"86\" width=\"202\" height=\"32\" rx=\"16\"/>"
      <> "<rect x=\"18\" y=\"142\" width=\"202\" height=\"32\" rx=\"16\"/></g>",
  )
}

/// The top bar.
pub fn header(here: String) -> Element(Msg) {
  html.header([attribute.class("bar")], [
    html.div([attribute.class("bar-inner")], [
      html.a(
        [attribute.class("brand"), attribute.href(route.to_hash(route.Landing))],
        [
          mark(28),
          html.span([], [element.text("Loom")]),
        ],
      ),
      html.nav([attribute("aria-label", "Main")], [
        nav_link("Docs", route.to_hash(route.DocsHome), here == "docs"),
        nav_link("Install", route.doc("getting-started"), False),
        html.a(
          [
            attribute.class("nav-link"),
            attribute.href(repo),
            attribute.target("_blank"),
            attribute.rel("noopener"),
          ],
          [element.text("GitHub")],
        ),
      ]),
    ]),
  ])
}

fn nav_link(label: String, href: String, current: Bool) -> Element(Msg) {
  html.a(
    [attribute.class("nav-link"), attribute.href(href), ..current_page(current)],
    [element.text(label)],
  )
}

fn current_page(current: Bool) -> List(Attribute(Msg)) {
  case current {
    True -> [attribute("aria-current", "page")]
    False -> []
  }
}

/// The page footer.
pub fn footer() -> Element(Msg) {
  html.footer([attribute.class("foot")], [
    html.div([attribute.class("foot-inner")], [
      html.p([], [
        element.text("Loom is developed in the open at "),
        html.a(
          [
            attribute.href(repo),
            attribute.target("_blank"),
            attribute.rel("noopener"),
          ],
          [
            element.text("github.com/Roasbeef/loom"),
          ],
        ),
        element.text(
          ". It is under active development, and you build it from source.",
        ),
      ]),
      html.p([attribute.class("foot-small")], [
        element.text(
          "This site is a client-side Lustre application written in Gleam. Its text describes the ",
        ),
        html.code([], [element.text("main")]),
        element.text(
          " branch, except where a page says a feature is in development.",
        ),
      ]),
    ]),
  ])
}
