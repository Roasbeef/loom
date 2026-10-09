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
////
//// The same pass stops background executions nobody wants any more. The
//// listing names the executions still running on the executor, and a key whose
//// record on this side is no longer live (`Executions.standing`) is sent
//// `StopExecution`. That repeats a stop a partition lost, and it stops a
//// program an orchestrator that restarted left running.
////
//// ## Background executions
////
//// An executor's `code_mode` tool launches and interacts with a background
//// execution through this port (`LaunchExecution`, `InteractExecution`). The
//// record is this side's, so the port hands both to the session's
//// `Executions`, and a launch is given the host link the session attached
//// through, which is how the record's worker reaches the executor to start the
//// program.

import client/escalate
import client/owner_services.{type ExecutionTerms, type OwnerServices}
import client/remote/protocol.{
  type ExecutionAnswer, type Key, type Lookup, type OwnerMessage, type Unacked,
}
import core/clock.{type Clock}
import core/json.{type JsonValue}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import tools/codemode as codemode_tool
import weft
import weft/actor

/// How the port reaches the executor's host, supplied by whoever attached.
pub type HostLink {
  HostLink(
    /// Asks the host for the session's unacknowledged calls. May block.
    list: fn() -> Result(Unacked, String),
    /// Tells the host a call's result is durably staged. A cast.
    ack: fn(Key) -> Nil,
    /// Starts a background execution and waits for how it ends, sending the
    /// same request again after a dropped connection until it is answered or
    /// the calling process is killed. Arguments are the key, the terms and
    /// the time the program may still run, in milliseconds.
    start: fn(Key, ExecutionTerms, Int) -> ExecutionAnswer,
    /// Tells the host an execution's record has closed. A cast.
    stop: fn(Key) -> Nil,
    /// Asks the host what its ledger holds for a key, for a bounded time.
    query: fn(Key) -> Result(Lookup, String),
  )
}

/// The session's background-execution service, as the port serves it to an
/// executor.
pub type Executions {
  Executions(
    /// Claims a launch's record and answers its handle. The host link is the
    /// one the session attached through, for the record's worker.
    launch: fn(ExecutionTerms, HostLink) -> Result(JsonValue, String),
    /// Checks, joins, cancels or sends to an execution the strand owns.
    /// Arguments are the strand, the handle, the interaction and the wait.
    interact: fn(String, String, codemode_tool.Interaction, Int) ->
      Result(JsonValue, String),
    /// Where the record behind an execution's key stands. The reconciler
    /// stops a running program whose record is not live, and acknowledges an
    /// execution's row only once its record is closed.
    standing: fn(Key) -> Standing,
  )
}

/// Where an execution's record stands, as the reconciler needs to know it.
pub type Standing {
  /// The record is starting or running: its program is wanted.
  RecordLive

  /// The record is draining: its program is no longer wanted, and the
  /// execution service has not settled it yet.
  RecordClosing

  /// The record is finished or lost, or there is none. The row's result is
  /// no longer needed here.
  RecordClosed
}

/// The execution service of a session that serves no background code mode to
/// an executor: launches and interactions are refused, and every execution the
/// executor reports running is taken as unwanted.
///
/// ## Examples
///
/// ```gleam
/// // owner_port.Config(.., executions: owner_port.no_executions())
/// ```
pub fn no_executions() -> Executions {
  Executions(
    launch: fn(_terms, _link) { Error(no_executions_text) },
    interact: fn(_strand, _handle, _interaction, _within) {
      Error(no_executions_text)
    },
    standing: fn(_key) { RecordClosed },
  )
}

const no_executions_text = "this session serves no background code mode"

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
    /// The session's background-execution service.
    executions: Executions,
    /// The MCP servers the executor's code mode reaches: façades of the
    /// servers this orchestrator runs, and the names it expects the executor to
    /// run. The executor asks for it while it builds the scope's plane.
    mcp: protocol.McpPlan,
  )
}

/// A running port.
pub opaque type Port {
  Port(inbox: Subject(OwnerMessage), control: Subject(Event))
}

/// The default reconciliation period: one minute.
pub const default_reconcile_every_ms = 60_000

// What the port's process receives: an executor's request, a runtime attaching
// and handing over its host link, the reconciler's timer, or the order to end.
type Event {
  FromExecutor(message: OwnerMessage)
  Bind(link: HostLink, unacked: Unacked)
  Tick
  Stop
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

/// Ends the port. Its requests in flight end with it, because their runs are
/// linked to the port, and the executor's callbacks that were waiting on them
/// settle through the host's monitor of the port.
///
/// ## Examples
///
/// ```gleam
/// // owner_port.stop(port)
/// ```
pub fn stop(port: Port) -> Nil {
  process.send(port.control, Stop)
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
      serve(state.config, state.link, message)
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
    Stop -> actor.stop()
  }
}

// --- serving requests -----------------------------------------------------------

// Each request runs beside the port, ending if its requester does. A `Tail` is
// answered here because it has no reply to wait for.
fn serve(config: Config, link: Option(HostLink), message: OwnerMessage) -> Nil {
  let services = config.services
  let executions = config.executions
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

    // A launch can only come from an executor the session attached to, and the
    // attach binds the link before any tool runs there, so a missing link is a
    // request from a workspace this port no longer serves.
    protocol.LaunchExecution(terms:, reply:) ->
      case link {
        Some(bound) -> answer(reply, fn() { executions.launch(terms, bound) })
        None -> process.send(reply, Error("the executor is not attached"))
      }
    protocol.InteractExecution(
      strand:,
      handle:,
      interaction:,
      within_ms:,
      reply:,
    ) ->
      answer(reply, fn() {
        executions.interact(strand, handle, interaction, within_ms)
      })

    // Asked during the plane build, before the attach is answered and so
    // before the link is bound; the plan is the port's own, fixed for the open.
    protocol.AskMcpPlan(reply:) -> process.send(reply, config.mcp)
  }
}

// Computes one reply in a run that dies with the requester. The run's scope is
// linked to the port, so a port that exits takes its requests with it, and the
// requester's own death or disconnection cancels it through a monitor.
//
// The requester is a process on the executor's node, so it is a remote pid.
// weft 0.4.6 watches a remote consumer by monitor alone (weft#17): a lost
// connection arrives as a `noconnection` DOWN and cancels the run, where 0.4.5
// checked the pid with `erlang:is_process_alive/1`, which raises `badarg` for a
// pid of another node and crashed the scope into the port.
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
// whether the executor stored an outcome or lost it, and stops every running
// execution whose record here has closed.
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

  // A running execution whose record is closed was stopped by a message the
  // network lost, or was left running by an orchestrator that restarted. The
  // stop is idempotent on the executor, so sending it on every pass is safe.
  list.each(unacked.executions, fn(key) {
    case config.executions.standing(key) {
      RecordLive -> Nil
      RecordClosing | RecordClosed -> link.stop(key)
    }
  })
}
