//// The documentation pages.
////
//// The text of each page is a Markdown file under `public/content/`. This
//// module knows the order of the pages, loads nothing itself, and lays out
//// whatever the model has fetched: a sidebar, the page, an outline and the
//// previous and next links.

import gleam/list
import lustre/attribute.{attribute}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import site/figure
import site/figures
import site/inline
import site/markdown
import site/model.{type Model} as m
import site/msg.{type Msg}
import site/route
import site/ui

/// A documentation page.
pub type Page {
  Page(slug: String, title: String, summary: String)
}

/// The pages, in reading order.
pub fn pages() -> List(Page) {
  [
    Page(
      "getting-started",
      "Install",
      "Download a release, verify it, install it and update it. Build from source instead if you prefer.",
    ),
    Page(
      "configuration",
      "Configuration",
      "Choose models, route roles and set the limits an operator owns.",
    ),
    Page(
      "sessions",
      "Sessions",
      "How a session is stored, resumed, forked and shared.",
    ),
    Page(
      "code-mode",
      "Code mode",
      "Let the model write a typed program that runs in a jail.",
    ),
    Page(
      "approvals-and-sandboxing",
      "Approvals and sandboxing",
      "What a command can touch, and how you widen it.",
    ),
    Page(
      "distributed-runtime",
      "Distributed runtime",
      "Orchestrators, executors, pools and moving a session, and what a remote session cannot do yet.",
    ),
    Page(
      "self-evolution",
      "Self-evolution",
      "Let an agent write extensions, programs and prompt profiles, and let you test, approve and select them while the session runs.",
    ),
    Page(
      "terminal-and-web",
      "Terminal and web view",
      "Use Loom from the terminal, a browser, or both.",
    ),
  ]
}

/// The title of a page, or its slug when it is unknown.
pub fn title_of(slug: String) -> String {
  case list.find(pages(), fn(page) { page.slug == slug }) {
    Ok(page) -> page.title
    Error(Nil) -> slug
  }
}

/// The documentation index.
pub fn home(model: Model) -> Element(Msg) {
  layout(model, "", [
    html.article([attribute.class("prose")], [
      html.h1([], [element.text("Documentation")]),
      html.p([attribute.class("lede")], [
        element.text(
          "These pages explain how to run Loom and how its main parts work. They are written for someone who has not read the source. The design documents in the repository go further, and each page says where.",
        ),
      ]),
      html.ol(
        [attribute.class("index")],
        list.map(pages(), fn(page) {
          html.li([], [
            html.a([attribute.href(route.doc(page.slug))], [
              element.text(page.title),
            ]),
            html.span([], [element.text(page.summary)]),
          ])
        }),
      ),
    ]),
  ])
}

/// One documentation page.
pub fn view(model: Model, slug: String) -> Element(Msg) {
  layout(model, slug, [
    case m.doc(model, slug) {
      m.Loading ->
        html.article([attribute.class("prose")], [
          html.p([attribute.class("quiet")], [element.text("Loading.")]),
        ])
      m.Failed ->
        html.article([attribute.class("prose")], [
          html.h1([], [element.text("Page not found")]),
          html.p([], [
            element.text("There is no documentation page called "),
            html.code([], [element.text(slug)]),
            element.text(". "),
            html.a([attribute.href(route.to_hash(route.DocsHome))], [
              element.text("See all pages."),
            ]),
          ]),
        ])
      m.Ready(blocks) -> article(model, slug, blocks)
    },
  ])
}

fn article(
  model: Model,
  slug: String,
  blocks: List(markdown.Block),
) -> Element(Msg) {
  let outline = markdown.outline(blocks)
  let body =
    list.append(
      markdown.render(
        blocks,
        markdown.Host(slug, model.copied, fn(name) { embed(model, name) }),
      ),
      [neighbours(slug)],
    )
    |> insert_outline(slug, outline)
  html.article([attribute.class("prose")], body)
}

/// Places the outline after the first paragraph, which is the page's lede.
fn insert_outline(
  elements: List(Element(Msg)),
  slug: String,
  outline: List(#(String, String)),
) -> List(Element(Msg)) {
  case outline {
    [] -> elements
    _ ->
      case elements {
        [title, lede, ..rest] -> [
          title,
          lede,
          html.nav(
            [
              attribute.class("outline"),
              attribute("aria-label", "On this page"),
            ],
            [
              html.p([attribute.class("kicker")], [element.text("On this page")]),
              html.ul(
                [],
                list.map(outline, fn(entry) {
                  html.li([], [
                    html.a(
                      [attribute.href(route.to_hash(route.Doc(slug, entry.0)))],
                      inline.render(entry.1),
                    ),
                  ])
                }),
              ),
            ],
          ),
          ..rest
        ]
        _ -> elements
      }
  }
}

fn embed(model: Model, name: String) -> Element(Msg) {
  case msg.figure_from_key(name) {
    Ok(id) ->
      figure.embedded(
        figures.spec(id),
        m.step(model, id),
        m.is_playing(model, id),
        model.copied,
      )
    Error(Nil) -> element.none()
  }
}

fn neighbours(slug: String) -> Element(Msg) {
  let all = pages()
  let indexed = list.index_map(all, fn(page, i) { #(page.slug, i) })
  case list.find(indexed, fn(pair) { pair.0 == slug }) {
    Error(Nil) -> element.none()
    Ok(#(_, i)) ->
      html.nav(
        [attribute.class("neighbours"), attribute("aria-label", "Pages")],
        [
          case i > 0, list.first(list.drop(all, i - 1)) {
            True, Ok(previous) -> link("Previous", previous)
            _, _ -> element.none()
          },
          case list.first(list.drop(all, i + 1)) {
            Ok(next) -> link("Next", next)
            Error(Nil) -> element.none()
          },
        ],
      )
  }
}

fn link(direction: String, page: Page) -> Element(Msg) {
  html.a([attribute.class("neighbour"), attribute.href(route.doc(page.slug))], [
    html.span([attribute.class("kicker")], [element.text(direction)]),
    html.span([attribute.class("neighbour-title")], [element.text(page.title)]),
  ])
}

fn layout(
  model: Model,
  current: String,
  content: List(Element(Msg)),
) -> Element(Msg) {
  html.div([attribute.class("page")], [
    ui.header("docs"),
    html.main(
      [attribute.id("main"), attribute.tabindex(-1), attribute.class("docs")],
      [
        html.aside([attribute.class("docs-nav")], [
          html.button(
            [
              attribute.class("menu-toggle"),
              attribute.type_("button"),
              attribute("aria-expanded", case model.menu_open {
                True -> "true"
                False -> "false"
              }),
              event.on_click(msg.ToggleMenu),
            ],
            [
              element.text(case current {
                "" -> "Documentation"
                slug -> title_of(slug)
              }),
              element.text(" · All pages"),
            ],
          ),
          html.nav(
            [
              attribute.class(case model.menu_open {
                True -> "docs-list is-open"
                False -> "docs-list"
              }),
              attribute("aria-label", "Documentation"),
            ],
            [
              html.ul(
                [],
                list.map(pages(), fn(page) {
                  html.li([], [
                    html.a(
                      [
                        attribute.href(route.doc(page.slug)),
                        ..case page.slug == current {
                          True -> [attribute("aria-current", "page")]
                          False -> []
                        }
                      ],
                      [element.text(page.title)],
                    ),
                  ])
                }),
              ),
            ],
          ),
        ]),
        ..content
      ],
    ),
    ui.footer(),
  ])
}
