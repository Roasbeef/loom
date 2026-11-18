//// How a live page of a session on another orchestrator waits for its
//// orchestrator without ending its socket (`client/daemon/ui_wait`).
////
//// The socket closes with a retry only when the run calls `done`, so what these
//// tests hold is when `done` is called: never while the orchestrator is silent,
//// once when it answers, and once when the wait runs out. Each ask hands the
//// test a reply subject of its own and blocks on it, so the test decides every
//// answer and sees every ask in order. Nothing here waits for time to pass to
//// prove an ordering.

import client/daemon/ui_wait
import client/remote/top_relay
import client/remote_top
import gleam/erlang/process.{type Subject}

const patience_ms = 5000

// The question a page asks: it announces itself with a reply subject, which the
// asking process owns, and returns what the test sends to it.
fn asking(asked: Subject(Subject(ui_wait.Reach))) -> fn() -> ui_wait.Reach {
  fn() {
    let answer = process.new_subject()
    process.send(asked, answer)
    case process.receive(answer, patience_ms) {
      Ok(reach) -> reach
      Error(Nil) -> ui_wait.Silent
    }
  }
}

fn short() -> ui_wait.Timing {
  ui_wait.Timing(first_pause_ms: 5, longest_pause_ms: 20, max_wait_ms: 30_000)
}

// A box that stays down is asked again and again and the socket is never told
// to close. The first answer closes it, once, and the asks stop.
pub fn a_silent_box_never_closes_the_socket_and_an_answer_closes_it_once_test() {
  let asked = process.new_subject()
  let done = process.new_subject()
  ui_wait.start(short(), ui_wait.AskAtOnce, asking(asked), fn() {
    process.send(done, Nil)
  })

  // Three asks are answered with silence. Each is a barrier: the ask is made
  // before the test sees it, so a close that had been sent would be in `done`.
  let assert Ok(first) = process.receive(asked, patience_ms) as "first ask"
  assert process.receive(done, 0) == Error(Nil)
  process.send(first, ui_wait.Silent)

  let assert Ok(second) = process.receive(asked, patience_ms) as "second ask"
  assert process.receive(done, 0) == Error(Nil)
  process.send(second, ui_wait.Silent)

  let assert Ok(third) = process.receive(asked, patience_ms) as "third ask"
  assert process.receive(done, 0) == Error(Nil)
  process.send(third, ui_wait.Answering)

  // The answer ends the loop: `done` arrives, and no ask followed the one that
  // was answered, since the loop made it before it called `done`.
  let assert Ok(Nil) = process.receive(done, patience_ms) as "the close"
  assert process.receive(asked, 0) == Error(Nil)
  assert process.receive(done, 0) == Error(Nil)
}

// An orchestrator that never answers does not hold the socket for ever: the
// wait runs out and the socket closes, so the reconnect meets the page's real
// standing.
pub fn a_wait_that_runs_out_closes_the_socket_once_test() {
  let done = process.new_subject()
  ui_wait.start(
    ui_wait.Timing(first_pause_ms: 2, longest_pause_ms: 4, max_wait_ms: 40),
    ui_wait.AskAtOnce,
    fn() { ui_wait.Silent },
    fn() { process.send(done, Nil) },
  )

  let assert Ok(Nil) = process.receive(done, patience_ms) as "the close"
  assert process.receive(done, 0) == Error(Nil)
}

// A call to the orchestrator that failed to reach it is silence, and any other
// result, a refusal included, is an answer.
pub fn only_a_call_that_did_not_reach_the_box_is_silence_test() {
  assert ui_wait.reach_of(Ok(Nil)) == ui_wait.Answering
  assert ui_wait.reach_of(Error(top_relay.Unreachable)) == ui_wait.Silent
  assert ui_wait.reach_of(Error(top_relay.Silent)) == ui_wait.Silent
  assert ui_wait.reach_of(Error(top_relay.PeerChanged)) == ui_wait.Silent
  assert ui_wait.reach_of(Error(top_relay.Unsupported)) == ui_wait.Answering
  assert ui_wait.reach_of(
      Error(top_relay.Refused(remote_top.NotYetOpen(reason: "opening"))),
    )
    == ui_wait.Answering
}

// A page whose own standing ended while it waited closes at the next ask
// without the box answering: the probe is never made.
pub fn a_revoked_page_closes_without_asking_the_box_test() {
  let asked = process.new_subject()
  let done = process.new_subject()
  let awaiting = fn() {
    ui_wait.checked(fn() { Error("revoked") }, fn() {
      process.send(asked, process.new_subject())
      ui_wait.Silent
    })
  }
  ui_wait.start(short(), ui_wait.AskAtOnce, awaiting, fn() {
    process.send(done, Nil)
  })

  let assert Ok(Nil) = process.receive(done, patience_ms) as "the close"
  assert process.receive(asked, 0) == Error(Nil)

  // A page that is still open asks the box.
  assert ui_wait.checked(fn() { Ok(Nil) }, fn() { ui_wait.Silent })
    == ui_wait.Silent
}

// A page whose attach was refused as a wait pauses before its first ask, so the
// close and reopen cannot repeat faster than the pause.
pub fn a_page_refused_as_a_wait_pauses_before_it_asks_test() {
  let asked = process.new_subject()
  let done = process.new_subject()
  ui_wait.start(
    ui_wait.Timing(
      first_pause_ms: 150,
      longest_pause_ms: 150,
      max_wait_ms: 30_000,
    ),
    ui_wait.PauseFirst,
    fn() {
      process.send(asked, process.new_subject())
      ui_wait.Answering
    },
    fn() { process.send(done, Nil) },
  )

  // Nothing has been asked for most of the pause, then the ask and the close.
  assert process.receive(asked, 50) == Error(Nil)
  let assert Ok(_) = process.receive(asked, patience_ms) as "the ask"
  let assert Ok(Nil) = process.receive(done, patience_ms) as "the close"
}
