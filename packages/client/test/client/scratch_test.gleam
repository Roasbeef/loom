//// The scratch store: what `kv.*` actually reads and writes.
////
//// Driven through the real actor and the real seam, because everything
//// worth proving here is *state over time* — an overwrite's accounting,
//// which entry eviction picks, and what a caller gets when the store is
//// not there — and none of those is visible in a single call.

import client/scratch
import codemode/workspace
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import support/addresses
import weft/registry as address

pub fn stopping_a_missing_store_is_a_no_op_test() {
  scratch.stop(addresses.new())
}

// --- a round trip -------------------------------------------------------------

pub fn a_set_then_get_returns_the_bytes_test() {
  let store = started(scratch.default_bounds())
  assert store.seam.set("k", <<"value":utf8>>) == Ok(Nil)
  assert store.seam.get("k") == Ok(Some(<<"value":utf8>>))
  stop(store)
}

pub fn an_absent_key_is_none_and_not_an_error_test() {
  // `cap/kv.get` answers `Ok(None)` for an absent key and every caller
  // must handle it, so an absent key must never come back as a refusal —
  // a program that read one as an error would treat a cold cache as a
  // broken host.
  let store = started(scratch.default_bounds())
  assert store.seam.get("never-written") == Ok(None)
  stop(store)
}

pub fn a_set_replaces_the_prior_value_and_its_bytes_test() {
  // Two properties in one: the value a program reads back, and the
  // *accounting* underneath it. An overwrite that added the new bytes
  // without subtracting the old would evict under a pressure that is not
  // there, and nothing a program can see would say why.
  let store = started(scratch.default_bounds())
  assert store.seam.set("k", <<"0123456789":utf8>>) == Ok(Nil)
  assert store.seam.set("k", <<"ab":utf8>>) == Ok(Nil)
  assert store.seam.get("k") == Ok(Some(<<"ab":utf8>>))
  assert scratch.stat(store.name, timeout_ms: 1000) == #(1, 2)
  stop(store)
}

pub fn a_delete_removes_the_key_and_is_idempotent_test() {
  let store = started(scratch.default_bounds())
  assert store.seam.set("k", <<"value":utf8>>) == Ok(Nil)
  assert store.seam.delete("k") == Ok(Nil)
  assert store.seam.get("k") == Ok(None)
  // Deleting an absent key succeeds: `cap/kv.delete` says so, and a
  // program tidying up after a partial run must not have to know whether
  // it got as far as writing.
  assert store.seam.delete("k") == Ok(Nil)
  assert store.seam.delete("never-written") == Ok(Nil)
  assert scratch.stat(store.name, timeout_ms: 1000) == #(0, 0)
  stop(store)
}

// --- the bounds ---------------------------------------------------------------

pub fn a_value_over_the_entry_bound_is_refused_test() {
  // Refused, not evicted: a single value too large for the cache is a
  // program's mistake about what a cache is for, and silently dropping it
  // would have it read back `None` forever.
  let store =
    started(scratch.Bounds(
      max_entry_bytes: 8,
      max_total_bytes: 64,
      max_entries: 8,
    ))
  let assert Error(workspace.EntryTooLarge(bytes:, limit:)) =
    store.seam.set("k", <<"nine byte":utf8>>)
    as "a value over the entry bound is refused"
  assert bytes == 9
  assert limit == 8
  // And nothing was stored: a refused write must not half-land.
  assert store.seam.get("k") == Ok(None)
  assert scratch.stat(store.name, timeout_ms: 1000) == #(0, 0)
  stop(store)
}

pub fn a_value_at_the_entry_bound_is_admitted_test() {
  let store =
    started(scratch.Bounds(
      max_entry_bytes: 8,
      max_total_bytes: 64,
      max_entries: 8,
    ))
  assert store.seam.set("k", <<"12345678":utf8>>) == Ok(Nil)
  assert store.seam.get("k") == Ok(Some(<<"12345678":utf8>>))
  stop(store)
}

