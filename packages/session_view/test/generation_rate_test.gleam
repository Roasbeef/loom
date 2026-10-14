//// Per-strand clocks survive view changes and consume only complete windows.

import gleam/option.{None, Some}
import session_view/generation_rate

pub fn simultaneous_generations_settle_independently_test() {
  let state =
    generation_rate.new()
    |> generation_rate.phase(
      "main",
      "assistant",
      generation_rate.Transition,
      1000,
    )
    |> generation_rate.phase(
      "worker",
      "assistant",
      generation_rate.Transition,
      2000,
    )
    |> generation_rate.settle("worker", 600, 4000)
  assert generation_rate.rate(state, "worker") == Some(300)
  assert generation_rate.rate(state, "main") == None
  assert generation_rate.started(state, "main") == Some(1000)
  let state = generation_rate.settle(state, "main", 500, 6000)
  assert generation_rate.rate(state, "main") == Some(100)
  assert generation_rate.rate(state, "worker") == Some(300)
}

pub fn a_partial_first_capture_never_times_the_full_output_count_test() {
  let state =
    generation_rate.new()
    |> generation_rate.phase(
      "worker",
      "assistant",
      generation_rate.Capture,
      4000,
    )
    |> generation_rate.stream("worker", "generation-1", "text", 4500)
    |> generation_rate.settle("worker", 800, 5000)
  assert generation_rate.rate(state, "worker") == None
  assert generation_rate.started(state, "worker") == None

  // Repeated captures and late fragments cannot restart a consumed request.
  let state =
    state
    |> generation_rate.phase(
      "worker",
      "assistant",
      generation_rate.Capture,
      5500,
    )
    |> generation_rate.stream("worker", "generation-1", "text", 5600)
  assert generation_rate.started(state, "worker") == None
  let state =
    state
    |> generation_rate.phase("worker", "tools", generation_rate.Capture, 6000)
    |> generation_rate.phase(
      "worker",
      "assistant",
      generation_rate.Capture,
      7000,
    )
    |> generation_rate.settle("worker", 400, 9000)
  assert generation_rate.rate(state, "worker") == Some(200)
}

pub fn new_generation_identity_cannot_reuse_an_older_window_test() {
  let state =
    generation_rate.new()
    |> generation_rate.phase(
      "worker",
      "assistant",
      generation_rate.Transition,
      1000,
    )
    |> generation_rate.stream("worker", "first", "text", 1100)
    |> generation_rate.stream("worker", "second", "text", 4000)
    |> generation_rate.settle("worker", 800, 5000)
  assert generation_rate.rate(state, "worker") == None
}

pub fn done_session_reset_and_roster_removal_retire_clocks_test() {
  let state =
    generation_rate.new()
    |> generation_rate.phase(
      "worker",
      "assistant",
      generation_rate.Transition,
      1000,
    )
    |> generation_rate.phase("worker", "done", generation_rate.Transition, 1500)
    |> generation_rate.settle("worker", 800, 5000)
  assert generation_rate.rate(state, "worker") == None
  let state = generation_rate.retain(state, ["main"])
  let state =
    generation_rate.phase(
      state,
      "worker",
      "assistant",
      generation_rate.Capture,
      6000,
    )
    |> generation_rate.settle("worker", 800, 7000)
  assert generation_rate.rate(state, "worker") == None
}
