//// The block summarizer's pacing, stepped event by event with no process
//// and no provider: which fragment makes a live stream due, what a request
//// that is already out does to growth, and how committed blocks queue.

import client/blocksummarybook.{
  type Launch, Job, LiveAsk, Pace, Reasoning, SettledAsk,
}
import core/clock
import core/ids.{type EntryId, type OpId}
import gleam/int
import gleam/list
import gleam/string

const pace = Pace(
  floor_bytes: 512,
  every_bytes: 4096,
  every_lines: 40,
  window_bytes: 32_768,
  settled_concurrency: 2,
  settled_backlog: 3,
)

// --- live streams ------------------------------------------------------------

// Below the floor nothing is asked, however many lines have arrived: forty
// one-word lines are a short block, and a short block keeps its digest.
pub fn a_stream_under_the_floor_asks_nothing_test() {
  let lines = string.repeat("ok\n", 60)
  let #(book, launches) = grow(blocksummarybook.new(), lines)

  assert string.byte_size(lines) < pace.floor_bytes
  assert launches == []
  assert blocksummarybook.tracks(book, "g-1")
}

// The first request waits for 4 KiB of growth, and carries all of it.
pub fn a_stream_asks_once_it_has_grown_enough_test() {
  let #(book, early) = grow(blocksummarybook.new(), string.repeat("a", 4095))
  assert early == []

  let #(_book, launches) = grow(book, "b")
  let assert [LiveAsk(generation: "g-1", strand: "main", text:, ..)] = launches
    as "the 4096th byte must launch one request"
  assert string.byte_size(text) == 4096
}

// Many short lines count as growth before their bytes would: reasoning
// written one short line at a time still earns a label once it is past
// the floor.
pub fn forty_lines_past_the_floor_ask_test() {
  let #(_book, launches) =
    grow(
      blocksummarybook.new(),
      string.repeat("a short line of reasoning\n", 40),
    )
  let assert [LiveAsk(..)] = launches as "forty lines past the floor ask"
}

// While a request is out, growth only grows the stream: however much
// arrives, no second request starts. When the first ends, exactly one
// more starts, carrying the newest text rather than a queue of snapshots.
pub fn growth_during_a_request_coalesces_into_one_test() {
  let assert #(book, [LiveAsk(..)]) =
    grow(blocksummarybook.new(), string.repeat("a", 4096))
    as "the first 4 KiB must launch"
  let #(book, during) =
    int.range(from: 1, to: 6, with: #(book, []), run: fn(acc, index) {
      let #(book, launched) = grow(acc.0, chunk(index))
      #(book, list.append(acc.1, launched))
    })
  assert during == []

  let #(book, after) = blocksummarybook.landed(book, pace, "g-1")
  let assert [LiveAsk(text:, ..)] = after
    as "the end of the first request launches exactly one more"
  assert string.ends_with(text, chunk(5))

  // That second request has everything, so its own end asks for nothing.
  let #(_book, quiet) = blocksummarybook.landed(book, pace, "g-1")
  assert quiet == []
}

// A request that ends with too little growth behind it launches nothing,
// and the next fragment that crosses the threshold does.
pub fn a_quiet_stream_waits_for_its_next_threshold_test() {
  let assert #(book, [LiveAsk(..)]) =
    grow(blocksummarybook.new(), string.repeat("a", 4096))
    as "the first 4 KiB must launch"
  let #(book, _) = grow(book, "tiny")
  let #(book, landed) = blocksummarybook.landed(book, pace, "g-1")
  assert landed == []

  let #(_book, crossed) = grow(book, string.repeat("b", 4092))
  let assert [LiveAsk(..)] = crossed as "the threshold counts from the ask"
}

