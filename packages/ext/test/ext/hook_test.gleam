//// `ext/hook`'s own tests: one round trip per event, against the exact
//// `args` document the harness sends and the exact `value` document it
//// reads back.
////
//// The harness half of this wire lives in `client/extension/hooks` and
//// is tested there against fake satellites. These tests are the other
//// half, and they are written as literal JSON text rather than through a
//// shared builder on purpose: a shared builder would let both sides
//// drift together, which is precisely the failure a wire test exists to
//// catch.

import ext/hook
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleeunit

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn every_hook_names_its_event_test() {
  let named = [
    #(hook.OnSessionStart(fn() { Nil }), "session_start"),
    #(hook.OnBeforeAgentStart(fn(_start) { None }), "before_agent_start"),
    #(
      hook.OnContext(fn(context) { list.map(context.messages, rerendered) }),
      "context",
    ),
    #(hook.OnToolCall(fn(_call) { hook.Allow }), "tool_call"),
    #(hook.OnToolResult(rerendered), "tool_result"),
    #(hook.OnAgentEnd(fn(_op) { Nil }), "agent_end"),
    #(hook.OnAgentSettled(fn(_op) { Nil }), "agent_settled"),
  ]
  assert list.map(named, fn(pair) { hook.event(pair.0) })
    == list.map(named, fn(pair) { pair.1 })
}

pub fn a_gate_renders_a_verdict_test() {
  let gate =
    hook.OnToolCall(fn(call) {
      case call.tool {
        "bash" -> hook.Block(reason: "no shells today")
        _other -> hook.Allow
      }
    })
  let args =
    "{\"op_id\":\"op-1\",\"tool\":\"bash\",\"arguments\":{},\"source_index\":0}"
  assert hook.answer(gate, args)
    == Ok("{\"verdict\":\"block\",\"reason\":\"no shells today\"}")
}

pub fn an_allowing_gate_carries_no_reason_test() {
  let gate = hook.OnToolCall(fn(_call) { hook.Allow })
  let args =
    "{\"op_id\":\"op-1\",\"tool\":\"grep\",\"arguments\":{},\"source_index\":2}"
  assert hook.answer(gate, args) == Ok("{\"verdict\":\"allow\"}")
}

pub fn a_gate_reads_the_call_it_was_given_test() {
  let gate =
    hook.OnToolCall(fn(call) {
      hook.Block(reason: call.tool <> "/" <> call.op_id)
    })
  let args =
    "{\"op_id\":\"op-9\",\"tool\":\"fs_write\",\"arguments\":{},\"source_index\":1}"
  assert hook.answer(gate, args)
    == Ok("{\"verdict\":\"block\",\"reason\":\"fs_write/op-9\"}")
}

pub fn an_injection_is_a_string_or_null_test() {
  let quiet = hook.OnBeforeAgentStart(fn(_start) { None })
  let loud = hook.OnBeforeAgentStart(fn(start) { Some(start.strand) })
  let args = "{\"op_id\":\"op-1\",\"strand\":\"main\"}"
  assert hook.answer(quiet, args) == Ok("{\"inject\":null}")
  assert hook.answer(loud, args) == Ok("{\"inject\":\"main\"}")
}

pub fn a_context_transform_answers_a_message_array_test() {
  let drop = hook.OnContext(fn(_context) { [] })
  let args =
    "{\"op_id\":\"op-1\",\"messages\":[{\"role\":\"user\"},{\"role\":\"assistant\"}]}"
  assert hook.answer(drop, args) == Ok("{\"messages\":[]}")
}

pub fn a_context_transform_reads_the_messages_it_was_handed_test() {
  let keep =
    hook.OnContext(fn(context) { list.map(context.messages, rerendered) })
  let args =
    "{\"op_id\":\"op-1\",\"messages\":[{\"role\":\"user\"},{\"role\":\"assistant\"}]}"
  assert hook.answer(keep, args)
    == Ok("{\"messages\":[{\"role\":\"user\"},{\"role\":\"assistant\"}]}")
}

pub fn a_tool_result_transform_answers_one_message_test() {
  let keep = hook.OnToolResult(rerendered)
  let args = "{\"message\":{\"role\":\"tool_result\"}}"
  assert hook.answer(keep, args)
    == Ok("{\"message\":{\"role\":\"tool_result\"}}")
}

pub fn a_notification_answers_an_empty_document_test() {
  let started = hook.OnSessionStart(fn() { Nil })
  let ended = hook.OnAgentEnd(fn(_op) { Nil })
  let settled = hook.OnAgentSettled(fn(_op) { Nil })
  assert hook.answer(started, "{}") == Ok("{}")
  assert hook.answer(ended, "{\"op_id\":\"op-1\"}") == Ok("{}")
  assert hook.answer(settled, "{\"op_id\":\"op-1\"}") == Ok("{}")
}

pub fn args_that_do_not_hold_the_event_are_an_error_test() {
  let gate = hook.OnToolCall(fn(_call) { hook.Allow })
  let assert Error(reason) = hook.answer(gate, "{\"op_id\":\"op-1\"}")
    as "a gate needs a tool name"
  assert reason == "the hook arguments have no string tool"

  let assert Error(malformed) = hook.answer(gate, "not json")
    as "a hook_call body that is not JSON is a broken wire"
  assert malformed == "the hook arguments were not JSON"
}

// A message read as `Dynamic` and written back as `Json`. The fixture
// messages carry one field, so re-rendering it is the whole document;
// a real hook decodes what it cares about and rebuilds the rest the
// same way. There is no `Dynamic -> Json` in the stdlib, which is the
// honest shape of the seam: an extension that wants to change a message
// has to say what it is making.
fn rerendered(message: Dynamic) -> json.Json {
  let assert Ok(role) = decode.run(message, decode.at(["role"], decode.string))
    as "the fixture messages carry a role"
  json.object([#("role", json.string(role))])
}
