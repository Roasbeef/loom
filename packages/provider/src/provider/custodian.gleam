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
//// retires normally only after the complete registered subtree is gone. An
//// unexpected abnormal child exit destroys that proof and is propagated as
//// an abnormal custodian exit after every still-known child is cancelled.
////
//// ## The process shape
////
//// The custodian is not another worker. It is the small, unlinked process that
//// remembers every process which can still own work:
////
//// ```text
//// caller --cancel--> custodian --stop--> worker
////                       |                  |
////                       |                  +-- starts child
////                       |<----- adopt(child, cancel)
////                       |
////                       +-- exits only after worker, child, and cancellation
////                           helpers have all exited
//// ```
////
//// Code which monitors `owner(custodian)` consequently learns a stronger fact
//// than "the worker returned": a normal `Down` proves cancellation crossed
//// every registered ownership boundary, while an abnormal `Down` explicitly
//// reports that the proof was lost. Keeping callbacks off the custodian itself
//// matters because a crashing callback must not destroy that evidence.
////
//// ## The ownership protocol
////
//// A worker starts a child parked, calls `adopt`, and starts the child only
//// when `adopt` returns `True`. A `False` result means teardown already won;
//// the worker must not begin new work. `owner: None` is reserved for work with
//// no asynchronous descendant. Its cancellation closure may run, but there is
//// no child process for the custodian to retain.

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
    poisoned: Bool,
  )
}

/// The typed capability for one transitive drain witness.
///
/// The constructor is opaque so callers can request cancellation, publish
/// children, or monitor the witness without sending arbitrary process
/// messages.
pub opaque type Custodian {
  Custodian(commands: Subject(Message), owner: Pid)
}

// --- Public protocol -------------------------------------------------------

/// Starts a custodian for `worker` and every child it later adopts.
///
/// `worker_stop` is the worker's typed cooperative-stop capability. `consumer`
/// is monitored because a stream nobody can receive must cancel itself. The
/// returned custodian is unlinked: its purpose is to survive a crashing worker
/// long enough to account for the worker's descendants.
///
/// ## Examples
///
/// ```gleam
/// let stop = process.new_subject()
/// let worker = process.spawn_unlinked(fn() { process.receive_forever(stop) })
/// let witness =
///   custodian.start(worker, stop, Nil, consumer: process.self())
/// custodian.cancel(witness)
/// // custodian.owner(witness) exits after `worker` exits.
/// ```
///
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
          poisoned: False,
        )
      process.send(ready, commands)
      loop(state)
    })
  let commands = process.receive_forever(ready)
  Custodian(commands:, owner:)
}

/// Returns the PID whose `Down` proves that the registered subtree drained.
///
/// Monitoring this PID is the acknowledgement side of cancellation. Callers
/// must not kill it: doing so would erase the evidence they are waiting for.
///
/// ## Examples
///
/// ```gleam
/// let owner = custodian.owner(witness)
/// // process.monitor(owner)
/// ```
///
pub fn owner(custodian: Custodian) -> Pid {
  custodian.owner
}

/// Requests cooperative teardown of the worker and its adopted children.
///
/// The request is asynchronous and idempotent. Monitor `owner(custodian)` when
/// the caller must know that teardown finished rather than merely began.
///
/// ## Examples
///
/// ```gleam
/// custodian.cancel(witness)
/// custodian.cancel(witness)
/// // Both calls request the same teardown.
/// ```
///
pub fn cancel(custodian: Custodian) -> Nil {
  process.send(custodian.commands, Cancel)
}

/// Publishes an optional child owner and its cancellation capability.
///
/// The call is synchronous. `True` transfers teardown custody to the witness;
/// the worker may now start or expose the child. `False` means cancellation or
/// witness death won the race, so the worker must leave the child parked and
/// tear it down. An owner published after cancellation is still retained until
/// it exits.
///
/// ## Examples
///
/// ```gleam
/// let accepted = custodian.adopt(witness, Some(child), cancel_child)
/// // accepted == True means `witness` now accounts for `child`.
/// ```
///
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

/// Publishes a required owner/cancel pair that is not a `StreamHandle`.
///
/// This is the convenient form for observers, pumps, and transport receivers,
/// all of which necessarily have a process owner.
///
/// ## Examples
///
/// ```gleam
/// custodian.adopt_owner(witness, observer, fn() {
///   process.kill(observer)
/// })
/// // -> True
/// ```
///
pub fn adopt_owner(
  custodian: Custodian,
  owner: Pid,
  cancel: fn() -> Nil,
) -> Bool {
  adopt(custodian, Some(owner), cancel)
}

// --- Ownership loop -------------------------------------------------------

// One mailbox serializes the two facts which would otherwise race: whether
// cancellation has begun, and which descendants teardown must still cover.
// Monitors turn process death into data for the same transition loop.
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
      // Keep even an already-dead owner until its Down is adjudicated. An
      // is_alive pre-filter would erase the only distinction between a normal
      // drain and an owner which crashed after abandoning descendants.
      Child(owner:, monitor: Some(monitor), cancel:, cancelling: False)
    }
  }
}

// Closing first tells the worker to stop producing descendants. Children are
// cancelled after worker death, when the adoption set can no longer grow.
fn begin_close(state: State(stop)) -> State(stop) {
  case state.closing {
    True -> state
    False -> {
      process.send(state.worker_stop, state.stop_message)
      State(..state, closing: True)
    }
  }
}

// Cancellation callbacks are external behavior and may crash. A disposable
// helper contains that failure while its monitor keeps the witness alive until
// the callback itself has returned or died.
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

// A worker Down closes the adoption frontier. At that point every retained
// child is known, so cancellation can fan out without missing a late publish.
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
    process.ProcessDown(monitor:, reason:, ..) -> {
      let lost_proof = case reason {
        process.Normal -> False
        // A child may stop via its cancellation capability after custody has
        // already marked it as cancelling. Before that transfer, an abnormal
        // exit is unexpected and cannot certify any descendants it owned.
        process.Killed | process.Abnormal(_) ->
          list.any(state.children, fn(child) {
            child.monitor == Some(monitor) && !child.cancelling
          })
      }
      let state =
        State(
          ..state,
          children: forget_child(state.children, monitor),
          cancellers: list.filter(state.cancellers, fn(held) { held != monitor }),
          poisoned: state.poisoned || lost_proof,
        )
      // Once a child witness dies abnormally, no later event can recreate its
      // transitive proof. Stop the remaining frontier and propagate an
      // abnormal owner exit after every still-known child has been cancelled.
      case lost_proof {
        True -> begin_close(state)
        False -> state
      }
    }
  }
}

fn forget_child(children: List(Child), monitor: Monitor) -> List(Child) {
  list.filter(children, fn(child) { child.monitor != Some(monitor) })
}

// The witness exits only at the conjunction which gives `owner` its meaning:
// the worker is gone, every asynchronous child is gone, and no cancellation
// callback remains live. Until then a monitorable proof still has work to do.
fn continue_or_stop(state: State(stop)) -> Nil {
  let async_children =
    list.any(state.children, fn(child) { child.owner != None })
  case
    state.closing
    && !state.worker_alive
    && !async_children
    && list.is_empty(state.cancellers)
  {
    True ->
      case state.poisoned {
        True -> process.kill(process.self())
        False -> forget(state)
      }
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
