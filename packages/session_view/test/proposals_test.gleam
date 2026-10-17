//// The standing-rule proposals, as a client reads them: the board's total
//// decoder, the words both hosts use for a row, the two commands, and what
//// the shared record does with the snapshot, the push and a refusal
//// (protocol-change/086).

import core/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import session_view/diff_view
import session_view/event_fold
import session_view/inbox
import session_view/lane_fold
import session_view/model.{type Shared} as session_model
import session_view/msg
import session_view/proposals
import session_view/protocol
import session_view/session_channel
import session_view/step
import session_view/worktree_view

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

fn snapshot_frame(board: json.JsonValue) -> String {
  json.to_string(
    json.Object([
      #("v", json.Int(2)),
      #("reply_to", json.Int(9)),
      #("event", json.String("snapshot")),
      #(
        "body",
        json.Object([
          #("mode", json.String("proposals")),
          #("board", board),
        ]),
      ),
    ]),
  )
}

pub fn a_board_decodes_every_field_of_every_row_test() {
  let assert Ok(decoded) =
    proposals.decode(board(
      [
        row("prop-0000000001", "pending", "", "Run make check."),
        row("prop-0000000002", "stale", "old text", "new text"),
      ],
      1,
    ))
  assert decoded.pending == 1
  assert decoded.limit == 64
  let assert [first, second] = decoded.proposals
  assert first.id == "prop-0000000001"
  assert first.kind == proposals.Rule
  assert first.target == "loom-rules.md"
  assert first.state == proposals.Pending
  assert first.old == ""
  assert first.source.entry == Some("0198c0de-0000-7000-8000-000000000003")
  assert first.created_ms == 1_790_000_000_000
  assert second.state == proposals.Stale
  assert proposals.decidable(first)
  assert !proposals.decidable(second)
}

pub fn an_empty_board_is_a_board_test() {
  let assert Ok(decoded) = proposals.decode(board([], 0))
  assert decoded.proposals == []
}

pub fn an_unknown_kind_and_state_are_kept_and_offer_no_action_test() {
  let odd =
    json.Object([
      #("id", json.String("prop-0000000003")),
      #("kind", json.String("config")),
      #("target", json.String("loom.toml")),
      #("base_digest", json.String("d")),
      #("old", json.String("")),
      #("new", json.String("x")),
      #("rationale", json.String("why")),
      #("source", json.Object([#("session", json.String("s"))])),
      #("created_ms", json.Int(1)),
      #("state", json.String("withdrawn")),
    ])
  let assert Ok(decoded) = proposals.decode(board([odd], 0))
  let assert [only] = decoded.proposals
  assert only.kind == proposals.Unrecognized("config")
  assert only.state == proposals.Other("withdrawn")
  assert only.source.entry == None
  assert !proposals.decidable(only)
  assert string.contains(proposals.state_words(only.state), "withdrawn")
}

