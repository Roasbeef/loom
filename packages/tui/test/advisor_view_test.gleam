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
import tui/model as tui_model
import tui/notes_view
import tui/transcript_lines

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
      tui_model.Line(
        tui_model.System,
        "advisor: the new test asserts nothing  [Ctrl+G to expand]",
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
      tui_model.Line(tui_model.System, "advisor"),
      tui_model.Line(tui_model.ToolDetail, body),
    ]
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
      tui_model.Line(tui_model.System, "advisor nudges (2)"),
      tui_model.Line(tui_model.ToolDetail, body),
    ]
  assert transcript_lines.advisor_lines(
      transcript_lines.Nudges(body),
      notes_view.Complete,
    )
    == [
      tui_model.Line(tui_model.System, "advisor nudges (2)"),
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
      tui_model.Line(tui_model.System, "advisor nudges (2)"),
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
