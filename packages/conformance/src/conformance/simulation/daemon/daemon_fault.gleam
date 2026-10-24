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
import gleam/option.{type Option, None, Some}
import gleam/string

/// One durable step of a single creation, named by what is already committed
/// when the daemon dies there.
pub type Step {
  /// The catalogue reservation and its domain row are committed, the slot is
  /// parked waiting for its domain, and no conversation database exists. This
  /// is the boundary `manager.reserve_creation` opens and the one a retry
  /// must resume rather than re-mint.
  AfterReservation

  /// The same committed state as `AfterReservation`: the registration and the
  /// domain mapping commit in one transaction, so no kill can land between
  /// them, and there is still no conversation database. What differs is which
  /// callback the builder is parked in. `AfterReservation` stops inside the
  /// domain build, before the slot has left `Awaiting`; this stops inside
  /// assembly, with the domain published and the slot moved to `Building`. The
  /// two are one durable state reached along two paths, and a retry has to
  /// resume it from either.
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

/// The one fault a schedule carries, if it carries any.
///
/// `Schedule` holds a list because the session taxonomy it mirrors does, and
/// because a schedule with two kills is the shape a future generator would
/// draw. This generator draws at most one, so a runner asking what to inject
/// is asking a two-answer question, and this is the total reading of the list
/// that answers it. A driver that matched on the list itself would carry an
/// arm for a state nothing produces.
///
/// ## Examples
///
/// ```gleam
/// assert daemon_fault.scheduled(daemon_fault.none()) == option.None
/// ```
pub fn scheduled(schedule: Schedule) -> Option(Fault) {
  list.first(schedule.faults) |> option.from_result
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

/// Converts a failure step enum into its short string representation.
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

  // Decide whether to inject a fault into the schedule.
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

/// Returns each creation paired with the steps its position makes reachable.
fn first_in_workspace(
  creations: List(#(String, String)),
  seen: List(String),
  acc: List(#(String, String, List(Step))),
) -> List(#(String, String, List(Step))) {
  // Filter and assign reachable steps for each creation.
  case creations {
    [] -> list.reverse(acc)
    [#(key, workspace), ..rest] -> {
      let later = [AfterDomainBind, AfterCustodyPublish, AfterConfirm]

      // Include reservation step only for first creation in workspace.
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

/// Candidate simpler schedules, simplest first, in the shape of
/// `fault.shrink`: drop a fault, or pull one earlier.
///
/// "Earlier" has two readings here, because a daemon fault has two
/// coordinates. The kill can move to an earlier **step** of the same
/// creation (`AfterConfirm` toward `AfterReservation`), or to the **creation
/// before it** in script order at the same step. Both only move toward the
/// start of the run, so every candidate has less of the run in front of its
/// kill than the case it came from.
///
/// A candidate is offered only where its step is reachable, using the rule
/// `generate` draws by. This matters for more than economy. An unreachable
/// step (`AfterReservation` for a creation whose workspace an earlier one
/// already opened) parks no builder, and the run waits out its real arrival
/// backstop before reporting `schedule/unreachable`, which is a different
/// check and would be rejected anyway, after twenty seconds.
///
/// The faults are not interdependent, which is why this is sound: a schedule
/// holds at most one kill, so no candidate can break a pairing another fault
/// relied on. Dropping the only fault yields the fault-free schedule. That
/// candidate cannot reproduce a failure that needs the kill, and one that
/// does reproduce it says the failure never depended on the kill at all.
///
/// ## Examples
///
/// ```gleam
/// // daemon_fault.shrink(schedule, daemon_script.coordinates(script))
/// ```
pub fn shrink(
  schedule: Schedule,
  creations: List(#(String, String)),
) -> List(Schedule) {
  let reachable = first_in_workspace(creations, [], [])
  let drops =
    list.index_map(schedule.faults, fn(_fault, index) {
      Schedule(faults: drop_at(schedule.faults, index))
    })
  let pulls =
    list.index_map(schedule.faults, fn(fault, index) {
      earlier(fault, reachable)
      |> list.map(fn(pulled) {
        Schedule(faults: replace_at(schedule.faults, index, pulled))
      })
    })
    |> list.flatten
  list.append(drops, pulls)
}

/// Returns candidate faults shifted earlier by step or creation order.
fn earlier(
  fault: Fault,
  reachable: List(#(String, String, List(Step))),
) -> List(Fault) {
  let KillDaemonAt(key:, workspace: _, step:) = fault
  let steps_of = fn(key) { list.find(reachable, fn(entry) { entry.0 == key }) }

  // Attempt to shift to an earlier step of the same creation.
  let earlier_step = case steps_of(key), previous_step(step) {
    Ok(#(_key, workspace, steps)), Some(before) ->
      case list.contains(steps, before) {
        True -> [KillDaemonAt(key:, workspace:, step: before)]
        False -> []
      }
    _unknown, _none -> []
  }

  // Attempt to shift to the previous creation at the same step.
  let earlier_key = case previous_creation(reachable, key) {
    Some(#(before, workspace, steps)) ->
      case list.contains(steps, step) {
        True -> [KillDaemonAt(key: before, workspace:, step:)]
        False -> []
      }
    None -> []
  }

  list.append(earlier_step, earlier_key)
}

/// Returns the immediate predecessor step toward reservation, if any.
fn previous_step(step: Step) -> Option(Step) {
  case step {
    AfterConfirm -> Some(AfterCustodyPublish)
    AfterCustodyPublish -> Some(AfterDomainBind)
    AfterDomainBind -> Some(AfterReservation)
    AfterReservation -> None
  }
}

/// Returns the creation immediately preceding `key` in script order.
fn previous_creation(
  creations: List(#(String, String, List(Step))),
  key: String,
) -> Option(#(String, String, List(Step))) {
  case creations {
    [before, next, ..rest] ->
      case next.0 == key {
        True -> Some(before)
        False -> previous_creation([next, ..rest], key)
      }
    [_only] | [] -> None
  }
}

fn drop_at(faults: List(Fault), index: Int) -> List(Fault) {
  list.append(list.take(faults, index), list.drop(faults, index + 1))
}

fn replace_at(faults: List(Fault), index: Int, fault: Fault) -> List(Fault) {
  list.append(list.take(faults, index), case list.drop(faults, index) {
    [_, ..rest] -> [fault, ..rest]
    [] -> []
  })
}
