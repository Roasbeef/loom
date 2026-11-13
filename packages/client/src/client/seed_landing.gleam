//// What a failed step of a seeded spawn means for the next ask
//// (protocol-change/107, slice 4b).
////
//// `client/spawn_seed` puts a parent's workspace into a child's own session on an
//// executor in a fixed order, and any step can fail. What the failure means is a
//// decision that has no effect in it, so it lives here, apart from the processes,
//// files and messages that `spawn_seed` uses to take the steps. Keeping it apart
//// is what lets `seed_landing_model_test` drive the same decisions the daemon
//// takes, in every order of failure and retry, without spawning anything.
////
//// ## Two kinds of failure
////
//// A failure is either one that asking again can cure or one that the same inputs
//// always get. The executor having no room, answering from a fence that has since
//// moved, not answering, or the work running out of time are of the first kind:
//// nothing is kept, the child's session stays, and the next ask resumes where the
//// executor stands. A workspace that does not take the state, a description or
//// piece the executor judges malformed, or a node that keeps no store are of the
//// second kind: the refusal is kept as the attempt's verdict and the child's
//// session is ended, since no child will run in it.
////
//// A verdict is therefore kept only for a deterministic refusal. Keeping one for
//// a transient failure would turn a moment's trouble into a permanent answer.
////
//// ## Whether the session has begun
////
//// The state is put into a workspace only before the child's first turn. The
//// answer to whether the session has begun is `session_states.Freshness`, which
//// has three values because the record can fail to be read, and `gate` turns it
//// into what the caller does. A record that cannot be read is never taken for a
//// session that has begun: the caller asks again.

import client/session_states
import client/state_transfer

/// Why the work did not put the state in place.
pub type Unplaced {
  /// Asking again can succeed. Nothing is kept as a verdict and the session
  /// stays.
  Retry(reason: String)

  /// The same inputs are refused again. The refusal is kept as the attempt's
  /// verdict and the child's session is ended.
  Refuse(reason: String)
}

/// What the work did, when it did not fail.
pub type Placed {
  /// The state was sent and the executor checked it out.
  Applied

  /// The session had begun by the time the apply was due, so the ask was a resend
  /// of a spawn that went through and nothing was put anywhere.
  AlreadyBegun
}

/// What a caller does with the answer to whether a session has begun.
pub type Gate {
  /// The session is fresh, so the state is put in.
  PutIn

  /// The session has begun, so nothing is put in and the child it started is the
  /// answer.
  LeaveAlone

  /// The record could not be read, so the caller asks again.
  AskAgain
}

/// Turns the answer to whether a session has begun into what the caller does.
///
/// ## Examples
///
/// ```gleam
/// assert seed_landing.gate(session_states.Unreadable) == seed_landing.AskAgain
/// ```
pub fn gate(freshness: session_states.Freshness) -> Gate {
  case freshness {
    session_states.Fresh -> PutIn
    session_states.Begun -> LeaveAlone
    session_states.Unreadable -> AskAgain
  }
}

/// What the executor's refusal of a piece means for the next ask. A store with no
/// room, a piece out of place and a bundle that arrived as another are states of
/// the executor and the link, which change. A description, a piece or a size the
/// executor judges malformed or too large, or a node that keeps no store, is the
/// same on every ask.
///
/// ## Examples
///
/// ```gleam
/// assert seed_landing.of_declined(state_transfer.NoRoom("at its cap"))
///   == seed_landing.Retry("sending the workspace to the executor failed: the executor declined it: ...")
/// ```
pub fn of_declined(refusal: state_transfer.Refusal) -> Unplaced {
  let said =
    "sending the workspace to the executor failed: the executor declined it: "
    <> state_transfer.describe(refusal)
  case refusal {
    state_transfer.NoRoom(..)
    | state_transfer.OutOfOrder(..)
    | state_transfer.Mismatch(..) -> Retry(said)
    state_transfer.BadState(..)
    | state_transfer.BadPiece(..)
    | state_transfer.TooLarge(..)
    | state_transfer.NotServing -> Refuse(said)
  }
}

/// What a failed apply means: a request to ask again stays a request to ask again,
/// and a refusal of the content stays a refusal.
///
/// ## Examples
///
/// ```gleam
/// assert seed_landing.of_failure(session_states.Later("no answer"))
///   == seed_landing.Retry("no answer")
/// ```
pub fn of_failure(failure: session_states.Failure) -> Unplaced {
  case failure {
    session_states.Later(reason:) -> Retry(reason)
    session_states.Final(reason:) ->
      Refuse("applying the workspace on the executor failed: " <> reason)
  }
}

/// Whether the failure is kept as the attempt's verdict. Only a refusal the same
/// inputs would get again is.
///
/// ## Examples
///
/// ```gleam
/// assert !seed_landing.keeps_verdict(seed_landing.Retry("no room"))
/// ```
pub fn keeps_verdict(unplaced: Unplaced) -> Bool {
  case unplaced {
    Retry(..) -> False
    Refuse(..) -> True
  }
}
