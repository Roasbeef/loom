//// The owner's review of proposed standing rules, on an operator's page
//// (protocol-change/086).
////
//// The Session pane lists each proposal newest first, opens one onto its edit
//// as a red and green diff, and approves it behind a question or rejects it
//// at once. The page is the owner's alone: a member's page and an observer's
//// draw nothing there, read nothing and send nothing. What a page sends is
//// read from the transport, with every effect performed (`page_fixture.run`),
//// as `remembered_page_test` does.

import core/json
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import lustre/element.{type Element}
import page_fixture
import session_view/connection_event
import session_view/proposals
import web_view/component
import web_view/operator_page

@external(erlang, "page_events_ffi", "handlers")
fn every_handler(view: Element(message)) -> List(String)

fn row(
  id: String,
  state: String,
  old: String,
  new: String,
  rationale: String,
) -> json.JsonValue {
  json.Object([
    #("id", json.String(id)),
    #("kind", json.String("rule")),
    #("target", json.String("loom-rules.md")),
    #("base_digest", json.String("cbf29ce484222325-0")),
    #("old", json.String(old)),
    #("new", json.String(new)),
    #("rationale", json.String(rationale)),
    #(
      "source",
      json.Object([
        #("session", json.String("0198c0de-0000-7000-8000-000000000001")),
        #("entry", json.String("0198c0de-0000-7000-8000-000000000003")),
      ]),
    ),
    #("created_ms", json.Int(1_790_000_000_000)),
    #("state", json.String(state)),
  ])
}

fn board(rows: List(json.JsonValue), pending: Int) -> json.JsonValue {
  json.Object([
    #("proposals", json.Array(rows)),
    #("pending", json.Int(pending)),
    #("limit", json.Int(64)),
  ])
}

fn one() -> json.JsonValue {
  board(
    [
      row(
        "prop-0000000001",
        "pending",
        "Run make test.",
        "Run make check.",
        "it failed twice",
      ),
    ],
    1,
  )
}

fn many() -> json.JsonValue {
  board(
    [
      row(
        "prop-0000000003",
        "pending",
        "",
        "Keep commits small.",
        "reviewer asked",
      ),
      row("prop-0000000002", "stale", "old rule", "new rule", "moved"),
      row("prop-0000000001", "approved", "", "Run make check.", "it failed"),
    ],
    1,
  )
}

