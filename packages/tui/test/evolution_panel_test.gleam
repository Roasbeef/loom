//// The operator's evolution review (protocol-change/099): what a key does at
//// each place, how the list, a candidate, the question, the rollback chooser
//// and the core card draw, the footer badge, and the `/evolution` command that
//// opens it.
////
//// The panel tests drive the pure state machine against a board decoded from
//// the JSON the daemon sends, in the shape of `proposal_panel_test`. The
//// consent rules are the ones the approval dialog follows: no key sends
//// anything but a lowercase y on a question, the question holds what was
//// drawn when it was asked, and a row offers only what the board lets a
//// person do to it. The model tests open the overlay through the composer and
//// through a scripted virtual terminal and read the frames back as text.

import core/json
import etui/backend
import etui/buffer
import etui/geometry
import etui/keys
import etui/widgets/textarea
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import session_view/command
import session_view/connection_event
import session_view/evolution
import session_view/evolution_pending
import session_view/model as session_model
import session_view/shared_set
import session_view/worktree_view
import tui
import tui/connection
import tui/evolution_panel
import tui/frame
import tui/model as tui_model
import tui/render
import tui/view_set
import tui/virtual_backend
import tui/workspace

const now = 1_790_000_000_000

const session = "0198c0de-0000-7000-8000-000000000001"

// --- the board the daemon sends ---------------------------------------------

fn text(value: String) -> json.JsonValue {
  json.String(value)
}

fn evidence(id: String, verdict: String) -> json.JsonValue {
  json.Object([
    #("evidence_id", text(id)),
    #("purpose", text("author_tests")),
    #("verdict", text(verdict)),
    #("reason", text("")),
    #("at_ms", json.Int(now - 7_200_000)),
    #("identity_current", json.Bool(True)),
  ])
}

fn session_scope() -> json.JsonValue {
  json.Object([#("kind", text("session")), #("session", text(session))])
}

fn workspace_scope() -> json.JsonValue {
  json.Object([
    #("kind", text("workspace")),
    #("workspace", text("executor:gilgamesh/loom")),
  ])
}

fn candidate(
  id: String,
  name: String,
  kind: String,
  scope: json.JsonValue,
  parent: json.JsonValue,
  approval: json.JsonValue,
  selected: json.JsonValue,
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
      json.Object([#("session", text(session)), #("strand", text("main"))]),
    ),
    #("identity_current", json.Bool(True)),
    #("approval", approval),
    #("evidence", json.Array([evidence("e" <> id, "passed")])),
    #("selected", selected),
  ])
}

fn approved(id: String) -> json.JsonValue {
  json.Object([
    #("evidence_id", text("e" <> id)),
    #("by", text("owner")),
    #("via", text("web")),
  ])
}

fn chosen(generation: Int, id: String) -> json.JsonValue {
  json.Object([
    #("generation", json.Int(generation)),
    #("evidence_id", text("e" <> id)),
  ])
}

fn event(
  seq: Int,
  decision: String,
  id: String,
  generation: json.JsonValue,
) -> json.JsonValue {
  json.Object([
    #("seq", json.Int(seq)),
    #("at_ms", json.Int(now - 3_600_000 + seq)),
    #("event", text(decision)),
    #("candidate_id", text(id)),
    #("name", text("fmt_check")),
    #("generation", generation),
    #("principal", text("owner")),
    #("via", text("terminal")),
    #("reason", text("looked fine")),
    #("request_id", text("")),
  ])
}

// The live generation (aaaa1111, generation 3), a new candidate with passing
// tests and no approval (bbbb2222), an earlier approved generation (dddd4444,
// once generation 2), and an approved program that no one selected.
fn board_json(extra: List(json.JsonValue)) -> json.JsonValue {
  json.Object([
    #("version", json.Int(1)),
    #("session", text(session)),
    #(
      "candidates",
      json.Array(list.append(
        [
          candidate(
            "aaaa1111",
            "fmt_check",
            "extension",
            session_scope(),
            json.Null,
            approved("aaaa1111"),
            chosen(3, "aaaa1111"),
          ),
          candidate(
            "bbbb2222",
            "fmt_check",
            "extension",
            session_scope(),
            text("aaaa1111"),
            json.Null,
            json.Null,
          ),
          candidate(
            "dddd4444",
            "fmt_check",
            "extension",
            session_scope(),
            json.Null,
            approved("dddd4444"),
            json.Null,
          ),
          candidate(
            "cccc3333",
            "gleam_fix",
            "program",
            workspace_scope(),
            json.Null,
            approved("cccc3333"),
            json.Null,
          ),
        ],
        extra,
      )),
    ),
    #(
      "selections",
      json.Array([
        json.Object([
          #("scope", session_scope()),
          #("name", text("fmt_check")),
          #("candidate_id", text("aaaa1111")),
          #("evidence_id", text("eaaaa1111")),
          #("generation", json.Int(3)),
          #("published", json.Bool(True)),
        ]),
      ]),
    ),
    #("published", json.Null),
    #("pending", json.Array([])),
    #(
      "history",
      json.Array([
        event(43, "selected", "aaaa1111", json.Int(3)),
        event(42, "selected", "dddd4444", json.Int(2)),
        event(41, "approved", "dddd4444", json.Null),
      ]),
    ),
    #(
      "omitted",
      json.Object([#("candidates", json.Int(0)), #("history", json.Int(0))]),
    ),
  ])
}

