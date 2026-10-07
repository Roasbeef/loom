//// The summarizer's labels on the lane's settled reasoning rows.
////
//// A long reasoning block that streams shows its label beneath the live row.
//// These tests hold the settled row to the terminal's: the block keeps the
//// label it streamed with until its stored label arrives, a stored label
//// replaces it, a label that arrives after the turn was sealed or the fold
//// read still shows, and the page reads the stored labels it lacks for the
//// blocks it draws, in bounded reads and once per block. The label is
//// summarizer text, so it is only ever drawn as text.

import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set
import gleam/string
import lane_fixture
import lustre/element
import page_fixture
import session_view/block_summary
import session_view/protocol
import session_view/session_channel
import session_view/turns
import web_view/component
import web_view/operator_page

const summarized = "<span class=\"verb\">Reasoning (summarized)</span>"

const raw = "<span class=\"verb\">Reasoning</span>"

fn running() -> Option(String) {
  Some(lane_fixture.main_op())
}

fn page(updates) {
  component.new(page_fixture.start()) |> component.apply(updates)
}

// Both pages draw the lane the same way.
fn drawn(model) -> List(String) {
  [
    element.to_string(component.view(model)),
    element.to_string(operator_page.view(model)),
  ]
}

// The stored label of the first block of the response at `seq`.
fn stored(seq: Int, text: String) -> session_channel.Update {
  session_channel.Auxiliary(protocol.BlockSummarized(
    block_summary.SettledBlock(block_summary.Key(
      lane_fixture.entry_text(seq),
      0,
    )),
    text,
  ))
}

// The live label of the stream that writes the response at `seq`.
fn streaming(seq: Int, text: String) -> session_channel.Update {
  session_channel.Auxiliary(protocol.BlockSummarized(
    block_summary.LiveStream(
      "main",
      lane_fixture.main_op(),
      lane_fixture.generation(seq),
    ),
    text,
  ))
}

// A page whose turn is running, with the reasoning of its first response
// streaming and labelled.
fn labelled_stream() {
  page([
    lane_fixture.reasoned(0, 0, running()),
    lane_fixture.fragment(
      lane_fixture.generation(2),
      "thinking",
      lane_fixture.thought(2),
    ),
    streaming(2, "Found a lock-order mismatch"),
  ])
}

fn preview(label: String) -> String {
  "<span class=\"subject preview\">" <> label <> "</span>"
}

fn count(haystack: String, needle: String) -> Int {
  list.length(string.split(haystack, needle)) - 1
}

pub fn a_block_without_a_label_is_drawn_as_it_always_was_test() {
  let model = page([lane_fixture.reasoned(0, 1, running())])
  list.each(drawn(model), fn(html) {
    assert string.contains(html, raw)
    assert string.contains(
      html,
      preview("Thought 2: weigh the locking order against the retry path."),
    )
    assert !string.contains(html, summarized)
  })
}

pub fn a_block_that_settles_keeps_the_label_it_streamed_with_test() {
  let streaming = labelled_stream()
  list.each(drawn(streaming), fn(html) {
    assert string.contains(
      html,
      "<p class=\"thinking-headline\">Found a lock-order mismatch</p>",
    )
  })

  // The response commits before its own label has arrived. The settled row is
  // the terminal's: the verb says it is summarized, the heading still counts
  // the block's lines, and the label is the preview.
  let settled =
    component.apply(streaming, [lane_fixture.reasoned(0, 1, running())])
  list.each(drawn(settled), fn(html) {
    assert string.contains(html, summarized)
    assert string.contains(html, "· 2 lines")
    assert string.contains(html, preview("Found a lock-order mismatch"))
    assert !string.contains(html, raw)
    assert !string.contains(
      html,
      preview("Thought 2: weigh the locking order against the retry path."),
    )

    // The block's own text is still behind the chevron.
    assert string.contains(html, "Then compare it with what the second reader")
  })
}

pub fn the_stored_label_replaces_the_carried_one_test() {
  let settled =
    component.apply(labelled_stream(), [
      lane_fixture.reasoned(0, 1, running()),
    ])
  let stored = component.apply(settled, [stored(2, "The stored summary")])
  list.each(drawn(stored), fn(html) {
    assert string.contains(html, preview("The stored summary"))
    assert !string.contains(html, "Found a lock-order mismatch")
    assert count(html, summarized) == 1
  })
}

