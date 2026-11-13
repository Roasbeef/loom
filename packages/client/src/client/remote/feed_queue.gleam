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
//// `remote_feed.queue_bytes` bytes that the laptop has not acknowledged, and it
//// admits a frame that one answer can carry. Passing either bound **lapses**
//// the feed: the queue drops every frame and answers `lapsed` from then on. It
//// drops the whole queue and never one frame, because a stream delta carries no
//// offset, so dropping one from the middle of an answer would draw a garbled
//// preview until the entry lands. A feed also ends `stopped`, when the
//// session's run ended, and `revoked`, when the box's owner took the page's
//// access away. The first ending is the one a feed keeps.
////
//// The lease, the third way a feed lapses, is not here. It is a weft named
//// timeout in `feed_host`, re-armed by every poll, because the house rule gives
//// every timer to weft and a queue that also read a clock would own the lease
//// twice. The queue knows what a poll acknowledged and nothing about when.
////
//// A frame that cannot fit alone in an answer under the stable exchange's
//// envelope ends the feed too. That case is reachable, though rare. The
//// gateway's `held_input_returned` push carries the whole text of a queued
//// prompt with no bound, so a relayed page that queued a prompt of more than
//// about half a mebibyte, when the box drains, is a push no answer can carry
//// (see the addendum of protocol-change/108). Piece answers for polls, which
//// would carry such a frame, belong to slice 4, and until then the feed lapses
//// and the page reconnects.
////
//// ## Flow
////
//// `new` → `push` → `read` → `end`
////
//// 1. `new` starts a live, empty queue.
//// 2. `push` numbers and holds one frame, or lapses the feed when it will not
////    fit.
//// 3. `read` is a poll: it checks the cursor, drops what was acknowledged and
////    answers the frames that fit one answer.
//// 4. `end` records a stop or a revocation.

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
    /// Why the feed ended, once it has.
    ended: Option(FeedEnd),
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
    /// The queue after the poll acknowledged.
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

/// A live, empty queue.
///
/// ## Examples
///
/// ```gleam
/// assert feed_queue.last(feed_queue.new()) == 0
/// ```
pub fn new() -> Queue {
  Queue(held: [], floor: 0, last: 0, bytes: 0, ended: None)
}

/// Numbers and holds one frame. The queue lapses instead when the frame would
/// pass the frame bound or the byte bound, or when no answer could carry it
/// alone. A frame pushed to an ended queue is dropped, because nothing reads it.
///
/// ## Examples
///
/// ```gleam
/// let queue = feed_queue.push(feed_queue.new(), "{}")
/// assert feed_queue.last(queue) == 1
/// ```
pub fn push(queue: Queue, frame: String) -> Queue {
  // Nothing reads the frames of an ended feed, so a push to one is dropped.
  case queue.ended {
    Some(_) -> queue
    None -> {
      let size = string.byte_size(frame)
      let wire = string.byte_size(json.to_string(json.String(frame)))

      // A frame that fits is numbered and held. One that does not ends the feed,
      // and never leaves a gap in the numbers the laptop was promised.
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
        False -> end(queue, remote_top.FeedLapsed)
      }
    }
  }
}

/// Whether a frame of `size` bytes, `wire` once it is a JSON string, can join
/// the queue. It must fit one answer alone, which is under the byte bound, and
/// leave the frame and byte bounds unpassed.
fn fits(queue: Queue, size: Int, wire: Int) -> Bool {
  wire <= answer_bytes
  && list.length(queue.held) < remote_feed.queue_frames
  && queue.bytes + size <= remote_feed.queue_bytes
}

/// Answers a poll: checks that `after` is a cursor the queue can honour, drops
/// every frame numbered `after` or less and returns the frames beyond `after`
/// that fit `answer_bytes`. The frames stay queued until a later poll
/// acknowledges them. An ended queue answers its ending and no frames, whatever
/// the cursor.
///
/// ## Examples
///
/// ```gleam
/// let queue = feed_queue.push(feed_queue.new(), "{}")
/// let assert Ok(reading) = feed_queue.read(queue, 0)
/// assert reading.frames == ["{}"]
/// ```
pub fn read(queue: Queue, after: Int) -> Result(Reading, Cursor) {
  case queue.ended {
    Some(why) ->
      Ok(Reading(queue:, first: queue.last + 1, frames: [], ended: Some(why)))
    None ->
      case after > queue.last, after < queue.floor {
        True, _ -> Error(AheadOfQueue)
        _, True -> Error(BehindFloor)
        False, False -> {
          let acknowledged = acknowledge(queue, after)
          Ok(Reading(
            queue: acknowledged,
            first: after + 1,
            frames: carried(acknowledged.held),
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

/// Ends a live feed with `why`, dropping every frame. The first ending a feed
/// has is the one it keeps.
///
/// ## Examples
///
/// ```gleam
/// let queue = feed_queue.end(feed_queue.new(), remote_top.FeedStopped)
/// assert feed_queue.ending(queue) == option.Some(remote_top.FeedStopped)
/// ```
pub fn end(queue: Queue, why: FeedEnd) -> Queue {
  case queue.ended {
    Some(_) -> queue
    None -> Queue(..queue, held: [], bytes: 0, ended: Some(why))
  }
}

/// Whether the queue holds a frame beyond `after`, which is what releases a
/// held poll early.
///
/// ## Examples
///
/// ```gleam
/// assert !feed_queue.has_after(feed_queue.new(), 0)
/// ```
pub fn has_after(queue: Queue, after: Int) -> Bool {
  queue.ended == None && queue.last > after
}

/// Why the feed ended, or `None` while it is live.
///
/// ## Examples
///
/// ```gleam
/// assert feed_queue.ending(feed_queue.new()) == option.None
/// ```
pub fn ending(queue: Queue) -> Option(FeedEnd) {
  queue.ended
}

/// The highest number assigned to a frame, or zero.
///
/// ## Examples
///
/// ```gleam
/// assert feed_queue.last(feed_queue.new()) == 0
/// ```
pub fn last(queue: Queue) -> Int {
  queue.last
}

/// The highest number a poll acknowledged, or zero.
///
/// ## Examples
///
/// ```gleam
/// assert feed_queue.floor(feed_queue.new()) == 0
/// ```
pub fn floor(queue: Queue) -> Int {
  queue.floor
}

/// How many frames the laptop has not acknowledged.
///
/// ## Examples
///
/// ```gleam
/// assert feed_queue.held_frames(feed_queue.new()) == 0
/// ```
pub fn held_frames(queue: Queue) -> Int {
  list.length(queue.held)
}

/// How many bytes of frames the laptop has not acknowledged.
///
/// ## Examples
///
/// ```gleam
/// assert feed_queue.held_bytes(feed_queue.new()) == 0
/// ```
pub fn held_bytes(queue: Queue) -> Int {
  queue.bytes
}
