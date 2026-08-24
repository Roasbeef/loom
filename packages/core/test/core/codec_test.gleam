import core/clock
import core/codec
import core/corruption
import core/entry
import core/ids
import core/json
import core/message
import core/register
import gleam/list
import gleam/option.{None, Some}
import support/generate

// --- roundtrip properties -----------------------------------------------

pub fn usage_roundtrip_property_test() {
  property(generate.seed(41), 200, generate.usage, fn(usage) {
    assert codec.decode_usage(codec.encode_usage(usage)) == Ok(usage)
  })
}

pub fn message_roundtrip_property_test() {
  property(generate.seed(42), 200, generate.agent_message, fn(message) {
    assert codec.decode_message(codec.encode_message(message)) == Ok(message)
  })
}

pub fn entry_roundtrip_property_test() {
  property(generate.seed(43), 200, generate.entry, fn(entry) {
    assert codec.decode_entry(codec.encode_entry(entry)) == Ok(entry)
  })
}

pub fn usage_row_roundtrip_property_test() {
  property(generate.seed(44), 200, generate.usage_row, fn(row) {
    assert codec.decode_usage_row(codec.encode_usage_row(row)) == Ok(row)
  })
}

pub fn register_value_roundtrip_property_test() {
  property(
    generate.seed(45),
    200,
    fn(seed) { generate.json_value(seed, 3) },
    fn(payload) {
      let value = register.value(payload)
      assert codec.decode_register_value(codec.encode_register_value(value))
        == Ok(value)
    },
  )
}

pub fn corruption_report_roundtrip_test() {
  property(generate.seed(46), 50, generate.small_string, fn(text) {
    let report =
      corruption.report(
        at: "boundary/" <> text,
        on: "subject " <> text,
        expected: "expected " <> text,
        context: text,
      )
    assert codec.decode_corruption_report(codec.encode_corruption_report(report))
      == Ok(report)
  })
}

// Entries survive the full durability pipeline: value -> Json -> text ->
// Json -> value.
pub fn entry_text_pipeline_property_test() {
  property(generate.seed(47), 200, generate.entry, fn(entry) {
    let text = json.to_string(codec.encode_entry(entry))
    let assert Ok(parsed) = json.parse(text)
    assert codec.decode_entry(parsed) == Ok(entry)
  })
}

fn property(
  seed: generate.Seed,
  remaining: Int,
  generator: fn(generate.Seed) -> #(a, generate.Seed),
  check: fn(a) -> b,
) -> Nil {
  case remaining <= 0 {
    True -> Nil
    False -> {
      let #(value, seed) = generator(seed)
      check(value)
      property(seed, remaining - 1, generator, check)
    }
  }
}

// --- wire-shape pins ----------------------------------------------------

fn sample_usage() -> message.Usage {
  message.Usage(
    input: 10,
    output: 20,
    cache_read: 1,
    cache_write: 2,
    cache_write_1h: None,
    reasoning: Some(5),
    total_tokens: 30,
    cost: message.UsageCost(
      input: 0.1,
      output: 0.2,
      cache_read: 0.01,
      cache_write: 0.02,
      total: 0.33,
    ),
  )
}

pub fn usage_uses_pi_field_names_test() {
  let assert json.Object(fields) = codec.encode_usage(sample_usage())
  let names = list.map(fields, fn(field) { field.0 })
  assert names
    == [
      "input",
      "output",
      "cacheRead",
      "cacheWrite",
      "reasoning",
      "totalTokens",
      "cost",
    ]
}

pub fn user_message_accepts_bare_string_content_test() {
  let assert Ok(json.Object(fields)) =
    json.parse("{\"role\":\"user\",\"content\":\"hi\",\"timestamp\":5}")
  assert codec.decode_message(json.Object(fields))
    == Ok(message.UserMessage(
      content: [message.UserText(text: "hi", text_signature: None)],
      timestamp: 5,
    ))
}

pub fn stop_reason_error_maps_to_errored_test() {
  let assistant =
    message.AssistantMessage(
      content: [],
      api: "a",
      provider: "p",
      model: "m",
      response_model: None,
      response_id: None,
      diagnostics: None,
      usage: sample_usage(),
      stop_reason: message.Errored,
      deferred: None,
      error_message: Some("boom"),
      raw_stop_reason: None,
      end_turn: None,
      timestamp: 1,
    )
  let assert json.Object(fields) = codec.encode_message(assistant)
  assert list.key_find(fields, "stopReason") == Ok(json.String("error"))
  assert codec.decode_message(json.Object(fields)) == Ok(assistant)
}

pub fn message_entry_terminate_defaults_to_false_test() {
  let #(id, _) = ids.mint_entry(ids.generator(clock.fixed(at: 1), seed: 1))
  let entry_value =
    entry.MessageEntry(
      id:,
      parent: None,
      seq: 3,
      ts: 9,
      message: message.UserMessage(content: [], timestamp: 9),
      terminate: False,
    )
  let assert json.Object(fields) = codec.encode_entry(entry_value)
  // terminate is omitted when false, matching pi's `terminate?: true`.
  assert list.key_find(fields, "terminate") == Error(Nil)
  assert codec.decode_entry(json.Object(fields)) == Ok(entry_value)
}

