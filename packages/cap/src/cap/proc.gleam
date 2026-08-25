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

import cap/internal/channel.{type CallError, Denied, Unreachable}
import cap/internal/dispatch
import cap/internal/wire
import core/msgpack.{type MsgPackValue}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

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
