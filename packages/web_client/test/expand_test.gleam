//// What `<loom-expand>` decides (`web_client/expand_rule`).

import web_client/expand_rule.{Closed, Open}

pub fn pressing_the_row_toggles_its_body_test() {
  assert expand_rule.toggled(Closed) == Open
  assert expand_rule.toggled(Open) == Closed
}

pub fn the_chevron_points_down_once_the_body_is_shown_test() {
  assert expand_rule.glyph(Closed) == "▸"
  assert expand_rule.glyph(Open) == "▾"
}
