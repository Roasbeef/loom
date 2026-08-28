//// Deterministic fixtures for events tests: an in-memory session
//// store, seeded id minting, and small entry/usage builders.

import core/clock
import core/entry.{
  type Entry, type UsageRow, CompactionEntry, CustomEntry, MessageEntry,
  UsageRow,
}
import core/ids.{type EntryId, type SessionId, type UsageId}
import core/message.{Usage, UsageCost, UserMessage, UserText}
import core/tx.{InsertEntry, InsertUsage, Tx}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import storage/memory
import storage/storage.{type Storage}

/// A threaded fixture context: a deterministic id generator.
pub type Ctx {
  Ctx(generator: ids.Generator)
}

/// A fresh context with a constant seed and a stepping clock, so every
/// test run mints the same ids in the same order.
pub fn new_ctx() -> Ctx {
  Ctx(generator: ids.generator(clock.stepping(from: 1000, by: 1), seed: 7))
}

/// A fresh in-memory store with a stepping clock.
pub fn open_store() -> Storage(Subject(memory.Message)) {
  let assert Ok(store) = memory.open(clock.stepping(from: 5000, by: 1))
    as "memory backend must open"
  store
}

/// Mints an entry id.
pub fn mint(ctx: Ctx) -> #(EntryId, Ctx) {
  let #(id, generator) = ids.mint_entry(ctx.generator)
  #(id, Ctx(generator:))
}

/// Mints a usage id.
pub fn mint_usage(ctx: Ctx) -> #(UsageId, Ctx) {
  let #(id, generator) = ids.mint_usage(ctx.generator)
  #(id, Ctx(generator:))
}

/// Mints an operation id.
pub fn mint_op(ctx: Ctx) -> #(ids.OpId, Ctx) {
  let #(id, generator) = ids.mint_op(ctx.generator)
  #(id, Ctx(generator:))
}

/// Mints a session id.
pub fn mint_session(ctx: Ctx) -> #(SessionId, Ctx) {
  let #(id, generator) = ids.mint_session(ctx.generator)
  #(id, Ctx(generator:))
}

/// A message entry with the given parent and a one-line user message.
/// The `seq`/`ts` fields are placeholders for storage to overwrite.
pub fn message_entry(
  ctx: Ctx,
  parent: Option(EntryId),
  text: String,
) -> #(Entry, Ctx) {
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

/// A compaction entry with the given parent and summary.
pub fn compaction_entry(
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
      tokens_before: 100,
      from_hook: False,
      usage: None,
    )
  #(entry, ctx)
}

/// A custom entry with the given parent and type name, carrying no
/// data.
pub fn custom_entry(
  ctx: Ctx,
  parent: Option(EntryId),
  custom_type: String,
) -> #(Entry, Ctx) {
  let #(id, ctx) = mint(ctx)
  let entry = CustomEntry(id:, parent:, seq: 0, ts: 0, custom_type:, data: None)
  #(entry, ctx)
}

/// A usage row charging `input` input tokens. The `seq` field is a
/// placeholder.
pub fn usage_row(ctx: Ctx, input: Int) -> #(UsageRow, Ctx) {
  let #(id, ctx) = mint_usage(ctx)
  let row =
    UsageRow(
      id:,
      seq: 0,
      entry_id: None,
      adjustment: False,
      usage: Usage(
        input:,
        output: 1,
        cache_read: 0,
        cache_write: 0,
        cache_write_1h: None,
        reasoning: Some(1),
        total_tokens: input + 1,
        cost: UsageCost(
          input: 0.001,
          output: 0.002,
          cache_read: 0.0,
          cache_write: 0.0,
          total: 0.003,
        ),
      ),
      details: None,
    )
  #(row, ctx)
}

/// Commits a list of entries in one transaction, asserting success.
pub fn commit_entries(store: Storage(handle), entries: List(Entry)) -> Nil {
  let writes = list.map(entries, InsertEntry)
  let assert Ok(_) = storage.commit(store, Tx(writes:, expected: []))
    as "fixture commit must succeed"
  Nil
}

/// Commits one entry and one usage row in one transaction.
pub fn commit_entry_and_usage(
  store: Storage(handle),
  entry: Entry,
  row: UsageRow,
) -> Nil {
  let assert Ok(_) =
    storage.commit(
      store,
      Tx(writes: [InsertEntry(entry), InsertUsage(row)], expected: []),
    )
    as "fixture commit must succeed"
  Nil
}
