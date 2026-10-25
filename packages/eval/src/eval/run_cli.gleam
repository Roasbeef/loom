//// The runner's command line.
////
////     gleam run -m eval/run_cli -- run <plan.json> [--out DIR] [--tasks DIR]
////       [--arms DIR] [--config loom.toml] [--helper PATH] [--seed DIR]
////       [--tapes DIR] [--record DIR] [--repo NAME=PATH]...
////     gleam run -m eval/run_cli -- report <run-dir>
////
//// `run` loads a plan and the tasks and arms it names, builds the session
//// settings every arm starts from, runs or resumes the plan, and writes the
//// report. A live plan takes its models from `--config` (a `loom.toml`
//// catalogue) and its keys from the environment, as a daemon would. A replay
//// plan takes `--tapes`, a directory holding `<task id>/<index>.jsonl`
//// recordings, and needs no key; the catalogue then only names the model the
//// recording was made against. `report` rebuilds the report from a finished
//// or interrupted run directory without running anything.
////
//// The base settings here are the minimum a trial needs and nothing a daemon
//// adds: no peers, no schedules, no memory, no advisor. `trial_settings`
//// strips the same fields again, so this is about what the catalogue and the
//// jail see, not about the trial's own isolation.

import argv
import broker/exec
import broker/policy
import client/catalog.{type Catalog}
import client/codemode
import client/internal/ffi_os
import client/jobs
import client/memory_config
import client/retryconf
import client/schedule
import client/secrets
import client/serve.{type Settings, Settings}
import client/workspace_policy
import core/clock
import eval/cassette
import eval/plan
import eval/report
import eval/repos
import eval/run
import eval/task
import eval/trial
import eval/verify
import gleam/dict
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import machine/operation
import machine/strand
import provider/adapter/anthropic
import provider/http.{type Transport}
import provider/secret.{type SecretStore}
import simplifile

/// The session settings a trial's arms start from.
///
/// `root` is a private directory the settings' session files live under;
/// `helper` is the jail helper binary and `seed` the offline code-mode cache.
/// The first catalogue entry that the main role routes names the model.
///
/// ## Examples
///
/// ```gleam
/// // run_cli.base_settings(catalogue, http.httpc_transport(), secret.env(), "/runs/base", "../sandbox/loom-exec", "../../build/codemode-seed")
/// ```
///
pub fn base_settings(
  catalogue: Catalog,
  transport: Transport,
  secrets: SecretStore,
  root: String,
  helper: String,
  seed: String,
) -> Result(Settings, String) {
  use main <- result.map(
    catalog.main_model(catalogue)
    |> result.replace_error("the catalogue routes no main model"),
  )

  Settings(
    peer_defaults: None,
    remote_reach: None,
    deadline_tick_ms: None,
    depth_cap: None,
    metering: None,
    spawner: None,
    laptop: None,
    profile_desk: None,
    go_caches: None,
    first_prompt: None,
    peer_directory: None,
    codemode_sockets: Some(root <> "/run"),
    secrets:,
    secret_failures: [],
    session_path: root <> "/session.db",
    domain_paths: None,
    bind_host: "127.0.0.1",
    bind_port: 0,
    token_path: root <> "/session.token",
    workspace: root <> "/work",
    // Trials run with the network off: their tasks are prepared on the host
    // beforehand, and a model's own traffic is the harness's, not the jail's.
    base_policy: policy.SandboxPolicy(
      ..workspace_policy.base_policy(root <> "/work"),
      network: policy.NetworkOff,
    ),
    helper_path: helper,
    helper_pool_size: 2,
    session_id: "eval-base",
    demand: exec.PlatformEnforcement,
    gateway: catalog.gateway(
      catalogue,
      transport:,
      secrets:,
      clock: clock.from_function(ffi_os.system_time_ms),
    ),
    evolution_role: serve.Source,
    catalog: catalogue,
    system: None,
    home: Some(root <> "/empty-home"),
    model: strand.ModelIdentity(main.name, main.model_id),
    context_window: main.context_window,
    max_output_tokens: main.max_output_tokens,
    api: anthropic.api_name,
    compaction: operation.CompactionSettings(True, 16_384, 20_000),
    codemode_seed: seed,
    codemode_seams: codemode.WorkspaceOnly,
    rules: [],
    schedules: [],
    schedule_policy: schedule.ModelSchedulesOff,
    jobs_policy: jobs.default_policy,
    retry_policy: retryconf.default_policy,
    deactivated_tools: [],
    memory: memory_config.default_options(),
    tools: catalog.default_tools(),
    advisor: None,
  )
}

