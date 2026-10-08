//// The last `proc.run` that failed, kept so a failed program can say why.
////
//// A program that shells out and then reports only `exit 128` hides the
//// one fact the model needs, which is what the command wrote to stderr.
//// The satellite host already sees every `proc.run` settle, so it keeps
//// one record of the most recent command that exited non-zero or timed
//// out, and `tools/codemode` prints it on the model-facing text when the
//// program ended in failure. This module is pure: it reads the call's
//// arguments and its reply, and renders the record.
////
//// ## What is kept
////
//// At most one `ProcFailure` per execution. The command is the argv joined
//// with single spaces and cut to `max_command_bytes`; the stderr tail is the
//// trimmed end of stderr cut to `max_stderr_bytes`. Both cuts fall on a
//// UTF-8 boundary and count the `…` that marks them, so a value is never
//// longer than its limit.
////
//// ## Exposure
////
//// The call record (`tools/call_record`, protocol-change 060) never keeps
//// argv beyond the executable name or any output, because it is a log the
//// host writes about calls for clients to display. This record is
//// different in kind: it goes into the model's own tool result, the model
//// wrote the command, and its program could have returned the same stderr
//// through `report.text`. No redaction is applied because the tree has no
//// text redaction helper outside the memory path, which owns its own
//// policy, and a half-measure here would imply a guarantee the host does
//// not make. The size limits are the bound on what travels.

import core/json.{type JsonValue}
import core/msgpack.{type MsgPackValue}
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// The longest command text kept, in bytes, `…` included.
pub const max_command_bytes = 160

/// The longest stderr tail kept, in bytes, `…` included.
pub const max_stderr_bytes = 400

const ellipsis = "…"

/// Whether the wall deadline killed the child.
pub type Ending {
  /// The child exited by itself.
  Exited

  /// The deadline killed the child.
  TimedOut
}

/// One failed command.
pub type ProcFailure {
  ProcFailure(
    /// The argv joined with single spaces, cut to `max_command_bytes`.
    command: String,
    /// The child's exit status; meaningful when `ending` is `Exited`.
    exit_code: Int,
    ending: Ending,
    /// The trimmed end of stderr, cut to `max_stderr_bytes`.
    stderr_tail: String,
  )
}

/// The command text for a `proc.run` call's arguments, or `None` when the
/// arguments carry no string argv.
///
/// ## Examples
///
/// ```gleam
/// // proc_failure.command_text(args) == Some("git log --format %h")
/// ```
///
pub fn command_text(args: MsgPackValue) -> Option(String) {
  case args {
    msgpack.MapValue(entries:) ->
      list.find_map(entries, fn(entry) {
        case entry {
          #(msgpack.StringValue("argv"), msgpack.ArrayValue(items:)) ->
            Ok(items)
          _ -> Error(Nil)
        }
      })
      |> option.from_result
      |> option.map(argv_words)
      |> option.then(fn(words) {
        case words {
          [] -> None
          _ -> Some(cut_head(string.join(words, " "), max_command_bytes))
        }
      })
    _ -> None
  }
}

fn argv_words(items: List(MsgPackValue)) -> List(String) {
  list.filter_map(items, fn(item) {
    case item {
      msgpack.StringValue(word) -> Ok(word)
      _ -> Error(Nil)
    }
  })
}

/// The failure a settled `proc.run` reply records, or `None` when the
/// command succeeded or the reply is not an output map.
///
/// ## Examples
///
/// ```gleam
/// // proc_failure.from_reply("git log", reply) == Some(ProcFailure(..))
/// ```
///
pub fn from_reply(command: String, reply: MsgPackValue) -> Option(ProcFailure) {
  case reply {
    msgpack.MapValue(entries:) -> {
      let exit_code = int_field(entries, "exit_code")
      let timed_out = bool_field(entries, "timed_out")
      let stderr = text_field(entries, "stderr") |> option.unwrap("")
      case exit_code, timed_out {
        Some(code), Some(True) -> Some(failure(command, code, TimedOut, stderr))
        Some(code), Some(False) if code != 0 ->
          Some(failure(command, code, Exited, stderr))
        _, _ -> None
      }
    }
    _ -> None
  }
}

fn failure(
  command: String,
  exit_code: Int,
  ending: Ending,
  stderr: String,
) -> ProcFailure {
  ProcFailure(
    command:,
    exit_code:,
    ending:,
    stderr_tail: cut_tail(string.trim(stderr), max_stderr_bytes),
  )
}

