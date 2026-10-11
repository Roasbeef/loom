//// The ledger's outcome codec: what goes in comes back, and what is not an
//// outcome is a report, never a different outcome.

import client/remote/codec
import core/json
import core/message
import gleam/bit_array
import gleam/option.{None, Some}
import runtime/effects.{ToolCompleted, ToolFailed}

fn result_message() -> message.AgentMessage {
  message.ToolResultMessage(
    tool_call_id: "call_1",
    tool_name: "bash",
    content: [
      message.ToolResultText(
        text: "hello\n\"quoted\" \u{00e9}",
        text_signature: None,
      ),
      message.ToolResultImage(data: "AAAA", mime_type: "image/png"),
    ],
    details: Some(json.Object([#("exit", json.Int(0))])),
    usage: None,
    added_tool_names: Some(["fs_read"]),
    is_error: False,
    timestamp: 1_700_000_000_000,
  )
}

pub fn a_completed_outcome_round_trips_test() {
  let completed = ToolCompleted(result: result_message(), terminate: True)
  assert codec.decode_outcome(codec.encode_outcome(completed)) == Ok(completed)
}

pub fn a_failed_outcome_round_trips_test() {
  let failed = ToolFailed(reason: "the helper died")
  assert codec.decode_outcome(codec.encode_outcome(failed)) == Ok(failed)
}

pub fn bytes_that_are_not_an_outcome_are_reports_test() {
  let refused = fn(bytes: BitArray) {
    let assert Error(_report) = codec.decode_outcome(bytes)
      as "Damaged bytes must be refused."
    Nil
  }

  // Not UTF-8, not JSON, not an object, and objects of the wrong shape.
  refused(<<255, 254, 253>>)
  refused(bit_array.from_string("not json"))
  refused(bit_array.from_string("[1]"))
  refused(bit_array.from_string("{}"))
  refused(bit_array.from_string("{\"kind\":\"unknown\"}"))
  refused(bit_array.from_string("{\"kind\":\"failed\"}"))
  refused(bit_array.from_string("{\"kind\":\"failed\",\"reason\":7}"))
  refused(bit_array.from_string("{\"kind\":\"completed\",\"terminate\":true}"))
  refused(bit_array.from_string(
    "{\"kind\":\"completed\",\"result\":{\"role\":\"nobody\"},\"terminate\":false}",
  ))
  refused(bit_array.from_string(
    "{\"kind\":\"completed\",\"result\":{\"role\":\"user\",\"content\":[],\"timestamp\":1},\"terminate\":\"yes\"}",
  ))
}
