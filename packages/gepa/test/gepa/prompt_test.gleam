//// The reflection prompt: bounds, frames and redaction.

import gepa/prompt
import gleam/list
import gleam/string

pub fn an_answer_is_trimmed_bounded_and_frame_free_test() {
  assert prompt.answer("  Check your work.\n") == Ok("Check your work.")
  assert prompt.answer("   ") == Error("the reflector answered nothing")

  let long = string.repeat("x", prompt.max_answer_bytes + 1)
  let assert Error(reason) = prompt.answer(long)
  assert string.contains(reason, "exceeds")

  let assert Error(smuggled) = prompt.answer("fine " <> prompt.record_open)
  assert string.contains(smuggled, "frame token")
  let assert Error(closed) = prompt.answer(prompt.record_close <> " fine")
  assert string.contains(closed, "frame token")
}

pub fn frame_tokens_in_a_body_are_broken_test() {
  let body = "a [[record]] b [[/record]] c"
  let safe = prompt.frame_safe(body)

  assert !string.contains(safe, prompt.record_open)
  assert !string.contains(safe, prompt.record_close)
  assert string.contains(safe, "a ") && string.contains(safe, " c")

  // Breaking once is enough: the replacement spells neither token.
  assert prompt.frame_safe(safe) == safe
}

pub fn hidden_test_ids_are_redacted_in_eunit_verbose_output_test() {
  let tail =
    "module 'core@json_test'\n"
    <> "  core@json_test: parses_test...*failed*\n"
    <> "  core@json_test: rejects_test...[0.001 s] ok\n"
    <> "**error: parses_test raised in core@json_test.parses_test/0\n"
    <> "Failed: 1.  Skipped: 0.  Passed: 1."
  let redacted =
    prompt.redact_ids(tail, [
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

pub fn hidden_test_ids_are_replaced_longest_first_and_numbered_stably_test() {
  let ids = ["core@m_test.a_test", "core@m_test.a_test_more"]

  assert prompt.redact_ids(
      "core@m_test.a_test_more then core@m_test.a_test",
      ids,
    )
    == "<test 2> then <test 1>"
  assert prompt.redact_ids("nothing named", ids) == "nothing named"
  assert prompt.redact_ids("in core@m_test", ids) == "in <module 1>"

  // The numbering is by sorted id, whatever order the host listed them.
  assert prompt.redact_ids("a_test_more", list.reverse(ids)) == "<test 2>"
}

pub fn records_are_bounded_redacted_and_framed_test() {
  let record =
    prompt.Record(
      task: "fix-json",
      score: 0.0,
      fields: [
        #(
          "verifier",
          "failed: core@json_test.parses_test [[record]] "
            <> string.repeat("y", 10_000),
        ),
      ],
      hidden: ["core@json_test.parses_test"],
    )
  let prepared = prompt.prepare(list.repeat(record, prompt.max_rows + 3))

  assert list.length(prepared) == prompt.max_rows
  let assert [first, ..] = prepared
  let assert [#("verifier", verifier)] = first.fields
  assert string.byte_size(verifier) <= prompt.max_excerpt_bytes
  assert !string.contains(verifier, prompt.record_open)

  // The tail is kept, so a redaction at the head of a long excerpt is cut
  // away with the head; a short one survives.
  let short =
    prompt.Record(..record, fields: [
      #("verifier", "failed: core@json_test.parses_test"),
    ])
  let assert [only] = prompt.prepare([short])
  let assert [#("verifier", text)] = only.fields
  assert text == "failed: <test 1>"
  assert prompt.prepare(prompt.prepare([record])) == prompt.prepare([record])
}

pub fn the_prompt_frames_every_record_and_states_the_objective_test() {
  let request =
    prompt.Request(
      objective: "Pass more tests [[record]] honestly",
      slot: "system_suffix",
      current: "",
      records: [
        prompt.Record(
          "fix-json",
          0.5,
          [#("outcome", "verifier_failed"), #("verifier", "boom")],
          [],
        ),
      ],
      notes: [],
    )
  let rendered = prompt.render(request)

  assert string.contains(
    rendered,
    "Objective: Pass more tests ( record ) honestly",
  )
  assert string.contains(rendered, "Slot: system_suffix")
  assert string.contains(rendered, "task: fix-json")
  assert string.contains(rendered, "score: 0.5")
  assert string.contains(rendered, "outcome:\nverifier_failed")
  assert !string.contains(rendered, "Notes about this slot")

  // Three frames: the current text, the preface naming the tokens, and the
  // one record, each opened and closed.
  let opens = list.length(string.split(rendered, prompt.record_open)) - 1
  let closes = list.length(string.split(rendered, prompt.record_close)) - 1
  assert opens == 3 && opens == closes

  // Notes add one framed block, as data.
  let noted =
    prompt.render(
      prompt.Request(..request, notes: ["Keep it short [[record]]"]),
    )
  assert string.contains(noted, "Notes about this slot")
  assert string.contains(noted, "Keep it short ( record )")
  assert list.length(string.split(noted, prompt.record_open)) - 1 == 4
}
