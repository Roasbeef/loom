//// The block summarizer's bookkeeping, as pure functions of the book and
//// one event.
////
//// `client/blocksummary` runs one state machine per session that asks the
//// `summarize` route for short labels of long reasoning blocks and long
//// delivered advisor messages (protocol 050). Two kinds of work reach it,
//// and they are paced differently.
////
//// **A committed block** is asked about once. The work arrives in bursts —
//// one commit can carry several long blocks, and a session that has just
//// settled a long turn may commit a dozen — so settled work waits in a
//// short queue and at most `Pace.settled_concurrency` requests are out at
//// once. The queue is bounded by `Pace.settled_backlog`; past it the
//// oldest waiting block is dropped, because the operator is reading the
//// newest turn and a dropped block keeps today's first-line digest.
////
//// **A block still streaming** is asked about repeatedly, because its text
//// keeps growing. Each stream has at most one request out at a time, and
//// growth that arrives while one is out is not queued as another request.
//// It is compared against the stream's size when the outstanding request
//// began, once that request has ended, and one new request is launched if
//// the stream has grown by `Pace.every_bytes` or `Pace.every_lines` since
//// then. However fast the provider writes, a stream therefore costs one
//// request per summarizer round trip at most, and the newest text is what
//// the next request is sent.
////
//// Nothing here performs I/O or reads a clock. The machine applies each
//// plan's launches and reports each request's end back as an event, which
//// is what makes the pacing testable without a process or a provider.

import core/ids.{type EntryId, type OpId}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/string

/// The knobs the book paces by. `default_pace` in production.
pub type Pace {
  Pace(
    /// The least source text, in bytes, any request is made for. A block
    /// shorter than this keeps the terminal's first-line digest, which
    /// already says most of what a short block contains.
    floor_bytes: Int,
    /// A live stream is asked about again once it has grown by this many
    /// bytes since the last request for it began.
    every_bytes: Int,
    /// Or by this many lines, whichever comes first. Reasoning written as
    /// many short lines grows slowly in bytes and quickly in rows.
    every_lines: Int,
    /// How many of a live stream's newest bytes are kept for its next
    /// request. The text is trimmed to this once it has grown to twice
    /// the figure, so a long stream costs bounded memory and a request is
    /// sent at most twice this much.
    window_bytes: Int,
    /// How many requests about committed blocks may be out at once.
    settled_concurrency: Int,
    /// How many committed blocks may wait for a request slot.
    settled_backlog: Int,
  )
}

/// The shipped pacing: a 512-byte floor (eight times the terminal's
/// 64-cell digest), a new live request per 4 KiB or 40 lines of growth, a
/// 32 KiB live window, two settled requests at once and sixteen waiting.
pub const default_pace = Pace(
  floor_bytes: 512,
  every_bytes: 4096,
  every_lines: 40,
  window_bytes: 32_768,
  settled_concurrency: 2,
  settled_backlog: 16,
)

/// What a block's text is, which decides how the summarizer is asked
/// about it.
pub type Source {
  /// A model's reasoning block.
  Reasoning

  /// The body of an advice or queued-nudges message the advisor delivered
  /// to the primary.
  AdvisorMessage
}

/// One committed block waiting to be summarized.
///
/// Constructor invariants: `block` is the block's index in its message's
/// content list; `text` is the whole source text, at least the pace's
/// floor in bytes.
pub type Job {
  Job(entry: EntryId, block: Int, source: Source, text: String)
}

/// One request the machine should start.
pub type Launch {
  /// Summarize a committed block and store the result.
  SettledAsk(job: Job)

  /// Summarize the newest text of a live reasoning stream and push the
  /// result without storing it.
  LiveAsk(generation: String, strand: String, operation: OpId, text: String)
}

/// Everything the book knows between events.
pub opaque type Book {
  Book(streams: Dict(String, Live), waiting: List(Job), asking: Int)
}

// One live stream. `chunks` holds its newest text, newest chunk first, and
// `retained` their byte count; `bytes` and `lines` count everything the
// stream has carried, and `asked_bytes` and `asked_lines` what it had
// carried when its last request began.
type Live {
  Live(
    strand: String,
    operation: OpId,
    chunks: List(String),
    retained: Int,
    bytes: Int,
    lines: Int,
    asked_bytes: Int,
    asked_lines: Int,
    flight: Flight,
    ending: Ending,
  )
}

