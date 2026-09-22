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
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string

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

/// An authoritative replacement for the visible strand set.
///
/// Each strand is an id, its display name and the phase its live operation
/// is in. All three are model-influenced: a sub-agent is named by whatever
/// spawned it, and the phase text comes back from the server as a string.
pub fn strands_snapshot(strands: List(#(String, String, String))) -> String {
  event("snapshot", [
    #("mode", json.String("strands")),
    #(
      "strands",
      json.Array(
        list.map(strands, fn(strand) {
          let #(id, name, phase) = strand
          json.Object([
            #("id", json.String(id)),
            #("name", json.String(name)),
            #("live_op", json.Object([#("phase", json.String(phase))])),
          ])
        }),
      ),
    ),
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
      origin: None,
    ),
  )
}

/// One durable compaction carrying model-facing checkpoint text and retained messages.
///
/// ## Examples
///
/// ```gleam
/// compaction_entry("main", "checkpoint", [], 204_143, 1)
/// ```
pub fn compaction_entry(
  strand: String,
  summary: String,
  retained_tail: List(message.AgentMessage),
  tokens_before: Int,
  seq: Int,
) -> String {
  let placed =
    entry.CompactionEntry(
      id: fixed_entry_id(seq),
      parent: None,
      seq:,
      ts: 0,
      summary:,
      retained_tail:,
      tokens_before:,
      from_hook: True,
      usage: None,
    )
  event("entry", [
    #("strand", json.String(strand)),
    #("entry", codec.encode_entry(placed)),
  ])
}

/// One durable assistant turn of prose, the reply a reader actually reads.
///
/// This is the markdown path rather than the plain one: an assistant body is
/// the only transcript text the CommonMark adapter parses, so a check on what
/// a provider can put on screen has to arrive here and not as a system line.
pub fn assistant_entry(strand: String, text: String, seq: Int) -> String {
  message_entry(
    strand,
    seq,
    assistant_message([message.AssistantText(text:, text_signature: None)]),
  )
}

/// One durable assistant turn carrying a tool call.
pub fn tool_call_entry(
  strand: String,
  tool: String,
  command: String,
  seq: Int,
) -> String {
  identified_tool_call_entry(strand, "call-1", tool, command, seq)
}

