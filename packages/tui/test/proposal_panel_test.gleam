//// The owner's review of proposed standing rules (protocol-change/086): what
//// a key does at each place, how the list and a proposal draw, the diff's
//// colours, the footer badge and the key that opens the review.

import core/json
import etui/backend
import etui/buffer
import etui/geometry
import etui/keys
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import session_view/proposals
import session_view/protocol
import session_view/session_channel
import session_view/shared_set
import session_view/worktree_view
import tui
import tui/connection
import tui/frame
import tui/inbound
import tui/model as tui_model
import tui/proposal_panel
import tui/render
import tui/theme
import tui/workspace

const now = 1_790_000_000_000

fn row(id: String, state: String, old: String, new: String) -> json.JsonValue {
  json.Object([
    #("id", json.String(id)),
    #("kind", json.String("rule")),
    #("target", json.String("loom-rules.md")),
    #("base_digest", json.String("cbf29ce484222325-0")),
    #("old", json.String(old)),
    #("new", json.String(new)),
    #("rationale", json.String("it failed twice\nand then again")),
    #(
      "source",
      json.Object([
        #("session", json.String("0198c0de-0000-7000-8000-000000000001")),
      ]),
    ),
    #("created_ms", json.Int(now - 7_200_000)),
    #("state", json.String(state)),
  ])
}

fn board(rows: List(json.JsonValue), pending: Int) -> proposals.Board {
  let assert Ok(decoded) =
    proposals.decode(
      json.Object([
        #("proposals", json.Array(rows)),
        #("pending", json.Int(pending)),
        #("limit", json.Int(64)),
      ]),
    )
  decoded
}

fn two() -> proposals.Board {
  board(
    [
      row("prop-0000000002", "pending", "Run make test.", "Run make check."),
      row("prop-0000000001", "stale", "", "Keep commits small."),
    ],
    1,
  )
}

fn area() -> geometry.Rect {
  geometry.rect_new(0, 0, 100, 24)
}

fn paint(
  state: proposal_panel.State,
  board: Option(proposals.Board),
  notice: String,
) -> String {
  let screen = buffer.buffer_new(geometry.rect_new(0, 0, 100, 24))
  proposal_panel.render(screen, area(), state, board, notice, now)
  |> frame.buffer_to_text
}

fn press(
  state: proposal_panel.State,
  board: Option(proposals.Board),
  key: keys.Key,
) -> proposal_panel.Action {
  proposal_panel.update(key, state, board, area())
}

fn next(action: proposal_panel.Action) -> proposal_panel.State {
  let assert proposal_panel.Continue(state) = action
  state
}

fn open_first(board: Option(proposals.Board)) -> proposal_panel.State {
  next(press(proposal_panel.new(), board, keys.Enter))
}

pub fn the_list_shows_each_row_newest_first_with_its_facts_test() {
  let text = paint(proposal_panel.new(), Some(two()), "")
  assert string.contains(text, "Proposals · 1 proposal pending")
  assert string.contains(
    text,
    "prop-0000000002  2h ago  pending  it failed twice",
  )
  assert string.contains(text, "prop-0000000001  2h ago  stale")
  assert string.contains(text, "0198c0de")
  let first = string.split(text, "prop-0000000002")
  assert list.length(first) == 2
  assert string.contains(text, "▸ prop-0000000002")
}

pub fn a_board_that_left_rows_out_says_how_many_test() {
  let assert Ok(left_out) =
    proposals.decode(
      json.Object([
        #("proposals", json.Array([row("prop-0000000001", "stale", "", "x")])),
        #("pending", json.Int(0)),
        #("limit", json.Int(64)),
        #("omitted", json.Int(5)),
      ]),
    )
  assert string.contains(
    paint(proposal_panel.new(), Some(left_out), ""),
    "5 older proposals not shown",
  )
  assert !string.contains(
    paint(proposal_panel.new(), Some(two()), ""),
    "not shown",
  )
}

pub fn an_empty_board_says_what_a_proposal_is_for_test() {
  let text = paint(proposal_panel.new(), Some(board([], 0)), "")
  assert string.contains(text, "No proposals.")
  assert string.contains(text, "worth keeping")
}

pub fn an_unread_board_is_loading_and_a_refusal_is_worded_test() {
  assert string.contains(
    paint(proposal_panel.new(), None, ""),
    proposals.loading_words,
  )
  let refused =
    paint(proposal_panel.new(), None, proposals.refusal_words("forbidden", ""))
  assert string.contains(refused, "Only the daemon's owner can review")
}

pub fn the_cursor_moves_and_stops_at_each_end_test() {
  let board = Some(two())
  let down = next(press(proposal_panel.new(), board, keys.Down))
  assert string.contains(paint(down, board, ""), "▸ prop-0000000001")
  let still = next(press(down, board, keys.Down))
  assert string.contains(paint(still, board, ""), "▸ prop-0000000001")
  let up = next(press(still, board, keys.Up))
  assert string.contains(paint(up, board, ""), "▸ prop-0000000002")
  let end = next(press(proposal_panel.new(), board, keys.End))
  assert string.contains(paint(end, board, ""), "▸ prop-0000000001")
}

