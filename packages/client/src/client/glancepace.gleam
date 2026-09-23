//// When the glance loop asks for a strand's summary: the whole schedule as
//// one pure function of (book, event, now).
////
//// The loop (`client/glance`) spends a provider request per refresh, on
//// every running sub-agent, for as long as it runs. Left to react to every
//// committed step it would ask once per tool round trip on every strand at
//// once, so the pacing is the part of the loop that decides what it costs,
//// and it is kept apart from the process so it can be tested by stepping
//// events through it rather than by racing a mailbox.
////
//// Four rules shape it, and each is a field of `Pace`.
////
//// - **First soon, then at most every `every_ms`.** A strand's first
////   step in an operation makes it due at once, so the operator sees a
////   title within one model round trip of the first tool call. After a
////   summary lands the next is not due until `every_ms` after that request
////   started.
//// - **Only when something happened.** A strand is `Fresh` when a step has
////   committed since its last request began and `Covered` otherwise; a
////   covered strand is never asked again however long it idles, because
////   the answer would be the one already written.
//// - **One request per strand, `concurrency` in all.** A strand that is
////   `Asking` is never launched again until its request settles, and the
////   launch pass fills at most `concurrency` slots across the session,
////   most overdue first.
//// - **Failures back off.** An unusable answer leaves the strand `Fresh`
////   and due again after `retry_ms`, doubling per consecutive failure up to
////   `retry_cap_ms`, so a broken summarizer route costs a trickle of
////   requests rather than one per step.
////
//// A strand that has not stepped for `retire_after_ms` and has nothing in
//// flight is forgotten, which is what bounds the book on a long session
//// that spawns many sub-agents. Forgetting is safe: the title lives in the
//// durable cell, not here, and a strand that steps again is simply booked
//// afresh.
////
//// The book holds no clock and arms no timer. Every `step` answers with
//// the launches to make now and the earliest instant anything becomes due,
//// and the loop arms one wake for that instant.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/string

/// The pacing knobs, all in milliseconds except `concurrency`.
///
/// Constructor invariants: every field is positive.
pub type Pace {
  Pace(
    /// The least time between the starts of two requests for one strand.
    every_ms: Int,
    /// The delay after a first failure; each further consecutive failure
    /// doubles it.
    retry_ms: Int,
    /// The longest a failing strand waits before its next attempt.
    retry_cap_ms: Int,
    /// The most requests in flight across the whole session.
    concurrency: Int,
    /// How long a strand may go without a step before it is forgotten.
    retire_after_ms: Int,
  )
}

/// The shipped pacing: a refresh at most every twenty seconds per strand,
/// three requests at once, failures backing off to five minutes, and a
/// strand forgotten after ten quiet minutes.
pub const default_pace = Pace(
  every_ms: 20_000,
  retry_ms: 20_000,
  retry_cap_ms: 300_000,
  concurrency: 3,
  retire_after_ms: 600_000,
)

/// Whether a strand has committed anything its last request did not see.
pub type Activity {
  /// A step committed since the last request began; a refresh is owed
  /// once the strand is due.
  Fresh

  /// Nothing committed since the last request began; no refresh is owed.
  Covered
}

/// Whether a strand has a request in flight.
pub type Phase {
  /// Nothing in flight.
  Resting

  /// A request started at `since` (Unix ms) and has not settled.
  Asking(since: Int)
}

/// One strand's schedule.
///
/// Constructor invariants: `operation` is the operation the strand's
/// latest step belonged to; `context` is the context size from that
/// operation's newest usage row, or zero before one arrived; `due` is the
/// earliest instant a request may start; `failures` counts consecutive
/// unusable answers for this operation; `seen` is when the strand last
/// stepped. An `Asking` track may be asking about the operation *before*
/// `operation`, when a successor started while its predecessor's request
/// was out.
pub type Track {
  Track(
    operation: String,
    context: Int,
    activity: Activity,
    phase: Phase,
    due: Int,
    failures: Int,
    seen: Int,
  )
}

/// Every strand the loop is pacing.
pub opaque type Book {
  Book(tracks: Dict(String, Track))
}

/// How a request ended, as far as the schedule cares.
pub type Ending {
  /// A glance was written. The next refresh waits out `every_ms`.
  Summarized

  /// The request failed or its answer could not be read. The old cell
  /// stands and the strand backs off.
  Unusable

  /// The operation was no longer the strand's live one when the request
  /// went to look, so nothing was asked. The strand is forgotten until it
  /// steps again.
  Ended
}

