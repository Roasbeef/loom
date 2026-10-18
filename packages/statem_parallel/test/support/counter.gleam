//// A counter served by one actor, and the spec that tests it.
////
//// The counter is the smallest system with a race in it. Served correctly,
//// every call is one message to a single actor, so calls serialize and the
//// counter is linearizable. Served badly, an increment is two messages, a
//// read and then a write, and two overlapping increments can both read the
//// same value and both write the one past it.
////
//// The module is shared by the property tests, which differ only in what
//// they break: the actor's behaviour, the model, a precondition, or what
//// `run` does in a branch.

import gleam/erlang/process.{type Subject}
import gleam/int
import qcheck
import statem
import statem_parallel.{type Spec, Spec}
import weft/actor

/// What a caller can ask of the counter.
pub type Cmd {
  Increment
  Decrement
  Read
}

/// What came back.
pub type Response {
  Value(Int)
  Underflow
}

/// The actor's mailbox.
pub type Message {
  Bump(reply: Subject(Response))
  Drop(reply: Subject(Response))
  Get(reply: Subject(Response))
  Put(value: Int, reply: Subject(Response))
  /// Choose how this actor's `Intermittent` callers increment.
  Configure(Service)
  /// Ask how `Intermittent` callers should increment.
  Serving(reply: Subject(Service))
  Stop
}

/// How `increment` is carried out.
pub type Service {
  /// One message: the actor adds one itself.
  Atomic
  /// Two messages: the caller reads, pauses for `race_window`, then writes.
  ReadThenWrite
  /// Whichever of the two the actor was told to use when it was built. A
  /// system built to be faulty only on some of its lives, which is what a
  /// scheduling-dependent bug looks like from outside, but decided by a
  /// counter instead of by chance so the test is deterministic.
  Intermittent
}

/// Start a counter actor at zero. It is linked to the caller, which is the
/// test process, and exits normally on `Stop`.
pub fn start() -> Subject(Message) {
  let assert Ok(started) =
    actor.new(State(count: 0, service: Atomic))
    |> actor.on_message(handle)
    |> actor.start
    as "the counter actor starts"

  started.data
}

/// The actor's state: the count, and how `Intermittent` callers increment.
type State {
  State(count: Int, service: Service)
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  let State(count, service) = state

  case message {
    Bump(reply) -> {
      process.send(reply, Value(count + 1))
      actor.continue(State(..state, count: count + 1))
    }

    Drop(reply) ->
      case count > 0 {
        True -> {
          process.send(reply, Value(count - 1))
          actor.continue(State(..state, count: count - 1))
        }

        False -> {
          process.send(reply, Underflow)
          actor.continue(state)
        }
      }

    Get(reply) -> {
      process.send(reply, Value(count))
      actor.continue(state)
    }

    Put(value, reply) -> {
      process.send(reply, Value(value))
      actor.continue(State(..state, count: value))
    }

    Configure(chosen) -> actor.continue(State(..state, service: chosen))

    Serving(reply) -> {
      process.send(reply, service)
      actor.continue(state)
    }

    Stop -> actor.stop()
  }
}

/// Stop the actor.
pub fn stop(counter: Subject(Message)) -> Nil {
  process.send(counter, Stop)
}

/// How long a read-then-write caller pauses between its two messages, in
/// milliseconds. It is the width of the race: wide enough that a branch
/// process scheduled a little late still lands inside it, so a test that
/// expects the race to show does not depend on scheduler latency.
const race_window = 2

/// Run one command the way `service` says to.
pub fn run(service: Service, counter: Subject(Message), cmd: Cmd) -> Response {
  case cmd {
    Increment ->
      case service {
        Atomic -> process.call(counter, 5000, Bump)

        ReadThenWrite -> {
          let assert Value(seen) = process.call(counter, 5000, Get)
          process.sleep(race_window)
          process.call(counter, 5000, Put(seen + 1, _))
        }

        Intermittent ->
          case process.call(counter, 5000, Serving) {
            Atomic -> run(Atomic, counter, cmd)
            ReadThenWrite -> run(ReadThenWrite, counter, cmd)
            Intermittent -> run(Atomic, counter, cmd)
          }
      }

    Decrement -> process.call(counter, 5000, Drop)
    Read -> process.call(counter, 5000, Get)
  }
}

