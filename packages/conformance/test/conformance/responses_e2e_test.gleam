//// Responses through the real gateway, wiring, runtime and memory store.
//// Only HTTP delivery and a pure fixture tool are substituted. Complete SSE
//// witnesses exercise incremental assembly before the runtime commits either
//// assistant response; the next request must replay the encrypted reasoning
//// and the actual tool result from that committed conversation.
////
//// This proves request-only secret injection, not redaction of arbitrary
//// provider output. No fixture response echoes the canary. It needs no API
//// account, network, native helper or filesystem effect.

import broker/broker
import broker/exec
import broker/policy
import broker/token
import client/escalate
import client/wiring
import core/clock
import core/codec
import core/entry
import core/json.{type JsonValue}
import core/message
import core/register
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import machine/operation
import machine/strand
import provider/gateway
import provider/http
import provider/model
import provider/secret
import runtime/api
import session/session
import storage/storage
import support/script
import tools/tool

const canary = "responses-conformance-request-only-canary"

const encrypted = "opaque-encrypted-reasoning-fixture"

const tool_name = "fixture_answer"

const model_id = "responses-fixture-model"

/// Runs two provider settlements around one real runtime tool dispatch.
///
/// ## Examples
///
/// Run `scripts/test.sh conformance --match responses_e2e`.
pub fn responses_tool_turn_replays_reasoning_without_credentials_test() -> Nil {
  let requests = process.new_subject()
  let executions = process.new_subject()
  let assert Ok(sess) = session.open_memory(clock.stepping(1000, 1))
    as "the fixture store must open"
  let assert Ok(brk) =
    broker.start(
      broker.BrokerConfig(
        entropy: token.production_entropy(),
        clock: clock.stepping(1000, 1),
        checkout: fn() { Error(exec.AllBusy(size: 0)) },
        checkin: fn(_helper) { Nil },
      ),
    )
    as "the helperless broker must start"
  let effects = wiring.build_effects(config(sess, brk, requests, executions))
  let configuration =
    strand.StrandConfiguration(
      model: strand.ModelIdentity("responses", model_id),
      thinking_level: strand.ThinkingHigh,
      active_tool_names: [tool_name],
    )
  let assert Ok(runtime) =
    api.open(sess, effects, api.default_options(configuration))
    as "the real runtime must open"

  // Capture the outcome and durable reads before assertions so a failed stream
  // still closes its original runtime. Runtime close also closes the store.
  let admitted =
    api.prompt(runtime, [
      message.UserMessage(
        content: [message.UserText("Answer using the fixture tool.", None)],
        timestamp: 0,
        origin: None,
      ),
    ])
  let outcome =
    admitted
    |> result.map_error(fn(_) { Nil })
    |> result.try(fn(op) { api.await_result(runtime, op, within_ms: 5000) })
  let rows = storage.scan_entries(sess.store, storage.entry_scan())
  let ledger = storage.scan_usage(sess.store, storage.usage_scan())
  let register_rows = stored_registers(sess)
  let closed = api.close(runtime)
  broker.stop(brk)

  let assert Ok(Nil) = closed as "the runtime must retire"
  let assert Ok(_) = admitted as "the prompt must be admitted"
  let assert Ok(operation.RunLastResult(outcome: operation.RunCompleted(..), ..)) =
    outcome
    as "the Responses tool loop must complete within its deadline"
  let assert Ok(entries) = rows as "durable entries must decode"
  let assert Ok(usage_rows) = ledger as "durable usage must decode"
  let assert Ok(registers) = register_rows
    as "every durable namespace must remain readable"
  assert_conversation(entries)
  assert list.map(usage_rows, fn(row) { row.usage })
    == [usage(80, 20, 20, 7), usage(110, 12, 40, 3)]

  // Exactly one trusted tool invocation and two outbound requests distinguish
  // an actual continuation from duplicated settlement or a canned final reply.
  let assert Ok(json.Object([])) = process.receive(executions, 1000)
    as "the runtime must dispatch the decoded empty argument object"
  assert process.receive(executions, 0) == Error(Nil)
  let assert Ok(first) = process.receive(requests, 1000)
    as "the initial HTTP request must be captured"
  let assert Ok(second) = process.receive(requests, 1000)
    as "the continuation HTTP request must be captured"
  assert process.receive(requests, 0) == Error(Nil)
  assert_request(first)
  assert_request(second)
  let assert Ok(initial) = json.parse(first.body)
    as "the initial request must decode"
  assert field(initial, "input")
    == json.Array([
      json.Object([
        #("role", json.String("user")),
        #(
          "content",
          json.Array([text_part("input_text", "Answer using the fixture tool.")]),
        ),
      ]),
    ])
  assert_replay(second.body)

  let stored =
    list.map(entries, codec.encode_entry)
    |> list.append(list.map(usage_rows, codec.encode_usage_row))
    |> list.append(registers)
  assert !string.contains(json.to_string(json.Array(stored)), canary)
}

