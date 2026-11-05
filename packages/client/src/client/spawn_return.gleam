//// Sending a finished child's commits back to the machine that asked for it
//// (protocol-change/107, "Return").
////
//// A child that was started from its parent's workspace works in a copy of it on
//// this machine (`client/spawn_seed`). When the parent asks whether the child has
//// finished, the answer is a join, and a join is the one message this machine is
//// sure to receive after the child's run has ended. This module sits in that
//// path. For a child that was handed a state it captures what the child
//// committed on top of that state, moves the bundle to the parent's machine, and
//// answers the join with the state's description, so the parent can fetch the
//// commits into its own repository. A child that was not handed a state is
//// answered as it always was.
////
//// ## What is returned
////
//// Commits, and only commits (`state_capture.capture_commits`). Edits the child
//// left uncommitted stay in its copy, and the join's text says that there were
//// some. The bundle is thin against the state the parent sent, which the parent
//// still holds, so it carries only what the child added.
////
//// ## A child on an executor
////
//// A child whose spawner is placed on an executor or a pool does not work in a
//// directory of this machine. It works in the worktree of a session of its own
//// (protocol-change/107, slice 4b), and its commits are on the executor. There
//// the capture is a request to the executor, `StateCapture` of the committed
//// content thin against the tip that was sent, through the session's record of
//// what it can do (`client/session_states`). The executor keeps the bundle in its
//// store, this node pulls it into its own, and the push to the parent's machine is
//// the one every other child uses. Two steps that a directory child does not have
//// can end in silence, the capture and the pull, and each is tried again at the
//// next join like a transfer that did not finish. A tree that holds changes the
//// child did not commit is not reported for such a child, because asking would
//// need a message the executor's vocabulary does not have.
////
//// ## A return does not fail a child
////
//// A child's result is the model's report, and nothing about the commits may take
//// it away. A capture that is refused, a parent that declines the bundle, and a
//// link that does not recover all end as a sentence appended to the report that
//// says the commits could not be returned and why. The commits stay in this
//// machine's state store for its retention.
////
//// ## Work that outlives its asker
////
//// A capture and a transfer can take longer than the join may wait. The work runs
//// in a process of its own under a deadline of its own, and a join that cannot
//// wait for it answers `Pending`, which the parent reads as a child still
//// finishing and asks about again. What the work learned is kept in a verdict
//// file in `<state root>/seed-returns`, a directory no session can read, so the
//// next join answers from the file and neither repeats a capture nor repeats a
//// failed one. A transfer that did not finish keeps the captured state and the
//// count of tries, and resumes where the parent's store stands; after
//// `max_attempts` it gives up with a refusal that says so.
////
//// ## Flow
////
//// `over` → `remember` → `settle` → `answered` → `attempt` → `working` → `amend`
////
//// 1. `over` binds the node and the way to reach the parent's machine, and
////    `none` is the value for a node that returns nothing.
//// 2. `remember` records, when a seeded child is started, which copy it works in
////    and which commit it was given, or that it works in a session of its own
////    on an executor.
//// 3. `settle` is applied to each entry of a join. An entry for a child that has
////    a record and has finished is answered by `answered`, from its verdict or
////    by an attempt.
//// 4. `attempt` claims the work and waits for it a little, and `working` is the
////    work: check the tree, capture, send.
//// 5. `amend` turns a verdict into the entry the parent reads.

import client/internal/ffi_os
import client/remote_spawn.{type CallSite, type Joined, type Parent}
import client/session_states.{type SessionStates}
import client/spawn_seed
import client/spawners.{type Spawner, InDirectory}
import client/state_capture
import client/state_node.{type StateNode}
import client/state_object.{type State}
import client/state_transfer.{type Link}
import client/worktree_git
import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import simplifile
import telemetry/field
import telemetry/log.{type Logger}
import tools/agent.{type Handle}
import weft

/// The directory under the state root that holds the records and verdicts.
pub const directory_name = "seed-returns"

/// How long a join waits for the work before it answers `Pending`, in
/// milliseconds. The parent allows a join its window and two seconds more, and a
/// capture of a few commits takes much less than this.
pub const wait_ms = 1500

/// How long the work may run in all, in milliseconds. It is below the age at
/// which a claim is taken over (`spawn_seed.claim_stale_s`).
pub const work_ms = 840_000

/// How many transfers may fail to finish before the return is given up.
pub const max_attempts = 5

