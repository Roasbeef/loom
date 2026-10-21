//// Git for worktree management, run in the sandbox (protocol-change/095).
////
//// An executor serving a worktree workspace has to run `git worktree add`,
//// `remove`, `prune` and `status` before a session's own plane exists, and
//// those commands read a repository whose configuration and hooks the
//// session's model may have written. Rule Zero says model-influenced code
//// never runs in the harness VM, so this module is the one place those
//// commands start, and it starts them through the same broker and helper that
//// run every tool call: a helper pool, the executor service over it, and a
//// broker that clears each call against a policy before the helper sees it.
//// The pool is lazy, so a daemon with no worktree workspace pays for nothing,
//// and it is separate from every session's pool because there is no session
//// yet when the first tree is made.
////
//// ## What a call may do
////
//// Each call carries its own policy, built here from the call's arguments and
//// never from anything an orchestrator sent. It may read the host, as a
//// session's tools may by default, with the state root's secrets masked
//// (`workspace_policy.protecting_state_root`), because the repository it
//// reads is the model's to shape. It has no network. Its writable roots are
//// exactly the ones the caller names: nothing for `status`, and for `add` and
//// `remove` the repository's `.git` and the workspace's directory under
//// `<state root>/worktrees`. A hook that `git worktree add` runs therefore
//// cannot write another session's tree, and a `status` cannot write anything,
//// whatever `core.fsmonitor` says.
////
//// ## Flow
////
//// `start` → `run` → `stop`
////
//// 1. `start` resolves the Git binary once, on the host, and boots the pool,
////    the service and the broker.
//// 2. `run` clears one call, collects its output and answers the exit code
////    with the first lines of both streams.
//// 3. `stop` drains the broker and the service.

import broker/broker
import broker/budget
import broker/exec.{type EnforcementDemand}
import broker/executor as service
import broker/policy
import broker/token
import client/host_git
import client/internal/ffi_os
import client/workspace_policy
import core/clock
import core/ids
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import gleam/time/timestamp
import simplifile
import telemetry/log
import tools/tool

/// What the sandboxed Git is started from.
pub type Config {
  Config(
    /// The `loom-exec` sandbox helper.
    helper_path: String,
    /// A directory the runner may keep the helper's policy files in. It is
    /// created private if absent and never holds a session's files.
    scratch: String,
    /// The daemon's state root, whose secrets every call masks.
    state_root: String,
    /// Enforcement strictness for every call.
    demand: EnforcementDemand,
  )
}

/// A running sandboxed Git: the broker its calls clear through and the Git
/// binary they name.
pub opaque type Git {
  Git(
    broker: broker.Broker,
    service: service.Executor,
    program: String,
    scratch: String,
    state_root: String,
    demand: EnforcementDemand,
    incarnation: Int,
  )
}

/// One Git invocation.
pub type Run {
  Run(
    /// The directory Git runs in. It is readable whatever the writable roots
    /// say, because the jail reads the host.
    directory: String,
    /// The paths the call may write, and nothing else. Empty for a read.
    writable: List(String),
    /// Git's arguments after the binary, such as `["worktree", "prune"]`.
    arguments: List(String),
  )
}

/// How a call that ran ended.
pub type Output {
  Output(
    /// Git's exit code.
    code: Int,
    /// Standard output as text, with invalid UTF-8 replaced.
    stdout: String,
    /// Standard error as text, with invalid UTF-8 replaced.
    stderr: String,
  )
}

/// How long a call may take unless the caller says otherwise: ten minutes,
/// which a checkout of a very large repository fits in.
pub const checkout_within_ms = 600_000

/// How long a read-only call may take.
pub const query_within_ms = 60_000

