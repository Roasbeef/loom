//// Runs the shared storage conformance suite against both backends, plus
//// the SQLite-only checks: writer-lease fencing under dueling writers,
//// `EXPLAIN QUERY PLAN` assertions, branch-index metadata invariants,
//// and the 10k-entry perf smoke.

import conformance/storage_suite.{Backend}
import core/clock
import core/entry.{type Entry, CompactionEntry, MessageEntry}
import core/ids.{type EntryId}
import core/message.{UserMessage, UserText}
import core/tx.{Faulted, InsertEntry, Tx}
import gleam/dict
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import simplifile
import storage/memory
import storage/sqlite
import storage/storage
import support/internal/ffi_time

// --- backends under test -------------------------------------------------

fn fresh_path(name: String) -> String {
  let _ = simplifile.create_directory_all("build/conformance_db")
  let path = "build/conformance_db/" <> name <> ".db"
  let _ = simplifile.delete(path)
  let _ = simplifile.delete(path <> "-wal")
  let _ = simplifile.delete(path <> "-shm")
  path
}

fn open_sqlite(tag: String) {
  let assert Ok(store) =
    sqlite.open(
      sqlite.config(path: fresh_path("suite_" <> tag), owner: "suite-writer"),
      clock.stepping(from: 1_000_000, by: 3),
    )
  store
}

pub fn memory_suite_test() {
  storage_suite.run(
    Backend(name: "memory", open: fn(_tag) {
      let assert Ok(store) = memory.open(clock.stepping(from: 1_000_000, by: 3))
      store
    }),
  )
}

pub fn sqlite_suite_test() {
  storage_suite.run(Backend(name: "sqlite", open: open_sqlite))
}

// --- fixtures ------------------------------------------------------------

fn generator() {
  ids.generator(clock.stepping(from: 9000, by: 1), seed: 23)
}

fn message_entry(
  generator: ids.Generator,
  parent: Option(EntryId),
  text: String,
) -> #(Entry, ids.Generator) {
  let #(id, generator) = ids.mint_entry(generator)
  let entry =
    MessageEntry(
      id:,
      parent:,
      seq: 0,
      ts: 0,
      message: UserMessage(
        content: [UserText(text:, text_signature: None)],
        timestamp: 0,
      ),
      terminate: False,
    )
  #(entry, generator)
}

fn compaction_entry(
  generator: ids.Generator,
  parent: Option(EntryId),
  summary: String,
) -> #(Entry, ids.Generator) {
  let #(id, generator) = ids.mint_entry(generator)
  let entry =
    CompactionEntry(
      id:,
      parent:,
      seq: 0,
      ts: 0,
      summary:,
      retained_tail: [],
      tokens_before: 42,
      from_hook: False,
      usage: None,
    )
  #(entry, generator)
}

// --- writer lease: dueling writers ---------------------------------------

pub fn sqlite_lease_duel_test() {
  let path = fresh_path("lease_duel")
  // Writer A holds a 1-second lease minted at t=10_000.
  let assert Ok(store_a) =
    sqlite.open(
      sqlite.config(path:, owner: "writer-a") |> sqlite.lease_ttl(1000),
      clock.fixed(at: 10_000),
    )
  let #(a1, generator) = message_entry(generator(), None, "from a")
  let assert Ok(_) =
    storage.commit(store_a, Tx(writes: [InsertEntry(a1)], expected: []))

  // A second writer cannot open while the lease is live.
  let assert Error(sqlite.LeaseHeld(owner: "writer-a", ..)) =
    sqlite.open(
      sqlite.config(path:, owner: "writer-b") |> sqlite.lease_ttl(1000),
      clock.fixed(at: 10_500),
    )

  // Past expiry, writer B steals the lease with a bumped fence.
  let assert Ok(store_b) =
    sqlite.open(
      sqlite.config(path:, owner: "writer-b") |> sqlite.lease_ttl(1000),
      clock.fixed(at: 12_000),
    )
  let #(b1, generator) = message_entry(generator, Some(a1.id), "from b")
  let assert Ok(_) =
    storage.commit(store_b, Tx(writes: [InsertEntry(b1)], expected: []))

  // The fenced-out writer's commit is refused as Faulted and applies
  // nothing.
  let #(a2, generator) = message_entry(generator, Some(a1.id), "late a")
  let assert Error(Faulted(_)) =
    storage.commit(store_a, Tx(writes: [InsertEntry(a2)], expected: []))
  let assert Ok(found) = storage.get_entries(store_b, [a2.id])
  assert dict.size(found) == 0
  // The refusal consumed nothing — not even a seq: the live writer's next
  // commit continues directly after the last applied write (a1 = 1,
  // b1 = 2).
  let #(b2, _generator) = message_entry(generator, Some(b1.id), "b again")
  let assert Ok(result) =
    storage.commit(store_b, Tx(writes: [InsertEntry(b2)], expected: []))
  assert result.first_seq == 3

  // The fenced-out writer cannot renew the stolen lease either.
  let assert Error(storage.BackendFault(_)) = sqlite.renew_lease(store_a.handle)

  // The stale owner's close must not release the replacement's lease.
  let assert Ok(Nil) = storage.close(store_a)
  let assert Error(sqlite.LeaseHeld(owner: "writer-b", ..)) =
    sqlite.open(
      sqlite.config(path:, owner: "writer-c") |> sqlite.lease_ttl(1000),
      clock.fixed(at: 12_500),
    )
  // B keeps committing happily.
  let assert Ok(stats) = storage.stats(store_b)
  assert stats.message_count == 3
  let assert Ok(Nil) = storage.close(store_b)
}

