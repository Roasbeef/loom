//// The two times of an activity row, as the daemon decodes them for the home
//// page (protocol-change/050, the addendum on times).
////
//// A time is a whole non-negative number of milliseconds and nothing else. A
//// row from an older resident has neither, and a damaged one is the same as a
//// missing one, so a malformed time never costs a session its row.

import client/daemon/server
import core/json
import gleam/list
import gleam/option.{None, Some}
import web_view/sessions

fn row(fields: List(#(String, json.JsonValue))) -> json.JsonValue {
  json.Object([
    #("session_id", json.String("S")),
    #("state", json.String("working")),
    #("last_message", json.String("Done.")),
    ..fields
  ])
}

pub fn both_times_are_read_when_the_row_carries_them_test() {
  assert server.report_of(
      row([
        #("last_message_at", json.Int(1_763_400_000_000)),
        #("turn_started_at", json.Int(1_763_400_060_000)),
      ]),
    )
    == Ok(#(
      "S",
      sessions.Report(
        sessions.Working,
        Some("Done."),
        [],
        Some(1_763_400_000_000),
        Some(1_763_400_060_000),
        asks: 0,
      ),
    ))
}

pub fn a_row_from_an_older_resident_has_no_times_test() {
  assert server.report_of(row([]))
    == Ok(#(
      "S",
      sessions.Report(sessions.Working, Some("Done."), [], None, None, 0),
    ))
}

pub fn a_damaged_time_is_no_time_and_never_costs_the_row_test() {
  assert server.report_of(
      row([
        #("last_message_at", json.String("noon")),
        #("turn_started_at", json.Int(-1)),
      ]),
    )
    == Ok(#(
      "S",
      sessions.Report(sessions.Working, Some("Done."), [], None, None, 0),
    ))
  assert server.report_of(
      row([
        #("last_message_at", json.Null),
        #("turn_started_at", json.Float(1.5)),
      ]),
    )
    == Ok(#(
      "S",
      sessions.Report(sessions.Working, Some("Done."), [], None, None, 0),
    ))
}

// The count of asks waiting on the owner (protocol-change/050, the addendum on
// open asks) is a whole non-negative number or it is none.
pub fn the_count_of_open_asks_is_read_when_the_row_carries_it_test() {
  let assert Ok(#("S", report)) =
    server.report_of(row([#("asks", json.Int(2))]))
  assert report.asks == 2
}

pub fn a_row_from_an_older_resident_has_no_asks_test() {
  let assert Ok(#("S", report)) = server.report_of(row([]))
  assert report.asks == 0
}

pub fn a_damaged_count_of_asks_is_none_and_never_costs_the_row_test() {
  let damaged = [
    json.String("two"),
    json.Int(-1),
    json.Float(1.5),
    json.Null,
    json.Bool(True),
    json.Array([]),
  ]
  list.each(damaged, fn(value) {
    let assert Ok(#("S", report)) = server.report_of(row([#("asks", value)]))
    assert report.asks == 0
    assert report.activity == sessions.Working
  })
}

// The page's narrowing keeps the state and the count and nothing the session
// said.
pub fn the_page_is_given_the_state_and_the_asks_only_test() {
  let reports = fn(_ids) {
    [#("S", sessions.Report(sessions.Idle, Some("Done."), [], None, None, 3))]
  }
  assert server.watches_of(reports)(["S"])
    == [#("S", sessions.Watch(sessions.Idle, 3))]
}
