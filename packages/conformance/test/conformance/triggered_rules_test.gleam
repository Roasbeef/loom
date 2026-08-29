//// Triggered project rules (issue #27), driven end to end: the real
//// wiring, the real provider gateway, the real Anthropic adapter, the
//// real runtime and the real scanner under a real supervisor, with only
//// the HTTP transport scripted.
////
//// Three rows, and each is a claim the feature would be worthless
//// without.
////
//// - **Fire.** A rule dormant in configuration reaches the *provider
////   request* after model output trips its trigger. The assertion is on
////   the bytes the transport was handed, not on the scanner's own
////   bookkeeping: a rule that fired into a register nobody projects has
////   not fired.
//// - **Isolation.** The scanner is killed while a turn is in flight.
////   Every settlement lands, the run reaches the same terminal outcome,
////   the same answers are in the tree — and the rule still fires, off
////   the durable marks, once the supervisor has replaced the scanner.
////   Design §10's requirement is that an expensive scan can never delay
////   a settlement; this is the strongest available form of it, since a
////   scanner that was *gone* for the whole turn is a scan of infinite
////   cost.
//// - **Flood.** A trigger matching every assistant message still yields
////   exactly one injection. The write-once mark is what decides, not the
////   match.
////
//// Nothing here needs a jail: no scripted turn calls a tool, so the
//// broker's pool seam never yields a helper and never has to.