pub fn sqlite_renew_lease_keeps_ownership_test() {
  let path = fresh_path("lease_renew")
  // A stepping clock: every renewal pushes expiry forward.
  let assert Ok(store) =
    sqlite.open(
      sqlite.config(path:, owner: "writer-a") |> sqlite.lease_ttl(1000),
      clock.stepping(from: 10_000, by: 400),
    )
  let assert Ok(Nil) = sqlite.renew_lease(store.handle)
  let assert Ok(Nil) = sqlite.renew_lease(store.handle)
  let assert Ok(Nil) = storage.close(store)
}

// --- query plans ---------------------------------------------------------

pub fn sqlite_branch_scan_plan_test() {
  let store = open_sqlite("plan")
  // Both page-query variants are part of the contract: the DESC plan
  // serves every NewestFirst scan and the ASC plan every OldestFirst
  // scan, and a regression in either would be a silent table scan.
  list.each([storage.NewestFirst, storage.OldestFirst], fn(order) {
    let assert Ok(lines) = sqlite.scan_branch_plan(store.handle, order)
    let plan = string.join(lines, with: "\n")
    // The scan must drive from branch_entries through the covering seq
    // index, probing entries by primary key ...
    assert string.contains(plan, "ix_be_seq")
    let assert [first_step, ..rest] = lines
    assert string.contains(
      first_step,
      "SEARCH b USING COVERING INDEX ix_be_seq",
    )
    assert list.any(rest, fn(line) {
      string.contains(line, "SEARCH e USING PRIMARY KEY")
    })
    // ... with no temporary sort and no scan of entries. Any of these in
    // the plan is a CI-failing regression (spec Part 1.2 rule 5).
    assert !string.contains(plan, "TEMP B-TREE")
    assert !string.contains(plan, "SCAN e")
  })
  let assert Ok(Nil) = storage.close(store)
}

// --- branch-index metadata invariants ------------------------------------