/// How a node returns a finished child's commits: the two steps that bracket a
/// child's life, bound to this node's store, Git and link.
pub type Returning {
  Returning(
    /// Records that a child was started from a state, at the spawn that started
    /// it. The arguments are the spawner, the parent, the call site, the state
    /// the child was handed and the child's handle.
    remember: fn(Spawner, Parent, CallSite, State, Handle) -> Nil,
    /// Answers one entry of a join: the entry itself for a child that was not
    /// seeded or has not finished, and otherwise the entry with the child's
    /// commits returned or the reason they could not be. The last argument is the
    /// record of the child's own session, which a child on an executor needs to
    /// have its commits captured there, and `None` for every other.
    settle: fn(Spawner, Parent, Joined, Option(SessionStates)) -> Joined,
    /// The name of the session a child has to itself, when it was seeded onto an
    /// executor or a pool, and `None` for a child that was not seeded or works in
    /// a directory. A join asks the child's session, and not the pair's, about it.
    session_of: fn(Spawner, Parent, Handle) -> Option(String),
  )
}

/// The value for a node that returns nothing: nothing is remembered and every
/// entry is answered as it is.
///
/// ## Examples
///
/// ```gleam
/// // spawn_return.none().settle(spawner, parent, entry, option.None) == entry
/// ```
pub fn none() -> Returning {
  Returning(
    remember: fn(_, _, _, _, _) { Nil },
    settle: fn(_, _, entry, _) { entry },
    session_of: fn(_, _, _) { None },
  )
}

/// What a node reaches in order to return a child's commits: the way to the
/// parent's store, and the log that keeps what is not sent to the parent.
type Reach {
  Reach(
    /// For the node a spawner names, the link to its state store, or `None`
    /// while the two machines are not connected.
    link_to: fn(String) -> Option(Link),
    /// Where a refusal's detail goes. The detail can hold this machine's paths
    /// and Git's own words, so the parent's report carries a fixed sentence and
    /// the detail stays here.
    logger: Logger,
  )
}

/// A node that returns the commits of the children it seeded. `link_to` answers,
/// for the node a spawner names, the link to its state store, or `None` while the
/// two machines are not connected. `logger` keeps the detail of a refused capture,
/// which is not sent to the parent.
///
/// ## Examples
///
/// ```gleam
/// // spawn_return.over(node, fn(_spawner_node) { Some(link) }, log.discard())
/// ```
pub fn over(
  node: StateNode,
  link_to: fn(String) -> Option(Link),
  logger: Logger,
) -> Returning {
  let reach = Reach(link_to:, logger:)
  Returning(
    remember: fn(spawner, parent, site, state, handle) {
      remember(node, spawner, parent, site, state, handle)
    },
    settle: fn(spawner, parent, entry, states) {
      settle(node, reach, spawner, parent, entry, states)
    },
    session_of: fn(spawner, parent, handle) {
      session_of(node, spawner, parent, handle)
    },
  )
}

/// Removes the claims a daemon that died left behind, when the next one starts.
/// A claim names work in a process that no longer exists, and would otherwise make
/// every join answer `Pending` until it aged out. Records and verdicts are kept:
/// they are what a restarted daemon answers from.
///
/// ## Examples
///
/// ```gleam
/// // spawn_return.sweep("/var/lib/loom")
/// ```
pub fn sweep(state_root: String) -> Nil {
  let directory = state_root <> "/" <> directory_name

  // A directory that is not there has no claims.
  case simplifile.read_directory(directory) {
    Ok(names) ->
      list.each(names, fn(name) {
        // Only a claim is removed; a record or a verdict is kept.
        case string.ends_with(name, ".claim") {
          True -> {
            let _removed = simplifile.delete(directory <> "/" <> name)
            Nil
          }
          False -> Nil
        }
      })
    Error(_) -> Nil
  }
}

// --- what is remembered -------------------------------------------------------

/// What the receiver keeps of a seeded child: the name of its copy and the commit
/// it was given, and where the copy is. Nothing else is needed, and no path is
/// kept, because the directory comes from the spawner's table when the record is
/// used.
type Copy {
  Copy(name: String, tip: String, home: Home)
}

/// Where a seeded child works.
type Home {
  /// In a copy under the spawner's directory on this machine, which the child
  /// shares its session with the pair's other children to reach.
  Directory

  /// In the worktree of a session of its own on an executor, named by `name`.
  Session
}

