//// Which model a session runs, as the page draws it: the main strand's
//// catalogue name beside the session's name in the top bar and in the stream's
//// strip, and the name on every strand's card
//// (protocol-change/076, the addendum on showing the model; every card names
//// its model since 2026-11-23).
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

// The strip above the stream names the model of the strand on screen, which on
// a fresh page is main's.
pub fn the_strip_names_the_strand_on_screens_model_test() {
  let html = page([#("advisor", "baseten-deepseek-v41")])
  assert string.contains(
    html,
    "<span class=\"stream-model\" title=\"Model this strand runs on\"> · test</span>",
  )
}

// Every live strand's card names its model, whether or not it is the main
// strand's, so a reader never opens a strand to learn it.
pub fn every_card_names_its_model_test() {
  let html =
    page([#("advisor", "baseten-deepseek-v41"), #("sub:main/worker", "test")])
  assert string.contains(
    html,
    "<span class=\"chip-model\">baseten-deepseek-v41</span>",
  )

  // The advisor's card carries its own model, after its status.
  let assert Ok(#(_, after)) = string.split_once(html, ">advisor</span>")
  let assert Ok(#(card, _)) = string.split_once(after, "</li>")
  assert string.contains(card, "chip-model")
  assert occurrences(html, "<span class=\"chip-model\">test</span>") >= 2
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
