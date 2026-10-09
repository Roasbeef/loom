//// `trace_view.fold` turns a window of records into the session's list of
//// `code_mode` programs. These tests build records holding `code_mode` calls
//// and results in the shape `tools/codemode` writes (`status`, `value`,
//// `message`) and check the order, the state each result maps to, the
//// excerpt and label bounds, that other tools add nothing, and that
//// markup-laden or control-laden session text comes out as one clean line.

import core/clock
import core/entry
import core/ids
import core/json
import core/message
import core/usage_evidence
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import session_view/protocol
import session_view/trace_view.{
  CompileFailed, Completed, Errored, Failed, Passed, Pending, Refused, Rejected,
  RunFailed, Running,
}

fn id(seq: Int) -> ids.EntryId {
  ids.mint_entry(ids.generator(clock.fixed(1000), seq)).0
}

fn record(seq: Int, body: message.AgentMessage) -> protocol.EntryRecord {
  let parent = case seq {
    1 -> None
    _ -> Some(id(seq - 1))
  }

  protocol.EntryRecord(
    "main",
    entry.MessageEntry(id(seq), parent, seq, seq * 1000, body, False),
  )
}

fn usage() -> message.Usage {
  message.Usage(
    0,
    0,
    0,
    0,
    None,
    None,
    0,
    message.UsageCost(0.0, 0.0, 0.0, 0.0, 0.0),
    usage_evidence.none(),
  )
}

fn call(
  call_id: String,
  name: String,
  arguments: json.JsonValue,
) -> message.AgentMessage {
  message.AssistantMessage(
    [
      message.AssistantToolCall(message.ToolCall(
        call_id,
        name,
        arguments,
        None,
        None,
      )),
    ],
    "test",
    "test",
    "test",
    None,
    None,
    None,
    usage(),
    message.Stop,
    None,
    None,
    None,
    None,
    0,
  )
}

fn result(
  call_id: String,
  name: String,
  text: String,
  details: Option(json.JsonValue),
  failed: Bool,
) -> message.AgentMessage {
  message.ToolResultMessage(
    call_id,
    name,
    [message.ToolResultText(text, None)],
    details,
    None,
    None,
    failed,
    0,
  )
}

