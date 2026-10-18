//// What a session owes the other orchestrators that run its subagents, and the
//// pass that attempts it (protocol-change/084, slice S3).
////
//// A parent session writes a stub before it sends a `Spawn` to another
//// orchestrator (`client/remote_child`). The orchestrator can be unreachable, and
//// the parent can crash between the stub and the message it implies, so something
//// has to keep attempting what is recorded. That is a second instance of the
//// outbox drainer (`client/peer_outbox_drain`), given this pass instead of peer
//// mail's. The pass owes three things, and it casts one vote.
////
//// ## A spawn that has not been answered
////
//// A `Spawn` is idempotent on the receiver, which is the whole reason the pass
//// needs no receipt of its own. A resent `Spawn` carries the call site the
//// child's name was derived from, and the receiver adopts the child that call
//// site already made, so the answer to the second attempt is the answer to the
//// first. So a `Requested` stub is attempted at each pass until the orchestrator
//// answers, and any answer settles it: `Refused` is definitive, and `Unreachable`
//// leaves the stub where it was.
////
//// A stub has no time to live. Peer mail's rows are refused after an hour because
//// a message nobody can deliver stops being worth sending, but a child is
//// bounded by its own deadline on the other orchestrator and a stub is a fact
//// about it, so the pass keeps asking for as long as the parent session exists.
//// An orchestrator that is gone for good costs one failed connect per pass.
////
//// ## A child that finishes without being waited on
////
//// A remote child is detached, so it runs on after the parent's turn, and a
//// parent that never calls `agent_wait` on it would otherwise never learn that it
//// finished. A `Spawned` stub holds a slot of the parent's fan-out caps, so
//// children nobody waits on would fill the caps for good. Two things release the
//// slot. The child's deadline does, with no message at all (`remote_child.is_live`
//// reads the time), and that is the bound. The drainer does it sooner for a
//// child that finishes early: it sends each orchestrator one `Join` per parent
//// strand with a window of zero, which the receiver answers as a read of where
//// each child stands, and records every `Ready` on the stub as `Settled`.
////
//// The report itself is not kept. The stub records that the child finished, how
//// it ended and what it cost, and a later `agent_wait` reads the full report from
//// the orchestrator again, so the drainer is not a second place where results
//// live.
////
//// While any child is running the pass reports `Owed`, so the drainer ticks at
//// its fixed interval, and when none is it reports `Clear` and the drainer goes
//// idle with no timer. A child past its deadline is not asked about: its slot is
//// already free by the clock, and an orchestrator that is down would otherwise
//// keep the drainer ticking for a child that cannot be running.
////
//// ## A message that has not been answered
////
//// A model's `agent_send` to a remote child is attempted at once, and an
//// orchestrator that did not answer leaves a row (`client/remote_send`). The
//// third step resends each row, and an answer of any kind removes it: the
//// orchestrator stores a receipt under the message id, so a resend after a lost
//// reply delivers nothing twice.
////
//// ## The vote
////
//// An orchestrator sends mail and progress of its own, and it can only do so
//// over a connection the laptop made. At each pass the drainer tells the link
//// keeper (`client/remote/link_keeper`) which orchestrators this session has a
//// stub for that is `Requested` or running, and which it has none for. The vote
//// is cast every pass, so a daemon that restarted has its votes again within one
//// pass, and a vote for an orchestrator with no keeper is dropped.
////
//// ## Flow
////
//// `pass` → `vote` → `spawn_pass` → `attempt_spawn` → `join_pass` →
//// `join_group` → `send_pass` → `attempt_send`
////
//// 1. `pass` reads the stubs once through the session's runtime, which it
////    fetches afresh each time because the drainer outlives a restart of the
////    runtime, and hands the same list to every step. `vote` comes first and
////    needs no network.
//// 2. `spawn_pass` walks the stubs that are `Requested`, and `attempt_spawn`
////    sends one and records the answer. A child it starts is owed a look, so the
////    pass reports `Owed` and the next one asks after it.
//// 3. `join_pass` groups the stubs whose child is running by orchestrator and
////    parent strand, and `join_group` asks one zero-window `Join` for each group
////    and settles the children it reports finished.
//// 4. An orchestrator that did not answer is not asked again in the same pass,
////    the way the peer-mail pass skips a silent session: every record owed to it
////    would wait out the same deadline to learn the same thing. The silent
////    orchestrators pass from the spawn step to the join step and on to the send
////    step, so a down orchestrator costs one connect timeout per pass, not
////    three.
//// 5. `send_pass` walks the rows of sends owed, and `attempt_send` resends one
////    and removes the row when the orchestrator answers.