// A stream that ends while a request is out is forgotten when that
// request ends, and nothing more is asked about it.
pub fn an_ended_stream_is_not_asked_again_test() {
  let assert #(book, [LiveAsk(..)]) =
    grow(blocksummarybook.new(), string.repeat("a", 4096))
    as "the first 4 KiB must launch"
  let #(book, _) = grow(book, string.repeat("b", 8192))
  let book = blocksummarybook.ended(book, "g-1")
  assert blocksummarybook.tracks(book, "g-1")

  let #(book, launches) = blocksummarybook.landed(book, pace, "g-1")
  assert launches == []
  assert !blocksummarybook.tracks(book, "g-1")
}

// A long stream keeps only its newest window, so memory and the request
// both stay bounded however long the model reasons.
pub fn a_long_stream_keeps_its_newest_window_test() {
  let small = Pace(..pace, window_bytes: 1024, every_bytes: 100_000)
  let book =
    int.range(
      from: 1,
      to: 41,
      with: blocksummarybook.new(),
      run: fn(book, index) {
        let #(book, _) =
          blocksummarybook.grow(
            book,
            small,
            generation: "g-1",
            strand: "main",
            operation: an_op(),
            chunk: string.pad_start(marker(index), 100, "."),
          )
        book
      },
    )
  let #(_book, launches) =
    blocksummarybook.grow(
      book,
      Pace(..small, every_bytes: 1),
      generation: "g-1",
      strand: "main",
      operation: an_op(),
      chunk: "",
    )
  let assert [LiveAsk(text:, ..)] = launches as "a due stream must launch"
  assert string.byte_size(text) <= 2 * 1024
  assert string.ends_with(text, marker(40))
}

// --- committed blocks ----------------------------------------------------------

// Two requests at once; the third waits for a slot and starts when one
// ends, oldest first.
pub fn settled_work_is_bounded_by_its_concurrency_test() {
  let jobs = [a_job(0), a_job(1), a_job(2)]
  let #(book, first) =
    blocksummarybook.admit(blocksummarybook.new(), pace, jobs)
  assert blocks(first) == [0, 1]
  assert blocksummarybook.waiting(book) == 1

  let #(book, next) = blocksummarybook.settled_landed(book, pace)
  assert blocks(next) == [2]
  let #(_book, none) = blocksummarybook.settled_landed(book, pace)
  assert none == []
}

// Past the backlog the oldest waiting blocks are dropped: the operator is
// reading the newest turn, and a dropped block keeps its digest.
pub fn a_full_backlog_drops_its_oldest_test() {
  let #(book, _started) =
    blocksummarybook.admit(blocksummarybook.new(), pace, [a_job(0), a_job(1)])
  let #(book, none) =
    blocksummarybook.admit(book, pace, [a_job(2), a_job(3), a_job(4), a_job(5)])
  assert none == []
  assert blocksummarybook.waiting(book) == 3

  let #(_book, next) = blocksummarybook.settled_landed(book, pace)
  assert blocks(next) == [3]
}

// --- fixtures ------------------------------------------------------------------

fn grow(
  book: blocksummarybook.Book,
  text: String,
) -> #(blocksummarybook.Book, List(Launch)) {
  blocksummarybook.grow(
    book,
    pace,
    generation: "g-1",
    strand: "main",
    operation: an_op(),
    chunk: text,
  )
}

fn chunk(index: Int) -> String {
  string.repeat("x", 4096) <> marker(index)
}

fn marker(index: Int) -> String {
  "<chunk " <> int.to_string(index) <> ">"
}

fn blocks(launches: List(Launch)) -> List(Int) {
  list.filter_map(launches, fn(launch) {
    case launch {
      SettledAsk(job:) -> Ok(job.block)
      LiveAsk(..) -> Error(Nil)
    }
  })
}

fn a_job(block: Int) -> blocksummarybook.Job {
  Job(entry: an_entry(), block:, source: Reasoning, text: "long")
}

fn an_entry() -> EntryId {
  let #(id, _generator) =
    ids.mint_entry(ids.generator(clock.fixed(at: 1000), seed: 1))
  id
}

fn an_op() -> OpId {
  let #(id, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 1000), seed: 2))
  id
}
