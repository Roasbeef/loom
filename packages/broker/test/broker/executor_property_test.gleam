//// Stateful property tests over the executor service: random interleavings
//// of the things that happen to executions, with the invariants every
//// interleaving must keep.
////
//// The pure relay core has its own property tests (`execution_test`). This
//// module covers the service around it, whose coverage was otherwise a set of
//// chosen cases (`executor_test`, `failure_matrix_test`) and one fixed
//// rotation (`leak_census_test`). It is a `statem` spec: a plan is a list of
//// commands, and a command is one thing that happens to the service. A
//// command starts an execution (one that ends at once, one that runs until
//// cancelled, one that ignores cancel, one that floods output; with or
//// without a wall deadline), cancels one by the broker or from the caller's
//// own process, kills a caller, crashes a helper actor, pauses, or closes the
//// service while work is in flight. `execute` performs one command, which is
//// as much interleaving as one process can impose on the service, the
//// broker, the relays and the helpers it is racing.
////
//// The system under test is the plane (pool, executor service, broker)
//// together with the driver's own bookkeeping of what it has started, and
//// the oracle lives there: the model is only how many executions the plan
//// has started, which is all the generator needs to avoid commands that name
//// an execution when none exists. `new_sut` builds a fresh plane in the
//// test's own process and `teardown` closes the service and stops the plane
//// on every path, a failed or crashed execution included, so a case that
//// fails and the shrink candidates after it leave no service behind to
//// disturb the next. Because `teardown` owns that, no case needs a process
//// of its own. Shrinking is bounded twice, because executions are not a
//// measure of time here: `max_shrinks` bounds it by executions, and a
//// deadline read when the test starts (`shrink_budget_ms`) stops it by wall
//// time, so the shrunk-so-far plan is reported before gleeunit's fifty
//// second kill.
////
//// Each plan must leave the same things true, each reported under its own
//// violation tag so that shrinking holds on to the invariant that broke
//// and cannot slide to another one:
////
//// - every caller that was not killed hears exactly one settlement, or was
////   refused at clearance and hears none, and hears nothing after it
////   (`never_heard`, `settlements`, `trailing`);
//// - when everything has ended the executor holds no row and every relay is
////   dead (`row_kept`, `row_after_close`, `relay_outlived`);
//// - with the service still open, the pool has nothing borrowed, and holds as
////   unconfirmed, draining or retiring only slots that a helper the run killed
////   or an execution that ignored cancel could account for
////   (`pool_borrowed`, `pool_slots`, `pool_quiet_slots`);
//// - a plan that did nothing a fake helper cannot attest to (no crash, no
////   cancel-ignoring execution) closes with `Ok` (`quiet_close`); and
//// - a second `close` returns the stored verdict, or says the service is gone
////   when the first answered `Ok` (`second_close`).
////
//// Two further tags report that the driver itself waited in vain: a call that
//// never reported its clearance (`clearance_hang`), and a close that never
//// answered (`close_hang`).
////
//// A failing plan is shrunk by deleting commands from anywhere in the list,
//// not only from the end, and then by pulling each remaining command toward a
//// plain start of a quick execution with no deadline, so what remains is the
//// few commands the invariant needs. A command names its target by a raw
//// pick, resolved by `execute` modulo the executions started so far, so
//// removing an earlier command retargets the later ones rather than
//// invalidating them.
////
//// What a seed reproduces is the plan, not the schedule: the real processes
//// still race, so a plan that fails once may need several runs to fail
//// again. The check therefore retries each shrink candidate
//// (`shrink_retries`): a candidate counts as still failing if any of its runs
//// fails with the original tag, which keeps a scheduling-sensitive failure
//// from being shrunk away by one lucky run. The retries cost nothing while
//// the plans pass. The pool size is fixed per check, so each test runs its
//// plans once for each of `pool_sizes`; a quiet plan and a faulty plan are
//// two tests, with their own seeds, so the quiet plans are not the faulty
//// ones with the faults filtered out. The fixed seeds make the plans the gate
//// draws the same on every machine.