pub fn sqlite_branch_meta_invariants_test() {
  let store = open_sqlite("meta")
  // Build a branching shape around a compaction, so the index must both
  // full-copy (divergence with no compaction below) and base-link
  // (divergence above the compaction):
  //
  //   e1 - e2 - c3 - e4 - e5      (c3 is a compaction; seqs 1..5)
  //         └--- g3               (full-copy segment, base: none)
  //              └(e4)--- f5      (compaction-bounded, base at c3)
  let #(e1, generator) = message_entry(generator(), None, "e1")
  let #(e2, generator) = message_entry(generator, Some(e1.id), "e2")
  let #(c3, generator) = compaction_entry(generator, Some(e2.id), "checkpoint")
  let #(e4, generator) = message_entry(generator, Some(c3.id), "e4")
  let #(e5, generator) = message_entry(generator, Some(e4.id), "e5")
  let #(f5, generator) = message_entry(generator, Some(e4.id), "f5")
  let #(g3, _generator) = message_entry(generator, Some(e2.id), "g3")
  let assert Ok(main) =
    storage.commit(
      store,
      Tx(
        writes: [
          InsertEntry(e1),
          InsertEntry(e2),
          InsertEntry(c3),
          InsertEntry(e4),
          InsertEntry(e5),
        ],
        expected: [],
      ),
    )
  let assert [_, _, compaction_seq, ..] = main.seqs
  let assert Ok(_) =
    storage.commit(store, Tx(writes: [InsertEntry(f5)], expected: []))
  let assert Ok(_) =
    storage.commit(store, Tx(writes: [InsertEntry(g3)], expected: []))

  let assert Ok(segments) = sqlite.segments(store.handle)
  // One segment per divergence plus the root segment.
  assert list.length(segments) == 3
  // Tip uniqueness (ix_bm_tip): no two segments share a tip entry.
  let tips = list.map(segments, fn(segment) { segment.tip_entry_id })
  assert list.length(list.unique(tips)) == list.length(tips)
  // The live tips are exactly the three leaves.
  assert list.sort(tips, string.compare)
    == list.sort(
      [
        ids.entry_id_to_string(e5.id),
        ids.entry_id_to_string(f5.id),
        ids.entry_id_to_string(g3.id),
      ],
      string.compare,
    )
  // Every base link names a live segment and sits strictly below the
  // segment's own tip.
  let by_id =
    list.fold(over: segments, from: dict.new(), with: fn(by_id, segment) {
      dict.insert(by_id, segment.branch_id, segment)
    })
  list.each(segments, fn(segment) {
    case segment.base {
      Some(#(base_id, base_seq)) -> {
        assert dict.has_key(by_id, base_id)
        assert base_seq < segment.tip_seq
      }
      None -> Nil
    }
  })
  // And non-vacuously: the segment diverging above the compaction links
  // its base to the main segment exactly at the compaction's seq, while
  // the one diverging below it full-copies and carries no base.
  let assert Ok(main_segment) =
    list.find(segments, fn(segment) {
      segment.tip_entry_id == ids.entry_id_to_string(e5.id)
    })
  let assert Ok(f_segment) =
    list.find(segments, fn(segment) {
      segment.tip_entry_id == ids.entry_id_to_string(f5.id)
    })
  let assert Ok(g_segment) =
    list.find(segments, fn(segment) {
      segment.tip_entry_id == ids.entry_id_to_string(g3.id)
    })
  assert main_segment.base == None
  assert f_segment.base == Some(#(main_segment.branch_id, compaction_seq))
  assert g_segment.base == None
  let assert Ok(Nil) = storage.close(store)
}

// --- perf smoke ----------------------------------------------------------

const perf_entries = 10_000

const perf_batch = 100

pub fn sqlite_perf_smoke_test() {
  let store = open_sqlite("perf")
  // A 10k-entry single-strand session committed in batches.
  let build_started = ffi_time.now_us()
  let leaf = insert_chain(store, None, generator(), perf_entries)
  let build_us = ffi_time.now_us() - build_started
  let assert Some(leaf_id) = leaf

  // Scan a recent window (newest 50) twenty times; report the p50, since
  // this container gives no stable ms guarantees to hard-fail on. The
  // M0 target is p50 < 5 ms.
  let q = storage.branch_scan(from: leaf_id) |> storage.branch_limit(50)
  let timings =
    list.map(list.repeat(Nil, times: 20), fn(_) {
      let started = ffi_time.now_us()
      let assert Ok(entries) = storage.scan_branch(store, q)
      let elapsed = ffi_time.now_us() - started
      assert list.length(entries) == 50
      elapsed
    })
  let sorted = list.sort(timings, int.compare)
  let p50 = nth(sorted, 9)
  let worst = nth(sorted, 19)
  io.println(
    "perf smoke [sqlite]: 10k-entry insert took "
    <> int.to_string(build_us / 1000)
    <> " ms; scan_branch(limit 50) over 20 runs: p50 = "
    <> us_to_ms(p50)
    <> " ms, max = "
    <> us_to_ms(worst)
    <> " ms (M0 target: p50 < 5 ms)",
  )
  let assert Ok(Nil) = storage.close(store)
}

fn insert_chain(
  store,
  parent: Option(EntryId),
  generator: ids.Generator,
  remaining: Int,
) -> Option(EntryId) {
  case remaining <= 0 {
    True -> parent
    False -> {
      let batch_size = int.min(perf_batch, remaining)
      let #(writes, parent, generator) =
        list.fold(
          over: list.repeat(Nil, times: batch_size),
          from: #([], parent, generator),
          with: fn(step, _) {
            let #(writes, parent, generator) = step
            let #(entry, generator) = message_entry(generator, parent, "entry")
            #([InsertEntry(entry), ..writes], Some(entry.id), generator)
          },
        )
      let assert Ok(_) =
        storage.commit(store, Tx(writes: list.reverse(writes), expected: []))
      insert_chain(store, parent, generator, remaining - batch_size)
    }
  }
}

fn nth(sorted: List(Int), index: Int) -> Int {
  case list.drop(sorted, index) {
    [value, ..] -> value
    [] -> 0
  }
}

fn us_to_ms(us: Int) -> String {
  int.to_string(us / 1000) <> "." <> pad_fraction(us % 1000)
}

fn pad_fraction(us: Int) -> String {
  string.pad_start(int.to_string(us), to: 3, with: "0")
}
