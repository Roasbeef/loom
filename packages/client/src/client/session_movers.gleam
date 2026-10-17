//// The daemon's movers: which sessions are being handed to another orchestrator
//// right now, and the process that keeps each of them going
//// (protocol-change/078, phase 5).
////
//// `client/session_mover` drives one move as far as it can and says how it
//// ended. This module owns the running of it. It is one actor, started with the
//// daemon's services and linked to them, and not part of the session registry:
//// the registry's turns are bounded by five seconds and a move waits on an
//// executor for a minute, so the work belongs to a process that can wait. The
//// registry commits the intent; this actor is told about it and does the rest.
////
//// ## Who runs what
////
//// Each move is one weft run, started by the actor and linked to it. The run
//// drives the move and reports how it ended in a single message, and the actor
//// keeps one entry per session until that message says the move is over.
////
//// - `Begin` starts a mover for a move that has none. The control command sends
////   it after the registry committed `moving`, and a restart sends it for every
////   `moving` row (`resume`), so a move survives the daemon that began it.
//// - A mover that ends `Stalled` is not abandoned. Its entry waits, and the next
////   tick starts it again, because whatever stopped it, an executor or an
////   orchestrator that did not answer, may have passed. This is the same retry
////   that follows a restart, and it takes the same path: the run reads the row
////   and asks the receiver, and does what remains.
//// - A mover that ends `Finished` or `Aborted` is removed.
//// - A second `Begin` for a move that is already running or waiting changes
////   nothing, so two owners asking at once, or a command racing a restart, start
////   one mover.
////
//// On a directory member (protocol-change/083) two more things happen on the
//// tick. A move that has stalled for thirty minutes while the store had a
//// quorum, toward a receiver whose migration marker exists, is given up
//// (`session_mover.give_up`), which is safe because the abandon is a
//// compare-and-set that fails if the receiver activated. The marker condition
//// keeps a receiver that still runs the phase 5 code, which never writes the
//// record, from being abandoned while it may hold the session. And the
//// upkeep runs (`Upkeep`): the store is seeded from the catalogue until it has
//// been once, the deletions a crash or a missing quorum left marked are
//// finished, and, at boot and after every local session's creation until a
//// run succeeds, the local sessions' records are written. An owner can also
//// give a move up at once (`Control.abandon`); a mover that is running is not
//// interrupted, so the request is kept on its entry and the give-up starts when
//// that run ends, through the same compare-and-set; and a deleted local session's
//// record is removed best-effort (`Control.forget`).
////
//// A daemon's report of itself lists these moves (protocol-change/085), so an
//// entry also keeps the reason the last run stopped, cut to
//// `node_report.max_reason_bytes`, and `Control.moves` reads the entries in the
//// actor's own turn. How long a move has been stalled is a duration on this
//// node's monotonic clock and never a timestamp, since the node that reads the
//// report has a different clock.
////
//// The entry is a map from session to the move, and a session has one row, so
//// one session can have only one move. A `Begin` carrying another operation
//// replaces the entry, which can only happen after the earlier move ended and
//// its row was replaced.

import client/daemon/manager
import client/node_report.{type MoveFacts}
import client/orchestrators.{type Orchestrator}
import client/remote/orchestrator_port.{type Ownership}
import client/roster.{type Roster}
import client/session_mover.{
  type Environment, Aborted, Deferred, Finished, Stalled,
}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import storage/catalogue
import weft
import weft/actor

/// How long a stalled mover waits before it runs again, in milliseconds.
pub const retry_ms = 5000

/// How long a move may stall, with the directory store answering, before a
/// member gives it up: thirty minutes.
pub const give_up_after_ms = 1_800_000

/// How long `Control.moves` waits for the actor to list its entries. The actor
/// answers from memory between runs, so a wait this long means it is wedged.
pub const moves_wait_ms = 2000

