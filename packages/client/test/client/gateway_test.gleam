//// The hub's protocol conduct: strict envelopes answered in-band,
//// unknown names tolerated with `unsupported`, subscription gating,
//// and the semantic error codes of the command table.

import broker/escalation as broker_escalation
import broker/internal/call
import broker/policy.{type Grant}
import client/catalog
import client/gateway
import client/grants
import client/protocol
import client/provider_relay
import client/schedule
import client/scheduleadmin
import core/clock
import core/entry as core_entry
import core/ids
import core/json
import core/message
import core/register
import core/tx
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import machine/operation
import machine/strand as machine_strand
import provider/model
import provider/stream
import runtime/api
import runtime/effects
import runtime/escalation as durable
import runtime/writer
import session/session
import storage/access
import storage/storage
import support/addresses
import support/tool_registry
import tools/tool
import weft/actor
import weft/poll

// --- wiring ----------------------------------------------------------------

@internal
pub type Harness {
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

// The host whose scheduling plane is open, over a scripted door.
fn start_harness_with_schedules(admin: scheduleadmin.Admin) -> Harness {
  start_harness_full(
    None,
    Some(tool_registry.built_in(None, None, None, None, None)),
    Some(admin),
  )
}

// Every harness but one carries the production tool registry, so
// `set_config active_tools` has the same registry to validate against
// that the effect wiring dispatches through.
fn start_harness_with(catalog catalogue: Option(catalog.Catalog)) -> Harness {
  start_harness_full(
    catalogue,
    Some(tool_registry.built_in(None, None, None, None, None)),
    None,
  )
}

// The host that configured no registry: active-set changes have
// nothing to check against and are refused.
fn start_harness_without_registry() -> Harness {
  start_harness_full(None, None, None)
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
        pricing: None,
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
        pricing: None,
      ),
    ],
    roles: [#(model.Main, ["acme", "fallback"])],
    mcp_servers: [],
  )
}

// The one assistant turn every scripted provider in this module answers
// with. Named here because two surfaces now send it: the settling default
// and the parked one the queue tests release by hand.
fn scripted_answer() -> message.AgentMessage {
  message.AssistantMessage(
    content: [message.AssistantText(text: "ok", text_signature: None)],
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
}

fn start_harness_full(
  catalogue: Option(catalog.Catalog),
  registry: Option(tool.Registry),
  schedules: Option(scheduleadmin.Admin),
) -> Harness {
  start_harness_reserved(catalogue, registry, schedules, None, SettlingProvider)
}

/// Builds the same scripted gateway against a daemon-reserved canonical ID.
@internal
pub fn reserved_fixture(id: ids.SessionId) -> Harness {
  start_harness_reserved(None, None, None, Some(id), SettlingProvider)
}

// The provider a harness runs its runs against. The default settles the
// first turn immediately, which is what every command test wants and what
// makes a prompt's entry readable in the same breath. A supplied surface
// is how a test gets a strand that is *actually* busy — nothing else in
// this fixture can hold an operation open.
type Provider {
  SettlingProvider
  ScriptedProvider(surface: effects.ProviderSurface)
}

fn start_harness_reserved(
  catalogue,
  registry,
  schedules,
  reserved,
  provider: Provider,
) -> Harness {
  let assert Ok(session) =
    session.open_memory(clock.stepping(from: 1_756_000_000_000, by: 3))
  case reserved {
    None -> Nil
    Some(id) -> {
      let assert Ok(_) = session.ensure_reserved_id(session, id)
        as "the gateway fixture uses the daemon's canonical identity"
      Nil
    }
  }
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
  let name = addresses.new()
  let forwarder_name = addresses.new()
  let assert Ok(_forwarder) =
    gateway.commit_forwarder(to: name, as_name: forwarder_name)
  let effects =
    effects.Effects(
      clock: clock.stepping(from: 1_756_000_000_000, by: 3),
      entropy:,
      timers: effects.real_timers(),
      provider: case provider {
        ScriptedProvider(surface:) -> surface
        SettlingProvider ->
          effects.ProviderSurface(timeout_ms: 1000, request: fn(_spec) {
            let events = process.new_subject()
            let assert Ok(settled) = stream.settle(scripted_answer())
            process.send(
              events,
              stream.Settled(message: settled, usage: effects.zero_usage()),
            )
            stream.immediate(events:, cancel: fn() { Nil })
          })
      },
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
        writer.Routed(forwarder_name),
      ]),
    )
  // Network fixtures make every old whole-history path an executable
  // failure. What "whole" means is the bound, not the call: since
  // `protocol-change/018` the network hub pulls above its own high-water
  // on every commit hint, so it scans — always from a lower bound it
  // computed, never from the beginning. The guards below therefore refuse
  // a scan with no lower bound and pass one that names a bound through to
  // the real backend. That is a check on the query's shape, not its size:
  // the prime at start names sequence one and reads the whole history
  // once, which is the same read the host fixture always made.
  // The separate snapshot_reader still borrows the real backend capability.
  let backend = runtime.session.store
  let runtime = case reserved {
    None -> runtime
    Some(_) ->
      api.Runtime(
        ..runtime,
        session: session.Session(
          ..runtime.session,
          store: storage.Storage(
            ..backend,
            scan_entries: fn(handle, query: storage.EntryScan) {
              case query.from_seq {
                Some(_) -> backend.scan_entries(handle, query)
                None -> panic as "network path must not scan whole entries"
              }
            },
            scan_branch: fn(handle, query: storage.BranchScan) {
              case query.cursor {
                Some(_) -> backend.scan_branch(handle, query)
                None -> panic as "network path must not scan whole branches"
              }
            },
            scan_usage: fn(handle, query: storage.UsageScan) {
              case query.from_seq {
                Some(_) -> backend.scan_usage(handle, query)
                None -> panic as "network path must not scan whole usage history"
              }
            },
            get_entries: fn(_, _) {
              panic as "network path must not decode whole entry records"
            },
          ),
        ),
      )
  }
  let options = gateway.default_options("sess-01", runtime)
  let options = case catalogue {
    Some(catalogue) -> gateway.with_catalog(options, catalogue)
    None -> options
  }
  let options = case registry {
    Some(registry) -> gateway.with_registry(options, registry)
    None -> options
  }
  let options = case schedules {
    Some(admin) -> gateway.with_schedules(options, admin)
    None -> options
  }
  let assert Ok(_started) = case reserved {
    None -> gateway.start_host_fixture(options, name)
    Some(_) -> gateway.start(options, name)
  }
  let hub = gateway.Gateway(name:)
  let inbox = process.new_subject()
  let assert Ok(connection) =
    gateway.attach(hub, fn(frame) { process.send(inbox, frame) })
    as "the live gateway must attach the test client"
  Harness(hub:, connection:, inbox:, runtime:)
}

fn send_raw(harness: Harness, frame: String) -> Nil {
  gateway.handle_text(harness.hub, harness.connection, frame)
}

fn send(harness: Harness, id: Int, command: protocol.Command) -> Nil {
  // Historical host fixtures answer the question currently displayed. Tests
  // for delayed answers supply an explicit sequence and bypass this shorthand.
  let command = case command {
    protocol.Approve(escalation_id, grants, action, 0) ->
      protocol.Approve(
        escalation_id,
        grants,
        action,
        current_question_seq(harness, escalation_id),
      )
    protocol.Deny(escalation_id, 0) ->
      protocol.Deny(escalation_id, current_question_seq(harness, escalation_id))
    other -> other
  }
  send_raw(
    harness,
    protocol.encode_command(protocol.CommandEnvelope(id:, command:)),
  )
}

fn current_question_seq(harness: Harness, id: String) -> Int {
  case api.escalation_cell(harness.runtime, id) {
    Ok(cell) -> cell.seq
    _ -> 0
  }
}

// One authenticated attachment on a *host fixture* hub: it subscribes with
// a cast and reads the snapshot back off the shared sink, because a host
// hub answers every command through the sink.
fn authenticated(
  harness: Harness,
  role: access.Authority,
  socket: process.Pid,
) {
  let #(handle, auth, closed) =
    attach_socket(
      harness.hub,
      harness.runtime,
      harness.inbox,
      access.Principal("alice", "Alice", access.MemberPrincipal),
      role,
      socket,
    )
  gateway.connection_text(handle, subscribe_frame(harness.runtime, 700))
  let _snapshot = next_reply(harness, 700, 8)
  #(handle, auth, closed)
}

