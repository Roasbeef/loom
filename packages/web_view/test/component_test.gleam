//// The observer's component reduces what arrives as it arrives: a batch of
//// frames is filed and handed to the lane in the same message, whether the
//// lane was waiting on it or not. Driven with Lustre's simulator, which
//// runs `update` and `view` and performs no effect, so the frames are the
//// ones a gateway would send for one credited transfer and nothing reaches
//// a socket. `delivery_test` drives the real runtime for what the simulator
//// cannot show: how many renders a burst costs, and when the timer fires.

import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/dev/query
import lustre/dev/simulate
import lustre/effect
import lustre/element
import page_fixture
import session_view/connection_event
import session_view/session_channel
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
      arrive(simulate.message(simulation, component.Arrived([frame])), rest)
  }
}

fn wire() {
  process.new_subject()
}

// The lane has a request out from the moment it opens, so every frame of
// the first transfer is a reply it is waiting on, and each is reduced as it
// arrives: the page follows the session without waiting for a tick.
pub fn a_reply_the_lane_awaits_is_reduced_on_arrival_test() {
  let opened = simulate.message(simulation(), component.Opened(wire()))
  assert component.status(simulate.model(opened)) == component.Connecting

  let transferred = arrive(opened, page_fixture.transfer("observer", []))
  assert component.status(simulate.model(transferred)) == component.Following
  assert string.contains(
    element.to_string(simulate.view(transferred)),
    "following",
  )
}

// A push to a lane with nothing out is reduced as it arrives: the capture a
// commit notice calls for is asked in the same message, not at a later
// tick.
pub fn a_push_to_an_idle_lane_is_reduced_on_arrival_test() {
  let following =
    simulate.message(simulation(), component.Opened(wire()))
    |> arrive(page_fixture.transfer("observer", []))
    |> arrive(page_fixture.first_reads_refused())
  assert !in_flight(following)

  let pushed =
    simulate.message(
      following,
      component.Arrived([
        connection_event.Incoming(
          "{\"v\":2,\"event\":\"committed\",\"seq\":11,\"body\":{\"strand\":\"main\"}}",
        ),
      ]),
    )
  assert in_flight(pushed)
}

// A batch is handed to the lane in order in one message: the whole first
// transfer, delivered as one burst, leaves the page following.
pub fn a_batch_is_reduced_in_arrival_order_in_one_message_test() {
  let page =
    simulate.message(simulation(), component.Opened(wire()))
    |> simulate.message(
      component.Arrived(page_fixture.transfer("observer", [])),
    )
  assert component.status(simulate.model(page)) == component.Following
}

fn in_flight(simulation) -> Bool {
  case component.lane(simulate.model(simulation)) {
    Some(lane) -> session_channel.in_flight(lane)
    None -> False
  }
}

pub fn frames_filed_before_the_transport_opens_are_kept_test() {
  // Frames filed before the transport reported open, and a tick that finds
  // no lane, must not lose them: the lane takes them, in order, as soon as
  // it exists.
  let early = arrive(simulation(), page_fixture.transfer("observer", []))
  let idle = simulate.message(early, component.Ticked)
  assert component.status(simulate.model(idle)) == component.Connecting

  let opened = simulate.message(idle, component.Opened(wire()))
  assert component.status(simulate.model(opened)) == component.Following
}

pub fn a_closed_connection_is_drawn_as_it_arrives_test() {
  // The relay tells the component its connection ended before it tells the
  // page's socket, which closes shortly after. The ended state is drawn by
  // the message that carried the close.
  let following =
    simulate.message(simulation(), component.Opened(wire()))
    |> arrive(page_fixture.transfer("observer", []))
  let closed =
    simulate.message(
      following,
      component.Arrived([connection_event.Closed("access was revoked")]),
    )
  assert string.contains(
    element.to_string(simulate.view(closed)),
    "disconnected: access was revoked",
  )
  assert component.status(simulate.model(closed))
    == component.Ended("access was revoked")
}

pub fn a_refused_open_ends_the_page_test() {
  let refused =
    simulate.message(simulation(), component.Refused("access was revoked"))
  assert component.status(simulate.model(refused))
    == component.Ended("access was revoked")
}

