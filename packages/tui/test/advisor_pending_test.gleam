//// The pending-nudge panel: a total decoder over a board this terminal did
//// not write, a compact rendering in the advisor's voice, and the three
//// conversation edges that are worth one read.
////
//// The panel is not a transcript row, so these tests check that it draws
//// beside the composer and disappears the moment the primary starts a run —
//// that run start is what drains the queue, and advice folded into a prompt
//// is delivered rather than pending.

import core/entry
import core/ids
import core/json
import core/message
import etui/backend
import etui/geometry
import gleam/option.{type Option, None, Some}
import gleam/string
import tui
import tui/advisor_pending
import tui/connection
import tui/frame
import tui/inbound
import tui/model as tui_model
import tui/protocol.{type Strand, Strand}
import tui/render
import tui/session_channel
import tui/surfaces
import tui/transcript_lines
import tui/workspace
import tui/worktree_view
import tui_test/gateway
import tui_test/pushed

fn model() {
  tui.new_model(connection.new_inbox(), workspace.Context("/work", None))
}

fn painted(model) {
  let model = tui.update(backend.Resize(120, 30), model)
  let #(buffer, _) = render.view(model, geometry.rect_new(0, 0, 120, 30))
  frame.buffer_to_text(buffer)
}

fn board(pending: List(String), total: Int) -> advisor_pending.Board {
  advisor_pending.Board("main", 42_000, pending, total)
}

