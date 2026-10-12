//// A program card as the page draws it, in each state a program is in.
////
//// The tests read the HTML `view/program_card` draws from a card built by hand
//// and assert its structure: which parts are open before the reader touches
//// anything, which rows are tinted, which chips appear, and that no session
//// text becomes anything but text. What the card says is
//// `session_view/program_card`'s to test, and what the browser does with a
//// `<details>` is the browser's.

import core/json
import core/message
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/element
import session_view/program_card.{type ProgramCard, OpeningOnly, Whole}
import web_view/view/program_card as card_view

const program =
  "import cap/fs\n\npub fn main() {\n  let a = fs.read(\"a\")\n  let b = fs.read(\"b\")\n  Ok(a <> b)\n}\n"

fn call() -> message.ToolCall {
  message.ToolCall(
    "c1",
    "code_mode",
    json.Object([
      #("program", json.String(program)),
      #("within_ms", json.Int(30_000)),
    ]),
    None,
    None,
  )
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

fn record(
  items: List(json.JsonValue),
  failed: Int,
  unsettled: Int,
  elapsed_ms: Int,
) -> #(String, json.JsonValue) {
  #(
    "calls",
    json.Object([
      #("started_unix_ms", json.Int(1)),
      #("elapsed_ms", json.Int(elapsed_ms)),
      #("total", json.Int(list.length(items))),
      #("failed", json.Int(failed)),
      #("cancelled", json.Int(0)),
      #("unsettled", json.Int(unsettled)),
      #("items", json.Array(items)),
    ]),
  )
}

fn card_of(
  outcome: Option(message.AgentMessage),
  source: program_card.Source,
) -> ProgramCard {
  let assert Some(card) = program_card.read(call(), outcome, source)
    as "a foreground program has a card"
  card
}

fn whole() -> program_card.Source {
  Whole(cut: fn(text) { text })
}

fn drawn(card: ProgramCard, since: Option(Int)) -> String {
  card_view.view(card, since)
  |> element.to_string
  |> string.replace("<!-- lustre:memo -->", "")
}

fn count(haystack: String, needle: String) -> Int {
  list.length(string.split(haystack, needle)) - 1
}

fn completed(items: List(json.JsonValue), failed: Int) -> ProgramCard {
  card_of(
    result(False, [
      #("status", json.String("completed")),
      #("value", json.Object([#("files", json.Array([json.Int(1)]))])),
      record(items, failed, 0, 100),
    ]),
    whole(),
  )
}

pub fn a_settled_program_with_nothing_wrong_is_one_closed_line_test() {
  let html =
    drawn(
      completed(
        [
          item("fs.read", Some("docs/next.md"), "ok", None, 0, 5),
          item("fs.read", Some("docs/execution.md"), "ok", None, 6, 5),
          item("git.status", None, "ok", None, 12, 20),
        ],
        0,
      ),
      None,
    )

  // The card is closed: no `open` on it, and the line says what happened.
  assert string.contains(html, "<details class=\"pc pc-ok\">")
  assert string.contains(
    html,
    "<span class=\"pc-outcome\">Read 2 files, ran 1 git command</span>",
  )
  assert string.contains(html, "<span class=\"pc-meta\">3 calls</span>")
  assert string.contains(html, "<span class=\"sr-only\">completed</span>")

  // Nothing here changes the world, so no chip.
  assert !string.contains(html, "pc-chip")

  // The sections are there for when it is opened, with the calls grouped.
  assert string.contains(html, "pc-program")
  assert string.contains(html, "pc-calls")
  assert string.contains(html, "pc-result")
  assert string.contains(html, "fs.read ×2")
  assert string.contains(html, "docs/next.md · docs/execution.md")
  assert string.contains(html, "ran for 100ms")
}

