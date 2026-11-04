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
//// (`<state root>/seed-staging`, in no session's writable roots), and the
//// finished repository is moved into the workspace with one rename. A session therefore cannot touch
//// the repository while it is being made, and a copy that exists at its name is a
//// copy that is whole. The stage is readable as the rest of the host is, because
//// the copy lands in a directory the host can read too, and it cannot be masked:
//// the sandboxed Git that makes the repository must write it, and a mask over a
//// directory wins over a write grant inside it.
////
//// ## Flow
////
//// `receive` → `permitted` → `copy` → `held` → `applied` → `briefed`
////
//// 1. `receive` passes a request with no state through unchanged.
//// 2. `permitted` judges the spawner's ceiling, its placement and the
////    description, and `copy` returns at once for a copy that is already there.
//// 3. `held` finds the whole bundle in the store, or answers `StateMissing` with
////    the bytes it holds so the sender resumes.
//// 4. `applied` makes the copy in a process that outlives the asker, or finds
////    that another attempt is making it.
//// 5. `briefed` tells the child where its copy is, in words appended to its
////    brief.

import client/internal/ffi_os
import client/remote_spawn.{
  type CallSite, type Request, type SpawnRefusal, NotYetOpen, StateMissing,
  StateRefused, StoreFailure,
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
import gleam/erlang/process
import gleam/int
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import simplifile
import tools/agent
import weft

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
  receive_within(node, spawner, site, request, apply_ms)
}

/// `receive` for an asker that waits at most `wait_ms` for the copy to be made.
/// An apply that takes longer is not abandoned: it runs on, in a process of its
/// own, and the next ask for the same spawn finds the copy it made.
///
/// ## Examples
///
/// ```gleam
/// // spawn_seed.receive_within(node, spawner, call_site, request, 30_000)
/// ```
pub fn receive_within(
  node: StateNode,
  spawner: Spawner,
  site: CallSite,
  request: Request,
  wait_ms: Int,
) -> Result(Request, SpawnRefusal) {
  // A request with no state is the request it always was.
  case request.state {
    None -> Ok(request)
    Some(state) -> {
      use directory <- result.try(permitted(spawner, state))
      let name = name_of(site, state)
      use Nil <- result.map(copy(node, directory, name, state, wait_ms))
      remote_spawn.Request(
        ..request,
        brief: request.brief <> briefed(name),
        state: None,
      )
    }
  }
}

/// How long one apply may run in all, in milliseconds: the sandboxed Git's own
/// ten minutes for a checkout, and a margin.
pub const apply_ms = 660_000

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

/// Whether a copy is already at its final name.
type Settled {
  /// Nothing is there.
  Missing

  /// A real directory, at the canonical path the name gives it. Only a rename of
  /// a finished repository makes that name, so it is whole.
  Whole

  /// Something is there that this daemon did not put there: a link, a file, or a
  /// directory that resolves elsewhere.
  Tampered
}

/// Looks at a path without following a link in its last component.
fn settled(path: String) -> Settled {
  case simplifile.link_info(path) {
    Error(simplifile.Enoent) -> Missing
    Error(_) -> Tampered
    Ok(info) ->
      case simplifile.file_info_type(info) == simplifile.Directory {
        False -> Tampered
        True ->
          case bootstrap.canonical_path(path) == Ok(path) {
            True -> Whole
            False -> Tampered
          }
      }
  }
}

// The one reason a name that something else holds is refused with, so no path
// from the workspace is ever echoed to the peer.
const tampered_reason = "the spawner's directory cannot hold a copy"

/// Makes the copy, or finds the one an earlier attempt made.
///
/// A copy at its final name is whole, so a resent spawn finds it before the store
/// is read at all and applies nothing, even after the bundle has expired. Otherwise
/// the bundle must be whole in the store and the copy is made.
fn copy(
  node: StateNode,
  directory: String,
  name: String,
  state: State,
  wait_ms: Int,
) -> Result(Nil, SpawnRefusal) {
  // The final name is looked at first, so the answer to a resend is quick.
  case settled(directory <> "/" <> seeds_directory <> "/" <> name) {
    Whole -> Ok(Nil)
    Tampered -> Error(StateRefused(tampered_reason))
    Missing -> {
      use held <- result.try(held(node, state))
      applied(node, directory, name, held, wait_ms)
    }
  }
}