/// The model's next count: it knows `Increment` adds `step`.
fn advance(count: Int, cmd: Cmd, step: Int) -> Int {
  case cmd {
    Increment -> count + step
    Decrement -> count - 1
    Read -> count
  }
}

/// The spec for the counter, parameterised by the things the tests break.
pub fn spec(
  service service: Service,
  commands commands: List(Cmd),
  step step: Int,
  guard guard: Guard,
) -> Spec(Int, Cmd, Subject(Message), Response) {
  Spec(
    initial: 0,
    command: fn(_) { pick(commands) },
    precondition: fn(count, cmd) {
      case cmd, guard {
        Decrement, Guarded ->
          case count > 0 {
            True -> statem.Admit
            False -> statem.Reject
          }

        _, _ -> statem.Admit
      }
    },
    next_model: fn(count, cmd) { advance(count, cmd, step) },
    new_sut: start,
    run: fn(counter, cmd) { run(service, counter, cmd) },
    postcondition: fn(count, cmd, response) {
      case response {
        Underflow ->
          Error(statem.Violation(
            tag: "underflow",
            detail: "a Decrement ran with the counter at zero",
          ))

        Value(seen) -> {
          let expected = advance(count, cmd, step)

          case seen == expected {
            True -> Ok(Nil)

            False ->
              Error(statem.Violation(
                tag: "counter",
                detail: "expected "
                  <> int.to_string(expected)
                  <> " for "
                  <> describe(cmd)
                  <> ", got "
                  <> int.to_string(seen),
              ))
          }
        }
      }
    },
    finish: fn(_) { Ok(Nil) },
    teardown: stop,
  )
}

/// Whether `Decrement` carries a precondition.
pub type Guard {
  Guarded
  Unguarded
}

/// A generator over the given commands, simplest first.
fn pick(commands: List(Cmd)) -> qcheck.Generator(Cmd) {
  case commands {
    [] -> qcheck.return(Read)
    [only] -> qcheck.return(only)

    [first, ..rest] ->
      qcheck.map(qcheck.bounded_int(from: 0, to: list_length(rest)), fn(index) {
        nth(commands, index, first)
      })
  }
}

fn list_length(items: List(Cmd)) -> Int {
  case items {
    [] -> 0
    [_, ..rest] -> 1 + list_length(rest)
  }
}

fn nth(items: List(Cmd), index: Int, fallback: Cmd) -> Cmd {
  case items, index {
    [], _ -> fallback
    [item, ..], 0 -> item
    [_, ..rest], _ -> nth(rest, index - 1, fallback)
  }
}

/// How a command reads in a report.
pub fn describe(cmd: Cmd) -> String {
  case cmd {
    Increment -> "Increment"
    Decrement -> "Decrement"
    Read -> "Read"
  }
}

/// A tally of calls, kept by an actor so the count is safe to read from the
/// test process while branch processes are writing it.
pub type Tally =
  Subject(TallyMessage)

pub type TallyMessage {
  Note(kind: String)
  Count(kind: String, reply: Subject(Int))
}

/// Start a tally.
pub fn start_tally() -> Tally {
  let assert Ok(started) =
    actor.new([])
    |> actor.on_message(fn(notes: List(String), message) {
      case message {
        Note(kind) -> actor.continue([kind, ..notes])

        Count(kind, reply) -> {
          process.send(reply, count_of(notes, kind, 0))
          actor.continue(notes)
        }
      }
    })
    |> actor.start
    as "the tally actor starts"

  started.data
}

fn count_of(notes: List(String), kind: String, found: Int) -> Int {
  case notes {
    [] -> found

    [note, ..rest] ->
      case note == kind {
        True -> count_of(rest, kind, found + 1)
        False -> count_of(rest, kind, found)
      }
  }
}

/// Record one occurrence of `kind`.
pub fn note(tally: Tally, kind: String) -> Nil {
  process.send(tally, Note(kind))
}

/// How many times `kind` was recorded.
pub fn count(tally: Tally, kind: String) -> Int {
  process.call(tally, 1000, Count(kind, _))
}
