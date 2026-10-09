//// Authentication HTTP refuses malformed framing and over-budget bodies before
//// decoding any secret-bearing JSON. Each scripted native owner stays alive
//// until cancellation so successful and failed collectors must retire it.

import client/codex/network
import gleam/bit_array
import gleam/erlang/process
import gleam/list
import provider/http
import weft

pub fn codex_auth_http_bounds_and_utf8_are_enforced_test() {
  assert fetch(
      [
        http.ResponseStatus(200, []),
        http.ResponseChunk(bit_array.from_string("abcd")),
        http.ResponseEnd,
      ],
      3,
    )
    == Error("response_too_large")
  assert fetch(
      [
        http.ResponseStatus(200, []),
        http.ResponseChunk(<<255>>),
        http.ResponseEnd,
      ],
      10,
    )
    == Error("invalid_http_response")
  assert fetch(
      [
        http.ResponseStatus(200, []),
        http.ResponseChunk(bit_array.from_string("ab")),
        http.ResponseChunk(bit_array.from_string("cd")),
        http.ResponseEnd,
      ],
      4,
    )
    == Ok(network.Response(200, "abcd"))
}

pub fn codex_auth_http_requires_one_status_before_body_test() {
  assert fetch([http.ResponseEnd], 10) == Error("invalid_http_response")
  assert fetch([http.ResponseChunk(<<1>>)], 10)
    == Error("invalid_http_response")
  assert fetch(
      [
        http.ResponseStatus(200, []),
        http.ResponseStatus(302, []),
      ],
      10,
    )
    == Error("invalid_http_response")
  assert fetch([http.RequestFailed("secret upstream diagnostic")], 10)
    == Error("request_transport_failed")
}

fn fetch(events: List(http.HttpEvent), limit: Int) {
  let retired = process.new_subject()

  // The test keeps custody while the fetch worker returns. Starting this
  // witnessed run from that worker would let its normal exit cancel the
  // fixture before the resource sends its graceful retirement acknowledgement.
  let ready = process.new_subject()
  let owner =
    weft.new_prepared([
      weft.managed(fn(_) {
        let cancel = process.new_subject()
        process.send(ready, cancel)
        process.receive_forever(cancel)
        process.send(retired, Nil)
        Ok(Nil)
      }),
    ])
    |> weft.start_witnessed
  let assert Ok(cancel) = process.receive(ready, 1000)
    as "The scripted native owner publishes its control subject."
  let transport =
    http.Transport(fn(_, target) {
      Ok(
        http.PreparedRequest(
          http.RunningRequest(weft.witness_pid(owner), fn() {
            process.send(cancel, Nil)
          }),
          fn() { list.each(events, fn(event) { process.send(target, event) }) },
        ),
      )
    })
  let answer =
    network.fetch_with(transport, http.HttpRequest("GET", "/", [], ""), limit)
  assert process.receive(retired, 1000) == Ok(Nil)
  answer
}
