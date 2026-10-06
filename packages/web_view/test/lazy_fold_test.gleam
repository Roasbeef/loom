//// A settled turn's work is drawn only while the reader has it open.
////
//// A page holds a limited number of rows, because the server runtime keeps
//// every element it draws. These tests read what the page counts and draws:
//// a settled turn is its prompt, its answer and one divider whatever it did,
//// opening the divider asks the page for the steps, and the page draws the
//// newest ones that fit its limit and says how many it left out.

import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lane_fixture
import lustre/element.{type Element}
import lustre/element/html
import page_fixture
import session_view/turns
import web_view/component
import web_view/view/lane

type Cache

@external(erlang, "lane_memo_ffi", "first")
fn first(view: Element(message)) -> Cache

@external(erlang, "lane_memo_ffi", "rerender")
fn rerender(cache: Cache, old: Element(message), new: Element(message)) -> Cache

fn page(update) {
  component.new(page_fixture.start()) |> component.apply([update])
}

fn html_of(model) -> String {
  element.to_string(component.view(model))
}

// The numbers of the folds the page holds, oldest turn first.
fn folds(model) -> List(Int) {
  list.filter_map(component.pieces(model), fn(piece) {
    case piece {
      turns.Work(id: Some(id), ..) -> Ok(id)
      turns.Work(id: None, ..)
      | turns.Plain(..)
      | turns.Prompt(..)
      | turns.Spawned(..)
      | turns.Returned(..)
      | turns.Nudged(..)
      | turns.Peer(..)
      | turns.Sibling(..)
      | turns.Missed(..)
      | turns.Decided(..)
      | turns.Commentary(..) -> Error(Nil)
    }
  })
}

fn toggled(model, fold: Int) {
  component.update(model, component.FoldToggled(fold)).0
}

