//// The shrinker's two acceptance rules, and the daemon candidates they
//// govern.
////
//// `runner.minimize` takes a probe rather than running a session, so these
//// tests stage a failure deterministically: a probe says which schedule
//// fails which check, and a counter from the simulation's own control actor
//// says how many times it has been asked. No real run is involved, which is
//// the only way to make a candidate fail on *some* runs on purpose.
////
//// Each rule has the test that fails when the rule is removed:
////
//// - **Same check.** A smaller schedule that breaks a different check is not
////   accepted (`shrinking_never_slips_to_another_check_test`).
//// - **Corroboration.** A candidate that fails on its first run and passes on
////   a later one is not accepted (`a_candidate_that_fails_once_is_not_accepted_test`),
////   and one that does fail every time pays exactly the corroboration's runs
////   (`a_reproducible_candidate_pays_the_corroboration_runs_test`).
////
//// The original failure's corroboration is held to the same check rule:
//// a re-run that fails another check makes the seed unstable
//// (`a_rerun_that_fails_another_check_is_unstable_test`).
////
//// The daemon half pins the candidates `daemon_fault.shrink` offers and the
//// single candidate `lifecycle_faults.shrink` does, then runs the real
//// shrinkers against seeds that pass, where nothing may be accepted.

import conformance/simulation/control
import conformance/simulation/daemon/daemon_fault
import conformance/simulation/daemon/daemon_runner
import conformance/simulation/daemon/lifecycle_faults
import conformance/simulation/daemon/lifecycle_runner
import conformance/simulation/fault
import conformance/simulation/runner.{type Failure, Failure}
import gleam/list
import gleam/option.{None, Some}

const crash = fault.CrashAtCommit(ordinal: 8)

const doorbell = fault.DropDoorbell(index: 4)

const slow = fault.SlowEffect(index: 2, delay_ms: 250)

fn schedule(faults: List(fault.Fault)) -> fault.Schedule {
  fault.Schedule(faults:)
}

fn fails(check: String) -> Result(Nil, Failure) {
  Error(Failure(check, "staged"))
}

fn minimize(
  start: fault.Schedule,
  probe: fn(fault.Schedule) -> Result(Nil, Failure),
) -> #(fault.Schedule, Failure) {
  runner.minimize(
    from: start,
    failing: Failure("x", "original"),
    candidates: fault.shrink,
    probe:,
    reprobe: probe,
    budget: 12,
  )
}

pub fn shrinking_never_slips_to_another_check_test() {
  // The crash is what fails `x`. The doorbell alone fails a different check,
  // and it is the first candidate offered (drop the crash). Accepting it
  // would report a minimal schedule for a failure nobody asked about.
  let probe = fn(candidate: fault.Schedule) {
    case
      list.contains(candidate.faults, crash),
      list.contains(candidate.faults, doorbell)
    {
      True, _ -> fails("x")
      False, True -> fails("other")
      False, False -> Ok(Nil)
    }
  }
  let #(smallest, failure) = minimize(schedule([crash, doorbell]), probe)
  assert smallest == schedule([crash])
  assert failure.check == "x"
}

pub fn a_candidate_that_fails_once_is_not_accepted_test() {
  // Dropping the crash leaves the doorbell alone, which fails `x` on its
  // first run and passes after: a racy candidate. It is offered before the
  // stable one and would be accepted on one run.
  let counter = control.start()
  let probe = fn(candidate: fault.Schedule) {
    case candidate.faults {
      [only] if only == doorbell ->
        case control.bump(counter, "doorbell-alone") {
          1 -> fails("x")
          _later -> Ok(Nil)
        }
      faults ->
        case list.contains(faults, crash) {
          True -> fails("x")
          False -> Ok(Nil)
        }
    }
  }
  let #(smallest, _failure) = minimize(schedule([crash, doorbell]), probe)
  assert smallest == schedule([crash])
  // It was asked more than once, so the rejection came from a confirming
  // run rather than from never being tried.
  assert control.read(counter, "doorbell-alone") == 2
  control.stop(counter)
}

pub fn a_reproducible_candidate_pays_the_corroboration_runs_test() {
  // Start at crash@8. Candidates, in order: the empty schedule (one run,
  // passes), crash@4 (fails `x` every time: its first run and every
  // confirming one). From crash@4: the empty schedule and crash@2, both
  // pass in one run. The cost is therefore the confirming runs plus four
  // single-run candidates.
  let counter = control.start()
  let probe = fn(candidate: fault.Schedule) {
    control.bump(counter, "runs")
    case candidate == schedule([fault.CrashAtCommit(ordinal: 4)]) {
      True -> fails("x")
      False -> Ok(Nil)
    }
  }
  let #(smallest, _failure) = minimize(schedule([crash]), probe)
  assert smallest == schedule([fault.CrashAtCommit(ordinal: 4)])
  let candidate_runs = 1 + runner.corroboration_runs
  assert control.read(counter, "runs") == candidate_runs + 3
  control.stop(counter)
}

pub fn a_three_fault_schedule_reduces_to_the_one_that_fails_test() {
  // The regression the shrinker was built for, staged: only the crash fails,
  // and the other two faults are noise a reader should not have to read.
  let probe = fn(candidate: fault.Schedule) {
    case list.contains(candidate.faults, crash) {
      True -> fails("x")
      False -> Ok(Nil)
    }
  }
  let #(smallest, _failure) = minimize(schedule([crash, doorbell, slow]), probe)
  assert smallest == schedule([crash])
}

