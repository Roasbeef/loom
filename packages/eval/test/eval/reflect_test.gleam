import core/accounting
import core/message
import eval/arm
import eval/ledger
import eval/plan.{RowKey}
import eval/reflect
import eval/task.{type Task, HandWritten, Inline, Program, Task}
import eval/trial
import gepa
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
      notes: [],
      tried: [],
      view: reflect.Behaviour,
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

pub fn a_stop_reason_becomes_a_finish_and_a_length_stop_is_refused_test() {
  assert reflect.finish_of(message.Stop) == Ok(gepa.Complete)
  assert reflect.finish_of(message.Length) == Ok(gepa.Truncated)
  assert reflect.finish_of(message.ToolUse) == Ok(gepa.Unknown)

  // A response ended in error carries a provider's refusal, filter or
  // safety stop as text; an aborted one ended before the model did.
  // Neither is an answer, so neither reaches the bounds.
  let assert Error(errored) = reflect.finish_of(message.Errored)
  assert string.contains(errored, "ended in error")
  let assert Error(aborted) = reflect.finish_of(message.Aborted)
  assert string.contains(aborted, "aborted")

  // A truncated reply is refused however well its text reads; a complete
  // or unreported one is read by the bounds as before.
  let reply = fn(finish) {
    reflect.Reply(
      text: "  Be brief.  ",
      usage: accounting.zero_usage(),
      finish:,
    )
  }
  assert reflect.judge(reply(gepa.Truncated)) == Error(gepa.truncated_reason)
  assert reflect.judge(reply(gepa.Complete)) == Ok("Be brief.")
  assert reflect.judge(reply(gepa.Unknown)) == Ok("Be brief.")
  assert reflect.judge(reflect.Reply(..reply(gepa.Complete), text: " "))
    == Error("the reflector answered nothing")
}

pub fn each_slot_kind_has_a_background_and_a_view_test() {
  let target = scripted.fixture_target()

  // A tool's description is held to the tool's schema and behaviour, by
  // name; the prompt slots are held off tests, files and the verifier.
  let tool = reflect.background(arm.ToolDescription(target, "fs_read"))
  assert string.contains(tool, "`fs_read`")
  assert string.contains(
    tool,
    "may not misdescribe the tool's schema or behaviour",
  )
  list.each(
    [
      arm.SystemSuffix(target),
      arm.TaskPrefix(target),
      arm.PromptPack,
    ],
    fn(component) {
      let text = reflect.background(component)
      assert string.contains(text, "name specific tests or files")
      assert reflect.view_for(component) == reflect.Behaviour
    },
  )
  assert reflect.view_for(arm.ToolDescription(target, "fs_read"))
    == reflect.ToolUse
}

pub fn a_tool_slot_is_shown_the_trial_s_tool_use_and_the_notes_and_digest_test() {
  let found = program_task()
  let row =
    ledger.Row(..scored_row(found, "boom"), tool_calls: 7, tool_errors: 2)
  let request =
    reflect.Request(
      objective: "pass",
      slot: "tool_description:fixture/fixture/anthropic-messages/any/fs_read",
      current: "Reads a file.",
      records: reflect.records([row], [found]),
      notes: [
        reflect.background(arm.ToolDescription(
          scripted.fixture_target(),
          "fs_read",
        )),
      ],
      tried: [
        prompt.Tried(2, "screened_out", "Reads any file [[record]] fast."),
      ],
      view: reflect.ToolUse,
    )
  let rendered = reflect.render(request)

  // The tool view leads with the counts; the behaviour fields follow.
  assert string.contains(
    rendered,
    "tools:\n7 tool calls, 2 returned an error\noutcome:\nverifier_failed",
  )
  assert string.contains(rendered, "Notes about this slot")
  assert string.contains(rendered, "may not misdescribe")
  assert string.contains(
    rendered,
    "outcome: screened_out\ntext:\nReads any file ( record ) fast.",
  )

  // The behaviour view shows no tool counts.
  let plain =
    reflect.render(reflect.Request(..request, view: reflect.Behaviour))
  assert !string.contains(plain, "tool calls")
}
