//// The Responses witnesses are exercised through the public sans-I/O fold.
//// Each negative changes one semantic witness, rather than merely making the
//// outer JSON invalid. Chunk tests hold the transcript fixed and vary bytes.

import core/codec
import core/json.{type JsonValue}
import core/message
import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import provider/adapter/responses
import provider/fixture
import provider/internal/wire
import provider/model
import provider/retry
import provider/stream

fn put(value: JsonValue, key: String, replacement: JsonValue) -> JsonValue {
  let assert json.Object(fields) = value as "fixture objects have named fields"
  json.Object(
    list.append(list.filter(fields, fn(field) { field.0 != key }), [
      #(key, replacement),
    ]),
  )
}

fn at(values: List(a), index: Int) -> a {
  let assert Ok(value) = list.first(list.drop(values, index))
    as "fixture event position exists"
  value
}

fn resolved() -> model.ResolvedModel {
  fixture.resolved("openai", "fixture-model")
}

fn machine() -> stream.ResponseMachine(responses.Accumulator) {
  responses.response_machine(resolved(), now: 123)
}

fn event(kind: String, fields: List(#(String, JsonValue))) -> String {
  fixture.sse_event(
    kind,
    json.to_string(json.Object([#("type", json.String(kind)), ..fields])),
  )
}

fn response(status: String, output: List(JsonValue)) -> JsonValue {
  json.Object([
    #("id", json.String("resp_fixture")),
    #("model", json.String("fixture-model")),
    #("status", json.String(status)),
    #("error", json.Null),
    #("output", json.Array(output)),
  ])
}

fn created() -> String {
  event("response.created", [#("response", response("in_progress", []))])
}

fn completed(output: List(JsonValue)) -> String {
  event("response.completed", [#("response", response("completed", output))])
}

fn part(kind: String, text: String) -> JsonValue {
  json.Object([
    #("type", json.String(kind)),
    #(
      case kind {
        "refusal" -> "refusal"
        _ -> "text"
      },
      json.String(text),
    ),
  ])
}

fn text_item(status: String, parts: List(JsonValue)) -> JsonValue {
  json.Object([
    #("id", json.String("msg_fixture")),
    #("type", json.String("message")),
    #("status", json.String(status)),
    #("role", json.String("assistant")),
    #("content", json.Array(parts)),
  ])
}

fn keyed() -> List(#(String, JsonValue)) {
  [
    #("output_index", json.Int(0)),
    #("item_id", json.String("msg_fixture")),
    #("content_index", json.Int(0)),
  ]
}

fn text_events(text: String, kind: String) -> List(String) {
  let delta_type = case kind {
    "refusal" -> "response.refusal"
    _ -> "response.output_text"
  }
  [
    created(),
    event("response.output_item.added", [
      #("output_index", json.Int(0)),
      #("item", text_item("in_progress", [])),
    ]),
    event("response.content_part.added", [#("part", part(kind, "")), ..keyed()]),
    event(delta_type <> ".delta", [#("delta", json.String(text)), ..keyed()]),
    event(delta_type <> ".done", [
      #(
        case kind {
          "refusal" -> "refusal"
          _ -> "text"
        },
        json.String(text),
      ),
      ..keyed()
    ]),
    event("response.content_part.done", [#("part", part(kind, text)), ..keyed()]),
    event("response.output_item.done", [
      #("output_index", json.Int(0)),
      #("item", text_item("completed", [part(kind, text)])),
    ]),
    completed([text_item("completed", [part(kind, text)])]),
  ]
}

fn run(events: List(String)) -> List(stream.StreamEvent) {
  fixture.drive_ok(machine(), string.concat(events))
}

fn settled(events: List(stream.StreamEvent)) -> message.AgentMessage {
  let assert Ok(stream.Settled(message, _)) = list.last(events)
    as "a verified terminal settles"
  stream.message(message)
}

fn malformed(events: List(stream.StreamEvent)) -> Nil {
  let assert Ok(stream.Failed(stream.MalformedStream(_))) = list.last(events)
    as "the changed provider witness fails as malformed"
  Nil
}

pub fn responses_text_and_terminal_once_test() {
  let body = text_events("Hello 🧵", "output_text")
  let events = run(body)
  let assert [
    stream.Delta(stream.TextDelta(0, "Hello 🧵")),
    stream.Settled(_, _),
  ] = events
    as "done witnesses add no deltas"
  let assert message.AssistantMessage(
    content: [message.AssistantText("Hello 🧵", None)],
    api: "openai-responses",
    timestamp: 123,
    stop_reason: message.Stop,
    ..,
  ) = settled(events)
    as "text settles under the new dialect"
  assert run(list.append(body, ["data: not-json\n\n", completed([])])) == events
}

pub fn responses_message_phase_survives_settlement_and_replay_test() {
  list.each(["commentary", "final_answer"], fn(phase) {
    let events = text_events("phase text", "output_text")
    let item =
      put(
        text_item("completed", [part("output_text", "phase text")]),
        "phase",
        json.String(phase),
      )
    let events =
      list.append(list.take(events, 6), [
        event("response.output_item.done", [
          #("output_index", json.Int(0)),
          #("item", item),
        ]),
        completed([item]),
      ])
    let assistant = settled(run(events))
    let target = resolved()
    let request =
      model.ProviderRequest(..fixture.request_for(target), messages: [assistant])
    let body =
      responses.build_request(
        "https://example.test/v1",
        "canary",
        target,
        request,
      ).body
    let assert Ok(body) = json.parse(body) as "phase replay request is JSON"
    let assert Ok([item]) = wire.array_field(body, "input")
      as "one assistant message is replayed"
    assert wire.string_field(item, "phase") == Ok(phase)
  })
}

pub fn responses_message_phase_disagreement_and_unknown_values_fail_test() {
  let events = text_events("phase text", "output_text")
  let item = text_item("completed", [part("output_text", "phase text")])
  let commentary = put(item, "phase", json.String("commentary"))
  let final_answer = put(item, "phase", json.String("final_answer"))
  malformed(
    run(
      list.append(list.take(events, 6), [
        event("response.output_item.done", [
          #("output_index", json.Int(0)),
          #("item", commentary),
        ]),
        completed([final_answer]),
      ]),
    ),
  )
  list.each([json.String("novel_phase"), json.Int(1)], fn(phase) {
    let invalid = put(item, "phase", phase)
    malformed(
      run(
        list.append(list.take(events, 6), [
          event("response.output_item.done", [
            #("output_index", json.Int(0)),
            #("item", invalid),
          ]),
          completed([invalid]),
        ]),
      ),
    )
  })
}

pub fn responses_initial_message_phase_is_a_consistency_witness_test() {
  let events = text_events("phase text", "output_text")
  let initial =
    put(text_item("in_progress", []), "phase", json.String("commentary"))
  let added =
    event("response.output_item.added", [
      #("output_index", json.Int(0)),
      #("item", initial),
    ])
  let prefix =
    list.index_map(list.take(events, 6), fn(value, index) {
      case index == 1 {
        True -> added
        False -> value
      }
    })
  let item = text_item("completed", [part("output_text", "phase text")])
  list.each(
    [item, put(item, "phase", json.String("final_answer"))],
    fn(changed) {
      malformed(
        run(
          list.append(prefix, [
            event("response.output_item.done", [
              #("output_index", json.Int(0)),
              #("item", changed),
            ]),
            completed([changed]),
          ]),
        ),
      )
    },
  )
  let matching = put(item, "phase", json.String("commentary"))
  let assert message.AssistantMessage(stop_reason: message.Stop, ..) =
    settled(
      run(
        list.append(prefix, [
          event("response.output_item.done", [
            #("output_index", json.Int(0)),
            #("item", matching),
          ]),
          completed([matching]),
        ]),
      ),
    )
    as "an unchanged supplied phase remains valid"
  malformed(
    run([
      created(),
      event("response.output_item.added", [
        #("output_index", json.Int(0)),
        #("item", put(initial, "phase", json.String("unknown"))),
      ]),
    ]),
  )
}

pub fn responses_every_byte_split_preserves_events_test() {
  let body = string.concat(text_events("héllo 🧵", "output_text"))
  let bytes = bit_array.from_string(body)
  let expected = fixture.drive_ok(machine(), body)
  list.each(
    list.index_map(
      list.repeat(Nil, bit_array.byte_size(bytes) + 1),
      fn(_, index) { index },
    ),
    fn(cut) {
      let assert Ok(left) = bit_array.slice(bytes, 0, cut)
        as "cut is inside the fixture"
      let assert Ok(right) =
        bit_array.slice(bytes, cut, bit_array.byte_size(bytes) - cut)
        as "remaining bytes are in bounds"
      assert fixture.drive(machine(), 200, [], [left, right]) == expected
    },
  )
  assert fixture.drive(machine(), 200, [], fixture.chunked(bytes, 1))
    == expected
}

pub fn responses_changed_done_item_and_final_witnesses_fail_test() {
  let events = text_events("original", "output_text")
  list.each([4, 5, 6, 7], fn(index) {
    let changed =
      list.index_map(events, fn(event, position) {
        case position == index {
          True -> string.replace(event, "original", "changed")
          False -> event
        }
      })
    malformed(run(changed))
  })
}

pub fn responses_missing_each_closure_fails_test() {
  let events = text_events("original", "output_text")
  list.each([1, 2, 4, 5, 6], fn(index) {
    malformed(run(
      events
      |> list.index_map(fn(event, position) { #(position, event) })
      |> list.filter(fn(pair) { pair.0 != index })
      |> list.map(fn(pair) { pair.1 }),
    ))
  })
}

pub fn responses_sequence_and_unknown_semantics_fail_test() {
  list.each(["response.new_content", "response.output_item.unknown"], fn(kind) {
    malformed(run([created(), event(kind, [])]))
  })
  let progress = fn(sequence) {
    event("response.in_progress", [
      #("sequence_number", json.Int(sequence)),
      #("response", response("in_progress", [])),
    ])
  }
  list.each([1, 0], fn(next) { malformed(run([progress(1), progress(next)])) })
  malformed(run([created(), "data: {broken}\n\n"]))
}

pub fn responses_eof_never_settles_partial_test() {
  let events = run(list.take(text_events("partial", "output_text"), 7))
  let assert Ok(stream.Failed(stream.StreamDisconnected(_))) = list.last(events)
    as "all item closures still need response terminal"
}

fn call_item(arguments: String) -> JsonValue {
  json.Object([
    #("id", json.String("fc_fixture")),
    #("type", json.String("function_call")),
    #("status", json.String("completed")),
    #("call_id", json.String("call_fixture")),
    #("name", json.String("read")),
    #("arguments", json.String(arguments)),
  ])
}

fn call_events(arguments: String) -> List(String) {
  let keys = [
    #("output_index", json.Int(0)),
    #("item_id", json.String("fc_fixture")),
  ]
  [
    created(),
    event("response.output_item.added", [
      #("output_index", json.Int(0)),
      #("item", put(call_item(""), "status", json.String("in_progress"))),
    ]),
    event("response.function_call_arguments.delta", [
      #("delta", json.String(arguments)),
      ..keys
    ]),
    event("response.function_call_arguments.done", [
      #("arguments", json.String(arguments)),
      ..keys
    ]),
    event("response.output_item.done", [
      #("output_index", json.Int(0)),
      #("item", call_item(arguments)),
    ]),
    completed([call_item(arguments)]),
  ]
}

pub fn responses_tool_arguments_preserve_model_errors_test() {
  list.each(["", "{}", "{broken", "[1]"], fn(arguments) {
    let assert message.AssistantMessage(
      content: [message.AssistantToolCall(call)],
      stop_reason: message.ToolUse,
      ..,
    ) = settled(run(call_events(arguments)))
      as "wire agreement settles model argument text"
    assert call.arguments == wire.tool_arguments(arguments)
    assert call.id == "call_fixture"
    assert call.name == "read"
  })
}

pub fn responses_tool_argument_witness_mismatch_test() {
  let events = call_events("{}")
  malformed(
    run(
      list.index_map(events, fn(event, index) {
        case index == 3 {
          True -> string.replace(event, "{}", "[]")
          False -> event
        }
      }),
    ),
  )
  list.each([#("name", "different"), #("call_id", "different")], fn(field) {
    let events = call_events("{}")
    let changed =
      event("response.function_call_arguments.done", [
        #("output_index", json.Int(0)),
        #("item_id", json.String("fc_fixture")),
        #("arguments", json.String("{}")),
        #(field.0, json.String(field.1)),
      ])
    malformed(
      run(
        list.index_map(events, fn(event, index) {
          case index == 3 {
            True -> changed
            False -> event
          }
        }),
      ),
    )
  })
}

pub fn responses_terminal_status_and_refusal_test() {
  let assert message.AssistantMessage(
    stop_reason: message.Errored,
    raw_stop_reason: Some("refusal"),
    content: [message.AssistantText("No", None)],
    ..,
  ) = settled(run(text_events("No", "refusal")))
    as "refusal remains visible without new core variants"
  malformed(
    run([
      created(),
      event("response.completed", [#("response", response("in_progress", []))]),
    ]),
  )
  let assert message.AssistantMessage(stop_reason: message.Aborted, ..) =
    settled(
      run([
        created(),
        event("response.cancelled", [#("response", response("cancelled", []))]),
      ]),
    )
    as "consistent cancellation is terminal"
}

pub fn responses_incomplete_and_failure_mapping_test() {
  list.each(
    [
      #("max_output_tokens", message.Length),
      #("content_filter", message.Errored),
    ],
    fn(pair) {
      let assert json.Object(fields) = response("incomplete", [])
        as "fixture response is an object"
      let incomplete =
        json.Object([
          #(
            "incomplete_details",
            json.Object([#("reason", json.String(pair.0))]),
          ),
          ..fields
        ])
      let assert message.AssistantMessage(
        stop_reason: stop,
        raw_stop_reason: Some(raw),
        ..,
      ) =
        settled(
          run([
            created(),
            event("response.incomplete", [#("response", incomplete)]),
          ]),
        )
        as "known incomplete reason settles"
      assert stop == pair.1
      assert raw == pair.0
    },
  )
  let assert [stream.Failed(stream.UnmappedStopReason(_))] =
    run([
      created(),
      event("response.incomplete", [#("response", response("incomplete", []))]),
    ])
    as "unknown incomplete reasons fail"
  let assert [stream.Failed(stream.StreamError(_, _))] =
    run([created(), event("response.failed", [])])
    as "provider failure is in-band"
}

pub fn responses_usage_clamps_and_splits_test() {
  let assert json.Object(fields) = response("completed", [])
    as "fixture response is an object"
  let value =
    json.Object([
      #(
        "usage",
        json.Object([
          #("input_tokens", json.Int(10)),
          #("output_tokens", json.Int(4)),
          #(
            "input_tokens_details",
            json.Object([
              #("cached_tokens", json.Int(8)),
              #("cache_write_tokens", json.Int(9)),
            ]),
          ),
          #(
            "output_tokens_details",
            json.Object([#("reasoning_tokens", json.Int(3))]),
          ),
        ]),
      ),
      ..fields
    ])
  let assert message.AssistantMessage(usage:, ..) =
    settled(
      run([created(), event("response.completed", [#("response", value)])]),
    )
    as "usage is extracted from terminal"
  assert #(usage.input, usage.cache_read, usage.cache_write, usage.output)
    == #(0, 8, 2, 4)
  assert usage.total_tokens == 14
  assert usage.reasoning == Some(3)
  assert usage.cache_write_1h == None
}

pub fn responses_request_policy_and_secret_boundary_test() {
  let target = model.ResolvedModel(..resolved(), thinking: model.ThinkingHigh)
  let request =
    model.ProviderRequest(..fixture.request_for(target), tools: [
      model.ToolSpec("read", "Read", json.Object([])),
    ])
  let built =
    responses.build_request(
      "https://example.test/v1",
      "private-fixture-key",
      target,
      request,
    )
  assert built.url == "https://example.test/v1/responses"
  assert built.method == "POST"
  assert list.key_find(built.headers, "authorization")
    == Ok("Bearer private-fixture-key")
  assert list.key_find(built.headers, "accept") == Ok("text/event-stream")
  let assert Ok(body) = json.parse(built.body) as "request is valid JSON"
  assert wire.field(body, "store") == Ok(json.Bool(False))
  assert wire.field(body, "stream") == Ok(json.Bool(True))
  assert wire.field(body, "reasoning")
    == Ok(
      json.Object([
        #("effort", json.String("high")),
        #("summary", json.String("auto")),
      ]),
    )
  let assert Ok([tool]) = wire.array_field(body, "tools") as "one flat tool"
  assert wire.field(tool, "name") == Ok(json.String("read"))
  assert wire.field(tool, "strict") == Error(Nil)
  assert !string.contains(built.body, "private-fixture-key")
  list.each(
    ["previous_response_id", "conversation", "service_tier", "prompt_cache_key"],
    fn(key) {
      assert wire.field(body, key) == Error(Nil)
    },
  )
}

pub fn responses_interleaved_item_starts_preserve_delta_block_positions_test() {
  let text = text_events("first text", "output_text")
  let calls =
    call_events("{\"path\":\"a\"}")
    |> list.map(fn(event) {
      string.replace(event, "\"output_index\":0", "\"output_index\":1")
    })

  // The call begins before the earlier output item's text part. Its emitted
  // block zero must still be block zero in the settled durable message.
  let events =
    run([
      at(text, 0),
      at(text, 1),
      at(calls, 1),
      at(text, 2),
      at(calls, 2),
      at(text, 3),
      at(calls, 3),
      at(text, 4),
      at(text, 5),
      at(calls, 4),
      at(text, 6),
      completed([
        text_item("completed", [part("output_text", "first text")]),
        call_item("{\"path\":\"a\"}"),
      ]),
    ])
  let assert [
    stream.Delta(stream.ToolCallDelta(0, _, _, _)),
    stream.Delta(stream.TextDelta(1, "first text")),
    stream.Settled(_, _),
  ] = events
    as "interleaved deltas retain original synthetic indices"
  let assert message.AssistantMessage(
    content: [
      message.AssistantToolCall(_),
      message.AssistantText("first text", None),
    ],
    diagnostics: Some(metadata),
    ..,
  ) = settled(events)
    as "settlement retains the delta ordering"
  let assert Ok(metadata) = wire.field(metadata, "loom.openai-responses.v1")
    as "order is namespaced"
  assert wire.array_field(metadata, "block_order")
    == Ok([json.Int(1), json.Int(0)])
}

pub fn responses_identity_index_duplicate_and_done_status_failures_test() {
  let events = text_events("text", "output_text")
  list.each(
    [
      #(3, "msg_fixture", "wrong_id"),
      #(3, "\"output_index\":0", "\"output_index\":1"),
      #(3, "\"content_index\":0", "\"content_index\":1"),
      #(7, "resp_fixture", "different_response"),
      #(7, "fixture-model", "different_model"),
      #(6, "completed", "in_progress"),
    ],
    fn(change) {
      malformed(
        run(
          list.index_map(events, fn(event, index) {
            case index == change.0 {
              True -> string.replace(event, change.1, change.2)
              False -> event
            }
          }),
        ),
      )
    },
  )
  malformed(run([at(events, 0), at(events, 1), at(events, 1)]))
  malformed(run([at(events, 0), at(events, 1), at(events, 2), at(events, 2)]))
  malformed(
    run([
      at(events, 0),
      string.replace(
        at(events, 1),
        "\"type\":\"message\"",
        "\"type\":\"web_search_call\"",
      ),
    ]),
  )
  malformed(
    run([
      at(events, 0),
      at(events, 1),
      at(events, 2),
      event("response.content_part.added", [
        #("part", part("refusal", "")),
        ..keyed()
      ]),
    ]),
  )
  malformed(
    run(
      list.index_map(events, fn(event, index) {
        case index >= 6 {
          True ->
            string.replace(
              event,
              "\"status\":\"completed\"",
              "\"status\":\"incomplete\"",
            )
          False -> event
        }
      }),
    ),
  )
}

fn reasoning_item(parts: List(JsonValue), signature: String) -> JsonValue {
  json.Object([
    #("id", json.String("rs_fixture")),
    #("type", json.String("reasoning")),
    #(
      "summary",
      parts
        |> list.filter(fn(part) {
          wire.string_field(part, "type") == Ok("summary_text")
        })
        |> json.Array,
    ),
    #(
      "content",
      parts
        |> list.filter(fn(part) {
          wire.string_field(part, "type") == Ok("reasoning_text")
        })
        |> json.Array,
    ),
    #("encrypted_content", json.String(signature)),
  ])
}

pub fn responses_reasoning_summary_text_and_empty_encrypted_item_test() {
  let keys = [
    #("output_index", json.Int(0)),
    #("item_id", json.String("rs_fixture")),
  ]
  let start =
    event("response.output_item.added", [
      #("output_index", json.Int(0)),
      #("item", reasoning_item([], "")),
    ])
  let summary_keys = [#("summary_index", json.Int(0)), ..keys]
  let content_keys = [#("content_index", json.Int(0)), ..keys]
  let output =
    reasoning_item(
      [part("summary_text", "summary"), part("reasoning_text", "reason")],
      "opaque-cipher",
    )
  let events =
    run([
      created(),
      start,
      event("response.reasoning_summary_part.added", [
        #("part", part("summary_text", "")),
        ..summary_keys
      ]),
      event("response.reasoning_summary_text.delta", [
        #("delta", json.String("summary")),
        ..summary_keys
      ]),
      event("response.reasoning_summary_text.done", [
        #("text", json.String("summary")),
        ..summary_keys
      ]),
      event("response.reasoning_summary_part.done", [
        #("part", part("summary_text", "summary")),
        ..summary_keys
      ]),
      event("response.content_part.added", [
        #("part", part("reasoning_text", "")),
        ..content_keys
      ]),
      event("response.reasoning_text.delta", [
        #("delta", json.String("reason")),
        ..content_keys
      ]),
      event("response.reasoning_text.done", [
        #("text", json.String("reason")),
        ..content_keys
      ]),
      event("response.content_part.done", [
        #("part", part("reasoning_text", "reason")),
        ..content_keys
      ]),
      event("response.output_item.done", [
        #("output_index", json.Int(0)),
        #("item", output),
      ]),
      completed([output]),
    ])
  let assert [
    stream.Delta(stream.ThinkingDelta(0, "summary")),
    stream.Delta(stream.ThinkingDelta(1, "reason")),
    stream.Settled(_, _),
  ] = events
    as "both reasoning event families emit thinking deltas"
  let assert message.AssistantMessage(
    content: [
      message.AssistantThinking("summary", Some("opaque-cipher"), False),
      message.AssistantThinking("reason", None, False),
    ],
    ..,
  ) = settled(events)
    as "ciphertext stays with the durable reasoning blocks"
  let empty = reasoning_item([], "opaque-cipher")
  let assert message.AssistantMessage(
    content: [message.AssistantThinking("", Some("opaque-cipher"), False)],
    ..,
  ) =
    settled(
      run([
        created(),
        start,
        event("response.output_item.done", [
          #("output_index", json.Int(0)),
          #("item", empty),
        ]),
        completed([empty]),
      ]),
    )
    as "encrypted reasoning without visible summary remains replayable"
}

fn annotated_events(title: String) -> List(String) {
  let citation =
    json.Object([
      #("type", json.String("url_citation")),
      #("start_index", json.Int(0)),
      #("end_index", json.Int(4)),
      #("url", json.String("https://example.test/source")),
      #("title", json.String(title)),
    ])
  let annotated =
    put(part("output_text", "text"), "annotations", json.Array([citation]))
  let events = text_events("text", "output_text")
  [
    at(events, 0),
    at(events, 1),
    at(events, 2),
    at(events, 3),
    event("response.output_text.annotation.added", [
      #("annotation_index", json.Int(0)),
      #("annotation", citation),
      ..keyed()
    ]),
    at(events, 4),
    event("response.content_part.done", [#("part", annotated), ..keyed()]),
    event("response.output_item.done", [
      #("output_index", json.Int(0)),
      #("item", text_item("completed", [annotated])),
    ]),
    completed([text_item("completed", [annotated])]),
  ]
}

pub fn responses_annotation_witness_and_replay_budget_test() {
  let assert message.AssistantMessage(diagnostics: Some(diagnostics), ..) =
    settled(run(annotated_events("Source")))
    as "bounded citation metadata survives"
  assert string.contains(
    json.to_string(diagnostics),
    "https://example.test/source",
  )
  malformed(run(annotated_events(string.repeat("x", 65_536))))
  malformed(
    run(
      list.index_map(annotated_events("Source"), fn(event, index) {
        case index == 6 {
          True -> string.replace(event, "Source", "Wrong")
          False -> event
        }
      }),
    ),
  )
}

pub fn responses_usage_extremes_overflow_and_explicit_total_test() {
  list.each([#(-10, 0), #(9_999_999_999_999, wire.max_usage_count)], fn(pair) {
    let value =
      put(
        response("completed", []),
        "usage",
        json.Object([
          #("input_tokens", json.Int(pair.0)),
          #("output_tokens", json.Int(-1)),
          #("total_tokens", json.Int(pair.0)),
          #(
            "input_tokens_details",
            json.Object([
              #("cached_tokens", json.Int(-2)),
              #("cache_write_tokens", json.Int(-3)),
            ]),
          ),
        ]),
      )
    let assert message.AssistantMessage(
      usage:,
      stop_reason: stop,
      error_message: error,
      ..,
    ) =
      settled(
        run([created(), event("response.completed", [#("response", value)])]),
      )
      as "even extreme usage remains encodable"
    assert usage.input == pair.1
    assert usage.output == 0
    assert usage.cache_read == 0
    assert usage.cache_write == 0
    assert usage.total_tokens == pair.1
    case pair.1 > 200_000 {
      True -> {
        assert stop == message.Errored
        let assert Some(error) = error as "overflow is explicit"
        assert retry.is_overflow_message(error)
      }
      False -> {
        assert stop == message.Stop
      }
    }
  })
}

pub fn responses_stream_and_http_errors_preserve_retry_without_remote_text_test() {
  list.each(
    [
      "server_error",
      "rate_limit_error",
      "timeout_error",
      "internal_server_error",
    ],
    fn(code) {
      let error =
        json.Object([
          #("code", json.String(code)),
          #("message", json.String("secret-canary")),
        ])
      let body = put(response("failed", []), "error", error)
      let assert [stream.Failed(failure)] =
        run([event("response.failed", [#("response", body)])])
        as "failure is one terminal"
      assert retry.classify(failure) == retry.Retryable(None)
      assert !string.contains(stream.describe_error(failure), "secret-canary")
      let assert [stream.Failed(top)] =
        run([
          event("error", [
            #("code", json.String(code)),
            #("message", json.String("secret-canary")),
          ]),
        ])
        as "top-level errors have the same retry semantics"
      assert retry.classify(top) == retry.Retryable(None)
    },
  )
  let assert [stream.Failed(error)] =
    fixture.drive(machine(), 429, [#("retry-after", "2")], [
      bit_array.from_string(
        "{\"error\":{\"code\":\"rate_limit_exceeded\",\"message\":\"secret-canary\"}}",
      ),
    ])
    as "HTTP errors remain bounded and classified"
  assert retry.classify(error) == retry.Retryable(Some(2000))
  assert !string.contains(stream.describe_error(error), "secret-canary")
}

pub fn responses_wire_and_error_body_budgets_fail_in_band_test() {
  malformed(
    fixture.drive(machine(), 200, [], [
      bit_array.from_string("data: " <> string.repeat("x", 4_194_305)),
    ]),
  )
  malformed(
    fixture.drive(machine(), 500, [], [
      bit_array.from_string(string.repeat("x", 65_537)),
    ]),
  )
}

pub fn responses_reasoning_cipher_is_stored_once_and_replays_losslessly_test() {
  let cipher = string.repeat("opaque-cipher-", 8192)
  let parts = list.repeat(part("summary_text", "x"), 32)
  let output = reasoning_item(parts, cipher)
  let keys = [
    #("output_index", json.Int(0)),
    #("item_id", json.String("rs_fixture")),
  ]
  let part_events =
    list.index_map(parts, fn(part, index) {
      let keys = [#("summary_index", json.Int(index)), ..keys]
      [
        event("response.reasoning_summary_part.added", [
          #("part", put(part, "text", json.String(""))),
          ..keys
        ]),
        event("response.reasoning_summary_text.delta", [
          #("delta", json.String("x")),
          ..keys
        ]),
        event("response.reasoning_summary_text.done", [
          #("text", json.String("x")),
          ..keys
        ]),
        event("response.reasoning_summary_part.done", [#("part", part), ..keys]),
      ]
    })
    |> list.flatten
  let transcript =
    list.flatten([
      [
        created(),
        event("response.output_item.added", [
          #("output_index", json.Int(0)),
          #("item", reasoning_item([], "")),
        ]),
      ],
      part_events,
      [
        event("response.output_item.done", [
          #("output_index", json.Int(0)),
          #("item", output),
        ]),
        completed([output]),
      ],
    ])
  let assistant = settled(run(transcript))
  let encoded = assistant |> codec.encode_message |> json.to_string
  assert string.byte_size(encoded) < string.byte_size(cipher) + 20_000
  assert list.length(string.split(encoded, cipher)) == 2

  // The compact template restores one complete provider item, so storing its
  // cipher once loses neither the original ID nor any summary boundary.
  let target = resolved()
  let request =
    model.ProviderRequest(..fixture.request_for(target), messages: [assistant])
  let body =
    responses.build_request(
      "https://example.test/v1",
      "canary",
      target,
      request,
    ).body
  let assert Ok(body) = json.parse(body) as "replayed request is JSON"
  let assert Ok([reasoning]) = wire.array_field(body, "input")
    as "one reasoning item is replayed"
  assert wire.string_field(reasoning, "id") == Ok("rs_fixture")
  assert wire.string_field(reasoning, "encrypted_content") == Ok(cipher)
  assert wire.array_field(reasoning, "summary") == Ok(parts)
}
