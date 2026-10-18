//// The scratch store: what `kv.*` actually reads and writes.
////
//// Driven through the real actor and the real seam, because everything
//// worth proving here is *state over time* — an overwrite's accounting,
//// which entry eviction picks, and what a caller gets when the store is
//// not there — and none of those is visible in a single call.

import client/scratch
import codemode/workspace
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import qcheck
import statem
import statem_parallel
import support/addresses
import weft/registry as address

pub fn stopping_a_missing_store_is_a_no_op_test() {
  scratch.stop(addresses.new())
}

// --- bounds & least-recently-written eviction smoke --------------------------

pub fn least_recently_written_eviction_and_entry_bound_smoke_test() {
  let store =
    started(scratch.Bounds(
      max_entry_bytes: 8,
      max_total_bytes: 8,
      max_entries: 8,
    ))
  let assert Error(workspace.EntryTooLarge(bytes: 9, limit: 8)) =
    store.seam.set("oversize", <<"nine byte":utf8>>)
    as "a value over the entry bound is refused"
  assert store.seam.set("first", <<"aaaa":utf8>>) == Ok(Nil)
  assert store.seam.set("second", <<"bbbb":utf8>>) == Ok(Nil)
  // Reading `first` does not refresh its write position; re-setting does.
  assert store.seam.get("first") == Ok(Some(<<"aaaa":utf8>>))
  assert store.seam.set("third", <<"cccc":utf8>>) == Ok(Nil)
  assert store.seam.get("first") == Ok(None)
  assert store.seam.get("second") == Ok(Some(<<"bbbb":utf8>>))
  assert store.seam.get("third") == Ok(Some(<<"cccc":utf8>>))
  assert scratch.stat(store.name, timeout_ms: 1000) == #(2, 8)
  stop(store)
}

pub fn the_shipped_bounds_are_the_documented_numbers_test() {
  let bounds = scratch.default_bounds()
  assert bounds.max_entry_bytes == 262_144
  assert bounds.max_total_bytes == 8_388_608
  assert bounds.max_entries == 1024
  // The per-entry bound must be the smaller of the two, or the store
  // would admit a value it has to evict itself to make room for.
  assert bounds.max_entry_bytes <= bounds.max_total_bytes
}

// --- a store that is not there --------------------------------------------------

pub fn an_unstarted_store_refuses_in_band_test() {
  // Never a dead caller: this runs on the host's served-call process
  // inside a live execution, so an exit here is a capability call that
  // never settles. And never a silent success — a `set` answering `Ok`
  // into nothing looks to a program exactly like an eviction, and it
  // would loop re-setting a key that never lands.
  let name = addresses.new()
  let seam = scratch.seam(name, timeout_ms: 200)
  let assert Error(workspace.StoreUnavailable(reason:)) = seam.get("k")
    as "an absent store refuses a get in band"
  assert string.contains(reason, "no scratch store")
  let assert Error(workspace.StoreUnavailable(..)) = seam.set("k", <<"v":utf8>>)
    as "an absent store refuses a set in band"
  let assert Error(workspace.StoreUnavailable(..)) = seam.delete("k")
    as "an absent store refuses a delete in band"
}

pub fn the_none_seam_refuses_every_call_test() {
  let seam = scratch.none()
  let assert Error(workspace.StoreUnavailable(reason:)) = seam.get("k")
    as "the empty seam refuses a get"
  assert string.contains(reason, "runs no scratch store")
  let assert Error(workspace.StoreUnavailable(..)) = seam.set("k", <<"v":utf8>>)
    as "the empty seam refuses a set"
  let assert Error(workspace.StoreUnavailable(..)) = seam.delete("k")
    as "the empty seam refuses a delete"
}

pub fn a_stopped_store_refuses_rather_than_killing_the_caller_test() {
  let store = started(scratch.default_bounds())
  assert store.seam.set("k", <<"v":utf8>>) == Ok(Nil)
  stop(store)
  // The name is unregistered on the way out, so the next call finds
  // nothing rather than a dead pid — either way it is a refusal and not
  // an exit, which is what this asserts.
  let assert Error(workspace.StoreUnavailable(..)) = store.seam.get("k")
    as "a stopped store refuses in band"
}

// --- the rig --------------------------------------------------------------------

type Store {
  Store(name: address.Address(scratch.Message), seam: scratch.Scratch)
}

fn started(bounds: scratch.Bounds) -> Store {
  let name = addresses.new()
  let assert Ok(_started) = scratch.start(name, bounds)
    as "the scratch store must start"
  Store(name:, seam: scratch.seam(name, timeout_ms: 1000))
}

// --- incoherent bounds ------------------------------------------------------

