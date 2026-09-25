//// Pure `Content-Length` framing for the Language Server Protocol's base
//// protocol, both directions.
////
//// # Why this is its own module, and why it works in bytes
////
//// A language server's stdout is a byte stream cut into frames by a
//// header section — `Content-Length: <n>\r\n`, optionally a
//// `Content-Type`, then a blank line — followed by exactly `n` bytes of
//// UTF-8 JSON. The length counts **bytes**, and the pipe (here, the
//// broker's `CallOutput` chunks, ADR-013 §1) cuts wherever it likes,
//// including between the bytes of one character. So unlike `mcp/stdio`,
//// which frames on newlines and can take `String` chunks, this framer must
//// take `BitArray` chunks: converting a chunk to text before the frame is
//// whole would either refuse a split character or miscount the length.
//// A body becomes a `String` only once all `n` of its bytes are in hand,
//// and it is refused then if it is not UTF-8.
////
//// # How a push stays cheap and bounded
////
//// The buffer is a two-state machine. While reading a header it holds at
//// most `max_header_bytes` plus the three bytes a split terminator can
//// leave behind, so re-scanning it costs a constant, and a peer that never
//// sends the blank line is refused at that bound. Once a header has named
//// a length, that length is checked against `max_frame_bytes` **before a
//// single body byte is buffered**, and body chunks are then kept unjoined,
//// newest first, with a running count: a push costs the chunk it carries,
//// never a re-copy of everything buffered before it, and the body is
//// joined exactly once, when it is complete.
////
//// Nothing here performs I/O or owns a process; the client actor (a later
//// slice) feeds chunks in as they arrive and gets whole bodies back. Every
//// fault is a value, and a faulted stream is not resumable — the caller
//// treats the transport as dead, because after a bad header there is no
//// way to find the next frame boundary.

import core/json.{type JsonValue}
import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// The largest body `push` will accept, in bytes: 16 MiB, the same cap
/// `mcp/stdio.max_line_bytes` and the cap channel's frame cap put on one
/// peer message, so one hostile message has one cost ceiling everywhere.
pub const max_frame_bytes = 16_777_216

/// The largest header section `push` will accept, in bytes, not counting
/// the blank line that ends it. A real header is one or two short lines;
/// 8 KiB leaves room for any legitimate `Content-Type` and bounds what a
/// peer that never sends the blank line can make us hold.
pub const max_header_bytes = 8192

/// Why framing refused the stream. Plain data; the owning actor decides
/// what a poisoned transport costs (ADR-013 §1: a broken stdout stream is
/// transport-fatal).
pub type FramingFault {
  /// The header section grew past `max_header_bytes` without its
  /// terminating blank line.
  HeaderTooLong(limit: Int)

  /// A header declared a body larger than `max_frame_bytes`. Refused when
  /// the header is parsed, before any of the body is buffered.
  FrameTooLong(limit: Int, declared: Int)

  /// A complete header section carried no `Content-Length`.
  MissingContentLength

  /// A header section carried `Content-Length` more than once. Two lengths
  /// are two opinions about where the next frame starts, and picking one
  /// would be a guess.
  DuplicateContentLength

  /// `Content-Length` was not a non-negative decimal integer. `value` is
  /// the text as received, whitespace trimmed.
  BadContentLength(value: String)

  /// A header line was not `Name: value`, or the header section was not
  /// text. `reason` names which.
  MalformedHeader(reason: String)

  /// A complete body was not valid UTF-8, which the protocol requires.
  BodyNotUtf8
}

/// The bytes between pushes. Opaque, because the two states and their
/// counters only mean anything together.
pub opaque type Buffer {
  /// Reading a header section. `head` holds every byte since the last
  /// frame ended, which is never more than `max_header_bytes + 3`: past
  /// that the header is refused, and a terminator split across pushes
  /// leaves at most three of its four bytes behind.
  ReadingHeader(head: BitArray)

  /// A header named `length` bytes of body and `have` of them have
  /// arrived, held as unjoined chunks, newest first.
  ReadingBody(length: Int, chunks: List(BitArray), have: Int)
}

