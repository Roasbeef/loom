import core/clock
import core/message
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import provider/fixture.{sse_event}
import provider/gateway
import provider/http
import provider/model
import provider/secret
import provider/stream

const secret_value = "sk-super-secret-123"

// --- fixtures -------------------------------------------------------------

fn target(provider: String, model_id: String) -> model.ResolvedModel {
  fixture.resolved(provider:, model_id:)
}

fn happy_transcript(text: String) -> String {
  sse_event(
    "message_start",
    "{\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"model\":\"m\","
      <> "\"usage\":{\"input_tokens\":10,\"output_tokens\":1}}}",
  )
  <> sse_event(
    "content_block_start",
    "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
  )
  <> sse_event(
    "content_block_delta",
    "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\""
      <> text
      <> "\"}}",
  )
  <> sse_event(
    "message_delta",
    "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":4}}",
  )
  <> sse_event("message_stop", "{\"type\":\"message_stop\"}")
}

fn overloaded_response() -> List(http.HttpEvent) {
  fixture.error_response(
    529,
    [],
    "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}",
  )
}

fn invalid_request_response() -> List(http.HttpEvent) {
  fixture.error_response(
    400,
    [],
    "{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"bad request\"}}",
  )
}

fn secrets() -> secret.SecretStore {
  secret.from_list([
    #("PRIMARY_KEY", secret_value),
    #("BACKUP_KEY", "sk-backup-key"),
  ])
}

