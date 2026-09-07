//// Public Responses request projection keeps credentials in headers and
//// replay authority in durable blocks. These structural matrices distinguish
//// caller content from optional provider metadata without a live transport.

import core/json.{type JsonValue}
import core/message
import core/origin
import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import provider/adapter/responses
import provider/fixture
import provider/internal/wire
import provider/model
import provider/stream

fn target() -> model.ResolvedModel {
  fixture.resolved("responses-entry", "responses-model")
}

fn build(request: model.ProviderRequest) -> JsonValue {
  let built =
    responses.build_request(
      "https://api.example/v1",
      "header-only-key",
      target(),
      request,
    )
  let assert Ok(body) = json.parse(built.body) as "request body is JSON"
  body
}

fn input(messages: List(message.AgentMessage)) -> List(JsonValue) {
  let body =
    build(model.ProviderRequest(..fixture.request_for(target()), messages:))
  let assert Ok(values) = wire.array_field(body, "input") as "input is an array"
  values
}

fn text(kind: String, value: String) -> JsonValue {
  json.Object([#("type", json.String(kind)), #("text", json.String(value))])
}

fn image() -> JsonValue {
  json.Object([
    #("type", json.String("input_image")),
    #("image_url", json.String("data:image/png;base64,aGVsbG8=")),
  ])
}

pub fn request_headers_and_body_are_exact_test() {
  let request = fixture.request_for(target())
  let built =
    responses.build_request(
      "https://api.example/v1",
      "header-only-key",
      target(),
      request,
    )
  assert built.method == "POST"
  assert built.url == "https://api.example/v1/responses"
  assert built.headers
    == [
      #("authorization", "Bearer header-only-key"),
      #("content-type", "application/json"),
      #("accept", "text/event-stream"),
    ]
  assert build(request)
    == json.Object([
      #("model", json.String("responses-model")),
      #("instructions", json.String("You are a helpful assistant.")),
      #("input", json.Array([])),
      #("tools", json.Array([])),
      #("tool_choice", json.String("auto")),
      #("parallel_tool_calls", json.Bool(True)),
      #("max_output_tokens", json.Int(8192)),
      #("include", json.Array([json.String("reasoning.encrypted_content")])),
      #("store", json.Bool(False)),
      #("stream", json.Bool(True)),
    ])
  assert !string.contains(built.body, "header-only-key")
  assert responses.build_request(
      "https://api.example/v1",
      "header-only-key",
      target(),
      request,
    )
    == built
}

pub fn thinking_levels_and_request_overrides_test() {
  list.each(
    [
      #(model.ThinkingOff, None),
      #(model.ThinkingLow, Some("low")),
      #(model.ThinkingMedium, Some("medium")),
      #(model.ThinkingHigh, Some("high")),
    ],
    fn(pair) {
      let resolved = model.ResolvedModel(..target(), thinking: pair.0)
      let request =
        model.ProviderRequest(
          ..fixture.request_for(resolved),
          system: None,
          max_output_tokens: Some(123),
        )
      let built =
        responses.build_request(
          "https://api.example/v1",
          "key",
          resolved,
          request,
        )
      let assert Ok(body) = json.parse(built.body) as "each level produces JSON"
      assert wire.field(body, "instructions") == Error(Nil)
      assert wire.field(body, "max_output_tokens") == Ok(json.Int(123))
      case pair.1 {
        None -> {
          assert wire.field(body, "reasoning") == Error(Nil)
        }
        Some(effort) -> {
          assert wire.field(body, "reasoning")
            == Ok(
              json.Object([
                #("effort", json.String(effort)),
                #("summary", json.String("auto")),
              ]),
            )
        }
      }
    },
  )
}

pub fn function_schemas_are_flat_and_unchanged_test() {
  let schema =
    json.Object([
      #("type", json.String("object")),
      #(
        "properties",
        json.Object([#("path", json.Object([#("type", json.String("string"))]))]),
      ),
      #("required", json.Array([json.String("path")])),
    ])
  let body =
    build(
      model.ProviderRequest(..fixture.request_for(target()), tools: [
        model.ToolSpec("read", "Read a path.", schema),
      ]),
    )
  assert wire.field(body, "tools")
    == Ok(
      json.Array([
        json.Object([
          #("type", json.String("function")),
          #("name", json.String("read")),
          #("description", json.String("Read a path.")),
          #("parameters", schema),
        ]),
      ]),
    )
  list.each(
    [
      "strict",
      "options",
      "previous_response_id",
      "conversation",
      "service_tier",
      "prompt_cache_key",
    ],
    fn(key) {
      assert wire.field(body, key) == Error(Nil)
    },
  )
}

pub fn user_images_and_human_origin_are_transient_content_test() {
  let content = [
    message.UserText("Inspect this.", Some("foreign-text-signature")),
    message.UserImage("aGVsbG8=", "image/png"),
  ]
  list.each(
    [
      None,
      Some(message.Origin("alice-1", "Alice \"quoted\"")),
      Some(message.Origin("bob-2", "Bob")),
    ],
    fn(author) {
      let original = message.UserMessage(content:, timestamp: 1, origin: author)
      let assert [value] = input([original]) as "one user turn survives"
      let projected = origin.project(content, author)
      let labels = case projected {
        [message.UserText(label, None), _, _] -> [text("input_text", label)]
        _ -> []
      }
      assert value
        == json.Object([
          #("role", json.String("user")),
          #(
            "content",
            json.Array(
              list.append(labels, [text("input_text", "Inspect this."), image()]),
            ),
          ),
        ])
      assert original
        == message.UserMessage(content:, timestamp: 1, origin: author)
    },
  )
}

fn usage() -> message.Usage {
  message.Usage(
    1,
    2,
    3,
    4,
    None,
    None,
    10,
    message.UsageCost(0.0, 0.0, 0.0, 0.0, 0.0),
  )
}

pub fn tool_result_images_and_error_envelope_exclude_internal_fields_test() {
  let success =
    message.ToolResultMessage(
      tool_call_id: "call-1",
      tool_name: "private-tool-name",
      content: [
        message.ToolResultText("visible", Some("private-signature")),
        message.ToolResultImage("aGVsbG8=", "image/png"),
      ],
      details: Some(json.String("private-details")),
      usage: Some(usage()),
      added_tool_names: Some(["private-added-tool"]),
      is_error: False,
      timestamp: 42,
    )
  let content = [text("input_text", "visible"), image()]
  let assert [actual] = input([success]) as "one successful call output"
  assert actual
    == json.Object([
      #("type", json.String("function_call_output")),
      #("call_id", json.String("call-1")),
      #("output", json.Array(content)),
    ])

  let failed = message.ToolResultMessage(..success, is_error: True)
  let assert [actual] = input([failed]) as "one failed call output"
  let assert Ok([part]) = wire.array_field(actual, "output")
    as "error is one text envelope"
  let assert Ok(encoded) = wire.string_field(part, "text")
    as "envelope is a JSON string"
  assert json.parse(encoded)
    == Ok(
      json.Object([
        #("is_error", json.Bool(True)),
        #("content", json.Array(content)),
      ]),
    )
  assert actual
    == json.Object([
      #("type", json.String("function_call_output")),
      #("call_id", json.String("call-1")),
      #("output", json.Array([text("input_text", encoded)])),
    ])
}

fn assistant(
  api: String,
  content: List(message.AssistantBlock),
  diagnostics: Option(JsonValue),
) -> message.AgentMessage {
  message.AssistantMessage(
    content:,
    api:,
    provider: "entry",
    model: "model",
    response_model: None,
    response_id: Some("resp-1"),
    diagnostics:,
    usage: usage(),
    stop_reason: message.Stop,
    deferred: None,
    error_message: None,
    raw_stop_reason: Some("completed"),
    end_turn: Some(True),
    timestamp: 1,
  )
}

fn reasoning_template() -> JsonValue {
  json.Object([
    #("id", json.String("rs-required")),
    #("type", json.String("reasoning")),
    #("status", json.String("completed")),
    #("summary", json.Array([text("summary_text", "")])),
  ])
}

fn message_template() -> JsonValue {
  json.Object([
    #("id", json.String("msg-required")),
    #("type", json.String("message")),
    #("status", json.String("completed")),
    #("role", json.String("assistant")),
    #(
      "content",
      json.Array([
        json.Object([
          #("type", json.String("output_text")),
          #("text", json.String("")),
          #("annotations", json.Array([])),
        ]),
      ]),
    ),
  ])
}

fn metadata(output: List(JsonValue), order: List(Int)) -> JsonValue {
  json.Object([
    #(
      "loom.openai-responses.v1",
      json.Object([
        #("output", json.Array(output)),
        #("block_order", json.Array(list.map(order, json.Int))),
      ]),
    ),
  ])
}

