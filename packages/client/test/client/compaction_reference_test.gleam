//// Provider-wire regressions for compaction's exact tool-result references.
//// The fixture uses the production preparation transform, then serializes the
//// resulting request through every supported provider adapter.

import core/clock
import core/ids
import core/json
import core/message
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import machine/operation.{CompactionPreparation, CompactionSettings}
import machine/planner.{Prepared}
import provider/adapter/anthropic
import provider/adapter/gemini
import provider/adapter/openai
import provider/http.{HttpRequest}
import provider/model
import runtime/hooks

pub fn references_serialize_through_every_provider_adapter_test() {
  let #(original, referenced) = fixture_messages()
  let original_request = request(original)
  let referenced_request = request(referenced)
  let original_bodies = bodies(original_request)
  let referenced_bodies = bodies(referenced_request)
  assert list.all(referenced_bodies, string.contains(
    _,
    "[loom tool-result reference]",
  ))
  assert list.all(referenced_bodies, string.contains(_, "argument-canary"))
  assert list.all(list.zip(original_bodies, referenced_bodies), fn(pair) {
    string.byte_size(pair.1) < string.byte_size(pair.0)
  })
  assert estimated_tokens(referenced) < estimated_tokens(original)
}

fn fixture_messages() -> #(
  List(message.AgentMessage),
  List(message.AgentMessage),
) {
  let generator = ids.generator(clock.fixed(at: 42), seed: 7)
  let #(session_id, generator) = ids.mint_session(generator)
  let #(cut_id, generator) = ids.mint_entry(generator)
  let #(call_id, generator) = ids.mint_entry(generator)
  let #(result_id, generator) = ids.mint_entry(generator)
  let #(answer_id, generator) = ids.mint_entry(generator)
  let #(user_id, _generator) = ids.mint_entry(generator)
  let call = tool_call()
  let result = tool_result()
  let answer = assistant_text("I read the old result.")
  let user = user_text("Continue.")
  let messages = [user_text("cut"), call, result, answer, user]
  let projected =
    hooks.Projected(
      messages:,
      carried: 0,
      previous_summary: None,
      origins: [
        Some(cut_id),
        Some(call_id),
        Some(result_id),
        Some(answer_id),
        Some(user_id),
      ],
      reference_session: Some(session_id),
      copied_from: None,
    )
  let assert Prepared(CompactionPreparation(retained_tail:, ..)) =
    hooks.preparation(
      projected,
      CompactionSettings(True, 0, 4),
      fn(_message) { 1 },
      tokens_before: 5,
    )
  #(list.drop(messages, 1), retained_tail)
}

fn tool_call() -> message.AgentMessage {
  message.AssistantMessage(
    content: [
      message.AssistantToolCall(message.ToolCall(
        id: "call-1",
        name: "bash",
        arguments: json.Object([
          #(
            "script",
            json.String("argument-canary " <> string.repeat("a", 6000)),
          ),
        ]),
        thought_signature: Some("opaque-thought-signature"),
        namespace: Some("shell"),
      )),
    ],
    api: "fixture",
    provider: "fixture",
    model: "fixture",
    response_model: None,
    response_id: None,
    diagnostics: None,
    usage: empty_usage(),
    stop_reason: message.ToolUse,
    deferred: None,
    error_message: None,
    raw_stop_reason: None,
    end_turn: None,
    timestamp: 0,
  )
}

fn user_text(text: String) -> message.AgentMessage {
  message.UserMessage([message.UserText(text, None)], 0, None)
}

fn assistant_text(text: String) -> message.AgentMessage {
  message.AssistantMessage(
    content: [message.AssistantText(text, None)],
    api: "fixture",
    provider: "fixture",
    model: "fixture",
    response_model: None,
    response_id: None,
    diagnostics: None,
    usage: empty_usage(),
    stop_reason: message.Stop,
    deferred: None,
    error_message: None,
    raw_stop_reason: None,
    end_turn: None,
    timestamp: 0,
  )
}

fn empty_usage() -> message.Usage {
  message.Usage(
    input: 0,
    output: 0,
    cache_read: 0,
    cache_write: 0,
    cache_write_1h: None,
    reasoning: None,
    total_tokens: 0,
    cost: message.UsageCost(0.0, 0.0, 0.0, 0.0, 0.0),
  )
}

fn tool_result() -> message.AgentMessage {
  message.ToolResultMessage(
    tool_call_id: "call-1",
    tool_name: "bash",
    content: [message.ToolResultText(string.repeat("r", 24_000), None)],
    details: Some(
      json.Object([#("ignored-by-provider", json.String("detail"))]),
    ),
    usage: None,
    added_tool_names: None,
    is_error: False,
    timestamp: 1,
  )
}

fn request(messages: List(message.AgentMessage)) -> model.ProviderRequest {
  model.ProviderRequest(
    target: model.ForResolved(resolved()),
    system: Some("fixture"),
    messages:,
    tools: [],
    max_output_tokens: None,
  )
}

fn resolved() -> model.ResolvedModel {
  model.ResolvedModel("fixture", "fixture", model.ThinkingOff, 128_000, 4096)
}

fn bodies(request: model.ProviderRequest) -> List(String) {
  let HttpRequest(body: anthropic_body, ..) =
    anthropic.build_request("https://example.test", "key", resolved(), request)
  let HttpRequest(body: openai_body, ..) =
    openai.build_request("https://example.test", "key", resolved(), request)
  let HttpRequest(body: gemini_body, ..) =
    gemini.build_request("https://example.test", "key", resolved(), request)
  [anthropic_body, openai_body, gemini_body]
}

fn estimated_tokens(messages: List(message.AgentMessage)) -> Int {
  list.fold(messages, 0, fn(total, item) {
    total + hooks.estimate_message(item)
  })
}
