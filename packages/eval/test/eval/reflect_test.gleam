import eval/ledger
import eval/plan.{RowKey}
import eval/reflect
import eval/task.{type Task, HandWritten, Inline, Program, Task}
import eval/trial
import gleam/list
import gleam/option.{Some}
import gleam/string
import support/scripted

pub fn an_answer_is_trimmed_bounded_and_frame_free_test() {
  assert reflect.answer("  Check your work.\n") == Ok("Check your work.")
  assert reflect.answer("   ") == Error("the reflector answered nothing")

  let long = string.repeat("x", reflect.max_answer_bytes + 1)
  let assert Error(reason) = reflect.answer(long)
  assert string.contains(reason, "exceeds")

  let assert Error(smuggled) = reflect.answer("fine " <> reflect.record_open)
  assert string.contains(smuggled, "frame token")
  let assert Error(closed) = reflect.answer(reflect.record_close <> " fine")
  assert string.contains(closed, "frame token")
}

pub fn frame_tokens_in_a_body_are_broken_test() {
  let body = "a [[record]] b [[/record]] c"
  let safe = reflect.frame_safe(body)

  assert !string.contains(safe, reflect.record_open)
  assert !string.contains(safe, reflect.record_close)
  assert string.contains(safe, "a ") && string.contains(safe, " c")

  // Breaking once is enough: the replacement spells neither token.
  assert reflect.frame_safe(safe) == safe
}

pub fn hidden_test_ids_are_redacted_in_eunit_verbose_output_test() {
  let tail =
    "module 'core@json_test'\n"
    <> "  core@json_test: parses_test...*failed*\n"
    <> "  core@json_test: rejects_test...[0.001 s] ok\n"
    <> "**error: parses_test raised in core@json_test.parses_test/0\n"
    <> "Failed: 1.  Skipped: 0.  Passed: 1."
  let redacted =
    reflect.redact_ids(tail, [
      "core@json_test.parses_test",
      "core@json_test.rejects_test",
    ])

  assert !string.contains(redacted, "parses_test")
  assert !string.contains(redacted, "rejects_test")
  assert !string.contains(redacted, "core@json_test")
  assert string.contains(redacted, "module '<module 1>'")
  assert string.contains(redacted, "<test 1>...*failed*")
  assert string.contains(redacted, "<test 2>...[0.001 s] ok")
  assert string.contains(redacted, "raised in <test 1>/0")
}

pub fn hidden_test_ids_are_replaced_longest_first_test() {
  let ids = ["m.a_test", "m.a_test_more"]

  assert reflect.redact_ids("m.a_test_more then m.a_test", ids)
    == "<test 2> then <test 1>"
  assert reflect.redact_ids("nothing named", ids) == "nothing named"
}

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
  assert !string.contains(only.side_info, reflect.record_open)

  // At most `max_rows` records, each excerpt within its byte bound.
  let many =
    list.repeat(
      scored_row(found, string.repeat("y", 10_000)),
      reflect.max_rows + 3,
    )
  let records = reflect.records(many, [found])
  assert list.length(records) == reflect.max_rows
  assert list.all(records, fn(record) {
    string.byte_size(record.side_info) <= reflect.max_excerpt_bytes
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
  let prompt = reflect.render(request)

  assert string.contains(
    prompt,
    "Objective: Pass more tests ( record ) honestly",
  )
  assert string.contains(
    prompt,
    "Slot: system_suffix:fixture/fixture/anthropic-messages/any",
  )
  assert string.contains(prompt, "task: fix-json")

  // Two frames: the current text and the one record, each opened and closed.
  let opens = list.length(string.split(prompt, reflect.record_open)) - 1
  let closes = list.length(string.split(prompt, reflect.record_close)) - 1
  assert opens >= 2 && opens == closes
}