pub fn side_effects_are_chipped_in_the_line_test() {
  let html =
    drawn(
      completed(
        [
          item("fs.write", Some("out.md"), "ok", None, 0, 4),
          item("proc.run", Some("make +1 args"), "ok", None, 5, 4),
          item("net.fetch", None, "ok", None, 10, 4),
        ],
        0,
      ),
      None,
    )
  assert string.contains(
    html,
    "<span class=\"pc-chip pc-chip-wrote\">wrote 1</span>",
  )
  assert string.contains(
    html,
    "<span class=\"pc-chip pc-chip-ran\">ran 1 command</span>",
  )
  assert string.contains(
    html,
    "<span class=\"pc-chip pc-chip-network\">network 1</span>",
  )
}

pub fn the_first_lines_show_and_the_rest_wait_behind_a_control_test() {
  let html = drawn(completed([], 0), None)
  assert string.contains(html, "7 lines, 4 shown")
  assert string.contains(html, "Show all 7 lines")

  // The control holds the whole program, so its last line is on the page.
  assert string.contains(html, "<span class=\"pc-n\">7</span>")
}

pub fn a_host_that_kept_no_whole_program_offers_no_control_test() {
  let card =
    card_of(
      result(False, [
        #("status", json.String("completed")),
        #("value", json.Null),
      ]),
      OpeningOnly,
    )
  let html = drawn(card, None)
  assert string.contains(html, "7 lines, 4 shown")
  assert !string.contains(html, "Show all")
}

pub fn a_failed_call_opens_the_card_on_a_tinted_row_test() {
  let html =
    drawn(
      completed(
        [
          item("fs.read", None, "ok", None, 0, 3),
          item(
            "proc.run",
            Some("make +1 args"),
            "failed",
            Some("exit_status"),
            3,
            4100,
          ),
        ],
        1,
      ),
      None,
    )

  // Open at the card and at the calls, shut at the program.
  assert string.contains(html, "<details class=\"pc pc-ok\" open>")
  assert string.contains(html, "<details class=\"pc-sec pc-calls\" open>")
  assert string.contains(html, "<details class=\"pc-sec pc-program\">")
  assert string.contains(
    html,
    "<span class=\"pc-chip pc-chip-failed\">failed 1</span>",
  )
  assert string.contains(html, "<details class=\"pc-call pc-call-failed\">")
  assert string.contains(html, "failed · exit status · 4.1s")
  assert string.contains(html, "error code: exit status")
  assert count(html, "pc-call-failed") == 1
}

pub fn a_row_opens_to_the_calls_of_its_run_test() {
  let html =
    drawn(
      completed(
        [
          item("proc.run", Some("git +1 args"), "ok", None, 12, 31),
          item("proc.run", Some("git +2 args"), "ok", None, 44, 88),
        ],
        0,
      ),
      None,
    )
  assert string.contains(html, "proc.run ×2")
  assert string.contains(html, "1. ")
  assert string.contains(html, "git +2 args")
  assert string.contains(html, "start +12ms · 31ms")
  assert string.contains(html, "not its arguments or its result")
}

pub fn a_bar_is_two_bounded_percentages_test() {
  let html =
    drawn(completed([item("fs.read", None, "ok", None, 25, 50)], 0), None)

  // 25 to 75 of a 100 ms program.
  assert string.contains(html, "style=\"left:25%;width:50%;\"")
  assert string.contains(html, "pc-fill-ok")
}

pub fn a_call_the_deadline_cut_off_is_drawn_hatched_test() {
  let card =
    card_of(
      result(True, [
        #("status", json.String("run_failed")),
        record(
          [
            item("fs.read", None, "ok", None, 0, 3),
            item("proc.run", None, "unsettled", None, 10, 0),
          ],
          0,
          1,
          1000,
        ),
      ]),
      whole(),
    )
  let html = drawn(card, None)
  assert string.contains(html, "pc-fill-open")
  assert string.contains(html, "not settled")
  assert string.contains(html, "<details class=\"pc pc-bad\" open>")
  assert string.contains(html, "the program was stopped · budget 30s")
}

