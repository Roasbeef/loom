//// The project a workspace belongs to (`client/daemon/ui_project`), read from
//// real directories: a git worktree's pointer file confirmed by the
//// repository's backlink, a plain repository, a directory that is no
//// repository, and pointers that lead nowhere or that the repository does not
//// confirm.

import broker/token
import client/daemon/ui_project
import client/daemon/ui_socket
import gleam/bit_array
import gleam/option.{None, Some}
import host/bootstrap
import simplifile
import web_view/sessions

// A fresh directory under the test database root, as an absolute path.
fn fresh() -> String {
  let relative =
    "build/test_db/ui-project-"
    <> bit_array.base16_encode(token.production_entropy()(8))
  let assert Ok(Nil) = bootstrap.ensure_private_directory(relative)
    as "fixture directory exists"
  let assert Ok(path) = bootstrap.absolute_path(relative)
    as "fixture directory has an absolute path"
  path
}

// A repository at `root`, with a worktree named `name` checked out at `tree`
// whose `.git` file points at it and whose record in the repository names it
// back, as `git worktree add` writes both.
fn repository_with_worktree(root: String, tree: String, name: String) -> Nil {
  let record = root <> "/.git/worktrees/" <> name
  let assert Ok(Nil) = simplifile.create_directory_all(record)
  let assert Ok(Nil) = simplifile.create_directory_all(tree)
  let assert Ok(Nil) =
    simplifile.write(tree <> "/.git", "gitdir: " <> record <> "\n")
  let assert Ok(Nil) = simplifile.write(record <> "/gitdir", tree <> "/.git\n")
  Nil
}

// A worktree under `<repo>/.claude/worktrees/` is grouped under the
// repository's own directory, where its confirmed pointer leads.
pub fn a_worktree_belongs_to_the_repository_its_pointer_names_test() {
  let base = fresh()
  let root = base <> "/btcd"
  let tree = root <> "/.claude/worktrees/hungry-euclid-d93364"
  repository_with_worktree(root, tree, "hungry-euclid-d93364")

  assert ui_project.locate(tree) == Some(root)
}

// A relative pointer is read from the worktree's own directory, and the dots
// in it are resolved, so the project is the clean path of the repository.
pub fn a_relative_pointer_is_resolved_from_the_worktree_test() {
  let base = fresh()
  let root = base <> "/lnd"
  let tree = base <> "/lnd-fix"
  let record = root <> "/.git/worktrees/fix"
  let assert Ok(Nil) = simplifile.create_directory_all(record)
  let assert Ok(Nil) = simplifile.create_directory_all(tree)
  let assert Ok(Nil) =
    simplifile.write(tree <> "/.git", "gitdir: ../lnd/.git/worktrees/fix\n")
  let assert Ok(Nil) = simplifile.write(record <> "/gitdir", tree <> "/.git\n")

  assert ui_project.locate(tree) == Some(root)
}

// A plain checkout, whose `.git` is a directory, is its own project.
pub fn a_plain_repository_is_its_own_project_test() {
  let base = fresh()
  let root = base <> "/loom"
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/.git")

  assert ui_project.locate(root) == Some(root)
}

// A worktree of a bare repository belongs to the bare repository's own
// directory, since there is no checkout beside its common directory.
pub fn a_bare_repositorys_worktree_belongs_to_the_bare_directory_test() {
  let base = fresh()
  let root = base <> "/weft.git"
  let tree = base <> "/weft-main"
  let record = root <> "/worktrees/main"
  let assert Ok(Nil) = simplifile.create_directory_all(record)
  let assert Ok(Nil) = simplifile.create_directory_all(tree)
  let assert Ok(Nil) =
    simplifile.write(tree <> "/.git", "gitdir: " <> record <> "\n")
  let assert Ok(Nil) = simplifile.write(record <> "/gitdir", tree <> "/.git\n")

  assert ui_project.locate(tree) == Some(root)
}

// A directory with no `.git`, and one that is not there, have no project.
pub fn a_directory_that_is_no_repository_has_no_project_test() {
  let base = fresh()
  let notes = base <> "/notes"
  let assert Ok(Nil) = simplifile.create_directory_all(notes)

  assert ui_project.locate(notes) == None
  assert ui_project.locate(base <> "/missing") == None
}

