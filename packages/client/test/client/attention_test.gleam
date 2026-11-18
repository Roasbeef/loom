//// The host half of `ask` and `notice`, over a real runtime and a real store:
//// the records a call writes, the bounds that need the store, the guard that
//// keeps two callers from both taking the last slot, pruning, and a record
//// surviving a session restart.
////
//// The model-facing half (every bound the arguments decide) is pinned by
//// `tools/attention_test`; the codec by `core/attention_test`.

import client/attention
import client/internal/ffi_os
import core/attention as records
import core/clock
import core/ids
import core/json
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import machine/strand as machine_strand
import provider/stream
import runtime/api
import runtime/effects
import runtime/lineage
import session/session
import simplifile
import tools/agent
import tools/attention as tool_attention

const now = 1_790_000_000_000

const day = 86_400_000

// --- the rig ---------------------------------------------------------------

fn path() -> String {
  let directory =
    "build/attention-test-" <> int.to_string(ffi_os.unique_positive_integer())
  let _removed = simplifile.delete(directory)
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
    as "the scratch directory is made"
  directory <> "/session.db"
}

fn open(path: String) -> api.Runtime {
  let time = clock.fixed(at: now)
  let assert Ok(opened) =
    session.open_sqlite(path, "attention-test", 30_000, time)
    as "the SQLite session must open"
  let configuration =
    machine_strand.StrandConfiguration(
      model: machine_strand.ModelIdentity(provider: "acme", model_id: "loom-1"),
      thinking_level: machine_strand.ThinkingOff,
      active_tool_names: ["ask", "notice"],
    )
  let assert Ok(runtime) =
    api.open(
      opened,
      effects.Effects(
        clock: time,
        entropy: ffi_os.unique_positive_integer,
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
          recover: None,
        ),
        hooks: effects.default_hooks(),
      ),
      api.default_options(configuration),
    )
    as "the runtime must open"
  runtime
}

fn wiring(runtime: api.Runtime) -> attention.Wiring {
  attention.Wiring(
    runtime: fn() { Ok(runtime) },
    clock: clock.fixed(at: now),
    entropy: ffi_os.unique_positive_integer,
  )
}

fn operation() -> ids.OpId {
  let #(id, _) = ids.mint_op(ids.generator(clock.fixed(at: 5), seed: 9))
  id
}

fn caller(strand: String) -> agent.Caller {
  agent.Caller(
    strand:,
    operation: operation(),
    step_id: "step-1",
    source_index: 3,
    minter: agent.ToolCall,
  )
}

fn request(to: option.Option(String)) -> tool_attention.AskRequest {
  tool_attention.AskRequest(to:, why: Some("The build is red."), questions: [
    records.Question(
      key: "q1",
      prompt: "Retry?",
      kind: records.Confirm,
      options: [],
    ),
  ])
}

fn notice() -> tool_attention.NoticeRequest {
  tool_attention.NoticeRequest(
    kind: records.Bug,
    text: "No backoff.",
    path: Some("src/retry.gleam"),
    line: Some(41),
  )
}

fn ask_n(wiring: attention.Wiring, times: Int) -> Nil {
  list.repeat(Nil, times)
  |> list.each(fn(_) {
    let assert Ok(_) = attention.ask(wiring, caller("main"), request(None))
      as "an ask below the bound is recorded"
  })
}

fn find_n(wiring: attention.Wiring, times: Int) -> Nil {
  list.repeat(Nil, times)
  |> list.each(fn(_) {
    let assert Ok(_) = attention.notice(wiring, caller("main"), notice())
      as "a find below the bound is recorded"
  })
}

