//// The event handlers each page registers, read from Lustre's own handler
//// table, which is what the server runtime looks a browser's event up in.
////
//// The observer's page may carry exactly two kinds of handler: the lane's
//// "Load older" click (protocol-change/051, the addendum on history paging)
//// and one click per chip of the agent strip (the addendum on strand focus).
//// The page socket admits an observer's event only at `component.older_path`
//// or beneath `component.strip_path`, so these tests pin that the handlers
//// are exactly there on the observer's page, and at the same paths on the
//// operator's.

import gleam/list
import gleam/option
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

// A handler key is `path ++ "\n" ++ name`; whether the path is beneath the
// strip's list, and the event is a click.
fn is_chip_click(key: String) -> Bool {
  string.starts_with(key, component.strip_path <> "\t")
  && string.ends_with(key, "\nclick")
}

// A page with older rows to load, which is when the button is drawn.
fn paged() {
  component.new(page_fixture.start())
  |> component.apply([lane_fixture.conversation(301, 450)])
}

// A page whose session lists `main`, two working agents and the advisor, so
// the strip has four chips.
fn crowded() {
  component.new(page_fixture.start())
  |> component.apply([lane_fixture.captured(10, option.None)])
}

pub fn the_observers_page_carries_the_older_click_and_the_chips_test() {
  let keys = handlers(component.view(paged()))
  assert list.contains(keys, older_click())

  // Everything else is one chip's click: `main`'s and the advisor's, since no
  // other agent is running in this session.
  let others = list.filter(keys, fn(key) { key != older_click() })
  assert list.length(others) == 2
  assert list.all(others, is_chip_click)
}

pub fn the_operators_older_click_is_at_the_same_path_test() {
  assert list.contains(handlers(operator_page.view(paged())), older_click())
}

// Each strand the strip lists has a click of its own beneath the strip's
// list, and nothing else on an observer's page is a handler: with nothing
// older to load, the chips are all there is.
pub fn an_observer_page_with_nothing_older_carries_only_chips_test() {
  let keys = handlers(component.view(crowded()))
  assert list.length(keys) == 4
  assert list.all(keys, is_chip_click)
  assert list.length(list.unique(keys)) == 4
}

// The operator's page draws the same strip at the same place, so its chips
// are at the same paths, and its other handlers are the composer's and the
// cards'.
pub fn the_operators_chips_are_at_the_same_paths_test() {
  let observer = handlers(component.view(crowded()))
  let operator =
    handlers(operator_page.view(crowded()))
    |> list.filter(is_chip_click)
  assert operator == observer
}

// The transcript's dots and tags, the breadcrumb's link and a strand view's
// back link are controls with no handler: each carries a marker, which
// `<loom-shell>` relays to a card. The page draws them, and the runtime's
// handler table still holds only the cards' clicks (and the older button),
// with a strand in focus and without.
pub fn the_marker_controls_add_no_handler_to_either_page_test() {
  let model = crowded()
  let focused =
    component.update(model, component.FocusRequested(lane_fixture.child)).0
  list.each([model, focused], fn(page) {
    assert string.contains(
      element.to_string(component.view(page)),
      "data-loom-focus",
    )
    let observer = handlers(component.view(page))
    assert list.length(observer) == 4
    assert list.all(observer, is_chip_click)

    let operator =
      handlers(operator_page.view(page))
      |> list.filter(is_chip_click)
    assert operator == observer
  })
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
