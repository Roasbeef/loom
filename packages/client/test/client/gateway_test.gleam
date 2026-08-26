//// The hub's protocol conduct: strict envelopes answered in-band,
//// unknown names tolerated with `unsupported`, subscription gating,
//// and the semantic error codes of the command table.

import client/catalog
import client/gateway
import client/protocol
import client/serve
import core/clock
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
import session/session
import tools/tool

// --- wiring ----------------------------------------------------------------

type Harness {
  Harness(hub: gateway.Gateway, connection: Int, inbox: Subject(String))
}

fn start_harness() -> Harness {
  start_harness_with(catalog: None)
}

// Every harness but one carries the production tool registry, so
// `set_config active_tools` has the same registry to validate against
// that the effect wiring dispatches through.
fn start_harness_with(catalog catalogue: Option(catalog.Catalog)) -> Harness {
  start_harness_full(catalogue, Some(serve.registry(None, None)))
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
        stream.StreamHandle(events:)
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
  Harness(hub:, connection:, inbox:)
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
