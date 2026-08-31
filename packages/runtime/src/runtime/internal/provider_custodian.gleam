//// The runtime-owned provider boundary.
////
//// An immediate `ProviderSurface.request` returns a live `StreamHandle`.
//// Calling an asynchronous implementation through that shape leaves one bad
//// instruction window between the return and publication of the handle to the
//// incarnation reaper. If the worker dies there, recovery can begin while the
//// just-started request is still cancelling. Production therefore supplies a
//// `PreparedProviderSurface`, while the immediate shape remains for in-memory
//// fakes which own no external work.
////
//// `prepare` closes the window at both composition layers. A minimal custodian
//// is published while the request worker is parked. Only after the reaper
//// accepts that witness does `begin` let the worker prepare and adopt the
//// inner owner, then grant the inner begin permit.
//// The custodian executes no provider callback: if the worker dies, it retains
//// and cancels the adopted inner handle and retires only after the inner owner
//// does. The worker is linked to the provider effect because they are one
//// failure domain: an unexpected surface crash must fault the effect and let
//// recovery run behind the custodian, not become a fabricated provider
//// response. The whole boundary is a Gleam process protocol.
////
//// ## The publication order
////
//// ```text
//// prepare
////   |-- spawn linked request worker, parked
////   |-- spawn unlinked custodian around that worker
////   `-- return { handle: custodian, begin }
////
//// strand runtime
////   |-- publish handle.owner to the incarnation reaper
////   `-- call begin only after the reaper acknowledges it
//// ```
////
//// This order removes the interval in which provider work has started but the
//// reaper does not yet know what to cancel. The linked
//// worker preserves the old failure semantics; the unlinked custodian
//// preserves the new drain evidence. They are separate because one PID cannot
//// both propagate a provider crash and remain alive to witness its cleanup.

import gleam/erlang/process.{type Monitor, type Pid, type Subject}
import provider/custodian
import provider/stream
import runtime/effects

type Start {
  Begin(custodian.Custodian)
}

type ParkedEvent {
  StartRequest(custodian.Custodian)
  StopBeforeStart
}

type WorkerEvent {
  Inner(stream.StreamEvent)
  Stop
  ConsumerDown(process.Down)
}

const cancel_grace_ms = 2000

/// A provider handle whose request worker is parked until `begin` is invoked.
///
/// Constructing the value starts no provider work. The caller first publishes
/// `handle.owner` to its restart barrier, then invokes `begin` exactly once.
pub type Prepared {
  Prepared(
    /// The immediately publishable outer stream and drain witness.
    handle: stream.StreamHandle,
    /// The one-way permit which lets the parked worker call the provider.
    begin: fn() -> Nil,
  )
}

