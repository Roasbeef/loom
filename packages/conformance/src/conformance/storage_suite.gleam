//// The shared storage conformance suite (WP-T).
////
//// One suite, parameterized over a backend constructor, exercising the
//// full Part 1.2 contract: all-or-none atomicity, strictly increasing
//// seqs with legal gaps, write order within a transaction, the shared
//// entry/usage id namespace, register set/replace/delete semantics, the
//// CAS expectation matrix, placement-pattern reads, branch scans
//// (ordering, stops, filters, cursor paging), the branch-index
//// invariants of pi §2.6 (every tip's scan reproduces the exact ancestor
//// chain, stale branches stay valid), session-wide entry and usage
//// scans — including the non-positive-limit rule, where a limit of zero
//// or below returns no rows in every backend — stats-equals-ledger-sum
//// after every commit, and close semantics. A backend passes WP-B's exit
//// criteria only when `run` is green.
////
//// This module is test infrastructure: like a gleeunit test module its
//// failure mechanism is the `assert` keyword, which is why asserts
//// appear here despite living under `src` — the suite must be
//// importable by backend packages' own test mains as well as this
//// package's.

import core/clock
import core/entry.{
  type Entry, type UsageRow, CompactionEntry, CustomEntry, MessageEntry,
  UsageRow,
}
import core/ids.{type EntryId}
import core/json
import core/message.{Usage, UsageCost, UserMessage, UserText}
import core/register
import core/tx.{
  type Tx, Corruption, DeleteRegister, Expect, Faulted, InsertEntry, InsertUsage,
  SetRegister, StaleExpectation, Tx,
}
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import storage/storage.{
  type SessionStats, type Storage, HandleClosed, SessionStats, UnknownEntry,
}

/// A backend under test: a display name and a constructor that opens a
/// fresh, empty session. The `tag` argument distinguishes the sessions a
/// single run opens (file-backed backends derive a distinct path per
/// tag).
pub type Backend(handle) {
  Backend(name: String, open: fn(String) -> Storage(handle))
}

/// Runs the complete suite against one backend. Panics (via `assert`) on
/// the first violated contract clause.
///
/// ## Examples
///
/// ```gleam
/// storage_suite.run(Backend(name: "memory", open: open_memory))
/// ```
///
pub fn run(backend: Backend(handle)) -> Nil {
  atomicity_checks(backend)
  seq_checks(backend)
  write_order_checks(backend)
  duplicate_id_checks(backend)
  register_checks(backend)
  cas_checks(backend)
  placement_checks(backend)
  branch_scan_checks(backend)
  branch_index_checks(backend)
  entry_scan_checks(backend)
  usage_scan_checks(backend)
  close_checks(backend)
  Nil
}

// --- fixtures ------------------------------------------------------------

type Ctx {
  Ctx(generator: ids.Generator)
}

fn new_ctx() -> Ctx {
  Ctx(generator: ids.generator(clock.stepping(from: 5000, by: 1), seed: 11))
}

fn mint(ctx: Ctx) -> #(EntryId, Ctx) {
  let #(id, generator) = ids.mint_entry(ctx.generator)
  #(id, Ctx(generator:))
}

fn message(ctx: Ctx, parent: Option(EntryId), text: String) -> #(Entry, Ctx) {
  let #(id, ctx) = mint(ctx)
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
  #(entry, ctx)
}

fn compaction(
  ctx: Ctx,
  parent: Option(EntryId),
  summary: String,
) -> #(Entry, Ctx) {
  let #(id, ctx) = mint(ctx)
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
  #(entry, ctx)
}

fn custom(
  ctx: Ctx,
  parent: Option(EntryId),
  custom_type: String,
) -> #(Entry, Ctx) {
  let #(id, ctx) = mint(ctx)
  #(CustomEntry(id:, parent:, seq: 0, ts: 0, custom_type:, data: None), ctx)
}

fn usage_of(input: Int) -> message.Usage {
  Usage(
    input:,
    output: 2,
    cache_read: 0,
    cache_write: 0,
    cache_write_1h: None,
    reasoning: None,
    total_tokens: input + 2,
    cost: UsageCost(
      input: 0.001,
      output: 0.001,
      cache_read: 0.0,
      cache_write: 0.0,
      total: 0.002,
    ),
  )
}

