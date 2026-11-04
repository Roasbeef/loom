//// The gate that makes a workspace quiet for a capture (protocol-change/107,
//// "Open: Quiescence at a spawn").
////
//// The properties are the ones a snapshot needs: a capture never overlaps a tool
//// call, a call that arrives during a capture waits for it and is not lost, a
//// capture that cannot get a quiet workspace is refused and the gate reopens, and
//// a capture that holds on too long is released with a refusal and not a hang.
//// Time is real and the durations are tens of milliseconds, so each test is
//// about a second at most.

import client/internal/ffi_os
import client/workspace_gate.{type Gate}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/string
import host/bootstrap
import simplifile
import weft/registry

fn started() -> Gate {
  let assert Ok(names) = registry.start() as "the registry starts"
  let assert Ok(gate) = workspace_gate.start_at(registry.new_address(names))
    as "the gate starts"
  gate
}

// What a worker did and when, on the monotonic clock.
type Mark {
  Mark(what: String, at: Int)
}

fn mark(log: Subject(Mark), what: String) -> Nil {
  process.send(log, Mark(what:, at: bootstrap.monotonic_time_ms()))
}

fn collected(log: Subject(Mark), count: Int) -> List(Mark) {
  case count {
    0 -> []
    _ -> {
      let assert Ok(found) = process.receive(log, 5000)
        as "every worker reported"
      [found, ..collected(log, count - 1)]
    }
  }
}

fn at(marks: List(Mark), what: String) -> Int {
  let assert Ok(found) = list.find(marks, fn(each) { each.what == what })
    as "the mark is in the log"
  found.at
}

pub fn a_call_runs_while_the_gate_is_open_test() {
  let gate = started()
  assert workspace_gate.shared(gate, 1000, fn() { 42 }) == Ok(42)
}

// A capture waits for a call in flight and starts after it ends; a call that
// arrives during the capture starts after the capture ends. Nothing overlaps.
pub fn a_capture_and_a_tool_call_never_overlap_test() {
  let gate = started()
  let log = process.new_subject()

  // A call in flight.
  let _first =
    process.spawn(fn() {
      let _ =
        workspace_gate.shared(gate, 5000, fn() {
          mark(log, "first-start")
          process.sleep(150)
          mark(log, "first-end")
        })
      Nil
    })
  process.sleep(40)

  // The capture asks while the first call runs.
  let _capture =
    process.spawn(fn() {
      let _ =
        workspace_gate.exclusive(gate, 5000, 5000, fn() {
          mark(log, "capture-start")
          process.sleep(150)
          mark(log, "capture-end")
        })
      Nil
    })
  process.sleep(40)

  // A call that arrives with the capture waiting.
  let _second =
    process.spawn(fn() {
      let _ =
        workspace_gate.shared(gate, 5000, fn() {
          mark(log, "second-start")
          mark(log, "second-end")
        })
      Nil
    })
  let marks = collected(log, 6)
  assert at(marks, "first-end") <= at(marks, "capture-start")
  assert at(marks, "capture-end") <= at(marks, "second-start")
}

