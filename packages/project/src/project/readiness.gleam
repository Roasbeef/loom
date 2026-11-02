//// Whether a ticket's work is ready for a person, and the only ways that
//// changes.
////
//// Readiness is the part of a ticket's life that a model must not be able to
//// move. A worker reports `Waiting`; the host snapshots its head; and only a
//// passing check built by the host (`host.CheckPassed`) can make the ticket
//// `Ready`. A diff that touches protected paths skips the check and waits for
//// a person (`AwaitingReview`), so edited build files never run on this path.
//// A person may publish past a failing check, which is a recorded command
//// (`Published`) and not a `Ready`, so the board can tell a verified ticket
//// from one a person overrode. A later commit invalidates whatever came
//// before it.
////
//// Every transition is a pure function here, and the engine calls these and
//// never constructs `Ready` itself.
////
//// <!-- transitions: readiness.Readiness -->
////
//// | state | check passed | person publishes | protected paths touched | new commit |
//// | --- | --- | --- | --- | --- |
//// | `InProgress` | `Ready` with the proof | `Published` | `AwaitingReview` | unchanged |
//// | `AwaitingReview` | refused, no check ran | `Published` | unchanged | `InProgress` |
//// | `Ready` | refused, already ready | `Published` | unchanged | `InProgress` |
//// | `Published` | refused, a person already decided | `Published` with the new commit | unchanged | `InProgress` |

import gleam/option.{type Option}
import project/host.{type CheckPassed}
import project/model.{type CommitId, type PrincipalId}

/// Where a ticket's work stands before a person looks at it.
pub type Readiness {
  /// Still being worked or checked.
  InProgress

  /// A person must look; the diff touched protected paths and no check ran.
  AwaitingReview

  /// The host's check passed at the proof's commit.
  Ready(
    /// The host-built proof.
    proof: CheckPassed,
  )

  /// A person published past the check.
  Published(
    /// Who published.
    by: PrincipalId,
    /// The commit they published.
    commit: CommitId,
  )
}

/// Record a passing check. Only a ticket still in progress can take one,
/// because a check is requested only from that state.
///
/// ## Examples
///
/// ```gleam
/// let proof = host.passed(
///   model.CommitId("a"),
///   model.CommandDigest("d"),
///   model.EntryId("e"),
/// )
/// assert readiness.check_passed(readiness.InProgress, proof)
///   == Ok(readiness.Ready(proof))
/// ```
pub fn check_passed(
  current: Readiness,
  proof: CheckPassed,
) -> Result(Readiness, Nil) {
  case current {
    InProgress -> Ok(Ready(proof))
    AwaitingReview -> Error(Nil)
    Ready(_) -> Error(Nil)
    Published(_, _) -> Error(Nil)
  }
}

/// Record that a person published past the check.
///
/// ## Examples
///
/// ```gleam
/// let by = model.PrincipalId("p")
/// let commit = model.CommitId("a")
/// assert readiness.person_publishes(readiness.InProgress, by, commit)
///   == readiness.Published(by, commit)
/// ```
pub fn person_publishes(
  current: Readiness,
  by: PrincipalId,
  commit: CommitId,
) -> Readiness {
  case current {
    InProgress -> Published(by, commit)
    AwaitingReview -> Published(by, commit)
    Ready(_) -> Published(by, commit)
    Published(_, _) -> Published(by, commit)
  }
}

/// Record that the head's diff touches protected paths, so no check runs.
///
/// ## Examples
///
/// ```gleam
/// assert readiness.protected_touched(readiness.InProgress)
///   == readiness.AwaitingReview
/// ```
pub fn protected_touched(current: Readiness) -> Readiness {
  case current {
    InProgress -> AwaitingReview
    AwaitingReview -> AwaitingReview
    Ready(_) -> current
    Published(_, _) -> current
  }
}

/// Record that the ticket has a new commit, which invalidates a passed
/// check, a publish and a pending review alike.
///
/// ## Examples
///
/// ```gleam
/// assert readiness.new_commit(readiness.AwaitingReview)
///   == readiness.InProgress
/// ```
pub fn new_commit(current: Readiness) -> Readiness {
  case current {
    InProgress -> InProgress
    AwaitingReview -> InProgress
    Ready(_) -> InProgress
    Published(_, _) -> InProgress
  }
}

/// The commit a readiness vouches for, if it vouches for one.
///
/// ## Examples
///
/// ```gleam
/// assert readiness.vouches_for(readiness.InProgress) == option.None
/// ```
pub fn vouches_for(current: Readiness) -> Option(CommitId) {
  case current {
    InProgress -> option.None
    AwaitingReview -> option.None
    Ready(proof) -> option.Some(host.commit(proof))
    Published(_, commit) -> option.Some(commit)
  }
}
