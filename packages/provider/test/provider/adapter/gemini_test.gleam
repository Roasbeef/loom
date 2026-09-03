//// The Gemini adapter's contract, driven over transcripts recorded from
//// the live Gemini Developer API (gemini-3.5-flash, 2026-09-03) with the
//// signatures shortened: parts fold into kind-cut blocks, signatures stay
//// on the block they signed, a function call is one whole delta, `STOP`
//// with a call is tool use, and replay carries every signature back.

import core/json
import core/message
import core/msgpack
import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import provider/adapter/gemini
import provider/fixture.{sse_data}
import provider/internal/wire
import provider/model
import provider/retry
import provider/stream

fn resolved() -> model.ResolvedModel {
  fixture.resolved(provider: "google", model_id: "gemini-3.5-flash")
}

fn machine() -> stream.ResponseMachine(gemini.Accumulator) {
  gemini.response_machine(resolved(), now: 1_700_000_000_000)
}

// --- fixture transcripts (generateContent wire vocabulary) ----------------

fn usage_json(
  prompt: Int,
  candidates: Int,
  thoughts: Int,
  cached: Int,
) -> String {
  "{\"promptTokenCount\":"
  <> json.to_string(json.Int(prompt))
  <> ",\"candidatesTokenCount\":"
  <> json.to_string(json.Int(candidates))
  <> ",\"thoughtsTokenCount\":"
  <> json.to_string(json.Int(thoughts))
  <> ",\"cachedContentTokenCount\":"
  <> json.to_string(json.Int(cached))
  <> ",\"totalTokenCount\":"
  <> json.to_string(json.Int(prompt + candidates + thoughts))
  <> "}"
}

// One chunk: the candidate's parts, an optional finishReason, and the
// running usage every real chunk repeats.
fn chunk(parts: String, finish: String, usage: String) -> String {
  let finish_field = case finish {
    "" -> ""
    reason -> ",\"finishReason\":\"" <> reason <> "\""
  }
  sse_data(
    "{\"candidates\":[{\"content\":{\"parts\":["
    <> parts
    <> "],\"role\":\"model\"}"
    <> finish_field
    <> ",\"index\":0}],\"usageMetadata\":"
    <> usage
    <> ",\"modelVersion\":\"gemini-3.5-flash\",\"responseId\":\"BRyZasq6BO\"}",
  )
}

fn text_part(text: String) -> String {
  "{\"text\":\"" <> text <> "\"}"
}

fn thought_part(text: String) -> String {
  "{\"text\":\"" <> text <> "\",\"thought\":true}"
}

fn signed_empty_part(signature: String) -> String {
  "{\"text\":\"\",\"thoughtSignature\":\"" <> signature <> "\"}"
}

fn call_part(
  name: String,
  args: String,
  id: String,
  signature: String,
) -> String {
  let id_field = case id {
    "" -> ""
    id -> ",\"id\":\"" <> id <> "\""
  }
  "{\"functionCall\":{\"name\":\""
  <> name
  <> "\",\"args\":"
  <> args
  <> id_field
  <> "},\"thoughtSignature\":\""
  <> signature
  <> "\"}"
}

fn happy_transcript() -> String {
  chunk(thought_part("Thinking it over."), "", usage_json(6, 0, 0, 0))
  <> chunk(text_part("hello"), "", usage_json(6, 2, 61, 0))
  <> chunk(text_part(" there"), "", usage_json(6, 4, 61, 0))
  <> chunk(signed_empty_part("c2lnLTE="), "STOP", usage_json(6, 4, 61, 0))
}

// --- happy path -------------------------------------------------------------

