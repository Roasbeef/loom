//// The executor service: the one process that knows which executions a
//// session has running, and the only process that speaks to a helper about
//// them.
////
//// The broker decides whether a call may run. Once it may, the broker hands
//// it to a `Dispatcher` (`broker/dispatch`), and this module is the
//// dispatcher the service lane installs. Per session there is one service,
//// wrapping that session's helper pool. It borrows a helper for each
//// execution, starts a `broker/relay` to watch the execution, dispatches
//// the helper, and keeps a row for the execution until the broker releases
//// it. Four properties that the direct lane left to convention are
//// properties of this module's structure.
////
//// ## One sender
////
//// Every `Run`, `Stdin` and `CancelExec` a helper receives for an execution
//// is sent by this process. The relay asks for a cancel rather than
//// sending one, and the broker's cancel, stdin and release closures are
//// casts to this process. Erlang orders the messages of one sender to one
//// receiver, so a cancel sent for an execution reaches the helper before
//// any `Run` this process sends for the next execution on that helper, and
//// a helper that has already finished the first execution ignores a late
//// cancel in `Idle`. That ordering is the fence against a stale cancel
//// reaching a replacement execution. It needs no generation counter,
//// because the other half of the fence is the row: a message addressed to
//// an execution whose row is gone, or whose settlement was granted, is
//// dropped.
////
//// The same ordering makes stdin safe. `exec.run` is sent before `start`
//// replies, and the broker's stdin closure sends only after it holds the
//// reply, so the helper sees `Run` before any `Stdin` of the same
//// execution.
////
//// ## Settled exactly once
////
//// A row is `Live` or `Granted`. `Live` means nobody has been given leave to
//// report a verdict. The relay asks (`MaySettle`) before it reports one,
//// and the first ask for a live row turns it `Granted` and is answered
//// `Granted`; every later ask is answered `AlreadySettled`. The service
//// settles a row itself when it is `Live` and the relay died or the service
//// is closing, and when the broker abandons the row, which is the one case
//// the status does not decide (below). The service's own notice that a
//// relay died on a `Granted` row settles nothing, because the relay may
//// already have reported. Because the status is read and written in one
//// mailbox, the two settlers cannot both win.
////
//// ## What returns the helper, and when
////
//// The helper goes back to the pool in exactly one place per path. A
//// granted settlement ends with the broker handling the relay's `Settle`
//// message and calling the execution's `release`, which is a cast to this
//// process (`Release`), so the helper is checked in while the broker
//// processes the settlement, as it was before the seam existed. A relay
//// that dies unsettled is handled here (`RelayDown`) or by the broker's
//// `abandon` (`Abandon`), whichever arrives first: the row is `Live`, so
//// the service cancels the helper, returns it (the pool retires a helper
//// returned while busy), removes the row and settles the caller as
//// `ExecutionLost(RelayDown)`. The second arrival finds no row and is
//// dropped. The caller therefore always hears a settlement in this lane;
//// the direct lane gives none when its relay dies.
////
//// That claim holds for a `Granted` row too, by an argument about order.
//// The broker's `settle` closure sends the broker its `Settle` message
//// first and only then the caller its `CallSettled`, and a process's
//// messages reach a receiver before its own death notice. So if the relay
//// ran `settle` at all, the broker has `Settle` ahead of any `DOWN`,
//// demonitors the guarantor and sends `Release`; the broker sends `Abandon`
//// only when it saw no `Settle`, which proves the relay made no settlement
//// send and the caller has heard nothing. `abandon_row` therefore settles
//// the caller as lost whatever the row's status. The argument depends on
//// that send order, which `broker.settle_to` keeps and says so.
////
//// The service's own monitor has no such proof: it fires on a `Granted` row
//// when the relay has reported (the broker may be about to release), or
//// died before it did (the broker is about to abandon). It cannot tell the
//// two apart, so it neither settles nor cancels: the execution
//// had already ended. It waits for the broker, which sends `Release` if it
//// saw the settlement and `Abandon` if it did not.
////
//// ## Closing
////
//// `close` is the session's `Helpers` custody step. It stops admissions
//// (`start` answers `PoolUnavailable`, which callers read as "stop
//// polling", unlike a full pool), asks every live execution to cancel, and
//// waits for the live ones to settle through their relays for half of the
//// budget it was given. Executions still live at that point are settled
//// `ExecutionLost(ExecutorClosing)`, their relays killed and their helpers
//// returned busy. Then it closes the pool with what is left of the budget
//// and replies with the pool's verdict.
////
//// An `Ok` verdict ends the service. An `Error` does not: custody of
//// helpers that could not be shown retired must not be dropped quietly, so
//// the service stays alive in `Closed` and answers any later `close` with
//// the same verdict, as the pool does.
////
//// ## A caller that gives up
////
//// `start` is a synchronous call whose budget is the sum of everything the
//// service may spend inside it: the pool's checkout wait, the relay's
//// initialiser, the helper's run call, and a second of slack for the
//// scheduling between them (`start_budget_ms`). A service that overruns it
//// anyway, because something it called broke its own bound, leaves the
//// broker answering `NotStarted` while the service goes on to start an
//// execution nobody holds: an orphan. The broker spends the call id on
//// every attempt, so no later call can be given the orphan's number. The
//// orphan's settlement names a call the broker no longer has, which it
//// ignores, and its relay is `Granted` but never released. The cost is one
//// pool slot held until the service closes, or until the S2 late-`Run`
//// fence stops such a run being dispatched at all. It cannot wedge anything:
//// no later start collides with it.
////
//// The service still refuses a `start` whose sequence number is in its
//// table. Through the broker that is unreachable, since a number is never
//// offered twice; the check stays so that a different caller of the
//// dispatcher cannot overwrite a live row, which would let the orphan's
//// relay be granted against the new row.
////
//// ## Transitions
////
//// <!-- transitions: executor.Phase -->
////
//// | state | start | close | drain deadline | execution traffic |
//// | --- | --- | --- | --- | --- |
//// | `Serving` | borrows a helper, starts a relay, dispatches, replies | cancels every live row; `Closing`, or finishes at once when none is live | stale, ignored | handled |
//// | `Closing` | refused, `PoolUnavailable` | postponed until the verdict | settles the rows still live as lost, then finishes | handled; finishes as the last live row is granted |
//// | `Closed` | refused, `PoolUnavailable` | answers the stored verdict | stale, ignored | answered as unknown: nothing is live |

