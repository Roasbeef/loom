//// The source's half of a session move (protocol-change/078, phase 5).
////
//// An owner hands a session to another orchestrator, and this module is the
//// driver that carries it there. The registry has already committed the intent,
//// `moving(op, to)`, and stopped the session's slot (`manager.begin_move`), so
//// nothing on this machine can open the conversation file. The mover takes the
//// remaining steps in order, each durable before the next:
////
//// 1. **Wait for the stop.** The slot drains through its ordinary cleanup, which
////    closes the session's scope on the executor and records how the close ended
////    in the file's own `client/remote/scope` cell.
//// 2. **Confirm the close.** The cell must read a clean close. A cell that never
////    recorded one, because the orchestrator died first, is settled by asking the
////    executor to close the scope now and writing what it answers into the file.
////    An unproven cleanup refuses the move.
//// 3. **Cut.** The closed file is copied coherently, under the lease owner
////    `move:<op>`, and the copy is hashed.
//// 4. **Send.** The copy goes to the receiver in pieces, each acknowledged.
//// 5. **Activate.** The receiver checks the digest and the cell, then commits its
////    catalogue row. That compare-and-set is the hand-over.
//// 6. **Retire.** The source's row becomes `moved(to)`, the lease is released and
////    the file is set aside as `<id>.db.moved`.
////
//// ## Every run starts from what is on disk
////
//// A mover is restarted by a daemon restart, by a crash of its own process and by
//// a step that could not finish. None of them leaves a memory of where it was, so
//// `drive` does not use one. Each run reads the source's row, asks the receiver
//// how far the move has got, and takes only the steps that remain. A receiver that
//// already activated the session sends the run straight to the last step. Every
//// step is safe to repeat: the cut reclaims its own lease and replaces its own
//// copy, a piece at offset zero begins the file afresh, and a repeated activation
//// answers the stored result. A fresh cut may differ from the copy the receiver
//// already holds, in which case the receiver refuses the digest once and the
//// whole file is sent again; that is the only recovery inside a file.
////
//// ## When a move may stop
////
//// There are three ends, and the difference between them is the point of the
//// protocol.
////
//// - **Finished.** The source's row is `moved`. There is no way back.
//// - **Aborted.** The move is abandoned and the session returns to `resident`.
////   This is allowed only on a definitive refusal: before anything was sent, a
////   close that proves the scope unusable, a file that is corrupt or too large;
////   after something was sent, only the receiver's own `Refused` verdict. An
////   unreachable receiver never aborts, because it may have activated the session
////   and lost the reply.
//// - **Stalled.** Something may pass: the receiver or the executor did not answer,
////   a lease has not expired, a step ran out of time. The row stays `moving`,
////   which is still exactly one owner, and the caller runs the mover again later.
////
//// Each step runs under a weft deadline of its own, so one that hangs cannot hold
//// the whole move, and its expiry is a stall and not a verdict.
////
//// ## Flow
////
//// `drive` → `run` → `migrated` → `intended` → `carried` → `retire`
////
//// 1. `drive` runs the move and turns how it halted into an `Outcome` through
////    `ended`; `give_up` does the same from an abandon.
//// 2. `run` reads the registration and the row (`still_moving`), waits on a
////    member for `migrated`, asks the receiver's `receiver_stage`, and writes
////    the record's intent with `intended`.
//// 3. `carried` takes the steps that remain: `stopped`, `closed`, `cut`,
////    `send` and `activate`.
//// 4. `retire` finishes the move: by the rows with `retire_by_rows`, or on a
////    member with `retire_recorded` after a consistent read.
//// 5. A move given up goes through `abandon`, which on a member is
////    `abandon_recorded` and otherwise `revert`.
////
//// ## On a directory member (protocol-change/079)
////
//// With `Recorded` authority the owner record decides and the catalogue row
//// remembers. The row is still written first, by the registry, in the turn
//// that stops the slot, because it stops this daemon serving the session. Then
//// the mover writes the record from `serving` to `moving`, and does nothing
//// that depends on the store until this daemon's migration marker exists, so a
//// record that is merely not seeded yet is never taken for a missing one. The
//// receiver's activation is the compare-and-set that hands the session over.
////
//// Three rules change. The move may be abandoned whatever the receiver did,
//// because the abandon is a compare-and-set that expects this daemon's
//// `moving` record and so fails once the receiver has activated; a failed
//// abandon sends the mover to the retirement instead. The retirement happens
//// only after the receiver answered and a consistent read of the record shows
//// another owner, so a stale copy never sets aside a file. And a stall that
//// giving the move up could not cure, because the store has no quorum or this
//// daemon has not seeded it yet, is reported as `Deferred`, so the movers do not
//// count it toward the time after which a silent receiver is given up. The
//// give-up passes the same seed check as a run before it touches the record,
//// since until the seed is done a missing record means "not copied yet".

import client/daemon/manager
import client/directory/ownership.{type Ownership}
import client/directory/record
import client/directory/store
import client/orchestrators.{type Orchestrator}
import client/remote/protocol
import client/remote/scope
import client/remote/workspace
import client/session_directory.{type Courier, type Directory}
import client/session_move.{type Step}
import core/clock.{type Clock}
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import simplifile
import storage/catalogue
import storage/sqlite
import telemetry/field
import telemetry/log.{type Logger}
import weft
import weft/poll