import broker/broker
import broker/exec
import broker/executor
import broker/support/fake_helper
import broker/support/planes
import gleam/bool
import gleam/dict
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import qcheck
import statem.{type Violation, Admit, Reject, Violation}
import weft/poll

// --- the commands -----------------------------------------------------------

// What an execution does, by the argv word the fake helper reads.
type Kind {
  Quick
  Sleeper
  Stubborn
  Flood
}

// Whether the call carries a wall deadline. The session clock is fixed, so a
// deadline a hundred milliseconds ahead of it fires about that long after the
// relay starts.
type Deadline {
  NoDeadline
  WallDeadline
}

// One thing `execute` does. A `pick` is a raw draw, resolved against the
// executions started so far when the command runs, so a plan is a plain list
// that can be printed and replayed, and a command survives the removal of an
// earlier one.
type Command {
  Start(kind: Kind, deadline: Deadline)
  BrokerCancel(pick: Int)
  CallerCancel(pick: Int)
  KillCaller(pick: Int)
  CrashHelper(pick: Int)
  Pause(ms: Int)
  CloseMidRun
}

// Whether a plan may crash a helper or start an execution that ignores
// cancel. A quiet plan has neither, which makes a clean close the only right
// answer.
type Faults {
  Quiet
  Faulty
}

// How many executions the plan has started, which is all the generator and
// the precondition need: a command that names an execution is meaningless
// before the first start. A start the broker refuses still counts here, and
// a pick that then finds nothing running is a pause.
type Model {
  Model(starts: Int)
}

/// The plans each check draws for each pool size, and the seed a test draws
/// them from. The two tests have their own seeds, so the quiet plans are not
/// the faulty ones with the faults filtered out; the pool sizes add their own
/// size to the seed so they draw different plans too. Twelve plans a test,
/// split over the three pool sizes.
const plans_per_pool = 4

const quiet_seed = 1000

const faulty_seed = 2000

/// The pools a plan is run against. Three is the smallest the plans are
/// written for; five leaves room for every start of a long plan to be lent a
/// helper at once, and four sits between them.
const pool_sizes = [3, 4, 5]

/// The most commands in one plan.
const plan_length = 22

/// How many times a shrink candidate is run before it is called passing. The
/// processes race, so a plan that failed once may pass on its next run, and
/// one lucky run would otherwise end the shrink at a larger plan than the
/// failure needs. Two runs make that unlikely, and the price is paid only
/// while shrinking.
const shrink_retries = 2

/// The most executions one shrink may spend, retries included. This is the
/// second bound: it ends the shrink early and reports the smallest plan found
/// so far, which is not always the smallest there is.
const max_shrinks = 8

/// How long into the test shrinking may begin another candidate, in
/// milliseconds. gleeunit kills a test after fifty seconds, and one failing
/// execution can wait out the driver's longest bounds: `await_heard` twelve
/// seconds, `close_hang` eight, or up to four seconds for each of the three
/// polls (inventory, pool, relays), and a candidate runs `shrink_retries`
/// times. The deadline is read when the test starts and checked before each
/// candidate, so a candidate already running is not interrupted. Fifteen
/// seconds leaves thirty-five for the one candidate that may be running when
/// the deadline passes, which covers a candidate that waits out the longest
/// single bound on both of its runs; one that waits out several bounds on
/// both runs can still overrun the kill.
const shrink_budget_ms = 15_000

fn plan_config(seed seed: Int) -> statem.Config {
  statem.default_config(seed:)
  |> statem.with_test_count(plans_per_pool)
  |> statem.with_max_commands(plan_length)
  |> statem.with_max_shrinks(max_shrinks)
  |> statem.with_shrink_retries(shrink_retries)
}

