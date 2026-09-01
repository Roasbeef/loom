//// A transitive drain witness for one public provider handle.
////
//// A process doing useful work is a poor teardown acknowledgement: if that
//// process crashes, its Down arrives before the work beneath it has finished
//// cancelling. This module keeps the public witness deliberately boring. It
//// is a weft *witnessed run* — a scope that monitors the worker and every
//// registered child, runs fallible cancellation closures on disposable
//// helper processes, and performs no provider callback, HTTP operation, or
//// foreign call of its own. Everything this module used to hand-roll (the
//// adoption ledger, the leaf/transitive proof rule, the poisoned exit, the
//// canceller helpers) is now weft's contract, and this file is the
//// translation between loom's vocabulary and weft's.
////
//// Child adoption is an acknowledged prepare/publish/begin boundary. A worker
//// must register a child before permitting that child to start. If teardown
//// already began, the scope refuses the permit, still asks the child to
//// stop, and still waits for both the child and the worker. The public owner
//// therefore retires normally only after the complete registered subtree is
//// gone. A leaf's `Down` completes that leaf, while an abnormal transitive
//// owner exit destroys its descendant proof and becomes an abnormal owner
//// exit after every still-known child is cancelled.
////
//// ## The process shape
////
//// The custodian is not another worker. It is the scope that remembers every
//// process which can still own work:
////
//// ```text
//// caller --cancel--> scope --stop--> worker
////                      |               |
////                      |               +-- starts child
////                      |<----- adopt(child, cancel)
////                      |
////                      +-- exits only after worker, child, and cancellation
////                          helpers have all exited
//// ```
////
//// The worker is adopted as a *leaf* whose cancel capability is its typed
//// stop message, so a crashing worker loses no proof: its children are
//// adopted into the scope directly, never beneath it. The worker's exit is
//// also a watched exit, so its death — however it dies — fans cancellation
//// out to every child adopted beside it. Children are cancelled *after* the
//// worker is gone, never beside it: every child is published beneath the
//// worker (`weft.adopt_under`), so a worker that is asked to stop keeps sole
//// custody of its own cancellation and terminal arbitration, and the scope
//// reaches a child directly only when the worker died without finishing
//// that job. The direct consumer is watched the same way: a
//// stream nobody can receive cancels itself. A lost proof cancels the run
//// (`weft.CancelSiblings`), which is how a dead transitive child asks the
//// worker to stop rather than leaving it parked behind evidence that no
//// longer exists.
////
//// Code which monitors `owner(custodian)` consequently learns a stronger fact
//// than "the worker returned": a normal `Down` proves cancellation crossed
//// every registered ownership boundary, while an abnormal `Down` — weft's
//// `weft_drain_proof_lost` — explicitly reports that the proof was lost.
//// Keeping callbacks off the scope itself matters because a crashing callback
//// must not destroy that evidence.
////
//// ## The ownership protocol
////
//// A worker starts a child parked, calls `adopt`, and starts the child only
//// when `adopt` returns `True`. A `False` result means teardown already won;
//// the worker must not begin new work. `owner: None` is reserved for work with
//// no asynchronous descendant: there is no child process for the scope to
//// retain and nothing for the witness to cancel, so the adoption is only the
//// permit question. The scope answers it through a stand-in leaf that exits
//// at once (see `ownerless`), the seam loom#159 names for ownerless work.

import gleam/erlang/process.{type Pid, type Subject}
import gleam/option.{type Option, None, Some}
import weft

/// The typed capability for one transitive drain witness.
///
/// The constructor is opaque so callers can request cancellation, publish
/// children, or monitor the witness without sending arbitrary process
/// messages.
pub opaque type Custodian {
  Custodian(
    /// The witnessed run whose scope is the public owner.
    run: weft.Witnessed,
    /// The ledger children are published through. `None` only when the
    /// scope died before handing it over, in which case every adoption is
    /// refused and the owner's `Down` already carries the verdict.
    ledger: Option(weft.Ledger),
    /// The worker every child is published beneath.
    worker: Pid,
  )
}

// --- Public protocol -------------------------------------------------------

/// Starts a custodian for `worker` and every child it later adopts.
///
/// `worker_stop` is the worker's typed cooperative-stop capability. `consumer`
/// is watched because a stream nobody can receive must cancel itself. The
/// returned custodian's scope is linked to the caller as every weft scope is,
/// but it survives a crashing worker long enough to account for the worker's
/// descendants, which is its whole purpose.
///
/// ## Examples
///
/// ```gleam
/// let stop = process.new_subject()
/// let worker = process.spawn_unlinked(fn() { process.receive_forever(stop) })
/// let witness =
///   custodian.start(worker, stop, Nil, consumer: process.self())
/// custodian.cancel(witness)
/// // custodian.owner(witness) exits after `worker` exits.
/// ```
///
pub fn start(
  worker: Pid,
  worker_stop: Subject(stop),
  stop_message: stop,
  consumer: Pid,
) -> Custodian {
  let handoff = process.new_subject()
  let run =
    weft.new_prepared([
      weft.managed(fn(ledger) {
        // The worker is adopted before this closure returns, so the task's
        // account cannot be sealed by its own return: from here the worker's
        // exit is an owner fact the scope waits for. A leaf, because the
        // worker's children are adopted into the scope directly and a
        // crashing worker therefore abandons nothing the scope cannot see.
        let _adoption =
          weft.adopt_leaf(ledger, owner: worker, cancel: fn() {
            process.send(worker_stop, stop_message)
          })
        process.send(handoff, ledger)
        Ok(Nil)
      }),
    ])
    |> weft.on_failure(weft.CancelSiblings)
    |> weft.cancel_when_exits(worker)
    |> weft.cancel_when_exits(consumer)
    |> weft.start_witnessed

  // The ledger arrives from inside the scope's worker; racing it against the
  // scope's own death is what keeps this total when something outside the
  // run destroys the scope before its first task runs.
  let watch = process.monitor(weft.witness_pid(run))
  let ledger =
    process.new_selector()
    |> process.select_map(handoff, Some)
    |> process.select_specific_monitor(watch, fn(_down) { None })
    |> process.selector_receive_forever()
  process.demonitor_process(watch)
  Custodian(run:, ledger:, worker:)
}

