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
import provider/adapter/anthropic
import provider/http
import provider/model
import provider/stream
import support/internal/ffi_daemon_socket as tcp
import support/internal/ffi_ws
import support/provider_http as peer
import weft
import weft/poll

fn result_body(id: String, text: String) -> String {
  let resolved =
    model.ResolvedModel("fixture", "fixture", model.ThinkingOff, 1000, 100)
  anthropic.build_request(
    base_url: "http://127.0.0.1",
    api_key: peer.dummy_key,
    resolved:,
    request: model.ProviderRequest(
      model.ForResolved(resolved),
      None,
      [
        message.ToolResultMessage(
          tool_call_id: id,
          tool_name: "bash",
          content: [message.ToolResultText(text, None)],
          details: None,
          usage: None,
          added_tool_names: None,
          is_error: False,
          timestamp: 0,
        ),
      ],
      [],
      None,
    ),
  ).body
}

fn result_block(
  id: json.JsonValue,
  content: List(json.JsonValue),
  status: json.JsonValue,
) -> json.JsonValue {
  json.Object([
    #("type", json.String("tool_result")),
    #("tool_use_id", id),
    #("content", json.Array(content)),
    #("is_error", status),
  ])
}

fn text_block(text: String) -> json.JsonValue {
  json.Object([#("type", json.String("text")), #("text", json.String(text))])
}

fn raw_body(turns: List(List(json.JsonValue))) -> String {
  json.to_string(
    json.Object([
      #("model", json.String("fixture")),
      #("stream", json.Bool(True)),
      #(
        "messages",
        json.Array(
          list.map(turns, fn(blocks) {
            json.Object([
              #("role", json.String("user")),
              #("content", json.Array(blocks)),
            ])
          }),
        ),
      ),
    ]),
  )
}

fn tool_step() -> peer.Exchange {
  peer.ToolUseExchange(
    "start A",
    "fixture-call",
    "bash",
    json.Object([#("command", json.String("printf done"))]),
  )
}

fn sse_values(text: String) -> List(json.JsonValue) {
  string.split(text, "\n")
  |> list.filter(fn(line) { string.starts_with(line, "data: ") })
  |> list.map(fn(line) {
    let assert Ok(value) = json.parse(string.drop_start(line, 6))
      as "every SSE data record is structured JSON"
    value
  })
}

pub fn provider_http_fixture_tool_interleaves_text_before_exact_result_test() {
  let #(url, report) =
    peer.with_server(
      [
        tool_step(),
        peer.Exchange("B turn", "B answer"),
        peer.ToolResultExchange("fixture-call", "done", "A finished"),
      ],
      fn(url) {
        let #(status, response) = post(url, peer.dummy_key, body(["start A"]))
        assert status == 200
        let machine =
          anthropic.response_machine(
            model.ResolvedModel(
              "fixture",
              "fixture",
              model.ThinkingOff,
              1000,
              100,
            ),
            now: 0,
          )
        let state = machine.on_status(machine.init, status, [])
        let #(_, decoded) =
          machine.on_chunk(state, bit_array.from_string(response))
        let settled =
          list.filter_map(decoded, fn(event) {
            case event {
              stream.Settled(message, _) -> Ok(stream.message(message))
              _ -> Error(Nil)
            }
          })
        let assert [message.AssistantMessage(content:, stop_reason:, ..)] =
          settled
          as "the real adapter settles exactly one assistant message"
        assert stop_reason == message.ToolUse
        assert content
          == [
            message.AssistantToolCall(message.ToolCall(
              "fixture-call",
              "bash",
              json.Object([#("command", json.String("printf done"))]),
              namespace: None,
              thought_signature: None,
            )),
          ]
        let events = sse_values(response)
        assert list.contains(
          events,
          json.Object([
            #("type", json.String("content_block_start")),
            #("index", json.Int(0)),
            #(
              "content_block",
              json.Object([
                #("type", json.String("tool_use")),
                #("id", json.String("fixture-call")),
                #("name", json.String("bash")),
                #("input", json.Object([])),
              ]),
            ),
          ]),
        )
        assert list.contains(
          events,
          json.Object([
            #("type", json.String("content_block_delta")),
            #("index", json.Int(0)),
            #(
              "delta",
              json.Object([
                #("type", json.String("input_json_delta")),
                #("partial_json", json.String("{\"command\":\"printf done\"}")),
              ]),
            ),
          ]),
        )
        assert list.contains(
          events,
          json.Object([
            #("type", json.String("message_delta")),
            #("delta", json.Object([#("stop_reason", json.String("tool_use"))])),
            #("usage", json.Object([#("output_tokens", json.Int(1))])),
          ]),
        )
        assert post(url, peer.dummy_key, body(["B turn"])).0 == 200
        let #(status, completed) =
          post(url, peer.dummy_key, result_body("fixture-call", "done"))
        assert status == 200
        assert list.contains(
          sse_values(completed),
          json.Object([
            #("type", json.String("content_block_delta")),
            #("index", json.Int(0)),
            #(
              "delta",
              json.Object([
                #("type", json.String("text_delta")),
                #("text", json.String("A finished")),
              ]),
            ),
          ]),
        )
        url
      },
    )
  let assert Ok(observed) = report
    as "all three independently ordered HTTP steps complete"
  assert list.map(observed, fn(request) { request.latest })
    == [
      peer.UserPrompt("start A"),
      peer.UserPrompt("B turn"),
      peer.SuccessfulToolResult("fixture-call", "done"),
    ]
  closed(url)
}

// Each malformed request owns a fresh finite script. A later correct request
// must still fail, proving a refused step never advances or heals the script.
fn refuses_result(request: String, expected_reason: String) -> Nil {
  let #(url, report) =
    peer.with_server(
      [tool_step(), peer.ToolResultExchange("fixture-call", "done", "finished")],
      fn(url) {
        assert post(url, peer.dummy_key, body(["start A"])).0 == 200
        let #(status, reason) = post(url, peer.dummy_key, request)
        assert status == 400
        assert reason == expected_reason
        assert post(url, peer.dummy_key, result_body("fixture-call", "done"))
          == #(400, reason)
        #(url, reason)
      },
    )
  assert report == Error(url.1)
  closed(url.0)
  Nil
}

pub fn provider_http_fixture_tool_result_requires_exact_nonempty_id_test() {
  list.each(
    [
      #(json.String("wrong"), "unexpected latest user text or extra request"),
      #(
        json.String(""),
        "tool result requires an ID and one successful content block",
      ),
      #(
        json.Null,
        "tool result requires an ID and one successful content block",
      ),
    ],
    fn(item) {
      refuses_result(
        raw_body([
          [result_block(item.0, [text_block("done")], json.Bool(False))],
        ]),
        item.1,
      )
    },
  )
  refuses_result(
    raw_body([
      [
        json.Object([
          #("type", json.String("tool_result")),
          #("content", json.Array([text_block("done")])),
          #("is_error", json.Bool(False)),
        ]),
      ],
    ]),
    "tool result requires an ID and one successful content block",
  )
}

