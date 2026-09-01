//// Safe local server bootstrap for the native terminal client.
////
//// The TUI remains a protocol client. This module maps one canonical
//// workspace to private launcher state, validates a cached endpoint through
//// an authenticated protocol-v1 snapshot, and starts a separate server only
//// while holding a cross-process launch lock. Repository content supplies the
//// server's workspace data but never its executable, configuration, helper,
//// working directory, or launch arguments.

import core/json
import filepath
import gleam/bit_array
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import tui/connection
import tui/internal/ffi_bootstrap
import tui/protocol
import weft/poll

const endpoint_version = 2

const gateway_protocol = 1

const startup_timeout_ms = 30_000

const live_probe_timeout_ms = 10_000

const probe_timeout_ms = 10_000

const startup_poll_ms = 50

const lock_timeout_ms = 30_000

const max_endpoint_bytes = 16_384

const max_token_bytes = 16_384

const max_endpoint_records = 1024

const startup_log_tail_bytes = 4096

const endpoint_future_skew_ms = 5000

/// Local bootstrap overrides.
///
/// Empty fields take the private per-user and per-workspace defaults. These
/// values select only launcher state and installed executables; no repository
/// configuration is loaded by automatic startup.
pub type Options {
  Options(
    /// The workspace to open, or the process directory when empty.
    workspace: String,
    /// The session database, or a private per-workspace database when empty.
    session_file: String,
    /// The server executable, or the installed discovery ladder when empty.
    server: String,
    /// The launcher state root, or `~/.loom` when empty.
    state_directory: String,
    /// A model catalogue file to hand the server, or none when empty.
    ///
    /// Named by the operator on the command line, so it is trusted the way
    /// an explicitly attached server's `--config` is; the launcher still
    /// never reads a catalogue out of the workspace. It shapes a *cold*
    /// start only — a recorded endpoint whose server is still alive is
    /// reused as it is, whatever catalogue that server booted with.
    config: String,
  )
}

/// An authenticated ClientGateway attachment.
pub type Target {
  Target(
    /// The loopback websocket address.
    address: String,
    /// The server's expected session name.
    session: String,
    /// The bearer token read from the private token file.
    token: String,
  )
}

/// One locally managed session that the terminal can open.
pub type SessionChoice {
  SessionChoice(
    /// The stable session name published by the server.
    session: String,
    /// The canonical workspace supplied to the server.
    workspace: String,
    /// The canonical durable session database path.
    session_file: String,
  )
}

type Endpoint {
  Endpoint(
    version: Int,
    gateway_protocol: Int,
    status: String,
    workspace: String,
    session_file: String,
    session: String,
    address: String,
    token_file: String,
    log_file: String,
    server_pid: Int,
    server_birth: String,
    started_at_ms: Int,
  )
}

type Paths {
  Paths(
    session: String,
    endpoint: String,
    token: String,
    log: String,
    lock: String,
    private_directories: List(String),
  )
}

type StartedProcess {
  StartedProcess(process: ffi_bootstrap.ServerProcess, pid: Int)
}

type Reuse {
  Reused(Target)
  Replace
}

type ProcessMatch {
  SameProcess
  DifferentProcess
  ProcessUnknown(String)
}

/// Resolves a compatible local server, starting one when necessary.
///
/// A returned target has completed a real authenticated `subscribe` and named
/// the expected session in its snapshot. The launch lock is held across every
/// decision that could start a writer, and is released on every result.
///
/// ## Examples
///
/// ```gleam
/// bootstrap.resolve(bootstrap.Options("", "", "", ""))
/// // -> Ok(bootstrap.Target(..))
/// ```
pub fn resolve(options: Options) -> Result(Target, String) {
  use workspace <- result.try(canonical_workspace(options.workspace))
  use paths <- result.try(resolve_paths(options, workspace))
  use Nil <- result.try(ensure_private_directories(paths.private_directories))
  use lock <- result.try(acquire_lock(paths.lock))
  let outcome = resolve_locked(options, workspace, paths)
  ffi_bootstrap.release_launch_lock(lock)
  outcome
}