/// The same turn, with the provider's call ID chosen by the caller.
///
/// A group of compact tool rows is keyed by call ID, and a repeated ID ends
/// the group rather than extending it, so a fixture that wants two calls
/// grouped together has to name them apart.
pub fn identified_tool_call_entry(
  strand: String,
  call_id: String,
  tool: String,
  command: String,
  seq: Int,
) -> String {
  message_entry(
    strand,
    seq,
    assistant_message([
      message.AssistantToolCall(call: message.ToolCall(
        id: call_id,
        name: tool,
        arguments: json.Object([#("command", json.String(command))]),
        thought_signature: None,
        namespace: None,
      )),
    ]),
  )
}

/// One durable turn whose prose and tool call arrive together.
///
/// A response carrying prose is a narrative rather than a member of an
/// activity group, so this is the fixture for the boundary between a
/// paragraph and the call beneath it in the same response.
pub fn narrated_tool_call_entry(
  strand: String,
  call_id: String,
  text: String,
  command: String,
  seq: Int,
) -> String {
  message_entry(
    strand,
    seq,
    assistant_message([
      message.AssistantText(text:, text_signature: None),
      message.AssistantToolCall(call: message.ToolCall(
        id: call_id,
        name: "bash",
        arguments: json.Object([#("command", json.String(command))]),
        thought_signature: None,
        namespace: None,
      )),
    ]),
  )
}

/// One durable `agent_note` turn, whose value the transcript renders as
/// Markdown beneath the call summary.
///
/// The note body is what makes this fixture worth having: it is a detail row
/// that closes itself with a blank, unlike the bare summary row a plain
/// command leaves behind.
pub fn note_call_entry(
  strand: String,
  call_id: String,
  value: String,
  seq: Int,
) -> String {
  message_entry(
    strand,
    seq,
    assistant_message([
      message.AssistantToolCall(call: message.ToolCall(
        id: call_id,
        name: "agent_note",
        arguments: json.Object([#("value", json.String(value))]),
        thought_signature: None,
        namespace: None,
      )),
    ]),
  )
}

/// One durable successful result answering a named call.
pub fn identified_tool_result_ok_entry(
  strand: String,
  call_id: String,
  text: String,
  seq: Int,
) -> String {
  message_entry(
    strand,
    seq,
    message.ToolResultMessage(
      tool_call_id: call_id,
      tool_name: "bash",
      content: [message.ToolResultText(text:, text_signature: None)],
      details: None,
      usage: None,
      added_tool_names: None,
      is_error: False,
      timestamp: 0,
    ),
  )
}

/// One durable failed result answering a named call.
pub fn identified_tool_failure_entry(
  strand: String,
  call_id: String,
  text: String,
  seq: Int,
) -> String {
  message_entry(
    strand,
    seq,
    message.ToolResultMessage(
      tool_call_id: call_id,
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

// Every assistant turn these fixtures build differs only in its blocks, so
// the envelope — which provider answered, how it stopped, what it cost — is
// written once. None of those fields reach a frame; a snapshot that moved
// when one of them changed would be pinning the fixture, not the client.
fn assistant_message(
  content: List(message.AssistantBlock),
) -> message.AgentMessage {
  message.AssistantMessage(
    content:,
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
  )
}

/// One durable assistant turn of reasoning, the block a collapsed
/// transcript stands in for with a single row.
pub fn thinking_entry(strand: String, thinking: String, seq: Int) -> String {
  message_entry(
    strand,
    seq,
    assistant_message([
      message.AssistantThinking(
        thinking:,
        redacted: False,
        thinking_signature: None,
      ),
    ]),
  )
}

/// One durable assistant turn that reasons and then calls a tool, the shape
/// a model takes when it thinks between one command and the next.
///
/// Collapsed, the reasoning is a single row with no blank of its own, so
/// this is the fixture for the gap above that row and the gap below it.
pub fn thinking_tool_call_entry(
  strand: String,
  call_id: String,
  thinking: String,
  command: String,
  seq: Int,
) -> String {
  message_entry(
    strand,
    seq,
    assistant_message([
      message.AssistantThinking(
        thinking:,
        redacted: False,
        thinking_signature: None,
      ),
      message.AssistantToolCall(call: message.ToolCall(
        id: call_id,
        name: "bash",
        arguments: json.Object([#("command", json.String(command))]),
        thought_signature: None,
        namespace: None,
      )),
    ]),
  )
}

/// One durable assistant turn of reasoning the provider withheld. There is
/// no text behind the marker, so expanding it can only show the marker
/// again.
pub fn redacted_thinking_entry(strand: String, seq: Int) -> String {
  message_entry(
    strand,
    seq,
    assistant_message([
      message.AssistantThinking(
        thinking: "",
        redacted: True,
        thinking_signature: None,
      ),
    ]),
  )
}

/// One durable tool result which succeeded, the shape that settles a
/// running call without adding a failure row beside it.
pub fn tool_result_ok_entry(strand: String, text: String, seq: Int) -> String {
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
      is_error: False,
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

/// A structured refusal, which is what a command gets instead of an outcome.
pub fn server_error(code: String, message: String) -> String {
  event("error", [
    #("code", json.String(code)),
    #("message", json.String(message)),
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

/// One `usage` event carrying a complete ledger row.
///
/// `usage/4` builds the row from four numbers, which is all a totals check
/// needs. A check on the prompt-cache detector needs the cache buckets and
/// their prices as well, so it supplies the row itself.
pub fn usage_row(strand: String, reported: message.Usage) -> String {
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
  let text =
    "00000000-0000-7000-8000-" <> string.pad_start(int.to_string(seq), 12, "0")
  case ids.parse_entry_id(text) {
    Ok(id) -> id
    Error(_) -> fallback_entry_id()
  }
}

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
