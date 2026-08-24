//// A test-side recorder actor: named counters (effect invocations,
//// entropy) plus the interleave harness's crash bomb.
////
//// The recorder outlives the session tree (it is owned by the test
//// process), so counters survive kills — which is exactly what "no
//// `replay: Never` effect ran twice across a crash" needs — and the
//// bomb's commit counter keeps counting across writer restarts, so a
//// bomb armed at commit `k` fires exactly once per scenario run.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/otp/actor

pub opaque type Message {
  Bump(key: String, reply: Subject(Int))
  Read(key: String, reply: Subject(Int))
  Arm(at: Int)
  OnCommit(reply: Subject(Bool))
  CommitCount(reply: Subject(Int))
  Fired(reply: Subject(Bool))
}

type State {
  State(counts: Dict(String, Int), armed: Bool, at: Int, seen: Int, fired: Bool)
}

/// Starts a recorder.
pub fn start() -> Subject(Message) {
  let assert Ok(started) =
    actor.new(State(
      counts: dict.new(),
      armed: False,
      at: 0,
      seen: 0,
      fired: False,
    ))
    |> actor.on_message(handle)
    |> actor.start
    as "the test recorder must start"
  started.data
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Bump(key:, reply:) -> {
      let next = case dict.get(state.counts, key) {
        Ok(count) -> count + 1
        Error(Nil) -> 1
      }
      process.send(reply, next)
      actor.continue(
        State(..state, counts: dict.insert(state.counts, key, next)),
      )
    }
    Read(key:, reply:) -> {
      process.send(reply, case dict.get(state.counts, key) {
        Ok(count) -> count
        Error(Nil) -> 0
      })
      actor.continue(state)
    }
    Arm(at:) ->
      actor.continue(State(..state, armed: True, at:, seen: 0, fired: False))
    OnCommit(reply:) ->
      case state.armed {
        False -> {
          process.send(reply, False)
          actor.continue(state)
        }
        True -> {
          let seen = state.seen + 1
          let explode = !state.fired && state.at > 0 && seen == state.at
          process.send(reply, explode)
          actor.continue(State(..state, seen:, fired: state.fired || explode))
        }
      }
    CommitCount(reply:) -> {
      process.send(reply, state.seen)
      actor.continue(state)
    }
    Fired(reply:) -> {
      process.send(reply, state.fired)
      actor.continue(state)
    }
  }
}

/// Increments a counter, returning the new value.
pub fn bump(recorder: Subject(Message), key: String) -> Int {
  process.call_forever(recorder, Bump(key, _))
}

/// Reads a counter (0 when never bumped).
pub fn read(recorder: Subject(Message), key: String) -> Int {
  process.call_forever(recorder, Read(key, _))
}

/// Arms the crash bomb: the `at`-th armed commit explodes (kills the
/// writer). `at <= 0` counts commits without ever exploding.
pub fn arm(recorder: Subject(Message), at: Int) -> Nil {
  process.send(recorder, Arm(at))
}

/// Reports one commit; `True` means the caller must crash now.
pub fn on_commit(recorder: Subject(Message)) -> Bool {
  process.call_forever(recorder, OnCommit)
}

/// The number of commits seen since the bomb was armed.
pub fn commit_count(recorder: Subject(Message)) -> Int {
  process.call_forever(recorder, CommitCount)
}

/// Whether the armed bomb has exploded.
pub fn fired(recorder: Subject(Message)) -> Bool {
  process.call_forever(recorder, Fired)
}