import client/peer_mail
import client/peer_outbox_drain.{type Backlog, Clear, Owed, Quick}
import client/remote_child.{type Kept}
import client/remote_reach.{type Reach}
import client/remote_send
import client/remote_spawn.{type ChildUsage, type Joined}
import core/clock.{type Clock}
import gleam/dict
import gleam/list
import runtime/api
import telemetry/field
import telemetry/log.{type Logger}
import tools/agent.{type Handle, type Outcome}

// What a pass owes while any spawn is unanswered or any child is running. The
// drainer's pace for it is the fixed interval, whatever kept the pass from
// finishing: the orchestrator that did not answer may be back by the next
// tick, and a running child ends at no moment this side can predict.
const owed = Owed(Quick)

/// The pass of the second drainer instance: votes which orchestrators this
/// session needs a connection to, attempts every spawn that is owed, asks after
/// every child that is running, resends every send that was not answered, and
/// says whether anything still is.
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
      Ok(open) ->
        case remote_child.all(open) {
          Error(reason) -> {
            log.warn(logger, "remote_drain.unreadable", [
              field.text("reason", reason),
            ])
            owed
          }
          Ok(kept) -> {
            vote(reach, kept, time)
            let #(spawns, silent) = spawn_pass(open, reach, time, logger, kept)
            let #(running, silent) =
              join_pass(open, reach, time, logger, kept, silent)
            let #(sends, _silent) = send_pass(open, reach, logger, silent)
            owed_if_either(owed_if_either(spawns, running), sends)
          }
        }
    }
  }
}

fn owed_if_either(first: Backlog, second: Backlog) -> Backlog {
  case first, second {
    Clear, Clear -> Clear
    Owed(_), _ | _, Owed(_) -> owed
  }
}

// --- the vote ------------------------------------------------------------------

// Tells the link keeper, for each orchestrator the session knows, whether a stub
// needs the connection kept up: `Requested`, or `Spawned` with the child's
// deadline not yet passed. A `Settled` or `Refused` stub, or one past its
// deadline, sends the box nothing more to say. An orchestrator that a stub names
// and the roster no longer lists is voted for as well, so a vote is never
// withheld from a child that may still be running.
fn vote(reach: Reach, kept: List(Kept), time: Clock) -> Nil {
  let #(now, _clock) = clock.read(time)
  let holding =
    kept
    |> list.filter(fn(entry) { remote_child.needs_link(entry.stub, now) })
    |> list.map(fn(entry) { entry.stub.orchestrator })
    |> list.unique
  list.append(reach.orchestrators, holding)
  |> list.unique
  |> list.each(fn(name) {
    case list.contains(holding, name) {
      True -> reach.keep(name, remote_reach.Hold)
      False -> reach.keep(name, remote_reach.Drop)
    }
  })
}

// --- spawns that have not been answered --------------------------------------

// Attempts each stub that is `Requested`, and returns what it owes together with
// the orchestrators that did not answer, which the join step skips as well. The
// stub list was read once by `pass`, which owes `Owed` when it cannot be read:
// the stubs may exist, and the next pass reads again.
fn spawn_pass(
  runtime: api.Runtime,
  reach: Reach,
  time: Clock,
  logger: Logger,
  kept: List(Kept),
) -> #(Backlog, List(String)) {
  kept
  |> list.filter(fn(entry) { entry.stub.state == remote_child.Requested })
  |> list.fold(#(Clear, []), fn(so_far, entry) {
    attempt_spawn(runtime, reach, time, logger, entry, so_far)
  })
}

// One stub. A child that answered is recorded as running, and a running child is
// owed a look, so the pass is `Owed` whether or not the store took the record.
// A refusal is recorded and finishes the stub. Silence leaves the stub pending
// and marks the orchestrator silent for the rest of the pass. A store that would
// not take the record leaves the stub pending too, since the answer is not lost,
// only unrecorded, and asking again returns it.
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
          remote_reach.spawn_ms,
        )
      {
        Ok(answer) -> {
          let #(now, _clock) = clock.read(time)
          let backlog =
            recorded(
              remote_child.spawned(runtime, entry.key, stub, answer, now),
              logger,
              "remote_drain.spawned",
              entry,
              owed,
            )
          #(backlog, silent)
        }
        Error(peer_mail.Refused(reason)) -> {
          let backlog =
            recorded(
              remote_child.refused(runtime, entry.key, reason),
              logger,
              "remote_drain.refused",
              entry,
              so_far.0,
            )
          #(backlog, silent)
        }
        Error(peer_mail.Unreachable) | Error(peer_mail.NotOpen) -> #(owed, [
          stub.orchestrator,
          ..silent
        ])
      }
  }
}