fn field(
  entries: List(#(MsgPackValue, MsgPackValue)),
  key: String,
) -> Option(MsgPackValue) {
  list.find_map(entries, fn(entry) {
    case entry {
      #(msgpack.StringValue(name), value) if name == key -> Ok(value)
      _ -> Error(Nil)
    }
  })
  |> option.from_result
}

fn int_field(
  entries: List(#(MsgPackValue, MsgPackValue)),
  key: String,
) -> Option(Int) {
  case field(entries, key) {
    Some(msgpack.IntValue(value)) -> Some(value)
    _ -> None
  }
}

fn bool_field(
  entries: List(#(MsgPackValue, MsgPackValue)),
  key: String,
) -> Option(Bool) {
  case field(entries, key) {
    Some(msgpack.BoolValue(value)) -> Some(value)
    _ -> None
  }
}

fn text_field(
  entries: List(#(MsgPackValue, MsgPackValue)),
  key: String,
) -> Option(String) {
  case field(entries, key) {
    Some(msgpack.StringValue(value)) -> Some(value)
    _ -> None
  }
}

/// The one line the model reads.
///
/// Stderr lines are joined with ` | ` so the record stays on one line.
///
/// ## Examples
///
/// ```gleam
/// assert proc_failure.line(ProcFailure("git log", 128, Exited, "fatal: x"))
///   == "last failing command: `git log` exited 128: fatal: x"
/// ```
///
pub fn line(failure: ProcFailure) -> String {
  let ended = case failure.ending {
    Exited -> "exited " <> int.to_string(failure.exit_code)
    TimedOut -> "timed out"
  }
  let stderr = case one_line(failure.stderr_tail) {
    "" -> ""
    text -> ": " <> text
  }
  "last failing command: `" <> failure.command <> "` " <> ended <> stderr
}

fn one_line(text: String) -> String {
  string.split(text, "\n")
  |> list.map(string.trim)
  |> list.filter(fn(piece) { piece != "" })
  |> string.join(" | ")
}

/// The record as the `last_failed_command` detail.
pub fn to_json(failure: ProcFailure) -> JsonValue {
  json.Object([
    #("command", json.String(failure.command)),
    #("exit_code", json.Int(failure.exit_code)),
    #("timed_out", json.Bool(failure.ending == TimedOut)),
    #("stderr_tail", json.String(failure.stderr_tail)),
  ])
}

fn byte_size(text: String) -> Int {
  bit_array.byte_size(bit_array.from_string(text))
}

/// Keeps the start of `text` within `limit` bytes, ending in `…` when cut.
///
/// The `…` counts toward the limit. The cut slices bytes and backs off to a
/// character boundary, the same way `cap/proc` cuts its failure text; the two
/// copies are separate because `cap` and `tools` share no module, so keep
/// them in step.
///
/// ## Examples
///
/// ```gleam
/// assert proc_failure.cut_head("abcdef", 5) == "ab…"
/// ```
///
pub fn cut_head(text: String, limit: Int) -> String {
  let bytes = bit_array.from_string(text)
  case bit_array.byte_size(bytes) <= limit {
    True -> text
    False -> longest_prefix(bytes, limit - byte_size(ellipsis)) <> ellipsis
  }
}

/// Keeps the end of `text` within `limit` bytes, starting with `…` when cut.
///
/// The `…` counts toward the limit, and the cut is made on bytes as
/// `cut_head` does, so a long stderr is never graphemized.
///
/// ## Examples
///
/// ```gleam
/// assert proc_failure.cut_tail("abcdef", 5) == "…ef"
/// ```
///
pub fn cut_tail(text: String, limit: Int) -> String {
  let bytes = bit_array.from_string(text)
  let size = bit_array.byte_size(bytes)
  case size <= limit {
    True -> text
    False ->
      ellipsis
      <> shortest_suffix(bytes, size, size - limit + byte_size(ellipsis))
  }
}

// The longest prefix of at most `length` bytes that decodes as UTF-8. A
// character is at most four bytes, so this backs off at most three bytes.
fn longest_prefix(bytes: BitArray, length: Int) -> String {
  let decoded =
    bit_array.slice(bytes, 0, length) |> result.try(bit_array.to_string)
  case decoded {
    Ok(text) -> text
    Error(Nil) if length > 0 -> longest_prefix(bytes, length - 1)
    Error(Nil) -> ""
  }
}

// The suffix starting at `start`, moved forward to the first character
// boundary.
fn shortest_suffix(bytes: BitArray, size: Int, start: Int) -> String {
  let decoded =
    bit_array.slice(bytes, start, size - start)
    |> result.try(bit_array.to_string)
  case decoded {
    Ok(text) -> text
    Error(Nil) if start < size -> shortest_suffix(bytes, size, start + 1)
    Error(Nil) -> ""
  }
}