/// How long each step may run before it is given up as stalled, in
/// milliseconds. The steps that wait on another machine are the long ones.
pub type Budget {
  Budget(
    /// The slot's drain after the stop, which closes the scope on the executor.
    drain_ms: Int,
    /// A close the mover itself asks the executor for.
    close_ms: Int,
    /// The coherent copy and its hash.
    cut_ms: Int,
    /// Sending the whole file, piece by piece.
    send_ms: Int,
    /// The receiver's activation, which hashes and opens the whole copy.
    activate_ms: Int,
    /// A catalogue step or a short question.
    quick_ms: Int,
  )
}

/// The budgets a daemon runs with. The executor's close may take a minute and
/// the activation hashes and opens a file, so both are given more than that.
///
/// ## Examples
///
/// ```gleam
/// assert session_mover.default_budget().quick_ms == 15_000
/// ```
pub fn default_budget() -> Budget {
  Budget(
    drain_ms: 180_000,
    close_ms: 90_000,
    cut_ms: 120_000,
    send_ms: 600_000,
    activate_ms: 150_000,
    quick_ms: 15_000,
  )
}

/// How the mover asks an executor to close the scope of a session that has no
/// runtime: the executor's name, the session, the workspace and the incarnation.
pub type Closer =
  fn(String, String, String, Int) ->
    Result(protocol.CloseOutcome, workspace.CloseFailure)

/// A closer for a daemon that cannot reach executors: every close is
/// unanswered, so the move waits until a daemon that can does it.
///
/// ## Examples
///
/// ```gleam
/// assert session_mover.unreachable_executors()("box", "s", "repo", 1)
///   == Error(workspace.CloseUnanswered)
/// ```
pub fn unreachable_executors() -> Closer {
  fn(_executor, _session, _workspace, _incarnation) {
    Error(workspace.CloseUnanswered)
  }
}

/// What decides who owns a session while it moves.
pub type Authority {
  /// Phase 5: the source's and the receiver's catalogue rows.
  Rows

  /// A directory member: the owner record, written through this daemon's
  /// ownership; the rows only remember.
  Recorded(
    /// The record writes and reads, bound to this daemon's node.
    ownership: Ownership,
  )
}

/// What a mover needs from the daemon around it.
pub type Environment(instance) {
  Environment(
    /// Whether the rows or the directory record decide.
    authority: Authority,
    /// The registry, which owns the slot and the catalogue.
    registry: manager.Manager(instance),
    /// The orchestrators this daemon lists, in which the destination is found.
    orchestrators: List(Orchestrator),
    /// The directory, whose `activate` makes the receiver take the session.
    directory: Directory,
    /// The pieces and the status.
    courier: Courier,
    /// Closes a scope on an executor for a session with no runtime.
    close: Closer,
    /// The clock the file steps read.
    clock: Clock,
    /// This node's name, which the receiver matches to one of its own
    /// `[orchestrators.<name>]`.
    node: String,
    /// How long each step may take.
    budget: Budget,
    /// Told after each step is durable. A daemon passes a function that does
    /// nothing; the shipped crash test passes one that halts the VM
    /// (`LOOM_MOVE_CRASH_AFTER`), and an in-VM test passes one that records.
    after: fn(Step) -> Nil,
    /// Where the mover writes down what it did.
    logger: Logger,
  )
}

/// How one run of a mover ended.
pub type Outcome {
  /// The source's row is `moved`, or the move is no longer this mover's.
  Finished

  /// The move was abandoned and the session is `resident` again, with the
  /// reason the move cannot go on.
  Aborted(reason: String)

  /// The move is neither finished nor abandoned. The row stays `moving` and the
  /// run is retried later, with the reason it stopped.
  Stalled(reason: String)

  /// As `Stalled`, for a reason that giving the move up could not cure: the
  /// directory store could not commit or be read, or this daemon has not
  /// seeded it yet. The time a receiver has been silent is not counted while
  /// this lasts.
  Deferred(reason: String)
}

// Whether a send has already begun the file again. A receiver that loses its
// place is answered by starting the file over once, and a second loss in one send
// is not a race.
type Sending {
  FirstTry
  RestartedOnce
}

// Whether the whole file has already been sent again for a refused digest.
type Asking {
  FirstAsk
  AfterResend
}

// Why a step ended the run. A halt is the error side of every step, so the steps
// read as a chain and the run's outcome is decided in one place.
type Halt {
  // The move cannot go on and may be abandoned. A step produces this only when
  // the answer is final.
  Abandon(reason: String)

  // The move may go on later.
  Stall(reason: String)

  // The move may go on later, once something a give-up could not cure has
  // passed: the directory store has a quorum again, or this daemon has seeded
  // it.
  Defer(reason: String)

  // The session's record is gone after this daemon seeded the store. Every
  // remote session has a record once the seed ran, so its owner deleted it:
  // the receiver took the session while this source was away, and then
  // deleted it. The source's copy is set aside, never served again.
  Gone

  // The receiver answered and the record decides: retire if it names another
  // owner.
  Decide

  // The move is over, one way or the other, and there is nothing left to do.
  Over
}

