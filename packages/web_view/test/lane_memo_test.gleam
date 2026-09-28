//// The lane's row memos, held to Lustre's own diff.
////
//// Each row of the lane is drawn inside a memo whose one dependency is its
//// piece, so a row is drawn, and its Markdown parsed, only when it first
//// appears or its piece changes. That holds only if Lustre keeps each row's
//// memo element from one render to the next, which it does not for a memo
//// nested inside another memo that hit (`component.lane_rows` says why).
//// These tests count the rows drawn across the renders a page goes through:
//// its first render, a render in which nothing in the lane changed, and a
//// capture that appends a row.
////
//// The renders are Lustre's: the cache the server runtime keeps is built
//// by `lustre/vdom/cache.from_node` and carried by `lustre/vdom/diff.diff`,
//// which the runtime calls for every message it takes. Those modules are
//// internal to Lustre, so the test reaches them through a test-only Erlang
//// module rather than importing them.

import gleam/erlang/process.{type Subject}
import gleam/int
import lane_fixture
import lustre/element.{type Element}
import lustre/element/html
import page_fixture
import session_view/turns
import web_view/component

type Cache

@external(erlang, "lane_memo_ffi", "first")
fn first(view: Element(message)) -> Cache

@external(erlang, "lane_memo_ffi", "rerender")
fn rerender(cache: Cache, old: Element(message), new: Element(message)) -> Cache

fn texts(count: Int) -> List(String) {
  int.range(from: count, to: 0, with: [], run: fn(acc, n) {
    ["**answer " <> int.to_string(n) <> "**", ..acc]
  })
}

fn pieces(count: Int) -> List(turns.Piece) {
  component.new(page_fixture.start())
  |> component.apply([lane_fixture.answered(texts(count))])
  |> component.pieces
}

// How many rows were drawn since the last call.
fn drawn(rows: Subject(Nil)) -> Int {
  case process.receive(rows, 0) {
    Ok(Nil) -> 1 + drawn(rows)
    Error(Nil) -> 0
  }
}

// A prompt and forty answers: the prompt, a turn's work holding thirty-nine
// answers, and the last answer on its own. Appending a forty-first answer
// moves the fortieth into the work and adds the new one, so that capture
// draws two lines, whatever the lane held before.
pub fn an_appended_answer_draws_only_the_lines_it_moved_test() {
  let lines = process.new_subject()
  let draw = fn(_line) {
    process.send(lines, Nil)
    html.text("line")
  }

  // The first render draws the prompt and every answer.
  let first_view = component.lane_rows(pieces(40), draw)
  let cache = first(first_view)
  assert drawn(lines) == 41

  // A render in which the lane did not change draws nothing. This is the
  // render in which an enclosing memo would have hit and dropped the line
  // memos inside it.
  let same_view = component.lane_rows(pieces(40), draw)
  let cache = rerender(cache, first_view, same_view)
  assert drawn(lines) == 0

  // A capture that appends one answer draws the answer it moved into the
  // work and the new answer, and no other line.
  let next_view = component.lane_rows(pieces(41), draw)
  let cache = rerender(cache, same_view, next_view)
  assert drawn(lines) == 2

  // And the lines are still kept on the render after that.
  let _ = rerender(cache, next_view, component.lane_rows(pieces(41), draw))
  assert drawn(lines) == 0
}

// Past the capture window the lane drops its oldest answer as each new one
// arrives, and the turn's work loses its first item. Its key does not name
// that item (`turns` keys work by its input, or by the window's start), so
// the work is matched to itself and only the moved and the new answer are
// drawn, rather than the whole turn.
pub fn a_sliding_window_draws_only_the_new_lines_test() {
  let lines = process.new_subject()
  let draw = fn(_line) {
    process.send(lines, Nil)
    html.text("line")
  }
  let first_view = component.lane_rows(pieces(700), draw)
  let cache = first(first_view)
  let _ = drawn(lines)
  let next_view = component.lane_rows(pieces(701), draw)
  let _ = rerender(cache, first_view, next_view)
  assert drawn(lines) == 2
}
