//// A long notice wraps in the band above the composer instead of being cut at
//// the edge. The refusal for a removed model profile names the configuration
//// file's path and then the profiles that are defined; the footer used to
//// end at `defines: b…`, dropping the names the operator needed.

import etui/backend
import gleam/list
import gleam/option.{None}
import gleam/string
import session_view/shared_set
import tui
import tui/connection
import tui/layout
import tui/model as tui_model
import tui/workspace

const refusal =
  "open session: session startup failed: /Users/someone/loom-drives/r8/state/loom.toml: unknown profile \"alpha\"; the configuration defines: beta, gamma"

fn model_with(notice: String, width: Int) -> tui_model.Model {
  let base =
    tui.new_model_with_clock(
      connection.new_inbox(),
      workspace.Context("/work", None),
      fn() { 0 },
    )
  let sized =
    tui.update(
      backend.Resize(width, 30),
      tui_model.Model(..base, shared: shared_set.notice(base.shared, notice)),
    )

  // The resize leaves the notice alone, but a step may clear it; the notice
  // is set again so the test reads the band for exactly this text.
  tui_model.Model(..sized, shared: shared_set.notice(sized.shared, notice))
}

pub fn a_long_refusal_wraps_and_keeps_the_defined_profiles_test() {
  let rows = layout.composer_status_lines(model_with(refusal, 100))
  let joined = string.join(rows, " ")

  assert list.length(rows) >= 2
  assert string.contains(joined, "the configuration defines: beta, gamma")
  assert !string.contains(joined, "…")
}

// The band used to cut each row at the width, so `attempts` could be left as
// `att` at the end of one row and `empts` at the start of the next. A row
// now ends at a word boundary: every word on every row is a whole word of the
// notice, at each width that could put a cut inside one.
pub fn a_wrapped_notice_never_splits_a_word_test() {
  let words = string.split(refusal, " ")
  list.each([70, 73, 77, 81, 86, 90, 95, 99, 104, 111, 120], fn(width) {
    let others = layout.composer_status_lines(model_with("", width))
    let rows = layout.composer_status_lines(model_with(refusal, width))
    let mine = list.filter(rows, fn(row) { !list.contains(others, row) })
    assert list.length(mine) >= 2
    list.each(mine, fn(row) {
      list.each(string.split(row, " "), fn(word) {
        assert list.contains(words, word) as { "split word " <> word }
      })
    })
  })
}

// A word longer than a whole row cannot stay whole, and is the one case that
// breaks inside a word.
pub fn a_word_longer_than_the_row_is_broken_only_then_test() {
  let rows =
    layout.composer_status_lines(model_with(string.repeat("x", 120), 60))
  let mine = list.filter(rows, string.contains(_, "x"))
  assert list.length(mine) >= 2
}

pub fn a_notice_that_fits_stays_one_row_test() {
  assert layout.composer_status_lines(model_with("copied 2 lines", 100))
    == ["copied 2 lines"]
}

pub fn a_notice_longer_than_three_rows_ends_in_an_ellipsis_test() {
  let rows =
    layout.composer_status_lines(model_with(string.repeat("word ", 200), 60))

  // Other band rows may stand beside the notice; its own are the ones that
  // hold its words.
  let mine = list.filter(rows, string.contains(_, "word"))
  assert list.length(mine) == 3
  let assert Ok(last) = list.last(mine)
  assert string.ends_with(last, "…")
}
