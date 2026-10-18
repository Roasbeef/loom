//// The session store, memory against SQLite, as a differential stateful
//// property.
////
//// `storage/memory` says in its own module doc that it exists so a property
//// test can drive the storage model directly. This is that test. `statem`
//// generates sequences of the operations both backends implement (commits
//// with entries, usage rows, register writes and compare-and-set guards,
//// deliberately failing commits, branch, entry and usage scans, register
//// reads, and a close-and-reopen of the database file) and runs each against
//// a fresh SQLite file. The pure `MemoryState`, threaded beside the real
//// handle inside the system under test, answers every command first; the
//// SQLite answer must equal it.
////
//// Equality with the model is not the only thing checked, because two
//// backends can share a bug. Each step also states the rules of the commit
//// contract from first principles, under a tag of its own: a failed commit
//// applies nothing, CAS is judged before any write, seqs rise strictly and
//// one per write, a register cell holds the last write's value at that
//// write's seq, the stats projection equals the usage ledger's sum, and a
//// branch scan with no filter is exactly the ancestor chain. The model
//// kept by `statem` stays coarse (how many entries are committed), so a
//// command names things by an index taken modulo that count and any
//// sub-sequence of a failing run is still a run.
////
//// ## Flow
////
//// `store_spec` → `execute` → `run_command` → `commit_step` → `audit`
////
//// 1. `execute` runs one command through `run_command`, then `audit`.
//// 2. `commit_step` builds the transaction from the command's items, sends
////    it to both backends and compares the three answers: model, SQLite and
////    the contract's own prediction.
//// 3. `audit` compares the whole observable state of the two backends, which
////    is what catches a failed commit that left something behind.
////
//// The seed and counts are fixed constants, so the gate is deterministic.

import core/clock
import core/entry.{type Entry, type UsageRow}
import core/ids.{type EntryId}
import core/json
import core/register.{type RegisterNs}
import core/tx.{
  type CommitError, type CommitResult, type Tx, type Write, Corruption,
  DeleteRegister, Expect, InsertEntry, InsertUsage, SetRegister,
  StaleExpectation, Tx,
}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import qcheck
import statem
import storage/memory.{type MemoryState}
import storage/sqlite
import storage/storage.{type Storage}
import support/fixtures

/// The number of random sequences the property runs. Each opens a database
/// file, so the count stays modest.
const sequence_count = 30

/// The longest sequence one run may draw. Shrinking re-executes candidates
/// against fresh files, so the bound is moderate.
const sequence_length = 30

/// The seed every sequence derives from. Fixed, so the gate is the same gate
/// on every machine.
const sequence_seed = 4217

/// The timestamp both backends stamp on every commit, so that a commit's
/// answer, which carries it, can be compared whole.
const commit_ts = 10_000

/// Where a new entry hangs, as an index rather than an id.
type Link {
  /// No parent: a new root.
  Root

  /// The newest entry there is, committed or earlier in this batch, which
  /// is what makes a branch deep rather than a fan of roots. With no entry
  /// yet it reads as `Root`.
  Latest

  /// The committed entry with this index (taken modulo the count). A store
  /// with no entries yet reads it as `Root`.
  Existing(index: Int)

  /// The entry this batch inserted at this position (modulo the entries
  /// inserted so far), which only a transaction applying writes in order can
  /// honour. A batch with no earlier entry reads it as `Root`.
  InBatch(index: Int)
}

/// What kind of entry a commit item inserts.
type Shape {
  MessageShape
  CompactionShape
  CustomShape(tag: Int)
}

/// One write of a commit.
type Item {
  AddEntry(shape: Shape, parent: Link)
  AddUsage(attach: Link, input: Int)
  Set(ns: RegisterNs, slot: Int, value: Int)
  Delete(ns: RegisterNs, slot: Int)
}

/// Whether a CAS guard names the cell's real seq.
type Freshness {
  /// The seq the cell holds now, or `None` when the cell is absent.
  Current

  /// A seq the cell does not hold: `None` for a present cell, a made-up seq
  /// for an absent one.
  Stale
}

/// One compare-and-set guard of a commit, on a register cell.
type Guard {
  Guard(ns: RegisterNs, slot: Int, freshness: Freshness)
}

/// A way a commit is made to fail, after its items.
type Fault {
  /// Nothing extra: the commit is valid.
  Clean

  /// A final write inserts a copy of the committed entry with this index
  /// (modulo the count), which is corruption.
  Duplicate(index: Int)

  /// A final write inserts an entry whose parent was never committed.
  Orphan
}

/// Which entry a branch scan starts from.
type Tip {
  /// The newest committed entry, the end of the deepest branch.
  Newest

  /// The committed entry with this index (modulo the count).
  Known(index: Int)

  /// An id the store has never seen.
  Unknown
}

/// Where a branch scan stops.
type Stop {
  NoStop
  StopKind(kind: storage.EntryKind)

  /// At the committed entry with this index, which may be off the path.
  StopId(index: Int)
}

