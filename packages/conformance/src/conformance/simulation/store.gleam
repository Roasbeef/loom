//// The instrumented session: a `Storage` record wrapped around the real
//// memory backend, plus a lease that can be stolen.
////
//// Every commit in a session goes through one writer, and the writer
//// goes through this record, which makes it the natural place to do
//// three things a simulation needs: count commits with a counter that
//// survives writer restarts, refuse a commit as stale exactly as a
//// concurrent admission would, and check the per-commit invariants at
//// the boundary that caused them rather than at the end of the run.
////
//// The lease is the other half. A memory session has no lease, so this
//// module gives it one — a renewal that fails once at a chosen commit
//// and succeeds afterwards, which is what a stolen-then-reacquired
//// SQLite lease looks like to the writer above it: a renewal failure,
//// an abnormal stop, and a tree that reboots through the open path.

import conformance/simulation/control.{type Control}
import conformance/simulation/fault.{type Schedule}
import conformance/simulation/invariant
import core/register
import core/tx.{type CommitError, type CommitResult, type Tx}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import session/session.{type Session, Session}
import storage/storage.{type Storage, type StorageError}

/// Wraps a session so its commits and reads run under `schedule`.
///
/// `lease_interval_ms` is the renewal period the writer above will use;
/// keep it short so a scheduled theft lands promptly after its commit.
///
/// ## Examples
///
/// ```gleam
/// // store.instrument(session, ctl, schedule, strand: "main", lease_interval_ms: 5)
/// ```
///
pub fn instrument(
  session: Session,
  ctl: Control,
  schedule: Schedule,
  strand strand: String,
  lease_interval_ms lease_interval_ms: Int,
) -> Session {
  let inner = session.store
  let read_faults =
    scheduled(schedule, fn(item) {
      case item {
        fault.ReadFault(..) -> True
        _ -> False
      }
    })
  let stale_faults =
    scheduled(schedule, fn(item) {
      case item {
        fault.RefuseCommitStale(..) -> True
        _ -> False
      }
    })
  let lease_faults =
    scheduled(schedule, fn(item) {
      case item {
        fault.StealLease(..) -> True
        _ -> False
      }
    })
  Session(
    store: storage.Storage(
      handle: Nil,
      commit: fn(_handle, transaction) {
        commit(inner, ctl, schedule, strand, stale_faults, transaction)
      },
      get_entries: fn(_handle, ids) {
        use <- guarded(ctl, schedule, read_faults)
        storage.get_entries(inner, ids)
      },
      get_register: fn(_handle, ns, key) {
        use <- guarded(ctl, schedule, read_faults)
        storage.get_register(inner, ns, key)
      },
      list_registers: fn(_handle, ns, prefix) {
        use <- guarded(ctl, schedule, read_faults)
        storage.list_registers(inner, ns, prefix)
      },
      scan_branch: fn(_handle, query) {
        use <- guarded(ctl, schedule, read_faults)
        storage.scan_branch(inner, query)
      },
      scan_entries: fn(_handle, query) {
        use <- guarded(ctl, schedule, read_faults)
        storage.scan_entries(inner, query)
      },
      scan_usage: fn(_handle, query) {
        use <- guarded(ctl, schedule, read_faults)
        storage.scan_usage(inner, query)
      },
      stats: fn(_handle) {
        use <- guarded(ctl, schedule, read_faults)
        storage.stats(inner)
      },
      close: fn(_handle) { storage.close(inner) },
    ),
    renew_lease: fn() { renew(ctl, schedule, lease_faults) },
    lease_interval_ms: Some(lease_interval_ms),
  )
}

