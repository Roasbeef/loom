//// What a session owes the other orchestrators that run its subagents, and the
//// pass that attempts it (protocol-change/084, slice S3).
////
//// A parent session writes two kinds of record before it sends a message to
//// another orchestrator (`client/remote_child`): a stub for each spawn it has
//// asked for, and a row for each run end it owes. The orchestrator can be
//// unreachable, and the parent can crash between a record and the message it
//// implies, so something has to keep attempting what is recorded. That is a
//// second instance of the outbox drainer (`client/peer_outbox_drain`), given
//// this pass instead of peer mail's.
////
//// ## What an attempt is
////
//// Both messages are idempotent on the receiver, which is the whole reason the
//// pass needs no receipt of its own. A resent `Spawn` carries the call site the
//// child's name was derived from, and the receiver adopts the child that call
//// site already made, so the answer to the second attempt is the answer to the
//// first. A repeated `RunEnded` stops nothing more. So a row is attempted at
//// each pass until the orchestrator answers, and any answer settles it:
//// `Refused` is definitive, and `Unreachable` leaves the row where it was.
////
//// A row has no time to live. Peer mail's rows are refused after an hour because
//// a message nobody can deliver stops being worth sending, but a child is
//// bounded by its own deadline on the other orchestrator and a stub is a fact
//// about it, so the pass keeps asking for as long as the parent session exists.
//// An orchestrator that is gone for good costs one failed connect per pass.
////
//// ## Flow
////
//// `pass` → `spawn_pass` → `attempt_spawn` → `run_end_pass` → `tell_unless_silent`
////
//// 1. `pass` reads the records through the session's runtime, which it fetches
////    afresh each time because the drainer outlives a restart of the runtime.
//// 2. `spawn_pass` walks the stubs that are `Requested`, and `attempt_spawn`
////    sends one and records the answer.
//// 3. `run_end_pass` walks the run-end rows that are `Pending`, and
////    `tell_unless_silent` sends one through `remote_child.tell`, which marks it
////    told on any answer.
//// 4. An orchestrator that did not answer is not asked again in the same pass,
////    the way the peer-mail pass skips a silent session: every row owed to it
////    would wait out the same deadline to learn the same thing.

import client/peer_mail
import client/peer_outbox_drain.{type Backlog, Clear, Owed, Quick}
import client/remote_child.{type Ended, type Kept}
import client/remote_reach.{type Reach}
import core/clock.{type Clock}
import gleam/list
import runtime/api
import telemetry/field
import telemetry/log.{type Logger}

// What a pass owes while any spawn is unanswered or any child is running. The
// drainer's pace for it is the fixed interval, whatever kept the pass from
// finishing: the orchestrator that did not answer may be back by the next
// tick, and a running child ends at no moment this side can predict.
const owed = Owed(Quick)

/// The pass of the second drainer instance: attempts every spawn that is owed
/// and every run end that is owed, and says whether anything still is.
///
/// `runtime` is asked at each pass, and a session whose runtime is not up yet
/// has nothing to read and reports `Owed`, so the drainer tries again at its
/// next tick.
///
/// ## Examples
///
/// ```gleam
/// // peer_outbox_drain.over(remote_drain.pass(agency.runtime_supplier(config), reach, clock, logger), after)
/// ```
pub fn pass(
  runtime: fn() -> Result(api.Runtime, Nil),
  reach: Reach,
  time: Clock,
  logger: Logger,
) -> fn() -> Backlog {
  fn() {
    case runtime() {
      Error(Nil) -> owed
      Ok(open) -> {
        let #(spawns, silent) = spawn_pass(open, reach, time, logger)
        let ends = run_end_pass(open, reach, logger, silent)
        case spawns, ends {
          Clear, Clear -> Clear
          Owed(_), _ | _, Owed(_) -> owed
        }
      }
    }
  }
}