/// A seq bound or cursor, written so that it can land on a boundary. A
/// random integer almost never equals the seq of an entry on a short path, and
/// off-by-one errors live exactly there.
type Mark {
  /// This seq, whether or not anything holds it.
  Raw(seq: Int)

  /// The seq of the committed entry with this index (modulo the count), moved
  /// by `shift`: below it, on it, or just past it. Before any entry exists it
  /// is the shift alone.
  SeqOf(index: Int, shift: Int)
}

/// One store operation, symbolic.
type Command {
  Commit(items: List(Item), guards: List(Guard), fault: Fault)
  ScanBranch(
    tip: Tip,
    order: storage.ScanOrder,
    stop: Stop,
    kind: Option(storage.EntryKind),
    custom_tag: Option(Int),
    limit: Option(Int),
    cursor: Option(Mark),
  )
  ScanEntries(
    kind: Option(storage.EntryKind),
    custom_tag: Option(Int),
    from_seq: Option(Mark),
    to_seq: Option(Mark),
    order: storage.ScanOrder,
    limit: Option(Int),
  )
  ScanUsage(
    from_seq: Option(Mark),
    to_seq: Option(Mark),
    order: storage.ScanOrder,
    limit: Option(Int),
  )
  GetEntries(picks: List(Int))
  GetRegister(ns: RegisterNs, slot: Int)
  ListRegisters(ns: RegisterNs, prefix: Option(String))

  /// Close the handle and open the same file again.
  Reopen
}

/// The coarse model `statem` keeps: how many entries are committed. It is
/// all the generator and the preconditions need, and it moves only when a
/// commit is valid by construction.
type Model {
  Model(entries: Int)
}

/// The system under test: the real store and everything the oracle keeps
/// beside it. The oracle state is a value, so each step returns a new one.
type Sut {
  Sut(
    store: Storage(Subject(sqlite.Message)),
    path: String,
    mem: MemoryState,
    ctx: fixtures.Ctx,
    ids: Dict(Int, EntryId),
    parents: Dict(Int, Option(Int)),
    count: Int,
    high: Int,
  )
}

/// A commit's answer reduced to what the backends must agree on, with the
/// corruption report's text folded away.
type Outcome {
  Committed(result: CommitResult)
  StaleAt(failed: tx.SeqExpectation)
  Corrupt
  Failed(reason: String)
}

fn fail(tag: String, detail: String) -> Result(a, statem.Violation) {
  Error(statem.Violation(tag:, detail:))
}

// Both answers must be equal, whatever their type. The label says which read
// this is, and the tag says which family of the contract it belongs to.
fn agree(
  tag: String,
  label: String,
  model: a,
  real: a,
) -> Result(Nil, statem.Violation) {
  case model == real {
    True -> Ok(Nil)
    False ->
      fail(
        tag,
        label
          <> ": expected "
          <> string.inspect(model)
          <> ", SQLite answered "
          <> string.inspect(real),
      )
  }
}

fn key_of(slot: Int) -> String {
  case slot % 4 {
    0 -> "ka0"
    1 -> "ka1"
    2 -> "kb0"
    _ -> "kb1"
  }
}

fn cell_value(value: Int) -> register.RegisterValue {
  register.value(json.Int(value))
}

fn open_store(path: String) -> Storage(Subject(sqlite.Message)) {
  let assert Ok(store) =
    sqlite.open(
      sqlite.config(path:, owner: "writer"),
      clock.fixed(at: commit_ts),
    )
    as "the session database opens"
  store
}

// --- resolving a command against the oracle ---------------------------------

// A commit under construction: entries are minted from the threaded context,
// so the same entry values go to both backends, and the id and parent tables
// grow as items resolve so a later item can name an earlier one.
type Draft {
  Draft(
    ctx: fixtures.Ctx,
    ids: Dict(Int, EntryId),
    parents: Dict(Int, Option(Int)),
    next: Int,
    writes: List(Write),
  )
}

fn resolve(sut: Sut, draft: Draft, link: Link) -> Option(Int) {
  let batch = draft.next - sut.count
  case link {
    Root -> None
    Latest if draft.next > 0 -> Some(draft.next - 1)
    Latest -> None
    Existing(index:) if sut.count > 0 -> Some(index % sut.count)
    Existing(..) -> None
    InBatch(index:) if batch > 0 -> Some(sut.count + index % batch)
    InBatch(..) -> None
  }
}

fn id_at(draft: Draft, index: Option(Int)) -> Option(EntryId) {
  option.then(index, fn(i) { dict.get(draft.ids, i) |> option.from_result })
}

fn add_item(sut: Sut, draft: Draft, item: Item) -> Draft {
  case item {
    AddEntry(shape:, parent:) -> {
      let parent_index = resolve(sut, draft, parent)
      let parent_id = id_at(draft, parent_index)
      let #(made, ctx) = case shape {
        MessageShape -> fixtures.message_entry(draft.ctx, parent_id, "m")
        CompactionShape -> fixtures.compaction_entry(draft.ctx, parent_id, "c")
        CustomShape(tag:) ->
          fixtures.custom_entry(draft.ctx, parent_id, tag_name(tag))
      }
      Draft(
        ctx:,
        ids: dict.insert(draft.ids, draft.next, made.id),
        parents: dict.insert(draft.parents, draft.next, parent_index),
        next: draft.next + 1,
        writes: [InsertEntry(made), ..draft.writes],
      )
    }

    AddUsage(attach:, input:) -> {
      let attached = id_at(draft, resolve(sut, draft, attach))
      let #(row, ctx) = fixtures.usage_row(draft.ctx, attached, input)
      Draft(..draft, ctx:, writes: [InsertUsage(row), ..draft.writes])
    }

    Set(ns:, slot:, value:) ->
      Draft(..draft, writes: [
        SetRegister(ns, key_of(slot), cell_value(value)),
        ..draft.writes
      ])

    Delete(ns:, slot:) ->
      Draft(..draft, writes: [DeleteRegister(ns, key_of(slot)), ..draft.writes])
  }
}