// Protocol-change/051, the operator addendum: an observer's page is a fixed
// line with no composer, and a pending escalation draws no card and no
// button. Its one handler, "Load older", is drawn only when older rows
// exist, which this empty session has none of (`paging_test` covers it).
pub fn an_observer_page_has_no_handler_and_no_card_test() {
  let page =
    simulate.message(simulation(), component.Opened(wire()))
    |> arrive(
      page_fixture.transfer("observer", [
        page_fixture.escalation("esc-1", 7, "fs_write", "write the file"),
      ]),
    )
    |> simulate.message(component.Ticked)
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
    simulate.message(simulation(), component.Opened(wire()))
    |> arrive(page_fixture.transfer("observer", []))
    |> simulate.message(component.Ticked)
  let before = simulate.model(page)
  let after = simulate.model(simulate.message(page, component.Ticked))
  assert component.rows(after) == component.rows(before)
  assert component.status(after) == component.status(before)
  assert element.to_string(component.view(after))
    == element.to_string(component.view(before))
}

// The heading names the session by the catalogue's label, with the whole
// identity in its `title`, and the workspace by its last path segment, with
// the whole path in its `title`. Both are escaped.
pub fn the_heading_names_the_session_and_its_workspace_test() {
  let start =
    component.Start(
      ..page_fixture.start(),
      session_id: "0f8e2a41-5d3c-4b7a-9e61-2c4d8b9f1a30",
      label: Some(component.Label(
        name: "review <auth>",
        workspace: "/home/me/src/loom/",
      )),
    )
  let html = element.to_string(component.heading(component.new(start)))
  assert string.contains(
    html,
    "<h1 title=\"0f8e2a41-5d3c-4b7a-9e61-2c4d8b9f1a30\">review &lt;auth&gt;</h1>",
  )
  assert string.contains(
    html,
    "<span class=\"workspace\" title=\"/home/me/src/loom/\">loom</span>",
  )
}

// A session with no name, or whose label the host could not read, is
// named by its identity's first eight characters, and no workspace is
// drawn when none is known.
pub fn a_session_without_a_name_is_named_by_its_short_identity_test() {
  let id = "0f8e2a41-5d3c-4b7a-9e61-2c4d8b9f1a30"
  let unnamed =
    component.Start(
      ..page_fixture.start(),
      session_id: id,
      label: Some(component.Label(name: "", workspace: "")),
    )
  let unknown = component.Start(..page_fixture.start(), session_id: id)
  list.each([unnamed, unknown], fn(start) {
    let html = element.to_string(component.heading(component.new(start)))
    assert string.contains(html, ">Session 0f8e2a41</h1>")
    assert string.contains(html, "title=\"" <> id <> "\"")
    assert !string.contains(html, "class=\"workspace\"")
  })
}

// The lane is drawn inside `<loom-follow>`, the client component that keeps
// the newest row in view, and it carries no attribute: the element reads
// the page's scroll position and the lane's size, never session text.
pub fn the_lane_is_drawn_inside_the_follower_test() {
  let page =
    simulate.message(simulation(), component.Opened(wire()))
    |> arrive(page_fixture.transfer("observer", []))
  let html = element.to_string(simulate.view(page))
  let assert Ok(#(_, inside)) =
    string.split_once(html, "<loom-follow class=\"follow\">")
    as "the page draws the follower with no attribute but its class"
  let assert Ok(#(lane, _)) = string.split_once(inside, "</loom-follow>")
    as "the follower is closed"
  assert string.contains(lane, "class=\"transcript lane\"")
}

// The observer's frame is pinned as the operator's is: the heading and the
// agent strip above the transcript, the read-only bar below it. The
// stylesheet scrolls only the transcript between them.
pub fn the_observers_frame_is_heading_strip_transcript_bar_test() {
  let page =
    simulate.message(simulation(), component.Opened(wire()))
    |> arrive(page_fixture.transfer("observer", []))
  let html = element.to_string(simulate.view(page))
  assert in_order(html, [
    "class=\"session-head\"",
    "class=\"agent-strip\"",
    "<loom-follow class=\"follow\">",
    "class=\"observer-bar\"",
  ])
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
