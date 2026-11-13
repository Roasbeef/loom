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
//// placement decides where a copy can be made.
////
//// A `directory` placement shares its delegate session's workspace with the
//// pair's other children, so the copy is made as a repository inside it, at
//// `seeds/<name>` under the spawner's `directory`, and the child's brief is told
//// where it is.
////
//// An `executor` or `pool` placement has its workspace on another machine, and a
//// session has one workspace, so the child gets a session of its own
//// (protocol-change/107, slice 4b). The workspace is its worktree, and the state
//// becomes that worktree's checkout. `land` makes that happen in a fixed order:
//// the whole bundle is in this machine's store, the child's session is opened
//// and its scope attached, the bundle is sent to the executor's store, the
//// executor applies it, and only then is the request handed to the Agency, whose
//// start of the child is the session's first turn. A step that fails is a refusal
//// that names the step, and a child that was not started is never reported
//// started.
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
//// `land` → `permitted` → `copy` → `held` → `applied` → `briefed`, and for an
//// executor `landed` → `placed` → `placing` → `moved`
////
//// 1. `land` passes a request with no state through unchanged, and `receive` is
////    the directory half of it.
//// 2. `permitted` judges the spawner's ceiling, its placement and the
////    description, and `copy` returns at once for a copy that is already there.
//// 3. `held` finds the whole bundle in the store, or answers `StateMissing` with
////    the bytes it holds so the sender resumes.
//// 4. `applied` makes the copy in a process that outlives the asker, or finds
////    that another attempt is making it.
//// 5. `briefed` tells the child where its copy is, in words appended to its
////    brief.
//// 6. For an executor, `landed` opens the child's session, `placed` runs the
////    claim and waits for the work, `placing` is the work under its deadline, and
////    `moved` is its two steps: send the bundle, apply it before the first
////    turn.

import client/agency.{type DelegateEndpoint}
import client/delegate_host.{type ChildSessions}
import client/internal/ffi_os
import client/remote_spawn.{
  type CallSite, type Parent, type Request, type SpawnRefusal, NotYetOpen,
  StateMissing, StateRefused, StoreFailure,
}
import client/seed_landing.{
  type Placed, type Unplaced, AlreadyBegun, Applied, Refuse, Retry,
}
import client/session_states.{type SessionStates}
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
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import simplifile
import telemetry/field
import telemetry/log.{type Logger}
import tools/agent
import weft

/// The directory under a spawner's `directory` that holds the copies.
pub const seeds_directory = "seeds"

/// Where a state is put.
pub type Target {
  /// A repository copy under this directory of the spawner's, which is on this
  /// machine.
  Directory(path: String)

  /// The child's own session, whose workspace is on an executor.
  Session
}

/// What a request becomes once its state has been dealt with.
pub type Landed {
  Landed(
    /// The request the Agency serves: its state cleared, and its brief saying
    /// where the child's workspace is.
    request: Request,
    /// The child's own session, with its workspace filled, when the placement is
    /// an executor or a pool, and `None` when the child runs in the pair's
    /// session.
    session: Option(DelegateEndpoint),
  )
}

/// Judges a request that may carry a state and prepares the copy it names, for a
/// spawner placed in a directory.
///
/// A request with no state is returned as it is. One with a state is returned
/// with its brief amended to say where the child's copy is and its `state` cleared,
/// since the Agency serves what the request asks of the child and the state has
/// done its work. Any other answer is a refusal: `StateMissing` when the bundle
/// is not all in the store, which the sender answers by sending the rest, and
/// `StateRefused` for everything else about the state, which resending cannot
/// change. A spawner placed on an executor or a pool is refused here, because its
/// child needs a session of its own that this function has no way to open: the
/// daemon's spawn host calls `land`.
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
      use target <- result.try(permitted(spawner, state))

      // Only a directory has a copy to make without a session to open.
      case target {
        Directory(path: directory) ->
          copy_in(node, directory, spawner, site, request, state, wait_ms)
        Session -> Error(StateRefused(needs_a_session))
      }
    }
  }
}

