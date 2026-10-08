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
//// On a directory member (protocol-change/079) two more things happen on the
//// tick. A move that has stalled for thirty minutes while the store had a
//// quorum, toward a receiver whose migration marker exists, is given up
//// (`session_mover.give_up`), which is safe because the abandon is a
//// compare-and-set that fails if the receiver activated. The marker condition
//// keeps a receiver that still runs the phase 5 code, which never writes the
//// record, from being abandoned while it may hold the session. And the
//// deletions a crash or a missing quorum left marked are finished. An owner can
//// also give a move up at once (`Control.abandon`).
////
//// The entry is a map from session to the move, and a session has one row, so
//// one session can have only one move. A `Begin` carrying another operation
//// replaces the entry, which can only happen after the earlier move ended and
//// its row was replaced.

import client/daemon/manager
import client/orchestrators.{type Orchestrator}
import client/remote/orchestrator_port.{type Ownership}
import client/session_mover.{
  type Environment, Aborted, Finished, Stalled, Unquorate,
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

/// What the rest of the daemon holds to start moves: the orchestrators a move
/// may go to, and the one way to tell the movers a move has begun.
pub type Control {
  Control(
    /// The orchestrators this daemon lists. A move to any other name is refused
    /// before the registry is asked.
    orchestrators: List(Orchestrator),
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
  )
}

// What the actor is told.
type Message {
  Begin(move: catalogue.Pending)
  Tick
  Ended(move: catalogue.Pending, outcome: session_mover.Outcome)
  GiveUp(session: String)
  Swept
}

// Whether a mover is running for a move or waiting to run again.
type Phase {
  Running
  Waiting
}

// A move that stalled while the store answered keeps the time its stalling
// began; a stall for want of a quorum clears it, so that time is not counted.
type Entry {
  Entry(move: catalogue.Pending, phase: Phase, stalled_since: Option(Int))
}

// Whether a pass over the marked deletions is running.
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
    deletions: fn() -> Nil,
    sweep: Sweep,
  )
}

/// The control of a daemon that moves nothing: it lists no orchestrator, so every
/// move is refused before the registry is asked, and `begin` does nothing.
///
/// ## Examples
///
/// ```gleam
/// assert session_movers.idle().orchestrators == []
/// ```
pub fn idle() -> Control {
  Control(
    orchestrators: [],
    begin: fn(_move) { Nil },
    holds: fn(_orchestrator, _session) { Error(Nil) },
    abandon: fn(_session) { Nil },
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
  start_with(environment, every_ms, holds, give_up_after_ms, fn() { Nil })
}

/// `start`, with how long a member lets a move stall before it gives it up and
/// the pass that finishes marked deletions (protocol-change/079); a daemon
/// passes `give_up_after_ms` and `deletion.finish_pending` over its registry.
///
/// ## Examples
///
/// ```gleam
/// // session_movers.start_with(environment, retry_ms, holds, give_up_after_ms, sweep)
/// ```
pub fn start_with(
  environment: Environment(instance),
  every_ms: Int,
  holds: fn(Orchestrator, String) -> Result(Ownership, Nil),
  give_up_after: Int,
  deletions: fn() -> Nil,
) -> Result(Control, String) {
  let started =
    actor.new_with_initialiser(1000, fn(inbox) {
      let state =
        State(
          environment:,
          inbox:,
          entries: dict.new(),
          give_up_after_ms: give_up_after,
          deletions:,
          sweep: Resting,
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
            Entry(move:, phase: Waiting, stalled_since: None),
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
        Ok(Entry(phase: Running, ..)) | Error(Nil) -> actor.continue(state)
      }

    Swept -> actor.continue(State(..state, sweep: Resting))

    Ended(move:, outcome:) ->
      case outcome {
        Finished | Aborted(..) ->
          actor.continue(
            State(..state, entries: dict.delete(state.entries, move.session)),
          )
        Stalled(..) -> {
          let since = case dict.get(state.entries, move.session) {
            Ok(Entry(stalled_since: Some(since), ..)) -> Some(since)
            Ok(Entry(stalled_since: None, ..)) | Error(Nil) ->
              Some(bootstrap.monotonic_time_ms())
          }
          actor.continue(waiting(state, move, since))
        }
        Unquorate(..) -> actor.continue(waiting(state, move, None))
      }
  }
}

fn waiting(
  state: State(instance),
  move: catalogue.Pending,
  since: Option(Int),
) -> State(instance) {
  State(
    ..state,
    entries: dict.insert(
      state.entries,
      move.session,
      Entry(move:, phase: Waiting, stalled_since: since),
    ),
  )
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
          orchestrators.find(state.environment.orchestrators, entry.move.to)
        {
          Ok(receiver) -> ownership.migrated(receiver.node) == Ok(True)
          Error(Nil) -> False
        }
      }
    session_mover.Recorded(..), None | session_mover.Rows, _ -> False
  }
}

// Starts one pass over the marked deletions unless one is running.
fn sweep(state: State(instance)) -> State(instance) {
  case state.sweep {
    Sweeping -> state
    Resting -> {
      let deletions = state.deletions
      let inbox = state.inbox
      let _witness =
        weft.new([
          fn() {
            deletions()
            process.send(inbox, Swept)
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
