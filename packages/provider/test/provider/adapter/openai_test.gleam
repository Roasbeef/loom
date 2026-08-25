import core/json
import core/message
import core/msgpack
import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import provider/adapter/openai
import provider/fixture.{sse_data}
import provider/internal/wire
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

// --- usage-counter clamping ------------------------------------------------

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
  // A hostile proxy reports prompt_tokens beyond 2^64 - 1; the boundary
  // clamp saturates it so the settled message stays msgpack-encodable.
  let transcript =
    content_chunk("Hi")
    <> finish_chunk("stop")
    <> usage_chunk(100_000_000_000_000_000_000, 100, 0)
    <> done()
  let events = fixture.drive_ok(machine(), transcript)
  let assert [_delta, stream.Settled(message: settled, usage:)] = events
  assert usage.input == wire.max_usage_count
  assert usage.output == 100
  assert_usage_encodable(usage)
  let assert message.AssistantMessage(usage: stored, ..) =
    stream.message(settled)
  assert_usage_encodable(stored)
}

pub fn negative_usage_counts_clamp_to_zero_test() {
  let transcript =
    content_chunk("Hi")
    <> finish_chunk("stop")
    <> usage_chunk(-260_000, -5, -9)
    <> done()
  let events = fixture.drive_ok(machine(), transcript)
  let assert [_delta, stream.Settled(message: _, usage:)] = events
  assert usage.input == 0
  assert usage.output == 0
  assert usage.cache_read == 0
  assert usage.total_tokens == 0
  assert_usage_encodable(usage)
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

// --- prompt caching ---------------------------------------------------------

pub fn the_request_carries_no_cache_breakpoints_test() {
  // Deliberate, not an omission: OpenAI-compatible prompt caching is
  // automatic on the server, matched by rendered prefix with no marker to
  // place and no request field to set. A `cache_control` block here would
  // be dialect noise at best and a 400 at worst.
  let request =
    model.ProviderRequest(
      target: model.ForResolved(resolved()),
      system: Some("You are Loom."),
      messages: [
        message.UserMessage(
          content: [message.UserText(text: "hi", text_signature: None)],
          timestamp: 1,
        ),
      ],
      tools: [
        model.ToolSpec(
          name: "bash",
          description: "runs a command",
          input_schema: json.Object([#("type", json.String("object"))]),
        ),
      ],
      max_output_tokens: None,
    )
  let built =
    openai.build_request(
      base_url: "https://api.openai.com/v1",
      api_key: "k",
      resolved: resolved(),
      request:,
    )
  assert !string.contains(built.body, "cache_control")
  assert !string.contains(built.body, "prompt_cache_key")
  // What the adapter does owe automatic caching is a stable prefix: the
  // system prompt ahead of all history, and the same bytes twice.
  let assert Ok(messages) = wire.array_field(parsed(built.body), "messages")
  let assert [first, ..] = messages
  assert wire.string_field_or(first, "role", or: "") == "system"
  let again =
    openai.build_request(
      base_url: "https://api.openai.com/v1",
      api_key: "k",
      resolved: resolved(),
      request:,
    )
  assert built.body == again.body
}

fn parsed(body: String) -> json.JsonValue {
  let assert Ok(document) = json.parse(body)
  document
}

fn cached_usage_chunk(
  prompt: Int,
  completion: Int,
  cached: Int,
  written: Int,
) -> String {
  chunk(
    "\"choices\":[],\"usage\":{\"prompt_tokens\":"
    <> json.to_string(json.Int(prompt))
    <> ",\"completion_tokens\":"
    <> json.to_string(json.Int(completion))
    <> ",\"total_tokens\":"
    <> json.to_string(json.Int(prompt + completion))
    <> ",\"prompt_tokens_details\":{\"cached_tokens\":"
    <> json.to_string(json.Int(cached))
    <> ",\"cache_write_tokens\":"
    <> json.to_string(json.Int(written))
    <> "}}",
  )
}

pub fn cache_read_and_write_split_out_of_prompt_tokens_test() {
  // `prompt_tokens` is the whole prompt. Both cached halves come back out
  // of it so the ledger's `input` means the same thing here as it does in
  // the Anthropic adapter, and the three still sum to the prompt.
  let transcript =
    finish_chunk("stop") <> cached_usage_chunk(9000, 40, 7000, 1500) <> done()
  let events = fixture.drive_ok(machine(), transcript)
  let assert [stream.Settled(message: settled, usage:)] = events
  assert usage.cache_read == 7000
  assert usage.cache_write == 1500
  assert usage.input == 500
  assert usage.input + usage.cache_read + usage.cache_write == 9000
  assert usage.output == 40
  assert usage.total_tokens == 9040
  // This dialect reports one cache lifetime, so there is no 1h subset.
  assert usage.cache_write_1h == None
  let assert message.AssistantMessage(usage: committed, ..) =
    stream.message(settled)
  assert committed == usage
  assert_usage_encodable(usage)
}

pub fn an_absent_cache_write_count_reads_as_zero_test() {
  // Most OpenAI-compatible endpoints report only `cached_tokens`. The
  // missing field must read as "nothing reported", not shift `input`.
  let transcript = finish_chunk("stop") <> usage_chunk(9000, 40, 7000) <> done()
  let events = fixture.drive_ok(machine(), transcript)
  let assert [stream.Settled(message: _, usage:)] = events
  assert usage.cache_read == 7000
  assert usage.cache_write == 0
  assert usage.input == 2000
}

pub fn an_impossible_cache_write_count_cannot_drive_input_negative_test() {
  // A proxy reporting more written than the prompt holds saturates
  // against what is left after the read rather than producing a negative
  // `input` the durable planes would have to encode.
  let transcript =
    finish_chunk("stop") <> cached_usage_chunk(1000, 5, 900, 5000) <> done()
  let events = fixture.drive_ok(machine(), transcript)
  let assert [stream.Settled(message: _, usage:)] = events
  assert usage.cache_read == 900
  assert usage.cache_write == 100
  assert usage.input == 0
}

pub fn cache_write_counts_toward_overflow_test() {
  // Overflow compares the whole prompt against the window, and the
  // written half is prompt. Splitting it out of `input` must not shrink
  // the request the classifier sees.
  let transcript =
    finish_chunk("stop")
    <> cached_usage_chunk(260_000, 0, 100_000, 60_000)
    <> done()
  let events = fixture.drive_ok(machine(), transcript)
  let assert [stream.Settled(message: settled, usage: _)] = events
  let assert message.AssistantMessage(
    stop_reason:,
    error_message: Some(error_message),
    ..,
  ) = stream.message(settled)
  assert stop_reason == message.Errored
  assert retry.is_overflow_message(error_message)
  assert string.contains(error_message, "260000")
}