import broker/dispatch.{type Dispatcher}
import broker/exec.{type Helper}
import broker/execution
import broker/internal/call
import broker/relay
import core/clock
import gleam/bool
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/otp/actor
import gleam/result
import weft/poll
import weft/state_machine

/// What the service is built over: the pool's seams, as closures so that
/// the service neither imports a pool type nor can be handed one it did not
/// expect, and tests can pass fakes.
pub type ExecutorConfig {
  ExecutorConfig(
    /// Borrows a helper from the pool, answering the pool's own refusal.
    checkout: fn() -> Result(Helper, exec.CheckoutError),
    /// Returns a helper. The pool retires one that is returned busy.
    checkin: fn(Helper) -> Nil,
    /// Counts the pool's inventory by custody.
    census: fn() -> Result(exec.PoolCensus, exec.CheckoutError),
    /// Closes every helper the pool owns, within this many milliseconds,
    /// answering the retirement verdict.
    close_helpers: fn(Int) -> Result(Nil, exec.RetirementFailure),
    /// Distinguishes this service from any earlier one of the session, so
    /// an execution identity from a previous service can never equal one
    /// from this one.
    incarnation: Int,
  )
}

/// A handle on a running service.
pub opaque type Executor {
  Executor(subject: Subject(Msg), pid: Pid, incarnation: Int)
}

/// One execution the service holds, as an observer sees it.
pub type LiveRow {
  LiveRow(
    /// The execution's identity.
    id: dispatch.ExecutionId,
    /// When the execution started, in the session clock's milliseconds.
    started_at: Int,
  )
}

