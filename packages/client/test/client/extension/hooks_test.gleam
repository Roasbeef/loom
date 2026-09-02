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
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import machine/operation
import machine/strand
import runtime/effects
import session/session
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

pub fn a_run_start_injection_is_collected_and_rendered_test() {
  let bus =
    started([
      hooks.Extension(
        name: "quiet",
        events: ["before_agent_start"],
        invoke: answering("{\"inject\":null}"),
      ),
      hooks.Extension(
        name: "web_search",
        events: ["before_agent_start"],
        invoke: answering("{\"inject\":\"3 searches left\"}"),
      ),
    ])
  let assert [injected] =
    hooks.run_start_injections(bus, operation(), "main", 7)
    as "only the extension with something to say injects"
  assert text_of(injected) == hooks.injection("web_search", "3 searches left")
}

pub fn a_block_with_no_reason_is_still_a_block_test() {
  let bus =
    started([
      hooks.Extension(
        name: "terse",
        events: ["tool_call"],
        invoke: answering("{\"verdict\":\"block\"}"),
      ),
    ])

  // Failing open on an unreadable reason would turn an author's empty
  // string into a silently disabled gate, which is the one direction a
  // gate must not fail in when the extension did say "block".
  assert hooks.gate(bus, operation(), "bash", json.Object([]), 0)
    == hooks.Block(extension: "terse", reason: "it gave no reason")
}

pub fn a_tool_result_hook_cannot_write_the_usage_ledger_test() {
  let billed =
    settled(
      "free",
      call: "call-1",
      settlement: Succeeded,
      usage: Some(core_usage()),
      at: 999,
    )
  let bus =
    started([
      hooks.Extension(
        name: "biller",
        events: ["tool_result"],
        invoke: retexting(billed),
      ),
    ])

  // The content is the hook's; every other field is the harness's, so a
  // usage the hook attached never becomes a durable ledger row.
  assert hooks.fold_tool_result(bus, reply_ok("secret")) == reply_ok("free")
}

pub fn a_tool_result_hook_cannot_move_the_reply_to_another_call_test() {
  let elsewhere =
    settled("free", call: "call-2", settlement: Succeeded, usage: None, at: 0)
  let bus =
    started([
      hooks.Extension(
        name: "mover",
        events: ["tool_result"],
        invoke: retexting(elsewhere),
      ),
    ])

  // The rebuild keeps the original's coordinates, so the transform is
  // applied to the reply it was given and lands nowhere else.
  assert hooks.fold_tool_result(bus, reply_ok("secret")) == reply_ok("free")
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
  let folded = hooks.fold_context(bus, operation(), [user("start")])
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
  assert hooks.fold_context(bus, operation(), [user("start")])
    == [user("start")]
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

  // The hook's content is taken and its claim about the settlement is
  // not: the reply the driver commits still reports the failure.
  assert hooks.fold_tool_result(bus, reply_failed("it failed"))
    == reply_failed("all fine")
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
  let folded = hooks.fold_context(bus, operation(), [user("start")])
  assert list.map(folded, text_of) == ["start", "one"]
}

pub fn a_malformed_verdict_allows_the_call_and_drops_the_handler_test() {
  let bus =
    started([
      hooks.Extension(
        name: "typo",
        events: ["tool_call"],
        // One capital letter. The first shape of this module sent
        // `Allow` and carried on, which is a gate silently disabled for
        // the rest of the session with nothing anywhere saying so.
        invoke: answering("{\"verdict\":\"Block\"}"),
      ),
      hooks.Extension(name: "sound", events: ["tool_call"], invoke: allow()),
    ])

  // The call in hand is allowed: dropping a handler is not a reason to
  // refuse work the built-in clearance cleared.
  assert hooks.gate(bus, operation(), "bash", json.Object([]), 0) == hooks.Allow

  // And the extension has lost its place, so the next call is not gated
  // on an answer nobody can read.
  assert hooks.subscribers(bus) == 1
}

// --- wiring ---------------------------------------------------------------

pub fn a_blocked_call_becomes_the_attributed_refusal_test() {
  let bus =
    started([
      hooks.Extension(
        name: "web_search",
        events: ["tool_call"],
        invoke: blocking("the workspace is frozen"),
      ),
    ])
  let wired = hooks.wire(cleared_effects(), bus, no_session(), clock.fixed(0))
  assert wired.tools.clear(clearance_query("bash"))
    == effects.ClearanceRefused(
      reason: "web_search blocked bash: the workspace is frozen",
    )
}

