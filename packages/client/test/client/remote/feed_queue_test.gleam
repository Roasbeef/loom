//// The live feed's queue under generated sequences, driven by `statem`
//// (protocol-change/108, "Fixed-seed properties").
////
//// `feed_queue` is a pure value, so the sequences here need no process. A
//// command is a push of a frame of one of a few sizes, a poll with a correct, a
//// stale or an overshooting `after` whose answer the link delivers, loses or
//// duplicates, or a tick of the clock that may cross the lease. The laptop is
//// simulated beside the queue as `ui_feed` is specified: it applies the frames of
//// an answer that are numbered above what it holds, in order, and drops the rest.
////
//// The oracle restates the rules from the module doc of `feed_queue` and from the
//// proposal, never from the queue's code, and every rule is checked after every
//// command under its own tag:
////
//// - `prefix`: the frames the laptop applied are a prefix of the frames the
////   queue accepted, in order and without a repeat, and an answer never has a
////   gap;
//// - `bound`: the frames and bytes the queue holds never pass the bounds, except
////   for a single frame larger than the byte bound held alone;
//// - `lapse`: the queue has lapsed exactly when the oracle says the bound or the
////   lease was passed, and a lapse names `lapsed`;
//// - `ended`: once ended, a poll answers the ending and no frames, and a push is
////   dropped;
//// - `answer`: a poll is answered with the frames beyond `after` that fit one
////   answer, from the cursor the oracle computes, or is refused as the oracle
////   refuses it;
//// - `forget`: an ended queue is forgettable exactly one lease after it ended.
////
//// Every randomized test runs on a fixed, named seed.

import client/remote/feed_queue
import client/remote_feed
import client/remote_top
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import qcheck
import statem

/// The seed of the campaign that runs under the daemon's lease.
const campaign_seed = 1081

/// The seed of the campaign that runs under a short lease, so a tick crosses it
/// within a few commands.
const short_lease_seed = 1082

const runs = 200

const longest = 60

/// The lease of the short campaign, in milliseconds.
const short_lease_ms = 5000

fn config(seed: Int) -> statem.Config {
  statem.default_config(seed:)
  |> statem.with_test_count(runs)
  |> statem.with_max_commands(longest)
}

// --- commands ----------------------------------------------------------------

/// How large a pushed frame is. Each size is a different case of the bounds.
type Size {
  /// Ten bytes.
  Tiny

  /// Four kibibytes, so a few hundred of them reach the frame bound.
  Small

  /// Three hundred kibibytes, so about three of them reach the byte bound.
  Medium

  /// A million bytes, which fits the byte bound and one answer only alone.
  Whole

  /// More than one answer can carry, which no queue can hold.
  TooBig
}

/// What a poll names as `after`.
type Cursor {
  /// What the laptop holds.
  Current

  /// One less than what the laptop holds, which the queue already acknowledged
  /// when it is not zero.
  Stale

  /// One more than the queue ever numbered.
  Ahead
}

/// What the link does to an answer.
type Fate {
  Delivered
  Lost
  Duplicated
}

/// How far a tick moves the clock.
type Span {
  /// One second.
  Second

  /// One millisecond short of the lease.
  AlmostLease

  /// The lease.
  Lease
}

type Command {
  Push(size: Size)
  Poll(cursor: Cursor, fate: Fate)
  Tick(span: Span)
}

fn command() -> qcheck.Generator(Command) {
  qcheck.from_weighted_generators(#(45, qcheck.map(size(), Push)), [
    #(
      40,
      qcheck.map2(cursor(), fate(), fn(cursor, fate) { Poll(cursor:, fate:) }),
    ),
    #(15, qcheck.map(span(), Tick)),
  ])
}

// Each enum is drawn as an index so that a shrink moves toward the first and
// least eventful variant.
fn size() -> qcheck.Generator(Size) {
  qcheck.from_weighted_generators(#(60, qcheck.constant(Tiny)), [
    #(25, qcheck.constant(Small)),
    #(10, qcheck.constant(Medium)),
    #(3, qcheck.constant(Whole)),
    #(2, qcheck.constant(TooBig)),
  ])
}

