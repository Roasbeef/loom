//// Historical endpoints stay readable while the authoritative session runs.
//// These fixtures drive the real correlated range replies through the shared
//// lane, rather than inserting historical rows directly into the view.

import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lane_fixture
import lustre/element
import page_fixture
import session_view/session_channel
import session_view/turns
import web_view/component
import web_view/view/lane

fn press(page) {
  page_fixture.run(page, component.update, [component.OlderRequested])
}

fn history_reads(wire) {
  page_fixture.sent(wire)
  |> list.filter(fn(frame) { string.contains(frame, "\"cmd\":\"history\"") })
}

fn running(from, to) {
  lane_fixture.long_running(from, to, Some(lane_fixture.main_op()))
}

fn answer(page, read, from, to, before) {
  let assert session_channel.Captured(cut, _, _) = running(from, to)
    as "history fixture is a capture"
  page_fixture.run(page, component.update, [
    component.Arrived(page_fixture.history(
      page_fixture.request_id(read),
      "operator",
      cut.window,
      before,
    )),
  ])
}

pub fn a_running_turn_can_be_paged_past_its_rendered_limit_test() {
  let wire = process.new_subject()
  let page =
    page_fixture.ready(wire, "operator")
    |> component.apply([running(1001, 1600)])
    |> press
  assert component.browsing(page)
  assert component.live(page) == []
  let assert [read] = history_reads(wire) as "one bounded range read"
  let page = answer(page, read, 1351, 1450, 1451)
  assert component.status(page) == component.Connected
  assert component.top(page) == lane.Earlier
  assert list.length(component.rows(page)) <= component.held_rows
  let assert [first, ..] = component.rows(page) as "history rows"
  assert first.line.text == "step 1351"

  // A fresh cut and a streamed fragment belong to the live endpoint. Neither
  // may change the historical rows or replace their return control.
  let held = component.rows(page)
  let assert session_channel.Captured(archive, _, _) = running(1, 1700)
    as "archive capture"
  let #(page, _) =
    lane_fixture.served(
      page,
      wire,
      list.reverse(archive.window.items),
      running(1601, 1700),
      "operator",
    )
  let page =
    component.apply(page, [
      running(1601, 1700),
      lane_fixture.fragment(
        lane_fixture.generation(1701),
        "text",
        "still working",
      ),
    ])
  assert component.rows(page) == held
  assert component.live(page) == []
  assert string.contains(
    element.to_string(component.view(page)),
    "Jump to latest",
  )

  let page = press(page)
  let #(page, frames) =
    lane_fixture.served(
      page,
      wire,
      list.reverse(archive.window.items),
      running(1601, 1700),
      "operator",
    )
  assert list.any(frames, fn(frame) {
    string.contains(frame, "\"cmd\":\"history\"")
  })
  let assert [first, ..] = component.rows(page) as "older rows"
  assert component.status(page) == component.Connected
  assert first.line.text == "step 1251"
  assert list.length(component.rows(page)) <= component.held_rows

  let page =
    page_fixture.run(page, component.update, [component.LatestRequested])
  assert !component.browsing(page)
  assert list.any(component.rows(page), fn(row) { row.line.text == "step 1700" })
}

pub fn settlement_does_not_move_the_history_endpoint_test() {
  let wire = process.new_subject()
  let page =
    page_fixture.ready(wire, "operator")
    |> component.apply([running(1001, 1600)])
    |> press
  let assert [read] = history_reads(wire) as "history range"
  let page = answer(page, read, 1351, 1450, 1451)
  let held = component.rows(page)
  let page =
    component.apply(page, [lane_fixture.long_running(1601, 1700, None)])
  assert component.browsing(page)
  assert component.rows(page) == held
  assert component.live(page) == []
}

pub fn returning_during_a_history_read_rejects_its_late_reply_test() {
  let wire = process.new_subject()
  let page =
    page_fixture.ready(wire, "operator")
    |> component.apply([running(1001, 1600)])
    |> press
  let assert [read] = history_reads(wire) as "history range in flight"
  let page =
    component.apply(page, [running(1601, 1700)])
    |> page_fixture.run(component.update, [component.LatestRequested])
  let held = component.rows(page)
  let page = answer(page, read, 1351, 1450, 1451)
  assert !component.browsing(page)
  assert component.rows(page) == held
  assert !list.any(component.rows(page), fn(row) {
    row.line.text == "step 1351"
  })
}

