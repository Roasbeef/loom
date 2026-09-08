//// The daemon-level fault taxonomy: killing the whole daemon at a named
//// creation step, and nothing else.
////
//// `conformance/simulation/fault` is the session-level equivalent, and this
//// module mirrors its shape: a `Fault`, a `Schedule` holding them, a
//// `describe` a failing seed prints, and a `generate` a runner draws from a
//// split stream. What differs is the address. A session fault names a commit
//// or a dispatch ordinal, counted across restarts. A creation has no ordinal
//// worth naming, because the thing under test is precisely that a retry with
//// the same request key does not become a second creation. So a daemon fault
//// names a durable creation coordinate: the request key, and which of four
//// steps of that key's creation the daemon dies at.
////
//// A fault is transparent in the same sense the session taxonomy uses. The
//// run under a schedule must end on the rows the fault-free run of the same
//// script ended on. Every step here lands before `catalogue.confirm` except
//// the last, which lands after it, and none of them may change which identity
//// a request key owns.
////
//// A kill is the whole daemon, never the registry alone. The root answers a
//// dead registry by blocking recovery rather than by restarting it in place,
//// so a registry restart would leave the run wedged in a state production
//// never reaches. The durable shape a crash actually takes here is the root
//// going away and a later `start` rebuilding from the same state root, which
//// is why the harness takes the state root from its caller.

import conformance/simulation/random.{type Rng}
import gleam/list
import gleam/string

/// One durable step of a single creation, named by what is already committed
/// when the daemon dies there.
pub type Step {
  /// The catalogue reservation and its domain row are committed, the slot is
  /// parked waiting for its domain, and no conversation database exists. This
  /// is the boundary `manager.reserve_creation` opens and the one a retry
  /// must resume rather than re-mint.
  AfterReservation

  /// The domain is published and the builder owns assembly, so the slot has
  /// moved to `Building`. Still no conversation database.
  AfterDomainBind

  /// The builder holds the conversation's writer lease and has published its
  /// retirement under custody, but has not yet written the reserved identity
  /// into the database. A file exists for a row that is still `Reserved`.
  AfterCustodyPublish

  /// The registry confirmed the reservation and published the instance. The
  /// row is `Saved` and the session is resident, so a kill here tests that a
  /// restart rediscovers a complete creation rather than repeating it.
  AfterConfirm
}

/// One injected fault.
pub type Fault {
  /// Kill the daemon at `step` of the creation carrying `key`, then restart
  /// over the same state root. `workspace` is carried alongside the key
  /// because the earliest step is reached inside the domain build, which sees
  /// the workspace rather than the request key.
  KillDaemonAt(key: String, workspace: String, step: Step)
}

/// A whole fault schedule. At most one kill: two daemon restarts in one run
/// tell no story one restart does not, and each costs a fresh root.
pub type Schedule {
  Schedule(faults: List(Fault))
}

/// The empty schedule: the fault-free run every faulted run is compared
/// against.
///
/// ## Examples
///
/// ```gleam
/// assert daemon_fault.none().faults == []
/// ```
pub fn none() -> Schedule {
  Schedule(faults: [])
}

/// A one-line rendering, printed with a failing seed.
///
/// ## Examples
///
/// ```gleam
/// // daemon_fault.describe(schedule)
/// ```
pub fn describe(schedule: Schedule) -> String {
  case schedule.faults {
    [] -> "no faults"
    faults -> string.join(list.map(faults, describe_fault), " + ")
  }
}

fn describe_fault(fault: Fault) -> String {
  case fault {
    KillDaemonAt(key:, workspace: _, step:) ->
      "kill@" <> key <> "/" <> describe_step(step)
  }
}

fn describe_step(step: Step) -> String {
  case step {
    AfterReservation -> "reserved"
    AfterDomainBind -> "domain"
    AfterCustodyPublish -> "custody"
    AfterConfirm -> "confirmed"
  }
}

/// Draws a schedule over the creations a script will perform, each given as
/// `#(key, workspace)` in the order the script runs them.
///
/// `AfterReservation` is only offered for a creation that is the first in its
/// workspace, because a later creation there finds the domain already
/// published and never enters the domain build at all. Offering it anyway
/// would make a share of schedules silently fault-free, which is worse than
/// having them, since a run that never reaches its fault still passes.
///
/// ## Examples
///
/// ```gleam
/// // daemon_fault.generate(rng, [#("alpha", "/simulation/workspace-a")])
/// ```
pub fn generate(
  rng: Rng,
  creations: List(#(String, String)),
) -> #(Schedule, Rng) {
  let #(faulted, rng) = random.chance(rng, 75)
  case faulted, first_in_workspace(creations, [], []) {
    False, _ | _, [] -> #(Schedule(faults: []), rng)
    True, [first, ..rest] -> {
      let #(target, rng) = random.pick(rng, [first, ..rest], first)
      let #(key, workspace, steps) = target
      let #(step, rng) = random.pick(rng, steps, AfterConfirm)
      #(Schedule(faults: [KillDaemonAt(key:, workspace:, step:)]), rng)
    }
  }
}

// Every creation, paired with the steps its position makes reachable. A
// creation whose workspace an earlier one already opened cannot be killed at
// `AfterReservation`, so that step is left out of its choices rather than
// drawn and discarded.
fn first_in_workspace(
  creations: List(#(String, String)),
  seen: List(String),
  acc: List(#(String, String, List(Step))),
) -> List(#(String, String, List(Step))) {
  case creations {
    [] -> list.reverse(acc)
    [#(key, workspace), ..rest] -> {
      let later = [AfterDomainBind, AfterCustodyPublish, AfterConfirm]
      let steps = case list.contains(seen, workspace) {
        True -> later
        False -> [AfterReservation, ..later]
      }
      first_in_workspace(rest, [workspace, ..seen], [
        #(key, workspace, steps),
        ..acc
      ])
    }
  }
}