pub fn a_refused_clearance_never_wakes_the_bus_test() {
  let calls = recorder()
  let bus =
    started([
      hooks.Extension(
        name: "gate",
        events: ["tool_call"],
        invoke: recording(calls, allow()),
      ),
    ])
  let wired = hooks.wire(refusing_effects(), bus, no_session(), clock.fixed(0))

  // A call the harness already refused is not a call an extension has an
  // opinion about, and asking would wake a satellite for nothing.
  assert wired.tools.clear(clearance_query("bash"))
    == effects.ClearanceRefused(reason: "the tool `bash` is unavailable")
  assert seen(calls) == []
}

pub fn the_unwired_invoker_says_the_satellite_is_gone_test() {
  let invoke = hooks.unwired()
  assert invoke("web_search", "tool_call", msgpack.NilValue, 0)
    == Error(hooks.Gone)
}

// --- fixtures -------------------------------------------------------------

// An effects record whose only real part is the tool surface's answer.
// `wire` wraps five slots and this test exercises one of them, so the
// rest are the inert defaults rather than a session's worth of scaffolding.
fn effects_answering(clearance: effects.Clearance) -> effects.Effects {
  effects.Effects(
    clock: clock.fixed(0),
    entropy: fn() { 0 },
    timers: effects.Timers(after: fn(_delay, _wake) { Nil }),
    provider: effects.ProviderSurface(
      request: fn(_spec) { panic as "no request is made" },
      timeout_ms: 0,
    ),
    tools: effects.ToolSurface(
      clear: fn(_query) { clearance },
      run: fn(_run) { panic as "no tool is run" },
      replay_still_safe: fn(_name) { False },
      execution_mode: fn(_name) { effects.ExclusiveExecution },
    ),
    hooks: effects.default_hooks(),
  )
}

fn cleared_effects() -> effects.Effects {
  effects_answering(effects.Cleared(
    effective_arguments: json.Object([]),
    replay: operation.ReplayNever,
  ))
}

fn refusing_effects() -> effects.Effects {
  effects_answering(effects.ClearanceRefused(
    reason: "the tool `bash` is unavailable",
  ))
}

fn clearance_query(tool: String) -> effects.ClearanceQuery {
  effects.ClearanceQuery(
    operation: operation(),
    step_id: "step-1",
    source_index: 0,
    call: message.ToolCall(
      id: "call-1",
      name: tool,
      arguments: json.Object([]),
      thought_signature: None,
      namespace: None,
    ),
    configuration: strand.StrandConfiguration(
      model: strand.ModelIdentity(provider: "p", model_id: "m"),
      thinking_level: strand.ThinkingOff,
      active_tool_names: [tool],
    ),
    grants: [],
  )
}

// `wire`'s `run_start` slot resolves a strand through the session store,
// and nothing here drives a run, so an unopened session is exactly what
// the gate tests need: the slot is never called.
fn no_session() -> session.Session {
  let assert Ok(opened) = session.open_memory(clock.fixed(0))
    as "an in-memory session always opens"
  opened
}

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

// Whether a settled reply reports an in-band failure. A type rather than
// a `Bool` at three call sites, because `is_error` is the thing under
// test and `settled(.., True, ..)` names nothing.
type Settlement {
  Succeeded
  Failed
}

// A settled tool reply, with every field a hook might try to move named
// at the call site: which call it settles, whether it failed, and what
// usage it claims. `usage` is here because a `ToolResultMessage`
// carrying one becomes a durable ledger row, so "the hook could not
// change it" is a property worth writing down rather than assuming.
fn settled(
  text: String,
  call call: String,
  settlement settlement: Settlement,
  usage usage: option.Option(message.Usage),
  at at: Int,
) -> message.AgentMessage {
  message.ToolResultMessage(
    tool_call_id: call,
    tool_name: "bash",
    content: [message.ToolResultText(text:, text_signature: None)],
    details: None,
    usage:,
    added_tool_names: None,
    is_error: settlement == Failed,
    timestamp: at,
  )
}

fn reply_ok(text: String) -> message.AgentMessage {
  settled(text, call: "call-1", settlement: Succeeded, usage: None, at: 0)
}

fn reply_failed(text: String) -> message.AgentMessage {
  settled(text, call: "call-1", settlement: Failed, usage: None, at: 0)
}

// A usage a hook might try to attach. The numbers do not matter; that
// the field survives the fold or does not is the whole question.
fn core_usage() -> message.Usage {
  message.Usage(
    input: 1,
    output: 1,
    cache_read: 0,
    cache_write: 0,
    cache_write_1h: None,
    reasoning: None,
    total_tokens: 2,
    cost: message.UsageCost(
      input: 0.0,
      output: 0.0,
      cache_read: 0.0,
      cache_write: 0.0,
      total: 0.0,
    ),
  )
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
