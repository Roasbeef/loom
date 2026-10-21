//// A real Git repository, a state root and an execution ledger for the tests of
//// worktree workspaces (protocol-change/095).
////
//// Every test gets a repository of its own with one commit on `main`, a state
//// root laid out as a daemon leaves it, a ledger file with the current schema,
//// and the production `client/worktrees` over the shipped sandbox helper. Git
//// itself is run here for setup and assertions, outside any jail, because the
//// tests are the operator: what is under test is that the executor never does.

import broker/exec
import client/internal/ffi_os
import client/workspaces.{type Workspace, Workspace}
import client/worktrees.{type Worktrees}
import gleam/int
import gleam/list
import gleam/string
import host/bootstrap
import simplifile
import storage/exec_ledger
import support/internal/ffi_proc
import telemetry/log

/// Everything one test needs.
pub type Rig {
  Rig(
    /// The executor's worktrees over the repository.
    trees: Worktrees,
    /// The configured workspace, `repo`, in worktree mode.
    workspace: Workspace,
    /// The repository's top directory.
    root: String,
    /// The executor's state root.
    state: String,
    /// The execution ledger's file.
    ledger_path: String,
  )
}

/// A session id the tests use, distinct for each number.
pub fn session(n: Int) -> String {
  "0198c0de-0000-7000-8000-00000000000" <> int.to_string(n)
}

/// A rig whose workspace starts each branch at `main`.
pub fn rig(name: String) -> Rig {
  rig_at(name, "main")
}

/// A rig whose workspace starts each branch at `base`, which need not exist.
pub fn rig_at(name: String, base: String) -> Rig {
  let scratch = absolute(scratch(name))
  let state = scratch <> "/state"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(scratch)
    as "the scratch directory is created"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(state)
    as "the state root is created"
  let assert Ok(state) = bootstrap.canonical_directory(state)
    as "the state root resolves"
  establish(state)
  let root = repository(scratch <> "/repo")
  let ledger_path = state <> "/exec-ledger.db"
  let assert Ok(ledger) = exec_ledger.open(ledger_path)
    as "the ledger is created"
  let assert Ok(Nil) = exec_ledger.close(ledger) as "the ledger closes"
  let workspace = Workspace("repo", root, workspaces.Worktree(base))
  let assert Ok(trees) =
    worktrees.start(
      worktrees.Config(
        state_root: state,
        ledger_path:,
        helper_path: absolute("../sandbox/loom-exec"),
        demand: exec.BestEffort,
        logger: log.discard(),
      ),
      [workspace],
    )
    as "the worktrees start"
  Rig(trees:, workspace:, root:, state:, ledger_path:)
}

/// The same executor after its daemon restarted: the old worktrees stopped, new
/// ones started over the same state root, repository and ledger. The first job
/// the new gates run reconciles the ledger with the disk.
pub fn restart(rig: Rig) -> Rig {
  worktrees.stop(rig.trees)
  let assert Ok(trees) =
    worktrees.start(
      worktrees.Config(
        state_root: rig.state,
        ledger_path: rig.ledger_path,
        helper_path: absolute("../sandbox/loom-exec"),
        demand: exec.BestEffort,
        logger: log.discard(),
      ),
      [rig.workspace],
    )
    as "the worktrees restart"
  Rig(..rig, trees:)
}

/// The entries a daemon creates in its state root before it builds any
/// session's policy. A jail masks them and cannot mask a path that does not
/// exist, so a rig standing in for a daemon creates them as a daemon would.
pub fn establish(state: String) -> Nil {
  list.each(["owner.token", "catalogue.db", "daemon.lock"], fn(name) {
    let assert Ok(Nil) = simplifile.write(state <> "/" <> name, "")
      as "a state root entry is created"
    Nil
  })
  list.each(["sessions", "run", "workspaces", "domains", "worktrees"], fn(name) {
    let assert Ok(Nil) =
      bootstrap.ensure_private_directory(state <> "/" <> name)
      as "a state root directory is created"
    Nil
  })
}

/// A repository with one commit, `README` on `main`. Its top directory.
pub fn repository(directory: String) -> String {
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
    as "the repository directory is created"
  let assert Ok(root) = bootstrap.canonical_directory(directory)
    as "the repository resolves"
  git(root, ["init", "--quiet", "--initial-branch=main"])
  write(root <> "/README", "one\n")
  git(root, ["add", "README"])
  git(root, ["commit", "--quiet", "-m", "first"])
  root
}

/// Runs Git as the operator in `directory`, failing the test when it exits
/// nonzero, and answers its output with the trailing newline cut.
pub fn git(directory: String, arguments: List(String)) -> String {
  let #(code, output) = git_status(directory, arguments)
  case code {
    0 -> string.trim_end(output)
    _ ->
      panic as {
        "git "
        <> string.join(arguments, " ")
        <> " exited "
        <> int.to_string(code)
        <> ": "
        <> output
      }
  }
}

/// Runs Git as the operator and answers its exit code and output.
pub fn git_status(
  directory: String,
  arguments: List(String),
) -> #(Int, String) {
  let assert Ok(program) = ffi_proc.which("git") as "git is installed"
  let assert Ok(done) =
    ffi_proc.run(
      program,
      list.append(
        [
          "-c", "user.name=Tester", "-c", "user.email=tester@example.invalid",
          "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
        ],
        arguments,
      ),
      in: directory,
    )
    as "git runs"
  done
}

/// Writes a file, making its directory.
pub fn write(path: String, text: String) -> Nil {
  let assert Ok(Nil) = simplifile.create_directory_all(parent_of(path))
  let assert Ok(Nil) = simplifile.write(path, text) as "a file is written"
  Nil
}

fn parent_of(path: String) -> String {
  case string.split(path, "/") |> list.reverse {
    [_last, ..rest] -> string.join(list.reverse(rest), "/")
    [] -> "."
  }
}

/// Whether a path exists on disk.
pub fn exists(path: String) -> Bool {
  bootstrap.path_exists(path)
}

fn absolute(path: String) -> String {
  case string.starts_with(path, "/") {
    True -> path
    False -> {
      let assert Ok(here) = simplifile.current_directory()
        as "the test runner has a working directory"
      here <> "/" <> path
    }
  }
}

fn scratch(name: String) -> String {
  let directory =
    "build/worktree-"
    <> name
    <> "-"
    <> int.to_string(ffi_os.unique_positive_integer())
  let _removed = simplifile.delete(directory)
  directory
}