pub fn a_zero_budget_keeps_the_case_as_drawn_test() {
  let #(smallest, failure) =
    runner.minimize(
      from: schedule([crash]),
      failing: Failure("x", "original"),
      candidates: fault.shrink,
      probe: fn(_candidate) { fails("x") },
      reprobe: fn(_candidate) { fails("x") },
      budget: 0,
    )
  assert smallest == schedule([crash])
  assert failure.detail == "original"
}

pub fn a_rerun_that_fails_another_check_is_unstable_test() {
  // The original failed `x`. The first re-run repeats it; the second fails
  // `other`, which is a different verdict from the same script and schedule
  // and so no corroboration. Accepting any failure here would call this seed
  // reproducible.
  let counter = control.start()
  let rerun = fn() {
    case control.bump(counter, "reruns") {
      1 -> fails("x")
      _later -> fails("other")
    }
  }
  assert runner.corroborate("x", rerun) == runner.Unstable(failed: 2, of: 3)
  control.stop(counter)
}

pub fn reruns_that_all_fail_the_same_check_are_reproducible_test() {
  let rerun = fn() { fails("x") }
  assert runner.corroborate("x", rerun)
    == runner.Reproducible(runs: 1 + runner.corroboration_runs)
}

// --- the daemon candidates -----------------------------------------------

const creations = [#("a", "w1"), #("b", "w1"), #("c", "w2")]

fn kill(key: String, workspace: String, step: daemon_fault.Step) {
  daemon_fault.Schedule(faults: [
    daemon_fault.KillDaemonAt(key:, workspace:, step:),
  ])
}

pub fn a_daemon_kill_is_pulled_to_an_earlier_step_or_creation_test() {
  // The empty schedule first, then the same creation one step earlier, then
  // the creation before it at the same step.
  assert daemon_fault.shrink(
      kill("c", "w2", daemon_fault.AfterConfirm),
      creations,
    )
    == [
      daemon_fault.none(),
      kill("c", "w2", daemon_fault.AfterCustodyPublish),
      kill("b", "w1", daemon_fault.AfterConfirm),
    ]
}

pub fn a_daemon_kill_is_never_pulled_to_an_unreachable_step_test() {
  // `b` shares a workspace with `a`, so it never enters the domain build and
  // `AfterReservation` would park nothing. The step is not offered, and the
  // earlier creation, which opens the workspace, is.
  assert daemon_fault.shrink(
      kill("b", "w1", daemon_fault.AfterDomainBind),
      creations,
    )
    == [
      daemon_fault.none(),
      kill("a", "w1", daemon_fault.AfterDomainBind),
    ]
  assert daemon_fault.shrink(
      kill("a", "w1", daemon_fault.AfterReservation),
      creations,
    )
    == [daemon_fault.none()]
  assert daemon_fault.shrink(daemon_fault.none(), creations) == []
}

pub fn a_daemon_failure_shrinks_by_the_same_rules_test() {
  // Every kill of `c` fails `x`; any kill of `b` fails `y`. The walk takes
  // `c` down to its earliest step, and the earlier-creation candidate, which
  // fails another check, is never taken.
  let probe = fn(candidate: daemon_fault.Schedule) {
    case daemon_fault.scheduled(candidate) {
      Some(daemon_fault.KillDaemonAt(key: "c", ..)) -> fails("x")
      Some(daemon_fault.KillDaemonAt(key: "b", ..)) -> fails("y")
      Some(daemon_fault.KillDaemonAt(..)) | None -> Ok(Nil)
    }
  }
  let #(smallest, failure) =
    runner.minimize(
      from: kill("c", "w2", daemon_fault.AfterConfirm),
      failing: Failure("x", "original"),
      candidates: fn(candidate) { daemon_fault.shrink(candidate, creations) },
      probe:,
      reprobe: probe,
      budget: 12,
    )
  assert smallest == kill("c", "w2", daemon_fault.AfterReservation)
  assert failure.check == "x"
}

// --- the lifecycle candidates --------------------------------------------

pub fn a_lifecycle_fault_has_only_the_fault_free_candidate_test() {
  let kill =
    lifecycle_faults.KillDaemonWithPending(
      session: "s",
      request: lifecycle_faults.PendingOpen,
    )
  let revoke =
    lifecycle_faults.RevokeAt(
      principal: "p",
      at: lifecycle_faults.BeforeAdmission,
    )
  assert lifecycle_faults.shrink(kill) == [lifecycle_faults.FaultFree]
  assert lifecycle_faults.shrink(revoke) == [lifecycle_faults.FaultFree]
  assert lifecycle_faults.shrink(lifecycle_faults.FaultFree) == []
}

pub fn a_lifecycle_check_names_its_script_test() {
  assert lifecycle_runner.script_of("lifecycle/no-resend")
    == Some(lifecycle_runner.RestartScript)
  assert lifecycle_runner.script_of("revocation/silence-after-close")
    == Some(lifecycle_runner.RevocationScript)
  assert lifecycle_runner.script_of("harness/start") == None
}

// --- the real shrinkers, over seeds that pass ----------------------------

pub fn the_daemon_shrinker_keeps_a_schedule_nothing_fails_under_test() {
  // Seed 2 passes. No candidate fails, so none can be accepted and the
  // schedule comes back as drawn: shrinking can fail to shrink, and never
  // invents a failure.
  let #(_script, drawn) = daemon_runner.plan(2)
  let #(smallest, _failure) =
    daemon_runner.shrink(2, "replay/equal-catalogue-rows", budget: 6)
  assert smallest == drawn
}

pub fn the_lifecycle_shrinker_keeps_a_fault_nothing_fails_under_test() {
  let drawn = lifecycle_runner.drawn_fault(4471, lifecycle_runner.RestartScript)
  let assert Some(#(smallest, _failure)) =
    lifecycle_runner.shrink(4471, "lifecycle/no-resend", budget: 4)
  assert smallest == drawn
}
