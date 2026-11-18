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
  assert jump_rule.destination([Ok("9.0")]) == Some(Row("9.0"))
}

// The marked button is the click's target or an ancestor of it, so the path
// reaches it after a span or two. The innermost marker decides.
pub fn the_innermost_marker_decides_test() {
  assert jump_rule.destination([Error(Nil), Ok("9.0"), Ok("dock")])
    == Some(Row("9.0"))
}

pub fn an_empty_marker_names_nothing_test() {
  assert jump_rule.destination([Ok("")]) == None
}

// A key is the server's text and is taken as it stands, whatever it holds.
pub fn a_key_is_taken_as_it_stands_test() {
  list.each(["1.0", "approval:esc-1", "6.0/0/0", "work:7#2", "é#"], fn(key) {
    assert jump_rule.destination([Ok(key)]) == Some(Row(key))
  })
}

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