// Why a move is being abandoned, which decides what an abandon that finds the
// receiver owning the session means.
type Cause {
  // Something answered no: the receiver refused, or the executor or the file
  // showed the move cannot go on. Every `Abandon` a run produces is this.
  Answered

  // Nobody answered: the movers gave up on a silent receiver, or the owner
  // asked (`give_up`).
  Unanswered
}

/// Runs the move as far as it can go and says how it ended. Safe to call again
/// after any outcome and after a crash anywhere inside it.
///
/// ## Examples
///
/// ```gleam
/// // session_mover.drive(environment, catalogue.Pending(session: id, op: op, to: "laptop"))
/// ```
pub fn drive(
  environment: Environment(instance),
  move: catalogue.Pending,
) -> Outcome {
  let outcome = ended(environment, move, run(environment, move))
  note(environment, move, outcome)
  outcome
}

/// Abandons the move now, at an operator's request or once the movers have
/// waited out a silent receiver. Only a directory member can: its abandon is a
/// compare-and-set that fails if the receiver has already activated, in which
/// case the move is retired instead. Under the rows authority an abandon after
/// the send could leave two owners, so it stalls with the reason.
///
/// ## Examples
///
/// ```gleam
/// // session_mover.give_up(environment, move)
/// ```
pub fn give_up(
  environment: Environment(instance),
  move: catalogue.Pending,
) -> Outcome {
  let outcome = case environment.authority {
    Rows ->
      Stalled(
        "a move can be abandoned on request only by a directory member; "
        <> "this daemon decides by its catalogue rows",
      )

    // The give-up reads the record, so it waits for the seed exactly as a run
    // does: before it, an abandon that finds no record would take the session
    // for one a later owner deleted and set its file aside.
    Recorded(..) ->
      case migrated(environment) {
        Error(halt) -> ended(environment, move, Error(halt))
        Ok(Nil) ->
          abandon(
            environment,
            move,
            "abandoned on request or after the receiver stayed silent",
            Unanswered,
          )
      }
  }
  note(environment, move, outcome)
  outcome
}

fn ended(
  environment: Environment(instance),
  move: catalogue.Pending,
  halted: Result(Nil, Halt),
) -> Outcome {
  case halted {
    Ok(Nil) -> Finished
    Error(Over) -> Finished
    Error(Abandon(reason:)) -> abandon(environment, move, reason, Answered)
    Error(Stall(reason:)) -> Stalled(reason)
    Error(Defer(reason:)) -> Deferred(reason)
    Error(Gone) -> gone(environment, move)
    Error(Decide) ->
      case environment.authority {
        Rows -> Stalled("only a directory member decides by the record")
        Recorded(ownership:) ->
          case retire_recorded(environment, ownership, move) {
            Ok(Nil) | Error(Over) -> Finished
            Error(Defer(reason:)) -> Deferred(reason)
            Error(Stall(reason:)) -> Stalled(reason)
            Error(Abandon(reason:)) -> Aborted(reason)
            Error(Gone) | Error(Decide) -> Stalled("the record did not decide")
          }
      }
  }
}

// The session's record is gone after the seed, so it was deleted elsewhere. A
// missing record never grants serving: the move ends as a retirement does,
// with the `moved` row and the file set aside under its tombstone name, which
// an operator can recover and nothing deletes.
fn gone(
  environment: Environment(instance),
  move: catalogue.Pending,
) -> Outcome {
  log.warn(environment.logger, "daemon.move_record_gone", [
    field.ident("session", move.session),
    field.ident("op", move.op),
    field.text(
      "reason",
      "the session's directory record is gone, so it was deleted elsewhere; "
        <> "this copy is set aside",
    ),
  ])
  case
    {
      use registration <- result.try(registered(environment, move))
      retire_by_rows(environment, move, registration)
    }
  {
    Ok(Nil) | Error(Over) -> Finished
    Error(Defer(reason:)) -> Deferred(reason)
    Error(Stall(reason:)) | Error(Abandon(reason:)) -> Stalled(reason)
    Error(Gone) | Error(Decide) -> Stalled("the record did not decide")
  }
}

fn run(
  environment: Environment(instance),
  move: catalogue.Pending,
) -> Result(Nil, Halt) {
  use registration <- result.try(registered(environment, move))
  use Nil <- result.try(still_moving(environment, move, registration))
  use Nil <- result.try(migrated(environment))
  environment.after(session_move.Intent)

  // A receiver that already activated the session needs nothing more from the
  // source than its own retirement. The question is asked first so a run that
  // restarts after the activation does not close, cut and send a session that
  // has already arrived.
  case receiver_stage(environment, move) {
    Ok(session_move.Activated) -> retire(environment, move, registration)
    Ok(session_move.Received) | Ok(session_move.Absent) | Error(Nil) -> {
      use Nil <- result.try(intended(environment, move))
      carried(environment, move, registration)
    }
  }
}

// On a member, nothing that reads the store runs before this daemon has seeded
// it from its catalogue: until then a missing record means "not copied yet",
// not "never existed".
fn migrated(environment: Environment(instance)) -> Result(Nil, Halt) {
  case environment.authority {
    Rows -> Ok(Nil)
    Recorded(ownership:) ->
      case ownership.migrated(ownership.node) {
        Ok(True) -> Ok(Nil)
        Ok(False) ->
          Error(Defer("this daemon has not seeded the directory store yet"))
        Error(store.Unavailable(reason:)) -> Error(Defer(reason))
      }
  }
}

