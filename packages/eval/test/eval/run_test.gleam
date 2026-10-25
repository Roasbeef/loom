import client/secrets
import eval/arm.{type Arm, Arm, Knobs, PromptPack}
import eval/budget
import eval/ledger.{type Row, Row}
import eval/plan.{type Plan}
import eval/repos
import eval/run
import eval/run_cli
import eval/task.{type Task}
import eval/trial
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import provider/pricing
import simplifile
import support/scripted

type Rig {
  Rig(plan: Plan, loaded: run.Loaded, ctx: trial.Context, out: String)
}

fn rig(
  name: String,
  tasks: List(Task),
  arms: List(Arm),
  trials: Int,
  concurrency: Int,
  max_dollars: Float,
  wall_ms: Int,
  input_tokens: Int,
) -> Rig {
  let root = scripted.scratch(name)
  let frozen =
    scripted.plan_of(tasks, arms, trials, concurrency, max_dollars, wall_ms)
  let base = scripted.base(root <> "/base", scripted.transport(input_tokens))

  Rig(
    plan: frozen,
    loaded: run.Loaded(frozen, tasks, arms),
    ctx: trial.Context(
      base:,
      lane: trial.Live,
      budgets: frozen.budgets,
      plan_id: frozen.id,
      seams: trial.default_seams(trial.refuse_program),
      repos: repos.empty(),
      selftest: trial.unprobed,
    ),
    out: root <> "/runs",
  )
}

fn with_seams(rig: Rig, seams: trial.Seams) -> Rig {
  Rig(..rig, ctx: trial.Context(..rig.ctx, seams:))
}

fn rows_of(directory: String) -> List(Row) {
  let assert Ok(text) = simplifile.read(directory <> "/trials.jsonl")
  let assert Ok(rows) = ledger.parse(text)

  rows
}

fn finished(rows: List(Row)) -> List(Row) {
  list.filter(rows, fn(row) { row.state != ledger.Running })
}

pub fn scripted_plan_writes_every_row_test_() -> scripted.EunitTest {
  scripted.Timeout(300, fn() {
    scripted.when_available("scripted_plan_writes_every_row", fn() {
      let tasks = [
        scripted.task_named("first", "hello", "hello"),
        scripted.task_named("second", "world", "world"),
      ]
      let arms = [scripted.baseline(), scripted.suffixed()]
      let r = rig("every-row", tasks, arms, 2, 2, 100.0, 60_000, 1)

      let assert Ok(summary) = run.execute(r.ctx, r.loaded, r.out)
      let rows = rows_of(summary.directory)

      // Eight cells, each a Running row then its scored row.
      assert summary.started == 8
      assert list.length(rows) == 16
      assert list.length(finished(rows)) == 8
      assert list.all(finished(rows), fn(row) {
        row.state == ledger.Scored && row.outcome == Some(ledger.Passed)
      })
      assert list.all(finished(rows), fn(row) { row.turns == 2 })
      assert list.all(finished(rows), fn(row) { row.tool_calls == 1 })
      assert list.all(finished(rows), fn(row) { row.served != [] })
      let assert Ok(_) = ledger.reconcile(r.plan, rows)

      // The report names the verdict the design could reach with two tasks.
      let assert Ok(json_text) =
        simplifile.read(summary.directory <> "/report.json")
      let assert Ok(markdown) =
        simplifile.read(summary.directory <> "/report.md")
      assert string.contains(json_text, "\"kind\":\"underpowered\"")
      assert string.starts_with(markdown, "Minimum detectable effect")
      assert string.contains(markdown, "live lane")
    })
  })
}

