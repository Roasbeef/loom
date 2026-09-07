//// A bounded rolling tail over one output stream, with a monotone byte
//// cursor: what a background job has printed lately, and what a reader
//// who last looked at cursor *n* has missed since.
////
//// ## Why this is not `blob` and not a list of chunks
////
//// Every existing consumer of the broker's `CallOutput` stream folds
//// every chunk into a list and emits nothing until the call settles
//// (`tools/tool.collect_events`), because every existing consumer is a
//// foreground tool call that has nothing to say until then. A background
//// job is the first consumer that has to answer "what has it printed
//// since I last looked" while the process is still running, and answer it
//// many times, from a process that must not grow without bound in the
//// meantime. Neither shape fits: an unbounded list is the memory leak a
//// `tail -f` held for a session would become, and `blob.bound` is
//// one-shot and content-addressed over a *complete* body, which a running
//// job does not have.
////
//// So the window is bounded and the stream position is not. `push` drops
//// from the front once the window is full; `since` answers with the bytes
//// after a cursor and the new cursor to ask with next time. A cursor that
//// predates the retained window is not an error and is not silently
//// rounded up: the reply says how many bytes fell out between the cursor
//// and the window, so a caller learns it missed output rather than
//// believing it saw everything.
////
//// ## The cursor is a stream position, not an index into the window
////
//// Cursors count bytes from the start of the stream and never go
//// backwards, which is what makes them comparable across polls of a job
//// whose window has rolled many times over. The window's own contents are
//// an implementation detail: `dropped` is the only thing that tells a
//// caller the two have drifted apart.
////
//// ## UTF-8
////
//// A jailed stream is expected to be UTF-8, and both edges of the window
//// respect that. The front is advanced past any continuation byte a trim
//// cut through, so the retained window never begins mid-character. The
//// slice `since` hands back stops at the last *complete* character, and
//// the bytes it holds back are handed to the next poll rather than
//// dropped — so consecutive slices concatenate to the exact stream and
//// each one decodes on its own. Output that is not UTF-8 at all is passed
//// through verbatim after a bounded three-byte backoff, because a tail
//// that held bytes back forever waiting for a character boundary that is
//// never coming would be worse than one that hands over what it has.
////
//// This module holds no process and performs no I/O. The runner that owns
//// one of these per stream is `client/jobs`.

import gleam/bit_array
import gleam/bool
import gleam/int

/// One stream's rolling window.
///
/// Constructor invariants, all maintained by `push` and relied on by
/// `since`: `capacity` is at least one byte; `received` is the total
/// number of bytes ever pushed and never decreases; `dropped` is how many
/// of those have fallen out of the front of the window and never
/// decreases; and `received - dropped` is exactly the size of `window`,
/// which is what lets a stream position be turned into an offset into the
/// window by subtraction alone.
pub opaque type Tail {
  Tail(capacity: Int, window: BitArray, dropped: Int, received: Int)
}

/// What a reader at some cursor has missed and what to ask with next.
///
/// A record rather than a bare tuple because all three fields are integers
/// or bytes with no natural order between them, and a caller that got
/// `dropped` and `cursor` the wrong way round would silently report a
/// healthy stream as a lossy one.
pub type Since {
  Since(
    /// The bytes that arrived after the cursor and are still retained,
    /// ending at a UTF-8 character boundary.
    bytes: BitArray,
    /// The stream position to ask with next time. Always at or after the
    /// cursor that was asked with.
    cursor: Int,
    /// How many bytes arrived after the cursor and fell out of the window
    /// before this call. Zero for a reader that is keeping up.
    dropped: Int,
  )
}

/// How many bytes past the end of a window a trim will walk looking for a
/// UTF-8 character boundary, and how far back `since` will step to end its
/// slice on one. Three, because that is the longest run of continuation
/// bytes a single character can have.
const utf8_backoff = 3

/// An empty tail retaining at most `capacity` bytes.
///
/// A capacity below one byte is raised to one rather than refused: the
/// number is a bound on memory, and a caller that computes a silly one
/// wants a tiny window, not a crash inside a job's output loop.
///
/// ## Examples
///
/// ```gleam
/// assert jobtail.received(jobtail.new(capacity: 8)) == 0
/// ```
///
/// ```gleam
/// assert jobtail.since(jobtail.new(capacity: 8), 0)
///   == jobtail.Since(bytes: <<>>, cursor: 0, dropped: 0)
/// ```
///
pub fn new(capacity capacity: Int) -> Tail {
  Tail(capacity: int.max(capacity, 1), window: <<>>, dropped: 0, received: 0)
}

