//// A transitive drain witness for one public provider handle.
////
//// A process doing useful work is a poor teardown acknowledgement: if that
//// process crashes, its Down arrives before the work beneath it has finished
//// cancelling. This module keeps the public witness deliberately boring. It
//// receives typed ownership registrations, monitors the worker and every
//// registered child, and runs fallible cancellation closures on disposable
//// helper processes. The witness itself performs no provider callback, HTTP
//// operation, or foreign call.
////
//// Child adoption is an acknowledged prepare/publish/begin boundary. A worker
//// must register a child before permitting that child to start. If teardown
//// already began, the custodian rejects the permit, invokes cancellation, and
//// still waits for both the child and the worker. The public owner therefore
//// retires only after the complete registered subtree is gone.

import gleam/erlang/process.{type Monitor, type Pid, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

type Message {
  Adopt(owner: Option(Pid), cancel: fn() -> Nil, reply_with: Subject(Bool))
  Cancel
}

type Event {
  Command(Message)
  Down(process.Down)
}

type Child {
  Child(
    owner: Option(Pid),
    monitor: Option(Monitor),
    cancel: fn() -> Nil,
    cancelling: Bool,
  )
}

type State(stop) {
  State(
    commands: Subject(Message),
    worker: Pid,
    worker_monitor: Monitor,
    worker_alive: Bool,
    worker_stop: Subject(stop),
    stop_message: stop,
    consumer_monitor: Monitor,
    children: List(Child),
    cancellers: List(Monitor),
    closing: Bool,
  )
}

/// The typed capability for a running drain custodian.
pub opaque type Custodian {
  Custodian(commands: Subject(Message), owner: Pid)
}

/// Starts a custodian for `worker` and its eventual children.
pub fn start(
  worker: Pid,
  worker_stop: Subject(stop),
  stop_message: stop,
  consumer: Pid,
) -> Custodian {
  let ready = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let commands = process.new_subject()
      let state =
        State(
          commands:,
          worker:,
          worker_monitor: process.monitor(worker),
          worker_alive: process.is_alive(worker),
          worker_stop:,
          stop_message:,
          consumer_monitor: process.monitor(consumer),
          children: [],
          cancellers: [],
          closing: False,
        )
      process.send(ready, commands)
      loop(state)
    })
  let commands = process.receive_forever(ready)
  Custodian(commands:, owner:)
}

/// Returns the PID whose Down proves that the registered subtree drained.
pub fn owner(custodian: Custodian) -> Pid {
  custodian.owner
}

/// Requests cooperative teardown. Repeated calls are harmless.
pub fn cancel(custodian: Custodian) -> Nil {
  process.send(custodian.commands, Cancel)
}

/// Publishes an optional owner/cancel pair before work begins.
pub fn adopt(
  custodian: Custodian,
  owner: Option(Pid),
  cancel: fn() -> Nil,
) -> Bool {
  let reply = process.new_subject()
  let witness_monitor = process.monitor(custodian.owner)
  process.send(custodian.commands, Adopt(owner:, cancel:, reply_with: reply))
  let accepted =
    process.new_selector()
    |> process.select_map(reply, Ok)
    |> process.select_specific_monitor(witness_monitor, fn(_down) { Error(Nil) })
    |> process.selector_receive_forever()
    |> result.unwrap(False)
  process.demonitor_process(witness_monitor)
  accepted
}

/// Publishes an owner/cancel pair that is not itself a `StreamHandle`.
pub fn adopt_owner(
  custodian: Custodian,
  owner: Pid,
  cancel: fn() -> Nil,
) -> Bool {
  adopt(custodian, Some(owner), cancel)
}

fn loop(state: State(stop)) -> Nil {
  let event =
    process.new_selector()
    |> process.select_map(state.commands, Command)
    |> process.select_monitors(Down)
    |> process.selector_receive_forever()
  case event {
    Command(Adopt(owner:, cancel:, reply_with:)) -> {
      case owner {
        None -> {
          process.send(reply_with, !state.closing)
          continue_or_stop(state)
        }
        Some(_) -> {
          let child = monitor_child(owner, cancel)
          let state = State(..state, children: [child, ..state.children])
          process.send(reply_with, !state.closing)
          let state = case state.closing && !state.worker_alive {
            True -> cancel_child(state, child)
            False -> state
          }
          continue_or_stop(state)
        }
      }
    }
    Command(Cancel) -> continue_or_stop(begin_close(state))
    Down(down) -> continue_or_stop(handle_down(state, down))
  }
}

fn monitor_child(owner: Option(Pid), cancel: fn() -> Nil) -> Child {
  case owner {
    None -> Child(owner:, monitor: None, cancel:, cancelling: False)
    Some(pid) -> {
      let monitor = process.monitor(pid)
      case process.is_alive(pid) {
        True ->
          Child(owner:, monitor: Some(monitor), cancel:, cancelling: False)
        False -> {
          process.demonitor_process(monitor)
          Child(owner: None, monitor: None, cancel:, cancelling: False)
        }
      }
    }
  }
}

fn begin_close(state: State(stop)) -> State(stop) {
  case state.closing {
    True -> state
    False -> {
      process.send(state.worker_stop, state.stop_message)
      State(..state, closing: True)
    }
  }
}

fn cancel_child(state: State(stop), child: Child) -> State(stop) {
  case child.cancelling {
    True -> state
    False -> {
      let canceller = process.spawn_unlinked(child.cancel)
      let monitor = process.monitor(canceller)
      let cancellers = case process.is_alive(canceller) {
        True -> [monitor, ..state.cancellers]
        False -> {
          process.demonitor_process(monitor)
          state.cancellers
        }
      }
      State(
        ..state,
        children: mark_cancelling(state.children, child),
        cancellers:,
      )
    }
  }
}

fn mark_cancelling(children: List(Child), target: Child) -> List(Child) {
  list.map(children, fn(child) {
    case child.monitor == target.monitor && child.owner == target.owner {
      True -> Child(..child, cancelling: True)
      False -> child
    }
  })
}

fn handle_down(state: State(stop), down: process.Down) -> State(stop) {
  case down {
    process.PortDown(..) -> state
    process.ProcessDown(monitor:, ..) if monitor == state.worker_monitor -> {
      let state = State(..state, worker_alive: False)
      let state = begin_close(state)
      list.fold(state.children, state, cancel_child)
    }
    process.ProcessDown(monitor:, ..) if monitor == state.consumer_monitor ->
      begin_close(state)
    process.ProcessDown(monitor:, ..) ->
      State(
        ..state,
        children: forget_child(state.children, monitor),
        cancellers: list.filter(state.cancellers, fn(held) { held != monitor }),
      )
  }
}

fn forget_child(children: List(Child), monitor: Monitor) -> List(Child) {
  list.filter(children, fn(child) { child.monitor != Some(monitor) })
}

fn continue_or_stop(state: State(stop)) -> Nil {
  let async_children =
    list.any(state.children, fn(child) { child.owner != None })
  case
    state.closing
    && !state.worker_alive
    && !async_children
    && list.is_empty(state.cancellers)
  {
    True -> forget(state)
    False -> loop(state)
  }
}

fn forget(state: State(stop)) -> Nil {
  process.demonitor_process(state.worker_monitor)
  process.demonitor_process(state.consumer_monitor)
  list.each(state.children, fn(child) {
    case child.monitor {
      None -> Nil
      Some(monitor) -> process.demonitor_process(monitor)
    }
  })
}