// Whether a stream has a request out.
type Flight {
  Idle

  Asking
}

// Whether the provider is still writing the stream. A stream that ends
// with a request out is kept until that request's end is reported, so the
// report finds it and does not launch again.
type Ending {
  Open

  Closed
}

/// A book with no streams and no waiting work.
///
/// ## Examples
///
/// ```gleam
/// assert blocksummarybook.streams(blocksummarybook.new()) == 0
/// ```
///
pub fn new() -> Book {
  Book(streams: dict.new(), waiting: [], asking: 0)
}

/// How many live streams the book is tracking.
///
/// ## Examples
///
/// ```gleam
/// assert blocksummarybook.streams(blocksummarybook.new()) == 0
/// ```
///
pub fn streams(book: Book) -> Int {
  dict.size(book.streams)
}

/// Whether the book is tracking the live stream `generation`: it has seen
/// a fragment of it and has not yet forgotten it.
///
/// ## Examples
///
/// ```gleam
/// assert !blocksummarybook.tracks(blocksummarybook.new(), "g-1")
/// ```
///
pub fn tracks(book: Book, generation: String) -> Bool {
  dict.has_key(book.streams, generation)
}

/// How many committed blocks are waiting for a request slot.
///
/// ## Examples
///
/// ```gleam
/// assert blocksummarybook.waiting(blocksummarybook.new()) == 0
/// ```
///
pub fn waiting(book: Book) -> Int {
  list.length(book.waiting)
}

// --- live streams ------------------------------------------------------------

/// Records one reasoning fragment of the stream `generation` and says
/// whether it has grown enough to be asked about.
///
/// `strand` and `operation` are the stream's identity, recorded the first
/// time the stream is seen. A launch is due when the stream has no request
/// out, has carried at least the floor, and has grown by the pace's bytes
/// or lines since its last request began. A fragment that arrives while a
/// request is out only grows the stream; `landed` asks the question again
/// when that request ends.
///
/// ## Examples
///
/// ```gleam
/// // let #(_book, launches) =
/// //   blocksummarybook.grow(book, pace, generation: "g-1", strand: "main",
/// //     operation: op, chunk: "short")
/// // launches == []
/// ```
///
pub fn grow(
  book: Book,
  pace: Pace,
  generation generation: String,
  strand strand: String,
  operation operation: OpId,
  chunk chunk: String,
) -> #(Book, List(Launch)) {
  let live = case dict.get(book.streams, generation) {
    Ok(live) -> live
    Error(Nil) ->
      Live(
        strand:,
        operation:,
        chunks: [],
        retained: 0,
        bytes: 0,
        lines: 0,
        asked_bytes: 0,
        asked_lines: 0,
        flight: Idle,
        ending: Open,
      )
  }
  let size = string.byte_size(chunk)
  let live =
    Live(
      ..live,
      chunks: [chunk, ..live.chunks],
      retained: live.retained + size,
      bytes: live.bytes + size,
      lines: live.lines + newlines(chunk),
    )
    |> trim(pace)

  consider(book, pace, generation, live)
}

/// Records that the provider stopped writing the stream `generation`. A
/// stream with no request out is forgotten at once; one with a request
/// out is forgotten when `landed` reports that request's end.
///
/// ## Examples
///
/// ```gleam
/// let book = blocksummarybook.ended(blocksummarybook.new(), "g-1")
/// assert blocksummarybook.streams(book) == 0
/// ```
///
pub fn ended(book: Book, generation: String) -> Book {
  case dict.get(book.streams, generation) {
    Error(Nil) -> book
    Ok(Live(flight: Idle, ..)) ->
      Book(..book, streams: dict.delete(book.streams, generation))
    Ok(Live(flight: Asking, ..) as live) -> {
      let closed = Live(..live, ending: Closed)
      Book(..book, streams: dict.insert(book.streams, generation, closed))
    }
  }
}

/// Records that the request out for the stream `generation` has ended,
/// however it ended, and says whether the growth that arrived meanwhile
/// is enough to ask again.
///
/// ## Examples
///
/// ```gleam
/// let #(_book, launches) =
///   blocksummarybook.landed(
///     blocksummarybook.new(),
///     blocksummarybook.default_pace,
///     "g-1",
///   )
/// assert launches == []
/// ```
///
pub fn landed(
  book: Book,
  pace: Pace,
  generation: String,
) -> #(Book, List(Launch)) {
  case dict.get(book.streams, generation) {
    Error(Nil) -> #(book, [])
    Ok(Live(ending: Closed, ..)) -> #(
      Book(..book, streams: dict.delete(book.streams, generation)),
      [],
    )
    Ok(Live(ending: Open, ..) as live) ->
      consider(book, pace, generation, Live(..live, flight: Idle))
  }
}