/// The service's books at one instant: the executions it holds and the
/// pool's census beside them. A row exists only while the service holds a
/// helper for it, so the list is never longer than the pool.
pub type Inventory {
  Inventory(
    /// The service's incarnation.
    incarnation: Int,
    /// Every execution the service holds, in start order. A row stays from
    /// dispatch until the broker releases it, so it includes executions
    /// whose settlement has been granted and not yet released.
    live: List(LiveRow),
    /// The pool's answer, or why it gave none.
    pool: Result(exec.PoolCensus, exec.CheckoutError),
  )
}

/// The service did not answer an observer within its window, or is gone.
pub type Unreachable {
  Unreachable
}

/// The service's message type. Opaque: callers reach the service through
/// this module's functions and through the closures of an `Execution`.
pub opaque type Msg {
  Start(
    request: dispatch.Dispatch,
    reply: Subject(Result(dispatch.Execution, dispatch.StartRefusal)),
  )
  Cancel(id: dispatch.ExecutionId)
  Stdin(id: dispatch.ExecutionId, data: BitArray, eof: dispatch.Eof)
  MaySettle(id: dispatch.ExecutionId, reply: Subject(relay.Permission))
  Release(id: dispatch.ExecutionId)
  Abandon(id: dispatch.ExecutionId)
  RelayDown(down: process.Down)
  Report(reply: Subject(Inventory))
  Close(waiting: Int, reply: Subject(Result(Nil, exec.RetirementFailure)))
  DrainDeadline
}

// The service's lifecycle. `Closing` carries the closer because it is
// fixed when the state is entered; everything that moves per message is in
// `State`.
type Phase {
  // Taking executions.
  Serving

  // Closing: new executions refused, live ones given half the budget to end.
  Closing(closer: Closer)

  // The close finished. Only reached when the pool could not show every
  // helper retired; a clean close ends the process instead.
  Closed(outcome: Result(Nil, exec.RetirementFailure))
}

// Who asked for the close and when their budget ends.
type Closer {
  Closer(reply: Subject(Result(Nil, exec.RetirementFailure)), deadline_ms: Int)
}

type State {
  State(config: ExecutorConfig, subject: Subject(Msg), rows: Dict(Int, Row))
}

// One execution. `settle` is the broker's closure from the `Dispatch`,
// kept so the service can report a loss when the relay cannot.
type Row {
  Row(
    id: dispatch.ExecutionId,
    helper: Helper,
    relay: relay.Relay,
    relay_monitor: process.Monitor,
    settle: fn(dispatch.Terminal) -> Nil,
    started_at_ms: Int,
    status: Status,
  )
}

// Whether anyone has been given leave to report this execution's verdict.
type Status {
  // Nobody has. The service may settle it, if the relay is lost.
  Live

  // The relay was given leave. The service's own monitor never settles it;
  // only the broker's `Abandon`, which proves the relay sent nothing, does.
  Granted
}

// How long the checkout seam is expected to take at most. The pool's
// checkout wait that `client/serve` passes is this long, and a checkout
// that blocks inside a helper spawn is bounded by it.
const checkout_wait_ms = 15_000

// How long the helper has to accept an `exec_start`.
const run_wait_ms = 5000

// Scheduling between the three steps of a `start`.
const start_slack_ms = 1000

// The budget of a `start`: every step the service may spend inside it, at
// its own bound, plus slack. Summed rather than written as a number so that
// raising one step cannot leave the budget behind it, which is the window
// an orphaned start needs. A function because constants cannot add.
fn start_budget_ms() -> Int {
  checkout_wait_ms + relay.init_wait_ms + run_wait_ms + start_slack_ms
}

// The caller of `close` waits this much past its own budget, because the
// service's last step, closing the pool, is bounded by that budget and the
// reply follows it.
const close_slack_ms = 1000

