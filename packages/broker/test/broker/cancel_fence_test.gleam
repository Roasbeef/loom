//// The single-sender fence, exercised: a cancel that arrives late cannot
//// reach the execution that reused its helper.
////
//// The executor service is the only process that sends a helper a `Run`, a
//// `Stdin` or a `CancelExec`. A relay that wants its execution cancelled asks
//// the service (`Link.cancel`), and the service sends the cancel only while
//// the execution's row is `Live`. Two things keep a relay's late cancel off
//// the next execution on a reused helper: Erlang orders one sender's messages
//// to one receiver, so a cancel the service sent for an execution precedes
//// any `Run` it sends for the next; and a request for an execution whose row
//// is gone or granted is dropped. A relay that sent to the helper itself
//// would be a second sender, and nothing would order its cancel before that
//// `Run`.
////
//// The absorbing relay core never cancels after settling, so a real relay
//// does not produce a stale cancel, and no test of the real path could fail
//// if the fence were gone. These tests produce the stale cancel by hand. A
//// helper runs one execution that ends by itself, is returned and runs a
//// second that sleeps; then the first execution's relay link is called, late.
//// Through the link the service builds, nothing happens to the second
//// execution. Through a link that sends to the helper directly, as a control,
//// the second execution is cancelled, which shows the hazard is real and
//// that the test can see it. The mutation that proves the first test is
//// recorded in the commit that added it: sending directly from `link_over`
//// makes it fail.

import broker/dispatch
import broker/exec
import broker/executor
import broker/relay
import broker/support/fake_helper
import broker/support/planes
import core/clock
import gleam/erlang/process
import gleam/option.{None}
import weft/poll

// A dispatch built by hand, with the argv `ByArgv` reads: `ok` ends at once
// and `sleep` runs until cancelled.
fn dispatch_of(
  seq: Int,
  word: String,
  settlements: process.Subject(dispatch.Terminal),
) -> dispatch.Dispatch {
  dispatch.Dispatch(
    system_reservation: None,
    context: dispatch.CallContext(
      operation: planes.op(),
      step: "fixture",
      origin: None,
    ),
    request: exec.ExecRequest(
      argv: [word],
      env: [],
      cwd: "/work",
      policy: None,
      token: <<0:size(32)-unit(8)>>,
      demand: exec.BestEffort,
    ),
    seq:,
    deadline_ms: 0,
    clock: clock.fixed(at: 1000),
    caller: None,
    deliver: fn(_chunk) { Nil },
    settle: fn(terminal) { process.send(settlements, terminal) },
  )
}

// Starts the second execution once the pool lends the returned helper again.
// The broker's release is a cast to the pool, so the first `start` can find
// the pool still busy.
fn start_second(
  dispatcher: dispatch.Dispatcher,
  settlements: process.Subject(dispatch.Terminal),
) -> dispatch.Execution {
  let assert poll.Answered(second) =
    poll.until(within: 3000, every: 10, attempt: fn() {
      case dispatcher.start(dispatch_of(2, "sleep", settlements)) {
        Ok(second) -> poll.Done(second)
        Error(dispatch.NoHelper(error: exec.AllBusy(..))) -> poll.Retry
        Error(refusal) -> poll.Fail(refusal)
      }
    })
    as "the second execution started on the returned helper"
  second
}

// Runs one execution to its end by itself, returns the helper, starts a second
// that sleeps on the same helper, and then calls the first execution's relay
// link's `cancel`, which is the stale cancel. Answers what the second
// execution did in the half second after.
fn stale_cancel_outcome(
  link_of: fn(executor.Executor, dispatch.ExecutionId, exec.Helper) ->
    relay.Link,
) -> Result(dispatch.Terminal, Nil) {
  let plane =
    planes.start_scripted(size: 1, script: fn() {
      fake_helper.start_helper(fake_helper.ByArgv)
    })
  let dispatcher = executor.dispatcher(plane.service)
  let first_settlements = process.new_subject()
  let second_settlements = process.new_subject()

  let assert Ok(first) =
    dispatcher.start(dispatch_of(1, "ok", first_settlements))
  let assert Ok(helper) = process.receive(plane.borrowed, 1000)
    as "the first execution borrowed the helper"
  let assert Ok(dispatch.Completed(_)) =
    process.receive(first_settlements, 2000)
  first.release()

  let second = start_second(dispatcher, second_settlements)
  let assert Ok(reused) = process.receive(plane.borrowed, 1000)
  assert exec.pid(reused) == exec.pid(helper) as "the helper was reused"

  // The relay of the first execution, late: it decided to cancel before its
  // execution ended, and the cancel is only now sent.
  let stale = link_of(plane.service, first.id, helper)
  stale.cancel()
  let outcome = process.receive(second_settlements, 500)

  // Whatever happened, end the second execution so the plane can stop.
  second.cancel()
  let _ = process.receive(second_settlements, 1000)
  second.release()
  planes.stop(plane)
  outcome
}

/// Through the link the service builds, a stale cancel for an execution whose
/// row is gone is dropped, and the second execution on the reused helper runs
/// on. A relay that cancelled the helper directly, instead of asking the
/// service, makes this fail.
pub fn a_stale_relay_cancel_never_reaches_the_next_execution_test() {
  assert stale_cancel_outcome(fn(service, id, _helper) {
      executor.relay_link(service, id)
    })
    == Error(Nil)
}

/// The control: a link whose cancel goes straight to the helper reaches the
/// second execution, because the helper cannot tell whose cancel it is. This
/// is the hazard the single sender removes, and it is what makes the test
/// above able to fail.
pub fn a_relay_cancelling_the_helper_directly_cancels_the_next_execution_test() {
  let direct = fn(_service, _id, helper) {
    relay.Link(
      cancel: fn() { exec.cancel(helper) },
      may_settle: fn(_verdict) { relay.AlreadySettled },
      progress: fn(_progress) { Nil },
    )
  }
  let assert Ok(dispatch.Completed(result)) = stale_cancel_outcome(direct)
  assert result.cancelled
}
