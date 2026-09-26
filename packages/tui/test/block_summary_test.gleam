//// Summarizer labels in the transcript (protocol 050): which blocks show
//// one, what a collapsed row reads in compact and detail mode, that every
//// form of a reasoning row stays one row, how a live label carries over to
//// the committed block, how long advisor messages collapse, and how a
//// reattaching terminal reads stored labels back.

import core/ids
import core/json
import etui/backend
import etui/geometry
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

const label = "The agent weighs two fixes and picks the bounded retry."

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

// A long block shows its label, marked as the summarizer's, in place of its
// opening line, and only in compact mode: detail mode is the full text.
// Without a label it is exactly today's digest.
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
        tui_model.ReasoningDigest,
        "summary: " <> label <> "  [Ctrl+G to expand]",
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

// The live row counts lines, then how long the generation has run, then the
// newest label; with neither a clock reading nor a label it is exactly the
// row it was before labels existed.
pub fn the_live_row_reads_lines_time_and_label_test() {
  assert transcript_lines.live_summary_digest("a\nb", 64, None)
    == "2 lines · 1m 04s so far"
  assert transcript_lines.live_summary_digest("a\nb", 9, None)
    == "2 lines · 9s so far"
  assert transcript_lines.live_summary_digest("a\nb", 0, None)
    == transcript_lines.live_reasoning_digest("a\nb")
  assert transcript_lines.live_summary_digest("a", 0, Some(label))
    == "1 line so far · summary: " <> label
}

// Every collapsed form of a reasoning row is one row at every width, which
// is what keeps the live-to-settled handoff and a label's arrival from
// moving the transcript.
pub fn every_reasoning_row_is_one_row_test() {
  let long_label = string.repeat("The agent weighs another option. ", 12)
  let rows = [
    transcript_lines.live_summary_digest(
      long_thinking(),
      3725,
      Some(long_label),
    ),
    transcript_lines.summarized_reasoning_digest(long_label),
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
      "The agent is reading the test.",
    )
  assert transcript_lines.labels_for(record.entry, live)
    == [#(0, "The agent is reading the test.")]

  let settled =
    block_summary.receive(
      live,
      block_summary.SettledBlock(Key(entry: id, block: 0)),
      label,
    )
  assert transcript_lines.labels_for(record.entry, settled) == [#(0, label)]
}

// The tick reads the generation clock into the model, and the live row
// built from the model carries the count, that reading and the label on
// one row.
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
  let assert [tui_model.Line(tui_model.ReasoningDigest, row)] =
    transcript_lines.stream_lines(
      ticked.streams,
      "main",
      notes_view.Excerpt,
      ticked.summaries,
      ticked.generation_elapsed_s,
    )
    as "the live stream is one reasoning row"
  assert string.starts_with(row, "3 lines · 1m ")
  assert string.ends_with(row, "s so far · summary: " <> label)
}

// A pushed label rewrites a row the record cache already holds: the frame
// painted before it shows the block's first line, and the frame after it
// shows the label on the same single row, without a new record arriving.
pub fn a_pushed_label_repaints_a_cached_row_test() {
  let record = thinking_record(long_thinking(), 5)
  let base =
    tui.new_model(connection.new_inbox(), workspace.Context("/work", None))
  let before =
    tui_model.Model(..base, records: [record]) |> tui.update(backend.Tick, _)
  assert string.contains(paint(before), "Opening line.  [Ctrl+G to expand]")

  let pushed =
    protocol.BlockSummarized(
      subject: block_summary.SettledBlock(Key(entry: id_of(record), block: 0)),
      text: label,
    )
  let after =
    before
    |> inbound.apply_channel_update(session_channel.Auxiliary(pushed))
    |> tui.update(backend.Tick, _)
  let painted = paint(after)
  assert string.contains(painted, "summary: The agent weighs two fixes")
  assert !string.contains(painted, "Opening line.")
}

// --- advisor messages ------------------------------------------------------------

// Long advice collapses in compact mode to its heading and the label; with
// no label yet, to its opening line. Detail mode shows the whole body.
// Short advice keeps its full body in both modes, as before.
pub fn long_advice_collapses_to_its_heading_and_label_test() {
  let body = "Rerun the verifier first.\n" <> string.repeat("Detail. ", 80)
  let advice = transcript_lines.Advice(body)

  assert transcript_lines.labelled_advisor_lines(
      advice,
      notes_view.Excerpt,
      Some("The advisor asks for a rerun."),
    )
    == [
      tui_model.Line(
        tui_model.System,
        "Advisor · block delivered: summary: The advisor asks for a rerun.  [Ctrl+G to expand]",
      ),
    ]
  assert transcript_lines.labelled_advisor_lines(
      advice,
      notes_view.Excerpt,
      None,
    )
    == [
      tui_model.Line(
        tui_model.System,
        "Advisor · block delivered: Rerun the verifier first.  [Ctrl+G to expand]",
      ),
    ]
  assert transcript_lines.labelled_advisor_lines(
      advice,
      notes_view.Complete,
      Some("The advisor asks for a rerun."),
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
      Some("The advisor asks for three checks."),
    )
    == [
      tui_model.Line(
        tui_model.System,
        "Advisor · nudges delivered (10): summary: The advisor asks for three checks.  [Ctrl+G to expand]",
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

fn paint(model: tui_model.Model) -> String {
  let #(buffer, _) = render.view(model, geometry.rect_new(0, 0, 160, 30))
  frame.buffer_to_text(buffer)
}

fn id_of(record: protocol.EntryRecord) -> String {
  ids.entry_id_to_string(record.entry.id)
}