import broker/broker
import broker/exec
import broker/policy
import broker/token
import client/escalate
import client/rules
import client/rulescan
import client/summaries
import client/system_prompt
import client/wiring
import core/clock
import core/json
import core/message
import core/register
import gleam/erlang/process.{type Name, type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor as sup
import gleam/string
import machine/operation
import machine/strand.{
  type StrandConfiguration, ModelIdentity, StrandConfiguration,
}
import prompt/pack
import provider/adapter/anthropic
import provider/gateway
import provider/http
import provider/model
import provider/secret
import runtime/api
import runtime/writer
import session/session.{type Session}
import storage/storage
import support/rig
import support/script

const model_id = "loom-1"

const window = 200_000

const trigger = "ALTER TABLE"

const body = "Run the schema gate before proposing a migration."

const rule_name = "schema-gate"

fn schema_gate() -> rules.Rule {
  rules.Rule(name: rule_name, triggers: [trigger], body:)
}

// --- the fire --------------------------------------------------------------

pub fn a_triggered_rule_reaches_the_next_provider_request_test() {
  let rig = boot([schema_gate()], Answers(trips: OnlyTheFirstTurn, kill: False))

  // Two runs. Whichever of them the scanner fires into — the first if its
  // checkpoint is still ahead, the second if the first ended before the
  // scanner got there — the injection is durable and drained by the time
  // the second run is done, because every turn from the second onward
  // waits for the mark before it answers.
  drive(rig, "what should I do about the users table?")
  drive(rig, "carry on")

  // The claim, stated where it matters: the rule's text was in a request
  // the harness actually put on the wire. A projection assertion alone
  // would not distinguish "in the tree" from "in the context".
  let sent = bodies(rig)
  assert list.any(sent, string.contains(_, body))
  assert list.any(sent, string.contains(_, "triggered project rule"))

  // …exactly once in the context, and attributed rather than passed off
  // as something the operator typed.
  let context = projected_text(rig.session)
  assert occurrences(context, body) == 1
  assert string.contains(context, "not a turn from the user")

  // …and the durable mark says which rule spent itself here.
  assert fired(rig.session) == Some(rule_name)
  teardown(rig)
}

// A rule nobody tripped is nowhere: not in the tree, not in a request,
// and no mark spent. The measurement design §8 actually promises.
pub fn a_dormant_rule_is_absent_from_every_request_test() {
  let rig = boot([schema_gate()], Answers(trips: Never, kill: False))
  drive(rig, "say something harmless")
  assert list.all(bodies(rig), fn(sent) { !string.contains(sent, body) })
  assert occurrences(projected_text(rig.session), body) == 0
  assert fired(rig.session) == None
  teardown(rig)
}

// --- isolation -------------------------------------------------------------

// The scanner is killed while the first turn is in flight — before its
// answer has even been streamed, so it is absent for the whole of the
// settlement it would have scanned. Nothing about the run changes: the
// answers land, the operation completes, the ledger is whole. And the
// rule still fires afterwards, because the replacement rebuilds what it
// needs from the store rather than from anything the dead one held.
pub fn a_scanner_killed_mid_turn_changes_no_settlement_test() {
  let rig = boot([schema_gate()], Answers(trips: OnlyTheFirstTurn, kill: True))
  let outcome = drive(rig, "what should I do about the users table?")
  let assert operation.RunLastResult(
    outcome: operation.RunCompleted(..),
    final_assistant: Some(_),
    ..,
  ) = outcome
    as "the run must complete exactly as it would with no scanner at all"

  // Every request produced exactly one settled assistant message
  // carrying exactly the text the script said, in order: nothing was
  // lost, reordered or rewritten by the scanner's death.
  assert assistant_texts(rig.session) == scripted_answers(rig)

  // The scanner really did die and really was replaced.
  assert rig.first_scanner != current_scanner(rig)
  // …and the rule fires off the durable state the replacement reloaded.
  drive(rig, "carry on")
  assert fired(rig.session) == Some(rule_name)
  assert occurrences(projected_text(rig.session), body) == 1
  teardown(rig)
}

// --- the flood -------------------------------------------------------------

pub fn a_trigger_on_every_message_still_injects_once_test() {
  let rig = boot([schema_gate()], Answers(trips: EveryTurn, kill: False))
  drive(rig, "one")
  drive(rig, "two")
  drive(rig, "three")
  assert occurrences(projected_text(rig.session), body) == 1
  // Every request after the fire carries the injection — it is in the
  // conversation now — but it carries exactly *one* copy of it, which is
  // the difference between "fired once" and "injected once".
  let assert Ok(newest) = list.last(bodies(rig))
    as "at least one request must have been sent"
  assert occurrences(newest, body) == 1
  teardown(rig)
}

// --- the rig ---------------------------------------------------------------

// Which turns carry the trigger.
type Trips {
  Never
  OnlyTheFirstTurn
  EveryTurn
}

type Answers {
  Answers(trips: Trips, kill: Bool)
}

type Rig {
  Rig(
    runtime: api.Runtime,
    session: Session,
    scanner: Name(writer.Event),
    services: Pid,
    first_scanner: Result(Pid, Nil),
    sent: Subject(Sent),
    answers: Answers,
  )
}

fn boot(rule_list: List(rules.Rule), answers: Answers) -> Rig {
  let sess = memory_session()
  let sent = recorder()
  let scanner = process.new_name(prefix: "loom_ttsr_conformance")
  let effects =
    wiring.build_effects(wiring_config(
      routed_gateway(transport(answers, sess, scanner, sent)),
      sess,
    ))
  let options = api.default_options(configuration())
  let assert Ok(runtime) =
    api.open(
      sess,
      effects,
      api.Options(
        ..options,
        poll_interval_ms: 20,
        // By name, the way `client/serve` subscribes it: the writer skips
        // a subscriber whose name is momentarily unregistered, which is
        // exactly what makes the kill row survivable.
        subscribers: [process.named_subject(scanner)],
      ),
    )
    as "the session must open"
  // The restartable tier, in miniature: one supervisor, one-for-one, the
  // scanner under it, unlinked from this process so a kill is a
  // supervised child dying rather than the test dying with it.
  let assert Ok(services) =
    sup.new(sup.OneForOne)
    |> sup.add(rulescan.supervised(
      rulescan.default_options(rule_list),
      runtime,
      scanner,
    ))
    |> sup.start
    as "the service supervisor must start"
  process.unlink(services.pid)
  await_named(scanner, 2000)
  Rig(
    runtime:,
    session: sess,
    scanner:,
    services: services.pid,
    first_scanner: process.named(scanner),
    sent:,
    answers:,
  )
}

fn teardown(rig: Rig) -> Nil {
  process.kill(rig.services)
  let assert Ok(Nil) = api.close(rig.runtime) as "the session must close"
  Nil
}

fn drive(rig: Rig, text: String) -> operation.LastResult {
  let assert Ok(op) = api.prompt(rig.runtime, [user(text)])
    as "the prompt must be accepted"
  let assert Ok(outcome) = api.await_result(rig.runtime, op, within_ms: 30_000)
    as "the run must reach a terminal result"
  outcome
}

fn current_scanner(rig: Rig) -> Result(Pid, Nil) {
  process.named(rig.scanner)
}

// --- the scripted transport ------------------------------------------------

// The transport records every request body and answers with a scripted
// turn. Two pieces of stage machinery, both outside the code under test:
//
// - From the second turn on it waits for the rule's durable fired-mark
//   before answering, which settles the one race in the scenario —
//   whether the scanner's steer was durable before the checkpoint that
//   would drain it — without touching the scanner or the runtime.
// - On the kill row it kills the scanner on the way into the first turn,
//   so the scanner is absent for the whole of the settlement it would
//   otherwise have scanned.
fn transport(
  answers: Answers,
  sess: Session,
  scanner: Name(writer.Event),
  sent: Subject(Sent),
) -> http.Transport {
  script.owned_transport(fn(request: http.HttpRequest, subject) {
    let turn = record(sent, request.body)
    case turn == 1 && answers.kill {
      True -> kill_scanner(scanner)
      False -> Nil
    }
    case turn > 1 && answers.trips != Never {
      True -> await_mark(sess, 20_000)
      False -> Nil
    }
    list.each(settled_events(scripted_text(answers, turn)), fn(event) {
      process.send(subject, event)
    })
  })
}

// What the script says on turn `n`. Pure and shared, so a test can
// predict the transcript rather than restate it.
fn scripted_text(answers: Answers, turn: Int) -> String {
  let tripped = " — we should " <> trigger <> " users"
  case answers.trips, turn {
    Never, _ -> answer_of(turn)
    EveryTurn, _ -> answer_of(turn) <> tripped
    OnlyTheFirstTurn, 1 -> answer_of(turn) <> tripped
    OnlyTheFirstTurn, _ -> answer_of(turn)
  }
}

// The transcript the script implies, one entry per request actually
// sent.
fn scripted_answers(rig: Rig) -> List(String) {
  bodies(rig)
  |> list.index_map(fn(_body, index) { scripted_text(rig.answers, index + 1) })
}

fn answer_of(turn: Int) -> String {
  "answer " <> int.to_string(turn)
}

fn kill_scanner(scanner: Name(writer.Event)) -> Nil {
  case process.named(scanner) {
    Ok(pid) -> process.kill(pid)
    Error(Nil) -> Nil
  }
}

// The scripted turn's SSE body, replayed through the real adapter by
// borrowing the e2e script's own renderer via a one-turn transport —
// the trick `routing_test` uses, for the same reason: the wire
// vocabulary should be the one the adapter really parses.
fn settled_events(text: String) -> List(http.HttpEvent) {
  let captured = process.new_subject()
  let one_shot =
    script.transport([
      script.AnswerTurn(text:, input_tokens: 100, output_tokens: 9),
    ])
  let assert Ok(_running) =
    one_shot.start_streaming(
      http.HttpRequest(
        method: "POST",
        url: "https://captured.test",
        headers: [],
        body: "",
      ),
      captured,
    )
  collect(captured, [])
}

fn collect(
  events: Subject(http.HttpEvent),
  seen: List(http.HttpEvent),
) -> List(http.HttpEvent) {
  case process.receive(events, within: 200) {
    Ok(event) -> collect(events, [event, ..seen])
    Error(Nil) -> list.reverse(seen)
  }
}

// --- the request recorder --------------------------------------------------

type Sent {
  Record(body: String, reply: Subject(Int))
  Read(reply: Subject(List(String)))
}

// An actor rather than a mailbox drain, because the assertions read it
// while runs are still live.
fn recorder() -> Subject(Sent) {
  let assert Ok(started) =
    actor.new([])
    |> actor.on_message(fn(seen: List(String), message) {
      case message {
        Record(body:, reply:) -> {
          let seen = [body, ..seen]
          process.send(reply, list.length(seen))
          actor.continue(seen)
        }
        Read(reply:) -> {
          process.send(reply, list.reverse(seen))
          actor.continue(seen)
        }
      }
    })
    |> actor.start
    as "the request recorder must start"
  started.data
}

fn record(sent: Subject(Sent), body: String) -> Int {
  process.call(sent, waiting: 5000, sending: fn(reply) { Record(body:, reply:) })
}

fn bodies(rig: Rig) -> List(String) {
  process.call(rig.sent, waiting: 5000, sending: fn(reply) { Read(reply:) })
}

// --- the wiring under test -------------------------------------------------

fn configuration() -> StrandConfiguration {
  StrandConfiguration(
    model: ModelIdentity(provider: "acme", model_id:),
    thinking_level: strand.ThinkingOff,
    active_tool_names: [],
  )
}

fn routed_gateway(transport: http.Transport) -> gateway.Gateway {
  gateway.new(
    transport:,
    secrets: secret.from_list([#("ACME_KEY", "ttsr-test-key")]),
    clock: clock.stepping(from: 1_700_000_000_000, by: 3),
  )
  |> gateway.add_provider(gateway.AnthropicProvider(
    name: "acme",
    base_url: "https://acme.test",
    api_key_secret: "ACME_KEY",
  ))
  |> gateway.route(model.Main, [
    model.ResolvedModel(
      provider: "acme",
      model_id:,
      thinking: model.ThinkingOff,
      context_window: window,
      max_output_tokens: 8192,
    ),
  ])
  |> gateway.with_attempt_timeout(30_000)
}

fn helperless_broker() -> broker.Broker {
  let assert Ok(started) =
    broker.start(
      broker.BrokerConfig(
        entropy: token.production_entropy(),
        clock: clock.stepping(from: 1_700_000_000_000, by: 7),
        checkout: fn() { Error(exec.AllBusy(size: 0)) },
        checkin: fn(_helper) { Nil },
      ),
    )
    as "the helperless broker must start"
  started
}

fn memory_session() -> Session {
  let assert Ok(opened) =
    session.open_memory(clock.stepping(from: 1_700_000_300_000, by: 11))
    as "the memory session must open"
  opened
}

fn summary_pack() -> pack.Pack {
  let assert Ok(#(decoded, [])) = system_prompt.summary_pack(None)
    as "the shipped summarization pack must load cleanly"
  decoded
}

fn wiring_config(gw: gateway.Gateway, sess: Session) -> wiring.Config {
  let assert Ok(sink) = summaries.start() as "the summary sink must start"
  let workspace = "/nonexistent/loom-ttsr-test"
  wiring.Config(
    gateway: gw,
    role: model.Main,
    facts: fn(_identity) { Error(Nil) },
    system: Some("Answer briefly."),
    api: anthropic.api_name,
    fallback_context_window: window,
    fallback_max_output_tokens: 8192,
    provider_timeout_ms: 30_000,
    summary_role: model.Summarize,
    summary_pack: summary_pack(),
    summaries: sink,
    session: sess,
    // Off, so nothing can rewrite the branch under the occurrence counts.
    compaction: operation.CompactionSettings(
      enabled: False,
      reserve_tokens: 0,
      keep_recent_tokens: 0,
    ),
    broker: helperless_broker(),
    broker_timeout_ms: 1000,
    registry: rig.registry(),
    workspace:,
    blob_root: workspace <> "/.blobs",
    base_policy: policy.workspace_default(workspace),
    escalations: escalate.none(),
    demand: exec.BestEffort,
    env: [#("PATH", "/usr/bin:/bin")],
    clock: clock.stepping(from: 1_700_000_010_000, by: 25),
    entropy: fn() { int.random(1_000_000_000) },
  )
}

// --- durable observation ---------------------------------------------------

fn fired_key() -> String {
  rules.fired_key(strand: "main", rule: rule_name)
}

fn fired(sess: Session) -> Option(String) {
  case storage.get_register(sess.store, register.FactCustom, fired_key()) {
    Ok(Some(storage.Register(value: stored, ..))) ->
      case stored.payload {
        json.String(name) -> Some(name)
        json.Object(..)
        | json.Array(..)
        | json.Int(..)
        | json.Float(..)
        | json.Bool(..)
        | json.Null -> None
      }
    Ok(None) | Error(_reason) -> None
  }
}

fn await_mark(sess: Session, remaining_ms: Int) -> Nil {
  case fired(sess), remaining_ms <= 0 {
    Some(_name), _ | _, True -> Nil
    None, False -> {
      process.sleep(10)
      await_mark(sess, remaining_ms - 10)
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

// --- projection ------------------------------------------------------------

fn projected(sess: Session) -> List(message.AgentMessage) {
  let leaf = case session.strand_leaf(sess, "main") {
    Ok(Some(session.Cell(value: leaf, ..))) -> leaf
    Ok(None) | Error(_reason) -> None
  }
  let assert Ok(messages) = session.project_context(sess, leaf)
    as "the projection must read cleanly"
  messages
}

fn projected_text(sess: Session) -> String {
  projected(sess) |> list.map(text_of) |> string.join("\n")
}

fn assistant_texts(sess: Session) -> List(String) {
  projected(sess)
  |> list.filter_map(fn(item) {
    case item {
      message.AssistantMessage(..) -> Ok(text_of(item))
      message.UserMessage(..)
      | message.ToolResultMessage(..)
      | message.CustomMessage(..) -> Error(Nil)
    }
  })
}

fn text_of(item: message.AgentMessage) -> String {
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

fn user(text: String) -> message.AgentMessage {
  message.UserMessage(
    content: [message.UserText(text:, text_signature: None)],
    timestamp: 0,
  )
}