/// Returns the PID whose `Down` proves that the registered subtree drained.
///
/// Monitoring this PID is the acknowledgement side of cancellation. Callers
/// must not kill it: doing so would erase the evidence they are waiting for.
///
/// ## Examples
///
/// ```gleam
/// let owner = custodian.owner(witness)
/// // process.monitor(owner)
/// ```
///
pub fn owner(custodian: Custodian) -> Pid {
  weft.witness_pid(custodian.run)
}

/// Requests cooperative teardown of the worker and its adopted children.
///
/// The request is asynchronous and idempotent. Monitor `owner(custodian)` when
/// the caller must know that teardown finished rather than merely began.
///
/// ## Examples
///
/// ```gleam
/// custodian.cancel(witness)
/// custodian.cancel(witness)
/// // Both calls request the same teardown.
/// ```
///
pub fn cancel(custodian: Custodian) -> Nil {
  weft.cancel_witnessed(custodian.run)
}

/// Publishes an optional child owner and its cancellation capability.
///
/// The call is synchronous. `True` transfers teardown custody to the witness;
/// the worker may now start or expose the child. `False` means cancellation or
/// witness death won the race, so the worker must leave the child parked and
/// tear it down. An owner published after cancellation is still retained until
/// it exits.
///
/// ## Examples
///
/// ```gleam
/// let accepted = custodian.adopt(witness, Some(child), cancel_child)
/// // accepted == True means `witness` now accounts for `child`.
/// ```
///
pub fn adopt(
  custodian: Custodian,
  owner: Option(Pid),
  cancel: fn() -> Nil,
) -> Bool {
  case owner {
    Some(pid) -> adopt_as(custodian, pid, Transitive, cancel)
    None -> adopt_as(custodian, ownerless(), Leaf, fn() { Nil })
  }
}

/// Publishes a required transitive owner/cancel pair.
///
/// Only a normal owner exit proves that every descendant beneath this boundary
/// drained. Cancellation merely requests that exit; it never weakens the proof.
///
/// ## Examples
///
/// ```gleam
/// custodian.adopt_owner(witness, observer, fn() {
///   process.kill(observer)
/// })
/// // -> True
/// ```
///
pub fn adopt_owner(
  custodian: Custodian,
  owner: Pid,
  cancel: fn() -> Nil,
) -> Bool {
  adopt_as(custodian, owner, Transitive, cancel)
}

/// Publishes a required leaf process and its cancellation capability.
///
/// A leaf owns no process, port, or socket beneath itself, so any `Down` ends
/// its complete lifetime. Use `adopt_owner` instead when the process speaks for
/// descendants whose drain must survive its own failure.
///
/// ## Examples
///
/// ```gleam
/// custodian.adopt_leaf(witness, observer, fn() { process.kill(observer) })
/// // -> True
/// ```
///
pub fn adopt_leaf(
  custodian: Custodian,
  owner: Pid,
  cancel: fn() -> Nil,
) -> Bool {
  adopt_as(custodian, owner, Leaf, cancel)
}

// A leaf's own Down completes its lifetime regardless of reason. A transitive
// witness speaks for work beneath itself, so only Normal can carry its proof.
type ChildKind {
  Leaf
  Transitive
}

fn adopt_as(
  custodian: Custodian,
  owner: Pid,
  kind: ChildKind,
  cancel: fn() -> Nil,
) -> Bool {
  case custodian.ledger {
    // The scope was gone before it handed the ledger over; there is nobody
    // to transfer custody to, which is the answer a dead witness gives.
    None -> False
    Some(ledger) -> {
      let parent = custodian.worker
      let adoption = case kind {
        Transitive -> weft.adopt_under(ledger, parent:, owner:, cancel:)
        Leaf -> weft.adopt_leaf_under(ledger, parent:, owner:, cancel:)
      }
      case adoption {
        weft.Adopted -> True
        weft.Refused -> False
      }
    }
  }
}

// Ownerless work has no process to wait for, and the hand-rolled loop never
// retained it: adopting `None` was the permit question and nothing more,
// its cancellation closure being the worker's to run. The scope's ledger
// needs a pid to answer that question against, so this is a leaf that
// exits at once — resolved as drained the moment it is watched, cancelled
// by a no-op, and holding nothing open.
fn ownerless() -> Pid {
  process.spawn_unlinked(fn() { Nil })
}
