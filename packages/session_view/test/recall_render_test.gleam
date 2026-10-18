//// A `history_search` call as the terminal and the web view draw it: the
//// step's words while it runs and once it has settled, the compact rows with
//// the hits listed, the expanded rows with all of them, and the plain
//// rendering a record that is not what the tool writes falls back to. A
//// `remember` call shares the file, since its words changed with its
//// arguments.

import core/clock
import core/ids
import core/json
import core/message
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import session_view/step_words.{Figure, Mono, Prose, Unnamed, Words}
import session_view/tool_activity
import session_view/transcript_line.{Line, ToolCall, ToolResult}
import session_view/transcript_lines

const session = "019a3c1e-5b7d-7c3e-9a10-2f4b6c8d0e1f"

fn entry(tail: String) -> String {
  "019a3c1e-aaaa-7bbb-8ccc-0123456789" <> tail
}

fn hit(tail: String, kind: String, snippet: String) -> json.JsonValue {
  json.Object([
    #("session", json.String(session)),
    #("entry", json.String(entry(tail))),
    #("kind", json.String(kind)),
    #("ts", json.Int(1_760_140_800_000)),
    #("snippet", json.String(snippet)),
  ])
}

fn three_hits() -> List(json.JsonValue) {
  [
    hit("a1", "assistant", "we deploy with make release"),
    hit("b2", "user", "how do I deploy this"),
    hit("c3", "note", "deploys go through the queue"),
  ]
}

fn details(hits: List(json.JsonValue)) -> json.JsonValue {
  json.Object([
    #("hits", json.Array(hits)),
    #("hit_count", json.Int(list.length(hits))),
    #("scope", json.String("repository")),
    #("limit", json.Int(10)),
  ])
}

fn settled(
  name: String,
  details: Option(json.JsonValue),
  is_error: Bool,
) -> Option(message.AgentMessage) {
  Some(message.ToolResultMessage(
    "c1",
    name,
    [message.ToolResultText("the tool's own prose", None)],
    details,
    None,
    None,
    is_error,
    0,
  ))
}

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
    None,
  )
}

