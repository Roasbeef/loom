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
import etui/geometry
import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleam/string
import tui
import tui/connection
import tui/frame
import tui/protocol
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

// A backlog long enough to survive a few frames, built the same way the
// shipped loop builds one: an anchor delivery (exempt from pacing, since
// nothing has been revealed yet) followed by a second delivery that lands
// on a viewport that already has a position to hold.
fn build_backlog() -> tui.Model {
  let inbox = connection.new_inbox()
  let base =
    tui.new_model_with_clock(inbox, workspace.Context("/work", None), fn() { 0 })
    |> fn(model) { tui.Model(..model, transcript: [], records: []) }
    |> fn(model) { tui.update(backend.Resize(84, 24), model) }
  process.send(
    inbox,
    connection.Incoming(gateway.stream_delta(
      "main",
      "text",
      numbered_lines("anchor", 40),
    )),
  )
  let anchored =
    tui.update(backend.Tick, base)
    |> fn(model) { tui.update(backend.Tick, model) }
  process.send(
    inbox,
    connection.Incoming(gateway.stream_delta(
      "main",
      "text",
      numbered_lines("filler", 4),
    )),
  )
  tui.update(backend.Tick, anchored)
}

// Numbered rather than repeated, so a row cannot be mistaken for one of its
// neighbours: a shift measured against identical repeated text is blind to
// exactly the off-by-a-multiple-of-the-period errors this suite exists to
// catch.
fn numbered_lines(prefix: String, count: Int) -> String {
  counting_to(count)
  |> list.map(fn(index) { prefix <> " " <> string.inspect(index) <> ".\n\n" })
  |> string.join("")
}

pub fn a_wheel_up_during_a_backlog_moves_the_window_older_test() {
  let backlogged = build_backlog()
  assert backlogged.revealed_rows < backlogged.rendered_row_count
    as "the fixture must actually carry a backlog, or the scroll below tests nothing"

  let before =
    tui.view(
      tui.Model(..backlogged, frame_cache: None),
      geometry.rect_new(0, 0, 84, 24),
    ).0
  let scrolled = tui.update(backend.MouseScroll(5, 5, True), backlogged)
  let after =
    tui.view(
      tui.Model(..scrolled, frame_cache: None),
      geometry.rect_new(0, 0, 84, 24),
    ).0

  // A wheel-up asks for three rows of older text. Measured against the
  // window the reader was actually looking at (the paced offset, not the
  // bare stored one), that is a three-row shift toward older text and
  // nothing else.
  assert older_shift(transcript_rows(before), transcript_rows(after)) == 3
    as "a wheel-up during a backlog must move the same window three rows older, not jump toward the tail"
}

// The mirror of `row_shift`: a scroll toward older text adds rows at the
// front and drops them off the back, the opposite direction from a stream
// appending at the tail, so the two cannot share one measure of "how far".
fn older_shift(before: List(String), after: List(String)) -> Int {
  case after {
    [] -> 0
    [_, ..rest] ->
      case list.take(before, list.length(after)) == after {
        True -> 0
        False -> 1 + older_shift(before, rest)
      }
  }
}

pub fn a_resize_mid_backlog_closes_it_test() {
  let backlogged = build_backlog()
  assert backlogged.revealed_rows < backlogged.rendered_row_count
    as "the fixture must actually carry a backlog, or the resize below tests nothing"

  // Height only, so the row count itself does not rewrap and the closing
  // of the backlog is the only thing this resize could have caused.
  let resized = tui.update(backend.Resize(84, 30), backlogged)
  assert resized.revealed_rows == resized.rendered_row_count
    as "a resize addresses the transcript and must close the backlog like any other gesture"
}

