//// The M5 role-routing row, driven end to end: a rate-limited chain head
//// and a live fallback, through the *real* wiring, the real gateway, the
//// real adapter and the real runtime, with only the HTTP transport
//// scripted.
////
//// This is the property the row exists for. Before role routing reached
//// the wiring seam, every production dispatch was `ForResolved`, so a
//// `429` on the main model was answered by the machine's own retry
//// ladder against the *same* endpoint — the chain's tail was configured,
//// parsed, routed, listed in the `models` reply, and never once reached.
//// The two tests below are the before/after of exactly that:
////
//// - **Fallback**: head refuses, tail settles, and the run completes on
////   the tail inside one attempt. No retry-wait is entered, which is
////   observable as the head being *asked once*.
//// - **Storm**: both refuse. The walk is exhausted, the terminal failure
////   is still classified retryable, and the machine's ladder engages —
////   `GenerationRetryWait` durably entered, the session alive throughout
////   and afterwards.
////
//// Nothing here needs a jail: an answer turn calls no tools, so the
//// broker's pool seam never yields a helper and never has to.

import broker/broker
import broker/exec
import broker/policy
import broker/token
import client/escalate
import client/summaries
import client/system_prompt
import client/wiring
import core/clock
import core/ids.{type OpId}
import core/message
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/string
import machine/operation
import machine/strand.{
  type ModelIdentity, type StrandConfiguration, ModelIdentity,
  StrandConfiguration,
}
import prompt/pack
import provider/adapter/anthropic
import provider/gateway
import provider/http
import provider/model
import provider/retry
import provider/secret
import provider/stream
import runtime/api
import session/session.{type Session}
import support/rig
import support/script

// --- the two endpoints -----------------------------------------------------

const head_model_id = "loom-head"

const tail_model_id = "loom-tail"

const head_window = 200_000

const tail_window = 150_000

fn head_target() -> model.ResolvedModel {
  model.ResolvedModel(
    provider: "primary",
    model_id: head_model_id,
    thinking: model.ThinkingOff,
    context_window: head_window,
    max_output_tokens: 8192,
  )
}

fn tail_target() -> model.ResolvedModel {
  model.ResolvedModel(
    provider: "backup",
    model_id: tail_model_id,
    thinking: model.ThinkingOff,
    context_window: tail_window,
    max_output_tokens: 4096,
  )
}

// The strand's durable configuration: the *head's* identity, which is
// what `gateway.resolve(Main)` stores and therefore what makes this
// strand on-route.
fn configuration() -> StrandConfiguration {
  StrandConfiguration(
    model: ModelIdentity(provider: "primary", model_id: head_model_id),
    thinking_level: strand.ThinkingOff,
    active_tool_names: [],
  )
}

fn entry_facts(
  identity: ModelIdentity,
) -> Result(#(model.ResolvedModel, String), Nil) {
  list.key_find(
    [
      #(head_model_id, #(head_target(), anthropic.api_name)),
      #(tail_model_id, #(tail_target(), anthropic.api_name)),
    ],
    identity.model_id,
  )
}

// --- the scripted transport ------------------------------------------------

