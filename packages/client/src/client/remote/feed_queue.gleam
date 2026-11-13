//// The numbered, bounded queue a live session feed holds (protocol-change/108).
////
//// The box's gateway writes frames to a feed host as they happen, and the
//// laptop collects them with a long poll. Between the two sits this queue. It is
//// a pure value: it holds no process, reads no clock and sends nothing, so the
//// feed host owns the mailbox and the timers and this module owns the rules.
//// That keeps the rules testable without spawning anything, and each of them is
//// checked by `feed_queue_test` under fixed-seed generated sequences.
////
//// ## What the queue promises
////
//// Frames are numbered consecutively from one as they arrive. A poll names
//// `after`, the number of the last frame the laptop received, and the queue
//// drops every frame numbered `after` or less and answers the frames it holds
//// beyond it. A frame stays queued until a later poll acknowledges it, so an
//// answer the link lost is answered again by the same poll. The laptop
//// therefore receives a prefix of the frames the gateway wrote, in order, and
//// never one twice.
////
//// ## When a feed ends
////
//// The queue holds at most `remote_feed.queue_frames` frames and
//// `remote_feed.queue_bytes` bytes that the laptop has not acknowledged, and an
//// empty queue admits any frame one answer can carry, so a frame's size alone
//// never ends a feed. Passing either bound, or going a whole
//// `remote_feed.lease_ms` without a poll, **lapses** the feed:
//// the queue drops every frame and answers `lapsed` from then on. It drops the
//// whole queue and never one frame, because a stream delta carries no offset, so
//// dropping one from the middle of an answer would draw a garbled preview until
//// the entry lands. A feed also ends `stopped`, when the session's run ended,
//// and `revoked`, when the box's owner took the page's access away. The first
//// ending is the one a feed keeps, and an ended queue is forgotten one lease
//// after it ended, which is long enough for a late poll to learn why.
////
//// A frame that cannot fit alone in an answer under the stable exchange's
//// envelope is the one case where a size ends a feed. No gateway push reaches
//// that size (protocol-change/108, the addendum on the push-size question: a
//// daemon's gateway pushes a notice and never an entry, and every other push is
//// under 150 KiB), so the case is unreachable, and this module still refuses the
//// frame rather than build an answer the exchange would replace with
//// `oversized`.
////
//// ## Flow
////
//// `new` → `push` → `read` → `expire` → `end` → `forgettable`
////
//// 1. `new` starts a live, empty queue whose lease begins at the time it is
////    given.
//// 2. `push` numbers and holds one frame, or lapses the feed when it will not
////    fit.
//// 3. `read` is a poll: it checks the cursor, drops what was acknowledged,
////    renews the lease and answers the frames that fit one answer.
//// 4. `expire` lapses a feed whose lease has run out, and `end` records the
////    other two endings.
//// 5. `forgettable` says when an ended feed's token may be forgotten.

import client/remote_feed
import client/remote_top.{type FeedEnd}
import core/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// The most bytes of frames one answer carries. It is the stable exchange's
/// envelope (`peer_codec.operation_bytes`, 1,048,576) less 4,096 for the
/// envelope's own members, the request id, `first`, `ended` and the separators
/// between at most 512 frames, which together are well under a kilobyte.
pub const answer_bytes = 1_044_480

/// A frame the queue holds, with the size it has as a JSON string.
type Held {
  Held(
    /// The frame's number among the feed's frames.
    n: Int,
    /// The frame, as the gateway wrote it.
    text: String,
    /// The frame's size in bytes, which the queue's byte bound counts.
    size: Int,
    /// The frame's size once it is a JSON string in an answer, which is what
    /// the answer's byte bound counts.
    wire: Int,
  )
}

/// How a feed ended and when, on the clock the feed host reads.
type Ending {
  Ending(why: FeedEnd, at_ms: Int)
}

/// One feed's queue. It is opaque so that every change goes through a rule
/// of this module.
pub opaque type Queue {
  Queue(
    /// The frames the laptop has not acknowledged, in number order.
    held: List(Held),
    /// The highest number acknowledged, or zero.
    floor: Int,
    /// The highest number assigned, or zero.
    last: Int,
    /// The bytes of `held`.
    bytes: Int,
    /// When a poll last renewed the lease.
    leased_ms: Int,
    /// Why the feed ended, once it has.
    ended: Option(Ending),
  )
}

/// Why a poll's cursor cannot be honoured.
pub type Cursor {
  /// `after` names a frame this feed has not numbered yet.
  AheadOfQueue

  /// `after` is below what a poll already acknowledged, so the frames between
  /// are gone and the laptop cannot be told what it missed.
  BehindFloor
}

