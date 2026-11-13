//// The frames the page's lane transmits to a live session feed, queued and cut
//// into the pieces `108.send.1` carries (protocol-change/108).
////
//// A lane transmits a frame and waits for its reply before it sends the next
//// command, but it may also write a few frames that no reply gates, so the
//// laptop holds them in order until the box has admitted them. This module is
//// the laptop's half of the piece rules `client/remote/feed_pieces` keeps on the
//// box. It is a pure value, with no process and no clock, so the interleavings
//// of lost admission answers and resends are tested under fixed seeds
//// (`feed_outbox_test`) and the process that owns the mailbox only follows what
//// this module says to send.
////
//// ## The rules
////
//// - Frames are numbered from one in the order the lane transmitted them, and a
////   frame is cut into pieces of at most `remote_feed.piece_bytes` bytes, each
////   ending on a character boundary because a piece is text.
//// - One piece is in flight. The next piece is sent only after the box admitted
////   the one before, and the first piece of frame `n + 1` only after every piece
////   of `n`, so the box sees the pieces of a frame in order and a frame at a time.
//// - A piece with no admission answer is sent again, unchanged. The box admits a
////   piece once and answers a repeat without effect, so the gateway receives each
////   frame at most once however many times its pieces were sent. This is not the
////   client resending a command: the lane's own rule for a reply that never comes
////   is untouched, and it reports an unknown outcome at its deadline.
//// - An admission answer is read only if it names the piece in flight. Any other
////   answer is a stray, so a delayed answer cannot advance a piece the box has
////   not admitted.
//// - The queue is bounded. It holds at most `max_frames` frames and
////   `max_bytes` bytes, and a frame larger than `remote_feed.frame_bytes` or an
////   empty frame is refused, so a lane that writes without bound ends the feed
////   instead of growing the laptop's memory.
////
//// ## Flow
////
//// `new` → `push` → `take` → `admitted` → `unanswered`
////
//// 1. `new` starts an outbox for a feed on which nothing was transmitted.
//// 2. `push` queues one frame the lane transmitted, or refuses it.
//// 3. `take` says which piece to send now, if one is due.
//// 4. `admitted` reads the box's answer to a piece.
//// 5. `unanswered` makes the piece in flight due again.

import client/remote/feed_cursor
import client/remote_feed
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}

/// The most frames the outbox holds that the box has not admitted whole.
pub const max_frames = 32

/// The most bytes of frame text the outbox holds that the box has not admitted
/// whole: two frames of the largest size.
pub const max_bytes = 25_165_824

/// One frame waiting to be admitted.
type Entry {
  Entry(
    /// The frame's number among the lane's frames.
    n: Int,
    /// The frame's size in bytes.
    total: Int,
    /// The bytes of the frame already admitted, which is where the next piece
    /// begins.
    offset: Int,
    /// The pieces not yet admitted, in order.
    pieces: List(String),
  )
}

/// The piece sent and not yet answered.
type Flight {
  Flight(n: Int, offset: Int)
}

/// The frames the lane transmitted and the box has not admitted. It is opaque so
/// that every change goes through a rule of this module.
pub opaque type Outbox {
  Outbox(
    /// The number the next frame pushed takes.
    next: Int,
    /// The frames held, oldest first.
    held: List(Entry),
    /// The bytes those frames hold that are not yet admitted.
    bytes: Int,
    /// The piece in flight, if any.
    flying: Option(Flight),
    /// How many sends in a row went unanswered.
    silent: Int,
  )
}

/// Why a frame was not queued.
pub type Refusal {
  /// The frame is empty, which no piece can carry.
  Empty

  /// The frame is larger than `remote_feed.frame_bytes`.
  TooLarge

  /// The outbox already holds `max_frames` frames or `max_bytes` bytes.
  Full
}

