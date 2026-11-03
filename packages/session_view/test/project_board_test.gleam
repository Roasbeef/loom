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

pub fn the_rule_list_carries_each_rules_mode_and_verdict_test() {
  let rule = fn(name, mode, verdict) {
    json.Object([
      #("name", json.String(name)),
      #("mode", json.String(mode)),
      #("verdict", verdict),
    ])
  }
  let verdict = fn(state, words, labelled) {
    json.Object([
      #("state", json.String(state)),
      #("words", json.String(words)),
      #("labelled", json.Int(labelled)),
      #("needed", json.Int(30)),
    ])
  }
  let with =
    json.Object([
      #("project", json.String("p1")),
      #("revision", json.Int(1)),
      #(
        "sources",
        json.Array([
          json.Object([
            #("source", json.String("github")),
            #(
              "rules",
              json.Array([
                rule("ci", "observe", verdict("none", "No verdict yet.", 12)),
                rule(
                  "deps",
                  "auto",
                  verdict("current", "Passing. Replay over 30.", 30),
                ),
                json.Object([#("mode", json.String("no name"))]),
              ]),
            ),
          ]),
          json.String("not a source"),
        ]),
      ),
    ])
  let assert Ok(decoded) = board.decode_board(with)
  let assert [ci, deps] = decoded.rules
  assert board.rule_words(ci) == "ci: observe, no verdict, 12 of 30 labelled"
  assert board.rule_words(deps)
    == "deps: auto, verdict passing, 30 of 30 labelled"
  assert deps.words == "Passing. Replay over 30."

  // A daemon that predates the verdict shows the rule with none.
  let older =
    json.Object([
      #("project", json.String("p1")),
      #("revision", json.Int(1)),
      #(
        "sources",
        json.Array([
          json.Object([
            #(
              "rules",
              json.Array([
                json.Object([
                  #("name", json.String("ci")),
                  #("mode", json.String("observe")),
                ]),
              ]),
            ),
          ]),
        ]),
      ),
    ])
  let assert Ok(plain) = board.decode_board(older)
  let assert [only] = plain.rules
  assert only.verdict == ""
  assert only.needed == 0
}

