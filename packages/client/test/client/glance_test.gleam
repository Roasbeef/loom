//// The glance loop against a real runtime: the usage hook casts, the
//// machine books and launches, and a scripted summarizer's answer lands in
//// the strand's `client/glance/` cell.
////
//// The runtime is real because what the loop does is read `op.meta`, a
//// strand's state and branch straight off the store and commit a reserved
//// fact through the writer, and none of those can be faked without testing
//// the fake. The provider hangs, so every operation the fixtures open stays
//// live for the length of a test, and the summarizer is a script that
//// records each request it is sent.

import client/distill
import client/glance
import client/glancepace
import core/clock
import core/entry
import core/glance as glance_cell
import core/ids.{type OpId}
import core/message
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor as otp_actor
import gleam/result
import gleam/string
import gleam/time/timestamp
import machine/strand as machine_strand
import provider/gateway as provider_gateway
import provider/model
import provider/secret
import provider/stream
import runtime/api
import runtime/effects
import runtime/hooks
import session/session
import support/addresses
import support/provider as provider_test
import telemetry/log
import weft/poll
import weft/registry as address

const sub = "sub:main/audit-1a2b"

// --- the pure edges ----------------------------------------------------------

// The terminal covers the primary and the advisor itself; every other
// strand is summarized.
pub fn the_primary_and_the_advisor_are_not_watched_test() {
  assert glance.is_watched(sub)
  assert glance.is_watched("review")
  assert !glance.is_watched("main")
  assert !glance.is_watched("advisor")
}

// The figure a glance carries is the context the newest row measured, and
// an adjustment row measures nothing.
pub fn the_context_is_the_rows_whole_prompt_and_answer_test() {
  assert glance.context_of(a_row(False)) == Some(100 + 30 + 5 + 7)
  assert glance.context_of(a_row(True)) == None
}

// A new user with no role table still gets a glance: the summarizer
// falls back from `summarize` to `subagent` to `main`, always with thinking
// off, and only a catalogue that routes nothing has no target.
pub fn the_summarizer_falls_back_to_the_routed_roles_test() {
  let off = Some(model.ThinkingOff)

  assert glance.target(routing([model.Main, model.Subagent, model.Summarize]))
    == Ok(model.ForRole(role: model.Summarize, thinking: off))
  assert glance.target(routing([model.Main, model.Subagent]))
    == Ok(model.ForRole(role: model.Subagent, thinking: off))
  assert glance.target(routing([model.Main]))
    == Ok(model.ForRole(role: model.Main, thinking: off))
  let assert Error(_reason) = glance.target(routing([]))
    as "a catalogue that routes nothing has no target"
}

// --- the loop ------------------------------------------------------------------

// The first step of a sub-agent's operation produces a glance for it, and
// a step on the primary produces nothing. The primary's step is cast
// first, from this same process, so by the time the sub-agent's cell
// exists the machine has already handled — and skipped — the primary's.
pub fn a_sub_agent_step_writes_a_glance_and_main_does_not_test() {
  let assert Ok(rig) = a_rig(glancepace.default_pace, fixed_clock())
    as "the glance rig must open"
  let hooked = glance.hooks(hooks.build(hooks.new()), rig.name)

  hooked.usage(rig.primary, a_row(False))
  hooked.usage(rig.child, a_row(False))

  let assert Ok(written) = await_glance(rig, fn(_cell) { True })
    as "the sub-agent's glance must be written"
  assert written.operation == ids.op_id_to_string(rig.child)
  assert written.title == "Audit the funding flow"
  assert written.summary == "Reading fundeeProcessOpenChannel in manager.go"
  assert written.tokens == 142
  assert written.at == 1_756_000_000_000

  // One request, about the sub-agent's own task, asking for a title.
  let assert [request] = requests(rig)
    as "exactly one request must have been made"
  assert string.contains(request, "Audit the channel funding flow")
  assert string.contains(request, "TITLE:")
  assert glance_of(rig, "main") == Error(Nil)
  stop(rig)
}

