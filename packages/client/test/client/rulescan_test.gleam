//// The triggered-rule scanner against a real runtime: what a dormant
//// rule costs a context (nothing, byte for byte), what a fired one adds
//// (one injection, once), what an idle strand does with a fire it
//// cannot admit, and what a restarted scanner does with a rule that has
//// already fired.
////
//// Every assertion here is made on the **projected context** — the
//// message list a provider request is actually built from — rather than
//// on the scanner's own bookkeeping. That is the claim design §8 makes
//// and the only one worth testing: a rule nobody triggered must not
//// cost a single byte of the model's window.
////
//// The provider is scripted and the session is in memory, but the
//// runtime, the writer, the queue admission and the projection are all
//// the real ones. The one piece of stage machinery is the gate: from
//// the second turn on, the scripted provider waits for the rule's
//// durable fired-mark before it answers. That removes the only race in
//// the scenario — whether the scanner's steer is durably queued before
//// the checkpoint that would drain it — without touching any of the
//// code under test.

import client/rules
import client/rulescan
import client/summaries
import client/wiring
import core/clock
import core/entry
import core/ids
import core/json
import core/message.{type AgentMessage}
import core/register
import core/tx
import gleam/erlang/process.{type Name, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor as sup
import gleam/result
import gleam/string
import machine/strand as machine_strand
import provider/stream
import runtime/api
import runtime/effects
import runtime/lineage
import runtime/writer
import session/session
import storage/storage

const trigger = "ALTER TABLE"

const body = "Run the schema gate before proposing a migration."

fn schema_gate() -> rules.Rule {
  rules.Rule(name: "schema-gate", triggers: [trigger], body:)
}

// --- zero cost when dormant (design §8, both directions) -------------------

// The dormant direction. A rule is configured, the scanner is running
// and has seen every commit, and the model said nothing that trips it:
// the rule's text is nowhere in the context the next request would be
// built from. Not "cheap" — absent.
pub fn a_dormant_rule_costs_the_context_nothing_test() {
  let assert Ok(rig) = harness([schema_gate()], answers_without_the_trigger())
    as "the harness must boot"
  let assert Ok(op) = api.prompt(rig.runtime, [user("say something harmless")])
    as "the prompt must be accepted"
  let assert Ok(_outcome) = api.await_result(rig.runtime, op, within_ms: 10_000)
    as "the run must complete"
  let context = rendered(rig.session)
  assert occurrences(context, body) == 0
  assert occurrences(context, "triggered project rule") == 0
  // …and nothing durable was spent either: no mark, so the rule is still
  // armed for the moment it becomes relevant.
  assert fact(rig.session, fired_key()) == None
  stop(rig)
}

// The fired direction, and the same measurement: exactly one copy of the
// rule's text, in a context the model will actually receive.
pub fn a_fired_rule_appears_in_the_context_exactly_once_test() {
  let assert Ok(rig) = harness([schema_gate()], answers_with_the_trigger())
    as "the harness must boot"
  let assert Ok(entry_text) = run_until_fired(rig)
    as "the rule must fire and reach the context"
  assert occurrences(entry_text, body) == 1
  // The injection says what it is. A model that reads it as a turn from
  // the person at the keyboard is a model steerable by whoever chose the
  // trigger string, which is the whole reason for the framing.
  assert string.contains(entry_text, "triggered project rule \"schema-gate\"")
  assert string.contains(entry_text, "not a turn from the user")
  assert string.contains(
    entry_text,
    "--- begin project rule \"schema-gate\" ---",
  )
  assert fact(rig.session, fired_key()) == Some(json.String("schema-gate"))
  stop(rig)
}

// --- exactly once ----------------------------------------------------------

// The flood row: a trigger that matches *every* assistant message. The
// scanner sees each of them and the rule still lands once, because the
// write-once mark is what decides, not the match.
pub fn a_trigger_matching_every_message_injects_once_test() {
  let assert Ok(rig) = harness([schema_gate()], answers_with_the_trigger())
    as "the harness must boot"
  let assert Ok(_first) = run_until_fired(rig) as "the rule must fire"
  // Two more runs, every turn of them carrying the trigger.
  let assert Ok(second) = api.prompt(rig.runtime, [user("again")])
    as "the second prompt must be accepted"
  let assert Ok(_outcome) =
    api.await_result(rig.runtime, second, within_ms: 10_000)
    as "the second run must complete"
  let assert Ok(third) = api.prompt(rig.runtime, [user("and again")])
    as "the third prompt must be accepted"
  let assert Ok(_outcome) =
    api.await_result(rig.runtime, third, within_ms: 10_000)
    as "the third run must complete"
  assert occurrences(rendered(rig.session), body) == 1
  stop(rig)
}

// A scanner that dies and is replaced rebuilds its cursors from the
// durable marks, so the rule it already fired is not fired again. This
// is the crash story stated as a test: the in-memory bookkeeping is a
// cache, and the marks are the record.
pub fn a_restarted_scanner_does_not_inject_a_second_time_test() {
  let assert Ok(rig) = harness([schema_gate()], answers_with_the_trigger())
    as "the harness must boot"
  let assert Ok(_first) = run_until_fired(rig) as "the rule must fire"
  // Kill the scanner. The supervisor restarts it under the same name,
  // with no memory of anything it had judged.
  let assert Ok(pid) = process.named(rig.scanner) as "the scanner must be live"
  process.kill(pid)
  await_replacement(rig.scanner, pid, 5000)
  // A run for the replacement to inject into, if it were going to.
  let assert Ok(second) = api.prompt(rig.runtime, [user("again")])
    as "the second prompt must be accepted"
  let assert Ok(_outcome) =
    api.await_result(rig.runtime, second, within_ms: 10_000)
    as "the second run must complete"
  assert occurrences(rendered(rig.session), body) == 1
  stop(rig)
}

// --- the idle strand -------------------------------------------------------

// A rule that trips while the strand has no open run is held, not
// dropped and not started. Held is observable as the *absence* of both:
// no mark (nothing was spent) and no new run (nothing was woken).
pub fn a_rule_tripped_on_an_idle_strand_starts_no_run_test() {
  let assert Ok(rig) = harness([schema_gate()], answers_without_the_trigger())
    as "the harness must boot"
  // Settle a run first so the strand exists and is idle.
  let assert Ok(op) = api.prompt(rig.runtime, [user("hello")])
    as "the prompt must be accepted"
  let assert Ok(_outcome) = api.await_result(rig.runtime, op, within_ms: 10_000)
    as "the run must complete"
  // Now trip the rule with the strand idle: an entry carrying the
  // trigger, committed the way a settlement commits one.
  let assert Ok(_) = commit_assistant(rig, "we should " <> trigger <> " users")
    as "the trigger entry must commit"
  poke(rig)
  process.sleep(200)
  // Nothing spent, nothing started, nothing injected.
  assert fact(rig.session, fired_key()) == None
  assert idle(rig)
  assert occurrences(rendered(rig.session), body) == 0
  // …and the next run gets it, because the cursor never moved past the
  // entry that matched.
  let assert Ok(second) = api.prompt(rig.runtime, [user("carry on")])
    as "the second prompt must be accepted"
  let assert Ok(_outcome) =
    api.await_result(rig.runtime, second, within_ms: 10_000)
    as "the second run must complete"
  assert occurrences(rendered(rig.session), body) == 1
  stop(rig)
}

// --- the dead child ---------------------------------------------------------

// Issue #113: a hold on a strand the ledger says was reaped is
// abandoned, not retried forever. The observable is behavioral rather
// than a peek at the scanner's own bookkeeping: a fresh run later opens
// on the very strand an ordinary hold would have fired into the instant
// it could, and the rule still never fires — proving the scanner never
// looked again, rather than merely losing a race.
pub fn a_held_rule_on_a_reaped_child_strand_is_abandoned_test() {
  let assert Ok(rig) = harness([schema_gate()], answers_without_the_trigger())
    as "the harness must boot"
  let child = "sub:main/reviewer-1"
  let assert Ok(Nil) = spawn_idle_strand(rig, child)
    as "the child strand must settle idle"
  // The ledger says the child was reaped *before* the scanner ever sees
  // the trigger — matching #113's own scenario, where the subagent had
  // already finished and been reaped by the time its history was first
  // scanned. This is the durable mark `client/agency`'s own lazy reap
  // enforcement writes, and the only signal this module trusts as "dead"
  // (never a terminal `last_result` alone: see the module doc for why).
  // The check runs once, on the pass a hold begins, so it must be in
  // place before that first pass or this test would only be proving the
  // ordinary retry behavior over again.
  write_lineage(rig, child, parent: "main", reaped: True)
  let assert Ok(Nil) =
    commit_assistant_on(rig, child, "we should " <> trigger <> " users", 91)
    as "the trigger entry must commit"
  let mark = rules.fired_key(strand: child, rule: "schema-gate")
  poke(rig)
  process.sleep(200)
  assert fact(rig.session, mark) == None
  // A fresh run opens on the same strand. An ordinary hold retries and
  // fires into it the moment it can; an abandoned one never looks again.
  let assert Ok(second) =
    api.prompt(api.on_strand(rig.runtime, child), [user("carry on")])
    as "the child's second prompt must be accepted"
  let assert Ok(_outcome) =
    api.await_result(rig.runtime, second, within_ms: 10_000)
    as "the child's second run must complete"
  poke(rig)
  process.sleep(200)
  assert fact(rig.session, mark) == None
  assert occurrences(rendered_of(rig.session, child), body) == 0
  stop(rig)
}

// The two fail-open branches: no lineage cell at all (a root strand, or
// a subagent whose cell has not landed yet) and one that will not
// decode both keep a hold ordinary. `a_rule_tripped_on_an_idle_strand_
// starts_no_run_test` above already proves the first, over "main",
// which never gets a lineage cell of its own; this proves the second.
pub fn a_held_rule_with_a_corrupt_lineage_cell_still_fires_test() {
  let assert Ok(rig) = harness([schema_gate()], answers_without_the_trigger())
    as "the harness must boot"
  let child = "sub:main/reviewer-2"
  let assert Ok(Nil) = spawn_idle_strand(rig, child)
    as "the child strand must settle idle"
  let assert Ok(Nil) =
    commit_assistant_on(rig, child, "we should " <> trigger <> " users", 92)
    as "the trigger entry must commit"
  write_corrupt_lineage(rig, child)
  let mark = rules.fired_key(strand: child, rule: "schema-gate")
  poke(rig)
  process.sleep(200)
  assert fact(rig.session, mark) == None
  // Fail open: doubt about the ledger must never read as "dead", so the
  // hold is retried and fires as soon as a run opens.
  let assert Ok(second) =
    api.prompt(api.on_strand(rig.runtime, child), [user("carry on")])
    as "the child's second prompt must be accepted"
  let assert Ok(_outcome) =
    api.await_result(rig.runtime, second, within_ms: 10_000)
    as "the child's second run must complete"
  poke(rig)
  process.sleep(200)
  assert occurrences(rendered_of(rig.session, child), body) == 1
  stop(rig)
}

// --- driving ---------------------------------------------------------------

// Two runs, the second gated on the fired-mark. Whichever of them the
// scanner fires into — the first if its checkpoint is still ahead, the
// second if the first run ended before the scanner got there — the
// injection is drained into the tree before this returns.
fn run_until_fired(rig: Rig) -> Result(String, String) {
  use first <- result.try(
    api.prompt(rig.runtime, [user("what next?")])
    |> result.replace_error("the first prompt was refused"),
  )
  use _outcome <- result.try(
    api.await_result(rig.runtime, first, within_ms: 10_000)
    |> result.replace_error("the first run did not complete"),
  )
  use second <- result.try(
    api.prompt(rig.runtime, [user("and then?")])
    |> result.replace_error("the second prompt was refused"),
  )
  use _outcome <- result.try(
    api.await_result(rig.runtime, second, within_ms: 10_000)
    |> result.replace_error("the second run did not complete"),
  )
  Ok(rendered(rig.session))
}

// --- the rig ---------------------------------------------------------------

type Rig {
  Rig(
    runtime: api.Runtime,
    session: session.Session,
    scanner: Name(writer.Event),
    services: process.Pid,
  )
}

// What the scripted provider says, per turn.
type Answers {
  Answers(text: fn(Int) -> String, gated: Bool)
}

fn answers_with_the_trigger() -> Answers {
  Answers(
    text: fn(turn) {
      "turn " <> string.inspect(turn) <> ": we should " <> trigger <> " users"
    },
    gated: True,
  )
}

fn answers_without_the_trigger() -> Answers {
  Answers(
    text: fn(turn) { "turn " <> string.inspect(turn) <> ": nothing to see" },
    gated: False,
  )
}

fn harness(
  rule_list: List(rules.Rule),
  answers: Answers,
) -> Result(Rig, String) {
  use opened <- result.try(
    session.open_memory(clock.stepping(from: 1_756_000_000_000, by: 3))
    |> result.replace_error("the memory session did not open"),
  )
  use entropy <- result.try(start_entropy())
  use sink <- result.try(
    summaries.start()
    |> result.replace_error("the summary sink did not start"),
  )
  use turns <- result.try(start_turns())
  let scanner = process.new_name(prefix: "loom_rulescan_test")
  let effects_record =
    effects.Effects(
      clock: clock.stepping(from: 1_756_000_000_000, by: 3),
      entropy:,
      timers: effects.real_timers(),
      provider: wiring.recording_summaries(
        scripted_provider(answers, turns, opened),
        into: sink,
      ),
      tools: refusing_tools(),
      hooks: effects.default_hooks(),
    )
  let configuration = strand_configuration()
  let options = api.default_options(configuration)
  use runtime <- result.try(
    api.open(
      opened,
      effects_record,
      api.Options(
        ..options,
        poll_interval_ms: 20,
        // By name, exactly as production wires it: the writer skips a
        // subscriber whose name is momentarily unregistered, which is
        // what lets the scanner be started after the runtime it watches
        // and restarted under it.
        subscribers: [process.named_subject(scanner)],
      ),
    )
    |> result.map_error(string.inspect),
  )
  // Under a supervisor, as production wires it — and unlinked from this
  // process, so a test that kills the scanner is killing a supervised
  // child rather than something it is linked to.
  use services <- result.try(
    sup.new(sup.OneForOne)
    |> sup.add(rulescan.supervised(
      rulescan.default_options(rule_list),
      runtime,
      scanner,
    ))
    |> sup.start
    |> result.replace_error("the scanner supervisor did not start"),
  )
  process.unlink(services.pid)
  await_named(scanner, 2000)
  Ok(Rig(runtime:, session: opened, scanner:, services: services.pid))
}

fn stop(rig: Rig) -> Nil {
  process.kill(rig.services)
  process.kill(rig.runtime.tree.supervisor)
}

fn strand_configuration() -> machine_strand.StrandConfiguration {
  machine_strand.StrandConfiguration(
    model: machine_strand.ModelIdentity(provider: "acme", model_id: "loom-1"),
    thinking_level: machine_strand.ThinkingOff,
    active_tool_names: [],
  )
}

// A second, genuinely running strand, seeded and settled through one
// harmless brief — real registers, a real driver, under the same
// supervisor "main" runs under. Used to give a subagent-shaped strand a
// real idle `strand.state` before a test hand-writes a trigger entry and
// a lineage cell onto it; the scanner does not care how a strand came to
// exist, only that it has a leaf, an idle state and a committed message.
fn spawn_idle_strand(rig: Rig, strand: String) -> Result(Nil, String) {
  use op <- result.try(
    api.create_strand(
      rig.runtime,
      named: strand,
      configuration: strand_configuration(),
      at: None,
      brief: [user("settle in")],
    )
    |> result.map_error(string.inspect),
  )
  use _outcome <- result.try(
    api.await_strand_result(
      rig.runtime,
      strand:,
      operation: op,
      within_ms: 10_000,
    )
    |> result.replace_error("the child's first run did not settle"),
  )
  Ok(Nil)
}

// A held rule's strand judged dead needs the ledger's own verdict: the
// `runtime/lineage` cell `client/agency`'s reap enforcement would have
// written. Written directly here, because this harness runs no Agency —
// the scanner does not know or care who wrote the cell, only what it
// says.
fn write_lineage(
  rig: Rig,
  strand: String,
  parent parent: String,
  reaped reaped: Bool,
) -> Nil {
  let #(brief, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 1_756_000_500_000), seed: 501))
  let cell =
    lineage.Lineage(
      strand:,
      parent:,
      depth: 1,
      minted_by: lineage.CallSite(
        operation: brief,
        step_id: "rulescan-test-step",
        source_index: 0,
      ),
      brief:,
      tools: [],
      deadline: None,
      detached: False,
      reaped:,
    )
  let assert Ok(Nil) =
    api.put_reserved_fact(
      rig.runtime,
      lineage.register_key(strand),
      lineage.encode(cell),
    )
    as "the lineage cell must commit"
  Nil
}

// A lineage cell that exists but will not decode: missing every field
// `lineage.decode` requires. The scanner must fail open on this exactly
// as it does on no cell at all.
fn write_corrupt_lineage(rig: Rig, strand: String) -> Nil {
  let assert Ok(Nil) =
    api.put_reserved_fact(
      rig.runtime,
      lineage.register_key(strand),
      json.Object([#("not-a-lineage-cell", json.Bool(True))]),
    )
    as "the corrupt cell must still commit"
  Nil
}

// A hint with nothing behind it: the scanner pulls its truth from the
// store, so any commit event makes it look again.
fn poke(rig: Rig) -> Nil {
  case process.named(rig.scanner) {
    Ok(_pid) ->
      process.send(
        process.named_subject(rig.scanner),
        writer.Committed(ordinal: 0, seqs: [], ts: 0),
      )
    Error(Nil) -> Nil
  }
}

fn scripted_provider(
  answers: Answers,
  turns: Subject(Subject(Int)),
  opened: session.Session,
) -> effects.ProviderSurface {
  effects.ProviderSurface(timeout_ms: 30_000, request: fn(spec) {
    let events = process.new_subject()
    case spec {
      effects.GenerationRequest(..) -> {
        let turn = next_turn(turns)
        // From the second turn on, wait for the mark. This runs on the
        // effect process, so nothing in the runtime is blocked by it —
        // and it makes "was the steer durable before the checkpoint?"
        // a settled question rather than a race.
        case answers.gated && turn > 1 {
          True -> await_mark(opened, 10_000)
          False -> Nil
        }
        settle(events, answer(answers.text(turn)))
      }
      effects.PollRequest(..) | effects.SummaryRequest(..) ->
        settle(events, answer("unused"))
    }
    stream.immediate(events:, cancel: fn() { Nil })
  })
}

fn settle(events: Subject(stream.StreamEvent), reply: AgentMessage) -> Nil {
  case stream.settle(reply) {
    Ok(settled) ->
      process.send(
        events,
        stream.Settled(message: settled, usage: effects.zero_usage()),
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

fn answer(text: String) -> AgentMessage {
  message.AssistantMessage(
    content: [message.AssistantText(text:, text_signature: None)],
    api: "anthropic",
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
  )
}

// --- durable observation ---------------------------------------------------

fn fired_key() -> String {
  rules.fired_key(strand: "main", rule: "schema-gate")
}

fn fact(opened: session.Session, key: String) -> Option(json.JsonValue) {
  storage.get_register(opened.store, register.FactCustom, key)
  |> result.unwrap(None)
  |> option.map(fn(cell: storage.Register) { cell.value.payload })
}

fn await_mark(opened: session.Session, remaining_ms: Int) -> Nil {
  case fact(opened, fired_key()), remaining_ms <= 0 {
    Some(_value), _ | _, True -> Nil
    None, False -> {
      process.sleep(10)
      await_mark(opened, remaining_ms - 10)
    }
  }
}

fn await_named(name: Name(writer.Event), remaining_ms: Int) -> Nil {
  case process.named(name), remaining_ms <= 0 {
    Ok(_pid), _ | _, True -> Nil
    Error(Nil), False -> {
      process.sleep(5)
      await_named(name, remaining_ms - 5)
    }
  }
}

// Waits until the name resolves to a *different* process: the
// supervisor's replacement, not the corpse.
fn await_replacement(
  name: Name(writer.Event),
  gone: process.Pid,
  remaining_ms: Int,
) -> Nil {
  case process.named(name), remaining_ms <= 0 {
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

fn idle(rig: Rig) -> Bool {
  case session.strand_state(rig.session, "main") {
    Ok(Some(session.Cell(value: state, ..))) -> state.current_operation == None
    Ok(None) | Error(_reason) -> False
  }
}

// One assistant entry committed straight onto the strand's leaf, the way
// a settlement commits one: the entry and the leaf move together, under
// the leaf's own seq. Used to trip a rule while the strand has no open
// run — a state no scripted provider can produce, because a settlement
// only ever happens inside one.
fn commit_assistant(rig: Rig, text: String) -> Result(Nil, String) {
  commit_assistant_on(rig, "main", text, 77)
}

// The same trick, onto any strand's leaf, distinguished by `seed` so two
// calls in the same test mint different entry ids.
fn commit_assistant_on(
  rig: Rig,
  strand: String,
  text: String,
  seed: Int,
) -> Result(Nil, String) {
  use leaf_cell <- result.try(
    session.strand_leaf(rig.session, strand)
    |> result.replace_error("the leaf register did not read"),
  )
  use session.Cell(seq: leaf_seq, value: leaf) <- result.try(option.to_result(
    leaf_cell,
    "the strand has no leaf register",
  ))
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
          message: answer(text),
          terminate: False,
        )),
        tx.SetRegister(
          ns: register.StrandLeaf,
          key: strand,
          value: register.leaf_value(Some(id)),
        ),
      ],
      expected: [
        tx.Expect(ns: register.StrandLeaf, key: strand, seq: Some(leaf_seq)),
      ],
    )
  writer.commit(process.named_subject(rig.runtime.tree.writer), commit)
  |> result.replace(Nil)
  |> result.map_error(string.inspect)
}

// --- projection ------------------------------------------------------------

fn rendered(opened: session.Session) -> String {
  rendered_of(opened, "main")
}

fn rendered_of(opened: session.Session, strand: String) -> String {
  let leaf = case session.strand_leaf(opened, strand) {
    Ok(Some(session.Cell(value: leaf, ..))) -> leaf
    Ok(None) | Error(_reason) -> None
  }
  case session.project_context(opened, leaf) {
    Ok(messages) -> messages |> list.map(text_of) |> string.join("\n")
    Error(_reason) -> ""
  }
}

fn text_of(item: AgentMessage) -> String {
  case item {
    message.UserMessage(content:, ..) ->
      content
      |> list.filter_map(fn(block) {
        case block {
          message.UserText(text:, ..) -> Ok(text)
          message.UserImage(..) -> Error(Nil)
        }
      })
      |> string.join("\n")
    message.AssistantMessage(content:, ..) ->
      content
      |> list.filter_map(fn(block) {
        case block {
          message.AssistantText(text:, ..) -> Ok(text)
          message.AssistantThinking(..) | message.AssistantToolCall(..) ->
            Error(Nil)
        }
      })
      |> string.join("\n")
    message.ToolResultMessage(content:, ..) ->
      content
      |> list.filter_map(fn(block) {
        case block {
          message.ToolResultText(text:, ..) -> Ok(text)
          message.ToolResultImage(..) -> Error(Nil)
        }
      })
      |> string.join("\n")
    message.CustomMessage(..) -> ""
  }
}

fn occurrences(haystack: String, needle: String) -> Int {
  list.length(string.split(haystack, on: needle)) - 1
}

// --- counters --------------------------------------------------------------

fn start_turns() -> Result(Subject(Subject(Int)), String) {
  actor.new(0)
  |> actor.on_message(fn(count, reply: Subject(Int)) {
    process.send(reply, count + 1)
    actor.continue(count + 1)
  })
  |> actor.start
  |> result.map(fn(started) { started.data })
  |> result.replace_error("the turn counter did not start")
}

fn next_turn(turns: Subject(Subject(Int))) -> Int {
  process.call(turns, waiting: 1000, sending: fn(reply) { reply })
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

fn user(text: String) -> AgentMessage {
  message.UserMessage(
    content: [message.UserText(text:, text_signature: None)],
    timestamp: 0,
  )
}
