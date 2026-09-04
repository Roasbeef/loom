//// Gateway frames for scripted runs.
////
//// A snapshot test drives the client the way the server does, over the
//// wire, so the frames here are built from `core/codec`'s own encoders
//// rather than written as JSON text. A fixture that drifted from the codec
//// would decode to `Ignored` and quietly render an empty transcript, which
//// is the failure mode this module exists to make impossible.

import core/codec
import core/entry
import core/ids
import core/json
import core/message
import gleam/option.{None}

/// A `full` snapshot naming a session, with no strands and no history.
pub fn full_snapshot(session: String) -> String {
  event("snapshot", [
    #("mode", json.String("full")),
    #("session", json.String(session)),
    #("strands", json.Array([])),
    #("entries", json.Array([])),
    #("usage", codec.encode_usage(zero_usage())),
  ])
}

/// One durable user turn on a strand.
pub fn user_entry(strand: String, text: String, seq: Int) -> String {
  message_entry(
    strand,
    seq,
    message.UserMessage(
      content: [message.UserText(text:, text_signature: None)],
      timestamp: 0,
    ),
  )
}

/// One durable assistant turn carrying a tool call.
pub fn tool_call_entry(
  strand: String,
  tool: String,
  command: String,
  seq: Int,
) -> String {
  message_entry(
    strand,
    seq,
    message.AssistantMessage(
      content: [
        message.AssistantToolCall(call: message.ToolCall(
          id: "call-1",
          name: tool,
          arguments: json.Object([#("command", json.String(command))]),
          thought_signature: None,
          namespace: None,
        )),
      ],
      api: "messages",
      provider: "baseten",
      model: "baseten-kimi-k3",
      response_model: None,
      response_id: None,
      diagnostics: None,
      usage: zero_usage(),
      stop_reason: message.Stop,
      deferred: None,
      error_message: None,
      raw_stop_reason: None,
      end_turn: None,
      timestamp: 0,
    ),
  )
}

/// One durable tool result, as the failing shape a reader most wants to see.
pub fn tool_result_entry(strand: String, text: String, seq: Int) -> String {
  message_entry(
    strand,
    seq,
    message.ToolResultMessage(
      tool_call_id: "call-1",
      tool_name: "bash",
      content: [message.ToolResultText(text:, text_signature: None)],
      details: None,
      usage: None,
      added_tool_names: None,
      is_error: True,
      timestamp: 0,
    ),
  )
}

/// One transient stream fragment.
pub fn stream_delta(strand: String, kind: String, text: String) -> String {
  event("stream_delta", [
    #("strand", json.String(strand)),
    #("op", json.String("op-1")),
    #("ephemeral", json.Bool(True)),
    #("kind", json.String(kind)),
    #("text", json.String(text)),
  ])
}

/// One usage report, which is also what settles a generation's rate.
pub fn usage(strand: String, input: Int, output: Int, cost: Float) -> String {
  let reported =
    message.Usage(
      input:,
      output:,
      cache_read: 0,
      cache_write: 0,
      cache_write_1h: None,
      reasoning: None,
      total_tokens: input + output,
      cost: message.UsageCost(
        input: 0.0,
        output: 0.0,
        cache_read: 0.0,
        cache_write: 0.0,
        total: cost,
      ),
    )
  event("usage", [
    #("strand", json.String(strand)),
    #("usage", codec.encode_usage(reported)),
  ])
}

// A `message` entry is the only entry shape these snapshots need, so the
// three builders above differ only in the message they carry.
fn message_entry(
  strand: String,
  seq: Int,
  body: message.AgentMessage,
) -> String {
  let placed =
    entry.MessageEntry(
      id: fixed_entry_id(seq),
      parent: None,
      seq:,
      ts: 0,
      message: body,
      terminate: False,
    )
  event("entry", [
    #("strand", json.String(strand)),
    #("entry", codec.encode_entry(placed)),
  ])
}

// Entry ids are version-7 UUIDs, and a snapshot must not move between runs,
// so the sequence number picks one from a fixed family rather than minting a
// fresh identifier from a clock.
fn fixed_entry_id(seq: Int) -> ids.EntryId {
  let text = "00000000-0000-7000-8000-00000000000" <> string_digit(seq % 10)
  case ids.parse_entry_id(text) {
    Ok(id) -> id
    Error(_) -> fallback_entry_id()
  }
}

fn string_digit(value: Int) -> String {
  case value {
    0 -> "0"
    1 -> "1"
    2 -> "2"
    3 -> "3"
    4 -> "4"
    5 -> "5"
    6 -> "6"
    7 -> "7"
    8 -> "8"
    _ -> "9"
  }
}

// Unreachable: the text above is a well-formed UUID. Answered rather than
// asserted so a stricter parser fails a test instead of the whole suite.
fn fallback_entry_id() -> ids.EntryId {
  case ids.parse_entry_id("00000000-0000-7000-8000-000000000000") {
    Ok(id) -> id
    Error(_) -> panic as "the fixed fixture UUID stopped parsing"
  }
}

fn zero_usage() -> message.Usage {
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

fn event(name: String, body: List(#(String, json.JsonValue))) -> String {
  json.to_string(
    json.Object([
      #("v", json.Int(1)),
      #("event", json.String(name)),
      #("body", json.Object(body)),
    ]),
  )
}
