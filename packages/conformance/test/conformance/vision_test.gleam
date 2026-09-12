//// The vision routing rule end to end (issue #358): a prompt carrying
//// an image, on a strand pinned to a text-only model, is answered by
//// the routed vision model — and the request that reached the wire is
//// provably the vision request, its images intact.
////
//// Three scenarios, all through the production wiring over a scripted
//// transport — the same shape as the routing suite, which proved the
//// fallback walk here first:
////
//// - **The re-route.** An image prompt reaches the vision provider's
////   host, carries the image bytes, and the settled answer is
////   attributed to the vision identity. The strand's own model is
////   never asked.
//// - **The refusal.** With no vision route, the same prompt fails in
////   band with the worded `image_unsupported` reason, and no provider
////   is asked at all.
//// - **The placeholder.** After the image turn, a text follow-up is
////   answered by the strand's own model, and the request that reached
////   it shows the placeholder where the image was — the durable
////   transcript still carries the image itself.

import broker/broker
import broker/exec
import broker/policy
import broker/token
import client/catalog
import client/escalate
import client/wiring
import core/clock
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
import provider/adapter/anthropic
import provider/gateway.{type Gateway}
import provider/http
import provider/model
import provider/secret
import runtime/api
import session/session.{type Session}
import storage/storage
import support/rig
import support/script

// The two entries: the text-only model the strand is pinned to, and
// the vision model an image turn should borrow.
const text_host = "https://text.test"

const vision_host = "https://vision.test"

const text_model_id = "loom-text"

const vision_model_id = "loom-eyes"

const image_base64 = "iVBORw0KGgo="

const image_answer = "The image shows a cat."

// --- the scripted transport ----------------------------------------------

