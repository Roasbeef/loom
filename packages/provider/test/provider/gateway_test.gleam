//// Provider-gateway behavior at the process boundary.
////
//// These tests use observable fixture transports to pin routing, settlement,
//// and cancellation order. In particular, the prepared-request test proves
//// that cancellation can retire the published owner before route resolution,
//// secret lookup, or transport startup becomes possible.

import core/accounting
import core/clock
import core/json
import core/message
import core/usage_evidence
import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import provider/fixture.{sse_event}
import provider/gateway
import provider/http
import provider/internal/wire
import provider/model
import provider/pricing
import provider/secret
import provider/stream

const secret_value = "sk-super-secret-123"

// --- fixtures -------------------------------------------------------------

fn target(provider: String, model_id: String) -> model.ResolvedModel {
  fixture.resolved(provider:, model_id:)
}

fn happy_transcript(text: String) -> String {
  sse_event(
    "message_start",
    "{\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"model\":\"m\","
      <> "\"usage\":{\"input_tokens\":10,\"output_tokens\":1}}}",
  )
  <> sse_event(
    "content_block_start",
    "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
  )
  <> sse_event(
    "content_block_delta",
    "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\""
      <> text
      <> "\"}}",
  )
  <> sse_event(
    "message_delta",
    "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":4}}",
  )
  <> sse_event("message_stop", "{\"type\":\"message_stop\"}")
}

fn overloaded_response() -> List(http.HttpEvent) {
  fixture.error_response(
    529,
    [],
    "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}",
  )
}

fn invalid_request_response() -> List(http.HttpEvent) {
  fixture.error_response(
    400,
    [],
    "{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"bad request\"}}",
  )
}

fn secrets() -> secret.SecretStore {
  secret.from_list([
    #("PRIMARY_KEY", secret_value),
    #("BACKUP_KEY", "sk-backup-key"),
  ])
}

fn two_provider_gateway(transport: http.Transport) -> gateway.Gateway {
  gateway.new(
    transport:,
    secrets: secrets(),
    clock: clock.fixed(at: 1_700_000_000_000),
  )
  |> gateway.add_provider(gateway.AnthropicProvider(
    name: "primary",
    base_url: "https://primary.test",
    api_key_secret: "PRIMARY_KEY",
  ))
  |> gateway.add_provider(gateway.AnthropicProvider(
    name: "backup",
    base_url: "https://backup.test",
    api_key_secret: "BACKUP_KEY",
  ))
  |> gateway.route(model.Main, [
    target("primary", "model-a"),
    target("backup", "model-b"),
  ])
  |> gateway.with_attempt_timeout(2000)
}

fn main_request() -> model.ProviderRequest {
  model.ProviderRequest(
    target: model.ForRole(model.Main, None),
    system: Some("Be terse."),
    messages: [
      message.UserMessage(
        content: [message.UserText(text: "hi", text_signature: None)],
        timestamp: 1,
        origin: None,
      ),
    ],
    tools: [],
    max_output_tokens: None,
  )
}

// --- resolve ---------------------------------------------------------------

pub fn resolve_returns_first_usable_target_test() {
  let gw = two_provider_gateway(fixture.transport([]))
  assert gateway.resolve(gw, model.Main) == Ok(target("primary", "model-a"))
}

pub fn resolve_skips_unregistered_providers_test() {
  let gw =
    two_provider_gateway(fixture.transport([]))
    |> gateway.route(model.Plan, [
      target("ghost", "phantom-model"),
      target("backup", "model-b"),
    ])
  assert gateway.resolve(gw, model.Plan) == Ok(target("backup", "model-b"))
}

pub fn resolve_missing_role_test() {
  let gw = two_provider_gateway(fixture.transport([]))
  assert gateway.resolve(gw, model.Vision)
    == Error(model.MissingIdentity(role: model.Vision))
}

pub fn resolve_route_with_no_registered_providers_test() {
  let gw =
    two_provider_gateway(fixture.transport([]))
    |> gateway.route(model.Summarize, [target("ghost", "phantom-model")])
  assert gateway.resolve(gw, model.Summarize)
    == Error(model.MissingIdentity(role: model.Summarize))
}

// --- request dispatch -------------------------------------------------------

