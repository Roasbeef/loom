//// A failed turn is drawn once, as the session wrote it, however the page came
//// to hold it.
////
//// A run that ended in an error leaves its question and a response that carries
//// the provider's refusal. The page that watched the turn arrive and the page
//// opened afterwards read the same records, so they draw the same rows: one
//// prompt and one failure line for each turn.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lane_fixture
import page_fixture
import session_view/snapshot
import session_view/transcript_line
import web_view/component

// The records of the archive up to a sequence, as a capture of `main` holds them,
// with the strand running when an operation is given.
fn upto(archive: List(snapshot.Item), last: Int, running) {
  lane_fixture.since(
    list.filter(archive, fn(item) { snapshot.sequence(item) <= last }),
    1,
    running,
  )
}

// What the page draws of the turns: how many prompts and how many failure
// lines.
fn counted(page) -> #(Int, Int) {
  let lines = component.lines(page)
  let prompts =
    list.length(
      list.filter(lines, fn(line) { string.starts_with(line.text, "FAIL ") }),
    )
  let failures =
    list.length(
      list.filter(lines, fn(line) { line.speaker == transcript_line.Failure }),
    )
  #(prompts, failures)
}

// A page that watches two turns fail, one after the other, draws each turn's
// prompt and failure once, as a page opened after them does.
pub fn a_failed_turn_is_drawn_once_as_it_arrives_test() {
  let archive = lane_fixture.failing(2)
  let watched =
    component.new(page_fixture.start())
    |> component.apply([
      upto(archive, 1, Some(lane_fixture.op(1))),
      upto(archive, 2, None),
      upto(archive, 3, Some(lane_fixture.op(2))),
      upto(archive, 4, None),
    ])
  let opened =
    component.new(page_fixture.start())
    |> component.apply([upto(archive, 4, None)])
  assert counted(opened) == #(2, 2)
  assert counted(watched) == counted(opened)
  assert list.length(component.pieces(watched))
    == list.length(component.pieces(opened))
}
