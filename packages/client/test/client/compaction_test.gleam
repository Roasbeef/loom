//// Compaction, end to end, through the production hooks.
////
//// `client/wiring`'s compaction seams are the whole of what makes
//// compaction *run*: before them a threshold never fired, every
//// structural decision declined, and an overflowing run drained as
//// `context_overflow`. These tests drive a real session and a real
//// runtime with those seams installed and a scripted provider behind
//// them, and assert on what lands in the tree — a `CompactionEntry`
//// whose summary is the text the provider produced, never a string this
//// test supplied.
////
//// The provider is scripted rather than routed at a network, but it is
//// reached the way production reaches one: through
//// `wiring.recording_summaries`, the same wrapper `build_effects`
//// composes, so the sink the `summary_progress` hook reads is filled by
//// the code that fills it in production.

import broker/broker
import broker/exec
import broker/policy
import broker/token
import client/escalate
import client/summaries
import client/system_prompt
import client/wiring
import core/clock
import core/entry
import core/message.{type AgentMessage}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import machine/operation
import machine/strand as machine_strand
import prompt/pack
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

// The text the scripted provider answers a summary request with. If a
// `CompactionEntry` carries this, a provider produced it — the hooks did
// not invent one.
const scripted_summary = "[from the provider] the fetcher grew a retry"

// Small enough that one scripted turn's reported usage crosses it.
const window = 10_000

const reserve = 2000

// Two of the harness's turns fit; a third does not, so a compaction
// always has something older than the tail to summarize.
const keep_recent = 500

// A message of roughly 400 estimated tokens (characters over four), so
// the keep-recent budget is a budget rather than a formality.
fn bulky(label: String) -> String {
  label <> ": " <> string.repeat("context ", 200)
}

// --- the threshold ---------------------------------------------------------