fn usage(ctx: Ctx, entry_id: Option(EntryId), input: Int) -> #(UsageRow, Ctx) {
  let #(id, generator) = ids.mint_usage(ctx.generator)
  let row =
    UsageRow(
      id:,
      seq: 0,
      entry_id:,
      adjustment: False,
      usage: usage_of(input),
      details: Some(json.Object([#("kind", json.String("fixture"))])),
    )
  #(row, Ctx(generator:))
}

fn json_value(n: Int) -> register.RegisterValue {
  register.value(json.Int(n))
}

// --- the stats-checked commit helper -------------------------------------
//
// Every successful commit in the suite goes through here, which asserts
// the maintained stats projection equals the suite's independently
// computed ledger sum and message count — "after every commit", exactly
// as the spec demands.

fn commit_ok(
  store: Storage(handle),
  model: SessionStats,
  tx: Tx,
) -> #(SessionStats, tx.CommitResult) {
  let assert Ok(result) = storage.commit(store, tx)
  let model =
    list.fold(over: tx.writes, from: model, with: fn(model, write) {
      case write {
        InsertEntry(entry: MessageEntry(..)) ->
          SessionStats(..model, message_count: model.message_count + 1)
        InsertEntry(_) -> model
        InsertUsage(row:) ->
          SessionStats(
            ..model,
            usage: storage.add_usage(model.usage, row.usage),
          )
        SetRegister(..) | DeleteRegister(..) -> model
      }
    })
  let assert Ok(actual) = storage.stats(store)
  assert actual == model
  #(model, result)
}

fn ids_of(entries: List(Entry)) -> List(EntryId) {
  list.map(entries, fn(entry) { entry.id })
}

fn scan_ids(store: Storage(handle), q: storage.BranchScan) -> List(EntryId) {
  let assert Ok(entries) = storage.scan_branch(store, q)
  ids_of(entries)
}

// --- checks --------------------------------------------------------------

fn atomicity_checks(backend: Backend(handle)) -> Nil {
  let store = backend.open("atomicity")
  let ctx = new_ctx()
  let #(a, ctx) = message(ctx, None, "a")
  let #(b, ctx) = message(ctx, Some(a.id), "b")

  // A failing write mid-transaction applies nothing: the leading register
  // set, the leading valid entry, and the duplicate all vanish.
  let failing =
    Tx(
      writes: [
        SetRegister(register.StrandLeaf, "main", register.leaf_value(None)),
        InsertEntry(a),
        InsertEntry(a),
      ],
      expected: [],
    )
  let assert Error(Corruption(_)) = storage.commit(store, failing)
  let assert Ok(None) = storage.get_register(store, register.StrandLeaf, "main")
  let assert Ok(found) = storage.get_entries(store, [a.id])
  assert dict.size(found) == 0
  let assert Ok(stats) = storage.stats(store)
  assert stats == storage.empty_stats()

  // A missing parent poisons the whole transaction the same way.
  let #(stranger, _ctx) = mint(ctx)
  let orphaned =
    Tx(
      writes: [
        InsertEntry(a),
        InsertEntry(MessageEntry(
          id: b.id,
          parent: Some(stranger),
          seq: 0,
          ts: 0,
          message: UserMessage(
            content: [UserText(text: "b", text_signature: None)],
            timestamp: 0,
          ),
          terminate: False,
        )),
      ],
      expected: [],
    )
  let assert Error(Corruption(_)) = storage.commit(store, orphaned)
  let assert Ok(found) = storage.get_entries(store, [a.id])
  assert dict.size(found) == 0

  // After the failures, a clean commit starts at seq 1: the failed
  // transactions left no trace here, not even consumed seqs.
  let #(_, result) =
    commit_ok(
      store,
      storage.empty_stats(),
      Tx(writes: [InsertEntry(a)], expected: []),
    )
  assert result.first_seq == 1
  let assert Ok(found) = storage.get_entries(store, [a.id])
  assert dict.size(found) == 1
  let assert Ok(Nil) = storage.close(store)
  Nil
}

fn seq_checks(backend: Backend(handle)) -> Nil {
  let store = backend.open("seqs")
  let ctx = new_ctx()
  let #(a, ctx) = message(ctx, None, "a")
  let #(b, ctx) = message(ctx, Some(a.id), "b")
  let #(c, _ctx) = message(ctx, Some(b.id), "c")

  // Interleave register writes so entry seqs are non-consecutive: gaps
  // are legal within and between transactions.
  let model = storage.empty_stats()
  let #(model, first) =
    commit_ok(
      store,
      model,
      Tx(
        writes: [
          InsertEntry(a),
          SetRegister(register.OpState, "op", json_value(1)),
          InsertEntry(b),
        ],
        expected: [],
      ),
    )
  // Strictly increasing in write order, starting at first_seq; gaps are
  // legal, so only monotonicity is contractual.
  let assert [fs1, fs2, fs3] = first.seqs
  assert fs1 == first.first_seq && fs1 < fs2 && fs2 < fs3
  let #(_, second) =
    commit_ok(
      store,
      model,
      Tx(
        writes: [
          SetRegister(register.OpState, "op", json_value(2)),
          InsertEntry(c),
        ],
        expected: [],
      ),
    )
  // Strictly increasing across commits.
  let assert [s1, s2] = second.seqs
  let assert Ok(first_last) = list.last(first.seqs)
  assert s1 > first_last
  assert s2 > s1

  // The stored entries carry the assigned seqs, with gaps where the
  // interleaved register writes consumed seqs.
  let assert Ok(found) = storage.get_entries(store, [a.id, b.id, c.id])
  let assert Ok(stored_a) = dict.get(found, a.id)
  let assert Ok(stored_b) = dict.get(found, b.id)
  let assert Ok(stored_c) = dict.get(found, c.id)
  assert stored_a.seq < stored_b.seq
  assert stored_b.seq < stored_c.seq
  assert stored_b.seq - stored_a.seq >= 2
  assert stored_c.seq - stored_b.seq >= 2

  // An empty transaction is legal, applies nothing, and assigns nothing.
  let assert Ok(empty) = storage.commit(store, Tx(writes: [], expected: []))
  assert empty.seqs == []
  let assert Ok(Nil) = storage.close(store)
  Nil
}

fn write_order_checks(backend: Backend(handle)) -> Nil {
  let store = backend.open("write_order")
  let ctx = new_ctx()
  let #(a, ctx) = message(ctx, None, "a")
  // An entry may name a parent created earlier in the same transaction.
  let #(b, _ctx) = message(ctx, Some(a.id), "b")
  let model = storage.empty_stats()
  let #(model, _) =
    commit_ok(
      store,
      model,
      Tx(
        writes: [
          InsertEntry(a),
          InsertEntry(b),
          // Set then delete: the delete wins.
          SetRegister(register.OpState, "gone", json_value(1)),
          DeleteRegister(register.OpState, "gone"),
          // Delete then set: the set wins and creates the cell fresh.
          DeleteRegister(register.OpState, "kept"),
          SetRegister(register.OpState, "kept", json_value(2)),
          // Two sets: the later one wins and stamps the later seq.
          SetRegister(register.OpState, "twice", json_value(3)),
          SetRegister(register.OpState, "twice", json_value(4)),
        ],
        expected: [],
      ),
    )
  let assert Ok(found) = storage.get_entries(store, [b.id])
  let assert Ok(stored_b) = dict.get(found, b.id)
  assert stored_b.parent == Some(a.id)
  let assert Ok(None) = storage.get_register(store, register.OpState, "gone")
  let assert Ok(Some(kept)) =
    storage.get_register(store, register.OpState, "kept")
  assert kept.value == json_value(2)
  let assert Ok(Some(twice)) =
    storage.get_register(store, register.OpState, "twice")
  assert twice.value == json_value(4)
  // The surviving "twice" cell was stamped by the later of its two sets.
  assert twice.seq > kept.seq
  let _ = model
  let assert Ok(Nil) = storage.close(store)
  Nil
}

fn duplicate_id_checks(backend: Backend(handle)) -> Nil {
  let store = backend.open("duplicate_ids")
  let ctx = new_ctx()
  let #(a, ctx) = message(ctx, None, "a")
  let #(row, ctx) = usage(ctx, Some(a.id), 10)
  let model = storage.empty_stats()
  let #(_, _) =
    commit_ok(
      store,
      model,
      Tx(writes: [InsertEntry(a), InsertUsage(row)], expected: []),
    )

  // Entry under an existing entry id: corruption, not an update.
  let assert Error(Corruption(_)) =
    storage.commit(store, Tx(writes: [InsertEntry(a)], expected: []))
  // Usage under an existing usage id.
  let assert Error(Corruption(_)) =
    storage.commit(store, Tx(writes: [InsertUsage(row)], expected: []))
  // The id namespace is shared: a usage row under an entry id is
  // corruption too.
  let #(cross, _ctx) = usage(ctx, None, 5)
  let assert Ok(entry_id_as_usage) =
    ids.parse_usage_id(ids.entry_id_to_string(a.id))
  let assert Error(Corruption(_)) =
    storage.commit(
      store,
      Tx(
        writes: [InsertUsage(UsageRow(..cross, id: entry_id_as_usage))],
        expected: [],
      ),
    )
  let assert Ok(Nil) = storage.close(store)
  Nil
}

fn register_checks(backend: Backend(handle)) -> Nil {
  let store = backend.open("registers")
  let model = storage.empty_stats()
  // Set, replace, delete, delete-absent, recreate.
  let #(model, first) =
    commit_ok(
      store,
      model,
      Tx(
        writes: [SetRegister(register.StrandConfig, "main", json_value(1))],
        expected: [],
      ),
    )
  let assert Ok(Some(cell)) =
    storage.get_register(store, register.StrandConfig, "main")
  assert cell.value == json_value(1) && cell.seq == first.first_seq

  let #(model, second) =
    commit_ok(
      store,
      model,
      Tx(
        writes: [SetRegister(register.StrandConfig, "main", json_value(2))],
        expected: [],
      ),
    )
  let assert Ok(Some(cell)) =
    storage.get_register(store, register.StrandConfig, "main")
  assert cell.value == json_value(2) && cell.seq == second.first_seq

  let #(model, _) =
    commit_ok(
      store,
      model,
      Tx(writes: [DeleteRegister(register.StrandConfig, "main")], expected: []),
    )
  let assert Ok(None) =
    storage.get_register(store, register.StrandConfig, "main")

  // Deleting an absent cell is a no-op, and the commit still succeeds.
  let #(model, _) =
    commit_ok(
      store,
      model,
      Tx(writes: [DeleteRegister(register.StrandConfig, "main")], expected: []),
    )

  // Recreation after deletion is a fresh cell.
  let #(model, third) =
    commit_ok(
      store,
      model,
      Tx(
        writes: [SetRegister(register.StrandConfig, "main", json_value(3))],
        expected: [],
      ),
    )
  let assert Ok(Some(cell)) =
    storage.get_register(store, register.StrandConfig, "main")
  assert cell.value == json_value(3) && cell.seq == third.first_seq

  // list_registers: key-ascending, prefix-filtered, namespace-scoped —
  // including keys containing LIKE metacharacters.
  let #(_, _) =
    commit_ok(
      store,
      model,
      Tx(
        writes: [
          SetRegister(register.OpToolArgs, "op1:step1:0", json_value(1)),
          SetRegister(register.OpToolArgs, "op1:step1:1", json_value(2)),
          SetRegister(register.OpToolArgs, "op1:step2:0", json_value(3)),
          SetRegister(register.OpToolArgs, "op2:step1:0", json_value(4)),
          SetRegister(register.OpToolArgs, "op1%weird_key", json_value(5)),
          SetRegister(register.OpMeta, "op1:step1:0", json_value(6)),
        ],
        expected: [],
      ),
    )
  let assert Ok(all) = storage.list_registers(store, register.OpToolArgs, None)
  assert list.map(all, fn(pair) { pair.0 })
    == [
      "op1%weird_key",
      "op1:step1:0",
      "op1:step1:1",
      "op1:step2:0",
      "op2:step1:0",
    ]
  let assert Ok(op1) =
    storage.list_registers(store, register.OpToolArgs, Some("op1:"))
  assert list.map(op1, fn(pair) { pair.0 })
    == ["op1:step1:0", "op1:step1:1", "op1:step2:0"]
  let assert Ok(weird) =
    storage.list_registers(store, register.OpToolArgs, Some("op1%"))
  assert list.map(weird, fn(pair) { pair.0 }) == ["op1%weird_key"]
  let assert Ok(none) =
    storage.list_registers(store, register.OpToolArgs, Some("op3"))
  assert none == []
  let assert Ok(Nil) = storage.close(store)
  Nil
}

fn cas_checks(backend: Backend(handle)) -> Nil {
  let store = backend.open("cas")
  let model = storage.empty_stats()

  // Expect-absent on an absent cell: passes.
  let #(model, first) =
    commit_ok(
      store,
      model,
      Tx(
        writes: [SetRegister(register.OpState, "op", json_value(1))],
        expected: [
          Expect(register.OpState, "op", None),
        ],
      ),
    )

  // Expect-absent on an existing cell: stale, nothing applied.
  let ctx = new_ctx()
  let #(a, ctx) = message(ctx, None, "a")
  let failing_none =
    Tx(writes: [InsertEntry(a)], expected: [
      Expect(register.OpState, "op", None),
    ])
  let assert Error(StaleExpectation(failed)) =
    storage.commit(store, failing_none)
  assert failed == Expect(register.OpState, "op", None)
  let assert Ok(found) = storage.get_entries(store, [a.id])
  assert dict.size(found) == 0

  // Matching seq: passes.
  let #(model, second) =
    commit_ok(
      store,
      model,
      Tx(
        writes: [SetRegister(register.OpState, "op", json_value(2))],
        expected: [
          Expect(register.OpState, "op", Some(first.first_seq)),
        ],
      ),
    )

  // Stale seq (the cell moved on): fails, nothing applied.
  let stale =
    Tx(writes: [SetRegister(register.OpState, "op", json_value(9))], expected: [
      Expect(register.OpState, "op", Some(first.first_seq)),
    ])
  let assert Error(StaleExpectation(_)) = storage.commit(store, stale)
  let assert Ok(Some(cell)) =
    storage.get_register(store, register.OpState, "op")
  assert cell.value == json_value(2)

  // Expect-some on an absent cell: fails.
  let absent =
    Tx(writes: [], expected: [Expect(register.OpState, "missing", Some(1))])
  let assert Error(StaleExpectation(_)) = storage.commit(store, absent)

  // Several expectations, all holding, guard one commit.
  let #(model, _) =
    commit_ok(
      store,
      model,
      Tx(writes: [DeleteRegister(register.OpState, "op")], expected: [
        Expect(register.OpState, "op", Some(second.first_seq)),
        Expect(register.OpState, "missing", None),
      ]),
    )
  // A deleted cell satisfies expect-absent again.
  let #(_, _) =
    commit_ok(
      store,
      model,
      Tx(writes: [], expected: [Expect(register.OpState, "op", None)]),
    )
  let _ = ctx
  let assert Ok(Nil) = storage.close(store)
  Nil
}

fn placement_checks(backend: Backend(handle)) -> Nil {
  // The pi §2.2 placement pattern: content staged in a PendingEntry
  // register, then one transaction inserts the complete entry, deletes
  // the pending value, and moves the leaf — CAS-guarded end to end.
  let store = backend.open("placement")
  let ctx = new_ctx()
  let #(root, ctx) = message(ctx, None, "root")
  let model = storage.empty_stats()
  let #(model, _) =
    commit_ok(
      store,
      model,
      Tx(
        writes: [
          InsertEntry(root),
          SetRegister(
            register.StrandLeaf,
            "main",
            register.leaf_value(Some(root.id)),
          ),
        ],
        expected: [],
      ),
    )

  let #(queued, _ctx) = message(ctx, Some(root.id), "queued")
  let queued_key = ids.entry_id_to_string(queued.id)
  let payload = register.value(json.String("staged message payload"))
  let #(model, staged) =
    commit_ok(
      store,
      model,
      Tx(
        writes: [SetRegister(register.PendingEntry, queued_key, payload)],
        expected: [Expect(register.PendingEntry, queued_key, None)],
      ),
    )
  // Until placement, exactly the pending value exists.
  let assert Ok(Some(pending)) =
    storage.get_register(store, register.PendingEntry, queued_key)
  assert pending.value == payload
  let assert Ok(found) = storage.get_entries(store, [queued.id])
  assert dict.size(found) == 0

  let #(_, _) =
    commit_ok(
      store,
      model,
      Tx(
        writes: [
          InsertEntry(queued),
          DeleteRegister(register.PendingEntry, queued_key),
          SetRegister(
            register.StrandLeaf,
            "main",
            register.leaf_value(Some(queued.id)),
          ),
        ],
        expected: [
          Expect(register.PendingEntry, queued_key, Some(staged.first_seq)),
        ],
      ),
    )
  // After placement, exactly the entry exists.
  let assert Ok(None) =
    storage.get_register(store, register.PendingEntry, queued_key)
  let assert Ok(listed) =
    storage.list_registers(store, register.PendingEntry, None)
  assert listed == []
  let assert Ok(found) = storage.get_entries(store, [queued.id])
  assert dict.size(found) == 1
  let assert Ok(Some(leaf)) =
    storage.get_register(store, register.StrandLeaf, "main")
  assert register.read_leaf(leaf.value) == Ok(Some(queued.id))
  let assert Ok(Nil) = storage.close(store)
  Nil
}

fn branch_scan_checks(backend: Backend(handle)) -> Nil {
  let store = backend.open("branch_scan")
  let ctx = new_ctx()
  let #(m1, ctx) = message(ctx, None, "m1")
  let #(m2, ctx) = message(ctx, Some(m1.id), "m2")
  let #(c3, ctx) = compaction(ctx, Some(m2.id), "sum")
  let #(x4, ctx) = custom(ctx, Some(c3.id), "note")
  let #(m5, ctx) = message(ctx, Some(x4.id), "m5")
  let #(m6, ctx) = message(ctx, Some(m5.id), "m6")
  let chain = [m1, m2, c3, x4, m5, m6]
  let model = storage.empty_stats()
  // Commit one per transaction with register noise between, so entry
  // seqs carry gaps the scans must tolerate.
  let #(_, _) =
    list.fold(over: chain, from: #(model, 0), with: fn(step, entry) {
      let #(model, n) = step
      let #(model, _) =
        commit_ok(
          store,
          model,
          Tx(
            writes: [
              SetRegister(register.OpState, "noise", json_value(n)),
              InsertEntry(entry),
            ],
            expected: [],
          ),
        )
      #(model, n + 1)
    })

  let newest = storage.branch_scan(from: m6.id)
  // Full path, newest first.
  assert scan_ids(store, newest) == [m6.id, m5.id, x4.id, c3.id, m2.id, m1.id]
  // Oldest first.
  assert scan_ids(store, newest |> storage.branch_order(storage.OldestFirst))
    == [m1.id, m2.id, c3.id, x4.id, m5.id, m6.id]
  // Stop at the compaction, inclusive.
  assert scan_ids(
      store,
      newest |> storage.branch_stop_at_kind(storage.Compaction),
    )
    == [m6.id, m5.id, x4.id, c3.id]
  // Stop at an id.
  assert scan_ids(store, newest |> storage.branch_stop_at_id(x4.id))
    == [m6.id, m5.id, x4.id]
  // Kind filter.
  assert scan_ids(store, newest |> storage.branch_kind(storage.Message))
    == [m6.id, m5.id, m2.id, m1.id]
  // Custom-type filter.
  assert scan_ids(store, newest |> storage.branch_custom_type("note"))
    == [x4.id]
  // Kind filter combined with a limit: the limit counts surviving rows.
  assert scan_ids(
      store,
      newest |> storage.branch_kind(storage.Message) |> storage.branch_limit(3),
    )
    == [m6.id, m5.id, m2.id]
  // A scan from mid-path sees only its ancestors.
  assert scan_ids(store, storage.branch_scan(from: m2.id)) == [m2.id, m1.id]
  // Limit.
  assert scan_ids(store, newest |> storage.branch_limit(2)) == [m6.id, m5.id]
  // A zero or negative limit returns no rows — never "no limit". Callers
  // compute limits like `budget - consumed`, so a negative result must
  // mean "nothing left".
  assert scan_ids(store, newest |> storage.branch_limit(0)) == []
  assert scan_ids(store, newest |> storage.branch_limit(-1)) == []
  assert scan_ids(store, newest |> storage.branch_limit(-100)) == []

  // Cursor paging: page size two until exhaustion reproduces the full
  // scan, both directions.
  assert page_through(store, newest, 2)
    == [m6.id, m5.id, x4.id, c3.id, m2.id, m1.id]
  assert page_through(
      store,
      newest |> storage.branch_order(storage.OldestFirst),
      2,
    )
    == [m1.id, m2.id, c3.id, x4.id, m5.id, m6.id]

  // A stop kind with no match on the path scans through to the root.
  assert scan_ids(
      store,
      newest |> storage.branch_stop_at_kind(storage.BranchSummary),
    )
    == [m6.id, m5.id, x4.id, c3.id, m2.id, m1.id]
  // A stop id that is not on this path never fires: commit a divergent
  // sibling and stop at it from the main tip.
  let #(d3, _ctx) = message(ctx, Some(m2.id), "d3")
  let assert Ok(_) =
    storage.commit(store, Tx(writes: [InsertEntry(d3)], expected: []))
  assert scan_ids(store, newest |> storage.branch_stop_at_id(d3.id))
    == [m6.id, m5.id, x4.id, c3.id, m2.id, m1.id]

  // The stop applies before the cursor: with the cursor below the
  // compaction stop, only rows between them emit ...
  let assert Ok(found) = storage.get_entries(store, [m5.id, c3.id])
  let assert Ok(stored_m5) = dict.get(found, m5.id)
  let assert Ok(stored_c3) = dict.get(found, c3.id)
  assert scan_ids(
      store,
      newest
        |> storage.branch_stop_at_kind(storage.Compaction)
        |> storage.branch_cursor(stored_m5.seq),
    )
    == [x4.id, c3.id]
  // ... and with the cursor below a higher stop, nothing emits at all —
  // the scan never continues past its stop to reach the cursor window.
  assert scan_ids(
      store,
      newest
        |> storage.branch_stop_at_kind(storage.Custom)
        |> storage.branch_cursor(stored_c3.seq),
    )
    == []

  // Unknown start.
  let #(stranger, _) = mint(new_ctx() |> skip_mints(50))
  let assert Error(UnknownEntry(_)) =
    storage.scan_branch(store, storage.branch_scan(from: stranger))
  let assert Ok(Nil) = storage.close(store)
  Nil
}

