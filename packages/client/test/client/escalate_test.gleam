//// Parking, and the raise policy under it (design §5.3, issue #4).
////
//// The subject is one refused `bash` call against a session whose base
//// policy is narrower than `bash` requires: composition narrows, the
//// broker refuses with the exact wanted diff, and what happens next is
//// what these tests are about. Every test drives the production seam —
//// `wiring.run_tool` over a real broker actor — rather than the seam's
//// internals, because the claim being made is about a production path.
////
//// The broker's pool seam never yields a helper, so a call that gets
//// *past* policy composition settles as "no sandbox helper available"
//// rather than as a policy refusal. That difference is the observable
//// this suite leans on: it separates "the re-clearance happened and
//// passed" from "the refusal stood" without needing a jail.
////
//// Time and the park loop's sleep are injected, so the deadline test
//// runs on logical time in microseconds. The clock is a
//// `clock.from_function` over a counter actor rather than
//// `clock.stepping`, for the reason the Agency suite documents: a
//// stepping clock returns a *new* clock per read and the seam holds one
//// clock value, so a stepping clock would freeze.

import broker/broker
import broker/exec
import broker/policy
import broker/token
import client/escalate
import client/grants
import client/serve
import client/summaries
import client/system_prompt
import client/wiring
import core/clock.{type Clock}
import core/ids
import core/json
import core/message
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/string
import machine/operation
import machine/strand.{
  type StrandConfiguration, ModelIdentity, StrandConfiguration,
}
import prompt/pack
import provider/gateway
import provider/http
import provider/model
import provider/secret
import provider/stream
import runtime/api
import runtime/effects
import runtime/escalation
import session/session
import simplifile

// --- the harness -----------------------------------------------------------

type Harness {
  Harness(
    runtime: api.Runtime,
    config: wiring.Config,
    escalations: escalate.Config,
    rests: Subject(CounterMessage),
  )
}

type CounterMessage {
  Next(reply: Subject(Int))
}

fn counter(from: Int, by: Int) -> Subject(CounterMessage) {
  let assert Ok(started) =
    actor.new(from)
    |> actor.on_message(fn(now, message) {
      let Next(reply:) = message
      process.send(reply, now)
      actor.continue(now + by)
    })
    |> actor.start
    as "the counter must start"
  started.data
}

fn bump(counter: Subject(CounterMessage)) -> Int {
  process.call(counter, waiting: 1000, sending: Next)
}

fn counting_clock(from: Int, by: Int) -> #(Clock, Subject(CounterMessage)) {
  let cell = counter(from, by)
  #(clock.from_function(fn() { bump(cell) }), cell)
}

fn dead_transport() -> http.Transport {
  http.Transport(send_streaming: fn(_request, _subject) { Nil })
}

