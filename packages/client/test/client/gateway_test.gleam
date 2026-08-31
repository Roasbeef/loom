//// The hub's protocol conduct: strict envelopes answered in-band,
//// unknown names tolerated with `unsupported`, subscription gating,
//// and the semantic error codes of the command table.

import broker/escalation as broker_escalation
import broker/policy.{type Grant}
import client/catalog
import client/gateway
import client/grants
import client/protocol
import client/provider_relay
import client/serve
import core/clock
import core/ids
import core/json
import core/message
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/string
import machine/strand as machine_strand
import provider/model
import provider/stream
import runtime/api
import runtime/effects
import runtime/escalation as durable
import session/session
import tools/tool

// --- wiring ----------------------------------------------------------------

type Harness {
  Harness(
    hub: gateway.Gateway,
    connection: Int,
    inbox: Subject(String),
    runtime: api.Runtime,
  )
}

fn start_harness() -> Harness {
  start_harness_with(catalog: None)
}

// Every harness but one carries the production tool registry, so
// `set_config active_tools` has the same registry to validate against
// that the effect wiring dispatches through.
fn start_harness_with(catalog catalogue: Option(catalog.Catalog)) -> Harness {
  start_harness_full(catalogue, Some(serve.registry(None, None, None, None)))
}

// The host that configured no registry: active-set changes have
// nothing to check against and are refused.
fn start_harness_without_registry() -> Harness {
  start_harness_full(None, None)
}