/// The word a home is kept as in the record file.
fn home_word(home: Home) -> String {
  case home {
    Directory -> "directory"
    Session -> "session"
  }
}

/// The key of a child's files: a digest of the spawner, the parent session and
/// the child's strand. The strand is minted by this daemon, and the digest keeps
/// every character of the other two out of a path.
fn key_of(spawner: Spawner, parent: Parent, handle: Handle) -> String {
  let text = string.join([spawner.name, parent.session, handle.strand], "\n")
  string.slice(state_object.hash_of(bit_array.from_string(text)), 0, 32)
}

/// The directory the records are kept in, made private if it is not there.
fn returns_directory(node: StateNode) -> Result(String, String) {
  // A node with no state root keeps nothing.
  case node.state_root {
    "" -> Error("this node keeps no state directory")
    root -> {
      let directory = root <> "/" <> directory_name
      bootstrap.ensure_private_directory(directory)
      |> result.map(fn(_made) { directory })
    }
  }
}

/// Writes a file whole: to a name of its own, then renamed over the target, so a
/// reader never sees half of it.
fn write_whole(path: String, text: String) -> Result(Nil, Nil) {
  let temporary = path <> "." <> int.to_string(ffi_os.unique_positive_integer())

  // The rename is what publishes the file, so a failed write publishes nothing.
  case simplifile.write(temporary, text) {
    Ok(Nil) ->
      simplifile.rename(temporary, path)
      |> result.replace_error(Nil)
    Error(_) -> Error(Nil)
  }
}

/// Records a seeded child. A resend of the same spawn writes the same record.
fn remember(
  node: StateNode,
  spawner: Spawner,
  parent: Parent,
  site: CallSite,
  state: State,
  handle: Handle,
) -> Nil {
  // A directory placement shares the pair's session and works in a copy under
  // it, and an executor or pool placement works in a session of its own.
  let home = case spawner.placement {
    InDirectory(..) -> Directory
    spawners.OnExecutor(..) | spawners.InPool(..) -> Session
  }

  let copy = Copy(name: spawn_seed.name_of(site, state), tip: state.tip, home:)

  // Failing to keep the record costs only that this child's commits are not
  // returned, and the spawn itself has been answered.
  case returns_directory(node) {
    Ok(directory) -> {
      let path = directory <> "/" <> key_of(spawner, parent, handle) <> ".copy"
      let _written = write_whole(path, encode_copy(copy))
      Nil
    }
    Error(_) -> Nil
  }
}

/// The record as the JSON text kept in its file.
fn encode_copy(copy: Copy) -> String {
  json.object([
    #("name", json.string(copy.name)),
    #("tip", json.string(copy.tip)),
    #("home", json.string(home_word(copy.home))),
  ])
  |> json.to_string
}

/// The home a record's word names. Anything but `session` is a directory, which
/// is where a copy was before there was a word for it.
fn home_of(word: String) -> Home {
  case word {
    "session" -> Session
    _ -> Directory
  }
}

/// Reads a record back, held to the shapes a path and a command are built from.
fn decode_copy(text: String) -> Result(Copy, Nil) {
  let decoder = {
    use name <- decode.field("name", decode.string)
    use tip <- decode.field("tip", decode.string)

    // A record written before a child could have a session of its own has no
    // home, and its copy was in a directory.
    use home <- decode.optional_field("home", "directory", decode.string)
    decode.success(Copy(name:, tip:, home: home_of(home)))
  }
  use copy <- result.try(result.replace_error(json.parse(text, decoder), Nil))
  let usable =
    spawn_seed.is_copy_name(copy.name) && state_object.is_object_id(copy.tip)

  // A record whose shapes are wrong is no record.
  case usable {
    True -> Ok(copy)
    False -> Error(Nil)
  }
}

// --- what is learned ----------------------------------------------------------

/// What the work found, and how far it got.
type Outcome {
  /// The child committed nothing on top of what it was given.
  NoCommits

  /// The executor the child worked on did not answer the request for its commits.
  /// Nothing was captured, and the request is made again at the next join.
  Waiting

  /// The commits are captured into this node's store and are not yet in the
  /// parent's. The transfer resumes from here.
  Captured(state: State)

  /// The commits are in the parent's store.
  Returned(state: State)

  /// The commits cannot be returned, for a reason a person can read.
  Refused(reason: String)
}

/// Whether the child's copy had changes it did not commit.
type Tree {
  Tidy
  Uncommitted
}

