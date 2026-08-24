//// Simulated time: one logical clock every part of a simulated session
//// shares, and the timer wheel its deadlines land in.
////
//// A simulated session never sleeps to make time pass. The clock only
//// moves when the runner moves it, and it moves by exactly one step:
//// to the earliest registered deadline. Everything that reads time —
//// the storage backend's commit timestamps, the strand driver, the
//// effect scripts, the api's id minting — reads this one clock, so the
//// eras that drift apart when a broker and a tool carry separate real
//// clocks cannot drift here.
////
//// Two consequences are worth stating plainly. Firing a deadline early
//// is always safe: every wake the driver schedules is a hint, and the
//// durable state it re-reads on the next pass decides what actually
//// happens. And a deadline is *removed* when it fires, so a wake that
//// the runner delivers to a dead process is simply lost, exactly as a
//// real timer's message would be.
////
//// This module is test infrastructure: `let assert` appears here (as in
//// `conformance/storage_suite`) because a runner whose clock will not
//// start has nothing to say.

import core/clock.{type Clock}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import runtime/effects

/// A pending deadline: when it comes due and what to run.
type Deadline {
  Deadline(at: Int, wake: fn() -> Nil)
}

/// Messages understood by the clock actor. Opaque: callers use the
/// wrapper functions.
pub opaque type Message {
  Read(reply: Subject(Int))
  Schedule(delay_ms: Int, wake: fn() -> Nil)
  TakeEarliest(reply: Subject(Option(fn() -> Nil)))
  Count(reply: Subject(Int))
  Shutdown
}

type State {
  State(now: Int, deadlines: List(Deadline))
}

/// A running simulated clock.
pub type Clockwork {
  Clockwork(subject: Subject(Message), pid: Pid)
}

/// Starts a clock reading `from` (Unix milliseconds) with no deadlines.
///
/// ## Examples
///
/// ```gleam
/// // let vc = vclock.start(from: 1_700_000_000_000)
/// ```
///
pub fn start(from now: Int) -> Clockwork {
  let assert Ok(started) =
    actor.new(State(now:, deadlines: []))
    |> actor.on_message(handle)
    |> actor.start
    as "the simulated clock must start"
  Clockwork(subject: started.data, pid: started.pid)
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Read(reply:) -> {
      process.send(reply, state.now)
      actor.continue(state)
    }
    Schedule(delay_ms:, wake:) -> {
      let at = state.now + int_max(delay_ms, 0)
      actor.continue(
        State(..state, deadlines: [Deadline(at:, wake:), ..state.deadlines]),
      )
    }
    TakeEarliest(reply:) ->
      case earliest(state.deadlines) {
        None -> {
          process.send(reply, None)
          actor.continue(state)
        }
        Some(due) -> {
          process.send(reply, Some(due.wake))
          actor.continue(State(
            now: int_max(state.now, due.at),
            deadlines: without(state.deadlines, due.at),
          ))
        }
      }
    Count(reply:) -> {
      process.send(reply, list.length(state.deadlines))
      actor.continue(state)
    }
    Shutdown -> actor.stop()
  }
}

fn earliest(deadlines: List(Deadline)) -> Option(Deadline) {
  list.fold(deadlines, None, fn(best: Option(Deadline), candidate: Deadline) {
    case best {
      Some(current) ->
        case current.at <= candidate.at {
          True -> best
          False -> Some(candidate)
        }
      None -> Some(candidate)
    }
  })
}

// Drops the first deadline due at `at` (the one `earliest` returned).
fn without(deadlines: List(Deadline), at: Int) -> List(Deadline) {
  case deadlines {
    [] -> []
    [first, ..rest] ->
      case first.at == at {
        True -> rest
        False -> [first, ..without(rest, at)]
      }
  }
}

fn int_max(a: Int, b: Int) -> Int {
  case a > b {
    True -> a
    False -> b
  }
}

/// The current logical time, in Unix milliseconds.
///
/// ## Examples
///
/// ```gleam
/// // vclock.now(vc)
/// ```
///
pub fn now(vc: Clockwork) -> Int {
  process.call_forever(vc.subject, Read)
}

/// A `core/clock.Clock` reading this simulated clock. Give it to the
/// session, the effects, and anything else that needs the time base.
///
/// ## Examples
///
/// ```gleam
/// // session.open_memory(vclock.clock(vc))
/// ```
///
pub fn clock(vc: Clockwork) -> Clock {
  clock.from_function(fn() { now(vc) })
}

/// The runtime timer seam backed by this clock: the driver's wakeups
/// become deadlines the runner fires, never wall-clock sleeps.
///
/// ## Examples
///
/// ```gleam
/// // effects.Effects(.., timers: vclock.timers(vc))
/// ```
///
pub fn timers(vc: Clockwork) -> effects.Timers {
  effects.Timers(after: fn(delay_ms, wake) {
    process.send(vc.subject, Schedule(delay_ms:, wake:))
  })
}

/// Number of deadlines waiting to fire.
///
/// ## Examples
///
/// ```gleam
/// // vclock.pending(vc) == 0
/// ```
///
pub fn pending(vc: Clockwork) -> Int {
  process.call_forever(vc.subject, Count)
}

/// Advances logical time to the earliest pending deadline and runs it,
/// reporting whether there was one. The wake runs in the caller's
/// process, so it must not call back into the clock.
///
/// ## Examples
///
/// ```gleam
/// // case vclock.advance(vc) { True -> "time moved" False -> "nothing due" }
/// ```
///
pub fn advance(vc: Clockwork) -> Bool {
  case process.call_forever(vc.subject, TakeEarliest) {
    None -> False
    Some(wake) -> {
      // On its own process: a wake aimed at a strand that has since died
      // may raise, and that must not reach the runner.
      let _pid = process.spawn_unlinked(wake)
      True
    }
  }
}

/// Blocks the calling process until `delay_ms` of logical time have
/// passed. Used by effect scripts that settle slowly: the process parks,
/// the session goes quiet, and the runner advances the clock to release
/// it.
///
/// ## Examples
///
/// ```gleam
/// // vclock.park(vc, 500)
/// ```
///
pub fn park(vc: Clockwork, delay_ms: Int) -> Nil {
  let woken: Subject(Nil) = process.new_subject()
  process.send(
    vc.subject,
    Schedule(delay_ms:, wake: fn() { process.send(woken, Nil) }),
  )
  process.receive_forever(woken)
}

/// Registers a deadline directly, for callers that are not the runtime's
/// timer seam — a doorbell the schedule asked to deliver late, say.
///
/// ## Examples
///
/// ```gleam
/// // vclock.schedule(vc, 250, fn() { ring() })
/// ```
///
pub fn schedule(vc: Clockwork, delay_ms: Int, wake: fn() -> Nil) -> Nil {
  process.send(vc.subject, Schedule(delay_ms:, wake:))
}

/// Stops the clock. Deadlines still in the wheel are discarded, as a
/// real timer's messages are when its owner dies.
///
/// ## Examples
///
/// ```gleam
/// // vclock.stop(vc)
/// ```
///
pub fn stop(vc: Clockwork) -> Nil {
  process.send(vc.subject, Shutdown)
}