fn search(
  hits: List(json.JsonValue),
  arguments: List(#(String, json.JsonValue)),
) -> tool_activity.Call {
  called(
    "history_search",
    arguments,
    settled("history_search", Some(details(hits)), False),
  )
}

// The words of a step.

pub fn a_running_search_names_its_query_test() {
  let words =
    step_words.pending(
      step_words.of_call(called(
        "history_search",
        [#("query", json.String("deploy"))],
        None,
      )),
    )
  assert step_words.text(words) == "Searching history for \"deploy\""
  assert step_words.is_present(words.verb)
}

pub fn a_settled_search_counts_its_hits_test() {
  let words =
    step_words.of_call(
      search(three_hits(), [#("query", json.String("deploy"))]),
    )
  assert words
    == Words("Searched history for", Prose("\"deploy\" · 3 hits"), None)
  assert !step_words.is_present(words.verb)
}

pub fn a_search_that_found_nothing_says_so_test() {
  assert step_words.text(
      step_words.of_call(search([], [#("query", json.String("zzz"))])),
    )
    == "Searched history for \"zzz\" · no hits"
  assert step_words.text(
      step_words.of_call(
        search([hit("a1", "user", "x")], [
          #("query", json.String("x")),
        ]),
      ),
    )
    == "Searched history for \"x\" · 1 hit"
}

pub fn a_failed_search_claims_no_count_test() {
  let failed =
    called(
      "history_search",
      [#("query", json.String("deploy"))],
      settled("history_search", Some(details(three_hits())), True),
    )
  assert step_words.text(step_words.of_call(failed))
    == "Searched history for \"deploy\""
  assert step_words.failure_sentence(step_words.of_call(failed), "no index")
    == "The search failed."
}

pub fn a_long_query_is_cut_in_the_words_test() {
  let words =
    step_words.of_call(called(
      "history_search",
      [#("query", json.String(string.repeat("word ", 40)))],
      None,
    ))
  let assert Prose(text) = words.subject as "a query is prose"
  assert string.ends_with(text, "…\"")
  assert string.length(text) <= 63
}

pub fn a_search_with_no_query_browses_test() {
  assert step_words.pending(
      step_words.of_call(called("history_search", [], None)),
    )
    == Words("Browsing history", Unnamed, None)
  assert step_words.of_call(search(three_hits(), []))
    == Words("Browsed history", Figure("3 hits"), None)
}

pub fn a_read_names_the_entry_it_fetched_test() {
  let call =
    called(
      "history_search",
      [
        #("action", json.String("read")),
        #("session", json.String(session)),
        #("entry", json.String(entry("a1"))),
      ],
      None,
    )
  assert step_words.of_call(call)
    == Words("Read history entry", Mono("019a3c1e 456789a1"), None)
  assert step_words.pending(step_words.of_call(call)).verb
    == "Reading history entry"
  assert step_words.of_call(called(
      "history_search",
      [#("action", json.String("read"))],
      None,
    ))
    == Words("Read history entry", Unnamed, None)
}

pub fn a_search_with_malformed_details_names_only_its_query_test() {
  let call =
    called(
      "history_search",
      [#("query", json.String("deploy"))],
      settled("history_search", Some(json.String("junk")), False),
    )
  assert step_words.text(step_words.of_call(call))
    == "Searched history for \"deploy\""
}

pub fn a_remembered_note_names_its_kind_and_title_test() {
  let call =
    called(
      "remember",
      [
        #("title", json.String("Prefer small diffs")),
        #("kind", json.String("feedback")),
        #("note", json.String("keep changes reviewable")),
      ],
      None,
    )
  assert step_words.text(step_words.of_call(call))
    == "Remembered feedback: Prefer small diffs"
  assert step_words.text(step_words.pending(step_words.of_call(call)))
    == "Remembering feedback: Prefer small diffs"
}

pub fn a_note_with_no_kind_names_its_title_alone_test() {
  assert step_words.text(
      step_words.of_call(called(
        "remember",
        [#("title", json.String("Release steps"))],
        None,
      )),
    )
    == "Remembered Release steps"
}

pub fn an_old_note_with_no_title_keeps_its_old_words_test() {
  let old =
    called("remember", [#("note", json.String("always run make"))], None)
  assert step_words.of_call(old)
    == Words("Remembered", Prose("a durable note"), None)
  assert step_words.of_call(called(
      "remember",
      [#("title", json.String("  "))],
      None,
    ))
    == Words("Remembered", Prose("a durable note"), None)
}

// The compact and the expanded rows.

pub fn the_summary_row_carries_the_query_and_filters_test() {
  let call =
    called(
      "history_search",
      [
        #("query", json.String("deploy")),
        #("kind", json.String("assistant")),
        #("before", json.String(entry("b2"))),
      ],
      None,
    )
  assert transcript_lines.call_summary(call)
    == "history_search · \"deploy\" · kind assistant · before 456789b2"
  assert transcript_lines.activity_call_lines(call)
    == [
      Line(
        ToolCall,
        "history_search · \"deploy\" · kind assistant · before 456789b2 · awaiting result",
      ),
    ]
}

pub fn a_settled_search_lists_its_hits_under_the_heading_test() {
  let call = search(three_hits(), [#("query", json.String("deploy"))])
  assert transcript_lines.activity_call_lines(call)
    == [
      Line(ToolCall, "✓ history_search · \"deploy\" · 3 hits"),
      Line(
        ToolResult,
        "019a3c1e · 456789a1 · assistant · 2025-10-11 · we deploy with make release\n"
          <> "019a3c1e · 456789b2 · user · 2025-10-11 · how do I deploy this\n"
          <> "019a3c1e · 456789c3 · note · 2025-10-11 · deploys go through the queue",
      ),
    ]
}

pub fn the_expanded_rows_hold_every_hit_test() {
  let hits =
    list.map(["a1", "b2", "c3", "d4", "e5"], fn(tail) {
      hit(tail, "user", tail)
    })
  let call = search(hits, [#("query", json.String("deploy"))])

  // Collapsed, three hits and the count of the rest; expanded, all five.
  let assert [_, compact] = transcript_lines.activity_call_lines(call)
    as "a heading and one row of hits"
  assert list.length(string.split(compact.text, "\n")) == 4
  assert string.ends_with(compact.text, "… 2 more · Ctrl+g shows all")
  let assert [expanded] = transcript_lines.expanded_call_lines(call)
    as "the heading and the hits are one result row"
  assert string.starts_with(expanded.text, "history_search · 5 hits\n")
  assert list.length(string.split(expanded.text, "\n")) == 6
  assert !string.contains(expanded.text, "more")
  assert expanded.speaker == ToolResult
}

pub fn a_zero_hit_search_says_no_hits_test() {
  let call = search([], [#("query", json.String("zzz"))])
  assert transcript_lines.activity_call_lines(call)
    == [Line(ToolCall, "✓ history_search · \"zzz\" · no hits")]
  assert transcript_lines.expanded_call_lines(call)
    == [Line(ToolResult, "history_search · no hits")]
}

pub fn malformed_details_fall_back_to_the_plain_rows_test() {
  let junk =
    called(
      "history_search",
      [#("query", json.String("deploy"))],
      settled("history_search", Some(json.String("junk")), False),
    )
  assert transcript_lines.activity_call_lines(junk)
    == [Line(ToolCall, "✓ history_search · \"deploy\"")]
  assert transcript_lines.expanded_call_lines(junk)
    == [Line(ToolResult, "history_search\nthe tool's own prose")]

  // A hit missing its entry spoils the record, and so does an absent one.
  let torn =
    search([json.Object([#("session", json.String(session))])], [
      #("query", json.String("deploy")),
    ])
  assert transcript_lines.activity_call_lines(torn)
    == [Line(ToolCall, "✓ history_search · \"deploy\"")]
  let bare =
    called(
      "history_search",
      [#("query", json.String("deploy"))],
      settled("history_search", None, False),
    )
  assert transcript_lines.activity_call_lines(bare)
    == [Line(ToolCall, "✓ history_search · \"deploy\"")]
}

pub fn a_read_keeps_the_plain_result_rows_test() {
  let call =
    called(
      "history_search",
      [
        #("action", json.String("read")),
        #("session", json.String(session)),
        #("entry", json.String(entry("a1"))),
        #("around", json.Int(1)),
      ],
      settled(
        "history_search",
        Some(json.Object([#("blob", json.String("ref"))])),
        False,
      ),
    )
  assert transcript_lines.activity_call_lines(call)
    == [
      Line(ToolCall, "✓ history_search · read 019a3c1e · 456789a1 · around 1"),
    ]
  assert transcript_lines.expanded_call_lines(call)
    == [Line(ToolResult, "history_search\nthe tool's own prose")]
}

pub fn a_failed_search_keeps_its_failure_rows_test() {
  let call =
    called(
      "history_search",
      [#("query", json.String("deploy"))],
      settled("history_search", None, True),
    )
  assert list.any(transcript_lines.activity_call_lines(call), fn(line) {
    line.speaker == transcript_line.ToolFailure
  })
}

pub fn a_summary_for_a_call_with_odd_arguments_is_the_generic_one_test() {
  assert transcript_lines.tool_call_summary(
      "history_search",
      json.Object([#("action", json.String("delete"))]),
      False,
    )
    == "history_search · {\"action\":\"delete\"}"
}

// The `remember` rows.

pub fn the_remember_summary_names_the_note_test() {
  assert transcript_lines.call_summary(called(
      "remember",
      [
        #("title", json.String("Prefer small diffs")),
        #("kind", json.String("feedback")),
        #("note", json.String("x")),
      ],
      None,
    ))
    == "remember · feedback: Prefer small diffs"
  assert transcript_lines.call_summary(called(
      "remember",
      [#("note", json.String("x"))],
      None,
    ))
    == "remember · durable note"
}
