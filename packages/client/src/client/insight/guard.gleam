//// The checks that keep an owner's marks from being scored against the wrong
//// rows.
////
//// A mark reaches a row only by its number within a session, and a number
//// means the same row only while the selection, `rows.json`, the model's
//// record and the sheet were all written from one selection. A reselection, a
//// sheet regenerated over marks, or a line deleted or duplicated while
//// marking would each shift a number silently, and the verdict would then
//// grade the model against rows the owner never judged. These checks turn
//// each of those into a refusal that names the session, rather than a score.
////
//// ## Flow
////
//// `write_sheet` → `refuse_existing`, and `session` → `same_rows` →
//// `same_numbers` → `whole_marks`.
////
//// `write_sheet` refuses to overwrite a sheet. `session` runs the three
//// equalities for one session at verdict time, and the first to fail names
//// the session.

import client/insight/sheet.{type Mark, type SheetSession}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/order
import gleam/result
import simplifile

/// Writes the label sheet and its twin, refusing when a sheet is already
/// there. An existing sheet may hold the owner's marks, and writing a new one
/// over it would erase an hour of work, so the owner deletes it first.
///
/// ## Examples
///
/// ```gleam
/// // guard.write_sheet("/path/to/dir", selection)
/// ```
pub fn write_sheet(
  dir: String,
  selection: List(SheetSession),
) -> Result(String, String) {
  let path = dir <> "/label-sheet.md"

  use _ <- result.try(refuse_existing(path))
  use _ <- result.try(
    simplifile.write(path, sheet.render(selection))
    |> result.map_error(fn(_) { path <> " cannot be written" }),
  )
  use _ <- result.try(
    simplifile.write(dir <> "/rows.json", sheet.rows_json(selection))
    |> result.map_error(fn(_) { "rows.json cannot be written" }),
  )

  Ok(
    "sheet written for "
    <> int.to_string(list.length(selection))
    <> " sessions: "
    <> path,
  )
}

/// Refuses a path that already holds a file.
fn refuse_existing(path: String) -> Result(Nil, String) {
  case simplifile.is_file(path) {
    Ok(True) ->
      Error(
        path
        <> " already exists and may hold marks. Delete it first to write a new sheet.",
      )
    Ok(False) | Error(_) -> Ok(Nil)
  }
}

/// Checks that one session's record, `rows.json` entry and marks all describe
/// the rows the selection lists, in the order it lists them.
///
/// ## Examples
///
/// ```gleam
/// assert guard.session(sheet.SheetSession("s", "n", 0, []), [], dict.new(), [])
///   == Ok(Nil)
/// ```
pub fn session(
  chosen: SheetSession,
  recorded: List(String),
  numbers: Dict(String, Int),
  marks: List(#(Int, Mark)),
) -> Result(Nil, String) {
  let keys = list.map(chosen.rows, fn(row) { row.key })

  use _ <- result.try(same_rows(chosen.id, keys, recorded))
  use _ <- result.try(same_numbers(chosen.id, keys, numbers))

  whole_marks(chosen.id, list.length(keys), marks)
}

/// The record must have been made for the selection's rows, in its order.
fn same_rows(
  id: String,
  keys: List(String),
  recorded: List(String),
) -> Result(Nil, String) {
  case recorded == keys {
    True -> Ok(Nil)
    False ->
      Error(
        id
        <> ": the record was made for different rows than the selection lists. Delete it and run again.",
      )
  }
}

/// `rows.json` must number the selection's rows one to the row count, in the
/// selection's order.
fn same_numbers(
  id: String,
  keys: List(String),
  numbers: Dict(String, Int),
) -> Result(Nil, String) {
  let wanted = list.index_map(keys, fn(key, index) { #(key, index + 1) })

  // Every key must hold exactly the number its place in the selection gives.
  case dict.to_list(numbers) |> list.sort(by_number) == wanted {
    True -> Ok(Nil)
    False ->
      Error(id <> ": rows.json numbers different rows than the selection lists")
  }
}

/// The sheet's numbers must be exactly one to the row count, each once: a
/// duplicated line would give one row two marks and a deleted one would shift
/// every mark after it.
fn whole_marks(
  id: String,
  rows: Int,
  marks: List(#(Int, Mark)),
) -> Result(Nil, String) {
  let seen = list.map(marks, fn(mark) { mark.0 }) |> list.sort(int.compare)
  let expected =
    list.index_map(list.repeat(Nil, rows), fn(_, index) { index + 1 })

  // Anything but the full run of numbers means a line was lost or repeated.
  case seen == expected {
    True -> Ok(Nil)
    False ->
      Error(
        id
        <> ": the sheet's row numbers are not exactly 1 to "
        <> int.to_string(rows)
        <> ", so a line was lost or repeated",
      )
  }
}

/// Orders rows by their number.
fn by_number(left: #(String, Int), right: #(String, Int)) -> order.Order {
  int.compare(left.1, right.1)
}