pub fn provider_http_fixture_rejects_repeated_tool_result_test() {
  let #(url, report) =
    peer.with_server(
      [tool_step(), peer.ToolResultExchange("fixture-call", "done", "finished")],
      fn(url) {
        assert post(url, peer.dummy_key, body(["start A"])).0 == 200
        let request = result_body("fixture-call", "done")
        assert post(url, peer.dummy_key, request).0 == 200
        assert post(url, peer.dummy_key, request).0 == 400
        url
      },
    )
  assert report == Error("unexpected latest user text or extra request")
  closed(url)
}

pub fn provider_http_fixture_rejects_tool_result_only_in_history_test() {
  refuses_result(
    raw_body([
      [
        result_block(
          json.String("fixture-call"),
          [text_block("done")],
          json.Bool(False),
        ),
      ],
      [text_block("wrong latest")],
    ]),
    "unexpected latest user text or extra request",
  )
}

pub fn provider_http_fixture_rejects_error_wrong_text_and_extra_result_content_test() {
  let good =
    result_block(
      json.String("fixture-call"),
      [text_block("done")],
      json.Bool(False),
    )
  list.each(
    [
      #(
        [result_block(json.String("fixture-call"), [], json.Bool(False))],
        "tool result requires an ID and one successful content block",
      ),
      #(
        [
          result_block(
            json.String("fixture-call"),
            [text_block("")],
            json.Bool(False),
          ),
        ],
        "unexpected latest user text or extra request",
      ),
      #(
        [
          result_block(
            json.String("fixture-call"),
            [text_block(string.repeat("x", 4097))],
            json.Bool(False),
          ),
        ],
        "tool result exceeds fixture limit",
      ),
      #(
        [
          result_block(
            json.String("fixture-call"),
            [text_block("not done")],
            json.Bool(False),
          ),
        ],
        "unexpected latest user text or extra request",
      ),
      #(
        [
          result_block(
            json.String("fixture-call"),
            [text_block("done")],
            json.Bool(True),
          ),
        ],
        "tool result requires an ID and one successful content block",
      ),
      #(
        [
          result_block(
            json.String("fixture-call"),
            [text_block("done"), text_block("extra")],
            json.Bool(False),
          ),
        ],
        "tool result requires an ID and one successful content block",
      ),
      #(
        [
          result_block(
            json.String("fixture-call"),
            [json.Object([#("type", json.String("image"))])],
            json.Bool(False),
          ),
        ],
        "tool result requires one exact text block",
      ),
      #([good, good], "unexpected text before latest user prompt"),
      #(
        [good, text_block("extra")],
        "unexpected text before latest user prompt",
      ),
    ],
    fn(blocks) { refuses_result(raw_body([blocks.0]), blocks.1) },
  )
}

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
  assert observed.latest == peer.UserPrompt("second")
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
  assert first.latest == peer.UserPrompt("first")
  assert second.latest == peer.UserPrompt("second")
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
