//// Turns a task's starting tree into files on disk, and times it.
////
//// An agent must start from exactly the tree the task names and from nothing
//// else. For a small inline fixture that is a list of files. For a git tree
//// it is the commit's files without the repository: the workspace is built
//// with `git archive`, so there is no `.git` directory and no object store,
//// and `git log --all` inside the trial finds nothing, where a worktree would
//// print the very fix the task is meant to hide.
////
//// A task names its repository, not its path; `eval/repos` maps the name to
//// the operator's clone. Before anything is extracted the commit's tree id is
//// read back from that clone and compared with the one the task recorded. A task is
//// content-addressed, so a repository that no longer holds those bytes at
//// that commit (a rewritten branch, a different clone) must refuse rather
//// than quietly measure another tree.
////
//// The `prepare` argvs then run on the host with the workspace as their
//// working directory. They are the repository's own warm-up at a trusted
//// commit, restricted by the task codec to an allowlist, and what they cost
//// is the trial's cold start: the elapsed time of the whole materialisation is
//// returned so the ledger can keep it apart from agent time. Every command
//// goes through `client/secrets.Runner` and `eval/git`'s quoting, so a path
//// with a quote in it stays one shell word.

import client/internal/ffi_os
import client/secrets.{type Runner}
import client/serve
import eval/git
import eval/prove
import eval/repos.{type Repos}
import eval/task.{type Task, GitTree, Inline, Program}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile

/// A materialised workspace.
pub type Prepared {
  Prepared(
    /// The directory the agent will work in.
    workspace: String,
    /// A tree beside the workspace holding copies of every `build/` the
    /// warm-up produced, at their relative paths, taken before the agent
    /// ran. The grader lays them over its copy of the agent's tree, so the
    /// dependency artefacts a verifier compiles against are never the
    /// agent's. `None` when the warm-up produced no build.
    pristine: Option(String),
    /// Milliseconds spent building it: the trial's cold start.
    prepare_ms: Int,
  )
}

/// The directory beside the workspace that holds the pristine build.
pub const pristine_directory = "pristine"

/// The longest any one host command in materialisation may run, thirty
/// minutes: a cold dependency download and build of a large repository.
const command_timeout_ms = 1_800_000

/// How long a tree-id check or archive may take before it is abandoned.
const git_timeout_ms = 300_000

/// Builds the task's starting tree under `root`, in the directory
/// `serve.trial_workspace(root)` names.
///
/// ## Examples
///
/// ```gleam
/// // materialise.run(secrets.host_runner(), repos, task, "/runs/p/t/a/0/attempt-1")
/// // == Ok(Prepared("/runs/p/t/a/0/attempt-1/work", 3))
/// ```
///
pub fn run(
  runner: Runner,
  known: Repos,
  task: Task,
  root: String,
) -> Result(Prepared, String) {
  let started = ffi_os.system_time_ms()
  let workspace = serve.trial_workspace(root)

  use Nil <- result.try(
    simplifile.create_directory_all(workspace)
    |> result.map_error(fn(error) {
      "cannot create the workspace: " <> simplifile.describe_error(error)
    }),
  )
  use Nil <- result.try(build(runner, known, task, workspace))
  use pristine <- result.try(keep_builds(runner, workspace, root))

  Ok(Prepared(
    workspace:,
    pristine:,
    prepare_ms: ffi_os.system_time_ms() - started,
  ))
}

/// Copies every `build/` under the prepared workspace (the root's own and
/// one per `packages/*`) to `<root>/pristine/<relative>`, with `cp -a` on
/// the host: the tree is the trusted commit's, prepared by the repository's
/// own warm-up, and nothing of the agent's has touched it yet.
fn keep_builds(
  runner: Runner,
  workspace: String,
  root: String,
) -> Result(Option(String), String) {
  let pristine = root <> "/" <> pristine_directory
  let builds =
    ["build", ..package_builds(workspace)]
    |> list.filter(fn(relative) {
      simplifile.is_directory(workspace <> "/" <> relative) == Ok(True)
    })

  // No build means nothing to keep, and the grader lays nothing over.
  case builds {
    [] -> Ok(None)
    _some -> {
      use Nil <- result.try(
        list.try_each(builds, fn(relative) {
          keep_build(runner, workspace, pristine, relative)
        }),
      )

      Ok(Some(pristine))
    }
  }
}

/// The `packages/<name>/build` paths a Loom-shaped tree may hold.
fn package_builds(workspace: String) -> List(String) {
  simplifile.read_directory(workspace <> "/packages")
  |> result.unwrap([])
  |> list.map(fn(name) { "packages/" <> name <> "/build" })
}

