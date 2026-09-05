//// Compaction, end to end, through the production hooks.
////
//// `client/wiring`'s compaction seams are the whole of what makes
//// compaction *run*: before them a threshold never fired, every
//// structural decision declined, and an overflowing run drained as
//// `context_overflow`. These tests drive a real session and a real
//// runtime with those seams installed and a scripted provider behind
//// them, and assert on what lands in the tree — a `CompactionEntry`
//// whose text is the checkpoint `client/checkpoint` built from the
//// strand's own notes, never a summary a provider produced.
////
//// The provider is scripted rather than routed at a network, and the
//// script is deliberately unable to summarize: a summary request, were
//// one ever dispatched, fails terminally. A compaction that lands anyway
//// is therefore a compaction that needed no summarizer, which is the
//// property the checkpoint exists to have.

import broker/broker
import broker/exec
import broker/policy
import broker/token
import client/checkpoint
import client/escalate
import client/wiring
import core/clock
import core/entry
import core/json
import core/message.{type AgentMessage}
import core/register
import core/tx.{SetRegister, Tx}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import machine/operation
import machine/strand as machine_strand
import provider/gateway as provider_gateway
import provider/model
import provider/secret
import provider/stream
import runtime/api
import runtime/effects
import session/session
import storage/storage
import support/provider as provider_test
import support/tool_registry
import weft/actor

// Small enough that one scripted turn's reported usage crosses it.
const window = 10_000

const reserve = 2000

// Two of the harness's turns fit; a third does not, so a compaction
// always has something older than the tail to cut.
const keep_recent = 500

// A note the model wrote before the boundary, exactly as `agent_note`
// writes one. If a `CompactionEntry` carries this, the checkpoint was
// built from the strand's own board.
const noted_decision = "the fetcher grew a retry; keep the backoff at 2x"

// A message of roughly 400 estimated tokens (characters over four), so
// the keep-recent budget is a budget rather than a formality.
fn bulky(label: String) -> String {
  label <> ": " <> string.repeat("context ", 200)
}

// --- the threshold ---------------------------------------------------------

pub fn a_crossed_threshold_publishes_the_notes_checkpoint_test() {
  let assert Ok(rig) = harness(Healthy, NoNotes) as "the harness must open"
  note(rig.session, "main", "decision", noted_decision)
  // Turn one settles under the threshold; turn two reports usage above
  // it, so the checkpoint after it compacts.
  let assert Ok(first) = api.prompt(rig.runtime, [user(bulky("start"))])
  let assert Ok(_settled) =
    api.await_result(rig.runtime, first, within_ms: 5000)
  let assert Ok(second) = api.prompt(rig.runtime, [user(bulky("keep going"))])
  let assert Ok(_settled) =
    api.await_result(rig.runtime, second, within_ms: 5000)

  let assert [entry.CompactionEntry(summary:, from_hook:, tokens_before:, ..)] =
    compactions(rig.session)
  // The text is the harness's own — hook-supplied, never generated — and
  // it carries the note the model left, whole.
  assert from_hook == True
  assert string.starts_with(summary, checkpoint.header_prefix <> "1 closed")
  assert string.contains(summary, "decision = \"" <> noted_decision <> "\"")
  assert string.contains(summary, "Nothing was summarized")
  assert tokens_before > window - reserve
  // No summary request was ever made: the script refuses them all, and
  // the compaction landed regardless.
  assert process.receive(rig.summaries, within: 0) == Error(Nil)
  let _closed = api.close(rig.runtime)
}

// A strand that wrote nothing is told so, in words that say where notes
// go, rather than handed an empty fence.
pub fn a_strand_with_no_notes_is_told_where_they_go_test() {
  let assert Ok(rig) = harness(Healthy, NoNotes) as "the harness must open"
  let assert Ok(first) = api.prompt(rig.runtime, [user(bulky("start"))])
  let assert Ok(_settled) =
    api.await_result(rig.runtime, first, within_ms: 5000)
  let assert Ok(second) = api.prompt(rig.runtime, [user(bulky("keep going"))])
  let assert Ok(_settled) =
    api.await_result(rig.runtime, second, within_ms: 5000)

  let assert [entry.CompactionEntry(summary:, ..)] = compactions(rig.session)
  assert string.contains(summary, "You wrote no notes before this boundary")
  assert string.contains(summary, "agent/main/")
  let _closed = api.close(rig.runtime)
}

