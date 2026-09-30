//// The attach element's rules: the limits it is told, which files it accepts
//// and which it refuses with what words, how a read becomes a held image,
//// and the one form field the held images make. The element itself
//// (`web_client/attach`) is the browser's; these are its decisions
//// (protocol-change/051, the addendum on images).

import gleam/list
import gleam/string
import web_client/attach_rule.{type Candidate, Candidate, Held, Limits, Reading}

const png = "image/png"

fn limits() -> attach_rule.Limits {
  Limits(count: 2, bytes: 1000, types: [
    "image/png",
    "image/jpeg",
    "image/gif",
    "image/webp",
  ])
}

fn ready() -> attach_rule.State {
  attach_rule.configured(attach_rule.start(), limits())
}

fn file(name: String, mime: String, size: Int) -> Candidate(String) {
  Candidate(name:, mime_type: mime, size:, file: name)
}

pub fn limits_decode_the_servers_attribute_test() {
  assert attach_rule.limits(
      "{\"count\":4,\"bytes\":8388608,\"types\":[\"image/png\",\"image/gif\"]}",
    )
    == Limits(4, 8_388_608, ["image/png", "image/gif"])
}

pub fn an_attribute_that_does_not_decode_allows_nothing_test() {
  assert attach_rule.limits("not json") == attach_rule.nothing
  assert attach_rule.limits("{\"count\":4}") == attach_rule.nothing
  assert attach_rule.limits("") == attach_rule.nothing
  assert attach_rule.full(attach_rule.start())
}

pub fn an_element_that_was_told_nothing_refuses_every_file_test() {
  let #(state, reads) =
    attach_rule.choose(attach_rule.start(), [file("a.png", png, 10)])
  assert reads == []
  assert state.reading == []
  assert state.notice != ""
}

