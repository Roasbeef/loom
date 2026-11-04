//// The project worker's commit scanner against a real session store and a
//// real project actor.
////
//// The session is a real in-memory one with a real runtime and writer, and the
//// project actor is the real one over a real ledger file. What the tests
//// commit to the worker's log is written straight onto its leaf, the way a
//// settlement commits an entry, because the claims are about what the scanner
//// does with entries in a log and not about how a model produced them. The
//// provider is never asked for anything.
////
//// The barrier in every test is the scan cursor in the project ledger. The
//// scanner sends its turns and reports, and then moves the cursor, and the
//// project actor takes messages from one sender in order. So once the cursor
//// names an entry, everything the scanner found at or below that entry has
//// been recorded, and a claim that something was not recorded can be checked
//// without waiting a guessed interval.

import client/daemon/project_host
import client/internal/ffi_os
import client/project_scan
import client/projectseam
import core/accounting
import core/clock
import core/entry
import core/ids.{type EntryId}
import core/json
import core/message.{type AgentMessage}
import core/register
import core/tx
import core/usage_evidence
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/static_supervisor as sup
import gleam/result
import gleam/string
import host/bootstrap
import machine/strand as machine_strand
import project/model
import provider/stream
import runtime/api
import runtime/effects
import runtime/writer
import session/session
import simplifile
import support/addresses
import support/project_ports
import tools/project as tools
import weft/actor
import weft/registry as address

// --- a person's turn --------------------------------------------------------

pub fn a_human_turn_is_recorded_once_across_a_scanner_restart_test() {
  let rig = rig("restart", Remembers)
  let first = commit(rig, 1, human("use sqlite"))
  poke(rig)
  await_cursor(rig, first)
  assert occurrences(rig, first) == 1

  // The scanner dies and is replaced. It starts from the cursor the ledger
  // holds, and a second turn after the restart is the next thing it records.
  restart_scanner(rig)
  let second = commit(rig, 2, human("and add an index"))
  poke(rig)
  await_cursor(rig, second)
  assert occurrences(rig, first) == 1
  assert occurrences(rig, second) == 1
  stop(rig)
}

pub fn a_scanner_that_lost_its_checkpoint_records_each_turn_once_test() {
  // This feed forgets where it was, so the replacement reads the whole log
  // again and sends the first turn a second time. Only the entry-keyed
  // trigger keeps it from being recorded twice.
  let rig = rig("forgetful", Forgets)
  let first = commit(rig, 1, human("use sqlite"))
  poke(rig)
  await_cursor(rig, first)
  restart_scanner(rig)
  let second = commit(rig, 2, human("and add an index"))
  poke(rig)
  await_cursor(rig, second)
  assert occurrences(rig, first) == 1
  assert occurrences(rig, second) == 1
  stop(rig)
}

pub fn the_projects_own_deliveries_are_not_taken_for_a_person_test() {
  let rig = rig("origins", Remembers)

  // The project's delivery, a peer's message, another strand's and a message
  // with no origin at all. None of them is the owner stepping in.
  let delivered =
    commit(
      rig,
      1,
      from(message.TriggerOrigin("composer", "a", "owner"), "fix a"),
    )
  let peer = commit(rig, 2, from(message.PeerOrigin("s-2", "main"), "hello"))
  let strand = commit(rig, 3, from(message.StrandOrigin("sub:main/x"), "note"))
  let bare = commit(rig, 4, user("no origin"))
  let person = commit(rig, 5, human("a real turn"))
  poke(rig)
  await_cursor(rig, person)
  assert occurrences(rig, person) == 1
  assert occurrences(rig, delivered) == 0
  assert occurrences(rig, peer) == 0
  assert occurrences(rig, strand) == 0
  assert occurrences(rig, bare) == 0
  stop(rig)
}

// --- a report the actor missed -----------------------------------------------

pub fn a_committed_report_the_actor_never_heard_is_replayed_test() {
  // The scanner forgets its checkpoint, so each incarnation reads the log
  // from the start and sees the report again.
  let rig = rig("report", Forgets)

  // The log holds a waiting report with a question, and the actor was never
  // told: no `project_host.report` call was made.
  assert !string.contains(card(rig), "which database?")
  let _call =
    commit(rig, 1, report_call("call-1", "waiting", Some("which database?")))
  let result = commit(rig, 2, report_result("call-1", tools_ok()))
  poke(rig)
  await_cursor(rig, result)
  let replayed = card(rig)
  assert string.contains(replayed, "which database?")
  assert string.contains(replayed, "person/answer")

  // Reading the log again does not ask the question a second time. The card
  // carries the question's number, which would change.
  restart_scanner(rig)
  let marker = commit(rig, 3, human("noted"))
  poke(rig)
  await_cursor(rig, marker)
  assert card(rig) == replayed
  stop(rig)
}