// A source's note says why it is not reading, so the board keeps it. A source
// with no note, an empty one, a blank one or one that is not text adds nothing,
// and a newline or escape in a note never reaches a drawn line.
pub fn a_sources_note_is_kept_and_made_safe_to_draw_test() {
  let source = fn(note: List(#(String, json.JsonValue))) {
    json.Object([#("source", json.String("github")), ..note])
  }
  let with =
    json.Object([
      #("project", json.String("p1")),
      #("revision", json.Int(1)),
      #(
        "sources",
        json.Array([
          source([
            #(
              "note",
              json.String("the origin is not a URL,\nso it is not read"),
            ),
          ]),
          source([#("note", json.String(""))]),
          source([#("note", json.String("   "))]),
          source([#("note", json.Int(3))]),
          source([]),
          json.String("not a source"),
          source([#("note", json.String("rate limited until 10:05\u{1b}[31m"))]),
        ]),
      ),
    ])
  let assert Ok(decoded) = board.decode_board(with)

  assert decoded.notes
    == [
      "the origin is not a URL, so it is not read",
      "rate limited until 10:05",
    ]

  // A daemon that sends no sources, or no notes, has none to show.
  let assert Ok(without) =
    board.decode_board(
      json.Object([
        #("project", json.String("p1")),
        #("revision", json.Int(1)),
      ]),
    )
  assert without.notes == []
}

pub fn the_labels_reply_decodes_totally_and_cuts_its_text_test() {
  let long = string.repeat("y", 500)
  let reply =
    json.Object([
      #("rule", json.String("deps")),
      #("labelled", json.Int(4)),
      #("needed", json.Int(30)),
      #(
        "triggers",
        json.Array([
          json.Object([
            #("trigger", json.String("gh-c-7")),
            #("actor", json.String("dependabot[bot]")),
            #("text", json.String(long)),
            #("recorded", json.String("took")),
          ]),
          json.Object([#("actor", json.String("no trigger"))]),
        ]),
      ),
    ])
  let assert Ok(decoded) = board.decode_labels(reply)
  assert decoded.rule == "deps"
  assert decoded.labelled == 4
  let assert [one] = decoded.candidates
  assert one.trigger == "gh-c-7"
  assert string.length(one.text) == board.would_text_limit
  assert one.recorded == "took"
  let assert Error(_) = board.decode_labels(json.Null)
  let assert Error(_) = board.decode_labels(json.Object([]))
}

// --- verdict runs ------------------------------------------------------------

fn board_with_run(run: option.Option(json.JsonValue)) -> json.JsonValue {
  let base = [#("name", json.String("ci")), #("mode", json.String("observe"))]
  let fields = case run {
    Some(found) -> list.append(base, [#("run", found)])
    None -> base
  }

  json.Object([
    #("project", json.String("p1")),
    #("revision", json.Int(1)),
    #(
      "sources",
      json.Array([
        json.Object([#("rules", json.Array([json.Object(fields)]))]),
      ]),
    ),
  ])
}

fn only_rule(document: json.JsonValue) -> board.Rule {
  let assert Ok(decoded) = board.decode_board(document)
  let assert [only] = decoded.rules
  only
}

pub fn a_rule_with_no_run_field_or_a_null_run_has_none_test() {
  assert only_rule(board_with_run(None)).run == None
  assert only_rule(board_with_run(Some(json.Null))).run == None

  // A run that is not an object, or names no state, is none and not a guess.
  assert only_rule(board_with_run(Some(json.String("x")))).run == None
  assert only_rule(board_with_run(Some(json.Object([])))).run == None
}

pub fn a_running_run_carries_progress_test() {
  let run =
    json.Object([
      #("state", json.String("running")),
      #("done", json.Int(12)),
      #("of", json.Int(90)),
      #("calls", json.Int(12)),
      #("tokens", json.Int(5100)),
      #("started_ms", json.Int(7)),
    ])
  let assert Some(found) = only_rule(board_with_run(Some(run))).run

  assert found == board.RunGoing(done: 12, of: 90, calls: 12, tokens: 5100)
  assert board.run_words(found)
    == "live run: 12 of 90 trials, 12 calls, 5100 tokens"
}

pub fn an_ended_run_carries_its_outcome_in_the_daemons_words_test() {
  let ended = fn(state) {
    json.Object([
      #("state", json.String(state)),
      #("words", json.String("The interval stayed above the floor.")),
      #("calls", json.Int(90)),
      #("tokens", json.Int(41_000)),
      #("ended_ms", json.Int(9)),
    ])
  }

  // Each outcome the protocol names is kept as sent, and a word this client
  // does not know is shown as sent and not mapped to one it does.
  let words = fn(state) {
    let assert Some(found) = only_rule(board_with_run(Some(ended(state)))).run
    board.run_words(found)
  }

  assert words("passed")
    == "live run passed, 90 calls, 41000 tokens: The interval stayed above the floor."
  assert string.starts_with(words("failed"), "live run failed, 90 calls")
  assert string.starts_with(
    words("incomplete"),
    "live run incomplete, 90 calls",
  )
  assert string.starts_with(
    words("from-the-future"),
    "live run from-the-future",
  )
}

pub fn run_text_is_made_safe_like_every_other_string_test() {
  let run =
    json.Object([
      #("state", json.String("failed")),
      #("words", json.String("bad\u{1b}[31m\nline")),
    ])
  let assert Some(board.RunOver(words:, ..)) =
    only_rule(board_with_run(Some(run))).run

  assert !string.contains(words, "\u{1b}")
  assert !string.contains(words, "\n")
}

pub fn the_live_confirmation_states_the_count_and_the_calls_test() {
  assert board.live_warning_words("ci")
    == "A live verdict on ci spends real model calls."
  assert board.live_count_words(30)
    == "30 labelled triggers, 3 trials each: about 90 calls."
}

pub fn the_words_for_a_mode_and_a_lane_are_the_wires_test() {
  assert board.mode_word(board.ModeOff) == "off"
  assert board.mode_word(board.ModeObserve) == "observe"
  assert board.mode_word(board.ModeAuto) == "auto"
  assert board.lane_word(board.Replay) == "replay"
  assert board.lane_word(board.Live) == "live"
}

pub fn a_live_reply_is_worded_as_running_and_not_as_a_finding_test() {
  let reply =
    json.Object([
      #("state", json.String("running")),
      #("words", json.String("90 trials started.")),
    ])

  assert board.verdict_reply_words(board.Live, "ci", reply)
    == "Live verdict on ci running. 90 trials started."
  assert board.verdict_reply_words(board.Replay, "ci", json.Object([]))
    == "Replay verdict on ci recorded."
}

// --- a ticket's check result ----------------------------------------------------

fn with_check(check: json.JsonValue) -> board.Ticket {
  let assert Ok(decoded) =
    body([
      json.Object([
        #("id", json.String("t-a")),
        #("stage", json.String("person/check")),
        #("check", check),
        #(
          "actions",
          json.Array([json.String("recheck"), json.String("publish")]),
        ),
      ]),
    ])
    |> board.decode_board
  let assert [found] = decoded.tickets
  found
}

pub fn a_failed_check_needs_a_person_and_offers_the_rerun_test() {
  let found =
    with_check(
      json.Object([
        #("commit", json.String("0123456789abcdef")),
        #("outcome", json.String("failed")),
        #("at_ms", json.Int(1000)),
        #("command", json.String("make check")),
        #("output", json.String("exit status 127\nmake: go: command not found")),
        #("cause", json.String("environment")),
        #("handling", json.String("person")),
      ]),
    )
  assert found.stage == board.PersonCheck
  assert board.attention(found.stage) == board.NeedsPerson
  assert board.stage_word(found.stage) == "check failed"
  assert board.offers(found, board.CanRecheck)
  let assert Some(check) = found.check
  assert check.outcome == board.CheckFailed
  assert check.output == Some("exit status 127\nmake: go: command not found")
  assert board.check_words(check, 181_000)
    == "The check failed at 0123456789ab, 3m ago. The check could not run as written, so the commit did not cause it, and the worker was not told."
}

pub fn a_failed_check_ranks_among_the_stages_that_need_a_person_test() {
  let tickets = [
    ticket("t-queued", "queued", 1, "q"),
    ticket("t-check", "person/check", 2, "c"),
    ticket("t-failed", "person/failed", 3, "f"),
    ticket("t-review", "person/review", 4, "r"),
  ]
  let assert Ok(decoded) = body(tickets) |> board.decode_board
  assert ids(board.ordered(decoded.tickets))
    == ["t-review", "t-check", "t-failed", "t-queued"]
}

pub fn the_checks_output_is_inert_and_a_missing_one_is_unknown_test() {
  let hostile =
    with_check(
      json.Object([
        #("commit", json.String("abc")),
        #("outcome", json.String("failed")),
        #("output", json.String("\u{1b}[31m<script>alert(1)</script>\u{7}")),
        #("command", json.String("make\u{1b}[0m check")),
      ]),
    )
  let assert Some(check) = hostile.check
  let assert Some(output) = check.output
  assert !string.contains(output, "\u{1b}")
  assert !string.contains(output, "\u{7}")

  // Markup passes through as the text it is: the hosts draw text, not HTML.
  assert string.contains(output, "<script>alert(1)</script>")
  let assert Some(command) = check.command
  assert !string.contains(command, "\u{1b}")

  // No time, output or command is unknown and not empty.
  let bare =
    with_check(
      json.Object([
        #("commit", json.String("abc")),
        #("outcome", json.String("passed")),
      ]),
    )
  let assert Some(passed) = bare.check
  assert passed.at_ms == None
  assert passed.output == None
  assert board.check_words(passed, 0) == "The check passed at abc."
}

pub fn a_check_without_a_commit_or_an_outcome_this_client_knows_is_handled_test() {
  assert with_check(json.Object([#("outcome", json.String("failed"))])).check
    == None
  assert with_check(json.Null).check == None
  let odd =
    with_check(
      json.Object([
        #("commit", json.String("abc")),
        #("outcome", json.String("exploded")),
      ]),
    )
  let assert Some(check) = odd.check
  assert check.outcome == board.CheckUnknown("exploded")
  assert board.check_words(check, 0) == "The check reported exploded at abc."
}

pub fn a_waiting_check_carries_the_daemons_reason_test() {
  let waiting =
    with_check(
      json.Object([
        #("commit", json.String("abc")),
        #("outcome", json.String("waiting")),
        #("note", json.String("The project's setup failed.")),
      ]),
    )
  let assert Some(check) = waiting.check
  assert board.check_words(check, 0)
    == "The check has not run at abc. The project's setup failed."
}