pub fn a_nonsense_bounds_is_clamped_to_a_coherent_one_test() {
  // `Bounds` is a plain public record, so a host can spell one that
  // breaks the invariants the doc states. Clamped rather than trusted:
  // each field floored at 1, and the per-entry bound never looser than
  // the total.
  assert scratch.coherent(scratch.Bounds(
      max_entry_bytes: 9,
      max_total_bytes: 4,
      max_entries: 0,
    ))
    == scratch.Bounds(max_entry_bytes: 4, max_total_bytes: 4, max_entries: 1)
}

pub fn a_coherent_bounds_is_left_alone_test() {
  assert scratch.coherent(scratch.default_bounds()) == scratch.default_bounds()
}

pub fn a_store_started_on_nonsense_bounds_still_stores_test() {
  // The property the clamp buys, observed through the store rather than
  // through the clamp. A `max_entries` of 0 makes `evict` drop every
  // entry the instant it is written, so each `set` answers `Ok` and each
  // `get` answers `None` — which a program reads as unrelenting eviction,
  // and `cap/kv`'s contract says to tolerate eviction, so it loops
  // instead of failing.
  let store =
    started(scratch.Bounds(
      max_entry_bytes: 0,
      max_total_bytes: 0,
      max_entries: 0,
    ))
  let assert Ok(Nil) = store.seam.set("k", <<"v":utf8>>)
    as "a one-byte value fits the clamped bounds"
  assert store.seam.get("k") == Ok(Some(<<"v":utf8>>))
  stop(store)
}

fn stop(store: Store) -> Nil {
  scratch.stop(store.name)
  // The store's death and the next `process.named` lookup race, and this
  // suite asserts on the answer after a stop, so it waits for the name to
  // clear rather than for a fixed sleep to be long enough.
  wait_gone(store.name, 100)
}

fn wait_gone(name: address.Address(scratch.Message), polls: Int) -> Nil {
  case addresses.owner(name), polls <= 0 {
    Error(Nil), _ -> Nil
    Ok(_pid), True -> Nil
    Ok(_pid), False -> {
      process.sleep(5)
      wait_gone(name, polls - 1)
    }
  }
}

// --- stateful model & parallel linearizability specs -------------------------

const model_bounds =
  scratch.Bounds(max_entry_bytes: 8, max_total_bytes: 16, max_entries: 3)

type ModelEntry {
  ModelEntry(key: String, value: BitArray, bytes: Int)
}

type ScratchModel {
  ScratchModel(entries: List(ModelEntry), total_bytes: Int, count: Int)
}

type ScratchCmd {
  CmdGet(key: String)
  CmdSet(key: String, value: BitArray)
  CmdDelete(key: String)
  CmdStat
}

type ScratchReply {
  ReplyGet(Result(option.Option(BitArray), workspace.KvRefusal))
  ReplySet(Result(Nil, workspace.KvRefusal))
  ReplyDelete(Result(Nil, workspace.KvRefusal))
  ReplyStat(#(Int, Int))
}

fn initial_model() -> ScratchModel {
  ScratchModel(entries: [], total_bytes: 0, count: 0)
}

fn key_gen() -> qcheck.Generator(String) {
  qcheck.bounded_int(from: 0, to: 4)
  |> qcheck.map(fn(i) { "k" <> int.to_string(i) })
}

fn value_gen() -> qcheck.Generator(BitArray) {
  qcheck.bounded_int(from: 0, to: 10)
  |> qcheck.map(fn(len) { bit_array.from_string(string.repeat("x", len)) })
}

fn cmd_gen(_model: ScratchModel) -> qcheck.Generator(ScratchCmd) {
  qcheck.from_weighted_generators(
    #(40, qcheck.map2(key_gen(), value_gen(), CmdSet)),
    [
      #(30, qcheck.map(key_gen(), CmdGet)),
      #(20, qcheck.map(key_gen(), CmdDelete)),
      #(10, qcheck.constant(CmdStat)),
    ],
  )
}

fn model_remove(model: ScratchModel, key: String) -> ScratchModel {
  case list.find(model.entries, fn(e) { e.key == key }) {
    Error(Nil) -> model
    Ok(found) ->
      ScratchModel(
        entries: list.filter(model.entries, fn(e) { e.key != key }),
        total_bytes: model.total_bytes - found.bytes,
        count: model.count - 1,
      )
  }
}

fn model_evict(model: ScratchModel) -> ScratchModel {
  case
    model.total_bytes > model_bounds.max_total_bytes
    || model.count > model_bounds.max_entries
  {
    False -> model
    True ->
      case list.reverse(model.entries) {
        [] -> model
        [oldest, ..newer] ->
          model_evict(ScratchModel(
            entries: list.reverse(newer),
            total_bytes: model.total_bytes - oldest.bytes,
            count: model.count - 1,
          ))
      }
  }
}

fn model_step(
  model: ScratchModel,
  cmd: ScratchCmd,
) -> #(ScratchModel, ScratchReply) {
  case cmd {
    CmdGet(key:) -> {
      let found =
        list.find(model.entries, fn(e) { e.key == key })
        |> option.from_result
        |> option.map(fn(e) { e.value })
      #(model, ReplyGet(Ok(found)))
    }
    CmdSet(key:, value:) -> {
      let bytes = bit_array.byte_size(value)
      case bytes > model_bounds.max_entry_bytes {
        True -> #(
          model,
          ReplySet(
            Error(workspace.EntryTooLarge(
              bytes:,
              limit: model_bounds.max_entry_bytes,
            )),
          ),
        )
        False -> {
          let cleared = model_remove(model, key)
          let admitted =
            ScratchModel(
              entries: [ModelEntry(key:, value:, bytes:), ..cleared.entries],
              total_bytes: cleared.total_bytes + bytes,
              count: cleared.count + 1,
            )
          #(model_evict(admitted), ReplySet(Ok(Nil)))
        }
      }
    }
    CmdDelete(key:) -> #(model_remove(model, key), ReplyDelete(Ok(Nil)))
    CmdStat -> #(model, ReplyStat(#(model.count, model.total_bytes)))
  }
}

