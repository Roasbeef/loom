//// The storage behaviour: one session's durable store behind a uniform,
//// backend-agnostic handle.
////
//// A `Storage(handle)` is a record of functions closed over a backend
//// handle, implementing the frozen interface contract in the
//// implementation spec Part 1.2. Two backends ship in this package:
//// `storage/memory` (pure maps inside an actor) and `storage/sqlite`
//// (one database file per session, writer lease, private branch index).
//// Both pass the same conformance suite.
////
//// The normative commit rules (Part 1.2 rules 1–5, following pi Part 1)
//// are documented on `commit` below and enforced by every backend.
////
//// Process model: a handle may be shared, but the intended owner is a
//// single writer process (the WP-E `StorageWriter`). Both shipped
//// backends serialize all operations through one actor mailbox, so
//// "transactions on one session are serialized: one writer, one queue"
//// holds even under accidental sharing; ordering between two concurrent
//// committers is then mailbox order, which is exactly the interleaving
//// the CAS expectations exist to detect.

import core/corruption.{type CorruptionReport}
import core/entry.{
  type Entry, type UsageRow, BranchSummaryEntry, CompactionEntry, CustomEntry,
  MessageEntry,
}
import core/ids.{type EntryId, type Seq}
import core/message.{type Usage, Usage, UsageCost}
import core/register.{type RegisterNs, type RegisterValue}
import core/tx.{type CommitError, type CommitResult, type Tx}
import gleam/dict.{type Dict}
import gleam/option.{type Option, None, Some}

