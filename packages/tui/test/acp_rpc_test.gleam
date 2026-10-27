//// The JSON-RPC boundary of `loom acp`: every shape of line the client can
//// send decodes once into a variant or is refused with the error object
//// JSON-RPC prescribes, and nothing a peer writes can crash the decoder.

import core/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import tui/acp/rpc

fn refused(line: String) -> rpc.Refusal {
  let assert Error(refusal) = rpc.decode(line) as "this line must be refused"
  refusal
}

pub fn a_request_decodes_with_its_id_and_params_test() {
  let line =
    "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"session/prompt\",\"params\":{\"a\":1}}"

  assert rpc.decode(line)
    == Ok(rpc.Call(
      rpc.NumberId(7),
      "session/prompt",
      json.Object([#("a", json.Int(1))]),
    ))
}

pub fn a_string_id_is_kept_as_a_string_test() {
  let line = "{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"method\":\"initialize\"}"

  let assert Ok(rpc.Call(id:, params:, ..)) = rpc.decode(line)
  assert id == rpc.TextId("abc")
  assert params == json.Object([])
}

pub fn a_frame_without_an_id_is_a_notification_test() {
  let line =
    "{\"jsonrpc\":\"2.0\",\"method\":\"session/cancel\",\"params\":{\"sessionId\":\"s\"}}"

  let assert Ok(rpc.Notification(method:, ..)) = rpc.decode(line)
  assert method == "session/cancel"
}

pub fn a_result_and_an_error_are_both_replies_test() {
  let ok = "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"outcome\":1}}"
  let bad =
    "{\"jsonrpc\":\"2.0\",\"id\":4,\"error\":{\"code\":-32000,\"message\":\"no\"}}"

  let assert Ok(rpc.Reply(id: rpc.NumberId(3), outcome: Ok(_))) = rpc.decode(ok)
  let assert Ok(rpc.Reply(id: rpc.NumberId(4), outcome: Error(error))) =
    rpc.decode(bad)
  assert error == rpc.WireError(-32_000, "no", None)
}

pub fn text_that_is_not_json_is_a_parse_error_with_a_null_id_test() {
  let refusal = refused("{not json")

  assert refusal.id == None
  assert refusal.error.code == rpc.parse_error
}

pub fn a_batch_or_a_scalar_is_an_invalid_request_test() {
  assert refused("[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"x\"}]").error.code
    == rpc.invalid_request
  assert refused("42").error.code == rpc.invalid_request
  assert refused("null").error.code == rpc.invalid_request
}

pub fn the_wrong_version_marker_is_refused_under_the_frames_own_id_test() {
  let refusal = refused("{\"jsonrpc\":\"1.0\",\"id\":9,\"method\":\"x\"}")

  assert refusal.id == Some(rpc.NumberId(9))
  assert refusal.error.code == rpc.invalid_request
  let missing = refused("{\"id\":9,\"method\":\"x\"}")
  assert missing.error.code == rpc.invalid_request
}

pub fn an_id_that_cannot_be_echoed_is_refused_test() {
  let float = "{\"jsonrpc\":\"2.0\",\"id\":1.5,\"method\":\"x\"}"
  let object = "{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":\"x\"}"
  let null = "{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"x\"}"

  assert refused(float).error.code == rpc.invalid_request
  assert refused(object).error.code == rpc.invalid_request
  assert refused(null).error.code == rpc.invalid_request
  assert refused(float).id == None
}

pub fn a_method_that_is_not_text_is_refused_test() {
  let refusal = refused("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":5}")

  assert refusal.id == Some(rpc.NumberId(2))
  assert refusal.error.code == rpc.invalid_request
}

pub fn positional_params_are_invalid_params_test() {
  let refusal =
    refused("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"x\",\"params\":[1]}")

  assert refusal.id == Some(rpc.NumberId(2))
  assert refusal.error.code == rpc.invalid_params
}

pub fn a_frame_that_is_neither_request_nor_response_is_refused_test() {
  let refusal = refused("{\"jsonrpc\":\"2.0\",\"id\":2}")

  assert refusal.error.code == rpc.invalid_request
}

pub fn a_response_needs_an_id_and_a_well_formed_error_test() {
  assert refused("{\"jsonrpc\":\"2.0\",\"result\":{}}").error.code
    == rpc.invalid_request
  assert refused("{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":\"boom\"}").error.code
    == rpc.invalid_request
  assert refused("{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":1}}").error.code
    == rpc.invalid_request
}

pub fn a_frame_with_both_result_and_method_is_refused_test() {
  let line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"x\",\"result\":{}}"

  assert refused(line).error.code == rpc.invalid_request
}

pub fn an_oversized_line_is_refused_without_being_parsed_test() {
  let padding = string.repeat("a", rpc.max_frame_bytes)
  let line =
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"x\",\"params\":{\"p\":\""
    <> padding
    <> "\"}}"

  let refusal = refused(line)
  assert refusal.id == None
  assert refusal.error.code == rpc.invalid_request
  assert string.contains(refusal.error.message, "size")
}

pub fn a_line_at_the_limit_is_still_parsed_test() {
  let frame = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"x\"}"
  let spaces = string.repeat(" ", rpc.max_frame_bytes - string.byte_size(frame))

  let assert Ok(rpc.Call(..)) = rpc.decode(frame <> spaces)
}

pub fn duplicate_keys_and_deep_nesting_are_refused_not_crashed_test() {
  let duplicated = "{\"jsonrpc\":\"2.0\",\"id\":1,\"id\":2,\"method\":\"x\"}"
  let deep =
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"x\",\"params\":"
    <> string.repeat("[", 5000)
    <> string.repeat("]", 5000)
    <> "}"

  assert refused(duplicated).error.code == rpc.parse_error
  assert refused(deep).error.code == rpc.parse_error
}

pub fn encoded_frames_decode_back_to_themselves_test() {
  let params = json.Object([#("k", json.String("v"))])

  let assert Ok(rpc.Call(id: rpc.NumberId(5), method: "m", params: back)) =
    rpc.decode(rpc.encode_request(rpc.NumberId(5), "m", params))
  assert back == params

  let assert Ok(rpc.Notification("n", back)) =
    rpc.decode(rpc.encode_notification("n", params))
  assert back == params

  let assert Ok(rpc.Reply(rpc.TextId("x"), Ok(back))) =
    rpc.decode(rpc.encode_result(rpc.TextId("x"), params))
  assert back == params
}

pub fn an_error_response_round_trips_with_and_without_data_test() {
  let plain = rpc.error(rpc.method_not_found, "nope")
  let detailed =
    rpc.WireError(rpc.invalid_params, "bad", Some(json.String("why")))

  let assert Ok(rpc.Reply(_, Error(back))) =
    rpc.decode(rpc.encode_error(Some(rpc.NumberId(1)), plain))
  assert back == plain
  let assert Ok(rpc.Reply(_, Error(back))) =
    rpc.decode(rpc.encode_error(Some(rpc.NumberId(1)), detailed))
  assert back == detailed
}

pub fn an_error_without_an_id_encodes_a_null_id_test() {
  let frame = rpc.encode_error(None, rpc.error(rpc.parse_error, "x"))

  assert string.contains(frame, "\"id\":null")
  assert !list.is_empty(string.split(frame, "\"error\""))
}

pub fn no_encoded_frame_contains_a_newline_test() {
  let params = json.Object([#("text", json.String("line one\nline two"))])

  assert !string.contains(
    rpc.encode_notification("session/update", params),
    "\n",
  )
}
