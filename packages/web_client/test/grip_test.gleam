//// What `<loom-shell>` decides about the strand panel's width
//// (`web_client/grip_rule`): the ceiling a window allows, how far a drag moves
//// the panel, and what the keys on the grip do.

import gleam/list
import gleam/option.{None, Some}
import web_client/grip_rule.{
  Coarse, Drag, Fine, Lifted, Narrower, Narrowest, Pressing, Reset, Room, Wider,
  Widest,
}
import web_client/shell_rule.{Free, Held}

// A 1400 px window with the sidebar open leaves 1168 px for the two columns;
// the panel is 340 of it, so the transcript has 828.
const room = Room(panel: 340, centre: 828)

pub fn the_ceiling_leaves_the_transcript_its_floor_test() {
  assert grip_rule.ceiling(room) == 340 + 828 - grip_rule.centre_floor
  assert grip_rule.ceiling(Room(panel: 340, centre: 700)) == 680
}

// A window too small for both floors keeps the panel at its least width and
// lets the stylesheet shrink the transcript's column, so the ceiling never
// goes under the least width.
pub fn a_small_window_never_takes_the_ceiling_under_the_least_width_test() {
  assert grip_rule.ceiling(Room(panel: 340, centre: 100))
    == grip_rule.least_width
  assert grip_rule.ceiling(Room(panel: 0, centre: 0)) == grip_rule.least_width
}

// A drag on a window wider than the stored bound still saves a width that
// reading accepts, so the ceiling stops at `most_width`.
pub fn the_ceiling_never_passes_the_widest_stored_width_test() {
  assert grip_rule.ceiling(Room(panel: 340, centre: 9000))
    == grip_rule.most_width
}

pub fn a_width_is_held_between_the_least_and_the_ceiling_test() {
  assert grip_rule.clamp(100, 600) == grip_rule.least_width
  assert grip_rule.clamp(900, 600) == 600
  assert grip_rule.clamp(400, 600) == 400
  assert grip_rule.clamp(grip_rule.least_width, 600) == grip_rule.least_width
  assert grip_rule.clamp(600, 600) == 600
}

// A ceiling under the least width, which a hostile measurement could give,
// still yields a usable panel.
pub fn a_ceiling_under_the_least_width_still_gives_the_least_width_test() {
  assert grip_rule.clamp(500, 10) == grip_rule.least_width
  assert grip_rule.clamp(0, -5) == grip_rule.least_width
}

pub fn a_drag_records_where_it_began_test() {
  assert grip_rule.begin(900, room)
    == Drag(origin: 900, start: 340, ceiling: 340 + 828 - 360)
}

// The panel is the right column: the pointer moving left widens it by the
// distance moved, and moving right narrows it.
pub fn dragging_left_widens_and_dragging_right_narrows_test() {
  let drag = Drag(origin: 900, start: 340, ceiling: 680)
  assert grip_rule.dragged(drag, 900) == 340
  assert grip_rule.dragged(drag, 800) == 440
  assert grip_rule.dragged(drag, 1000) == 280
  assert grip_rule.dragged(drag, 880) == 360
}

pub fn a_drag_stops_at_both_limits_test() {
  let drag = Drag(origin: 900, start: 340, ceiling: 680)
  assert grip_rule.dragged(drag, 100) == 680
  assert grip_rule.dragged(drag, -5000) == 680
  assert grip_rule.dragged(drag, 1500) == grip_rule.least_width
}

// The width comes from where the drag began, so a pointer that went far past a
// limit and came back finds the panel where it was when it left, not stuck at
// the limit it hit.
pub fn a_pointer_that_overshoots_and_returns_has_no_dead_zone_test() {
  let drag = Drag(origin: 900, start: 340, ceiling: 680)
  assert grip_rule.dragged(drag, -2000) == 680
  assert grip_rule.dragged(drag, 800) == 440
}

// Whatever the pointer does, the width is in range, and moving the pointer
// left never gives a narrower panel than moving it right.
pub fn every_pointer_position_gives_a_width_in_range_test() {
  let drag = grip_rule.begin(900, room)
  let ceiling = grip_rule.ceiling(room)
  let positions = sweep(-500, 2500)
  assert list.all(positions, fn(pointer) {
    let width = grip_rule.dragged(drag, pointer)
    width >= grip_rule.least_width && width <= ceiling
  })
  assert list.all(positions, fn(pointer) {
    grip_rule.dragged(drag, pointer) >= grip_rule.dragged(drag, pointer + 1)
  })
}

pub fn a_move_with_no_button_down_ends_the_drag_test() {
  assert grip_rule.contact(0) == Lifted
  assert grip_rule.contact(1) == Pressing
  assert grip_rule.contact(2) == Pressing
  assert grip_rule.contact(5) == Pressing
}

