//// The seat gauge command end to end over scripted HTTP: output shapes, the
//// exit status, bounded reads, and the property that no seat token reaches
//// anything the command writes, whatever the provider answers.

import client/seat_usage
import client/seat_usage_cli
import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/string
import provider/http
import weft

const now_ms = 1_794_355_200_000

const codex_open =
  "{\"plan_type\":\"plus\",\"rate_limit\":{\"allowed\":true,\"limit_reached\":false,\"primary_window\":{\"used_percent\":42,\"limit_window_seconds\":18000,\"reset_after_seconds\":100,\"reset_at\":1794434400}}}"

const claude_spent =
  "{\"five_hour\":{\"utilization\":100,\"resets_at\":\"2026-11-11T22:00:00Z\"}}"

const listing = "{\"models\":[{\"slug\":\"gpt-x\",\"visibility\":\"list\"}]}"

fn seat_line(label: String, provider: String, token: String) -> String {
  "{\"label\":\""
  <> label
  <> "\",\"provider\":\""
  <> provider
  <> "\",\"token\":\""
  <> token
  <> "\"}"
}

fn input(lines: List(String)) -> List(#(Int, seat_usage.RawLine)) {
  list.index_map(lines, fn(line, index) { #(index + 1, seat_usage.Raw(line)) })
}

/// A transport that answers each request from `route`, and parks a witnessed
/// owner for it as the production transport does.
fn transport(route: fn(http.HttpRequest) -> List(http.HttpEvent)) {
  http.Transport(fn(request, target) {
    let ready = process.new_subject()
    let owner =
      weft.new_prepared([
        weft.managed(fn(_) {
          let cancel = process.new_subject()
          process.send(ready, cancel)
          process.receive_forever(cancel)
          Ok(Nil)
        }),
      ])
      |> weft.start_witnessed
    let assert Ok(cancel) = process.receive(ready, 1000)
      as "The scripted owner publishes its control subject."

    Ok(
      http.PreparedRequest(
        http.RunningRequest(weft.witness_pid(owner), fn() {
          process.send(cancel, Nil)
        }),
        fn() {
          list.each(route(request), fn(event) { process.send(target, event) })
        },
      ),
    )
  })
}

fn ok(body: String) -> List(http.HttpEvent) {
  [
    http.ResponseStatus(200, []),
    http.ResponseChunk(bit_array.from_string(body)),
    http.ResponseEnd,
  ]
}

fn status(code: Int, body: String) -> List(http.HttpEvent) {
  [
    http.ResponseStatus(code, []),
    http.ResponseChunk(bit_array.from_string(body)),
    http.ResponseEnd,
  ]
}

fn bearer(request: http.HttpRequest, token: String) -> Bool {
  list.contains(request.headers, #("authorization", "Bearer " <> token))
}

pub fn a_table_reports_each_seat_and_exits_zero_test() {
  let run =
    seat_usage_cli.execute(
      [],
      input([
        seat_line("codex-a", "codex", "TOKEN-CODEX-AAAAAAAAAAAA"),
        seat_line("claude-a", "claude", "TOKEN-CLAUDE-BBBBBBBBBBB"),
      ]),
      transport(fn(request) {
        case
          string.contains(request.url, "wham/usage"),
          bearer(request, "TOKEN-CODEX-AAAAAAAAAAAA"),
          bearer(request, "TOKEN-CLAUDE-BBBBBBBBBBB")
        {
          True, True, _ -> ok(codex_open)
          False, _, True -> ok(claude_spent)
          _, _, _ -> status(401, "")
        }
      }),
      now_ms,
    )

  assert run.exit_code == 0
  assert run.stderr == ""
  assert string.contains(run.stdout, "codex-a")
  assert string.contains(run.stdout, "plus")
  assert string.contains(run.stdout, "primary 42% resets 2026-11-11T22:00:00Z")
  assert string.contains(run.stdout, "exhausted")
  assert string.contains(run.stdout, "five_hour 100%")
}

pub fn json_prints_one_object_per_seat_and_the_model_answer_test() {
  let run =
    seat_usage_cli.execute(
      ["--json", "--model", "gpt-x"],
      input([seat_line("codex-a", "codex", "TOKEN-CODEX-AAAAAAAAAAAA")]),
      transport(fn(request) {
        case string.contains(request.url, "/v1/models") {
          True -> ok(listing)
          False -> ok(codex_open)
        }
      }),
      now_ms,
    )

  assert run.exit_code == 0
  assert run.stdout
    == "{\"label\":\"codex-a\",\"provider\":\"codex\",\"plan\":\"plus\",\"state\":\"available\",\"state_reason\":null,\"windows\":[{\"name\":\"primary\",\"used_fraction\":0.42,\"resets_at\":\"2026-11-11T22:00:00Z\",\"window_seconds\":18000}],\"model\":{\"available\":\"yes\",\"reason\":null},\"error\":null}"
}

pub fn an_unreadable_seat_exits_nonzero_and_is_reported_unknown_test() {
  let run =
    seat_usage_cli.execute(
      ["--json"],
      input([seat_line("claude-a", "claude", "TOKEN-CLAUDE-BBBBBBBBBBB")]),
      transport(fn(_) { status(403, "{\"error\":\"scope\"}") }),
      now_ms,
    )

  assert run.exit_code == 1
  assert string.contains(run.stdout, "\"state\":\"unknown\"")
  assert string.contains(run.stdout, "\"error\":\"http_403\"")
}

pub fn a_slow_seat_times_out_without_hiding_the_others_test() {
  let run =
    seat_usage_cli.execute(
      ["--json", "--timeout-ms", "100"],
      input([
        seat_line("slow", "codex", "TOKEN-SLOW-CCCCCCCCCCCCC"),
        seat_line("fast", "codex", "TOKEN-FAST-DDDDDDDDDDDDD"),
      ]),
      transport(fn(request) {
        case bearer(request, "TOKEN-SLOW-CCCCCCCCCCCCC") {
          True -> []
          False -> ok(codex_open)
        }
      }),
      now_ms,
    )

  assert run.exit_code == 1
  let assert [slow, fast] = string.split(run.stdout, "\n")
  assert string.contains(slow, "\"error\":\"timeout\"")
  assert string.contains(fast, "\"error\":null")
}

pub fn an_oversized_response_is_refused_test() {
  let big = string.repeat("a", 262_145)
  let run =
    seat_usage_cli.execute(
      ["--json"],
      input([seat_line("a", "codex", "TOKEN-BIG-EEEEEEEEEEEEEE")]),
      transport(fn(_) { ok(big) }),
      now_ms,
    )

  assert run.exit_code == 1
  assert string.contains(run.stdout, "\"error\":\"response_too_large\"")
}

pub fn input_refusals_make_no_request_and_exit_two_test() {
  let run =
    seat_usage_cli.execute(
      [],
      input([
        seat_line("a", "codex", "TOKEN-OK-FFFFFFFFFFFFFFFF"),
        "{\"label\":\"b\",\"provider\":\"codex\",\"token\":\"TOKEN-BAD-GGGGGGGGGGGG\",\"x\":1}",
      ]),
      transport(fn(_) { panic as "no request may be made for refused input" }),
      now_ms,
    )

  assert run.exit_code == 2
  assert run.stdout == ""
  assert run.stderr == "loom seat-usage: line 2 (b): unknown key"
}

pub fn arguments_are_checked_and_never_echoed_test() {
  let run =
    seat_usage_cli.execute(
      ["--token", "TOKEN-ARG-HHHHHHHHHHHHHHHH"],
      input([seat_line("a", "codex", "t")]),
      transport(fn(_) { [] }),
      now_ms,
    )

  assert run.exit_code == 2
  assert !string.contains(run.stderr, "TOKEN-ARG")
  assert seat_usage_cli.parse_arguments(["--concurrency", "0"])
    == Error("a number option is not an integer in range")
  assert seat_usage_cli.parse_arguments(["--json", "--json"])
    == Error("an option was given twice")
  assert seat_usage_cli.parse_arguments(["--model"])
    == Error("an option is missing its value")
}

pub fn no_token_reaches_anything_the_command_writes_test() {
  let tokens = [
    "TOKEN-LEAK-0123456789-alpha", "TOKEN-LEAK-0123456789-bravo",
    "TOKEN-LEAK-0123456789-charlie", "TOKEN-LEAK-0123456789-delta",
    "TOKEN-LEAK-0123456789-echo",
  ]
  let lines = [
    seat_line("ok", "codex", "TOKEN-LEAK-0123456789-alpha"),
    seat_line("http", "claude", "TOKEN-LEAK-0123456789-bravo"),
    seat_line("slow", "codex", "TOKEN-LEAK-0123456789-charlie"),
    seat_line("junk", "claude", "TOKEN-LEAK-0123456789-delta"),
    seat_line("failed", "codex", "TOKEN-LEAK-0123456789-echo"),
  ]

  // Every outcome: a success, an HTTP error, a timeout, a malformed response
  // and a transport failure. The servers echo the bearer they were sent, as a
  // careless one might.
  let route = fn(request: http.HttpRequest) {
    let held = fn(token) { bearer(request, token) }

    case
      held("TOKEN-LEAK-0123456789-alpha"),
      held("TOKEN-LEAK-0123456789-bravo"),
      held("TOKEN-LEAK-0123456789-charlie"),
      held("TOKEN-LEAK-0123456789-delta")
    {
      True, _, _, _ -> ok(codex_open)
      _, True, _, _ ->
        status(429, "rate limited for TOKEN-LEAK-0123456789-bravo")
      _, _, True, _ -> []
      _, _, _, True -> ok("{\"echo\": TOKEN-LEAK-0123456789-delta")
      _, _, _, _ -> [http.RequestFailed("refused TOKEN-LEAK-0123456789-echo")]
    }
  }

  let outputs =
    list.flat_map(
      [[], ["--json"], ["--model", "gpt-x"], ["--json", "--model", "gpt-x"]],
      fn(arguments) {
        let run =
          seat_usage_cli.execute(
            list.append(["--timeout-ms", "100"], arguments),
            input(lines),
            transport(route),
            now_ms,
          )

        [run.stdout, run.stderr]
      },
    )

  // The decode refusal path, too: a refused line carrying a token.
  let refused =
    seat_usage_cli.execute(
      [],
      input([
        "{\"label\":\"a\",\"provider\":\"codex\",\"token\":\"TOKEN-LEAK-0123456789-alpha\",\"extra\":1}",
        "not json TOKEN-LEAK-0123456789-bravo",
      ]),
      transport(route),
      now_ms,
    )

  let everything =
    string.join([refused.stdout, refused.stderr, ..outputs], "\n")

  assert string.contains(everything, "timeout")
  assert string.contains(everything, "http_429")
  assert string.contains(everything, "malformed_response")
  assert string.contains(everything, "transport_failed")
  assert list.all(tokens, fn(token) {
    !string.contains(everything, token)
    && !string.contains(everything, string.drop_end(token, 8))
    && !string.contains(everything, string.drop_start(token, 8))
  })
}
