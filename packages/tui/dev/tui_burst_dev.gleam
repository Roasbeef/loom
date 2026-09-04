//// Repeatable microbenchmarks for queued terminal input.
////
//// Etui's buffered loop used to draw after each decoded event. Its bounded
//// loop now applies up to sixty-four ready events before drawing. This module
//// replays forty queued key events through an in-memory backend so the two
//// policies can be compared without terminal I/O or human timing.

import etui/app
import etui/backend
import etui/buffer
import etui/geometry.{type Rect, Position}
import etui/style
import etui/terminal
import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/string
import tui
import tui/theme

type Script {
  Script(events: List(backend.InputEvent))
}

type Model {
  Model(events: Int)
}

type RenderMode {
  Cached(buffer.Buffer)
  Rebuilt
}

@external(erlang, "erlang", "monotonic_time")
fn now_native(unit: Micro) -> Int

type Micro {
  Microsecond
}

fn now_us() -> Int {
  now_native(Microsecond)
}

fn scripted_backend() -> backend.Backend(Script) {
  backend.Backend(
    init: fn() { Ok(Script(list.repeat(backend.KeyPress("j"), 40))) },
    render: fn(state, _ops) { Ok(state) },
    poll: fn(state, _timeout_ms) {
      case state.events {
        [event, ..rest] -> Ok(#(event, Script(rest)))
        [] -> Error(backend.Interrupted)
      }
    },
    next_size: fn(state) {
      Ok(#(backend.TerminalSize(width: 200, height: 50), state))
    },
    cleanup: fn(_state) { Nil },
  )
}

fn apply_event(event: backend.InputEvent, model: Model) -> Model {
  case event {
    backend.KeyPress(_) -> Model(events: model.events + 1)
    _ -> model
  }
}

fn loom_frame(area: Rect, frame: Int) -> buffer.Buffer {
  let row = string.repeat("the quick brown fox ", 10)
  let transcript = geometry.rect_new(0, 1, 166, 43)
  let input = geometry.rect_new(0, 44, 200, 4)

  buffer.buffer_new_filled(
    area,
    row,
    style.new(theme.paper, style.Default, style.none()),
  )
  |> tui.render_panel_border(transcript, " transcript / main ", theme.quiet)
  |> tui.render_panel_border(input, " message ", theme.signal)
  |> buffer.set_string(
    Position(2, 2),
    int.to_string(frame),
    theme.signal_bold(),
  )
}

fn frame_for(mode: RenderMode, model: Model, area: Rect) -> buffer.Buffer {
  case mode {
    Cached(frame) -> frame
    Rebuilt -> loom_frame(area, model.events)
  }
}

fn draw(
  term: terminal.Terminal(Script),
  model: Model,
  mode: RenderMode,
) -> terminal.Terminal(Script) {
  let assert Ok(drawn) =
    terminal.draw(term, fn(frame) {
      terminal.with_buffer(frame, frame_for(mode, model, frame.area))
    })
    as "the in-memory backend must draw"
  drawn
}

fn old_loop(
  term: terminal.Terminal(Script),
  model: Model,
  mode: RenderMode,
) -> #(terminal.Terminal(Script), Model) {
  case terminal.poll(term, 0) {
    Ok(#(event, polled)) -> {
      let next = apply_event(event, model)
      old_loop(draw(polled, next, mode), next, mode)
    }
    Error(_) -> #(term, model)
  }
}

fn one_event_per_frame(mode: RenderMode) -> Int {
  let assert Ok(term) = terminal.new(scripted_backend())
    as "the in-memory backend must initialize"
  let started = draw(term, Model(events: 0), mode)
  let #(finished, model) = old_loop(started, Model(events: 0), mode)
  terminal.restore(finished)
  model.events
}

fn bounded_burst(mode: RenderMode) -> Int {
  let assert app.Success(model) =
    app.run_buffered(
      scripted_backend(),
      Model(events: 0),
      fn(model, area) { frame_for(mode, model, area) },
      apply_event,
      fn(_model) { False },
      0,
    )
    as "the bounded in-memory loop must complete"
  model.events
}

fn repeat(iterations: Int, work: fn() -> Int, total: Int) -> Int {
  case iterations <= 0 {
    True -> total
    False -> {
      let events = work()
      let assert 40 = events as "each benchmark burst must process every event"
      repeat(iterations - 1, work, total + events)
    }
  }
}

fn measure(name: String, iterations: Int, work: fn() -> Int) -> Nil {
  let warmup_events = work()
  let assert 40 = warmup_events
    as "the benchmark warm-up must process every event"
  let started = now_us()
  let total_events = repeat(iterations, work, 0)
  let elapsed = now_us() - started
  let per_burst = int.to_float(elapsed) /. int.to_float(iterations)

  io.println(
    name
    <> ": "
    <> float.to_string(round2(per_burst))
    <> " us per 40-event burst ("
    <> int.to_string(total_events)
    <> " events)",
  )
}

fn round2(value: Float) -> Float {
  int.to_float(float.round(value *. 100.0)) /. 100.0
}

/// Measures the frame work removed by etui's bounded input loop.
///
/// The cached case represents Loom returning the exact completed frame. The
/// rebuilt case represents an invalidated 200-by-50 Loom-style frame. Terminal
/// Both policies include terminal setup and cleanup. The public bounded loop
/// also includes its cleanup guard.
///
/// ## Examples
///
/// ```sh
/// make bench-tui
/// ```
pub fn run() -> Nil {
  let area = geometry.rect_new(0, 0, 200, 50)
  let cached = Cached(loom_frame(area, 0))

  io.println("\netui queued-input batching")
  measure("one event/frame, exact cached frame", 2000, fn() {
    one_event_per_frame(cached)
  })
  measure("bounded burst, exact cached frame", 2000, fn() {
    bounded_burst(cached)
  })
  measure("one event/frame, rebuilt Loom frame", 30, fn() {
    one_event_per_frame(Rebuilt)
  })
  measure("bounded burst, rebuilt Loom frame", 30, fn() {
    bounded_burst(Rebuilt)
  })
}
