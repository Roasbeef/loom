//// `transcript.project` draws one strand of a capture from the records on
//// that strand's ancestry, oldest first, and nothing from another strand's
//// branch that shares the same window. The advisor's commentary board is
//// drawn only on `main`.

import core/clock
import core/entry
import core/ids
import core/json
import core/message
import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import session_view/snapshot
import session_view/snapshot_view
import session_view/transcript
import session_view/transcript_line

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
