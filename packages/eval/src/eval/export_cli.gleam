//// The exporter's command line:
//// `gleam run -m eval/export_cli -- atif <session.db> <out.json>` and
//// `gleam run -m eval/export_cli -- harbor --tasks <dir> --out <dir>
//// --repo-url <url> --base-image <ref> [--repo <name>=<path>]...`.
////
//// Both modes read finished evidence and write files; neither runs a trial,
//// builds an image or contacts a service. A task that cannot be exported
//// (unreadable file, unusable URL) is reported on its own and the rest are
//// still written, because one bad task file should not hide forty good ones;
//// the exit status is nonzero when any failed.

import argv
import client/internal/ffi_os
import client/secrets
import eval/atif
import eval/harbor
import eval/repos
import eval/task
import gleam/int
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import simplifile

/// What a harbor export was asked for.
type Request {
  Request(
    tasks: String,
    out: String,
    options: harbor.Options,
    repos: List(String),
  )
}

/// Runs the exporter. Usage errors exit 2, a failed export exits 1.
///
/// ## Examples
///
/// ```gleam
/// // gleam run -m eval/export_cli -- atif run/state/session.db run/trajectory.json
/// ```
///
pub fn main() -> Nil {
  case argv.load().arguments {
    ["atif", database, out] -> finish(export_atif(database, out))

    ["harbor", ..flags] ->
      case request(flags, Request("", "", harbor.Options("", ""), [])) {
        Ok(asked) -> finish(export_harbor(asked))
        Error(reason) -> usage(reason)
      }

    _ -> usage("expected `atif <session.db> <out.json>` or `harbor ...`")
  }
}

/// Prints a successful summary, or reports the failure and exits 1.
fn finish(outcome: Result(String, String)) -> Nil {
  // A summary goes to standard output; a failure to standard error with a nonzero status.
  case outcome {
    Ok(summary) -> io.println(summary)
    Error(reason) -> {
      io.println_error("eval/export_cli: " <> reason)
      ffi_os.halt(1)
    }
  }
}

/// Reports a request that did not parse and exits 2, distinct from a run that failed.
fn usage(reason: String) -> Nil {
  io.println_error("eval/export_cli: " <> reason)
  io.println_error(
    "usage: atif <session.db> <out.json> | harbor --tasks <dir> --out <dir> --repo-url <url> --base-image <ref> [--repo <name>=<path>]...",
  )
  ffi_os.halt(2)
}

fn export_atif(database: String, out: String) -> Result(String, String) {
  use trajectory <- result.try(atif.from_session_db(database))
  use _ <- result.map(atif.write(trajectory, out))

  "wrote " <> out
}

/// Reads the harbor flags one at a time; each takes one value, and the first unknown flag is named so a typo is never taken for a default.
fn request(flags: List(String), so_far: Request) -> Result(Request, String) {
  case flags {
    [] ->
      case
        so_far.tasks == ""
        || so_far.out == ""
        || so_far.options.repo_url == ""
        || so_far.options.base_image == ""
      {
        True ->
          Error("--tasks, --out, --repo-url and --base-image are all required")
        False -> Ok(so_far)
      }

    ["--tasks", value, ..rest] -> request(rest, Request(..so_far, tasks: value))
    ["--out", value, ..rest] -> request(rest, Request(..so_far, out: value))
    ["--repo-url", value, ..rest] ->
      request(
        rest,
        Request(
          ..so_far,
          options: harbor.Options(..so_far.options, repo_url: value),
        ),
      )
    ["--repo", value, ..rest] ->
      request(rest, Request(..so_far, repos: [value, ..so_far.repos]))
    ["--base-image", value, ..rest] ->
      request(
        rest,
        Request(
          ..so_far,
          options: harbor.Options(..so_far.options, base_image: value),
        ),
      )
    [flag, ..] -> Error("unknown or incomplete argument " <> flag)
  }
}

/// Exports every task file in the directory, each to `<out>/<slug>`.
fn export_harbor(asked: Request) -> Result(String, String) {
  use known <- result.try(repos.from_flags(list.reverse(asked.repos)))
  let known = repos.with_default(known, secrets.host_runner())
  use names <- result.try(
    simplifile.read_directory(asked.tasks)
    |> result.map_error(fn(error) {
      "cannot read " <> asked.tasks <> ": " <> simplifile.describe_error(error)
    }),
  )
  let files =
    names
    |> list.filter(string.ends_with(_, ".json"))
    |> list.sort(string.compare)
  let failures =
    list.filter_map(files, fn(name) {
      case export_one(asked, known, asked.tasks <> "/" <> name) {
        Ok(Nil) -> Error(Nil)
        Error(reason) -> Ok(name <> ": " <> reason)
      }
    })

  // Every failure is printed, then the run as a whole is refused: a partial export must not look complete.
  case failures {
    [] -> Ok("exported " <> int.to_string(list.length(files)) <> " tasks")
    _ -> {
      list.each(failures, io.println_error)
      Error(int.to_string(list.length(failures)) <> " tasks failed to export")
    }
  }
}

/// Loads one task file and exports it under its slug.
fn export_one(
  asked: Request,
  known: repos.Repos,
  path: String,
) -> Result(Nil, String) {
  use loaded <- result.try(task.load(path))

  harbor.export(
    loaded,
    asked.out <> "/" <> harbor.slug(loaded.name),
    asked.options,
    known,
    secrets.host_runner(),
  )
}