fn cursor() -> qcheck.Generator(Cursor) {
  qcheck.from_weighted_generators(#(75, qcheck.constant(Current)), [
    #(15, qcheck.constant(Stale)),
    #(10, qcheck.constant(Ahead)),
  ])
}

fn fate() -> qcheck.Generator(Fate) {
  qcheck.from_weighted_generators(#(60, qcheck.constant(Delivered)), [
    #(25, qcheck.constant(Lost)),
    #(15, qcheck.constant(Duplicated)),
  ])
}

fn span() -> qcheck.Generator(Span) {
  qcheck.from_weighted_generators(#(70, qcheck.constant(Second)), [
    #(15, qcheck.constant(AlmostLease)),
    #(15, qcheck.constant(Lease)),
  ])
}

fn describe(command: Command) -> String {
  string.inspect(command)
}

/// The integers from `start` to `stop`, inclusive.
fn numbers(start: Int, stop: Int) -> List(Int) {
  case start > stop {
    True -> []
    False -> [start, ..numbers(start + 1, stop)]
  }
}

// --- the oracle -------------------------------------------------------------

/// One frame the oracle holds: its number and its size in bytes.
type Held {
  Held(n: Int, size: Int)
}

/// The rules, restated as plain data beside the queue.
type Oracle {
  Oracle(
    /// The frames the queue accepted, in number order, as text.
    accepted: List(String),
    /// The frames not yet acknowledged.
    held: List(Held),
    /// The highest number acknowledged.
    floor: Int,
    /// The highest number assigned.
    last: Int,
    /// When a poll last renewed the lease.
    leased_ms: Int,
    /// When the oracle says the feed lapsed, or `None` while it is live.
    lapsed_at: Option(Int),
  )
}

/// The simulated laptop: what it holds of the feed.
type Laptop {
  Laptop(received: Int, applied: List(String))
}

type Sut {
  Sut(
    queue: feed_queue.Queue,
    oracle: Oracle,
    laptop: Laptop,
    now_ms: Int,
    pushed: Int,
    lease_ms: Int,
  )
}

fn new_sut(lease_ms: Int) -> Sut {
  Sut(
    queue: feed_queue.new(0),
    oracle: Oracle(
      accepted: [],
      held: [],
      floor: 0,
      last: 0,
      leased_ms: 0,
      lapsed_at: None,
    ),
    laptop: Laptop(received: 0, applied: []),
    now_ms: 0,
    pushed: 0,
    lease_ms:,
  )
}

fn size_of(size: Size) -> Int {
  case size {
    Tiny -> 10
    Small -> 4096
    Medium -> 307_200
    Whole -> 1_000_000
    TooBig -> 1_046_000
  }
}

/// A frame of the size, unique by its serial number so a repeat or a reorder
/// shows as a different text.
fn frame(serial: Int, size: Size) -> String {
  let head = "#" <> int.to_string(serial) <> ":"
  let pad = int.max(size_of(size) - string.byte_size(head), 0)
  head <> string.repeat("x", pad)
}

// --- running a command ------------------------------------------------------

fn violation(tag: String, detail: String) -> statem.Violation {
  statem.Violation(tag:, detail:)
}

fn execute(sut: Sut, command: Command) -> Result(Sut, statem.Violation) {
  use stepped <- result.try(case command {
    Push(size:) -> pushed(sut, size)
    Poll(cursor:, fate:) -> polled(sut, cursor, fate)
    Tick(span:) -> ticked(sut, span)
  })
  use Nil <- result.try(agrees(stepped))
  Ok(stepped)
}

