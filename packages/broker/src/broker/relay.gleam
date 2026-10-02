//// The per-execution relay: one process that watches one execution and
//// reports how it ended.
////
//// A relay is the shell around `broker/execution`'s pure core. It owns the
//// subject the helper's events arrive on, monitors the two processes whose
//// death matters (the caller that asked for the execution, and the helper
//// actor running it), and turns each thing it hears into an
//// `execution.Event`. The core decides what to do; the relay does it.
//// Output goes to the caller, a cancel goes to the executor service, and
//// the one verdict goes to the broker, in that order.
////
//// ## Why the relay exists at all
////
//// The executor service is one serial process for every execution of a
//// session. Forwarding output through it would make a flood of one
//// execution's stdout delay every other execution's cancel and settlement,
//// and a deadline timer per execution would need a table of deadlines the
//// service would have to keep honest. A process per execution has neither
//// problem: its mailbox is its own, its deadline is its state timeout, and
//// its death is a fact the service can monitor.
////
//// ## The state machine, and why it decides nothing
////
//// The relay is a `weft/state_machine` whose state is `execution.Mode`,
//// `Streaming` or `Draining`, and which carries nothing, because a state
//// timeout is cancelled only by a move to a state that compares unequal
//// and anything that changed per event would restart it. `Streaming`'s
//// state timeout is the wall deadline that remains when the relay starts,
//// and `Draining`'s is `dispatch.relay_grace_ms`. Leaving a state cancels
//// its timeout, so no handler asks whether a timer is still relevant.
////
//// `handle` is not written as a `case mode, event` matrix, unlike the
//// helper machine and the pool. Their decisions live in the matrix; the
//// relay's live in `execution.step`, which is exhaustive over every event
//// and every mode and is property-tested. The handler is a translation, so
//// a matrix here would have sixteen arms that all say "ask the core" and
//// would hide the one decision that is the shell's, which is what an
//// effect does. The transition table for the two modes is in
//// `broker/execution`'s module doc, where `Mode` is defined, and the lint
//// holds it to the type.
////
//// ## Started before the helper is dispatched
////
//// A subject is tied to the process that creates it, so the relay creates
//// its own `exec_events` subject while it initialises, and `start` returns
//// only after the initialiser ran. The executor sends the helper its
//// `exec_start` after it holds that subject, which closes the race in which
//// the helper could produce output before anyone was listening.
////
//// The helper's actor is monitored in the same initialiser, before the
//// execution is dispatched. A monitor of an actor that is already dead
//// fires at once, so a helper that died between its checkout and its
//// dispatch settles the execution as lost rather than leaving the relay to
//// wait for a terminal event that nobody can send.
////
//// ## The relay never casts to the helper
////
//// A cancel goes to the executor service, which forwards it to the helper.
//// The service is therefore the only process that ever sends a helper
//// anything about an execution, and Erlang orders the messages of one
//// sender to one receiver, so a cancel the service sent for an execution
//// reaches the helper before any `Run` it sends for the next one. A relay
//// that cast to the helper directly would have a second sender, and its
//// cancel could land on whatever the helper was running by then.
////
//// ## The cancel is asked, not cast
////
//// A relay cancels for its own reasons too (the caller died, the wall
//// deadline passed), and the grace that bounds the cancel starts when the
//// relay enters `Draining`. The service can be blocked inside a `start`
//// that waits on a checkout, so a cast would leave the relay's five
//// seconds running while the cancel sat unread in the service's mailbox:
//// the relay could report `CancelEscalated` for a helper that had never
//// heard the cancel. The relay therefore asks (`Link.cancel` is a bounded
//// synchronous call, `cancel_wait_ms`) and enters `Draining` only after
//// the service has answered, which it does after it has sent the helper
//// the cancel. The grace then measures the helper's answer to a cancel
//// that was sent, as it does in the direct lane. A service that does not
//// answer is wedged or dead; the relay drains anyway, because the grace is
//// the only thing left that bounds the relay, and a service that wakes
//// later still forwards the cancel it finds in its mailbox. Waiting inside
//// a handler is within weft's rules here: the relay's only peers are the
//// service, which never waits on a relay, and the broker.
////
//// ## Settlement asks first
////
//// The core decides a verdict; the relay may not report it until the
//// service agrees, by asking `may_settle`. The service answers `Granted` to
//// the first ask for a live execution and `AlreadySettled` to any other,
//// and settles a live execution itself only when the relay dies. Between
//// them an execution is reported once. A service that is gone or silent
//// cannot be asked, and the relay then reports anyway: a dead service
//// settles nothing, and a live service that answers late has, by the order
//// of its own mailbox, either granted this relay's ask (which changes
//// nothing, since the relay has gone) or seen the relay's death after the
//// ask and found the row no longer live.

