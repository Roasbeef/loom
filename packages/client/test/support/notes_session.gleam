//// SQLite-backed Agency for the notes end-to-end fixture. No model or tool
//// is mocked into the note path; idle provider hooks exist only to open
//// the real runtime whose writer owns the blackboard transactions.

import client/agency
import core/clock.{type Clock}
import gleam/erlang/process.{type Subject}
import machine/strand as machine_strand
import provider/stream
import runtime/api
import runtime/effects
import session/session
import support/addresses
import tools/agent
import weft/actor

pub type Session {
  Session(runtime: api.Runtime, agency: agent.Agency)
}

pub fn open(path: String, time: Clock) -> Session {
  let session_clock = time
  let assert Ok(sess) =
    session.open_sqlite(path, "notes-test", 30_000, session_clock)
    as "the SQLite session must open"
  let assert Ok(counter) =
    actor.new(1)
    |> actor.on_message(fn(next, reply: Subject(Int)) {
      process.send(reply, next)
      actor.continue(next + 1)
    })
    |> actor.start
    as "the entropy counter must start"
  let entropy = fn() {
    7_000_000
    + process.call(counter.data, waiting: 1000, sending: fn(reply) { reply })
    * 104_729
  }
  let name = addresses.new()
  let config =
    agency.Config(
      ..agency.default_config(name, counting_clock(1_756_000_000_000, 3)),
      rest: fn(_slice) { Nil },
      first_slice_ms: 1,
      max_slice_ms: 1,
    )
  let configuration =
    machine_strand.StrandConfiguration(
      model: machine_strand.ModelIdentity(provider: "acme", model_id: "loom-1"),
      thinking_level: machine_strand.ThinkingOff,
      active_tool_names: ["agent_spawn", "code_mode"],
    )
  let base = api.default_options(configuration)
  let assert Ok(runtime) =
    api.open(
      sess,
      effects.Effects(
        clock: session_clock,
        entropy:,
        timers: effects.real_timers(),
        provider: effects.ProviderSurface(
          timeout_ms: 60_000,
          request: fn(_spec) {
            stream.immediate(events: process.new_subject(), cancel: fn() { Nil })
          },
        ),
        tools: effects.ToolSurface(
          clear: fn(_query) {
            effects.ClearanceRefused(reason: "no tools in this harness")
          },
          run: fn(_run) { effects.ToolFailed(reason: "no tools") },
          replay_still_safe: fn(_name) { False },
          execution_mode: fn(_name) { effects.ExclusiveExecution },
        ),
        hooks: effects.default_hooks(),
      ),
      api.Options(..base, poll_interval_ms: 25, subagent: agency.is_subagent),
    )
    as "the runtime must open"
  let assert Ok(_holder) = agency.start(config, runtime)
    as "the agency holder must start"
  Session(runtime:, agency: agency.seam(config))
}

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
