//// Deterministic pseudo-random generation for the session property tests:
//// the seeded SplitMix64 pattern from core's test support, plus builders
//// for the settled messages the projection and fork properties drive
//// sessions with. Everything is a pure function of the threaded `Seed`,
//// so a failing property reproduces from its seed alone.

import core/json.{type JsonValue}
import core/message.{type AgentMessage, type ToolCall}
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string

/// Pseudo-random generator state.
pub type Seed {
  Seed(state: Int)
}

const mask_64 = 0xFFFFFFFFFFFFFFFF

/// Builds a seed from any integer.
pub fn seed(n: Int) -> Seed {
  Seed(state: int.bitwise_and(n, mask_64))
}

/// Draws the next 64-bit value.
pub fn next(seed: Seed) -> #(Int, Seed) {
  let state = int.bitwise_and(seed.state + 0x9E3779B97F4A7C15, mask_64)
  let z = state
  let z =
    int.bitwise_and(
      int.bitwise_exclusive_or(z, int.bitwise_shift_right(z, 30))
        * 0xBF58476D1CE4E5B9,
      mask_64,
    )
  let z =
    int.bitwise_and(
      int.bitwise_exclusive_or(z, int.bitwise_shift_right(z, 27))
        * 0x94D049BB133111EB,
      mask_64,
    )
  let z = int.bitwise_exclusive_or(z, int.bitwise_shift_right(z, 31))
  #(z, Seed(state:))
}

/// An inclusive integer range as a list. Requires `start <= stop`.
pub fn range(from start: Int, to stop: Int) -> List(Int) {
  int.range(from: start, to: stop + 1, with: [], run: fn(acc, n) { [n, ..acc] })
  |> list.reverse
}

/// Draws an integer in `[min, max]`, both inclusive.
pub fn int_between(seed: Seed, min: Int, max: Int) -> #(Int, Seed) {
  let #(raw, seed) = next(seed)
  #(min + raw % { max - min + 1 }, seed)
}

/// Draws a boolean.
pub fn bool(seed: Seed) -> #(Bool, Seed) {
  let #(n, seed) = int_between(seed, 0, 1)
  #(n == 1, seed)
}

/// Picks one element of a non-empty list; the first is the fallback.
pub fn one_of(seed: Seed, choices: List(a), fallback: a) -> #(a, Seed) {
  let #(index, seed) = int_between(seed, 0, list.length(choices) - 1)
  case list.drop(choices, index) {
    [chosen, ..] -> #(chosen, seed)
    [] -> #(fallback, seed)
  }
}

/// A zero-cost, zero-token usage value.
pub fn zero_usage() -> message.Usage {
  message.Usage(
    input: 0,
    output: 0,
    cache_read: 0,
    cache_write: 0,
    cache_write_1h: None,
    reasoning: None,
    total_tokens: 0,
    cost: message.UsageCost(
      input: 0.0,
      output: 0.0,
      cache_read: 0.0,
      cache_write: 0.0,
      total: 0.0,
    ),
  )
}

/// A small non-zero usage value carrying `tokens` input tokens.
pub fn some_usage(tokens: Int) -> message.Usage {
  message.Usage(..zero_usage(), input: tokens, total_tokens: tokens)
}

/// A user message with numbered text.
pub fn user_msg(n: Int) -> AgentMessage {
  user_text("user-" <> int.to_string(n))
}

/// A user message with the given text.
pub fn user_text(text: String) -> AgentMessage {
  message.UserMessage(
    content: [message.UserText(text:, text_signature: None)],
    timestamp: n_of_text(text),
  )
}

// A stable fake timestamp derived from the text so equal builders compare
// equal across runs.
fn n_of_text(text: String) -> Int {
  string.byte_size(text)
}

/// A settled assistant message: numbered text plus the given tool-call
/// blocks and stop reason.
pub fn assistant_msg(
  n: Int,
  stop: message.StopReason,
  calls: List(ToolCall),
) -> AgentMessage {
  message.AssistantMessage(
    content: [
      message.AssistantText(
        text: "assistant-" <> int.to_string(n),
        text_signature: None,
      ),
      ..list.map(calls, fn(call) { message.AssistantToolCall(call:) })
    ],
    api: "fake",
    provider: "acme",
    model: "loom-1",
    response_model: None,
    response_id: None,
    diagnostics: None,
    usage: zero_usage(),
    stop_reason: stop,
    deferred: None,
    error_message: None,
    raw_stop_reason: None,
    end_turn: None,
    timestamp: n,
  )
}

/// A numbered tool call with the given arguments.
pub fn tool_call(n: Int, arguments: JsonValue) -> ToolCall {
  message.ToolCall(
    id: "call-" <> int.to_string(n),
    name: "tool-" <> int.to_string(n),
    arguments:,
    thought_signature: None,
    namespace: None,
  )
}

/// The (successful) result of a tool call, with numbered text.
pub fn tool_result(call: ToolCall, n: Int) -> AgentMessage {
  message.ToolResultMessage(
    tool_call_id: call.id,
    tool_name: call.name,
    content: [
      message.ToolResultText(
        text: "result-" <> int.to_string(n),
        text_signature: None,
      ),
    ],
    details: None,
    usage: None,
    added_tool_names: None,
    is_error: False,
    timestamp: n,
  )
}
