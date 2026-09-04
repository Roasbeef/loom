//// Unit tests of the production-wiring adapter's mappings, with fakes
//// throughout: a dead transport behind the gateway, a broker whose
//// pool seam never yields a helper, and an on-disk workspace only where
//// a harness-side tool actually writes.

import broker/broker
import broker/exec
import broker/policy
import broker/token
import client/escalate
import client/grants
import client/wiring
import core/clock
import core/ids
import core/json.{type JsonValue}
import core/message
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import machine/operation as machine_operation
import machine/planner
import machine/strand.{ModelIdentity, StrandConfiguration}
import provider/gateway
import provider/http
import provider/model
import provider/retry
import provider/secret
import provider/stream
import runtime/effects
import session/session
import simplifile
import support/rig
import support/script

// --- fixtures -------------------------------------------------------------

// A transport that never answers; mapping tests never dispatch through
// it.
fn dead_transport() -> http.Transport {
  script.owned_transport(fn(_request, _subject) { Nil })
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

// A second entry the host's catalogue knows but no role heads — the
// switched-to model in the off-route tests. Its figures differ from both
// the route's and the config's fallbacks, so an assertion can say which
// of the three answered.
const off_route_context_window = 333_000

const off_route_max_output_tokens = 3333

const off_route_api = "acme-openai-api"

fn off_route_model() -> model.ResolvedModel {
  model.ResolvedModel(
    provider: "acme",
    model_id: "loom-0",
    thinking: model.ThinkingOff,
    context_window: off_route_context_window,
    max_output_tokens: off_route_max_output_tokens,
  )
}

// The host's model-facts source, as `client/serve` builds it from the
// catalogue: an identity's own entry, or `Error(Nil)` for one the
// catalogue does not know.
fn entry_facts(
  identity: strand.ModelIdentity,
) -> Result(#(model.ResolvedModel, String), Nil) {
  list.key_find(
    [
      #("loom-1", #(routed_model(), "acme-api")),
      #("loom-0", #(off_route_model(), off_route_api)),
    ],
    identity.model_id,
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

fn memory_session() -> session.Session {
  let assert Ok(opened) = session.open_memory(clock.fixed(at: 0))
    as "the memory session must open"
  opened
}

fn config(base_policy: policy.SandboxPolicy) -> wiring.Config {
  let workspace = workspace()
  wiring.Config(
    gateway: routed_gateway(),
    role: model.Main,
    facts: entry_facts,
    system: Some("unit-test system prompt"),
    api: "acme-api",
    fallback_context_window: 111_000,
    fallback_max_output_tokens: 2222,
    provider_timeout_ms: 1000,
    session: memory_session(),
    compaction: machine_operation.CompactionSettings(
      enabled: False,
      reserve_tokens: 0,
      keep_recent_tokens: 0,
    ),
    broker: helperless_broker(),
    broker_timeout_ms: 1000,
    registry: rig.registry(),
    workspace:,
    blob_root: workspace <> "/.blobs",
    base_policy:,
    escalations: escalate.none(),
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

pub fn request_target_walks_the_role_when_on_route_test() {
  // The captured identity heads `main`'s chain, so the dispatch is
  // `ForRole` and the gateway walks that chain within the attempt — a
  // rate-limited head costs a fallback, not the machine's retry ladder.
  // The overlay is the strand's per-turn level (here ThinkingMax →
  // ThinkingHigh), never the route's static configuration.
  let target =
    wiring.request_target(wide_config(), configuration_for("acme", "loom-1"))
  assert target
    == model.ForRole(role: model.Main, thinking: Some(model.ThinkingHigh))
}

pub fn request_target_carries_per_turn_thinking_level_test() {
  // The route's static config says ThinkingOff; a turn that raises its
  // level must reach the provider with that raised level, and a turn
  // that switches thinking off must not inherit a route budget. On route
  // that travels as the walk's overlay…
  let configuration = configuration_for("acme", "loom-1")
  let medium =
    strand.StrandConfiguration(
      ..configuration,
      thinking_level: strand.ThinkingMedium,
    )
  assert wiring.request_target(wide_config(), medium)
    == model.ForRole(role: model.Main, thinking: Some(model.ThinkingMedium))
  let off =
    strand.StrandConfiguration(
      ..configuration,
      thinking_level: strand.ThinkingOff,
    )
  assert wiring.request_target(wide_config(), off)
    == model.ForRole(role: model.Main, thinking: Some(model.ThinkingOff))
  // …and off route it travels on the resolved target itself.
  let assert model.ForResolved(resolved:) =
    wiring.request_target(
      wide_config(),
      strand.StrandConfiguration(
        ..configuration_for("acme", "loom-0"),
        thinking_level: strand.ThinkingMedium,
      ),
    )
  assert resolved.thinking == model.ThinkingMedium
}

pub fn request_target_off_route_keeps_captured_identity_test() {
  // An identity no role heads — a strand switched to another catalogue
  // entry — must not be redirected by a walk: the captured identity
  // wins, dispatched to exactly, and the *entry's own* window and
  // ceiling ride along rather than the main chain head's.
  let target =
    wiring.request_target(wide_config(), configuration_for("acme", "loom-0"))
  assert target
    == model.ForResolved(resolved: model.ResolvedModel(
      provider: "acme",
      model_id: "loom-0",
      thinking: model.ThinkingHigh,
      context_window: off_route_context_window,
      max_output_tokens: off_route_max_output_tokens,
    ))
}

pub fn request_target_unknown_identity_falls_back_to_the_config_test() {
  // An identity neither routed nor in the catalogue — a session written
  // against a catalogue this boot no longer has — keeps running on the
  // config's declared fallbacks rather than being refused.
  let assert model.ForResolved(resolved:) =
    wiring.request_target(wide_config(), configuration_for("ghost", "phantom"))
  assert resolved.provider == "ghost"
  assert resolved.model_id == "phantom"
  assert resolved.context_window == 111_000
  assert resolved.max_output_tokens == 2222
}

pub fn a_deferred_poll_never_walks_a_chain_test() {
  // On route, so a *generation* would dispatch `ForRole`. A poll must
  // not: the handle it fetches was minted by one identity and ORCH-L4
  // validates the settlement against exactly that captured value.
  let configuration = configuration_for("acme", "loom-1")
  let assert model.ForRole(..) =
    wiring.request_target(wide_config(), configuration)
  let request =
    wiring.provider_request(
      wide_config(),
      effects.PollRequest(
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
        configuration:,
        stream_options: json.Object([]),
      ),
    )
  let assert model.ForResolved(resolved:) = request.target
  assert resolved.provider == "acme"
  assert resolved.model_id == "loom-1"
}

// --- per-query admission ---------------------------------------------------

// Admission answers from the *query's own* configuration, so a strand
// switched to another catalogue entry is admitted against that entry's
// window, ceiling and dialect. All three are captured durably into the
// generation intent: the window and ceiling decide overflow
// classification, and the api is what a deferred handle is later
// validated against (ORCH-L4). A boot-frozen answer would name the main
// chain head's figures — and its dialect — for every strand alive.
pub fn admission_reads_the_switched_strands_own_entry_test() {
  let hooks = wiring.compaction_hooks(wide_config())
  let admitted = fn(configuration) {
    hooks.admission(effects.AdmissionQuery(
      operation: op_id(),
      step_id: "turn-1",
      attempt: 1,
      configuration:,
      stream_options: json.Object([]),
    ))
  }
  let assert planner.Admitted(
    intended_output_limit: 8192,
    context_window: 200_000,
    api: "acme-api",
    ..,
  ) = admitted(configuration_for("acme", "loom-1"))
  let assert planner.Admitted(
    intended_output_limit: limit,
    context_window: window,
    api:,
    ..,
  ) = admitted(configuration_for("acme", "loom-0"))
  assert window == off_route_context_window
  assert limit == off_route_max_output_tokens
  assert api == off_route_api
  // An identity the catalogue does not know still admits, on the
  // config's declared fallbacks.
  let assert planner.Admitted(
    intended_output_limit: 2222,
    context_window: 111_000,
    api: "acme-api",
    ..,
  ) = admitted(configuration_for("ghost", "phantom"))
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
  assert request.target
    == model.ForRole(role: model.Main, thinking: Some(model.ThinkingHigh))
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
  let assert Ok(#([], stream.Failed(error))) =
    stream.await_terminal(handle, within: 1000)
  let assert stream.StreamError(api_error_type: _, message: reason) = error
  assert string.contains(reason, "deferred polls")
  // Terminally classified: the machine must not burn its retry ladder
  // on a surface that can never succeed.
  assert retry.classify(error) == retry.Terminal
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
      grants: [],
    )
  // bash: replay Never, arguments pass through unchanged.
  assert wiring.clear(config, query)
    == effects.Cleared(
      effective_arguments: arguments,
      replay: machine_operation.ReplayNever,
    )
  // fs_read: replay Safe.
  let read_query =
    effects.ClearanceQuery(
      ..query,
      call: call("fs_read", json.Object([#("path", json.String("a"))])),
    )
  let assert effects.Cleared(replay: machine_operation.ReplaySafe, ..) =
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
      grants: [],
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
      grants: [],
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
  let run =
    effects.ToolRun(
      operation:,
      step_id: "turn-3:tools",
      source_index: 2,
      strand: "sub:main/reviewer-turn-3-tools-2",
      call: call("fs_read", json.Object([])),
      arguments: json.Object([]),
      replay: machine_operation.ReplaySafe,
      // Grants ride the *run*, not the config: they are what this call's
      // own clearance consumed, in the opaque escalation vocabulary the
      // runtime moves them in.
      grants: [grants.encode(policy.GrantEnv(name: "LANG"))],
    )
  let ctx = wiring.tool_context(config, run)
  assert ctx.workspace == config.workspace
  assert ctx.op_id == operation
  assert ctx.step_id == "turn-3:tools"
  // The driver's own coordinates reach the tool untouched: the agent
  // tools are judged against `strand` and mint a child's name from the
  // rest, so a value invented here would be an identity a model could
  // claim.
  assert ctx.strand == "sub:main/reviewer-turn-3-tools-2"
  assert ctx.source_index == 2
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
      strand: "main",
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
      replay: machine_operation.ReplaySafe,
      grants: [],
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
      strand: "main",
      call: call("ghost", json.Object([])),
      arguments: json.Object([]),
      replay: machine_operation.ReplaySafe,
      grants: [],
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
      strand: "main",
      call: call("bash", bash_arguments()),
      arguments: bash_arguments(),
      replay: machine_operation.ReplayNever,
      grants: [],
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
