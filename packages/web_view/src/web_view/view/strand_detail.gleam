//// One strand's own view, drawn in the Strands tab in place of the list while
//// a strand other than `main` is in focus: a link back to the list, the
//// strand's ring, name and status line, the figures that do not fit on a
//// card, and the tools it ran most recently.
////
//// The list of strand cards stays in the tab beneath this view, hidden by the
//// stylesheet while the view shows (`view/panel`), because the marker relay
//// works by clicking a card (protocol-change/051, the addendum on the marker
//// relay): the back link is a control with no handler that carries the
//// position of `main`'s card, and `<loom-shell>` clicks that card. This
//// module therefore draws no handler at all. `main` has no such view: focusing
//// `main` is `All strands` and shows the list (docs/design-notes/web-design.md,
//// section 3.2).
////
//// The figures are the ones a card leaves out. The model comes from the
//// capture, the context size from the roster and the cache's words from
//// `session_view/cache_miss`, which allows only what the rows proved, so the
//// view claims no more about the cache than the card's ring does. The
//// elapsed time is counted by the browser from the duration the roster
//// measured (`<loom-elapsed>`), so the server never renders again only to
//// move a clock. There is no cost row: the session keeps its cost as a total
//// across strands and no ledger of a strand's own, and a figure the page
//// cannot back is not drawn. A row whose value is not known is left out
//// rather than drawn empty.
////
//// Everything here is derived from the session: the name, the status line, the
//// model and the tool names are drawn as text nodes and never as an
//// attribute, a class or a key. Every class is a whole literal chosen from a
//// closed type. The marker on the back link is the number `0`, fixed here.

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import session_view/strand_card
import web_view/view/strip.{type Chip}

/// The strand's own view for `chip`.
///
/// ## Examples
///
/// ```gleam
/// // strand_detail.view(chip)
/// ```
pub fn view(chip: Chip) -> Element(message) {
  let line = chip.line
  html.div([attribute.class("strand-detail"), strip.hue_class(chip.hue)], [
    html.button(
      [
        attribute.type_("button"),
        attribute.class("detail-back"),
        strip.focus_attribute(0),
      ],
      [html.text("← Strands")],
    ),
    html.div([attribute.class("detail-head")], [
      strip.ring(chip.cache, strip.Detail),
      html.div([attribute.class("detail-title")], [
        html.span([attribute.class("detail-name")], [html.text(line.name)]),
        html.span(
          [attribute.class("chip-status"), strip.status_class(line.status)],
          [html.text(strand_card.status_line(line))],
        ),
      ]),
    ]),
    html.dl([attribute.class("detail-figures")], figures(chip)),
    recent(chip),
  ])
}

// The figures that are known, in a fixed order. A figure that is not known is
// not drawn: an empty row would read as a value.
fn figures(chip: Chip) -> List(Element(message)) {
  list.flatten([
    case chip.model {
      "" -> []
      model -> figure("Model", [html.text(model)])
    },
    case strand_card.context_words(chip.line.tokens) {
      Some(words) -> figure("Context", [html.text(words)])
      None -> []
    },
    case chip.cache {
      Some(#(_, words)) -> figure("Cache", [html.text(words)])
      None -> []
    },
    case chip.running_ms {
      Some(running) ->
        figure("Running", [
          element.element(
            "loom-elapsed",
            [
              attribute.class("elapsed"),
              attribute.attribute("offset", int.to_string(running)),
            ],
            [],
          ),
        ])
      None -> []
    },
  ])
}

fn figure(
  label: String,
  value: List(Element(message)),
) -> List(Element(message)) {
  [
    html.dt([attribute.class("detail-term")], [html.text(label)]),
    html.dd([attribute.class("detail-value")], value),
  ]
}

// The tools the strand ran most recently, newest last as `agent_view` bounds
// them, or a line saying there are none.
fn recent(chip: Chip) -> Element(message) {
  html.section([attribute.class("detail-recent")], [
    html.h3([attribute.class("panel-title")], [html.text("Recent")]),
    case chip.recent {
      [] ->
        html.p([attribute.class("pane-empty")], [html.text("No tools yet.")])
      tools ->
        html.ul(
          [attribute.class("detail-tools")],
          list.map(tools, fn(tool) { html.li([], [html.text(tool)]) }),
        )
    },
  ])
}
