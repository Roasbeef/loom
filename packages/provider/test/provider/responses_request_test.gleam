//// Public Responses request projection keeps credentials in headers and
//// replay authority in durable blocks. These structural matrices distinguish
//// caller content from optional provider metadata without a live transport.

import core/usage_evidence

import core/json.{type JsonValue}
import core/message
import core/origin
import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import provider/adapter/responses
import provider/fixture
import provider/internal/responses_request
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

fn subscription_input(messages: List(message.AgentMessage)) -> List(JsonValue) {
  let request =
    model.ProviderRequest(..fixture.request_for(target()), messages:)
  let assert Ok(body) =
    json.parse(responses_request.subscription_body(target(), request))
    as "subscription request body is JSON"
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
    usage_evidence.reported(usage_evidence.Api),
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

pub fn subscription_settlement_replays_verified_responses_metadata_test() {
  let original =
    assistant(
      responses.subscription_api_name,
      [message.AssistantText("subscription answer", None)],
      Some(metadata([message_template()], [0])),
    )
  let assert [answer] = input([original])
    as "subscription identity must retain the same verified replay template"
  assert wire.string_field(answer, "id") == Ok("msg-required")
  let assert Ok([part]) = wire.array_field(answer, "content")
    as "the replayed answer contains its original content part"
  assert wire.string_field(part, "text") == Ok("subscription answer")
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

// The namespace is a transport shape. The function schema and local name remain
// identical to the public API request so broker lookup retains its meaning.
pub fn subscription_request_namespace_and_restrictions_are_exact_test() {
  let schema = json.Object([#("type", json.String("object"))])
  let request =
    model.ProviderRequest(
      ..fixture.request_for(target()),
      max_output_tokens: Some(123),
      tools: [model.ToolSpec("read", "Read a path.", schema)],
    )
  let assert Ok(body) =
    json.parse(responses_request.subscription_body(target(), request))
    as "subscription request is JSON"
  assert body
    == json.Object([
      #("model", json.String("responses-model")),
      #("instructions", json.String("You are a helpful assistant.")),
      #("input", json.Array([])),
      #(
        "tools",
        json.Array([
          json.Object([
            #("type", json.String("namespace")),
            #("name", json.String("loom")),
            #(
              "description",
              json.String("Tools executed by Loom under its local policy."),
            ),
            #(
              "tools",
              json.Array([
                json.Object([
                  #("type", json.String("function")),
                  #("name", json.String("read")),
                  #("description", json.String("Read a path.")),
                  #("parameters", schema),
                ]),
              ]),
            ),
          ]),
        ]),
      ),
      #("include", json.Array([json.String("reasoning.encrypted_content")])),
      #("store", json.Bool(False)),
      #("stream", json.Bool(True)),
    ])
}

fn call(namespace: Option(String)) -> message.AssistantBlock {
  message.AssistantToolCall(message.ToolCall(
    id: "call-local",
    name: "read",
    arguments: json.Object([]),
    thought_signature: None,
    namespace:,
  ))
}

fn call_template(namespace: Option(String)) -> JsonValue {
  let fields = [
    #("id", json.String("fc-local")),
    #("type", json.String("function_call")),
    #("call_id", json.String("call-local")),
    #("name", json.String("read")),
    #("arguments", json.String("")),
  ]
  json.Object(
    list.append(fields, case namespace {
      None -> []
      Some(name) -> [#("namespace", json.String(name))]
    }),
  )
}

pub fn subscription_history_namespaces_only_known_legacy_tools_test() {
  list.each([None, Some("loom"), Some("foreign")], fn(namespace) {
    let original =
      assistant(responses.subscription_api_name, [call(namespace)], None)
    let request =
      model.ProviderRequest(
        ..fixture.request_for(target()),
        messages: [original],
        tools: [model.ToolSpec("read", "Read a path.", json.Object([]))],
      )
    let assert Ok(body) =
      json.parse(responses_request.subscription_body(target(), request))
      as "historical calls project to JSON"
    let assert Ok([value]) = wire.array_field(body, "input")
      as "one historical call projects"
    assert wire.string_field(value, "namespace")
      == case namespace {
        None -> Ok("loom")
        Some(name) -> Ok(name)
      }
    assert wire.string_field(value, "name") == Ok("read")

    // The namespace is a subscription transport shape, so the public request
    // sends none of it, whatever route recorded the call.
    let assert [public] = input([original]) as "public call remains readable"
    assert wire.field(public, "namespace") == Error(Nil)
    assert wire.string_field(public, "name") == Ok("read")
  })
  let request =
    model.ProviderRequest(..fixture.request_for(target()), messages: [
      assistant(responses.subscription_api_name, [call(None)], None),
    ])
  let assert Ok(body) =
    json.parse(responses_request.subscription_body(target(), request))
    as "unoffered legacy call is still historical data"
  let assert Ok([value]) = wire.array_field(body, "input")
    as "historical call remains readable"
  assert wire.field(value, "namespace") == Error(Nil)
}

pub fn namespaced_replay_keeps_reasoning_and_rejects_changed_metadata_test() {
  let content = [
    message.AssistantThinking("summary", Some("cipher"), False),
    call(Some("loom")),
  ]
  let diagnostics =
    metadata([reasoning_template(), call_template(Some("loom"))], [0, 1])
  let assert [thought, tool] =
    subscription_input([
      assistant(responses.subscription_api_name, content, Some(diagnostics)),
    ])
    as "reasoning and its namespaced call replay together"
  assert wire.string_field(thought, "id") == Ok("rs-required")
  assert wire.string_field(thought, "encrypted_content") == Ok("cipher")
  assert wire.string_field(tool, "id") == Ok("fc-local")
  assert wire.string_field(tool, "namespace") == Ok("loom")

  // A namespace disagreement invalidates the whole hint. Durable call metadata
  // still projects, but the hint cannot substitute its foreign namespace.
  let changed = metadata([call_template(Some("foreign"))], [0])
  let assert [tool] =
    subscription_input([
      assistant(
        responses.subscription_api_name,
        [call(Some("loom"))],
        Some(changed),
      ),
    ])
    as "the durable call is the fallback authority"
  assert wire.field(tool, "id") == Error(Nil)
  assert wire.string_field(tool, "namespace") == Ok("loom")
}

// A session can move from the subscription route to an API-key route. Both the
// stored-hint replay and the durable-call fallback must drop the namespace the
// subscription route recorded, and keep every other field of the item.
pub fn public_replay_of_subscription_history_carries_no_namespace_test() {
  let content = [
    message.AssistantThinking("summary", Some("cipher"), False),
    call(Some("loom")),
  ]
  let diagnostics =
    metadata([reasoning_template(), call_template(Some("loom"))], [0, 1])

  // The hint replays the item verbatim, ID included.
  let assert [thought, tool] =
    input([
      assistant(responses.subscription_api_name, content, Some(diagnostics)),
    ])
    as "reasoning and its call replay through the public request"
  assert wire.string_field(thought, "id") == Ok("rs-required")
  assert wire.string_field(tool, "id") == Ok("fc-local")
  assert wire.string_field(tool, "name") == Ok("read")
  assert wire.field(tool, "namespace") == Error(Nil)

  // Without a hint the durable call is the authority and gets the same shape.
  let assert [tool] =
    input([
      assistant(responses.subscription_api_name, [call(Some("loom"))], None),
    ])
    as "the durable call projects through the public request"
  assert wire.string_field(tool, "call_id") == Ok("call-local")
  assert wire.field(tool, "namespace") == Error(Nil)
}

// A refreshed grant reads plain old assistant records and verified legacy item
// hints. Namespace migration applies after hint validation, preserving item IDs.
pub fn subscription_legacy_hint_and_plain_assistant_project_test() {
  let diagnostics = metadata([call_template(None)], [0])
  let legacy =
    assistant(responses.subscription_api_name, [call(None)], Some(diagnostics))
  let plain =
    assistant(
      responses.subscription_api_name,
      [message.AssistantText("historical answer", None)],
      None,
    )
  let request =
    model.ProviderRequest(
      ..fixture.request_for(target()),
      messages: [plain, legacy],
      tools: [model.ToolSpec("read", "Read a path.", json.Object([]))],
    )
  let assert Ok(body) =
    json.parse(responses_request.subscription_body(target(), request))
    as "old subscription history is readable for the new grant"
  let assert Ok([answer, tool]) = wire.array_field(body, "input")
    as "plain text and the validated legacy call both project"
  assert wire.string_field(answer, "role") == Ok("assistant")
  assert wire.field(answer, "content")
    == Ok(json.Array([text("output_text", "historical answer")]))
  assert wire.string_field(tool, "id") == Ok("fc-local")
  assert wire.string_field(tool, "namespace") == Ok("loom")
  assert wire.string_field(tool, "name") == Ok("read")
}
