//// The project board as a client reads it: the total decoders, the order a
//// person reads tickets in, and the words both hosts use.

import core/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import session_view/project_board as board

fn ticket(
  id: String,
  stage: String,
  opened: Int,
  title: String,
) -> json.JsonValue {
  json.Object([
    #("id", json.String(id)),
    #("title", json.String(title)),
    #("stage", json.String(stage)),
    #("session", json.Null),
    #("opened_ms", json.Int(opened)),
    #("question", json.Null),
  ])
}

fn body(tickets: List(json.JsonValue)) -> json.JsonValue {
  json.Object([
    #("project", json.String("p1")),
    #("revision", json.Int(9)),
    #("total", json.Int(list.length(tickets))),
    #("tickets", json.Array(tickets)),
  ])
}

// Tickets sent in no useful order, one of each kind a board can hold.
fn fixture() -> board.Board {
  let assert Ok(decoded) =
    body([
      ticket("t-working", "working", 100, "build the thing"),
      ticket("t-review", "person/review", 200, "review me"),
      ticket("t-old-answer", "person/answer", 300, "older question"),
      ticket("t-queued", "queued", 400, "waiting"),
      ticket("t-delivery", "person/delivery", 50, "lost input"),
      ticket("t-new-answer", "person/answer", 900, "newer question"),
      ticket("t-ended", "ended/merged", 10, "done"),
      ticket("t-failed", "person/failed", 20, "broke"),
      ticket("t-future", "person/triage", 30, "a stage from a newer daemon"),
      ticket("t-odd", "wild/stage", 40, "not a person stage"),
    ])
    |> board.decode_board
  decoded
}

fn ids(tickets: List(board.Ticket)) -> List(String) {
  list.map(tickets, fn(each) { each.id })
}

pub fn tickets_read_in_stage_order_with_the_newest_first_in_a_stage_test() {
  assert ids(board.ordered(fixture().tickets))
    == [
      "t-delivery",
      "t-new-answer",
      "t-old-answer",
      "t-review",
      "t-failed",
      "t-future",
      "t-queued",
      "t-working",
      "t-ended",
      "t-odd",
    ]
}

pub fn the_order_does_not_depend_on_the_order_the_daemon_sent_test() {
  let tickets = fixture().tickets
  assert ids(board.ordered(list.reverse(tickets)))
    == ids(board.ordered(tickets))
}

pub fn groups_carry_the_stage_word_and_whether_it_needs_a_person_test() {
  let groups = board.groups(board.ordered(fixture().tickets))
  assert list.map(groups, fn(each) { each.word })
    == [
      "delivery", "answer", "review", "failed", "person/triage", "queued",
      "working", "ended: merged", "wild/stage",
    ]
  let needing =
    list.filter(groups, fn(each) { each.needs == board.NeedsPerson })
  assert list.length(needing) == 5
}

pub fn a_stage_from_a_newer_daemon_is_kept_as_text_test() {
  assert board.parse_stage("person/triage")
    == board.UnknownStage("person/triage")
  assert board.stage_word(board.parse_stage("person/triage")) == "person/triage"
  assert board.attention(board.parse_stage("person/triage"))
    == board.NeedsPerson
  assert board.attention(board.parse_stage("wild/stage")) == board.NeedsNobody
  assert board.stage_word(board.parse_stage("")) == "unknown"
}

pub fn a_healthy_board_is_one_line_of_counts_test() {
  let assert Ok(healthy) =
    body([
      ticket("t-1", "working", 1, "a"),
      ticket("t-2", "working", 2, "b"),
      ticket("t-3", "queued", 3, "c"),
    ])
    |> board.decode_board
  assert board.health_words(healthy)
    == "Nothing needs you. 1 queued, 2 working."
  assert board.needing(healthy) == []
}

pub fn a_board_that_needs_people_says_how_many_test() {
  assert string.starts_with(
    board.health_words(fixture()),
    "6 tickets need you. ",
  )
}

pub fn a_page_that_is_not_the_whole_project_says_so_test() {
  let assert Ok(partial) =
    json.Object([
      #("project", json.String("p1")),
      #("revision", json.Int(1)),
      #("total", json.Int(37)),
      #("tickets", json.Array([ticket("t-1", "working", 1, "a")])),
    ])
    |> board.decode_board
  assert string.ends_with(
    board.health_words(partial),
    "Showing 1 of 37 tickets.",
  )
}

