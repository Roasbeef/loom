//// Joining children that run in different sessions of one parent
//// (protocol-change/107, slice 4b).
////
//// A parent that spawns on a remote orchestrator asks for its children's results
//// with one join naming their handles, and the receiver used to answer it from one
//// delegate session, the pair's. A child that was seeded onto an executor runs in
//// a session of its own, so the same join has to ask several sessions, and it has
//// to do three more things for the children that live in them.
////
//// ## What a join does for a seeded child
////
//// 1. It asks the child's own session, opened if it is not resident and never
////    made: a child that settled and was released has none, and a join about it is
////    refused instead of creating a session to hold the answer.
//// 2. It lets the child's commits come back before the child is reported finished
////    (`client/spawn_return`), which needs the session's record of its workspace.
//// 3. It ends the session once the child is settled and owes nothing. A session
////    costs a slot against the spawner's `max_sessions` and a worktree on the
////    executor, and the commits no longer need either: they are in this machine's
////    store, or have gone to the parent's.
////
//// ## A join can be asked again
////
//// A parent asks again by design: a wait made from a program is deferred and
//// retried, a second wait names handles that settled in the first, and a reply may
//// be lost. The session is gone after the first answer, so before it is ended the
//// settled entry is kept (`Returning.keep`, beside the child's verdict), and a join
//// that finds no session, or one being released, answers from it. A repeated join
//// therefore gets the answer the first one did however often it is asked. A child
//// whose record cannot be read is not placed at all and answers `Pending`.
////
//// ## Why a session is not ended earlier
////
//// The commits may reach the parent over several joins, because a transfer that
//// does not finish is tried again at the next one, and the answer the parent reads
//// is made from the session's record of the child. So the session is kept until the
//// entry for the child is `Ready`, which `spawn_return` says only when the matter of
//// its commits is decided, and until the child owes the parent no mail, which the
//// session's outbox holds. A child whose parent never joins it is ended with the
//// parent (`delegate_host.releaser`) or by the retention sweep.
////
//// ## Flow
////
//// `join` → `grouped` → `asked` → `asked_in` → `reassembled`
////
//// 1. `join` splits the handles into those the pair's session serves and those that
////    have a session of their own, and answers a join with no seeded child exactly
////    as before.
//// 2. `grouped` runs one task for the pair's group and one for each seeded child,
////    all at once and under one deadline, so a join over eight children waits for
////    the slowest of them and not for all of them in turn.
//// 3. `asked` is one group's work: join, settle each entry, and end the session of
////    a child that is done.
//// 4. `reassembled` puts the entries back in the order the handles came in.

import client/agency.{type DelegateEndpoint}
import client/delegate_host.{type ChildSessions}
import client/remote_spawn.{type Joined, type Parent, type SpawnRefusal}
import client/spawn_return.{type Returning}
import client/spawners.{type Spawner}
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import tools/agent.{type Handle}
import weft

/// What a join needs to reach the sessions that hold a parent's children.
pub type Joining {
  Joining(
    /// The spawner the join came from.
    spawner: Spawner,
    /// The parent session and strand it speaks for.
    parent: Parent,
    /// Finds or makes the session that serves the pair's other children.
    pair: fn() -> Result(DelegateEndpoint, SpawnRefusal),
    /// The sessions of seeded children.
    children: ChildSessions,
    /// What becomes of a finished child's commits.
    returning: Returning,
  )
}

/// How much longer than the window a join may take to settle the entries it
/// collected, in milliseconds: the time to capture and move a seeded child's
/// commits, which the work does in a process of its own and the join only waits a
/// little for.
const settle_margin_ms = 20_000

/// Answers a join over `handles`, waiting at most `within_ms` for the children.
///
/// A join with no seeded child is the pair's session asked once, and its entries
/// settled with no session record, as it has always been. Otherwise each group is
/// asked in its own task and the first refusal of any group is the join's. A group
/// that does not finish in time answers `Pending` for its handles, which the parent
/// reads as children still finishing and asks about again.
///
/// ## Examples
///
/// ```gleam
/// // child_join.join(joining, [handle], 25_000) == Ok([remote_spawn.Pending(handle:, waited_ms: 25_000)])
/// ```
pub fn join(
  joining: Joining,
  handles: List(Handle),
  within_ms: Int,
) -> Result(List(Joined), SpawnRefusal) {
  let named =
    list.map(handles, fn(handle) {
      #(
        handle,
        joining.returning.session_of(joining.spawner, joining.parent, handle),
      )
    })
  let shared =
    list.filter_map(named, fn(each) {
      case each.1 {
        spawn_return.Unseeded -> Ok(each.0)
        spawn_return.OwnSession(..) | spawn_return.Unreadable -> Error(Nil)
      }
    })
  let own =
    list.filter_map(named, fn(each) {
      case each.1 {
        spawn_return.OwnSession(name:) -> Ok(#(each.0, name))
        spawn_return.Unseeded | spawn_return.Unreadable -> Error(Nil)
      }
    })
  let unplaced = list.any(named, fn(each) { each.1 == spawn_return.Unreadable })

  // No seeded child, and every record readable, is the join it always was, in
  // this process. Otherwise a handle whose record cannot be read is left out of
  // every group and answered `Pending` with the rest.
  case own, unplaced {
    [], False -> pair_group(joining, shared, within_ms)
    _, _ -> grouped(joining, handles, shared, own, within_ms)
  }
}

