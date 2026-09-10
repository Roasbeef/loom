//// Terminal cuts and ancestry gaps must never broaden operation ownership.

import core/clock
import core/entry
import core/ids
import core/json
import core/message
import core/register
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import machine/codec
import machine/operation
import tui/completion_summary as summary
import tui/snapshot_view

fn entry_id(n) {
  ids.mint_entry(ids.generator(clock.fixed(n), seed: n)).0
}

fn op_id(n) {
  ids.mint_op(ids.generator(clock.fixed(n), seed: n)).0
}

fn placed(n, parent, body) {
  entry.MessageEntry(entry_id(n), parent, n, n, body, False)
}

fn assistant(n, parent, content) {
  placed(
    n,
    parent,
    message.AssistantMessage(
      content:,
      api: "test",
      provider: "test",
      model: "test",
      response_model: None,
      response_id: None,
      diagnostics: None,
      usage: message.Usage(
        0,
        0,
        0,
        0,
        None,
        None,
        0,
        message.UsageCost(0.0, 0.0, 0.0, 0.0, 0.0),
      ),
      stop_reason: message.Stop,
      deferred: None,
      error_message: None,
      raw_stop_reason: None,
      end_turn: None,
      timestamp: n,
    ),
  )
}

fn invocation(id, name, args) {
  message.AssistantToolCall(message.ToolCall(id, name, args, None, None))
}

