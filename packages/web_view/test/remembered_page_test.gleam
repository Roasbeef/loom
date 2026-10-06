//// "Allow for this session" on an operator's page, and the list of what it
//// kept (protocol-change/073).
////
//// The card offers the button only where the terminal would
//// (`approval.rememberable`), the click asks again and echoes the drawn
//// record, and the Session pane lists each remembered permission with who
//// allowed it, from which sign-in and when, behind a two-step Forget. What a
//// page sends is read from the transport, with every effect performed
//// (`page_fixture.run`), as `operator_page_test` does.

import core/json
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/element.{type Element}
import page_fixture
import session_view/connection_event
import session_view/remembered
import web_view/component
import web_view/operator_page
import web_view/remembered as holding

@external(erlang, "page_events_ffi", "handlers")
fn every_handler(view: Element(message)) -> List(String)

// A pending escalation wanting `wanted`, as the harness stores one.
fn escalation(
  id: String,
  seq: Int,
  wanted: List(json.JsonValue),
) -> json.JsonValue {
  json.Object([
    #("namespace", json.String("fact.custom")),
    #("key", json.String("escalation/" <> id)),
    #("seq", json.Int(seq)),
    #(
      "value",
      json.Object([
        #("id", json.String(id)),
        #("status", json.String("pending")),
        #("tool", json.String("bash")),
        #("preview", json.String("make check")),
        #("action", json.String("captured-action")),
        #("origin", json.Null),
        #("denial", json.Object([#("wanted", json.Array(wanted))])),
      ]),
    ),
  ])
}

fn writable(path: String) -> json.JsonValue {
  json.Object([
    #("grant", json.String("writable_root")),
    #("path", json.String(path)),
  ])
}

fn limit() -> json.JsonValue {
  json.Object([
    #("grant", json.String("limit")),
    #("field", json.String("wall_s")),
    #("value", json.Int(60)),
  ])
}

fn rememberable() -> List(json.JsonValue) {
  [escalation("esc-1", 7, [writable("/shared/output")])]
}

fn with_a_limit() -> List(json.JsonValue) {
  [escalation("esc-1", 7, [writable("/shared/output"), limit()])]
}

// The wire grant a board carries for a path.
fn wire(kind: String, path: String) -> json.JsonValue {
  json.Object([#("type", json.String(kind)), #("path", json.String(path))])
}

fn network() -> json.JsonValue {
  json.Object([
    #("type", json.String("network")),
    #("network", json.Object([#("mode", json.String("full"))])),
  ])
}

fn approved(name: String, fingerprint: String) -> json.JsonValue {
  json.Object([
    #(
      "by",
      json.Object([
        #("principal", json.String("alice")),
        #("name", json.String(name)),
      ]),
    ),
    #(
      "via",
      json.Object([
        #("kind", json.String("login")),
        #("fingerprint", json.String(fingerprint)),
      ]),
    ),
    #("at_ms", json.Int(1_790_000_000_000)),
  ])
}