/// What the rest of the daemon holds to start moves: the orchestrators a move
/// may go to, and the one way to tell the movers a move has begun.
pub type Control {
  Control(
    /// The orchestrators this daemon lists. A move to any other name is refused
    /// before the registry is asked.
    orchestrators: Roster(Orchestrator),
    /// Tells the movers that a move began, and returns at once. The move is
    /// already `moving` in the catalogue when this is called.
    begin: fn(catalogue.Pending) -> Nil,
    /// Asks an orchestrator whether it holds a session, and answers what its
    /// port answers, or `Error(Nil)` for silence. A move of a session this
    /// daemon imported is begun only after the orchestrator it came from
    /// answers `Moved`, which that orchestrator can answer only after it
    /// retired the move that brought the session here.
    holds: fn(Orchestrator, String) -> Result(Ownership, Nil),
    /// Gives up the move of a session now, on a directory member, and returns
    /// at once; a session with no move in flight is left alone.
    abandon: fn(String) -> Nil,
    /// Says a local session was created, so the next tick writes the local
    /// sessions' records, and returns at once.
    cover: fn() -> Nil,
    /// Removes the record of a local session that was deleted, best-effort,
    /// and returns at once.
    forget: fn(String) -> Nil,
    /// The moves in flight, as a report lists them. It asks the actor and
    /// waits for its answer, so a stuck actor ends the caller's turn instead of
    /// being reported as a daemon with no moves.
    moves: fn() -> List(MoveFacts),
  )
}

/// The work a directory member's movers do on their tick beside the moves
/// (protocol-change/083). A daemon that is not a member passes `no_upkeep()`.
pub type Upkeep {
  Upkeep(
    /// Runs on every tick: the seed, until it has run once, and the deletions
    /// left marked.
    every_tick: fn() -> Nil,
    /// Writes the record of every local session that lacks one. An error leaves
    /// the work wanted, and the next tick tries again.
    cover: fn() -> Result(Nil, String),
    /// Removes the record of one deleted local session; its outcome is not
    /// waited for.
    release: fn(String) -> Nil,
  )
}

// What the actor is told.
type Message {
  Begin(move: catalogue.Pending)
  Tick
  Ended(move: catalogue.Pending, outcome: session_mover.Outcome)
  GiveUp(session: String)
  Cover
  Forget(session: String)
  Moves(reply: Subject(List(MoveFacts)))

  // A pass of the upkeep ended. `covered` is the request count the pass wrote
  // the local records for, when it was asked to and succeeded.
  Swept(covered: Option(Int))
}

// Whether a mover is running for a move or waiting to run again.
type Phase {
  Running
  Waiting
}

// Whether the owner asked to give a move up while its mover was running. A
// running mover cannot be interrupted, so the request is kept on the entry and
// honoured when that run ends.
type Abandon {
  Unasked
  Asked
}

// A move that stalled while the store answered keeps the time its stalling
// began; a stall for want of a quorum clears it, so that time is not counted.
// `reason` is the last thing a run said when it stopped, kept through the retry
// so a report can say why a move that is running again was waiting.
type Entry {
  Entry(
    move: catalogue.Pending,
    phase: Phase,
    stalled_since: Option(Int),
    reason: Option(String),
    abandon: Abandon,
  )
}

// Whether a pass of the upkeep is running.
type Sweep {
  Sweeping
  Resting
}

type State(instance) {
  State(
    environment: Environment(instance),
    inbox: Subject(Message),
    entries: Dict(String, Entry),
    give_up_after_ms: Int,
    upkeep: Upkeep,
    sweep: Sweep,
    // How many times the local records were asked for, and the count the last
    // successful pass covered. A request made while a pass runs is not covered
    // by that pass, so the next tick runs another. Boot is the first request.
    wanted: Int,
    covered: Int,
  )
}

/// The upkeep of a daemon that keeps no directory records: nothing to do.
///
/// ## Examples
///
/// ```gleam
/// // session_movers.start_with(environment, retry_ms, holds, give_up_after_ms, session_movers.no_upkeep())
/// ```
pub fn no_upkeep() -> Upkeep {
  Upkeep(every_tick: fn() { Nil }, cover: fn() { Ok(Nil) }, release: fn(_) {
    Nil
  })
}