fn run_cmd(store: Store, cmd: ScratchCmd) -> ScratchReply {
  case cmd {
    CmdGet(key:) -> ReplyGet(store.seam.get(key))
    CmdSet(key:, value:) -> ReplySet(store.seam.set(key, value))
    CmdDelete(key:) -> ReplyDelete(store.seam.delete(key))
    CmdStat -> ReplyStat(scratch.stat(store.name, timeout_ms: 1000))
  }
}

fn scratch_statem_spec() -> statem.Spec(ScratchModel, ScratchCmd, Store) {
  statem.Spec(
    initial: initial_model(),
    command: cmd_gen,
    precondition: fn(_, _) { statem.Admit },
    next_model: fn(model, cmd) { model_step(model, cmd).0 },
    new_sut: fn() { started(model_bounds) },
    execute: fn(store, model, cmd) {
      let expected = model_step(model, cmd).1
      let actual = run_cmd(store, cmd)
      case actual == expected {
        True -> Ok(store)
        False ->
          Error(statem.Violation(
            tag: "scratch_postcondition",
            detail: string.inspect(#(cmd, expected, actual)),
          ))
      }
    },
    finish: fn(store, model) {
      let actual = scratch.stat(store.name, timeout_ms: 1000)
      case actual == #(model.count, model.total_bytes) {
        True -> Ok(Nil)
        False ->
          Error(statem.Violation(
            tag: "scratch_finish_stat",
            detail: string.inspect(#(model, actual)),
          ))
      }
    },
    teardown: stop,
  )
}

pub fn scratch_matches_reference_model_under_statem_test() {
  let config =
    statem.default_config(seed: 20_261_018)
    |> statem.with_test_count(100)
    |> statem.with_min_commands(10)
    |> statem.with_max_commands(40)
  case statem.check(scratch_statem_spec(), config) {
    Ok(Nil) -> Nil
    Error(failure) -> panic as statem.report(failure, string.inspect)
  }
}

pub fn scratch_is_linearizable_under_concurrent_callers_test() {
  let spec =
    statem_parallel.Spec(
      initial: initial_model(),
      command: cmd_gen,
      precondition: fn(_, _) { statem.Admit },
      next_model: fn(model, cmd) { model_step(model, cmd).0 },
      new_sut: fn() { started(model_bounds) },
      run: run_cmd,
      postcondition: fn(model, cmd, actual) {
        let expected = model_step(model, cmd).1
        case actual == expected {
          True -> Ok(Nil)
          False ->
            Error(statem.Violation(
              tag: "scratch_parallel_postcondition",
              detail: string.inspect(#(cmd, expected, actual)),
            ))
        }
      },
      finish: fn(store) {
        let #(count, bytes) = scratch.stat(store.name, timeout_ms: 1000)
        case
          count <= model_bounds.max_entries
          && bytes <= model_bounds.max_total_bytes
        {
          True -> Ok(Nil)
          False ->
            Error(statem.Violation(
              tag: "scratch_parallel_bounds",
              detail: string.inspect(#(count, bytes)),
            ))
        }
      },
      teardown: stop,
    )
  let config =
    statem_parallel.default_config(seed: 20_261_019)
    |> statem_parallel.with_test_count(40)
    |> statem_parallel.with_repeat(2)
  case statem_parallel.check(spec, config) {
    Ok(Nil) -> Nil
    Error(failure) -> panic as statem_parallel.report(failure, string.inspect)
  }
}
