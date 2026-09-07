//// The settled shape of a tool call's arguments, pinned at the one function
//// both dialects share. The adapter tests prove the stream survives a bad
//// call; these prove what the surviving call carries, including the case
//// where the text parses and is still not an object.

import core/json
import core/message
import gleam/list
import gleam/string
import provider/internal/wire

pub fn empty_text_is_the_empty_object_test() {
  assert wire.tool_arguments("") == json.Object([])
}

pub fn an_object_passes_through_untouched_test() {
  assert wire.tool_arguments("{\"path\":\"a\"}")
    == json.Object([#("path", json.String("a"))])
}

pub fn unparseable_text_is_carried_as_malformed_test() {
  let assert Ok(#(raw, reason)) =
    message.malformed_arguments_of(wire.tool_arguments("{\"path\":"))
  assert raw == "{\"path\":"
  assert string.contains(reason, "core/json.parse")
}

// A value that parses but is not an object is the model's failure in the
// same sense as unbalanced braces: nothing downstream can consume it, and
// the Anthropic and Gemini dialects refuse to replay a call whose input is
// `null` or a list. Each JSON kind is tried so a future arm cannot let one
// through by accident.
pub fn a_parsed_non_object_is_carried_as_malformed_test() {
  ["null", "[]", "\"x\"", "7", "1.5", "true"]
  |> list.each(fn(text) {
    let assert Ok(#(raw, reason)) =
      message.malformed_arguments_of(wire.tool_arguments(text))
    assert raw == text
    assert string.contains(reason, "must be a JSON object")
  })
}
