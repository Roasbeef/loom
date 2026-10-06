//// `fold_budget` decides how many turns a page holds and which steps of an
//// open fold it draws. The decisions are over weights and pieces, so these
//// tests build them directly: a settled turn costs its closed rows, an open
//// fold adds its steps, the page keeps the newest turns that fit, and an open
//// fold that does not fit is cut to its newest steps.

import gleam/dict
import gleam/option.{None, Some}
import session_view/fold_budget.{Fitted, Fold, Weight}
import session_view/turns

fn turn(base: Int, id: Int, steps: Int) -> fold_budget.Weight {
  Weight(base:, fold: Some(Fold(id:, rows: steps)))
}

fn bare(base: Int) -> fold_budget.Weight {
  Weight(base:, fold: None)
}

pub fn a_closed_turn_costs_its_closed_rows_test() {
  let weight = turn(3, 7, 170)
  assert fold_budget.cost(weight, []) == 3
  assert fold_budget.cost(weight, [9]) == 3
  assert fold_budget.cost(weight, [7]) == 173
  assert fold_budget.cost(bare(2), [7]) == 2
}

// A turn of two hundred calls does not keep the turns before it off the
// page: each costs its three rows.
pub fn many_closed_turns_fit_whatever_they_did_test() {
  let weights = [turn(3, 30, 200), turn(3, 20, 200), turn(3, 10, 200)]
  assert fold_budget.fit(weights, [], 150)
    == Fitted(kept: 3, used: 9, allowance: dict.new())
}

pub fn the_page_keeps_the_newest_turns_that_fit_test() {
  let weights = [bare(60), bare(60), bare(60), bare(60)]
  assert fold_budget.fit(weights, [], 150)
    == Fitted(kept: 2, used: 120, allowance: dict.new())
}

// The first turn that does not fit ends the page, even when an older one
// would have.
pub fn a_smaller_older_turn_is_not_taken_past_one_that_did_not_fit_test() {
  let weights = [bare(60), bare(100), bare(5)]
  assert fold_budget.fit(weights, [], 150).kept == 1
}

pub fn the_newest_turn_is_held_even_when_it_alone_is_over_the_limit_test() {
  assert fold_budget.fit([bare(200), bare(1)], [], 150).kept == 1
}

pub fn an_open_fold_adds_its_steps_test() {
  let weights = [turn(3, 30, 40), turn(3, 20, 10)]
  assert fold_budget.fit(weights, [30], 150)
    == Fitted(kept: 2, used: 46, allowance: dict.new())
}

// An open fold that does not fit beside the turns newer than it is held with
// the steps the room allows, and that fills the page: nothing older follows.
pub fn an_open_fold_that_does_not_fit_is_cut_to_the_room_test() {
  let weights = [bare(10), turn(5, 20, 400), bare(3)]
  assert fold_budget.fit(weights, [20], 150)
    == Fitted(kept: 2, used: 150, allowance: dict.from_list([#(20, 135)]))
}

// The newest turn's fold is cut the same way.
pub fn the_newest_turns_open_fold_is_cut_to_the_limit_test() {
  assert fold_budget.fit([turn(3, 20, 400)], [20], 150)
    == Fitted(kept: 1, used: 150, allowance: dict.from_list([#(20, 147)]))
}

// A fold that is not open is never cut, and an open number that names no turn
// of the page costs nothing.
pub fn only_an_open_fold_is_cut_test() {
  let weights = [turn(3, 20, 400), turn(3, 10, 400)]
  assert fold_budget.fit(weights, [99], 150)
    == Fitted(kept: 2, used: 6, allowance: dict.new())
}

pub fn no_turns_hold_no_rows_test() {
  assert fold_budget.fit([], [1], 150)
    == Fitted(kept: 0, used: 0, allowance: dict.new())
}

fn work(id: Int, count: Int, folding: turns.Folding) -> turns.Piece {
  turns.Work(
    key: "work:1.0",
    worked: turns.Worked(None, count, 0, 0, turns.Finished),
    items: steps(count),
    folding:,
    id: Some(id),
  )
}

fn steps(count: Int) -> List(turns.Item) {
  case count {
    0 -> []
    _ -> [turns.Memory("1.0", 1, []), ..steps(count - 1)]
  }
}

pub fn a_closed_fold_keeps_no_steps_test() {
  let assert [turns.Work(items: [], folding: turns.Folded, id: Some(7), ..)] =
    fold_budget.draw([work(7, 50, turns.Folded)], [], dict.new())
  let assert [turns.Work(items: [], folding: turns.Folded, ..)] =
    fold_budget.draw([work(7, 50, turns.Folded)], [8], dict.new())
}

pub fn an_open_fold_keeps_every_step_without_an_allowance_test() {
  let assert [turns.Work(items:, folding: turns.Unfolded(hidden: 0), ..)] =
    fold_budget.draw([work(7, 50, turns.Folded)], [7], dict.new())
  assert items == steps(50)
}

pub fn an_open_fold_keeps_its_newest_steps_within_the_allowance_test() {
  let assert [turns.Work(items:, folding: turns.Unfolded(hidden: 35), ..)] =
    fold_budget.draw(
      [work(7, 50, turns.Folded)],
      [7],
      dict.from_list([#(7, 15)]),
    )
  assert items == steps(15)
}

// The turn that is still running, and every piece that is not a settled
// turn's work, are returned as they were.
pub fn the_running_turn_is_not_touched_test() {
  let running = work(7, 50, turns.Open)
  assert fold_budget.draw([running], [7], dict.new()) == [running]
  let opened = work(7, 20, turns.Unfolded(hidden: 0))
  assert fold_budget.draw([opened], [], dict.new()) == [opened]
}
