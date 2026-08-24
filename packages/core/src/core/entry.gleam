//// The write-once durable rows: conversation entries and usage-ledger rows.
////
//// An entry is the complete stored row — placement fields (`id`, `parent`,
//// `seq`, `ts`) and payload together. What storage returns is exactly what
//// was committed: no materialization step, no join. Entries are created in
//// exactly one transaction and never modified or deleted (the precise
//// rewrite is the sole, repo-level exception).
////
//// The variants and fields transcribe the frozen contract in the
//// implementation spec Part 1.1, which itself follows pi §2.1.

import core/ids.{type EntryId, type Seq, type UsageId}
import core/json.{type JsonValue}
import core/message.{type AgentMessage, type Usage}
import gleam/option.{type Option}

/// One row of the conversation tree.
///
/// Shared placement invariants (all constructors): `id` is unique within
/// the session; `parent` names an existing entry or `None` for a root; a
/// missing parent is always corruption; `seq` and `ts` (Unix ms) are
/// assigned by storage at commit — before commit they are placeholders.
///
/// Per-constructor invariants:
///
/// - `MessageEntry`: an assistant `message` is always settled (never a
///   `Pending` stop reason). `terminate` is orchestration state carried on
///   tool-result entries — the message type has no field for it; it is
///   `False` everywhere it is meaningless.
/// - `CompactionEntry`: `retained_tail` is the complete retained suffix
///   (`[]` when empty) — context never reads past a compaction, so the
///   entry is a self-contained checkpoint, not a pointer into history.
///   `tokens_before` is the context size the compaction replaced.
///   `from_hook` is `True` for hook output, `False` for generated;
///   generated summaries carry their `usage`.
/// - `BranchSummaryEntry`: `from_id` is the summarized branch's
///   pre-navigation leaf. `from_hook`/`usage` as for compactions.
/// - `CustomEntry`: `custom_type` is a structural field — branch queries
///   filter on it — and is meaningful only on this variant. `data` is an
///   opaque application payload and may be absent.
pub type Entry {
  /// A conversation message at its position in the tree.
  MessageEntry(
    id: EntryId,
    parent: Option(EntryId),
    seq: Seq,
    ts: Int,
    message: AgentMessage,
    terminate: Bool,
  )
  /// A self-contained context checkpoint summarizing everything before it.
  CompactionEntry(
    id: EntryId,
    parent: Option(EntryId),
    seq: Seq,
    ts: Int,
    summary: String,
    retained_tail: List(AgentMessage),
    tokens_before: Int,
    from_hook: Bool,
    usage: Option(Usage),
  )
  /// A summary of an abandoned branch, written on navigation.
  BranchSummaryEntry(
    id: EntryId,
    parent: Option(EntryId),
    seq: Seq,
    ts: Int,
    from_id: EntryId,
    summary: String,
    from_hook: Bool,
    usage: Option(Usage),
  )
  /// An application-defined row under a registered custom type name.
  CustomEntry(
    id: EntryId,
    parent: Option(EntryId),
    seq: Seq,
    ts: Int,
    custom_type: String,
    data: Option(JsonValue),
  )
}

/// One append-only cost-ledger row. Never modified, never deleted.
///
/// Constructor invariants: `id` is unique within the session; `seq` is
/// assigned by storage at commit; `entry_id`, when present, names the entry
/// this cost belongs to; `adjustment` is `True` for a caller-supplied
/// reconciliation row rather than a provider report; `details` is opaque
/// application data.
pub type UsageRow {
  UsageRow(
    id: UsageId,
    seq: Seq,
    entry_id: Option(EntryId),
    adjustment: Bool,
    usage: Usage,
    details: Option(JsonValue),
  )
}
