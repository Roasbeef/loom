//// The search's command line.
////
////     gleam run -m eval/optimize_cli -- search --objective TEXT
////       [--arm FILE | --arm none] [--tasks DIR] [--out DIR] [--config loom.toml]
////       [--reflector NAME] [--steps N] [--max-dollars X] [--max-reflections N]
////       [--max-candidates N] [--k N] [--k-tune N] [--minibatch N] [--salt S]
////       [--mutate SPEC]... [--profile quick|full] [--lane live|replay]
////       [--tapes DIR] [--helper PATH] [--seed DIR] [--repo NAME=PATH]...
////       [--concurrency N] [--wall-ms N] [--max-requests N]
////     gleam run -m eval/optimize_cli -- report <search-dir>
////
//// `search` reads every task under `--tasks`, keeps the tune and validate
//// splits that `--salt` assigns and never reads the holdout, loads the seed
//// arm (or starts from the empty base arm with `--arm none`), resolves the
//// reflector entry once, stamps the harness, and runs or resumes the search
//// under `<out>/<search id>/`. `report` rebuilds the front of a search
//// directory from its log without running anything.
////
//// The mutable set is `--mutate` flags over the main model's exact target:
//// the default is the system suffix, the task prefix and a tool description
//// for every tool the seed already names; `pack` adds the prompt pack,
//// `tool:<name>` a tool's description, and `role:<role>` the suffix and
//// prefix aimed at that role. A role-aimed slot joins by flag and no loop
//// change; until per-role profiles land, a child written into one is
//// refused by `arm_settings` and recorded as such, costing nothing.

import argv
import client/catalog
import client/internal/ffi_os
import client/secrets.{type Runner}
import client/serve.{type Settings}
import client/workspace_policy
import core/json
import eval/arm.{type Arm, type Component, type Target, Target}
import eval/optimize
import eval/plan
import eval/reflect
import eval/repos
import eval/run
import eval/run_cli
import eval/split
import eval/task.{type Task}
import eval/trial
import eval/verify
import gleam/dict
import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import provider/gateway
import provider/http
import provider/model
import provider/secret
import simplifile

/// Dispatches argv; a failure prints its reason on standard error and exits
/// with status 1.
///
/// ## Examples
///
/// ```gleam
/// // gleam run -m eval/optimize_cli -- report searches/<id>
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
    ["search", ..flags] -> {
      use #(repeated, flags) <- result.try(take_repeated(flags, [], [], []))
      use options <- result.try(parse_flags(flags))
      use known <- result.try(repos.from_flags(repeated.repos))
      command_search(
        repos.with_default(known, secrets.host_runner()),
        options,
        repeated.mutations,
      )
    }
    ["report", directory] -> {
      use Nil <- result.map(optimize.report(directory))

      "wrote " <> directory <> "/front.md"
    }
    _ ->
      Error(
        "usage: search --objective TEXT [--arm FILE|none] [--tasks DIR] [--out DIR] [--config FILE] [--reflector NAME] [--steps N] [--max-dollars X] [--max-reflections N] [--max-candidates N] [--k N] [--k-tune N] [--minibatch N] [--salt S] [--mutate SPEC]... [--profile quick|full] [--lane live|replay] [--tapes DIR] [--helper PATH] [--seed DIR] [--repo NAME=PATH]... | report <search-dir>",
      )
  }
}

type Options =
  dict.Dict(String, String)

// The two repeatable flags, which a dictionary would overwrite.
type Repeated {
  Repeated(repos: List(String), mutations: List(String))
}

