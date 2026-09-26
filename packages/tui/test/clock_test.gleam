//// Presentation timing under a caller-owned clock.
////
//// These tests drive the shipped event handler, not just its arithmetic.
//// Negative epochs catch accidental comparisons with the host clock; no
//// sleep or scheduling tolerance determines a frame or throughput result.
////
//// The clocks are read once per event, by `runtime.stamp` inside
//// `tui.update`, and the step itself reads none of them. The last group of
//// tests pins that split: the step works with a presentation clock that
//// panics when called, `update` calls it exactly once per event, and the
//// session lane's refresh and deadline follow the reading it is passed.

import etui/backend
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import tui
import tui/connection
import tui/frame
import tui/model as tui_model
import tui/pacing
import tui/session_channel
import tui/snapshot
import tui/virtual_backend
import tui/workspace
import tui_test/gateway
import tui_test/pushed

fn initial(now: Int) -> tui_model.Model {
  tui.new_model_with_clock(
    connection.new_inbox(),
    workspace.Context(path: "/test/workspace", branch: None),
    fn() { now },
  )
}

fn at(model: tui_model.Model, now: Int) -> tui_model.Model {
  tui_model.Model(..model, monotonic_time_ms: fn() { now })
}

fn deliver(model: tui_model.Model, wire: String) -> tui_model.Model {
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
  assert deferred.frame_debt == pacing.FrameDeferred
  assert deferred.last_frame_ms == -10_000
  assert deferred.frame_cache == drawn.frame_cache

  let refreshed = tui.update(backend.KeyPress("b"), at(deferred, -9984))
  assert refreshed.frame_debt == pacing.FrameSettled
  assert refreshed.last_frame_ms == -9984
  assert refreshed.frame_cache != drawn.frame_cache

  let again = tui.update(backend.KeyPress("c"), at(refreshed, -9983))
  assert again.frame_debt == pacing.FrameDeferred
  let flushed = tui.update(backend.Tick, again)
  assert flushed.frame_debt == pacing.FrameSettled
  assert flushed.last_frame_ms == -9983
}