/// Starts the service. It is linked to the caller, like the pool and the
/// broker it serves beside, so that a plane built by one process is torn
/// down with it.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(service) =
///   executor.start(executor.ExecutorConfig(
///     checkout: fn() { exec.checkout(pool, waiting: 15_000) },
///     checkin: fn(helper) { exec.checkin(pool, helper) },
///     census: fn() { exec.pool_census(pool, waiting: 1000) },
///     close_helpers: fn(ms) { exec.close_pool(pool, waiting: ms) },
///     incarnation: 0,
///   ))
/// ```
///
pub fn start(config: ExecutorConfig) -> Result(Executor, actor.StartError) {
  state_machine.new_with_initialiser(1000, fn(subject) {
    // Relay deaths arrive as monitor messages, and the service takes a
    // monitor for each relay it starts, so one selector for all of them.
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_monitors(RelayDown)
    state_machine.initialised(
      Serving,
      State(config:, subject:, rows: dict.new()),
    )
    |> state_machine.selecting(selector)
    |> state_machine.returning(subject)
    |> Ok
  })
  |> state_machine.on_event(handle)
  |> state_machine.start
  |> result.map(fn(started) {
    Executor(
      subject: started.data,
      pid: started.pid,
      incarnation: config.incarnation,
    )
  })
}

/// The service's pid, for custody and for a link to be dropped.
pub fn pid(executor: Executor) -> Pid {
  executor.pid
}

/// The dispatcher to give `broker.start_dispatching`. The record holds no
/// process of its own: `start` is a bounded call to the service.
///
/// A service that does not answer within the start budget, or is gone, is
/// `NotStarted`, which the broker answers as `BrokerUnavailable`: a refusal
/// the caller does not retry, as opposed to a full pool, which it waits
/// out.
///
/// ## Examples
///
/// ```gleam
/// broker.start_dispatching(
///   entropy: token.production_entropy(),
///   clock:,
///   dispatcher: executor.dispatcher(service),
/// )
/// ```
///
pub fn dispatcher(executor: Executor) -> Dispatcher {
  let subject = executor.subject
  dispatch.Dispatcher(start: fn(request) {
    let asked =
      call.try_call(subject, waiting: start_budget_ms(), sending: fn(reply) {
        Start(request:, reply:)
      })
    case asked {
      Ok(answer) -> answer
      Error(call.NoReply) | Error(call.CalleeGone) -> Error(dispatch.NotStarted)
    }
  })
}

/// The service's books, answered by the service so that rows and census
/// describe one instant. `waiting` is the observer's window in
/// milliseconds.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(books) = executor.inventory(service, waiting: 1000)
/// assert books.live == []
/// ```
///
pub fn inventory(
  executor: Executor,
  waiting timeout: Int,
) -> Result(Inventory, Unreachable) {
  case call.try_call(executor.subject, waiting: timeout, sending: Report) {
    Ok(books) -> Ok(books)
    Error(call.NoReply) | Error(call.CalleeGone) -> Error(Unreachable)
  }
}

/// Closes the service: refuses new executions, cancels the live ones,
/// settles any that outlast half of `waiting`, and closes the pool with the
/// rest. The answer is the pool's retirement verdict.
///
/// `Ok(Nil)` ends the service, so a second `close` finds no process and
/// answers `RetirementOwnerGone`. An `Error` leaves the service alive in
/// `Closed`, where a second `close` answers the same verdict.
///
/// ## Examples
///
/// ```gleam
/// assert executor.close(service, waiting: 5000) == Ok(Nil)
/// ```
///
pub fn close(
  executor: Executor,
  waiting timeout: Int,
) -> Result(Nil, exec.RetirementFailure) {
  let asked =
    call.try_call(
      executor.subject,
      waiting: timeout + close_slack_ms,
      sending: fn(reply) { Close(waiting: timeout, reply:) },
    )
  case asked {
    Ok(verdict) -> verdict
    Error(call.NoReply) -> Error(exec.RetirementPending)
    Error(call.CalleeGone) -> Error(exec.RetirementOwnerGone)
  }
}

// --- the machine --------------------------------------------------------