pub fn a_failed_report_call_is_not_replayed_test() {
  let rig = rig("failed-report", Remembers)
  let _call = commit(rig, 1, report_call("call-1", "blocked", None))
  let result = commit(rig, 2, report_result("call-1", tools_failed()))
  poke(rig)
  await_cursor(rig, result)
  assert !string.contains(card(rig), "person/blocked")
  stop(rig)
}

// --- the rig ------------------------------------------------------------------

type Memory {
  Remembers
  Forgets
}

type Rig {
  Rig(
    runtime: api.Runtime,
    session: session.Session,
    scanner: address.Address(writer.Event),
    services: process.Pid,
    handle: project_host.Handle,
    worker: String,
    memory: Memory,
  )
}

fn rig(name: String, memory: Memory) -> Rig {
  let directory =
    "build/project-scan-"
    <> name
    <> "-"
    <> int.to_string(ffi_os.unique_positive_integer())
  let _removed = simplifile.delete(directory)
  let assert Ok(Nil) = bootstrap.ensure_private_directory("build")
    as "the build directory exists"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
    as "the scratch directory is made"
  let handle = host(directory)

  // One ticket with one worker, bound to a session id the host chose.
  let assert Ok(_) = project_host.post(handle, "a", "fix a") as "the post lands"
  let assert Ok([tools.Applied]) = project_host.route(handle, [accept("a")])
    as "the router accepts it"
  let worker = "session-project:p1:t-a:1"
  let assert Ok(opened) =
    session.open_memory(clock.stepping(from: 1_756_000_000_000, by: 3))
    as "the memory session opens"
  let assert Ok(entropy) = start_entropy() as "the entropy counter starts"
  let effects_record =
    effects.Effects(
      clock: clock.stepping(from: 1_756_000_000_000, by: 3),
      entropy:,
      timers: effects.real_timers(),
      provider: idle_provider(),
      tools: refusing_tools(),
      hooks: effects.default_hooks(),
    )
  let scanner = addresses.new()
  let options = api.default_options(strand_configuration())
  let assert Ok(runtime) =
    api.open(
      opened,
      effects_record,
      api.Options(
        ..options,
        poll_interval_ms: 20,
        idle_poll_interval_ms: 20,
        subscribers: [writer.Routed(scanner)],
      ),
    )
    as "the runtime opens"
  let assert Ok(services) = supervise(handle, worker, memory, runtime, scanner)
    as "the scanner starts"
  Rig(
    runtime:,
    session: opened,
    scanner:,
    services: services,
    handle:,
    worker:,
    memory:,
  )
}

// The project actor over a real ledger, with fake ports. The worker is never
// delivered to in these tests, so the endpoints accept and forget.
fn host(directory: String) -> project_host.Handle {
  let ports = project_ports.inert()
  let assert Ok(handle) =
    project_host.start(
      project_host.Config(
        project: "p1",
        workspace: "/work/repo",
        router_session: "router-1",
        ledger_path: directory <> "/ledger.db",
        max_workers: 2,
        tick_ms: 3_600_000,
        router_turn_ms: 3_600_000,
        policy: project_host.idle_policy,
        ports: fn() { ports },
      ),
    )
    as "the project actor starts"
  handle
}

// The scanner under a supervisor, unlinked from the test so that killing it
// kills a supervised child and not something the test is linked to.
fn supervise(
  handle: project_host.Handle,
  worker: String,
  memory: Memory,
  runtime: api.Runtime,
  scanner: address.Address(writer.Event),
) -> Result(process.Pid, String) {
  let real = projectseam.feed(handle, worker)
  let feed = case memory {
    Remembers -> real
    Forgets -> project_scan.Feed(..real, cursor: fn() { Ok(None) })
  }
  use services <- result.try(
    sup.new(sup.OneForOne)
    |> sup.add(project_scan.supervised(
      project_scan.default_options(feed),
      runtime,
      scanner,
    ))
    |> sup.start
    |> result.replace_error("the scanner supervisor did not start"),
  )
  process.unlink(services.pid)
  await_named(scanner, 2000)
  Ok(services.pid)
}

fn stop(rig: Rig) -> Nil {
  process.kill(rig.services)
  process.kill(rig.runtime.tree.supervisor)
}