// The record's half of the intent: `serving -> moving(op, to)`. A record that
// already names another owner means the receiver's activation committed and its
// import or its reply did not reach us, and the move carries on so that the
// receiver is asked again and answers from what it holds. No record at all, now
// that the seed has run (`run` checks it first), means the session was deleted
// elsewhere, and the move ends with the copy set aside (`gone`).
fn intended(
  environment: Environment(instance),
  move: catalogue.Pending,
) -> Result(Nil, Halt) {
  case environment.authority {
    Rows -> Ok(Nil)
    Recorded(ownership:) -> {
      use receiver <- result.try(destination(environment, move))
      case ownership.begin_move(move.session, move.op, receiver.node) {
        Ok(Nil) -> Ok(Nil)
        Error(store.Mismatch(found: None)) -> Error(Gone)
        Error(store.Mismatch(found: Some(found)))
          if found.owner != ownership.node
        -> Ok(Nil)
        Error(store.Mismatch(found: Some(_))) ->
          Error(Stall(
            "the directory record is in a state this move did not write",
          ))
        Error(store.NoQuorum(reason:)) -> Error(Defer(reason))
      }
    }
  }
}

// Steps one to five, then the last.
fn carried(
  environment: Environment(instance),
  move: catalogue.Pending,
  registration: catalogue.Registration,
) -> Result(Nil, Halt) {
  use Nil <- result.try(stopped(environment, move))
  use cell <- result.try(closed(environment, move, registration))
  environment.after(session_move.Close)
  use copy <- result.try(cut(environment, move, registration))
  environment.after(session_move.Cut)
  use stage <- result.try(send(environment, move, copy))
  environment.after(session_move.Send)
  case stage {
    // The question the send asked was answered by a receiver that has already
    // taken the session in. Asking it to activate again would only ask what it
    // has told us, and the stage is the observation the retirement needs.
    session_move.Activated -> retire(environment, move, registration)
    session_move.Received | session_move.Absent -> {
      use Nil <- result.try(activate(
        environment,
        move,
        registration,
        cell,
        copy,
      ))
      environment.after(session_move.Activate)
      retire(environment, move, registration)
    }
  }
}

// --- the row and the registration --------------------------------------------

fn registered(
  environment: Environment(instance),
  move: catalogue.Pending,
) -> Result(catalogue.Registration, Halt) {
  case manager.get(environment.registry, move.session) {
    Ok(view) -> Ok(view.registration)
    Error(error) ->
      Error(Stall("the registry could not read the session: " <> show(error)))
  }
}

// The row is the authority for whether this mover has anything to do. It is
// read every run, because a mover is started from a list taken at boot and an
// owner command can change the row afterwards.
fn still_moving(
  environment: Environment(instance),
  move: catalogue.Pending,
  registration: catalogue.Registration,
) -> Result(Nil, Halt) {
  case manager.custody(environment.registry, move.session) {
    Ok(catalogue.Moving(op:, ..)) if op == move.op -> Ok(Nil)

    // The row says the move finished. A crash between the row and the file work
    // leaves the work undone, and this is where it is finished.
    Ok(catalogue.Moved(op:, ..)) if op == move.op -> {
      set_aside(move, registration)
      Error(Over)
    }
    Ok(catalogue.Resident)
    | Ok(catalogue.Moving(..))
    | Ok(catalogue.Moved(..))
    | Ok(catalogue.Imported(..)) -> Error(Over)
    Error(error) ->
      Error(Stall("the registry could not read the row: " <> show(error)))
  }
}

fn destination(
  environment: Environment(instance),
  move: catalogue.Pending,
) -> Result(Orchestrator, Halt) {
  orchestrators.find(environment.orchestrators, move.to)
  |> result.map_error(fn(_unlisted) {
    Stall("this daemon does not list an orchestrator named " <> move.to)
  })
}

fn receiver_stage(
  environment: Environment(instance),
  move: catalogue.Pending,
) -> Result(session_move.Stage, Nil) {
  use receiver <- result.try(orchestrators.find(
    environment.orchestrators,
    move.to,
  ))
  environment.courier.stage(receiver, move.session, move.op)
}

// --- step 1: the stop ----------------------------------------------------------