fn program(source: String, within_ms: Option(Int)) -> json.JsonValue {
  json.Object(
    list.append([#("program", json.String(source))], case within_ms {
      Some(ms) -> [#("within_ms", json.Int(ms))]
      None -> []
    }),
  )
}

fn status(
  word: String,
  rest: List(#(String, json.JsonValue)),
) -> Option(json.JsonValue) {
  Some(json.Object([#("status", json.String(word)), ..rest]))
}

// One `code_mode` call and its result as two records, oldest first. The
// result is absent for a call still running.
fn exchange(
  index: Int,
  arguments: json.JsonValue,
  outcome: Option(#(String, Option(json.JsonValue), Bool)),
) -> List(protocol.EntryRecord) {
  let call_id = "call-" <> int.to_string(index)
  let base = index * 2 + 1

  [
    record(base, call(call_id, "code_mode", arguments)),
    ..case outcome {
      None -> []
      Some(#(text, details, failed)) -> [
        record(base + 1, result(call_id, "code_mode", text, details, failed)),
      ]
    }
  ]
}

// A window as a host holds it, newest first.
fn window(
  exchanges: List(List(protocol.EntryRecord)),
) -> List(protocol.EntryRecord) {
  exchanges |> list.flatten |> list.reverse
}

fn only(trace: trace_view.Trace) -> trace_view.Program {
  let assert [program] = trace.programs as "one program"
  program
}

pub fn an_empty_window_has_no_programs_test() {
  assert trace_view.fold([]) == trace_view.empty()
}

pub fn other_tools_add_nothing_test() {
  let records =
    window([
      [
        record(1, call("c1", "fs_read", json.Object([]))),
        record(2, result("c1", "fs_read", "text", None, False)),
      ],
    ])

  assert trace_view.fold(records) == trace_view.empty()
}

pub fn a_call_with_no_result_is_running_test() {
  let trace =
    trace_view.fold(
      window([exchange(0, program("pub fn main() {}", Some(5000)), None)]),
    )

  assert only(trace)
    == trace_view.Program(
      Running,
      "Program 1",
      None,
      Some(5000),
      Pending,
      None,
      None,
      [],
    )
}

pub fn a_completed_program_shows_its_value_test() {
  let outcome =
    Some(#(
      "3\nsandbox: ...",
      status("completed", [#("value", json.Int(3))]),
      False,
    ))
  let trace =
    trace_view.fold(
      window([
        exchange(
          0,
          program("\n// count functions\npub fn main() { 3 }", Some(30_000)),
          outcome,
        ),
      ]),
    )
  let shown = only(trace)

  assert shown.state == Completed
  assert shown.label == "count functions"
  assert shown.excerpt == Some("3")
  assert shown.within_ms == Some(30_000)
  assert shown.vetting == Passed
  assert trace_view.budget_line(shown) == "30000 ms wall · vetted"
}

// The compiler's diagnostics are kept apart from the text written for the
// model, so a host can show a reader the first and not the second.
pub fn a_failed_build_keeps_its_diagnostics_apart_from_the_models_text_test() {
  let outcome =
    Some(#(
      "the program did not compile and did not run. Fix the diagnostics below",
      status("compile_failed", [#("detail", json.String("error: no module"))]),
      True,
    ))
  let shown =
    only(
      trace_view.fold(
        window([exchange(0, program("pub fn main() {}", None), outcome)]),
      ),
    )

  assert shown.state == CompileFailed
  assert shown.detail == Some("error: no module")

  // The compiler's progress and warnings before the first error are not the
  // reason, so the detail starts at the error.
  let noisy =
    Some(#(
      "text",
      status("compile_failed", [
        #(
          "detail",
          json.String(
            "Compiling app\nwarning: unused import\n\nerror: Unknown module\n  fs.nope",
          ),
        ),
      ]),
      True,
    ))
  assert only(
      trace_view.fold(
        window([exchange(0, program("pub fn main() {}", None), noisy)]),
      ),
    ).detail
    == Some("error: Unknown module\n  fs.nope")
  assert trace_view.budget_words(shown) == "default"
  assert trace_view.budget_words(
      trace_view.Program(..shown, within_ms: Some(30_000)),
    )
    == "30 s"
  assert trace_view.budget_words(
      trace_view.Program(..shown, within_ms: Some(1500)),
    )
    == "1500 ms"
}

// A vetting refusal keeps its reasons in `rejections`; the result's text ends
// with an instruction to the model, which a reader is not shown.
pub fn a_refused_program_shows_the_rejection_not_the_instruction_test() {
  let rejection = fn(detail) {
    json.Object([
      #("rule", json.String("import_not_allowed")),
      #("detail", json.String(detail)),
    ])
  }
  let outcome =
    Some(#(
      "the program was refused before it ran; fix the program and submit it again.",
      status("vetting_rejected", [
        #(
          "rejections",
          json.Array([
            rejection("import os is not allowed"),
            rejection("second"),
          ]),
        ),
      ]),
      True,
    ))
  let shown =
    only(
      trace_view.fold(
        window([exchange(0, program("import os", None), outcome)]),
      ),
    )

  assert shown.state == Rejected
  assert shown.detail == Some("import os is not allowed\nsecond")
}

// A failure with no reason in its details still shows what happened, as the
// first sentence of its text, and never the instruction after it.
pub fn an_empty_reason_falls_back_to_the_first_sentence_test() {
  let outcome =
    Some(#(
      "the program did not compile and did not run. Fix the diagnostics below",
      status("compile_failed", [#("detail", json.String(""))]),
      True,
    ))
  let shown =
    only(
      trace_view.fold(
        window([exchange(0, program("pub fn main() {}", None), outcome)]),
      ),
    )

  assert shown.detail == Some("the program did not compile and did not run.")
}

pub fn a_named_file_is_the_label_test() {
  let arguments =
    json.Object([
      #("program_path", json.String("scripts/count.gleam")),
      #("program", json.String("ignored")),
    ])
  let trace = trace_view.fold(window([exchange(0, arguments, None)]))

  assert only(trace).label == "scripts/count.gleam"
  assert trace_view.budget_line(only(trace))
    == "default wall budget · not vetted yet"
}

pub fn each_status_word_maps_to_a_state_test() {
  let cases = [
    #("errored", Errored, Passed),
    #("program_failed", Errored, Passed),
    #("vetting_rejected", Rejected, Refused),
    #("compile_failed", CompileFailed, Passed),
    #("run_failed", RunFailed, Passed),
    #("something_new", Failed, Pending),
  ]

  list.each(cases, fn(row) {
    let #(word, state, vetting) = row
    let trace =
      trace_view.fold(
        window([
          exchange(
            0,
            program("x", None),
            Some(#("boom", status(word, [#("message", json.String("m"))]), True)),
          ),
        ]),
      )

    assert only(trace).state == state
    assert only(trace).vetting == vetting
    assert only(trace).excerpt == Some("m")
  })
}

pub fn an_error_with_no_details_falls_back_to_its_text_test() {
  let trace =
    trace_view.fold(
      window([
        exchange(0, program("x", None), Some(#("denied by policy", None, True))),
      ]),
    )

  assert only(trace).state == Failed
  assert only(trace).excerpt == Some("denied by policy")
}

pub fn programs_keep_their_order_and_the_newest_is_last_test() {
  let trace =
    trace_view.fold(
      window([
        exchange(
          0,
          program("first", None),
          Some(#("1", status("completed", [#("value", json.Int(1))]), False)),
        ),
        exchange(1, program("second", None), None),
      ]),
    )

  assert list.map(trace.programs, fn(shown) { shown.label })
    == ["Program 1", "Program 2"]
  assert list.map(trace.programs, fn(shown) { shown.state })
    == [Completed, Running]
}

pub fn the_trace_keeps_the_newest_programs_and_counts_the_rest_test() {
  let extra = 3
  let exchanges =
    list.repeat(Nil, trace_view.max_programs + extra)
    |> list.index_map(fn(_, index) {
      exchange(index, program("p" <> int.to_string(index), None), None)
    })
  let trace = trace_view.fold(window(exchanges))

  assert list.length(trace.programs) == trace_view.max_programs
  assert trace.omitted == extra
  let assert Ok(first) = list.first(trace.programs)
  assert first.label == "Program " <> int.to_string(extra + 1)
}

pub fn an_excerpt_is_one_clean_bounded_line_test() {
  let long = string.repeat("a", trace_view.max_characters * 2)
  let hostile = "<script>alert(1)</script>\n\u{1b}[31mred\u{7}" <> long
  let trace =
    trace_view.fold(
      window([
        exchange(
          0,
          program("// " <> hostile, None),
          Some(#(
            hostile,
            status("completed", [#("value", json.String(hostile))]),
            False,
          )),
        ),
      ]),
    )
  let shown = only(trace)
  let assert Some(excerpt) = shown.excerpt

  assert string.length(excerpt) <= trace_view.max_characters
  assert string.length(shown.label) <= trace_view.max_characters
  assert !string.contains(excerpt, "\n")
  assert !string.contains(excerpt, "\u{1b}")
  assert string.contains(shown.label, "<script>")
  assert string.ends_with(excerpt, "…")
}

pub fn the_sandbox_line_the_result_reported_is_kept_test() {
  let layers = fn(enforced) {
    json.Object([
      #("reported", json.Bool(True)),
      #("enforced", json.Array(enforced)),
      #("skipped", json.Array([])),
    ])
  }
  let sandbox =
    json.Object([
      #("build", layers([json.String("a"), json.String("b")])),
      #("node", layers([json.String("a")])),
    ])
  let trace =
    trace_view.fold(
      window([
        exchange(
          0,
          program("x", None),
          Some(#("1", status("completed", [#("sandbox", sandbox)]), False)),
        ),
      ]),
    )

  assert only(trace).sandbox
    == Some(
      "sandbox · build enforced 2 layers; skipped 0 · satellite enforced 1 layers; skipped 0",
    )
  assert trace_view.first_call(only(trace)) == "Program 1"
}

pub fn the_label_is_the_leading_comment_after_the_imports_test() {
  let source =
    "\nimport cap/fs\nimport gleam/list\n\n//// Count the functions in calc.py.\npub fn main() { 1 }"
  let trace =
    trace_view.fold(window([exchange(0, program(source, None), None)]))

  assert only(trace).label == "Count the functions in calc.py."
}

pub fn a_program_that_opens_with_code_is_numbered_test() {
  let trace =
    trace_view.fold(
      window([
        exchange(0, program("import cap/fs\npub fn main() { 1 }", None), None),
        exchange(1, program("// \npub fn main() { 2 }", None), None),
        exchange(2, program("// later\npub fn main() { 3 }", None), None),
      ]),
    )

  assert list.map(trace.programs, fn(shown) { shown.label })
    == ["Program 1", "Program 2", "later"]
}

// An assistant message with reasoning ahead of a `code_mode` call, the shape
// real models write.
fn reasoned_call(call_id: String) -> message.AgentMessage {
  message.AssistantMessage(
    [
      message.AssistantThinking("plan the program", None, False),
      message.AssistantToolCall(message.ToolCall(
        call_id,
        "code_mode",
        program("pub fn main() {}", None),
        None,
        None,
      )),
    ],
    "test",
    "test",
    "test",
    None,
    None,
    None,
    usage(),
    message.Stop,
    None,
    None,
    None,
    None,
    0,
  )
}

pub fn a_program_called_after_reasoning_is_listed_test() {
  let records = [
    record(2, result("c1", "code_mode", "done", status("completed", []), False)),
    record(1, reasoned_call("c1")),
  ]

  assert list.length(trace_view.fold(records).programs) == 1
}

// --- the newest program of one strand, and the call record --------------

fn on(strand: String, records: List(protocol.EntryRecord)) {
  list.map(records, fn(found) { protocol.EntryRecord(..found, strand:) })
}

fn calls_record(total: Int, failed: Int) -> json.JsonValue {
  json.Object([
    #("started_unix_ms", json.Int(0)),
    #("elapsed_ms", json.Int(120)),
    #("total", json.Int(total)),
    #("failed", json.Int(failed)),
    #("cancelled", json.Int(0)),
    #("unsettled", json.Int(0)),
    #(
      "items",
      json.Array([
        json.Object([
          #("cap", json.String("fs.read")),
          #("args", json.String("a.gleam")),
          #("status", json.String("ok")),
          #("start_ms", json.Int(1)),
          #("duration_ms", json.Int(2)),
        ]),
      ]),
    ),
  ])
}

pub fn a_strand_with_no_program_has_no_newest_test() {
  assert trace_view.newest([], "main") == None
  let other = on("sub:a", exchange(0, program("pub fn main() {}", None), None))
  assert trace_view.newest(other, "main") == None
    as "another strand's program is not this strand's"
}

pub fn the_newest_program_wins_whatever_the_order_test() {
  let older = exchange(0, program("// older", None), None)
  let newer = exchange(1, program("// newer", None), None)
  let forward = trace_view.newest(list.append(older, newer), "main")
  let backward =
    trace_view.newest(list.reverse(list.append(older, newer)), "main")
  assert forward == backward
  let assert Some(found) = forward
  assert found.source == ["  1 │ // newer"]
  assert found.program.label == "newer"
}

pub fn a_running_program_has_its_source_and_no_calls_test() {
  let assert Some(found) =
    trace_view.newest(
      exchange(0, program("import cap/fs\npub fn main() {}", None), None),
      "main",
    )
  assert found.program.state == Running
  assert found.program.excerpt == None
  assert found.program.calls == []
  assert found.source == ["  1 │ import cap/fs", "  2 │ pub fn main() {}"]
}

pub fn a_result_with_a_call_record_lists_its_calls_test() {
  let details =
    status("completed", [
      #("value", json.String("42")),
      #("calls", calls_record(1, 0)),
    ])
  let assert Some(found) =
    trace_view.newest(
      exchange(
        0,
        program("pub fn main() {}", None),
        Some(#("fallback", details, False)),
      ),
      "main",
    )
  assert found.program.state == Completed
  let assert [heading, row] = found.program.calls
  assert heading == "CALLS · 1 call · 0 failed"
  assert string.contains(row, "fs.read")
  assert string.contains(row, "a.gleam")
  assert trace_view.first_call(found.program) == row
}

pub fn a_result_with_no_record_lists_no_calls_test() {
  let assert Some(found) =
    trace_view.newest(
      exchange(
        0,
        program("x", None),
        Some(#("it failed", status("run_failed", []), True)),
      ),
      "main",
    )
  assert found.program.state == RunFailed
  assert found.program.calls == []
  assert trace_view.first_call(found.program) == "Program 1"
}

pub fn a_state_is_worded_as_the_transcript_words_it_test() {
  assert trace_view.state_title(CompileFailed) == "compile error"
  assert trace_view.state_title(Rejected) == "refused by vetting"
  assert trace_view.state_title(RunFailed) == "did not finish"
  assert trace_view.state_title(Errored) == "program failed"
  assert trace_view.state_title(Failed) == "failed"
}

pub fn a_long_program_is_cut_and_counted_test() {
  let source = list.repeat("let x = 1", 30) |> string.join("\n")
  let rows = trace_view.source_rows(source)
  assert list.length(rows) == trace_view.source_lines + 1
  assert list.last(rows)
    == Ok("    … 18 more lines · the transcript has the rest")
  assert list.first(rows) == Ok("  1 │ let x = 1")
}

pub fn program_text_is_one_line_per_row_test() {
  let rows = trace_view.source_rows("a\u{001B}[31mb\nc")
  assert !list.any(rows, string.contains(_, "\u{001B}"))
    as "a control sequence in the program never reaches a host"
}

// Joining the traces of two stretches is the trace of both, oldest program
// first, within the same bound, with the programs left out counted.
pub fn joining_two_stretches_is_tracing_them_together_test() {
  let first =
    trace_view.fold(
      window([exchange(0, program("// one\npub fn main() { 1 }", None), None)]),
    )
  let second =
    trace_view.fold(
      window([exchange(0, program("// two\npub fn main() { 2 }", None), None)]),
    )
  let joined = trace_view.append(first, second)
  assert list.map(joined.programs, fn(program) { program.label })
    == ["one", "two"]
  assert joined.omitted == 0
  assert trace_view.append(trace_view.empty(), first) == first
  assert trace_view.append(first, trace_view.empty()) == first
}

pub fn a_joined_trace_keeps_the_newest_programs_test() {
  let stretch = fn(from: Int, count: Int) {
    int.range(from: from + count - 1, to: from - 1, with: [], run: fn(all, n) {
      [n, ..all]
    })
    |> list.map(fn(index) {
      exchange(
        index,
        program("// p" <> int.to_string(index) <> "\npub fn main() {}", None),
        None,
      )
    })
    |> window
    |> trace_view.fold
  }
  let joined = trace_view.append(stretch(0, 10), stretch(10, 10))
  assert list.length(joined.programs) == trace_view.max_programs
  assert joined.omitted == 8
  let assert Ok(newest) = list.last(joined.programs)
  assert newest.label == "p19"
}