// The guard against a compaction loop: the entry a compaction writes
// carries a copy of the retained tail, whose assistant usage describes
// the context that was *replaced*. A fold that read it would compact on
// every checkpoint for the rest of the session.
pub fn a_finished_compaction_does_not_re_fire_the_threshold_test() {
  let assert Ok(rig) = harness(Healthy, NoNotes)
  let assert Ok(first) = api.prompt(rig.runtime, [user(bulky("start"))])
  let assert Ok(_settled) =
    api.await_result(rig.runtime, first, within_ms: 5000)
  let assert Ok(second) = api.prompt(rig.runtime, [user(bulky("keep going"))])
  let assert Ok(_settled) =
    api.await_result(rig.runtime, second, within_ms: 5000)
  assert list.length(compactions(rig.session)) == 1
  // A third turn, whose own reported usage is small, must not compact
  // again on the strength of the pre-compaction number in the tail.
  let assert Ok(third) = api.prompt(rig.runtime, [user(bulky("and once more"))])
  let assert Ok(_settled) =
    api.await_result(rig.runtime, third, within_ms: 5000)
  assert list.length(compactions(rig.session)) == 1
  let _closed = api.close(rig.runtime)
}

// The second window boundary is numbered, so the model can tell how far
// into a long session it is, and the notes travel across both.
pub fn a_second_compaction_closes_window_two_test() {
  let assert Ok(rig) = harness(CrossesTwice, NoNotes)
  note(rig.session, "main", "decision", noted_decision)
  let assert Ok(first) = api.prompt(rig.runtime, [user(bulky("start"))])
  let assert Ok(_settled) =
    api.await_result(rig.runtime, first, within_ms: 5000)
  let assert Ok(second) = api.prompt(rig.runtime, [user(bulky("keep going"))])
  let assert Ok(_settled) =
    api.await_result(rig.runtime, second, within_ms: 5000)
  let assert Ok(third) = api.prompt(rig.runtime, [user(bulky("and again"))])
  let assert Ok(_settled) =
    api.await_result(rig.runtime, third, within_ms: 5000)

  let assert [
    entry.CompactionEntry(summary: first_text, ..),
    entry.CompactionEntry(summary: second_text, ..),
  ] = compactions(rig.session)
  assert string.starts_with(first_text, checkpoint.header_prefix <> "1 closed")
  assert string.starts_with(second_text, checkpoint.header_prefix <> "2 closed")
  assert string.contains(second_text, noted_decision)
  let _closed = api.close(rig.runtime)
}

// --- the reminder before the cut -------------------------------------------

// Once the context is within a reserve of the compaction point, the
// request the model is about to answer carries the reminder to write its
// notes; before that band it carries nothing, and after the compaction
// the context is small again and it carries nothing.
pub fn a_near_limit_request_carries_the_notes_reminder_test() {
  let assert Ok(rig) = harness(NearsTheLimit, NoNotes)
  let assert Ok(first) = api.prompt(rig.runtime, [user(bulky("start"))])
  let assert Ok(_settled) =
    api.await_result(rig.runtime, first, within_ms: 5000)
  let assert Ok(second) = api.prompt(rig.runtime, [user(bulky("keep going"))])
  let assert Ok(_settled) =
    api.await_result(rig.runtime, second, within_ms: 5000)
  let assert Ok(third) = api.prompt(rig.runtime, [user(bulky("and again"))])
  let assert Ok(_settled) =
    api.await_result(rig.runtime, third, within_ms: 5000)

  // Request one: a fresh strand, nothing reported yet. Request two: turn
  // one reported a usage inside the band. Request three: turn two's
  // usage crossed the threshold, the checkpoint compacted, and the
  // post-compaction context is small.
  let assert Ok(one) = process.receive(rig.contexts, within: 1000)
  let assert Ok(two) = process.receive(rig.contexts, within: 1000)
  let assert Ok(three) = process.receive(rig.contexts, within: 1000)
  assert reminded(one) == False
  assert reminded(two) == True
  assert reminded(three) == False
  // The reminder is transient: it was a transform on the request, not an
  // entry, so the tree holds no trace of it.
  assert list.length(compactions(rig.session)) == 1
  assert projected_mentions_reminder(rig.session) == False
  let _closed = api.close(rig.runtime)
}