// Waits for the slot to be gone. The registry stopped it in the turn that wrote
// the row, so on a restart there is nothing to wait for; the stop is asked for
// again whenever the slot is still up, which is idempotent.
fn stopped(
  environment: Environment(instance),
  move: catalogue.Pending,
) -> Result(Nil, Halt) {
  let budget = environment.budget
  bounded(budget.drain_ms, "the session's stop", fn() {
    let outcome =
      poll.until(within: budget.drain_ms - 1000, every: 50, attempt: fn() {
        case manager.get(environment.registry, move.session) {
          Ok(manager.View(status: manager.Saved, ..)) -> poll.Done(Nil)
          Ok(manager.View(status: manager.Reserved, ..)) ->
            poll.Fail(Abandon("the session has not finished being created"))
          Ok(manager.View(status: manager.RecoveryBlocked(reason:), ..)) ->
            poll.Fail(Stall("the session's cleanup is blocked: " <> reason))
          Ok(manager.View(status: manager.Stopping(..), ..)) -> poll.Retry
          Ok(manager.View(status: manager.Resident(..), ..))
          | Ok(manager.View(status: manager.Opening(..), ..)) -> {
            let _asked =
              manager.stop_session(environment.registry, move.session)
            poll.Retry
          }
          Error(error) ->
            poll.Fail(Stall(
              "the registry could not read the session: " <> show(error),
            ))
        }
      })
    case outcome {
      poll.Answered(Nil) -> Ok(Nil)
      poll.Failed(halt) -> Error(halt)
      poll.Expired -> Error(Stall("the session did not stop in time"))
    }
  })
}

// --- step 2: the close -------------------------------------------------------

// The scope cell that says how the last close ended, settled to a clean close
// or the end of the move. The file is opened here, so the lease an earlier run
// left under this move's own owner is released first; nothing else can have
// opened a session whose row says it is moving.
fn closed(
  environment: Environment(instance),
  move: catalogue.Pending,
  registration: catalogue.Registration,
) -> Result(scope.Scope, Halt) {
  let path = registration.path
  let _released =
    sqlite.release_export(path:, owner: session_move.lease_owner(move.op))
  let reader = session_move.reader_owner(move.op)
  use found <- result.try(
    bounded(environment.budget.quick_ms, "reading the scope cell", fn() {
      scope.read_at(path, reader, environment.clock)
      |> result.map_error(fn(reason) { Stall(reason) })
    }),
  )
  case found {
    None ->
      Error(Abandon(
        "the session never attached to an executor, so there is no scope to hand over",
      ))
    Some(cell) ->
      case cell.closed {
        Some(protocol.AllRetired) -> Ok(cell)
        Some(protocol.UnknownCleanup(count:)) ->
          Error(Abandon(
            "the executor could not prove the cleanup of the scope ("
            <> int.to_string(count)
            <> " children unaccounted for), so the session cannot move",
          ))
        None -> asked_to_close(environment, move, registration, cell)
      }
  }
}

// The last close was never recorded: the orchestrator died, or the executor did
// not answer, before the session's cleanup wrote it. The executor knows how the
// scope ended, and a repeated Close answers what it stored, so asking is how the
// file learns. What it answers is written into the file first, whichever way it
// ended, so a session whose move is then abandoned reopens at the right
// incarnation and is not refused as out of step.
fn asked_to_close(
  environment: Environment(instance),
  move: catalogue.Pending,
  registration: catalogue.Registration,
  cell: scope.Scope,
) -> Result(scope.Scope, Halt) {
  let executor = option.unwrap(cell.executor, registration.executor)
  use outcome <- result.try(
    bounded(environment.budget.close_ms, "the executor's close", fn() {
      case
        environment.close(
          executor,
          registration.id,
          registration.workspace,
          cell.incarnation,
        )
      {
        Ok(outcome) -> Ok(outcome)
        Error(workspace.CloseRefused(refusal:)) ->
          Error(Abandon(
            "the executor refused to close the scope: "
            <> protocol.describe(refusal),
          ))
        Error(workspace.CloseUnanswered) ->
          Error(Stall(
            "the executor " <> executor <> " did not answer the close",
          ))
      }
    }),
  )
  let settled = scope.Scope(..cell, closed: Some(outcome))
  use Nil <- result.try(
    bounded(environment.budget.quick_ms, "recording the close", fn() {
      scope.write_at(
        registration.path,
        session_move.reader_owner(move.op),
        environment.clock,
        settled,
      )
      |> result.map_error(fn(reason) { Stall(reason) })
    }),
  )
  case outcome {
    protocol.AllRetired -> Ok(settled)
    protocol.UnknownCleanup(count:) ->
      Error(Abandon(
        "the executor could not prove the cleanup of the scope ("
        <> int.to_string(count)
        <> " children unaccounted for), so the session cannot move",
      ))
  }
}

// --- step 3: the cut ---------------------------------------------------------

/// The copy a mover cut: where it is and its SHA-256.
type Copy {
  Copy(path: String, digest: String, bytes: BitArray)
}

fn cut(
  environment: Environment(instance),
  move: catalogue.Pending,
  registration: catalogue.Registration,
) -> Result(Copy, Halt) {
  let copy = session_move.copy_path(registration.path, move.op)
  bounded(environment.budget.cut_ms, "cutting the file", fn() {
    use digest <- result.try(
      sqlite.export_closed(
        path: registration.path,
        to: copy,
        owner: session_move.lease_owner(move.op),
        clock: environment.clock,
      )
      |> result.map_error(cut_halt),
    )
    use bytes <- result.try(
      simplifile.read_bits(copy)
      |> result.map_error(fn(error) {
        Stall(
          "the copy could not be read: " <> simplifile.describe_error(error),
        )
      }),
    )
    case bit_array.byte_size(bytes) > session_move.size_limit {
      True ->
        Error(Abandon(
          "the session file is larger than the "
          <> int.to_string(session_move.size_limit)
          <> " bytes a move carries",
        ))
      False -> Ok(Copy(path: copy, digest:, bytes:))
    }
  })
}

