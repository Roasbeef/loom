//// `tool_activity.project` groups calls for the transcript and ends a group
//// at prose; `tool_activity.calls` lists them regardless. These tests pin both
//// answers for one message that carries reasoning ahead of a call: the
//// transcript still treats it as prose, and the list of calls still holds
//// the call with its result.

import core/clock
import core/entry
import core/ids
import core/json
import core/message
import core/usage_evidence
import gleam/list
import gleam/option.{None, Some}
import session_view/tool_activity

fn id(seq: Int) -> ids.EntryId {
  ids.mint_entry(ids.generator(clock.fixed(1000), seq)).0
}

fn entry_of(seq: Int, body: message.AgentMessage) -> entry.Entry {
  entry.MessageEntry(id(seq), None, seq, seq * 1000, body, False)
}

fn assistant(content: List(message.AssistantBlock)) -> message.AgentMessage {
  message.AssistantMessage(
    content,
    "test",
    "test",
    "test",
    None,
    None,
    None,
    message.Usage(
      0,
      0,
      0,
      0,
      None,
      None,
      0,
      message.UsageCost(0.0, 0.0, 0.0, 0.0, 0.0),
      usage_evidence.none(),
    ),
    message.Stop,
    None,
    None,
    None,
    None,
    0,
  )
}

fn invocation(call_id: String) -> message.AssistantBlock {
  message.AssistantToolCall(message.ToolCall(
    call_id,
    "fs_read",
    json.Object([]),
    None,
    None,
  ))
}

fn outcome(call_id: String) -> message.AgentMessage {
  message.ToolResultMessage(
    call_id,
    "fs_read",
    [message.ToolResultText("ok", None)],
    None,
    None,
    None,
    False,
    0,
  )
}

fn reasoned() -> List(entry.Entry) {
  [
    entry_of(
      1,
      assistant([
        message.AssistantThinking("look first", None, False),
        invocation("c1"),
      ]),
    ),
    entry_of(2, outcome("c1")),
  ]
}

pub fn a_message_with_reasoning_is_still_a_narrative_boundary_test() {
  let assert [tool_activity.Narrative(_), tool_activity.Narrative(_)] =
    tool_activity.project(reasoned())
    as "prose ends the group, and the result has no group to join"
}

pub fn a_call_beside_reasoning_is_listed_with_its_result_test() {
  let assert [call] = tool_activity.calls(reasoned()) as "one call"

  assert call.invocation.id == "c1"
  assert call.source == id(1)
  assert call.result_source == Some(id(2))
}

pub fn calls_keep_source_order_and_reused_ids_join_in_turn_test() {
  let entries = [
    entry_of(1, assistant([invocation("c")])),
    entry_of(2, outcome("c")),
    entry_of(
      3,
      assistant([message.AssistantText("again", None), invocation("c")]),
    ),
    entry_of(4, outcome("c")),
  ]

  let sources =
    tool_activity.calls(entries)
    |> list.map(fn(call) { #(call.source, call.result_source) })

  assert sources == [#(id(1), Some(id(2))), #(id(3), Some(id(4)))]
}

pub fn a_result_without_its_call_is_not_a_call_test() {
  assert tool_activity.calls([entry_of(1, outcome("gone"))]) == []
}
