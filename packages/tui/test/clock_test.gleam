//// Presentation timing under a caller-owned clock.
////
//// These tests drive the shipped event handler, not just its arithmetic.
//// Negative epochs catch accidental comparisons with the host clock; no
//// sleep or scheduling tolerance determines a frame or throughput result.

import etui/backend
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import tui
import tui/connection
import tui/frame
import tui/virtual_backend
import tui/workspace
import tui_test/gateway

fn initial(now: Int) -> tui.Model {
  tui.new_model_with_clock(
    connection.new_inbox(),
    workspace.Context(path: "/test/workspace", branch: None),
    fn() { now },
  )
}

fn at(model: tui.Model, now: Int) -> tui.Model {
  tui.Model(..model, monotonic_time_ms: fn() { now })
}

fn deliver(model: tui.Model, wire: String) -> tui.Model {
  process.send(model.inbox, connection.Incoming(wire))
  tui.update(backend.Tick, model)
}

pub fn initial_frame_uses_the_injected_epoch_test() {
  let model = initial(-10_000)
  assert model.last_frame_ms == -10_000
  assert model.monotonic_time_ms() == -10_000
}

pub fn real_event_handler_paces_frames_on_the_injected_clock_test() {
  let drawn = tui.update(backend.Resize(80, 24), initial(-10_000))
  let deferred = tui.update(backend.KeyPress("a"), at(drawn, -9999))
  assert deferred.frame_debt == tui.FrameDeferred
  assert deferred.last_frame_ms == -10_000
  assert deferred.frame_cache == drawn.frame_cache

  let refreshed = tui.update(backend.KeyPress("b"), at(deferred, -9984))
  assert refreshed.frame_debt == tui.FrameSettled
  assert refreshed.last_frame_ms == -9984
  assert refreshed.frame_cache != drawn.frame_cache

  let again = tui.update(backend.KeyPress("c"), at(refreshed, -9983))
  assert again.frame_debt == tui.FrameDeferred
  let flushed = tui.update(backend.Tick, again)
  assert flushed.frame_debt == tui.FrameSettled
  assert flushed.last_frame_ms == -9983
}

pub fn generation_and_usage_measure_one_injected_clock_test() {
  let started =
    initial(-10_000)
    |> deliver(
      "{\"v\":1,\"event\":\"op_transition\",\"body\":{\"strand\":\"main\",\"phase\":\"assistant\"}}",
    )
  assert started.generation_started_ms == Some(-10_000)

  let streaming =
    started
    |> at(-9500)
    |> deliver(gateway.stream_delta("main", "text", "answer"))
  assert streaming.generation_started_ms == Some(-10_000)

  let settled =
    streaming
    |> at(-8000)
    |> deliver(gateway.usage("main", 10, 300, 0.0))
  assert settled.output_rate_tps == Some(150)
  assert settled.generation_started_ms == None
}

pub fn stream_fallback_uses_the_injected_clock_test() {
  let other =
    initial(-10_000)
    |> deliver(gateway.stream_delta("another", "text", "other answer"))
  assert other.generation_started_ms == None

  let started = deliver(other, gateway.stream_delta("main", "text", "answer"))
  assert started.generation_started_ms == Some(-10_000)
  let settled =
    started
    |> at(-9999)
    |> deliver(gateway.usage("main", 10, 300, 0.0))
  assert settled.output_rate_tps == None
}

pub fn activity_elapsed_time_uses_the_injected_clock_test() {
  let live =
    initial(-10_000)
    |> deliver(
      "{\"v\":1,\"event\":\"op_transition\",\"body\":{\"strand\":\"main\",\"phase\":\"assistant\"}}",
    )
    |> tui.update(backend.Tick, _)
  assert live.activity_started_ms == Some(-10_000)

  let later = tui.update(backend.Tick, at(live, -7000))
  assert later.activity_elapsed_s == 3
  let stopped =
    later
    |> deliver(
      "{\"v\":1,\"event\":\"op_transition\",\"body\":{\"strand\":\"main\",\"phase\":\"done\"}}",
    )
    |> tui.update(backend.Tick, _)
  assert stopped.activity_started_ms == None
  assert stopped.activity_elapsed_s == 0
}

pub fn scripted_intermediate_frames_repeat_with_a_fixed_clock_test() {
  assert scripted_frames() == scripted_frames()
}

fn scripted_frames() -> List(String) {
  let model = initial(-10_000)
  let script =
    virtual_backend.script(
      backend.TerminalSize(width: 80, height: 24),
      [
        virtual_backend.Input(backend.KeyPress("a")),
        virtual_backend.Input(backend.KeyPress("b")),
        virtual_backend.Input(backend.Tick),
      ],
      model.inbox,
    )
  let assert Ok(run) = tui.run_script(model, script)
    as "the shipped loop must run under an injected presentation clock"
  assert list.length(run.frames) == 6
  assert run.final.last_frame_ms == -10_000
  list.map(run.frames, frame.buffer_to_text)
}
