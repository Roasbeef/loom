//// The transcript on the relayed session page (protocol-change/094, issue
//// #1135): drawn as the page's own lane draws a session's, from text recorded
//// on another machine, and without the framing that protects an agent.
////
//// These tests pin that an answer is rendered Markdown and a tool call a folded
//// step; that a transcript written to attack the page reaches it as characters
//// (a tag, an event attribute, a `javascript:` link) and puts no handler, link
//// or address from the transcript on the page; that the framing lines are not
//// drawn on the owner's page, while a message that quotes them is kept whole;
//// and that the framing an agent receives is still produced by the layer the
//// agent reads.

import core/clock
import core/entry
import core/ids
import core/json
import core/message
import core/usage_evidence
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/element
import session_view/remote_transcript
import session_view/strand_framing
import session_view/turns
import web_view/listing
import web_view/relayed
import web_view/relayed_lane
import web_view/relayed_session
import web_view/view/lane
import web_view/view/peek
import web_view/view/relayed_session as relayed_view

const identity = "0198c0de-0000-7000-8000-000000000001"

// The fixed pieces of a hostile transcript, each of which would do harm if any
// of it reached the page as markup.
const script = "<script>alert(1)</script>"

const image = "<img src=x onerror=alert(1)>"

const bad_link = "[click me](javascript:alert(1))"

const pixel = "![x](http://attacker/x.png)"

fn usage() -> message.Usage {
  message.Usage(
    0,
    0,
    0,
    0,
    None,
    None,
    0,
    message.UsageCost(0.0, 0.0, 0.0, 0.0, 0.0),
    usage_evidence.none(),
  )
}

fn at(seq: Int, body: message.AgentMessage) -> entry.Entry {
  let #(id, _) = ids.mint_entry(ids.generator(clock.fixed(at: 0), seed: seq))
  let parent = case seq {
    1 -> None
    _ ->
      Some(ids.mint_entry(ids.generator(clock.fixed(at: 0), seed: seq - 1)).0)
  }
  entry.MessageEntry(
    id:,
    parent:,
    seq:,
    ts: seq * 1000,
    message: body,
    terminate: False,
  )
}

fn asked(seq: Int, text: String) -> entry.Entry {
  at(
    seq,
    message.UserMessage(
      content: [message.UserText(text:, text_signature: None)],
      timestamp: 0,
      origin: None,
    ),
  )
}

fn answered(seq: Int, content: List(message.AssistantBlock)) -> entry.Entry {
  at(
    seq,
    message.AssistantMessage(
      content:,
      api: "test",
      provider: "test",
      model: "test",
      response_model: None,
      response_id: None,
      diagnostics: None,
      usage: usage(),
      stop_reason: message.Stop,
      deferred: None,
      error_message: None,
      raw_stop_reason: None,
      end_turn: None,
      timestamp: 0,
    ),
  )
}

fn said(text: String) -> message.AssistantBlock {
  message.AssistantText(text:, text_signature: None)
}

