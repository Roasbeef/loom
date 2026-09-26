//// Summarizer labels in the transcript (protocol 050): which blocks show
//// one, what a collapsed block reads in compact and detail mode, how many
//// rows a summarized block takes, how a live label carries over to the
//// committed block, how long advisor messages collapse, that the anchor and
//// row projections stay parallel and the reader stays in place when a
//// summary adds rows, and how a reattaching terminal reads labels back.

import core/ids
import core/json
import etui/backend
import etui/geometry
import etui/span
import etui/text
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import tui
import tui/block_summary.{Key}
import tui/connection
import tui/frame
import tui/inbound
import tui/model as tui_model
import tui/notes_view
import tui/protocol
import tui/render
import tui/session_channel
import tui/transcript_lines
import tui/workspace
import tui_test/gateway
import tui_test/pushed

const label = "Found four bugs: touching intervals are not merged and exact-length gaps are dropped."

// --- which blocks, and what their rows read ------------------------------------

// A block under the floor keeps today's first-line digest and is not asked
// about, even if a label for it were somehow held.
pub fn a_short_block_keeps_its_first_line_digest_test() {
  let record = thinking_record("First.\nSecond.", 1)
  let id = id_of(record)
  let labels =
    block_summary.receive(
      block_summary.new(),
      block_summary.SettledBlock(Key(entry: id, block: 0)),
      label,
    )

  assert transcript_lines.summarizable_blocks(record.entry) == []
  assert transcript_lines.entry_lines(record.entry, False, None, labels)
    == [
      tui_model.Line(tui_model.ReasoningDigest, "First.  [Ctrl+G to expand]"),
    ]
}

// A long block with a label becomes a summarized block in compact mode: a
// header naming it as summarized, with the expand hint, and the label as
// its secondary text. Without a label it is exactly today's digest, and
// detail mode is the full text either way.
pub fn a_long_block_shows_its_label_in_compact_mode_only_test() {
  let text = long_thinking()
  let record = thinking_record(text, 2)
  let id = id_of(record)
  let labels =
    block_summary.receive(
      block_summary.new(),
      block_summary.SettledBlock(Key(entry: id, block: 0)),
      label,
    )

  assert transcript_lines.entry_lines(record.entry, False, None, labels)
    == [
      tui_model.Line(
        tui_model.SummarizedReasoning,
        "  [Ctrl+G to expand]\n" <> label,
      ),
    ]
  assert transcript_lines.entry_lines(
      record.entry,
      False,
      None,
      block_summary.new(),
    )
    == [
      tui_model.Line(
        tui_model.ReasoningDigest,
        transcript_lines.settled_reasoning_digest(text),
      ),
    ]
  assert transcript_lines.entry_lines(record.entry, True, None, labels)
    == [tui_model.Line(tui_model.Reasoning, text)]
}

// Unsummarized, the live row is the count and the clock on one row, and
// with no clock reading it is exactly the row it was before labels. The
// summarized header carries the same figures without "so far".
pub fn the_live_row_reads_lines_and_time_test() {
  assert transcript_lines.live_summary_digest("a\nb", 64)
    == "2 lines · 1m 04s so far"
  assert transcript_lines.live_summary_digest("a\nb", 9)
    == "2 lines · 9s so far"
  assert transcript_lines.live_summary_digest("a\nb", 0)
    == transcript_lines.live_reasoning_digest("a\nb")
  assert transcript_lines.live_summary_header("a\nb", 13) == " · 2 lines · 13s"
  assert transcript_lines.live_summary_header("a", 0) == " · 1 line"
}

// A summarized block paints as its header row and then at most three dim
// secondary rows, each within the pane; a longer summary ends in an
// ellipsis. The header carries the attribution, and the summary no prefix.
pub fn a_summarized_block_is_a_header_and_three_rows_at_most_test() {
  let long = string.repeat("Checked the merge of touching intervals. ", 20)
  list.each([30, 60, 120], fn(width) {
    let rows =
      render.render_line(
        transcript_lines.summarized_reasoning_line(
          transcript_lines.expand_hint,
          long,
        ),
        width,
      )
      |> list.map(row_text)
    let assert [header, ..summary] = rows as "a header row comes first"
    assert string.starts_with(header, render.summarized_mark)
    assert list.length(summary) == transcript_lines.summary_rows
    assert list.all(rows, fn(row) { text.cell_width(row) <= width })
    let assert Ok(last) = list.last(summary) as "the summary has rows"
    assert string.ends_with(last, "…")
    assert !list.any(summary, string.contains(_, "summary:"))
  })

  let short =
    render.render_line(
      transcript_lines.summarized_reasoning_line(
        transcript_lines.expand_hint,
        "Found it.",
      ),
      80,
    )
    |> list.map(row_text)
  assert short
    == [render.summarized_mark <> "  [Ctrl+G to expand]", "  Found it."]
}

