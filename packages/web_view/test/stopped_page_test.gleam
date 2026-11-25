//// A session page whose own session stopped (protocol-change/051, the
//// addendum on an ended page).
////
//// The page is sent no more reads once it ends, so the listing it holds still
//// names its own session as running. The rail's count, its "Watch live" rows
//// and the sidebar's groups are all drawn from `session_groups`, so they must
//// agree that the stopped session is no longer running.

import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/string
import lane_fixture
import page_fixture
import session_view/connection_event
import web_view/component
import web_view/ending
import web_view/listing
import web_view/sessions.{type Entry, Entry, Live}

// The page is on session `A`, and two other sessions run beside it.
fn listing() -> List(Entry) {
  [
    Entry(
      "B",
      "vetting lint",
      "/src/loom",
      300,
      Live,
      None,
      None,
      None,
      None,
      sessions.Ordinary,
    ),
    Entry(
      "A",
      "web ui",
      "/src/loom",
      100,
      Live,
      None,
      None,
      None,
      None,
      sessions.Ordinary,
    ),
    Entry(
      "C",
      "census",
      "/src/loom",
      50,
      Live,
      None,
      None,
      None,
      None,
      sessions.Ordinary,
    ),
  ]
}

fn listed() -> component.Model(page_fixture.Wire) {
  let model =
    page_fixture.start()
    |> component.new
    |> component.apply([lane_fixture.captured(10, None)])
  let #(model, _) = component.update(model, component.SessionsListed(listing()))
  model
}

fn stopped() -> component.Model(page_fixture.Wire) {
  let #(opened, _) =
    component.update(listed(), component.Opened(process.new_subject()))
  let #(stopped, _) =
    component.update(
      opened,
      component.Arrived([
        connection_event.Closed(ending.reason(ending.SessionStopped)),
      ]),
    )
  stopped
}

// The ids of the sessions the sidebar draws as running.
fn running_ids(model: component.Model(page_fixture.Wire)) -> List(String) {
  listing.entries(component.session_groups(model))
  |> list.filter(fn(entry) { entry.residency == Live })
  |> list.map(fn(entry) { entry.id })
}

// While the page is connected every running row counts, its own included.
pub fn a_connected_page_counts_every_running_session_test() {
  assert component.running_count(listed()) == 3
  assert list.length(running_ids(listed())) == 3
}

// A stop ends the page for good. The count, the running rows and the
// "Watch live" lines all lose the page's own session together, and its row
// moves to the sessions that are not running.
pub fn a_stopped_page_agrees_on_what_still_runs_test() {
  let model = stopped()
  assert component.final_ending(model) == Some(ending.SessionStopped)
  assert component.running_count(model) == 2
  assert list.sort(running_ids(model), fn(a, b) { string_order(a, b) })
    == ["B", "C"]
  assert list.sort(dict.keys(component.session_watching(model)), fn(a, b) {
      string_order(a, b)
    })
    == ["B", "C"]
  let own =
    listing.entries(component.session_groups(model))
    |> list.find(fn(entry) { entry.id == "A" })
  assert option.from_result(own)
    |> option.map(fn(entry) { entry.residency })
    == Some(sessions.Saved)
}

fn string_order(a: String, b: String) -> order.Order {
  string.compare(a, b)
}