// Every request the wiring makes, tallied with what the wire would
// need to know about it: the host it went to, whether its body carried
// the fixture image's base64 bytes, and the model the adapter named in
// the request body. The tally is an actor rather than a mailbox drain
// because the assertions read it while the session is still live.
type Tally {
  Saw(host: String, body: String)
  Read(reply: process.Subject(List(#(String, String))))
}

fn tally() -> process.Subject(Tally) {
  let assert Ok(started) =
    actor.new([])
    |> actor.on_message(fn(seen: List(#(String, String)), message) {
      case message {
        Saw(host, body) -> actor.continue([#(host, body), ..seen])
        Read(reply) -> {
          process.send(reply, list.reverse(seen))
          actor.continue(seen)
        }
      }
    })
    |> actor.start
    as "the request tally must start"
  started.data
}

fn requests_to(counter: process.Subject(Tally), host: String) -> Int {
  let seen =
    process.call(counter, waiting: 1000, sending: fn(reply) { Read(reply:) })
  list.length(list.filter(seen, fn(entry) { entry.0 == host }))
}

// The one request a test asserts on, in full.
fn the_one_request_to(
  counter: process.Subject(Tally),
  host: String,
) -> #(String, String) {
  let seen =
    process.call(counter, waiting: 1000, sending: fn(reply) { Read(reply:) })
  let assert [only] = list.filter(seen, fn(entry) { entry.0 == host })
    as "exactly one request must have reached the host"
  only
}

// The transport: every request is tallied and answered with the
// scripted settlement, so a run completes while the tally records
// what the wire saw.
fn transport(
  counter: process.Subject(Tally),
  answer: String,
) -> http.Transport {
  let turn =
    script.AnswerTurn(text: answer, input_tokens: 100, output_tokens: 9)
  script.owned_transport(fn(request: http.HttpRequest, subject) {
    let host = string.replace(request.url, "/v1/messages", "")
    process.send(counter, Saw(host, request.body))
    let events = settled_events(turn)
    list.each(events, fn(event) { process.send(subject, event) })
  })
}

// The scripted turn's SSE body, replayed through the real adapter by
// borrowing the e2e script's own renderer via a one-turn transport.
fn settled_events(turn: script.Turn) -> List(http.HttpEvent) {
  let captured = process.new_subject()
  let one_shot = script.transport([turn])
  let assert Ok(http.PreparedRequest(begin:, ..)) =
    one_shot.prepare_streaming(
      http.HttpRequest(
        method: "POST",
        url: "https://captured.test",
        headers: [],
        body: "",
      ),
      captured,
    )
  begin()
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

// --- the wiring under test ----------------------------------------------

fn routed_gateway(transport: http.Transport) -> Gateway {
  gateway.new(
    transport:,
    secrets: secret.from_list([
      #("TEXT_KEY", "vision-test-key"),
      #("VISION_KEY", "vision-test-key"),
    ]),
    clock: clock.stepping(from: 1_700_000_000_000, by: 3),
  )
  |> gateway.add_provider(gateway.AnthropicProvider(
    name: "texty",
    base_url: text_host,
    api_key_secret: "TEXT_KEY",
  ))
  |> gateway.add_provider(gateway.AnthropicProvider(
    name: "eyes",
    base_url: vision_host,
    api_key_secret: "VISION_KEY",
  ))
  |> gateway.route(model.Main, [text_target()])
  |> gateway.route(model.Vision, [vision_target()])
  |> gateway.with_attempt_timeout(5000)
}

// The same gateway with no vision route: the refusal's fixture.
fn unrouted_gateway(transport: http.Transport) -> Gateway {
  gateway.new(
    transport:,
    secrets: secret.from_list([#("TEXT_KEY", "vision-test-key")]),
    clock: clock.stepping(from: 1_700_000_000_000, by: 3),
  )
  |> gateway.add_provider(gateway.AnthropicProvider(
    name: "texty",
    base_url: text_host,
    api_key_secret: "TEXT_KEY",
  ))
  |> gateway.route(model.Main, [text_target()])
  |> gateway.with_attempt_timeout(5000)
}

fn text_target() -> model.ResolvedModel {
  model.ResolvedModel(
    provider: "texty",
    model_id: text_model_id,
    thinking: model.ThinkingOff,
    context_window: 200_000,
    max_output_tokens: 8192,
  )
}

fn vision_target() -> model.ResolvedModel {
  model.ResolvedModel(
    provider: "eyes",
    model_id: vision_model_id,
    thinking: model.ThinkingOff,
    context_window: 64_000,
    max_output_tokens: 8192,
  )
}

// The facts seam, as `client/serve` builds it from a catalogue: the
// text entry declares itself text-only, the vision entry reads images.
fn entry_facts(
  identity: ModelIdentity,
) -> Result(#(model.ResolvedModel, String, catalog.ImageReading), Nil) {
  case identity {
    ModelIdentity(provider: "texty", ..) ->
      Ok(#(text_target(), anthropic.api_name, catalog.TextOnly))
    ModelIdentity(provider: "eyes", ..) ->
      Ok(#(vision_target(), anthropic.api_name, catalog.ReadsImages))
    _ -> Error(Nil)
  }
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
    session.open_memory(clock.stepping(from: 1_700_000_000_300, by: 11))
    as "the memory session must open"
  opened
}

// The strand, pinned to the text-only entry.
fn configuration() -> StrandConfiguration {
  StrandConfiguration(
    model: ModelIdentity(provider: "texty", model_id: text_model_id),
    thinking_level: strand.ThinkingOff,
    active_tool_names: [],
  )
}

fn wiring_config(gw: Gateway, sess: Session) -> wiring.Config {
  let workspace = "/nonexistent/loom-vision-test"
  wiring.Config(
    observe_output: wiring.unobserved(),
    gateway: gw,
    role: model.Main,
    facts: entry_facts,
    system: Some("Answer briefly."),
    api: anthropic.api_name,
    fallback_context_window: 200_000,
    fallback_max_output_tokens: 8192,
    provider_timeout_ms: 20_000,
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

fn image_prompt() -> message.AgentMessage {
  message.UserMessage(
    content: [
      message.UserText(text: "what is in this picture", text_signature: None),
      message.UserImage(image_base64, "image/png"),
    ],
    timestamp: 0,
    origin: None,
  )
}

fn text_prompt(text: String) -> message.AgentMessage {
  message.UserMessage(
    content: [message.UserText(text:, text_signature: None)],
    timestamp: 0,
    origin: None,
  )
}

// --- the re-route ---------------------------------------------------------

// The image prompt is answered by the vision model: the request
// reached the vision host carrying the image bytes, the settled answer
// is attributed to the vision identity, and the strand's own model
// was never asked.
pub fn an_image_prompt_routes_to_the_vision_model_test() {
  let counter = tally()
  let sess = memory_session()
  let effects =
    wiring.build_effects(wiring_config(
      routed_gateway(transport(counter, image_answer)),
      sess,
    ))
  let assert Ok(runtime) =
    api.open(sess, effects, api.default_options(configuration()))
    as "the vision session must open"
  let assert Ok(op) = api.prompt(runtime, [image_prompt()])
  let assert Ok(outcome) = api.await_result(runtime, op, within_ms: 30_000)
    as "the image run must reach a terminal result"
  let assert operation.RunLastResult(
    outcome: operation.RunCompleted(..),
    final_assistant: Some(_),
    ..,
  ) = outcome

  // The wire saw the vision request and only it.
  assert requests_to(counter, vision_host) == 1
  assert requests_to(counter, text_host) == 0
  let #(_, body) = the_one_request_to(counter, vision_host)
  assert string.contains(body, image_base64)
  assert string.contains(body, vision_model_id)

  // The settled answer is attributed to the vision identity — the
  // model that actually answered — and the strand's durable
  // configuration is untouched: a re-route is a dispatch-time choice,
  // never a configuration change.
  let assert [_, settled] = projected_all(sess)
  let assert message.AssistantMessage(provider:, model: model_id, ..) = settled
  assert provider == "eyes"
  assert model_id == vision_model_id

  let assert Ok(Nil) = api.close(runtime)
}

// --- the refusal ----------------------------------------------------------

// With no vision route the same prompt fails in band, worded, before
// any provider is asked.
pub fn an_image_prompt_without_a_route_fails_worded_test() {
  let counter = tally()
  let sess = memory_session()
  let effects =
    wiring.build_effects(wiring_config(
      unrouted_gateway(transport(counter, image_answer)),
      sess,
    ))
  let assert Ok(runtime) =
    api.open(sess, effects, api.default_options(configuration()))
    as "the refusal session must open"
  let assert Ok(op) = api.prompt(runtime, [image_prompt()])
  let assert Ok(outcome) = api.await_result(runtime, op, within_ms: 30_000)
    as "the refused run must reach a terminal result"
  let assert operation.RunLastResult(
    outcome: operation.RunFailed(error: operation.OperationError(
      code: error_code,
      message: error_message,
      details: _,
    )),
    ..,
  ) = outcome
  assert error_code == "image_unsupported"
  assert string.contains(error_message, text_model_id)
  assert string.contains(error_message, "no vision route resolves")

  // Nobody was asked: the refusal is at admission, before dispatch.
  assert requests_to(counter, text_host) == 0
  assert requests_to(counter, vision_host) == 0

  let assert Ok(Nil) = api.close(runtime)
}

// --- the placeholder ------------------------------------------------------

// After the image turn, a text follow-up is answered by the strand's
// own text-only model, and the request that reached it shows the
// placeholder where the image was — while the durable transcript
// still carries the image itself.
pub fn a_followup_reaches_the_text_model_placeheld_test() {
  let counter = tally()
  let sess = memory_session()
  let effects =
    wiring.build_effects(wiring_config(
      routed_gateway(transport(counter, image_answer)),
      sess,
    ))
  let assert Ok(runtime) =
    api.open(sess, effects, api.default_options(configuration()))
    as "the placeholder session must open"

  let assert Ok(first) = api.prompt(runtime, [image_prompt()])
  let assert Ok(_outcome) = api.await_result(runtime, first, within_ms: 30_000)
    as "the image turn must complete"

  let assert Ok(second) = api.prompt(runtime, [text_prompt("and in prose?")])
  let assert Ok(outcome) = api.await_result(runtime, second, within_ms: 30_000)
    as "the follow-up must reach a terminal result"
  let assert operation.RunLastResult(
    outcome: operation.RunCompleted(..),
    final_assistant: Some(_),
    ..,
  ) = outcome

  // The follow-up went to the strand's own model, and its request
  // body shows the placeholder, not the bytes.
  assert requests_to(counter, text_host) == 1
  let #(_, body) = the_one_request_to(counter, text_host)
  assert !string.contains(body, image_base64)
  assert string.contains(
    body,
    "[image: image/png, described earlier in this conversation]",
  )

  // The durable transcript keeps the image: the second turn's
  // projection carries the original block, placeholders and all.
  let messages = projected_all(sess)
  let assert [
    message.UserMessage(content: [_, message.UserImage(data:, ..)], ..),
    message.AssistantMessage(..),
    message.UserMessage(..),
    message.AssistantMessage(..),
  ] = messages
  assert data == image_base64

  let assert Ok(Nil) = api.close(runtime)
}

fn projected_all(sess: Session) -> List(message.AgentMessage) {
  case session.strand_leaf(sess, "main") {
    Ok(Some(session.Cell(value: Some(leaf), ..))) ->
      case storage.scan_branch(sess.store, storage.branch_scan(from: leaf)) {
        Ok(entries) -> session.project_scan(entries)
        Error(_) -> []
      }
    _ -> []
  }
}
