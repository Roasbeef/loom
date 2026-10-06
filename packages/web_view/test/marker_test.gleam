//// The controls that focus a strand without a handler of their own, and what
//// they point at: the timeline's dots and tags, the breadcrumb, a strand's
//// own view and the cards they all press (protocol-change/051, the addendum
//// on the marker relay).
////
//// The relay itself runs in the browser (`<loom-shell>`), so these tests read
//// the markup the server writes for it. What they pin is what the server owes
//// the element: a marker is a number and nothing else, it is the position of
//// the card that focuses the same strand, a control for a strand the page does
//// not list is not a control, the strand on screen has none, and none of them
//// has a handler. That no handler is drawn is also pinned from the runtime's
//// side, in `page_events_test`.

import gleam/dict
import gleam/list
import gleam/option.{None}
import gleam/string
import lane_fixture
import lustre/element
import page_fixture
import session_view/agent_roster
import session_view/agent_view
import session_view/cache_miss
import session_view/turns
import web_view/component
import web_view/operator_page
import web_view/view/strand_detail
import web_view/view/strip

fn page(running: List(#(String, String))) {
  component.new(page_fixture.start())
  |> component.apply([lane_fixture.captured_with(10, None, running)])
}

// The page as the fixture draws it: `main` on screen, the reviewer and the
// tester running, the advisor listed. Their cards are positions 0 to 3.
fn settled() {
  page([
    #(lane_fixture.child, lane_fixture.review_op()),
    #(lane_fixture.tester, lane_fixture.tests_op()),
  ])
}

fn focused(model, strand: String) {
  component.update(model, component.FocusRequested(strand)).0
}

fn observer(model) -> String {
  element.to_string(component.view(model))
}

fn operator(model) -> String {
  element.to_string(operator_page.view(model))
}

fn count(haystack: String, needle: String) -> Int {
  list.length(string.split(haystack, needle)) - 1
}

// Whether each part appears in `html` after the one before it.
fn in_order(html: String, parts: List(String)) -> Bool {
  case parts {
    [] -> True
    [part, ..rest] ->
      case string.split_once(html, part) {
        Ok(#(_, after)) -> in_order(after, rest)
        Error(Nil) -> False
      }
  }
}

// Every value a marker attribute holds in `html`.
fn values(html: String, name: String) -> List(String) {
  string.split(html, name <> "=\"")
  |> list.drop(1)
  |> list.map(fn(rest) {
    case string.split_once(rest, "\"") {
      Ok(#(value, _)) -> value
      Error(Nil) -> rest
    }
  })
}

fn is_number(value: String) -> Bool {
  value != ""
  && list.all(string.to_graphemes(value), fn(grapheme) {
    string.contains("0123456789", grapheme)
  })
}

// A row of the timeline is a dot and the piece. The dot is decoration, a span
// hidden from assistive technology, in the hue of the strand the piece belongs
// to; where that is another strand the page lists it holds the number of that
// strand's card, and the tag in the piece holds the same one.
pub fn a_dot_and_a_tag_hold_the_position_of_the_strand_they_name_test() {
  let html = observer(settled())

  // The spawn and its result belong to the reviewer, whose card is the second.
  assert in_order(html, [
    "class=\"tl-row hue-2\">",
    "<span aria-hidden=\"true\" class=\"dot\" data-loom-focus=\"1\"></span>",
    "Spawned ",
    "<button class=\"tag\" data-loom-focus=\"1\" type=\"button\">&lt;b&gt;review</button>",
    "class=\"tl-row hue-2\">",
    "<span aria-hidden=\"true\" class=\"dot\" data-loom-focus=\"1\"></span>",
    "<button class=\"tag\" data-loom-focus=\"1\" type=\"button\">&lt;b&gt;review</button>",
    " finished",
  ])

  // The nudge belongs to the advisor, whose card is last.
  assert in_order(html, [
    "class=\"tl-row hue-advisor\">",
    "<span aria-hidden=\"true\" class=\"dot\" data-loom-focus=\"3\"></span>",
    "<button class=\"tag\" data-loom-focus=\"3\" type=\"button\">advisor</button>",
    " · nudge · delivered",
  ])

  // The operator's page draws the same rows.
  assert string.contains(
    operator(settled()),
    "<span aria-hidden=\"true\" class=\"dot\" data-loom-focus=\"1\"></span>",
  )
}

// The number is the card's position, so the card a marker names is the
// strand's own: the reviewer's card is the second and says so.
pub fn a_marker_names_the_card_of_the_same_strand_test() {
  let html = observer(settled())
  let assert Ok(#(_, from_second)) =
    string.split_once(html, "data-loom-card=\"1\"")
  let assert Ok(#(second, _)) =
    string.split_once(from_second, "data-loom-card=\"2\"")
  assert string.contains(second, "&lt;b&gt;review")
  assert !string.contains(second, ">tests<")

  let assert Ok(#(_, from_last)) =
    string.split_once(html, "data-loom-card=\"3\"")
  assert string.contains(from_last, ">advisor<")
}

// Position zero is `main`, wherever `main` is listed: the marker of `All
// strands` is the constant zero and the shell treats it so.
pub fn position_zero_is_main_test() {
  let positions = strip.positions(component.strip(settled()))
  assert dict.get(positions, "main") == Ok(0)
  assert dict.get(positions, "advisor") == Ok(3)
}

// A marker is a number and nothing else: no identity the daemon minted, no
// name the session wrote, whatever the strand is called. The fixture's names
// hold markup and a minted slug, which reach the page as text and never as
// the value of a marker.
pub fn a_marker_is_only_ever_a_number_test() {
  list.each([observer(settled()), operator(settled())], fn(html) {
    let markers = values(html, "data-loom-focus")
    assert markers != []
    assert list.all(markers, is_number)
    let cards = values(html, "data-loom-card")
    assert list.length(cards) == 4
    assert list.all(cards, is_number)

    assert !string.contains(html, "data-loom-focus=\"main\"")
    assert !string.contains(html, "data-loom-card=\"main\"")
  })
}

// The strand on screen has no marker on its own rows: focusing what is
// already shown does nothing, so its dots are decoration. On `main`, only the
// three pieces that belong to other strands are controls.
pub fn the_strand_on_screen_has_no_marked_rows_test() {
  let html = observer(settled())
  let rows = count(html, "class=\"tl-row ")
  let marked = count(html, "class=\"dot\" data-loom-focus")
  assert rows > marked
  assert marked == 3
  assert count(html, "class=\"tag\"") == 3

  // Focused on the reviewer, the same pieces belong to a strand on screen or
  // to `main`, which is another strand and is listed.
  let reviewing = observer(focused(settled(), lane_fixture.child))
  assert !string.contains(reviewing, "class=\"dot\" data-loom-focus=\"1\"")
}

// A settled strand is a card in the settled group, so its tag is a control
// and holds the position of that card, which follows the live cards'. The
// group is closed until the reader opens it, but the relay presses the card
// with a script click, so the control works either way.
pub fn a_settled_strand_is_a_control_pointing_at_its_card_test() {
  // The reviewer settled and left the live cards: only the tester is running.
  let model = page([#(lane_fixture.tester, lane_fixture.tests_op())])
  let html = observer(model)
  let positions = strip.positions(component.strip(model))
  let assert Ok(reviewer) = dict.get(positions, lane_fixture.child)
  assert reviewer == 3
  assert string.contains(
    html,
    "<button class=\"tag\" data-loom-focus=\"3\" type=\"button\">&lt;b&gt;review</button>",
  )
  assert string.contains(html, "data-loom-card=\"3\"")

  // The advisor is still listed, and its nudge is still a control.
  assert string.contains(html, ">advisor</button> · nudge · delivered")
}

// A dot is never a button and never a tab stop: it is a span the assistive
// technology skips, and the same action is on the cards and the tags, which
// are buttons.
pub fn a_dot_is_a_span_and_never_a_button_test() {
  let html = observer(settled())
  assert count(html, "class=\"dot\"") > 0
  assert !string.contains(html, "<button aria-hidden")
  assert !string.contains(html, "tabindex")
  assert count(html, "<span aria-hidden=\"true\" class=\"dot\"")
    == count(html, "class=\"dot\"")
}

// While `main` is on screen there is no breadcrumb and no strand view: the
// centre's first child is the transcript's scroller, and the Strands pane is
// the list.
pub fn main_has_neither_a_breadcrumb_nor_a_view_test() {
  let html = observer(settled())
  assert !string.contains(html, "class=\"crumb\"")
  assert !string.contains(html, "strand-detail")
  assert !string.contains(html, "pane-strands detailed")
  assert component.detail(settled()) == None
}

// Focused on a strand, the page draws the breadcrumb first in the centre, and
// the strand's own view in the Strands tab in place of the list. The link
// back to `main` in both is a marker with no handler.
pub fn a_focused_strand_has_a_breadcrumb_and_a_view_test() {
  let html = observer(focused(settled(), lane_fixture.child))

  assert in_order(html, [
    "<main class=\"centre\">",
    "<nav aria-label=\"Focused strand\" class=\"crumb\" data-loom-crumb>",
    "Session A",
    "&lt;b&gt;review",
    "<button class=\"crumb-all\" data-loom-focus=\"0\" type=\"button\">All strands</button>",
    "<kbd class=\"crumb-hint\">Esc</kbd>",
    "<loom-follow class=\"follow\" data-strand-key=\"",
  ])

  // The Strands pane carries the strand's view after the list, and says so, so
  // the stylesheet hides the title and the list and the cards stay in the page
  // for the relay to press.
  assert in_order(html, [
    "pane pane-strands detailed",
    "class=\"agent-strip\"",
    "data-loom-card=\"1\"",
    "class=\"strand-detail hue-2\"",
    "<button class=\"detail-back\" data-loom-focus=\"0\" type=\"button\">← Strands</button>",
    "avatar avatar-detail",
    "&lt;b&gt;review",
    "class=\"detail-figures\"",
    "Recent",
  ])
  assert count(html, "data-loom-card=\"") == 4
}

// The figures a card leaves out are the ones a strand's own view draws. The
// reviewer is running, so it has a model, a context size and a duration, and
// no row is a cost: the session keeps its cost as one total, not per strand.
pub fn a_strands_view_draws_the_figures_it_knows_test() {
  let html = observer(focused(settled(), lane_fixture.child))
  // The fixture's capture names no model, so there is no Model row.
  assert !string.contains(html, "<dt class=\"detail-term\">Model</dt>")
  assert in_order(html, [
    "<dt class=\"detail-term\">Context</dt>",
    "<dt class=\"detail-term\">Running</dt>",
    "loom-elapsed",
  ])
  assert !string.contains(html, "<dt class=\"detail-term\">Cost</dt>")
}

fn chip(
  model: String,
  tokens: option.Option(Int),
  cache: option.Option(#(cache_miss.Outlook, String)),
  running: option.Option(Int),
  recent: List(String),
) -> strip.Chip {
  strip.Chip(
    line: agent_roster.Line(
      id: "sub:main/x",
      name: "sub:x",
      status: agent_view.Working,
      text: "reading",
      title: "",
      elapsed_s: None,
      tokens:,
    ),
    hue: turns.Sub(0),
    cache:,
    running_ms: running,
    model:,
    recent:,
    answer: option.None,
  )
}

// A figure that is not known is left out and not drawn as an empty row, which
// would read as a value; a strand that ran nothing says so.
pub fn a_figure_that_is_not_known_is_not_drawn_test() {
  let bare =
    element.to_string(strand_detail.view(chip("", None, None, None, [])))
  assert !string.contains(bare, "Model")
  assert !string.contains(bare, "Cache")
  assert !string.contains(bare, "loom-elapsed")

  // A context the roster does not report is said so, not left a blank.
  assert string.contains(bare, "not reported")
  assert string.contains(bare, "No tools yet.")
  assert string.contains(bare, "Working · reading")

  let full =
    element.to_string(
      strand_detail.view(
        chip(
          "glm-5.2",
          option.Some(136_540),
          option.Some(#(cache_miss.Expired, "cache expired")),
          option.Some(7000),
          ["fs_read", "fs_edit <b>"],
        ),
      ),
    )
  assert string.contains(full, "<span title=\"glm-5.2\">glm-5.2</span>")
  assert !string.contains(full, "not reported")
  assert string.contains(full, "136.5k tokens")
  assert string.contains(full, "<dd class=\"detail-value\">cache expired</dd>")
  assert string.contains(full, "offset=\"7000\"")
  assert string.contains(full, "<li>fs_read</li>")

  // A tool name is session text and arrives escaped.
  assert string.contains(full, "<li>fs_edit &lt;b&gt;</li>")
  assert !string.contains(full, "<b>")
}

// The list is not replaced in the page by the view, only hidden by the
// stylesheet: every card is still drawn, so the relay always has the card it
// is asked to press.
pub fn the_cards_stay_in_the_page_beneath_a_view_test() {
  let listed = observer(settled())
  let viewing = observer(focused(settled(), lane_fixture.child))
  assert count(listed, "class=\"chip-hit\"") == 4
  assert count(viewing, "class=\"chip-hit\"") == 4
}

// The breadcrumb and the view hold no handler and no form, and an observer
// who has focused a strand still holds no control that acts.
pub fn the_marker_controls_carry_no_handler_test() {
  let html = observer(focused(settled(), lane_fixture.child))
  let markers = count(html, "data-loom-focus=\"")
  assert markers >= 2
  assert !string.contains(html, "<form")
  assert !string.contains(html, "<textarea")
}
