import eval/ledger
import eval/plan.{RowKey}
import eval/reflect
import eval/task.{type Task, HandWritten, Inline, Program, Task}
import eval/trial
import gepa/prompt
import gleam/list
import gleam/option.{Some}
import gleam/string
import support/scripted

fn program_task() -> Task {
  task.mint(Task(
    id: "",
    name: "fix-json",
    prompt: "Fix the parser.",
    workspace: Inline([#("a.txt", "a")]),
    verifier: Program(
      files: [],
      argv: ["bash", "scripts/test.sh", "core"],
      fail_to_pass: ["core@json_test.parses_test"],
      pass_to_pass: ["core@json_test.rejects_test"],
      timeout_ms: 60_000,
      scoring: task.AllRewardsOne,
    ),
    tags: [],
    provenance: HandWritten("test"),
  ))
}

fn scored_row(found: Task, side_info: String) -> ledger.Row {
  ledger.Row(
    ..trial.infra_row("plan", RowKey(found.id, "arm", 0), 1, ""),
    state: ledger.Scored,
    outcome: Some(ledger.VerifierFailed),
    side_info:,
  )
}

pub fn records_redact_ids_drop_other_tasks_and_are_bounded_test() {
  let found = program_task()
  let other = scripted.task_named("other", "x", "x")
  let rows = [
    scored_row(found, "failed: core@json_test.parses_test [[record]] tail"),
    scored_row(other, "not a tune task"),
  ]

  let assert [only] = reflect.records(rows, [found])
  assert only.task == "fix-json"
  assert only.outcome == "verifier_failed"
  assert !string.contains(only.side_info, "parses_test")
  assert string.contains(only.side_info, "<test 1>")
  assert !string.contains(only.side_info, prompt.record_open)

  // At most `max_rows` records, each excerpt within its byte bound.
  let many =
    list.repeat(
      scored_row(found, string.repeat("y", 10_000)),
      prompt.max_rows + 3,
    )
  let records = reflect.records(many, [found])
  assert list.length(records) == prompt.max_rows
  assert list.all(records, fn(record) {
    string.byte_size(record.side_info) <= prompt.max_excerpt_bytes
  })
}

pub fn the_prompt_frames_every_record_and_states_the_objective_test() {
  let found = program_task()
  let request =
    reflect.Request(
      objective: "Pass more tests [[record]] honestly",
      slot: "system_suffix:fixture/fixture/anthropic-messages/any",
      current: "",
      records: reflect.records([scored_row(found, "boom")], [found]),
    )
  let rendered = reflect.render(request)

  assert string.contains(
    rendered,
    "Objective: Pass more tests ( record ) honestly",
  )
  assert string.contains(
    rendered,
    "Slot: system_suffix:fixture/fixture/anthropic-messages/any",
  )
  assert string.contains(rendered, "task: fix-json")
  assert string.contains(rendered, "outcome:\nverifier_failed")

  // The current text and the one record are framed, each opened and closed.
  let opens = list.length(string.split(rendered, prompt.record_open)) - 1
  let closes = list.length(string.split(rendered, prompt.record_close)) - 1
  assert opens >= 2 && opens == closes
}