pub fn enter_opens_the_row_and_shows_the_edit_and_the_sentence_test() {
  let board = Some(two())
  let text = paint(open_first(board), board, "")
  assert string.contains(text, "prop-0000000002 · pending · 2h ago")
  assert string.contains(
    text,
    "From session 0198c0de-0000-7000-8000-000000000001",
  )
  assert string.contains(text, "it failed twice")
  assert string.contains(text, "Replaces text in loom-rules.md")
  assert string.contains(text, "- Run make test.")
  assert string.contains(text, "+ Run make check.")
  assert string.contains(text, "Applies to new sessions only.")
  assert string.contains(text, "a approve · r reject")
}

pub fn removed_text_is_red_and_added_text_is_green_test() {
  let board = Some(two())
  let drawn =
    proposal_panel.render(
      buffer.buffer_new(area()),
      area(),
      open_first(board),
      board,
      "",
      now,
    )
  let rows = string.split(frame.buffer_to_text(drawn), "\n")
  let removed = cell_of(drawn, rows, "- Run make test.")
  assert removed.style.fg == theme.danger
  assert removed.style.bg == theme.removed_bg
  let added = cell_of(drawn, rows, "+ Run make check.")
  assert added.style.fg == theme.added
  assert added.style.bg == theme.added_bg
}