// A read that may fault transiently, once, at its scheduled commit.
fn guarded(
  ctl: Control,
  schedule: Schedule,
  armed: Bool,
  read: fn() -> Result(value, StorageError),
) -> Result(value, StorageError) {
  use <- unless(armed, read)
  let landed = control.commits(ctl)
  case
    scheduled(schedule, fn(item) {
      case item {
        fault.ReadFault(ordinal:) -> ordinal == landed
        _ -> False
      }
    })
  {
    False -> read()
    True ->
      case control.claim(ctl, "readfault@c" <> int.to_string(landed)) {
        False -> read()
        True -> {
          control.mark(ctl, "transient-read-fault")
          Error(storage.BackendFault(reason: "injected transient read fault"))
        }
      }
  }
}

// Reads are on the hot path of every drive pass, so the control actor is
// consulted only when the schedule actually has a fault that could fire.
fn unless(
  armed: Bool,
  plain: fn() -> value,
  guarded_path: fn() -> value,
) -> value {
  case armed {
    True -> guarded_path()
    False -> plain()
  }
}

fn commit(
  inner: Storage(handle),
  ctl: Control,
  schedule: Schedule,
  strand: String,
  stale_faults: Bool,
  transaction: Tx,
) -> Result(CommitResult, CommitError) {
  let next = control.commits(ctl) + 1
  case refuse_as_stale(ctl, schedule, next, stale_faults, transaction) {
    Some(error) -> Error(error)
    None ->
      case storage.commit(inner, transaction) {
        Error(error) -> Error(error)
        Ok(result) -> {
          let _ordinal = control.note_commit(ctl)
          note_terminal_writes(ctl, transaction)
          case invariant.placement(inner, strand:) {
            Ok(Nil) -> Nil
            Error(violation) ->
              control.note(
                ctl,
                invariant.describe(violation)
                  <> " (at commit "
                  <> int.to_string(next)
                  <> ")",
              )
          }
          Ok(result)
        }
      }
  }
}

fn refuse_as_stale(
  ctl: Control,
  schedule: Schedule,
  next: Int,
  armed: Bool,
  transaction: Tx,
) -> option.Option(CommitError) {
  use <- unless(armed, fn() { None })
  case
    scheduled(schedule, fn(item) {
      case item {
        fault.RefuseCommitStale(ordinal:) -> ordinal == next
        _ -> False
      }
    })
  {
    False -> None
    True ->
      case control.claim(ctl, "stale@c" <> int.to_string(next)) {
        False -> None
        True -> {
          control.mark(ctl, "stale-commit-refusal")
          Some(
            tx.StaleExpectation(failed: case transaction.expected {
              [first, ..] -> first
              [] -> tx.Expect(ns: register.StrandState, key: "main", seq: None)
            }),
          )
        }
      }
  }
}

// The terminal transaction is the one that writes `strand.last_result`;
// counting those per strand is how "written exactly once per operation"
// is checked, and how the abort-at-terminal intervention finds its
// moment.
fn note_terminal_writes(ctl: Control, transaction: Tx) -> Nil {
  list.each(transaction.writes, fn(write) {
    case write {
      tx.SetRegister(ns: register.StrandLastResult, key:, value: _) -> {
        let _count = control.bump(ctl, "last_result:" <> key)
        let _terminals = control.bump(ctl, "terminal_commits")
        Nil
      }
      _ -> Nil
    }
  })
}

fn renew(
  ctl: Control,
  schedule: Schedule,
  armed: Bool,
) -> Result(Nil, StorageError) {
  use <- unless(armed, fn() { Ok(Nil) })
  let landed = control.commits(ctl)
  case
    scheduled(schedule, fn(item) {
      case item {
        fault.StealLease(ordinal:) -> ordinal <= landed
        _ -> False
      }
    })
  {
    False -> Ok(Nil)
    True ->
      case control.claim(ctl, "leasetheft") {
        False -> Ok(Nil)
        True -> {
          control.mark(ctl, "lease-theft")
          Error(storage.BackendFault(
            reason: "writer lease stolen by a competing writer",
          ))
        }
      }
  }
}

fn scheduled(schedule: Schedule, matches: fn(fault.Fault) -> Bool) -> Bool {
  list.any(schedule.faults, matches)
}