pub fn a_label_that_arrives_after_the_block_settled_shows_test() {
  let settled = page([lane_fixture.reasoned(0, 1, running())])
  let labelled = component.apply(settled, [stored(2, "Arrived late")])
  list.each(drawn(labelled), fn(html) {
    assert string.contains(html, summarized)
    assert string.contains(html, preview("Arrived late"))
  })
}

// A carried label belongs to the first long reasoning block of its response
// and to no other, so a later block does not borrow it.
pub fn a_carried_label_is_not_lent_to_another_response_test() {
  let settled =
    component.apply(labelled_stream(), [
      lane_fixture.reasoned(0, 2, running()),
    ])
  list.each(drawn(settled), fn(html) {
    assert count(html, summarized) == 1
    assert count(html, raw) == 1
  })
}

pub fn a_label_that_arrives_after_the_turn_was_sealed_shows_test() {
  let sealed = page([lane_fixture.reasoned(2, 1, None)])
  let folded = lane_fixture.opened(sealed)
  list.each(drawn(folded), fn(html) {
    assert count(html, raw) == 2
    assert !string.contains(html, summarized)
  })

  // The first turn's block is labelled after both turns closed and its fold's
  // steps were read. Nothing was sealed again: the row is drawn from the label.
  let labelled = component.apply(folded, [stored(2, "Sealed, then labelled")])
  list.each(drawn(labelled), fn(html) {
    assert string.contains(html, preview("Sealed, then labelled"))
    assert count(html, summarized) == 1
    assert count(html, raw) == 1
  })

  // A label that is there before the fold is opened shows when it opens.
  let early =
    page([lane_fixture.reasoned(2, 1, None), stored(6, "Before opening")])
    |> lane_fixture.opened
  list.each(drawn(early), fn(html) {
    assert string.contains(html, preview("Before opening"))
    assert count(html, summarized) == 1
  })
}

pub fn a_label_is_only_ever_drawn_as_text_test() {
  let model =
    page([
      lane_fixture.reasoned(0, 1, running()),
      stored(2, "<script>alert(1)</script> and <b>bold</b>"),
    ])
  list.each(drawn(model), fn(html) {
    assert string.contains(html, summarized)
    assert string.contains(html, "&lt;script&gt;alert(1)&lt;/script&gt;")
    assert !string.contains(html, "<script>")
    assert !string.contains(html, "<b>bold</b>")
  })
}

// --- the reads ---------------------------------------------------------------

fn summaries_in(frames: List(String)) -> List(String) {
  list.filter(frames, fn(frame) {
    string.contains(frame, "\"cmd\":\"block_summaries\"")
  })
}

