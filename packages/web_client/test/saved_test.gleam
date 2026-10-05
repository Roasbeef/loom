//// What `<loom-saved>` decides (`web_client/saved_rule`): whether the sidebar's
//// saved sessions are showing, and how the choice is read back from the
//// browser's storage.

import gleam/list
import web_client/saved_rule.{Hidden, Shown}

pub fn a_press_flips_the_state_test() {
  assert saved_rule.flipped(Hidden) == Shown
  assert saved_rule.flipped(Shown) == Hidden
}

// The choice survives the round trip through the storage's one item, and the
// toggle's `aria-expanded` follows the state.
pub fn the_choice_round_trips_through_the_storage_test() {
  assert saved_rule.restored(Ok(saved_rule.encode(Shown))) == Shown
  assert saved_rule.restored(Ok(saved_rule.encode(Hidden))) == Hidden
  assert saved_rule.expanded(Shown) == "true"
  assert saved_rule.expanded(Hidden) == "false"
}

// A missing or blocked storage, and any value but the one word, is the default:
// folded. A stale or edited item never shows the saved sessions on its own.
pub fn anything_but_shown_restores_as_hidden_test() {
  assert saved_rule.restored(Error(Nil)) == Hidden
  list.each(["", "Shown", "shown ", "true", "open", "1", "hidden"], fn(word) {
    assert saved_rule.restored(Ok(word)) == Hidden
  })
}

// The item is one fixed key for the origin, with no identity or path in it, so
// the choice is the viewer's and applies to every page they open.
pub fn the_choice_is_kept_under_one_fixed_key_test() {
  assert saved_rule.key == "loom.sidebar.saved.v1"
}
