//// A project's repositories over a real owner checkout, for the tests of
//// clone isolation: the host repository, a ticket's clone and the commits a
//// worker makes in it, all through the production `client/project_repo` and
//// the shipped sandbox helper.
////
//// The rig is `worktree_rig`'s, a repository with one commit on `main`, a
//// state root laid out as a daemon leaves it and the production sandboxed
//// Git. This module adds the project's directories and the host repository on
//// top, and a few verbs for what a worker does in its clone. Git is run here
//// as the operator, outside any jail, because the tests are the operator: what
//// is under test is what the host does with a repository a worker wrote.

import client/project_repo
import client/worktrees
import gleam/io
import gleam/list
import gleam/string
import host/bootstrap
import simplifile
import support/worktree_rig

/// The project every rig stands for.
pub const project = "p-1"

/// The layout of the rig's project.
pub fn layout(rig: worktree_rig.Rig) -> project_repo.Layout {
  project_repo.Layout(state_root: rig.state, project:, owner: rig.root)
}

/// The rig's project with its directories made and its host repository
/// ensured, as a project's actor does at its start.
pub fn started(rig: worktree_rig.Rig) -> project_repo.Layout {
  let assert Ok(Nil) =
    bootstrap.ensure_private_directory(rig.state <> "/projects")
    as "the projects directory is made"
  let assert Ok(Nil) =
    bootstrap.ensure_private_directory(rig.state <> "/projects/" <> project)
    as "the project directory is made"
  let found = layout(rig)
  let assert Ok(Nil) = project_repo.ensure_host(rig.trees, found)
    as "the host repository is ensured"
  found
}

/// Makes an assignment's clone and answers its path.
pub fn cloned(
  rig: worktree_rig.Rig,
  found: project_repo.Layout,
  name: String,
) -> String {
  cloned_from(rig, found, name, project_repo.FromOwner)
}

/// Makes an assignment's clone at the start given and answers its path.
pub fn cloned_from(
  rig: worktree_rig.Rig,
  found: project_repo.Layout,
  name: String,
  start: project_repo.Start,
) -> String {
  let assert Ok(path) = project_repo.clone(rig.trees, found, name, start)
    as "the clone is made"
  path
}

/// A worker's commit: writes the files, adds everything and commits, then
/// answers the new head.
pub fn commit(clone: String, files: List(#(String, String))) -> String {
  list.each(files, fn(file) {
    worktree_rig.write(clone <> "/" <> file.0, file.1)
  })
  worktree_rig.git(clone, ["add", "-A"])
  worktree_rig.git(clone, ["commit", "--quiet", "-m", "work"])
  worktree_rig.git(clone, ["rev-parse", "HEAD"])
}

/// A record of everything in a repository that a worker's write could change
/// to the owner's harm: its configuration, its hooks, its refs, its `HEAD`
/// and the objects its refs name. Equal digests before and after a scenario
/// are the claim that nothing reached the owner's repository. It stays text so
/// that a failed comparison names the part that moved.
pub fn digest(repository: String) -> String {
  let assert Ok(config) = simplifile.read(repository <> "/.git/config")
    as "the configuration is readable"
  let hooks = case simplifile.read_directory(repository <> "/.git/hooks") {
    Ok(names) -> string.join(list.sort(names, string.compare), ",")
    Error(_) -> "no hooks directory"
  }
  let refs = worktree_rig.git(repository, ["for-each-ref"])
  let head = worktree_rig.git(repository, ["rev-parse", "HEAD"])

  // Every object by name, not `count-objects -v`, whose sizes are disk blocks
  // and change on Linux when the filesystem flushes a delayed write.
  let objects =
    worktree_rig.git(repository, [
      "cat-file", "--batch-all-objects", "--batch-check",
    ])
  string.join([config, hooks, refs, head, objects], "\n--\n")
}

/// The parts of two records of a repository that differ, in words, and an empty
/// string when they agree. A test runner cuts a long value short, so a failure
/// prints the whole of what moved to stderr, where the log keeps it.
pub fn moved(before: String, after: String) -> String {
  let found =
    list.zip(string.split(before, "\n--\n"), string.split(after, "\n--\n"))
    |> list.filter(fn(pair) { pair.0 != pair.1 })
    |> list.map(fn(pair) { "was: " <> pair.0 <> " now: " <> pair.1 })
    |> string.join("\n")

  // A clean comparison prints nothing, so the log holds only what moved.
  case found {
    "" -> Nil
    _ -> io.println_error(found)
  }
  found
}

/// The host repository's ref for a commit taken in for a ticket, or an empty
/// string when the host repository has none.
pub fn ticket_ref_of(
  found: project_repo.Layout,
  ticket: String,
  commit: String,
) -> String {
  let #(code, output) =
    worktree_rig.git_status(project_repo.host_path(found), [
      "rev-parse",
      "--verify",
      "--quiet",
      project_repo.ticket_ref(ticket, commit),
    ])
  case code {
    0 -> string.trim(output)
    _ -> ""
  }
}

/// Stops the rig's Git service, for a test that has finished with it.
pub fn stop(rig: worktree_rig.Rig) -> Nil {
  worktrees.stop(rig.trees)
}
