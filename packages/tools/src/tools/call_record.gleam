//// The per-call record of a code-mode execution: which capabilities a
//// program called, in what order, how each ended, and when (protocol
//// change 060).
////
//// ## Who writes it, and why that matters
////
//// The satellite host actor owns this record, not the satellite. The host
//// is the trusted, harness-side end of the capability channel: it already
//// authenticates every `cap_call`, routes it, admits or refuses it and
//// settles it, so it can describe each call from what it decided and what
//// its own clock read. The program's terminal `outcome` frame is never
//// consulted, which is Rule Zero applied to a display field: a program
//// cannot write, edit or suppress what a client shows about it.
////
//// Only two things come from the program, the capability name and the
//// arguments of an authenticated call, and both are reduced before they
//// are kept. The name is sanitised to a short closed alphabet. The
//// arguments are never kept at all: `summarise` reads an allowlisted
//// handful of fields (a path, a key, an executable) and everything else a
//// call carries, file bodies, `stdin`, environment, tokens and the tail of
//// an `argv`, is not read. A capability the allowlist does not name has no
//// summary, which is the default for MCP and extension capabilities whose
//// argument shapes the host does not know.
////
//// ## Bounded whatever the program does
////
//// A `Ledger` retains the first `max_records` calls and counts every call
//// exactly, so a program that makes five thousand calls costs the host
//// 128 records and four integers. Each summary is cut to
//// `max_summary_bytes` on a UTF-8 boundary with the cut marked, and
//// control characters are removed before the cut so a client may draw the
//// text without worrying about terminal escape sequences.
////
//// ## Time
////
//// Every instant is the host's injected wall clock in Unix milliseconds,
//// never the monotonic clock, which is negative on the BEAM and must not
//// reach a wire. The log carries one absolute instant and every call
//// carries offsets from it, clamped at zero because a wall clock can step
//// backwards.
////
//// This module is pure. The host threads a `Ledger` through its state; the
//// tool result carries the finished `CallLog` as JSON.

import core/json.{type JsonValue}
import core/msgpack.{type MsgPackValue}
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// How many calls a log itemises. Calls past it are counted and not
/// listed, so memory and result size are bounded whatever a program does.
pub const max_records = 128

/// The byte budget of one argument summary, truncation marker included.
pub const max_summary_bytes = 96

/// The byte budget of a capability name.
pub const max_cap_bytes = 64

/// The byte budget of an error code.
pub const max_error_bytes = 48

// The mark a cut summary ends with: U+2026, three bytes in UTF-8.
const ellipsis = "…"

/// How one call ended, as the host saw it.
pub type CallStatus {
  /// The settlement was a success.
  CallOk

  /// The settlement was an error, or the host refused the call before
  /// dispatching it.
  CallFailed

  /// The satellite cancelled the call before it settled.
  CallCancelled

  /// The call was still in flight when the execution ended.
  CallUnsettled
}

/// One capability call.
pub type CallRecord {
  CallRecord(
    /// The capability name, sanitised and bounded.
    cap: String,
    /// A redacted summary of the arguments, or `None`.
    args: Option(String),
    /// How the call ended.
    status: CallStatus,
    /// The `CapErr` code, never its message.
    error: Option(String),
    /// Milliseconds from the execution's start to the call's admission.
    start_ms: Int,
    /// Milliseconds from the call's start to its end, never negative.
    duration_ms: Int,
  )
}

/// The settled record of one execution.
///
/// `items` holds the first `max_records` calls in admission order, and
/// `total - length(items)` is the number not itemised. The counters are
/// exact for every call, itemised or not.
pub type CallLog {
  CallLog(
    /// The execution's own zero, in Unix milliseconds.
    started_unix_ms: Int,
    /// Execution start to settlement, in milliseconds.
    elapsed_ms: Int,
    /// Every call the execution made.
    total: Int,
    /// Calls that ended in an error or were refused.
    failed: Int,
    /// Calls the satellite cancelled.
    cancelled: Int,
    /// Calls still in flight when the execution ended.
    unsettled: Int,
    /// The itemised calls.
    items: List(CallRecord),
  )
}

