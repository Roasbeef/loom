//// What `<loom-dismiss>` decides (`web_client/dismiss_rule`): when a press or
//// a key closes the context disclosure.

import gleam/list
import web_client/dismiss_rule.{
  Close, Consume, Inside, Keep, PassOn, Showing, Shut,
}

pub fn the_one_fixed_word_is_the_mark_test() {
  assert dismiss_rule.mark("keep") == Ok(Inside)
}

// Any other word is no mark, whatever it resembles, so a node the server did
// not mark is never taken for one.
pub fn any_other_word_is_no_mark_test() {
  list.each(["", "Keep", "keep ", "inside", "open", "true"], fn(word) {
    assert dismiss_rule.mark(word) == Error(Nil)
  })
}

// A press that passed through the disclosure leaves it open, so Refresh and
// Compact now do not close the panel they sit in. A press that passed through
// nothing marked is outside it, and closes it.
pub fn a_press_outside_closes_and_one_inside_keeps_test() {
  assert dismiss_rule.after_click([Inside]) == Keep
  assert dismiss_rule.after_click([]) == Close
}

// Escape with the panel open closes it and is consumed, so the shell's own
// Escape (back to `main`) does not also run.
pub fn escape_with_the_panel_open_is_consumed_test() {
  assert dismiss_rule.on_key("Escape", Showing) == Consume
}

// Escape with the panel shut, and every other key either way, passes on
// untouched, so a page with no panel open behaves as it always did.
pub fn escape_with_the_panel_shut_and_other_keys_pass_on_test() {
  assert dismiss_rule.on_key("Escape", Shut) == PassOn
  list.each(["Enter", "a", "Tab", "escape", " ", "Esc"], fn(key) {
    assert dismiss_rule.on_key(key, Showing) == PassOn
    assert dismiss_rule.on_key(key, Shut) == PassOn
  })
}
