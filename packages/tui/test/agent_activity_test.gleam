//// Evidence-based activity cannot cross a strand or operation boundary.

import core/clock
import core/entry
import core/ids
import core/json
import core/message
import core/register
import gleam/dict
import gleam/option.{None, Some}
import machine/codec
import machine/operation
import tui
import tui/agent_activity
import tui/connection
import tui/protocol
import tui/snapshot
import tui/snapshot_view
import tui/workspace

fn eid(n) {
  ids.mint_entry(ids.generator(clock.fixed(n), n)).0
}

fn oid(n) {
  ids.mint_op(ids.generator(clock.fixed(n), n)).0
}

fn call(name, args) {
  message.ToolCall("call", name, args, None, None)
}

pub fn only_explicit_well_formed_waits_name_dependencies_test() {
  let handle = "sub:main/check#" <> ids.op_id_to_string(oid(1))
  let waiting =
    call(
      "agent_wait",
      json.Object([#("handles", json.Array([json.String(handle)]))]),
    )
  assert agent_activity.waiting([waiting]) == Some("Waiting for sub:main/check")
  assert agent_activity.waiting([call("fs_read", json.Object([]))]) == None
  assert agent_activity.waiting([
      call(
        "agent_wait",
        json.Object([
          #("handles", json.Array([json.String("not a run handle")])),
        ]),
      ),
    ])
    == None
  assert agent_activity.waiting([waiting, call("fs_read", json.Object([]))])
    == Some("Waiting for sub:main/check · other tools active")
}

pub fn recent_activity_joins_prose_calls_without_borrowing_another_run_test() {
  let base =
    tui.new_model_with_clock(
      connection.new_inbox(),
      workspace.Context("/work", None),
      fn() { 0 },
    )
  let prompt =
    entry.MessageEntry(
      eid(1),
      None,
      1,
      1,
      message.UserMessage([message.UserText("Read the source", None)], 1, None),
      False,
    )
  let response =
    entry.MessageEntry(
      eid(2),
      Some(eid(1)),
      2,
      2,
      message.AssistantMessage(
        [
          message.AssistantText("Reading it now.", None),
          message.AssistantToolCall(call(
            "fs_read",
            json.Object([#("path", json.String("src/main.gleam"))]),
          )),
        ],
        "test",
        "test",
        "test",
        None,
        None,
        None,
        base.usage,
        message.Stop,
        None,
        None,
        None,
        None,
        2,
      ),
      False,
    )
  let outcome =
    entry.MessageEntry(
      eid(3),
      Some(eid(2)),
      3,
      3,
      message.ToolResultMessage(
        "call",
        "fs_read",
        [message.ToolResultText("source", None)],
        None,
        None,
        None,
        False,
        3,
      ),
      False,
    )
  let meta =
    snapshot_view.Cell(
      register.OpMeta,
      ids.op_id_to_string(oid(1)),
      1,
      codec.encode_operation(operation.Operation(
        oid(1),
        "main",
        None,
        1,
        operation.RunIntent([eid(1)]),
      )),
    )
  let view =
    snapshot_view.View(
      [protocol.Strand("main", None, None)],
      dict.from_list([#("main", Some(eid(3)))]),
      dict.new(),
      dict.new(),
      base.usage,
      snapshot_view.RunSettings("one_at_a_time", "parallel", None),
      [],
      [meta],
      None,
      Some([]),
      None,
    )
  let window =
    snapshot.Window(
      [
        snapshot.Loaded(outcome, 1),
        snapshot.Loaded(response, 1),
        snapshot.Loaded(prompt, 1),
      ],
      3,
      None,
    )
  assert agent_activity.recent(
      view,
      window,
      "main",
      Some(ids.op_id_to_string(oid(1))),
    )
    == ["✓ Completed · fs_read · src/main.gleam"]
  assert agent_activity.recent(
      view,
      window,
      "main",
      Some(ids.op_id_to_string(oid(2))),
    )
    == []
  assert agent_activity.recent(
      view,
      window,
      "other",
      Some(ids.op_id_to_string(oid(1))),
    )
    == []
  let evicted =
    snapshot.Window(
      [snapshot.Loaded(outcome, 1), snapshot.Loaded(response, 1)],
      2,
      None,
    )
  assert agent_activity.recent(
      view,
      evicted,
      "main",
      Some(ids.op_id_to_string(oid(1))),
    )
    == []
}