fn spec(faults: Faults, pool_size: Int) -> statem.Spec(Model, Command, Sut) {
  statem.Spec(
    initial: Model(starts: 0),
    command: fn(_model) { command_generator(faults) },
    precondition:,
    next_model:,
    new_sut: fn() { new_sut(faults, pool_size) },
    execute:,
    finish:,
    teardown:,
  )
}

// Every field of a command is drawn, whichever command it turns out to be,
// and each shrinks toward zero: the first kind of command is a start, its
// first kind is the quick one, and zero is no deadline.
fn command_generator(faults: Faults) -> qcheck.Generator(Command) {
  let drawn =
    qcheck.map5(
      qcheck.bounded_int(from: 0, to: 19),
      qcheck.bounded_int(from: 0, to: 1000),
      qcheck.bounded_int(from: 0, to: 7),
      qcheck.bounded_int(from: 0, to: 3),
      qcheck.bounded_int(from: 0, to: 40),
      command_of,
    )
  case faults {
    Quiet -> qcheck.map(drawn, without_faults)
    Faulty -> drawn
  }
}

fn command_of(
  which: Int,
  pick: Int,
  kind: Int,
  deadline: Int,
  pause: Int,
) -> Command {
  case which {
    0 | 1 | 2 | 3 | 4 | 5 ->
      Start(kind: kind_of(kind), deadline: case deadline {
        3 -> WallDeadline
        _ -> NoDeadline
      })
    6 | 7 -> BrokerCancel(pick:)
    8 | 9 -> CallerCancel(pick:)
    10 -> KillCaller(pick:)
    11 -> CrashHelper(pick:)
    12 | 13 | 14 | 15 | 16 | 17 | 18 -> Pause(ms: pause)
    _ -> CloseMidRun
  }
}

fn kind_of(draw: Int) -> Kind {
  case draw {
    0 | 1 -> Quick
    2 | 3 | 4 -> Sleeper
    5 -> Stubborn
    _ -> Flood
  }
}

fn without_faults(command: Command) -> Command {
  case command {
    Start(kind: Stubborn, deadline:) -> Start(kind: Sleeper, deadline:)
    CrashHelper(..) -> Pause(ms: 5)
    Start(..)
    | BrokerCancel(..)
    | CallerCancel(..)
    | KillCaller(..)
    | Pause(..)
    | CloseMidRun -> command
  }
}

// A command that names an execution is admitted only once the plan has
// started one, so a generated or shrunk plan never spends its commands on
// targets that cannot exist.
fn precondition(model: Model, command: Command) -> statem.Admission {
  case command {
    Start(..) | Pause(..) | CloseMidRun -> Admit
    BrokerCancel(..) | CallerCancel(..) | KillCaller(..) | CrashHelper(..) ->
      case model.starts {
        0 -> Reject
        _ -> Admit
      }
  }
}

fn next_model(model: Model, command: Command) -> Model {
  case command {
    Start(..) -> Model(starts: model.starts + 1)
    BrokerCancel(..)
    | CallerCancel(..)
    | KillCaller(..)
    | CrashHelper(..)
    | Pause(..)
    | CloseMidRun -> model
  }
}

fn word_of(kind: Kind) -> String {
  case kind {
    Quick -> "ok"
    Sleeper -> "sleep"
    Stubborn -> "stubborn"
    Flood -> "flood"
  }
}

// --- the callers ------------------------------------------------------------

// What a caller tells the driver once its call is cleared or refused.
type First {
  Started(
    handle: broker.CallHandle,
    control: Subject(Control),
    relay: Result(Pid, Nil),
  )
  Refused
}

// What the driver can ask of a caller that is still alive.
type Control {
  CancelNow
}

// What a caller heard, once its execution settled.
type Heard {
  Heard(index: Int, settlements: Int, trailing: Int)
}