// What `receive` says of a spawner placed on an executor or a pool.
const needs_a_session =
  "this spawner places its children on an executor, and each is started in a session of its own; the spawn host does that, not a copy in a directory"

/// Makes the copy for a spawner placed in a directory and amends the brief.
fn copy_in(
  node: StateNode,
  directory: String,
  spawner: Spawner,
  site: CallSite,
  request: Request,
  state: State,
  wait_ms: Int,
) -> Result(Request, SpawnRefusal) {
  let name = name_of(site, state)
  use Nil <- result.map(copy(
    node,
    directory,
    spawner.name,
    name,
    state,
    wait_ms,
  ))
  remote_spawn.Request(
    ..request,
    brief: request.brief <> briefed(name),
    state: None,
  )
}

/// Deals with the state a request carries, wherever the spawner places its
/// children, and returns the request the Agency serves with the session it is to
/// be served in.
///
/// A request with no state is `Landed` as it is, with no session of its own. For
/// a `directory` placement the copy is made as `receive` makes it. For an
/// `executor` or `pool` placement the child's session is found or made through
/// `children`, the state is sent to its executor and applied there, and the
/// session is returned so that the child starts in it. Nothing is started here:
/// the Agency's `spawn` is the child's first turn, and it is not called until this
/// has returned `Ok`.
///
/// ## Examples
///
/// ```gleam
/// // spawn_seed.land(node, children, spawner, parent, call_site, request)
/// // == Ok(spawn_seed.Landed(request:, session: option.None)) for a request with no state
/// ```
pub fn land(
  node: StateNode,
  children: ChildSessions,
  spawner: Spawner,
  parent: Parent,
  site: CallSite,
  request: Request,
) -> Result(Landed, SpawnRefusal) {
  land_within(node, children, spawner, parent, site, request, place_wait_ms)
}

/// `land` for an asker that waits at most `wait_ms` for the workspace to be put
/// in place. The work is not abandoned when the asker stops waiting, and the next
/// ask for the same spawn finds it done or still going.
///
/// ## Examples
///
/// ```gleam
/// // spawn_seed.land_within(node, children, spawner, parent, call_site, request, 15_000)
/// ```
pub fn land_within(
  node: StateNode,
  children: ChildSessions,
  spawner: Spawner,
  parent: Parent,
  site: CallSite,
  request: Request,
  wait_ms: Int,
) -> Result(Landed, SpawnRefusal) {
  // A request with no state is the request it always was.
  case request.state {
    None -> Ok(Landed(request:, session: None))
    Some(state) -> {
      use target <- result.try(permitted(spawner, state))

      // Where the state goes decides which half of the work this is.
      case target {
        Directory(path: directory) ->
          copy_in(node, directory, spawner, site, request, state, apply_ms)
          |> result.map(fn(served) { Landed(request: served, session: None) })
        Session ->
          landed(
            node,
            children,
            spawner,
            parent,
            name_of(site, state),
            request,
            state,
            wait_ms,
          )
      }
    }
  }
}

/// How long one apply may run in all, in milliseconds: the sandboxed Git's own
/// ten minutes for a checkout, and a margin.
pub const apply_ms = 660_000

/// How long a spawn waits for a workspace to be put into a child's session on an
/// executor before it tells the sender to ask again, in milliseconds. The work
/// goes on in a process of its own, and the sender's window is thirty seconds.
pub const place_wait_ms = 15_000