fn path(value) {
  json.Object([#("path", json.String(value))])
}

fn tool(n, parent, id, name, status, details) {
  placed(
    n,
    parent,
    message.ToolResultMessage(
      id,
      name,
      [message.ToolResultText("captured output", None)],
      Some(details),
      None,
      None,
      status == summary.Failed,
      n,
    ),
  )
}

fn meta(n, name, source) {
  snapshot_view.Cell(
    register.OpMeta,
    ids.op_id_to_string(op_id(n)),
    n,
    codec.encode_operation(operation.Operation(
      op_id(n),
      name,
      source,
      n,
      operation.RunIntent([]),
    )),
  )
}

fn terminal(n, name, leaf, outcome) {
  snapshot_view.Cell(
    register.StrandLastResult,
    name,
    n,
    codec.encode_last_result(operation.RunLastResult(
      op_id(n),
      leaf,
      outcome,
      None,
    )),
  )
}

fn completed() {
  operation.RunCompleted(operation.CompletedByAssistant)
}

fn latest(state, strand) {
  let assert Some(value) = summary.latest(state, strand)
    as "the observed strand has a captured terminal result"
  value
}

pub fn predecessor_result_keeps_boundary_when_successor_is_in_same_cut_test() {
  let old_call =
    assistant(1, None, [invocation("old", "fs_edit", path("old.gleam"))])
  let old_result =
    tool(
      2,
      Some(entry_id(1)),
      "old",
      "fs_edit",
      summary.Succeeded,
      path("old.gleam"),
    )
  let new_call =
    assistant(3, Some(entry_id(2)), [
      message.AssistantText("Running checks after the edit.", None),
      invocation("edit", "fs_edit", path("new.gleam")),
      invocation(
        "checks",
        "bash",
        json.Object([#("command", json.String("make test"))]),
      ),
    ])
  let edited =
    tool(
      4,
      Some(entry_id(3)),
      "edit",
      "fs_edit",
      summary.Succeeded,
      path("new.gleam"),
    )
  let checked =
    tool(
      5,
      Some(entry_id(4)),
      "checks",
      "bash",
      summary.Failed,
      json.Object([#("exit_code", json.Int(7))]),
    )
  let initial =
    summary.observe(summary.new(), [meta(10, "main", Some(entry_id(2)))], [])
  let cut = [
    meta(11, "main", Some(entry_id(5))),
    terminal(10, "main", Some(entry_id(5)), completed()),
  ]
  let observed =
    summary.observe(initial, cut, [
      checked,
      old_result,
      new_call,
      old_call,
      edited,
    ])
  let result = latest(observed, "main")
  assert result.coverage == summary.Complete
  assert result.edits == ["new.gleam"]
  assert result.tools
    == [
      summary.ToolOutcome("edit", "fs_edit", summary.Succeeded, None, None),
      summary.ToolOutcome(
        "checks",
        "bash",
        summary.Failed,
        Some("make test"),
        Some(7),
      ),
    ]
  assert list.contains(summary.lines(result), "bash failed; exit 7: make test")
  assert !string.contains(
    string.join(summary.lines(result), "\n"),
    "tests passed",
  )

  // The successor can evict every predecessor entry from the bounded window.
  // A completed evidence record must survive that ordinary metadata refresh.
  let refreshed = summary.observe(observed, cut, [])
  assert latest(refreshed, "main") == result
}

pub fn known_root_and_unobserved_reconnect_have_different_evidence_test() {
  let call =
    assistant(1, None, [invocation("edit", "fs_edit", path("root.gleam"))])
  let edited =
    tool(
      2,
      Some(entry_id(1)),
      "edit",
      "fs_edit",
      summary.Succeeded,
      path("root.gleam"),
    )
  let cells = [terminal(10, "main", Some(entry_id(2)), completed())]
  let known =
    summary.new()
    |> summary.observe([meta(10, "main", None)], [])
    |> summary.observe(cells, [call, edited])
    |> latest("main")
  let unknown =
    summary.new()
    |> summary.observe(cells, [call, edited])
    |> latest("main")
  assert known.coverage == summary.Complete
  assert known.edits == ["root.gleam"]
  assert unknown.coverage == summary.Unavailable
  assert unknown.edits == []
  assert unknown.tools == []
}

pub fn missing_ancestor_is_partial_and_unpaired_result_is_not_an_edit_test() {
  let result =
    tool(
      3,
      Some(entry_id(2)),
      "missing-call",
      "fs_edit",
      summary.Succeeded,
      path("unproven.gleam"),
    )
  let observed =
    summary.new()
    |> summary.observe([meta(10, "main", Some(entry_id(1)))], [])
    |> summary.observe([terminal(10, "main", Some(entry_id(3)), completed())], [
      result,
    ])
    |> latest("main")
  assert observed.coverage == summary.Partial
  assert observed.edits == []
  assert observed.tools == []
}

pub fn partial_history_can_be_completed_by_a_later_loaded_window_test() {
  let call =
    assistant(1, None, [invocation("edit", "fs_edit", path("later.gleam"))])
  let edited =
    tool(
      2,
      Some(entry_id(1)),
      "edit",
      "fs_edit",
      summary.Succeeded,
      path("later.gleam"),
    )
  let cut = [terminal(10, "main", Some(entry_id(2)), completed())]
  let partial =
    summary.new()
    |> summary.observe([meta(10, "main", None)], [])
    |> summary.observe(cut, [edited])
  assert latest(partial, "main").coverage == summary.Partial
  let complete = summary.observe(partial, cut, [call, edited]) |> latest("main")
  assert complete.coverage == summary.Complete
  assert complete.edits == ["later.gleam"]
}

pub fn terminal_status_is_taken_from_machine_result_test() {
  let scenarios = [
    #(
      operation.RunCompleted(operation.CompletedByTerminatedTools),
      "Completed by terminating tools",
    ),
    #(
      operation.RunFailed(operation.OperationError(
        "provider_error",
        "provider disconnected",
        None,
      )),
      "Failed: provider disconnected",
    ),
    #(operation.RunAborted, "Aborted"),
  ]
  list.each(scenarios, fn(pair) {
    let result =
      summary.new()
      |> summary.observe([terminal(10, "main", None, pair.0)], [])
      |> latest("main")
    assert result.outcome == pair.0
    assert summary.brief(result) == pair.1
  })
}

pub fn strand_retention_is_bounded_test() {
  let observed =
    int.range(from: 1, to: 41, with: summary.new(), run: fn(state, n) {
      summary.observe(
        state,
        [terminal(n, "strand-" <> int.to_string(n), None, completed())],
        [],
      )
    })
  assert summary.latest(observed, "strand-1") == None
  assert latest(observed, "strand-40").operation
    == ids.op_id_to_string(op_id(40))
}
