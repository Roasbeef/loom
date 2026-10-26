//// Responses corruption through the real gateway, runtime and durable store.
//// Scripted HTTP is the only transport substitution. Each retry records the
//// previous request owner's death before it starts a new request.

import broker/broker
import broker/exec
import broker/policy
import broker/token
import client/catalog
import client/escalate
import client/wiring
import core/clock
import core/codec
import core/entry
import core/json.{type JsonValue}
import core/message
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import machine/operation
import machine/strand
import provider/gateway
import provider/http
import provider/model
import provider/secret
import runtime/api
import session/session
import storage/storage
import support/script
import tools/tool

const canary = "responses-conformance-request-only-canary"

const tool_name = "fixture_answer"

const model_id = "responses-fixture-model"

fn config(
  sess: session.Session,
  brk: broker.Broker,
  executions: process.Subject(JsonValue),
  gw: gateway.Gateway,
  resolved: model.ResolvedModel,
) -> wiring.Config {
  let registry =
    tool.registry([
      tool.Tool(
        name: "fixture_answer",
        description: "Return the fixed fixture answer.",
        prompt_snippet: None,
        schema: json.Object([
          #("type", json.String("object")),
          #("properties", json.Object([])),
        ]),
        replay: tool.Safe,
        execution_mode: tool.Concurrent,
        requirements: policy.workspace_default,
        run: fn(_ctx, arguments) {
          process.send(executions, arguments)
          tool.success("fixture result")
        },
      ),
    ])

  wiring.Config(
    observe_output: wiring.unobserved(),
    gateway: gw,
    role: model.Main,
    facts: fn(_identity) {
      Ok(#(resolved, "openai-responses", catalog.ReadsImages))
    },
    system: Some("Use the supplied tool once."),
    api: "openai-responses",
    fallback_context_window: 200_000,
    fallback_max_output_tokens: 4096,
    provider_timeout_ms: 3000,
    session: sess,
    compaction: operation.CompactionSettings(False, 0, 0),
    broker: brk,
    broker_timeout_ms: 1000,
    registry:,
    workspace: "/nonexistent/responses-fixture",
    blob_root: "/nonexistent/responses-fixture/blobs",
    base_policy: policy.workspace_default("/nonexistent/responses-fixture"),
    escalations: escalate.none(),
    demand: exec.BestEffort,
    env: [],
    clock: clock.stepping(2000, 1),
    entropy: fn() { int.random(1_000_000_000) },
  )
}

fn final_turn() -> List(String) {
  [
    response_event(
      "response.created",
      "resp_final",
      "in_progress",
      [],
      0,
      0,
      0,
      0,
    ),
    ..list.append(text_events("msg_final", 0, "final_answer", "Finished."), [
      response_event(
        "response.completed",
        "resp_final",
        "completed",
        [
          message_item("msg_final", "completed", "final_answer", [
            text_part("output_text", "Finished."),
          ]),
        ],
        150,
        12,
        40,
        3,
      ),
    ])
  ]
}

fn text_events(
  id: String,
  index: Int,
  phase: String,
  text: String,
) -> List(String) {
  [
    item_event(
      "response.output_item.added",
      index,
      message_item(id, "in_progress", phase, []),
    ),
    part_event(
      "response.content_part.added",
      id,
      index,
      "content_index",
      text_part("output_text", ""),
    ),
    text_event(
      "response.output_text.delta",
      id,
      index,
      "content_index",
      "delta",
      text,
    ),
    text_event(
      "response.output_text.done",
      id,
      index,
      "content_index",
      "text",
      text,
    ),
    part_event(
      "response.content_part.done",
      id,
      index,
      "content_index",
      text_part("output_text", text),
    ),
    item_event(
      "response.output_item.done",
      index,
      message_item(id, "completed", phase, [text_part("output_text", text)]),
    ),
  ]
}

fn text_part(kind: String, text: String) -> JsonValue {
  json.Object([#("type", json.String(kind)), #("text", json.String(text))])
}

fn message_item(
  id: String,
  status: String,
  phase: String,
  content: List(JsonValue),
) -> JsonValue {
  json.Object([
    #("id", json.String(id)),
    #("type", json.String("message")),
    #("role", json.String("assistant")),
    #("status", json.String(status)),
    #("phase", json.String(phase)),
    #("content", json.Array(content)),
  ])
}

fn call_item(status: String, arguments: String) -> JsonValue {
  json.Object([
    #("id", json.String("fc_fixture")),
    #("type", json.String("function_call")),
    #("status", json.String(status)),
    #("call_id", json.String("call_fixture")),
    #("name", json.String(tool_name)),
    #("arguments", json.String(arguments)),
  ])
}

fn response_event(
  kind: String,
  id: String,
  status: String,
  output: List(JsonValue),
  input: Int,
  tokens: Int,
  cached: Int,
  reasoning: Int,
) -> String {
  event(kind, [
    #(
      "response",
      json.Object([
        #("id", json.String(id)),
        #("model", json.String(model_id)),
        #("status", json.String(status)),
        #("error", json.Null),
        #("output", json.Array(output)),
        #(
          "usage",
          json.Object([
            #("input_tokens", json.Int(input)),
            #("output_tokens", json.Int(tokens)),
            #("total_tokens", json.Int(input + tokens)),
            #(
              "input_tokens_details",
              json.Object([#("cached_tokens", json.Int(cached))]),
            ),
            #(
              "output_tokens_details",
              json.Object([#("reasoning_tokens", json.Int(reasoning))]),
            ),
          ]),
        ),
      ]),
    ),
  ])
}

fn item_event(kind: String, index: Int, item: JsonValue) -> String {
  event(kind, [#("output_index", json.Int(index)), #("item", item)])
}

fn part_event(
  kind: String,
  id: String,
  index: Int,
  index_key: String,
  part: JsonValue,
) -> String {
  event(kind, [
    #("item_id", json.String(id)),
    #("output_index", json.Int(index)),
    #(index_key, json.Int(0)),
    #("part", part),
  ])
}

fn text_event(
  kind: String,
  id: String,
  index: Int,
  index_key: String,
  text_key: String,
  text: String,
) -> String {
  event(kind, [
    #("item_id", json.String(id)),
    #("output_index", json.Int(index)),
    #(index_key, json.Int(0)),
    #(text_key, json.String(text)),
  ])
}

fn event(kind: String, fields: List(#(String, JsonValue))) -> String {
  "event: "
  <> kind
  <> "\ndata: "
  <> json.to_string(json.Object([#("type", json.String(kind)), ..fields]))
  <> "\n\n"
}

fn field(value: JsonValue, key: String) -> JsonValue {
  let assert json.Object(fields) = value as "wire item must be an object"
  case list.key_find(fields, key) {
    Ok(value) -> value
    Error(Nil) -> json.Null
  }
}

// The transport reports each prepared owner and the preceding owner's death.
// The second preparation can therefore prove that the failed request drained
// before the machine started its retry, rather than merely observing an end
// marker in the scripted stream.
type RecoveryCounter {
  NextRecovery(reply: process.Subject(Int))
}

type OwnerCheck {
  CheckOwner(owner: process.Pid, reply: process.Subject(Option(process.Pid)))
}

fn owner_checker() -> process.Subject(OwnerCheck) {
  let assert Ok(started) =
    actor.new(None)
    |> actor.on_message(fn(previous, command) {
      case command {
        CheckOwner(owner, reply) -> {
          process.send(reply, previous)
          actor.continue(Some(owner))
        }
      }
    })
    |> actor.start
  started.data
}

fn drained(previous: Option(process.Pid)) -> Bool {
  case previous {
    None -> True
    Some(pid) -> !process.is_alive(pid)
  }
}

fn recovery_counter() -> process.Subject(RecoveryCounter) {
  let assert Ok(started) =
    actor.new(0)
    |> actor.on_message(fn(count, command) {
      case command {
        NextRecovery(reply) -> {
          process.send(reply, count)
          actor.continue(count + 1)
        }
      }
    })
    |> actor.start
  started.data
}

/// A malformed part is settled separately before a fresh attempt succeeds.
///
/// ## Examples
///
/// Run `scripts/test.sh conformance --match responses_recovery`.
pub fn responses_recovery_separates_partial_attempt_test() -> Nil {
  // A live preceding owner must fail the oracle without a wait that could
  // itself serialize an incorrectly early retry.
  let checker = owner_checker()
  let owner = process.self()
  let first =
    process.call(checker, 1000, fn(reply) { CheckOwner(owner, reply) })
  let second =
    process.call(checker, 1000, fn(reply) { CheckOwner(owner, reply) })
  assert drained(first)
  assert !drained(second)
  recovery_run(1, operation.Unbounded, True)
}

/// An unbounded retry policy must still stop after three corruptions.
///
/// ## Examples
///
/// Run `scripts/test.sh conformance --match responses_recovery`.
pub fn responses_recovery_caps_unbounded_test() -> Nil {
  recovery_run(9, operation.Unbounded, False)
}

/// The recovery ceiling must not widen a stricter existing policy.
///
/// ## Examples
///
/// Run `scripts/test.sh conformance --match responses_recovery`.
pub fn responses_recovery_respects_stricter_policy_test() -> Nil {
  recovery_run(9, operation.Bounded(max_attempts: 2), False)
}

fn recovery_run(
  corrupt_count: Int,
  bound: operation.RetryBudget,
  succeeds: Bool,
) {
  let requests = process.new_subject()
  let executions = process.new_subject()
  let owners = process.new_subject()
  let counter = recovery_counter()
  let checker = owner_checker()
  let assert Ok(sess) = session.open_memory(clock.stepping(1000, 1))
  let assert Ok(brk) =
    broker.start(
      broker.BrokerConfig(
        entropy: token.production_entropy(),
        clock: clock.stepping(1000, 1),
        checkout: fn() { Error(exec.AllBusy(size: 0)) },
        checkin: fn(_helper) { Nil },
      ),
    )
  let scripted =
    script.owned_transport(fn(request, events) {
      let n = process.call(counter, 1000, fn(reply) { NextRecovery(reply) })
      process.send(requests, request)
      process.send(events, http.ResponseStatus(200, []))
      let frames = case n < corrupt_count {
        True -> malformed_turn()
        False -> final_turn()
      }
      list.each(frames, fn(frame) {
        process.send(events, http.ResponseChunk(bit_array.from_string(frame)))
      })
      process.send(events, http.ResponseEnd)
    })
  let transport =
    http.Transport(prepare_streaming: fn(request, subject) {
      use prepared <- result.try(scripted.prepare_streaming(request, subject))
      let previous =
        process.call(checker, 2000, fn(reply) {
          CheckOwner(prepared.running.owner, reply)
        })
      Ok(
        http.PreparedRequest(..prepared, begin: fn() {
          process.send(owners, drained(previous))
          prepared.begin()
        }),
      )
    })
  let resolved =
    model.ResolvedModel(
      provider: "responses",
      model_id:,
      thinking: model.ThinkingHigh,
      context_window: 200_000,
      max_output_tokens: 4096,
    )
  let backup = model.ResolvedModel(..resolved, provider: "backup")
  let gw =
    gateway.new(
      transport,
      secret.from_list([#("FIXTURE_KEY", canary)]),
      clock.stepping(1000, 1),
    )
    |> gateway.add_provider(gateway.OpenAiResponsesProvider(
      name: "responses",
      base_url: "https://responses.invalid/v1",
      api_key_secret: "FIXTURE_KEY",
    ))
    |> gateway.add_provider(gateway.OpenAiResponsesProvider(
      name: "backup",
      base_url: "https://backup.invalid/v1",
      api_key_secret: "FIXTURE_KEY",
    ))
    |> gateway.route(model.Main, [resolved, backup])
    |> gateway.with_attempt_timeout(2000)
  let effects =
    wiring.build_effects(config(sess, brk, executions, gw, resolved))
  let configuration =
    strand.StrandConfiguration(
      model: strand.ModelIdentity("responses", model_id),
      thinking_level: strand.ThinkingHigh,
      active_tool_names: [tool_name],
    )
  let options = api.default_options(configuration)
  let assert Ok(runtime) =
    api.open(
      sess,
      effects,
      api.Options(
        ..options,
        retry_policy: operation.NormalizedRetryPolicy(
          attempts: bound,
          base_delay_ms: 1,
          max_delay_ms: 10,
        ),
      ),
    )
  let assert Ok(op) =
    api.prompt(runtime, [
      message.UserMessage(
        content: [message.UserText("Recover.", None)],
        timestamp: 0,
        origin: None,
      ),
    ])
  let outcome = api.await_result(runtime, op, within_ms: 10_000)
  let rows = storage.scan_entries(sess.store, storage.entry_scan())
  let ledger = storage.scan_usage(sess.store, storage.usage_scan())
  let assert Ok(Nil) = api.close(runtime)
  broker.stop(brk)
  case succeeds {
    True -> {
      let assert Ok(operation.RunLastResult(
        outcome: operation.RunCompleted(..),
        ..,
      )) = outcome
      Nil
    }
    False -> {
      let assert Ok(operation.RunLastResult(
        outcome: operation.RunFailed(..),
        ..,
      )) = outcome
      Nil
    }
  }
  let expected = case bound, succeeds {
    _, True -> 2
    operation.Bounded(max_attempts: n), False -> n
    operation.Unbounded, False -> 3
  }
  let captured =
    list.map(list.repeat(Nil, expected), fn(_) {
      let assert Ok(request) = process.receive(requests, 1000)
      request
    })
  assert process.receive(requests, 0) == Error(Nil)
  assert list.all(captured, fn(request) {
    string.contains(request.url, "responses.invalid")
  })
  assert process.receive(executions, 0) == Error(Nil)
  let assert Ok(entries) = rows
  let assert Ok(usage_rows) = ledger
  assert list.length(usage_rows) == expected
  let failures =
    list.filter_map(entries, fn(row) {
      case row {
        entry.MessageEntry(
          message: message.AssistantMessage(
            content: [],
            stop_reason: message.Errored,
            raw_stop_reason: Some("retryable"),
            diagnostics: Some(diagnostics),
            usage:,
            ..,
          ),
          ..,
        ) -> Ok(#(diagnostics, usage))
        _ -> Error(Nil)
      }
    })
  let expected_failures = case succeeds {
    True -> expected - 1
    False -> expected
  }
  assert list.length(failures) == expected_failures
  list.each(failures, fn(failure) {
    assert field(failure.0, "retry_max_attempts") == json.Int(3)
    assert failure.1.input == 80
    assert failure.1.cache_read == 20
    assert failure.1.output == 20
  })
  let encoded =
    json.to_string(json.Array(list.map(entries, codec.encode_entry)))
  assert string.contains(encoded, "retryable")
  case succeeds {
    True -> {
      let finals =
        list.filter_map(entries, fn(row) {
          case row {
            entry.MessageEntry(
              message: message.AssistantMessage(
                content: [message.AssistantText("Finished.", ..)],
                stop_reason: message.Stop,
                ..,
              ),
              ..,
            ) -> Ok(Nil)
            _ -> Error(Nil)
          }
        })
      assert list.length(finals) == 1
    }
    False -> {
      assert !string.contains(encoded, "Finished.")
    }
  }
  list.each(list.repeat(Nil, expected), fn(_) {
    assert process.receive(owners, 1000) == Ok(True)
  })
  assert process.receive(owners, 0) == Error(Nil)
}

fn malformed_turn() -> List(String) {
  let text =
    list.filter(text_events("msg_bad", 1, "commentary", "partial"), fn(frame) {
      !string.contains(frame, "response.output_text.done")
      && !string.contains(frame, "response.content_part.done")
    })
  let call = [
    item_event("response.output_item.added", 0, call_item("in_progress", "")),
    event("response.function_call_arguments.delta", [
      #("item_id", json.String("fc_fixture")),
      #("output_index", json.Int(0)),
      #("delta", json.String("{}")),
    ]),
    event("response.function_call_arguments.done", [
      #("item_id", json.String("fc_fixture")),
      #("output_index", json.Int(0)),
      #("arguments", json.String("{}")),
    ]),
    item_event("response.output_item.done", 0, call_item("completed", "{}")),
  ]
  [
    response_event(
      "response.created",
      "resp_bad",
      "in_progress",
      [],
      100,
      20,
      20,
      7,
    ),
    ..list.append(call, text)
  ]
}