pub fn custom_entry_data_null_is_distinct_from_absent_test() {
  let #(id, _) = ids.mint_entry(ids.generator(clock.fixed(at: 1), seed: 2))
  let absent =
    entry.CustomEntry(
      id:,
      parent: None,
      seq: 0,
      ts: 0,
      custom_type: "marker",
      data: None,
    )
  let null = entry.CustomEntry(..absent, data: Some(json.Null))
  let assert Ok(decoded_absent) = codec.decode_entry(codec.encode_entry(absent))
  let assert Ok(decoded_null) = codec.decode_entry(codec.encode_entry(null))
  assert decoded_absent == absent
  assert decoded_null == null
  assert decoded_absent != decoded_null
}

// --- adversarial decodes ------------------------------------------------

pub fn decode_rejects_wrong_shapes_test() {
  let corpus = [
    json.Null,
    json.Int(3),
    json.String("nope"),
    json.Array([]),
    // missing everything
    json.Object([]),
    // unknown role
    json.Object([#("role", json.String("oracle"))]),
    // role of the wrong type
    json.Object([#("role", json.Int(1))]),
    // user message with wrong content type
    json.Object([
      #("role", json.String("user")),
      #("content", json.Int(1)),
      #("timestamp", json.Int(0)),
    ]),
    // user message with a bad block kind
    json.Object([
      #("role", json.String("user")),
      #(
        "content",
        json.Array([json.Object([#("type", json.String("thinking"))])]),
      ),
      #("timestamp", json.Int(0)),
    ]),
    // timestamp as string
    json.Object([
      #("role", json.String("user")),
      #("content", json.Array([])),
      #("timestamp", json.String("now")),
    ]),
  ]
  list.each(corpus, fn(value) {
    let assert Error(_report) = codec.decode_message(value)
  })
}

pub fn decode_entry_rejects_bad_rows_test() {
  let valid_id = json.String("01930000-0000-7000-8000-000000000000")
  let base = [
    #("id", valid_id),
    #("parentId", json.Null),
    #("seq", json.Int(1)),
    #("timestamp", json.Int(2)),
  ]
  let corpus = [
    // not an object
    json.Array([]),
    // missing type
    json.Object(base),
    // unknown type
    json.Object(list.append(base, [#("type", json.String("wormhole"))])),
    // malformed id
    json.Object([
      #("id", json.String("not-a-uuid")),
      #("parentId", json.Null),
      #("seq", json.Int(1)),
      #("timestamp", json.Int(2)),
      #("type", json.String("custom")),
      #("customType", json.String("x")),
    ]),
    // parentId of the wrong type
    json.Object([
      #("id", valid_id),
      #("parentId", json.Int(4)),
      #("seq", json.Int(1)),
      #("timestamp", json.Int(2)),
      #("type", json.String("custom")),
      #("customType", json.String("x")),
    ]),
    // message entry without a message
    json.Object(list.append(base, [#("type", json.String("message"))])),
    // compaction with retainedTail of the wrong type
    json.Object(
      list.append(base, [
        #("type", json.String("compaction")),
        #("summary", json.String("s")),
        #("retainedTail", json.String("nope")),
        #("tokensBefore", json.Int(1)),
        #("fromHook", json.Bool(False)),
      ]),
    ),
    // branch summary with a null fromId
    json.Object(
      list.append(base, [
        #("type", json.String("branch_summary")),
        #("fromId", json.Null),
        #("summary", json.String("s")),
        #("fromHook", json.Bool(False)),
      ]),
    ),
  ]
  list.each(corpus, fn(value) {
    let assert Error(_report) = codec.decode_entry(value)
  })
}

pub fn decode_usage_rejects_wrong_field_types_test() {
  let assert json.Object(fields) = codec.encode_usage(sample_usage())
  let corpus = [
    json.Object(list.key_set(fields, "input", json.String("ten"))),
    json.Object(list.key_set(fields, "cost", json.Array([]))),
    json.Object(list.key_set(fields, "totalTokens", json.Float(1.5))),
    json.Object(list.key_set(fields, "reasoning", json.Bool(True))),
  ]
  list.each(corpus, fn(value) {
    let assert Error(_report) = codec.decode_usage(value)
  })
}

pub fn decode_usage_row_rejects_bad_ids_test() {
  let assert json.Object(fields) = codec.encode_usage_row(sample_usage_row())
  let corrupted = json.Object(list.key_set(fields, "id", json.String("xyz")))
  let assert Error(_report) = codec.decode_usage_row(corrupted)
}

fn sample_usage_row() -> entry.UsageRow {
  let #(id, _) = ids.mint_usage(ids.generator(clock.fixed(at: 1), seed: 5))
  entry.UsageRow(
    id:,
    seq: 1,
    entry_id: None,
    adjustment: False,
    usage: sample_usage(),
    details: None,
  )
}
