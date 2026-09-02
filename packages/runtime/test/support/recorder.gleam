//// A test-side recorder actor: named counters (effect invocations,
//// entropy) plus the interleave harness's crash bomb.
////
//// The recorder outlives the session tree (it is owned by the test
//// process), so counters survive kills — which is exactly what "no
//// `replay: Never` effect ran twice across a crash" needs — and the
//// bomb's commit counter keeps counting across writer restarts, so a
//// bomb armed at commit `k` fires exactly once per scenario run.
////
//// Two counts, not one. `total` is every commit the writer has ever
//// reported, armed or not, and it is what lets the harness ask whether a
//// drive slipped in while it was admitting its own prompt. `seen` is the
//// run's boundary number, and it only starts once the bomb is armed —
//// after the admissions, so the test's own writes can neither be numbered
//// as the run's nor be the commit that explodes.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/otp/actor

pub opaque type Message {
  Bump(key: String, reply: Subject(Int))
  Read(key: String, reply: Subject(Int))
  Arm(at: Int, after: Int, reply: Subject(Arming))
  OnCommit(reply: Subject(Bool))
  CommitCount(reply: Subject(Int))
  Fired(reply: Subject(Bool))
}

/// Whether a run's boundary numbering begins where its scenario says.
pub type Arming {
  /// The strand driver committed nothing while the test was admitting, so
  /// the next commit the writer reports is boundary one.
  Clean

  /// A drive landed inside the admission window and has already committed
  /// this many of the run's opening boundaries. Numbering from here would
  /// name a different crash point than the scenario's, so the caller
  /// throws the run away rather than crash at a boundary it cannot name.
  Drifted(boundaries: Int)
}

type State {
  State(
    counts: Dict(String, Int),
    armed: Bool,
    at: Int,
    /// Every commit the writer has reported, from the moment the recorder
    /// started. Only arming reads it, and only to subtract the test's own
    /// admissions from it.
    total: Int,
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
      total: 0,
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
    Arm(at:, after: admissions, reply:) -> {
      // The subtraction happens inside this turn, so nothing can commit
      // between reading the total and arming on it: a drive that lands
      // one message later is boundary one, exactly as the scenario means.
      let drift = state.total - admissions
      process.send(reply, case drift {
        0 -> Clean
        boundaries -> Drifted(boundaries:)
      })
      actor.continue(State(..state, armed: True, at:, seen: 0, fired: False))
    }
    OnCommit(reply:) -> {
      let total = state.total + 1
      case state.armed {
        False -> {
          process.send(reply, False)
          actor.continue(State(..state, total:))
        }
        True -> {
          let seen = state.seen + 1
          let explode = !state.fired && state.at > 0 && seen == state.at
          process.send(reply, explode)
          actor.continue(
            State(..state, total:, seen:, fired: state.fired || explode),
          )
        }
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

/// Arms the crash bomb once the test's own `after` admissions have landed:
/// the `at`-th commit reported from here on explodes, killing the writer.
/// `at <= 0` numbers the run's boundaries without ever exploding.
///
/// Arming last is what keeps the test's writes out of the run's numbering
/// and out of the bomb's reach. The writer calls `after_commit` before it
/// releases the committer, so an admission that has returned has already
/// been counted, and the recorder can say whether anything *else* was
/// counted with it: `Clean` when the difference is zero, `Drifted` when a
/// drive beat the arm to the writer.
///
/// ## Examples
///
/// ```gleam
/// // recorder.arm(rec, at: 3, after: 2)
/// // -> Clean
/// ```
///
pub fn arm(recorder: Subject(Message), at at: Int, after after: Int) -> Arming {
  process.call_forever(recorder, Arm(at, after, _))
}

/// Reports one commit; `True` means the caller must crash now.
pub fn on_commit(recorder: Subject(Message)) -> Bool {
  process.call_forever(recorder, OnCommit)
}

/// The run's boundary count: commits reported since the bomb was armed.
pub fn commit_count(recorder: Subject(Message)) -> Int {
  process.call_forever(recorder, CommitCount)
}

/// Whether the armed bomb has exploded.
pub fn fired(recorder: Subject(Message)) -> Bool {
  process.call_forever(recorder, Fired)
}
