//// A regression pin for the `agent_*` family's narrowed capture.
////
//// `docs/design-notes/daemon-memory.md`'s "option A evaluated" section
//// measured each `agent_*` tool at 0.028 MiB because its closure held
//// the whole `Agency` record rather than the one slot it calls. The fix
//// binds each tool to the slot before building its closure
//// (`packages/tools/src/tools/agent.gleam`); this test would fail again
//// if a future edit went back to handing a whole `Agency` to a
//// constructor and closing over it.
////
//// The method mirrors `client/test/client/wiring_test.gleam`'s registry
//// padding tests: build two agencies alike except for a large value
//// planted in a slot no `agent_spawn` call reads, and assert the tool's
//// `run` closure does not grow with it.

import core/clock
import core/ids
import gleam/list
import gleam/option.{None}
import support/internal/ffi_memory
import tools/agent

// An Agency identical to the fixture in `agent_test.gleam` in every slot
// `agent_spawn` never touches, except that `roster`'s closure additionally
// holds a list of the given length. `agent_spawn` calls only `spawn` and
// reads only `model_names`, so a `spawn_tool` built correctly must not
// see this padding at all.
fn padded_agency(padding_words: Int) -> agent.Agency {
  let padding = list.repeat(0, padding_words)
  agent.Agency(
    spawn: fn(caller, request) {
      Ok(agent.Spawned(
        handle: agent.Handle(strand: caller.strand, operation: caller.operation),
        strand: caller.strand,
        tools: option.unwrap(request.tools, []),
        model: option.unwrap(request.model, "default-model"),
        model_id: "provider-model-id",
        deadline_ms: None,
      ))
    },
    send: fn(_caller, _to, _text, _within_ms) {
      Ok(agent.Started(operation: an_op(), deadline_ms: None))
    },
    wait: fn(_caller, _handles, _within_ms) { Ok([]) },
    note: fn(_caller, _key, _value) { Ok(Nil) },
    notes: fn(_caller, _prefix) { Ok([]) },
    // The padded slot. `list.length` keeps the capture live rather than
    // one the compiler could drop as unused.
    todos: fn(_caller, _step) { Error(agent.AgencyUnavailable) },
    roster: fn(_caller) {
      case list.length(padding) {
        0 -> Ok([])
        _ -> Ok([])
      }
    },
    max_wait_ms: 30_000,
    model_names: ["reviewer", "worker"],
  )
}

fn an_op() -> ids.OpId {
  let #(op, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 1))
  op
}

pub fn spawn_tool_does_not_capture_whole_agency_test() {
  let light = padded_agency(1)
  let heavy = padded_agency(4096)

  // Sanity: the padding actually lands where the closures said it would,
  // so a size difference below would be a real regression and not a test
  // that never planted anything.
  assert ffi_memory.flat_words(heavy.roster)
    > ffi_memory.flat_words(light.roster) + 4096

  let spawn_light = agent.spawn_tool(light.spawn, light.model_names)
  let spawn_heavy = agent.spawn_tool(heavy.spawn, heavy.model_names)
  assert ffi_memory.flat_words(spawn_heavy.run)
    == ffi_memory.flat_words(spawn_light.run)

  let note_light = agent.note_tool(light.note)
  let note_heavy = agent.note_tool(heavy.note)
  assert ffi_memory.flat_words(note_heavy.run)
    == ffi_memory.flat_words(note_light.run)
}
