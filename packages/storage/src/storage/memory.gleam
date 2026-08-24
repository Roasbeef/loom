//// The Memory backend: the storage model as pure data structures.
////
//// `MemoryState` holds exactly the live state and nothing else — entries,
//// a children index for parent lookups, registers, the usage ledger, the
//// stats projection, and the next seq. Every mutation and query is a pure
//// function over it, so the conformance suite (and any future property
//// test) can drive the state directly with no process involved.
////
//// `open` wraps a `MemoryState` in an actor implementing the uniform
//// `storage/storage.Storage` interface. The actor serializes commits and
//// queries through its mailbox — "one writer, one queue" — and threads
//// the injected clock so fixture clocks behave deterministically.
//// Validation of a commit completes before any state is replaced: the
//// pure `commit` either returns a fully applied successor state or an
//// error and no state change, which is what makes all-or-none trivially
//// true here.

import core/clock.{type Clock}
import core/corruption
import core/entry.{
  type Entry, type UsageRow, BranchSummaryEntry, CompactionEntry, CustomEntry,
  MessageEntry, UsageRow,
}
import core/ids.{type EntryId, type Seq}
import core/register.{type RegisterNs}
import core/tx.{
  type CommitError, type CommitResult, type SeqExpectation, type Tx,
  CommitResult, Corruption, DeleteRegister, Expect, Faulted, InsertEntry,
  InsertUsage, SetRegister, StaleExpectation,
}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import storage/internal/branch
import storage/storage.{
  type BranchScan, type EntryScan, type Register, type SessionStats,
  type Storage, type StorageError, type UsageScan, BackendFault, CorruptRow,
  HandleClosed, NewestFirst, OldestFirst, Register, SessionStats, Storage,
  UnknownEntry,
}

/// One session's complete in-memory state. All fields are consistent with
/// each other by construction: only `new` and `commit` produce values.
pub opaque type MemoryState {
  /// Invariants: `entries` and `usage` ids are disjoint (one session-wide
  /// id namespace); `children` maps a parent id to its children in append
  /// order; every non-root entry's parent exists in `entries`; `usage`
  /// rows are in ascending seq order; `next_seq` is strictly greater than
  /// every assigned seq; `stats` equals the ledger sum and message count.
  MemoryState(
    entries: Dict(String, Entry),
    children: Dict(String, List(EntryId)),
    registers: Dict(String, Dict(String, Register)),
    usage: List(UsageRow),
    usage_ids: Dict(String, Nil),
    next_seq: Seq,
    stats: SessionStats,
  )
}

/// An empty session: no entries, no registers, an empty ledger, seqs
/// starting at 1.
///
/// ## Examples
///
/// ```gleam
/// assert memory.stats(memory.new()) == Ok(storage.empty_stats())
/// ```
///
pub fn new() -> MemoryState {
  MemoryState(
    entries: dict.new(),
    children: dict.new(),
    registers: dict.new(),
    usage: [],
    usage_ids: dict.new(),
    next_seq: 1,
    stats: storage.empty_stats(),
  )
}

// --- pure commit ---------------------------------------------------------

/// Applies one transaction, returning the successor state and the commit
/// result, or an error and (by purity) no state change. Enforces every
/// commit rule documented on `storage.commit`: CAS expectations are
/// evaluated against the pre-transaction registers before anything else;
/// writes then apply in order with strictly increasing seqs from
/// `next_seq`; a duplicate entry/usage id or a missing parent is
/// corruption. `ts` is the storage-assigned commit timestamp (Unix ms).
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(#(state, result)) =
///   memory.commit(memory.new(), tx.Tx(writes:, expected: []), ts: 1000)
/// ```
///
pub fn commit(
  state: MemoryState,
  tx: Tx,
  ts ts: Int,
) -> Result(#(MemoryState, CommitResult), CommitError) {
  use Nil <- result.try(check_expectations(state, tx.expected))
  let first_seq = state.next_seq
  use #(state, reversed_seqs) <- result.map(
    list.try_fold(over: tx.writes, from: #(state, []), with: fn(step, write) {
      apply_write(step, write, ts)
    }),
  )
  #(state, CommitResult(first_seq:, seqs: list.reverse(reversed_seqs), ts:))
}

