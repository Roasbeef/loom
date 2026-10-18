//// The block summarizer's book under generated event sequences, driven by
//// `statem`.
////
//// `blocksummarybook_test` pins each rule with a hand-built sequence. This
//// module states the same rules as a reference and runs generated sequences of
//// events against the real book, which is where an interaction between two
//// rules would show: an eviction that lands while a request is out, a backlog
//// that overflows while a settled request ends, a stream ended while its
//// request is in flight and then written to again.
////
//// An event is one fragment of a live stream, the end of a stream, the end of a
//// live request, a burst of committed blocks, or the end of a settled request.
//// Streams are named from a small pool, so a sequence can revisit one after it
//// was evicted. A request that ends is chosen by position among the requests
//// the oracle holds out, resolved when the event runs, so deleting an event
//// while shrinking leaves every later one meaningful, and the model is empty:
//// every event is admissible in every state. The oracle lives in the system
//// under test, beside the book, because it must see the launches the book
//// returns; it restates the rules from `client/CLAUDE.md` ("the summarizer's
//// pacing as pure functions") and the module doc of `blocksummarybook`, never
//// from the book's code:
////
//// - settled jobs launch oldest first, at most `settled_concurrency` are out,
////   and at most `settled_backlog` wait, the oldest dropped first;
//// - a live stream is asked when it has no request out, has carried
////   `floor_bytes`, has grown `every_bytes` or `every_lines` since its last
////   request began, and fewer than `live_concurrency` live requests are out;
//// - growth during a request coalesces: nothing launches until it ends, and
////   then at most one request starts, for the newest text;
//// - a request's text is a suffix of everything the stream carried, holds its
////   newest `window_bytes`, and is trimmed once the stream reaches twice that;
//// - at most `max_streams` streams are tracked, and a new one evicts the oldest
////   with no request out;
//// - a stream that ends with no request out is forgotten at once, and one that
////   ends with a request out when that request lands, launching nothing.
////
//// The rules are checked after every event, each under its own tag, and the
//// campaign runs twice: under the shipped pace, where thresholds take kilobytes
//// to reach, and under a tight one where every bound is hit in a few events.
//// `the_events_reach_every_pacing_case_test` replays the drawn sequences and
//// fails if any case the rules talk about is never reached.

import client/blocksummarybook.{
  type Book, type Launch, type Pace, Job, LiveAsk, Pace, Reasoning, SettledAsk,
}
import core/clock
import core/ids.{type EntryId, type OpId}
import gleam/dict.{type Dict}
import gleam/int
import gleam/io
import gleam/list
import gleam/result
import gleam/set
import gleam/string
import qcheck
import statem

// --- the campaigns ----------------------------------------------------------

// A pace small enough that every bound is reached within a few events: eight
// bytes of floor, a request per 32 bytes or four lines, a 64-byte window, two
// requests of each kind out, three settled blocks waiting and four streams.
const tight =
  Pace(
    floor_bytes: 8,
    every_bytes: 32,
    every_lines: 4,
    window_bytes: 64,
    settled_concurrency: 2,
    settled_backlog: 3,
    live_concurrency: 2,
    max_streams: 4,
  )

// The seed, run count and sequence length of each campaign. Sequences are long
// enough to fill the shipped window, which takes about thirty large fragments
// in one stream.
const campaign_seed = 1561

const runs = 150

const longest = 60

fn config() -> statem.Config {
  statem.default_config(seed: campaign_seed)
  |> statem.with_test_count(runs)
  |> statem.with_max_commands(longest)
}

// --- events -----------------------------------------------------------------

// How many bytes of text a fragment carries, in the units of the pace under
// test so one campaign's events mean the same thing under either pace.
type Size {
  // One byte.
  Tiny

  // Half the floor, so two of them reach it.
  Small

  // Half of `every_bytes`.
  Medium

  // `every_bytes`.
  Large

  // The whole window, so the stream is trimmed within three of them.
  Whole
}

// How many line breaks a fragment carries.
type Breaks {
  // None, so the stream grows in bytes alone.
  NoBreaks

  // One.
  OneBreak

  // `every_lines`, so a single fragment can earn a request by lines alone.
  ManyBreaks
}