fn skip_mints(ctx: Ctx, n: Int) -> Ctx {
  case n <= 0 {
    True -> ctx
    False -> {
      let #(_, ctx) = mint(ctx)
      skip_mints(ctx, n - 1)
    }
  }
}

// Pages a branch scan with the given page size until an empty page,
// concatenating the pages.
fn page_through(
  store: Storage(handle),
  q: storage.BranchScan,
  page: Int,
) -> List(EntryId) {
  page_through_loop(store, q, page, None, [])
}

fn page_through_loop(
  store: Storage(handle),
  q: storage.BranchScan,
  page: Int,
  cursor: Option(Int),
  accumulator: List(EntryId),
) -> List(EntryId) {
  let paged = case cursor {
    Some(seq) -> q |> storage.branch_limit(page) |> storage.branch_cursor(seq)
    None -> q |> storage.branch_limit(page)
  }
  let assert Ok(entries) = storage.scan_branch(store, paged)
  case entries {
    [] -> list.reverse(accumulator)
    _ -> {
      let assert Ok(last) = list.last(entries)
      page_through_loop(
        store,
        q,
        page,
        Some(last.seq),
        list.reverse(ids_of(entries)) |> list.append(accumulator),
      )
    }
  }
}

fn branch_index_checks(backend: Backend(handle)) -> Nil {
  // A branching torture script. After every commit, every entry ever
  // written must scan to exactly its model root path (pi §2.6: chains
  // yield the exact root path with no gaps or duplicates; stale branches
  // remain valid cache history), which the suite tracks independently by
  // parent pointers.
  let store = backend.open("branch_index")
  let ctx = new_ctx()

  // Main: e1 - e2 - e3(compaction) - e4 - e5
  let #(e1, ctx) = message(ctx, None, "e1")
  let #(e2, ctx) = message(ctx, Some(e1.id), "e2")
  let #(e3, ctx) = compaction(ctx, Some(e2.id), "checkpoint")
  let #(e4, ctx) = message(ctx, Some(e3.id), "e4")
  let #(e5, ctx) = message(ctx, Some(e4.id), "e5")
  // Divergence with no compaction below: full-copy segment.
  let #(f3, ctx) = message(ctx, Some(e2.id), "f3")
  let #(f4, ctx) = message(ctx, Some(f3.id), "f4")
  // Main continues after the divergence.
  let #(e6, ctx) = message(ctx, Some(e5.id), "e6")
  // Divergence above the compaction: compaction-bounded segment.
  let #(g5, ctx) = message(ctx, Some(e4.id), "g5")
  let #(g6, ctx) = message(ctx, Some(g5.id), "g6")
  // Divergence from the compaction entry itself.
  let #(h4, ctx) = message(ctx, Some(e3.id), "h4")
  // Divergence from a segment whose own rows hold no compaction: the
  // newest-compaction search must walk the base chain (mandatory rule 2).
  let #(i7, ctx) = message(ctx, Some(g6.id), "i7")
  // Divergence from an entry physically inside an older segment (e5 sits
  // in main's segment while newer tips moved on): the resolved cover
  // must itself contain the anchor in its logical range (mandatory rule 1).
  let #(j6, ctx) = message(ctx, Some(e5.id), "j6")
  // A second compaction on a branch, then a divergence below it.
  let #(k7, ctx) = compaction(ctx, Some(g6.id), "branch checkpoint")
  let #(k8, ctx) = message(ctx, Some(k7.id), "k8")
  let #(l8, _ctx) = message(ctx, Some(k7.id), "l8")

  let script = [
    [e1, e2],
    [e3],
    [e4, e5],
    [f3],
    [f4],
    [e6],
    [g5],
    [g6],
    [h4],
    [i7],
    [j6],
    [k7, k8],
    [l8],
  ]
  let all = [e1, e2, e3, e4, e5, f3, f4, e6, g5, g6, h4, i7, j6, k7, k8, l8]

  // The model: parent pointers by id.
  let parents =
    list.fold(over: all, from: dict.new(), with: fn(parents, entry) {
      dict.insert(parents, entry.id, entry.parent)
    })

  let committed =
    list.fold(
      over: script,
      from: #(storage.empty_stats(), []),
      with: fn(step, batch) {
        let #(model, committed) = step
        let #(model, _) =
          commit_ok(
            store,
            model,
            Tx(writes: list.map(batch, InsertEntry), expected: []),
          )
        let committed = list.append(committed, batch)
        // Every committed entry scans to its exact model root path, after
        // every commit.
        list.each(committed, fn(entry) {
          let expected = model_path(parents, entry.id, [])
          assert scan_ids(
              store,
              storage.branch_scan(from: entry.id)
                |> storage.branch_order(storage.OldestFirst),
            )
            == expected
        })
        #(model, committed)
      },
    )
  let _ = committed

  // Context-projection shape: newest first, stop at first compaction —
  // never reads past its checkpoint even across branch segments.
  assert scan_ids(
      store,
      storage.branch_scan(from: l8.id)
        |> storage.branch_stop_at_kind(storage.Compaction),
    )
    == [l8.id, k7.id]
  assert scan_ids(
      store,
      storage.branch_scan(from: i7.id)
        |> storage.branch_stop_at_kind(storage.Compaction),
    )
    == [i7.id, g6.id, g5.id, e4.id, e3.id]
  assert scan_ids(
      store,
      storage.branch_scan(from: f4.id)
        |> storage.branch_stop_at_kind(storage.Compaction),
    )
    == [f4.id, f3.id, e2.id, e1.id]
  let assert Ok(Nil) = storage.close(store)
  Nil
}

