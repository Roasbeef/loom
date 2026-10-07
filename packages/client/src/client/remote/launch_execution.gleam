//// Original remote Launch native custody after the paused connection escapes.
////
//// The existing Broker alone clears and dispatches the SatelliteCommand. This
//// small owner pins its CallHandle before answering admission, retains actual
//// settlement independently of cap traffic, and closes the original bridge when
//// the invoking body dies. A native report never emits cap End or proves native
//// retirement. Both observation tasks run through weft; their drain and their
//// returned evidence remain separate.

import broker/broker
import codemode/enforcement
import codemode/run_channel as channel
import core/remote_tool
import executor/remote/launch_beam as bridge
import gleam/erlang/process
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import tools/tool
import weft
import weft/actor

/// Original local native owner; historical metadata cannot construct one.
@internal
pub opaque type Execution {
  Execution(commands: process.Subject(Message))
}

type Message {
  Settled(outcome: broker.CallOutcome)
  Cleared(result: Result(broker.CallHandle, broker.Refusal))
  Native(report: weft.Pulled(broker.CallOutcome, NativeFailure))
  Closed(report: weft.Pulled(channel.CloseResult, Nil))
  Close(reply: process.Subject(channel.CloseResult))
  ParentDied
  Expire
}

type NativeFailure {
  ClearanceRefused(refusal: broker.Refusal)
  ObservationLost
}

type CloseMode {
  Joining
  Abandoned
}

type ObserverDrain {
  Joined
  Lost
}

type State {
  State(
    subject: process.Subject(Message),
    original_broker: broker.Broker,
    original_bridge: bridge.Owner,
    handle: Option(broker.CallHandle),
    admission: Option(process.Subject(Result(Nil, broker.Refusal))),
    node: enforcement.Report,
    native_drain: Option(ObserverDrain),
    transport: Option(channel.CloseResult),
    transport_drain: Option(ObserverDrain),
    close_reply: Option(process.Subject(channel.CloseResult)),
    close_started: Option(CloseMode),
    cancellation: fn() -> Nil,
    selector: process.Selector(Message),
  )
}

/// Admits one original native call and pins its handle before returning.
/// The original deadline is on the owner's clock; executor deadlines never
/// enter this owner. Settlement observation alone has a six-second grace.
///
/// ## Examples
/// `start(broker, origin, spec, stream, parent, deadline, now, 1000, cancel)`.
@internal
pub fn start(
  original_broker: broker.Broker,
  origin: remote_tool.ChildOrigin,
  spec: broker.CallSpec,
  stream: bridge.Owner,
  parent: process.Pid,
  deadline: Int,
  now: fn() -> Int,
  clearance_ms: Int,
  cancellation: fn() -> Nil,
  finish_outer: fn() -> Result(Nil, Nil),
) -> Result(Execution, broker.Refusal) {
  let admission = process.new_subject()
  let started =
    actor.new_with_initialiser(1000, fn(subject) {
      let reports = process.new_subject()
      let monitor = process.monitor(parent)
      let selector =
        process.new_selector()
        |> process.select(subject)
        |> process.select_map(reports, Native)
        |> process.select_specific_monitor(monitor, fn(_) { ParentDied })

      // Clearance and event collection share one managed task. Its successful
      // clearance is sent to this owner before the caller can receive admission.
      let body = fn() {
        let events = process.new_subject()
        let cleared =
          broker.clear_call_from(
            original_broker,
            origin,
            spec,
            events: events,
            waiting: clearance_ms,
          )
        process.send(subject, Cleared(cleared))
        use _ <- result.try(cleared |> result.map_error(ClearanceRefused))
        use collected <- result.try(
          tool.collect_events(
            events,
            waiting: int.max(1, deadline - now()) + 6000,
          )
          |> result.replace_error(ObservationLost),
        )
        process.send(subject, Settled(collected.outcome))
        use Nil <- result.try(
          finish_outer() |> result.replace_error(ObservationLost),
        )
        Ok(collected.outcome)
      }
      let _ =
        weft.new([body])
        |> weft.deadline(int.max(1, deadline - now()) + 6000)
        |> weft.cancel_when_exits(process.self())
        |> weft.start_relayed(to: reports)
      Ok(
        actor.initialised(State(
          subject,
          original_broker,
          stream,
          None,
          Some(admission),
          enforcement.Unreported("original native settlement pending"),
          None,
          None,
          None,
          None,
          None,
          cancellation,
          selector,
        ))
        |> actor.selecting(selector)
        |> actor.returning(subject),
      )
    })
    |> actor.unlinked
    |> actor.on_message(handle)
    |> actor.idle_timeout(6000, Expire)
    |> actor.on_shutdown(shutdown)
    |> actor.start
  use started <- result.try(
    started |> result.replace_error(broker.BrokerUnavailable),
  )
  let observed = process.receive(admission, clearance_ms + 1000)
  use answer <- result.try(case observed {
    Ok(answer) -> Ok(answer)
    Error(Nil) -> {
      process.send(started.data, ParentDied)
      Error(broker.BrokerUnavailable)
    }
  })
  use Nil <- result.try(answer)
  Ok(Execution(started.data))
}

