//// Shared fixtures for the `harness` tests: a routed gateway over a scripted
//// transport, the strand configuration that names its model, and the fallback
//// figures an embedder would declare.

import core/clock
import harness/model_facts.{type Fallback, Fallback}
import machine/strand.{
  type StrandConfiguration, ModelIdentity, StrandConfiguration, ThinkingOff,
}
import provider/adapter/anthropic
import provider/gateway.{type Gateway}
import provider/http
import provider/model
import provider/secret

/// The model the gateway routes `Main` to.
pub fn routed_model() -> model.ResolvedModel {
  model.ResolvedModel(
    provider: "acme",
    model_id: "loom-1",
    thinking: model.ThinkingOff,
    context_window: 222_000,
    max_output_tokens: 4096,
  )
}

/// A gateway with one Anthropic provider and a `Main` route over `transport`.
pub fn routed_gateway(transport: http.Transport) -> Gateway {
  unrouted_gateway(transport)
  |> gateway.route(model.Main, [routed_model()])
}

/// The same gateway with no route at all.
pub fn unrouted_gateway(transport: http.Transport) -> Gateway {
  gateway.new(
    transport:,
    secrets: secret.from_list([#("ACME_KEY", "unit-test-key")]),
    clock: clock.fixed(at: 0),
  )
  |> gateway.add_provider(gateway.AnthropicProvider(
    name: "acme",
    base_url: "https://acme.test",
    api_key_secret: "ACME_KEY",
  ))
}

/// The figures an embedder declares for an identity it has no facts for.
pub fn fallback() -> Fallback {
  Fallback(
    api: anthropic.api_name,
    context_window: 100_000,
    max_output_tokens: 2048,
  )
}

/// A strand on the routed model with these tools active.
pub fn strand_on_route(active: List(String)) -> StrandConfiguration {
  StrandConfiguration(
    model: ModelIdentity(provider: "acme", model_id: "loom-1"),
    thinking_level: ThinkingOff,
    active_tool_names: active,
  )
}

/// A fallback with these figures, for the construction-error tests.
pub fn fallback_with(api: String, window: Int, ceiling: Int) -> Fallback {
  Fallback(api:, context_window: window, max_output_tokens: ceiling)
}