pub fn browsing_reaches_the_beginning_at_a_bounded_size_test() {
  let wire = process.new_subject()
  let restore = running(1001, 1600)
  let assert session_channel.Captured(archive, _, _) = running(1, 1600)
    as "complete archive"
  let page =
    page_fixture.ready(wire, "operator") |> component.apply([restore]) |> press
  let page =
    list.fold(
      int.range(from: 16, to: 0, with: [], run: fn(ns, n) { [n, ..ns] }),
      page,
      fn(page, _) {
        let #(page, _) =
          lane_fixture.served(
            page,
            wire,
            list.reverse(archive.window.items),
            restore,
            "operator",
          )
        assert component.status(page) == component.Connected
        assert list.length(component.rows(page)) <= component.held_rows
        press(page)
      },
    )
  assert component.top(page) == lane.Beginning
  assert component.browsing(page)
  let drawn = element.to_string(component.view(page))
  assert string.contains(drawn, "Jump to latest")
  assert string.contains(drawn, "history=\"reading\"")
  let assert [first, ..] = component.rows(page) as "beginning rows"
  assert first.line.text == "start a long run"
}

pub fn switching_strands_preserves_the_historical_endpoint_test() {
  let wire = process.new_subject()
  let restore = running(1001, 1600)
  let assert session_channel.Captured(archive, _, _) = running(1, 1600)
    as "complete archive"
  let page =
    page_fixture.ready(wire, "operator") |> component.apply([restore]) |> press
  let #(page, _) =
    lane_fixture.served(
      page,
      wire,
      list.reverse(archive.window.items),
      restore,
      "operator",
    )
  let held = component.rows(page)
  let #(page, _) = component.focus(page, lane_fixture.child)
  let #(page, _) = component.focus(page, "main")
  assert component.browsing(page)
  assert component.rows(page) == held
}

pub fn a_refused_history_read_keeps_the_endpoint_and_offers_retry_test() {
  let wire = process.new_subject()
  let page =
    page_fixture.ready(wire, "operator")
    |> component.apply([running(1001, 1600)])
    |> press
  let assert [read] = history_reads(wire) as "range to refuse"
  let held = component.rows(page)
  let page =
    page_fixture.run(page, component.update, [
      component.Arrived([page_fixture.refusal(page_fixture.request_id(read))]),
    ])
  assert component.browsing(page)
  assert component.rows(page) == held
  assert component.top(page) == lane.Earlier
}

pub fn historical_turn_folds_can_be_opened_and_closed_test() {
  let wire = process.new_subject()
  let archive = lane_fixture.reading(list.append(list.repeat(10, 50), [200]))
  let midway = list.take(archive, list.length(archive) - 1)
  let capture =
    lane_fixture.since(
      midway,
      list.length(midway) - 599,
      Some(lane_fixture.main_op()),
    )
  let page =
    page_fixture.ready(wire, "operator")
    |> component.apply([capture])
    |> page_fixture.run(component.update, [component.Ticked])
    |> lane_fixture.serve(wire, archive, capture)
    |> press
    |> lane_fixture.serve(wire, archive, capture)
  assert component.browsing(page)
  let assert [fold, ..] =
    component.pieces(page)
    |> list.filter_map(fn(piece) {
      case piece {
        turns.Work(id: Some(id), folding: turns.Folded, ..) -> Ok(id)
        _ -> Error(Nil)
      }
    })
    as "historical page includes a closed turn"
  let held = component.pieces(page)
  let opened =
    page_fixture.run(page, component.update, [component.FoldToggled(fold)])
  assert component.pieces(opened) != held
  assert list.length(component.rows(opened)) <= component.held_rows
  let closed =
    page_fixture.run(opened, component.update, [component.FoldToggled(fold)])
  assert component.pieces(closed) == held
}

pub fn live_advisor_output_does_not_enter_a_historical_page_test() {
  let wire = process.new_subject()
  let restore = running(1001, 1600)
  let assert session_channel.Captured(archive, _, _) = running(1, 1700)
    as "complete archive"
  let items = list.reverse(archive.window.items)
  let page =
    page_fixture.ready(wire, "operator")
    |> component.apply([restore])
    |> press
    |> lane_fixture.serve(wire, items, restore)
  let held = component.pieces(page)
  let fresh =
    lane_fixture.cut(
      lane_fixture.advised(items, 1),
      100,
      [#("main", 1700), #("advisor", 1701)],
      Some(lane_fixture.main_op()),
    )
  let page = component.apply(page, [fresh])
  assert component.browsing(page)
  assert component.pieces(page) == held
}

pub fn paging_never_skips_the_start_of_a_large_tool_group_test() {
  let wire = process.new_subject()
  let archive = lane_fixture.reading([175])
  let midway = list.take(archive, list.length(archive) - 1)
  let capture = lane_fixture.since(midway, 152, Some(lane_fixture.main_op()))
  let page =
    page_fixture.ready(wire, "operator")
    |> component.apply([capture])
    |> page_fixture.run(component.update, [component.Ticked])
    |> lane_fixture.serve(wire, archive, capture)
    |> press
    |> lane_fixture.serve(wire, archive, capture)
    |> press
    |> lane_fixture.serve(wire, archive, capture)
  assert component.browsing(page)
  assert component.top(page) == lane.Beginning
  assert list.length(component.rows(page)) <= component.held_rows
  assert string.contains(element.to_string(component.view(page)), "t1-1.txt")
  assert string.contains(element.to_string(component.view(page)), "t1-25.txt")
}