/// Splits the repeatable `--repo` and `--mutate` flags from the rest.
fn take_repeated(
  flags: List(String),
  specs: List(String),
  mutations: List(String),
  others: List(String),
) -> Result(#(Repeated, List(String)), String) {
  case flags {
    [] ->
      Ok(#(
        Repeated(list.reverse(specs), list.reverse(mutations)),
        list.reverse(others),
      ))
    ["--repo", spec, ..rest] ->
      take_repeated(rest, [spec, ..specs], mutations, others)
    ["--mutate", spec, ..rest] ->
      take_repeated(rest, specs, [spec, ..mutations], others)
    ["--repo"] -> Error("flag --repo needs a value")
    ["--mutate"] -> Error("flag --mutate needs a value")
    [other, ..rest] -> take_repeated(rest, specs, mutations, [other, ..others])
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

/// A flag's integer value, or its default, refusing anything else.
fn int_option(
  options: Options,
  name: String,
  default: Int,
) -> Result(Int, String) {
  case dict.get(options, name) {
    Error(Nil) -> Ok(default)
    Ok(text) ->
      int.parse(text)
      |> result.map_error(fn(_) { "--" <> name <> " must be an integer" })
  }
}

/// The `search` verb: load, build the base settings, resolve the reflector,
/// stamp the harness, run.
fn command_search(
  known: repos.Repos,
  options: Options,
  mutations: List(String),
) -> Result(String, String) {
  use objective <- result.try(
    dict.get(options, "objective")
    |> result.replace_error("--objective TEXT is required"),
  )
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
  use seed_dir <- result.try(
    absolute(option(options, "seed", "../../build/codemode-seed")),
  )
  use scratch <- result.try(scratch_root(out))
  use base <- result.try(run_cli.base_settings(
    catalogue,
    http.httpc_transport(),
    secret.env(),
    scratch,
    helper,
    seed_dir,
  ))

  use seed <- result.try(seed_arm(options))
  use #(tune, validate) <- result.try(splits(
    option(options, "tasks", "tasks"),
    option(options, "salt", "salt"),
  ))
  use slots <- result.try(mutable_set(base, seed, mutations))
  use lane <- result.try(lane_of(options))
  use budgets <- result.try(search_budgets(options))
  use trial_budgets <- result.try(trial_budgets(options))
  use profile <- result.try(profile_of(options))
  use harness <- result.try(stamp_harness(secrets.host_runner()))
  use #(identity, resolved) <- result.try(reflect.resolve(
    catalogue,
    base.gateway,
    option(options, "reflector", "main"),
  ))
  use k <- result.try(int_option(options, "k", 3))
  use k_tune <- result.try(int_option(options, "k-tune", 2))
  use minibatch <- result.try(int_option(options, "minibatch", 4))

  let frozen =
    optimize.mint(optimize.Plan(
      id: "",
      seed:,
      objective:,
      tune:,
      validate:,
      trials_per_cell: k,
      tune_trials: k_tune,
      minibatch:,
      slots:,
      reflector: identity,
      budgets:,
      trial: trial_budgets,
      lane:,
      profile:,
      split_salt: option(options, "salt", "salt"),
      harness:,
    ))
  use frozen <- result.try(optimize.check(frozen))

  run_search(base, frozen, out, options, known, resolved)
}

/// Opens the jail when a task needs one, builds the contexts and runs.
fn run_search(
  base: Settings,
  frozen: optimize.Plan,
  out: String,
  options: Options,
  known: repos.Repos,
  resolved: model.ResolvedModel,
) -> Result(String, String) {
  let directory = out <> "/" <> frozen.id
  let tasks = list.append(frozen.tune, frozen.validate)

  // A reflector with no rate card cannot be metered, and an unmetered live
  // call has no place in a search that promises a dollar ceiling.
  use card <- result.try(
    gateway.card_for(base.gateway, resolved.provider)
    |> result.map_error(fn(_) {
      "the reflector's provider "
      <> resolved.provider
      <> " has no rate card, so its calls cannot be metered"
    }),
  )

  use trial_lane <- result.try(trial_lane(frozen.lane, options))

  // Opening a jail starts a helper pool, which an exact-file search never uses.
  use jail <- result.try(case needs_jail(tasks) {
    True -> verify.open_jail(base, directory) |> result.map(Some)
    False -> Ok(None)
  })

  let ctx =
    optimize.Context(
      trial: trial.Context(
        base:,
        lane: trial_lane,
        budgets: frozen.trial,
        plan_id: "",
        seams: trial.default_seams(grader_for(jail)),
        repos: known,
        selftest: selftest_of(jail, base),
      ),
      seams: optimize.Seams(
        execute: run.execute,
        reflect: reflect.through_gateway(base.gateway, resolved),
      ),
      reflection_worst: reflect.worst_case(card, resolved),
      reflector_card: Some(card),
    )

  let searched = optimize.search(ctx, frozen, out)

  // Closing is owed exactly when opening happened, whatever the search did.
  let closed = case jail {
    Some(open) -> verify.close_jail(open)
    None -> Ok(Nil)
  }

  use outcome <- result.try(searched)
  use Nil <- result.map(closed)

  "searched "
  <> int.to_string(outcome.state.step)
  <> " steps; front at "
  <> outcome.directory
  <> "/front.md"
}

