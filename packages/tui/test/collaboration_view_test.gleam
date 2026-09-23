//// Collaboration fixtures keep captured facts and authenticated peer origins
//// separate from an invented delivery or workflow completion state.

import core/clock
import core/entry
import core/ids
import core/json
import core/message
import core/register
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import tui
import tui/collaboration_view
import tui/connection
import tui/protocol
import tui/snapshot
import tui/snapshot_view
import tui/workspace

fn empty_view() {
  snapshot_view.View(
    [protocol.Strand("main", Some("main"), None)],
    dict.new(),
    dict.new(),
    dict.new(),
    tui.new_model_with_clock(
      connection.new_inbox(),
      workspace.Context("/work", None),
      fn() { 0 },
    ).usage,
    snapshot_view.RunSettings("one_at_a_time", "parallel", None),
    [],
    [],
    None,
    Some([]),
    None,
  )
}

fn fact(key, seq, value) {
  snapshot_view.Cell(register.FactCustom, key, seq, value)
}

fn rendered(view, window) {
  collaboration_view.lines(view, window, "main", 80)
  |> list.map(fn(line) {
    line.spans |> list.map(fn(part) { part.content }) |> string.concat
  })
  |> string.join("\n")
}

pub fn custody_readiness_and_intent_have_distinct_labels_test() {
  let view =
    snapshot_view.View(..empty_view(), cells: [
      fact(
        "client/async/record/abc",
        4,
        json.Object([
          #("id", json.String("abc")),
          #("strand", json.String("main")),
          #("phase", json.String("running")),
          #("result", json.Null),
        ]),
      ),
      fact(
        "client/async/ready/abc",
        5,
        json.Object([#("endpoints", json.Array([json.String("review")]))]),
      ),
      fact(
        "client/peers/link/link-1",
        6,
        json.Object([
          #("source_strand", json.String("main")),
          #("session", json.String("other-session")),
          #("strand", json.String("reviewer")),
        ]),
      ),
      fact(
        "client/workflow/run/run-1",
        7,
        json.Object([
          #("strand", json.String("main")),
          #("name", json.String("review")),
          #("version", json.String("v1")),
        ]),
      ),
      fact(
        "client/workflow/step/step-1",
        8,
        json.Object([
          #("run", json.String("client/workflow/run/run-1")),
          #("name", json.String("security")),
        ]),
      ),
    ])
  let text = rendered(view, snapshot.Window([], 0, None))
  assert string.contains(text, "1 live executions")
  assert string.contains(text, "abc · running")
  assert string.contains(text, "Published endpoints: review")
  assert string.contains(text, "other-session/reviewer")
  assert string.contains(text, "1 recorded step intents")
  assert !string.contains(text, "completed")
}

pub fn settled_execution_keeps_only_historical_endpoint_evidence_test() {
  let view =
    snapshot_view.View(..empty_view(), cells: [
      fact(
        "client/async/record/def",
        9,
        json.Object([
          #("id", json.String("def")),
          #("strand", json.String("main")),
          #("phase", json.String("finished")),
          #("result", json.String("done")),
        ]),
      ),
      fact(
        "client/async/ready/def",
        8,
        json.Object([#("endpoints", json.Array([json.String("review")]))]),
      ),
    ])
  let text = rendered(view, snapshot.Window([], 0, None))
  assert string.contains(text, "0 live executions")
  assert string.contains(text, "def · finished")
  assert string.contains(text, "Published endpoints: review")
  assert !string.contains(text, "Ready: review")
}

pub fn a_peer_origin_is_visible_as_stored_input_not_a_read_receipt_test() {
  let #(id, _) = ids.mint_entry(ids.generator(clock.fixed(1), 1))
  let placed =
    entry.MessageEntry(
      id,
      None,
      9,
      9,
      message.UserMessage(
        [message.UserText("Check the cancellation path.", None)],
        9,
        Some(message.PeerOrigin("source-session", "reviewer")),
      ),
      False,
    )
  let view =
    snapshot_view.View(
      ..empty_view(),
      leaves: dict.from_list([#("main", Some(id))]),
    )
  let text =
    rendered(view, snapshot.Window([snapshot.Loaded(placed, 100)], 100, None))
  assert string.contains(text, "stored #9")
  assert string.contains(text, "source-session/reviewer")
  assert string.contains(text, "Check the cancellation path.")
  assert string.contains(text, "stored does not mean read")
}
