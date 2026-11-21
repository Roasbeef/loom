//// Building a project's template (protocol-change/106, "The template").
////
//// A check runs code a worker wrote, so it runs with the network off. A real
//// repository's build needs its dependencies before that, and fetching them
//// needs the network. The template is where the two meet: a checkout of the
//// recorded base commit in which the project's `setup` ran once with the
//// network on, and in which the project's `check` then ran with the network
//// off to show that it passes on the clean base. Every worker clone and check
//// tree is a copy of it, so the offline check finds what `setup` fetched.
////
//// ## Why this is safe to run with the network on
////
//// `setup` runs the repository's own scripts. What makes that acceptable is
//// what it runs on and where. The tree is cut by the host from the host
//// repository at one commit, so no worker has written a byte of it, and the
//// build never takes a tree a worker touched as input. It runs in the check's
//// jail with the network switched on and nothing else widened: the host is
//// readable with the state root, the credentials and the other projects'
//// private files masked, the only writable root is the tree, and `HOME` is a
//// directory inside it, so every cache `setup` fills lands in the template.
//// The environment carries nothing of the daemon's but its `PATH`.
////
//// ## Flow
////
//// `build` → `build_to_swap` → `run_setup` → `run_check` → `seal`
////
//// 1. `build` reads the base commit and answers `Unchanged` when the template
////    already stands at it, so a rebuild that finds the base where it was
////    costs one fetch.
//// 2. `build_to_swap` cuts the tree under the building name, which a crash
////    leaves behind and the next build removes, and carries every step below
////    to the rename that puts the tree in place.
//// 3. `run_setup` runs the setup command with the network on.
//// 4. `run_check` runs the project's check once on the clean base with the
////    network off, so a template whose own base is red is never used.
//// 5. `seal` excludes what the build left untracked, so a worker's clone does
////    not read as holding changes, and checks that the tree can be copied.
////    The rename comes last. Everything before it can fail, and any failure
////    removes the tree and leaves the last good template.

import client/goalcheck
import client/goalstate
import client/project_repo.{type Layout}
import client/worktrees.{type Worktrees}
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// What a build is asked to do.
pub type Request {
  Request(
    /// The `setup` command.
    setup: String,
    /// The `check` command to prove on the clean base, or none for a project
    /// with no check.
    check: Option(String),
    /// The wall `setup` may take, in milliseconds.
    setup_wall_ms: Int,
    /// The wall the base check may take, in milliseconds.
    check_wall_ms: Int,
    /// The commit the template stands at now, if there is a usable one. A
    /// build whose base is that commit does nothing.
    current: Option(String),
  )
}

/// How a build ended.
pub type Outcome {
  /// A new template stands at this commit.
  Built(
    /// The base commit.
    commit: String,
  )

  /// The base is still the commit the template stands at, so nothing was done.
  Unchanged(
    /// The base commit.
    commit: String,
  )

  /// The build stopped at a step. The tree is removed and the last good
  /// template, if any, is as it was.
  Failed(
    /// What failed.
    failure: Failure,
  )
}

/// A build that stopped, and what it printed.
pub type Failure {
  Failure(
    /// The step.
    stage: Stage,
    /// What the step printed, cut to the last `max_output_chars`, or why it
    /// could not run.
    output: String,
  )
}

/// The step of a build that failed.
pub type Stage {
  /// The host could not make the tree: a Git failure, a full disk, a sandbox
  /// that would not start.
  Cutting

  /// `setup` exited nonzero, or did not finish.
  Setup

  /// `check` failed on the clean base. The project's own check is red before
  /// any worker touched it, so no worker starts.
  BaseCheck
}

/// The most characters of output a failure keeps, as a check's failure note
/// keeps them.
pub const max_output_chars = 4000

/// How long `setup` may take when the caller has no better number: thirty
/// minutes, which a cold dependency download and a first build fit in.
pub const default_setup_wall_ms = 1_800_000

/// Builds a template at the owner's current `HEAD`.
///
/// ## Examples
///
/// ```gleam
/// // project_template.build(trees, layout, Request("make deps", Some("make check"), 1_800_000, 600_000, None))
/// ```
pub fn build(trees: Worktrees, layout: Layout, request: Request) -> Outcome {
  // A failed build removes its tree whatever step failed, so no disk is left
  // behind and nothing is left under the building name.
  case build_to_swap(trees, layout, request) {
    Ok(outcome) -> outcome
    Error(failed) -> {
      project_repo.discard_template_tree(trees, layout)
      failed
    }
  }
}