// A pointer that cannot be followed is no project: text that is not a pointer,
// a path that is not a worktree's, and a repository that was deleted.
pub fn a_pointer_that_leads_nowhere_has_no_project_test() {
  let base = fresh()

  let garbled = base <> "/garbled"
  let assert Ok(Nil) = simplifile.create_directory_all(garbled)
  let assert Ok(Nil) = simplifile.write(garbled <> "/.git", "not a pointer\n")
  assert ui_project.locate(garbled) == None

  let odd = base <> "/odd"
  let assert Ok(Nil) = simplifile.create_directory_all(odd)
  let assert Ok(Nil) =
    simplifile.write(odd <> "/.git", "gitdir: /somewhere/else\n")
  assert ui_project.locate(odd) == None

  let orphan = base <> "/orphan"
  let assert Ok(Nil) = simplifile.create_directory_all(orphan)
  let assert Ok(Nil) =
    simplifile.write(
      orphan <> "/.git",
      "gitdir: " <> base <> "/deleted/.git/worktrees/orphan\n",
    )
  assert ui_project.locate(orphan) == None
}

// A hostile `.git` can point at any repository on the host. The pointer is
// accepted only when the repository's own record of the worktree names this
// workspace, so the same pointer is refused without the backlink, refused when
// the backlink names another workspace, and accepted when it names this one.
pub fn a_pointer_needs_the_repositorys_backlink_test() {
  let base = fresh()
  let root = base <> "/victim"
  let record = root <> "/.git/worktrees/real"
  let assert Ok(Nil) = simplifile.create_directory_all(record)
  let hostile = base <> "/hostile"
  let assert Ok(Nil) = simplifile.create_directory_all(hostile)
  let assert Ok(Nil) =
    simplifile.write(hostile <> "/.git", "gitdir: " <> record <> "\n")

  // A real repository, but no backlink at all.
  assert ui_project.locate(hostile) == None

  // A backlink to some other worktree.
  let assert Ok(Nil) =
    simplifile.write(record <> "/gitdir", base <> "/elsewhere/.git\n")
  assert ui_project.locate(hostile) == None

  // The repository's record names this workspace.
  let assert Ok(Nil) =
    simplifile.write(record <> "/gitdir", hostile <> "/.git\n")
  assert ui_project.locate(hostile) == Some(root)
}

// The size cap is checked before anything is read. A valid, confirmed pointer
// padded past the cap with newlines is refused, so this fails if the cap goes;
// the same goes for a backlink padded past it.
pub fn a_pointer_past_the_size_cap_is_never_read_test() {
  let base = fresh()
  let root = base <> "/btcd"
  let tree = base <> "/padded"
  repository_with_worktree(root, tree, "padded")
  assert ui_project.locate(tree) == Some(root)

  let record = root <> "/.git/worktrees/padded"
  let padding = newlines(5000)
  let assert Ok(Nil) =
    simplifile.write(tree <> "/.git", "gitdir: " <> record <> "\n" <> padding)
  assert ui_project.locate(tree) == None

  let assert Ok(Nil) =
    simplifile.write(tree <> "/.git", "gitdir: " <> record <> "\n")
  let assert Ok(Nil) =
    simplifile.write(record <> "/gitdir", tree <> "/.git\n" <> padding)
  assert ui_project.locate(tree) == None
}

fn newlines(count: Int) -> String {
  case count {
    0 -> ""
    _ -> "\n" <> newlines(count - 1)
  }
}

// The daemon fills each listed entry's project from the disk, by the workspace
// the catalogue recorded, and leaves one that has none without.
pub fn listed_entries_take_the_project_of_their_workspace_test() {
  let base = fresh()
  let root = base <> "/btcd"
  let tree = root <> "/.claude/worktrees/one"
  repository_with_worktree(root, tree, "one")
  let notes = base <> "/notes"
  let assert Ok(Nil) = simplifile.create_directory_all(notes)
  let in_tree =
    sessions.Entry("a", "", tree, 0, sessions.Saved, None, None, None)
  let in_notes = sessions.Entry(..in_tree, id: "b", workspace: notes)

  assert ui_socket.with_projects([in_tree, in_notes])
    == [sessions.Entry(..in_tree, project: Some(root)), in_notes]
}