pub fn a_row_without_an_address_is_counted_and_left_out_test() {
  let assert Ok(decoded) =
    body([
      ticket("t-ok", "working", 1, "fine"),
      json.Object([
        #("title", json.String("no id")),
        #("stage", json.String("working")),
      ]),
      ticket("has space", "working", 1, "unaddressable"),
      json.String("not an object"),
    ])
    |> board.decode_board
  assert ids(decoded.tickets) == ["t-ok"]
  assert decoded.unreadable == 3
}

pub fn an_absent_field_is_unknown_and_not_zero_test() {
  let assert Ok(decoded) =
    body([
      json.Object([#("id", json.String("t-bare"))]),
    ])
    |> board.decode_board
  let assert [bare] = decoded.tickets
  assert bare.opened_ms == None
  assert bare.title == None
  assert board.title_words(bare) == "(untitled)"
  assert board.age_words(bare.opened_ms, 1_000_000_000) == "?"
  assert board.stage_word(bare.stage) == "unknown"
  assert bare.question == None
}

pub fn a_board_with_no_revision_is_an_error_not_revision_zero_test() {
  let missing =
    json.Object([
      #("project", json.String("p1")),
      #("tickets", json.Array([])),
    ])
  assert board.decode_board(missing) |> result.is_error
  assert board.decode_board(json.Null) |> result.is_error
}

pub fn a_hostile_title_is_inert_text_test() {
  let hostile =
    "<script>alert(1)</script>\u{1b}[31mred\u{1b}]0;owned\u{7}\r\nline two"
  let assert Ok(decoded) =
    body([ticket("t-evil", "person/answer", 1, hostile)])
    |> board.decode_board
  let assert [evil] = decoded.tickets
  let shown = board.title_words(evil)

  // The escape sequences and the control characters are gone, the line cannot
  // break, and the markup is still there as the characters it is.
  assert !string.contains(shown, "\u{1b}")
  assert !string.contains(shown, "\u{7}")
  assert !string.contains(shown, "\n")
  assert !string.contains(shown, "\r")
  assert string.contains(shown, "<script>alert(1)</script>")
}

pub fn age_is_the_largest_whole_unit_and_never_negative_test() {
  assert board.age_words(Some(0), 30_000) == "now"
  assert board.opened_words(Some(0), 30_000) == "opened just now"
  assert board.opened_words(Some(0), 5 * 60_000) == "opened 5m ago"
  assert board.opened_words(None, 5 * 60_000) == "opened at an unknown time"
  assert board.age_words(Some(0), 5 * 60_000) == "5m"
  assert board.age_words(Some(0), 3 * 3_600_000) == "3h"
  assert board.age_words(Some(0), 2 * 86_400_000) == "2d"
  assert board.age_words(Some(10_000_000), 0) == "now"
}

pub fn the_mandate_is_said_in_words_test() {
  let composer =
    board.Mandate("explicit", "composer", "composer", "owner", "v7")
  assert board.mandate_words(Some(composer))
    == "You asked for it in the composer. Policy v7."
  let overheard =
    board.Mandate("inferred", "overheard", "github", "mallory", "")
  assert board.mandate_words(Some(overheard))
    == "The router inferred it from a message by mallory on github that was not addressed to the project."
  let strange = board.Mandate("explicit", "telepathy", "x", "y", "v1")
  assert string.contains(board.mandate_words(Some(strange)), "telepathy")
  assert board.mandate_words(None)
    == "The daemon did not say why this ticket was allowed."
}

pub fn a_stale_answer_is_said_in_words_test() {
  assert string.contains(
    board.answer_refusal_words("conflict"),
    "The question changed while you were typing. Nothing was recorded",
  )
  assert string.contains(board.answer_refusal_words("odd\u{1b}[0m"), "odd")
  assert !string.contains(board.answer_refusal_words("odd\u{1b}[0m"), "\u{1b}")
}

pub fn a_detail_decodes_with_its_question_assignments_and_inputs_test() {
  let record =
    json.Object([
      #("id", json.String("t-a")),
      #("title", json.String("fix a")),
      #("stage", json.String("person/answer")),
      #("session", json.String("s_01")),
      #("opened_ms", json.Int(5)),
      #(
        "mandate",
        json.Object([
          #("strength", json.String("explicit")),
          #("via", json.String("composer")),
          #("source", json.String("composer")),
          #("actor", json.String("owner")),
          #("policy_version", json.String("v1")),
        ]),
      ),
      #(
        "question",
        json.Object([
          #("seq", json.Int(9)),
          #("text", json.String("which database?")),
          #("options", json.Array([json.String("sqlite"), json.Int(3)])),
        ]),
      ),
    ])
  let assert Ok(detail) =
    json.Object([
      #("project", json.String("p1")),
      #("revision", json.Int(14)),
      #("ticket", record),
      #(
        "assignments",
        json.Array([
          json.Object([
            #("seq", json.Int(1)),
            #("session", json.String("s_01")),
            #("status", json.String("running")),
          ]),
        ]),
      ),
      #(
        "inputs",
        json.Array([
          json.Object([
            #("trigger", json.String("tr-1")),
            #("delivery", json.String("failed")),
            #("text", json.String("fix a")),
          ]),
          json.Object([
            #("trigger", json.String("tr-2")),
            #("delivery", json.String("someday")),
          ]),
        ]),
      ),
    ])
    |> board.decode_detail
  assert detail.revision == 14
  assert detail.ticket.session == Some("s_01")
  let assert Some(question) = detail.ticket.question
  assert question.seq == 9
  assert question.options == ["sqlite"]
  assert list.map(detail.assignments, fn(each) { each.status }) == ["running"]
  let assert [first, second] = detail.inputs
  assert first.delivery == board.Failed
  assert first.text == Some("fix a")
  assert second.text == None
  assert second.delivery == board.UnknownDelivery("someday")
}

