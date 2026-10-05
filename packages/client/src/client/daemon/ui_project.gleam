//// The project a session's workspace belongs to, for the web view's lists
//// (protocol-change/065, the addendum on grouping by project).
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
//// for a bare repository, the repository's own directory. A workspace with no
//// `.git`, or one whose pointer cannot be followed to a repository that is
//// there, has no project, and the page treats its workspace as its own. A
//// worktree whose repository was deleted is the second case, which is why the
//// answer is checked on the disk and not read off the pointer's shape alone.
////
//// The answer for a workspace is stable for the life of the daemon, and the
//// lists are read on every refresh, so `Projects` is a small actor that
//// derives each workspace once and keeps the answer. It is asked with a list
//// of workspaces and answers a dictionary, so one read is one message. An
//// answer that does not arrive in time is an empty dictionary, which leaves
//// every session its own project for that read: a slow disk makes a list
//// read flat and never makes it wait. A repository created in a workspace
//// after the daemon first listed it keeps the answer it had until the daemon
//// restarts, a rare case that a restart cures.
////
//// ## Flow
////
//// - `start` starts the actor, once, with the web view.
//// - `of` asks it for the project of each of a list's workspaces.
//// - `locate` is the filesystem read the actor runs for a
////   workspace it has not seen.

import broker/internal/call
import filepath
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile
import telemetry/owner
import weft/actor

/// A handle on the cache actor.
pub opaque type Projects {
  Projects(subject: Subject(Message))
}

type Message {
  Ask(workspaces: List(String), reply: Subject(Dict(String, Option(String))))
}

/// The most bytes of a `.git` pointer file `locate` reads. A real pointer is
/// one short line, and a file beyond this is not one.
const pointer_limit = 4096

/// How long `of` waits for the actor, in milliseconds. The first read of a
/// workspace touches the disk, so the bound is generous, and an answer past it
/// is dropped and read again on the next refresh.
const wait_ms = 2000

/// Starts the cache.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(projects) = ui_project.start()
/// ```
pub fn start() -> Result(Projects, String) {
  actor.new_with_initialiser(1000, fn(subject) {
    // The cache belongs to the daemon and not to any session. It takes the
    // web view table's label, the nearest of the daemon's own.
    owner.label([], owner.PageSessions)
    actor.initialised(dict.new())
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.start
  |> result.map(fn(started) { Projects(started.data) })
  |> result.replace_error("the web view's project cache did not start")
}

// One read: the workspaces the cache has not seen are derived now, each once,
// and the answer is the cache's entry for every workspace asked for.
fn handle(
  cache: Dict(String, Option(String)),
  message: Message,
) -> actor.Next(Dict(String, Option(String)), Message) {
  case message {
    Ask(workspaces:, reply:) -> {
      let cache =
        list.fold(workspaces, cache, fn(known, workspace) {
          case dict.has_key(known, workspace) {
            True -> known
            False -> dict.insert(known, workspace, locate(workspace))
          }
        })
      let answer =
        list.fold(workspaces, dict.new(), fn(found, workspace) {
          case dict.get(cache, workspace) {
            Ok(project) -> dict.insert(found, workspace, project)
            Error(Nil) -> found
          }
        })
      process.send(reply, answer)
      actor.continue(cache)
    }
  }
}

/// The project of each workspace, by workspace. A workspace the cache could
/// not answer for in time is missing from the dictionary, and a caller treats
/// that as no project.
///
/// ## Examples
///
/// ```gleam
/// // ui_project.of(projects, ["/src/loom"])
/// ```
pub fn of(
  projects: Projects,
  workspaces: List(String),
) -> Dict(String, Option(String)) {
  call.try_call(projects.subject, waiting: wait_ms, sending: Ask(
    list.unique(workspaces),
    _,
  ))
  |> result.lazy_unwrap(dict.new)
}

/// The project of one workspace read from the disk now: the workspace itself
/// for a plain checkout, the main repository's directory for a git worktree,
/// and nothing for a directory that is no repository or whose pointer cannot be
/// followed to one that exists.
///
/// ## Examples
///
/// ```gleam
/// // With /work/tree/.git reading "gitdir: /work/repo/.git/worktrees/tree"
/// // and /work/repo/.git a directory:
/// assert ui_project.locate("/work/tree") == Some("/work/repo")
/// ```
pub fn locate(workspace: String) -> Option(String) {
  let marker = filepath.join(workspace, ".git")
  case simplifile.is_directory(marker), simplifile.is_file(marker) {
    Ok(True), _ -> Some(workspace)
    _, Ok(True) ->
      pointer(marker)
      |> result.try(repository(_, workspace))
      |> option.from_result
    _, _ -> None
  }
}

// The text of a worktree's `.git` file, which is one `gitdir:` line.
fn pointer(marker: String) -> Result(String, Nil) {
  use bytes <- result.try(
    simplifile.read_bits(marker) |> result.replace_error(Nil),
  )
  case bit_array.byte_size(bytes) <= pointer_limit {
    True -> bit_array.to_string(bytes)
    False -> Error(Nil)
  }
}

// The repository a pointer leads to. The pointer names the worktree's own
// directory inside the repository, `<common>/worktrees/<name>`, so the common
// directory is two levels up. A common directory called `.git` belongs to the
// checkout beside it, whose directory is the project; any other (a bare
// repository) is the project itself. Either must exist, or the worktree's
// repository is gone and the pointer leads nowhere.
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
      case filepath.base_name(common) {
        ".git" -> Ok(filepath.directory_name(common))
        _ -> Ok(common)
      }
    }
    _ -> Error(Nil)
  }
}
