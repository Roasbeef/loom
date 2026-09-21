//// Real snapshot fixtures for the bounded inter-agent message projection.
////
//// These tests keep the ownership boundary explicit: every candidate comes
//// after the current operation's accepted prompt and every result is joined
//// inside that strand's retained suffix.

import core/clock
import core/entry
import core/ids
import core/json
import core/message
import core/register
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import machine/codec
import machine/operation
import tui/agent_messages
import tui/protocol
import tui/snapshot
import tui/snapshot_view

fn eid(n) {
  ids.mint_entry(ids.generator(clock.fixed(n), n)).0
}

fn oid(n) {
  ids.mint_op(ids.generator(clock.fixed(n), n)).0
}

fn usage() {
  message.Usage(
    0,
    0,
    0,
    0,
    None,
    None,
    0,
    message.UsageCost(0.0, 0.0, 0.0, 0.0, 0.0),
  )
}

fn prompt(id, seq, parent) {
  entry.MessageEntry(
    id,
    parent,
    seq,
    seq,
    message.UserMessage([message.UserText("prompt", None)], seq, None),
    False,
  )
}

fn send(id, seq, parent, call_id, target, body) {
  entry.MessageEntry(
    id,
    parent,
    seq,
    seq,
    message.AssistantMessage(
      [
        message.AssistantToolCall(message.ToolCall(
          call_id,
          "agent_send",
          json.Object([
            #("to", json.String(target)),
            #("message", json.String(body)),
          ]),
          None,
          None,
        )),
      ],
      "test",
      "test",
      "test",
      None,
      None,
      None,
      usage(),
      message.ToolUse,
      None,
      None,
      None,
      None,
      seq,
    ),
    False,
  )
}

