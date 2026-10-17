//// Property tests over the executor service: random interleavings of the
//// things that happen to executions, with the invariants every interleaving
//// must keep.
////
//// The pure relay core has its own property tests (`execution_test`). This
//// module covers the service around it, whose coverage was otherwise a set of
//// chosen cases (`executor_test`, `failure_matrix_test`) and one fixed
//// rotation (`leak_census_test`). A qcheck generator draws a plan: a pool size
//// and a list of steps. A step starts an execution (one that ends at once, one
//// that runs until cancelled, one that ignores cancel, one that floods output;
//// with or without a wall deadline), cancels one by the broker or from the
//// caller's own process, kills a caller, crashes a helper actor, pauses, or
//// closes the service while work is in flight. The driver performs the steps
//// in order, which is as much interleaving as one process can impose on the
//// service, the broker, the relays and the helpers it is racing.
////
//// Each plan must leave the same things true:
////
//// - every caller that was not killed hears exactly one settlement, or was
////   refused at clearance and hears none, and hears nothing after it;
//// - when everything has ended the executor holds no row and every relay is
////   dead;
//// - with the service still open, the pool has nothing borrowed, and holds as
////   unconfirmed, draining or retiring only slots that a helper the run killed
////   or an execution that ignored cancel could account for;
//// - a plan that did nothing a fake helper cannot attest to (no crash, no
////   cancel-ignoring execution) closes with `Ok`; and
//// - a second `close` returns the stored verdict, or says the service is gone
////   when the first answered `Ok`.
////
//// A failing plan is reported already shrunk. The pool shrinks toward three
//// helpers, the plan toward fewer steps, and each step toward a plain start
//// of a quick execution with no deadline, so what remains is the few steps
//// the invariant needs. A step names its target by a raw pick resolved
//// against the executions started so far, so removing an earlier step
//// retargets the later ones rather than invalidating them.
////
//// What a seed reproduces is the plan, not the schedule: the real processes
//// still race, so a plan that fails once may need several runs to fail
//// again. Two choices follow from that. Every case runs its own plane in a
//// process of its own (`planes.isolated`), so a case that panics, and the
//// shrink candidates after it, leave no service behind to disturb the next.
//// The properties retry each shrink candidate (`shrink_retries`): a
//// candidate counts as still failing if any of its runs fails, which keeps a
//// scheduling-sensitive failure from being shrunk away by one lucky run. The
//// retries cost nothing while the properties pass, because qcheck uses them
//// only on candidates it is already shrinking. And shrinking is bounded in
//// wall time (`shrink_budget_ms`), because a failure that waits out a poll
//// deadline would otherwise shrink past gleeunit's per-test timeout and
//// lose the report; a run that hits the bound reports the smallest plan
//// found so far, which is not always the smallest there is. The run uses fixed qcheck
//// seeds, so the plans the gate draws are the same on every machine.

import broker/broker
import broker/exec
import broker/executor
import broker/support/fake_helper
import broker/support/planes
import gleam/dict
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import qcheck
import weft/poll

// --- the plan ---------------------------------------------------------------

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

// One thing the driver does. A `pick` is a raw draw, resolved against the
// executions started so far when the step runs, so a plan is a plain list
// that can be printed and replayed, and a step survives the removal of an
// earlier one.
type Step {
  Start(kind: Kind, deadline: Deadline)
  BrokerCancel(pick: Int)
  CallerCancel(pick: Int)
  KillCaller(pick: Int)
  CrashHelper(pick: Int)
  Pause(ms: Int)
  CloseMidRun
}

type Plan {
  Plan(pool_size: Int, quiet: Bool, steps: List(Step))
}

/// The number of plans each test checks, and the seed each draws them from.
/// The two tests have their own seeds, so the quiet plans are not the faulty
/// ones with the faults filtered out.
const plan_count = 12

const quiet_seed = 1000

const faulty_seed = 2000

/// How many times qcheck runs a shrink candidate before it calls it passing.
/// The processes race, so a plan that failed once may pass on its next run,
/// and one lucky run would otherwise end the shrink at a larger plan than
/// the failure needs. Two runs make that unlikely, and the price is paid
/// only while shrinking.
const shrink_retries = 2

/// How long shrinking may go on after the first failure. A candidate that
/// fails on a poll deadline takes several seconds to do it, and gleeunit
/// kills a test after fifty, before qcheck reports anything; the budget ends
/// the shrink early instead and reports the smallest plan found so far.
const shrink_budget_ms = 25_000