pub fn happy_text_settles_test() {
  let events = fixture.drive_ok(machine(), happy_transcript())
  let assert [
    stream.Delta(stream.ThinkingDelta(index: 0, thinking: "Thinking it over.")),
    stream.Delta(stream.TextDelta(index: 1, text: "hello")),
    stream.Delta(stream.TextDelta(index: 1, text: " there")),
    stream.Settled(message: settled, usage:),
  ] = events
  let assert message.AssistantMessage(
    content:,
    api:,
    provider:,
    model: model_id,
    response_model:,
    response_id:,
    stop_reason:,
    raw_stop_reason:,
    end_turn:,
    ..,
  ) = stream.message(settled)
  // The trailing empty signed part signs the text block in progress.
  assert content
    == [
      message.AssistantThinking(
        thinking: "Thinking it over.",
        thinking_signature: None,
        redacted: False,
      ),
      message.AssistantText(
        text: "hello there",
        text_signature: Some("c2lnLTE="),
      ),
    ]
  assert api == "gemini-generate-content"
  assert provider == "google"
  assert model_id == "gemini-3.5-flash"
  assert response_model == Some("gemini-3.5-flash")
  assert response_id == Some("BRyZasq6BO")
  assert stop_reason == message.Stop
  assert raw_stop_reason == Some("STOP")
  assert end_turn == Some(True)
  // Thought tokens are billed output and kept as the reasoning breakdown.
  assert usage.input == 6
  assert usage.output == 65
  assert usage.reasoning == Some(61)
  assert usage.total_tokens == 71
}

pub fn happy_survives_any_chunking_test() {
  let whole = fixture.drive_ok(machine(), happy_transcript())
  let bytes = bit_array.from_string(happy_transcript())
  list.each([1, 7, 33], fn(size) {
    assert fixture.drive(
        machine(),
        status: 200,
        headers: [],
        chunks: fixture.chunked(bytes, size),
      )
      == whole
  })
}

pub fn thinking_then_text_then_thinking_cuts_three_blocks_test() {
  let transcript =
    chunk(thought_part("a"), "", usage_json(1, 0, 0, 0))
    <> chunk(text_part("b"), "", usage_json(1, 1, 1, 0))
    <> chunk(thought_part("c"), "STOP", usage_json(1, 1, 2, 0))
  let events = fixture.drive_ok(machine(), transcript)
  let assert [
    stream.Delta(stream.ThinkingDelta(index: 0, ..)),
    stream.Delta(stream.TextDelta(index: 1, ..)),
    stream.Delta(stream.ThinkingDelta(index: 2, ..)),
    stream.Settled(..),
  ] = events
}

// --- tool calls -------------------------------------------------------------

