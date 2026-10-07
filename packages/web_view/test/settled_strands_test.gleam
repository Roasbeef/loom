//// The Strands list's settled group: strands that are no longer running,
//// drawn below the live cards in a group that starts closed, each a card that
//// focuses the strand as a live card does.
////
//// The page tests build sessions from `lane_fixture`, whose strands are
//// `main`, a reviewer, a tester and the advisor, and vary which of them run.
//// The bound on how many settled cards are drawn is the strip's, so it is
//// tested on a strip built by hand, which also lets a card say `Finished` or
//// `Failed`, words the fixture's idle strands never reach.

import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lane_fixture
import lustre/element.{type Element}
import page_fixture
import session_view/agent_roster
import session_view/agent_view
import session_view/turns
import web_view/component
import web_view/view/strip

@external(erlang, "page_events_ffi", "handlers")
fn handlers(view: Element(message)) -> List(String)

fn page(running: List(#(String, String))) {
  component.new(page_fixture.start())
  |> component.apply([lane_fixture.captured_with(10, None, running)])
}

fn html(model) -> String {
  element.to_string(component.view(model))
}

fn focused(model, strand: String) {
  component.update(model, component.FocusRequested(strand)).0
}

// The strip's markup before the settled group and the markup of the group,
// or the whole strip and nothing when it draws no group.
fn split_group(html: String) -> #(String, String) {
  // Only the list is read: the transcript names the strands too.
  let assert Ok(#(_, from_list)) =
    string.split_once(html, "<nav aria-label=\"Agents\"")
    as "a page with strands draws the list"
  let assert Ok(#(cards, _)) = string.split_once(from_list, "</nav>")
    as "the list closes"
  case string.split_once(cards, "settled-group") {
    Ok(#(live, group)) -> #(live, group)
    Error(Nil) -> #(cards, "")
  }
}

// A strip of `settled` chips and the fixed live cards `main` and nothing
// else, so a test reads the group alone.
fn strip_of(settled: List(strip.Chip), earlier: Int) -> strip.Strip {
  strip.Strip(
    chips: [chip("main", agent_view.Idle)],
    advisor: None,
    settled:,
    earlier:,
    followed: "main",
  )
}

fn chip(id: String, status: agent_view.Status) -> strip.Chip {
  strip.Chip(
    line: agent_roster.Line(
      id:,
      name: id,
      status:,
      text: "",
      title: "",
      elapsed_s: None,
      tokens: None,
    ),
    hue: turns.Sub(0),
    cache: None,
    running_ms: None,
    model: "",
    own_model: None,
    recent: [],
    answer: None,
  )
}

fn view(strip: strip.Strip) -> String {
  element.to_string(strip.view(strip, fn(name) { name }))
}

// With every strand running there is nothing to settle: the list is live
// cards, and no group or word for one is drawn.
pub fn a_page_with_only_live_strands_draws_no_group_test() {
  let drawn =
    html(
      page([
        #(lane_fixture.child, lane_fixture.review_op()),
        #(lane_fixture.tester, lane_fixture.tests_op()),
      ]),
    )
  assert !string.contains(drawn, "settled-group")
  assert !string.contains(drawn, "Settled")
}

// With no other strand running, the reviewer and the tester are settled. They
// are listed in reverse row order, the group is a `details` with no `open` attribute
// so it starts closed, and its title counts them.
pub fn a_page_with_only_settled_strands_draws_a_closed_group_test() {
  let drawn = html(page([]))
  let #(live, group) = split_group(drawn)
  assert string.contains(live, ">main<")
  assert string.contains(live, ">advisor<")
  assert !string.contains(live, ">tests<")
  assert string.contains(group, "<details><summary class=\"settled-title\">")
  assert string.contains(group, "Settled · 2")
  assert !string.contains(group, "open")

  // The tester's row follows the reviewer's, so it is listed first.
  let assert Ok(#(before_tests, after_tests)) =
    string.split_once(group, ">tests<")
  assert !string.contains(before_tests, "review")
  assert string.contains(after_tests, "&lt;b&gt;review")

  // Each settled card says how its strand ended and has a button of its own.
  assert string.contains(group, "<span class=\"chip-status done\">")
  assert string.contains(group, "✓</span>Finished</span>")
  assert string.contains(group, "data-loom-card=\"2\"")
  assert string.contains(group, "data-loom-card=\"3\"")
}

// A running strand is a live card and a settled one is in the group, side by
// side, and the settled cards' positions continue the live cards'.
pub fn a_page_with_live_and_settled_strands_draws_both_test() {
  let model = page([#(lane_fixture.tester, lane_fixture.tests_op())])
  let #(live, group) = split_group(html(model))
  assert string.contains(live, ">tests<")
  assert !string.contains(live, "review")
  assert string.contains(group, "&lt;b&gt;review")
  assert !string.contains(group, ">tests<")
  assert string.contains(group, "Settled · 1")

  // Main, the tester and the advisor are positions 0 to 2, the reviewer's
  // settled card is the next.
  let positions = strip.positions(component.strip(model))
  assert dict.get(positions, "main") == Ok(0)
  assert dict.get(positions, lane_fixture.tester) == Ok(1)
  assert dict.get(positions, "advisor") == Ok(2)
  assert dict.get(positions, lane_fixture.child) == Ok(3)
}

// The title and the tab's badge speak of live strands. A settled strand is
// neither running nor waiting, so it is not counted.
pub fn settled_strands_are_not_counted_among_the_live_ones_test() {
  let model = page([])
  assert strip.count(component.strip(model)) == 2
  assert list.length(strip.settled_cards(component.strip(model))) == 2
}

// Each settled card carries a click beneath the strip's list, where the
// observer's socket admits one, and the page draws nothing else that acts.
pub fn a_settled_card_has_a_click_beneath_the_strip_test() {
  let keys = lane_fixture.beyond_dividers(handlers(component.view(page([]))))
  assert list.length(keys) == 4
  assert list.all(keys, fn(key) {
    string.starts_with(key, component.strip_path <> "\t")
    && string.ends_with(key, "\nclick")
  })
  assert list.length(list.unique(keys)) == 4
}

// Pressing a settled strand's card shows that strand and addresses it. While
// it is shown the roster lists it with the live cards, so it leaves the
// group, and it returns to the group when the reader goes back to `main`.
pub fn focusing_a_settled_strand_shows_its_transcript_test() {
  let model = page([#(lane_fixture.tester, lane_fixture.tests_op())])
  let shown = focused(model, lane_fixture.child)
  assert component.strand(shown) == lane_fixture.child

  let #(live, group) = split_group(html(shown))
  assert string.contains(live, "&lt;b&gt;review")
  assert string.contains(live, "aria-current=\"true\"")
  assert group == ""
  assert component.detail(shown) != None

  let back = focused(shown, component.primary)
  assert component.strand(back) == component.primary
  let #(live, group) = split_group(html(back))
  assert !string.contains(live, "review")
  assert string.contains(group, "&lt;b&gt;review")
}

// The strip draws at most `settled_limit` cards and names the rest by count
// in text that is not a card, and the title counts all of them.
pub fn older_settled_strands_are_a_count_and_not_cards_test() {
  let chips =
    list.repeat(Nil, strip.settled_limit)
    |> list.index_map(fn(_, n) {
      chip("done-" <> int.to_string(n), agent_view.Finished)
    })
  let drawn = view(strip_of(chips, 3))
  assert string.contains(drawn, "Settled · 9")
  assert string.contains(drawn, "<li class=\"settled-earlier\">+3 earlier</li>")
  assert count(drawn, "class=\"chip-hit\"") == strip.settled_limit + 1
  assert !string.contains(drawn, "+0 earlier")
}

// A strand that ended in failure says so in words, in the class the
// stylesheet gives failed strands, and no card carries a duration.
pub fn a_settled_card_says_how_the_strand_ended_test() {
  let drawn =
    view(strip_of(
      [chip("bad", agent_view.Failed), chip("good", agent_view.Finished)],
      0,
    ))
  assert string.contains(drawn, "<span class=\"chip-status failed\">")
  assert string.contains(drawn, "×</span>Failed</span>")
  assert string.contains(drawn, "<span class=\"chip-status done\">")
  assert string.contains(drawn, "✓</span>Finished</span>")
  assert !string.contains(drawn, "loom-elapsed")
  assert !string.contains(drawn, "earlier")
}

// A strip with no settled strand draws no group, whatever `earlier` says of
// a strip that was never built that way.
pub fn no_settled_strands_no_group_test() {
  let drawn = view(strip_of([], 3))
  assert !string.contains(drawn, "settled-group")
  assert string.contains(drawn, "data-loom-card=\"0\"")
}

// The group stays the same element when live cards come and go, so a reader
// who opened it does not find it closed: its key is a fixed word and the live
// cards' keys are their positions.
pub fn the_group_is_keyed_by_a_fixed_word_test() {
  let one = view(strip_of([chip("a", agent_view.Idle)], 0))
  let two =
    view(
      strip.Strip(
        ..strip_of([chip("a", agent_view.Idle)], 0),
        chips: [chip("main", agent_view.Idle), chip("x", agent_view.Working)],
        advisor: Some(chip("advisor", agent_view.Idle)),
      ),
    )
  assert string.contains(one, "<li data-lustre-key=\"settled\"")
  assert string.contains(two, "<li data-lustre-key=\"settled\"")
  assert !string.contains(two, "data-lustre-key=\"a\"")
}

fn count(haystack: String, needle: String) -> Int {
  list.length(string.split(haystack, needle)) - 1
}