fn plan_config(seed seed: Int) -> qcheck.Config {
  qcheck.default_config()
  |> qcheck.with_test_count(plan_count)
  |> qcheck.with_seed(qcheck.seed(seed))
  |> qcheck.with_max_retries(shrink_retries)
}

// A plan of three to five helpers and one to twenty-two steps. A quiet plan
// has no crash and no cancel-ignoring execution, which makes a clean close
// the only right answer.
fn plan_generator(quiet quiet: Bool) -> qcheck.Generator(Plan) {
  let steps =
    qcheck.generic_list(
      elements_from: step_generator(),
      length_from: qcheck.bounded_int(from: 1, to: 22),
    )
    |> qcheck.map(fn(steps) {
      case quiet {
        True -> list.map(steps, without_faults)
        False -> steps
      }
    })
  qcheck.map2(qcheck.bounded_int(from: 3, to: 5), steps, fn(pool_size, steps) {
    Plan(pool_size:, quiet:, steps:)
  })
}

// Every field of a step is drawn, whichever step it turns out to be, and
// each shrinks toward zero: the first kind of step is a start, its first
// kind is the quick one, and zero is no deadline.
fn step_generator() -> qcheck.Generator(Step) {
  qcheck.map5(
    qcheck.bounded_int(from: 0, to: 19),
    qcheck.bounded_int(from: 0, to: 1000),
    qcheck.bounded_int(from: 0, to: 7),
    qcheck.bounded_int(from: 0, to: 3),
    qcheck.bounded_int(from: 0, to: 40),
    step_of,
  )
}

