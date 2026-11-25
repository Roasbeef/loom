//// A Git worktree for each local session that asked for one
//// (protocol-change/133).
////
//// A session created with a `worktree` choice works in a linked worktree of its
//// folder, on a branch of its own, instead of in the folder. `client/worktrees`
//// already owns that tree's whole life for a workspace an executor serves
//// (protocol-change/095): it creates the tree at the first attach, adopts or
//// recreates it at a reopen, removes it at a clean close and keeps it when it
//// holds changes. This module adds the one thing a local session needs on top:
//// a `Worktrees` service for each folder, started the first time a session of
//// that folder asks.
////
//// ## Why a service for each folder
////
//// A `Worktrees` serves a fixed list of workspaces, each with a gate that runs
//// its Git work one job at a time, because `git worktree` rewrites files in the
//// repository's `.git` and two jobs on one repository would race. An executor
//// knows its workspaces when it starts. A daemon does not know its folders: the
//// owner names one whenever a session is created. So a folder becomes a
//// workspace named for it (`workspace_of`), and the first session that needs it
//// starts a service whose gate then orders every later session of the same
//// folder. Two sessions of one folder therefore never run `git worktree` at
//// once, and sessions of different folders never wait for each other.
////
//// ## Who owns the services
////
//// A service's processes (its sandboxed Git and its gate) are linked to the
//// process that started it. A session's builder lives only as long as the
//// build, so it cannot be the starter. A registry process, started once with
//// the daemon, is: it starts each folder's service from its own turn and keeps
//// it for the life of the daemon. The registry answers only "which service
//// serves this folder"; the Git work itself runs in the folder's gate, never in
//// the registry's turn, so a long checkout in one folder does not delay another
//// folder's lookup.
////
//// ## Flow
////
//// `start` → `open` → `close`
////
//// 1. `start` begins the registry with the function that builds one folder's
////    service.
//// 2. `open` runs when a session is built: it finds or starts the folder's
////    service and has `worktrees.open` create, adopt or recreate the tree.
//// 3. `close` runs when the session's tools have stopped for good: it has
////    `worktrees.close` remove a clean tree and keep one that holds changes.

import client/workspaces.{type Workspace}
import client/worktrees.{type Closed, type Tree, type Worktrees}
import gleam/bit_array
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/result
import gleam/string
import weft/actor

/// How long a lookup waits for the registry. The registry starts a service in
/// its own turn, which boots a sandboxed Git and a gate and checks the
/// repository, so the wait covers a cold start and nothing else.
pub const lookup_within_ms = 60_000

/// The registry of the worktree services of a daemon's local folders.
pub opaque type LocalTrees {
  LocalTrees(registry: Subject(Lookup))
}

// A request to the registry: the service for this workspace, started if it is
// the first ask. The answer travels on a subject only the asker holds.
type Lookup {
  Lookup(workspace: Workspace, reply: Subject(Result(Worktrees, String)))
}

// What the registry keeps between requests: the services it has started, by
// the workspace name that names their folder, and the function that starts one.
type Services {
  Services(
    start: fn(Workspace) -> Result(Worktrees, String),
    held: Dict(String, Worktrees),
  )
}

/// Starts the registry. `service` builds one folder's `Worktrees` and runs in
/// the registry's own process, so the processes it starts are linked to the
/// registry and live as long as it does.
///
/// ## Examples
///
/// ```gleam
/// // local_trees.start(fn(workspace) { executor_plane.worktrees_of(machine, [workspace]) })
/// ```
pub fn start(
  service: fn(Workspace) -> Result(Worktrees, String),
) -> Result(LocalTrees, String) {
  actor.new(Services(start: service, held: dict.new()))
  |> actor.on_message(serve_lookup)
  |> actor.start
  |> result.map(fn(started) { LocalTrees(registry: started.data) })
  |> result.map_error(fn(error) {
    "the local worktree registry did not start: " <> string.inspect(error)
  })
}

