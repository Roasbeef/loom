//// Linearizability of the executor service under several concurrent callers
//// on one pool: does what each caller was told fit some single order of the
//// commands that a plain sequential model agrees with?
////
//// `executor_property_test` drives the service from one process, so it can
//// interleave the service, the broker, the relays and the helpers but never
//// two callers of the service itself. This module is the other half. A
//// `statem_parallel` case runs a sequential prefix and then two or three
//// branches at the same moment, each branch a process of its own calling the
//// one shared plane, and the checker looks for an order of everything the
//// branches did that the model accepts.
////
//// ## What races
////
//// A command is a start of a run (one that holds a helper until cancelled,
//// or one that ends at once), a broker cancel, a kill of the run's caller, an
//// await of the run's settlement, or a close of the whole service. The races
//// the service must survive are the ones between these: a start against a
//// close (a start that the service accepts must be cancelled by that close,
//// one it refuses must see a closed service), a cancel against a close, a
//// cancel against the relay's own settlement, two closes against each other
//// (the second is postponed, or finds the service gone), and a caller's death
//// against any of them.
////
//// ## What the model claims
////
//// The model is the list of runs the service has accepted, in the order it
//// accepted them, each with what has been asked of it (cancelled, its caller
//// killed), and whether the service is closed. Every answer is predicted from
//// that alone:
////
//// - a start answers `Started(n)` where `n` is how many runs came before it,
////   or `Refused` once the service is closed;
//// - a cancel or a kill answers the run its pick names, by the pick modulo
////   the runs there are;
//// - an await answers `Settled` for a run that has to end (it ends by itself,
////   it was cancelled, or the service closed), `StillRunning` for a run that
////   was left alone, and `CallerKilled` when its caller was killed first;
//// - the first close answers a clean `Ok`, and a later one the same or says
////   the service is gone.
////
//// ## Why the system carries a registry
////
//// A run is named by the position it was accepted in, so the system under
//// test is the plane plus a small registry actor that every branch shares.
//// A shared handle cannot thread driver bookkeeping through `execute` the way
//// the sequential test's `Sut` does, so the bookkeeping lives behind the
//// handle. It is the harness, not an oracle: it holds what a driver has to
//// hold (the caller processes, the handles, the settlements each heard) and
//// it decides how long an await waits, which is a fact about the test's
//// patience and not about the service. What is right is decided only by the
//// model.
////
//// Two choices keep the model able to predict an answer from its own state at
//// the linearization point, which is what a response-free `next_model`
//// requires. First, a run takes its position when the registry hears that
//// the service decided on it, never when it was asked for, and the registry
//// asks the service for one start at a time. A position taken at request time
//// would put two concurrent starts in an order the service did not choose,
//// and a refusal that follows a close would then contradict the order: a
//// false alarm. Starts therefore race everything else but not each other. Second, the
//// pool is larger than the most starts one case can make, so a refusal means
//// a closed service and never a full pool, which the model could not predict.
////
//// ## Where each invariant is checked
////
//// Answers are checked one by one against the model, which also covers the
//// exactly-once rule for any run awaited: an await that heard anything but
//// one settlement and then nothing is answered `Garbled`, which no model
//// state predicts. What can only be seen once the system is quiet is in
//// `finish`, each under its own tag so that shrinking cannot slide to another
//// invariant: every caller that was not killed heard one settlement
//// (`never_heard`, `settlements`, `trailing`); with the service open the
//// executor holds no row and the pool nothing borrowed or held
//// (`row_kept`, `pool_borrowed`, `pool_slots`); no relay outlives its run
//// (`relay_outlived`); and a second close finds the service gone
//// (`second_close`). There is no fault here that a fake helper cannot attest
//// to, so every close must be clean.
////
//// Shrinking is bounded twice, as in the sequential test: by executions, and
//// by a deadline read when the test starts, so the shrunk case is reported
//// before gleeunit's fifty second kill. What a seed reproduces is the case,
//// not the schedule.

import broker/broker
import broker/exec
import broker/executor
import broker/support/fake_helper
import broker/support/planes
import gleam/bool
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import qcheck
import statem.{type Violation, Admit, Reject, Violation}
import statem_parallel
import weft/actor
import weft/poll

// --- the commands -----------------------------------------------------------

// What a run does, by the argv word the fake helper reads.
type Kind {
  Hold
  Quick
}

