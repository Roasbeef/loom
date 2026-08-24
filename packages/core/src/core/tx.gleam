//// Transactions: the write vocabulary and commit results.
////
//// A `Tx` is the unit of durability: an ordered list of writes applied
//// all-or-none, guarded by optimistic seq expectations (CAS). These types
//// transcribe the frozen contract in the implementation spec Part 1.1;
//// storage (WP-B) implements `commit` over them.

import core/corruption.{type CorruptionReport}
import core/entry.{type Entry, type UsageRow}
import core/ids.{type Seq}
import core/register.{type RegisterNs, type RegisterValue}
import gleam/option.{type Option}

/// One write within a transaction.
///
/// Constructor invariants:
///
/// - `InsertEntry`: the entry's `seq` and `ts` are placeholders — storage
///   assigns both at commit. Writing under an existing id is corruption,
///   not an update.
/// - `InsertUsage`: same seq/id rules as entries; the ledger is
///   append-only.
/// - `SetRegister`: replaces the cell's value; registers keep no history.
/// - `DeleteRegister`: removes the cell; deleting an absent cell is a
///   no-op.
pub type Write {
  /// Insert one write-once conversation entry.
  InsertEntry(entry: Entry)
  /// Append one usage-ledger row.
  InsertUsage(row: UsageRow)
  /// Set a register cell, replacing any current value.
  SetRegister(ns: RegisterNs, key: String, value: RegisterValue)
  /// Delete a register cell.
  DeleteRegister(ns: RegisterNs, key: String)
}

/// An atomic transaction: writes applied in order, all-or-none, only if
/// every seq expectation holds.
///
/// Constructor invariants: `writes` apply in list order within one commit;
/// `expected` is evaluated before any write is applied — any mismatch means
/// nothing is applied.
pub type Tx {
  Tx(writes: List(Write), expected: List(SeqExpectation))
}

/// One optimistic concurrency guard: the register seq the committer
/// computed against.
///
/// Constructor invariants: `seq` is `Some(n)` when the committer read the
/// cell at write-seq `n`, and `None` when the cell must not exist.
pub type SeqExpectation {
  Expect(ns: RegisterNs, key: String, seq: Option(Seq))
}

/// A successful commit.
///
/// Constructor invariants: `first_seq` is the seq of the first write;
/// `seqs` lists every assigned seq in write order (strictly increasing,
/// gaps legal); `ts` is the storage-assigned commit time in Unix ms.
pub type CommitResult {
  CommitResult(first_seq: Seq, seqs: List(Seq), ts: Int)
}

/// Why a commit was refused or failed. Nothing was applied in any case.
///
/// Constructor invariants: `StaleExpectation` carries the first expectation
/// that did not hold — the committer should reload and replan;
/// `Corruption` means the transaction or stored state failed a total
/// decode; `Faulted` is a backend fault (I/O error, lost lease) described
/// for humans, not for dispatch.
pub type CommitError {
  /// An `expected` entry did not match the cell's current seq.
  StaleExpectation(failed: SeqExpectation)
  /// The transaction or stored state failed a total decode.
  Corruption(report: CorruptionReport)
  /// The backend faulted; the reason is a human-readable description.
  Faulted(reason: String)
}
