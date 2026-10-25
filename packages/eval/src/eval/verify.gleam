//// The hidden verifier: grades one retired trial workspace by running the
//// task's program in a fresh jail, after the agent is gone.
////
//// # Why the grade runs in a jail
////
//// A verifier is operator-authored (a mined task's is the repository's own
//// test runner), and that is not the question Rule Zero asks. Rule Zero is
//// about *where* code runs: a test command executed inside the harness VM
//// would be a hole in the effect plane whatever its provenance, which is
//// the arrangement `client/goalcheck` already refused for the goal check.
//// So a verifier clears through the same seam the `bash` tool and the goal
//// check clear through — `tools/tool.broker_runner` over a real helper
//// pool — under a policy whose only readable and writable root is the copy
//// it grades, with the network off. There is no host fallback: a host that
//// cannot jail the verifier does not grade, and `open_jail` says which
//// layer refused.
////
//// # Why the copy holds only what the agent could not forge
////
//// The agent owned its workspace, so everything in it is adversarial input
//// to the grader: a planted `logs/verifier/reward.json`, a symlink from
//// `test/` to a sibling trial's live tree, a fifo where a hidden file goes,
//// a forged `eunit.beam` under a dependency's `ebin`. The copy the verifier
//// runs in is therefore built by a walk that `lstat`s every entry and keeps
//// only regular files and directories; the agent's `logs/` and every
//// `build/` are dropped; the hidden files are written only after every
//// path component is proved a real directory and the target is unlinked;
//// and the dependency build the verifier compiles against is the pristine
//// one the host prepared from the trusted tree before the agent ran. The
//// host reads the verifier's outputs the same way: `lstat` first, regular
//// files only, a byte cap, never through a link and never from a fifo.
////
//// # What a pass is
////
//// A pass needs all of: the program exited 0; every fail-to-pass and
//// pass-to-pass id the task recorded is parsed from the output as passed
//// (an id the output never names did not pass); and the reward map, when
//// the program wrote one, passes the task's `Scoring`. A run the wall
//// killed is a failed grade with its reason in `side_info`, never an
//// infrastructure error. Only a jail that could not run the command at all
//// is an `Error`, which the runner records as `Infra`.
////
//// The residual the reader should know: code reachable from a fail-to-pass
//// test runs inside the test VM, and nothing stops it printing forged EUnit
//// lines or halting the emulator with status 0. The defence against that
//// is the hidden test bodies — which the agent never saw — and the pristine
//// dependency build, not the output parsing.
////
//// ## Flow
////
//// `open_jail` → `probe`; `grade` → `trusted_runner` → `copy_workspace` →
//// `overlay_builds` → `stage_files` → `run` → `read_output` →
//// `copy_artifacts` → `settle`
////
//// 1. `open_jail` locates the toolchain, builds the root policy with
////    `policy_for`, starts the plane and has `probe` run the shell no-op through `run`;
////    the probe's enforcement report is kept on the jail.
//// 2. `grade` admits the task (`program_of`, `trusted_runner`,
////    `safe_hidden_path`), then builds the copy: `copy_workspace` walks the
////    frozen tree with `copy_entry`, `overlay_builds` lays the pristine
////    `build/` directories over it, and `stage_files` writes the hidden
////    files through `real_parents` and `remove`.
//// 3. `run` builds the `call_spec`, clears it through the broker and
////    collects the settlement; `settled` refuses a run whose report has a
////    `foreign_skips` entry.
//// 4. `read_output` and `copy_artifacts` read the tails and the reward file
////    with `read_regular`; `settle` applies `pass_faults` and writes the
////    grade with `side_info`.
////
//// Purity: this module copies trees, starts a helper pool and clears calls
//// through a broker, so it is an effect module. Nothing it returns depends
//// on anything but its arguments, the task's files and the process it ran.

import broker/broker
import broker/budget
import broker/exec
import broker/policy
import client/codemode
import client/evolution/retirement
import client/evolution/rollout.{type Grade, Grade, ProgramRun}
import client/install
import client/internal/ffi_os
import client/serve.{type Settings}
import client/workspace_plane
import client/workspace_policy
import core/clock
import core/ids
import core/json
import eval/eunit_ids
import eval/git
import eval/task.{
  type Scoring, type Task, AllRewardsOne, AllRewardsPositive, ExpectedFiles,
  Program,
}
import eval/wire
import gleam/bit_array
import gleam/erlang/process
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile
import telemetry/field
import tools/tool
import weft/poll

/// The most bytes of `side_info` a grade carries: the failing test names
/// and a tail of the verifier's output, which is what a reflection reads
/// later. Eight KiB holds the last screen of a test run and nothing a
/// runner would mind storing per row.
pub const max_side_info_bytes = 8192

/// The most bytes of each output stream the host reads back: the jail
/// writes a `tail -c` of this size beside the full stream, and the host
/// refuses a tail file larger than this, so a program cannot make the
/// grader read a gigabyte.
pub const max_stream_bytes = 1_048_576

/// The most bytes a `reward.json` may be before it is refused unread.
pub const max_reward_bytes = 65_536

/// The directory under `<out_dir>` that holds the graded copy.
pub const verify_directory = "verify"

/// The directory under `<out_dir>` the verifier's artifacts are copied to.
pub const artifact_directory = "verifier"

/// Where, inside the copy, the program's output and reward land. The path
/// is Harbor's contract for `reward.json`, and the output streams sit
/// beside it so one directory is the whole record of a run. The agent's
/// own `logs/` is deleted from the copy before the run, so nothing under
/// this path predates the verifier.
pub const log_directory = "logs/verifier"

/// The exit status recorded for a run that produced none, because the wall
/// stopped it. Not a status any process can exit with, so a reader cannot
/// mistake it for the command's own verdict.
pub const no_exit_status = -1

/// How long one clearance may wait on a congested helper pool.
pub const clearance_ms = 5000

/// The helpers a jail holds: one verifier runs at a time, and the second
/// helper is the room the pool needs to retire one and admit the next.
pub const pool_size = 2

/// The one enforcement layer a best-effort jail may lack: the cgroup v2
/// memory and pids ceilings, which a development kernel without a
/// delegated cgroup cannot apply and which no filesystem or network
/// guarantee rests on. Any other skipped layer refuses the run under every
/// demand.
pub const tolerated_skip = "skip:cgroup-v2"

/// A running helper pool and broker that verifier runs clear through, over
/// a root directory every graded copy must sit under.
///
/// The jail is opened once for a run and shared by every grade. Each
/// verifier run is still its own kernel jail — one bubblewrap or Seatbelt
/// confinement per execution — with a policy narrowed to its own copy; what
/// is shared is the pool and the broker, as a session shares them across
/// tool calls.
pub opaque type Jail {
  Jail(
    /// The settings the jail was opened from: the helper, the enforcement
    /// demand and the base policy whose limits and masks carry over.
    settings: Settings,
    /// The directory every `out_dir` must sit under. It is the pool's
    /// writable root, and a grade outside it would be refused by the meet.
    root: String,
    /// The toolchain the jail mounts read-only, found where code mode finds
    /// it, so the verifier's `gleam test` sees the same compiler the agent's
    /// did.
    toolchain: codemode.Toolchain,
    /// The pool, broker and executor, held as the one-shot plane shape
    /// `serve` already names so the broker reaches `tools/tool.broker_runner`.
    plane: serve.BuildPlane,
    /// Retires the plane and answers whether retirement was confirmed.
    close: retirement.Task,
    /// The time base for budget deadlines and operation ids.
    clock: clock.Clock,
    /// The enforcement report of the open-time probe: what the kernel
    /// applied to `true`, which is what it applies to every verifier.
    enforcement: List(String),
  )
}

