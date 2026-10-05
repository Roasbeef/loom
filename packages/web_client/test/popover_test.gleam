//// What `<loom-popover>` decides (`web_client/popover_rule`): when the home's
//// account panel is open, from the clicks, keys and the one word the server
//// writes.

import gleam/list
import web_client/popover_rule.{Closed, Open, Panel, Toggle}

pub fn the_two_fixed_words_are_the_marks_test() {
  assert popover_rule.mark("toggle") == Ok(Toggle)
  assert popover_rule.mark("panel") == Ok(Panel)
}

// Any other word is no mark, whatever it resembles, so a node the server did
// not mark is never taken for one.
pub fn any_other_word_is_no_mark_test() {
  list.each(["", "Toggle", "toggle ", "panel2", "open", "true"], fn(word) {
    assert popover_rule.mark(word) == Error(Nil)
  })
}

// The server asks only for `open`. The word it writes when a link is done, and
// any other, asks for nothing, so a person's own closing is never undone by a
// re-render that carries the same state.
pub fn the_server_can_only_ask_for_open_test() {
  assert popover_rule.wanted("open") == Ok(Open)
  list.each(["closed", "", "Open", "open ", "yes"], fn(word) {
    assert popover_rule.wanted(word) == Error(Nil)
  })
}

pub fn a_press_on_the_toggle_flips_the_state_test() {
  assert popover_rule.after_click(Closed, [Toggle]) == Open
  assert popover_rule.after_click(Open, [Toggle]) == Closed

  // The toggle's own children are nodes the click passed through too; the
  // button's mark is what decides.
  assert popover_rule.after_click(Closed, [Toggle, Panel]) == Open
}

// A press inside the panel leaves it as it is, so "Sign out" does not close the
// panel it sits in, and a press anywhere else closes it.
pub fn a_press_inside_the_panel_keeps_it_and_one_outside_closes_it_test() {
  assert popover_rule.after_click(Open, [Panel]) == Open
  assert popover_rule.after_click(Closed, [Panel]) == Closed
  assert popover_rule.after_click(Open, []) == Closed
  assert popover_rule.after_click(Closed, []) == Closed
}

pub fn escape_closes_and_no_other_key_changes_anything_test() {
  assert popover_rule.after_key(Open, "Escape") == Closed
  assert popover_rule.after_key(Closed, "Escape") == Closed
  list.each(["Enter", "a", "Tab", "escape", " ", "Esc"], fn(key) {
    assert popover_rule.after_key(Open, key) == Open
    assert popover_rule.after_key(Closed, key) == Closed
  })
}

pub fn the_toggle_reports_whether_the_panel_is_open_test() {
  assert popover_rule.expanded(Open) == "true"
  assert popover_rule.expanded(Closed) == "false"
}
