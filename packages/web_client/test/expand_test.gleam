//// What `<loom-expand>` decides (`web_client/expand_rule`).

import web_client/expand_rule.{Compact, Full}

pub fn a_row_starts_compact_and_the_button_flips_it_test() {
  assert expand_rule.toggled(Compact) == Full
  assert expand_rule.toggled(Full) == Compact
}

pub fn each_state_shows_the_slot_the_server_named_test() {
  assert expand_rule.slot(Compact) == "compact"
  assert expand_rule.slot(Full) == "full"
}

pub fn the_words_name_what_pressing_does_test() {
  assert expand_rule.words(Compact) == "Expand"
  assert expand_rule.words(Full) == "Collapse"
  assert expand_rule.glyph(Compact) == "▸"
  assert expand_rule.glyph(Full) == "▾"
}