/// What a poll is answered.
pub type Reading {
  Reading(
    /// The queue after the poll acknowledged and renewed.
    queue: Queue,
    /// The number of the first frame in `frames`, or of the next frame when
    /// there are none.
    first: Int,
    /// The frames beyond `after` that fit one answer, in number order.
    frames: List(String),
    /// Why the feed ended, or `None` while it is live.
    ended: Option(FeedEnd),
  )
}

/// A live, empty queue whose lease begins at `now_ms`.
///
/// ## Examples
///
/// ```gleam
/// assert feed_queue.last(feed_queue.new(0)) == 0
/// ```
pub fn new(now_ms: Int) -> Queue {
  Queue(held: [], floor: 0, last: 0, bytes: 0, leased_ms: now_ms, ended: None)
}

/// Numbers and holds one frame. The queue lapses instead when the frame would
/// pass the frame bound or the byte bound, or when no answer could carry it
/// alone. A frame pushed to an ended queue is dropped, because nothing reads it.
///
/// ## Examples
///
/// ```gleam
/// let queue = feed_queue.push(feed_queue.new(0), "{}", 1)
/// assert feed_queue.last(queue) == 1
/// ```
pub fn push(queue: Queue, frame: String, now_ms: Int) -> Queue {
  // Nothing reads the frames of an ended feed, so a push to one is dropped.
  case queue.ended {
    Some(_) -> queue
    None -> {
      let size = string.byte_size(frame)
      let wire = string.byte_size(json.to_string(json.String(frame)))

      // A frame that fits is numbered and held. One that does not ends the feed, and
      // never leaves a gap in the numbers the laptop was promised.
      case fits(queue, size, wire) {
        True -> {
          let n = queue.last + 1
          Queue(
            ..queue,
            held: list.append(queue.held, [Held(n:, text: frame, size:, wire:)]),
            last: n,
            bytes: queue.bytes + size,
          )
        }
        False -> lapse(queue, now_ms)
      }
    }
  }
}

/// Whether a frame of `size` bytes, `wire` once it is a JSON string, can join
/// the queue. An empty queue admits any frame an answer can carry alone. Such a
/// frame is always inside the byte bound, because one answer carries less than the
/// bound, so the proposal's exception for a frame larger than the bound never
/// applies and is not written.
fn fits(queue: Queue, size: Int, wire: Int) -> Bool {
  let alone = wire <= answer_bytes
  let room =
    list.length(queue.held) < remote_feed.queue_frames
    && queue.bytes + size <= remote_feed.queue_bytes
  alone && { queue.held == [] || room }
}

/// Answers a poll: checks that `after` is a cursor the queue can honour, drops
/// every frame numbered `after` or less, renews the lease at `now_ms` and
/// returns the frames beyond `after` that fit `answer_bytes`, at least one when
/// there is one. The frames stay queued until a later poll acknowledges them.
/// An ended queue answers its ending and no frames, whatever the cursor.
///
/// ## Examples
///
/// ```gleam
/// let queue = feed_queue.push(feed_queue.new(0), "{}", 1)
/// let assert Ok(reading) = feed_queue.read(queue, 0, 2)
/// assert reading.frames == ["{}"]
/// ```
pub fn read(queue: Queue, after: Int, now_ms: Int) -> Result(Reading, Cursor) {
  case queue.ended {
    Some(Ending(why:, ..)) ->
      Ok(Reading(queue:, first: queue.last + 1, frames: [], ended: Some(why)))
    None ->
      case after > queue.last, after < queue.floor {
        True, _ -> Error(AheadOfQueue)
        _, True -> Error(BehindFloor)
        False, False -> {
          let acknowledged = acknowledge(queue, after)
          let renewed = Queue(..acknowledged, leased_ms: now_ms)
          Ok(Reading(
            queue: renewed,
            first: after + 1,
            frames: carried(renewed.held),
            ended: None,
          ))
        }
      }
  }
}

/// Drops every frame numbered `after` or less.
fn acknowledge(queue: Queue, after: Int) -> Queue {
  let #(dropped, kept) =
    list.split_while(queue.held, fn(held) { held.n <= after })
  let freed = list.fold(dropped, 0, fn(sum, held) { sum + held.size })
  Queue(..queue, held: kept, floor: after, bytes: queue.bytes - freed)
}

/// The frames of an answer: those that fit `answer_bytes` together, in order.
fn carried(held: List(Held)) -> List(String) {
  carried_within(held, answer_bytes, [])
}