fn config(
  sess: session.Session,
  brk: broker.Broker,
  requests: process.Subject(http.HttpRequest),
  executions: process.Subject(JsonValue),
) -> wiring.Config {
  let resolved =
    model.ResolvedModel(
      provider: "responses",
      model_id:,
      thinking: model.ThinkingHigh,
      context_window: 200_000,
      max_output_tokens: 4096,
    )
  let transport =
    script.owned_transport(fn(request, events) {
      process.send(requests, request)
      let continuation = string.contains(request.body, "function_call_output")
      let frames = case continuation {
        False -> first_turn()
        True -> final_turn()
      }
      process.send(events, http.ResponseStatus(200, []))
      list.each(frames, fn(frame) {
        process.send(events, http.ResponseChunk(bit_array.from_string(frame)))
      })
      process.send(events, http.ResponseEnd)
    })
  let gw =
    gateway.new(
      transport,
      secret.from_list([#("FIXTURE_KEY", canary)]),
      clock.stepping(1000, 1),
    )
    |> gateway.add_provider(gateway.OpenAiResponsesProvider(
      name: "responses",
      base_url: "https://responses.invalid/v1",
      api_key_secret: "FIXTURE_KEY",
    ))
    |> gateway.route(model.Main, [resolved])
    |> gateway.with_attempt_timeout(2000)
  let registry =
    tool.registry([
      tool.Tool(
        name: "fixture_answer",
        description: "Return the fixed fixture answer.",
        prompt_snippet: None,
        schema: json.Object([
          #("type", json.String("object")),
          #("properties", json.Object([])),
        ]),
        replay: tool.Safe,
        execution_mode: tool.Concurrent,
        requirements: policy.workspace_default,
        run: fn(_ctx, arguments) {
          process.send(executions, arguments)
          tool.success("fixture result")
        },
      ),
    ])

  wiring.Config(
    gateway: gw,
    role: model.Main,
    facts: fn(_identity) { Ok(#(resolved, "openai-responses")) },
    system: Some("Use the supplied tool once."),
    api: "openai-responses",
    fallback_context_window: 200_000,
    fallback_max_output_tokens: 4096,
    provider_timeout_ms: 3000,
    session: sess,
    compaction: operation.CompactionSettings(False, 0, 0),
    broker: brk,
    broker_timeout_ms: 1000,
    registry:,
    workspace: "/nonexistent/responses-fixture",
    blob_root: "/nonexistent/responses-fixture/blobs",
    base_policy: policy.workspace_default("/nonexistent/responses-fixture"),
    escalations: escalate.none(),
    demand: exec.BestEffort,
    env: [],
    clock: clock.stepping(2000, 1),
    entropy: fn() { int.random(1_000_000_000) },
  )
}

fn assert_request(request: http.HttpRequest) -> Nil {
  assert request.method == "POST"
  assert request.url == "https://responses.invalid/v1/responses"
  assert list.filter(request.headers, fn(header) {
      string.lowercase(header.0) == "authorization"
    })
    == [#("authorization", "Bearer " <> canary)]
  assert !string.contains(request.body, canary)
  let assert Ok(body) = json.parse(request.body) as "request JSON must decode"
  assert field(body, "model") == json.String(model_id)
  assert field(body, "store") == json.Bool(False)
  assert field(body, "stream") == json.Bool(True)
  assert field(body, "include")
    == json.Array([json.String("reasoning.encrypted_content")])
}

fn assert_replay(body: String) -> Nil {
  let assert Ok(value) = json.parse(body) as "continuation JSON must decode"
  let assert json.Array(input) = field(value, "input")
    as "input must be an array"
  assert list.length(input) == 5
    as "the continuation must contain exactly user, reasoning, text, call and result"
  let assert [user, item, assistant, call, output] = input
    as "replay order must preserve user, reasoning, commentary, call and result"
  assert field(user, "role") == json.String("user")
  assert field(user, "content")
    == json.Array([
      text_part("input_text", "Answer using the fixture tool."),
    ])
  assert field(item, "type") == json.String("reasoning")
  assert field(item, "id") == json.String("rs_fixture")
  assert field(item, "encrypted_content") == json.String(encrypted)
  assert field(item, "summary")
    == json.Array([text_part("summary_text", "Use the tool.")])
  assert field(assistant, "type") == json.String("message")
  assert field(assistant, "role") == json.String("assistant")
  assert field(assistant, "phase") == json.String("commentary")
  assert field(assistant, "content")
    == json.Array([
      json.Object([
        #("type", json.String("output_text")),
        #("annotations", json.Array([])),
        #("text", json.String("Checking.")),
      ]),
    ])
  assert field(call, "type") == json.String("function_call")
  assert field(call, "call_id") == json.String("call_fixture")
  assert field(call, "name") == json.String(tool_name)
  assert field(call, "arguments") == json.String("{}")
  assert field(output, "type") == json.String("function_call_output")
  assert field(output, "call_id") == json.String("call_fixture")
  assert field(output, "output")
    == json.Array([text_part("input_text", "fixture result")])
}

fn assert_conversation(entries: List(entry.Entry)) -> Nil {
  let assert [
    entry.MessageEntry(id: user_id, message: message.UserMessage(..), ..),
    entry.MessageEntry(
      id: first_id,
      parent: Some(first_parent),
      message: first,
      ..,
    ),
    entry.MessageEntry(
      id: tool_id,
      parent: Some(tool_parent),
      message: result,
      ..,
    ),
    entry.MessageEntry(parent: Some(final_parent), message: last, ..),
  ] = entries
    as "exactly four linked messages must be durable"
  assert #(first_parent, tool_parent, final_parent)
    == #(user_id, first_id, tool_id)
  let assert message.AssistantMessage(
    content: [
      message.AssistantThinking(
        thinking: "Use the tool.",
        thinking_signature: Some(signature),
        ..,
      ),
      message.AssistantText(text: "Checking.", ..),
      message.AssistantToolCall(message.ToolCall(
        id: "call_fixture",
        name: "fixture_answer",
        arguments: json.Object([]),
        ..,
      )),
    ],
    api: "openai-responses",
    provider: "responses",
    model: "responses-fixture-model",
    response_id: Some("resp_first"),
    usage: first_usage,
    stop_reason: message.ToolUse,
    ..,
  ) = first
    as "the complete first settlement must retain reasoning, text and call"
  assert signature == encrypted
  assert first_usage == usage(80, 20, 20, 7)
  let assert message.ToolResultMessage(
    tool_call_id: "call_fixture",
    tool_name: "fixture_answer",
    content: [message.ToolResultText("fixture result", None)],
    is_error: False,
    ..,
  ) = result
    as "the real tool must commit its exact successful result"
  let assert message.AssistantMessage(
    content: [message.AssistantText("Finished.", ..)],
    api: "openai-responses",
    provider: "responses",
    model: "responses-fixture-model",
    response_id: Some("resp_final"),
    usage: final_usage,
    stop_reason: message.Stop,
    ..,
  ) = last
    as "the continuation must commit the final answer"
  assert final_usage == usage(110, 12, 40, 3)
}

fn usage(
  input: Int,
  output: Int,
  cached: Int,
  reasoning: Int,
) -> message.Usage {
  message.Usage(
    input:,
    output:,
    cache_read: cached,
    cache_write: 0,
    cache_write_1h: None,
    reasoning: Some(reasoning),
    total_tokens: input + cached + output,
    cost: message.UsageCost(0.0, 0.0, 0.0, 0.0, 0.0),
  )
}

fn stored_registers(
  sess: session.Session,
) -> Result(List(JsonValue), storage.StorageError) {
  list.try_map(
    [
      register.StrandLeaf, register.StrandConfig, register.StrandState,
      register.StrandLastResult, register.OpMeta, register.OpState,
      register.OpToolArgs, register.OpPreparation, register.PendingEntry,
      register.FactName, register.FactLabel, register.FactCustom,
    ],
    fn(namespace) {
      storage.list_registers(sess.store, namespace, None)
      |> result.map(fn(cells) {
        list.map(cells, fn(cell) { codec.encode_register_value(cell.1.value) })
      })
    },
  )
  |> result.map(list.flatten)
}

// These builders emit the real event vocabulary, including every closing
// witness. Each event is a separate HTTP chunk, so no parser shortcut can rely
// on the final response being the only document delivered.
fn first_turn() -> List(String) {
  let reasoning =
    json.Object([
      #("id", json.String("rs_fixture")),
      #("type", json.String("reasoning")),
      #("summary", json.Array([text_part("summary_text", "Use the tool.")])),
      #("encrypted_content", json.String(encrypted)),
    ])
  let call = call_item("completed", "{}")
  [
    response_event(
      "response.created",
      "resp_first",
      "in_progress",
      [],
      0,
      0,
      0,
      0,
    ),
    item_event(
      "response.output_item.added",
      0,
      json.Object([
        #("id", json.String("rs_fixture")),
        #("type", json.String("reasoning")),
        #("summary", json.Array([])),
      ]),
    ),
    part_event(
      "response.reasoning_summary_part.added",
      "rs_fixture",
      0,
      "summary_index",
      text_part("summary_text", ""),
    ),
    text_event(
      "response.reasoning_summary_text.delta",
      "rs_fixture",
      0,
      "summary_index",
      "delta",
      "Use the tool.",
    ),
    text_event(
      "response.reasoning_summary_text.done",
      "rs_fixture",
      0,
      "summary_index",
      "text",
      "Use the tool.",
    ),
    part_event(
      "response.reasoning_summary_part.done",
      "rs_fixture",
      0,
      "summary_index",
      text_part("summary_text", "Use the tool."),
    ),
    item_event("response.output_item.done", 0, reasoning),
    ..list.append(text_events("msg_first", 1, "commentary", "Checking."), [
      item_event("response.output_item.added", 2, call_item("in_progress", "")),
      event("response.function_call_arguments.delta", [
        #("item_id", json.String("fc_fixture")),
        #("output_index", json.Int(2)),
        #("delta", json.String("{}")),
      ]),
      event("response.function_call_arguments.done", [
        #("item_id", json.String("fc_fixture")),
        #("output_index", json.Int(2)),
        #("arguments", json.String("{}")),
      ]),
      item_event("response.output_item.done", 2, call),
      response_event(
        "response.completed",
        "resp_first",
        "completed",
        [
          reasoning,
          message_item("msg_first", "completed", "commentary", [
            text_part("output_text", "Checking."),
          ]),
          call,
        ],
        100,
        20,
        20,
        7,
      ),
    ])
  ]
}

fn final_turn() -> List(String) {
  [
    response_event(
      "response.created",
      "resp_final",
      "in_progress",
      [],
      0,
      0,
      0,
      0,
    ),
    ..list.append(text_events("msg_final", 0, "final_answer", "Finished."), [
      response_event(
        "response.completed",
        "resp_final",
        "completed",
        [
          message_item("msg_final", "completed", "final_answer", [
            text_part("output_text", "Finished."),
          ]),
        ],
        150,
        12,
        40,
        3,
      ),
    ])
  ]
}

fn text_events(
  id: String,
  index: Int,
  phase: String,
  text: String,
) -> List(String) {
  [
    item_event(
      "response.output_item.added",
      index,
      message_item(id, "in_progress", phase, []),
    ),
    part_event(
      "response.content_part.added",
      id,
      index,
      "content_index",
      text_part("output_text", ""),
    ),
    text_event(
      "response.output_text.delta",
      id,
      index,
      "content_index",
      "delta",
      text,
    ),
    text_event(
      "response.output_text.done",
      id,
      index,
      "content_index",
      "text",
      text,
    ),
    part_event(
      "response.content_part.done",
      id,
      index,
      "content_index",
      text_part("output_text", text),
    ),
    item_event(
      "response.output_item.done",
      index,
      message_item(id, "completed", phase, [text_part("output_text", text)]),
    ),
  ]
}

fn text_part(kind: String, text: String) -> JsonValue {
  json.Object([#("type", json.String(kind)), #("text", json.String(text))])
}

fn message_item(
  id: String,
  status: String,
  phase: String,
  content: List(JsonValue),
) -> JsonValue {
  json.Object([
    #("id", json.String(id)),
    #("type", json.String("message")),
    #("role", json.String("assistant")),
    #("status", json.String(status)),
    #("phase", json.String(phase)),
    #("content", json.Array(content)),
  ])
}

fn call_item(status: String, arguments: String) -> JsonValue {
  json.Object([
    #("id", json.String("fc_fixture")),
    #("type", json.String("function_call")),
    #("status", json.String(status)),
    #("call_id", json.String("call_fixture")),
    #("name", json.String(tool_name)),
    #("arguments", json.String(arguments)),
  ])
}

fn response_event(
  kind: String,
  id: String,
  status: String,
  output: List(JsonValue),
  input: Int,
  tokens: Int,
  cached: Int,
  reasoning: Int,
) -> String {
  event(kind, [
    #(
      "response",
      json.Object([
        #("id", json.String(id)),
        #("model", json.String(model_id)),
        #("status", json.String(status)),
        #("error", json.Null),
        #("output", json.Array(output)),
        #(
          "usage",
          json.Object([
            #("input_tokens", json.Int(input)),
            #("output_tokens", json.Int(tokens)),
            #("total_tokens", json.Int(input + tokens)),
            #(
              "input_tokens_details",
              json.Object([#("cached_tokens", json.Int(cached))]),
            ),
            #(
              "output_tokens_details",
              json.Object([#("reasoning_tokens", json.Int(reasoning))]),
            ),
          ]),
        ),
      ]),
    ),
  ])
}

fn item_event(kind: String, index: Int, item: JsonValue) -> String {
  event(kind, [#("output_index", json.Int(index)), #("item", item)])
}

fn part_event(
  kind: String,
  id: String,
  index: Int,
  index_key: String,
  part: JsonValue,
) -> String {
  event(kind, [
    #("item_id", json.String(id)),
    #("output_index", json.Int(index)),
    #(index_key, json.Int(0)),
    #("part", part),
  ])
}

fn text_event(
  kind: String,
  id: String,
  index: Int,
  index_key: String,
  text_key: String,
  text: String,
) -> String {
  event(kind, [
    #("item_id", json.String(id)),
    #("output_index", json.Int(index)),
    #(index_key, json.Int(0)),
    #(text_key, json.String(text)),
  ])
}

fn event(kind: String, fields: List(#(String, JsonValue))) -> String {
  "event: "
  <> kind
  <> "\ndata: "
  <> json.to_string(json.Object([#("type", json.String(kind)), ..fields]))
  <> "\n\n"
}

fn field(value: JsonValue, key: String) -> JsonValue {
  let assert json.Object(fields) = value as "wire item must be an object"
  case list.key_find(fields, key) {
    Ok(value) -> value
    Error(Nil) -> json.Null
  }
}
