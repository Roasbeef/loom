//// What `<loom-expand>` decides (`web_client/expand_rule`).

import gleam/int
import web_client/expand_rule.{Closed, Open}

pub fn pressing_the_row_toggles_its_body_test() {
  assert expand_rule.toggled(Closed) == Open
  assert expand_rule.toggled(Open) == Closed
}

pub fn the_chevron_points_down_once_the_body_is_shown_test() {
  assert expand_rule.glyph(Closed) == "▸"
  assert expand_rule.glyph(Open) == "▾"
}

pub fn the_server_names_a_live_and_a_settled_reasoning_row_test() {
  assert expand_rule.kind("live") == expand_rule.Live
  assert expand_rule.kind("settled") == expand_rule.Settled
  assert expand_rule.kind("") == expand_rule.Plain
  assert expand_rule.kind("anything else") == expand_rule.Plain
}

pub fn only_a_marked_row_takes_the_offer_test() {
  let left = 1_700_000_000_000
  let standing = int.to_string(expand_rule.standing)
  let fresh = int.to_string(left + expand_rule.handoff_window_ms)
  let expired = int.to_string(left)

  assert expand_rule.mark("yes") == expand_rule.Marked
  assert expand_rule.mark("no") == expand_rule.Unmarked
  assert expand_rule.mark("") == expand_rule.Unmarked

  // A marked row takes a standing offer and a fresh one.
  assert expand_rule.takes(expand_rule.Marked, standing, left)
  assert expand_rule.takes(expand_rule.Marked, fresh, left + 1)

  // An unmarked row never does, however good the offer.
  assert !expand_rule.takes(expand_rule.Unmarked, standing, left)
  assert !expand_rule.takes(expand_rule.Unmarked, fresh, left + 1)

  // An expired offer is refused even to a marked row, as is a note that is
  // not a deadline.
  assert !expand_rule.takes(expand_rule.Marked, expired, left)
  assert !expand_rule.takes(expand_rule.Marked, "soon", left)
}

pub fn an_open_live_row_offers_its_state_to_the_settled_row_that_follows_test() {
  let left = 1_700_000_000_000

  // While the live row is open and on the page, the offer stands.
  assert expand_rule.offers(int.to_string(expand_rule.standing), left)

  // After it leaves, the offer lasts the window and then runs out.
  let until = int.to_string(left + expand_rule.handoff_window_ms)
  assert expand_rule.offers(until, left + 1)
  assert !expand_rule.offers(until, left + expand_rule.handoff_window_ms)

  // Text that is not a deadline offers nothing.
  assert !expand_rule.offers("", left)
  assert !expand_rule.offers("soon", left)
}

// The stylesheet hides an open reasoning row's preview by this custom state.
pub fn an_open_row_publishes_the_state_the_stylesheet_reads_test() {
  assert expand_rule.open_state == "open"
}
