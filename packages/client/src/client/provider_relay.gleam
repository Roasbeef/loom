//// A cancellation-transparent wrapper around one provider stream.
////
//// `prepare` returns a minimal custodian while its guard remains parked. Once
//// the caller has published that owner, the begin permit lets the guard adopt
//// an observer and the inner stream before starting either one. The guard
//// remains the inner request's direct consumer, while the second process runs
//// only the synchronous observer callback. This continuity is the important
//// part: a guard crash cannot discard the inner `StreamHandle`, and an
//// observer crash cannot erase the witness that still owns cancellation.
////
//// Explicit cancellation enters through the guard. It is handed to the inner
//// owner, then the guard waits one fixed grace timer for the owner-authored
//// terminal. The timer is scheduled once, so a stream of late deltas cannot
//// extend teardown indefinitely. If no terminal arrives, the guard reports
//// `CancellationUnconfirmed`; the custodian nevertheless remains alive until
//// the guard, observer, and inner owner drain. Its public pid is therefore a
//// transitive teardown acknowledgement rather than another working actor.
//// The synchronous `wrap` facade waits only until the inner owner is adopted,
//// preserving the older promise that cancellation is usable when it returns.

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
  Begin(BeginPermit)
  StartConsumerDown(process.Down)
  StartCancelled
}

type BeginPermit {
  BeginPermit(owner: custodian.Custodian, acknowledged: Subject(Nil))
}

type ObserverMessage {
  Observe(stream.StreamEvent, acknowledged: Subject(Nil))
}