// The cell under the first character of the row that holds `words`.
fn cell_of(
  drawn: buffer.Buffer,
  rows: List(String),
  words: String,
) -> buffer.Cell {
  let assert Ok(#(y, line)) =
    rows
    |> list.index_map(fn(line, y) { #(y, line) })
    |> list.find(fn(pair) { string.contains(pair.1, words) })
  let assert [before, ..] = string.split(line, words)
  buffer.get_cell(drawn, geometry.Position(string.length(before), y))
}

pub fn an_append_has_no_removed_line_test() {
  let board =
    Some(board([row("prop-0000000003", "pending", "", "Be brief.")], 1))
  let text = paint(open_first(board), board, "")
  assert string.contains(text, "Adds a rule to loom-rules.md")
  assert string.contains(text, "+ Be brief.")
  assert !string.contains(text, "- Be brief.")
}

pub fn approval_takes_two_presses_and_only_y_sends_test() {
  let board = Some(two())
  let opened = open_first(board)
  let asking = next(press(opened, board, keys.Char("a")))
  let text = paint(asking, board, "")
  assert string.contains(text, "Approve this rule?")
  assert string.contains(text, "loom-rules.md")
  assert string.contains(text, "AGENTS.md is never edited")
  assert string.contains(text, "y approve · n or Esc go back")
  let assert proposal_panel.Decide("prop-0000000002", proposals.Approve) =
    press(asking, board, keys.Char("y"))
  assert string.contains(
    paint(next(press(asking, board, keys.Escape)), board, ""),
    "a approve · r reject",
  )
  assert string.contains(
    paint(next(press(asking, board, keys.Char("x"))), board, ""),
    "Approve this rule?",
  )
}

pub fn reject_is_one_press_test() {
  let board = Some(two())
  let assert proposal_panel.Decide("prop-0000000002", proposals.Reject) =
    press(open_first(board), board, keys.Char("r"))
}

pub fn a_stale_row_shows_its_state_and_offers_no_action_test() {
  let board = Some(two())
  let stale =
    next(press(
      next(press(proposal_panel.new(), board, keys.Down)),
      board,
      keys.Enter,
    ))
  let text = paint(stale, board, "")
  assert string.contains(text, "prop-0000000001 · stale")
  assert string.contains(text, "loom-rules.md changed after this was proposed")
  assert !string.contains(text, "a approve")
  let assert proposal_panel.Continue(_) = press(stale, board, keys.Char("a"))
  let assert proposal_panel.Continue(_) = press(stale, board, keys.Char("r"))
}

pub fn a_row_that_is_gone_after_a_read_says_so_test() {
  let board = Some(two())
  let opened = open_first(board)
  let text = paint(opened, Some(board_without_rows()), "")
  assert string.contains(text, "no longer listed")
  let assert proposal_panel.Continue(_) =
    press(opened, Some(board_without_rows()), keys.Char("a"))
}

fn board_without_rows() -> proposals.Board {
  board([], 0)
}

pub fn escape_goes_back_to_the_list_then_closes_test() {
  let board = Some(two())
  let back = next(press(open_first(board), board, keys.Escape))
  assert proposal_panel.on_list(back)
  let assert proposal_panel.Close = press(back, board, keys.Escape)
}

pub fn r_on_the_list_reads_again_test() {
  let assert proposal_panel.Refresh =
    press(proposal_panel.new(), Some(two()), keys.Char("r"))
}

pub fn a_decision_leaves_the_reader_on_the_proposal_test() {
  let board = Some(two())
  let after =
    proposal_panel.after_decision(open_first(board), "prop-0000000002")
  assert !proposal_panel.on_list(after)
}

pub fn the_badge_is_blank_until_something_waits_test() {
  assert proposal_panel.badge(None) == ""
  assert proposal_panel.badge(Some(board([], 0))) == ""
  assert proposal_panel.badge(Some(board([], 3))) == "proposals 3 · Alt+p"
}

pub fn a_hostile_rationale_cannot_leave_its_row_test() {
  let hostile = row("prop-0000000004", "pending", "", "rule")
  let assert json.Object(fields) = hostile
  let hostile =
    json.Object(
      list.map(fields, fn(field) {
        case field.0 {
          "rationale" -> #("rationale", json.String("one\u{1b}[31mtwo\nthree"))
          _ -> field
        }
      }),
    )
  let board = Some(board([hostile], 1))
  let text = paint(proposal_panel.new(), board, "")
  assert !string.contains(text, "\u{1b}")
}

fn model() -> tui_model.Model {
  tui.new_model(connection.new_inbox(), workspace.Context("/work", None))
}

fn with_board(board: Option(proposals.Board)) -> tui_model.Model {
  let base = model()
  tui_model.Model(..base, shared: shared_set.proposals(base.shared, board))
}

fn painted(model: tui_model.Model) -> String {
  let model = tui.update(backend.Resize(120, 30), model)
  let #(drawn, _) = render.view(model, geometry.rect_new(0, 0, 120, 30))
  frame.buffer_to_text(drawn)
}

pub fn the_footer_shows_the_badge_only_when_something_waits_test() {
  assert string.contains(
    painted(with_board(Some(two()))),
    "proposals 1 · Alt+p",
  )
  assert !string.contains(painted(with_board(Some(board([], 0)))), "proposals")
  assert !string.contains(painted(with_board(None)), "proposals")
}

pub fn alt_p_opens_the_review_and_asks_for_a_fresh_board_test() {
  let opened = tui.update(backend.KeyPress("alt+p"), with_board(Some(two())))
  let assert tui_model.ProposalReview(_) = opened.view.overlay
  assert opened.shared.proposals_refresh == worktree_view.Requested
  assert string.contains(painted(opened), "prop-0000000002")
}

pub fn the_review_opens_a_proposal_and_escape_closes_it_test() {
  let opened = tui.update(backend.KeyPress("alt+p"), with_board(Some(two())))
  let reading = tui.update(backend.KeyPress("enter"), opened)
  assert string.contains(painted(reading), "- Run make test.")
  let list_again = tui.update(backend.KeyPress("esc"), reading)
  let assert tui_model.ProposalReview(_) = list_again.view.overlay
  let closed = tui.update(backend.KeyPress("esc"), list_again)
  assert closed.view.overlay == tui_model.NoOverlay
}

pub fn a_refusal_the_lane_kept_is_drawn_in_the_review_test() {
  let base = with_board(None)
  let refused =
    tui_model.Model(
      ..base,
      shared: shared_set.proposals_notice(
        base.shared,
        proposals.refusal_words("unsupported", ""),
      ),
    )
  let text = painted(tui.update(backend.KeyPress("alt+p"), refused))
  // Opening asks again and clears the old words, so the reader never sees a
  // refusal that predates the question they just asked.
  assert !string.contains(text, "keeps no proposal queue")
  assert string.contains(text, proposals.loading_words)
}

fn arrived(model: tui_model.Model, event: protocol.Event) -> tui_model.Model {
  inbound.apply_channel_update(model, session_channel.Auxiliary(event))
}

pub fn a_board_that_arrives_draws_the_badge_and_one_that_empties_removes_it_test() {
  let first = model()
  assert !string.contains(painted(first), "proposals")
  let with = arrived(first, protocol.ProposalsSnapshot(two()))
  assert string.contains(painted(with), "proposals 1 · Alt+p")
  let emptied = arrived(with, protocol.ProposalsSnapshot(board([], 0)))
  assert !string.contains(painted(emptied), "proposals")
}

pub fn the_push_owes_a_read_and_a_board_replaces_what_the_open_review_shows_test() {
  let opened = tui.update(backend.KeyPress("alt+p"), with_board(Some(two())))
  let owed = arrived(opened, protocol.ProposalsChanged)
  assert owed.shared.proposals_refresh == worktree_view.Requested
  let decided =
    arrived(
      tui.update(backend.KeyPress("enter"), owed),
      protocol.ProposalsSnapshot(board(
        [
          row(
            "prop-0000000002",
            "approved",
            "Run make test.",
            "Run make check.",
          ),
        ],
        0,
      )),
    )
  let text = painted(decided)
  assert string.contains(text, "prop-0000000002 · approved")
  assert string.contains(text, "Approved and written to loom-rules.md.")
  assert !string.contains(text, "a approve")
}

pub fn a_refused_read_is_drawn_in_the_open_review_test() {
  let base = with_board(None)
  let opened = tui.update(backend.KeyPress("alt+p"), base)
  let refused =
    inbound.apply_channel_update(
      opened,
      session_channel.RequestRefused("proposals_get", 4, "forbidden", "no"),
    )
  assert string.contains(painted(refused), "Only the daemon's owner can review")
  assert !string.contains(painted(refused), "proposals 1")
}
