//// Golden-file comparison for rendered frames.
////
//// A frame is a grid, and the useful assertion about one is almost never
//// "this cell holds that character" — it is "the whole thing still looks
//// like this". Written out as inline expectations that reads as noise and
//// is rewritten by hand on every layout change; written as a golden file it
//// reads as the screen and is rewritten by a flag.
////
//// `LOOM_UPDATE_SNAPSHOTS=1 gleam test` rewrites every golden this run
//// touches instead of failing. Review the resulting diff: the flag exists to
//// spare the typing, not the judgement.
////
//// The report on a mismatch is aligned by row index rather than by a
//// longest-common-subsequence walk. Two renderings of the same screen have
//// the same number of rows and row *n* means the same thing in both, so an
//// index-aligned comparison points at the row that changed, where an LCS
//// diff would report an insert and a delete for one edited character.

import gleam/int
import gleam/io
import gleam/list
import gleam/string
import simplifile
import tui/internal/ffi_bootstrap

/// Compares text against the golden of the given name, or rewrites it.
///
/// The name is a file stem under `test/snapshots`; keep it a description of
/// the state being pinned, since that is all a reader of the failure has.
///
/// ## Examples
///
/// ```gleam
/// snapshot_test.assert_snapshot("footer-one-row", frame.buffer_to_text(drawn))
/// ```
pub fn assert_snapshot(name: String, actual: String) -> Nil {
  let path = "test/snapshots/" <> name <> ".txt"
  case updating() {
    True -> write(path, actual)
    False -> compare(path, name, actual)
  }
}

// The golden is stored with exactly one trailing newline so the file is an
// ordinary text file, and the read takes exactly one back off. Stripping
// every trailing newline instead would make a frame whose last row is blank
// impossible to match against its own freshly written golden.
fn write(path: String, actual: String) -> Nil {
  case simplifile.write(path, actual <> "\n") {
    Ok(Nil) -> Nil
    Error(reason) -> {
      io.println_error(
        "cannot write snapshot " <> path <> ": " <> string.inspect(reason),
      )
      panic as "the snapshot could not be rewritten"
    }
  }
}

fn compare(path: String, name: String, actual: String) -> Nil {
  case simplifile.read(path) {
    Ok(stored) ->
      case drop_one_trailing_newline(stored) == actual {
        True -> Nil
        False -> {
          io.println(report(name, drop_one_trailing_newline(stored), actual))
          panic as "a snapshot did not match; rerun with LOOM_UPDATE_SNAPSHOTS=1 to accept"
        }
      }

    // A missing golden is reported rather than silently created: a snapshot
    // that writes itself on first run always passes, which is the one thing
    // a snapshot must not do.
    Error(_) -> {
      io.println(report(name, "", actual))
      panic as "a snapshot file is missing; rerun with LOOM_UPDATE_SNAPSHOTS=1 to create it"
    }
  }
}

// A unified-diff-shaped report: `-` is the golden, `+` is what was rendered,
// and a matching row is echoed with two leading spaces so the surrounding
// screen stays readable.
fn report(name: String, expected: String, actual: String) -> String {
  let expected_rows = string.split(expected, "\n")
  let actual_rows = string.split(actual, "\n")
  let rows = int.max(list.length(expected_rows), list.length(actual_rows))
  let body =
    numbers(rows)
    |> list.flat_map(fn(index) {
      row_report(at(expected_rows, index), at(actual_rows, index))
    })
    |> string.join("\n")
  "--- test/snapshots/" <> name <> ".txt\n+++ rendered\n" <> body
}

fn row_report(expected: Result(String, Nil), actual: Result(String, Nil)) {
  case expected, actual {
    Ok(same), Ok(also) if same == also -> ["  " <> same]
    Ok(was), Ok(now) -> ["- " <> was, "+ " <> now]
    Ok(was), Error(Nil) -> ["- " <> was]
    Error(Nil), Ok(now) -> ["+ " <> now]
    Error(Nil), Error(Nil) -> []
  }
}

fn at(rows: List(String), index: Int) -> Result(String, Nil) {
  rows |> list.drop(index) |> list.first
}

fn numbers(count: Int) -> List(Int) {
  numbers_down(count - 1, [])
}

fn numbers_down(index: Int, collected: List(Int)) -> List(Int) {
  case index < 0 {
    True -> collected
    False -> numbers_down(index - 1, [index, ..collected])
  }
}

// Exactly one, and only if it is there: the inverse of the newline `write`
// appends.
fn drop_one_trailing_newline(text: String) -> String {
  case string.ends_with(text, "\n") {
    True -> string.drop_end(text, 1)
    False -> text
  }
}

fn updating() -> Bool {
  ffi_bootstrap.getenv("LOOM_UPDATE_SNAPSHOTS") == Ok("1")
}
