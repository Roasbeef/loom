//// `transcript.project` draws one strand of a capture from the records on
//// that strand's ancestry, oldest first, and nothing from another strand's
//// branch that shares the same window.

import core/clock
import core/entry
import core/ids
import core/json
import core/message
import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
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
