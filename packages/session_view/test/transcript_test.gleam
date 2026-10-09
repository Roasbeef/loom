//// `transcript.project` draws one strand of a capture from the records on
//// that strand's ancestry, oldest first, and nothing from another strand's
//// branch that shares the same window. The advisor's commentary board is
//// drawn only on `main`.

import core/clock
import core/entry
import core/ids
import core/json
import core/message
import core/usage_evidence
import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import session_view/history_view
import session_view/protocol
import session_view/snapshot
import session_view/snapshot_view
import session_view/transcript
import session_view/transcript_line
import session_view/transcript_lines

fn id(seq: Int) -> ids.EntryId {
  ids.mint_entry(ids.generator(clock.fixed(1000), seq)).0
}

fn said(seq: Int, parent: Option(Int), text: String) -> snapshot.Item {
  snapshot.Loaded(
    entry.MessageEntry(
      id(seq),
      option.map(parent, id),
      seq,
      1000,
      message.UserMessage([message.UserText(text, None)], 1000, None),
      False,
    ),
    100,
  )
}

fn view(leaves: List(#(String, Int))) -> snapshot_view.View {
  snapshot_view.View(
    [],
    leaves
      |> list.map(fn(leaf) { #(leaf.0, Some(id(leaf.1))) })
      |> dict.from_list,
    dict.new(),
    dict.new(),
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
    ),
    snapshot_view.RunSettings("one_at_a_time", "parallel", None),
    [],
    [],
    None,
    None,
    None,
  )
}

fn cut(items: List(snapshot.Item)) -> snapshot.Captured {
  snapshot.Captured(
    snapshot.Attachment(
      snapshot.Expected("session", "epoch", "incarnation"),
      "tab",
      message.Origin("principal-Alice", "Alice"),
      snapshot.Observer,
    ),
    list.length(items) + 1,
    // The projection never decodes the metadata; the view stands for it.
    json.Null,
    snapshot.Window(items, list.length(items) * 100, None),
    None,
  )
}

fn spoken(lines: List(transcript_line.Line)) -> List(String) {
  list.filter_map(lines, fn(line) {
    case line.speaker {
      transcript_line.User -> Ok(line.text)
      _ -> Error(Nil)
    }
  })
}

pub fn a_strand_is_drawn_from_its_own_ancestry_oldest_first_test() {
  // The window is newest first, as a capture holds it. "sub" forks from the
  // first entry, so its entry shares the window but not main's ancestry.
  let items = [
    said(3, Some(1), "on the fork"),
    said(2, Some(1), "second"),
    said(1, None, "first"),
  ]
  let captured = cut(items)
  let shown = view([#("main", 2), #("sub", 3)])

  assert spoken(transcript.project(captured, shown, "main"))
    == ["first", "second"]
  assert spoken(transcript.project(captured, shown, "sub"))
    == ["first", "on the fork"]
}

pub fn an_empty_window_draws_no_records_test() {
  assert transcript.project(cut([]), view([#("main", 1)]), "main") == []
}

fn advised(seq: Int, parent: Int, text: String) -> snapshot.Item {
  snapshot.Loaded(
    entry.MessageEntry(
      id(seq),
      Some(id(parent)),
      seq,
      1000,
      message.AssistantMessage(
        [message.AssistantText(text, None)],
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
        1000,
      ),
      False,
    ),
    100,
  )
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

fn mentions(lines: List(transcript_line.Line), text: String) -> Int {
  list.count(lines, fn(line) { string.contains(line.text, text) })
}

pub fn only_main_shows_the_advisor_board_test() {
  // The advisor forks from main's root and comments once. "sub" shares the
  // root and nothing else.
  let commentary = "Watch the edge case."
  let items = [
    advised(3, 2, commentary),
    said(2, Some(1), "advisor feed"),
    said(1, None, "first"),
  ]
  let captured = cut(items)
  let shown = view([#("main", 1), #("advisor", 3), #("sub", 1)])

  // Main draws the commentary from the board. The advisor draws it once, as
  // its own entry, and another strand never draws it.
  assert mentions(transcript.project(captured, shown, "main"), commentary) > 0
  assert mentions(transcript.project(captured, shown, "advisor"), commentary)
    == 1
  assert mentions(transcript.project(captured, shown, "sub"), commentary) == 0
}

fn keys(rows: List(transcript.Row)) -> List(String) {
  list.map(rows, fn(row) { row.key })
}

// The keyed rows are the projection's own lines, in its order, whatever the
// strand, so a host that keys its list draws exactly what `project` draws.
pub fn keyed_rows_are_the_projected_lines_test() {
  let items = [
    advised(4, 3, "Watch the edge case."),
    said(3, Some(2), "third"),
    said(2, Some(1), "second"),
    said(1, None, "first"),
  ]
  let captured = cut(items)
  let shown = view([#("main", 3), #("advisor", 4)])
  list.each(["main", "advisor"], fn(strand) {
    let rows = transcript.project_rows(captured, shown, strand)
    assert list.map(rows, fn(row) { row.line })
      == transcript.project(captured, shown, strand)
    assert list.unique(keys(rows)) == keys(rows) as "every row has its own key"
  })
}

// A window that has moved past its oldest entry drops that entry's rows,
// and every row that remains keeps the key it had.
pub fn a_row_keeps_its_key_when_the_head_is_dropped_test() {
  let wide =
    cut([
      said(3, Some(2), "third"),
      said(2, Some(1), "second"),
      said(1, None, "first"),
    ])
  let narrow = cut([said(3, Some(2), "third"), said(2, Some(1), "second")])
  let shown = view([#("main", 3)])
  let before = transcript.project_rows(wide, shown, "main")
  let after = transcript.project_rows(narrow, shown, "main")
  assert after != []
  assert list.all(after, fn(row) { list.contains(before, row) })
    as "each remaining row has the key and line it had before"
}

// A key is a list key in the web view, whose event paths separate segments
// with tab, carriage return and newline; a key holds none of them.
pub fn a_key_holds_no_path_separator_test() {
  let rows =
    transcript.project_rows(
      cut([said(2, Some(1), "a\tb\nc"), said(1, None, "first")]),
      view([#("main", 2)]),
      "main",
    )
  assert rows != []
  assert list.all(keys(rows), fn(key) {
    !string.contains(key, "\t")
    && !string.contains(key, "\n")
    && !string.contains(key, "\r")
  })
}

// A host that keeps a history window draws the same blocks from it as from
// the capture that filled it, each with the same key, and reads a block's
// sequence back from its key.
pub fn branch_blocks_are_the_capture_blocks_test() {
  let captured =
    cut([
      said(3, Some(2), "third"),
      said(2, Some(1), "second"),
      said(1, None, "first"),
    ])
  let shown = view([#("main", 3)])
  let history =
    history_view.empty()
    |> history_view.capture(captured.window, shown, "main")
  let kept =
    transcript.branch_blocks(
      history_view.branch(history, shown),
      captured,
      shown,
      "main",
      [],
    )
  assert kept == transcript.blocks(captured, shown, "main", [])
  let assert [first, ..] = kept as "the window draws its entries"
  assert transcript_lines.block_seq(first) == Ok(1)
}

// Trimming a live window drops the records older than the sequence given,
// and the next read asks for the interval below what is left. A window
// with a read owed is left alone, since the read was sized from it.
pub fn a_live_window_is_trimmed_to_what_is_drawn_test() {
  let captured =
    cut([
      said(3, Some(2), "third"),
      said(2, Some(1), "second"),
      said(1, None, "first"),
    ])
  let shown = view([#("main", 3)])
  let history =
    history_view.empty()
    |> history_view.capture(captured.window, shown, "main")
  let trimmed = history_view.retain_from(history, 2)
  assert trimmed.before_seq == 2
  assert list.length(trimmed.window.items) == 2
  assert history_view.branch(trimmed, shown).unloaded != None
  assert spoken(
      list.flat_map(
        transcript.branch_blocks(
          history_view.branch(trimmed, shown),
          captured,
          shown,
          "main",
          [],
        ),
        fn(block) { list.map(block.rows, fn(row) { row.1 }) },
      ),
    )
    == ["second", "third"]

  let owed = history_view.older(trimmed, Some("parent"))
  assert history_view.retain_from(owed, 3) == owed
}

// A page read below the window can hold none of the strand's ancestry,
// when another strand wrote every sequence in it. The next capture keeps
// the progress `accept` made past that interval, so the next read asks for
// the sequences below it and not the same ones again.
pub fn a_capture_keeps_the_progress_of_an_empty_read_test() {
  // Main's record at 200 names 2 as its parent; 100 to 199 are elsewhere.
  let captured =
    cut([said(201, Some(200), "later"), said(200, Some(2), "resumed")])
  let shown = view([#("main", 201)])
  let history =
    history_view.empty()
    |> history_view.capture(captured.window, shown, "main")
  assert history.before_seq == 200

  let wanted =
    history_view.older(history, history_view.branch(history, shown).unloaded)
  let assert Some(#(after, before)) = history_view.range(wanted)
    as "a read is owed"
  let page =
    snapshot.Window(
      [said(199, Some(198), "elsewhere"), said(150, Some(149), "elsewhere")],
      200,
      None,
    )
  let read =
    history_view.accept(
      history_view.sent(wanted, before),
      page,
      before,
      after,
      shown,
    )
    |> history_view.resume
    |> history_view.capture(captured.window, shown, "main")
  assert read.before_seq == after + 1
  assert read.before_seq < 200
}

// The identity a request that reserved an entry carries, as the daemon
// writes it: the entry its answer will be committed as is its last element.
fn generation(seq: Int) -> String {
  "[\"generation\",\"op-1\",0,\"" <> ids.entry_id_to_string(id(seq)) <> "\"]"
}

fn streaming(generation: String) -> transcript_line.Stream {
  transcript_line.Stream("main", "op-1", generation, "text", ["hi"], 2)
}

fn record_of(item: snapshot.Item) -> List(protocol.EntryRecord) {
  case item {
    snapshot.Loaded(entry, _) -> [protocol.EntryRecord("main", entry)]
    snapshot.Unloaded(..) -> []
  }
}

// A response is owed while its entry is not held and its operation still
// runs; either ending it lets the host stop drawing the stream.
pub fn a_response_is_owed_until_its_entry_or_its_operation_ends_test() {
  let running = dict.from_list([#("main", "op-1")])
  let stream = streaming(generation(2))

  assert transcript_lines.response_awaited([], running, stream)

  // The entry the request reserved is held: the record replaces the stream.
  assert !transcript_lines.response_awaited(
    record_of(said(2, Some(1), "answer")),
    running,
    stream,
  )

  // Another entry does not.
  assert transcript_lines.response_awaited(
    record_of(said(3, Some(1), "other")),
    running,
    stream,
  )

  // The operation is over with no entry: nothing will replace the stream.
  assert !transcript_lines.response_awaited([], dict.new(), stream)
  assert !transcript_lines.response_awaited(
    [],
    dict.from_list([#("main", "op-2")]),
    stream,
  )
}

pub fn a_stream_naming_no_entry_is_never_owed_test() {
  let running = dict.from_list([#("main", "op-1")])
  assert !transcript_lines.response_awaited(
    [],
    running,
    streaming("legacy-request"),
  )
}
