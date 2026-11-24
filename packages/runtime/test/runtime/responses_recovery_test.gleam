//// The real runtime retries adapter-produced failures under a sticky ceiling.
//// Its provider seam is scripted; normalization, settlement and policy are not.

import core/clock
import core/codec
import core/ids.{type OpId}
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
import weft/poll

fn failure(code: String, hint: Option(Int)) {
  let target =
    model.ResolvedModel("codex", "fixture", model.ThinkingOff, 200_000, 8192)
  let machine = responses.subscription_response_machine(target, now: 0)
  let state =
    machine.on_status(machine.init, 200, [
      #("x-request-id", "req_0123456789abcdef0123456789abcdef"),
      #("retry-after", "1"),
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
            #("code", json.String(code)),
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
  let #(error, report) = failure("unknown_backend", Some(60_000))
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

type RetryDeadlineCapture {
  CaptureRetryDeadline
  SkipRetryDeadline
}

fn run(
  code: String,
  hint: Option(Int),
  budget: operation.RetryBudget,
  succeeds_on: Option(Int),
  capture_retry_deadline: RetryDeadlineCapture,
) {
  let rec = recorder.start()
  let #(error, report) = failure(code, hint)
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
  let retry_deadline = case capture_retry_deadline {
    CaptureRetryDeadline -> observe_retry_deadline(sess, op)
    SkipRetryDeadline -> None
  }
  let assert Ok(outcome) = api.await_result(rt, op, within_ms: 5000)
    as "Bounded recovery must finish without another owner prompt."
  let attempts = recorder.read(rec, "provider")
  let projection = harness.final_projection(sess)
  assert api.close(rt) == Ok(Nil)
  #(outcome, attempts, projection, retry_deadline)
}

fn observe_retry_deadline(sess: session.Session, op: OpId) -> Option(Int) {
  let observed =
    poll.until(within: 1000, every: 5, attempt: fn() {
      case session.op_state(sess, op) {
        Ok(Some(session.Cell(
          value: operation.RunState(
            phase: operation.Assistant(generation: operation.GenerationRetryWait(
              not_before:,
              ..,
            )),
            ..,
          ),
          ..,
        ))) -> poll.Done(Some(not_before))
        Ok(Some(session.Cell(..))) | Ok(None) -> poll.Retry
        Error(session.StoreFailure(..)) | Error(session.SessionCorrupt(..)) ->
          poll.Done(None)
      }
    })
  case observed {
    poll.Answered(deadline) -> deadline
    _ -> None
  }
}

pub fn transient_unknown_stream_failure_recovers_without_manual_continue_test() {
  let #(outcome, attempts, projection, _) =
    run(
      "unknown_backend",
      None,
      operation.Unbounded,
      Some(3),
      SkipRetryDeadline,
    )
  harness.assert_completed(outcome)
  assert attempts == 3
  assert projection == ["user:recover", "assistant:stop:Recovered"]
}

pub fn persistent_unknown_stream_failure_stops_after_three_attempts_test() {
  let #(outcome, attempts, _, _) =
    run("unknown_backend", None, operation.Unbounded, None, SkipRetryDeadline)
  let assert operation.RunLastResult(outcome: operation.RunFailed(error:), ..) =
    outcome
    as "The third failed attempt terminates the run."
  assert attempts == 3
  assert error.code == "provider_error"
  assert string.contains(error.message, "responses_error")
}

pub fn overloaded_stream_failure_without_server_advice_is_terminal_test() {
  let #(outcome, attempts, _, _) =
    run(
      "server_is_overloaded",
      None,
      operation.Unbounded,
      Some(2),
      SkipRetryDeadline,
    )
  let assert operation.RunLastResult(outcome: operation.RunFailed(error:), ..) =
    outcome
    as "An overload without server advice is not retryable."
  assert attempts == 1
  assert error.code == "provider_error"
  assert string.contains(error.message, "capacity")
  assert string.contains(error.message, "server_is_overloaded")
}

pub fn advised_overloaded_stream_failure_retries_and_recovers_test() {
  let #(outcome, attempts, projection, retry_deadline) =
    run(
      "server_is_overloaded",
      Some(250),
      operation.Unbounded,
      Some(2),
      CaptureRetryDeadline,
    )
  harness.assert_completed(outcome)
  assert attempts == 2
  assert projection == ["user:recover", "assistant:stop:Recovered"]
  let assert Some(not_before) = retry_deadline
    as "The runtime persisted the server-advised retry deadline."
  assert not_before >= 1_000_250
}

pub fn advised_overloaded_stream_failure_stops_after_six_attempts_test() {
  let #(outcome, attempts, _, _) =
    run(
      "server_is_overloaded",
      Some(1),
      operation.Unbounded,
      None,
      SkipRetryDeadline,
    )
  let assert operation.RunLastResult(outcome: operation.RunFailed(..), ..) =
    outcome
    as "Five server-advised retries exhaust the overload attempt cap."
  assert attempts == 6
}

pub fn stricter_configured_retry_budget_is_preserved_test() {
  let #(outcome, attempts, _, _) =
    run(
      "server_is_overloaded",
      Some(1),
      operation.Bounded(1),
      Some(2),
      SkipRetryDeadline,
    )
  let assert operation.RunLastResult(outcome: operation.RunFailed(..), ..) =
    outcome
    as "A one-attempt operator budget does not gain retries."
  assert attempts == 1
}