// What the driver keeps of an execution it started.
type Running {
  Running(
    index: Int,
    kind: Kind,
    caller: Pid,
    handle: broker.CallHandle,
    control: Subject(Control),
    relay: Result(Pid, Nil),
    helper: exec.Helper,
    caller_killed: Killed,
  )
}

type Killed {
  Alive
  Dead
}

fn spawn_caller(
  plane: planes.Plane,
  index: Int,
  kind: Kind,
  deadline: Deadline,
  first: Subject(First),
  heard: Subject(Heard),
) -> Pid {
  process.spawn_unlinked(fn() {
    let events = process.new_subject()
    let control = process.new_subject()
    let spec = planes.spec(planes.op(), argv: [word_of(kind)], deadline_ms: 0)
    let spec =
      broker.CallSpec(
        ..spec,
        step_id: "step-" <> int.to_string(index),
        budget: broker_budget(deadline),
      )
    case broker.clear_call(plane.broker, spec, events:, waiting: 1000) {
      Error(_refusal) -> process.send(first, Refused)
      Ok(handle) -> {
        let relay = broker.relay_pid(plane.broker, handle, waiting: 1000)
        process.send(first, Started(handle:, control:, relay:))
        let settlements =
          listen(plane.broker, handle, events, control, settled: 0)
        let trailing = count_trailing(events, 0)
        process.send(heard, Heard(index:, settlements:, trailing:))
      }
    }
  })
}

fn broker_budget(deadline: Deadline) {
  let wall = case deadline {
    NoDeadline -> 0
    WallDeadline -> 1100
  }
  planes.spec(planes.op(), argv: [], deadline_ms: wall).budget
}

// Reads the call's events and the driver's instructions until the call
// settles, or until ten quiet seconds say it never will.
fn listen(
  broker_actor: broker.Broker,
  handle: broker.CallHandle,
  events: Subject(broker.CallEvent),
  control: Subject(Control),
  settled settled: Int,
) -> Int {
  let selector =
    process.new_selector()
    |> process.select_map(events, fn(event) { Ok(event) })
    |> process.select_map(control, fn(_instruction) { Error(Nil) })
  case process.selector_receive(selector, 10_000) {
    Error(Nil) -> settled
    Ok(Ok(broker.CallOutput(..))) ->
      listen(broker_actor, handle, events, control, settled:)
    Ok(Ok(broker.CallSettled(..))) -> settled + 1
    Ok(Error(Nil)) -> {
      broker.cancel(broker_actor, handle)
      listen(broker_actor, handle, events, control, settled:)
    }
  }
}

// How many events arrive after the settlement, which must be none.
fn count_trailing(events: Subject(broker.CallEvent), seen: Int) -> Int {
  case process.receive(events, 80) {
    Ok(_) -> count_trailing(events, seen + 1)
    Error(Nil) -> seen
  }
}

// --- the driver -------------------------------------------------------------

// The system under test: the plane, and everything the driver carries between
// commands, which is also the oracle's whole memory of the plan.
type Sut {
  Sut(
    faults: Faults,
    plane: planes.Plane,
    heard: Subject(Heard),
    started: List(Running),
    refused: Int,
    crashed: List(Pid),
    stubborn_started: Int,
    closer: Option(Subject(Result(Nil, exec.RetirementFailure))),
  )
}

// A plane of fake helpers made fresh for one execution of a plan. It is built
// in the calling process, so the `borrowed` subject and every subject the
// driver makes belong to the process that reads them.
fn new_sut(faults: Faults, pool_size: Int) -> Sut {
  let plane =
    planes.start_scripted(size: pool_size, script: fn() {
      fake_helper.start_helper_configured(
        fake_helper.ByArgv,
        cancel_grace_ms: 300,
        heartbeat_interval_ms: 0,
      )
    })
  Sut(
    faults:,
    plane:,
    heard: process.new_subject(),
    started: [],
    refused: 0,
    crashed: [],
    stubborn_started: 0,
    closer: None,
  )
}

