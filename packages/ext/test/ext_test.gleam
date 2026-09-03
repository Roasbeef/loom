//// The extension prelude's own tests: the vocabulary, the dispatch table,
//// and one real round trip of the satellite runtime over a faked
//// capability channel.
////
//// The loop test is the one that matters. `ext/runtime.serve` is the only
//// line an extension author writes that they cannot debug themselves, so
//// it is exercised end to end here — a `hook_call` arrives, the tool runs,
//// a `hook_result` goes back under the same frame id, and the satellite
//// stays up for the next one — with function values standing in for the
//// socket, exactly as `packages/cap`'s own boot tests do.

import cap/internal/dispatch as cap_dispatch
import cap/report
import cap/runtime as cap_runtime
import core/msgpack
import ext.{type Ctx, type Refusal, ContinueRun, Refusal, TerminateRun, Text}
import ext/hook
import ext/runtime
import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/list
import gleam/otp/actor
import gleam/string
import gleeunit

pub fn main() -> Nil {
  gleeunit.main()
}

// --- the vocabulary -------------------------------------------------------

pub fn text_builds_a_continuing_outcome_test() {
  assert ext.text("done")
    == ext.Outcome(content: [Text(text: "done")], terminate: ContinueRun)
}

pub fn json_builds_a_continuing_outcome_test() {
  let outcome = ext.json(json.object([#("n", json.int(1))]))
  assert outcome.terminate == ContinueRun
}

pub fn refuse_is_an_error_test() {
  assert ext.refuse("no such city") == Error(Refusal(message: "no such city"))
}

/// A decode failure names the field, because the model reads the refusal
/// and retries: "expected String at .city" is a repair instruction and
/// "bad arguments" is a dead end.
pub fn decode_args_names_the_field_test() {
  let assert Error(Refusal(message:)) =
    ext.decode_args(dynamic_of("{\"city\": 4}"), city_decoder())
    as "an integer where a string was wanted must not decode"
  assert string.contains(message, "city")
  assert string.contains(message, "String")
}

pub fn decode_args_passes_a_good_call_test() {
  assert ext.decode_args(dynamic_of("{\"city\": \"oslo\"}"), city_decoder())
    == Ok("oslo")
}

// --- dispatch, without a channel -----------------------------------------

pub fn answer_runs_the_named_tool_test() {
  let produced =
    runtime.answer(
      [#("echo_tool", echo_tool)],
      [],
      asked("echo_tool", "{\"say\": \"hi\"}"),
    )
  assert produced
    == cap_runtime.Answered(body([text_block("hi")], terminating: False))
}

pub fn answer_carries_a_terminating_reply_test() {
  let produced = runtime.answer([#("stop", stopper)], [], asked("stop", "{}"))
  assert produced
    == cap_runtime.Answered(body([text_block("halted")], terminating: True))
}

pub fn answer_serialises_a_json_block_test() {
  let produced = runtime.answer([#("shape", shaper)], [], asked("shape", "{}"))
  assert produced
    == cap_runtime.Answered(body([json_block("{\"n\":1}")], terminating: False))
}

/// An unknown name means the manifest and the artifact disagree, so the
/// refusal shows both sides: what was asked for, and what is served.
pub fn answer_names_what_it_serves_test() {
  let assert cap_runtime.Refused(code:, message:) =
    runtime.answer(
      [#("echo_tool", echo_tool), #("stop", stopper)],
      [],
      asked("weather", "{}"),
    )
    as "a tool this artifact does not serve must not run"
  assert code == runtime.unknown_tool_code
  assert string.contains(message, "weather")
  assert string.contains(message, "echo_tool, stop")
}

pub fn answer_reports_a_refusal_under_its_own_code_test() {
  let assert cap_runtime.Refused(code:, message:) =
    runtime.answer([#("no", refuser)], [], asked("no", "{}"))
    as "a refusal must reach the harness as an in-band failure"
  assert code == runtime.refused_code
  assert string.contains(message, "not today")
}

/// Arguments that are not JSON never passed a schema check on the harness
/// side, so the satellite says which side is broken rather than guessing
/// past it into a tool.
pub fn answer_refuses_unparseable_arguments_test() {
  let assert cap_runtime.Refused(code:, message:) =
    runtime.answer(
      [#("echo_tool", echo_tool)],
      [],
      asked("echo_tool", "not json"),
    )
    as "arguments that are not JSON must not reach a tool"
  assert code == runtime.bad_arguments_code
  assert string.contains(message, "not JSON")
}

// --- events ---------------------------------------------------------------

pub fn answer_runs_a_registered_event_test() {
  let seen = process.new_subject()
  let produced =
    runtime.answer(
      [],
      [
        #(
          "session_start",
          hook.OnSessionStart(fn() { process.send(seen, Nil) }),
        ),
      ],
      event("session_start", "{}"),
    )
  assert produced == cap_runtime.Answered(report.string("{}"))
  assert process.receive(seen, within: 0) == Ok(Nil)
}

/// The manifest declares an event and the module implements one, and the
/// two come from different places. A pair that disagrees is an install
/// that does not hold together, so it is refused under its own code
/// rather than served as whichever half was read.
pub fn a_hook_that_answers_another_event_is_refused_test() {
  let assert cap_runtime.Refused(code:, message:) =
    runtime.answer(
      [],
      [#("session_start", hook.OnToolCall(fn(_call) { hook.Allow }))],
      event("session_start", "{}"),
    )
    as "a mismatched pair must not be served"
  assert code == runtime.mismatched_hook_code
  assert string.contains(message, "tool_call")
}

/// A `tool_call` hook's verdict crosses as the JSON the harness's bus
/// reads, marshalled in `ext/hook` and carried here untouched.
pub fn a_tool_call_hook_answers_a_verdict_test() {
  let produced =
    runtime.answer(
      [],
      [#("tool_call", hook.OnToolCall(fn(_call) { hook.Block("not here") }))],
      event(
        "tool_call",
        "{\"op_id\":\"op\",\"tool\":\"bash\",\"arguments\":{},\"source_index\":0}",
      ),
    )
  assert produced
    == cap_runtime.Answered(report.string(
      "{\"verdict\":\"block\",\"reason\":\"not here\"}",
    ))
}

/// An extension is offered every moment and cares about almost none of
/// them, so an event with no handler is an ordinary answer under a code
/// the bus reads, not a fault that costs the satellite its node.
pub fn answer_reports_an_unhandled_event_test() {
  let assert cap_runtime.Refused(code:, message:) =
    runtime.answer([], [], event("session_start", "{}"))
    as "an event with no handler must answer rather than crash"
  assert code == runtime.unhandled_code
  assert string.contains(message, "session_start")
}

// --- the loop over a faked channel ---------------------------------------

/// `serve`'s whole contract, driven over injected function values: the
/// harness asks twice on one satellite, each answer carries its own frame
/// id, and the node is still there in between — which is the property the
/// per-call node never had.
pub fn the_runtime_answers_two_invocations_on_one_node_test() {
  let served = start_serving([#("echo_tool", echo_tool)], [])

  push(served, hook_call(11, "tool", "echo_tool", "{\"say\": \"first\"}"))
  assert answered(served, 11) == body([text_block("first")], terminating: False)

  push(served, hook_call(12, "tool", "echo_tool", "{\"say\": \"second\"}"))
  assert answered(served, 12)
    == body([text_block("second")], terminating: False)
}

/// A tool that panics is an answer, not a dead satellite: the invocation
/// is refused as `crashed` and the next one is served normally.
pub fn a_crashing_tool_is_an_answer_test() {
  let served =
    start_serving([#("boom", crasher), #("echo_tool", echo_tool)], [])

  push(served, hook_call(21, "tool", "boom", "{}"))
  let #(code, _message) = refusal(served, 21)
  assert code == "crashed"

  push(served, hook_call(22, "tool", "echo_tool", "{\"say\": \"alive\"}"))
  assert answered(served, 22) == body([text_block("alive")], terminating: False)
}

/// The token on the wire is the invocation's, not the node's. A
/// `cap_call` the tool makes while answering carries the token the
/// `hook_call` handed over — which is the whole reason a satellite may
/// outlive an execution without outliving its authority.
pub fn a_cap_call_presents_the_invocation_token_test() {
  let served = start_serving([#("emitter", emitter)], [])

  push(served, hook_call_with_token(31, <<42, 42>>, "emitter", "{}"))
  let assert Ok(frame) = process.receive(served.sent, within: 5000)
    as "the tool must reach a capability"
  assert cap_call_token(frame) == <<42, 42>>
}

// --- tool fixtures --------------------------------------------------------

fn echo_tool(arguments: Dynamic, _ctx: Ctx) -> Result(ext.Outcome, Refusal) {
  use say <- try_refusal(ext.decode_args(arguments, say_decoder()))
  Ok(ext.text(say))
}

fn stopper(_arguments: Dynamic, _ctx: Ctx) -> Result(ext.Outcome, Refusal) {
  Ok(ext.Outcome(content: [Text(text: "halted")], terminate: TerminateRun))
}

fn shaper(_arguments: Dynamic, _ctx: Ctx) -> Result(ext.Outcome, Refusal) {
  Ok(ext.json(json.object([#("n", json.int(1))])))
}

fn refuser(_arguments: Dynamic, _ctx: Ctx) -> Result(ext.Outcome, Refusal) {
  ext.refuse("not today")
}

fn crasher(_arguments: Dynamic, _ctx: Ctx) -> Result(ext.Outcome, Refusal) {
  panic as "this tool is written badly on purpose"
}

// A tool that reaches a capability, so the token it presents can be read
// off the wire. The emit fails (nothing answers it), which is fine: what
// is under test is the frame, not the answer.
fn emitter(_arguments: Dynamic, ctx: Ctx) -> Result(ext.Outcome, Refusal) {
  ctx.report("narrating")
  Ok(ext.text("done"))
}

fn try_refusal(
  outcome: Result(a, Refusal),
  then: fn(a) -> Result(ext.Outcome, Refusal),
) -> Result(ext.Outcome, Refusal) {
  case outcome {
    Ok(value) -> then(value)
    Error(refusal) -> Error(refusal)
  }
}

fn say_decoder() -> decode.Decoder(String) {
  use say <- decode.field("say", decode.string)
  decode.success(say)
}

fn city_decoder() -> decode.Decoder(String) {
  use city <- decode.field("city", decode.string)
  decode.success(city)
}

// --- value fixtures -------------------------------------------------------

fn asked(tool: String, args: String) -> cap_runtime.Asked {
  cap_runtime.Asked(
    invocation: cap_runtime.Tool(name: tool),
    args: report.object([
      #("args", report.string(args)),
      #("strand", report.string("main")),
    ]),
    deadline_ms: 5000,
  )
}

fn event(name: String, args: String) -> cap_runtime.Asked {
  cap_runtime.Asked(
    invocation: cap_runtime.Event(name:),
    args: report.string(args),
    deadline_ms: 5000,
  )
}

fn dynamic_of(text: String) -> Dynamic {
  let assert Ok(value) = json.parse(from: text, using: decode.dynamic)
    as "the fixture must be JSON"
  value
}

fn text_block(text: String) -> report.Value {
  report.object([
    #("type", report.string("text")),
    #("text", report.string(text)),
  ])
}

fn json_block(rendered: String) -> report.Value {
  report.object([
    #("type", report.string("json")),
    #("json", report.string(rendered)),
  ])
}

fn body(
  blocks: List(report.Value),
  terminating terminating: Bool,
) -> report.Value {
  report.object([
    #("content", report.list(blocks)),
    #("terminate", report.bool(terminating)),
  ])
}

fn text_of(value: msgpack.MsgPackValue, key: String) -> String {
  let assert Ok(msgpack.StringValue(text)) = report.field(value, key)
    as "the field must be text"
  text
}

// --- frames ---------------------------------------------------------------

fn cap_call_token(frame: BitArray) -> BitArray {
  let assert Ok(#(_id, body)) = frame_parts(frame)
    as "an outbound frame must be a well-formed envelope"
  let assert Ok(msgpack.BinaryValue(token)) = report.field(body, "token")
    as "a cap_call carries a token"
  token
}

fn frame_parts(frame: BitArray) -> Result(#(Int, msgpack.MsgPackValue), Nil) {
  let assert <<_size:size(32), payload:bits>> = frame
    as "every frame carries a 32-bit length prefix"
  let assert Ok(envelope) = msgpack.decode(payload)
    as "an outbound frame must be msgpack"
  let assert Ok(msgpack.IntValue(id)) = report.field(envelope, "id")
    as "a frame carries an id"
  let assert Ok(body) = report.field(envelope, "body")
    as "a frame carries a body"
  Ok(#(id, body))
}

fn hook_call(id: Int, kind: String, name: String, args: String) -> BitArray {
  hook_call_frame(id, <<9, 9>>, kind, name, [
    #("args", msgpack.StringValue(args)),
    #("strand", msgpack.StringValue("main")),
  ])
}

fn hook_call_with_token(
  id: Int,
  token: BitArray,
  name: String,
  args: String,
) -> BitArray {
  hook_call_frame(id, token, "tool", name, [
    #("args", msgpack.StringValue(args)),
    #("strand", msgpack.StringValue("main")),
  ])
}

fn hook_call_frame(
  id: Int,
  token: BitArray,
  kind: String,
  name: String,
  args: List(#(String, msgpack.MsgPackValue)),
) -> BitArray {
  frame(id, "hook_call", [
    #("token", msgpack.BinaryValue(token)),
    #("kind", msgpack.StringValue(kind)),
    #("name", msgpack.StringValue(name)),
    #("args", report.object(args)),
    #("deadline_ms", msgpack.IntValue(5000)),
  ])
}

fn frame(
  id: Int,
  kind: String,
  fields: List(#(String, msgpack.MsgPackValue)),
) -> BitArray {
  let envelope =
    report.object([
      #("v", report.int(1)),
      #("id", report.int(id)),
      #("kind", report.string(kind)),
      #("body", report.object(fields)),
    ])
  let assert Ok(payload) = msgpack.encode(envelope)
    as "a fixture frame must encode"
  let size = bit_array.byte_size(payload)
  <<size:size(32), payload:bits>>
}

// --- the faked channel ----------------------------------------------------

// A test double for the inbound socket: `WirePull` blocks until a
// `WirePush` provides bytes, so the runtime's `recv` behaves like a real
// blocking read and the test decides exactly when a frame arrives.
type WireMsg {
  WirePush(bytes: BitArray)
  WirePull(reply: Subject(Result(BitArray, Nil)))
}

type WireState {
  WireState(
    queue: List(BitArray),
    waiting: List(Subject(Result(BitArray, Nil))),
  )
}

type Served {
  Served(sent: Subject(BitArray), wire: Subject(WireMsg))
}

// One serving satellite over a faked channel.
//
// The VM-global channel slot is reset first: every test in this module
// stands one satellite up in the same VM, where production gives each a
// node of its own, and `install_exclusive` would otherwise refuse the
// second — correctly, since the first's channel actor is still alive.
fn start_serving(
  tools: List(#(String, ext.Tool)),
  hooks: List(runtime.Declared),
) -> Served {
  cap_dispatch.reset()
  let sent = process.new_subject()
  let wire = start_wire()
  let transport =
    cap_runtime.Transport(
      send: fn(bytes) {
        process.send(sent, bytes)
        Nil
      },
      recv: fn() { process.call(wire, waiting: 60_000, sending: WirePull) },
      outcome_sink: fn(_bytes) { Nil },
    )
  let _ =
    process.spawn_unlinked(fn() {
      let _ =
        cap_runtime.serve_over(<<7, 7, 7>>, transport, fn(ask) {
          runtime.answer(tools, hooks, ask)
        })
      Nil
    })
  Served(sent:, wire:)
}

fn push(served: Served, bytes: BitArray) -> Nil {
  process.send(served.wire, WirePush(bytes:))
}

// The `hook_result` for `id`, skipping any `cap_call` a tool made on the
// way. A satellite writes both on one socket, so a reader that took the
// first frame it saw would be reading the tool's own traffic.
fn answered(served: Served, id: Int) -> msgpack.MsgPackValue {
  let body = hook_result_body(served, id)
  let assert Ok(msgpack.BoolValue(True)) = report.field(body, "ok")
    as "the invocation must have been answered"
  let assert Ok(value) = report.field(body, "value")
    as "an answered hook_result carries a value"
  value
}

fn refusal(served: Served, id: Int) -> #(String, String) {
  let body = hook_result_body(served, id)
  let assert Ok(msgpack.BoolValue(False)) = report.field(body, "ok")
    as "the invocation must have been refused"
  let assert Ok(error) = report.field(body, "error")
    as "a refused hook_result carries an error"
  #(text_of(error, "code"), text_of(error, "msg"))
}

fn hook_result_body(served: Served, id: Int) -> msgpack.MsgPackValue {
  let assert Ok(frame) = process.receive(served.sent, within: 5000)
    as "the satellite must answer every invocation"
  let assert Ok(#(seen, body)) = frame_parts(frame)
    as "an outbound frame must be a well-formed envelope"
  case seen == id {
    True -> body
    False -> hook_result_body(served, id)
  }
}

fn start_wire() -> Subject(WireMsg) {
  let assert Ok(started) =
    actor.new(WireState(queue: [], waiting: []))
    |> actor.on_message(wire_handle)
    |> actor.start
    as "the fake wire actor must start"
  started.data
}

fn wire_handle(
  state: WireState,
  msg: WireMsg,
) -> actor.Next(WireState, WireMsg) {
  case msg {
    WirePush(bytes:) ->
      case state.waiting {
        [first, ..rest] -> {
          process.send(first, Ok(bytes))
          actor.continue(WireState(..state, waiting: rest))
        }
        [] ->
          actor.continue(
            WireState(..state, queue: list.append(state.queue, [bytes])),
          )
      }
    WirePull(reply:) ->
      case state.queue {
        [first, ..rest] -> {
          process.send(reply, Ok(first))
          actor.continue(WireState(..state, queue: rest))
        }
        [] ->
          actor.continue(
            WireState(..state, waiting: list.append(state.waiting, [reply])),
          )
      }
  }
}
