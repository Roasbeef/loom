//// The committed operator plans are runnable as they stand: each one passes
//// the instrument's own total decoders, names tasks and arms that exist, and
//// says in its README what to expect and how to start it.

import eval
import eval/arm.{type Arm}
import eval/arm_settings
import eval/ledger
import eval/plan
import eval/repos
import eval/run
import eval/trial
import gleam/list
import gleam/option.{Some}
import gleam/string
import simplifile
import support/scripted

const plans_directory = "plans"

const tasks_directory = "tasks/loom-history-v1"

const arms_directory = "plans/arms"

const plan_files = [
  "aa-live.json", "degrade-live.json", "smoke-replay.json",
  "smoke-record-live.json",
]

fn loaded(file: String) -> run.Loaded {
  let assert Ok(found) =
    run.load(plans_directory <> "/" <> file, tasks_directory, arms_directory)
    as { file <> " loads with its tasks and arms" }

  found
}

fn arm_named(found: run.Loaded, name: String) -> Arm {
  let assert Ok(each) = list.find(found.arms, fn(each) { each.name == name })
    as { "the plan holds an arm named " <> name }

  each
}

pub fn committed_plans_validate_test() {
  // Every plan file passes `eval validate`, the decoders and `plan.check`, and
  // `run.load` finds each task and arm it names, each arm under its own id.
  list.each(plan_files, fn(file) {
    let path = plans_directory <> "/" <> file
    let assert Ok(verdict) = eval.validate(path)
    assert string.starts_with(verdict, "ok plan ")

    let found = loaded(file)
    let assert Ok(checked) = plan.check(found.plan)
    assert checked == found.plan
    assert list.length(found.tasks) == list.length(found.plan.task_ids)
    assert list.length(found.arms) == list.length(found.plan.arm_ids)
  })

  // Every committed arm file validates on its own, so none is left behind by a plan.
  let assert Ok(arm_files) = simplifile.read_directory(arms_directory)
  assert arm_files != []
  list.each(arm_files, fn(file) {
    let assert Ok(verdict) = eval.validate(arms_directory <> "/" <> file)
    assert string.starts_with(verdict, "ok arm ")
  })

  // The plans use the committed task set and nothing else.
  let assert Ok(task_files) = simplifile.read_directory(tasks_directory)
  let committed =
    task_files
    |> list.filter(string.ends_with(_, ".json"))
    |> list.map(string.drop_end(_, 5))
  list.each(plan_files, fn(file) {
    assert list.all(loaded(file).plan.task_ids, list.contains(committed, _))
  })
}

pub fn the_plans_have_the_shape_their_readme_promises_test() {
  let aa = loaded("aa-live.json")
  let degrade = loaded("degrade-live.json")
  let smoke = loaded("smoke-replay.json")
  let record = loaded("smoke-record-live.json")

  // The A/A plan compares two arms that differ only by inert markers.
  let first = arm_named(aa, "control-a")
  let second = arm_named(aa, "control-b")
  assert first.id != second.id
  assert first.components == second.components
  assert list.length(aa.tasks) == 21
  assert aa.plan.trials_per_cell == 3
  assert aa.plan.lane == plan.Live
  assert aa.plan.profile == plan.Full

  // The degradation plan holds the baseline against the one instruction.
  let baseline = arm_named(degrade, "baseline")
  let worse = arm_named(degrade, "no-tests")
  assert baseline.components == []
  assert list.map(worse.components, fn(each) { each.1 })
    == ["Do not run any tests; answer from reading the code alone."]
  assert degrade.plan.arm_ids == [baseline.id, worse.id]
  assert degrade.plan.trials_per_cell == 3
  assert degrade.plan.lane == plan.Live

  // The smoke plan replays what its live twin records: the same cells, the
  // lane the only difference, so a tape recorded by one is found by the other.
  assert smoke.plan.lane == plan.Replay
  assert smoke.plan.profile == plan.Quick
  assert plan.mint(
      plan.Plan(..record.plan, lane: plan.Replay, budgets: smoke.plan.budgets),
    )
    == smoke.plan
  assert plan.rows(smoke.plan) == plan.rows(record.plan)
}

pub fn the_readme_names_every_plan_and_the_command_that_runs_it_test() {
  let assert Ok(text) = simplifile.read(plans_directory <> "/README.md")

  list.each(plan_files, fn(file) {
    assert string.contains(text, "plans/" <> file)
    assert string.contains(text, "make eval-run ARGS=\"run plans/" <> file)
  })
  assert string.contains(text, "A/A")
  assert string.contains(text, "Harmed")
  assert string.contains(text, "minimum detectable effect")
}

pub fn inert_markers_change_nothing_a_session_sees_test_() -> scripted.EunitTest {
  scripted.Timeout(120, fn() {
    scripted.when_available("inert_markers_change_nothing", fn() {
      let aa = loaded("aa-live.json")
      let root = scripted.scratch("inert-markers")
      let base = scripted.base(root <> "/base", scripted.transport(1))

      // Each control arm applies to the base settings and opens a real
      // session that completes a task: an unknown withheld tool is no fault.
      list.each(aa.arms, fn(each) {
        let assert Ok(_) = arm_settings.to_settings(each, base)
        let assert Ok([]) = arm_settings.profiles(each, base)
      })
      let ctx =
        trial.Context(
          base:,
          lane: trial.Live,
          budgets: plan.Budgets(4, 100.0, 60_000, 1),
          plan_id: "inert",
          seams: trial.default_seams(trial.refuse_program),
          repos: repos.empty(),
          selftest: trial.unprobed,
        )
      let found = scripted.task_named("inert", "hello", "hello")
      let key = plan.RowKey(found.id, arm_named(aa, "control-b").id, 0)
      let row =
        trial.run_one(
          ctx,
          found,
          arm_named(aa, "control-b"),
          key,
          1,
          root <> "/attempt",
        )

      assert row.outcome == Some(ledger.Passed)
    })
  })
}