/// One piece to send, as `108.send.1` places it.
pub type Due {
  Due(
    /// The frame's number.
    n: Int,
    /// The bytes of the frame before this piece.
    offset: Int,
    /// The frame's whole size in bytes.
    total: Int,
    /// The piece's text.
    text: String,
  )
}

/// An outbox with nothing in it: the first frame pushed is number one.
///
/// ## Examples
///
/// ```gleam
/// assert feed_outbox.held_frames(feed_outbox.new()) == 0
/// ```
pub fn new() -> Outbox {
  Outbox(next: 1, held: [], bytes: 0, flying: None, silent: 0)
}

/// How many frames the box has not admitted whole.
///
/// ## Examples
///
/// ```gleam
/// assert feed_outbox.held_frames(feed_outbox.new()) == 0
/// ```
pub fn held_frames(outbox: Outbox) -> Int {
  list.length(outbox.held)
}

/// How many bytes of frame text the box has not admitted.
///
/// ## Examples
///
/// ```gleam
/// assert feed_outbox.held_bytes(feed_outbox.new()) == 0
/// ```
pub fn held_bytes(outbox: Outbox) -> Int {
  outbox.bytes
}

/// How many sends in a row went unanswered. Zero means the box answered last.
///
/// ## Examples
///
/// ```gleam
/// assert feed_outbox.silent_for(feed_outbox.new()) == 0
/// ```
pub fn silent_for(outbox: Outbox) -> Int {
  outbox.silent
}

/// Queues one frame the lane transmitted, numbered after the ones before it. An
/// empty or oversized frame, or one that would pass the outbox's bounds, is
/// refused and nothing changes.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(outbox) = feed_outbox.push(feed_outbox.new(), "{}")
/// assert feed_outbox.held_frames(outbox) == 1
/// ```
pub fn push(outbox: Outbox, frame: String) -> Result(Outbox, Refusal) {
  let bits = bit_array.from_string(frame)
  let total = bit_array.byte_size(bits)

  // An empty frame, an oversized one and a full outbox are each refused, and
  // anything else is queued behind the frames before it.
  case
    total == 0,
    total > remote_feed.frame_bytes,
    list.length(outbox.held) >= max_frames || outbox.bytes + total > max_bytes
  {
    True, _, _ -> Error(Empty)
    False, True, _ -> Error(TooLarge)
    False, False, True -> Error(Full)
    False, False, False -> {
      let entry =
        Entry(n: outbox.next, total:, offset: 0, pieces: cut(bits, total))
      Ok(
        Outbox(
          ..outbox,
          next: outbox.next + 1,
          held: list.append(outbox.held, [entry]),
          bytes: outbox.bytes + total,
        ),
      )
    }
  }
}

/// The piece to send now, if one is due: the piece after the last admitted, when
/// none is in flight. The piece is marked in flight, so `take` answers nothing
/// again until `admitted` or `unanswered` is called.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(outbox) = feed_outbox.push(feed_outbox.new(), "{}")
/// let #(_, due) = feed_outbox.take(outbox)
/// assert due == option.Some(feed_outbox.Due(n: 1, offset: 0, total: 2, text: "{}"))
/// ```
pub fn take(outbox: Outbox) -> #(Outbox, Option(Due)) {
  case outbox.flying, outbox.held {
    Some(_), _ | None, [] -> #(outbox, None)
    None, [Entry(n:, total:, offset:, pieces: [text, ..]), ..] -> #(
      Outbox(..outbox, flying: Some(Flight(n:, offset:))),
      Some(Due(n:, offset:, total:, text:)),
    )

    // An entry with no piece left is never held: `admitted` drops a frame with
    // its last piece. The arm keeps the outbox as it is rather than invent one.
    None, [Entry(pieces: [], ..), ..] -> #(outbox, None)
  }
}