type Event {
  // A fragment of the live stream that the `stream`-th pool name stands for.
  Grow(stream: Int, size: Size, breaks: Breaks)

  // The provider stopped writing the `stream`-th stream.
  End(stream: Int)

  // The `pick`-th live request out, in name order, ends. Nothing happens when
  // none is out.
  LandLive(pick: Int)

  // A burst of `count` committed blocks.
  Admit(count: Int)

  // One settled request ends. Nothing happens when none is out.
  LandSettled
}

fn event() -> qcheck.Generator(Event) {
  qcheck.from_weighted_generators(
    #(
      55,
      qcheck.map3(
        qcheck.bounded_int(0, 15),
        size(),
        breaks(),
        fn(stream, size, breaks) { Grow(stream:, size:, breaks:) },
      ),
    ),
    [
      #(8, qcheck.map(qcheck.bounded_int(0, 15), End)),
      #(25, qcheck.map(qcheck.bounded_int(0, 15), LandLive)),
      #(12, qcheck.map(qcheck.bounded_int(1, 6), Admit)),
      #(12, qcheck.constant(LandSettled)),
    ],
  )
}

// The simplest size is the smallest, so a shrink moves toward one byte.
fn size() -> qcheck.Generator(Size) {
  qcheck.bounded_int(0, 4)
  |> qcheck.map(fn(pick) {
    case pick {
      0 -> Tiny
      1 -> Small
      2 -> Medium
      3 -> Large
      _ -> Whole
    }
  })
}

fn breaks() -> qcheck.Generator(Breaks) {
  qcheck.bounded_int(0, 2)
  |> qcheck.map(fn(pick) {
    case pick {
      0 -> NoBreaks
      1 -> OneBreak
      _ -> ManyBreaks
    }
  })
}

fn describe(event: Event) -> String {
  string.inspect(event)
}

// --- what the oracle remembers ----------------------------------------------

// Whether a stream has a request out, and whether its provider has stopped
// writing while it does.
type Phase {
  Resting
  Asking
  AskingEnded
}

// One stream as the rules describe it: everything it carried, in order, how
// many bytes and line breaks that is, and how much of both it had carried when
// its last request began.
type Mirror {
  Mirror(
    order: Int,
    carried: String,
    bytes: Int,
    lines: Int,
    asked_bytes: Int,
    asked_lines: Int,
    phase: Phase,
  )
}

// The oracle: the streams that should be tracked, how many streams have ever
// been first seen (the eviction order), the settled requests that should be
// out, the blocks that should be waiting, and the next block number to mint.
type Oracle {
  Oracle(
    streams: Dict(String, Mirror),
    seen: Int,
    settled_out: Int,
    waiting: List(Int),
    minted: Int,
  )
}

type Sut {
  Sut(book: Book, oracle: Oracle)
}

fn new_sut() -> Sut {
  Sut(
    book: blocksummarybook.new(),
    oracle: Oracle(
      streams: dict.new(),
      seen: 0,
      settled_out: 0,
      waiting: [],
      minted: 0,
    ),
  )
}

fn violation(tag: String, detail: String) -> statem.Violation {
  statem.Violation(tag:, detail:)
}

// Compares what the book did with what the rules say, and names the rule.
fn agree(tag: String, got: a, wanted: a) -> Result(Nil, statem.Violation) {
  case got == wanted {
    True -> Ok(Nil)
    False ->
      Error(violation(
        tag,
        "expected "
          <> string.inspect(wanted)
          <> " but got "
          <> string.inspect(got),
      ))
  }
}

// --- the pool and the units -------------------------------------------------

// The names streams are drawn from: half as many again as the book may track,
// so a sequence evicts and then meets an evicted name again.
fn pool(pace: Pace) -> List(String) {
  list.map(numbers(0, pace.max_streams * 3 / 2), fn(index) {
    "g-" <> int.to_string(index)
  })
}

fn numbers(start: Int, stop: Int) -> List(Int) {
  int.range(from: start, to: stop, with: [], run: fn(all, number) {
    [number, ..all]
  })
  |> list.reverse
}

fn generation(pace: Pace, stream: Int) -> String {
  let names = pool(pace)
  case list.drop(names, stream % list.length(names)) {
    [name, ..] -> name
    [] -> "g-0"
  }
}

fn bytes_of(pace: Pace, size: Size) -> Int {
  case size {
    Tiny -> 1
    Small -> int.max(pace.floor_bytes / 2, 1)
    Medium -> int.max(pace.every_bytes / 2, 1)
    Large -> pace.every_bytes
    Whole -> pace.window_bytes
  }
}