fn tag_name(tag: Int) -> String {
  case tag % 2 {
    0 -> "alpha"
    _ -> "beta"
  }
}

// The copy of a committed entry that a duplicate insert sends: the same id
// under any placeholder seq, taken from the model's own copy.
fn duplicate_of(sut: Sut, index: Int) -> List(Write) {
  let found =
    dict.get(sut.ids, index % int.max(sut.count, 1))
    |> result.try(fn(id) {
      case memory.get_entries(sut.mem, [id]) {
        Ok(entries) -> dict.get(entries, id)
        Error(_) -> Error(Nil)
      }
    })
  case found {
    Ok(copy) -> [InsertEntry(copy)]
    Error(Nil) -> []
  }
}

fn orphan_write(draft: Draft) -> #(List(Write), fixtures.Ctx) {
  let #(missing, ctx) = fixtures.mint(draft.ctx)
  let #(stray, ctx) = fixtures.message_entry(ctx, Some(missing), "orphan")
  #([InsertEntry(stray)], ctx)
}

// The guard as the expectation it sends, read against the model's registers.
fn expectation(sut: Sut, guard: Guard) -> tx.SeqExpectation {
  let current = case
    memory.get_register(sut.mem, guard.ns, key_of(guard.slot))
  {
    Ok(Some(cell)) -> Some(cell.seq)
    Ok(None) | Error(_) -> None
  }
  let seq = case guard.freshness, current {
    Current, _ -> current
    Stale, Some(_) -> None
    Stale, None -> Some(1)
  }
  Expect(ns: guard.ns, key: key_of(guard.slot), seq:)
}

// --- the commit step --------------------------------------------------------

fn outcome(answer: Result(CommitResult, CommitError)) -> Outcome {
  case answer {
    Ok(result) -> Committed(result)
    Error(StaleExpectation(failed:)) -> StaleAt(failed)
    Error(Corruption(_)) -> Corrupt
    Error(other) -> Failed(string.inspect(other))
  }
}

// What the contract says before any backend is asked: the first stale guard
// is named, else a fault is corruption, else the commit succeeds. `None`
// means success, whose seqs are checked separately.
fn predicted(stale: List(tx.SeqExpectation), fault: Fault) -> Option(Outcome) {
  case stale, fault {
    [first, ..], _ -> Some(StaleAt(first))
    [], Clean -> None
    [], Duplicate(_) | [], Orphan -> Some(Corrupt)
  }
}

fn build_commit(
  sut: Sut,
  items: List(Item),
  fault: Fault,
  guards: List(Guard),
) -> #(Tx, Draft) {
  let start =
    Draft(
      ctx: sut.ctx,
      ids: sut.ids,
      parents: sut.parents,
      next: sut.count,
      writes: [],
    )
  let drafted =
    list.fold(items, start, fn(draft, item) { add_item(sut, draft, item) })
  let #(extra, ctx) = case fault {
    Clean -> #([], drafted.ctx)
    Duplicate(index:) -> #(duplicate_of(sut, index), drafted.ctx)
    Orphan -> orphan_write(drafted)
  }
  let drafted =
    Draft(
      ..drafted,
      ctx:,
      writes: list.reverse(list.append(extra, drafted.writes)),
    )
  let expected = list.map(guards, expectation(sut, _))
  #(Tx(writes: drafted.writes, expected:), drafted)
}

fn is_stale(guard: Guard) -> Bool {
  guard.freshness == Stale
}

fn commit_step(
  sut: Sut,
  items: List(Item),
  guards: List(Guard),
  fault: Fault,
) -> Result(Sut, statem.Violation) {
  let #(transaction, drafted) = build_commit(sut, items, fault, guards)
  let stale = list.filter(guards, is_stale) |> list.map(expectation(sut, _))
  let modelled = memory.commit(sut.mem, transaction, ts: commit_ts)
  let real = storage.commit(sut.store, transaction)
  let model_outcome = outcome(result.map(modelled, fn(done) { done.1 }))
  use Nil <- result.try(check_cas_order(stale, outcome(real)))
  use Nil <- result.try(agree(
    "commit-diverges",
    "commit",
    model_outcome,
    outcome(real),
  ))
  case predicted(stale, fault), modelled {
    None, Ok(#(next_mem, done)) -> {
      use Nil <- result.try(check_seqs(sut, transaction.writes, done))
      let advanced =
        Sut(
          ..sut,
          mem: next_mem,
          ctx: drafted.ctx,
          ids: drafted.ids,
          parents: drafted.parents,
          count: drafted.next,
          high: list.fold(done.seqs, sut.high, int.max),
        )
      use Nil <- result.try(check_registers_written(
        advanced,
        transaction.writes,
        done,
      ))
      Ok(advanced)
    }
    None, Error(_) ->
      fail(
        "commit-rule",
        "a valid commit was refused: " <> string.inspect(real),
      )
    Some(expected), _ ->
      agree("commit-rule", "a faulty commit", expected, outcome(real))
      |> result.replace(Sut(..sut, ctx: drafted.ctx))
  }
}

