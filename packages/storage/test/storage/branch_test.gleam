//// Unit tests for the pure branch-scan refinement pipeline.

import core/entry.{type Entry}
import gleam/list
import gleam/option.{None, Some}
import storage/internal/branch
import storage/storage.{OldestFirst}
import support/fixtures

// A five-entry path with a compaction in the middle and a custom entry,
// newest first, with the seqs storage would have stamped.
fn fixture_path() {
  let ctx = fixtures.new_ctx()
  let #(a, ctx) = fixtures.message_entry(ctx, None, "a")
  let #(b, ctx) = fixtures.message_entry(ctx, Some(a.id), "b")
  let #(c, ctx) = fixtures.compaction_entry(ctx, Some(b.id), "summary")
  let #(d, ctx) = fixtures.custom_entry(ctx, Some(c.id), "note")
  let #(e, _ctx) = fixtures.message_entry(ctx, Some(d.id), "e")
  let a = storage.stamp(a, seq: 1, ts: 10)
  let b = storage.stamp(b, seq: 2, ts: 10)
  let c = storage.stamp(c, seq: 4, ts: 11)
  let d = storage.stamp(d, seq: 7, ts: 12)
  let e = storage.stamp(e, seq: 9, ts: 13)
  #([e, d, c, b, a], e)
}

fn base_query() {
  let #(_, newest) = fixture_path()
  storage.branch_scan(from: newest.id)
}

pub fn no_filters_returns_whole_path_test() {
  let #(path, _) = fixture_path()
  assert branch.refine_all(base_query(), path) == path
}

pub fn stop_at_kind_is_inclusive_test() {
  let #(path, _) = fixture_path()
  let q = base_query() |> storage.branch_stop_at_kind(storage.Compaction)
  let assert [e, d, c] = branch.refine_all(q, path)
  assert storage.kind_of(c) == storage.Compaction
  assert e.seq == 9 && d.seq == 7
}

pub fn stop_entry_failing_filter_is_dropped_but_still_stops_test() {
  let #(path, _) = fixture_path()
  let q =
    base_query()
    |> storage.branch_stop_at_kind(storage.Compaction)
    |> storage.branch_kind(storage.Message)
  let assert [e] = branch.refine_all(q, path)
  assert e.seq == 9
}

pub fn stop_at_id_test() {
  let #(path, _) = fixture_path()
  let assert [_, _, c, _, _] = path
  let q = base_query() |> storage.branch_stop_at_id(c.id)
  let assert [_, _, stopped] = branch.refine_all(q, path)
  assert stopped.id == c.id
}

pub fn custom_type_filter_test() {
  let #(path, _) = fixture_path()
  let q = base_query() |> storage.branch_custom_type("note")
  let assert [d] = branch.refine_all(q, path)
  assert d.seq == 7
}

pub fn custom_type_mismatch_filters_all_test() {
  let #(path, _) = fixture_path()
  let q = base_query() |> storage.branch_custom_type("other")
  assert branch.refine_all(q, path) == []
}

pub fn cursor_newest_first_is_exclusive_test() {
  let #(path, _) = fixture_path()
  let q = base_query() |> storage.branch_cursor(7)
  let seqs = branch.refine_all(q, path) |> seqs_of
  assert seqs == [4, 2, 1]
}

pub fn cursor_oldest_first_is_exclusive_test() {
  let #(path, _) = fixture_path()
  let q =
    base_query()
    |> storage.branch_order(OldestFirst)
    |> storage.branch_cursor(4)
  let seqs = branch.refine_all(q, path |> reverse) |> seqs_of
  assert seqs == [7, 9]
}

pub fn limit_applies_last_test() {
  let #(path, _) = fixture_path()
  let q = base_query() |> storage.branch_cursor(9) |> storage.branch_limit(2)
  let seqs = branch.refine_all(q, path) |> seqs_of
  assert seqs == [7, 4]
}

pub fn zero_limit_is_empty_test() {
  let #(path, _) = fixture_path()
  let q = base_query() |> storage.branch_limit(0)
  assert branch.refine_all(q, path) == []
}

pub fn step_after_done_is_inert_test() {
  let #(path, _) = fixture_path()
  let assert [e, d, ..] = path
  let q = base_query() |> storage.branch_limit(1)
  let state = branch.new(q) |> branch.step(e)
  assert state.done
  let state = branch.step(state, d)
  let assert [only] = branch.results(state)
  assert only.seq == 9
}

pub fn stop_before_cursor_window_truncates_test() {
  // The stop applies before the cursor: a stop entry above the cursor
  // window still ends the scan, so nothing below it leaks through.
  let #(path, _) = fixture_path()
  let q =
    base_query()
    |> storage.branch_stop_at_kind(storage.Custom)
    |> storage.branch_cursor(5)
  let seqs = branch.refine_all(q, path) |> seqs_of
  assert seqs == []
}

fn seqs_of(entries: List(Entry)) -> List(Int) {
  list.map(entries, fn(entry) { entry.seq })
}

fn reverse(path: List(Entry)) -> List(Entry) {
  list.reverse(path)
}
