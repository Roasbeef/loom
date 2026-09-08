//// The two daemon-level faults a lifecycle or a revocation script runs
//// under, and the draws a seed makes about where they land.
////
//// A session fault is a torn write or a refused commit inside one
//// conversation. Neither of these is: one kills the whole daemon while a
//// lifecycle request it accepted has not settled, and the other lands an
//// owner administration between two halves of a command that is already
//// through admission. What they have in common with the session taxonomy is
//// the property they are held to. A fault is transparent when the run under
//// it converges on the durable rows the fault-free run left, and a fault
//// that changes those rows is a finding rather than an expected difference.
////
//// Every coordinate here is durable. `KillDaemonWithPending` names the
//// lifecycle request by the session it addresses and by which request it is,
//// never by how many messages had been sent. `RevokeAt` names a step in the
//// command's own progress through the authority boundary, and that step is a
//// place in the protocol rather than a moment on a clock. The reason is the
//// one `docs/architecture/simulation.md` gives under "Keying, and why it is
//// not a counter": a counter renumbers itself the moment the script changes,
//// and a seed corpus pinned against it stops meaning anything.

import gleam/int
import gleam/string

/// Which lifecycle request the daemon is killed in the middle of.
///
/// The registry answers both with an accepted operation before the work
/// behind it finishes, so both leave a request whose outcome the caller never
/// learned. They differ in what the durable record said at the moment of the
/// kill, which is what makes running the script under each worth the second
/// run.
pub type Pending {
  /// An explicit open of a saved session, accepted as `Opening` and killed
  /// before the instance is published.
  PendingOpen

  /// An ordered stop of a resident session, accepted as `Stopping` and killed
  /// before the drain completes.
  PendingStop
}

/// Where an owner's revocation lands relative to the command the revoked
/// principal already has in flight.
///
/// The manager asks the same authority question when a command is admitted
/// and again when its reply is delivered, so a command in flight straddles
/// two answers. These are the two coordinates a revocation can land on
/// between them, and the check is that both end in silence.
pub type Coordinate {
  /// The revocation commits before the principal offers the command, so
  /// admission itself is refused and nothing is ever queued.
  BeforeAdmission

  /// The revocation commits after admission and before delivery, so a
  /// command that was accepted must still not be delivered.
  BetweenAdmissionAndDelivery
}

/// What a run is asked to survive.
pub type Fault {
  /// Nothing goes wrong. This is the baseline every faulted run is compared
  /// against, and it is a variant rather than an absence so that a script
  /// takes the same path under both.
  FaultFree

  /// The root is killed, untrappably, while the named session's lifecycle
  /// request has not settled. Recovery is a fresh root over the same state
  /// root, because a killed registry leaves the root blocking recovery and
  /// the persisted reservation is the only thing a restart has to go on.
  KillDaemonWithPending(session: String, request: Pending)

  /// The named principal's credential is revoked at a durable coordinate in
  /// the command it already has in flight.
  RevokeAt(principal: String, at: Coordinate)
}

/// Renders a fault as the phrase a failing check puts in its detail, so a red
/// verdict says which schedule produced it without the reader consulting the
/// seed.
///
/// ## Examples
///
/// ```gleam
/// // lifecycle_faults.describe(FaultFree) == "no fault"
/// ```
pub fn describe(fault: Fault) -> String {
  case fault {
    FaultFree -> "no fault"
    KillDaemonWithPending(session:, request:) ->
      "daemon killed with a pending "
      <> case request {
        PendingOpen -> "open"
        PendingStop -> "stop"
      }
      <> " of "
      <> session
    RevokeAt(principal:, at:) ->
      "principal "
      <> principal
      <> " revoked "
      <> case at {
        BeforeAdmission -> "before its command was admitted"
        BetweenAdmissionAndDelivery ->
          "after its command was admitted and before delivery"
      }
  }
}

/// Draws the lifecycle request a seed kills the daemon in the middle of.
///
/// The draw is a parity of the seed rather than a call into the simulation's
/// generator, because these scripts take exactly two draws between them and a
/// split generator would carry state neither of them reads.
///
/// ## Examples
///
/// ```gleam
/// // lifecycle_faults.pending_for(4471)
/// ```
pub fn pending_for(seed: Int) -> Pending {
  case int.bitwise_and(seed, 1) {
    0 -> PendingOpen
    _ -> PendingStop
  }
}

/// Draws the coordinate a seed lands a revocation on.
///
/// ## Examples
///
/// ```gleam
/// // lifecycle_faults.coordinate_for(4471)
/// ```
pub fn coordinate_for(seed: Int) -> Coordinate {
  case int.bitwise_and(int.bitwise_shift_right(seed, 1), 1) {
    0 -> BeforeAdmission
    _ -> BetweenAdmissionAndDelivery
  }
}

/// The name a report uses for one run's schedule.
///
/// ## Examples
///
/// ```gleam
/// // lifecycle_faults.label(FaultFree) == "fault-free"
/// ```
pub fn label(fault: Fault) -> String {
  case fault {
    FaultFree -> "fault-free"
    KillDaemonWithPending(..) | RevokeAt(..) ->
      string.replace(describe(fault), " ", "-")
  }
}
