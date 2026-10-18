//// Running the branches of a parallel case at once and recording what each
//// call saw.
////
//// A race is only a race if the contenders start together. Spawning one
//// process per branch and letting each begin as soon as it is scheduled would
//// run the first branch's opening calls before the last branch exists, and the
//// interleavings worth testing, the ones where calls overlap, would be rare.
//// So each branch process announces itself and parks until the coordinator has
//// heard from all of them, and only then does the coordinator release them
//// with one `Go` apiece. That is the whole of the scheduling help this layer
//// gives; it does not control or observe the scheduler beyond it.
////
//// The branches run as one weft run, which is what owns them. Weft links every
//// worker to its scope, bounds the whole phase with a deadline that kills and
//// joins what has not finished, and accounts for every branch with exactly one
//// outcome, so a branch that hangs, crashes or is cut off cannot leave a
//// process behind or go unreported. The scope's slot limit is set to the number
//// of branches, because the default is the number of schedulers and a barrier
//// between more branches than slots would wait forever.
////
//// ## Time
////
//// Each call is bracketed by two reads of weft's monotonic clock, taken in the
//// branch's own process, in milliseconds. A millisecond is coarse: calls to an
//// in-memory system often fit in one. The checker reads equal instants as
//// overlap, so coarseness hides ordering constraints and never invents one.
////
//// ## Flow
////
//// `race` → `release` → `collect` → `settle`
////
//// 1. `race` starts the branches detached, so the coordinator is free to wait.
//// 2. `release` waits for every branch's go subject and sends each a `Go`.
//// 3. `collect` pulls the outcomes until the run reports it has delivered
////    them all.
//// 4. `settle` turns the outcomes into the histories or the one violation
////    that explains why there are none.

import exception
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/string
import statem.{type Violation, Violation}
import statem/linearize.{type Event, Event}
import weft
import weft/poll

/// The message that releases a parked branch.
type Go {
  Go
}

/// How long `collect` waits past the run's own deadline before cancelling,
/// and again after cancelling before it gives up on the scope. The weft
/// deadline normally ends the run first; this is the margin for it to do so.
const grace = 2000

/// Run every branch at once against `sut` and return one history per branch,
/// in the order the branches were given. A call that raises is a
/// `statem.crash` violation, and a phase that does not finish within `within`
/// milliseconds is a `statem.timeout` one.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(histories) = runner.race(run, sut, [[Increment], [Increment]], 10_000)
/// ```
pub fn race(
  run: fn(sut, cmd) -> response,
  sut: sut,
  branches: List(List(cmd)),
  within: Int,
) -> Result(List(List(Event(cmd, response))), Violation) {
  case branches {
    [] -> Ok([])

    _ -> {
      let started = process.new_subject()
      let now = poll.monotonic().now
      let count = list.length(branches)

      let detached =
        branches
        |> list.map(fn(commands) {
          fn() { branch(run, sut, commands, started, now, within) }
        })
        |> weft.new
        |> weft.limit(count)
        |> weft.deadline(within)
        |> weft.start_detached

      case release(started, count, within) {
        Ok(Nil) -> collect(detached, within + grace)

        // A branch that never reached the barrier is a phase that did not
        // finish; the run is cancelled so nothing is left parked.
        Error(Nil) -> {
          weft.cancel_detached(detached)
          let _ = collect(detached, grace)

          Error(timeout("a branch never reached the start barrier"))
        }
      }
    }
  }
}

/// The body of one branch's process. It parks first so that all branches begin
/// together, then makes its calls in order, bracketing each with the clock.
fn branch(
  run: fn(sut, cmd) -> response,
  sut: sut,
  commands: List(cmd),
  started: Subject(Subject(Go)),
  now: fn() -> Int,
  within: Int,
) -> Result(List(Event(cmd, response)), Violation) {
  let go = process.new_subject()
  process.send(started, go)

  // The release has to arrive within the phase's own bound; a coordinator
  // that died would otherwise leave this process parked until the scope's
  // deadline killed it.
  case process.receive(go, within) {
    Error(Nil) -> Error(timeout("a branch was never released"))
    Ok(Go) -> calls(run, sut, commands, now, [])
  }
}

/// Make the branch's calls one after another. The instants are read inside
/// the branch's own process, around the call and nothing else, so a slow
/// coordinator cannot widen a call's interval.
fn calls(
  run: fn(sut, cmd) -> response,
  sut: sut,
  commands: List(cmd),
  now: fn() -> Int,
  recorded: List(Event(cmd, response)),
) -> Result(List(Event(cmd, response)), Violation) {
  case commands {
    [] -> Ok(list.reverse(recorded))

    [command, ..rest] -> {
      let invoked_at = now()

      case exception.rescue(fn() { run(sut, command) }) {
        Error(crash) -> Error(statem.crashed("run", crash))

        Ok(response) -> {
          let event =
            Event(
              cmd: command,
              response: response,
              invoked_at: invoked_at,
              returned_at: now(),
            )

          calls(run, sut, rest, now, [event, ..recorded])
        }
      }
    }
  }
}