fn settled_ask(id: String, at: Int) -> records.Ask {
  records.Ask(
    header: records.Header(
      id:,
      created_at: 1,
      routing: records.ToOwner,
      anchor: records.Anchor(
        operation: operation(),
        step_id: "s",
        source_index: 0,
      ),
      strand: "main",
      parents: [],
    ),
    why: None,
    questions: [
      records.Question(
        key: "q1",
        prompt: "Retry?",
        kind: records.Confirm,
        options: [],
      ),
    ],
    state: records.Answered(
      at:,
      answer: records.Answer(values: [#("q1", records.Yes)], by: "owner"),
    ),
  )
}

// --- what a call writes ----------------------------------------------------

pub fn an_ask_is_recorded_and_read_back_test() {
  let runtime = open(path())
  let seam = attention.seam(wiring(runtime))
  let assert Ok(id) = seam.ask(caller("main"), request(None))
  assert records.is_ask_id(id)

  let assert Ok([ask]) = attention.asks(runtime)
  assert ask.header.id == id
  assert ask.header.created_at == now
  assert ask.header.routing == records.ToOwner
  assert ask.header.strand == "main"
  assert ask.header.parents == []
  assert ask.header.anchor
    == records.Anchor(
      operation: operation(),
      step_id: "step-1",
      source_index: 3,
    )
  assert ask.why == Some("The build is red.")
  assert ask.state == records.AskOpen
  let assert Ok(Nil) = api.close(runtime)
}

pub fn a_find_is_recorded_and_read_back_test() {
  let runtime = open(path())
  let seam = attention.seam(wiring(runtime))
  let assert Ok(id) = seam.notice(caller("main"), notice())
  assert records.is_find_id(id)

  let assert Ok([find]) = attention.finds(runtime)
  assert find.header.id == id
  assert find.header.routing == records.ToOwner
  assert find.kind == records.Bug
  assert find.text == "No backoff."
  assert find.path == Some("src/retry.gleam")
  assert find.line == Some(41)
  assert find.state == records.FindOpen
  let assert Ok(Nil) = api.close(runtime)
}

pub fn a_record_carries_the_strands_parent_chain_nearest_first_test() {
  let runtime = open(path())
  let edge = fn(strand, parent) {
    lineage.Lineage(
      strand:,
      parent:,
      depth: 1,
      minted_by: lineage.CallSite(
        operation: operation(),
        step_id: "s",
        source_index: 0,
      ),
      brief: operation(),
      tools: [],
      default_within_ms: None,
      deadline: None,
      detached: False,
      reaped: False,
      orchestrator: None,
    )
  }
  let assert Ok(Nil) =
    api.put_reserved_fact(
      runtime,
      lineage.register_key("sub:main/a"),
      lineage.encode(edge("sub:main/a", "main")),
    )
  let assert Ok(Nil) =
    api.put_reserved_fact(
      runtime,
      lineage.register_key("sub:main/a/b"),
      lineage.encode(edge("sub:main/a/b", "sub:main/a")),
    )
  let assert Ok(_) =
    attention.notice(wiring(runtime), caller("sub:main/a/b"), notice())
  let assert Ok([find]) = attention.finds(runtime)
  assert find.header.strand == "sub:main/a/b"
  assert find.header.parents == ["sub:main/a", "main"]
  let assert Ok(Nil) = api.close(runtime)
}

pub fn an_ask_names_a_strand_of_the_session_or_is_refused_test() {
  let runtime = open(path())
  let wired = wiring(runtime)
  let assert Ok(_) =
    attention.ask(wired, caller("sub:main/a"), request(Some("main")))
  let assert Ok([ask]) = attention.asks(runtime)
  assert ask.header.routing == records.ToStrand("main")

  assert attention.ask(wired, caller("main"), request(Some("nobody")))
    == Error(tool_attention.NoSuchStrand("nobody"))
  let assert Ok(Nil) = api.close(runtime)
}

pub fn an_ask_to_the_asking_strand_itself_is_refused_test() {
  let runtime = open(path())
  let assert Error(tool_attention.Invalid(reason)) =
    attention.ask(wiring(runtime), caller("main"), request(Some("main")))
  assert string.contains(reason, "your own strand")
  let assert Ok(Nil) = api.close(runtime)
}

pub fn more_notices_than_the_old_retry_bound_all_land_test() {
  let runtime = open(path())
  let wired = wiring(runtime)
  let results = process.new_subject()
  list.each(list.repeat(Nil, 12), fn(_) {
    process.spawn(fn() {
      process.send(results, attention.notice(wired, caller("main"), notice()))
    })
  })
  let outcomes =
    list.map(list.repeat(Nil, 12), fn(_) {
      let assert Ok(outcome) = process.receive(results, 30_000)
        as "every racer answers"
      outcome
    })

  // Every contender has a slot below the bound, so none may fail on the race.
  assert list.all(outcomes, fn(outcome) { outcome |> result_is_ok })
  let assert Ok(finds) = attention.finds(runtime)
  assert list.length(finds) == 12
  let assert Ok(Nil) = api.close(runtime)
}

fn result_is_ok(result: Result(a, e)) -> Bool {
  case result {
    Ok(_) -> True
    Error(_) -> False
  }
}

pub fn a_session_that_is_not_up_refuses_in_band_test() {
  let down =
    attention.Wiring(
      runtime: fn() { Error(Nil) },
      clock: clock.fixed(at: now),
      entropy: fn() { 1 },
    )
  let assert Error(tool_attention.Unavailable(_)) =
    attention.ask(down, caller("main"), request(None))
  let assert Error(tool_attention.Unavailable(_)) =
    attention.notice(down, caller("main"), notice())
}

// --- the bounds ------------------------------------------------------------

pub fn the_thirty_third_open_ask_is_refused_in_band_test() {
  let runtime = open(path())
  let wired = wiring(runtime)
  ask_n(wired, 32)
  assert attention.ask(wired, caller("main"), request(None))
    == Error(tool_attention.Full("asks", 32))
  let assert Ok(asks) = attention.asks(runtime)
  assert list.length(asks) == 32
  let assert Ok(Nil) = api.close(runtime)
}

pub fn the_hundred_and_twenty_ninth_open_find_is_refused_in_band_test() {
  let runtime = open(path())
  let wired = wiring(runtime)
  find_n(wired, 128)
  assert attention.notice(wired, caller("main"), notice())
    == Error(tool_attention.Full("finds", 128))
  let assert Ok(Nil) = api.close(runtime)
}

pub fn the_two_bounds_are_counted_apart_test() {
  let runtime = open(path())
  let wired = wiring(runtime)
  ask_n(wired, 32)
  let assert Ok(_) = attention.notice(wired, caller("main"), notice())
  let assert Ok(Nil) = api.close(runtime)
}

pub fn a_settled_record_and_a_damaged_cell_are_not_counted_test() {
  let runtime = open(path())
  let wired = wiring(runtime)
  let settled = settled_ask("ask-0000000001", now)
  let assert Ok(Nil) =
    api.put_reserved_fact(
      runtime,
      records.ask_key(settled.header.id),
      records.encode_ask(settled),
    )
  let assert Ok(Nil) =
    api.put_reserved_fact(
      runtime,
      records.ask_key("ask-0000000002"),
      json.String("damaged"),
    )

  // Thirty-two open asks still fit beside one settled and one damaged cell.
  ask_n(wired, 32)
  assert attention.ask(wired, caller("main"), request(None))
    == Error(tool_attention.Full("asks", 32))

  // The settled one reads back and the damaged one is left out.
  let assert Ok(asks) = attention.asks(runtime)
  assert list.length(asks) == 33
  let assert Ok(Nil) = api.close(runtime)
}

pub fn two_callers_cannot_both_take_the_last_slot_test() {
  let runtime = open(path())
  let wired = wiring(runtime)
  ask_n(wired, 31)

  // Eight callers race for one slot. Each reads the same thirty-one, so only
  // the guard stands between them and thirty-nine open asks.
  let results = process.new_subject()
  list.each(list.repeat(Nil, 8), fn(_) {
    process.spawn(fn() {
      process.send(results, attention.ask(wired, caller("main"), request(None)))
    })
  })
  let outcomes =
    list.map(list.repeat(Nil, 8), fn(_) {
      let assert Ok(outcome) = process.receive(results, 30_000)
        as "every racer answers"
      outcome
    })
  let recorded =
    list.count(outcomes, fn(outcome) {
      outcome != Error(tool_attention.Full("asks", 32))
    })
  assert recorded == 1
  assert list.all(outcomes, fn(outcome) {
    case outcome {
      Ok(_) | Error(tool_attention.Full("asks", 32)) -> True
      Error(_) -> False
    }
  })
  let assert Ok(asks) = attention.asks(runtime)
  assert list.length(asks) == 32
  let assert Ok(Nil) = api.close(runtime)
}

pub fn two_notices_cannot_both_take_the_last_slot_test() {
  let runtime = open(path())
  let wired = wiring(runtime)
  find_n(wired, 127)
  let results = process.new_subject()
  list.each(list.repeat(Nil, 6), fn(_) {
    process.spawn(fn() {
      process.send(results, attention.notice(wired, caller("main"), notice()))
    })
  })
  let outcomes =
    list.map(list.repeat(Nil, 6), fn(_) {
      let assert Ok(outcome) = process.receive(results, 30_000)
        as "every racer answers"
      outcome
    })
  assert list.count(outcomes, fn(outcome) {
      outcome != Error(tool_attention.Full("finds", 128))
    })
    == 1
  let assert Ok(finds) = attention.finds(runtime)
  assert list.length(finds) == 128
  let assert Ok(Nil) = api.close(runtime)
}

// --- pruning ---------------------------------------------------------------

pub fn an_old_settled_ask_is_pruned_and_an_old_open_one_is_not_test() {
  let runtime = open(path())
  let wired = wiring(runtime)
  let old_settled = settled_ask("ask-0000000001", now - 8 * day)
  let fresh_settled = settled_ask("ask-0000000002", now - 1 * day)
  let old_open =
    records.Ask(..settled_ask("ask-0000000003", 0), state: records.AskOpen)
  list.each([old_settled, fresh_settled, old_open], fn(ask) {
    let assert Ok(Nil) =
      api.put_reserved_fact(
        runtime,
        records.ask_key(ask.header.id),
        records.encode_ask(ask),
      )
  })

  let assert Ok(_) = attention.ask(wired, caller("main"), request(None))
  let assert Ok(asks) = attention.asks(runtime)
  let ids = list.map(asks, fn(ask) { ask.header.id })
  assert !list.contains(ids, "ask-0000000001")
  assert list.contains(ids, "ask-0000000002")
  assert list.contains(ids, "ask-0000000003")
  let assert Ok(Nil) = api.close(runtime)
}

pub fn settled_asks_past_the_count_are_pruned_oldest_first_test() {
  let runtime = open(path())
  let wired = wiring(runtime)
  list.each(numbers(202), fn(n) {
    let ask = settled_ask("ask-" <> ten(n), now - n)
    let assert Ok(Nil) =
      api.put_reserved_fact(
        runtime,
        records.ask_key(ask.header.id),
        records.encode_ask(ask),
      )
  })
  let assert Ok(_) = attention.ask(wired, caller("main"), request(None))

  // The oldest two settled rows have the largest `n`, and 202 exceed 200 by
  // two.
  let assert Ok(asks) = attention.asks(runtime)
  let ids = list.map(asks, fn(ask) { ask.header.id })
  assert !list.contains(ids, "ask-" <> ten(202))
  assert !list.contains(ids, "ask-" <> ten(201))
  assert list.contains(ids, "ask-" <> ten(200))
  assert list.length(asks) == 201
  let assert Ok(Nil) = api.close(runtime)
}

fn ten(n: Int) -> String {
  string.pad_start(int.to_string(n), to: 10, with: "0")
}

fn numbers(count: Int) -> List(Int) {
  list.repeat(Nil, count) |> list.index_map(fn(_, index) { index + 1 })
}

// --- restart ---------------------------------------------------------------

pub fn a_record_survives_a_session_restart_test() {
  let scratch = path()
  let first = open(scratch)
  let seam = attention.seam(wiring(first))
  let assert Ok(ask_id) = seam.ask(caller("main"), request(None))
  let assert Ok(find_id) = seam.notice(caller("main"), notice())
  let assert Ok(Nil) = api.close(first)

  let second = open(scratch)
  let assert Ok([ask]) = attention.asks(second)
  let assert Ok([find]) = attention.finds(second)
  assert ask.header.id == ask_id
  assert find.header.id == find_id

  // The bound still counts what the earlier session wrote.
  ask_n(wiring(second), 31)
  assert attention.ask(wiring(second), caller("main"), request(None))
    == Error(tool_attention.Full("asks", 32))
  let assert Ok(Nil) = api.close(second)
}

// --- the model cannot forge a record ---------------------------------------

pub fn a_models_fact_write_cannot_forge_a_record_test() {
  let runtime = open(path())
  let assert Error(api.ReservedFactKey(..)) =
    api.put_fact(
      runtime,
      records.ask_key("ask-0000000001"),
      records.encode_ask(settled_ask("ask-0000000001", now)),
    )
  let assert Error(api.ReservedFactKey(..)) =
    api.put_fact(runtime, records.find_key("find-0000000001"), json.Null)
  let assert Ok(Nil) = api.close(runtime)
}
