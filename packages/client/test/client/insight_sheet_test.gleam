//// The label sheet and its twin, and the reading of the owner's marks back.

import client/insight/record
import client/insight/sheet
import gleam/dict
import gleam/list
import gleam/string

fn sessions() -> List(sheet.SheetSession) {
  [
    sheet.SheetSession("s1", "CI fixes", 1_700_000_000_000, [
      sheet.SheetRow("work:1.0", "Failed", "Ran make · exit 2"),
      sheet.SheetRow("2.0", "Result", "no change needed"),
    ]),
    sheet.SheetSession("s2", "pool\nrelease", 1_700_086_400_000, [
      sheet.SheetRow("3.0", "Failed", "boom"),
    ]),
  ]
}

pub fn the_sheet_shows_names_dates_and_numbered_checkboxes_only_test() {
  let text = sheet.render(sessions())

  assert string.contains(text, "## 1. CI fixes · 2023-11-14")
  assert string.contains(text, "Session `s1`")
  assert string.contains(text, "- [ ] 1. Failed · Ran make · exit 2")
  assert string.contains(text, "- [ ] 2. Result · no change needed")
  assert string.contains(text, "## 2. pool release · 2023-11-15")

  // A key is the classifier's identity and stays out of what the owner reads.
  assert !string.contains(text, "work:1.0")
}

pub fn the_twin_is_keyed_by_session_and_row_key_and_counts_rows_test() {
  let text = sheet.rows_json(sessions())

  assert string.contains(text, "\"work:1.0\"")
  assert sheet.row_counts(text) == Ok(dict.from_list([#("s1", 2), #("s2", 1)]))
  assert sheet.rows_json([]) == "{}"
}

pub fn a_checked_box_is_open_first_and_an_empty_one_is_skippable_test() {
  let text =
    "# notes the owner wrote\n\n## 1. a · d\nSession `s1`\n\n- [x] 1. Failed · a\n- [ ] 2. Result · b\n- [X] 3. Failed · c\nstray line\n\nSession `s2`\n- [ ] 1. Failed · d\n"

  assert sheet.marks(text)
    == dict.from_list([
      #("s1", [#(1, sheet.Open), #(2, sheet.Skip), #(3, sheet.Open)]),
      #("s2", [#(1, sheet.Skip)]),
    ])
}

pub fn a_box_before_any_session_line_belongs_to_no_session_test() {
  assert sheet.marks("- [x] 1. Failed · orphan") == dict.new()
}

pub fn a_rendered_sheet_reads_back_as_all_skippable_test() {
  let marked = sheet.marks(sheet.render(sessions()))

  assert dict.get(marked, "s1") == Ok([#(1, sheet.Skip), #(2, sheet.Skip)])
  assert list.length(dict.keys(marked)) == 2
}

pub fn the_selection_file_round_trips_test() {
  assert sheet.read_selection(sheet.selection_json(sessions()))
    == Ok(sessions())
  assert sheet.read_selection("{}")
    == Error("the selection file does not hold sessions")
}

pub fn a_record_round_trips_and_a_stranger_is_refused_test() {
  let held =
    record.Record("s1", "summarize", "entry model-id", "prompt", "1 high x", [
      "k1",
    ])

  assert record.decode(record.encode(held)) == Ok(held)
  assert record.decode("{}") == Error("the record file is not a triage record")
}