/// Dispatches argv; a failure prints its reason on standard error and exits
/// with status 1.
///
/// ## Examples
///
/// ```gleam
/// // gleam run -m eval/run_cli -- report runs/<plan id>
/// ```
///
pub fn main() -> Nil {
  // Success prints one line; any refusal exits nonzero so a script can tell the two apart.
  case dispatch(argv.load().arguments) {
    Ok(line) -> io.println(line)
    Error(reason) -> {
      io.println_error("eval: " <> reason)
      ffi_os.halt(1)
    }
  }
}

/// Routes the arguments to a verb.
fn dispatch(arguments: List(String)) -> Result(String, String) {
  // The two verbs are the only requests; anything else is a usage error.
  case arguments {
    ["run", plan_path, ..flags] -> {
      use #(specs, flags) <- result.try(take_repos(flags, [], []))
      use options <- result.try(parse_flags(flags))
      use known <- result.try(repos.from_flags(specs))
      command_run(
        plan_path,
        repos.with_default(known, secrets.host_runner()),
        options,
      )
    }
    ["report", directory] -> command_report(directory)
    _ ->
      Error(
        "usage: run <plan.json> [--out DIR] [--tasks DIR] [--arms DIR] [--config FILE] [--helper PATH] [--seed DIR] [--tapes DIR] [--record DIR] [--repo NAME=PATH]... | report <run-dir>",
      )
  }
}

type Options =
  dict.Dict(String, String)

