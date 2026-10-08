//// The orchestrator's end of a remote session's callbacks, and its
//// reconciler (protocol-change/078, "Executor to orchestrator").
////
//// A workspace on another machine asks its owner for decisions and records
//// while a tool runs (`client/remote/owner_link` is the sender). This module
//// is the receiver, one actor per session. It answers each `OwnerMessage` by
//// calling the session's local `OwnerServices`, the same record the workspace
//// would have been handed if it ran in this VM, so a remote workspace cannot
//// reach anything a local one could not.
////
//// ## The port never blocks
////
//// An approval can park for ten minutes and a capability can run a spawn, so
//// a request is never served on the port's own process. Each one runs in a weft
//// run whose cancel signal is the death of the executor-side requester: if the
//// executor's call is killed, its node disconnects, or its VM dies, the run is
//// cancelled and a parked decision does not outlive the question. A `Tail` is
//// the one inline case. It is a cast, it carries no reply, and losing one is
//// legal.
////
//// An escalation arrives with a remaining duration and not a deadline, because
//// the two machines' clocks differ. The port rebuilds the refusal's deadline on
//// its own clock before handing it to the local seam.
////
//// ## Reconciling acknowledgements
////
//// The orchestrator acknowledges a call's result to the executor only after it
//// has durably staged it, and an acknowledgement can be lost: the executor then
//// holds a row nobody will ever query, because the call is no longer orphaned.
//// So the port runs a reconciler. Whenever a runtime attaches (`bind`) it is
//// handed the unacknowledged keys the attach reported, and on a timer it asks
//// the executor for them again through the `HostLink` the attach supplied. A key
//// is acknowledged only if the injected `settled` says the orchestrator already
//// holds its result, whether the executor holds a stored outcome or reports it
//// lost, so a row for a call whose result is still in flight is left alone.

import client/escalate
import client/owner_services.{type OwnerServices}
import client/remote/protocol.{type Key, type OwnerMessage, type Unacked}
import core/clock.{type Clock}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import weft
import weft/actor

/// How the port reaches the executor's host, supplied by whoever attached.
pub type HostLink {
  HostLink(
    /// Asks the host for the session's unacknowledged calls. May block.
    list: fn() -> Result(Unacked, String),
    /// Tells the host a call's result is durably staged. A cast.
    ack: fn(Key) -> Nil,
  )
}

/// How a port is configured.
pub type Config {
  Config(
    /// The session's local owner services, which every request is served by.
    services: OwnerServices,
    /// The orchestrator's clock, used to rebuild an escalation's deadline.
    clock: Clock,
    /// Whether the orchestrator already holds the result of this call, so its
    /// executor row may be deleted.
    settled: fn(Key) -> Bool,
    /// How often the reconciler asks the host for unacknowledged calls.
    reconcile_every_ms: Int,
  )
}

/// A running port.
pub opaque type Port {
  Port(inbox: Subject(OwnerMessage), control: Subject(Event))
}

/// The default reconciliation period: one minute.
pub const default_reconcile_every_ms = 60_000

// What the port's process receives: an executor's request, a runtime attaching
// and handing over its host link, or the reconciler's timer.
type Event {
  FromExecutor(message: OwnerMessage)
  Bind(link: HostLink, unacked: Unacked)
  Tick
}

type State {
  State(
    config: Config,
    link: Option(HostLink),
    reconciling: Option(weft.Witnessed),
  )
}

/// Starts a port, linked to the caller.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(port) = owner_port.start(config)
/// // owner_port.inbox(port) is what an attach hands the executor
/// ```
pub fn start(config: Config) -> Result(Port, String) {
  actor.new_with_initialiser(5000, fn(control) { initialise(config, control) })
  |> actor.on_message(handle_event)
  |> actor.periodic(every: config.reconcile_every_ms, sending: Tick)
  |> actor.start
  |> result_of_start
}

/// The subject an attach gives the executor, which sends `OwnerMessage`s to it.
///
/// ## Examples
///
/// ```gleam
/// // protocol.Attach(.., owner_port: owner_port.inbox(port), ..)
/// ```
pub fn inbox(port: Port) -> Subject(OwnerMessage) {
  port.inbox
}

/// Tells the port which host the session just attached to and which calls that
/// attach reported unacknowledged. It acknowledges the settled ones at once and
/// keeps the link for the periodic reconciliation. A later attach replaces the
/// link.
///
/// ## Examples
///
/// ```gleam
/// // owner_port.bind(port, link, attached.unacked)
/// ```
pub fn bind(port: Port, link: HostLink, unacked: Unacked) -> Nil {
  process.send(port.control, Bind(link:, unacked:))
}

/// Runs one reconciliation now instead of waiting for the timer.
///
/// ## Examples
///
/// ```gleam
/// // owner_port.reconcile(port)
/// ```
pub fn reconcile(port: Port) -> Nil {
  process.send(port.control, Tick)
}

