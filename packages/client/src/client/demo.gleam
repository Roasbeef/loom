//// The scripted end-to-end demo: a real session, a real runtime with
//// scripted provider effects, a served gateway — and the whole M3
//// acceptance flow driven **through the client protocol only**:
//// subscribe → prompt (tool round-trip, streamed deltas) → a subagent
//// strand created and briefed → durable messaging back to the parent →
//// escalation raised, approved over the wire, consumed as typed grants
//// → fork → navigate → compact → catch-up replay → final snapshot.
////
//// `run` is the M3 acceptance test's body (`client/demo_test` executes
//// it inside `make check-client`); `main` runs the same flow from the
//// command line (`cd packages/client && gleam run -m client/demo`) and
//// prints the narrative.
////
//// The effect surface follows the conformance simulation's shape —
//// generation requests are answered by the *content and phase of the
//// projected context*, tools settle scripted results, hooks supply the
//// compaction summary — copied rather than imported, because the
//// conformance package's surface is test support, not a library
//// (spec-gaps: no cross-test-boundary imports). Inter-strand messaging
//// uses the same pattern as the conformance multi-strand scenario: once
//// the subagent's terminal result lands, its findings travel to the
//// parent with `api.send_to_strand` — the durable steer-or-start
//// admission — and everything the client sees of it arrives through
//// the protocol's event stream.

import broker/broker
import broker/exec
import broker/token
import client/escalate
import client/gateway
import client/grants
import client/protocol
import client/serve
import client/server
import client/summaries
import client/system_prompt
import client/wiring
import core/clock
import core/entry
import core/ids
import core/json
import core/message.{type AgentMessage}
import gleam/bool
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import machine/operation
import machine/strand as machine_strand
import provider/gateway as provider_gateway
import provider/http
import provider/model
import provider/secret
import provider/stream
import runtime/api
import runtime/effects
import session/session
import storage/storage

import broker/escalation as broker_escalation
import broker/policy

/// The session name clients subscribe with.
pub const session_id = "demo-session"

/// The durable cross-strand report the subagent sends its parent.
pub const report_text = "research reports: verified the fetch layer"

/// What the scripted provider answers a summary request with. The demo
/// asserts the committed `CompactionEntry` carries exactly this, which
/// is how it proves the summary came from a provider rather than from a
/// hook the demo installed.
pub const summary_text = "nested summary output"

/// One line of the demo's narrative.
pub type Narrative =
  List(String)

/// Runs the full acceptance flow and prints the narrative.
///
/// ## Examples
///
/// ```gleam
/// // gleam run -m client/demo
/// ```
///
pub fn main() -> Nil {
  case run() {
    Ok(lines) -> list.each(lines, io.println)
    Error(reason) -> io.println("demo failed: " <> reason)
  }
}

