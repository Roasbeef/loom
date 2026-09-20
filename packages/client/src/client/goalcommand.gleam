//// The gateway's six goal commands over the advisor actor's address.
////
//// The actor is the goal cell's only writer, so every operator command
//// routes to it rather than to the store: the status transitions happen
//// where the loop's bookkeeping lives, and a second writer would race
//// the loop's own writes. This module is the seam between the gateway —
//// which must not depend on the actor's internals — and the advisor's
//// wiring, the same arrangement the `advise` tool's `Advice` seam and
//// the `goal_abort` notice take.
////
//// Each command is a call with a bounded wait, because the operator is
//// waiting for the answer; an actor that cannot answer inside the bound
//// is reported as unavailable rather than retried, since the actor may
//// be mid-scan on a branch and a connection is not entitled to wait out
//// a review behind it.

import client/advisor
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option}
import weft/registry as address

/// How long one goal command waits for the actor. The status flips are
/// single cell writes, so five seconds is generous against a host whose
/// actor is mid-review; a busier answer is an unavailable plane, which
/// the gateway reports and the operator retries.
const command_timeout_ms = 5000

/// The six calls the gateway makes, filled from the advisor's wiring.
/// One record rather than six fields because the wiring is one value
/// and the gateway holds one option of it.
pub type Seam {
  Seam(
    /// Pins or replaces the goal, optionally with the check to run before
    /// each feed.
    set: fn(String, Int, Option(String)) -> Result(Nil, String),
    /// Sets the check on the goal that is already pinned, or clears it
    /// with `None`. Its own call rather than a `set` with an unchanged
    /// objective, because that is defined as a refresh and would clear the
    /// loop's bound counters.
    set_check: fn(Option(String)) -> Result(Nil, String),
    /// Clears the goal.
    clear: fn() -> Result(Nil, String),
    /// Holds the goal.
    pause: fn() -> Result(Nil, String),
    /// Continues a held or tripped goal.
    resume: fn() -> Result(Nil, String),
  )
}

/// The seam over an advisor wiring.
pub fn seam(wiring: advisor.Wiring) -> Seam {
  let named: address.Address(advisor.Message) = wiring.name

  Seam(
    set: fn(objective, budget, check) {
      call(named, fn(reply: Subject(Result(Nil, String))) {
        advisor.SetGoal(objective:, token_budget: budget, check:, reply:)
      })
    },
    set_check: fn(command) {
      call(named, fn(reply: Subject(Result(Nil, String))) {
        advisor.SetGoalCheck(command:, reply:)
      })
    },
    clear: fn() {
      call(named, fn(reply: Subject(Result(Nil, String))) {
        advisor.ClearGoal(reply:)
      })
    },
    pause: fn() {
      call(named, fn(reply: Subject(Result(Nil, String))) {
        advisor.PauseGoal(reply:)
      })
    },
    resume: fn() {
      call(named, fn(reply: Subject(Result(Nil, String))) {
        advisor.ResumeGoal(reply:)
      })
    },
  )
}

// One bounded call over the wiring's registered address, the same
// monitored send-and-select the `advise` seam takes: a dead or timed-out
// actor is an answer the operator reads, never the caller's exit. The
// registry resolves a restarted actor under the same name, which is the
// restart-safety the wiring exists for.
fn call(
  named: address.Address(advisor.Message),
  build: fn(Subject(Result(answer, String))) -> advisor.Message,
) -> Result(answer, String) {
  // The outer layer is the call itself — a dead actor, or one that did
  // not answer inside the bound — and the inner layer is the actor's
  // own refusal. Both are the operator's answer, so the two flatten:
  // there is no case where an unavailable plane should read as a
  // committed command.
  case advisor.ask(named, command_timeout_ms, build) {
    Ok(Ok(value)) -> Ok(value)
    Ok(Error(refusal)) -> Error(refusal)
    Error(Nil) -> Error("the goal plane is unavailable")
  }
}