fn lines_of(pace: Pace, breaks: Breaks) -> Int {
  case breaks {
    NoBreaks -> 0
    OneBreak -> 1
    ManyBreaks -> pace.every_lines
  }
}

// --- the rules --------------------------------------------------------------

fn requests_out(streams: Dict(String, Mirror)) -> Int {
  dict.fold(streams, 0, fn(count, _generation, mirror) {
    case mirror.phase {
      Resting -> count
      Asking | AskingEnded -> count + 1
    }
  })
}

// Whether `generation` is due: no request out for it, the floor carried,
// enough growth since its last request began, and a live slot free.
fn due(pace: Pace, streams: Dict(String, Mirror), generation: String) -> Bool {
  case dict.get(streams, generation) {
    Error(Nil) -> False
    Ok(mirror) -> {
      let grown =
        mirror.bytes - mirror.asked_bytes >= pace.every_bytes
        || mirror.lines - mirror.asked_lines >= pace.every_lines
      mirror.phase == Resting
      && mirror.bytes >= pace.floor_bytes
      && grown
      && requests_out(streams) < pace.live_concurrency
    }
  }
}

// The stream's request began: it has now seen everything it carried.
fn asked(
  streams: Dict(String, Mirror),
  generation: String,
) -> Dict(String, Mirror) {
  case dict.get(streams, generation) {
    Error(Nil) -> streams
    Ok(mirror) ->
      dict.insert(
        streams,
        generation,
        Mirror(
          ..mirror,
          asked_bytes: mirror.bytes,
          asked_lines: mirror.lines,
          phase: Asking,
        ),
      )
  }
}

// The stream that makes room for a new one: the oldest with no request out,
// and the oldest of all only as the fallback the book documents.
fn victim(streams: Dict(String, Mirror)) -> Result(String, Nil) {
  let ranked =
    dict.to_list(streams)
    |> list.sort(fn(a, b) { int.compare({ a.1 }.order, { b.1 }.order) })
  let idle = list.find(ranked, fn(pair) { { pair.1 }.phase == Resting })
  result.lazy_or(idle, fn() { list.first(ranked) })
  |> result.map(fn(pair) { pair.0 })
}

// The generations the book says it tracks, among every name the pool holds.
fn tracked(pace: Pace, book: Book) -> List(String) {
  list.filter(pool(pace), blocksummarybook.tracks(book, _))
  |> list.sort(string.compare)
}

fn checked_streams(
  pace: Pace,
  streams: Dict(String, Mirror),
  book: Book,
) -> Result(Nil, statem.Violation) {
  use Nil <- result.try(agree(
    "tracked",
    tracked(pace, book),
    list.sort(dict.keys(streams), string.compare),
  ))
  use Nil <- result.try(agree(
    "max-streams",
    blocksummarybook.streams(book) <= pace.max_streams,
    True,
  ))
  agree(
    "live-concurrency",
    requests_out(streams) <= pace.live_concurrency,
    True,
  )
}

// The text a request carries is a suffix of everything the stream carried,
// holds at least its newest window, and is never more than twice the window.
fn checked_text(
  pace: Pace,
  mirror: Mirror,
  launches: List(Launch),
) -> Result(List(String), statem.Violation) {
  case launches {
    [LiveAsk(text:, ..)] -> {
      let size = string.byte_size(text)
      use Nil <- result.try(agree(
        "window-suffix",
        string.ends_with(mirror.carried, text),
        True,
      ))
      use Nil <- result.try(agree(
        "window-newest",
        size >= int.min(mirror.bytes, pace.window_bytes),
        True,
      ))
      use Nil <- result.try(agree(
        "window-bound",
        size <= 2 * pace.window_bytes,
        True,
      ))
      case size < mirror.bytes {
        True -> Ok(["live-launch", "window-trim"])
        False -> Ok(["live-launch"])
      }
    }
    [] -> Ok([])
    [_, ..] -> Error(violation("live-due", "more than one live request"))
  }
}

fn generations_of(launches: List(Launch)) -> List(String) {
  list.map(launches, fn(launch) {
    case launch {
      LiveAsk(generation:, ..) -> generation
      SettledAsk(..) -> "settled"
    }
  })
}

fn blocks_of(launches: List(Launch)) -> List(Int) {
  list.filter_map(launches, fn(launch) {
    case launch {
      SettledAsk(job:) -> Ok(job.block)
      LiveAsk(..) -> Error(Nil)
    }
  })
}