/// Drives the M3 acceptance flow through the protocol and returns the
/// narrative; any deviation from the expected flow is an `Error` naming
/// the step that broke.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(_lines) = demo.run()
/// ```
///
pub fn run() -> Result(Narrative, String) {
  // --- a real session, a real runtime, scripted effects ------------------
  use session <- result.try(
    session.open_memory(clock.stepping(from: 1_756_000_000_000, by: 3))
    |> result.map_error(fn(_) { "the memory session did not open" }),
  )
  use entropy <- result.try(start_entropy())
  let name = process.new_name(prefix: "loom_gateway_demo")
  let forwarder_name = process.new_name(prefix: "loom_forwarder_demo")
  use _forwarder <- result.try(
    gateway.commit_forwarder(to: name, as_name: forwarder_name)
    |> result.map_error(fn(_) { "the commit forwarder did not start" }),
  )
  // Compaction runs on the *production* seams. The demo scripts the
  // provider's answers and the tools' results, and nothing else: the
  // hooks that decide whether to compact, what to compact, and what the
  // provider's answer meant are `client/wiring`'s own, over a real
  // session and a real routing table. A demo that supplied its own
  // summary would prove nothing about whether compaction runs.
  use wiring_config <- result.try(compaction_wiring(session))
  let effects =
    effects.Effects(
      clock: clock.stepping(from: 1_756_000_000_000, by: 3),
      entropy:,
      timers: effects.real_timers(),
      provider: gateway.tap_provider(
        wiring.recording_summaries(
          scripted_provider(),
          into: wiring_config.summaries,
        ),
        to: name,
      ),
      tools: scripted_tools(),
      hooks: wiring.compaction_hooks(wiring_config),
    )
  let configuration =
    machine_strand.StrandConfiguration(
      model: machine_strand.ModelIdentity(provider: "acme", model_id: "loom-1"),
      thinking_level: machine_strand.ThinkingOff,
      active_tool_names: ["bash"],
    )
  let options = api.default_options(configuration)
  use runtime <- result.try(api.open(
    session,
    effects,
    api.Options(..options, poll_interval_ms: 25, subscribers: [
      process.named_subject(forwarder_name),
    ]),
  ))
  // --- the served gateway -------------------------------------------------
  use _gateway <- result.try(
    gateway.start(gateway.default_options(session_id, runtime), name)
    |> result.map_error(fn(_) { "the gateway did not start" }),
  )
  let hub = gateway.Gateway(name:)
  use served <- result.try(
    server.serve(server.Config(
      gateway: hub,
      bind: "127.0.0.1",
      port: 0,
      auth: server.BearerAuth(token: server.mint_token(entropy)),
      entropy:,
    ))
    |> result.map_error(fn(_) { "the websocket server did not start" }),
  )
  // --- drive the flow through the protocol --------------------------------
  let outcome = drive(hub, runtime, served)
  server.stop(served)
  let _closed = api.close(runtime)
  outcome
}

/// The served endpoint of a demo run, for transport-level smoke tests.
pub type Served =
  server.Server

fn drive(
  hub: gateway.Gateway,
  runtime: api.Runtime,
  served: server.Server,
) -> Result(Narrative, String) {
  let inbox = process.new_subject()
  let connection = gateway.attach(hub, fn(frame) { process.send(inbox, frame) })
  let client = Client(hub:, connection:, inbox:)
  use lines <- result.try(acceptance_flow(client, runtime))
  Ok(
    list.append(lines, [
      "served: ws://127.0.0.1:"
      <> int.to_string(served.port)
      <> "/v1/ws (bearer auth)",
    ]),
  )
}

type Client {
  Client(hub: gateway.Gateway, connection: Int, inbox: Subject(String))
}

