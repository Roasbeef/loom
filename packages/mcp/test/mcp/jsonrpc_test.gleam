import core/json
import gleam/option.{None, Some}
import mcp/jsonrpc

// --- encoding ---------------------------------------------------------------

pub fn request_with_params_test() {
  let encoded =
    jsonrpc.request(
      jsonrpc.IdInt(1),
      "tools/call",
      Some(json.Object([#("name", json.String("echo"))])),
    )
  assert json.to_string(encoded)
    == "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\","
    <> "\"params\":{\"name\":\"echo\"}}"
}

pub fn request_without_params_omits_the_field_test() {
  assert json.to_string(jsonrpc.request(jsonrpc.IdInt(7), "ping", None))
    == "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"ping\"}"
}

pub fn request_with_string_id_test() {
  assert json.to_string(jsonrpc.request(jsonrpc.IdString("a-1"), "ping", None))
    == "{\"jsonrpc\":\"2.0\",\"id\":\"a-1\",\"method\":\"ping\"}"
}

pub fn notification_test() {
  assert json.to_string(jsonrpc.notification("notifications/initialized", None))
    == "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"
}

pub fn notification_with_params_test() {
  let encoded =
    jsonrpc.notification("note", Some(json.Object([#("k", json.Int(1))])))
  assert json.to_string(encoded)
    == "{\"jsonrpc\":\"2.0\",\"method\":\"note\",\"params\":{\"k\":1}}"
}

// --- decoding: the three inbound shapes ---------------------------------------

pub fn decode_result_response_test() {
  assert jsonrpc.decode("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"a\":1}}")
    == Ok(jsonrpc.Response(
      id: jsonrpc.IdInt(1),
      outcome: Ok(json.Object([#("a", json.Int(1))])),
    ))
}

pub fn decode_string_id_response_test() {
  assert jsonrpc.decode("{\"jsonrpc\":\"2.0\",\"id\":\"x\",\"result\":null}")
    == Ok(jsonrpc.Response(id: jsonrpc.IdString("x"), outcome: Ok(json.Null)))
}

pub fn decode_huge_id_test() {
  // JSON ints are arbitrary precision; an id past 2^64 still correlates.
  let huge = "123456789012345678901234567890"
  let assert Ok(jsonrpc.Response(id: jsonrpc.IdInt(id), ..)) =
    jsonrpc.decode("{\"jsonrpc\":\"2.0\",\"id\":" <> huge <> ",\"result\":1}")
  assert id > 1_000_000_000_000_000_000
}

pub fn decode_error_response_test() {
  assert jsonrpc.decode(
      "{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":"
      <> "{\"code\":-32601,\"message\":\"method not found\"}}",
    )
    == Ok(jsonrpc.Response(
      id: jsonrpc.IdInt(2),
      outcome: Error(jsonrpc.RpcError(
        code: -32_601,
        message: "method not found",
        data: None,
      )),
    ))
}

pub fn decode_error_with_data_test() {
  let assert Ok(jsonrpc.Response(outcome: Error(error), ..)) =
    jsonrpc.decode(
      "{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":"
      <> "{\"code\":1,\"message\":\"m\",\"data\":[1,2]}}",
    )
  assert error.data == Some(json.Array([json.Int(1), json.Int(2)]))
}

pub fn decode_server_request_test() {
  assert jsonrpc.decode(
      "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"roots/list\",\"params\":{}}",
    )
    == Ok(jsonrpc.ServerRequest(
      id: jsonrpc.IdInt(9),
      method: "roots/list",
      params: Some(json.Object([])),
    ))
}

pub fn decode_server_request_without_params_test() {
  assert jsonrpc.decode("{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"ping\"}")
    == Ok(jsonrpc.ServerRequest(
      id: jsonrpc.IdInt(9),
      method: "ping",
      params: None,
    ))
}

pub fn decode_notification_test() {
  assert jsonrpc.decode(
      "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}",
    )
    == Ok(jsonrpc.Notification(
      method: "notifications/tools/list_changed",
      params: None,
    ))
}

pub fn round_trip_request_test() {
  let encoded =
    json.to_string(jsonrpc.request(
      jsonrpc.IdInt(42),
      "tools/list",
      Some(json.Object([#("cursor", json.String("c"))])),
    ))
  assert jsonrpc.decode(encoded)
    == Ok(jsonrpc.ServerRequest(
      id: jsonrpc.IdInt(42),
      method: "tools/list",
      params: Some(json.Object([#("cursor", json.String("c"))])),
    ))
}

pub fn round_trip_notification_test() {
  let encoded = json.to_string(jsonrpc.notification("n", None))
  assert jsonrpc.decode(encoded)
    == Ok(jsonrpc.Notification(method: "n", params: None))
}

// --- decoding: tolerance ------------------------------------------------------

pub fn unknown_extra_fields_are_ignored_test() {
  assert jsonrpc.decode(
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":1,\"_meta\":{\"x\":true}}",
    )
    == Ok(jsonrpc.Response(id: jsonrpc.IdInt(1), outcome: Ok(json.Int(1))))
}

pub fn unknown_extra_error_fields_are_ignored_test() {
  let assert Ok(jsonrpc.Response(outcome: Error(error), ..)) =
    jsonrpc.decode(
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":"
      <> "{\"code\":1,\"message\":\"m\",\"extra\":\"ignored\"}}",
    )
  assert error == jsonrpc.RpcError(code: 1, message: "m", data: None)
}

// --- decoding: hostile input settles as faults --------------------------------

pub fn not_json_is_malformed_test() {
  let assert Error(jsonrpc.MalformedMessage(_)) = jsonrpc.decode("{nope")
}

pub fn non_object_message_is_refused_test() {
  let assert Error(jsonrpc.BadMessage(_)) = jsonrpc.decode("[1,2,3]")
}

pub fn missing_jsonrpc_field_is_refused_test() {
  let assert Error(jsonrpc.BadMessage(reason)) =
    jsonrpc.decode("{\"id\":1,\"result\":1}")
  assert reason == "a \"jsonrpc\" field carrying \"2.0\""
}

pub fn wrong_jsonrpc_version_is_refused_test() {
  let assert Error(jsonrpc.BadMessage(_)) =
    jsonrpc.decode("{\"jsonrpc\":\"1.0\",\"id\":1,\"result\":1}")
}

pub fn non_string_jsonrpc_field_is_refused_test() {
  let assert Error(jsonrpc.BadMessage(_)) =
    jsonrpc.decode("{\"jsonrpc\":2,\"id\":1,\"result\":1}")
}

pub fn non_string_method_is_refused_test() {
  let assert Error(jsonrpc.BadMessage(reason)) =
    jsonrpc.decode("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":7}")
  assert reason == "a string method name"
}

pub fn method_with_result_is_refused_test() {
  let assert Error(jsonrpc.BadMessage(_)) =
    jsonrpc.decode(
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"m\",\"result\":1}",
    )
}

pub fn method_with_error_is_refused_test() {
  let assert Error(jsonrpc.BadMessage(_)) =
    jsonrpc.decode(
      "{\"jsonrpc\":\"2.0\",\"method\":\"m\",\"error\":"
      <> "{\"code\":1,\"message\":\"m\"}}",
    )
}

pub fn response_without_id_is_refused_test() {
  let assert Error(jsonrpc.BadMessage(reason)) =
    jsonrpc.decode("{\"jsonrpc\":\"2.0\",\"result\":1}")
  assert reason == "an id on a response"
}

pub fn float_id_is_refused_test() {
  let assert Error(jsonrpc.BadMessage(reason)) =
    jsonrpc.decode("{\"jsonrpc\":\"2.0\",\"id\":1.5,\"result\":1}")
  assert reason == "an integer or string id"
}

pub fn null_id_is_refused_test() {
  let assert Error(jsonrpc.BadMessage(_)) =
    jsonrpc.decode(
      "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":"
      <> "{\"code\":-32700,\"message\":\"parse error\"}}",
    )
}

pub fn float_id_on_server_request_is_refused_test() {
  let assert Error(jsonrpc.BadMessage(_)) =
    jsonrpc.decode("{\"jsonrpc\":\"2.0\",\"id\":1.5,\"method\":\"m\"}")
}

pub fn result_and_error_together_are_refused_test() {
  let assert Error(jsonrpc.BadMessage(reason)) =
    jsonrpc.decode(
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":1,\"error\":"
      <> "{\"code\":1,\"message\":\"m\"}}",
    )
  assert reason == "exactly one of result and error, not both"
}

pub fn neither_result_nor_error_is_refused_test() {
  let assert Error(jsonrpc.BadMessage(reason)) =
    jsonrpc.decode("{\"jsonrpc\":\"2.0\",\"id\":1}")
  assert reason == "exactly one of result and error, not neither"
}

pub fn non_object_error_member_is_refused_test() {
  let assert Error(jsonrpc.BadMessage(_)) =
    jsonrpc.decode("{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":\"boom\"}")
}

pub fn string_error_code_is_refused_test() {
  let assert Error(jsonrpc.BadMessage(reason)) =
    jsonrpc.decode(
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":"
      <> "{\"code\":\"1\",\"message\":\"m\"}}",
    )
  assert reason == "an integer error code"
}

pub fn missing_error_message_is_refused_test() {
  let assert Error(jsonrpc.BadMessage(reason)) =
    jsonrpc.decode("{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":1}}")
  assert reason == "a string error message"
}

pub fn non_string_error_message_is_refused_test() {
  let assert Error(jsonrpc.BadMessage(_)) =
    jsonrpc.decode(
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":1,\"message\":9}}",
    )
}