pub fn a_malformed_board_is_an_error_and_never_a_crash_test() {
  assert proposals.decode(json.Null) |> result.is_error
  assert proposals.decode(json.Object([])) |> result.is_error
  assert proposals.decode(
      json.Object([
        #("proposals", json.String("x")),
        #("pending", json.Int(0)),
        #("limit", json.Int(1)),
      ]),
    )
    |> result.is_error
  assert proposals.decode(
      json.Object([
        #("proposals", json.Array([])),
        #("pending", json.Int(-1)),
        #("limit", json.Int(1)),
      ]),
    )
    |> result.is_error
  assert proposals.decode(
      json.Object([#("proposals", json.Array([])), #("pending", json.Int(0))]),
    )
    |> result.is_error
  assert proposals.decode(board([json.Array([])], 0)) |> result.is_error
  assert proposals.decode(board([json.Object([])], 0)) |> result.is_error
}

pub fn a_row_missing_one_required_field_is_an_error_test() {
  let assert json.Object(fields) = row("prop-0000000001", "pending", "", "x")
  list.each(
    [
      "id",
      "kind",
      "target",
      "base_digest",
      "old",
      "new",
      "rationale",
      "source",
      "created_ms",
      "state",
    ],
    fn(name) {
      let without = list.filter(fields, fn(pair) { pair.0 != name })
      assert proposals.decode(board([json.Object(without)], 0))
        |> result.is_error
        as name
    },
  )
}

pub fn a_longer_board_than_the_bound_is_cut_not_refused_test() {
  let rows =
    list.repeat(
      row("prop-0000000001", "approved", "", "x"),
      proposals.row_limit + 30,
    )
  let assert Ok(decoded) = proposals.decode(board(rows, 0))
  assert list.length(decoded.proposals) == proposals.row_limit
}

// `omitted` is additive: a board without it, which is every board a daemon
// that predates it sends, decodes as one that left nothing out.
pub fn a_board_without_omitted_decodes_as_none_left_out_test() {
  let assert Ok(decoded) = proposals.decode(board([], 0))
  assert decoded.omitted == 0
}

pub fn a_board_reports_how_many_rows_the_daemon_left_out_test() {
  let assert json.Object(fields) = board([], 0)
  let assert Ok(decoded) =
    proposals.decode(
      json.Object(list.append(fields, [#("omitted", json.Int(7))])),
    )
  assert decoded.omitted == 7
  let assert Error(_) =
    proposals.decode(
      json.Object(list.append(fields, [#("omitted", json.Int(-1))])),
    )
  let assert Error(_) =
    proposals.decode(
      json.Object(list.append(fields, [#("omitted", json.String("7"))])),
    )
}

pub fn the_omitted_line_says_how_many_older_rows_are_not_shown_test() {
  assert proposals.omitted_words(0) == None
  assert proposals.omitted_words(1) == Some("1 older proposal not shown")
  assert proposals.omitted_words(12) == Some("12 older proposals not shown")
}

pub fn row_text_cannot_carry_a_terminal_escape_into_a_single_line_field_test() {
  let assert Ok(decoded) =
    proposals.decode(board(
      [row("prop-0000000001\nx", "pending", "", "a\r\nb")],
      1,
    ))
  let assert [only] = decoded.proposals
  assert !string.contains(only.id, "\n")
  assert !string.contains(only.new, "\r")
}

pub fn the_headline_is_the_first_line_cut_to_the_width_test() {
  assert proposals.headline("it failed twice\nand then again", 40)
    == "it failed twice"
  assert proposals.headline("abcdefghij", 5) == "abcd…"
  assert proposals.headline("  \n ", 5) == "(no rationale given)"
}

pub fn an_age_reads_in_the_coarsest_unit_that_fits_test() {
  assert proposals.age(1000, 1000) == "just now"
  assert proposals.age(0, 5 * 60_000) == "5m ago"
  assert proposals.age(0, 3 * 3_600_000) == "3h ago"
  assert proposals.age(0, 2 * 86_400_000) == "2d ago"
  assert proposals.age(5000, 0) == "just now"
}

pub fn the_diff_removes_the_old_text_and_adds_the_new_test() {
  let assert Ok(decoded) =
    proposals.decode(board([row("prop-0000000001", "pending", "a\nb", "c")], 1))
  let assert [only] = decoded.proposals
  let kinds = list.map(proposals.diff_lines(only), fn(line) { line.kind })
  assert kinds == [diff_view.Removed, diff_view.Removed, diff_view.Added]
}

pub fn an_append_has_no_removed_lines_test() {
  let assert Ok(decoded) =
    proposals.decode(board([row("prop-0000000001", "pending", "", "c")], 1))
  let assert [only] = decoded.proposals
  assert list.map(proposals.diff_lines(only), fn(line) { line.kind })
    == [diff_view.Added]
}

pub fn the_badge_shows_only_when_something_waits_test() {
  let assert Ok(none) = proposals.decode(board([], 0))
  let assert Ok(some) = proposals.decode(board([], 3))
  assert proposals.badge(None) == None
  assert proposals.badge(Some(none)) == None
  assert proposals.badge(Some(some)) == Some(3)
}

pub fn the_commands_are_the_wire_forms_test() {
  assert string.contains(protocol.proposals_get(4), "\"cmd\":\"proposals_get\"")
  let approve =
    protocol.proposal_decide(5, "prop-0123456789", proposals.Approve)
  assert string.contains(approve, "\"cmd\":\"proposal_decide\"")
  assert string.contains(approve, "\"id\":\"prop-0123456789\"")
  assert string.contains(approve, "\"decision\":\"approve\"")
  assert string.contains(
    protocol.proposal_decide(6, "prop-0123456789", proposals.Reject),
    "\"decision\":\"reject\"",
  )
}

pub fn a_snapshot_decodes_as_an_event_and_a_bad_one_is_refused_test() {
  let assert Ok(protocol.ProposalsSnapshot(decoded)) =
    protocol.decode_v2_presentation(
      snapshot_frame(board([row("prop-0000000001", "pending", "", "x")], 1)),
    )
  assert decoded.pending == 1
  assert protocol.decode_v2_presentation(snapshot_frame(json.Null))
    |> result.is_error
}

pub fn the_push_decodes_and_carries_nothing_test() {
  let assert Ok(protocol.ProposalsChanged) =
    protocol.decode_v2_pushed(
      "{\"v\":2,\"event\":\"proposals_changed\",\"body\":{}}",
    )
  assert protocol.decode_v2_pushed(
      "{\"v\":2,\"event\":\"proposals_changed\",\"body\":3}",
    )
    |> result.is_error
}

fn fresh() -> Shared(String, Nil, String, String) {
  step.new(
    "main",
    "session",
    msg.Stamp(1000, 1000),
    inbox.new("frames"),
    inbox.new("replay"),
  )
}

pub fn the_record_starts_with_no_board_and_no_read_owed_test() {
  let shared = fresh()
  assert shared.proposals == None
  assert shared.proposals_refresh == worktree_view.Settled
  assert shared.proposals_notice == ""
}

pub fn a_snapshot_is_kept_and_clears_the_last_refusal_test() {
  let assert Ok(decoded) =
    proposals.decode(board([row("prop-0000000001", "pending", "", "x")], 1))
  let refused =
    session_model.Shared(..fresh(), proposals_notice: "forbidden: no")
  let kept =
    event_fold.apply_event(refused, protocol.ProposalsSnapshot(decoded))
  assert kept.proposals == Some(decoded)
  assert kept.proposals_notice == ""
}

pub fn the_push_owes_a_read_and_changes_nothing_else_test() {
  let shared = event_fold.apply_event(fresh(), protocol.ProposalsChanged)
  assert shared.proposals_refresh == worktree_view.Requested
  assert shared.proposals == None
}

pub fn a_refused_decision_is_worded_and_owes_the_list_again_test() {
  let refused =
    lane_fold.apply_channel_update(
      fresh(),
      session_channel.RequestRefused("proposal_decide", 3, "conflict", "done"),
      lane_fold.nothing_shown(),
    )
  assert string.contains(refused.proposals_notice, "already decided")
  assert refused.proposals_refresh == worktree_view.Requested
}

pub fn a_refused_read_is_worded_and_does_not_ask_again_test() {
  let refused =
    lane_fold.apply_channel_update(
      fresh(),
      session_channel.RequestRefused("proposals_get", 3, "forbidden", "no"),
      lane_fold.nothing_shown(),
    )
  assert string.contains(refused.proposals_notice, "owner")
  assert refused.proposals_refresh == worktree_view.Settled
}

pub fn refusal_words_cover_each_code_and_pass_an_unknown_one_through_test() {
  assert string.contains(
    proposals.refusal_words("unsupported", ""),
    "no proposal queue",
  )
  assert string.contains(
    proposals.refusal_words("internal", ""),
    "stays pending",
  )
  assert string.contains(
    proposals.refusal_words("bad_request", ""),
    "no longer exists",
  )
  assert proposals.refusal_words("odd", "line\none") == "odd: line one"
}
