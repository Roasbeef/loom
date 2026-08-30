//// A cancellation-transparent wrapper around one provider stream.
////
//// A minimal custodian is published before the guard is allowed to start the
//// inner request. The guard remains that request's direct consumer, while a
//// second process runs only the synchronous observer callback. Both are
//// adopted by the custodian before their work begins. This continuity is the
//// important part: a guard crash cannot discard the inner `StreamHandle`, and
//// an observer crash cannot erase the witness that still owns cancellation.
////
//// Explicit cancellation enters through the guard. It is handed to the inner
//// owner, then the guard waits one fixed grace timer for the owner-authored
//// terminal. The timer is scheduled once, so a stream of late deltas cannot
//// extend teardown indefinitely. If no terminal arrives, the guard reports
//// `CancellationUnconfirmed`; the custodian nevertheless remains alive until
//// the guard, observer, and inner owner drain. Its public pid is therefore a
//// transitive teardown acknowledgement rather than another working actor.

import gleam/erlang/process.{type Monitor, type Pid, type Subject}
import provider/custodian
import provider/stream
import runtime/effects

const start_timeout_ms = 5000

const cancel_grace_ms = 1500

type Control {
  Cancel
  CancelDeadline
}

type StartEvent {
  Begin(custodian.Custodian)
  StartConsumerDown(process.Down)
}

type ObserverMessage {
  Observe(stream.StreamEvent, acknowledged: Subject(Nil))
}

type RelayEvent {
  Inner(stream.StreamEvent)
  ConsumerDown(process.Down)
  ObserverDown(process.Down)
  CancelRequested
  CancelExpired
}

type ObservationEvent {
  Observed
  ObservationConsumerDown(process.Down)
  ObservationObserverDown(process.Down)
  ObservationCancelRequested
  ObservationCancelExpired
}

/// Wraps one provider request with a synchronous event observer.
///
/// The observer must return promptly and must not receive from the stream.
/// Cancellation remains owned by the inner request owner; this wrapper carries
/// its capability and terminal acknowledgement across the composition boundary.
///
/// ## Examples
///
/// ```gleam
/// let wrapped = provider_relay.wrap(surface, request, fn(event) {
///   summaries.record(event)
/// })
/// // wrapped.owner stays alive until the inner provider subtree drains.
/// ```
///
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
  await_handle(outer, ready, guard, consumer)
}

