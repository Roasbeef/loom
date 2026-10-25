//// The verifier prover's command line:
//// `gleam run -m eval/prove_cli -- --tasks <dir> --repo <path> [--out <dir>]
//// [--helper <path>] [--seed <dir>] [--best-effort]`.
////
//// It opens one jail under `<out>`, proves every task file in `<tasks>`
//// through `eval/prove`, and appends one JSON line per task to
//// `<out>/prove.jsonl`. The line is written as each task finishes, so an
//// interrupted run keeps the proofs it reached, and a task whose proof could
//// not run adds a line with its reason rather than stopping the others: a
//// task set is proved as a whole, and the summary says how many were
//// admitted.
////
//// The default output directory is `$HOME/evalwt/prove`, never `/tmp`: the
//// jail replaces `/tmp` with its scratch tmpfs, and a verifier run laid out
//// there would be invisible to itself.
////
//// `--best-effort` is the same choice `loomd --best-effort` offers, for a
//// development kernel whose helper reports a ceiling it could not apply.
//// Without it the production demand holds, and a host that cannot meet it
//// refuses before any proof runs, naming the skipped layer.

import argv
import broker/exec
import client/catalog
import client/internal/ffi_os
import client/secrets
import client/serve.{Settings}
import client/workspace_policy
import core/json
import eval/prove
import eval/run_cli
import eval/task
import eval/verify
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import provider/http
import provider/model
import provider/secret
import simplifile

/// What the command line asked for.
type Options {
  Options(
    tasks: String,
    repo: String,
    out: String,
    helper: String,
    seed: String,
    demand: exec.EnforcementDemand,
  )
}

/// Runs the prover. Usage errors exit 2 and a jail or task directory that
/// cannot be opened exits 1; a refused task is data in the output, never a
/// failure of the run.
///
/// ## Examples
///
/// ```gleam
/// // gleam run -m eval/prove_cli -- --tasks ~/evalwt/mined --repo ../..
/// ```
///
pub fn main() -> Nil {
  // A request that does not parse is a usage error, distinct from a run
  // that failed.
  case options(argv.load().arguments, defaults()) {
    Error(reason) -> {
      io.println_error("eval/prove_cli: " <> reason)
      io.println_error(
        "usage: --tasks <dir> --repo <path> [--out <dir>] [--helper <path>] [--seed <dir>] [--best-effort]",
      )
      ffi_os.halt(2)
    }

    Ok(options) ->
      case run(options) {
        Ok(summary) -> io.println(summary)
        Error(reason) -> {
          io.println_error("eval/prove_cli: " <> reason)
          ffi_os.halt(1)
        }
      }
  }
}

/// The options before any flag: the output under the operator's home, the
/// helper and seed where a checkout's `packages/eval` finds them, and the
/// production enforcement demand.
fn defaults() -> Options {
  // Without a home the output lands beside the caller, which `--out` fixes.
  let home = case workspace_policy.home_directory() {
    Some(home) -> home
    None -> "."
  }

  Options(
    tasks: "",
    repo: "",
    out: home <> "/evalwt/prove",
    helper: "../sandbox/loom-exec",
    seed: "../../build/codemode-seed",
    demand: exec.PlatformEnforcement,
  )
}

/// Reads the flags one at a time. Each value flag takes one word; the first
/// unknown flag or missing value is named so a typo is never a default.
fn options(
  arguments: List(String),
  so_far: Options,
) -> Result(Options, String) {
  case arguments {
    [] ->
      case so_far.tasks, so_far.repo {
        "", _ -> Error("--tasks is required")
        _, "" -> Error("--repo is required")
        _, _ -> Ok(so_far)
      }
    ["--tasks", value, ..rest] -> options(rest, Options(..so_far, tasks: value))
    ["--repo", value, ..rest] -> options(rest, Options(..so_far, repo: value))
    ["--out", value, ..rest] -> options(rest, Options(..so_far, out: value))
    ["--helper", value, ..rest] ->
      options(rest, Options(..so_far, helper: value))
    ["--seed", value, ..rest] -> options(rest, Options(..so_far, seed: value))
    ["--best-effort", ..rest] ->
      options(rest, Options(..so_far, demand: exec.BestEffort))
    [flag, ..] -> Error("unknown or incomplete flag: " <> flag)
  }
}