// What the pass owes after one write to a stub: `if_written` when the store took
// it, and `Owed` when it did not, since the report the write carried is not lost
// and asking again returns it.
fn recorded(
  stored: Result(remote_child.Stub, String),
  logger: Logger,
  event: String,
  entry: Kept,
  if_written: Backlog,
) -> Backlog {
  case stored {
    Ok(_) -> {
      log.info(logger, event, where(entry))
      if_written
    }
    Error(reason) -> {
      log.warn(logger, "remote_drain.unrecorded", [
        field.text("reason", reason),
        ..where(entry)
      ])
      owed
    }
  }
}

// --- children that are running ------------------------------------------------

// Asks after every child whose stub says it is running, and settles the ones
// that finished. It answers the orchestrators that did not answer as well, for
// the step that follows. The stubs are the pass's one read, so a child the spawn step
// started in this pass is not among them: that step reported `Owed`, and the
// next pass asks after it. The orchestrators the spawn step found silent are not
// asked again. A pass that leaves any child running is `Owed`, which is what
// keeps the drainer ticking while a child runs and stops it when none does.
fn join_pass(
  runtime: api.Runtime,
  reach: Reach,
  time: Clock,
  logger: Logger,
  kept: List(Kept),
  silent: List(String),
) -> #(Backlog, List(String)) {
  let #(now, _clock) = clock.read(time)
  kept
  |> list.filter_map(fn(entry) { running(entry, now) })
  |> by_parent
  |> list.fold(#(Clear, silent), fn(so_far, group) {
    join_group(runtime, reach, logger, group, so_far)
  })
}