// The reply the daemon gives to a `proposals_get` or a decision.
fn answer(request: Int, board: json.JsonValue) -> connection_event.Message {
  connection_event.Incoming(
    "{\"v\":2,\"reply_to\":"
    <> int.to_string(request)
    <> ",\"event\":\"snapshot\",\"body\":{\"mode\":\"proposals\",\"board\":"
    <> json.to_string(board)
    <> "}}",
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

// A page whose cut is empty, after the lane's own reads are answered. A
// `proposals_get` is answered with `listed` when there is a board and refused
// with `refusal` when there is none.
// What the daemon answers a `proposals_get` with: the board, or a refusal
// with the code it carries.
type Reply {
  Listed(json.JsonValue)
  Refused(code: String)
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
              case string.contains(frame, "\"cmd\":\"proposals_get\""), listed {
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

fn send(model, messages) {
  page_fixture.run(model, operator_page.update, messages)
}

fn drawn(model) -> String {
  element.to_string(operator_page.view(model))
}

// --- the list -----------------------------------------------------------------

pub fn a_board_that_left_rows_out_says_how_many_test() {
  let assert json.Object(fields) = one()
  let left_out = json.Object(list.append(fields, [#("omitted", json.Int(3))]))
  let #(model, _wire) = owner(Listed(left_out))
  assert string.contains(drawn(model), "3 older proposals not shown")
  let #(whole, _wire) = owner(Listed(one()))
  assert !string.contains(drawn(whole), "older proposal")
}

pub fn a_page_that_has_read_nothing_says_it_is_reading_test() {
  let model = component.new(owner_start())
  let html = drawn(model)
  assert string.contains(html, "Proposals")
  assert string.contains(html, proposals.loading_words)
}

pub fn no_proposals_says_what_a_proposal_is_for_test() {
  let #(model, _) = owner(Listed(board([], 0)))
  let html = drawn(model)
  assert string.contains(
    html,
    "No proposals. The agent proposes a rule when it notices a correction worth keeping.",
  )
  assert component.proposals_pending(model) == 0
}

pub fn one_proposal_shows_its_facts_and_the_two_buttons_test() {
  let #(model, _) = owner(Listed(one()))
  let html = drawn(model)
  assert string.contains(html, "Proposals · 1 pending")
  assert string.contains(html, "prop-0000000001")
  assert string.contains(html, "it failed twice")
  assert string.contains(html, "2026-09-21 14:13 UTC")
  assert string.contains(html, "A rule applies to new sessions only.")
  assert string.contains(html, "Approve</button>")
  assert string.contains(html, "Reject</button>")
  assert component.proposals_pending(model) == 1
}

pub fn the_drawer_shows_the_edit_in_red_and_green_and_where_it_came_from_test() {
  let #(model, _) = owner(Listed(one()))
  let html = drawn(model)
  assert string.contains(html, "Review the change")
  assert string.contains(html, "From session")
  assert string.contains(html, "0198c0de-0000-7000-8000-000000000001")
  assert string.contains(html, "Replaces text in loom-rules.md")
  assert string.contains(html, "diff-removed")
  assert string.contains(html, "Run make test.")
  assert string.contains(html, "diff-added")
  assert string.contains(html, "Run make check.")
}

pub fn an_append_draws_only_added_lines_test() {
  let #(model, _) =
    owner(
      Listed(board(
        [row("prop-0000000001", "pending", "", "Be brief.", "why")],
        1,
      )),
    )
  let html = drawn(model)
  assert string.contains(html, "Adds a rule to loom-rules.md")
  assert string.contains(html, "diff-added")
  assert !string.contains(html, "diff-removed")
}

pub fn many_rows_keep_their_order_and_only_a_pending_row_has_buttons_test() {
  let #(model, _) = owner(Listed(many()))
  let html = drawn(model)
  let assert Ok(#(_, section)) = string.split_once(html, "id=\"proposals\"")
    as "the Session pane holds the proposals section"
  let assert [_, after_three] = string.split(section, "prop-0000000003")
    as "prop-0000000003 appears once in the proposals section"
  let assert [three_to_two, after_two] =
    string.split(after_three, "prop-0000000002")
    as "prop-0000000002 follows prop-0000000003"
  let assert [two_to_one, _] = string.split(after_two, "prop-0000000001")
    as "prop-0000000001 follows prop-0000000002"
  assert string.contains(three_to_two, "Approve</button>")
  assert !string.contains(two_to_one, "Approve</button>")
  assert !string.contains(two_to_one, "Reject</button>")
  assert list.length(string.split(section, "Approve</button>")) == 2
}

pub fn a_stale_row_says_why_nothing_was_written_test() {
  let #(model, _) = owner(Listed(many()))
  let html = drawn(model)
  assert string.contains(html, "proposal-stale")
  assert string.contains(
    html,
    "Stale: loom-rules.md changed after this was proposed, so nothing was written.",
  )
  assert string.contains(html, "Approved and written to loom-rules.md.")
}

pub fn the_page_has_no_accent_bar_and_no_shadow_test() {
  let #(model, _) = owner(Listed(many()))
  let html = drawn(model)
  assert !string.contains(html, "box-shadow")
  assert !string.contains(html, "border-left")
}

// An unfamiliar kind or state is shown, not refused, and offers no button.
pub fn an_unknown_state_is_shown_without_buttons_test() {
  let odd =
    json.Object([
      #("id", json.String("prop-0000000009")),
      #("kind", json.String("config")),
      #("target", json.String("loom.toml")),
      #("base_digest", json.String("d")),
      #("old", json.String("")),
      #("new", json.String("x")),
      #("rationale", json.String("r")),
      #("source", json.Object([#("session", json.String("s"))])),
      #("created_ms", json.Int(1)),
      #("state", json.String("withdrawn")),
    ])
  let #(model, _) = owner(Listed(board([odd], 0)))
  let html = drawn(model)
  assert string.contains(html, "unknown (withdrawn)")
  assert string.contains(html, "proposal-unknown")
  assert !string.contains(html, "Approve</button>")
}

pub fn hostile_text_is_only_ever_text_test() {
  let hostile = "</li><script>alert(1)</script>\"onmouseover=\"x"
  let listed =
    board(
      [
        row(
          "prop-0000000001",
          "pending",
          "<b>old</b>",
          hostile,
          "<img src=x onerror=alert(2)>",
        ),
      ],
      1,
    )
  let #(model, _) = owner(Listed(listed))
  let html = drawn(model)
  assert !string.contains(html, "<script>")
  assert !string.contains(html, "<img")
  assert !string.contains(html, "<b>old")
  assert string.contains(html, "&lt;script&gt;")
  assert !string.contains(html, "onmouseover=\"x")
}

// --- errors ---------------------------------------------------------------------

pub fn a_refused_read_is_worded_and_replaces_the_loading_words_test() {
  let #(model, _) = owner(Refused("unsupported"))
  let html = drawn(model)
  assert string.contains(html, "This daemon keeps no proposal queue.")
  assert !string.contains(html, proposals.loading_words)
  assert component.proposals_kept(model) == None
}

pub fn a_forbidden_read_says_only_the_owner_may_review_test() {
  let #(model, _) = owner(Refused("forbidden"))
  assert string.contains(drawn(model), "Only the daemon&#39;s owner can review")
}

// --- approving ---------------------------------------------------------------

pub fn approving_is_two_presses_and_the_first_sends_nothing_test() {
  let #(model, wire) = owner(Listed(one()))
  let asked = send(model, [operator_page.AskingApproval("prop-0000000001")])
  assert page_fixture.commands(page_fixture.sent(wire)) == []
  let html = drawn(asked)
  assert string.contains(html, "Approve this rule?")
  assert string.contains(html, "loom-rules.md")
  assert string.contains(html, "AGENTS.md is never edited")
  assert string.contains(html, "Approve rule")
  assert string.contains(html, "Keep waiting")

  let kept = send(asked, [operator_page.CancellingApproval])
  assert page_fixture.commands(page_fixture.sent(wire)) == []
  assert !string.contains(drawn(kept), "Keep waiting")
}

pub fn the_confirm_sends_the_approval_the_question_armed_test() {
  let #(model, wire) = owner(Listed(one()))
  let _ =
    send(model, [
      operator_page.AskingApproval("prop-0000000001"),
      operator_page.ConfirmingApproval,
    ])
  let assert [frame] = page_fixture.commands(page_fixture.sent(wire))
    as "one approval is one command"
  assert string.contains(frame, "\"cmd\":\"proposal_decide\"")
  assert string.contains(frame, "\"id\":\"prop-0000000001\"")
  assert string.contains(frame, "\"decision\":\"approve\"")
}

pub fn a_confirm_with_no_question_open_changes_nothing_test() {
  let #(model, wire) = owner(Listed(one()))
  let _ = send(model, [operator_page.ConfirmingApproval])
  assert page_fixture.commands(page_fixture.sent(wire)) == []
}

pub fn asking_about_a_row_that_is_not_pending_opens_no_question_test() {
  let #(model, wire) = owner(Listed(many()))
  let asked = send(model, [operator_page.AskingApproval("prop-0000000002")])
  assert !string.contains(drawn(asked), "Approve this rule?")
  let _ = send(asked, [operator_page.ConfirmingApproval])
  assert page_fixture.commands(page_fixture.sent(wire)) == []
}

// The board moves between the press that opened the question and the press
// that confirms it: the confirm looks the row up in the board the page holds
// now, so a row someone else decided is not approved again.
pub fn a_row_decided_after_the_question_opened_is_not_approved_test() {
  let #(model, wire) = owner(Listed(one()))
  let asked = send(model, [operator_page.AskingApproval("prop-0000000001")])
  let settled =
    board([row("prop-0000000001", "approved", "Run make test.", "x", "y")], 0)
  let moved = pushed_board(asked, wire, settled)
  let _ = send(moved, [operator_page.ConfirmingApproval])
  assert list.all(page_fixture.commands(page_fixture.sent(wire)), fn(frame) {
    !string.contains(frame, "proposal_decide")
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
            "{\"v\":2,\"event\":\"proposals_changed\",\"body\":{}}",
          ),
        ]),
      ),
      operator_page.Observed(component.Ticked),
    ])
  let reads =
    list.filter(page_fixture.sent(wire), fn(frame) {
      string.contains(frame, "\"cmd\":\"proposals_get\"")
    })
  let assert [read] = reads as "one push is one read"
  send(model, [
    operator_page.Observed(
      component.Arrived([answer(page_fixture.request_id(read), listed)]),
    ),
  ])
}

pub fn rejecting_is_one_press_and_sends_a_reject_test() {
  let #(model, wire) = owner(Listed(one()))
  let _ = send(model, [operator_page.Rejecting("prop-0000000001")])
  let assert [frame] = page_fixture.commands(page_fixture.sent(wire))
  assert string.contains(frame, "\"cmd\":\"proposal_decide\"")
  assert string.contains(frame, "\"decision\":\"reject\"")
}

pub fn rejecting_a_row_that_is_not_pending_sends_nothing_test() {
  let #(model, wire) = owner(Listed(many()))
  let _ = send(model, [operator_page.Rejecting("prop-0000000002")])
  let _ = send(model, [operator_page.Rejecting("prop-9999999999")])
  assert page_fixture.commands(page_fixture.sent(wire)) == []
}

// The daemon answers a decision with the board as it now stands, and the page
// draws that, a stale answer included.
pub fn the_answer_to_a_decision_redraws_the_list_test() {
  let #(model, wire) = owner(Listed(one()))
  let model =
    send(model, [
      operator_page.AskingApproval("prop-0000000001"),
      operator_page.ConfirmingApproval,
    ])
  let assert [frame] = page_fixture.commands(page_fixture.sent(wire))
  let stale =
    board(
      [
        row(
          "prop-0000000001",
          "stale",
          "Run make test.",
          "Run make check.",
          "it failed twice",
        ),
      ],
      0,
    )
  let model =
    send(model, [
      operator_page.Observed(
        component.Arrived([answer(page_fixture.request_id(frame), stale)]),
      ),
    ])
  let html = drawn(model)
  assert string.contains(html, "proposal-stale")
  assert !string.contains(html, "Approve</button>")
  assert component.proposals_pending(model) == 0
}

// --- the push -----------------------------------------------------------------

pub fn a_proposals_changed_push_makes_the_page_read_again_test() {
  let #(model, wire) = owner(Listed(one()))
  let after =
    pushed_board(
      model,
      wire,
      board([row("prop-0000000005", "pending", "", "New rule.", "again")], 1),
    )
  let html = drawn(after)
  assert string.contains(html, "prop-0000000005")
  assert !string.contains(html, "prop-0000000001")
}

// --- who sees it ----------------------------------------------------------------

pub fn a_members_page_draws_no_pane_reads_nothing_and_sends_nothing_test() {
  let #(model, wire) = page_of(page_fixture.start(), Listed(one()))
  let html = drawn(model)
  assert !string.contains(html, "Proposals")
  assert !string.contains(html, "prop-0000000001")
  assert component.proposals_kept(model) == None
  assert component.proposals_pending(model) == 0
  assert !string.contains(html, "proposals=")
  let _ =
    send(model, [
      operator_page.AskingApproval("prop-0000000001"),
      operator_page.ConfirmingApproval,
      operator_page.Rejecting("prop-0000000001"),
    ])
  assert page_fixture.commands(page_fixture.sent(wire)) == []
  assert list.all(page_fixture.sent(wire), fn(frame) {
    !string.contains(frame, "proposals_get")
  })
}

pub fn an_observers_page_draws_no_pane_and_no_handler_there_test() {
  let model = component.new(page_fixture.start())
  let html = element.to_string(component.view(model))
  assert !string.contains(html, "Proposals")
  let keys = every_handler(component.view(model))
  assert list.filter(keys, fn(key) {
      string.starts_with(key, component.proposals_path)
    })
    == []
  assert !string.contains(html, "proposals=")
}

// --- the badge ---------------------------------------------------------------------

pub fn the_frame_carries_the_pending_count_only_for_the_owner_test() {
  let #(model, _) = owner(Listed(one()))
  assert string.contains(drawn(model), "proposals=\"1\"")
  let #(none, _) = owner(Listed(board([], 0)))
  assert !string.contains(drawn(none), "proposals=")
}

// --- where the handlers are --------------------------------------------------------

pub fn the_pane_is_the_eighth_child_of_the_session_pane_test() {
  assert component.proposals_path == "0\t3\t2\t7"
  let #(model, _) = owner(Listed(many()))
  let keys = every_handler(operator_page.view(model))
  let beneath =
    list.filter(keys, fn(key) {
      string.starts_with(key, component.proposals_path <> "\t")
    })

  // Only the pending row has handlers: Approve and Reject.
  assert list.length(beneath) == 2
  assert list.all(beneath, fn(key) { string.ends_with(key, "\nclick") })

  // The paths that already existed keep their places.
  assert component.invite_path == "0\t3\t2\t2"
  assert component.rename_path == "0\t3\t2\t4"
  assert component.remembered_path == "0\t3\t2\t5"
  assert component.peers_path == "0\t3\t2\t6"
  assert list.filter(keys, fn(key) {
      string.starts_with(key, component.peers_path)
    })
    == []
}

pub fn pending_proposals_render_as_inline_cards_in_the_dock_above_the_composer_test() {
  let #(model, _) = owner(Listed(many()))
  let html = drawn(model)
  let assert Ok(#(_, from_dock)) =
    string.split_once(html, "<footer class=\"dock\">")
    as "the page draws a dock"
  let assert Ok(#(dock, _)) = string.split_once(from_dock, "</footer>")
    as "the dock is closed"
  let assert Ok(#(above_composer, _)) =
    string.split_once(dock, "class=\"composer\"")
    as "the dock holds the composer"
  assert string.contains(above_composer, "class=\"approvals\"")
  assert string.contains(above_composer, "proposal-card")
  assert string.contains(above_composer, "prop-0000000003")
  assert string.contains(above_composer, "Keep commits small.")
  assert string.contains(above_composer, "Reject rule")
  assert string.contains(above_composer, "Approve rule…")
  assert !string.contains(above_composer, "prop-0000000002")
  assert !string.contains(above_composer, "prop-0000000001")
}
