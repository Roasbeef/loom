//// Two models in one session: the advisor strand reading what the primary
//// did, and reaching it.
////
//// Every other test of this feature holds one piece of it still. The
//// renderer is tested against hand-built entries, the emission guard
//// against a constructed guard, the tool against a stub seam, and the
//// actor against a fake runtime. None of them can answer the question
//// issue #137 actually asks, which is whether a second model, routed by
//// the catalogue and driven by the harness alone, sees a real run's work
//// and whether its verdict reaches the primary. That question needs the
//// whole assembly: `serve.open_instance`, two providers, the durable
//// machine that owns both run boundaries, and the advisor strand's own
//// driver.
////
//// ## The two providers
////
//// The catalogue carries two entries on two base URLs, which is what
//// makes the fixture able to tell the strands apart at all. The scripted
//// transport keys on the request URL: `acme.test` is the primary and
//// `sage.test` is the advisor, and the two lanes are scripted
//// independently. Asserting on request bodies rather than on the durable
//// tree is deliberate throughout — the tree would show a message that was
//// written, and a body shows one that was sent to a model.
////
//// ## The shape of the run
////
//// Three operator turns on `main`, and the advisor's own runs interleaved
//// with them at whatever pace the actor's coalescing allows:
////
//// 1. the first turn ends, the primary's run-end hook feeds the advisor,
////    and the advisor answers `block`. The guard delivers it, so a framed
////    advice message reaches `main` — as a steer if its run is still
////    open, as a fresh run if it is idle. Either way it is in a primary
////    request body, which is the only place a message that was never sent
////    could not appear;
//// 2. the second turn ends and the advisor answers `nudge`, which is
////    queued rather than sent. It is folded into the next run start on
////    `main` as one fenced `advisor-nudges` message;
//// 3. the third turn ends and the advisor answers `quiet`, which emits
////    nothing at all — the assertion for which is that no fifth primary
////    request appears.
////
//// ## Why the advisor's lane is scripted by position and not by count
////
//// The loop is not a lockstep: a run end that finds the advisor busy is
//// coalesced away, and the advisor's own run end feeds it again if the
//// primary appended anything meanwhile. How many feeds a given scheduling
//// produces is therefore not fixed, and a script keyed on "the fourth
//// advisor request" would be a flake waiting for a slow host. What is
//// fixed is the shape of one review: a request that ends with a feed
//// wants an `advise` call, and a request that carries the tool result
//// after that feed wants the text that ends the run. `answered` reads
//// exactly that, and the verdicts are drawn in order — one block, one
//// nudge, quiet from then on — so the three assertions above hold however
//// many reviews the host's timing happens to produce.

import broker/exec
import client/advisor
import client/advisorguard
import client/advisorslice
import client/catalog
import client/codemode
import client/distillpass
import client/internal/ffi_os
import client/jobs
import client/schedule
import client/serve
import client/tui_e2e_test.{type EunitTest, Timeout}
import core/clock
import core/ids
import core/json
import core/message
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import machine/acceptance
import machine/operation
import machine/strand as machine_strand
import provider/adapter/anthropic
import provider/gateway as provider_gateway
import provider/http
import provider/model
import provider/secret
import runtime/api
import simplifile
import support/provider as provider_test
import telemetry/log
import tools/advise
import weft/actor
import weft/poll

/// The whole budget: one real instance assembly, three operator turns, a
/// delivered block's own run, and the advisor's reviews between them.
/// eunit's unchosen default is 5 s, which gleeunit scales to 50 — close
/// enough to the observed run that a slow host would report `Timeout` at a
/// line number rather than a failed assertion.
const test_timeout_seconds = 240

/// gleeunit runs eunit with `ScaleTimeouts(10)`, and that scale multiplies
/// a generator's own timeout too, so the number handed to eunit is the
/// number wanted divided by ten. Stated rather than folded into the
/// constant because the arithmetic is the trap: `Timeout(240, _)` read at
/// face value would be forty minutes.
const gleeunit_timeout_scale = 10

/// How long any one wait for the loop to reach a state may take. Generous
/// against a loaded host: every step it waits on is an in-memory script
/// and a durable write, and nothing here is waiting on a network.
const await_ms = 30_000

/// How long the fixture watches for a primary request that should never
/// come. See the settle assertion for why this bound is safe.
const settle_ms = 2000

/// What the primary says on its first turn. The advisor must be shown it,
/// so it has to be findable in a `sage.test` request body.
const primary_said = "I changed auth.gleam and consider this done."