// What each work of the page is drawn as: the number of steps it holds and how
// many it left out, or nothing for a closed fold.
fn drawn_folds(model) -> List(#(Int, Int)) {
  list.filter_map(component.pieces(model), fn(piece) {
    case piece {
      turns.Work(items:, folding: turns.Unfolded(hidden:), ..) ->
        Ok(#(list.length(items), hidden))
      turns.Work(..)
      | turns.Plain(..)
      | turns.Prompt(..)
      | turns.Spawned(..)
      | turns.Returned(..)
      | turns.Nudged(..)
      | turns.Peer(..)
      | turns.Sibling(..)
      | turns.Missed(..)
      | turns.Decided(..)
      | turns.Commentary(..) -> Error(Nil)
    }
  })
}

// A turn of two hundred calls costs the page its prompt, its answer and one
// divider, so the page keeps the prompt and the divider, where a page that
// counted every step cut the turn down to its last rows.
pub fn a_settled_turn_of_many_steps_is_one_divider_test() {
  let model = page(lane_fixture.weighty(1, [170]))
  let assert [
    turns.Plain(..),
    turns.Work(items: [], folding: turns.Folded, ..),
    turns.Plain(..),
  ] = component.pieces(model)
  let drawn = html_of(model)
  assert string.contains(drawn, "question 1")
  assert string.contains(drawn, "answer 1")
  assert string.contains(drawn, "data-loom-fold")
  assert string.contains(drawn, "aria-expanded=\"false\"")
  assert !string.contains(drawn, "step 1.5")
  assert component.top(model) == lane.Beginning
  assert component.paging(model) == component.Tail
}

// The turns before a turn of two hundred calls stay on the page, and the page
// can still load the ones older than those.
pub fn a_long_turn_does_not_hide_the_turns_before_it_test() {
  let model = page(lane_fixture.weighty(6, [3, 3, 3, 170]))
  let prompts =
    list.filter_map(component.pieces(model), fn(piece) {
      case piece {
        turns.Plain(block:, ..) ->
          case block.rows {
            [#(_, line), ..] ->
              case string.starts_with(line.text, "question") {
                True -> Ok(line.text)
                False -> Error(Nil)
              }
            [] -> Error(Nil)
          }
        turns.Work(..)
        | turns.Prompt(..)
        | turns.Spawned(..)
        | turns.Returned(..)
        | turns.Nudged(..)
        | turns.Peer(..)
        | turns.Sibling(..)
        | turns.Missed(..)
        | turns.Decided(..)
        | turns.Commentary(..) -> Error(Nil)
      }
    })
  assert prompts == ["question 2", "question 3", "question 4"]
  assert component.top(model) == lane.Earlier

  // Pressing the button is a read and not a refusal: the page is not full.
  let #(pressed, _) = component.older(model)
  assert component.top(pressed) == lane.Loading
  assert component.paging(pressed) == component.Paged
}

// Pressing a divider opens its fold, and the steps are drawn from what the
// page holds; pressing it again closes the fold and the steps are gone.
pub fn a_divider_opens_and_closes_its_fold_test() {
  let model = page(lane_fixture.captured(10, None))
  let assert [fold] = folds(model)
  assert drawn_folds(model) == []
  assert !string.contains(html_of(model), "src/&lt;a&gt;.gleam")

  let open = toggled(model, fold)
  assert drawn_folds(open) == [#(4, 0)]
  assert string.contains(html_of(open), "src/&lt;a&gt;.gleam")
  assert string.contains(html_of(open), "aria-expanded=\"true\"")

  let closed = toggled(open, fold)
  assert drawn_folds(closed) == []
  assert !string.contains(html_of(closed), "src/&lt;a&gt;.gleam")
}

// A number that names no fold the page holds, or a page that is not reading a
// session, changes nothing.
pub fn an_unknown_fold_is_ignored_test() {
  let model = page(lane_fixture.captured(10, None))
  let before = component.pieces(model)
  assert component.pieces(toggled(model, 999_999)) == before
  assert component.pieces(toggled(model, -1)) == before

  // The lane's own turns are named by sequence, and a sequence that is not the
  // first record of a fold is not a fold.
  let assert [fold] = folds(model)
  assert component.pieces(toggled(model, fold + 1)) == before

  let unopened = component.new(page_fixture.start())
  assert component.pieces(toggled(unopened, 1)) == []

  let #(ended, _) = component.update(model, component.Refused("not open"))
  assert drawn_folds(toggled(ended, fold)) == []
}

// A fold larger than the page's limit draws its newest steps that fit and
// says how many earlier ones it left out.
pub fn a_fold_larger_than_the_limit_draws_its_newest_steps_test() {
  let model = page(lane_fixture.weighty(1, [400]))
  let assert [fold] = folds(model)
  let open = toggled(model, fold)
  let assert [#(held, hidden)] = drawn_folds(open)
  assert hidden > 0
  assert held + hidden == 400
  assert held < component.live_rows
  let drawn = html_of(open)
  assert string.contains(
    drawn,
    int.to_string(hidden)
      <> " earlier steps are not shown, to keep the page small.",
  )
  assert string.contains(drawn, "step 1.400")
  assert !string.contains(drawn, "step 1.1<")
}

// Opening a fold that does not fit beside the ones already open closes the
// one opened longest ago, and keeps the new one.
pub fn opening_a_fold_closes_the_older_ones_when_they_do_not_fit_test() {
  let model = page(lane_fixture.weighty(1, [100, 100, 3]))
  let assert [first_fold, second_fold, _] = folds(model)
  let one = toggled(model, first_fold)
  assert drawn_folds(one) == [#(100, 0)]

  let two = toggled(one, second_fold)
  assert drawn_folds(two) == [#(100, 0)]
  let assert [turns.Work(folding: turns.Folded, ..), ..] =
    list.filter(component.pieces(two), fn(piece) {
      case piece {
        turns.Work(..) -> True
        turns.Plain(..)
        | turns.Prompt(..)
        | turns.Spawned(..)
        | turns.Returned(..)
        | turns.Nudged(..)
        | turns.Peer(..)
        | turns.Sibling(..)
        | turns.Missed(..)
        | turns.Decided(..)
        | turns.Commentary(..) -> False
      }
    })
}

// Folds that fit together stay open together.
pub fn folds_that_fit_stay_open_together_test() {
  let model = page(lane_fixture.weighty(1, [30, 30, 3]))
  let assert [first_fold, second_fold, _] = folds(model)
  let both = toggled(toggled(model, first_fold), second_fold)
  assert drawn_folds(both) == [#(30, 0), #(30, 0)]
}

// A fold the reader opened stays open as new turns arrive, and is forgotten
// when its turn leaves the page.
pub fn an_open_fold_stays_open_as_the_page_grows_test() {
  let model = page(lane_fixture.weighty(1, [30, 3]))
  let assert [fold, _] = folds(model)
  let open = toggled(model, fold)
  let grown = component.apply(open, [lane_fixture.weighty(1, [30, 3, 3])])
  assert drawn_folds(grown) == [#(30, 0)]
}

// Opening a fold draws the steps and nothing else again: the pieces keep
// their keys and the lane's memos hold the lines the page already drew.
pub fn opening_a_fold_draws_only_its_steps_test() {
  let lines = process.new_subject()
  let draw = fn(_line) {
    process.send(lines, Nil)
    html.text("line")
  }
  let render = fn(model) {
    lane.rows(
      component.pieces(model),
      [],
      element.none(),
      draw,
      lane.NoReplies,
      lane.no_marks(),
      lane.NoFolds,
      "",
    )
  }
  let model = page(lane_fixture.weighty(1, [5, 5, 5]))
  let assert [_, middle, _] = folds(model)
  let closed = render(model)
  let cache = first(closed)
  assert received(lines) == 6

  let open = render(toggled(model, middle))
  let _ = rerender(cache, closed, open)
  assert received(lines) == 5
}

fn received(lines: process.Subject(Nil)) -> Int {
  case process.receive(lines, 0) {
    Ok(Nil) -> 1 + received(lines)
    Error(Nil) -> 0
  }
}
