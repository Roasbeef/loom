//// What a session owes the other orchestrators that run its subagents, and the
//// pass that attempts it (protocol-change/084, slice S3).
////
//// A parent session writes a stub before it sends a `Spawn` to another
//// orchestrator (`client/remote_child`). The orchestrator can be unreachable, and
//// the parent can crash between the stub and the message it implies, so something
//// has to keep attempting what is recorded. That is a second instance of the
//// outbox drainer (`client/peer_outbox_drain`), given this pass instead of peer
//// mail's. The pass owes two things.
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
//// ## Flow
////
//// `pass` → `spawn_pass` → `attempt_spawn` → `join_pass` → `join_group`
////
//// 1. `pass` reads the stubs through the session's runtime, which it fetches
////    afresh each time because the drainer outlives a restart of the runtime.
//// 2. `spawn_pass` walks the stubs that are `Requested`, and `attempt_spawn`
////    sends one and records the answer.
//// 3. `join_pass` groups the stubs whose child is running by orchestrator and
////    parent strand, and `join_group` asks one zero-window `Join` for each group
////    and settles the children it reports finished.
//// 4. An orchestrator that did not answer is not asked again in the same step,
////    the way the peer-mail pass skips a silent session: every record owed to it
////    would wait out the same deadline to learn the same thing.

import client/peer_mail
import client/peer_outbox_drain.{type Backlog, Clear, Owed, Quick}
import client/remote_child.{type Kept}
import client/remote_reach.{type Reach}
import client/remote_spawn.{type ChildUsage, type Joined}
import core/clock.{type Clock}
import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import runtime/api
import telemetry/field
import telemetry/log.{type Logger}
import tools/agent.{type Handle, type Outcome}

// What a pass owes while any spawn is unanswered or any child is running. The
// drainer's pace for it is the fixed interval, whatever kept the pass from
// finishing: the orchestrator that did not answer may be back by the next
// tick, and a running child ends at no moment this side can predict.
const owed = Owed(Quick)

/// The pass of the second drainer instance: attempts every spawn that is owed,
/// asks after every child that is running, and says whether anything still is.
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
        let spawns = spawn_pass(open, reach, time, logger)
        let running = join_pass(open, reach, time, logger)
        owed_if_either(spawns, running)
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

// --- spawns that have not been answered --------------------------------------

// Attempts each stub that is `Requested`. A stub list that cannot be read is
// `Owed`: the stubs may exist, and the next pass reads again.
fn spawn_pass(
  runtime: api.Runtime,
  reach: Reach,
  time: Clock,
  logger: Logger,
) -> Backlog {
  case remote_child.all(runtime) {
    Error(reason) -> {
      log.warn(logger, "remote_drain.unreadable", [field.text("reason", reason)])
      owed
    }
    Ok(kept) -> {
      let #(backlog, _silent) =
        kept
        |> list.filter(fn(entry) { entry.stub.state == remote_child.Requested })
        |> list.fold(#(Clear, []), fn(so_far, entry) {
          attempt_spawn(runtime, reach, time, logger, entry, so_far)
        })
      backlog
    }
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
          remote_reach.spawn_ms,
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

// --- children that are running ------------------------------------------------

// Asks after every child whose stub says it is running, and settles the ones
// that finished. The stubs are read again here and not carried over from the
// spawn step, so a child that step has just started is asked about in the same
// pass. A pass that leaves any child running is `Owed`, which is what keeps the
// drainer ticking while a child runs and stops it when none does.
fn join_pass(
  runtime: api.Runtime,
  reach: Reach,
  time: Clock,
  logger: Logger,
) -> Backlog {
  case remote_child.all(runtime) {
    Error(reason) -> {
      log.warn(logger, "remote_drain.unreadable", [field.text("reason", reason)])
      owed
    }
    Ok(kept) -> {
      let #(now, _clock) = clock.read(time)
      let #(backlog, _silent) =
        kept
        |> list.filter(fn(entry) { running(entry, now) })
        |> by_parent
        |> list.fold(#(Clear, []), fn(so_far, group) {
          join_group(runtime, reach, logger, group, so_far)
        })
      backlog
    }
  }
}