/// What the primary reasons on its first turn. The renderer withholds
/// reasoning from the feed, so this is the string whose *absence* from the
/// advisor's request is the assertion.
const primary_thinking = "the reasoning the reviewer is never shown"

/// The advisor's block. It has to reach `main` as sent text.
const block_text = "auth.gleam has no test; add one before finishing."

/// The advisor's nudge. It has to reach `main` inside a fence, once.
const nudge_text = "Name the test after the behaviour."

/// The host that answers for the primary's model.
const primary_host = "acme.test"

/// The host that answers for the advisor's model. The transport tells the
/// two lanes apart by this substring alone.
const advisor_host = "sage.test"

/// The acceptance case of issue #137, as a test rather than a claim: a
/// second model routed by the catalogue reviews the primary's real runs,
/// and each of its three verdicts costs the primary what the design says
/// it costs.
pub fn a_second_model_reviews_the_primary_and_reaches_it_test_() -> EunitTest {
  Timeout(test_timeout_seconds / gleeunit_timeout_scale, fn() {
    let root = fixture_root()
    let script = script()
    let assert Ok(instance) =
      serve.open_instance(settings(root, script), log.discard())
      as "the advisor fixture must open a real instance"

    // Checked out and back before the first prompt, for the reason
    // `serve_test`'s own instance turn does it: an instance whose pool
    // never handshook would otherwise fail later, inside a tool call, as a
    // clearance refusal that reads like a policy decision.
    let assert Ok(helper) = exec.checkout(instance.pool, waiting: 5000)
      as "the instance must have a real, handshaken helper"
    exec.checkin(instance.pool, helper)

    // The first operator turn, admitted through the instance's own writer
    // and awaited to settlement.
    complete(instance, "look at what I changed")

    // The block, observed where a message that was never sent could not
    // appear: a request the harness made to the primary's own provider.
    let carrying = await_primary(script, advisorslice.advice_header)
    assert string.contains(carrying, block_text)

    // What the advisor was shown, and what it was given to answer with.
    let assert Ok(feed) = list.first(seen(script).advisor)
      as "the advisor must have been asked at least once"
    the_feed_is_a_review(feed)
    the_advisor_holds_its_own_tools(feed)

    let assert Ok(opening) = list.first(seen(script).primary)
      as "the primary must have been asked at least once"
    assert !string.contains(opening, tool_entry(advise.name))
      as "the primary must not be offered the tool its reviewer answers with"
    assert !string.contains(opening, "`" <> advise.name <> "`")
      as "the primary's system prompt must not index its reviewer's tool"

    // The second turn, and then the wait for the nudge it earns. The wait
    // is on the advisor having *answered* twice rather than on the guard's
    // pending list, because a nudge queued before the third run start is
    // drained by it and a fixture watching the queue would miss the
    // transition it was waiting for.
    complete(instance, "add the test")
    await_advised(script, 2)
    complete(instance, "confirm it passes")

    // One nudge, folded in once. The newest request carrying the fence
    // holds the whole conversation, so a nudge re-queued at every run start
    // would show up in it more than once.
    let nudged = await_primary(script, fence_open())
    assert string.contains(nudged, nudge_text)
    assert occurrences(nudged, fence_open()) == 1
      as "the queued nudge must be drained into exactly one run start"

    // The quiet verdict costs nothing. Three operator turns and the one
    // run the delivered block started are four requests, and nothing left
    // can add a fifth: the only verdict that starts a run on the primary
    // is a block, the script raises exactly one, and every later verdict is
    // quiet. The bound is therefore watching for a request that is merely
    // late, and a scripted transport answers in microseconds.
    let settled: poll.Outcome(Nil, Nil) =
      poll.until(within: settle_ms, every: 100, attempt: fn() {
        case list.length(seen(script).primary) > 4 {
          True -> poll.Done(Nil)
          False -> poll.Retry
        }
      })
    assert settled == poll.Expired
      as "a quiet verdict must not reach the primary at all"
    assert list.length(seen(script).primary) == 4

    // The two cells, read before the instance is closed because reading
    // one goes through the writer this close is about to stop.
    let assert Ok(Some(json.Int(_seq))) =
      api.fact(instance.runtime, advisor.cursor_key)
      as "the feed cursor must be durable and must hold a seq"
    let assert Ok(Some(payload)) = api.fact(instance.runtime, advisor.guard_key)
      as "the emission guard must be durable"
    let assert Ok(_guard) = advisorguard.decode(payload)
      as "the guard cell must decode with the guard's own decoder"

    serve.close_instance(instance)
  })
}