/// Copies one build directory into the pristine tree at its relative path.
fn keep_build(
  runner: Runner,
  workspace: String,
  pristine: String,
  relative: String,
) -> Result(Nil, String) {
  let target = pristine <> "/" <> relative
  use Nil <- result.try(
    simplifile.create_directory_all(parent_of(target))
    |> result.map_error(simplifile.describe_error),
  )
  use capture <- result.try(runner(
    ["cp", "-a", workspace <> "/" <> relative, target],
    git_timeout_ms,
  ))

  // `cp` answers with its status; its output is the reason when it fails.
  case capture.status {
    0 -> Ok(Nil)
    status ->
      Error(
        "keeping the pristine build of "
        <> relative
        <> " exited "
        <> int.to_string(status)
        <> ": "
        <> string.trim(capture.output),
      )
  }
}

/// Builds the task's tree in `workspace` from its inline files or its git tree.
fn build(
  runner: Runner,
  known: Repos,
  task: Task,
  workspace: String,
) -> Result(Nil, String) {
  // The two workspace kinds differ only in where the bytes come from; both end as plain files.
  case task.workspace {
    Inline(files:) -> write_files(workspace, files)

    GitTree(repository:, commit:, tree:, prepare:) -> {
      use clone <- result.try(repos.resolve(
        known,
        runner,
        repository,
        commit,
        tree,
      ))
      use Nil <- result.try(archive(runner, clone, commit, workspace))

      // Steps run where the verifier's package lives, since a mined Loom
      // tree has no project at its root; the build is then warmed there too.
      let cwd = prove.prepare_directory(workspace, task, verifier_argv(task))

      use Nil <- result.try(
        list.try_each(prepare, fn(argv) { prepare_step(runner, cwd, argv) }),
      )

      warm_build(runner, cwd, prepare)
    }
  }
}

/// Writes inline files under the workspace, creating directories as needed.
fn write_files(
  workspace: String,
  files: List(#(String, String)),
) -> Result(Nil, String) {
  use #(path, content) <- list.try_each(files)
  let target = workspace <> "/" <> path

  use Nil <- result.try(
    simplifile.create_directory_all(parent_of(target))
    |> result.map_error(simplifile.describe_error),
  )

  simplifile.write(target, content)
  |> result.map_error(fn(error) {
    "cannot write " <> path <> ": " <> simplifile.describe_error(error)
  })
}

/// `pipefail` makes a failed `git archive` fail the pipeline; without it `tar`
/// would happily extract an empty stream and the trial would start on nothing.
fn archive(
  runner: Runner,
  repository: String,
  commit: String,
  workspace: String,
) -> Result(Nil, String) {
  let command =
    "set -o pipefail; git -C "
    <> git.shell_quote(repository)
    <> " archive "
    <> git.shell_quote(commit)
    <> " | tar -x -C "
    <> git.shell_quote(workspace)
    <> " 2>&1"

  use capture <- result.try(runner(["bash", "-c", command], git_timeout_ms))

  // A nonzero pipeline status means the archive or the extraction failed, and a trial must not start on a partial tree.
  case capture.status {
    0 -> Ok(Nil)
    status ->
      Error(
        "git archive exited "
        <> int.to_string(status)
        <> ": "
        <> string.trim(capture.output),
      )
  }
}

/// The verifier's argv, when it has one; an exact-file task names no package.
fn verifier_argv(task: Task) -> List(String) {
  case task.verifier {
    Program(argv:, ..) -> argv
    task.ExpectedFiles(..) -> []
  }
}

/// Warms the build after dependencies are fetched, as `prove` does, so the
/// jailed agent and verifier find a compiled tree. Only a task whose steps
/// use `gleam` has a Gleam project to build.
fn warm_build(
  runner: Runner,
  cwd: String,
  steps: List(List(String)),
) -> Result(Nil, String) {
  let uses_gleam =
    list.any(steps, fn(step) {
      case step {
        ["gleam", ..] -> True
        _ -> False
      }
    })

  // Nothing to warm unless a step prepared a Gleam project.
  case uses_gleam {
    False -> Ok(Nil)
    True -> prepare_step(runner, cwd, ["gleam", "build"])
  }
}

/// Runs one allowlisted warm-up argv in the workspace on the host.
fn prepare_step(
  runner: Runner,
  workspace: String,
  argv: List(String),
) -> Result(Nil, String) {
  use capture <- result.try(git.run_in(
    runner,
    workspace,
    argv,
    command_timeout_ms,
  ))

  // A failed warm-up step would hand the agent a tree that cannot build, so it fails the whole materialisation.
  case capture.status {
    0 -> Ok(Nil)
    status ->
      Error(
        "prepare `"
        <> string.join(argv, " ")
        <> "` exited "
        <> int.to_string(status)
        <> ": "
        <> string.trim(capture.output),
      )
  }
}

/// The directory part of a path. The codec admits only safe relative file
/// names, so the target always has a slash and the fallback is unreachable.
fn parent_of(path: String) -> String {
  case string.split(path, "/") |> list.reverse {
    [_, ..rest] -> rest |> list.reverse |> string.join("/")
    [] -> path
  }
}
