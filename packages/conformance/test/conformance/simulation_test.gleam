//// The deterministic simulation suite.
////
//// Three things run here. A **fast sweep** of generated seeds, sized to
//// keep `make check-conformance` well under a minute: each seed builds a
//// script, runs it fault-free, runs it again under a generated fault
//// schedule, and holds the pair to every named check. A **coverage**
//// assertion over the same sweep, which is the suite's evidence that the
//// generator reaches the recovery paths the enumerated interleave
//// harness could not — a sweep that never produced a deferred poll would
//// pass every convergence check and prove nothing. And a **pinned
//// corpus**: hand-built script-and-schedule pairs that each found a real
//// defect, kept as cases rather than as seeds because a seed's meaning
//// changes when the generator does.
////
//// The soak suite is opt-in: set `LOOM_SOAK_SEEDS` to the number of
//// seeds to run (and optionally `LOOM_SOAK_FROM` to start elsewhere).
//// `make soak` does both.

import conformance/simulation/fault
import conformance/simulation/random
import conformance/simulation/runner
import conformance/simulation/script
import conformance/simulation/wire
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import machine/operation.{ReplayNever, ReplaySafe}
import support/internal/ffi_shell

// Three chunks so no single eunit test carries the whole sweep.
const sweep_from = 1

const sweep_size = 16

fn sweep(from: Int) -> Nil {
  let failures =
    runner.seeds(from, sweep_size)
    |> list.filter_map(fn(seed) {
      case runner.run(seed:) {
        runner.Passed -> Error(Nil)
        runner.Failed(failure:, reproduce:, ..) ->
          Ok(failure.check <> " — " <> failure.detail <> "\n    " <> reproduce)
      }
    })
  case failures {
    [] -> Nil
    lines ->
      panic as { "simulation failures:\n  " <> string.join(lines, "\n  ") }
  }
}

pub fn simulation_sweep_a_test() {
  sweep(sweep_from)
}

pub fn simulation_sweep_b_test() {
  sweep(sweep_from + sweep_size)
}

pub fn simulation_sweep_c_test() {
  sweep(sweep_from + 2 * sweep_size)
}

// --- coverage -------------------------------------------------------------

/// The paths the generator must reach for the suite to mean anything.
/// The first four are the recovery paths review finding ORCH-H1 named as
/// untested; the rest are the fault taxonomy proving it fires.
const required_paths = [
  "deferred-suspend", "deferred-poll", "threshold-compaction",
  "overflow-compaction", "structural-supplied", "structural-generated",
  "summary-request", "navigation-summarized", "navigation-unsummarized",
  "standalone-compaction", "tool-batch", "retry-ladder", "crash-at-commit",
  "crash-during-effect", "stale-commit-refusal", "lease-theft",
  "transient-read-fault", "slow-effect", "effect-process-died",
  "effect-timed-out", "steer-during-effect", "follow-up-during-effect",
  "abort-during-effect", "abort-at-terminal-commit",
]

pub fn simulation_coverage_test() {
  let reached =
    runner.seeds(sweep_from, 3 * sweep_size)
    |> list.flat_map(fn(seed) { runner.examine(seed:).coverage })
    |> list.unique
  let missing =
    list.filter(required_paths, fn(path) { !list.contains(reached, path) })
  case missing {
    [] -> Nil
    paths -> panic as { "the sweep never reached: " <> string.join(paths, ", ") }
  }
}

// --- the pinned corpus ----------------------------------------------------