/// Discovers locally managed sessions from validated launcher records.
///
/// Endpoint files remain hints: malformed, misplaced, incompatible, and
/// non-loopback records are omitted. Selecting a result still calls `resolve`,
/// which verifies process identity and authenticates a real gateway snapshot.
///
/// ## Examples
///
/// ```gleam
/// bootstrap.discover_sessions(bootstrap.Options("", "", "", ""))
/// ```
pub fn discover_sessions(
  options: Options,
) -> Result(List(SessionChoice), String) {
  use unresolved_state <- result.try(state_directory(options.state_directory))
  use Nil <- result.try(
    ffi_bootstrap.ensure_private_directory(unresolved_state)
    |> result.map_error(fn(reason) {
      "prepare Loom state " <> unresolved_state <> ": " <> reason
    }),
  )
  use state <- result.try(
    ffi_bootstrap.canonical_directory(unresolved_state)
    |> result.map_error(fn(reason) { "resolve state directory: " <> reason }),
  )
  let directory = filepath.join(state, "endpoints")
  use Nil <- result.try(
    ffi_bootstrap.ensure_private_directory(directory)
    |> result.map_error(fn(reason) {
      "prepare Loom state " <> directory <> ": " <> reason
    }),
  )
  use names <- result.try(
    ffi_bootstrap.list_directory_bounded(directory, max_endpoint_records)
    |> result.map_error(fn(reason) { "list local sessions: " <> reason }),
  )
  let choices =
    names
    |> list.filter_map(fn(name) {
      discover_session(options, state, directory, name)
    })
    |> list.fold(dict.new(), fn(found, choice) {
      dict.insert(found, choice.session_file, choice)
    })
    |> dict.values
    |> list.sort(by: fn(left, right) {
      string.compare(
        left.session
          <> "\u{0}"
          <> left.workspace
          <> "\u{0}"
          <> left.session_file,
        right.session
          <> "\u{0}"
          <> right.workspace
          <> "\u{0}"
          <> right.session_file,
      )
    })
  Ok(choices)
}

/// Rebuilds local-launch inputs for one discovered session.
///
/// ## Examples
///
/// ```gleam
/// bootstrap.session_options(options, choice)
/// ```
pub fn session_options(base: Options, choice: SessionChoice) -> Options {
  Options(
    workspace: choice.workspace,
    session_file: choice.session_file,
    server: base.server,
    state_directory: base.state_directory,
  )
}

/// Resolves the canonical database identity selected by local launch options.
///
/// ## Examples
///
/// ```gleam
/// bootstrap.session_file(bootstrap.Options("", "", "", ""))
/// ```
@internal
pub fn session_file(options: Options) -> Result(String, String) {
  use workspace <- result.try(canonical_workspace(options.workspace))
  use paths <- result.try(resolve_paths(options, workspace))
  Ok(paths.session)
}

fn discover_session(
  base: Options,
  state: String,
  directory: String,
  name: String,
) -> Result(SessionChoice, Nil) {
  case string.ends_with(name, ".json") {
    False -> Error(Nil)
    True -> {
      let path = filepath.join(directory, name)
      use endpoint <- result.try(discard_reason(read_endpoint(path)))
      let options =
        Options(
          workspace: endpoint.workspace,
          session_file: endpoint.session_file,
          server: base.server,
          state_directory: state,
        )
      use workspace <- result.try(
        discard_reason(canonical_workspace(endpoint.workspace)),
      )
      use paths <- result.try(discard_reason(resolve_paths(options, workspace)))
      case
        paths.endpoint == path && endpoint_matches(endpoint, workspace, paths)
      {
        False -> Error(Nil)
        True ->
          Ok(SessionChoice(
            session: endpoint.session,
            workspace:,
            session_file: paths.session,
          ))
      }
    }
  }
}

fn discard_reason(value: Result(a, String)) -> Result(a, Nil) {
  result.replace_error(value, Nil)
}

fn resolve_locked(
  options: Options,
  workspace: String,
  paths: Paths,
) -> Result(Target, String) {
  case read_endpoint(paths.endpoint) {
    Ok(endpoint) ->
      case endpoint_matches(endpoint, workspace, paths) {
        True -> {
          use reuse <- result.try(reuse_endpoint(endpoint, paths.endpoint))
          case reuse {
            Reused(target) -> Ok(target)
            Replace -> start_server(options, workspace, paths)
          }
        }
        False ->
          preserve_incompatible_or_start(endpoint, options, workspace, paths)
      }
    Error(_) -> start_server(options, workspace, paths)
  }
}

fn preserve_incompatible_or_start(
  endpoint: Endpoint,
  options: Options,
  workspace: String,
  paths: Paths,
) -> Result(Target, String) {
  case match_process(endpoint.server_pid, endpoint.server_birth) {
    DifferentProcess -> start_server(options, workspace, paths)
    SameProcess ->
      Error(
        "the cached endpoint is incompatible, but loomd process "
        <> int.to_string(endpoint.server_pid)
        <> " is still alive; the record was preserved to avoid starting a competing session writer",
      )
    ProcessUnknown(reason) ->
      Error(identity_unknown_message(endpoint.server_pid, reason))
  }
}

