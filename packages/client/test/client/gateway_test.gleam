//// The hub's protocol conduct: strict envelopes answered in-band,
//// unknown names tolerated with `unsupported`, subscription gating,
//// and the semantic error codes of the command table.

import client/gateway
import client/protocol
import core/clock
import core/json
import core/message
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import machine/strand as machine_strand
import provider/stream
import runtime/api
import runtime/effects
import session/session

// --- wiring ----------------------------------------------------------------

type Harness {
  Harness(hub: gateway.Gateway, connection: Int, inbox: Subject(String))
}

fn start_harness() -> Harness {
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
  let assert Ok(forwarder) = gateway.commit_forwarder(to: name)
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
        forwarder.data,
      ]),
    )
  let assert Ok(_started) =
    gateway.start(gateway.default_options("sess-01", runtime), name)
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