/// The log of an execution that made no calls, or that never got far
/// enough to have any: vet and compile failures, and a run that never
/// launched.
pub fn empty() -> CallLog {
  CallLog(
    started_unix_ms: 0,
    elapsed_ms: 0,
    total: 0,
    failed: 0,
    cancelled: 0,
    unsettled: 0,
    items: [],
  )
}

/// The host's working record while an execution runs. Opaque so that the
/// bounds and the counters are maintained in one place.
pub opaque type Ledger {
  Ledger(
    started_unix_ms: Int,
    total: Int,
    failed: Int,
    cancelled: Int,
    unsettled: Int,
    records: Dict(Int, CallRecord),
  )
}

/// Starts a ledger whose zero is `started_unix_ms`.
///
/// ## Examples
///
/// ```gleam
/// let ledger = call_record.start(1_790_000_000_000)
/// ```
///
pub fn start(started_unix_ms: Int) -> Ledger {
  Ledger(
    started_unix_ms:,
    total: 0,
    failed: 0,
    cancelled: 0,
    unsettled: 0,
    records: dict.new(),
  )
}

/// Records a call admitted at `now` (Unix milliseconds) and returns the
/// ledger with the call's sequence number, which `settle` and `finish`
/// take back. The call is held as unsettled until one of them closes it.
///
/// ## Examples
///
/// ```gleam
/// let #(ledger, seq) =
///   call_record.admit(ledger, "fs.read", msgpack.NilValue, 1_790_000_000_012)
/// ```
///
pub fn admit(
  ledger: Ledger,
  cap: String,
  args: MsgPackValue,
  now: Int,
) -> #(Ledger, Int) {
  let seq = ledger.total
  let record =
    CallRecord(
      cap: clean_code(cap, max_cap_bytes),
      args: summarise(cap, args),
      status: CallUnsettled,
      error: None,
      start_ms: offset(ledger, now),
      duration_ms: 0,
    )
  #(
    Ledger(
      ..ledger,
      total: seq + 1,
      records: retain(ledger.records, seq, record),
    ),
    seq,
  )
}

/// Records a call the host refused before dispatching it: it failed under
/// `code` and took no time.
pub fn refuse(
  ledger: Ledger,
  cap: String,
  args: MsgPackValue,
  code: String,
  now: Int,
) -> Ledger {
  let #(ledger, seq) = admit(ledger, cap, args, now)
  settle(ledger, seq, CallFailed, Some(code), now)
}

/// Closes call `seq` at `now` with the status the host decided and the
/// `CapErr` code when there was one. A call that is not retained is still
/// counted.
pub fn settle(
  ledger: Ledger,
  seq: Int,
  status: CallStatus,
  error: Option(String),
  now: Int,
) -> Ledger {
  let counted = case status {
    CallOk -> ledger
    CallFailed -> Ledger(..ledger, failed: ledger.failed + 1)
    CallCancelled -> Ledger(..ledger, cancelled: ledger.cancelled + 1)
    CallUnsettled -> Ledger(..ledger, unsettled: ledger.unsettled + 1)
  }
  let records = case dict.get(ledger.records, seq) {
    Error(Nil) -> ledger.records
    Ok(record) ->
      dict.insert(
        ledger.records,
        seq,
        CallRecord(
          ..record,
          status:,
          error: option.map(error, clean_code(_, max_error_bytes)),
          duration_ms: int.max(offset(ledger, now) - record.start_ms, 0),
        ),
      )
  }
  Ledger(..counted, records:)
}

/// Ends the execution at `now`. Every call in `open` (the sequence numbers
/// the host still holds in flight) is closed as unsettled, and the
/// finished log is returned.
pub fn finish(ledger: Ledger, open: List(Int), now: Int) -> CallLog {
  let closed =
    list.fold(open, ledger, fn(ledger, seq) {
      settle(ledger, seq, CallUnsettled, None, now)
    })
  let items =
    dict.to_list(closed.records)
    |> list.sort(fn(left, right) { int.compare(left.0, right.0) })
    |> list.map(fn(entry) { entry.1 })
  CallLog(
    started_unix_ms: closed.started_unix_ms,
    elapsed_ms: int.max(offset(closed, now), 0),
    total: closed.total,
    failed: closed.failed,
    cancelled: closed.cancelled,
    unsettled: closed.unsettled,
    items:,
  )
}