// Every request the walk makes, tallied by the host it went to. The
// counter is an actor rather than a mailbox drain because the assertions
// read it while the run is still live.
type Tally {
  Bump(host: String)
  Read(reply: process.Subject(List(#(String, Int))))
}

fn tally() -> process.Subject(Tally) {
  let assert Ok(started) =
    actor.new([])
    |> actor.on_message(fn(counts: List(#(String, Int)), message) {
      case message {
        Bump(host:) -> {
          let seen = case list.key_find(counts, host) {
            Ok(count) -> count
            Error(Nil) -> 0
          }
          actor.continue([
            #(host, seen + 1),
            ..list.filter(counts, fn(entry) { entry.0 != host })
          ])
        }
        Read(reply:) -> {
          process.send(reply, counts)
          actor.continue(counts)
        }
      }
    })
    |> actor.start
    as "the request tally must start"
  started.data
}

fn hits(counter: process.Subject(Tally), host: String) -> Int {
  let counts =
    process.call(counter, waiting: 1000, sending: fn(reply) { Read(reply:) })
  case list.key_find(counts, host) {
    Ok(count) -> count
    Error(Nil) -> 0
  }
}

// A 429 with no `retry-after`, in the Messages API's own error shape.
fn rate_limited() -> List(http.HttpEvent) {
  [
    http.ResponseStatus(status: 429, headers: []),
    http.ResponseChunk(chunk: <<
      "{\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"slow down\"}}":utf8,
    >>),
    http.ResponseEnd,
  ]
}

// The transport: the head is always rate limited; the tail either settles
// the scripted answer or is rate limited too (the storm).
fn transport(
  counter: process.Subject(Tally),
  tail_answers: Bool,
) -> http.Transport {
  let answer =
    script.AnswerTurn(text: answer_text, input_tokens: 100, output_tokens: 9)
  http.Transport(send_streaming: fn(request: http.HttpRequest, subject) {
    let head = string.contains(request.url, "primary.test")
    process.send(counter, Bump(host: host_of(head)))
    let events = case head, tail_answers {
      True, _ -> rate_limited()
      False, False -> rate_limited()
      False, True -> settled_events(answer)
    }
    list.each(events, fn(event) { process.send(subject, event) })
  })
}

const answer_text = "The fallback answered."

fn host_of(head: Bool) -> String {
  case head {
    True -> "primary"
    False -> "backup"
  }
}

// The scripted turn's SSE body, replayed through the real adapter by
// borrowing the e2e script's own renderer via a one-turn transport.
fn settled_events(turn: script.Turn) -> List(http.HttpEvent) {
  let captured = process.new_subject()
  let one_shot = script.transport([turn])
  one_shot.send_streaming(
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
  events: process.Subject(http.HttpEvent),
  seen: List(http.HttpEvent),
) -> List(http.HttpEvent) {
  case process.receive(events, within: 200) {
    Ok(event) -> collect(events, [event, ..seen])
    Error(Nil) -> list.reverse(seen)
  }
}

// --- the wiring under test -------------------------------------------------

fn routed_gateway(transport: http.Transport) -> gateway.Gateway {
  gateway.new(
    transport:,
    secrets: secret.from_list([
      #("PRIMARY_KEY", "routing-test-key"),
      #("BACKUP_KEY", "routing-test-key"),
    ]),
    clock: clock.stepping(from: 1_700_000_000_000, by: 3),
  )
  |> gateway.add_provider(gateway.AnthropicProvider(
    name: "primary",
    base_url: "https://primary.test",
    api_key_secret: "PRIMARY_KEY",
  ))
  |> gateway.add_provider(gateway.AnthropicProvider(
    name: "backup",
    base_url: "https://backup.test",
    api_key_secret: "BACKUP_KEY",
  ))
  |> gateway.route(model.Main, [head_target(), tail_target()])
  |> gateway.with_attempt_timeout(5000)
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
    as "the fake broker must start"
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
  let workspace = "/nonexistent/loom-routing-test"
  wiring.Config(
    gateway: gw,
    role: model.Main,
    facts: entry_facts,
    system: Some("Answer briefly."),
    api: anthropic.api_name,
    fallback_context_window: head_window,
    fallback_max_output_tokens: 8192,
    provider_timeout_ms: 20_000,
    summary_role: model.Summarize,
    summary_pack: summary_pack(),
    summaries: sink,
    session: sess,
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

// --- the fallback row ------------------------------------------------------

pub fn a_rate_limited_head_falls_to_the_chains_tail_test() {
  let counter = tally()
  let sess = memory_session()
  let effects =
    wiring.build_effects(wiring_config(
      routed_gateway(transport(counter, True)),
      sess,
    ))
  let assert Ok(runtime) =
    api.open(sess, effects, api.default_options(configuration()))
    as "the routing session must open"
  let assert Ok(op) = api.prompt(runtime, [user("Say something.")])
  let assert Ok(outcome) = api.await_result(runtime, op, within_ms: 30_000)
    as "the run must reach a terminal result"
  let assert operation.RunLastResult(
    outcome: operation.RunCompleted(..),
    final_assistant: Some(_),
    ..,
  ) = outcome

  // The head was asked exactly once. That single ask is the whole
  // assertion about the retry ladder: a `GenerationRetryWait` exists only
  // to produce a *second* attempt, so one attempt is proof none was
  // entered — the fallback happened inside the gateway's own walk.
  assert hits(counter, "primary") == 1
  assert hits(counter, "backup") == 1

  // The settled response is attributed to the tail, because that is the
  // identity that actually answered.
  let assert [message.UserMessage(..), settled] = projected(sess)
  let assert message.AssistantMessage(provider:, model: model_id, ..) = settled
  assert provider == "backup"
  assert model_id == tail_model_id
  assert answer_of(settled) == answer_text

  // …and the strand's durable configuration is untouched. A walk is a
  // dispatch-time choice, never a routing change: the next turn starts
  // at the head again, which is what makes the head "preferred" rather
  // than "preferred until it fails once".
  let assert Ok(Some(session.Cell(value: current, ..))) =
    session.strand_configuration(sess, "main")
    as "the strand configuration must read cleanly"
  assert current.model
    == ModelIdentity(provider: "primary", model_id: head_model_id)

  let assert Ok(Nil) = api.close(runtime)
}

// --- the storm -------------------------------------------------------------

pub fn a_storm_across_the_whole_chain_engages_the_retry_ladder_test() {
  // A 429 is retryable wherever it is met, which is why an exhausted
  // walk must not look terminal to the machine.
  assert retry.classify(stream.HttpError(
      status: 429,
      api_error_type: "rate_limit_error",
      message: "slow down",
      retry_after_ms: None,
    ))
    == retry.Retryable(backoff_hint_ms: None)

  let counter = tally()
  let sess = memory_session()
  let effects =
    wiring.build_effects(wiring_config(
      routed_gateway(transport(counter, False)),
      sess,
    ))
  let options = api.default_options(configuration())
  let assert Ok(runtime) =
    api.open(
      sess,
      effects,
      api.Options(
        ..options,
        // Long enough that the durable retry-wait is observable rather
        // than inferred; three attempts still exhaust in about a second.
        retry_policy: operation.NormalizedRetryPolicy(
          max_attempts: 3,
          base_delay_ms: 400,
        ),
      ),
    )
    as "the routing session must open"
  let assert Ok(op) = api.prompt(runtime, [user("Say something.")])

  // The ladder is durably entered, not merely implied by a second
  // attempt: `op.state` sits in `GenerationRetryWait` between them.
  assert waited_for_retry(sess, op, 6000)
    as "the machine must durably enter a retry wait"

  let assert Ok(outcome) = api.await_result(runtime, op, within_ms: 30_000)
    as "the storm run must reach a terminal result"
  let assert operation.RunLastResult(outcome: operation.RunFailed(..), ..) =
    outcome

  // Every attempt walked the whole chain, and there were three of them —
  // the ladder ran to exhaustion rather than the walk being mistaken for
  // it, or the walk being skipped.
  assert hits(counter, "primary") == 3
  assert hits(counter, "backup") == 3

  // The session survived the storm: it still accepts work.
  let assert Ok(_next) = api.prompt(runtime, [user("Still there?")])
    as "the session must still admit a run after a drained failure"
  let assert Ok(Nil) = api.close(runtime)
}

// Polls the durable operation state for a `GenerationRetryWait`. The
// register is the evidence — a retry wait that only ever existed in a
// driver's process state would not survive the crash the machine is
// built around.
fn waited_for_retry(sess: Session, op: OpId, remaining_ms: Int) -> Bool {
  case in_retry_wait(sess, op) {
    True -> True
    False ->
      case remaining_ms <= 0 {
        True -> False
        False -> {
          process.sleep(10)
          waited_for_retry(sess, op, remaining_ms - 10)
        }
      }
  }
}

fn in_retry_wait(sess: Session, op: OpId) -> Bool {
  case session.op_state(sess, op) {
    Ok(Some(session.Cell(
      value: operation.RunState(
        phase: operation.Assistant(
          generation: operation.GenerationRetryWait(..),
        ),
        ..,
      ),
      ..,
    ))) -> True
    _ -> False
  }
}

// --- helpers ---------------------------------------------------------------

fn user(text: String) -> message.AgentMessage {
  message.UserMessage(
    content: [message.UserText(text:, text_signature: None)],
    timestamp: 0,
  )
}

fn projected(sess: Session) -> List(message.AgentMessage) {
  let leaf = case session.strand_leaf(sess, "main") {
    Ok(Some(session.Cell(value: leaf, ..))) -> leaf
    _ -> None
  }
  let assert Ok(messages) = session.project_context(sess, leaf)
    as "the projection must read cleanly"
  messages
}

fn answer_of(settled: message.AgentMessage) -> String {
  case settled {
    message.AssistantMessage(
      content: [message.AssistantText(text:, ..), ..],
      ..,
    ) -> text
    _ -> ""
  }
}
