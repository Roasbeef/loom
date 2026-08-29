//// A cancellation-transparent wrapper around one provider stream.
////
//// Client composition layers use this when they must observe events before
//// forwarding them. There are deliberately two processes. The worker is the
//// inner stream's direct consumer and runs the observer; the guard owns the
//// public handle, monitors the worker, and turns a post-start worker crash
//// into one prompt in-band failure. Keeping those roles separate matters:
//// an observer panic must not strand the public consumer until its ordinary
//// provider timeout, and the worker's death must still propagate cancellation
//// down through every wrapper beneath it.
////
//// Explicit cancellation enters through the guard. It is handed to the inner
//// owner, then the guard waits one fixed grace timer for the owner-authored
//// terminal. The timer is scheduled once, so a stream of late deltas cannot
//// extend teardown indefinitely. If no terminal arrives, the guard reports
//// `CancellationUnconfirmed`, kills the worker, and the worker's disappearance
//// supplies a second downward cancellation signal to the inner stream.

import gleam/erlang/process.{type Pid, type Subject}
import provider/stream
import runtime/effects

const start_timeout_ms = 5000

const cancel_grace_ms = 1500

type Control {
  Cancel
  CancelDeadline
}

type WorkerEvent {
  InnerEvent(stream.StreamEvent)
  GuardDown(process.Down)
}

type GuardEvent {
  Relayed(stream.StreamEvent)
  ConsumerDown(process.Down)
  WorkerDown(process.Down)
  CancelRequested
  CancelExpired
}

/// Wraps one provider request with a synchronous event observer.
///
/// The observer must return promptly and must not receive from the stream.
/// Cancellation remains owned by the inner request owner; this wrapper carries
/// its capability and terminal acknowledgement across the composition boundary.
pub fn wrap(
  surface: effects.ProviderSurface,
  spec: effects.RequestSpec,
  observe: fn(stream.StreamEvent) -> Nil,
) -> stream.StreamHandle {
  let consumer = process.self()
  let outer = process.new_subject()
  let ready = process.new_subject()
  let guard =
    process.spawn_unlinked(fn() {
      guard(surface, spec, observe, consumer, outer, ready)
    })
  await_handle(outer, ready, guard)
}

fn guard(
  surface: effects.ProviderSurface,
  spec: effects.RequestSpec,
  observe: fn(stream.StreamEvent) -> Nil,
  consumer: Pid,
  outer: Subject(stream.StreamEvent),
  ready: Subject(Result(Subject(Control), String)),
) -> Nil {
  let self = process.self()
  let control = process.new_subject()
  let worker_ready = process.new_subject()
  let relayed = process.new_subject()
  let consumer_monitor = process.monitor(consumer)
  let worker =
    process.spawn_unlinked(fn() {
      relay_worker(surface, spec, observe, self, worker_ready, relayed)
    })
  let worker_monitor = process.monitor(worker)
  let started =
    process.new_selector()
    |> process.select_map(worker_ready, Ok)
    |> process.select_specific_monitor(worker_monitor, fn(_down) { Error(Nil) })
    |> process.selector_receive(start_timeout_ms)
  case started {
    Ok(Ok(inner)) -> {
      process.send(ready, Ok(control))
      forward(
        inner,
        worker,
        outer,
        consumer,
        control,
        relayed,
        consumer_monitor,
        worker_monitor,
      )
    }
    Ok(Error(Nil)) -> {
      process.demonitor_process(consumer_monitor)
      process.send(ready, Error("provider relay worker exited before start"))
    }
    Error(Nil) -> {
      process.kill(worker)
      process.demonitor_process(consumer_monitor)
      process.demonitor_process(worker_monitor)
      process.send(ready, Error("provider relay worker did not start in time"))
    }
  }
}

fn relay_worker(
  surface: effects.ProviderSurface,
  spec: effects.RequestSpec,
  observe: fn(stream.StreamEvent) -> Nil,
  guard: Pid,
  ready: Subject(stream.StreamHandle),
  relayed: Subject(stream.StreamEvent),
) -> Nil {
  let guard_monitor = process.monitor(guard)
  let inner = surface.request(spec)
  case process.is_alive(guard) {
    False -> {
      process.demonitor_process(guard_monitor)
      stream.cancel(inner)
    }
    True -> {
      process.send(ready, inner)
      forward_inner(
        inner,
        guard_monitor,
        relayed,
        observe,
        surface.timeout_ms + 100,
      )
    }
  }
}

fn forward_inner(
  inner: stream.StreamHandle,
  guard_monitor: process.Monitor,
  relayed: Subject(stream.StreamEvent),
  observe: fn(stream.StreamEvent) -> Nil,
  timeout_ms: Int,
) -> Nil {
  let selector =
    process.new_selector()
    |> process.select_map(inner.events, InnerEvent)
    |> process.select_specific_monitor(guard_monitor, GuardDown)
  case process.selector_receive(selector, within: timeout_ms) {
    Error(Nil) -> {
      process.demonitor_process(guard_monitor)
      stream.cancel(inner)
    }
    Ok(GuardDown(_down)) -> stream.cancel(inner)
    Ok(InnerEvent(event)) -> {
      observe(event)
      process.send(relayed, event)
      case event {
        stream.Delta(..) ->
          forward_inner(inner, guard_monitor, relayed, observe, timeout_ms)
        stream.Settled(..) | stream.Failed(..) ->
          process.demonitor_process(guard_monitor)
      }
    }
  }
}