// The stub with its child's handle, when the stub is `Spawned` and the child's
// deadline has not passed. A `Requested` stub is the spawn step's, and a child
// past its deadline needs no asking: its slot is free by the clock and
// `agent_wait` reads its outcome.
fn running(entry: Kept, now: Int) -> Result(#(Kept, Handle), Nil) {
  case entry.stub.state {
    remote_child.Spawned(placed:) ->
      case remote_child.is_live(entry.stub, now) {
        True -> Ok(#(entry, placed.handle))
        False -> Error(Nil)
      }

    // A child that finished and whose orchestrator still holds mail it sent is
    // asked about again, to learn when the mail has been delivered.
    remote_child.Settled(placed:, ..) ->
      case remote_child.owes_mail(entry.stub, now) {
        True -> Ok(#(entry, placed.handle))
        False -> Error(Nil)
      }
    remote_child.Requested | remote_child.Refused(..) -> Error(Nil)
  }
}

// The running children grouped by the orchestrator they run on and the parent
// strand that asked, because a `Join` names one parent and the receiver judges
// the handles against it.
fn by_parent(
  children: List(#(Kept, Handle)),
) -> List(#(#(String, String), List(#(Kept, Handle)))) {
  children
  |> list.group(fn(child) { #(child.0.stub.orchestrator, child.0.stub.strand) })
  |> dict.to_list
}

// One zero-window `Join` for the running children of one parent on one
// orchestrator. Silence marks the orchestrator silent for the rest of the pass
// and leaves its children owed. A refusal is definitive: the orchestrator will
// not report these children, and their deadlines release the slots, so it is
// logged and not retried within the pass.
fn join_group(
  runtime: api.Runtime,
  reach: Reach,
  logger: Logger,
  group: #(#(String, String), List(#(Kept, Handle))),
  so_far: #(Backlog, List(String)),
) -> #(Backlog, List(String)) {
  let #(#(orchestrator, strand), children) = group
  let #(backlog, silent) = so_far
  case list.contains(silent, orchestrator) {
    True -> #(owed, silent)
    False ->
      case
        reach.join(
          orchestrator,
          remote_reach.parent(reach, strand),
          list.map(children, fn(child) { child.1 }),
          0,
        )
      {
        Ok(joined) -> #(
          owed_if_either(backlog, settle_all(runtime, logger, joined, children)),
          silent,
        )
        Error(peer_mail.Refused(reason)) -> {
          log.info(logger, "remote_drain.join_refused", [
            field.text("orchestrator", orchestrator),
            field.text("reason", reason),
          ])
          so_far
        }
        Error(peer_mail.Unreachable) | Error(peer_mail.NotOpen) -> #(owed, [
          orchestrator,
          ..silent
        ])
      }
  }
}

// Settles each child the join reported finished, and answers `Owed` if any
// child of the group is still running afterwards, whether the orchestrator
// reported it pending, said nothing of it, or the settling could not be
// recorded. The step is a compare-and-set, so a wait that settled the same child
// first leaves this write agreeing with it.
fn settle_all(
  runtime: api.Runtime,
  logger: Logger,
  joined: List(Joined),
  children: List(#(Kept, Handle)),
) -> Backlog {
  list.fold(children, Clear, fn(backlog, child) {
    let #(entry, handle) = child
    case finished(joined, handle) {
      // A finished child whose orchestrator still holds mail it sent keeps the
      // pass owed, so the next pass asks again and the connection stays up.
      Ok(#(outcome, usage, undelivered)) ->
        owed_if_either(
          backlog,
          recorded(
            remote_child.settled(
              runtime,
              entry.key,
              outcome,
              usage,
              undelivered,
            ),
            logger,
            "remote_drain.settled",
            entry,
            case undelivered > 0 {
              True -> owed
              False -> Clear
            },
          ),
        )
      Error(Nil) -> owed
    }
  })
}

// The outcome, the cost and the count of undelivered messages a join reports for
// one handle, when it reports that child finished.
fn finished(
  joined: List(Joined),
  handle: Handle,
) -> Result(#(Outcome, ChildUsage, Int), Nil) {
  list.find_map(joined, fn(entry) {
    case entry {
      remote_spawn.Ready(handle: found, outcome:, usage:, owed:, ..)
        if found == handle
      -> Ok(#(outcome, usage, owed))
      remote_spawn.Ready(..) | remote_spawn.Pending(..) -> Error(Nil)
    }
  })
}

// --- sends that have not been answered ---------------------------------------

// Resends each row of a send the orchestrator did not answer, and removes the
// rows it answered. The orchestrators the earlier steps found silent are not
// asked again, and one that goes silent here is passed on. A row that cannot be
// read leaves the pass owed: the rows may exist, and the next pass reads again.
fn send_pass(
  runtime: api.Runtime,
  reach: Reach,
  logger: Logger,
  silent: List(String),
) -> #(Backlog, List(String)) {
  case remote_send.all(runtime) {
    Error(reason) -> {
      log.warn(logger, "remote_drain.sends_unreadable", [
        field.text("reason", reason),
      ])
      #(owed, silent)
    }
    Ok(rows) ->
      list.fold(rows, #(Clear, silent), fn(so_far, row) {
        attempt_send(runtime, reach, logger, row, so_far)
      })
  }
}

// One row. Any answer removes it: a landing says the child has the message, a
// repeat says an earlier attempt delivered it, and a refusal says the
// orchestrator will not deliver it, which is definitive. Silence leaves the row
// and marks the orchestrator silent for the rest of the pass. A row that cannot
// be removed stays, and the next pass sends again and is answered from the
// receipt.
fn attempt_send(
  runtime: api.Runtime,
  reach: Reach,
  logger: Logger,
  row: remote_send.Row,
  so_far: #(Backlog, List(String)),
) -> #(Backlog, List(String)) {
  let #(backlog, silent) = so_far
  case list.contains(silent, row.orchestrator) {
    True -> #(owed, silent)
    False ->
      case
        reach.send(
          row.orchestrator,
          remote_reach.parent(reach, row.parent_strand),
          row.child,
          row.id,
          row.text,
        )
      {
        Ok(_landing) -> #(settled_send(runtime, logger, row, backlog), silent)
        Error(peer_mail.Refused(reason)) -> {
          log.info(logger, "remote_drain.send_refused", [
            field.text("reason", reason),
            field.text("orchestrator", row.orchestrator),
          ])
          #(settled_send(runtime, logger, row, backlog), silent)
        }
        Error(peer_mail.Unreachable) | Error(peer_mail.NotOpen) -> #(owed, [
          row.orchestrator,
          ..silent
        ])
      }
  }
}

fn settled_send(
  runtime: api.Runtime,
  logger: Logger,
  row: remote_send.Row,
  backlog: Backlog,
) -> Backlog {
  case remote_send.settle(runtime, row.id) {
    Ok(Nil) -> {
      log.info(logger, "remote_drain.sent", [
        field.text("orchestrator", row.orchestrator),
        field.text("message_id", row.id),
      ])
      backlog
    }
    Error(reason) -> {
      log.warn(logger, "remote_drain.send_unrecorded", [
        field.text("reason", reason),
        field.text("message_id", row.id),
      ])
      owed
    }
  }
}

fn where(entry: Kept) -> List(field.Field) {
  [
    field.text("orchestrator", entry.stub.orchestrator),
    field.text("stub", entry.key),
  ]
}