// --- what the advisor was shown ----------------------------------------------

// The feed is a framed review and not the primary's transcript: the
// standing instructions lead it, the frame names it, the primary's words
// are in it, and the primary's reasoning is not.
fn the_feed_is_a_review(feed: String) -> Nil {
  assert string.contains(feed, escaped(advisor.brief))
    as "the standing instructions must be prepended to the advisor's request"
  assert string.contains(feed, advisorslice.feed_header)
  assert string.contains(feed, "consider this done")
    as "the advisor must be shown what the primary said"
  assert !string.contains(feed, primary_thinking)
    as "the advisor must not be shown the primary's reasoning"
  Nil
}

// The advisor's tool array is the `[advisor]` table plus `advise`, and
// nothing else this host registers. `bash` is the one that matters: a
// reviewer that could run commands would be a second worker.
fn the_advisor_holds_its_own_tools(feed: String) -> Nil {
  assert string.contains(feed, tool_entry(advise.name))
  assert string.contains(feed, tool_entry("fs_read"))
  assert !string.contains(feed, tool_entry("bash"))
    as "the advisor must not be given a tool its table did not name"
  Nil
}

// The head of one entry in a request's `tools` array. Matching the object's
// opening rather than the bare name keeps the two assertions distinct: this
// one is about the tool array, and the system-prompt assertion beside it is
// about the prose index, which names tools in backticks.
fn tool_entry(name: String) -> String {
  "{\"name\":\"" <> name <> "\","
}

// A string as a request body carries it. The adapter renders every message
// through `core/json`, so running a constant through the same encoder
// matches a multi-line brief exactly rather than by one of its lines.
fn escaped(text: String) -> String {
  json.to_string(json.String(text))
}

fn fence_open() -> String {
  "```" <> advisorslice.nudges_fence
}

fn occurrences(text: String, marker: String) -> Int {
  list.length(string.split(text, marker)) - 1
}

// --- waiting on the loop ------------------------------------------------------

// The newest primary request body carrying `marker`, waited for. The loop
// runs on its own process and every step of it is asynchronous to the
// operator's turn, so there is no point at which the fixture may simply
// look.
fn await_primary(script: Subject(ScriptMessage), marker: String) -> String {
  let found: poll.Outcome(String, Nil) =
    poll.until(within: await_ms, every: 100, attempt: fn() {
      case latest_with(seen(script).primary, marker) {
        Ok(body) -> poll.Done(body)
        Error(Nil) -> poll.Retry
      }
    })

  let assert poll.Answered(value: body) = found
    as "the marker must reach a primary request inside the wait"
  body
}

