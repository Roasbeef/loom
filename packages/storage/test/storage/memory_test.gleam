//// Unit tests driving the pure MemoryState functions directly.

import core/json
import core/register
import core/tx.{
  Corruption, Expect, InsertEntry, InsertUsage, SetRegister, StaleExpectation,
  Tx,
}
import gleam/dict
import gleam/option.{None, Some}
import storage/memory
import storage/storage
import support/fixtures

pub fn empty_state_test() {
  let state = memory.new()
  assert memory.stats(state) == Ok(storage.empty_stats())
  assert memory.list_registers(state, register.StrandLeaf, None) == Ok([])
}

pub fn commit_assigns_seqs_in_order_test() {
  let ctx = fixtures.new_ctx()
  let #(a, ctx) = fixtures.message_entry(ctx, None, "a")
  let #(b, _ctx) = fixtures.message_entry(ctx, Some(a.id), "b")
  let assert Ok(#(state, result)) =
    memory.commit(
      memory.new(),
      Tx(writes: [InsertEntry(a), InsertEntry(b)], expected: []),
      ts: 555,
    )
  assert result.first_seq == 1
  assert result.seqs == [1, 2]
  assert result.ts == 555
  let assert Ok(found) = memory.get_entries(state, [a.id, b.id])
  let assert Ok(stored_b) = dict.get(found, b.id)
  assert stored_b.seq == 2 && stored_b.ts == 555
}

pub fn duplicate_entry_id_is_corruption_and_applies_nothing_test() {
  let ctx = fixtures.new_ctx()
  let #(a, _ctx) = fixtures.message_entry(ctx, None, "a")
  let state = memory.new()
  let tx =
    Tx(
      writes: [
        SetRegister(register.StrandLeaf, "main", register.leaf_value(None)),
        InsertEntry(a),
        InsertEntry(a),
      ],
      expected: [],
    )
  let assert Error(Corruption(_)) = memory.commit(state, tx, ts: 1)
  // Purity means the caller keeps the untouched pre-state; nothing to
  // assert beyond the error itself.
}

pub fn missing_parent_is_corruption_test() {
  let ctx = fixtures.new_ctx()
  let #(orphan_parent, ctx) = fixtures.mint(ctx)
  let #(a, _ctx) = fixtures.message_entry(ctx, Some(orphan_parent), "a")
  let assert Error(Corruption(_)) =
    memory.commit(
      memory.new(),
      Tx(writes: [InsertEntry(a)], expected: []),
      ts: 1,
    )
}

pub fn usage_and_entry_share_id_namespace_test() {
  let ctx = fixtures.new_ctx()
  let #(a, ctx) = fixtures.message_entry(ctx, None, "a")
  let #(row, _ctx) = fixtures.usage_row(ctx, Some(a.id), 100)
  let assert Ok(#(state, _)) =
    memory.commit(
      memory.new(),
      Tx(writes: [InsertEntry(a), InsertUsage(row)], expected: []),
      ts: 1,
    )
  // Re-inserting the usage row under the same id is corruption.
  let assert Error(Corruption(_)) =
    memory.commit(state, Tx(writes: [InsertUsage(row)], expected: []), ts: 2)
}

pub fn cas_mismatch_applies_nothing_test() {
  let ctx = fixtures.new_ctx()
  let #(a, _ctx) = fixtures.message_entry(ctx, None, "a")
  let tx =
    Tx(writes: [InsertEntry(a)], expected: [
      Expect(register.StrandLeaf, "main", Some(1)),
    ])
  let assert Error(StaleExpectation(Expect(register.StrandLeaf, "main", _))) =
    memory.commit(memory.new(), tx, ts: 1)
}

pub fn register_set_replaces_and_stamps_seq_test() {
  let value_one = register.value(json.Int(1))
  let value_two = register.value(json.Int(2))
  let assert Ok(#(state, _)) =
    memory.commit(
      memory.new(),
      Tx(
        writes: [
          SetRegister(register.OpState, "op", value_one),
          SetRegister(register.OpState, "op", value_two),
        ],
        expected: [],
      ),
      ts: 1,
    )
  let assert Ok(Some(cell)) = memory.get_register(state, register.OpState, "op")
  assert cell.value == value_two
  assert cell.seq == 2
}

pub fn children_index_tracks_parents_test() {
  let ctx = fixtures.new_ctx()
  let #(a, ctx) = fixtures.message_entry(ctx, None, "a")
  let #(b, ctx) = fixtures.message_entry(ctx, Some(a.id), "b")
  let #(c, _ctx) = fixtures.message_entry(ctx, Some(a.id), "c")
  let assert Ok(#(state, _)) =
    memory.commit(
      memory.new(),
      Tx(writes: [InsertEntry(a), InsertEntry(b), InsertEntry(c)], expected: []),
      ts: 1,
    )
  assert memory.children_of(state, Some(a.id)) == [b.id, c.id]
  assert memory.children_of(state, None) == [a.id]
}