pub fn a_crossed_threshold_compacts_with_the_providers_summary_test() {
  let assert Ok(#(runtime, opened)) = harness(Healthy, NoNotes)
    as "the harness must open"
  // Turn one settles under the threshold; turn two reports usage above
  // it, so the checkpoint after it compacts.
  let assert Ok(first) = api.prompt(runtime, [user(bulky("start the work"))])
  let assert Ok(_settled) = api.await_result(runtime, first, within_ms: 5000)
  let assert Ok(second) = api.prompt(runtime, [user(bulky("keep going"))])
  let assert Ok(_settled) = api.await_result(runtime, second, within_ms: 5000)

  let assert [entry.CompactionEntry(summary:, from_hook:, tokens_before:, ..)] =
    compactions(opened)
  assert summary == scripted_summary
  // The entry is the machine's own, not a hook's: a summary a hook
  // supplied would be marked as such.
  assert from_hook == False
  assert tokens_before > window - reserve
  let _closed = api.close(runtime)
}

// The guard against a compaction loop: the entry a compaction writes
// carries a copy of the retained tail, whose assistant usage describes
// the context that was *replaced*. A fold that read it would compact on
// every checkpoint for the rest of the session.
pub fn a_finished_compaction_does_not_re_fire_the_threshold_test() {
  let assert Ok(#(runtime, opened)) = harness(Healthy, NoNotes)
  let assert Ok(first) = api.prompt(runtime, [user(bulky("start the work"))])
  let assert Ok(_settled) = api.await_result(runtime, first, within_ms: 5000)
  let assert Ok(second) = api.prompt(runtime, [user(bulky("keep going"))])
  let assert Ok(_settled) = api.await_result(runtime, second, within_ms: 5000)
  assert list.length(compactions(opened)) == 1
  // A third turn, whose own reported usage is small, must not compact
  // again on the strength of the pre-compaction number in the tail.
  let assert Ok(third) = api.prompt(runtime, [user(bulky("and once more"))])
  let assert Ok(_settled) = api.await_result(runtime, third, within_ms: 5000)
  assert list.length(compactions(opened)) == 1
  let _closed = api.close(runtime)
}

// --- the before_compact note -----------------------------------------------
//
// The non-vetoing form of the `session_before_*` hooks the design note
// refused. The event fires once the compaction is decided and before
// the summary generation starts; its answer is appended to the
// summarizer's input and there is no shape it can take that stops the
// compaction.

pub fn a_threshold_compaction_carries_its_note_to_the_summarizer_test() {
  let cues = process.new_subject()
  let delivered = process.new_subject()
  let assert Ok(#(runtime, opened)) =
    harness(Healthy, Noting(cues:, delivered:))
    as "the harness must open"
  let assert Ok(first) = api.prompt(runtime, [user(bulky("start the work"))])
  let assert Ok(_settled) = api.await_result(runtime, first, within_ms: 5000)
  let assert Ok(second) = api.prompt(runtime, [user(bulky("keep going"))])
  let assert Ok(_settled) = api.await_result(runtime, second, within_ms: 5000)

  // Asked once, with the door this compaction came through named and
  // the preparation's own numbers on the cue.
  let assert Ok(cue) = process.receive(cues, within: 1000)
    as "the compaction asked for notes"
  assert cue.cause == effects.ThresholdCompaction
  assert cue.tokens_before > window - reserve
  assert cue.summarized_messages > 0
  assert cue.retained_messages > 0

  // Asked once, and only once: one dispatched summary request is one
  // ask, so a second cue here would mean the slot fired somewhere other
  // than the dispatch.
  assert process.receive(cues, within: 0) == Error(Nil)

  // And the note reached the request the summarizer was actually sent.
  assert process.receive(delivered, within: 1000) == Ok([scripted_note])

  // The compaction happened anyway, which is the whole ruling: a note
  // is an aside, never a veto.
  assert list.length(compactions(opened)) == 1
  let _closed = api.close(runtime)
}

pub fn an_overflow_compaction_names_its_own_cause_test() {
  let cues = process.new_subject()
  let delivered = process.new_subject()
  let assert Ok(#(runtime, _opened)) =
    harness(OverflowsOnce, Noting(cues:, delivered:))
  let assert Ok(first) = api.prompt(runtime, [user(bulky("start the work"))])
  let assert Ok(_settled) = api.await_result(runtime, first, within_ms: 5000)
  let assert Ok(op) = api.prompt(runtime, [user(bulky("keep going"))])
  let assert Ok(_settled) = api.await_result(runtime, op, within_ms: 5000)

  let assert Ok(cue) = process.receive(cues, within: 1000)
    as "the overflow compaction asked for notes"
  assert cue.cause == effects.OverflowCompaction
  let _closed = api.close(runtime)
}

// A re-dispatched summary asks again. This is the replay rule the slot
// is documented against, driven rather than asserted from prose: the
// note is transient input to a request whose consuming commit is the
// summary, so an attempt that fails before that commit re-dispatches and
// re-asks, and the second answer is as good as the first because neither
// was written down. The ask lives at the dispatch for exactly this
// reason, and a cue asked once here would mean it had moved back to the
// decision.
pub fn a_re_dispatched_compaction_asks_for_its_notes_again_test() {
  let cues = process.new_subject()
  let delivered = process.new_subject()
  let assert Ok(#(runtime, opened)) =
    harness(SummariesFlapOnce, Noting(cues:, delivered:))
    as "the harness must open"
  let assert Ok(first) = api.prompt(runtime, [user(bulky("start the work"))])
  let assert Ok(_settled) = api.await_result(runtime, first, within_ms: 5000)
  let assert Ok(second) = api.prompt(runtime, [user(bulky("keep going"))])
  let assert Ok(_settled) = api.await_result(runtime, second, within_ms: 8000)

  // Two dispatches, two asks: the attempt the summarizer dropped, and
  // the one that landed.
  let assert Ok(_first_cue) = process.receive(cues, within: 1000)
    as "the first attempt asked for notes"
  let assert Ok(_second_cue) = process.receive(cues, within: 1000)
    as "the re-dispatched attempt asked again"
  assert process.receive(cues, within: 0) == Error(Nil)

  // And both requests carried the note, so the retry is a whole request
  // rebuilt rather than a resend of what the first attempt assembled.
  assert process.receive(delivered, within: 0) == Ok([scripted_note])
  assert process.receive(delivered, within: 0) == Ok([scripted_note])
  assert list.length(compactions(opened)) == 1
  let _closed = api.close(runtime)
}

// --- overflow recovery -----------------------------------------------------

// The provider says the context does not fit. With the overflow
// preparation wired, the machine compacts and retries the turn once; with
// the default `EmptyPreparation` it drained the whole run as
// `context_overflow`.
pub fn a_reported_overflow_compacts_and_retries_test() {
  let assert Ok(#(runtime, opened)) = harness(OverflowsOnce, NoNotes)
  let assert Ok(first) = api.prompt(runtime, [user(bulky("start the work"))])
  let assert Ok(_settled) = api.await_result(runtime, first, within_ms: 5000)
  let assert Ok(op) = api.prompt(runtime, [user(bulky("keep going"))])
  let assert Ok(last) = api.await_result(runtime, op, within_ms: 5000)
  let assert operation.RunLastResult(outcome: operation.RunCompleted(..), ..) =
    last
  let assert [entry.CompactionEntry(summary:, ..)] = compactions(opened)
  assert summary == scripted_summary
  let _closed = api.close(runtime)
}

// A summary attempt that fails retryably is retried, and the compaction
// still lands. This is the production-seam half of "recover mid-
// compaction": a summary the sink does not hold — a dropped connection
// here, a reaped effect or a crashed strand in the field — starts the
// attempt over rather than publishing an empty summary.
pub fn a_retryable_summary_failure_is_retried_test() {
  let assert Ok(#(runtime, opened)) = harness(SummariesFlapOnce, NoNotes)
  let assert Ok(first) = api.prompt(runtime, [user(bulky("start the work"))])
  let assert Ok(_settled) = api.await_result(runtime, first, within_ms: 5000)
  let assert Ok(second) = api.prompt(runtime, [user(bulky("keep going"))])
  let assert Ok(_settled) = api.await_result(runtime, second, within_ms: 8000)
  let assert [entry.CompactionEntry(summary:, ..)] = compactions(opened)
  assert summary == scripted_summary
  let _closed = api.close(runtime)
}

// --- what a lost summary does ----------------------------------------------

// A summary request that fails terminally must fail the *structural
// task*, not publish an empty summary. The run drains, and the tree gains
// no compaction — a `CompactionEntry` with an empty summary would have
// replaced the conversation with nothing.
pub fn a_terminally_failed_summary_publishes_nothing_test() {
  let assert Ok(#(runtime, opened)) = harness(SummariesRefuse, NoNotes)
  let assert Ok(first) = api.prompt(runtime, [user(bulky("start the work"))])
  let assert Ok(_settled) = api.await_result(runtime, first, within_ms: 5000)
  let assert Ok(second) = api.prompt(runtime, [user(bulky("keep going"))])
  let assert Ok(_settled) = api.await_result(runtime, second, within_ms: 8000)
  assert compactions(opened) == []
  let _closed = api.close(runtime)
}

// --- the harness -----------------------------------------------------------

type Script {
  /// Every request settles; the second turn reports usage over the
  /// threshold.
  Healthy
  /// The first generation reports a context overflow; everything after
  /// it settles normally.
  OverflowsOnce
  /// Summary requests fail terminally.
  SummariesRefuse
  /// The first summary request fails retryably; the next succeeds.
  SummariesFlapOnce
}

/// Whether this harness watches the `before_compact` seam.
///
/// A variant rather than two harnesses: everything else about the setup
/// is identical, and the tests that do not care about notes should not
/// have to say so in more than a word.
type Notes {
  /// The production compaction hooks, untouched.
  NoNotes

  /// A `compaction_note` slot that records every cue it is asked about
  /// and answers with one note, plus a sink the scripted provider
  /// reports each summary request's notes to.
  Noting(cues: Subject(effects.CompactionCue), delivered: Subject(List(String)))
}

/// The note a `Noting` harness answers every cue with.
const scripted_note = "<extension name=tracer>keep the migration plan</extension>"

fn harness(
  script: Script,
  notes: Notes,
) -> Result(#(api.Runtime, session.Session), String) {
  use opened <- result.try(
    session.open_memory(clock.stepping(from: 1_756_000_000_000, by: 3))
    |> result.map_error(fn(_) { "the memory session did not open" }),
  )
  use entropy <- result.try(start_entropy())
  use sink <- result.try(
    summaries.start()
    |> result.map_error(fn(_) { "the summary sink did not start" }),
  )
  use config <- result.try(wiring_config(opened, sink))
  use turns <- result.try(start_turns())
  use summaries_seen <- result.try(start_turns())
  let effects_record =
    effects.Effects(
      clock: clock.stepping(from: 1_756_000_000_000, by: 3),
      entropy:,
      timers: effects.real_timers(),
      provider: wiring.recording_summaries(
        scripted_provider(script, turns, summaries_seen, notes),
        into: sink,
      ),
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
  Ok(#(runtime, opened))
}

// The production compaction hooks, with the `before_compact` slot
// replaced by a recorder when the test asked for one. Wrapping rather
// than rebuilding is what `client/extension/hooks.wire` does in
// production, so the test drives the same composition shape.
fn noting(hooks: effects.Hooks, notes: Notes) -> effects.Hooks {
  case notes {
    NoNotes -> hooks

    Noting(cues:, delivered: _) ->
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

fn wiring_config(
  opened: session.Session,
  sink: summaries.Summaries,
) -> Result(wiring.Config, String) {
  use loaded <- result.try(system_prompt.summary_pack(None))
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
      summary_role: model.Summarize,
      summary_pack: summary_pack(loaded),
      summaries: sink,
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

fn summary_pack(loaded: #(pack.Pack, List(String))) -> pack.Pack {
  loaded.0
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
  |> provider_gateway.route(model.Summarize, [identity])
}

// --- the scripted provider -------------------------------------------------

// Generations are answered by a turn counter rather than by inspecting
// the context, so the reported usage — the number the threshold actually
// reads — is scripted turn by turn.
fn scripted_provider(
  script: Script,
  turns: Subject(Subject(Int)),
  summaries_seen: Subject(Subject(Int)),
  notes: Notes,
) -> effects.ProviderSurface {
  effects.ProviderSurface(timeout_ms: 2000, request: fn(spec) {
    let events = process.new_subject()
    report_notes(spec, notes)
    case spec {
      effects.SummaryRequest(..) ->
        case script, next_turn(summaries_seen) {
          SummariesRefuse, _ ->
            process.send(
              events,
              stream.Failed(error: stream.StreamError(
                api_error_type: "invalid_request_error",
                message: "this endpoint does not summarize",
              )),
            )
          SummariesFlapOnce, 1 ->
            process.send(
              events,
              stream.Failed(error: stream.TransportFailed(
                reason: "the summarizer dropped the connection",
              )),
            )
          _, _ -> settle(events, answer(scripted_summary, 40))
        }
      effects.PollRequest(..) -> settle(events, answer("polled", 1))
      effects.GenerationRequest(..) -> {
        let turn = next_turn(turns)
        case script, turn {
          // The overflow script never crosses the threshold: its first
          // turn settles, its second reports overflow, and the retry
          // after the overflow compaction settles. Every compaction it
          // produces came from the overflow path.
          OverflowsOnce, 2 -> settle(events, overflowed())
          OverflowsOnce, _ -> settle(events, answer(bulky("answer"), 100))
          // Otherwise turn one sits under the threshold and turn two
          // crosses it; later turns report little, so a second
          // compaction would have to come from the carried tail.
          _, 2 -> settle(events, answer(bulky("continuing"), window))
          _, _ -> settle(events, answer(bulky("answer"), 100))
        }
      }
    }
    stream.immediate(events:, cancel: fn() { Nil })
  })
}

// What a dispatched summary request actually carries, reported from the
// provider surface — the far side of the whole path, so a note that was
// gathered but never threaded into the spec fails here rather than
// passing on the strength of the hook having been asked.
fn report_notes(spec: effects.RequestSpec, notes: Notes) -> Nil {
  case spec, notes {
    effects.SummaryRequest(notes: carried, ..), Noting(cues: _, delivered:) ->
      process.send(delivered, carried)

    effects.SummaryRequest(..), NoNotes
    | effects.GenerationRequest(..), _
    | effects.PollRequest(..), _
    -> Nil
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