pub fn the_arrows_home_and_end_are_the_grips_keys_test() {
  assert grip_rule.adjustment("ArrowLeft", Free) == Some(Wider(Fine))
  assert grip_rule.adjustment("ArrowRight", Free) == Some(Narrower(Fine))
  assert grip_rule.adjustment("ArrowLeft", Held) == Some(Wider(Coarse))
  assert grip_rule.adjustment("ArrowRight", Held) == Some(Narrower(Coarse))
  assert grip_rule.adjustment("Home", Free) == Some(Narrowest)
  assert grip_rule.adjustment("End", Free) == Some(Widest)
}

// Every key the grip does not take stays the browser's, Tab above all, which a
// keyboard reader uses to leave the grip.
pub fn every_other_key_is_left_to_the_browser_test() {
  let others = [
    "Tab", "Enter", " ", "Escape", "ArrowUp", "ArrowDown", "PageUp", "b", "B",
    "", "arrowleft",
  ]
  assert list.all(others, fn(key) {
    grip_rule.adjustment(key, Free) == None
    && grip_rule.adjustment(key, Held) == None
  })
}

pub fn an_arrow_moves_by_a_step_and_shift_by_a_larger_one_test() {
  assert grip_rule.adjusted(340, Wider(Fine), room) == 340 + grip_rule.fine_step
  assert grip_rule.adjusted(340, Wider(Coarse), room)
    == 340 + grip_rule.coarse_step
  assert grip_rule.adjusted(400, Narrower(Fine), room)
    == 400 - grip_rule.fine_step
  assert grip_rule.adjusted(400, Narrower(Coarse), room)
    == 400 - grip_rule.coarse_step
}

// A width the window no longer holds (the stored width of a larger window) is
// brought inside the room before the step, so the first press moves from the
// width the reader sees and not from one that is hidden by the stylesheet.
pub fn a_width_the_room_no_longer_holds_is_brought_inside_first_test() {
  let ceiling = grip_rule.ceiling(room)
  assert grip_rule.adjusted(ceiling + 500, Narrower(Fine), room)
    == ceiling - grip_rule.fine_step
  assert grip_rule.adjusted(ceiling + 500, Wider(Fine), room) == ceiling
}

// Repeated presses accumulate from the width each one produced.
pub fn repeated_presses_accumulate_test() {
  let once = grip_rule.adjusted(280, Wider(Fine), room)
  let twice = grip_rule.adjusted(once, Wider(Fine), room)
  let thrice = grip_rule.adjusted(twice, Wider(Fine), room)
  assert thrice == 280 + 3 * grip_rule.fine_step
}

pub fn the_keys_stop_at_the_limits_test() {
  let ceiling = grip_rule.ceiling(room)
  assert grip_rule.adjusted(ceiling - 1, Wider(Coarse), room) == ceiling
  assert grip_rule.adjusted(grip_rule.least_width + 1, Narrower(Coarse), room)
    == grip_rule.least_width
  assert grip_rule.adjusted(340, Widest, room) == ceiling
  assert grip_rule.adjusted(900, Narrowest, room) == grip_rule.least_width
}

pub fn reset_goes_back_to_the_default_where_the_room_allows_it_test() {
  assert grip_rule.adjusted(600, Reset, room) == grip_rule.default_width
  assert grip_rule.adjusted(grip_rule.least_width, Reset, room)
    == grip_rule.default_width
  // Where the window cannot hold the default, the ceiling wins.
  let tight = Room(panel: 300, centre: 380)
  assert grip_rule.adjusted(300, Reset, tight) == grip_rule.ceiling(tight)
}

// Whatever the key and wherever the panel is now, the width is in range.
pub fn no_key_takes_the_width_out_of_range_test() {
  let adjustments = [
    Wider(Fine),
    Wider(Coarse),
    Narrower(Fine),
    Narrower(Coarse),
    Widest,
    Narrowest,
    Reset,
  ]
  let rooms = [
    room,
    Room(panel: 340, centre: 100),
    Room(panel: 280, centre: 360),
  ]
  assert list.all(rooms, fn(room) {
    let ceiling = grip_rule.ceiling(room)
    list.all(adjustments, fn(adjustment) {
      list.all(sweep(0, 40), fn(step) {
        let width = grip_rule.adjusted(step * 50, adjustment, room)
        width >= grip_rule.least_width && width <= ceiling
      })
    })
  })
}

// Every integer from `low` to `high`, for the sweeps above.
fn sweep(low: Int, high: Int) -> List(Int) {
  case low > high {
    True -> []
    False -> [low, ..sweep(low + 1, high)]
  }
}
