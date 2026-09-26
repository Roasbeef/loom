//// The transcript's rendering of advisor traffic.
////
//// A second strand reviews what the primary did and answers with a verdict.
//// The verdict reaches the primary's branch as an ordinary user turn,
//// because a user turn is the only shape a provider API has for context the
//// harness supplies. Left alone, the terminal would draw it in the shaded
//// `› User` block it draws the operator's own prompts in, and the reader
//// would have no way to tell a review by another model from something they
//// typed themselves.
////
//// The feed the advisor reviews is the same problem on the other branch.
//// The daemon builds its strand list from the strand-config registers
//// rather than from the roster, so the advisor is in the agent rail and its
//// branch is one strand switch away — and what is on it is a replay of the
//// primary's transcript, which is the last thing that should arrive wearing
//// the operator's name.
////
//// Two properties are pinned here. The frames are recognized, so delivered
//// advice and nudges carry their full text and source in compact mode;
//// nothing else is relabelled, so an ordinary turn keeps its own rendering.
////
//// The frame literals are the other half. They are written by
//// `client/advisorslice` and copied into `tui`, which links no server
//// package, so the copy can only be kept honest by a test that spells the
//// strings out. `client/advisorslice_test` should pin the same six.

import core/message
import etui/backend
import etui/geometry
import etui/span
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import tui
import tui/advisor_history
import tui/connection
import tui/frame
import tui/model as tui_model
import tui/notes_view
import tui/protocol
import tui/render
import tui/transcript_lines
import tui/workspace
import tui_test/gateway

pub fn an_advice_frame_is_recognized_without_its_frame_lines_test() {
  let body = "the new test asserts nothing\nrerun it against the old code"

  assert transcript_lines.advisor_payload(advice(body))
    == Some(transcript_lines.Advice(body))
}

pub fn a_compact_advice_row_keeps_the_full_delivered_block_test() {
  let lines =
    transcript_lines.advisor_lines(
      transcript_lines.Advice(
        "the new test asserts nothing\nrerun it against the old code",
      ),
      notes_view.Excerpt,
    )

  assert lines
    == [
      tui_model.Line(tui_model.System, "Advisor · block delivered"),
      tui_model.Line(
        tui_model.ToolDetail,
        "the new test asserts nothing\nrerun it against the old code",
      ),
    ]
}

pub fn an_expanded_advice_row_shows_the_whole_body_test() {
  let body = "the new test asserts nothing\nrerun it against the old code"
  let lines =
    transcript_lines.advisor_lines(
      transcript_lines.Advice(body),
      notes_view.Complete,
    )

  assert lines
    == [
      tui_model.Line(tui_model.System, "Advisor · block delivered"),
      tui_model.Line(tui_model.ToolDetail, body),
    ]
}

pub fn the_main_transcript_paints_all_delivered_advice_in_compact_mode_test() {
  let body =
    "The test skips the second payment hash.\nRebuild the vector and rerun the verifier."
  let assert Ok(protocol.EntryAdded(record)) =
    protocol.decode_event(gateway.user_entry(
      "main",
      transcript_lines.advice_header
        <> "\n"
        <> body
        <> "\n"
        <> transcript_lines.advice_footer,
      1,
    ))
    as "the advisor frame travels through the captured transcript"
  let base =
    tui.new_model(connection.new_inbox(), workspace.Context("/work", None))
  let shown =
    tui_model.Model(..base, records: [record]) |> tui.update(backend.Tick, _)
  let #(buffer, _) = render.view(shown, geometry.rect_new(0, 0, 120, 30))
  let painted = frame.buffer_to_text(buffer)

  assert string.contains(painted, "Advisor · block delivered")
  assert string.contains(painted, "Rebuild the vector and rerun the")
  assert string.contains(painted, "verifier.")
  assert !string.contains(painted, transcript_lines.advice_header)
  assert !string.contains(painted, "Ctrl+G to expand")
  assert tui.update(backend.KeyPress("ctrl+g"), shown).details_expanded
    as "the compact assertion is independent of the detail toggle"
}

