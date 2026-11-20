//// The session's figures: the context estimate, the session's cost estimate and
//// the output speed of the last timed generation.
////
//// The figures were the top bar's right half. The final design
//// (`docs/design-notes/attention-inbox/final/mockup.html`) gives every page one
//// 44px bar and puts the facts about the session in the stream's own strip
//// (`view/stream_head`), so this module draws them for that strip and for no
//// other place. They are the same figures the terminal's footer shows, worded by
//// `session_view` and handed in as strings, so the page and the terminal cannot
//// disagree.
////
//// The context figure is the summary of a native `<details>`, and the breakdown
//// the daemon read is its body (`view/context_breakdown`), so the browser opens
//// and closes it and the server renders nothing for that. A sibling
//// `<loom-dismiss>` closes the panel on an outside press or Escape; it is a
//// sibling and not a wrapper so the panel's buttons keep their tree paths
//// (`component.context_refresh_path`).
////
//// A figure with no value is not drawn: an empty context draws no `ctx`, and a
//// cost that ends in the dash (`est —`, a model with no price) draws no `est`,
//// since two dashes beside each other read as missing data. The speed's slot is
//// kept with a dimmed dash until a generation long enough to time has settled,
//// so the strip neither jumps when the first sample lands nor looks as if it
//// lost the item.
////
//// Every figure's words are the engine's or the daemon's, drawn as text nodes.
//// Nothing here is built from transcript text.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html

/// The figures as one span: the context figure with its breakdown, the cost and
/// the speed.
///
/// `context` and `cost` are already worded (`ctx ~41%`, `est $0.04`), and
/// `breakdown` is the body the context figure opens. `rate` is the output speed
/// in tokens per second of the last timed generation, or `None` until one has
/// settled.
///
/// ## Examples
///
/// ```gleam
/// // figures.view("ctx ~41%", element.none(), "est $0.04", Some(87))
/// ```
pub fn view(
  context: String,
  breakdown: Element(message),
  cost: String,
  rate: Option(Int),
) -> Element(message) {
  html.span(
    [attribute.class("figures")],
    list.flatten([
      case context {
        "" -> []
        _ -> [
          html.details(
            [
              attribute.class("figure"),
              attribute.class("ctx"),
              attribute.attribute("data-dismiss", "keep"),
            ],
            [
              html.summary(
                [
                  attribute.title(case string.ends_with(context, " —") {
                    True -> "No turn yet on the strand shown"
                    False ->
                      "Estimated context use of the strand shown. Open for the breakdown."
                  }),
                ],
                figure_words(context),
              ),
              breakdown,
            ],
          ),

          // Closes the panel on an outside press or Escape. A sibling and not
          // a wrapper, so the panel's buttons keep their tree paths.
          element.element("loom-dismiss", [], []),
        ]
      },

      // A session whose model has no price has no estimate to give, and two
      // dashes read as missing data. The Session tab, which has a row labelled
      // for the estimate, keeps its dash.
      case cost == "" || string.ends_with(cost, " —") {
        True -> []
        False -> [
          html.span(
            [
              attribute.class("figure"),
              attribute.title("Estimated cost of the session, across strands"),
            ],
            figure_words(cost),
          ),
        ]
      },
      [rate_figure(rate)],
    ]),
  )
}

/// The output-speed figure. A measured rate is drawn like the other figures; no
/// rate is a dash in the quiet colour (`idle`), in the same slot, which the
/// stylesheet gives a fixed width so the figures beside it keep their places.
fn rate_figure(rate: Option(Int)) -> Element(message) {
  case rate {
    Some(tokens) ->
      html.span(
        [
          attribute.class("figure"),
          attribute.class("rate"),
          attribute.title(
            "Output tokens per second of the last timed generation on the strand shown",
          ),
        ],
        [number_element(int.to_string(tokens)), html.text(" tok/s")],
      )
    None ->
      html.span(
        [
          attribute.class("figure"),
          attribute.class("rate"),
          attribute.class("idle"),
          attribute.title(
            "No timed generation yet on the strand shown; the speed appears once one has finished",
          ),
        ],
        [number_element("—"), html.text(" tok/s")],
      )
  }
}

// The emphasised number of a figure. It is a classed span and not a `<b>`:
// the page's tests treat a bare bold tag anywhere in the page as markup that
// escaped from transcript text.
fn number_element(number: String) -> Element(message) {
  html.span([attribute.class("num")], [html.text(number)])
}

/// A figure's label and its number: `ctx ~41%` is the word `ctx` and the
/// emphasised `~41%`. The number is the last token and the label is everything
/// before it, because the cost words carry qualifiers ahead of the marker
/// (`API ref partial est $1.00`, `mixed rates est $2.10`) and only the amount
/// is emphasis. A figure with no space is all emphasis.
fn figure_words(words: String) -> List(Element(message)) {
  case list.reverse(string.split(words, " ")) {
    [number, last_label, ..earlier] -> [
      html.text(string.join(list.reverse([last_label, ..earlier]), " ") <> " "),
      number_element(number),
    ]

    [_] | [] -> [number_element(words)]
  }
}
