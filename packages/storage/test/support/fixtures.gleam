//// Deterministic fixtures for storage tests: seeded id generation and
//// small entry/usage builders threaded through a test context.

import core/clock
import core/entry.{
  type Entry, type UsageRow, CompactionEntry, CustomEntry, MessageEntry,
  UsageRow,
}
import core/ids.{type EntryId, type UsageId}
import core/json
import core/message.{Usage, UsageCost, UserMessage, UserText}
import gleam/option.{type Option, None, Some}

/// A threaded fixture context: a deterministic id generator.
pub type Ctx {
  Ctx(generator: ids.Generator)
}

/// A fresh context with a constant seed and a stepping clock, so every
/// test run mints the same ids in the same order.
pub fn new_ctx() -> Ctx {
  Ctx(generator: ids.generator(clock.stepping(from: 1000, by: 1), seed: 7))
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

/// A compaction entry with the given parent.
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

/// A custom entry with the given parent, type name, and no data.
pub fn custom_entry(
  ctx: Ctx,
  parent: Option(EntryId),
  custom_type: String,
) -> #(Entry, Ctx) {
  let #(id, ctx) = mint(ctx)
  let entry = CustomEntry(id:, parent:, seq: 0, ts: 0, custom_type:, data: None)
  #(entry, ctx)
}

/// A usage row charging `input` input tokens, attributed to an optional
/// entry. The `seq` field is a placeholder.
pub fn usage_row(
  ctx: Ctx,
  entry_id: Option(EntryId),
  input: Int,
) -> #(UsageRow, Ctx) {
  let #(id, ctx) = mint_usage(ctx)
  let row =
    UsageRow(
      id:,
      seq: 0,
      entry_id:,
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
      details: Some(json.Object([#("note", json.String("fixture"))])),
    )
  #(row, ctx)
}
