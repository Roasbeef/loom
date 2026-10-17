//// A `history_search` step on the page: its line says what was searched for
//// and how many hits came back, and the row opens to one line per hit, each
//// naming its session, entry, kind and date before the snippet. The snippets
//// are session text and arrive as text nodes. A record that is not what the
//// tool writes leaves the step with its query and no count.

import gleam/option.{None, Some}
import gleam/string
import lane_fixture
import lustre/element
import page_fixture
import web_view/component
import web_view/operator_page

fn model(details) {
  component.new(page_fixture.start())
  |> component.apply([lane_fixture.recalled(details)])
  |> lane_fixture.opened
}

fn observer(details) -> String {
  model(details)
  |> component.view
  |> element.to_string
  |> string.replace("<!-- lustre:memo -->", "")
}

fn operator(details) -> String {
  model(details)
  |> operator_page.view
  |> element.to_string
  |> string.replace("<!-- lustre:memo -->", "")
}

fn assert_recalled(drawn: String) {
  // The step's line: the verb, the query and the count.
  assert string.contains(drawn, "Searched history for")
  assert string.contains(drawn, "&quot;deploy&quot; · 3 hits")

  // The body lists every hit, a line each, with where it came from.
  assert string.contains(
    drawn,
    "019a3c1e · 456789a1 · assistant · 2025-10-11 · we deploy with make release",
  )
  assert string.contains(
    drawn,
    "019a3c1e · 456789b2 · user · 2025-10-11 · how do I deploy this",
  )
  assert string.contains(drawn, "019b44aa · 000000c3 · note")
  assert !string.contains(drawn, "no hits")

  // A snippet is a text node, never markup.
  assert string.contains(drawn, "never &lt;b&gt;deploy&lt;/b&gt; on a friday")
  assert !string.contains(drawn, "<b>deploy</b>")
}

pub fn the_observer_page_lists_the_hits_test() {
  assert_recalled(observer(Some(lane_fixture.three_hits())))
}

pub fn the_operator_page_lists_the_hits_test() {
  assert_recalled(operator(Some(lane_fixture.three_hits())))
}

pub fn a_search_with_no_details_keeps_its_query_and_no_count_test() {
  let drawn = observer(None)
  assert string.contains(drawn, "Searched history for")
  assert string.contains(drawn, "&quot;deploy&quot;")
  assert !string.contains(drawn, "&quot; · ")

  // The body falls back to the tool's own prose, as any tool's does.
  assert string.contains(drawn, "3 hits from the repository history index.")
}