// CAS is evaluated before anything applies: a transaction with a stale guard
// must name the first one, even when a later write is also bad. Named on its
// own so shrinking one failure never slides into the other.
fn check_cas_order(
  stale: List(tx.SeqExpectation),
  observed: Outcome,
) -> Result(Nil, statem.Violation) {
  case stale {
    [] -> Ok(Nil)
    [first, ..] ->
      case observed == StaleAt(first) {
        True -> Ok(Nil)
        False ->
          fail(
            "cas-order",
            "the first stale guard is "
              <> string.inspect(first)
              <> ", the store answered "
              <> string.inspect(observed),
          )
      }
  }
}

// One seq per write, strictly increasing within the commit and above every
// seq an earlier commit assigned; gaps are legal, so only order is stated.
fn check_seqs(
  sut: Sut,
  writes: List(Write),
  done: CommitResult,
) -> Result(Nil, statem.Violation) {
  let rising = case done.seqs {
    [] -> True
    [first, ..rest] ->
      first > sut.high
      && first == done.first_seq
      && list.zip([first, ..rest], rest)
      |> list.all(fn(pair) { pair.1 > pair.0 })
  }
  case rising && list.length(done.seqs) == list.length(writes) {
    True -> Ok(Nil)
    False ->
      fail(
        "seq-order",
        "seqs "
          <> string.inspect(done.seqs)
          <> " after high-water "
          <> int.to_string(sut.high)
          <> " for "
          <> int.to_string(list.length(writes))
          <> " writes",
      )
  }
}

// Set replaces and delete removes, with no history: the cell a key ends in
// is its last write's, at that write's seq. Read from SQLite alone, because
// the model is checked against it everywhere else.
fn check_registers_written(
  sut: Sut,
  writes: List(Write),
  done: CommitResult,
) -> Result(Nil, statem.Violation) {
  let last =
    list.zip(writes, done.seqs)
    |> list.fold(dict.new(), fn(cells, pair) {
      case pair.0 {
        SetRegister(ns:, key:, value:) ->
          dict.insert(cells, #(register.ns_to_string(ns), key), #(
            ns,
            key,
            Some(storage.Register(value:, seq: pair.1)),
          ))
        DeleteRegister(ns:, key:) ->
          dict.insert(cells, #(register.ns_to_string(ns), key), #(ns, key, None))
        InsertEntry(_) | InsertUsage(_) -> cells
      }
    })
  list.try_each(dict.values(last), fn(cell) {
    let #(ns, key, expected) = cell
    agree(
      "register-last-write",
      "register " <> register.ns_to_string(ns) <> "/" <> key,
      Ok(expected),
      storage.get_register(sut.store, ns, key),
    )
  })
}

// --- reads ------------------------------------------------------------------

// The seq a mark names, read from the model's own copy of the entry.
fn seq_at(sut: Sut, mark: Mark) -> Int {
  case mark {
    Raw(seq:) -> seq
    SeqOf(index:, shift:) -> {
      let held =
        id_of_index(sut, index)
        |> option.to_result(Nil)
        |> result.try(fn(id) {
          memory.get_entries(sut.mem, [id]) |> result.replace_error(Nil)
        })
        |> result.try(fn(found) { list.first(dict.values(found)) })
      case held {
        Ok(found) -> {
          let found: Entry = found
          found.seq + shift
        }
        Error(Nil) -> shift
      }
    }
  }
}

fn id_of_index(sut: Sut, index: Int) -> Option(EntryId) {
  case sut.count {
    0 -> None
    count -> dict.get(sut.ids, index % count) |> option.from_result
  }
}

// The ancestor chain of a committed entry, newest first, from the oracle's
// own parent table and not from either backend.
fn chain_from(sut: Sut, index: Int) -> List(EntryId) {
  let here = dict.get(sut.ids, index) |> result.map(fn(id) { [id] })
  let above = case dict.get(sut.parents, index) {
    Ok(Some(parent)) -> chain_from(sut, parent)
    Ok(None) | Error(Nil) -> []
  }
  result.unwrap(here, []) |> list.append(above)
}

fn branch_query(
  sut: Sut,
  start: EntryId,
  stop: Stop,
  order: storage.ScanOrder,
  kind: Option(storage.EntryKind),
  custom_tag: Option(Int),
  limit: Option(Int),
  cursor: Option(Int),
) -> storage.BranchScan {
  let query =
    storage.BranchScan(..storage.branch_scan(from: start), order:, kind:)
  let query = case stop {
    NoStop -> query
    StopKind(kind: stopping) -> storage.branch_stop_at_kind(query, stopping)
    StopId(index:) ->
      case id_of_index(sut, index) {
        Some(id) -> storage.branch_stop_at_id(query, id)
        None -> query
      }
  }
  storage.BranchScan(
    ..query,
    custom_type: option.map(custom_tag, tag_name),
    limit:,
    cursor:,
  )
}

