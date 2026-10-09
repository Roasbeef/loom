//// The project a session's workspace belongs to, for the web view's lists.
////
//// A person thinks of a session by the repository it works on, and not by the
//// directory it runs in. A session started in a git worktree runs in a path
//// like `<repo>/.claude/worktrees/hungry-euclid-d93364`, which names the
//// worktree and says nothing of the repository, so grouping by directory put
//// every worktree under its own heading. The web view groups by project
//// instead, and this module finds it. It is filesystem work, which is why it
//// lives in the daemon and never in `web_view`, `session_view` or `core`.
////
//// `locate` reads a workspace's `.git`. A directory means a plain checkout,
//// whose project is the workspace itself. A file is a worktree's pointer,
//// `gitdir: <repo>/.git/worktrees/<name>`, and the project is the repository
//// that path leads to: the directory holding the `.git` the pointer names, or,
//// for a bare repository, the repository's own directory.
////
//// A workspace is host text a session's agent can write into, so the pointer is
//// not trusted on its own. A hostile `.git` could name any directory on the host
//// and regroup its session under someone else's repository. Git writes the
//// other half of the link: `<repo>/.git/worktrees/<name>/gitdir` holds the path
//// of this worktree's `.git` file. The pointer is accepted only when that
//// backlink exists and names this workspace, so a workspace can claim only a
//// repository that has already registered it. Every read is bounded first: the
//// file's size comes from `file_info`, which follows symlinks, and a file past
//// `pointer_limit` is never read.
////
//// There is no cache. The read is three stats and two small files, and the
//// lists run it once for each entry from the task that already reads the
//// catalogue, every 30 seconds, so no page runtime waits on the disk. A
//// workspace with no `.git`, or whose pointer cannot be followed to a
//// repository that registers it, has no project, and the page treats its
//// workspace as its own.

import filepath
import gleam/bit_array
import gleam/bool
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile

/// The most bytes of a pointer or backlink file `locate` reads. A real one is a
/// single short line, and a file beyond this is not one.
const pointer_limit = 4096

/// The project of one workspace read from the disk now: the workspace itself for
/// a plain checkout, the main repository's directory for a git worktree that the
/// repository registers, and nothing for a directory that is no repository or
/// whose pointer cannot be followed and confirmed. A workspace that is not an
/// absolute path, which is how a workspace registered on an executor is
/// stored, has no project and is never read.
///
/// ## Examples
///
/// ```gleam
/// // With /work/tree/.git reading "gitdir: /work/repo/.git/worktrees/tree" and
/// // /work/repo/.git/worktrees/tree/gitdir reading "/work/tree/.git":
/// assert ui_project.locate("/work/tree") == Some("/work/repo")
/// ```
pub fn locate(workspace: String) -> Option(String) {
  // A workspace registered on an executor is a name, which has no `/` and so
  // is never an absolute path; joined to `.git` it would be read relative to
  // the daemon's own directory. Only a path on this host has a disk to read.
  use <- bool.guard(!string.starts_with(workspace, "/"), None)
  let marker = filepath.join(workspace, ".git")
  case simplifile.file_info(marker) {
    Ok(info) ->
      case simplifile.file_info_type(info) {
        simplifile.Directory -> Some(workspace)
        simplifile.File ->
          small_text(marker)
          |> result.try(repository(_, workspace))
          |> option.from_result
        simplifile.Symlink | simplifile.Other -> None
      }
    Error(_) -> None
  }
}

// The text of a small regular file. The size is checked before anything is
// read, so a huge or sparse file, or a link to one, costs a stat.
fn small_text(path: String) -> Result(String, Nil) {
  use info <- result.try(
    simplifile.file_info(path) |> result.replace_error(Nil),
  )
  case
    simplifile.file_info_type(info) == simplifile.File
    && info.size <= pointer_limit
  {
    True ->
      simplifile.read_bits(path)
      |> result.replace_error(Nil)
      |> result.try(bit_array.to_string)
    False -> Error(Nil)
  }
}

// The repository a pointer leads to, once its backlink confirms `workspace`.
// The pointer names the worktree's own directory inside the repository,
// `<common>/worktrees/<name>`, so the common directory is two levels up. A
// common directory called `.git` belongs to the checkout beside it, whose
// directory is the project; any other (a bare repository) is the project
// itself.
fn repository(text: String, workspace: String) -> Result(String, Nil) {
  case string.split(string.trim(text), "gitdir:") {
    ["", rest] -> {
      let named = string.trim(rest)
      use gitdir <- result.try(
        case filepath.is_absolute(named) {
          True -> named
          False -> filepath.join(workspace, named)
        }
        |> filepath.expand,
      )
      let worktrees = filepath.directory_name(gitdir)
      let common = filepath.directory_name(worktrees)
      use _ <- result.try(case filepath.base_name(worktrees) {
        "worktrees" -> Ok(Nil)
        _ -> Error(Nil)
      })
      use _ <- result.try(case simplifile.is_directory(common) {
        Ok(True) -> Ok(Nil)
        Ok(False) | Error(_) -> Error(Nil)
      })
      use _ <- result.map(registered(gitdir, workspace))
      case filepath.base_name(common) {
        ".git" -> filepath.directory_name(common)
        _ -> common
      }
    }
    _ -> Error(Nil)
  }
}

// Whether the repository's record of the worktree names this workspace's `.git`.
fn registered(gitdir: String, workspace: String) -> Result(Nil, Nil) {
  use backlink <- result.try(small_text(filepath.join(gitdir, "gitdir")))
  case string.trim(backlink) == filepath.join(workspace, ".git") {
    True -> Ok(Nil)
    False -> Error(Nil)
  }
}
