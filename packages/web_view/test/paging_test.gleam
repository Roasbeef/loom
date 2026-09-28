//// The page's row window and its paging of older history.
////
//// The page holds the newest `component.live_rows` rows of its strand, cut
//// between turns, and loads older rows when the reader asks, through the
//// `history` read the terminal pages with, up to `component.held_rows`.
//// These tests drive the component with `lane_fixture.conversation`, whose
//// every turn is three rows, and a page fixture whose lane has finished its
//// first transfer, so the frames the page writes are the ones a gateway
//// would receive.

import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/string
import lane_fixture
import lustre/element
import page_fixture
import session_view/connection_event
import session_view/transcript
import web_view/component
import web_view/operator_page
import web_view/view/lane

// The history reads among the frames the page wrote since the last look.
fn reads(wire: page_fixture.Wire) -> List(String) {
  page_fixture.sent(wire)
  |> list.filter(fn(frame) { string.contains(frame, "\"cmd\":\"history\"") })
}

// The catch-ups among the frames the page wrote since the last look.
fn catch_ups(wire: page_fixture.Wire) -> List(String) {
  page_fixture.sent(wire)
  |> list.filter(fn(frame) { string.contains(frame, "\"cmd\":\"catch_up\"") })
}

fn press(page) {
  page_fixture.run(page, operator_page.update, [operator_page.OlderRequested])
}

// The daemon's reply to `read`, the history read the page sent, carrying
// the records of `window`, delivered through the page's lane.
fn answer(page, read: String, window, before: Int) {
  page_fixture.run(page, component.update, [
    component.Arrived(
      page_fixture.history(
        page_fixture.request_id(read),
        "operator",
        window,
        before,
      ),
      0,
    ),
  ])
}

// The daemon's refusal of `read`, delivered through the page's lane.
fn refuse(page, read: String) {
  let id = int.to_string(page_fixture.request_id(read))
  page_fixture.run(page, component.update, [
    component.Arrived(
      [
        connection_event.Incoming(
          "{\"v\":2,\"reply_to\":"
          <> id
          <> ",\"event\":\"error\",\"body\":{\"code\":\"unavailable\",\"message\":\"busy\"}}",
        ),
      ],
      0,
    ),
  ])
}

fn first_text(page) -> String {
  case component.rows(page) {
    [transcript.Row(line:, ..), ..] -> line.text
    [] -> ""
  }
}

// A page following a long conversation holds its newest 150 rows, starting
// at a turn's input, and offers the older ones. When a turn arrives, the
// oldest turn leaves and the page still holds 150 rows.
pub fn the_page_holds_its_newest_rows_test() {
  let page =
    component.new(page_fixture.start())
    |> component.apply([lane_fixture.conversation(1, 1200)])
  assert list.length(component.rows(page)) == component.live_rows
  assert first_text(page) == "question 351"
  assert component.top(page) == lane.Earlier

  let page = component.apply(page, [lane_fixture.conversation(1, 1203)])
  assert list.length(component.rows(page)) == component.live_rows
  assert first_text(page) == "question 352"
}

// A conversation shorter than the window is held whole, and the lane says
// it holds the beginning.
pub fn a_short_conversation_is_held_from_its_beginning_test() {
  let page =
    component.new(page_fixture.start())
    |> component.apply([lane_fixture.conversation(1, 30)])
  assert list.length(component.rows(page)) == 30
  assert component.top(page) == lane.Beginning
}

// The reader's press sends one `history` read for the hundred sequences
// below the oldest record the page holds. While it is out a second press
// sends nothing, since the lane has one request out at a time.
pub fn a_press_sends_one_history_read_test() {
  let wire = process.new_subject()
  let page =
    page_fixture.ready(wire, "operator")
    |> component.apply([lane_fixture.conversation(301, 450)])
  assert component.top(page) == lane.Earlier

  let page = press(page)
  let assert [read] = reads(wire) as "one history read"
  assert string.contains(read, "\"after_seq\":200,\"before_seq\":301")
  assert component.top(page) == lane.Loading
  assert component.paging(page) == component.Paged

  let page = press(page)
  assert reads(wire) == []
  assert component.top(page) == lane.Loading
}