/// Starts the apply for one copy, unless another attempt is making it, and waits
/// for it.
///
/// An apply can take longer than the asker is willing to wait, and the asker's
/// window is 30 seconds while a large checkout takes minutes. The apply therefore
/// runs in a process of its own that nothing but its own deadline ends, and an
/// asker that stops waiting is told to ask again: the next ask finds the copy. A
/// claim, made by creating a directory, which is atomic, keeps the asks that
/// arrive meanwhile from each starting a full apply of the same copy; a claim
/// whose owner died is taken over after `claim_stale_s`. Were two applies ever to
/// run, each has a stage of its own, and the one that renames second finds the
/// name taken and removes its own.
fn applied(
  node: StateNode,
  directory: String,
  name: String,
  held: state_store.Held,
  wait_ms: Int,
) -> Result(Nil, SpawnRefusal) {
  // The copy is made by this node's own sandboxed Git, and a node without one
  // cannot make it.
  case node.git {
    None ->
      Error(StateRefused(
        "this machine has no sandboxed Git to apply a workspace with",
      ))
    Some(git) -> {
      use parent <- result.try(stage_parent(node))
      use taken <- result.try(claim(
        parent,
        name,
        ffi_os.system_time_ms() / 1000,
      ))

      // One attempt makes the copy; the others are told to ask again.
      case taken {
        Busy -> Error(NotYetOpen(still_making))
        Claimed -> {
          let stage =
            parent
            <> "/"
            <> name
            <> "-"
            <> int.to_string(ffi_os.unique_positive_integer())
          let reply = process.new_subject()
          let _building =
            process.spawn_unlinked(fn() {
              process.send(
                reply,
                building(git, held, directory, parent, stage, name),
              )
            })

          // An asker that stops waiting leaves the apply running.
          let heard = process.receive(reply, wait_ms)

          // The apply's own answer, or the request to ask again.
          case heard {
            Ok(done) -> done
            Error(Nil) -> Error(NotYetOpen(still_making))
          }
        }
      }
    }
  }
}

const still_making = "the copy of the workspace is still being made; ask again"

/// How long a claim may stand with no sign of life before another attempt takes
/// it over, in seconds: longer than an apply may run.
pub const claim_stale_s = 900

/// What asking to make a copy found.
pub type Claim {
  /// This attempt makes it.
  Claimed

  /// Another attempt is making it.
  Busy
}

/// Claims the making of one copy by creating its marker directory.
///
/// Creating a directory is atomic, so exactly one attempt sees it succeed. A
/// marker older than `claim_stale_s` at `now_s` belongs to an attempt that died
/// without releasing it and is taken over.
///
/// ## Examples
///
/// ```gleam
/// // spawn_seed.claim(stage_parent, "seed-0123456789abcdef", 1_700_000_000) == Ok(Claimed)
/// ```
pub fn claim(
  parent: String,
  name: String,
  now_s: Int,
) -> Result(Claim, SpawnRefusal) {
  let marker = parent <> "/" <> name <> ".claim"

  // Exactly one attempt creates the marker; the others find it there.
  case simplifile.create_directory(marker) {
    Ok(Nil) -> Ok(Claimed)
    Error(simplifile.Eexist) ->
      case stale(marker, now_s) {
        False -> Ok(Busy)
        True -> {
          let _removed = simplifile.delete(marker)

          // Taking over races other takers, and the one that creates it wins.
          case simplifile.create_directory(marker) {
            Ok(Nil) -> Ok(Claimed)
            Error(_) -> Ok(Busy)
          }
        }
      }
    Error(error) ->
      Error(StoreFailure(
        "the claim for a copy could not be made: "
        <> simplifile.describe_error(error),
      ))
  }
}

/// Whether a marker has stood longer than a claim may.
fn stale(marker: String, now_s: Int) -> Bool {
  case simplifile.file_info(marker) {
    Ok(info) -> info.mtime_seconds + claim_stale_s < now_s
    Error(_) -> False
  }
}

/// The directory the stages are made in, which the daemon owns: no session
/// writes it. It is emptied when the daemon starts, because nothing in it can
/// outlive the process that was making it.
fn stage_parent(node: StateNode) -> Result(String, SpawnRefusal) {
  let parent = node.state_root <> "/" <> staging_directory
  bootstrap.ensure_private_directory(parent)
  |> result.map(fn(_made) { parent })
  |> result.map_error(fn(reason) { StoreFailure(reason:) })
}

