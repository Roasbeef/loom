import core/json
import core/message
import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import provider/adapter/openai
import provider/fixture.{sse_data}
import provider/model
import provider/retry
import provider/stream

fn resolved() -> model.ResolvedModel {
  fixture.resolved(provider: "openrouter", model_id: "openai/gpt-5")
}

fn machine() -> stream.ResponseMachine(openai.Accumulator) {
  openai.response_machine(resolved(), now: 1_700_000_000_000)
}

// --- fixture transcripts (chat-completions wire vocabulary) --------------

fn chunk(payload: String) -> String {
  sse_data(
    "{\"id\":\"chatcmpl-9x\",\"object\":\"chat.completion.chunk\",\"model\":\"openai/gpt-5\","
    <> payload
    <> "}",
  )
}

fn content_chunk(text: String) -> String {
  chunk(
    "\"choices\":[{\"index\":0,\"delta\":{\"content\":\""
    <> text
    <> "\"},\"finish_reason\":null}]",
  )
}

fn finish_chunk(reason: String) -> String {
  chunk(
    "\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\""
    <> reason
    <> "\"}]",
  )
}

fn usage_chunk(prompt: Int, completion: Int, cached: Int) -> String {
  chunk(
    "\"choices\":[],\"usage\":{\"prompt_tokens\":"
    <> json.to_string(json.Int(prompt))
    <> ",\"completion_tokens\":"
    <> json.to_string(json.Int(completion))
    <> ",\"total_tokens\":"
    <> json.to_string(json.Int(prompt + completion))
    <> ",\"prompt_tokens_details\":{\"cached_tokens\":"
    <> json.to_string(json.Int(cached))
    <> "}}",
  )
}

fn done() -> String {
  "data: [DONE]\n\n"
}

fn happy_transcript() -> String {
  chunk(
    "\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\"},\"finish_reason\":null}]",
  )
  <> content_chunk("Hello")
  <> content_chunk(" there")
  <> finish_chunk("stop")
  <> usage_chunk(120, 8, 100)
  <> done()
}

// --- happy path -----------------------------------------------------------

pub fn happy_text_settles_test() {
  let events = fixture.drive_ok(machine(), happy_transcript())
  let assert [
    stream.Delta(stream.TextDelta(index: 0, text: "Hello")),
    stream.Delta(stream.TextDelta(index: 0, text: " there")),
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
    ..,
  ) = stream.message(settled)
  assert content
    == [message.AssistantText(text: "Hello there", text_signature: None)]
  assert api == "openai-completions"
  assert provider == "openrouter"
  assert model_id == "openai/gpt-5"
  assert response_id == Some("chatcmpl-9x")
  assert stop_reason == message.Stop
  assert raw_stop_reason == Some("stop")
  // prompt_tokens includes the cached read; the ledger splits them.
  assert usage.input == 20
  assert usage.cache_read == 100
  assert usage.output == 8
  assert usage.total_tokens == 128
}

pub fn happy_survives_any_chunking_test() {
  let whole = fixture.drive_ok(machine(), happy_transcript())
  let bytes = bit_array.from_string(happy_transcript())
  list.each([1, 5, 33], fn(size) {
    assert fixture.drive(
        machine(),
        status: 200,
        headers: [],
        chunks: fixture.chunked(bytes, size),
      )
      == whole
  })
}

// --- tool calls ------------------------------------------------------------

fn tool_call_transcript() -> String {
  chunk(
    "\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_a1\",\"type\":\"function\",\"function\":{\"name\":\"get_weather\",\"arguments\":\"\"}}]},\"finish_reason\":null}]",
  )
  <> chunk(
    "\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"city\\\":\"}}]},\"finish_reason\":null}]",
  )
  <> chunk(
    "\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"\\\"Paris\\\"}\"}}]},\"finish_reason\":null}]",
  )
  <> finish_chunk("tool_calls")
  <> usage_chunk(60, 15, 0)
  <> done()
}

