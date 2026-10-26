//// Routing, thinking levels and model facts: the decisions `client/wiring`
//// used to own, held to the rules their documentation states.

import core/clock
import gleam/erlang/process
import gleam/option.{None, Some}
import harness/model_facts.{Known, ReadsImages, TextOnly}
import harness/routing.{Routing}
import machine/planner
import machine/strand.{
  ModelIdentity, StrandConfiguration, ThinkingHigh, ThinkingMax, ThinkingOff,
  ThinkingXHigh,
}
import provider/gateway
import provider/http
import provider/model
import session/session
import support/fixtures
import support/scripted

fn quiet() -> http.Transport {
  scripted.transport(process.new_subject(), fn(_body) { scripted.Say("") })
}

fn routes() -> routing.Routing {
  Routing(
    gateway: fixtures.routed_gateway(quiet()),
    role: model.Main,
    lookup: model_facts.no_facts(),
    fallback: fixtures.fallback(),
  )
}

fn strand_on(identity: strand.ModelIdentity, level: strand.ThinkingLevel) {
  StrandConfiguration(
    model: identity,
    thinking_level: level,
    active_tool_names: [],
  )
}

const on_route = ModelIdentity(provider: "acme", model_id: "loom-1")

const off_route = ModelIdentity(provider: "acme", model_id: "elsewhere")

pub fn an_identity_heading_the_main_chain_dispatches_by_role_test() {
  assert routing.request_target(routes(), strand_on(on_route, ThinkingXHigh))
    == model.ForRole(role: model.Main, thinking: Some(model.ThinkingXHigh))
}

pub fn an_identity_no_role_heads_dispatches_to_exactly_that_identity_test() {
  let target =
    routing.request_target(routes(), strand_on(off_route, ThinkingOff))
  let assert model.ForResolved(resolved:) = target
  assert resolved.provider == "acme"
  assert resolved.model_id == "elsewhere"
  assert resolved.thinking == model.ThinkingOff
}

pub fn an_unknown_identity_is_accounted_against_the_fallback_test() {
  let assert model.ForResolved(resolved:) =
    routing.resolved_target(routes(), strand_on(off_route, ThinkingOff))
  assert resolved.context_window == fixtures.fallback().context_window
  assert resolved.max_output_tokens == fixtures.fallback().max_output_tokens
}

pub fn a_known_identity_is_accounted_against_its_own_entry_test() {
  let known =
    model.ResolvedModel(
      provider: "acme",
      model_id: "elsewhere",
      thinking: model.ThinkingOff,
      context_window: 31_000,
      max_output_tokens: 777,
    )
  let lookup = fn(identity: strand.ModelIdentity) {
    case identity.model_id {
      "elsewhere" ->
        Ok(Known(resolved: known, api: "other-api", reading: TextOnly))
      _ -> Error(Nil)
    }
  }
  let assert model.ForResolved(resolved:) =
    routing.resolved_target(
      Routing(..routes(), lookup:),
      strand_on(off_route, ThinkingOff),
    )
  assert resolved.context_window == 31_000
  assert resolved.max_output_tokens == 777
  assert model_facts.of_identity(lookup, fixtures.fallback(), off_route).reading
    == TextOnly
  assert model_facts.of_identity(lookup, fixtures.fallback(), on_route).reading
    == ReadsImages
}

pub fn the_vision_route_exists_only_when_the_gateway_routes_vision_test() {
  let configuration = strand_on(on_route, ThinkingHigh)
  assert routing.vision_route(routes(), configuration) == None
  let with_vision =
    Routing(
      ..routes(),
      gateway: gateway.route(fixtures.routed_gateway(quiet()), model.Vision, [
        fixtures.routed_model(),
      ]),
    )
  assert routing.vision_route(with_vision, configuration)
    == Some(model.ForRole(
      role: model.Vision,
      thinking: Some(model.ThinkingHigh),
    ))
}

pub fn resolution_reports_an_unrouted_role_in_band_test() {
  let gateway = fixtures.routed_gateway(quiet())
  assert routing.resolution(gateway, model.Main) == planner.ModelResolved
  let assert planner.ModelUnresolved(error:) =
    routing.resolution(gateway, model.Plan)
  assert error.code == "model_unavailable"
}

pub fn provider_levels_round_trip_through_strand_test() {
  assert routing.thinking_level(ThinkingMax) == model.ThinkingMax
  assert routing.thinking_level(strand.ThinkingMinimal) == model.ThinkingLow
  // Lifting a provider level and collapsing it again changes nothing.
  assert [
      model.ThinkingOff, model.ThinkingLow, model.ThinkingMedium,
      model.ThinkingHigh, model.ThinkingXHigh, model.ThinkingMax,
    ]
    |> list_all_round_trip
}

fn list_all_round_trip(levels: List(model.ThinkingLevel)) -> Bool {
  case levels {
    [] -> True
    [level, ..rest] ->
      routing.thinking_level(routing.strand_thinking_level(level)) == level
      && list_all_round_trip(rest)
  }
}

pub fn a_strand_with_no_stored_configuration_has_the_fallback_window_test() {
  let assert Ok(opened) = session.open_memory(clock.fixed(at: 1))
  assert model_facts.strand_window(
      opened,
      model_facts.no_facts(),
      "main",
      fallback: 12_345,
    )
    == 12_345
  assert model_facts.of_strand(
      opened,
      model_facts.no_facts(),
      fixtures.fallback(),
      "main",
    ).context_window
    == fixtures.fallback().context_window
}