// Keeps a record only while the log still has room for it.
fn retain(
  records: Dict(Int, CallRecord),
  seq: Int,
  record: CallRecord,
) -> Dict(Int, CallRecord) {
  case seq < max_records {
    True -> dict.insert(records, seq, record)
    False -> records
  }
}

// Milliseconds since the execution's zero, never negative.
fn offset(ledger: Ledger, now: Int) -> Int {
  int.max(now - ledger.started_unix_ms, 0)
}

// --- the wire shape -------------------------------------------------------

/// Encodes a log as the `calls` value of a `code_mode` result's `details`.
///
/// `args` and `error` are omitted when absent. Position in `items` is
/// admission order, so it is not a field.
///
/// ## Examples
///
/// ```gleam
/// let details = call_record.to_json(call_record.empty())
/// ```
///
pub fn to_json(log: CallLog) -> JsonValue {
  json.Object([
    #("started_unix_ms", json.Int(log.started_unix_ms)),
    #("elapsed_ms", json.Int(log.elapsed_ms)),
    #("total", json.Int(log.total)),
    #("failed", json.Int(log.failed)),
    #("cancelled", json.Int(log.cancelled)),
    #("unsettled", json.Int(log.unsettled)),
    #("items", json.Array(list.map(log.items, record_json))),
  ])
}