fn restart_scanner(rig: Rig) -> Nil {
  let assert Ok(pid) = addresses.owner(rig.scanner)
    as "the scanner must be live"
  process.kill(pid)
  await_replacement(rig.scanner, pid, 5000)
}

// A hint with nothing behind it: the scanner pulls its truth from the store.
fn poke(rig: Rig) -> Nil {
  let _sent =
    address.send(rig.scanner, writer.Committed(ordinal: 0, seqs: [], ts: 0))
  Nil
}

// --- what the project actor holds ---------------------------------------------

// How many times the thread of ticket `a` names the trigger made from an
// entry, which is the number of turns recorded for it.
fn occurrences(rig: Rig, id: EntryId) -> Int {
  let trigger = "h-" <> ids.entry_id_to_string(id)
  let assert Ok(thread) =
    project_host.read(rig.handle, tools.ThreadCard(model.ThreadId("a")))
    as "the thread reads"
  list.length(string.split(json.to_string(thread), trigger)) - 1
}

fn card(rig: Rig) -> String {
  let assert Ok(found) =
    project_host.read(rig.handle, tools.TicketCard(model.TicketId("t-a")))
    as "the ticket reads"
  json.to_string(found)
}

// Waits until the ledger's cursor for the worker is the entry. The scanner moves
// it last, so what it found at or below the entry is already recorded.
fn await_cursor(rig: Rig, id: EntryId) -> Nil {
  await_cursor_for(rig, ids.entry_id_to_string(id), 5000)
}

fn await_cursor_for(rig: Rig, wanted: String, remaining_ms: Int) -> Nil {
  let held = project_host.scan_cursor(rig.handle, rig.worker)
  case held == Ok(Some(wanted)), remaining_ms <= 0 {
    True, _ | _, True -> {
      assert held == Ok(Some(wanted))
      Nil
    }
    False, False -> {
      process.sleep(10)
      await_cursor_for(rig, wanted, remaining_ms - 10)
    }
  }
}

fn accept(trigger: String) -> tools.Item {
  tools.Item(
    trigger: model.TriggerId(trigger),
    action: tools.Accept(model.title("work on " <> trigger)),
    holds: [],
    related: [],
    prior_hand_back: None,
  )
}

// --- the worker's log -----------------------------------------------------------

// Commits one message onto the main strand's leaf, the way a settlement does:
// the entry and the leaf move together under the leaf's own seq. `seed`
// distinguishes the ids of two commits in one test.
fn commit(rig: Rig, seed: Int, held: AgentMessage) -> EntryId {
  let assert Ok(leaf_cell) = session.strand_leaf(rig.session, "main")
    as "the leaf register reads"
  let assert Some(session.Cell(seq: leaf_seq, value: leaf)) = leaf_cell
    as "the strand has a leaf register"
  let #(id, _next) =
    ids.mint_entry(ids.generator(
      clock.fixed(at: 1_756_000_900_000 + seed),
      seed:,
    ))
  let commit =
    tx.Tx(
      writes: [
        tx.InsertEntry(entry: entry.MessageEntry(
          id:,
          parent: leaf,
          seq: 0,
          ts: 0,
          message: held,
          terminate: False,
        )),
        tx.SetRegister(
          ns: register.StrandLeaf,
          key: "main",
          value: register.leaf_value(Some(id)),
        ),
      ],
      expected: [
        tx.Expect(ns: register.StrandLeaf, key: "main", seq: Some(leaf_seq)),
      ],
    )
  let assert Ok(_) = writer.commit(rig.runtime.tree.writer, commit)
    as "the entry commits"
  id
}

fn user(text: String) -> AgentMessage {
  from_origin(None, text)
}

fn human(text: String) -> AgentMessage {
  from(message.Origin("owner", "Owner"), text)
}

fn from(origin: message.Origin, text: String) -> AgentMessage {
  from_origin(Some(origin), text)
}

fn from_origin(origin: Option(message.Origin), text: String) -> AgentMessage {
  message.UserMessage(
    content: [message.UserText(text:, text_signature: None)],
    timestamp: 0,
    origin:,
  )
}

