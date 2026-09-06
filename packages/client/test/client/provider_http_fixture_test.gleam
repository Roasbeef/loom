//// The loopback provider fixture is exercised through production HTTP, never
//// by injecting a provider transport. Negative requests pin the finite script
//// and latest-message oracle; teardown checks the actual listening socket.

import core/codec
import core/json
import core/message
import core/origin
import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/uri
import provider/http
import support/internal/ffi_daemon_socket as tcp
import support/internal/ffi_ws
import support/provider_http as peer
import weft
import weft/poll

fn body(prompts) {
  bodies(list.map(prompts, fn(prompt) { [message.UserText(prompt, None)] }))
}

fn bodies(turns) {
  json.to_string(
    json.Object([
      #("model", json.String("fixture")),
      #("stream", json.Bool(True)),
      #("system", json.String("a deterministic fixture system prompt")),
      #(
        "messages",
        json.Array(
          list.map(turns, fn(content) {
            json.Object([
              #("role", json.String("user")),
              #(
                "content",
                json.Array(list.map(content, codec.encode_user_block)),
              ),
            ])
          }),
        ),
      ),
    ]),
  )
}

pub fn provider_http_fixture_accepts_real_projected_author_block_test() {
  let projected =
    origin.project(
      [message.UserText("second", None)],
      Some(message.Origin("alice", "Alice")),
    )
  let #(url, report) =
    peer.with_server([peer.Exchange("second", "answer")], fn(url) {
      let #(status, _) =
        post(
          url,
          peer.dummy_key,
          bodies([
            [message.UserText("first", None)],
            projected,
          ]),
        )
      assert status == 200
      url
    })
  let assert Ok([observed]) = report
    as "attribution does not replace the actual prompt"
  assert observed.prompt == "second"
  closed(url)
}

pub fn provider_http_fixture_rejects_marker_in_extra_user_block_test() {
  let #(url, report) =
    peer.with_server([peer.Exchange("first", "answer")], fn(url) {
      let #(status, _) =
        post(
          url,
          peer.dummy_key,
          bodies([
            [message.UserText("first", None), message.UserText("wrong", None)],
          ]),
        )
      assert status == 400
      url
    })
  assert report == Error("unexpected text before latest user prompt")
  closed(url)
}

fn post(url, key, text) {
  let events = process.new_subject()
  let http.Transport(prepare_streaming:) = http.httpc_transport()
  let assert Ok(prepared) =
    prepare_streaming(
      http.HttpRequest(
        "POST",
        url <> "/v1/messages",
        [
          #("content-type", "application/json"),
          #("x-api-key", key),
        ],
        text,
      ),
      events,
    )
    as "the production HTTP request publishes its original owner before execution"
  let watch = process.monitor(http.owner(prepared.running))
  prepared.begin()
  let assert Ok(http.ResponseStatus(status, _)) = process.receive(events, 3000)
    as "the real HTTP peer supplies its status"
  let bytes = collect(events, [], 32)
  let assert Ok(process.ProcessDown(reason: process.Normal, ..)) =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down })
    |> process.selector_receive(3000)
    as "the original HTTP owner proves native request retirement"
  let assert Ok(text) = bit_array.to_string(bytes)
    as "fixture responses are UTF-8"
  #(status, text)
}

fn collect(events, chunks, remaining) {
  assert remaining > 0 as "the finite response stays within its chunk budget"
  case process.receive(events, 3000) {
    Ok(http.ResponseChunk(chunk)) ->
      collect(events, [chunk, ..chunks], remaining - 1)
    Ok(http.ResponseEnd) -> bit_array.concat(list.reverse(chunks))
    other ->
      panic as { "the HTTP response must finish: " <> string.inspect(other) }
  }
}

fn closed(url) {
  let assert Ok(parsed) = uri.parse(url) as "the fixture returns a loopback URL"
  let assert Some(port) = parsed.port as "the ephemeral port is explicit"
  let assert poll.Answered(Nil) =
    poll.until(within: 1000, every: 10, attempt: fn() {
      case
        tcp.connect(
          #(127, 0, 0, 1),
          port,
          [ffi_ws.Binary, ffi_ws.Active(False)],
          100,
        )
      {
        Error(_) -> poll.Done(Nil)
        Ok(socket) -> {
          let _ = ffi_ws.tcp_close(socket)
          poll.Retry
        }
      }
    })
    as "listener retirement closes the actual loopback socket"
}

pub fn provider_http_fixture_serves_ordered_sse_over_real_http_test() {
  let #(url, report) =
    peer.with_server(
      [
        peer.Exchange("first", "first-answer"),
        peer.Exchange("second", "second-answer"),
      ],
      fn(url) {
        let #(status, reply) = post(url, peer.dummy_key, body(["first"]))
        assert status == 200
        assert string.contains(reply, "event: message_start\n")
        assert string.contains(reply, "first-answer")
        assert string.ends_with(reply, "data: {\"type\":\"message_stop\"}\n\n")
        let #(status, reply) =
          post(url, peer.dummy_key, body(["first", "second"]))
        assert status == 200
        assert string.contains(reply, "second-answer")
        url
      },
    )
  let assert Ok([first, second]) = report
    as "both exact script steps are observed"
  assert first.model == "fixture"
  assert first.prompt == "first"
  assert second.prompt == "second"
  let assert Ok(expected) = json.parse(body(["first", "second"]))
    as "the expected request is JSON"
  assert second.body == expected
  closed(url)
}

pub fn provider_http_fixture_rejects_old_marker_instead_of_latest_text_test() {
  let #(url, report) =
    peer.with_server([peer.Exchange("first", "answer")], fn(url) {
      let #(status, reason) =
        post(url, peer.dummy_key, body(["first", "wrong"]))
      assert status == 400
      assert reason == "unexpected latest user text or extra request"
      url
    })
  assert report == Error("unexpected latest user text or extra request")
  closed(url)
}

pub fn provider_http_fixture_rejects_wrong_dummy_key_test() {
  let #(url, report) =
    peer.with_server([peer.Exchange("first", "answer")], fn(url) {
      let #(status, reason) = post(url, "wrong-key", body(["first"]))
      assert status == 401
      assert reason == "invalid dummy key"
      url
    })
  assert report == Error("invalid dummy key")
  closed(url)
}

pub fn provider_http_fixture_bounds_request_body_test() {
  let #(url, report) =
    peer.with_server([peer.Exchange("first", "answer")], fn(url) {
      let #(status, _) = post(url, peer.dummy_key, string.repeat("x", 262_145))
      assert status == 400
      url
    })
  assert report == Error("request body exceeds limit or is malformed")
  closed(url)
}

pub fn provider_http_fixture_reports_unconsumed_script_test() {
  let #(url, report) =
    peer.with_server([peer.Exchange("first", "answer")], fn(url) { url })
  assert report == Error("provider script was not exhausted")
  closed(url)
}

pub fn provider_http_fixture_cleans_listener_after_callback_failure_test() {
  let urls = process.new_subject()
  let outcomes =
    weft.new([
      fn() {
        let _ =
          peer.with_server([], fn(url) {
            process.send(urls, url)
            panic as "deliberate callback failure"
          })
        Ok(Nil)
      },
    ])
    |> weft.deadline(10_000)
    |> weft.start
  let assert [weft.Crashed(0, _)] = outcomes
    as "a failed callback is not reported as fixture success"
  let assert Ok(url) = process.receive(urls, 1000)
    as "the failure happened after actual listener startup"
  closed(url)
}
