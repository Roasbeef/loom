//// The words a step reads in: one verb per kind of tool, the subject drawn
//// the way its kind is (code, prose or a figure), the lines an edit changed,
//// and the first call a `code_mode` program makes.

import core/clock
import core/ids
import core/json
import core/message
import gleam/option.{type Option, None, Some}
import gleam/string
import session_view/step_words.{
  type Words, Change, Figure, Mono, Prose, Unnamed, Words,
}
import session_view/tool_activity

fn called(
  name: String,
  arguments: List(#(String, json.JsonValue)),
  outcome: Option(message.AgentMessage),
) -> tool_activity.Call {
  tool_activity.Call(
    ids.mint_entry(ids.generator(clock.fixed(1000), 1)).0,
    message.ToolCall("c1", name, json.Object(arguments), None, None),
    outcome,
    None,
  )
}

fn words(name: String, arguments: List(#(String, json.JsonValue))) -> Words {
  step_words.of_call(called(name, arguments, None))
}

fn text(value: String) -> json.JsonValue {
  json.String(value)
}

fn result(
  details: List(#(String, json.JsonValue)),
  is_error: Bool,
) -> Option(message.AgentMessage) {
  Some(message.ToolResultMessage(
    "c1",
    "fs_edit",
    [message.ToolResultText("ok", None)],
    Some(json.Object(details)),
    None,
    None,
    is_error,
    0,
  ))
}

pub fn a_read_names_its_path_in_code_test() {
  assert words("fs_read", [#("path", text("src/calc.py"))])
    == Words("Read", Mono("src/calc.py"), None)
  assert words("read", [#("path", text("a.gleam"))])
    == Words("Read", Mono("a.gleam"), None)
}

pub fn a_command_keeps_its_first_line_test() {
  assert words("bash", [#("command", text("python3 -m unittest"))])
    == Words("Ran", Mono("python3 -m unittest"), None)
  assert step_words.text(words("bash", [#("command", text("make a\nmake b"))]))
    == "Ran make a …"
}

pub fn an_edit_counts_the_lines_its_result_reported_test() {
  let diff = "@@ -1,2 +1,4 @@\n keep\n-old\n+new\n+newer\n+newest"
  let call =
    called(
      "fs_edit",
      [#("path", text("calc.py"))],
      result([#("diff", text(diff))], False),
    )
  assert step_words.of_call(call)
    == Words("Edit", Mono("calc.py"), Some(Change(3, 1)))
  assert step_words.text(step_words.of_call(call)) == "Edit calc.py +3 −1"
}

pub fn an_edit_with_no_result_or_a_failed_one_claims_no_change_test() {
  assert words("fs_edit", [#("path", text("calc.py"))])
    == Words("Edit", Mono("calc.py"), None)
  let failed =
    called(
      "fs_edit",
      [#("path", text("calc.py"))],
      result([#("diff", text("+x"))], True),
    )
  assert step_words.of_call(failed) == Words("Edit", Mono("calc.py"), None)
}

pub fn a_long_path_keeps_its_end_test() {
  let long =
    "a/very/long/directory/name/"
    <> "that/goes/on/and/on/and/on/for/ages/and/ages/and/ages/and/more/ages/"
  let assert Words(subject: Mono(shown), ..) =
    words("fs_read", [#("path", text(long <> "calc.py"))])
  assert shown != long <> "calc.py"
  assert string.starts_with(shown, "…")
  assert string.ends_with(shown, "calc.py")
}

pub fn the_other_shipped_tools_have_their_own_verbs_test() {
  assert words("fs_write", [#("path", text("new.py"))])
    == Words("Wrote", Mono("new.py"), None)
  assert words("grep", [#("pattern", text("def add")), #("path", text("src"))])
    == Words("Searched", Mono("def add in src"), None)
  assert words("agent_spawn", [#("purpose", text("scan the repo"))])
    == Words("Spawned", Prose("scan the repo"), None)
  assert words("agent_wait", [
      #("handles", json.Array([text("a"), text("b")])),
    ])
    == Words("Waited for", Prose("2 sub-agents"), None)
  assert words("agent_wait", [#("handles", json.Array([text("a")]))])
    == Words("Waited for", Prose("1 sub-agent"), None)
  assert words("agent_send", [#("to", text("main"))])
    == Words("Messaged", Prose("main"), None)
  assert words("agent_note", [#("key", text("plan"))])
    == Words("Noted", Mono("plan"), None)
  assert words("context_remaining", [])
    == Words("Checked context", Unnamed, None)
}

// The `todo` tool's ops are the model's vocabulary; a step says what a
// person would: a count for a new list, a past participle and the task for
// the rest.
pub fn a_todo_step_reads_in_a_readers_words_test() {
  let phase = fn(items) {
    json.Object([#("name", text("Work")), #("items", json.Array(items))])
  }
  let task = fn(op, name) {
    words("todo", [#("op", text(op)), #("task", text(name))])
  }

  assert step_words.text(words("todo", [#("op", text("view"))]))
    == "Todo · viewed"
  assert step_words.text(
      words("todo", [
        #("op", text("init")),
        #(
          "phases",
          json.Array([
            phase([text("a"), text("b")]),
            phase([text("c"), text("d")]),
          ]),
        ),
      ]),
    )
    == "Todo · 4 tasks"
  assert step_words.text(
      words("todo", [
        #("op", text("init")),
        #("items", json.Array([text("a")])),
      ]),
    )
    == "Todo · 1 task"
  assert step_words.text(task("done", "Add modulo to calc.py"))
    == "Todo · done: Add modulo to calc.py"
  assert step_words.text(task("drop", "Run the program"))
    == "Todo · dropped: Run the program"
  assert step_words.text(words("todo", [#("op", text("done"))]))
    == "Todo · done"

  let long = string.repeat("x", 80)
  assert string.length(step_words.text(task("start", long)))
    == string.length("Todo · started: ") + 60
}

// A result's first line is what a reader scans: a Markdown marker is bare, a
// long line is cut at a word with the ellipsis inside it, and a cut that
// lands on a word's end keeps the whole word.
pub fn a_result_line_is_cut_at_a_word_with_an_inline_ellipsis_test() {
  assert step_words.result_line("# Summary\n\nFound two files.") == "Summary"
  assert step_words.result_line("") == ""

  let cut = step_words.result_line(string.repeat("alpha ", 40))
  assert string.ends_with(cut, "alpha…")
  assert string.length(cut) <= step_words.result_limit + 1

  let whole = string.repeat("a", step_words.result_limit - 1) <> " tail"
  assert step_words.result_line(whole)
    == string.repeat("a", step_words.result_limit - 1) <> "…"
}

pub fn a_tool_the_table_does_not_know_keeps_its_own_name_test() {
  assert words("mcp_search", [#("q", text("x"))])
    == Words("mcp_search", Mono("{\"q\":\"x\"}"), None)
  assert words("mcp_ping", []) == Words("mcp_ping", Unnamed, None)
}

pub fn a_known_tool_with_malformed_arguments_falls_back_to_its_name_test() {
  assert words("fs_read", [#("path", json.Int(3))])
    == Words("fs_read", Mono("{\"path\":3}"), None)
}

pub fn memory_and_reasoning_read_as_a_verb_and_a_figure_test() {
  assert step_words.text(step_words.memory(4)) == "Memory · 4 lines"
  assert step_words.text(step_words.memory(1)) == "Memory · 1 line"
  assert step_words.memory(4).subject == Figure("4 lines")
  assert step_words.text(step_words.reasoning(Some(4000))) == "Reasoning · 4s"
  assert step_words.text(step_words.reasoning(None)) == "Reasoning"
}

pub fn a_fold_summary_leaves_out_a_figure_the_records_did_not_give_test() {
  assert step_words.worked(Some(22_000), 10, 2)
    == "Worked 22s · 10 steps · 2 files"
  assert step_words.worked(Some(5000), 1, 1) == "Worked 5s · 1 step · 1 file"
  assert step_words.worked(None, 0, 0) == "Worked"
}

pub fn durations_read_in_the_largest_unit_that_fits_test() {
  assert step_words.duration(400) == "<1s"
  assert step_words.duration(48_000) == "48s"
  assert step_words.duration(64_000) == "1m 4s"
  assert step_words.duration(7_260_000) == "2h 1m"
}

pub fn a_result_reads_finished_for_a_completed_child_test() {
  assert step_words.returned("completed") == "finished"
  assert step_words.returned("failed") == "failed"
}

pub fn a_program_names_the_first_capability_it_calls_test() {
  let program =
    "import cap/fs\nimport cap/proc\n\npub fn main() {\n  let text = fs.read(\"calc.py\")\n  proc.run(\"ls\")\n}"
  assert step_words.first_call(program) == Some("fs.read calc.py")
  assert step_words.of_call(called(
      "code_mode",
      [#("program", text(program))],
      None,
    ))
    == Words("code_mode", Mono("fs.read calc.py"), None)
}

pub fn a_call_without_a_literal_argument_names_only_the_function_test() {
  assert step_words.first_call(
      "import cap/git\n\npub fn main() {\n  git.status(root)\n}",
    )
    == Some("git.status")
}

pub fn an_aliased_import_and_a_longer_name_are_told_apart_test() {
  let program =
    "import cap/fs as files\n\npub fn main() {\n  profiles.read(\"x\")\n  files.write(\"out.txt\", \"y\")\n}"
  assert step_words.first_call(program) == Some("fs.write out.txt")
}

pub fn a_program_that_calls_nothing_is_just_code_mode_test() {
  assert step_words.first_call("pub fn main() { 1 + 1 }") == None
  assert words("code_mode", [#("program", text("pub fn main() { 1 }"))])
    == Words("code_mode", Unnamed, None)
  assert words("code_mode", []) == Words("code_mode", Unnamed, None)
}

// The words are session text: a tool name, or a module or function name in a
// program, can be any length the model writes, so a step's line is bounded.
pub fn a_huge_tool_or_function_name_is_clipped_test() {
  let huge = string.repeat("a", 10_000)
  let Words(verb:, ..) = words(huge, [])
  assert string.length(verb) == step_words.subject_limit

  let program = "import cap/fs\n\npub fn main() {\n  fs." <> huge <> "(1)\n}"
  let assert Words(subject: Mono(shown), ..) =
    step_words.of_call(called("code_mode", [#("program", text(program))], None))
  assert string.length(shown) == step_words.subject_limit
}

// Only the call's own first argument is read: a name or an expression there
// says no argument, and a literal belonging to a later call is not taken.
pub fn only_the_calls_own_first_argument_is_read_test() {
  assert step_words.first_call(
      "import cap/fs\nimport cap/proc\n\npub fn main() {\n  fs.read(path); proc.run(\"ls\")\n}",
    )
    == Some("fs.read")
  assert step_words.first_call(
      "import cap/fs\n\npub fn main() {\n  fs.read(name <> \".txt\")\n}",
    )
    == Some("fs.read")
  assert step_words.first_call(
      "import cap/fs\n\npub fn main() {\n  fs.read( \"calc.py\" )\n}",
    )
    == Some("fs.read calc.py")
}

// A longer name that merely ends in the module's name is skipped, and the real
// call after it still wins over a later module on the line.
pub fn a_skipped_longer_name_does_not_reorder_the_calls_test() {
  assert step_words.first_call(
      "import cap/fs\nimport cap/proc\n\npub fn main() {\n  profs.x(1) fs.read(\"a\") proc.run(\"b\")\n}",
    )
    == Some("fs.read a")
}