// --- the before_compact note -----------------------------------------------
//
// The non-vetoing form of the `session_before_*` hooks the design note
// refused. The event fires once the compaction is decided; its answer is
// appended to the checkpoint, and there is no shape it can take that
// stops the compaction.

pub fn a_threshold_compaction_carries_its_note_into_the_checkpoint_test() {
  let cues = process.new_subject()
  let assert Ok(rig) = harness(Healthy, Noting(cues:))
    as "the harness must open"
  let assert Ok(first) = api.prompt(rig.runtime, [user(bulky("start"))])
  let assert Ok(_settled) =
    api.await_result(rig.runtime, first, within_ms: 5000)
  let assert Ok(second) = api.prompt(rig.runtime, [user(bulky("keep going"))])
  let assert Ok(_settled) =
    api.await_result(rig.runtime, second, within_ms: 5000)

  // Asked once, with the door this compaction came through named and
  // the preparation's own numbers on the cue.
  let assert Ok(cue) = process.receive(cues, within: 1000)
    as "the compaction asked for notes"
  assert cue.cause == effects.ThresholdCompaction
  assert cue.tokens_before > window - reserve
  assert cue.summarized_messages > 0
  assert cue.retained_messages > 0
  assert process.receive(cues, within: 0) == Error(Nil)

  // And the note reached the checkpoint that was actually published,
  // after the harness's own text.
  let assert [entry.CompactionEntry(summary:, ..)] = compactions(rig.session)
  assert string.contains(summary, scripted_note)
  let assert Ok(#(_head, tail)) = string.split_once(summary, scripted_note)
  assert string.contains(tail, "You wrote no notes") == False
  let _closed = api.close(rig.runtime)
}

pub fn an_overflow_compaction_names_its_own_cause_test() {
  let cues = process.new_subject()
  let assert Ok(rig) = harness(OverflowsOnce, Noting(cues:))
  let assert Ok(first) = api.prompt(rig.runtime, [user(bulky("start"))])
  let assert Ok(_settled) =
    api.await_result(rig.runtime, first, within_ms: 5000)
  let assert Ok(op) = api.prompt(rig.runtime, [user(bulky("keep going"))])
  let assert Ok(_settled) = api.await_result(rig.runtime, op, within_ms: 5000)

  let assert Ok(cue) = process.receive(cues, within: 1000)
    as "the overflow compaction asked for notes"
  assert cue.cause == effects.OverflowCompaction
  let _closed = api.close(rig.runtime)
}

// --- overflow recovery -----------------------------------------------------

// The provider says the context does not fit. With the overflow
// preparation wired, the machine compacts and retries the turn once —
// and it does so with no summarizer to reach, which is the outage that
// used to drain the run.
pub fn a_reported_overflow_compacts_and_retries_test() {
  let assert Ok(rig) = harness(OverflowsOnce, NoNotes)
  note(rig.session, "main", "decision", noted_decision)
  let assert Ok(first) = api.prompt(rig.runtime, [user(bulky("start"))])
  let assert Ok(_settled) =
    api.await_result(rig.runtime, first, within_ms: 5000)
  let assert Ok(op) = api.prompt(rig.runtime, [user(bulky("keep going"))])
  let assert Ok(last) = api.await_result(rig.runtime, op, within_ms: 5000)
  let assert operation.RunLastResult(outcome: operation.RunCompleted(..), ..) =
    last
  let assert [entry.CompactionEntry(summary:, from_hook: True, ..)] =
    compactions(rig.session)
  assert string.contains(summary, noted_decision)
  assert process.receive(rig.summaries, within: 0) == Error(Nil)
  let _closed = api.close(rig.runtime)
}

// --- the harness -----------------------------------------------------------

type Script {
  /// Every request settles; the second turn reports usage over the
  /// threshold.
  Healthy
  /// The first turn reports a usage inside the reminder band; the
  /// second crosses the threshold.
  NearsTheLimit
  /// The second and third turns both report usage over the threshold.
  CrossesTwice
  /// The first generation reports a context overflow; everything after
  /// it settles normally.
  OverflowsOnce
}

/// Whether this harness watches the `before_compact` seam.
type Notes {
  /// The production compaction hooks, untouched.
  NoNotes

  /// A `compaction_note` slot that records every cue it is asked about
  /// and answers with one note.
  Noting(cues: Subject(effects.CompactionCue))
}

/// The note a `Noting` harness answers every cue with.
const scripted_note = "<extension name=tracer>keep the migration plan</extension>"

type Rig {
  Rig(
    runtime: api.Runtime,
    session: session.Session,
    /// Every generation request's context, in dispatch order.
    contexts: Subject(List(AgentMessage)),
    /// One message per summary request the provider was asked — which
    /// must be none.
    summaries: Subject(Nil),
  )
}

fn harness(script: Script, notes: Notes) -> Result(Rig, String) {
  use opened <- result.try(
    session.open_memory(clock.stepping(from: 1_756_000_000_000, by: 3))
    |> result.map_error(fn(_) { "the memory session did not open" }),
  )
  use entropy <- result.try(start_entropy())
  use config <- result.try(wiring_config(opened))
  use turns <- result.try(start_turns())
  let contexts = process.new_subject()
  let summaries = process.new_subject()
  let effects_record =
    effects.Effects(
      clock: clock.stepping(from: 1_756_000_000_000, by: 3),
      entropy:,
      timers: effects.real_timers(),
      provider: scripted_provider(script, turns, contexts, summaries),
      tools: refusing_tools(),
      hooks: noting(wiring.compaction_hooks(config), notes),
    )
  let configuration =
    machine_strand.StrandConfiguration(
      model: machine_strand.ModelIdentity(provider: "acme", model_id: "loom-1"),
      thinking_level: machine_strand.ThinkingOff,
      active_tool_names: [],
    )
  let options = api.default_options(configuration)
  use runtime <- result.try(api.open(
    opened,
    effects_record,
    api.Options(
      ..options,
      poll_interval_ms: 20,
      settings: operation.RunSettings(
        ..options.settings,
        compaction: compaction_settings(),
      ),
    ),
  ))
  Ok(Rig(runtime:, session: opened, contexts:, summaries:))
}

// The production compaction hooks, with the `before_compact` slot
// replaced by a recorder when the test asked for one. Wrapping rather
// than rebuilding is what `client/extension/hooks.wire` does in
// production, so the test drives the same composition shape.
fn noting(hooks: effects.Hooks, notes: Notes) -> effects.Hooks {
  case notes {
    NoNotes -> hooks

    Noting(cues:) ->
      effects.Hooks(..hooks, compaction_note: fn(_operation, cue) {
        process.send(cues, cue)
        [scripted_note]
      })
  }
}

fn compaction_settings() -> operation.CompactionSettings {
  operation.CompactionSettings(
    enabled: True,
    reserve_tokens: reserve,
    keep_recent_tokens: keep_recent,
  )
}

fn wiring_config(opened: session.Session) -> Result(wiring.Config, String) {
  use broker_actor <- result.try(
    broker.start(
      broker.BrokerConfig(
        entropy: token.production_entropy(),
        clock: clock.fixed(at: 0),
        checkout: fn() { Error(exec.AllBusy(size: 0)) },
        checkin: fn(_helper) { Nil },
      ),
    )
    |> result.map_error(fn(_) { "the broker did not start" }),
  )
  let workspace = "/nonexistent/loom-compaction-test"
  Ok(
    wiring.Config(
      gateway: routed_gateway(),
      role: model.Main,
      facts: fn(_identity) { Error(Nil) },
      system: Some("you are an agent"),
      api: "acme-api",
      fallback_context_window: window,
      fallback_max_output_tokens: 1024,
      provider_timeout_ms: 2000,
      session: opened,
      compaction: compaction_settings(),
      broker: broker_actor,
      broker_timeout_ms: 1000,
      registry: tool_registry.built_in(None, None, None, None, None),
      workspace:,
      blob_root: workspace <> "/.blobs",
      base_policy: policy.workspace_default(workspace),
      escalations: escalate.none(),
      demand: exec.BestEffort,
      env: [],
      clock: clock.fixed(at: 0),
      entropy: fn() { 11 },
    ),
  )
}

fn routed_gateway() -> provider_gateway.Gateway {
  let identity =
    model.ResolvedModel(
      provider: "acme",
      model_id: "loom-1",
      thinking: model.ThinkingOff,
      context_window: window,
      max_output_tokens: 1024,
    )
  provider_gateway.new(
    transport: provider_test.silent(),
    secrets: secret.from_list([]),
    clock: clock.fixed(at: 0),
  )
  |> provider_gateway.add_provider(provider_gateway.AnthropicProvider(
    name: "acme",
    base_url: "https://acme.invalid",
    api_key_secret: "ACME_KEY",
  ))
  |> provider_gateway.route(model.Main, [identity])
}

// --- the scripted provider -------------------------------------------------

// Generations are answered by a turn counter rather than by inspecting
// the context, so the reported usage — the number the threshold actually
// reads — is scripted turn by turn. A summary request is refused
// terminally and reported, so a test can assert none was ever made.
fn scripted_provider(
  script: Script,
  turns: Subject(Subject(Int)),
  contexts: Subject(List(AgentMessage)),
  summaries: Subject(Nil),
) -> effects.ProviderSurface {
  effects.ProviderSurface(timeout_ms: 2000, request: fn(spec) {
    let events = process.new_subject()
    case spec {
      effects.SummaryRequest(..) -> {
        process.send(summaries, Nil)
        process.send(
          events,
          stream.Failed(error: stream.StreamError(
            api_error_type: "invalid_request_error",
            message: "this endpoint does not summarize",
          )),
        )
      }
      effects.PollRequest(..) -> settle(events, answer("polled", 1))
      effects.GenerationRequest(context:, ..) -> {
        process.send(contexts, context)
        settle(events, generation(script, next_turn(turns)))
      }
    }
    stream.immediate(events:, cancel: fn() { Nil })
  })
}

// What each script answers each turn with. Turn one sits under the
// threshold unless the script says otherwise; turn two crosses it; later
// turns report little, so a further compaction would have to come from
// the carried tail — or from the script asking for one.
fn generation(script: Script, turn: Int) -> AgentMessage {
  case script, turn {
    // The overflow script never crosses the threshold: its first turn
    // settles, its second reports overflow, and the retry after the
    // overflow compaction settles. Every compaction it produces came
    // from the overflow path.
    OverflowsOnce, 2 -> overflowed()
    OverflowsOnce, _ -> answer(bulky("answer"), 100)

    // Inside the band: past the reminder point, short of the threshold.
    NearsTheLimit, 1 -> answer(bulky("answer"), window - 2 * reserve + 500)
    NearsTheLimit, 2 -> answer(bulky("continuing"), window)
    NearsTheLimit, _ -> answer(bulky("answer"), 100)

    CrossesTwice, 2 -> answer(bulky("continuing"), window)
    CrossesTwice, 3 -> answer(bulky("continuing again"), window)
    CrossesTwice, _ -> answer(bulky("answer"), 100)

    Healthy, 2 -> answer(bulky("continuing"), window)
    Healthy, _ -> answer(bulky("answer"), 100)
  }
}

fn settle(events: Subject(stream.StreamEvent), reply: AgentMessage) -> Nil {
  case stream.settle(reply) {
    Ok(settled) ->
      process.send(
        events,
        stream.Settled(message: settled, usage: usage_of(reply)),
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

fn usage_of(reply: AgentMessage) -> message.Usage {
  case reply {
    message.AssistantMessage(usage:, ..) -> usage
    _ -> effects.zero_usage()
  }
}

fn answer(text: String, tokens: Int) -> AgentMessage {
  assistant(
    [message.AssistantText(text:, text_signature: None)],
    message.Stop,
    tokens,
    None,
  )
}

// The adapter's own overflow settlement: an `error` stop whose message
// matches the canonical pattern (spec §1.5).
fn overflowed() -> AgentMessage {
  assistant(
    [],
    message.Errored,
    0,
    Some("prompt is too long: 21000 tokens > 10000 maximum"),
  )
}

fn assistant(
  content: List(message.AssistantBlock),
  stop: message.StopReason,
  tokens: Int,
  error_message: Option(String),
) -> AgentMessage {
  message.AssistantMessage(
    content:,
    api: "acme-api",
    provider: "acme",
    model: "loom-1",
    response_model: None,
    response_id: None,
    diagnostics: None,
    usage: usage(tokens),
    stop_reason: stop,
    deferred: None,
    error_message:,
    raw_stop_reason: None,
    end_turn: case stop {
      message.Stop -> Some(True)
      _ -> None
    },
    timestamp: 0,
  )
}

fn usage(tokens: Int) -> message.Usage {
  message.Usage(
    input: tokens,
    output: 0,
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

// --- small helpers ---------------------------------------------------------

fn user(text: String) -> AgentMessage {
  message.UserMessage(
    content: [message.UserText(text:, text_signature: None)],
    timestamp: 0,
  )
}

// Writes one blackboard cell exactly where `agent_note` writes it.
fn note(opened: session.Session, strand: String, key: String, value: String) {
  let assert Ok(_committed) =
    storage.commit(
      opened.store,
      Tx(
        writes: [
          SetRegister(
            ns: register.FactCustom,
            key: "agent/" <> strand <> "/" <> key,
            value: register.RegisterValue(payload: json.String(value)),
          ),
        ],
        expected: [],
      ),
    )
    as "the fixture note must commit"
  Nil
}

// Whether a dispatched context ends with the notes reminder.
fn reminded(context: List(AgentMessage)) -> Bool {
  case list.last(context) {
    Ok(message.UserMessage(content: [message.UserText(text:, ..)], ..)) ->
      string.starts_with(text, checkpoint.reminder_prefix)
    _ -> False
  }
}

// Whether the durable projection carries the reminder anywhere.
fn projected_mentions_reminder(opened: session.Session) -> Bool {
  case session.strand_leaf(opened, "main") {
    Ok(Some(session.Cell(value: Some(leaf), ..))) ->
      case storage.scan_branch(opened.store, storage.branch_scan(from: leaf)) {
        Ok(entries) ->
          session.project_scan(entries)
          |> list.any(fn(projected) {
            case projected {
              message.UserMessage(content:, ..) ->
                list.any(content, fn(block) {
                  case block {
                    message.UserText(text:, ..) ->
                      string.contains(text, checkpoint.reminder_prefix)
                    message.UserImage(..) -> False
                  }
                })
              _ -> False
            }
          })
        Error(_) -> False
      }
    _ -> False
  }
}

// Every `CompactionEntry` in the session, oldest first.
fn compactions(opened: session.Session) -> List(entry.Entry) {
  case storage.scan_entries(opened.store, storage.entry_scan()) {
    Ok(entries) ->
      list.filter(entries, fn(item) {
        case item {
          entry.CompactionEntry(..) -> True
          _ -> False
        }
      })
    Error(_) -> []
  }
}

fn start_turns() -> Result(Subject(Subject(Int)), String) {
  case
    actor.new(0)
    |> actor.on_message(fn(count, reply: Subject(Int)) {
      process.send(reply, count + 1)
      actor.continue(count + 1)
    })
    |> actor.start
  {
    Ok(started) -> Ok(started.data)
    Error(_) -> Error("the turn counter did not start")
  }
}

fn next_turn(turns: Subject(Subject(Int))) -> Int {
  process.call(turns, waiting: 1000, sending: fn(reply) { reply })
}

fn start_entropy() -> Result(fn() -> Int, String) {
  case
    actor.new(1)
    |> actor.on_message(fn(next, reply: Subject(Int)) {
      process.send(reply, next)
      actor.continue(next + 1)
    })
    |> actor.start
  {
    Ok(counter) ->
      Ok(fn() {
        2_000_000
        + process.call(counter.data, waiting: 1000, sending: fn(reply) { reply })
        * 15_485_863
      })
    Error(_) -> Error("the entropy counter did not start")
  }
}