fn the_board() -> evolution.Board {
  decoded(board_json([]))
}

fn decoded(value: json.JsonValue) -> evolution.Board {
  let assert Ok(board) = evolution.decode_board(value)
  board
}

// --- the panel's inputs -----------------------------------------------------

fn area() -> geometry.Rect {
  geometry.rect_new(0, 0, 100, 30)
}

fn facts(board: Option(evolution.Board)) -> evolution_panel.Facts {
  evolution_panel.Facts(
    board:,
    tracker: evolution_pending.new(),
    opened: None,
    notice: "",
    transport_ms: 1000,
    wall_ms: now,
  )
}

// A tracker holding one selection of this candidate that the daemon is
// running, begun at transport time 1000.
fn staging(candidate_id: String) -> evolution_pending.Tracker {
  let assert Ok(#(tracker, _)) =
    evolution_pending.begin(
      evolution_pending.new(),
      session,
      1000,
      candidate_id,
      "fmt_check",
    )
  let #(running, _) =
    evolution_pending.answered(
      tracker,
      evolution.InFlight(evolution.Running),
      1000,
    )
  running
}

fn paint(state: evolution_panel.State, with: evolution_panel.Facts) -> String {
  let screen = buffer.buffer_new(area())
  evolution_panel.render(screen, area(), state, with)
  |> frame.buffer_to_text
}

fn press(
  state: evolution_panel.State,
  with: evolution_panel.Facts,
  key: keys.Key,
) -> evolution_panel.Action {
  evolution_panel.update(key, state, with, area())
}

fn next(action: evolution_panel.Action) -> evolution_panel.State {
  let assert evolution_panel.Continue(state) = action
  state
}

// The panel opened on the candidate at this position of the list: the live
// extension is 0, the unapproved one 1, the earlier approved one 2.
fn open_row(
  with: evolution_panel.Facts,
  position: Int,
) -> evolution_panel.State {
  let moved =
    list.fold(list.repeat(Nil, position), evolution_panel.new(), fn(state, _) {
      next(press(state, with, keys.Down))
    })
  next(press(moved, with, keys.Enter))
}

// --- the list ---------------------------------------------------------------

pub fn the_list_groups_candidates_by_kind_with_their_state_test() {
  let screen = paint(evolution_panel.new(), facts(Some(the_board())))
  assert string.contains(screen, "Evolution · session 0198c0de")
  assert string.contains(screen, "LIVE fmt_check extension generation 3")
  assert string.contains(screen, "EXTENSIONS")
  assert string.contains(screen, "PROGRAMS")
  assert string.contains(screen, "PROMPTS")
  assert string.contains(screen, "(none)")
  assert string.contains(screen, "generation 3, live")
  assert string.contains(screen, "tests passed")
  assert string.contains(screen, "approved")
  assert string.contains(screen, "gleam_fix")
  assert string.contains(screen, "HISTORY")
  assert string.contains(screen, "selected fmt_check → generation 3")
  assert string.contains(screen, "CORE")
  assert string.contains(screen, "core_upgrade")
}

pub fn a_board_not_yet_read_says_so_test() {
  let screen = paint(evolution_panel.new(), facts(None))
  assert string.contains(screen, evolution.loading_words)
}

pub fn the_list_moves_and_asks_for_a_read_and_closes_test() {
  let with = facts(Some(the_board()))
  let down = next(press(evolution_panel.new(), with, keys.Down))
  assert string.contains(paint(down, with), "▸ fmt_check  bbbb2222")
  let end = next(press(evolution_panel.new(), with, keys.End))
  assert string.contains(paint(end, with), "▸ gleam_fix")
  let assert evolution_panel.Refresh =
    press(evolution_panel.new(), with, keys.Char("R"))
  let assert evolution_panel.Close =
    press(evolution_panel.new(), with, keys.Escape)
}

pub fn the_selected_row_stays_on_screen_in_a_short_panel_test() {
  let tall = list.index_map(list.repeat(Nil, 20), fn(_, index) { index + 1 })
  let extra =
    list.map(tall, fn(index) {
      candidate(
        "ffff" <> string.pad_start(string.inspect(index), 4, "0"),
        "later_" <> string.inspect(index),
        "extension",
        session_scope(),
        json.Null,
        json.Null,
        json.Null,
      )
    })
  let with = facts(Some(decoded(board_json(extra))))
  let end = next(press(evolution_panel.new(), with, keys.End))
  assert string.contains(paint(end, with), "▸ gleam_fix")
}

// --- a candidate ------------------------------------------------------------

pub fn a_candidate_opens_with_its_evidence_and_what_is_offered_test() {
  let with = facts(Some(the_board()))
  let reading = open_row(with, 1)
  let screen = paint(reading, with)
  assert string.contains(screen, "fmt_check · extension · tests passed")
  assert string.contains(screen, "candidate bbbb2222")
  assert string.contains(screen, "Applies to this session")
  assert string.contains(screen, "proposed from aaaa1111")
  assert string.contains(screen, "Runs the formatter before an edit lands.")
  assert string.contains(screen, "author tests · passed · 2h ago")
  assert string.contains(screen, "Not approved.")
  assert string.contains(screen, "a approve")
  assert !string.contains(screen, "s select")
  let assert evolution_panel.Continue(back) = press(reading, with, keys.Escape)
  assert evolution_panel.on_list(back)
  assert string.contains(paint(back, with), "▸ fmt_check  bbbb2222")
}

pub fn the_approved_live_candidate_offers_revoke_and_rollback_test() {
  let with = facts(Some(the_board()))
  let screen = paint(open_row(with, 0), with)
  assert string.contains(screen, "Approved by owner from the web")
  assert string.contains(screen, "r revoke")
  assert string.contains(screen, "b rollback")
  assert !string.contains(screen, "a approve")
  assert !string.contains(screen, "s select")
}

// --- the consent rules ------------------------------------------------------

pub fn approving_asks_and_only_y_sends_what_was_drawn_test() {
  let with = facts(Some(the_board()))
  let asked = next(press(open_row(with, 1), with, keys.Char("a")))
  assert evolution_panel.confirming(asked)
  let screen = paint(asked, with)
  assert string.contains(screen, "Approve fmt_check bbbb2222?")
  assert string.contains(screen, "Evidence ebbbb222")
  assert string.contains(screen, "y sends")
  let assert evolution_panel.Act(request, after) =
    press(asked, with, keys.Char("y"))
  assert request == evolution.Approve("bbbb2222", "ebbbb2222")
  assert !evolution_panel.confirming(after)
  assert !evolution_panel.on_list(after)
}

pub fn no_other_key_sends_from_a_question_test() {
  let with = facts(Some(the_board()))
  let asked = next(press(open_row(with, 1), with, keys.Char("a")))
  let others = [
    keys.Enter,
    keys.Char("Y"),
    keys.Char("n"),
    keys.Char("a"),
    keys.Char("s"),
    keys.Char(" "),
    keys.Escape,
    keys.Up,
    keys.PageDown,
    keys.Tab,
  ]
  list.each(others, fn(key) {
    let assert evolution_panel.Continue(after) = press(asked, with, key)
    assert !evolution_panel.confirming(after)
  })
}

pub fn a_row_offers_nothing_it_cannot_describe_test() {
  let with = facts(Some(the_board()))

  // The live candidate is already approved and already selected.
  let live = open_row(with, 0)
  assert !evolution_panel.confirming(next(press(live, with, keys.Char("a"))))
  assert !evolution_panel.confirming(next(press(live, with, keys.Char("s"))))

  // The new candidate has no approval to revoke, no approval to select on,
  // and is not the selected generation, so it has nothing to roll back.
  let proposed = open_row(with, 1)
  assert !evolution_panel.confirming(
    next(press(proposed, with, keys.Char("s"))),
  )
  assert !evolution_panel.confirming(
    next(press(proposed, with, keys.Char("r"))),
  )
  assert !evolution_panel.confirming(
    next(press(proposed, with, keys.Char("b"))),
  )
  assert !string.contains(paint(proposed, with), "b rollback")
}

pub fn a_kind_this_client_cannot_name_offers_no_change_test() {
  let strange =
    candidate(
      "eeee5555",
      "mystery",
      "wasm",
      session_scope(),
      json.Null,
      approved("eeee5555"),
      json.Null,
    )
  let with = facts(Some(decoded(board_json([strange]))))
  let reading = open_row(with, 4)
  let screen = paint(reading, with)
  assert string.contains(screen, "unknown (wasm)")
  assert !string.contains(screen, "a approve")
  assert !string.contains(screen, "s select")
  assert !string.contains(screen, "r revoke")
  list.each(
    [keys.Char("a"), keys.Char("s"), keys.Char("r"), keys.Char("b")],
    fn(key) {
      assert !evolution_panel.confirming(next(press(reading, with, key)))
    },
  )
}

pub fn a_selection_echoes_the_generation_that_was_drawn_test() {
  let drawn = facts(Some(the_board()))
  let asked = next(press(open_row(drawn, 2), drawn, keys.Char("s")))
  let screen = paint(asked, drawn)
  assert string.contains(screen, "Select dddd4444 as generation 4 of fmt_check")
  assert string.contains(screen, "replacing generation 3")
  assert string.contains(screen, "reason: selected from the terminal")

  // The board moves on while the question is open. The question still holds
  // what it asked about, so the daemon is the one that notices.
  let moved =
    facts(Some(
      evolution.Board(
        ..the_board(),
        selections: [],
        candidates: list.filter(the_board().candidates, fn(row) {
          row.candidate_id != "aaaa1111"
        }),
      ),
    ))
  let assert evolution_panel.Act(request, _) =
    press(asked, moved, keys.Char("y"))
  assert request
    == evolution.Select(
      candidate_id: "dddd4444",
      name: "fmt_check",
      evidence_id: "edddd4444",
      expected_generation: 3,
      reason: evolution_panel.select_reason,
    )
}

pub fn a_selection_is_not_offered_while_another_is_staging_test() {
  let busy =
    evolution_panel.Facts(
      ..facts(Some(the_board())),
      tracker: staging("bbbb2222"),
    )
  let reading = open_row(busy, 2)
  assert !string.contains(paint(reading, busy), "s select")
  assert !evolution_panel.confirming(next(press(reading, busy, keys.Char("s"))))

  // An approval is not a selection and is still offered.
  let proposed = open_row(busy, 1)
  assert string.contains(paint(proposed, busy), "a approve")
}

pub fn a_staging_selection_draws_on_its_row_and_in_its_detail_test() {
  let busy =
    evolution_panel.Facts(
      ..facts(Some(the_board())),
      tracker: staging("bbbb2222"),
    )
  let list_screen = paint(evolution_panel.new(), busy)
  assert string.contains(list_screen, "staging… 60 s")
  let detail = paint(open_row(busy, 1), busy)
  assert string.contains(detail, "fmt_check: staging, 60 s left")
}

pub fn a_revocation_asks_with_a_fixed_reason_test() {
  let with = facts(Some(the_board()))
  let asked = next(press(open_row(with, 2), with, keys.Char("r")))
  assert string.contains(
    paint(asked, with),
    "Revoke the approval of fmt_check dddd4444?",
  )
  let assert evolution_panel.Act(request, _) =
    press(asked, with, keys.Char("y"))
  assert request == evolution.Revoke("dddd4444", evolution_panel.revoke_reason)
}

pub fn a_rollback_chooses_an_earlier_generation_and_asks_test() {
  let with = facts(Some(the_board()))
  let chooser = next(press(open_row(with, 0), with, keys.Char("b")))
  let screen = paint(chooser, with)
  assert string.contains(screen, "dddd4444")
  assert string.contains(screen, "was generation 2")
  assert string.contains(screen, "Enter pick")
  let asked = next(press(chooser, with, keys.Enter))
  assert evolution_panel.confirming(asked)
  assert string.contains(
    paint(asked, with),
    "Roll back to dddd4444 as generation 4 of fmt_check, replacing generation 3",
  )
  let assert evolution_panel.Act(request, _) =
    press(asked, with, keys.Char("y"))
  assert request
    == evolution.Rollback(
      candidate_id: "dddd4444",
      name: "fmt_check",
      evidence_id: "edddd4444",
      expected_generation: 3,
      reason: evolution_panel.rollback_reason,
    )
  let assert evolution_panel.Continue(back) = press(chooser, with, keys.Escape)
  assert !evolution_panel.on_list(back)
}

// --- the core card ----------------------------------------------------------

pub fn the_core_card_reads_the_status_and_never_offers_an_upgrade_test() {
  let with = facts(Some(the_board()))
  let assert evolution_panel.Act(request, card) =
    press(evolution_panel.new(), with, keys.Char("c"))
  assert request == evolution.CoreStatus
  assert string.contains(paint(card, with), "Reading the core status")
  let status =
    json.Object([
      #("component", text("scratch")),
      #("version", text("0.3.0")),
      #("state", json.Object([#("version", json.Int(2))])),
    ])
  let read =
    evolution_panel.Facts(
      ..with,
      opened: Some(evolution.Opened(
        action: "core_status",
        page: evolution.Whole(status),
      )),
    )
  let screen = paint(card, read)
  assert string.contains(screen, "component: scratch")
  assert string.contains(screen, "version: 0.3.0")
  assert string.contains(screen, "state.version: 2")
  assert string.contains(screen, "core_upgrade")
  assert !string.contains(screen, "core_downgrade")
  let assert evolution_panel.Continue(list_again) =
    press(card, with, keys.Escape)
  assert evolution_panel.on_list(list_again)
}

pub fn another_pages_envelope_is_not_drawn_as_the_core_status_test() {
  let with =
    evolution_panel.Facts(
      ..facts(Some(the_board())),
      opened: Some(evolution.Opened(
        action: "inspect",
        page: evolution.Whole(json.Object([#("secret", text("not core"))])),
      )),
    )
  let assert evolution_panel.Act(_, card) =
    press(evolution_panel.new(), with, keys.Char("c"))
  assert !string.contains(paint(card, with), "not core")
}

// --- totality and hostile text ----------------------------------------------

pub fn every_key_works_from_every_state_test() {
  let every = [
    keys.Escape,
    keys.Enter,
    keys.Up,
    keys.Down,
    keys.PageUp,
    keys.PageDown,
    keys.Home,
    keys.End,
    keys.Tab,
    keys.Backspace,
    keys.Char("a"),
    keys.Char("b"),
    keys.Char("c"),
    keys.Char("d"),
    keys.Char("n"),
    keys.Char("r"),
    keys.Char("R"),
    keys.Char("s"),
    keys.Char("y"),
    keys.Char("Y"),
    keys.Char("é"),
    keys.Ctrl("x"),
    keys.Alt("p"),
  ]
  let boards = [None, Some(the_board()), Some(decoded(json.Object([])))]
  list.each(boards, fn(board) {
    let with = facts(board)
    let places = [
      evolution_panel.new(),
      open_row(with, 0),
      open_row(with, 1),
      next(press(open_row(with, 0), with, keys.Char("b"))),
      next(press(open_row(with, 1), with, keys.Char("a"))),
      next(press(open_row(with, 2), with, keys.Char("s"))),
    ]
    list.each(places, fn(state) {
      list.each(every, fn(key) {
        let _ = press(state, with, key)
        let _ = paint(state, with)
        Nil
      })
    })
  })
}

pub fn text_a_model_wrote_is_drawn_as_text_test() {
  let hostile =
    candidate(
      "ffff6666",
      "bad\u{1b}[31mname",
      "extension",
      session_scope(),
      json.Null,
      json.Null,
      json.Null,
    )
  let with = facts(Some(decoded(board_json([hostile]))))
  assert !string.contains(paint(evolution_panel.new(), with), "\u{1b}")
  let reading = open_row(with, 3)
  assert !string.contains(paint(reading, with), "\u{1b}")
}

// --- the command, the badge and the model -----------------------------------

fn model() -> tui_model.Model {
  tui.new_model(connection.new_inbox(), workspace.Context("/work", None))
}

fn with_board(board: Option(evolution.Board)) -> tui_model.Model {
  let base = model()
  tui_model.Model(
    ..base,
    shared: base.shared
      |> shared_set.session(session)
      |> shared_set.evolution(board),
  )
}

fn painted(model: tui_model.Model) -> String {
  let model = tui.update(backend.Resize(120, 30), model)
  let #(drawn, _) = render.view(model, geometry.rect_new(0, 0, 120, 30))
  frame.buffer_to_text(drawn)
}

fn typing(model: tui_model.Model, words: String) -> tui_model.Model {
  tui_model.Model(
    ..model,
    view: view_set.input(model.view, textarea.state_from_string(words)),
  )
}

pub fn the_command_is_parsed_suggested_and_in_the_help_test() {
  assert command.parse("/evolution") == command.Surface(command.Evolution)
  assert string.contains(command.help_text(), "/evolution")
  assert list.any(command.suggestions("/evo"), fn(suggestion) {
    suggestion.command == "/evolution"
  })
}

pub fn the_command_opens_the_overlay_and_asks_for_a_fresh_board_test() {
  let opened =
    tui.update(
      backend.KeyPress("enter"),
      typing(with_board(Some(the_board())), "/evolution"),
    )
  let assert tui_model.EvolutionReview(_) = opened.view.overlay
  assert opened.shared.evolution_refresh == worktree_view.Requested
  let screen = painted(opened)
  assert string.contains(screen, "EXTENSIONS")
  assert string.contains(screen, "fmt_check")
  let closed = tui.update(backend.KeyPress("esc"), opened)
  assert closed.view.overlay == tui_model.NoOverlay
}

pub fn the_overlay_is_watched_exactly_while_it_is_open_test() {
  let closed = with_board(Some(the_board()))
  assert tui.update(backend.Tick, closed).shared.evolution_watch
    == session_model.NotWatchingEvolution
  let opened =
    tui.update(backend.KeyPress("enter"), typing(closed, "/evolution"))
  assert tui.update(backend.Tick, opened).shared.evolution_watch
    == session_model.WatchingEvolution
  let left = tui.update(backend.KeyPress("esc"), opened)
  assert tui.update(backend.Tick, left).shared.evolution_watch
    == session_model.NotWatchingEvolution
}

pub fn the_terminal_claims_the_terminal_surface_test() {
  assert model().shared.evolution_via == evolution.ClaimsTerminal
}

pub fn the_footer_shows_the_badge_only_when_something_waits_test() {
  assert string.contains(
    painted(with_board(Some(the_board()))),
    "evolution 1 · /evolution",
  )
  assert !string.contains(painted(with_board(None)), "evolution 1")
  let settled =
    evolution.Board(
      ..the_board(),
      candidates: list.filter(the_board().candidates, fn(row) {
        row.candidate_id != "bbbb2222"
      }),
    )
  assert !string.contains(painted(with_board(Some(settled))), "/evolution")
}

pub fn a_board_for_another_session_is_never_drawn_test() {
  let base = with_board(Some(the_board()))
  let elsewhere =
    tui_model.Model(
      ..base,
      shared: shared_set.session(
        base.shared,
        "0198ffff-0000-7000-8000-000000000009",
      ),
    )
  assert !string.contains(painted(elsewhere), "/evolution")
  let opened =
    tui.update(backend.KeyPress("enter"), typing(elsewhere, "/evolution"))
  let screen = painted(opened)
  assert string.contains(screen, evolution.loading_words)
  assert !string.contains(screen, "EXTENSIONS")
}

pub fn a_confirmed_change_without_a_lane_is_refused_in_the_overlay_test() {
  let opened =
    tui.update(
      backend.KeyPress("enter"),
      typing(with_board(Some(the_board())), "/evolution"),
    )
  let steps = ["down", "enter", "a", "y"]
  let sent =
    list.fold(steps, opened, fn(model, key) {
      tui.update(backend.KeyPress(key), model)
    })
  assert sent.shared.evolution_notice == "No conversation is attached."
  let assert tui_model.EvolutionReview(_) = sent.view.overlay
  assert string.contains(painted(sent), "No conversation is attached.")
}

pub fn a_board_that_arrives_replaces_what_the_open_overlay_shows_test() {
  let opened =
    tui.update(
      backend.KeyPress("enter"),
      typing(with_board(Some(the_board())), "/evolution"),
    )
  let renamed =
    candidate(
      "aaaa1111",
      "fmt_renamed",
      "extension",
      session_scope(),
      json.Null,
      approved("aaaa1111"),
      chosen(3, "aaaa1111"),
    )
  let replaced =
    tui_model.Model(
      ..opened,
      shared: shared_set.evolution(
        opened.shared,
        Some(decoded(board_json([renamed]))),
      ),
    )
  assert string.contains(painted(replaced), "fmt_renamed")
}

// --- a scripted terminal ----------------------------------------------------

fn keystroke(name: String) -> virtual_backend.Step {
  virtual_backend.Input(backend.KeyPress(name))
}

fn typed(words: String) -> List(virtual_backend.Step) {
  words |> string.to_graphemes |> list.map(keystroke)
}

// A scripted run of the real loop over a seeded model: the last frame it drew
// as text and the model it ended with.
fn scripted(steps: List(virtual_backend.Step)) -> #(String, tui_model.Model) {
  let inbox: process.Subject(connection_event.Message) = process.new_subject()
  let base = tui.new_model(inbox, workspace.Context("/work", None))
  let seeded =
    tui_model.Model(
      ..base,
      shared: base.shared
        |> shared_set.session(session)
        |> shared_set.evolution(Some(the_board())),
    )
  let script =
    virtual_backend.script(
      backend.TerminalSize(width: 100, height: 32),
      steps,
      inbox,
    )
  let assert Ok(run) = tui.run_script(seeded, script)
  let assert Ok(last) = list.last(list.map(run.frames, frame.buffer_to_text))
  #(last, run.final)
}

pub fn a_scripted_run_opens_the_overlay_on_the_list_test() {
  let #(screen, final) =
    scripted(list.append(typed("/evolution"), [keystroke("enter")]))
  assert string.contains(screen, "Evolution · session 0198c0de")
  assert string.contains(screen, "EXTENSIONS")
  assert string.contains(screen, "▸ fmt_check  aaaa1111")
  assert string.contains(screen, "generation 3, live")
  assert string.contains(screen, "evolution 1 · /evolution")
  let assert tui_model.EvolutionReview(_) = final.view.overlay
}

pub fn a_scripted_run_walks_to_a_candidate_and_asks_test() {
  let #(screen, final) =
    scripted(
      list.flatten([
        typed("/evolution"),
        [keystroke("enter"), keystroke("down"), keystroke("enter")],
        [keystroke("a")],
      ]),
    )
  assert string.contains(screen, "candidate bbbb2222")
  assert string.contains(screen, "Approve fmt_check bbbb2222?")
  assert string.contains(screen, "y sends")
  let assert tui_model.EvolutionReview(state) = final.view.overlay
  assert evolution_panel.confirming(state)
  assert final.shared.evolution_notice == ""
}

pub fn a_scripted_run_that_declines_the_question_sends_nothing_test() {
  let #(screen, final) =
    scripted(
      list.flatten([
        typed("/evolution"),
        [keystroke("enter"), keystroke("down"), keystroke("enter")],
        [keystroke("a"), keystroke("n")],
      ]),
    )
  assert !string.contains(screen, "Approve fmt_check bbbb2222?")
  assert final.shared.evolution_notice == ""
  let assert tui_model.EvolutionReview(state) = final.view.overlay
  assert !evolution_panel.confirming(state)
}
