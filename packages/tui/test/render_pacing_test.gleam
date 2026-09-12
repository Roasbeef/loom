//// How often the loop repaints while streaming, and how far the transcript
//// moves when it does.
////
//// Three things are pinned here. The arithmetic of the walk is pinned
//// directly, because its bounds — never past the tail, never backwards,
//// always terminating — are what keep a paced viewport from drifting away
//// from the rows the model holds. The motion itself is pinned through the
//// shipped loop: a script of stream deltas is driven through `run_script`
//// and the frames it produced are compared pair by pair, because the
//// property the operator sees is a property of consecutive frames and
//// nothing smaller can express it. The third is the frame budget: a tick
//// carrying a stream delta is one frame of a stream and waits its turn,
//// while a tick carrying nothing keeps the flushing duty a deferred frame
//// depends on.

import etui/backend
import etui/buffer
import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleam/string
import tui
import tui/connection
import tui/frame
import tui/virtual_backend
import tui/workspace
import tui_test/gateway

const policy = tui.PacePolicy(
  rows_per_frame: 1,
  catch_up_threshold: 24,
  snap_above: 200,
)

pub fn pace_reveals_one_row_per_frame_test() {
  assert tui.pace(10, 11, policy) == 11
  assert tui.pace(10, 15, policy) == 11
  assert tui.pace(10, 10, policy) == 10
}

pub fn pace_never_passes_or_retreats_from_the_tail_test() {
  // A shrink is adopted at once: retired rows must not stay on screen.
  assert tui.pace(30, 4, policy) == 4
  assert tui.pace(30, 0, policy) == 0

  // And a step never overshoots a target one row away, at any backlog.
  assert list.all(counting_to(60), fn(target) {
    let next = tui.pace(1, target, policy)
    next <= int_max(target, 1) && next >= 1
  })
    as "a step lands on or before the target and never moves backwards"
}

pub fn pace_accelerates_out_of_a_long_backlog_test() {
  // At the threshold the step is still one row; past it the step grows with
  // the backlog, so the lag cannot keep lengthening while output arrives.
  assert tui.pace(0, 24, tui.PacePolicy(1, 24, 200)) == 24
  assert tui.pace(1, 25, policy) == 2
  assert tui.pace(1, 26, policy) == 4
  assert tui.pace(1, 105, policy) == 14
}

pub fn pace_reaches_the_tail_in_bounded_frames_test() {
  // The bound is what makes the lag a latency rather than a divergence:
  // one row a frame at sixteen milliseconds is under half a second for the
  // largest backlog the ordinary arm can hold.
  assert frames_to_settle(1, 25, policy) <= 25
  assert frames_to_settle(1, 199, policy) <= 41
  assert frames_to_settle(1, 201, policy) == 1
}

pub fn an_unrevealed_viewport_adopts_its_first_projection_test() {
  // Nothing is on screen yet, so there is no position to stay continuous
  // with and a walk would animate an arrival rather than a change.
  assert tui.pace(0, 40, policy) == 40
  assert tui.pace(0, 1, policy) == 1
}

pub fn a_jump_wider_than_the_viewport_is_taken_at_once_test() {
  // Attaching to a long session, or paging in history, replaces every row
  // the reader could see. Walking that would scroll history nobody read.
  let screen = tui.PacePolicy(1, 24, 20)
  assert tui.pace(5, 25, screen) == 25
  assert tui.pace(5, 24, screen) == 6
}

// Runs the walk to the tail and reports how many steps it took, with a bound
// so a policy that failed to converge ends the test rather than the suite.
fn frames_to_settle(revealed: Int, target: Int, policy: tui.PacePolicy) -> Int {
  case revealed >= target, revealed > 400 {
    True, _ | _, True -> 0
    False, False ->
      1 + frames_to_settle(tui.pace(revealed, target, policy), target, policy)
  }
}

// The integers one through `last`, which the standard library has no
// generator for and which two fixtures here need.
fn counting_to(last: Int) -> List(Int) {
  list.repeat(0, last) |> list.index_map(fn(_, index) { index + 1 })
}

fn int_max(left: Int, right: Int) -> Int {
  case left > right {
    True -> left
    False -> right
  }
}

pub fn streaming_frames_shift_the_transcript_one_row_at_a_time_test() {
  let shifts = streamed_shifts()
  assert list.any(shifts, fn(rows) { rows > 0 })
    as "the fixture must actually scroll, or the bound below is vacuous"
  assert list.all(shifts, fn(rows) { rows <= 1 })
    as "a streamed answer moves the transcript by at most one row a frame"
}