/// A child's verdict: what was found, whether it left uncommitted work, and how
/// many times a transfer has failed to finish.
type Verdict {
  Verdict(outcome: Outcome, tree: Tree, attempts: Int)
}

/// Whether a verdict ends the matter. A captured state is waiting for its
/// transfer and is not final.
fn is_final(verdict: Verdict) -> Bool {
  case verdict.outcome {
    NoCommits | Returned(..) | Refused(..) -> True
    Waiting | Captured(..) -> False
  }
}

/// The verdict as the JSON text kept in its file.
fn encode_verdict(verdict: Verdict) -> String {
  // Each outcome is a kind word, the state it carries and its reason.
  let #(kind, state, reason) = case verdict.outcome {
    NoCommits -> #("none", None, "")
    Waiting -> #("waiting", None, "")
    Captured(state:) -> #("captured", Some(state), "")
    Returned(state:) -> #("returned", Some(state), "")
    Refused(reason:) -> #("refused", None, reason)
  }

  json.object([
    #("outcome", json.string(kind)),
    #(
      "state",
      json.nullable(option.map(state, state_object.encode), json.string),
    ),
    #("reason", json.string(reason)),
    #("uncommitted", json.string(tree_word(verdict.tree))),
    #("attempts", json.int(verdict.attempts)),
  ])
  |> json.to_string
}

/// The word a tree is kept as in the verdict file.
fn tree_word(tree: Tree) -> String {
  case tree {
    Tidy -> "tidy"
    Uncommitted -> "uncommitted"
  }
}

/// Reads a verdict back. A file that does not parse is no verdict, which costs a
/// repeat of the work and nothing more.
fn decode_verdict(text: String) -> Result(Verdict, Nil) {
  let decoder = {
    use kind <- decode.field("outcome", decode.string)
    use state <- decode.field("state", decode.optional(decode.string))
    use reason <- decode.field("reason", decode.string)
    use tree <- decode.field("uncommitted", decode.string)
    use attempts <- decode.field("attempts", decode.int)
    decode.success(#(kind, state, reason, tree, attempts))
  }
  use #(kind, state, reason, tree, attempts) <- result.try(result.replace_error(
    json.parse(text, decoder),
    Nil,
  ))

  // A state, when the file has one, is read with the total state decoder.
  use held <- result.try(case state {
    Some(text) ->
      state_object.decode(text) |> result.map(Some) |> result.replace_error(Nil)
    None -> Ok(None)
  })

  // The outcome and the state it carries must agree.
  use outcome <- result.map(case kind, held {
    "none", None -> Ok(NoCommits)
    "waiting", None -> Ok(Waiting)
    "captured", Some(state) -> Ok(Captured(state:))
    "returned", Some(state) -> Ok(Returned(state:))
    "refused", None -> Ok(Refused(reason:))
    _, _ -> Error(Nil)
  })

  // Anything but the word for uncommitted is a tidy tree.
  let tree = case tree {
    "uncommitted" -> Uncommitted
    _ -> Tidy
  }

  Verdict(outcome:, tree:, attempts:)
}

// --- answering a join ---------------------------------------------------------

/// Answers one entry of a join.
fn settle(
  node: StateNode,
  reach: Reach,
  spawner: Spawner,
  parent: Parent,
  entry: Joined,
  states: Option(SessionStates),
) -> Joined {
  // Only a finished child that carries no state yet can have commits to return.
  case entry {
    remote_spawn.Ready(handle:, state: None, ..) ->
      settle_child(node, reach, spawner, parent, handle, entry, states)
    remote_spawn.Ready(state: Some(..), ..) | remote_spawn.Pending(..) -> entry
  }
}

/// Answers a finished child's entry when it has a record, and returns it as it is
/// when it has none.
fn settle_child(
  node: StateNode,
  reach: Reach,
  spawner: Spawner,
  parent: Parent,
  handle: Handle,
  entry: Joined,
  states: Option(SessionStates),
) -> Joined {
  let key = key_of(spawner, parent, handle)
  let settled = {
    use directory <- result.try(result.replace_error(
      returns_directory(node),
      Nil,
    ))
    use text <- result.try(
      simplifile.read(directory <> "/" <> key <> ".copy")
      |> result.replace_error(Nil),
    )
    use copy <- result.map(decode_copy(text))
    answered(node, reach, spawner, copy, directory, key, entry, states)
  }

  // A child with no readable record was not seeded, and is answered as it was.
  result.unwrap(settled, entry)
}

