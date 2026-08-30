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
//// does. The whole boundary is a Gleam process protocol.

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

/// A provider handle whose worker is parked until `begin` is invoked.
pub type Prepared {
  Prepared(handle: stream.StreamHandle, begin: fn() -> Nil)
}

/// Publishes a parked runtime custodian around one provider request.
pub fn prepare(
  surface: effects.ProviderSurface,
  spec: effects.RequestSpec,
) -> Prepared {
  let consumer = process.self()
  let events = process.new_subject()
  let ready = process.new_subject()
  let worker =
    process.spawn_unlinked(fn() {
      let start = process.new_subject()
      let stop = process.new_subject()
      process.send(ready, #(start, stop))
      let Begin(owner) = process.receive_forever(start)
      let inner = surface.request(spec)
      case custodian.adopt(owner, inner.owner, inner.cancel) {
        True -> forward(inner, consumer, events, stop)
        // A rejected permit means teardown won the race or its witness died.
        // Do not wait for a stop message that a dead custodian cannot send.
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
    Stop | ConsumerDown(_down) ->
      cancel_and_forward(
        inner,
        consumer,
        outer,
        consumer_monitor,
        owner_monitor,
        selector,
      )
    InnerOwnerDown(_down) -> {
      send_unconfirmed(consumer, outer)
      forget(consumer_monitor, owner_monitor)
    }
  }
}

fn cancel_and_forward(
  inner: stream.StreamHandle,
  consumer: Pid,
  outer: Subject(stream.StreamEvent),
  consumer_monitor: Monitor,
  owner_monitor: Option(Monitor),
  selector: process.Selector(WorkerEvent),
) -> Nil {
  // Cancellation is fallible work, so it runs on this worker rather than on
  // the public witness. If it crashes, the custodian observes that Down and
  // invokes its retained copy on a disposable helper while keeping the inner
  // owner in the drain set.
  stream.cancel(inner)
  case process.selector_receive(selector, within: 2000) {
    Ok(Inner(stream.Delta(..))) | Ok(Stop) | Ok(ConsumerDown(_)) ->
      cancel_and_forward(
        inner,
        consumer,
        outer,
        consumer_monitor,
        owner_monitor,
        selector,
      )
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