fn cut_halt(error: sqlite.RewriteError) -> Halt {
  case error {
    sqlite.RewriteLeaseHeld(owner:, ..) ->
      Stall("the session file is held by " <> owner)
    sqlite.RewriteCorrupt(..) ->
      Abandon(
        "the session file does not pass its own checks, so it is not sent",
      )
    sqlite.RewriteFailed(reason:) -> Stall("the cut failed: " <> reason)
  }
}

// --- step 4: the send --------------------------------------------------------

// Sends the whole copy unless the receiver already holds a complete one, which a
// run restarting after the send finds out by asking. A receiver that cannot be
// asked is a stall, since sending to it would find out the same thing slower.
// What it answers is returned: `Activated` means there is nothing left to send
// or to ask, and the caller goes straight to the retirement.
fn send(
  environment: Environment(instance),
  move: catalogue.Pending,
  copy: Copy,
) -> Result(session_move.Stage, Halt) {
  use receiver <- result.try(destination(environment, move))
  case environment.courier.stage(receiver, move.session, move.op) {
    Error(Nil) ->
      Error(Stall("the orchestrator " <> move.to <> " did not answer"))
    Ok(session_move.Activated) -> Ok(session_move.Activated)
    Ok(session_move.Received) -> Ok(session_move.Received)
    Ok(session_move.Absent) -> {
      use Nil <- result.try(send_all(environment, move, receiver, copy))
      Ok(session_move.Absent)
    }
  }
}

fn send_all(
  environment: Environment(instance),
  move: catalogue.Pending,
  receiver: Orchestrator,
  copy: Copy,
) -> Result(Nil, Halt) {
  bounded(environment.budget.send_ms, "sending the copy", fn() {
    pieces(environment, move, receiver, copy, 0, FirstTry)
  })
}

// One piece after another, each acknowledged. A receiver that lost its place
// says where it stands; the answer is to start the file again, once, because a
// second loss in one send is not a race.
fn pieces(
  environment: Environment(instance),
  move: catalogue.Pending,
  receiver: Orchestrator,
  copy: Copy,
  offset: Int,
  sending: Sending,
) -> Result(Nil, Halt) {
  let total = bit_array.byte_size(copy.bytes)
  let length = int.min(session_move.chunk_bytes, total - offset)
  case bit_array.slice(copy.bytes, offset, length) {
    Error(Nil) -> Error(Stall("the copy could not be cut into pieces"))
    Ok(bytes) -> {
      let piece =
        session_move.Chunk(
          session: move.session,
          op: move.op,
          offset:,
          total:,
          bytes:,
        )
      case environment.courier.send(receiver, piece) {
        Ok(session_move.Accepted) ->
          case offset + length >= total {
            True -> Ok(Nil)
            False ->
              pieces(
                environment,
                move,
                receiver,
                copy,
                offset + length,
                sending,
              )
          }
        Ok(session_move.Refused(session_move.OutOfOrder(..))) ->
          case sending {
            FirstTry ->
              pieces(environment, move, receiver, copy, 0, RestartedOnce)
            RestartedOnce ->
              Error(Stall("the receiver keeps losing its place in the copy"))
          }
        Ok(session_move.Refused(refusal:)) ->
          Error(Abandon(
            "the orchestrator "
            <> move.to
            <> " refused the copy: "
            <> session_move.describe(refusal),
          ))
        Ok(session_move.Failed(reason:)) ->
          Error(Stall(
            "the orchestrator " <> move.to <> " could not take it: " <> reason,
          ))
        Error(Nil) ->
          Error(Stall("the orchestrator " <> move.to <> " did not answer"))
      }
    }
  }
}

// --- step 5: the activation --------------------------------------------------

// The compare-and-set on the receiver's catalogue. A digest it refuses, or a
// copy it no longer has, means what it holds is not what was cut, and the cure is
// the whole file again; that is tried once. Every other refusal is the receiver's
// decision and ends the move.
fn activate(
  environment: Environment(instance),
  move: catalogue.Pending,
  registration: catalogue.Registration,
  cell: scope.Scope,
  copy: Copy,
) -> Result(Nil, Halt) {
  use receiver <- result.try(destination(environment, move))
  let request =
    session_move.Activation(
      session: move.session,
      op: move.op,
      from_node: environment.node,
      digest: copy.digest,
      incarnation: cell.incarnation,
      manifest: session_move.manifest_of(registration),
    )
  asked_to_activate(environment, move, receiver, copy, request, FirstAsk)
}