pub fn killed_trial_becomes_infra_then_retry_test_() -> scripted.EunitTest {
  scripted.Timeout(120, fn() {
    scripted.when_available("killed_trial_becomes_infra_then_retry", fn() {
      let r =
        rig(
          "killed",
          [scripted.task_named("only", "hello", "hello")],
          [scripted.baseline()],
          1,
          1,
          100.0,
          60_000,
          1,
        )
      let opens = scripted.counter()
      let normal = trial.default_seams(trial.refuse_program)
      let flaky =
        trial.Seams(..normal, open: fn(settings) {
          case scripted.bump(opens) {
            1 -> Error("the helper was killed")
            _ -> normal.open(settings)
          }
        })

      let assert Ok(summary) =
        run.execute(with_seams(r, flaky).ctx, r.loaded, r.out)
      let rows = rows_of(summary.directory)

      assert list.map(rows, fn(row) { #(row.attempt, row.state) })
        == [
          #(1, ledger.Running),
          #(1, ledger.Infra),
          #(2, ledger.Running),
          #(2, ledger.Scored),
        ]
      let assert [_, infra, ..] = rows
      assert string.contains(infra.side_info, "the helper was killed")
      let assert Ok([final]) = ledger.reconcile(r.plan, rows)
      assert final.attempt == 2
      assert final.outcome == Some(ledger.Passed)
    })
  })
}

pub fn agent_timeout_is_a_failure_test_() -> scripted.EunitTest {
  scripted.Timeout(120, fn() {
    scripted.when_available("agent_timeout_is_a_failure", fn() {
      let r =
        rig(
          "timeout",
          [scripted.stalled_task()],
          [scripted.baseline()],
          1,
          1,
          100.0,
          3000,
          1,
        )

      let assert Ok(summary) = run.execute(r.ctx, r.loaded, r.out)
      let rows = rows_of(summary.directory)

      // One attempt: a timeout is the arm's failure and is never requeued.
      assert list.map(rows, fn(row) { #(row.attempt, row.state) })
        == [#(1, ledger.Running), #(1, ledger.Scored)]
      let assert Ok([final]) = ledger.reconcile(r.plan, rows)
      assert final.outcome == Some(ledger.AgentTimeout)
      let assert Ok(markdown) =
        simplifile.read(summary.directory <> "/report.md")
      assert string.contains(markdown, "pass rate 0.0 (0/1)")
    })
  })
}

pub fn measured_spend_cap_stops_admission_test_() -> scripted.EunitTest {
  scripted.Timeout(300, fn() {
    scripted.when_available("measured_spend_cap_stops_admission", fn() {
      let tasks = [
        scripted.task_named("first", "hello", "hello"),
        scripted.task_named("second", "world", "world"),
      ]
      let arms = [scripted.baseline(), scripted.suffixed()]

      // A trial's worst case is four requests of 3 * 100k context + 4096
      // output at $1 per million; the cap covers it with five percent to
      // spare, and each trial then measurably spends only 2 * 40k tokens.
      let worst =
        budget.worst_case_dollars(
          4,
          pricing.Pricing(1.0, 1.0, 1.0, 1.0),
          context: 100_000,
          output: 4096,
        )
      let r = rig("cap", tasks, arms, 1, 1, worst *. 1.05, 60_000, 40_000)

      let assert Ok(summary) = run.execute(r.ctx, r.loaded, r.out)
      let rows = finished(rows_of(summary.directory))

      assert summary.budget_note == Some("budget exhausted after 1 trials")
      assert list.length(rows) == 1
      let assert [only] = rows
      assert only.usage.dollars >. 0.0
      assert only.usage.dollars <. worst

      // The cells that never ran are missing, which the report says plainly.
      let assert Ok(markdown) =
        simplifile.read(summary.directory <> "/report.md")
      assert string.contains(markdown, "budget exhausted after 1 trials")
      assert string.contains(markdown, "INCOMPLETE: plan row missing")
    })
  })
}

pub fn resume_skips_terminal_cells_test_() -> scripted.EunitTest {
  scripted.Timeout(300, fn() {
    scripted.when_available("resume_skips_terminal_cells", fn() {
      let r =
        rig(
          "resume",
          [scripted.task_named("only", "hello", "hello")],
          [scripted.baseline()],
          2,
          1,
          100.0,
          60_000,
          1,
        )
      let assert Ok(first) = run.execute(r.ctx, r.loaded, r.out)
      assert first.started == 2

      // A crash: cell 0 is intact, cell 1 has only its Running row.
      let kept =
        rows_of(first.directory)
        |> list.filter(fn(row) { row.index == 0 || row.state == ledger.Running })
      let assert Ok(Nil) =
        simplifile.write(
          first.directory <> "/trials.jsonl",
          string.join(list.map(kept, ledger.encode_line), "\n") <> "\n",
        )

      let opens = scripted.counter()
      let normal = trial.default_seams(trial.refuse_program)
      let counting =
        trial.Seams(..normal, open: fn(settings) {
          scripted.bump(opens)
          normal.open(settings)
        })
      let assert Ok(second) =
        run.execute(with_seams(r, counting).ctx, r.loaded, r.out)
      let rows = rows_of(second.directory)

      assert second.started == 1
      assert scripted.count(opens) == 1
      assert list.map(rows, fn(row) { #(row.index, row.attempt, row.state) })
        == [
          #(0, 1, ledger.Running),
          #(0, 1, ledger.Scored),
          #(1, 1, ledger.Running),
          #(1, 1, ledger.Infra),
          #(1, 2, ledger.Running),
          #(1, 2, ledger.Scored),
        ]
      let assert Ok(_) = ledger.reconcile(r.plan, rows)
      Nil
    })
  })
}

pub fn grading_sees_a_retired_session_test_() -> scripted.EunitTest {
  scripted.Timeout(120, fn() {
    scripted.when_available("grading_sees_a_retired_session", fn() {
      let r =
        rig(
          "ordering",
          [scripted.task_named("only", "hello", "hello")],
          [scripted.baseline()],
          1,
          1,
          100.0,
          60_000,
          1,
        )
      let retired = scripted.counter()
      let normal = trial.default_seams(trial.refuse_program)
      let watching =
        trial.Seams(
          ..normal,
          retire: fn(instance) {
            let outcome = normal.retire(instance)
            scripted.bump(retired)
            outcome
          },
          grade: fn(found, frozen, out, pristine) {
            case scripted.count(retired) {
              0 -> Error("graded before the session was retired")
              _ -> normal.grade(found, frozen, out, pristine)
            }
          },
        )

      let assert Ok(summary) =
        run.execute(with_seams(r, watching).ctx, r.loaded, r.out)
      let assert Ok([final]) =
        ledger.reconcile(r.plan, rows_of(summary.directory))

      assert final.state == ledger.Scored
      assert final.outcome == Some(ledger.Passed)
    })
  })
}

pub fn an_unretired_session_is_not_graded_test_() -> scripted.EunitTest {
  scripted.Timeout(120, fn() {
    scripted.when_available("an_unretired_session_is_not_graded", fn() {
      let r =
        rig(
          "unretired",
          [scripted.task_named("only", "hello", "hello")],
          [scripted.baseline()],
          1,
          1,
          100.0,
          60_000,
          1,
        )
      let graded = scripted.counter()
      let normal = trial.default_seams(trial.refuse_program)
      let stubborn =
        trial.Seams(
          ..normal,
          retire: fn(instance) {
            let _ = normal.retire(instance)
            Error("a helper outlived its session")
          },
          grade: fn(found, frozen, out, pristine) {
            scripted.bump(graded)
            normal.grade(found, frozen, out, pristine)
          },
        )

      let assert Ok(summary) =
        run.execute(with_seams(r, stubborn).ctx, r.loaded, r.out)
      let rows = rows_of(summary.directory)

      // Every attempt is an infrastructure fault, and the grader never ran.
      assert scripted.count(graded) == 0
      assert list.length(
          list.filter(rows, fn(row) { row.state == ledger.Infra }),
        )
        == 3
      let assert [_, first_infra, ..] = rows
      assert string.contains(first_infra.side_info, "retirement unconfirmed")
    })
  })
}

pub fn unapplied_arm_is_refused_before_any_trial_test_() -> scripted.EunitTest {
  scripted.Timeout(60, fn() {
    scripted.when_available("unapplied_arm_is_refused", fn() {
      let assert Ok(packed) =
        arm.mint(Arm(
          id: "",
          name: "packed",
          components: [#(PromptPack, "{}")],
          knobs: Knobs(roles: [], thinking: [], disabled_tools: []),
        ))
      let r =
        rig(
          "refused",
          [scripted.task_named("only", "hello", "hello")],
          [scripted.baseline(), packed],
          1,
          1,
          100.0,
          60_000,
          1,
        )

      let assert Error(reason) = run.execute(r.ctx, r.loaded, r.out)

      assert string.contains(reason, "PromptPack")
      assert simplifile.is_file(r.out <> "/" <> r.plan.id <> "/trials.jsonl")
        == Ok(False)
    })
  })
}

pub fn a_recorded_tape_replays_to_the_same_result_test_() -> scripted.EunitTest {
  scripted.Timeout(300, fn() {
    scripted.when_available("a_recorded_tape_replays", fn() {
      let tasks = [scripted.task_named("only", "hello", "hello")]
      let arms = [scripted.baseline()]
      let r = rig("record", tasks, arms, 1, 1, 100.0, 60_000, 1)
      let tapes = r.out <> "/tapes"

      // Record: a live plan whose wire is tapped.
      let recording =
        trial.Context(
          ..r.ctx,
          lane: trial.Recording(run_cli.record_open(
            scripted.transport(1),
            tapes,
          )),
        )
      let assert Ok(live) = run.execute(recording, r.loaded, r.out)
      let assert Ok(task) = list.first(tasks)
      let tape_path = tapes <> "/" <> task.id <> "/0.jsonl"
      let assert Ok(text) = simplifile.read(tape_path)
      assert string.contains(text, "\"v\":1")
      assert list.all(finished(rows_of(live.directory)), fn(row) {
        row.outcome == Some(ledger.Passed)
      })

      // Replay: the same cell under a replay plan answers from the tape alone,
      // through a transport that would fail every request.
      let replay_plan = plan.mint(plan.Plan(..r.plan, lane: plan.Replay))
      let replaying =
        trial.Context(
          ..r.ctx,
          lane: trial.Taped(open: run_cli.replay_open(tapes)),
          plan_id: replay_plan.id,
        )
      let assert Ok(replayed) =
        run.execute(
          replaying,
          run.Loaded(replay_plan, tasks, arms),
          r.out <> "-replay",
        )

      let assert [final] = finished(rows_of(replayed.directory))
      assert final.outcome == Some(ledger.Passed)
      assert replayed.budget_note == None
    })
  })
}

// --- futility -------------------------------------------------------------------

// Seven tasks, one trial each, and two arms that behave alike under the
// scripted provider: every task is a tie, so after a few tasks no completion
// of the plan can bring the sign test below its level.
fn tied_tasks() -> List(Task) {
  list.index_map(list.repeat(Nil, 7), fn(_, position) {
    scripted.task_named("tie-" <> int.to_string(position), "same", "same")
  })
}

pub fn runner_stops_admission_on_futility_test_() -> scripted.EunitTest {
  scripted.Timeout(300, fn() {
    scripted.when_available("runner_stops_admission_on_futility", fn() {
      let tasks = tied_tasks()
      let arms = [scripted.baseline(), scripted.suffixed()]
      let r = rig("futility", tasks, arms, 1, 1, 100.0, 60_000, 1)

      let assert Ok(summary) = run.execute(r.ctx, r.loaded, r.out)
      let rows = finished(rows_of(summary.directory))

      // Seven pairs could still have reached p = 0.03 at the start, and five
      // cannot, so admission stops after the second task: two pairs, four trials.
      assert summary.started == 4
      assert list.length(rows) == 4
      assert summary.futility_note == Some("stopped for futility after 2 pairs")
      assert summary.budget_note == None

      // The cells never run are missing, so the verdict is Incomplete, and
      // the report says why the run is short.
      let assert Ok(markdown) =
        simplifile.read(summary.directory <> "/report.md")
      assert string.contains(
        markdown,
        "Futility: stopped for futility after 2 pairs",
      )
      assert string.contains(markdown, "INCOMPLETE: plan row missing")

      // A report rebuilt from the directory says the same thing.
      let assert Ok(inputs) = run.reload(summary.directory)
      assert inputs.futility_note == Some("stopped for futility after 2 pairs")
    })
  })
}

fn tied_row(frozen: Plan, key: plan.RowKey) -> Row {
  Row(
    ..trial.infra_row(frozen.id, key, 1, ""),
    state: ledger.Scored,
    outcome: Some(ledger.Passed),
    reward: 1.0,
  )
}

fn rows_for_tasks(frozen: Plan, how_many: Int) -> List(Row) {
  plan.rows(frozen)
  |> list.filter(fn(key) {
    list.take(frozen.task_ids, how_many) |> list.contains(key.task)
  })
  |> list.map(tied_row(frozen, _))
}

pub fn futility_waits_until_a_decision_is_out_of_reach_test() {
  let arms = [scripted.baseline(), scripted.suffixed()]
  let frozen = scripted.plan_of(tied_tasks(), arms, 1, 1, 10.0, 1000)

  // Nothing run, then one task, then two: the fifth remaining pair is the one
  // that takes a perfect sweep below the level out of reach.
  assert run.futile_after(frozen, []) == None
  assert run.futile_after(frozen, rows_for_tasks(frozen, 1)) == None
  assert run.futile_after(frozen, rows_for_tasks(frozen, 2)) == Some(2)
  assert run.futile_after(frozen, rows_for_tasks(frozen, 3)) == Some(3)
}

pub fn a_plan_that_could_never_decide_is_not_stopped_for_futility_test() {
  // Two tasks cannot reach p < 0.05 whatever happens, so the plan is
  // underpowered by design; stopping it "for futility" would stop it at once.
  let tasks = [
    scripted.task_named("one", "a", "a"),
    scripted.task_named("two", "b", "b"),
  ]
  let arms = [scripted.baseline(), scripted.suffixed()]
  let frozen = scripted.plan_of(tasks, arms, 1, 1, 10.0, 1000)

  assert run.futile_after(frozen, rows_for_tasks(frozen, 1)) == None
  assert run.futile_after(frozen, rows_for_tasks(frozen, 2)) == None
}

pub fn a_single_arm_plan_has_nothing_to_stop_test() {
  let frozen =
    scripted.plan_of(tied_tasks(), [scripted.baseline()], 1, 1, 10.0, 1000)

  assert run.futile_after(frozen, rows_for_tasks(frozen, 5)) == None
}

// --- faults that are the instrument's, not the arm's ----------------------------

pub fn an_unwritable_tape_directory_is_infrastructure_not_a_failure_test_() -> scripted.EunitTest {
  scripted.Timeout(300, fn() {
    scripted.when_available("an_unwritable_tape_directory", fn() {
      let tasks = [scripted.task_named("only", "hello", "hello")]
      let r =
        rig("unwritable", tasks, [scripted.baseline()], 1, 1, 100.0, 60_000, 1)

      // A regular file where the tape folder must go: creating it fails.
      let blocker = r.out <> "-blocker"
      let assert Ok(Nil) = simplifile.write(blocker, "not a directory")
      let recording =
        trial.Context(
          ..r.ctx,
          lane: trial.Recording(run_cli.record_open(
            scripted.transport(1),
            blocker <> "/tapes",
          )),
        )

      let assert Ok(summary) = run.execute(recording, r.loaded, r.out)
      let rows = finished(rows_of(summary.directory))

      // The arm did nothing wrong: every attempt is an instrument fault.
      assert list.length(rows) == 3
      assert list.all(rows, fn(row) {
        row.state == ledger.Infra
        && row.outcome == Some(ledger.Infrastructure)
        && string.contains(row.side_info, "the tape was not written")
      })
    })
  })
}

pub fn a_fault_after_the_run_still_charges_what_it_spent_test_() -> scripted.EunitTest {
  scripted.Timeout(300, fn() {
    scripted.when_available("a_fault_after_the_run_still_charges", fn() {
      let tasks = [scripted.task_named("only", "hello", "hello")]
      let worst =
        budget.worst_case_dollars(
          4,
          pricing.Pricing(1.0, 1.0, 1.0, 1.0),
          context: 100_000,
          output: 4096,
        )
      let r =
        rig(
          "late",
          tasks,
          [scripted.baseline()],
          1,
          1,
          worst *. 1.05,
          60_000,
          40_000,
        )
      let normal = trial.default_seams(trial.refuse_program)
      let stubborn =
        trial.Seams(..normal, retire: fn(instance) {
          let _ = normal.retire(instance)
          Error("a helper outlived its session")
        })

      let assert Ok(summary) =
        run.execute(with_seams(r, stubborn).ctx, r.loaded, r.out)
      let rows = finished(rows_of(summary.directory))

      // The first attempt spent real money before retirement failed; the cap
      // sees it, so the retries are not admitted on a false zero balance.
      assert summary.budget_note == Some("budget exhausted after 1 trials")
      let assert [only] = rows
      assert only.state == ledger.Infra
      assert only.usage.dollars >. 0.0
    })
  })
}

pub fn three_tasks_of_three_trials_are_recognised_hopeless_test() {
  let tasks = list.take(tied_tasks(), 3)
  let arms = [scripted.baseline(), scripted.suffixed()]
  let frozen = scripted.plan_of(tasks, arms, 3, 1, 10.0, 1000)

  // Nine pairs, but only three tasks, so only three signs can ever move:
  // p >= 0.25 whatever happens, and a plan that could never decide is not
  // stopped for futility by what it has seen.
  assert run.futile_after(frozen, rows_for_tasks(frozen, 2)) == None
}

// --- the tree a plan claims ------------------------------------------------------

fn tree_at(commit: String, status: String) -> secrets.Runner {
  fn(argv, _timeout) {
    case argv {
      ["git", "rev-parse", "HEAD"] -> Ok(secrets.Capture(0, commit <> "\n"))
      ["git", "status", "--porcelain"] -> Ok(secrets.Capture(0, status))
      _ -> Error("unexpected command")
    }
  }
}

fn claiming(profile: plan.Profile) -> Plan {
  let base =
    scripted.plan_of(tied_tasks(), [scripted.baseline()], 1, 1, 1.0, 1000)

  plan.mint(plan.Plan(..base, profile:))
}

pub fn a_full_plan_at_a_different_commit_is_refused_test() {
  let frozen = claiming(plan.Full)
  let claimed = frozen.harness.git_commit
  let other = "fedcba9876543210fedcba9876543210fedcba98"

  assert run_cli.check_harness(frozen, tree_at(claimed, "")) == Ok(None)

  let assert Error(reason) = run_cli.check_harness(frozen, tree_at(other, ""))
  assert string.contains(reason, claimed)
  assert string.contains(reason, other)

  let assert Error(dirty) =
    run_cli.check_harness(frozen, tree_at(claimed, " M src/x.gleam\n"))
  assert string.contains(dirty, "uncommitted")
}

pub fn a_quick_plan_at_a_different_commit_runs_with_a_warning_test() {
  let frozen = claiming(plan.Quick)
  let other = "fedcba9876543210fedcba9876543210fedcba98"

  let assert Ok(Some(warning)) =
    run_cli.check_harness(frozen, tree_at(other, ""))
  assert string.contains(warning, other)
}

pub fn unfinished_pairs_of_one_task_move_only_one_sign_test() {
  let arms = [scripted.baseline(), scripted.suffixed()]
  let frozen = scripted.plan_of(tied_tasks(), arms, 2, 1, 10.0, 1000)

  // Seven tasks of two trials: four tasks are done, ties. Six pairs remain
  // but only three tasks can still sign, and three signs reach at best
  // p = 0.25, so the run is stalled; counting pairs would have said six.
  assert run.futile_after(frozen, rows_for_tasks(frozen, 4)) == Some(8)
}
