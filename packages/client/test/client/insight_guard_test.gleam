//// The guards that keep the owner's marks on the rows they were made for.

import client/insight/guard
import client/insight/sheet
import gleam/dict
import gleam/string
import simplifile

fn chosen() -> sheet.SheetSession {
  sheet.SheetSession("s", "n", 0, [
    sheet.SheetRow("a", "Failed", "x"),
    sheet.SheetRow("b", "Failed", "y"),
    sheet.SheetRow("c", "Result", "z"),
  ])
}

fn numbers() -> dict.Dict(String, Int) {
  dict.from_list([#("a", 1), #("b", 2), #("c", 3)])
}

fn marks() -> List(#(Int, sheet.Mark)) {
  [#(1, sheet.Open), #(2, sheet.Skip), #(3, sheet.Skip)]
}

fn refusal(result: Result(Nil, String)) -> String {
  let assert Error(reason) = result as "the check must refuse"
  reason
}

pub fn agreeing_inputs_pass_test() {
  assert guard.session(chosen(), ["a", "b", "c"], numbers(), marks()) == Ok(Nil)
}

pub fn a_record_made_for_other_rows_is_refused_test() {
  assert string.contains(
    refusal(guard.session(chosen(), ["a", "x", "c"], numbers(), marks())),
    "different rows",
  )
  assert string.contains(
    refusal(guard.session(chosen(), ["c", "b", "a"], numbers(), marks())),
    "different rows",
  )
}

pub fn a_rows_json_that_numbers_other_rows_is_refused_test() {
  let reselected = dict.from_list([#("a", 1), #("q", 2), #("c", 3)])
  let reordered = dict.from_list([#("a", 2), #("b", 1), #("c", 3)])

  assert string.contains(
    refusal(guard.session(chosen(), ["a", "b", "c"], reselected, marks())),
    "rows.json",
  )
  assert string.contains(
    refusal(guard.session(chosen(), ["a", "b", "c"], reordered, marks())),
    "rows.json",
  )
}

pub fn a_duplicated_or_deleted_sheet_line_is_refused_test() {
  let duplicated = [#(1, sheet.Open), #(1, sheet.Open), #(2, sheet.Skip)]
  let deleted = [#(1, sheet.Open), #(3, sheet.Skip)]
  let extra = [
    #(1, sheet.Open),
    #(2, sheet.Skip),
    #(3, sheet.Skip),
    #(4, sheet.Skip),
  ]

  assert string.contains(
    refusal(guard.session(chosen(), ["a", "b", "c"], numbers(), duplicated)),
    "lost or repeated",
  )
  assert string.contains(
    refusal(guard.session(chosen(), ["a", "b", "c"], numbers(), deleted)),
    "lost or repeated",
  )
  assert string.contains(
    refusal(guard.session(chosen(), ["a", "b", "c"], numbers(), extra)),
    "lost or repeated",
  )
}

pub fn an_existing_sheet_is_never_overwritten_test() {
  let dir = "build/insight_guard_test_sheet"
  let _ = simplifile.delete(dir)
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
    as "the scratch directory is created"

  let assert Ok(_) = guard.write_sheet(dir, [chosen()])
    as "a first write succeeds"
  let assert Ok(Nil) =
    simplifile.write(dir <> "/label-sheet.md", "- [x] 1. mine")
    as "the owner marks it"

  assert string.contains(
    refusal(guard.write_sheet(dir, [chosen()]) |> result_nil),
    "Delete it first",
  )
  assert simplifile.read(dir <> "/label-sheet.md") == Ok("- [x] 1. mine")
  let _ = simplifile.delete(dir)
}

fn result_nil(written: Result(String, String)) -> Result(Nil, String) {
  case written {
    Ok(_) -> Ok(Nil)
    Error(reason) -> Error(reason)
  }
}