pub fn wheel_then_press_captures_one_painted_copy_layout_test() {
  let lines =
    list.repeat(Nil, 12)
    |> list.index_map(fn(_, index) {
      case index % 2 {
        0 -> tui_model.Line(tui_model.User, "  user " <> int.to_string(index))
        _ ->
          tui_model.Line(
            tui_model.Assistant,
            "assistant " <> int.to_string(index),
          )
      }
    })
  let drawn =
    tui_model.Model(..initial(-10_000), transcript: lines)
    |> tui.update(backend.Resize(50, 12), _)
  let assert Some(tui_model.FrameCache(
    rendered: #(painted, _),
    selection_gutters: painted_gutters,
    ..,
  )) = drawn.frame_cache
  let scrolled =
    drawn
    |> at(-10_000)
    |> tui.update(backend.MouseScroll(5, 5, True), _)

  assert scrolled.scroll_offset != drawn.scroll_offset
    as "premise: the wheel moved the model's viewport"
  assert scrolled.frame_cache == drawn.frame_cache
    as "the frozen clock keeps the old frame painted"

  let pressed =
    scrolled
    |> at(-10_000)
    |> tui.update(backend.MousePress(2, 4, backend.MouseLeft), _)
  assert pressed.selection_frame == Some(painted)
  assert pressed.selection_gutters == painted_gutters
    as "mouse-down must capture copy metadata from the painted frame"
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

pub fn a_subagent_usage_row_does_not_settle_the_primary_clock_test() {
  let started =
    initial(-10_000)
    |> deliver(
      "{\"v\":1,\"event\":\"op_transition\",\"body\":{\"strand\":\"main\",\"phase\":\"assistant\"}}",
    )
  assert started.generation_started_ms == Some(-10_000)

  // A sub-agent's own request settles mid-generation. `generation_clock`
  // only ever starts the clock for the active strand's row, so only that
  // same strand's settlement may read it or clear it: the sub-agent's row
  // must not report its output over the primary's window, and must not
  // stop the primary's clock out from under it.
  let crossed =
    started
    |> at(-9500)
    |> deliver(gateway.usage("sub:main/audit", 10, 300, 0.0))
  assert crossed.generation_started_ms == Some(-10_000)
    as "a sub-agent's settlement must not clear the primary's clock"
  assert crossed.output_rate_tps == None
    as "a sub-agent's settlement must not report its own output rate"

  // The primary's own settlement afterward still works as before.
  let settled =
    crossed
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

const assistant_phase = "{\"v\":1,\"event\":\"op_transition\",\"body\":{\"strand\":\"main\",\"phase\":\"assistant\"}}"

// Moves the event's presentation reading without touching the clock, which
// is what a caller of `tui.step` does to choose the time.
fn stamped_at(model: tui_model.Model, now: Int) -> tui_model.Model {
  tui_model.Model(..model, stamp: tui_model.Stamp(..model.stamp, now_ms: now))
}

pub fn a_step_reads_the_stamp_and_never_the_clock_test() {
  let model =
    tui_model.Model(..initial(-10_000), monotonic_time_ms: fn() {
      panic as "a step called the presentation clock"
    })

  // The first tick drains the transition, which starts the generation
  // clock from the stamp; the second finds the strand live and starts the
  // activity count from it.
  process.send(model.inbox, connection.Incoming(assistant_phase))
  let #(started, _) = tui.step(backend.Tick, model)
  assert started.generation_started_ms == Some(-10_000)
  let #(live, _) = tui.step(backend.Tick, started)
  assert live.activity_started_ms == Some(-10_000)

  // Three seconds of stamp are three seconds of activity, with the clock
  // still refusing every call.
  let #(later, _) = tui.step(backend.Tick, stamped_at(live, -7000))
  assert later.activity_elapsed_s == 3

  // The frame decision, a delta, a usage settlement and the input events
  // that drain traffic ahead of their own work all run at the stamp too.
  process.send(
    later.inbox,
    connection.Incoming(gateway.stream_delta("main", "text", "answer")),
  )
  process.send(
    later.inbox,
    connection.Incoming(gateway.usage("main", 10, 300, 0.0)),
  )
  let #(settled, _) = tui.step(backend.Tick, stamped_at(later, -8000))
  assert settled.output_rate_tps == Some(150)
  let #(resized, _) = tui.step(backend.Resize(100, 30), settled)
  assert resized.last_frame_ms == -8000
  let #(typed, _) = tui.step(backend.KeyPress("a"), resized)
  let #(_, _) = tui.step(backend.MouseScroll(5, 5, True), typed)
}

pub fn update_reads_the_presentation_clock_once_per_event_test() {
  let calls = process.new_subject()
  let model =
    tui.new_model_with_clock(
      connection.new_inbox(),
      workspace.Context(path: "/test/workspace", branch: None),
      fn() {
        process.send(calls, Nil)
        -10_000
      },
    )
  assert count(calls, 0) == 1 as "creation stamps the model once"

  // A live strand and a settled usage row put every presentation reader in
  // the path of these events.
  process.send(model.inbox, connection.Incoming(assistant_phase))
  process.send(
    model.inbox,
    connection.Incoming(gateway.stream_delta("main", "text", "answer")),
  )
  let events = [
    backend.Resize(80, 24),
    backend.Tick,
    backend.Tick,
    backend.KeyPress("a"),
    backend.Paste("b"),
    backend.MouseScroll(5, 5, True),
    backend.Tick,
  ]
  let model =
    list.fold(events, model, fn(model, event) { tui.update(event, model) })
  assert count(calls, 0) == list.length(events)
    as "update stamps each event with exactly one presentation reading"

  process.send(
    model.inbox,
    connection.Incoming(gateway.usage("main", 10, 300, 0.0)),
  )
  let _ = tui.update(backend.Tick, model)
  assert count(calls, 0) == 1
}

fn count(calls: process.Subject(Nil), seen: Int) -> Int {
  case process.receive(calls, 0) {
    Ok(Nil) -> count(calls, seen + 1)
    Error(Nil) -> seen
  }
}

pub fn a_lane_refreshes_and_expires_at_the_time_it_is_passed_test() {
  let lane =
    session_channel.replay(snapshot.Expected("A", "epoch", "incarnation"))
  let #(ready, _) =
    list.fold(
      pushed.transfer(1, "1:1", "recent", 10),
      #(lane, []),
      fn(acc, frame) { session_channel.receive(acc.0, frame, now: 1000) },
    )
  assert !session_channel.in_flight(ready)
    as "premise: the initial capture completed at 1000"

  // The idle refresh is due 250 ms after the capture that completed at the
  // reading the lane was handed, and not a millisecond before.
  let #(early, _) = session_channel.tick(ready, now: 1249)
  assert !session_channel.in_flight(early)
  let #(refreshing, _) = session_channel.tick(ready, now: 1250)
  assert session_channel.in_flight(refreshing)

  // The catch-up issued at 1250 has thirty seconds, measured from 1250.
  let #(waiting, updates) = session_channel.tick(refreshing, now: 31_249)
  assert updates == []
  assert session_channel.in_flight(waiting)
  let #(expired, updates) = session_channel.tick(refreshing, now: 31_250)
  assert updates == [session_channel.Failed("conversation request timed out")]
  assert !session_channel.in_flight(expired)
}

pub fn a_step_ticks_the_lane_at_the_stamped_transport_reading_test() {
  // The attached fixture's lane captured at zero, so its refresh is due at
  // 250 on the transport reading, whatever the presentation clock says.
  let model = pushed.attached()
  let at = fn(model: tui_model.Model, transport: Int) {
    tui_model.Model(
      ..model,
      stamp: tui_model.Stamp(..model.stamp, transport_ms: transport),
    )
  }
  let assert Some(lane) = model.channel
  assert !session_channel.in_flight(lane)

  let #(early, _) = tui.step(backend.Tick, at(model, 249))
  let assert Some(lane) = early.channel
  assert !session_channel.in_flight(lane)
  let #(due, _) = tui.step(backend.Tick, at(model, 250))
  let assert Some(lane) = due.channel
  assert session_channel.in_flight(lane)
    as "the step's lane tick runs at the stamp, not at a clock it reads"
}
