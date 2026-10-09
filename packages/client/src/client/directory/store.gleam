//// The directory store: the Khepri store `loom_directory` that holds one owner
//// record per remote session (protocol-change/079).
////
//// This module is the only caller of `client/internal/ffi_khepri`, and it adds
//// two things the FFI cannot. Every call runs in a weft task under a deadline,
//// because a Khepri call may wait on a quorum and the consistent read ignores
//// its own timeout once the majority is gone; a call that outlives its
//// deadline is reported as no quorum, never as an answer. And every payload
//// read back crosses `record.decode`, the total decoder for the durable record.
////
//// There is one store per VM. The functions here take no handle: the Ra system
//// and the store are registered under fixed names, and a daemon starts them
//// once at boot (`start_system`, then `boot` or `join`).
////
//// ## Two kinds of read
////
//// `read` returns this member's own copy without waiting for anyone, and can
//// lag the leader. It is for decisions a stale answer cannot make wrong: a
//// redirect, a mail route, whether a marker that is only ever added exists.
//// `read_consistent` first waits for the copy to hold everything the leader
//// has committed. It is for the mover's decisions to retire or resume.
////
//// ## Writes
////
//// `create`, `swap` and `delete_if` each name the exact value they expect, so a
//// write never depends on a read before it. A refusal is either `NoQuorum`,
//// whose outcome may be unknown and whose caller reads before it acts, or
//// `Mismatch`, which carries what the record holds now.

import client/directory/record.{type Record}
import client/internal/ffi_khepri
import gleam/dynamic.{type Dynamic}
import gleam/erlang/node.{type Node}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import simplifile
import weft
import weft/poll

/// How long a write may take before it is reported as no quorum.
pub const write_ms = 3000

/// How long a receiver's activation write may take.
pub const activation_ms = 5000

/// How long a read may take, including the fence of a consistent read.
pub const read_ms = 3000

/// Why a read gave no answer.
pub type Unavailable {
  Unavailable(
    /// What went wrong, for a log line or a refusal's message.
    reason: String,
  )
}

/// Why a write did not commit.
pub type WriteRefusal {
  /// The write did not commit within its deadline, or the store is not
  /// running. Its outcome may be unknown.
  NoQuorum(
    /// What went wrong, for a log line or a refusal's message.
    reason: String,
  )

  /// The record did not hold the expected value. Carries what it holds now,
  /// or `None` when there is no record.
  Mismatch(
    /// The record as it stands.
    found: Option(Record),
  )
}