fn await_handle(
  outer: Subject(stream.StreamEvent),
  ready: Subject(Result(Subject(Control), String)),
  guard: Pid,
) -> stream.StreamHandle {
  let monitor = process.monitor(guard)
  let started =
    process.new_selector()
    |> process.select_map(ready, Ok)
    |> process.select_specific_monitor(monitor, fn(_down) { Error(Nil) })
    |> process.selector_receive(within: start_timeout_ms)
  process.demonitor_process(monitor)
  case started {
    Ok(Ok(Ok(control))) ->
      stream.StreamHandle(events: outer, cancel: fn() {
        process.send(control, Cancel)
      })
    Ok(Ok(Error(reason))) -> failed_handle(outer, reason)
    Ok(Error(Nil)) -> failed_handle(outer, "provider relay guard exited")
    Error(Nil) -> {
      process.kill(guard)
      failed_handle(outer, "provider relay guard did not start in time")
    }
  }
}

fn failed_handle(
  outer: Subject(stream.StreamEvent),
  reason: String,
) -> stream.StreamHandle {
  process.send(
    outer,
    stream.Failed(error: stream.TransportFailed(reason: reason)),
  )
  stream.StreamHandle(events: outer, cancel: fn() { Nil })
}

fn forward(
  inner: stream.StreamHandle,
  worker: Pid,
  outer: Subject(stream.StreamEvent),
  consumer: Pid,
  control: Subject(Control),
  relayed: Subject(stream.StreamEvent),
  consumer_monitor: process.Monitor,
  worker_monitor: process.Monitor,
) -> Nil {
  let selector =
    guard_selector(control, relayed, consumer_monitor, worker_monitor)
  case process.selector_receive_forever(selector) {
    Relayed(event) ->
      case process.is_alive(consumer) {
        False -> stop_relay(inner, worker, consumer_monitor, worker_monitor)
        True -> {
          process.send(outer, event)
          case event {
            stream.Delta(..) ->
              forward(
                inner,
                worker,
                outer,
                consumer,
                control,
                relayed,
                consumer_monitor,
                worker_monitor,
              )
            stream.Settled(..) | stream.Failed(..) ->
              forget_relay(consumer_monitor, worker_monitor)
          }
        }
      }
    ConsumerDown(_down) ->
      stop_relay(inner, worker, consumer_monitor, worker_monitor)
    WorkerDown(_down) -> {
      stream.cancel(inner)
      process.demonitor_process(consumer_monitor)
      process.send(
        outer,
        stream.Failed(error: stream.TransportFailed(
          reason: "provider relay worker stopped before a terminal response",
        )),
      )
    }
    CancelRequested -> {
      stream.cancel(inner)
      let _timer = process.send_after(control, cancel_grace_ms, CancelDeadline)
      forward_cancelling(
        inner,
        worker,
        outer,
        control,
        relayed,
        consumer_monitor,
        worker_monitor,
      )
    }
    CancelExpired ->
      forward(
        inner,
        worker,
        outer,
        consumer,
        control,
        relayed,
        consumer_monitor,
        worker_monitor,
      )
  }
}

fn forward_cancelling(
  inner: stream.StreamHandle,
  worker: Pid,
  outer: Subject(stream.StreamEvent),
  control: Subject(Control),
  relayed: Subject(stream.StreamEvent),
  consumer_monitor: process.Monitor,
  worker_monitor: process.Monitor,
) -> Nil {
  let selector =
    guard_selector(control, relayed, consumer_monitor, worker_monitor)
  case process.selector_receive_forever(selector) {
    Relayed(event) ->
      case event {
        stream.Delta(..) ->
          forward_cancelling(
            inner,
            worker,
            outer,
            control,
            relayed,
            consumer_monitor,
            worker_monitor,
          )
        stream.Settled(..) | stream.Failed(..) -> {
          process.send(outer, event)
          forget_relay(consumer_monitor, worker_monitor)
        }
      }
    ConsumerDown(_down) ->
      stop_relay(inner, worker, consumer_monitor, worker_monitor)
    WorkerDown(_down) | CancelExpired -> {
      stop_relay(inner, worker, consumer_monitor, worker_monitor)
      process.send(outer, stream.Failed(error: stream.CancellationUnconfirmed))
    }
    CancelRequested ->
      forward_cancelling(
        inner,
        worker,
        outer,
        control,
        relayed,
        consumer_monitor,
        worker_monitor,
      )
  }
}

fn guard_selector(
  control: Subject(Control),
  relayed: Subject(stream.StreamEvent),
  consumer_monitor: process.Monitor,
  worker_monitor: process.Monitor,
) -> process.Selector(GuardEvent) {
  process.new_selector()
  |> process.select_map(relayed, Relayed)
  |> process.select_map(control, fn(message) {
    case message {
      Cancel -> CancelRequested
      CancelDeadline -> CancelExpired
    }
  })
  |> process.select_specific_monitor(consumer_monitor, ConsumerDown)
  |> process.select_specific_monitor(worker_monitor, WorkerDown)
}

fn stop_relay(
  inner: stream.StreamHandle,
  worker: Pid,
  consumer_monitor: process.Monitor,
  worker_monitor: process.Monitor,
) -> Nil {
  stream.cancel(inner)
  process.kill(worker)
  forget_relay(consumer_monitor, worker_monitor)
}

fn forget_relay(
  consumer_monitor: process.Monitor,
  worker_monitor: process.Monitor,
) -> Nil {
  process.demonitor_process(consumer_monitor)
  process.demonitor_process(worker_monitor)
}