/// How many bytes this stream has carried in total. The cursor a reader
/// that has seen everything holds.
///
/// ## Examples
///
/// ```gleam
/// let tail = jobtail.push(jobtail.new(capacity: 2), <<"abcd":utf8>>)
/// assert jobtail.received(tail) == 4
/// ```
///
pub fn received(tail: Tail) -> Int {
  tail.received
}

/// Appends one chunk, dropping from the front of the window whatever no
/// longer fits.
///
/// ## Examples
///
/// ```gleam
/// let tail = jobtail.push(jobtail.new(capacity: 4), <<"hello":utf8>>)
/// assert jobtail.since(tail, 0).dropped == 1
/// ```
///
/// ```gleam
/// let tail = jobtail.push(jobtail.new(capacity: 16), <<"hi":utf8>>)
/// assert jobtail.since(tail, 0).bytes == <<"hi":utf8>>
/// ```
///
pub fn push(tail: Tail, chunk: BitArray) -> Tail {
  let window = bit_array.append(tail.window, chunk)
  let received = tail.received + bit_array.byte_size(chunk)
  trim(Tail(..tail, window:, received:))
}

// Bring the window back inside its capacity, cutting on a character
// boundary.
//
// The cut is computed against the capacity first and then walked forward
// past any continuation byte it landed on, so the window never begins in
// the middle of a character and a reader rendering it as text never sees a
// leading replacement character. Walking forward rather than back is what
// keeps the window inside its bound: stepping back to the previous
// boundary would retain more than `capacity` bytes.
fn trim(tail: Tail) -> Tail {
  let size = bit_array.byte_size(tail.window)
  use <- bool.guard(when: size <= tail.capacity, return: tail)
  let cut = boundary_at(tail.window, size - tail.capacity, utf8_backoff)
  case bit_array.slice(tail.window, cut, size - cut) {
    Ok(window) -> Tail(..tail, window:, dropped: tail.dropped + cut)

    // Unreachable: `cut` is between zero and `size` by construction, so
    // the slice is in range. The arm exists because `slice` is total and
    // an empty window with the dropped count moved on is the answer that
    // keeps the record's invariant true rather than one that breaks it.
    Error(Nil) -> Tail(..tail, window: <<>>, dropped: tail.received)
  }
}

/// What arrived after `cursor`, where to carry on from, and how much fell
/// out of the window in between.
///
/// A cursor before the retained window is answered with everything the
/// window still holds and a `dropped` count for the gap; a cursor at or
/// past the end of the stream is answered with no bytes and itself. A
/// cursor outside the stream entirely — negative, or ahead of what has
/// been received — is clamped rather than refused, because it can only
/// come from a caller that has confused two streams and the useful answer
/// is the one that puts it back on the rails.
///
/// ## Examples
///
/// ```gleam
/// let tail = jobtail.push(jobtail.new(capacity: 16), <<"abc":utf8>>)
/// assert jobtail.since(tail, 1)
///   == jobtail.Since(bytes: <<"bc":utf8>>, cursor: 3, dropped: 0)
/// ```
///
/// ```gleam
/// let tail = jobtail.push(jobtail.new(capacity: 2), <<"abcd":utf8>>)
/// assert jobtail.since(tail, 0).dropped == 2
/// ```
///
pub fn since(tail: Tail, cursor: Int) -> Since {
  let asked = int.clamp(cursor, min: 0, max: tail.received)

  // Nothing before the window survives, so a reader that fell behind
  // resumes at the window's front and is told how far it fell.
  let from = int.max(asked, tail.dropped)
  let kept = complete_prefix(window_from(tail, from))
  Since(
    bytes: kept,
    cursor: from + bit_array.byte_size(kept),
    dropped: from - asked,
  )
}

