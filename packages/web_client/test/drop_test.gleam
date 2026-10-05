//// The drop rules: which drags are about files, how the drag state moves as
//// the pointer crosses the composer's elements, when the drop state shows,
//// and that a drop is vetted by the paste's own rules.

import web_client/attach_rule.{Candidate, Limits}
import web_client/drop_rule.{Away, Beyond, Over, Within}

const files = ["text/uri-list", "Files"]

const text = ["text/plain", "text/html"]

fn ready() -> attach_rule.State {
  attach_rule.configured(
    attach_rule.start(),
    Limits(count: 1, bytes: 1000, types: ["image/png"]),
  )
}

pub fn only_a_drag_with_files_is_about_files_test() {
  assert drop_rule.carries_files(files)
  assert drop_rule.carries_files(["Files"])
  assert !drop_rule.carries_files(text)
  assert !drop_rule.carries_files([])
}

pub fn a_file_drag_entering_is_over_the_composer_test() {
  assert drop_rule.entered(drop_rule.away, files) == Over
  assert drop_rule.entered(Over, files) == Over
}

pub fn leaving_for_another_element_of_the_composer_stays_over_test() {
  assert drop_rule.left(Over, files, Within) == Over
}

pub fn leaving_for_nothing_or_for_the_outside_is_away_test() {
  assert drop_rule.left(Over, files, Beyond) == Away
}

pub fn an_element_replaced_mid_drag_cannot_stick_the_overlay_test() {
  // The element under the pointer was removed, so its leave never came. The
  // next enter, then a leave towards the outside, ends the drag as it should.
  let drag =
    drop_rule.away
    |> drop_rule.entered(files)
    |> drop_rule.entered(files)
  assert drop_rule.left(drag, files, Beyond) == Away

  // And a drop or drag end anywhere ends it with no leave at all.
  assert drop_rule.dropped(Over) == Away
}

pub fn a_text_drag_never_moves_the_state_test() {
  assert drop_rule.entered(drop_rule.away, text) == Away
  assert drop_rule.left(Over, text, Beyond) == Over
}

pub fn the_drop_state_shows_only_with_room_test() {
  assert drop_rule.surface(Over, drop_rule.Room) == drop_rule.Inviting
  assert drop_rule.surface(Away, drop_rule.Room) == drop_rule.Plain
  assert drop_rule.surface(Over, drop_rule.Full) == drop_rule.Plain
}

pub fn an_element_told_no_limits_has_no_room_test() {
  assert drop_rule.places(attach_rule.start()) == drop_rule.Full
  assert drop_rule.places(ready()) == drop_rule.Room
}

pub fn a_full_element_shows_no_drop_state_and_takes_nothing_test() {
  let file = Candidate("a.png", "image/png", 10, Nil)
  let #(state, reads) = attach_rule.choose(ready(), [file])
  assert reads != []
  assert drop_rule.places(state) == drop_rule.Full
  assert drop_rule.surface(Over, drop_rule.places(state)) == drop_rule.Plain

  // A second drop is refused with the limit's words, as a paste is.
  let #(state, reads) = attach_rule.choose(state, [file])
  assert reads == []
  assert state.notice == "At most 1 images can be attached."
}

pub fn a_dropped_file_meets_the_pastes_vetting_test() {
  let #(state, reads) =
    attach_rule.choose(ready(), [Candidate("a.txt", "text/plain", 10, Nil)])
  assert reads == []
  assert state.notice == "a.txt is not a PNG, JPEG, GIF or WebP image."
}
