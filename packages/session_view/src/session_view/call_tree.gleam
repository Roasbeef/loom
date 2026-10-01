//// The call record of a `code_mode` result, read back from the stored
//// `details` (protocol change 060).
////
//// The satellite host writes a `calls` object beside a foreground result's
//// `value` and `sandbox`: how many capability calls the program made, how
//// many failed, and an itemised, bounded list with each call's capability,
//// a redacted argument summary, status and timing. This module is the
//// reading half. It decodes that object into a `CallLog` and says one line
//// about it, so the terminal and the web view cannot word it differently.
////
//// ## Why decoding is total and quiet
////
//// A transcript must never fail to render over a display field. `read`
//// therefore answers `None` for a result with no `calls` (every result
//// written before the record existed, every background result, every vet
//// or compile failure) and for a `calls` value that is malformed in any
//// way: a wrong type, a missing field, a status it does not know, a
//// negative offset, or more items than `total`. Both cases mean the same
//// to a renderer, which draws what it always drew. Keys this version does
//// not know are ignored, so a later writer can add fields.
////
//// The module is pure and portable (lint R6): it reads a `JsonValue` and
//// holds no process, clock or host type. It knows the wire shape and
//// nothing about the tool that writes it, because `session_view` does not
//// depend on `tools`; the golden fixture in `call_tree_test` and in
//// `tools/call_record_test` is what keeps the two in step.

import core/json.{type JsonValue}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// How one call ended.
pub type Status {
  /// The capability answered.
  Settled

  /// The capability answered with an error, or the host refused the call.
  Failed

  /// The program cancelled the call before it settled.
  Cancelled

  /// The call was still in flight when the execution ended.
  Unsettled
}

/// One capability call.
pub type Call {
  Call(
    /// The capability name, such as `fs.read`.
    cap: String,
    /// The redacted argument summary, when the host made one.
    args: Option(String),
    /// How the call ended.
    status: Status,
    /// The error code of a failed call, never its message.
    error: Option(String),
    /// Milliseconds from the execution's start to this call's start.
    start_ms: Int,
    /// Milliseconds from the call's start to its end.
    duration_ms: Int,
  )
}

/// The settled record of one execution.
///
/// `total - length(items)` is the number of calls the host counted and did
/// not itemise. The counters are exact for every call.
pub type CallLog {
  CallLog(
    /// The execution's own zero, in Unix milliseconds.
    started_unix_ms: Int,
    /// Execution start to settlement, in milliseconds.
    elapsed_ms: Int,
    /// Every call the execution made.
    total: Int,
    /// Calls that failed or were refused.
    failed: Int,
    /// Calls the program cancelled.
    cancelled: Int,
    /// Calls still in flight when the execution ended.
    unsettled: Int,
    /// The itemised calls, in admission order.
    items: List(Call),
  )
}

/// Reads the call record out of a `code_mode` result's `details`, or
/// answers `None` when there is none or it cannot be trusted.
///
/// ## Examples
///
/// ```gleam
/// assert call_tree.read(json.Object([])) == option.None
/// ```
///
pub fn read(details: JsonValue) -> Option(CallLog) {
  case details {
    json.Object(fields) ->
      list.key_find(fields, "calls")
      |> result.try(decode_log)
      |> option.from_result
    _ -> None
  }
}

/// The one-line account of a record: `7 calls · 1 failed`, with
/// cancelled and unsettled counts added only when there are some.
///
/// ## Examples
///
/// ```gleam
/// assert call_tree.summary(log) == "7 calls · 1 failed"
/// ```
///
pub fn summary(log: CallLog) -> String {
  let noun = case log.total {
    1 -> " call"
    _ -> " calls"
  }
  let counted = fn(count: Int, word: String) {
    case count {
      0 -> []
      _ -> [int.to_string(count) <> " " <> word]
    }
  }
  list.flatten([
    [int.to_string(log.total) <> noun, int.to_string(log.failed) <> " failed"],
    counted(log.cancelled, "cancelled"),
    counted(log.unsettled, "unsettled"),
  ])
  |> string.join(" · ")
}

// --- decoding --------------------------------------------------------------

fn decode_log(value: JsonValue) -> Result(CallLog, Nil) {
  case value {
    json.Object(fields) -> {
      use started_unix_ms <- result.try(count(fields, "started_unix_ms"))
      use elapsed_ms <- result.try(count(fields, "elapsed_ms"))
      use total <- result.try(count(fields, "total"))
      use failed <- result.try(count(fields, "failed"))
      use cancelled <- result.try(count(fields, "cancelled"))
      use unsettled <- result.try(count(fields, "unsettled"))
      use items <- result.try(decode_items(fields))

      // An itemised list longer than the count of calls cannot be a record
      // of this execution, so it is refused rather than drawn.
      case list.length(items) <= total {
        True ->
          Ok(CallLog(
            started_unix_ms:,
            elapsed_ms:,
            total:,
            failed:,
            cancelled:,
            unsettled:,
            items:,
          ))
        False -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

fn decode_items(fields: List(#(String, JsonValue))) -> Result(List(Call), Nil) {
  case list.key_find(fields, "items") {
    Ok(json.Array(items)) -> list.try_map(items, decode_call)
    _ -> Error(Nil)
  }
}

fn decode_call(value: JsonValue) -> Result(Call, Nil) {
  case value {
    json.Object(fields) -> {
      use cap <- result.try(text(fields, "cap"))
      use args <- result.try(optional_text(fields, "args"))
      use status <- result.try(decode_status(fields))
      use error <- result.try(optional_text(fields, "error"))
      use start_ms <- result.try(count(fields, "start_ms"))
      use duration_ms <- result.try(count(fields, "duration_ms"))
      Ok(Call(cap:, args:, status:, error:, start_ms:, duration_ms:))
    }
    _ -> Error(Nil)
  }
}

fn decode_status(fields: List(#(String, JsonValue))) -> Result(Status, Nil) {
  case list.key_find(fields, "status") {
    Ok(json.String("ok")) -> Ok(Settled)
    Ok(json.String("failed")) -> Ok(Failed)
    Ok(json.String("cancelled")) -> Ok(Cancelled)
    Ok(json.String("unsettled")) -> Ok(Unsettled)
    _ -> Error(Nil)
  }
}

// A non-negative integer field. Every number in a record is a count or an
// offset, so a negative one is a malformed record.
fn count(fields: List(#(String, JsonValue)), key: String) -> Result(Int, Nil) {
  case list.key_find(fields, key) {
    Ok(json.Int(value)) if value >= 0 -> Ok(value)
    _ -> Error(Nil)
  }
}

fn text(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(String, Nil) {
  case list.key_find(fields, key) {
    Ok(json.String(value)) -> Ok(value)
    _ -> Error(Nil)
  }
}

// An optional text field: absent is fine, present must be a string.
fn optional_text(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(Option(String), Nil) {
  case list.key_find(fields, key) {
    Error(Nil) -> Ok(None)
    Ok(json.String(value)) -> Ok(Some(value))
    Ok(_) -> Error(Nil)
  }
}
