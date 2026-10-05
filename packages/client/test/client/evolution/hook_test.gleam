//// A real promoted bus retains one generation through the native tool body.
//// Queued activation must wait for its result transform and cleanup witness.

import client/evolution/hook
import client/evolution/live
import client/evolution/queue
import client/evolution/record
import client/evolution/record_test
import client/evolution/retirement
import client/evolution/store as live_failure
import client/extension/hooks
import core/clock
import core/codec
import core/ids
import core/json
import core/message
import core/msgpack
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/option.{None, Some}
import gleeunit/should
import machine/operation
import runtime/effects
import telemetry/log
import weft
import weft/poll

pub fn native_tool_and_promoted_result_finish_before_activation_test() {
  let events = process.new_subject()
  let gates = process.new_subject()
  let assert Ok(owner) =
    live.start(
      live.Config(
        clock: clock.fixed(0),
        stage: fn(selected) { stage(selected, events) },
        adopt: fn(_) { Ok(Nil) },
        recover: fn() { Ok(None) },
      ),
    )
    as "native live owner starts"
  let first = selected(1)
  live.activate(owner, transition(first), 1000) |> should.equal(Ok(first))
  let wired = hook.wire(native_effects(events, gates), owner)
  let outcomes = process.new_subject()
  let run =
    weft.new_prepared([
      weft.managed(fn(_ledger) { Ok(wired.tools.run(request())) }),
    ])
    |> weft.deadline(5000)
  let _relay = weft.start_relayed(run, to: outcomes)
  process.receive(events, 1000) |> should.equal(Ok("1:tool_call"))
  process.receive(events, 1000) |> should.equal(Ok("native"))
  let assert Ok(gate) = process.receive(gates, 1000)
    as "native tool owns its continuation subject"
  let assert Ok(front) = queue.start(owner, clock.fixed(0))
    as "bounded transition queue starts"
  let second = selected(2)
  queue.enqueue(front, transition(second), "second")
  |> should.equal(Ok(queue.Queued("2")))
  process.receive(events, 0) |> should.equal(Error(Nil))

  // The successor may stage only after both tool phases have used generation
  // one. The native settlement fields survive the promoted text transform.
  process.send(gate, Nil)
  let assert Ok(weft.PulledOutcome(weft.Completed(_, answer))) =
    process.receive(outcomes, 2000)
    as "native invocation completes"
  answer
  |> should.equal(effects.ToolCompleted(
    result: reply("1", Failed),
    terminate: True,
  ))
  process.receive(outcomes, 1000) |> should.equal(Ok(weft.AllDelivered))
  process.receive(events, 1000) |> should.equal(Ok("1:tool_result"))
  process.receive(events, 1000) |> should.equal(Ok("retire:1"))
  poll.until(within: 2000, every: 5, attempt: fn() {
    case queue.poll(front, "2") {
      Ok(Some(queue.Completed(selection))) -> poll.Done(selection)
      Ok(Some(queue.Queued(_))) | Ok(Some(queue.Running(_))) -> poll.Retry
      _ -> poll.Fail("successor did not publish")
    }
  })
  |> should.equal(poll.Answered(second))
  queue.close(front) |> should.equal(Ok(Nil))
  live.close(owner, 1000) |> should.equal(Ok(Nil))
  process.receive(events, 1000) |> should.equal(Ok("retire:2"))
}

fn stage(
  selected: record.Selection,
  events: Subject(String),
) -> Result(live.Generation, live_failure.Refusal) {
  let version = int.to_string(selected.generation)
  let assert Ok(bus) =
    hooks.start(
      [
        hooks.Extension(
          name: version,
          events: ["tool_call", "tool_result"],
          invoke: fn(_name, event, _args, _deadline) {
            process.send(events, version <> ":" <> event)
            let answer = case event {
              "tool_call" -> json.Object([#("verdict", json.String("allow"))])
              _result ->
                json.Object([
                  #("message", codec.encode_message(reply(version, Succeeded))),
                ])
            }
            Ok(msgpack.StringValue(json.to_string(answer)))
          },
        ),
      ],
      log.discard(),
    )
    as "promoted bus starts linked to its generation owner"
  Ok(live.Generation(
    mode: live.ReplacementOnly,
    selection: selected,
    tools: [],
    hooks: Some(bus),
    inventory: fn() { Ok(json.Null) },
    validate: fn() { Ok(Nil) },
    retire: retirement.repeat(fn() {
      hooks.close(bus)
      process.send(events, "retire:" <> version)
      Ok(Nil)
    }),
  ))
}

fn selected(version: Int) -> record.Selection {
  let candidate = record_test.candidate()
  record.Selection(
    candidate.id,
    record.evidence_placeholder(),
    candidate.scope,
    candidate.name,
    version,
  )
}

fn transition(selection: record.Selection) -> live.Transition {
  live.Transition(
    int.to_string(selection.generation),
    10_000,
    selection,
    fn() { Ok(selection) },
    fn() { Ok(None) },
  )
}

fn request() -> effects.ToolRun {
  let #(op, _) = ids.mint_op(ids.generator(clock.fixed(0), 7))
  effects.ToolRun(
    operation: op,
    step_id: "native",
    source_index: 0,
    strand: "main",
    call: message.ToolCall("call", "native", json.Object([]), None, None),
    arguments: json.Object([]),
    replay: operation.ReplayNever,
    grants: [],
  )
}

fn native_effects(
  events: Subject(String),
  gates: Subject(Subject(Nil)),
) -> effects.Effects {
  effects.Effects(
    clock: clock.fixed(0),
    entropy: fn() { 0 },
    timers: effects.Timers(after: fn(_delay, _wake) { Nil }),
    provider: effects.ProviderSurface(timeout_ms: 0, request: fn(_spec) {
      panic as "this fixture never requests a model"
    }),
    tools: effects.ToolSurface(
      clear: fn(_query) { effects.ClearanceRefused("unused") },
      run: fn(_request) {
        let gate = process.new_subject()
        process.send(gates, gate)
        process.send(events, "native")
        process.receive(gate, 2000) |> should.equal(Ok(Nil))
        effects.ToolCompleted(result: reply("native", Failed), terminate: True)
      },
      replay_still_safe: fn(_name) { False },
      execution_mode: fn(_name) { effects.ExclusiveExecution },
    ),
    hooks: effects.default_hooks(),
  )
}

type Settlement {
  Succeeded
  Failed
}

fn reply(text: String, failed: Settlement) -> message.AgentMessage {
  message.ToolResultMessage(
    tool_call_id: "call",
    tool_name: "native",
    content: [message.ToolResultText(text, None)],
    details: None,
    usage: None,
    added_tool_names: None,
    is_error: failed == Failed,
    timestamp: 0,
  )
}
