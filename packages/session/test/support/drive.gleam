//// Test driver for building session histories: chained entry commits
//// against a session's storage handle, with the id generator and the
//// strand leaf threaded through a `Ctx`.

import core/clock
import core/entry
import core/ids.{type EntryId}
import core/json.{type JsonValue}
import core/message.{type AgentMessage}
import core/tx.{InsertEntry, InsertUsage, Tx}
import gleam/option.{type Option, None, Some}
import session/session.{type Session}
import storage/storage

/// A session under construction: the handle, the id mint, the current
/// leaf, and a counter for numbered message builders.
pub type Ctx {
  Ctx(
    session: Session,
    generator: ids.Generator,
    leaf: Option(EntryId),
    counter: Int,
  )
}

/// A fresh driver over an open session. The generator's clock only feeds
/// uuid timestamps, so fixed time is fine.
pub fn new_ctx(session: Session, seed: Int) -> Ctx {
  Ctx(
    session:,
    generator: ids.generator(clock.fixed(at: 1000), seed:),
    leaf: None,
    counter: 0,
  )
}

/// Appends one message entry under the current leaf and moves the leaf to
/// it.
pub fn append_message(ctx: Ctx, message: AgentMessage) -> #(Ctx, EntryId) {
  append_message_under(ctx, ctx.leaf, message)
}

/// Appends one message entry under an explicit parent and moves the leaf
/// to it (diverging appends build branches).
pub fn append_message_under(
  ctx: Ctx,
  parent: Option(EntryId),
  message: AgentMessage,
) -> #(Ctx, EntryId) {
  let #(id, generator) = ids.mint_entry(ctx.generator)
  let assert Ok(_) =
    storage.commit(
      ctx.session.store,
      Tx(
        writes: [
          InsertEntry(entry: entry.MessageEntry(
            id:,
            parent:,
            seq: 0,
            ts: 0,
            message:,
            terminate: False,
          )),
        ],
        expected: [],
      ),
    )
  #(Ctx(..ctx, generator:, leaf: Some(id)), id)
}

/// Appends a compaction entry under the current leaf and moves the leaf.
pub fn append_compaction(
  ctx: Ctx,
  summary: String,
  retained_tail: List(AgentMessage),
) -> #(Ctx, EntryId) {
  let #(id, generator) = ids.mint_entry(ctx.generator)
  let assert Ok(_) =
    storage.commit(
      ctx.session.store,
      Tx(
        writes: [
          InsertEntry(entry: entry.CompactionEntry(
            id:,
            parent: ctx.leaf,
            seq: 0,
            ts: 0,
            summary:,
            retained_tail:,
            tokens_before: 1000,
            from_hook: False,
            usage: None,
          )),
        ],
        expected: [],
      ),
    )
  #(Ctx(..ctx, generator:, leaf: Some(id)), id)
}

/// Appends a custom entry under the current leaf and moves the leaf.
pub fn append_custom(
  ctx: Ctx,
  custom_type: String,
  data: Option(JsonValue),
) -> #(Ctx, EntryId) {
  let #(id, generator) = ids.mint_entry(ctx.generator)
  let assert Ok(_) =
    storage.commit(
      ctx.session.store,
      Tx(
        writes: [
          InsertEntry(entry: entry.CustomEntry(
            id:,
            parent: ctx.leaf,
            seq: 0,
            ts: 0,
            custom_type:,
            data:,
          )),
        ],
        expected: [],
      ),
    )
  #(Ctx(..ctx, generator:, leaf: Some(id)), id)
}

/// Appends one usage-ledger row attributed to an entry.
pub fn append_usage(
  ctx: Ctx,
  entry_id: Option(EntryId),
  usage: message.Usage,
) -> Ctx {
  let #(id, generator) = ids.mint_usage(ctx.generator)
  let assert Ok(_) =
    storage.commit(
      ctx.session.store,
      Tx(
        writes: [
          InsertUsage(row: entry.UsageRow(
            id:,
            seq: 0,
            entry_id:,
            adjustment: False,
            usage:,
            details: None,
          )),
        ],
        expected: [],
      ),
    )
  Ctx(..ctx, generator:)
}

/// Bumps and returns the driver's message counter.
pub fn tick(ctx: Ctx) -> #(Ctx, Int) {
  let counter = ctx.counter + 1
  #(Ctx(..ctx, counter:), counter)
}