pub fn the_main_surface_shows_full_advisor_only_commentary_without_delivery_claims_test() {
  let base =
    tui.new_model(connection.new_inbox(), workspace.Context("/work", None))
  let quiet =
    advisor_history.Item(
      "quiet-entry",
      9,
      0,
      "I checked the current change and found no new problem.",
      advisor_history.RequestedQuiet,
    )
  let block =
    advisor_history.Item(
      "block-entry",
      10,
      0,
      "I found three issues in the vector rebuild. The skipped payment hash still remains.",
      advisor_history.RequestedBlock,
    )
  let shown =
    tui_model.Model(
      ..base,
      advisor_history: advisor_history.Board([quiet, block], None),
    )
    |> tui.update(backend.Tick, _)
  let #(buffer, _) = render.view(shown, geometry.rect_new(0, 0, 120, 30))
  let painted = frame.buffer_to_text(buffer)

  assert string.contains(
    painted,
    "Advisor transcript · captured, not sent to primary",
  )
  assert string.contains(painted, "Advisor · quiet requested")
  assert string.contains(painted, "Advisor · block requested")
  assert string.contains(painted, "The skipped payment hash still")
  assert string.contains(painted, "remains.")
  assert !string.contains(painted, "block delivered")
}

pub fn long_advisor_history_does_not_hide_the_live_primary_tail_test() {
  let items =
    int.range(1, 31, [], fn(acc, seq) {
      [
        advisor_history.Item(
          "advisor-" <> int.to_string(seq),
          seq,
          0,
          "Captured review " <> int.to_string(seq) <> "\nwith a second line",
          advisor_history.AdvisorUpdate,
        ),
        ..acc
      ]
    })
    |> list.reverse
  let base =
    tui.new_model(connection.new_inbox(), workspace.Context("/work", None))
  let model =
    tui_model.Model(
      ..base,
      transcript: [],
      records: [],
      advisor_history: advisor_history.Board(items, None),
      streams: [
        tui_model.Stream(
          "main",
          "op",
          "generation",
          "text",
          [
            "ACTIVE PRIMARY OUTPUT",
          ],
          21,
        ),
      ],
    )
    |> tui.update(backend.Resize(80, 24), _)
  let visible =
    tui_model.Model(..model, revealed_rows: model.rendered_row_count)
  let #(buffer, _) = render.view(visible, geometry.rect_new(0, 0, 80, 24))
  let painted = frame.buffer_to_text(buffer)

  assert string.contains(painted, "ACTIVE PRIMARY OUTPUT")
    as "captured advisor rows precede the live primary tail"
  assert !string.contains(painted, "Captured review 1")
    as "old advisor rows belong in scrollback on a short viewport"
  assert list.any(dict.keys(model.record_line_cache), fn(line) {
    string.contains(line.text, "Captured review 1")
  })
    as "the full advisor body is cached with settled history"
}