/// One session's storage, as a record of functions over a backend handle.
///
/// Constructor invariants: every field implements the Part 1.2 contract
/// for the same underlying session; `handle` is the value threaded into
/// each function. Callers use the module-level wrappers (`storage.commit`,
/// `storage.scan_branch`, …) rather than reaching into fields.
pub type Storage(handle) {
  Storage(
    /// The backend handle every operation receives.
    handle: handle,
    /// See `storage.commit`.
    commit: fn(handle, Tx) -> Result(CommitResult, CommitError),
    /// See `storage.get_entries`.
    get_entries: fn(handle, List(EntryId)) ->
      Result(Dict(EntryId, Entry), StorageError),
    /// See `storage.get_register`.
    get_register: fn(handle, RegisterNs, String) ->
      Result(Option(Register), StorageError),
    /// See `storage.list_registers`.
    list_registers: fn(handle, RegisterNs, Option(String)) ->
      Result(List(#(String, Register)), StorageError),
    /// See `storage.scan_branch`.
    scan_branch: fn(handle, BranchScan) -> Result(List(Entry), StorageError),
    /// See `storage.scan_entries`.
    scan_entries: fn(handle, EntryScan) -> Result(List(Entry), StorageError),
    /// See `storage.scan_usage`.
    scan_usage: fn(handle, UsageScan) -> Result(List(UsageRow), StorageError),
    /// See `storage.stats`.
    stats: fn(handle) -> Result(SessionStats, StorageError),
    /// See `storage.close`.
    close: fn(handle) -> Result(Nil, StorageError),
  )
}

/// Why a read or lifecycle operation failed. Commits fail with the frozen
/// `core/tx.CommitError` instead.
pub type StorageError {
  /// Stored bytes failed a total decode. The session file is damaged or
  /// was written by something other than this storage version.
  CorruptRow(report: CorruptionReport)
  /// A query named an entry id that is not in the session (for example a
  /// `BranchScan.start` that was never committed).
  UnknownEntry(id: EntryId)
  /// The backend infrastructure failed: I/O error, SQL error, lost
  /// process. The reason is a human-readable description, not for
  /// dispatch.
  BackendFault(reason: String)
  /// The handle was used after `close`.
  HandleClosed
}

/// A register cell as stored: the value and the seq of the write that last
/// set it.
///
/// Constructor invariants: `seq` is the storage-assigned seq of the `set`
/// that produced `value`; it is what CAS expectations compare against.
pub type Register {
  Register(value: RegisterValue, seq: Seq)
}

/// The structural type tag of an entry — the field branch queries filter
/// on and the branch index denormalizes. Mirrors the four `core/entry`
/// constructors.
pub type EntryKind {
  /// A `MessageEntry`.
  Message
  /// A `CompactionEntry`.
  Compaction
  /// A `BranchSummaryEntry`.
  BranchSummary
  /// A `CustomEntry`.
  Custom
}

/// Scan direction for branch, entry, and usage scans.
pub type ScanOrder {
  /// Descending seq: the newest matching row first.
  NewestFirst
  /// Ascending seq: the oldest matching row first.
  OldestFirst
}

/// A branch query: the root path of `start`, ordered, truncated, filtered,
/// and paged. Semantics (pi §2.5): take the path from `start` toward the
/// root, order it (`order`), stop *inclusively* at the first `stop_at_kind`
/// or `stop_at_id` match in that order, filter by `kind`/`custom_type`,
/// apply the exclusive `cursor`, then apply `limit`. A stop entry is
/// returned only if it also passes the filter.
///
/// Constructor invariants: `start` must name a committed entry;
/// `custom_type` only matches `Custom` entries; `cursor` is an exclusive
/// seq bound — `NewestFirst` retains `seq < cursor`, `OldestFirst` retains
/// `seq > cursor`; `limit`, when present, is a row cap applied last —
/// a limit of zero or below returns no rows, never "no limit". Every
/// backend must implement that non-positive-limit rule identically; the
/// conformance suite asserts it.
pub type BranchScan {
  BranchScan(
    /// The entry whose root path is scanned.
    start: EntryId,
    /// End the ordered scan at the first entry of this kind, inclusive.
    stop_at_kind: Option(EntryKind),
    /// End the ordered scan at this entry, inclusive.
    stop_at_id: Option(EntryId),
    /// Keep only entries of this kind.
    kind: Option(EntryKind),
    /// Keep only custom entries with this `custom_type`.
    custom_type: Option(String),
    /// Scan direction; the default constructor uses `NewestFirst`.
    order: ScanOrder,
    /// Maximum rows returned, applied after every other step.
    limit: Option(Int),
    /// Exclusive seq cursor for paging, applied after the filter.
    cursor: Option(Seq),
  )
}

/// A session-wide entry inventory scan over a seq range, in seq order.
///
/// Constructor invariants: `from_seq`/`to_seq` are inclusive bounds;
/// `custom_type` only matches `Custom` entries; `limit`, when present, is
/// a row cap applied after ordering and filtering — a limit of zero or
/// below returns no rows, never "no limit". Every backend must implement
/// that non-positive-limit rule identically (callers compute limits like
/// `budget - consumed`, and a negative result must mean "nothing left",
/// not "everything"); the conformance suite asserts it.
pub type EntryScan {
  EntryScan(
    /// Keep only entries of this kind.
    kind: Option(EntryKind),
    /// Keep only custom entries with this `custom_type`.
    custom_type: Option(String),
    /// Inclusive lower seq bound.
    from_seq: Option(Seq),
    /// Inclusive upper seq bound.
    to_seq: Option(Seq),
    /// Scan direction; the default constructor uses `OldestFirst`.
    order: ScanOrder,
    /// Maximum rows returned.
    limit: Option(Int),
  )
}

/// A usage-ledger read over a seq range, in seq order.
///
/// Constructor invariants: `from_seq`/`to_seq` are inclusive bounds;
/// `limit`, when present, is a row cap — a limit of zero or below returns
/// no rows, never "no limit". Every backend must implement that
/// non-positive-limit rule identically; the conformance suite asserts it.
pub type UsageScan {
  UsageScan(
    /// Inclusive lower seq bound.
    from_seq: Option(Seq),
    /// Inclusive upper seq bound.
    to_seq: Option(Seq),
    /// Scan direction; the default constructor uses `OldestFirst`.
    order: ScanOrder,
    /// Maximum rows returned.
    limit: Option(Int),
  )
}

/// The maintained stats projection: after every commit it equals the
/// usage-ledger sum and the message-entry count. The conformance suite
/// asserts this equality.
///
/// Constructor invariants: `message_count` counts `MessageEntry` rows only
/// — not compactions, summaries, or custom entries; `usage` is the
/// field-wise sum of every ledger row, adjustments included.
pub type SessionStats {
  SessionStats(message_count: Int, usage: Usage)
}

// --- module-level wrappers ----------------------------------------------

/// Commits one transaction. The normative rules (Part 1.2 rules 1–5),
/// which every backend enforces:
///
/// 1. **All-or-none**: there is no observable state in which some of a
///    transaction's writes exist and others do not. Writes receive
///    **strictly increasing** seqs in the order given — gaps are legal,
///    within and between transactions — and apply in order within the
///    transaction, so an entry may name a parent created earlier in the
///    same transaction.
/// 2. Entries and usage rows share one session-wide id namespace; writing
///    either kind under any existing id is **corruption**, not an update.
///    Entry `seq`/`ts` fields inside `InsertEntry` are placeholders that
///    storage overwrites at commit.
/// 3. A register `set` replaces the cell's value; `delete` removes it;
///    deleting an absent cell is a no-op; no history is retained.
/// 4. **CAS**: before applying any write, every `Tx.expected` entry is
///    evaluated against the pre-transaction register state — `seq: None`
///    means the cell must not exist, `seq: Some(n)` means the cell must
///    exist with stored seq `n`. Any mismatch fails the commit with
///    `StaleExpectation` carrying the first failing expectation, and
///    nothing is applied.
/// 5. SQLite specifics: every commit opens with `BEGIN IMMEDIATE`; a
///    commit whose writer lease was lost fails with `Faulted` and applies
///    nothing; the branch index is maintained per pi §2.6.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(result) = storage.commit(store, tx.Tx(writes:, expected: []))
/// // -> CommitResult(first_seq: 1, seqs: [1, 2], ts: 1000)
/// ```
///
pub fn commit(
  storage: Storage(handle),
  tx: Tx,
) -> Result(CommitResult, CommitError) {
  storage.commit(storage.handle, tx)
}

/// Batch-fetches entries by id. Ids not present in the session are simply
/// absent from the returned dict — a missing id is not an error, because
/// callers (recovery, tree views) probe with candidate id sets.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(found) = storage.get_entries(store, [id_one, id_two])
/// // -> dict with the subset of ids that exist
/// ```
///
pub fn get_entries(
  storage: Storage(handle),
  ids: List(EntryId),
) -> Result(Dict(EntryId, Entry), StorageError) {
  storage.get_entries(storage.handle, ids)
}

/// Reads one register cell. Returns `None` when the cell does not exist —
/// absence is data, not an error (rule 3: a deleted cell is
/// indistinguishable from one never set).
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(Some(cell)) =
///   storage.get_register(store, register.StrandLeaf, "main")
/// ```
///
pub fn get_register(
  storage: Storage(handle),
  ns: RegisterNs,
  key: String,
) -> Result(Option(Register), StorageError) {
  storage.get_register(storage.handle, ns, key)
}

/// Lists a namespace's cells in key-ascending order, optionally restricted
/// to keys with the given prefix (pi's `scanValues`: inventory and cleanup
/// reads, never a cross-namespace dump).
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(cells) =
///   storage.list_registers(store, register.OpToolArgs, Some(op_id <> ":"))
/// ```
///
pub fn list_registers(
  storage: Storage(handle),
  ns: RegisterNs,
  key_prefix: Option(String),
) -> Result(List(#(String, Register)), StorageError) {
  storage.list_registers(storage.handle, ns, key_prefix)
}

/// Runs a branch query: the root path of `q.start`, ordered, truncated at
/// the first stop match, filtered, and paged — see `BranchScan` for the
/// exact pipeline. Backends must serve this from an index or in-memory
/// walk, never an unordered table scan (rule 5: the SQLite plan is
/// asserted in CI).
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(recent) =
///   storage.scan_branch(store, storage.branch_scan(from: leaf))
/// ```
///
pub fn scan_branch(
  storage: Storage(handle),
  q: BranchScan,
) -> Result(List(Entry), StorageError) {
  storage.scan_branch(storage.handle, q)
}

/// Runs a session-wide entry inventory scan in seq order.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(all) = storage.scan_entries(store, storage.entry_scan())
/// ```
///
pub fn scan_entries(
  storage: Storage(handle),
  q: EntryScan,
) -> Result(List(Entry), StorageError) {
  storage.scan_entries(storage.handle, q)
}

/// Reads usage-ledger rows in seq order. A consumer that persists the
/// greatest seq it applied catches up after downtime with
/// `from_seq: Some(seq + 1)`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(rows) = storage.scan_usage(store, storage.usage_scan())
/// ```
///
pub fn scan_usage(
  storage: Storage(handle),
  q: UsageScan,
) -> Result(List(UsageRow), StorageError) {
  storage.scan_usage(storage.handle, q)
}

/// Reads the maintained stats projection. After every commit it equals the
/// ledger sum and message-entry count (see `SessionStats`).
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(stats) = storage.stats(store)
/// ```
///
pub fn stats(storage: Storage(handle)) -> Result(SessionStats, StorageError) {
  storage.stats(storage.handle)
}

/// Closes the handle: releases backend resources (and, for SQLite, the
/// writer lease). Idempotent — closing a closed handle returns `Ok(Nil)`;
/// every other operation on a closed handle returns `HandleClosed`. The
/// shipped backends keep their (idle) actor process alive after close so
/// late callers get an error value rather than a crashed call; the owning
/// supervisor reclaims the process.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(Nil) = storage.close(store)
/// assert storage.close(store) == Ok(Nil)
/// ```
///
pub fn close(storage: Storage(handle)) -> Result(Nil, StorageError) {
  storage.close(storage.handle)
}

// --- scan constructors ---------------------------------------------------

/// A branch scan with the default settings: newest first, no stop, no
/// filter, no cursor, no limit. Adjust fields with record-update syntax or
/// the setters below.
///
/// ## Examples
///
/// ```gleam
/// let q = storage.branch_scan(from: leaf) |> storage.branch_limit(50)
/// ```
///
pub fn branch_scan(from start: EntryId) -> BranchScan {
  BranchScan(
    start:,
    stop_at_kind: None,
    stop_at_id: None,
    kind: None,
    custom_type: None,
    order: NewestFirst,
    limit: None,
    cursor: None,
  )
}

/// Sets the inclusive kind stop of a branch scan.
///
/// ## Examples
///
/// ```gleam
/// let q =
///   storage.branch_scan(from: leaf)
///   |> storage.branch_stop_at_kind(storage.Compaction)
/// ```
///
pub fn branch_stop_at_kind(q: BranchScan, kind: EntryKind) -> BranchScan {
  BranchScan(..q, stop_at_kind: Some(kind))
}

/// Sets the inclusive id stop of a branch scan.
///
/// ## Examples
///
/// ```gleam
/// let q = storage.branch_scan(from: leaf) |> storage.branch_stop_at_id(anchor)
/// ```
///
pub fn branch_stop_at_id(q: BranchScan, id: EntryId) -> BranchScan {
  BranchScan(..q, stop_at_id: Some(id))
}

/// Restricts a branch scan to one entry kind.
///
/// ## Examples
///
/// ```gleam
/// let q = storage.branch_scan(from: leaf) |> storage.branch_kind(storage.Message)
/// ```
///
pub fn branch_kind(q: BranchScan, kind: EntryKind) -> BranchScan {
  BranchScan(..q, kind: Some(kind))
}

/// Restricts a branch scan to custom entries with the given type name.
///
/// ## Examples
///
/// ```gleam
/// let q = storage.branch_scan(from: leaf) |> storage.branch_custom_type("note")
/// ```
///
pub fn branch_custom_type(q: BranchScan, custom_type: String) -> BranchScan {
  BranchScan(..q, custom_type: Some(custom_type))
}

/// Sets the scan direction of a branch scan.
///
/// ## Examples
///
/// ```gleam
/// let q = storage.branch_scan(from: leaf) |> storage.branch_order(storage.OldestFirst)
/// ```
///
pub fn branch_order(q: BranchScan, order: ScanOrder) -> BranchScan {
  BranchScan(..q, order:)
}

/// Caps the number of rows a branch scan returns. A limit of zero or
/// below returns no rows.
///
/// ## Examples
///
/// ```gleam
/// let q = storage.branch_scan(from: leaf) |> storage.branch_limit(50)
/// ```
///
pub fn branch_limit(q: BranchScan, limit: Int) -> BranchScan {
  BranchScan(..q, limit: Some(limit))
}

/// Sets the exclusive seq cursor of a branch scan (`NewestFirst` retains
/// `seq < cursor`; `OldestFirst` retains `seq > cursor`).
///
/// ## Examples
///
/// ```gleam
/// let q = storage.branch_scan(from: leaf) |> storage.branch_cursor(last_seq)
/// ```
///
pub fn branch_cursor(q: BranchScan, cursor: Seq) -> BranchScan {
  BranchScan(..q, cursor: Some(cursor))
}

/// An entry scan with the default settings: oldest first, whole session,
/// no filter, no limit.
///
/// ## Examples
///
/// ```gleam
/// let q = storage.entry_scan() |> storage.entry_kind(storage.Compaction)
/// ```
///
pub fn entry_scan() -> EntryScan {
  EntryScan(
    kind: None,
    custom_type: None,
    from_seq: None,
    to_seq: None,
    order: OldestFirst,
    limit: None,
  )
}

/// Restricts an entry scan to one entry kind.
///
/// ## Examples
///
/// ```gleam
/// let q = storage.entry_scan() |> storage.entry_kind(storage.Custom)
/// ```
///
pub fn entry_kind(q: EntryScan, kind: EntryKind) -> EntryScan {
  EntryScan(..q, kind: Some(kind))
}

/// Restricts an entry scan to custom entries with the given type name.
///
/// ## Examples
///
/// ```gleam
/// let q = storage.entry_scan() |> storage.entry_custom_type("note")
/// ```
///
pub fn entry_custom_type(q: EntryScan, custom_type: String) -> EntryScan {
  EntryScan(..q, custom_type: Some(custom_type))
}

/// Bounds an entry scan to `from_seq <= seq <= to_seq` (either side
/// optional; this setter sets both).
///
/// ## Examples
///
/// ```gleam
/// let q = storage.entry_scan() |> storage.entry_seq_range(Some(10), Some(20))
/// ```
///
pub fn entry_seq_range(
  q: EntryScan,
  from_seq: Option(Seq),
  to_seq: Option(Seq),
) -> EntryScan {
  EntryScan(..q, from_seq:, to_seq:)
}

/// Sets the scan direction of an entry scan.
///
/// ## Examples
///
/// ```gleam
/// let q = storage.entry_scan() |> storage.entry_order(storage.NewestFirst)
/// ```
///
pub fn entry_order(q: EntryScan, order: ScanOrder) -> EntryScan {
  EntryScan(..q, order:)
}

/// Caps the number of rows an entry scan returns. A limit of zero or
/// below returns no rows.
///
/// ## Examples
///
/// ```gleam
/// let q = storage.entry_scan() |> storage.entry_limit(100)
/// ```
///
pub fn entry_limit(q: EntryScan, limit: Int) -> EntryScan {
  EntryScan(..q, limit: Some(limit))
}

/// A usage scan with the default settings: oldest first, whole ledger, no
/// limit.
///
/// ## Examples
///
/// ```gleam
/// let q = storage.usage_scan() |> storage.usage_limit(100)
/// ```
///
pub fn usage_scan() -> UsageScan {
  UsageScan(from_seq: None, to_seq: None, order: OldestFirst, limit: None)
}

/// Bounds a usage scan to `from_seq <= seq <= to_seq` (either side
/// optional; this setter sets both).
///
/// ## Examples
///
/// ```gleam
/// let q = storage.usage_scan() |> storage.usage_seq_range(Some(10), None)
/// ```
///
pub fn usage_seq_range(
  q: UsageScan,
  from_seq: Option(Seq),
  to_seq: Option(Seq),
) -> UsageScan {
  UsageScan(..q, from_seq:, to_seq:)
}

/// Sets the scan direction of a usage scan.
///
/// ## Examples
///
/// ```gleam
/// let q = storage.usage_scan() |> storage.usage_order(storage.NewestFirst)
/// ```
///
pub fn usage_order(q: UsageScan, order: ScanOrder) -> UsageScan {
  UsageScan(..q, order:)
}

/// Caps the number of rows a usage scan returns. A limit of zero or
/// below returns no rows.
///
/// ## Examples
///
/// ```gleam
/// let q = storage.usage_scan() |> storage.usage_limit(100)
/// ```
///
pub fn usage_limit(q: UsageScan, limit: Int) -> UsageScan {
  UsageScan(..q, limit: Some(limit))
}

// --- shared entry helpers ------------------------------------------------

/// The structural kind of an entry.
///
/// ## Examples
///
/// ```gleam
/// assert storage.kind_of(message_entry) == storage.Message
/// ```
///
pub fn kind_of(entry: Entry) -> EntryKind {
  case entry {
    MessageEntry(..) -> Message
    CompactionEntry(..) -> Compaction
    BranchSummaryEntry(..) -> BranchSummary
    CustomEntry(..) -> Custom
  }
}

/// The persisted text tag of an entry kind, shared by the SQLite `type`
/// column and the wire codecs.
///
/// ## Examples
///
/// ```gleam
/// assert storage.kind_to_string(storage.BranchSummary) == "branch_summary"
/// ```
///
pub fn kind_to_string(kind: EntryKind) -> String {
  case kind {
    Message -> "message"
    Compaction -> "compaction"
    BranchSummary -> "branch_summary"
    Custom -> "custom"
  }
}

/// Parses a persisted entry-kind tag. Total: unknown tags are corruption —
/// the entry-type set is closed.
///
/// ## Examples
///
/// ```gleam
/// assert storage.parse_kind("compaction") == Ok(storage.Compaction)
/// ```
///
pub fn parse_kind(text: String) -> Result(EntryKind, CorruptionReport) {
  case text {
    "message" -> Ok(Message)
    "compaction" -> Ok(Compaction)
    "branch_summary" -> Ok(BranchSummary)
    "custom" -> Ok(Custom)
    other ->
      Error(corruption.report(
        at: "storage/storage.parse_kind",
        on: "entry type tag",
        expected: "message, compaction, branch_summary, or custom",
        context: other,
      ))
  }
}

/// Returns the entry with its placement stamped: storage calls this at
/// commit to overwrite the placeholder `seq` and `ts` carried by
/// `InsertEntry` (commit rule 2).
///
/// ## Examples
///
/// ```gleam
/// assert storage.stamp(entry, seq: 7, ts: 1000).seq == 7
/// ```
///
pub fn stamp(entry: Entry, seq seq: Seq, ts ts: Int) -> Entry {
  case entry {
    MessageEntry(..) as e -> MessageEntry(..e, seq:, ts:)
    CompactionEntry(..) as e -> CompactionEntry(..e, seq:, ts:)
    BranchSummaryEntry(..) as e -> BranchSummaryEntry(..e, seq:, ts:)
    CustomEntry(..) as e -> CustomEntry(..e, seq:, ts:)
  }
}

// --- usage aggregation ---------------------------------------------------

/// The zero usage aggregate: all counters zero, optional subsets absent,
/// all costs zero. The stats projection of an empty ledger.
///
/// ## Examples
///
/// ```gleam
/// assert storage.empty_usage().total_tokens == 0
/// ```
///
pub fn empty_usage() -> Usage {
  Usage(
    input: 0,
    output: 0,
    cache_read: 0,
    cache_write: 0,
    cache_write_1h: None,
    reasoning: None,
    total_tokens: 0,
    cost: UsageCost(
      input: 0.0,
      output: 0.0,
      cache_read: 0.0,
      cache_write: 0.0,
      total: 0.0,
    ),
  )
}

/// Field-wise usage sum, used by the stats projection. Optional subsets
/// (`cache_write_1h`, `reasoning`) stay absent while no row reports them
/// and become the sum of the rows that do.
///
/// ## Examples
///
/// ```gleam
/// assert storage.add_usage(storage.empty_usage(), row.usage) == row.usage
/// ```
///
pub fn add_usage(total: Usage, usage: Usage) -> Usage {
  Usage(
    input: total.input + usage.input,
    output: total.output + usage.output,
    cache_read: total.cache_read + usage.cache_read,
    cache_write: total.cache_write + usage.cache_write,
    cache_write_1h: add_optional(total.cache_write_1h, usage.cache_write_1h),
    reasoning: add_optional(total.reasoning, usage.reasoning),
    total_tokens: total.total_tokens + usage.total_tokens,
    cost: UsageCost(
      input: total.cost.input +. usage.cost.input,
      output: total.cost.output +. usage.cost.output,
      cache_read: total.cost.cache_read +. usage.cost.cache_read,
      cache_write: total.cost.cache_write +. usage.cost.cache_write,
      total: total.cost.total +. usage.cost.total,
    ),
  )
}

fn add_optional(left: Option(Int), right: Option(Int)) -> Option(Int) {
  case left, right {
    None, None -> None
    Some(a), None -> Some(a)
    None, Some(b) -> Some(b)
    Some(a), Some(b) -> Some(a + b)
  }
}

/// Empty session stats: no messages, zero usage.
///
/// ## Examples
///
/// ```gleam
/// assert storage.empty_stats().message_count == 0
/// ```
///
pub fn empty_stats() -> SessionStats {
  SessionStats(message_count: 0, usage: empty_usage())
}
