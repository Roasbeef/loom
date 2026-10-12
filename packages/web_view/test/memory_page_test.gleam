//// The owner's overview of the daemon's memory, on an operator's page
//// (protocol-change/087).
////
//// The Session pane shows four counts, what each run receives, the newest
//// notes and the approved rules, read-only. The page is the owner's alone: a
//// member's page and an observer's draw nothing there, read nothing and send
//// nothing. What a page sends is read from the transport, with every effect
//// performed (`page_fixture.run`), as `proposals_page_test` does.

import core/json
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import lustre/element.{type Element}
import page_fixture
import session_view/connection_event
import session_view/memory_overview as words
import web_view/component
import web_view/operator_page

@external(erlang, "page_events_ffi", "handlers")
fn every_handler(view: Element(message)) -> List(String)

fn file(name: String, state: String, bytes: Int) -> json.JsonValue {
  json.Object([
    #("file", json.String(name)),
    #("state", json.String(state)),
    #("bytes", json.Int(bytes)),
  ])
}

fn note(title: String, legacy: Bool) -> json.JsonValue {
  json.Object([
    #("kind", json.String("fact")),
    #("date", json.String("2026-10-11")),
    #("title", json.String(title)),
    #("description", json.String("one line")),
    #("legacy", json.Bool(legacy)),
  ])
}

fn rule(id: String, line: String) -> json.JsonValue {
  json.Object([
    #("id", json.String(id)),
    #("approved", json.String("2026-10-09")),
    #("session", json.String("0198c0de-0000-7000-8000-000000000001")),
    #("line", json.String(line)),
  ])
}

fn ok(total: Int, omitted: Int, rows: List(json.JsonValue)) -> json.JsonValue {
  json.Object([
    #("state", json.String("ok")),
    #("total", json.Int(total)),
    #("omitted", json.Int(omitted)),
    #("rows", json.Array(rows)),
  ])
}

fn board(
  notes: json.JsonValue,
  rules: json.JsonValue,
  pending: Int,
) -> json.JsonValue {
  json.Object([
    #("inject", json.String("notes")),
    #(
      "receives",
      json.Array([
        file("loom-rules.md", "injected", 900),
        file("loom-memory.notes", "injected", 112),
      ]),
    ),
    #("notes", notes),
    #("rules", rules),
    #(
      "proposals",
      json.Object([
        #("state", json.String("ok")),
        #("pending", json.Int(pending)),
      ]),
    ),
  ])
}

fn empty() -> json.JsonValue {
  board(ok(0, 0, []), ok(0, 0, []), 0)
}

fn one() -> json.JsonValue {
  board(
    ok(1, 0, [note("Use tabs", False)]),
    ok(1, 0, [rule("prop-0000000001", "Run make check.")]),
    1,
  )
}

fn many() -> json.JsonValue {
  board(
    ok(60, 10, list.repeat(note("Prefer small commits", False), 50)),
    ok(2, 0, [
      rule("prop-0000000002", "Never touch vendor/."),
      rule("prop-0000000001", "Run make check."),
    ]),
    3,
  )
}

// The reply the daemon gives to a `memory_get`.
fn answer(request: Int, board: json.JsonValue) -> connection_event.Message {
  connection_event.Incoming(
    "{\"v\":2,\"reply_to\":"
    <> int.to_string(request)
    <> ",\"event\":\"snapshot\",\"body\":{\"mode\":\"memory\",\"board\":"
    <> json.to_string(board)
    <> "}}",
  )
}

fn refusal(id: Int, code: String) -> connection_event.Message {
  connection_event.Incoming(
    "{\"v\":2,\"reply_to\":"
    <> int.to_string(id)
    <> ",\"event\":\"error\",\"body\":{\"code\":\""
    <> code
    <> "\",\"message\":\"nope\"}}",
  )
}

fn owner_start() -> component.Start(page_fixture.Wire) {
  let start = page_fixture.start()
  component.Start(
    ..start,
    standing: component.Standing(
      ..start.standing,
      reader: component.DaemonOwner,
    ),
  )
}