/// Ra's view of the cluster from this member.
pub type Membership {
  Membership(
    /// Each member's node name and whether it votes, in name order.
    members: List(#(String, ffi_khepri.Voting)),
    /// The leader's node name, when there is one.
    leader: Option(String),
  )
}

// --- lifecycle -----------------------------------------------------------------

/// Starts the Khepri and Ra applications and the Ra system rooted at the
/// directory. The store itself is started by `boot` or `join`.
///
/// ## Examples
///
/// ```gleam
/// // store.start_system(state_root <> "/directory")
/// ```
pub fn start_system(directory: String) -> Result(Nil, String) {
  use Nil <- result.try(
    simplifile.create_directory_all(directory)
    |> result.map_error(fn(error) {
      "the directory store's data directory "
      <> directory
      <> " could not be created: "
      <> simplifile.describe_error(error)
    }),
  )
  ffi_khepri.start_system(directory)
}

/// Starts the store. A member whose store is joined restarts its server with
/// its membership; `bootstrap` uses the same call on an empty directory to
/// create a one-member cluster.
///
/// ## Examples
///
/// ```gleam
/// // store.boot(30_000)
/// ```
pub fn boot(within_ms: Int) -> Result(Nil, String) {
  bounded(within_ms + 1000, Error("the store did not start in time"), fn() {
    ffi_khepri.boot(within_ms)
  })
}

/// Joins the cluster through the member on `remote` as a non-voter and returns
/// once Ra has promoted this member.
///
/// The join is four requests to the cluster in order: start a fresh local
/// server, have the cluster forget this member's old identity (a member that
/// lost its disk is still listed under it), add the server as a promotable
/// non-voter, and wait for Ra to promote it once it has caught up. Ra refuses a
/// membership change while an earlier one settles, so each step is repeated
/// under one deadline for the whole join. Any failure deletes the local server
/// again, so the next attempt starts clean.
///
/// ## Examples
///
/// ```gleam
/// // store.join(peer_node, 60_000)
/// ```
pub fn join(remote: Node, within_ms: Int) -> Result(Nil, String) {
  bounded(within_ms + 2000, Error("the join did not finish in time"), fn() {
    let clock = poll.monotonic()
    let deadline = clock.now() + within_ms
    let left = fn() { int.max(1, deadline - clock.now()) }
    use uid <- result.try(ffi_khepri.join_start())
    let joined = {
      use Nil <- result.try(
        joining(left, fn(ms) { ffi_khepri.join_remove(remote, ms) }),
      )
      use Nil <- result.try(
        joining(left, fn(ms) { ffi_khepri.join_add(remote, uid, ms) }),
      )
      use Nil <- result.try(
        joining(left, fn(ms) { ffi_khepri.join_promoted(remote, ms) }),
      )
      ffi_khepri.join_finish(left())
    }
    result.map_error(joined, fn(reason) {
      ffi_khepri.forget_local()
      reason
    })
  })
}

// One step of the join, asked again every 50 ms while the cluster says not
// yet, until it is taken, refused, or the join's deadline passes.
fn joining(
  left: fn() -> Int,
  step: fn(Int) -> ffi_khepri.JoinStep,
) -> Result(Nil, String) {
  let outcome =
    poll.until(within: left(), every: 50, attempt: fn() {
      case step(left()) {
        ffi_khepri.Done -> poll.Done(Nil)
        ffi_khepri.Again -> poll.Retry
        ffi_khepri.Failed(reason:) -> poll.Fail(reason)
      }
    })
  case outcome {
    poll.Answered(Nil) -> Ok(Nil)
    poll.Failed(reason) -> Error(reason)
    poll.Expired -> Error("the join did not finish in time")
  }
}

/// Stops the store and the Ra system.
///
/// ## Examples
///
/// ```gleam
/// // store.stop()
/// ```
pub fn stop() -> Nil {
  ffi_khepri.stop_system()
}

/// Deletes this member's local server and its data. Only for a store that is
/// not joined: bootstrap and a failed join use it to start clean.
///
/// ## Examples
///
/// ```gleam
/// // store.forget_local()
/// ```
pub fn forget_local() -> Nil {
  ffi_khepri.forget_local()
}

/// The file whose presence says this member's store is joined.
///
/// ## Examples
///
/// ```gleam
/// assert store.joined_marker("/s/directory") == "/s/directory/joined"
/// ```
pub fn joined_marker(directory: String) -> String {
  directory <> "/joined"
}

/// Whether this member's store is joined.
///
/// ## Examples
///
/// ```gleam
/// // store.is_joined(state_root <> "/directory")
/// ```
pub fn is_joined(directory: String) -> Bool {
  simplifile.is_file(joined_marker(directory)) == Ok(True)
}

/// Records that this member's store is joined.
///
/// ## Examples
///
/// ```gleam
/// // store.mark_joined(state_root <> "/directory")
/// ```
pub fn mark_joined(directory: String) -> Result(Nil, String) {
  simplifile.write(joined_marker(directory), "joined\n")
  |> result.map_error(fn(error) {
    "the joined marker could not be written: "
    <> simplifile.describe_error(error)
  })
}

/// Whether the data directory holds a store: the joined marker, or the
/// directory Ra keeps for a server it started. Bootstrap refuses one that
/// does.
///
/// A member daemon starts the Ra system at every boot, joined or not, and the
/// system writes its own files (`names.dets`, `meta.dets`, the first
/// write-ahead log) into the directory at once. Those hold no store and no
/// membership, so they are not counted: a member that booted before any
/// cluster existed can still be the one that creates it.
///
/// ## Examples
///
/// ```gleam
/// // store.holds_data(state_root <> "/directory")
/// ```
pub fn holds_data(directory: String) -> Bool {
  is_joined(directory)
  || case simplifile.read_directory(directory) {
    Ok(entries) ->
      list.any(entries, fn(entry) {
        simplifile.is_directory(directory <> "/" <> entry) == Ok(True)
      })
    Error(_) -> False
  }
}

/// Ra's view of the cluster from this member.
///
/// ## Examples
///
/// ```gleam
/// // store.membership() // -> Ok(Membership([#("a@h.x", Voter)], Some("a@h.x")))
/// ```
pub fn membership() -> Result(Membership, Unavailable) {
  bounded(read_ms + 1000, Error(Unavailable("no answer in time")), fn() {
    case ffi_khepri.membership(read_ms) {
      Ok(#(members, leader)) -> Ok(Membership(members:, leader:))
      Error(failure) -> Error(Unavailable(describe(failure)))
    }
  })
}

/// The log index of this member's latest snapshot, or 0 when it has none or
/// the store is not running.
///
/// ## Examples
///
/// ```gleam
/// // store.snapshot_index() // -> 4757
/// ```
pub fn snapshot_index() -> Int {
  ffi_khepri.snapshot_index()
}

/// Whether the directory store answers on another node, within two seconds.
/// A node that is down, unreachable or not running a store all say `False`.
///
/// ## Examples
///
/// ```gleam
/// // store.running_on(peer_node) // -> True
/// ```
pub fn running_on(node: Node) -> Bool {
  bounded(read_ms + 1000, Ok(False), fn() {
    Ok(ffi_khepri.store_running_on(node, read_ms))
  })
  == Ok(True)
}

/// The last log index this member has applied, or 0 when the store is not
/// running.
///
/// ## Examples
///
/// ```gleam
/// // store.applied_index() // -> 42
/// ```
pub fn applied_index() -> Int {
  ffi_khepri.applied_index()
}

// --- reads ---------------------------------------------------------------------

/// This member's own copy of a session's record, without waiting for other
/// members. `Ok(None)` means there is no record.
///
/// ## Examples
///
/// ```gleam
/// // store.read(session) // -> Ok(Some(Record("a@h.x", Serving)))
/// ```
pub fn read(session: String) -> Result(Option(Record), Unavailable) {
  bounded(read_ms + 1000, Error(Unavailable("no answer in time")), fn() {
    ffi_khepri.read(record.path(session), read_ms) |> decoded
  })
}

/// A session's record after this member's copy has caught up with everything
/// the leader has committed. Needs a quorum.
///
/// ## Examples
///
/// ```gleam
/// // store.read_consistent(session)
/// ```
pub fn read_consistent(session: String) -> Result(Option(Record), Unavailable) {
  bounded(2 * read_ms + 1000, Error(Unavailable("no quorum in time")), fn() {
    ffi_khepri.consistent(record.path(session), read_ms, read_ms) |> decoded
  })
}

/// Whether an orchestrator's migration marker exists in this member's copy.
/// The marker is only ever added, so a stale copy can only say `False` early.
///
/// ## Examples
///
/// ```gleam
/// // store.migrated("alpha@10.0.0.1") // -> Ok(True)
/// ```
pub fn migrated(node: String) -> Result(Bool, Unavailable) {
  bounded(read_ms + 1000, Error(Unavailable("no answer in time")), fn() {
    case ffi_khepri.read(record.migrated_path(node), read_ms) {
      Ok(Some(payload)) -> Ok(record.is_migrated(payload))
      Ok(None) -> Ok(False)
      Error(failure) -> Error(Unavailable(describe(failure)))
    }
  })
}

fn decoded(
  read: Result(Option(Dynamic), ffi_khepri.Failure),
) -> Result(Option(Record), Unavailable) {
  case read {
    Ok(None) -> Ok(None)
    Ok(Some(payload)) ->
      record.decode(payload)
      |> result.map(Some)
      |> result.map_error(Unavailable)
    Error(failure) -> Error(Unavailable(describe(failure)))
  }
}

// --- writes --------------------------------------------------------------------

/// Creates a session's record, refusing when one exists.
///
/// ## Examples
///
/// ```gleam
/// // store.create(session, Record(owner: node, state: record.Serving))
/// ```
pub fn create(session: String, new: Record) -> Result(Nil, WriteRefusal) {
  written(write_ms, fn() {
    ffi_khepri.create(record.path(session), record.encode(new), write_ms)
  })
}

/// Replaces a session's record only if it is exactly `expected`.
///
/// ## Examples
///
/// ```gleam
/// // store.swap(session, expected, new, store.write_ms)
/// ```
pub fn swap(
  session: String,
  expected: Record,
  new: Record,
  within_ms: Int,
) -> Result(Nil, WriteRefusal) {
  written(within_ms, fn() {
    ffi_khepri.swap(
      record.path(session),
      record.encode(expected),
      record.encode(new),
      within_ms,
    )
  })
}

/// Deletes a session's record only if it is exactly `expected`.
///
/// ## Examples
///
/// ```gleam
/// // store.delete_if(session, Record(owner: node, state: record.Serving))
/// ```
pub fn delete_if(
  session: String,
  expected: Record,
) -> Result(Nil, WriteRefusal) {
  written(write_ms, fn() {
    ffi_khepri.delete_if(
      record.path(session),
      record.encode(expected),
      write_ms,
    )
  })
}

/// Writes an orchestrator's migration marker.
///
/// ## Examples
///
/// ```gleam
/// // store.mark_migrated("alpha@10.0.0.1")
/// ```
pub fn mark_migrated(node: String) -> Result(Nil, WriteRefusal) {
  written(write_ms, fn() {
    ffi_khepri.put(record.migrated_path(node), record.migrated(), write_ms)
  })
}

// A write's Erlang answer, with a mismatch's payload decoded. A payload that
// does not decode is reported as no quorum with the decoder's reason: the
// caller can neither act on it nor treat it as absent, so it waits.
fn written(
  within_ms: Int,
  work: fn() -> Result(Nil, ffi_khepri.Failure),
) -> Result(Nil, WriteRefusal) {
  bounded(within_ms + 1000, Error(NoQuorum("no quorum in time")), fn() {
    case work() {
      Ok(Nil) -> Ok(Nil)
      Error(ffi_khepri.Mismatch(found: None)) -> Error(Mismatch(None))
      Error(ffi_khepri.Mismatch(found: Some(payload))) ->
        case record.decode(payload) {
          Ok(found) -> Error(Mismatch(Some(found)))
          Error(reason) -> Error(NoQuorum(reason))
        }
      Error(failure) -> Error(NoQuorum(describe(failure)))
    }
  })
}

fn describe(failure: ffi_khepri.Failure) -> String {
  case failure {
    ffi_khepri.NoQuorum -> "the directory has no quorum"
    ffi_khepri.NotRunning -> "the directory store is not running or not joined"
    ffi_khepri.Mismatch(..) -> "the directory record did not match"
  }
}

// Runs one call in a weft task cut off at `budget_ms`. Anything but a finished
// call (a crash, the deadline, a run that never started) is the fallback,
// which every caller chooses to mean "no answer", so a fault is never read as
// an answer.
fn bounded(
  budget_ms: Int,
  fallback: Result(a, e),
  work: fn() -> Result(a, e),
) -> Result(a, e) {
  let outcomes =
    weft.new([work])
    |> weft.deadline(budget_ms)
    |> weft.start
  case list.first(outcomes) {
    Ok(weft.Completed(value:, ..)) -> Ok(value)
    Ok(weft.Failed(error:, ..)) -> Error(error)
    Ok(weft.Crashed(..))
    | Ok(weft.Abandoned(..))
    | Ok(weft.NeverStarted(..))
    | Ok(weft.DrainProofLost(..))
    | Ok(weft.CancellationUnconfirmed(..))
    | Error(Nil) -> fallback
  }
}

/// A short description of a write refusal, for log lines and messages.
///
/// ## Examples
///
/// ```gleam
/// assert store.describe_refusal(store.Mismatch(option.None))
///   == "the directory holds no record for the session"
/// ```
pub fn describe_refusal(refusal: WriteRefusal) -> String {
  case refusal {
    NoQuorum(reason:) -> reason
    Mismatch(found: None) -> "the directory holds no record for the session"
    Mismatch(found: Some(found)) ->
      "the directory record names " <> found.owner <> state_words(found.state)
  }
}

fn state_words(state: record.OwnerState) -> String {
  case state {
    record.Serving -> " as serving"
    record.Moving(op:, to:) -> " as moving to " <> to <> " under " <> op
  }
}