/// Judges the spawner's ceiling, its placement and the description, and answers
/// where the state goes.
///
/// ## Examples
///
/// ```gleam
/// // spawn_seed.permitted(spawner_with_seed_none, state) == Error(StateRefused(..))
/// ```
pub fn permitted(
  spawner: Spawner,
  state: State,
) -> Result(Target, SpawnRefusal) {
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
  // to choose. An executor or a pool takes a state only in a workspace of
  // `mode = "worktree"`, which this machine learns from the executor's census
  // when the child's session attaches, so that refusal comes later and names the
  // mode.
  case spawner.seed, spawner.placement {
    WorkspaceSeed, InDirectory(path:) ->
      bootstrap.canonical_directory(path)
      |> result.map(Directory)
      |> result.replace_error(StateRefused(
        "the spawner's directory is not usable on this machine",
      ))
    WorkspaceSeed, spawners.OnExecutor(..)
    | WorkspaceSeed, spawners.InPool(..)
    -> Ok(Session)
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

/// The path of a finished copy, when `name` is the name of one and a whole
/// repository is there: a real directory at its canonical path under
/// `directory/seeds`, which only the daemon's own rename makes. Anything else,
/// a link a session planted included, is `Error(Nil)`.
///
/// ## Examples
///
/// ```gleam
/// // spawn_seed.copy_at("/srv/work", "seed-0123456789abcdef")
/// // == Ok("/srv/work/seeds/seed-0123456789abcdef")
/// ```
pub fn copy_at(directory: String, name: String) -> Result(String, Nil) {
  let path = directory <> "/" <> seeds_directory <> "/" <> name
  use <- bool.guard(when: !is_copy_name(name), return: Error(Nil))

  // Only a whole copy at its canonical name is one.
  case settled(path) {
    Whole -> Ok(path)
    Missing | Tampered -> Error(Nil)
  }
}

/// Whether text has the shape `name_of` makes: `seed-` and sixteen lower-case
/// hexadecimal digits. A name read back from a file is held to it before it is
/// made into a path.
///
/// ## Examples
///
/// ```gleam
/// assert spawn_seed.is_copy_name("seed-0123456789abcdef")
/// assert !spawn_seed.is_copy_name("seed-../x")
/// ```
pub fn is_copy_name(name: String) -> Bool {
  case name {
    "seed-" <> digits ->
      string.byte_size(digits) == 16
      && list.all(string.to_graphemes(digits), fn(each) {
        string.contains("0123456789abcdef", each)
      })
    _ -> False
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
  spawner: String,
  name: String,
  state: State,
  wait_ms: Int,
) -> Result(Nil, SpawnRefusal) {
  // The final name is looked at first, so the answer to a resend is quick.
  case settled(directory <> "/" <> seeds_directory <> "/" <> name) {
    Whole -> Ok(Nil)
    Tampered -> Error(StateRefused(tampered_reason))
    Missing -> {
      // An apply that failed after its asker had gone left its verdict, so the
      // resend is told so at once and starts no second apply.
      use Nil <- result.try(refused_before(node, name))
      use held <- result.try(held(node, state))
      applied(node, directory, spawner, name, held, wait_ms)
    }
  }
}

/// The reason an earlier apply of this copy failed, as the refusal it earned, or
/// `Ok` when none did.
fn refused_before(node: StateNode, name: String) -> Result(Nil, SpawnRefusal) {
  case simplifile.read(verdict_path(node.state_root, name)) {
    Ok(reason) -> Error(StateRefused(reason))
    Error(_) -> Ok(Nil)
  }
}

/// Where the verdict of one copy's failed apply is kept, beside its claim.
fn verdict_path(state_root: String, name: String) -> String {
  state_root <> "/" <> staging_directory <> "/" <> name <> ".refused"
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
  spawner: String,
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
                building(
                  git,
                  node.logger,
                  held,
                  directory,
                  parent,
                  stage,
                  spawner,
                  name,
                ),
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
/// already when the rename took it, and its claim. An attempt that made the copy
/// says so once, which is the only place a copy is known to be new: a resend that
/// finds the finished copy never gets here.
fn building(
  git: worktree_git.Git,
  logger: Logger,
  held: state_store.Held,
  directory: String,
  parent: String,
  stage: String,
  spawner: String,
  name: String,
) -> Result(Nil, SpawnRefusal) {
  let started = bootstrap.monotonic_time_ms()
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

  // A task that finished has its own answer; every other end is the deadline.
  let answer = case outcomes {
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

  // The verdict is kept before the claim is let go, so no ask can find the claim
  // free and the verdict missing. The stage and the claim are daemon-owned.
  record_refusal(parent, name, answer)
  let _stage_removed = simplifile.delete(stage)
  let _claim_released = simplifile.delete(parent <> "/" <> name <> ".claim")

  // Only a copy that was made is told; a refusal has its own verdict file.
  case answer {
    Ok(Nil) -> told_placed(logger, held.state, spawner, name, started)
    Error(_) -> Nil
  }

  answer
}

/// Says that a state was applied and its copy is in place. The state is named by
/// its short hash and size, the copy by its name under the spawner's `seeds`
/// directory, and no path of this machine is written.
fn told_placed(
  logger: Logger,
  state: State,
  spawner: String,
  name: String,
  started: Int,
) -> Nil {
  log.info(logger, "remote_spawn.seed_placed", [
    field.text("spawner", spawner),
    field.ident("seed", name),
    field.ident("state", state_object.short(state.hash)),
    field.count("bytes", state.size),
    field.count("elapsed_ms", bootstrap.monotonic_time_ms() - started),
  ])
}

/// Keeps the reason a failed apply was refused for, so that an ask arriving after
/// the asker that started it has gone is answered with it. The reason is bounded
/// and printable, and is written to a temporary file and renamed so a reader never
/// sees half of it. A success keeps nothing. Failing to keep it costs only that the
/// next ask applies again.
fn record_refusal(
  parent: String,
  name: String,
  answer: Result(Nil, SpawnRefusal),
) -> Nil {
  // Only a refusal is a verdict; a copy that was made, or a store that failed, is
  // not.
  case answer {
    Ok(Nil) -> Nil
    Error(StateRefused(reason)) -> {
      let path = parent <> "/" <> name <> ".refused"
      let temporary =
        path <> "." <> int.to_string(ffi_os.unique_positive_integer())

      // The rename is what publishes it, whole.
      case simplifile.write(temporary, worktree_git.printable(reason, 512)) {
        Ok(Nil) -> {
          let _renamed = simplifile.rename(temporary, path)
          Nil
        }
        Error(_) -> Nil
      }
    }
    Error(_) -> Nil
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
/// copy must be where its name says; a copy that landed anywhere else is refused
/// and left where it landed. This narrows the window and does not close it: a
/// child that swaps `seeds` for a link between the check and the rename can still
/// redirect the rename, and the after-check then refuses. The daemon does not
/// delete what landed, because that delete would be made outside the jail by path
/// through a tree the session controls. Closing the window for good needs a
/// destination no session can write, which is a design change for a later slice.
/// What lands is always a repository this daemon made from a bundle at a name it
/// chose.
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

/// Requires the copy to be exactly where its name says.
///
/// One that is not is refused, and left where the rename put it. The daemon does
/// not delete it: the delete would be made outside the jail, by path, through a
/// tree a session that already won the first race can still rearrange, and a link
/// swapped into it mid-walk would have the daemon delete its own private files.
/// What stays is a repository the daemon made from a bundle at a name it chose, in
/// a place the session could already write. The refusal is logged by the spawn
/// host, which records the class of every final refusal.
fn verified(final: String, name: String) -> Result(String, SpawnRefusal) {
  // Whole is the copy where its name says; anything else is refused.
  case settled(final) {
    Whole -> Ok(name)
    Missing | Tampered -> Error(StateRefused(tampered_reason))
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

// --- a child's own session on an executor (protocol-change/107, slice 4b) --------

/// Puts a state into the workspace of the child's own session, in the order that
/// keeps the child from starting on a half-made tree.
///
/// 1. A refusal an earlier attempt left is answered at once, so a failure that
///    came after its asker had gone is not run again.
/// 2. A session that already exists and has begun belongs to a spawn that went
///    through, and this one is its resend: nothing is put anywhere, and the
///    Agency answers the child it already started.
/// 3. The whole bundle must be in this machine's store. A state that is still
///    arriving is `StateMissing` before any session is made, so a sender that is
///    midway through a transfer holds no slot.
/// 4. The session is found or made, and the executor's census must say its
///    workspace takes a state. A workspace in `shared` mode is refused naming the
///    mode, and the session just made is released, since no child will run in it.
/// 5. The bundle is sent to the executor's store and applied, by `placed`.
fn landed(
  node: StateNode,
  children: ChildSessions,
  spawner: Spawner,
  parent: Parent,
  name: String,
  request: Request,
  state: State,
  wait_ms: Int,
) -> Result(Landed, SpawnRefusal) {
  let ready = fn(endpoint) {
    Landed(
      request: remote_spawn.Request(
        ..request,
        brief: request.brief <> briefed_in_workspace(),
        state: None,
      ),
      session: Some(endpoint),
    )
  }

  // A verdict is written before the session is ended, so a daemon that stopped
  // between the two left a refused child with a session. The ask that finds the
  // verdict ends it, which does nothing when it is already gone.
  use Nil <- result.try(
    refused_before(node, name)
    |> result.map_error(fn(refusal) {
      let _released = children.release(spawner, parent, name)
      refusal
    }),
  )
  use begun <- result.try(children.open(spawner, parent, name))

  // A child that has begun is a resend of a spawn that went through.
  case begun {
    Some(endpoint) ->
      placed_or_begun(
        node,
        children,
        spawner,
        parent,
        name,
        state,
        endpoint,
        wait_ms,
      )
      |> result.map(ready)
    None -> {
      use held <- result.try(held(node, state))
      use endpoint <- result.try(children.resolve(spawner, parent, name))
      placed_in(node, children, spawner, parent, name, held, endpoint, wait_ms)
      |> result.map(fn(_placed) { ready(endpoint) })
    }
  }
}

/// A session that exists: skips the work when the child has begun, and otherwise
/// finishes it, as a resend after a lost reply or a wait that ran out does.
fn placed_or_begun(
  node: StateNode,
  children: ChildSessions,
  spawner: Spawner,
  parent: Parent,
  name: String,
  state: State,
  endpoint: DelegateEndpoint,
  wait_ms: Int,
) -> Result(DelegateEndpoint, SpawnRefusal) {
  // A session whose child began has its workspace already, one that has not gets
  // it now, and one that cannot be read is asked about again: skipping the work
  // for it would start the child on a checkout nothing was put in.
  case seed_landing.gate(endpoint.fresh()) {
    seed_landing.LeaveAlone -> Ok(endpoint)
    seed_landing.AskAgain -> Error(NotYetOpen(session_states.unreadable))
    seed_landing.PutIn -> {
      use held <- result.try(held(node, state))
      placed_in(node, children, spawner, parent, name, held, endpoint, wait_ms)
      |> result.map(fn(_placed) { endpoint })
    }
  }
}

/// Checks the session can take a state, then runs the work or finds it running.
fn placed_in(
  node: StateNode,
  children: ChildSessions,
  spawner: Spawner,
  parent: Parent,
  name: String,
  held: state_store.Held,
  endpoint: DelegateEndpoint,
  wait_ms: Int,
) -> Result(Nil, SpawnRefusal) {
  let release = fn() {
    let _released = children.release(spawner, parent, name)
    Nil
  }

  // The census says whether the executor's workspace takes a state at all.
  case endpoint.states {
    None -> {
      release()
      Error(StateRefused(
        "the child's session has no workspace on an executor to put a workspace in",
      ))
    }
    Some(states) ->
      case states.fit {
        Error(reason) -> {
          release()
          Error(StateRefused(worktree_git.printable(reason, 512)))
        }
        Ok(Nil) ->
          placed(node, states, endpoint, spawner, name, held, release, wait_ms)
      }
  }
}

/// Starts the work for one child, unless another attempt is doing it, and waits
/// for it.
///
/// The sender's window is thirty seconds and a large checkout takes minutes, so
/// the work runs in a process of its own that nothing but its own deadline ends,
/// and an asker that stops waiting is told to ask again. The claim is the one the
/// directory copy uses, a marker directory made atomically beside the stages, so
/// the asks that arrive meanwhile do not each start a transfer. Were two to run,
/// both are safe: a piece the executor holds is accepted again, and an apply of
/// a tip the tree already has is answered with the tip and touches nothing.
fn placed(
  node: StateNode,
  states: SessionStates,
  endpoint: DelegateEndpoint,
  spawner: Spawner,
  name: String,
  held: state_store.Held,
  release: fn() -> Nil,
  wait_ms: Int,
) -> Result(Nil, SpawnRefusal) {
  use parent <- result.try(stage_parent(node))
  use taken <- result.try(claim(parent, name, ffi_os.system_time_ms() / 1000))

  // One attempt does the work; the others are told to ask again.
  case taken {
    Busy -> Error(NotYetOpen(still_placing))
    Claimed -> {
      let reply = process.new_subject()
      let _working =
        process.spawn_unlinked(fn() {
          process.send(
            reply,
            placing(
              node,
              states,
              endpoint,
              spawner,
              held,
              parent,
              name,
              release,
            ),
          )
        })

      // An asker that stops waiting leaves the work running.
      case process.receive(reply, wait_ms) {
        Ok(done) -> done
        Error(Nil) -> Error(NotYetOpen(still_placing))
      }
    }
  }
}

const still_placing =
  "the workspace is still being put in place on the executor; ask again"

/// The refusal a caller of `land` is told for an unplaced state.
fn refusal_of(unplaced: Unplaced) -> SpawnRefusal {
  case unplaced {
    Retry(reason:) -> NotYetOpen(worktree_git.printable(reason, 300))
    Refuse(reason:) -> StateRefused(worktree_git.printable(reason, 512))
  }
}

/// The work of one placement under a deadline of its own.
///
/// Whatever the end, the claim is released. Only a refusal the same inputs would
/// get again is kept as the attempt's verdict, before the claim is let go, so an
/// ask that arrives after the asker has gone is answered with it and starts
/// nothing, and such a refusal ends the child's session, since no child will run
/// in it. A failure that asking again can cure (no answer, no room, a fence that
/// moved, the deadline) keeps no verdict and leaves the session, so the next ask
/// resumes the transfer at the executor's offset.
fn placing(
  node: StateNode,
  states: SessionStates,
  endpoint: DelegateEndpoint,
  spawner: Spawner,
  held: state_store.Held,
  parent: String,
  name: String,
  release: fn() -> Nil,
) -> Result(Nil, SpawnRefusal) {
  let started = bootstrap.monotonic_time_ms()
  let outcomes =
    weft.new([fn() { moved(node, states, endpoint, held) }])
    |> weft.deadline(apply_ms)
    |> weft.start

  // A task that finished has its own answer; every other end is the deadline,
  // which says nothing about the inputs and so is a reason to ask again.
  let answer = case outcomes {
    [weft.Completed(value:, ..)] -> Ok(value)
    [weft.Failed(error:, ..)] -> Error(error)
    [weft.Crashed(..)]
    | [weft.Abandoned(..)]
    | [weft.NeverStarted(..)]
    | [weft.DrainProofLost(..)]
    | [weft.CancellationUnconfirmed(..)]
    | []
    | [_, _, ..] ->
      Error(Retry("putting the workspace in place did not finish in time"))
  }

  let refused = result.map(answer, fn(_placed) { Nil })
  let told = result.map_error(refused, refusal_of)

  // The verdict is kept before the claim is let go, so no ask finds the claim
  // free and the verdict missing. A request to ask again is not a verdict.
  record_refusal(parent, name, case answer {
    Error(unplaced) ->
      case seed_landing.keeps_verdict(unplaced) {
        True -> told
        False -> Ok(Nil)
      }
    Ok(_placed) -> Ok(Nil)
  })
  let _claim_released = simplifile.delete(parent <> "/" <> name <> ".claim")

  // The record that the workspace is in place, or the end of the child's session.
  // A resend that found the session begun put nothing anywhere and says nothing.
  case answer {
    Ok(Applied) ->
      told_applied(
        node.logger,
        held.state,
        spawner.name,
        states.executor,
        started,
      )
    Ok(AlreadyBegun) | Error(Retry(..)) -> Nil
    Error(Refuse(..)) -> release()
  }

  told
}

/// Sends the bundle to the executor's store and has the executor apply it.
fn moved(
  node: StateNode,
  states: SessionStates,
  endpoint: DelegateEndpoint,
  held: state_store.Held,
) -> Result(Placed, Unplaced) {
  use Nil <- result.try(delivered(node, states, held.state))
  applied_on(states, endpoint, held.state)
}

/// Relays the bundle from this machine's store to the executor's, resuming at the
/// offset the executor already holds. A transfer that did not finish, an executor
/// with no room yet and a store that could not say are the next ask's to try
/// again; a description or a piece the executor judges malformed is refused for
/// good.
fn delivered(
  node: StateNode,
  states: SessionStates,
  state: State,
) -> Result(Nil, Unplaced) {
  case node.store {
    None -> Error(Refuse("this machine keeps no state store"))
    Some(store) ->
      case state_transfer.send(store, state.hash, states.link) {
        state_transfer.Delivered -> Ok(Nil)
        state_transfer.Declined(refusal:) ->
          Error(seed_landing.of_declined(refusal))

        // A fault is a node that could not decide or read, which may pass; a
        // bundle this machine lost is found missing by the next ask's check.
        state_transfer.Faulted(reason:) ->
          Error(Retry(
            "sending the workspace to the executor failed: " <> reason,
          ))
        state_transfer.Silent | state_transfer.Stalled ->
          Error(Retry(still_placing))
      }
  }
}

/// Has the executor check the state out as the child's tree, before the child's
/// first turn.
///
/// The session is asked once more whether it has begun, at the moment before the
/// request, because the executor cannot tell: a session that began while the
/// bundle was crossing is a resend of a spawn that went through, and gets no
/// apply. A session that cannot be read is asked about again, and is never taken
/// for one that has begun. The session's own `apply` refuses once the session has
/// begun as well, so the line is held where the request is made and not only
/// here.
fn applied_on(
  states: SessionStates,
  endpoint: DelegateEndpoint,
  state: State,
) -> Result(Placed, Unplaced) {
  case seed_landing.gate(endpoint.fresh()) {
    seed_landing.LeaveAlone -> Ok(AlreadyBegun)
    seed_landing.AskAgain -> Error(Retry(session_states.unreadable))
    seed_landing.PutIn -> apply_once(states, state)
  }
}

/// Sends the apply and reads the executor's answer: the tip it checked out, a
/// request to ask again, or a refusal of the content that asking again does not
/// change.
fn apply_once(states: SessionStates, state: State) -> Result(Placed, Unplaced) {
  case states.apply(state) {
    Ok(tip) if tip == state.tip -> Ok(Applied)
    Ok(_other) ->
      Error(Refuse(
        "applying the workspace on the executor checked out another commit than the one sent",
      ))
    Error(failure) -> Error(seed_landing.of_failure(failure))
  }
}

/// Says that a state was put into a child's workspace on an executor. The state is
/// named by its short hash and size and the executor by its name; no path of
/// either machine is written.
fn told_applied(
  logger: Logger,
  state: State,
  spawner: String,
  executor: String,
  started: Int,
) -> Nil {
  log.info(logger, "remote_spawn.seed_applied", [
    field.text("spawner", spawner),
    field.text("executor", executor),
    field.ident("state", state_object.short(state.hash)),
    field.count("bytes", state.size),
    field.count("elapsed_ms", bootstrap.monotonic_time_ms() - started),
  ])
}

/// The words appended to the brief of a child whose workspace is its session's
/// own.
///
/// ## Examples
///
/// ```gleam
/// // spawn_seed.briefed_in_workspace()
/// ```
pub fn briefed_in_workspace() -> String {
  "\n\nYour workspace: you were started from the workspace of the session "
  <> "that asked for you, as it was when it asked, uncommitted edits and new "
  <> "files included. Your workspace is that copy, a Git worktree on a branch "
  <> "of its own, and its newest commit may be a snapshot of that uncommitted "
  <> "work. Work in it as in any workspace and commit what you change: your "
  <> "commits are returned to the session that asked, as a ref in its "
  <> "repository. Nothing is pushed anywhere."
}