fn asked_to_activate(
  environment: Environment(instance),
  move: catalogue.Pending,
  receiver: Orchestrator,
  copy: Copy,
  request: session_move.Activation,
  asking: Asking,
) -> Result(Nil, Halt) {
  let answer =
    bounded(environment.budget.activate_ms, "the activation", fn() {
      case environment.directory.activate(receiver, request) {
        Ok(verdict) -> Ok(verdict)
        Error(Nil) ->
          Error(Stall("the orchestrator " <> move.to <> " did not answer"))
      }
    })
  case answer {
    Error(halt) -> Error(halt)
    Ok(session_move.Accepted) -> Ok(Nil)
    Ok(session_move.Failed(reason:)) ->
      Error(Stall(
        "the orchestrator " <> move.to <> " could not decide: " <> reason,
      ))
    Ok(session_move.Refused(session_move.MoveEnded)) ->
      case environment.authority {
        Recorded(..) -> Error(Decide)
        Rows ->
          Error(Abandon(
            "the orchestrator "
            <> move.to
            <> " refused the session: "
            <> session_move.describe(session_move.MoveEnded),
          ))
      }
    Ok(session_move.Refused(refusal:)) ->
      case refusal, asking {
        session_move.DigestMismatch, FirstAsk
        | session_move.NothingReceived, FirstAsk
        -> {
          use Nil <- result.try(send_all(environment, move, receiver, copy))
          asked_to_activate(
            environment,
            move,
            receiver,
            copy,
            request,
            AfterResend,
          )
        }
        _, _ ->
          Error(Abandon(
            "the orchestrator "
            <> move.to
            <> " refused the session: "
            <> session_move.describe(refusal),
          ))
      }
  }
}

// --- step 6: the retirement --------------------------------------------------

// The receiver owns the session, so the source's row says so: this is the
// compare-and-set that cannot be undone. The file work follows it, and a crash
// between them is finished by the next run, which finds the row `moved`.
fn retire(
  environment: Environment(instance),
  move: catalogue.Pending,
  registration: catalogue.Registration,
) -> Result(Nil, Halt) {
  case environment.authority {
    Recorded(..) -> Error(Decide)
    Rows -> retire_by_rows(environment, move, registration)
  }
}

// On a member the retirement reads the record after this member has caught up
// with the leader. Another owner, or no record at all now that this daemon has
// seeded the store (the later owner deleted it), means the session left: the
// row becomes `moved` and the file is set aside. This daemon still serving it
// means its own abandon committed before a crash, and the row is reverted
// without touching the file.
fn retire_recorded(
  environment: Environment(instance),
  ownership: Ownership,
  move: catalogue.Pending,
) -> Result(Nil, Halt) {
  use registration <- result.try(registered(environment, move))
  case ownership.read_consistent(move.session) {
    Error(store.Unavailable(reason:)) -> Error(Defer(reason))
    Ok(Some(found)) if found.owner == ownership.node ->
      case found.state {
        record.Serving -> {
          let _reverted = revert(environment, move, "the move was abandoned")
          Error(Over)
        }
        record.Moving(..) ->
          Error(Stall(
            "the receiver answered but the directory record still says moving",
          ))

        // A session on an executor never has a local record; one that does is
        // a fault for an operator, and nothing is changed on its strength.
        record.Local ->
          Error(Stall("the directory records this session as a local one"))
      }
    Ok(Some(_)) | Ok(None) -> retire_by_rows(environment, move, registration)
  }
}

fn retire_by_rows(
  environment: Environment(instance),
  move: catalogue.Pending,
  registration: catalogue.Registration,
) -> Result(Nil, Halt) {
  use Nil <- result.try(
    bounded(environment.budget.quick_ms, "recording the hand-over", fn() {
      case
        manager.finish_move(environment.registry, move.session, op: move.op)
      {
        Ok(_) -> Ok(Nil)
        Error(manager.Catalogue(catalogue.Conflict)) -> Error(Over)
        Error(error) ->
          Error(Stall(
            "the registry could not record the hand-over: " <> show(error),
          ))
      }
    }),
  )
  set_aside(move, registration)
  environment.after(session_move.Retire)
  Ok(Nil)
}

// The file work of a finished move, safe to repeat: the lease is released, the
// original is renamed, its sidecars and the copy are removed. Nothing here can
// fail the move, because the row already says it finished; a rename that does not
// happen leaves a file that no admission can open.
fn set_aside(
  move: catalogue.Pending,
  registration: catalogue.Registration,
) -> Nil {
  let path = registration.path
  let _released =
    sqlite.release_export(path:, owner: session_move.lease_owner(move.op))
  let _renamed = case simplifile.is_file(path) {
    Ok(True) -> simplifile.rename(at: path, to: session_move.moved_path(path))
    Ok(False) | Error(_) -> Ok(Nil)
  }
  remove_copy(move, registration)
}

fn remove_copy(
  move: catalogue.Pending,
  registration: catalogue.Registration,
) -> Nil {
  let path = registration.path
  let copy = session_move.copy_path(path, move.op)
  list.each(
    [
      copy,
      copy <> "-journal",
      copy <> "-wal",
      copy <> "-shm",
      path <> "-wal",
      path <> "-shm",
    ],
    fn(leftover) {
      let _removed = simplifile.delete_file(leftover)
      Nil
    },
  )
}

// --- giving the move up ------------------------------------------------------

// The move is abandoned: the lease is released first, so the session can be
// opened the moment the row says it may, and then the row goes back to
// resident. If the receiver may hold a copy it does not matter, since it
// refused or never saw an activation.
fn abandon(
  environment: Environment(instance),
  move: catalogue.Pending,
  reason: String,
  cause: Cause,
) -> Outcome {
  case environment.authority {
    Rows -> revert(environment, move, reason)
    Recorded(ownership:) ->
      abandon_recorded(environment, ownership, move, reason, cause)
  }
}

