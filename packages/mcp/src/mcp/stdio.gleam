//// Pure line framing for the MCP stdio transport.
////
//// The stdio transport is newline-delimited JSON: one message per line,
//// and a message must not contain a literal newline (`core/json` escapes
//// every control character inside strings, so `frame`'s output cannot).
//// This module owns both directions of that framing and nothing else —
//// no ports, no processes; the client actor that owns the pipe feeds
//// chunks in as they arrive and gets complete lines back.
////
//// Chunks are taken as `String`: the BEAM port delivers binaries, and
//// the actor slice converts at its own boundary, keeping this package
//// free of bit-array plumbing it would never inspect.
////
//// The buffer is bounded. A peer that never sends a newline would
//// otherwise grow the pending line without limit, so any line — pending
//// or complete — larger than `max_line_bytes` settles as a
//// `FramingFault` value instead. The cap matches the cap channel's
//// frame cap (16 MiB): both bound what one hostile peer message may
//// cost the harness.

import core/json.{type JsonValue}
import gleam/bool
import gleam/list
import gleam/result
import gleam/string

/// The largest line `push` will accumulate or emit, in bytes: 16 MiB,
/// matching the cap channel's frame cap. A line past this is a
/// `FramingFault`, whether or not its newline has arrived yet.
pub const max_line_bytes = 16_777_216

/// Why framing refused input. Plain data; the owning actor decides what
/// a poisoned connection costs.
pub type FramingFault {
  /// A line exceeded `max_line_bytes`. `limit` restates the cap; `seen`
  /// is the byte count that breached it (for the pending line, the bytes
  /// buffered so far — the true line is at least that long).
  LineTooLong(limit: Int, seen: Int)
}

/// The accumulated partial line between pushes. Chunks are kept unjoined,
/// newest first, with a running byte count, so a push costs the chunk it
/// carries — never a re-copy of everything buffered before it — and the
/// cap check is one comparison rather than a walk.
pub opaque type Buffer {
  Buffer(pending: List(String), pending_bytes: Int)
}

/// An empty buffer: no partial line pending.
///
/// ## Examples
///
/// ```gleam
/// assert stdio.push(stdio.new(), "") == Ok(#(stdio.new(), []))
/// ```
///
pub fn new() -> Buffer {
  Buffer(pending: [], pending_bytes: 0)
}

/// Feeds one chunk into the buffer, returning the new buffer and every
/// line the chunk completed, in arrival order. Lines are split on `\n`;
/// a trailing `\r` is trimmed from each completed line, so `\r\n` peers
/// work unchanged. Bytes after the last newline stay pending until a
/// later push completes them.
///
/// Total and bounded: a completed line larger than `max_line_bytes`, or
/// a pending line grown past it, is a `LineTooLong` fault. A faulted
/// buffer holds nothing recoverable — the caller drops the connection
/// rather than resuming mid-line.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(#(buffer, [])) = stdio.push(stdio.new(), "{\"a\":")
/// assert stdio.push(buffer, "1}\n") == Ok(#(stdio.new(), ["{\"a\":1}"]))
/// ```
///
pub fn push(
  buffer: Buffer,
  chunk: String,
) -> Result(#(Buffer, List(String)), FramingFault) {
  use <- bool.guard(when: chunk == "", return: Ok(#(buffer, [])))
  case string.split(chunk, "\n") {
    // No newline: the whole chunk joins the pending line.
    [only] -> {
      let pending_bytes = buffer.pending_bytes + string.byte_size(only)
      use Nil <- result.try(check_line(pending_bytes))
      Ok(#(Buffer(pending: [only, ..buffer.pending], pending_bytes:), []))
    }

    // At least one newline: the first part completes the pending line,
    // middle parts are whole lines of their own, and the part after the
    // last newline starts the next pending line.
    [first, ..completed_and_rest] -> {
      let #(rest, completed) = split_last(completed_and_rest)
      let first_line_bytes = buffer.pending_bytes + string.byte_size(first)
      use Nil <- result.try(check_line(first_line_bytes))
      let first_line = string.concat(list.reverse([first, ..buffer.pending]))
      use middle <- result.try(list.try_map(completed, checked_line))
      let lines = [trim_carriage_return(first_line), ..middle]
      let pending_bytes = string.byte_size(rest)
      use Nil <- result.try(check_line(pending_bytes))
      let pending = case rest {
        "" -> []
        rest -> [rest]
      }
      Ok(#(Buffer(pending:, pending_bytes:), lines))
    }

    // `string.split` never returns an empty list, but the decoder is
    // total rather than trusting that: an impossible shape reads as an
    // empty push, not a crash.
    [] -> Ok(#(buffer, []))
  }
}

// Separates the final element (the new pending remainder) from the
// completed lines before it. The input is the tail of a non-empty split,
// so it has at least one element; the empty case is unreachable but
// settles totally as "nothing pending, nothing completed".
fn split_last(parts: List(String)) -> #(String, List(String)) {
  case list.reverse(parts) {
    [last, ..completed_reversed] -> #(last, list.reverse(completed_reversed))
    [] -> #("", [])
  }
}

fn checked_line(line: String) -> Result(String, FramingFault) {
  use Nil <- result.try(check_line(string.byte_size(line)))
  Ok(trim_carriage_return(line))
}

fn check_line(bytes: Int) -> Result(Nil, FramingFault) {
  case bytes <= max_line_bytes {
    True -> Ok(Nil)
    False -> Error(LineTooLong(limit: max_line_bytes, seen: bytes))
  }
}

// Tolerates `\r\n` framing by trimming one trailing `\r`; a carriage
// return anywhere else in the line is content and survives.
fn trim_carriage_return(line: String) -> String {
  case string.ends_with(line, "\r") {
    True -> string.drop_end(line, 1)
    False -> line
  }
}

/// Renders one message as a wire frame: compact single-line JSON plus the
/// terminating newline. `core/json.to_string` escapes every control
/// character inside strings, so the body can never contain a literal
/// newline whatever the message carries.
///
/// ## Examples
///
/// ```gleam
/// assert stdio.frame(json.Object([#("a", json.String("x\ny"))]))
///   == "{\"a\":\"x\\ny\"}\n"
/// ```
///
pub fn frame(message: JsonValue) -> String {
  json.to_string(message) <> "\n"
}
