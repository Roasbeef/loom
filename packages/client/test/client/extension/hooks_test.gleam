//// The extension hook bus, driven with fake invokers.
////
//// Every test here stands in for a satellite with a function, which is
//// the whole reason `Invoker` is a function type: the properties worth
//// pinning — load order, a block winning, a dead extension losing its
//// place while its siblings carry on, an undeclared event never reaching
//// anybody — are properties of the bus and not of the transport under
//// it.

import client/extension/hooks
import core/clock
import core/codec
import core/ids
import core/json
import core/message
import core/msgpack
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit
import telemetry/log

pub fn main() -> Nil {
  gleeunit.main()
}

// --- the fan-out ----------------------------------------------------------

pub fn an_undeclared_event_never_reaches_an_extension_test() {
  let calls = recorder()
  let bus =
    started([
      hooks.Extension(
        name: "quiet",
        events: [],
        invoke: recording(calls, allow()),
      ),
    ])
  assert hooks.gate(bus, operation(), "bash", json.Object([]), 0) == hooks.Allow
  assert seen(calls) == []
}

pub fn a_declared_event_is_asked_test() {
  let calls = recorder()
  let bus =
    started([
      hooks.Extension(
        name: "gate",
        events: ["tool_call"],
        invoke: recording(calls, allow()),
      ),
    ])
  assert hooks.gate(bus, operation(), "bash", json.Object([]), 0) == hooks.Allow
  assert seen(calls) == [#("gate", "tool_call")]
}

pub fn a_block_wins_and_names_the_extension_test() {
  let bus =
    started([
      hooks.Extension(name: "first", events: ["tool_call"], invoke: allow()),
      hooks.Extension(
        name: "second",
        events: ["tool_call"],
        invoke: blocking("the workspace is frozen"),
      ),
    ])
  assert hooks.gate(bus, operation(), "bash", json.Object([]), 0)
    == hooks.Block(extension: "second", reason: "the workspace is frozen")
}

pub fn a_gone_extension_is_dropped_and_the_rest_still_fire_test() {
  let calls = recorder()
  let bus =
    started([
      hooks.Extension(name: "dead", events: ["tool_call"], invoke: gone()),
      hooks.Extension(
        name: "alive",
        events: ["tool_call"],
        invoke: recording(calls, allow()),
      ),
    ])

  // The first fan-out reaches both: the dead one answers `Gone` and is
  // dropped, its sibling answers normally.
  assert hooks.gate(bus, operation(), "bash", json.Object([]), 0) == hooks.Allow
  assert hooks.subscribers(bus) == 1

  // The second reaches only the survivor, and the run carries on.
  assert hooks.gate(bus, operation(), "bash", json.Object([]), 0) == hooks.Allow
  assert seen(calls) == [#("alive", "tool_call"), #("alive", "tool_call")]
}

pub fn a_declining_extension_keeps_its_place_test() {
  let bus =
    started([
      hooks.Extension(
        name: "picky",
        events: ["tool_call"],
        invoke: refusing("not my business"),
      ),
    ])
  assert hooks.gate(bus, operation(), "bash", json.Object([]), 0) == hooks.Allow
  assert hooks.subscribers(bus) == 1
}

pub fn an_injection_is_fenced_and_attributed_test() {
  let rendered = hooks.injection("web_search", "3 searches left")
  assert string.contains(rendered, "<extension name=web_search>")
  assert string.contains(rendered, "3 searches left")
  assert string.contains(rendered, "</extension>")
  assert string.contains(rendered, "[loom] note from the extension")
}

// --- the two chained transforms -------------------------------------------

pub fn a_context_transform_is_chained_in_load_order_test() {
  let bus =
    started([
      hooks.Extension(
        name: "first",
        events: ["context"],
        invoke: appending("one"),
      ),
      hooks.Extension(
        name: "second",
        events: ["context"],
        invoke: appending("two"),
      ),
    ])
  let folded = hooks.fold_context(bus, [user("start")])
  assert list.map(folded, text_of) == ["start", "one", "two"]
}

pub fn an_oversized_context_transform_is_discarded_test() {
  let bus =
    started([
      hooks.Extension(
        name: "greedy",
        events: ["context"],
        // Four characters to the token, so a message this long is far
        // past the allowance on its own.
        invoke: appending(repeat("x", hooks.context_growth_tokens * 8)),
      ),
    ])
  assert hooks.fold_context(bus, [user("start")]) == [user("start")]
}

pub fn a_tool_result_transform_is_applied_test() {
  let bus =
    started([
      hooks.Extension(
        name: "redactor",
        events: ["tool_result"],
        invoke: retexting(reply_ok("redacted")),
      ),
    ])
  let folded = hooks.fold_tool_result(bus, reply_ok("secret"))
  assert folded == reply_ok("redacted")
}

pub fn is_error_cannot_be_cleared_by_a_hook_test() {
  let bus =
    started([
      hooks.Extension(
        name: "launderer",
        events: ["tool_result"],
        invoke: retexting(reply_ok("all fine")),
      ),
    ])

  // The transform is discarded whole, so the text does not change
  // either: a hook that lied about the failure gets to change nothing.
  assert hooks.fold_tool_result(bus, reply_failed("it failed"))
    == reply_failed("it failed")
}

pub fn a_transform_from_a_gone_extension_is_discarded_test() {
  let bus =
    started([
      hooks.Extension(name: "dead", events: ["context"], invoke: gone()),
      hooks.Extension(
        name: "alive",
        events: ["context"],
        invoke: appending("one"),
      ),
    ])
  let folded = hooks.fold_context(bus, [user("start")])
  assert list.map(folded, text_of) == ["start", "one"]
}

// --- wiring ---------------------------------------------------------------

pub fn the_unwired_invoker_says_the_satellite_is_gone_test() {
  let invoke = hooks.unwired()
  assert invoke("web_search", "tool_call", msgpack.NilValue, 0)
    == Error(hooks.Gone)
}

// --- fixtures -------------------------------------------------------------

fn started(extensions: List(hooks.Extension)) -> hooks.Bus {
  let assert Ok(bus) = hooks.start(extensions, log.discard())
    as "the bus must start"
  bus
}

fn operation() -> ids.OpId {
  let generator = ids.generator(clock.fixed(at: 0), seed: 7)
  let #(id, _generator) = ids.mint_op(generator)
  id
}

// An invoker that answers every call the same way, with the answer given
// as the JSON text a satellite would have sent back.
fn answering(text: String) -> hooks.Invoker {
  fn(_extension, _event, _args, _deadline) { Ok(msgpack.StringValue(text)) }
}

fn allow() -> hooks.Invoker {
  answering("{\"verdict\":\"allow\"}")
}

fn blocking(reason: String) -> hooks.Invoker {
  answering("{\"verdict\":\"block\",\"reason\":\"" <> reason <> "\"}")
}

fn gone() -> hooks.Invoker {
  fn(_extension, _event, _args, _deadline) { Error(hooks.Gone) }
}

fn refusing(reason: String) -> hooks.Invoker {
  fn(_extension, _event, _args, _deadline) {
    Error(hooks.Refused(reason: reason))
  }
}

// A `context` invoker that appends one user message to whatever it was
// handed, which is what makes the chaining observable: the second
// extension's output contains the first's addition.
fn appending(text: String) -> hooks.Invoker {
  fn(_extension, _event, args, _deadline) {
    let assert msgpack.StringValue(value: sent) = args
      as "the bus sends a msgpack string"
    let assert Ok(json.Object(fields:)) = json.parse(sent)
      as "the args are a JSON object"
    let assert Ok(json.Array(items:)) = list.key_find(fields, "messages")
      as "context args carry a message array"
    let appended = list.append(items, [codec.encode_message(user(text))])
    Ok(
      msgpack.StringValue(
        json.to_string(json.Object([#("messages", json.Array(appended))])),
      ),
    )
  }
}

// A `tool_result` invoker that answers with whatever reply it was built
// with, however unlike the one it was handed. That is what makes the
// `is_error` rule testable from the hook's side: the invoker returns a
// successful reply and the harness has to notice.
fn retexting(answer: message.AgentMessage) -> hooks.Invoker {
  fn(_extension, _event, _args, _deadline) {
    Ok(
      msgpack.StringValue(
        json.to_string(
          json.Object([#("message", codec.encode_message(answer))]),
        ),
      ),
    )
  }
}

// An invoker that notes who was asked what before delegating, so a test
// can assert that an extension was never woken at all.
fn recording(
  calls: Subject(#(String, String)),
  inner: hooks.Invoker,
) -> hooks.Invoker {
  fn(extension, event, args, deadline) {
    process.send(calls, #(extension, event))
    inner(extension, event, args, deadline)
  }
}

fn recorder() -> Subject(#(String, String)) {
  process.new_subject()
}

fn seen(calls: Subject(#(String, String))) -> List(#(String, String)) {
  drain(calls, [])
}

fn drain(calls: Subject(answer), collected: List(answer)) -> List(answer) {
  case process.receive(calls, within: 0) {
    Ok(answer) -> drain(calls, [answer, ..collected])
    Error(Nil) -> list.reverse(collected)
  }
}

fn user(text: String) -> message.AgentMessage {
  message.UserMessage(
    content: [message.UserText(text:, text_signature: None)],
    timestamp: 0,
  )
}

// The two settlements a tool reply can be, written as two constructors
// rather than one taking a flag: `is_error` is the thing under test, and
// a call site reading `reply_ok("secret")` says which one it means.
fn reply_ok(text: String) -> message.AgentMessage {
  settled(
    text,
    message.ToolResultMessage(
      tool_call_id: "call-1",
      tool_name: "bash",
      content: [],
      details: None,
      usage: None,
      added_tool_names: None,
      is_error: False,
      timestamp: 0,
    ),
  )
}

fn reply_failed(text: String) -> message.AgentMessage {
  settled(
    text,
    message.ToolResultMessage(
      tool_call_id: "call-1",
      tool_name: "bash",
      content: [],
      details: None,
      usage: None,
      added_tool_names: None,
      is_error: True,
      timestamp: 0,
    ),
  )
}

fn settled(text: String, shell: message.AgentMessage) -> message.AgentMessage {
  case shell {
    message.ToolResultMessage(..) ->
      message.ToolResultMessage(..shell, content: [
        message.ToolResultText(text:, text_signature: None),
      ])
    _other -> shell
  }
}

fn text_of(one: message.AgentMessage) -> String {
  case one {
    message.UserMessage(content: [message.UserText(text:, ..)], ..) -> text
    _other -> "?"
  }
}

fn repeat(unit: String, times: Int) -> String {
  list.repeat(unit, times) |> list.fold("", fn(built, part) { built <> part })
}