// Whether the stub is `Spawned` and its child's deadline has not passed. A
// `Requested` stub is the spawn step's, and a child past its deadline needs no
// asking: its slot is free by the clock and `agent_wait` reads its outcome.
fn running(entry: Kept, now: Int) -> Bool {
  case entry.stub.state {
    remote_child.Spawned(..) -> remote_child.is_live(entry.stub, now)
    remote_child.Requested
    | remote_child.Settled(..)
    | remote_child.Refused(..) -> False
  }
}

// The stubs grouped by the orchestrator they run on and the parent strand that
// asked, because a `Join` names one parent and the receiver judges the handles
// against it. The groups come in key order so that a pass asks the same way each
// time.
fn by_parent(entries: List(Kept)) -> List(#(#(String, String), List(Kept))) {
  entries
  |> list.group(fn(entry) { #(entry.stub.orchestrator, entry.stub.strand) })
  |> dict.to_list
  |> list.sort(fn(a, b) {
    string.compare(a.0.0 <> "/" <> a.0.1, b.0.0 <> "/" <> b.0.1)
  })
}

// One zero-window `Join` for the running children of one parent on one
// orchestrator. Silence marks the orchestrator silent for the rest of the pass
// and leaves its children owed. A refusal is definitive: the orchestrator will
// not report these children, and their deadlines release the slots, so it is
// logged and not asked again.
fn join_group(
  runtime: api.Runtime,
  reach: Reach,
  logger: Logger,
  group: #(#(String, String), List(Kept)),
  so_far: #(Backlog, List(String)),
) -> #(Backlog, List(String)) {
  let #(#(orchestrator, strand), entries) = group
  let #(backlog, silent) = so_far
  case list.contains(silent, orchestrator) {
    True -> #(owed, silent)
    False ->
      case
        reach.join(
          orchestrator,
          remote_reach.parent(reach, strand),
          list.filter_map(entries, handle_of),
          0,
        )
      {
        Ok(joined) -> #(
          owed_if_either(backlog, settle_all(runtime, logger, joined, entries)),
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

fn handle_of(entry: Kept) -> Result(Handle, Nil) {
  case entry.stub.state {
    remote_child.Spawned(placed:) -> Ok(placed.handle)
    remote_child.Requested
    | remote_child.Settled(..)
    | remote_child.Refused(..) -> Error(Nil)
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
  entries: List(Kept),
) -> Backlog {
  list.fold(entries, Clear, fn(backlog, entry) {
    let settled = case handle_of(entry) {
      Ok(handle) -> finished(joined, handle)
      Error(Nil) -> None
    }
    case settled {
      Some(#(outcome, usage)) ->
        owed_if_either(backlog, settle(runtime, logger, entry, outcome, usage))
      None -> owed
    }
  })
}

// The outcome and cost a join reports for one handle, when it reports that child
// finished.
fn finished(
  joined: List(Joined),
  handle: Handle,
) -> Option(#(Outcome, ChildUsage)) {
  list.find_map(joined, fn(entry) {
    case entry {
      remote_spawn.Ready(handle: found, outcome:, usage:, ..)
        if found == handle
      -> Ok(#(outcome, usage))
      remote_spawn.Ready(..) | remote_spawn.Pending(..) -> Error(Nil)
    }
  })
  |> option.from_result
}

// Records one child as finished. A write the store would not take leaves the
// child owed, since asking again returns the same report.
fn settle(
  runtime: api.Runtime,
  logger: Logger,
  entry: Kept,
  outcome: Outcome,
  usage: ChildUsage,
) -> Backlog {
  case remote_child.settled(runtime, entry.key, outcome, usage) {
    Ok(_) -> {
      log.info(logger, "remote_drain.settled", where(entry))
      Clear
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

fn where(entry: Kept) -> List(field.Field) {
  [
    field.text("orchestrator", entry.stub.orchestrator),
    field.text("stub", entry.key),
  ]
}
