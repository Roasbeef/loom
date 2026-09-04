//// The wiring adapter's tool-list canonicalization. The rendered tool
//// array is the *byte prefix* of the provider's cached region (the
//// Anthropic adapter hangs one breakpoint on the last tool definition
//// and another on the system block, and the API caches by exact byte
//// prefix over `tools` → `system` → `messages`), so the specs a request
//// carries must depend only on **which** tools are active — never on
//// the order or the multiplicity the strand's durable configuration
//// happens to list them in. The clearance tests alongside pin the other
//// half: canonicalizing the render must not move the authorization
//// line, which is set membership in the same list.
////
//// The fakes are the same shape as the conformance wiring suite's: a
//// transport that never answers, and a broker whose pool seam never
//// yields a helper. Neither is reached — `tool_specs` and `clear` are
//// pure registry work.

import broker/broker
import broker/exec
import broker/policy
import broker/token
import client/escalate
import client/grants
import client/wiring
import core/clock
import core/ids
import core/json
import core/message
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import machine/operation
import machine/planner
import machine/strand.{
  type ModelIdentity, type StrandConfiguration, ModelIdentity,
  StrandConfiguration,
}
import provider/gateway
import provider/http
import provider/model
import provider/secret
import runtime/effects
import session/session
import support/provider as provider_test
import support/tool_registry
import tools/tool

// --- fixtures --------------------------------------------------------------

// A transport that never answers; nothing here dispatches through it.
fn dead_transport() -> http.Transport {
  provider_test.silent()
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
  |> gateway.route(model.Main, [routed_model("loom-1", routed_context_window)])
}

// The main route's window. Distinct from the config's fallback so a test
// can tell which one admission reported.
const routed_context_window = 222_000

fn routed_model(model_id: String, context_window: Int) -> model.ResolvedModel {
  model.ResolvedModel(
    provider: "acme",
    model_id:,
    thinking: model.ThinkingOff,
    context_window:,
    max_output_tokens: 4096,
  )
}

// The host's model-facts source, as `client/serve` builds it from the
// catalogue: an identity's own entry, or `Error(Nil)` for one the
// catalogue does not know.
fn entry_facts(
  identity: ModelIdentity,
) -> Result(#(model.ResolvedModel, String), Nil) {
  list.key_find(
    [
      #("loom-1", #(routed_model("loom-1", routed_context_window), "acme-api")),
    ],
    identity.model_id,
  )
}

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
    as "the fake broker must start"
  broker_actor
}