pub fn orphaned_deferred_poll_corpus_test() {
  // Found by the sweep before the fix: killing the tree while a deferred
  // poll was in flight left the strand faulting forever. The machine
  // asked whether the captured identity still resolved and then could
  // not consume its own answer, so the poll was never replaced and the
  // run never ended.
  let deferred =
    script.Script(
      registry: [#("read", ReplaySafe), #("write", ReplayNever)],
      tools: [
        #("read", script.ToolOk(text: "out:read")),
        #("write", script.ToolOk(text: "out:write")),
      ],
      ops: [
        script.RunOp(
          prompt: "run this as a batch job",
          settles: [script.Defer, script.Answer(text: "answered", tokens: 5)],
          post: script.Answer(text: "after compaction", tokens: 2),
        ),
      ],
      threshold_after: None,
      structural: script.Supplied,
      interventions: [],
      poll_answer: script.Answer(text: "deferred answer", tokens: 4),
    )
  expect_case(deferred, [fault.CrashDuringEffect(index: 2)])
  expect_case(deferred, [fault.CrashDuringEffect(index: 1)])
}

pub fn steer_racing_a_live_effect_corpus_test() {
  // The interleave harness admitted its steer before driving, so the
  // reload path a concurrent admission forces was never actually raced.
  // Here the steer commits from inside the live assistant effect, so the
  // settlement that follows loses its seq race by construction.
  let raced =
    script.Script(
      registry: [#("read", ReplaySafe), #("write", ReplayNever)],
      tools: [
        #("read", script.ToolOk(text: "out:read")),
        #("write", script.ToolOk(text: "out:write")),
      ],
      ops: [
        script.RunOp(
          prompt: "do the work",
          settles: [
            script.Calls(
              calls: [script.Call(id: "t00write", tool: "write")],
              tokens: 4,
            ),
            script.Answer(text: "answered", tokens: 5),
          ],
          post: script.Answer(text: "after compaction", tokens: 2),
        ),
      ],
      threshold_after: None,
      structural: script.Supplied,
      interventions: [
        script.Steer(trigger: script.DuringTurn(turn: 0), text: "steered"),
      ],
      poll_answer: script.Answer(text: "deferred answer", tokens: 4),
    )
  expect_case(raced, [])
  expect_case(raced, [fault.CrashDuringEffect(index: 2)])
  expect_case(raced, [fault.CrashAtCommit(ordinal: 4)])
}

pub fn abort_at_the_terminal_commit_corpus_test() {
  // The §4.6 race the harness could not reach: the abort request is sent
  // from the writer, after the terminal transaction is durable and
  // before its committer learns of it.
  let terminal =
    script.Script(
      registry: [#("read", ReplaySafe)],
      tools: [#("read", script.ToolOk(text: "out:read"))],
      ops: [
        script.RunOp(
          prompt: "finish quickly",
          settles: [script.Answer(text: "answered", tokens: 5)],
          post: script.Answer(text: "after compaction", tokens: 2),
        ),
      ],
      threshold_after: None,
      structural: script.Supplied,
      interventions: [script.Abort(trigger: script.AtTerminalCommit)],
      poll_answer: script.Answer(text: "deferred answer", tokens: 4),
    )
  expect_case(terminal, [])
  expect_case(terminal, [fault.CrashAtCommit(ordinal: 2)])
}

fn expect_case(scripted: script.Script, faults: List(fault.Fault)) -> Nil {
  case runner.verify_case(scripted, fault.Schedule(faults:)) {
    Ok(Nil) -> Nil
    Error(failure) ->
      panic as {
        failure.check
        <> " — "
        <> failure.detail
        <> " ["
        <> fault.describe(fault.Schedule(faults:))
        <> "]"
      }
  }
}

// --- determinism ----------------------------------------------------------

pub fn one_seed_is_one_script_test() {
  // The whole method rests on this: a seed names a run, so drawing twice
  // from it must draw the same thing, and two seeds must not collide
  // into the same case.
  let #(first, rest) = script.generate(random.from_seed(4242))
  let #(again, rest_again) = script.generate(random.from_seed(4242))
  assert first == again
  let #(schedule, _) = fault.generate(rest, commit_bound: 12, effect_bound: 5)
  let #(schedule_again, _) =
    fault.generate(rest_again, commit_bound: 12, effect_bound: 5)
  assert schedule == schedule_again
}

pub fn split_streams_are_independent_test() {
  // Splitting is what lets the script generator grow without shifting
  // every fault schedule underneath it.
  let rng = random.from_seed(99)
  let #(left, right) = random.split(rng)
  let #(from_left, _) = random.int_between(left, 0, 1_000_000)
  let #(from_right, _) = random.int_between(right, 0, 1_000_000)
  assert from_left != from_right
}

pub fn shrinking_only_offers_smaller_schedules_test() {
  let schedule =
    fault.Schedule(faults: [
      fault.CrashAtCommit(ordinal: 8),
      fault.DropDoorbell(index: 4),
    ])
  let candidates = fault.shrink(schedule)
  // Never the schedule it started from, and never larger than it.
  assert !list.contains(candidates, schedule)
  assert list.all(candidates, fn(candidate: fault.Schedule) {
    list.length(candidate.faults) <= 2
  })
  // Dropping each fault in turn is among the candidates, so the search
  // can always reach the empty schedule.
  assert list.contains(
    candidates,
    fault.Schedule(faults: [fault.DropDoorbell(index: 4)]),
  )
  assert list.contains(
    candidates,
    fault.Schedule(faults: [fault.CrashAtCommit(ordinal: 8)]),
  )
}

pub fn shrinking_a_passing_seed_still_passes_test() {
  let assert runner.Passed = runner.check(seed: 7, shrink_budget: 6)
}

// --- the wire ------------------------------------------------------------

pub fn wire_faults_test() {
  let failures =
    runner.seeds(1, 400)
    |> list.filter_map(fn(seed) {
      case wire.check(seed:) {
        Ok(Nil) -> Error(Nil)
        Error(failure) ->
          Ok(
            "seed "
            <> int.to_string(seed)
            <> ": "
            <> failure.check
            <> " — "
            <> failure.detail,
          )
      }
    })
  case failures {
    [] -> Nil
    lines -> panic as { "wire failures:\n  " <> string.join(lines, "\n  ") }
  }
}

// --- the soak ------------------------------------------------------------

pub fn soak_test() {
  case soak_size() {
    0 -> Nil
    count -> {
      let from = env_int("LOOM_SOAK_FROM", 1)
      case runner.soak(from:, count:) {
        [] -> Nil
        lines -> panic as { "soak failures:\n  " <> string.join(lines, "\n  ") }
      }
    }
  }
}

fn soak_size() -> Int {
  env_int("LOOM_SOAK_SEEDS", 0)
}

fn env_int(name: String, fallback: Int) -> Int {
  ffi_shell.get_env(name)
  |> result.try(int.parse)
  |> result.unwrap(fallback)
}