fn routed_gateway() -> gateway.Gateway {
  gateway.new(
    transport: dead_transport(),
    secrets: secret.from_list([#("ACME_KEY", "unit-test-key")]),
    clock: clock.fixed(at: 0),
  )
  |> gateway.add_provider(gateway.AnthropicProvider(
    name: "acme",
    base_url: "https://acme.test",
    api_key_secret: "ACME_KEY",
  ))
  |> gateway.route(model.Main, [
    model.ResolvedModel(
      provider: "acme",
      model_id: "loom-1",
      thinking: model.ThinkingOff,
      context_window: 200_000,
      max_output_tokens: 8192,
    ),
  ])
}

// A real broker whose checkout seam never yields a helper: policy
// composition, budget, and token minting all run for real, and only the
// jail is absent.
fn helperless_broker() -> broker.Broker {
  let assert Ok(broker_actor) =
    broker.start(
      broker.BrokerConfig(
        entropy: token.production_entropy(),
        clock: clock.fixed(at: 0),
        checkout: fn() { Error(exec.AllBusy(size: 0)) },
        checkin: fn(_helper) { Nil },
      ),
    )
  broker_actor
}

fn workspace() -> String {
  let assert Ok(here) = simplifile.current_directory()
    as "the test needs a working directory"
  let workspace = here <> "/build/escalate/work"
  let assert Ok(Nil) = simplifile.create_directory_all(workspace)
    as "the test workspace must exist"
  workspace
}

fn summary_pack() -> pack.Pack {
  let assert Ok(#(decoded, [])) = system_prompt.summary_pack(None)
    as "the shipped summarization pack must load cleanly"
  decoded
}

fn configuration() -> StrandConfiguration {
  StrandConfiguration(
    model: ModelIdentity(provider: "acme", model_id: "loom-1"),
    thinking_level: strand.ThinkingOff,
    active_tool_names: ["bash"],
  )
}

// The whole stack over one memory session: a live runtime (so the holder
// has something to hold), the escalation seam, and a wiring config whose
// base policy is narrower than `bash` requires.
fn start_harness(
  interactive: fn() -> Bool,
  shape: fn(escalate.Config) -> escalate.Config,
) -> Harness {
  start_harness_with(interactive, shape, plane: True)
}

/// `plane: False` builds the same session with no holder standing up
/// under the seam's name — a host that wired no escalation plane at all.
fn start_harness_with(
  interactive: fn() -> Bool,
  shape: fn(escalate.Config) -> escalate.Config,
  plane plane: Bool,
) -> Harness {
  let workspace = workspace()
  let #(session_clock, _session_counter) = counting_clock(1_756_000_000_000, 1)
  let assert Ok(opened) = session.open_memory(session_clock)
    as "the memory session must open"
  let #(seam_clock, _seam_counter) = counting_clock(1_756_000_000_000, 10)
  // The park loop's sleep, counted rather than slept: `bump` returns the
  // number of slices taken so far, so a test can assert that a window
  // already closed was never polled at all.
  let rests = counter(0, 1)
  let name = process.new_name(prefix: "loom_escalate_test")
  let escalations =
    shape(
      escalate.Config(
        ..escalate.default_config(name, seam_clock),
        interactive:,
        poll_interval_ms: 1,
        rest: fn(_slice) {
          let _slices = bump(rests)
          Nil
        },
      ),
    )
  let config =
    wiring.Config(
      gateway: routed_gateway(),
      role: model.Main,
      system: None,
      api: "acme-api",
      fallback_context_window: 111_000,
      fallback_max_output_tokens: 2222,
      provider_timeout_ms: 1000,
      summary_role: model.Summarize,
      summary_pack: summary_pack(),
      summaries: summary_sink(),
      session: opened,
      compaction: operation.CompactionSettings(
        enabled: False,
        reserve_tokens: 0,
        keep_recent_tokens: 0,
      ),
      broker: helperless_broker(),
      broker_timeout_ms: 5000,
      registry: serve.registry(None, None),
      workspace:,
      blob_root: workspace <> "/.blobs",
      // Narrower than `bash` requires: it wants the whole filesystem
      // readable, and this grants only the workspace.
      base_policy: policy.workspace_default(workspace),
      escalations: escalate.seam(escalations),
      demand: exec.BestEffort,
      env: [#("PATH", "/usr/bin:/bin")],
      clock: session_clock,
      entropy: fn() { 7 },
    )
  let assert Ok(runtime) =
    api.open(
      opened,
      effects.Effects(
        clock: session_clock,
        entropy: fn() { 7 },
        timers: effects.real_timers(),
        provider: effects.ProviderSurface(timeout_ms: 1000, request: fn(_spec) {
          stream_handle_that_never_settles()
        }),
        tools: effects.ToolSurface(
          clear: fn(_query) {
            effects.ClearanceRefused(reason: "no clearance in this harness")
          },
          run: fn(run) { wiring.run_tool(config, run) },
          replay_still_safe: fn(_name) { False },
          execution_mode: fn(_name) { effects.ExclusiveExecution },
        ),
        hooks: effects.default_hooks(),
      ),
      api.Options(..api.default_options(configuration()), poll_interval_ms: 50),
    )
    as "the runtime must open"
  case plane {
    False -> Nil
    True -> {
      let assert Ok(_holder) = escalate.start(escalations, runtime)
        as "the escalation holder must start"
      Nil
    }
  }
  Harness(runtime:, config:, escalations:, rests:)
}

fn summary_sink() -> summaries.Summaries {
  let assert Ok(sink) = summaries.start() as "the summary sink must start"
  sink
}

// A provider that never answers; nothing in this suite generates.
fn stream_handle_that_never_settles() -> stream.StreamHandle {
  stream.StreamHandle(events: process.new_subject())
}

// --- the call under test ---------------------------------------------------

fn bash_run(call_id: String) -> effects.ToolRun {
  let #(operation, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 1))
  let arguments =
    json.Object([
      #("command", json.String("true")),
      #("timeout_ms", json.Int(120_000)),
    ])
  effects.ToolRun(
    operation:,
    step_id: "turn-1:tools",
    source_index: 0,
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

fn result_text(outcome: effects.ToolOutcome) -> String {
  let assert effects.ToolCompleted(result:, ..) = outcome
    as "a tool always completes in band"
  let assert message.ToolResultMessage(content:, ..) = result
    as "a tool result is a tool result message"
  content
  |> list.filter_map(fn(block) {
    case block {
      message.ToolResultText(text:, ..) -> Ok(text)
      _ -> Error(Nil)
    }
  })
  |> string.join(with: "\n")
}

// An approver that stands in for a human at a client: it waits for a
// pending record, reads the denial's wanted diff exactly as the gateway
// does, and approves precisely that.
fn approve_when_pending(
  runtime: api.Runtime,
  decide: fn(String) -> Nil,
) -> Nil {
  let _pid = process.spawn_unlinked(fn() { approve_loop(runtime, decide, 500) })
  Nil
}

fn approve_loop(
  runtime: api.Runtime,
  decide: fn(String) -> Nil,
  fuel: Int,
) -> Nil {
  case fuel <= 0 {
    True -> Nil
    False ->
      case api.escalations(runtime) {
        Ok([record, ..]) if record.status == escalation.Pending -> {
          decide(record.id)
          Nil
        }
        _ -> {
          process.sleep(2)
          approve_loop(runtime, decide, fuel - 1)
        }
      }
  }
}

fn approve_with_the_wanted_diff(runtime: api.Runtime) -> fn(String) -> Nil {
  fn(id) {
    let assert Ok(records) = api.escalations(runtime) as "the records must list"
    let assert Ok(record) = list.find(records, fn(r) { r.id == id })
      as "the record must be there"
    let assert Ok(decoded) = grants.decode_denial(record.denial)
      as "the stored denial must decode"
    let assert Ok(Nil) =
      api.approve_escalation(
        runtime,
        id,
        list.map(decoded.wanted, grants.encode),
      )
      as "the approval must commit"
    Nil
  }
}

// --- step 1: the grants channel, end to end in production ------------------

// The far end of the channel `runtime/effects.ClearanceQuery` opens.
// A run carrying no grants is refused on policy; the *same* run carrying
// the one grant that closes the diff clears composition and dies at the
// helper pool instead. Nothing in this test is simulated: it is
// `wiring.run_tool` over the real `bash` tool and a real broker, and the
// only difference between the two calls is what `ToolRun.grants` holds.
//
// Before the channel was threaded, `Ctx.grants` came from a boot-time
// config that production pinned to the empty list, so the second call
// was refused exactly like the first and an approved grant could not
// reach a policy decision by any route at all.
pub fn a_runs_grants_reach_policy_composition_test() {
  let harness =
    start_harness_with(fn() { False }, fn(config) { config }, plane: False)
  let bare = result_text(wiring.run_tool(harness.config, bash_run("call_1")))
  assert string.contains(bare, "policy refused")
  let widened =
    effects.ToolRun(..bash_run("call_2"), grants: [
      grants.encode(policy.GrantReadableRoot(path: "/")),
    ])
  let text = result_text(wiring.run_tool(harness.config, widened))
  assert string.contains(text, "no sandbox helper")
  assert !string.contains(text, "policy refused")
}

// --- step 2: parking -------------------------------------------------------

// The round trip the release is for. A policy refusal holds the call
// open; a human approves it; the *same* call is re-cleared under the
// widened policy and resumes. Without parking the call settles as a
// policy refusal and the approval — minted against this call's id —
// can never be spent by anything, because the model's retry would
// arrive under a new id.
//
// The resumed call gets past composition and dies at the pool instead,
// which is the observable: "no sandbox helper" is a message only a call
// that cleared policy can produce.
pub fn an_approval_resumes_the_parked_call_test() {
  let harness = start_harness(fn() { True }, fn(config) { config })
  approve_when_pending(
    harness.runtime,
    approve_with_the_wanted_diff(harness.runtime),
  )
  let text = result_text(wiring.run_tool(harness.config, bash_run("call_1")))
  assert string.contains(text, "no sandbox helper")
  assert !string.contains(text, "policy refused")
  // One approval bought exactly one widened execution, and the record
  // says so.
  let assert Ok([record]) = api.escalations(harness.runtime)
    as "one record must exist"
  assert record.status == escalation.Consumed
}

// A denial un-parks the call just as an approval does, and the model
// gets the in-band refusal it would have got without any of this.
pub fn a_denial_settles_the_parked_call_in_band_test() {
  let harness = start_harness(fn() { True }, fn(config) { config })
  approve_when_pending(harness.runtime, fn(id) {
    let assert Ok(Nil) = api.deny_escalation(harness.runtime, id)
      as "the denial must commit"
    Nil
  })
  let text = result_text(wiring.run_tool(harness.config, bash_run("call_1")))
  assert string.contains(text, "policy refused")
  let assert Ok([record]) = api.escalations(harness.runtime)
    as "one record must exist"
  assert record.status == escalation.Rejected
}

// Nobody decides. The call must not hang: the park window closes on the
// injected clock and the refusal settles in band, leaving the record
// pending for whoever reviews it later.
pub fn an_undecided_park_settles_when_its_window_closes_test() {
  let harness =
    start_harness(fn() { True }, fn(config) {
      escalate.Config(..config, park_timeout_ms: 25)
    })
  let text = result_text(wiring.run_tool(harness.config, bash_run("call_1")))
  assert string.contains(text, "policy refused")
  let assert Ok([record]) = api.escalations(harness.runtime)
    as "one record must exist"
  assert record.status == escalation.Pending
  // It really did wait, rather than falling straight through.
  assert bump(harness.rests) >= 1
}

// The park window is bounded by the call's own budget as well as by the
// configured timeout, because a re-clearance past the deadline the first
// clearance was minted against is a `BudgetRefused`, not a resumption.
// Here the tool asks for a 1 ms budget and the seam is configured to
// park for an hour: the shorter one has to win.
pub fn a_park_never_outlives_the_calls_budget_test() {
  let harness =
    start_harness(fn() { True }, fn(config) {
      escalate.Config(..config, park_timeout_ms: 3_600_000)
    })
  let run = bash_run("call_1")
  let arguments =
    json.Object([
      #("command", json.String("true")),
      #("timeout_ms", json.Int(1)),
    ])
  let text =
    result_text(wiring.run_tool(
      harness.config,
      effects.ToolRun(
        ..run,
        arguments:,
        call: message.ToolCall(..run.call, arguments:),
      ),
    ))
  assert string.contains(text, "policy refused")
  // The window was shut before the first slice: the call never polled.
  assert bump(harness.rests) == 0
}

// An approval names one call. A *different* call of the same tool
// wanting the same diff lands on the same record — that is the
// deduplication working — and must still not spend it, because the
// scope names the call a human said yes to. Skipping it can only
// narrow, which is the safe direction.
pub fn an_approval_is_spent_only_by_the_call_it_names_test() {
  let harness = start_harness(fn() { True }, fn(config) { config })
  // Raise for `call_1` and approve it, with nobody parked.
  let headless =
    escalate.Config(..harness.escalations, interactive: fn() { False })
  let recording =
    wiring.Config(..harness.config, escalations: escalate.seam(headless))
  let _first = wiring.run_tool(recording, bash_run("call_1"))
  let assert Ok([raised]) = api.escalations(harness.runtime)
    as "one record must exist"
  approve_with_the_wanted_diff(harness.runtime)(raised.id)
  // A sibling call finds the approval and leaves it alone.
  let sibling = result_text(wiring.run_tool(harness.config, bash_run("call_2")))
  assert string.contains(sibling, "policy refused")
  let assert Ok([still]) = api.escalations(harness.runtime)
    as "the record must survive"
  assert still.status == escalation.Approved
  // The call it was minted for spends it.
  let owner = result_text(wiring.run_tool(harness.config, bash_run("call_1")))
  assert string.contains(owner, "no sandbox helper")
  let assert Ok([spent]) = api.escalations(harness.runtime)
    as "the record must survive"
  assert spent.status == escalation.Consumed
}

// --- step 3: the raise policy ---------------------------------------------

// Every policy refusal raises a durable record, attributed to the exact
// call it was raised for — including in a session with nobody attached,
// where the record is an audit line rather than a prompt.
pub fn every_policy_refusal_raises_a_scoped_record_test() {
  let harness = start_harness(fn() { False }, fn(config) { config })
  let run = bash_run("call_1")
  let text = result_text(wiring.run_tool(harness.config, run))
  // The in-band error stands alongside the raised record: the model is
  // told what happened whether or not anyone ever looks at the queue.
  assert string.contains(text, "policy refused")
  let assert Ok([record]) = api.escalations(harness.runtime)
    as "one record must exist"
  assert record.status == escalation.Pending
  assert record.scope
    == Some(escalation.CallScope(
      operation: run.operation,
      strand: "main",
      step_id: "turn-1:tools",
      source_index: 0,
      call_id: "call_1",
    ))
}

// A model that reads the in-band refusal and retries produces a new call
// id every time. The record id is derived from `{strand, tool, wanted
// diff}` instead, so a retry loop lands on the record that is already
// there rather than filling the queue with one row per attempt.
pub fn a_retry_loop_dedupes_onto_one_record_test() {
  let harness = start_harness(fn() { False }, fn(config) { config })
  let _first = wiring.run_tool(harness.config, bash_run("call_1"))
  let _second = wiring.run_tool(harness.config, bash_run("call_2"))
  let _third = wiring.run_tool(harness.config, bash_run("call_3"))
  let assert Ok(records) = api.escalations(harness.runtime)
    as "the records must list"
  assert list.length(records) == 1
  // And the surviving record still names the call it was raised for, so
  // the approval a human gives is spendable by that call and no other.
  let assert [record] = records
  let assert Some(scope) = record.scope as "the record must be scoped"
  assert scope.call_id == "call_1"
}

// The same derivation, stated directly: identical coordinates give the
// same id, and any of the three inputs moving gives a different one.
pub fn the_record_id_is_deterministic_test() {
  let wanted = [policy.GrantReadableRoot(path: "/")]
  let id = escalate.record_id("main", "bash", wanted)
  assert escalate.record_id("main", "bash", wanted) == id
  assert escalate.record_id("sub:1", "bash", wanted) != id
  assert escalate.record_id("main", "grep", wanted) != id
  assert escalate.record_id("main", "bash", [policy.GrantEnv(name: "PATH")])
    != id
  // Grant order is not part of the identity: the same diff written two
  // ways is the same want.
  let pair = [
    policy.GrantReadableRoot(path: "/"),
    policy.GrantEnv(name: "PATH"),
  ]
  assert escalate.record_id("main", "bash", pair)
    == escalate.record_id("main", "bash", list.reverse(pair))
}

// A session nobody is attached to records the refusal and settles it,
// rather than holding a call open for a decision that can never come.
// This is the interactive flag, and it decides *parking* only — never
// whether the record is written.
pub fn a_headless_session_records_but_never_parks_test() {
  let harness =
    start_harness(fn() { False }, fn(config) {
      escalate.Config(..config, park_timeout_ms: 3_600_000, rest: fn(_slice) {
        panic as "a headless refusal must not park"
      })
    })
  let text = result_text(wiring.run_tool(harness.config, bash_run("call_1")))
  assert string.contains(text, "policy refused")
  let assert Ok([_record]) = api.escalations(harness.runtime)
    as "the record is written anyway"
}

// A seam with no runtime behind it — a host that wired no escalation
// plane at all — changes nothing: the refusal settles exactly as it did
// before any of this existed.
pub fn a_session_without_the_plane_settles_as_before_test() {
  let harness =
    start_harness_with(fn() { True }, fn(config) { config }, plane: False)
  let text = result_text(wiring.run_tool(harness.config, bash_run("call_1")))
  assert string.contains(text, "policy refused")
  let assert Ok([]) = api.escalations(harness.runtime)
    as "nothing is recorded without a plane"
}