pub fn a_file_of_an_allowed_type_starts_reading_test() {
  let #(state, reads) = attach_rule.choose(ready(), [file("a.png", png, 10)])
  assert reads == [#(1, "a.png")]
  assert state.reading == [Reading(1, "a.png", 10)]
  assert state.next == 2
  assert state.notice == ""
}

pub fn files_are_numbered_in_the_order_they_are_chosen_test() {
  let #(state, reads) =
    attach_rule.choose(ready(), [
      file("a.png", png, 10),
      file("b.jpg", "image/jpeg", 20),
    ])
  assert reads == [#(1, "a.png"), #(2, "b.jpg")]
  assert state.next == 3
}

pub fn a_type_the_daemon_does_not_admit_is_refused_test() {
  let #(state, reads) =
    attach_rule.choose(ready(), [
      file("logo.svg", "image/svg+xml", 10),
      file("notes.txt", "text/plain", 10),
      file("blank", "", 10),
    ])
  assert reads == []
  assert state.notice == "logo.svg is not a PNG, JPEG, GIF or WebP image."
}

pub fn a_declared_type_is_compared_without_regard_to_case_test() {
  let #(_, reads) =
    attach_rule.choose(ready(), [file("a.PNG", "IMAGE/PNG", 10)])
  assert reads == [#(1, "a.PNG")]
}

pub fn an_empty_file_is_refused_test() {
  let #(state, reads) = attach_rule.choose(ready(), [file("a.png", png, 0)])
  assert reads == []
  assert state.notice == "a.png is empty."
}

pub fn a_third_image_is_refused_when_two_places_are_taken_test() {
  let #(state, reads) =
    attach_rule.choose(ready(), [
      file("a.png", png, 10),
      file("b.png", png, 10),
      file("c.png", png, 10),
    ])
  assert reads == [#(1, "a.png"), #(2, "b.png")]
  assert state.notice == "At most 2 images can be attached."
}

// Two files chosen together cannot both take the last place: the first is
// counted as taken before the second is vetted.
pub fn a_read_in_flight_holds_its_place_test() {
  let #(state, _) = attach_rule.choose(ready(), [file("a.png", png, 10)])
  let #(state, reads) = attach_rule.choose(state, [file("b.png", png, 10)])
  assert reads == [#(2, "b.png")]
  let #(state, reads) = attach_rule.choose(state, [file("c.png", png, 10)])
  assert reads == []
  assert attach_rule.full(state)
}

pub fn the_total_size_is_bounded_and_counts_reads_in_flight_test() {
  let #(state, _) = attach_rule.choose(ready(), [file("a.png", png, 600)])
  let #(state, reads) = attach_rule.choose(state, [file("b.png", png, 401)])
  assert reads == []
  assert state.notice == "Attached images may total at most 1000 B."
  let #(_, reads) = attach_rule.choose(state, [file("b.png", png, 400)])
  assert reads == [#(2, "b.png")]
}

pub fn the_first_refusal_of_a_choice_is_the_one_said_test() {
  let #(state, _) =
    attach_rule.choose(ready(), [
      file("x.svg", "image/svg+xml", 10),
      file("y.png", png, 0),
    ])
  assert state.notice == "x.svg is not a PNG, JPEG, GIF or WebP image."
}

pub fn a_new_choice_clears_the_old_notice_test() {
  let #(state, _) =
    attach_rule.choose(ready(), [file("x.svg", "image/svg+xml", 1)])
  let #(state, _) = attach_rule.choose(state, [file("a.png", png, 10)])
  assert state.notice == ""
}

pub fn a_finished_read_is_held_where_it_was_chosen_test() {
  let #(state, _) =
    attach_rule.choose(ready(), [file("a.png", png, 10), file("b.png", png, 20)])

  // The reads finish out of order; the images are held in the order the
  // reads finish, and each keeps the number it was given.
  let state = attach_rule.loaded(state, 2, Ok("data:image/png;base64,QkJC"))
  let state = attach_rule.loaded(state, 1, Ok("data:image/png;base64,QUFB"))
  assert state.reading == []
  assert state.held
    == [Held(2, "b.png", 20, "QkJC"), Held(1, "a.png", 10, "QUFB")]
}

pub fn a_read_that_failed_or_is_not_base64_says_so_test() {
  let #(state, _) = attach_rule.choose(ready(), [file("a.png", png, 10)])
  let failed = attach_rule.loaded(state, 1, Error(Nil))
  assert failed.held == []
  assert failed.reading == []
  assert failed.notice == "Could not read a.png."
  let odd = attach_rule.loaded(state, 1, Ok("data:image/png,raw"))
  assert odd.held == []
  assert odd.notice == "Could not read a.png."
}

pub fn a_read_that_finishes_after_its_image_was_removed_adds_nothing_test() {
  let #(state, _) = attach_rule.choose(ready(), [file("a.png", png, 10)])
  let state = attach_rule.removed(state, 1)
  assert attach_rule.loaded(state, 1, Ok("data:image/png;base64,QUFB")) == state
}

pub fn data_urls_yield_only_their_base64_text_test() {
  assert attach_rule.data_of("data:image/png;base64,iVBOR") == Ok("iVBOR")
  assert attach_rule.data_of("data:image/png;charset=x;base64,iVBOR")
    == Ok("iVBOR")
  assert attach_rule.data_of("data:image/png;base64,") == Error(Nil)
  assert attach_rule.data_of("data:text/plain,hi") == Error(Nil)
  assert attach_rule.data_of("https://example.com/a.png") == Error(Nil)
  assert attach_rule.data_of("nothing") == Error(Nil)
}

pub fn removing_frees_the_place_and_drops_the_notice_test() {
  let #(state, _) =
    attach_rule.choose(ready(), [file("a.png", png, 10), file("b.png", png, 10)])
  let state = attach_rule.loaded(state, 1, Ok("data:image/png;base64,QUFB"))
  assert attach_rule.full(state)
  let state = attach_rule.removed(state, 1)
  assert !attach_rule.full(state)
  assert state.held == []
  assert state.reading == [Reading(2, "b.png", 10)]
}

pub fn the_form_field_is_the_held_images_as_a_json_array_test() {
  let state = ready()
  assert attach_rule.value(state) == Error(Nil)
  let #(state, _) =
    attach_rule.choose(state, [file("a.png", png, 10), file("b.png", png, 20)])
  let state = attach_rule.loaded(state, 1, Ok("data:image/png;base64,QUFB"))
  assert attach_rule.value(state) == Ok("[\"QUFB\"]")
  let state = attach_rule.loaded(state, 2, Ok("data:image/png;base64,QkJC"))
  assert attach_rule.value(state) == Ok("[\"QUFB\",\"QkJC\"]")
  assert attach_rule.value(attach_rule.removed(state, 1)) == Ok("[\"QkJC\"]")
  assert attach_rule.value(attach_rule.removed(attach_rule.removed(state, 1), 2))
    == Error(Nil)
}

pub fn a_long_name_is_cut_and_a_short_one_is_not_test() {
  assert attach_rule.label("a.png") == "a.png"
  let cut = attach_rule.label(string.repeat("x", 40))
  assert string.length(cut) == attach_rule.name_width
  assert string.ends_with(cut, "…")
  assert attach_rule.label(string.repeat("y", attach_rule.name_width))
    == string.repeat("y", attach_rule.name_width)
}

pub fn a_size_reads_in_the_unit_it_is_nearest_test() {
  assert attach_rule.size_text(0) == "0 B"
  assert attach_rule.size_text(1023) == "1023 B"
  assert attach_rule.size_text(1024) == "1.0 KB"
  assert attach_rule.size_text(1536) == "1.5 KB"
  assert attach_rule.size_text(1_048_576) == "1.0 MB"
  assert attach_rule.size_text(8_388_608) == "8.0 MB"
}

pub fn any_image_type_is_an_image_for_a_paste_test() {
  assert attach_rule.is_image("image/png")
  assert attach_rule.is_image("image/svg+xml")
  assert attach_rule.is_image("IMAGE/PNG")
  assert !attach_rule.is_image("text/plain")
  assert !attach_rule.is_image("")
}

pub fn dismissing_clears_the_notice_test() {
  let #(state, _) =
    attach_rule.choose(ready(), [file("x.svg", "image/svg+xml", 1)])
  assert attach_rule.dismissed(state).notice == ""
  assert list.is_empty(attach_rule.dismissed(state).held)
}
