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

// The terminal-write check asks whether the run wrote once per operation,
// and answers it by counting down through the outcomes rather than by
// measuring them. Exactness is the point — a run one write short and a run
// one write over are both failures the suite must report — so the count is
// pinned at the bound and one place either side of it.
pub fn counts_exactly_is_exact_at_the_bound_test() {
  assert runner.counts_exactly([], 0)
  assert runner.counts_exactly(["a", "b", "c"], 3)
  assert !runner.counts_exactly(["a", "b"], 3)
  assert !runner.counts_exactly(["a", "b", "c", "d"], 3)
  assert !runner.counts_exactly(["a"], 0)
  assert !runner.counts_exactly([], 1)
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
  "abort-during-effect", "abort-at-terminal-commit", "subagent-spawn",
  "cross-strand-message",
  // The M3 escalation-boundary wave (SIM-6): parallel batch frontiers,
  // the raise → approve → consume escalation dance, and the partial
  // crash that restarts one strand driver mid-effect. A sweep that
  // never reached these could not regress on RT-esc-attribution,
  // RT-esc-double, or RT-restart-leak.
  "parallel-tools", "escalation-raised", "escalation-consumed",
  "strand-restart-during-effect",
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
      subagent: None,
      parallel: False,
      escalate: False,
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
      subagent: None,
      parallel: False,
      escalate: False,
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
      subagent: None,
      parallel: False,
      escalate: False,
    )
  expect_case(terminal, [])
  expect_case(terminal, [fault.CrashAtCommit(ordinal: 2)])
}