fn scan_branch_step(
  sut: Sut,
  tip: Tip,
  stop: Stop,
  order: storage.ScanOrder,
  kind: Option(storage.EntryKind),
  custom_tag: Option(Int),
  limit: Option(Int),
  cursor: Option(Int),
) -> Result(Nil, statem.Violation) {
  let start_index = case tip {
    Newest if sut.count > 0 -> Some(sut.count - 1)
    Known(index:) if sut.count > 0 -> Some(index % sut.count)
    Newest | Known(_) | Unknown -> None
  }
  let start_id = case option.then(start_index, id_of_index(sut, _)) {
    Some(id) -> id
    None -> fixtures.mint(sut.ctx).0
  }
  let query =
    branch_query(sut, start_id, stop, order, kind, custom_tag, limit, cursor)
  use Nil <- result.try(agree(
    "scan-diverges",
    "scan_branch " <> string.inspect(query),
    memory.scan_branch(sut.mem, query),
    storage.scan_branch(sut.store, query),
  ))
  case start_index {
    Some(index) -> check_chain(sut, index, start_id)
    None -> Ok(Nil)
  }
}

// An unfiltered scan from a tip is the chain of its ancestors, in order, and
// reaches every one however far down the branch index it lies.
fn check_chain(
  sut: Sut,
  index: Int,
  start: EntryId,
) -> Result(Nil, statem.Violation) {
  let scanned =
    storage.scan_branch(sut.store, storage.branch_scan(from: start))
    |> result.map(list.map(_, fn(found: Entry) { found.id }))
  agree(
    "branch-chain",
    "the branch from entry " <> int.to_string(index),
    Ok(chain_from(sut, index)),
    result.replace_error(scanned, Nil),
  )
}

fn scan_entries_step(
  sut: Sut,
  query: storage.EntryScan,
) -> Result(Nil, statem.Violation) {
  use Nil <- result.try(agree(
    "scan-diverges",
    "scan_entries " <> string.inspect(query),
    memory.scan_entries(sut.mem, query),
    storage.scan_entries(sut.store, query),
  ))
  use Nil <- result.try(agree(
    "scan-diverges",
    "scan_entry_heads " <> string.inspect(query),
    memory.scan_entry_heads(sut.mem, query),
    storage.scan_entry_heads(sut.store, query),
  ))
  agree(
    "heads-project-entries",
    "scan_entry_heads " <> string.inspect(query),
    storage.scan_entries(sut.store, query)
      |> result.map(list.map(_, storage.entry_head_of)),
    storage.scan_entry_heads(sut.store, query),
  )
}

fn run_command(sut: Sut, command: Command) -> Result(Sut, statem.Violation) {
  case command {
    Commit(items:, guards:, fault:) -> commit_step(sut, items, guards, fault)

    ScanBranch(tip:, order:, stop:, kind:, custom_tag:, limit:, cursor:) ->
      scan_branch_step(
        sut,
        tip,
        stop,
        order,
        kind,
        custom_tag,
        limit,
        option.map(cursor, seq_at(sut, _)),
      )
      |> result.replace(sut)

    ScanEntries(kind:, custom_tag:, from_seq:, to_seq:, order:, limit:) ->
      scan_entries_step(
        sut,
        storage.EntryScan(
          kind:,
          custom_type: option.map(custom_tag, tag_name),
          from_seq: option.map(from_seq, seq_at(sut, _)),
          to_seq: option.map(to_seq, seq_at(sut, _)),
          order:,
          limit:,
        ),
      )
      |> result.replace(sut)

    ScanUsage(from_seq:, to_seq:, order:, limit:) -> {
      let query =
        storage.UsageScan(
          from_seq: option.map(from_seq, seq_at(sut, _)),
          to_seq: option.map(to_seq, seq_at(sut, _)),
          order:,
          limit:,
        )
      agree(
        "scan-diverges",
        "scan_usage " <> string.inspect(query),
        memory.scan_usage(sut.mem, query),
        storage.scan_usage(sut.store, query),
      )
      |> result.replace(sut)
    }

    GetEntries(picks:) -> {
      let wanted =
        list.filter_map(picks, fn(i) {
          id_of_index(sut, i) |> option.to_result(Nil)
        })
      agree(
        "scan-diverges",
        "get_entries",
        memory.get_entries(sut.mem, wanted),
        storage.get_entries(sut.store, wanted),
      )
      |> result.replace(sut)
    }

    GetRegister(ns:, slot:) ->
      agree(
        "register-diverges",
        "get_register",
        memory.get_register(sut.mem, ns, key_of(slot)),
        storage.get_register(sut.store, ns, key_of(slot)),
      )
      |> result.replace(sut)

    ListRegisters(ns:, prefix:) ->
      agree(
        "register-diverges",
        "list_registers",
        memory.list_registers(sut.mem, ns, prefix),
        storage.list_registers(sut.store, ns, prefix),
      )
      |> result.replace(sut)

    Reopen -> reopen(sut)
  }
}