fn row(grant: json.JsonValue, provenance: json.JsonValue) -> json.JsonValue {
  json.Object([#("grant", grant), #("provenance", provenance)])
}

fn board(
  seq: Int,
  grants: List(json.JsonValue),
  actions: List(json.JsonValue),
) -> json.JsonValue {
  json.Object([
    #("seq", json.Int(seq)),
    #("grants", json.Array(grants)),
    #("actions", json.Array(actions)),
  ])
}

// The reply the daemon gives to a `permissions` read or a forget.
fn answer(request: Int, board: json.JsonValue) -> connection_event.Message {
  connection_event.Incoming(
    "{\"v\":2,\"reply_to\":"
    <> int.to_string(request)
    <> ",\"event\":\"snapshot\",\"body\":{\"mode\":\"permissions\",\"board\":"
    <> json.to_string(board)
    <> "}}",
  )
}

// A page for `role` whose cut holds `cells`, after the lane's own reads are
// answered. A `permissions` read is answered with `listed` when there is a
// board and refused when there is none, as an older daemon would.
fn page(role: String, cells, listed: option.Option(json.JsonValue)) {
  page_of(owner_start(), role, cells, listed)
}

// The daemon's owner's page: the only one that may remember anything.
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

fn page_of(
  start: component.Start(page_fixture.Wire),
  role: String,
  cells,
  listed: option.Option(json.JsonValue),
) {
  let wire = process.new_subject()
  let model =
    page_fixture.run(
      component.new(start),
      operator_page.update,
      list.flatten([
        [operator_page.Observed(component.Opened(wire))],
        list.map(page_fixture.transfer(role, cells), fn(frame) {
          operator_page.Observed(component.Arrived([frame]))
        }),
        [operator_page.Observed(component.Ticked)],
      ]),
    )
    |> answering(wire, listed, 8)
  let _ = page_fixture.sent(wire)
  #(model, wire)
}

// Answers the reads on the wire, and the reads those free, until it holds
// none: the board for the permissions read and a refusal for every other.
fn answering(model, wire, listed, rounds: Int) {
  let reads =
    list.filter(page_fixture.sent(wire), fn(frame) {
      !string.contains(frame, "\"cmd\":\"snapshot")
      && !string.contains(frame, "\"cmd\":\"subscribe\"")
    })
  case reads, rounds {
    [], _ | _, 0 -> model
    _, _ ->
      page_fixture.run(model, operator_page.update, [
        operator_page.Observed(
          component.Arrived(
            list.map(reads, fn(frame) {
              let id = page_fixture.request_id(frame)
              case string.contains(frame, "\"cmd\":\"permissions\""), listed {
                True, Some(board) -> answer(id, board)
                True, None | False, _ -> page_fixture.refusal(id)
              }
            }),
          ),
        ),
      ])
      |> answering(wire, listed, rounds - 1)
  }
}

fn send(model, messages) {
  page_fixture.run(model, operator_page.update, messages)
}

fn drawn(model) -> String {
  element.to_string(operator_page.view(model))
}

// --- the card ---------------------------------------------------------------

// The terminal offers the choice only where every grant is a canonical path or
// full network (`approval.rememberable`), and the page asks the same function.
pub fn a_card_offers_allow_for_the_session_where_the_terminal_does_test() {
  let #(model, _) = page("operator", rememberable(), None)
  let html = drawn(model)
  let assert [_, after_deny] = string.split(html, "Deny bash")
    as "the deny button names the tool once"
  assert string.contains(after_deny, "Allow bash once")
  assert string.contains(after_deny, "Allow bash for this session")
  assert !string.contains(html, "autofocus")

  // Deny is still the first control, and the session choice follows allow
  // once rather than replacing it.
  let assert [before_once, after_once] =
    string.split(after_deny, "Allow bash once")
  assert !string.contains(before_once, "for this session")
  assert string.contains(after_once, "for this session")
}

pub fn a_card_with_a_limit_offers_only_allow_once_test() {
  let #(model, _) = page("operator", with_a_limit(), None)
  let html = drawn(model)
  assert string.contains(html, "Allow bash once")
  assert !string.contains(html, "for this session")
}

pub fn allow_for_the_session_echoes_the_drawn_record_with_the_session_scope_test() {
  let #(model, wire) = page("operator", rememberable(), None)
  let _ =
    send(model, [
      operator_page.Decided("esc-1", 7, component.AllowForSession),
    ])
  let assert [frame] = page_fixture.commands(page_fixture.sent(wire))
    as "one decision is one command"
  assert string.contains(frame, "\"cmd\":\"approve\"")
  assert string.contains(frame, "\"scope\":\"session\"")
  assert string.contains(frame, "\"expected_seq\":7")
  assert string.contains(frame, "\"action\":\"captured-action\"")
  assert string.contains(frame, "/shared/output")
}

pub fn allow_for_the_session_for_a_stale_sequence_sends_nothing_test() {
  let #(model, wire) = page("operator", rememberable(), None)
  let model =
    send(model, [
      operator_page.Decided("esc-1", 6, component.AllowForSession),
    ])
  assert page_fixture.commands(page_fixture.sent(wire)) == []
  let assert component.Warned(_) = component.notice(model)
    as "the page says nothing was decided"
}

// A button drawn from a card is asked again at the click: a record that no
// longer holds only remembered authority cannot be remembered by a button
// that was drawn for it.
pub fn allow_for_the_session_is_asked_again_at_the_click_test() {
  let #(model, wire) = page("operator", with_a_limit(), None)
  let _ =
    send(model, [
      operator_page.Decided("esc-1", 7, component.AllowForSession),
    ])
  assert page_fixture.commands(page_fixture.sent(wire)) == []
}

pub fn an_observers_attachment_cannot_allow_for_the_session_test() {
  let #(model, wire) = page("observer", rememberable(), None)
  let _ =
    send(model, [
      operator_page.Decided("esc-1", 7, component.AllowForSession),
    ])
  assert page_fixture.commands(page_fixture.sent(wire)) == []
}

// --- the list ---------------------------------------------------------------

fn remembered_board() -> json.JsonValue {
  board(
    9,
    [
      row(wire("readable_root", "/repo"), approved("Alice", "9c1e0f2ab3d4e5f6")),
      row(network(), json.Null),
    ],
    [],
  )
}

pub fn the_list_names_each_permission_who_allowed_it_and_when_test() {
  let #(model, _) = page("operator", [], Some(remembered_board()))
  let html = drawn(model)
  assert string.contains(html, "Remembered permissions")
  assert string.contains(html, "Read /repo")
  assert string.contains(html, "Network access")
  assert string.contains(
    html,
    "Alice from a browser sign-in 9c1e0f2ab3d4e5f6 · 2026-09-21 14:13 UTC",
  )
  assert string.contains(html, "Approved before approvals were recorded")
  assert string.contains(html, "Forget all 2")
  assert !string.contains(html, "box-shadow")
}

pub fn a_page_that_has_read_nothing_says_so_test() {
  let #(model, _) = page("operator", [], None)
  assert string.contains(drawn(model), "not read yet")
}

pub fn a_session_that_remembers_nothing_says_so_test() {
  let #(model, _) = page("operator", [], Some(board(0, [], [])))
  assert string.contains(
    drawn(model),
    "Nothing is remembered for this session.",
  )
}

// Paths, command excerpts and names are session text. Each is a text node:
// none can open a tag, and none is in an attribute, a class or a handler.
pub fn hostile_text_in_the_list_is_only_ever_text_test() {
  let hostile = "</li><script>alert(1)</script>\"onmouseover=\"x"
  let listed =
    board(
      3,
      [
        row(
          wire("writable_root", hostile),
          approved("<img src=x onerror=alert(2)>", "9c1e0f2ab3d4e5f6"),
        ),
      ],
      [
        json.Object([
          #("id", json.String("ab12")),
          #("seq", json.Int(4)),
          #("tool", json.String("bash")),
          #("strand", json.String("<b>main</b>")),
          #("preview", json.String("<script>alert(3)</script>")),
          #("provenance", json.Null),
        ]),
      ],
    )
  let #(model, _) = page("operator", [], Some(listed))
  let html = drawn(model)
  assert !string.contains(html, "<script>")
  assert !string.contains(html, "<img")
  assert !string.contains(html, "<b>")
  assert string.contains(html, "&lt;script&gt;")
  assert string.contains(html, "&lt;img src=x onerror=alert(2)&gt;")
  assert !string.contains(html, "onmouseover=\"x")
}

// --- forgetting -------------------------------------------------------------

fn armed_for(listed: json.JsonValue, index: Int) -> holding.Armed {
  let assert Ok(decoded) = remembered.decode(listed)
  let assert Ok(permission) = list.drop(decoded.grants, index) |> list.first
  holding.forgetting_permission(decoded, permission)
}

pub fn forgetting_is_two_presses_and_the_first_sends_nothing_test() {
  let #(model, wire) = page("operator", [], Some(remembered_board()))
  let asked =
    send(model, [operator_page.AskingForget(armed_for(remembered_board(), 0))])
  assert page_fixture.commands(page_fixture.sent(wire)) == []
  let html = drawn(asked)
  assert string.contains(
    html,
    "Forget this permission? The agent will have to ask again.",
  )
  assert string.contains(html, "Keep it")

  // Keeping it closes the question and still sends nothing.
  let kept = send(asked, [operator_page.CancellingForget])
  assert page_fixture.commands(page_fixture.sent(wire)) == []
  assert !string.contains(drawn(kept), "Keep it")
}

pub fn the_confirm_sends_what_the_question_armed_and_only_that_test() {
  let #(model, wire) = page("operator", [], Some(remembered_board()))
  let _ =
    send(model, [
      operator_page.AskingForget(armed_for(remembered_board(), 0)),
      operator_page.ConfirmingForget,
    ])
  let assert [frame] = page_fixture.commands(page_fixture.sent(wire))
    as "one forget is one command"
  assert string.contains(frame, "\"cmd\":\"permission_forget\"")
  assert string.contains(frame, "\"kind\":\"grant\"")
  assert string.contains(frame, "/repo")
  assert string.contains(frame, "\"expected_seq\":9")
}

pub fn a_confirm_with_no_question_open_changes_nothing_test() {
  let #(model, wire) = page("operator", [], Some(remembered_board()))
  let _ = send(model, [operator_page.ConfirmingForget])
  assert page_fixture.commands(page_fixture.sent(wire)) == []
}

pub fn forget_all_asks_about_everything_the_list_showed_test() {
  let #(model, wire) = page("operator", [], Some(remembered_board()))
  let assert Ok(decoded) = remembered.decode(remembered_board())
  let asked =
    send(model, [
      operator_page.AskingForget(holding.forgetting_everything(decoded)),
    ])
  assert string.contains(
    drawn(asked),
    "Forget all 2? The agent will have to ask again for each.",
  )
  let _ = send(asked, [operator_page.ConfirmingForget])
  let assert [frame] = page_fixture.commands(page_fixture.sent(wire))
  assert string.contains(frame, "\"kind\":\"all\"")
  assert string.contains(frame, "\"expected_seq\":9")
}

// The daemon answers a forget with what remains, and the page draws that.
pub fn the_answer_to_a_forget_redraws_the_list_test() {
  let #(model, wire) = page("operator", [], Some(remembered_board()))
  let model =
    send(model, [
      operator_page.AskingForget(armed_for(remembered_board(), 0)),
      operator_page.ConfirmingForget,
    ])
  let assert [frame] = page_fixture.commands(page_fixture.sent(wire))
  let after = board(10, [row(network(), json.Null)], [])
  let model =
    send(model, [
      operator_page.Observed(
        component.Arrived([answer(page_fixture.request_id(frame), after)]),
      ),
    ])
  let html = drawn(model)
  assert !string.contains(html, "Read /repo")
  assert string.contains(html, "Network access")
}

// --- sign-ins that have ended -----------------------------------------------

pub fn a_permission_from_an_ended_sign_in_says_so_test() {
  let #(model, _) = page("operator", [], Some(remembered_board()))
  assert !string.contains(drawn(model), holding.ended_words)
  let judged =
    send(model, [
      operator_page.Observed(
        component.LoginsJudged([holding.Login("alice", "9c1e0f2ab3d4e5f6")]),
      ),
    ])
  let html = drawn(judged)
  assert string.contains(html, holding.ended_words)

  // Only the permission that came from that sign-in carries the note.
  assert list.length(string.split(html, holding.ended_words)) == 2
}

pub fn a_sign_in_the_daemon_did_not_judge_draws_no_note_test() {
  let #(model, _) = page("operator", [], Some(remembered_board()))
  let judged =
    send(model, [
      operator_page.Observed(
        component.LoginsJudged([
          holding.Login("someone-else", "ffffffffffffffff"),
        ]),
      ),
    ])
  assert !string.contains(drawn(judged), holding.ended_words)
}

// --- where the handlers are ---------------------------------------------------

pub fn the_list_is_the_sixth_child_of_the_session_pane_test() {
  assert component.remembered_path == "0\t3\t2\t5"
  let #(model, _) = page("operator", [], Some(remembered_board()))
  let keys = every_handler(operator_page.view(model))
  let beneath =
    list.filter(keys, fn(key) {
      string.starts_with(key, component.remembered_path <> "\t")
    })

  // One Forget button for each row, and Forget all.
  assert list.length(beneath) == 3
  assert list.all(beneath, fn(key) { string.ends_with(key, "\nclick") })

  // The invitation, the session controls and the rename control keep the
  // paths they had, and nothing outside the list gained a handler.
  assert component.invite_path == "0\t3\t2\t2"
  assert component.session_controls_path == "0\t3\t2\t3"
  assert component.rename_path == "0\t3\t2\t4"
}

pub fn an_observers_page_draws_no_list_and_no_handler_there_test() {
  let model = component.new(page_fixture.start())
  let html = element.to_string(component.view(model))
  assert !string.contains(html, "Remembered permissions")
  let keys = every_handler(component.view(model))
  assert list.filter(keys, fn(key) {
      string.starts_with(key, component.remembered_path)
    })
    == []
}

// --- members -----------------------------------------------------------------

// A member who may allow once and deny may not remember anything for the
// session or see what the owner remembered (protocol-change/073), so the card
// offers the two answers it always did, the pane draws no list, and the page
// never asks for one.
pub fn a_members_page_offers_allow_once_and_deny_only_test() {
  let #(model, wire) =
    page_of(
      page_fixture.start(),
      "operator",
      rememberable(),
      Some(remembered_board()),
    )
  let html = drawn(model)
  assert string.contains(html, "Deny bash")
  assert string.contains(html, "Allow bash once")
  assert !string.contains(html, "for this session")
  assert !string.contains(html, "Remembered permissions")
  assert !string.contains(html, "Read /repo")
  assert component.permissions_kept(model) == option.None

  // Nothing the browser sends can ask for it either.
  let sent =
    send(model, [
      operator_page.Decided("esc-1", 7, component.AllowForSession),
    ])
  assert page_fixture.commands(page_fixture.sent(wire)) == []
  let assert component.Warned(_) = component.notice(sent)
}

pub fn an_owners_page_offers_the_session_choice_and_the_list_test() {
  let #(model, _) = page("operator", rememberable(), Some(remembered_board()))
  let html = drawn(model)
  assert string.contains(html, "Allow bash for this session")
  assert string.contains(html, "Remembered permissions")
  assert string.contains(html, "Read /repo")
}