// The live block that shows a summary and the settled block that borrows it
// paint the same number of rows, so the settle does not move the
// transcript.
pub fn live_and_settled_summarized_blocks_have_equal_height_test() {
  let live =
    transcript_lines.summarized_reasoning_line(
      transcript_lines.live_summary_header(long_thinking(), 3725),
      label,
    )
  let settled =
    transcript_lines.summarized_reasoning_line(
      transcript_lines.expand_hint,
      label,
    )
  list.each([30, 60, 120], fn(width) {
    assert list.length(render.render_line(live, width))
      == list.length(render.render_line(settled, width))
  })
}

// Every unsummarized collapsed form of a reasoning block stays one row at
// every width.
pub fn an_unsummarized_reasoning_row_is_one_row_test() {
  let rows = [
    transcript_lines.live_summary_digest(long_thinking(), 3725),
    transcript_lines.settled_reasoning_digest(long_thinking()),
  ]
  list.each([24, 40, 80, 200], fn(width) {
    list.each(rows, fn(text) {
      let line = tui_model.Line(tui_model.ReasoningDigest, text)
      assert list.length(render.render_line(line, width)) == 1
    })
  })
}

// A live label whose stream became a committed entry lends itself to that
// entry's first long reasoning block until the block's own label arrives,
// and then the stored label is what shows.
pub fn a_live_label_carries_over_until_the_stored_one_arrives_test() {
  let record = thinking_record(long_thinking(), 3)
  let id = id_of(record)
  let generation =
    json.to_string(
      json.Array([
        json.String("generation"),
        json.String("step-1"),
        json.Int(1),
        json.String(id),
      ]),
    )
  let live =
    block_summary.receive(
      block_summary.new(),
      block_summary.LiveStream("main", "op-1", generation),
      "Reading the failing test.",
    )
  assert transcript_lines.labels_for(record.entry, live)
    == [#(0, "Reading the failing test.")]

  let settled =
    block_summary.receive(
      live,
      block_summary.SettledBlock(Key(entry: id, block: 0)),
      label,
    )
  assert transcript_lines.labels_for(record.entry, settled) == [#(0, label)]
}

// The tick reads the generation clock into the model, and the live block
// built from the model carries the count and that reading in its header
// and the label beneath.
pub fn the_tick_times_the_live_row_test() {
  let base =
    tui.new_model(connection.new_inbox(), workspace.Context("/work", None))
  let labels =
    block_summary.receive(
      block_summary.new(),
      block_summary.LiveStream("main", "op-1", "g-1"),
      label,
    )
  let ticked =
    tui_model.Model(
      ..base,
      summaries: labels,
      generation_started_ms: Some(base.monotonic_time_ms() - 64_000),
      streams: [
        tui_model.Stream("main", "op-1", "g-1", "thinking", ["a\nb\nc"], 5),
      ],
    )
    |> tui.update(backend.Tick, _)

  // The clock is the real one, so the reading is 64 seconds plus however
  // long the test took to reach its tick.
  assert ticked.generation_elapsed_s >= 64
  let assert [tui_model.Line(tui_model.SummarizedReasoning, block)] =
    transcript_lines.stream_lines(
      ticked.streams,
      "main",
      notes_view.Excerpt,
      ticked.summaries,
      ticked.generation_elapsed_s,
    )
    as "the live stream is one summarized block"
  assert string.starts_with(block, " · 3 lines · 1m ")
  assert string.ends_with(block, "s\n" <> label)
}

// A pushed label rewrites rows the record cache already holds: the frame
// painted before it shows the block's first line, and the frame after it
// shows the summarized header and the label, without a new record.
pub fn a_pushed_label_repaints_a_cached_row_test() {
  let record = thinking_record(long_thinking(), 5)
  let base =
    tui.new_model(connection.new_inbox(), workspace.Context("/work", None))
  let before =
    tui_model.Model(..base, records: [record]) |> tui.update(backend.Tick, _)
  assert string.contains(paint(before), "Opening line.  [Ctrl+G to expand]")

  let after =
    before
    |> inbound.apply_channel_update(
      session_channel.Auxiliary(settled_push(record, label)),
    )
    |> tui.update(backend.Tick, _)
  let painted = paint(after)
  assert string.contains(painted, render.summarized_mark)
  assert string.contains(painted, "Found four bugs: touching intervals")
  assert !string.contains(painted, "Opening line.")
}

// A summarized block adds rows, so the anchor projection the reading view
// keeps has to add the same rows: with a summarized block in the history
// and the reader scrolled back, there is one anchor per record row.
pub fn a_summarized_block_keeps_anchors_parallel_to_rows_test() {
  let records = history_with_thought(30)
  let summarized = summarize(reading(records), thought_of(records))
  assert !list.is_empty(summarized.rendered_anchors)
    as "scrolling back must freeze anchors"
  assert list.length(summarized.rendered_anchors)
    == list.length(summarized.record_rows)
}

// A summary that arrives while the reader is scrolled back adds rows to a
// block off screen, above or below the viewport, and the rows on screen do
// not move.
pub fn a_summary_off_screen_leaves_the_reader_in_place_test() {
  list.each([2, 58], fn(at) {
    let records = history_with_thought(at)
    let before = reading(records)
    let after = summarize(before, thought_of(records))
    assert paint(after) == paint(before)
  })
}

// --- advisor messages ------------------------------------------------------------

// Long advice collapses in compact mode to its heading and, beneath it, the
// label with the heading marked as summarized, or the opening line with no
// label yet. Detail mode shows the whole body. Short advice keeps its full
// body in both modes, as before.
pub fn long_advice_collapses_to_its_heading_and_label_test() {
  let body = "Rerun the verifier first.\n" <> string.repeat("Detail. ", 80)
  let advice = transcript_lines.Advice(body)

  assert transcript_lines.labelled_advisor_lines(
      advice,
      notes_view.Excerpt,
      Some("Asks for a rerun."),
    )
    == [
      tui_model.Line(
        tui_model.SummarizedAdvice,
        "Advisor · block delivered (summarized)  [Ctrl+G to expand]\nAsks for a rerun.",
      ),
    ]
  assert transcript_lines.labelled_advisor_lines(
      advice,
      notes_view.Excerpt,
      None,
    )
    == [
      tui_model.Line(
        tui_model.SummarizedAdvice,
        "Advisor · block delivered  [Ctrl+G to expand]\nRerun the verifier first.",
      ),
    ]
  assert transcript_lines.labelled_advisor_lines(
      advice,
      notes_view.Complete,
      Some("Asks for a rerun."),
    )
    == [
      tui_model.Line(tui_model.System, "Advisor · block delivered"),
      tui_model.Line(tui_model.ToolDetail, body),
    ]

  let short = transcript_lines.Advice("Looks fine.")
  assert transcript_lines.labelled_advisor_lines(
      short,
      notes_view.Excerpt,
      Some("unused"),
    )
    == [
      tui_model.Line(tui_model.System, "Advisor · block delivered"),
      tui_model.Line(tui_model.ToolDetail, "Looks fine."),
    ]

  let rows =
    render.render_line(
      tui_model.Line(
        tui_model.SummarizedAdvice,
        "Advisor · block delivered (summarized)  [Ctrl+G to expand]\n"
          <> string.repeat("Asks for a rerun. ", 30),
      ),
      60,
    )
    |> list.map(row_text)
  let assert ["◇ Advisor · block delivered (summarized)" <> _, ..rest] = rows
    as "the heading is the first row"

  // Three summary rows and the blank every system row closes with.
  assert list.length(rest) == transcript_lines.summary_rows + 1
}

// A long nudges message collapses the same way and keeps its count.
pub fn long_nudges_collapse_with_their_count_test() {
  let body =
    int.range(from: 10, to: 0, with: [], run: fn(lines, index) {
      [
        "- nudge " <> int.to_string(index) <> " " <> string.repeat("x", 60),
        ..lines
      ]
    })
    |> string.join("\n")
  assert transcript_lines.labelled_advisor_lines(
      transcript_lines.Nudges(body),
      notes_view.Excerpt,
      Some("Asks for three checks."),
    )
    == [
      tui_model.Line(
        tui_model.SummarizedAdvice,
        "Advisor · nudges delivered (10) (summarized)  [Ctrl+G to expand]\nAsks for three checks.",
      ),
    ]
}

// --- reading labels back -----------------------------------------------------------

// Blocks are asked about once per attachment, at most thirty-two to a read,
// and a refusal ends the asking for the attachment.
pub fn reads_are_batched_once_and_end_on_refusal_test() {
  let keys =
    int.range(from: 39, to: -1, with: [], run: fn(keys, index) {
      [Key(entry: "e", block: index), ..keys]
    })
  let labels = block_summary.want(block_summary.new(), keys)

  let assert Some(#(first, labels)) = block_summary.next_read(labels)
    as "the first read goes out"
  assert list.length(first) == block_summary.max_blocks
  let assert Some(#(second, labels)) = block_summary.next_read(labels)
    as "the rest follow"
  assert list.length(second) == 8
  assert block_summary.next_read(labels) == None
  assert block_summary.next_read(block_summary.want(labels, keys)) == None

  let refused =
    block_summary.refused(block_summary.want(block_summary.new(), keys))
  assert block_summary.next_read(refused) == None
}

// A reattaching terminal's read: the command takes the read lane, its reply
// settles it, and the returned label replaces the block's first-line
// digest. An unlisted command name would hold the mutation lane forever,
// and an unlisted reply shape would fail the channel.
pub fn a_label_read_back_by_exact_key_labels_the_block_test() {
  let record = thinking_record(long_thinking(), 4)
  let id = id_of(record)
  let model = pushed.attached()
  let assert Some(channel) = model.channel
    as "fixture has a synchronized channel"
  let #(channel, disposition) =
    session_channel.submit(
      channel,
      protocol.block_summaries(999, [Key(entry: id, block: 0)]),
    )
  let assert session_channel.Sent("block_summaries", request) = disposition
    as "the label read is issued with the lane's request id"
  assert session_channel.mutation_available(channel)
    as "a label read never holds the composer's lane"

  let body =
    json.Object([
      #("mode", json.String("block_summaries")),
      #(
        "board",
        json.Object([
          #(
            "summaries",
            json.Array([
              json.Object([
                #("entry", json.String(id)),
                #("block", json.Int(0)),
                #("text", json.String(label)),
              ]),
            ]),
          ),
        ]),
      ),
    ])
  let #(channel, updates) =
    session_channel.receive(channel, pushed.reply(request, "snapshot", body))
  let assert [session_channel.Auxiliary(event)] = updates
    as "the reply is an auxiliary answer, not an answer to no command"
  assert session_channel.ready_for_read(channel)

  let labelled =
    inbound.apply_channel_update(
      tui_model.Model(..model, records: [record]),
      session_channel.Auxiliary(event),
    )
  assert transcript_lines.labels_for(record.entry, labelled.summaries)
    == [#(0, label)]
}

// An older daemon refuses the read. The terminal says nothing about it and
// stops asking for this attachment.
pub fn a_refused_read_is_silent_test() {
  let base =
    tui.new_model(connection.new_inbox(), workspace.Context("/work", None))
  let refused =
    inbound.apply_channel_update(
      base,
      session_channel.RequestRefused(
        "block_summaries",
        7,
        "unsupported",
        "unknown command",
      ),
    )
  assert refused.transcript == base.transcript
  let wanted =
    block_summary.want(refused.summaries, [Key(entry: "e", block: 0)])
  assert block_summary.next_read(wanted) == None
}

// A pushed label decodes to its subject, and a subject this build does not
// know is ignored rather than closing the socket.
pub fn pushed_labels_decode_and_unknown_subjects_are_ignored_test() {
  let push = fn(body: List(#(String, json.JsonValue))) {
    json.to_string(
      json.Object([
        #("v", json.Int(2)),
        #("event", json.String("block_summary")),
        #("body", json.Object(body)),
      ]),
    )
  }

  let assert Ok(protocol.BlockSummarized(
    subject: block_summary.SettledBlock(Key(entry: "e", block: 2)),
    text: "x",
  )) =
    protocol.decode_v2_pushed(
      push([
        #("subject", json.String("block")),
        #("entry", json.String("e")),
        #("block", json.Int(2)),
        #("text", json.String("x")),
      ]),
    )
    as "a settled label decodes"
  let assert Ok(protocol.BlockSummarized(
    subject: block_summary.LiveStream("main", "op-1", "g-1"),
    ..,
  )) =
    protocol.decode_v2_pushed(
      push([
        #("subject", json.String("stream")),
        #("strand", json.String("main")),
        #("op", json.String("op-1")),
        #("generation", json.String("g-1")),
        #("text", json.String("x")),
      ]),
    )
    as "a live label decodes"
  assert protocol.decode_v2_pushed(
      push([#("subject", json.String("session")), #("text", json.String("x"))]),
    )
    == Ok(protocol.Ignored("block_summary.session"))
}

// --- fixtures ------------------------------------------------------------------

fn long_thinking() -> String {
  "Opening line.\n" <> string.repeat("The agent considers the retry path. ", 30)
}

fn thinking_record(thinking: String, seq: Int) -> protocol.EntryRecord {
  let assert Ok(protocol.EntryAdded(record)) =
    protocol.decode_event(gateway.thinking_entry("main", thinking, seq))
    as "the thinking fixture must decode"
  record
}

// Forty tool calls around one long reasoning block at position `at`, so a
// scrolled-back viewport can hold the block above it, below it or on it.
fn history_with_thought(at: Int) -> List(protocol.EntryRecord) {
  int.range(1, 61, [], fn(acc, n) {
    let seq = n * 10
    let id = "c" <> int.to_string(n)
    let wires = case n == at {
      True -> [gateway.thinking_entry("main", long_thinking(), seq + 5)]
      False -> []
    }
    list.append(wires, [
      gateway.identified_tool_result_ok_entry("main", id, "ok", seq + 1),
      gateway.identified_tool_call_entry(
        "main",
        id,
        "bash",
        "echo " <> int.to_string(n),
        seq,
      ),
      ..acc
    ])
  })
  |> list.reverse
  |> list.map(fn(wire) {
    let assert Ok(protocol.EntryAdded(record)) = protocol.decode_event(wire)
      as "the fixture decodes"
    record
  })
  |> list.reverse
}

fn thought_of(records: List(protocol.EntryRecord)) -> protocol.EntryRecord {
  let assert Ok(record) =
    list.find(records, fn(record) {
      transcript_lines.summarizable_blocks(record.entry) != []
    })
    as "the history holds one long reasoning block"
  record
}

// The history on screen, scrolled back into the middle.
fn reading(records: List(protocol.EntryRecord)) -> tui_model.Model {
  let base =
    tui.new_model(connection.new_inbox(), workspace.Context("/work", None))
  tui_model.Model(..base, records:)
  |> tui.update(backend.Resize(100, 20), _)
  |> tui.update(backend.MouseScroll(5, 5, True), _)
  |> tui.update(backend.MouseScroll(5, 5, True), _)
  |> tui.update(backend.MouseScroll(5, 5, True), _)
}

fn summarize(
  model: tui_model.Model,
  record: protocol.EntryRecord,
) -> tui_model.Model {
  model
  |> inbound.apply_channel_update(
    session_channel.Auxiliary(settled_push(record, label)),
  )
  |> tui.update(backend.Tick, _)
}

fn settled_push(record: protocol.EntryRecord, text: String) -> protocol.Event {
  protocol.BlockSummarized(
    subject: block_summary.SettledBlock(Key(entry: id_of(record), block: 0)),
    text:,
  )
}

fn row_text(row: span.Line) -> String {
  row.spans |> list.map(fn(value) { value.content }) |> string.concat
}

fn paint(model: tui_model.Model) -> String {
  let #(buffer, _) = render.view(model, geometry.rect_new(0, 0, 160, 30))
  frame.buffer_to_text(buffer)
}

fn id_of(record: protocol.EntryRecord) -> String {
  ids.entry_id_to_string(record.entry.id)
}