// Attempts each stub that is `Requested`, and answers what is still owed with
// the orchestrators that did not answer. A stub list that cannot be read is
// `Owed`: the stubs may exist, and the next pass reads again.
fn spawn_pass(
  runtime: api.Runtime,
  reach: Reach,
  time: Clock,
  logger: Logger,
) -> #(Backlog, List(String)) {
  case remote_child.all(runtime) {
    Error(reason) -> {
      log.warn(logger, "remote_drain.unreadable", [field.text("reason", reason)])
      #(owed, [])
    }
    Ok(kept) ->
      kept
      |> list.filter(fn(entry) { entry.stub.state == remote_child.Requested })
      |> list.fold(#(Clear, []), fn(so_far, entry) {
        attempt_spawn(runtime, reach, time, logger, entry, so_far)
      })
  }
}

// One stub. An answer is recorded and finishes the stub; silence leaves it
// pending and marks the orchestrator silent for the rest of the pass; a store
// that would not take the record leaves the stub pending too, since the answer
// is not lost, only unrecorded, and asking again returns it.
fn attempt_spawn(
  runtime: api.Runtime,
  reach: Reach,
  time: Clock,
  logger: Logger,
  entry: Kept,
  so_far: #(Backlog, List(String)),
) -> #(Backlog, List(String)) {
  let silent = so_far.1
  let stub = entry.stub
  case list.contains(silent, stub.orchestrator) {
    True -> #(owed, silent)
    False ->
      case
        reach.spawn(
          stub.orchestrator,
          remote_child.parent_of(stub, reach.session),
          stub.site,
          stub.depth,
          stub.parent_tools,
          stub.request,
        )
      {
        Ok(answer) -> {
          let #(now, _clock) = clock.read(time)
          recorded(
            remote_child.spawned(runtime, entry.key, stub, answer, now),
            logger,
            "remote_drain.spawned",
            entry,
            so_far,
          )
        }
        Error(peer_mail.Refused(reason)) ->
          recorded(
            remote_child.refused(runtime, entry.key, reason),
            logger,
            "remote_drain.refused",
            entry,
            so_far,
          )
        Error(peer_mail.Unreachable) | Error(peer_mail.NotOpen) -> #(owed, [
          stub.orchestrator,
          ..silent
        ])
      }
  }
}

// What the pass owes after the answer to one stub was recorded, or was not.
fn recorded(
  stored: Result(remote_child.Stub, String),
  logger: Logger,
  event: String,
  entry: Kept,
  so_far: #(Backlog, List(String)),
) -> #(Backlog, List(String)) {
  case stored {
    Ok(_) -> {
      log.info(logger, event, where(entry))
      so_far
    }
    Error(reason) -> {
      log.warn(logger, "remote_drain.unrecorded", [
        field.text("reason", reason),
        ..where(entry)
      ])
      #(owed, so_far.1)
    }
  }
}

// Tells each orchestrator whose run end is pending, skipping those that already
// failed to answer this pass.
fn run_end_pass(
  runtime: api.Runtime,
  reach: Reach,
  logger: Logger,
  silent: List(String),
) -> Backlog {
  case remote_child.owed_run_ends(runtime) {
    Error(reason) -> {
      log.warn(logger, "remote_drain.unreadable", [field.text("reason", reason)])
      owed
    }
    Ok(rows) -> {
      let #(backlog, _silent) =
        list.fold(rows, #(Clear, silent), fn(so_far, row) {
          tell_unless_silent(runtime, reach, row, so_far)
        })
      backlog
    }
  }
}

// One row, unless its orchestrator already failed to answer in this pass.
fn tell_unless_silent(
  runtime: api.Runtime,
  reach: Reach,
  row: Ended,
  so_far: #(Backlog, List(String)),
) -> #(Backlog, List(String)) {
  let #(backlog, silent) = so_far
  case list.contains(silent, row.orchestrator) {
    True -> #(owed, silent)
    False ->
      case remote_child.tell(runtime, reach, row) {
        remote_child.Answered -> #(backlog, silent)
        remote_child.Silent -> #(owed, [row.orchestrator, ..silent])
      }
  }
}

fn where(entry: Kept) -> List(field.Field) {
  [
    field.text("orchestrator", entry.stub.orchestrator),
    field.text("stub", entry.key),
  ]
}