/// One group's handles and the work that answers them.
type Group {
  Group(handles: List(Handle), work: fn() -> Result(List(Joined), SpawnRefusal))
}

/// Runs the pair's group, when it has handles, and each seeded child's group, all
/// at once under one deadline.
fn grouped(
  joining: Joining,
  handles: List(Handle),
  shared: List(Handle),
  own: List(#(Handle, String)),
  within_ms: Int,
) -> Result(List(Joined), SpawnRefusal) {
  // The pair's session is asked only when some handle is its to answer.
  let pair = case shared {
    [] -> []
    [_, ..] -> [
      Group(handles: shared, work: fn() {
        pair_group(joining, shared, within_ms)
      }),
    ]
  }

  // Every seeded child's own session is asked about that child alone.
  let children =
    list.map(own, fn(each) {
      Group(handles: [each.0], work: fn() {
        asked(joining, each.0, each.1, within_ms)
      })
    })
  let groups = list.append(pair, children)

  // A join in which no handle could be placed has nothing to ask.
  case groups {
    [] -> Ok(reassembled([], handles, within_ms))
    [_, ..] -> asked_together(groups, handles, within_ms)
  }
}

/// Runs the groups all at once under one deadline and reads what each answered.
fn asked_together(
  groups: List(Group),
  handles: List(Handle),
  within_ms: Int,
) -> Result(List(Joined), SpawnRefusal) {
  let outcomes =
    weft.new(list.map(groups, fn(group) { group.work }))
    |> weft.limit(list.length(groups))
    |> weft.deadline(within_ms + settle_margin_ms)
    |> weft.start

  // Each group is read for what it answered, or for the children it left waiting.
  let entries =
    list.zip(groups, outcomes)
    |> list.map(fn(each) { answered(each.0, each.1, within_ms) })
    |> list.flatten
  Ok(reassembled(entries, handles, within_ms))
}

/// What one group's task came to, as the entries for its handles. A group's refusal
/// is about its own children and not about the others in the same join.
fn answered(
  group: Group,
  outcome: weft.Outcome(List(Joined), SpawnRefusal),
  within_ms: Int,
) -> List(Joined) {
  case outcome {
    weft.Completed(value:, ..) -> value
    weft.Failed(error:, ..) -> refused(group, error, within_ms)

    // A group the deadline cut off, or that crashed, has told the parent nothing,
    // so its children are still finishing as far as the parent can know.
    weft.Crashed(..)
    | weft.Abandoned(..)
    | weft.NeverStarted(..)
    | weft.DrainProofLost(..)
    | weft.CancellationUnconfirmed(..) -> pending(group, within_ms)
  }
}

/// A group's handles as children still finishing.
fn pending(group: Group, within_ms: Int) -> List(Joined) {
  list.map(group.handles, fn(handle) {
    remote_spawn.Pending(handle:, waited_ms: within_ms)
  })
}

/// What a group's refusal means for its own handles. An orchestrator that holds
/// no such child, or whose run has ended, is a definite answer about that child, and
/// it is told as the child's failure with the reason. Any other refusal may pass,
/// and the child is still finishing as far as the parent can know.
fn refused(
  group: Group,
  refusal: SpawnRefusal,
  within_ms: Int,
) -> List(Joined) {
  case refusal {
    remote_spawn.InvalidArgument(reason:) -> failed(group, reason)
    remote_spawn.ParentRunEnded ->
      failed(group, remote_spawn.describe_refusal(refusal))
    _ -> pending(group, within_ms)
  }
}

/// A group's handles as children that ended in failure for a stated reason.
fn failed(group: Group, reason: String) -> List(Joined) {
  list.map(group.handles, fn(handle) {
    remote_spawn.Ready(
      handle:,
      outcome: agent.Failed(reason:),
      report: "",
      result: agent.NoResultAsked,
      notes: [],
      usage: remote_spawn.ChildUsage(
        input: 0,
        output: 0,
        cache_read: 0,
        cache_write: 0,
        cost: 0.0,
      ),
      owed: 0,
      state: None,
    )
  })
}

/// Puts the groups' entries in the order the handles came in.
fn reassembled(
  entries: List(Joined),
  handles: List(Handle),
  within_ms: Int,
) -> List(Joined) {
  let by_strand =
    entries
    |> list.map(fn(entry) { #(entry_handle(entry).strand, entry) })
    |> dict.from_list
  list.map(handles, fn(handle) {
    case dict.get(by_strand, handle.strand) {
      Ok(entry) -> entry
      Error(Nil) -> remote_spawn.Pending(handle:, waited_ms: within_ms)
    }
  })
}

/// The handle an entry is about.
fn entry_handle(entry: Joined) -> Handle {
  case entry {
    remote_spawn.Ready(handle:, ..) -> handle
    remote_spawn.Pending(handle:, ..) -> handle
  }
}

/// The pair's session asked about the handles it serves, each entry settled with
/// no record of a session of its own.
fn pair_group(
  joining: Joining,
  handles: List(Handle),
  within_ms: Int,
) -> Result(List(Joined), SpawnRefusal) {
  use endpoint <- result.try(joining.pair())
  use entries <- result.map(endpoint.join(joining.parent, handles, within_ms))
  list.map(entries, fn(entry) {
    joining.returning.settle(joining.spawner, joining.parent, entry, None)
  })
}

/// One seeded child's group: its own session asked, the entry settled with the
/// session's record of its workspace, and the session ended once the child is
/// done.
fn asked(
  joining: Joining,
  handle: Handle,
  name: String,
  within_ms: Int,
) -> Result(List(Joined), SpawnRefusal) {
  let kept = joining.returning.kept
  let spawner = joining.spawner
  let parent = joining.parent
  let gone = fn(refusal) {
    // A child with no session was settled and released, or never started. A
    // settled one left its answer.
    case kept(spawner, parent, handle) {
      Some(entry) -> Ok([entry])
      None -> Error(refusal)
    }
  }

  // An open session answers, and one that is gone or being released answers from
  // the kept entry when there is one.
  case joining.children.open(joining.spawner, joining.parent, name) {
    Ok(Some(endpoint)) -> asked_in(joining, endpoint, handle, name, within_ms)
    Ok(None) ->
      gone(remote_spawn.InvalidArgument(
        reason: "this orchestrator holds no such child for that parent",
      ))

    // A session being released refuses as its run having ended, which is the
    // state a settled child's session is in for a moment.
    Error(remote_spawn.ParentRunEnded) -> gone(remote_spawn.ParentRunEnded)
    Error(refusal) -> Error(refusal)
  }
}

/// A seeded child's open session asked, its entry settled and kept, and the
/// session ended once the child is done.
fn asked_in(
  joining: Joining,
  endpoint: DelegateEndpoint,
  handle: Handle,
  name: String,
  within_ms: Int,
) -> Result(List(Joined), SpawnRefusal) {
  use entries <- result.map(endpoint.join(joining.parent, [handle], within_ms))
  let settled =
    list.map(entries, fn(entry) {
      joining.returning.settle(
        joining.spawner,
        joining.parent,
        entry,
        endpoint.states,
      )
    })
  ended_when_done(joining, name, settled)
  settled
}

/// Ends the child's session when its entry says it is finished and owes the
/// parent nothing. The release is idempotent, so a join that repeats it, or one
/// that finds the registry has already done it, changes nothing.
fn ended_when_done(
  joining: Joining,
  name: String,
  settled: List(Joined),
) -> Nil {
  let done =
    list.any(settled, fn(entry) {
      case entry {
        remote_spawn.Ready(owed: 0, ..) -> True
        remote_spawn.Ready(..) | remote_spawn.Pending(..) -> False
      }
    })

  // The entry is kept before the session goes, so a join that comes after it is
  // answered the same. A failure to end the session costs a slot until the
  // parent's release or the sweep, and the entry has been answered, so it is not
  // the join's to report.
  case done {
    True -> {
      list.each(settled, fn(entry) {
        joining.returning.keep(joining.spawner, joining.parent, entry)
      })
      let _ = joining.children.release(joining.spawner, joining.parent, name)
      Nil
    }
    False -> Nil
  }
}