/// The seed arm: a file, or the empty base arm for `--arm none`.
fn seed_arm(options: Options) -> Result(Arm, String) {
  // `none` is the empty base arm; anything else is a path to an arm file.
  case option(options, "arm", "none") {
    "none" ->
      arm.mint(arm.Arm(
        id: "",
        name: "base",
        components: [],
        knobs: arm.Knobs(roles: [], thinking: [], disabled_tools: []),
      ))
    path -> {
      use body <- result.try(
        simplifile.read(path)
        |> result.map_error(fn(error) {
          "cannot read " <> path <> ": " <> simplifile.describe_error(error)
        }),
      )
      use value <- result.try(
        json.parse(body)
        |> result.map_error(fn(_report) { path <> ": not valid JSON" }),
      )
      use decoded <- result.try(arm.decode(value))

      arm.verify_id(decoded)
    }
  }
}

/// Every task under the directory, split by the salt into the two sides
/// the search may read. The holdout is dropped here and reaches nothing.
fn splits(
  directory: String,
  salt: String,
) -> Result(#(List(Task), List(Task)), String) {
  use names <- result.try(
    simplifile.read_directory(directory)
    |> result.map_error(fn(error) {
      "cannot list " <> directory <> ": " <> simplifile.describe_error(error)
    }),
  )
  use tasks <- result.try(
    names
    |> list.filter(string.ends_with(_, ".json"))
    |> list.sort(string.compare)
    |> list.try_map(fn(name) { task.load(directory <> "/" <> name) }),
  )
  let side = fn(wanted: split.Split) {
    list.filter(tasks, fn(each) {
      split.assign(salt, split.family(each)) == wanted
    })
  }

  Ok(#(side(split.Tune), side(split.Validate)))
}

/// The mutable set: the main model's suffix, prefix and the seed's tool
/// descriptions, plus whatever `--mutate` adds.
fn mutable_set(
  base: Settings,
  seed: Arm,
  mutations: List(String),
) -> Result(List(Component), String) {
  use main <- result.try(
    gateway.resolve(base.gateway, model.Main)
    |> result.replace_error("the catalogue routes no main model"),
  )
  use api <- result.try(
    gateway.api_for(base.gateway, main)
    |> result.replace_error("no provider is registered for the main model"),
  )
  let target = Target(main.provider, main.model_id, api, arm.Any)
  let seed_tools =
    list.filter_map(seed.components, fn(component) {
      case component.0 {
        arm.ToolDescription(tool:, ..) -> Ok(arm.ToolDescription(target, tool))
        arm.SystemSuffix(..) | arm.TaskPrefix(..) | arm.PromptPack -> Error(Nil)
      }
    })
  use added <- result.map(list.try_map(mutations, mutation(target, _)))

  list.flatten([
    [arm.SystemSuffix(target), arm.TaskPrefix(target)],
    seed_tools,
    list.flatten(added),
  ])
  |> list.unique
}

/// One `--mutate` spec as the slots it adds.
fn mutation(target: Target, spec: String) -> Result(List(Component), String) {
  // `pack` stands alone; the other two carry a name after a colon.
  case spec, string.split_once(spec, ":") {
    "pack", _ -> Ok([arm.PromptPack])
    _, Ok(#("tool", name)) if name != "" ->
      Ok([arm.ToolDescription(target, name)])
    _, Ok(#("role", name)) -> {
      use role <- result.map(role_of(name))
      let aimed = Target(..target, role:)

      [arm.SystemSuffix(aimed), arm.TaskPrefix(aimed)]
    }
    _, _ ->
      Error("--mutate takes pack, tool:<name> or role:<role>, not " <> spec)
  }
}

/// A target role's spelling.
fn role_of(name: String) -> Result(arm.Role, String) {
  case name {
    "main" -> Ok(arm.Main)
    "subagent" -> Ok(arm.Subagent)
    "advisor" -> Ok(arm.Advisor)
    "summarize" -> Ok(arm.Summarize)
    other -> Error("unknown role " <> other)
  }
}

/// The plan's lane from `--lane`.
fn lane_of(options: Options) -> Result(plan.Lane, String) {
  case option(options, "lane", "live") {
    "live" -> Ok(plan.Live)
    "replay" -> Ok(plan.Replay)
    other -> Error("--lane must be live or replay, not " <> other)
  }
}

/// The trial lane: live, or taped from `--tapes` on a replay plan.
fn trial_lane(lane: plan.Lane, options: Options) -> Result(trial.Lane, String) {
  case lane, dict.get(options, "tapes") {
    plan.Live, _ -> Ok(trial.Live)
    plan.Replay, Ok(directory) ->
      Ok(trial.Taped(open: run_cli.replay_open(directory)))
    plan.Replay, Error(Nil) -> Error("a replay search needs --tapes DIR")
  }
}

/// The search's ceilings. `--max-dollars` is required on every lane: the
/// trials of a replay search are taped and free, but the reflector is a
/// live, priced call on either lane.
fn search_budgets(options: Options) -> Result(optimize.Budgets, String) {
  // The reflector spends real money whatever the trials do.
  use max_dollars <- result.try(case dict.get(options, "max-dollars") {
    Error(Nil) ->
      Error(
        "--max-dollars X is required on every lane: the reflector is a live call",
      )
    Ok(text) ->
      parse_float(text)
      |> result.replace_error("--max-dollars must be a number")
  })

  use max_steps <- result.try(int_option(options, "steps", 8))
  use max_reflections <- result.try(int_option(options, "max-reflections", 64))
  use max_candidates <- result.try(int_option(options, "max-candidates", 64))

  Ok(optimize.Budgets(
    max_dollars:,
    max_steps:,
    max_reflections:,
    max_candidates:,
  ))
}

/// A number written as `12` or `12.5`.
fn parse_float(text: String) -> Result(Float, Nil) {
  case float.parse(text) {
    Ok(value) -> Ok(value)
    Error(Nil) -> int.parse(text) |> result.map(int.to_float)
  }
}

/// The per-trial ceilings every sub-plan carries.
fn trial_budgets(options: Options) -> Result(plan.Budgets, String) {
  use max_requests_per_trial <- result.try(int_option(
    options,
    "max-requests",
    40,
  ))
  use wall_ms_per_trial <- result.try(int_option(options, "wall-ms", 600_000))
  use concurrency <- result.try(int_option(options, "concurrency", 2))

  Ok(plan.Budgets(
    max_requests_per_trial:,
    max_dollars: 0.0,
    wall_ms_per_trial:,
    concurrency:,
  ))
}

/// The profile every sub-plan carries.
fn profile_of(options: Options) -> Result(plan.Profile, String) {
  case option(options, "profile", "quick") {
    "quick" -> Ok(plan.Quick)
    "full" -> Ok(plan.Full)
    other -> Error("--profile must be quick or full, not " <> other)
  }
}

/// The harness as the running tree reports it: `HEAD` and whether tracked
/// files have uncommitted changes. A full profile on a dirty tree is then
/// refused by `plan.check` through `optimize.check`.
fn stamp_harness(runner: Runner) -> Result(plan.Harness, String) {
  use commit <- result.try(git_output(runner, ["git", "rev-parse", "HEAD"]))
  use status <- result.try(
    git_output(runner, ["git", "status", "--porcelain", "--untracked-files=no"]),
  )

  Ok(
    plan.Harness(git_commit: commit, posture: case status {
      "" -> plan.Clean
      _ -> plan.Dirty
    }),
  )
}

/// One git command's trimmed standard output, or why it did not answer.
fn git_output(runner: Runner, command: List(String)) -> Result(String, String) {
  use capture <- result.try(runner(command, 30_000))

  // Only a zero status leaves output worth trusting.
  case capture.status {
    0 -> Ok(string.trim(capture.output))
    status ->
      Error(
        string.join(command, " ")
        <> " exited "
        <> int.to_string(status)
        <> ": "
        <> string.trim(capture.output),
      )
  }
}

/// Whether any task's verifier is a program, which only a jail can run.
fn needs_jail(tasks: List(Task)) -> Bool {
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

/// What each scored row's jail records.
fn selftest_of(jail: Option(verify.Jail), base: Settings) -> String {
  case jail {
    Some(_) ->
      "verify.open_jail probe: `true` ran under " <> string.inspect(base.demand)
    None -> trial.unprobed
  }
}

/// A private directory under `out` for the base settings' session files.
fn scratch_root(out: String) -> Result(String, String) {
  let scratch = out <> "/base"

  simplifile.create_directory_all(scratch)
  |> result.map(fn(_) { scratch })
  |> result.map_error(simplifile.describe_error)
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
    Ok(home) -> home <> "/.loom/eval/searches"
    Error(Nil) -> "eval-searches"
  }
}
