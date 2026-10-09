//// Summarizer labels applied to a lane's pieces when it is drawn.
////
//// The pieces here are built by hand from one response that holds two long
//// reasoning blocks, a short one and some prose, so each test names the row it
//// expects to change and the rows it expects to leave alone.

import core/clock
import core/entry
import core/ids
import core/json
import core/message
import core/usage_evidence
import gleam/dict
import gleam/option.{None, Some}
import gleam/string
import session_view/block_summary
import session_view/transcript_line.{Line}
import session_view/transcript_lines.{Block, FromEntry}
import session_view/turn_labels
import session_view/turns

fn id(seq: Int) -> ids.EntryId {
  ids.mint_entry(ids.generator(clock.fixed(1000), seq)).0
}

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

fn long(word: String) -> String {
  word <> " " <> string.repeat("and then the next thing. ", 30)
}

// A response of content blocks 0 (long reasoning), 1 (prose), 2 (a call), 3
// (long reasoning) and 4 (short reasoning), which draws one row for each block
// that is not a call.
fn response() -> entry.Entry {
  response_of([
    message.AssistantThinking(long("first"), None, False),
    message.AssistantText("In between.", None),
    message.AssistantToolCall(message.ToolCall(
      "c1",
      "fs_read",
      json.Object([]),
      None,
      None,
    )),
    message.AssistantThinking(long("second"), None, False),
    message.AssistantThinking("short", None, False),
  ])
}

fn response_of(content: List(message.AssistantBlock)) -> entry.Entry {
  entry.MessageEntry(
    id(7),
    None,
    7,
    10_000,
    message.AssistantMessage(
      content,
      "test",
      "test",
      "test",
      None,
      None,
      None,
      usage(),
      message.Stop,
      None,
      None,
      None,
      None,
      0,
    ),
    False,
  )
}

fn rows() -> List(#(String, transcript_line.Line)) {
  [
    #("7.0:0", Line(transcript_line.ReasoningDigest, "first digest")),
    #("7.0:1", Line(transcript_line.Assistant, "In between.")),
    #("7.0:2", Line(transcript_line.ReasoningDigest, "second digest")),
    #("7.0:3", Line(transcript_line.ReasoningDigest, "short")),
  ]
}

fn piece() -> turns.Piece {
  turns.Plain(Block("7.0", FromEntry(response()), rows()), dict.new(), None)
}

fn labelled(
  piece: turns.Piece,
  labels: block_summary.Labels,
) -> List(#(String, transcript_line.Line)) {
  let assert [turns.Plain(block:, ..)] = turn_labels.apply([piece], labels)
  block.rows
}

fn stored(index: Int, text: String) -> block_summary.Labels {
  block_summary.receive(
    block_summary.new(),
    block_summary.SettledBlock(block_summary.Key(
      ids.entry_id_to_string(id(7)),
      index,
    )),
    text,
  )
}

pub fn a_book_with_no_labels_changes_nothing_test() {
  assert turn_labels.apply([piece()], block_summary.new()) == [piece()]
}

// The label is of the content block, which counts the call, so the second
// reasoning block is block 3 and its row is the third row.
pub fn a_stored_label_replaces_the_digest_of_its_own_block_only_test() {
  let assert [first, between, second, short] =
    labelled(piece(), stored(3, "Settled on the second idea."))
  assert first
    == #("7.0:0", Line(transcript_line.ReasoningDigest, "first digest"))
  assert between == #("7.0:1", Line(transcript_line.Assistant, "In between."))
  assert short == #("7.0:3", Line(transcript_line.ReasoningDigest, "short"))

  // The row keeps its key, is spoken as a summary and carries the label after
  // the terminal's header line.
  assert second.0 == "7.0:2"
  assert { second.1 }.speaker == transcript_line.SummarizedReasoning
  assert string.ends_with({ second.1 }.text, "\nSettled on the second idea.")
}

