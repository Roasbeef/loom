//// What a running session reports of one timeline span, for Home's cards
//// (protocol-change/134): the resident side of the `sessions.span` read.
////
//// A card names a span by the sequences of its first and last records and the id
//// of its last. The read scans down the strand's parent links from that record
//// for at most the span's length, keeps the records from `from_seq` on, and
//// answers the lines `session_view/span_lines` makes of them. It runs no tool,
//// opens no other session and writes nothing, and a record id that is not this
//// session's is an unknown one.
////
//// ## How a read runs
////
//// 1. `read` answers `build`'s lines as the reply object.
//// 2. `window` scans from the named record, at most `max_records` records, and
////    stops at the span's first sequence.
//// 3. `span_lines.of_records` makes the bounded lines and counts the rest.
////
//// ## What it claims
////
//// The lines are what the records say, worded as the session's page words them.
//// Their text is session text, marked untrusted for the page
//// (`web_view/span_feed`).

import core/entry.{type Entry}
import core/ids
import core/json.{type JsonValue}
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import runtime/api
import session_view/span_lines
import storage/storage
import web_view/span_feed

/// The most records one span read scans.
pub const max_records = 5000

/// The lines of the span ending at the record `last`, which begins at sequence
/// `from_seq` and ends at `to_seq`, as one reply object `{"span": {...}}`.
///
/// ## Examples
///
/// ```gleam
/// // span_read.read(runtime, "0198...", 12, 40)
/// ```
pub fn read(
  runtime: api.Runtime,
  last: String,
  from_seq: Int,
  to_seq: Int,
) -> Result(JsonValue, String) {
  build(runtime, last, from_seq, to_seq) |> result.map(span_feed.to_json)
}

/// The lines of a span as a typed value, before it is encoded.
///
/// ## Examples
///
/// ```gleam
/// // span_read.build(runtime, "0198...", 12, 40)
/// ```
pub fn build(
  runtime: api.Runtime,
  last: String,
  from_seq: Int,
  to_seq: Int,
) -> Result(span_feed.Feed, String) {
  use records <- result.map(window(runtime, last, from_seq, to_seq))
  let #(lines, omitted) = span_lines.of_records(records)

  span_feed.of_lines(lines, omitted)
}

/// The records of a span, oldest first, scanned down from its last record.
fn window(
  runtime: api.Runtime,
  last: String,
  from_seq: Int,
  to_seq: Int,
) -> Result(List(Entry), String) {
  use id <- result.try(
    ids.parse_entry_id(last)
    |> result.replace_error("not a record of this session"),
  )

  storage.scan_branch(
    runtime.session.store,
    storage.branch_scan(id)
      |> storage.branch_limit(int.min(max_records, to_seq - from_seq + 1)),
  )
  |> result.map(fn(newest_first) {
    list.take_while(newest_first, fn(record) { record.seq >= from_seq })
    |> list.reverse
  })
  |> result.map_error(string.inspect)
}
