//// A strand's glance: a short title for its current task and one line
//// saying what it is doing right now.
////
//// The operator watching several agents at once needs each one reduced to
//// a line they can read without opening it. The raw material for that line
//// is the strand's recent tool calls and assistant text, which are long,
//// structured and noisy, so the harness hands them to the `summarize` model
//// role and keeps the answer here. The daemon writes the cell and the
//// terminal reads it, which puts the shape in the one package both already
//// depend on, with a single total codec for both sides.
////
//// The cell lives under `client/glance/{strand}`, inside the reserved
//// `client/` prefix. Two properties follow from that placement. A model
//// cannot write there, so an agent cannot describe itself to the operator
//// in words the harness did not choose. And every transcript capture
//// already carries the whole `client/` prefix, so a terminal receives each
//// glance with the cut it renders, with no extra read and no new frame.
////
//// A glance describes one operation. The terminal shows it only while that
//// operation is still the strand's current one, so a successor never
//// inherits a title or summary written about its predecessor's task.
////
//// The stored cell is durable data from a daemon that may be older or
//// newer than the reader, so `decode` is total: anything malformed comes
//// back as a `CorruptionReport` rather than a crash or a blank row.

import core/corruption.{type CorruptionReport}
import core/json.{type JsonValue}
import gleam/list
import gleam/result
import gleam/string

/// The reserved `fact.custom` prefix every glance cell is written under.
pub const key_prefix = "client/glance/"

/// The longest a stored title may be, in bytes.
pub const max_title_bytes = 64

/// The longest a stored summary may be, in bytes.
pub const max_summary_bytes = 96

/// One strand's glance, as stored in its cell.
pub type Glance {
  Glance(
    /// The operation this glance describes. A reader shows the glance only
    /// while this is still the strand's current operation.
    operation: String,
    /// A few words naming the task, at most `max_title_bytes`.
    title: String,
    /// One line describing the latest activity, at most
    /// `max_summary_bytes`. Empty until the first summary is written.
    summary: String,
    /// When the summary was written, in Unix milliseconds.
    at: Int,
    /// The operation's current context size when the summary was written:
    /// `input + cache_read + cache_write + output` from the newest usage
    /// row that belongs to the operation, or zero before it has one. It is
    /// a replacement value, never a sum over rows, so a reader may swap in
    /// a newer figure from a live usage push without double counting.
    tokens: Int,
  )
}

/// Names the cell holding one strand's glance.
///
/// ## Examples
///
/// ```gleam
/// assert glance.key("sub:main/audit-1a2b") == "client/glance/sub:main/audit-1a2b"
/// ```
pub fn key(strand: String) -> String {
  key_prefix <> strand
}

/// Recovers the strand a glance cell belongs to from its key.
///
/// ## Examples
///
/// ```gleam
/// assert glance.strand_of("client/glance/main") == Ok("main")
/// assert glance.strand_of("client/run_settings") == Error(Nil)
/// ```
pub fn strand_of(key: String) -> Result(String, Nil) {
  case string.split_once(key, key_prefix) {
    Ok(#("", strand)) if strand != "" -> Ok(strand)
    Ok(_) | Error(Nil) -> Error(Nil)
  }
}

/// Reduces model text to one line of at most `max_bytes` bytes.
///
/// Whitespace runs, newlines included, collapse to one space, so a
/// multi-line answer cannot push the rows below it out of place. A cut
/// falls on a grapheme boundary and ends in an ellipsis, so a reader can
/// tell a shortened line from a complete one.
///
/// ## Examples
///
/// ```gleam
/// assert glance.clip("  Reading\n  manager.go ", 64) == "Reading manager.go"
/// assert glance.clip("abcdefgh", 6) == "abc…"
/// ```
pub fn clip(text: String, max_bytes: Int) -> String {
  let line =
    text
    |> string.split(on: "\n")
    |> list.flat_map(string.split(_, on: " "))
    |> list.flat_map(string.split(_, on: "\t"))
    |> list.flat_map(string.split(_, on: "\r"))
    |> list.filter(fn(word) { word != "" })
    |> string.join(" ")
  let graphemes = string.to_graphemes(line)
  case string.byte_size(line) <= max_bytes, max_bytes >= 3 {
    True, _ -> line

    // The ellipsis is three bytes, so a bound too small to hold it gets a
    // bare cut rather than a result longer than it asked for.
    False, True -> fit(graphemes, max_bytes - 3, "") <> "…"
    False, False -> fit(graphemes, max_bytes, "")
  }
}

// Graphemes are taken while they fit, so the cut can never split a
// multi-byte character and leave invalid UTF-8 in a stored cell.
fn fit(graphemes: List(String), budget: Int, taken: String) -> String {
  case graphemes {
    [] -> taken
    [next, ..rest] -> {
      let longer = taken <> next
      case string.byte_size(longer) <= budget {
        True -> fit(rest, budget, longer)
        False -> string.trim_end(taken)
      }
    }
  }
}

/// Encodes a glance as the JSON stored in its cell.
///
/// ## Examples
///
/// ```gleam
/// let stored = glance.encode(Glance("op-1", "Audit", "Reading x", 5, 10))
/// assert glance.decode(stored) == Ok(Glance("op-1", "Audit", "Reading x", 5, 10))
/// ```
pub fn encode(glance: Glance) -> JsonValue {
  json.Object([
    #("operation", json.String(glance.operation)),
    #("title", json.String(glance.title)),
    #("summary", json.String(glance.summary)),
    #("at", json.Int(glance.at)),
    #("tokens", json.Int(glance.tokens)),
  ])
}

/// Decodes a stored glance. Total: anything `encode` did not produce is a
/// `CorruptionReport` naming the first field that is wrong. Bounds are not
/// re-checked, so a reader still shows an oversized glance, clipped to its
/// own width, rather than dropping it.
///
/// ## Examples
///
/// ```gleam
/// let assert Error(_) = glance.decode(json.String("not a glance"))
/// ```
pub fn decode(value: JsonValue) -> Result(Glance, CorruptionReport) {
  use operation <- result.try(string_field(value, "operation"))
  use title <- result.try(string_field(value, "title"))
  use summary <- result.try(string_field(value, "summary"))
  use at <- result.try(int_field(value, "at"))
  use tokens <- result.map(int_field(value, "tokens"))
  Glance(operation:, title:, summary:, at:, tokens:)
}

fn string_field(
  value: JsonValue,
  key: String,
) -> Result(String, CorruptionReport) {
  case field(value, key) {
    Ok(json.String(text)) -> Ok(text)
    Ok(_) | Error(Nil) ->
      Error(corrupt("a string `" <> key <> "` field", value))
  }
}

fn int_field(value: JsonValue, key: String) -> Result(Int, CorruptionReport) {
  case field(value, key) {
    Ok(json.Int(number)) -> Ok(number)
    Ok(_) | Error(Nil) ->
      Error(corrupt("an integer `" <> key <> "` field", value))
  }
}

fn corrupt(expected: String, seen: JsonValue) -> CorruptionReport {
  corruption.report(
    at: "core/glance",
    on: "glance",
    expected:,
    context: json.to_string(seen),
  )
}

// The first occurrence wins, matching `core/json`'s documented tiebreak
// for hand-built objects with a repeated key.
fn field(value: JsonValue, key: String) -> Result(JsonValue, Nil) {
  case value {
    json.Object(fields) -> list.key_find(fields, key)
    json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error(Nil)
  }
}