// --- stepping ---------------------------------------------------------------

// One event, with the labels of the cases it reached. `execute` drops the
// labels, and the coverage test collects them.
fn step(
  pace: Pace,
  sut: Sut,
  event: Event,
) -> Result(#(Sut, List(String)), statem.Violation) {
  case event {
    Grow(stream:, size:, breaks:) -> grow(pace, sut, stream, size, breaks)
    End(stream:) -> end(pace, sut, stream)
    LandLive(pick:) -> land_live(pace, sut, pick)
    Admit(count:) -> admit(pace, sut, count)
    LandSettled -> land_settled(pace, sut)
  }
}

fn grow(
  pace: Pace,
  sut: Sut,
  stream: Int,
  size: Size,
  breaks: Breaks,
) -> Result(#(Sut, List(String)), statem.Violation) {
  let name = generation(pace, stream)
  let chunk =
    string.repeat("\n", lines_of(pace, breaks))
    <> string.repeat("a", bytes_of(pace, size))
  let oracle = sut.oracle

  // A stream the book has not seen makes room first, then starts empty.
  let #(streams, seen, evicted) = case dict.get(oracle.streams, name) {
    Ok(_) -> #(oracle.streams, oracle.seen, [])
    Error(Nil) -> admitted(pace, oracle)
  }
  let mirror = case dict.get(streams, name) {
    Ok(held) -> held
    Error(Nil) ->
      Mirror(
        order: oracle.seen,
        carried: "",
        bytes: 0,
        lines: 0,
        asked_bytes: 0,
        asked_lines: 0,
        phase: Resting,
      )
  }
  let carried = mirror.carried <> chunk
  let grown =
    Mirror(
      ..mirror,
      carried:,
      bytes: string.byte_size(carried),
      lines: mirror.lines + lines_of(pace, breaks),
    )
  let streams = dict.insert(streams, name, grown)

  // Whether this fragment makes the stream due is decided from the rules
  // before the book is asked, so the book cannot answer its own question.
  let owed = due(pace, streams, name)
  let #(book, launches) =
    blocksummarybook.grow(
      sut.book,
      pace,
      generation: name,
      strand: "main",
      operation: an_op(),
      chunk:,
    )
  use Nil <- result.try(
    agree("live-due", generations_of(launches), case owed {
      True -> [name]
      False -> []
    }),
  )
  let streams = case owed {
    True -> asked(streams, name)
    False -> streams
  }
  use Nil <- result.try(checked_streams(pace, streams, book))
  use reached <- result.try(checked_text(pace, grown, launches))
  let refused = case owed, wants_a_request(pace, grown) {
    False, True -> ["live-refused"]
    True, _ | False, False -> []
  }
  Ok(#(
    Sut(book:, oracle: Oracle(..oracle, streams:, seen:)),
    list.flatten([
      reached,
      refused,
      case evicted {
        [] -> []
        [_, ..] -> ["eviction"]
      },
      case mirror.phase {
        Asking | AskingEnded -> ["growth-while-out"]
        Resting -> []
      },
    ]),
  ))
}

// Whether a stream has earned a request by size alone, without a slot.
fn wants_a_request(pace: Pace, mirror: Mirror) -> Bool {
  mirror.phase == Resting
  && mirror.bytes >= pace.floor_bytes
  && {
    mirror.bytes - mirror.asked_bytes >= pace.every_bytes
    || mirror.lines - mirror.asked_lines >= pace.every_lines
  }
}

// The oracle's streams with room for one more, the order the new one takes, and
// the names that were evicted to make room.
fn admitted(
  pace: Pace,
  oracle: Oracle,
) -> #(Dict(String, Mirror), Int, List(String)) {
  case dict.size(oracle.streams) < pace.max_streams {
    True -> #(oracle.streams, oracle.seen + 1, [])
    False ->
      case victim(oracle.streams) {
        Ok(forgotten) -> #(
          dict.delete(oracle.streams, forgotten),
          oracle.seen + 1,
          [forgotten],
        )
        Error(Nil) -> #(oracle.streams, oracle.seen + 1, [])
      }
  }
}