/// Something the loop saw.
pub type Event {
  /// A strand committed a step of `operation`. `context` is that step's
  /// context size, or `None` for a row that measures none (an
  /// adjustment).
  Stepped(strand: String, operation: String, context: Option(Int))

  /// The request about `operation` on `strand` finished.
  Settled(strand: String, operation: String, ending: Ending)

  /// The wake the last plan asked for has come.
  Tick
}

/// A request to start now.
pub type Launch {
  Launch(strand: String, operation: String, context: Int)
}

/// The answer to one event: the book to keep, the requests to start now,
/// and the instant (Unix ms) the next wake is owed, if any.
pub type Plan {
  Plan(book: Book, launch: List(Launch), wake: Option(Int))
}

/// An empty book.
///
/// ## Examples
///
/// ```gleam
/// assert glancepace.track(glancepace.new(), "sub:main/a-1") == Error(Nil)
/// ```
pub fn new() -> Book {
  Book(tracks: dict.new())
}

/// One strand's schedule, when the book holds one.
///
/// ## Examples
///
/// ```gleam
/// let plan =
///   glancepace.step(glancepace.new(), glancepace.Stepped("s", "op", None), 0, glancepace.default_pace)
/// let assert Ok(track) = glancepace.track(plan.book, "s")
/// assert track.phase == glancepace.Asking(since: 0)
/// ```
pub fn track(book: Book, strand: String) -> Result(Track, Nil) {
  dict.get(book.tracks, strand)
}

/// Applies one event at `now` and plans what follows from it.
///
/// Every event ends in the same launch pass, so an answer that frees a
/// slot starts the next due strand at once rather than at the next wake.
/// Runs in time linear in the strands booked.
///
/// ## Examples
///
/// ```gleam
/// let pace = glancepace.default_pace
/// let first = glancepace.step(glancepace.new(), glancepace.Stepped("s", "op", Some(900)), 0, pace)
/// assert first.launch == [glancepace.Launch("s", "op", 900)]
/// let again = glancepace.step(first.book, glancepace.Stepped("s", "op", Some(950)), 5, pace)
/// assert again.launch == []
/// ```
pub fn step(book: Book, event: Event, now: Int, pace: Pace) -> Plan {
  let tracks =
    book.tracks
    |> apply(event, now, pace)
    |> retire(now, pace)
  let #(tracks, launch) = launch_due(tracks, now, pace)
  Plan(book: Book(tracks:), launch:, wake: next_wake(tracks, now))
}

// --- events -------------------------------------------------------------------

fn apply(
  tracks: Dict(String, Track),
  event: Event,
  now: Int,
  pace: Pace,
) -> Dict(String, Track) {
  case event {
    Stepped(strand:, operation:, context:) ->
      dict.insert(
        tracks,
        strand,
        stepped(dict.get(tracks, strand), operation, context, now),
      )

    Settled(strand:, operation:, ending:) ->
      case dict.get(tracks, strand) {
        Ok(track) ->
          settled(tracks, strand, track, operation, ending, now, pace)

        // Nothing retires a strand with a request in flight, so a
        // settlement always finds its track; this arm is totality.
        Error(Nil) -> tracks
      }

    Tick -> tracks
  }
}

fn stepped(
  booked: Result(Track, Nil),
  operation: String,
  context: Option(Int),
  now: Int,
) -> Track {
  case booked {
    Ok(track) if track.operation == operation ->
      Track(
        ..track,
        activity: Fresh,
        context: option.unwrap(context, track.context),
        seen: now,
      )

    // A successor operation starts its schedule afresh — due at once, no
    // failures carried over — but keeps the phase: a request still out
    // about the predecessor holds the strand's one slot until it settles.
    Ok(track) ->
      Track(
        operation:,
        context: option.unwrap(context, 0),
        activity: Fresh,
        phase: track.phase,
        due: now,
        failures: 0,
        seen: now,
      )

    Error(Nil) ->
      Track(
        operation:,
        context: option.unwrap(context, 0),
        activity: Fresh,
        phase: Resting,
        due: now,
        failures: 0,
        seen: now,
      )
  }
}