fn model_path(
  parents: Dict(EntryId, Option(EntryId)),
  id: EntryId,
  accumulator: List(EntryId),
) -> List(EntryId) {
  let accumulator = [id, ..accumulator]
  case dict.get(parents, id) {
    Ok(Some(parent)) -> model_path(parents, parent, accumulator)
    Ok(None) -> accumulator
    Error(Nil) -> accumulator
  }
}

fn entry_scan_checks(backend: Backend(handle)) -> Nil {
  let store = backend.open("entry_scan")
  let ctx = new_ctx()
  let #(m1, ctx) = message(ctx, None, "m1")
  let #(c2, ctx) = compaction(ctx, Some(m1.id), "sum")
  let #(x3, ctx) = custom(ctx, Some(c2.id), "note")
  let #(x4, ctx) = custom(ctx, Some(x3.id), "other")
  let #(m5, _ctx) = message(ctx, Some(x4.id), "m5")
  let #(_, _) =
    commit_ok(
      store,
      storage.empty_stats(),
      Tx(
        writes: [
          InsertEntry(m1),
          InsertEntry(c2),
          InsertEntry(x3),
          InsertEntry(x4),
          InsertEntry(m5),
        ],
        expected: [],
      ),
    )
  let assert Ok(all) = storage.scan_entries(store, storage.entry_scan())
  assert ids_of(all) == [m1.id, c2.id, x3.id, x4.id, m5.id]
  let assert Ok(descending) =
    storage.scan_entries(
      store,
      storage.entry_scan() |> storage.entry_order(storage.NewestFirst),
    )
  assert ids_of(descending) == list.reverse(ids_of(all))
  let assert Ok(messages) =
    storage.scan_entries(
      store,
      storage.entry_scan() |> storage.entry_kind(storage.Message),
    )
  assert ids_of(messages) == [m1.id, m5.id]
  let assert Ok(notes) =
    storage.scan_entries(
      store,
      storage.entry_scan() |> storage.entry_custom_type("note"),
    )
  assert ids_of(notes) == [x3.id]
  let assert Ok(window) =
    storage.scan_entries(
      store,
      storage.entry_scan() |> storage.entry_seq_range(Some(2), Some(4)),
    )
  assert ids_of(window) == [c2.id, x3.id, x4.id]
  let assert Ok(limited) =
    storage.scan_entries(store, storage.entry_scan() |> storage.entry_limit(2))
  assert ids_of(limited) == [m1.id, c2.id]
  // A zero or negative limit returns no rows — never "no limit". SQLite's
  // own `LIMIT -1` means unlimited, so an unclamped backend would return
  // every row here while another returns none: a silent divergence.
  let assert Ok(zero) =
    storage.scan_entries(store, storage.entry_scan() |> storage.entry_limit(0))
  assert zero == []
  let assert Ok(negative) =
    storage.scan_entries(store, storage.entry_scan() |> storage.entry_limit(-1))
  assert negative == []
  let assert Ok(very_negative) =
    storage.scan_entries(
      store,
      storage.entry_scan()
        |> storage.entry_kind(storage.Message)
        |> storage.entry_limit(-100),
    )
  assert very_negative == []
  let assert Ok(Nil) = storage.close(store)
  Nil
}