fn initialise(
  config: Config,
  control: Subject(Event),
) -> Result(actor.Initialised(State, Event, Port), String) {
  let inbox = process.new_subject()
  let selector =
    process.new_selector()
    |> process.select(control)
    |> process.select_map(inbox, FromExecutor)
  actor.initialised(State(config:, link: None, reconciling: None))
  |> actor.selecting(selector)
  |> actor.returning(Port(inbox:, control:))
  |> Ok
}

fn result_of_start(
  started: Result(actor.Started(Port), actor.StartError),
) -> Result(Port, String) {
  case started {
    Ok(running) -> Ok(running.data)
    Error(error) ->
      Error("the owner port did not start: " <> string.inspect(error))
  }
}

fn handle_event(state: State, event: Event) -> actor.Next(State, Event) {
  case event {
    FromExecutor(message) -> {
      serve(state.config, message)
      actor.continue(state)
    }
    Bind(link:, unacked:) -> {
      // The keys are checked off the port's process, because `settled` reads
      // the session's store.
      let _pass =
        detached(fn() { acknowledge_settled(state.config, link, unacked) })
      actor.continue(State(..state, link: Some(link)))
    }
    Tick -> actor.continue(tick(state))
  }
}

// --- serving requests -----------------------------------------------------------

// Each request runs beside the port, ending if its requester does. A `Tail` is
// answered here because it has no reply to wait for.
fn serve(config: Config, message: OwnerMessage) -> Nil {
  let services = config.services
  case message {
    protocol.Escalate(refused:, remaining_ms:, reply:) -> {
      let #(now, _clock) = clock.read(config.clock)
      let rebased = escalate.Refused(..refused, deadline_ms: now + remaining_ms)
      answer(reply, fn() { services.escalate(rebased) })
    }
    protocol.FactGet(key:, reply:) ->
      answer(reply, fn() { services.facts.cell(key) })
    protocol.FactPut(key:, value:, expected:, reply:) ->
      answer(reply, fn() { services.facts.put(key, value, expected) })
    protocol.FactPutBlind(key:, value:, reply:) ->
      answer(reply, fn() { services.facts.put_blind(key, value) })
    protocol.FactDelete(key:, reply:) ->
      answer(reply, fn() { services.facts.delete(key) })
    protocol.FactList(prefix:, reply:) ->
      answer(reply, fn() { services.facts.list(prefix) })
    protocol.Notify(strand:, work:, text:, reply:) ->
      answer(reply, fn() { services.notify(strand, work, text) })
    protocol.StrandActivity(strand:, reply:) ->
      answer(reply, fn() { services.strand_activity(strand) })
    protocol.Wake(strand:, text:, reply:) ->
      answer(reply, fn() { services.wake(strand, text) })
    protocol.Holds(caller:, tool:, reply:) ->
      answer(reply, fn() { services.holds(caller, tool) })
    protocol.Tail(run:, tail:) -> services.output(run)(tail)
    protocol.Capability(call:, reply:) ->
      answer(reply, fn() { services.capability(call) })
  }
}

// Computes one reply in a run that dies with the requester. The run's scope is
// linked to the port, so a port that exits takes its requests with it, and the
// requester's own death or disconnection cancels it through a monitor.
fn answer(reply: Subject(reply), compute: fn() -> reply) -> Nil {
  case process.subject_owner(reply) {
    Ok(requester) -> {
      let _witness =
        weft.new([
          fn() {
            process.send(reply, compute())
            Ok(Nil)
          },
        ])
        |> weft.cancel_when_exits(requester)
        |> weft.start_witnessed
      Nil
    }
    Error(Nil) -> Nil
  }
}

// --- reconciling ----------------------------------------------------------------

// The timer, or a request to reconcile now. A pass still running when the next
// tick comes is left to finish: two passes would acknowledge the same keys
// twice.
fn tick(state: State) -> State {
  case state.link, reconciling(state) {
    Some(link), False -> {
      let pass = detached(fn() { acknowledge_listed(state.config, link) })
      State(..state, reconciling: Some(pass))
    }
    Some(_link), True | None, True | None, False -> state
  }
}

fn reconciling(state: State) -> Bool {
  case state.reconciling {
    Some(pass) -> process.is_alive(weft.witness_pid(pass))
    None -> False
  }
}

// Runs `work` in a weft run of its own, linked to the port so that a port that
// exits takes it along.
fn detached(work: fn() -> Nil) -> weft.Witnessed {
  weft.new([
    fn() {
      work()
      Ok(Nil)
    },
  ])
  |> weft.start_witnessed
}

// Asks the host what it holds and acknowledges the settled keys.
fn acknowledge_listed(config: Config, link: HostLink) -> Nil {
  case link.list() {
    Ok(unacked) -> acknowledge_settled(config, link, unacked)
    Error(_unreachable) -> Nil
  }
}

// Acknowledges every listed key whose result the orchestrator already holds,
// whether the executor stored an outcome or lost it.
fn acknowledge_settled(
  config: Config,
  link: HostLink,
  unacked: Unacked,
) -> Nil {
  list.each(list.append(unacked.terminal, unacked.unknown), fn(key) {
    case config.settled(key) {
      True -> link.ack(key)
      False -> Nil
    }
  })
}