/// Reads the box's answer to piece `offset` of frame `n`. The answer advances the
/// outbox only if it names the piece in flight, and a frame whose last piece was
/// admitted leaves the outbox.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(outbox) = feed_outbox.push(feed_outbox.new(), "{}")
/// let #(outbox, _) = feed_outbox.take(outbox)
/// assert feed_outbox.held_frames(feed_outbox.admitted(outbox, 1, 0)) == 0
/// ```
pub fn admitted(outbox: Outbox, n: Int, offset: Int) -> Outbox {
  case outbox.flying, outbox.held {
    Some(Flight(n: flying_n, offset: flying_offset)), [entry, ..rest]
      if flying_n == n && flying_offset == offset
    -> advance(Outbox(..outbox, flying: None, silent: 0), entry, rest)
    Some(_), _ | None, _ -> outbox
  }
}

/// Moves past the piece just admitted: the frame is done with its last piece, and
/// otherwise its next piece begins where this one ended.
fn advance(outbox: Outbox, entry: Entry, rest: List(Entry)) -> Outbox {
  // The piece at the head was admitted, so it is no longer held.
  case entry.pieces {
    [text, ..more] -> {
      let size = bit_array.byte_size(bit_array.from_string(text))
      let bytes = outbox.bytes - size

      // A frame with no piece left is done and leaves the outbox. Otherwise its
      // next piece begins where this one ended.
      case more {
        [] -> Outbox(..outbox, held: rest, bytes:)
        _ ->
          Outbox(
            ..outbox,
            held: [
              Entry(..entry, offset: entry.offset + size, pieces: more),
              ..rest
            ],
            bytes:,
          )
      }
    }
    [] -> Outbox(..outbox, held: rest)
  }
}

/// Makes the piece in flight due again, because its answer did not come, and says
/// how long to wait before sending it, which is the cursor's pause for the same
/// link. The piece is the same one, unchanged.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(outbox) = feed_outbox.push(feed_outbox.new(), "{}")
/// let #(outbox, _) = feed_outbox.take(outbox)
/// let #(_, pause) = feed_outbox.unanswered(outbox)
/// assert pause == 250
/// ```
pub fn unanswered(outbox: Outbox) -> #(Outbox, Int) {
  #(
    Outbox(..outbox, flying: None, silent: outbox.silent + 1),
    feed_cursor.pause_ms(outbox.silent),
  )
}

/// The pieces of a frame, each at most `remote_feed.piece_bytes` bytes and each
/// ending on a character boundary.
fn cut(bits: BitArray, total: Int) -> List(String) {
  cut_from(bits, 0, total, [])
}

/// Cuts the frame from byte `at` to its end, collecting the pieces newest first.
fn cut_from(
  bits: BitArray,
  at: Int,
  total: Int,
  found: List(String),
) -> List(String) {
  // The cut is done when it reaches the end of the frame.
  case at >= total {
    True -> list.reverse(found)
    False -> {
      let stop =
        boundary(bits, int.min(at + remote_feed.piece_bytes, total), total)

      // The piece runs from `at` to `stop`, which is a character boundary, and
      // the next one begins there.
      case bit_array.slice(bits, at, stop - at) {
        Ok(slice) ->
          case bit_array.to_string(slice) {
            Ok(text) -> cut_from(bits, stop, total, [text, ..found])

            // The frame is text, so a boundary found by the rule below always
            // yields text. The arm ends the cut instead of looping.
            Error(Nil) -> list.reverse(found)
          }
        Error(Nil) -> list.reverse(found)
      }
    }
  }
}

/// The nearest byte at or before `stop` that begins a character, or `total`. A
/// UTF-8 continuation byte is one of the form `10xxxxxx`.
fn boundary(bits: BitArray, stop: Int, total: Int) -> Int {
  case stop >= total {
    True -> total
    False ->
      case bit_array.slice(bits, stop, 1) {
        Ok(<<byte>>) if byte >= 0x80 && byte < 0xC0 ->
          boundary(bits, stop - 1, total)
        Ok(_) | Error(Nil) -> stop
      }
  }
}
