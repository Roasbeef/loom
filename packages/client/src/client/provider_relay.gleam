//// A cancellation-transparent wrapper around one provider stream.
////
//// Client composition layers use this when they must observe events before
//// forwarding them. The direct consumer owns the outer subject; this relay
//// creates the inner handle, monitors that consumer, and propagates both
//// explicit cancellation and consumer death inward. `observe` runs before
//// the same event is forwarded, which preserves the summary sink's
//// record-before-terminal rule.

import gleam/erlang/process.{type Pid, type Subject}
import provider/stream
import runtime/effects

const start_timeout_ms = 5000

type RelayEvent {
  InnerEvent(stream.StreamEvent)
  ConsumerDown(process.Down)
}

/// Wraps one provider request with a synchronous event observer.
///
/// The observer must return promptly and must not receive from the stream.
/// Cancellation remains owned by the inner request owner; the relay only
/// carries that capability across the composition boundary.
pub fn wrap(
  surface: effects.ProviderSurface,
  spec: effects.RequestSpec,
  observe: fn(stream.StreamEvent) -> Nil,
) -> stream.StreamHandle {
  let consumer = process.self()
  let outer = process.new_subject()
  let ready = process.new_subject()
  let relay =
    process.spawn_unlinked(fn() {
      let consumer_monitor = process.monitor(consumer)
      let inner = surface.request(spec)
      process.send(ready, inner)
      forward(
        inner,
        outer,
        consumer,
        consumer_monitor,
        observe,
        surface.timeout_ms + 100,
      )
    })
  await_handle(outer, ready, relay)
}

fn await_handle(
  outer: Subject(stream.StreamEvent),
  ready: Subject(stream.StreamHandle),
  relay: Pid,
) -> stream.StreamHandle {
  let monitor = process.monitor(relay)
  let started =
    process.new_selector()
    |> process.select_map(ready, Ok)
    |> process.select_specific_monitor(monitor, fn(_down) { Error(Nil) })
    |> process.selector_receive(within: start_timeout_ms)
  process.demonitor_process(monitor)
  case started {
    Ok(Ok(inner)) ->
      stream.StreamHandle(events: outer, cancel: fn() { stream.cancel(inner) })
    Ok(Error(Nil)) -> failed_handle(outer, "provider relay exited before start")
    Error(Nil) -> {
      process.kill(relay)
      failed_handle(outer, "provider relay did not start in time")
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
  outer: Subject(stream.StreamEvent),
  consumer: Pid,
  consumer_monitor: process.Monitor,
  observe: fn(stream.StreamEvent) -> Nil,
  timeout_ms: Int,
) -> Nil {
  let selector =
    process.new_selector()
    |> process.select_map(inner.events, InnerEvent)
    |> process.select_specific_monitor(consumer_monitor, ConsumerDown)
  case process.selector_receive(selector, within: timeout_ms) {
    Error(Nil) -> {
      process.demonitor_process(consumer_monitor)
      stream.cancel(inner)
    }
    Ok(ConsumerDown(_down)) -> stream.cancel(inner)
    Ok(InnerEvent(event)) ->
      case process.is_alive(consumer) {
        False -> {
          process.demonitor_process(consumer_monitor)
          stream.cancel(inner)
        }
        True -> {
          observe(event)
          process.send(outer, event)
          case event {
            stream.Delta(..) ->
              forward(
                inner,
                outer,
                consumer,
                consumer_monitor,
                observe,
                timeout_ms,
              )
            stream.Settled(..) | stream.Failed(..) ->
              process.demonitor_process(consumer_monitor)
          }
        }
      }
  }
}
