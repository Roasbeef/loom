//// Ordinary parallel tool-result batches for merge regressions and the full
//// Anthropic request benchmark. Alternating roles keep the non-merge path in
//// the same fixture; all messages and credentials are synthetic.

import core/json
import core/message
import core/usage_evidence
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import provider/fixture
import provider/model

/// A fixed model identity for the disposable encoding fixture.
pub fn resolved() -> model.ResolvedModel {
  fixture.resolved("anthropic", "claude-sonnet-4-5")
}

/// A request whose parallel results must remain in their source order.
pub fn batch(count: Int) -> model.ProviderRequest {
  request(
    list.index_map(list.repeat(Nil, count), fn(_, index) { result(index + 1) }),
  )
}

/// The control request has an assistant boundary between every result.
pub fn alternating(count: Int) -> model.ProviderRequest {
  request(
    list.flatten(
      list.index_map(list.repeat(Nil, count), fn(_, index) {
        [answer(), result(index + 1)]
      }),
    ),
  )
}

fn request(messages: List(message.AgentMessage)) -> model.ProviderRequest {
  model.ProviderRequest(
    target: model.ForResolved(resolved()),
    system: Some("Pinned system"),
    messages:,
    tools: [
      model.ToolSpec(
        "fs_read",
        "Read a file",
        json.Object([#("type", json.String("object"))]),
      ),
    ],
    max_output_tokens: None,
  )
}

fn result(index: Int) -> message.AgentMessage {
  message.ToolResultMessage(
    tool_call_id: "call-" <> int.to_string(index),
    tool_name: "fs_read",
    content: [
      message.ToolResultText("first", None),
      message.ToolResultText("second", None),
    ],
    details: None,
    usage: None,
    added_tool_names: None,
    is_error: False,
    timestamp: 2,
  )
}

fn answer() -> message.AgentMessage {
  message.AssistantMessage(
    content: [message.AssistantText("reading", None)],
    api: "anthropic-messages",
    provider: "anthropic",
    model: "claude-sonnet-4-5",
    response_model: None,
    response_id: None,
    diagnostics: None,
    usage: message.Usage(
      evidence: usage_evidence.reported(usage_evidence.Api),
      input: 0,
      output: 0,
      cache_read: 0,
      cache_write: 0,
      cache_write_1h: None,
      reasoning: None,
      total_tokens: 0,
      cost: message.UsageCost(0.0, 0.0, 0.0, 0.0, 0.0),
    ),
    stop_reason: message.Stop,
    deferred: None,
    error_message: None,
    raw_stop_reason: None,
    end_turn: None,
    timestamp: 1,
  )
}
