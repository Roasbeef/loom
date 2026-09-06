//// Origin tests pin durable compatibility, bounds, and transient projection.

import core/codec
import core/json
import core/message
import core/origin
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

pub fn attributed_messages_roundtrip_without_rewriting_content_test() {
  let content = [
    message.UserImage("image", "image/png"),
    message.UserText("hello", None),
  ]
  int.range(from: 1, to: 128, with: Nil, run: fn(_, size) {
    let assert Ok(author) =
      origin.validate(string.repeat("a", size), "Historical name")
      as "every allowed principal length is accepted"
    let original = message.UserMessage(content, 100, Some(author))
    assert codec.decode_message(codec.encode_message(original)) == Ok(original)
    let projected = origin.project(content, Some(author))
    let assert [message.UserText(prefix, None), ..tail] = projected
      as "one prefix precedes even an image-first message"
    assert tail == content
    assert string.contains(prefix, "Historical name")
    assert string.contains(prefix, "attribution data")
  })
}

pub fn historical_missing_and_null_origins_remain_anonymous_test() {
  let fields = [
    #("role", json.String("user")),
    #("content", json.String("old")),
    #("timestamp", json.Int(0)),
  ]
  let expected = message.UserMessage([message.UserText("old", None)], 0, None)
  assert codec.decode_message(json.Object(fields)) == Ok(expected)
  assert codec.decode_message(json.Object([#("origin", json.Null), ..fields]))
    == Ok(expected)
  assert origin.project([message.UserImage("image", "image/png")], None)
    == [message.UserImage("image", "image/png")]
}

pub fn malformed_present_origins_never_fall_back_to_anonymous_test() {
  let malformed = [
    json.Bool(False),
    json.Int(1),
    json.String("Alice"),
    json.Array([]),
    json.Object([]),
    json.Object([#("principal", json.Int(1)), #("name", json.String("Alice"))]),
  ]
  list.each(malformed, fn(value) {
    let encoded =
      json.Object([
        #("role", json.String("user")),
        #("content", json.String("hello")),
        #("timestamp", json.Int(1)),
        #("origin", value),
      ])
    assert result.is_error(codec.decode_message(encoded))
  })
}

pub fn origin_scalar_bounds_and_control_characters_test() {
  assert result.is_error(origin.validate("", "Alice"))
  assert result.is_error(origin.validate(string.repeat("a", 129), "Alice"))
  assert result.is_error(origin.validate("bad principal", "Alice"))
  assert result.is_error(origin.validate("é", "Alice"))
  assert result.is_error(origin.validate("alice", " \t "))
  assert result.is_ok(origin.validate("alice", string.repeat("é", 128)))
  assert result.is_error(origin.validate("alice", string.repeat("é", 129)))
  let controls =
    int.range(from: 0, to: 159, with: [], run: fn(values, code) {
      case code <= 31 || code >= 127 {
        True -> [code, ..values]
        False -> values
      }
    })
  list.each(controls, fn(code) {
    let assert Ok(point) = string.utf_codepoint(code)
      as "control range consists of valid scalar values"
    assert result.is_error(origin.validate(
      "alice",
      "Name" <> string.from_utf_codepoints([point]),
    ))
  })
}
