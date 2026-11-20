//// Where a find is drawn in a review (`web_view/review_pin_rule`).

import gleam/option.{None, Some}
import session_view/diff_view
import web_view/review_feed.{File, Hunk}
import web_view/review_pin_rule as pins

fn line(kind: diff_view.Kind, new: option.Option(Int)) -> diff_view.Line {
  diff_view.Line(kind:, old: None, new:, text: "t")
}

fn file(path: String) -> review_feed.File {
  File(
    path:,
    change: review_feed.Modified,
    section: review_feed.Source,
    content: review_feed.Text,
    added: 2,
    removed: 1,
    hunks: [
      Hunk(
        header: "@@ -1,2 +1,3 @@",
        lines: [
          line(diff_view.Context, Some(40)),
          line(diff_view.Removed, None),
          line(diff_view.Added, Some(41)),
        ],
        omitted: 0,
        shortened: 0,
      ),
      Hunk(
        header: "@@ -90 +91 @@",
        lines: [line(diff_view.Added, Some(91))],
        omitted: 0,
        shortened: 0,
      ),
    ],
    hunks_omitted: 0,
    extent: review_feed.Whole,
  )
}

pub fn a_find_at_a_shown_line_is_anchored_there_test() {
  let placed =
    pins.place([file("src/a.gleam")], [
      pins.Pin("f1", Some("src/a.gleam"), Some(41)),
      pins.Pin("f2", Some("./src/a.gleam"), Some(91)),
    ])
  let assert [one] = placed.files
  assert one.anchored == [pins.Anchor(0, 2, "f1"), pins.Anchor(1, 0, "f2")]
  assert pins.at_line(one, 0, 2) == ["f1"]
  assert pins.at_line(one, 0, 1) == []
  assert one.loose == []
  assert placed.unplaced == []
}

pub fn a_find_off_the_shown_lines_is_loose_in_its_file_test() {
  let placed =
    pins.place([file("src/a.gleam")], [
      pins.Pin("cut", Some("src/a.gleam"), Some(500)),
      pins.Pin("noline", Some("src/a.gleam"), None),
    ])
  let assert [one] = placed.files
  assert one.anchored == []
  assert one.loose == ["cut", "noline"]
}

pub fn a_removed_line_has_no_new_number_to_pin_to_test() {
  let placed =
    pins.place([file("src/a.gleam")], [
      pins.Pin("f", Some("src/a.gleam"), Some(0)),
    ])
  let assert [one] = placed.files
  assert one.loose == ["f"]
}

pub fn a_find_naming_no_shown_file_is_unplaced_test() {
  let placed =
    pins.place([file("src/a.gleam")], [
      pins.Pin("other", Some("src/b.gleam"), Some(1)),
      pins.Pin("nopath", None, None),
      pins.Pin("prefix", Some("xsrc/a.gleam"), Some(41)),
    ])
  assert placed.unplaced == ["other", "nopath", "prefix"]
  let assert [one] = placed.files
  assert one.anchored == [] && one.loose == []
}
