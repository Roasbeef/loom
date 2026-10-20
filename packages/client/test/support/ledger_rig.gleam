//// Services of the membership ledger run in one VM, for tests of the
//// protocol that need no distribution.
////
//// A rig is a `ledger_service` over a real file in a scratch directory, with
//// peers the test supplies. A rig's peers are a list held by a small actor
//// (a `Book`), so a test can introduce a peer after the service has started
//// and watch the periodic tick find it. `link` makes one rig a peer of
//// another by delivering straight to its wire subject, which is what a send
//// to `{loom_ledger, node}` does across nodes.

import client/ledger_service.{type Observer, type Reach, type Service, Reach}
import client/membership_entry
import client/membership_ledger
import client/membership_store
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/otp/actor
import gleam/string
import host/bootstrap
import simplifile
import support/membership_fixture as fixture
import support/remote_fixtures
import telemetry/log
import weft/poll

/// A clock a test sets, for the service's schedules.
pub opaque type Clock {
  Clock(subject: Subject(ClockMessage))
}

type ClockMessage {
  SetTime(Int)
  ReadTime(Subject(Int))
}

/// A clock that reads zero until it is set.
pub fn new_clock() -> Clock {
  let assert Ok(started) =
    actor.new(0)
    |> actor.on_message(fn(now, message) {
      case message {
        SetTime(next) -> actor.continue(next)
        ReadTime(reply) -> {
          process.send(reply, now)
          actor.continue(now)
        }
      }
    })
    |> actor.start
    as "the clock starts"
  Clock(subject: started.data)
}

/// Sets the time the clock reads.
pub fn set_time(clock: Clock, ms: Int) -> Nil {
  process.send(clock.subject, SetTime(ms))
}

/// The clock as the function a service takes.
pub fn reading(clock: Clock) -> fn() -> Int {
  fn() { process.call(clock.subject, 1000, ReadTime) }
}

/// The peers of a rig, changeable while the rig runs.
pub opaque type Book {
  Book(subject: Subject(BookMessage))
}

type BookMessage {
  Put(List(Reach))
  Get(Subject(List(Reach)))
}

/// A started service and what a test needs to look at it.
pub type Rig {
  Rig(
    /// The running service.
    service: Service,
    /// Its peers.
    book: Book,
    /// Its ledger file.
    path: String,
  )
}

/// How a rig is timed.
pub type Timing {
  Timing(
    /// Milliseconds between ticks.
    tick_ms: Int,
    /// Milliseconds a pull waits.
    pull_within_ms: Int,
  )
}

/// A tick that never fires within a test and the production pull deadline.
pub const patient = Timing(tick_ms: 3_600_000, pull_within_ms: 5000)

/// A fast tick, for tests that need the periodic exchange to do the work.
pub const brisk = Timing(tick_ms: 50, pull_within_ms: 5000)

fn new_book() -> Book {
  let assert Ok(started) =
    actor.new([])
    |> actor.on_message(fn(peers, message) {
      case message {
        Put(next) -> actor.continue(next)
        Get(reply) -> {
          process.send(reply, peers)
          actor.continue(peers)
        }
      }
    })
    |> actor.start
    as "the book starts"
  Book(subject: started.data)
}

/// Replaces a rig's peers.
pub fn set_peers(rig: Rig, peers: List(Reach)) -> Nil {
  process.send(rig.book.subject, Put(peers))
}

/// A peer that delivers to another rig.
pub fn reach_to(label: String, other: Rig) -> Reach {
  Reach(node: label, deliver: fn(message) {
    process.send(ledger_service.wire(other.service), message)
  })
}

/// A file holding `lines`, opened and served, with no peers.
pub fn start(
  label: String,
  lines: List(BitArray),
  timing: Timing,
  observers: List(Observer),
) -> Rig {
  let directory = remote_fixtures.scratch(label)
  start_in(directory, lines, timing, observers)
}

/// The same, in a directory the caller made.
pub fn start_in(
  directory: String,
  lines: List(BitArray),
  timing: Timing,
  observers: List(Observer),
) -> Rig {
  start_clocked(
    directory,
    lines,
    timing,
    observers,
    bootstrap.monotonic_time_ms,
  )
}

/// The same, with the clock the service ages reports and schedules dials by.
pub fn start_clocked(
  directory: String,
  lines: List(BitArray),
  timing: Timing,
  observers: List(Observer),
  now_ms: fn() -> Int,
) -> Rig {
  let path = directory <> "/ledger.log"
  let assert Ok(Nil) = simplifile.write(path, text_of(lines))
    as "the ledger file is written"
  let assert Ok(opened) = membership_store.open(path, fixture.verifier())
    as "the fixture ledger opens"
  let book = new_book()
  let config =
    ledger_service.Config(
      ..ledger_service.configuration(
        opened.store,
        opened.ledger,
        fixture.verifier(),
        observers,
        log.discard(),
      ),
      peers: ledger_service.Supplied(reach: fn() {
        process.call(book.subject, 1000, Get)
      }),
      name: process.new_name("ledger"),
      tick_ms: timing.tick_ms,
      pull_within_ms: timing.pull_within_ms,
      now_ms:,
    )
  let assert Ok(service) = ledger_service.start(config) as "the service starts"
  Rig(service:, book:, path:)
}

/// The lines as file text: each followed by a newline.
pub fn text_of(lines: List(BitArray)) -> String {
  string.concat(
    list.map(lines, fn(line) {
      let assert Ok(text) = bit_array.to_string(line)
        as "the fixture lines are text"
      text <> "\n"
    }),
  )
}

/// The sequence number of a rig's head.
pub fn head_seq(rig: Rig) -> Int {
  let assert Ok(head) = ledger_service.head(rig.service, 30_000)
    as "the service answers"
  head.seq
}

/// The ledger file as it is on disk.
pub fn file(rig: Rig) -> String {
  let assert Ok(text) = simplifile.read(rig.path)
    as "the ledger file is readable"
  text
}

/// Waits, within a bound, for a rig's head to reach `seq`. `Error` carries the
/// head sequence number the rig had when the bound ran out.
pub fn await_head(rig: Rig, seq: Int) -> Result(Int, Int) {
  let outcome =
    poll.until(within: 40_000, every: 20, attempt: fn() {
      let reached = head_seq(rig)
      case reached >= seq {
        True -> poll.Done(reached)
        False -> poll.Retry
      }
    })
  case outcome {
    poll.Answered(reached) -> Ok(reached)
    poll.Failed(Nil) -> Error(head_seq(rig))
    poll.Expired -> Error(head_seq(rig))
  }
}

/// The identity of a line's entry.
pub fn id_of(line: BitArray) -> BitArray {
  let assert Ok(signed) = membership_entry.read(line, fixture.verifier())
    as "the fixture line reads"
  membership_entry.id_to_bytes(signed.id)
}

/// The ledger's head sequence number as `int.to_string`, for messages.
pub fn describe(ledger: membership_ledger.Ledger) -> String {
  int.to_string(membership_ledger.head(ledger).seq)
}
