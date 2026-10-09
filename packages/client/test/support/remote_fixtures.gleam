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
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/string
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
  HoldBuild(session: String)
  ReleaseBuild(session: String)
  BuildGate(session: String, reply: Subject(Nil))
  Aborted(op: String, step: String)
  Aborts(reply: Subject(List(#(String, String))))
}

type ProbeState {
  ProbeState(
    runs: List(#(Pid, String)),
    waiters: List(Subject(Nil)),
    released: Bool,
    builds: List(OwnerServices),
    closes: Int,
    held_builds: List(String),
    build_waiters: List(#(String, Subject(Nil))),
    aborts: List(#(String, String)),
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
    ProbeState(
      runs: [],
      waiters: [],
      released:,
      builds: [],
      closes: 0,
      held_builds: [],
      build_waiters: [],
      aborts: [],
    )
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
    HoldBuild(session:) ->
      actor.continue(
        ProbeState(..state, held_builds: [session, ..state.held_builds]),
      )
    ReleaseBuild(session:) -> {
      let #(released, kept) =
        list.partition(state.build_waiters, fn(entry) { entry.0 == session })
      list.each(released, fn(entry) { process.send(entry.1, Nil) })
      actor.continue(
        ProbeState(
          ..state,
          held_builds: list.filter(state.held_builds, fn(held) {
            held != session
          }),
          build_waiters: kept,
        ),
      )
    }
    Aborted(op:, step:) ->
      actor.continue(
        ProbeState(..state, aborts: list.append(state.aborts, [#(op, step)])),
      )
    Aborts(reply:) -> {
      process.send(reply, state.aborts)
      actor.continue(state)
    }
    BuildGate(session:, reply:) ->
      case list.contains(state.held_builds, session) {
        True ->
          actor.continue(
            ProbeState(..state, build_waiters: [
              #(session, reply),
              ..state.build_waiters
            ]),
          )
        False -> {
          process.send(reply, Nil)
          actor.continue(state)
        }
      }
  }
}

/// Makes the fake factory wait, when it builds a plane for `session`, until
/// `release_build`. Other sessions build at once.
pub fn hold_build(probe: Probe, session: String) -> Nil {
  process.send(probe.subject, HoldBuild(session:))
}

/// Lets the held build for `session` finish.
pub fn release_build(probe: Probe, session: String) -> Nil {
  process.send(probe.subject, ReleaseBuild(session:))
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

/// Every broker step the plane was told to abort, oldest first, as
/// `#(operation, step)`.
pub fn aborts(probe: Probe) -> List(#(String, String)) {
  process.call(probe.subject, 1000, Aborts)
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
    process.call(probe.subject, 30_000, BuildGate(spec.session, _))
    Ok(
      host.Plane(
        run: fn(run, _authority) { fake_tool(probe, spec.owner, asks, run) },
        execute: fn(start) { fake_program(probe, start) },
        abort_step: fn(op, step) {
          process.send(probe.subject, Aborted(op, step))
        },
        census: "census-" <> int.to_string(spec.incarnation),
        children: fn(builder) { builder },
        close: fn(retire_children) {
          process.send(probe.subject, Closed)
          let _retired = retire_children()
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
  case run.call.id {
    "duplicate-keys" -> duplicate_key_outcome(run)
    _ ->
      effects.ToolCompleted(result: text_result(run, verdict), terminate: False)
  }
}

/// The outcome the fake tool completes with for a call whose id is
/// `duplicate-keys`: its details hold one key twice. It encodes, and the bytes
/// do not parse back, because `core/json` refuses a duplicated key.
pub fn duplicate_key_outcome(run: ToolRun) -> ToolOutcome {
  effects.ToolCompleted(
    result: message.ToolResultMessage(
      tool_call_id: run.call.id,
      tool_name: run.call.name,
      content: [message.ToolResultText(text: "ran", text_signature: None)],
      details: Some(json.Object([#("k", json.Int(1)), #("k", json.Int(2))])),
      usage: None,
      added_tool_names: None,
      is_error: False,
      timestamp: 0,
    ),
    terminate: False,
  )
}

// The fake background program: it records its run under its step, waits on the
// gate like the fake tool, and ends with a value that names its step and the
// time it was given.
// A program whose source is `big` adds a field large enough to pass any
// reservation a test sets, so the replacement of an oversized value is
// reachable.
fn fake_program(probe: Probe, start: host.ExecutionStart) -> json.JsonValue {
  process.send(probe.subject, Ran(pid: process.self(), call: start.step))
  process.call(probe.subject, 30_000, Wait)
  case start.terms.source, expected_value(start.step, start.remaining_ms) {
    "big", json.Object(fields) ->
      json.Object([#("pad", json.String(string.repeat("x", 4096))), ..fields])
    _, value -> value
  }
}

/// The value the fake program ends with.
pub fn expected_value(step: String, remaining_ms: Int) -> json.JsonValue {
  json.Object([
    #("ran", json.String(step)),
    #("remaining_ms", json.Int(remaining_ms)),
  ])
}

/// What a launching call captured, for an execution test.
pub fn execution_terms() -> owner_services.ExecutionTerms {
  let #(operation, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 1))
  owner_services.ExecutionTerms(
    strand: "main",
    op_id: operation,
    launch_step: "turn-1:tools",
    source_index: 0,
    source: "pub fn main() { Nil }",
    seam: "workspace",
    within_ms: 60_000,
    access: directory_access.Access(readable: [], writable: []),
    grants: [],
  )
}

/// The handle a launch with these terms is given: the digest of the launching
/// call's coordinates.
pub fn handle_of(terms: owner_services.ExecutionTerms) -> String {
  agent.call_site_digest(agent.Caller(
    strand: terms.strand,
    operation: terms.op_id,
    step_id: terms.launch_step,
    source_index: terms.source_index,
    minter: agent.ToolCall,
  ))
}

/// The ledger key of the execution `id` of `session`, under the operation
/// `execution_terms` uses.
pub fn execution_key(session: String, id: String) -> protocol.Key {
  protocol.execution_key(session, execution_terms().op_id, id)
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
    execution_result_bytes: 4096,
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
    launch_execution: owner_services.no_launch,
    interact_execution: owner_services.no_interaction,
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