// One thing a branch does. A `pick` is a raw draw, resolved modulo the runs the
// service has accepted when the command takes effect, so a plain value keeps
// its meaning when shrinking removes an earlier command.
type Command {
  Start(kind: Kind)
  Cancel(pick: Int)
  KillCaller(pick: Int)
  Await(pick: Int)
  Close
}

// --- the model --------------------------------------------------------------

// Whether anyone has asked the run to stop.
type Wish {
  Untouched
  Cancelled
}

// Whether the run's calling process is still alive.
type Caller {
  Alive
  Killed
}

// Whether the service has been closed.
type Closure {
  Open
  Shut
}

// What the model knows of one accepted run.
type Run {
  Run(kind: Kind, wish: Wish, caller: Caller)
}

// The runs the service accepted, oldest first, and whether it is closed.
type Model {
  Model(runs: List(Run), closure: Closure)
}

// What an await found out.
type Outcome {
  Settled
  StillRunning
  CallerKilled
  Garbled(settlements: Int, trailing: Int)
}

// What a close answered.
type Verdict {
  CleanClose
  AlreadyGone
  FailedClose(detail: String)
}

// What a command answered. Every variant is something the model can predict.
type Answer {
  Started(index: Int)
  Refused
  NoRun
  Acted(index: Int)
  Awaited(index: Int, outcome: Outcome)
  Closed(verdict: Verdict)
}

fn initial() -> Model {
  Model(runs: [], closure: Open)
}