fn reuse_endpoint(
  endpoint: Endpoint,
  endpoint_path: String,
) -> Result(Reuse, String) {
  case probe(endpoint) {
    Ok(target) -> Ok(Reused(target))
    Error(_) ->
      case endpoint.status {
        "starting" -> await_starting(endpoint, endpoint_path)
        "ready" ->
          case match_process(endpoint.server_pid, endpoint.server_birth) {
            SameProcess -> await_live(endpoint)
            DifferentProcess -> Ok(Replace)
            ProcessUnknown(reason) ->
              Error(identity_unknown_message(endpoint.server_pid, reason))
          }
        _ -> Ok(Replace)
      }
  }
}

// Every wait in this module is the same shape — probe, ask whether the
// server process is still the one the endpoint names, sleep, again — and
// `poll.until` is that shape decided once: an immediate first attempt, a
// last attempt at the deadline, and `Fail` kept apart from `Retry`. What
// each wait decides for itself is only what a probe failure means given
// the process identity, and what expiry means for the caller.
fn await_starting(
  endpoint: Endpoint,
  endpoint_path: String,
) -> Result(Reuse, String) {
  // The recorded start time bounds the wait even when this launcher
  // arrived late, and this launcher's own clock bounds it even when the
  // recorded time is in the future; the budget is what remains of the
  // earlier of the two.
  let now = ffi_bootstrap.system_time_ms()
  let deadline =
    int.min(
      endpoint.started_at_ms + startup_timeout_ms,
      now + startup_timeout_ms,
    )
  let outcome =
    poll.until(within: deadline - now, every: startup_poll_ms, attempt: fn() {
      case probe(endpoint) {
        Ok(target) -> poll.Done(Reused(target))
        Error(_) -> retry_starting(endpoint)
      }
    })
  case outcome {
    poll.Answered(Reused(target)) -> {
      let endpoint = Endpoint(..endpoint, status: "ready")
      use Nil <- result.try(
        write_endpoint(endpoint_path, endpoint)
        |> result.map_error(fn(reason) {
          "publish adopted endpoint: " <> reason
        }),
      )
      Ok(Reused(target))
    }
    poll.Answered(Replace) -> Ok(Replace)
    poll.Failed(reason) -> Error(reason)
    poll.Expired -> abandoned_start(endpoint)
  }
}

// A probe that failed while a *different* process holds the recorded pid
// means the server is gone and the endpoint is a replacement candidate;
// the same process, or one whose identity cannot be read, is still worth
// waiting for. An endpoint with no pid at all is a start that has not
// published one yet.
fn retry_starting(endpoint: Endpoint) -> poll.Attempt(Reuse, String) {
  case endpoint.server_pid > 0 {
    False -> poll.Retry
    True ->
      case match_process(endpoint.server_pid, endpoint.server_birth) {
        DifferentProcess -> poll.Done(Replace)
        SameProcess | ProcessUnknown(_) -> poll.Retry
      }
  }
}

fn abandoned_start(endpoint: Endpoint) -> Result(Reuse, String) {
  case match_process(endpoint.server_pid, endpoint.server_birth) {
    SameProcess ->
      Error(
        "loomd process "
        <> int.to_string(endpoint.server_pid)
        <> " is alive but did not become ready at "
        <> endpoint.address
        <> log_tail(endpoint),
      )
    DifferentProcess -> Ok(Replace)
    ProcessUnknown(reason) ->
      Error(identity_unknown_message(endpoint.server_pid, reason))
  }
}

fn await_live(endpoint: Endpoint) -> Result(Reuse, String) {
  let outcome =
    poll.until(
      within: live_probe_timeout_ms,
      every: startup_poll_ms,
      attempt: fn() {
        case probe(endpoint) {
          Ok(target) -> poll.Done(Reused(target))
          Error(_) ->
            case match_process(endpoint.server_pid, endpoint.server_birth) {
              DifferentProcess -> poll.Done(Replace)
              SameProcess | ProcessUnknown(_) -> poll.Retry
            }
        }
      },
    )
  case outcome {
    poll.Answered(reuse) -> Ok(reuse)
    poll.Failed(reason) -> Error(reason)
    poll.Expired ->
      Error(
        "loomd process "
        <> int.to_string(endpoint.server_pid)
        <> " is still alive but its authenticated gateway did not answer at "
        <> endpoint.address
        <> "; the endpoint was preserved to avoid starting a competing session writer"
        <> log_tail(endpoint),
      )
  }
}