/// The directory under the state root that holds the stages and claims.
pub const staging_directory = "seed-staging"

/// Applies the bundle into the attempt's own stage, moves it into the workspace,
/// and releases the claim, all under a deadline of its own.
///
/// The stage name is unique to the attempt, so no attempt ever deletes another's
/// tree. Whatever the end, the attempt removes its own stage, which is gone
/// already when the rename took it, and its claim.
fn building(
  git: worktree_git.Git,
  held: state_store.Held,
  directory: String,
  parent: String,
  stage: String,
  name: String,
) -> Result(Nil, SpawnRefusal) {
  let outcomes =
    weft.new([
      fn() {
        use Nil <- result.try(made(git, held, stage, name))
        published(stage, directory, name)
        |> result.map(fn(_published) { Nil })
      },
    ])
    |> weft.deadline(apply_ms)
    |> weft.start

  let _stage_removed = simplifile.delete(stage)
  let _claim_released = simplifile.delete(parent <> "/" <> name <> ".claim")

  // A task that finished has its own answer; every other end is the deadline.
  case outcomes {
    [weft.Completed(..)] -> Ok(Nil)
    [weft.Failed(error:, ..)] -> Error(error)
    [weft.Crashed(..)]
    | [weft.Abandoned(..)]
    | [weft.NeverStarted(..)]
    | [weft.DrainProofLost(..)]
    | [weft.CancellationUnconfirmed(..)]
    | []
    | [_, _, ..] ->
      Error(StateRefused("applying the state did not finish in time"))
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
    StateRefused(worktree_git.printable(
      "applying the state failed: " <> reason,
      512,
    ))
  })
}

/// Moves the finished repository into the spawner's workspace.
///
/// The workspace is writable by the sessions that run in it, and this move is made
/// by the daemon outside any jail, so a session could try to steer it. Before the
/// move `seeds` must be a real directory at its canonical path, and after it the
/// copy must be where its name says; a copy that landed anywhere else is removed
/// and refused. This narrows the window and does not close it: a child that
/// swaps `seeds` for a link between the check and the rename can still redirect
/// the rename, and the after-check then finds and removes what the daemon put
/// there. Closing it for good needs a destination no session can write, which is
/// a design change for a later slice. What lands is always a repository this
/// daemon made from a bundle at a name it chose.
fn published(
  stage: String,
  directory: String,
  name: String,
) -> Result(String, SpawnRefusal) {
  let seeds = directory <> "/" <> seeds_directory
  let final = seeds <> "/" <> name
  use Nil <- result.try(seeds_ready(seeds))

  // The rename is the publication: it either makes the whole copy appear or
  // leaves the stage to be removed.
  case simplifile.rename(stage, final) {
    Ok(Nil) -> verified(final, name)
    Error(_error) ->
      // A copy another attempt finished first is the same copy.
      case settled(final) {
        Whole -> Ok(name)
        Tampered -> Error(StateRefused(tampered_reason))
        Missing ->
          Error(StateRefused(
            "the copy could not be moved into the spawner's directory: the "
            <> "directory and this daemon's state directory must be on one "
            <> "filesystem",
          ))
      }
  }
}

/// Makes `seeds` if it is not there and requires it to be a real directory at
/// its canonical path, not a link a session planted.
fn seeds_ready(seeds: String) -> Result(Nil, SpawnRefusal) {
  case settled(seeds) {
    Whole -> Ok(Nil)
    Tampered -> Error(StateRefused(tampered_reason))
    Missing ->
      case simplifile.create_directory(seeds) {
        Error(_) -> Error(StateRefused(tampered_reason))
        Ok(Nil) ->
          case settled(seeds) {
            Whole -> Ok(Nil)
            Missing | Tampered -> Error(StateRefused(tampered_reason))
          }
      }
  }
}

/// Requires the copy to be exactly where its name says. One that landed
/// elsewhere was put there by this daemon at a path it named, so it is removed.
fn verified(final: String, name: String) -> Result(String, SpawnRefusal) {
  // Whole is the copy where its name says; anything else is removed.
  case settled(final) {
    Whole -> Ok(name)
    Missing | Tampered -> {
      let _removed = simplifile.delete(final)
      Error(StateRefused(tampered_reason))
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
