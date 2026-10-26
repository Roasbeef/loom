//// The miner's command line:
//// `gleam run -m eval/mine_cli -- [--repo <name>=<path>]... [--name <name>]
//// --out <dir> [--package a,b] [--limit N] [--commit <hash>] [--work <dir>]`.
////
//// The repository mined is the clone `--repo` maps `--name` to (default
//// `loom`, mapped to the current checkout when no flag names it). The name
//// is what every task records; the path is used here and never written down,
//// so the task set can be proved on any machine that supplies a clone.
////
//// It lists candidates from the repository's history, mines each in turn and
//// writes what came out. Every admitted task is a file `<out>/<id>.json`
//// named for its own digest, so the output directory is also a valid task
//// store; every candidate, admitted or culled, adds one line to
//// `<out>/census.jsonl` with the reason and the timings. The census is
//// appended as the run goes rather than written at the end, so an
//// interrupted run keeps what it learned.
////
//// Candidates run one at a time. Each is a worktree build and two or three
//// test runs, and the runs share a machine's ports and scratch directories;
//// concurrency here would turn a flaky collision into a false cull.

import argv
import client/internal/ffi_os
import client/secrets
import core/json
import eval/git
import eval/mine
import eval/repos
import eval/task
import gleam/int
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import simplifile

/// What the command line asked for.
type Options {
  Options(
    repos: List(String),
    name: String,
    out: String,
    work: String,
    packages: List(String),
    limit: Int,
    commit: String,
  )
}

/// Runs the miner. Usage errors exit 2 and a failed listing exits 1; a
/// culled candidate is data, never a failure.
///
/// ## Examples
///
/// ```gleam
/// // gleam run -m eval/mine_cli -- --repo ../.. --out ~/evalwt/mined --package machine
/// ```
///
pub fn main() -> Nil {
  // A request that does not parse is a usage error, distinct from a run that failed.
  case
    options(
      argv.load().arguments,
      Options([], repos.default_name, "", "", [], 0, ""),
    )
  {
    Error(reason) -> {
      io.println_error("eval/mine_cli: " <> reason)
      io.println_error(
        "usage: [--repo <name>=<path>]... [--name <name>] --out <dir> [--package a,b] [--limit N] [--commit <hash>] [--work <dir>]",
      )
      ffi_os.halt(2)
    }

    Ok(options) ->
      case run(options) {
        Ok(summary) -> io.println(summary)
        Error(reason) -> {
          io.println_error("eval/mine_cli: " <> reason)
          ffi_os.halt(1)
        }
      }
  }
}

/// Reads the flags one at a time into `Options`. Each takes one value; the
/// first unknown flag or missing value is named in the error so a typo is never
/// mistaken for a default.
fn options(
  arguments: List(String),
  so_far: Options,
) -> Result(Options, String) {
  case arguments {
    [] ->
      case so_far.out {
        "" -> Error("--out is required")
        _ -> Ok(so_far)
      }

    ["--repo", value, ..rest] ->
      options(rest, Options(..so_far, repos: [value, ..so_far.repos]))
    ["--name", value, ..rest] -> options(rest, Options(..so_far, name: value))
    ["--out", value, ..rest] -> options(rest, Options(..so_far, out: value))
    ["--work", value, ..rest] -> options(rest, Options(..so_far, work: value))
    ["--commit", value, ..rest] ->
      options(rest, Options(..so_far, commit: value))
    ["--package", value, ..rest] ->
      options(rest, Options(..so_far, packages: string.split(value, ",")))
    ["--limit", value, ..rest] ->
      case int.parse(value) {
        Ok(limit) -> options(rest, Options(..so_far, limit:))
        Error(Nil) -> Error("--limit wants a number, got " <> value)
      }
    [flag, ..] -> Error("unknown or incomplete argument " <> flag)
  }
}

/// Lists the candidates, mines each in turn and writes the output, answering a
/// one-line summary. A failed listing is the only error; a culled candidate is
/// data.
fn run(options: Options) -> Result(String, String) {
  let runner = secrets.host_runner()
  use work <- result.try(work_dir(options, runner))
  use known <- result.try(repos.from_flags(list.reverse(options.repos)))
  let known = repos.with_default(known, runner)
  use repo <- result.try(repos.path(known, options.name))
  let config =
    mine.Config(
      name: options.name,
      repo:,
      work:,
      runner:,
      run_timeout_ms: 1_800_000,
    )

  use _ <- result.try(
    simplifile.create_directory_all(options.out)
    |> result.map_error(fn(e) { simplifile.describe_error(e) }),
  )
  use found <- result.try(mine.candidates(config, "HEAD", options.packages))

  let chosen =
    found
    |> list.filter(fn(candidate) {
      options.commit == "" || candidate.commit == options.commit
    })
    |> take(options.limit)
  let results =
    list.map(chosen, fn(candidate) { record(options, config, candidate) })
  let admitted = list.count(results, fn(admitted) { admitted })

  Ok(
    "mined "
    <> int.to_string(list.length(results))
    <> " candidates, admitted "
    <> int.to_string(admitted),
  )
}

fn take(items: List(a), limit: Int) -> List(a) {
  case limit > 0 {
    True -> list.take(items, limit)
    False -> items
  }
}

/// The directory for worktrees and patch files: as given, else
/// `$HOME/evalwt/mine`. It is under the home directory because the code-mode
/// jail replaces `/tmp`.
fn work_dir(
  options: Options,
  runner: secrets.Runner,
) -> Result(String, String) {
  // An explicit directory is used as given, the default is under the home directory.
  case options.work {
    "" -> {
      use capture <- result.map(runner(
        ["bash", "-c", "printf %s \"$HOME\""],
        10_000,
      ))
      capture.output <> "/evalwt/mine"
    }
    given -> Ok(given)
  }
}

/// Mines one candidate, writes its task file and census line, and answers
/// whether it was admitted. A write failure is printed rather than raised:
/// losing one task file must not discard the hours the other candidates took.
fn record(
  options: Options,
  config: mine.Config,
  candidate: git.Candidate,
) -> Bool {
  let mined = mine.mine(config, candidate)
  let line = mine.census_line(mined) <> "\n"
  io.println(line)

  // Only an admitted task has a file to write.
  let written = case mined.result {
    Ok(minted) ->
      simplifile.write(
        options.out <> "/" <> mine.task_file(minted),
        json.to_string(task.to_json(minted)),
      )
    Error(_) -> Ok(Nil)
  }

  let appended = simplifile.append(options.out <> "/census.jsonl", line)

  // Both writes must succeed for the output to be complete; either failing is reported once.
  case written, appended {
    Ok(Nil), Ok(Nil) -> Nil
    _, _ ->
      io.println_error(
        "eval/mine_cli: could not write output for " <> candidate.commit,
      )
  }

  result.is_ok(mined.result)
}