// The one place a live launch is decided. Every event that can make a
// stream due ends here, so the three conditions are stated once.
fn consider(
  book: Book,
  pace: Pace,
  generation: String,
  live: Live,
) -> #(Book, List(Launch)) {
  let grown =
    live.bytes - live.asked_bytes >= pace.every_bytes
    || live.lines - live.asked_lines >= pace.every_lines
  let due = live.flight == Idle && live.bytes >= pace.floor_bytes && grown

  case due {
    False -> #(
      Book(..book, streams: dict.insert(book.streams, generation, live)),
      [],
    )

    True -> {
      let asked =
        Live(
          ..live,
          asked_bytes: live.bytes,
          asked_lines: live.lines,
          flight: Asking,
        )
      let launch =
        LiveAsk(
          generation:,
          strand: live.strand,
          operation: live.operation,
          text: live.chunks |> list.reverse |> string.concat,
        )
      let streams = dict.insert(book.streams, generation, asked)
      #(Book(..book, streams:), [launch])
    }
  }
}

// Keeps the newest `window_bytes` once the retained text has grown to twice
// that. Whole chunks are dropped from the old end, so a cut never lands
// inside a character; the halving means a trim runs once per window of
// growth rather than once per fragment.
fn trim(live: Live, pace: Pace) -> Live {
  case live.retained > pace.window_bytes * 2 {
    False -> live
    True -> {
      let #(kept, retained) =
        list.fold_until(live.chunks, #([], 0), fn(acc, chunk) {
          let #(kept, retained) = acc
          case retained >= pace.window_bytes {
            True -> list.Stop(acc)
            False ->
              list.Continue(#(
                [chunk, ..kept],
                retained + string.byte_size(chunk),
              ))
          }
        })
      Live(..live, chunks: list.reverse(kept), retained:)
    }
  }
}

fn newlines(chunk: String) -> Int {
  int.max(list.length(string.split(chunk, "\n")) - 1, 0)
}

// --- committed blocks ----------------------------------------------------------

/// Admits committed blocks and says which to ask about now.
///
/// Jobs are launched oldest first while the settled requests out are fewer
/// than the pace allows; the rest wait. A backlog past its bound drops its
/// oldest waiting jobs.
///
/// ## Examples
///
/// ```gleam
/// let #(_book, launches) =
///   blocksummarybook.admit(
///     blocksummarybook.new(),
///     blocksummarybook.default_pace,
///     [],
///   )
/// assert launches == []
/// ```
///
pub fn admit(book: Book, pace: Pace, jobs: List(Job)) -> #(Book, List(Launch)) {
  let waiting = list.append(book.waiting, jobs)
  let excess = list.length(waiting) - pace.settled_backlog
  let waiting = case excess > 0 {
    True -> list.drop(waiting, excess)
    False -> waiting
  }
  start_waiting(Book(..book, waiting:), pace, [])
}

/// Records that one settled request has ended and starts the next waiting
/// job, if any.
///
/// ## Examples
///
/// ```gleam
/// let #(_book, launches) =
///   blocksummarybook.settled_landed(
///     blocksummarybook.new(),
///     blocksummarybook.default_pace,
///   )
/// assert launches == []
/// ```
///
pub fn settled_landed(book: Book, pace: Pace) -> #(Book, List(Launch)) {
  let book = Book(..book, asking: int.max(book.asking - 1, 0))
  start_waiting(book, pace, [])
}

// Launches waiting jobs oldest first while a slot is free.
fn start_waiting(
  book: Book,
  pace: Pace,
  launched: List(Launch),
) -> #(Book, List(Launch)) {
  case book.waiting, book.asking < pace.settled_concurrency {
    [job, ..rest], True -> {
      let book = Book(..book, waiting: rest, asking: book.asking + 1)
      start_waiting(book, pace, [SettledAsk(job:), ..launched])
    }
    [], _ | _, False -> #(book, list.reverse(launched))
  }
}
