//// Cached layout must agree with fresh layout across presentation changes.
////
//// The cache owns only hints for current history. These tests exercise the
//// wire reducer, compare styled rows against a cold render, and check that a
//// replacement snapshot releases text from the previous conversation.

import core/entry
import etui/backend
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import tui
import tui/connection
import tui/protocol
import tui/session_channel
import tui/snapshot
import tui/tool_activity
import tui/workspace
import tui_test/ffi_term
import tui_test/gateway
import tui_test/pushed

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

// One complete credited capture, applied through the shipped channel reducer
// so the cut reaches `render_cut` the way the daemon's does. The capture is
// named by `seq`, which is what makes a second one a new cut rather than a
// repeat the lane discards; a fresh replay channel per capture is what lets
// both reuse one set of frame numbers.
fn captured(model: tui.Model, data: String, seq: Int) -> tui.Model {
  let channel =
    session_channel.replay(snapshot.Expected("A", "epoch", "incarnation"))
  let #(_, applied) =
    list.fold(
      pushed.transfer_with_metadata(
        1,
        "1:" <> int.to_string(seq),
        "recent",
        seq,
        data,
      ),
      #(channel, model),
      fn(acc, incoming) {
        let #(channel, changes) = session_channel.receive(acc.0, incoming)
        #(channel, list.fold(changes, acc.1, tui.apply_channel_update))
      },
    )
  applied
}

pub fn an_unchanged_cut_leaves_the_record_projection_standing_test() {
  // Cuts arrive four times a second throughout a turn. One that moved only
  // usage or a phase has changed nothing the transcript rows are built from,
  // and rebuilding on it re-projected the whole session at that cadence.
  let first =
    model()
    |> received(gateway.user_entry("main", "a settled turn", 1))
    |> checked_layout(120)
    |> captured(pushed.metadata(), 10)
    |> checked_layout(120)
  assert first.record_cache_valid
    as "the first capture rebuilds and leaves a valid cache behind it"
  assert first.record_rows != []
    as "the fixture must project rows, or term identity proves nothing"

  let second = captured(first, pushed.metadata(), 11) |> checked_layout(120)
  assert ffi_term.same_term(second.record_rows, first.record_rows)
    as "a cut that moved no projection input must not rebuild the rows"
}

pub fn settled_prose_appends_and_a_tool_record_regroups_test() {
  let base =
    model()
    |> received(gateway.user_entry("main", "run the tests", 1))
    |> checked_layout(120)
  let appended =
    base
    |> received(gateway.assistant_entry("main", "Looking at it now.", 2))
    |> checked_layout(120)
  assert same_tail(appended.record_rows, base.record_rows)
    as "settled prose extends rows already projected instead of rebuilding"

  // A call joins the open group, whose heading and pending row are already on
  // screen, so those rows have to be projected again.
  let regrouped =
    appended
    |> received(gateway.tool_call_entry("main", "bash", "printf 'x'", 3))
    |> checked_layout(120)
  assert !same_tail(regrouped.record_rows, appended.record_rows)
    as "a tool call can re-group an open block, so its rows are rebuilt"
}

pub fn tool_records_regroup_and_prose_does_not_test() {
  assert !tool_activity.regroups(entry_of(gateway.user_entry("main", "hi", 1)))
  assert !tool_activity.regroups(
    entry_of(gateway.assistant_entry("main", "prose", 2)),
  )
  assert tool_activity.regroups(
    entry_of(gateway.tool_call_entry("main", "bash", "x", 3)),
  )
  assert tool_activity.regroups(
    entry_of(gateway.tool_result_entry("main", "out", 4)),
  )
}

fn entry_of(wire: String) -> entry.Entry {
  let assert Ok(protocol.EntryAdded(record)) = protocol.decode_event(wire)
    as "the fixture must be one durable entry"
  record.entry
}

// Whether `rows` ends in the exact list `older` is, rather than in an equal
// copy of it. Term identity is the only evidence that separates an append
// from a rebuild that happened to produce the same text.
fn same_tail(rows: List(a), older: List(a)) -> Bool {
  ffi_term.same_term(
    list.drop(rows, list.length(rows) - list.length(older)),
    older,
  )
}
