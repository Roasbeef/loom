//// The extension memory door against a real session store.
////
//// Two claims live here and nowhere else. **The subtree is the
//// extension's name**, so an extension called `a` and one called `b`
//// cannot see each other's cells however they word the key — the key is
//// composed here, from the record, and no argument contributes to it.
//// And **the cell is durable**: it is a reserved blackboard fact in the
//// session file, so it survives the session being closed and reopened,
//// which is the whole difference between this door and `kv.*`.
////
//// The durability case runs over a real SQLite session file rather than
//// an in-memory one, because "survives a reopen" is not a question an
//// in-memory store can be asked. Everything else runs in memory, where
//// the answer does not depend on the backend.

import client/extension/memory
import core/clock
import core/json
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import machine/strand as machine_strand
import provider/stream
import runtime/api
import runtime/effects
import session/session
import simplifile

// --- the rig ----------------------------------------------------------------

type Rig {
  Rig(runtime: api.Runtime, door: memory.Door)
}

fn harness(opened: session.Session) -> Result(Rig, String) {
  use entropy <- result.try(start_entropy())
  let configuration =
    machine_strand.StrandConfiguration(
      model: machine_strand.ModelIdentity(provider: "acme", model_id: "loom-1"),
      thinking_level: machine_strand.ThinkingOff,
      active_tool_names: [],
    )
  use runtime <- result.try(
    api.open(
      opened,
      effects.Effects(
        clock: clock.fixed(at: 0),
        entropy:,
        timers: effects.real_timers(),
        provider: hanging_provider(),
        tools: refusing_tools(),
        hooks: effects.default_hooks(),
      ),
      api.default_options(configuration),
    )
    |> result.map_error(string.inspect),
  )
  Ok(Rig(
    runtime:,
    door: memory.door(memory.Wiring(runtime: fn() { Ok(runtime) })),
  ))
}

fn in_memory() -> Result(Rig, String) {
  use opened <- result.try(
    session.open_memory(clock.fixed(at: 0))
    |> result.replace_error("the memory session did not open"),
  )
  harness(opened)
}

fn stop(rig: Rig) -> Nil {
  process.kill(rig.runtime.tree.supervisor)
}

// --- the key ----------------------------------------------------------------

pub fn a_cell_lives_under_its_own_extensions_subtree_test() {
  // The composition, pinned: this is the line the whole confinement
  // rests on, so it is asserted directly rather than inferred from a
  // read that happened to miss.
  assert memory.key(memory.Cell(extension: "web-search", key: "last"))
    == api.ext_fact_prefix <> "web-search/last"
}

// --- one extension cannot read another's ------------------------------------

pub fn an_extension_cannot_read_another_extensions_cell_test() {
  let assert Ok(rig) = in_memory() as "the harness must boot"
  let assert Ok(Nil) =
    rig.door.remember(
      memory.Cell(extension: "a", key: "shared"),
      "{\"who\":\"a\"}",
    )
    as "a must be able to write its own cell"

  // The same leaf, a different extension. Not a refusal — a cell that
  // was never written — because from b's side there is nothing there,
  // which is the honest answer and the one that leaks nothing about
  // whether a wrote anything at all.
  assert rig.door.recall(memory.Cell(extension: "b", key: "shared")) == Ok(None)

  // And a reads back exactly what it wrote.
  assert rig.door.recall(memory.Cell(extension: "a", key: "shared"))
    == Ok(Some("{\"who\":\"a\"}"))
  stop(rig)
}

pub fn a_remember_overwrites_the_cell_it_names_test() {
  let assert Ok(rig) = in_memory() as "the harness must boot"
  let cell = memory.Cell(extension: "a", key: "count")
  let assert Ok(Nil) = rig.door.remember(cell, "1")
    as "the first write must land"
  let assert Ok(Nil) = rig.door.remember(cell, "2")
    as "the second write must land"

  // Latest-wins, as the door's doc says and as `put_reserved_fact` is.
  assert rig.door.recall(cell) == Ok(Some("2"))
  stop(rig)
}