// The entries a `block_summaries` frame names.
fn named(frame: String) -> List(String) {
  string.split(frame, "\"entry\":\"")
  |> list.drop(1)
  |> list.filter_map(fn(rest) {
    case string.split_once(rest, "\"") {
      Ok(#(entry, _)) -> Ok(entry)
      Error(Nil) -> Error(Nil)
    }
  })
}

// Ticks the page until it has sent a read of labels, refusing the other reads
// the lane sent first so its one command slot frees. The frames it sent.
fn asked(page, wire, rounds: Int) {
  let page = page_fixture.run(page, component.update, [component.Ticked])
  let frames = page_fixture.commands(page_fixture.sent(wire))
  case summaries_in(frames), rounds {
    [], 0 -> #(page, [])
    [], _ ->
      page_fixture.run(page, component.update, [
        component.Arrived(
          list.map(frames, fn(frame) {
            page_fixture.refusal(page_fixture.request_id(frame))
          }),
        ),
      ])
      |> asked(wire, rounds - 1)
    found, _ -> #(page, found)
  }
}

fn answered(page, read: String, found: List(#(String, Int, String))) {
  page_fixture.run(page, component.update, [
    component.Arrived([
      page_fixture.block_summaries(page_fixture.request_id(read), found),
    ]),
  ])
}

pub fn a_reloaded_page_reads_the_labels_it_lacks_and_draws_them_test() {
  let wire = process.new_subject()
  let model =
    page_fixture.ready(wire, "operator")
    |> component.apply([lane_fixture.reasoned(0, 1, running())])
  let #(model, reads) = asked(model, wire, 4)
  let assert [read] = reads as "one read of labels"
  assert named(read) == [lane_fixture.entry_text(2)]

  let model =
    answered(model, read, [#(lane_fixture.entry_text(2), 0, "Read from store")])
  list.each(drawn(model), fn(html) {
    assert string.contains(html, preview("Read from store"))
    assert string.contains(html, summarized)
  })

  // The block was asked about once. The answer does not bring it back.
  let #(_, again) = asked(model, wire, 2)
  assert again == []
}

pub fn a_read_names_at_most_max_blocks_and_no_block_twice_test() {
  let wire = process.new_subject()
  let model =
    page_fixture.ready(wire, "operator")
    |> component.apply([lane_fixture.reasoned(0, 40, running())])
  let #(model, first) = asked(model, wire, 4)
  let assert [one] = first as "the first read"
  assert list.length(named(one)) == block_summary.max_blocks

  // The daemon has labels for none of them; the rest are asked next, and
  // those the first read named are not named again.
  let model = answered(model, one, [])
  let #(model, second) = asked(model, wire, 4)
  let assert [two] = second as "the second read"
  assert list.length(named(two)) == 40 - block_summary.max_blocks
  assert list.all(named(two), fn(entry) { !list.contains(named(one), entry) })

  let model = answered(model, two, [])
  let #(_, third) = asked(model, wire, 2)
  assert third == []
  assert set.size(set.from_list(list.append(named(one), named(two)))) == 40
}

fn folds(model) -> List(Int) {
  list.filter_map(component.pieces(model), fn(piece) {
    case piece {
      turns.Work(id: Some(id), ..) -> Ok(id)
      turns.Work(..)
      | turns.Plain(..)
      | turns.Prompt(..)
      | turns.Spawned(..)
      | turns.Returned(..)
      | turns.Nudged(..)
      | turns.Peer(..)
      | turns.Sibling(..)
      | turns.Missed(..)
      | turns.Decided(..)
      | turns.Commentary(..) -> Error(Nil)
    }
  })
}

// A turn the page reads through a lineage read and the steps of its fold,
// neither of which is in the capture, has its blocks' labels read like any
// other, and drawn.
pub fn blocks_loaded_through_history_and_an_opened_fold_are_read_test() {
  let archive = lane_fixture.thinking([3, 570])
  let labels = [
    #(lane_fixture.entry_text(2), 0, "First step weighed"),
    #(lane_fixture.entry_text(4), 0, "Second step weighed"),
    #(lane_fixture.entry_text(6), 0, "Third step weighed"),
  ]
  let wire = process.new_subject()
  let capture = lane_fixture.newest(archive, 100)
  let serve = fn(model) {
    lane_fixture.served_labelled(
      model,
      wire,
      archive,
      capture,
      "operator",
      labels,
    )
  }
  let #(model, opening) =
    page_fixture.ready(wire, "operator")
    |> component.apply([capture])
    |> page_fixture.run(component.update, [component.Ticked])
    |> serve

  // The page holds the long turn; the short one is below it, read on request.
  let #(model, older) =
    page_fixture.run(model, component.update, [component.OlderRequested])
    |> serve
  let assert [short, _long] = folds(model)
  let #(model, opened) =
    page_fixture.run(model, component.update, [component.FoldToggled(short)])
    |> serve

  list.each(drawn(model), fn(html) {
    assert string.contains(html, preview("First step weighed"))
    assert string.contains(html, preview("Second step weighed"))
    assert string.contains(html, preview("Third step weighed"))
  })

  // Each of the three was asked about once, in reads of at most the bound.
  let reads = summaries_in(list.flatten([opening, older, opened]))
  assert list.all(reads, fn(read) {
    list.length(named(read)) <= block_summary.max_blocks
  })
  let asked = list.flat_map(reads, named)
  assert list.length(asked) == set.size(set.from_list(asked))
  assert list.contains(asked, lane_fixture.entry_text(2))
  assert list.contains(asked, lane_fixture.entry_text(4))
  assert list.contains(asked, lane_fixture.entry_text(6))
  assert reads != []
}
