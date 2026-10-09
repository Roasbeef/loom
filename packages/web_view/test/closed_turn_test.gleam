//// A turn the page has closed is drawn from its summary and from nothing else.
////
//// The page closes each settled turn into a summary and trims the records it
//// summarizes from its window, so the window holds only what is still moving.
//// The advisor's commentary is not trimmed with them. It is projected from the
//// capture's whole window on every capture, as blocks keyed by the advisor's
//// own sequences, so a note the advisor wrote after a turn closed stays among
//// the window's blocks, older than every turn that closes after it. These tests
//// pin that such a block is never drawn, and that it cannot make a later turn
//// be drawn twice, once from its summary and once from the window.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lane_fixture
import lustre/element
import page_fixture
import session_view/snapshot
import session_view/turns
import web_view/component

// The session's records: the fixture's first turn (the records 1 to 10 of
// `main`), then a note the advisor wrote on it (the record 13, on the
// `advisor` strand), then two more turns on `main`, each a question and an
// answer.
fn archive() -> List(snapshot.Item) {
  list.flatten([
    lane_fixture.items(),
    [
      lane_fixture.answered_after(13, Some(10), "advisor: a note on the first"),
      lane_fixture.said_after(14, Some(10), "second question", None),
      lane_fixture.answered_after(15, Some(14), "second answer"),
      lane_fixture.said_after(16, Some(15), "third question", None),
      lane_fixture.answered_after(17, Some(16), "third answer"),
    ],
  ])
}

// What a capture of the session holds once `last` is its newest record: the
// records up to it, with `main` and `advisor` at their leaves.
fn capture(last: Int, running: Bool) {
  let held =
    list.filter(archive(), fn(item) { snapshot.sequence(item) <= last })
  let main = case last > 13 {
    True -> last
    False -> 10
  }
  lane_fixture.cut(
    held,
    100,
    [#("main", main), #("advisor", 13)],
    case running {
      True -> Some(lane_fixture.main_op())
      False -> None
    },
  )
}

// The keys of the pieces the lane draws, in order.
fn keys(page) -> List(String) {
  list.filter_map(component.pieces(page), fn(piece) {
    case piece {
      turns.Commentary(..) -> Error(Nil)
      turns.Plain(block:, ..) | turns.Prompt(block:, ..) -> Ok(block.key)
      turns.Work(key:, ..)
      | turns.Spawned(key:, ..)
      | turns.Returned(key:, ..)
      | turns.Nudged(key:, ..)
      | turns.Peer(key:, ..)
      | turns.Sibling(key:, ..)
      | turns.Missed(key:, ..)
      | turns.Decided(key:, ..) -> Ok(key)
    }
  })
}

// The page after each capture in turn. Each is applied on its own, as the
// daemon delivers them, so the page closes the settled turns between them.
fn arrive(captures) {
  list.fold(captures, component.new(page_fixture.start()), fn(page, update) {
    component.apply(page, [update])
  })
}

fn times(page, text: String) -> Int {
  list.length(string.split(element.to_string(component.view(page)), text)) - 1
}

// A turn that closes after the advisor's note, with the note's block still
// among the window's, is drawn once. Its question appears once, and no two
// pieces of the lane share a key, which a keyed lane needs: a client given the
// same key twice keeps one node for it and leaves the other behind.
pub fn a_turn_closing_after_an_advisors_note_is_drawn_once_test() {
  let page =
    arrive([
      capture(13, False),
      capture(14, True),
      capture(15, False),
      capture(16, True),
      capture(17, False),
    ])
  assert times(page, "second question") == 1
  assert times(page, "third question") == 1
  assert times(page, "third answer") == 1
  let held = keys(page)
  assert list.length(list.unique(held)) == list.length(held)
}

// The note is the advisor's, and the lane draws it in no row however many
// turns close after it.
pub fn the_note_is_drawn_in_no_row_of_the_lane_test() {
  let page =
    arrive([capture(13, False), capture(15, False), capture(17, False)])
  let drawn = element.to_string(component.view(page))
  let assert Ok(#(lane, _)) = string.split_once(drawn, "pane pane-strands")
    as "the page draws the panel after the lane"
  assert !string.contains(lane, "a note on the first")
}