fn start_server(
  options: Options,
  workspace: String,
  paths: Paths,
) -> Result(Target, String) {
  use server <- result.try(find_server(options.server))
  use config <- result.try(resolve_config(options.config))
  use port <- result.try(
    ffi_bootstrap.reserve_loopback_port()
    |> result.map_error(fn(reason) { "reserve loopback port: " <> reason }),
  )
  let started_at_ms = ffi_bootstrap.system_time_ms()
  let endpoint =
    Endpoint(
      version: endpoint_version,
      gateway_protocol: gateway_protocol,
      status: "starting",
      workspace:,
      session_file: paths.session,
      session: session_id(paths.session),
      address: "ws://127.0.0.1:" <> int.to_string(port) <> "/v1/ws",
      token_file: paths.token,
      log_file: paths.log,
      server_pid: 0,
      server_birth: "",
      started_at_ms:,
    )
  use Nil <- result.try(
    write_endpoint(paths.endpoint, endpoint)
    |> result.map_error(fn(reason) { "publish starting endpoint: " <> reason }),
  )
  use started <- result.try(spawn(endpoint, server, config))
  let StartedProcess(process:, pid:) = started
  case ffi_bootstrap.process_identity(pid) {
    Error(reason) -> {
      stop_started(StartedProcess(process:, pid:))
      Error("identify loomd process: " <> reason)
    }
    Ok(ffi_bootstrap.ProcessAbsent) -> {
      stop_started(StartedProcess(process:, pid:))
      Error("loomd wrapper exited before its identity was published")
    }
    Ok(ffi_bootstrap.ProcessPresent(server_birth)) -> {
      let endpoint = Endpoint(..endpoint, server_pid: pid, server_birth:)
      case write_endpoint(paths.endpoint, endpoint) {
        Error(reason) -> {
          stop_started(StartedProcess(process:, pid:))
          Error("publish server process: " <> reason)
        }
        Ok(Nil) -> release_and_await(endpoint, started, paths.endpoint)
      }
    }
  }
}

fn release_and_await(
  endpoint: Endpoint,
  started: StartedProcess,
  endpoint_path: String,
) -> Result(Target, String) {
  let StartedProcess(process:, pid:) = started
  case ffi_bootstrap.release_server_process(process) {
    Error(reason) -> {
      stop_started(StartedProcess(process:, pid:))
      Error("release loomd process: " <> reason)
    }
    Ok(Nil) ->
      await_new_server(
        endpoint,
        started,
        endpoint.started_at_ms + startup_timeout_ms,
        endpoint_path,
      )
  }
}

fn await_new_server(
  endpoint: Endpoint,
  started: StartedProcess,
  deadline: Int,
  endpoint_path: String,
) -> Result(Target, String) {
  let outcome =
    poll.until(
      within: deadline - ffi_bootstrap.system_time_ms(),
      every: startup_poll_ms,
      attempt: fn() {
        case probe(endpoint) {
          Ok(target) -> poll.Done(target)
          Error(_) ->
            // A server this launcher just started and which is already a
            // different process did not merely fail a probe: it exited.
            case match_process(endpoint.server_pid, endpoint.server_birth) {
              DifferentProcess ->
                poll.Fail("loomd exited before readiness" <> log_tail(endpoint))
              SameProcess | ProcessUnknown(_) -> poll.Retry
            }
        }
      },
    )
  case outcome {
    poll.Answered(target) -> {
      let ready = Endpoint(..endpoint, status: "ready")
      case write_endpoint(endpoint_path, ready) {
        Ok(Nil) -> Ok(target)
        Error(reason) -> {
          stop_started(started)
          Error("publish ready endpoint: " <> reason)
        }
      }
    }
    poll.Failed(reason) -> Error(reason)
    poll.Expired -> {
      stop_started(started)
      Error(
        "timed out waiting for loomd at "
        <> endpoint.address
        <> log_tail(endpoint),
      )
    }
  }
}

fn acquire_lock(path: String) -> Result(ffi_bootstrap.LaunchLock, String) {
  let outcome =
    poll.until(within: lock_timeout_ms, every: 25, attempt: fn() {
      case ffi_bootstrap.try_launch_lock(path) {
        Ok(lock) -> poll.Done(lock)

        // Busy is the one failure more time can fix; anything else is the
        // lock file itself refusing, which no retry will change.
        Error("busy") -> poll.Retry
        Error(reason) -> poll.Fail(reason)
      }
    })
  case outcome {
    poll.Answered(lock) -> Ok(lock)
    poll.Failed(reason) -> Error("acquire launch lock: " <> reason)
    poll.Expired -> Error("timed out waiting for the local server launch lock")
  }
}

fn canonical_workspace(path: String) -> Result(String, String) {
  ffi_bootstrap.canonical_directory(path)
  |> result.map_error(fn(reason) { "resolve workspace: " <> reason })
}

