//// `cap/proc` — run a command in a jailed executor. Each `run` is its
//// own kernel-sandboxed process (its own pgroup, its own filesystem
//// view) but draws on the execution's *pooled* budget: many `run`s share
//// one aggregate CPU/memory/pids cgroup and one wall deadline, so a
//// fanned-out program cannot amplify its footprint past what the token
//// backs (design §6.5).
////
//// A command is built with the pipeable builder and run once. A non-zero
//// exit is data — it comes back in `Output.exit_code`, not as an error;
//// only a refusal, a failed spawn, or a lost channel is a `ProcError`.
////
//// Most programs want the output text and nothing else, and hand-writing that
//// reduction is where they lose information: a helper that drops `stderr`
//// turns a tool's "fatal: ambiguous argument" into a bare "exit 128". Use
//// `stdout` (or `stdout_accepting`, for commands whose non-zero exit is an
//// answer, such as `grep` exiting 1 on no match) to get the text or one
//// error string that names the command, its exit code and the tail of its
//// stderr. Use `run` when the exit code or the truncation flags are data the
//// program needs.

import cap/internal/channel.{type CallError, Denied, Unreachable}
import cap/internal/dispatch
import cap/internal/wire
import core/msgpack.{type MsgPackValue}
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// A command to run. Opaque: built through `command` and the setters so
/// its invariants (non-empty argv) hold by construction.
pub opaque type Command {
  Command(
    argv: List(String),
    cwd: Option(String),
    env: List(#(String, String)),
    stdin: Option(String),
    timeout_ms: Option(Int),
  )
}

/// The result of a completed run. `exit_code` is the child's status;
/// `truncated` flags mark output cut at the policy's byte cap;
/// `timed_out` is set when the wall deadline killed the child.
pub type Output {
  Output(
    exit_code: Int,
    stdout: String,
    stderr: String,
    stdout_truncated: Bool,
    stderr_truncated: Bool,
    timed_out: Bool,
  )
}

/// Why a run could not produce an `Output`.
pub type ProcError {
  /// The broker refused to run the command in-band (e.g. policy).
  ProcDenied(code: String, message: String)

  /// The executor could not spawn the command at all.
  SpawnFailed(message: String)

  /// The capability channel could not carry the call.
  ProcUnavailable(reason: String)
}

/// Begins a command from its argv. The first element is the executable.
pub fn command(argv: List(String)) -> Command {
  Command(argv:, cwd: None, env: [], stdin: None, timeout_ms: None)
}

/// Sets the working directory for the command.
pub fn in_dir(command: Command, dir: String) -> Command {
  Command(..command, cwd: Some(dir))
}

/// Adds one environment variable. The executor still drops anything the
/// policy's `env_allow` does not permit.
pub fn with_env(command: Command, name: String, value: String) -> Command {
  Command(..command, env: [#(name, value), ..command.env])
}

/// Supplies stdin for the command.
pub fn with_stdin(command: Command, input: String) -> Command {
  Command(..command, stdin: Some(input))
}

/// Sets a per-command timeout in milliseconds. The pooled wall deadline
/// still bounds the whole execution.
pub fn with_timeout(command: Command, timeout_ms: Int) -> Command {
  Command(..command, timeout_ms: Some(timeout_ms))
}

/// Runs the command and returns its output.
///
/// Capability: `proc.run`.
pub fn run(command: Command) -> Result(Output, ProcError) {
  let args =
    wire.args([
      #("argv", wire.string_array(command.argv)),
      #("cwd", encode_optional_string(command.cwd)),
      #("env", encode_env(command.env)),
      #("stdin", encode_optional_string(command.stdin)),
      #("timeout_ms", encode_optional_int(command.timeout_ms)),
    ])
  use value <- result.try(
    dispatch.call("proc.run", args) |> result.map_error(map_error),
  )
  decode_output(value)
  |> result.map_error(fn(reason) {
    ProcUnavailable("bad proc.run result: " <> reason)
  })
}

fn encode_optional_string(value: Option(String)) -> MsgPackValue {
  case value {
    Some(text) -> wire.string(text)
    None -> msgpack.NilValue
  }
}

fn encode_optional_int(value: Option(Int)) -> MsgPackValue {
  case value {
    Some(number) -> wire.int(number)
    None -> msgpack.NilValue
  }
}

fn encode_env(env: List(#(String, String))) -> MsgPackValue {
  msgpack.MapValue(
    list.map(env, fn(pair) {
      #(msgpack.StringValue(pair.0), msgpack.StringValue(pair.1))
    }),
  )
}

fn decode_output(value: MsgPackValue) -> Result(Output, String) {
  use exit_code <- result.try(wire.int_field(value, "exit_code"))
  use stdout <- result.try(wire.string_field(value, "stdout"))
  use stderr <- result.try(wire.string_field(value, "stderr"))
  use stdout_truncated <- result.try(wire.bool_field(value, "stdout_truncated"))
  use stderr_truncated <- result.try(wire.bool_field(value, "stderr_truncated"))
  use timed_out <- result.try(wire.bool_field(value, "timed_out"))
  Ok(Output(
    exit_code:,
    stdout:,
    stderr:,
    stdout_truncated:,
    stderr_truncated:,
    timed_out:,
  ))
}

fn map_error(error: CallError) -> ProcError {
  case error {
    Unreachable(reason:) -> ProcUnavailable(reason:)
    Denied(code:, message:) ->
      case code {
        "spawn_failed" -> SpawnFailed(message:)
        _ -> ProcDenied(code:, message:)
      }
  }
}

/// A one-line rendering of a `ProcError`.
///
/// ## Examples
///
/// ```gleam
/// assert proc.error_text(proc.SpawnFailed("no such file")) == "spawn failed: no such file"
/// ```
///
pub fn error_text(error: ProcError) -> String {
  case error {
    ProcDenied(code:, message:) -> code <> ": " <> message
    SpawnFailed(message:) -> "spawn failed: " <> message
    ProcUnavailable(reason:) -> "proc unavailable: " <> reason
  }
}

/// Runs the command and returns its stdout, or one error string.
///
/// Only exit code 0 counts as success. The error text names the command and
/// says why it failed, so a program that runs several independent probes can
/// keep each probe's result or error without losing the reason.
///
/// When the output exceeded the policy's byte cap, the text is cut without a
/// marker; use `run` and read `stdout_truncated` when that matters.
///
/// Capability: `proc.run`.
///
/// ## Examples
///
/// ```gleam
/// let probes = [
///   proc.command(["git", "log", "-1", "--format=%h %s"]) |> proc.stdout,
///   proc.command(["gh", "pr", "list", "--json", "number"]) |> proc.stdout,
/// ]
/// // Each element is Ok(text) or an Error naming the failed command.
/// ```
///
pub fn stdout(command: Command) -> Result(String, String) {
  stdout_accepting(command, [0])
}

/// Runs the command and returns its stdout when the exit code is one of
/// `exit_codes`, or one error string otherwise.
///
/// A timed-out run is always an error, whatever its exit code.
///
/// When the output exceeded the policy's byte cap, the text is cut without a
/// marker; use `run` and read `stdout_truncated` when that matters.
///
/// Capability: `proc.run`.
///
/// ## Examples
///
/// ```gleam
/// // grep exits 1 when nothing matches, which is an answer, not a failure.
/// let hits =
///   proc.command(["grep", "-rn", "TODO", "src"])
///   |> proc.stdout_accepting([0, 1])
/// ```
///
pub fn stdout_accepting(
  command: Command,
  exit_codes: List(Int),
) -> Result(String, String) {
  stdout_from(command.argv, run(command), exit_codes)
}

/// The decision behind `stdout_accepting`, over an already-obtained run
/// result, so it can be tested without a capability channel.
///
/// ## Examples
///
/// ```gleam
/// let output = proc.Output(1, "", "boom", False, False, False)
/// assert proc.stdout_from(["ls"], Ok(output), [0])
///   == Error("`ls` exited 1: boom")
/// ```
///
@internal
pub fn stdout_from(
  argv: List(String),
  result: Result(Output, ProcError),
  exit_codes: List(Int),
) -> Result(String, String) {
  case result {
    Error(error) -> Error("`" <> argv_text(argv) <> "`: " <> error_text(error))

    // A timed-out child is a failure even when its recorded exit code is
    // one the caller accepts, because its output is cut short.
    Ok(output) ->
      case output.timed_out, list.contains(exit_codes, output.exit_code) {
        True, _ -> Error(timeout_text(argv, output.stderr))
        False, True -> Ok(output.stdout)
        False, False -> Error(exit_text(argv, output))
      }
  }
}

fn timeout_text(argv: List(String), stderr: String) -> String {
  let prefix = "`" <> argv_text(argv) <> "` timed out"
  case stderr_tail(stderr) {
    "" -> prefix
    tail -> prefix <> ": " <> tail
  }
}

fn exit_text(argv: List(String), output: Output) -> String {
  let reason = case stderr_tail(output.stderr) {
    "" -> "(no stderr)"
    tail -> tail
  }

  "`"
  <> argv_text(argv)
  <> "` exited "
  <> int.to_string(output.exit_code)
  <> ": "
  <> reason
}

// The command line only has to identify which probe failed, so a long one is
// cut rather than echoed whole. Both limits count the ellipsis, so the text
// is never longer than the limit. `tools/proc_failure` keeps its own copy of
// this cut for the satellite host; keep the two in step.
const argv_limit = 160

// Tools put the fatal line at the end of stderr, so the tail is kept.
const stderr_limit = 400

// The ellipsis is three bytes in UTF-8.
const ellipsis = "…"

const ellipsis_bytes = 3

fn argv_text(argv: List(String)) -> String {
  let line = string.join(argv, " ")
  case bit_array.byte_size(<<line:utf8>>) > argv_limit {
    True ->
      longest_prefix(<<line:utf8>>, argv_limit - ellipsis_bytes) <> ellipsis
    False -> line
  }
}

fn stderr_tail(stderr: String) -> String {
  let text = string.trim(stderr)
  let bytes = <<text:utf8>>
  let size = bit_array.byte_size(bytes)
  case size > stderr_limit {
    True ->
      ellipsis
      <> shortest_suffix(bytes, size, size - stderr_limit + ellipsis_bytes)
    False -> text
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
