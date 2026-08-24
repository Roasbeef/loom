import core/clock
import core/message
import gleam/option.{None, Some}
import gleam/string
import provider/fixture.{sse_event}
import provider/gateway
import provider/http
import provider/model
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
    target: model.ForRole(model.Main),
    system: Some("Be terse."),
    messages: [
      message.UserMessage(
        content: [message.UserText(text: "hi", text_signature: None)],
        timestamp: 1,
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
  let assert Ok(#(deltas, stream.Settled(message: settled, usage:))) =
    stream.await_terminal(handle, within: 2000)
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
  let assert Ok(#(_deltas, stream.Settled(message: settled, usage: _))) =
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
  let assert Ok(#([], stream.Failed(error))) =
    stream.await_terminal(handle, within: 2000)
  assert error
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
  let assert Ok(#([], stream.Failed(stream.HttpError(status: 400, ..)))) =
    stream.await_terminal(handle, within: 2000)
}

pub fn unroutable_role_fails_in_band_test() {
  let gw = two_provider_gateway(fixture.transport([]))
  let request =
    model.ProviderRequest(..main_request(), target: model.ForRole(model.Vision))
  let handle = gateway.request(gw, request)
  let assert Ok(#([], stream.Failed(stream.NoIdentity(role: "vision")))) =
    stream.await_terminal(handle, within: 2000)
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
  let assert Ok(#([], stream.Failed(stream.HttpError(status: 529, ..)))) =
    stream.await_terminal(handle, within: 2000)
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
  let assert Ok(#([], stream.Failed(error))) =
    stream.await_terminal(handle, within: 2000)
  assert error
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
  let assert Ok(#([], stream.Failed(stream.UnknownProvider(provider: "ghost")))) =
    stream.await_terminal(handle, within: 2000)
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
  let assert Ok(#(_deltas, stream.Failed(error))) =
    stream.await_terminal(handle, within: 2000)
  assert !string.contains(stream.describe_error(error), secret_value)
}