fn step_of(
  which: Int,
  pick: Int,
  kind: Int,
  deadline: Int,
  pause: Int,
) -> Step {
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

fn without_faults(step: Step) -> Step {
  case step {
    Start(kind: Stubborn, deadline:) -> Start(kind: Sleeper, deadline:)
    CrashHelper(..) -> Pause(ms: 5)
    other -> other
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

// Everything the driver carries between steps.
type Run {
  Run(
    plan: Plan,
    plane: planes.Plane,
    heard: Subject(Heard),
    started: List(Running),
    refused: Int,
    crashed: List(Pid),
    stubborn_started: Int,
    closer: Option(Subject(Result(Nil, exec.RetirementFailure))),
  )
}

fn drive(run: Run, steps: List(Step)) -> Run {
  case steps {
    [] -> run
    [step, ..rest] -> drive(perform(run, step), rest)
  }
}

fn perform(run: Run, step: Step) -> Run {
  case step {
    Start(kind:, deadline:) -> start_one(run, kind, deadline)
    Pause(ms:) -> {
      process.sleep(ms)
      run
    }
    BrokerCancel(pick:) -> {
      use target <- with_target(run, pick)
      broker.cancel(run.plane.broker, target.handle)
    }
    CallerCancel(pick:) -> {
      use target <- with_target(run, pick)
      process.send(target.control, CancelNow)
    }
    KillCaller(pick:) -> kill_caller(run, pick)
    CrashHelper(pick:) -> crash_helper(run, pick)
    CloseMidRun -> close_mid_run(run)
  }
}

// Applies `act` to the execution a pick names, if any has started. A step
// with nothing to act on is a pause, so a plan never fails for lack of a
// target.
fn with_target(run: Run, pick: Int, act: fn(Running) -> Nil) -> Run {
  case list.length(run.started) {
    0 -> Nil
    count -> {
      let assert Ok(target) = list.drop(run.started, pick % count) |> list.first
        as "a pick resolves to a started execution"
      act(target)
    }
  }
  run
}

fn start_one(run: Run, kind: Kind, deadline: Deadline) -> Run {
  let index = list.length(run.started) + run.refused
  let first = process.new_subject()
  let caller = spawn_caller(run.plane, index, kind, deadline, first, run.heard)
  let stubborn_started = case kind {
    Stubborn -> run.stubborn_started + 1
    Quick | Sleeper | Flood -> run.stubborn_started
  }
  case process.receive(first, 4000) {
    Ok(Started(handle:, control:, relay:)) -> {
      let helper = latest_borrowed(run.plane)
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
      Run(..run, started: [running, ..run.started], stubborn_started:)
    }
    Ok(Refused) -> Run(..run, refused: run.refused + 1, stubborn_started:)
    Error(Nil) -> {
      // A caller that reports nothing in four seconds is a hang in
      // `clear_call`, which has its own bounds, so it is a failure here.
      panic as {
        describe(run.plan) <> ": a caller never reported its clearance"
      }
    }
  }
}

fn kill_caller(run: Run, pick: Int) -> Run {
  case list.length(run.started) {
    0 -> run
    count -> {
      let at = pick % count
      let started =
        list.index_map(run.started, fn(target, position) {
          case position == at {
            True -> {
              process.kill(target.caller)
              Running(..target, caller_killed: Dead)
            }
            False -> target
          }
        })
      Run(..run, started:)
    }
  }
}

fn crash_helper(run: Run, pick: Int) -> Run {
  case list.length(run.started) {
    0 -> run
    count -> {
      let assert Ok(target) = list.drop(run.started, pick % count) |> list.first
        as "a pick resolves to a started execution"
      let pid = exec.pid(target.helper)
      process.kill(pid)
      case list.contains(run.crashed, pid) {
        True -> run
        False -> Run(..run, crashed: [pid, ..run.crashed])
      }
    }
  }
}

fn close_mid_run(run: Run) -> Run {
  case run.closer {
    Some(_) -> run
    None -> {
      let verdicts = process.new_subject()
      let service = run.plane.service
      process.spawn_unlinked(fn() {
        process.send(
          verdicts,
          executor.close(service, draining: 400, helpers: 800),
        )
      })
      Run(..run, closer: Some(verdicts))
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

fn describe(plan: Plan) -> String {
  "plan " <> string.inspect(plan)
}

fn run_plan(plan: Plan, budget: planes.Budget) -> Nil {
  planes.isolated(
    size: plan.pool_size,
    script: fn() {
      fake_helper.start_helper_configured(
        fake_helper.ByArgv,
        cancel_grace_ms: 300,
        heartbeat_interval_ms: 0,
      )
    },
    within: 120_000,
    budget:,
    body: fn(plane) { drive_plan(plan, plane) },
  )
}

// One plan over one plane, which `run_plan` stops afterwards whether this
// returns or panics.
fn drive_plan(plan: Plan, plane: planes.Plane) -> Nil {
  let heard = process.new_subject()
  let run =
    Run(
      plan:,
      plane:,
      heard:,
      started: [],
      refused: 0,
      crashed: [],
      stubborn_started: 0,
      closer: None,
    )
  let run = drive(run, plan.steps)

  // End everything that is still running. The plan's own cancels may not
  // have reached it, and a stubborn one needs its grace to expire.
  list.each(run.started, fn(target) {
    broker.cancel(plane.broker, target.handle)
  })
  assert_heard_exactly_once(run)

  let verdict = settle_the_service(run)
  assert_nothing_left(run)
  assert_second_close(run, verdict)
}

// Every caller the plan did not kill heard one settlement and then nothing.
fn assert_heard_exactly_once(run: Run) -> Nil {
  let expected =
    list.filter(run.started, fn(target) { target.caller_killed == Alive })
  let wanted = list.map(expected, fn(target) { target.index })
  let heard = await_heard(run.heard, wanted, dict.new())
  list.each(expected, fn(target) {
    let assert Ok(Heard(settlements:, trailing:, ..)) =
      dict.get(heard, target.index)
      as {
        describe(run.plan)
        <> ": caller "
        <> int.to_string(target.index)
        <> " never heard its settlement"
      }
    assert settlements == 1
      as {
        describe(run.plan)
        <> ": caller "
        <> int.to_string(target.index)
        <> " heard "
        <> int.to_string(settlements)
        <> " settlements"
      }
    assert trailing == 0
      as {
        describe(run.plan)
        <> ": caller "
        <> int.to_string(target.index)
        <> " heard events after its settlement"
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
fn settle_the_service(run: Run) -> Result(Nil, exec.RetirementFailure) {
  let faults = list.length(run.crashed) + run.stubborn_started
  case run.closer {
    Some(verdicts) -> {
      let assert Ok(verdict) = process.receive(verdicts, 8000)
        as { describe(run.plan) <> ": the close never answered" }
      assert_clean_when_quiet(run, verdict)
      verdict
    }
    None -> {
      assert_inventory_drains(run)
      assert_pool_baseline(run, faults)
      let verdict =
        executor.close(run.plane.service, draining: 400, helpers: 800)
      assert_clean_when_quiet(run, verdict)
      verdict
    }
  }
}

// A plan with no fault a fake cannot attest to closes with `Ok`.
fn assert_clean_when_quiet(
  run: Run,
  verdict: Result(Nil, exec.RetirementFailure),
) -> Nil {
  case run.plan.quiet {
    True -> {
      assert verdict == Ok(Nil)
        as {
          describe(run.plan)
          <> ": a plan with no faults closed with "
          <> string.inspect(verdict)
        }
    }
    False -> Nil
  }
}

// With the service still open and every execution ended, the executor's rows
// go: each is removed when the broker releases it, which is a cast, so the
// check waits for the last one. This is the check that sees a row that a
// release forgot, which a close would otherwise sweep up unseen.
fn assert_inventory_drains(run: Run) -> Nil {
  let assert poll.Answered(Nil) =
    poll.until(within: 4000, every: 20, attempt: fn() {
      case executor.snapshot(run.plane.service, waiting: 1000) {
        Ok(books) ->
          case books.live {
            [] -> poll.Done(Nil)
            _rows -> poll.Retry
          }
        Error(unreachable) -> poll.Fail(unreachable)
      }
    })
    as {
      describe(run.plan)
      <> ": the executor kept a row after its execution ended"
    }
  Nil
}

// Nothing borrowed once the executions ended, and the slots held beyond that
// are the ones a killed helper or an execution that ignored cancel can
// account for; a plan with neither holds none.
fn assert_pool_baseline(run: Run, faults: Int) -> Nil {
  let assert poll.Answered(census) =
    poll.until(within: 6000, every: 20, attempt: fn() {
      case exec.pool_census(run.plane.pool, waiting: 1000) {
        Ok(census) ->
          case census.borrowed == 0 {
            True -> poll.Done(census)
            False -> poll.Retry
          }
        Error(refusal) -> poll.Fail(refusal)
      }
    })
    as { describe(run.plan) <> ": the pool still had a helper borrowed" }
  let held = census.draining + census.unconfirmed + census.retiring
  assert held <= faults
    as {
      describe(run.plan)
      <> ": the pool holds "
      <> int.to_string(held)
      <> " slots for "
      <> int.to_string(faults)
      <> " faults"
    }
  case faults {
    0 -> {
      assert held == 0
        as { describe(run.plan) <> ": a quiet plan left slots held" }
    }
    _ -> Nil
  }
}

// The executor holds no row and no relay of this run is alive.
fn assert_nothing_left(run: Run) -> Nil {
  case executor.snapshot(run.plane.service, waiting: 1000) {
    Ok(books) -> {
      assert books.live == []
        as { describe(run.plan) <> ": the executor still held a row" }
    }
    Error(executor.Unreachable) -> Nil
  }
  let relays = list.filter_map(run.started, fn(target) { target.relay })
  let assert poll.Answered(Nil) =
    poll.until(within: 4000, every: 20, attempt: fn() {
      case list.any(relays, process.is_alive) {
        True -> poll.Retry
        False -> poll.Done(Nil)
      }
    })
    as { describe(run.plan) <> ": a relay outlived its execution" }
  Nil
}

// A second close returns the stored verdict, and an `Ok` one ended the
// service, so it finds no process.
fn assert_second_close(
  run: Run,
  first: Result(Nil, exec.RetirementFailure),
) -> Nil {
  let second = executor.close(run.plane.service, draining: 100, helpers: 100)
  let expected = case first {
    Ok(Nil) -> Error(exec.RetirementOwnerGone)
    Error(_) -> first
  }
  assert second == expected
    as {
      describe(run.plan)
      <> ": a second close answered "
      <> string.inspect(second)
      <> " after "
      <> string.inspect(first)
    }
}

// --- the tests --------------------------------------------------------------

/// Plans with no crash and no cancel-ignoring execution keep every invariant,
/// and close cleanly.
pub fn quiet_plans_keep_every_invariant_and_close_cleanly_test() {
  let budget = planes.shrink_budget(ms: shrink_budget_ms)
  qcheck.run(
    plan_config(seed: quiet_seed),
    plan_generator(quiet: True),
    run_plan(_, budget),
  )
}

/// Plans that crash helpers and ignore cancel keep the invariants that hold
/// whatever the faults.
pub fn faulty_plans_keep_every_invariant_test() {
  let budget = planes.shrink_budget(ms: shrink_budget_ms)
  qcheck.run(
    plan_config(seed: faulty_seed),
    plan_generator(quiet: False),
    run_plan(_, budget),
  )
}
