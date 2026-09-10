//// Cached layout must agree with fresh layout across presentation changes.
////
//// The cache owns only hints for current history. These tests exercise the
//// wire reducer, compare styled rows against a cold render, and check that a
//// replacement snapshot releases text from the previous conversation.

import etui/backend
import gleam/dict
import gleam/list
import gleam/option.{None}
import gleam/string
import tui
import tui/connection
import tui/workspace
import tui_test/gateway

fn model() {
  let base =
    tui.new_model(connection.new_inbox(), workspace.Context("/work", None))
  tui.Model(..base, transcript: [], records: [], notice: "fixture")
}

fn received(model, wire) {
  tui.accept_connection_message(model, connection.Incoming(wire))
}

fn checked_layout(model, width) {
  let cold =
    tui.Model(
      ..model,
      record_cache_valid: False,
      record_line_cache: dict.new(),
      rendered_revision: -1,
    )
    |> fn(value) { tui.update(backend.Resize(width, 40), value) }
  let cached = tui.update(backend.Resize(width, 40), model)
  assert cached.rendered_rows == cold.rendered_rows
    as "cached rows must preserve fresh text, styles, links, and wrapping"
  assert cached.rendered_row_count == cold.rendered_row_count
  cached
}

pub fn cached_history_matches_fresh_rows_after_each_event_test() {
  let wires = [
    gateway.user_entry("main", "Review 界 and e\u{301} beside 👩‍💻", 1),
    gateway.assistant_entry(
      "main",
      "**Result**: [details](https://example.test)\n\n```gleam\n  pub fn main() { Nil }\n```",
      2,
    ),
    gateway.tool_call_entry("main", "bash", "printf 'same'", 3),
    gateway.tool_result_entry("main", "first result", 4),
    gateway.tool_call_entry("main", "bash", "printf 'same'", 5),
    gateway.tool_result_entry("main", "second result", 6),
    gateway.assistant_entry("main", "Finished with \u{1b}[31mred\u{1b}[0m", 7),
    gateway.user_entry("other", "not in the active strand", 8),
  ]
  let populated =
    list.fold(wires, model(), fn(current, wire) {
      current |> received(wire) |> checked_layout(120)
    })

  // Reflow, expanded details, and strand selection change the projection or
  // its geometry. All three must preserve the same cold-render semantics.
  assert list.length(populated.records) == 8
    as "the fixture must admit every durable event before comparing layout"
  assert !list.any(populated.transcript, fn(line) {
    line.speaker == tui.Failure
  })
    as "protocol errors are not a history-rendering workload"
  let narrow = checked_layout(populated, 32)
  let expanded =
    checked_layout(tui.Model(..narrow, details_expanded: True), 120)
  let other =
    checked_layout(
      tui.Model(..expanded, active_strand: "other", rendered_revision: -1),
      120,
    )
  assert !list.any(dict.keys(other.record_line_cache), fn(line) {
    string.contains(line.text, "Review 界")
    || string.contains(line.text, "**Result**")
  })
    as "changing the active branch must release its previous layout hints"
  let _ =
    checked_layout(
      tui.Model(..other, active_strand: "main", rendered_revision: -1),
      120,
    )
}

pub fn a_replaced_snapshot_releases_previous_cached_text_test() {
  let old =
    model()
    |> received(gateway.user_entry("main", "discarded conversation marker", 1))
    |> checked_layout(120)
  assert list.any(dict.keys(old.record_line_cache), fn(line) {
    string.contains(line.text, "discarded conversation marker")
  })
  let fresh =
    old
    |> received(gateway.full_snapshot("replacement"))
    |> received(gateway.user_entry("main", "current conversation", 2))
    |> checked_layout(120)
  assert !list.any(dict.keys(fresh.record_line_cache), fn(line) {
    string.contains(line.text, "discarded conversation marker")
  })
    as "a cache must not extend the lifetime of replaced conversation text"
}

pub fn identical_text_keeps_each_speakers_own_style_test() {
  let user =
    model()
    |> received(gateway.user_entry("main", "**same**", 1))
    |> checked_layout(120)
  let both =
    user
    |> received(gateway.assistant_entry("main", "**same**", 2))
    |> checked_layout(120)
  assert dict.size(both.record_line_cache) > dict.size(user.record_line_cache)
    as "plain user text and assistant markdown are distinct presentation keys"
}
