//// The native admission boundary accepts only a relative request with fixed
//// content headers. A bearer enters the fixed public API request only after
//// authorization, while its response events retain no request credential.

import client/codex/transport
import gleam/erlang/process
import gleam/list
import provider/http
import weft

fn subscription_request(headers: List(#(String, String))) -> http.HttpRequest {
  http.HttpRequest(method: "POST", url: "/responses", headers:, body: "{}")
}

pub fn request_accepts_only_fixed_relative_shape_test() {
  let headers = [
    #("content-type", "application/json"),
    #("accept", "text/event-stream"),
  ]
  assert transport.validate_request(subscription_request(headers)) == Ok(Nil)
  assert transport.validate_request(
      subscription_request([
        #("authorization", "Bearer canary"),
      ]),
    )
    != Ok(Nil)
  assert transport.validate_request(http.HttpRequest(
      method: "POST",
      url: "https://api.openai.com/v1/responses",
      headers:,
      body: "{}",
    ))
    != Ok(Nil)
  assert transport.validate_request(http.HttpRequest(
      method: "GET",
      url: "/responses",
      headers:,
      body: "{}",
    ))
    != Ok(Nil)
}

pub fn native_transport_binds_bearer_to_fixed_origin_without_response_leak_test() {
  let headers = [
    #("content-type", "application/json"),
    #("accept", "text/event-stream"),
  ]
  let captured = process.new_subject()
  let events = process.new_subject()

  // The test retains the scripted owner's custody after the transport worker
  // returns. Its begin permit transfers the admitted request; a normal worker
  // exit must not cancel the fixture before it publishes the response events.
  let ready = process.new_subject()
  let owner =
    weft.new_prepared([
      weft.managed(fn(_) {
        let begin = process.new_subject()
        process.send(ready, begin)
        let #(request, target) = process.receive_forever(begin)
        process.send(captured, request)
        process.send(target, http.ResponseStatus(200, []))
        process.send(target, http.ResponseEnd)
        Ok(Nil)
      }),
    ])
    |> weft.start_witnessed
  let begin = process.receive_forever(ready)
  let inference =
    http.Transport(prepare_streaming: fn(request, target) {
      Ok(
        http.PreparedRequest(
          running: http.RunningRequest(weft.witness_pid(owner), fn() {
            weft.cancel_witnessed(owner)
          }),
          begin: fn() { process.send(begin, #(request, target)) },
        ),
      )
    })
  let assert Ok(prepared) =
    transport.prepare_streaming_with(
      fn(profile, _) {
        assert profile == "work"
        Ok("native-credential-canary")
      },
      inference,
      "work",
      subscription_request(headers),
      events,
    )
    as "The native operation is prepared without admitting inference."
  let monitor = process.monitor(prepared.running.owner)
  assert process.receive(captured, 0) == Error(Nil)
  prepared.begin()
  let assert Ok(request) = process.receive(captured, 1000)
    as "The captured request appears only after authorization and begin."
  assert request.url == "https://api.openai.com/v1/responses"
  assert request.body == "{}"
  assert request.headers
    == [#("authorization", "Bearer native-credential-canary"), ..headers]
  assert list.length(request.headers) == 3
  assert process.receive(events, 1000) == Ok(http.ResponseStatus(200, []))
  assert process.receive(events, 1000) == Ok(http.ResponseEnd)
  assert process.receive(events, 0) == Error(Nil)
  let assert Ok(down) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(1000)
    as "The native owner proves the original inference resource drained."
  assert down.reason == process.Normal
}