fn result(id, seq, parent, call_id, failed, delivery) {
  entry.MessageEntry(
    id,
    parent,
    seq,
    seq,
    message.ToolResultMessage(
      call_id,
      "agent_send",
      [message.ToolResultText("accepted", None)],
      Some(json.Object([#("delivery", json.String(delivery))])),
      None,
      None,
      failed,
      seq,
    ),
    False,
  )
}

fn view(strands, leaves, operations, cells) {
  snapshot_view.View(
    strands,
    leaves,
    dict.new(),
    operations,
    usage(),
    snapshot_view.RunSettings("one_at_a_time", "parallel", None),
    [],
    cells,
    None,
    Some([]),
    None,
  )
}

fn window(entries) {
  snapshot.Window(
    list.map(entries, fn(value) { snapshot.Loaded(value, 1) }),
    list.length(entries),
    None,
  )
}

fn active_view(strand, operation_id, prompt_id, leaf_id, entries) {
  let operation_id_value = oid(operation_id)
  let cell =
    snapshot_view.Cell(
      register.OpMeta,
      ids.op_id_to_string(operation_id_value),
      operation_id,
      codec.encode_operation(operation.Operation(
        operation_id_value,
        strand,
        None,
        1,
        operation.RunIntent([prompt_id]),
      )),
    )
  #(
    view(
      [protocol.Strand(strand, None, Some("running"))],
      dict.from_list([#(strand, Some(leaf_id))]),
      dict.from_list([#(strand, ids.op_id_to_string(operation_id_value))]),
      [cell],
    ),
    window(entries),
  )
}

fn send_chain(remaining, parent, sequence, entries) {
  case remaining {
    0 -> #(parent, entries)
    _ -> {
      let id = eid(100 + sequence)
      let value =
        send(
          id,
          sequence + 1,
          Some(parent),
          "call-" <> int.to_string(sequence),
          "sub:worker",
          "body",
        )
      send_chain(remaining - 1, id, sequence + 1, list.append(entries, [value]))
    }
  }
}

pub fn joins_exact_agent_send_results_and_delivery_states_test() {
  let p = eid(1)
  let a = eid(2)
  let ar = eid(3)
  let b = eid(4)
  let br = eid(5)
  let c = eid(6)
  let cr = eid(7)
  let entries = [
    prompt(p, 1, None),
    send(a, 2, Some(p), "a", "sub:worker", "start this"),
    result(ar, 3, Some(a), "a", False, "started"),
    send(b, 4, Some(ar), "b", "sub:worker", "steer this"),
    result(br, 5, Some(b), "b", False, "steered"),
    send(c, 6, Some(br), "c", "sub:worker", "failed this"),
    result(cr, 7, Some(c), "c", True, "steered"),
  ]
  let #(captured, history) = active_view("main", 1, p, cr, entries)
  let rows = agent_messages.observe(captured, history, "main")
  let assert [first, second, third] = rows
  assert first.call_id == "c"
  assert first.state == agent_messages.SendFailed
  assert second.call_id == "b"
  assert second.state == agent_messages.Accepted
  assert third.call_id == "a"
  assert third.state == agent_messages.Started
  assert third.target == "sub:worker"
  assert third.body == "start this"
}

pub fn pending_send_does_not_borrow_result_from_another_strand_test() {
  let main_prompt = eid(10)
  let main_send = eid(11)
  let sub_prompt = eid(20)
  let sub_send = eid(21)
  let sub_result = eid(22)
  let main_op = oid(10)
  let sub_op = oid(20)
  let main_cell =
    snapshot_view.Cell(
      register.OpMeta,
      ids.op_id_to_string(main_op),
      1,
      codec.encode_operation(operation.Operation(
        main_op,
        "main",
        None,
        1,
        operation.RunIntent([main_prompt]),
      )),
    )
  let sub_cell =
    snapshot_view.Cell(
      register.OpMeta,
      ids.op_id_to_string(sub_op),
      2,
      codec.encode_operation(operation.Operation(
        sub_op,
        "sub:worker",
        None,
        1,
        operation.RunIntent([sub_prompt]),
      )),
    )
  let captured =
    view(
      [
        protocol.Strand("main", None, Some("running")),
        protocol.Strand("sub:worker", None, Some("running")),
      ],
      dict.from_list([
        #("main", Some(main_send)),
        #("sub:worker", Some(sub_result)),
      ]),
      dict.from_list([
        #("main", ids.op_id_to_string(main_op)),
        #("sub:worker", ids.op_id_to_string(sub_op)),
      ]),
      [main_cell, sub_cell],
    )
  let history =
    window([
      prompt(main_prompt, 1, None),
      send(main_send, 2, Some(main_prompt), "same", "sub:worker", "pending"),
      prompt(sub_prompt, 3, None),
      send(sub_send, 4, Some(sub_prompt), "same", "main", "done"),
      result(sub_result, 5, Some(sub_send), "same", False, "started"),
    ])
  let assert [foreign, row] = agent_messages.observe(captured, history, "main")
  assert foreign.source == "sub:worker"
  assert foreign.state == agent_messages.Started
  assert row.source == "main"
  assert row.state == agent_messages.SendPending
}

pub fn inherited_parent_send_before_child_prompt_is_excluded_test() {
  let parent_send = eid(30)
  let child_prompt = eid(31)
  let child_send = eid(32)
  let child =
    send(child_send, 3, Some(child_prompt), "child", "main", "child body")
  let #(captured, history) =
    active_view("sub:child", 30, child_prompt, child_send, [
      send(parent_send, 1, None, "parent", "main", "forged parent"),
      prompt(child_prompt, 2, Some(parent_send)),
      child,
    ])
  let assert [row] = agent_messages.observe(captured, history, "sub:child")
  assert row.body == "child body"
}

pub fn missing_opmeta_or_prompt_is_unavailable_test() {
  let p = eid(40)
  let a = eid(41)
  let entries = [
    prompt(p, 1, None),
    send(a, 2, Some(p), "call", "main", "body"),
  ]
  let base =
    view(
      [protocol.Strand("main", None, Some("running"))],
      dict.from_list([#("main", Some(a))]),
      dict.from_list([#("main", ids.op_id_to_string(oid(40)))]),
      [],
    )
  assert agent_messages.observe(base, window(entries), "main") == []
  let wrong_prompt = active_view("main", 41, eid(42), a, entries).0
  assert agent_messages.observe(wrong_prompt, window(entries), "main") == []
}

pub fn latest_twenty_and_body_excerpt_are_bounded_test() {
  let p = eid(50)
  let a = eid(51)
  let #(captured, history) =
    active_view("main", 50, p, a, [
      prompt(p, 1, None),
      send(a, 2, Some(p), "call", "sub:worker", string.repeat("x", 5000)),
    ])
  let assert [row] = agent_messages.observe(captured, history, "main")
  assert row.body_extent == agent_messages.Excerpt
  assert string.length(row.body) == 4097

  let chain_prompt = eid(60)
  let #(chain_leaf, sends) = send_chain(21, chain_prompt, 1, [])
  let #(chain_view, chain_history) =
    active_view("main", 60, chain_prompt, chain_leaf, [
      prompt(chain_prompt, 1, None),
      ..sends
    ])
  assert list.length(agent_messages.observe(chain_view, chain_history, "main"))
    == 20
}

pub fn capture_retains_and_refreshes_after_opmeta_is_deleted_test() {
  let p = eid(70)
  let a = eid(71)
  let ar = eid(72)
  let pending =
    agent_messages.Item(
      entry_id: ids.entry_id_to_string(a),
      call_id: "call",
      source: "main",
      target: "sub:worker",
      body: "body",
      body_extent: agent_messages.Complete,
      seq: 2,
      state: agent_messages.SendPending,
    )
  let ended_view =
    view(
      [protocol.Strand("main", None, None)],
      dict.from_list([#("main", Some(ar))]),
      dict.new(),
      [],
    )
  let retained =
    agent_messages.capture(
      [pending],
      ended_view,
      window([
        prompt(p, 1, None),
        send(a, 2, Some(p), "call", "sub:worker", "body"),
        result(ar, 3, Some(a), "call", False, "started"),
      ]),
    )
  let assert [updated] = retained
  assert updated.entry_id == ids.entry_id_to_string(a)
  assert updated.state == agent_messages.Started
}

pub fn reused_call_id_cannot_settle_an_older_send_test() {
  let p = eid(80)
  let first = eid(81)
  let second = eid(82)
  let reply = eid(83)
  let #(captured, history) =
    active_view("main", 80, p, reply, [
      prompt(p, 1, None),
      send(first, 2, Some(p), "reused", "sub:worker", "old body"),
      send(second, 3, Some(first), "reused", "sub:worker", "new body"),
      result(reply, 4, Some(second), "reused", False, "started"),
    ])
  let assert [new, old] = agent_messages.observe(captured, history, "main")
  assert new.state == agent_messages.Started
  assert old.state == agent_messages.SendPending
  let ended = snapshot_view.View(..captured, operations: dict.new(), cells: [])
  let assert [retained] = agent_messages.capture([old], ended, history)
  assert retained == old
}

pub fn truncated_branch_cannot_refresh_a_cached_send_by_call_id_alone_test() {
  let p = eid(90)
  let first = eid(91)
  let later = eid(92)
  let reply = eid(93)
  let #(captured, history) =
    active_view("main", 90, p, first, [
      prompt(p, 1, None),
      send(first, 2, Some(p), "reused", "sub:worker", "original body"),
    ])
  let original = agent_messages.capture([], captured, history)
  let ended =
    snapshot_view.View(
      ..captured,
      operations: dict.new(),
      cells: [],
      leaves: dict.from_list([#("main", Some(reply))]),
    )
  let truncated =
    window([
      result(reply, 200, Some(later), "reused", True, "steered"),
    ])
  assert agent_messages.capture(original, ended, truncated) == original
}