/// Takes frames in order while their JSON-string sizes fit `room`. The first
/// frame always fits an empty answer, because `push` admits only a frame that
/// fits an answer alone, so a queue that holds a frame answers at least one.
fn carried_within(
  held: List(Held),
  room: Int,
  taken: List(String),
) -> List(String) {
  case held {
    [] -> list.reverse(taken)
    [next, ..rest] ->
      case next.wire <= room {
        True -> carried_within(rest, room - next.wire, [next.text, ..taken])
        False -> list.reverse(taken)
      }
  }
}

/// Lapses a feed whose lease has run out: no poll has renewed it for `lease_ms`
/// (`remote_feed.lease_ms` in the daemon). An ended queue and a queue still
/// inside its lease are returned unchanged.
///
/// ## Examples
///
/// ```gleam
/// let queue = feed_queue.expire(feed_queue.new(0), 15_000, 15_000)
/// assert feed_queue.ending(queue) == option.Some(remote_top.FeedLapsed)
/// ```
pub fn expire(queue: Queue, now_ms: Int, lease_ms: Int) -> Queue {
  case queue.ended, now_ms - queue.leased_ms >= lease_ms {
    None, True -> lapse(queue, now_ms)
    Some(_), _ | None, False -> queue
  }
}

/// Ends a live feed with `why`, dropping every frame. The first ending a feed
/// has is the one it keeps.
///
/// ## Examples
///
/// ```gleam
/// let queue = feed_queue.end(feed_queue.new(0), remote_top.FeedStopped, 5)
/// assert feed_queue.ending(queue) == option.Some(remote_top.FeedStopped)
/// ```
pub fn end(queue: Queue, why: FeedEnd, now_ms: Int) -> Queue {
  case queue.ended {
    Some(_) -> queue
    None ->
      Queue(
        ..queue,
        held: [],
        bytes: 0,
        ended: Some(Ending(why:, at_ms: now_ms)),
      )
  }
}

fn lapse(queue: Queue, now_ms: Int) -> Queue {
  end(queue, remote_top.FeedLapsed, now_ms)
}

/// Whether an ended feed's token may be forgotten: a whole lease has passed
/// since it ended, so a late poll has had its chance to learn why. A live feed
/// is never forgettable.
///
/// ## Examples
///
/// ```gleam
/// let queue = feed_queue.end(feed_queue.new(0), remote_top.FeedStopped, 0)
/// assert !feed_queue.forgettable(queue, 14_999, 15_000)
/// assert feed_queue.forgettable(queue, 15_000, 15_000)
/// ```
pub fn forgettable(queue: Queue, now_ms: Int, lease_ms: Int) -> Bool {
  case queue.ended {
    Some(Ending(at_ms:, ..)) -> now_ms - at_ms >= lease_ms
    None -> False
  }
}

/// Whether the queue holds a frame beyond `after`, which is what releases a
/// held poll early.
///
/// ## Examples
///
/// ```gleam
/// assert !feed_queue.has_after(feed_queue.new(0), 0)
/// ```
pub fn has_after(queue: Queue, after: Int) -> Bool {
  queue.ended == None && queue.last > after
}

/// Why the feed ended, or `None` while it is live.
///
/// ## Examples
///
/// ```gleam
/// assert feed_queue.ending(feed_queue.new(0)) == option.None
/// ```
pub fn ending(queue: Queue) -> Option(FeedEnd) {
  option.map(queue.ended, fn(ending) { ending.why })
}

/// The highest number assigned to a frame, or zero.
///
/// ## Examples
///
/// ```gleam
/// assert feed_queue.last(feed_queue.new(0)) == 0
/// ```
pub fn last(queue: Queue) -> Int {
  queue.last
}

/// The highest number a poll acknowledged, or zero.
///
/// ## Examples
///
/// ```gleam
/// assert feed_queue.floor(feed_queue.new(0)) == 0
/// ```
pub fn floor(queue: Queue) -> Int {
  queue.floor
}

/// How many frames the laptop has not acknowledged.
///
/// ## Examples
///
/// ```gleam
/// assert feed_queue.held_frames(feed_queue.new(0)) == 0
/// ```
pub fn held_frames(queue: Queue) -> Int {
  list.length(queue.held)
}

/// How many bytes of frames the laptop has not acknowledged.
///
/// ## Examples
///
/// ```gleam
/// assert feed_queue.held_bytes(feed_queue.new(0)) == 0
/// ```
pub fn held_bytes(queue: Queue) -> Int {
  queue.bytes
}
