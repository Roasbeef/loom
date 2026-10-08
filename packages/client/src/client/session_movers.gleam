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
//// The entry is a map from session to the move, and a session has one row, so
//// one session can have only one move. A `Begin` carrying another operation
//// replaces the entry, which can only happen after the earlier move ended and
//// its row was replaced.

import client/daemon/manager
import client/orchestrators.{type Orchestrator}
import client/session_mover.{type Environment, Aborted, Finished, Stalled}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/result
import gleam/string
import storage/catalogue
import weft
import weft/actor

/// How long a stalled mover waits before it runs again, in milliseconds.
pub const retry_ms = 5000

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
  )
}

// What the actor is told.
type Message {
  Begin(move: catalogue.Pending)
  Tick
  Ended(move: catalogue.Pending, outcome: session_mover.Outcome)
}

// Whether a mover is running for a move or waiting to run again.
type Phase {
  Running
  Waiting
}

type Entry {
  Entry(move: catalogue.Pending, phase: Phase)
}

type State(instance) {
  State(
    environment: Environment(instance),
    inbox: Subject(Message),
    entries: Dict(String, Entry),
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
  Control(orchestrators: [], begin: fn(_move) { Nil })
}

/// Starts the actor, linked to the caller, and returns the control that reaches
/// it. `every_ms` is how often a stalled mover runs again; a daemon passes
/// `retry_ms`.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(control) = session_movers.start(environment, session_movers.retry_ms)
/// ```
pub fn start(
  environment: Environment(instance),
  every_ms: Int,
) -> Result(Control, String) {
  let started =
    actor.new_with_initialiser(1000, fn(inbox) {
      let state = State(environment:, inbox:, entries: dict.new())
      Ok(actor.initialised(state) |> actor.returning(inbox))
    })
    |> actor.on_message(handle)
    |> actor.periodic(every: every_ms, sending: Tick)
    |> actor.start
  case started {
    Ok(started) -> {
      let inbox = started.data
      Ok(
        Control(orchestrators: environment.orchestrators, begin: fn(move) {
          process.send(inbox, Begin(move))
        }),
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
        Ok(_) | Error(Nil) -> actor.continue(start_mover(state, move))
      }

    // The ones that stalled run again. A mover that is running is left alone.
    Tick ->
      state.entries
      |> dict.values
      |> list.fold(state, fn(state, entry) {
        case entry.phase {
          Waiting -> start_mover(state, entry.move)
          Running -> state
        }
      })
      |> actor.continue

    Ended(move:, outcome:) ->
      case outcome {
        Finished | Aborted(..) ->
          actor.continue(
            State(..state, entries: dict.delete(state.entries, move.session)),
          )
        Stalled(..) ->
          actor.continue(
            State(
              ..state,
              entries: dict.insert(
                state.entries,
                move.session,
                Entry(move:, phase: Waiting),
              ),
            ),
          )
      }
  }
}

// Starts the mover of one move in a run linked to this actor. The run drives the
// move inside a run of its own, so a mover that crashes is a stalled move and the
// report is still sent; the actor never waits for a message that cannot come.
fn start_mover(
  state: State(instance),
  move: catalogue.Pending,
) -> State(instance) {
  let environment = state.environment
  let inbox = state.inbox
  let _witness =
    weft.new([
      fn() {
        let outcome = case
          weft.new([fn() { Ok(session_mover.drive(environment, move)) }])
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
      Entry(move:, phase: Running),
    ),
  )
}