// A two-entry catalogue whose second entry ("fallback") is routed but
// not the main head, so switching to it exercises the interesting
// half of set-by-name.
fn test_catalog() -> catalog.Catalog {
  catalog.Catalog(
    models: [
      catalog.CatalogModel(
        name: "acme",
        dialect: catalog.Anthropic,
        base_url: "https://acme.test",
        api_key_env: "ACME_KEY",
        model_id: "loom-1",
        context_window: 100_000,
        max_output_tokens: 4096,
        thinking: model.ThinkingOff,
      ),
      catalog.CatalogModel(
        name: "fallback",
        dialect: catalog.OpenAiCompatible,
        base_url: "https://fallback.test/v1",
        api_key_env: "FALLBACK_KEY",
        model_id: "fb-9",
        context_window: 64_000,
        max_output_tokens: 2048,
        thinking: model.ThinkingOff,
      ),
    ],
    roles: [#(model.Main, ["acme", "fallback"])],
    mcp_servers: [],
  )
}

fn start_harness_full(
  catalogue: Option(catalog.Catalog),
  registry: Option(tool.Registry),
) -> Harness {
  let assert Ok(session) =
    session.open_memory(clock.stepping(from: 1_756_000_000_000, by: 3))
  let assert Ok(counter) =
    actor.new(1)
    |> actor.on_message(fn(next, reply: Subject(Int)) {
      process.send(reply, next)
      actor.continue(next + 1)
    })
    |> actor.start
  let entropy = fn() {
    9_000_000
    + process.call(counter.data, waiting: 1000, sending: fn(reply) { reply })
    * 7919
  }
  let name = process.new_name(prefix: "loom_gateway_test")
  let forwarder_name = process.new_name(prefix: "loom_forwarder_test")
  let assert Ok(_forwarder) =
    gateway.commit_forwarder(to: name, as_name: forwarder_name)
  let effects =
    effects.Effects(
      clock: clock.stepping(from: 1_756_000_000_000, by: 3),
      entropy:,
      timers: effects.real_timers(),
      provider: effects.ProviderSurface(timeout_ms: 1000, request: fn(_spec) {
        let events = process.new_subject()
        let response =
          message.AssistantMessage(
            content: [
              message.AssistantText(text: "ok", text_signature: None),
            ],
            api: "test",
            provider: "acme",
            model: "loom-1",
            response_model: None,
            response_id: None,
            diagnostics: None,
            usage: effects.zero_usage(),
            stop_reason: message.Stop,
            deferred: None,
            error_message: None,
            raw_stop_reason: None,
            end_turn: Some(True),
            timestamp: 0,
          )
        let assert Ok(settled) = stream.settle(response)
        process.send(
          events,
          stream.Settled(message: settled, usage: effects.zero_usage()),
        )
        stream.immediate(events:, cancel: fn() { Nil })
      }),
      tools: effects.ToolSurface(
        clear: fn(_query) { effects.ClearanceRefused(reason: "no tools") },
        run: fn(_run) { effects.ToolFailed(reason: "no tools") },
        replay_still_safe: fn(_name) { False },
        execution_mode: fn(_name) { effects.ExclusiveExecution },
      ),
      hooks: effects.default_hooks(),
    )
  let configuration =
    machine_strand.StrandConfiguration(
      model: machine_strand.ModelIdentity(provider: "acme", model_id: "loom-1"),
      thinking_level: machine_strand.ThinkingOff,
      active_tool_names: [],
    )
  let options = api.default_options(configuration)
  let assert Ok(runtime) =
    api.open(
      session,
      effects,
      api.Options(..options, poll_interval_ms: 25, subscribers: [
        process.named_subject(forwarder_name),
      ]),
    )
  let options = gateway.default_options("sess-01", runtime)
  let options = case catalogue {
    Some(catalogue) -> gateway.with_catalog(options, catalogue)
    None -> options
  }
  let options = case registry {
    Some(registry) -> gateway.with_registry(options, registry)
    None -> options
  }
  let assert Ok(_started) = gateway.start(options, name)
  let hub = gateway.Gateway(name:)
  let inbox = process.new_subject()
  let connection = gateway.attach(hub, fn(frame) { process.send(inbox, frame) })
  Harness(hub:, connection:, inbox:, runtime:)
}

fn send_raw(harness: Harness, frame: String) -> Nil {
  gateway.handle_text(harness.hub, harness.connection, frame)
}

fn send(harness: Harness, id: Int, command: protocol.Command) -> Nil {
  send_raw(
    harness,
    protocol.encode_command(protocol.CommandEnvelope(id:, command:)),
  )
}

fn next(harness: Harness) -> protocol.EventEnvelope {
  let assert Ok(frame) = process.receive(harness.inbox, within: 5000)
    as "an event frame must arrive"
  let assert Ok(envelope) = protocol.decode_event(frame)
    as "every emitted frame must decode"
  envelope
}

fn expect_error(harness: Harness, id: Int, code: String) -> Nil {
  let envelope = next(harness)
  assert envelope.reply_to == Some(id)
  let assert protocol.ErrorEvent(code: got, ..) = envelope.event
    as "an error reply was expected"
  assert got == code
  Nil
}

fn subscribe(harness: Harness) -> Nil {
  send(harness, 1, protocol.Subscribe(session: "sess-01", from_seq: None))
  let envelope = next(harness)
  assert envelope.reply_to == Some(1)
  let assert protocol.SnapshotEvent(protocol.FullSnapshot(..)) = envelope.event
    as "subscribe must reply with a full snapshot"
  Nil
}

// --- who is attached -------------------------------------------------------

/// The count `client/serve` puts to the escalation seam as "is a human
/// there?", on every poll of every parked call. It had no test at all,
/// and every parking test injects the answer directly — so nothing
/// asserted that attaching or leaving moves it.
pub fn attached_counts_live_connections_test() {
  let harness = start_harness()
  assert gateway.attached(harness.hub) == 1
    as "the harness's own connection counts"

  let second = gateway.attach(harness.hub, fn(_frame) { Nil })
  assert gateway.attached(harness.hub) == 2
  gateway.detach(harness.hub, second)
  assert gateway.attached(harness.hub) == 1
    as "a detached connection stops counting"

  // Detaching an id nobody holds is a no-op, not a decrement: a
  // miscounted hub would park a call for a human who has gone.
  gateway.detach(harness.hub, 9999)
  assert gateway.attached(harness.hub) == 1

  gateway.detach(harness.hub, harness.connection)
  assert gateway.attached(harness.hub) == 0
    as "the last client leaving makes the session headless"
}

/// A hub that was never started answers zero rather than exiting the
/// caller — a server without a gateway is by definition not being
/// watched, and the only caller is a tool effect process.
pub fn attached_without_a_hub_is_zero_test() {
  let name = process.new_name(prefix: "loom_absent_hub")
  assert gateway.attached(gateway.Gateway(name:)) == 0
}

/// A hub that is alive but does not answer in time counts as nobody
/// attached. `process.call` exits its *caller* on timeout rather than
/// returning an error, and the caller here is a parked tool call's own
/// effect process asking once a second for the length of the park — so a
/// hub busy behind a long pull would kill the very call it is being
/// asked about, and the driver would report a death with no stated
/// reason where the seam's doc promises an in-band policy refusal.
pub fn attached_is_zero_when_the_hub_does_not_answer_test() {
  let name = process.new_name(prefix: "loom_silent_hub")
  let assert Ok(_silent) =
    actor.new(Nil)
    |> actor.on_message(fn(state, _message) { actor.continue(state) })
    |> actor.named(name)
    |> actor.start
    as "the silent hub must start"
  assert gateway.attached(gateway.Gateway(name:)) == 0
}

/// And a hub that dies while being asked answers zero too, rather than
/// taking the asker down with it.
pub fn attached_is_zero_when_the_hub_dies_mid_question_test() {
  let name = process.new_name(prefix: "loom_dying_hub")
  let assert Ok(started) =
    actor.new(Nil)
    |> actor.on_message(fn(_state, _message) { actor.stop() })
    |> actor.named(name)
    |> actor.start
    as "the dying hub must start"
  let _pid = started.pid
  assert gateway.attached(gateway.Gateway(name:)) == 0
}

// --- envelope conduct ------------------------------------------------------

pub fn malformed_frame_answered_in_band_test() {
  let harness = start_harness()
  send_raw(harness, "{not json")
  let envelope = next(harness)
  assert envelope.reply_to == None
  let assert protocol.ErrorEvent(code: "bad_request", ..) = envelope.event
}

pub fn wrong_version_refused_with_reply_test() {
  let harness = start_harness()
  send_raw(harness, "{\"v\":2,\"id\":3,\"cmd\":\"abort\",\"body\":{}}")
  expect_error(harness, 3, "bad_request")
}

pub fn unknown_command_unsupported_test() {
  let harness = start_harness()
  subscribe(harness)
  send_raw(harness, "{\"v\":1,\"id\":4,\"cmd\":\"levitate\",\"body\":{}}")
  expect_error(harness, 4, "unsupported")
}

// --- subscription gating ---------------------------------------------------

pub fn commands_require_subscription_test() {
  let harness = start_harness()
  send(harness, 2, protocol.Abort(strand: "main"))
  expect_error(harness, 2, "bad_request")
}

pub fn wrong_session_refused_test() {
  let harness = start_harness()
  send(harness, 2, protocol.Subscribe(session: "elsewhere", from_seq: None))
  expect_error(harness, 2, "unknown_session")
}

pub fn double_subscribe_conflicts_test() {
  let harness = start_harness()
  subscribe(harness)
  send(harness, 5, protocol.Subscribe(session: "sess-01", from_seq: None))
  expect_error(harness, 5, "conflict")
}

// --- semantic errors -------------------------------------------------------

pub fn steer_idle_conflicts_test() {
  let harness = start_harness()
  subscribe(harness)
  send(harness, 3, protocol.Steer(strand: "main", text: "faster"))
  let envelope = next(harness)
  assert envelope.reply_to == Some(3)
  let assert protocol.ErrorEvent(code: "conflict", message:, ..) =
    envelope.event
  // The exact message the golden error fixture shows.
  assert message == "strand main has no live operation to steer"
}

pub fn unknown_strand_refused_test() {
  let harness = start_harness()
  subscribe(harness)
  send(harness, 6, protocol.Prompt(strand: "ghost", text: "hi"))
  expect_error(harness, 6, "unknown_strand")
}

pub fn unknown_escalation_refused_test() {
  let harness = start_harness()
  subscribe(harness)
  send(harness, 7, protocol.Deny(escalation_id: "esc-none"))
  expect_error(harness, 7, "unknown_escalation")
}

pub fn set_config_unknown_key_refused_test() {
  let harness = start_harness()
  subscribe(harness)
  send(
    harness,
    8,
    protocol.SetConfig(
      strand: None,
      config: json.Object([#("warp_speed", json.Bool(True))]),
    ),
  )
  expect_error(harness, 8, "bad_request")
}

pub fn set_config_queue_mode_applies_test() {
  let harness = start_harness()
  subscribe(harness)
  send(
    harness,
    9,
    protocol.SetConfig(
      strand: Some("main"),
      config: json.Object([#("queue_mode", json.String("one_at_a_time"))]),
    ),
  )
  let envelope = next(harness)
  assert envelope.reply_to == Some(9)
  let assert protocol.SnapshotEvent(protocol.ConfigSnapshot(config:)) =
    envelope.event
  let assert json.Object(fields) = config
  assert list.key_find(fields, "queue_mode") == Ok(json.String("one_at_a_time"))
  // The per-strand keys ride along when a strand is named.
  let assert Ok(json.Object(model_fields)) = list.key_find(fields, "model")
  assert list.key_find(model_fields, "model_id") == Ok(json.String("loom-1"))
}

// --- the model catalogue ---------------------------------------------------

pub fn models_lists_catalogue_test() {
  let harness = start_harness_with(catalog: Some(test_catalog()))
  subscribe(harness)
  send(harness, 10, protocol.ListModels)
  let envelope = next(harness)
  assert envelope.reply_to == Some(10)
  let assert protocol.SnapshotEvent(protocol.ModelsSnapshot(models:)) =
    envelope.event
  assert models
    == [
      protocol.ModelInfo(
        name: "acme",
        dialect: "anthropic",
        model_id: "loom-1",
        roles: ["main"],
        active: ["main"],
      ),
      protocol.ModelInfo(
        name: "fallback",
        dialect: "openai",
        model_id: "fb-9",
        roles: ["main"],
        active: [],
      ),
    ]
}

pub fn models_without_catalogue_lists_nothing_test() {
  let harness = start_harness()
  subscribe(harness)
  send(harness, 10, protocol.ListModels)
  let envelope = next(harness)
  assert envelope.reply_to == Some(10)
  let assert protocol.SnapshotEvent(protocol.ModelsSnapshot(models: [])) =
    envelope.event
}

pub fn set_config_model_name_switches_strand_test() {
  let harness = start_harness_with(catalog: Some(test_catalog()))
  subscribe(harness)
  send(
    harness,
    11,
    protocol.SetConfig(
      strand: Some("main"),
      config: json.Object([#("model_name", json.String("fallback"))]),
    ),
  )
  let envelope = next(harness)
  assert envelope.reply_to == Some(11)
  let assert protocol.SnapshotEvent(protocol.ConfigSnapshot(config:)) =
    envelope.event
  // The durable identity switched to the resolved catalogue facts, and
  // the effective config names the entry back.
  let assert json.Object(fields) = config
  let assert Ok(json.Object(model_fields)) = list.key_find(fields, "model")
  assert list.key_find(model_fields, "provider") == Ok(json.String("fallback"))
  assert list.key_find(model_fields, "model_id") == Ok(json.String("fb-9"))
  assert list.key_find(fields, "model_name") == Ok(json.String("fallback"))
}

pub fn set_config_unknown_model_name_refused_test() {
  let harness = start_harness_with(catalog: Some(test_catalog()))
  subscribe(harness)
  send(
    harness,
    12,
    protocol.SetConfig(
      strand: Some("main"),
      config: json.Object([#("model_name", json.String("ghost"))]),
    ),
  )
  expect_error(harness, 12, "bad_request")
}

pub fn set_config_model_name_needs_a_catalogue_test() {
  let harness = start_harness()
  subscribe(harness)
  send(
    harness,
    13,
    protocol.SetConfig(
      strand: Some("main"),
      config: json.Object([#("model_name", json.String("acme"))]),
    ),
  )
  expect_error(harness, 13, "bad_request")
}

// Without a strand the switch is session-wide: every strand's durable
// configuration moves to the named entry.
pub fn set_config_model_name_without_strand_switches_all_test() {
  let harness = start_harness_with(catalog: Some(test_catalog()))
  subscribe(harness)
  send(
    harness,
    14,
    protocol.SetConfig(
      strand: None,
      config: json.Object([#("model_name", json.String("fallback"))]),
    ),
  )
  let envelope = next(harness)
  assert envelope.reply_to == Some(14)
  let assert protocol.SnapshotEvent(protocol.ConfigSnapshot(..)) =
    envelope.event
  // Read the switch back through a strand-scoped effective config.
  send(
    harness,
    15,
    protocol.SetConfig(strand: Some("main"), config: json.Object([])),
  )
  let envelope = next(harness)
  assert envelope.reply_to == Some(15)
  let assert protocol.SnapshotEvent(protocol.ConfigSnapshot(config:)) =
    envelope.event
  let assert json.Object(fields) = config
  assert list.key_find(fields, "model_name") == Ok(json.String("fallback"))
}

// --- thinking levels: seeded once, moved only by their own key -------------

// A catalogue whose main entry declares a reasoning budget. The two tests
// below are the pair issue #14's ruling 3 turns on: the entry seeds a
// *new* strand, and nothing else in `set_config` may move the level.
fn thinking_catalog() -> catalog.Catalog {
  let assert [head, tail] = test_catalog().models
    as "the test catalogue must have two entries"
  catalog.Catalog(..test_catalog(), models: [
    catalog.CatalogModel(..head, thinking: model.ThinkingHigh),
    tail,
  ])
}

fn effective_config(
  harness: Harness,
  id: Int,
  strand: String,
) -> json.JsonValue {
  send(
    harness,
    id,
    protocol.SetConfig(strand: Some(strand), config: json.Object([])),
  )
  let envelope = next(harness)
  assert envelope.reply_to == Some(id)
  let assert protocol.SnapshotEvent(protocol.ConfigSnapshot(config:)) =
    envelope.event
    as "an effective-config snapshot was expected"
  config
}

fn field_of(
  config: json.JsonValue,
  key: String,
) -> Result(json.JsonValue, Nil) {
  let assert json.Object(fields) = config as "an effective config is an object"
  list.key_find(fields, key)
}

// Switching model is not a request to un-raise a reasoning budget
// somebody deliberately raised. A client that wants both sends both keys.
pub fn set_config_model_name_leaves_thinking_level_alone_test() {
  let harness = start_harness_with(catalog: Some(test_catalog()))
  subscribe(harness)
  send(
    harness,
    30,
    protocol.SetConfig(
      strand: Some("main"),
      config: json.Object([#("thinking_level", json.String("high"))]),
    ),
  )
  let envelope = next(harness)
  assert envelope.reply_to == Some(30)
  send(
    harness,
    31,
    protocol.SetConfig(
      strand: Some("main"),
      config: json.Object([#("model_name", json.String("fallback"))]),
    ),
  )
  let envelope = next(harness)
  assert envelope.reply_to == Some(31)
  let assert protocol.SnapshotEvent(protocol.ConfigSnapshot(config:)) =
    envelope.event
  assert field_of(config, "model_name") == Ok(json.String("fallback"))
  assert field_of(config, "thinking_level") == Ok(json.String("high"))
  // …and the level's own key still moves it, in both directions.
  send(
    harness,
    32,
    protocol.SetConfig(
      strand: Some("main"),
      config: json.Object([#("thinking_level", json.String("off"))]),
    ),
  )
  let envelope = next(harness)
  assert envelope.reply_to == Some(32)
  assert field_of(effective_config(harness, 33, "main"), "thinking_level")
    == Ok(json.String("off"))
}

// A strand the hub seeds takes its per-turn level from the catalogue
// entry its identity names — the entry in force — and not from whatever
// level the source strand happened to be sitting at. A copied strand has
// had no conversation yet, so there is no per-turn decision to inherit;
// the same rule seeds `main` at boot and an Agency's children.
pub fn a_forked_strand_is_seeded_from_the_entry_in_force_test() {
  let harness = start_harness_with(catalog: Some(thinking_catalog()))
  subscribe(harness)
  // Main is deliberately moved *away* from the entry's level first, so
  // "inherited the source" and "read the entry" cannot look alike.
  send(
    harness,
    40,
    protocol.SetConfig(
      strand: Some("main"),
      config: json.Object([#("thinking_level", json.String("off"))]),
    ),
  )
  let envelope = next(harness)
  assert envelope.reply_to == Some(40)
  send(
    harness,
    41,
    protocol.Fork(strand: "main", scope: protocol.ScopeBranch, name: None),
  )
  let envelope = next(harness)
  assert envelope.reply_to == Some(41)
  let assert protocol.SnapshotEvent(protocol.StrandsSnapshot(..)) =
    envelope.event
    as "a fork replies with the strand list"
  assert field_of(effective_config(harness, 42, "main-fork"), "thinking_level")
    == Ok(json.String("high"))
  // The source strand is untouched.
  assert field_of(effective_config(harness, 43, "main"), "thinking_level")
    == Ok(json.String("off"))
}

// --- the active tool list --------------------------------------------------

// The durable list is the provider request's cached byte prefix, so
// the hub stores a canonical form: sorted, deduped. A client that
// re-sends the same set in a new order must not move a single byte.
pub fn set_config_active_tools_canonicalized_test() {
  let harness = start_harness()
  subscribe(harness)
  send(
    harness,
    20,
    protocol.SetConfig(
      strand: Some("main"),
      config: json.Object([
        #(
          "active_tools",
          json.Array([
            json.String("grep"),
            json.String("bash"),
            json.String("grep"),
          ]),
        ),
      ]),
    ),
  )
  let envelope = next(harness)
  assert envelope.reply_to == Some(20)
  let assert protocol.SnapshotEvent(protocol.ConfigSnapshot(config:)) =
    envelope.event
  let assert json.Object(fields) = config
  assert list.key_find(fields, "active_tools")
    == Ok(json.Array([json.String("bash"), json.String("grep")]))
}

// An unregistered name refuses the whole command in band and names the
// offender, the way an unknown `model_name` does — and, per
// `apply_config`'s validate-then-apply contract, nothing is written.
pub fn set_config_unknown_active_tool_refused_test() {
  let harness = start_harness()
  subscribe(harness)
  send(
    harness,
    21,
    protocol.SetConfig(
      strand: Some("main"),
      config: json.Object([
        #(
          "active_tools",
          json.Array([json.String("bash"), json.String("ghost")]),
        ),
      ]),
    ),
  )
  let envelope = next(harness)
  assert envelope.reply_to == Some(21)
  let assert protocol.ErrorEvent(code: "bad_request", message:, ..) =
    envelope.event
  assert string.contains(message, "ghost")
  // Read the strand's configuration back: the refused command left the
  // harness's empty active set alone, `bash` included.
  send(
    harness,
    22,
    protocol.SetConfig(strand: Some("main"), config: json.Object([])),
  )
  let envelope = next(harness)
  let assert protocol.SnapshotEvent(protocol.ConfigSnapshot(config:)) =
    envelope.event
  let assert json.Object(fields) = config
  assert list.key_find(fields, "active_tools") == Ok(json.Array([]))
}

// A hub with no registry cannot check membership, so it writes nothing
// rather than trusting the client — the same shape as a `model_name`
// switch with no catalogue.
pub fn set_config_active_tools_needs_a_registry_test() {
  let harness = start_harness_without_registry()
  subscribe(harness)
  send(
    harness,
    23,
    protocol.SetConfig(
      strand: Some("main"),
      config: json.Object([
        #("active_tools", json.Array([json.String("bash")])),
      ]),
    ),
  )
  expect_error(harness, 23, "bad_request")
}

// The canonical durable list is also the one authorization reads:
// after the hub sorts and dedups, `bash` is still active and `fs_write`
// — never sent — is still not.
pub fn set_config_active_tools_preserves_membership_test() {
  let harness = start_harness()
  subscribe(harness)
  send(
    harness,
    24,
    protocol.SetConfig(
      strand: Some("main"),
      config: json.Object([
        #(
          "active_tools",
          json.Array([
            json.String("grep"),
            json.String("bash"),
            json.String("grep"),
          ]),
        ),
      ]),
    ),
  )
  let envelope = next(harness)
  let assert protocol.SnapshotEvent(protocol.ConfigSnapshot(config:)) =
    envelope.event
  let assert json.Object(fields) = config
  let assert Ok(json.Array(stored)) = list.key_find(fields, "active_tools")
  let names =
    list.map(stored, fn(item) {
      let assert json.String(name) = item
      name
    })
  // Set membership, which is what `wiring.clear` tests, is unchanged by
  // the canonicalization: what was sent still clears, what was not sent
  // still does not.
  assert list.contains(names, "bash")
  assert list.contains(names, "grep")
  assert !list.contains(names, "fs_write")
}

// --- escalations: naming the request, and answering that one ---------------
//
// Two properties are under test here and they are the same property
// twice. A prompt must identify the request it is about — which strand
// raised it, which tool would run, with what arguments — and an answer
// must be about the request that was identified. Everything below is one
// of those two halves.

fn op_id(seed: Int) -> ids.OpId {
  let #(op, _generator) = ids.mint_op(ids.generator(clock.fixed(at: 0), seed:))
  op
}

fn scope_on(strand: String, operation: ids.OpId) -> durable.CallScope {
  durable.CallScope(
    operation:,
    strand:,
    step_id: "turn-1:tools",
    source_index: 0,
    call_id: "call-" <> strand,
  )
}

fn wall(seconds: Int) -> Grant {
  policy.GrantLimit(field: policy.WallSeconds, value: seconds)
}

fn to_registry() -> Grant {
  policy.GrantNetwork(network: policy.NetworkProxy(
    allow: ["registry.npmjs.org"],
    proxy: "127.0.0.1:3128",
  ))
}

// Files (or re-files) a record through the same door `client/escalate`
// raises through, so the tests see the record shape the gateway will
// actually meet: scoped, action-bound, and refreshed by whichever call
// most recently stood at the door.
fn claim(
  harness: Harness,
  id: String,
  scope: durable.CallScope,
  action: durable.Action,
  wanted: List(Grant),
) -> Nil {
  let denial =
    grants.encode_denial(
      reason: "tool requirements exceed the session policy",
      source: broker_escalation.PolicyDenial,
      wanted:,
    )
  let assert Ok(durable.Claimed(_record)) =
    api.claim_escalation(
      harness.runtime,
      id,
      denial,
      action:,
      scope:,
      max_asks: 3,
    )
    as "the test's own raise must take the claim"
  Nil
}

// The next escalation event on the wire, skipping anything else the pull
// happened to carry.
fn next_escalation(harness: Harness) -> protocol.EscalationRecord {
  case next(harness).event {
    protocol.EscalationEvent(record:) -> record
    _ -> next_escalation(harness)
  }
}

fn stored(harness: Harness, id: String) -> durable.Escalation {
  let assert Ok(record) = api.escalation(harness.runtime, id)
    as "the record must still be readable"
  record
}

/// #67. The hub used to infer `op`/`strand` from its live map: with one
/// operation open it named that strand for *every* record, and with none
/// open — the state this harness is in — it named neither. The record
/// has carried its own `CallScope` since it started carrying one, so two
/// records raised on two strands must come back naming their own, which
/// fails against the guess in both of its branches.
pub fn an_escalation_names_the_strand_that_raised_it_test() {
  let harness = start_harness()
  subscribe(harness)
  let main_op = op_id(11)
  let sub_op = op_id(22)

  claim(
    harness,
    "esc-main",
    scope_on("main", main_op),
    durable.Action(tool: "bash", digest: "d-main", preview: "{}"),
    [to_registry()],
  )
  let first = next_escalation(harness)
  claim(
    harness,
    "esc-sub",
    scope_on("sub:1", sub_op),
    durable.Action(tool: "bash", digest: "d-sub", preview: "{}"),
    [to_registry()],
  )
  let second = next_escalation(harness)

  assert first.strand == "main"
  assert first.op == ids.op_id_to_string(main_op)
  assert second.strand == "sub:1"
    as "a refusal raised on sub:1 must not be presented as main's"
  assert second.op == ids.op_id_to_string(sub_op)
}

/// The same attribution on the snapshot path, which is a second call
/// site and was wrong in the same way.
pub fn a_snapshot_names_the_strand_that_raised_each_escalation_test() {
  let harness = start_harness()
  claim(
    harness,
    "esc-sub",
    scope_on("sub:1", op_id(33)),
    durable.Action(tool: "bash", digest: "d-sub", preview: "{}"),
    [to_registry()],
  )
  send(harness, 1, protocol.Subscribe(session: "sess-01", from_seq: None))
  let assert protocol.SnapshotEvent(protocol.FullSnapshot(escalations:, ..)) =
    next(harness).event
    as "subscribe must reply with a full snapshot"
  let assert [record] = escalations
  assert record.strand == "sub:1"
  assert record.op == ids.op_id_to_string(op_id(33))
}

/// The prompt carries the action, so a client has something to render
/// beyond "something on this strand wants network".
pub fn an_escalation_carries_the_action_it_would_authorize_test() {
  let harness = start_harness()
  subscribe(harness)
  claim(
    harness,
    "esc-1",
    scope_on("main", op_id(44)),
    durable.Action(
      tool: "bash",
      digest: "0123456789abcdef0123456789abcdef",
      preview: "{\"command\":\"npm install left-pad\"}",
    ),
    [to_registry()],
  )
  let record = next_escalation(harness)
  assert record.tool == "bash"
  assert record.action == "0123456789abcdef0123456789abcdef"
  assert record.preview == "{\"command\":\"npm install left-pad\"}"
  assert record.asked == 1
}

/// #72, as reported. `dedup_key` drops a limit grant's magnitude on
/// purpose, so a retry asking for ten times the timeout lands on the
/// *same* row and refreshes the stored denial. An approval that resolved
/// "everything wanted" at commit time therefore committed a widening the
/// human never saw: a person looking at `wall_seconds 60` could commit
/// `wall_seconds 600`. The answer now states the diff and the action it
/// was drawn from, and a record that has moved refuses it and hands
/// itself back.
pub fn approve_of_a_refreshed_record_is_refused_test() {
  let harness = start_harness()
  subscribe(harness)
  claim(
    harness,
    "esc-1",
    scope_on("main", op_id(55)),
    durable.Action(
      tool: "bash",
      digest: "d-60",
      preview: "{\"timeout_ms\":60000}",
    ),
    [wall(60)],
  )
  let rendered = next_escalation(harness)
  assert rendered.denial
    == Some(
      protocol.Denial(
        reason: "tool requirements exceed the session policy",
        source: "policy",
        enforcement: None,
        wanted: [wall(60)],
      ),
    )

  // The retry: same want, same row, ten times the magnitude.
  claim(
    harness,
    "esc-1",
    scope_on("main", op_id(56)),
    durable.Action(
      tool: "bash",
      digest: "d-600",
      preview: "{\"timeout_ms\":600000}",
    ),
    [wall(600)],
  )
  let _refreshed = next_escalation(harness)

  send(
    harness,
    30,
    protocol.Approve(escalation_id: "esc-1", grants: [wall(60)], action: "d-60"),
  )
  let envelope = next(harness)
  assert envelope.reply_to == Some(30)
  let assert protocol.ErrorEvent(code:, details: Some(details), ..) =
    envelope.event
    as "a stale echo must be refused, with the record attached"
  assert code == protocol.code_stale_approval

  // The refusal carries the record as it now stands, so the client can
  // re-render without waiting for a pull.
  let assert json.Object(fields) = details
  let assert Ok(json.Object(fresh)) = list.key_find(fields, "escalation")
  assert list.key_find(fresh, "action") == Ok(json.String("d-600"))

  // And nothing was decided: the row is still a question.
  assert stored(harness, "esc-1").status == durable.Pending
  assert stored(harness, "esc-1").grants == []
}

/// The action half of the echo, on its own: a diff that is
/// byte-identical across the refresh and an action that moved. This is
/// #65 seen from the prompt's side — the model asks for the same
/// widening in order to run something else — and it is the case the
/// diff check alone cannot see.
pub fn approve_echoing_a_stale_action_is_refused_test() {
  let harness = start_harness()
  subscribe(harness)
  claim(
    harness,
    "esc-1",
    scope_on("main", op_id(70)),
    durable.Action(tool: "bash", digest: "d-true", preview: "{\"c\":\"true\"}"),
    [to_registry()],
  )
  let _rendered = next_escalation(harness)
  claim(
    harness,
    "esc-1",
    scope_on("main", op_id(71)),
    durable.Action(tool: "bash", digest: "d-curl", preview: "{\"c\":\"curl\"}"),
    [to_registry()],
  )
  let _refreshed = next_escalation(harness)

  send(
    harness,
    40,
    protocol.Approve(
      escalation_id: "esc-1",
      grants: [to_registry()],
      action: "d-true",
    ),
  )
  let envelope = next(harness)
  let assert protocol.ErrorEvent(code:, ..) = envelope.event
    as "an approval naming a superseded action must be refused"
  assert code == protocol.code_stale_approval
  assert stored(harness, "esc-1").status == durable.Pending
}

/// The diff half of the echo, on its own: an action that still matches
/// but a diff that has moved underneath it. The composed base a
/// denial is measured against is not the model's to choose, so the two
/// can move independently.
pub fn approve_echoing_a_stale_diff_is_refused_test() {
  let harness = start_harness()
  subscribe(harness)
  let action =
    durable.Action(tool: "bash", digest: "d-1", preview: "{\"command\":\"go\"}")
  claim(harness, "esc-1", scope_on("main", op_id(57)), action, [wall(60)])
  let _rendered = next_escalation(harness)
  claim(harness, "esc-1", scope_on("main", op_id(58)), action, [wall(600)])
  let _refreshed = next_escalation(harness)

  send(
    harness,
    31,
    protocol.Approve(escalation_id: "esc-1", grants: [wall(60)], action: "d-1"),
  )
  let envelope = next(harness)
  let assert protocol.ErrorEvent(code:, ..) = envelope.event
  assert code == protocol.code_stale_approval
  assert stored(harness, "esc-1").status == durable.Pending
}

/// An approval may narrow what was asked for and may never widen it. The
/// widening direction is the same refusal as a stale echo, because from
/// the record's side the two are the same statement: this is not my
/// diff.
pub fn approve_cannot_widen_past_the_wanted_diff_test() {
  let harness = start_harness()
  subscribe(harness)
  claim(
    harness,
    "esc-1",
    scope_on("main", op_id(59)),
    durable.Action(tool: "bash", digest: "d-1", preview: "{}"),
    [wall(60)],
  )
  let _rendered = next_escalation(harness)
  send(
    harness,
    32,
    protocol.Approve(
      escalation_id: "esc-1",
      grants: [to_registry()],
      action: "d-1",
    ),
  )
  let envelope = next(harness)
  let assert protocol.ErrorEvent(code:, ..) = envelope.event
  assert code == protocol.code_stale_approval
  assert stored(harness, "esc-1").status == durable.Pending
}

/// The positive control, which is what separates a check from a
/// blockade: an answer about the record as it stands is committed, and
/// committed with exactly the grants the client echoed — not with
/// whatever the record wanted when the commit ran.
pub fn approve_echoing_the_record_commits_those_grants_test() {
  let harness = start_harness()
  subscribe(harness)
  claim(
    harness,
    "esc-1",
    scope_on("main", op_id(60)),
    durable.Action(tool: "bash", digest: "d-1", preview: "{}"),
    [wall(60), to_registry()],
  )
  let _rendered = next_escalation(harness)

  // Narrowed on purpose: the human said yes to the timeout and no to
  // the network.
  send(
    harness,
    33,
    protocol.Approve(escalation_id: "esc-1", grants: [wall(60)], action: "d-1"),
  )
  let envelope = next(harness)
  assert envelope.reply_to == Some(33)
  let assert protocol.EscalationEvent(record:) = envelope.event
    as "an accepted approval is acked with the escalation event"
  assert record.status == "approved"

  let record = stored(harness, "esc-1")
  assert record.status == durable.Approved
  let assert Ok(committed) = grants.decode_all(record.grants)
  assert committed == [wall(60)]
    as "the commit must spend the echoed diff, not the stored one"
}

/// A record raised through a door that names no call and no action — the
/// shape everything written before this change has. It must still reach
/// a client renderable, and must still be answerable: a client that
/// echoes the nothing it was given matches.
pub fn a_record_with_no_action_still_renders_and_still_approves_test() {
  let harness = start_harness()
  subscribe(harness)
  let assert Ok(Nil) =
    api.raise_escalation(
      harness.runtime,
      "esc-legacy",
      grants.encode_denial(
        reason: "tool requirements exceed the session policy",
        source: broker_escalation.PolicyDenial,
        wanted: [to_registry()],
      ),
    )
    as "the unscoped door must still file a record"
  let rendered = next_escalation(harness)
  assert rendered.op == ""
  assert rendered.strand == ""
  assert rendered.tool == ""
  assert rendered.action == ""
  assert rendered.preview == ""

  send(
    harness,
    34,
    protocol.Approve(
      escalation_id: "esc-legacy",
      grants: [to_registry()],
      action: "",
    ),
  )
  let envelope = next(harness)
  assert envelope.reply_to == Some(34)
  let assert protocol.EscalationEvent(record:) = envelope.event
    as "a record naming no action must still be approvable"
  assert record.status == "approved"
  assert stored(harness, "esc-legacy").status == durable.Approved
}

/// A decided record refuses a second answer, and the refusal is
/// `not_pending` rather than a stale echo: the question is closed, not
/// changed.
pub fn approve_of_a_decided_record_is_not_pending_test() {
  let harness = start_harness()
  subscribe(harness)
  claim(
    harness,
    "esc-1",
    scope_on("main", op_id(61)),
    durable.Action(tool: "bash", digest: "d-1", preview: "{}"),
    [wall(60)],
  )
  let _rendered = next_escalation(harness)
  send(
    harness,
    35,
    protocol.Approve(escalation_id: "esc-1", grants: [wall(60)], action: "d-1"),
  )
  let _ack = next(harness)
  send(
    harness,
    36,
    protocol.Approve(escalation_id: "esc-1", grants: [wall(60)], action: "d-1"),
  )
  expect_error(harness, 36, "not_pending")
}

// --- provider tap cancellation --------------------------------------------

fn cancellable_provider(cancelled: Subject(Nil)) -> effects.ProviderSurface {
  effects.ProviderSurface(timeout_ms: 1000, request: fn(_spec) {
    let events = process.new_subject()
    stream.immediate(events:, cancel: fn() {
      process.send(cancelled, Nil)
      process.send(events, stream.Failed(error: stream.ProviderCancelled))
    })
  })
}

fn cancellation_spec() -> effects.RequestSpec {
  effects.GenerationRequest(
    operation: op_id(919),
    step_id: "turn-1",
    attempt: 1,
    configuration: machine_strand.StrandConfiguration(
      model: machine_strand.ModelIdentity(provider: "acme", model_id: "loom-1"),
      thinking_level: machine_strand.ThinkingOff,
      active_tool_names: [],
    ),
    context: [],
    stream_options: json.Object([]),
  )
}

fn prepared_probe(started: Subject(Nil)) -> stream.PreparedStream {
  let begin = process.new_subject()
  let cancel = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let should_start =
        process.new_selector()
        |> process.select_map(begin, fn(_nil) { True })
        |> process.select_map(cancel, fn(_nil) { False })
        |> process.selector_receive_forever()
      case should_start {
        False -> Nil
        True -> {
          process.send(started, Nil)
          let _cancel = process.receive_forever(cancel)
          Nil
        }
      }
    })
  stream.PreparedStream(
    handle: stream.owned(events: process.new_subject(), owner:, cancel: fn() {
      process.send(cancel, Nil)
    }),
    begin: fn() { process.send(begin, Nil) },
  )
}

fn prepared_provider(started: Subject(Nil)) -> effects.ProviderSurface {
  effects.PreparedProviderSurface(
    timeout_ms: 1000,
    request: fn(_spec) { prepared_probe(started) |> stream.start_prepared },
    prepare: fn(_spec) { prepared_probe(started) },
  )
}

pub fn provider_tap_forwards_explicit_cancellation_once_test() {
  let cancelled = process.new_subject()
  let tapped =
    gateway.tap_provider(
      cancellable_provider(cancelled),
      to: process.new_name(prefix: "loom_cancel_tap_test"),
    )
  let handle = tapped.request(cancellation_spec())

  stream.cancel(handle)

  let assert Ok(Nil) = process.receive(cancelled, within: 1000)
  let assert Ok(stream.Failed(error: stream.ProviderCancelled)) =
    stream.next(handle, within: 1000)
  assert stream.next(handle, within: 10) == Error(Nil)
}

pub fn provider_tap_cancel_before_begin_starts_no_inner_work_test() {
  let started = process.new_subject()
  let tapped =
    gateway.tap_provider(
      prepared_provider(started),
      to: process.new_name(prefix: "loom_parked_tap_test"),
    )
  let stream.PreparedStream(handle:, begin:) =
    effects.prepare_provider(tapped, cancellation_spec())
  let drain_witness = stream.watch_drain(handle)

  stream.cancel(handle)
  assert stream.await_drain_forever(drain_witness) == stream.Drained
  begin()

  assert process.receive(started, within: 50) == Error(Nil)
}

pub fn provider_tap_cancels_when_its_consumer_dies_test() {
  let cancelled = process.new_subject()
  let ready = process.new_subject()
  let tapped =
    gateway.tap_provider(
      cancellable_provider(cancelled),
      to: process.new_name(prefix: "loom_cancel_tap_death_test"),
    )
  let consumer =
    process.spawn_unlinked(fn() {
      let handle = tapped.request(cancellation_spec())
      process.send(ready, Nil)
      let _ = stream.next(handle, within: 5000)
      Nil
    })
  let assert Ok(Nil) = process.receive(ready, within: 1000)

  process.kill(consumer)

  let assert Ok(Nil) = process.receive(cancelled, within: 1000)
}

pub fn provider_relay_bounds_unacknowledged_cancellation_test() {
  let cancelled = process.new_subject()
  let consumers = process.new_subject()
  let surface =
    effects.ProviderSurface(timeout_ms: 10_000, request: fn(_spec) {
      process.send(consumers, process.self())
      let events = process.new_subject()
      stream.immediate(events:, cancel: fn() { process.send(cancelled, Nil) })
    })
  let handle =
    provider_relay.wrap(surface, cancellation_spec(), fn(_event) { Nil })
  let drain_witness = stream.watch_drain(handle)
  let assert Ok(direct_consumer) = process.receive(consumers, within: 1000)
  let direct_monitor = process.monitor(direct_consumer)

  stream.cancel(handle)

  let assert Ok(stream.Failed(error: stream.CancellationUnconfirmed)) =
    stream.next(handle, within: 2500)
  let assert Ok(Nil) = process.receive(cancelled, within: 1000)
  let assert Ok(True) =
    process.new_selector()
    |> process.select_specific_monitor(direct_monitor, fn(_down) { True })
    |> process.selector_receive(1000)
  assert stream.await_drain_forever(drain_witness) == stream.Drained
}

pub fn provider_relay_custodian_is_distinct_from_inner_consumer_test() {
  let callers = process.new_subject()
  let surface =
    effects.ProviderSurface(timeout_ms: 10_000, request: fn(_spec) {
      process.send(callers, process.self())
      let events = process.new_subject()
      process.send(events, stream.Failed(error: stream.ProviderCancelled))
      stream.immediate(events:, cancel: fn() { Nil })
    })
  let handle =
    provider_relay.wrap(surface, cancellation_spec(), fn(_event) { Nil })
  let drain_witness = stream.watch_drain(handle)
  let assert stream.StreamHandle(owner: Some(owner), ..) = handle
    as "the relay must publish a custodian-backed handle"
  let assert Ok(inner_consumer) = process.receive(callers, within: 1000)

  assert inner_consumer != owner
    as "fallible stream consumption must not be the public drain witness"
  let assert Ok(stream.Failed(error: stream.ProviderCancelled)) =
    stream.next(handle, within: 1000)
  assert stream.await_drain_forever(drain_witness) == stream.Drained
}

pub fn provider_relay_cancel_during_inner_start_keeps_guard_test() {
  let entered = process.new_subject()
  let cancelled = process.new_subject()
  let surface =
    effects.ProviderSurface(timeout_ms: 10_000, request: fn(_spec) {
      let start_gate = process.new_subject()
      process.send(entered, start_gate)
      let _start = process.receive_forever(start_gate)
      let events = process.new_subject()
      stream.immediate(events:, cancel: fn() {
        process.send(cancelled, Nil)
        process.send(events, stream.Failed(error: stream.ProviderCancelled))
      })
    })
  let handle =
    provider_relay.wrap(surface, cancellation_spec(), fn(_event) { Nil })
  let drain_witness = stream.watch_drain(handle)
  let assert stream.StreamHandle(owner: Some(owner), ..) = handle
    as "the relay must publish its guard before inner startup"
  let assert Ok(start_gate) = process.receive(entered, within: 1000)

  stream.cancel(handle)

  assert process.is_alive(owner)
  assert process.receive(cancelled, within: 20) == Error(Nil)
  process.send(start_gate, Nil)
  assert process.receive(cancelled, within: 1000) == Ok(Nil)
  assert stream.next(handle, within: 1000)
    == Ok(stream.Failed(error: stream.ProviderCancelled))
  assert stream.await_drain_forever(drain_witness) == stream.Drained
}

pub fn provider_relay_worker_crash_fails_promptly_and_cancels_test() {
  let cancelled = process.new_subject()
  let surface =
    effects.ProviderSurface(timeout_ms: 10_000, request: fn(_spec) {
      let events = process.new_subject()
      process.send(
        events,
        stream.Delta(stream.TextDelta(index: 0, text: "before crash")),
      )
      stream.immediate(events:, cancel: fn() { process.send(cancelled, Nil) })
    })
  let handle =
    provider_relay.wrap(surface, cancellation_spec(), fn(_event) {
      panic as "observer crash"
    })
  let drain_witness = stream.watch_drain(handle)

  let assert Ok(stream.Failed(error: stream.TransportFailed(reason:))) =
    stream.next(handle, within: 1000)
  assert reason == "provider relay worker stopped before a terminal response"
  let assert Ok(Nil) = process.receive(cancelled, within: 1000)
  assert stream.await_drain_forever(drain_witness) == stream.Drained
}

pub fn provider_relay_worker_crash_waits_for_stubborn_owner_test() {
  let cancelled = process.new_subject()
  let owners = process.new_subject()
  let surface =
    effects.ProviderSurface(timeout_ms: 10_000, request: fn(_spec) {
      let events = process.new_subject()
      let ready = process.new_subject()
      let owner =
        process.spawn_unlinked(fn() {
          let release = process.new_subject()
          process.send(ready, release)
          let _release = process.receive_forever(release)
          Nil
        })
      let release = process.receive_forever(ready)
      process.send(owners, #(owner, release))
      process.send(
        events,
        stream.Delta(stream.TextDelta(index: 0, text: "before crash")),
      )
      stream.owned(events:, owner:, cancel: fn() {
        process.send(cancelled, Nil)
      })
    })
  let handle =
    provider_relay.wrap(surface, cancellation_spec(), fn(_event) {
      panic as "observer crash"
    })
  let drain_witness = stream.watch_drain(handle)
  let assert Ok(#(owner, release)) = process.receive(owners, within: 1000)

  let assert Ok(stream.Failed(error: stream.CancellationUnconfirmed)) =
    stream.next(handle, within: 2500)
  let assert Ok(Nil) = process.receive(cancelled, within: 1000)
  assert process.is_alive(owner)
  assert stream.await_drain(drain_witness, within: 20) == stream.TimedOut
  process.send(release, Nil)
  assert stream.await_drain_forever(drain_witness) == stream.Drained
}

pub fn provider_relay_guard_crash_keeps_custodian_until_inner_drain_test() {
  let cancelled = process.new_subject()
  let started = process.new_subject()
  let surface =
    effects.ProviderSurface(timeout_ms: 10_000, request: fn(_spec) {
      let guard = process.self()
      let events = process.new_subject()
      let ready = process.new_subject()
      let owner =
        process.spawn_unlinked(fn() {
          let release = process.new_subject()
          process.send(ready, release)
          let _release = process.receive_forever(release)
          Nil
        })
      let release = process.receive_forever(ready)
      process.send(started, #(guard, owner, release))
      stream.owned(events:, owner:, cancel: fn() {
        process.send(cancelled, Nil)
      })
    })
  let handle =
    provider_relay.wrap(surface, cancellation_spec(), fn(_event) { Nil })
  let drain_witness = stream.watch_drain(handle)
  let assert Ok(#(guard, inner_owner, release)) =
    process.receive(started, within: 1000)
  let assert stream.StreamHandle(owner: Some(witness), ..) = handle

  process.kill(guard)

  let assert Ok(Nil) = process.receive(cancelled, within: 1000)
  assert process.is_alive(inner_owner)
  assert process.is_alive(witness)
  assert stream.await_drain(drain_witness, within: 20) == stream.TimedOut
  process.send(release, Nil)
  assert stream.await_drain_forever(drain_witness) == stream.Drained
}
