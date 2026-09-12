//// The vision routing rule's unit tests (issue #358): an image-bearing
//// request from a text-only model dispatches through the `vision` chain,
//// an image-bearing request with no usable chain is refused in band with
//// a worded reason, and a text-only target's projection shows
//// placeholders where its images were.
////
//// The fixtures are the wiring suite's shape: a dead transport (nothing
//// dispatches), a facts source over a two-entry catalogue — a
//// `TextOnly` main head and a `ReadsImages` vision head — and the
//// production hooks record, so the admission tests exercise exactly the
//// seam a session runs.

import broker/broker
import broker/exec
import broker/policy
import broker/token
import client/catalog
import client/checkpoint
import client/escalate
import client/vision as client_vision
import client/wiring
import core/clock
import core/entry.{MessageEntry}
import core/ids
import core/json
import core/message
import core/register
import core/tx.{Expect, InsertEntry, SetRegister, Tx}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import machine/codec as machine_codec
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
import storage/storage
import support/provider as provider_test
import support/tool_registry

// --- fixtures ---------------------------------------------------------------

fn dead_transport() -> http.Transport {
  provider_test.silent()
}

// One provider, two entries: the text-only head the strand is pinned to
// and the vision model the image request should borrow.
fn vision_gateway() -> gateway.Gateway {
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
  |> gateway.route(model.Main, [resolved("loom-text", 200_000)])
  |> gateway.route(model.Vision, [resolved("loom-eyes", 64_000)])
}

fn resolved(model_id: String, context_window: Int) -> model.ResolvedModel {
  model.ResolvedModel(
    provider: "acme",
    model_id:,
    thinking: model.ThinkingOff,
    context_window:,
    max_output_tokens: 4096,
  )
}

// The same gateway as above with the vision route removed: the
// no-route refusal's fixture.
fn blind_gateway() -> gateway.Gateway {
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
  |> gateway.route(model.Main, [resolved("loom-text", 200_000)])
}