/// Answers the entry of a seeded child from its verdict, running the work when the
/// verdict is not final, and answers `Pending` while the work is not done.
fn answered(
  node: StateNode,
  reach: Reach,
  spawner: Spawner,
  copy: Copy,
  directory: String,
  key: String,
  entry: Joined,
  states: Option(SessionStates),
) -> Joined {
  let known = verdict_of(directory, key)

  // A final verdict is the answer; anything else is work to run or to wait for,
  // and a captured state that is not yet in the parent's store is not an answer.
  let verdict =
    option.lazy_or(final_of(known), fn() {
      final_of(attempt(
        node,
        reach,
        spawner,
        copy,
        directory,
        key,
        known,
        states,
      ))
    })

  // An answer amends the entry, and its absence leaves the child unfinished.
  case verdict {
    Some(verdict) -> amend(entry, verdict)
    None -> pending_of(entry)
  }
}

/// The verdict, when it ends the matter.
fn final_of(verdict: Option(Verdict)) -> Option(Verdict) {
  option.then(verdict, fn(found) {
    case is_final(found) {
      True -> Some(found)
      False -> None
    }
  })
}

/// The entry of a child whose commits are still being returned.
fn pending_of(entry: Joined) -> Joined {
  case entry {
    remote_spawn.Ready(handle:, ..) ->
      remote_spawn.Pending(handle:, waited_ms: wait_ms)
    remote_spawn.Pending(..) -> entry
  }
}

/// The verdict a child's file holds, if it has one that reads.
fn verdict_of(directory: String, key: String) -> Option(Verdict) {
  case simplifile.read(directory <> "/" <> key <> ".verdict") {
    Ok(text) -> option.from_result(decode_verdict(text))
    Error(_) -> None
  }
}

/// Runs the work for one child, unless another join is running it, and waits for
/// it a little. `None` says the work is not finished: it runs on in a process of
/// its own and the next join finds what it learned.
fn attempt(
  node: StateNode,
  reach: Reach,
  spawner: Spawner,
  copy: Copy,
  directory: String,
  key: String,
  known: Option(Verdict),
  states: Option(SessionStates),
) -> Option(Verdict) {
  let now_s = ffi_os.system_time_ms() / 1000

  // A claim, made by creating a directory, keeps joins that arrive while the work
  // runs from each starting it.
  case spawn_seed.claim(directory, key, now_s) {
    Error(_) -> None
    Ok(spawn_seed.Busy) -> None
    Ok(spawn_seed.Claimed) -> {
      let reply = process.new_subject()
      let _working =
        process.spawn_unlinked(fn() {
          process.send(
            reply,
            working(node, reach, spawner, copy, directory, key, known, states),
          )
        })

      // A join that stops waiting leaves the work running.
      option.from_result(process.receive(reply, wait_ms))
    }
  }
}

/// The work: runs under a deadline of its own, keeps what it learned in the
/// child's verdict file, and releases the claim whatever the end.
fn working(
  node: StateNode,
  reach: Reach,
  spawner: Spawner,
  copy: Copy,
  directory: String,
  key: String,
  known: Option(Verdict),
  states: Option(SessionStates),
) -> Verdict {
  let outcomes =
    weft.new([fn() { Ok(found(node, reach, spawner, copy, known, states)) }])
    |> weft.deadline(work_ms)
    |> weft.start

  // A task that finished has its own answer; every other end is the deadline.
  let verdict = case outcomes {
    [weft.Completed(value:, ..)] -> value
    [weft.Failed(..)]
    | [weft.Crashed(..)]
    | [weft.Abandoned(..)]
    | [weft.NeverStarted(..)]
    | [weft.DrainProofLost(..)]
    | [weft.CancellationUnconfirmed(..)]
    | []
    | [_, _, ..] ->
      Verdict(
        outcome: Refused(
          "the work of returning its commits did not finish in time",
        ),
        tree: Tidy,
        attempts: 0,
      )
  }

  // The verdict is kept before the claim is let go, so no join finds the claim
  // free and the verdict missing.
  let _kept =
    write_whole(directory <> "/" <> key <> ".verdict", encode_verdict(verdict))
  let _released = simplifile.delete(directory <> "/" <> key <> ".claim")
  verdict
}