/// Boots the sandboxed Git.
///
/// The processes are linked to the caller, which in the daemon is the process
/// that starts the executor host. The Git binary is resolved once, here, on the
/// host and outside any jail (`host_git.program`), so a Mac's `xcrun` shim never
/// runs under the jail's file-size limit.
///
/// ## Examples
///
/// ```gleam
/// // worktree_git.start(Config(helper, state <> "/git", state, exec.PlatformEnforcement))
/// ```
pub fn start(config: Config) -> Result(Git, String) {
  use Nil <- result.try(
    simplifile.create_directory_all(config.scratch <> "/tmp")
    |> result.map_error(fn(error) {
      "cannot create "
      <> config.scratch
      <> ": "
      <> simplifile.describe_error(error)
    }),
  )
  let spawn =
    exec.SpawnConfig(
      helper_path: config.helper_path,
      shell_path: workspace_policy.shell_path,
      base_policy: policy.workspace_default(config.scratch),
      helper_args: [],
      tmp_dir: config.scratch <> "/tmp",
      handshake_timeout_ms: 5000,
      cancel_grace_ms: 3000,
      heartbeat_interval_ms: 0,
    )
  use pool <- result.try(
    exec.start_pool(size: 1, spawn: fn() { exec.prepare_helper(spawn) })
    |> result.map_error(fn(error) {
      "the Git helper pool did not start: " <> string.inspect(error)
    }),
  )
  let incarnation = mint_incarnation()
  use started <- result.try(
    service.start(service.ExecutorConfig(
      checkout: fn() { exec.checkout(pool, waiting: 15_000) },
      checkin: fn(helper) { exec.checkin(pool, helper) },
      custody: fn() { exec.pool_custody(pool, waiting: 1000) },
      close_helpers: fn(waiting) { exec.close_pool(pool, waiting:) },
      incarnation:,
      log: log.discard(),
    ))
    |> result.map_error(fn(error) {
      "the Git service did not start: " <> string.inspect(error)
    }),
  )
  use fronted <- result.map(
    broker.start_dispatching(
      entropy: token.production_entropy(),
      clock: wall_clock(),
      dispatcher: service.dispatcher(started),
    )
    |> result.map_error(fn(error) {
      "the Git broker did not start: " <> string.inspect(error)
    }),
  )
  Git(
    broker: fronted,
    service: started,
    program: host_git.program(),
    scratch: config.scratch,
    state_root: config.state_root,
    demand: config.demand,
    incarnation:,
  )
}

/// Runs one Git invocation in the sandbox and answers how it ended.
///
/// An `Error` means the call did not run to an exit: the broker refused its
/// policy, the helper could not start, or it did not settle within `within_ms`
/// and was cancelled. A Git that ran and failed is `Ok` with a nonzero code,
/// because the caller decides what each failure means.
///
/// ## Examples
///
/// ```gleam
/// // worktree_git.run(git, Run("/repo", [], ["status", "--porcelain=v1"]), 60_000)
/// ```
pub fn run(git: Git, call: Run, within_ms: Int) -> Result(Output, String) {
  let #(op_id, _) =
    ids.mint_op(ids.generator(wall_clock(), seed: random_seed()))
  let environment = environment()
  let allowed = list.map(environment, fn(pair) { pair.0 })
  let policy = policy_of(git, call, allowed, within_ms)
  let events = process.new_subject()
  use handle <- result.try(
    broker.clear_call(
      git.broker,
      broker.CallSpec(
        op_id:,
        step_id: "worktree-git",
        base_policy: policy,
        requirements: policy,
        grants: [],
        response: broker.RefuseNarrowed,
        demand: git.demand,
        argv: [
          git.program,
          "--no-pager",
          "--no-optional-locks",
          ..call.arguments
        ],
        env: environment,
        cwd: call.directory,
        budget: budget.Budget(max_outstanding: 1, deadline_ms: 0),
      ),
      events:,
      waiting: within_ms,
    )
    |> result.map_error(fn(refusal) {
      "the sandbox refused the Git call: " <> string.inspect(refusal)
    }),
  )

  // Git reads no input, so its stdin is closed before anything can wait on it.
  broker.stdin(git.broker, handle, data: <<>>, eof: True)
  use collected <- result.try(
    tool.collect_events(events, waiting: within_ms + settlement_grace_ms)
    |> result.map_error(fn(_) {
      broker.cancel(git.broker, handle)
      "the Git call did not settle in time"
    }),
  )
  settled(collected)
}

/// Stops the broker and the service, which closes the helper pool. The answer
/// is whether the pool confirmed its helpers gone.
///
/// ## Examples
///
/// ```gleam
/// // worktree_git.stop(git)
/// ```
pub fn stop(git: Git) -> Result(Nil, String) {
  broker.stop(git.broker)
  service.close(
    git.service,
    draining: service.drain_ms,
    helpers: service.helpers_ms,
  )
  |> result.map_error(fn(failure) { string.inspect(failure) })
}

