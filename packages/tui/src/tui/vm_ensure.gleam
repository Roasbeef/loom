//// `loom --vm`'s first step: make the workspace's microVM guest ready by
//// running `loomd vm ensure`, and turn its answer into the placement a session
//// is created with.
////
//// The launcher cannot import `client`, which owns the guest, so it does what
//// `loom vm` does for every verb: it runs the server binary. It differs from a
//// forwarded verb in needing the answer. `ensure` prints, as the last line of
//// standard output, `executor=<guest> workspace=<registered name>`, which is
//// exactly what `--executor E --workspace W` takes, and the launcher continues
//// as if those two flags had been typed (`placement.new`).
////
//// ## Two orderings
////
//// The launcher runs `ensure` before it resolves the daemon, because the first
//// guest of a machine installs the deployment into `loom.toml` and a daemon
//// that started earlier would not have read it (`ensure` stops an idle one, and
//// the launcher's normal resolve then starts it again with the table). The
//// second and later guests join that deployment through the running daemon,
//// and `ensure` never starts one: it exits with status 75 and the last line
//// `daemon=required`. The launcher then resolves the daemon, which starts one
//// when none runs, and runs `ensure` once more. One retry and no loop: a second
//// answer that is not a guest is the error.
////
//// ## Flow
////
//// `launch` → `ensure` → `answer` → `parse_line`
////
//// 1. `launch` locates the server and wires `ensure` to the real runner and the
////    real daemon resolution.
//// 2. `ensure` runs the command, asks `answer` what the output means, repairs
////    a missing daemon once, and builds the options the session starts with.
//// 3. `answer` is the pure reading of a status and its output, and
////    `parse_line` the total parser of the line that names the guest.
////
//// The standard library port that runs the server merges standard error into
//// standard output, so the progress `ensure` writes on standard error reaches
//// this module in the same text as its answer. It is shown after the command
//// ends, not as it is written, and the answer is the last line either way.

import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import host/bootstrap as host
import tui/bootstrap
import tui/daemon
import tui/placement

// A first guest may install the microVM artifacts, which is a download of
// several hundred megabytes, and then boot, so the command gets an hour.
const ensure_budget_ms = 3_600_000

// The status and last line `ensure` uses to say only a daemon is missing. They
// repeat `client/vm_spec`, which this package cannot import; the shipped
// acceptance runs both ends.
const daemon_required_status = 75

const daemon_required_line = "daemon=required"

/// The guest `ensure` made ready: the executor to place a session on and the
/// name its workspace is registered under there.
pub type Guest {
  Guest(executor: String, workspace: String)
}

/// Why `loom --vm` stopped, with the exit status to end with.
pub type Failure {
  Failure(status: Int, reason: String)
}

/// How one `ensure` run ended, read from its exit status and output.
pub type Answer {
  /// The guest serves. `progress` is what `ensure` said before its last line.
  Ready(guest: Guest, progress: String)

  /// Only a running daemon is missing.
  NeedsDaemon(progress: String)

  /// `ensure` failed or printed nothing the launcher can read. `output` is all
  /// of it, since the reason is the end of it and may span lines.
  Failed(status: Int, output: String)
}

/// Runs `ensure` with these arguments and answers its exit status and its
/// output, standard error included.
pub type Runner =
  fn(List(String)) -> Result(#(Int, String), String)

/// The arguments the server is run with: `vm ensure` for the launch's
/// workspace directory and configuration.
///
/// With no `--workspace` the directory is the launcher's own, which `ensure`
/// inherits and resolves the way a plain launch does; the dot says so.
///
/// ## Examples
///
/// ```gleam
/// assert vm_ensure.arguments(options)
///   == ["vm", "ensure", "--workspace", ".", "--config", "/c/loom.toml"]
/// ```
pub fn arguments(options: bootstrap.Options) -> List(String) {
  // An empty option is the launcher's default, which the server resolves the
  // same way, so it is passed as the current directory or not at all.
  let directory = case options.workspace {
    "" -> "."
    path -> path
  }

  // The configuration is passed only when the launch named one.
  let config = case options.config {
    "" -> []
    path -> ["--config", path]
  }

  list.flatten([["vm", "ensure", "--workspace", directory], config])
}

/// Reads the line `ensure` ends its standard output with.
///
/// The line is exactly `executor=NAME workspace=NAME`, with one space between
/// the two words, and both names must be ones a placement accepts, so the
/// launcher never builds a session from text that is not a pair of names.
///
/// ## Examples
///
/// ```gleam
/// assert vm_ensure.parse_line("executor=proj-1a2b3c workspace=proj")
///   == Ok(vm_ensure.Guest("proj-1a2b3c", "proj"))
/// let assert Error(_) = vm_ensure.parse_line("executor=a")
/// ```
pub fn parse_line(line: String) -> Result(Guest, String) {
  case string.split(line, " ") {
    ["executor=" <> executor, "workspace=" <> workspace] ->
      placement.new(Some(executor), None, Some(workspace))
      |> result.replace(Guest(executor:, workspace:))
      |> result.map_error(fn(reason) {
        "vm ensure named a guest the launcher cannot use: " <> reason
      })
    _ -> Error("vm ensure did not end with `executor=NAME workspace=NAME`")
  }
}

/// Reads one run of `ensure`.
///
/// Status zero must end with a guest line, and status 75 with the daemon line;
/// any other pair is a failure carrying the whole output, because the reason is
/// its last lines and may be several. Lines before the last one are progress.
///
/// ## Examples
///
/// ```gleam
/// let assert vm_ensure.Ready(guest, _) =
///   vm_ensure.answer(0, "booting\nexecutor=a-1 workspace=a\n")
/// assert guest.executor == "a-1"
/// ```
pub fn answer(status: Int, output: String) -> Answer {
  let lines =
    string.split(output, "\n")
    |> list.map(string.trim_end)
    |> list.reverse
    |> list.drop_while(fn(line) { line == "" })

  // The last non-blank line is the answer and what precedes it is progress.
  let #(last, before) = case lines {
    [last, ..rest] -> #(last, string.join(list.reverse(rest), "\n"))
    [] -> #("", "")
  }

  // Only the two statuses `ensure` documents have an answer line to read.
  case status {
    0 -> succeeded(last, before, output)
    s if s == daemon_required_status -> daemon_asked(last, before, output)
    _ -> Failed(status, string.trim(output))
  }
}