// Dismantles the plane, whichever way the plan ended. After
// a plan that closed the service already, the close answers the stored verdict
// at once; after one that failed with the service still serving, it is what
// retires the executions the plan left behind.
fn teardown(sut: Sut) -> Nil {
  planes.dismantle(sut.plane)
}

fn violation(tag: String, detail: String) -> Result(a, Violation) {
  Error(Violation(tag:, detail:))
}

fn execute(
  sut: Sut,
  _model: Model,
  command: Command,
) -> Result(Sut, Violation) {
  case command {
    Start(kind:, deadline:) -> start_one(sut, kind, deadline)
    Pause(ms:) -> {
      process.sleep(ms)
      Ok(sut)
    }
    BrokerCancel(pick:) -> {
      use target <- with_target(sut, pick)
      broker.cancel(sut.plane.broker, target.handle)
    }
    CallerCancel(pick:) -> {
      use target <- with_target(sut, pick)
      process.send(target.control, CancelNow)
    }
    KillCaller(pick:) -> Ok(kill_caller(sut, pick))
    CrashHelper(pick:) -> Ok(crash_helper(sut, pick))
    CloseMidRun -> Ok(close_mid_run(sut))
  }
}

// Applies `act` to the execution a pick names, if any has started. A command
// with nothing to act on is a pause, so a plan never fails for lack of a
// target.
fn with_target(
  sut: Sut,
  pick: Int,
  act: fn(Running) -> Nil,
) -> Result(Sut, Violation) {
  case target_of(sut, pick) {
    Ok(target) -> act(target)
    Error(Nil) -> Nil
  }
  Ok(sut)
}

// The execution a pick names: the pick modulo the number started, so any
// pick resolves once one has.
fn target_of(sut: Sut, pick: Int) -> Result(Running, Nil) {
  case list.length(sut.started) {
    0 -> Error(Nil)
    count -> list.drop(sut.started, pick % count) |> list.first
  }
}

fn start_one(
  sut: Sut,
  kind: Kind,
  deadline: Deadline,
) -> Result(Sut, Violation) {
  let index = list.length(sut.started) + sut.refused
  let first = process.new_subject()
  let caller = spawn_caller(sut.plane, index, kind, deadline, first, sut.heard)
  let stubborn_started = case kind {
    Stubborn -> sut.stubborn_started + 1
    Quick | Sleeper | Flood -> sut.stubborn_started
  }
  case process.receive(first, 4000) {
    Ok(Started(handle:, control:, relay:)) -> {
      let helper = latest_borrowed(sut.plane)
      let running =
        Running(
          index:,
          kind:,
          caller:,
          handle:,
          control:,
          relay:,
          helper:,
          caller_killed: Alive,
        )
      Ok(Sut(..sut, started: [running, ..sut.started], stubborn_started:))
    }
    Ok(Refused) -> Ok(Sut(..sut, refused: sut.refused + 1, stubborn_started:))

    // A caller that reports nothing in four seconds is a hang in
    // `clear_call`, which has its own bounds, so it is a failure here.
    Error(Nil) ->
      violation("clearance_hang", "a caller never reported its clearance")
  }
}

fn kill_caller(sut: Sut, pick: Int) -> Sut {
  case target_of(sut, pick) {
    Error(Nil) -> sut
    Ok(target) -> {
      process.kill(target.caller)
      let started =
        list.map(sut.started, fn(running) {
          case running.index == target.index {
            True -> Running(..running, caller_killed: Dead)
            False -> running
          }
        })
      Sut(..sut, started:)
    }
  }
}

fn crash_helper(sut: Sut, pick: Int) -> Sut {
  case target_of(sut, pick) {
    Error(Nil) -> sut
    Ok(target) -> {
      let pid = exec.pid(target.helper)
      process.kill(pid)
      case list.contains(sut.crashed, pid) {
        True -> sut
        False -> Sut(..sut, crashed: [pid, ..sut.crashed])
      }
    }
  }
}

