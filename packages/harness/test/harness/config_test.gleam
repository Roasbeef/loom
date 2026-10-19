//// `harness.new` is the typed front door: a configuration the daemon would
//// reject at run time is refused at construction, and a valid one is built.

import core/clock
import gleam/erlang/process
import gleam/option.{None}
import harness
import provider/model
import session/session
import support/fixtures
import support/scripted
import tools/tool

fn settings(gateway) -> harness.Settings {
  let assert Ok(opened) = session.open_memory(clock.fixed(at: 1))
    as "the in-memory session opens"
  harness.settings(
    gateway:,
    session: opened,
    registry: tool.registry([]),
    clock: clock.fixed(at: 1),
    fallback: fixtures.fallback(),
    tools: harness.Embedded(workspace: "/w", blob_root: "/w/blobs"),
  )
}

fn transport() {
  scripted.transport(process.new_subject(), fn(_body) { scripted.Say("hi") })
}

pub fn a_routed_main_role_builds_test() {
  let assert Ok(_config) =
    harness.new(settings(fixtures.routed_gateway(transport())))
}

pub fn a_gateway_with_no_main_route_is_refused_at_construction_test() {
  assert harness.new(settings(fixtures.unrouted_gateway(transport())))
    == Error(harness.RoleUnrouted(role: model.Main))
}

pub fn the_role_asked_about_is_the_role_that_must_route_test() {
  let wanted = model.Plan
  assert harness.new(
      harness.Settings(
        ..settings(fixtures.routed_gateway(transport())),
        role: wanted,
      ),
    )
    == Error(harness.RoleUnrouted(role: wanted))
}

pub fn a_non_positive_fallback_window_is_refused_test() {
  let base = settings(fixtures.routed_gateway(transport()))
  let fallback = fixtures.fallback()
  assert harness.new(
      harness.Settings(
        ..base,
        fallback: fixtures.fallback_with(fallback.api, 0, 1),
      ),
    )
    == Error(harness.InvalidLimit(name: "fallback.context_window"))
}

pub fn a_non_positive_fallback_ceiling_is_refused_test() {
  let base = settings(fixtures.routed_gateway(transport()))
  assert harness.new(
      harness.Settings(
        ..base,
        fallback: fixtures.fallback_with(fixtures.fallback().api, 1, -5),
      ),
    )
    == Error(harness.InvalidLimit(name: "fallback.max_output_tokens"))
}

pub fn a_non_positive_provider_timeout_is_refused_test() {
  let base = settings(fixtures.routed_gateway(transport()))
  assert harness.new(harness.Settings(..base, provider_timeout_ms: 0))
    == Error(harness.InvalidLimit(name: "provider_timeout_ms"))
}

pub fn a_relative_workspace_or_blob_root_is_refused_test() {
  let base = settings(fixtures.routed_gateway(transport()))
  assert harness.new(
      harness.Settings(
        ..base,
        tools: harness.Embedded(workspace: "work", blob_root: "/w/blobs"),
      ),
    )
    == Error(harness.RelativePath(path: "work"))
  assert harness.new(
      harness.Settings(
        ..base,
        tools: harness.Embedded(workspace: "/w", blob_root: "blobs"),
      ),
    )
    == Error(harness.RelativePath(path: "blobs"))
}

pub fn hosted_tools_bring_their_own_context_and_are_not_path_checked_test() {
  let base = settings(fixtures.routed_gateway(transport()))
  let context = harness.embedded_context("/w", "/w/blobs", clock.fixed(at: 1))
  let assert Ok(_config) =
    harness.new(harness.Settings(..base, tools: harness.Hosted(context:)))
}

pub fn the_default_settings_name_no_system_prompt_and_the_main_role_test() {
  let base = settings(fixtures.routed_gateway(transport()))
  assert base.system == None
  assert base.role == model.Main
}

pub fn random_entropy_does_not_repeat_test() {
  let seed = harness.random_entropy()
  assert seed() != seed()
}