// Rule 4: every expectation is evaluated against the pre-transaction
// register state; the first mismatch fails the whole commit.
fn check_expectations(
  state: MemoryState,
  expected: List(SeqExpectation),
) -> Result(Nil, CommitError) {
  list.try_fold(over: expected, from: Nil, with: fn(_, expectation) {
    let Expect(ns:, key:, seq:) = expectation
    let current = lookup_register(state, ns, key)
    case current, seq {
      None, None -> Ok(Nil)
      Some(register), Some(expected_seq) if register.seq == expected_seq ->
        Ok(Nil)
      _, _ -> Error(StaleExpectation(failed: expectation))
    }
  })
}

// Every write, register deletes included, consumes the next seq before
// dispatch, so seqs increase strictly across the transaction in write
// order regardless of which writes touch which store.
fn apply_write(
  step: #(MemoryState, List(Seq)),
  write: tx.Write,
  ts: Int,
) -> Result(#(MemoryState, List(Seq)), CommitError) {
  let #(state, seqs) = step
  let seq = state.next_seq
  let state = MemoryState(..state, next_seq: seq + 1)
  use state <- result.map(case write {
    InsertEntry(entry:) -> insert_entry(state, entry, seq, ts)
    InsertUsage(row:) -> insert_usage(state, row, seq)
    SetRegister(ns:, key:, value:) ->
      Ok(put_register(state, ns, key, Register(value:, seq:)))
    DeleteRegister(ns:, key:) -> Ok(drop_register(state, ns, key))
  })
  #(state, [seq, ..seqs])
}

fn insert_entry(
  state: MemoryState,
  entry: Entry,
  seq: Seq,
  ts: Int,
) -> Result(MemoryState, CommitError) {
  let id_text = ids.entry_id_to_string(entry.id)
  // Rule 2: entries and usage rows share one id namespace; an existing id
  // is corruption, not an update.
  use Nil <- result.try(check_fresh_id(state, id_text))
  // A missing parent is always corruption. Writes apply in order, so a
  // parent inserted earlier in this same transaction is already visible.
  use Nil <- result.try(case entry.parent {
    Some(parent) ->
      case dict.has_key(state.entries, ids.entry_id_to_string(parent)) {
        True -> Ok(Nil)
        False ->
          Error(
            Corruption(report: corruption.report(
              at: "storage/memory.commit",
              on: id_text,
              expected: "an existing parent entry",
              context: "parent " <> ids.entry_id_to_string(parent) <> " absent",
            )),
          )
      }
    None -> Ok(Nil)
  })
  let stamped = storage.stamp(entry, seq:, ts:)
  // Each child list is built by prepending, so insertion stays O(1); readers
  // (`children_of`) reverse it back into append order.
  let children = case entry.parent {
    Some(parent) -> {
      let parent_text = ids.entry_id_to_string(parent)
      let siblings =
        dict.get(state.children, parent_text) |> result.unwrap(or: [])
      dict.insert(state.children, parent_text, [entry.id, ..siblings])
    }
    None -> state.children
  }
  let message_count = case stamped {
    MessageEntry(..) -> state.stats.message_count + 1
    CompactionEntry(..) | BranchSummaryEntry(..) | CustomEntry(..) ->
      state.stats.message_count
  }
  Ok(
    MemoryState(
      ..state,
      entries: dict.insert(state.entries, id_text, stamped),
      children:,
      stats: SessionStats(..state.stats, message_count:),
    ),
  )
}

fn insert_usage(
  state: MemoryState,
  row: UsageRow,
  seq: Seq,
) -> Result(MemoryState, CommitError) {
  let id_text = ids.usage_id_to_string(row.id)
  use Nil <- result.try(check_fresh_id(state, id_text))
  let stamped = UsageRow(..row, seq:)
  Ok(
    MemoryState(
      ..state,
      usage: [stamped, ..state.usage],
      usage_ids: dict.insert(state.usage_ids, id_text, Nil),
      stats: SessionStats(
        ..state.stats,
        usage: storage.add_usage(state.stats.usage, row.usage),
      ),
    ),
  )
}