fn two_provider_gateway(transport: http.Transport) -> gateway.Gateway {
  gateway.new(
    transport:,
    secrets: secrets(),
    clock: clock.fixed(at: 1_700_000_000_000),
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
  |> gateway.route(model.Main, [
    target("primary", "model-a"),
    target("backup", "model-b"),
  ])
  |> gateway.with_attempt_timeout(2000)
}

fn main_request() -> model.ProviderRequest {
  model.ProviderRequest(
    target: model.ForRole(model.Main, None),
    system: Some("Be terse."),
    messages: [
      message.UserMessage(
        content: [message.UserText(text: "hi", text_signature: None)],
        timestamp: 1,
      ),
    ],
    tools: [],
    max_output_tokens: None,
  )
}

// --- resolve ---------------------------------------------------------------

pub fn resolve_returns_first_usable_target_test() {
  let gw = two_provider_gateway(fixture.transport([]))
  assert gateway.resolve(gw, model.Main) == Ok(target("primary", "model-a"))
}

pub fn resolve_skips_unregistered_providers_test() {
  let gw =
    two_provider_gateway(fixture.transport([]))
    |> gateway.route(model.Plan, [
      target("ghost", "phantom-model"),
      target("backup", "model-b"),
    ])
  assert gateway.resolve(gw, model.Plan) == Ok(target("backup", "model-b"))
}

pub fn resolve_missing_role_test() {
  let gw = two_provider_gateway(fixture.transport([]))
  assert gateway.resolve(gw, model.Vision)
    == Error(model.MissingIdentity(role: model.Vision))
}

pub fn resolve_route_with_no_registered_providers_test() {
  let gw =
    two_provider_gateway(fixture.transport([]))
    |> gateway.route(model.Summarize, [target("ghost", "phantom-model")])
  assert gateway.resolve(gw, model.Summarize)
    == Error(model.MissingIdentity(role: model.Summarize))
}

// --- request dispatch -------------------------------------------------------

pub fn happy_dispatch_settles_test() {
  let gw =
    two_provider_gateway(
      fixture.transport(fixture.ok_response(happy_transcript("Hello"))),
    )
  let handle = gateway.request(gw, main_request())
  let assert Ok(#(deltas, stream.Settled(message: settled, usage:))) =
    stream.await_terminal(handle, within: 2000)
  assert deltas == [stream.TextDelta(index: 0, text: "Hello")]
  let assert message.AssistantMessage(
    model: model_id,
    provider:,
    timestamp:,
    ..,
  ) = stream.message(settled)
  assert model_id == "model-a"
  assert provider == "primary"
  assert timestamp == 1_700_000_000_000
  assert usage.output == 4
}

pub fn retryable_failure_walks_the_chain_test() {
  // Primary answers 529 overloaded; the pump falls to backup, which
  // settles. The resolved identity in the settled message is backup's.
  let transport =
    fixture.routing_transport(fn(request) {
      case string.contains(request.url, "primary.test") {
        True -> overloaded_response()
        False -> fixture.ok_response(happy_transcript("From backup"))
      }
    })
  let handle = gateway.request(two_provider_gateway(transport), main_request())
  let assert Ok(#(_deltas, stream.Settled(message: settled, usage: _))) =
    stream.await_terminal(handle, within: 2000)
  let assert message.AssistantMessage(model: model_id, provider:, ..) =
    stream.message(settled)
  assert provider == "backup"
  assert model_id == "model-b"
}

pub fn exhausted_chain_fails_in_band_with_last_error_test() {
  let handle =
    gateway.request(
      two_provider_gateway(fixture.transport(overloaded_response())),
      main_request(),
    )
  let assert Ok(#([], stream.Failed(error))) =
    stream.await_terminal(handle, within: 2000)
  assert error
    == stream.HttpError(
      status: 529,
      api_error_type: "overloaded_error",
      message: "Overloaded",
      retry_after_ms: None,
    )
}

pub fn terminal_failure_does_not_walk_the_chain_test() {
  // Primary answers 400 invalid_request (terminal); backup would settle,
  // but a terminal error must surface, not be papered over.
  let transport =
    fixture.routing_transport(fn(request) {
      case string.contains(request.url, "primary.test") {
        True -> invalid_request_response()
        False -> fixture.ok_response(happy_transcript("From backup"))
      }
    })
  let handle = gateway.request(two_provider_gateway(transport), main_request())
  let assert Ok(#([], stream.Failed(stream.HttpError(status: 400, ..)))) =
    stream.await_terminal(handle, within: 2000)
}

pub fn cancellation_is_terminal_and_prevents_fallback_test() {
  let started = process.new_subject()
  let cancelled = process.new_subject()
  let transport =
    http.Transport(start_streaming: fn(request, _events) {
      let owner =
        process.spawn_unlinked(fn() {
          process.receive_forever(process.new_subject())
        })
      process.send(started, request.url)
      Ok(
        http.RunningRequest(owner:, cancel: fn() {
          process.send(cancelled, request.url)
          process.kill(owner)
        }),
      )
    })
  let handle = gateway.request(two_provider_gateway(transport), main_request())
  assert process.receive(started, within: 1000)
    == Ok("https://primary.test/v1/messages")
  stream.cancel(handle)
  stream.cancel(handle)
  let assert Ok(#([], stream.Failed(stream.ProviderCancelled))) =
    stream.await_terminal(handle, within: 1000)
  assert process.receive(cancelled, within: 1000)
    == Ok("https://primary.test/v1/messages")
  assert process.receive(started, within: 100) == Error(Nil)
  assert process.receive(cancelled, within: 100) == Error(Nil)
}

pub fn cancellation_after_settlement_is_a_noop_test() {
  let gateway =
    two_provider_gateway(
      fixture.transport(fixture.ok_response(happy_transcript("done"))),
    )
  let handle = gateway.request(gateway, main_request())
  let assert Ok(#(_deltas, stream.Settled(..))) =
    stream.await_terminal(handle, within: 1000)
  stream.cancel(handle)
  stream.cancel(handle)
  assert stream.next(handle, within: 100) == Error(Nil)
}

pub fn pump_crash_before_attempt_fails_promptly_in_band_test() {
  let crashing =
    http.Transport(start_streaming: fn(_request, _events) {
      panic as "transport seam crashed"
    })
  let handle = gateway.request(two_provider_gateway(crashing), main_request())
  let assert Ok(#([], stream.Failed(stream.CancellationUnconfirmed))) =
    stream.await_terminal(handle, within: 1000)
}

pub fn pump_crash_after_attempt_refuses_retry_until_transport_drains_test() {
  let owners = process.new_subject()
  let cancelled = process.new_subject()
  let transport =
    http.Transport(start_streaming: fn(_request, _events) {
      let pump = process.self()
      let ready = process.new_subject()
      let owner =
        process.spawn_unlinked(fn() {
          let release = process.new_subject()
          process.send(ready, release)
          let _release = process.receive_forever(release)
          Nil
        })
      let release = process.receive_forever(ready)
      process.send(owners, #(owner, release))
      let _killer =
        process.spawn_unlinked(fn() {
          // Let `run_tracked` publish the live capability before simulating
          // the pump fault that would otherwise lose it.
          process.sleep(25)
          process.kill(pump)
        })
      Ok(
        http.RunningRequest(owner:, cancel: fn() {
          process.send(cancelled, Nil)
        }),
      )
    })
  let handle = gateway.request(two_provider_gateway(transport), main_request())
  let assert Ok(#(owner, release)) = process.receive(owners, within: 1000)
  let assert Ok(#([], stream.Failed(stream.CancellationUnconfirmed))) =
    stream.await_terminal(handle, within: 2500)
  let assert Ok(Nil) = process.receive(cancelled, within: 1000)

  assert process.is_alive(owner)
  assert !stream.await_stopped(handle, within: 20)
  process.send(release, Nil)
  assert stream.await_stopped(handle, within: 1000)
}

pub fn retryable_terminal_does_not_fallback_before_transport_drains_test() {
  let attempts = process.new_subject()
  let ready = process.new_subject()
  let transport =
    http.Transport(start_streaming: fn(request, events) {
      process.send(attempts, request.url)
      let owner_ready = process.new_subject()
      let owner =
        process.spawn_unlinked(fn() {
          let release = process.new_subject()
          process.send(owner_ready, release)
          process.send(events, http.RequestFailed(reason: "overloaded"))
          let _release = process.receive_forever(release)
          Nil
        })
      let release = process.receive_forever(owner_ready)
      process.send(ready, #(owner, release))
      Ok(http.RunningRequest(owner:, cancel: fn() { Nil }))
    })
  let handle = gateway.request(two_provider_gateway(transport), main_request())
  let assert Ok(#(owner, release)) = process.receive(ready, within: 1000)
  let assert Ok(#([], stream.Failed(stream.CancellationUnconfirmed))) =
    stream.await_terminal(handle, within: 1000)

  assert process.is_alive(owner)
  assert process.receive(attempts, within: 1000)
    == Ok("https://primary.test/v1/messages")
  assert process.receive(attempts, within: 100) == Error(Nil)
  process.send(release, Nil)
  assert stream.await_stopped(handle, within: 1000)
}

pub fn consumer_death_cancels_and_reaps_transport_test() {
  let ready = process.new_subject()
  let owners = process.new_subject()
  let cancelled = process.new_subject()
  let transport =
    http.Transport(start_streaming: fn(_request, _events) {
      let owner =
        process.spawn_unlinked(fn() {
          process.receive_forever(process.new_subject())
        })
      process.send(owners, owner)
      Ok(
        http.RunningRequest(owner:, cancel: fn() {
          process.send(cancelled, Nil)
          process.kill(owner)
        }),
      )
    })
  let consumer =
    process.spawn_unlinked(fn() {
      let _handle =
        gateway.request(two_provider_gateway(transport), main_request())
      process.send(ready, Nil)
      process.receive_forever(process.new_subject())
    })
  assert process.receive(ready, within: 1000) == Ok(Nil)
  let assert Ok(transport_owner) = process.receive(owners, within: 1000)
  let transport_monitor = process.monitor(transport_owner)
  process.kill(consumer)
  assert process.receive(cancelled, within: 1000) == Ok(Nil)
  assert process.new_selector()
    |> process.select_specific_monitor(transport_monitor, fn(_down) { True })
    |> process.selector_receive(1000)
    == Ok(True)
}

pub fn unroutable_role_fails_in_band_test() {
  let gw = two_provider_gateway(fixture.transport([]))
  let request =
    model.ProviderRequest(
      ..main_request(),
      target: model.ForRole(model.Vision, None),
    )
  let handle = gateway.request(gw, request)
  let assert Ok(#([], stream.Failed(stream.NoIdentity(role: "vision")))) =
    stream.await_terminal(handle, within: 2000)
}

// --- the reasoning-budget overlay (protocol-change/009) --------------------
//
// A role walk may reach a target whose route row declares a different
// reasoning budget than the head's. `ForRole.thinking` decides which
// budget every attempt is made at: `Some(level)` overlays that level onto
// the whole chain, `None` leaves each entry's own. Both halves are pinned
// here because the wire cost of getting either wrong is silent — a turn
// that asked to think hard settling on a fallback that thought not at all.

// Main's chain with the two ends declaring *different* static levels, so
// an overlay and an absent overlay cannot produce the same bytes.
fn thinking_chain_gateway(transport: http.Transport) -> gateway.Gateway {
  two_provider_gateway(transport)
  |> gateway.route(model.Main, [
    model.ResolvedModel(
      ..target("primary", "model-a"),
      thinking: model.ThinkingHigh,
    ),
    model.ResolvedModel(
      ..target("backup", "model-b"),
      thinking: model.ThinkingOff,
    ),
  ])
}

// Every request body the walk put on the wire, in attempt order. The
// subject is owned by the calling test process, so the pump's sends queue
// in its own mailbox and can be drained after the terminal arrives.
fn walk_bodies(thinking: option.Option(model.ThinkingLevel)) -> List(String) {
  let bodies = process.new_subject()
  let transport =
    fixture.routing_transport(fn(request: http.HttpRequest) {
      process.send(bodies, request.body)
      case string.contains(request.url, "primary.test") {
        True -> overloaded_response()
        False -> fixture.ok_response(happy_transcript("From backup"))
      }
    })
  let request =
    model.ProviderRequest(
      ..main_request(),
      target: model.ForRole(model.Main, thinking),
    )
  let handle = gateway.request(thinking_chain_gateway(transport), request)
  let assert Ok(#(_deltas, stream.Settled(..))) =
    stream.await_terminal(handle, within: 2000)
    as "the walk must reach backup and settle"
  drain(bodies, [])
}

fn drain(subject: process.Subject(String), seen: List(String)) -> List(String) {
  case process.receive(subject, within: 500) {
    Ok(body) -> drain(subject, [body, ..seen])
    Error(Nil) -> list.reverse(seen)
  }
}

pub fn for_role_overlays_one_thinking_level_on_every_attempt_test() {
  // The head declares high and the fallback declares off; a turn asking
  // for medium must reach *both* at medium.
  let assert [head, fallback] = walk_bodies(Some(model.ThinkingMedium))
    as "the walk must have attempted both targets"
  assert string.contains(head, "\"budget_tokens\":8192")
  assert string.contains(fallback, "\"budget_tokens\":8192")
}

pub fn for_role_without_an_overlay_uses_each_entrys_own_level_test() {
  let assert [head, fallback] = walk_bodies(None)
    as "the walk must have attempted both targets"
  // The head's own declared high…
  assert string.contains(head, "\"budget_tokens\":16384")
  // …and the fallback's own off, which sends no thinking field at all.
  assert !string.contains(fallback, "budget_tokens")
  assert !string.contains(fallback, "\"thinking\"")
}

pub fn for_resolved_dispatches_exactly_once_test() {
  // ForResolved never falls back, even on a retryable failure.
  let transport =
    fixture.routing_transport(fn(request) {
      case string.contains(request.url, "primary.test") {
        True -> overloaded_response()
        False -> fixture.ok_response(happy_transcript("From backup"))
      }
    })
  let request =
    model.ProviderRequest(
      ..main_request(),
      target: model.ForResolved(target("primary", "model-a")),
    )
  let handle = gateway.request(two_provider_gateway(transport), request)
  let assert Ok(#([], stream.Failed(stream.HttpError(status: 529, ..)))) =
    stream.await_terminal(handle, within: 2000)
}

pub fn missing_secret_fails_with_name_only_test() {
  let gw =
    gateway.new(
      transport: fixture.transport([]),
      secrets: secret.from_list([]),
      clock: clock.fixed(at: 0),
    )
    |> gateway.add_provider(gateway.AnthropicProvider(
      name: "anthropic",
      base_url: "https://api.anthropic.com",
      api_key_secret: "ANTHROPIC_API_KEY",
    ))
    |> gateway.route(model.Main, [target("anthropic", "model-a")])
  let handle = gateway.request(gw, main_request())
  let assert Ok(#([], stream.Failed(error))) =
    stream.await_terminal(handle, within: 2000)
  assert error
    == stream.NoSecret(provider: "anthropic", secret_name: "ANTHROPIC_API_KEY")
}

pub fn unknown_provider_in_resolved_identity_fails_in_band_test() {
  let gw = two_provider_gateway(fixture.transport([]))
  let request =
    model.ProviderRequest(
      ..main_request(),
      target: model.ForResolved(target("ghost", "phantom-model")),
    )
  let handle = gateway.request(gw, request)
  let assert Ok(#([], stream.Failed(stream.UnknownProvider(provider: "ghost")))) =
    stream.await_terminal(handle, within: 2000)
}

// --- secret leak scan --------------------------------------------------------

pub fn secret_never_appears_in_any_produced_structure_test() {
  // A full fixture session: resolve, dispatch, stream, settle — then a
  // failing run for the error path. The secret must appear in NO
  // returned or accumulated structure's rendered debug output.
  let gw =
    two_provider_gateway(
      fixture.transport(fixture.ok_response(happy_transcript("Hello"))),
    )
  let resolve_result = gateway.resolve(gw, model.Main)
  let handle = gateway.request(gw, main_request())
  let assert Ok(#(deltas, terminal)) =
    stream.await_terminal(handle, within: 2000)

  let failing = two_provider_gateway(fixture.transport(overloaded_response()))
  let failed_handle = gateway.request(failing, main_request())
  let assert Ok(#(failed_deltas, failed_terminal)) =
    stream.await_terminal(failed_handle, within: 2000)

  let rendered =
    fixture.rendered(#(
      resolve_result,
      deltas,
      terminal,
      failed_deltas,
      failed_terminal,
    ))
  assert !string.contains(rendered, secret_value)
  assert !string.contains(rendered, "sk-backup-key")
  // Sanity: the scan corpus is not empty.
  assert string.length(rendered) > 100
}

pub fn described_errors_never_carry_the_secret_test() {
  let failing = two_provider_gateway(fixture.transport(overloaded_response()))
  let handle = gateway.request(failing, main_request())
  let assert Ok(#(_deltas, stream.Failed(error))) =
    stream.await_terminal(handle, within: 2000)
  assert !string.contains(stream.describe_error(error), secret_value)
}