/// The control of a daemon that moves nothing: it lists no orchestrator, so every
/// move is refused before the registry is asked, and `begin` does nothing.
///
/// ## Examples
///
/// ```gleam
/// assert roster.rows(session_movers.idle().orchestrators) == []
/// ```
pub fn idle() -> Control {
  Control(
    orchestrators: roster.fixed([]),
    begin: fn(_move) { Nil },
    holds: fn(_orchestrator, _session) { Error(Nil) },
    abandon: fn(_session) { Nil },
    cover: fn() { Nil },
    forget: fn(_session) { Nil },
    moves: fn() { [] },
  )
}

/// Starts the actor, linked to the caller, and returns the control that reaches
/// it. `every_ms` is how often a stalled mover runs again; a daemon passes
/// `retry_ms`.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(control) = session_movers.start(environment, session_movers.retry_ms, session_directory.over_distribution(membership))
/// ```
pub fn start(
  environment: Environment(instance),
  every_ms: Int,
  holds: fn(Orchestrator, String) -> Result(Ownership, Nil),
) -> Result(Control, String) {
  start_with(environment, every_ms, holds, give_up_after_ms, no_upkeep())
}

/// `start`, with how long a member lets a move stall before it gives it up and
/// the member's upkeep (protocol-change/083); a daemon passes
/// `give_up_after_ms` and an `Upkeep` over its registry and its ownership.
///
/// ## Examples
///
/// ```gleam
/// // session_movers.start_with(environment, retry_ms, holds, give_up_after_ms, upkeep)
/// ```
pub fn start_with(
  environment: Environment(instance),
  every_ms: Int,
  holds: fn(Orchestrator, String) -> Result(Ownership, Nil),
  give_up_after: Int,
  upkeep: Upkeep,
) -> Result(Control, String) {
  let started =
    actor.new_with_initialiser(1000, fn(inbox) {
      let state =
        State(
          environment:,
          inbox:,
          entries: dict.new(),
          give_up_after_ms: give_up_after,
          upkeep:,
          sweep: Resting,
          wanted: 1,
          covered: 0,
        )
      Ok(actor.initialised(state) |> actor.returning(inbox))
    })
    |> actor.on_message(handle)
    |> actor.periodic(every: every_ms, sending: Tick)
    |> actor.start
  case started {
    Ok(started) -> {
      let inbox = started.data
      Ok(
        Control(
          orchestrators: environment.orchestrators,
          begin: fn(move) { process.send(inbox, Begin(move)) },
          holds:,
          abandon: fn(session) { process.send(inbox, GiveUp(session)) },
          cover: fn() { process.send(inbox, Cover) },
          forget: fn(session) { process.send(inbox, Forget(session)) },
          moves: fn() { process.call(inbox, moves_wait_ms, Moves) },
        ),
      )
    }
    Error(error) ->
      Error("the session movers did not start: " <> string.inspect(error))
  }
}

/// Starts a mover for every move the catalogue still has in `moving`, which is
/// what a restart does. The count is the number of moves resumed.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(resumed) = session_movers.resume(control, registry)
/// ```
pub fn resume(
  control: Control,
  registry: manager.Manager(instance),
) -> Result(Int, String) {
  use pending <- result.map(
    manager.moving_sessions(registry)
    |> result.map_error(fn(error) {
      "the moves in flight could not be listed: " <> string.inspect(error)
    }),
  )
  list.each(pending, control.begin)
  list.length(pending)
}