// Closing hands the writer lease back and reopening takes it again, so
// everything the next audit reads has come off the disk.
fn reopen(sut: Sut) -> Result(Sut, statem.Violation) {
  case storage.close(sut.store) {
    Ok(Nil) -> Ok(Sut(..sut, store: open_store(sut.path)))
    Error(error) -> fail("reopen", "close failed: " <> string.inspect(error))
  }
}

// --- the audit after every step ---------------------------------------------

// Stats come from the maintained projection, and equal the ledger they
// summarise after every commit: the usage rows summed in seq order and the
// message entries counted, both read back from SQLite.
fn check_stats(sut: Sut) -> Result(Nil, statem.Violation) {
  use Nil <- result.try(agree(
    "stats-diverge",
    "stats",
    memory.stats(sut.mem),
    storage.stats(sut.store),
  ))
  let rows = storage.scan_usage(sut.store, storage.usage_scan())
  let messages =
    storage.scan_entries(
      sut.store,
      storage.EntryScan(..storage.entry_scan(), kind: Some(storage.Message)),
    )
  case rows, messages {
    Ok(rows), Ok(messages) ->
      agree(
        "stats-ledger",
        "stats against the ledger",
        Ok(storage.SessionStats(
          message_count: list.length(messages),
          usage: list.fold(
            rows,
            storage.empty_usage(),
            fn(total, row: UsageRow) { storage.add_usage(total, row.usage) },
          ),
        )),
        storage.stats(sut.store),
      )
    Error(error), _ | _, Error(error) -> fail("read", string.inspect(error))
  }
}

fn check_inventory(sut: Sut) -> Result(Nil, statem.Violation) {
  use Nil <- result.try(agree(
    "entries-diverge",
    "every entry",
    memory.scan_entries(sut.mem, storage.entry_scan()),
    storage.scan_entries(sut.store, storage.entry_scan()),
  ))
  agree(
    "usage-diverge",
    "every usage row",
    memory.scan_usage(sut.mem, storage.usage_scan()),
    storage.scan_usage(sut.store, storage.usage_scan()),
  )
}

fn check_all_registers(sut: Sut) -> Result(Nil, statem.Violation) {
  list.try_each(register_spaces(), fn(ns) {
    list.try_each([None, Some("k"), Some("ka")], fn(prefix) {
      agree(
        "register-diverge",
        "the cells of "
          <> register.ns_to_string(ns)
          <> " under prefix "
          <> string.inspect(prefix),
        memory.list_registers(sut.mem, ns, prefix),
        storage.list_registers(sut.store, ns, prefix),
      )
    })
  })
}

fn register_spaces() -> List(RegisterNs) {
  [register.OpState, register.FactName]
}

fn audit(sut: Sut) -> Result(Nil, statem.Violation) {
  use Nil <- result.try(check_stats(sut))
  use Nil <- result.try(check_inventory(sut))
  check_all_registers(sut)
}

fn execute(
  sut: Sut,
  _model: Model,
  command: Command,
) -> Result(Sut, statem.Violation) {
  use advanced <- result.try(run_command(sut, command))
  use Nil <- result.try(audit(advanced))
  Ok(advanced)
}

// --- generation -------------------------------------------------------------

fn index() -> qcheck.Generator(Int) {
  qcheck.bounded_int(from: 0, to: 7)
}

fn slot() -> qcheck.Generator(Int) {
  qcheck.bounded_int(from: 0, to: 3)
}

fn space() -> qcheck.Generator(RegisterNs) {
  qcheck.bounded_int(from: 0, to: 1)
  |> qcheck.map(fn(n) {
    case n {
      0 -> register.OpState
      _ -> register.FactName
    }
  })
}

fn order() -> qcheck.Generator(storage.ScanOrder) {
  qcheck.bounded_int(from: 0, to: 1)
  |> qcheck.map(fn(n) {
    case n {
      0 -> storage.OldestFirst
      _ -> storage.NewestFirst
    }
  })
}

fn kind() -> qcheck.Generator(storage.EntryKind) {
  qcheck.bounded_int(from: 0, to: 3)
  |> qcheck.map(fn(n) {
    case n {
      0 -> storage.Message
      1 -> storage.Custom
      2 -> storage.Compaction
      _ -> storage.BranchSummary
    }
  })
}

// A filter is usually absent: kind, custom type and limit each cut a scan down,
// and stacked together they leave almost every scan empty, which would make
// agreement between the backends trivial.
fn sparse(
  generator: qcheck.Generator(a),
  absent absent: Int,
) -> qcheck.Generator(Option(a)) {
  qcheck.from_weighted_generators(#(absent, qcheck.return(None)), [
    #(1, qcheck.map(generator, Some)),
  ])
}

fn mark() -> qcheck.Generator(Mark) {
  qcheck.from_weighted_generators(
    #(1, qcheck.map(qcheck.bounded_int(from: 0, to: 24), Raw)),
    [
      #(3, qcheck.map2(index(), qcheck.bounded_int(from: -1, to: 1), SeqOf)),
    ],
  )
}

