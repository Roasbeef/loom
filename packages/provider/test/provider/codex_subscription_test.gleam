//// The subscription provider keeps credential custody outside the gateway.
//// These fixtures prove that an absent bridge opens no transport, and that a
//// present bridge receives only an uncredentialed relative Responses request.

import core/clock
import core/json
import core/message
import gleam/erlang/process
import gleam/option.{None, Some}
import provider/adapter/responses
import provider/fixture
import provider/gateway
import provider/http
import provider/internal/wire
import provider/model
import provider/secret
import provider/stream

fn target(provider: String) -> model.ResolvedModel {
  fixture.resolved(provider, "codex-model")
}

fn request(provider: String) -> model.ProviderRequest {
  fixture.request_for(target(provider))
}

fn done_transcript() -> String {
  fixture.sse_event(
    "response.created",
    "{\"type\":\"response.created\",\"response\":{\"id\":\"resp_1\",\"model\":\"codex-model\",\"status\":\"in_progress\",\"output\":[]}}",
  )
  <> fixture.sse_event(
    "response.done",
    "{\"type\":\"response.done\",\"response\":{\"id\":\"resp_1\",\"model\":\"codex-model\",\"status\":\"completed\",\"output\":[],\"error\":null,\"usage\":{\"input_tokens\":10,\"output_tokens\":4,\"total_tokens\":14}}}",
  )
}

fn gateway_without_bridge(public: http.Transport) -> gateway.Gateway {
  gateway.new(public, secret.from_list([]), clock.fixed(123))
  |> gateway.add_provider(gateway.CodexSubscriptionProvider(
    name: "codex",
    profile: "personal",
  ))
  |> gateway.route(model.Main, [target("codex")])
  |> gateway.with_attempt_timeout(2000)
}

pub fn subscription_body_and_route_exclude_credentials_and_output_cap_test() {
  let built =
    responses.build_subscription_request(
      target("codex"),
      model.ProviderRequest(..request("codex"), max_output_tokens: Some(123)),
    )
  assert built.method == "POST"
  assert built.url == "/responses"
  assert built.headers
    == [
      #("content-type", "application/json"),
      #("accept", "text/event-stream"),
    ]
  let assert Ok(body) = json.parse(built.body) as "body is valid JSON"
  assert wire.string_field(body, "model") == Ok("codex-model")
  assert wire.field(body, "max_output_tokens") == Error(Nil)
  assert wire.field(body, "tool_choice") == Error(Nil)
  assert wire.field(body, "parallel_tool_calls") == Error(Nil)
  assert wire.field(body, "store") == Ok(json.Bool(False))
  assert wire.field(body, "stream") == Ok(json.Bool(True))
}

pub fn missing_bridge_fails_locally_without_using_public_transport_test() {
  let public_requests = process.new_subject()
  let public =
    fixture.routing_transport(fn(sent) {
      process.send(public_requests, sent)
      fixture.ok_response(done_transcript())
    })
  let handle = gateway.request(gateway_without_bridge(public), request("codex"))
  let assert Ok(#([], stream.Failed(error))) =
    stream.await_terminal(handle, within: 2000)
    as "missing bridge must deliver one local failure"
  let assert stream.StreamError(api_error_type:, ..) =
    stream.underlying_error(error)
    as "missing bridge is a terminal configuration failure"
  assert api_error_type == "codex_transport_unavailable"
  assert process.receive(public_requests, within: 0) == Error(Nil)
}

pub fn subscription_dispatch_uses_bridge_profile_and_done_identity_test() {
  let public_requests = process.new_subject()
  let bridge_requests = process.new_subject()
  let public =
    fixture.routing_transport(fn(sent) {
      process.send(public_requests, sent)
      fixture.ok_response(done_transcript())
    })
  let bridge =
    gateway.CodexTransport(prepare_streaming: fn(profile, sent, events) {
      process.send(bridge_requests, #(profile, sent))
      let http.Transport(prepare_streaming:) =
        fixture.transport(fixture.ok_response(done_transcript()))
      prepare_streaming(sent, events)
    })
  let registered =
    gateway_without_bridge(public)
    |> gateway.with_codex_transport(bridge)
  let handle = gateway.request(registered, request("codex"))
  let assert Ok(#([], stream.Settled(message: settled, usage:))) =
    stream.await_terminal(handle, within: 2000)
    as "subscription bridge must settle the verified Codex terminal"
  let assert message.AssistantMessage(api:, provider:, model: model_id, ..) =
    stream.message(settled)
    as "subscription result has separate durable identity"
  assert #(api, provider, model_id)
    == #("codex-subscription", "codex", "codex-model")
  assert usage.output == 4
  let assert Ok(#("personal", sent)) =
    process.receive(bridge_requests, within: 1000)
    as "the bridge receives the profile separately from request headers"
  assert sent.url == "/responses"
  assert sent.headers
    == [
      #("content-type", "application/json"),
      #("accept", "text/event-stream"),
    ]
  assert process.receive(public_requests, within: 0) == Error(Nil)
}

pub fn subscription_done_is_rejected_by_public_responses_dialect_test() {
  let events =
    fixture.drive_ok(
      responses.response_machine(target("codex"), now: 123),
      done_transcript(),
    )
  let assert [stream.Failed(stream.MalformedStream(..))] = events
    as "public Responses cannot silently accept a private terminal"
}

pub fn helper_auth_denial_does_not_fall_back_to_api_key_test() {
  let public_requests = process.new_subject()
  let public =
    fixture.routing_transport(fn(sent) {
      process.send(public_requests, sent)
      fixture.ok_response(done_transcript())
    })
  let bridge =
    gateway.CodexTransport(prepare_streaming: fn(_profile, sent, events) {
      let http.Transport(prepare_streaming:) =
        fixture.transport(fixture.error_response(
          401,
          [],
          "{\"error\":{\"type\":\"codex_not_logged_in\",\"message\":\"Sign in required\"}}",
        ))
      prepare_streaming(sent, events)
    })
  let registered =
    gateway_without_bridge(public)
    |> gateway.add_provider(gateway.OpenAiResponsesProvider(
      name: "paid-api",
      base_url: "https://api.openai.com/v1",
      api_key_secret: "API_KEY",
    ))
    |> gateway.route(model.Main, [target("codex"), target("paid-api")])
    |> gateway.with_codex_transport(bridge)
  let role_request =
    model.ProviderRequest(
      ..request("codex"),
      target: model.ForRole(model.Main, None),
    )
  let handle = gateway.request(registered, role_request)
  let assert Ok(#([], stream.Failed(error))) =
    stream.await_terminal(handle, within: 2000)
    as "helper authentication denial is terminal"
  let assert stream.HttpError(status: 401, ..) = stream.underlying_error(error)
    as "auth failure remains a non-retryable HTTP error"
  assert process.receive(public_requests, within: 0) == Error(Nil)
}
