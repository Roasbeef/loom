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
import client/catalog
import client/directories
import client/escalate
import client/gateway as client_gateway
import client/grants
import client/permissions
import client/wiring
import core/clock
import core/ids
import core/json
import core/message
import core/register
import core/tx
import events/bus
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
import runtime/api
import runtime/effects
import session/session
import simplifile
import storage/storage
import support/internal/ffi_memory
import support/provider as provider_test
import support/tool_registry
import tools/directory_access
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
) -> Result(#(model.ResolvedModel, String, catalog.ImageReading), Nil) {
  list.key_find(
    [
      #(
        "loom-1",
        #(
          routed_model("loom-1", routed_context_window),
          "acme-api",
          catalog.ReadsImages,
        ),
      ),
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
    observe_output: wiring.unobserved(),
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
    tool.declarations(config().registry),
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

/// Projection retains the opened session without retaining tool environment.
pub fn overflow_projection_does_not_copy_tool_environment_test() {
  let base = config()
  let heavy =
    wiring.Config(..base, env: list.repeat(#("MARKER", "value"), times: 4096))
  let small = wiring.compaction_hooks(base)
  let large = wiring.compaction_hooks(heavy)

  assert ffi_memory.flat_words(heavy) > ffi_memory.flat_words(base) + 4096
  assert ffi_memory.flat_words(large.overflow_preparation)
    == ffi_memory.flat_words(small.overflow_preparation)
}

/// Every compaction callback projects the fields it can reach from wiring.
pub fn compaction_callbacks_do_not_copy_tool_environment_test() {
  let base = config()
  let heavy =
    wiring.Config(..base, env: list.repeat(#("MARKER", "value"), times: 4096))
  let small = wiring.compaction_hooks(base)
  let large = wiring.compaction_hooks(heavy)

  assert ffi_memory.flat_words(large.admission)
    == ffi_memory.flat_words(small.admission)
  assert ffi_memory.flat_words(large.threshold)
    == ffi_memory.flat_words(small.threshold)
  assert ffi_memory.flat_words(large.structural_decision)
    == ffi_memory.flat_words(small.structural_decision)
  assert ffi_memory.flat_words(large.context)
    == ffi_memory.flat_words(small.context)
  assert ffi_memory.flat_words(large.resolution)
    == ffi_memory.flat_words(small.resolution)
}

// A tool whose behaviour carries a payload built at run time, which is the
// only kind of payload a copy actually duplicates: a literal schema or a
// long description is shared across process boundaries, so growing one
// would prove nothing about copy cost.
fn padded_tool(name: String, words: Int) -> tool.Tool {
  let payload = list.repeat(#(name, name), times: words)
  tool.Tool(
    name:,
    description: "a tool whose environment is deliberately heavy",
    prompt_snippet: None,
    schema: tool.object_schema([], []),
    replay: tool.Safe,
    execution_mode: tool.Concurrent,
    requirements: policy.workspace_default,
    run: fn(_ctx, _args) {
      tool.ToolOutcome(
        content: [
          message.ToolResultText(
            text: string.inspect(payload),
            text_signature: None,
          ),
        ],
        details: None,
        is_error: False,
        terminate: tool.ContinueRun,
      )
    },
  )
}

// The registry a session runs under, with two extra tools whose payload the
// caller sizes. Only the payload varies between the two registries a test
// compares: the tool *count* is what a name-keyed projection is allowed to
// scale with, so holding it fixed is what makes an exact equality the right
// assertion rather than a tolerance nobody can justify.
fn registry_padded_to(words: Int) -> tool.Registry {
  tool.registry(
    list.append(
      tool.registered(tool_registry.built_in(None, None, None, None, None)),
      [padded_tool("padded_one", words), padded_tool("padded_two", words)],
    ),
  )
}

/// The declaration slots answer from a projection, so growing the registry
/// they were projected from does not grow what they cost to copy.
///
/// This is the regression for the copy that dominated a resident session's
/// heap: `Effects` is a record of closures copied into every process a
/// session assembly starts, and a slot that held the configuration to read
/// one registration out of it duplicated the whole tool table per copy.
pub fn declaration_slots_do_not_copy_the_registry_test() {
  let light = wiring.Config(..config(), registry: registry_padded_to(1))
  let heavy = wiring.Config(..config(), registry: registry_padded_to(4096))
  let small = wiring.build_effects(light)
  let large = wiring.build_effects(heavy)

  // The premise: the heavy registry really is the larger term. Without
  // this the assertions below would pass on two identical inputs.
  assert ffi_memory.flat_words(heavy.registry)
    > ffi_memory.flat_words(light.registry) + 8192

  assert ffi_memory.flat_words(large.tools.replay_still_safe)
    == ffi_memory.flat_words(small.tools.replay_still_safe)
  assert ffi_memory.flat_words(large.tools.execution_mode)
    == ffi_memory.flat_words(small.tools.execution_mode)
  assert ffi_memory.flat_words(large.tools.clear)
    == ffi_memory.flat_words(small.tools.clear)

  // The registration is still reachable through the slot itself, so this
  // measures a narrower capture rather than a lost tool. Asking the slot
  // rather than a freshly built projection is the point: it is the slot
  // whose size the assertions above pinned.
  assert large.tools.replay_still_safe("padded_one")
  assert large.tools.execution_mode("padded_one") == effects.ConcurrentExecution
}

/// The three compaction slots ask the registry one question — whether this
/// host offers history search — so a larger registry does not enlarge them.
pub fn compaction_slots_do_not_copy_the_registry_test() {
  let light = wiring.Config(..config(), registry: registry_padded_to(1))
  let heavy = wiring.Config(..config(), registry: registry_padded_to(4096))
  let small = wiring.compaction_hooks(light)
  let large = wiring.compaction_hooks(heavy)

  // Its own premise, so this does not depend on a sibling test failing
  // first if the padding ever stops growing the registry.
  assert ffi_memory.flat_words(heavy.registry)
    > ffi_memory.flat_words(light.registry) + 8192

  assert ffi_memory.flat_words(large.threshold)
    == ffi_memory.flat_words(small.threshold)
  assert ffi_memory.flat_words(large.overflow_preparation)
    == ffi_memory.flat_words(small.overflow_preparation)
  assert ffi_memory.flat_words(large.structural_decision)
    == ffi_memory.flat_words(small.structural_decision)
}

/// A collector's output callback carries identity independently of arguments.
pub fn output_observer_does_not_copy_run_payload_test() {
  let opened = memory_session()
  let assert Ok(_) =
    session.ensure_id(opened, ids.generator(clock.fixed(at: 0), seed: 1))
    as "the observer must take the publishing branch"
  let observer = client_gateway.tool_output_observer(bus.start(), opened)
  let small = tool_run([])
  let large =
    effects.ToolRun(
      ..small,
      arguments: json.Array(list.repeat(json.String("marker"), times: 4096)),
    )

  assert ffi_memory.flat_words(large) > ffi_memory.flat_words(small) + 4096
  assert ffi_memory.flat_words(observer(large))
    == ffi_memory.flat_words(observer(small))
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
    origin: None,
  )
}

pub fn a_generation_request_still_carries_the_head_test() {
  let #(operation_id, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 1))
  let request =
    wiring.provider_request(
      wiring.Config(..config(), system: Some("you are an agent")),
      effects.GenerationRequest(
        response_entry: ids.mint_entry(ids.generator(clock.fixed(0), 991)).0,
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

pub fn dispatch_reads_session_directory_authority_before_native_io_test() {
  let assert Ok(here) = simplifile.current_directory()
    as "the fixture directory must be known"
  let root = here <> "/build/directory-dispatch"
  let shared = root <> "-shared"
  let _cleared = simplifile.delete(shared)
  let assert Ok(Nil) = simplifile.create_directory_all(root)
    as "the workspace must exist"
  let assert Ok(Nil) = simplifile.create_directory_all(shared)
    as "the added directory must exist"
  let configured =
    wiring.Config(
      ..config(),
      workspace: root,
      blob_root: root <> "/.blobs",
      base_policy: policy.workspace_default(root),
    )
  let args =
    json.Object([
      #("path", json.String(shared <> "/output")),
      #("content", json.String("granted")),
    ])
  let run = tool_run([])
  let run =
    effects.ToolRun(
      ..run,
      call: message.ToolCall(..run.call, name: "fs_write", arguments: args),
      arguments: args,
    )
  let assert effects.ToolCompleted(
    result: message.ToolResultMessage(is_error: True, ..),
    ..,
  ) = wiring.run_tool(configured, run)
    as "an ungranted directory must be refused"
  assert simplifile.read(shared <> "/output") != Ok("granted")
  let value =
    json.Object([
      #(
        "directories",
        directories.encode(directory_access.Access([shared], [shared])),
      ),
    ])
  let assert Ok(_) =
    storage.commit(
      configured.session.store,
      tx.Tx(
        [
          tx.SetRegister(
            register.FactCustom,
            directories.key,
            register.value(value),
          ),
        ],
        [],
      ),
    )
    as "the operator's committed directory authority must be present"
  let assert effects.ToolCompleted(
    result: message.ToolResultMessage(is_error: False, ..),
    ..,
  ) = wiring.run_tool(configured, run)
    as "the committed directory must permit the write"
  assert simplifile.read(shared <> "/output") == Ok("granted")

  // A different session retains its own baseline even in the same workspace.
  let other = wiring.Config(..configured, session: memory_session())
  let assert effects.ToolCompleted(
    result: message.ToolResultMessage(is_error: True, ..),
    ..,
  ) = wiring.run_tool(other, run)
    as "another session must not inherit the addition"
}

pub fn remembered_file_and_network_permissions_survive_restart_without_widening_neighbors_test() {
  let assert Ok(here) = simplifile.current_directory()
    as "the fixture directory must be known"
  let root = here <> "/build/remembered-permission-restart"
  let shared = root <> "/outside"
  let _cleared = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/workspace")
    as "the workspace must exist"
  let assert Ok(Nil) = simplifile.create_directory_all(shared)
    as "the external parent must exist"
  let path = root <> "/session.db"
  let time = clock.fixed(at: 1000)
  let assert Ok(opened) = session.open_sqlite(path, "first", 30_000, time)
    as "the saved session must open"
  let configured =
    wiring.Config(
      ..config(),
      session: opened,
      workspace: root <> "/workspace",
      blob_root: root <> "/workspace/.blobs",
      base_policy: policy.workspace_default(root <> "/workspace"),
    )
  let assert Ok(live) =
    api.open(
      opened,
      wiring.build_effects(configured),
      api.default_options(configuration_with(["fs_write"])),
    )
    as "the runtime owns the durable approval transaction"
  let allowed = [
    policy.GrantWritableRoot(shared <> "/output"),
    policy.GrantNetwork(policy.NetworkFull),
  ]
  let assert Ok(Nil) =
    api.raise_escalation(live, "remember-exact-file", json.Object([]))
    as "the pending record must exist"
  let assert Ok(cell) = api.escalation_cell(live, "remember-exact-file")
    as "the exact question is captured"
  let assert Ok(change) = permissions.remembering(live, allowed, None)
    as "a missing writable file is a valid remembered target"
  let assert Ok(_) =
    api.approve_escalation_with_fact_at(
      live,
      cell,
      list.map(allowed, grants.encode),
      None,
      change,
    )
    as "approval and standing authority commit together"
  let assert Ok(_) = api.consume_escalation(live, "remember-exact-file")
    as "consuming the call approval does not consume session authority"
  let assert Ok(Nil) = api.close(live) as "the runtime and database must close"
  let assert Ok(reopened) = session.open_sqlite(path, "second", 30_000, time)
    as "the saved session must reopen"
  assert permissions.read(reopened) == Ok(allowed)
  let configured = wiring.Config(..configured, session: reopened)
  let args =
    json.Object([
      #("path", json.String(shared <> "/output")),
      #("content", json.String("remembered")),
    ])
  let original = tool_run([])
  let run =
    effects.ToolRun(
      ..original,
      call: message.ToolCall(..original.call, name: "fs_write", arguments: args),
      arguments: args,
    )
  let assert effects.ToolCompleted(
    result: message.ToolResultMessage(is_error: False, ..),
    ..,
  ) = wiring.run_tool(configured, run)
    as "the remembered exact file succeeds without another approval"
  assert simplifile.read(shared <> "/output") == Ok("remembered")
  let neighbor =
    json.Object([
      #("path", json.String(shared <> "/neighbor")),
      #("content", json.String("denied")),
    ])
  let neighboring =
    effects.ToolRun(
      ..run,
      call: message.ToolCall(..run.call, arguments: neighbor),
      arguments: neighbor,
    )
  let assert effects.ToolCompleted(
    result: message.ToolResultMessage(is_error: True, ..),
    ..,
  ) = wiring.run_tool(configured, neighboring)
    as "remembering a file must not authorize its parent directory"
  assert simplifile.read(shared <> "/neighbor") != Ok("denied")

  // The same snapshot must reach the jail policy without adding host-native paths.
  let observer =
    tool.Tool(..terminating_tool(tool.ContinueRun), run: fn(ctx: tool.Ctx, _) {
      assert ctx.base_policy.network == policy.NetworkFull
      assert ctx.directory_access.writable == [shared <> "/output"]
      tool.success("captured")
    })
  let observed =
    wiring.Config(..configured, registry: tool.registry([observer]))
  let assert effects.ToolCompleted(
    result: message.ToolResultMessage(is_error: False, ..),
    ..,
  ) =
    wiring.run_tool(
      observed,
      effects.ToolRun(
        ..original,
        call: message.ToolCall(..original.call, name: "halt"),
      ),
    )
    as "standing network authority must reach the next invocation's policy"
  let assert Ok(_) =
    storage.commit(
      reopened.store,
      tx.Tx(
        [
          tx.SetRegister(
            register.FactCustom,
            permissions.key,
            register.value(json.Object([])),
          ),
        ],
        [],
      ),
    )
    as "the corruption fixture must commit"
  let assert effects.ToolCompleted(
    result: message.ToolResultMessage(is_error: True, ..),
    ..,
  ) = wiring.run_tool(configured, run)
    as "malformed standing authority must refuse dispatch"
  let assert Ok(Nil) = session.close(reopened)
    as "the reopened store must close"
}