fn record_json(record: CallRecord) -> JsonValue {
  let optional = fn(key: String, value: Option(String)) {
    case value {
      Some(text) -> [#(key, json.String(text))]
      None -> []
    }
  }
  json.Object(
    list.flatten([
      [#("cap", json.String(record.cap))],
      optional("args", record.args),
      [#("status", json.String(status_text(record.status)))],
      optional("error", record.error),
      [
        #("start_ms", json.Int(record.start_ms)),
        #("duration_ms", json.Int(record.duration_ms)),
      ],
    ]),
  )
}

/// The wire word for a status.
pub fn status_text(status: CallStatus) -> String {
  case status {
    CallOk -> "ok"
    CallFailed -> "failed"
    CallCancelled -> "cancelled"
    CallUnsettled -> "unsettled"
  }
}

// --- sanitising and redaction ----------------------------------------------

// Reduces a program-chosen or host-chosen token to `[a-z0-9_.]`, one
// replacement character per offending character, cut to `limit` bytes.
// Every kept character is one byte, so counting characters is counting
// bytes.
fn clean_code(text: String, limit: Int) -> String {
  string.to_utf_codepoints(text)
  |> list.take(limit)
  |> list.map(fn(codepoint) {
    case code_character(string.utf_codepoint_to_int(codepoint)) {
      True -> string.from_utf_codepoints([codepoint])
      False -> "_"
    }
  })
  |> string.concat
}

fn code_character(code: Int) -> Bool {
  { code >= 0x61 && code <= 0x7A }
  || { code >= 0x30 && code <= 0x39 }
  || code == 0x5F
  || code == 0x2E
}

/// The redacted summary of one call's arguments, or `None`.
///
/// An allowlist keyed on capability name; see the module doc for why it is
/// default-deny. A call whose arguments lack the expected key, or carry it
/// as the wrong type, has no summary.
///
/// | Capability | Summary |
/// |---|---|
/// | `fs.read`, `fs.write`, `fs.edit`, `fs.list` | the `path` |
/// | `kv.get`, `kv.set`, `kv.delete` | the `key` |
/// | `job.poll`, `job.kill`, `job.send` | the `job_id` |
/// | `job.start` | the first whitespace token of `command` |
/// | `proc.run` | the executable's basename and the argument count |
///
/// ## Examples
///
/// ```gleam
/// let args = msgpack.MapValue([#(msgpack.StringValue("path"), msgpack.StringValue("a.txt"))])
/// assert call_record.summarise("fs.read", args) == Some("a.txt")
/// ```
///
pub fn summarise(cap: String, args: MsgPackValue) -> Option(String) {
  let summary = case cap {
    "fs.read" | "fs.write" | "fs.edit" | "fs.list" -> text_field(args, "path")
    "kv.get" | "kv.set" | "kv.delete" -> text_field(args, "key")
    "job.poll" | "job.kill" | "job.send" -> text_field(args, "job_id")
    "job.start" -> text_field(args, "command") |> result.map(first_token)
    "proc.run" -> process_summary(args)
    _ -> Error(Nil)
  }
  summary
  |> result.map(fn(text) { cut(strip_controls(text), max_summary_bytes) })
  |> result.try(fn(text) {
    case text {
      "" -> Error(Nil)
      _ -> Ok(text)
    }
  })
  |> option.from_result
}

fn text_field(args: MsgPackValue, key: String) -> Result(String, Nil) {
  case args {
    msgpack.MapValue(entries:) ->
      list.find_map(entries, fn(entry) {
        case entry {
          #(msgpack.StringValue(name), msgpack.StringValue(value))
            if name == key
          -> Ok(value)
          _ -> Error(Nil)
        }
      })
    _ -> Error(Nil)
  }
}

// The executable's basename and how many arguments follow it. The
// arguments themselves are never read: secrets travel on a command line
// far more often than in the name of the program.
fn process_summary(args: MsgPackValue) -> Result(String, Nil) {
  case args {
    msgpack.MapValue(entries:) ->
      list.find_map(entries, fn(entry) {
        case entry {
          #(msgpack.StringValue("argv"), msgpack.ArrayValue(items:)) ->
            executable_summary(items)
          _ -> Error(Nil)
        }
      })
    _ -> Error(Nil)
  }
}

fn executable_summary(argv: List(MsgPackValue)) -> Result(String, Nil) {
  case argv {
    [msgpack.StringValue(program), ..rest] ->
      Ok(
        basename(program) <> " +" <> int.to_string(list.length(rest)) <> " args",
      )
    _ -> Error(Nil)
  }
}

fn basename(path: String) -> String {
  string.split(path, on: "/")
  |> list.last
  |> result.unwrap(path)
}

// The first run of non-whitespace characters, which is the command a shell
// string starts with and nothing that follows it.
fn first_token(command: String) -> String {
  string.to_utf_codepoints(string.trim_start(command))
  |> list.take_while(fn(codepoint) {
    !is_whitespace(string.utf_codepoint_to_int(codepoint))
  })
  |> string.from_utf_codepoints
}

fn is_whitespace(code: Int) -> Bool {
  code == 0x20 || code == 0x09 || code == 0x0A || code == 0x0D
}

// Removes C0 controls, DEL and C1 controls, so a client drawing the text
// cannot be handed a terminal escape sequence.
fn strip_controls(text: String) -> String {
  string.to_utf_codepoints(text)
  |> list.filter(fn(codepoint) {
    let code = string.utf_codepoint_to_int(codepoint)
    !{ code < 0x20 || { code >= 0x7F && code <= 0x9F } }
  })
  |> string.from_utf_codepoints
}

// Cuts `text` to at most `limit` bytes on a code point boundary. A cut
// text ends with the ellipsis, and the ellipsis counts toward the limit.
fn cut(text: String, limit: Int) -> String {
  case byte_size(text) <= limit {
    True -> text
    False ->
      take_within(
        string.to_utf_codepoints(text),
        limit - byte_size(ellipsis),
        [],
      )
      <> ellipsis
  }
}

fn take_within(
  remaining: List(UtfCodepoint),
  budget: Int,
  kept: List(UtfCodepoint),
) -> String {
  case remaining {
    [codepoint, ..rest] -> {
      let width = byte_size(string.from_utf_codepoints([codepoint]))
      case width <= budget {
        True -> take_within(rest, budget - width, [codepoint, ..kept])
        False -> string.from_utf_codepoints(list.reverse(kept))
      }
    }
    [] -> string.from_utf_codepoints(list.reverse(kept))
  }
}

fn byte_size(text: String) -> Int {
  bit_array.byte_size(bit_array.from_string(text))
}