fn resolve_paths(options: Options, workspace: String) -> Result(Paths, String) {
  use unresolved_state <- result.try(state_directory(options.state_directory))
  use Nil <- result.try(
    ffi_bootstrap.ensure_private_directory(unresolved_state)
    |> result.map_error(fn(reason) {
      "prepare Loom state " <> unresolved_state <> ": " <> reason
    }),
  )
  use state_directory <- result.try(
    ffi_bootstrap.canonical_directory(unresolved_state)
    |> result.map_error(fn(reason) { "resolve state directory: " <> reason }),
  )
  let default_session_directory = filepath.join(state_directory, "sessions")
  use Nil <- result.try(case options.session_file {
    "" ->
      ffi_bootstrap.ensure_private_directory(default_session_directory)
      |> result.map_error(fn(reason) {
        "prepare Loom state " <> default_session_directory <> ": " <> reason
      })
    _ -> Ok(Nil)
  })
  use session <- result.try(session_path(
    options.session_file,
    state_directory,
    workspace,
  ))
  let endpoint_key = digest_prefix(session, 24)
  let endpoint_directory = filepath.join(state_directory, "endpoints")
  let log_directory = filepath.join(state_directory, "logs")
  let lock_directory = filepath.join(state_directory, "locks")
  let token_directory = filepath.join(state_directory, "tokens")
  let private_directories = [
    endpoint_directory,
    log_directory,
    lock_directory,
    token_directory,
  ]
  Ok(Paths(
    session:,
    endpoint: filepath.join(endpoint_directory, endpoint_key <> ".json"),
    token: filepath.join(token_directory, endpoint_key <> ".token"),
    log: filepath.join(log_directory, endpoint_key <> ".log"),
    lock: filepath.join(lock_directory, endpoint_key <> ".lock"),
    private_directories:,
  ))
}

fn state_directory(override: String) -> Result(String, String) {
  case override {
    "" -> {
      use home <- result.try(
        ffi_bootstrap.getenv("HOME")
        |> result.map_error(fn(_) { "find home directory: HOME is not set" }),
      )
      ffi_bootstrap.absolute_path(filepath.join(home, ".loom"))
    }
    path -> ffi_bootstrap.absolute_path(path)
  }
  |> result.map_error(fn(reason) { "resolve state directory: " <> reason })
}

fn session_path(
  override: String,
  state_directory: String,
  workspace: String,
) -> Result(String, String) {
  case override {
    "" ->
      canonical_session_path(filepath.join(
        filepath.join(state_directory, "sessions"),
        workspace_name(workspace) <> ".db",
      ))
    path -> canonical_session_path(path)
  }
}

fn canonical_session_path(path: String) -> Result(String, String) {
  use absolute <- result.try(
    ffi_bootstrap.absolute_path(path)
    |> result.map_error(fn(reason) { "resolve session file: " <> reason }),
  )
  case ffi_bootstrap.path_exists(absolute) {
    True ->
      ffi_bootstrap.canonical_path(absolute)
      |> result.map_error(fn(reason) { "resolve session file: " <> reason })
    False -> {
      use parent <- result.try(
        ffi_bootstrap.canonical_directory(filepath.directory_name(absolute))
        |> result.map_error(fn(reason) {
          "resolve session directory: " <> reason
        }),
      )
      Ok(filepath.join(parent, filepath.base_name(absolute)))
    }
  }
}

fn ensure_private_directories(
  directories: List(String),
) -> Result(Nil, String) {
  directories
  |> list.try_each(fn(directory) {
    ffi_bootstrap.ensure_private_directory(directory)
    |> result.map_error(fn(reason) {
      "prepare Loom state " <> directory <> ": " <> reason
    })
  })
}

/// Produces the stable private session name for a canonical workspace.
///
/// The readable slug is bounded to thirty-two ASCII characters and the
/// twelve-hex digest keeps equal basenames in different directories distinct.
@internal
pub fn workspace_name(workspace: String) -> String {
  let base = case filepath.base_name(workspace) {
    "" | "." | "/" -> "workspace"
    value -> value
  }
  let slug =
    slug_loop(string.to_utf_codepoints(string.lowercase(base)), "", 0, False)
  let slug = case trim_slug(slug) {
    "" -> "workspace"
    value -> value
  }
  slug <> "-" <> digest_prefix(workspace, 12)
}

fn slug_loop(
  characters: List(UtfCodepoint),
  accumulator: String,
  length: Int,
  last_was_dash: Bool,
) -> String {
  case characters, length >= 32 {
    _, True | [], False -> accumulator
    [character, ..rest], False -> {
      let code = string.utf_codepoint_to_int(character)
      case
        { code >= 0x61 && code <= 0x7a } || { code >= 0x30 && code <= 0x39 }
      {
        True ->
          slug_loop(
            rest,
            accumulator <> string.from_utf_codepoints([character]),
            length + 1,
            False,
          )
        False ->
          case accumulator != "" && !last_was_dash {
            True -> slug_loop(rest, accumulator <> "-", length + 1, True)
            False -> slug_loop(rest, accumulator, length, last_was_dash)
          }
      }
    }
  }
}

