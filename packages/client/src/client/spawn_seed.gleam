//// The receiving end of a spawn that carries the parent's workspace
//// (protocol-change/107, "Spawn: sending the parent's state with a child").
////
//// A parent on one orchestrator can ask for a child that starts from its
//// workspace. The sender captures the workspace into a state, sends the bundle in
//// pieces to this machine's state store, and asks for the child with the state's
//// description in the request. This module is what the receiver does with that
//// request before it reaches the delegate session's Agency: it judges whether the
//// spawner may send a state at all, checks that the whole bundle is in the store,
//// applies it into a repository of its own, and tells the child where its copy is.
//// The child never starts from a half-made copy. Every failure is a
//// `SpawnRefusal`, and the request that passes is the one the Agency has always
//// served.
////
//// ## What decides
////
//// The `seed` key of the spawner's table (`client/spawners`) is the owner's
//// ceiling, and it is checked first, before the store is looked at or any
//// directory made, so a spawner with `seed = "none"` leaves no trace. The
//// placement decides where a copy can be made. The child shares its delegate
//// session's workspace, so the copy is made as a repository inside it, at
//// `seeds/<name>` under the spawner's `directory`, and the child's brief is told
//// where it is. A spawner placed on an executor or a pool has its workspace on
//// another machine, where the apply would have to run, and is refused with a
//// reason that says so.
////
//// ## Where the copy is made
////
//// The directory the copy lands in is the spawner's own, from the table the
//// operator wrote. Nothing in the request names a path: the copy's name is a
//// digest of the parent's call site and the state, so a resent spawn finds the
//// copy it made and makes no second one, and no peer text reaches a path. The
//// apply itself runs in a stage the daemon owns that no session can write
//// (`<state root>/seed-staging`, in no session's writable roots), and the finished repository is
//// moved into the workspace with one rename. A session therefore cannot touch
//// the repository while it is being made, and a copy that exists at its name is a
//// copy that is whole. The stage is readable as the rest of the host is, because
//// the copy lands in a directory the host can read too, and it cannot be masked:
//// the sandboxed Git that makes the repository must write it, and a mask over a
//// directory wins over a write grant inside it.
////
//// ## Flow
////
//// `receive` → `permitted` → `held` → `applied` → `briefed`
////
//// 1. `receive` passes a request with no state through unchanged.
//// 2. `permitted` judges the spawner's ceiling, its placement and the
////    description.
//// 3. `held` finds the whole bundle in the store, or answers `StateMissing` with
////    the bytes it holds so the sender resumes.
//// 4. `applied` makes the copy, or finds the one an earlier attempt made.
//// 5. `briefed` tells the child where its copy is, in words appended to its
////    brief.

import client/remote_spawn.{
  type CallSite, type Request, type SpawnRefusal, StateMissing, StateRefused,
  StoreFailure,
}
import client/spawners.{type Spawner, InDirectory, NoSeed, WorkspaceSeed}
import client/state_apply
import client/state_node.{type StateNode}
import client/state_object.{type State}
import client/state_store
import client/state_transfer
import client/worktree_git
import core/ids
import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import simplifile
import tools/agent

/// The directory under a spawner's `directory` that holds the copies.
pub const seeds_directory = "seeds"

/// Judges a request that may carry a state and prepares the copy it names.
///
/// A request with no state is returned as it is. One with a state is returned
/// with its brief amended to say where the child's copy is and its `state` cleared,
/// since the Agency serves what the request asks of the child and the state has
/// done its work. Any other answer is a refusal: `StateMissing` when the bundle
/// is not all in the store, which the sender answers by sending the rest, and
/// `StateRefused` for everything else about the state, which resending cannot
/// change.
///
/// ## Examples
///
/// ```gleam
/// // spawn_seed.receive(node, spawner, call_site, request) == Ok(request) for a request with no state
/// ```
pub fn receive(
  node: StateNode,
  spawner: Spawner,
  site: CallSite,
  request: Request,
) -> Result(Request, SpawnRefusal) {
  // A request with no state is the request it always was.
  case request.state {
    None -> Ok(request)
    Some(state) -> {
      use directory <- result.try(permitted(spawner, state))
      use held <- result.try(held(node, state))
      use name <- result.map(applied(node, directory, site, held))
      remote_spawn.Request(
        ..request,
        brief: request.brief <> briefed(name),
        state: None,
      )
    }
  }
}

