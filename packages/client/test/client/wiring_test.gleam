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
import client/serve
import client/wiring
import core/clock
import core/ids
import core/json
import core/message
import gleam/list
import gleam/option.{None}
import gleam/string
import machine/strand.{
  type StrandConfiguration, ModelIdentity, StrandConfiguration,
}
import provider/gateway
import provider/http
import provider/model
import provider/secret
import runtime/effects

// --- fixtures --------------------------------------------------------------

// A transport that never answers; nothing here dispatches through it.
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

// The registry is production's own (`serve.registry()`), so a tool that
// stops being registered breaks these tests rather than silently
// changing what a request advertises.
fn config() -> wiring.Config {
  let workspace = "/nonexistent/loom-wiring-test"
  wiring.Config(
    gateway: routed_gateway(),
    role: model.Main,
    system: None,
    fallback_context_window: 111_000,
    fallback_max_output_tokens: 2222,
    provider_timeout_ms: 1000,
    broker: helperless_broker(),
    broker_timeout_ms: 1000,
    registry: serve.registry(None),
    workspace:,
    blob_root: workspace <> "/.blobs",
    base_policy: policy.workspace_default(workspace),
    grants: [],
    demand: exec.BestEffort,
    env: [#("PATH", "/usr/bin:/bin")],
    clock: clock.fixed(at: 4242),
    entropy: fn() { 7 },
  )
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
