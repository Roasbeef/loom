//// Exact profile isolation at the real adapter request boundary.

import core/clock
import core/json
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import provider/fixture
import provider/gateway
import provider/model
import provider/profile
import provider/secret
import provider/stream

pub fn fallback_profiles_use_unchanged_base_test() {
  let requests = process.new_subject()
  let observations = process.new_subject()
  let transport =
    fixture.routing_transport(fn(request) {
      process.send(requests, request)
      case string.contains(request.url, "primary") {
        True ->
          fixture.error_response(
            529,
            [],
            "{\"error\":{\"type\":\"overloaded_error\"}}",
          )
        False ->
          fixture.ok_response(
            fixture.sse_event(
              "message_start",
              "{\"type\":\"message_start\",\"message\":{\"id\":\"msg1\",\"model\":\"b\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}",
            )
            <> fixture.sse_event(
              "message_delta",
              "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}",
            )
            <> fixture.sse_event("message_stop", "{\"type\":\"message_stop\"}"),
          )
      }
    })
  let assert Ok(a) =
    profile.new(
      "profile-a",
      "a",
      "a",
      "anthropic-messages",
      "only-A",
      "task-A",
      [#("code_mode", "prose-A")],
    )
    as "profile A is valid"
  let assert Ok(b) =
    profile.new(
      "profile-b",
      "b",
      "b",
      "anthropic-messages",
      "only-B",
      "task-B",
      [#("code_mode", "prose-B")],
    )
    as "profile B is valid"
  let gw =
    gateway.new(
      transport:,
      secrets: secret.from_list([#("KEY", "sk-fixture")]),
      clock: clock.fixed(1),
    )
    |> gateway.add_provider(gateway.AnthropicProvider(
      "a",
      "https://primary.test",
      "KEY",
    ))
    |> gateway.add_provider(gateway.AnthropicProvider(
      "b",
      "https://backup.test",
      "KEY",
    ))
    |> gateway.route(model.Main, [
      fixture.resolved(provider: "a", model_id: "a"),
      fixture.resolved(provider: "b", model_id: "b"),
    ])
  let assert Ok(gw) =
    gateway.with_profiles(
      gw,
      [a, b],
      fn(system, _) { string.inspect(system) },
      fn(observation) {
        process.send(observations, observation)
        Ok(Nil)
      },
    )
    as "profile map is valid"
  let base =
    model.ProviderRequest(
      ..fixture.request_for(fixture.resolved(provider: "a", model_id: "a")),
      target: model.ForRole(model.Main, None),
      system: Some("requirements"),
      tools: [
        model.ToolSpec("code_mode", "generated signatures", json.Object([])),
      ],
    )
  let handle = gateway.request(gw, base)
  let assert Ok(#(_, stream.Settled(..))) =
    stream.await_terminal(handle, within: 2000)
    as "fallback settles"
  let assert Ok(first) = process.receive(requests, within: 1000)
    as "A reached transport"
  let assert Ok(second) = process.receive(requests, within: 1000)
    as "B reached transport"
  let first_text = first.body
  let second_text = second.body
  assert string.contains(first_text, "only-A")
    && string.contains(first_text, "task-A")
  assert !string.contains(first_text, "only-B")
  assert string.contains(second_text, "only-B")
    && string.contains(second_text, "task-B")
  assert !string.contains(second_text, "only-A")
    && !string.contains(second_text, "prose-A")
  assert string.contains(second_text, "generated signatures")
    && string.contains(second_text, "requirements")
  let assert Ok(first_observation) = process.receive(observations, within: 1000)
    as "failed A records provenance"
  let assert Ok(second_observation) =
    process.receive(observations, within: 1000)
    as "successful B records provenance"
  assert first_observation.profile_id == Some("profile-a")
    && first_observation.ordinal == 1
  assert second_observation.profile_id == Some("profile-b")
    && second_observation.ordinal == 2
  assert !string.contains(second_observation.digest, "only-A")
}

pub fn exact_api_match_and_schema_preservation_test() {
  let assert Ok(p) =
    profile.new("id", "p", "m", "openai-completions", "suffix", "task", [
      #("tool", "extra"),
    ])
    as "profile is valid"
  let target = fixture.resolved(provider: "p", model_id: "m")
  let schema = json.Object([#("type", json.String("object"))])
  let base =
    model.ProviderRequest(..fixture.request_for(target), tools: [
      model.ToolSpec("tool", "original", schema),
    ])
  assert profile.apply([p], target, "openai-responses", base) == #(None, base)
  let #(id, changed) = profile.apply([p], target, "openai-completions", base)
  assert id == Some("id")
  let assert Ok(tool) = list.first(changed.tools) as "tool stays present"
  assert tool.name == "tool"
    && tool.input_schema == schema
    && tool.description == "original\n\nextra"
  assert changed.messages == base.messages && changed.target == base.target
  assert profile.validate_map([p, p])
    == Error("duplicate or oversized exact-model profile map")
}

pub fn failed_provenance_prevents_transport_test() {
  let requests = process.new_subject()
  let transport =
    fixture.routing_transport(fn(request) {
      process.send(requests, request)
      []
    })
  let gw =
    gateway.new(
      transport:,
      secrets: secret.from_list([#("KEY", "sk-fixture")]),
      clock: clock.fixed(1),
    )
    |> gateway.add_provider(gateway.AnthropicProvider(
      "p",
      "https://test",
      "KEY",
    ))
  let assert Ok(gw) =
    gateway.with_profiles(gw, [], fn(_, _) { "digest" }, fn(_) {
      Error("write failed")
    })
    as "empty pinned map is valid"
  let handle =
    gateway.request(
      gw,
      fixture.request_for(fixture.resolved(provider: "p", model_id: "m")),
    )
  let assert Ok(#(_, stream.Failed(_))) =
    stream.await_terminal(handle, within: 2000)
    as "provenance failure settles"
  assert process.receive(requests, within: 0) == Error(Nil)
}

pub fn refused_trial_admission_keeps_reason_and_acquires_no_credentials_test() {
  let effects = process.new_subject()
  let gw =
    gateway.new(
      transport: fixture.routing_transport(fn(_) {
        process.send(effects, "transport")
        []
      }),
      secrets: secret.from_function(fn(_) {
        process.send(effects, "credential")
        Ok("sk-fixture")
      }),
      clock: clock.fixed(1),
    )
    |> gateway.add_provider(gateway.AnthropicProvider(
      "p",
      "https://test",
      "KEY",
    ))
    |> gateway.with_request_guard(fn(_, _, _) {
      Error("aggregate token reservation exhausted")
    })
  let handle =
    gateway.request(
      gw,
      fixture.request_for(fixture.resolved(provider: "p", model_id: "m")),
    )
  let assert Ok(#(_, stream.Failed(error))) =
    stream.await_terminal(handle, within: 2000)
    as "native refusal is a terminal observed result"
  assert stream.underlying_error(error)
    == stream.StreamError(
      api_error_type: "request_admission",
      message: "aggregate token reservation exhausted",
    )
  assert process.receive(effects, within: 0) == Error(Nil)
}