/// The workspace a folder becomes: a name made of the folder's digest, so that
/// the same folder always has the same name and the same ledger rows, and the
/// session's own base.
///
/// The name is `local-` and sixteen hex digits of the SHA-256 of the folder's
/// canonical path. It is a directory name under the state root's `worktrees/`,
/// so it holds only characters `worktrees.safe_component` accepts.
///
/// ## Examples
///
/// ```gleam
/// let workspace = local_trees.workspace_of("/src/loom", "HEAD")
/// assert workspace.root == "/src/loom"
/// assert workspace.mode == workspaces.Worktree("HEAD")
/// ```
pub fn workspace_of(folder: String, base: String) -> Workspace {
  let digest =
    crypto.hash(crypto.Sha256, bit_array.from_string(folder))
    |> bit_array.base16_encode
    |> string.lowercase
    |> string.slice(0, 16)
  workspaces.Workspace(
    name: "local-" <> digest,
    root: folder,
    mode: workspaces.Worktree(base:),
  )
}

/// Creates, adopts or recreates the session's tree in a worktree of `folder`
/// and answers where it is. The branch starts from `base` the first time; a
/// reopen finds the session's own branch and ignores it.
///
/// ## Examples
///
/// ```gleam
/// // local_trees.open(trees, "/src/loom", "HEAD", "0198c0de-0000-7000-8000-000000000001")
/// ```
pub fn open(
  trees: LocalTrees,
  folder: String,
  base: String,
  session: String,
) -> Result(Tree, String) {
  let workspace = workspace_of(folder, base)
  use service <- result.try(service_of(trees, workspace))
  worktrees.open(service, workspace, session)
}

/// Settles the session's tree once its tools have stopped: a clean tree is
/// removed and its branch stays, a tree with changes is kept. A close that
/// cannot run answers `Kept` with the reason, because the retirement that calls
/// it has no use for an error.
///
/// ## Examples
///
/// ```gleam
/// // local_trees.close(trees, "/src/loom", "HEAD", "0198c0de-0000-7000-8000-000000000001")
/// ```
pub fn close(
  trees: LocalTrees,
  folder: String,
  base: String,
  session: String,
) -> Closed {
  let workspace = workspace_of(folder, base)
  let service = service_of(trees, workspace)

  // A service that cannot be had leaves the tree where it is.
  case service {
    Ok(service) -> worktrees.close(service, workspace, session)
    Error(reason) -> worktrees.Kept(reason)
  }
}

/// Asks the registry for the folder's service, waiting for a start if this is
/// the folder's first session.
fn service_of(
  trees: LocalTrees,
  workspace: Workspace,
) -> Result(Worktrees, String) {
  let reply = process.new_subject()
  process.send(trees.registry, Lookup(workspace:, reply:))

  // The registry answers from its own turn, and a start that outlasts the wait
  // is reported rather than waited for.
  case process.receive(reply, lookup_within_ms) {
    Ok(answer) -> answer
    Error(Nil) -> Error("the local worktree registry did not answer in time")
  }
}

/// Answers one lookup: the folder's service if the registry holds it, and a
/// start otherwise. A start that fails is answered and not remembered, so the
/// next session of the folder tries again instead of inheriting a stale
/// refusal.
fn serve_lookup(
  services: Services,
  lookup: Lookup,
) -> actor.Next(Services, Lookup) {
  // A folder that has had a session before already has its service.
  case dict.get(services.held, lookup.workspace.name) {
    Ok(service) -> {
      process.send(lookup.reply, Ok(service))
      actor.continue(services)
    }

    // The folder's first session starts it, in this process, so its Git and
    // gate are linked to the registry and not to the session's builder.
    Error(Nil) ->
      case services.start(lookup.workspace) {
        Ok(service) -> {
          process.send(lookup.reply, Ok(service))
          actor.continue(
            Services(
              ..services,
              held: dict.insert(services.held, lookup.workspace.name, service),
            ),
          )
        }

        Error(reason) -> {
          process.send(lookup.reply, Error(reason))
          actor.continue(services)
        }
      }
  }
}
