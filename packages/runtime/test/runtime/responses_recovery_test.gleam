//// The real runtime retries adapter-produced failures under a sticky ceiling.
//// Its provider seam is scripted; normalization, settlement and policy are not.

import core/clock
import core/codec
import core/json
import core/message
import core/usage_evidence
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import machine/operation
import provider/adapter/responses
import provider/model
import provider/stream
import runtime/api
import runtime/effects
import session/session
import support/fake
import support/harness
import support/recorder

fn failure(hint: Option(Int)) {
  let target =
    model.ResolvedModel("codex", "fixture", model.ThinkingOff, 200_000, 8192)
  let machine = responses.subscription_response_machine(target, now: 0)
  let state =
    machine.on_status(machine.init, 200, [
      #("x-request-id", "req_0123456789abcdef0123456789abcdef"),
    ])
  let headers = case hint {
    Some(delay) -> [#("retry-after-ms", json.String(int.to_string(delay)))]
    None -> []
  }
  let body =
    "event: error\ndata: "
    <> json.to_string(
      json.Object([
        #("type", json.String("error")),
        #(
          "error",
          json.Object([
            #("code", json.String("unknown_backend")),
            #("message", json.String("canary-provider-secret")),
            #("headers", json.Object(headers)),
          ]),
        ),
      ]),
    )
    <> "\n\n"
  let #(_, events) = machine.on_chunk(state, bit_array.from_string(body))
  let assert [stream.Failed(error, report)] = events
    as "The production adapter produces the scripted failure."
  #(error, report)
}

pub fn unclassified_failure_cap_and_context_survive_durable_codec_test() {
  let #(error, report) = failure(Some(60_000))
  let settled =
    effects.settle_failure(error, harness.configuration(), 50, report)
  assert codec.decode_message(codec.encode_message(settled)) == Ok(settled)
  let assert message.AssistantMessage(
    diagnostics: Some(json.Object(fields)),
    raw_stop_reason: Some("retryable"),
    error_message: Some(description),
    usage:,
    content: [],
    ..,
  ) = settled
    as "The original failure settles with its retry ceiling and no output."
  assert list.key_find(fields, "retry_max_attempts") == Ok(json.Int(3))
  assert list.key_find(fields, "retry_after_ms") == Ok(json.Int(60_000))
  assert usage.evidence == usage_evidence.unknown(usage_evidence.ChatGptPlan)
  assert string.contains(description, "event=error")
  assert string.contains(
    description,
    "upstream_request_id=req_0123456789abcdef0123456789abcdef",
  )
  assert !string.contains(description, "canary-provider-secret")
}

fn run(budget: operation.RetryBudget, succeeds_on: Option(Int)) {
  let rec = recorder.start()
  let #(error, report) = failure(None)
  let assert Ok(sess) =
    session.open_memory(clock.stepping(from: 1_000_000, by: 7))
    as "The session opens before effects start."
  let eff =
    fake.effects(
      rec,
      clock.stepping(from: 2_000_000, by: 25),
      [],
      fn(spec) {
        let attempt = fake.attempt(spec)
        case succeeds_on {
          Some(number) if attempt >= number ->
            fake.Reply(fake.answer("Recovered", 8))
          Some(_) | None -> fake.RefuseAccounted(error, report)
        }
      },
      fn(_) { fake.ToolHang },
    )
  let options =
    api.Options(
      ..api.default_options(harness.configuration()),
      retry_policy: operation.NormalizedRetryPolicy(budget, 1, 4),
      poll_interval_ms: 25,
      idle_poll_interval_ms: 25,
    )
  let assert Ok(rt) = api.open(sess, eff, options)
    as "The runtime uses its normal writer and strand driver."
  let assert Ok(op) = api.prompt(rt, [fake.user("recover")])
    as "One owner prompt admits the complete run."
  let assert Ok(outcome) = api.await_result(rt, op, within_ms: 5000)
    as "Bounded recovery must finish without another owner prompt."
  let attempts = recorder.read(rec, "provider")
  let projection = harness.final_projection(sess)
  assert api.close(rt) == Ok(Nil)
  #(outcome, attempts, projection)
}

pub fn transient_unknown_stream_failure_recovers_without_manual_continue_test() {
  let #(outcome, attempts, projection) = run(operation.Unbounded, Some(3))
  harness.assert_completed(outcome)
  assert attempts == 3
  assert projection == ["user:recover", "assistant:stop:Recovered"]
}

pub fn persistent_unknown_stream_failure_stops_after_three_attempts_test() {
  let #(outcome, attempts, _) = run(operation.Unbounded, None)
  let assert operation.RunLastResult(outcome: operation.RunFailed(error:), ..) =
    outcome
    as "The third failed attempt terminates the run."
  assert attempts == 3
  assert error.code == "provider_error"
  assert string.contains(error.message, "responses_error")
}

pub fn stricter_configured_retry_budget_is_preserved_test() {
  let #(outcome, attempts, _) = run(operation.Bounded(1), Some(2))
  let assert operation.RunLastResult(outcome: operation.RunFailed(..), ..) =
    outcome
    as "A one-attempt operator budget does not gain retries."
  assert attempts == 1
}