fn close_mid_run(sut: Sut) -> Sut {
  case sut.closer {
    Some(_) -> sut
    None -> {
      let verdicts = process.new_subject()
      let service = sut.plane.service
      process.spawn_unlinked(fn() {
        process.send(
          verdicts,
          executor.close(service, draining: 400, helpers: 800),
        )
      })
      Sut(..sut, closer: Some(verdicts))
    }
  }
}

// Every checkout is announced on the plane's `borrowed` subject, so after a
// successful clearance the newest announcement is the helper just lent, and
// the older ones are read past.
fn latest_borrowed(plane: planes.Plane) -> exec.Helper {
  let assert Ok(first) = process.receive(plane.borrowed, 2000)
    as "a cleared call borrowed a helper"
  newest(plane, first)
}

fn newest(plane: planes.Plane, so_far: exec.Helper) -> exec.Helper {
  case process.receive(plane.borrowed, 0) {
    Ok(later) -> newest(plane, later)
    Error(Nil) -> so_far
  }
}

// --- the verdict ------------------------------------------------------------

// Ends the plan: everything still running is cancelled, and then each
// invariant is read in the order it can first be seen.
fn finish(sut: Sut, _model: Model) -> Result(Nil, Violation) {
  // End everything that is still running. The plan's own cancels may not
  // have reached it, and a stubborn one needs its grace to expire.
  list.each(sut.started, fn(target) {
    broker.cancel(sut.plane.broker, target.handle)
  })
  use _ <- result.try(check_heard_exactly_once(sut))
  use verdict <- result.try(settle_the_service(sut))
  use _ <- result.try(check_nothing_left(sut))
  check_second_close(sut, verdict)
}

// Every caller the plan did not kill heard one settlement and then nothing.
fn check_heard_exactly_once(sut: Sut) -> Result(Nil, Violation) {
  let expected =
    list.filter(sut.started, fn(target) { target.caller_killed == Alive })
  let wanted = list.map(expected, fn(target) { target.index })
  let heard = await_heard(sut.heard, wanted, dict.new())
  list.try_each(expected, fn(target) {
    let caller = "caller " <> int.to_string(target.index)
    case dict.get(heard, target.index) {
      Error(Nil) ->
        violation("never_heard", caller <> " never heard its settlement")
      Ok(Heard(settlements:, trailing:, ..)) -> {
        use <- bool.guard(
          settlements != 1,
          violation(
            "settlements",
            caller <> " heard " <> int.to_string(settlements) <> " settlements",
          ),
        )
        use <- bool.guard(
          trailing != 0,
          violation("trailing", caller <> " heard events after its settlement"),
        )
        Ok(Nil)
      }
    }
  })
}

// Reads reports until every wanted caller has reported, or twelve quiet
// seconds say one never will. A caller the plan killed after it had settled
// may also report, so the count of reports is not the test: the wanted
// indices are.
fn await_heard(
  heard: Subject(Heard),
  wanted: List(Int),
  seen: dict.Dict(Int, Heard),
) -> dict.Dict(Int, Heard) {
  case list.all(wanted, dict.has_key(seen, _)) {
    True -> seen
    False ->
      case process.receive(heard, 12_000) {
        Ok(Heard(index:, ..) as report) ->
          await_heard(heard, wanted, dict.insert(seen, index, report))
        Error(Nil) -> seen
      }
  }
}

