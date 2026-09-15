//// The prompt-cache notice as the terminal draws it.
////
//// These tests drive the shipped event handler over the wire, on an
//// injected clock, so what they check is the whole path: two `usage` frames
//// on one strand, the detector between them, and the row that lands in the
//// transcript under the turn that paid for the miss. The detector's own
//// thresholds are swept in `cache_miss_test`.

import core/message
import etui/backend
import etui/geometry
import gleam/erlang/process
import gleam/option.{None}
import gleam/string
import tui
import tui/connection
import tui/frame
import tui/workspace
import tui_test/gateway

// A quarter-million token prefix, priced at a dollar per million tokens for
// a cached read. The figures are round so the row's text is exact rather
// than approximately exact.
fn held_prefix() -> message.Usage {
  message.Usage(
    input: 0,
    output: 400,
    cache_read: 250_000,
    cache_write: 0,
    cache_write_1h: None,
    reasoning: None,
    total_tokens: 250_400,
    cost: message.UsageCost(
      input: 0.0,
      output: 0.004,
      cache_read: 0.25,
      cache_write: 0.0,
      total: 0.254,
    ),
  )
}

// The same prefix read again from cold, at five dollars per million tokens:
// four dollars per million more than the cached read, which over a quarter
// of a million tokens is exactly one dollar.
fn re_read_prefix() -> message.Usage {
  message.Usage(
    input: 0,
    output: 400,
    cache_read: 0,
    cache_write: 250_000,
    cache_write_1h: None,
    reasoning: None,
    total_tokens: 250_400,
    cost: message.UsageCost(
      input: 0.0,
      output: 0.004,
      cache_read: 0.0,
      cache_write: 1.25,
      total: 1.254,
    ),
  )
}

const expected_row = "Cache miss after 10m idle: 250k tokens re-billed (~$1.00)"

fn initial(now: Int) -> tui.Model {
  tui.new_model_with_clock(
    connection.new_inbox(),
    workspace.Context(path: "/work", branch: None),
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

fn text(model: tui.Model) -> String {
  let model = tui.update(backend.Resize(120, 40), model)
  let #(buffer, _) = tui.view(model, geometry.rect_new(0, 0, 120, 40))
  frame.buffer_to_text(buffer)
}

// A first turn whose request read the cached prefix, ten minutes ago.
fn after_the_first_turn() -> tui.Model {
  initial(0)
  |> deliver(gateway.user_entry("main", "carry on", 1))
  |> deliver(gateway.assistant_entry("main", "first answer", 2))
  |> deliver(gateway.usage_row("main", held_prefix()))
}

// The turn after the pause, whose request paid for the prefix again.
fn after_the_second_turn(model: tui.Model) -> tui.Model {
  model
  |> at(600_000)
  |> deliver(gateway.user_entry("main", "still there", 3))
  |> deliver(gateway.assistant_entry("main", "second answer", 4))
  |> deliver(gateway.usage_row("main", re_read_prefix()))
}

pub fn two_usage_rows_across_a_pause_draw_the_row_test() {
  let quiet = after_the_first_turn()
  assert !string.contains(text(quiet), "Cache miss")

  let drawn = text(after_the_second_turn(quiet))
  assert string.contains(drawn, expected_row)

  // The row explains the turn above it, so it follows the answer whose
  // request missed rather than heading the transcript.
  let assert Ok(#(above, _)) = string.split_once(drawn, "Cache miss")
    as "the row is on screen"
  assert string.contains(above, "second answer")
}

pub fn an_unpriced_model_keeps_the_row_and_drops_the_money_test() {
  let free = message.UsageCost(0.0, 0.0, 0.0, 0.0, 0.0)
  let drawn =
    initial(0)
    |> deliver(gateway.user_entry("main", "carry on", 1))
    |> deliver(gateway.assistant_entry("main", "first answer", 2))
    |> deliver(gateway.usage_row(
      "main",
      message.Usage(..held_prefix(), cost: free),
    ))
    |> at(600_000)
    |> deliver(gateway.assistant_entry("main", "second answer", 4))
    |> deliver(gateway.usage_row(
      "main",
      message.Usage(..re_read_prefix(), cost: free),
    ))
    |> text

  // The status line prices the session elsewhere on screen, so what must be
  // absent is the row's own parenthetical rather than every dollar sign.
  assert string.contains(
    drawn,
    "Cache miss after 10m idle: 250k tokens re-billed",
  )
  assert !string.contains(drawn, "re-billed (~$")
}

pub fn a_subagent_strand_never_feeds_the_primary_detector_test() {
  // The sub-agent's own strand misses while `main` sits on its cached
  // prefix. Its row belongs to its own transcript, and its rows must not
  // become the baseline the primary is judged against.
  let sub = "sub:main/audit"
  let crossed =
    after_the_first_turn()
    |> deliver(gateway.assistant_entry(sub, "sub answer", 5))
    |> deliver(gateway.usage_row(sub, held_prefix()))
    |> at(600_000)
    |> deliver(gateway.usage_row(sub, re_read_prefix()))

  assert !string.contains(text(crossed), "Cache miss")

  // `main`'s own second row still reports the whole prefix, which it could
  // not do if the sub-agent's rows had displaced its baseline.
  let drawn =
    crossed
    |> deliver(gateway.assistant_entry("main", "second answer", 6))
    |> deliver(gateway.usage_row("main", re_read_prefix()))
    |> text
  assert string.contains(drawn, expected_row)
}

pub fn a_reattach_does_not_redraw_the_row_test() {
  // The notice is memory-only. A fresh model fed the same durable history
  // shows the conversation and none of the transient rows, which is what
  // "not durable" has to mean on screen.
  let drawn = text(after_the_second_turn(after_the_first_turn()))
  assert string.contains(drawn, expected_row)

  let reattached =
    initial(600_000)
    |> deliver(gateway.user_entry("main", "carry on", 1))
    |> deliver(gateway.assistant_entry("main", "first answer", 2))
    |> deliver(gateway.user_entry("main", "still there", 3))
    |> deliver(gateway.assistant_entry("main", "second answer", 4))
    |> text
  assert string.contains(reattached, "second answer")
  assert !string.contains(reattached, "Cache miss")
}

pub fn a_row_raised_inside_a_tool_group_follows_the_group_test() {
  // A usage event can land between a tool call and its result. The compact
  // projection joins those two, so the row has to follow the whole group
  // rather than cut it in half and leave the call pending.
  let drawn =
    initial(0)
    |> deliver(gateway.user_entry("main", "carry on", 1))
    |> deliver(gateway.assistant_entry("main", "first answer", 2))
    |> deliver(gateway.usage_row("main", held_prefix()))
    |> at(600_000)
    |> deliver(gateway.tool_call_entry("main", "bash", "call-1", 3))
    |> deliver(gateway.usage_row("main", re_read_prefix()))
    |> deliver(gateway.tool_result_ok_entry("main", "call output", 4))
    |> text

  assert string.contains(drawn, expected_row)

  // The joined group reports one call and no unfinished work above the row.
  let assert Ok(#(above, _)) = string.split_once(drawn, "Cache miss")
    as "the row is on screen"
  assert string.contains(above, "tools · 1 call")
}