// What the daemon answers a `memory_get` with: the board, or a refusal with
// the code it carries.
type Reply {
  Listed(json.JsonValue)
  Refused(code: String)
}

fn page_of(start: component.Start(page_fixture.Wire), listed: Reply) {
  let wire = process.new_subject()
  let model =
    page_fixture.run(
      component.new(start),
      operator_page.update,
      list.flatten([
        [operator_page.Observed(component.Opened(wire))],
        list.map(page_fixture.transfer("operator", []), fn(frame) {
          operator_page.Observed(component.Arrived([frame]))
        }),
        [operator_page.Observed(component.Ticked)],
      ]),
    )
    |> answering(wire, listed, 8)
  let _ = page_fixture.sent(wire)
  #(model, wire)
}

fn owner(listed: Reply) {
  page_of(owner_start(), listed)
}

fn answering(model, wire, listed: Reply, rounds: Int) {
  let reads =
    list.filter(page_fixture.sent(wire), fn(frame) {
      !string.contains(frame, "\"cmd\":\"snapshot")
      && !string.contains(frame, "\"cmd\":\"subscribe\"")
    })
  case reads, rounds {
    [], _ | _, 0 -> model
    _, _ -> {
      page_fixture.run(model, operator_page.update, [
        operator_page.Observed(
          component.Arrived(
            list.map(reads, fn(frame) {
              let id = page_fixture.request_id(frame)
              case string.contains(frame, "\"cmd\":\"memory_get\""), listed {
                True, Listed(board) -> answer(id, board)
                True, Refused(code) -> refusal(id, code)
                False, _ -> page_fixture.refusal(id)
              }
            }),
          ),
        ),
      ])
      |> answering(wire, listed, rounds - 1)
    }
  }
}

fn drawn(model) -> String {
  element.to_string(operator_page.view(model))
}

// --- the section --------------------------------------------------------------

pub fn a_page_that_has_read_nothing_says_it_is_reading_test() {
  let html = drawn(component.new(owner_start()))
  assert string.contains(html, "Memory")
  assert string.contains(html, words.loading_words)
}

pub fn an_empty_board_says_so_in_each_section_test() {
  let #(model, _) = owner(Listed(empty()))
  let html = drawn(model)
  assert string.contains(
    html,
    "No notes yet. The agent writes one when it learns something worth keeping.",
  )
  assert string.contains(html, "No approved rules.")
  assert string.contains(html, "What each run receives")
  assert !string.contains(html, words.loading_words)
}

pub fn one_note_and_one_rule_show_their_facts_test() {
  let #(model, _) = owner(Listed(one()))
  let html = drawn(model)
  assert string.contains(html, "fact · 2026-10-11")
  assert string.contains(html, "Use tabs: one line")
  assert string.contains(
    html,
    "prop-0000000001 · approved 2026-10-09 · session 0198c0de",
  )
  assert string.contains(html, "Run make check.")
  assert string.contains(html, "[memory] inject = notes")
  assert string.contains(html, "loom-rules.md (approved rules) · 900 B")
  assert string.contains(html, "history_search kind=note")
  assert string.contains(
    html,
    "1 proposal pending. Review it with the Proposals section above.",
  )
  assert string.contains(html, "loom-memory.notes (the notes index)")
}

pub fn the_four_counts_are_drawn_as_tiles_test() {
  let #(model, _) = owner(Listed(one()))
  let html = drawn(model)
  assert string.contains(html, "memory-tiles")
  assert string.contains(html, "approved rules")
  assert string.contains(html, "pending proposals")
  assert string.contains(html, "1012 B")
}

pub fn many_rows_keep_their_order_and_the_omitted_count_shows_test() {
  let #(model, _) = owner(Listed(many()))
  let html = drawn(model)
  let rows = string.split(html, "Prefer small commits")
  assert list.length(rows) == 51
  assert string.contains(
    html,
    "+10 more not shown; history_search kind=note finds them",
  )
  let newest = string.split(html, "prop-0000000002")
  let older = string.split(html, "prop-0000000001")
  assert list.length(newest) == 2
  assert list.length(older) == 2
}