/// Starts the helper pool and broker verifier runs clear through, under
/// `root`. Refuses, naming the reason, when the helper binary is missing,
/// the toolchain cannot be found, the base policy is one the sandbox
/// cannot enforce, or the pool cannot run `true` under the demanded
/// enforcement — the same refusals a boot makes, in the same order, so a
/// host that cannot jail a verifier learns so before any trial runs.
///
/// `root` must be an absolute path and should be under the operator's
/// home, never `/tmp`, which the jail replaces with its scratch tmpfs.
///
/// ## Examples
///
/// ```gleam
/// // verify.open_jail(settings, home <> "/evalwt/run-7")
/// ```
///
pub fn open_jail(base: Settings, root: String) -> Result(Jail, String) {
  use Nil <- result.try(absolute(root, "jail root"))
  use Nil <- result.try(directory(root))
  use Nil <- result.try(directory(root <> "/tmp"))
  use _helper <- result.try(
    install.existing_file(base.helper_path)
    |> result.map_error(fn(_nil) {
      "the helper binary does not exist: " <> base.helper_path
    }),
  )
  use toolchain <- result.try(toolchain(base))
  use toolchain <- result.try(
    codemode.clear_of(toolchain, writable_roots: [root]),
  )
  let policy = policy_for(root, toolchain, root)
  use Nil <- result.try(workspace_policy.base_policy_fault(policy))
  let wall = clock.from_function(ffi_os.system_time_ms)

  // The plane is the production shape: a pool of real helpers, the executor
  // service over it and one broker in front, so a verifier gets the relay,
  // the settlement guarantees and the enforcement report a tool call gets.
  use #(pool, broker_actor, service) <- result.try(
    workspace_plane.start_effect_plane(
      helper: base.helper_path,
      base_policy: policy,
      tmp_dir: root <> "/tmp",
      size: pool_size,
      clock: wall,
    ),
  )
  let jail =
    Jail(
      settings: base,
      root:,
      toolchain:,
      plane: serve.BuildPlane(
        broker: broker_actor,
        pool:,
        executor: service,
        toolchain:,
        base_policy: policy,
      ),
      close: workspace_plane.retire_effect_plane(broker_actor, pool, service),
      clock: wall,
      enforcement: [],
    )

  // A pool that cannot run `true` under the demanded enforcement is closed
  // again here, so a refusal leaves no helpers behind, and the reason names
  // the layer the helper skipped.
  case probe(jail) {
    Ok(enforcement) -> Ok(Jail(..jail, enforcement:))
    Error(reason) -> {
      let _retired = close_jail(jail)

      Error(reason)
    }
  }
}

/// Retires the jail's pool and broker. `Error` carries the reason retirement
/// could not be confirmed, which is not a grade problem but is worth a line
/// in a run's log: an unconfirmed pool is a helper nobody owns.
///
/// ## Examples
///
/// ```gleam
/// // verify.close_jail(jail) == Ok(Nil)
/// ```
///
pub fn close_jail(jail: Jail) -> Result(Nil, String) {
  retirement.perform(jail.close)
  |> result.map_error(fn(failure) { failure.reason })
}

/// The enforcement report the kernel gave the jail's open-time probe: the
/// layers it applied to `true`, and any it skipped. A proof or a ledger row
/// records it so a reader knows how the grade was jailed.
///
/// ## Examples
///
/// ```gleam
/// // verify.enforcement(jail) == ["bwrap", "mounts:…", "seccomp-net", …]
/// ```
///
pub fn enforcement(jail: Jail) -> List(String) {
  jail.enforcement
}

/// The enforcement demand the jail was opened under, as a word.
///
/// ## Examples
///
/// ```gleam
/// // verify.demand_text(jail) == "platform"
/// ```
///
pub fn demand_text(jail: Jail) -> String {
  case jail.settings.demand {
    exec.FullEnforcement -> "full"
    exec.PlatformEnforcement -> "platform"
    exec.BestEffort -> "best-effort"
  }
}

/// Grades one retired trial. `workspace` is the frozen copy of the agent's
/// tree; its regular files and directories, less `logs/` and every
/// `build/`, are copied to `<out_dir>/verify`, the `build/` directories
/// under `pristine` (the host's prepared build of the trusted tree, when the
/// task has one) are laid over the copy, the task's hidden files are written
/// into it, and the program runs there under a jail whose only readable and
/// writable root is the copy, with the network off and the task's
/// `timeout_ms` as the wall. The verifier's bounded output and `reward.json`
/// are copied to `<out_dir>/verifier/`.
///
/// `Ok` is a grade, including a timed-out or failing one; `Error` means the
/// task cannot be graded as given or the jail could not run the program,
/// which a runner records as `Infra`. Refused before anything runs: an
/// `ExpectedFiles` verifier (the runner grades it in process), an argv that
/// runs a workspace path the task does not stage itself (an agent-owned
/// runner would grade its own work), and a hidden-file path that is not a
/// safe relative path.
///
/// ## Examples
///
/// ```gleam
/// // verify.grade(task, root <> "/frozen", root <> "/out", jail, Some(root <> "/pristine"))
/// // -> Ok(rollout.Grade(1.0, [#("f2p", 1.0), #("p2p", 1.0)], "", ProgramRun(..)))
/// ```
///
pub fn grade(
  task: Task,
  workspace: String,
  out_dir: String,
  jail: Jail,
  pristine: Option(String),
) -> Result(Grade, String) {
  grade_within(task, workspace, out_dir, jail, pristine, default_caps)
}

/// `grade` with the copy walk's caps chosen by the caller, so a test can
/// prove the caps with files kept small on disk.
///
/// ## Examples
///
/// ```gleam
/// // verify.grade_within(task, frozen, out, jail, None, verify.Caps(1000, 5000))
/// ```
///
pub fn grade_within(
  task: Task,
  workspace: String,
  out_dir: String,
  jail: Jail,
  pristine: Option(String),
  caps: Caps,
) -> Result(Grade, String) {
  use program <- result.try(program_of(task))
  use Nil <- result.try(trusted_runner(program))
  use Nil <- result.try(list.try_each(program.files, safe_hidden_path))
  use Nil <- result.try(absolute(out_dir, "out_dir"))
  use Nil <- result.try(under_root(out_dir, jail.root))

  // A ceiling the jail cannot honour is a malformed task, graded zero and
  // named, rather than an execution the broker refuses and the runner
  // records as its own fault.
  case program.timeout_ms > task.max_timeout_ms {
    True -> Ok(over_ceiling(program))
    False -> copy_and_run(program, workspace, out_dir, jail, pristine, caps)
  }
}

/// The zero grade of a task whose wall exceeds `task.max_timeout_ms`.
fn over_ceiling(program: Verifier) -> Grade {
  Grade(
    reward: 0.0,
    scores: [],
    side_info: "malformed task: timeout_ms "
      <> int.to_string(program.timeout_ms)
      <> " exceeds the cap of "
      <> int.to_string(task.max_timeout_ms)
      <> " ms, the jail's wall; the task was not run",
    verifier: ProgramRun(
      argv: program.argv,
      exit_status: no_exit_status,
      wall_ms: 0,
    ),
  )
}

/// Builds the copy, runs the program and settles the grade.
fn copy_and_run(
  program: Verifier,
  workspace: String,
  out_dir: String,
  jail: Jail,
  pristine: Option(String),
  caps: Caps,
) -> Result(Grade, String) {
  let verify_dir = out_dir <> "/" <> verify_directory
  let artifacts = out_dir <> "/" <> artifact_directory
  use dropped <- result.try(copy_workspace(workspace, verify_dir, caps))
  use Nil <- result.try(overlay_builds(pristine, verify_dir))
  use Nil <- result.try(stage_files(verify_dir, program.files))
  use Nil <- result.try(directory(artifacts))

  // The run happens after the copy is complete and the hidden files are in
  // it, and the artifacts are copied out after the run: the order is the
  // hidden-verifier guarantee made mechanical.
  let ran = run(jail, verify_dir, program.argv, program.timeout_ms)
  let output = read_output(verify_dir)
  use Nil <- result.try(copy_artifacts(verify_dir, artifacts))

  settle(program, ran, output, verify_dir, dropped)
}