// Gets the service closed and answers the first verdict. With no close in the
// plan the pool is read first, while the service is still open.
fn settle_the_service(
  sut: Sut,
) -> Result(Result(Nil, exec.RetirementFailure), Violation) {
  let faults = list.length(sut.crashed) + sut.stubborn_started
  case sut.closer {
    Some(verdicts) ->
      case process.receive(verdicts, 8000) {
        Ok(verdict) -> {
          use _ <- result.try(check_clean_when_quiet(sut, verdict))
          Ok(verdict)
        }
        Error(Nil) -> violation("close_hang", "the close never answered")
      }
    None -> {
      use _ <- result.try(check_inventory_drains(sut))
      use _ <- result.try(check_pool_baseline(sut, faults))
      let verdict =
        executor.close(sut.plane.service, draining: 400, helpers: 800)
      use _ <- result.try(check_clean_when_quiet(sut, verdict))
      Ok(verdict)
    }
  }
}

// A plan with no fault a fake cannot attest to closes with `Ok`.
fn check_clean_when_quiet(
  sut: Sut,
  verdict: Result(Nil, exec.RetirementFailure),
) -> Result(Nil, Violation) {
  case sut.faults, verdict {
    Quiet, Error(_) ->
      violation(
        "quiet_close",
        "a plan with no faults closed with " <> string.inspect(verdict),
      )
    Quiet, Ok(Nil) | Faulty, _ -> Ok(Nil)
  }
}

// With the service still open and every execution ended, the executor's rows
// go: each is removed when the broker releases it, which is a cast, so the
// check waits for the last one. This is the check that sees a row that a
// release forgot, which a close would otherwise sweep up unseen.
fn check_inventory_drains(sut: Sut) -> Result(Nil, Violation) {
  let drained =
    poll.until(within: 4000, every: 20, attempt: fn() {
      case executor.snapshot(sut.plane.service, waiting: 1000) {
        Ok(books) ->
          case books.live {
            [] -> poll.Done(Nil)
            _rows -> poll.Retry
          }
        Error(unreachable) -> poll.Fail(unreachable)
      }
    })
  case drained {
    poll.Answered(Nil) -> Ok(Nil)
    poll.Failed(_) | poll.Expired ->
      violation("row_kept", "the executor kept a row after its execution ended")
  }
}

// Nothing borrowed once the executions ended, and the slots held beyond that
// are the ones a killed helper or an execution that ignored cancel can
// account for; a plan with neither holds none.
fn check_pool_baseline(sut: Sut, faults: Int) -> Result(Nil, Violation) {
  let balanced =
    poll.until(within: 4000, every: 20, attempt: fn() {
      case exec.pool_census(sut.plane.pool, waiting: 1000) {
        Ok(census) ->
          case census.borrowed == 0 {
            True -> poll.Done(census)
            False -> poll.Retry
          }
        Error(refusal) -> poll.Fail(refusal)
      }
    })
  case balanced {
    poll.Failed(_) | poll.Expired ->
      violation("pool_borrowed", "the pool still had a helper borrowed")
    poll.Answered(census) -> {
      let held = census.draining + census.unconfirmed + census.retiring
      use <- bool.guard(
        held > faults,
        violation(
          "pool_slots",
          "the pool holds "
            <> int.to_string(held)
            <> " slots for "
            <> int.to_string(faults)
            <> " faults",
        ),
      )
      use <- bool.guard(
        faults == 0 && held != 0,
        violation("pool_quiet_slots", "a quiet plan left slots held"),
      )
      Ok(Nil)
    }
  }
}

// The executor holds no row and no relay of this run is alive.
fn check_nothing_left(sut: Sut) -> Result(Nil, Violation) {
  use _ <- result.try(case executor.snapshot(sut.plane.service, waiting: 1000) {
    Ok(books) ->
      case books.live {
        [] -> Ok(Nil)
        _rows -> violation("row_after_close", "the executor still held a row")
      }
    Error(executor.Unreachable) -> Ok(Nil)
  })
  let relays = list.filter_map(sut.started, fn(target) { target.relay })
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
      violation("relay_outlived", "a relay outlived its execution")
  }
}