// Waits until the advisor has answered `wanted` feeds with a verdict. The
// count only ever rises, so a fixture that reads it late reads it right.
fn await_advised(script: Subject(ScriptMessage), wanted: Int) -> Nil {
  let counted: poll.Outcome(Nil, Nil) =
    poll.until(within: await_ms, every: 100, attempt: fn() {
      case seen(script).advised >= wanted {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })

  let assert poll.Answered(value: Nil) = counted
    as "the advisor must answer enough feeds inside the wait"
  Nil
}

fn latest_with(bodies: List(String), marker: String) -> Result(String, Nil) {
  bodies
  |> list.filter(string.contains(_, marker))
  |> list.last
}

// --- the session --------------------------------------------------------------

// One operator turn, admitted through the instance's own writer and awaited
// to settlement. A block delivered into the open run steers it rather than
// starting a new one, which costs the run one more provider request and
// still settles it as the assistant's own completion.
//
// Admission is retried while the strand is busy. A block delivered onto an
// idle primary starts a run of its own, and how long that run stays open
// depends on the host's scheduling: the advice can be visible in a request
// body while the run that carries it has not settled yet, and an operator
// prompt admitted at that moment is refused as busy rather than queued.
fn complete(instance: serve.Instance, text: String) -> Nil {
  let admitted: poll.Outcome(ids.OpId, Nil) =
    poll.until(within: await_ms, every: 100, attempt: fn() {
      case api.prompt(instance.runtime, [user(text)]) {
        Ok(op) -> poll.Done(op)
        Error(api.AcceptRejected(reason: acceptance.StrandBusy)) -> poll.Retry
        Error(other) -> panic as string.inspect(other)
      }
    })
  let assert poll.Answered(value: op) = admitted
    as "the instance must admit the operator's turn through its own writer"
  let assert Ok(operation.RunLastResult(outcome: completion, ..)) =
    api.await_result(instance.runtime, op, within_ms: 60_000)
    as "the operator's turn must settle through the real machine"

  assert completion == operation.RunCompleted(operation.CompletedByAssistant)
  Nil
}

fn user(text: String) -> message.AgentMessage {
  message.UserMessage(
    content: [message.UserText(text:, text_signature: None)],
    timestamp: 0,
    origin: None,
  )
}

// --- the two scripted models ---------------------------------------------------

// What the script has been asked and what it has said. Bodies are kept
// newest first while they accumulate and handed back oldest first, which is
// the order every assertion reads them in.
type Seen {
  Seen(primary: List(String), advisor: List(String), advised: Int)
}

type ScriptMessage {
  Dispatched(url: String, body: String, reply: Subject(String))
  Snapshot(reply: Subject(Seen))
}

fn script() -> Subject(ScriptMessage) {
  let assert Ok(started) =
    actor.new(Seen(primary: [], advisor: [], advised: 0))
    |> actor.on_message(dispatch)
    |> actor.start
    as "the two-model script must start"
  started.data
}

fn dispatch(
  seen: Seen,
  message: ScriptMessage,
) -> actor.Next(Seen, ScriptMessage) {
  case message {
    Snapshot(reply:) -> {
      process.send(
        reply,
        Seen(
          ..seen,
          primary: list.reverse(seen.primary),
          advisor: list.reverse(seen.advisor),
        ),
      )
      actor.continue(seen)
    }

    // The lane is the request's own URL. Two catalogue entries on two base
    // URLs is the whole reason the fixture can tell one strand's traffic
    // from the other's.
    Dispatched(url:, body:, reply:) ->
      case string.contains(url, advisor_host) {
        True -> advisor_reply(seen, body, reply)
        False -> primary_reply(seen, body, reply)
      }
  }
}

fn primary_reply(
  seen: Seen,
  body: String,
  reply: Subject(String),
) -> actor.Next(Seen, ScriptMessage) {
  process.send(reply, primary_turn(list.length(seen.primary) + 1))
  actor.continue(Seen(..seen, primary: [body, ..seen.primary]))
}

// The primary's turns, by position. Only the first one matters to an
// assertion: it reasons and then speaks, so the feed can be checked for
// what it said and for the absence of what it thought.
fn primary_turn(index: Int) -> String {
  case index {
    1 -> thinking_turn("primary-1", primary_thinking, primary_said)
    2 -> text_turn("primary-2", primary_model, "Adding the test now.")
    3 -> text_turn("primary-3", primary_model, "done")
    _later -> text_turn("primary-n", primary_model, "nothing further")
  }
}

fn advisor_reply(
  seen: Seen,
  body: String,
  reply: Subject(String),
) -> actor.Next(Seen, ScriptMessage) {
  case answered(body) {
    // The `advise` call this request carries the result of was the answer
    // to the newest feed, so the review is over and the run ends here.
    True -> {
      process.send(reply, text_turn("advisor-said", advisor_model, "noted"))
      actor.continue(Seen(..seen, advisor: [body, ..seen.advisor]))
    }

    False -> {
      process.send(reply, advise_turn(seen.advised))
      actor.continue(
        Seen(..seen, advisor: [body, ..seen.advisor], advised: seen.advised + 1),
      )
    }
  }
}

// Whether the advisor has already answered the newest feed in `body`.
//
// The advisor's branch accumulates every earlier `advise` call and its
// result, so a tool result somewhere in the request says nothing about this
// review. Where the newest feed sits does: the request that ends a review
// carries the tool result *after* the feed it answered, and the request
// that opens one ends with the feed itself.
fn answered(body: String) -> Bool {
  case list.last(string.split(body, advisorslice.feed_header)) {
    Ok(tail) -> string.contains(tail, "\"tool_result\"")

    // Unreachable: `string.split` always yields at least one fragment. An
    // unanswered feed is the safe reading either way, since it costs one
    // extra verdict rather than a run that never ends.
    Error(Nil) -> False
  }
}

// The verdicts, in the order the assertions need them: one block, one
// nudge, and quiet for every review the host's timing adds.
fn advise_turn(already: Int) -> String {
  case already {
    0 -> advise_call("advise-block", "block", block_text)
    1 -> advise_call("advise-nudge", "nudge", nudge_text)
    _later -> advise_call("advise-quiet", "quiet", "")
  }
}

fn advise_call(id: String, verdict: String, text: String) -> String {
  let arguments = case text {
    // `quiet` carries no text at all: the tool refuses a quiet verdict
    // that says something, and an empty string is the same refusal.
    "" -> json.Object([#("verdict", json.String(verdict))])

    said ->
      json.Object([
        #("verdict", json.String(verdict)),
        #("text", json.String(said)),
      ])
  }

  tool_turn(id, advisor_model, advise.name, arguments)
}

fn seen(script: Subject(ScriptMessage)) -> Seen {
  actor.call(script, waiting: 5000, sending: fn(reply) { Snapshot(reply) })
}

fn scripted_transport(script: Subject(ScriptMessage)) -> http.Transport {
  provider_test.transport(fn(request: http.HttpRequest, events) {
    let response =
      actor.call(script, waiting: 10_000, sending: fn(reply) {
        Dispatched(request.url, request.body, reply)
      })

    process.send(
      events,
      http.ResponseStatus(200, [#("content-type", "text/event-stream")]),
    )
    process.send(events, http.ResponseChunk(bit_array.from_string(response)))
    process.send(events, http.ResponseEnd)
  })
}

// --- the wire shapes ------------------------------------------------------------

fn text_turn(id: String, model_id: String, text: String) -> String {
  started(id, model_id) <> text_block(0, text) <> stopped("end_turn")
}

// A turn that reasons before it speaks. The whole thinking block rides in
// `content_block_start` with a signature, because a durable thinking block
// with no signature is a shape the adapter would re-encode on the primary's
// next request and nothing here is testing that.
fn thinking_turn(id: String, thinking: String, text: String) -> String {
  started(id, primary_model)
  <> sse(
    "content_block_start",
    "{\"type\":\"content_block_start\",\"index\":0,"
      <> "\"content_block\":{\"type\":\"thinking\",\"thinking\":"
      <> json.to_string(json.String(thinking))
      <> ",\"signature\":\"fixture-signature\"}}",
  )
  <> sse("content_block_stop", "{\"type\":\"content_block_stop\",\"index\":0}")
  <> text_block(1, text)
  <> stopped("end_turn")
}

fn text_block(index: Int, text: String) -> String {
  let at = int.to_string(index)

  sse(
    "content_block_start",
    "{\"type\":\"content_block_start\",\"index\":"
      <> at
      <> ",\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
  )
  <> sse(
    "content_block_delta",
    "{\"type\":\"content_block_delta\",\"index\":"
      <> at
      <> ",\"delta\":{\"type\":\"text_delta\",\"text\":"
      <> json.to_string(json.String(text))
      <> "}}",
  )
  <> sse(
    "content_block_stop",
    "{\"type\":\"content_block_stop\",\"index\":" <> at <> "}",
  )
}

fn tool_turn(
  id: String,
  model_id: String,
  name: String,
  arguments: json.JsonValue,
) -> String {
  started(id, model_id)
  <> sse(
    "content_block_start",
    "{\"type\":\"content_block_start\",\"index\":0,"
      <> "\"content_block\":{\"type\":\"tool_use\",\"id\":\""
      <> id
      <> "\",\"name\":\""
      <> name
      <> "\",\"input\":{}}}",
  )
  <> sse(
    "content_block_delta",
    "{\"type\":\"content_block_delta\",\"index\":0,"
      <> "\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":"
      <> json.to_string(json.String(json.to_string(arguments)))
      <> "}}",
  )
  <> sse("content_block_stop", "{\"type\":\"content_block_stop\",\"index\":0}")
  <> stopped("tool_use")
}

fn started(id: String, model_id: String) -> String {
  sse(
    "message_start",
    "{\"type\":\"message_start\",\"message\":{\"id\":\""
      <> id
      <> "\",\"model\":\""
      <> model_id
      <> "\",\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}}",
  )
}

fn stopped(reason: String) -> String {
  sse(
    "message_delta",
    "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\""
      <> reason
      <> "\"},\"usage\":{\"output_tokens\":1}}",
  )
  <> sse("message_stop", "{\"type\":\"message_stop\"}")
}

fn sse(event: String, data: String) -> String {
  "event: " <> event <> "\ndata: " <> data <> "\n\n"
}

// --- the catalogue and the instance ---------------------------------------------

const primary_model = "loom-1"

const advisor_model = "sage-1"

fn scripted_catalog() -> catalog.Catalog {
  catalog.Catalog(
    models: [
      entry("acme", "https://" <> primary_host, primary_model, "ACME_KEY"),
      entry("sage", "https://" <> advisor_host, advisor_model, "SAGE_KEY"),
    ],
    // The advisor role is routed as well as named, because that is the
    // arrangement an operator's `loom.toml` produces and the one a reader
    // comparing this fixture to a real catalogue expects. `open_instance`
    // takes its advisor settings as given rather than deriving them from
    // the route; `serve.resolve` is the path that derives.
    roles: [#(model.Main, ["acme"]), #(catalog.advisor_role, ["sage"])],
    mcp_servers: [],
  )
}

fn entry(
  name: String,
  base_url: String,
  model_id: String,
  api_key_env: String,
) -> catalog.CatalogModel {
  catalog.CatalogModel(
    name:,
    dialect: catalog.Anthropic,
    base_url:,
    api_key_env:,
    model_id:,
    context_window: 100_000,
    max_output_tokens: 4096,
    thinking: model.ThinkingOff,
    pricing: None,
  )
}

fn gateway(script: Subject(ScriptMessage)) -> provider_gateway.Gateway {
  catalog.gateway(
    scripted_catalog(),
    transport: scripted_transport(script),
    secrets: secret.from_list([
      #("ACME_KEY", "advisor-e2e-primary-key"),
      #("SAGE_KEY", "advisor-e2e-advisor-key"),
    ]),
    clock: clock.fixed(at: 0),
  )
}

// Where this run's tree lives. The name carries a clock reading as well as
// the node-local counter, because the counter restarts with the Erlang node
// and a second run would otherwise inherit the first run's session store —
// which holds the two cells every assertion here reads.
fn fixture_root() -> String {
  let assert Ok(here) = simplifile.current_directory()
    as "the test process must know where it is"
  let root =
    here
    <> "/build/advisor-e2e-"
    <> int.to_string(ffi_os.system_time_ms())
    <> "-"
    <> int.to_string(ffi_os.unique_positive_integer())

  let assert Ok(Nil) = simplifile.delete_all([root])
    as "a previous run's fixture tree must be removable"
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/work")
    as "the fixture workspace must be creatable"
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/home")
    as "the fixture home must be creatable"
  root
}

fn settings(root: String, script: Subject(ScriptMessage)) -> serve.Settings {
  let assert Ok(here) = simplifile.current_directory()
    as "the test process must know where it is"
  serve.Settings(
    secrets: secret.env(),
    secret_failures: [],
    session_path: root <> "/session.db",
    domain_paths: None,
    // No listener: `open_instance` binds none, and the invalid address is
    // what proves it did not.
    bind_host: "not an interface",
    bind_port: -1,
    token_path: root <> "/transport-only/daemon.token",
    workspace: root <> "/work",
    base_policy: serve.base_policy(root <> "/work"),
    helper_path: here <> "/../sandbox/loom-exec",
    helper_pool_size: 2,
    session_id: "advisor-e2e",
    demand: exec.BestEffort,
    gateway: gateway(script),
    catalog: scripted_catalog(),
    system: None,
    // A fixture home rather than the machine's: a run that read the
    // developer's would discover their skills and their settings, and the
    // system prompt is one of the bytes this fixture asserts around.
    home: Some(root <> "/home"),
    model: machine_strand.ModelIdentity(
      provider: "acme",
      model_id: primary_model,
    ),
    context_window: 100_000,
    max_output_tokens: 4096,
    api: anthropic.api_name,
    compaction: operation.CompactionSettings(
      enabled: True,
      reserve_tokens: 16_384,
      keep_recent_tokens: 20_000,
    ),
    codemode_seed: root <> "/no-such-seed",
    codemode_seams: codemode.WorkspaceOnly,
    rules: [],
    schedules: [],
    schedule_policy: schedule.ModelSchedulesOff,
    jobs_policy: jobs.default_policy,
    deactivated_tools: [],
    memory: distillpass.no_pass(),
    tools: catalog.default_tools(),
    // The whole point of the fixture. `open_instance` takes these as given:
    // it registers `advise`, seeds the strand, wires the three hooks and
    // starts the actor from this one field being `Some`.
    advisor: Some(advisor.Settings(
      model: machine_strand.ModelIdentity(
        provider: "sage",
        model_id: advisor_model,
      ),
      thinking: machine_strand.ThinkingOff,
      tools: ["fs_read", "grep"],
      block_cooldown_runs: 2,
    )),
  )
}