fn guard(
  surface: effects.ProviderSurface,
  spec: effects.RequestSpec,
  observe: fn(stream.StreamEvent) -> Nil,
  consumer: Pid,
  outer: Subject(stream.StreamEvent),
  ready: Subject(#(Subject(Control), Subject(custodian.Custodian))),
) -> Nil {
  let control = process.new_subject()
  let begin = process.new_subject()
  let consumer_monitor = process.monitor(consumer)
  process.send(ready, #(control, begin))
  let start =
    process.new_selector()
    |> process.select_map(begin, Begin)
    |> process.select_specific_monitor(consumer_monitor, StartConsumerDown)
    |> process.selector_receive_forever()
  case start {
    StartConsumerDown(_down) -> process.demonitor_process(consumer_monitor)
    Begin(owner) -> {
      // Publish the observer before the inner request begins. Cancellation can
      // reach the public custodian as soon as `wrap` returns; if it wins this
      // startup race, an owner-authored terminal must still pass through the
      // observer before it reaches the caller.
      let #(observer, observer_control, observer_monitor) =
        start_observer(observe)
      let _observer_permit =
        custodian.adopt_owner(owner, observer, fn() { process.kill(observer) })
      let inner = surface.request(spec)
      case custodian.adopt(owner, inner.owner, inner.cancel) {
        False -> {
          cancel_during_start(
            inner,
            observer,
            observer_control,
            outer,
            consumer,
            consumer_monitor,
            observer_monitor,
          )
        }
        True ->
          forward(
            inner,
            observer,
            observer_control,
            outer,
            consumer,
            control,
            consumer_monitor,
            observer_monitor,
            surface.timeout_ms + 100,
          )
      }
    }
  }
}

fn start_observer(
  observe: fn(stream.StreamEvent) -> Nil,
) -> #(Pid, Subject(ObserverMessage), Monitor) {
  let ready = process.new_subject()
  let observer =
    process.spawn_unlinked(fn() {
      let control = process.new_subject()
      process.send(ready, control)
      observer_loop(control, observe)
    })
  let control = process.receive_forever(ready)
  #(observer, control, process.monitor(observer))
}

fn observer_loop(
  control: Subject(ObserverMessage),
  observe: fn(stream.StreamEvent) -> Nil,
) -> Nil {
  let Observe(event, acknowledged:) = process.receive_forever(control)
  observe(event)
  process.send(acknowledged, Nil)
  observer_loop(control, observe)
}

fn await_handle(
  outer: Subject(stream.StreamEvent),
  ready: Subject(#(Subject(Control), Subject(custodian.Custodian))),
  guard: Pid,
  consumer: Pid,
) -> stream.StreamHandle {
  let monitor = process.monitor(guard)
  let started =
    process.new_selector()
    |> process.select_map(ready, Ok)
    |> process.select_specific_monitor(monitor, fn(_down) { Error(Nil) })
    |> process.selector_receive(within: start_timeout_ms)
  process.demonitor_process(monitor)
  case started {
    Ok(Ok(#(control, begin))) -> {
      let owner = custodian.start(guard, control, Cancel, consumer)
      process.send(begin, owner)
      stream.owned(events: outer, owner: custodian.owner(owner), cancel: fn() {
        custodian.cancel(owner)
      })
    }
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
  stream.immediate(events: outer, cancel: fn() { Nil })
}

fn forward(
  inner: stream.StreamHandle,
  observer: Pid,
  observer_control: Subject(ObserverMessage),
  outer: Subject(stream.StreamEvent),
  consumer: Pid,
  control: Subject(Control),
  consumer_monitor: Monitor,
  observer_monitor: Monitor,
  timeout_ms: Int,
) -> Nil {
  let selector =
    relay_selector(inner, control, consumer_monitor, observer_monitor)
  case process.selector_receive(selector, within: timeout_ms) {
    Error(Nil) ->
      fail_and_drain(inner, observer, outer, consumer_monitor, observer_monitor)
    Ok(Inner(event)) ->
      observe_forwarding(
        event,
        inner,
        observer,
        observer_control,
        outer,
        consumer,
        control,
        consumer_monitor,
        observer_monitor,
        timeout_ms,
      )
    Ok(ConsumerDown(_down)) ->
      stop_for_dead_consumer(
        inner,
        observer,
        consumer_monitor,
        observer_monitor,
      )
    Ok(ObserverDown(_down)) ->
      fail_and_drain(inner, observer, outer, consumer_monitor, observer_monitor)
    Ok(CancelRequested) -> {
      stream.cancel(inner)
      let _timer = process.send_after(control, cancel_grace_ms, CancelDeadline)
      forward_cancelling(
        inner,
        observer,
        observer_control,
        outer,
        control,
        consumer_monitor,
        observer_monitor,
      )
    }
    Ok(CancelExpired) ->
      forward(
        inner,
        observer,
        observer_control,
        outer,
        consumer,
        control,
        consumer_monitor,
        observer_monitor,
        timeout_ms,
      )
  }
}

fn observe_forwarding(
  event: stream.StreamEvent,
  inner: stream.StreamHandle,
  observer: Pid,
  observer_control: Subject(ObserverMessage),
  outer: Subject(stream.StreamEvent),
  consumer: Pid,
  control: Subject(Control),
  consumer_monitor: Monitor,
  observer_monitor: Monitor,
  timeout_ms: Int,
) -> Nil {
  let acknowledged = process.new_subject()
  process.send(observer_control, Observe(event, acknowledged:))
  case observation(acknowledged, control, consumer_monitor, observer_monitor) {
    Observed ->
      case process.is_alive(consumer) {
        False ->
          stop_for_dead_consumer(
            inner,
            observer,
            consumer_monitor,
            observer_monitor,
          )
        True -> {
          process.send(outer, event)
          case event {
            stream.Delta(..) ->
              forward(
                inner,
                observer,
                observer_control,
                outer,
                consumer,
                control,
                consumer_monitor,
                observer_monitor,
                timeout_ms,
              )
            stream.Settled(..) | stream.Failed(..) ->
              finish_relay(inner, observer, consumer_monitor, observer_monitor)
          }
        }
      }
    ObservationConsumerDown(_down) ->
      stop_for_dead_consumer(
        inner,
        observer,
        consumer_monitor,
        observer_monitor,
      )
    ObservationObserverDown(_down) ->
      fail_and_drain(inner, observer, outer, consumer_monitor, observer_monitor)
    ObservationCancelRequested -> {
      stream.cancel(inner)
      let _timer = process.send_after(control, cancel_grace_ms, CancelDeadline)
      observe_cancelling(
        event,
        acknowledged,
        inner,
        observer,
        observer_control,
        outer,
        control,
        consumer_monitor,
        observer_monitor,
      )
    }
    ObservationCancelExpired ->
      observe_forwarding(
        event,
        inner,
        observer,
        observer_control,
        outer,
        consumer,
        control,
        consumer_monitor,
        observer_monitor,
        timeout_ms,
      )
  }
}

fn forward_cancelling(
  inner: stream.StreamHandle,
  observer: Pid,
  observer_control: Subject(ObserverMessage),
  outer: Subject(stream.StreamEvent),
  control: Subject(Control),
  consumer_monitor: Monitor,
  observer_monitor: Monitor,
) -> Nil {
  let selector =
    relay_selector(inner, control, consumer_monitor, observer_monitor)
  case process.selector_receive_forever(selector) {
    Inner(event) -> {
      let acknowledged = process.new_subject()
      process.send(observer_control, Observe(event, acknowledged:))
      observe_cancelling(
        event,
        acknowledged,
        inner,
        observer,
        observer_control,
        outer,
        control,
        consumer_monitor,
        observer_monitor,
      )
    }
    ConsumerDown(_down) ->
      stop_for_dead_consumer(
        inner,
        observer,
        consumer_monitor,
        observer_monitor,
      )
    ObserverDown(_down) | CancelExpired ->
      cancellation_unconfirmed(
        inner,
        observer,
        outer,
        consumer_monitor,
        observer_monitor,
      )
    CancelRequested ->
      forward_cancelling(
        inner,
        observer,
        observer_control,
        outer,
        control,
        consumer_monitor,
        observer_monitor,
      )
  }
}

fn cancel_during_start(
  inner: stream.StreamHandle,
  observer: Pid,
  observer_control: Subject(ObserverMessage),
  outer: Subject(stream.StreamEvent),
  consumer: Pid,
  consumer_monitor: Monitor,
  observer_monitor: Monitor,
) -> Nil {
  stream.cancel(inner)
  let terminal = stream.await_terminal(inner, within: cancel_grace_ms)
  case terminal, process.is_alive(consumer) {
    Ok(#(_deltas, event)), True -> {
      let acknowledged = process.new_subject()
      process.send(observer_control, Observe(event, acknowledged:))
      let observed =
        process.new_selector()
        |> process.select_map(acknowledged, fn(_acknowledged) { True })
        |> process.select_specific_monitor(consumer_monitor, fn(_down) { False })
        |> process.select_specific_monitor(observer_monitor, fn(_down) { False })
        |> process.selector_receive(within: cancel_grace_ms)
      case observed {
        Ok(True) -> process.send(outer, event)
        Ok(False) | Error(Nil) ->
          case process.is_alive(consumer) {
            True ->
              process.send(
                outer,
                stream.Failed(error: stream.CancellationUnconfirmed),
              )
            False -> Nil
          }
      }
    }
    Error(Nil), True ->
      process.send(outer, stream.Failed(error: stream.CancellationUnconfirmed))
    _, False -> Nil
  }
  stream.await_stopped_forever(inner)
  stop_observer(observer, observer_monitor)
  forget_relay(consumer_monitor, observer_monitor)
}

fn observe_cancelling(
  event: stream.StreamEvent,
  acknowledged: Subject(Nil),
  inner: stream.StreamHandle,
  observer: Pid,
  observer_control: Subject(ObserverMessage),
  outer: Subject(stream.StreamEvent),
  control: Subject(Control),
  consumer_monitor: Monitor,
  observer_monitor: Monitor,
) -> Nil {
  case observation(acknowledged, control, consumer_monitor, observer_monitor) {
    Observed ->
      case event {
        stream.Delta(..) ->
          forward_cancelling(
            inner,
            observer,
            observer_control,
            outer,
            control,
            consumer_monitor,
            observer_monitor,
          )
        stream.Settled(..) | stream.Failed(..) -> {
          process.send(outer, event)
          finish_relay(inner, observer, consumer_monitor, observer_monitor)
        }
      }
    ObservationConsumerDown(_down) ->
      stop_for_dead_consumer(
        inner,
        observer,
        consumer_monitor,
        observer_monitor,
      )
    ObservationObserverDown(_down) | ObservationCancelExpired ->
      cancellation_unconfirmed(
        inner,
        observer,
        outer,
        consumer_monitor,
        observer_monitor,
      )
    ObservationCancelRequested ->
      observe_cancelling(
        event,
        acknowledged,
        inner,
        observer,
        observer_control,
        outer,
        control,
        consumer_monitor,
        observer_monitor,
      )
  }
}

fn observation(
  acknowledged: Subject(Nil),
  control: Subject(Control),
  consumer_monitor: Monitor,
  observer_monitor: Monitor,
) -> ObservationEvent {
  process.new_selector()
  |> process.select_map(acknowledged, fn(_acknowledged) { Observed })
  |> process.select_map(control, fn(message) {
    case message {
      Cancel -> ObservationCancelRequested
      CancelDeadline -> ObservationCancelExpired
    }
  })
  |> process.select_specific_monitor(consumer_monitor, ObservationConsumerDown)
  |> process.select_specific_monitor(observer_monitor, ObservationObserverDown)
  |> process.selector_receive_forever()
}

fn relay_selector(
  inner: stream.StreamHandle,
  control: Subject(Control),
  consumer_monitor: Monitor,
  observer_monitor: Monitor,
) -> process.Selector(RelayEvent) {
  process.new_selector()
  |> process.select_map(inner.events, Inner)
  |> process.select_map(control, fn(message) {
    case message {
      Cancel -> CancelRequested
      CancelDeadline -> CancelExpired
    }
  })
  |> process.select_specific_monitor(consumer_monitor, ConsumerDown)
  |> process.select_specific_monitor(observer_monitor, ObserverDown)
}

fn fail_and_drain(
  inner: stream.StreamHandle,
  observer: Pid,
  outer: Subject(stream.StreamEvent),
  consumer_monitor: Monitor,
  observer_monitor: Monitor,
) -> Nil {
  stop_observer(observer, observer_monitor)
  stream.cancel(inner)
  case stream.await_stopped(inner, within: cancel_grace_ms) {
    True ->
      process.send(
        outer,
        stream.Failed(error: stream.TransportFailed(
          reason: "provider relay worker stopped before a terminal response",
        )),
      )
    False -> {
      process.send(outer, stream.Failed(error: stream.CancellationUnconfirmed))
      stream.await_stopped_forever(inner)
    }
  }
  forget_relay(consumer_monitor, observer_monitor)
}

fn cancellation_unconfirmed(
  inner: stream.StreamHandle,
  observer: Pid,
  outer: Subject(stream.StreamEvent),
  consumer_monitor: Monitor,
  observer_monitor: Monitor,
) -> Nil {
  stop_observer(observer, observer_monitor)
  process.send(outer, stream.Failed(error: stream.CancellationUnconfirmed))
  stream.cancel(inner)
  stream.await_stopped_forever(inner)
  forget_relay(consumer_monitor, observer_monitor)
}

fn stop_for_dead_consumer(
  inner: stream.StreamHandle,
  observer: Pid,
  consumer_monitor: Monitor,
  observer_monitor: Monitor,
) -> Nil {
  // Consumer death closes the observation boundary before cancellation can
  // produce a terminal event. This keeps wrapper-local side effects, such as
  // summary recording, from outliving the consumer that requested them.
  stop_observer(observer, observer_monitor)
  stream.cancel(inner)
  stream.await_stopped_forever(inner)
  forget_relay(consumer_monitor, observer_monitor)
}

fn finish_relay(
  inner: stream.StreamHandle,
  observer: Pid,
  consumer_monitor: Monitor,
  observer_monitor: Monitor,
) -> Nil {
  stream.await_stopped_forever(inner)
  stop_observer(observer, observer_monitor)
  forget_relay(consumer_monitor, observer_monitor)
}

fn stop_observer(observer: Pid, monitor: Monitor) -> Nil {
  case process.is_alive(observer) {
    False -> Nil
    True -> {
      process.kill(observer)
      let _down =
        process.new_selector()
        |> process.select_specific_monitor(monitor, fn(_down) { Nil })
        |> process.selector_receive_forever()
      Nil
    }
  }
}

fn forget_relay(consumer_monitor: Monitor, observer_monitor: Monitor) -> Nil {
  process.demonitor_process(consumer_monitor)
  process.demonitor_process(observer_monitor)
}