// Captures that land while the read is out do not move the rows the page
// holds; once the page arrives the page follows the session again, from the
// newest capture, with the older rows above.
pub fn the_newest_capture_is_drawn_once_the_page_arrives_test() {
  let wire = process.new_subject()
  let page =
    page_fixture.ready(wire, "operator")
    |> component.apply([lane_fixture.conversation(301, 450)])
    |> press
  let assert [read] = reads(wire) as "one history read"
  let held = component.rows(page)
  let page = component.apply(page, [lane_fixture.conversation(301, 453)])
  assert component.rows(page) == held

  let page = answer(page, read, lane_fixture.older_page(201, 300), 301)
  assert first_text(page) == "question 68"
  assert list.length(component.rows(page)) == 252
  assert component.top(page) == lane.Earlier
}

// The page holds at most 300 rows. A read that would take it past them
// leaves it holding its newest 300, and the lane says it loads no more; a
// press then asks nothing, and new rows still push the oldest out.
//
// The lane refreshes as soon as a page arrives, so a press right after it
// finds the lane busy: the read waits, and goes out in the reduction that
// takes the refresh's reply. The fixture's lane carries an empty session,
// so after that refresh the test puts back the capture a real one would
// have carried.
pub fn a_full_page_loads_no_more_test() {
  let wire = process.new_subject()
  let page =
    page_fixture.ready(wire, "operator")
    |> component.apply([lane_fixture.conversation(301, 450)])
    |> press
  let assert [read] = reads(wire) as "the first read"
  let page = answer(page, read, lane_fixture.older_page(201, 300), 301)
  assert list.length(component.rows(page)) == 249
  let assert [refresh] = catch_ups(wire) as "the lane refreshes"

  let page = press(page)
  assert component.top(page) == lane.Loading
  assert reads(wire) == []

  let page =
    page_fixture.run(page, component.update, [
      component.Arrived(
        page_fixture.catch_up(page_fixture.request_id(refresh), "operator"),
        0,
      ),
    ])
  let assert [read] = reads(wire) as "the second read, once the lane is free"
  assert string.contains(read, "\"after_seq\":100,\"before_seq\":201")

  let page =
    component.apply(page, [lane_fixture.conversation(301, 453)])
    |> answer(read, lane_fixture.older_page(101, 200), 201)
  assert list.length(component.rows(page)) == component.held_rows
  assert first_text(page) == "question 52"
  assert component.top(page) == lane.Full(component.held_rows)
  assert component.paging(page) == component.Full

  let page = press(page)
  assert reads(wire) == []

  let page = component.apply(page, [lane_fixture.conversation(301, 456)])
  assert list.length(component.rows(page)) == component.held_rows
  assert first_text(page) == "question 53"
}

// A refused read retires the demand: the page follows the session again,
// says what happened, and offers the older rows once more.
pub fn a_refused_read_can_be_asked_again_test() {
  let wire = process.new_subject()
  let page =
    page_fixture.ready(wire, "operator")
    |> component.apply([lane_fixture.conversation(301, 450)])
    |> press
  let assert [read] = reads(wire) as "one history read"
  let page = refuse(page, read)
  assert component.top(page) == lane.Earlier
  let assert component.Warned(text) = component.notice(page)
    as "the refusal is stated"
  assert string.contains(text, "unavailable")

  let _ = press(page)
  let assert [_] = reads(wire) as "the read is asked again"
}

// The operator's lane offers a real button marked for `<loom-follow>`; an
// observer's page, whose view attaches no handler, says in words that it
// does not load older rows, and draws no button.
pub fn only_the_operators_lane_offers_the_button_test() {
  let page =
    component.new(page_fixture.start())
    |> component.apply([lane_fixture.conversation(301, 450)])
  let operator = element.to_string(operator_page.view(page))
  assert string.contains(
    operator,
    "<button class=\"load-older\" data-loom-older=\"load\" type=\"button\">Load older</button>",
  )
  let observer = element.to_string(component.view(page))
  assert !string.contains(observer, "<button")
  assert string.contains(observer, "Older rows are not shown.")
}

