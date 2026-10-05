//// The drop rules: which drags are about files, how the drag depth moves as
//// the pointer crosses the composer's elements, when the drop state shows,
//// and that a drop is vetted by the paste's own rules.

import web_client/attach_rule.{Candidate, Limits}
import web_client/drop_rule.{Depth}

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

pub fn the_depth_counts_the_elements_a_file_drag_is_inside_test() {
  let depth =
    drop_rule.outside
    |> drop_rule.entered(files)
    |> drop_rule.entered(files)
  assert depth == Depth(2)
  assert drop_rule.left(depth, files) == Depth(1)
  assert drop_rule.left(Depth(1), files) == drop_rule.outside
}

pub fn the_depth_never_goes_below_zero_test() {
  assert drop_rule.left(drop_rule.outside, files) == drop_rule.outside
}

pub fn a_text_drag_never_moves_the_depth_test() {
  assert drop_rule.entered(drop_rule.outside, text) == drop_rule.outside
  assert drop_rule.left(Depth(2), text) == Depth(2)
}

pub fn a_drop_ends_the_drag_test() {
  assert drop_rule.dropped(Depth(3)) == drop_rule.outside
}

pub fn the_drop_state_shows_only_with_room_test() {
  assert drop_rule.surface(Depth(1), drop_rule.Room) == drop_rule.Inviting
  assert drop_rule.surface(Depth(0), drop_rule.Room) == drop_rule.Plain
  assert drop_rule.surface(Depth(1), drop_rule.Full) == drop_rule.Plain
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
  assert drop_rule.surface(Depth(1), drop_rule.places(state)) == drop_rule.Plain

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