// A second step inside the interval is not asked about at once; the
// machine's own wake asks once the interval has passed, reusing the title
// it already wrote and asking only for the "now" line. Deleting the wake's
// arming fails this test, which is what makes the timer a tested one
// (`docs/weft.md` rule 7). The interval is wide enough that the scripted
// first round trip cannot outlast it even on a loaded box: if it did, the
// second step would launch on its own arrival and the test would pass with
// no timer at all.
pub fn a_later_step_is_summarized_on_the_wake_test() {
  let pace = glancepace.Pace(..glancepace.default_pace, every_ms: 1500)
  let assert Ok(rig) = a_rig(pace, wall_clock()) as "the glance rig must open"
  let hooked = glance.hooks(hooks.build(hooks.new()), rig.name)

  hooked.usage(rig.child, a_row(False))
  let assert Ok(_first) = await_glance(rig, fn(_cell) { True })
    as "the first glance must be written"

  hooked.usage(rig.child, a_row(False))
  let assert Ok(refreshed) =
    await_glance(rig, fn(cell) { cell.summary == "Editing funding.go" })
    as "the wake must ask again once the interval passed"
  assert refreshed.title == "Audit the funding flow"

  let assert [_first, second] = requests(rig)
    as "exactly two requests must have been made"
  assert !string.contains(second, "TITLE:")
  assert string.contains(second, "\"Audit the funding flow\"")
  stop(rig)
}

// --- the rig -------------------------------------------------------------------

type Rig {
  Rig(
    runtime: api.Runtime,
    name: address.Address(glance.Message),
    primary: OpId,
    child: OpId,
    asked: Subject(String),
  )
}

// A runtime whose provider hangs, a primary run and a sub-agent run both
// left open on it, and the loop started over a scripted summarizer that
// answers with a title first and a new "now" line on every later request.
fn a_rig(
  pace: glancepace.Pace,
  loop_clock: clock.Clock,
) -> Result(Rig, String) {
  use opened <- result.try(
    session.open_memory(fixed_clock())
    |> result.replace_error("the memory session did not open"),
  )
  use entropy <- result.try(start_entropy())
  use runtime <- result.try(
    api.open(
      opened,
      effects.Effects(
        clock: fixed_clock(),
        entropy:,
        timers: effects.real_timers(),
        provider: hanging_provider(),
        tools: refusing_tools(),
        hooks: effects.default_hooks(),
      ),
      api.default_options(a_configuration()),
    )
    |> result.map_error(string.inspect),
  )
  use primary <- result.try(
    api.prompt(runtime, [user("Refactor the router")])
    |> result.map_error(string.inspect),
  )
  use child <- result.try(
    api.create_strand(
      runtime,
      named: sub,
      configuration: a_configuration(),
      at: None,
      brief: [user("Audit the channel funding flow for panics")],
    )
    |> result.map_error(string.inspect),
  )

  let asked = process.new_subject()
  let name = addresses.new()
  use _started <- result.try(
    glance.start(glance.Wiring(
      session: opened,
      runtime: fn() { Ok(runtime) },
      summarizer: scripted(asked),
      clock: loop_clock,
      pace:,
      logger: log.discard(),
      name:,
    ))
    |> result.replace_error("the glance machine did not start"),
  )
  Ok(Rig(runtime:, name:, primary:, child:, asked:))
}

// Titles the task on a first request and says something new on each later
// one, so a test can tell a refresh from the first answer.
fn scripted(asked: Subject(String)) -> distill.Distiller {
  distill.Distiller(ask: fn(request) {
    process.send(asked, request)
    let text = case string.contains(request, "TITLE:") {
      True ->
        "TITLE: Audit the funding flow\n"
        <> "NOW: Reading fundeeProcessOpenChannel in manager.go"
      False -> "NOW: Editing funding.go"
    }
    Ok(distill.Answer(text:, usage: effects.zero_usage()))
  })
}

fn requests(rig: Rig) -> List(String) {
  case process.receive(rig.asked, 0) {
    Ok(request) -> [request, ..requests(rig)]
    Error(Nil) -> []
  }
}