fn trim_slug(slug: String) -> String {
  case string.ends_with(slug, "-") {
    True -> string.drop_end(slug, 1)
    False -> slug
  }
}

fn digest_prefix(value: String, length: Int) -> String {
  ffi_bootstrap.sha256(<<value:utf8>>)
  |> bit_array.base16_encode
  |> string.lowercase
  |> string.slice(at_index: 0, length:)
}

fn endpoint_matches(
  endpoint: Endpoint,
  workspace: String,
  paths: Paths,
) -> Bool {
  let now = ffi_bootstrap.system_time_ms()
  endpoint.version == endpoint_version
  && endpoint.gateway_protocol == gateway_protocol
  && { endpoint.status == "starting" || endpoint.status == "ready" }
  && endpoint.started_at_ms > 0
  && endpoint.started_at_ms <= now + endpoint_future_skew_ms
  && endpoint.workspace == workspace
  && endpoint.session_file == paths.session
  && endpoint.session == session_id(paths.session)
  && endpoint.token_file == paths.token
  && endpoint.log_file == paths.log
  && local_gateway_address(endpoint.address)
}

/// Reports whether an address is the exact local gateway shape bootstrap owns.
///
/// Only plain websocket loopback addresses with a numeric port and `/v1/ws`
/// path pass. User info, query strings, fragments, host aliases, and remote
/// lookalikes are rejected.
@internal
pub fn local_gateway_address(address: String) -> Bool {
  let prefix = "ws://127.0.0.1:"
  let suffix = "/v1/ws"
  case
    string.starts_with(address, prefix) && string.ends_with(address, suffix)
  {
    False -> False
    True -> {
      let port =
        address
        |> string.drop_start(string.length(prefix))
        |> string.drop_end(string.length(suffix))
      case int.parse(port) {
        Ok(value) -> value > 0 && value <= 65_535
        Error(Nil) -> False
      }
    }
  }
}

/// Derives the server session name from a database basename.
///
/// The server uses the bytes before the first non-leading dot. Multi-dot
/// filenames and leading-dot filenames therefore retain its exact rule.
@internal
pub fn session_id(path: String) -> String {
  let base = filepath.base_name(path)
  case string.split(base, ".") {
    [first, ..] if first != "" -> first
    _ -> base
  }
}

fn read_endpoint(path: String) -> Result(Endpoint, String) {
  use bytes <- result.try(ffi_bootstrap.read_regular_bounded(
    path,
    max_endpoint_bytes,
  ))
  use text <- result.try(
    bit_array.to_string(bytes)
    |> result.replace_error("endpoint record is not UTF-8"),
  )
  use value <- result.try(
    json.parse(text)
    |> result.map_error(fn(report) { report.expected }),
  )
  decode_endpoint(value)
}

fn decode_endpoint(value: json.JsonValue) -> Result(Endpoint, String) {
  use fields <- result.try(object_fields(value, "endpoint record"))
  use version <- result.try(required_int(fields, "version"))
  use gateway_protocol <- result.try(required_int(fields, "gateway_protocol"))
  use status <- result.try(required_string(fields, "status"))
  use workspace <- result.try(required_string(fields, "workspace"))
  use session_file <- result.try(required_string(fields, "session_file"))
  use session <- result.try(required_string(fields, "session"))
  use address <- result.try(required_string(fields, "address"))
  use token_file <- result.try(required_string(fields, "token_file"))
  use log_file <- result.try(required_string(fields, "log_file"))
  use server_pid <- result.try(required_int(fields, "server_pid"))
  use server_birth <- result.try(required_string(fields, "server_birth"))
  use started_at_ms <- result.try(required_int(fields, "started_at_ms"))
  Ok(Endpoint(
    version:,
    gateway_protocol:,
    status:,
    workspace:,
    session_file:,
    session:,
    address:,
    token_file:,
    log_file:,
    server_pid:,
    server_birth:,
    started_at_ms:,
  ))
}

fn write_endpoint(path: String, endpoint: Endpoint) -> Result(Nil, String) {
  endpoint
  |> encode_endpoint
  |> json.to_string
  |> string.append("\n")
  |> ffi_bootstrap.atomic_write_private(path, _)
}

