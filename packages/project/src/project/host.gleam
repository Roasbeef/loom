//// The one door through which a passing check enters the engine.
////
//// A ticket can reach `Ready` only by holding a `CheckPassed`. The type is
//// opaque and `passed` is its only constructor, so the rest of the package
//// cannot build one. By convention only the host's event path calls `passed`:
//// the code that ran the project's check command in a fresh worktree at a
//// commit, in a jail the worker cannot reach, and recorded the result under
//// a ledger entry. The engine never calls it, the router's tools have no way
//// to, and a worker's `Report` has no variant that stands for it. The codec
//// calls it too, because the ledger stores the event and a replay must
//// rebuild the same value; that is a reader of what the host already wrote,
//// not a second writer.
////
//// Keeping the constructor in its own module makes the claim reviewable: a
//// grep for `host.passed` lists every place a passing check can come from.

import project/model.{type CommandDigest, type CommitId, type EntryId}

/// Proof that the project's check passed at one commit. A later commit on the
/// ticket invalidates it.
pub opaque type CheckPassed {
  CheckPassed(commit: CommitId, command_digest: CommandDigest, entry: EntryId)
}

/// Build the proof of a passing check. Only the host's event path calls this.
///
/// ## Examples
///
/// ```gleam
/// let proof =
///   host.passed(
///     model.CommitId("abc"),
///     model.CommandDigest("d1"),
///     model.EntryId("e1"),
///   )
/// assert host.commit(proof) == model.CommitId("abc")
/// ```
pub fn passed(
  commit: CommitId,
  command_digest: CommandDigest,
  entry: EntryId,
) -> CheckPassed {
  CheckPassed(commit:, command_digest:, entry:)
}

/// The commit the check ran against.
///
/// ## Examples
///
/// ```gleam
/// let proof = host.passed(
///   model.CommitId("abc"),
///   model.CommandDigest("d"),
///   model.EntryId("e"),
/// )
/// assert host.commit(proof) == model.CommitId("abc")
/// ```
pub fn commit(proof: CheckPassed) -> CommitId {
  proof.commit
}

/// The digest of the check command that ran.
///
/// ## Examples
///
/// ```gleam
/// let proof = host.passed(
///   model.CommitId("abc"),
///   model.CommandDigest("d"),
///   model.EntryId("e"),
/// )
/// assert host.command_digest(proof) == model.CommandDigest("d")
/// ```
pub fn command_digest(proof: CheckPassed) -> CommandDigest {
  proof.command_digest
}

/// The ledger entry that records the check's result.
///
/// ## Examples
///
/// ```gleam
/// let proof = host.passed(
///   model.CommitId("abc"),
///   model.CommandDigest("d"),
///   model.EntryId("e"),
/// )
/// assert host.entry(proof) == model.EntryId("e")
/// ```
pub fn entry(proof: CheckPassed) -> EntryId {
  proof.entry
}
