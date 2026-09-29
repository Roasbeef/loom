//// The event handlers each page registers, read from Lustre's own handler
//// table, which is what the server runtime looks a browser's event up in.
////
//// The observer's page may carry exactly one handler: the lane's "Load
//// older" click (protocol-change/051, the addendum on history paging). The
//// page socket admits an observer's event only at `component.older_path`,
//// so these tests pin that the handler is there, alone, on the observer's
//// page, and at the same path on the operator's.

import gleam/list
import gleam/string
import lane_fixture
import lustre/element.{type Element}
import page_fixture
import web_view/component
import web_view/operator_page

@external(erlang, "page_events_ffi", "handlers")
fn handlers(view: Element(message)) -> List(String)

fn older_click() -> String {
  component.older_path <> "\n" <> "click"
}

// A page with older rows to load, which is when the button is drawn.
fn paged() {
  component.new(page_fixture.start())
  |> component.apply([lane_fixture.conversation(301, 450)])
}

pub fn the_observers_page_carries_only_the_older_click_test() {
  assert handlers(component.view(paged())) == [older_click()]
}

pub fn the_operators_older_click_is_at_the_same_path_test() {
  assert list.contains(handlers(operator_page.view(paged())), older_click())
}

// With nothing older to load, the observer's page carries no handler.
pub fn an_observer_page_with_nothing_older_carries_no_handler_test() {
  let page =
    component.new(page_fixture.start())
    |> component.apply([lane_fixture.conversation(1, 30)])
  assert handlers(component.view(page)) == []
}

// The composer's list and its keys run in the browser, in `<loom-composer>`,
// which listens to the editor and submits the form. None of that reaches the
// server as an event of its own: the operator's page still registers only
// the click and the submit that `ui_socket.operator_accepts` admits, with an
// approval pending and the composer's editor in the tree.
pub fn the_operators_page_registers_only_clicks_and_submits_test() {
  let page =
    component.new(page_fixture.start())
    |> component.apply([lane_fixture.conversation(301, 450)])
  let names =
    handlers(operator_page.view(page))
    |> list.map(fn(key) {
      let assert Ok(name) = list.last(string.split(key, "\n"))
        as "a handler key ends in its event name"
      name
    })
    |> list.unique
  assert list.sort(names, string.compare) == ["click", "submit"]
}