import broker/dispatch
import broker/exec
import broker/execution.{
  type Core, type Effect, type Event, type Mode, Draining, Streaming,
}
import core/clock.{type Clock}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import weft/state_machine

/// What the relay learns when it asks the service for leave to report its
/// verdict.
pub type Permission {
  /// The execution was live and is now spoken for: this relay reports.
  Granted

  /// The service has already settled or released the execution, so
  /// reporting again would be a second settlement.
  AlreadySettled

  /// The service did not answer: it is gone, or it did not reply in time.
  /// The relay reports anyway; see the module doc for why that is still
  /// exactly once.
  ServiceSilent
}

/// The relay's two ways back to the executor service, as closures so that
/// this module never imports the service that starts it.
pub type Link {
  Link(
    /// Asks the service to cancel the helper and waits, at most
    /// `cancel_wait_ms`, for it to say the cancel was sent. Idempotent.
    /// Returns when the service answered or the wait ran out; the relay
    /// drains either way.
    cancel: fn() -> Nil,
    /// Asks the service for leave to report the verdict, and waits for the
    /// answer a bounded time.
    may_settle: fn() -> Permission,
  )
}

/// What a relay is started with. Every field is a decision already made.
pub type Config {
  Config(
    /// The process whose death cancels the execution, if the call named a
    /// live owner.
    caller: Option(Pid),
    /// The helper actor whose death settles the execution as lost.
    helper: Pid,
    /// The session clock the wall deadline is measured on.
    clock: Clock,
    /// The aggregate wall deadline in the clock's milliseconds, or `0` for
    /// none.
    deadline_ms: Int,
    /// Called for each output chunk, in order, before `settle`.
    deliver: fn(dispatch.Chunk) -> Nil,
    /// Called at most once, with the verdict, after the last `deliver`.
    settle: fn(dispatch.Terminal) -> Nil,
    /// The way back to the service.
    link: Link,
  )
}

/// A running relay, as its starter holds it.
pub type Relay {
  Relay(
    /// The relay process. The broker monitors it as the execution's
    /// guarantor, and the service monitors it to settle its death.
    pid: Pid,
    /// Where the helper's events for this execution go. Owned by the relay
    /// process, so an event for an earlier execution cannot reach it.
    events: Subject(exec.ExecEvent),
    /// Where the service tells the relay about a cancel the broker asked
    /// for.
    control: Subject(Event),
  )
}

// Everything the relay carries across both modes. The core changes on
// every event, which is why it lives here and not in the state.
type Data {
  Data(
    core: Core,
    deliver: fn(dispatch.Chunk) -> Nil,
    settle: fn(dispatch.Terminal) -> Nil,
    link: Link,
    // The wall deadline's remaining span in milliseconds, computed once
    // when the relay started; `None` means the execution has no deadline.
    wall_after_ms: Option(Int),
  )
}

// What a step's effects add up to for the machine: stay, move to the
// draining grace, or end.
type Course {
  Stay
  Drain
  End
}

// The direct relay has always waited this long past the remaining span
// before it cancelled, and the service lane keeps the allowance so that
// the two lanes expire together.
const wall_slack_ms = 20

/// How long a relay waits for the service to answer a request for leave to
/// settle. The service handles one message at a time and may be inside a
/// checkout, which can take a helper handshake, so this bounds how long a
/// verdict waits for it. It is public so the service builds the
/// `may_settle` closure it hands the relay with the same bound.
pub const settle_wait_ms = 5000

/// How long a relay waits for the service to confirm it sent a cancel.
/// The service may be inside a checkout, so this is the same bound as
/// `settle_wait_ms`; it is public so the service builds the `cancel`
/// closure with it.
pub const cancel_wait_ms = 5000

/// How long a relay has to initialise, which bounds how long `start` can
/// block its caller. The service sums it into its own start budget.
pub const init_wait_ms = 1000

/// Starts a relay and returns once it is listening for events.
///
/// The relay is unlinked from its starter: a relay that crashes must not
/// take the service down, and the service monitors it instead. It stops by
/// itself after it reports a verdict.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(started) = relay.start(config)
/// // started.events is where the helper's events for this execution go.
/// ```
///
pub fn start(config: Config) -> Result(Relay, actor.StartError) {
  state_machine.new_with_initialiser(init_wait_ms, fn(control) {
    init(config, control)
  })
  |> state_machine.on_event(handle)
  |> state_machine.on_enter(entered)
  |> state_machine.unlinked
  |> state_machine.start
  |> result.map(fn(started) {
    let #(events, control) = started.data
    Relay(pid: started.pid, events:, control:)
  })
}