fn handle(
  state: State(instance),
  message: Message,
) -> actor.Next(State(instance), Message) {
  case message {
    // A move that has an entry under the same operation is already being
    // driven or is waiting its turn.
    Begin(move:) ->
      case dict.get(state.entries, move.session) {
        Ok(Entry(move: held, ..)) if held.op == move.op -> actor.continue(state)
        Ok(_) | Error(Nil) ->
          actor.continue(start_mover(
            state,
            Entry(
              move:,
              phase: Waiting,
              stalled_since: None,
              reason: None,
              abandon: Unasked,
            ),
          ))
      }

    // The ones that stalled run again, or are given up when they have stalled
    // long enough on a member. A mover that is running is left alone.
    Tick -> {
      let now = bootstrap.monotonic_time_ms()
      state.entries
      |> dict.values
      |> list.fold(state, fn(state, entry) {
        case entry.phase {
          Waiting ->
            case overdue(state, entry, now) {
              True -> start_giving_up(state, entry)
              False -> start_mover(state, entry)
            }
          Running -> state
        }
      })
      |> sweep
      |> actor.continue
    }

    GiveUp(session:) ->
      case dict.get(state.entries, session) {
        Ok(Entry(phase: Waiting, ..) as entry) ->
          actor.continue(start_giving_up(state, entry))

        // A run in progress is not interrupted. The request is kept, and the
        // run's end gives the move up in its place (`after_run`), through the
        // same compare-and-set, so a receiver that already activated still
        // finishes the move.
        Ok(Entry(phase: Running, ..) as entry) ->
          actor.continue(
            State(
              ..state,
              entries: dict.insert(
                state.entries,
                session,
                Entry(..entry, abandon: Asked),
              ),
            ),
          )
        Error(Nil) -> actor.continue(state)
      }

    Cover -> actor.continue(State(..state, wanted: state.wanted + 1))

    // The entries are read here, in the actor's turn, so the list is one
    // moment's view and needs no table shared with other processes.
    Moves(reply:) -> {
      process.send(reply, move_facts(state, bootstrap.monotonic_time_ms()))
      actor.continue(state)
    }

    // The removal runs on its own and reports nothing: a record left behind
    // names this daemon, which answers `not_found` for the session.
    Forget(session:) -> {
      let release = state.upkeep.release
      let _witness =
        weft.new([
          fn() {
            release(session)
            Ok(Nil)
          },
        ])
        |> weft.start_witnessed
      actor.continue(state)
    }

    Swept(covered:) ->
      actor.continue(
        State(
          ..state,
          sweep: Resting,
          covered: option.unwrap(covered, state.covered),
        ),
      )

    Ended(move:, outcome:) ->
      case outcome {
        Finished | Aborted(..) ->
          actor.continue(
            State(..state, entries: dict.delete(state.entries, move.session)),
          )
        Stalled(reason:) -> {
          let since = case dict.get(state.entries, move.session) {
            Ok(Entry(stalled_since: Some(since), ..)) -> Some(since)
            Ok(Entry(stalled_since: None, ..)) | Error(Nil) ->
              Some(bootstrap.monotonic_time_ms())
          }
          actor.continue(after_run(state, move, since, Some(reason)))
        }
        Deferred(reason:) ->
          actor.continue(after_run(state, move, None, Some(reason)))
      }
  }
}

// A run that did not end the move. If the owner asked to give the move up while
// it ran, the give-up starts now in place of waiting for the next tick. It goes
// through `session_mover.give_up`, which expects the moving record, so it fails
// if the receiver already took the session and the move finishes instead. The
// request is spent by that run. Otherwise the move waits to run again.
fn after_run(
  state: State(instance),
  move: catalogue.Pending,
  since: Option(Int),
  reason: Option(String),
) -> State(instance) {
  case dict.get(state.entries, move.session) {
    Ok(Entry(abandon: Asked, ..)) ->
      start_giving_up(
        waiting(state, move, since, reason),
        Entry(
          move:,
          phase: Waiting,
          stalled_since: since,
          reason: option.map(reason, node_report.cut_reason),
          abandon: Unasked,
        ),
      )
    Ok(Entry(abandon: Unasked, ..)) | Error(Nil) ->
      waiting(state, move, since, reason)
  }
}

fn waiting(
  state: State(instance),
  move: catalogue.Pending,
  since: Option(Int),
  reason: Option(String),
) -> State(instance) {
  State(
    ..state,
    entries: dict.insert(
      state.entries,
      move.session,
      Entry(
        move:,
        phase: Waiting,
        stalled_since: since,
        reason: option.map(reason, node_report.cut_reason),
        abandon: Unasked,
      ),
    ),
  )
}

