//// Glance tests pin the stored shape, the total decoder, the key
//// convention both sides share, and the one-line clipping every writer
//// relies on.

import core/glance.{Glance}
import core/json
import gleam/list
import gleam/string
import support/generate

fn sample() -> glance.Glance {
  Glance(
    operation: "op-7",
    title: "Audit funding panics",
    summary: "Reading fundeeProcessOpenChannel in manager.go",
    at: 1_790_000_000_000,
    tokens: 58_200,
  )
}

pub fn a_glance_round_trips_through_its_codec_test() {
  assert glance.decode(glance.encode(sample())) == Ok(sample())
}

pub fn a_glance_round_trips_through_json_text_test() {
  let text = json.to_string(glance.encode(sample()))
  let assert Ok(value) = json.parse(text) as "an encoded glance is valid JSON"
  assert glance.decode(value) == Ok(sample())
}

// A newer daemon may add fields; an older terminal must still read the
// ones it knows rather than refusing the whole cell.
pub fn unknown_fields_are_ignored_test() {
  let assert json.Object(fields) = glance.encode(sample())
    as "a glance encodes as an object"
  let widened = json.Object(list.append(fields, [#("model", json.String("x"))]))
  assert glance.decode(widened) == Ok(sample())
}

pub fn every_missing_or_mistyped_field_is_a_corruption_report_test() {
  let assert json.Object(fields) = glance.encode(sample())
    as "a glance encodes as an object"
  list.each(fields, fn(pair) {
    let #(name, _) = pair
    let without = json.Object(list.filter(fields, fn(f) { f.0 != name }))
    let assert Error(_) = glance.decode(without)
      as "a glance without its field is refused"
    let mistyped =
      json.Object(
        list.map(fields, fn(f) {
          case f.0 == name {
            True -> #(name, json.Bool(True))
            False -> f
          }
        }),
      )
    let assert Error(_) = glance.decode(mistyped)
      as "a glance with a mistyped field is refused"
  })
}

pub fn non_objects_are_refused_test() {
  list.each(
    [json.Null, json.String("x"), json.Int(1), json.Array([]), json.Bool(False)],
    fn(value) {
      let assert Error(_) = glance.decode(value)
        as "only an object can be a glance"
    },
  )
}

pub fn a_key_names_its_strand_and_nothing_else_test() {
  assert glance.strand_of(glance.key("sub:main/audit-1a2b"))
    == Ok("sub:main/audit-1a2b")
  assert glance.strand_of(glance.key("main")) == Ok("main")
  assert glance.strand_of("client/glance/") == Error(Nil)
  assert glance.strand_of("client/run_settings") == Error(Nil)
  assert glance.strand_of("x/client/glance/main") == Error(Nil)
}

pub fn clip_collapses_whitespace_to_one_line_test() {
  assert glance.clip("  Reading\n\tmanager.go\r\n  now ", 64)
    == "Reading manager.go now"
  assert glance.clip("", 64) == ""
  assert glance.clip(" \n\t ", 64) == ""
}

pub fn clip_leaves_a_line_that_fits_untouched_test() {
  assert glance.clip("abcdef", 6) == "abcdef"
}

pub fn clip_marks_a_cut_with_an_ellipsis_test() {
  assert glance.clip("abcdefgh", 6) == "abc…"
}

// The cut is taken on grapheme boundaries and the result, ellipsis
// included, never exceeds the byte bound it was given, for every prefix
// length of a string mixing one-, two-, three- and four-byte characters.
pub fn clip_never_exceeds_its_bound_or_splits_a_character_test() {
  let text = "aé中🦀 bé中🦀 cé中🦀 dé中🦀 eé中🦀"
  list.each(generate.range(from: 4, to: string.byte_size(text) + 2), fn(bound) {
    let clipped = glance.clip(text, bound)
    assert string.byte_size(clipped) <= bound
    assert string.starts_with(text, string.drop_end(clipped, 1))
      || clipped == text
  })
}
