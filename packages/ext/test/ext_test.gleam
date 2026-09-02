//// The extension prelude's own tests: the vocabulary, the dispatch table,
//// and one real round trip of the satellite runtime over a faked
//// capability channel.
////
//// The round-trip test is the one that matters. `ext/runtime.serve` is the
//// only line an extension author writes that they cannot debug themselves,
//// so it is exercised end to end here — a `cap_call` goes out, a
//// `cap_result` comes back, the tool runs, and the terminal `outcome`
//// frame is read and decoded — with function values standing in for the
//// socket, exactly as `packages/cap`'s own boot tests do.

import cap/ext as cap_ext
import cap/report
import cap/runtime as cap_runtime
import core/msgpack
import ext.{type Ctx, type Refusal, ContinueRun, Refusal, TerminateRun, Text}
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

pub fn dispatch_runs_the_named_tool_test() {
  let outcome =
    runtime.dispatch(
      [#("echo_tool", echo_tool)],
      call("echo_tool", "{\"say\": \"hi\"}"),
    )
  assert outcome == report.value(body([text_block("hi")], terminating: False))
}

pub fn dispatch_carries_a_terminating_reply_test() {
  let outcome = runtime.dispatch([#("stop", stopper)], call("stop", "{}"))
  assert outcome
    == report.value(body([text_block("halted")], terminating: True))
}

pub fn dispatch_serialises_a_json_block_test() {
  let outcome = runtime.dispatch([#("shape", shaper)], call("shape", "{}"))
  assert outcome
    == report.value(body([json_block("{\"n\":1}")], terminating: False))
}

/// An unknown name means the manifest and the artifact disagree, so the
/// refusal shows both sides: what was asked for, and what is served.
pub fn dispatch_names_what_it_serves_test() {
  let assert report.Errored(message:, details:) =
    runtime.dispatch(
      [#("echo_tool", echo_tool), #("stop", stopper)],
      call("weather", "{}"),
    )
    as "a tool this artifact does not serve must not run"
  assert string.contains(message, "weather")
  assert string.contains(message, "echo_tool, stop")
  assert details == report.object([#("tool", report.string("weather"))])
}

pub fn dispatch_reports_a_refusal_as_an_error_test() {
  let assert report.Errored(message:, ..) =
    runtime.dispatch([#("no", refuser)], call("no", "{}"))
    as "a refusal must reach the harness as an error outcome"
  assert string.contains(message, "not today")
}

/// Arguments that are not JSON never passed a schema check on the harness
/// side, so the satellite says which side is broken rather than guessing
/// past it into a tool.
pub fn dispatch_refuses_unparseable_arguments_test() {
  let assert report.Errored(message:, ..) =
    runtime.dispatch([#("echo_tool", echo_tool)], call("echo_tool", "not json"))
    as "arguments that are not JSON must not reach a tool"
  assert string.contains(message, "not JSON")
}

// --- the round trip over a faked channel ---------------------------------

/// `serve`'s whole contract, driven over injected function values: the
/// runtime asks for its call with `ext.call`, dispatches it, and writes
/// exactly one `outcome` frame carrying the tool's reply.
pub fn the_runtime_fetches_its_call_and_answers_test() {
  let booted = boot(fn() { runtime.answer([#("echo_tool", echo_tool)]) })

  // The first thing an extension satellite says is "which call am I
  // serving?" — nothing else can happen until the harness answers.
  let assert Ok(frame) = process.receive(booted.sent, within: 5000)
    as "the runtime must open with a cap_call"
  let #(id, cap) = cap_call_of(frame)
  assert cap == "ext.call"

  process.send(
    booted.wire,
    WirePush(
      bytes: cap_result(id, [
        #("tool", msgpack.StringValue("echo_tool")),
        #("args", msgpack.StringValue("{\"say\": \"round trip\"}")),
        #("strand", msgpack.StringValue("main")),
        #("deadline_ms", msgpack.IntValue(5000)),
      ]),
    ),
  )

  let assert Ok(outcome) = process.receive(booted.outcomes, within: 5000)
    as "the runtime must write exactly one outcome frame"
  assert outcome_body(outcome)
    == report.to_msgpack(
      report.value(body([text_block("round trip")], terminating: False)),
    )
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

fn call(tool: String, args: String) -> cap_ext.Call {
  cap_ext.Call(tool:, args:, strand: "main", deadline_ms: 5000)
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

// The `id` and `cap` of an outbound `cap_call` frame, read back off the
// wire so the reply can be correlated the way the host would.
fn cap_call_of(frame: BitArray) -> #(Int, String) {
  let assert <<_size:size(32), payload:bits>> = frame
    as "every frame carries a 32-bit length prefix"
  let assert Ok(envelope) = msgpack.decode(payload)
    as "an outbound frame must be msgpack"
  let assert Ok(inner) = report.field(envelope, "body")
    as "a cap_call carries a body"
  let assert Ok(msgpack.IntValue(id)) = report.field(envelope, "id")
    as "a cap_call carries an id"
  #(id, text_of(inner, "cap"))
}

fn cap_result(
  id: Int,
  fields: List(#(String, msgpack.MsgPackValue)),
) -> BitArray {
  frame(id, "cap_result", [
    #("ok", msgpack.BoolValue(True)),
    #("value", report.object(fields)),
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

fn outcome_body(frame: BitArray) -> msgpack.MsgPackValue {
  let assert <<_size:size(32), payload:bits>> = frame
    as "every frame carries a 32-bit length prefix"
  let assert Ok(envelope) = msgpack.decode(payload)
    as "the outcome frame must be msgpack"
  let assert Ok(inner) = report.field(envelope, "body")
    as "the outcome frame carries a body"
  inner
}

// --- the faked channel ----------------------------------------------------

// A test double for the inbound socket: `WirePull` blocks until a
// `WirePush` provides bytes, so the runtime's `recv` behaves like a real
// blocking read and the test decides exactly when the reply arrives.
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

type Booted {
  Booted(
    sent: Subject(BitArray),
    wire: Subject(WireMsg),
    outcomes: Subject(BitArray),
  )
}

fn boot(program: fn() -> report.Outcome) -> Booted {
  let sent = process.new_subject()
  let outcomes = process.new_subject()
  let wire = start_wire()
  let transport =
    cap_runtime.Transport(
      send: fn(bytes) {
        process.send(sent, bytes)
        Nil
      },
      recv: fn() { process.call(wire, waiting: 60_000, sending: WirePull) },
      outcome_sink: fn(bytes) {
        process.send(outcomes, bytes)
        Nil
      },
    )
  let _ =
    process.spawn_unlinked(fn() {
      let _ = cap_runtime.boot(<<7, 7, 7>>, transport, program)
      Nil
    })
  Booted(sent:, wire:, outcomes:)
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