fn end(
  pace: Pace,
  sut: Sut,
  stream: Int,
) -> Result(#(Sut, List(String)), statem.Violation) {
  let name = generation(pace, stream)
  let #(streams, reached) = case dict.get(sut.oracle.streams, name) {
    Error(Nil) -> #(sut.oracle.streams, ["end-untracked"])
    Ok(Mirror(phase: Resting, ..)) -> #(dict.delete(sut.oracle.streams, name), [
      "end-idle",
    ])
    Ok(mirror) -> #(
      dict.insert(
        sut.oracle.streams,
        name,
        Mirror(..mirror, phase: AskingEnded),
      ),
      ["end-asking"],
    )
  }
  let book = blocksummarybook.ended(sut.book, name)
  use Nil <- result.try(checked_streams(pace, streams, book))
  Ok(#(Sut(book:, oracle: Oracle(..sut.oracle, streams:)), reached))
}

fn land_live(
  pace: Pace,
  sut: Sut,
  pick: Int,
) -> Result(#(Sut, List(String)), statem.Violation) {
  let outstanding =
    dict.to_list(sut.oracle.streams)
    |> list.filter(fn(pair) { { pair.1 }.phase != Resting })
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  case list.length(outstanding) {
    0 -> Ok(#(sut, []))
    size ->
      case list.drop(outstanding, pick % size) {
        [#(name, mirror), ..] -> landing(pace, sut, name, mirror)
        [] -> Ok(#(sut, []))
      }
  }
}

fn landing(
  pace: Pace,
  sut: Sut,
  name: String,
  mirror: Mirror,
) -> Result(#(Sut, List(String)), statem.Violation) {
  let #(book, launches) = blocksummarybook.landed(sut.book, pace, name)
  case mirror.phase {
    // The provider already stopped writing: the stream is forgotten and
    // nothing launches, however much it grew meanwhile.
    AskingEnded -> {
      let streams = dict.delete(sut.oracle.streams, name)
      use Nil <- result.try(agree("closed-landing", launches, []))
      use Nil <- result.try(checked_streams(pace, streams, book))
      Ok(
        #(Sut(book:, oracle: Oracle(..sut.oracle, streams:)), ["landed-closed"]),
      )
    }

    // Still open: the growth that arrived meanwhile earns at most one request,
    // for the newest text. The request that just ended no longer holds a slot,
    // so the slot count is taken with this stream resting. `landed` counts the
    // ending request as still out while every other slot is in use, and so
    // never relaunches then: that is a defect this tag reports.
    Asking | Resting -> {
      let freed =
        dict.insert(sut.oracle.streams, name, Mirror(..mirror, phase: Resting))
      let owed = due(pace, freed, name)
      use Nil <- result.try(
        agree("coalesce", generations_of(launches), case owed {
          True -> [name]
          False -> []
        }),
      )
      let streams = case owed {
        True -> asked(freed, name)
        False -> freed
      }
      use Nil <- result.try(checked_streams(pace, streams, book))
      use reached <- result.try(checked_text(pace, mirror, launches))
      let relaunch = case owed {
        True -> ["coalesced-relaunch"]
        False -> ["landed-quiet"]
      }
      Ok(#(
        Sut(book:, oracle: Oracle(..sut.oracle, streams:)),
        list.append(reached, relaunch),
      ))
    }
  }
}

fn admit(
  pace: Pace,
  sut: Sut,
  count: Int,
) -> Result(#(Sut, List(String)), statem.Violation) {
  let oracle = sut.oracle
  let minted =
    list.map(numbers(0, count), fn(offset) { oracle.minted + offset })
  let all = list.append(oracle.waiting, minted)
  let dropped = int.max(list.length(all) - pace.settled_backlog, 0)
  let kept = list.drop(all, dropped)
  let free = int.max(pace.settled_concurrency - oracle.settled_out, 0)
  let launching = list.take(kept, free)
  let queue = list.drop(kept, free)

  let #(book, launches) =
    blocksummarybook.admit(
      sut.book,
      pace,
      list.map(minted, fn(block) { a_job(block) }),
    )
  use Nil <- result.try(agree("settled-launch", blocks_of(launches), launching))
  use Nil <- result.try(agree(
    "settled-queue",
    list.map(blocksummarybook.queued(book), fn(job) { job.block }),
    queue,
  ))
  use Nil <- result.try(agree(
    "backlog",
    blocksummarybook.waiting(book) <= pace.settled_backlog,
    True,
  ))
  let out = oracle.settled_out + list.length(launching)
  use Nil <- result.try(agree(
    "settled-concurrency",
    out <= pace.settled_concurrency,
    True,
  ))
  Ok(#(
    Sut(
      book:,
      oracle: Oracle(
        ..oracle,
        settled_out: out,
        waiting: queue,
        minted: oracle.minted + count,
      ),
    ),
    list.flatten([
      case launching {
        [] -> []
        [_, ..] -> ["settled-launch"]
      },
      case queue {
        [] -> []
        [_, ..] -> ["settled-queued"]
      },
      case dropped {
        0 -> []
        _ -> ["backlog-drop"]
      },
    ]),
  ))
}

fn land_settled(
  pace: Pace,
  sut: Sut,
) -> Result(#(Sut, List(String)), statem.Violation) {
  let oracle = sut.oracle
  case oracle.settled_out {
    0 -> Ok(#(sut, []))
    out -> {
      let #(book, launches) = blocksummarybook.settled_landed(sut.book, pace)
      let freed = out - 1
      let launching = case oracle.waiting, freed < pace.settled_concurrency {
        [next, ..], True -> [next]
        [], _ | _, False -> []
      }
      let queue = list.drop(oracle.waiting, list.length(launching))
      use Nil <- result.try(agree(
        "settled-launch",
        blocks_of(launches),
        launching,
      ))
      use Nil <- result.try(agree(
        "settled-queue",
        list.map(blocksummarybook.queued(book), fn(job) { job.block }),
        queue,
      ))
      Ok(
        #(
          Sut(
            book:,
            oracle: Oracle(
              ..oracle,
              settled_out: freed + list.length(launching),
              waiting: queue,
            ),
          ),
          case launching {
            [] -> ["settled-landed"]
            [_, ..] -> ["settled-chain"]
          },
        ),
      )
    }
  }
}

// --- the property -----------------------------------------------------------

fn spec(pace: Pace) -> statem.Spec(Nil, Event, Sut) {
  statem.Spec(
    initial: Nil,
    command: fn(_) { event() },
    precondition: fn(_, _) { statem.Admit },
    next_model: fn(_, _) { Nil },
    new_sut:,
    execute: fn(sut, _, event) {
      step(pace, sut, event) |> result.map(fn(stepped) { stepped.0 })
    },
    finish: fn(_, _) { Ok(Nil) },
    teardown: fn(_) { Nil },
  )
}

fn checked(pace: Pace) -> Nil {
  case statem.check(spec(pace), config()) {
    Ok(Nil) -> Nil

    // EUnit clips a long panic message, so the whole report also goes to
    // standard error, which EUnit does not capture.
    Error(failure) -> {
      let report = statem.report(failure, describe)
      io.println_error(report)
      panic as report
    }
  }
}

pub fn the_book_keeps_its_bounds_under_the_shipped_pace_test() {
  checked(blocksummarybook.default_pace)
}

pub fn the_book_keeps_its_bounds_under_a_tight_pace_test() {
  checked(tight)
}

// --- the generator is worth testing with ------------------------------------

// Every case the rules above talk about, under the pace that reaches it.
const wanted = [
  "live-launch", "live-refused", "coalesced-relaunch", "landed-quiet",
  "landed-closed", "growth-while-out", "end-idle", "end-asking", "end-untracked",
  "eviction", "settled-launch", "settled-queued", "backlog-drop",
  "settled-landed", "settled-chain",
]

fn reached(pace: Pace) -> set.Set(String) {
  list.fold(numbers(0, runs), set.new(), fn(found, run) {
    let events = statem.commands(spec(pace), config(), run)
    let #(_, labels) =
      list.fold(events, #(new_sut(), []), fn(state, event) {
        case step(pace, state.0, event) {
          Ok(#(next, labels)) -> #(next, list.append(labels, state.1))
          Error(_) -> state
        }
      })
    set.union(found, set.from_list(labels))
  })
}

pub fn the_events_reach_every_pacing_case_test() {
  let tight_cases = reached(tight)
  let shipped_cases = reached(blocksummarybook.default_pace)
  let missing =
    list.filter(wanted, fn(label) { !set.contains(tight_cases, label) })
  assert missing == [] as "the tight pace never reached every case"

  // The shipped pace keeps its window at 32 KiB, so trimming is reached by a
  // stream written to by many whole-window fragments; it must be there too.
  assert set.contains(shipped_cases, "window-trim")
  assert set.contains(tight_cases, "window-trim")
  assert set.contains(shipped_cases, "live-launch")
  assert set.contains(shipped_cases, "eviction")
}

// --- fixtures ---------------------------------------------------------------

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
