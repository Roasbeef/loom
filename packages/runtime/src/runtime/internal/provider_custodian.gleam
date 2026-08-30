//// The runtime-owned provider boundary.
////
//// `ProviderSurface.request` is intentionally synchronous: it returns a live
//// `StreamHandle`. Calling it directly from the effect worker leaves one bad
//// instruction window between that return and publication of the handle to
//// the incarnation reaper. If the worker dies there, recovery can begin while
//// the just-started request is still cancelling.
////
//// `prepare` closes the window without changing the frozen surface. A minimal
//// custodian is published while the request worker is parked. Only after the
//// reaper accepts that witness does `begin` let the worker call the surface.
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
//// This order removes the interval in which `surface.request` has started
//// native work but the reaper does not yet know what to cancel. The linked
//// worker preserves the old failure semantics; the unlinked custodian
//// preserves the new drain evidence. They are separate because one PID cannot
//// both propagate a provider crash and remain alive to witness its cleanup.

import gleam/erlang/process.{type Monitor, type Pid, type Subject}
import gleam/option.{type Option, None, Some}
import provider/custodian
import provider/stream
import runtime/effects

type Start {
  Begin(custodian.Custodian)
}

type WorkerEvent {
  Inner(stream.StreamEvent)
  Stop
  ConsumerDown(process.Down)
  InnerOwnerDown(process.Down)
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
/// `surface.request` is called. The returned `begin` capability completes the
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
      let Begin(owner) = process.receive_forever(start)
      let inner = surface.request(spec)
      case custodian.adopt(owner, inner.owner, inner.cancel) {
        True -> forward(inner, consumer, events, stop)
        // A rejected permit means teardown won the race or its witness died,
        // but the provider may already have queued a real terminal. Preserve
        // that terminal while the consumer lives; its Down changes the same
        // loop into drain-only teardown.
        False -> cancel(inner, consumer, events, stop)
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
  consumer: Pid,
  outer: Subject(stream.StreamEvent),
  stop: Subject(Nil),
) -> Nil {
  let consumer_monitor = process.monitor(consumer)
  let #(selector, owner_monitor) = selector(inner, stop, consumer_monitor)
  forward_selected(
    inner,
    consumer,
    outer,
    consumer_monitor,
    owner_monitor,
    selector,
  )
}

fn cancel(
  inner: stream.StreamHandle,
  consumer: Pid,
  outer: Subject(stream.StreamEvent),
  stop: Subject(Nil),
) -> Nil {
  let consumer_monitor = process.monitor(consumer)
  let #(selector, owner_monitor) = selector(inner, stop, consumer_monitor)
  cancel_and_forward(
    inner,
    consumer,
    outer,
    consumer_monitor,
    owner_monitor,
    cancel_grace_ms,
    selector,
  )
}

fn forward_selected(
  inner: stream.StreamHandle,
  consumer: Pid,
  outer: Subject(stream.StreamEvent),
  consumer_monitor: Monitor,
  owner_monitor: Option(Monitor),
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
            consumer,
            outer,
            consumer_monitor,
            owner_monitor,
            selector,
          )
        stream.Settled(..) | stream.Failed(..) ->
          finish(inner, consumer_monitor, owner_monitor)
      }
    }
    Stop ->
      case process.is_alive(consumer) {
        True ->
          cancel_and_forward(
            inner,
            consumer,
            outer,
            consumer_monitor,
            owner_monitor,
            cancel_grace_ms,
            selector,
          )
        False -> drain(inner, consumer_monitor, owner_monitor)
      }
    ConsumerDown(_down) -> drain(inner, consumer_monitor, owner_monitor)
    InnerOwnerDown(_down) -> {
      send_unconfirmed(consumer, outer)
      forget(consumer_monitor, owner_monitor)
    }
  }
}

// Cancellation has two outcomes to report and one stronger fact to preserve.
// A provider-authored terminal may arrive during the grace and is forwarded;
// otherwise the caller gets `CancellationUnconfirmed`. Either way this worker
// does not exit until the inner owner's Down proves the subtree is gone.
fn cancel_and_forward(
  inner: stream.StreamHandle,
  consumer: Pid,
  outer: Subject(stream.StreamEvent),
  consumer_monitor: Monitor,
  owner_monitor: Option(Monitor),
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
        consumer,
        outer,
        consumer_monitor,
        owner_monitor,
        within_ms,
        selector,
      )
    Ok(ConsumerDown(_down)) -> drain(inner, consumer_monitor, owner_monitor)
    Ok(Inner(stream.Settled(..) as terminal))
    | Ok(Inner(stream.Failed(..) as terminal)) -> {
      case process.is_alive(consumer) {
        True -> process.send(outer, terminal)
        False -> Nil
      }
      finish(inner, consumer_monitor, owner_monitor)
    }
    Ok(InnerOwnerDown(_down)) | Error(Nil) -> {
      send_unconfirmed(consumer, outer)
      stream.await_stopped_forever(inner)
      forget(consumer_monitor, owner_monitor)
    }
  }
}

// Once the consumer is dead, no process can use a terminal event. Waiting for
// one would delay restart without preserving information, so this path keeps
// only the stronger obligation: cancel and prove the inner owner is gone.
fn drain(
  inner: stream.StreamHandle,
  consumer_monitor: Monitor,
  owner_monitor: Option(Monitor),
) -> Nil {
  stream.cancel(inner)
  stream.await_stopped_forever(inner)
  forget(consumer_monitor, owner_monitor)
}

fn selector(
  inner: stream.StreamHandle,
  stop: Subject(Nil),
  consumer_monitor: Monitor,
) -> #(process.Selector(WorkerEvent), Option(Monitor)) {
  let selector =
    process.new_selector()
    |> process.select_map(inner.events, Inner)
    |> process.select_map(stop, fn(_nil) { Stop })
    |> process.select_specific_monitor(consumer_monitor, ConsumerDown)
  case inner.owner {
    None -> #(selector, None)
    Some(owner) -> {
      let monitor = process.monitor(owner)
      #(
        process.select_specific_monitor(selector, monitor, InnerOwnerDown),
        Some(monitor),
      )
    }
  }
}

fn finish(
  inner: stream.StreamHandle,
  consumer_monitor: Monitor,
  owner_monitor: Option(Monitor),
) -> Nil {
  stream.await_stopped_forever(inner)
  forget(consumer_monitor, owner_monitor)
}

fn send_unconfirmed(consumer: Pid, outer: Subject(stream.StreamEvent)) -> Nil {
  case process.is_alive(consumer) {
    True ->
      process.send(outer, stream.Failed(error: stream.CancellationUnconfirmed))
    False -> Nil
  }
}

fn forget(consumer_monitor: Monitor, owner_monitor: Option(Monitor)) -> Nil {
  process.demonitor_process(consumer_monitor)
  case owner_monitor {
    None -> Nil
    Some(monitor) -> process.demonitor_process(monitor)
  }
}