fn encoded(fields: List(#(String, json.JsonValue))) -> json.JsonValue {
  json.Object(fields)
}

fn wire(pending: List(json.JsonValue), total: Int) -> json.JsonValue {
  encoded([
    #("strand", json.String("main")),
    #("observed_at_ms", json.Int(42_000)),
    #("pending", json.Array(pending)),
    #("total", json.Int(total)),
  ])
}

fn roster(main: Option(String), advisor: Option(String)) -> List(Strand) {
  [
    Strand(id: "main", name: Some("main"), live_phase: main),
    Strand(id: "advisor", name: Some("advisor"), live_phase: advisor),
  ]
}

fn with_roster(strands: List(Strand)) -> tui_model.Model {
  tui_model.Model(..model(), strands:)
}

// --- the decoder is total ---------------------------------------------------

/// A board the server sent is data, not a promise. Every malformed shape is an
/// error the terminal reports, and none of them is a crash.
pub fn malformed_boards_are_refused_rather_than_trusted_test() {
  let assert Ok(accepted) =
    advisor_pending.decode(wire([json.String("no down step")], 1))
  assert accepted == board(["no down step"], 1)

  let assert Error(_) = advisor_pending.decode(json.String("not a board"))
    as "a board must be an object"
  let assert Error(_) =
    advisor_pending.decode(
      encoded([
        #("strand", json.String("main")),
        #("observed_at_ms", json.Int(1)),
        #("total", json.Int(0)),
      ]),
    )
    as "a board without a queue is not an empty queue"
  let assert Error(_) = advisor_pending.decode(wire([json.Int(7)], 1))
    as "a nudge is text"
  let assert Error(_) =
    advisor_pending.decode(wire([json.String("a"), json.String("b")], 1))
    as "a total below the rows sent contradicts the rows"
  let assert Error(_) = advisor_pending.decode(wire([json.String("a")], -1))
    as "a negative total is not a count"
  let assert Error(_) =
    advisor_pending.decode(
      encoded([
        #("strand", json.String("")),
        #("observed_at_ms", json.Int(1)),
        #("pending", json.Array([])),
        #("total", json.Int(0)),
      ]),
    )
    as "a board must name the strand its queue drains into"
  let assert Error(_) =
    advisor_pending.decode(wire([json.String(string.repeat("x", 5000))], 1))
    as "one nudge cannot exceed the guard's own byte cap"
}

// --- the rendering ----------------------------------------------------------

/// The heading carries the count because the bullets are the whole content,
/// and an empty queue costs the conversation no rows at all.
pub fn the_panel_counts_the_queue_and_vanishes_when_it_is_empty_test() {
  assert advisor_pending.lines(board([], 0)) == []

  let lines = advisor_pending.lines(board(["no down step", "untested arm"], 2))
  let assert [heading, first, second] = lines
  assert string.contains(heading, "advisor nudges pending (2)")
  assert string.contains(heading, "main")
  assert string.contains(first, "no down step")
  assert string.contains(second, "untested arm")
}

/// A long queue is counted rather than printed: the band sits above the
/// composer and its height comes out of the conversation.
pub fn a_queue_past_the_visible_rows_reports_the_remainder_test() {
  let queued = ["one", "two", "three", "four", "five"]
  let assert [heading, ..rest] = advisor_pending.lines(board(queued, 5))
  assert string.contains(heading, "advisor nudges pending (5)")
  let assert [_, _, _, overflow] = rest
  assert string.contains(overflow, "+2 more waiting")
}

/// Control sequences in model-written advice never reach the terminal raw.
pub fn nudge_text_is_sanitized_before_it_is_drawn_test() {
  let assert [_, row] =
    advisor_pending.lines(board(["bell\u{0007}and\nnewline"], 1))
  assert !string.contains(row, "\u{0007}")
  assert !string.contains(row, "\n")
}

/// The panel draws beside the composer, in the advisor's voice, without
/// becoming a transcript row that would claim the model had read it.
pub fn an_observed_queue_is_drawn_beside_the_composer_test() {
  let observed =
    tui_model.Model(
      ..with_roster(roster(None, None)),
      nudges: Some(board(["the migration has no down step"], 1)),
    )
  let text = painted(observed)
  assert string.contains(text, "advisor nudges pending (1)")
  assert string.contains(text, "the migration has no down step")
}

/// A nudge observed after a review settles during an open primary run remains
/// visible until a new run starts or another authoritative read replaces it.
pub fn a_running_primary_keeps_newly_observed_advice_visible_test() {
  let running =
    tui_model.Model(
      ..with_roster(roster(Some("assistant"), None)),
      nudges: Some(board(["no down step"], 1)),
    )
  let resized = tui.update(backend.Resize(120, 30), running)
  assert resized.nudges == running.nudges
  assert string.contains(painted(resized), "advisor nudges pending")
  assert string.contains(painted(resized), "no down step")
}

// --- the three read edges ---------------------------------------------------

/// The primary's own operation settling is the first edge: the operator is
/// back at the composer and the advice is for the prompt they write next.
pub fn the_primary_settling_asks_for_one_read_test() {
  let running = with_roster(roster(Some("assistant"), None))
  let idle = with_roster(roster(None, None))
  assert surfaces.advisor_nudges_action(running, idle) == surfaces.ReadNudges
  assert surfaces.advisor_nudges_action(idle, running) == surfaces.DropNudges
}

/// A review ending can queue a nudge even while the primary is still running.
/// That edge must read the queue so the operator sees the full advice at once.
pub fn a_review_settling_asks_for_a_read_regardless_of_primary_phase_test() {
  let reviewing = with_roster(roster(None, Some("assistant")))
  let reviewed = with_roster(roster(None, None))
  assert surfaces.advisor_nudges_action(reviewing, reviewed)
    == surfaces.ReadNudges

  // The running operation only drained advice that existed at its start.
  let busy = with_roster(roster(Some("assistant"), Some("assistant")))
  let busy_reviewed = with_roster(roster(Some("assistant"), None))
  assert surfaces.advisor_nudges_action(busy, busy_reviewed)
    == surfaces.ReadNudges

  // A start and review end in one captured transition still needs the
  // authoritative read: the review may have queued advice after the start
  // drained older advice.
  let both = with_roster(roster(Some("assistant"), None))
  assert surfaces.advisor_nudges_action(reviewing, both) == surfaces.ReadNudges
}

/// The primary appearing in the roster is the attachment edge: a terminal that
/// has just attached holds no roster at all, and its first snapshot is the
/// moment there is a session to ask about.
pub fn the_primary_appearing_in_the_roster_asks_for_one_read_test() {
  let attaching = with_roster([])
  let listed = with_roster(roster(None, None))
  assert surfaces.advisor_nudges_action(attaching, listed)
    == surfaces.ReadNudges
}

/// Everything else holds. A phase change on an unrelated strand cannot have
/// grown the queue, and repeating the read on each of them would put a request
/// behind every tool call of a sub-agent's turn.
pub fn unrelated_movement_asks_for_nothing_test() {
  let idle = with_roster(roster(None, None))
  assert surfaces.advisor_nudges_action(idle, idle) == surfaces.HoldNudges

  let with_worker =
    with_roster([
      Strand(id: "sub:main/audit", name: None, live_phase: Some("assistant")),
      ..roster(None, None)
    ])
  assert surfaces.advisor_nudges_action(idle, with_worker)
    == surfaces.HoldNudges
  assert surfaces.advisor_nudges_action(with_worker, idle)
    == surfaces.HoldNudges
}

/// A submitted prompt drains the queue at the run it is about to start, and
/// the operator sees that submission before the server reports a phase for it.
pub fn a_local_submission_counts_as_the_primary_running_test() {
  let idle = with_roster(roster(None, None))
  let submitting = tui_model.Model(..idle, submitting: Some("main"))
  assert surfaces.advisor_nudges_action(idle, submitting) == surfaces.DropNudges
}

// --- the command lane -------------------------------------------------------

/// The observation is a read, not a mutation, and its correlated reply settles
/// the lane it borrowed.
///
/// Both halves are a command name in a table the compiler cannot check: an
/// unlisted name defaults to the mutation lane, which blocks the composer for
/// the life of the attachment, and an unlisted reply shape fails the channel as
/// an answer to no command. The real terminal drive found both.
pub fn the_observation_takes_the_read_lane_and_its_reply_settles_it_test() {
  let model = pushed.attached()
  let assert Some(channel) = model.channel
    as "fixture has a synchronized channel"
  let #(channel, disposition) =
    session_channel.submit(channel, protocol.advisor_pending(999), now: 0)
  let assert session_channel.Sent("advisor_pending", id) = disposition
    as "the queue read is issued once with the lane's request id"
  assert session_channel.mutation_available(channel)
    as "an auxiliary read never holds the composer's own lane"

  let body =
    json.Object([
      #("mode", json.String("advisor_pending")),
      #("board", wire([json.String("no down step")], 1)),
    ])
  let #(channel, updates) =
    session_channel.receive(channel, pushed.reply(id, "snapshot", body), now: 0)
  let assert [session_channel.Auxiliary(protocol.AdvisorPendingSnapshot(board))] =
    updates
    as "a successful read never becomes an answer to no command"
  assert board.pending == ["no down step"]
  assert session_channel.ready_for_read(channel)
}

// --- a drain the roster cannot see ------------------------------------------

/// The daemon drains the queue inside a long run as well as at its start: a
/// checkpoint, a follow-up on an ending run, a steer. None of those moves a
/// phase, so the delivered frame is what retires the board. Without this the
/// panel showed the same advice as pending beside the entry delivering it.
pub fn a_delivered_nudges_entry_retires_the_board_test() {
  let observed =
    tui_model.Model(
      ..with_roster(roster(Some("assistant"), None)),
      nudges: Some(board(["no down step"], 1)),
    )
  let delivered = nudges_record("main", "no down step")
  let retired = surfaces.retire_delivered_nudges(observed, delivered)
  assert retired.nudges == None

  // The fresh read is what keeps advice queued after the drain visible.
  assert retired.nudges_refresh == worktree_view.Requested

  // The same frame on another strand, or an ordinary turn on the primary,
  // is not the primary's queue draining.
  let elsewhere =
    surfaces.retire_delivered_nudges(
      observed,
      nudges_record("advisor", "no down step"),
    )
  assert elsewhere.nudges == observed.nudges
  let ordinary =
    surfaces.retire_delivered_nudges(
      observed,
      record("main", "please look at the migration"),
    )
  assert ordinary.nudges == observed.nudges
}

fn nudges_record(strand: String, text: String) -> protocol.EntryRecord {
  record(
    strand,
    transcript_lines.nudges_header
      <> "\n```"
      <> transcript_lines.nudges_fence
      <> "\n- "
      <> text
      <> "\n```",
  )
}

fn record(strand: String, text: String) -> protocol.EntryRecord {
  let assert Ok(id) = ids.parse_entry_id("00000000-0000-7000-8000-000000000000")
    as "a fixed entry id parses"
  protocol.EntryRecord(
    strand:,
    entry: entry.MessageEntry(
      id:,
      parent: None,
      seq: 1,
      ts: 1,
      message: message.UserMessage(
        content: [message.UserText(text:, text_signature: None)],
        timestamp: 1,
        origin: None,
      ),
      terminate: False,
    ),
  )
}

/// The same retire, reached the way the daemon reaches it: a pushed entry
/// through the connection handler, which pins the call in `inbound`.
pub fn a_pushed_delivery_retires_the_board_test() {
  let observed =
    tui_model.Model(
      ..with_roster(roster(Some("assistant"), None)),
      nudges: Some(board(["no down step"], 1)),
    )
  let frame =
    gateway.user_entry(
      "main",
      transcript_lines.nudges_header
        <> "\n```"
        <> transcript_lines.nudges_fence
        <> "\n- no down step\n```",
      9,
    )
  let delivered =
    inbound.accept_connection_message(observed, connection.Incoming(frame))
  assert delivered.nudges == None
  assert delivered.nudges_refresh == worktree_view.Requested
}

// --- the tail collapses to previews -----------------------------------------

/// A queue that grows through a long run would push the run out of view if
/// every body printed in full, so the tail shows one preview row per nudge
/// until detail mode asks for the complete text.
pub fn pending_bodies_collapse_until_details_are_expanded_test() {
  let tail = " and the ending that only detail mode shows"
  let body = "check the dedup section " <> string.repeat("x", 150) <> tail
  let observed =
    tui_model.Model(
      ..with_roster(roster(Some("assistant"), None)),
      nudges: Some(board([body], 1)),
    )

  let collapsed = painted(observed)
  assert string.contains(collapsed, "- check the dedup")
  assert string.contains(collapsed, "Ctrl+G to expand")
  assert !string.contains(collapsed, "only detail mode shows")

  let expanded = painted(tui_model.Model(..observed, details_expanded: True))
  assert string.contains(expanded, "only detail mode shows")
}