/// Closes the original bridge and observes the native task independently.
/// Associated native resource retirement remains unresolved even after settlement.
///
/// ## Examples
/// `close(original_execution)` returns the original observations.
@internal
pub fn close(execution: Execution) -> channel.CloseResult {
  let reply = process.new_subject()
  process.send(execution.commands, Close(reply))
  process.receive(reply, 9000) |> result.lazy_unwrap(unknown)
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  let next = case message {
    Settled(outcome) -> State(..state, node: enforcement.of_call(outcome))
    Cleared(answer) -> {
      case state.admission {
        Some(reply) -> process.send(reply, answer |> result.replace(Nil))
        None -> Nil
      }
      let original = case answer {
        Ok(handle) -> Some(handle)
        Error(_) -> None
      }
      case state.close_started, original {
        Some(Abandoned), Some(handle) ->
          broker.cancel(state.original_broker, handle)
        _, _ -> Nil
      }
      State(..state, admission: None, handle: original)
    }
    Native(weft.PulledOutcome(weft.Completed(_, outcome))) ->
      State(..state, node: enforcement.of_call(outcome))
    Native(weft.AllDelivered) -> State(..state, native_drain: Some(Joined))
    Native(weft.PulledOutcome(weft.Failed(_, ClearanceRefused(_)))) -> state
    Native(weft.PulledOutcome(_)) -> abandon(state)
    Native(weft.RunLost(_)) -> abandon(State(..state, native_drain: Some(Lost)))
    Native(weft.NotYet) -> state
    Closed(weft.PulledOutcome(weft.Completed(_, observed))) ->
      State(..state, transport: Some(observed))
    Closed(weft.AllDelivered) -> State(..state, transport_drain: Some(Joined))
    Closed(weft.PulledOutcome(_)) -> State(..state, transport: Some(unknown()))
    Closed(weft.RunLost(_)) ->
      State(..state, transport: Some(unknown()), transport_drain: Some(Lost))
    Closed(weft.NotYet) -> state
    Close(reply) -> begin_close(State(..state, close_reply: Some(reply)))
    ParentDied -> abandon(state)
    Expire -> state
  }

  // A lost run is terminal observer uncertainty, not a join witness. Once both
  // observers terminate, local retirement leaves original external custody held.
  case message, next.transport_drain, next.native_drain {
    Expire, Some(_), Some(_) -> actor.stop()
    _, _, _ -> finish(next)
  }
}

fn finish(next: State) -> actor.Next(State, Message) {
  case
    next.transport,
    next.transport_drain,
    next.native_drain,
    next.close_reply
  {
    Some(observed), Some(_), Some(_), Some(reply) -> {
      process.send(
        reply,
        channel.CloseResult(
          node: next.node,
          transport: case next.transport_drain {
            Some(Joined) -> observed.transport
            Some(Lost) | None ->
              channel.TransportUnresolved("original transport observer lost")
          },
          resources: channel.ResourcesUnresolved(
            "original native retirement not observed",
          ),
        ),
      )
      actor.continue(State(..next, close_reply: None))
      |> actor.with_selector(next.selector)
    }
    _, _, _, _ -> actor.continue(next) |> actor.with_selector(next.selector)
  }
}

fn begin_close(state: State) -> State {
  case state.close_started {
    Some(_) -> state
    None -> {
      // Normal close preserves the original native and outer receipt collector.
      // Only abandonment may cancel that collector before its fixed deadline.
      bridge.cancel(state.original_bridge)
      let reports = process.new_subject()
      let stream = state.original_bridge
      let _ =
        weft.new([
          fn() { Ok(bridge.close(stream)) },
        ])
        |> weft.deadline(7000)
        |> weft.cancel_when_exits(process.self())
        |> weft.start_relayed(to: reports)
      State(
        ..state,
        close_started: Some(Joining),
        selector: process.select_map(state.selector, reports, Closed),
      )
    }
  }
}

// Abandonment cancels the original native handle; normal close only joins it.
fn abandon(state: State) -> State {
  case state.close_started {
    Some(Abandoned) -> state
    None | Some(Joining) -> {
      case state.handle {
        Some(handle) -> broker.cancel(state.original_broker, handle)
        None -> Nil
      }
      let next = begin_close(state)
      let cancel_original = state.cancellation
      let _ =
        weft.new([
          fn() {
            cancel_original()
            Ok(Nil)
          },
        ])
        |> weft.deadline(1000)
        |> weft.cancel_when_exits(process.self())
        |> weft.start
      State(..next, close_started: Some(Abandoned))
    }
  }
}

fn shutdown(state: State, _reason: process.ExitReason) -> Nil {
  case state.handle {
    Some(handle) -> broker.cancel(state.original_broker, handle)
    None -> Nil
  }
  bridge.cancel(state.original_bridge)
}

fn unknown() -> channel.CloseResult {
  channel.CloseResult(
    enforcement.Unreported("original native settlement not observed"),
    channel.TransportUnresolved("original transport join not observed"),
    channel.ResourcesUnresolved("original native retirement not observed"),
  )
}