type ObserverEvent {
  ObserverCommand(ObserverMessage)
  ObserverCreatorDown(process.Down)
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

// This private type gives each liveness check the meaning needed by the relay:
// whether forwarding remains useful, rather than merely exposing a raw Boolean.
type ConsumerLiveness {
  ConsumerAlive
  ConsumerGone
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
  prepare(surface, spec, observe)
  |> stream.start_prepared
}

/// Prepares an observed provider request without starting its inner stream.
///
/// The returned owner covers the relay guard and observer. A caller must
/// publish that owner before invoking `begin`, which in turn lets the guard
/// prepare, adopt, and only then start the inner provider request.
///
/// ## Examples
///
/// ```gleam
/// let prepared = provider_relay.prepare(surface, request, observe)
/// let handle = stream.start_prepared(prepared)
/// ```
///
pub fn prepare(
  surface: effects.ProviderSurface,
  spec: effects.RequestSpec,
  observe: fn(stream.StreamEvent) -> Nil,
) -> stream.PreparedStream {
  let consumer = process.self()
  let outer = process.new_subject()
  let ready = process.new_subject()
  let guard =
    process.spawn_unlinked(fn() {
      guard(surface, spec, observe, consumer, outer, ready)
    })
  await_prepared(outer, ready, guard, consumer)
}

fn guard(
  surface: effects.ProviderSurface,
  spec: effects.RequestSpec,
  observe: fn(stream.StreamEvent) -> Nil,
  consumer: Pid,
  outer: Subject(stream.StreamEvent),
  ready: Subject(#(Subject(Control), Subject(BeginPermit))),
) -> Nil {
  let control = process.new_subject()
  let begin = process.new_subject()
  let consumer_monitor = process.monitor(consumer)
  process.send(ready, #(control, begin))
  let start =
    process.new_selector()
    |> process.select_map(begin, Begin)
    |> process.select_map(control, fn(_cancel) { StartCancelled })
    |> process.select_specific_monitor(consumer_monitor, StartConsumerDown)
    |> process.selector_receive_forever()
  case start {
    StartCancelled | StartConsumerDown(_down) ->
      process.demonitor_process(consumer_monitor)
    Begin(BeginPermit(owner:, acknowledged:)) -> {
      // Publish the observer before the inner request begins. Cancellation can
      // reach the public custodian as soon as `wrap` returns; if it wins this
      // startup race, an owner-authored terminal must still pass through the
      // observer before it reaches the caller.
      let #(observer, observer_control, observer_monitor) =
        start_observer(observe, process.self())
      case custodian.adopt_leaf(owner, observer, fn() { Nil }) {
        False -> {
          // Rejection leaves startup with the guard. Returning drops the
          // creator monitor normally, so the still-parked observer follows
          // without manufacturing an abnormal child exit.
          process.demonitor_process(consumer_monitor)
          process.demonitor_process(observer_monitor)
          process.send(acknowledged, Nil)
        }
        True -> {
          let stream.PreparedStream(handle: inner, begin: begin_inner) =
            effects.prepare_provider(surface, spec)
          let drain_witness = stream.watch_drain(inner)
          case custodian.adopt(owner, inner.owner, inner.cancel) {
            False -> {
              process.send(acknowledged, Nil)
              cancel_during_start(
                inner,
                drain_witness,
                observer,
                observer_control,
                outer,
                control,
                consumer_monitor,
                observer_monitor,
              )
            }
            True -> {
              begin_inner()
              process.send(acknowledged, Nil)
              forward(
                inner,
                drain_witness,
                observer,
                observer_control,
                outer,
                consumer,
                control,
                consumer_monitor,
                observer_monitor,
                effects.provider_timeout_ms(surface) + 100,
              )
            }
          }
        }
      }
    }
  }
}

fn start_observer(
  observe: fn(stream.StreamEvent) -> Nil,
  creator: Pid,
) -> #(Pid, Subject(ObserverMessage), Monitor) {
  let ready = process.new_subject()
  let observer =
    process.spawn_unlinked(fn() {
      let control = process.new_subject()
      process.send(ready, control)
      observer_loop(control, observe, process.monitor(creator))
    })
  let control = process.receive_forever(ready)
  #(observer, control, process.monitor(observer))
}

fn observer_loop(
  control: Subject(ObserverMessage),
  observe: fn(stream.StreamEvent) -> Nil,
  creator_monitor: Monitor,
) -> Nil {
  let event =
    process.new_selector()
    |> process.select_map(control, ObserverCommand)
    |> process.select_specific_monitor(creator_monitor, ObserverCreatorDown)
    |> process.selector_receive_forever()
  case event {
    ObserverCommand(Observe(event, acknowledged:)) -> {
      observe(event)
      process.send(acknowledged, Nil)
      observer_loop(control, observe, creator_monitor)
    }

    // Before adoption, the guard is the observer's only reachable owner.
    // After adoption, the same edge closes the leaf promptly while the public
    // custodian still adjudicates whether the guard itself drained normally.
    ObserverCreatorDown(_down) -> process.demonitor_process(creator_monitor)
  }
}

fn await_prepared(
  outer: Subject(stream.StreamEvent),
  ready: Subject(#(Subject(Control), Subject(BeginPermit))),
  guard: Pid,
  consumer: Pid,
) -> stream.PreparedStream {
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
      stream.PreparedStream(
        handle: stream.owned(
          events: outer,
          owner: custodian.owner(owner),
          cancel: fn() { custodian.cancel(owner) },
        ),
        begin: fn() { begin_guard(begin, owner, guard) },
      )
    }
    Ok(Error(Nil)) -> failed_prepared(outer, "provider relay guard exited")
    Error(Nil) -> {
      process.kill(guard)
      failed_prepared(outer, "provider relay guard did not start in time")
    }
  }
}

// The compatibility `request` facade returns the prepared handle immediately
// after invoking this callback. Waiting for the guard's acknowledgement keeps
// that return equivalent to the old contract: an immediate cancellation can
// already reach the adopted inner stream.
fn begin_guard(
  begin: Subject(BeginPermit),
  owner: custodian.Custodian,
  guard: Pid,
) -> Nil {
  let acknowledged = process.new_subject()
  let monitor = process.monitor(guard)
  process.send(begin, BeginPermit(owner:, acknowledged:))
  let _started =
    process.new_selector()
    |> process.select_map(acknowledged, fn(_nil) { Nil })
    |> process.select_specific_monitor(monitor, fn(_down) { Nil })
    |> process.selector_receive(within: start_timeout_ms)
  process.demonitor_process(monitor)
  Nil
}

fn failed_prepared(
  outer: Subject(stream.StreamEvent),
  reason: String,
) -> stream.PreparedStream {
  process.send(
    outer,
    stream.Failed(error: stream.TransportFailed(reason: reason)),
  )
  stream.PreparedStream(
    handle: stream.immediate(events: outer, cancel: fn() { Nil }),
    begin: fn() { Nil },
  )
}

fn forward(
  inner: stream.StreamHandle,
  drain_witness: stream.DrainWitness,
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
      fail_and_drain(
        inner,
        drain_witness,
        observer,
        outer,
        consumer_monitor,
        observer_monitor,
      )
    Ok(Inner(event)) ->
      observe_forwarding(
        event,
        inner,
        drain_witness,
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
        drain_witness,
        observer,
        consumer_monitor,
        observer_monitor,
      )
    Ok(ObserverDown(_down)) ->
      fail_and_drain(
        inner,
        drain_witness,
        observer,
        outer,
        consumer_monitor,
        observer_monitor,
      )
    Ok(CancelRequested) -> {
      stream.cancel(inner)
      let _timer = process.send_after(control, cancel_grace_ms, CancelDeadline)
      forward_cancelling(
        inner,
        drain_witness,
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
        drain_witness,
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
  drain_witness: stream.DrainWitness,
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
      // Decide liveness and event shape together. Besides keeping the state
      // transition visible in one place, this prevents another liveness check
      // from enclosing the entire event protocol and hiding its terminal arm.
      case consumer_liveness(consumer), event {
        ConsumerGone, _event ->
          stop_for_dead_consumer(
            inner,
            drain_witness,
            observer,
            consumer_monitor,
            observer_monitor,
          )
        ConsumerAlive, stream.Delta(..) -> {
          process.send(outer, event)
          forward(
            inner,
            drain_witness,
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
        ConsumerAlive, stream.Settled(..) | ConsumerAlive, stream.Failed(..) -> {
          finish_relay(
            drain_witness,
            observer,
            consumer_monitor,
            observer_monitor,
          )
          case consumer_liveness(consumer) {
            ConsumerAlive -> process.send(outer, event)
            ConsumerGone -> Nil
          }
        }
      }
    ObservationConsumerDown(_down) ->
      stop_for_dead_consumer(
        inner,
        drain_witness,
        observer,
        consumer_monitor,
        observer_monitor,
      )
    ObservationObserverDown(_down) ->
      fail_and_drain(
        inner,
        drain_witness,
        observer,
        outer,
        consumer_monitor,
        observer_monitor,
      )
    ObservationCancelRequested -> {
      stream.cancel(inner)
      let _timer = process.send_after(control, cancel_grace_ms, CancelDeadline)
      observe_cancelling(
        event,
        acknowledged,
        inner,
        drain_witness,
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
        drain_witness,
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
  drain_witness: stream.DrainWitness,
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
        drain_witness,
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
        drain_witness,
        observer,
        consumer_monitor,
        observer_monitor,
      )
    ObserverDown(_down) | CancelExpired ->
      cancellation_unconfirmed(
        inner,
        drain_witness,
        observer,
        outer,
        consumer_monitor,
        observer_monitor,
      )
    CancelRequested ->
      forward_cancelling(
        inner,
        drain_witness,
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
  drain_witness: stream.DrainWitness,
  observer: Pid,
  observer_control: Subject(ObserverMessage),
  outer: Subject(stream.StreamEvent),
  control: Subject(Control),
  consumer_monitor: Monitor,
  observer_monitor: Monitor,
) -> Nil {
  stream.cancel(inner)

  // Reuse the ordinary cancelling state machine so startup cancellation has
  // the same single scheduled deadline. `await_terminal` uses an idle timeout
  // and would let each late delta silently renew this grace period.
  let _timer = process.send_after(control, cancel_grace_ms, CancelDeadline)
  forward_cancelling(
    inner,
    drain_witness,
    observer,
    observer_control,
    outer,
    control,
    consumer_monitor,
    observer_monitor,
  )
}

fn consumer_liveness(consumer: Pid) -> ConsumerLiveness {
  case process.is_alive(consumer) {
    True -> ConsumerAlive
    False -> ConsumerGone
  }
}

fn observe_cancelling(
  event: stream.StreamEvent,
  acknowledged: Subject(Nil),
  inner: stream.StreamHandle,
  drain_witness: stream.DrainWitness,
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
            drain_witness,
            observer,
            observer_control,
            outer,
            control,
            consumer_monitor,
            observer_monitor,
          )
        stream.Settled(..) | stream.Failed(..) -> {
          finish_relay(
            drain_witness,
            observer,
            consumer_monitor,
            observer_monitor,
          )
          process.send(outer, event)
        }
      }
    ObservationConsumerDown(_down) ->
      stop_for_dead_consumer(
        inner,
        drain_witness,
        observer,
        consumer_monitor,
        observer_monitor,
      )
    ObservationObserverDown(_down) | ObservationCancelExpired ->
      cancellation_unconfirmed(
        inner,
        drain_witness,
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
        drain_witness,
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
  drain_witness: stream.DrainWitness,
  _observer: Pid,
  outer: Subject(stream.StreamEvent),
  consumer_monitor: Monitor,
  observer_monitor: Monitor,
) -> Nil {
  release_observer(observer_monitor)
  stream.cancel(inner)
  case stream.await_drain(drain_witness, within: cancel_grace_ms) {
    stream.Drained ->
      process.send(
        outer,
        stream.Failed(error: stream.TransportFailed(
          reason: "provider relay worker stopped before a terminal response",
        )),
      )
    stream.TimedOut -> {
      process.send(outer, stream.Failed(error: stream.CancellationUnconfirmed))
      require_drain(drain_witness)
    }
    stream.ProofLost -> {
      process.send(outer, stream.Failed(error: stream.DrainProofLost))

      // Returning normally here would let the outer custodian certify a
      // subtree whose transitive owner died abnormally.
      process.kill(process.self())
    }
  }
  forget_relay(consumer_monitor, observer_monitor)
}

fn cancellation_unconfirmed(
  inner: stream.StreamHandle,
  drain_witness: stream.DrainWitness,
  _observer: Pid,
  outer: Subject(stream.StreamEvent),
  consumer_monitor: Monitor,
  observer_monitor: Monitor,
) -> Nil {
  release_observer(observer_monitor)
  process.send(outer, stream.Failed(error: stream.CancellationUnconfirmed))
  stream.cancel(inner)
  require_drain(drain_witness)
  forget_relay(consumer_monitor, observer_monitor)
}

fn stop_for_dead_consumer(
  inner: stream.StreamHandle,
  drain_witness: stream.DrainWitness,
  _observer: Pid,
  consumer_monitor: Monitor,
  observer_monitor: Monitor,
) -> Nil {
  // Consumer death closes the observation boundary before cancellation can
  // produce a terminal event. This keeps wrapper-local side effects, such as
  // summary recording, from outliving the consumer that requested them.
  release_observer(observer_monitor)
  stream.cancel(inner)
  require_drain(drain_witness)
  forget_relay(consumer_monitor, observer_monitor)
}

fn finish_relay(
  drain_witness: stream.DrainWitness,
  _observer: Pid,
  consumer_monitor: Monitor,
  observer_monitor: Monitor,
) -> Nil {
  require_drain(drain_witness)
  release_observer(observer_monitor)
  forget_relay(consumer_monitor, observer_monitor)
}

// The observer's creator monitor, rather than an untyped kill, closes this
// leaf. The guard cannot synchronously await that edge because the observer
// learns of creator death only after the guard returns. The public custodian
// keeps its independent monitor and therefore remains the drain witness.
fn release_observer(monitor: Monitor) -> Nil {
  process.demonitor_process(monitor)
}

fn forget_relay(consumer_monitor: Monitor, observer_monitor: Monitor) -> Nil {
  process.demonitor_process(consumer_monitor)
  process.demonitor_process(observer_monitor)
}

// A transitive owner speaks for work beneath it. Only its normal Down permits
// this relay to retire normally; otherwise the relay must preserve the lost
// proof as an abnormal Down for its own custodian.
fn require_drain(drain_witness: stream.DrainWitness) -> Nil {
  case stream.await_drain_forever(drain_witness) {
    stream.Drained -> Nil
    stream.TimedOut | stream.ProofLost -> process.kill(process.self())
  }
}