// The run a pick names: the pick modulo the runs there are.
fn target(model: Model, pick: Int) -> Result(#(Int, Run), Nil) {
  case list.length(model.runs) {
    0 -> Error(Nil)
    count -> {
      let index = pick % count
      list.drop(model.runs, index)
      |> list.first
      |> result.map(fn(run) { #(index, run) })
    }
  }
}

// A command that names a run is admitted only once there is one. Runs are
// never removed, so the first start keeps every later pick meaningful.
fn precondition(model: Model, command: Command) -> statem.Admission {
  case command {
    Start(..) | Close -> Admit
    Cancel(..) | KillCaller(..) | Await(..) ->
      case model.runs {
        [] -> Reject
        [_, ..] -> Admit
      }
  }
}

fn next_model(model: Model, command: Command) -> Model {
  case command {
    Start(kind:) ->
      case model.closure {
        Open ->
          Model(
            ..model,
            runs: list.append(model.runs, [
              Run(kind:, wish: Untouched, caller: Alive),
            ]),
          )
        Shut -> model
      }
    Cancel(pick:) ->
      change_run(model, pick, fn(run) { Run(..run, wish: Cancelled) })
    KillCaller(pick:) ->
      change_run(model, pick, fn(run) { Run(..run, caller: Killed) })
    Await(..) -> model
    Close -> Model(..model, closure: Shut)
  }
}

fn change_run(model: Model, pick: Int, change: fn(Run) -> Run) -> Model {
  case target(model, pick) {
    Error(Nil) -> model
    Ok(#(chosen, _run)) ->
      Model(
        ..model,
        runs: list.index_map(model.runs, fn(run, index) {
          case index == chosen {
            True -> change(run)
            False -> run
          }
        }),
      )
  }
}

// A run has to end when it ends by itself, was cancelled, or the service was
// closed under it. A held run that was left alone has no way to.
fn must_end(model: Model, run: Run) -> Bool {
  case model.closure, run.wish, run.kind {
    Shut, _, _ -> True
    Open, Cancelled, _ -> True
    Open, Untouched, Quick -> True
    Open, Untouched, Hold -> False
  }
}

fn expected_outcome(model: Model, run: Run) -> Outcome {
  case run.caller, must_end(model, run) {
    Killed, _ -> CallerKilled
    Alive, True -> Settled
    Alive, False -> StillRunning
  }
}

fn violation(tag: String, detail: String) -> Result(a, Violation) {
  Error(Violation(tag:, detail:))
}

// Whether `answer` is the one the model predicts for `command`, in the model
// as it stood just before the command took effect.
fn postcondition(
  model: Model,
  command: Command,
  answer: Answer,
) -> Result(Nil, Violation) {
  case command {
    Start(..) -> expect_start(model, answer)
    Cancel(pick:) | KillCaller(pick:) -> expect_acted(model, pick, answer)
    Await(pick:) -> expect_awaited(model, pick, answer)
    Close -> expect_closed(model, answer)
  }
}

fn expect_start(model: Model, answer: Answer) -> Result(Nil, Violation) {
  case model.closure, answer {
    Open, Started(index:) ->
      case index == list.length(model.runs) {
        True -> Ok(Nil)
        False ->
          violation(
            "start_position",
            "a start took position "
              <> int.to_string(index)
              <> " after "
              <> int.to_string(list.length(model.runs))
              <> " runs",
          )
      }
    Shut, Refused -> Ok(Nil)
    Open, unexpected ->
      violation(
        "start_refused",
        "an open service answered a start " <> string.inspect(unexpected),
      )
    Shut, unexpected ->
      violation(
        "start_after_close",
        "a closed service answered a start " <> string.inspect(unexpected),
      )
  }
}

fn expect_acted(
  model: Model,
  pick: Int,
  answer: Answer,
) -> Result(Nil, Violation) {
  case target(model, pick), answer {
    Error(Nil), NoRun -> Ok(Nil)
    Ok(#(index, _run)), Acted(index: acted) if acted == index -> Ok(Nil)
    _, unexpected ->
      violation(
        "acted_on",
        "a pick of "
          <> int.to_string(pick)
          <> " answered "
          <> string.inspect(unexpected),
      )
  }
}

fn expect_awaited(
  model: Model,
  pick: Int,
  answer: Answer,
) -> Result(Nil, Violation) {
  case target(model, pick), answer {
    Error(Nil), NoRun -> Ok(Nil)
    Ok(#(index, run)), Awaited(index: awaited, outcome:) if awaited == index ->
      case outcome == expected_outcome(model, run) {
        True -> Ok(Nil)
        False ->
          violation(
            "await_outcome",
            "run "
              <> int.to_string(index)
              <> " awaited as "
              <> string.inspect(outcome)
              <> " where the model has "
              <> string.inspect(run)
              <> " and the service "
              <> string.inspect(model.closure),
          )
      }
    _, unexpected ->
      violation(
        "awaited",
        "a pick of "
          <> int.to_string(pick)
          <> " answered "
          <> string.inspect(unexpected),
      )
  }
}

// The first close is clean. A later one is either postponed behind the first
// and given its verdict, or finds the service gone.
fn expect_closed(model: Model, answer: Answer) -> Result(Nil, Violation) {
  case model.closure, answer {
    Open, Closed(CleanClose) -> Ok(Nil)
    Shut, Closed(CleanClose) | Shut, Closed(AlreadyGone) -> Ok(Nil)
    _, unexpected ->
      violation(
        "close_verdict",
        "a close answered "
          <> string.inspect(unexpected)
          <> " with the service "
          <> string.inspect(model.closure),
      )
  }
}

// --- the generator ----------------------------------------------------------

// Each field is drawn whichever command it turns out to be, and each shrinks
// toward zero: the first command is a start, the first kind is a held run.
fn command_generator() -> qcheck.Generator(Command) {
  qcheck.map3(
    qcheck.bounded_int(from: 0, to: 19),
    qcheck.bounded_int(from: 0, to: 1000),
    qcheck.bounded_int(from: 0, to: 1),
    command_of,
  )
}

fn command_of(which: Int, pick: Int, kind: Int) -> Command {
  case which {
    0 | 1 | 2 | 3 | 4 | 5 | 6 ->
      Start(kind: case kind {
        0 -> Hold
        _ -> Quick
      })
    7 | 8 | 9 -> Cancel(pick:)
    10 | 11 -> KillCaller(pick:)
    12 | 13 | 14 | 15 | 16 | 17 -> Await(pick:)
    _ -> Close
  }
}

fn describe(command: Command) -> String {
  string.inspect(command)
}

// --- the callers ------------------------------------------------------------

// What a caller tells the registry once its call is cleared or refused.
type First {
  Granted(handle: broker.CallHandle, relay: Result(Pid, Nil))
  Declined
}

// What a caller heard, once its run settled and the quiet after it passed.
type Hearing {
  Hearing(settlements: Int, trailing: Int)
}

fn word_of(kind: Kind) -> String {
  case kind {
    Hold -> "sleep"
    Quick -> "ok"
  }
}

// A caller is a process of its own, unlinked, so that a branch process killed
// at the deadline cannot take its run's caller with it and a killed caller is
// exactly the death the relay monitors. It reports to the registry twice: when
// its call is cleared or refused, and when its run has settled.
fn spawn_caller(
  plane: planes.Plane,
  ticket: Int,
  kind: Kind,
  registry: Subject(Message),
) -> Pid {
  process.spawn_unlinked(fn() {
    let events = process.new_subject()
    let spec = planes.spec(planes.op(), argv: [word_of(kind)], deadline_ms: 0)
    let spec =
      broker.CallSpec(..spec, step_id: "step-" <> int.to_string(ticket))

    case broker.clear_call(plane.broker, spec, events:, waiting: 1000) {
      Error(_refusal) -> process.send(registry, Cleared(ticket, Declined))
      Ok(handle) -> {
        let relay = broker.relay_pid(plane.broker, handle, waiting: 1000)
        process.send(registry, Cleared(ticket, Granted(handle:, relay:)))
        let settlements = listen(events, settled: 0)
        let trailing = count_trailing(events, 0)
        process.send(registry, Heard(ticket, Hearing(settlements:, trailing:)))
      }
    }
  })
}

// Reads the call's events until it settles, or until ten quiet seconds say it
// never will.
fn listen(events: Subject(broker.CallEvent), settled settled: Int) -> Int {
  case process.receive(events, 10_000) {
    Error(Nil) -> settled
    Ok(broker.CallOutput(..)) -> listen(events, settled:)
    Ok(broker.CallSettled(..)) -> settled + 1
  }
}

// How many events arrive after the settlement, which must be none.
fn count_trailing(events: Subject(broker.CallEvent), seen: Int) -> Int {
  case process.receive(events, 80) {
    Ok(_) -> count_trailing(events, seen + 1)
    Error(Nil) -> seen
  }
}

// --- the registry -----------------------------------------------------------

// What a driver has to keep of a run once the service accepted it.
type Slot {
  Slot(
    ticket: Int,
    kind: Kind,
    caller_pid: Pid,
    handle: broker.CallHandle,
    relay: Result(Pid, Nil),
    wish: Wish,
    caller: Caller,
    hearing: Option(Hearing),
  )
}

// A start the registry has handed to a caller and is waiting on.
type Beginning {
  Beginning(ticket: Int, caller_pid: Pid, kind: Kind, reply: Subject(Answer))
}

// A start asked for and not yet handed to a caller.
type Waiting {
  Waiting(kind: Kind, registry: Subject(Message), reply: Subject(Answer))
}

// What a branch may do to a run, atomically with the registry's own record.
type Touch {
  WishCancel
  KillIt
}

type Touched {
  NoSlot
  Touched(index: Int, handle: broker.CallHandle)
}

// Whether the registry knows the run has to end, which sets how long an
// await waits for it. This is the harness's patience, not the model's claim.
type Patience {
  Long
  Short
}

type View {
  View(index: Int, caller: Caller, hearing: Option(Hearing), patience: Patience)
}

type Viewed {
  NoView
  Viewed(View)
}

// Everything `finish` reads.
type Books {
  Books(slots: List(Slot), closure: Closure)
}

type Message {
  Begin(kind: Kind, registry: Subject(Message), reply: Subject(Answer))
  Cleared(ticket: Int, first: First)
  Heard(ticket: Int, hearing: Hearing)
  Touching(pick: Int, touch: Touch, reply: Subject(Touched))
  Peek(pick: Int, reply: Subject(Viewed))
  Shutting(reply: Subject(Nil))
  Inspect(reply: Subject(Books))
  Halt
}

type Registry {
  Registry(
    plane: planes.Plane,
    slots: List(Slot),
    inflight: Option(Beginning),
    queue: List(Waiting),
    tickets: Int,
    closure: Closure,
  )
}

fn start_registry(plane: planes.Plane) -> Subject(Message) {
  let assert Ok(started) =
    actor.new(Registry(
      plane:,
      slots: [],
      inflight: None,
      queue: [],
      tickets: 0,
      closure: Open,
    ))
    |> actor.on_message(handle_message)
    |> actor.start
    as "the registry actor starts"

  started.data
}

fn handle_message(
  state: Registry,
  message: Message,
) -> actor.Next(Registry, Message) {
  case message {
    Begin(kind:, registry:, reply:) ->
      Registry(
        ..state,
        queue: list.append(state.queue, [Waiting(kind:, registry:, reply:)]),
      )
      |> pump
      |> actor.continue

    // A caller reports the service's decision. Only the start in flight can
    // report, because only one is handed out at a time.
    Cleared(ticket:, first:) ->
      case state.inflight {
        Some(beginning) if beginning.ticket == ticket ->
          conclude(state, beginning, first) |> pump |> actor.continue
        Some(_) | None -> actor.continue(state)
      }

    Heard(ticket:, hearing:) ->
      Registry(
        ..state,
        slots: list.map(state.slots, fn(slot) {
          case slot.ticket == ticket {
            True -> Slot(..slot, hearing: Some(hearing))
            False -> slot
          }
        }),
      )
      |> actor.continue

    Touching(pick:, touch:, reply:) -> {
      let #(touched_state, touched) = touch_slot(state, pick, touch)
      process.send(reply, touched)
      actor.continue(touched_state)
    }

    Peek(pick:, reply:) -> {
      process.send(reply, view_of(state, pick))
      actor.continue(state)
    }

    Shutting(reply:) -> {
      process.send(reply, Nil)
      actor.continue(Registry(..state, closure: Shut))
    }

    Inspect(reply:) -> {
      process.send(reply, Books(slots: state.slots, closure: state.closure))
      actor.continue(state)
    }

    Halt -> actor.stop()
  }
}

// Hands the next waiting start to a caller, if none is in flight. The order
// of positions is then the order in which the service decided, because the
// next start is not asked of the service until this one has been answered.
fn pump(state: Registry) -> Registry {
  case state.inflight, state.queue {
    Some(_), _ | None, [] -> state

    None, [next, ..rest] -> {
      let ticket = state.tickets
      let caller_pid =
        spawn_caller(state.plane, ticket, next.kind, next.registry)
      Registry(
        ..state,
        queue: rest,
        tickets: ticket + 1,
        inflight: Some(Beginning(
          ticket:,
          caller_pid:,
          kind: next.kind,
          reply: next.reply,
        )),
      )
    }
  }
}

// The service decided: a refusal leaves no run, an acceptance takes the next
// position and answers it.
fn conclude(state: Registry, beginning: Beginning, first: First) -> Registry {
  case first {
    Declined -> {
      process.send(beginning.reply, Refused)
      Registry(..state, inflight: None)
    }

    Granted(handle:, relay:) -> {
      process.send(beginning.reply, Started(index: list.length(state.slots)))
      Registry(
        ..state,
        inflight: None,
        slots: list.append(state.slots, [
          Slot(
            ticket: beginning.ticket,
            kind: beginning.kind,
            caller_pid: beginning.caller_pid,
            handle:,
            relay:,
            wish: Untouched,
            caller: Alive,
            hearing: None,
          ),
        ]),
      )
    }
  }
}

fn slot_at(state: Registry, pick: Int) -> Result(#(Int, Slot), Nil) {
  case list.length(state.slots) {
    0 -> Error(Nil)
    count -> {
      let index = pick % count
      list.drop(state.slots, index)
      |> list.first
      |> result.map(fn(slot) { #(index, slot) })
    }
  }
}

// Records the touch before the branch acts on it, so that anything which sees
// the effect of the touch can only have started after it was recorded. A
// kill is carried out here, in the registry, for the same reason.
fn touch_slot(
  state: Registry,
  pick: Int,
  touch: Touch,
) -> #(Registry, Touched) {
  case slot_at(state, pick) {
    Error(Nil) -> #(state, NoSlot)

    Ok(#(chosen, slot)) -> {
      let changed = case touch {
        WishCancel -> Slot(..slot, wish: Cancelled)
        KillIt -> {
          process.kill(slot.caller_pid)
          Slot(..slot, caller: Killed)
        }
      }
      let slots =
        list.index_map(state.slots, fn(old, index) {
          case index == chosen {
            True -> changed
            False -> old
          }
        })
      #(Registry(..state, slots:), Touched(index: chosen, handle: slot.handle))
    }
  }
}

fn view_of(state: Registry, pick: Int) -> Viewed {
  case slot_at(state, pick) {
    Error(Nil) -> NoView
    Ok(#(index, slot)) ->
      Viewed(View(
        index:,
        caller: slot.caller,
        hearing: slot.hearing,
        patience: patience_for(state, slot),
      ))
  }
}

fn patience_for(state: Registry, slot: Slot) -> Patience {
  case state.closure, slot.wish, slot.kind {
    Shut, _, _ -> Long
    Open, Cancelled, _ -> Long
    Open, Untouched, Quick -> Long
    Open, Untouched, Hold -> Short
  }
}

// --- the system under test --------------------------------------------------

// The shared handle: the plane and the registry that fronts the callers. Both
// are processes, so every branch can use them at once.
type Sut {
  Sut(plane: planes.Plane, registry: Subject(Message))
}

/// The most starts one case can make: a prefix of `max_prefix` and every
/// branch of `max_branch`, with three branches. The pool is larger than that,
/// so no start is ever refused for want of a helper and a refusal can only
/// mean a closed service.
const pool_size = 14

const max_prefix = 3

const max_branch = 3

fn new_sut() -> Sut {
  let plane =
    planes.start_scripted(size: pool_size, script: fn() {
      fake_helper.start_helper_configured(
        fake_helper.ByArgv,
        cancel_grace_ms: 300,
        heartbeat_interval_ms: 0,
      )
    })
  Sut(plane:, registry: start_registry(plane))
}

// Dismantles the plane, whichever way the case ended. After a case that
// closed the service the close answers at once; after one that failed with the
// service open it is what retires the runs the case left behind.
fn teardown(sut: Sut) -> Nil {
  process.send(sut.registry, Halt)
  planes.dismantle(sut.plane)
}

// --- running a command ------------------------------------------------------

fn run(sut: Sut, command: Command) -> Answer {
  case command {
    Start(kind:) ->
      process.call(sut.registry, 8000, fn(reply) {
        Begin(kind:, registry: sut.registry, reply:)
      })
    Cancel(pick:) -> cancel_run(sut, pick)
    KillCaller(pick:) -> kill_caller(sut, pick)
    Await(pick:) -> await_run(sut, pick, waited: 0)
    Close -> close_service(sut)
  }
}

fn cancel_run(sut: Sut, pick: Int) -> Answer {
  case process.call(sut.registry, 1000, Touching(pick, WishCancel, _)) {
    NoSlot -> NoRun
    Touched(index:, handle:) -> {
      broker.cancel(sut.plane.broker, handle)
      Acted(index:)
    }
  }
}

fn kill_caller(sut: Sut, pick: Int) -> Answer {
  case process.call(sut.registry, 1000, Touching(pick, KillIt, _)) {
    NoSlot -> NoRun
    Touched(index:, ..) -> Acted(index:)
  }
}

// Polls the registry for the run's fate every ten milliseconds, for as many
// polls as the registry's patience allows: a run that has to end is given
// three seconds, a held run that was left alone a few polls, which is long
// enough for a settlement that was owed to have arrived.
//
// Every poll resolves the pick afresh and the answer comes from the last poll
// alone, so the run it names and what it found are one instant of the registry.
// An await that fixed its run at its first poll and kept looking would name the
// run by the count of runs when it began and report what a close did much
// later, and no single place in the model's order fits both.
fn await_run(sut: Sut, pick: Int, waited waited: Int) -> Answer {
  case process.call(sut.registry, 1000, Peek(pick, _)) {
    NoView -> NoRun

    Viewed(View(index:, caller:, hearing:, patience:)) ->
      case caller, hearing {
        Killed, _ -> Awaited(index:, outcome: CallerKilled)

        Alive, Some(Hearing(settlements: 1, trailing: 0)) ->
          Awaited(index:, outcome: Settled)

        Alive, Some(Hearing(settlements:, trailing:)) ->
          Awaited(index:, outcome: Garbled(settlements:, trailing:))

        Alive, None ->
          case waited >= polls_allowed(patience) {
            True -> Awaited(index:, outcome: StillRunning)
            False -> {
              process.sleep(10)
              await_run(sut, pick, waited: waited + 1)
            }
          }
      }
  }
}

fn polls_allowed(patience: Patience) -> Int {
  case patience {
    Long -> 300
    Short -> 6
  }
}

// The registry hears of the close before the service does, so any answer that
// shows the close at work was given by a branch that overlaps this command.
fn close_service(sut: Sut) -> Answer {
  process.call(sut.registry, 1000, Shutting)

  case executor.close(sut.plane.service, draining: 400, helpers: 800) {
    Ok(Nil) -> Closed(CleanClose)
    Error(exec.RetirementOwnerGone) -> Closed(AlreadyGone)
    Error(other) -> Closed(FailedClose(string.inspect(other)))
  }
}

// --- the verdict ------------------------------------------------------------

// Ends the case: everything still running is cancelled, and then each
// invariant is read in the order it can first be seen.
fn finish(sut: Sut) -> Result(Nil, Violation) {
  let books = inspect(sut)
  list.each(books.slots, fn(slot) {
    broker.cancel(sut.plane.broker, slot.handle)
  })

  use _ <- result.try(check_heard_exactly_once(sut))
  use _ <- result.try(case books.closure {
    Shut -> Ok(Nil)
    Open -> check_open_service_is_quiet(sut)
  })
  use _ <- result.try(check_nothing_left(sut))
  check_second_close(sut)
}

fn inspect(sut: Sut) -> Books {
  process.call(sut.registry, 2000, Inspect)
}

// Every caller the case did not kill heard one settlement and then nothing.
fn check_heard_exactly_once(sut: Sut) -> Result(Nil, Violation) {
  let everyone_asked_heard = fn() {
    let books = inspect(sut)
    let waiting =
      list.filter(books.slots, fn(slot) {
        slot.caller == Alive && option.is_none(slot.hearing)
      })
    case waiting {
      [] -> poll.Done(books.slots)
      [_, ..] -> poll.Retry
    }
  }

  case poll.until(within: 3000, every: 20, attempt: everyone_asked_heard) {
    poll.Failed(_) | poll.Expired ->
      violation("never_heard", "a caller never heard its settlement")

    poll.Answered(slots) ->
      list.try_each(slots, fn(slot) {
        case slot.caller, slot.hearing {
          Killed, _ | Alive, None -> Ok(Nil)
          Alive, Some(Hearing(settlements:, trailing:)) -> {
            use <- bool.guard(
              settlements != 1,
              violation(
                "settlements",
                "a caller heard "
                  <> int.to_string(settlements)
                  <> " settlements",
              ),
            )
            use <- bool.guard(
              trailing != 0,
              violation("trailing", "a caller heard events after its end"),
            )
            Ok(Nil)
          }
        }
      })
  }
}

// With the service still open and every run ended, the executor's rows go
// (each is removed when the broker releases it, which is a cast, so the check
// waits for the last), the pool has nothing borrowed or held, and the close
// the cases never issued is clean.
fn check_open_service_is_quiet(sut: Sut) -> Result(Nil, Violation) {
  let drained =
    poll.until(within: 4000, every: 20, attempt: fn() {
      case executor.snapshot(sut.plane.service, waiting: 1000) {
        Ok(books) ->
          case books.live {
            [] -> poll.Done(Nil)
            [_, ..] -> poll.Retry
          }
        Error(unreachable) -> poll.Fail(unreachable)
      }
    })
  use _ <- result.try(case drained {
    poll.Answered(Nil) -> Ok(Nil)
    poll.Failed(_) | poll.Expired ->
      violation("row_kept", "the executor kept a row after its run ended")
  })

  let balanced =
    poll.until(within: 4000, every: 20, attempt: fn() {
      case exec.pool_census(sut.plane.pool, waiting: 1000) {
        Ok(census) ->
          case census.borrowed {
            0 -> poll.Done(census)
            _ -> poll.Retry
          }
        Error(refusal) -> poll.Fail(refusal)
      }
    })
  use _ <- result.try(case balanced {
    poll.Failed(_) | poll.Expired ->
      violation("pool_borrowed", "the pool still had a helper borrowed")
    poll.Answered(census) ->
      case census.draining + census.unconfirmed + census.retiring {
        0 -> Ok(Nil)
        held ->
          violation(
            "pool_slots",
            "the pool holds "
              <> int.to_string(held)
              <> " slots after a quiet case",
          )
      }
  })

  case executor.close(sut.plane.service, draining: 400, helpers: 800) {
    Ok(Nil) -> Ok(Nil)
    Error(failure) ->
      violation(
        "quiet_close",
        "a quiet case closed with " <> string.inspect(failure),
      )
  }
}

// The executor holds no row and no relay of this case is alive.
fn check_nothing_left(sut: Sut) -> Result(Nil, Violation) {
  use _ <- result.try(case executor.snapshot(sut.plane.service, waiting: 1000) {
    Ok(books) ->
      case books.live {
        [] -> Ok(Nil)
        [_, ..] -> violation("row_after_close", "the executor still held a row")
      }
    Error(executor.Unreachable) -> Ok(Nil)
  })

  let relays = list.filter_map(inspect(sut).slots, fn(slot) { slot.relay })
  let gone =
    poll.until(within: 4000, every: 20, attempt: fn() {
      case list.any(relays, process.is_alive) {
        True -> poll.Retry
        False -> poll.Done(Nil)
      }
    })
  case gone {
    poll.Answered(Nil) -> Ok(Nil)
    poll.Failed(_) | poll.Expired ->
      violation("relay_outlived", "a relay outlived its run")
  }
}

// By now the first close has answered `Ok`, which the model required of it,
// and a clean close ends the service, so a second finds it gone.
fn check_second_close(sut: Sut) -> Result(Nil, Violation) {
  case executor.close(sut.plane.service, draining: 100, helpers: 100) {
    Error(exec.RetirementOwnerGone) -> Ok(Nil)
    other ->
      violation(
        "second_close",
        "a second close answered " <> string.inspect(other),
      )
  }
}

// --- the tests --------------------------------------------------------------

fn spec() -> statem_parallel.Spec(Model, Command, Sut, Answer) {
  statem_parallel.Spec(
    initial: initial(),
    command: fn(_model) { command_generator() },
    precondition:,
    next_model:,
    new_sut:,
    run:,
    postcondition:,
    finish:,
    teardown:,
  )
}

/// The cases each test draws, and the number of times each runs before it
/// counts as a pass. Forty cases at three runs each take about ten seconds a
/// test: the processes race, so a case that passes once may fail the next
/// time, and repeating it is the cheapest way to look again.
const cases = 40

const repeats = 3

const two_branch_seed = 3100

const three_branch_seed = 3200

/// How long into the test shrinking may begin another candidate, in
/// milliseconds. gleeunit kills a test after fifty seconds and a candidate that
/// is already running is not interrupted, so fifteen seconds leaves the rest
/// for it.
const shrink_budget_ms = 15_000

fn case_config(
  branches branches: Int,
  seed seed: Int,
) -> statem_parallel.Config {
  statem_parallel.default_config(seed:)
  |> statem_parallel.with_test_count(cases)
  |> statem_parallel.with_branches(branches)
  |> statem_parallel.with_max_prefix(max_prefix)
  |> statem_parallel.with_max_branch(max_branch)
  |> statem_parallel.with_repeat(repeats)
  |> statem_parallel.with_max_shrinks(40)
  |> statem_parallel.with_shrink_retries(2)
}

fn check_cases(branches branches: Int, seed seed: Int) -> Nil {
  let stop = planes.shrink_stop_after(within_ms: shrink_budget_ms)
  let config =
    case_config(branches:, seed:) |> statem_parallel.with_shrink_stop(stop)

  case statem_parallel.check(spec(), config) {
    Ok(Nil) -> Nil
    Error(failure) -> panic as statem_parallel.report(failure, describe)
  }
}

/// Two callers on one pool: what each was told fits an order the model
/// agrees with.
pub fn two_callers_on_one_pool_are_linearizable_test() {
  check_cases(branches: 2, seed: two_branch_seed)
}

/// Three callers on one pool.
pub fn three_callers_on_one_pool_are_linearizable_test() {
  check_cases(branches: 3, seed: three_branch_seed)
}

// --- the census -------------------------------------------------------------

fn is_start(command: Command) -> Bool {
  case command {
    Start(..) -> True
    Cancel(..) | KillCaller(..) | Await(..) | Close -> False
  }
}

fn is_close(command: Command) -> Bool {
  case command {
    Close -> True
    Start(..) | Cancel(..) | KillCaller(..) | Await(..) -> False
  }
}

fn is_cancel(command: Command) -> Bool {
  case command {
    Cancel(..) -> True
    Start(..) | KillCaller(..) | Await(..) | Close -> False
  }
}

fn is_kill(command: Command) -> Bool {
  case command {
    KillCaller(..) -> True
    Start(..) | Cancel(..) | Await(..) | Close -> False
  }
}

fn is_await(command: Command) -> Bool {
  case command {
    Await(..) -> True
    Start(..) | Cancel(..) | KillCaller(..) | Close -> False
  }
}

// Whether two branches of one case hold the two kinds of command, one each
// way round.
fn split_across(
  branches: List(List(Command)),
  one: fn(Command) -> Bool,
  other: fn(Command) -> Bool,
) -> Bool {
  list.any(branches, fn(first) {
    list.any(first, one)
    && list.any(branches, fn(second) {
      second != first && list.any(second, other)
    })
  })
}

/// The generator keeps producing the races the tests exist for. Without this a
/// generator that quietly stopped putting a close beside a start, or a cancel
/// beside an await, would leave both tests green on cases that race nothing
/// that matters.
pub fn the_generator_races_the_commands_that_contend_test() {
  let drawn =
    list.flat_map(
      [
        case_config(branches: 2, seed: two_branch_seed),
        case_config(branches: 3, seed: three_branch_seed),
      ],
      fn(config) {
        list.repeat(Nil, cases)
        |> list.index_map(fn(_, run) {
          statem_parallel.generate_case(spec(), config, run)
        })
      },
    )
  let races = fn(one, other) {
    list.any(drawn, fn(drawn_case) {
      split_across(drawn_case.branches, one, other)
    })
  }

  assert races(is_close, is_start)
  assert races(is_close, is_close)
  assert races(is_start, is_start)
  assert races(is_cancel, is_await)
  assert races(is_kill, is_await)
  assert races(is_cancel, is_close)
}