pub fn the_idle_strand_snap_reveals_the_trailing_frame_test() {
  let backlogged = build_backlog()
  assert backlogged.revealed_rows < backlogged.rendered_row_count
    as "the fixture must actually carry a backlog, or the idle snap below tests nothing"

  // The strand stops producing without any gesture from the reader: the
  // walk has nothing left to lag behind, so the next tick must adopt the
  // complete projection at once rather than keep crawling toward it.
  let ended_strands =
    list.map(backlogged.strands, fn(strand) {
      case strand.id == backlogged.active_strand {
        True -> protocol.Strand(..strand, live_phase: None)
        False -> strand
      }
    })
  let idled = tui.Model(..backlogged, strands: ended_strands, submitting: None)
  let settled = tui.update(backend.Tick, idled)
  assert settled.revealed_rows == settled.rendered_row_count
    as "an idle strand has no tail to walk toward, so the trailing frame must be the complete one"

  let #(buffer, _) =
    tui.view(
      tui.Model(..settled, frame_cache: None),
      geometry.rect_new(0, 0, 84, 24),
    )
  let assert Ok(_) =
    frame.buffer_to_lines(buffer)
    |> list.find(fn(row) { string.contains(row, "filler") })
    as "the trailing frame must show the accumulated output, not the stale backlog"
}

pub fn a_backlog_past_the_catch_up_threshold_accelerates_test() {
  let inbox = connection.new_inbox()
  let clocked =
    tui.new_model_with_clock(inbox, workspace.Context("/work", None), fn() { 0 })
    |> fn(model) { tui.Model(..model, transcript: [], records: []) }
    |> fn(model) { tui.update(backend.Resize(84, 60), at(model, 0)) }

  process.send(
    inbox,
    connection.Incoming(gateway.stream_delta(
      "main",
      "text",
      string.join(list.repeat("anchor line.\n\n", 5), ""),
    )),
  )
  let anchored = tui.update(backend.Tick, at(clocked, 16))

  // One delivery of thirty short lines pushes the backlog past the
  // twenty-four row catch-up threshold in a single step.
  process.send(
    inbox,
    connection.Incoming(gateway.stream_delta(
      "main",
      "text",
      string.join(list.repeat("filler line.\n\n", 15), ""),
    )),
  )
  let backlogged = tui.update(backend.Tick, at(anchored, 32))
  assert backlogged.rendered_row_count - backlogged.revealed_rows > 24
    as "the fixture must actually push the backlog past the threshold, or the catch-up arm below is untested"

  // A real clock advancing sixteen milliseconds a tick, not a frozen one:
  // the ordinary arm alone would need more than twenty frames to close a
  // backlog this size.
  let stepped = tui.update(backend.Tick, at(backlogged, 48))
  assert stepped.revealed_rows - backlogged.revealed_rows > 1
    as "a backlog past the catch-up threshold must accelerate, not crawl one row a frame"
}

pub fn a_backlog_behind_a_full_width_diff_view_answers_settled_test() {
  let base =
    tui.new_model_with_clock(
      connection.new_inbox(),
      workspace.Context("/work", None),
      fn() { 0 },
    )
  let behind_diff =
    tui.Model(
      ..base,
      rendered_row_count: 40,
      revealed_rows: 10,
      diff_view: tui.DiffVisible,
      width: 90,
    )
  assert tui.viewport_pacing(behind_diff) == tui.ViewportSettled
    as "a backlog behind a full-width diff view is not on its way to any screen the loop is painting"
}

pub fn typing_leaves_a_backlog_alone_but_a_page_key_closes_it_test() {
  let backlogged = build_backlog()
  assert backlogged.revealed_rows < backlogged.rendered_row_count
    as "the fixture must actually carry a backlog, or neither assertion below tests anything"

  let typed =
    ["a", "b", "c"]
    |> list.fold(backlogged, fn(model, key) {
      tui.update(backend.KeyPress(key), model)
    })
  assert typed.revealed_rows == backlogged.revealed_rows
    as "typing into the composer says nothing about the transcript and must not move it"
  assert typed.rendered_row_count == backlogged.rendered_row_count

  let paged = tui.update(backend.KeyPress("pageup"), typed)
  assert paged.revealed_rows == paged.rendered_row_count
    as "a page key addresses the transcript and must close the backlog"
}