pub fn crash_on_the_terminal_commit_corpus_test() {
  // Found by a soak at seed 5377, and the reason the runner now waits
  // for the writer's post-commit seam before taking a terminal result.
  // A terminal-racing intervention holds that seam open; the commit it
  // was armed on is already visible in the store, so the runner used to
  // call the run finished while the crash was still queued behind the
  // intervention, and reported a bomb that never went off.
  //
  // Kept as a case rather than as a seed because the generator no longer
  // draws a steer at the terminal commit — a hand-built script still
  // can, and the runner must still fire the crash under it.
  let racing =
    script.Script(
      registry: [#("read", ReplaySafe)],
      tools: [#("read", script.ToolOk(text: "out:read"))],
      ops: [
        script.RunOp(
          prompt: "answer and finish",
          settles: [script.Answer(text: "answered", tokens: 5)],
          post: script.Answer(text: "after compaction", tokens: 2),
        ),
      ],
      threshold_after: None,
      structural: script.Generated(split: False),
      interventions: [
        script.Steer(trigger: script.AtTerminalCommit, text: "steered"),
      ],
      poll_answer: script.Answer(text: "deferred answer", tokens: 4),
      subagent: None,
      parallel: False,
      escalate: False,
    )
  // The shape this case depends on: the terminal transaction is the last
  // of six commits, so a crash armed there is armed on the seam that the
  // intervention holds open. Asserted, so a change in the commit
  // sequence retires the case loudly instead of quietly.
  assert runner.execute(racing, fault.none()).commits == 6
  expect_case(racing, [fault.CrashAtCommit(ordinal: 6)])
  expect_case(racing, [fault.CrashAtCommit(ordinal: 5)])
}

pub fn intervention_commit_reply_loss_corpus_test() {
  // Seed 33 combines a follow-up during the first provider turn with a tree
  // crash and a stolen lease. Before the intervention admission carried a
  // durable identity, the runner could spend its in-memory one-shot and then
  // lose the writer reply: some runs finished three tokens short with an
  // unmatched `intervening@follow-up-during-effect`. Repeating the exact seed
  // exercises the live scheduler interleaving that exposed the defect while
  // keeping the script and fault schedule fixed.
  repeat_seed(33, times: 12)
}

pub fn simultaneous_abort_and_steer_corpus_test() {
  // Seed 584 puts an abort and a steer at the same live trigger. Linux ran the
  // abort cast before the following admission on every corroboration, while
  // macOS admitted the steer first. The script must have one fault-free
  // baseline rather than asking the scheduler which transcript is canonical.
  repeat_seed(584, times: 12)
}

fn repeat_seed(seed: Int, times times: Int) -> Nil {
  case times <= 0 {
    True -> Nil
    False ->
      case runner.run(seed:) {
        runner.Passed -> repeat_seed(seed, times: times - 1)
        runner.Failed(failure:, reproduce:, ..) ->
          panic as {
            failure.check <> " — " <> failure.detail <> "\n    " <> reproduce
          }
      }
  }
}

pub fn strand_restart_mid_parallel_batch_corpus_test() {
  // RT-restart-leak: a strand-actor restart (the tree survives) used to
  // leak the dying incarnation's live effects, so recovery re-executed a
  // tool concurrently with its still-running first execution. Pinned
  // with a parallel two-call batch whose second call is `replay: Never`:
  // the restart lands while both tool effects are live, the reaper must
  // take both down, and recovery replays the safe call while the never
  // call comes back as the synthetic interruption.
  let batch =
    script.Script(
      registry: [#("read", ReplaySafe), #("write", ReplayNever)],
      tools: [
        #("read", script.ToolOk(text: "out:read")),
        #("write", script.ToolOk(text: "out:write")),
      ],
      ops: [
        script.RunOp(
          prompt: "fan out",
          settles: [
            script.Calls(
              calls: [
                script.Call(id: "t00read", tool: "read"),
                script.Call(id: "t01write", tool: "write"),
              ],
              tokens: 4,
            ),
            script.Answer(text: "answered", tokens: 5),
          ],
          post: script.Answer(text: "after compaction", tokens: 2),
        ),
      ],
      threshold_after: None,
      structural: script.Supplied,
      interventions: [],
      poll_answer: script.Answer(text: "deferred answer", tokens: 4),
      subagent: None,
      parallel: True,
      escalate: False,
    )
  // The shape the indices depend on: one generation, two overlapped
  // tools, one closing generation. Asserted so a dispatch-order change
  // retires the case loudly.
  assert runner.execute(batch, fault.none()).effects == 4
  expect_case(batch, [fault.RestartStrand(index: 2)])
  expect_case(batch, [fault.RestartStrand(index: 3)])
  expect_case(batch, [
    fault.RestartStrand(index: 2),
    fault.DropDoorbell(index: 1),
  ])
}

pub fn escalation_dance_under_crashes_corpus_test() {
  // RT-esc-attribution / RT-esc-double: the scripted escalation dance —
  // raise scoped to the exact call, approve, driver restart, re-clear,
  // consume-before-clear — must converge under crashes aimed at the
  // commits the dance itself makes. A crash that costs the approval is
  // allowed to cost exactly that (the re-cleared call runs under base
  // policy); it must never change the transcript or double-run the tool.
  let danced =
    script.Script(
      registry: [#("read", ReplaySafe), #("write", ReplayNever)],
      tools: [
        #("read", script.ToolOk(text: "out:read")),
        #("write", script.ToolOk(text: "out:write")),
      ],
      ops: [
        script.RunOp(
          prompt: "ask for more",
          settles: [
            script.Calls(
              calls: [script.Call(id: "t00write", tool: "write")],
              tokens: 3,
            ),
            script.Answer(text: "answered", tokens: 5),
          ],
          post: script.Answer(text: "after compaction", tokens: 2),
        ),
      ],
      threshold_after: None,
      structural: script.Supplied,
      interventions: [],
      poll_answer: script.Answer(text: "deferred answer", tokens: 4),
      subagent: None,
      parallel: False,
      escalate: True,
    )
  // Enough commits that the crash ordinals below land inside the run —
  // the raise, the approval, and the consumption are all in there.
  assert runner.execute(danced, fault.none()).commits >= 8
  expect_case(danced, [])
  expect_case(danced, [fault.CrashAtCommit(ordinal: 4)])
  expect_case(danced, [fault.CrashAtCommit(ordinal: 6)])
  expect_case(danced, [fault.CrashAtCommit(ordinal: 8)])
  expect_case(danced, [fault.RestartStrand(index: 2)])
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