pub fn byte_pressure_evicts_the_oldest_written_test() {
  // The eviction rule, pinned by its consequence rather than by reading
  // the state: three entries fill a store that holds two, and it is the
  // *first written* that is gone. An LRU would have kept it, because it
  // was read most recently — which is exactly the distinction this
  // asserts.
  let store =
    started(scratch.Bounds(
      max_entry_bytes: 8,
      max_total_bytes: 8,
      max_entries: 8,
    ))
  assert store.seam.set("first", <<"aaaa":utf8>>) == Ok(Nil)
  assert store.seam.set("second", <<"bbbb":utf8>>) == Ok(Nil)
  // Reading the oldest does not save it: this is least-recently-written.
  assert store.seam.get("first") == Ok(Some(<<"aaaa":utf8>>))
  assert store.seam.set("third", <<"cccc":utf8>>) == Ok(Nil)
  assert store.seam.get("first") == Ok(None)
  assert store.seam.get("second") == Ok(Some(<<"bbbb":utf8>>))
  assert store.seam.get("third") == Ok(Some(<<"cccc":utf8>>))
  // The bound holds after the eviction, which is the thing eviction is
  // for: two four-byte entries, exactly at the total.
  assert scratch.stat(store.name, timeout_ms: 1000) == #(2, 8)
  stop(store)
}

pub fn a_rewrite_moves_an_entry_to_the_back_of_the_queue_test() {
  // A program that wants a value kept re-sets it, which the module doc
  // promises. So an overwrite must refresh the write order, or the
  // promise is empty.
  let store =
    started(scratch.Bounds(
      max_entry_bytes: 8,
      max_total_bytes: 8,
      max_entries: 8,
    ))
  assert store.seam.set("first", <<"aaaa":utf8>>) == Ok(Nil)
  assert store.seam.set("second", <<"bbbb":utf8>>) == Ok(Nil)
  assert store.seam.set("first", <<"AAAA":utf8>>) == Ok(Nil)
  assert store.seam.set("third", <<"cccc":utf8>>) == Ok(Nil)
  // `second` is now the oldest written and is the one that went.
  assert store.seam.get("second") == Ok(None)
  assert store.seam.get("first") == Ok(Some(<<"AAAA":utf8>>))
  assert store.seam.get("third") == Ok(Some(<<"cccc":utf8>>))
  stop(store)
}

pub fn count_pressure_evicts_even_when_the_bytes_fit_test() {
  // The count bound is not redundant with the byte bound: eight megabytes
  // of one-byte values is eight million entries, and every operation
  // walks the list. Two tiny entries in a store that holds one is the
  // same shape at a size a test can hold.
  let store =
    started(scratch.Bounds(
      max_entry_bytes: 64,
      max_total_bytes: 64,
      max_entries: 1,
    ))
  assert store.seam.set("first", <<"a":utf8>>) == Ok(Nil)
  assert store.seam.set("second", <<"b":utf8>>) == Ok(Nil)
  assert store.seam.get("first") == Ok(None)
  assert store.seam.get("second") == Ok(Some(<<"b":utf8>>))
  assert scratch.stat(store.name, timeout_ms: 1000) == #(1, 1)
  stop(store)
}

pub fn the_store_stays_inside_its_bounds_under_a_write_loop_test() {
  // The property the two bounds exist for, driven rather than reasoned
  // about: a program looping on `set` with distinct keys — the shape that
  // grows a cache without bound — never gets the store past either
  // number.
  let bounds =
    scratch.Bounds(max_entry_bytes: 16, max_total_bytes: 64, max_entries: 8)
  let store = started(bounds)
  list.each(counting(200), fn(nth) {
    assert store.seam.set("k" <> int.to_string(nth), <<"12345678":utf8>>)
      == Ok(Nil)
    let #(count, bytes) = scratch.stat(store.name, timeout_ms: 1000)
    assert count <= bounds.max_entries
    assert bytes <= bounds.max_total_bytes
  })
  // And the most recent write survived, which is what makes the store
  // worth having at all.
  assert store.seam.get("k200") == Ok(Some(<<"12345678":utf8>>))
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

// `[1, …, count]`. `int.range` counts towards `to` without reaching it,
// so counting down and prepending yields the ascending list.
fn counting(count: Int) -> List(Int) {
  int.range(from: count, to: 0, with: [], run: list.prepend)
}
