//// The governed-evolution tab of the strand panel, on an operator's page
//// (protocol-change/099).
////
//// The tab lists the session's candidates, each with its evidence and its
//// approval, the generation the session runs, the decisions made and a
//// read-only card for the core component. A row offers an approval, a
//// selection, a revocation or a rollback, and each is two presses: the first
//// opens a question and sends nothing, and the confirm sends the ids and the
//// generation the question showed. The owner's page is offered every row; a
//// member operator's page only this session's own; an observer's page has no
//// tab and no handler beneath its path.
////
//// What a page sends is read from the transport, with every effect performed
//// (`page_fixture.run`), as `proposals_page_test` does, and which handlers a
//// page holds is read through Lustre's simulator.

import core/json
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/dev/query
import lustre/dev/simulate
import lustre/effect
import lustre/element.{type Element}
import page_fixture
import session_view/connection_event
import session_view/evolution
import web_view/component
import web_view/evolution as evolving
import web_view/operator_page

@external(erlang, "page_events_ffi", "handlers")
fn every_handler(view: Element(message)) -> List(String)

// --- the board ----------------------------------------------------------------

const at = 1_790_000_000_000

fn text(value: String) -> json.JsonValue {
  json.String(value)
}

fn session_scope() -> json.JsonValue {
  json.Object([#("kind", text("session")), #("session", text("A"))])
}

fn workspace_scope() -> json.JsonValue {
  json.Object([#("kind", text("workspace")), #("workspace", text("/src/loom"))])
}

fn evidence(id: String, verdict: String) -> json.JsonValue {
  json.Object([
    #("evidence_id", text(id)),
    #("purpose", text("author_tests")),
    #("verdict", text(verdict)),
    #("reason", text("")),
    #("at_ms", json.Int(at)),
    #("identity_current", json.Bool(True)),
  ])
}

fn approval(evidence_id: String) -> json.JsonValue {
  json.Object([
    #("evidence_id", text(evidence_id)),
    #("by", text("owner")),
    #("via", text("terminal")),
  ])
}

fn chosen(generation: Int, evidence_id: String) -> json.JsonValue {
  json.Object([
    #("generation", json.Int(generation)),
    #("evidence_id", text(evidence_id)),
  ])
}

// One candidate row. `approved` and `selected` are the nested rows or null.
fn candidate(
  id: String,
  name: String,
  kind: String,
  scope: json.JsonValue,
  parent: json.JsonValue,
  approved: json.JsonValue,
  selected: json.JsonValue,
  evidence_rows: List(json.JsonValue),
) -> json.JsonValue {
  json.Object([
    #("candidate_id", text(id)),
    #("name", text(name)),
    #("kind", text(kind)),
    #("scope", scope),
    #("description", text("Runs the formatter before an edit lands.")),
    #("parent", parent),
    #(
      "origin",
      json.Object([#("session", text("A")), #("strand", text("main"))]),
    ),
    #("identity_current", json.Bool(True)),
    #("approval", approved),
    #("evidence", json.Array(evidence_rows)),
    #("selected", selected),
  ])
}

const live_id = "3f9a0c2e-live"

const fresh_id = "7b109d04-new"

const program_id = "0a7731f0-prog"

const old_id = "91ab5c20-old"

fn live_candidate() -> json.JsonValue {
  candidate(
    live_id,
    "fmt_check",
    "extension",
    session_scope(),
    json.Null,
    approval("e-live"),
    chosen(3, "e-live"),
    [evidence("e-live", "passed")],
  )
}

fn fresh_candidate() -> json.JsonValue {
  candidate(
    fresh_id,
    "fmt_check",
    "extension",
    session_scope(),
    text(live_id),
    json.Null,
    json.Null,
    [evidence("e-fresh", "passed")],
  )
}

fn program_candidate() -> json.JsonValue {
  candidate(
    program_id,
    "gleam_fix",
    "program",
    workspace_scope(),
    json.Null,
    approval("e-prog"),
    json.Null,
    [evidence("e-prog", "passed")],
  )
}

fn old_candidate() -> json.JsonValue {
  candidate(
    old_id,
    "fmt_check",
    "extension",
    session_scope(),
    json.Null,
    approval("e-old"),
    json.Null,
    [evidence("e-old", "passed")],
  )
}

fn event(
  seq: Int,
  decision: String,
  id: String,
  generation: json.JsonValue,
) -> json.JsonValue {
  json.Object([
    #("seq", json.Int(seq)),
    #("at_ms", json.Int(at)),
    #("event", text(decision)),
    #("candidate_id", text(id)),
    #("name", text("fmt_check")),
    #("generation", generation),
    #("principal", text("owner")),
    #("via", text("web")),
    #("reason", text("author tests held")),
    #("request_id", text("")),
  ])
}

fn board_of(
  candidates: List(json.JsonValue),
  pending: List(json.JsonValue),
) -> json.JsonValue {
  json.Object([
    #("version", json.Int(1)),
    #("session", text("A")),
    #("candidates", json.Array(candidates)),
    #(
      "selections",
      json.Array([
        json.Object([
          #("scope", session_scope()),
          #("name", text("fmt_check")),
          #("candidate_id", text(live_id)),
          #("evidence_id", text("e-live")),
          #("generation", json.Int(3)),
          #("published", json.Bool(True)),
        ]),
      ]),
    ),
    #("pending", json.Array(pending)),
    #(
      "history",
      json.Array([
        event(3, "selected", live_id, json.Int(3)),
        event(2, "approved", fresh_id, json.Null),
        event(1, "selected", old_id, json.Int(2)),
      ]),
    ),
    #("omitted", json.Object([#("candidates", json.Int(0))])),
  ])
}

// A board of a session that has no candidates, no selection and no history.
fn nothing() -> json.JsonValue {
  json.Object([
    #("version", json.Int(1)),
    #("session", text("A")),
    #("candidates", json.Array([])),
    #("selections", json.Array([])),
    #("pending", json.Array([])),
    #("history", json.Array([])),
  ])
}

fn full() -> json.JsonValue {
  board_of(
    [live_candidate(), fresh_candidate(), program_candidate(), old_candidate()],
    [],
  )
}

// The same board after another attachment selected the old candidate: the
// live generation is 4 and no longer the one a question was drawn from.
fn moved() -> json.JsonValue {
  let assert json.Object(fields) = full()
  json.Object(
    list.map(fields, fn(field) {
      case field {
        #("selections", _) -> #(
          "selections",
          json.Array([
            json.Object([
              #("scope", session_scope()),
              #("name", text("fmt_check")),
              #("candidate_id", text(live_id)),
              #("evidence_id", text("e-live")),
              #("generation", json.Int(4)),
              #("published", json.Bool(True)),
            ]),
          ]),
        )
        other -> other
      }
    }),
  )
}

// --- the pages ----------------------------------------------------------------

fn owner_start(
  start: component.Start(page_fixture.Wire),
) -> component.Start(page_fixture.Wire) {
  component.Start(
    ..start,
    standing: component.Standing(
      ..start.standing,
      reader: component.DaemonOwner,
    ),
  )
}

fn answer(id: Int, body: json.JsonValue) -> connection_event.Message {
  connection_event.Incoming(
    "{\"v\":2,\"reply_to\":"
    <> int.to_string(id)
    <> ",\"event\":\"snapshot\",\"body\":{\"mode\":\"evolution\",\"board\":"
    <> json.to_string(body)
    <> "}}",
  )
}

fn refusal(id: Int, code: String, message: String) -> connection_event.Message {
  connection_event.Incoming(
    "{\"v\":2,\"reply_to\":"
    <> int.to_string(id)
    <> ",\"event\":\"error\",\"body\":{\"code\":\""
    <> code
    <> "\",\"message\":\""
    <> message
    <> "\"}}",
  )
}

// What the daemon answers the page's evolution reads with: the board, or a
// refusal with the code and message it carries. A core status read is
// answered with the status of the scratch component.
type Reply {
  Listed(json.JsonValue)
  Refused(code: String, message: String)
}

fn core_status() -> json.JsonValue {
  json.Object([
    #("component", text("scratch")),
    #("version", text("0.3.0")),
    #("digest", text("91ab5c20deadbeef")),
    #("state_version", text("2")),
  ])
}

fn is_evolution(frame: String, action: String) -> Bool {
  string.contains(frame, "\"cmd\":\"evolution\"")
  && string.contains(frame, "\"action\":\"" <> action <> "\"")
}

// Answers every read the page writes, and the reads those answers free, and
// returns the frames it answered too, so a test can say what the page asked.
fn answering(model, wire, listed: Reply, rounds: Int) {
  answering_logged(model, wire, listed, rounds, []).0
}

fn answering_logged(
  model,
  wire,
  listed: Reply,
  rounds: Int,
  seen: List(String),
) -> #(component.Model(page_fixture.Wire), List(String)) {
  let reads =
    list.filter(page_fixture.sent(wire), fn(frame) {
      !string.contains(frame, "\"cmd\":\"snapshot")
      && !string.contains(frame, "\"cmd\":\"subscribe\"")
    })
  case reads, rounds {
    [], _ | _, 0 -> #(model, seen)
    _, _ -> {
      page_fixture.run(model, operator_page.update, [
        operator_page.Observed(
          component.Arrived(
            list.map(reads, fn(frame) {
              let id = page_fixture.request_id(frame)
              case is_evolution(frame, "board"), listed {
                True, Listed(board) -> answer(id, board)
                True, Refused(code, message) -> refusal(id, code, message)
                False, _ -> page_fixture.refusal(id)
              }
            }),
          ),
        ),
      ])
      |> answering_logged(wire, listed, rounds - 1, list.append(seen, reads))
    }
  }
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
    |> answering(wire, listed, 12)
  let _ = page_fixture.sent(wire)
  #(model, wire)
}

fn owner(listed: Reply) {
  page_of(owner_start(page_fixture.start()), listed)
}

fn member(listed: Reply) {
  page_of(page_fixture.start(), listed)
}

fn send(model, messages) {
  page_fixture.run(model, operator_page.update, messages)
}

fn drawn(model) -> String {
  element.to_string(operator_page.view(model))
}

fn count(haystack: String, needle: String) -> Int {
  list.length(string.split(haystack, needle)) - 1
}

// The board the page holds, and the change one of its rows offers.
fn kept(model) -> evolution.Board {
  let assert Some(board) = component.evolution_kept(model)
    as "the page holds a board"
  board
}

fn row(model, id: String) -> evolution.Candidate {
  let assert Ok(found) = evolution.find(kept(model), id)
    as "the board lists the candidate"
  found
}

fn offers(model, id: String) -> evolving.Offers {
  let board = kept(model)
  evolving.offers(
    component.evolution_reach(model),
    evolving.Settled,
    board,
    row(model, id),
  )
}

fn approving(model, id: String) -> evolving.Armed {
  let assert Some(armed) = offers(model, id).approve
    as "the row offers an approval"
  armed
}

fn selecting(model, id: String) -> evolving.Armed {
  let assert Some(armed) = offers(model, id).select
    as "the row offers a selection"
  armed
}

// The evolution commands the page wrote, with the `action` and the arguments.
fn evolutions(frames: List(String)) -> List(String) {
  list.filter(page_fixture.commands(frames), fn(frame) {
    string.contains(frame, "\"cmd\":\"evolution\"")
  })
}

// A push, the tick that sends the read it owes, and the daemon's answer.
fn pushed_board(model, wire, listed: json.JsonValue) {
  let _ = page_fixture.sent(wire)
  let model =
    send(model, [
      operator_page.Observed(
        component.Arrived([
          connection_event.Incoming(
            "{\"v\":2,\"event\":\"evolution_changed\",\"body\":{}}",
          ),
        ]),
      ),
      operator_page.Observed(component.Ticked),
    ])
  let reads =
    list.filter(page_fixture.sent(wire), fn(frame) {
      is_evolution(frame, "board")
    })
  let assert [read] = reads as "one push is one read"
  send(model, [
    operator_page.Observed(
      component.Arrived([answer(page_fixture.request_id(read), listed)]),
    ),
  ])
}

// --- the read -----------------------------------------------------------------

// The owner's page asks for the board when it opens, and again after the
// daemon pushes `evolution_changed`.
pub fn the_owners_page_reads_the_board_on_open_and_after_a_push_test() {
  let wire = process.new_subject()
  let model =
    page_fixture.run(
      component.new(owner_start(page_fixture.start())),
      operator_page.update,
      list.flatten([
        [operator_page.Observed(component.Opened(wire))],
        list.map(page_fixture.transfer("operator", []), fn(frame) {
          operator_page.Observed(component.Arrived([frame]))
        }),
        [operator_page.Observed(component.Ticked)],
      ]),
    )
  let #(model, asked) = answering_logged(model, wire, Listed(full()), 12, [])
  let _ = page_fixture.sent(wire)
  let boards = list.filter(asked, fn(frame) { is_evolution(frame, "board") })
  assert list.length(boards) == 1
  assert component.evolution_kept(model) != None

  let after = pushed_board(model, wire, board_of([fresh_candidate()], []))
  assert string.contains(drawn(after), "Extensions (1)")
  assert string.contains(drawn(after), "Programs (0)")
}

pub fn a_page_that_has_read_nothing_says_it_is_reading_test() {
  let html = drawn(component.new(owner_start(page_fixture.start())))
  assert string.contains(html, "Evolution")
  assert string.contains(html, evolution.loading_words)
}

pub fn an_empty_board_says_what_a_candidate_is_for_test() {
  let #(model, _) = owner(Listed(nothing()))
  let html = drawn(model)
  assert string.contains(html, "No extension candidates.")
  assert string.contains(html, "No program candidates.")
  assert string.contains(html, "No prompt candidates.")
  assert string.contains(html, "Nothing is selected for this session yet.")
  assert string.contains(html, "Nothing has been decided yet.")
  assert component.evolution_waiting(model) == 0
}

pub fn a_refused_read_is_worded_and_replaces_the_loading_words_test() {
  let #(model, _) =
    owner(Refused(
      "bad_request",
      "runtime evolution is unavailable for this session",
    ))
  let html = drawn(model)
  assert string.contains(html, "Evolution is not available for this session.")
  assert !string.contains(html, evolution.loading_words)
  assert component.evolution_kept(model) == None
}

// A board is drawn only when its session is the attached one.
pub fn a_board_for_another_session_is_not_drawn_test() {
  let assert json.Object(fields) = full()
  let other =
    json.Object(
      list.map(fields, fn(field) {
        case field {
          #("session", _) -> #("session", text("B"))
          kept -> kept
        }
      }),
    )
  let #(model, _) = owner(Listed(other))
  assert component.evolution_kept(model) == None
  let html = drawn(model)
  assert !string.contains(html, "fmt_check")
  assert string.contains(html, evolution.loading_words)
}

// --- what the tab draws ---------------------------------------------------------

pub fn the_tab_groups_candidates_by_kind_with_their_facts_test() {
  let #(model, _) = owner(Listed(full()))
  let html = drawn(model)
  assert string.contains(html, "Extensions (3)")
  assert string.contains(html, "Programs (1)")
  assert string.contains(html, "Prompts (0)")
  assert string.contains(html, "3f9a0c2e")
  assert string.contains(html, "generation 3, live")
  assert string.contains(html, "approved, not selected")
  assert string.contains(html, "Runs the formatter before an edit lands.")
  assert string.contains(html, "evidence: author tests · passed")
  assert string.contains(html, "2026-09-21 14:13 UTC")
  assert string.contains(html, "approved by owner · terminal")
  assert string.contains(html, "proposed from 3f9a0c2e")
  assert string.contains(html, "/src/loom")
  assert string.contains(html, "this session")
}

pub fn the_tab_says_what_is_live_and_what_was_decided_test() {
  let #(model, _) = owner(Listed(full()))
  let html = drawn(model)
  assert string.contains(html, "fmt_check</span> · extension · this session")
  assert string.contains(html, "selected fmt_check 3f9a0c2e as generation 3")
  assert string.contains(html, "owner · web · &quot;author tests held&quot;")
  assert string.contains(html, "approved fmt_check 7b109d04")
}

pub fn the_core_card_is_read_only_status_and_never_an_upgrade_test() {
  let #(model, wire) = owner(Listed(full()))
  let html = drawn(model)
  assert string.contains(html, "Core")
  assert string.contains(html, "The core status has not been read.")
  assert string.contains(html, evolution.core_words)
  assert !string.contains(html, "core_upgrade\"")
  assert !string.contains(html, "Upgrade</button>")
  assert !string.contains(html, "Downgrade")

  let model = send(model, [operator_page.ReadingCore])
  let assert [frame] = evolutions(page_fixture.sent(wire))
    as "the card's button asks for the status"
  assert string.contains(frame, "\"action\":\"core_status\"")
  let model =
    send(model, [
      operator_page.Observed(
        component.Arrived([
          answer(page_fixture.request_id(frame), core_status()),
        ]),
      ),
    ])
  assert string.contains(
    drawn(model),
    "scratch component · version 0.3.0 · digest 91ab5c20 · state version 2",
  )
}

pub fn hostile_text_is_only_ever_text_test() {
  let hostile = "</li><script>alert(1)</script>\"onmouseover=\"x"
  let one =
    candidate(
      "id-hostile",
      "<b>name</b>",
      "extension",
      session_scope(),
      json.Null,
      json.Null,
      json.Null,
      [evidence("e-h", "passed")],
    )
  let assert json.Object(fields) = one
  let hostile_row =
    json.Object(
      list.map(fields, fn(field) {
        case field {
          #("description", _) -> #("description", text(hostile))
          kept -> kept
        }
      }),
    )
  let #(model, _) = owner(Listed(board_of([hostile_row], [])))
  let html = drawn(model)
  assert !string.contains(html, "<script>")
  assert !string.contains(html, "<b>name")
  assert string.contains(html, "&lt;script&gt;")
  assert !string.contains(html, "onmouseover=\"x")
}

pub fn the_page_has_no_accent_bar_and_no_shadow_test() {
  let #(model, _) = owner(Listed(full()))
  let html = drawn(model)
  assert !string.contains(html, "box-shadow")
  assert !string.contains(html, "border-left")
}

// --- approving and selecting -----------------------------------------------------

pub fn a_row_offers_only_what_the_board_says_it_may_do_test() {
  let #(model, _) = owner(Listed(full()))
  let html = drawn(model)

  // The unapproved candidate offers an approval, the approved ones a
  // selection as the next generation, and the live one a rollback.
  assert count(html, "Approve</button>") == 1
  assert count(html, "Select as generation 4</button>") == 1
  assert count(html, "Select as generation 1</button>") == 1
  assert count(html, "Roll back to 91ab5c20</button>") == 1
  assert count(html, "Revoke</button>") == 3
}

pub fn approving_is_two_presses_and_the_first_sends_nothing_test() {
  let #(model, wire) = owner(Listed(full()))
  let armed = approving(model, fresh_id)
  let asked = send(model, [operator_page.AskingEvolve(armed)])
  assert evolutions(page_fixture.sent(wire)) == []
  let html = drawn(asked)
  assert string.contains(
    html,
    "Approve fmt_check 7b109d04 on evidence e-fresh?",
  )
  assert string.contains(html, "Keep waiting")

  let kept = send(asked, [operator_page.CancellingEvolve])
  assert evolutions(page_fixture.sent(wire)) == []
  assert !string.contains(drawn(kept), "Keep waiting")
}

pub fn the_confirm_sends_the_approval_with_the_drawn_ids_test() {
  let #(model, wire) = owner(Listed(full()))
  let armed = approving(model, fresh_id)
  let _ =
    send(model, [
      operator_page.AskingEvolve(armed),
      operator_page.ConfirmingEvolve(""),
    ])
  let assert [frame] = evolutions(page_fixture.sent(wire))
    as "one approval is one command"
  assert string.contains(frame, "\"action\":\"approve\"")
  assert string.contains(frame, "\"candidate_id\":\"" <> fresh_id <> "\"")
  assert string.contains(frame, "\"evidence_id\":\"e-fresh\"")
}

pub fn the_question_names_the_generation_and_the_confirm_echoes_it_test() {
  let #(model, wire) = owner(Listed(full()))
  let armed = selecting(model, old_id)
  assert armed.expected_generation == 3
  let asked = send(model, [operator_page.AskingEvolve(armed)])
  assert string.contains(
    drawn(asked),
    "Select fmt_check 91ab5c20 as generation 4, replacing generation 3, on evidence e-old?",
  )
  assert evolutions(page_fixture.sent(wire)) == []

  let _ =
    send(asked, [
      operator_page.ConfirmingEvolve("the old one was steadier"),
    ])
  let assert [frame] = evolutions(page_fixture.sent(wire))
    as "one selection is one command"
  assert string.contains(frame, "\"action\":\"select\"")
  assert string.contains(frame, "\"candidate_id\":\"" <> old_id <> "\"")
  assert string.contains(frame, "\"evidence_id\":\"e-old\"")
  assert string.contains(frame, "\"expected_generation\":3")
  assert string.contains(frame, "\"reason\":\"the old one was steadier\"")
  assert string.contains(frame, "\"request_id\":\"ui-")
}

pub fn a_blank_reason_sends_the_sentence_and_a_long_one_is_cut_test() {
  let #(model, wire) = owner(Listed(full()))
  let armed = selecting(model, old_id)
  let _ =
    send(model, [
      operator_page.AskingEvolve(armed),
      operator_page.ConfirmingEvolve("   "),
    ])
  let assert [frame] = evolutions(page_fixture.sent(wire))
  assert string.contains(frame, "\"reason\":\"selected from the web page\"")
  assert evolving.reason_for(evolving.Revoking, string.repeat("x", 500))
    == string.repeat("x", evolving.reason_limit)
}

pub fn a_confirm_with_no_question_open_changes_nothing_test() {
  let #(model, wire) = owner(Listed(full()))
  let _ = send(model, [operator_page.ConfirmingEvolve("go")])
  assert evolutions(page_fixture.sent(wire)) == []
}

// A change the board does not offer, such as a selection with another
// generation than the one drawn, opens no question.
pub fn a_change_the_board_does_not_offer_opens_no_question_test() {
  let #(model, wire) = owner(Listed(full()))
  let forged =
    evolving.Armed(..selecting(model, old_id), expected_generation: 9)
  let asked = send(model, [operator_page.AskingEvolve(forged)])
  assert component.evolution_state(asked).armed == None
  let _ = send(asked, [operator_page.ConfirmingEvolve("")])
  assert evolutions(page_fixture.sent(wire)) == []
}

// The board moves between the press that opened the question and the press
// that confirms it: the generation the person agreed to replace is no longer
// the live one, so nothing is sent.
pub fn a_board_that_moved_after_the_question_sends_nothing_test() {
  let #(model, wire) = owner(Listed(full()))
  let armed = selecting(model, old_id)
  let asked = send(model, [operator_page.AskingEvolve(armed)])
  let after = pushed_board(asked, wire, moved())
  assert !string.contains(drawn(after), "Keep waiting")
  let confirmed = send(after, [operator_page.ConfirmingEvolve("go")])
  assert evolutions(page_fixture.sent(wire)) == []
  assert string.contains(
    drawn(confirmed),
    "The board changed since this was drawn, so nothing was sent.",
  )
}

pub fn a_revocation_and_a_rollback_send_their_own_ids_test() {
  let #(model, wire) = owner(Listed(full()))
  let assert Some(revoke) = offers(model, live_id).revoke
    as "an approved row offers a revocation"
  let _ =
    send(model, [
      operator_page.AskingEvolve(revoke),
      operator_page.ConfirmingEvolve("flaky"),
    ])
  let assert [frame] = evolutions(page_fixture.sent(wire))
  assert string.contains(frame, "\"action\":\"revoke\"")
  assert string.contains(frame, "\"candidate_id\":\"" <> live_id <> "\"")
  assert string.contains(frame, "\"reason\":\"flaky\"")

  let assert [back] = offers(model, live_id).rollbacks
  let _ =
    send(model, [
      operator_page.AskingEvolve(back),
      operator_page.ConfirmingEvolve(""),
    ])
  let assert [frame] = evolutions(page_fixture.sent(wire))
  assert string.contains(frame, "\"action\":\"rollback\"")
  assert string.contains(frame, "\"candidate_id\":\"" <> old_id <> "\"")
  assert string.contains(frame, "\"expected_generation\":3")
}

// --- a selection on its way ------------------------------------------------------

fn queued(id: String) -> json.JsonValue {
  json.Object([#("state", text("queued")), #("request_id", text(id))])
}

fn requested_id(frame: String) -> String {
  let assert Ok(#(_, after)) = string.split_once(frame, "\"request_id\":\"")
  let assert Ok(#(id, _)) = string.split_once(after, "\"")
  id
}

pub fn a_queued_reply_draws_staging_and_a_later_status_redraws_it_test() {
  let clock = page_fixture.clock()
  let wire = process.new_subject()
  let model =
    page_fixture.run(
      component.new(owner_start(page_fixture.start_with(clock))),
      operator_page.update,
      list.flatten([
        [operator_page.Observed(component.Opened(wire))],
        list.map(page_fixture.transfer("operator", []), fn(frame) {
          operator_page.Observed(component.Arrived([frame]))
        }),
        [operator_page.Observed(component.Ticked)],
      ]),
    )
    |> answering(wire, Listed(full()), 12)
  let _ = page_fixture.sent(wire)

  let armed = selecting(model, old_id)
  let model =
    send(model, [
      operator_page.AskingEvolve(armed),
      operator_page.ConfirmingEvolve(""),
    ])
  let assert [frame] = evolutions(page_fixture.sent(wire))
  let request = requested_id(frame)
  let model =
    send(model, [
      operator_page.Observed(
        component.Arrived([
          answer(page_fixture.request_id(frame), queued(request)),
        ]),
      ),
    ])
  let html = drawn(model)
  assert string.contains(html, "staging…")
  assert !string.contains(html, request)

  // While it stages, no second selection is offered.
  assert !string.contains(html, "Select as generation")
  assert !string.contains(html, "Roll back to")

  // The lane polls on its own cadence, and a completed status redraws the row.
  page_fixture.set(clock, 2500)
  let model = send(model, [operator_page.Observed(component.Ticked)])
  let assert [poll] = evolutions(page_fixture.sent(wire)) as "one status poll"
  assert string.contains(poll, "\"action\":\"status\"")
  assert string.contains(poll, "\"request_id\":\"" <> request <> "\"")
  let done =
    json.Object([
      #("state", text("completed")),
      #("committed", json.Object([#("generation", json.Int(4))])),
    ])
  let model =
    send(model, [
      operator_page.Observed(
        component.Arrived([answer(page_fixture.request_id(poll), done)]),
      ),
    ])
  let html = drawn(model)
  assert !string.contains(html, "staging…")
  assert string.contains(html, "generation 4 is live")
}

// A selection another attachment made, or one the lane lost on a reconnect, is
// on the board's own list and draws the same words.
pub fn a_board_that_lists_a_waiting_selection_draws_staging_test() {
  let waiting =
    json.Object([
      #("request_id", text("ui-held")),
      #("state", text("running")),
      #("candidate_id", text(old_id)),
      #("expires_at_ms", json.Int(1)),
    ])
  let #(model, _) =
    owner(
      Listed(
        board_of([live_candidate(), old_candidate(), fresh_candidate()], [
          waiting,
        ]),
      ),
    )
  let html = drawn(model)
  assert string.contains(html, "staging…")
  assert !string.contains(html, "ui-held")
  assert !string.contains(html, "Select as generation")
  assert component.evolution_waiting(model) == 2
}

// --- who sees it ------------------------------------------------------------------

pub fn a_member_operator_is_offered_this_sessions_rows_only_test() {
  let #(model, wire) = member(Listed(full()))
  let html = drawn(model)

  // The session's own rows offer their changes; the workspace program, which
  // would bind other sessions, offers none and is still listed.
  assert string.contains(html, "gleam_fix")
  assert count(html, "Select as generation 1</button>") == 0
  assert count(html, "Approve</button>") == 1
  assert count(html, "Select as generation 4</button>") == 1
  assert count(html, "Revoke</button>") == 2

  // A press forged for the program opens no question and sends nothing.
  let owners =
    evolving.offers(
      evolving.Everywhere,
      evolving.Settled,
      kept(model),
      row(model, program_id),
    )
  let assert Some(armed) = owners.select
  let asked = send(model, [operator_page.AskingEvolve(armed)])
  assert component.evolution_state(asked).armed == None
  let _ = send(asked, [operator_page.ConfirmingEvolve("")])
  assert evolutions(page_fixture.sent(wire)) == []

  // The core card is the owner's alone.
  assert !string.contains(html, "Read core status")
  assert !string.contains(html, "Core</h3>")
  let _ = send(model, [operator_page.ReadingCore])
  assert evolutions(page_fixture.sent(wire)) == []
}

pub fn a_members_row_still_sends_through_the_daemons_gate_test() {
  let #(model, wire) = member(Listed(full()))
  let armed = approving(model, fresh_id)
  let _ =
    send(model, [
      operator_page.AskingEvolve(armed),
      operator_page.ConfirmingEvolve(""),
    ])
  let assert [frame] = evolutions(page_fixture.sent(wire))
  assert string.contains(frame, "\"action\":\"approve\"")
}

pub fn an_observers_page_has_no_tab_and_no_handler_there_test() {
  let model = component.new(page_fixture.start())
  let html = element.to_string(component.view(model))
  assert !string.contains(html, "pane-evolution")
  assert !string.contains(html, "Evolution")
  assert !string.contains(html, "evolution=")
  let keys = every_handler(component.view(model))
  assert list.filter(keys, fn(key) {
      string.starts_with(key, component.evolution_path)
    })
    == []

  let page =
    simulate.application(
      init: fn(_) { #(model, effect.none()) },
      update: component.update,
      view: component.view,
    )
    |> simulate.start(Nil)
  let clicked = simulate.click(page, on: query.element(query.tag("aside")))
  let assert Ok(simulate.Problem(name: "EventHandlerNotFound", ..)) =
    list.last(simulate.history(clicked))
    as "the observer's panel holds no click handler"
}

pub fn a_click_where_the_tab_draws_no_handler_is_not_found_test() {
  let #(model, _) = owner(Listed(full()))
  let page =
    simulate.application(
      init: fn(_) { #(model, effect.none()) },
      update: operator_page.update,
      view: operator_page.view,
    )
    |> simulate.start(Nil)
  let clicked =
    simulate.click(
      page,
      on: query.element(query.class("evolution-description")),
    )
  let assert Ok(simulate.Problem(name: "EventHandlerNotFound", ..)) =
    list.last(simulate.history(clicked))
    as "a candidate's text holds no click handler"
}

// --- the badge and the path ---------------------------------------------------------

pub fn the_frame_carries_the_count_waiting_for_a_person_test() {
  let #(model, _) = owner(Listed(full()))

  // One candidate has passing evidence and no approval.
  assert component.evolution_waiting(model) == 1
  assert string.contains(drawn(model), "evolution=\"1\"")
  assert string.contains(drawn(model), "Evolution · 1 waiting")

  // A page that has read nothing still has the tab, with a zero.
  let fresh = component.new(owner_start(page_fixture.start()))
  assert string.contains(drawn(fresh), "evolution=\"0\"")
}

pub fn the_pane_is_the_panels_seventh_child_and_every_handler_is_a_press_test() {
  assert component.evolution_path == "0\t3\t6"
  assert component.notes_path == "0\t3\t5"
  assert component.proposals_path == "0\t3\t2\t7"
  let #(model, _) = owner(Listed(full()))
  let armed = approving(model, fresh_id)
  let asked = send(model, [operator_page.AskingEvolve(armed)])
  let keys = every_handler(operator_page.view(asked))
  let beneath =
    list.filter(keys, fn(key) {
      string.starts_with(key, component.evolution_path <> "\t")
    })
  assert beneath != []
  assert list.all(beneath, fn(key) {
    string.ends_with(key, "\nclick") || string.ends_with(key, "\nsubmit")
  })

  // The paths that already existed keep their places.
  assert list.filter(keys, fn(key) {
      string.starts_with(key, component.notes_path <> "\t")
    })
    != []
  assert component.peers_path == "0\t3\t2\t6"
}

// The catalogue is daemon-wide, so the owner reads another session's
// candidates here, but a change to one would run through this session's queue
// and live owner. The page lists such a row and offers nothing on it, and its
// approval does not count toward the tab's badge.
pub fn a_candidate_of_another_session_is_listed_and_offered_nothing_test() {
  let elsewhere =
    candidate(
      "5555aaaa-other",
      "other_tool",
      "extension",
      json.Object([#("kind", text("session")), #("session", text("B"))]),
      json.Null,
      approval("e-other"),
      json.Null,
      [evidence("e-other", "passed")],
    )
  let #(model, wire) = owner(Listed(board_of([elsewhere], [])))
  let html = drawn(model)
  assert string.contains(html, "other_tool")
  assert string.contains(html, "session B")
  assert count(html, "Select as generation") == 0
  assert count(html, "Revoke</button>") == 0
  assert component.evolution_waiting(model) == 0
  let armed =
    evolving.Armed(
      act: evolving.Selecting,
      candidate_id: "5555aaaa-other",
      name: "other_tool",
      evidence_id: "e-other",
      expected_generation: 0,
    )
  let asked = send(model, [operator_page.AskingEvolve(armed)])
  assert component.evolution_state(asked).armed == None
  let _ = send(asked, [operator_page.ConfirmingEvolve("")])
  assert evolutions(page_fixture.sent(wire)) == []
}

// The lane holds one command at a time. A confirm that meets a busy lane sends
// nothing, says so, and leaves the question open, so the person presses the
// confirm again once the lane is free instead of finding the row as it was.
pub fn a_confirm_that_meets_a_busy_lane_keeps_its_question_test() {
  let #(model, wire) = owner(Listed(full()))
  let armed = approving(model, fresh_id)
  let asked = send(model, [operator_page.AskingEvolve(armed)])

  // A read of the core status is out and unanswered, so the slot is taken.
  let busy = send(asked, [operator_page.ReadingCore])
  let assert [read] = evolutions(page_fixture.sent(wire))
  let refused = send(busy, [operator_page.ConfirmingEvolve("")])
  assert evolutions(page_fixture.sent(wire)) == []
  assert component.evolution_state(refused).armed == Some(armed)
  assert string.contains(drawn(refused), "The session is busy")

  // The read is answered, the slot is free, and the same confirm sends.
  let freed =
    send(refused, [
      operator_page.Observed(
        component.Arrived([
          answer(page_fixture.request_id(read), core_status()),
        ]),
      ),
      operator_page.ConfirmingEvolve(""),
    ])
  let assert [frame] = evolutions(page_fixture.sent(wire))
  assert string.contains(frame, "\"action\":\"approve\"")
  assert component.evolution_state(freed).armed == None
}
