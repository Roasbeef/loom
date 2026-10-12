//// The ledger's outcome codec: what goes in comes back, and what is not an
//// outcome is a report, never a different outcome.

import client/remote/codec
import client/remote/protocol
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

pub fn an_execution_value_round_trips_as_its_own_kind_test() {
  let value = json.Object([#("status", json.String("completed"))])
  let bytes = codec.encode_execution(value)
  assert codec.decode_stored(bytes) == Ok(codec.StoredExecution(value))
  assert codec.decode_stored(codec.encode_outcome(ToolFailed(reason: "no")))
    == Ok(codec.StoredOutcome(ToolFailed(reason: "no")))
}

pub fn an_execution_value_is_never_read_as_a_tool_outcome_test() {
  // A tool call answered from an execution's row would hand the model a
  // program's value as the call's result, so the outcome reader refuses it.
  let assert Error(report) =
    codec.decode_outcome(codec.encode_execution(json.Int(1)))
    as "an execution value is not a tool outcome"
  assert report.expected == "completed or failed"
}

pub fn an_execution_key_names_its_execution_and_a_call_key_none_test() {
  let key = protocol.Key("s", "op", "async/ab12", 0)
  assert protocol.execution_id(key) == Ok("ab12")
  assert protocol.execution_id(protocol.Key(..key, step: "turn-1:tools"))
    == Error(Nil)
}