/// Everything up to the swap, with a failure carried as the outcome to answer.
/// A recorded swap that stopped half way is undone first, so the last good
/// template is back in place before anything is built beside it.
fn build_to_swap(
  trees: Worktrees,
  layout: Layout,
  request: Request,
) -> Result(Outcome, Outcome) {
  use Nil <- result.try(
    project_repo.restore_interrupted_swap(layout) |> result.map_error(cutting),
  )
  use base <- result.try(
    project_repo.base_commit(trees, layout) |> result.map_error(cutting),
  )

  // A base the template already stands at needs no build. Any other base is
  // cut, set up, proved and swapped in.
  case request.current == Some(base) {
    True -> Ok(Unchanged(base))
    False -> {
      use tree <- result.try(
        project_repo.cut_template_tree(trees, layout, base)
        |> result.map_error(cutting),
      )
      use Nil <- result.try(run_setup(trees, tree, request))
      use Nil <- result.try(run_check(trees, tree, request))
      use Nil <- result.try(seal(trees, tree))
      use Nil <- result.map(
        project_repo.swap_template(trees, layout) |> result.map_error(cutting),
      )
      Built(base)
    }
  }
}

fn cutting(why: String) -> Outcome {
  Failed(Failure(Cutting, tail(why)))
}

/// Runs the setup command in the tree with the network on, and passes when it
/// exits zero.
fn run_setup(
  trees: Worktrees,
  tree: String,
  request: Request,
) -> Result(Nil, Outcome) {
  use Nil <- result.try(
    worktrees.prepare_home(trees, tree) |> result.map_error(cutting),
  )
  use runner <- result.try(
    worktrees.setup_runner(trees, tree) |> result.map_error(cutting),
  )
  let done =
    { goalcheck.wiring(runner, timeout_ms: request.setup_wall_ms) }.run(
      request.setup,
    )
  verdict(done, Setup)
}

/// Runs the project's check on the clean base with the network off, and passes
/// when it exits zero. A project with no check has nothing to prove here.
fn run_check(
  trees: Worktrees,
  tree: String,
  request: Request,
) -> Result(Nil, Outcome) {
  // A check that is configured must pass on the base; none passes trivially.
  case request.check {
    None -> Ok(Nil)
    Some(command) -> {
      use Nil <- result.try(
        worktrees.prepare_home(trees, tree) |> result.map_error(cutting),
      )
      use runner <- result.try(
        worktrees.check_runner(trees, tree) |> result.map_error(cutting),
      )
      let done =
        { goalcheck.wiring(runner, timeout_ms: request.check_wall_ms) }.run(
          command,
        )
      verdict(done, BaseCheck)
    }
  }
}

/// A command's end as the step's result: a clean exit passes, and anything else
/// fails the step with the end of what it printed.
fn verdict(done: goalstate.CheckResult, stage: Stage) -> Result(Nil, Outcome) {
  case done.ending {
    goalstate.Exited(status: 0) -> Ok(Nil)
    goalstate.Exited(status:) ->
      Error(
        Failed(Failure(
          stage,
          "exit status " <> int.to_string(status) <> "\n" <> tail(done.output),
        )),
      )
    goalstate.DidNotFinish(reason:) ->
      Error(
        Failed(Failure(
          stage,
          "did not finish: " <> reason <> "\n" <> tail(done.output),
        )),
      )
  }
}

// Makes the built tree one that can be copied and read as clean.
fn seal(trees: Worktrees, tree: String) -> Result(Nil, Outcome) {
  project_repo.sound_template(tree)
  |> result.try(fn(_) { project_repo.exclude_untracked(trees, tree) })
  |> result.map_error(cutting)
}

/// The word the ledger and the board keep for a step.
///
/// ## Examples
///
/// ```gleam
/// assert project_template.stage_word(project_template.BaseCheck) == "base_check"
/// ```
pub fn stage_word(stage: Stage) -> String {
  case stage {
    Cutting -> "cutting"
    Setup -> "setup"
    BaseCheck -> "base_check"
  }
}

/// The step a ledger word names. A word it does not know reads as `Cutting`,
/// the step that carries "the host could not do it".
///
/// ## Examples
///
/// ```gleam
/// assert project_template.stage_of_word("setup") == project_template.Setup
/// ```
pub fn stage_of_word(word: String) -> Stage {
  case word {
    "setup" -> Setup
    "base_check" -> BaseCheck
    _ -> Cutting
  }
}

/// The last `max_output_chars` characters of a step's output, where the failure
/// is.
///
/// ## Examples
///
/// ```gleam
/// assert project_template.tail("short") == "short"
/// ```
pub fn tail(output: String) -> String {
  let extra = string.length(output) - max_output_chars

  // Output that fits is kept whole; longer output loses its start.
  case extra > 0 {
    True -> string.drop_start(output, extra)
    False -> output
  }
}