// A bound or cursor is absent about as often as it is present, and when it is
// present it usually sits on or beside an entry's seq.
fn bound() -> qcheck.Generator(Option(Mark)) {
  sparse(mark(), absent: 2)
}

fn limit() -> qcheck.Generator(Option(Int)) {
  sparse(qcheck.bounded_int(from: -1, to: 6), absent: 4)
}

fn link() -> qcheck.Generator(Link) {
  qcheck.from_weighted_generators(#(1, qcheck.return(Root)), [
    #(5, qcheck.return(Latest)),
    #(2, qcheck.map(index(), Existing)),
    #(2, qcheck.map(index(), InBatch)),
  ])
}

fn shape() -> qcheck.Generator(Shape) {
  qcheck.bounded_int(from: 0, to: 4)
  |> qcheck.map(fn(n) {
    case n {
      0 | 1 -> MessageShape
      2 -> CompactionShape
      _ -> CustomShape(n - 3)
    }
  })
}

fn item() -> qcheck.Generator(Item) {
  qcheck.from_weighted_generators(#(6, qcheck.map2(shape(), link(), AddEntry)), [
    #(3, qcheck.map2(link(), qcheck.bounded_int(from: 0, to: 40), AddUsage)),
    #(3, qcheck.map3(space(), slot(), qcheck.bounded_int(from: 0, to: 9), Set)),
    #(2, qcheck.map2(space(), slot(), Delete)),
  ])
}

fn guard() -> qcheck.Generator(Guard) {
  qcheck.map3(
    space(),
    slot(),
    qcheck.bounded_int(from: 0, to: 2),
    fn(ns, slot, n) {
      Guard(ns:, slot:, freshness: case n {
        0 -> Stale
        _ -> Current
      })
    },
  )
}

fn guards() -> qcheck.Generator(List(Guard)) {
  qcheck.bounded_int(from: 0, to: 9)
  |> qcheck.bind(fn(n) {
    case n < 6 {
      True -> qcheck.return([])
      False -> qcheck.fixed_length_list_from(guard(), n - 5)
    }
  })
}

fn items() -> qcheck.Generator(List(Item)) {
  qcheck.generic_list(
    elements_from: item(),
    length_from: qcheck.bounded_int(from: 0, to: 5),
  )
}

fn fault(model: Model) -> qcheck.Generator(Fault) {
  case model.entries {
    0 ->
      qcheck.from_weighted_generators(#(8, qcheck.return(Clean)), [
        #(1, qcheck.return(Orphan)),
      ])
    _ ->
      qcheck.from_weighted_generators(#(8, qcheck.return(Clean)), [
        #(1, qcheck.return(Orphan)),
        #(1, qcheck.map(index(), Duplicate)),
      ])
  }
}

fn tip() -> qcheck.Generator(Tip) {
  qcheck.from_weighted_generators(#(4, qcheck.return(Newest)), [
    #(4, qcheck.map(index(), Known)),
    #(1, qcheck.return(Unknown)),
  ])
}

fn stop() -> qcheck.Generator(Stop) {
  qcheck.from_weighted_generators(#(4, qcheck.return(NoStop)), [
    #(1, qcheck.map(kind(), StopKind)),
    #(1, qcheck.map(index(), StopId)),
  ])
}

fn prefix() -> qcheck.Generator(Option(String)) {
  qcheck.bounded_int(from: 0, to: 4)
  |> qcheck.map(fn(n) {
    case n {
      0 -> None
      1 -> Some("k")
      2 -> Some("ka")
      3 -> Some("kb1")
      _ -> Some("z")
    }
  })
}

fn custom_tag() -> qcheck.Generator(Option(Int)) {
  sparse(qcheck.bounded_int(from: 0, to: 1), absent: 4)
}

fn scan_branch_command() -> qcheck.Generator(Command) {
  qcheck.map6(
    tip(),
    order(),
    stop(),
    sparse(kind(), absent: 3),
    limit(),
    bound(),
    fn(tip, order, stop, kind, limit, cursor) {
      ScanBranch(tip:, order:, stop:, kind:, custom_tag: None, limit:, cursor:)
    },
  )
  |> qcheck.map2(custom_tag(), fn(command, tag) {
    case command {
      ScanBranch(..) -> ScanBranch(..command, custom_tag: tag)
      Commit(..)
      | ScanEntries(..)
      | ScanUsage(..)
      | GetEntries(..)
      | GetRegister(..)
      | ListRegisters(..)
      | Reopen -> command
    }
  })
}