pub fn tool_call_arrives_whole_and_stop_becomes_tool_use_test() {
  // Recorded shape: the call carries an id and a signature, and the
  // finishing chunk is an empty unsigned text part with plain STOP.
  let transcript =
    chunk(
      call_part("get_weather", "{\"city\":\"Paris\"}", "call_853920", "c2ln"),
      "",
      usage_json(57, 16, 40, 0),
    )
    <> chunk(text_part(""), "STOP", usage_json(57, 16, 40, 0))
  let events = fixture.drive_ok(machine(), transcript)
  let assert [
    stream.Delta(stream.ToolCallDelta(
      index: 0,
      call_id: "call_853920",
      name: "get_weather",
      arguments_json: "{\"city\":\"Paris\"}",
    )),
    stream.Settled(message: settled, usage: _),
  ] = events
  let assert message.AssistantMessage(content:, stop_reason:, end_turn:, ..) =
    stream.message(settled)
  assert stop_reason == message.ToolUse
  assert end_turn == Some(True)
  assert content
    == [
      message.AssistantToolCall(call: message.ToolCall(
        id: "call_853920",
        name: "get_weather",
        arguments: json.Object([#("city", json.String("Paris"))]),
        thought_signature: Some("c2ln"),
        namespace: None,
      )),
    ]
}

pub fn tool_call_without_an_id_is_named_by_position_test() {
  let transcript =
    chunk(
      call_part("read", "{}", "", "c2ln")
        <> ","
        <> call_part("grep", "{\"q\":1}", "", "c2ln"),
      "STOP",
      usage_json(10, 8, 0, 0),
    )
  let events = fixture.drive_ok(machine(), transcript)
  let assert [
    stream.Delta(stream.ToolCallDelta(index: 0, call_id: "read_0", ..)),
    stream.Delta(stream.ToolCallDelta(index: 1, call_id: "grep_1", ..)),
    stream.Settled(..),
  ] = events
}

// --- settlement edge cases --------------------------------------------------

pub fn disconnect_before_finish_reason_fails_in_band_test() {
  let events =
    fixture.drive_ok(
      machine(),
      chunk(text_part("hi"), "", usage_json(1, 1, 0, 0)),
    )
  let assert [
    stream.Delta(_),
    stream.Failed(stream.StreamDisconnected(context: _)),
  ] = events
}

pub fn unknown_finish_reason_fails_in_band_test() {
  let events =
    fixture.drive_ok(
      machine(),
      chunk(text_part("hi"), "NOVEL_REASON", usage_json(1, 1, 0, 0)),
    )
  let assert [
    stream.Delta(_),
    stream.Failed(stream.UnmappedStopReason(raw: "NOVEL_REASON")),
  ] = events
}

pub fn safety_finish_settles_as_error_test() {
  let events =
    fixture.drive_ok(machine(), chunk("", "SAFETY", usage_json(1, 0, 0, 0)))
  let assert [stream.Settled(message: settled, usage: _)] = events
  let assert message.AssistantMessage(
    stop_reason:,
    error_message: Some(error_message),
    ..,
  ) = stream.message(settled)
  assert stop_reason == message.Errored
  assert string.contains(error_message, "SAFETY")
}

pub fn malformed_chunk_fails_in_band_test() {
  let events = fixture.drive_ok(machine(), sse_data("{broken"))
  let assert [stream.Failed(stream.MalformedStream(report: _))] = events
}

pub fn in_stream_error_document_fails_in_band_test() {
  let events =
    fixture.drive_ok(
      machine(),
      sse_data(
        "{\"error\":{\"code\":429,\"message\":\"Quota exceeded\",\"status\":\"RESOURCE_EXHAUSTED\"}}",
      ),
    )
  assert events
    == [
      stream.Failed(stream.StreamError(
        api_error_type: "RESOURCE_EXHAUSTED",
        message: "Quota exceeded",
      )),
    ]
}

pub fn silent_overflow_settles_as_error_test() {
  let transcript = chunk("", "STOP", usage_json(260_000, 0, 0, 0))
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

// --- usage ----------------------------------------------------------------------

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

pub fn cached_tokens_split_out_of_prompt_tokens_test() {
  let transcript = chunk("", "STOP", usage_json(9000, 40, 0, 7000))
  let events = fixture.drive_ok(machine(), transcript)
  let assert [stream.Settled(message: settled, usage:)] = events
  assert usage.cache_read == 7000
  assert usage.input == 2000
  assert usage.cache_write == 0
  assert usage.output == 40
  assert usage.total_tokens == 9040
  let assert message.AssistantMessage(usage: committed, ..) =
    stream.message(settled)
  assert committed == usage
  assert_usage_encodable(usage)
}

pub fn absent_thoughts_count_reads_as_not_reported_test() {
  let usage_text =
    "{\"promptTokenCount\":6,\"candidatesTokenCount\":4,\"totalTokenCount\":10}"
  let events = fixture.drive_ok(machine(), chunk("", "STOP", usage_text))
  let assert [stream.Settled(message: _, usage:)] = events
  assert usage.reasoning == None
  assert usage.output == 4
  assert usage.total_tokens == 10
}

pub fn oversized_usage_counts_clamp_and_stay_encodable_test() {
  let transcript =
    chunk("", "STOP", usage_json(100_000_000_000_000_000_000, 100, 0, 0))
  let events = fixture.drive_ok(machine(), transcript)
  let assert [stream.Settled(message: settled, usage:)] = events
  assert usage.input == wire.max_usage_count
  assert usage.output == 100
  assert_usage_encodable(usage)
  let assert message.AssistantMessage(usage: stored, ..) =
    stream.message(settled)
  assert_usage_encodable(stored)
}

pub fn negative_usage_counts_clamp_to_zero_test() {
  let transcript = chunk("", "STOP", usage_json(-260_000, -5, -9, -1))
  let events = fixture.drive_ok(machine(), transcript)
  let assert [stream.Settled(message: _, usage:)] = events
  assert usage.input == 0
  assert usage.output == 0
  assert usage.cache_read == 0
  assert_usage_encodable(usage)
}

// --- http errors ----------------------------------------------------------------

pub fn invalid_key_error_carries_the_status_word_test() {
  // The recorded 400 for a bad key: `status` is the closest thing the
  // dialect has to a machine-readable error type.
  let events =
    fixture.drive(machine(), status: 400, headers: [], chunks: [
      bit_array.from_string(
        "{\"error\":{\"code\":400,\"message\":\"API key not valid. Please pass a valid API key.\",\"status\":\"INVALID_ARGUMENT\"}}",
      ),
    ])
  assert events
    == [
      stream.Failed(stream.HttpError(
        status: 400,
        api_error_type: "INVALID_ARGUMENT",
        message: "API key not valid. Please pass a valid API key.",
        retry_after_ms: None,
      )),
    ]
}

pub fn rate_limit_is_retryable_test() {
  let events =
    fixture.drive(
      machine(),
      status: 429,
      headers: [#("retry-after", "3")],
      chunks: [
        bit_array.from_string(
          "{\"error\":{\"code\":429,\"message\":\"Resource exhausted\",\"status\":\"RESOURCE_EXHAUSTED\"}}",
        ),
      ],
    )
  let assert [stream.Failed(error)] = events
  assert retry.classify(error) == retry.Retryable(backoff_hint_ms: Some(3000))
}

pub fn oversized_http_error_body_fails_at_the_byte_budget_test() {
  let events =
    fixture.drive(machine(), status: 500, headers: [], chunks: [
      bit_array.from_string(string.repeat("x", 65_537)),
    ])
  let assert [stream.Failed(stream.MalformedStream(report: report))] = events
  assert string.contains(report.context, "exceeded its byte budget")
}

// --- finish-reason mapping table -----------------------------------------------

pub fn finish_reason_mapping_table_test() {
  assert gemini.map_finish_reason("STOP") == Ok(#(message.Stop, None))
  assert gemini.map_finish_reason("MAX_TOKENS") == Ok(#(message.Length, None))
  list.each(
    [
      "SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII",
      "LANGUAGE", "MALFORMED_FUNCTION_CALL", "UNEXPECTED_TOOL_CALL",
      "IMAGE_SAFETY", "OTHER", "FINISH_REASON_UNSPECIFIED",
    ],
    fn(raw) {
      let assert Ok(#(message.Errored, Some(_))) = gemini.map_finish_reason(raw)
      Nil
    },
  )
  assert gemini.map_finish_reason("stop") == Error(Nil)
  assert gemini.map_finish_reason("flex_mode_interrupted") == Error(Nil)
}

// --- request construction -------------------------------------------------------

fn parsed(body: String) -> json.JsonValue {
  let assert Ok(document) = json.parse(body)
  document
}

fn with_thinking(level: model.ThinkingLevel) -> model.ResolvedModel {
  model.ResolvedModel(..resolved(), thinking: level)
}

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
    gemini.build_request(
      base_url: "https://generativelanguage.googleapis.com/v1beta",
      api_key: "AIza-test-key",
      resolved: with_thinking(model.ThinkingMedium),
      request:,
    )
  assert built.method == "POST"
  assert built.url
    == "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash:streamGenerateContent?alt=sse"
  assert list.key_find(built.headers, "x-goog-api-key") == Ok("AIza-test-key")
  assert !string.contains(built.body, "AIza-test-key")
  let document = parsed(built.body)
  let assert Ok(system) = wire.field(document, "systemInstruction")
  let assert Ok([part]) = wire.array_field(system, "parts")
  assert wire.string_field(part, "text") == Ok("Be terse.")
  let assert Ok(config) = wire.field(document, "generationConfig")
  assert wire.int_field(config, "maxOutputTokens") == Ok(2000)
  let assert Ok(thinking) = wire.field(config, "thinkingConfig")
  assert wire.string_field(thinking, "thinkingLevel") == Ok("MEDIUM")
  assert wire.field(thinking, "includeThoughts") == Ok(json.Bool(True))
  let assert Ok([tools]) = wire.array_field(document, "tools")
  let assert Ok([declaration]) = wire.array_field(tools, "functionDeclarations")
  assert wire.string_field(declaration, "name") == Ok("get_weather")
  let assert Ok(_schema) = wire.field(declaration, "parametersJsonSchema")
  let assert Ok([content]) = wire.array_field(document, "contents")
  assert wire.string_field(content, "role") == Ok("user")
}

pub fn thinking_off_sends_no_thinking_config_test() {
  let built =
    gemini.build_request(
      base_url: "https://generativelanguage.googleapis.com/v1beta",
      api_key: "k",
      resolved: with_thinking(model.ThinkingOff),
      request: fixture.request_for(resolved()),
    )
  assert !string.contains(built.body, "thinkingConfig")
  assert !string.contains(built.body, "\"tools\"")
}

pub fn gemini_two_point_five_takes_a_token_budget_test() {
  // 2.5 rejects `thinkingLevel` ("Thinking level is not supported for
  // this model"); 3.x rejects the budget. The dial is read off the id.
  assert gemini.thinking_dial("gemini-2.5-pro") == gemini.TokenBudget
  assert gemini.thinking_dial("gemini-2.5-flash-lite") == gemini.TokenBudget
  assert gemini.thinking_dial("gemini-3.1-pro-preview") == gemini.LevelWord
  assert gemini.thinking_dial("gemini-3.8-flash") == gemini.LevelWord
  assert gemini.thinking_dial("gemini-flash-latest") == gemini.LevelWord
  assert gemini.thinking_config("gemini-2.5-flash", model.ThinkingHigh)
    == Some(
      json.Object([
        #("includeThoughts", json.Bool(True)),
        #("thinkingBudget", json.Int(24_576)),
      ]),
    )
  assert gemini.thinking_config("gemini-3.5-flash", model.ThinkingLow)
    == Some(
      json.Object([
        #("includeThoughts", json.Bool(True)),
        #("thinkingLevel", json.String("LOW")),
      ]),
    )
  assert gemini.thinking_config("gemini-2.5-flash", model.ThinkingOff) == None
}

fn tool_result(id: String, text: String) -> message.AgentMessage {
  tool_result_with(
    id,
    [message.ToolResultText(text:, text_signature: None)],
    is_error: False,
  )
}

fn tool_result_with(
  id: String,
  content: List(message.ToolResultBlock),
  is_error is_error: Bool,
) -> message.AgentMessage {
  message.ToolResultMessage(
    tool_call_id: id,
    tool_name: "get_weather",
    content:,
    details: None,
    usage: None,
    added_tool_names: None,
    is_error:,
    timestamp: 2,
  )
}

fn assistant_turn(
  content: List(message.AssistantBlock),
) -> message.AgentMessage {
  message.AssistantMessage(
    content:,
    api: gemini.api_name,
    provider: "google",
    model: "gemini-3.5-flash",
    response_model: None,
    response_id: None,
    diagnostics: None,
    usage: message.Usage(
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
    ),
    stop_reason: message.ToolUse,
    deferred: None,
    error_message: None,
    raw_stop_reason: Some("STOP"),
    end_turn: Some(True),
    timestamp: 1,
  )
}

fn call(
  id: String,
  signature: option.Option(String),
) -> message.AssistantBlock {
  message.AssistantToolCall(call: message.ToolCall(
    id:,
    name: "get_weather",
    arguments: json.Object([#("city", json.String("Paris"))]),
    thought_signature: signature,
    namespace: None,
  ))
}

fn contents_of(messages: List(message.AgentMessage)) -> List(json.JsonValue) {
  let built =
    gemini.build_request(
      base_url: "https://generativelanguage.googleapis.com/v1beta",
      api_key: "k",
      resolved: resolved(),
      request: model.ProviderRequest(
        ..fixture.request_for(resolved()),
        messages:,
      ),
    )
  let assert Ok(contents) = wire.array_field(parsed(built.body), "contents")
  contents
}

pub fn replay_carries_signatures_and_merges_parallel_results_test() {
  // The recorded shape that the API accepts back: the call with its
  // signature and id, and both results in ONE user turn — split across
  // two turns the API refuses with "number of function response parts is
  // not equal to number of function call parts".
  let contents =
    contents_of([
      assistant_turn([
        message.AssistantThinking(
          thinking: "hmm",
          thinking_signature: None,
          redacted: False,
        ),
        message.AssistantText(text: "Checking.", text_signature: Some("dHh0")),
        call("call_1", Some("c2lnLTE=")),
        call("call_2", Some("c2lnLTI=")),
      ]),
      tool_result("call_1", "Sunny"),
      tool_result("call_2", "Rainy"),
    ])
  let assert [model_turn, results_turn] = contents
  assert wire.string_field(model_turn, "role") == Ok("model")
  // Thought summaries are not replayed; text and both calls are, signed.
  let assert Ok([text, first, second]) = wire.array_field(model_turn, "parts")
  assert wire.string_field(text, "thoughtSignature") == Ok("dHh0")
  let assert Ok(first_call) = wire.field(first, "functionCall")
  assert wire.string_field(first_call, "id") == Ok("call_1")
  assert wire.string_field(first, "thoughtSignature") == Ok("c2lnLTE=")
  assert wire.string_field(second, "thoughtSignature") == Ok("c2lnLTI=")
  assert wire.string_field(results_turn, "role") == Ok("user")
  let assert Ok([first_result, second_result]) =
    wire.array_field(results_turn, "parts")
  let assert Ok(response) = wire.field(first_result, "functionResponse")
  assert wire.string_field(response, "id") == Ok("call_1")
  let assert Ok(payload) = wire.field(response, "response")
  assert wire.string_field(payload, "output") == Ok("Sunny")
  let assert Ok(_) = wire.field(second_result, "functionResponse")
}

pub fn a_signed_thought_replays_as_a_thought_part_test() {
  // Only a signature makes a thought worth sending back; the unsigned
  // sibling beside it is dropped as before.
  let contents =
    contents_of([
      assistant_turn([
        message.AssistantThinking(
          thinking: "unsigned",
          thinking_signature: None,
          redacted: False,
        ),
        message.AssistantThinking(
          thinking: "signed",
          thinking_signature: Some("c2lnLXQ="),
          redacted: False,
        ),
        message.AssistantText(text: "Answer.", text_signature: None),
      ]),
    ])
  let assert [model_turn] = contents
  let assert Ok([thought, text]) = wire.array_field(model_turn, "parts")
  assert wire.string_field(thought, "text") == Ok("signed")
  assert wire.field(thought, "thought") == Ok(json.Bool(True))
  assert wire.string_field(thought, "thoughtSignature") == Ok("c2lnLXQ=")
  assert wire.string_field(text, "text") == Ok("Answer.")
}

pub fn unsigned_tool_call_replays_with_the_skip_sentinel_test() {
  // A call another model made earlier in the conversation has no Gemini
  // signature; without the sentinel the API refuses the whole request.
  let contents = contents_of([assistant_turn([call("call_x", None)])])
  let assert [model_turn] = contents
  let assert Ok([part]) = wire.array_field(model_turn, "parts")
  assert wire.string_field(part, "thoughtSignature")
    == Ok(gemini.skip_signature_sentinel)
}

pub fn error_results_use_the_error_key_test() {
  let failed =
    tool_result_with(
      "call_1",
      [message.ToolResultText(text: "no such file", text_signature: None)],
      is_error: True,
    )
  let assert [turn] = contents_of([failed])
  let assert Ok([part]) = wire.array_field(turn, "parts")
  let assert Ok(response) = wire.field(part, "functionResponse")
  let assert Ok(payload) = wire.field(response, "response")
  assert wire.string_field(payload, "error") == Ok("no such file")
  assert wire.string_field(payload, "output") == Error(Nil)
}

pub fn a_result_image_follows_in_its_own_user_turn_test() {
  let with_image =
    tool_result_with(
      "call_1",
      [
        message.ToolResultText(text: "see image", text_signature: None),
        message.ToolResultImage(data: "AAAA", mime_type: "image/png"),
      ],
      is_error: False,
    )
  let assert [results, images] = contents_of([with_image])
  let assert Ok([_response]) = wire.array_field(results, "parts")
  assert wire.string_field(images, "role") == Ok("user")
  let assert Ok([_caption, image]) = wire.array_field(images, "parts")
  let assert Ok(inline) = wire.field(image, "inlineData")
  assert wire.string_field(inline, "mimeType") == Ok("image/png")
}

pub fn empty_assistant_turns_are_not_sent_test() {
  // An assistant turn that was all unsigned thinking renders to no parts,
  // and an empty `parts` array is a 400.
  let contents =
    contents_of([
      assistant_turn([
        message.AssistantThinking(
          thinking: "only thoughts",
          thinking_signature: None,
          redacted: False,
        ),
      ]),
    ])
  assert contents == []
}

pub fn the_request_is_deterministic_test() {
  let request = fixture.request_for(resolved())
  let once =
    gemini.build_request(
      base_url: "https://generativelanguage.googleapis.com/v1beta",
      api_key: "k",
      resolved: resolved(),
      request:,
    )
  let again =
    gemini.build_request(
      base_url: "https://generativelanguage.googleapis.com/v1beta",
      api_key: "k",
      resolved: resolved(),
      request:,
    )
  assert once.body == again.body
}