pub fn a_value_that_is_not_json_is_refused_test() {
  let assert Ok(rig) = in_memory() as "the harness must boot"
  let cell = memory.Cell(extension: "a", key: "broken")
  let assert Error(memory.NotJson(reason:)) = rig.door.remember(cell, "{oops")
    as "a value that is not a JSON document is refused"
  assert string.contains(reason, "JSON")

  // Refused means nothing was written, not that something half was.
  assert rig.door.recall(cell) == Ok(None)
  stop(rig)
}

pub fn a_shut_door_refuses_both_arms_in_band_test() {
  let door = memory.shut("this host has no session")
  let cell = memory.Cell(extension: "a", key: "last")
  assert door.remember(cell, "{}")
    == Error(memory.Unavailable(reason: "this host has no session"))
  assert door.recall(cell)
    == Error(memory.Unavailable(reason: "this host has no session"))
}

pub fn a_runtime_that_cannot_be_borrowed_refuses_in_band_test() {
  // The holder not up, or gone: an in-band refusal the extension reads,
  // never a crash on the effect process.
  let door = memory.door(memory.Wiring(runtime: fn() { Error(Nil) }))
  let assert Error(memory.Unavailable(..)) =
    door.recall(memory.Cell(extension: "a", key: "last"))
    as "a borrow that fails is a refusal"
}

// --- the model's own door does not reach it ---------------------------------

pub fn a_remembered_cell_is_not_on_the_models_blackboard_test() {
  let assert Ok(rig) = in_memory() as "the harness must boot"
  let assert Ok(Nil) =
    rig.door.remember(memory.Cell(extension: "a", key: "secret"), "{}")
    as "the cell must be written"

  // `facts` is the listing the blackboard tool reads, and a reserved key
  // is hidden from it — so an extension's memory reaches the model only
  // if the extension puts it there itself.
  let assert Ok(listed) = api.facts(rig.runtime, prefix: None)
    as "the blackboard must list"
  assert listed == []

  // Nor is it the model's to write.
  let assert Error(api.ReservedFactKey(..)) =
    api.put_fact(rig.runtime, memory.key(memory.Cell("a", "secret")), json.Null)
    as "the model's write door refuses the namespace"
  stop(rig)
}

// --- durability -------------------------------------------------------------

pub fn a_remembered_cell_survives_a_reopen_test() {
  let root = "build/extension-memory-test"
  let _stale = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root)
    as "the test root must be creatable"
  let path = root <> "/session.db"
  let cell = memory.Cell(extension: "a", key: "last")

  let assert Ok(first) = sqlite_session(path) as "the session must open"
  let assert Ok(rig) = harness(first) as "the harness must boot"
  let assert Ok(Nil) = rig.door.remember(cell, "{\"seen\":7}")
    as "the cell must be written"
  stop(rig)
  let _sealed = session.close(first)

  // A second session over the same file, with nothing carried across but
  // the bytes on disk.
  let assert Ok(second) = sqlite_session(path) as "the file must reopen"
  let assert Ok(reopened) = harness(second) as "the second harness must boot"
  assert reopened.door.recall(cell) == Ok(Some("{\"seen\":7}"))

  // And the subtree still belongs to whoever wrote it.
  assert reopened.door.recall(memory.Cell(extension: "b", key: "last"))
    == Ok(None)
  stop(reopened)
  let _closed = session.close(second)
  let _removed = simplifile.delete(root)
  Nil
}

fn sqlite_session(path: String) -> Result(session.Session, String) {
  session.open_sqlite(
    path:,
    owner: "extension-memory-test",
    lease_ttl_ms: 60_000,
    clock: clock.fixed(at: 0),
  )
  |> result.map_error(string.inspect)
}

// --- the surfaces the runtime needs and this suite does not -----------------

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
  actor.new(1)
  |> actor.on_message(fn(next, reply) {
    process.send(reply, next)
    actor.continue(next + 1)
  })
  |> actor.start
  |> result.map(fn(counter) {
    fn() { process.call(counter.data, waiting: 1000, sending: fn(r) { r }) }
  })
  |> result.replace_error("the entropy counter did not start")
}