fn check_fresh_id(
  state: MemoryState,
  id_text: String,
) -> Result(Nil, CommitError) {
  case
    dict.has_key(state.entries, id_text)
    || dict.has_key(state.usage_ids, id_text)
  {
    False -> Ok(Nil)
    True ->
      Error(
        Corruption(report: corruption.report(
          at: "storage/memory.commit",
          on: id_text,
          expected: "a fresh id (entries and usage share one namespace)",
          context: "id already written",
        )),
      )
  }
}

fn put_register(
  state: MemoryState,
  ns: RegisterNs,
  key: String,
  cell: Register,
) -> MemoryState {
  let ns_text = register.ns_to_string(ns)
  let cells =
    dict.get(state.registers, ns_text) |> result.unwrap(or: dict.new())
  MemoryState(
    ..state,
    registers: dict.insert(
      state.registers,
      ns_text,
      dict.insert(cells, key, cell),
    ),
  )
}

fn drop_register(
  state: MemoryState,
  ns: RegisterNs,
  key: String,
) -> MemoryState {
  let ns_text = register.ns_to_string(ns)
  case dict.get(state.registers, ns_text) {
    Ok(cells) ->
      MemoryState(
        ..state,
        registers: dict.insert(
          state.registers,
          ns_text,
          dict.delete(cells, key),
        ),
      )
    Error(Nil) -> state
  }
}

fn lookup_register(
  state: MemoryState,
  ns: RegisterNs,
  key: String,
) -> Option(Register) {
  case dict.get(state.registers, register.ns_to_string(ns)) {
    Ok(cells) ->
      case dict.get(cells, key) {
        Ok(cell) -> Some(cell)
        Error(Nil) -> None
      }
    Error(Nil) -> None
  }
}

// --- pure queries --------------------------------------------------------

/// Batch-fetches entries by id; absent ids are omitted from the dict.
///
/// ## Examples
///
/// ```gleam
/// assert memory.get_entries(memory.new(), [some_id]) == Ok(dict.new())
/// ```
///
pub fn get_entries(
  state: MemoryState,
  entry_ids: List(EntryId),
) -> Result(Dict(EntryId, Entry), StorageError) {
  Ok(
    list.fold(over: entry_ids, from: dict.new(), with: fn(found, id) {
      case dict.get(state.entries, ids.entry_id_to_string(id)) {
        Ok(entry) -> dict.insert(found, id, entry)
        Error(Nil) -> found
      }
    }),
  )
}

/// Reads one register cell; `None` when absent.
///
/// ## Examples
///
/// ```gleam
/// assert memory.get_register(memory.new(), register.StrandLeaf, "main")
///   == Ok(None)
/// ```
///
pub fn get_register(
  state: MemoryState,
  ns: RegisterNs,
  key: String,
) -> Result(Option(Register), StorageError) {
  Ok(lookup_register(state, ns, key))
}

