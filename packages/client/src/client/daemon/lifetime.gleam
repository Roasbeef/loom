//// One daemon lifetime witness over the registry's aggregate cleanup proof.
////
//// The outer Weft scope owns one transitive registry, not every incarnation it
//// ever opens. The registry retains original per-instance monitors and exits
//// normally only after they have all proved drain. This bounds the outer owner
//// ledger independently of the number of open/close cycles.
////
//// Registry KILL loses that aggregate proof. Inner cleanup scopes self-cancel,
//// but their later completion cannot repair an outer witness which already
//// reported proof loss. Daemon wiring must keep readiness false and retain its
//// lifetime lock on that result; replacing the registry empty is forbidden.
//// This module starts no listener and acquires or releases no daemon lock.

import client/daemon/manager
import gleam/erlang/process.{type Subject}
import gleam/result
import gleam/string
import storage/catalogue
import weft

/// A registry and its outer cancellation capability and drain witness.
pub opaque type Lifetime(instance) {
  Lifetime(registry: manager.Manager(instance), witness: weft.Witnessed)
}

// How long the daemon root waits for the scope to publish its registry. Five
// times the registry's own startup budget, so a slow host is not mistaken for
// a wedged one.
const registry_handoff_deadline_ms = 5000

/// Starts a registry beneath a single transitive Weft owner.
///
/// The caller is the long-lived daemon root and must trap exits, since loss of
/// proof makes the linked witness exit abnormally. It must monitor `witness`
/// before exposing the registry and retain that original monitor's verdict.
/// The worker stays alive for the registry's lifetime, so returning from this
/// function does not cancel a scope started by a short-lived opening job.
///
/// ## Examples
///
/// ```gleam
/// // lifetime.start(catalogue, assembly, epoch: daemon_epoch, limit: 8)
/// ```
@internal
pub fn start(
  catalogue: catalogue.Catalogue,
  assembly: manager.Assembly(instance),
  epoch epoch: String,
  limit limit: Int,
) -> Result(Lifetime(instance), String) {
  let replies = process.new_subject()
  let witness =
    weft.new_prepared([
      weft.managed(fn(ledger) {
        own_registry(catalogue, assembly, epoch, limit, ledger, replies)
      }),
    ])
    |> weft.start_witnessed

  // Everything the managed worker does before it answers is bounded — the
  // registry's own one-second initialiser and one adoption — so a wait with no
  // deadline could only ever hold the daemon's boot open on a host that will
  // not answer at all. Expiry refuses the start; the scope keeps whatever it
  // took and reports it through the witness the caller is already monitoring.
  let watch = process.monitor(weft.witness_pid(witness))
  let outcome =
    process.new_selector()
    |> process.select(replies)
    |> process.select_specific_monitor(watch, fn(down) {
      Error(
        "daemon custody ended during startup: " <> string.inspect(down.reason),
      )
    })
    |> process.selector_receive(registry_handoff_deadline_ms)
    |> result.unwrap(Error("daemon custody did not publish a registry in time"))
  process.demonitor_process(watch)
  result.map(outcome, fn(registry) { Lifetime(registry:, witness:) })
}

/// Returns the registry for authorized daemon requests.
///
/// ## Examples
///
/// ```gleam
/// let registry = lifetime.registry(daemon)
/// ```
@internal
pub fn registry(lifetime: Lifetime(instance)) -> manager.Manager(instance) {
  lifetime.registry
}

/// Returns the outer witness for the root's original lifetime monitor.
///
/// Only a normal exit observed through that monitor permits lock release.
/// A dead witness discovered later is missing evidence, not successful drain.
///
/// ## Examples
///
/// ```gleam
/// let watch = process.monitor(lifetime.witness(daemon))
/// ```
@internal
pub fn witness(lifetime: Lifetime(instance)) -> process.Pid {
  weft.witness_pid(lifetime.witness)
}

/// Requests shutdown without imposing a deadline on cleanup ownership.
///
/// The root may stop waiting, but it must retain its lock until its original
/// witness monitor reports normal retirement. Failure never permits restart.
///
/// ## Examples
///
/// ```gleam
/// lifetime.shutdown(daemon)
/// ```
@internal
pub fn shutdown(lifetime: Lifetime(instance)) -> Nil {
  weft.cancel_witnessed(lifetime.witness)
}

fn own_registry(
  catalogue: catalogue.Catalogue,
  assembly: manager.Assembly(instance),
  epoch: String,
  limit: Int,
  ledger: weft.Ledger,
  replies: Subject(Result(manager.Manager(instance), String)),
) -> Result(Nil, String) {
  // A registry failure belongs to the outer transitive monitor. Its startup
  // link must not kill this worker before that monitor records the verdict.
  process.trap_exits(True)
  case manager.start(catalogue, assembly, epoch:, limit:) {
    Error(reason) -> {
      process.send(replies, Error(reason))
      Error(reason)
    }
    Ok(registry) -> {
      let watch = process.monitor(manager.pid(registry))
      let adoption =
        weft.adopt(ledger, owner: manager.pid(registry), cancel: fn() {
          manager.shutdown(registry)
        })
      case adoption {
        weft.Adopted -> process.send(replies, Ok(registry))
        weft.Refused -> {
          // No caller has received the registry, so no instance can have begun.
          // Close the empty registry rather than exposing unowned admission.
          manager.shutdown(registry)
          process.send(replies, Error("daemon custody refused the registry"))
        }
      }

      // Keeping this worker alive preserves the registry's starter lifetime.
      // Cancellation may kill it; the registry then enters ordered shutdown.
      let _down =
        process.new_selector()
        |> process.select_specific_monitor(watch, fn(down) { down })
        |> process.selector_receive_forever()
      Ok(Nil)
    }
  }
}