pub fn happy_dispatch_settles_test() {
  let gw =
    two_provider_gateway(
      fixture.transport(fixture.ok_response(happy_transcript("Hello"))),
    )
  let handle = gateway.request(gw, main_request())
  let assert Ok(#(deltas, stream.Settled(message: settled, accounting: report))) =
    stream.await_terminal(handle, within: 2000)
  let usage = accounting.total(report)
  assert deltas == [stream.TextDelta(index: 0, text: "Hello")]
  let assert message.AssistantMessage(
    model: model_id,
    provider:,
    timestamp:,
    ..,
  ) = stream.message(settled)
  assert model_id == "model-a"
  assert provider == "primary"
  assert timestamp == 1_700_000_000_000
  assert usage.output == 4
}

// --- pricing ----------------------------------------------------------------

pub fn a_priced_provider_settles_with_a_real_cost_test() {
  // The transcript above reports ten input and four output tokens. At
  // $3.00 and $15.00 per million that is $0.00003 and $0.00006, and the
  // point of the assertion is that the number the ledger will store is the
  // one `pricing.price` computes — not a zero, and not a second opinion.
  let card =
    pricing.Pricing(input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.0)
  let gw =
    two_provider_gateway(
      fixture.transport(fixture.ok_response(happy_transcript("Hello"))),
    )
    |> gateway.price("primary", card)
  let handle = gateway.request(gw, main_request())
  let assert Ok(#(_deltas, stream.Settled(message: settled, accounting: report))) =
    stream.await_terminal(handle, within: 2000)
  let usage = accounting.total(report)

  assert usage.cost.total >. 0.0
  assert usage.cost == pricing.price(usage, card).cost

  // A one-attempt report equals the final message's usage. Pricing must
  // update both observations so either reader receives the same estimate.
  let assert message.AssistantMessage(usage: inner, ..) =
    stream.message(settled)
  assert inner == usage
}

pub fn an_unpriced_provider_retains_unavailable_estimate_test() {
  let gw =
    two_provider_gateway(
      fixture.transport(fixture.ok_response(happy_transcript("Hello"))),
    )
  let handle = gateway.request(gw, main_request())
  let assert Ok(#(_deltas, stream.Settled(message: _, accounting: report))) =
    stream.await_terminal(handle, within: 2000)
  let usage = accounting.total(report)
  assert usage.cost.total == 0.0
  assert usage.evidence == usage_evidence.partial(usage_evidence.Api)
}

pub fn a_card_prices_only_the_provider_it_names_test() {
  // Cards hang off the provider name, so a card written for the fallback
  // must not price a settlement the primary produced.
  let gw =
    two_provider_gateway(
      fixture.transport(fixture.ok_response(happy_transcript("Hello"))),
    )
    |> gateway.price(
      "backup",
      pricing.Pricing(
        input: 1000.0,
        output: 1000.0,
        cache_read: 1000.0,
        cache_write: 1000.0,
      ),
    )
  let handle = gateway.request(gw, main_request())
  let assert Ok(#(_deltas, stream.Settled(message: _, accounting: report))) =
    stream.await_terminal(handle, within: 2000)
  let usage = accounting.total(report)
  assert usage.cost.total == 0.0
  assert usage.evidence == usage_evidence.partial(usage_evidence.Api)
}

pub fn gemini_provider_dispatches_through_its_adapter_test() {
  // The third dialect reaches its own adapter: the request goes to the
  // generateContent path with the key in `x-goog-api-key`, and the
  // response folds through the Gemini machine.
  let requests = process.new_subject()
  let transport =
    fixture.routing_transport(fn(request) {
      process.send(requests, request)
      fixture.ok_response(
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"Hello\"}],\"role\":\"model\"},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":10,\"candidatesTokenCount\":4,\"totalTokenCount\":14}}\n\n",
      )
    })
  let gw =
    gateway.new(
      transport:,
      secrets: secrets(),
      clock: clock.fixed(at: 1_700_000_000_000),
    )
    |> gateway.add_provider(gateway.GeminiProvider(
      name: "google",
      base_url: "https://gemini.test/v1beta",
      api_key_secret: "PRIMARY_KEY",
    ))
    |> gateway.route(model.Main, [target("google", "gemini-3.5-flash")])
    |> gateway.with_attempt_timeout(2000)
  let handle = gateway.request(gw, main_request())
  let assert Ok(#(deltas, stream.Settled(message: settled, accounting: report))) =
    stream.await_terminal(handle, within: 2000)
  let usage = accounting.total(report)
  assert deltas == [stream.TextDelta(index: 0, text: "Hello")]
  let assert message.AssistantMessage(api:, provider:, ..) =
    stream.message(settled)
  assert api == "gemini-generate-content"
  assert provider == "google"
  assert usage.output == 4
  let assert Ok(sent) = process.receive(requests, within: 1000)
  assert sent.url
    == "https://gemini.test/v1beta/models/gemini-3.5-flash:streamGenerateContent?alt=sse"
  assert list.key_find(sent.headers, "x-goog-api-key") == Ok(secret_value)
}

// Empty output isolates dispatch from content decoding. Both lifecycle
// witnesses still name the same response and resolved model.
fn responses_transcript() -> String {
  sse_event(
    "response.created",
    "{\"type\":\"response.created\",\"response\":{\"id\":\"resp_1\",\"model\":\"model-b\",\"status\":\"in_progress\",\"output\":[]}}",
  )
  <> sse_event(
    "response.completed",
    "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"model\":\"model-b\",\"status\":\"completed\",\"output\":[],\"error\":null,\"usage\":{\"input_tokens\":10,\"output_tokens\":4,\"total_tokens\":14}}}",
  )
}

fn responses_gateway(transport: http.Transport) -> gateway.Gateway {
  gateway.new(transport:, secrets: secrets(), clock: clock.fixed(123))
  |> gateway.add_provider(gateway.OpenAiCompatibleProvider(
    name: "chat",
    base_url: "https://api.openai.com/v1",
    api_key_secret: "PRIMARY_KEY",
  ))
  |> gateway.add_provider(gateway.OpenAiResponsesProvider(
    name: "responses",
    base_url: "https://api.openai.com/v1",
    api_key_secret: "BACKUP_KEY",
  ))
  |> gateway.route(model.Main, [
    model.ResolvedModel(
      ..target("chat", "model-b"),
      thinking: model.ThinkingHigh,
    ),
    model.ResolvedModel(
      ..target("responses", "model-b"),
      thinking: model.ThinkingOff,
    ),
  ])
  |> gateway.with_attempt_timeout(2000)
}

pub fn responses_provider_dispatches_with_exact_endpoint_and_credentials_test() {
  let requests = process.new_subject()
  let transport =
    fixture.routing_transport(fn(request) {
      process.send(requests, request)
      fixture.ok_response(responses_transcript())
    })
  let request =
    model.ProviderRequest(
      ..main_request(),
      target: model.ForResolved(target("responses", "model-b")),
    )
  let handle = gateway.request(responses_gateway(transport), request)
  let assert Ok(#([], stream.Settled(message: settled, accounting: report))) =
    stream.await_terminal(handle, within: 2000)
    as "the Responses adapter must settle its own lifecycle stream"
  let usage = accounting.total(report)
  let assert message.AssistantMessage(api:, provider:, model: model_id, ..) =
    stream.message(settled)
    as "a Responses settlement retains its durable identity"
  assert #(api, provider, model_id)
    == #("openai-responses", "responses", "model-b")
  assert usage.output == 4
  let assert Ok(sent) = process.receive(requests, within: 1000)
    as "one API-key request must reach the transport"
  assert sent.method == "POST"
  assert sent.url == "https://api.openai.com/v1/responses"
  assert list.key_find(sent.headers, "authorization")
    == Ok("Bearer sk-backup-key")
  assert list.key_find(sent.headers, "content-type") == Ok("application/json")
  assert list.key_find(sent.headers, "accept") == Ok("text/event-stream")
  assert list.key_find(sent.headers, "chatgpt-account-id") == Error(Nil)
  assert !string.contains(sent.body, "sk-backup-key")
  assert process.receive(requests, within: 0) == Error(Nil)
}

fn mixed_openai_walk(
  thinking: option.Option(model.ThinkingLevel),
) -> List(String) {
  let bodies = process.new_subject()
  let transport =
    fixture.routing_transport(fn(request) {
      process.send(bodies, request.body)
      case request.url {
        "https://api.openai.com/v1/chat/completions" -> overloaded_response()
        "https://api.openai.com/v1/responses" ->
          fixture.ok_response(responses_transcript())
        _ -> invalid_request_response()
      }
    })
  let request =
    model.ProviderRequest(
      ..main_request(),
      target: model.ForRole(model.Main, thinking),
    )
  let handle = gateway.request(responses_gateway(transport), request)
  let assert Ok(#(_, stream.Settled(message: settled, ..))) =
    stream.await_terminal(handle, within: 2000)
    as "a retryable Chat Completions failure must reach Responses"
  let assert message.AssistantMessage(api:, provider:, ..) =
    stream.message(settled)
    as "the fallback settlement must retain the dialect that answered"
  assert #(api, provider) == #("openai-responses", "responses")
  drain(bodies, [])
}

pub fn mixed_chat_responses_walk_preserves_thinking_overlay_test() {
  let assert [chat, responses] = mixed_openai_walk(Some(model.ThinkingMedium))
    as "the mixed walk must attempt both dialects"
  assert string.contains(chat, "\"reasoning_effort\":\"medium\"")
  assert string.contains(responses, "\"effort\":\"medium\"")
}

pub fn mixed_chat_responses_walk_retains_static_levels_without_overlay_test() {
  let assert [chat, responses] = mixed_openai_walk(None)
    as "the mixed walk must attempt both dialects"
  assert string.contains(chat, "\"reasoning_effort\":\"high\"")
  assert !string.contains(responses, "\"reasoning\":")
}

pub fn retryable_failure_walks_the_chain_test() {
  // Primary answers 529 overloaded; the pump falls to backup, which
  // settles. The resolved identity in the settled message is backup's.
  let transport =
    fixture.routing_transport(fn(request) {
      case string.contains(request.url, "primary.test") {
        True -> overloaded_response()
        False -> fixture.ok_response(happy_transcript("From backup"))
      }
    })
  let handle = gateway.request(two_provider_gateway(transport), main_request())
  let assert Ok(#(_deltas, stream.Settled(message: settled, accounting: _))) =
    stream.await_terminal(handle, within: 2000)
  let assert message.AssistantMessage(model: model_id, provider:, ..) =
    stream.message(settled)
  assert provider == "backup"
  assert model_id == "model-b"
}

pub fn exhausted_chain_fails_in_band_with_last_error_test() {
  let handle =
    gateway.request(
      two_provider_gateway(fixture.transport(overloaded_response())),
      main_request(),
    )
  let assert Ok(#([], stream.Failed(error, _))) =
    stream.await_terminal(handle, within: 2000)
  assert stream.underlying_error(error)
    == stream.HttpError(
      status: 529,
      api_error_type: "overloaded_error",
      message: "Overloaded",
      retry_after_ms: None,
    )
}

pub fn terminal_failure_does_not_walk_the_chain_test() {
  // Primary answers 400 invalid_request (terminal); backup would settle,
  // but a terminal error must surface, not be papered over.
  let transport =
    fixture.routing_transport(fn(request) {
      case string.contains(request.url, "primary.test") {
        True -> invalid_request_response()
        False -> fixture.ok_response(happy_transcript("From backup"))
      }
    })
  let handle = gateway.request(two_provider_gateway(transport), main_request())
  let assert Ok(#([], stream.Failed(error, _))) =
    stream.await_terminal(handle, within: 2000)
  let assert stream.HttpError(status: 400, ..) = stream.underlying_error(error)
    as "context preserves the exact underlying failure"
}

pub fn reflected_secret_is_scrubbed_from_http_error_test() {
  let body =
    "{\"type\":\"error\",\"error\":{\"type\":\""
    <> secret_value
    <> "\",\"message\":\"authorization: "
    <> secret_value
    <> "\"}}"
  let handle =
    gateway.request(
      two_provider_gateway(
        fixture.transport(fixture.error_response(400, [], body)),
      ),
      main_request(),
    )
  let assert Ok(#([], stream.Failed(error, _))) =
    stream.await_terminal(handle, within: 2000)
  let rendered = stream.describe_error(error)
  assert !string.contains(rendered, secret_value)
  assert string.contains(rendered, "[REDACTED]")
}

pub fn reflected_secret_is_scrubbed_from_sse_error_test() {
  let response =
    fixture.ok_response(sse_event(
      "error",
      "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"x-api-key "
        <> secret_value
        <> "\"}}",
    ))
  let handle =
    gateway.request(
      two_provider_gateway(fixture.transport(response)),
      model.ProviderRequest(
        ..main_request(),
        target: model.ForResolved(target("primary", "model-a")),
      ),
    )
  let assert Ok(#([], stream.Failed(error, _))) =
    stream.await_terminal(handle, within: 2000)
  let rendered = stream.describe_error(error)
  assert !string.contains(rendered, secret_value)
  assert string.contains(rendered, "[REDACTED]")
}

pub fn reflected_secret_is_scrubbed_from_malformed_response_test() {
  let response =
    fixture.error_response(400, [], "not-json credential=" <> secret_value)
  let handle =
    gateway.request(
      two_provider_gateway(fixture.transport(response)),
      main_request(),
    )
  let assert Ok(#([], stream.Failed(error, _))) =
    stream.await_terminal(handle, within: 2000)
  let rendered = stream.describe_error(error)
  assert !string.contains(rendered, secret_value)
  assert string.contains(rendered, "[REDACTED]")
}

pub fn remote_diagnostics_are_bounded_by_bytes_not_graphemes_test() {
  let one_large_grapheme = "a" <> string.repeat("́", 2000)
  let body =
    "{\"type\":\"error\",\"error\":{\"type\":\"remote\",\"message\":\""
    <> one_large_grapheme
    <> "\"}}"
  let handle =
    gateway.request(
      two_provider_gateway(
        fixture.transport(fixture.error_response(400, [], body)),
      ),
      main_request(),
    )
  let assert Ok(#([], stream.Failed(error, _))) =
    stream.await_terminal(handle, within: 2000)
  let rendered = stream.describe_error(error)
  assert bit_array.byte_size(bit_array.from_string(rendered)) < 1024
}

pub fn cancellation_is_terminal_and_prevents_fallback_test() {
  let started = process.new_subject()
  let cancelled = process.new_subject()
  let transport =
    http.Transport(prepare_streaming: fn(request, _events) {
      let stop_ready = process.new_subject()
      let owner =
        process.spawn_unlinked(fn() {
          let stop = process.new_subject()
          process.send(stop_ready, stop)
          let _stop = process.receive_forever(stop)
          Nil
        })
      let stop = process.receive_forever(stop_ready)
      Ok(
        http.PreparedRequest(
          running: http.RunningRequest(owner:, cancel: fn() {
            process.send(cancelled, request.url)
            process.send(stop, Nil)
          }),
          begin: fn() { process.send(started, request.url) },
        ),
      )
    })
  let handle = gateway.request(two_provider_gateway(transport), main_request())
  assert process.receive(started, within: 1000)
    == Ok("https://primary.test/v1/messages")
  stream.cancel(handle)
  stream.cancel(handle)
  let assert Ok(#([], stream.Failed(error, _))) =
    stream.await_terminal(handle, within: 1000)
  let assert stream.ProviderCancelled = stream.underlying_error(error)
    as "context preserves the exact underlying failure"
  assert process.receive(cancelled, within: 1000)
    == Ok("https://primary.test/v1/messages")
  assert process.receive(started, within: 100) == Error(Nil)

  // The witness asks every adopted owner to stop the moment teardown
  // begins, and the pump cancels its active transport as well, so the
  // primary may hear its cancel more than once; a cancel capability is
  // idempotent by contract (protocol-change/010). What must never happen
  // is a cancel addressed to a transport that was never started.
  assert only_primary_cancelled(cancelled)
}

fn only_primary_cancelled(cancelled: process.Subject(String)) -> Bool {
  case process.receive(cancelled, within: 100) {
    Error(Nil) -> True
    Ok("https://primary.test/v1/messages") -> only_primary_cancelled(cancelled)
    Ok(_other) -> False
  }
}

pub fn cancellation_before_begin_starts_no_provider_work_test() {
  let started = process.new_subject()
  let transport =
    http.Transport(prepare_streaming: fn(_request, _events) {
      process.send(started, Nil)
      Error("a cancelled prepared request must not reach transport")
    })
  let stream.PreparedStream(handle:, begin:) =
    gateway.prepare(two_provider_gateway(transport), main_request())
  let drain_witness = stream.watch_drain(handle)

  stream.cancel(handle)
  assert stream.await_drain_forever(drain_witness) == stream.Drained
  begin()

  assert process.receive(started, within: 50) == Error(Nil)
  assert stream.next(handle, within: 50) == Error(Nil)
}

pub fn cancellation_after_settlement_is_a_noop_test() {
  let gateway =
    two_provider_gateway(
      fixture.transport(fixture.ok_response(happy_transcript("done"))),
    )
  let handle = gateway.request(gateway, main_request())
  let assert Ok(#(_deltas, stream.Settled(..))) =
    stream.await_terminal(handle, within: 1000)
  stream.cancel(handle)
  stream.cancel(handle)
  assert stream.next(handle, within: 100) == Error(Nil)
}

/// Cancellation which crosses a parsed settlement still preserves that one
/// terminal, while the public owner remains live until the attempt drains.
pub fn cancellation_racing_settlement_keeps_one_terminal_test() {
  let #(transport, attempts, owner_ready, cancelled) =
    terminal_race_transport(fixture.ok_response(happy_transcript("done")))
  let handle = gateway.request(two_provider_gateway(transport), main_request())
  let drain = stream.watch_drain(handle)
  let assert Ok(owner) = process.receive(owner_ready, within: 1000)

  stream.cancel(handle)
  let assert Ok(Nil) = process.receive(cancelled, within: 2500)
    as "the cancellation deadline must reach the terminal attempt"
  let assert Ok(#(_deltas, stream.Settled(..))) =
    stream.await_terminal(handle, within: 1000)

  assert stream.await_drain_forever(drain) == stream.Drained
  assert !process.is_alive(owner)
  assert process.receive(attempts, within: 0)
    == Ok("https://primary.test/v1/messages")
  assert process.receive(attempts, within: 100) == Error(Nil)
  assert stream.next(handle, within: 100) == Error(Nil)
}

/// Cancellation which crosses a retryable failure drains that attempt but
/// consumes the queued stop before a fallback can begin.
pub fn cancellation_racing_retryable_failure_stops_fallback_test() {
  let #(transport, attempts, owner_ready, cancelled) =
    terminal_race_transport([
      http.RequestFailed(reason: "overloaded during cancellation"),
    ])
  let handle = gateway.request(two_provider_gateway(transport), main_request())
  let drain = stream.watch_drain(handle)
  let assert Ok(owner) = process.receive(owner_ready, within: 1000)

  stream.cancel(handle)
  let assert Ok(Nil) = process.receive(cancelled, within: 2500)
    as "the cancellation deadline must reach the retryable attempt"
  let assert Ok(#([], terminal)) = stream.await_terminal(handle, within: 1000)
  assert case bare_event(terminal) {
    stream.Failed(stream.ProviderCancelled, _)
    | stream.Failed(stream.CancellationUnconfirmed, _) -> True
    _ -> False
  }
    as "the retryable error must not escape the cancellation race"

  assert stream.await_drain_forever(drain) == stream.Drained
  assert !process.is_alive(owner)
  assert process.receive(attempts, within: 0)
    == Ok("https://primary.test/v1/messages")
  assert process.receive(attempts, within: 100) == Error(Nil)
  assert stream.next(handle, within: 100) == Error(Nil)
}

// The primary publishes its complete terminal script, then withholds the
// owner's Down until cancellation reaches the transport capability. This
// forces the guard to arbitrate a real terminal/cancel crossing instead of a
// test-authored order where one side has already completed.
fn terminal_race_transport(
  primary_events: List(http.HttpEvent),
) -> #(
  http.Transport,
  process.Subject(String),
  process.Subject(process.Pid),
  process.Subject(Nil),
) {
  let attempts = process.new_subject()
  let owner_ready = process.new_subject()
  let cancelled = process.new_subject()
  let transport =
    http.Transport(prepare_streaming: fn(request, events) {
      let creator = process.self()
      let controls_ready = process.new_subject()
      let owner =
        process.spawn_unlinked(fn() {
          let begin = process.new_subject()
          let release = process.new_subject()
          let creator_monitor = process.monitor(creator)
          process.send(controls_ready, #(begin, release))
          let admitted =
            process.new_selector()
            |> process.select_map(begin, fn(_nil) { True })
            |> process.select_specific_monitor(creator_monitor, fn(_down) {
              False
            })
            |> process.selector_receive_forever()
          process.demonitor_process(creator_monitor)
          case admitted {
            False -> Nil
            True -> {
              process.send(attempts, request.url)
              case string.contains(request.url, "primary.test") {
                True -> {
                  list.each(primary_events, fn(event) {
                    process.send(events, event)
                  })
                  process.send(owner_ready, process.self())
                  let _release = process.receive_forever(release)
                  Nil
                }
                False ->
                  list.each(
                    fixture.ok_response(happy_transcript("unexpected fallback")),
                    fn(event) { process.send(events, event) },
                  )
              }
            }
          }
        })
      let #(begin, release) = process.receive_forever(controls_ready)
      Ok(
        http.PreparedRequest(
          running: http.RunningRequest(owner:, cancel: fn() {
            process.send(cancelled, Nil)
            process.send(release, Nil)
          }),
          begin: fn() { process.send(begin, Nil) },
        ),
      )
    })
  #(transport, attempts, owner_ready, cancelled)
}

pub fn transport_prepare_crash_fails_closed_test() {
  let crashing =
    http.Transport(prepare_streaming: fn(_request, _events) {
      panic as "transport seam crashed"
    })
  let handle = gateway.request(two_provider_gateway(crashing), main_request())
  let assert Ok(#([], stream.Failed(error, _))) =
    stream.await_terminal(handle, within: 1000)
  let assert stream.TransportFailed(..) = stream.underlying_error(error)
    as "context preserves the exact underlying failure"
}

pub fn abnormal_transport_owner_reports_lost_drain_proof_test() {
  let transport =
    http.Transport(prepare_streaming: fn(_request, _events) {
      let creator = process.self()
      let ready = process.new_subject()
      let owner =
        process.spawn_unlinked(fn() {
          let begin = process.new_subject()
          let creator_monitor = process.monitor(creator)
          process.send(ready, begin)
          let _permit =
            process.new_selector()
            |> process.select_map(begin, fn(_nil) { Nil })
            |> process.select_specific_monitor(creator_monitor, fn(_down) {
              Nil
            })
            |> process.selector_receive_forever()
          process.demonitor_process(creator_monitor)
          process.kill(process.self())
        })
      let begin = process.receive_forever(ready)
      Ok(
        http.PreparedRequest(
          running: http.RunningRequest(owner:, cancel: fn() { Nil }),
          begin: fn() { process.send(begin, Nil) },
        ),
      )
    })
  let handle = gateway.request(two_provider_gateway(transport), main_request())
  let assert Ok(#([], stream.Failed(error, _))) =
    stream.await_terminal(handle, within: 1000)
  let assert stream.DrainProofLost = stream.underlying_error(error)
    as "context preserves the exact underlying failure"
}

/// Only the guard classifies the active attempt when the pump dies without
/// authoring a terminal of its own. A transport owner that exited abnormally
/// destroyed the proof that its native work stopped, so the request must
/// surface `DrainProofLost` rather than the retryable transport failure a
/// clean drain would have earned.
pub fn abnormal_attempt_owner_outlives_a_dead_pump_test() {
  let registered = process.new_subject()
  let transport =
    http.Transport(prepare_streaming: fn(_request, _events) {
      // The owner is dead before it is ever published, so the guard's own
      // monitor reports the abnormal exit rather than a completion.
      let owner = process.spawn_unlinked(fn() { process.kill(process.self()) })
      let gone = process.monitor(owner)
      let _down =
        process.new_selector()
        |> process.select_specific_monitor(gone, fn(_down) { Nil })
        |> process.selector_receive(1000)
      process.demonitor_process(gone)
      Ok(http.PreparedRequest(
        running: http.RunningRequest(owner:, cancel: fn() { Nil }),
        // Crashing here rather than in `prepare_streaming` is what makes
        // this test different from the one above: the attempt has already
        // been registered and adopted, so the guard holds a monitor whose
        // verdict nothing else can supply once the pump is gone.
        begin: fn() {
          process.send(registered, Nil)
          panic as "transport begin crashed after registration"
        },
      ))
    })
  let handle = gateway.request(two_provider_gateway(transport), main_request())
  assert process.receive(registered, within: 1000) == Ok(Nil)
  let assert Ok(#([], stream.Failed(error, _))) =
    stream.await_terminal(handle, within: 2500)
  let assert stream.DrainProofLost = stream.underlying_error(error)
    as "context preserves the exact underlying failure"
}

pub fn cancellation_during_transport_start_keeps_drain_witness_test() {
  let entered = process.new_subject()
  let owners = process.new_subject()
  let cancelled = process.new_subject()
  let transport =
    http.Transport(prepare_streaming: fn(_request, _events) {
      let ready = process.new_subject()
      let owner =
        process.spawn_unlinked(fn() {
          let release = process.new_subject()
          process.send(ready, release)
          let _release = process.receive_forever(release)
          Nil
        })
      let release = process.receive_forever(ready)
      let start_gate = process.new_subject()
      process.send(owners, #(owner, release))
      Ok(
        http.PreparedRequest(
          running: http.RunningRequest(owner:, cancel: fn() {
            process.send(cancelled, Nil)
            process.send(start_gate, Nil)
          }),
          begin: fn() {
            process.send(entered, start_gate)
            let _release_start = process.receive_forever(start_gate)
            Nil
          },
        ),
      )
    })
  let handle = gateway.request(two_provider_gateway(transport), main_request())
  let drain_witness = stream.watch_drain(handle)
  let assert Ok(start_gate) = process.receive(entered, within: 1000)
  stream.cancel(handle)
  assert stream.await_drain(drain_witness, within: 20) == stream.TimedOut
  let assert Ok(#([], stream.Failed(error, _))) =
    stream.await_terminal(handle, within: 2500)
  let assert stream.CancellationUnconfirmed = stream.underlying_error(error)
    as "context preserves the exact underlying failure"
  assert list.any(stream.failure_context(error), fn(context) {
    context.cause == stream.CancellationRequested
  })
    as "the bounded terminal retains the observed cancel before late retirement"
  process.send(start_gate, Nil)
  let assert Ok(#(owner, release)) = process.receive(owners, within: 1000)
  let assert Ok(Nil) = process.receive(cancelled, within: 1000)

  assert process.is_alive(owner)
  assert stream.await_drain(drain_witness, within: 20) == stream.TimedOut
  process.send(release, Nil)
  assert stream.await_drain_forever(drain_witness) == stream.Drained
}

/// A request which finishes preparation after cancellation expires must not
/// wait for a guard permit which can no longer arrive. The guard keeps the
/// ownership frontier open, adopts the late transport, and rejects its begin
/// permit before waiting for the pump to drain.
pub fn cancellation_expiry_rejects_late_attempt_registration_test() {
  let prepare_entered = process.new_subject()
  let cancelled = process.new_subject()
  let started = process.new_subject()
  let transport =
    http.Transport(prepare_streaming: fn(_request, _events) {
      let release_prepare = process.new_subject()
      process.send(prepare_entered, release_prepare)
      let _release = process.receive_forever(release_prepare)
      let owner_ready = process.new_subject()
      let owner =
        process.spawn_unlinked(fn() {
          let begin = process.new_subject()
          let stop = process.new_subject()
          process.send(owner_ready, #(begin, stop))
          let admitted =
            process.new_selector()
            |> process.select_map(begin, fn(_nil) { True })
            |> process.select_map(stop, fn(_nil) { False })
            |> process.selector_receive_forever()
          case admitted {
            True -> process.send(started, Nil)
            False -> process.send(cancelled, Nil)
          }
        })
      let #(begin, stop) = process.receive_forever(owner_ready)
      Ok(
        http.PreparedRequest(
          running: http.RunningRequest(owner:, cancel: fn() {
            process.send(stop, Nil)
          }),
          begin: fn() { process.send(begin, Nil) },
        ),
      )
    })
  let handle = gateway.request(two_provider_gateway(transport), main_request())
  let drain = stream.watch_drain(handle)
  let assert Ok(release_prepare) =
    process.receive(prepare_entered, within: 1000)

  stream.cancel(handle)
  let assert Ok(#([], stream.Failed(error, _))) =
    stream.await_terminal(handle, within: 2500)
  let assert stream.CancellationUnconfirmed = stream.underlying_error(error)
    as "context preserves the exact underlying failure"
  process.send(release_prepare, Nil)

  assert process.receive(cancelled, within: 1000) == Ok(Nil)
  assert process.receive(started, within: 100) == Error(Nil)
  assert stream.await_drain(drain, within: 1000) == stream.Drained
}

/// A rejected registration after expiry must retain cancellation semantics;
/// otherwise its normal owner Down looks retryable and starts the fallback.
pub fn cancellation_rejected_registration_stays_terminal_test() {
  let prepare_entered = process.new_subject()
  let prepared = process.new_subject()
  let cancelled = process.new_subject()
  let transport =
    http.Transport(prepare_streaming: fn(request, _events) {
      process.send(prepared, request.url)
      let release_prepare = process.new_subject()
      process.send(prepare_entered, release_prepare)
      let _release = process.receive_forever(release_prepare)
      let owner_ready = process.new_subject()
      let owner =
        process.spawn_unlinked(fn() {
          let begin = process.new_subject()
          let stop = process.new_subject()
          process.send(owner_ready, #(begin, stop))
          let admitted =
            process.new_selector()
            |> process.select_map(begin, fn(_nil) { True })
            |> process.select_map(stop, fn(_nil) { False })
            |> process.selector_receive_forever()
          case admitted {
            True -> Nil
            False -> process.send(cancelled, Nil)
          }
        })
      let #(begin, stop) = process.receive_forever(owner_ready)
      Ok(
        http.PreparedRequest(
          running: http.RunningRequest(owner:, cancel: fn() {
            process.send(stop, Nil)
          }),
          begin: fn() { process.send(begin, Nil) },
        ),
      )
    })
  let handle = gateway.request(two_provider_gateway(transport), main_request())
  let drain = stream.watch_drain(handle)
  assert process.receive(prepared, within: 1000)
    == Ok("https://primary.test/v1/messages")
  let assert Ok(release_prepare) =
    process.receive(prepare_entered, within: 1000)

  stream.cancel(handle)
  let assert Ok(#([], stream.Failed(error, _))) =
    stream.await_terminal(handle, within: 2500)
  let assert stream.CancellationUnconfirmed = stream.underlying_error(error)
    as "context preserves the exact underlying failure"
  process.send(release_prepare, Nil)
  assert process.receive(cancelled, within: 1000) == Ok(Nil)
  assert stream.await_drain(drain, within: 1000) == stream.Drained
  assert process.receive(prepared, within: 100) == Error(Nil)
}

pub fn retryable_terminal_does_not_fallback_before_transport_drains_test() {
  let attempts = process.new_subject()
  let ready = process.new_subject()
  let transport =
    http.Transport(prepare_streaming: fn(request, events) {
      let owner_ready = process.new_subject()
      let owner =
        process.spawn_unlinked(fn() {
          let begin = process.new_subject()
          let release = process.new_subject()
          process.send(owner_ready, #(begin, release))
          let _permit = process.receive_forever(begin)
          case string.contains(request.url, "primary.test") {
            True -> {
              process.send(events, http.RequestFailed(reason: "overloaded"))
              process.receive_forever(release)
            }
            False -> {
              list.each(
                fixture.ok_response(happy_transcript("From backup")),
                fn(event) { process.send(events, event) },
              )
            }
          }
        })
      let #(begin, release) = process.receive_forever(owner_ready)
      case string.contains(request.url, "primary.test") {
        True -> process.send(ready, #(owner, release))
        False -> Nil
      }
      Ok(
        http.PreparedRequest(
          running: http.RunningRequest(owner:, cancel: fn() { Nil }),
          begin: fn() {
            process.send(attempts, request.url)
            process.send(begin, Nil)
          },
        ),
      )
    })
  let handle = gateway.request(two_provider_gateway(transport), main_request())
  let drain_witness = stream.watch_drain(handle)
  let assert Ok(#(owner, release)) = process.receive(ready, within: 1000)

  assert process.is_alive(owner)
  assert process.receive(attempts, within: 1000)
    == Ok("https://primary.test/v1/messages")
  assert process.receive(attempts, within: 100) == Error(Nil)
  assert stream.next(handle, within: 100) == Error(Nil)
  process.send(release, Nil)
  assert process.receive(attempts, within: 1000)
    == Ok("https://backup.test/v1/messages")
  let assert Ok(#(_deltas, stream.Settled(..))) =
    stream.await_terminal(handle, within: 1000)
  assert stream.await_drain_forever(drain_witness) == stream.Drained
}

pub fn consumer_death_cancels_and_reaps_transport_test() {
  let ready = process.new_subject()
  let owners = process.new_subject()
  let cancelled = process.new_subject()
  let transport =
    http.Transport(prepare_streaming: fn(_request, _events) {
      let owner =
        process.spawn_unlinked(fn() {
          process.receive_forever(process.new_subject())
        })
      process.send(owners, owner)
      Ok(
        http.PreparedRequest(
          running: http.RunningRequest(owner:, cancel: fn() {
            process.send(cancelled, Nil)
            process.kill(owner)
          }),
          begin: fn() { Nil },
        ),
      )
    })
  let consumer =
    process.spawn_unlinked(fn() {
      let _handle =
        gateway.request(two_provider_gateway(transport), main_request())
      process.send(ready, Nil)
      process.receive_forever(process.new_subject())
    })
  assert process.receive(ready, within: 1000) == Ok(Nil)
  let assert Ok(transport_owner) = process.receive(owners, within: 1000)
  let transport_monitor = process.monitor(transport_owner)
  process.kill(consumer)
  assert process.receive(cancelled, within: 1000) == Ok(Nil)
  assert process.new_selector()
    |> process.select_specific_monitor(transport_monitor, fn(_down) { True })
    |> process.selector_receive(1000)
    == Ok(True)
}

pub fn unroutable_role_fails_in_band_test() {
  let gw = two_provider_gateway(fixture.transport([]))
  let request =
    model.ProviderRequest(
      ..main_request(),
      target: model.ForRole(model.Vision, None),
    )
  let handle = gateway.request(gw, request)
  let assert Ok(#([], stream.Failed(error, _))) =
    stream.await_terminal(handle, within: 2000)
  let assert stream.NoIdentity(role: "vision") = stream.underlying_error(error)
    as "context preserves the exact underlying failure"
}

// --- the reasoning-budget overlay (protocol-change/009) --------------------
//
// A role walk may reach a target whose route row declares a different
// reasoning budget than the head's. `ForRole.thinking` decides which
// budget every attempt is made at: `Some(level)` overlays that level onto
// the whole chain, `None` leaves each entry's own. Both halves are pinned
// here because the wire cost of getting either wrong is silent — a turn
// that asked to think hard settling on a fallback that thought not at all.

// Main's chain with the two ends declaring *different* static levels, so
// an overlay and an absent overlay cannot produce the same bytes.
fn thinking_chain_gateway(transport: http.Transport) -> gateway.Gateway {
  two_provider_gateway(transport)
  |> gateway.route(model.Main, [
    model.ResolvedModel(
      ..target("primary", "model-a"),
      thinking: model.ThinkingHigh,
    ),
    model.ResolvedModel(
      ..target("backup", "model-b"),
      thinking: model.ThinkingOff,
    ),
  ])
}

// Every request body the walk put on the wire, in attempt order. The
// subject is owned by the calling test process, so the pump's sends queue
// in its own mailbox and can be drained after the terminal arrives.
fn walk_bodies(thinking: option.Option(model.ThinkingLevel)) -> List(String) {
  let bodies = process.new_subject()
  let transport =
    fixture.routing_transport(fn(request: http.HttpRequest) {
      process.send(bodies, request.body)
      case string.contains(request.url, "primary.test") {
        True -> overloaded_response()
        False -> fixture.ok_response(happy_transcript("From backup"))
      }
    })
  let request =
    model.ProviderRequest(
      ..main_request(),
      target: model.ForRole(model.Main, thinking),
    )
  let handle = gateway.request(thinking_chain_gateway(transport), request)
  let assert Ok(#(_deltas, stream.Settled(..))) =
    stream.await_terminal(handle, within: 2000)
    as "the walk must reach backup and settle"
  drain(bodies, [])
}

fn drain(subject: process.Subject(String), seen: List(String)) -> List(String) {
  case process.receive(subject, within: 500) {
    Ok(body) -> drain(subject, [body, ..seen])
    Error(Nil) -> list.reverse(seen)
  }
}

pub fn for_role_overlays_one_thinking_level_on_every_attempt_test() {
  // The head declares high and the fallback declares off; a turn asking
  // for medium must reach *both* at medium.
  let assert [head, fallback] = walk_bodies(Some(model.ThinkingMedium))
    as "the walk must have attempted both targets"
  assert string.contains(head, "\"budget_tokens\":8192")
  assert string.contains(fallback, "\"budget_tokens\":8192")
}

pub fn for_role_without_an_overlay_uses_each_entrys_own_level_test() {
  let assert [head, fallback] = walk_bodies(None)
    as "the walk must have attempted both targets"
  // The head's own declared high…
  assert string.contains(head, "\"budget_tokens\":16384")
  // …and the fallback's own off, which sends no thinking field at all.
  assert !string.contains(fallback, "budget_tokens")
  assert !string.contains(fallback, "\"thinking\"")
}

pub fn for_resolved_dispatches_exactly_once_test() {
  // ForResolved never falls back, even on a retryable failure.
  let transport =
    fixture.routing_transport(fn(request) {
      case string.contains(request.url, "primary.test") {
        True -> overloaded_response()
        False -> fixture.ok_response(happy_transcript("From backup"))
      }
    })
  let request =
    model.ProviderRequest(
      ..main_request(),
      target: model.ForResolved(target("primary", "model-a")),
    )
  let handle = gateway.request(two_provider_gateway(transport), request)
  let assert Ok(#([], stream.Failed(error, _))) =
    stream.await_terminal(handle, within: 2000)
  let assert stream.HttpError(status: 529, ..) = stream.underlying_error(error)
    as "context preserves the exact underlying failure"
}

pub fn missing_secret_fails_with_name_only_test() {
  let gw =
    gateway.new(
      transport: fixture.transport([]),
      secrets: secret.from_list([]),
      clock: clock.fixed(at: 0),
    )
    |> gateway.add_provider(gateway.AnthropicProvider(
      name: "anthropic",
      base_url: "https://api.anthropic.com",
      api_key_secret: "ANTHROPIC_API_KEY",
    ))
    |> gateway.route(model.Main, [target("anthropic", "model-a")])
  let handle = gateway.request(gw, main_request())
  let assert Ok(#([], stream.Failed(error, _))) =
    stream.await_terminal(handle, within: 2000)
  assert stream.underlying_error(error)
    == stream.NoSecret(provider: "anthropic", secret_name: "ANTHROPIC_API_KEY")
}

pub fn unknown_provider_in_resolved_identity_fails_in_band_test() {
  let gw = two_provider_gateway(fixture.transport([]))
  let request =
    model.ProviderRequest(
      ..main_request(),
      target: model.ForResolved(target("ghost", "phantom-model")),
    )
  let handle = gateway.request(gw, request)
  let assert Ok(#([], stream.Failed(error, _))) =
    stream.await_terminal(handle, within: 2000)
  let assert stream.UnknownProvider(provider: "ghost") =
    stream.underlying_error(error)
    as "context preserves the exact underlying failure"
}

// --- secret leak scan --------------------------------------------------------

pub fn secret_never_appears_in_any_produced_structure_test() {
  // A full fixture session: resolve, dispatch, stream, settle — then a
  // failing run for the error path. The secret must appear in NO
  // returned or accumulated structure's rendered debug output.
  let gw =
    two_provider_gateway(
      fixture.transport(fixture.ok_response(happy_transcript("Hello"))),
    )
  let resolve_result = gateway.resolve(gw, model.Main)
  let handle = gateway.request(gw, main_request())
  let assert Ok(#(deltas, terminal)) =
    stream.await_terminal(handle, within: 2000)

  let failing = two_provider_gateway(fixture.transport(overloaded_response()))
  let failed_handle = gateway.request(failing, main_request())
  let assert Ok(#(failed_deltas, failed_terminal)) =
    stream.await_terminal(failed_handle, within: 2000)

  let rendered =
    fixture.rendered(#(
      resolve_result,
      deltas,
      terminal,
      failed_deltas,
      failed_terminal,
    ))
  assert !string.contains(rendered, secret_value)
  assert !string.contains(rendered, "sk-backup-key")
  // Sanity: the scan corpus is not empty.
  assert string.length(rendered) > 100
}

pub fn described_errors_never_carry_the_secret_test() {
  let failing = two_provider_gateway(fixture.transport(overloaded_response()))
  let handle = gateway.request(failing, main_request())
  let assert Ok(#(_deltas, stream.Failed(error, _))) =
    stream.await_terminal(handle, within: 2000)
  assert !string.contains(stream.describe_error(error), secret_value)
}

fn bare_event(event) {
  case event {
    stream.Failed(error, report) ->
      stream.Failed(stream.underlying_error(error), report)
    _ -> event
  }
}

// Each attempt budgets the original history against its own model's limit.
// A larger fallback must not inherit the smaller head's discarded pixels.
pub fn fallback_attempts_apply_their_own_image_limits_test() {
  list.each([#(3, 5), #(5, 3)], fn(limits) {
    let bodies = process.new_subject()
    let transport =
      fixture.routing_transport(fn(request: http.HttpRequest) {
        process.send(bodies, request.body)
        case string.contains(request.url, "primary.test") {
          True -> overloaded_response()
          False -> fixture.ok_response(happy_transcript("From backup"))
        }
      })
    let gw =
      two_provider_gateway(transport)
      |> gateway.with_image_limit("primary", "model-a", limits.0)
      |> gateway.with_image_limit("backup", "model-b", limits.1)
    let old = list.map([1, 2, 3, 4, 5, 6], fn(n) { budget_prompt([n]) })
    let request =
      model.ProviderRequest(
        ..main_request(),
        messages: list.append(old, [budget_prompt([7, 8])]),
      )
    let handle = gateway.request(gw, request)
    let assert Ok(#(_, stream.Settled(..))) =
      stream.await_terminal(handle, within: 2000)
      as "the request must settle through fallback"
    let assert [head, fallback] = drain(bodies, [])
      as "both actual dispatch bodies must be inspected"
    assert list.length(string.split(head, "\"type\":\"image\"")) - 1 == limits.0
    assert list.length(string.split(fallback, "\"type\":\"image\"")) - 1
      == limits.1
    list.each([head, fallback], fn(body) {
      assert string.contains(body, "Bwg=")
      assert string.contains(body, "omitted from this request")
    })
  })
}

fn budget_prompt(images: List(Int)) -> message.AgentMessage {
  // Two adjacent bytes form a single image in this wire fixture. The final
  // prompt has one image, and its sentinel must survive every fallback.
  message.UserMessage(
    content: [
      message.UserImage(
        bit_array.base64_encode(
          bit_array.concat(list.map(images, fn(n) { <<n>> })),
          True,
        ),
        "image/png",
      ),
    ],
    timestamp: 0,
    origin: Some(message.Origin("owner", "Owner")),
  )
}

pub fn oversized_active_image_turn_never_opens_transport_test() {
  let bodies = process.new_subject()
  let transport =
    fixture.routing_transport(fn(request: http.HttpRequest) {
      process.send(bodies, request.body)
      fixture.ok_response(happy_transcript("must not run"))
    })
  let gw = two_provider_gateway(transport)
  let request =
    model.ProviderRequest(..main_request(), messages: [
      message.UserMessage(
        content: list.map([1, 2, 3, 4, 5, 6, 7, 8, 9], fn(n) {
          message.UserImage(bit_array.base64_encode(<<n>>, True), "image/png")
        }),
        timestamp: 0,
        origin: Some(message.Origin("owner", "Owner")),
      ),
    ])
  let handle = gateway.request(gw, request)
  let assert Ok(#([], stream.Failed(error:, accounting: _))) =
    stream.await_terminal(handle, within: 2000)
    as "the default eight-image limit must refuse nine active images locally"
  let assert stream.StreamError(api_error_type: "image_limit", message:) =
    stream.underlying_error(error)
    as "image limits are terminal local failures"
  assert string.contains(message, "current turn contains 9 images")
  assert process.receive(bodies, within: 0) == Error(Nil)
}

// These Responses scripts report complete, disjoint usage buckets. The first
// output includes three reasoning tokens; they remain a subset of its five
// output tokens rather than an additional charge.
fn measured_failure_transcript() -> String {
  sse_event(
    "response.failed",
    "{\"type\":\"response.failed\",\"response\":{\"id\":\"failed_attempt\",\"model\":\"model-a\",\"status\":\"failed\",\"error\":{\"code\":\"server_error\"},\"usage\":{\"input_tokens\":12,\"output_tokens\":5,\"total_tokens\":17,\"input_tokens_details\":{\"cached_tokens\":2},\"output_tokens_details\":{\"reasoning_tokens\":3}}}}",
  )
}

fn measured_success_transcript() -> String {
  sse_event(
    "response.created",
    "{\"type\":\"response.created\",\"response\":{\"id\":\"successful_attempt\",\"model\":\"model-b\",\"status\":\"in_progress\",\"output\":[]}}",
  )
  <> sse_event(
    "response.completed",
    "{\"type\":\"response.completed\",\"response\":{\"id\":\"successful_attempt\",\"model\":\"model-b\",\"status\":\"completed\",\"output\":[],\"error\":null,\"usage\":{\"input_tokens\":20,\"output_tokens\":7,\"total_tokens\":27,\"input_tokens_details\":{\"cached_tokens\":4}}}}",
  )
}

fn measured_failure_usage() -> message.Usage {
  message.Usage(
    ..accounting.zero_usage(),
    input: 10,
    cache_read: 2,
    output: 5,
    reasoning: Some(3),
    total_tokens: 17,
    evidence: usage_evidence.reported(usage_evidence.Api),
  )
  |> pricing.price(pricing.Pricing(2.0, 3.0, 1.0, 0.0))
}

fn mixed_accounting_gateway(
  public: http.Transport,
  bridge: gateway.CodexTransport,
) -> gateway.Gateway {
  gateway.new(public, secrets(), clock.fixed(123))
  |> gateway.add_provider(gateway.OpenAiResponsesProvider(
    name: "primary",
    base_url: "https://primary.test/v1",
    api_key_secret: "PRIMARY_KEY",
  ))
  |> gateway.add_provider(gateway.CodexSubscriptionProvider(
    name: "subscription",
    profile: "personal",
  ))
  |> gateway.with_codex_transport(bridge)
  |> gateway.route(model.Main, [
    target("primary", "model-a"),
    target("subscription", "model-b"),
  ])
  |> gateway.price("primary", pricing.Pricing(2.0, 3.0, 1.0, 0.0))
  |> gateway.price("subscription", pricing.Pricing(5.0, 7.0, 2.0, 0.0))
  |> gateway.with_attempt_timeout(2000)
}

pub fn fallback_retains_each_actual_target_price_and_final_context_usage_test() {
  let requests = process.new_subject()
  let public =
    fixture.routing_transport(fn(sent) {
      process.send(requests, sent.url)
      fixture.ok_response(measured_failure_transcript())
    })
  let bridge =
    gateway.CodexTransport(prepare_streaming: fn(profile, sent, events) {
      process.send(requests, profile <> sent.url)
      let http.Transport(prepare_streaming:) =
        fixture.transport(fixture.ok_response(measured_success_transcript()))
      prepare_streaming(sent, events)
    })
  let handle =
    gateway.request(mixed_accounting_gateway(public, bridge), main_request())
  let assert Ok(#([], stream.Settled(settled, report))) =
    stream.await_terminal(handle, within: 2000)
    as "the retryable measured failure must reach the subscription fallback"
  let assert message.AssistantMessage(usage: last, api:, provider:, ..) =
    stream.message(settled)
    as "the final message retains the actual successful target"
  let total = accounting.total(report)

  // The request total counts both attempts exactly once. Context overflow
  // decisions still receive only the final attempt's twenty prompt tokens.
  assert accounting.attempts(report) == 2
  assert accounting.last(report) == Some(last)
  assert #(total.input, total.cache_read, total.output, total.total_tokens)
    == #(26, 6, 12, 44)
  assert total.reasoning == Some(3)
  assert #(last.input, last.cache_read, last.output, last.total_tokens)
    == #(16, 4, 7, 27)
  assert #(api, provider) == #("codex-subscription", "subscription")
  assert last.evidence
    == usage_evidence.with_price(
      usage_evidence.reported(usage_evidence.ChatGptPlan),
      usage_evidence.ChatGptReferenceRates,
    )

  // Each card applies before aggregation. Subscription prices are reference
  // estimates and cannot be presented as ChatGPT plan charges or allowances.
  let expected_last =
    message.Usage(
      ..accounting.zero_usage(),
      input: 16,
      cache_read: 4,
      output: 7,
      total_tokens: 27,
      evidence: usage_evidence.reported(usage_evidence.ChatGptPlan),
    )
    |> pricing.price(pricing.Pricing(5.0, 7.0, 2.0, 0.0))
  assert last == expected_last
  assert total == accounting.add_usage(measured_failure_usage(), expected_last)
  assert total.evidence
    == usage_evidence.Remote(
      usage_evidence.Other,
      usage_evidence.Reported(
        usage_evidence.Complete,
        usage_evidence.Priced(
          usage_evidence.Complete,
          usage_evidence.MixedRates,
        ),
      ),
    )
  assert process.receive(requests, within: 0)
    == Ok("https://primary.test/v1/responses")
  assert process.receive(requests, within: 0) == Ok("personal/responses")
  assert process.receive(requests, within: 0) == Error(Nil)
}

pub fn fallback_owner_loss_retains_measured_prefix_and_unknown_attempt_test() {
  let entered = process.new_subject()
  let public =
    fixture.transport(fixture.ok_response(measured_failure_transcript()))
  let bridge =
    gateway.CodexTransport(prepare_streaming: fn(_profile, _sent, _events) {
      // This is the existing abnormal-owner failure shape, reached only after
      // a real first terminal has been drained and handed to the guard.
      let owner = process.spawn_unlinked(fn() { process.kill(process.self()) })
      let gone = process.monitor(owner)
      let _down =
        process.new_selector()
        |> process.select_specific_monitor(gone, fn(_down) { Nil })
        |> process.selector_receive(1000)
      process.demonitor_process(gone)
      Ok(
        http.PreparedRequest(
          running: http.RunningRequest(owner:, cancel: fn() { Nil }),
          begin: fn() {
            process.send(entered, Nil)
            panic as "fallback begin crashed after registration"
          },
        ),
      )
    })
  let handle =
    gateway.request(mixed_accounting_gateway(public, bridge), main_request())
  assert process.receive(entered, within: 1000) == Ok(Nil)
  let assert Ok(#([], stream.Failed(error, report))) =
    stream.await_terminal(handle, within: 2500)
    as "the guard must settle the failed fallback with its retained prefix"
  assert stream.underlying_error(error) == stream.DrainProofLost
  let total = accounting.total(report)
  let assert Some(last) = accounting.last(report)
    as "the admitted fallback is retained as an unknown attempt"

  // The known first attempt is a lower bound, not a complete request bill.
  // An unknown fallback cannot disappear as a free or undispatched attempt.
  assert accounting.attempts(report) == 2
  assert #(total.input, total.cache_read, total.output, total.total_tokens)
    == #(10, 2, 5, 17)
  assert total.cost == measured_failure_usage().cost
  assert total.evidence
    == usage_evidence.Remote(
      usage_evidence.Other,
      usage_evidence.Reported(
        usage_evidence.Partial,
        usage_evidence.Priced(usage_evidence.Partial, usage_evidence.ApiRates),
      ),
    )
  assert last.evidence == usage_evidence.unknown(usage_evidence.ChatGptPlan)
}

pub fn local_secret_refusal_has_empty_accounting_and_never_prepares_transport_test() {
  let prepared = process.new_subject()
  let transport =
    http.Transport(prepare_streaming: fn(request, events) {
      process.send(prepared, Nil)
      let http.Transport(prepare_streaming:) = fixture.transport([])
      prepare_streaming(request, events)
    })
  let gw =
    gateway.new(transport, secret.from_list([]), clock.fixed(0))
    |> gateway.add_provider(gateway.OpenAiResponsesProvider(
      name: "primary",
      base_url: "https://primary.test/v1",
      api_key_secret: "MISSING_KEY",
    ))
    |> gateway.route(model.Main, [target("primary", "model-a")])
  let handle = gateway.request(gw, main_request())
  let assert Ok(#([], stream.Failed(error, report))) =
    stream.await_terminal(handle, within: 1000)
    as "missing credentials are refused before remote admission"
  assert stream.underlying_error(error)
    == stream.NoSecret("primary", "MISSING_KEY")
  assert report == accounting.empty()
  assert accounting.attempts(report) == 0
  assert accounting.last(report) == None
  assert accounting.total(report).evidence == usage_evidence.none()
  assert process.receive(prepared, within: 0) == Error(Nil)
}

pub fn cyber_access_fallback_uses_each_entry_and_denial_stops_test() {
  list.each([403, 503], fn(status) {
    let observed = process.new_subject()
    let transport =
      fixture.routing_transport(fn(sent) {
        process.send(observed, sent)
        case sent.url {
          "https://blue.test/v1/responses" ->
            fixture.error_response(
              status,
              [],
              "{\"error\":{\"type\":\"permission_error\",\"code\":\"access_program_not_enabled\"}}",
            )
          "https://plain.test/v1/responses" ->
            fixture.ok_response(responses_transcript())
          _other -> fixture.error_response(400, [], "{}")
        }
      })
    let configured =
      gateway.new(transport, secrets(), clock.fixed(123))
      |> gateway.add_provider(gateway.OpenAiResponsesProvider(
        name: "blue",
        base_url: "https://blue.test/v1",
        api_key_secret: "PRIMARY_KEY",
      ))
      |> gateway.add_provider(gateway.OpenAiResponsesProvider(
        name: "plain",
        base_url: "https://plain.test/v1",
        api_key_secret: "BACKUP_KEY",
      ))
      |> gateway.with_cyber_access("blue", model.DaybreakBlue)
      |> gateway.with_cyber_access("plain", model.StandardCyberAccess)
      |> gateway.route(model.Main, [
        target("blue", "model-b"),
        target("plain", "model-b"),
      ])
    let handle = gateway.request(configured, main_request())
    let assert Ok(#(_, terminal)) = stream.await_terminal(handle, within: 2000)
      as "The selected route must settle or refuse within the fixture deadline."
    let assert Ok(first) = process.receive(observed, within: 1000)
      as "The Daybreak head must be attempted."
    let assert Ok(first_body) = json.parse(first.body)
      as "The head body must parse."
    assert wire.field(first_body, "access_programs")
      == Ok(json.Object([#("cyber", json.String("daybreak_blue"))]))

    // A denied program is terminal. A retryable service failure may walk an
    // operator-configured fallback, whose own program must replace the head's.
    case status {
      403 -> {
        let assert stream.Failed(_, report) = terminal
          as "A Daybreak permission denial must remain a failure."
        assert accounting.attempts(report) == 1
        assert process.receive(observed, within: 20) == Error(Nil)
      }
      503 -> {
        let assert stream.Settled(_, report) = terminal
          as "A retryable failure must reach the configured fallback."
        assert accounting.attempts(report) == 2
        let assert Ok(second) = process.receive(observed, within: 1000)
          as "The fallback must actually execute."
        let assert Ok(second_body) = json.parse(second.body)
          as "The fallback body must parse."
        assert wire.field(second_body, "access_programs")
          == Ok(json.Object([#("cyber", json.String("standard"))]))
      }
      _other ->
        panic as "Only the permission and retryable statuses are exercised."
    }
  })
}
