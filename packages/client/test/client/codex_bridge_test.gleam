//// The bridge's narrow wire boundary: only a relative request with fixed
//// content headers enters the helper, outbound commands omit all credentials,
//// and frames retain their length/version fences across arbitrary chunks.

import client/codex_bridge as bridge
import gleam/bit_array
import gleam/option.{None, Some}
import gleam/string
import provider/http

fn subscription_request(headers: List(#(String, String))) -> http.HttpRequest {
  http.HttpRequest(method: "POST", url: "/responses", headers:, body: "{}")
}

pub fn request_accepts_only_fixed_relative_shape_test() {
  let headers = [
    #("content-type", "application/json"),
    #("accept", "text/event-stream"),
  ]
  assert bridge.validate_request(subscription_request(headers)) == Ok(Nil)
  assert bridge.validate_request(
      subscription_request([
        #("authorization", "Bearer canary"),
      ]),
    )
    != Ok(Nil)
  assert bridge.validate_request(http.HttpRequest(
      method: "POST",
      url: "https://api.openai.com/v1/responses",
      headers:,
      body: "{}",
    ))
    != Ok(Nil)
  assert bridge.validate_request(http.HttpRequest(
      method: "GET",
      url: "/responses",
      headers:,
      body: "{}",
    ))
    != Ok(Nil)
}

pub fn command_frame_omits_host_and_credential_fields_test() {
  let frame = bridge.request_command_json("loom-17", "work", "e30=")
  assert string.contains(frame, "\"profile\":\"work\"")
  assert string.contains(frame, "\"body_b64\":\"e30=\"")
  assert !string.contains(frame, "authorization")
  assert !string.contains(frame, "account_id")
  assert !string.contains(frame, "token")
  assert !string.contains(frame, "url")
  assert !string.contains(frame, "host")
}

pub fn frame_split_waits_for_full_body_and_preserves_tail_test() {
  let partial = <<0, 0, 0, 3, 0x61, 0x62>>
  assert bridge.split_frame(partial) == Ok(None)
  let complete = <<0, 0, 0, 3, 0x61, 0x62, 0x63, 0x7a>>
  assert bridge.split_frame(complete)
    == Ok(Some(#(bit_array.from_string("abc"), bit_array.from_string("z"))))
}

pub fn frame_split_refuses_zero_and_oversized_length_test() {
  assert bridge.split_frame(<<0, 0, 0, 0>>) == Error(Nil)
  assert bridge.split_frame(<<0, 64, 0, 1>>) == Error(Nil)
}

pub fn frame_decoder_refuses_version_mismatch_and_missing_id_test() {
  let valid =
    bit_array.from_string("{\"v\":1,\"id\":\"loom-1\",\"event\":\"end\"}")
  assert bridge.event_name(valid) == Ok("end")
  assert bridge.event_name(bit_array.from_string(
      "{\"v\":2,\"id\":\"loom-1\",\"event\":\"end\"}",
    ))
    == Error(Nil)
  assert bridge.event_name(bit_array.from_string("{\"v\":1,\"event\":\"end\"}"))
    == Error(Nil)
}
