//// The fault taxonomy: everything a simulated session must survive
//// without anyone noticing.
////
//// A fault here is *transparent* by definition. Crashing the tree at a
//// commit boundary, killing it while an effect is in flight, refusing a
//// commit as stale, faulting a read, stealing the writer's lease,
//// dropping or delaying a doorbell, starving an effect, losing an effect
//// process outright — none of these may change what the session ends up
//// having done. That is the whole claim, and it is why faults live apart
//// from `simulation/script`: anything that legitimately changes the
//// outcome (a provider that refuses, a user who aborts) is scripted into
//// both the fault-free run and the faulted one.
////
//// Faults are addressed two ways. Commit-indexed faults name a global
//// commit ordinal, counted across writer restarts, so "kill after commit
//// 7" means the same thing on a rebooted tree. Effect-indexed faults
//// name a dispatch ordinal, counted the same way. Neither index is a
//// wall-clock instant, so a schedule means the same thing on a loaded
//// machine as on an idle one.

import conformance/simulation/random.{type Rng}
import gleam/int
import gleam/list
import gleam/string

/// One injected fault.
pub type Fault {
  /// Kill the writer immediately after commit `ordinal` is durable and
  /// published, before its committer learns of it — the crash-between-
  /// two-commits state, at that exact boundary.
  CrashAtCommit(ordinal: Int)
  /// Kill the whole session tree while dispatched effect `index` is
  /// running, which is the one interruption a commit-boundary crash can
  /// never produce.
  CrashDuringEffect(index: Int)
  /// Kill only the strand driver serving dispatched effect `index`,
  /// while the effect is running: the partial crash. The writer, the
  /// registry, and every other strand keep going; the factory restarts
  /// just this driver, whose reaper must take the orphaned effect down
  /// with the old incarnation before recovery re-dispatches.
  RestartStrand(index: Int)
  /// Refuse the `ordinal`-th commit as a stale expectation without
  /// applying it, as a concurrent admission would.
  RefuseCommitStale(ordinal: Int)
  /// Fault the next store read after commit `ordinal`.
  ReadFault(ordinal: Int)
  /// Steal the writer lease after commit `ordinal`: the next renewal
  /// fails, the writer stops, and the tree reboots through the open
  /// path.
  StealLease(ordinal: Int)
  /// Drop doorbell `index`, which must cost latency and nothing else.
  DropDoorbell(index: Int)
  /// Deliver doorbell `index` late, after `delay_ms` of logical time.
  DelayDoorbell(index: Int, delay_ms: Int)
  /// Effect `index` settles only after `delay_ms` of logical time.
  SlowEffect(index: Int, delay_ms: Int)
  /// Provider effect `index` never settles; its process dies instead.
  ProviderEffectDies(index: Int)
  /// Provider effect `index` never settles and never dies; the surface's
  /// own timeout must settle it in band.
  ProviderEffectTimesOut(index: Int)
}

/// A whole fault schedule.
pub type Schedule {
  Schedule(faults: List(Fault))
}

/// The empty schedule: the fault-free run every faulted run is compared
/// against.
///
/// ## Examples
///
/// ```gleam
/// assert fault.none().faults == []
/// ```
///
pub fn none() -> Schedule {
  Schedule(faults: [])
}

/// A one-line rendering, printed with a failing seed.
///
/// ## Examples
///
/// ```gleam
/// // fault.describe(schedule)
/// ```
///
pub fn describe(schedule: Schedule) -> String {
  case schedule.faults {
    [] -> "no faults"
    faults -> string.join(list.map(faults, describe_fault), " + ")
  }
}

fn describe_fault(fault: Fault) -> String {
  case fault {
    CrashAtCommit(ordinal:) -> "crash@c" <> int.to_string(ordinal)
    CrashDuringEffect(index:) -> "crash@e" <> int.to_string(index)
    RestartStrand(index:) -> "strandkill@e" <> int.to_string(index)
    RefuseCommitStale(ordinal:) -> "stale@c" <> int.to_string(ordinal)
    ReadFault(ordinal:) -> "readfault@c" <> int.to_string(ordinal)
    StealLease(ordinal:) -> "leasetheft@c" <> int.to_string(ordinal)
    DropDoorbell(index:) -> "dropbell@" <> int.to_string(index)
    DelayDoorbell(index:, delay_ms:) ->
      "latebell@" <> int.to_string(index) <> "/" <> int.to_string(delay_ms)
    SlowEffect(index:, delay_ms:) ->
      "slow@e" <> int.to_string(index) <> "/" <> int.to_string(delay_ms)
    ProviderEffectDies(index:) -> "effectdied@e" <> int.to_string(index)
    ProviderEffectTimesOut(index:) -> "effecttimeout@e" <> int.to_string(index)
  }
}

