//// What `<loom-picklist>` decides (`web_client/picklist_rule`): where the arrow
//// keys move the focus in the folder list, and when Escape closes it.

import gleam/list
import web_client/picklist_rule.{Close, Focus, Ignore}

// Down goes one item on and holds at the last, so the column does not wrap and
// the focus is never lost off its end.
pub fn down_moves_on_and_holds_at_the_last_test() {
  assert picklist_rule.after_key("ArrowDown", 0, 4) == Focus(1)
  assert picklist_rule.after_key("ArrowDown", 2, 4) == Focus(3)
  assert picklist_rule.after_key("ArrowDown", 3, 4) == Focus(3)
}

// Up goes one item back and holds at the first, which is the search field.
pub fn up_moves_back_and_holds_at_the_first_test() {
  assert picklist_rule.after_key("ArrowUp", 3, 4) == Focus(2)
  assert picklist_rule.after_key("ArrowUp", 1, 4) == Focus(0)
  assert picklist_rule.after_key("ArrowUp", 0, 4) == Focus(0)
}

// A focus outside the list, or a list with nothing in it, is left alone, so a
// person who is elsewhere on the page keeps the arrows' own scrolling.
pub fn arrows_leave_a_focus_outside_the_list_alone_test() {
  assert picklist_rule.after_key("ArrowDown", -1, 4) == Ignore
  assert picklist_rule.after_key("ArrowUp", -1, 4) == Ignore
  assert picklist_rule.after_key("ArrowDown", 0, 0) == Ignore
  assert picklist_rule.after_key("ArrowDown", 4, 4) == Ignore
}

// Escape closes the list wherever the focus is.
pub fn escape_closes_from_anywhere_test() {
  assert picklist_rule.after_key("Escape", 0, 3) == Close
  assert picklist_rule.after_key("Escape", -1, 3) == Close
  assert picklist_rule.after_key("Escape", -1, 0) == Close
}

// No other key is the list's: Enter belongs to the form and the focused button,
// and a letter belongs to the field.
pub fn no_other_key_is_the_lists_test() {
  list.each(["Enter", "a", "Tab", "Home", "End", " ", "escape", "Esc"], fn(key) {
    assert picklist_rule.after_key(key, 1, 3) == Ignore
  })
}