fn usage_scan_checks(backend: Backend(handle)) -> Nil {
  let store = backend.open("usage_scan")
  let ctx = new_ctx()
  let #(a, ctx) = message(ctx, None, "a")
  let #(u1, ctx) = usage(ctx, Some(a.id), 10)
  let #(u2, ctx) = usage(ctx, None, 20)
  let #(u3, _ctx) = usage(ctx, None, 30)
  let adjustment = UsageRow(..u3, adjustment: True)
  let model = storage.empty_stats()
  let #(model, first) =
    commit_ok(
      store,
      model,
      Tx(writes: [InsertEntry(a), InsertUsage(u1)], expected: []),
    )
  let #(_, _) =
    commit_ok(
      store,
      model,
      Tx(writes: [InsertUsage(u2), InsertUsage(adjustment)], expected: []),
    )

  let assert Ok(rows) = storage.scan_usage(store, storage.usage_scan())
  let assert [r1, r2, r3] = rows
  assert r1.id == u1.id && r1.entry_id == Some(a.id) && !r1.adjustment
  assert r2.id == u2.id && r2.entry_id == None
  assert r3.id == u3.id && r3.adjustment
  assert r1.seq < r2.seq && r2.seq < r3.seq
  assert r1.usage == u1.usage
  assert r1.details == u1.details

  // Descending and limited.
  let assert Ok(newest) =
    storage.scan_usage(
      store,
      storage.usage_scan()
        |> storage.usage_order(storage.NewestFirst)
        |> storage.usage_limit(1),
    )
  let assert [only] = newest
  assert only.id == u3.id

  // Catch-up read: everything after a persisted high-water seq.
  let assert Ok(catch_up) =
    storage.scan_usage(
      store,
      storage.usage_scan() |> storage.usage_seq_range(Some(r1.seq + 1), None),
    )
  assert list.map(catch_up, fn(row) { row.id }) == [u2.id, u3.id]

  // A zero or negative limit returns no rows — never "no limit".
  let assert Ok(zero) =
    storage.scan_usage(store, storage.usage_scan() |> storage.usage_limit(0))
  assert zero == []
  let assert Ok(negative) =
    storage.scan_usage(store, storage.usage_scan() |> storage.usage_limit(-1))
  assert negative == []
  let _ = first
  let assert Ok(Nil) = storage.close(store)
  Nil
}

fn close_checks(backend: Backend(handle)) -> Nil {
  let store = backend.open("close")
  let ctx = new_ctx()
  let #(a, _ctx) = message(ctx, None, "a")
  let #(_, _) =
    commit_ok(
      store,
      storage.empty_stats(),
      Tx(writes: [InsertEntry(a)], expected: []),
    )
  let assert Ok(Nil) = storage.close(store)
  // Idempotent.
  assert storage.close(store) == Ok(Nil)
  // Reads on a closed handle are refused in-band.
  let assert Error(HandleClosed) =
    storage.get_register(store, register.StrandLeaf, "main")
  let assert Error(HandleClosed) = storage.stats(store)
  // Commits on a closed handle fault in-band.
  let assert Error(Faulted(_)) =
    storage.commit(store, Tx(writes: [], expected: []))
  Nil
}
