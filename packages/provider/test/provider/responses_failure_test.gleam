//// Provider failures retain bounded structural facts and use machine recovery.
//// Remote prose and unknown identifiers never become durable diagnostics.

import core/accounting
import core/json
import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import provider/adapter/responses
import provider/fixture
import provider/internal/diagnostic
import provider/retry
import provider/stream

const request_id = "req_0123456789abcdef0123456789abcdef"

fn machine() {
  responses.subscription_response_machine(
    fixture.resolved("codex", "fixture-model"),
    now: 0,
  )
}

fn error_value(code: String, kind: String) {
  json.Object([
    #("code", json.String(code)),
    #("type", json.String(kind)),
    #("message", json.String("canary-provider-secret")),
  ])
}

fn body(kind: String, error: json.JsonValue) {
  let fields = case kind {
    "response.failed" -> [#("response", json.Object([#("error", error)]))]
    _ -> [#("error", error)]
  }
  fixture.sse_event(
    kind,
    json.to_string(
      json.Object([
        #("type", json.String(kind)),
        #("sequence_number", json.Int(7)),
        ..fields
      ]),
    ),
  )
}

fn failed(body: String) {
  let events =
    fixture.drive(
      machine(),
      status: 200,
      headers: [
        #("content-type", "text/event-stream"),
        #("x-request-id", request_id),
      ],
      chunks: [bit_array.from_string(body)],
    )
  let assert [stream.Failed(error, report)] = events
    as "A failed stream emits exactly one terminal and no settled output."
  #(error, report)
}

pub fn nested_error_preserves_classification_and_safe_context_test() {
  let #(error, _) = failed(body("error", error_value("server_error", "error")))
  let assert stream.StreamError("server_error", description, None) = error
    as "The nested error code owns classification, not the envelope type."
  assert retry.classify(error) == retry.Retryable(backoff_hint_ms: None)
  assert string.contains(description, "error_code=server_error")
  assert string.contains(description, "status=200")
  assert string.contains(description, "event=error; seq=7")
  assert string.contains(description, "upstream_request_id=" <> request_id)
  assert !string.contains(description, "canary-provider-secret")
}

pub fn unknown_response_failures_have_a_three_attempt_ceiling_test() {
  list.each(["error", "response.failed"], fn(kind) {
    list.each(
      [json.Null, error_value("novel_failure", "novel_type")],
      fn(value) {
        let #(error, report) = failed(body(kind, value))
        assert retry.classify(error)
          == retry.RetryableWithin(backoff_hint_ms: None, max_attempts: 3)
        assert accounting.attempts(report) == 1
        let description = stream.describe_error(error)
        assert string.contains(description, "event=" <> kind)
        assert string.contains(
          description,
          "upstream_request_id=" <> request_id,
        )
        assert !string.contains(description, "novel_failure")
        assert !string.contains(description, "novel_type")
        assert !string.contains(description, "canary-provider-secret")
      },
    )
  })
}

pub fn permanent_error_codes_and_types_stay_terminal_test() {
  list.each(
    [
      "authentication_error", "invalid_api_key", "permission_error",
      "invalid_request_error", "invalid_prompt", "model_not_found",
      "insufficient_quota", "credit_balance_exhausted",
      "organization_spend_limit_exceeded", "project_spend_limit_exceeded",
      "organization_usage_limit_exceeded", "usage_not_included",
      "usage_limit_reached", "flex_unavailable", "cyber_policy", "bio_policy",
      "misalignment_policy_violation", "context_length_exceeded",
    ],
    fn(code) {
      list.each(["error", "response.failed"], fn(kind) {
        list.each(
          [
            error_value(code, "server_error"),
            error_value(code, "rate_limit_error"),
            error_value("rate_limit_exceeded", code),
            error_value("novel", code),
          ],
          fn(value) {
            let #(error, _) = failed(body(kind, value))
            assert retry.classify(error) == retry.Terminal
            assert string.contains(stream.describe_error(error), code)
          },
        )
      })
    },
  )
}

pub fn failure_diagnostics_reject_provider_text_and_invalid_headers_test() {
  let text =
    body(
      "error",
      error_value("canary-provider-secret", "canary-provider-secret"),
    )
  let events =
    fixture.drive(
      machine(),
      status: 200,
      headers: [
        #("content-type", "canary-provider-secret"),
        #("x-request-id", "canary-provider-secret"),
        #("authorization", "canary-provider-secret"),
      ],
      chunks: [bit_array.from_string(text)],
    )
  let assert [stream.Failed(error, _)] = events
    as "Untrusted diagnostic fields do not prevent failure settlement."
  let scrubbed = diagnostic.scrub_error(error, secret: "different-credential")
  let assert stream.StreamError(_, description, _) = scrubbed
    as "The scrubber retains a structural stream failure."
  assert string.contains(description, "error_code=unrecognized")
  assert string.contains(description, "error_type=unrecognized")
  assert string.contains(description, "upstream_request_id=invalid")
  assert !string.contains(description, "canary-provider-secret")
  assert string.byte_size(description) <= 400
}

pub fn failure_context_is_chunk_invariant_and_terminal_once_test() {
  let text = body("response.failed", error_value("novel", "server_error"))
  let bytes = bit_array.from_string(text)
  let whole = fixture.drive(machine(), 200, [], [bytes])
  assert fixture.drive(machine(), 200, [], fixture.chunked(bytes, 1)) == whole
  assert fixture.drive(machine(), 200, [], [bytes, bytes]) == whole
}

pub fn flat_errors_and_malformed_labels_keep_distinct_diagnostics_test() {
  let flat =
    fixture.sse_event(
      "error",
      "{\"type\":\"error\",\"code\":\"context_length_exceeded\",\"message\":\"canary-provider-secret\"}",
    )
  let #(error, _) = failed(flat)
  assert retry.classify(error) == retry.Terminal
  assert string.contains(
    stream.describe_error(error),
    "maximum context length exceeded",
  )
  assert !string.contains(
    stream.describe_error(error),
    "canary-provider-secret",
  )

  // Invalid field shapes remain failed responses; diagnostics identify only
  // their shape and cannot copy the remote object or string representation.
  let #(error, _) =
    failed(body(
      "response.failed",
      json.Object([
        #("code", json.Int(17)),
        #("type", json.Array([json.String("canary-provider-secret")])),
      ]),
    ))
  assert retry.classify(error)
    == retry.RetryableWithin(backoff_hint_ms: None, max_attempts: 3)
  assert string.contains(stream.describe_error(error), "error_code=invalid")
  assert string.contains(stream.describe_error(error), "error_type=invalid")
  assert !string.contains(
    stream.describe_error(error),
    "canary-provider-secret",
  )
}

pub fn failed_response_retains_reported_usage_and_one_terminal_test() {
  let text =
    fixture.sse_event(
      "response.failed",
      "{\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"novel\"},\"usage\":{\"input_tokens\":12,\"output_tokens\":5,\"total_tokens\":17,\"input_tokens_details\":{\"cached_tokens\":2}}}}",
    )
  let #(error, report) = failed(text)
  assert retry.classify(error)
    == retry.RetryableWithin(backoff_hint_ms: None, max_attempts: 3)
  let usage = accounting.total(report)
  assert #(usage.input, usage.cache_read, usage.output, usage.total_tokens)
    == #(10, 2, 5, 17)
  assert accounting.attempts(report) == 1
}

pub fn streamed_retry_advice_survives_scrubbing_and_classification_test() {
  list.each(["error", "response.failed"], fn(kind) {
    list.each(["novel", "server_error", "permission_denied"], fn(code) {
      let value =
        json.Object([
          #("code", json.String(code)),
          #("message", json.String("canary-provider-secret")),
          #(
            "headers",
            json.Object([
              #("Retry-After", json.String("60")),
              #("Authorization", json.String("canary-provider-secret")),
            ]),
          ),
        ])
      let #(error, _) = failed(body(kind, value))
      let scrubbed =
        diagnostic.scrub_error(error, secret: "different-credential")
      let assert stream.StreamError(_, description, Some(60_000)) = scrubbed
        as "The structured advice survives the credential scrubber."
      let expected = case code {
        "permission_denied" -> retry.Terminal
        "server_error" -> retry.Retryable(backoff_hint_ms: Some(60_000))
        _ ->
          retry.RetryableWithin(backoff_hint_ms: Some(60_000), max_attempts: 3)
      }
      assert retry.classify(scrubbed) == expected
      assert !string.contains(description, "canary-provider-secret")
    })
  })
}

pub fn response_and_event_advice_keep_the_larger_valid_delay_test() {
  list.each([#("3000", 7000), #("9000", 9000)], fn(values) {
    let #(event_delay, expected) = values
    let text =
      body(
        "error",
        json.Object([
          #(
            "headers",
            json.Object([
              #("RETRY-AFTER-MS", json.Array([json.String(event_delay)])),
            ]),
          ),
        ]),
      )
    let events =
      fixture.drive(machine(), 200, [#("retry-after-ms", "7000")], [
        bit_array.from_string(text),
      ])
    let assert [stream.Failed(error, _)] = events
      as "Both header sources belong to the same failed attempt."
    assert retry.classify(error)
      == retry.RetryableWithin(backoff_hint_ms: Some(expected), max_attempts: 3)
  })
}

pub fn malformed_retry_advice_does_not_become_a_weaker_seconds_hint_test() {
  list.each(
    [json.String("-1"), json.String("invalid"), json.Int(5000), json.Array([])],
    fn(value) {
      let #(error, _) =
        failed(body(
          "error",
          json.Object([
            #(
              "headers",
              json.Object([
                #("retry-after-ms", value),
                #("retry-after", json.String("60")),
              ]),
            ),
          ]),
        ))
      assert retry.classify(error)
        == retry.RetryableWithin(backoff_hint_ms: None, max_attempts: 3)
    },
  )
}