/// Judges the spawner's ceiling, its placement and the description, and answers
/// the directory the copy goes under.
///
/// ## Examples
///
/// ```gleam
/// // spawn_seed.permitted(spawner_with_seed_none, state) == Error(StateRefused(..))
/// ```
pub fn permitted(
  spawner: Spawner,
  state: State,
) -> Result(String, SpawnRefusal) {
  use <- bool.lazy_guard(when: spawner.seed == NoSeed, return: fn() {
    Error(StateRefused(
      "this machine's table [spawners."
      <> spawner.name
      <> "] has seed = \"none\", so it takes no workspace with a spawn. Its owner "
      <> "can set seed = \"workspace\" to allow it",
    ))
  })
  use state <- result.try(
    state_object.validate(state)
    |> result.map_error(fn(reason) {
      StateRefused("the state is not a valid description: " <> reason)
    }),
  )
  use <- bool.guard(
    when: state.size > state_object.size_limit,
    return: Error(StateRefused("the state is over the size limit")),
  )

  // The seed ceiling is the owner's to widen, and the placement is the owner's
  // to choose; this release makes a copy only where this machine holds the
  // workspace.
  case spawner.seed, spawner.placement {
    WorkspaceSeed, InDirectory(path:) ->
      bootstrap.canonical_directory(path)
      |> result.replace_error(StateRefused(
        "the spawner's directory is not usable on this machine",
      ))
    WorkspaceSeed, spawners.OnExecutor(..)
    | WorkspaceSeed, spawners.InPool(..)
    ->
      Error(StateRefused(
        "the table [spawners."
        <> spawner.name
        <> "] places its children on an executor, and a workspace is applied "
        <> "where the children run; this release applies it only for a "
        <> "`directory` placement",
      ))
    NoSeed, _ -> Error(StateRefused("the spawner takes no workspace"))
  }
}

/// Finds the whole bundle in the store, or says how much of it is there.
fn held(
  node: StateNode,
  state: State,
) -> Result(state_store.Held, SpawnRefusal) {
  case node.store {
    None -> Error(StateRefused("this machine keeps no state store"))
    Some(store) ->
      case node.endpoint.stage(state.hash) {
        Error(reason) -> Error(StoreFailure(reason:))
        Ok(state_transfer.Absent) -> Error(StateMissing(state.hash, 0))
        Ok(state_transfer.Partial(held:)) ->
          Error(StateMissing(state.hash, held))
        Ok(state_transfer.Complete) -> whole(store, state)
      }
  }
}

/// Reads the complete state back from the store, which hashes it again.
fn whole(
  store: state_store.Store,
  state: State,
) -> Result(state_store.Held, SpawnRefusal) {
  case state_store.get(store, state.hash) {
    Ok(Some(found)) ->
      case found.state == state {
        True -> Ok(found)
        False ->
          Error(StateRefused(
            "the description in the request is not the one the stored state has",
          ))
      }
    Ok(None) -> Error(StateMissing(state.hash, 0))
    Error(reason) -> Error(StoreFailure(reason:))
  }
}

/// Makes the copy, or finds the one an earlier attempt made, and answers its name.
///
/// The copy is a repository in the node's private stage until it is whole, and
/// is then renamed into `<directory>/seeds`. A copy at its final name is whole,
/// because nothing else makes that name, so a resent spawn finds it and applies
/// nothing.
fn applied(
  node: StateNode,
  directory: String,
  site: CallSite,
  held: state_store.Held,
) -> Result(String, SpawnRefusal) {
  let name = name_of(site, held.state)
  let final = directory <> "/" <> seeds_directory <> "/" <> name
  use <- bool.guard(when: bootstrap.path_exists(final), return: Ok(name))

  // The copy is made by this node's own sandboxed Git, and a node without one
  // cannot make it.
  case node.git {
    None ->
      Error(StateRefused(
        "this machine has no sandboxed Git to apply a workspace with",
      ))
    Some(git) -> {
      use stage <- result.try(staged(node, name))
      use Nil <- result.try(made(git, held, stage, name))
      published(stage, directory, final, name)
    }
  }
}