// Drives the shipped loop over a scripted answer and measures how far the
// transcript moved between each pair of consecutive frames.
//
// The clock is frozen, so a paced boundary never elapses and the walk is
// carried entirely by the quiet ticks between deliveries — which is the
// loop's own behaviour when the socket goes quiet between provider chunks,
// and the reason those ticks kept their flushing duty.
fn streamed_shifts() -> List(Int) {
  let inbox = connection.new_inbox()
  let base =
    tui.new_model_with_clock(inbox, workspace.Context("/work", None), fn() { 0 })

  // The demo transcript is cleared so the run starts from an empty
  // viewport; its live strand is kept, because a strand that has stopped
  // producing holds no rows back and there would be nothing to measure.
  let model = tui.Model(..base, transcript: [], records: [])
  let script =
    virtual_backend.Script(
      size: backend.TerminalSize(width: 84, height: 24),
      steps: list.flat_map(counting_to(20), fn(index) {
        [
          virtual_backend.Deliver(
            connection.Incoming(gateway.stream_delta(
              "main",
              "text",
              "paragraph " <> string.inspect(index) <> " of the answer.\n\n",
            )),
          ),
          ..list.repeat(virtual_backend.Input(backend.Tick), 6)
        ]
      }),
      inbox:,
      settle_ticks: 8,
      attempts: None,
    )
  let assert Ok(run) = tui.run_script(model, script)
    as "the shipped loop must run the scripted answer"

  // The frames before the transcript holds anything are dropped, and with
  // them the one adoption this law exempts: a viewport showing nothing has
  // no position to keep, so its first projection arrives whole.
  run.frames
  |> list.map(transcript_rows)
  |> list.drop_while(blank)
  |> list.window_by_2
  |> list.map(fn(pair) { row_shift(pair.0, pair.1) })
}

fn blank(rows: List(String)) -> Bool {
  list.all(rows, empty_row)
}

// The rows inside the transcript border, with the border columns removed
// and the unfilled rows below the text dropped. A transcript shorter than
// its panel is drawn from the top, so those trailing rows are padding
// rather than content and comparing them would read an append as a scroll.
fn transcript_rows(drawn: buffer.Buffer) -> List(String) {
  frame.buffer_to_lines(drawn)
  |> list.drop_while(fn(row) { !string.starts_with(row, "╭ transcript") })
  |> list.drop(1)
  |> list.take_while(fn(row) { string.starts_with(row, "│") })
  |> list.reverse
  |> list.drop_while(empty_row)
  |> list.reverse
}

fn empty_row(row: String) -> Bool {
  string.trim(string.replace(row, "│", "")) == ""
}

// How far the transcript scrolled between two frames, as the smallest number
// of rows that has to leave the top of the earlier frame for what remains to
// be what the later frame shows. A pair that shares no such prefix is not a
// scroll at all, and is reported as a shift wide enough to fail the bound.
fn row_shift(before: List(String), after: List(String)) -> Int {
  case before {
    [] -> 0
    [_, ..rest] ->
      case list.take(after, list.length(before)) == before {
        True -> 0
        False -> 1 + row_shift(rest, after)
      }
  }
}

pub fn a_tick_carrying_a_delta_waits_for_the_frame_interval_test() {
  let inbox = connection.new_inbox()
  let drawn =
    tui.new_model_with_clock(inbox, workspace.Context("/work", None), fn() { 0 })
    |> tui.update(backend.Resize(84, 24), _)

  // One millisecond after the last frame, so only the budget can be what
  // decides this. The delta has to reach the transcript for the tick that
  // drains it to count as carrying traffic.
  process.send(
    inbox,
    connection.Incoming(gateway.stream_delta("main", "text", "an answer")),
  )
  let carried = tui.update(backend.Tick, at(drawn, drawn.last_frame_ms + 1))
  assert carried.render_revision != drawn.render_revision
    as "the fixture must deliver a delta the transcript actually admits"
  assert carried.frame_debt == tui.FrameDeferred
    as "a tick that drained a delta is one frame of a stream, not a flush"

  // The same instant, with nothing left to drain, still renders: a deferred
  // frame has no other event waiting to pay it off.
  let flushed = tui.update(backend.Tick, carried)
  assert flushed.frame_debt == tui.FrameSettled
}

pub fn frame_boundary_paces_only_the_tick_that_carried_traffic_test() {
  assert tui.frame_boundary(backend.Tick, tui.TranscriptMoved) == tui.Paced
  assert tui.frame_boundary(backend.Tick, tui.TranscriptQuiet) == tui.FlushPoint
  assert tui.frame_boundary(backend.Resize(80, 24), tui.TranscriptMoved)
    == tui.FlushPoint
  assert tui.frame_boundary(backend.KeyPress("a"), tui.TranscriptQuiet)
    == tui.Paced
}

pub fn an_unrevealed_backlog_keeps_the_loop_waking_test() {
  let settled =
    tui.new_model_with_clock(
      connection.new_inbox(),
      workspace.Context("/work", None),
      fn() { 0 },
    )
  assert tui.viewport_pacing(settled) == tui.ViewportSettled

  // The quiet timeout would strand the walk for a whole quiet poll a step,
  // with no socket traffic left to wake the loop.
  let catching_up =
    tui.Model(..settled, rendered_row_count: 40, revealed_rows: 10)
  assert tui.viewport_pacing(catching_up) == tui.ViewportCatchingUp
  assert tui.terminal_poll_timeout(catching_up) == 16
  assert tui.terminal_poll_timeout(settled) > 16
}

fn at(model: tui.Model, now: Int) -> tui.Model {
  tui.Model(..model, monotonic_time_ms: fn() { now })
}
