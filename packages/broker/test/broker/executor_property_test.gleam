//// Property tests over the executor service: seeded random interleavings of
//// the things that happen to executions, with the invariants every
//// interleaving must keep.
////
//// The pure relay core has its own property tests (`execution_test`). This
//// module covers the service around it, whose coverage was otherwise a set of
//// chosen cases (`executor_test`, `failure_matrix_test`) and one fixed
//// rotation (`leak_census_test`). A seed draws a plan: a pool size and a list
//// of steps. A step starts an execution (one that ends at once, one that runs
//// until cancelled, one that ignores cancel, one that floods output; with or
//// without a wall deadline), cancels one by the broker or from the caller's
//// own process, kills a caller, crashes a helper actor, pauses, or closes the
//// service while work is in flight. The driver performs the steps in order,
//// which is as much interleaving as one process can impose on the service, the
//// broker, the relays and the helpers it is racing.
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
//// A seed reproduces the plan, which is printed in every failure message, and
//// not the schedule: the real processes still race, so a failing plan may need
//// a few runs. `LOOM_EXECUTOR_PROPERTY_SEEDS` sets how many seeds each test
//// draws (default 12), and the failing seed names the run to repeat.

import broker/broker
import broker/exec
import broker/executor
import broker/support/bench_host as host
import broker/support/fake_helper
import broker/support/planes
import broker/support/seeded
import gleam/dict
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
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
// that can be printed and replayed.
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
  Plan(seed: Int, pool_size: Int, quiet: Bool, steps: List(Step))
}

// A plan for a seed. A quiet plan has no crash and no cancel-ignoring
// execution, which makes a clean close the only right answer.
fn plan_for(seed_value: Int, quiet quiet: Bool) -> Plan {
  let seed = seeded.new(seed_value)
  let #(pool_size, seed) = seeded.between(seed, 3, 5)
  let #(length, seed) = seeded.between(seed, 10, 22)
  let #(steps, _seed) = seeded.repeat(seed, length, step_from)
  let steps = case quiet {
    True -> list.map(steps, without_faults)
    False -> steps
  }
  Plan(seed: seed_value, pool_size:, quiet:, steps:)
}

fn step_from(seed: seeded.Seed) -> #(Step, seeded.Seed) {
  let #(which, seed) = seeded.between(seed, 0, 19)
  let #(pick, seed) = seeded.between(seed, 0, 1000)
  let #(kind, seed) = seeded.between(seed, 0, 7)
  let #(deadline, seed) = seeded.between(seed, 0, 3)
  let #(pause, seed) = seeded.between(seed, 0, 40)
  let step = case which {
    0 | 1 | 2 | 3 | 4 | 5 ->
      Start(kind: kind_of(kind), deadline: case deadline {
        0 -> WallDeadline
        _ -> NoDeadline
      })
    6 | 7 -> BrokerCancel(pick:)
    8 | 9 -> CallerCancel(pick:)
    10 -> KillCaller(pick:)
    11 -> CrashHelper(pick:)
    12 | 13 | 14 | 15 | 16 | 17 | 18 -> Pause(ms: pause)
    _ -> CloseMidRun
  }
  #(step, seed)
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
  "seed "
  <> int.to_string(plan.seed)
  <> " (replay with the plan below)\n"
  <> string.inspect(plan)
}

fn run_plan(plan: Plan) -> Nil {
  let plane =
    planes.start_scripted(size: plan.pool_size, script: fn() {
      fake_helper.start_helper_configured(
        fake_helper.ByArgv,
        cancel_grace_ms: 300,
        heartbeat_interval_ms: 0,
      )
    })
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
  planes.stop(plane)
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

fn seed_count() -> Int {
  host.getenv("LOOM_EXECUTOR_PROPERTY_SEEDS")
  |> result.try(int.parse)
  |> result.unwrap(12)
}

// The seeds a test draws: `seed_count` consecutive ones from `first`, or the
// single seed named by `LOOM_EXECUTOR_PROPERTY_ONLY` when it falls in this
// test's range, which is how a failing seed is replayed on its own.
fn seeds_from(first: Int) -> List(Int) {
  let only = host.getenv("LOOM_EXECUTOR_PROPERTY_ONLY") |> result.try(int.parse)
  case only {
    Ok(seed_value) if seed_value >= first && seed_value < first + 1000 -> [
      seed_value,
    ]
    Ok(_) -> []
    Error(Nil) ->
      list.index_map(list.repeat(Nil, seed_count()), fn(_, offset) {
        first + offset
      })
  }
}

fn each_seed(first first: Int, quiet quiet: Bool) -> Nil {
  list.each(seeds_from(first), fn(seed_value) {
    let plan = plan_for(seed_value, quiet:)

    // A replay of one seed prints its plan whole, because the failure
    // message is cut short by the test runner.
    case host.getenv("LOOM_EXECUTOR_PROPERTY_ONLY") {
      Ok(_) -> io.println_error(describe(plan))
      Error(Nil) -> Nil
    }
    run_plan(plan)
  })
}

/// Plans with no crash and no cancel-ignoring execution keep every invariant,
/// and close cleanly.
pub fn quiet_plans_keep_every_invariant_and_close_cleanly_test() {
  each_seed(first: 1000, quiet: True)
}

/// Plans that crash helpers and ignore cancel keep the invariants that hold
/// whatever the faults.
pub fn faulty_plans_keep_every_invariant_test() {
  each_seed(first: 2000, quiet: False)
}