/// Splits the repeatable `--repo <name>=<path>` flags from the rest. Every
/// other flag is single-valued and lives in a dictionary, where a repeat
/// would silently overwrite; a repository map needs every occurrence.
fn take_repos(
  flags: List(String),
  specs: List(String),
  others: List(String),
) -> Result(#(List(String), List(String)), String) {
  case flags {
    [] -> Ok(#(list.reverse(specs), list.reverse(others)))
    ["--repo", spec, ..rest] -> take_repos(rest, [spec, ..specs], others)
    ["--repo"] -> Error("flag --repo needs a value")
    [other, ..rest] -> take_repos(rest, specs, [other, ..others])
  }
}

/// Reads `--name value` pairs into a dictionary.
fn parse_flags(flags: List(String)) -> Result(Options, String) {
  case flags {
    [] -> Ok(dict.new())
    [name, value, ..rest] ->
      case string.starts_with(name, "--") {
        True ->
          parse_flags(rest)
          |> result.map(dict.insert(_, string.drop_start(name, 2), value))
        False -> Error("unexpected argument " <> name)
      }
    [name] -> Error("flag " <> name <> " needs a value")
  }
}

/// A flag's value or its default.
fn option(options: Options, name: String, default: String) -> String {
  result.unwrap(dict.get(options, name), default)
}

/// The `report` verb: rebuild the report of a run directory.
fn command_report(directory: String) -> Result(String, String) {
  use inputs <- result.try(run.reload(directory))
  use Nil <- result.map(report.write_run(directory, inputs))

  "wrote " <> directory <> "/report.md"
}

/// The `run` verb: load, build the base settings, pick the lane, execute.
fn command_run(
  plan_path: String,
  known: repos.Repos,
  options: Options,
) -> Result(String, String) {
  use loaded <- result.try(run.load(
    plan_path,
    option(options, "tasks", "tasks"),
    option(options, "arms", "arms"),
  ))
  use warning <- result.try(check_harness(loaded.plan, secrets.host_runner()))
  warn(warning)

  use text <- result.try(
    simplifile.read(option(options, "config", "loom.toml"))
    |> result.map_error(fn(error) {
      "cannot read the catalogue: " <> simplifile.describe_error(error)
    }),
  )
  use catalogue <- result.try(catalog.parse(text))

  use out <- result.try(absolute(option(options, "out", default_out())))
  use helper <- result.try(
    absolute(option(options, "helper", "../sandbox/loom-exec")),
  )
  use seed <- result.try(
    absolute(option(options, "seed", "../../build/codemode-seed")),
  )
  let scratch = out <> "/" <> loaded.plan.id <> "/base"
  use Nil <- result.try(
    simplifile.create_directory_all(scratch)
    |> result.map_error(simplifile.describe_error),
  )
  use base <- result.try(base_settings(
    catalogue,
    http.httpc_transport(),
    secret.env(),
    scratch,
    helper,
    seed,
  ))
  use lane <- result.try(lane_of(loaded.plan, options))

  // The jail is opened only for a plan that has a program verifier, since
  // opening it starts a helper pool; its root is the run directory, which is
  // where every verifier output directory lies.
  let run_directory = out <> "/" <> loaded.plan.id
  use jail <- result.try(open_jail_if_needed(loaded.tasks, base, run_directory))

  let ctx =
    trial.Context(
      base:,
      lane:,
      budgets: loaded.plan.budgets,
      plan_id: loaded.plan.id,
      seams: trial.default_seams(grader_for(jail)),
      repos: known,
      selftest: selftest_of(jail, base),
    )
  let executed = run.execute(ctx, loaded, out)
  let closed = close_jail_if_open(jail)

  use summary <- result.try(executed)
  use Nil <- result.map(closed)

  "ran "
  <> int.to_string(summary.started)
  <> " trials; report at "
  <> summary.directory
  <> "/report.md"
}

/// Prints a harness warning on standard error, when there is one.
fn warn(warning: Option(String)) -> Nil {
  case warning {
    Some(text) -> io.println_error("eval: warning: " <> text)
    None -> Nil
  }
}

/// Checks the tree this process runs from against the harness the plan
/// claims, before any trial is paid for.
///
/// A plan stamps `harness.git_commit` and a `Clean` posture so that a result
/// can be compared with others; running it from some other tree would stamp
/// a reproducibility claim that is false. A `full` plan therefore refuses to
/// run unless `git rev-parse HEAD` equals the stamped commit and, when the
/// plan says `Clean`, `git status --porcelain` is empty. A `quick` plan runs
/// regardless and the mismatch comes back as a warning to print. A tree that
/// cannot be read at all counts as a mismatch, since nothing was verified.
///
/// ## Examples
///
/// ```gleam
/// // run_cli.check_harness(quick_plan, secrets.host_runner()) == Ok(None)
/// // run_cli.check_harness(full_plan_at_other_commit, runner) == Error("...")
/// ```
///
pub fn check_harness(
  frozen: plan.Plan,
  runner: secrets.Runner,
) -> Result(Option(String), String) {
  let problems = harness_problems(frozen.harness, runner)

  // Only a profile that claims comparability turns a mismatch into a refusal.
  case problems, frozen.profile {
    [], _ -> Ok(None)
    [_, ..], plan.Quick -> Ok(Some(string.join(problems, "; ")))
    [_, ..], plan.Full ->
      Error(
        "a full plan refuses to run from a different harness: "
        <> string.join(problems, "; ")
        <> " (re-mint the plan at this commit, or use the quick profile)",
      )
  }
}

/// How the running tree differs from the harness a plan claims.
fn harness_problems(
  claimed: plan.Harness,
  runner: secrets.Runner,
) -> List(String) {
  let head = git_output(runner, ["git", "rev-parse", "HEAD"])
  let status = git_output(runner, ["git", "status", "--porcelain"])

  // The commit must be exactly the one the plan stamped.
  let commit = case head {
    Ok(found) if found == claimed.git_commit -> []
    Ok(found) -> [
      "the plan claims commit "
      <> claimed.git_commit
      <> " but the running tree is at "
      <> found,
    ]
    Error(reason) -> ["cannot read the running tree's commit: " <> reason]
  }

  // Only a plan that claims a clean tree is contradicted by uncommitted changes.
  let posture = case claimed.posture, status {
    plan.Clean, Ok("") -> []
    plan.Clean, Ok(_) -> [
      "the plan claims a clean tree but the running tree has uncommitted changes",
    ]
    plan.Clean, Error(reason) -> [
      "cannot read the running tree's status: " <> reason,
    ]
    plan.Dirty, _ -> []
  }

  list.append(commit, posture)
}

/// One git command's trimmed standard output, or why it did not answer.
fn git_output(
  runner: secrets.Runner,
  argv: List(String),
) -> Result(String, String) {
  use capture <- result.try(runner(argv, 30_000))

  // Only a zero status leaves output worth trusting.
  case capture.status {
    0 -> Ok(string.trim(capture.output))
    status ->
      Error(
        string.join(argv, " ")
        <> " exited "
        <> int.to_string(status)
        <> ": "
        <> string.trim(capture.output),
      )
  }
}

/// Opens the verifier's jail when some task needs one.
fn open_jail_if_needed(
  tasks: List(task.Task),
  base: Settings,
  directory: String,
) -> Result(Option(verify.Jail), String) {
  // Opening a jail starts a helper pool, which an exact-file plan never uses.
  case needs_jail(tasks) {
    True -> verify.open_jail(base, directory) |> result.map(Some)
    False -> Ok(None)
  }
}

/// Closes the jail if one was opened.
fn close_jail_if_open(jail: Option(verify.Jail)) -> Result(Nil, String) {
  // Closing is owed exactly when opening happened.
  case jail {
    Some(open) -> verify.close_jail(open)
    None -> Ok(Nil)
  }
}

/// What the row's jail records: the open-time probe ran `true` under the
/// demanded enforcement when a jail was opened, and nothing otherwise.
fn selftest_of(jail: Option(verify.Jail), base: Settings) -> String {
  // A jail that opened is a jail whose probe passed.
  case jail {
    Some(_) ->
      "verify.open_jail probe: `true` ran under " <> string.inspect(base.demand)
    None -> trial.unprobed
  }
}

/// Whether any task's verifier is a program, which only a jail can run.
fn needs_jail(tasks: List(task.Task)) -> Bool {
  list.any(tasks, fn(each) {
    case each.verifier {
      task.Program(..) -> True
      task.ExpectedFiles(..) -> False
    }
  })
}

/// The grader for program verifiers: the jailed verifier when a jail was
/// opened, otherwise a named refusal.
fn grader_for(jail: Option(verify.Jail)) -> trial.Grader {
  case jail {
    Some(open) -> fn(found, frozen, out, pristine) {
      verify.grade(found, frozen, out, open, pristine)
    }
    None -> trial.refuse_program
  }
}

/// A path made absolute against the working directory.
fn absolute(path: String) -> Result(String, String) {
  case string.starts_with(path, "/") {
    True -> Ok(path)
    False ->
      simplifile.current_directory()
      |> result.map(fn(here) { here <> "/" <> path })
      |> result.map_error(simplifile.describe_error)
  }
}

fn default_out() -> String {
  case workspace_policy.env_text("HOME") {
    Ok(home) -> home <> "/.loom/eval/runs"
    Error(Nil) -> "eval-runs"
  }
}

/// The trial lane a plan's lane needs: replay requires a tape directory, and
/// a live plan with `--record` also writes one tape per cell there.
fn lane_of(frozen: plan.Plan, options: Options) -> Result(trial.Lane, String) {
  // The plan's lane picks the family; `--tapes` feeds a replay and `--record`
  // taps a live run.
  case frozen.lane, dict.get(options, "tapes"), dict.get(options, "record") {
    plan.Live, _, Error(Nil) -> Ok(trial.Live)
    plan.Live, _, Ok(directory) ->
      Ok(trial.Recording(open: record_open(http.httpc_transport(), directory)))
    plan.Replay, Ok(directory), Error(Nil) ->
      Ok(trial.Taped(open: replay_open(directory)))
    plan.Replay, Error(Nil), _ -> Error("a replay plan needs --tapes DIR")
    plan.Replay, _, Ok(_) -> Error("--record is for a live plan")
  }
}

/// Opens a recording transport over the real wire for one cell. The tape is
/// written when the trial's findings are asked for, which is after the
/// session has drained, so every request is on it.
///
/// ## Examples
///
/// ```gleam
/// // run_cli.record_open(http.httpc_transport(), "tapes")
/// ```
///
pub fn record_open(
  inner: Transport,
  directory: String,
) -> fn(plan.RowKey, String) -> Result(trial.Tape, String) {
  fn(key: plan.RowKey, root: String) {
    use sink <- result.map(cassette.start_sink())

    trial.Tape(transport: cassette.recording(inner, root, sink), findings: fn() {
      write_tape(directory, key, sink)
    })
  }
}

/// Writes the finished tape to `<directory>/<task>/<index>.jsonl` and stops
/// the sink; a failure to write is a finding, since the run's point is lost.
fn write_tape(
  directory: String,
  key: plan.RowKey,
  sink: cassette.Sink,
) -> List(String) {
  let collected = cassette.finish(sink)
  cassette.close_sink(sink)
  let folder = directory <> "/" <> key.task

  let written = {
    use tape <- result.try(collected)
    use Nil <- result.try(
      simplifile.create_directory_all(folder)
      |> result.map_error(simplifile.describe_error),
    )

    simplifile.write(
      folder <> "/" <> int.to_string(key.index) <> ".jsonl",
      cassette.tape_to_jsonl(tape),
    )
    |> result.map_error(simplifile.describe_error)
  }

  // A tape that did not reach the disk loses the recording, so it is reported.
  case written {
    Ok(Nil) -> []
    Error(reason) -> ["the tape was not written: " <> reason]
  }
}

/// Opens a replaying transport over the tape recorded for a cell.
///
/// ## Examples
///
/// ```gleam
/// // run_cli.replay_open("tapes")
/// ```
///
pub fn replay_open(
  directory: String,
) -> fn(plan.RowKey, String) -> Result(trial.Tape, String) {
  fn(key: plan.RowKey, root: String) {
    let path =
      directory
      <> "/"
      <> key.task
      <> "/"
      <> int.to_string(key.index)
      <> ".jsonl"

    use text <- result.try(
      simplifile.read(path)
      |> result.map_error(fn(error) {
        "cannot read the tape "
        <> path
        <> ": "
        <> simplifile.describe_error(error)
      }),
    )
    use tape <- result.try(cassette.tape_from_jsonl(text))
    use log <- result.map(cassette.start_log())

    trial.Tape(transport: cassette.replaying(tape, root, log), findings: fn() {
      list.map(cassette.divergences(log), fn(found) {
        "request " <> int.to_string(found.ordinal) <> ": " <> found.summary
      })
    })
  }
}