/// Pushes a frame to the queue and to the oracle.
fn pushed(sut: Sut, size: Size) -> Result(Sut, statem.Violation) {
  let serial = sut.pushed + 1
  let text = frame(serial, size)
  let bytes = string.byte_size(text)
  let wire = bytes + 2
  let queue = feed_queue.push(sut.queue, text, sut.now_ms)
  let oracle = sut.oracle
  let next = case oracle.lapsed_at {
    // A frame pushed to an ended queue is dropped.
    Some(_) -> oracle
    None -> {
      let alone = wire <= feed_queue.answer_bytes
      let held_bytes =
        list.fold(oracle.held, 0, fn(sum, held) { sum + held.size })
      let room =
        list.length(oracle.held) < remote_feed.queue_frames
        && held_bytes + bytes <= remote_feed.queue_bytes
      case alone && { oracle.held == [] || room } {
        True ->
          Oracle(
            ..oracle,
            accepted: list.append(oracle.accepted, [text]),
            held: list.append(oracle.held, [
              Held(n: oracle.last + 1, size: bytes),
            ]),
            last: oracle.last + 1,
          )
        False -> Oracle(..oracle, held: [], lapsed_at: Some(sut.now_ms))
      }
    }
  }
  Ok(Sut(..sut, queue:, oracle: next, pushed: serial))
}

/// The `after` a cursor kind names, given what the laptop holds.
fn after_of(sut: Sut, cursor: Cursor) -> Int {
  case cursor {
    Current -> sut.laptop.received
    Stale -> sut.laptop.received - 1
    Ahead -> sut.oracle.last + 1
  }
}