/// Captures the child's commits and sends them, resuming from what an earlier
/// attempt kept. A child in a directory is captured on this machine, and a child
/// in a session of its own is captured on its executor.
fn found(
  node: StateNode,
  reach: Reach,
  spawner: Spawner,
  copy: Copy,
  known: Option(Verdict),
  states: Option(SessionStates),
) -> Verdict {
  case copy.home {
    Directory -> found_in_directory(node, reach, spawner, copy, known)
    Session -> found_in_session(node, reach, spawner, copy, known, states)
  }
}

/// The work for a child whose copy is a directory of this machine.
fn found_in_directory(
  node: StateNode,
  reach: Reach,
  spawner: Spawner,
  copy: Copy,
  known: Option(Verdict),
) -> Verdict {
  // The directory is the spawner's own, and a finished copy is a real directory
  // at its name: a link a session planted is not followed.
  let located = case spawner.placement {
    InDirectory(path:) ->
      bootstrap.canonical_directory(path)
      |> result.replace_error(Nil)
      |> result.try(spawn_seed.copy_at(_, copy.name))
    spawners.OnExecutor(..) | spawners.InPool(..) -> Error(Nil)
  }

  // An earlier attempt that captured and could not send sends the same state.
  case located, known {
    Error(Nil), _ ->
      Verdict(
        outcome: Refused("the child's copy of the workspace is not there"),
        tree: Tidy,
        attempts: 0,
      )
    Ok(_), Some(Verdict(outcome: Captured(state:), tree:, attempts:)) ->
      sent(node, reach, spawner, state, tree, attempts)
    Ok(path), Some(_) | Ok(path), None ->
      captured(node, reach, spawner, copy, path)
  }
}

/// The work for a child that has a session of its own on an executor: capture its
/// commits there, bring the bundle to this machine's store, and send it on.
///
/// An earlier attempt that captured keeps the state, and this one goes on from the
/// pull. A child's record that finds no open session is refused: the join opens the
/// session before it settles an entry, so a missing one means it could not be
/// opened.
fn found_in_session(
  node: StateNode,
  reach: Reach,
  spawner: Spawner,
  copy: Copy,
  known: Option(Verdict),
  states: Option(SessionStates),
) -> Verdict {
  case states, known {
    None, _ ->
      Verdict(
        outcome: Refused(
          "the child's workspace on its executor is not reachable",
        ),
        tree: Tidy,
        attempts: 0,
      )
    Some(states), Some(Verdict(outcome: Captured(state:), tree:, attempts:)) ->
      pulled(node, reach, spawner, states, state, tree, attempts)
    Some(states), Some(Verdict(attempts:, ..)) ->
      committed(node, reach, spawner, copy, states, attempts)
    Some(states), None -> committed(node, reach, spawner, copy, states, 0)
  }
}

/// Asks the executor for the child's commits, thin against the tip it was handed,
/// and brings them on. `tries` is how many times the executor has not answered.
fn committed(
  node: StateNode,
  reach: Reach,
  spawner: Spawner,
  copy: Copy,
  states: SessionStates,
  tries: Int,
) -> Verdict {
  let made =
    states.capture(state_object.Thin(copy.tip), state_object.CommittedOnly)

  // Nothing committed is an answer, silence is another try, and a refusal is
  // final: capturing again does not change what is wrong with the workspace.
  case made {
    Ok(None) -> Verdict(outcome: NoCommits, tree: Tidy, attempts: 0)
    Ok(Some(state)) -> pulled(node, reach, spawner, states, state, Tidy, 0)
    Error(session_states.Later(..)) -> waiting(tries + 1)
    Error(session_states.Final(reason:)) -> {
      // The detail can hold the executor's paths and Git's own words, so it stays
      // in this machine's log and the parent is told a fixed sentence.
      log.warn(reach.logger, "spawn_return.capture_refused", [
        field.text("detail", clipped(reason)),
      ])
      Verdict(outcome: Refused(capture_refused), tree: Tidy, attempts: 0)
    }
  }
}

/// The verdict for a request the executor has not answered: asked again at the
/// next join, until `max_attempts`.
fn waiting(attempts: Int) -> Verdict {
  // The last try gives the request up, and says where the commits are.
  case attempts >= max_attempts {
    True ->
      Verdict(
        outcome: Refused(
          "the machine the child ran on did not answer the request for its commits after "
          <> int.to_string(max_attempts)
          <> " tries. The commits are in the child's workspace there",
        ),
        tree: Tidy,
        attempts:,
      )
    False -> Verdict(outcome: Waiting, tree: Tidy, attempts:)
  }
}