fn entry_facts(
  identity: ModelIdentity,
) -> Result(#(model.ResolvedModel, String, catalog.ImageReading), Nil) {
  list.key_find(
    [
      #(
        "loom-text",
        #(resolved("loom-text", 200_000), "acme-api", catalog.TextOnly),
      ),
      #(
        "loom-eyes",
        #(resolved("loom-eyes", 64_000), "acme-api", catalog.ReadsImages),
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

fn config_with(gateway: gateway.Gateway) -> wiring.Config {
  config_on(gateway, memory_session())
}

fn config_on(
  gateway: gateway.Gateway,
  opened: session.Session,
) -> wiring.Config {
  let workspace = "/nonexistent/loom-vision-test"
  wiring.Config(
    observe_output: wiring.unobserved(),
    gateway:,
    role: model.Main,
    facts: entry_facts,
    system: None,
    api: "acme-api",
    fallback_context_window: 111_000,
    fallback_max_output_tokens: 2222,
    provider_timeout_ms: 1000,
    session: opened,
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

// The session the admission tests decide from: a strand pinned to
// the text-only entry, whose committed newest message carries an
// image, with the operation registered on the strand the way a run
// registers one. This is the durable state the production hook reads —
// the same discipline the threshold and overflow hooks decide from.
fn image_session() -> session.Session {
  let opened = memory_session()
  let assert Ok(_seeded) =
    session.ensure_strand(opened, "main", text_only_configuration())
    as "the fixture strand must seed"
  let #(entry_id, _generator) =
    ids.mint_entry(ids.generator(clock.fixed(at: 0), seed: 1))
  let assert Ok(Some(session.Cell(seq: leaf_seq, value: leaf))) =
    session.strand_leaf(opened, "main")
  let assert Ok(_leaf) =
    storage.commit(
      opened.store,
      Tx(
        writes: [
          InsertEntry(entry: MessageEntry(
            id: entry_id,
            parent: leaf,
            seq: 0,
            ts: 0,
            message: image_user(),
            terminate: False,
          )),
          SetRegister(
            ns: register.StrandLeaf,
            key: "main",
            value: register.leaf_value(Some(entry_id)),
          ),
        ],
        expected: [
          Expect(ns: register.StrandLeaf, key: "main", seq: Some(leaf_seq)),
        ],
      ),
    )
    as "the fixture image entry must commit"
  opened
}

// The operation that names the fixture strand, as `notes.strand_of`
// reads it.
fn image_operation(opened: session.Session) -> ids.OpId {
  let #(id, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 2))
  let assert Ok(_committed) =
    storage.commit(
      opened.store,
      Tx(
        writes: [
          SetRegister(
            ns: register.OpMeta,
            key: ids.op_id_to_string(id),
            value: register.RegisterValue(
              payload: machine_codec.encode_operation(operation.Operation(
                id:,
                strand: "main",
                source_leaf: None,
                started_at: 0,
                intent: operation.RunIntent(prompt_entries: []),
              )),
            ),
          ),
        ],
        expected: [],
      ),
    )
    as "the fixture operation must commit"
  id
}

fn memory_session() -> session.Session {
  let assert Ok(opened) = session.open_memory(clock.fixed(at: 0))
    as "the memory session must open"
  opened
}

// The strand: pinned to the text-only main head.
fn text_only_configuration() -> StrandConfiguration {
  StrandConfiguration(
    model: ModelIdentity(provider: "acme", model_id: "loom-text"),
    thinking_level: strand.ThinkingOff,
    active_tool_names: [],
  )
}

fn image_user() -> message.AgentMessage {
  message.UserMessage(
    content: [
      message.UserText(text: "what is in this picture", text_signature: None),
      message.UserImage("iVBORw0KGgo=", "image/png"),
    ],
    timestamp: 0,
    origin: None,
  )
}

fn text_user(text: String) -> message.AgentMessage {
  message.UserMessage(
    content: [message.UserText(text:, text_signature: None)],
    timestamp: 0,
    origin: None,
  )
}

fn generation(context: List(message.AgentMessage)) -> effects.RequestSpec {
  let #(operation_id, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 1))
  effects.GenerationRequest(
    operation: operation_id,
    step_id: "turn-1",
    attempt: 1,
    configuration: text_only_configuration(),
    context:,
    stream_options: json.Object([]),
  )
}

// --- the routing --------------------------------------------------------

// The image-bearing request dispatches through the vision chain, and
// carries its images: the vision model reads the whole context, older
// images included.
pub fn image_bearing_request_routes_through_vision_test() {
  let request =
    wiring.provider_request(
      config_with(vision_gateway()),
      generation([
        image_user(),
      ]),
    )
  assert request.target
    == model.ForRole(role: model.Vision, thinking: Some(model.ThinkingOff))
  assert request.messages == [image_user()]
}

// A text-only request from the same strand keeps its own route: the
// strand's model answers every turn the vision chain is not needed for.
pub fn text_request_keeps_the_strands_route_test() {
  let request =
    wiring.provider_request(
      config_with(vision_gateway()),
      generation([
        text_user("hello"),
      ]),
    )
  assert request.target
    == model.ForRole(role: model.Main, thinking: Some(model.ThinkingOff))
}

// With no vision route, an image-bearing request falls back to the
// strand's own target and its images are placeholdered: admission has
// already refused this request in band (the test below), and this arm
// exists for the registry-moved-between-admission-and-dispatch window
// rather than as a live path.
pub fn no_vision_route_leaves_placeholders_test() {
  let request =
    wiring.provider_request(
      config_with(blind_gateway()),
      generation([
        image_user(),
      ]),
    )
  // The strand's own head is the main chain's head, so the ordinary
  // target rule answers `ForRole(Main)` — the point of this arm is the
  // placeholders, not the target.
  assert request.target
    == model.ForRole(role: model.Main, thinking: Some(model.ThinkingOff))
  let assert [message.UserMessage(content: [text_block, placeholder], ..)] =
    request.messages
  assert text_block
    == message.UserText(text: "what is in this picture", text_signature: None)
  assert placeholder
    == message.UserText(
      text: "[image: image/png, described earlier in this conversation]",
      text_signature: None,
    )
}

// A later text-only request to the text-only model placeholders the
// *older* image: the model cannot read it on any turn, and a provider
// that rejects one stale image would fail a request whose own newest
// message is plain text.
pub fn later_text_request_placeholders_the_older_image_test() {
  let request =
    wiring.provider_request(
      config_with(vision_gateway()),
      generation([
        image_user(),
        assistant_answer(),
        text_user("and in prose?"),
      ]),
    )
  assert request.target
    == model.ForRole(role: model.Main, thinking: Some(model.ThinkingOff))
  let assert [
    message.UserMessage(content: [_, first_placeholder], ..),
    message.AssistantMessage(..),
    message.UserMessage(content: [final_text], ..),
  ] = request.messages
  assert first_placeholder
    == message.UserText(
      text: "[image: image/png, described earlier in this conversation]",
      text_signature: None,
    )
  assert final_text
    == message.UserText(text: "and in prose?", text_signature: None)
}

fn assistant_answer() -> message.AgentMessage {
  message.AssistantMessage(
    content: [message.AssistantText(text: "a cat", text_signature: None)],
    api: "acme-api",
    provider: "acme",
    model: "loom-eyes",
    response_model: None,
    response_id: None,
    diagnostics: None,
    usage: message.Usage(
      input: 0,
      output: 0,
      cache_read: 0,
      cache_write: 0,
      cache_write_1h: None,
      reasoning: None,
      total_tokens: 0,
      cost: message.UsageCost(
        input: 0.0,
        output: 0.0,
        cache_read: 0.0,
        cache_write: 0.0,
        total: 0.0,
      ),
    ),
    stop_reason: message.Stop,
    deferred: None,
    error_message: None,
    raw_stop_reason: None,
    end_turn: None,
    timestamp: 0,
  )
}

// A vision-capable model keeps images it can read, on its own route.
pub fn vision_capable_model_keeps_images_test() {
  let capable =
    StrandConfiguration(
      model: ModelIdentity(provider: "acme", model_id: "loom-eyes"),
      thinking_level: strand.ThinkingOff,
      active_tool_names: [],
    )
  let #(operation_id, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 1))
  let request =
    wiring.provider_request(
      config_with(vision_gateway()),
      effects.GenerationRequest(
        operation: operation_id,
        step_id: "turn-1",
        attempt: 1,
        configuration: capable,
        context: [image_user(), text_user("describe it")],
        stream_options: json.Object([]),
      ),
    )
  assert request.messages == [image_user(), text_user("describe it")]
}

// --- the admission --------------------------------------------------------

// An image-bearing request is admitted against the vision head's own
// facts, not the strand's: the three durable values admission mints
// must describe the identity the request actually reaches.
pub fn admission_reports_the_vision_heads_facts_test() {
  let opened = image_session()
  let hooks_record =
    wiring.compaction_hooks(config_on(vision_gateway(), opened))
  let assert planner.Admitted(
    context_window: 64_000,
    intended_output_limit: 4096,
    api: "acme-api",
    ..,
  ) =
    hooks_record.admission(effects.AdmissionQuery(
      operation: image_operation(opened),
      step_id: "turn-1",
      attempt: 1,
      configuration: text_only_configuration(),
      stream_options: json.Object([]),
    ))
  Nil
}

// The worded refusal, live through the admission hook: the operation
// names a strand whose committed newest message carries an image, the
// strand is pinned to the text-only entry, and no vision route
// resolves. This is the exact path an operator's dropped image takes
// on an unrouted host.
pub fn admission_refuses_without_a_vision_route_test() {
  let opened = image_session()
  let hooks_record = wiring.compaction_hooks(config_on(blind_gateway(), opened))
  let assert planner.AdmissionUnavailable(error:) =
    hooks_record.admission(effects.AdmissionQuery(
      operation: image_operation(opened),
      step_id: "turn-1",
      attempt: 1,
      configuration: text_only_configuration(),
      stream_options: json.Object([]),
    ))
  assert error.code == "image_unsupported"
  assert string.contains(error.message, "loom-text")
  assert string.contains(error.message, "no vision route resolves")
}

// A routed vision chain whose own head the catalogue declares
// text-only is a misconfiguration, and the refusal names the blind
// entry rather than blaming the strand's model.
pub fn admission_refuses_a_blind_vision_route_test() {
  let opened = image_session()
  let gateway_with_blind_vision =
    blind_gateway()
    |> gateway.route(model.Vision, [resolved("loom-text", 200_000)])
  let hooks_record =
    wiring.compaction_hooks(config_on(gateway_with_blind_vision, opened))
  let assert planner.AdmissionUnavailable(error:) =
    hooks_record.admission(effects.AdmissionQuery(
      operation: image_operation(opened),
      step_id: "turn-1",
      attempt: 1,
      configuration: text_only_configuration(),
      stream_options: json.Object([]),
    ))
  assert error.code == "vision_misconfigured"
  // The refusal names the blind entry the operator routed — loom-text,
  // here both the strand's model and the vision head — not the strand's
  // model, which is the difference between a misconfiguration report
  // and a blame-the-victim one.
  assert string.contains(error.message, "loom-text")
  assert string.contains(error.message, "unable to read images")
  assert !string.contains(error.message, "no vision route resolves")
}

// The worded refusal, when no vision chain is routed at all. The
// session is empty so the classification reads imageless from a store
// that answers nothing; the direct refusal shapes are what the message
// tests ride on.
pub fn no_route_refusal_names_model_and_route_test() {
  let refusal =
    client_vision.no_route_refusal(ModelIdentity(
      provider: "acme",
      model_id: "loom-text",
    ))
  let assert planner.AdmissionUnavailable(error:) = refusal
  assert error.code == "image_unsupported"
  assert string.contains(error.message, "loom-text")
  assert string.contains(error.message, "no vision route resolves")
}

pub fn blind_route_refusal_names_the_blind_entry_test() {
  let refusal = client_vision.blind_route_refusal(resolved("loom-eyes", 64_000))
  let assert planner.AdmissionUnavailable(error:) = refusal
  assert error.code == "vision_misconfigured"
  assert string.contains(error.message, "loom-eyes")
}

// --- the catalogue key ----------------------------------------------------

pub fn catalogue_parses_vision_test() {
  let assert Ok(catalogue) =
    catalog.parse(
      "[models.acme]\n"
      <> "dialect = \"anthropic\"\n"
      <> "api_key_env = \"ACME_KEY\"\n"
      <> "model_id = \"loom-1\"\n"
      <> "context_window = 200000\n"
      <> "max_output_tokens = 8192\n"
      <> "vision = true\n"
      <> "\n"
      <> "[roles]\n"
      <> "main = [\"acme\"]\n",
    )
  let assert [entry] = catalogue.models
  assert entry.vision == catalog.ReadsImages
}

pub fn catalogue_vision_defaults_to_text_only_test() {
  let assert Ok(catalogue) =
    catalog.parse(
      "[models.acme]\n"
      <> "dialect = \"anthropic\"\n"
      <> "api_key_env = \"ACME_KEY\"\n"
      <> "model_id = \"loom-1\"\n"
      <> "context_window = 200000\n"
      <> "max_output_tokens = 8192\n"
      <> "\n"
      <> "[roles]\n"
      <> "main = [\"acme\"]\n",
    )
  let assert [entry] = catalogue.models
  assert entry.vision == catalog.TextOnly
}

pub fn catalogue_refuses_a_non_boolean_vision_test() {
  let assert Error(reason) =
    catalog.parse(
      "[models.acme]\n"
      <> "dialect = \"anthropic\"\n"
      <> "api_key_env = \"ACME_KEY\"\n"
      <> "model_id = \"loom-1\"\n"
      <> "context_window = 200000\n"
      <> "max_output_tokens = 8192\n"
      <> "vision = \"maybe\"\n"
      <> "\n"
      <> "[roles]\n"
      <> "main = [\"acme\"]\n",
    )
  assert string.contains(reason, "vision must be true or false")
}

// --- the classification ---------------------------------------------------

// The reminder is the harness speaking; a reminder appended after an
// image-bearing turn must not mask the image from the classifier.
pub fn reminder_does_not_mask_the_image_test() {
  let #(now, _clock) = clock.read(clock.fixed(at: 99))
  let reminder =
    message.UserMessage(
      content: [
        message.UserText(
          text: checkpoint.reminder_text(1200),
          text_signature: None,
        ),
      ],
      timestamp: now,
      origin: None,
    )
  assert client_vision.image_bearing([image_user(), reminder])
}

pub fn text_only_projection_classifies_imageless_test() {
  assert !client_vision.image_bearing([text_user("hello")])
  assert !client_vision.image_bearing([])
}
