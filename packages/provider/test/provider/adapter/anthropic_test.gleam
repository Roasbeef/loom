import core/json
import core/message
import core/msgpack
import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import provider/adapter/anthropic
import provider/fixture.{sse_event}
import provider/internal/wire
import provider/model
import provider/retry
import provider/stream

fn resolved() -> model.ResolvedModel {
  fixture.resolved(provider: "anthropic", model_id: "claude-sonnet-4-5")
}

fn machine() -> stream.ResponseMachine(anthropic.Accumulator) {
  anthropic.response_machine(resolved(), now: 1_700_000_000_000)
}

// --- fixture transcripts (from the real Messages API wire vocabulary) ---

fn message_start(input: Int, cache_read: Int, cache_write: Int) -> String {
  sse_event(
    "message_start",
    "{\"type\":\"message_start\",\"message\":{\"id\":\"msg_01XFDUDYJgAACzvnptvVoYEL\","
      <> "\"type\":\"message\",\"role\":\"assistant\",\"model\":\"claude-sonnet-4-5\","
      <> "\"content\":[],\"stop_reason\":null,\"usage\":{\"input_tokens\":"
      <> int_string(input)
      <> ",\"output_tokens\":1,\"cache_read_input_tokens\":"
      <> int_string(cache_read)
      <> ",\"cache_creation_input_tokens\":"
      <> int_string(cache_write)
      <> "}}}",
  )
}

fn int_string(value: Int) -> String {
  json.to_string(json.Int(value))
}

fn message_delta(stop_reason: String, output: Int) -> String {
  sse_event(
    "message_delta",
    "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\""
      <> stop_reason
      <> "\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":"
      <> int_string(output)
      <> "}}",
  )
}

fn message_stop() -> String {
  sse_event("message_stop", "{\"type\":\"message_stop\"}")
}

fn ping() -> String {
  sse_event("ping", "{\"type\":\"ping\"}")
}

fn happy_text_transcript() -> String {
  message_start(25, 0, 0)
  <> sse_event(
    "content_block_start",
    "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
  )
  <> ping()
  <> sse_event(
    "content_block_delta",
    "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}",
  )
  <> sse_event(
    "content_block_delta",
    "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\" world\"}}",
  )
  <> sse_event(
    "content_block_stop",
    "{\"type\":\"content_block_stop\",\"index\":0}",
  )
  <> message_delta("end_turn", 12)
  <> message_stop()
}

// --- happy path ----------------------------------------------------------

pub fn happy_text_settles_test() {
  let events = fixture.drive_ok(machine(), happy_text_transcript())
  let assert [
    stream.Delta(stream.TextDelta(index: 0, text: "Hello")),
    stream.Delta(stream.TextDelta(index: 0, text: " world")),
    stream.Settled(message: settled, usage:),
  ] = events
  let assert message.AssistantMessage(
    content:,
    api:,
    provider:,
    model: model_id,
    response_id:,
    stop_reason:,
    raw_stop_reason:,
    end_turn:,
    error_message:,
    ..,
  ) = stream.message(settled)
  assert content
    == [message.AssistantText(text: "Hello world", text_signature: None)]
  assert api == "anthropic-messages"
  assert provider == "anthropic"
  assert model_id == "claude-sonnet-4-5"
  assert response_id == Some("msg_01XFDUDYJgAACzvnptvVoYEL")
  assert stop_reason == message.Stop
  assert raw_stop_reason == Some("end_turn")
  assert end_turn == Some(True)
  assert error_message == None
  assert usage.input == 25
  assert usage.output == 12
  assert usage.total_tokens == 37
}

pub fn happy_text_survives_any_chunking_test() {
  let whole = fixture.drive_ok(machine(), happy_text_transcript())
  let bytes = bit_array.from_string(happy_text_transcript())
  list.each([1, 7, 64], fn(size) {
    let chunked =
      fixture.drive(
        machine(),
        status: 200,
        headers: [],
        chunks: fixture.chunked(bytes, size),
      )
    assert chunked == whole
  })
}

// --- tool calls -----------------------------------------------------------

fn tool_call_transcript() -> String {
  message_start(80, 0, 0)
  <> sse_event(
    "content_block_start",
    "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":"
      <> "{\"type\":\"tool_use\",\"id\":\"toolu_01T1x1fJ34qAmk2tNTrN7Up6\",\"name\":\"get_weather\",\"input\":{}}}",
  )
  <> sse_event(
    "content_block_delta",
    "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"city\\\":\"}}",
  )
  <> sse_event(
    "content_block_delta",
    "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"\\\"Paris\\\"}\"}}",
  )
  <> sse_event(
    "content_block_stop",
    "{\"type\":\"content_block_stop\",\"index\":0}",
  )
  <> message_delta("tool_use", 30)
  <> message_stop()
}