// A short block is never labelled by the daemon, so a label keyed to it, which
// can only be a mistake, is not drawn.
pub fn a_short_block_is_not_labelled_test() {
  assert labelled(piece(), stored(4, "A label for a short block.")) == rows()
}

// The stream's own label is carried to the entry's first long reasoning block
// and to no other, and the block's stored label then takes its place.
pub fn a_carried_label_goes_to_the_first_long_block_until_its_own_arrives_test() {
  let generation =
    "[\"generation\",\"op\",0,\"" <> ids.entry_id_to_string(id(7)) <> "\"]"
  let carried =
    block_summary.receive(
      block_summary.new(),
      block_summary.LiveStream("main", "op", generation),
      "Streamed label",
    )
  let assert [first, _, second, _] = labelled(piece(), carried)
  assert { first.1 }.speaker == transcript_line.SummarizedReasoning
  assert string.ends_with({ first.1 }.text, "\nStreamed label")
  assert { second.1 }.speaker == transcript_line.ReasoningDigest

  let replaced =
    block_summary.receive(
      carried,
      block_summary.SettledBlock(block_summary.Key(
        ids.entry_id_to_string(id(7)),
        0,
      )),
      "Stored label",
    )
  let assert [first, ..] = labelled(piece(), replaced)
  assert string.ends_with({ first.1 }.text, "\nStored label")
}

// A turn's work holds its blocks as items, and a closed turn's items are the
// steps its opened fold read: both are drawn from the labels at the time.
pub fn the_blocks_of_a_turns_work_are_labelled_too_test() {
  let work =
    turns.Work(
      "work:7.0",
      turns.Worked(None, 1, 0, 0, turns.Finished),
      [
        turns.Narrated(
          Block("7.0", FromEntry(response()), rows()),
          dict.new(),
          None,
        ),
      ],
      turns.Unfolded(hidden: 0),
      Some(7),
    )
  let assert [turns.Work(items: [turns.Narrated(block:, ..)], ..)] =
    turn_labels.apply([work], stored(0, "In a fold."))
  let assert [#(_, first), ..] = block.rows
  assert first.speaker == transcript_line.SummarizedReasoning
}

pub fn the_keys_are_the_long_reasoning_blocks_of_the_responses_drawn_test() {
  let entry_text = ids.entry_id_to_string(id(7))
  assert turn_labels.keys([piece()])
    == [
      block_summary.Key(entry_text, 0),
      block_summary.Key(entry_text, 3),
    ]

  // A piece that draws no response has none.
  assert turn_labels.keys([
      turns.Missed("9.0", "cache miss"),
      turns.Plain(
        Block("8.0", transcript_lines.FromSpacer, []),
        dict.new(),
        None,
      ),
    ])
    == []
}

// A sealed turn holds no full reasoning text, but the response it was drawn
// from does, so each reasoning row's line count is read from there: by the
// row's key, for the blocks that have text, walking the rows and the blocks
// together. A redacted block has no text and so no count, and a response that
// is not an entry has none.
pub fn the_lines_of_each_reasoning_row_are_read_from_its_response_test() {
  let content = [
    message.AssistantThinking("one\ntwo\nthree", None, False),
    message.AssistantText("In between.", None),
    message.AssistantThinking("hidden", Some("sig"), True),
    message.AssistantThinking("a\nb", None, False),
  ]
  let block =
    Block("7.0", FromEntry(response_of(content)), [
      #("7.0:0", Line(transcript_line.ReasoningDigest, "one")),
      #("7.0:1", Line(transcript_line.Assistant, "In between.")),
      #("7.0:2", Line(transcript_line.ReasoningDigest, "redacted")),
      #("7.0:3", Line(transcript_line.SummarizedReasoning, "x\nlabel")),
    ])
  assert turns.reasoning_lines(block)
    == dict.from_list([#("7.0:0", 3), #("7.0:3", 2)])

  let notice = Block("7.1", transcript_lines.FromNotice, block.rows)
  assert turns.reasoning_lines(notice) == dict.new()
}