// The request's own start, not its answer, is what `every_ms` counts
// from, so a slow summarizer does not stretch the cadence by its own
// latency on top of the interval.
fn settled(
  tracks: Dict(String, Track),
  strand: String,
  track: Track,
  operation: String,
  ending: Ending,
  now: Int,
  pace: Pace,
) -> Dict(String, Track) {
  let since = case track.phase {
    Asking(since:) -> since
    Resting -> now
  }
  let rested = Track(..track, phase: Resting)
  case track.operation == operation, ending {
    // An answer about the predecessor frees the slot and changes nothing
    // else: the successor's own schedule was set when it first stepped.
    False, _ending -> dict.insert(tracks, strand, rested)
    True, Summarized ->
      dict.insert(
        tracks,
        strand,
        Track(..rested, due: since + pace.every_ms, failures: 0),
      )

    // The entries the request was meant to cover are still unsummarized,
    // so the strand goes back to `Fresh` and waits out its back-off.
    True, Unusable -> {
      let failures = track.failures + 1
      dict.insert(
        tracks,
        strand,
        Track(
          ..rested,
          activity: Fresh,
          failures:,
          due: now + backoff(pace, failures),
        ),
      )
    }

    True, Ended -> dict.delete(tracks, strand)
  }
}

fn backoff(pace: Pace, failures: Int) -> Int {
  double(pace.retry_ms, failures - 1, pace.retry_cap_ms)
}

// Doubling stops at the cap rather than after it, so a strand that has
// failed a thousand times computes no thousand-bit delay.
fn double(delay: Int, times: Int, cap: Int) -> Int {
  case times <= 0 || delay >= cap {
    True -> int.min(delay, cap)
    False -> double(delay * 2, times - 1, cap)
  }
}

// --- the launch pass ------------------------------------------------------------

fn retire(
  tracks: Dict(String, Track),
  now: Int,
  pace: Pace,
) -> Dict(String, Track) {
  dict.filter(tracks, fn(_strand, track) {
    case track.phase {
      Asking(..) -> True
      Resting -> now - track.seen < pace.retire_after_ms
    }
  })
}

// Most overdue first, and by strand name within one instant, so which
// strands win the free slots is a function of the book rather than of a
// dict's iteration order.
fn launch_due(
  tracks: Dict(String, Track),
  now: Int,
  pace: Pace,
) -> #(Dict(String, Track), List(Launch)) {
  let asking =
    dict.fold(tracks, 0, fn(count, _strand, track) {
      case track.phase {
        Asking(..) -> count + 1
        Resting -> count
      }
    })
  let chosen =
    tracks
    |> dict.to_list
    |> list.filter(fn(pair) { is_due(pair.1, now) })
    |> list.sort(fn(a, b) {
      case int.compare({ a.1 }.due, { b.1 }.due) {
        order.Eq -> string.compare(a.0, b.0)
        ordered -> ordered
      }
    })
    |> list.take(int.max(pace.concurrency - asking, 0))

  list.fold(chosen, #(tracks, []), fn(accumulator, pair) {
    let #(strand, track) = pair
    let #(tracks, launch) = accumulator
    let started = Track(..track, phase: Asking(since: now), activity: Covered)
    #(dict.insert(tracks, strand, started), [
      Launch(strand:, operation: track.operation, context: track.context),
      ..launch
    ])
  })
  |> fn(accumulator) { #(accumulator.0, list.reverse(accumulator.1)) }
}

fn is_due(track: Track, now: Int) -> Bool {
  case track.phase, track.activity {
    Resting, Fresh -> track.due <= now
    Resting, Covered | Asking(..), Fresh | Asking(..), Covered -> False
  }
}

// The soonest instant a resting, fresh strand becomes due. A strand that
// is already due but found no slot needs no wake: a slot frees only when a
// request settles, and a settlement is an event of its own.
fn next_wake(tracks: Dict(String, Track), now: Int) -> Option(Int) {
  dict.fold(tracks, None, fn(soonest, _strand, track) {
    case track.phase, track.activity {
      Resting, Fresh if track.due > now ->
        case soonest {
          None -> Some(track.due)
          Some(earlier) -> Some(int.min(earlier, track.due))
        }
      Resting, Fresh
      | Resting, Covered
      | Asking(..), Fresh
      | Asking(..), Covered
      -> soonest
    }
  })
}