// The retained bytes from stream position `from` onward.
//
// The record's invariant — `received - dropped` is the window's size — is
// what makes this subtraction and no bounds arithmetic: `from` is at or
// after `dropped` and at or before `received` by the two clamps above.
fn window_from(tail: Tail, from: Int) -> BitArray {
  let offset = from - tail.dropped
  case bit_array.slice(tail.window, offset, tail.received - from) {
    Ok(bytes) -> bytes

    // Unreachable while the invariant holds; an empty answer is the one
    // that cannot invent bytes the stream never carried.
    Error(Nil) -> <<>>
  }
}

// `bytes` with any *incomplete* final character held back.
//
// Holding back is the load-bearing half. A slice ending mid-character is
// the ordinary case — the helper chunks on 32 KiB boundaries, not on
// character boundaries — and keeping those bytes until the next chunk
// completes them is what makes each slice decodable on its own and what
// makes consecutive slices concatenate to the exact stream.
//
// What it must never do is hold bytes back forever. "Ends
// mid-character" and "is not UTF-8 at all" look identical to a decoder
// asked about the whole slice, so the question is asked of the last
// character's *lead byte* instead: a lead byte whose character does not
// fit in what is left is incomplete and waits, and a byte that leads no
// character at all is binary output and goes out as it is. A stream of
// 0xFF would otherwise answer every poll with nothing, forever.
fn complete_prefix(bytes: BitArray) -> BitArray {
  let size = bit_array.byte_size(bytes)
  let keep = complete_length(bytes, size, size - 1, utf8_backoff)
  case bit_array.slice(bytes, 0, keep) {
    Ok(prefix) -> prefix

    // Unreachable: `keep` is between zero and `size`. Handing back
    // everything is the answer that cannot lose bytes the caller will
    // never be offered again.
    Error(Nil) -> bytes
  }
}

// How much of `bytes` ends on a complete character, walking back from
// `at` over at most `budget` continuation bytes to find the last lead.
fn complete_length(bytes: BitArray, size: Int, at: Int, budget: Int) -> Int {
  use <- bool.guard(when: at < 0 || budget < 0, return: size)
  case byte_at(bytes, at) {
    Error(Nil) -> size

    Ok(byte) ->
      case is_continuation(byte) {
        // Still inside a character; its lead byte is further back.
        True -> complete_length(bytes, size, at - 1, budget - 1)

        False ->
          case character_width(byte) {
            // A byte that leads no character. The stream is not UTF-8
            // here, so there is no boundary to wait for.
            Error(Nil) -> size

            Ok(width) ->
              case at + width <= size {
                True -> size
                False -> at
              }
          }
      }
  }
}

// How many bytes the character beginning with `lead` occupies, or
// `Error(Nil)` for a byte that begins none — a continuation byte, an
// overlong two-byte lead, or one of the five values UTF-8 never uses.
fn character_width(lead: Int) -> Result(Int, Nil) {
  case lead {
    _ascii if lead < 0x80 -> Ok(1)
    _two if lead >= 0xC2 && lead <= 0xDF -> Ok(2)
    _three if lead >= 0xE0 && lead <= 0xEF -> Ok(3)
    _four if lead >= 0xF0 && lead <= 0xF4 -> Ok(4)
    _leads_nothing -> Error(Nil)
  }
}

// A UTF-8 continuation byte is `10xxxxxx`, so anything in `0x80..0xBF` is
// the middle of a character rather than the start of one.
fn is_continuation(byte: Int) -> Bool {
  byte >= 0x80 && byte < 0xC0
}

// The first character boundary at or after `from`, walking at most
// `budget` bytes forward.
//
// Running out of budget means the bytes are not UTF-8 at all, and the
// offer stands where it was: this walk exists to make text read cleanly,
// not to refuse binary output.
fn boundary_at(bytes: BitArray, from: Int, budget: Int) -> Int {
  use <- bool.guard(when: budget <= 0, return: from)
  case byte_at(bytes, from) {
    Error(Nil) -> from

    Ok(byte) ->
      case is_continuation(byte) {
        True -> boundary_at(bytes, from + 1, budget - 1)
        False -> from
      }
  }
}

fn byte_at(bytes: BitArray, index: Int) -> Result(Int, Nil) {
  case bit_array.slice(bytes, index, 1) {
    Ok(<<value:size(8)>>) -> Ok(value)
    Ok(<<_shorter:bits>>) -> Error(Nil)
    Error(Nil) -> Error(Nil)
  }
}
