import eval/ledger.{type Row}
import eval/plan.{type Plan, RowKey}
import gleam/list
import gleam/option.{None, Some}
import gleam/string

fn the_plan() -> Plan {
  plan.mint(plan.Plan(
    id: "",
    task_ids: ["t"],
    arm_ids: ["a"],
    trials_per_cell: 2,
    lane: plan.Replay,
    profile: plan.Quick,
    split_salt: "s",
    budgets: plan.Budgets(
      max_requests_per_trial: 10,
      max_dollars: 1.0,
      wall_ms_per_trial: 1000,
      concurrency: 1,
    ),
    harness: plan.Harness(
      git_commit: "0123456789abcdef0123456789abcdef01234567",
      posture: plan.Clean,
    ),
  ))
}

fn row(
  index: Int,
  attempt: Int,
  state: ledger.RowState,
  outcome: option.Option(ledger.Outcome),
) -> Row {
  ledger.Row(
    plan: the_plan().id,
    task: "t",
    arm: "a",
    index:,
    attempt:,
    state:,
    outcome:,
    reward: case outcome {
      Some(ledger.Passed) -> 1.0
      Some(_) | None -> 0.0
    },
    scores: [#("f2p", 1.0), #("p2p", 0.5)],
    side_info: "tail",
    served: [
      ledger.Served(
        provider: "p",
        model: "m",
        api: "messages",
        profile: Some("prof"),
        digest: "d",
      ),
      ledger.Served(
        provider: "p",
        model: "n",
        api: "messages",
        profile: None,
        digest: "e",
      ),
    ],
    usage: ledger.Usage(
      input: 1,
      output: 2,
      cache_read: 3,
      cache_write: 4,
      dollars: 0.25,
      completeness: ledger.LowerBound,
    ),
    turns: 7,
    tool_calls: 19,
    tool_errors: 2,
    compactions: 0,
    timing: ledger.Timing(prepare: 1, agent: 2, verifier: 3, retire: 4),
    jail: ledger.Jail(posture: ledger.BwrapUserns, selftest: "10/11"),
    artifacts: ledger.Artifacts(
      session_db: "s.db",
      workspace: "w",
      trajectory: "t.json",
      verifier_stdout: "v.txt",
    ),
  )
}

fn scored(index: Int, attempt: Int) -> Row {
  row(index, attempt, ledger.Scored, Some(ledger.Passed))
}

fn infra(index: Int, attempt: Int) -> Row {
  row(index, attempt, ledger.Infra, Some(ledger.Infrastructure))
}

pub fn ledger_rows_round_trip_test() {
  let rows = [
    scored(0, 1),
    infra(1, 1),
    row(1, 2, ledger.Running, None),
    row(1, 2, ledger.Scored, Some(ledger.AgentTimeout)),
  ]

  list.each(rows, fn(original) {
    assert ledger.decode_line(ledger.encode_line(original)) == Ok(original)
  })
  assert !string.contains(ledger.encode_line(scored(0, 1)), "\n")
}

pub fn ledger_parse_reports_the_first_bad_line_test() {
  let good = ledger.encode_line(scored(0, 1))
  let text = good <> "\n\n" <> "{\"v\":2}" <> "\n" <> "garbage" <> "\n"

  let assert Error(reason) = ledger.parse(text)
  assert string.starts_with(reason, "line 3: ")
  assert ledger.parse(good <> "\n") == Ok([scored(0, 1)])
  assert ledger.parse("") == Ok([])
  assert ledger.parse("garbage") == Error("line 1: not valid JSON")
}

pub fn ledger_state_must_match_outcome_test() {
  let lying = row(0, 1, ledger.Running, Some(ledger.Passed))
  let unscored = row(0, 1, ledger.Scored, None)
  let wrong_infra = row(0, 1, ledger.Infra, Some(ledger.Passed))

  assert ledger.decode_line(ledger.encode_line(lying))
    == Error("a running row has no outcome yet")
  assert ledger.decode_line(ledger.encode_line(unscored))
    == Error("a scored row needs a graded outcome")
  assert ledger.decode_line(ledger.encode_line(wrong_infra))
    == Error("an infra row's outcome must be infrastructure")
  assert ledger.decode_line(ledger.encode_line(scored(0, 4)))
    == Error("\"attempt\" must be between 1 and 3")
}

pub fn ledger_reconcile_takes_latest_attempt_test() {
  let running = row(0, 1, ledger.Running, None)
  let done = scored(0, 1)
  let third = scored(1, 3)

  // File order is the order things happened: a running row, then the row
  // that supersedes it; two infra attempts, then a scored third.
  let reconciled =
    ledger.reconcile(the_plan(), [
      running,
      done,
      infra(1, 1),
      infra(1, 2),
      third,
    ])

  assert reconciled == Ok([done, third])
}

pub fn ledger_exhausted_infra_is_terminal_test() {
  let exhausted = infra(1, 3)

  assert ledger.reconcile(the_plan(), [
      scored(0, 1),
      infra(1, 1),
      infra(1, 2),
      exhausted,
    ])
    == Ok([scored(0, 1), exhausted])
}

pub fn ledger_missing_row_refused_test() {
  let plan = the_plan()

  assert ledger.reconcile(plan, [scored(0, 1)])
    == Error("plan row missing: t/a/1")
  assert ledger.reconcile(plan, []) == Error("plan row missing: t/a/0")

  // A trial still running, or failed with attempts left, owes a row too.
  assert ledger.reconcile(plan, [scored(0, 1), row(1, 1, ledger.Running, None)])
    == Error("plan row missing: t/a/1")
  assert ledger.reconcile(plan, [scored(0, 1), infra(1, 1)])
    == Error("plan row missing: t/a/1")
  assert ledger.reconcile(plan, [
      scored(0, 1),
      infra(1, 1),
      row(1, 2, ledger.Running, None),
    ])
    == Error("plan row missing: t/a/1")
}

pub fn scored_cell_cannot_be_rerolled_test() {
  let plan = the_plan()
  let failed = row(0, 1, ledger.Scored, Some(ledger.VerifierFailed))
  let later = row(0, 2, ledger.Scored, Some(ledger.Passed))
  let same = row(0, 1, ledger.Scored, Some(ledger.Passed))

  assert ledger.reconcile(plan, [failed, later, scored(1, 1)])
    == Error("cell rerolled: t/a/0")
  assert ledger.reconcile(plan, [failed, same, scored(1, 1)])
    == Error("cell rerolled: t/a/0")
  assert ledger.reconcile(plan, [scored(0, 1), scored(1, 1), scored(1, 2)])
    == Error("cell rerolled: t/a/1")
}

pub fn attempt_gap_refused_test() {
  let plan = the_plan()
  let broken = Error("attempt sequence broken: t/a/1")

  // A lone infra at attempt 3, a skipped attempt, a repeated attempt and a
  // retry that follows a running row rather than an infra row.
  assert ledger.reconcile(plan, [scored(0, 1), infra(1, 3)]) == broken
  assert ledger.reconcile(plan, [scored(0, 1), infra(1, 1), scored(1, 3)])
    == broken
  assert ledger.reconcile(plan, [scored(0, 1), infra(1, 1), infra(1, 1)])
    == broken
  assert ledger.reconcile(plan, [
      scored(0, 1),
      row(1, 1, ledger.Running, None),
      row(1, 2, ledger.Running, None),
    ])
    == broken
}

pub fn contradictory_row_refused_test() {
  let passed_for_nothing = ledger.Row(..scored(0, 1), reward: 0.0)
  let passed_for_half = ledger.Row(..scored(0, 1), reward: 0.5)
  let failed_for_full =
    ledger.Row(
      ..row(0, 1, ledger.Scored, Some(ledger.VerifierFailed)),
      reward: 1.0,
    )
  let partial =
    ledger.Row(
      ..row(0, 1, ledger.Scored, Some(ledger.VerifierFailed)),
      reward: 0.5,
    )
  let escaping =
    ledger.Row(
      ..scored(0, 1),
      artifacts: ledger.Artifacts(
        session_db: "../../etc/shadow",
        workspace: "w",
        trajectory: "t.json",
        verifier_stdout: "v.txt",
      ),
    )
  let unwritten =
    ledger.Row(
      ..row(0, 1, ledger.Running, None),
      artifacts: ledger.Artifacts(
        session_db: "",
        workspace: "",
        trajectory: "",
        verifier_stdout: "",
      ),
    )

  assert ledger.decode_line(ledger.encode_line(passed_for_nothing))
    == Error("a passed row needs a reward of 1")
  assert ledger.decode_line(ledger.encode_line(passed_for_half))
    == Error("a passed row needs a reward of 1")
  assert ledger.decode_line(ledger.encode_line(failed_for_full))
    == Error("a row that did not pass needs a reward below 1")
  assert ledger.decode_line(ledger.encode_line(partial)) == Ok(partial)
  assert ledger.decode_line(ledger.encode_line(escaping))
    == Error("\"session_db\" must be a safe relative path")
  assert ledger.decode_line(ledger.encode_line(unwritten)) == Ok(unwritten)
}

pub fn ledger_strays_are_refused_test() {
  let plan = the_plan()
  let outside = ledger.Row(..scored(0, 1), task: "other")
  let foreign = ledger.Row(..scored(0, 1), plan: "another")

  assert ledger.reconcile(plan, [scored(0, 1), scored(1, 1), outside])
    == Error("row outside the plan: other/a/0")
  assert ledger.reconcile(plan, [foreign])
    == Error("row from another plan: t/a/0")
  assert plan.rows(plan) == [RowKey("t", "a", 0), RowKey("t", "a", 1)]
}