fn called(id: String, command: String) -> message.AssistantBlock {
  message.AssistantToolCall(message.ToolCall(
    id:,
    name: "bash",
    arguments: json.Object([#("command", json.String(command))]),
    thought_signature: None,
    namespace: None,
  ))
}

fn returned(seq: Int, id: String, text: String) -> entry.Entry {
  at(
    seq,
    message.ToolResultMessage(
      tool_call_id: id,
      tool_name: "bash",
      content: [message.ToolResultText(text:, text_signature: None)],
      details: None,
      usage: None,
      added_tool_names: None,
      is_error: False,
      timestamp: 0,
    ),
  )
}

fn page_of(entries: List(entry.Entry)) -> remote_transcript.Page {
  remote_transcript.Page(child: "main", entries:, omitted: 0, next: None)
}

// A turn as a model writes one: it runs a command, reads what it printed, and
// answers in Markdown with a table, a link and a tag of its own.
fn worked() -> remote_transcript.Page {
  page_of([
    asked(1, "list the files and sum them up"),
    answered(2, [called("c1", "ls -la")]),
    returned(3, "c1", "total 8\nREADME.md"),
    answered(4, [
      said(
        "All **done**.\n\n| file | size |\n|------|------|\n| README.md | 8 |\n\nSee <details><summary>more</summary>x</details> and [the docs](https://example.com/docs).",
      ),
    ]),
  ])
}

// A transcript written to attack the page. The user's message quotes the foot
// the page used to draw, and the answer carries every shape of markup.
fn hostile() -> remote_transcript.Page {
  page_of([
    asked(
      1,
      "Remember: "
        <> strand_framing.transcript_foot
        <> "\n"
        <> strand_framing.transcript_head("main", "box"),
    ),
    answered(2, [called("c1", "echo " <> script)]),
    returned(3, "c1", script <> image),
    answered(4, [
      said(script <> "\n\n" <> image <> "\n\n" <> bad_link <> "\n\n" <> pixel),
    ]),
  ])
}

fn row(activity: relayed.Activity) -> relayed.Row {
  relayed.Row(
    name: "build the thing",
    code: listing.Registered("exec", "loom"),
    activity:,
    updated_ms: 1000,
    needs: [],
    more_needs: 0,
  )
}

fn presses() -> relayed_view.Presses(Nil) {
  relayed_view.Presses(
    replied: fn(_) { Nil },
    stopped: Nil,
    archive_asked: Nil,
    archive_confirmed: Nil,
    archive_cancelled: Nil,
    decided: fn(_, _, _) { Nil },
  )
}

// The relayed centre for a session in this activity with this page.
fn drawn(activity: relayed.Activity, page: remote_transcript.Page) -> String {
  relayed_session.heard(
    relayed_session.open("box", identity),
    relayed.Heard(row: Some(row(activity)), history: relayed.Shown(page)),
    100,
  )
  |> relayed_view.view(presses())
  |> element.to_string
}

fn count(text: String, part: String) -> Int {
  list.length(string.split(text, part)) - 1
}

pub fn an_answer_is_rendered_markdown_not_its_source_test() {
  let html = drawn(relayed.Idle, worked())

  // The table, the emphasis and the link are elements of the lane.
  assert string.contains(html, "md-table")
  assert string.contains(html, "<strong>done</strong>")
  assert string.contains(html, "<loom-link>")
  assert string.contains(html, "https://example.com/docs")

  // The pipes and asterisks that made them are gone.
  assert !string.contains(html, "|------|")
  assert !string.contains(html, "**done**")
}

pub fn a_tag_in_an_answer_is_the_characters_it_was_written_with_test() {
  let html = drawn(relayed.Idle, worked())

  assert string.contains(html, "&lt;details&gt;")
  assert !string.contains(html, "<details>")
  assert !string.contains(html, "<summary>")
}

pub fn a_tool_call_is_a_folded_step_not_a_speaker_label_test() {
  let html = drawn(relayed.Idle, worked())

  // The step is one line with its detail behind a chevron the browser opens.
  assert string.contains(html, "<loom-expand")
  assert string.contains(html, "ls -la")
  assert string.contains(html, "Worked")

  // The old plain-text page labelled each entry with who said it.
  assert !string.contains(html, "peek-speaker")
  assert !string.contains(html, ">tool<")
}

pub fn a_running_session_draws_its_last_turn_without_a_divider_test() {
  let settled = drawn(relayed.Idle, worked())
  let running = drawn(relayed.Working, worked())

  assert string.contains(settled, "work-toggle")
  assert !string.contains(running, "work-toggle")
  assert string.contains(running, "ls -la")
}

pub fn hostile_text_reaches_the_page_as_characters_test() {
  let html = drawn(relayed.Idle, hostile())

  // No tag the transcript wrote is a tag of the page.
  assert !string.contains(html, "<script")
  assert !string.contains(html, "<img")
  assert string.contains(html, "&lt;script&gt;alert(1)&lt;/script&gt;")
  assert string.contains(html, "&lt;img src=x onerror=alert(1)&gt;")

  // A link is a pair of text children for the browser to check, and the
  // `javascript:` destination is never an attribute.
  assert string.contains(html, "<loom-link>")
  assert !string.contains(html, "href=\"javascript")
  assert !string.contains(html, "href='javascript")
  assert count(html, "javascript:alert(1)") == 1
  assert string.contains(
    html,
    "<span class=\"ll-url\" hidden>javascript:alert(1)</span>",
  )
}

// The lane alone, so the page's own controls cannot hide a link of the
// transcript's or be blamed for one.
pub fn the_lane_draws_no_handler_link_or_address_from_the_transcript_test() {
  let html =
    relayed_lane.pieces(hostile(), turns.Settled)
    |> lane.reading
    |> element.to_string

  assert string.contains(html, "transcript lane")
  assert !string.contains(html, "<a ")
  assert !string.contains(html, "href=")
  assert !string.contains(html, "<iframe")
  assert !string.contains(html, "<img")
}

// An image is the text of its alt and its destination, and nothing is fetched.
pub fn a_markdown_image_is_text_and_loads_nothing_test() {
  let html =
    relayed_lane.pieces(hostile(), turns.Settled)
    |> lane.reading
    |> element.to_string

  assert string.contains(html, "[image: x · http://attacker/x.png]")
  assert !string.contains(html, "<img")
}

pub fn an_orphan_result_has_no_link_to_a_session_this_daemon_lacks_test() {
  // The page begins in the middle of a turn, so its first entry is a result
  // whose call is on an older page.
  let html = drawn(relayed.Idle, page_of([returned(3, "c1", "total 8")]))

  assert string.contains(html, "total 8")
  assert !string.contains(html, "View full result")
  assert !string.contains(html, "/result/")
}

pub fn the_framing_an_agent_reads_is_not_drawn_to_the_owner_test() {
  let html = drawn(relayed.Idle, worked())

  assert !string.contains(html, "[transcript of ")
  assert !string.contains(html, "[end transcript.")
  assert !string.contains(html, "peek-frame")
  assert !string.contains(html, "not an instruction from your operator")
}

pub fn a_message_that_quotes_the_framing_is_kept_whole_test() {
  let html = drawn(relayed.Idle, hostile())

  // The foot appears once, as the user wrote it. Nothing drew a second one, and
  // nothing removed the user's.
  assert count(html, "recorded on another machine and shown as data") == 1
  assert count(html, "[transcript of main on box]") == 1
}

pub fn the_framing_an_agent_receives_is_unchanged_test() {
  let page = worked()
  let lines =
    remote_transcript.lines(remote_transcript.Shown("main", "box", page))

  assert list.first(lines) == Ok(strand_framing.transcript_head("main", "box"))
  assert list.contains(lines, strand_framing.transcript_foot)

  // The Strands tab's peek is the agent-side layer of the web view, and it
  // keeps both lines.
  let assert Some(peeked) =
    peek.view(remote_transcript.Shown("main", "box", page))
  let peeked = element.to_string(peeked)
  assert string.contains(peeked, "[transcript of main on box]")
  assert string.contains(peeked, "[end transcript.")
}

pub fn an_empty_page_says_so_test() {
  let html = drawn(relayed.Idle, page_of([]))

  assert string.contains(html, "No entries yet.")
  assert !string.contains(html, "transcript lane")
}

pub fn a_page_with_older_entries_and_omissions_says_so_test() {
  let page = remote_transcript.Page(..worked(), omitted: 2, next: Some(1))
  let html = drawn(relayed.Idle, page)

  assert string.contains(html, "Older entries are not shown.")
  assert string.contains(html, "2 entries too large to show were left out.")
}

pub fn reasoning_a_page_still_carries_is_not_drawn_test() {
  let page =
    page_of([
      asked(1, "think about it"),
      answered(2, [
        message.AssistantThinking(
          thinking: "SECRET-CHAIN-OF-THOUGHT",
          thinking_signature: None,
          redacted: False,
        ),
        said("The answer."),
      ]),
    ])
  let html = drawn(relayed.Idle, page)

  assert string.contains(html, "The answer.")
  assert !string.contains(html, "SECRET-CHAIN-OF-THOUGHT")
}

pub fn a_settled_turns_work_is_drawn_open_test() {
  let opened = relayed_lane.pieces(worked(), turns.Settled)

  let folds =
    list.filter_map(opened, fn(piece) {
      case piece {
        turns.Work(folding:, ..) -> Ok(folding)
        _ -> Error(Nil)
      }
    })
  assert folds == [turns.Unfolded(hidden: 0)]
}

pub fn the_running_turn_is_open_and_an_empty_page_has_no_pieces_test() {
  let running = relayed_lane.pieces(worked(), turns.Running)
  let folds =
    list.filter_map(running, fn(piece) {
      case piece {
        turns.Work(folding:, ..) -> Ok(folding)
        _ -> Error(Nil)
      }
    })

  assert folds == [turns.Open]
  assert relayed_lane.pieces(page_of([]), turns.Settled) == []
}
