//// The lane's row memos, held to Lustre's own diff.
////
//// Each row of the lane is drawn inside a memo whose one dependency is its
//// piece, so a row is drawn, and its Markdown parsed, only when it first
//// appears or its piece changes. That holds only if Lustre keeps each row's
//// memo element from one render to the next, which it does not for a memo
//// nested inside another memo that hit (`lane.rows` says why).
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
import session_view/session_channel
import session_view/turns
import web_view/component
import web_view/view/lane

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
  |> lane_fixture.opened
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
  let first_view =
    lane.rows(
      pieces(40),
      [],
      element.none(),
      draw,
      lane.NoReplies,
      lane.no_marks(),
      lane.NoFolds,
      "",
    )
  let cache = first(first_view)
  assert drawn(lines) == 41

  // A render in which the lane did not change draws nothing. This is the
  // render in which an enclosing memo would have hit and dropped the line
  // memos inside it.
  let same_view =
    lane.rows(
      pieces(40),
      [],
      element.none(),
      draw,
      lane.NoReplies,
      lane.no_marks(),
      lane.NoFolds,
      "",
    )
  let cache = rerender(cache, first_view, same_view)
  assert drawn(lines) == 0

  // A capture that appends one answer draws the answer it moved into the
  // work and the new answer, and no other line.
  let next_view =
    lane.rows(
      pieces(41),
      [],
      element.none(),
      draw,
      lane.NoReplies,
      lane.no_marks(),
      lane.NoFolds,
      "",
    )
  let cache = rerender(cache, same_view, next_view)
  assert drawn(lines) == 2

  // And the lines are still kept on the render after that.
  let _ =
    rerender(
      cache,
      next_view,
      lane.rows(
        pieces(41),
        [],
        element.none(),
        draw,
        lane.NoReplies,
        lane.no_marks(),
        lane.NoFolds,
        "",
      ),
    )
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
  let first_view =
    lane.rows(
      pieces(700),
      [],
      element.none(),
      draw,
      lane.NoReplies,
      lane.no_marks(),
      lane.NoFolds,
      "",
    )
  let cache = first(first_view)
  let _ = drawn(lines)
  let next_view =
    lane.rows(
      pieces(701),
      [],
      element.none(),
      draw,
      lane.NoReplies,
      lane.no_marks(),
      lane.NoFolds,
      "",
    )
  let _ = rerender(cache, first_view, next_view)
  assert drawn(lines) == 2
}

// A page of older history lands above the rows the page holds. The rows
// already drawn keep their keys, so only the rows the page adds are drawn.
//
// The page holds turns 101 to 150 of a conversation whose turns are a prompt,
// one folded step and an answer, three rows each, which is its whole live
// limit. A closed fold draws no step, so the page draws the 100 lines of the
// prompts and the answers. The older page is records 201 to 300: the end of
// turn 67 and turns 68 to 100. The page starts at a turn's input when it can,
// so it leaves out turn 67's answer, whose input is older still, and draws
// the 66 lines of turns 68 to 100. Had it drawn that
// answer, the turn would have been keyed by the window's start, and the
// next page, which brings its input, would have redrawn it under a new key.
pub fn a_page_of_older_rows_draws_only_the_rows_it_adds_test() {
  let lines = process.new_subject()
  let draw = fn(_line) {
    process.send(lines, Nil)
    html.text("line")
  }
  let page =
    page_fixture.ready(process.new_subject(), "operator")
    |> component.apply([lane_fixture.conversation(301, 450)])
  let first_view =
    lane.rows(
      component.pieces(page),
      [],
      element.none(),
      draw,
      lane.NoReplies,
      lane.no_marks(),
      lane.NoFolds,
      "",
    )
  let cache = first(first_view)
  assert drawn(lines) == 100

  // The read goes out from the parent of the oldest record, and its reply
  // lands above what is drawn.
  let page =
    page_fixture.run(page, component.update, [component.OlderRequested])
  assert component.top(page) == lane.Loading
  let page =
    component.apply(page, [
      session_channel.LineagePage(
        lane_fixture.older_page(201, 300),
        lane_fixture.entry_text(300),
      ),
    ])
  let next_view =
    lane.rows(
      component.pieces(page),
      [],
      element.none(),
      draw,
      lane.NoReplies,
      lane.no_marks(),
      lane.NoFolds,
      "",
    )
  let cache = rerender(cache, first_view, next_view)
  assert drawn(lines) == 66

  // A render after the prepend keeps every line.
  let _ =
    rerender(
      cache,
      next_view,
      lane.rows(
        component.pieces(page),
        [],
        element.none(),
        draw,
        lane.NoReplies,
        lane.no_marks(),
        lane.NoFolds,
        "",
      ),
    )
  assert drawn(lines) == 0
}