/// Brings a state captured on the executor into this node's store, resuming at
/// the bytes the store holds, and sends it on to the parent.
fn pulled(
  node: StateNode,
  reach: Reach,
  spawner: Spawner,
  states: SessionStates,
  state: State,
  tree: Tree,
  attempts: Int,
) -> Verdict {
  // Delivered is in this node's store whole; a refusal is final, and silence is
  // another try with the captured state kept.
  case state_transfer.pull(node.endpoint, state.hash, from: states.link) {
    state_transfer.Delivered ->
      sent(node, reach, spawner, state, tree, attempts)
    state_transfer.Declined(refusal:) -> {
      log.warn(reach.logger, "spawn_return.pull_declined", [
        field.text("detail", clipped(state_transfer.describe(refusal))),
      ])
      Verdict(outcome: Refused(pull_failed), tree:, attempts:)
    }
    state_transfer.Faulted(reason:) -> {
      log.warn(reach.logger, "spawn_return.pull_faulted", [
        field.text("detail", clipped(reason)),
      ])
      Verdict(outcome: Refused(pull_failed), tree:, attempts:)
    }
    state_transfer.Silent | state_transfer.Stalled ->
      unfinished(state, tree, attempts + 1)
  }
}

/// The name of the session a child has to itself, from its record, or `None`
/// for a child with no record or one whose copy is in a directory.
fn session_of(
  node: StateNode,
  spawner: Spawner,
  parent: Parent,
  handle: Handle,
) -> Option(String) {
  let named = {
    use directory <- result.try(result.replace_error(
      returns_directory(node),
      Nil,
    ))
    use text <- result.try(
      simplifile.read(
        directory <> "/" <> key_of(spawner, parent, handle) <> ".copy",
      )
      |> result.replace_error(Nil),
    )
    use copy <- result.try(decode_copy(text))

    // Only a child with a session of its own has a name to find it by.
    case copy.home {
      Session -> Ok(copy.name)
      Directory -> Error(Nil)
    }
  }
  option.from_result(named)
}

/// Looks at the child's tree, captures its commits, and sends them.
fn captured(
  node: StateNode,
  reach: Reach,
  spawner: Spawner,
  copy: Copy,
  path: String,
) -> Verdict {
  let tree = tree_of(node, path)

  // A node with no sandboxed Git cannot capture, and says why.
  let made = case state_node.capturer(node) {
    None ->
      Error("this machine has no sandboxed Git to capture the commits with")
    Some(capturer) -> state_capture.capture_commits(capturer, path, copy.tip)
  }

  // Nothing committed is an answer, and a refusal is final: capturing again
  // does not change what is wrong with the repository.
  case made {
    Ok(None) -> Verdict(outcome: NoCommits, tree:, attempts: 0)
    Error(reason) -> {
      // The detail can hold this machine's paths and Git's own words, so it is
      // kept in this machine's log and the parent is told a fixed sentence.
      log.warn(reach.logger, "spawn_return.capture_refused", [
        field.text("detail", clipped(reason)),
      ])
      Verdict(outcome: Refused(capture_refused), tree:, attempts: 0)
    }
    Ok(Some(state)) -> sent(node, reach, spawner, state, tree, 0)
  }
}

/// Sends a captured state to the parent's store from this node's, resuming at the
/// offset the parent holds.
fn sent(
  node: StateNode,
  reach: Reach,
  spawner: Spawner,
  state: State,
  tree: Tree,
  attempts: Int,
) -> Verdict {
  // A transfer needs both the store to read from and a link to send over.
  let moved = case node.store, reach.link_to(spawner.node) {
    Some(store), Some(link) ->
      Some(state_transfer.send(store, state.hash, link))
    None, _ | _, None -> None
  }

  // Delivered ends the matter, and so does a refusal or a lost state. Silence,
  // no link and a stalled transfer leave the captured state to the next attempt,
  // until there have been too many.
  case moved {
    Some(state_transfer.Delivered) ->
      Verdict(outcome: Returned(state:), tree:, attempts:)
    Some(state_transfer.Declined(refusal:)) ->
      Verdict(
        outcome: Refused(
          "the parent's machine declined them: "
          <> clipped(state_transfer.describe(refusal)),
        ),
        tree:,
        attempts:,
      )
    Some(state_transfer.Faulted(reason:)) -> {
      // A fault in this machine's own store can name its paths, so the parent is
      // told a fixed sentence and the detail stays in the log.
      log.warn(reach.logger, "spawn_return.send_faulted", [
        field.text("detail", clipped(reason)),
      ])
      Verdict(outcome: Refused(send_faulted), tree:, attempts:)
    }
    Some(state_transfer.Silent) | Some(state_transfer.Stalled) | None ->
      unfinished(state, tree, attempts + 1)
  }
}