pub fn a_legacy_note_is_marked_and_a_typed_one_is_not_test() {
  let #(model, _) =
    owner(
      Listed(board(
        ok(2, 0, [note("old words", True), note("new words", False)]),
        ok(0, 0, []),
        0,
      )),
    )
  let html = drawn(model)
  assert string.contains(html, "fact · 2026-10-11 · legacy")
  assert list.length(string.split(html, "· legacy")) == 2
}

pub fn a_section_that_could_not_be_read_is_not_drawn_as_empty_test() {
  let broken =
    json.Object([
      #("state", json.String("unavailable")),
      #("reason", json.String("the store is damaged")),
    ])
  let #(model, _) = owner(Listed(board(broken, ok(0, 0, []), 0)))
  let html = drawn(model)
  assert string.contains(html, "Notes unavailable: the store is damaged")
  assert !string.contains(html, "No notes yet")
}

pub fn the_page_has_no_accent_bar_and_no_shadow_test() {
  let #(model, _) = owner(Listed(many()))
  let html = drawn(model)
  assert !string.contains(html, "box-shadow")
  assert !string.contains(html, "border-left")
}

pub fn hostile_text_is_only_ever_text_test() {
  let hostile = "<script>alert(1)</script>\" onclick=\"x"
  let #(model, _) =
    owner(Listed(board(ok(1, 0, [note(hostile, False)]), ok(0, 0, []), 0)))
  let html = drawn(model)
  assert !string.contains(html, "<script>alert")
  assert string.contains(html, "&lt;script&gt;")
  assert !string.contains(html, "\" onclick=\"")
}

// --- errors ---------------------------------------------------------------------

pub fn a_refused_read_is_worded_and_replaces_the_loading_words_test() {
  let #(model, _) = owner(Refused("unsupported"))
  let html = drawn(model)
  assert string.contains(html, "This daemon keeps no memory overview.")
  assert !string.contains(html, words.loading_words)
  assert component.memory_kept(model) == None
}

pub fn a_forbidden_read_says_only_the_owner_may_read_test() {
  let #(model, _) = owner(Refused("forbidden"))
  assert string.contains(
    drawn(model),
    "Only the daemon&#39;s owner can read the memory overview.",
  )
}

// --- who sees it ----------------------------------------------------------------

pub fn a_members_page_draws_no_section_reads_nothing_and_sends_nothing_test() {
  let #(model, wire) = page_of(page_fixture.start(), Listed(one()))
  let html = drawn(model)
  assert !string.contains(html, "What each run receives")
  assert !string.contains(html, "Use tabs")
  assert component.memory_kept(model) == None
  assert list.all(page_fixture.sent(wire), fn(frame) {
    !string.contains(frame, "memory_get")
  })
}

pub fn an_observers_page_draws_no_section_test() {
  let model = component.new(page_fixture.start())
  let html = element.to_string(component.view(model))
  assert !string.contains(html, "What each run receives")
}

pub fn an_owners_page_reads_the_overview_once_test() {
  let #(model, wire) = owner(Listed(one()))
  let asked =
    list.filter(page_fixture.sent(wire), fn(frame) {
      string.contains(frame, "memory_get")
    })
  assert list.length(asked) <= 1
  assert component.memory_kept(model) != None
}

// --- where the handlers are --------------------------------------------------------

pub fn the_section_is_the_ninth_child_and_has_no_handler_test() {
  let #(model, _) = owner(Listed(many()))
  let keys = every_handler(operator_page.view(model))
  assert list.filter(keys, fn(key) { string.starts_with(key, "0\t3\t2\t8") })
    == []

  // The paths that already existed keep their places.
  assert component.proposals_path == "0\t3\t2\t7"
  assert component.peers_path == "0\t3\t2\t6"
  assert component.remembered_path == "0\t3\t2\t5"
  assert component.invite_path == "0\t3\t2\t2"
}
