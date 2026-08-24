//// The scripted provider transport for the e2e suite: recorded-style
//// Anthropic Messages SSE transcripts replayed through the real
//// gateway, adapter, and stream machinery — no live network anywhere.
////
//// The script is keyed deterministically by the *projected
//// conversation*, not by call order: each request's turn index is the
//// number of tool results already in its request body (the
//// `"tool_use_id"` blocks the adapter encodes). Dropped (errored or
//// synthetic-interrupted-then-errored) responses never re-enter the
//// projection, so the key is stable across crashes and retries — the
//// same property the runtime's own scripted fakes rely on.

import core/json.{type JsonValue}
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/string
import provider/http.{type HttpEvent, type Transport}

/// One scripted settlement.
pub type Turn {
  /// Settle with a single tool call (`stop_reason: tool_use`).
  ToolUseTurn(
    call_id: String,
    tool: String,
    arguments: JsonValue,
    input_tokens: Int,
    output_tokens: Int,
  )
  /// Settle with a plain text answer (`stop_reason: end_turn`).
  AnswerTurn(text: String, input_tokens: Int, output_tokens: Int)
}

/// A transport replaying `turns[n]` for the request carrying `n` tool
/// results. A request beyond the script fails the attempt in-band, so
/// an over-long run fails loudly instead of looping.
pub fn transport(turns: List(Turn)) -> Transport {
  http.Transport(send_streaming: fn(request, subject) {
    let index = tool_results_in(request.body)
    case
      turns
      |> list.drop(index)
      |> list.first
    {
      Ok(turn) -> deliver(subject, transcript(turn))
      Error(Nil) ->
        process.send(
          subject,
          http.RequestFailed(
            reason: "the provider script is exhausted at turn "
            <> int.to_string(index),
          ),
        )
    }
  })
}

/// How many tool results the adapter encoded into a request body: the
/// script's turn key.
pub fn tool_results_in(body: String) -> Int {
  list.length(string.split(body, on: "\"tool_use_id\"")) - 1
}

/// The token total the usage ledger must converge to after every
/// scripted settlement lands exactly once.
pub fn total_usage(turns: List(Turn)) -> Int {
  list.fold(turns, 0, fn(total, turn) {
    case turn {
      ToolUseTurn(input_tokens:, output_tokens:, ..) ->
        total + input_tokens + output_tokens
      AnswerTurn(input_tokens:, output_tokens:, ..) ->
        total + input_tokens + output_tokens
    }
  })
}

// --- SSE rendering (the real Messages API wire vocabulary) ---------------

fn deliver(subject: Subject(HttpEvent), body: String) -> Nil {
  process.send(subject, http.ResponseStatus(status: 200, headers: []))
  process.send(subject, http.ResponseChunk(chunk: bit_array.from_string(body)))
  process.send(subject, http.ResponseEnd)
}

fn transcript(turn: Turn) -> String {
  case turn {
    AnswerTurn(text:, input_tokens:, output_tokens:) ->
      message_start(input_tokens)
      <> text_block(text)
      <> message_delta("end_turn", output_tokens)
      <> message_stop()
    ToolUseTurn(call_id:, tool:, arguments:, input_tokens:, output_tokens:) ->
      message_start(input_tokens)
      <> tool_use_block(call_id, tool, arguments)
      <> message_delta("tool_use", output_tokens)
      <> message_stop()
  }
}

fn sse_event(name: String, data: String) -> String {
  "event: " <> name <> "\ndata: " <> data <> "\n\n"
}

fn message_start(input: Int) -> String {
  sse_event(
    "message_start",
    "{\"type\":\"message_start\",\"message\":{\"id\":\"msg_scripted\","
      <> "\"type\":\"message\",\"role\":\"assistant\",\"model\":\"loom-1\","
      <> "\"content\":[],\"stop_reason\":null,\"usage\":{\"input_tokens\":"
      <> int.to_string(input)
      <> ",\"output_tokens\":1}}}",
  )
}

fn message_delta(stop_reason: String, output: Int) -> String {
  sse_event(
    "message_delta",
    "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\""
      <> stop_reason
      <> "\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":"
      <> int.to_string(output)
      <> "}}",
  )
}

fn message_stop() -> String {
  sse_event("message_stop", "{\"type\":\"message_stop\"}")
}

fn text_block(text: String) -> String {
  sse_event(
    "content_block_start",
    "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":"
      <> "{\"type\":\"text\",\"text\":\"\"}}",
  )
  <> sse_event(
    "content_block_delta",
    "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":"
      <> "{\"type\":\"text_delta\",\"text\":"
      <> quoted(text)
      <> "}}",
  )
  <> sse_event(
    "content_block_stop",
    "{\"type\":\"content_block_stop\",\"index\":0}",
  )
}

// The call's arguments stream as one `input_json_delta` fragment whose
// `partial_json` is the encoded arguments object — the accumulated form
// the adapter parses at settlement.
fn tool_use_block(
  call_id: String,
  tool: String,
  arguments: JsonValue,
) -> String {
  sse_event(
    "content_block_start",
    "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":"
      <> "{\"type\":\"tool_use\",\"id\":"
      <> quoted(call_id)
      <> ",\"name\":"
      <> quoted(tool)
      <> ",\"input\":{}}}",
  )
  <> sse_event(
    "content_block_delta",
    "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":"
      <> "{\"type\":\"input_json_delta\",\"partial_json\":"
      <> quoted(json.to_string(arguments))
      <> "}}",
  )
  <> sse_event(
    "content_block_stop",
    "{\"type\":\"content_block_stop\",\"index\":0}",
  )
}

// A JSON string literal (quotes included), escaping handled by the core
// encoder.
fn quoted(text: String) -> String {
  json.to_string(json.String(text))
}
