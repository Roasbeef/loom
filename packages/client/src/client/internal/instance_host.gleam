//// A persistent assembly host whose exit requests independently owned cleanup.
////
//// Preparation starts no session work. The manager first records the returned
//// custody witness and installs its monitor, then calls `begin`. The builder
//// runs assembly once and remains resident after publishing the result. Returning
//// from an opening request therefore does not end the session's lifetime.
////
//// Fatal children stop this host without running teardown here. Weft observes
//// the builder's exit and starts the surviving holder's ordered cleanup. Assembly
//// must publish resources to that holder and transfer their startup links before
//// beginning work; trapping exits alone does not protect resources from KILL.

import client/internal/instance_owner as custody
import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/result
import gleam/string
import weft/state_machine as sm

/// A parked or resident builder and its independently owned cleanup capability.
pub opaque type Host {
  Host(commands: Subject(Message), pid: Pid, custody: custody.Owner)
}

type Phase {
  Prepared
  Live
}

type Message {
  Begin(custody.Owner)
  Stop
  ConsumerGone
  ChildGone(String, process.ExitReason)
  LinkGone(process.ExitReason)
}

type Book(instance) {
  Book(
    build: fn(custody.Owner) -> Result(instance, String),
    fatal: fn(instance) -> List(#(String, Pid)),
    results: Subject(Result(instance, String)),
    faults: Subject(String),
    selector: process.Selector(Message),
  )
}

/// Prepares ownership without acquiring session resources or starting recovery.
///
/// The caller is the daemon's custody registry, not a connection or opening job.
/// Weft ties the scope to its creator, so preparation stays in this long-lived
/// process; only assembly runs out of line. The caller must trap exits and monitor
/// `owner(host)` before `begin`. Result and fault subjects belong to it too.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(host) = instance_host.prepare(build:, fatal:,
/// //   results:, faults:, failures:)
/// // let watch = process.monitor(instance_host.owner(host))
/// // instance_host.begin(host)
/// ```
@internal
pub fn prepare(
  build build: fn(custody.Owner) -> Result(instance, String),
  fatal fatal: fn(instance) -> List(#(String, Pid)),
  results results: Subject(Result(instance, String)),
  faults faults: Subject(String),
  failures failures: Subject(custody.Failure),
) -> Result(Host, String) {
  let consumer = process.self()
  use started <- result.try(
    sm.new_with_initialiser(1000, fn(commands) {
      let selector =
        process.new_selector()
        |> process.select(commands)
        |> process.select_specific_monitor(process.monitor(consumer), fn(_down) {
          ConsumerGone
        })
        |> process.select_trapped_exits(fn(exit) { LinkGone(exit.reason) })
      sm.initialised(
        Prepared,
        Book(build:, fatal:, results:, faults:, selector:),
      )
      |> sm.selecting(selector)
      |> sm.returning(commands)
      |> Ok
    })
    |> sm.trapping_exits(True)
    |> sm.unlinked
    |> sm.on_event(handle)
    |> sm.start
    |> result.map_error(string.inspect),
  )
  let stop = fn() { process.send(started.data, Stop) }
  case custody.start(started.pid, stop, consumer:, failures:) {
    Ok(owner) -> Ok(Host(started.data, started.pid, owner))
    Error(error) -> {
      stop()
      Error(error)
    }
  }
}

/// Releases the parked builder after the manager has retained its witness.
///
/// Repeated calls do not repeat assembly or publish a second runtime.
///
/// ## Examples
///
/// ```gleam
/// instance_host.begin(host)
/// ```
@internal
pub fn begin(host: Host) -> Nil {
  process.send(host.commands, Begin(host.custody))
}

/// Returns the cleanup witness, whose normal exit confirms ordered retirement.
///
/// ## Examples
///
/// ```gleam
/// let watch = process.monitor(instance_host.owner(host))
/// ```
@internal
pub fn owner(host: Host) -> Pid {
  custody.owner(host.custody)
}

/// Returns the persistent builder PID for fault containment and diagnostics.
///
/// ## Examples
///
/// ```gleam
/// let builder = instance_host.builder(host)
/// ```
@internal
pub fn builder(host: Host) -> Pid {
  host.pid
}

/// Requests ordered stop while preserving custody beyond this report deadline.
///
/// ## Examples
///
/// ```gleam
/// let report = instance_host.close(host, within_ms: 1000)
/// ```
@internal
pub fn close(host: Host, within_ms within_ms: Int) -> custody.CloseOutcome {
  custody.close(host.custody, within_ms:)
}

/// Requests shutdown without waiting in the daemon's admission handler.
///
/// ## Examples
///
/// ```gleam
/// instance_host.cancel(host)
/// ```
@internal
pub fn cancel(host: Host) -> Nil {
  custody.cancel(host.custody)
}

fn handle(phase: Phase, book: Book(instance), message: Message) {
  case phase, message {
    Prepared, Begin(owner) -> assemble(book, owner)
    Live, Begin(_owner) -> sm.keep(book)
    _, Stop | _, ConsumerGone -> sm.stop()
    _, ChildGone(name, reason) -> {
      process.send(book.faults, name <> ": " <> string.inspect(reason))
      sm.stop()
    }
    _, LinkGone(process.Normal) -> sm.keep(book)
    _, LinkGone(reason) -> {
      process.send(
        book.faults,
        "linked assembly resource: " <> string.inspect(reason),
      )
      sm.stop()
    }
  }
}

fn assemble(book: Book(instance), owner: custody.Owner) {
  case book.build(owner) {
    Error(reason) -> {
      process.send(book.results, Error(reason))
      sm.stop()
    }
    Ok(instance) -> {
      let selector =
        list.fold(book.fatal(instance), book.selector, fn(selector, child) {
          process.select_specific_monitor(
            selector,
            process.monitor(child.1),
            fn(down) { ChildGone(child.0, down.reason) },
          )
        })

      // Fatal-child monitoring precedes publication. A root which already died
      // cannot leave an apparently resident host with no pending death event.
      process.send(book.results, Ok(instance))
      sm.transition(Live, Book(..book, selector:)) |> sm.with_selector(selector)
    }
  }
}