// An assistant message that calls `project_report`.
fn report_call(
  id: String,
  status: String,
  question: Option(String),
) -> AgentMessage {
  let arguments =
    json.Object([
      #("status", json.String(status)),
      ..case question {
        Some(text) -> [#("question", json.String(text))]
        None -> []
      }
    ])
  message.AssistantMessage(
    content: [
      message.AssistantToolCall(message.ToolCall(
        id:,
        name: tools.report_tool_name,
        arguments:,
        thought_signature: None,
        namespace: None,
      )),
    ],
    api: "anthropic",
    provider: "acme",
    model: "loom-1",
    response_model: None,
    response_id: None,
    diagnostics: None,
    usage: accounting.unknown_usage(usage_evidence.Other),
    stop_reason: message.ToolUse,
    deferred: None,
    error_message: None,
    raw_stop_reason: None,
    end_turn: None,
    timestamp: 0,
  )
}

type Outcome {
  Succeeded
  Refused
}

fn tools_ok() -> Outcome {
  Succeeded
}

fn tools_failed() -> Outcome {
  Refused
}

fn report_result(call: String, outcome: Outcome) -> AgentMessage {
  message.ToolResultMessage(
    tool_call_id: call,
    tool_name: tools.report_tool_name,
    content: [message.ToolResultText(text: "recorded.", text_signature: None)],
    details: None,
    usage: None,
    added_tool_names: None,
    is_error: case outcome {
      Succeeded -> False
      Refused -> True
    },
    timestamp: 0,
  )
}

// --- the runtime's inert parts -----------------------------------------------------

fn strand_configuration() -> machine_strand.StrandConfiguration {
  machine_strand.StrandConfiguration(
    model: machine_strand.ModelIdentity(provider: "acme", model_id: "loom-1"),
    thinking_level: machine_strand.ThinkingOff,
    active_tool_names: [],
  )
}

// A provider no test asks anything of. It answers every request with a short
// settled message so that an unexpected request would still end cleanly.
fn idle_provider() -> effects.ProviderSurface {
  effects.ProviderSurface(timeout_ms: 30_000, request: fn(_spec) {
    let events: Subject(stream.StreamEvent) = process.new_subject()
    case stream.settle(settled_answer()) {
      Ok(settled) ->
        process.send(
          events,
          stream.Settled(
            message: settled,
            accounting: accounting.from_usage(accounting.unknown_usage(
              usage_evidence.Other,
            )),
          ),
        )
      Error(Nil) -> Nil
    }
    stream.immediate(events:, cancel: fn() { Nil })
  })
}

fn settled_answer() -> AgentMessage {
  message.AssistantMessage(
    content: [message.AssistantText(text: "unused", text_signature: None)],
    api: "anthropic",
    provider: "acme",
    model: "loom-1",
    response_model: None,
    response_id: None,
    diagnostics: None,
    usage: accounting.unknown_usage(usage_evidence.Other),
    stop_reason: message.Stop,
    deferred: None,
    error_message: None,
    raw_stop_reason: None,
    end_turn: None,
    timestamp: 0,
  )
}

fn refusing_tools() -> effects.ToolSurface {
  effects.ToolSurface(
    clear: fn(_query) {
      effects.ClearanceRefused(reason: "no tools in this harness")
    },
    run: fn(_run) { effects.ToolFailed(reason: "no tools in this harness") },
    replay_still_safe: fn(_name) { False },
    execution_mode: fn(_name) { effects.ExclusiveExecution },
    recover: None,
  )
}

fn start_entropy() -> Result(fn() -> Int, String) {
  actor.new(1)
  |> actor.on_message(fn(next, reply: Subject(Int)) {
    process.send(reply, next)
    actor.continue(next + 1)
  })
  |> actor.start
  |> result.map(fn(counter) {
    fn() { process.call(counter.data, waiting: 1000, sending: fn(r) { r }) }
  })
  |> result.replace_error("the entropy counter did not start")
}

// --- waiting on the supervisor ------------------------------------------------------

fn await_named(name: address.Address(writer.Event), remaining_ms: Int) -> Nil {
  case addresses.owner(name), remaining_ms <= 0 {
    Ok(_pid), _ | _, True -> Nil
    Error(Nil), False -> {
      process.sleep(5)
      await_named(name, remaining_ms - 5)
    }
  }
}

// Waits until the name resolves to a different process: the supervisor's
// replacement, not the corpse.
fn await_replacement(
  name: address.Address(writer.Event),
  gone: process.Pid,
  remaining_ms: Int,
) -> Nil {
  case addresses.owner(name), remaining_ms <= 0 {
    _, True -> Nil
    Ok(pid), False ->
      case pid == gone {
        False -> Nil
        True -> {
          process.sleep(5)
          await_replacement(name, gone, remaining_ms - 5)
        }
      }
    Error(Nil), False -> {
      process.sleep(5)
      await_replacement(name, gone, remaining_ms - 5)
    }
  }
}