// Every phase and message pair is accounted for. The messages that mean the
// same in every phase are matched with the phase bound to a name, which
// lists the message once and still fails to compile if a message is
// added and not handled.
fn handle(
  phase: Phase,
  state: State,
  message: Msg,
) -> state_machine.Next(Phase, State, Msg) {
  case phase, message {
    Serving, Start(request:, reply:) -> {
      let #(state, answer) = begin_execution(state, request)
      process.send(reply, answer)
      state_machine.keep(state)
    }

    // Admissions are closed. `PoolUnavailable` is deliberately not
    // `AllBusy`: a full pool clears as executions end and callers wait it
    // out, while a closing service never will.
    Closing(..), Start(reply:, ..) | Closed(..), Start(reply:, ..) -> {
      process.send(reply, Error(dispatch.NoHelper(exec.PoolUnavailable)))
      state_machine.keep(state)
    }

    Serving, Close(waiting:, reply:) -> begin_close(state, waiting, reply)

    // A second closer waits for the verdict of the first: postponed, it is
    // replayed when the service reaches `Closed`, and lost if the service
    // ends, which its caller sees as a dead service.
    Closing(..), Close(..) ->
      state_machine.keep(state) |> state_machine.postpone
    Closed(outcome), Close(reply:, ..) -> {
      process.send(reply, outcome)
      state_machine.keep(state)
    }

    // The half-budget has run out with executions still live: settle them
    // as lost and close the pool. The timer is the state timeout of
    // `Closing`, so it cannot fire in another phase; the arms say what a
    // stale fire would be.
    Closing(closer), DrainDeadline ->
      finish_closing(expire_live_rows(state), closer)
    Serving, DrainDeadline | Closed(..), DrainDeadline ->
      state_machine.keep(state)

    _phase, Cancel(id:) -> {
      cancel_row(state, id)
      state_machine.keep(state)
    }
    _phase, Stdin(id:, data:, eof:) -> {
      feed_row(state, id, data, eof)
      state_machine.keep(state)
    }
    phase, MaySettle(id:, reply:) ->
      conclude(phase, grant_settlement(state, id, reply))
    phase, Release(id:) -> conclude(phase, release_row(state, id))
    phase, Abandon(id:) -> conclude(phase, abandon_row(state, id))
    phase, RelayDown(down:) -> conclude(phase, relay_gone(state, down))
    _phase, Report(reply:) -> {
      process.send(reply, books(state))
      state_machine.keep(state)
    }
  }
}

// After a message that can end a live row: a closing service whose last
// live row just ended has nothing left to wait for.
fn conclude(
  phase: Phase,
  state: State,
) -> state_machine.Next(Phase, State, Msg) {
  case phase {
    Closing(closer) ->
      case has_live_row(state) {
        True -> state_machine.keep(state)
        False -> finish_closing(state, closer)
      }
    Serving | Closed(..) -> state_machine.keep(state)
  }
}

// --- starting an execution ----------------------------------------------

// Borrows a helper, starts the relay that will watch it, and dispatches.
// The service is blocked for all of it, which is what makes the row appear
// to every other message at once. Anything that refuses leaves nothing
// held.
fn begin_execution(
  state: State,
  request: dispatch.Dispatch,
) -> #(State, Result(dispatch.Execution, dispatch.StartRefusal)) {
  case dispatch_execution(state, request) {
    Ok(#(state, execution)) -> #(state, Ok(execution))
    Error(refusal) -> #(state, Error(refusal))
  }
}