// The registry is production's own (`contributions.built_in`), so a tool that
// stops being registered breaks these tests rather than silently
// changing what a request advertises.
fn config() -> wiring.Config {
  let workspace = "/nonexistent/loom-wiring-test"
  wiring.Config(
    gateway: routed_gateway(),
    role: model.Main,
    facts: entry_facts,
    system: None,
    api: "acme-api",
    fallback_context_window: 111_000,
    fallback_max_output_tokens: 2222,
    provider_timeout_ms: 1000,
    session: memory_session(),
    compaction: operation.CompactionSettings(
      enabled: True,
      reserve_tokens: 100,
      keep_recent_tokens: 400,
    ),
    broker: helperless_broker(),
    broker_timeout_ms: 1000,
    registry: tool_registry.built_in(None, None, None, None, None),
    workspace:,
    blob_root: workspace <> "/.blobs",
    base_policy: policy.workspace_default(workspace),
    escalations: escalate.none(),
    demand: exec.BestEffort,
    env: [#("PATH", "/usr/bin:/bin")],
    clock: clock.fixed(at: 4242),
    entropy: fn() { 7 },
  )
}

fn memory_session() -> session.Session {
  let assert Ok(opened) = session.open_memory(clock.fixed(at: 0))
    as "the memory session must open"
  opened
}

fn configuration_with(active: List(String)) -> StrandConfiguration {
  StrandConfiguration(
    model: ModelIdentity(provider: "acme", model_id: "loom-1"),
    thinking_level: strand.ThinkingOff,
    active_tool_names: active,
  )
}

fn spec_names(active: List(String)) -> List(String) {
  wiring.tool_specs(config(), active)
  |> list.map(fn(spec) { spec.name })
}

fn clearance(active: List(String), name: String) -> effects.Clearance {
  let #(operation, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 1))
  wiring.clear(
    config(),
    effects.ClearanceQuery(
      operation:,
      step_id: "turn-1:tools",
      source_index: 0,
      call: message.ToolCall(
        id: "call_1",
        name:,
        arguments: json.Object([]),
        thought_signature: None,
        namespace: None,
      ),
      configuration: configuration_with(active),
      grants: [],
    ),
  )
}

// --- the cached prefix -----------------------------------------------------

// Three permutations of one set must render one byte-identical array.
pub fn tool_specs_are_order_independent_test() {
  let canonical = spec_names(["bash", "fs_read", "grep"])
  assert canonical == ["bash", "fs_read", "grep"]
  assert spec_names(["grep", "bash", "fs_read"]) == canonical
  assert spec_names(["fs_read", "grep", "bash"]) == canonical
}

// The whole spec, not just the name: a permutation must not move a
// description or a schema either, since those are the cached bytes.
pub fn tool_specs_permutation_is_byte_identical_test() {
  assert wiring.tool_specs(config(), ["grep", "bash"])
    == wiring.tool_specs(config(), ["bash", "grep"])
}

pub fn tool_specs_collapse_duplicate_names_test() {
  assert spec_names(["grep", "bash", "grep"]) == ["bash", "grep"]
  // A duplicate must not survive as a second identical definition.
  assert spec_names(["bash", "bash"]) == ["bash"]
}

pub fn tool_specs_omit_unregistered_names_test() {
  assert spec_names(["ghost", "bash"]) == ["bash"]
  assert spec_names(["ghost"]) == []
}

// --- authorization is set membership, unchanged ----------------------------

// Sorting and deduping the render must not widen the authorization
// line: `clear` still admits exactly the names in the list, wherever
// they sit in it and however often.
pub fn clearance_admits_a_listed_tool_in_any_position_test() {
  let assert effects.Cleared(..) = clearance(["bash", "fs_read"], "bash")
  let assert effects.Cleared(..) = clearance(["fs_read", "bash"], "bash")
  let assert effects.Cleared(..) = clearance(["grep", "bash", "grep"], "bash")
  let assert effects.Cleared(..) = clearance(["grep", "bash", "grep"], "grep")
}

// …and must not narrow it: a registered tool that is not listed stays
// refused, with the reason that names it.
pub fn clearance_refuses_an_unlisted_tool_test() {
  let assert effects.ClearanceRefused(reason:) =
    clearance(["bash", "grep"], "fs_write")
  assert string.contains(reason, "fs_write")
  assert string.contains(reason, "not active")
}

pub fn clearance_refuses_an_unregistered_tool_test() {
  let assert effects.ClearanceRefused(reason:) =
    clearance(["bash", "ghost"], "ghost")
  assert string.contains(reason, "ghost")
}

fn user(text: String) -> message.AgentMessage {
  message.UserMessage(
    content: [message.UserText(text:, text_signature: None)],
    timestamp: 0,
  )
}

pub fn a_generation_request_still_carries_the_head_test() {
  let #(operation_id, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 1))
  let request =
    wiring.provider_request(
      wiring.Config(..config(), system: Some("you are an agent")),
      effects.GenerationRequest(
        operation: operation_id,
        step_id: "turn-1",
        attempt: 1,
        configuration: configuration_with(["bash", "grep"]),
        context: [user("hello")],
        stream_options: json.Object([]),
      ),
    )
  assert request.system == Some("you are an agent")
  assert list.map(request.tools, fn(spec) { spec.name }) == ["bash", "grep"]
}

// --- the hooks -------------------------------------------------------------

// Admission reports the *route's* window, not the config's fallback:
// everything the threshold decides keys off this number.
pub fn admission_reports_the_resolved_window_test() {
  let hooks_record = wiring.compaction_hooks(config())
  let #(operation_id, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 1))
  let assert planner.Admitted(context_window:, api:, ..) =
    hooks_record.admission(effects.AdmissionQuery(
      operation: operation_id,
      step_id: "turn-1",
      attempt: 1,
      configuration: configuration_with([]),
      stream_options: json.Object([]),
    ))
  assert context_window == routed_context_window
  assert api == "acme-api"
}

// Every structural decision goes to a provider. A harness that supplied
// its own summary here would be answering its own compaction.

// --- the far end of the grants channel ------------------------------------

// One tool run, with whatever grants its clearance consumed.
fn tool_run(grants: List(json.JsonValue)) -> effects.ToolRun {
  let #(operation, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 1))
  effects.ToolRun(
    operation:,
    step_id: "turn-1:tools",
    source_index: 0,
    strand: "main",
    call: message.ToolCall(
      id: "call_1",
      name: "bash",
      arguments: json.Object([]),
      thought_signature: None,
      namespace: None,
    ),
    arguments: json.Object([]),
    replay: operation.ReplayNever,
    grants:,
  )
}

// The seam the whole approval path ends at. `bash` passes `ctx.grants`
// straight into its `CallSpec`, so a grant that does not arrive here
// cannot widen any policy: the context built the grants from a static
// boot-time config, which production pinned to the empty list, and the
// approved grant the driver had just consumed went nowhere.
pub fn tool_context_carries_the_runs_grants_test() {
  let approved = grants.encode(policy.GrantNetwork(network: policy.NetworkFull))
  let ctx = wiring.tool_context(config(), tool_run([approved]))
  assert ctx.grants == [policy.GrantNetwork(network: policy.NetworkFull)]
}

// A run with no approval behind it must widen nothing — the far end of
// the channel is exactly as narrow as what the clearance consumed.
pub fn tool_context_without_grants_widens_nothing_test() {
  assert wiring.tool_context(config(), tool_run([])).grants == []
}

// The grant payloads are durable state in the broker's escalation
// vocabulary, so they decode totally or not at all. A payload that will
// not decode drops out rather than faulting the tool: skipping a grant
// can only narrow what a call receives, which is the safe direction, and
// the call still settles in band under the base policy.
pub fn tool_context_drops_an_undecodable_grant_test() {
  let approved = grants.encode(policy.GrantEnv(name: "PATH"))
  let junk = json.Object([#("grant", json.String("teleport"))])
  let ctx = wiring.tool_context(config(), tool_run([junk, approved]))
  assert ctx.grants == [policy.GrantEnv(name: "PATH")]
}

// --- a tool that ends the run ---------------------------------------------

// A tool whose whole point is the answer under test. `run_tool` never
// inspects a tool beyond dispatching it, so the smallest possible one is
// also the most honest fixture.
fn terminating_tool(terminate: tool.Terminate) -> tool.Tool {
  tool.Tool(
    name: "halt",
    description: "Ends the run.",
    prompt_snippet: None,
    schema: tool.object_schema([], []),
    replay: tool.Safe,
    execution_mode: tool.Concurrent,
    requirements: fn(_workspace) { policy.workspace_default("/nonexistent") },
    run: fn(_ctx, _args) {
      tool.ToolOutcome(..tool.success("halted"), terminate:)
    },
  )
}

fn halt_outcome(terminate: tool.Terminate) -> effects.ToolOutcome {
  let config =
    wiring.Config(
      ..config(),
      registry: tool.registry([terminating_tool(terminate)]),
    )
  let run = tool_run([])
  wiring.run_tool(
    config,
    effects.ToolRun(..run, call: message.ToolCall(..run.call, name: "halt")),
  )
}

// The conversion this boundary exists for. `terminate` has been on
// `MessageEntry` and in the planner since WP-D with nothing upstream able
// to set it; a tool saying `TerminateRun` is what finally reaches the
// frozen effect field as `True`.
pub fn a_terminating_outcome_reaches_the_effect_as_true_test() {
  let assert effects.ToolCompleted(result: _, terminate: True) =
    halt_outcome(tool.TerminateRun)
    as "a TerminateRun outcome must commit with terminate: True"
}

pub fn a_continuing_outcome_reaches_the_effect_as_false_test() {
  let assert effects.ToolCompleted(result: _, terminate: False) =
    halt_outcome(tool.ContinueRun)
    as "a ContinueRun outcome must commit with terminate: False"
}

pub fn terminates_maps_the_two_answers_test() {
  // The conversion itself, both ways: this is the only place the tool
  // vocabulary's polarity is written down.
  assert wiring.terminates(tool.ContinueRun) == False
  assert wiring.terminates(tool.TerminateRun)
}