/// The verifier parts of a task, or the refusal for a task graded in
/// process.
fn program_of(task: Task) -> Result(Verifier, String) {
  case task.verifier {
    ExpectedFiles(expected: _) ->
      Error("expected-files verifier is graded in process, not in a jail")

    Program(files:, argv:, fail_to_pass:, pass_to_pass:, timeout_ms:, scoring:) ->
      Ok(Verifier(
        files:,
        argv:,
        fail_to_pass:,
        pass_to_pass:,
        timeout_ms:,
        scoring:,
      ))
  }
}

/// The `Program` variant's fields as one record, so the stages below take
/// one argument instead of six.
type Verifier {
  Verifier(
    files: List(#(String, String)),
    argv: List(String),
    fail_to_pass: List(String),
    pass_to_pass: List(String),
    timeout_ms: Int,
    scoring: Scoring,
  )
}

/// What one run of the program came back as, with its wall time.
type Ran {
  /// The helper reported an exit: a status, or a wall-stopped run whose
  /// result says `timed_out`.
  Exited(result: exec.ExecResult, wall_ms: Int)

  /// No exit was reported: the clearance was refused, the execution
  /// settled as a failure, or the settlement never came.
  Stopped(reason: String, wall_ms: Int)
}

/// The program's two streams as the host read them back: each a bounded
/// tail, or the reason it was not read.
type Output {
  Output(stdout: Result(String, String), stderr: Result(String, String))
}

/// What the copy walk left out of the agent's tree. Reported in
/// `side_info`, because a verifier that failed for want of a symlinked
/// fixture should say so.
pub type Dropped {
  Dropped(
    /// Symbolic links, never followed.
    symlinks: Int,
    /// Fifos, sockets and devices.
    specials: Int,
    /// `build/` directories at any depth, and the top-level `logs/`.
    directories: Int,
    /// Regular files over the per-file cap, or past the copy's cap.
    oversize: Int,
    /// Bytes copied so far, which the copy cap is checked against.
    bytes: Int,
  )
}

/// Nothing dropped and nothing copied yet: where a walk starts.
const nothing_dropped = Dropped(0, 0, 0, 0, 0)

/// How much of the agent's tree the copy walk will read: the most bytes of
/// one file, and the most bytes of the whole copy. A file over the first or
/// a tree past the second is dropped and counted rather than read, so an
/// agent cannot make the grader read a gigabyte or fill the disk twice over.
pub type Caps {
  Caps(
    /// The most bytes one regular file may hold to be copied.
    file_bytes: Int,
    /// The most bytes the whole copy may hold.
    copy_bytes: Int,
  )
}

/// The production caps: 64 MiB per file and 1 GiB per copy.
///
/// ## Examples
///
/// ```gleam
/// assert verify.default_caps.file_bytes == 67_108_864
/// ```
///
pub const default_caps = Caps(file_bytes: 67_108_864, copy_bytes: 1_073_741_824)

// --- admission ------------------------------------------------------------

/// Refuses a program whose argv runs a path inside the workspace that the
/// task does not stage itself. The agent owned the workspace, so a runner
/// read from it — `scripts/test.sh`, `./run_tests` — is the agent grading
/// its own work; a runner the task carries in `files` is written over
/// whatever the agent left and is the task's own.
///
/// What is run is what stands in command position: the argv's program, the
/// script an interpreter is handed (`bash scripts/test.sh`), and, inside a
/// `-c` script, every token that opens a command (`./x && bash y/z`). A
/// relative path with a slash in such a position must be staged; arguments
/// (`test -f build/x`, `cat logs/verifier/out`) are the program's own
/// business and are not read here.
fn trusted_runner(program: Verifier) -> Result(Nil, String) {
  let staged = list.map(program.files, fn(file) { file.0 })
  let untrusted =
    command_paths(program.argv)
    |> list.filter(fn(path) { !list.contains(staged, path) })

  // The first unstaged path names the refusal.
  case untrusted {
    [] -> Ok(Nil)
    [path, ..] ->
      Error(
        "the verifier runs `"
        <> path
        <> "` from the workspace, which the agent owned; a runner must be "
        <> "among the task's hidden files",
      )
  }
}

/// The workspace-relative paths an argv runs: its program when that is a
/// path, the script handed to an interpreter, and the command-position
/// tokens of a `-c` script.
///
/// ## Examples
///
/// ```gleam
/// assert verify.command_paths(["bash", "scripts/test.sh", "m"]) == ["scripts/test.sh"]
/// assert verify.command_paths(["bash", "-c", "test -f a/b && ./run x"]) == ["run"]
/// assert verify.command_paths(["true"]) == []
/// ```
///
pub fn command_paths(argv: List(String)) -> List(String) {
  case argv {
    [] -> []
    [program, ..arguments] ->
      list.flatten([
        relative_path(program),
        // An interpreter runs its first non-option argument; a `-c` hands
        // it a script whose own commands are read.
        case is_interpreter(program), arguments {
          True, ["-c", script, ..] -> script_paths(script)
          True, ["-o", _option, "-c", script, ..] -> script_paths(script)
          True, [first, ..] -> relative_path(first)
          True, [] -> []
          False, _ -> []
        },
      ])
  }
}

/// Whether a program runs what it is handed next.
fn is_interpreter(program: String) -> Bool {
  list.contains(
    ["bash", "sh", "dash", "zsh", "python", "python3", "env", "exec", "source"],
    program,
  )
}

/// The command-position paths of a shell script: the first token and every
/// token after a command separator, each followed through an interpreter
/// to the script it runs.
fn script_paths(script: String) -> List(String) {
  let tokens =
    script
    |> string.replace("\n", " ")
    |> string.replace("\t", " ")
    |> string.replace(";", " ; ")
    |> string.replace("(", " ( ")
    |> string.replace(")", " ) ")
    |> string.split(" ")
    |> list.map(string.replace(_, "'", ""))
    |> list.map(string.replace(_, "\"", ""))
    |> list.filter(fn(token) { token != "" })

  walk_commands(tokens, Opening, [])
}

/// Where the script walk stands: at the start of a command, or inside one.
type Position {
  Opening
  InsideCommand
  AfterInterpreter
}

/// Walks tokens, collecting the path-like token that opens each command and
/// the one an interpreter is handed.
fn walk_commands(
  tokens: List(String),
  position: Position,
  found: List(String),
) -> List(String) {
  case tokens {
    [] -> list.reverse(found)
    [token, ..rest] ->
      // A separator reopens; an opening token is a command, which may be an
      // interpreter whose next token is the script.
      case is_separator(token), position {
        True, _ -> walk_commands(rest, Opening, found)
        False, Opening | False, AfterInterpreter ->
          walk_commands(rest, after_command(token), opened(token, found))
        False, InsideCommand -> walk_commands(rest, InsideCommand, found)
      }
  }
}

/// Where the walk stands after a command token: an interpreter hands the
/// next token a script, anything else is inside its own arguments.
fn after_command(token: String) -> Position {
  case is_interpreter(token) {
    True -> AfterInterpreter
    False -> InsideCommand
  }
}

/// The found list with a command token's path added, unless the token is
/// an option (`-c`), which opens nothing.
fn opened(token: String, found: List(String)) -> List(String) {
  case string.starts_with(token, "-") {
    True -> found
    False -> list.append(list.reverse(relative_path(token)), found)
  }
}

/// Whether a token ends one command and opens the next.
fn is_separator(token: String) -> Bool {
  list.contains(["&&", "||", ";", "|", "(", ")", "&"], token)
}

/// A token as a workspace-relative path, `./` removed: a slash makes it a
/// path, and a leading `/`, `-` or `$` makes it an absolute path, an option
/// or a variable, which are not the workspace's.
fn relative_path(token: String) -> List(String) {
  // `./x` and `x` name the same staged file.
  let bare = case string.starts_with(token, "./") {
    True -> string.drop_start(token, 2)
    False -> token
  }

  // A path is a slash without a prefix that makes it something else.
  case
    string.contains(token, "/")
    && !string.starts_with(token, "/")
    && !string.starts_with(token, "-")
    && !string.starts_with(token, "$")
    && !string.contains(token, "://")
  {
    True -> [bare]
    False -> []
  }
}

/// Refuses a hidden-file path the copy must not receive: anything the task
/// codec would refuse, re-checked here because a task built in code never
/// went through the codec, and a `..` here is a write outside the copy.
fn safe_hidden_path(file: #(String, String)) -> Result(Nil, String) {
  case wire.safe_path(file.0) {
    True -> Ok(Nil)
    False -> Error("unsafe hidden file path: " <> file.0)
  }
}

// --- the jailed run -------------------------------------------------------

/// Runs `argv` in `dir` through the broker: the `bash` tool's own clearance
/// and settlement, under requirements whose only roots are `dir`, with the
/// network off and the wall at `timeout_ms`. The command redirects the
/// program's streams into the copy's `logs/verifier/` and leaves a bounded
/// tail of each beside them, so the host never reads more than
/// `max_stream_bytes` of either.
///
/// Stdin is closed before the collector starts, as the goal check does,
/// because a program that reads it — a pager, a prompt a script did not
/// expect to be absent — would otherwise sit against an open pipe until
/// the wall killed it and be graded as too slow.
fn run(jail: Jail, dir: String, argv: List(String), timeout_ms: Int) -> Ran {
  let monotonic = poll.monotonic()
  let started = monotonic.now()
  let events = process.new_subject()
  let clear =
    tool.broker_runner(broker: jail.plane.broker, waiting: clearance_ms)
  let now = monotonic.now
  let elapsed = fn() { now() - started }

  // A refusal is a decision more time cannot change: a fresh operation
  // holds no slot another call could be draining, so there is nothing to
  // wait out.
  case clear(call_spec(jail, dir, argv, timeout_ms), events) {
    Error(refusal) ->
      Stopped(
        reason: "the broker refused the verifier: " <> string.inspect(refusal),
        wall_ms: elapsed(),
      )

    Ok(call) -> {
      call.stdin(<<>>, True)

      // One settlement per clearance is the broker's contract; a window with
      // none is the broker breaking it, and the cancel asks the helper to
      // stop whatever is still running.
      case tool.collect_events(events, waiting: timeout_ms + settle_grace_ms) {
        Ok(collected) -> settled(collected, elapsed())
        Error(Nil) -> {
          call.cancel()
          Stopped(
            reason: "the sandbox did not settle the verifier",
            wall_ms: elapsed(),
          )
        }
      }
    }
  }
}

/// The collected call as a run: a status, or the reason there is none. An
/// exit whose enforcement report skipped a layer other than the tolerated
/// one is not a status: a best-effort helper accepts any report, and the
/// grade must not stand on a run that lacked its filesystem or network
/// jail.
fn settled(collected: tool.Collected, wall_ms: Int) -> Ran {
  case collected.outcome {
    broker.CallExited(result:) ->
      // Only the cgroup ceilings may be missing; any other skip is a run
      // that was not jailed as promised.
      case foreign_skips(result.enforcement) {
        [] -> Exited(result:, wall_ms:)
        skips ->
          Stopped(
            reason: "the verifier ran without a required enforcement layer: "
              <> string.join(skips, "; "),
            wall_ms:,
          )
      }
    broker.CallFailed(failure:) ->
      Stopped(reason: failure_text(failure), wall_ms:)
  }
}

/// The `skip:` entries of an enforcement report other than the tolerated
/// cgroup v2 one.
///
/// ## Examples
///
/// ```gleam
/// assert verify.foreign_skips(["bwrap", "skip:cgroup-v2: no cgroup"]) == []
/// assert verify.foreign_skips(["skip:seccomp-net: x"]) == ["skip:seccomp-net: x"]
/// ```
///
pub fn foreign_skips(enforcement: List(String)) -> List(String) {
  list.filter(enforcement, fn(entry) {
    string.starts_with(entry, exec.skip_prefix)
    && !string.starts_with(entry, tolerated_skip)
  })
}

/// The spec for one verifier call. The base is the pool's own (the jail
/// root), the requirements are narrowed to the copy, and composition takes
/// the meet, so a copy outside the root is refused rather than run wide.
/// The wall and the output ceiling are the two limits that move; the rest
/// are the base's.
fn call_spec(
  jail: Jail,
  dir: String,
  argv: List(String),
  timeout_ms: Int,
) -> broker.CallSpec {
  let #(now, _clock) = clock.read(jail.clock)
  let #(op_id, _generator) =
    ids.mint_op(ids.generator(
      jail.clock,
      seed: ffi_os.unique_positive_integer(),
    ))
  let env = environment(jail)
  let narrowed = policy_for(jail.root, jail.toolchain, dir)
  let requirements =
    policy.SandboxPolicy(
      ..narrowed,
      env_allow: list.map(env, fn(pair) { pair.0 }),
      limits: policy.Limits(
        ..narrowed.limits,
        wall_s: { timeout_ms + 999 } / 1000,
        output_bytes:,
      ),
    )

  broker.CallSpec(
    op_id:,
    step_id:,
    base_policy: jail.plane.base_policy,
    requirements:,
    grants: [],
    response: broker.RefuseNarrowed,
    demand: jail.settings.demand,
    // The `bash` tool's own invocation: `pipefail` so a failing stage of a
    // piped runner is not reported as its passing tail, and no login shell
    // so a profile cannot rewrite the `PATH` the jail composed.
    argv: ["bash", "-o", "pipefail", "-c", command(argv)],
    env:,
    cwd: dir,
    budget: budget.Budget(max_outstanding: 1, deadline_ms: now + timeout_ms),
  )
}

/// The step every verifier clears under. Its own name, because the pooled
/// budget follows the operation-and-step pair and each grade mints a fresh
/// operation: no verifier ever queues behind another's drain.
const step_id = "eval-verify"

/// The ceiling on each captured stream. The streams are redirected into
/// the copy, so what the relay carries is what escaped the redirect: the
/// shell's own complaints, bounded well below the pool's default.
const output_bytes = 1_048_576

/// The grace past the wall the collector waits for a settlement: the
/// helper's cancel ladder needs a moment to climb from TERM to KILL.
const settle_grace_ms = 10_000

/// Why a call produced no exit status, in the words the runner's `Infra`
/// row and a refusing `open_jail` carry. A degraded execution names the
/// layers the report skipped, because the layer is the remedy: a reader
/// who sees `skip:cgroup-v2` knows to delegate a cgroup or to accept
/// best-effort enforcement, and one who sees "degraded" alone knows
/// nothing.
fn failure_text(failure: exec.ExecFailure) -> String {
  case failure {
    exec.DegradedExecution(result:) ->
      tool.exec_failure_text(failure)
      <> ": "
      <> string.join(skipped_layers(result.enforcement), "; ")
    exec.DegradedHelper(features:) ->
      tool.exec_failure_text(failure) <> ": " <> string.join(features, "; ")
    exec.NotReady
    | exec.HandshakeTimeout
    | exec.HelperBusy
    | exec.RefusedByHelper(code: _, message: _)
    | exec.ChannelFault(fault: _)
    | exec.ChannelClosed(status: _)
    | exec.ProtocolViolation(kind: _)
    | exec.ProtocolVersionMismatch(helper: _, broker: _)
    | exec.SendFailed
    | exec.CancelEscalated
    | exec.HeartbeatMissed
    | exec.HelperUnresponsive
    | exec.ExecutionLost(cause: _) -> tool.exec_failure_text(failure)
  }
}

/// The entries of an enforcement report that begin with `skip:`, or the
/// whole report when none does (a required layer the report never
/// mentioned is then the finding, and the report is the evidence).
fn skipped_layers(enforcement: List(String)) -> List(String) {
  case list.filter(enforcement, string.starts_with(_, exec.skip_prefix)) {
    [] -> enforcement
    skips -> skips
  }
}

/// Proves the jail can run a program at all before any grade depends on
/// it: `true` under the same demand, policy and mounts a verifier gets, and
/// answers the enforcement report the kernel gave it. A host whose helper
/// reports a layer it could not apply — the cgroup v2 ceilings on a kernel
/// with no delegated cgroup, under platform enforcement; any other layer
/// under best effort — refuses here, with the skipped layer in the reason,
/// rather than at the first trial's grade.
fn probe(jail: Jail) -> Result(List(String), String) {
  let dir = jail.root <> "/probe"
  use Nil <- result.try(directory(dir))

  // A status is the pool working; anything else is the refusal the caller
  // is told, with the layer in it.
  case run(jail, dir, ["true"], probe_timeout_ms) {
    Exited(result:, wall_ms: _) ->
      case result.code {
        0 -> Ok(result.enforcement)
        code ->
          Error("the jail ran `true` and it exited " <> int.to_string(code))
      }
    Stopped(reason:, wall_ms: _) ->
      Error("this host cannot jail a verifier: " <> reason)
  }
}

/// How long the open-time probe may take: `true` under a cold pool.
const probe_timeout_ms = 30_000

/// The shell line the call executes: the program with its streams
/// redirected into the copy's log directory, then a bounded tail of each
/// stream written beside it for the host to read. The program runs in a
/// subshell so its exit status survives the tails, and that status is the
/// shell's: the status the grade reads is the verifier's own.
fn command(argv: List(String)) -> String {
  let logs = git.shell_quote(log_directory)
  let stream = fn(name) { git.shell_quote(log_directory <> "/" <> name) }
  let tail = fn(name) {
    "tail -c "
    <> int.to_string(max_stream_bytes)
    <> " "
    <> stream(name)
    <> " > "
    <> stream(name <> ".tail")
  }

  "mkdir -p "
  <> logs
  <> " && ( exec "
  <> git.quoted(argv)
  <> " ) >"
  <> stream("stdout")
  <> " 2>"
  <> stream("stderr")
  <> "; status=$?; "
  <> tail("stdout")
  <> "; "
  <> tail("stderr")
  <> "; exit $status"
}

/// The policy a run under `dir` clears against: the evolution trial's own
/// shape (readable and writable roots are `dir` alone, scratch is a fresh
/// tmpfs) over a network-off base, with the toolchain admitted read-only.
///
/// The base is the build plane's rather than the session's because the
/// session's base says what network the operator allowed the agent, and a
/// verifier gets none whatever that was. Its limits are the defaults every
/// session base starts from, and `task.max_timeout_ms` is held under the
/// default wall so a valid task is never refused by the meet.
fn policy_for(
  root: String,
  toolchain: codemode.Toolchain,
  dir: String,
) -> policy.SandboxPolicy {
  let state_root = root <> "/state"
  let trials = root <> "/trials"

  workspace_policy.build_plane_policy(root, state_root)
  |> serve.evolution_trial_policy(trials, dir)
  |> workspace_policy.admitting_codemode(Ok(toolchain))
  |> workspace_policy.merging_mounts
}

/// The child environment: the toolchain's `PATH`, a `HOME` outside every
/// readable root so a verifier that writes to it is refused, and the two
/// locale names a test runner reads.
fn environment(jail: Jail) -> List(#(String, String)) {
  [
    #("PATH", codemode.toolchain_path(jail.toolchain)),
    #("HOME", jail.root <> "/home"),
    #("LANG", "C.UTF-8"),
    #("TERM", "dumb"),
  ]
}

/// Where `gleam` and `erl` are on this host, as code mode locates them: a
/// release's bundled copies first, then `PATH`. The seed slot names the
/// configured code-mode seed when it exists and the compiler's own
/// directory otherwise, which `toolchain_mounts` folds into the regions it
/// already names; a verifier compiles against the workspace's warm build,
/// not a seed.
fn toolchain(settings: Settings) -> Result(codemode.Toolchain, String) {
  use gleam_path <- result.try(codemode.locate(
    "gleam",
    beside: install.gleam_compiler(),
    remedy: "the verifier runs the workspace's own tests with it",
  ))
  use erl_path <- result.try(codemode.locate(
    "erl",
    beside: install.erl(),
    remedy: "the verifier runs the workspace's own tests on it",
  ))

  // A configured seed is mounted only when it is an absolute directory: a
  // relative one would reach the helper as a path it refuses, and an absent
  // one as a required mount that fails every dispatch.
  let seed_root = case
    string.starts_with(settings.codemode_seed, "/")
    && simplifile.is_directory(settings.codemode_seed) == Ok(True)
  {
    True -> settings.codemode_seed
    False -> parent_of(gleam_path)
  }

  Ok(codemode.toolchain(gleam_path:, erl_path:, seed_root:))
}

// --- settling a run -------------------------------------------------------

/// Turns a run into a grade. An exit is graded by the pass rule; a run the
/// wall stopped is a zero grade that says so; anything else is the jail
/// failing to run the program, which is the caller's `Infra`.
fn settle(
  program: Verifier,
  ran: Ran,
  output: Output,
  verify_dir: String,
  dropped: Dropped,
) -> Result(Grade, String) {
  let report =
    eunit_ids.parse(
      stream_text(output.stdout) <> "\n" <> stream_text(output.stderr),
    )
  let tests = test_scores(program, report)

  // An exit is graded; a run with no exit is the jail's failure to run it.
  case ran {
    Exited(result:, wall_ms:) ->
      // The wall is the task's own ceiling, so exceeding it is the work
      // failing to finish, not the harness failing to run it.
      case result.timed_out || result.cancelled {
        True ->
          Ok(Grade(
            reward: 0.0,
            scores: tests,
            side_info: side_info(
              [
                "verifier timed out after "
                <> int.to_string(wall_ms)
                <> " ms (ceiling "
                <> int.to_string(program.timeout_ms)
                <> " ms)",
              ],
              program,
              report,
              output,
              dropped,
            ),
            verifier: ProgramRun(
              argv: program.argv,
              exit_status: no_exit_status,
              wall_ms:,
            ),
          ))

        False -> {
          let map = reward_file(verify_dir)
          let faults = pass_faults(program, result.code, report, map)

          Ok(Grade(
            reward: reward_of(faults),
            scores: list.append(reward_scores(map), tests),
            side_info: side_info(faults, program, report, output, dropped),
            verifier: ProgramRun(
              argv: program.argv,
              exit_status: result.code,
              wall_ms:,
            ),
          ))
        }
      }

    Stopped(reason:, wall_ms: _) -> Error("verifier could not run: " <> reason)
  }
}

/// Why a run is not a pass, each as one line; an empty list is the pass.
/// All three conditions are checked and all are reported, so a run that
/// failed two ways says so once.
fn pass_faults(
  program: Verifier,
  status: Int,
  report: eunit_ids.TestReport,
  map: Result(List(#(String, Float)), RewardFailure),
) -> List(String) {
  list.flatten([
    case status {
      0 -> []
      _nonzero -> ["exit status " <> int.to_string(status)]
    },
    not_passing("fail_to_pass not passing", program.fail_to_pass, report),
    not_passing("pass_to_pass not passing", program.pass_to_pass, report),
    reward_fault(program.scoring, map),
  ])
}

/// The grade a fault list earns: a pass is exactly no fault.
fn reward_of(faults: List(String)) -> Float {
  case faults {
    [] -> 1.0
    _some -> 0.0
  }
}

/// The ids in `ids` the report does not name as passed, as one labelled
/// line, or nothing when all passed.
fn not_passing(
  label: String,
  ids: List(String),
  report: eunit_ids.TestReport,
) -> List(String) {
  case list.filter(ids, fn(id) { !passed(report, id) }) {
    [] -> []
    missed -> [label <> ": " <> string.join(missed, ", ")]
  }
}

/// Whether the report names `id` as passed.
fn passed(report: eunit_ids.TestReport, id: String) -> Bool {
  eunit_ids.outcome(report, id) == Ok(eunit_ids.Passed)
}

/// The reward map's verdict as a fault line: nothing when there is no map
/// or it passes the policy; the policy when it fails; the reason when the
/// file could not be read as a map.
fn reward_fault(
  scoring: Scoring,
  map: Result(List(#(String, Float)), RewardFailure),
) -> List(String) {
  case map {
    Error(RewardAbsent) -> []
    Error(RewardUnreadable(reason:)) -> ["reward.json " <> reason]
    Ok(rewards) ->
      // The map passes the policy or names the policy it failed.
      case reduce(scoring, rewards) == 1.0 {
        True -> []
        False -> ["reward.json fails " <> scoring_text(scoring)]
      }
  }
}

/// A scoring policy as the task file spells it.
fn scoring_text(scoring: Scoring) -> String {
  case scoring {
    AllRewardsOne -> "all_rewards_one"
    AllRewardsPositive -> "all_rewards_positive"
  }
}

/// The reward map's entries as named scores, or none.
fn reward_scores(
  map: Result(List(#(String, Float)), RewardFailure),
) -> List(#(String, Float)) {
  case map {
    Ok(rewards) -> rewards
    Error(RewardAbsent) | Error(RewardUnreadable(reason: _)) -> []
  }
}

/// Reduces a reward map under the task's policy: Harbor's "all rewards
/// one" and nanocodex's "all rewards positive". An empty map is a pass
/// under either, because no reward failed the test.
///
/// ## Examples
///
/// ```gleam
/// assert verify.reduce(task.AllRewardsOne, [#("a", 0.5)]) == 0.0
/// assert verify.reduce(task.AllRewardsPositive, [#("a", 0.5)]) == 1.0
/// ```
///
pub fn reduce(scoring: Scoring, map: List(#(String, Float))) -> Float {
  // The policy names the test every entry must meet.
  let passes = case scoring {
    AllRewardsOne -> list.all(map, fn(entry) { entry.1 == 1.0 })
    AllRewardsPositive -> list.all(map, fn(entry) { entry.1 >. 0.0 })
  }

  // One failing entry is a failed grade; the map is never averaged.
  case passes {
    True -> 1.0
    False -> 0.0
  }
}

/// Why no reward map was read.
type RewardFailure {
  /// The program wrote no `reward.json`, which is the ordinary case for a
  /// test runner and means the exit status and the test ids are the grade.
  RewardAbsent

  /// A `reward.json` exists and is not a regular file holding a flat
  /// object of numbers within `max_reward_bytes`.
  RewardUnreadable(reason: String)
}

/// Reads `logs/verifier/reward.json` from the copy as a flat object of
/// numbers: a regular file only, at most `max_reward_bytes`, never through
/// a link and never from a fifo. Total over the file's bytes: any malformed
/// content is a `RewardUnreadable` naming the fault, never a crash.
fn reward_file(
  verify_dir: String,
) -> Result(List(#(String, Float)), RewardFailure) {
  let path = verify_dir <> "/" <> log_directory <> "/reward.json"

  // No file is the ordinary case; a file is read strictly.
  case read_regular(path, max_reward_bytes) {
    Error(Absent) -> Error(RewardAbsent)
    Error(Unreadable(reason:)) -> Error(RewardUnreadable(reason))
    Ok(text) ->
      parse_rewards(text)
      |> result.map_error(RewardUnreadable)
  }
}

/// Decodes a reward map: an object whose every value is a number. Total
/// over any text.
///
/// ## Examples
///
/// ```gleam
/// assert verify.parse_rewards("{\"a\": 1}") == Ok([#("a", 1.0)])
/// assert verify.parse_rewards("[1]") == Error("is not an object")
/// ```
///
pub fn parse_rewards(text: String) -> Result(List(#(String, Float)), String) {
  use value <- result.try(
    json.parse(text) |> result.replace_error("is not valid JSON"),
  )
  use fields <- result.try(object_fields(value))

  // Every value must be a number; the first that is not names its key.
  list.try_map(fields, fn(field) {
    case field.1 {
      json.Float(value:) -> Ok(#(field.0, value))
      json.Int(value:) -> Ok(#(field.0, int.to_float(value)))
      json.Object(..)
      | json.Array(..)
      | json.String(..)
      | json.Bool(..)
      | json.Null -> Error("field \"" <> field.0 <> "\" is not a number")
    }
  })
}

/// The fields of a JSON object, or the refusal for any other shape.
fn object_fields(
  value: json.JsonValue,
) -> Result(List(#(String, json.JsonValue)), String) {
  case value {
    json.Object(fields:) -> Ok(fields)
    json.Array(..)
    | json.String(..)
    | json.Int(..)
    | json.Float(..)
    | json.Bool(..)
    | json.Null -> Error("is not an object")
  }
}

/// The pass fractions of the task's two test sets as named scores. A set
/// with no members scores 1.0: nothing in it failed.
fn test_scores(
  program: Verifier,
  report: eunit_ids.TestReport,
) -> List(#(String, Float)) {
  [
    #("f2p", fraction_passed(program.fail_to_pass, report)),
    #("p2p", fraction_passed(program.pass_to_pass, report)),
  ]
}

/// The share of `ids` the report names as passed. An id the report never
/// mentions did not pass: a compile failure prints no test lines at all.
fn fraction_passed(ids: List(String), report: eunit_ids.TestReport) -> Float {
  // An empty set has nothing to fail.
  case ids {
    [] -> 1.0
    _some -> {
      let passing = list.count(ids, passed(report, _))

      int.to_float(passing) /. int.to_float(list.length(ids))
    }
  }
}

/// The actionable side information: the faults that kept the run from a
/// pass, what the copy walk dropped, and a scrubbed tail of the output, the
/// whole bounded at `max_side_info_bytes`.
///
/// Faults first and the tail last, so a bound that bites loses the oldest
/// output and never a test name.
fn side_info(
  faults: List(String),
  program: Verifier,
  report: eunit_ids.TestReport,
  output: Output,
  dropped: Dropped,
) -> String {
  let _unused = #(program, report)
  let head =
    list.flatten([faults, dropped_lines(dropped), stream_faults(output)])
    |> string.join("\n")
  let budget = max_side_info_bytes - string.byte_size(head) - 1

  // The tail gets whatever the faults left of the bound.
  case budget > 0 {
    False -> head
    True -> head <> "\n" <> bounded_tail(output, budget)
  }
}

/// One line naming what the copy walk left out, or nothing when it kept
/// everything.
fn dropped_lines(dropped: Dropped) -> List(String) {
  case dropped {
    Dropped(0, 0, 0, 0, _bytes) -> []
    Dropped(symlinks:, specials:, directories:, oversize:, bytes: _) -> [
      "dropped from the copy: "
      <> int.to_string(symlinks)
      <> " symlinks, "
      <> int.to_string(specials)
      <> " special files, "
      <> int.to_string(directories)
      <> " build/logs directories, "
      <> int.to_string(oversize)
      <> " oversize files",
    ]
  }
}

/// A line per stream the host refused to read, naming why.
fn stream_faults(output: Output) -> List(String) {
  list.flatten([
    case output.stdout {
      Ok(_) -> []
      Error(reason) -> ["stdout not read: " <> reason]
    },
    case output.stderr {
      Ok(_) -> []
      Error(reason) -> ["stderr not read: " <> reason]
    },
  ])
}

/// A stream's text, or nothing when it was not read.
fn stream_text(stream: Result(String, String)) -> String {
  result.unwrap(stream, "")
}

/// The last `budget` bytes, at most, of the program's output, with
/// credentials scrubbed before the cut so a clipped token cannot read as an
/// ordinary word.
fn bounded_tail(output: Output, budget: Int) -> String {
  let text =
    string.trim(
      stream_text(output.stdout) <> "\n" <> stream_text(output.stderr),
    )
  let length = string.length(text)
  let tail = string.slice(text, int.max(0, length - budget), budget)

  field.scrub_text(tail)
  |> fit(budget)
}

/// Drops leading characters until the text is within `budget` bytes. The
/// slice above counted graphemes, so multi-byte output can still overrun.
fn fit(text: String, budget: Int) -> String {
  case string.byte_size(text) > budget {
    False -> text
    True -> fit(string.drop_start(text, 1), budget)
  }
}

// --- the filesystem -------------------------------------------------------

/// Copies the frozen workspace to the verify directory: regular files and
/// directories only, modes kept, and the agent's `logs/` and every `build/`
/// left behind. Nothing is followed: a symlink in the agent's tree is a
/// pointer the agent chose, and a fifo is a read that never returns.
fn copy_workspace(
  workspace: String,
  verify_dir: String,
  caps: Caps,
) -> Result(Dropped, String) {
  use Nil <- result.try(real_directory(workspace, "workspace"))
  use Nil <- result.try(absent(verify_dir))
  use Nil <- result.try(directory(parent_of(verify_dir)))
  use Nil <- result.try(create(verify_dir))

  copy_entries(workspace, verify_dir, AtTop, caps, nothing_dropped)
}

/// Where a walk stands, which decides whether `logs` is dropped: only the
/// top-level `logs/` is the verifier's; `build/` is dropped at every depth.
type Depth {
  AtTop
  Below
}

/// Walks one directory's entries into the copy, accumulating what was
/// dropped. Each entry is `lstat`ed and dispatched on what it really is.
fn copy_entries(
  from: String,
  to: String,
  depth: Depth,
  caps: Caps,
  dropped: Dropped,
) -> Result(Dropped, String) {
  use names <- result.try(
    simplifile.read_directory(from)
    |> result.map_error(fn(e) { from <> ": " <> simplifile.describe_error(e) }),
  )

  list.try_fold(list.sort(names, string.compare), dropped, fn(so_far, name) {
    copy_entry(
      from <> "/" <> name,
      to <> "/" <> name,
      name,
      depth,
      caps,
      so_far,
    )
  })
}

/// Copies one entry by what `lstat` says it is. A `build` directory at any
/// depth and the top-level `logs` are dropped and counted; a symlink or a
/// special file is dropped and counted; a regular file within the caps is
/// copied with its mode and one over them is dropped and counted; a
/// directory is created and walked.
fn copy_entry(
  from: String,
  to: String,
  name: String,
  depth: Depth,
  caps: Caps,
  dropped: Dropped,
) -> Result(Dropped, String) {
  use info <- result.try(lstat(from))

  // The kind decides, and a dropped kind never touches the copy.
  case simplifile.file_info_type(info), name, depth {
    simplifile.Directory, "build", _ | simplifile.Directory, "logs", AtTop ->
      Ok(Dropped(..dropped, directories: dropped.directories + 1))

    simplifile.Directory, _, _ -> {
      use Nil <- result.try(create(to))

      copy_entries(from, to, Below, caps, dropped)
    }

    simplifile.File, _, _ ->
      // The size is `lstat`'s, read before a byte of the file is: a file
      // over the cap is never opened.
      case
        info.size > caps.file_bytes
        || dropped.bytes + info.size > caps.copy_bytes
      {
        True -> Ok(Dropped(..dropped, oversize: dropped.oversize + 1))
        False -> {
          use Nil <- result.try(copy_file(from, to, info))

          Ok(Dropped(..dropped, bytes: dropped.bytes + info.size))
        }
      }

    simplifile.Symlink, _, _ ->
      Ok(Dropped(..dropped, symlinks: dropped.symlinks + 1))

    simplifile.Other, _, _ ->
      Ok(Dropped(..dropped, specials: dropped.specials + 1))
  }
}

/// Copies one regular file's bytes and permission bits.
fn copy_file(
  from: String,
  to: String,
  info: simplifile.FileInfo,
) -> Result(Nil, String) {
  use bytes <- result.try(
    simplifile.read_bits(from)
    |> result.map_error(fn(e) { from <> ": " <> simplifile.describe_error(e) }),
  )
  use Nil <- result.try(
    simplifile.write_bits(to, bytes)
    |> result.map_error(fn(e) { to <> ": " <> simplifile.describe_error(e) }),
  )

  simplifile.set_permissions_octal(
    to,
    simplifile.file_info_permissions_octal(info),
  )
  |> result.map_error(fn(e) { to <> ": " <> simplifile.describe_error(e) })
}

/// Lays the pristine build directories over the copy. `pristine` is a tree
/// prepared on the host from the trusted starting tree before the agent ran
/// (`eval/materialise` writes it beside the workspace); every `build/` in
/// it, to three levels down, replaces whatever the copy has at that path,
/// which the walk already dropped. A task with no pristine tree — an inline
/// fixture — gets nothing laid over.
fn overlay_builds(
  pristine: Option(String),
  verify_dir: String,
) -> Result(Nil, String) {
  // No pristine tree, nothing laid over.
  case pristine {
    None -> Ok(Nil)
    Some(root) -> {
      use Nil <- result.try(real_directory(root, "pristine tree"))

      build_directories(root, "", 3)
      |> list.try_each(fn(relative) {
        let target = verify_dir <> "/" <> relative
        use Nil <- result.try(remove(target))
        use Nil <- result.try(directory(parent_of(target)))
        use Nil <- result.try(create(target))
        use _dropped <- result.try(copy_entries(
          root <> "/" <> relative,
          target,
          Below,
          default_caps,
          nothing_dropped,
        ))

        Ok(Nil)
      })
    }
  }
}

/// The relative paths of the `build` directories under `root`, to `depth`
/// levels, found without following links.
fn build_directories(
  root: String,
  relative: String,
  depth: Int,
) -> List(String) {
  let here = joined(root, relative)
  let names = result.unwrap(simplifile.read_directory(here), [])

  // Below the depth limit there is nothing more to look for.
  case depth {
    0 -> []
    _ ->
      list.flat_map(names, fn(name) {
        let child = joined(relative, name)
        let kind =
          lstat(here <> "/" <> name) |> result.map(simplifile.file_info_type)

        // A `build` is taken whole; any other real directory is searched.
        case kind, name {
          Ok(simplifile.Directory), "build" -> [child]
          Ok(simplifile.Directory), _ ->
            build_directories(root, child, depth - 1)
          Ok(simplifile.File), _
          | Ok(simplifile.Symlink), _
          | Ok(simplifile.Other), _
          | Error(_), _
          -> []
        }
      })
  }
}

/// `base/name`, or `name` alone when the base is empty.
fn joined(base: String, name: String) -> String {
  case base {
    "" -> name
    _ -> base <> "/" <> name
  }
}

/// Writes the hidden files into the copy. Every path component below the
/// copy is proved a real directory (or created), the target is unlinked
/// whatever it was, and only then is the file written: never through a
/// link the agent left, never into a fifo, never over a directory in
/// place. The task's bytes are the verifier, whatever the agent left at
/// that path.
fn stage_files(
  dir: String,
  files: List(#(String, String)),
) -> Result(Nil, String) {
  list.try_each(files, fn(file) {
    let target = dir <> "/" <> file.0
    use Nil <- result.try(real_parents(dir, parent_of(file.0)))
    use Nil <- result.try(remove(target))

    simplifile.write(target, file.1)
    |> result.map_error(fn(e) { target <> ": " <> simplifile.describe_error(e) })
  })
}

/// Walks `relative`'s components under `dir`, creating each that is absent
/// and refusing any that exists as something other than a real directory.
fn real_parents(dir: String, relative: String) -> Result(Nil, String) {
  case relative {
    "" -> Ok(Nil)
    _ ->
      string.split(relative, "/")
      |> list.try_fold(dir, fn(parent, component) {
        let path = parent <> "/" <> component

        // Absent is created; a real directory is passed through; anything
        // else is a path the agent planted.
        case lstat(path) {
          Error(_absent) -> create(path) |> result.map(fn(_) { path })
          Ok(info) ->
            case simplifile.file_info_type(info) {
              simplifile.Directory -> Ok(path)
              simplifile.File | simplifile.Symlink | simplifile.Other ->
                Error("hidden file path component is not a directory: " <> path)
            }
        }
      })
      |> result.map(fn(_) { Nil })
  }
}

/// Removes whatever stands at `path`, by what `lstat` says it is: a link,
/// file or special is unlinked, a real directory is removed with its
/// contents, and nothing is followed. Absent is fine.
fn remove(path: String) -> Result(Nil, String) {
  case lstat(path) {
    Error(_absent) -> Ok(Nil)
    Ok(info) ->
      // A directory is the one kind that needs the recursive delete; every
      // other kind is a single unlink.
      case simplifile.file_info_type(info) {
        simplifile.Directory ->
          simplifile.delete(path)
          |> result.map_error(fn(e) {
            path <> ": " <> simplifile.describe_error(e)
          })
        simplifile.File | simplifile.Symlink | simplifile.Other ->
          simplifile.delete_file(path)
          |> result.map_error(fn(e) {
            path <> ": " <> simplifile.describe_error(e)
          })
      }
  }
}

/// Copies the verifier's bounded outputs out of the copy: the two stream
/// tails and the reward file, each read as a regular file under its cap or
/// not at all. Nothing else under `logs/verifier/` is copied, because
/// nothing else is the verifier's record.
fn copy_artifacts(
  verify_dir: String,
  artifacts: String,
) -> Result(Nil, String) {
  let logs = verify_dir <> "/" <> log_directory
  let artifact = fn(from, to, cap) {
    case read_regular(logs <> "/" <> from, cap) {
      Ok(text) ->
        simplifile.write(artifacts <> "/" <> to, text)
        |> result.map_error(fn(e) { to <> ": " <> simplifile.describe_error(e) })
      Error(Absent) | Error(Unreadable(reason: _)) -> Ok(Nil)
    }
  }
  use Nil <- result.try(artifact("stdout.tail", "stdout", max_stream_bytes))
  use Nil <- result.try(artifact("stderr.tail", "stderr", max_stream_bytes))

  artifact("reward.json", "reward.json", max_reward_bytes)
}

/// The two stream tails as the run left them, each read strictly.
fn read_output(verify_dir: String) -> Output {
  let stream = fn(name) {
    read_regular(
      verify_dir <> "/" <> log_directory <> "/" <> name <> ".tail",
      max_stream_bytes,
    )
    |> result.map_error(fn(fault) {
      case fault {
        Absent -> "no " <> name <> " was written"
        Unreadable(reason:) -> reason
      }
    })
  }

  Output(stdout: stream("stdout"), stderr: stream("stderr"))
}

/// Why a file the verifier should have left was not read.
type ReadFault {
  /// Nothing is at the path.
  Absent

  /// Something is there that must not be read: not a regular file, over
  /// the cap, or not UTF-8.
  Unreadable(reason: String)
}

/// Reads a file the agent's program may have shaped: `lstat` first, a
/// regular file only, at most `cap` bytes, UTF-8. A link is never followed
/// and a fifo is never opened, so the read cannot block or reach outside
/// the copy.
fn read_regular(path: String, cap: Int) -> Result(String, ReadFault) {
  use info <- result.try(lstat(path) |> result.replace_error(Absent))

  // Only a regular file within the cap is opened at all.
  case simplifile.file_info_type(info), info.size <= cap {
    simplifile.File, True ->
      simplifile.read_bits(path)
      |> result.map_error(fn(e) { Unreadable(simplifile.describe_error(e)) })
      |> result.try(fn(bytes) {
        bit_array.to_string(bytes)
        |> result.replace_error(Unreadable("is not UTF-8"))
      })
    simplifile.File, False ->
      Error(Unreadable(
        "is "
        <> int.to_string(info.size)
        <> " bytes, over the "
        <> int.to_string(cap)
        <> " byte cap",
      ))
    simplifile.Directory, _ -> Error(Unreadable("is a directory"))
    simplifile.Symlink, _ -> Error(Unreadable("is a symlink"))
    simplifile.Other, _ -> Error(Unreadable("is not a regular file"))
  }
}

/// What is at `path` without following a final link.
fn lstat(path: String) -> Result(simplifile.FileInfo, String) {
  simplifile.link_info(path)
  |> result.map_error(fn(e) { path <> ": " <> simplifile.describe_error(e) })
}

/// Refuses a path that is not a real directory.
fn real_directory(path: String, what: String) -> Result(Nil, String) {
  case lstat(path) |> result.map(simplifile.file_info_type) {
    Ok(simplifile.Directory) -> Ok(Nil)
    Ok(simplifile.File)
    | Ok(simplifile.Symlink)
    | Ok(simplifile.Other)
    | Error(_) -> Error(what <> " is not a directory: " <> path)
  }
}

/// Refuses a verify directory that already exists: a grade never lands on
/// top of another's copy.
fn absent(verify_dir: String) -> Result(Nil, String) {
  case lstat(verify_dir) {
    Ok(_) -> Error("verify directory already exists: " <> verify_dir)
    Error(_) -> Ok(Nil)
  }
}

/// Creates one directory, which must not exist.
fn create(path: String) -> Result(Nil, String) {
  simplifile.create_directory(path)
  |> result.map_error(fn(e) { path <> ": " <> simplifile.describe_error(e) })
}

/// Creates a directory and its parents, naming it in the error.
fn directory(path: String) -> Result(Nil, String) {
  simplifile.create_directory_all(path)
  |> result.map_error(fn(e) { path <> ": " <> simplifile.describe_error(e) })
}

/// Refuses a relative path, which the policy could not carry.
fn absolute(path: String, what: String) -> Result(Nil, String) {
  case string.starts_with(path, "/") {
    True -> Ok(Nil)
    False -> Error(what <> " must be an absolute path: " <> path)
  }
}

/// Refuses an output directory the jail's root does not cover: the meet
/// would leave the run with no writable root at all, and the refusal here
/// names the cause.
fn under_root(out_dir: String, root: String) -> Result(Nil, String) {
  case root == out_dir || string.starts_with(out_dir, root <> "/") {
    True -> Ok(Nil)
    False ->
      Error("out_dir " <> out_dir <> " is not under the jail root " <> root)
  }
}

/// The directory holding a path, or `""` for a bare name.
fn parent_of(path: String) -> String {
  path
  |> string.split("/")
  |> list.reverse
  |> list.drop(1)
  |> list.reverse
  |> string.join("/")
}

/// A float as the ledger prints one, for callers that log a grade.
///
/// ## Examples
///
/// ```gleam
/// assert verify.reward_text(1.0) == "1.0"
/// ```
///
pub fn reward_text(reward: Float) -> String {
  float.to_string(reward)
}
