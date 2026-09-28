//// Agent-authored prose that reaches a strand from outside its own answer:
//// a sub-agent's report, returned by `agent_wait`, and a message another
//// session's agent sent. Both are model output, so the terminal draws their
//// bodies as Markdown, as it draws an advisor's, and as the web view draws
//// all three in its cards.

import core/entry
import core/json
import core/message
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import session_view/block_summary
import session_view/protocol
import session_view/transcript_line.{Line, System, ToolDetail, ToolResult}
import session_view/transcript_lines
import tui/render
import tui_test/gateway

// An entry envelope from the gateway fixture, carrying `body` instead.
fn entry_with(body: message.AgentMessage) -> entry.Entry {
  let assert Ok(protocol.EntryAdded(record)) =
    protocol.decode_event(gateway.tool_call_entry("main", "bash", "other", 2))
    as "the fixture supplies an entry envelope"
  let assert entry.MessageEntry(..) as placed = record.entry
    as "the fixture carries a message"
  entry.MessageEntry(..placed, message: body)
}

const report = "Found it.\n\n```python\nprint(1)\n```"

fn waited() -> entry.Entry {
  entry_with(message.ToolResultMessage(
    tool_call_id: "wait",
    tool_name: "agent_wait",
    content: [
      message.ToolResultText(
        "[sub:main/review-1a2b3c completed]\n" <> report,
        None,
      ),
    ],
    details: Some(
      json.Object([
        #(
          "results",
          json.Array([
            json.Object([
              #("strand", json.String("sub:main/review-1a2b3c")),
              #("state", json.String("ready")),
              #("outcome", json.String("completed")),
              #("report", json.String(report)),
              #("notes", json.Object([])),
            ]),
            json.Object([
              #("strand", json.String("sub:main/lint-4d5e6f")),
              #("state", json.String("pending")),
            ]),
          ]),
        ),
        #("pending", json.Bool(True)),
      ]),
    ),
    usage: None,
    added_tool_names: None,
    is_error: False,
    timestamp: 0,
  ))
}

pub fn an_expanded_wait_draws_the_report_as_prose_test() {
  let lines =
    transcript_lines.entry_lines(waited(), True, None, block_summary.new())
  assert lines
    == [
      Line(ToolResult, "agent_wait"),
      Line(System, "from sub:review · result · completed"),
      Line(ToolDetail, report),
      Line(System, "sub:lint · still working"),
    ]

  // The fence in the report is a code block, drawn under the code gutter,
  // rather than three backticks on a row of their own.
  let rows =
    lines
    |> list.flat_map(render.render_line(_, 80))
    |> list.map(fn(row) {
      row.spans |> list.map(fn(value) { value.content }) |> string.concat
    })
  assert list.any(rows, fn(row) { string.contains(row, "▎ print(1)") })
  assert !list.any(rows, fn(row) { string.contains(row, "```") })
}

pub fn a_collapsed_wait_keeps_its_one_row_test() {
  let assert [Line(ToolResult, row)] =
    transcript_lines.entry_lines(waited(), False, None, block_summary.new())
    as "a collapsed wait is one row"
  assert string.starts_with(row, "agent_wait · ")
}

pub fn a_peer_message_is_prose_under_its_source_test() {
  let sent =
    entry_with(message.UserMessage(
      content: [message.UserText("**R8** census is up", None)],
      timestamp: 0,
      origin: Some(message.PeerOrigin("lint-census", "main")),
    ))
  assert transcript_lines.entry_lines(sent, False, None, block_summary.new())
    == [
      Line(System, "peer · lint-census · main"),
      Line(ToolDetail, "**R8** census is up"),
    ]
}

// An aborted child's reason joins its heading, and a result it was asked for
// and gave is shown as its value, as the tool's own text shows it.
pub fn an_aborted_child_names_its_reason_and_its_result_test() {
  let aborted =
    entry_with(message.ToolResultMessage(
      tool_call_id: "wait",
      tool_name: "agent_wait",
      content: [message.ToolResultText("[sub:main/x-1a2b3c aborted]", None)],
      details: Some(
        json.Object([
          #(
            "results",
            json.Array([
              json.Object([
                #("strand", json.String("sub:main/x-1a2b3c")),
                #("state", json.String("ready")),
                #("outcome", json.String("aborted")),
                #("abort_reason", json.String("budget_expired")),
                #("report", json.String("")),
                #("notes", json.Object([])),
                #(
                  "result",
                  json.Object([
                    #("state", json.String("given")),
                    #("value", json.Int(7)),
                  ]),
                ),
              ]),
            ]),
          ),
        ]),
      ),
      usage: None,
      added_tool_names: None,
      is_error: False,
      timestamp: 0,
    ))
  assert transcript_lines.entry_lines(aborted, True, None, block_summary.new())
    == [
      Line(ToolResult, "agent_wait"),
      Line(System, "from sub:x · result · aborted · budget_expired"),
      Line(ToolDetail, "(no report: the run ended without a final answer)"),
      Line(System, "result · 7"),
    ]
}

// A long message collapsed to a preview is not drawn as Markdown: the
// preview can stop inside a fence and swallow the expand hint.
pub fn a_collapsed_long_peer_message_stays_literal_test() {
  let long = "```\n" <> string.repeat("line of code\n", 2000) <> "```"
  let sent =
    entry_with(message.UserMessage(
      content: [message.UserText(long, None)],
      timestamp: 0,
      origin: Some(message.PeerOrigin("lint-census", "main")),
    ))
  let assert [_, Line(System, preview)] =
    transcript_lines.entry_lines(sent, False, None, block_summary.new())
    as "a collapsed long peer message is a literal preview"
  assert preview != long
  let assert [_, Line(ToolDetail, whole)] =
    transcript_lines.entry_lines(sent, True, None, block_summary.new())
    as "an expanded peer message is Markdown"
  assert whole == long
}
