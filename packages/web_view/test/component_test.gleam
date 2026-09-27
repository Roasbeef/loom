//// The observer's component keeps option C: an arriving frame is filed and
//// changes nothing on the page until a tick hands it to the lane. Driven
//// with Lustre's simulator, which runs `update` and `view` and performs no
//// effect, so the frames are the ones a gateway would send for one credited
//// transfer and nothing reaches a socket.

import gleam/erlang/process
import gleam/list
import gleam/string
import lustre/dev/query
import lustre/dev/simulate
import lustre/effect
import lustre/element
import page_fixture
import session_view/connection_event
import web_view/component

fn simulation() {
  simulate.application(
    init: fn(start) { #(component.new(start), effect.none()) },
    update: component.update,
    view: component.view,
  )
  |> simulate.start(page_fixture.start())
}

fn arrive(simulation, frames: List(connection_event.Message)) {
  case frames {
    [] -> simulation
    [frame, ..rest] ->
      arrive(simulate.message(simulation, component.Arrived(frame)), rest)
  }
}

fn wire() {
  process.new_subject()
}

pub fn arrivals_are_filed_and_reduced_only_at_a_tick_test() {
  let opened = simulate.message(simulation(), component.Opened(wire(), 0))
  let filed = arrive(opened, page_fixture.transfer("observer", []))

  // Every frame of a complete transfer has arrived, and the page still says
  // it is connecting: nothing was reduced.
  assert component.status(simulate.model(filed)) == component.Connecting
  assert string.contains(element.to_string(simulate.view(filed)), "connecting")

  let ticked = simulate.message(filed, component.Ticked(0))
  assert component.status(simulate.model(ticked)) == component.Following
  assert string.contains(element.to_string(simulate.view(ticked)), "following")
}

pub fn a_tick_before_the_transport_opens_keeps_what_was_filed_test() {
  // Frames filed before the transport reported open, and a tick that finds
  // no lane, must not lose them: the first tick with a lane reduces them.
  let early = arrive(simulation(), page_fixture.transfer("observer", []))
  let idle = simulate.message(early, component.Ticked(0))
  assert component.status(simulate.model(idle)) == component.Connecting

  let opened = simulate.message(idle, component.Opened(wire(), 0))
  let ticked = simulate.message(opened, component.Ticked(0))
  assert component.status(simulate.model(ticked)) == component.Following
}

pub fn a_closed_connection_is_drawn_at_the_next_tick_test() {
  // The relay tells the component its connection ended before it tells the
  // page's socket, which closes two ticks later. The ended state is drawn
  // by the first of them.
  let ticked =
    simulate.message(simulation(), component.Opened(wire(), 0))
    |> arrive(page_fixture.transfer("observer", []))
    |> simulate.message(component.Ticked(0))
  let closed =
    simulate.message(
      ticked,
      component.Arrived(connection_event.Closed("access was revoked")),
    )
  assert component.status(simulate.model(closed)) == component.Following

  let drawn = simulate.message(closed, component.Ticked(250))
  assert string.contains(
    element.to_string(simulate.view(drawn)),
    "disconnected",
  )
}

pub fn a_refused_open_ends_the_page_test() {
  let refused =
    simulate.message(simulation(), component.Refused("access was revoked"))
  assert component.status(simulate.model(refused))
    == component.Ended("access was revoked")
}

// Protocol-change/051, the operator addendum: an observer's page is a fixed
// line and attaches no handler, so there is nothing a browser can fire, and
// a pending escalation draws no card and no button.
pub fn an_observer_page_has_no_handler_and_no_card_test() {
  let page =
    simulate.message(simulation(), component.Opened(wire(), 0))
    |> arrive(
      page_fixture.transfer("observer", [
        page_fixture.escalation("esc-1", 7, "fs_write", "write the file"),
      ]),
    )
    |> simulate.message(component.Ticked(0))
  let html = element.to_string(simulate.view(page))
  assert string.contains(html, "Observer · read-only")
  assert !string.contains(html, "<button")
  assert !string.contains(html, "<form")
  assert !string.contains(html, "<textarea")

  let clicked =
    simulate.click(page, on: query.element(query.class("observer-bar")))
  let assert Ok(simulate.Problem(name: "EventHandlerNotFound", ..)) =
    list.last(simulate.history(clicked))
    as "an observer page holds no click handler"

  let submitted =
    simulate.submit(page, on: query.element(query.tag("main")), fields: [
      #("draft", "hello"),
    ])
  let assert Ok(simulate.Problem(name: "EventHandlerNotFound", ..)) =
    list.last(simulate.history(submitted))
    as "an observer page holds no submit handler"
}

// Guide §4: a tick that brought nothing new changes nothing the view reads,
// so Lustre's diff of the memoized transcript is empty.
pub fn an_idle_tick_leaves_the_model_as_it_was_test() {
  let page =
    simulate.message(simulation(), component.Opened(wire(), 0))
    |> arrive(page_fixture.transfer("observer", []))
    |> simulate.message(component.Ticked(0))
  let before = simulate.model(page)
  let after = simulate.model(simulate.message(page, component.Ticked(0)))
  assert component.rows(after) == component.rows(before)
  assert component.status(after) == component.status(before)
  assert element.to_string(component.view(after))
    == element.to_string(component.view(before))
}