// On a member the abandon is the record's compare-and-set first, because
// reverting the row lets this daemon serve the session again and that must
// follow a committed write. The receiver's activation expects the same moving
// record, so exactly one of the two commits; one that finds the receiver
// already owning the session retires instead, but only on an answer: see
// `taken_elsewhere`.
fn abandon_recorded(
  environment: Environment(instance),
  ownership: Ownership,
  move: catalogue.Pending,
  reason: String,
  cause: Cause,
) -> Outcome {
  case destination(environment, move) {
    Error(Stall(reason:)) -> Stalled(reason)
    Error(_) -> Stalled("the destination is not configured")
    Ok(receiver) ->
      case ownership.abandon(move.session, move.op, receiver.node) {
        Ok(Nil) -> revert(environment, move, reason)
        Error(store.Mismatch(found: Some(found)))
          if found.owner == ownership.node
        ->
          case found.state {
            record.Serving -> revert(environment, move, reason)
            record.Moving(..) ->
              Stalled("the directory record names another move of this session")
            record.Local ->
              Stalled("the directory records this session as a local one")
          }
        Error(store.Mismatch(found: Some(found))) ->
          taken_elsewhere(environment, move, cause, found.owner)
        Error(store.Mismatch(found: None)) ->
          ended(environment, move, Error(Decide))
        Error(store.NoQuorum(reason:)) -> Deferred(reason)
      }
  }
}

// An abandon that finds the record naming another owner means the receiver's
// activation committed first. After an answer (a refusal, or a close the
// executor refused because the receiver holds the scope), the receiver has
// spoken and the record decides. After silence it has not: its compare-and-set
// may have committed with its import lost to a crash, and only the source's
// next activation makes it finish the import, so retiring now would leave the
// record naming a daemon that never registered the session. The run asks the
// receiver again instead, and retires on its answer; the wait is not counted
// toward the give-up, which could not take the session back anyway.
fn taken_elsewhere(
  environment: Environment(instance),
  move: catalogue.Pending,
  cause: Cause,
  owner: String,
) -> Outcome {
  case cause {
    Answered -> ended(environment, move, Error(Decide))
    Unanswered ->
      Deferred(
        "the directory record names "
        <> owner
        <> ", so its activation committed; the receiver is asked again",
      )
  }
}

// Reverts the row and drops the cut copy: the move is over and the session is
// this daemon's again.
fn revert(
  environment: Environment(instance),
  move: catalogue.Pending,
  reason: String,
) -> Outcome {
  case manager.get(environment.registry, move.session) {
    Error(error) ->
      Stalled(
        "the move cannot be abandoned until the registry answers: "
        <> show(error),
      )
    Ok(view) -> {
      let registration = view.registration
      let _released =
        sqlite.release_export(
          path: registration.path,
          owner: session_move.lease_owner(move.op),
        )
      case manager.abort_move(environment.registry, move.session, op: move.op) {
        Ok(_) | Error(manager.Catalogue(catalogue.Conflict)) -> {
          remove_copy(move, registration)
          Aborted(reason)
        }
        Error(error) ->
          Stalled(
            "the move cannot be abandoned until the registry answers: "
            <> show(error),
          )
      }
    }
  }
}

// --- deadlines and records ---------------------------------------------------

// Runs a step in a weft run that is cut off at `budget_ms`, so one that hangs
// cannot hold the whole move. The step's own halt is the run's error, and
// anything else that ends the run, the deadline included, is a stall: the step
// told the mover nothing, and treating that as a verdict would let a fault
// abandon a move.
fn bounded(
  budget_ms: Int,
  step: String,
  work: fn() -> Result(a, Halt),
) -> Result(a, Halt) {
  let outcomes =
    weft.new([work])
    |> weft.deadline(budget_ms)
    |> weft.start
  case outcomes {
    [weft.Completed(value:, ..)] -> Ok(value)
    [weft.Failed(error:, ..)] -> Error(error)
    [weft.Crashed(..)] -> Error(Stall(step <> " crashed"))
    [weft.Abandoned(..)] ->
      Error(Stall(
        step <> " did not finish in " <> int.to_string(budget_ms) <> " ms",
      ))
    [weft.NeverStarted(..)]
    | [weft.DrainProofLost(..)]
    | [weft.CancellationUnconfirmed(..)]
    | []
    | [_, _, ..] -> Error(Stall(step <> " could not be run"))
  }
}

fn show(error: manager.Error) -> String {
  string.inspect(error)
}

fn note(
  environment: Environment(instance),
  move: catalogue.Pending,
  outcome: Outcome,
) -> Nil {
  let fields = [
    field.ident("session", move.session),
    field.ident("op", move.op),
    field.text("to", move.to),
  ]
  case outcome {
    Finished -> log.info(environment.logger, "daemon.move_finished", fields)
    Aborted(reason:) ->
      log.warn(environment.logger, "daemon.move_aborted", [
        field.text("reason", reason),
        ..fields
      ])
    Stalled(reason:) | Deferred(reason:) ->
      log.warn(environment.logger, "daemon.move_stalled", [
        field.text("reason", reason),
        ..fields
      ])
  }
}