/// Wait until `count` branches have announced themselves, then send each its
/// release. Releasing only after the last arrival is the barrier. `Error`
/// means one did not arrive within the bound.
fn release(
  started: Subject(Subject(Go)),
  count: Int,
  within: Int,
) -> Result(Nil, Nil) {
  case arrivals(started, count, within, []) {
    Ok(subjects) -> {
      list.each(subjects, fn(go) { process.send(go, Go) })
      Ok(Nil)
    }

    Error(Nil) -> Error(Nil)
  }
}

/// Collect `count` go subjects, one receive at a time.
fn arrivals(
  started: Subject(Subject(Go)),
  count: Int,
  within: Int,
  seen: List(Subject(Go)),
) -> Result(List(Subject(Go)), Nil) {
  case count <= 0 {
    True -> Ok(seen)

    False ->
      case process.receive(started, within) {
        Ok(go) -> arrivals(started, count - 1, within, [go, ..seen])
        Error(Nil) -> Error(Nil)
      }
  }
}

/// What one branch's task delivers: its history, or the violation that
/// stopped it.
type Outcome(cmd, response) =
  weft.Outcome(List(Event(cmd, response)), Violation)

/// Pull outcomes until the run has delivered every one. A pull that finds
/// nothing in time cancels the run once and pulls again, so a stuck scope is
/// asked to stop before it is given up on, and the second silence is reported
/// rather than waited out.
fn collect(
  detached: weft.Detached(List(Event(cmd, response)), Violation),
  within: Int,
) -> Result(List(List(Event(cmd, response))), Violation) {
  case pull_all(detached, within, [], Asked) {
    Ok(outcomes) -> settle(outcomes)
    Error(violation) -> Error(violation)
  }
}

/// Whether `pull_all` has already cancelled the run once.
type Cancelled {
  Asked
  Cancelled
}

/// Pull until `AllDelivered`, accumulating outcomes in completion order.
fn pull_all(
  detached: weft.Detached(List(Event(cmd, response)), Violation),
  within: Int,
  gathered: List(Outcome(cmd, response)),
  cancelled: Cancelled,
) -> Result(List(Outcome(cmd, response)), Violation) {
  case weft.pull(detached, within) {
    weft.PulledOutcome(outcome) ->
      pull_all(detached, within, [outcome, ..gathered], cancelled)

    weft.AllDelivered -> Ok(gathered)

    weft.NotYet ->
      case cancelled {
        Asked -> {
          weft.cancel_detached(detached)
          pull_all(detached, grace, gathered, Cancelled)
        }

        Cancelled -> Error(timeout("the branches did not stop when cancelled"))
      }

    weft.RunLost(reason) ->
      Error(Violation(
        tag: "statem.crash",
        detail: "the branch scope was lost: " <> string.inspect(reason),
      ))
  }
}

/// Turn what the run delivered into histories or the violation that explains
/// their absence. A crash outranks a timeout: a branch that raised often
/// leaves its siblings waiting, and the raise is the cause.
fn settle(
  outcomes: List(Outcome(cmd, response)),
) -> Result(List(List(Event(cmd, response))), Violation) {
  // Weft gives every task exactly one outcome before it reports the run
  // delivered, so there is one result per branch and none to count.
  outcomes
  |> list.map(verdict_of)
  |> list.sort(fn(left, right) { int.compare(left.0, right.0) })
  |> list.map(fn(entry) { entry.1 })
  |> first_problem
}

/// One branch's index and what became of it.
fn verdict_of(
  outcome: Outcome(cmd, response),
) -> #(Int, Result(List(Event(cmd, response)), Violation)) {
  case outcome {
    weft.Completed(index, events) -> #(index, Ok(events))
    weft.Failed(index, violation) -> #(index, Error(violation))

    weft.Crashed(index, reason) -> #(
      index,
      Error(Violation(
        tag: "statem.crash",
        detail: "a branch process died: " <> string.inspect(reason),
      )),
    )

    weft.Abandoned(index) -> #(
      index,
      Error(timeout("a branch did not finish within the deadline")),
    )

    weft.NeverStarted(index) -> #(
      index,
      Error(timeout("a branch never started before the deadline")),
    )

    weft.DrainProofLost(index, reason) -> #(
      index,
      Error(Violation(
        tag: "statem.crash",
        detail: "a branch lost its drain proof: " <> string.inspect(reason),
      )),
    )

    weft.CancellationUnconfirmed(index) -> #(
      index,
      Error(timeout("a branch did not confirm cancellation")),
    )
  }
}

/// The histories if every branch completed, else the most telling violation:
/// the first one that is not a timeout, and failing that the first timeout.
fn first_problem(
  results: List(Result(List(Event(cmd, response)), Violation)),
) -> Result(List(List(Event(cmd, response))), Violation) {
  let problems =
    list.filter_map(results, fn(result) {
      case result {
        Ok(_) -> Error(Nil)
        Error(violation) -> Ok(violation)
      }
    })

  case problems {
    [] -> Ok(list.filter_map(results, fn(result) { result }))

    [first, ..] ->
      case list.find(problems, fn(violation) { violation.tag != timeout_tag }) {
        Ok(cause) -> Error(cause)
        Error(Nil) -> Error(first)
      }
  }
}

/// The tag every deadline violation carries, so a timeout shrinks to a
/// timeout whatever its detail.
pub const timeout_tag = "statem.timeout"

fn timeout(detail: String) -> Violation {
  Violation(tag: timeout_tag, detail: detail)
}