pub fn tool_call_with_streamed_arguments_test() {
  let events = fixture.drive_ok(machine(), tool_call_transcript())
  let assert [
    stream.Delta(stream.ToolCallDelta(
      index: 0,
      call_id: "call_a1",
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
        id: "call_a1",
        name: "get_weather",
        arguments: json.Object([#("city", json.String("Paris"))]),
        thought_signature: None,
        namespace: None,
      )),
    ]
}

// --- reasoning deltas -------------------------------------------------------

pub fn reasoning_content_becomes_thinking_test() {
  let transcript =
    chunk(
      "\"choices\":[{\"index\":0,\"delta\":{\"reasoning_content\":\"hmm\"},\"finish_reason\":null}]",
    )
    <> content_chunk("Answer")
    <> finish_chunk("stop")
    <> done()
  let events = fixture.drive_ok(machine(), transcript)
  let assert [
    stream.Delta(stream.ThinkingDelta(index: 0, thinking: "hmm")),
    stream.Delta(stream.TextDelta(index: 1, text: "Answer")),
    stream.Settled(message: settled, usage: _),
  ] = events
  let assert message.AssistantMessage(content:, ..) = stream.message(settled)
  assert content
    == [
      message.AssistantThinking(
        thinking: "hmm",
        thinking_signature: None,
        redacted: False,
      ),
      message.AssistantText(text: "Answer", text_signature: None),
    ]
}

// --- settlement edge cases --------------------------------------------------

pub fn stream_without_done_still_settles_on_end_test() {
  let transcript = content_chunk("hi") <> finish_chunk("stop")
  let events = fixture.drive_ok(machine(), transcript)
  let assert [stream.Delta(_), stream.Settled(message: _, usage: _)] = events
}

pub fn disconnect_before_finish_reason_fails_in_band_test() {
  let events = fixture.drive_ok(machine(), content_chunk("hi"))
  let assert [
    stream.Delta(_),
    stream.Failed(stream.StreamDisconnected(context: _)),
  ] = events
}

pub fn unknown_finish_reason_fails_in_band_test() {
  let transcript = content_chunk("hi") <> finish_chunk("novel_reason") <> done()
  let events = fixture.drive_ok(machine(), transcript)
  let assert [
    stream.Delta(_),
    stream.Failed(stream.UnmappedStopReason(raw: "novel_reason")),
  ] = events
}

pub fn malformed_chunk_fails_in_band_test() {
  let events = fixture.drive_ok(machine(), sse_data("{broken") <> done())
  let assert [stream.Failed(stream.MalformedStream(report: _))] = events
}

// --- adapter-computed overflow ----------------------------------------------

pub fn silent_overflow_settles_as_error_test() {
  // z.ai style: the provider accepts the oversized request and reports
  // usage above the window with no real output.
  let transcript = finish_chunk("stop") <> usage_chunk(260_000, 0, 0) <> done()
  let events = fixture.drive_ok(machine(), transcript)
  let assert [stream.Settled(message: settled, usage: _)] = events
  let assert message.AssistantMessage(
    stop_reason:,
    error_message: Some(error_message),
    ..,
  ) = stream.message(settled)
  assert stop_reason == message.Errored
  assert retry.is_overflow_message(error_message)
}

// --- http errors --------------------------------------------------------------

pub fn server_error_with_json_body_test() {
  let events =
    fixture.drive(machine(), status: 500, headers: [], chunks: [
      bit_array.from_string(
        "{\"error\":{\"message\":\"The server had an error\",\"type\":\"server_error\",\"code\":null}}",
      ),
    ])
  assert events
    == [
      stream.Failed(stream.HttpError(
        status: 500,
        api_error_type: "server_error",
        message: "The server had an error",
        retry_after_ms: None,
      )),
    ]
}

// --- finish-reason mapping table -----------------------------------------------

pub fn finish_reason_mapping_table_test() {
  assert openai.map_finish_reason("stop") == Ok(#(message.Stop, None))
  assert openai.map_finish_reason("length") == Ok(#(message.Length, None))
  assert openai.map_finish_reason("tool_calls") == Ok(#(message.ToolUse, None))
  assert openai.map_finish_reason("function_call")
    == Ok(#(message.ToolUse, None))
  let assert Ok(#(message.Errored, Some(_))) =
    openai.map_finish_reason("content_filter")
  assert openai.map_finish_reason("flex_mode_interrupted") == Error(Nil)
}

// --- request construction -------------------------------------------------------

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
      max_output_tokens: Some(2000),
    )
  let built =
    openai.build_request(
      base_url: "https://api.openai.com/v1",
      api_key: "sk-test-key",
      resolved: resolved(),
      request:,
    )
  assert built.method == "POST"
  assert built.url == "https://api.openai.com/v1/chat/completions"
  assert list.key_find(built.headers, "authorization")
    == Ok("Bearer sk-test-key")
  assert string.contains(built.body, "\"include_usage\":true")
  assert string.contains(built.body, "\"max_completion_tokens\":2000")
  assert string.contains(built.body, "\"role\":\"system\"")
  assert string.contains(built.body, "\"get_weather\"")
  assert !string.contains(built.body, "sk-test-key")
}

pub fn build_request_tool_result_becomes_tool_role_test() {
  let request =
    model.ProviderRequest(
      target: model.ForResolved(resolved()),
      system: None,
      messages: [
        message.ToolResultMessage(
          tool_call_id: "call_a1",
          tool_name: "get_weather",
          content: [message.ToolResultText(text: "sunny", text_signature: None)],
          details: None,
          usage: None,
          added_tool_names: None,
          is_error: False,
          timestamp: 2,
        ),
      ],
      tools: [],
      max_output_tokens: None,
    )
  let built =
    openai.build_request(
      base_url: "https://api.openai.com/v1",
      api_key: "k",
      resolved: resolved(),
      request:,
    )
  assert string.contains(built.body, "\"role\":\"tool\"")
  assert string.contains(built.body, "\"tool_call_id\":\"call_a1\"")
  assert string.contains(built.body, "sunny")
}
