import core/json
import gleam/option.{None, Some}
import lsp/jsonrpc.{
  BadMessage, IdInt, IdString, MalformedMessage, Notification, Response,
  RpcError, ServerRequest,
}

// --- encoding ---------------------------------------------------------------

pub fn a_request_without_params_omits_the_member_test() {
  assert json.to_string(jsonrpc.request(IdInt(1), "shutdown", None))
    == "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"shutdown\"}"
}

pub fn a_request_with_params_carries_them_last_test() {
  let params = json.Object([#("x", json.Int(2))])

  assert json.to_string(jsonrpc.request(IdString("a"), "m", Some(params)))
    == "{\"jsonrpc\":\"2.0\",\"id\":\"a\",\"method\":\"m\",\"params\":{\"x\":2}}"
}

pub fn a_notification_carries_no_id_test() {
  assert json.to_string(jsonrpc.notification("exit", None))
    == "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}"
}

pub fn a_response_echoes_the_id_of_either_kind_test() {
  assert json.to_string(jsonrpc.response(IdInt(3), json.Null))
    == "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":null}"
  assert json.to_string(jsonrpc.response(IdString("s"), json.Bool(True)))
    == "{\"jsonrpc\":\"2.0\",\"id\":\"s\",\"result\":true}"
}

pub fn an_error_response_omits_what_is_absent_test() {
  let bare = RpcError(code: -32_601, message: "nope", data: None)
  let with_data = RpcError(..bare, data: Some(json.String("why")))

  assert json.to_string(jsonrpc.error_response(Some(IdInt(3)), bare))
    == "{\"jsonrpc\":\"2.0\",\"id\":3,\"error\":{\"code\":-32601,\"message\":\"nope\"}}"
  assert json.to_string(jsonrpc.error_response(None, with_data))
    == "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32601,\"message\":\"nope\",\"data\":\"why\"}}"
}

// --- round trips ------------------------------------------------------------

pub fn an_encoded_request_decodes_as_a_server_request_test() {
  let params = json.Array([json.Int(1)])
  let text = json.to_string(jsonrpc.request(IdInt(7), "ping", Some(params)))

  assert jsonrpc.decode(text)
    == Ok(ServerRequest(IdInt(7), "ping", Some(params)))
}

pub fn an_encoded_notification_decodes_as_a_notification_test() {
  let text = json.to_string(jsonrpc.notification("note", None))

  assert jsonrpc.decode(text) == Ok(Notification("note", None))
}

pub fn an_encoded_response_decodes_with_its_result_test() {
  let value = json.Object([#("ok", json.Bool(True))])
  let text = json.to_string(jsonrpc.response(IdString("q"), value))

  assert jsonrpc.decode(text) == Ok(Response(IdString("q"), Ok(value)))
}

pub fn an_encoded_error_decodes_with_its_data_test() {
  let error =
    RpcError(code: -32_800, message: "cancelled", data: Some(json.Null))
  let text = json.to_string(jsonrpc.error_response(Some(IdInt(4)), error))

  assert jsonrpc.decode(text) == Ok(Response(IdInt(4), Error(error)))
}

pub fn unknown_extra_fields_are_ignored_test() {
  let text = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":0,\"extra\":[1,2]}"

  assert jsonrpc.decode(text) == Ok(Response(IdInt(1), Ok(json.Int(0))))
}

// --- refusals ---------------------------------------------------------------

pub fn text_that_is_not_json_is_malformed_test() {
  let assert Error(MalformedMessage(_)) = jsonrpc.decode("{\"jsonrpc\":")
  let assert Error(MalformedMessage(_)) = jsonrpc.decode("")
}

pub fn a_message_that_is_not_an_object_is_refused_test() {
  let assert Error(BadMessage(_)) = jsonrpc.decode("[]")
  let assert Error(BadMessage(_)) = jsonrpc.decode("7")
}

pub fn a_wrong_or_missing_version_is_refused_test() {
  let assert Error(BadMessage(_)) = jsonrpc.decode("{\"id\":1,\"result\":0}")
  let assert Error(BadMessage(_)) =
    jsonrpc.decode("{\"jsonrpc\":\"1.0\",\"id\":1,\"result\":0}")
  let assert Error(BadMessage(_)) =
    jsonrpc.decode("{\"jsonrpc\":2,\"id\":1,\"result\":0}")
}

pub fn an_id_that_is_neither_integer_nor_string_is_refused_test() {
  let assert Error(BadMessage(_)) =
    jsonrpc.decode("{\"jsonrpc\":\"2.0\",\"id\":1.5,\"result\":0}")
  let assert Error(BadMessage(_)) =
    jsonrpc.decode("{\"jsonrpc\":\"2.0\",\"id\":null,\"result\":0}")
  let assert Error(BadMessage(_)) =
    jsonrpc.decode("{\"jsonrpc\":\"2.0\",\"id\":[1],\"method\":\"m\"}")
}

pub fn a_response_needs_exactly_one_of_result_and_error_test() {
  let assert Error(BadMessage(_)) =
    jsonrpc.decode("{\"jsonrpc\":\"2.0\",\"id\":1}")
  let assert Error(BadMessage(_)) =
    jsonrpc.decode(
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":0,\"error\":{\"code\":1,\"message\":\"m\"}}",
    )
}

pub fn a_response_without_an_id_is_refused_test() {
  let assert Error(BadMessage(_)) =
    jsonrpc.decode(
      "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32700,\"message\":\"parse\"}}",
    )
}

pub fn a_call_carrying_an_outcome_is_refused_test() {
  let assert Error(BadMessage(_)) =
    jsonrpc.decode("{\"jsonrpc\":\"2.0\",\"method\":\"m\",\"result\":0}")
  let assert Error(BadMessage(_)) =
    jsonrpc.decode(
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"m\",\"error\":{\"code\":1,\"message\":\"m\"}}",
    )
}

pub fn a_method_that_is_not_a_string_is_refused_test() {
  let assert Error(BadMessage(_)) =
    jsonrpc.decode("{\"jsonrpc\":\"2.0\",\"method\":4}")
}

pub fn a_malformed_error_member_is_refused_test() {
  let assert Error(BadMessage(_)) =
    jsonrpc.decode("{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":\"boom\"}")
  let assert Error(BadMessage(_)) =
    jsonrpc.decode(
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":\"1\",\"message\":\"m\"}}",
    )
  let assert Error(BadMessage(_)) =
    jsonrpc.decode(
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":1,\"message\":2}}",
    )
}