/// Polls the queue and the oracle, then lets the link do its worst to the answer.
fn polled(
  sut: Sut,
  cursor: Cursor,
  fate: Fate,
) -> Result(Sut, statem.Violation) {
  let after = after_of(sut, cursor)
  let read = feed_queue.read(sut.queue, after, sut.now_ms)
  let oracle = sut.oracle

  case oracle.lapsed_at, read {
    // An ended queue answers its ending whatever the cursor, with no frames.
    Some(_), Ok(feed_queue.Reading(frames:, ended:, ..)) ->
      case frames, ended {
        [], Some(remote_top.FeedLapsed) -> Ok(sut)
        _, _ ->
          Error(violation(
            "ended",
            "an ended queue answered " <> string.inspect(#(frames, ended)),
          ))
      }
    Some(_), Error(_) ->
      Error(violation("ended", "an ended queue refused a cursor"))

    None, Error(why) -> refused(sut, after, why)
    None, Ok(reading) -> answered(sut, after, reading, fate)
  }
}

/// A live queue refused a cursor. The oracle must agree that the cursor was
/// ahead of the queue or behind what was acknowledged, and nothing changes.
fn refused(
  sut: Sut,
  after: Int,
  why: feed_queue.Cursor,
) -> Result(Sut, statem.Violation) {
  let expected = case after > sut.oracle.last, after < sut.oracle.floor {
    True, _ -> Some(feed_queue.AheadOfQueue)
    False, True -> Some(feed_queue.BehindFloor)
    False, False -> None
  }
  case expected == Some(why) {
    True -> Ok(sut)
    False ->
      Error(violation(
        "answer",
        "refused after "
          <> int.to_string(after)
          <> " as "
          <> string.inspect(why),
      ))
  }
}

/// A live queue answered. The oracle computes the frames the answer must carry,
/// the queue's state moves with the poll, and the laptop applies what the link
/// delivers.
fn answered(
  sut: Sut,
  after: Int,
  reading: feed_queue.Reading,
  fate: Fate,
) -> Result(Sut, statem.Violation) {
  let oracle = sut.oracle
  case after > oracle.last || after < oracle.floor {
    True ->
      Error(violation(
        "answer",
        "answered a cursor the oracle refuses: " <> int.to_string(after),
      ))
    False -> {
      let beyond = list.drop(oracle.accepted, after)
      let fitting = fit(beyond, feed_queue.answer_bytes)
      let acknowledged = list.filter(oracle.held, fn(held) { held.n > after })
      use Nil <- result.try(case reading.frames == fitting {
        True -> Ok(Nil)
        False ->
          Error(violation(
            "answer",
            "the answer carried "
              <> int.to_string(list.length(reading.frames))
              <> " frames, the oracle expected "
              <> int.to_string(list.length(fitting)),
          ))
      })
      use Nil <- result.try(case reading.first == after + 1, reading.ended {
        True, None -> Ok(Nil)
        _, _ ->
          Error(violation("answer", "the answer's number or ending is wrong"))
      })
      let advanced =
        Sut(
          ..sut,
          queue: reading.queue,
          oracle: Oracle(
            ..oracle,
            held: acknowledged,
            floor: after,
            leased_ms: sut.now_ms,
          ),
        )
      deliver(advanced, reading, fate)
    }
  }
}

/// The frames that fit `room` bytes as JSON strings, in order, which is what one
/// answer carries.
fn fit(frames: List(String), room: Int) -> List(String) {
  case frames {
    [] -> []
    [next, ..rest] -> {
      let wire = string.byte_size(next) + 2
      case wire <= room {
        True -> [next, ..fit(rest, room - wire)]
        False -> []
      }
    }
  }
}

/// The link's fate for an answer. The laptop applies the frames of a delivered
/// answer that are numbered above what it holds, and an answer that arrives twice
/// changes nothing the second time.
fn deliver(
  sut: Sut,
  reading: feed_queue.Reading,
  fate: Fate,
) -> Result(Sut, statem.Violation) {
  case fate {
    Lost -> Ok(sut)
    Delivered -> applied(sut, reading)
    Duplicated -> {
      use once <- result.try(applied(sut, reading))
      applied(once, reading)
    }
  }
}

fn applied(
  sut: Sut,
  reading: feed_queue.Reading,
) -> Result(Sut, statem.Violation) {
  apply_frames(sut, reading.first, reading.frames)
}

fn apply_frames(
  sut: Sut,
  number: Int,
  frames: List(String),
) -> Result(Sut, statem.Violation) {
  case frames {
    [] -> Ok(sut)
    [text, ..rest] -> {
      let laptop = sut.laptop
      case number <= laptop.received {
        // A frame at or below what the laptop holds is dropped, which is how
        // a duplicated answer is harmless.
        True -> apply_frames(sut, number + 1, rest)
        False ->
          case number == laptop.received + 1 {
            True ->
              apply_frames(
                Sut(
                  ..sut,
                  laptop: Laptop(
                    received: number,
                    applied: list.append(laptop.applied, [text]),
                  ),
                ),
                number + 1,
                rest,
              )
            False ->
              Error(violation(
                "prefix",
                "the answer skipped from "
                  <> int.to_string(laptop.received)
                  <> " to "
                  <> int.to_string(number),
              ))
          }
      }
    }
  }
}

/// Moves the clock and lets the queue expire, as the feed host's lease timer does.
fn ticked(sut: Sut, span: Span) -> Result(Sut, statem.Violation) {
  let now = case span {
    Second -> sut.now_ms + 1000
    AlmostLease -> sut.now_ms + sut.lease_ms - 1
    Lease -> sut.now_ms + sut.lease_ms
  }
  let queue = feed_queue.expire(sut.queue, now, sut.lease_ms)
  let oracle = sut.oracle
  let next = case oracle.lapsed_at, now - oracle.leased_ms >= sut.lease_ms {
    None, True -> Oracle(..oracle, held: [], lapsed_at: Some(now))
    _, _ -> oracle
  }
  Ok(Sut(..sut, queue:, oracle: next, now_ms: now))
}

// --- the checks after every command ------------------------------------------

fn agrees(sut: Sut) -> Result(Nil, statem.Violation) {
  let oracle = sut.oracle
  let queue = sut.queue
  let held_bytes = list.fold(oracle.held, 0, fn(sum, held) { sum + held.size })
  let ended = case oracle.lapsed_at {
    Some(_) -> Some(remote_top.FeedLapsed)
    None -> None
  }

  use Nil <- result.try(same(
    "lapse",
    feed_queue.ending(queue),
    ended,
    "the queue's ending",
  ))
  use Nil <- result.try(same(
    "bound",
    #(feed_queue.held_frames(queue), feed_queue.held_bytes(queue)),
    #(list.length(oracle.held), held_bytes),
    "the frames and bytes held",
  ))
  use Nil <- result.try(same(
    "answer",
    #(feed_queue.last(queue), feed_queue.floor(queue)),
    #(oracle.last, oracle.floor),
    "the queue's numbers",
  ))
  use Nil <- result.try(bounded(sut))
  use Nil <- result.try(prefixed(sut))
  forgettable(sut)
}

fn same(
  tag: String,
  found: a,
  expected: a,
  what: String,
) -> Result(Nil, statem.Violation) {
  case found == expected {
    True -> Ok(Nil)
    False ->
      Error(violation(
        tag,
        what
          <> " were "
          <> string.inspect(found)
          <> " and the oracle expected "
          <> string.inspect(expected),
      ))
  }
}

/// The bounds hold in the queue itself, whatever the oracle says: at most the
/// frame bound, and at most the byte bound unless one frame is held alone.
fn bounded(sut: Sut) -> Result(Nil, statem.Violation) {
  let frames = feed_queue.held_frames(sut.queue)
  let bytes = feed_queue.held_bytes(sut.queue)
  case
    frames <= remote_feed.queue_frames
    && { bytes <= remote_feed.queue_bytes || frames == 1 }
  {
    True -> Ok(Nil)
    False ->
      Error(violation(
        "bound",
        "the queue holds "
          <> int.to_string(frames)
          <> " frames and "
          <> int.to_string(bytes)
          <> " bytes",
      ))
  }
}

/// What the laptop applied is a prefix of what the queue accepted.
fn prefixed(sut: Sut) -> Result(Nil, statem.Violation) {
  let applied = sut.laptop.applied
  case list.take(sut.oracle.accepted, list.length(applied)) == applied {
    True -> Ok(Nil)
    False ->
      Error(violation(
        "prefix",
        "the laptop's frames are not a prefix of the accepted frames",
      ))
  }
}

/// An ended queue is forgettable exactly one lease after it ended.
fn forgettable(sut: Sut) -> Result(Nil, statem.Violation) {
  let expected = case sut.oracle.lapsed_at {
    Some(at) -> sut.now_ms - at >= sut.lease_ms
    None -> False
  }
  same(
    "forget",
    feed_queue.forgettable(sut.queue, sut.now_ms, sut.lease_ms),
    expected,
    "whether the queue is forgettable",
  )
}

// --- the properties -----------------------------------------------------------

fn spec(lease_ms: Int) -> statem.Spec(Nil, Command, Sut) {
  statem.Spec(
    initial: Nil,
    command: fn(_) { command() },
    precondition: fn(_, _) { statem.Admit },
    next_model: fn(_, _) { Nil },
    new_sut: fn() { new_sut(lease_ms) },
    execute: fn(sut, _, command) { execute(sut, command) },
    finish: fn(_, _) { Ok(Nil) },
    teardown: fn(_) { Nil },
  )
}

fn checked(seed: Int, lease_ms: Int) -> Nil {
  case statem.check(spec(lease_ms), config(seed)) {
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

pub fn the_queue_keeps_its_rules_under_the_daemons_lease_test() {
  checked(campaign_seed, remote_feed.lease_ms)
}

pub fn the_queue_keeps_its_rules_under_a_short_lease_test() {
  checked(short_lease_seed, short_lease_ms)
}

// --- the cases the rules talk about ------------------------------------------

/// Whether the oracle ran the lists of one campaign through a case: a lapse by
/// the frame bound, by the byte bound, by an answer too large to carry, by the
/// lease, and a poll that was refused.
fn reached(seed: Int, lease_ms: Int) -> List(String) {
  numbers(0, runs - 1)
  |> list.flat_map(fn(run) {
    let commands = statem.commands(spec(lease_ms), config(seed), run)
    case run_all(new_sut(lease_ms), commands, []) {
      Ok(cases) -> cases
      Error(_) -> []
    }
  })
}

fn run_all(
  sut: Sut,
  commands: List(Command),
  cases: List(String),
) -> Result(List(String), statem.Violation) {
  case commands {
    [] -> Ok(cases)
    [command, ..rest] -> {
      let before = sut
      use stepped <- result.try(execute(sut, command))
      run_all(
        stepped,
        rest,
        list.append(cases, reached_by(before, stepped, command)),
      )
    }
  }
}

fn reached_by(before: Sut, after: Sut, command: Command) -> List(String) {
  let lapsed = before.oracle.lapsed_at == None && after.oracle.lapsed_at != None
  case command, lapsed {
    Push(TooBig), True -> ["too-big"]
    Push(_), True ->
      case list.length(before.oracle.held) >= remote_feed.queue_frames {
        True -> ["frame-bound"]
        False -> ["byte-bound"]
      }
    Tick(_), True -> ["lease"]
    Poll(Ahead, _), False -> ["ahead"]
    Poll(Stale, _), False ->
      case after.laptop.received > 0 {
        True -> ["stale"]
        False -> []
      }
    Poll(_, Lost), False -> ["lost"]
    Poll(_, Duplicated), False -> ["duplicated"]
    Push(Whole), False -> ["whole-alone"]
    _, _ -> []
  }
}

pub fn the_commands_reach_every_case_the_rules_talk_about_test() {
  let cases =
    list.append(
      reached(campaign_seed, remote_feed.lease_ms),
      reached(short_lease_seed, short_lease_ms),
    )
  let wanted = [
    "too-big", "byte-bound", "lease", "ahead", "stale", "lost", "duplicated",
    "whole-alone",
  ]
  let missing = list.filter(wanted, fn(case_) { !list.contains(cases, case_) })
  assert missing == []
}

// The frame bound needs more frames than a generated list holds, so it has a
// direct test beside the property.

fn pushed_tiny(queue: feed_queue.Queue, count: Int) -> feed_queue.Queue {
  numbers(1, count)
  |> list.fold(queue, fn(queue, serial) {
    feed_queue.push(queue, "#" <> int.to_string(serial), 0)
  })
}

pub fn the_five_hundred_and_twelfth_frame_fits_and_the_next_lapses_test() {
  let full = pushed_tiny(feed_queue.new(0), remote_feed.queue_frames)
  assert feed_queue.ending(full) == None
  assert feed_queue.held_frames(full) == remote_feed.queue_frames

  let over = feed_queue.push(full, "one more", 0)
  assert feed_queue.ending(over) == Some(remote_top.FeedLapsed)
  assert feed_queue.held_frames(over) == 0
}

pub fn a_frame_that_nearly_fills_an_answer_is_held_alone_and_a_second_lapses_test() {
  // One answer carries at most `answer_bytes` of JSON string, which is less
  // than the byte bound, so a frame the answer can carry is always inside the
  // bound and the proposal's exception for a larger frame is never needed.
  assert feed_queue.answer_bytes < remote_feed.queue_bytes
  let big = string.repeat("x", 1_040_000)
  let alone = feed_queue.push(feed_queue.new(0), big, 0)
  assert feed_queue.ending(alone) == None
  assert feed_queue.held_frames(alone) == 1

  // The queue is not empty any more, so a second frame that passes the byte
  // bound lapses it.
  let two = feed_queue.push(alone, string.repeat("y", 20_000), 0)
  assert feed_queue.ending(two) == Some(remote_top.FeedLapsed)
}

pub fn a_poll_acknowledges_what_it_names_and_an_answer_the_link_lost_is_answered_again_test() {
  let queue =
    feed_queue.new(0)
    |> feed_queue.push("a", 1)
    |> feed_queue.push("b", 2)
  let assert Ok(first) = feed_queue.read(queue, 0, 3)
  assert first.frames == ["a", "b"]
  assert first.first == 1

  // The answer was lost, so the laptop asks again with the same cursor.
  let assert Ok(again) = feed_queue.read(first.queue, 0, 4)
  assert again.frames == ["a", "b"]

  // The laptop received "a", so the next poll acknowledges it.
  let assert Ok(after_a) = feed_queue.read(again.queue, 1, 5)
  assert after_a.frames == ["b"]
  assert after_a.first == 2
  assert feed_queue.floor(after_a.queue) == 1
}

pub fn a_cursor_ahead_of_the_queue_or_behind_the_floor_is_refused_test() {
  let queue = feed_queue.new(0) |> feed_queue.push("a", 0)
  assert feed_queue.read(queue, 2, 0) |> result.is_error
  let assert Ok(read) = feed_queue.read(queue, 1, 0)
  assert feed_queue.read(read.queue, 0, 0) |> result.is_error
}