fn encode_endpoint(endpoint: Endpoint) -> json.JsonValue {
  json.Object([
    #("version", json.Int(endpoint.version)),
    #("gateway_protocol", json.Int(endpoint.gateway_protocol)),
    #("status", json.String(endpoint.status)),
    #("workspace", json.String(endpoint.workspace)),
    #("session_file", json.String(endpoint.session_file)),
    #("session", json.String(endpoint.session)),
    #("address", json.String(endpoint.address)),
    #("token_file", json.String(endpoint.token_file)),
    #("log_file", json.String(endpoint.log_file)),
    #("server_pid", json.Int(endpoint.server_pid)),
    #("server_birth", json.String(endpoint.server_birth)),
    #("started_at_ms", json.Int(endpoint.started_at_ms)),
  ])
}

fn object_fields(
  value: json.JsonValue,
  context: String,
) -> Result(List(#(String, json.JsonValue)), String) {
  case value {
    json.Object(fields) -> Ok(fields)
    json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error(context <> " must be an object")
  }
}

fn required_string(
  fields: List(#(String, json.JsonValue)),
  key: String,
) -> Result(String, String) {
  case list.key_find(fields, key) {
    Ok(json.String(value)) -> Ok(value)
    Ok(_) -> Error(key <> " must be a string")
    Error(Nil) -> Error(key <> " is required")
  }
}

fn required_int(
  fields: List(#(String, json.JsonValue)),
  key: String,
) -> Result(Int, String) {
  case list.key_find(fields, key) {
    Ok(json.Int(value)) -> Ok(value)
    Ok(_) -> Error(key <> " must be an integer")
    Error(Nil) -> Error(key <> " is required")
  }
}

fn find_server(explicit: String) -> Result(String, String) {
  case explicit {
    "" -> find_configured_server()
    path ->
      ffi_bootstrap.find_executable(path)
      |> result.map_error(fn(reason) { "--server: " <> reason })
  }
}

fn find_configured_server() -> Result(String, String) {
  case ffi_bootstrap.getenv("LOOM_SERVER") {
    Ok(configured) ->
      ffi_bootstrap.find_executable(configured)
      |> result.map_error(fn(reason) { "LOOM_SERVER: " <> reason })
    Error(Nil) -> find_installed_server()
  }
}

fn find_installed_server() -> Result(String, String) {
  let sibling_candidates = case ffi_bootstrap.getenv("LOOM_EXECUTABLE") {
    Ok(executable) ->
      case string.starts_with(executable, "/") {
        True -> [filepath.join(filepath.directory_name(executable), "loomd")]
        False -> []
      }
    Error(Nil) -> []
  }
  let path_candidates = case ffi_bootstrap.getenv("PATH") {
    Ok(path) -> installed_path_candidates(path)
    Error(Nil) -> []
  }
  find_first_server(list.append(sibling_candidates, path_candidates))
}

/// Expands only absolute PATH entries for implicit daemon discovery.
///
/// Relative entries resolve through the workspace and therefore cannot be
/// implicit launch authority. Operators can still select any executable with
/// `--server` or `LOOM_SERVER`.
@internal
pub fn installed_path_candidates(path: String) -> List(String) {
  path
  |> string.split(":")
  |> list.filter(fn(directory) { string.starts_with(directory, "/") })
  |> list.map(fn(directory) { filepath.join(directory, "loomd") })
}

fn find_first_server(candidates: List(String)) -> Result(String, String) {
  case candidates {
    [] ->
      Error(
        "loomd was not found; install it beside loom, put it on PATH, or pass --server <path>",
      )
    [candidate, ..rest] ->
      case ffi_bootstrap.find_executable(candidate) {
        Ok(path) -> Ok(path)
        Error(_) -> find_first_server(rest)
      }
  }
}

fn spawn(
  endpoint: Endpoint,
  server: String,
  config: String,
) -> Result(StartedProcess, String) {
  let arguments = server_arguments(endpoint, server, config)
  ffi_bootstrap.spawn_server(
    server,
    arguments,
    filepath.directory_name(endpoint.log_file),
    endpoint.log_file,
  )
  |> result.map(fn(started) {
    StartedProcess(process: started.0, pid: started.1)
  })
  |> result.map_error(fn(reason) { "start loomd: " <> reason })
}

fn stop_started(started: StartedProcess) -> Nil {
  let StartedProcess(process:, pid: _) = started
  ffi_bootstrap.close_server_process(process)
}

fn server_arguments(
  endpoint: Endpoint,
  server: String,
  config: String,
) -> List(String) {
  let port =
    endpoint.address
    |> string.drop_start(string.length("ws://127.0.0.1:"))
    |> string.drop_end(string.length("/v1/ws"))
  launch_arguments(
    endpoint.session_file,
    endpoint.workspace,
    port,
    endpoint.token_file,
    server,
    config,
  )
}

// An operator-named catalogue is resolved before the port is reserved, so a
// file that does not exist refuses the launch with a worded reason rather
// than a server that boots without it or dies on its own flag parsing. The
// path is made canonical because the server runs from the private state
// directory, not from wherever the operator typed the flag.
fn resolve_config(config: String) -> Result(String, String) {
  case config {
    "" -> Ok("")
    path ->
      ffi_bootstrap.canonical_path(path)
      |> result.map_error(fn(reason) {
        "resolve config " <> path <> ": " <> reason
      })
  }
}

/// Builds the fixed server argument surface used by automatic startup.
///
/// Workspace content contributes only the `--workspace` data path. A config
/// argument is emitted only for a catalogue the operator named explicitly
/// (never one found in the workspace), and a helper is pinned only when it
/// is an executable sibling of the selected server.
@internal
pub fn launch_arguments(
  session_file: String,
  workspace: String,
  port: String,
  token_file: String,
  server: String,
  config: String,
) -> List(String) {
  let arguments = [
    "--session",
    session_file,
    "--workspace",
    workspace,
    "--bind",
    "127.0.0.1:" <> port,
    "--token-file",
    token_file,
  ]
  let arguments = case config {
    "" -> arguments
    path -> list.append(arguments, ["--config", path])
  }
  let helper = filepath.join(filepath.directory_name(server), "loom-exec")
  case ffi_bootstrap.is_executable_file(helper) {
    True -> list.append(arguments, ["--helper", helper])
    False -> arguments
  }
}

fn match_process(pid: Int, birth: String) -> ProcessMatch {
  case pid > 1 && birth != "" {
    False -> DifferentProcess
    True ->
      case ffi_bootstrap.process_identity(pid) {
        Ok(ffi_bootstrap.ProcessPresent(current)) if current == birth ->
          SameProcess
        Ok(ffi_bootstrap.ProcessPresent(_)) | Ok(ffi_bootstrap.ProcessAbsent) ->
          DifferentProcess
        Error(reason) -> ProcessUnknown(reason)
      }
  }
}

fn identity_unknown_message(pid: Int, reason: String) -> String {
  "could not verify loomd process "
  <> int.to_string(pid)
  <> ": "
  <> reason
  <> "; the endpoint was preserved to avoid starting a competing session writer"
}

fn probe(endpoint: Endpoint) -> Result(Target, String) {
  use token <- result.try(read_token(endpoint.token_file))
  let inbox = connection.new_inbox()
  use socket <- result.try(connection.connect(endpoint.address, token, inbox))
  connection.send(socket, protocol.subscribe(1, endpoint.session))
  let result =
    await_snapshot(
      inbox,
      endpoint.session,
      ffi_bootstrap.system_time_ms() + probe_timeout_ms,
    )
  connection.close(socket)
  result
  |> result.map(fn(_) {
    Target(address: endpoint.address, session: endpoint.session, token:)
  })
}

fn await_snapshot(
  inbox: process.Subject(connection.Message),
  expected_session: String,
  deadline: Int,
) -> Result(Nil, String) {
  let remaining = int.max(0, deadline - ffi_bootstrap.system_time_ms())
  case process.receive(inbox, remaining) {
    Error(Nil) -> Error("gateway snapshot timed out")
    Ok(connection.Connected) ->
      await_snapshot(inbox, expected_session, deadline)
    Ok(connection.Closed(reason)) -> Error("gateway closed: " <> reason)
    Ok(connection.NetworkFault(reason)) -> Error("gateway fault: " <> reason)
    Ok(connection.Incoming(text)) ->
      case protocol.decode_event(text) {
        Ok(protocol.FullSnapshot(session:, ..)) ->
          case session == expected_session {
            True -> Ok(Nil)
            False ->
              Error(
                "gateway snapshot named session "
                <> string.inspect(session)
                <> ", want "
                <> string.inspect(expected_session),
              )
          }
        Ok(_) -> await_snapshot(inbox, expected_session, deadline)
        Error(reason) ->
          Error("gateway returned an invalid snapshot: " <> reason)
      }
  }
}

fn read_token(path: String) -> Result(String, String) {
  use bytes <- result.try(ffi_bootstrap.read_private_bounded(
    path,
    max_token_bytes,
  ))
  use token <- result.try(
    bit_array.to_string(bytes)
    |> result.replace_error("token file is not UTF-8"),
  )
  case string.trim(token) {
    "" -> Error("token file is empty: " <> path)
    value -> Ok(value)
  }
}

fn log_tail(endpoint: Endpoint) -> String {
  case
    ffi_bootstrap.current_log_tail(
      endpoint.log_file,
      endpoint.started_at_ms,
      startup_log_tail_bytes,
    )
  {
    Ok("") | Error(Nil) ->
      "; the server wrote no current log at " <> endpoint.log_file
    Ok(tail) -> "; recent server log (" <> endpoint.log_file <> "):\n" <> tail
  }
}
