//// Which model a session runs, as the page draws it: the main strand's
//// catalogue name beside the session's name in the top bar, and the name on a
//// strand's card only where the strand runs on another model than `main`
//// (protocol-change/076, the addendum on showing the model).
////
//// The names come from the strands' configurations in the capture the page
//// holds, so each test sends the page a real transfer whose metadata lists
//// the strands and the catalogue entry each is configured on.

import gleam/erlang/process
import gleam/list
import gleam/string
import lustre/element
import page_fixture
import web_view/component

// An observer's page whose capture lists `main`, always on the entry `test`,
// and `others`: each a strand and the entry it is configured on.
fn page(others: List(#(String, String))) -> String {
  let wire = process.new_subject()
  let cells =
    list.index_map(others, fn(other, index) {
      page_fixture.configured(other.0, other.1, 4 + index * 3)
    })
    |> list.flatten
  page_fixture.run(
    component.new(page_fixture.start()),
    component.update,
    list.flatten([
      [component.Opened(wire)],
      list.map(page_fixture.transfer("observer", cells), fn(frame) {
        component.Arrived([frame])
      }),
      [component.Ticked],
    ]),
  )
  |> page_fixture.refuse_reads(component.update, wire, component.Arrived)
  |> component.view
  |> element.to_string
}

fn occurrences(html: String, needle: String) -> Int {
  list.length(string.split(html, needle)) - 1
}

// The bar names the main strand's model in the catalogue's words beside the
// session's name, once, and the upstream identifier the entry maps to is not
// drawn there.
pub fn the_bar_names_the_main_strands_model_test() {
  let html = page([])
  assert string.contains(
    html,
    "<span class=\"session-model\" title=\"Model the main strand runs on\">test</span>",
  )
  assert occurrences(html, "class=\"session-model\"") == 1
  assert !string.contains(html, "upstream/test")
}

// A card names a model only where it is not the main strand's. Here the
// advisor runs on another entry and the sub-agent shares `main`'s, so one card
// says so and the sub-agent's and `main`'s say nothing.
pub fn a_card_names_a_model_only_when_it_differs_from_main_test() {
  let html =
    page([#("advisor", "baseten-deepseek-v41"), #("sub:main/worker", "test")])
  assert occurrences(html, "class=\"chip-model\"") == 1
  assert string.contains(
    html,
    "<span class=\"chip-model\">baseten-deepseek-v41</span>",
  )

  // The advisor's card is the one that carries it, after its status.
  let assert Ok(#(_, after)) = string.split_once(html, ">advisor</span>")
  let assert Ok(#(card, _)) = string.split_once(after, "</li>")
  assert string.contains(card, "chip-model")
}

// Every strand on the main strand's model leaves the strip as it was.
pub fn strands_on_the_main_model_draw_no_model_test() {
  let html = page([#("advisor", "test"), #("sub:main/worker", "test")])
  assert !string.contains(html, "chip-model")
}

// The catalogue's names are the owner's, but a card draws one as a text node
// like any other value: markup in it is escaped.
pub fn a_models_name_is_drawn_as_text_test() {
  let html = page([#("advisor", "<i>fast</i>")])
  assert string.contains(
    html,
    "<span class=\"chip-model\">&lt;i&gt;fast&lt;/i&gt;</span>",
  )
  assert !string.contains(html, "<i>fast")
}