/// Draws a schedule. The two bounds are the fault-free run's commit and
/// effect-dispatch counts, so a fault lands inside the run rather than
/// after it. A faulted run may dispatch fewer effects than the
/// fault-free one did, so an effect-indexed fault is reachable rather
/// than guaranteed.
///
/// ## Examples
///
/// ```gleam
/// // fault.generate(rng, commit_bound: 12, effect_bound: 4)
/// ```
///
pub fn generate(
  rng: Rng,
  commit_bound commit_bound: Int,
  effect_bound effect_bound: Int,
) -> #(Schedule, Rng) {
  let commits = int.max(commit_bound, 1)
  let effects = int.max(effect_bound, 1)
  let #(count, rng) = random.weighted(rng, [#(2, 1), #(5, 2), #(3, 3)], 1)
  let #(faults, rng) =
    random.list_of(rng, count, fn(rng) { draw(rng, commits, effects) })
  #(Schedule(faults: dedupe(faults)), rng)
}

fn draw(rng: Rng, bound: Int, effects: Int) -> #(Fault, Rng) {
  let #(ordinal, rng) = random.int_between(rng, 1, bound)
  let #(index, rng) = random.int_between(rng, 1, effects)
  let #(delay, rng) = random.pick(rng, [10, 250, 2000], 250)
  let #(kind, rng) = random.int_between(rng, 1, 100)
  let fault = case kind {
    n if n <= 24 -> CrashAtCommit(ordinal:)
    n if n <= 40 -> CrashDuringEffect(index:)
    n if n <= 48 -> RestartStrand(index:)
    n if n <= 58 -> RefuseCommitStale(ordinal:)
    n if n <= 65 -> ReadFault(ordinal:)
    n if n <= 71 -> StealLease(ordinal:)
    n if n <= 78 -> DropDoorbell(index:)
    n if n <= 84 -> DelayDoorbell(index:, delay_ms: delay)
    n if n <= 91 -> SlowEffect(index:, delay_ms: delay)
    n if n <= 96 -> ProviderEffectDies(index:)
    _ -> ProviderEffectTimesOut(index:)
  }
  #(fault, rng)
}

// At most one crash of each kind per schedule: two nested tree kills tell
// no story the single kills do not, and they multiply run time.
fn dedupe(faults: List(Fault)) -> List(Fault) {
  let #(kept, _crashes) =
    list.fold(faults, #([], 0), fn(acc, fault) {
      let #(kept, crashes) = acc
      case is_crash(fault), crashes {
        True, 0 -> #([fault, ..kept], 1)
        True, _ -> acc
        False, _ ->
          case list.contains(kept, fault) {
            True -> acc
            False -> #([fault, ..kept], crashes)
          }
      }
    })
  list.reverse(kept)
}

fn is_crash(fault: Fault) -> Bool {
  case fault {
    CrashAtCommit(..) | CrashDuringEffect(..) | RestartStrand(..) -> True
    _ -> False
  }
}

/// Candidate simpler schedules, ordered simplest first: drop one fault,
/// or pull one fault's index toward the start of the run. The runner
/// re-runs each candidate and keeps only those that still fail, so a
/// reported minimal schedule is one that was observed to fail, never one
/// inferred to.
///
/// ## Examples
///
/// ```gleam
/// // fault.shrink(schedule)
/// ```
///
pub fn shrink(schedule: Schedule) -> List(Schedule) {
  let drops =
    list.index_map(schedule.faults, fn(_fault, index) {
      Schedule(faults: drop_at(schedule.faults, index))
    })
  let pulls =
    list.index_map(schedule.faults, fn(fault, index) {
      Schedule(faults: replace_at(schedule.faults, index, earlier(fault)))
    })
    |> list.filter(fn(candidate) { candidate != schedule })
  list.append(drops, pulls)
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

fn earlier(fault: Fault) -> Fault {
  case fault {
    CrashAtCommit(ordinal:) -> CrashAtCommit(ordinal: halve(ordinal))
    CrashDuringEffect(index:) -> CrashDuringEffect(index: halve(index))
    RestartStrand(index:) -> RestartStrand(index: halve(index))
    RefuseCommitStale(ordinal:) -> RefuseCommitStale(ordinal: halve(ordinal))
    ReadFault(ordinal:) -> ReadFault(ordinal: halve(ordinal))
    StealLease(ordinal:) -> StealLease(ordinal: halve(ordinal))
    DropDoorbell(index:) -> DropDoorbell(index: halve(index))
    DelayDoorbell(index:, delay_ms:) ->
      DelayDoorbell(index: halve(index), delay_ms:)
    SlowEffect(index:, delay_ms:) -> SlowEffect(index: halve(index), delay_ms:)
    ProviderEffectDies(index:) -> ProviderEffectDies(index: halve(index))
    ProviderEffectTimesOut(index:) ->
      ProviderEffectTimesOut(index: halve(index))
  }
}

fn halve(n: Int) -> Int {
  int.max(1, n / 2)
}