/// Status zero must end with a guest line the launcher can place a session on.
fn succeeded(last: String, progress: String, output: String) -> Answer {
  // A line that is not a guest is the server's fault, and the whole output
  // goes with the reason.
  case parse_line(last) {
    Ok(guest) -> Ready(guest, progress)
    Error(reason) -> Failed(1, string.trim(output) <> "\n" <> reason)
  }
}

/// Status 75 means a missing daemon only when its line says so.
fn daemon_asked(last: String, progress: String, output: String) -> Answer {
  // The status alone could be any other failure that happened to exit 75.
  case last == daemon_required_line {
    True -> NeedsDaemon(progress)
    False -> Failed(daemon_required_status, string.trim(output))
  }
}

/// Makes the guest ready and answers the options the session starts with: the
/// executor placement of `--executor E --workspace W`, and no `--workspace`
/// directory, as that launch has none.
///
/// `run` runs `ensure`, `start_daemon` resolves the daemon of the launch
/// (starting one when none runs), and `report` shows progress; all three are
/// arguments so a test can script them. When `ensure` says only a daemon is
/// missing, the daemon is started and `ensure` runs once more; the second answer
/// decides.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(options) =
///   vm_ensure.ensure(options, scripted_runner, fn() { Ok(Nil) }, fn(_) { Nil })
/// ```
pub fn ensure(
  options: bootstrap.Options,
  run run: Runner,
  start_daemon start_daemon: fn() -> Result(Nil, String),
  report report: fn(String) -> Nil,
) -> Result(bootstrap.Options, Failure) {
  use first <- result.try(attempt(options, run, report))

  // A missing daemon is the one answer the launcher can repair, once.
  use guest <- result.try(case first {
    Ready(guest, _) -> Ok(guest)
    NeedsDaemon(_) -> after_daemon(options, run, start_daemon, report)
    Failed(status, output) -> Error(Failure(status, output))
  })

  use chosen <- result.map(
    placement.new(Some(guest.executor), None, Some(guest.workspace))
    |> result.map_error(fn(reason) { Failure(1, reason) }),
  )
  bootstrap.Options(..options, workspace: "", placement: chosen)
}

/// Starts the daemon and runs `ensure` once more. The second answer is final:
/// a second request for a daemon is an error and not a second retry.
fn after_daemon(
  options: bootstrap.Options,
  run: Runner,
  start_daemon: fn() -> Result(Nil, String),
  report: fn(String) -> Nil,
) -> Result(Guest, Failure) {
  use Nil <- result.try(
    start_daemon()
    |> result.map_error(fn(reason) {
      Failure(1, "could not start the daemon: " <> reason)
    }),
  )
  use second <- result.try(attempt(options, run, report))

  // Only a guest ends it well; the daemon is up now, so asking for it again
  // would mean it did not take.
  case second {
    Ready(guest, _) -> Ok(guest)
    NeedsDaemon(_) ->
      Error(Failure(
        daemon_required_status,
        "vm ensure still needs a running daemon after one was started",
      ))
    Failed(status, output) -> Error(Failure(status, output))
  }
}

/// One run of `ensure`, with its progress shown. A failure to run it at all is
/// a failure with status 1.
fn attempt(
  options: bootstrap.Options,
  run: Runner,
  report: fn(String) -> Nil,
) -> Result(Answer, Failure) {
  use #(status, output) <- result.map(
    run(arguments(options))
    |> result.map_error(fn(reason) {
      Failure(1, "could not run vm ensure: " <> reason)
    }),
  )
  let read = answer(status, output)

  // Nothing to show is not reported as an empty line.
  case progress_of(read) {
    "" -> Nil
    text -> report(text)
  }

  read
}

/// What `ensure` said before its answer. A failure's output is its reason,
/// which the caller reports, so a failure has no progress of its own.
fn progress_of(read: Answer) -> String {
  case read {
    Ready(progress:, ..) | NeedsDaemon(progress:) -> progress
    Failed(..) -> ""
  }
}

/// Makes the guest ready with the real server, the real daemon resolution and
/// progress on standard error, for a launch that asked for `--vm`.
///
/// The daemon is resolved with the options the session will have, so it is the
/// daemon that launch reaches, and the connection that resolution opened is
/// closed again: the interactive client and `loom run` open their own.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(options) = vm_ensure.launch(options, io.println_error)
/// ```
pub fn launch(
  options: bootstrap.Options,
  report report: fn(String) -> Nil,
) -> Result(bootstrap.Options, Failure) {
  use server <- result.try(
    bootstrap.server_executable(options.server)
    |> result.map_error(fn(reason) { Failure(1, reason) }),
  )

  ensure(
    options,
    run: fn(arguments) {
      host.run_captured(server, arguments, ensure_budget_ms)
      |> result.map(fn(captured) { #(captured.status, captured.output) })
    },
    start_daemon: fn() {
      bootstrap.resolve_daemon(
        bootstrap.Options(..options, workspace: ""),
        process.self(),
        90_000,
      )
      |> result.map(fn(connected) { daemon.close(connected.control) })
    },
    report:,
  )
}
