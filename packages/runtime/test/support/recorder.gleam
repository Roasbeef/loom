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
  Arm(at: Int, skipping: Int)
  OnCommit(reply: Subject(Bool))
  CommitCount(reply: Subject(Int))
  Fired(reply: Subject(Bool))
}

type State {
  State(
    counts: Dict(String, Int),
    armed: Bool,
    at: Int,
    /// Commits still to let through uncounted after arming: the test's
    /// own admissions, which precede the run and must be neither numbered
    /// nor exploded.
    skip: Int,
    seen: Int,
    fired: Bool,
  )
}

/// Starts a recorder.
pub fn start() -> Subject(Message) {
  let assert Ok(started) =
    actor.new(State(
      counts: dict.new(),
      armed: False,
      at: 0,
      skip: 0,
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
    Arm(at:, skipping:) ->
      actor.continue(
        State(..state, armed: True, at:, skip: skipping, seen: 0, fired: False),
      )
    OnCommit(reply:) ->
      case state.armed, state.skip > 0 {
        False, _skip -> {
          process.send(reply, False)
          actor.continue(state)
        }

        // An admission the test itself made: let it through without a
        // number, so the bomb's `k` still means "the k-th commit of the
        // run" whatever the driver does in the meantime.
        True, True -> {
          process.send(reply, False)
          actor.continue(State(..state, skip: state.skip - 1))
        }
        True, False -> {
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
/// writer). `at <= 0` counts commits without ever exploding. The first
/// `skipping` commits after arming are passed through uncounted and
/// unexploded — they are the test's own admissions (acceptance, steer),
/// which have to be committed *after* arming so the driver cannot slip a
/// run-start commit into the gap between the admission and the arm.
pub fn arm(recorder: Subject(Message), at: Int, skipping skipping: Int) -> Nil {
  process.send(recorder, Arm(at, skipping:))
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