/// Lists a namespace's cells in key-ascending order, optionally prefix
/// restricted.
///
/// ## Examples
///
/// ```gleam
/// assert memory.list_registers(memory.new(), register.OpState, None) == Ok([])
/// ```
///
pub fn list_registers(
  state: MemoryState,
  ns: RegisterNs,
  key_prefix: Option(String),
) -> Result(List(#(String, Register)), StorageError) {
  let cells = case dict.get(state.registers, register.ns_to_string(ns)) {
    Ok(cells) -> dict.to_list(cells)
    Error(Nil) -> []
  }
  let matching = case key_prefix {
    Some(prefix) ->
      list.filter(cells, fn(cell) { string.starts_with(cell.0, prefix) })
    None -> cells
  }
  Ok(
    list.sort(matching, by: fn(left, right) { string.compare(left.0, right.0) }),
  )
}

/// Runs a branch query by walking parent pointers from `q.start` and
/// refining through the shared pipeline. An unknown start is
/// `UnknownEntry`; a broken parent link mid-walk is `CorruptRow` (a
/// missing parent is always corruption).
///
/// ## Examples
///
/// ```gleam
/// let assert Error(storage.UnknownEntry(_)) =
///   memory.scan_branch(memory.new(), storage.branch_scan(from: some_id))
/// ```
///
pub fn scan_branch(
  state: MemoryState,
  q: BranchScan,
) -> Result(List(Entry), StorageError) {
  use path <- result.map(root_path(state, q.start))
  let ordered = case q.order {
    NewestFirst -> path
    OldestFirst -> list.reverse(path)
  }
  branch.refine_all(q, ordered)
}

// The path from `start` toward the root, newest (start) first.
fn root_path(
  state: MemoryState,
  start: EntryId,
) -> Result(List(Entry), StorageError) {
  case dict.get(state.entries, ids.entry_id_to_string(start)) {
    Ok(entry) -> root_path_loop(state, entry, [])
    Error(Nil) -> Error(UnknownEntry(id: start))
  }
}

fn root_path_loop(
  state: MemoryState,
  entry: Entry,
  accumulator: List(Entry),
) -> Result(List(Entry), StorageError) {
  let accumulator = [entry, ..accumulator]
  case entry.parent {
    None -> Ok(list.reverse(accumulator))
    Some(parent) ->
      case dict.get(state.entries, ids.entry_id_to_string(parent)) {
        Ok(parent_entry) -> root_path_loop(state, parent_entry, accumulator)
        Error(Nil) ->
          Error(
            CorruptRow(report: corruption.report(
              at: "storage/memory.scan_branch",
              on: ids.entry_id_to_string(entry.id),
              expected: "an existing parent entry",
              context: "parent " <> ids.entry_id_to_string(parent) <> " absent",
            )),
          )
      }
  }
}

/// Session-wide entry inventory in seq order.
///
/// ## Examples
///
/// ```gleam
/// assert memory.scan_entries(memory.new(), storage.entry_scan()) == Ok([])
/// ```
///
pub fn scan_entries(
  state: MemoryState,
  q: EntryScan,
) -> Result(List(Entry), StorageError) {
  state.entries
  |> dict.values
  |> list.filter(fn(entry) {
    let kind_ok = case q.kind {
      Some(kind) -> storage.kind_of(entry) == kind
      None -> True
    }
    let custom_ok = case q.custom_type {
      Some(name) ->
        case entry {
          CustomEntry(custom_type:, ..) -> custom_type == name
          MessageEntry(..) | CompactionEntry(..) | BranchSummaryEntry(..) ->
            False
        }
      None -> True
    }
    kind_ok && custom_ok && in_seq_range(entry.seq, q.from_seq, q.to_seq)
  })
  |> sort_by_seq(fn(entry: Entry) { entry.seq }, q.order)
  |> take_limit(q.limit)
  |> Ok
}

/// Usage-ledger read in seq order.
///
/// ## Examples
///
/// ```gleam
/// assert memory.scan_usage(memory.new(), storage.usage_scan()) == Ok([])
/// ```
///
pub fn scan_usage(
  state: MemoryState,
  q: UsageScan,
) -> Result(List(UsageRow), StorageError) {
  state.usage
  |> list.filter(fn(row) { in_seq_range(row.seq, q.from_seq, q.to_seq) })
  |> sort_by_seq(fn(row: UsageRow) { row.seq }, q.order)
  |> take_limit(q.limit)
  |> Ok
}

/// The maintained stats projection; equals the ledger sum and message
/// count after every commit.
///
/// ## Examples
///
/// ```gleam
/// assert memory.stats(memory.new()) == Ok(storage.empty_stats())
/// ```
///
pub fn stats(state: MemoryState) -> Result(SessionStats, StorageError) {
  Ok(state.stats)
}

/// The children of an entry in append order — the in-memory equivalent of
/// SQLite's `ix_entry_parent` index, for the tree views WP-C builds on
/// top. `None` for the parent lists root entries.
///
/// ## Examples
///
/// ```gleam
/// assert memory.children_of(memory.new(), None) == []
/// ```
///
pub fn children_of(
  state: MemoryState,
  parent: Option(EntryId),
) -> List(EntryId) {
  case parent {
    Some(id) ->
      dict.get(state.children, ids.entry_id_to_string(id))
      |> result.unwrap(or: [])
      |> list.reverse
    None ->
      state.entries
      |> dict.values
      |> list.filter(fn(entry) { entry.parent == None })
      |> list.sort(by: fn(left, right) { int.compare(left.seq, right.seq) })
      |> list.map(fn(entry) { entry.id })
  }
}

fn in_seq_range(seq: Seq, from_seq: Option(Seq), to_seq: Option(Seq)) -> Bool {
  let from_ok = case from_seq {
    Some(bound) -> seq >= bound
    None -> True
  }
  let to_ok = case to_seq {
    Some(bound) -> seq <= bound
    None -> True
  }
  from_ok && to_ok
}

fn sort_by_seq(
  rows: List(row),
  seq_of: fn(row) -> Seq,
  scan_order: storage.ScanOrder,
) -> List(row) {
  let ascending =
    list.sort(rows, by: fn(left, right) {
      int.compare(seq_of(left), seq_of(right))
    })
  case scan_order {
    OldestFirst -> ascending
    NewestFirst -> list.reverse(ascending)
  }
}

// A non-positive limit returns no rows (the shared scan contract):
// `list.take` already yields `[]` for any `n <= 0`, matching the SQLite
// backend's clamped `LIMIT 0`.
fn take_limit(rows: List(row), limit: Option(Int)) -> List(row) {
  case limit {
    Some(n) -> list.take(from: rows, up_to: n)
    None -> rows
  }
}

// --- the actor wrapper ---------------------------------------------------

/// Messages understood by the memory storage actor. Opaque: callers go
/// through the `Storage` interface, never send these directly.
pub opaque type Message {
  /// Commit a transaction and reply with the result.
  Commit(tx: Tx, reply: Subject(Result(CommitResult, CommitError)))
  /// Batch entry fetch.
  GetEntries(
    ids: List(EntryId),
    reply: Subject(Result(Dict(EntryId, Entry), StorageError)),
  )
  /// Read one register cell.
  GetRegister(
    ns: RegisterNs,
    key: String,
    reply: Subject(Result(Option(Register), StorageError)),
  )
  /// List a namespace's cells.
  ListRegisters(
    ns: RegisterNs,
    key_prefix: Option(String),
    reply: Subject(Result(List(#(String, Register)), StorageError)),
  )
  /// Branch query.
  ScanBranch(q: BranchScan, reply: Subject(Result(List(Entry), StorageError)))
  /// Entry inventory scan.
  ScanEntries(q: EntryScan, reply: Subject(Result(List(Entry), StorageError)))
  /// Ledger read.
  ScanUsage(q: UsageScan, reply: Subject(Result(List(UsageRow), StorageError)))
  /// Stats projection read.
  Stats(reply: Subject(Result(SessionStats, StorageError)))
  /// Seal the handle. Idempotent.
  Close(reply: Subject(Result(Nil, StorageError)))
}

type ActorState {
  ActorState(state: MemoryState, clock: Clock, closed: Bool)
}

/// Opens a fresh in-memory session wrapped in an actor and returns the
/// uniform `Storage` handle. Commit timestamps come from the injected
/// clock, which the actor threads so stepping fixtures advance. Calls
/// block until the actor replies (and panic if the actor process has
/// died, which only happens if the owning supervisor killed it — the
/// storage code itself never crashes the actor).
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(store) = memory.open(clock.fixed(at: 1000))
/// ```
///
pub fn open(clock: Clock) -> Result(Storage(Subject(Message)), StorageError) {
  let started =
    actor.new(ActorState(state: new(), clock:, closed: False))
    |> actor.on_message(handle_message)
    |> actor.start
  case started {
    Ok(started) ->
      Ok(
        Storage(
          handle: started.data,
          commit: fn(handle, tx) { process.call_forever(handle, Commit(tx, _)) },
          get_entries: fn(handle, entry_ids) {
            process.call_forever(handle, GetEntries(entry_ids, _))
          },
          get_register: fn(handle, ns, key) {
            process.call_forever(handle, GetRegister(ns, key, _))
          },
          list_registers: fn(handle, ns, prefix) {
            process.call_forever(handle, ListRegisters(ns, prefix, _))
          },
          scan_branch: fn(handle, q) {
            process.call_forever(handle, ScanBranch(q, _))
          },
          scan_entries: fn(handle, q) {
            process.call_forever(handle, ScanEntries(q, _))
          },
          scan_usage: fn(handle, q) {
            process.call_forever(handle, ScanUsage(q, _))
          },
          stats: fn(handle) { process.call_forever(handle, Stats) },
          close: fn(handle) { process.call_forever(handle, Close) },
        ),
      )
    Error(error) ->
      Error(BackendFault(
        reason: "memory storage actor failed to start: "
        <> start_error_reason(error),
      ))
  }
}

fn start_error_reason(error: actor.StartError) -> String {
  case error {
    actor.InitTimeout -> "initialisation timeout"
    actor.InitFailed(reason) -> reason
    actor.InitExited(_) -> "initialiser exited"
  }
}

fn handle_message(
  actor_state: ActorState,
  message: Message,
) -> actor.Next(ActorState, Message) {
  case message, actor_state.closed {
    Close(reply:), _ -> {
      process.send(reply, Ok(Nil))
      actor.continue(ActorState(..actor_state, closed: True))
    }
    Commit(reply:, ..), True -> {
      process.send(reply, Error(Faulted(reason: "storage handle closed")))
      actor.continue(actor_state)
    }
    GetEntries(reply:, ..), True -> {
      process.send(reply, Error(HandleClosed))
      actor.continue(actor_state)
    }
    GetRegister(reply:, ..), True -> {
      process.send(reply, Error(HandleClosed))
      actor.continue(actor_state)
    }
    ListRegisters(reply:, ..), True -> {
      process.send(reply, Error(HandleClosed))
      actor.continue(actor_state)
    }
    ScanBranch(reply:, ..), True -> {
      process.send(reply, Error(HandleClosed))
      actor.continue(actor_state)
    }
    ScanEntries(reply:, ..), True -> {
      process.send(reply, Error(HandleClosed))
      actor.continue(actor_state)
    }
    ScanUsage(reply:, ..), True -> {
      process.send(reply, Error(HandleClosed))
      actor.continue(actor_state)
    }
    Stats(reply:), True -> {
      process.send(reply, Error(HandleClosed))
      actor.continue(actor_state)
    }
    Commit(tx:, reply:), False -> {
      let #(now, clock) = clock.read(actor_state.clock)
      case commit(actor_state.state, tx, ts: now) {
        Ok(#(state, commit_result)) -> {
          process.send(reply, Ok(commit_result))
          actor.continue(ActorState(..actor_state, state:, clock:))
        }
        Error(error) -> {
          process.send(reply, Error(error))
          actor.continue(ActorState(..actor_state, clock:))
        }
      }
    }
    GetEntries(ids: entry_ids, reply:), False -> {
      process.send(reply, get_entries(actor_state.state, entry_ids))
      actor.continue(actor_state)
    }
    GetRegister(ns:, key:, reply:), False -> {
      process.send(reply, get_register(actor_state.state, ns, key))
      actor.continue(actor_state)
    }
    ListRegisters(ns:, key_prefix:, reply:), False -> {
      process.send(reply, list_registers(actor_state.state, ns, key_prefix))
      actor.continue(actor_state)
    }
    ScanBranch(q:, reply:), False -> {
      process.send(reply, scan_branch(actor_state.state, q))
      actor.continue(actor_state)
    }
    ScanEntries(q:, reply:), False -> {
      process.send(reply, scan_entries(actor_state.state, q))
      actor.continue(actor_state)
    }
    ScanUsage(q:, reply:), False -> {
      process.send(reply, scan_usage(actor_state.state, q))
      actor.continue(actor_state)
    }
    Stats(reply:), False -> {
      process.send(reply, stats(actor_state.state))
      actor.continue(actor_state)
    }
  }
}
