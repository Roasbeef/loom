//// Slice 0 of the session timeline: how many cards the cut makes of recorded
//// sessions at span limits of 20, 40 and 80 steps
//// (`docs/design-notes/session-timeline.md`, section 8). It is a developer
//// script. It adds no protocol change and no daemon code, and it reads only
//// copies of stores.
////
//// ```text
//// gleam run -m timeline_census -- <dir>
//// ```
////
//// `<dir>` holds `*.db` session stores, copies made with
//// `sqlite3 <source> ".backup '<copy>'"`. Nothing here opens a live store: the
//// session layer takes a writer lease on open, and a copy is the only file it
//// may take one on. A copy of a live session may carry an unexpired lease, so
//// the stores are opened under a clock far in the future.
////
//// ## Flow
////
//// `census` → `study` → `lineage` → `row` → `spread`
////
//// 1. `census` lists the copied stores and studies each.
//// 2. `study` opens one, reads the `main` strand's branch oldest first and cuts
////    it at each limit.
//// 3. `row` prints one line per session, and `spread` prints the distribution
////    of each limit's card counts.

import argv
import client/internal/ffi_os
import core/clock
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import session/session
import session_view/timeline
import simplifile
import storage/storage

/// The time the stores are opened at, in Unix milliseconds: far enough ahead
/// that a writer lease copied from a live session has expired.
const far_future = 4_000_000_000_000

/// The span limits the owner asked to compare.
const limits = [20, 40, 80]

/// One session's counts: its records and steps, and the card count at each of
/// `limits`.
type Study {
  Study(id: String, records: Int, steps: Int, counts: List(Int))
}

/// Runs the census over the directory named on the command line.
pub fn main() -> Nil {
  case argv_dir() {
    Ok(dir) ->
      case census(dir) {
        Ok(report) -> io.println(report)
        Error(reason) -> {
          io.println_error("error: " <> reason)
          ffi_os.halt(1)
        }
      }
    Error(Nil) -> {
      io.println_error("usage: gleam run -m timeline_census -- <dir>")
      ffi_os.halt(1)
    }
  }
}

fn argv_dir() -> Result(String, Nil) {
  case argv.load().arguments {
    [dir, ..] -> Ok(dir)
    [] -> Error(Nil)
  }
}

// Studies every copied store under `dir` and prints the table and the spread.
fn census(dir: String) -> Result(String, String) {
  use files <- result.try(
    simplifile.get_files(dir)
    |> result.replace_error("the directory cannot be read"),
  )
  let studied =
    list.filter(files, string.ends_with(_, ".db"))
    |> list.sort(string.compare)
    |> list.filter_map(study)

  Ok(
    string.join(
      [
        "session  records  steps  cards@20  cards@40  cards@80",
        ..list.map(studied, row)
      ],
      "\n",
    )
    <> "\n\n"
    <> spread(studied),
  )
}

// Opens one copied store, reads `main`'s branch oldest first and cuts it. A
// store with no `main` leaf is skipped.
fn study(path: String) -> Result(Study, Nil) {
  use opened <- result.try(
    session.open_sqlite(
      path:,
      owner: "timeline-census",
      lease_ttl_ms: 600_000,
      clock: clock.fixed(at: far_future),
    )
    |> result.replace_error(Nil),
  )
  let found = lineage(opened)
  let _ = session.close(opened)

  use records <- result.try(found)

  Ok(Study(
    id: string.slice(last_segment(path), 0, 8),
    records: list.length(records),
    steps: list.fold(timeline.cut(records, 1_000_000).cards, 0, fn(sum, card) {
      sum + card.facts.steps
    }),
    counts: list.map(limits, fn(limit) {
      let cut = timeline.cut(records, limit)
      list.length(cut.cards) + open_count(cut)
    }),
  ))
}

fn open_count(cut: timeline.Cut) -> Int {
  case cut.open {
    Some(_) -> 1
    None -> 0
  }
}

// The `main` strand's records, oldest first.
fn lineage(opened: session.Session) {
  use leaf <- result.try(
    session.strand_leaf(opened, "main") |> result.replace_error(Nil),
  )

  case leaf {
    Some(session.Cell(value: Some(newest), ..)) ->
      storage.scan_branch(opened.store, storage.branch_scan(from: newest))
      |> result.map(list.reverse)
      |> result.replace_error(Nil)
    Some(session.Cell(value: None, ..)) | None -> Error(Nil)
  }
}

fn last_segment(path: String) -> String {
  case list.last(string.split(path, "/")) {
    Ok(name) -> name
    Error(Nil) -> path
  }
}

fn row(study: Study) -> String {
  string.join(
    [
      string.pad_end(study.id, 8, " "),
      string.pad_start(int.to_string(study.records), 7, " "),
      string.pad_start(int.to_string(study.steps), 6, " "),
      ..list.map(study.counts, fn(count) {
        string.pad_start(int.to_string(count), 9, " ")
      })
    ],
    " ",
  )
}

// The least, median, 90th percentile and greatest card count at each limit.
fn spread(studied: List(Study)) -> String {
  list.index_map(limits, fn(limit, at) {
    let counts =
      list.filter_map(studied, fn(study) {
        list.drop(study.counts, at) |> list.first
      })
      |> list.sort(int.compare)
    let size = list.length(counts)

    "limit "
    <> int.to_string(limit)
    <> ": sessions "
    <> int.to_string(size)
    <> " min "
    <> int.to_string(nth(counts, 0))
    <> " median "
    <> int.to_string(nth(counts, size / 2))
    <> " p90 "
    <> int.to_string(nth(counts, size * 9 / 10))
    <> " max "
    <> int.to_string(nth(counts, size - 1))
  })
  |> string.join("\n")
}

fn nth(sorted: List(Int), index: Int) -> Int {
  case list.drop(sorted, int.max(0, index)) {
    [value, ..] -> value
    [] -> 0
  }
}
