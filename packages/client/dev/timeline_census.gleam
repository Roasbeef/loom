//// Slice 0 of the session timeline: how many cards the cut makes of recorded
//// sessions at span limits of 20, 40 and 80 steps
//// (`docs/design-notes/session-timeline.md`, section 8). It is a developer
//// script. It adds no protocol change and no daemon code, and it reads only
//// copies of stores.
////
//// ```text
//// gleam run -m timeline_census -- <dir>
//// gleam run -m timeline_census -- timing <dir>
//// ```
////
//// The second form times the resident's `sessions.timeline` read over each copy:
//// the scan of the newest 2,000 records, the cut, the page and its encoding, with
//// the size of the reply. It is the measurement slice 1's exit criterion asks
//// for.
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
import client/timeline_read
import core/clock
import core/entry.{type Entry}
import core/json
import gleam/dict
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
import web_view/timeline_feed
import web_view/timeline_rule

/// The time the stores are opened at, in Unix milliseconds: far enough ahead
/// that a writer lease copied from a live session has expired.
const far_future = 4_000_000_000_000

/// The span limits the owner asked to compare.
const limits = [20, 40, 80]

/// One session's counts: its records and steps, and the card count at each of
/// `limits`.
type Study {
  Study(
    id: String,
    records: Int,
    steps: Int,
    counts: List(Int),
    landmarks: Int,
    turns: Int,
    eventful: Int,
  )
}

/// Runs the census over the directory named on the command line.
pub fn main() -> Nil {
  case argv.load().arguments {
    ["timing", dir] -> finish(timing(dir))
    [dir] -> finish(census(dir))
    _ -> {
      io.println_error("usage: gleam run -m timeline_census -- [timing] <dir>")
      ffi_os.halt(1)
    }
  }
}

fn finish(outcome: Result(String, String)) -> Nil {
  case outcome {
    Ok(report) -> io.println(report)
    Error(reason) -> {
      io.println_error("error: " <> reason)
      ffi_os.halt(1)
    }
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
        "session  records  steps  cards@20  cards@40  cards@80  landmarks@40  turns  eventful",
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
    landmarks: list.count(
      timeline.cut(records, timeline.default_step_limit).cards,
      fn(card) { timeline_rule.landmark(timeline_feed.of_card(card)) },
    ),
    turns: turn_count(records),
    eventful: eventful_turns(records),
  ))
}

// How many turns the strand has: its prompt cards.
fn turn_count(records: List(Entry)) -> Int {
  list.count(timeline.cut(records, timeline.default_step_limit).cards, fn(card) {
    card.kind == timeline.Prompted
  })
}

// How many turns wrote a file, hit a failure or compacted or asked: the turns a
// tighter landmark set would keep.
fn eventful_turns(records: List(Entry)) -> Int {
  timeline.cut(records, timeline.default_step_limit).cards
  |> list.group(fn(card) { card.turn_seq })
  |> dict.values
  |> list.count(fn(cards) {
    list.any(cards, fn(card) {
      card.facts.files_total > 0
      || card.facts.failed > 0
      || card.kind == timeline.Asked
      || card.kind == timeline.Compacted
      || card.kind == timeline.Reported
    })
  })
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
      ..list.append(
        list.map(study.counts, fn(count) {
          string.pad_start(int.to_string(count), 9, " ")
        }),
        [
          string.pad_start(int.to_string(study.landmarks), 13, " "),
          string.pad_start(int.to_string(study.turns), 6, " "),
          string.pad_start(int.to_string(study.eventful), 9, " "),
        ],
      )
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

// --- timing -------------------------------------------------------------------

/// Times the resident's read over every copied store and prints a line each and
/// the spread of the times.
fn timing(dir: String) -> Result(String, String) {
  use files <- result.try(
    simplifile.get_files(dir)
    |> result.replace_error("the directory cannot be read"),
  )
  let timed =
    list.filter(files, string.ends_with(_, ".db"))
    |> list.sort(string.compare)
    |> list.filter_map(time_one)
  let times = list.map(timed, fn(each) { each.1 }) |> list.sort(int.compare)

  Ok(
    string.join(
      [
        "session  scanned  read_ms  reply_bytes",
        ..list.map(timed, fn(each) {
          string.pad_end(each.0, 8, " ")
          <> " "
          <> string.pad_start(int.to_string(each.2), 7, " ")
          <> " "
          <> string.pad_start(int.to_string(each.1), 8, " ")
          <> " "
          <> string.pad_start(int.to_string(each.3), 11, " ")
        })
      ],
      "\n",
    )
    <> "\n\nsessions "
    <> int.to_string(list.length(times))
    <> " min "
    <> int.to_string(nth(times, 0))
    <> " median "
    <> int.to_string(nth(times, list.length(times) / 2))
    <> " p90 "
    <> int.to_string(nth(times, list.length(times) * 9 / 10))
    <> " max "
    <> int.to_string(nth(times, list.length(times) - 1))
    <> " ms",
  )
}

// One copy's read: the newest 2,000 records scanned, cut and paged, with the
// time it took and the size of the encoded reply.
fn time_one(path: String) -> Result(#(String, Int, Int, Int), Nil) {
  use opened <- result.try(
    session.open_sqlite(
      path:,
      owner: "timeline-census",
      lease_ttl_ms: 600_000,
      clock: clock.fixed(at: far_future),
    )
    |> result.replace_error(Nil),
  )
  use leaf <- result.try(
    session.strand_leaf(opened, "main") |> result.replace_error(Nil),
  )

  case leaf {
    Some(session.Cell(value: Some(newest), ..)) -> {
      let started = ffi_os.system_time_ms()
      let scanned =
        storage.scan_branch(
          opened.store,
          storage.branch_scan(newest)
            |> storage.branch_limit(timeline_read.scan_cap),
        )
      let _ = session.close(opened)

      use newest_first <- result.try(scanned |> result.replace_error(Nil))
      let feed = timeline_read.of_records(list.reverse(newest_first), None, 10)
      let bytes = string.byte_size(json.to_string(timeline_feed.to_json(feed)))

      Ok(#(
        string.slice(last_segment(path), 0, 8),
        ffi_os.system_time_ms() - started,
        list.length(newest_first),
        bytes,
      ))
    }
    Some(session.Cell(value: None, ..)) | None -> {
      let _ = session.close(opened)
      Error(Nil)
    }
  }
}