/// Prepares a parked runtime custodian around one provider request.
///
/// This function returns only after the worker and custodian exist, but before
/// the provider surface is prepared. The returned `begin` capability completes the
/// prepare/publish/begin protocol described in the module documentation.
///
/// ## Examples
///
/// ```gleam
/// let provider_custodian.Prepared(handle:, begin:) =
///   provider_custodian.prepare(surface, request)
/// publish_to_reaper(handle)
/// begin()
/// ```
///
pub fn prepare(
  surface: effects.ProviderSurface,
  spec: effects.RequestSpec,
) -> Prepared {
  let consumer = process.self()
  let events = process.new_subject()
  let ready = process.new_subject()
  let worker =
    process.spawn(fn() {
      let start = process.new_subject()
      let stop = process.new_subject()
      process.send(ready, #(start, stop))
      // The stop capability exists before publication. Selecting it here lets
      // a rejected reaper adoption retire the parked worker without ever
      // crossing the provider seam.
      let parked =
        process.new_selector()
        |> process.select_map(start, fn(message) {
          let Begin(owner) = message
          StartRequest(owner)
        })
        |> process.select_map(stop, fn(_stop) { StopBeforeStart })
        |> process.selector_receive_forever()
      case parked {
        StopBeforeStart -> Nil
        StartRequest(owner) -> {
          let stream.PreparedStream(handle: inner, begin:) =
            effects.prepare_provider(surface, spec)
          case custodian.adopt(owner, inner.owner, inner.cancel) {
            True -> {
              let drain = stream.watch_drain(inner)
              begin()
              forward(inner, drain, consumer, events, stop)
            }
            // Prepared production work is still parked here, but legacy
            // in-memory surfaces may already carry a real terminal. The
            // cancellation loop preserves that terminal without granting a
            // begin permit to asynchronous work.
            False -> {
              let drain = stream.watch_drain(inner)
              cancel(inner, drain, consumer, events, stop)
            }
          }
        }
      }
    })
  let #(start, stop) = process.receive_forever(ready)
  let owner = custodian.start(worker, stop, Nil, consumer)
  Prepared(
    handle: stream.owned(events:, owner: custodian.owner(owner), cancel: fn() {
      custodian.cancel(owner)
    }),
    begin: fn() { process.send(start, Begin(owner)) },
  )
}

// --- Event forwarding -----------------------------------------------------

// The worker, rather than the custodian, receives provider events. This keeps
// parsing and terminal arbitration in the effect failure domain while the
// custodian remains a reliable witness if any of that work crashes.
fn forward(
  inner: stream.StreamHandle,
  witness: stream.DrainWitness,
  consumer: Pid,
  outer: Subject(stream.StreamEvent),
  stop: Subject(Nil),
) -> Nil {
  let consumer_monitor = process.monitor(consumer)
  let selector = selector(inner, stop, consumer_monitor)
  forward_selected(inner, witness, consumer, outer, consumer_monitor, selector)
}

fn cancel(
  inner: stream.StreamHandle,
  witness: stream.DrainWitness,
  consumer: Pid,
  outer: Subject(stream.StreamEvent),
  stop: Subject(Nil),
) -> Nil {
  let consumer_monitor = process.monitor(consumer)
  let selector = selector(inner, stop, consumer_monitor)
  cancel_and_forward(
    inner,
    witness,
    consumer,
    outer,
    consumer_monitor,
    cancel_grace_ms,
    selector,
  )
}

fn forward_selected(
  inner: stream.StreamHandle,
  witness: stream.DrainWitness,
  consumer: Pid,
  outer: Subject(stream.StreamEvent),
  consumer_monitor: Monitor,
  selector: process.Selector(WorkerEvent),
) -> Nil {
  case process.selector_receive_forever(selector) {
    Inner(event) -> {
      case process.is_alive(consumer) {
        True -> process.send(outer, event)
        False -> Nil
      }
      case event {
        stream.Delta(..) ->
          forward_selected(
            inner,
            witness,
            consumer,
            outer,
            consumer_monitor,
            selector,
          )
        stream.Settled(..) | stream.Failed(..) ->
          finish(witness, consumer_monitor)
      }
    }
    Stop ->
      case process.is_alive(consumer) {
        True ->
          cancel_and_forward(
            inner,
            witness,
            consumer,
            outer,
            consumer_monitor,
            cancel_grace_ms,
            selector,
          )
        False -> drain(inner, witness, consumer_monitor)
      }
    ConsumerDown(_down) -> drain(inner, witness, consumer_monitor)
  }
}

// Cancellation has two outcomes to report and one stronger fact to preserve.
// A provider-authored terminal may arrive during the grace and is forwarded;
// otherwise the caller gets `CancellationUnconfirmed`. Either way this worker
// does not exit until the inner owner's Down proves the subtree is gone.
fn cancel_and_forward(
  inner: stream.StreamHandle,
  witness: stream.DrainWitness,
  consumer: Pid,
  outer: Subject(stream.StreamEvent),
  consumer_monitor: Monitor,
  within_ms: Int,
  selector: process.Selector(WorkerEvent),
) -> Nil {
  // Cancellation is fallible work, so it runs on this worker rather than on
  // the public witness. If it crashes, the custodian observes that Down and
  // invokes its retained copy on a disposable helper while keeping the inner
  // owner in the drain set.
  stream.cancel(inner)
  case process.selector_receive(selector, within: within_ms) {
    Ok(Inner(stream.Delta(..))) | Ok(Stop) ->
      cancel_and_forward(
        inner,
        witness,
        consumer,
        outer,
        consumer_monitor,
        within_ms,
        selector,
      )
    Ok(ConsumerDown(_down)) -> drain(inner, witness, consumer_monitor)
    Ok(Inner(stream.Settled(..) as terminal))
    | Ok(Inner(stream.Failed(..) as terminal)) -> {
      case process.is_alive(consumer) {
        True -> process.send(outer, terminal)
        False -> Nil
      }
      finish(witness, consumer_monitor)
    }
    Error(Nil) -> {
      send_unconfirmed(consumer, outer)
      require_inner_drain(witness)
      forget(consumer_monitor)
    }
  }
}

// Once the consumer is dead, no process can use a terminal event. Waiting for
// one would delay restart without preserving information, so this path keeps
// only the stronger obligation: cancel and prove the inner owner is gone.
fn drain(
  inner: stream.StreamHandle,
  witness: stream.DrainWitness,
  consumer_monitor: Monitor,
) -> Nil {
  stream.cancel(inner)
  require_inner_drain(witness)
  forget(consumer_monitor)
}

fn selector(
  inner: stream.StreamHandle,
  stop: Subject(Nil),
  consumer_monitor: Monitor,
) -> process.Selector(WorkerEvent) {
  process.new_selector()
  |> process.select_map(inner.events, Inner)
  |> process.select_map(stop, fn(_nil) { Stop })
  |> process.select_specific_monitor(consumer_monitor, ConsumerDown)
}

fn finish(witness: stream.DrainWitness, consumer_monitor: Monitor) -> Nil {
  require_inner_drain(witness)
  forget(consumer_monitor)
}

fn send_unconfirmed(consumer: Pid, outer: Subject(stream.StreamEvent)) -> Nil {
  case process.is_alive(consumer) {
    True ->
      process.send(outer, stream.Failed(error: stream.CancellationUnconfirmed))
    False -> Nil
  }
}

fn forget(consumer_monitor: Monitor) -> Nil {
  process.demonitor_process(consumer_monitor)
}

// This worker is itself a transitive child of the outer custodian. Preserving
// an abnormal inner Down as an abnormal worker Down lets that custodian report
// the lost proof instead of certifying a clean provider shutdown.
fn require_inner_drain(witness: stream.DrainWitness) -> Nil {
  case stream.await_drain_forever(witness) {
    stream.Drained -> Nil
    stream.TimedOut | stream.ProofLost -> process.kill(process.self())
  }
}