// A second close returns the stored verdict, and an `Ok` one ended the
// service, so it finds no process.
fn check_second_close(
  sut: Sut,
  first: Result(Nil, exec.RetirementFailure),
) -> Result(Nil, Violation) {
  let second = executor.close(sut.plane.service, draining: 100, helpers: 100)
  let expected = case first {
    Ok(Nil) -> Error(exec.RetirementOwnerGone)
    Error(_) -> first
  }
  case second == expected {
    True -> Ok(Nil)
    False ->
      violation(
        "second_close",
        "a second close answered "
          <> string.inspect(second)
          <> " after "
          <> string.inspect(first),
      )
  }
}

// --- the tests --------------------------------------------------------------

// Checks `plans_per_pool` plans against each pool size, and panics with the
// shrunk plan of the first that fails. The shrink deadline is read here, once,
// so the pool sizes share one budget of the test's wall time.
fn check_plans(faults: Faults, seed seed: Int) -> Nil {
  let stop = planes.shrink_stop_after(within_ms: shrink_budget_ms)

  list.each(pool_sizes, fn(size) {
    let config = plan_config(seed: seed + size) |> statem.with_shrink_stop(stop)

    case statem.check(spec(faults, size), config) {
      Ok(Nil) -> Nil
      Error(failure) ->
        panic as {
          "pool of "
          <> int.to_string(size)
          <> ": "
          <> statem.report(failure, string.inspect)
        }
    }
  })
}

/// Plans with no crash and no cancel-ignoring execution keep every invariant,
/// and close cleanly.
pub fn quiet_plans_keep_every_invariant_and_close_cleanly_test() {
  check_plans(Quiet, seed: quiet_seed)
}

/// Plans that crash helpers and ignore cancel keep the invariants that hold
/// whatever the faults.
pub fn faulty_plans_keep_every_invariant_test() {
  check_plans(Faulty, seed: faulty_seed)
}

/// The generator reaches every kind of command in the faulty plans, and the
/// quiet plans never draw a fault. Without this a generator that quietly
/// stopped producing crashes would leave the faulty test passing on plans no
/// harder than the quiet ones.
pub fn the_generators_reach_the_commands_each_test_needs_test() {
  // The plans the tests themselves draw: every run of every pool size, under
  // the seed the test gives that size.
  let drawn = fn(faults, seed) {
    list.flat_map(pool_sizes, fn(size) {
      list.repeat(Nil, plans_per_pool)
      |> list.index_map(fn(_, run) {
        statem.commands(spec(faults, size), plan_config(seed: seed + size), run)
      })
      |> list.flatten
    })
  }
  let faulty = drawn(Faulty, faulty_seed)
  let quiet = drawn(Quiet, quiet_seed)

  assert list.any(faulty, fn(command) {
    command == Start(kind: Stubborn, deadline: NoDeadline)
    || command == Start(kind: Stubborn, deadline: WallDeadline)
  })
  assert list.any(faulty, fn(command) {
    case command {
      CrashHelper(..) -> True
      Start(..)
      | BrokerCancel(..)
      | CallerCancel(..)
      | KillCaller(..)
      | Pause(..)
      | CloseMidRun -> False
    }
  })
  assert list.any(faulty, fn(command) { command == CloseMidRun })
  assert list.any(faulty, fn(command) {
    command == Start(kind: Flood, deadline: WallDeadline)
  })
  assert list.any(faulty, fn(command) {
    case command {
      KillCaller(..) -> True
      Start(..)
      | BrokerCancel(..)
      | CallerCancel(..)
      | CrashHelper(..)
      | Pause(..)
      | CloseMidRun -> False
    }
  })

  assert !list.any(quiet, fn(command) {
    case command {
      CrashHelper(..) | Start(kind: Stubborn, ..) -> True
      Start(..)
      | BrokerCancel(..)
      | CallerCancel(..)
      | KillCaller(..)
      | Pause(..)
      | CloseMidRun -> False
    }
  })
}