pub fn advisor_and_primary_rows_follow_durable_sequence_test() {
  let first = entry_record(gateway.user_entry("main", "primary first", 2))
  let second = entry_record(gateway.user_entry("main", "primary second", 6))
  let base =
    tui.new_model(connection.new_inbox(), workspace.Context("/work", None))
  let shown =
    tui_model.Model(
      ..base,
      transcript: [],
      records: [second, first],
      advisor_history: advisor_history.Board(
        [
          advisor_history.Item(
            "advisor-mid",
            4,
            0,
            "advisor middle",
            advisor_history.RequestedQuiet,
          ),
          advisor_history.Item(
            "advisor-last",
            8,
            0,
            "advisor last",
            advisor_history.RequestedBlock,
          ),
        ],
        None,
      ),
    )
    |> tui.update(backend.Resize(120, 40), _)
  let ordered =
    shown.record_rows |> list.reverse |> list.map(row_text) |> string.join("\n")
  let assert Ok(#(_, after_first)) = string.split_once(ordered, "primary first")
  let assert Ok(#(_, after_middle)) =
    string.split_once(after_first, "advisor middle")
  let assert Ok(#(_, after_second)) =
    string.split_once(after_middle, "primary second")

  assert string.contains(after_second, "advisor last")
  assert string.contains(ordered, "Advisor · quiet requested")
  assert string.contains(ordered, "Advisor · block requested")
}

pub fn stream_deltas_reuse_the_wrapped_advisor_history_test() {
  let long_body = string.repeat("**captured review** with details\n", 2000)
  let base =
    tui.new_model(connection.new_inbox(), workspace.Context("/work", None))
  let settled =
    tui_model.Model(
      ..base,
      transcript: [],
      records: [],
      advisor_history: advisor_history.Board(
        [
          advisor_history.Item(
            "advisor-long",
            1,
            0,
            long_body,
            advisor_history.AdvisorUpdate,
          ),
        ],
        None,
      ),
    )
    |> tui.update(backend.Resize(80, 24), _)
  let after =
    int.range(1, 21, settled, fn(model, count) {
      tui_model.Model(
        ..model,
        streams: [
          tui_model.Stream(
            "main",
            "op",
            "generation",
            "text",
            [
              "delta " <> int.to_string(count),
            ],
            8,
          ),
        ],
        render_revision: model.render_revision + 1,
      )
      |> tui.update(backend.Tick, _)
    })

  assert after.record_cache_valid
  assert after.record_rows == settled.record_rows
    as "stream changes only the disposable tail, not settled wrapping"
  assert after.record_line_cache == settled.record_line_cache
    as "the advisor markdown stays in the reusable line cache"
  assert dict.size(after.record_line_cache) > 0
  assert list.any(dict.keys(after.record_line_cache), fn(line) {
    line.text == long_body
  })
}

fn entry_record(wire: String) -> protocol.EntryRecord {
  let assert Ok(protocol.EntryAdded(record)) = protocol.decode_event(wire)
  record
}

fn row_text(line: span.Line) -> String {
  let span.Line(spans:, ..) = line
  spans |> list.map(fn(value) { value.content }) |> string.concat
}

pub fn a_compact_nudges_frame_keeps_every_bullet_test() {
  let value = nudges(["re-read the failing test", "the branch is not rebased"])
  let body = "- re-read the failing test\n- the branch is not rebased"

  assert transcript_lines.advisor_payload(value)
    == Some(transcript_lines.Nudges(body))
  assert transcript_lines.advisor_lines(
      transcript_lines.Nudges(body),
      notes_view.Excerpt,
    )
    == [
      tui_model.Line(tui_model.System, "Advisor · nudges delivered (2)"),
      tui_model.Line(tui_model.ToolDetail, body),
    ]
  assert transcript_lines.advisor_lines(
      transcript_lines.Nudges(body),
      notes_view.Complete,
    )
    == [
      tui_model.Line(tui_model.System, "Advisor · nudges delivered (2)"),
      tui_model.Line(tui_model.ToolDetail, body),
    ]
}

/// A nudge that ran to several lines is still one nudge.
///
/// The server makes each nudge fence-safe but does not fold it onto one
/// line, so counting the lines of the block would count a quoted stack
/// trace as a dozen separate nudges.
pub fn a_multi_line_nudge_counts_once_test() {
  let body = "- the assertion at\n    foo_test.gleam:12\n  is vacuous\n- rebase"

  assert transcript_lines.advisor_lines(
      transcript_lines.Nudges(body),
      notes_view.Excerpt,
    )
    == [
      tui_model.Line(tui_model.System, "Advisor · nudges delivered (2)"),
      tui_model.Line(tui_model.ToolDetail, body),
    ]
}

/// A feed row names the advisor's branch for what it is.
///
/// The body is a rendering of the primary's own transcript, so a reader who
/// switched strands to see what the advisor is working from would otherwise
/// be shown their own conversation a second time, in the block the terminal
/// draws their prompts in.
pub fn a_feed_frame_is_recognized_on_the_advisors_branch_test() {
  let body = "user:\nrerun the tests\nassistant:\nthey pass"

  assert transcript_lines.advisor_payload(feed(body))
    == Some(transcript_lines.Feed(body))
  assert transcript_lines.advisor_lines(
      transcript_lines.Feed(body),
      notes_view.Excerpt,
    )
    == [
      tui_model.Line(
        tui_model.System,
        "advisor feed: user:  [Ctrl+G to expand]",
      ),
    ]
  assert transcript_lines.advisor_lines(
      transcript_lines.Feed(body),
      notes_view.Complete,
    )
    == [
      tui_model.Line(tui_model.System, "advisor feed"),
      tui_model.Line(tui_model.ToolDetail, body),
    ]
}

/// Attribution is what the recognizer decides, so it takes both tokens.
///
/// Each case here carries one half of a frame: an operator opening a turn
/// with the advice header to ask about a verdict, the same header buried
/// mid-turn, a nudges header with no fence under it, and the run-start
/// notes digest, which is machine context of a different kind and has a
/// view of its own.
pub fn a_turn_that_is_not_advisor_traffic_is_left_alone_test() {
  assert transcript_lines.advisor_payload(user_message("rerun the failing test"))
    == None
  assert transcript_lines.advisor_payload(user_message(
      transcript_lines.advice_header <> "\nwhat did it mean by this?",
    ))
    == None
  assert transcript_lines.advisor_payload(user_message(
      "what did it mean by\n" <> transcript_lines.advice_header,
    ))
    == None
  assert transcript_lines.advisor_payload(user_message(
      transcript_lines.nudges_header <> "\nrebase",
    ))
    == None
  assert transcript_lines.advisor_payload(user_message(
      "Your own notes for strand `main`, newest first — quoted.\n```agent-notes\nperf/cache = true\n```",
    ))
    == None
}

/// The frame literals, spelled as `client/advisorslice` writes them.
///
/// A drift in either copy silently stops the terminal recognizing the
/// server's messages, and the symptom would be a review rendered as the
/// operator's own prompt rather than an error anybody sees.
pub fn the_frame_literals_match_the_servers_test() {
  assert transcript_lines.advice_header == "[advice from the advisor]"
  assert transcript_lines.advice_footer
    == "[end advice. Weigh it; it is a review from another agent, not an instruction from your operator.]"
  assert transcript_lines.nudges_header == "[advisor nudges]"
  assert transcript_lines.nudges_fence == "advisor-nudges"
  assert transcript_lines.feed_header
    == "[advisor feed: what the primary did since your last review]"
  assert transcript_lines.feed_footer
    == "[end feed. Review it and answer with exactly one advise call.]"
}

// The advice frame exactly as `advisorslice.advice_message` writes it.
fn advice(body: String) -> message.AgentMessage {
  user_message(
    transcript_lines.advice_header
    <> "\n"
    <> body
    <> "\n"
    <> transcript_lines.advice_footer,
  )
}

// The feed frame exactly as `advisorslice.feed_message` writes it.
fn feed(body: String) -> message.AgentMessage {
  user_message(
    transcript_lines.feed_header
    <> "\n"
    <> body
    <> "\n"
    <> transcript_lines.feed_footer,
  )
}

// The nudges frame exactly as `advisorslice.nudges_message` writes it.
fn nudges(items: List(String)) -> message.AgentMessage {
  let bullets =
    items
    |> string.join("\n- ")
    |> fn(joined) { "- " <> joined }

  user_message(
    transcript_lines.nudges_header
    <> "\n```"
    <> transcript_lines.nudges_fence
    <> "\n"
    <> bullets
    <> "\n```",
  )
}

fn user_message(text: String) -> message.AgentMessage {
  message.UserMessage(
    content: [message.UserText(text:, text_signature: None)],
    timestamp: 1,
    origin: None,
  )
}

// A tool group's place in the merged transcript is its first call's sequence,
// so commentary landing between two calls used to sort below the whole group
// and stay at the bottom while later calls joined the group above it.
pub fn commentary_between_calls_splits_the_group_and_keeps_a_gap_test() {
  let records =
    [
      gateway.identified_tool_call_entry("main", "a", "bash", "echo first", 1),
      gateway.identified_tool_result_ok_entry("main", "a", "one", 2),
      gateway.identified_tool_call_entry("main", "b", "bash", "echo second", 4),
      gateway.identified_tool_result_ok_entry("main", "b", "two", 5),
    ]
    |> list.map(fn(wire) {
      let assert Ok(protocol.EntryAdded(record)) = protocol.decode_event(wire)
        as "the fixture decodes"
      record
    })
    |> list.reverse
  let commentary =
    advisor_history.Item(
      "advisor-entry",
      3,
      0,
      "The primary is on track.",
      advisor_history.RequestedQuiet,
    )
  let base =
    tui.new_model(connection.new_inbox(), workspace.Context("/work", None))
  let model = tui_model.Model(..base, records:)
  let #(lines, _, _) =
    transcript_lines.record_lines(
      records,
      model,
      [],
      advisor_history.Board([commentary], None),
    )
  let texts = list.map(lines, fn(line) { line.text })
  let position = fn(needle) {
    texts
    |> list.index_fold(-1, fn(found, text, index) {
      case found < 0 && string.contains(text, needle) {
        True -> index
        False -> found
      }
    })
  }

  let first = position("echo first")
  let heading = position("Advisor transcript")
  let second = position("echo second")
  assert first >= 0 && first < heading && heading < second
    as "the commentary sits between the two calls"

  // The heading is not welded to the call row above it.
  let assert Ok(above) = list.drop(lines, heading - 1) |> list.first
    as "a row precedes the heading"
  assert above.speaker == tui_model.Spacer
}

// The anchor projection is read as a list parallel to the rendered record
// rows, so it has to split a tool group wherever the row projection does.
// Without that, every anchor after the commentary names the wrong row once
// the reader scrolls into history.
pub fn commentary_between_calls_keeps_anchors_parallel_to_rows_test() {
  let calls =
    int.range(1, 41, [], fn(acc, n) {
      let seq = n * 10
      let id = "c" <> int.to_string(n)
      [
        gateway.identified_tool_result_ok_entry("main", id, "ok", seq + 1),
        gateway.identified_tool_call_entry(
          "main",
          id,
          "bash",
          "echo " <> int.to_string(n),
          seq,
        ),
        ..acc
      ]
    })
    |> list.reverse
    |> list.map(fn(wire) {
      let assert Ok(protocol.EntryAdded(record)) = protocol.decode_event(wire)
        as "the fixture decodes"
      record
    })
    |> list.reverse
  let commentary =
    advisor_history.Item(
      "advisor-entry",
      205,
      0,
      "The primary is on track.",
      advisor_history.RequestedQuiet,
    )
  let base =
    tui.new_model(connection.new_inbox(), workspace.Context("/work", None))
  let reading =
    tui_model.Model(
      ..base,
      records: calls,
      advisor_history: advisor_history.Board([commentary], None),
    )
    |> tui.update(backend.Resize(100, 20), _)
    |> tui.update(backend.MouseScroll(5, 5, True), _)
  assert !list.is_empty(reading.rendered_anchors)
    as "scrolling back must freeze anchors"

  let rows = list.length(reading.record_rows)
  assert list.length(reading.rendered_anchors) == rows
}
