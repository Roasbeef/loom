//// An in-test fake store: a Dict-backed register/entry map that applies
//// the machine's emitted transactions with the storage rules that matter
//// to the machine suite — seq expectations (CAS), write-once entries and
//// usage rows, ordered in-transaction application, strictly increasing
//// seqs.

import core/entry.{type Entry, type UsageRow}
import core/ids
import core/register.{type RegisterNs, type RegisterValue}
import core/tx.{type SeqExpectation, type Tx, type Write, Expect}
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{None, Some}
import gleam/string

/// The fake store's whole state.
pub type Store {
  Store(
    registers: Dict(#(String, String), #(Int, RegisterValue)),
    entries: Dict(String, Entry),
    entry_log: List(String),
    usage: List(UsageRow),
    next_seq: Int,
  )
}

/// An empty store.
pub fn new() -> Store {
  Store(
    registers: dict.new(),
    entries: dict.new(),
    entry_log: [],
    usage: [],
    next_seq: 1,
  )
}

/// Applies one transaction: expectations first, then writes in order,
/// all-or-none. Errors are human-readable strings for test assertions.
pub fn apply(store: Store, tx: Tx) -> Result(Store, String) {
  case check_expectations(store, tx.expected) {
    Error(message) -> Error(message)
    Ok(Nil) -> apply_writes(store, tx.writes)
  }
}

fn check_expectations(
  store: Store,
  expected: List(SeqExpectation),
) -> Result(Nil, String) {
  list.try_fold(expected, Nil, fn(_, expectation) {
    let Expect(ns:, key:, seq:) = expectation
    let current = dict.get(store.registers, #(register.ns_to_string(ns), key))
    case seq, current {
      None, Error(Nil) -> Ok(Nil)
      None, Ok(_) ->
        Error("stale expectation: " <> key <> " exists but None expected")
      Some(expected_seq), Ok(#(current_seq, _)) ->
        case expected_seq == current_seq {
          True -> Ok(Nil)
          False -> Error("stale expectation: " <> key)
        }
      Some(_), Error(Nil) ->
        Error("stale expectation: " <> key <> " absent but seq expected")
    }
  })
}

fn apply_writes(store: Store, writes: List(Write)) -> Result(Store, String) {
  list.try_fold(writes, store, fn(store, write) {
    let seq = store.next_seq
    let store = Store(..store, next_seq: seq + 1)
    case write {
      tx.InsertEntry(entry:) -> {
        let id = ids.entry_id_to_string(entry_id(entry))
        case dict.has_key(store.entries, id) {
          True -> Error("entry id collision: " <> id)
          False ->
            Ok(
              Store(
                ..store,
                entries: dict.insert(store.entries, id, with_seq(entry, seq)),
                entry_log: list.append(store.entry_log, [id]),
              ),
            )
        }
      }
      tx.InsertUsage(row:) -> {
        let id = ids.usage_id_to_string(row.id)
        let collision =
          list.any(store.usage, fn(existing) {
            ids.usage_id_to_string(existing.id) == id
          })
        case collision {
          True -> Error("usage id collision: " <> id)
          False ->
            Ok(
              Store(
                ..store,
                usage: list.append(store.usage, [
                  entry.UsageRow(..row, seq: seq),
                ]),
              ),
            )
        }
      }
      tx.SetRegister(ns:, key:, value:) ->
        Ok(
          Store(
            ..store,
            registers: dict.insert(
              store.registers,
              #(register.ns_to_string(ns), key),
              #(seq, value),
            ),
          ),
        )
      tx.DeleteRegister(ns:, key:) ->
        Ok(
          Store(
            ..store,
            registers: dict.delete(store.registers, #(
              register.ns_to_string(ns),
              key,
            )),
          ),
        )
    }
  })
}

/// Reads one register: `Ok(#(seq, value))` when present.
pub fn get_register(
  store: Store,
  ns: RegisterNs,
  key: String,
) -> Result(#(Int, RegisterValue), Nil) {
  dict.get(store.registers, #(register.ns_to_string(ns), key))
}

/// Every register key under a namespace, with an optional prefix filter.
pub fn list_register_keys(
  store: Store,
  ns: RegisterNs,
  prefix: String,
) -> List(String) {
  let ns_text = register.ns_to_string(ns)
  store.registers
  |> dict.keys
  |> list.filter_map(fn(pair) {
    let #(key_ns, key) = pair
    case key_ns == ns_text && starts_with(key, prefix) {
      True -> Ok(key)
      False -> Error(Nil)
    }
  })
}

/// Reads an entry by id.
pub fn get_entry(store: Store, id: String) -> Result(Entry, Nil) {
  dict.get(store.entries, id)
}

fn starts_with(text: String, prefix: String) -> Bool {
  string.starts_with(text, prefix)
}

fn entry_id(entry: Entry) -> ids.EntryId {
  case entry {
    entry.MessageEntry(id:, ..)
    | entry.CompactionEntry(id:, ..)
    | entry.BranchSummaryEntry(id:, ..)
    | entry.CustomEntry(id:, ..) -> id
  }
}

fn with_seq(entry: Entry, seq: Int) -> Entry {
  case entry {
    entry.MessageEntry(..) -> entry.MessageEntry(..entry, seq:, ts: seq)
    entry.CompactionEntry(..) -> entry.CompactionEntry(..entry, seq:, ts: seq)
    entry.BranchSummaryEntry(..) ->
      entry.BranchSummaryEntry(..entry, seq:, ts: seq)
    entry.CustomEntry(..) -> entry.CustomEntry(..entry, seq:, ts: seq)
  }
}