fn acceptance_flow(
  client: Client,
  runtime: api.Runtime,
) -> Result(Narrative, String) {
  // 1. subscribe → full snapshot.
  use _snapshot <- result.try(subscribe_full(client))
  let lines = ["subscribed: full snapshot for " <> session_id]
  // 2. prompt main: tool round-trip with streamed deltas.
  use Nil <- result.try(command_replied(
    client,
    2,
    protocol.Prompt(strand: "main", text: "add a retry to the fetcher"),
    fn(envelope) {
      case envelope.event {
        protocol.EntryEvent(..) -> True
        _ -> False
      }
    },
    "prompt main",
  ))
  use Nil <- result.try(await(client, done_for(_, "main"), "main run settled"))
  let lines = ["prompted main: run settled after a bash round-trip", ..lines]
  // 3. a subagent strand, created and briefed over the wire.
  use Nil <- result.try(command_replied(
    client,
    3,
    protocol.CreateStrand(name: Some("research")),
    strands_reply(_, "research"),
    "create_strand research",
  ))
  use Nil <- result.try(command_replied(
    client,
    4,
    protocol.Prompt(strand: "research", text: "verify the fetch layer"),
    fn(envelope) {
      case envelope.event {
        protocol.EntryEvent(..) -> True
        _ -> False
      }
    },
    "brief research",
  ))
  use Nil <- result.try(await(
    client,
    done_for(_, "research"),
    "research run settled",
  ))
  let lines = ["created and briefed the research strand", ..lines]
  // 4. durable messaging: research reports to main; main acknowledges.
  use Nil <- result.try(
    case
      api.send_to_strand(
        api.on_strand(runtime, "research"),
        to: "main",
        message: message.UserMessage(
          content: [message.UserText(text: report_text, text_signature: None)],
          timestamp: 0,
        ),
      )
    {
      Ok(_) -> Ok(Nil)
      Error(_) -> Error("the cross-strand send was refused")
    },
  )
  use Nil <- result.try(await(
    client,
    report_entry_on_main,
    "the report reached main's tree",
  ))
  use Nil <- result.try(await(client, done_for(_, "main"), "main acknowledged"))
  let lines = ["research reported to main durably; main acknowledged", ..lines]
  // 5. escalation: raised harness-side, approved over the wire, consumed
  //    as typed grants.
  let wanted =
    policy.GrantNetwork(network: policy.NetworkProxy(
      allow: ["registry.npmjs.org"],
      proxy: "127.0.0.1:3128",
    ))
  use Nil <- result.try(
    api.raise_escalation(
      runtime,
      "esc-1",
      grants.encode_denial(
        reason: "connect to registry.npmjs.org:443 blocked by policy",
        source: broker_escalation.PolicyDenial,
        wanted: [wanted],
      ),
    )
    |> result.map_error(fn(_) { "raising the escalation failed" }),
  )
  use Nil <- result.try(await(
    client,
    escalation_status(_, "esc-1", "pending"),
    "escalation surfaced as pending",
  ))
  use Nil <- result.try(command_replied(
    client,
    5,
    // Raised through the unscoped door, so the record names no action
    // and the echo the gateway checks is the empty one.
    protocol.Approve(escalation_id: "esc-1", grants: [wanted], action: ""),
    escalation_reply(_, "esc-1", "approved"),
    "approve esc-1",
  ))
  use typed <- result.try(
    api.consume_escalation(runtime, "esc-1")
    |> result.map_error(fn(_) { "consuming the approval failed" })
    |> result.try(fn(raw) {
      grants.decode_all(raw)
      |> result.map_error(fn(_) { "the consumed grants did not decode" })
    }),
  )
  use Nil <- result.try(case typed == [wanted] {
    True -> Ok(Nil)
    False -> Error("the consumed grants did not round-trip to policy grants")
  })
  let lines = [
    "escalation approved over the wire; grants consumed as typed policy grants",
    ..lines
  ]
  // 6. fork: a new strand at main's leaf.
  use Nil <- result.try(command_replied(
    client,
    6,
    protocol.Fork(
      strand: "main",
      scope: protocol.ScopeBranch,
      name: Some("alt-approach"),
    ),
    strands_reply(_, "alt-approach"),
    "fork main",
  ))
  let lines = ["forked main in place as alt-approach", ..lines]
  // 7. navigate the fork back to the root of its shared history.
  use target <- result.try(oldest_entry_id(runtime))
  use Nil <- result.try(command_replied(
    client,
    7,
    protocol.Navigate(strand: "alt-approach", to_entry: target),
    fn(envelope) {
      case envelope.event {
        protocol.SnapshotEvent(protocol.StrandsSnapshot(strands:)) ->
          list.any(strands, fn(strand: protocol.Strand) {
            strand.id == "alt-approach" && strand.leaf == Some(target)
          })
        _ -> False
      }
    },
    "navigate alt-approach",
  ))
  let lines = ["navigated alt-approach to the oldest shared entry", ..lines]
  // 8. compact main.
  use Nil <- result.try(command_replied(
    client,
    8,
    protocol.Compact(strand: "main", instructions: None),
    fn(envelope) {
      case envelope.event {
        protocol.OpTransitionEvent(..) -> True
        _ -> False
      }
    },
    "compact main",
  ))
  use Nil <- result.try(await(
    client,
    compaction_entry(_, "main"),
    "the compaction entry appeared",
  ))
  use Nil <- result.try(await(client, done_for(_, "main"), "compaction done"))
  let lines = ["compacted main: summary entry committed", ..lines]
  // 9. set_config over the wire.
  use Nil <- result.try(command_replied(
    client,
    9,
    protocol.SetConfig(
      strand: None,
      config: json.Object([#("queue_mode", json.String("one_at_a_time"))]),
    ),
    fn(envelope) {
      case envelope.event {
        protocol.SnapshotEvent(protocol.ConfigSnapshot(..)) -> True
        _ -> False
      }
    },
    "set_config",
  ))
  let lines = ["set queue_mode over the wire", ..lines]
  // 10. catch-up replay: every durable entry event again, exactly once,
  //     in seq order, from seq 1.
  use replayed <- result.try(catch_up_all(client, 10))
  use Nil <- result.try(check_replay(replayed))
  let lines = [
    "caught up from seq 1: replay is seq-ordered and duplicate-free",
    ..lines
  ]
  // 11. a second connection's full snapshot shows the final state.
  use snapshot <- result.try(final_snapshot(client))
  use Nil <- result.try(check_final(snapshot))
  let lines = [
    "final snapshot: main, research, and alt-approach; compaction durable",
    ..lines
  ]
  Ok(list.reverse(lines))
}

// --- protocol-side helpers -------------------------------------------------

fn send_command(client: Client, id: Int, command: protocol.Command) -> Nil {
  gateway.handle_text(
    client.hub,
    client.connection,
    protocol.encode_command(protocol.CommandEnvelope(id:, command:)),
  )
}

fn next_event(
  client: Client,
  step: String,
) -> Result(protocol.EventEnvelope, String) {
  case process.receive(client.inbox, within: 8000) {
    Error(Nil) -> Error(step <> ": timed out waiting for an event")
    Ok(frame) ->
      protocol.decode_event(frame)
      |> result.map_error(fn(_) { "an event frame did not decode: " <> frame })
  }
}

// Sends a command and drains events until its reply arrives; the reply
// must satisfy `expected` and not be an error.
fn command_replied(
  client: Client,
  id: Int,
  command: protocol.Command,
  expected: fn(protocol.EventEnvelope) -> Bool,
  step: String,
) -> Result(Nil, String) {
  send_command(client, id, command)
  reply_loop(client, id, expected, step, 200)
}

fn reply_loop(
  client: Client,
  id: Int,
  expected: fn(protocol.EventEnvelope) -> Bool,
  step: String,
  budget: Int,
) -> Result(Nil, String) {
  use <- bool.lazy_guard(when: budget <= 0, return: fn() {
    Error(step <> ": no reply arrived")
  })
  use envelope <- result.try(next_event(client, step))
  case envelope.reply_to == Some(id) {
    False -> reply_loop(client, id, expected, step, budget - 1)
    True -> reply_outcome(envelope, expected, step)
  }
}

fn reply_outcome(
  envelope: protocol.EventEnvelope,
  expected: fn(protocol.EventEnvelope) -> Bool,
  step: String,
) -> Result(Nil, String) {
  case envelope.event {
    protocol.ErrorEvent(code:, message:, ..) ->
      Error(step <> " failed: " <> code <> ": " <> message)
    _ ->
      case expected(envelope) {
        True -> Ok(Nil)
        False -> Error(step <> ": unexpected reply shape")
      }
  }
}

// Drains events until one satisfies the predicate.
fn await(
  client: Client,
  wanted: fn(protocol.EventEnvelope) -> Bool,
  step: String,
) -> Result(Nil, String) {
  await_loop(client, wanted, step, 400)
}

fn await_loop(
  client: Client,
  wanted: fn(protocol.EventEnvelope) -> Bool,
  step: String,
  budget: Int,
) -> Result(Nil, String) {
  case budget <= 0 {
    True -> Error(step <> ": the awaited event never arrived")
    False -> {
      use envelope <- result.try(next_event(client, step))
      case wanted(envelope) {
        True -> Ok(Nil)
        False -> await_loop(client, wanted, step, budget - 1)
      }
    }
  }
}

fn subscribe_full(client: Client) -> Result(protocol.Snapshot, String) {
  send_command(
    client,
    1,
    protocol.Subscribe(session: session_id, from_seq: None),
  )
  use envelope <- result.try(next_event(client, "subscribe"))
  case envelope.reply_to, envelope.event {
    Some(1), protocol.SnapshotEvent(snapshot) ->
      case snapshot {
        protocol.FullSnapshot(..) -> Ok(snapshot)
        _ -> Error("subscribe: expected a full snapshot")
      }
    _, protocol.ErrorEvent(code:, ..) -> Error("subscribe failed: " <> code)
    _, _ -> Error("subscribe: the first event was not the snapshot reply")
  }
}

fn done_for(envelope: protocol.EventEnvelope, strand: String) -> Bool {
  case envelope.event {
    protocol.StrandResultEvent(strand: on, status: "done", ..) -> on == strand
    _ -> False
  }
}

fn strands_reply(envelope: protocol.EventEnvelope, expected: String) -> Bool {
  case envelope.event {
    protocol.SnapshotEvent(protocol.StrandsSnapshot(strands:)) ->
      list.any(strands, fn(strand: protocol.Strand) { strand.id == expected })
    _ -> False
  }
}

fn escalation_reply(
  envelope: protocol.EventEnvelope,
  id: String,
  status: String,
) -> Bool {
  case envelope.event {
    protocol.EscalationEvent(record:) ->
      record.escalation_id == id && record.status == status
    _ -> False
  }
}

fn escalation_status(
  envelope: protocol.EventEnvelope,
  id: String,
  status: String,
) -> Bool {
  escalation_reply(envelope, id, status)
}

fn report_entry_on_main(envelope: protocol.EventEnvelope) -> Bool {
  case envelope.event {
    protocol.EntryEvent(record: protocol.EntryRecord(
      strand: "main",
      entry: entry.MessageEntry(
        message: message.UserMessage(content:, ..),
        seq:,
        ..,
      ),
    )) ->
      seq > 0
      && list.any(content, fn(block) {
        case block {
          message.UserText(text:, ..) -> text == report_text
          _ -> False
        }
      })
    _ -> False
  }
}

// A compaction entry whose summary is the *scripted provider's* answer.
// The demo supplies no summary of its own any more: the hooks are
// `client/wiring`'s, so a compaction that lands here was decided,
// prepared, dispatched and read back by production code, and its text
// came off the wire.
fn compaction_entry(envelope: protocol.EventEnvelope, strand: String) -> Bool {
  case envelope.event {
    protocol.EntryEvent(record: protocol.EntryRecord(
      strand: on,
      entry: entry.CompactionEntry(summary:, from_hook: False, ..),
    )) -> on == strand && summary == summary_text
    _ -> False
  }
}

// The oldest entry on main's branch — the navigation target for the
// forked strand (fork shares the tree, so main's history is its own).
fn oldest_entry_id(runtime: api.Runtime) -> Result(String, String) {
  case session.strand_leaf(runtime.session, "main") {
    Ok(Some(session.Cell(value: Some(leaf), ..))) ->
      case
        storage.scan_branch(
          runtime.session.store,
          storage.branch_scan(from: leaf)
            |> storage.branch_order(storage.OldestFirst)
            |> storage.branch_limit(1),
        )
      {
        Ok([oldest]) -> Ok(ids.entry_id_to_string(entry_id_of(oldest)))
        _ -> Error("no navigation target exists")
      }
    _ -> Error("main has no leaf to navigate from")
  }
}

fn entry_id_of(row: entry.Entry) -> ids.EntryId {
  case row {
    entry.MessageEntry(id:, ..) -> id
    entry.CompactionEntry(id:, ..) -> id
    entry.BranchSummaryEntry(id:, ..) -> id
    entry.CustomEntry(id:, ..) -> id
  }
}

// --- catch-up and final-state checks ---------------------------------------

// Replays everything from seq 1 and returns the replayed envelopes (the
// resume snapshot reply excluded).
fn catch_up_all(
  client: Client,
  id: Int,
) -> Result(List(protocol.EventEnvelope), String) {
  send_command(client, id, protocol.CatchUp(from_seq: 1))
  use next_seq <- result.try(resume_reply(client, id, 200))
  collect_replay(client, next_seq, [])
}

fn resume_reply(client: Client, id: Int, budget: Int) -> Result(Int, String) {
  case budget <= 0 {
    True -> Error("catch_up: no resume snapshot arrived")
    False -> {
      use envelope <- result.try(next_event(client, "catch_up"))
      case envelope.reply_to, envelope.event {
        Some(reply), protocol.SnapshotEvent(protocol.ResumeSnapshot(next_seq:))
        ->
          case reply == id {
            True -> Ok(next_seq)
            False -> resume_reply(client, id, budget - 1)
          }
        Some(reply), protocol.ErrorEvent(code:, ..) ->
          case reply == id {
            True -> Error("catch_up failed: " <> code)
            False -> resume_reply(client, id, budget - 1)
          }
        _, _ -> resume_reply(client, id, budget - 1)
      }
    }
  }
}

// Collects replayed events until the stream reaches next_seq - 1 (the
// replay is synchronous on the hub, so a short quiet period ends it).
fn collect_replay(
  client: Client,
  next_seq: Int,
  collected: List(protocol.EventEnvelope),
) -> Result(List(protocol.EventEnvelope), String) {
  case process.receive(client.inbox, within: 500) {
    Error(Nil) -> Ok(list.reverse(collected))
    Ok(frame) ->
      case protocol.decode_event(frame) {
        Error(_) -> Error("a replayed frame did not decode")
        Ok(envelope) ->
          case envelope.seq {
            Some(seq) if seq >= next_seq ->
              collect_replay(client, next_seq, collected)
            _ -> collect_replay(client, next_seq, [envelope, ..collected])
          }
      }
  }
}

fn check_replay(replayed: List(protocol.EventEnvelope)) -> Result(Nil, String) {
  let seqs =
    list.filter_map(replayed, fn(envelope) {
      case envelope.seq {
        Some(seq) -> Ok(seq)
        None -> Error(Nil)
      }
    })
  let ordered =
    seqs
    |> list.window_by_2
    |> list.all(fn(pair) { pair.0 < pair.1 })
  let has_entries =
    list.any(replayed, fn(envelope) {
      case envelope.event {
        protocol.EntryEvent(..) -> True
        _ -> False
      }
    })
  case ordered, has_entries {
    True, True -> Ok(Nil)
    False, _ -> Error("replay seqs were not strictly increasing")
    _, False -> Error("replay carried no entry events")
  }
}

fn final_snapshot(client: Client) -> Result(protocol.Snapshot, String) {
  let inbox = process.new_subject()
  let connection =
    gateway.attach(client.hub, fn(frame) { process.send(inbox, frame) })
  let second = Client(hub: client.hub, connection:, inbox:)
  subscribe_full(second)
}

fn check_final(snapshot: protocol.Snapshot) -> Result(Nil, String) {
  case snapshot {
    protocol.FullSnapshot(strands:, entries:, ..) -> {
      let names = list.map(strands, fn(strand: protocol.Strand) { strand.id })
      let has_compaction =
        list.any(entries, fn(record: protocol.EntryRecord) {
          case record.entry {
            entry.CompactionEntry(..) -> True
            _ -> False
          }
        })
      case
        list.contains(names, "main")
        && list.contains(names, "research")
        && list.contains(names, "alt-approach")
        && has_compaction
      {
        True -> Ok(Nil)
        False -> Error("the final snapshot is missing strands or compaction")
      }
    }
    _ -> Error("the final snapshot was not full")
  }
}

// --- the scripted effect surface -------------------------------------------

// A process-backed counter: the entropy source (seeds must never repeat
// within the session).
fn start_entropy() -> Result(fn() -> Int, String) {
  let started =
    actor.new(1)
    |> actor.on_message(fn(next, reply: Subject(Int)) {
      process.send(reply, next)
      actor.continue(next + 1)
    })
    |> actor.start
  case started {
    Error(_) -> Error("the entropy counter did not start")
    Ok(counter) ->
      Ok(fn() {
        1_000_000
        + process.call(counter.data, waiting: 1000, sending: fn(reply) { reply })
        * 104_729
      })
  }
}

// Generation requests answered by the projected context: the newest
// user text picks the scripted turn, the assistant count breaks the
// tie between "open with a tool call" and "answer".
fn scripted_provider() -> effects.ProviderSurface {
  effects.ProviderSurface(timeout_ms: 4000, request: fn(spec) {
    let events = process.new_subject()
    case spec {
      effects.PollRequest(..) -> settle(events, answer("polled", 1), [])
      effects.SummaryRequest(..) -> settle(events, answer(summary_text, 2), [])
      effects.GenerationRequest(context:, ..) ->
        generation_response(events, context)
    }
    stream.StreamHandle(events:)
  })
}

// The scripted generation turn: the newest user text picks a canned
// reply, and (for the retry scenario) the assistant count breaks the tie
// between "open with a tool call" and "answer".
fn generation_response(
  events: Subject(stream.StreamEvent),
  context: List(AgentMessage),
) -> Nil {
  let newest = newest_user_text(context)
  case newest == report_text, newest == "verify the fetch layer" {
    True, _ -> settle(events, answer("acknowledged: verified", 2), [])
    _, True -> settle(events, answer("verified the fetch layer", 2), [])
    _, _ -> retry_turn_response(events, context)
  }
}

fn retry_turn_response(
  events: Subject(stream.StreamEvent),
  context: List(AgentMessage),
) -> Nil {
  case assistant_turns(context) {
    0 ->
      settle(events, tool_call_response(), [
        stream.TextDelta(index: 0, text: "I will wrap the call"),
        stream.ToolCallDelta(
          index: 1,
          call_id: "call-1",
          name: "bash",
          arguments_json: "{\"command\":\"go te",
        ),
      ])
    _ ->
      settle(events, answer("retry added; tests pass", 3), [
        stream.TextDelta(index: 0, text: "retry added"),
      ])
  }
}

fn settle(
  events: Subject(stream.StreamEvent),
  message: AgentMessage,
  deltas: List(stream.Delta),
) -> Nil {
  list.each(deltas, fn(delta) { process.send(events, stream.Delta(delta:)) })
  case stream.settle(message) {
    Ok(settled) ->
      process.send(
        events,
        stream.Settled(message: settled, usage: usage_of(message)),
      )
    Error(Nil) ->
      process.send(
        events,
        stream.Failed(error: stream.TransportFailed(
          reason: "the scripted settlement was not settleable",
        )),
      )
  }
}

fn usage_of(message: AgentMessage) -> message.Usage {
  case message {
    message.AssistantMessage(usage:, ..) -> usage
    _ -> effects.zero_usage()
  }
}

fn newest_user_text(context: List(AgentMessage)) -> String {
  list.fold(context, "", fn(found, item) {
    case item {
      message.UserMessage(content:, ..) ->
        content
        |> list.filter_map(fn(block) {
          case block {
            message.UserText(text:, ..) -> Ok(text)
            _ -> Error(Nil)
          }
        })
        |> string.join(" ")
      _ -> found
    }
  })
}

fn assistant_turns(context: List(AgentMessage)) -> Int {
  list.fold(context, 0, fn(count, item) {
    case item {
      message.AssistantMessage(..) -> count + 1
      _ -> count
    }
  })
}

fn answer(text: String, tokens: Int) -> AgentMessage {
  assistant(
    [message.AssistantText(text:, text_signature: None)],
    message.Stop,
    tokens,
  )
}

fn tool_call_response() -> AgentMessage {
  assistant(
    [
      message.AssistantText(
        text: "I will wrap the call in a bounded retry.",
        text_signature: None,
      ),
      message.AssistantToolCall(call: message.ToolCall(
        id: "call-1",
        name: "bash",
        arguments: json.Object([
          #("command", json.String("go test ./...")),
        ]),
        thought_signature: None,
        namespace: None,
      )),
    ],
    message.ToolUse,
    5,
  )
}

fn assistant(
  content: List(message.AssistantBlock),
  stop: message.StopReason,
  tokens: Int,
) -> AgentMessage {
  message.AssistantMessage(
    content:,
    api: "demo",
    provider: "acme",
    model: "loom-1",
    response_model: None,
    response_id: None,
    diagnostics: None,
    usage: demo_usage(tokens),
    stop_reason: stop,
    deferred: None,
    error_message: None,
    raw_stop_reason: None,
    end_turn: case stop {
      message.Stop -> Some(True)
      _ -> None
    },
    timestamp: 0,
  )
}

fn demo_usage(tokens: Int) -> message.Usage {
  message.Usage(
    input: 0,
    output: tokens,
    cache_read: 0,
    cache_write: 0,
    cache_write_1h: None,
    reasoning: None,
    total_tokens: tokens,
    cost: message.UsageCost(
      input: 0.0,
      output: 0.0,
      cache_read: 0.0,
      cache_write: 0.0,
      total: 0.0,
    ),
  )
}

fn scripted_tools() -> effects.ToolSurface {
  effects.ToolSurface(
    clear: fn(query: effects.ClearanceQuery) {
      effects.Cleared(
        effective_arguments: query.call.arguments,
        replay: operation.ReplaySafe,
      )
    },
    run: fn(run: effects.ToolRun) {
      effects.ToolCompleted(
        result: message.ToolResultMessage(
          tool_call_id: run.call.id,
          tool_name: run.call.name,
          content: [
            message.ToolResultText(
              text: "ok  \tloom/fetch\t0.31s",
              text_signature: None,
            ),
          ],
          details: None,
          usage: None,
          added_tool_names: None,
          is_error: False,
          timestamp: 0,
        ),
        terminate: False,
      )
    },
    replay_still_safe: fn(_name) { True },
    execution_mode: fn(_name) { effects.ConcurrentExecution },
  )
}

// The production wiring config the demo's compaction hooks are built
// from. Its provider gateway is routed for real — the summary role
// resolves, admission reports the route's window — but its transport is
// never reached: the effects record's provider surface is the scripted
// one above, so every request the demo makes is answered by the script
// and every *decision* about compaction is made by production code.
fn compaction_wiring(
  session: session.Session,
) -> Result(wiring.Config, String) {
  use summary_sink <- result.try(
    summaries.start()
    |> result.map_error(fn(_) { "the summary sink did not start" }),
  )
  use pack <- result.try(
    system_prompt.summary_pack(None)
    |> result.map(fn(loaded) { loaded.0 }),
  )
  use broker_actor <- result.try(
    broker.start(
      broker.BrokerConfig(
        entropy: token.production_entropy(),
        clock: clock.fixed(at: 0),
        checkout: fn() { Error(exec.AllBusy(size: 0)) },
        checkin: fn(_helper) { Nil },
      ),
    )
    |> result.map_error(fn(_) { "the demo broker did not start" }),
  )
  let workspace = "/nonexistent/loom-demo"
  Ok(wiring.Config(
    gateway: demo_gateway(),
    role: model.Main,
    // No catalogue in the demo: every identity takes the fallback
    // counts and the config's api, which is what they describe.
    facts: fn(_identity) { Error(Nil) },
    system: None,
    api: "demo",
    fallback_context_window: demo_context_window,
    fallback_max_output_tokens: 1_000_000,
    provider_timeout_ms: 4000,
    summary_role: model.Summarize,
    summary_pack: pack,
    summaries: summary_sink,
    session:,
    compaction: operation.CompactionSettings(
      enabled: True,
      reserve_tokens: 1,
      keep_recent_tokens: 1,
    ),
    broker: broker_actor,
    broker_timeout_ms: 1000,
    registry: serve.registry(None, None, None, None),
    workspace:,
    blob_root: workspace <> "/.blobs",
    base_policy: policy.workspace_default(workspace),
    escalations: escalate.none(),
    demand: exec.BestEffort,
    env: [],
    clock: clock.fixed(at: 0),
    entropy: fn() { 7 },
  ))
}

// Wide enough that the demo's scripted turns never cross the threshold:
// this flow compacts because the operator asked it to, over the
// protocol, which is the M3 acceptance criterion.
const demo_context_window = 1_000_000

// A routed gateway over a transport nothing dispatches through. The
// routing is what the hooks read — admission's window, the summary
// role's resolution — and the demo's provider surface is scripted, so
// the transport is never reached.
fn demo_gateway() -> provider_gateway.Gateway {
  let identity =
    model.ResolvedModel(
      provider: "acme",
      model_id: "loom-1",
      thinking: model.ThinkingOff,
      context_window: demo_context_window,
      max_output_tokens: 1_000_000,
    )
  provider_gateway.new(
    transport: http.Transport(send_streaming: fn(_request, _subject) { Nil }),
    secrets: secret.from_list([]),
    clock: clock.fixed(at: 0),
  )
  |> provider_gateway.add_provider(provider_gateway.AnthropicProvider(
    name: "acme",
    base_url: "https://acme.invalid",
    api_key_secret: "ACME_KEY",
  ))
  |> provider_gateway.route(model.Main, [identity])
  |> provider_gateway.route(model.Summarize, [identity])
}