fn dispatch_execution(
  state: State,
  request: dispatch.Dispatch,
) -> Result(#(State, dispatch.Execution), dispatch.StartRefusal) {
  // A sequence number still in the table is a late `start` the broker gave
  // up on (see the module doc); taking it would overwrite a live row.
  use <- bool.guard(
    when: dict.has_key(state.rows, request.seq),
    return: Error(dispatch.NotStarted),
  )
  use helper <- result.try(
    state.config.checkout() |> result.map_error(dispatch.NoHelper(error: _)),
  )
  let id =
    dispatch.execution_id(
      incarnation: state.config.incarnation,
      seq: request.seq,
    )

  // The relay is started before the helper is dispatched: it owns the
  // subject the helper's events arrive on, and nothing is sent to the
  // helper until that subject has a listener.
  use started <- result.try(start_relay(state, request, helper, id))
  let #(started_at_ms, _clock) = clock.read(request.clock)
  let row =
    Row(
      id:,
      helper:,
      relay: started,
      relay_monitor: process.monitor(started.pid),
      settle: request.settle,
      started_at_ms:,
      status: Live,
    )

  // A refusal here still reaches the caller through the relay, as the
  // direct lane does, so the caller sees one settlement either way. The
  // service sends it on the relay's own subject, which the relay reads as
  // the helper's failure event.
  case
    exec.run(
      helper,
      request.request,
      events: started.events,
      waiting: run_wait_ms,
    )
  {
    Ok(Nil) -> Nil
    Error(failure) -> process.send(started.events, exec.Failed(failure:))
  }

  let rows = dict.insert(state.rows, request.seq, row)
  Ok(#(State(..state, rows:), execution_of(state.subject, id, started.pid)))
}

// The relay, wired to this service by closures over its subject and the
// execution's identity.
fn start_relay(
  state: State,
  request: dispatch.Dispatch,
  helper: Helper,
  id: dispatch.ExecutionId,
) -> Result(relay.Relay, dispatch.StartRefusal) {
  let subject = state.subject
  let link =
    relay.Link(
      cancel: fn() { process.send(subject, Cancel(id:)) },
      may_settle: fn() {
        ask_to_settle(subject, id, waiting: relay.settle_wait_ms)
      },
    )
  let config =
    relay.Config(
      caller: request.caller,
      helper: exec.pid(helper),
      clock: request.clock,
      deadline_ms: request.deadline_ms,
      deliver: request.deliver,
      settle: request.settle,
      link:,
    )
  case relay.start(config) {
    Ok(started) -> Ok(started)

    // Nothing was dispatched, so the helper is idle and goes straight back.
    Error(actor.InitTimeout)
    | Error(actor.InitFailed(_))
    | Error(actor.InitExited(_)) -> {
      state.config.checkin(helper)
      Error(dispatch.NotStarted)
    }
  }
}

// The relay's question, asked from the relay's own process. A service that
// is gone or does not answer in the relay's window is `ServiceSilent`.
fn ask_to_settle(
  subject: Subject(Msg),
  id: dispatch.ExecutionId,
  waiting timeout: Int,
) -> relay.Permission {
  let asked =
    call.try_call(subject, waiting: timeout, sending: fn(reply) {
      MaySettle(id:, reply:)
    })
  case asked {
    Ok(permission) -> permission
    Error(call.NoReply) | Error(call.CalleeGone) -> relay.ServiceSilent
  }
}

/// Asks the service for leave to settle an execution, as its relay does.
/// Exists so a test can ask twice and see that only the first ask for a
/// live execution is granted; nothing outside the relay has a reason to
/// ask. Not part of the service's API.
@internal
pub fn may_settle(
  executor: Executor,
  id: dispatch.ExecutionId,
  waiting timeout: Int,
) -> relay.Permission {
  ask_to_settle(executor.subject, id, waiting: timeout)
}

// What the broker holds for an execution: closures that send to this
// service and name the execution by identity, so a late one is dropped when
// its row is gone.
fn execution_of(
  subject: Subject(Msg),
  id: dispatch.ExecutionId,
  guarantor: Pid,
) -> dispatch.Execution {
  dispatch.Execution(
    id:,
    guarantor:,
    cancel: fn() { process.send(subject, Cancel(id:)) },
    stdin: fn(data, eof) { process.send(subject, Stdin(id:, data:, eof:)) },
    release: fn() { process.send(subject, Release(id:)) },
    abandon: fn() { process.send(subject, Abandon(id:)) },
  )
}

// --- traffic about a running execution ----------------------------------

// The row an identity names, if it names one of this service's. An
// identity from another incarnation can never match.
fn find_row(state: State, id: dispatch.ExecutionId) -> Result(Row, Nil) {
  case dispatch.incarnation(id) == state.config.incarnation {
    True -> dict.get(state.rows, dispatch.seq(id))
    False -> Error(Nil)
  }
}

// A cancel for a live row reaches the helper and is echoed to the relay so
// that its core records that one was asked. The relay's own cancels arrive
// here too, since the relay may not cast to the helper, and the echo to it
// is harmless: the core keeps the first cause and a settled core ignores
// everything. A cancel for a granted or unknown row is dropped: the
// execution has ended, and the helper may already hold the next one.
fn cancel_row(state: State, id: dispatch.ExecutionId) -> Nil {
  case find_row(state, id) {
    Ok(Row(status: Live, helper:, relay:, ..)) -> {
      exec.cancel(helper)
      process.send(relay.control, execution.CancelRequested)
    }
    Ok(Row(status: Granted, ..)) | Error(Nil) -> Nil
  }
}

// Stdin follows the same rule as a cancel and the same ordering: it is
// sent from this process, after the `Run` it belongs to.
fn feed_row(
  state: State,
  id: dispatch.ExecutionId,
  data: BitArray,
  eof: dispatch.Eof,
) -> Nil {
  case find_row(state, id) {
    Ok(Row(status: Live, helper:, ..)) -> {
      // The helper's wire flag for the seam's two-variant type.
      let closes_stdin = case eof {
        dispatch.EndOfInput -> True
        dispatch.MoreInput -> False
      }
      exec.stdin(helper, data:, eof: closes_stdin)
    }
    Ok(Row(status: Granted, ..)) | Error(Nil) -> Nil
  }
}

// The relay asks for leave to report. The first ask for a live row is the
// only one granted; the answer is sent before anything else can change the
// row.
fn grant_settlement(
  state: State,
  id: dispatch.ExecutionId,
  reply: Subject(relay.Permission),
) -> State {
  case find_row(state, id) {
    Ok(Row(status: Live, ..) as row) -> {
      process.send(reply, relay.Granted)
      let rows =
        dict.insert(state.rows, dispatch.seq(id), Row(..row, status: Granted))
      State(..state, rows:)
    }
    Ok(Row(status: Granted, ..)) | Error(Nil) -> {
      process.send(reply, relay.AlreadySettled)
      state
    }
  }
}

// The broker processed the execution's `Settle` and is returning what was
// lent. A granted row's helper goes back to the pool and the row ends.
//
// A `Live` row can be released too, and the case is real: a relay whose
// ask went unanswered reports anyway (`ServiceSilent`), the broker then
// releases, and by the time the service reads `Release` the late ask may
// not have been read yet. The execution has been reported, so it is
// treated exactly as a granted one; the relay's late ask finds no row and
// is answered `AlreadySettled` to a process that is already gone.
fn release_row(state: State, id: dispatch.ExecutionId) -> State {
  case find_row(state, id) {
    Ok(row) -> {
      state.config.checkin(row.helper)
      remove_row(state, row)
    }
    Error(Nil) -> state
  }
}

// The broker's guarantor monitor fired and it saw no `Settle`: the relay
// died. Whichever of this and the service's own monitor arrives first does
// the work, and the other finds nothing.
//
// Both statuses settle the caller as lost. For a `Live` row that is plain.
// For a `Granted` row it rests on send order: `broker.settle_to` sends the
// broker `Settle` before anything else, and a process's messages reach the
// broker ahead of its own death notice, so a relay that ran `settle` at all
// would have been seen as settled and never abandoned. An `Abandon` proves
// the relay sent nothing, so the caller has heard nothing and this is its
// only settlement. The service's own monitor cannot make that argument and
// does not try (`relay_gone`).
fn abandon_row(state: State, id: dispatch.ExecutionId) -> State {
  case find_row(state, id) {
    Ok(row) -> lose_row(state, row, exec.RelayDown)
    Error(Nil) -> state
  }
}

// The service's own monitor on a relay fired.
fn relay_gone(state: State, down: process.Down) -> State {
  case down {
    // The service only monitors processes, never ports.
    process.PortDown(..) -> state
    process.ProcessDown(pid:, ..) ->
      case
        list.find(dict.values(state.rows), fn(row) { row.relay.pid == pid })
      {
        Ok(Row(status: Live, ..) as row) -> lose_row(state, row, exec.RelayDown)

        // The relay was granted leave, so it has reported or is about to,
        // or it died between the grant and the report. Either way the
        // broker decides: it sends `Release` for a settlement it saw and
        // `Abandon` for one it did not.
        Ok(Row(status: Granted, ..)) | Error(Nil) -> state
      }
  }
}

// An execution whose relay is gone before it reported. The helper is told
// to stop, then returned: the pool retires a helper returned while busy, so
// a helper still running the execution is never lent again. The row goes
// before the settlement so a message the settlement provokes finds no row.
fn lose_row(state: State, row: Row, cause: exec.LossCause) -> State {
  exec.cancel(row.helper)
  state.config.checkin(row.helper)
  let state = remove_row(state, row)
  row.settle(dispatch.Failed(failure: exec.ExecutionLost(cause:)))
  state
}

fn remove_row(state: State, row: Row) -> State {
  process.demonitor_process(row.relay_monitor)
  State(..state, rows: dict.delete(state.rows, dispatch.seq(row.id)))
}

// --- closing ------------------------------------------------------------

// Stops admissions and gives live executions half the budget to end by
// themselves, after a cancel. With none live there is nothing to wait for.
fn begin_close(
  state: State,
  waiting: Int,
  reply: Subject(Result(Nil, exec.RetirementFailure)),
) -> state_machine.Next(Phase, State, Msg) {
  let closer = Closer(reply:, deadline_ms: monotonic_ms() + waiting)
  list.each(dict.keys(state.rows), fn(seq) {
    cancel_row(
      state,
      dispatch.execution_id(incarnation: state.config.incarnation, seq:),
    )
  })
  case has_live_row(state) {
    False -> finish_closing(state, closer)
    True ->
      state_machine.transition(to: Closing(closer), data: state)
      |> state_machine.with_state_timeout(
        after: waiting / 2,
        sending: DrainDeadline,
      )
  }
}

// Settles every row still live as lost. The relay is killed first so it
// cannot answer a late ask; the rows are removed in this one handler, so a
// question it had already sent finds no row and is answered
// `AlreadySettled` to a dead process. The helpers go back busy and the pool
// retires them.
fn expire_live_rows(state: State) -> State {
  dict.values(state.rows)
  |> list.fold(state, fn(state, row) {
    case row.status {
      Live -> {
        process.kill(row.relay.pid)
        lose_row(state, row, exec.ExecutorClosing)
      }
      Granted -> state
    }
  })
}

// Closes the pool with what is left of the budget and answers the closer.
// Rows still held are granted ones whose release will never come, because
// the broker stops before the service, and the pool closes helpers
// including borrowed ones, so they are dropped here with their monitors.
fn finish_closing(
  state: State,
  closer: Closer,
) -> state_machine.Next(Phase, State, Msg) {
  list.each(dict.values(state.rows), fn(row) {
    process.demonitor_process(row.relay_monitor)
  })
  let remaining = int.max(closer.deadline_ms - monotonic_ms(), 0)
  let outcome = state.config.close_helpers(remaining)
  process.send(closer.reply, outcome)
  case outcome {
    Ok(Nil) -> state_machine.stop()

    // Custody that could not be shown retired is not dropped by exiting.
    Error(_) ->
      state_machine.transition(
        to: Closed(outcome),
        data: State(..state, rows: dict.new()),
      )
  }
}

fn has_live_row(state: State) -> Bool {
  list.any(dict.values(state.rows), fn(row) {
    case row.status {
      Live -> True
      Granted -> False
    }
  })
}

fn monotonic_ms() -> Int {
  let clock = poll.monotonic()
  clock.now()
}

// --- observation --------------------------------------------------------

fn books(state: State) -> Inventory {
  let live =
    dict.to_list(state.rows)
    |> list.sort(fn(left, right) { int.compare(left.0, right.0) })
    |> list.map(fn(entry) {
      LiveRow(id: { entry.1 }.id, started_at: { entry.1 }.started_at_ms)
    })
  Inventory(
    incarnation: state.config.incarnation,
    live:,
    pool: state.config.census(),
  )
}
