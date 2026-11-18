//// The live rail's jump rule: which click goes where, and which row a key
//// names. The scrolling and the marking need a page and are not run here.

import gleam/list
import gleam/option.{None, Some}
import web_client/follow_rule
import web_client/jump_rule.{Dock, Row}

pub fn a_click_with_no_marker_goes_nowhere_test() {
  assert jump_rule.destination([]) == None
  assert jump_rule.destination([Error(Nil), Error(Nil)]) == None
}

pub fn a_marker_naming_the_dock_goes_to_the_dock_test() {
  assert jump_rule.destination([Error(Nil), Ok("dock"), Error(Nil)])
    == Some(Dock)
}

pub fn a_marker_naming_a_row_goes_to_that_row_test() {
  assert jump_rule.destination([Ok("9.0")]) == Some(Row(["9.0"]))
}

// The marked button is the click's target or an ancestor of it, so the path
// reaches it after a span or two. The innermost marker decides.
pub fn the_innermost_marker_decides_test() {
  assert jump_rule.destination([Error(Nil), Ok("9.0"), Ok("dock")])
    == Some(Row(["9.0"]))
}

pub fn an_empty_marker_names_nothing_test() {
  assert jump_rule.destination([Ok("")]) == None
}

pub fn a_step_in_a_fold_falls_back_to_the_turns_row_test() {
  assert jump_rule.destination([Ok("work:7#2")])
    == Some(Row(["work:7#2", "work:7"]))
  assert jump_rule.candidates("#2") == ["#2"]
  assert jump_rule.candidates("9.0") == ["9.0"]
}

pub fn a_row_in_the_window_resolves_test() {
  assert jump_rule.resolve(["work:7#2", "work:7"], ["1.0", "work:7"])
    == Ok("work:7")
  assert jump_rule.resolve(["9.0"], ["9.0", "work:7"]) == Ok("9.0")
}

// A row older than the loaded page is not on it, and the press does nothing.
pub fn a_row_not_in_the_window_resolves_to_nothing_test() {
  assert jump_rule.resolve(["3.0"], ["9.0", "10.0"]) == Error(Nil)
  assert jump_rule.resolve(["3.0"], []) == Error(Nil)
}

// A jump is the reader's own move, so the follower stops following; the rule
// the element applies is the fold's.
pub fn a_jump_leaves_the_tail_test() {
  let at_the_bottom = follow_rule.start()
  assert follow_rule.folded(at_the_bottom).position == follow_rule.Reading
}

pub fn the_mark_is_brief_and_not_a_class_test() {
  assert jump_rule.marked_for == 900
  assert jump_rule.marked_attribute == "data-loom-jumped"
  assert jump_rule.marker == "data-loom-jump"
  assert jump_rule.row_marker == "data-loom-row"
}

// For each of these keys, a click on its marker is a row whose first candidate
// is the key itself, and the key resolves against a page that holds it.
pub fn a_marked_key_resolves_against_a_page_that_holds_it_test() {
  list.each(
    ["1.0", "approval:esc-1", "6.0/0/0", "work:window-start#3", "é#"],
    fn(key) {
      let assert Some(Row(candidates:)) = jump_rule.destination([Ok(key)])
      assert list.first(candidates) == Ok(key)
      assert jump_rule.resolve(candidates, ["other", key]) == Ok(key)
    },
  )
}

// A 100px row 400px below the top of a 400px view is moved to the middle, so
// the transcript scrolls by the row's offset less the 150px of room around it.
pub fn a_row_is_scrolled_to_the_middle_of_the_view_test() {
  assert jump_rule.centring(row: 500.0, host: 100.0, view: 400.0, height: 100.0)
    == 250.0

  // A row already in the middle does not move the transcript.
  assert jump_rule.centring(row: 250.0, host: 100.0, view: 400.0, height: 100.0)
    == 0.0

  // A row taller than the view is centred by its middle, so its top edge ends
  // above the view.
  assert jump_rule.centring(row: 100.0, host: 100.0, view: 400.0, height: 600.0)
    == 100.0
}
