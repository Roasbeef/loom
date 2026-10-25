//// The settlement observer: told once per admitted attempt, after pricing,
//// never for an attempt the request guard refused.
////
//// A guard that debits a worst case before each attempt relies on three
//// properties here. Every admitted attempt is reported exactly once, whatever
//// its end, or a reservation leaks. A refused attempt is never reported, or a
//// settlement arrives for a reservation that was never made. And the report
//// carries the usage the gateway priced, so the credit is computed from the
//// figure the ledger row will carry.

import core/clock
import core/message
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/string
import provider/fixture.{sse_event}
import provider/gateway
import provider/http
import provider/model
import provider/pricing
import provider/secret
import provider/stream

const key_value = "sk-primary-key"

fn target(provider: String, model_id: String) -> model.ResolvedModel {
  fixture.resolved(provider:, model_id:)
}

/// Ten input and four output tokens, settled with `end_turn`.
fn settled_transcript() -> String {
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
    "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"ok\"}}",
  )
  <> sse_event(
    "message_delta",
    "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":4}}",
  )
  <> sse_event("message_stop", "{\"type\":\"message_stop\"}")
}

fn card() -> pricing.Pricing {
  pricing.Pricing(input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.0)
}

/// Two Anthropic providers on one role, the primary priced, every attempt
/// reported to `settled`.
fn observed_gateway(
  transport: http.Transport,
  settled: process.Subject(gateway.AttemptSettled),
) -> gateway.Gateway {
  gateway.new(
    transport:,
    secrets: secret.from_list([
      #("PRIMARY_KEY", key_value),
      #("BACKUP_KEY", "sk-backup-key"),
    ]),
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
  |> gateway.price("primary", card())
  |> gateway.with_attempt_timeout(2000)
  |> gateway.with_attempt_settled(fn(report) { process.send(settled, report) })
}

fn request(target: model.RequestTarget) -> model.ProviderRequest {
  model.ProviderRequest(
    target:,
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

fn overloaded() -> List(http.HttpEvent) {
  fixture.error_response(
    529,
    [],
    "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}",
  )
}

pub fn a_settled_attempt_is_reported_once_with_its_priced_usage_test() {
  let settled = process.new_subject()
  let gw =
    observed_gateway(
      fixture.transport(fixture.ok_response(settled_transcript())),
      settled,
    )
  let handle =
    gateway.request(
      gw,
      request(model.ForResolved(target("primary", "model-a"))),
    )
  let assert Ok(#(_, stream.Settled(..))) =
    stream.await_terminal(handle, within: 2000)

  // One report, for the exact target and dialect, at walk position one.
  let assert Ok(report) = process.receive(settled, 1000)
    as "the admitted attempt is reported"
  assert report.target == target("primary", "model-a")
  assert report.api == "anthropic-messages"
  assert report.ordinal == 1
  assert report.ending == gateway.Responded(message.Stop)

  // The usage is the adapter's figure priced on the card, not a zero and
  // not an unpriced count.
  assert report.usage.input == 10 && report.usage.output == 4
  assert report.usage.cost == pricing.price(report.usage, card()).cost
  assert report.usage.cost.total >. 0.0
  assert process.receive(settled, 100) == Error(Nil)
    as "an attempt settles exactly once"
}

pub fn a_failed_attempt_is_reported_unanswered_test() {
  let settled = process.new_subject()
  let gw = observed_gateway(fixture.transport(overloaded()), settled)
  let handle =
    gateway.request(
      gw,
      request(model.ForResolved(target("primary", "model-a"))),
    )
  let assert Ok(#(_, stream.Failed(..))) =
    stream.await_terminal(handle, within: 2000)
  let assert Ok(report) = process.receive(settled, 1000)
    as "a failed attempt still settles"
  assert report.ending == gateway.Unanswered
  assert process.receive(settled, 100) == Error(Nil)
}

pub fn every_attempt_of_a_fallback_walk_is_reported_in_order_test() {
  let settled = process.new_subject()
  let transport =
    fixture.routing_transport(fn(http_request) {
      case string.contains(http_request.url, "primary.test") {
        True -> overloaded()
        False -> fixture.ok_response(settled_transcript())
      }
    })
  let gw = observed_gateway(transport, settled)
  let handle = gateway.request(gw, request(model.ForRole(model.Main, None)))
  let assert Ok(#(_, stream.Settled(..))) =
    stream.await_terminal(handle, within: 2000)

  // The overloaded primary is reported before the backup that answered;
  // each carries its own target and position.
  let assert Ok(first) = process.receive(settled, 1000)
  let assert Ok(second) = process.receive(settled, 1000)
  assert first.target == target("primary", "model-a")
    && first.ordinal == 1
    && first.ending == gateway.Unanswered
  assert second.target == target("backup", "model-b")
    && second.ordinal == 2
    && second.ending == gateway.Responded(message.Stop)
  assert process.receive(settled, 100) == Error(Nil)
}

pub fn an_attempt_the_guard_refuses_is_never_reported_test() {
  let settled = process.new_subject()
  let gw =
    observed_gateway(
      fixture.transport(fixture.ok_response(settled_transcript())),
      settled,
    )
    |> gateway.with_request_guard(fn(_target, _api, _request) {
      Error("aggregate reservation budget refused request")
    })
  let handle =
    gateway.request(
      gw,
      request(model.ForResolved(target("primary", "model-a"))),
    )
  let assert Ok(#(_, stream.Failed(error, _))) =
    stream.await_terminal(handle, within: 2000)
  let assert stream.StreamError(api_error_type: "request_admission", ..) =
    stream.underlying_error(error)
  assert process.receive(settled, 200) == Error(Nil)
    as "a refused attempt reserved nothing and settles nothing"
}

pub fn an_admitted_attempt_with_no_secret_is_still_reported_test() {
  // The secret lookup sits behind admission, so an attempt refused there has
  // reserved and must settle: one report, unanswered, with no usage.
  let settled = process.new_subject()
  let gw =
    gateway.new(
      transport: fixture.transport(fixture.ok_response(settled_transcript())),
      secrets: secret.from_list([]),
      clock: clock.fixed(at: 1_700_000_000_000),
    )
    |> gateway.add_provider(gateway.AnthropicProvider(
      name: "primary",
      base_url: "https://primary.test",
      api_key_secret: "PRIMARY_KEY",
    ))
    |> gateway.with_attempt_settled(fn(report) { process.send(settled, report) })
  let handle =
    gateway.request(
      gw,
      request(model.ForResolved(target("primary", "model-a"))),
    )
  let assert Ok(#(_, stream.Failed(..))) =
    stream.await_terminal(handle, within: 2000)
  let assert Ok(report) = process.receive(settled, 1000)
  assert report.ending == gateway.Unanswered
  assert report.usage.total_tokens == 0 && report.usage.cost.total == 0.0
  assert process.receive(settled, 100) == Error(Nil)
}
