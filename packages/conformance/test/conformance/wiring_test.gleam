//// Unit tests of the production-wiring adapter's mappings, with fakes
//// throughout: a dead transport behind the gateway, a broker whose
//// pool seam never yields a helper, and an on-disk workspace only where
//// a harness-side tool actually writes.

import broker/broker
import broker/exec
import broker/policy
import broker/token
import conformance/wiring
import core/clock
import core/ids
import core/json.{type JsonValue}
import core/message
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import machine/operation
import machine/strand.{ModelIdentity, StrandConfiguration}
import provider/gateway
import provider/http
import provider/model
import provider/secret
import provider/stream
import runtime/effects
import simplifile
import support/rig

// --- fixtures -------------------------------------------------------------

// A transport that never answers; mapping tests never dispatch through
// it.
fn dead_transport() -> http.Transport {
  http.Transport(send_streaming: fn(_request, _subject) { Nil })
}

fn routed_gateway() -> gateway.Gateway {
  gateway.new(
    transport: dead_transport(),
    secrets: secret.from_list([#("ACME_KEY", "unit-test-key")]),
    clock: clock.fixed(at: 0),
  )
  |> gateway.add_provider(gateway.AnthropicProvider(
    name: "acme",
    base_url: "https://acme.test",
    api_key_secret: "ACME_KEY",
  ))
  |> gateway.route(model.Main, [routed_model()])
}

fn routed_model() -> model.ResolvedModel {
  model.ResolvedModel(
    provider: "acme",
    model_id: "loom-1",
    thinking: model.ThinkingOff,
    context_window: 200_000,
    max_output_tokens: 8192,
  )
}

// A real broker actor whose checkout seam always refuses — clearance
// and policy composition run for real, no helper ever spawns.
fn helperless_broker() -> broker.Broker {
  let assert Ok(broker_actor) =
    broker.start(
      broker.BrokerConfig(
        entropy: token.production_entropy(),
        clock: clock.fixed(at: 0),
        checkout: fn() { Error(exec.AllBusy(size: 0)) },
        checkin: fn(_helper) { Nil },
      ),
    )
  broker_actor
}

fn workspace() -> String {
  let assert Ok(here) = simplifile.current_directory()
  let workspace = here <> "/build/wiring/work"
  let assert Ok(Nil) = simplifile.create_directory_all(workspace)
  workspace
}

fn config(base_policy: policy.SandboxPolicy) -> wiring.Config {
  let workspace = workspace()
  wiring.Config(
    gateway: routed_gateway(),
    role: model.Main,
    system: Some("unit-test system prompt"),
    fallback_context_window: 111_000,
    fallback_max_output_tokens: 2222,
    provider_timeout_ms: 1000,
    broker: helperless_broker(),
    broker_timeout_ms: 1000,
    registry: rig.registry(),
    workspace:,
    blob_root: workspace <> "/.blobs",
    base_policy:,
    grants: [policy.GrantEnv(name: "LANG")],
    demand: exec.BestEffort,
    env: [#("PATH", "/usr/bin:/bin")],
    clock: clock.fixed(at: 4242),
    entropy: fn() { 7 },
  )
}

fn wide_config() -> wiring.Config {
  let workspace = workspace()
  config(
    policy.SandboxPolicy(..policy.workspace_default(workspace), readable_roots: [
      "/",
    ]),
  )
}

fn configuration_for(
  provider: String,
  model_id: String,
) -> strand.StrandConfiguration {
  StrandConfiguration(
    model: ModelIdentity(provider:, model_id:),
    thinking_level: strand.ThinkingMax,
    active_tool_names: ["bash", "fs_read", "ghost"],
  )
}

fn op_id() -> ids.OpId {
  let #(op, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 1))
  op
}

fn call(name: String, arguments: JsonValue) -> message.ToolCall {
  message.ToolCall(
    id: "call_1",
    name:,
    arguments:,
    thought_signature: None,
    namespace: None,
  )
}

fn generation_spec(
  configuration: strand.StrandConfiguration,
) -> effects.RequestSpec {
  effects.GenerationRequest(
    operation: op_id(),
    step_id: "turn-1",
    attempt: 1,
    configuration:,
    context: [user("hello")],
    stream_options: json.Object([]),
  )
}

fn user(text: String) -> message.AgentMessage {
  message.UserMessage(
    content: [message.UserText(text:, text_signature: None)],
    timestamp: 0,
  )
}

// --- RequestSpec -> ProviderRequest ---------------------------------------

pub fn request_target_uses_gateway_facts_when_identity_matches_test() {
  // The captured identity agrees with the role's resolution, so the
  // dispatch target carries the gateway's full model facts.
  let target =
    wiring.request_target(wide_config(), configuration_for("acme", "loom-1"))
  assert target == model.ForResolved(resolved: routed_model())
}

pub fn request_target_identity_mismatch_keeps_captured_identity_test() {
  // A routing change after the intent was committed must not redirect
  // the dispatch: the captured identity wins, with fallback facts.
  let target =
    wiring.request_target(wide_config(), configuration_for("acme", "loom-0"))
  assert target
    == model.ForResolved(resolved: model.ResolvedModel(
      provider: "acme",
      model_id: "loom-0",
      thinking: model.ThinkingHigh,
      context_window: 111_000,
      max_output_tokens: 2222,
    ))
}

pub fn request_target_unroutable_role_falls_back_test() {
  let unrouted = wiring.Config(..wide_config(), role: model.Vision)
  let assert model.ForResolved(resolved:) =
    wiring.request_target(unrouted, configuration_for("acme", "loom-1"))
  assert resolved.provider == "acme"
  assert resolved.model_id == "loom-1"
  assert resolved.context_window == 111_000
}

pub fn thinking_level_collapses_onto_provider_scale_test() {
  assert wiring.thinking_level(strand.ThinkingOff) == model.ThinkingOff
  assert wiring.thinking_level(strand.ThinkingMinimal) == model.ThinkingLow
  assert wiring.thinking_level(strand.ThinkingLow) == model.ThinkingLow
  assert wiring.thinking_level(strand.ThinkingMedium) == model.ThinkingMedium
  assert wiring.thinking_level(strand.ThinkingHigh) == model.ThinkingHigh
  assert wiring.thinking_level(strand.ThinkingXHigh) == model.ThinkingHigh
  assert wiring.thinking_level(strand.ThinkingMax) == model.ThinkingHigh
}

pub fn provider_request_field_mapping_test() {
  let config = wide_config()
  let configuration = configuration_for("acme", "loom-1")
  let request = wiring.provider_request(config, generation_spec(configuration))
  // The projected context maps verbatim; the system prompt comes from
  // the config; the output ceiling is left to the resolved model.
  assert request.messages == [user("hello")]
  assert request.system == Some("unit-test system prompt")
  assert request.max_output_tokens == None
  assert request.target == model.ForResolved(resolved: routed_model())
  // Active names are rendered from the registry; the unregistered
  // "ghost" is omitted.
  assert list.map(request.tools, fn(spec) { spec.name }) == ["bash", "fs_read"]
}

pub fn poll_requests_settle_in_band_as_unsupported_test() {
  let effects_record = wiring.build_effects(wide_config())
  let handle =
    effects_record.provider.request(effects.PollRequest(
      operation: op_id(),
      step_id: "poll-1",
      poll: 1,
      handle: message.DeferredHandle(
        provider: "acme",
        model_id: "loom-1",
        api: "anthropic-messages",
        id: "deferred-1",
        expires_at: None,
        poll_after_ms: None,
        data: None,
      ),
      configuration: configuration_for("acme", "loom-1"),
      stream_options: json.Object([]),
    ))
  let assert Ok(#([], stream.Failed(stream.TransportFailed(reason:)))) =
    stream.await_terminal(handle, within: 1000)
  assert string.contains(reason, "deferred polls")
}

// --- clearance and replay -------------------------------------------------

pub fn clearance_maps_replay_declarations_test() {
  let config = wide_config()
  let configuration = configuration_for("acme", "loom-1")
  let arguments = json.Object([#("command", json.String("true"))])
  let query =
    effects.ClearanceQuery(
      operation: op_id(),
      step_id: "turn-1:tools",
      source_index: 0,
      call: call("bash", arguments),
      configuration:,
    )
  // bash: replay Never, arguments pass through unchanged.
  assert wiring.clear(config, query)
    == effects.Cleared(
      effective_arguments: arguments,
      replay: operation.ReplayNever,
    )
  // fs_read: replay Safe.
  let read_query =
    effects.ClearanceQuery(
      ..query,
      call: call("fs_read", json.Object([#("path", json.String("a"))])),
    )
  let assert effects.Cleared(replay: operation.ReplaySafe, ..) =
    wiring.clear(config, read_query)
}

pub fn clearance_refuses_unregistered_tool_test() {
  let config = wide_config()
  let query =
    effects.ClearanceQuery(
      operation: op_id(),
      step_id: "turn-1:tools",
      source_index: 0,
      call: call("ghost", json.Object([])),
      configuration: configuration_for("acme", "loom-1"),
    )
  let assert effects.ClearanceRefused(reason:) = wiring.clear(config, query)
  assert string.contains(reason, "ghost")
}

pub fn clearance_refuses_inactive_tool_test() {
  // fs_write is registered but absent from the strand's active names.
  let config = wide_config()
  let query =
    effects.ClearanceQuery(
      operation: op_id(),
      step_id: "turn-1:tools",
      source_index: 0,
      call: call("fs_write", json.Object([])),
      configuration: configuration_for("acme", "loom-1"),
    )
  let assert effects.ClearanceRefused(reason:) = wiring.clear(config, query)
  assert string.contains(reason, "not active")
}

pub fn replay_still_safe_consults_live_registry_test() {
  let config = wide_config()
  assert wiring.replay_still_safe(config, "fs_read")
  assert wiring.replay_still_safe(config, "fs_edit")
  assert !wiring.replay_still_safe(config, "bash")
  assert !wiring.replay_still_safe(config, "ghost")
}

// --- ToolRun -> Ctx -------------------------------------------------------

pub fn tool_context_construction_test() {
  let config = wide_config()
  let operation = op_id()
  let ctx = wiring.tool_context(config, operation, "turn-3:tools")
  assert ctx.workspace == config.workspace
  assert ctx.op_id == operation
  assert ctx.step_id == "turn-3:tools"
  assert ctx.base_policy == config.base_policy
  assert ctx.grants == [policy.GrantEnv(name: "LANG")]
  assert ctx.demand == exec.BestEffort
  assert ctx.env == [#("PATH", "/usr/bin:/bin")]
  assert ctx.blob_root == config.workspace <> "/.blobs"
}

// --- outcome mapping ------------------------------------------------------

pub fn run_tool_wraps_outcome_as_result_message_test() {
  // fs_write runs harness-side (no broker), so the whole path executes
  // for real against the on-disk workspace.
  let config = wide_config()
  let run =
    effects.ToolRun(
      operation: op_id(),
      step_id: "turn-1:tools",
      source_index: 0,
      call: call(
        "fs_write",
        json.Object([
          #("path", json.String("wiring_test.txt")),
          #("content", json.String("mapped")),
        ]),
      ),
      arguments: json.Object([
        #("path", json.String("wiring_test.txt")),
        #("content", json.String("mapped")),
      ]),
      replay: operation.ReplaySafe,
    )
  let assert effects.ToolCompleted(result:, terminate: False) =
    wiring.run_tool(config, run)
  let assert message.ToolResultMessage(
    tool_call_id: "call_1",
    tool_name: "fs_write",
    is_error: False,
    timestamp: 4242,
    ..,
  ) = result
  let assert Ok("mapped") =
    simplifile.read(config.workspace <> "/wiring_test.txt")
}

pub fn run_tool_unknown_name_is_in_band_error_test() {
  // Dispatch is total: an unknown name maps to an is_error result,
  // never a ToolFailed harness fault.
  let config = wide_config()
  let run =
    effects.ToolRun(
      operation: op_id(),
      step_id: "turn-1:tools",
      source_index: 0,
      call: call("ghost", json.Object([])),
      arguments: json.Object([]),
      replay: operation.ReplaySafe,
    )
  let assert effects.ToolCompleted(result:, terminate: False) =
    wiring.run_tool(config, run)
  let assert message.ToolResultMessage(is_error: True, ..) = result
}

pub fn run_tool_policy_refusal_carries_wanted_grants_test() {
  // The base policy only covers the workspace, but bash requires the
  // whole filesystem readable: composition narrows, the broker refuses,
  // and the refusal surfaces as an is_error result whose details carry
  // the exact wanted grants (the escalation seam).
  let narrow = config(policy.workspace_default(workspace()))
  let run =
    effects.ToolRun(
      operation: op_id(),
      step_id: "turn-1:tools",
      source_index: 0,
      call: call("bash", bash_arguments()),
      arguments: bash_arguments(),
      replay: operation.ReplayNever,
    )
  let assert effects.ToolCompleted(result:, terminate: False) =
    wiring.run_tool(narrow, run)
  let assert message.ToolResultMessage(
    is_error: True,
    details: Some(details),
    content: [message.ToolResultText(text:, ..)],
    ..,
  ) = result
  assert string.contains(text, "policy refused")
  let assert Ok(json.Array(wanted)) = json_field(details, "wanted")
  assert list.any(wanted, fn(grant) {
    json_field(grant, "grant") == Ok(json.String("readable_root"))
    && json_field(grant, "path") == Ok(json.String("/"))
  })
}

fn bash_arguments() -> JsonValue {
  json.Object([#("command", json.String("true"))])
}

fn json_field(value: JsonValue, key: String) -> Result(JsonValue, Nil) {
  case value {
    json.Object(fields:) ->
      list.find_map(fields, fn(entry) {
        case entry.0 == key {
          True -> Ok(entry.1)
          False -> Error(Nil)
        }
      })
    _ -> Error(Nil)
  }
}