pub fn tool_call_with_streamed_arguments_test() {
  let events = fixture.drive_ok(machine(), tool_call_transcript())
  let assert [
    stream.Delta(stream.ToolCallDelta(
      index: 0,
      call_id: "toolu_01T1x1fJ34qAmk2tNTrN7Up6",
      name: "get_weather",
      arguments_json: "",
    )),
    stream.Delta(stream.ToolCallDelta(arguments_json: "{\"city\":", ..)),
    stream.Delta(stream.ToolCallDelta(arguments_json: "\"Paris\"}", ..)),
    stream.Settled(message: settled, usage: _),
  ] = events
  let assert message.AssistantMessage(content:, stop_reason:, ..) =
    stream.message(settled)
  assert stop_reason == message.ToolUse
  assert content
    == [
      message.AssistantToolCall(call: message.ToolCall(
        id: "toolu_01T1x1fJ34qAmk2tNTrN7Up6",
        name: "get_weather",
        arguments: json.Object([#("city", json.String("Paris"))]),
        thought_signature: None,
        namespace: None,
      )),
    ]
}

// --- thinking blocks ------------------------------------------------------

fn thinking_transcript() -> String {
  message_start(40, 0, 0)
  <> sse_event(
    "content_block_start",
    "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}",
  )
  <> sse_event(
    "content_block_delta",
    "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"Let me reason.\"}}",
  )
  <> sse_event(
    "content_block_delta",
    "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"EqQBCgIYAhIM\"}}",
  )
  <> sse_event(
    "content_block_stop",
    "{\"type\":\"content_block_stop\",\"index\":0}",
  )
  <> sse_event(
    "content_block_start",
    "{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
  )
  <> sse_event(
    "content_block_delta",
    "{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"Done.\"}}",
  )
  <> message_delta("end_turn", 20)
  <> message_stop()
}

pub fn thinking_block_with_signature_test() {
  let events = fixture.drive_ok(machine(), thinking_transcript())
  let assert [
    stream.Delta(stream.ThinkingDelta(index: 0, thinking: "Let me reason.")),
    stream.Delta(stream.TextDelta(index: 1, text: "Done.")),
    stream.Settled(message: settled, usage: _),
  ] = events
  let assert message.AssistantMessage(content:, ..) = stream.message(settled)
  assert content
    == [
      message.AssistantThinking(
        thinking: "Let me reason.",
        thinking_signature: Some("EqQBCgIYAhIM"),
        redacted: False,
      ),
      message.AssistantText(text: "Done.", text_signature: None),
    ]
}

pub fn redacted_thinking_block_test() {
  let transcript =
    message_start(10, 0, 0)
    <> sse_event(
      "content_block_start",
      "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"redacted_thinking\",\"data\":\"EmwKAhgB\"}}",
    )
    <> sse_event(
      "content_block_stop",
      "{\"type\":\"content_block_stop\",\"index\":0}",
    )
    <> message_delta("end_turn", 5)
    <> message_stop()
  let events = fixture.drive_ok(machine(), transcript)
  let assert [stream.Settled(message: settled, usage: _)] = events
  let assert message.AssistantMessage(content:, ..) = stream.message(settled)
  assert content
    == [
      message.AssistantThinking(
        thinking: "[reasoning redacted]",
        thinking_signature: Some("EmwKAhgB"),
        redacted: True,
      ),
    ]
}

// --- adapter-computed overflow -------------------------------------------

pub fn overflow_settles_as_error_with_canonical_message_test() {
  // input + cache_read = 250_000 > 200_000 window, output negligible.
  let transcript =
    message_start(190_000, 60_000, 0)
    <> message_delta("end_turn", 3)
    <> message_stop()
  let events = fixture.drive_ok(machine(), transcript)
  let assert [stream.Settled(message: settled, usage:)] = events
  let assert message.AssistantMessage(
    stop_reason:,
    error_message: Some(error_message),
    raw_stop_reason:,
    ..,
  ) = stream.message(settled)
  assert stop_reason == message.Errored
  assert raw_stop_reason == Some("end_turn")
  assert error_message == "prompt is too long: 250000 tokens > 200000 maximum"
  assert retry.is_overflow_message(error_message)
  assert usage.input == 190_000
  assert usage.cache_read == 60_000
}

pub fn substantive_answer_is_not_overflow_test() {
  // Same oversized input, but real output: not discarded as overflow.
  let transcript =
    message_start(190_000, 60_000, 0)
    <> message_delta("end_turn", 900)
    <> message_stop()
  let events = fixture.drive_ok(machine(), transcript)
  let assert [stream.Settled(message: settled, usage: _)] = events
  let assert message.AssistantMessage(stop_reason:, error_message:, ..) =
    stream.message(settled)
  assert stop_reason == message.Stop
  assert error_message == None
}

// --- errors ---------------------------------------------------------------

pub fn rate_limited_with_retry_after_test() {
  let events =
    fixture.drive(
      machine(),
      status: 429,
      headers: [#("retry-after", "7")],
      chunks: [
        bit_array.from_string(
          "{\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"Rate limited\"}}",
        ),
      ],
    )
  assert events
    == [
      stream.Failed(stream.HttpError(
        status: 429,
        api_error_type: "rate_limit_error",
        message: "Rate limited",
        retry_after_ms: Some(7000),
      )),
    ]
}

pub fn overloaded_stream_error_event_test() {
  let transcript =
    message_start(10, 0, 0)
    <> sse_event(
      "error",
      "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}",
    )
  let events = fixture.drive_ok(machine(), transcript)
  assert events
    == [
      stream.Failed(stream.StreamError(
        api_error_type: "overloaded_error",
        message: "Overloaded",
      )),
    ]
}

pub fn mid_stream_disconnect_fails_in_band_test() {
  let truncated =
    message_start(25, 0, 0)
    <> sse_event(
      "content_block_start",
      "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
    )
  let events = fixture.drive_ok(machine(), truncated)
  assert events
    == [
      stream.Failed(stream.StreamDisconnected(
        context: "response body ended before message_stop",
      )),
    ]
}

pub fn unknown_stop_reason_fails_in_band_test() {
  let transcript =
    message_start(25, 0, 0)
    <> message_delta("galaxy_brain", 12)
    <> message_stop()
  let events = fixture.drive_ok(machine(), transcript)
  assert events
    == [stream.Failed(stream.UnmappedStopReason(raw: "galaxy_brain"))]
}

pub fn malformed_sse_data_fails_in_band_test() {
  let transcript =
    message_start(25, 0, 0) <> sse_event("message_delta", "{not json")
  let events = fixture.drive_ok(machine(), transcript)
  let assert [stream.Failed(stream.MalformedStream(report: _))] = events
}

pub fn unknown_event_types_are_ignored_test() {
  let transcript =
    sse_event("brand_new_event", "{\"type\":\"brand_new_event\",\"x\":1}")
    <> happy_text_transcript()
  let assert [
    stream.Delta(_),
    stream.Delta(_),
    stream.Settled(message: _, usage: _),
  ] = fixture.drive_ok(machine(), transcript)
}

// --- stop-reason mapping table -------------------------------------------

pub fn stop_reason_mapping_table_test() {
  assert anthropic.map_stop_reason("end_turn") == Ok(#(message.Stop, None))
  assert anthropic.map_stop_reason("max_tokens") == Ok(#(message.Length, None))
  assert anthropic.map_stop_reason("tool_use") == Ok(#(message.ToolUse, None))
  assert anthropic.map_stop_reason("stop_sequence") == Ok(#(message.Stop, None))
  assert anthropic.map_stop_reason("pause_turn") == Ok(#(message.Stop, None))
  let assert Ok(#(message.Errored, Some(_))) =
    anthropic.map_stop_reason("refusal")
  let assert Ok(#(message.Errored, Some(_))) =
    anthropic.map_stop_reason("sensitive")
  assert anthropic.map_stop_reason("something_new") == Error(Nil)
}

// --- usage extraction -----------------------------------------------------

pub fn usage_extraction_with_cache_test() {
  let transcript =
    message_start(100, 2000, 300)
    <> message_delta("end_turn", 50)
    <> message_stop()
  let events = fixture.drive_ok(machine(), transcript)
  let assert [stream.Settled(message: _, usage:)] = events
  assert usage.input == 100
  assert usage.output == 50
  assert usage.cache_read == 2000
  assert usage.cache_write == 300
  assert usage.total_tokens == 2450
}

// A settled message's usage must always be storable: every counter (and
// every composed total) must encode as a msgpack integer.
fn assert_usage_encodable(usage: message.Usage) -> Nil {
  let counters = [
    usage.input,
    usage.output,
    usage.cache_read,
    usage.cache_write,
    option.unwrap(usage.cache_write_1h, 0),
    option.unwrap(usage.reasoning, 0),
    usage.total_tokens,
  ]
  list.each(counters, fn(counter) {
    let assert Ok(_bytes) = msgpack.encode(msgpack.IntValue(counter))
    Nil
  })
}

pub fn oversized_usage_counts_clamp_and_stay_encodable_test() {
  // A hostile proxy reports input_tokens above 2^64 - 1 — beyond what
  // the durable msgpack codec can encode. The boundary clamp saturates
  // it to wire.max_usage_count, so the settled message round-trips.
  let huge = 100_000_000_000_000_000_000
  let transcript =
    message_start(huge, 0, 0)
    <> message_delta("end_turn", 100)
    <> message_stop()
  let events = fixture.drive_ok(machine(), transcript)
  let assert [stream.Settled(message: settled, usage:)] = events
  assert usage.input == wire.max_usage_count
  assert usage.output == 100
  assert usage.total_tokens == wire.max_usage_count + 100
  assert_usage_encodable(usage)
  let assert message.AssistantMessage(usage: stored, ..) =
    stream.message(settled)
  assert_usage_encodable(stored)
}

pub fn negative_usage_counts_clamp_to_zero_test() {
  // Negative counts are equally unreal, and letting them through would
  // skew the overflow arithmetic downward.
  let transcript =
    message_start(-500, -2, -3)
    <> message_delta("end_turn", -7)
    <> message_stop()
  let events = fixture.drive_ok(machine(), transcript)
  let assert [stream.Settled(message: _, usage:)] = events
  assert usage.input == 0
  assert usage.output == 0
  assert usage.cache_read == 0
  assert usage.cache_write == 0
  assert usage.total_tokens == 0
  assert_usage_encodable(usage)
}

pub fn duplicate_message_start_does_not_zero_usage_test() {
  // A second message_start with an empty usage object must not erase
  // the counts the first one reported (a proxy could otherwise suppress
  // usage accounting).
  let empty_start =
    sse_event(
      "message_start",
      "{\"type\":\"message_start\",\"message\":{\"id\":\"msg_dup\","
        <> "\"type\":\"message\",\"role\":\"assistant\",\"usage\":{}}}",
    )
  let transcript =
    message_start(100, 2000, 300)
    <> empty_start
    <> message_delta("end_turn", 50)
    <> message_stop()
  let events = fixture.drive_ok(machine(), transcript)
  let assert [stream.Settled(message: _, usage:)] = events
  assert usage.input == 100
  assert usage.cache_read == 2000
  assert usage.cache_write == 300
  assert usage.output == 50
}

// --- request construction -------------------------------------------------

pub fn build_request_shape_test() {
  let request =
    model.ProviderRequest(
      target: model.ForResolved(resolved()),
      system: Some("Be terse."),
      messages: [
        message.UserMessage(
          content: [message.UserText(text: "hi", text_signature: None)],
          timestamp: 1,
        ),
      ],
      tools: [
        model.ToolSpec(
          name: "get_weather",
          description: "Weather lookup",
          input_schema: json.Object([#("type", json.String("object"))]),
        ),
      ],
      max_output_tokens: None,
    )
  let built =
    anthropic.build_request(
      base_url: "https://api.anthropic.com",
      api_key: "sk-test-key",
      resolved: resolved(),
      request:,
    )
  assert built.method == "POST"
  assert built.url == "https://api.anthropic.com/v1/messages"
  assert list.key_find(built.headers, "x-api-key") == Ok("sk-test-key")
  assert list.key_find(built.headers, "anthropic-version") == Ok("2023-06-01")
  assert string.contains(built.body, "\"model\":\"claude-sonnet-4-5\"")
  assert string.contains(built.body, "\"system\":\"Be terse.\"")
  assert string.contains(built.body, "\"stream\":true")
  assert string.contains(built.body, "\"get_weather\"")
  // The key goes into the header, never the body.
  assert !string.contains(built.body, "sk-test-key")
}

pub fn build_request_merges_tool_results_into_one_user_turn_test() {
  let tool_result = fn(id) {
    message.ToolResultMessage(
      tool_call_id: id,
      tool_name: "get_weather",
      content: [message.ToolResultText(text: "ok", text_signature: None)],
      details: None,
      usage: None,
      added_tool_names: None,
      is_error: False,
      timestamp: 2,
    )
  }
  let request =
    model.ProviderRequest(
      target: model.ForResolved(resolved()),
      system: None,
      messages: [tool_result("toolu_1"), tool_result("toolu_2")],
      tools: [],
      max_output_tokens: None,
    )
  let built =
    anthropic.build_request(
      base_url: "https://api.anthropic.com",
      api_key: "k",
      resolved: resolved(),
      request:,
    )
  // Both results share one user turn: only one "role":"user" in the body.
  assert list.length(string.split(built.body, "\"role\":\"user\"")) == 2
  assert string.contains(built.body, "toolu_1")
  assert string.contains(built.body, "toolu_2")
}