// The same property over a file: writers write whenever the gate lets them, the
// capture reads the file when it starts and again when it ends, and the two
// reads are equal however many writers were queued behind it. A write is a
// read, a pause and a rewrite, so a write that landed inside the capture would
// be visible in the second read.
pub fn a_concurrent_write_cannot_land_inside_a_capture_test() {
  let gate = started()
  let path =
    "build/gate-file-" <> int.to_string(ffi_os.unique_positive_integer())
  let assert Ok(Nil) = simplifile.write(path, "0") as "the file is made"
  let read = fn() {
    let assert Ok(text) = simplifile.read(path) as "the file is there"
    text
  }
  let write = fn() {
    let before = read()
    process.sleep(2)
    let assert Ok(Nil) = simplifile.write(path, before <> "+") as "written"
    Nil
  }

  list.each(list.repeat(Nil, 6), fn(_writer) {
    process.spawn(fn() {
      list.each(list.repeat(Nil, 25), fn(_step) {
        let _ = workspace_gate.shared(gate, 5000, write)
        process.sleep(1)
      })
    })
  })
  process.sleep(30)

  let seen =
    workspace_gate.exclusive(gate, 5000, 5000, fn() {
      let before = read()
      process.sleep(150)
      #(before, read())
    })
  let assert Ok(#(before, after)) = seen
  assert before == after
  assert string.length(before) > 1
    as "writers were running when the capture asked"
}

// A call in flight that outlasts the drain refuses the capture and does not
// close the gate: the next call runs at once.
pub fn a_workspace_that_will_not_go_quiet_refuses_the_capture_and_reopens_test() {
  let gate = started()
  let log = process.new_subject()
  let _slow =
    process.spawn(fn() {
      let _ =
        workspace_gate.shared(gate, 5000, fn() {
          mark(log, "slow-start")
          process.sleep(600)
        })
      Nil
    })
  process.sleep(40)
  assert workspace_gate.exclusive(gate, 100, 1000, fn() { "captured" })
    == Error(workspace_gate.NotQuiet)

  // The refusal reopened the gate, so a call is admitted while the slow one runs.
  assert workspace_gate.shared(gate, 1000, fn() { "ran" }) == Ok("ran")
}

// A capture that never comes back is cut loose at its hold: the gate reopens
// under it, the waiting call runs, and when the capture does return its answer is
// a refusal and not the value it computed.
pub fn a_stuck_capture_is_released_and_its_result_refused_test() {
  let gate = started()
  let log = process.new_subject()
  let _waiting =
    process.spawn(fn() {
      process.sleep(60)
      let outcome = workspace_gate.shared(gate, 5000, fn() { Nil })
      mark(log, case outcome {
        Ok(Nil) -> "call-ran"
        Error(workspace_gate.Busy) -> "call-busy"
      })
    })
  let started_at = bootstrap.monotonic_time_ms()
  let outcome =
    workspace_gate.exclusive(gate, 1000, 200, fn() {
      process.sleep(700)
      "mixed two writes"
    })
  assert outcome == Error(workspace_gate.Lapsed)

  // The call that waited ran at the hold's deadline, long before the capture
  // came back.
  let marks = collected(log, 1)
  assert at(marks, "call-ran") - started_at < 600
}

// A capture whose process dies while it holds the gate does not leave it closed.
pub fn a_capture_that_dies_holding_the_gate_releases_it_test() {
  let gate = started()
  let held = process.new_subject()
  let capture =
    process.spawn_unlinked(fn() {
      let _ =
        workspace_gate.exclusive(gate, 1000, 30_000, fn() {
          process.send(held, Nil)
          process.sleep(30_000)
        })
      Nil
    })
  let assert Ok(Nil) = process.receive(held, 2000)
    as "the capture holds the gate"
  process.kill(capture)
  assert workspace_gate.shared(gate, 2000, fn() { "ran" }) == Ok("ran")
}

// A call whose process dies in flight frees the drain a capture waits on.
pub fn a_call_that_dies_in_flight_frees_the_drain_test() {
  let gate = started()
  let entered = process.new_subject()
  let call =
    process.spawn_unlinked(fn() {
      let _ =
        workspace_gate.shared(gate, 2000, fn() {
          process.send(entered, Nil)
          process.sleep(30_000)
        })
      Nil
    })
  let assert Ok(Nil) = process.receive(entered, 2000) as "the call is in flight"
  process.kill(call)
  assert workspace_gate.exclusive(gate, 2000, 1000, fn() { "captured" })
    == Ok("captured")
}

// A call that waits longer than it will for a closed gate gives up with a
// reason, and the capture it waited for is untouched by the call's departure.
pub fn a_call_that_waits_too_long_at_a_closed_gate_is_busy_test() {
  let gate = started()
  let inside = process.new_subject()
  let _capture =
    process.spawn(fn() {
      let _ =
        workspace_gate.exclusive(gate, 1000, 5000, fn() {
          process.send(inside, Nil)
          process.sleep(400)
        })
      Nil
    })
  let assert Ok(Nil) = process.receive(inside, 2000)
    as "the capture holds the gate"
  assert workspace_gate.shared(gate, 80, fn() { Nil })
    == Error(workspace_gate.Busy)

  // The call that gave up was never admitted late: once the capture ends the
  // gate is open and nothing in flight keeps the next capture waiting.
  process.sleep(450)
  assert workspace_gate.exclusive(gate, 200, 1000, fn() { "quiet" })
    == Ok("quiet")
}

// The gate fails open for a call and closed for a capture. A session with no gate
// running has no capture to wait for, so its tool calls run; a capture asked of a
// gate that is not there has nothing to hold and is refused.
pub fn no_gate_lets_a_call_run_and_refuses_a_capture_test() {
  let assert Ok(names) = registry.start()
  let nowhere = workspace_gate.at(registry.new_address(names))
  assert workspace_gate.shared(nowhere, 100, fn() { "ran" }) == Ok("ran")
  assert workspace_gate.exclusive(nowhere, 100, 100, fn() { "captured" })
    == Error(workspace_gate.Unavailable)
}

// A gate that dies while a call waits at it lets the call run, and does not leave
// it to wait out its whole allowance.
pub fn a_gate_that_dies_under_a_waiting_call_lets_it_run_test() {
  let assert Ok(names) = registry.start()
  let address = registry.new_address(names)
  let held = process.new_subject()
  let started = process.new_subject()

  // The gate is started by a process we can kill, and held by a capture.
  let owner =
    process.spawn_unlinked(fn() {
      let assert Ok(gate) = workspace_gate.start_at(address)
      process.send(started, gate)
      process.sleep(30_000)
    })
  let assert Ok(gate) = process.receive(started, 2000) as "the gate starts"
  let _capture =
    process.spawn(fn() {
      let _ =
        workspace_gate.exclusive(gate, 1000, 30_000, fn() {
          process.send(held, Nil)
          process.sleep(30_000)
        })
      Nil
    })
  let assert Ok(Nil) = process.receive(held, 2000)
    as "the capture holds the gate"
  let waiting = process.new_subject()
  let _call =
    process.spawn(fn() {
      process.send(waiting, workspace_gate.shared(gate, 20_000, fn() { "ran" }))
    })
  process.sleep(100)
  process.kill(owner)
  assert process.receive(waiting, 3000) == Ok(Ok("ran"))
}
