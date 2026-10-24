//// The orchestrator's half of a staged generation, over a hand-built value.
////
//// `generation_of` is the part of staging that needs no jail: it starts the
//// hook bus over a `Staged` value's `invoke` and puts the catalogue's checks in
//// front of the machine. These tests give it a `Staged` made of closures, so
//// they run without a plane, a compiler or a satellite.

import client/evolution/live
import client/evolution/machine/local
import client/evolution/record
import client/evolution/record_test
import client/evolution/retirement
import client/evolution/staged
import client/evolution/store
import client/extension/hooks
import client/internal/ffi_os
import core/clock
import core/ids
import core/json
import core/msgpack
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/option.{type Option, None, Some}
import gleeunit/should
import telemetry/log

fn catalogue() -> store.Store {
  let assert Ok(opened) =
    store.open(
      "build/test_db/local-evolution-"
        <> int.to_string(ffi_os.system_time_ms())
        <> "-"
        <> int.to_string(ffi_os.unique_positive_integer()),
      store.Owner,
      record_test.candidate().identity,
      clock.fixed(at: 1_700_000_000_000),
    )
    as "the catalogue opens"
  opened
}

fn selection() -> record.Selection {
  let candidate = record_test.candidate()
  record.Selection(
    candidate.id,
    record.evidence_placeholder(),
    candidate.scope,
    candidate.name,
    1,
  )
}

// A staged value with no native resources. The satellite blocks every
// `tool_call` and reports each event it was asked on `seen`.
fn staged_over(
  seen: Subject(String),
  upgrade: Option(staged.Upgrade),
) -> staged.Staged {
  staged.Staged(
    name: "fake-extension",
    selection: selection(),
    tools: [],
    events: ["tool_call"],
    invoke: fn(event, _args, _within) {
      process.send(seen, "invoked:" <> event)
      Ok(msgpack.StringValue("{\"verdict\":\"block\",\"reason\":\"not here\"}"))
    },
    inventory: fn() { Ok(json.Null) },
    retire: retirement.done(),
    upgrade:,
  )
}

fn operation() -> ids.OpId {
  let #(op, _) = ids.mint_op(ids.generator(clock.fixed(0), seed: 1))
  op
}

/// The bus the generation carries is subscribed under the staged value's name
/// and events, and reaches the satellite through its `invoke`: a block the
/// satellite returns is attributed to the extension the value names.
pub fn the_bus_names_the_extension_the_staged_value_names_test() {
  let seen = process.new_subject()
  let assert Ok(generation) =
    local.generation_of(catalogue(), log.discard(), staged_over(seen, None))
    as "a staged value becomes a generation"
  let assert Some(bus) = generation.hooks as "the generation carries a bus"
  hooks.subscribers(bus, on: hooks.Answering) |> should.equal(1)
  hooks.gate(bus, operation(), "any_tool", json.Null, 0)
  |> should.equal(hooks.Block("fake-extension", "not here"))
  process.receive(seen, 0) |> should.equal(Ok("invoked:tool_call"))
  let assert live.ReplacementOnly = generation.mode
    as "no upgrade means replacement only"
}

/// Retirement closes the bus before it runs the staged value's own task. The
/// staged task asks the bus one more question as it runs: a closed bus answers
/// nothing, so the satellite is not reached from inside it. The weft crash
/// report this prints from the dead manager is the expected signature of a
/// closed bus, not a failure.
pub fn retiring_closes_the_bus_before_the_staged_task_test() {
  let seen = process.new_subject()
  let box = process.new_subject()
  let probing =
    staged.Staged(
      ..staged_over(seen, None),
      retire: retirement.repeat(fn() {
        let assert Ok(bus) = process.receive(box, 0)
          as "the bus was handed over"
        case hooks.gate(bus, operation(), "any_tool", json.Null, 0) {
          hooks.Allow -> process.send(seen, "retired:bus-closed")
          hooks.Block(..) -> process.send(seen, "retired:bus-open")
        }
        Ok(Nil)
      }),
    )
  let assert Ok(generation) =
    local.generation_of(catalogue(), log.discard(), probing)
    as "a staged value becomes a generation"
  let assert Some(bus) = generation.hooks as "the generation carries a bus"
  process.send(box, bus)
  let assert Ok(Nil) = retirement.perform(generation.retire)
    as "retirement completes"
  let assert Ok(last) = process.receive(seen, 0)
    as "the staged task reported what it saw"
  last |> should.equal("retired:bus-closed")
}

/// The wrapper, not the machine, asks the catalogue. A selection the
/// catalogue does not hold fails `validate`, and an upgrade is refused before
/// the staged value's `prepare` is reached.
pub fn the_catalogue_is_consulted_by_the_wrapper_test() {
  let seen = process.new_subject()
  let prepared = process.new_subject()
  let upgrade =
    staged.Upgrade(prepare: fn(_selection, _candidate) {
      process.send(prepared, Nil)
      Error(store.Bounds("the machine must not be reached"))
    })
  let assert Ok(generation) =
    local.generation_of(
      catalogue(),
      log.discard(),
      staged_over(seen, Some(upgrade)),
    )
    as "a staged value with an upgrade becomes a generation"
  let assert Error(_) = generation.validate()
    as "an unknown selection is not authorized"
  let assert live.Stateful(prepare:) = generation.mode
    as "an upgrade makes the generation stateful"
  let assert Error(_) = prepare(selection())
    as "an unapproved successor is refused"
  process.receive(prepared, 0) |> should.equal(Error(Nil))
}
