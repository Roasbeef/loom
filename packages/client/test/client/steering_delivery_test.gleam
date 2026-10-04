//// Real runtime steering delivery at the first post-tool generation.
//// The blocked tool is the barrier: both transports admit while it runs,
//// and the very next provider context must contain both exact payloads.

import client/agency
import client/peer_mail
import core/clock.{type Clock}
import core/ids
import core/json
import core/message
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import machine/operation
import machine/strand
import provider/stream
import runtime/api
import runtime/effects
import session/session
import support/addresses
import tools/agent
import weft/actor

fn counting_clock(from: Int, by: Int) -> Clock {
  let assert Ok(counter) =
    actor.new(from)
    |> actor.on_message(fn(now, reply: Subject(Int)) {
      process.send(reply, now)
      actor.continue(now + by)
    })
    |> actor.start
    as "the clock counter must start"
  clock.from_function(fn() {
    process.call(counter.data, waiting: 1000, sending: fn(reply) { reply })
  })
}

pub fn local_and_remote_steering_reach_the_next_provider_context_test() {
  let time = counting_clock(1_756_000_000_000, 3)
  let started = process.new_subject()
  let entropy_clock = counting_clock(7_000_000, 104_729)
  let seen = process.new_subject()
  let assert Ok(counter) =
    actor.new(0)
    |> actor.on_message(fn(index, reply: Subject(Int)) {
      process.send(reply, index)
      actor.continue(index + 1)
    })
    |> actor.start
    as "the provider counter starts"
  let assert Ok(sess) = session.open_memory(time) as "the session opens"
  let config = agency.default_config(addresses.new(), time)
  let configuration =
    strand.StrandConfiguration(
      model: strand.ModelIdentity("acme", "loom-1"),
      thinking_level: strand.ThinkingOff,
      active_tool_names: ["bash"],
    )
  let assert Ok(runtime) =
    api.open(
      sess,
      effects.Effects(
        clock: time,
        entropy: fn() {
          let #(value, _) = clock.read(entropy_clock)
          value
        },
        timers: effects.real_timers(),
        provider: effects.ProviderSurface(timeout_ms: 60_000, request: fn(spec) {
          let events = process.new_subject()
          let assert effects.GenerationRequest(context:, ..) = spec
            as "this fixture only generates assistant messages"
          process.send(seen, context)
          let index = process.call(counter.data, 1000, fn(reply) { reply })
          case index {
            0 -> settle_tool(events)
            _ -> settle_into(events, "complete")
          }
          stream.immediate(events, fn() { Nil })
        }),
        tools: effects.ToolSurface(
          recover: fn(_run, _complete) { effects.UnmanagedLocal },
          clear: fn(query) {
            effects.Cleared(query.call.arguments, operation.ReplaySafe)
          },
          run: fn(run) {
            let release = process.new_subject()
            process.send(started, #(run, release))
            let assert Ok(Nil) = process.receive(release, 5000)
              as "the test releases the existing tool"
            effects.ToolCompleted(
              message.ToolResultMessage(
                tool_call_id: run.call.id,
                tool_name: run.call.name,
                content: [
                  message.ToolResultText("existing tool complete", None),
                ],
                details: None,
                usage: None,
                added_tool_names: None,
                is_error: False,
                timestamp: 0,
              ),
              False,
            )
          },
          replay_still_safe: fn(_) { True },
          execution_mode: fn(_) { effects.ConcurrentExecution },
        ),
        hooks: agency.reaping_hooks(effects.default_hooks(), config),
      ),
      api.default_options(configuration),
    )
    as "the runtime opens"
  let assert Ok(_) = agency.start(config, runtime) as "the agency starts"
  let #(parent_op, generator) =
    ids.mint_op(ids.generator(clock.fixed(1000), 77))
  let #(step, _) = ids.mint_entry(generator)
  let caller =
    agent.Caller(
      "main",
      parent_op,
      ids.entry_id_to_string(step),
      0,
      agent.ToolCall,
    )
  let seam = agency.seam(config)
  let assert Ok(child) =
    seam.spawn(
      caller,
      agent.SpawnRequest(
        purpose: "delivery",
        brief: "run the existing tool",
        model: None,
        tools: None,
        within_ms: None,
        result_schema: None,
        context: agent.Fresh,
        detach: False,
      ),
    )
    as "the recipient is a real child"
  let assert Ok(_initial_context) = process.receive(seen, 5000)
    as "the initial generation starts"
  let assert Ok(#(run, release)) = process.receive(started, 5000)
    as "the existing tool is running"
  assert run.strand == child.strand
  let local = "local exact body: preserve every byte"
  let remote = "remote exact body: preserve every byte"
  let assert Ok(_) = seam.send(caller, child.strand, local, None)
    as "local agency send admits during the tool"
  let #(source_id, _) = ids.mint_session(ids.generator(clock.fixed(1000), 88))
  let source = ids.session_id_to_string(source_id)
  let assert Ok(_) =
    peer_mail.handle(
      runtime,
      time,
      peer_mail.Allow(peer_mail.Grant(
        source,
        "main",
        child.strand,
        peer_mail.BusyOnly,
      )),
    )
    as "the exact remote direction is allowed"
  let assert Ok(_) =
    peer_mail.handle(
      runtime,
      time,
      peer_mail.Deliver(
        peer_mail.Source(source, "main", json.Null),
        child.strand,
        "message-one",
        remote,
      ),
    )
    as "remote delivery admits during the same tool"

  // Admission cannot start another generation while the current tool runs.
  assert process.receive(seen, 0) == Error(Nil)
  process.send(release, Nil)
  let assert Ok(next_context) = process.receive(seen, 5000)
    as "the very next generation receives both queued inputs"
  assert list.contains(
    user_texts(next_context),
    agency.frame_message("main", local),
  )
  assert list.contains(user_texts(next_context), remote)
  assert list.any(next_context, fn(item) {
    case item {
      message.ToolResultMessage(
        content: [message.ToolResultText("existing tool complete", _)],
        ..,
      ) -> True
      _ -> False
    }
  })
    as "the existing tool completed before the queued inputs reached the provider"
  let assert Ok(_) =
    api.await_result(
      api.on_strand(runtime, child.strand),
      child.handle.operation,
      5000,
    )
    as "the run settles normally"
  let assert Ok(_) = api.close(runtime) as "the fixture closes"
}

fn user_texts(context: List(message.AgentMessage)) -> List(String) {
  list.flat_map(context, fn(item) {
    case item {
      message.UserMessage(content:, ..) ->
        list.filter_map(content, fn(block) {
          case block {
            message.UserText(text:, ..) -> Ok(text)
            _ -> Error(Nil)
          }
        })
      _ -> []
    }
  })
}

fn settle_tool(events: Subject(stream.StreamEvent)) -> Nil {
  let response =
    message.AssistantMessage(
      content: [
        message.AssistantToolCall(message.ToolCall(
          "existing",
          "bash",
          json.Object([]),
          None,
          None,
        )),
      ],
      api: "test",
      provider: "acme",
      model: "loom-1",
      response_model: None,
      response_id: None,
      diagnostics: None,
      usage: effects.zero_usage(),
      stop_reason: message.ToolUse,
      deferred: None,
      error_message: None,
      raw_stop_reason: None,
      end_turn: Some(False),
      timestamp: 0,
    )
  let assert Ok(settled) = stream.settle(response)
    as "the tool response settles"
  process.send(events, stream.Settled(settled, effects.zero_usage()))
}

fn settle_into(events: Subject(stream.StreamEvent), text: String) -> Nil {
  {
    let response =
      message.AssistantMessage(
        content: [message.AssistantText(text:, text_signature: None)],
        api: "test",
        provider: "acme",
        model: "loom-1",
        response_model: None,
        response_id: None,
        diagnostics: None,
        usage: effects.zero_usage(),
        stop_reason: message.Stop,
        deferred: None,
        error_message: None,
        raw_stop_reason: None,
        end_turn: Some(True),
        timestamp: 0,
      )
    let assert Ok(settled) = stream.settle(response)
      as "the scripted response must settle"
    process.send(
      events,
      stream.Settled(message: settled, usage: effects.zero_usage()),
    )
  }
}
