import broker/broker
import broker/exec
import core/json
import core/message
import gleam/erlang/process
import gleam/list
import gleam/option.{Some}
import gleam/string
import support/fake_broker
import support/memory_fs
import tools/grep
import tools/tool

const workspace = "/work"

const now = 9000

fn run_with_script(
  script: List(broker.CallEvent),
  args: json.JsonValue,
) -> #(tool.ToolOutcome, process.Subject(fake_broker.Recorded)) {
  let filesystem = memory_fs.filesystem(memory_fs.start())
  let recorded = process.new_subject()
  let ctx = fake_broker.ctx(workspace:, filesystem:, now:, script:, recorded:)
  let outcome = grep.tool().run(ctx, args)
  #(outcome, recorded)
}

fn pattern_args(pattern: String) -> json.JsonValue {
  json.Object([#("pattern", json.String(pattern))])
}

fn first_text(outcome: tool.ToolOutcome) -> String {
  let assert [message.ToolResultText(text:, text_signature: _)] =
    outcome.content
    as "expected a single text block"
  text
}

fn recorded_spec(
  recorded: process.Subject(fake_broker.Recorded),
) -> broker.CallSpec {
  let assert Ok(fake_broker.Spec(spec:)) = process.receive(recorded, 1000)
    as "the tool never cleared a call"
  spec
}

fn match_line(path: String, line: Int, text: String) -> String {
  "{\"type\":\"match\",\"data\":{\"path\":{\"text\":\""
  <> path
  <> "\"},\"lines\":{\"text\":\""
  <> text
  <> "\\n\"},\"line_number\":"
  <> string.inspect(line)
  <> ",\"absolute_offset\":0,\"submatches\":[]}}\n"
}

// --- parsing -------------------------------------------------------------

pub fn parse_matches_test() {
  let stdout =
    "{\"type\":\"begin\",\"data\":{\"path\":{\"text\":\"a.gleam\"}}}\n"
    <> match_line("a.gleam", 3, "let x = 1")
    <> "{\"type\":\"end\",\"data\":{}}\n"
    <> "{\"type\":\"summary\",\"data\":{}}\n"
  assert grep.parse_matches(stdout)
    == [grep.Match(path: "a.gleam", line: 3, text: "let x = 1")]
}

pub fn parse_skips_malformed_lines_test() {
  let stdout = "not json at all\n" <> match_line("b.txt", 1, "hit")
  assert grep.parse_matches(stdout)
    == [grep.Match(path: "b.txt", line: 1, text: "hit")]
}

// --- happy path ----------------------------------------------------------

pub fn grep_matches_test() {
  let stdout =
    match_line("src/a.gleam", 12, "pub fn anchor")
    <> match_line("src/b.gleam", 4, "anchored")
  let #(outcome, _recorded) =
    run_with_script(
      [fake_broker.stdout(stdout), fake_broker.exited(code: 0, stdout_bytes: 0)],
      pattern_args("anchor"),
    )
  assert outcome.is_error == False
  let text = first_text(outcome)
  assert string.contains(text, "src/a.gleam:12:pub fn anchor")
  assert string.contains(text, "src/b.gleam:4:anchored")
  let assert Some(json.Object(fields)) = outcome.details
  assert list.key_find(fields, "match_count") == Ok(json.Int(2))
}

pub fn grep_no_matches_exit_one_test() {
  // rg exits 1 when nothing matched; that is not an error.
  let #(outcome, _recorded) =
    run_with_script(
      [fake_broker.exited(code: 1, stdout_bytes: 0)],
      pattern_args("nothing"),
    )
  assert outcome.is_error == False
  assert first_text(outcome) == "no matches"
}

pub fn grep_call_spec_shape_test() {
  let #(_outcome, recorded) =
    run_with_script(
      [fake_broker.exited(code: 0, stdout_bytes: 0)],
      json.Object([
        #("pattern", json.String("todo")),
        #("globs", json.Array([json.String("*.gleam")])),
        #("context", json.Int(2)),
      ]),
    )
  let spec = recorded_spec(recorded)
  assert spec.argv
    == [
      "rg", "--json", "--regexp", "todo", "--context", "2", "--glob", "*.gleam",
      workspace,
    ]
  assert spec.cwd == workspace
  assert spec.response == broker.RefuseNarrowed
  // Read-only requirements: nothing writable.
  assert spec.requirements.writable_roots == []
  assert spec.requirements.readable_roots == [workspace]
  assert spec.budget.deadline_ms == now + grep.timeout_ms
}

pub fn grep_path_scopes_search_test() {
  let #(_outcome, recorded) =
    run_with_script(
      [fake_broker.exited(code: 1, stdout_bytes: 0)],
      json.Object([
        #("pattern", json.String("x")),
        #("path", json.String("src")),
      ]),
    )
  let spec = recorded_spec(recorded)
  assert list.last(spec.argv) == Ok("/work/src")
}

pub fn grep_path_escape_rejected_test() {
  let #(outcome, _recorded) =
    run_with_script(
      [],
      json.Object([
        #("pattern", json.String("x")),
        #("path", json.String("../../etc")),
      ]),
    )
  assert outcome.is_error
  assert string.contains(first_text(outcome), "outside the workspace")
}

pub fn grep_max_results_caps_matches_test() {
  let stdout =
    match_line("a", 1, "hit")
    <> match_line("a", 2, "hit")
    <> match_line("a", 3, "hit")
  let #(outcome, _recorded) =
    run_with_script(
      [fake_broker.stdout(stdout), fake_broker.exited(code: 0, stdout_bytes: 0)],
      json.Object([
        #("pattern", json.String("hit")),
        #("max_results", json.Int(2)),
      ]),
    )
  let assert Some(json.Object(fields)) = outcome.details
  assert list.key_find(fields, "match_count") == Ok(json.Int(2))
  assert list.key_find(fields, "capped") == Ok(json.Bool(True))
  assert string.contains(first_text(outcome), "capped at max_results")
}

// --- failure paths -------------------------------------------------------

pub fn grep_rg_unavailable_suggests_bash_test() {
  let #(outcome, _recorded) =
    run_with_script(
      [
        fake_broker.failed(exec.RefusedByHelper(
          code: "spawn_failed",
          message: "no rg",
        )),
      ],
      pattern_args("x"),
    )
  assert outcome.is_error
  let text = first_text(outcome)
  assert string.contains(text, "not available")
  assert string.contains(text, "bash")
}

pub fn grep_rg_error_exit_test() {
  let #(outcome, _recorded) =
    run_with_script(
      [
        fake_broker.stderr("regex parse error\n"),
        fake_broker.exited(code: 2, stdout_bytes: 0),
      ],
      pattern_args("(unclosed"),
    )
  assert outcome.is_error
  let text = first_text(outcome)
  assert string.contains(text, "exit code 2")
  assert string.contains(text, "regex parse error")
}

pub fn grep_other_failures_stay_generic_test() {
  let #(outcome, _recorded) =
    run_with_script([fake_broker.failed(exec.HelperBusy)], pattern_args("x"))
  assert outcome.is_error
  assert string.contains(first_text(outcome), "busy")
}

pub fn grep_invalid_args_test() {
  let #(outcome, _recorded) = run_with_script([], json.Object([]))
  assert outcome.is_error
  assert string.contains(first_text(outcome), "pattern")
}

pub fn grep_negative_context_rejected_test() {
  let #(outcome, _recorded) =
    run_with_script(
      [],
      json.Object([
        #("pattern", json.String("x")),
        #("context", json.Int(-1)),
      ]),
    )
  assert outcome.is_error
}

// --- contract flags ------------------------------------------------------

pub fn grep_flags_test() {
  let grep_tool = grep.tool()
  assert grep_tool.name == "grep"
  assert grep_tool.replay == tool.Safe
  assert grep_tool.execution_mode == tool.Concurrent
}
