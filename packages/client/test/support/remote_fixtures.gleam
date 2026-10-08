//// Fixtures for the remote tool-call tests: a fake workspace plane whose tool
//// counts its runs and can be held open, plus the small builders every test
//// in the family needs.
////
//// The plane is the one thing the host leaves to its integration, so a fake
//// one lets the host, the surface and the owner port be proved in one VM or
//// across two real nodes without a broker, a jail or a checkout. The fake
//// tool records each run in a `Probe`, so a test can count how many times a
//// call actually ran, which is the number the whole protocol exists to keep
//// at one.

import broker/escalation
import client/escalate
import client/internal/ffi_os
import client/owner_services.{type OwnerServices, OwnerServices}
import client/remote/host
import client/remote/protocol
import client/wiring
import codemode/vet/policy as vet_policy
import core/clock
import core/ids
import core/json
import core/message
import core/msgpack
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/otp/actor
import machine/operation
import runtime/effects.{type ToolOutcome, type ToolRun}
import simplifile
import storage/exec_ledger
import tools/agent
import tools/directory_access

/// Whether the fake tool finishes at once or waits to be released.
pub type Gate {
  Open
  Held
}

/// What the fake tool does when it asks its owner for a decision.
pub type Asks {
  AsksNothing
  AsksOwner
}

/// The record of what the fake plane did.
pub type Probe {
  Probe(subject: Subject(ProbeMessage))
}