/// An empty buffer: at a frame boundary, nothing pending.
///
/// ## Examples
///
/// ```gleam
/// assert framing.push(framing.new(), <<>>) == Ok(#(framing.new(), []))
/// ```
///
pub fn new() -> Buffer {
  ReadingHeader(head: <<>>)
}

/// Feeds one chunk into the buffer, returning the new buffer and every
/// body the chunk completed, in arrival order. A chunk may carry part of
/// a frame, exactly one, or several; bytes past the last complete frame
/// stay buffered for the next push.
///
/// Header names are matched case-insensitively, `Content-Type` and any
/// other well-formed header are tolerated and ignored, and whitespace
/// around a value is trimmed. Total and bounded: every refusal is a
/// `FramingFault`, and the buffer after a fault holds nothing recoverable.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(#(buffer, [])) = framing.push(framing.new(), <<"Content-Length: 2\r\n\r\n{":utf8>>)
/// assert framing.push(buffer, <<"}":utf8>>) == Ok(#(framing.new(), ["{}"]))
/// ```
///
pub fn push(
  buffer: Buffer,
  chunk: BitArray,
) -> Result(#(Buffer, List(String)), FramingFault) {
  use #(buffer, bodies) <- result.try(consume(buffer, chunk, []))
  Ok(#(buffer, list.reverse(bodies)))
}

// Drives the two-state machine over one chunk. Each completed frame hands
// the unconsumed remainder of the chunk back here in the header state, so
// a chunk carrying several frames is walked once, front to back. `done`
// collects completed bodies newest first.
fn consume(
  buffer: Buffer,
  chunk: BitArray,
  done: List(String),
) -> Result(#(Buffer, List(String)), FramingFault) {
  case buffer {
    ReadingHeader(head:) -> consume_header(head, chunk, done)
    ReadingBody(length:, chunks:, have:) ->
      consume_body(length, chunks, have, chunk, done)
  }
}

// Appends the chunk to the pending header bytes and looks for the blank
// line. The scan resumes three bytes before the old end, because that is
// as much of a terminator as the previous push could have left unmatched,
// and it never looks past `max_header_bytes`, so each push scans at most
// a constant number of bytes however large the chunk is.
fn consume_header(
  head: BitArray,
  chunk: BitArray,
  done: List(String),
) -> Result(#(Buffer, List(String)), FramingFault) {
  let data = bit_array.append(head, chunk)
  let from = int.max(bit_array.byte_size(head) - 3, 0)
  case find_terminator(data, from) {
    Ok(at) -> {
      use length <- result.try(parse_header(data, at))

      // The body begins after the four terminator bytes. The slice is a
      // sub-binary of `data`, not a copy.
      let body_start = at + 4
      let rest_size = bit_array.byte_size(data) - body_start
      let rest = slice_or_empty(data, body_start, rest_size)
      consume_body(length, [], 0, rest, done)
    }

    // No terminator yet. A header that cannot fit under the cap even if
    // the terminator arrived next is refused now rather than held.
    Error(Nil) ->
      case bit_array.byte_size(data) > max_header_bytes + 3 {
        True -> Error(HeaderTooLong(limit: max_header_bytes))
        False -> Ok(#(ReadingHeader(head: data), done))
      }
  }
}

// Finds the first `\r\n\r\n` starting at or after `at`, where the header
// before it would still fit under `max_header_bytes`. Returns the index of
// its first byte.
fn find_terminator(data: BitArray, at: Int) -> Result(Int, Nil) {
  case at > max_header_bytes {
    True -> Error(Nil)
    False ->
      case data {
        <<_:bytes-size(at), 13, 10, 13, 10, _:bits>> -> Ok(at)
        <<_:bytes-size(at), _, _:bits>> -> find_terminator(data, at + 1)
        _ -> Error(Nil)
      }
  }
}

// Adds a chunk to a body in progress. While the body is short, the chunk
// is only consed on; once it is complete, the body is joined once, decoded
// once, and whatever the chunk carried past it starts the next header.
fn consume_body(
  length: Int,
  chunks: List(BitArray),
  have: Int,
  chunk: BitArray,
  done: List(String),
) -> Result(#(Buffer, List(String)), FramingFault) {
  let size = bit_array.byte_size(chunk)
  case have + size < length {
    True ->
      Ok(#(
        ReadingBody(length:, chunks: [chunk, ..chunks], have: have + size),
        done,
      ))
    False -> {
      let needed = length - have
      let tail = slice_or_empty(chunk, 0, needed)
      let rest = slice_or_empty(chunk, needed, size - needed)
      let body = bit_array.concat(list.reverse([tail, ..chunks]))
      use text <- result.try(
        bit_array.to_string(body) |> result.replace_error(BodyNotUtf8),
      )

      // An empty remainder ends the walk at a clean frame boundary; any
      // other remainder is the start of the next frame's header.
      case rest {
        <<>> -> Ok(#(new(), [text, ..done]))
        rest -> consume_header(<<>>, rest, [text, ..done])
      }
    }
  }
}

// `bit_array.slice` is total only over in-range arguments; every caller
// here computes its range from the same array's size, so the fallback is
// unreachable, and an empty slice is the honest reading if it ever were.
fn slice_or_empty(bits: BitArray, from: Int, length: Int) -> BitArray {
  case bit_array.slice(bits, from, length) {
    Ok(slice) -> slice
    Error(Nil) -> <<>>
  }
}

// Parses the header section `data[0, at)` into the body length. The
// section must be text; each line must be `Name: value`; exactly one of
// them must be `Content-Length`, and its value must fit under the frame
// cap. Everything else well-formed is tolerated, which is the base
// protocol's own posture towards `Content-Type`.
fn parse_header(data: BitArray, at: Int) -> Result(Int, FramingFault) {
  use section <- result.try(
    slice_or_empty(data, 0, at)
    |> bit_array.to_string
    |> result.replace_error(MalformedHeader(reason: "header is not text")),
  )
  use lengths <- result.try(
    string.split(section, "\r\n")
    |> list.try_fold([], fn(lengths, line) {
      use #(name, value) <- result.try(split_header_line(line))
      case string.lowercase(name) {
        "content-length" -> Ok([value, ..lengths])
        _ -> Ok(lengths)
      }
    }),
  )
  case lengths {
    [] -> Error(MissingContentLength)
    [value] -> parse_length(value)
    [_, _, ..] -> Error(DuplicateContentLength)
  }
}

fn split_header_line(line: String) -> Result(#(String, String), FramingFault) {
  case string.split_once(line, ":") {
    Ok(#(name, value)) ->
      case string.trim(name) == name && name != "" {
        True -> Ok(#(name, string.trim(value)))
        False -> Error(MalformedHeader(reason: "bad header name: " <> line))
      }
    Error(Nil) -> Error(MalformedHeader(reason: "not a header line: " <> line))
  }
}

// Digits only. `int.parse` would also take a sign, and a signed length is
// not a length; the cap is checked here, before the caller buffers a byte
// of body.
fn parse_length(value: String) -> Result(Int, FramingFault) {
  let digits = string.to_graphemes(value)
  let all_digits =
    digits != []
    && list.all(digits, fn(digit) { string.contains("0123456789", digit) })
  use <- bool.guard(when: !all_digits, return: Error(BadContentLength(value:)))
  case int.parse(value) {
    Error(Nil) -> Error(BadContentLength(value:))
    Ok(length) ->
      case length > max_frame_bytes {
        True -> Error(FrameTooLong(limit: max_frame_bytes, declared: length))
        False -> Ok(length)
      }
  }
}

/// Renders one message as a wire frame: `Content-Length` counting the
/// body's UTF-8 bytes, the blank line, then compact JSON.
///
/// ## Examples
///
/// ```gleam
/// assert framing.frame(json.Object([#("é", json.Int(1))]))
///   == "Content-Length: 8\r\n\r\n{\"é\":1}"
/// ```
///
pub fn frame(message: JsonValue) -> String {
  let body = json.to_string(message)
  "Content-Length: "
  <> int.to_string(string.byte_size(body))
  <> "\r\n\r\n"
  <> body
}