// The same attachment on a *network* hub, which answers a command through
// the request's own reply capability and reserves the sink for frames it
// pushed. Two freedoms the push tests need: a peer whose frames are not
// mixed with another's, and a second hub whose priming is the thing under
// test.
fn network_socket(
  hub: gateway.Gateway,
  runtime: api.Runtime,
  inbox: Subject(String),
  principal: access.Principal,
  role: access.Authority,
) {
  let #(handle, auth, closed) =
    attach_socket(hub, runtime, inbox, principal, role, process.self())
  let assert Ok(_snapshot) =
    gateway.connection_request(handle, subscribe_frame(runtime, 700))
    as "the network attachment subscribes"
  #(handle, auth, closed)
}

fn subscribe_frame(runtime: api.Runtime, id: Int) -> String {
  protocol.encode_command(protocol.CommandEnvelope(
    id:,
    command: protocol.Subscribe(
      ids.session_id_to_string(api.session_id(runtime)),
      None,
    ),
  ))
}

fn attach_socket(
  hub: gateway.Gateway,
  runtime: api.Runtime,
  inbox: Subject(String),
  principal: access.Principal,
  role: access.Authority,
  socket: process.Pid,
) {
  let assert Ok(digest) = access.credential_digest(string.repeat("a", 64))
    as "the fixture digest is valid"
  let closed = process.new_subject()
  let assert Ok(auth) =
    actor.new(Ok(#(principal, role)))
    |> actor.on_message(fn(state, message) {
      case message {
        ReadAuth(reply) -> {
          process.send(reply, state)
          actor.continue(state)
        }
        ChangeAuth(value, reply) -> {
          process.send(reply, Nil)
          actor.continue(value)
        }
      }
    })
    |> actor.start
    as "the authorization fixture starts"
  let session_id = ids.session_id_to_string(api.session_id(runtime))
  let assert Ok(handle) =
    gateway.attach_authenticated(
      hub,
      gateway.Binding(
        session_id,
        "epoch",
        "incarnation",
        "connection-" <> principal.id,
        principal,
        role,
        digest,
      ),
      fn() {
        call.try_call(auth.data, waiting: 1000, sending: ReadAuth)
        |> result.unwrap(Error("authority fixture unavailable"))
      },
      fn(frame) { process.send(inbox, frame) },
      fn() { process.send(closed, Nil) },
      fn() { Nil },
      socket,
    )
    as "authenticated attachment succeeds"
  #(handle, auth.data, closed)
}

type AuthMessage {
  ReadAuth(Subject(Result(#(access.Principal, access.Authority), String)))
  ChangeAuth(
    Result(#(access.Principal, access.Authority), String),
    Subject(Nil),
  )
}

pub fn authenticated_observer_cannot_mutate_test() {
  let harness = start_harness()
  let #(handle, _, _) =
    authenticated(harness, access.Participant(access.Observer), process.self())
  gateway.connection_text(
    handle,
    protocol.encode_command(protocol.CommandEnvelope(
      701,
      protocol.SetConfig(
        None,
        json.Object([#("queue_mode", json.String("one_at_a_time"))]),
      ),
    )),
  )
  let assert protocol.ErrorEvent(code: "forbidden", ..) =
    next_reply(harness, 701, 8).event
    as "observers cannot change shared settings"
  assert api.fact_cell(harness.runtime, "client/run_settings") == Ok(None)
}

pub fn authenticated_prompt_captures_human_origin_test() {
  let harness = start_harness()
  let #(handle, _, _) =
    authenticated(harness, access.Participant(access.Operator), process.self())
  gateway.connection_text(
    handle,
    protocol.encode_command(protocol.CommandEnvelope(
      702,
      protocol.Prompt("main", "hello"),
    )),
  )
  let assert protocol.EntryEvent(protocol.EntryRecord(
    entry: core_entry.MessageEntry(
      message: message.UserMessage(origin: author, ..),
      ..,
    ),
    ..,
  )) = next_reply(harness, 702, 16).event
    as "the prompt is admitted as a user entry"
  assert author == Some(message.Origin("alice", "Alice"))
}

pub fn revoked_connection_closes_before_command_admission_test() {
  let harness = start_harness()
  let #(handle, auth, closed) =
    authenticated(harness, access.Participant(access.Operator), process.self())
  process.call(auth, waiting: 1000, sending: ChangeAuth(Error("revoked"), _))
  gateway.connection_text(
    handle,
    protocol.encode_command(protocol.CommandEnvelope(
      703,
      protocol.SetConfig(
        None,
        json.Object([#("queue_mode", json.String("one_at_a_time"))]),
      ),
    )),
  )
  let assert Ok(Nil) = process.receive(closed, within: 1000)
    as "revocation closes the socket"
  assert api.fact_cell(harness.runtime, "client/run_settings") == Ok(None)
}

pub fn shared_configuration_commits_complete_defaults_and_origin_test() {
  let harness = start_harness()
  let #(handle, _, _) =
    authenticated(harness, access.Participant(access.Operator), process.self())
  gateway.connection_text(
    handle,
    protocol.encode_command(protocol.CommandEnvelope(
      704,
      protocol.SetConfig(
        Some("main"),
        json.Object([
          #("queue_mode", json.String("one_at_a_time")),
          #("tool_execution", json.String("sequential")),
          #("thinking_level", json.String("high")),
        ]),
      ),
    )),
  )
  let assert protocol.SnapshotEvent(protocol.ConfigSnapshot(_)) =
    next_reply(harness, 704, 8).event
    as "the committed shared value is returned"
  let assert Ok(defaults) = api.run_defaults_cell(harness.runtime)
    as "fresh reads see durable defaults"
  assert defaults.settings.steering_mode == operation.OneAtATime
  assert defaults.settings.tool_execution == operation.Sequential
  assert defaults.origin == Some(message.Origin("alice", "Alice"))
  let assert Ok(Some(cell)) =
    api.fact_cell(harness.runtime, "client/config_origin/main")
    as "the same transaction persisted strand attribution"
  assert cell.value
    == json.Object([
      #(
        "origin",
        json.Object([
          #("principal", json.String("alice")),
          #("name", json.String("Alice")),
        ]),
      ),
    ])
}

pub fn malformed_shared_defaults_refuse_new_admission_test() {
  let harness = start_harness()
  let assert Ok(_) =
    writer.commit(
      harness.runtime.tree.writer,
      tx.Tx(
        [
          tx.SetRegister(
            register.FactCustom,
            "client/run_settings",
            register.value(json.Null),
          ),
        ],
        [],
      ),
    )
    as "the corrupt fixture cell is written"
  let assert Error(api.ReadFailed(_)) = api.run_defaults_cell(harness.runtime)
    as "present corruption is not host defaults"
  let assert Error(api.ReadFailed(_)) =
    api.prompt(harness.runtime, [
      message.UserMessage(
        content: [message.UserText("must not run", None)],
        timestamp: 1,
        origin: None,
      ),
    ])
    as "new execution must refuse malformed defaults"
}

pub fn original_socket_kill_removes_presence_without_detach_test() {
  let harness = start_harness()
  let assert Ok(socket) =
    actor.new(Nil)
    |> actor.on_message(fn(state, _: Nil) { actor.continue(state) })
    |> actor.start
    as "the socket lifetime fixture starts"
  process.unlink(socket.pid)
  let #(_, _, _) =
    authenticated(harness, access.Participant(access.Operator), socket.pid)
  assert gateway.attached(harness.hub) == 2
  process.kill(socket.pid)
  let monitor = process.monitor(socket.pid)
  let assert Ok(Nil) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(within: 1000)
    as "the original socket is dead"

  // A mailbox barrier observes the monitor-driven removal, without on_close.
  let assert poll.Answered(Nil) =
    poll.until(within: 1000, every: 1, attempt: fn() {
      case gateway.attached(harness.hub) == 1 {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
    as "the dead socket no longer contributes presence"
}

pub fn changed_role_closes_original_attachment_test() {
  let harness = start_harness()
  let #(handle, auth, closed) =
    authenticated(harness, access.Participant(access.Operator), process.self())
  let principal = access.Principal("alice", "Alice", access.MemberPrincipal)
  process.call(auth, waiting: 1000, sending: ChangeAuth(
    Ok(#(principal, access.Participant(access.Observer))),
    _,
  ))
  gateway.connection_text(
    handle,
    protocol.encode_command(protocol.CommandEnvelope(705, protocol.ListModels)),
  )
  let assert Ok(Nil) = process.receive(closed, within: 1000)
    as "a role change requires a new attachment, even for a read command"
}

pub fn shared_configuration_read_failure_leaves_no_partial_defaults_test() {
  let harness = start_harness()
  subscribe(harness)
  send(
    harness,
    706,
    protocol.SetConfig(
      Some("missing-strand"),
      json.Object([
        #("queue_mode", json.String("one_at_a_time")),
        #("thinking_level", json.String("high")),
      ]),
    ),
  )
  let assert protocol.ErrorEvent(code: "bad_request", ..) =
    next_reply(harness, 706, 8).event
    as "a missing strand refuses the complete command"
  assert api.fact_cell(harness.runtime, "client/run_settings") == Ok(None)
  assert api.fact_cell(harness.runtime, "client/config_origin/missing-strand")
    == Ok(None)
}

pub fn new_admission_reads_defaults_without_changing_existing_run_test() {
  let harness = start_harness()
  let settings =
    operation.RunSettings(
      ..harness.runtime.settings,
      steering_mode: operation.OneAtATime,
      follow_up_mode: operation.OneAtATime,
      tool_execution: operation.Sequential,
    )
  let assert Ok(_) =
    writer.commit(
      harness.runtime.tree.writer,
      tx.Tx(
        [
          tx.SetRegister(
            register.FactCustom,
            "client/run_settings",
            register.value(api.encode_run_defaults(
              settings,
              Some(message.Origin("alice", "Alice")),
            )),
          ),
        ],
        [],
      ),
    )
    as "the first complete defaults are durable"
  let assert Ok(id) =
    api.accept_quietly(harness.runtime, [
      message.UserMessage([message.UserText("quiet run", None)], 1, None),
    ])
    as "the run is durably accepted"
  let assert Ok(Some(session.Cell(
    value: operation.RunState(settings: admitted, ..),
    ..,
  ))) = session.op_state(harness.runtime.session, id)
    as "the admitted settings are readable"
  assert admitted == settings
  let assert Ok(_) =
    writer.commit(
      harness.runtime.tree.writer,
      tx.Tx(
        [
          tx.SetRegister(
            register.FactCustom,
            "client/run_settings",
            register.value(api.encode_run_defaults(
              harness.runtime.settings,
              None,
            )),
          ),
        ],
        [],
      ),
    )
    as "later defaults are separate from the running operation"
  let assert Ok(Some(session.Cell(
    value: operation.RunState(settings: retained, ..),
    ..,
  ))) = session.op_state(harness.runtime.session, id)
    as "the live operation retains its snapshot"
  assert retained == settings
}

fn next(harness: Harness) -> protocol.EventEnvelope {
  next_on(harness.inbox)
}

fn next_on(inbox: Subject(String)) -> protocol.EventEnvelope {
  let assert Ok(frame) = process.receive(inbox, within: 5000)
    as "an event frame must arrive"
  let assert Ok(envelope) = protocol.decode_event(frame)
    as "every emitted frame must decode"
  envelope
}

fn next_reply(
  harness: Harness,
  id: Int,
  remaining: Int,
) -> protocol.EventEnvelope {
  let envelope = next(harness)
  case envelope.reply_to == Some(id), remaining > 0 {
    True, _ -> envelope
    False, True -> next_reply(harness, id, remaining - 1)
    False, False -> panic as "the expected command reply must arrive"
  }
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

  let assert Ok(second) = gateway.attach(harness.hub, fn(_frame) { Nil })
    as "the live gateway must attach the second client"
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
  let name = addresses.new()
  assert gateway.attached(gateway.Gateway(name:)) == 0
}

pub fn attach_without_a_hub_refuses_the_connection_test() {
  let name = addresses.new()
  let delivered = process.new_subject()
  assert gateway.attach(gateway.Gateway(name:), fn(frame) {
      process.send(delivered, frame)
    })
    == Error(Nil)
  assert process.receive(delivered, within: 0) == Error(Nil)
}

/// A hub that is alive but does not answer in time counts as nobody
/// attached. `process.call` exits its *caller* on timeout rather than
/// returning an error, and the caller here is a parked tool call's own
/// effect process asking once a second for the length of the park — so a
/// hub busy behind a long pull would kill the very call it is being
/// asked about, and the driver would report a death with no stated
/// reason where the seam's doc promises an in-band policy refusal.
pub fn attached_is_zero_when_the_hub_does_not_answer_test() {
  let name = addresses.new()
  let assert Ok(_silent) =
    actor.new(Nil)
    |> actor.on_message(fn(state, _message) { actor.continue(state) })
    |> actor.addressed(name)
    |> actor.start
    as "the silent hub must start"
  assert gateway.attached(gateway.Gateway(name:)) == 0
}

/// And a hub that dies while being asked answers zero too, rather than
/// taking the asker down with it.
pub fn attached_is_zero_when_the_hub_dies_mid_question_test() {
  let name = addresses.new()
  let assert Ok(started) =
    actor.new(Nil)
    |> actor.on_message(fn(_state, _message) { actor.stop() })
    |> actor.addressed(name)
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
  send_raw(harness, "{\"v\":2,\"id\":4,\"cmd\":\"levitate\",\"body\":{}}")
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

pub fn prompt_content_admits_one_ordered_user_message_test() {
  let harness = start_harness()
  subscribe(harness)
  let content = [
    message.UserText("inspect this", None),
    message.UserImage("iVBORw0KGgo=", "image/png"),
  ]
  send(harness, 60, protocol.PromptContent(strand: "main", content:))
  let envelope = next_reply(harness, 60, 8)
  assert envelope.reply_to == Some(60)
  let assert protocol.EntryEvent(record: protocol.EntryRecord(entry:, ..)) =
    envelope.event
  let assert core_entry.MessageEntry(
    id: user_entry_id,
    message: message.UserMessage(content: admitted, ..),
    ..,
  ) = entry
  assert admitted == content
  let assert Ok(entries) =
    storage.scan_branch(
      harness.runtime.session.store,
      storage.branch_scan(from: user_entry_id),
    )
  let admitted_user_turns =
    list.filter_map(entries, fn(entry) {
      case entry {
        core_entry.MessageEntry(message: message.UserMessage(content:, ..), ..) ->
          Ok(content)
        core_entry.MessageEntry(..)
        | core_entry.CompactionEntry(..)
        | core_entry.BranchSummaryEntry(..)
        | core_entry.CustomEntry(..) -> Error(Nil)
      }
    })
  assert admitted_user_turns == [content]
}

pub fn unknown_escalation_refused_test() {
  let harness = start_harness()
  subscribe(harness)
  send(harness, 7, protocol.Deny(escalation_id: "esc-none", expected_seq: 0))
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
    protocol.Approve(
      escalation_id: "esc-1",
      grants: [wall(60)],
      action: "d-60",
      expected_seq: 0,
    ),
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
      expected_seq: 0,
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
    protocol.Approve(
      escalation_id: "esc-1",
      grants: [wall(60)],
      action: "d-1",
      expected_seq: 0,
    ),
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
      expected_seq: 0,
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
    protocol.Approve(
      escalation_id: "esc-1",
      grants: [wall(60)],
      action: "d-1",
      expected_seq: 0,
    ),
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
      expected_seq: 0,
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
    protocol.Approve(
      escalation_id: "esc-1",
      grants: [wall(60)],
      action: "d-1",
      expected_seq: 0,
    ),
  )
  let _ack = next(harness)
  send(
    harness,
    36,
    protocol.Approve(
      escalation_id: "esc-1",
      grants: [wall(60)],
      action: "d-1",
      expected_seq: 0,
    ),
  )
  expect_error(harness, 36, "not_pending")
}

// --- provider tap cancellation --------------------------------------------

pub fn delayed_approve_cannot_answer_reopened_same_action_test() {
  let #(harness, displayed) = reopened_same_question()
  send(
    harness,
    801,
    protocol.Approve("same-question", [wall(60)], "same-action", displayed.seq),
  )
  let assert protocol.ErrorEvent(code: "stale_approval", ..) =
    next_reply(harness, 801, 8).event
    as "an old approval cannot answer the reopened question"
  assert stored(harness, "same-question").status == durable.Pending
  assert stored(harness, "same-question").origin == None
}

pub fn delayed_deny_cannot_answer_reopened_same_action_test() {
  let #(harness, displayed) = reopened_same_question()
  send(harness, 802, protocol.Deny("same-question", displayed.seq))
  let assert protocol.ErrorEvent(code: "stale_approval", ..) =
    next_reply(harness, 802, 8).event
    as "an old denial cannot answer the reopened question"
  assert stored(harness, "same-question").status == durable.Pending
  assert stored(harness, "same-question").origin == None
}

fn reopened_same_question() {
  let harness = start_harness()
  subscribe(harness)
  let action = durable.Action("bash", "same-action", "{}")
  claim(harness, "same-question", scope_on("main", op_id(81)), action, [
    wall(60),
  ])
  let displayed = next_escalation(harness)
  let assert Ok(_) = api.deny_escalation(harness.runtime, "same-question")
    as "the first question can be closed"
  claim(harness, "same-question", scope_on("main", op_id(82)), action, [
    wall(60),
  ])
  let assert Ok(current) = api.escalation_cell(harness.runtime, "same-question")
    as "the reopened question exists"
  assert current.seq > displayed.seq
  assert current.record.action == Some("same-action")
  #(harness, displayed)
}

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

pub fn preview_observation_drops_backlog_but_preserves_consumer_and_cancel_test() {
  let supplied = process.new_subject()
  let seen = process.new_subject()
  let observer_ready = process.new_subject()
  let cancelled = process.new_subject()
  let surface =
    effects.ProviderSurface(timeout_ms: 5000, request: fn(_) {
      let events = process.new_subject()
      process.send(supplied, events)
      stream.immediate(events:, cancel: fn() {
        process.send(cancelled, Nil)
        process.send(events, stream.Failed(stream.ProviderCancelled))
      })
    })
  let handle =
    provider_relay.prepare_preview(surface, cancellation_spec(), fn() {
      let release = process.new_subject()
      process.send(observer_ready, release)
      blocked_preview(seen, release)
    })
    |> stream.start_prepared
  let witness = stream.watch_drain(handle)
  let assert Ok(release) = process.receive(observer_ready, within: 1000)
    as "the observer owns its release capability"
  let assert Ok(events) = process.receive(supplied, within: 1000)
    as "the inner stream is ready"
  process.send(events, stream.Delta(stream.TextDelta(0, "first")))
  let assert Ok(stream.Delta(_)) = process.receive(seen, within: 1000)
    as "one preview callback is outstanding"

  // Every authoritative delta passes the busy optional observer in order.
  int.range(1, 51, Nil, fn(_, index) {
    process.send(events, stream.Delta(stream.TextDelta(index, "next")))
  })
  int.range(0, 51, Nil, fn(_, index) {
    let assert Ok(stream.Delta(stream.TextDelta(actual, _))) =
      stream.next(handle, within: 1000)
      as "the runtime receives every delta without waiting for preview"
    assert actual == index
    Nil
  })
  stream.cancel(handle)
  assert process.receive(cancelled, within: 1000) == Ok(Nil)
  assert process.receive(seen, within: 50) == Error(Nil)

  // One release exposes the terminal immediately, not fifty queued callbacks.
  process.send(release, Nil)
  assert process.receive(seen, within: 1000)
    == Ok(stream.Failed(stream.ProviderCancelled))
  assert stream.next(handle, within: 1000)
    == Ok(stream.Failed(stream.ProviderCancelled))
  assert stream.await_drain_forever(witness) == stream.Drained
}

fn blocked_preview(seen, release) -> provider_relay.ObservationCallback {
  provider_relay.ObservationCallback(fn(event) {
    process.send(seen, event)
    case event {
      stream.Delta(_) -> {
        let assert Ok(Nil) = process.receive(release, within: 1000)
          as "the test releases its bounded outstanding observer"
        blocked_preview(seen, release)
      }
      stream.Settled(..) | stream.Failed(..) -> blocked_preview(seen, release)
    }
  })
}

pub fn preview_sources_bound_blocked_gateway_and_disable_after_timeout_test() {
  let harness = start_harness()
  let #(connection, _, _) = authenticated(harness, access.Owner, process.self())
  let pid = gateway.connection_pid(connection)
  let baseline = process_monitor_count(pid)
  let supplied = process.new_subject()
  let surface =
    effects.ProviderSurface(timeout_ms: 5000, request: fn(_) {
      let events = process.new_subject()
      process.send(supplied, events)
      stream.immediate(events:, cancel: fn() {
        process.send(events, stream.Failed(stream.ProviderCancelled))
      })
    })
  let tapped = gateway.tap_preview_provider(surface, to: harness.hub.name)
  let handles =
    list.map(list.repeat(Nil, 17), fn(_) {
      let handle =
        effects.prepare_provider(tapped, cancellation_spec())
        |> stream.start_prepared
      let assert Ok(events) = process.receive(supplied, within: 1000)
        as "the inner source is ready"
      #(handle, events, stream.watch_drain(handle))
    })
  let assert poll.Answered(Nil) =
    poll.until(within: 1000, every: 5, attempt: fn() {
      case process_monitor_count(pid) == baseline + 16 {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
    as "only sixteen original observers receive leases"
  let assert True = suspend_test_process(pid) as "block the original gateway"

  // Each admitted source contributes at most one bounded payload. The refused
  // seventeenth source contributes none; after timeout, no source retries.
  list.each(handles, fn(pair) {
    process.send(
      pair.1,
      stream.Delta(stream.TextDelta(0, string.repeat("x", 40_000))),
    )
  })
  process.sleep(300)
  let initial_queue = process_queue_length(pid)
  list.each(handles, fn(pair) {
    int.range(0, 50, Nil, fn(_, index) {
      process.send(pair.1, stream.Delta(stream.TextDelta(index, "later")))
    })
  })
  process.sleep(100)
  let later_queue = process_queue_length(pid)
  let assert True = resume_test_process(pid) as "resume the original gateway"
  assert initial_queue >= 16
  assert initial_queue <= 17
  assert later_queue <= 17

  // Timed-out sources retain their permits until original terminal release,
  // rather than allowing new sources to overlap their queued payloads.
  assert process_monitor_count(pid) == baseline + 16
  list.each(handles, fn(pair) { stream.cancel(pair.0) })
  let assert poll.Answered(Nil) =
    poll.until(within: 2000, every: 5, attempt: fn() {
      case process_monitor_count(pid) == baseline {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
    as "ordered terminal release reclaims every source"
  list.each(handles, fn(pair) {
    assert stream.await_drain_forever(pair.2) == stream.Drained
  })
  let _ = api.close(harness.runtime)
  Nil
}

fn process_monitor_count(pid) {
  let assert Ok(monitors) =
    decode.run(
      test_process_info(pid, atom.create("monitors")),
      decode.at([1], decode.list(decode.dynamic)),
    )
    as "the gateway reports its monitor inventory"
  list.length(monitors)
}

pub fn expired_preview_admission_cannot_allocate_after_caller_timeout_test() {
  let harness = start_harness()
  let #(connection, _, _) = authenticated(harness, access.Owner, process.self())
  let pid = gateway.connection_pid(connection)
  let baseline = process_monitor_count(pid)
  let supplied = process.new_subject()
  let surface =
    effects.ProviderSurface(timeout_ms: 5000, request: fn(_) {
      let events = process.new_subject()
      process.send(supplied, events)
      stream.immediate(events:, cancel: fn() {
        process.send(events, stream.Failed(stream.ProviderCancelled))
      })
    })
  let tapped = gateway.tap_preview_provider(surface, to: harness.hub.name)
  let assert True = suspend_test_process(pid) as "delay the lease request"
  let handle =
    effects.prepare_provider(tapped, cancellation_spec())
    |> stream.start_prepared
  let witness = stream.watch_drain(handle)
  let assert Ok(events) = process.receive(supplied, within: 1000)
    as "the real stream does not depend on optional preview admission"
  process.sleep(250)
  let assert True = resume_test_process(pid)
    as "process the already expired request"

  // A synchronous mailbox barrier follows the expired request. No replacement
  // lease may be granted, even though the observer remains alive.
  assert gateway.attached(harness.hub) == 2
  assert process_monitor_count(pid) == baseline
  process.send(events, stream.Delta(stream.TextDelta(0, "still authoritative")))
  assert stream.next(handle, within: 1000)
    == Ok(stream.Delta(stream.TextDelta(0, "still authoritative")))
  assert process_monitor_count(pid) == baseline
  stream.cancel(handle)
  assert stream.next(handle, within: 1000)
    == Ok(stream.Failed(stream.ProviderCancelled))
  assert stream.await_drain_forever(witness) == stream.Drained
  let _ = api.close(harness.runtime)
  Nil
}

fn process_queue_length(pid) {
  let assert Ok(count) =
    decode.run(
      test_process_info(pid, atom.create("message_queue_len")),
      decode.at([1], decode.int),
    )
    as "the original gateway reports its queue length"
  count
}

@external(erlang, "erlang", "process_info")
fn test_process_info(pid: process.Pid, item: atom.Atom) -> Dynamic

@external(erlang, "erlang", "suspend_process")
fn suspend_test_process(pid: process.Pid) -> Bool

@external(erlang, "erlang", "resume_process")
fn resume_test_process(pid: process.Pid) -> Bool

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
    gateway.tap_provider(cancellable_provider(cancelled), to: addresses.new())
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
    gateway.tap_provider(prepared_provider(started), to: addresses.new())
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
    gateway.tap_provider(cancellable_provider(cancelled), to: addresses.new())
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
  let prepared =
    provider_relay.prepare(surface, cancellation_spec(), fn(_event) { Nil })
  let handle = prepared.handle

  // The immediate terminal may retire the custodian before a begun request
  // returns. Publish both original monitors while the relay is still parked.
  let drain_witness = stream.watch_drain(handle)
  let assert stream.StreamHandle(owner: Some(owner), ..) = handle
    as "the relay must publish a custodian-backed handle"
  let owner_monitor = process.monitor(owner)
  assert process.receive(callers, within: 20) == Error(Nil)
    as "preparation must not release inner work before custody is published"
  prepared.begin()
  let assert Ok(inner_consumer) = process.receive(callers, within: 1000)

  assert inner_consumer != owner
    as "fallible stream consumption must not be the public drain witness"
  let assert Ok(stream.Failed(error: stream.ProviderCancelled)) =
    stream.next(handle, within: 1000)

  // Deliberately await proof after retirement, not while racing the terminal.
  // Only a monitor installed before begin can retain the original exit reason.
  let assert Ok(process.ProcessDown(reason: process.Normal, ..)) =
    process.new_selector()
    |> process.select_specific_monitor(owner_monitor, fn(down) { down })
    |> process.selector_receive(1000)
    as "the original custodian must retire normally before drain is inspected"
  assert stream.await_drain(drain_witness, within: 1000) == stream.Drained
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

pub fn provider_relay_startup_cancel_has_one_delta_proof_deadline_test() {
  let entered = process.new_subject()
  let flooders = process.new_subject()
  let surface =
    effects.ProviderSurface(timeout_ms: 10_000, request: fn(_spec) {
      let start_gate = process.new_subject()
      process.send(entered, start_gate)
      let _start = process.receive_forever(start_gate)
      let events = process.new_subject()
      stream.immediate(events:, cancel: fn() {
        let flooder =
          process.spawn_unlinked(fn() { flood_relay_deltas(events, 700) })
        process.send(flooders, flooder)
      })
    })
  let handle =
    provider_relay.wrap(surface, cancellation_spec(), fn(_event) { Nil })
  let assert Ok(start_gate) = process.receive(entered, within: 1000)

  stream.cancel(handle)
  process.send(start_gate, Nil)

  // The flood runs longer than the 1.5-second cancellation grace. The relay
  // must discard each delta without treating activity as renewed proof time.
  let assert Ok(stream.Failed(error: stream.CancellationUnconfirmed)) =
    stream.next(handle, within: 2500)
    as "startup cancellation must keep one fixed proof deadline"
  let assert Ok(flooder) = process.receive(flooders, within: 1000)
  process.kill(flooder)
}

fn flood_relay_deltas(
  events: Subject(stream.StreamEvent),
  remaining: Int,
) -> Nil {
  case remaining <= 0 {
    True -> Nil
    False -> {
      process.send(
        events,
        stream.Delta(stream.TextDelta(index: 0, text: "late")),
      )
      process.sleep(5)
      flood_relay_deltas(events, remaining - 1)
    }
  }
}

/// The guard hands the observer one event at a time and queues whatever
/// arrives behind it, so a stream that outruns the callback is still observed
/// in arrival order and nothing is dropped on the way past. The burst is
/// already in the guard's mailbox before its first acknowledgement, which is
/// the interleaving that a queue kept in the machine's data exists for.
pub fn provider_relay_observes_a_burst_in_order_test() {
  let seen = process.new_subject()
  let surface =
    effects.ProviderSurface(timeout_ms: 10_000, request: fn(_spec) {
      let events = process.new_subject()
      list.each([1, 2, 3, 4, 5], fn(index) {
        process.send(events, stream.Delta(stream.TextDelta(index:, text: "d")))
      })
      process.send(events, stream.Failed(error: stream.ProviderCancelled))
      stream.immediate(events:, cancel: fn() { Nil })
    })
  let handle =
    provider_relay.wrap(surface, cancellation_spec(), fn(event) {
      process.sleep(5)
      process.send(seen, event)
    })

  assert burst_indices(fn() { process.receive(seen, within: 1000) }, 5)
    == [1, 2, 3, 4, 5]
    as "the observer must see every delta of the burst, in arrival order"
  let assert Ok(stream.Failed(error: stream.ProviderCancelled)) =
    process.receive(seen, within: 1000)
    as "the terminal must reach the observer behind the deltas it followed"

  assert burst_indices(fn() { stream.next(handle, within: 1000) }, 5)
    == [1, 2, 3, 4, 5]
    as "the consumer must be forwarded the same deltas, in the same order"
  let assert Ok(stream.Failed(error: stream.ProviderCancelled)) =
    stream.next(handle, within: 1000)
    as "the terminal is forwarded once the observer has seen it"
}

fn burst_indices(
  next: fn() -> Result(stream.StreamEvent, Nil),
  remaining: Int,
) -> List(Int) {
  case remaining <= 0 {
    True -> []
    False -> {
      let assert Ok(stream.Delta(stream.TextDelta(index:, ..))) = next()
        as "every delta of the burst must arrive"
      [index, ..burst_indices(next, remaining - 1)]
    }
  }
}

/// Consumer death closes the observation boundary: the relay cancels inward
/// and stops, and the terminal that cancellation produces is never handed to
/// the observer. The sink is read only once the custodian has drained, so the
/// answer cannot be "not yet" — the guard and its observer are both gone by
/// then, and anything either of them would have said has been said.
pub fn provider_relay_consumer_death_observes_nothing_test() {
  let cancelled = process.new_subject()
  let seen = process.new_subject()
  let handles = process.new_subject()
  let surface =
    effects.ProviderSurface(timeout_ms: 10_000, request: fn(_spec) {
      let events = process.new_subject()
      stream.immediate(events:, cancel: fn() {
        process.send(cancelled, Nil)
        process.send(events, stream.Failed(error: stream.ProviderCancelled))
      })
    })
  let consumer =
    process.spawn_unlinked(fn() {
      let handle =
        provider_relay.wrap(surface, cancellation_spec(), fn(event) {
          process.send(seen, event)
        })
      process.send(handles, handle)
      let _ = stream.next(handle, within: 5000)
      Nil
    })
  let assert Ok(handle) = process.receive(handles, within: 1000)
    as "the relay must be running before its consumer is killed"
  let assert Some(owner) = handle.owner
    as "the relay exposes its original custodian"
  assert !monitored_by_test(owner)
    as "no earlier test-owned monitor can satisfy the drain-witness barrier"
  let drain_witness = stream.watch_drain(handle)

  // Monitoring the custodian and killing its consumer target different PIDs.
  // Observe this test's monitor at the custodian before releasing that kill;
  // creating the local reference alone is not the fixture's acknowledgement.
  assert monitored_by_test(owner)
    as "the custodian has installed this test's original drain monitor"
  process.kill(consumer)

  let assert Ok(Nil) = process.receive(cancelled, within: 1000)
    as "consumer death must cancel the inner stream"
  assert stream.await_drain(drain_witness, within: 1000) == stream.Drained
    as "the custodian retires once the guard and observer are gone"
  assert process.receive(seen, within: 0) == Error(Nil)
    as "a terminal produced by consumer death must never reach the observer"
}

// Compare trusted OTP PID identities without an unchecked cast or new FFI.
fn monitored_by_test(owner: process.Pid) -> Bool {
  let assert Ok(watchers) =
    decode.run(
      test_process_info(owner, atom.create("monitored_by")),
      decode.at([1], decode.list(decode.dynamic)),
    )
    as "the original live custodian reports its incoming monitors"
  let current = string.inspect(process.self())
  list.any(watchers, fn(watcher) { string.inspect(watcher) == current })
}

pub fn provider_relay_worker_crash_fails_promptly_and_cancels_test() {
  let cancelled = process.new_subject()
  let streams = process.new_subject()
  let surface =
    effects.ProviderSurface(timeout_ms: 10_000, request: fn(_spec) {
      let events = process.new_subject()
      process.send(streams, events)
      stream.immediate(events:, cancel: fn() { process.send(cancelled, Nil) })
    })
  let handle =
    provider_relay.wrap(surface, cancellation_spec(), fn(_event) {
      panic as "observer crash"
    })
  let assert Some(owner) = handle.owner
    as "the relay exposes its original custodian"
  assert !monitored_by_test(owner)
    as "no earlier test-owned monitor can satisfy the drain-witness barrier"
  let drain_witness = stream.watch_drain(handle)

  // The observer's crash retires the custodian from a different process than
  // the one installing this test's monitor, and two senders' signals carry no
  // order between them. The delta that provokes the crash is therefore sent
  // only once the custodian reports the monitor installed; a crash that beat
  // the monitor would settle the witness as ProofLost for a Normal exit.
  assert monitored_by_test(owner)
    as "the custodian has installed this test's original drain monitor"
  let assert Ok(events) = process.receive(streams, within: 1000)
    as "the relay opened its inner stream"
  process.send(
    events,
    stream.Delta(stream.TextDelta(index: 0, text: "before crash")),
  )

  let assert Ok(stream.Failed(error: stream.TransportFailed(reason:))) =
    stream.next(handle, within: 1000)
  assert reason == "provider relay worker stopped before a terminal response"
  let assert Ok(Nil) = process.receive(cancelled, within: 1000)
  assert stream.await_drain(drain_witness, within: 1000) == stream.Drained
    as "the custodian retires once the crashed worker is gone"
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

// --- the operator's schedule surface ---------------------------------------

// The hub's own conduct over a scripted door: what it lists, what code it
// answers each refusal with, and what a successful cancel replies with.
// The real door over a real store is `scheduleadmin_test`'s subject, and
// scripting it here is what keeps this file about the hub.
type DoorMessage {
  ListRows(reply: Subject(Result(List(scheduleadmin.Row), String)))
  CancelRow(
    target: String,
    name: String,
    reply: Subject(Result(Nil, scheduleadmin.CancelRefusal)),
  )
}

fn scripted_admin(rows: List(scheduleadmin.Row)) -> scheduleadmin.Admin {
  let assert Ok(door) =
    actor.new(rows)
    |> actor.on_message(fn(rows, message) {
      case message {
        ListRows(reply:) -> {
          process.send(reply, Ok(rows))
          actor.continue(rows)
        }
        CancelRow(target:, name:, reply:) -> {
          let #(kept, answer) = scripted_cancel(rows, target, name)
          process.send(reply, answer)
          actor.continue(kept)
        }
      }
    })
    |> actor.start
    as "the scripted schedule door must start"
  scheduleadmin.Admin(
    list: fn() { process.call(door.data, waiting: 1000, sending: ListRows) },
    cancel: fn(target, name) {
      process.call(door.data, waiting: 1000, sending: CancelRow(target, name, _))
    },
  )
}

// The real door's three answers, decided the way the real one decides
// them: an operator row cannot be retired, a model row is removed, and
// anything else was never there.
fn scripted_cancel(
  rows: List(scheduleadmin.Row),
  target: String,
  name: String,
) -> #(List(scheduleadmin.Row), Result(Nil, scheduleadmin.CancelRefusal)) {
  case list.find(rows, fn(row) { row.target == target && row.name == name }) {
    Error(Nil) -> #(rows, Error(scheduleadmin.NotFound))
    Ok(found) if found.owner == "operator" -> #(
      rows,
      Error(scheduleadmin.OperatorConfigured),
    )
    Ok(found) -> #(list.filter(rows, fn(row) { row != found }), Ok(Nil))
  }
}

fn operator_row() -> scheduleadmin.Row {
  scheduleadmin.Row(
    name: "nightly",
    target: "main",
    owner: "operator",
    when: "every 3600s, at most 24 times",
    wake: schedule.WakesIdle,
    fired: 7,
    body: "summarize what changed today",
  )
}

fn model_row() -> scheduleadmin.Row {
  scheduleadmin.Row(
    name: "heartbeat",
    target: "sub:main/reviewer-abc123",
    owner: "main",
    when: "every 300s, at most 20 times",
    wake: schedule.SteersOnly,
    fired: 2,
    body: "report where the review has got to",
  )
}

fn schedules_listing(harness: Harness, id: Int) -> List(protocol.ScheduleInfo) {
  let envelope = next(harness)
  assert envelope.reply_to == Some(id)
  let assert protocol.SnapshotEvent(protocol.SchedulesSnapshot(schedules:)) =
    envelope.event
    as "a schedules snapshot was expected"
  schedules
}

/// The `models` posture: a host with no scheduling plane has nothing to
/// list, and says so with an empty listing rather than an error, so a
/// client renders "no schedules" from the same reply shape it always
/// gets.
pub fn schedules_without_a_door_lists_nothing_test() {
  let harness = start_harness()
  subscribe(harness)
  send(harness, 30, protocol.ListSchedules)
  assert schedules_listing(harness, 30) == []
}

/// Order is part of the answer: standing configuration first, then what
/// this session grew. An operator reading the table sees which half is
/// theirs without reading the `owner` column.
pub fn schedules_lists_operator_rows_before_model_rows_test() {
  let harness =
    start_harness_with_schedules(scripted_admin([operator_row(), model_row()]))
  subscribe(harness)
  send(harness, 31, protocol.ListSchedules)
  assert schedules_listing(harness, 31)
    == [
      protocol.ScheduleInfo(
        name: "nightly",
        target: "main",
        owner: "operator",
        when: "every 3600s, at most 24 times",
        wake: protocol.WakesIdle,
        fired: 7,
        body: "summarize what changed today",
      ),
      protocol.ScheduleInfo(
        name: "heartbeat",
        target: "sub:main/reviewer-abc123",
        owner: "main",
        when: "every 300s, at most 20 times",
        wake: protocol.SteersOnly,
        fired: 2,
        body: "report where the review has got to",
      ),
    ]
}

/// The reply to a cancel *is* the listing that remains, which is what
/// lets a client re-render from one round trip. A success followed by a
/// stale table would be the same bug the poke after a retire exists to
/// prevent, one layer up.
pub fn cancelling_a_model_schedule_replies_with_what_remains_test() {
  let harness =
    start_harness_with_schedules(scripted_admin([operator_row(), model_row()]))
  subscribe(harness)
  send(
    harness,
    32,
    protocol.CancelSchedule(
      target: "sub:main/reviewer-abc123",
      name: "heartbeat",
    ),
  )
  let remaining = schedules_listing(harness, 32)
  assert list.map(remaining, fn(row) { row.name }) == ["nightly"]

  // And the door was actually asked, not merely answered: a second
  // listing agrees with the reply.
  send(harness, 33, protocol.ListSchedules)
  assert list.map(schedules_listing(harness, 33), fn(row) { row.name })
    == ["nightly"]
}

/// A conflict rather than a bad request: the name is real and the
/// operator may certainly end it — the file is where they do it.
pub fn cancelling_an_operator_schedule_is_a_conflict_test() {
  let harness =
    start_harness_with_schedules(scripted_admin([operator_row(), model_row()]))
  subscribe(harness)
  send(harness, 34, protocol.CancelSchedule(target: "main", name: "nightly"))
  expect_error(harness, 34, protocol.code_conflict)

  // Refused means untouched: both rows are still there.
  send(harness, 35, protocol.ListSchedules)
  assert list.length(schedules_listing(harness, 35)) == 2
}

pub fn cancelling_an_unknown_schedule_is_a_bad_request_test() {
  let harness = start_harness_with_schedules(scripted_admin([operator_row()]))
  subscribe(harness)
  send(harness, 36, protocol.CancelSchedule(target: "main", name: "ghost"))
  expect_error(harness, 36, protocol.code_bad_request)
}

/// Unsupported rather than an empty success: a cancellation that
/// cancelled nothing must not read as one that worked.
pub fn cancelling_without_a_door_is_unsupported_test() {
  let harness = start_harness()
  subscribe(harness)
  send(harness, 37, protocol.CancelSchedule(target: "main", name: "nightly"))
  expect_error(harness, 37, protocol.code_unsupported)
}

// --- pushed delivery (protocol-change/018) ---------------------------------

fn network_fixture_id() -> ids.SessionId {
  let #(id, _) =
    ids.mint_session(ids.generator(clock.fixed(at: 1_700_000_000_000), 4211))
  id
}

// The hub the daemon actually serves: network delivery, the bounded
// reader, and — since `protocol-change/018` — a push path.
fn network_harness() -> Harness {
  reserved_fixture(network_fixture_id())
}

fn operator(id: String, name: String) -> access.Principal {
  access.Principal(id, name, access.MemberPrincipal)
}

// Commits one user entry straight through the writer, which publishes to
// the fixture's commit forwarder and so gives the hub a real hint. Answers
// the seq the notice must carry.
fn commit_user_entry(harness: Harness, seed: Int, text: String) -> Int {
  let #(id, _) =
    ids.mint_entry(ids.generator(clock.fixed(1_700_000_000_001), seed))
  let row =
    core_entry.MessageEntry(
      id:,
      parent: None,
      seq: 0,
      ts: 0,
      message: message.UserMessage(
        content: [message.UserText(text:, text_signature: None)],
        timestamp: 0,
        origin: None,
      ),
      terminate: False,
    )
  let assert Ok(commit) =
    writer.commit(harness.runtime.tree.writer, tx.Tx([tx.InsertEntry(row)], []))
    as "the fixture entry commits"
  commit.first_seq
}

/// The property issue #240 is about: a peer learns of a commit without
/// asking. What it learns is a *notice* — the seq and the strand — and
/// deliberately not the record, which still travels the credited snapshot
/// path where the size bound and the retention window are enforced.
pub fn a_network_commit_reaches_a_subscribed_socket_as_one_notice_test() {
  let harness = network_harness()
  let inbox = process.new_subject()
  let #(_handle, _auth, _closed) =
    network_socket(
      harness.hub,
      harness.runtime,
      inbox,
      operator("alice", "Alice"),
      access.Participant(access.Operator),
    )
  let seq = commit_user_entry(harness, 71, "hello")

  let envelope = next_on(inbox)
  assert envelope.reply_to == None as "a notice answers no command"
  assert envelope.seq == Some(seq)
  assert envelope.event == protocol.CommittedEvent(strand: "main")

  // And nothing else. An `entry` frame here would be the record itself on
  // a path with neither credit nor a size bound.
  assert process.receive(inbox, within: 100) == Error(Nil)
}

/// A hub that starts over a store with history in it must treat that
/// history as history. Without the prime, its first hint would push a
/// notice for every sequence the session has ever written.
pub fn a_network_hub_primes_past_history_before_its_first_hint_test() {
  let harness = network_harness()
  let _before = commit_user_entry(harness, 72, "already committed")

  let name = addresses.new()
  let assert Ok(_later) =
    gateway.start(gateway.default_options("sess-01", harness.runtime), name)
    as "a second hub starts over the same store"
  let inbox = process.new_subject()
  let #(_handle, _auth, _closed) =
    network_socket(
      gateway.Gateway(name:),
      harness.runtime,
      inbox,
      operator("bob", "Bob"),
      access.Participant(access.Operator),
    )

  // A hint with nothing new behind it, which is what a hub sees for every
  // sequence that landed before it started.
  let assert Ok(forwarder) =
    gateway.commit_forwarder(to: name, as_name: addresses.new())
    as "the second hub's forwarder starts"
  process.send(forwarder.data, writer.Committed(ordinal: 1, seqs: [], ts: 0))
  assert process.receive(inbox, within: 200) == Error(Nil)
}

// A provider whose one turn is a text delta and then a settled answer.
fn delta_provider(text: String) -> effects.ProviderSurface {
  effects.ProviderSurface(timeout_ms: 1000, request: fn(_spec) {
    let events = process.new_subject()
    process.send(events, stream.Delta(delta: stream.TextDelta(index: 0, text:)))
    let assert Ok(settled) = stream.settle(scripted_answer())
    process.send(
      events,
      stream.Settled(message: settled, usage: effects.zero_usage()),
    )
    stream.immediate(events:, cancel: fn() { Nil })
  })
}

/// Deltas are what make a peer see an answer being written rather than a
/// discontinuous sample of it. They stay gated on the subscription: an
/// attachment that has not said it is here is told nothing.
pub fn a_provider_delta_reaches_only_a_subscribed_socket_test() {
  let harness = network_harness()
  let inbox = process.new_subject()
  let #(_handle, _auth, _closed) =
    network_socket(
      harness.hub,
      harness.runtime,
      inbox,
      operator("alice", "Alice"),
      access.Participant(access.Operator),
    )
  let quiet = process.new_subject()
  let assert Ok(_unsubscribed) =
    gateway.attach(harness.hub, fn(frame) { process.send(quiet, frame) })
    as "a second sink attaches without subscribing"

  let tapped = gateway.tap_provider(delta_provider("tok"), to: harness.hub.name)
  let handle = tapped.request(cancellation_spec())
  let assert Ok(stream.Delta(..)) = stream.next(handle, within: 1000)
    as "the runtime's own consumer still sees the delta"
  let assert Ok(stream.Settled(..)) = stream.next(handle, within: 1000)
    as "and its terminal"

  let envelope = next_on(inbox)
  assert envelope.reply_to == None
  let assert protocol.StreamDeltaEvent(kind: protocol.TextKind, text:, ..) =
    envelope.event
    as "a subscribed peer is pushed the delta"
  assert text == Some("tok")
  assert process.receive(quiet, within: 100) == Error(Nil)
}

/// Push opens no second way out. A membership that changed retires the
/// attachment before the commit's notice is built — the hint's
/// `revalidate_all` runs ahead of the pull — so the revoked socket is
/// closed and written nothing. The per-frame check inside `deliver` is
/// the second line, reached only by a change between those two reads in
/// one turn, which this fixture does not stage.
pub fn a_revoked_socket_is_retired_rather_than_pushed_to_test() {
  let harness = network_harness()
  let inbox = process.new_subject()
  let #(_handle, auth, closed) =
    network_socket(
      harness.hub,
      harness.runtime,
      inbox,
      operator("alice", "Alice"),
      access.Participant(access.Operator),
    )
  process.call(auth, waiting: 1000, sending: ChangeAuth(Error("revoked"), _))

  let _seq = commit_user_entry(harness, 73, "after the revocation")
  let assert Ok(Nil) = process.receive(closed, within: 2000)
    as "the attachment is closed at the authority check"
  assert process.receive(inbox, within: 100) == Error(Nil)
}

// --- the per-strand queue (protocol-change/018, ruling 3) ------------------

// Whether the scripted provider's turn may finish yet.
type GateState {
  Parked
  Released
}

type GateMessage {
  /// A provider turn asking to be held. The subject is replied to when the
  /// gate opens, or at once if it is open already.
  ParkGate(Subject(Nil))

  ReleaseGate(Subject(Nil))
}

fn start_gate() -> Subject(GateMessage) {
  let assert Ok(gate) =
    actor.new(#(Parked, []))
    |> actor.on_message(fn(state, message) {
      let #(opened, waiting) = state
      case message, opened {
        ParkGate(waiter), Released -> {
          process.send(waiter, Nil)
          actor.continue(state)
        }
        ParkGate(waiter), Parked ->
          actor.continue(#(Parked, [waiter, ..waiting]))
        ReleaseGate(reply), _ -> {
          list.each(waiting, fn(waiter) { process.send(waiter, Nil) })
          process.send(reply, Nil)
          actor.continue(#(Released, []))
        }
      }
    })
    |> actor.start
    as "the provider gate starts"
  gate.data
}

fn release_gate(gate: Subject(GateMessage)) -> Nil {
  process.call(gate, waiting: 5000, sending: ReleaseGate)
}

// A provider whose turn does not end until the test releases it, which is
// the only way this fixture can hold an operation open long enough for a
// second prompt to meet a busy strand.
//
// It parks by *receiving on a subject it just made*, never by asking the
// gate a question. `process.call` exits its caller when the answer is
// late, and a loaded runner made that reachable: a killed effect process
// ends the operation, the strand goes idle, and the queue this fixture
// exists to fill drains itself out from under the test.
fn parked_provider(gate: Subject(GateMessage)) -> effects.ProviderSurface {
  effects.ProviderSurface(timeout_ms: 30_000, request: fn(_spec) {
    let events = process.new_subject()
    let waiting = process.new_subject()
    process.send(gate, ParkGate(waiting))
    let _open = process.receive(waiting, within: 20_000)
    let assert Ok(settled) = stream.settle(scripted_answer())
    process.send(
      events,
      stream.Settled(message: settled, usage: effects.zero_usage()),
    )
    stream.immediate(events:, cancel: fn() { Nil })
  })
}

fn parked_network_harness(gate: Subject(GateMessage)) -> Harness {
  start_harness_reserved(
    None,
    None,
    None,
    Some(network_fixture_id()),
    ScriptedProvider(parked_provider(gate)),
  )
}

fn prompt_frame(id: Int, strand: String, text: String) -> String {
  protocol.encode_command(protocol.CommandEnvelope(
    id:,
    command: protocol.Prompt(strand:, text:),
  ))
}

fn outcome_status(frame: String) -> String {
  let assert Ok(envelope) = protocol.decode_event(frame) as "the reply decodes"
  let assert protocol.MutationOutcome(json.Object(fields)) = envelope.event
    as "a mutation outcome was expected"
  let assert Ok(json.String(status)) = list.key_find(fields, "status")
    as "the outcome carries a status"
  status
}

/// Two peers submitting inside one catch-up window is the case issue #240
/// is really about. The loser is queued rather than refused, and its
/// message reaches the transcript under *its own* author once the run it
/// lost to is done.
pub fn a_prompt_on_a_busy_strand_is_queued_and_drained_test() {
  let gate = start_gate()
  let harness = parked_network_harness(gate)
  let alice_inbox = process.new_subject()
  let bob_inbox = process.new_subject()
  let #(alice, _, _) =
    network_socket(
      harness.hub,
      harness.runtime,
      alice_inbox,
      operator("alice", "Alice"),
      access.Participant(access.Operator),
    )
  let #(bob, _, _) =
    network_socket(
      harness.hub,
      harness.runtime,
      bob_inbox,
      operator("bob", "Bob"),
      access.Participant(access.Operator),
    )

  let assert Ok(first) =
    gateway.connection_request(alice, prompt_frame(710, "main", "first"))
    as "Alice's prompt is answered"
  assert outcome_status(first) == "admitted"

  let assert Ok(second) =
    gateway.connection_request(bob, prompt_frame(711, "main", "second"))
    as "Bob's prompt is answered"
  assert outcome_status(second) == "queued"

  // The run Bob lost to finishes, and the hub submits what it held.
  release_gate(gate)
  let assert poll.Answered(author) =
    poll.until(within: 15_000, every: 25, attempt: fn() {
      case held_entry_origin(harness, "second") {
        Some(origin) -> poll.Done(origin)
        None -> poll.Retry
      }
    })
    as "the held prompt is admitted once the strand goes idle"
  assert author == message.Origin("bob", "Bob")
}

/// An observer meeting a busy strand is refused at admission rather than
/// held. The queue is a courtesy extended to a principal who may write; a
/// principal who may not write must learn that from the authority check on
/// the frame, before anything is held on its behalf, because a refusal that
/// waited for the drain would let an observer keep hub memory reserved and
/// would report the refusal at a moment the client can no longer tie to its
/// command.
pub fn an_observer_on_a_busy_strand_is_refused_at_admission_test() {
  let gate = start_gate()
  let harness = parked_network_harness(gate)
  let #(alice, _, _) =
    network_socket(
      harness.hub,
      harness.runtime,
      process.new_subject(),
      operator("alice", "Alice"),
      access.Participant(access.Operator),
    )
  let #(bob, _, _) =
    network_socket(
      harness.hub,
      harness.runtime,
      process.new_subject(),
      operator("bob", "Bob"),
      access.Participant(access.Operator),
    )
  let #(carol, _, _) =
    network_socket(
      harness.hub,
      harness.runtime,
      process.new_subject(),
      operator("carol", "Carol"),
      access.Participant(access.Observer),
    )

  let assert Ok(first) =
    gateway.connection_request(alice, prompt_frame(730, "main", "first"))
    as "Alice's prompt is answered"
  assert outcome_status(first) == "admitted"

  let assert Ok(second) =
    gateway.connection_request(bob, prompt_frame(731, "main", "second"))
    as "Bob's prompt is answered"
  assert outcome_status(second) == "queued"

  // The refusal is the authority check's, not the queue's: `forbidden`
  // rather than the `conflict` an over-full queue answers with.
  let assert Ok(refused) =
    gateway.connection_request(carol, prompt_frame(732, "main", "third"))
    as "Carol's prompt is answered"
  let assert Ok(envelope) = protocol.decode_event(refused)
    as "the refusal decodes"
  let assert protocol.ErrorEvent(code: "forbidden", ..) = envelope.event
    as "an observer may not submit, busy strand or not"

  release_gate(gate)
  let assert poll.Answered(_author) =
    poll.until(within: 15_000, every: 25, attempt: fn() {
      case held_entry_origin(harness, "second") {
        Some(origin) -> poll.Done(origin)
        None -> poll.Retry
      }
    })
    as "the held prompt is admitted once the strand goes idle"

  // Nothing Carol sent reached the transcript, and the drain did not admit
  // it late under somebody else's origin.
  assert held_entry_origin(harness, "third") == None
  assert user_prompt_texts(harness) == ["first", "second"]
}

// Every user prompt the transcript holds, in commit order.
fn user_prompt_texts(harness: Harness) -> List(String) {
  let assert Ok(rows) =
    storage.scan_entries(
      harness.runtime.session.store,
      storage.entry_scan() |> storage.entry_seq_range(Some(1), None),
    )
    as "the fixture reads its own transcript"
  list.filter_map(rows, fn(row) {
    case row {
      core_entry.MessageEntry(
        message: message.UserMessage(content: [message.UserText(text:, ..)], ..),
        ..,
      ) -> Ok(text)
      _ -> Error(Nil)
    }
  })
}

// The origin on the durable user entry carrying `text`, once one exists.
// That origin is the whole assertion: a queue that re-minted it at drain
// time would credit whoever happened to be attached by then.
fn held_entry_origin(harness: Harness, text: String) -> Option(message.Origin) {
  let assert Ok(rows) =
    storage.scan_entries(
      harness.runtime.session.store,
      storage.entry_scan() |> storage.entry_seq_range(Some(1), None),
    )
    as "the fixture reads its own transcript"
  list.fold(rows, None, fn(found, row) {
    case row {
      core_entry.MessageEntry(
        message: message.UserMessage(content: [content], origin:, ..),
        ..,
      ) ->
        case content == message.UserText(text:, text_signature: None) {
          True -> origin
          False -> found
        }
      _ -> found
    }
  })
}

/// The bound. A strand whose run never settles must not let a peer grow
/// hub memory without limit, so the fifth submission gets the conflict the
/// whole command used to answer with.
pub fn a_fifth_held_prompt_is_refused_as_a_conflict_test() {
  let gate = start_gate()
  let harness = parked_network_harness(gate)
  let inbox = process.new_subject()
  let #(socket, _, _) =
    network_socket(
      harness.hub,
      harness.runtime,
      inbox,
      operator("alice", "Alice"),
      access.Participant(access.Operator),
    )

  let assert Ok(opened) =
    gateway.connection_request(socket, prompt_frame(720, "main", "open"))
    as "the first prompt opens the run"
  assert outcome_status(opened) == "admitted"

  let statuses =
    list.map([721, 722, 723, 724], fn(id) {
      let assert Ok(frame) =
        gateway.connection_request(
          socket,
          prompt_frame(id, "main", "queued " <> int.to_string(id)),
        )
        as "each queued prompt is answered"
      outcome_status(frame)
    })
  assert statuses == ["queued", "queued", "queued", "queued"]

  let assert Ok(refused) =
    gateway.connection_request(
      socket,
      prompt_frame(725, "main", "one too many"),
    )
    as "the fifth is answered"
  let assert Ok(envelope) = protocol.decode_event(refused)
    as "the refusal decodes"
  let assert protocol.ErrorEvent(code:, ..) = envelope.event
    as "the fifth is refused rather than queued"
  assert code == protocol.code_conflict
  release_gate(gate)
}

/// A drain that fails for any reason but a busy strand is dropped, and its
/// submitter is told. The report answers no request — the command that
/// queued the prompt was answered when it arrived — so it is pushed.
///
/// The injection is one corrupt `strand.state` cell, which is both halves
/// of the case at once: the hub reads the strand as idle and drains it,
/// and the drain's own read of that cell fails.
pub fn a_drain_that_cannot_be_admitted_reports_to_its_submitter_test() {
  let gate = start_gate()
  let harness = parked_network_harness(gate)
  let inbox = process.new_subject()
  let #(socket, _, _) =
    network_socket(
      harness.hub,
      harness.runtime,
      inbox,
      operator("alice", "Alice"),
      access.Participant(access.Operator),
    )

  let assert Ok(opened) =
    gateway.connection_request(socket, prompt_frame(730, "main", "open"))
    as "the first prompt opens the run"
  assert outcome_status(opened) == "admitted"
  let assert Ok(held) =
    gateway.connection_request(socket, prompt_frame(731, "main", "held"))
    as "the second prompt is held"
  assert outcome_status(held) == "queued"

  let assert Ok(_corrupted) =
    writer.commit(
      harness.runtime.tree.writer,
      tx.Tx(
        [
          tx.SetRegister(
            register.StrandState,
            "main",
            register.value(json.String("not a strand state")),
          ),
        ],
        [],
      ),
    )
    as "the corrupt cell commits, and its own hint drives the drain"

  // The admitted first prompt's own notice is already on this sink, so the
  // report is looked for past it rather than in the next frame.
  let assert protocol.ErrorEvent(..) = pushed_error(inbox, 8)
    as "the submitter is told its held prompt was dropped"
  release_gate(gate)
}

fn pushed_error(inbox: Subject(String), remaining: Int) -> protocol.Event {
  let envelope = next_on(inbox)
  case envelope.event, remaining > 0 {
    protocol.ErrorEvent(..), _ -> envelope.event
    _, True -> pushed_error(inbox, remaining - 1)
    _, False -> panic as "a pushed error must reach the submitter"
  }
}