// The entries as a report lists them, ordered by session so that two reads of
// the same moves agree. The destination is named by its node when this daemon
// lists the orchestrator, and by the configured name otherwise, since a move
// resumed after the configuration changed can name one that is gone.
fn move_facts(state: State(instance), now: Int) -> List(MoveFacts) {
  let listed = roster.rows(state.environment.orchestrators)
  state.entries
  |> dict.values
  |> list.sort(fn(a, b) { string.compare(a.move.session, b.move.session) })
  |> list.take(node_report.max_moves)
  |> list.map(fn(entry) {
    node_report.MoveFacts(
      session: entry.move.session,
      op: entry.move.op,
      to_node: case orchestrators.find(listed, entry.move.to) {
        Ok(receiver) -> receiver.node
        Error(Nil) -> entry.move.to
      },
      phase: case entry.phase {
        Running -> node_report.Running
        Waiting -> node_report.Waiting
      },
      stalled_ms: option.map(entry.stalled_since, fn(since) { now - since }),
      reason: entry.reason,
    )
  })
}

// Whether a member should give a move up: it has stalled for long enough while
// the store answered, and the receiver has seeded the store, so it decides by
// the record and an abandon cannot race a receiver that never writes it.
fn overdue(state: State(instance), entry: Entry, now: Int) -> Bool {
  case state.environment.authority, entry.stalled_since {
    session_mover.Recorded(ownership:), Some(since) ->
      now - since >= state.give_up_after_ms
      && {
        case
          orchestrators.find(
            roster.rows(state.environment.orchestrators),
            entry.move.to,
          )
        {
          Ok(receiver) -> ownership.migrated(receiver.node) == Ok(True)
          Error(Nil) -> False
        }
      }
    session_mover.Recorded(..), None | session_mover.Rows, _ -> False
  }
}

// Starts one pass of the upkeep unless one is running. The local records are
// written only when a request is not yet covered, and the pass reports the
// request count it started with, so a creation during the pass is covered by
// the next one.
fn sweep(state: State(instance)) -> State(instance) {
  case state.sweep {
    Sweeping -> state
    Resting -> {
      let upkeep = state.upkeep
      let inbox = state.inbox
      let through = state.wanted
      let uncovered = state.covered < through
      let _witness =
        weft.new([
          fn() {
            upkeep.every_tick()
            let covered = case uncovered {
              True ->
                upkeep.cover()
                |> result.replace(through)
                |> option.from_result
              False -> None
            }
            process.send(inbox, Swept(covered:))
            Ok(Nil)
          },
        ])
        |> weft.start_witnessed
      State(..state, sweep: Sweeping)
    }
  }
}

fn start_mover(state: State(instance), entry: Entry) -> State(instance) {
  run_mover(state, entry, session_mover.drive)
}

fn start_giving_up(state: State(instance), entry: Entry) -> State(instance) {
  run_mover(state, entry, session_mover.give_up)
}

// Starts the mover of one move in a run linked to this actor. The run drives the
// move inside a run of its own, so a mover that crashes is a stalled move and the
// report is still sent; the actor never waits for a message that cannot come.
fn run_mover(
  state: State(instance),
  entry: Entry,
  step: fn(Environment(instance), catalogue.Pending) -> session_mover.Outcome,
) -> State(instance) {
  let environment = state.environment
  let inbox = state.inbox
  let move = entry.move
  let _witness =
    weft.new([
      fn() {
        let outcome = case
          weft.new([fn() { Ok(step(environment, move)) }])
          |> weft.start
        {
          [weft.Completed(value:, ..)] -> value
          [weft.Failed(..)]
          | [weft.Crashed(..)]
          | [weft.Abandoned(..)]
          | [weft.NeverStarted(..)]
          | [weft.DrainProofLost(..)]
          | [weft.CancellationUnconfirmed(..)]
          | []
          | [_, _, ..] -> Stalled("the mover crashed")
        }
        process.send(inbox, Ended(move:, outcome:))
        Ok(Nil)
      },
    ])
    |> weft.start_witnessed
  State(
    ..state,
    entries: dict.insert(
      state.entries,
      move.session,
      Entry(..entry, phase: Running),
    ),
  )
}
