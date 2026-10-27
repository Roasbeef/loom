import core/json
import eval/plan.{type Plan}
import gleam/list
import gleam/string
import simplifile

const commit = "0123456789abcdef0123456789abcdef01234567"

fn sample(profile: plan.Profile, posture: plan.Posture) -> Plan {
  plan.mint(plan.Plan(
    id: "",
    task_ids: ["t1", "t2", "t3"],
    arm_ids: ["a1", "a2"],
    trials_per_cell: 4,
    lane: plan.Replay,
    profile:,
    split_salt: "salt",
    budgets: plan.Budgets(
      max_requests_per_trial: 100,
      max_dollars: 5.5,
      wall_ms_per_trial: 600_000,
      concurrency: 2,
    ),
    harness: plan.Harness(git_commit: commit, posture:),
  ))
}

pub fn plan_rows_are_the_denominator_test() {
  let rows = plan.rows(sample(plan.Quick, plan.Clean))

  assert list.length(rows) == 24
  assert list.length(list.unique(rows)) == 24
  assert list.first(rows) == Ok(plan.RowKey("t1", "a1", 0))
  assert list.last(rows) == Ok(plan.RowKey("t3", "a2", 3))
  assert plan.key_to_string(plan.RowKey("t3", "a2", 3)) == "t3/a2/3"
}

pub fn plan_round_trips_test() {
  let original = sample(plan.Full, plan.Clean)

  assert plan.decode(plan.to_json(original)) == Ok(original)
  assert plan.verify_id(original) == Ok(original)
  assert plan.mint(original) == original
}

pub fn full_plan_refuses_dirty_tree_test() {
  let dirty_full = sample(plan.Full, plan.Dirty)
  let assert Error(reason) = plan.check(dirty_full)

  assert string.contains(reason, "dirty tree")
  assert plan.decode(plan.to_json(dirty_full)) == Error(reason)

  let quick = sample(plan.Quick, plan.Dirty)
  assert plan.check(quick) == Ok(quick)
  assert plan.decode(plan.to_json(quick)) == Ok(quick)
}

pub fn plan_invariants_are_enforced_test() {
  let base = sample(plan.Quick, plan.Clean)

  assert plan.check(plan.Plan(..base, task_ids: [])) != Ok(base)
  assert plan.check(plan.Plan(..base, arm_ids: ["a", "a"])) != Ok(base)
  assert plan.check(plan.Plan(..base, trials_per_cell: 0)) != Ok(base)
  assert plan.check(
      plan.Plan(
        ..base,
        harness: plan.Harness(git_commit: "abc", posture: plan.Clean),
      ),
    )
    != Ok(base)
  assert plan.decode(json.Null) == Error("expected an object")
}

pub fn plan_load_verifies_the_digest_test() {
  let directory = "build/eval_plan_test"
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
  let original = sample(plan.Quick, plan.Clean)
  let good = directory <> "/plan.json"
  let edited = directory <> "/edited.json"
  let tampered = plan.Plan(..original, split_salt: "other")
  let assert Ok(Nil) =
    simplifile.write(good, json.to_string(plan.to_json(original)))
  let assert Ok(Nil) =
    simplifile.write(edited, json.to_string(plan.to_json(tampered)))

  assert plan.load(good) == Ok(original)
  let assert Error(reason) = plan.load(edited)
  assert string.starts_with(reason, "plan content changed")
}