/// The name of the copy: a digest of the parent's call site and the state's hash,
/// so the same spawn names the same copy and no peer text is ever a path.
///
/// ## Examples
///
/// ```gleam
/// // spawn_seed.name_of(site, state) == "seed-0123456789abcdef"
/// ```
pub fn name_of(site: CallSite, state: State) -> String {
  // A program's spawns are told apart by their ordinal, as the call site does.
  let minter = case site.minter {
    agent.ToolCall -> "tool"
    agent.Program(ordinal) -> "program" <> int.to_string(ordinal)
  }

  let text =
    string.join(
      [
        ids.op_id_to_string(site.operation),
        site.step_id,
        int.to_string(site.source_index),
        minter,
        state.hash,
      ],
      "\n",
    )
  "seed-"
  <> string.slice(state_object.hash_of(bit_array.from_string(text)), 0, 16)
}

/// The node's stage for one copy, made fresh. No session can write it, and a
/// leftover from an attempt that did not finish is removed because the stage
/// belongs to this daemon alone.
fn staged(node: StateNode, name: String) -> Result(String, SpawnRefusal) {
  let parent = node.state_root <> "/seed-staging"
  use Nil <- result.try(
    bootstrap.ensure_private_directory(parent)
    |> result.map_error(fn(reason) { StoreFailure(reason:) }),
  )
  let stage = parent <> "/" <> name
  let _removed = simplifile.delete(stage)
  Ok(stage)
}

/// Applies the bundle into the stage as a repository on the copy's own branch.
fn made(
  git: worktree_git.Git,
  held: state_store.Held,
  stage: String,
  name: String,
) -> Result(Nil, SpawnRefusal) {
  state_apply.apply(
    git,
    held.path,
    held.state,
    state_apply.Clone(destination: stage, session: name),
  )
  |> result.map(fn(_applied) { Nil })
  |> result.map_error(fn(reason) {
    let _removed = simplifile.delete(stage)
    StateRefused(worktree_git.printable(
      "applying the state failed: " <> reason,
      512,
    ))
  })
}

/// Moves the finished repository into the spawner's workspace. A rename cannot
/// be redirected through a link in its last component, and a copy that is there
/// by the time it lands was made by an attempt that finished first.
fn published(
  stage: String,
  directory: String,
  final: String,
  name: String,
) -> Result(String, SpawnRefusal) {
  let seeds = directory <> "/" <> seeds_directory
  use Nil <- result.try(
    simplifile.create_directory_all(seeds)
    |> result.map_error(fn(_error) {
      StateRefused("the spawner's directory cannot hold a copy")
    }),
  )

  // The rename is the publication: it either makes the whole copy appear or
  // leaves the stage to be removed.
  case simplifile.rename(stage, final) {
    Ok(Nil) -> Ok(name)
    Error(_error) ->
      case bootstrap.path_exists(final) {
        True -> {
          let _removed = simplifile.delete(stage)
          Ok(name)
        }
        False -> {
          let _removed = simplifile.delete(stage)
          Error(StateRefused(
            "the copy could not be moved into the spawner's directory: the "
            <> "directory and this daemon's state directory must be on one "
            <> "filesystem",
          ))
        }
      }
  }
}

/// The words appended to the child's brief, which say where its copy is.
///
/// ## Examples
///
/// ```gleam
/// // spawn_seed.briefed("seed-0123456789abcdef")
/// ```
pub fn briefed(name: String) -> String {
  "\n\nYour working copy: you were started from the workspace of the session "
  <> "that asked for you, as it was when it asked, uncommitted edits and new "
  <> "files included. It is a Git repository at `"
  <> seeds_directory
  <> "/"
  <> name
  <> "` under your workspace, on the branch `loom/"
  <> name
  <> "`, and its newest commit may be a snapshot of that uncommitted work. Do "
  <> "your work there: use paths that begin `"
  <> seeds_directory
  <> "/"
  <> name
  <> "/`, or `cd` into it. Commit what you change. Nothing is pushed anywhere."
}