// The lane refreshes as soon as a page of history arrives. This answers
// that refresh, which carries the fixture lane's empty session, and puts
// back `update`, the capture a real refresh would have carried, so the
// lane is free for the next read.
fn settle(page, wire: page_fixture.Wire, update) {
  let assert [refresh] = catch_ups(wire) as "the lane refreshes"
  page_fixture.run(page, component.update, [
    component.Arrived(
      page_fixture.catch_up(page_fixture.request_id(refresh), "operator"),
      0,
    ),
  ])
  |> component.apply([update])
}

// A turn whose input is more than one read below the page's oldest input
// arrives over several reads. The end of it that a read brings is not
// drawn, since the page starts at an input, but it stays in the history
// window, so the next read asks for the sequences below it rather than
// the same interval again, and the turn is drawn whole once its input
// arrives.
pub fn a_turn_longer_than_one_read_is_loaded_whole_test() {
  let wire = process.new_subject()
  let live = lane_fixture.long_turn(142, 291)
  let page =
    page_fixture.ready(wire, "operator")
    |> component.apply([live])
    |> press
  let assert [read] = reads(wire) as "the first read"
  assert string.contains(read, "\"after_seq\":41,\"before_seq\":142")

  let page = answer(page, read, lane_fixture.long_turn_page(42, 141), 142)
  assert list.length(component.rows(page)) == 150
  assert component.top(page) == lane.Earlier

  let page = settle(page, wire, live) |> press
  let assert [read] = reads(wire) as "the second read goes further down"
  assert string.contains(read, "\"after_seq\":0,\"before_seq\":42")

  let page = answer(page, read, lane_fixture.long_turn_page(1, 41), 42)
  assert list.length(component.rows(page)) == 291
  assert first_text(page) == "question 0"
  assert component.top(page) == lane.Beginning
}

// Another strand can write every sequence of a read. The page then brings
// nothing of its own strand, but the next read still asks for the
// sequences below that interval, and reaches the rest of the strand.
pub fn a_read_that_finds_only_other_strands_moves_on_test() {
  let wire = process.new_subject()
  let live = lane_fixture.gapped(153, 302)
  let page =
    page_fixture.ready(wire, "operator")
    |> component.apply([live])
    |> press
  let assert [read] = reads(wire) as "the first read"
  assert string.contains(read, "\"after_seq\":52,\"before_seq\":153")

  let page = answer(page, read, lane_fixture.gapped_page(53, 152), 153)
  assert list.length(component.rows(page)) == 150
  assert component.top(page) == lane.Earlier

  let page = settle(page, wire, live) |> press
  let assert [read] = reads(wire) as "the second read is below the first"
  assert string.contains(read, "\"after_seq\":0,\"before_seq\":53")

  let page = answer(page, read, lane_fixture.gapped_page(1, 52), 53)
  assert first_text(page) == "question 0"
  assert component.top(page) == lane.Beginning
}

// A strand whose leaf the capture names but whose records it does not hold
// has nothing below the window to read, so the lane offers no button that
// would ask for nothing.
pub fn no_button_when_there_is_nothing_to_read_test() {
  let page =
    component.new(page_fixture.start())
    |> component.apply([lane_fixture.conversation(1, 0)])
  assert component.rows(page) == []
  assert component.top(page) == lane.Beginning
  assert !string.contains(
    element.to_string(operator_page.view(page)),
    "load-older",
  )
}

// A lane that fails with a read out never answers it, so the lane stops
// saying it is loading.
pub fn a_failed_lane_retires_the_read_test() {
  let wire = process.new_subject()
  let page =
    page_fixture.ready(wire, "operator")
    |> component.apply([lane_fixture.conversation(301, 450)])
    |> press
  assert component.top(page) == lane.Loading
  let page =
    page_fixture.run(page, component.update, [
      component.Arrived([connection_event.Closed("gone")], 0),
    ])
  assert component.top(page) != lane.Loading
}
