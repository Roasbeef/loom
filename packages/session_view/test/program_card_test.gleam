//// A `code_mode` program as a card: the states a card is in, the sentence and
//// chips its call record gives it, the bars its calls are drawn with, and the
//// compiler diagnostic read into its parts.
////
//// The card is a projection of the call and the result joined to it, so each
//// test builds those two by hand and reads the card, and none of them draws
//// anything. What the web view does with a card is `web_view`'s to test.

import core/json
import core/message
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import session_view/call_tree
import session_view/program_card.{
  type ProgramCard, Bar, Collapsed, CompileFailed, Completed, Expanded, Opening,
  OpeningOnly, ProgramFailed, Rejected, RunFailed, Running, Whole,
}

const program =
  "import cap/fs\n\npub fn main() {\n  let a = fs.read(\"a\")\n  let b = fs.read(\"b\")\n  Ok(a <> b)\n}\n"

fn call(arguments: List(#(String, json.JsonValue))) -> message.ToolCall {
  message.ToolCall("c1", "code_mode", json.Object(arguments), None, None)
}

fn running_call() -> message.ToolCall {
  call([#("program", json.String(program)), #("within_ms", json.Int(30_000))])
}

fn result(
  is_error: Bool,
  details: List(#(String, json.JsonValue)),
) -> Option(message.AgentMessage) {
  Some(message.ToolResultMessage(
    "c1",
    "code_mode",
    [message.ToolResultText("the text", None)],
    Some(json.Object(details)),
    None,
    None,
    is_error,
    2000,
  ))
}

fn item(
  cap: String,
  args: Option(String),
  status: String,
  error: Option(String),
  start_ms: Int,
  duration_ms: Int,
) -> json.JsonValue {
  json.Object(
    list.flatten([
      [#("cap", json.String(cap))],
      case args {
        Some(args) -> [#("args", json.String(args))]
        None -> []
      },
      [#("status", json.String(status))],
      case error {
        Some(error) -> [#("error", json.String(error))]
        None -> []
      },
      [
        #("start_ms", json.Int(start_ms)),
        #("duration_ms", json.Int(duration_ms)),
      ],
    ]),
  )
}

fn ok(cap: String, start_ms: Int, duration_ms: Int) -> json.JsonValue {
  item(cap, None, "ok", None, start_ms, duration_ms)
}

fn record(
  items: List(json.JsonValue),
  total: Int,
  failed: Int,
  unsettled: Int,
  elapsed_ms: Int,
) -> #(String, json.JsonValue) {
  #(
    "calls",
    json.Object([
      #("started_unix_ms", json.Int(1)),
      #("elapsed_ms", json.Int(elapsed_ms)),
      #("total", json.Int(total)),
      #("failed", json.Int(failed)),
      #("cancelled", json.Int(0)),
      #("unsettled", json.Int(unsettled)),
      #("items", json.Array(items)),
    ]),
  )
}

fn completed_with(items: List(json.JsonValue)) -> ProgramCard {
  let total = list.length(items)
  let assert Some(card) =
    program_card.read(
      running_call(),
      result(False, [
        #("status", json.String("completed")),
        #("value", json.Object([#("files", json.Array([json.Int(1)]))])),
        record(items, total, 0, 0, 100),
      ]),
      OpeningOnly,
    )
    as "a foreground program has a card"
  card
}

fn failed_with(
  status: String,
  extra: List(#(String, json.JsonValue)),
) -> ProgramCard {
  let assert Some(card) =
    program_card.read(
      running_call(),
      result(True, [#("status", json.String(status)), ..extra]),
      OpeningOnly,
    )
    as "a failed foreground program has a card"
  card
}

pub fn a_program_with_no_result_is_running_with_its_opening_test() {
  let assert Some(card) = program_card.read(running_call(), None, OpeningOnly)
    as "a running program has a card"
  assert card.state == Running
  assert card.outcome == "Running a program"
  assert card.budget_ms == Some(30_000)
  assert card.calls == None
  assert card.chips == []

  // Blank lines are skipped and each shown line keeps its own number.
  assert card.program.lines == 7
  assert list.map(card.program.opening, fn(line) { line.number })
    == [1, 3, 4, 5]
  assert program_card.opening(card).card == Expanded
}

pub fn the_whole_program_is_kept_only_when_the_host_asks_for_it_test() {
  let assert Some(opening) =
    program_card.read(running_call(), None, OpeningOnly)
  assert opening.program.whole == None

  let assert Some(whole) =
    program_card.read(
      running_call(),
      None,
      Whole(cut: fn(text) { string.slice(text, 0, 10) }),
    )
  assert whole.program.whole == Some("import cap")
}

pub fn only_a_foreground_program_has_a_card_test() {
  let launched =
    call([#("program", json.String(program)), #("mode", json.String("launch"))])
  assert program_card.read(launched, None, OpeningOnly) == None

  let other = message.ToolCall("c1", "fs_read", json.Object([]), None, None)
  assert program_card.read(other, None, OpeningOnly) == None

  assert program_card.read(call([]), None, OpeningOnly) == None
}

pub fn a_completed_program_reads_as_what_it_did_test() {
  let card =
    completed_with([
      ok("fs.read", 1, 5),
      ok("fs.read", 7, 5),
      ok("git.status", 13, 20),
      ok("git.log", 34, 20),
      ok("git.diff", 55, 20),
      ok("git.current_branch", 76, 5),
    ])
  assert card.state == Completed
  assert card.outcome == "Read 2 files, ran 4 git commands"
  assert card.count_words == Some("6 calls")
  assert card.elapsed_ms == Some(100)

  // Reads and read-only git are not side effects, so nothing is chipped.
  assert card.chips == []
  assert program_card.opening(card).card == Collapsed
  assert program_card.opening(card).calls == Expanded
}

pub fn side_effects_are_chipped_by_family_test() {
  let card =
    completed_with([
      ok("fs.write", 0, 4),
      ok("fs.edit", 5, 4),
      ok("proc.run", 10, 30),
      ok("job.start", 41, 3),
      ok("git.commit", 45, 9),
      ok("net.fetch", 55, 40),
    ])
  assert card.outcome
    == "Ran 1 git command, wrote 2 files, ran 2 commands, made 1 network request"
  assert list.map(card.chips, program_card.chip_words)
    == ["wrote 2", "ran 3 commands", "network 1"]
}

pub fn a_capability_the_table_does_not_name_is_an_other_call_test() {
  let card = completed_with([ok("peer.send", 0, 2), ok("mystery.thing", 3, 2)])
  assert card.outcome == "2 other calls"
  assert card.chips == []
}

pub fn every_capability_has_one_family_in_the_closed_table_test() {
  // A capability each family claims, in the sentence's fixed order.
  let card =
    completed_with([
      ok("fs.read", 0, 1),
      ok("fs.list", 1, 1),
      ok("search.grep", 2, 1),
      ok("lsp.references", 3, 1),
      ok("lsp_sql.query", 4, 1),
      ok("git.add", 5, 1),
      ok("lsp.rename", 6, 1),
      ok("job.kill", 7, 1),
      ok("net.request", 8, 1),
      ok("kv.set", 9, 1),
    ])
  assert card.outcome
    == "Read 1 file, searched 2 times, looked up code 2 times, ran 1 git command, wrote 1 file, ran 1 command, made 1 network request, 1 other call"
}

pub fn a_failed_call_is_not_counted_as_having_done_its_work_test() {
  let items = [
    ok("fs.read", 0, 1),
    item("fs.write", None, "failed", Some("permission_denied"), 2, 1),
  ]
  let assert Some(card) =
    program_card.read(
      running_call(),
      result(False, [
        #("status", json.String("completed")),
        #("value", json.Null),
        record(items, 2, 1, 0, 10),
      ]),
      OpeningOnly,
    )
  assert card.outcome == "Read 1 file, 1 failed"
  assert list.map(card.chips, program_card.chip_words) == ["failed 1"]
  assert card.count_words == Some("2 calls · 1 failed")

  // A failed call opens the card on its calls.
  assert program_card.opening(card)
    == Opening(
      card: Expanded,
      program: Collapsed,
      calls: Expanded,
      result: Collapsed,
    )
}

pub fn a_result_with_no_call_record_has_a_sentence_and_no_calls_test() {
  let assert Some(card) =
    program_card.read(
      running_call(),
      result(False, [
        #("status", json.String("completed")),
        #("value", json.String("done")),
      ]),
      OpeningOnly,
    )
  assert card.outcome == "Completed"
  assert card.calls == None
  assert card.count_words == None
  assert card.elapsed_ms == None
}

pub fn a_program_that_made_no_calls_says_so_test() {
  let card = completed_with([])
  assert card.outcome == "Ran with no calls"
}

pub fn calls_the_host_counted_and_did_not_itemise_are_said_test() {
  let assert Some(card) =
    program_card.read(
      running_call(),
      result(False, [
        #("status", json.String("completed")),
        #("value", json.Null),
        record([ok("fs.read", 0, 1)], 5, 0, 0, 10),
      ]),
      OpeningOnly,
    )
  assert card.outcome == "Read 1 file, 4 other calls"
  let assert Some(table) = card.calls
  assert table.unlisted == 4
}

pub fn consecutive_calls_to_one_capability_are_one_row_test() {
  let card =
    completed_with([
      item("proc.run", Some("git +1 args"), "ok", None, 0, 10),
      item("proc.run", Some("git +2 args"), "ok", None, 10, 10),
      ok("fs.read", 20, 5),
      ok("proc.run", 30, 5),
    ])
  let assert Some(table) = card.calls
  assert list.map(table.rows, fn(row) { #(row.cap, row.count) })
    == [#("proc.run", 2), #("fs.read", 1), #("proc.run", 1)]
  let assert [first, ..] = table.rows
  assert first.args == "git +1 args · git +2 args"
  assert first.duration_ms == 20
  assert list.length(first.members) == 2
}

pub fn a_run_of_calls_that_ended_differently_is_two_rows_test() {
  let card =
    completed_with([
      ok("proc.run", 0, 10),
      item("proc.run", None, "failed", Some("exit_status"), 10, 10),
    ])
  let assert Some(table) = card.calls
  assert list.map(table.rows, fn(row) { row.error })
    == [None, Some("exit status")]
}

pub fn calls_are_placed_on_the_programs_own_time_axis_test() {
  let card = completed_with([ok("fs.read", 0, 25), ok("proc.run", 50, 50)])
  let assert Some(table) = card.calls
  assert table.axis_ms == 100
  assert list.map(table.rows, fn(row) { row.bar }) == [Bar(0, 25), Bar(50, 50)]
}

pub fn a_zero_duration_call_is_still_a_mark_test() {
  assert program_card.bar(1000, 500, 500, call_tree.Settled) == Bar(50, 1)
}

pub fn an_axis_of_zero_does_not_divide_by_zero_test() {
  assert program_card.bar(0, 0, 0, call_tree.Settled) == Bar(0, 1)
  assert program_card.bar(-5, 3, 9, call_tree.Settled) == Bar(99, 1)
}

pub fn a_call_at_the_very_end_stays_inside_the_track_test() {
  assert program_card.bar(100, 100, 100, call_tree.Settled) == Bar(99, 1)
  assert program_card.bar(100, 90, 400, call_tree.Settled) == Bar(90, 10)
}

pub fn an_unsettled_call_runs_to_the_end_of_the_axis_test() {
  assert program_card.bar(100, 40, 40, call_tree.Unsettled) == Bar(40, 60)
}

pub fn every_bar_stays_inside_its_track_test() {
  // A deterministic walk over starts, ends and axes, including values the
  // record would refuse and ones far past the axis.
  let samples =
    list.repeat(Nil, 600)
    |> list.index_map(fn(_, n) {
      let a = scramble(n)
      let b = scramble(a)
      let c = scramble(b)
      #(a % 5000 - 100, b % 5000 - 100, c % 7000 - 100)
    })
  list.each(samples, fn(sample) {
    let #(axis, start, end) = sample
    list.each(
      [
        call_tree.Settled,
        call_tree.Failed,
        call_tree.Cancelled,
        call_tree.Unsettled,
      ],
      fn(status) {
        let bar = program_card.bar(axis, start, end, status)
        assert bar.offset >= 0 && bar.offset <= 99
        assert bar.width >= 1
        assert bar.offset + bar.width <= 100
      },
    )
  })
}

pub fn the_bars_of_any_record_stay_inside_their_track_test() {
  let cards =
    list.repeat(Nil, 120)
    |> list.index_map(fn(_, n) {
      let count = scramble(n) % 9
      let items =
        list.repeat(Nil, count)
        |> list.index_map(fn(_, index) {
          let seed = scramble(n * 31 + index)
          item(
            "fs.read",
            None,
            case seed % 4 {
              0 -> "failed"
              1 -> "unsettled"
              _ -> "ok"
            },
            None,
            seed % 300,
            scramble(seed) % 400,
          )
        })
      let elapsed = scramble(n + 7) % 250
      let assert Some(card) =
        program_card.read(
          running_call(),
          result(False, [
            #("status", json.String("completed")),
            #("value", json.Null),
            record(items, count, 0, 0, elapsed),
          ]),
          OpeningOnly,
        )
      card
    })
  list.each(cards, fn(card) {
    let assert Some(table) = card.calls
    assert table.axis_ms >= 1
    list.each(table.rows, fn(row) {
      assert row.bar.offset >= 0 && row.bar.offset <= 99
      assert row.bar.width >= 1
      assert row.bar.offset + row.bar.width <= 100
    })
  })
}

// A cheap deterministic mixer, so the walks above need no generator.
fn scramble(n: Int) -> Int {
  { n * 1_103_515_245 + 12_345 } % 2_147_483_648
}

pub fn a_program_that_failed_a_call_says_how_many_of_how_many_test() {
  let items = [
    ok("fs.read", 0, 3),
    item(
      "proc.run",
      Some("make +1 args"),
      "failed",
      Some("exit_status"),
      3,
      400,
    ),
    ok("fs.read", 410, 1),
    ok("fs.read", 420, 1),
  ]
  let card =
    failed_with("program_failed", [
      #("message", json.String("make check exited with status 2")),
      record(items, 4, 1, 0, 500),
    ])
  assert card.state == ProgramFailed
  assert card.outcome == "Failed: 1 of 4 calls"
  assert card.status_word == "program failed"
  let assert Some(failure) = card.failure
  assert failure.text == "make check exited with status 2"
  assert failure.foot == "the program reported a failure"
  assert program_card.opening(card).calls == Expanded
  assert program_card.opening(card).program == Collapsed
}

pub fn a_deadline_stop_draws_the_unsettled_call_to_the_end_test() {
  let items = [
    ok("fs.read", 0, 3),
    item("proc.run", None, "unsettled", None, 10, 0),
  ]
  let assert Some(card) =
    program_card.read(
      call([
        #("program", json.String(program)),
        #("within_ms", json.Int(300_000)),
      ]),
      result(True, [
        #("status", json.String("run_failed")),
        record(items, 2, 0, 1, 1000),
      ]),
      OpeningOnly,
    )
  assert card.state == RunFailed
  assert card.outcome == "Stopped before it finished, 1 call not settled"
  let assert Some(failure) = card.failure
  assert failure.foot == "the program was stopped · budget 5m"
  let assert Some(table) = card.calls
  let assert [_, hatched] = table.rows
  assert hatched.status == call_tree.Unsettled
  assert hatched.bar == Bar(1, 99)
}

pub fn a_program_vetting_refused_never_ran_test() {
  let card = failed_with("vetting_rejected", [])
  assert card.state == Rejected
  assert card.outcome == "Refused by vetting"
  assert card.status_word == "refused by vetting"
  assert card.calls == None
}

const diagnostic =
  "error: Unknown variable\n  ┌─ program.gleam:5:12\n  │\n5 │   let x = fs.raed(\"a.md\")\n  │              ^^^^^^^ Did you mean `read`?\n\nThe name `raed` is not defined here."

pub fn a_compile_error_is_read_into_its_line_and_source_test() {
  let card =
    failed_with("compile_failed", [#("detail", json.String(diagnostic))])
  assert card.state == CompileFailed
  assert card.outcome == "Compile error, line 5"
  assert card.program.failing_line == Some(5)
  assert program_card.opening(card).card == Expanded

  let assert Some(failure) = card.failure
  assert failure.foot == "the program did not run"
  assert failure.lines == 7
  let assert Some(found) = failure.diagnostic
  assert found.heading == "error: Unknown variable"
  assert found.path == "program.gleam"
  assert found.line == 5
  assert found.column == 12
  assert found.rows
    == [
      program_card.Quoted(5, "  let x = fs.raed(\"a.md\")"),
      program_card.Pointer("             ^^^^^^^ Did you mean `read`?"),
      program_card.Note("The name `raed` is not defined here."),
    ]
}

pub fn a_diagnostic_that_cannot_be_read_degrades_to_its_text_test() {
  let card =
    failed_with("compile_failed", [
      #("detail", json.String("something went wrong\nand then more")),
    ])
  assert card.outcome == "Compile error"
  assert card.program.failing_line == None
  let assert Some(failure) = card.failure
  assert failure.diagnostic == None
  assert failure.text == "something went wrong\nand then more"
}

pub fn a_place_without_quoted_source_is_not_a_diagnostic_test() {
  let card =
    failed_with("compile_failed", [
      #("detail", json.String("error: odd\n  ┌─ a.gleam:2:3\n  │\n")),
    ])
  let assert Some(failure) = card.failure
  assert failure.diagnostic == None
}

pub fn a_place_with_no_numbers_is_not_a_diagnostic_test() {
  let card =
    failed_with("compile_failed", [
      #("detail", json.String("error: odd\n  ┌─ a.gleam:x:y\n1 │ code")),
    ])
  let assert Some(failure) = card.failure
  assert failure.diagnostic == None
}

pub fn the_result_text_stands_in_for_a_missing_detail_test() {
  let card = failed_with("compile_failed", [])
  let assert Some(failure) = card.failure
  assert failure.text == "the text"
}

pub fn a_value_is_its_kind_and_a_hint_per_key_test() {
  let card = completed_with([ok("fs.read", 0, 1)])
  let assert Some(value) = card.value
  assert value.kind == "object · 1 key"
  assert value.hints == ["files: list(1)"]
  assert value.whole == None
}

pub fn a_hostile_string_stays_a_string_test() {
  let hostile = "</span><script>alert(1)</script>"
  let card = completed_with([item("fs.read", Some(hostile), "ok", None, 0, 1)])
  let assert Some(table) = card.calls
  let assert [row] = table.rows
  assert row.args == hostile
  assert int.to_string(row.count) == "1"
}