/// The first `limit` bytes of text that are printable, for a refusal that
/// carries Git's message across the wire. Control characters become spaces and
/// the cut never splits a character.
///
/// ## Examples
///
/// ```gleam
/// assert worktree_git.printable("fatal: no\nrepo\u{0}", 512) == "fatal: no repo"
/// ```
pub fn printable(text: String, limit: Int) -> String {
  let cleaned =
    string.to_graphemes(string.trim(text))
    |> list.map(fn(grapheme) {
      case string.to_utf_codepoints(grapheme) {
        [point] ->
          case string.utf_codepoint_to_int(point) {
            code if code < 32 || code == 127 -> " "
            _ -> grapheme
          }
        _ -> grapheme
      }
    })
    |> string.concat
    |> string.trim
  take_bytes(string.to_graphemes(cleaned), limit, "")
}

fn take_bytes(graphemes: List(String), left: Int, kept: String) -> String {
  case graphemes {
    [first, ..rest] ->
      case string.byte_size(first) <= left {
        True -> take_bytes(rest, left - string.byte_size(first), kept <> first)
        False -> kept
      }
    [] -> kept
  }
}

// A cleared call's account. A cancellation or timeout is not an exit, so it is
// an error; everything else carries the exit code the caller will judge.
fn settled(collected: tool.Collected) -> Result(Output, String) {
  case collected.outcome {
    broker.CallFailed(failure) -> Error(string.inspect(failure))
    broker.CallExited(report) ->
      case report.cancelled || report.timed_out {
        True -> Error("Git did not complete before cancellation")
        False ->
          Ok(Output(
            code: report.code,
            stdout: text_of(collected.stdout),
            stderr: text_of(collected.stderr),
          ))
      }
  }
}

fn text_of(bits: BitArray) -> String {
  case bit_array.to_string(bits) {
    Ok(text) -> text
    Error(Nil) -> string.inspect(bits)
  }
}

// The policy for one call: the host readable, the state root's secrets masked,
// the network off, and writes only where the caller named. The ceilings leave
// the CPU, memory and file size to the wall deadline, since a checkout's cost
// grows with the repository and a limit that fits a small one stops a large
// one half way.
fn policy_of(
  git: Git,
  call: Run,
  allowed: List(String),
  within_ms: Int,
) -> policy.SandboxPolicy {
  let base = policy.workspace_default(git.scratch)
  policy.SandboxPolicy(
    ..base,
    writable_roots: call.writable,
    readable_roots: ["/"],
    network: policy.NetworkOff,
    limits: policy.Limits(
      cpu_s: 0,
      wall_s: { within_ms + 999 } / 1000,
      mem_bytes: 0,
      pids: 64,
      fsize_bytes: 0,
      output_bytes: output_limit_bytes,
    ),
    env_allow: allowed,
  )
  |> workspace_policy.protecting_state_root(git.state_root)
}

// Nothing here comes from a peer. Git reads no user or system configuration:
// the repository's own is the only one in play, and a global file that names
// a credential helper or an include has no business in a worktree command.
fn environment() -> List(#(String, String)) {
  [
    #("PATH", "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"),
    #("HOME", "/nonexistent"),
    #("LANG", "C"),
    #("LC_ALL", "C"),
    #("GIT_CONFIG_NOSYSTEM", "1"),
    #("GIT_CONFIG_GLOBAL", "/dev/null"),
    #("GIT_TERMINAL_PROMPT", "0"),
    #("GIT_OPTIONAL_LOCKS", "0"),
  ]
}

// Output past this is cut by the helper. A worktree command prints a line or
// a few, and a message longer than this is not one an operator reads.
const output_limit_bytes = 1_048_576

// The time the broker is given to report a cancelled call after the call's own
// deadline, so a settlement that races the deadline is still collected.
const settlement_grace_ms = 5000

// Two calls minted in one millisecond must not share an operation id, since
// the broker keeps one budget per id, so the generator's seed is random.
fn random_seed() -> Int {
  int.random(281_474_976_710_656)
}

// The wall clock in microseconds. An incarnation only has to differ between two
// boots in one VM, and a boot takes far longer than a microsecond.
fn mint_incarnation() -> Int {
  let #(seconds, nanoseconds) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  seconds * 1_000_000 + nanoseconds / 1000
}

fn wall_clock() -> clock.Clock {
  clock.from_function(ffi_os.system_time_ms)
}