pub fn a_running_program_shows_its_opening_and_the_browsers_clock_test() {
  let html = drawn(card_of(None, whole()), Some(1_790_000_000_000))
  assert string.contains(html, "<details class=\"pc pc-run\" open>")
  assert string.contains(
    html,
    "<loom-elapsed since=\"1790000000000\"></loom-elapsed>",
  )
  assert string.contains(html, "<details class=\"pc-sec pc-program\" open>")

  // No call record yet, so no calls and no result section, only the note.
  assert !string.contains(html, "pc-calls")
  assert !string.contains(html, "pc-result")
  assert string.contains(html, "arrive when it ends")
  assert string.contains(html, "budget 30s")
}

pub fn a_running_program_with_no_record_time_draws_no_clock_test() {
  let html = drawn(card_of(None, whole()), None)
  assert !string.contains(html, "loom-elapsed")
}

const diagnostic =
  "error: Unknown variable\n  ┌─ program.gleam:5:12\n  │\n5 │   let x = fs.raed(\"a.md\")\n  │              ^^^^^^^ Did you mean `read`?\n\nThe name `raed` is not defined here."

pub fn a_compile_error_marks_its_line_and_its_caret_test() {
  let card =
    card_of(
      result(True, [
        #("status", json.String("compile_failed")),
        #("detail", json.String(diagnostic)),
      ]),
      whole(),
    )
  let html = drawn(card, None)
  assert string.contains(html, "<details class=\"pc pc-bad\" open>")
  assert string.contains(
    html,
    "<span class=\"pc-outcome\">Compile error, line 5</span>",
  )
  assert string.contains(
    html,
    "<p class=\"pc-errh\">error: Unknown variable</p>",
  )
  assert string.contains(html, "program.gleam:5:12")

  // The failing line is marked in the report and in the program.
  assert string.contains(html, "<div class=\"pc-ln pc-hit\">")
  assert string.contains(html, "pc-caret")
  assert string.contains(html, "Did you mean `read`?")
  assert string.contains(html, "<details class=\"pc-sec pc-error\" open>")
  assert string.contains(html, "<details class=\"pc-sec pc-program\">")
  assert string.contains(html, "the program did not run")

  // Nothing ran, so there are no calls.
  assert !string.contains(html, "pc-calls")
}

pub fn a_diagnostic_that_cannot_be_read_is_drawn_as_it_came_test() {
  let card =
    card_of(
      result(True, [
        #("status", json.String("compile_failed")),
        #("detail", json.String("it broke\nin two lines")),
      ]),
      whole(),
    )
  let html = drawn(card, None)
  assert string.contains(
    html,
    "<pre class=\"pc-raw\">it broke\nin two lines</pre>",
  )
  assert !string.contains(html, "pc-hit")
  assert string.contains(
    html,
    "<span class=\"pc-outcome\">Compile error</span>",
  )
}

pub fn a_long_unreadable_error_keeps_its_rest_behind_a_control_test() {
  let card =
    card_of(
      result(True, [
        #("status", json.String("program_failed")),
        #("message", json.String("a\nb\nc\nd\ne\nf")),
      ]),
      whole(),
    )
  let html = drawn(card, None)
  assert string.contains(html, "Show all 6 lines")
}

pub fn session_text_is_only_ever_text_test() {
  let hostile = "</span><script>alert(1)</script>"
  let html =
    drawn(
      completed(
        [item(hostile, Some(hostile), "failed", Some(hostile), 0, 1)],
        1,
      ),
      None,
    )
  assert !string.contains(html, "<script>")
  assert string.contains(html, "&lt;/span&gt;&lt;script&gt;")
}

pub fn a_hostile_program_and_error_are_text_too_test() {
  let hostile = "</code><img src=x onerror=alert(1)>"
  let card =
    card_of(
      result(True, [
        #("status", json.String("program_failed")),
        #("message", json.String(hostile)),
      ]),
      whole(),
    )
  let html = drawn(card, None)
  assert !string.contains(html, "<img")
}