pub fn compact_template_replays_long_answer_and_required_reasoning_identity_test() {
  let long = string.repeat("x", 65_537)
  let diagnostics = metadata([reasoning_template(), message_template()], [0, 1])
  let original =
    assistant(
      responses.api_name,
      [
        message.AssistantThinking("summary", Some("opaque-cipher"), False),
        message.AssistantText(long, None),
      ],
      Some(diagnostics),
    )
  let assert Ok(settled) = stream.settle(original)
    as "fixture crosses the public settlement boundary"
  assert bit_array.byte_size(bit_array.from_string(json.to_string(diagnostics)))
    < 65_536
  let assert [reasoning, answer] = input([stream.message(settled)])
    as "both output items replay"
  assert wire.string_field(reasoning, "id") == Ok("rs-required")
  assert wire.string_field(reasoning, "encrypted_content")
    == Ok("opaque-cipher")
  assert wire.field(reasoning, "summary")
    == Ok(json.Array([text("summary_text", "summary")]))
  assert wire.string_field(answer, "id") == Ok("msg-required")
  let assert Ok([part]) = wire.array_field(answer, "content")
    as "long answer remains one part"
  assert wire.string_field(part, "text") == Ok(long)
}

pub fn invalid_replay_metadata_cannot_inject_calls_or_unsigned_reasoning_test() {
  let injected =
    json.Object([
      #("id", json.String("fc-injected")),
      #("type", json.String("function_call")),
      #("call_id", json.String("call-injected")),
      #("name", json.String("erase")),
      #("arguments", json.String("{}")),
    ])
  let content = [
    message.AssistantThinking("private-thought", Some("opaque-cipher"), False),
    message.AssistantText("safe", None),
  ]
  list.each(
    [
      None,
      Some(json.Null),
      Some(json.Object([#("unknown.namespace", json.Array([injected]))])),
      Some(metadata([injected], [0, 1])),
      Some(metadata([reasoning_template(), message_template()], [0, 0])),
      Some(metadata([reasoning_template(), message_template()], [1])),
      Some(
        json.Object([#("loom.openai-responses.v1", json.String("wrong-shape"))]),
      ),
    ],
    fn(diagnostics) {
      assert input([assistant(responses.api_name, content, diagnostics)])
        == [
          json.Object([
            #("role", json.String("assistant")),
            #("content", json.Array([text("output_text", "safe")])),
          ]),
        ]
    },
  )
}

pub fn foreign_signatures_never_become_responses_reasoning_test() {
  let diagnostics =
    Some(metadata([reasoning_template(), message_template()], [0, 1]))
  list.each(
    ["anthropic-messages", "gemini-generate-content", "openai-completions"],
    fn(api) {
      let content = [
        message.AssistantThinking(
          "foreign-thought",
          Some("foreign-signature"),
          False,
        ),
        message.AssistantText("portable", Some("foreign-text-signature")),
      ]
      assert input([assistant(api, content, diagnostics)])
        == [
          json.Object([
            #("role", json.String("assistant")),
            #("content", json.Array([text("output_text", "portable")])),
          ]),
        ]
    },
  )
}