pub fn a_question_without_a_sequence_number_is_no_question_test() {
  let assert Ok(decoded) =
    body([
      json.Object([
        #("id", json.String("t-q")),
        #("stage", json.String("person/answer")),
        #("question", json.Object([#("text", json.String("?"))])),
      ]),
    ])
    |> board.decode_board
  let assert [one] = decoded.tickets
  assert one.question == None
}

pub fn the_project_of_a_workspace_comes_from_the_list_test() {
  let listed =
    json.Object([
      #(
        "projects",
        json.Array([
          json.Object([
            #("id", json.String("p-other")),
            #("workspace", json.String("/elsewhere")),
          ]),
          json.Object([
            #("id", json.String("p-here")),
            #("workspace", json.String("/work/repo")),
          ]),
        ]),
      ),
    ])
  assert board.project_for(listed, "/work/repo") == Some("p-here")
  assert board.project_for(listed, "/nowhere") == None
  assert board.project_for(json.Null, "/work/repo") == None
}

pub fn the_would_have_done_list_decodes_totally_and_cuts_its_text_test() {
  let long = string.repeat("x", 500)
  let row = fn(fields) { json.Object(fields) }
  let with =
    json.Object([
      #("project", json.String("p1")),
      #("revision", json.Int(1)),
      #(
        "would_have_done",
        json.Array([
          row([
            #("trigger", json.String("gh-c-1")),
            #("rule", json.String("deps")),
            #("actor", json.String("dependabot[bot]")),
            #("text", json.String(long)),
            #("link", json.String("https://github.com/o/r/issues/1")),
          ]),
          row([#("rule", json.String("no trigger so unreadable"))]),
          json.String("not an object"),
        ]),
      ),
    ])
  let assert Ok(decoded) = board.decode_board(with)
  let assert [one] = decoded.would
  assert one.trigger == "gh-c-1"
  assert string.length(one.text) == board.would_text_limit
  assert one.link == Some("https://github.com/o/r/issues/1")
  assert board.would_words(board.Would("t", "ci", "alice", "boom", None))
    == "ci: alice: boom"

  // A daemon that sends none, or something else, has an empty list.
  let assert Ok(without) = board.decode_board(body([]))
  assert without.would == []
}