// Commands read the model only to avoid drawing what could never run; every
// choice is an index, so deleting commands during shrinking keeps the rest
// meaningful. Weights favour commits so scans have something to read, and
// the simplest command comes first so shrinking prefers a plain commit.
fn command(model: Model) -> qcheck.Generator(Command) {
  let reads = [
    #(4, scan_branch_command()),
    #(
      1,
      qcheck.map6(
        sparse(kind(), absent: 3),
        custom_tag(),
        bound(),
        bound(),
        order(),
        limit(),
        fn(kind, custom_tag, from_seq, to_seq, order, limit) {
          ScanEntries(kind:, custom_tag:, from_seq:, to_seq:, order:, limit:)
        },
      ),
    ),
    #(
      1,
      qcheck.map4(
        bound(),
        bound(),
        order(),
        limit(),
        fn(from, to, order, limit) {
          ScanUsage(from_seq: from, to_seq: to, order:, limit:)
        },
      ),
    ),
    #(
      1,
      qcheck.generic_list(
        elements_from: index(),
        length_from: qcheck.bounded_int(from: 0, to: 4),
      )
        |> qcheck.map(GetEntries),
    ),
    #(1, qcheck.map2(space(), slot(), GetRegister)),
    #(1, qcheck.map2(space(), prefix(), ListRegisters)),
    #(1, qcheck.return(Reopen)),
  ]
  qcheck.from_weighted_generators(
    #(
      8,
      qcheck.map3(items(), guards(), fault(model), fn(items, guards, fault) {
        Commit(items:, guards:, fault:)
      }),
    ),
    reads,
  )
}

// A command that needs a committed entry waits for one. An unknown tip needs
// none, and neither does a duplicate that falls back to a clean commit, but
// both are drawn only when the model allows them, so a rejection here is a
// shrink candidate that deleted the commit they relied on.
fn admit(model: Model, command: Command) -> statem.Admission {
  case command, model.entries {
    Commit(fault: Duplicate(_), ..), 0 -> statem.Reject
    ScanBranch(tip: Known(_), ..), 0 | ScanBranch(tip: Newest, ..), 0 ->
      statem.Reject
    _, _ -> statem.Admit
  }
}

// The model moves only for a commit that is valid by construction: no stale
// guard and no fault.
fn advance(model: Model, command: Command) -> Model {
  case command {
    Commit(items:, guards:, fault: Clean) ->
      case list.any(guards, is_stale) {
        True -> model
        False ->
          Model(
            entries: model.entries
            + list.count(items, fn(item) {
              case item {
                AddEntry(..) -> True
                AddUsage(..) | Set(..) | Delete(..) -> False
              }
            }),
          )
      }
    Commit(..)
    | ScanBranch(..)
    | ScanEntries(..)
    | ScanUsage(..)
    | GetEntries(..)
    | GetRegister(..)
    | ListRegisters(..)
    | Reopen -> model
  }
}

fn new_sut() -> Sut {
  let path = fixtures.scratch("store-model") <> "/session.db"
  Sut(
    store: open_store(path),
    path:,
    mem: memory.new(),
    ctx: fixtures.new_ctx(),
    ids: dict.new(),
    parents: dict.new(),
    count: 0,
    high: 0,
  )
}

fn store_spec() -> statem.Spec(Model, Command, Sut) {
  statem.Spec(
    initial: Model(entries: 0),
    command:,
    precondition: admit,
    next_model: advance,
    // Each execution opens a database file of its own in a scratch directory
    // that `fixtures.scratch` empties first, so nothing a run or a shrink
    // candidate wrote can reach the next.
    new_sut:,
    execute:,
    // The reopen after the last command proves the whole history survives a
    // close: the audit then reads everything back off the disk.
    finish: fn(sut, _model) {
      use reopened <- result.try(reopen(sut))
      let verdict = audit(reopened)
      let _closed = storage.close(reopened.store)
      verdict
    },
    teardown: fn(sut) {
      let _closed = storage.close(sut.store)
      Nil
    },
  )
}

fn store_config() -> statem.Config {
  statem.default_config(seed: sequence_seed)
  |> statem.with_test_count(sequence_count)
  |> statem.with_max_commands(sequence_length)
}

pub fn memory_and_sqlite_agree_on_random_command_sequences_test() {
  case statem.check(store_spec(), store_config()) {
    Ok(Nil) -> Nil
    Error(failure) ->
      panic as statem.report(failure, fn(command) { string.inspect(command) })
  }
}

// A property that cannot reach a case proves nothing about it, so the
// generator is asked, over the very runs the property checks, whether every
// family of command and every boundary the checks exist for is drawn.
pub fn the_generator_reaches_every_family_of_command_test() {
  let drawn =
    int.range(0, sequence_count, [], fn(runs, run) { [run, ..runs] })
    |> list.flat_map(fn(run) {
      statem.commands(store_spec(), store_config(), run)
    })
  assert list.any(drawn, fn(command) {
    case command {
      Commit(fault: Duplicate(_), ..) -> True
      _ -> False
    }
  })
  assert list.any(drawn, fn(command) {
    case command {
      Commit(fault: Orphan, ..) -> True
      _ -> False
    }
  })
  assert list.any(drawn, fn(command) {
    case command {
      Commit(guards:, fault: Clean, ..) -> list.any(guards, is_stale)
      _ -> False
    }
  })
  assert list.any(drawn, fn(command) {
    case command {
      ScanBranch(tip: Newest, cursor: Some(SeqOf(..)), ..) -> True
      _ -> False
    }
  })
  assert list.any(drawn, fn(command) {
    case command {
      ScanBranch(tip: Unknown, ..) -> True
      _ -> False
    }
  })
  assert list.any(drawn, fn(command) { command == Reopen })
  assert list.any(drawn, fn(command) {
    case command {
      ScanEntries(from_seq: Some(SeqOf(..)), ..) -> True
      _ -> False
    }
  })
}