/// Opens the jail, proves every task file, writes the lines and the summary.
fn run(options: Options) -> Result(String, String) {
  use out <- result.try(absolute(options.out))
  use repo <- result.try(absolute(options.repo))
  use helper <- result.try(absolute(options.helper))
  use seed <- result.try(absolute(options.seed))
  use Nil <- result.try(
    simplifile.create_directory_all(out)
    |> result.map_error(fn(e) { out <> ": " <> simplifile.describe_error(e) }),
  )
  use files <- result.try(task_files(options.tasks))
  use base <- result.try(run_cli.base_settings(
    placeholder_catalogue(),
    http.httpc_transport(),
    secret.env(),
    out <> "/settings",
    helper,
    seed,
  ))
  use jail <- result.try(verify.open_jail(
    Settings(..base, demand: options.demand),
    out,
  ))
  let lines = list.map(files, fn(file) { prove_file(file, repo, out, jail) })
  let _closed = verify.close_jail(jail)
  use Nil <- result.try(append_lines(out <> "/prove.jsonl", lines))

  Ok(summary(lines))
}

/// Proves one task file and renders its line; a task that could not be
/// loaded or proved becomes a line carrying the reason.
fn prove_file(
  file: String,
  repo: String,
  out: String,
  jail: verify.Jail,
) -> Line {
  let proved = {
    use loaded <- result.try(task.load(file))

    prove.prove(loaded, repo, out <> "/work", jail, secrets.host_runner())
    |> result.map_error(fn(reason) { loaded.id <> ": " <> reason })
  }

  // A proof that could not run is a line with its reason, not a stop.
  case proved {
    Ok(proof) -> Proved(proof)
    Error(reason) -> Unproved(file:, reason:)
  }
}

/// One output line's worth of result.
type Line {
  /// The proof ran to a verdict.
  Proved(proof: prove.Proof)

  /// The proof could not run.
  Unproved(file: String, reason: String)
}

/// The JSON for a line: the proof, or the file and the reason.
fn line_json(line: Line) -> json.JsonValue {
  case line {
    Proved(proof) -> prove.to_json(proof)
    Unproved(file:, reason:) ->
      json.Object([
        #("v", json.Int(1)),
        #("file", json.String(file)),
        #("error", json.String(reason)),
      ])
  }
}

/// Appends the lines to `prove.jsonl`, one JSON object each.
fn append_lines(path: String, lines: List(Line)) -> Result(Nil, String) {
  let text =
    lines
    |> list.map(fn(line) { json.to_string(line_json(line)) <> "\n" })
    |> string.concat

  simplifile.append(path, text)
  |> result.map_error(fn(e) { path <> ": " <> simplifile.describe_error(e) })
}

/// The one-line summary printed on standard output.
fn summary(lines: List(Line)) -> String {
  let admitted =
    list.count(lines, fn(line) {
      case line {
        Proved(proof) -> proof.verdict == prove.Admitted
        Unproved(file: _, reason: _) -> False
      }
    })
  let unproved =
    list.count(lines, fn(line) {
      case line {
        Proved(_) -> False
        Unproved(file: _, reason: _) -> True
      }
    })

  int.to_string(list.length(lines))
  <> " tasks, "
  <> int.to_string(admitted)
  <> " admitted, "
  <> int.to_string(unproved)
  <> " could not be proved"
}

/// Every `.json` file in the task directory except the census, sorted so
/// two runs write their lines in the same order.
fn task_files(directory: String) -> Result(List(String), String) {
  use names <- result.try(
    simplifile.read_directory(directory)
    |> result.map_error(fn(e) {
      directory <> ": " <> simplifile.describe_error(e)
    }),
  )

  names
  |> list.filter(fn(name) {
    string.ends_with(name, ".json") && name != "census.json"
  })
  |> list.sort(string.compare)
  |> list.map(fn(name) { directory <> "/" <> name })
  |> Ok
}

/// A path as given when absolute, else under the current directory. The
/// jail root and the repository both reach the helper as absolute paths.
fn absolute(path: String) -> Result(String, String) {
  case string.starts_with(path, "/") {
    True -> Ok(path)
    False ->
      simplifile.current_directory()
      |> result.map(fn(here) { here <> "/" <> path })
      |> result.map_error(fn(e) {
        "current directory: " <> simplifile.describe_error(e)
      })
  }
}

/// A catalogue with one model nothing will ever call. The base settings
/// need a main model to exist; a verifier never reaches a provider, so the
/// entry is a placeholder rather than an operator's configuration.
fn placeholder_catalogue() -> catalog.Catalog {
  catalog.Catalog(
    models: [
      catalog.CatalogModel(
        name: "unused",
        dialect: catalog.Anthropic,
        base_url: "https://unused.invalid",
        api_key_env: "UNUSED",
        model_id: "unused",
        context_window: 1,
        max_output_tokens: 1,
        thinking: model.ThinkingOff,
        pricing: None,
        vision: catalog.TextOnly,
        max_images: 0,
        cyber_access: None,
        service_tier: None,
      ),
    ],
    roles: [#(model.Main, ["unused"])],
    profiles: [],
    mcp_servers: [],
    lsp_servers: [],
  )
}