/// A transfer that did not finish: tried again by the next join, until
/// `max_attempts`.
fn unfinished(state: State, tree: Tree, attempts: Int) -> Verdict {
  // The last try gives the commits up, and says where they are kept.
  case attempts >= max_attempts {
    True ->
      Verdict(
        outcome: Refused(
          "the transfer to the parent's machine did not finish after "
          <> int.to_string(max_attempts)
          <> " tries. The commits are kept on the machine the child ran on, in its state store as "
          <> state_object.short(state.hash),
        ),
        tree:,
        attempts:,
      )
    False -> Verdict(outcome: Captured(state:), tree:, attempts:)
  }
}

/// Whether the child's copy has changes it did not commit. A failure to ask is
/// taken as none, because the answer only decides one sentence of the report.
fn tree_of(node: StateNode, path: String) -> Tree {
  // A node with no Git cannot ask, and says nothing.
  case node.git {
    None -> Tidy
    Some(git) -> {
      let asked =
        worktree_git.run(
          git,
          worktree_git.Run(directory: path, writable: [], arguments: [
            "--no-optional-locks", "-c", "core.fsmonitor=false", "-c",
            "core.hooksPath=/dev/null", "status", "--porcelain=v1",
            "--untracked-files=normal",
          ]),
          worktree_git.query_within_ms,
        )

      // Git prints a line for each change and exits zero.
      case asked {
        Ok(output) ->
          case output.code == 0 && string.trim(output.stdout) != "" {
            True -> Uncommitted
            False -> Tidy
          }
        Error(_) -> Tidy
      }
    }
  }
}

/// Peer-influenced text, cut and made printable for a sentence the model reads.
fn clipped(text: String) -> String {
  worktree_git.printable(text, 300)
}

// --- the entry the parent reads ----------------------------------------------

/// The reason a refused capture is reported with. The detail is in the log of the
/// machine the child ran on.
pub const capture_refused =
  "the commits could not be captured on the machine the child ran on; its log has the detail"

/// The reason a transfer that this machine's store could not serve is reported with.
pub const send_faulted =
  "this machine's state store could not serve the commits; its log has the detail"

/// The reason a bundle that could not be brought into this machine's store is
/// reported with. The detail is in this machine's log.
pub const pull_failed =
  "this machine's state store could not take the commits from the machine the child ran on; its log has the detail"

/// The sentence for a child that left changes uncommitted.
pub const uncommitted_note =
  "It left uncommitted changes in its copy of the workspace. They are not returned: only commits are."

/// The sentence for a child that committed nothing.
pub const no_commits_note =
  "It made no commits on top of the workspace it was given, so nothing comes back to your repository."

/// Turns a final verdict into the entry the parent reads: the state on a return,
/// and sentences appended to the child's report for everything else the parent
/// ought to know. The sentences are fixed words and a bounded reason.
fn amend(entry: Joined, verdict: Verdict) -> Joined {
  // A child that has not finished has nothing to amend.
  case entry {
    remote_spawn.Pending(..) -> entry
    remote_spawn.Ready(report:, ..) -> {
      // What became of the commits, in a sentence when the parent ought to know.
      let outcome_notes = case verdict.outcome {
        NoCommits -> [no_commits_note]
        Refused(reason:) -> [
          "Its commits could not be returned to your repository: "
          <> reason
          <> ".",
        ]
        Waiting | Captured(..) | Returned(..) -> []
      }

      // Whether it left work behind that does not come back.
      let tree_notes = case verdict.tree {
        Uncommitted -> [uncommitted_note]
        Tidy -> []
      }

      // The report comes first, and an empty one leaves no blank paragraph.
      let report =
        [[report], outcome_notes, tree_notes]
        |> list.flatten
        |> list.filter(fn(paragraph) { paragraph != "" })
        |> string.join("\n\n")

      // Only a return carries a state.
      case verdict.outcome {
        Returned(state:) ->
          remote_spawn.Ready(..entry, report:, state: Some(state))
        NoCommits | Refused(..) | Waiting | Captured(..) ->
          remote_spawn.Ready(..entry, report:)
      }
    }
  }
}