// Runs in the relay process. The subject and both monitors must be made
// here, because a subject and a monitor belong to the process that creates
// them.
fn init(
  config: Config,
  control: Subject(Event),
) -> Result(
  state_machine.Initialised(
    Mode,
    Data,
    Event,
    #(Subject(exec.ExecEvent), Subject(Event)),
  ),
  String,
) {
  let events = process.new_subject()
  let base =
    process.new_selector()
    |> process.select(control)
    |> process.select_map(events, from_exec)
    |> process.select_specific_monitor(
      process.monitor(config.helper),
      fn(_down) { execution.HelperDown },
    )
  let selector = case config.caller {
    Some(caller) ->
      process.select_specific_monitor(base, process.monitor(caller), fn(_down) {
        execution.CallerDown
      })
    None -> base
  }

  let data =
    Data(
      core: execution.new(),
      deliver: config.deliver,
      settle: config.settle,
      link: config.link,
      wall_after_ms: wall_after(config.clock, config.deadline_ms),
    )
  state_machine.initialised(Streaming, data)
  |> state_machine.selecting(selector)
  |> state_machine.returning(#(events, control))
  |> Ok
}

// The span the wall deadline has left, measured on the injected clock once
// and then waited out on the wall clock, which is the same thing for a real
// session and the only practical one for a state timeout.
fn wall_after(clock: Clock, deadline_ms: Int) -> Option(Int) {
  case deadline_ms {
    0 -> None
    _ -> {
      let #(now, _clock) = clock.read(clock)
      Some(int.max(deadline_ms - now, 0) + wall_slack_ms)
    }
  }
}

// The helper's own event vocabulary as the core's. The only translation of
// output the relay performs: bytes are never inspected or copied.
fn from_exec(event: exec.ExecEvent) -> Event {
  case event {
    exec.Output(stream:, data:, total_bytes:, truncated:) ->
      execution.ExecOutput(dispatch.Chunk(
        stream:,
        data:,
        total_bytes:,
        truncated:,
      ))
    exec.Exited(result:) -> execution.ExecExited(result:)
    exec.Failed(failure:) -> execution.ExecFailed(failure:)
  }
}

// Entering a mode arms that mode's deadline. `Streaming` is entered once,
// at start, and `Draining` once, on the core's say-so, so each timeout is
// armed exactly once and dies with its state.
fn entered(
  _from: Mode,
  to: Mode,
  data: Data,
) -> state_machine.Enter(Mode, Data, Event) {
  case to, data.wall_after_ms {
    Streaming, Some(after) ->
      state_machine.keep(data)
      |> state_machine.with_state_timeout(
        after:,
        sending: execution.DeadlineReached,
      )

    // No deadline: the execution runs until the helper reports, the caller
    // dies or somebody cancels, which is what a session-lived job means.
    Streaming, None -> state_machine.keep(data)

    // The grace starts when the cancel is sent, never from an earlier
    // timestamp, so a quiet execution's drain gets its whole window.
    Draining, _ ->
      state_machine.keep(data)
      |> state_machine.with_state_timeout(
        after: dispatch.relay_grace_ms,
        sending: execution.GraceExpired,
      )
  }
}

// One event: ask the core, then carry out what it says.
fn handle(
  _mode: Mode,
  data: Data,
  event: Event,
) -> state_machine.Next(Mode, Data, Event) {
  let #(core, effects) = execution.step(data.core, event)
  let data = Data(..data, core:)
  case perform(data, effects) {
    Stay -> state_machine.keep(data)
    Drain -> state_machine.transition(to: Draining, data:)
    End -> state_machine.stop()
  }
}

// Carries out a step's effects in the order the core listed them, and says
// what the machine does next. `Settle` is always the last effect and ends
// the relay, so by the time the relay stops everything the caller was owed
// has been sent.
fn perform(data: Data, effects: List(Effect)) -> Course {
  list.fold(effects, Stay, fn(course, effect) {
    case effect {
      execution.Deliver(chunk:) -> {
        data.deliver(chunk)
        course
      }

      // The cancel goes to the service, never to the helper: see the
      // module doc on why the service must be the helper's only sender.
      // The call returns once the cancel was sent, and only then does the
      // `EnterDraining` that follows start the grace.
      execution.SendCancel -> {
        data.link.cancel()
        course
      }

      execution.EnterDraining ->
        case course {
          End -> End
          Stay | Drain -> Drain
        }

      execution.Settle(terminal:) -> {
        report(data, terminal)
        End
      }
    }
  })
}

// Reports the verdict if the service allows. `AlreadySettled` means the
// service has settled this execution (the relay was thought dead) or has
// seen it released, so the relay says nothing. A silent service cannot
// forbid a report, so it is made.
fn report(data: Data, terminal: dispatch.Terminal) -> Nil {
  case data.link.may_settle() {
    Granted | ServiceSilent -> data.settle(terminal)
    AlreadySettled -> Nil
  }
}