pub type ProbeMessage {
  Ran(pid: Pid, call: String)
  Wait(reply: Subject(Nil))
  Release
  Runs(reply: Subject(List(#(Pid, String))))
  Built(owner: OwnerServices)
  Builds(reply: Subject(List(OwnerServices)))
  Closed
  Closes(reply: Subject(Int))
}

type ProbeState {
  ProbeState(
    runs: List(#(Pid, String)),
    waiters: List(Subject(Nil)),
    released: Bool,
    builds: List(OwnerServices),
    closes: Int,
  )
}

/// Starts a probe. A held gate blocks every fake tool until `release`.
pub fn probe(gate: Gate) -> Probe {
  let assert Ok(started) = probe_builder(gate) |> actor.start
    as "the probe starts"
  Probe(subject: started.data)
}

/// Starts a probe that other nodes can reach by a registered name, which is how
/// an orchestrator asks an executor how many times its fake tool ran.
pub fn named_probe(gate: Gate, name: process.Name(ProbeMessage)) -> Probe {
  let assert Ok(started) =
    probe_builder(gate) |> actor.named(name) |> actor.start
    as "the named probe starts"
  Probe(subject: started.data)
}

fn probe_builder(
  gate: Gate,
) -> actor.Builder(ProbeState, ProbeMessage, Subject(ProbeMessage)) {
  let released = case gate {
    Open -> True
    Held -> False
  }
  let state =
    ProbeState(runs: [], waiters: [], released:, builds: [], closes: 0)
  actor.new(state) |> actor.on_message(probe_loop)
}

fn probe_loop(
  state: ProbeState,
  message: ProbeMessage,
) -> actor.Next(ProbeState, ProbeMessage) {
  case message {
    Ran(pid:, call:) ->
      actor.continue(
        ProbeState(..state, runs: list.append(state.runs, [#(pid, call)])),
      )
    Wait(reply:) ->
      case state.released {
        True -> {
          process.send(reply, Nil)
          actor.continue(state)
        }
        False ->
          actor.continue(ProbeState(..state, waiters: [reply, ..state.waiters]))
      }
    Release -> {
      list.each(state.waiters, fn(waiter) { process.send(waiter, Nil) })
      actor.continue(ProbeState(..state, waiters: [], released: True))
    }
    Runs(reply:) -> {
      process.send(reply, state.runs)
      actor.continue(state)
    }
    Built(owner:) ->
      actor.continue(
        ProbeState(..state, builds: list.append(state.builds, [owner])),
      )
    Builds(reply:) -> {
      process.send(reply, state.builds)
      actor.continue(state)
    }
    Closed -> actor.continue(ProbeState(..state, closes: state.closes + 1))
    Closes(reply:) -> {
      process.send(reply, state.closes)
      actor.continue(state)
    }
  }
}

/// Lets every held tool, and every later one, finish.
pub fn release(probe: Probe) -> Nil {
  process.send(probe.subject, Release)
}

/// Every run the fake tool began, in order, with the process that ran it.
pub fn runs(probe: Probe) -> List(#(Pid, String)) {
  process.call(probe.subject, 1000, Runs)
}

/// How many times the fake tool began running the named call.
pub fn run_count(probe: Probe, call: String) -> Int {
  runs(probe)
  |> list.filter(fn(entry) { entry.1 == call })
  |> list.length
}

/// The owner services each plane build was given, oldest first.
pub fn builds(probe: Probe) -> List(OwnerServices) {
  process.call(probe.subject, 1000, Builds)
}

/// How many times a plane's `close` ran.
pub fn closes(probe: Probe) -> Int {
  process.call(probe.subject, 1000, Closes)
}

/// Polls `check` until it holds, up to two seconds, so a test waits for an
/// asynchronous fact without a fixed sleep.
pub fn eventually(check: fn() -> Bool) -> Bool {
  eventually_loop(check, 200)
}

fn eventually_loop(check: fn() -> Bool, attempts_left: Int) -> Bool {
  case check(), attempts_left {
    True, _ -> True
    False, 0 -> False
    False, _ -> {
      process.sleep(10)
      eventually_loop(check, attempts_left - 1)
    }
  }
}

/// A plane factory whose plane runs the fake tool.
///
/// The tool records its run, optionally asks its owner to decide a refusal
/// (and treats a `Settle` as part of its normal result), waits on the gate, and
/// completes with the text of its call id. `close_outcome` is what the plane's
/// `close` reports.
pub fn factory(
  probe: Probe,
  asks: Asks,
  close_outcome: protocol.CloseOutcome,
) -> host.PlaneFactory(String) {
  fn(spec: host.AttachSpec) {
    process.send(probe.subject, Built(owner: spec.owner))
    Ok(
      host.Plane(
        run: fn(run, _authority) { fake_tool(probe, spec.owner, asks, run) },
        census: "census-" <> int.to_string(spec.incarnation),
        close: fn() {
          process.send(probe.subject, Closed)
          close_outcome
        },
      ),
    )
  }
}

fn fake_tool(
  probe: Probe,
  owner: OwnerServices,
  asks: Asks,
  run: ToolRun,
) -> ToolOutcome {
  process.send(probe.subject, Ran(pid: process.self(), call: run.call.id))
  let verdict = case asks {
    AsksNothing -> "ran"
    AsksOwner ->
      case owner.escalate(refused_for(run)) {
        escalate.Settle -> "settled"
        escalate.Resume(..) -> "resumed"
      }
  }
  process.call(probe.subject, 30_000, Wait)
  effects.ToolCompleted(result: text_result(run, verdict), terminate: False)
}

fn refused_for(run: ToolRun) -> escalate.Refused {
  escalate.Refused(
    operation: run.operation,
    strand: run.strand,
    step_id: run.step_id,
    source_index: run.source_index,
    call_id: run.call.id,
    tool: run.call.name,
    denial: denial(),
    arguments: run.arguments,
    deadline_ms: 60_000,
  )
}

/// A policy denial for a refusal that asks for nothing in particular.
pub fn denial() -> escalation.Denial {
  escalation.Denial(
    reason: "the fake tool wants more",
    source: escalation.PolicyDenial,
    wanted: [],
  )
}

/// The result message the fake tool completes with.
pub fn text_result(run: ToolRun, text: String) -> message.AgentMessage {
  message.ToolResultMessage(
    tool_call_id: run.call.id,
    tool_name: run.call.name,
    content: [message.ToolResultText(text:, text_signature: None)],
    details: None,
    usage: None,
    added_tool_names: None,
    is_error: False,
    timestamp: 0,
  )
}

/// The outcome the fake tool completes with for `run` when it asked nothing.
pub fn expected_outcome(run: ToolRun) -> ToolOutcome {
  effects.ToolCompleted(result: text_result(run, "ran"), terminate: False)
}

/// A bash-shaped tool call with the given call id and source index.
pub fn tool_run(call_id: String, source_index: Int) -> ToolRun {
  let #(operation, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 1))
  let arguments = json.Object([#("command", json.String("true"))])
  effects.ToolRun(
    operation:,
    step_id: "turn-1:tools",
    source_index:,
    strand: "main",
    call: message.ToolCall(
      id: call_id,
      name: "bash",
      arguments:,
      thought_signature: None,
      namespace: None,
    ),
    arguments:,
    replay: operation.ReplayNever,
    grants: [],
  )
}

/// An authority with nothing granted.
pub fn authority() -> wiring.Authority {
  wiring.Authority(
    access: directory_access.Access(readable: [], writable: []),
    standing: [],
  )
}

/// A fresh scratch directory under the package's build directory.
pub fn scratch(name: String) -> String {
  let directory =
    "build/remote-"
    <> name
    <> "-"
    <> int.to_string(ffi_os.unique_positive_integer())

  // The counter restarts with every emulator, so a name can repeat across runs
  // and must not find the last run's ledger in it.
  let _removed = simplifile.delete(directory)
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
    as "the scratch directory is created"
  directory
}

/// A host configuration over a ledger at `path`, for a fresh private name.
pub fn host_config(
  path: String,
  factory: host.PlaneFactory(String),
) -> host.Config(String) {
  host.Config(
    name: process.new_name("remote_test_host"),
    ledger_path: path,
    limits: exec_ledger.default_limits(),
    max_result_bytes: 65_536,
    clock: clock.fixed(at: 1000),
    factory:,
  )
}

/// Owner services that serve nothing: every call answers its in-band default.
/// A test replaces the fields it cares about.
pub fn quiet_services() -> OwnerServices {
  OwnerServices(
    escalate: fn(_refused) { escalate.Settle },
    facts: owner_services.FactAccess(
      cell: fn(_key) { Ok(None) },
      put: fn(_key, _value, _expected) { Ok(0) },
      put_blind: fn(_key, _value) { Ok(Nil) },
      delete: fn(_key) { Ok(Nil) },
      list: fn(_prefix) { Ok([]) },
    ),
    output: fn(_run) { fn(_tail) { Nil } },
    capability: owner_services.no_capability,
    holds: fn(_caller, _tool) { Error(agent.AgencyUnavailable) },
    notify: fn(_strand, _work, _text) { Error("quiet") },
    strand_activity: fn(_strand) { Error("quiet") },
    wake: fn(_strand, _text) { Error("quiet") },
  )
}

/// A code-mode capability call for the owner to answer.
pub fn capability_call() -> owner_services.OwnerCapCall {
  let #(operation, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 1))
  owner_services.OwnerCapCall(
    strand: "main",
    op_id: operation,
    step_id: "turn-1:tools",
    source_index: 0,
    seam: vet_policy.WorkspaceSeam,
    cap: "strand.spawn",
    args: msgpack.NilValue,
    ordinal: 0,
  )
}

/// A set of call keys a test fills in as facts become true, read from other
/// processes.
pub type Marks {
  Marks(subject: Subject(MarksMessage))
}

pub type MarksMessage {
  Mark(key: protocol.Key)
  Marked(key: protocol.Key, reply: Subject(Bool))
  All(reply: Subject(List(protocol.Key)))
}

/// Starts an empty set of marks.
pub fn marks() -> Marks {
  let assert Ok(started) =
    actor.new([])
    |> actor.on_message(fn(keys: List(protocol.Key), message) {
      case message {
        Mark(key:) -> actor.continue([key, ..keys])
        Marked(key:, reply:) -> {
          process.send(reply, list.contains(keys, key))
          actor.continue(keys)
        }
        All(reply:) -> {
          process.send(reply, list.reverse(keys))
          actor.continue(keys)
        }
      }
    })
    |> actor.start
    as "the marks start"
  Marks(subject: started.data)
}

/// Adds a key.
pub fn mark(marks: Marks, key: protocol.Key) -> Nil {
  process.send(marks.subject, Mark(key:))
}

/// Whether the key was marked.
pub fn is_marked(marks: Marks, key: protocol.Key) -> Bool {
  process.call(marks.subject, 1000, Marked(key, _))
}

/// Every marked key, oldest first.
pub fn marked(marks: Marks) -> List(protocol.Key) {
  process.call(marks.subject, 1000, All)
}

/// A call to a tool that runs on the orchestrator, not the executor.
pub fn local_call(call_id: String) -> message.ToolCall {
  message.ToolCall(
    id: call_id,
    name: "agent_spawn",
    arguments: json.Null,
    thought_signature: None,
    namespace: None,
  )
}