fn await_glance(
  rig: Rig,
  wanted: fn(glance_cell.Glance) -> Bool,
) -> Result(glance_cell.Glance, Nil) {
  case
    poll.until(within: 5000, every: 20, attempt: fn() {
      case glance_of(rig, sub) {
        Ok(found) ->
          case wanted(found) {
            True -> poll.Done(found)
            False -> poll.Retry
          }
        Error(Nil) -> poll.Retry
      }
    })
  {
    poll.Answered(value:) -> Ok(value)
    poll.Expired | poll.Failed(error: _never) -> Error(Nil)
  }
}

fn glance_of(rig: Rig, strand: String) -> Result(glance_cell.Glance, Nil) {
  case api.fact_cell(rig.runtime, glance_cell.key(strand)) {
    Ok(Some(api.FactCell(value:, ..))) ->
      glance_cell.decode(value) |> result.replace_error(Nil)
    Ok(None) | Error(_) -> Error(Nil)
  }
}

// The machine first, then the tree it writes through, for the reason
// `advisor_test.stop` gives: a machine left alive over a dead writer
// crashes on its next write, and it is linked to the test process.
fn stop(rig: Rig) -> Nil {
  case addresses.owner(rig.name) {
    Ok(pid) -> {
      process.unlink(pid)
      process.kill(pid)
    }
    Error(Nil) -> Nil
  }
  process.kill(rig.runtime.tree.supervisor)
}

// --- fixtures ------------------------------------------------------------------

fn a_row(adjustment: Bool) -> entry.UsageRow {
  let #(id, _generator) =
    ids.mint_usage(ids.generator(clock.fixed(at: 1000), seed: 5))
  entry.UsageRow(
    id:,
    seq: 1,
    entry_id: None,
    adjustment:,
    usage: message.Usage(
      ..effects.zero_usage(),
      input: 100,
      cache_read: 30,
      cache_write: 5,
      output: 7,
    ),
    details: None,
  )
}

fn routing(roles: List(model.Role)) -> provider_gateway.Gateway {
  let identity =
    model.ResolvedModel(
      provider: "acme",
      model_id: "loom-1",
      thinking: model.ThinkingHigh,
      context_window: 100_000,
      max_output_tokens: 4096,
    )
  let gateway =
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
  list.fold(roles, gateway, fn(gateway, role) {
    provider_gateway.route(gateway, role, [identity])
  })
}

fn fixed_clock() -> clock.Clock {
  clock.fixed(at: 1_756_000_000_000)
}

// A clock that moves, for the one test whose property is a wait.
fn wall_clock() -> clock.Clock {
  clock.from_function(fn() {
    let #(seconds, nanoseconds) =
      timestamp.to_unix_seconds_and_nanoseconds(timestamp.system_time())
    seconds * 1000 + nanoseconds / 1_000_000
  })
}

fn a_configuration() -> machine_strand.StrandConfiguration {
  machine_strand.StrandConfiguration(
    model: machine_strand.ModelIdentity(provider: "acme", model_id: "loom-1"),
    thinking_level: machine_strand.ThinkingOff,
    active_tool_names: [],
  )
}

fn user(text: String) -> message.AgentMessage {
  message.UserMessage(
    content: [message.UserText(text:, text_signature: None)],
    timestamp: 0,
    origin: None,
  )
}

fn hanging_provider() -> effects.ProviderSurface {
  effects.ProviderSurface(timeout_ms: 30_000, request: fn(_spec) {
    stream.immediate(events: process.new_subject(), cancel: fn() { Nil })
  })
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

fn start_entropy() -> Result(fn() -> Int, String) {
  otp_actor.new(1)
  |> otp_actor.on_message(fn(next, reply) {
    process.send(reply, next)
    otp_actor.continue(next + 1)
  })
  |> otp_actor.start
  |> result.map(fn(counter) {
    fn() { process.call(counter.data, waiting: 1000, sending: fn(r) { r }) }
  })
  |> result.replace_error("the entropy counter did not start")
}
