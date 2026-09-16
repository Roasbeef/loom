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
import gleam/bit_array
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
import provider/adapter/openai
import provider/gateway
import provider/http
import provider/model
import provider/secret
import runtime/effects
import session/session
import simplifile
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
    response_entry: ids.mint_entry(ids.generator(clock.fixed(0), 991)).0,
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
fn assistant_tool_call() -> message.AgentMessage {
  let assert message.AssistantMessage(..) as answer = assistant_answer()
    as "the fixture answer is an assistant message"
  message.AssistantMessage(
    ..answer,
    content: [
      message.AssistantToolCall(message.ToolCall(
        id: "call_look_1",
        name: "fs_read",
        arguments: json.Object([#("path", json.String("notes.txt"))]),
        thought_signature: None,
        namespace: None,
      )),
    ],
    stop_reason: message.ToolUse,
  )
}

fn tool_result() -> message.AgentMessage {
  message.ToolResultMessage(
    tool_call_id: "call_look_1",
    tool_name: "fs_read",
    content: [message.ToolResultText(text: "alpha", text_signature: None)],
    details: None,
    usage: None,
    added_tool_names: None,
    is_error: False,
    timestamp: 0,
  )
}

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
        response_entry: ids.mint_entry(ids.generator(clock.fixed(0), 991)).0,
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

pub fn catalogue_vision_defaults_to_reading_images_test() {
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
  assert entry.vision == catalog.ReadsImages
}

pub fn catalogue_refuses_a_text_only_vision_chain_test() {
  let assert Error(reason) =
    catalog.parse(
      "[models.texty]\n"
      <> "dialect = \"anthropic\"\n"
      <> "api_key_env = \"TEXT_KEY\"\n"
      <> "model_id = \"loom-text\"\n"
      <> "context_window = 200000\n"
      <> "max_output_tokens = 8192\n"
      <> "vision = false\n"
      <> "\n"
      <> "[models.eyes]\n"
      <> "dialect = \"anthropic\"\n"
      <> "api_key_env = \"VISION_KEY\"\n"
      <> "model_id = \"loom-eyes\"\n"
      <> "context_window = 64000\n"
      <> "max_output_tokens = 8192\n"
      <> "vision = true\n"
      <> "\n"
      <> "[roles]\n"
      <> "main = [\"texty\"]\n"
      <> "vision = [\"eyes\", \"texty\"]\n",
    )
  assert string.contains(reason, "roles.vision")
  assert string.contains(reason, "\"texty\"")
  assert string.contains(reason, "vision = false")
}

pub fn catalogue_accepts_an_all_reading_vision_chain_test() {
  let assert Ok(catalogue) =
    catalog.parse(
      "[models.texty]\n"
      <> "dialect = \"anthropic\"\n"
      <> "api_key_env = \"TEXT_KEY\"\n"
      <> "model_id = \"loom-text\"\n"
      <> "context_window = 200000\n"
      <> "max_output_tokens = 8192\n"
      <> "\n"
      <> "[models.eyes]\n"
      <> "dialect = \"anthropic\"\n"
      <> "api_key_env = \"VISION_KEY\"\n"
      <> "model_id = \"loom-eyes\"\n"
      <> "context_window = 64000\n"
      <> "max_output_tokens = 8192\n"
      <> "vision = true\n"
      <> "\n"
      <> "[roles]\n"
      <> "main = [\"texty\"]\n"
      <> "vision = [\"eyes\"]\n",
    )
  let assert Ok(chain) = list.key_find(catalogue.roles, model.Vision)
  assert chain == ["eyes"]
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

// The current-turn boundary is what keeps run-start injections from
// masking the operator's image: the notes digest, the memory digest
// and the reminder are all user messages the harness appends *after*
// the operator's prompt, and a newest-user-message walk would
// classify one of them instead — the exact silent placeholder the
// rule exists to remove. Any user message in the unanswered segment
// counts, injections included, which is the whole point.
pub fn a_run_start_injection_does_not_mask_the_image_test() {
  let digest = text_user("Your own notes for strand `main`, newest first.")
  let reminder = text_user("[loom] Your context window is nearly full.")
  assert client_vision.image_bearing([image_user(), digest, reminder])
}

// A reminder alone — the operator's turn answered, only the harness
// speaking since — is not image-bearing.
pub fn a_lone_reminder_classifies_imageless_test() {
  assert !client_vision.image_bearing([
    image_user(),
    assistant_answer(),
    text_user("[loom] Your context window is nearly full."),
  ])
}

// Once an assistant has answered the image turn, the image is a past
// turn: a text follow-up routes to the strand's own model, and the
// placeholderer — not the router — handles the image.
pub fn an_answered_image_is_a_past_turn_test() {
  assert !client_vision.image_bearing([
    image_user(),
    assistant_answer(),
    text_user("and in prose?"),
  ])
}

// A tool call does not end the turn. The vision model answered the
// image with a tool call; the request that carries the result back is
// the same turn, so it must route to the model that saw the image.
pub fn a_tool_step_in_an_image_turn_is_still_image_bearing_test() {
  assert client_vision.image_bearing([
    image_user(),
    assistant_tool_call(),
    tool_result(),
  ])
}

// Two steps deep is still the same turn, and a settled answer ends it.
pub fn a_turn_ends_at_the_answer_not_at_the_tool_call_test() {
  assert client_vision.image_bearing([
    image_user(),
    assistant_tool_call(),
    tool_result(),
    assistant_tool_call(),
    tool_result(),
  ])
  assert !client_vision.image_bearing([
    image_user(),
    assistant_tool_call(),
    tool_result(),
    assistant_answer(),
    tool_result(),
  ])
}

pub fn text_only_projection_classifies_imageless_test() {
  assert !client_vision.image_bearing([text_user("hello")])
  assert !client_vision.image_bearing([])
}

fn model_catalogue(model_id: String, declaration: String) -> catalog.Catalog {
  let assert Ok(parsed) =
    catalog.parse(
      "[models.acme]\ndialect = \"openai\"\napi_key_env = \"ACME_KEY\"\n"
      <> "model_id = \""
      <> model_id
      <> "\"\ncontext_window = 200000\n"
      <> "max_output_tokens = 8192\n"
      <> declaration
      <> "\n[roles]\nmain = [\"acme\"]\n",
    )
    as "the catalogue fixture must parse"
  parsed
}

pub fn glm_capability_default_respects_exact_identity_and_override_test() {
  let assert [glm] = model_catalogue("zai-org/GLM-5.3", "").models
    as "the fixture has one model"
  let assert [short_glm] = model_catalogue("GLM-5.3", "").models
    as "the fixture has one model"
  let assert [flash] = model_catalogue("zai-org/GLM-5.3-Flash", "").models
    as "the fixture has one model"
  let assert [overridden] =
    model_catalogue("zai-org/GLM-5.3", "vision = true\n").models
    as "the fixture has one model"
  assert glm.vision == catalog.TextOnly
  assert short_glm.vision == catalog.TextOnly
  assert flash.vision == catalog.ReadsImages
  assert overridden.vision == catalog.ReadsImages
}

// Build the same projection the driver uses: failed assistant responses
// disappear before vision routing sees the messages.
fn projected_failure_then_prompt(
  prompt: message.AgentMessage,
) -> List(message.AgentMessage) {
  let assert message.AssistantMessage(..) as answer = assistant_answer()
    as "the fixture is an assistant message"
  let failure =
    message.AssistantMessage(
      ..answer,
      content: [],
      stop_reason: message.Errored,
    )
  let messages =
    list.append(list.repeat(image_user(), 14), [
      failure,
      prompt,
      text_user("notes digest"),
    ])
  messages
  |> list.index_map(fn(message, index) {
    MessageEntry(
      id: ids.mint_entry(ids.generator(clock.fixed(0), index + 100)).0,
      parent: None,
      seq: index + 1,
      ts: 0,
      message:,
      terminate: False,
    )
  })
  |> list.reverse
  |> session.project_scan
}

fn owner_prompt(content: List(message.UserBlock)) -> message.AgentMessage {
  message.UserMessage(
    content:,
    timestamp: 0,
    origin: Some(message.Origin("owner-fixture", "Owner")),
  )
}

pub fn text_prompt_after_fourteen_images_and_provider_failure_recovers_test() {
  let context =
    projected_failure_then_prompt(
      owner_prompt([message.UserText("test", None)]),
    )
  let request =
    wiring.provider_request(config_with(vision_gateway()), generation(context))
  assert list.length(context) == 16
    as "the failed response was removed by the production projection"
  assert request.messages == client_vision.placeholdered(context)
  assert request.target != client_vision.routed_target(Some(model.ThinkingOff))
  assert !client_vision.image_bearing(context)
}

pub fn new_image_prompt_after_failure_stays_on_vision_through_tools_test() {
  let context =
    projected_failure_then_prompt(
      owner_prompt([message.UserImage("YQ==", "image/png")]),
    )
  let with_tools = list.append(context, [assistant_tool_call(), tool_result()])
  let request =
    wiring.provider_request(
      config_with(vision_gateway()),
      generation(with_tools),
    )
  assert client_vision.image_bearing(with_tools)
  assert request.target == client_vision.routed_target(Some(model.ThinkingOff))
  assert request.messages == with_tools
}

/// Catalogue defaults must reach dispatch, not merely a parsing assertion.
pub fn default_glm_routes_images_and_recovers_text_requests_test() {
  let catalogue = model_catalogue("zai-org/GLM-5.3", "")
  let assert [entry] = catalogue.models as "the fixture has one model"
  let config = config_with(vision_gateway())
  let config =
    wiring.Config(..config, facts: fn(identity: ModelIdentity) {
      case identity.model_id {
        "zai-org/GLM-5.3" ->
          Ok(#(catalog.resolved(entry), "openai-completions", entry.vision))
        _ -> entry_facts(identity)
      }
    })
  let assert effects.GenerationRequest(..) as spec = generation([image_user()])
    as "the fixture is a generation"
  let configuration =
    StrandConfiguration(
      ..text_only_configuration(),
      model: ModelIdentity("acme", "zai-org/GLM-5.3"),
    )
  let spec = effects.GenerationRequest(..spec, configuration:)
  let image_request = wiring.provider_request(config, spec)
  assert image_request.target
    == client_vision.routed_target(Some(model.ThinkingOff))
  assert image_request.messages == [image_user()]

  let context =
    projected_failure_then_prompt(
      owner_prompt([message.UserText("test", None)]),
    )
  let text_request =
    wiring.provider_request(config, effects.GenerationRequest(..spec, context:))
  assert text_request.messages == client_vision.placeholdered(context)
  assert text_request.target != image_request.target
}

/// Held prompts form one admission batch, even when its last item is text.
pub fn held_image_and_text_batch_routes_admission_and_dispatch_test() {
  let opened = image_session()
  let assert Ok(Some(session.Cell(value: Some(image_id), ..))) =
    session.strand_leaf(opened, "main")
    as "the fixture's image is the initial leaf"
  let operation_id = image_operation(opened)
  let text_id = ids.mint_entry(ids.generator(clock.fixed(0), 12_345)).0
  let text = owner_prompt([message.UserText("review that image", None)])
  let assert Ok(_) =
    storage.commit(
      opened.store,
      Tx(
        writes: [
          InsertEntry(MessageEntry(
            id: text_id,
            parent: Some(image_id),
            seq: 0,
            ts: 0,
            message: text,
            terminate: False,
          )),
          SetRegister(
            ns: register.StrandLeaf,
            key: "main",
            value: register.leaf_value(Some(text_id)),
          ),
          SetRegister(
            ns: register.OpMeta,
            key: ids.op_id_to_string(operation_id),
            value: register.RegisterValue(
              machine_codec.encode_operation(operation.Operation(
                id: operation_id,
                strand: "main",
                source_leaf: None,
                started_at: 0,
                intent: operation.RunIntent(prompt_entries: [image_id, text_id]),
              )),
            ),
          ),
        ],
        expected: [],
      ),
    )
    as "the held batch and its admission must commit"
  let config = config_on(vision_gateway(), opened)
  let hooks_record = wiring.compaction_hooks(config)
  let assert planner.Admitted(context_window: 64_000, ..) =
    hooks_record.admission(effects.AdmissionQuery(
      operation: operation_id,
      step_id: "turn-1",
      attempt: 1,
      configuration: text_only_configuration(),
      stream_options: json.Object([]),
    ))
    as "admission must account against the vision model"
  let assert effects.GenerationRequest(..) as spec =
    generation([image_user(), text])
    as "the fixture is a generation"
  let spec = effects.GenerationRequest(..spec, operation: operation_id)
  let request = wiring.provider_request(config, spec)
  assert request.target == client_vision.routed_target(Some(model.ThinkingOff))
  assert request.messages == [image_user(), text]

  // A run-end continuation retains the image model for this admitted run.
  let continued =
    wiring.provider_request(
      config,
      effects.GenerationRequest(..spec, context: [
        image_user(),
        text,
        assistant_answer(),
        text_user("follow-up"),
      ]),
    )
  assert continued.target == request.target

  // A successor run excludes the previous batch at its immutable source leaf.
  let next_op = ids.mint_op(ids.generator(clock.fixed(0), 9876)).0
  let next_id = ids.mint_entry(ids.generator(clock.fixed(0), 9876)).0
  let next_prompt = owner_prompt([message.UserText("plain text retry", None)])
  let assert Ok(_) =
    storage.commit(
      opened.store,
      Tx(
        writes: [
          InsertEntry(MessageEntry(
            id: next_id,
            parent: Some(text_id),
            seq: 0,
            ts: 0,
            message: next_prompt,
            terminate: False,
          )),
          SetRegister(
            ns: register.StrandLeaf,
            key: "main",
            value: register.leaf_value(Some(next_id)),
          ),
          SetRegister(
            ns: register.OpMeta,
            key: ids.op_id_to_string(next_op),
            value: register.RegisterValue(
              machine_codec.encode_operation(operation.Operation(
                id: next_op,
                strand: "main",
                source_leaf: Some(text_id),
                started_at: 0,
                intent: operation.RunIntent(prompt_entries: [next_id]),
              )),
            ),
          ),
        ],
        expected: [],
      ),
    )
    as "the successor operation must commit"
  let recovered =
    wiring.provider_request(
      config,
      effects.GenerationRequest(..spec, operation: next_op, context: [
        image_user(),
        text,
        next_prompt,
      ]),
    )
  assert recovered.target == model.ForRole(model.Main, Some(model.ThinkingOff))
  assert recovered.messages
    == client_vision.placeholdered([image_user(), text, next_prompt])
}

// This exercises the production disk seam and tool-result conversion before
// routing and serialization, rather than manufacturing only a user image.
pub fn disk_image_read_routes_to_vision_and_preserves_pixels_test() {
  let assert Ok(here) = simplifile.current_directory()
    as "the test runner must have a working directory"
  let workspace = here <> "/build/vision-disk-image"
  let assert Ok(Nil) = simplifile.create_directory_all(workspace)
    as "the image workspace must exist"
  let data =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aoykAAAAASUVORK5CYII="
  let assert Ok(bytes) = bit_array.base64_decode(data)
    as "the fixture is a one-pixel PNG"
  let assert Ok(Nil) = simplifile.write_bits(workspace <> "/pixel.png", bytes)
    as "the image must exist on disk"
  let config =
    wiring.Config(
      ..config_with(vision_gateway()),
      workspace:,
      base_policy: policy.workspace_default(workspace),
    )
  let assert message.AssistantMessage(
    content: [message.AssistantToolCall(call:)],
    ..,
  ) as assistant = assistant_tool_call()
    as "the fixture assistant requests one read"
  let arguments = json.Object([#("path", json.String("pixel.png"))])
  let call = message.ToolCall(..call, arguments:)
  let operation_id = image_operation(config.session)
  let assert effects.ToolCompleted(result:, terminate: False) =
    wiring.run_tool(
      config,
      effects.ToolRun(
        operation: operation_id,
        step_id: "read-image",
        source_index: 0,
        strand: "main",
        call:,
        arguments:,
        replay: operation.ReplaySafe,
        grants: [],
      ),
    )
    as "the production read must complete"
  let assert message.ToolResultMessage(is_error: False, content: [_, image], ..) =
    result
    as "disk image bytes must survive conversion to the durable message type"
  assert image == message.ToolResultImage(data, "image/png")
  let context = [
    owner_prompt([message.UserText("look at pixel.png", None)]),
    message.AssistantMessage(..assistant, content: [
      message.AssistantToolCall(call),
    ]),
    result,
  ]
  // Admission reads durable history before dispatch builds its request. Both
  // must resolve the vision head, including its smaller context allowance.
  let assert Ok(_) =
    session.ensure_strand(config.session, "main", text_only_configuration())
    as "the disk-read strand must exist"
  let entry_id = fn(index) {
    ids.mint_entry(ids.generator(clock.fixed(0), 500 + index)).0
  }
  let writes =
    list.index_map(context, fn(entry, index) {
      InsertEntry(MessageEntry(
        id: entry_id(index),
        parent: case index {
          0 -> None
          _ -> Some(entry_id(index - 1))
        },
        seq: 0,
        ts: 0,
        message: entry,
        terminate: False,
      ))
    })
  let assert Ok(_) =
    storage.commit(
      config.session.store,
      Tx(
        writes: list.append(writes, [
          SetRegister(
            register.StrandLeaf,
            "main",
            register.leaf_value(Some(entry_id(2))),
          ),
        ]),
        expected: [],
      ),
    )
    as "the read transcript must commit"
  let query =
    effects.AdmissionQuery(
      operation: operation_id,
      step_id: "after-read",
      attempt: 1,
      configuration: text_only_configuration(),
      stream_options: json.Object([]),
    )
  let assert planner.Admitted(context_window: 64_000, ..) =
    wiring.compaction_hooks(config).admission(query)
    as "a disk image must use the vision head's admission facts"
  let unrouted = wiring.Config(..config, gateway: blind_gateway())
  let assert planner.AdmissionUnavailable(error:) =
    wiring.compaction_hooks(unrouted).admission(query)
    as "a disk image without a vision route must be refused before dispatch"
  assert error.code == "image_unsupported"

  let request = wiring.provider_request(config, generation(context))
  assert request.target == client_vision.routed_target(Some(model.ThinkingOff))
  assert request.messages == context
  let wire =
    openai.build_request(
      "https://example.test",
      "k",
      resolved("loom-eyes", 64_000),
      request,
    )
  assert string.contains(wire.body, "data:image/png;base64," <> data)

  // Further tool steps stay on vision; a later human text prompt can recover
  // even if projection has removed a failed provider response.
  let continued = list.append(context, [assistant_tool_call(), tool_result()])
  assert wiring.provider_request(config, generation(continued)).target
    == request.target
  let next_context =
    list.append(continued, [
      owner_prompt([message.UserText("continue in text", None)]),
    ])
  let next = wiring.provider_request(config, generation(next_context))
  assert next.target == model.ForRole(model.Main, Some(model.ThinkingOff))
  assert next.messages == client_vision.placeholdered(next_context)
  let text_wire =
    openai.build_request(
      "https://example.test",
      "k",
      resolved("loom-text", 200_000),
      next,
    )
  assert !string.contains(text_wire.body, data)
  assert string.contains(
    text_wire.body,
    "described earlier in this conversation",
  )
}

pub fn historical_tool_image_placeholder_preserves_result_metadata_test() {
  let original =
    message.ToolResultMessage(
      tool_call_id: "read-photo",
      tool_name: "fs_read",
      content: [
        message.ToolResultText("photo.png", None),
        message.ToolResultImage("YQ==", "image/png"),
      ],
      details: Some(json.Object([#("path", json.String("photo.png"))])),
      usage: None,
      added_tool_names: None,
      is_error: False,
      timestamp: 42,
    )
  let expected =
    message.ToolResultMessage(..original, content: [
      message.ToolResultText("photo.png", None),
      message.ToolResultText(
        "[image: image/png, described earlier in this conversation]",
        None,
      ),
    ])
  assert client_vision.placeholdered([original]) == [expected]
  assert client_vision.image_bearing([
    text_user("look"),
    assistant_tool_call(),
    original,
  ])
  assert !client_vision.image_bearing([original, assistant_answer()])
}
