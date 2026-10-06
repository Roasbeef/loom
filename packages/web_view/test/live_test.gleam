//// The live region: the response the provider is still writing, drawn at
//// the end of the lane on both pages until the daemon commits the answer.
////
//// The tests read the HTML the browser would receive, as `lane_view_test`
//// does. They cover the reasoning row (its count, its clock and the
//// headline that may sit beneath it), an answer growing across batches, the
//// hand-over to the committed row, and what a batch of fragments costs on
//// the wire: the size of Lustre's own patch, which must be the live region's
//// tail and nothing that depends on how many rows the page holds.

import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lane_fixture
import lustre/dev/query
import lustre/element.{type Element}
import lustre/element/html
import page_fixture
import session_view/block_summary
import session_view/protocol
import session_view/session_channel
import session_view/transcript_line.{type Line}
import web_view/component
import web_view/operator_page
import web_view/view/lane
import web_view/view/live

type Cache

@external(erlang, "lane_memo_ffi", "first")
fn first(view: Element(message)) -> Cache

@external(erlang, "lane_memo_ffi", "patched")
fn patched(
  cache: Cache,
  old: Element(message),
  new: Element(message),
) -> #(Int, Cache)

fn running() -> session_channel.Update {
  lane_fixture.asked(Some(lane_fixture.main_op()))
}

fn page(updates) {
  component.new(page_fixture.start()) |> component.apply(updates)
}

// A page whose transport reads a clock the test sets, and the clock.
fn timed(updates) {
  let clock = page_fixture.clock()
  #(
    component.new(page_fixture.start_with(clock)) |> component.apply(updates),
    clock,
  )
}

// The page after a tick that the transport's clock reads `now` at, which is
// the reading the shared record stamps what follows with.
fn at(model, clock: page_fixture.Clock, now: Int) {
  page_fixture.set(clock, now)
  component.update(model, component.Ticked).0
}

// Both pages draw the lane the same way, so each test says what it checks
// of each.
fn observer(model) -> Element(Nil) {
  component.view(model) |> element.map(fn(_) { Nil })
}

fn operator(model) -> Element(Nil) {
  operator_page.view(model) |> element.map(fn(_) { Nil })
}

fn pages(model) -> List(Element(Nil)) {
  [observer(model), operator(model)]
}

// The live region's HTML, or nothing when the page draws none.
fn region(view: Element(message)) -> String {
  case query.find(in: view, matching: query.element(query.class("live"))) {
    Ok(found) -> element.to_string(found)
    Error(Nil) -> ""
  }
}

fn count(haystack: String, needle: String) -> Int {
  list.length(string.split(haystack, needle)) - 1
}

// The fragments of a long answer: sentences of about fifty characters, with
// a blank line after every sixth so that the answer is many paragraphs.
fn sentences(count: Int) -> List(String) {
  int.range(from: 1, to: count + 1, with: [], run: fn(acc, n) {
    let sentence = "Sentence " <> int.to_string(n) <> " of the answer, said. "
    case n % 6 {
      0 -> [sentence <> "\n\n", ..acc]
      _ -> [sentence, ..acc]
    }
  })
  |> list.reverse
}

pub fn a_streaming_answer_grows_across_batches_on_both_pages_test() {
  let generation = lane_fixture.generation(2)
  let started =
    page([running(), lane_fixture.fragment(generation, "text", "Hello, ")])
  let grown =
    component.apply(started, [
      lane_fixture.fragment(generation, "text", "**wor"),
      lane_fixture.fragment(generation, "text", "ld**"),
    ])

  list.each(pages(started), fn(view) {
    let drawn = region(view)
    assert string.contains(drawn, "Hello,")
    assert !string.contains(drawn, "<strong>")

    // The committed prompt is drawn once, above the region, in the lane.
    assert string.contains(element.to_string(view), ">go<")
  })

  // The answer so far is what the region draws, as Markdown, with no
  // second copy: the lane holds the prompt and this one answer.
  list.each(pages(grown), fn(view) {
    let drawn = region(view)
    assert string.contains(drawn, "Hello, <strong>world</strong>")
    assert count(element.to_string(view), "world") == 1
  })
}

pub fn the_region_is_the_lanes_last_entry_and_absent_without_a_stream_test() {
  let generation = lane_fixture.generation(2)

  // Nothing streaming, nothing drawn, so an idle lane is what it was.
  list.each(pages(page([running()])), fn(view) {
    assert region(view) == ""
  })

  let streaming =
    page([running(), lane_fixture.fragment(generation, "text", "so far")])
  list.each(pages(streaming), fn(view) {
    let drawn = element.to_string(view)
    let assert Ok(#(before, after)) = string.split_once(drawn, "so far")
    assert string.contains(before, ">go<")

    // Not announced: the lane is a polite log and the region opts out.
    assert string.contains(before, "aria-live=\"off\"")
    assert !string.contains(after, ">go<")
  })
}

pub fn a_reasoning_row_counts_lines_and_the_browser_counts_its_time_test() {
  let generation = lane_fixture.generation(2)
  let #(model, clock) = timed([running()])
  let model = at(model, clock, 1000)
  let model =
    component.apply(model, [
      lane_fixture.fragment(generation, "thinking", "first thought\nsecond"),
    ])

  // The generation began at the reading the first fragment was stamped
  // with, and the row carries the seconds since as a reading the browser
  // counts on from, as an agent chip's time is. The row says `Reasoning`
  // and keeps the line count to its title. The thinking itself is not drawn.
  let model = at(model, clock, 5500)
  list.each(pages(model), fn(view) {
    let drawn = region(view)
    assert string.contains(drawn, "title=\"2 lines\"")
    assert string.contains(
      drawn,
      "Reasoning · <loom-elapsed class=\"elapsed\" offset=\"4500\"></loom-elapsed></p>",
    )
    assert !string.contains(drawn, "first thought")
    assert !string.contains(drawn, "thinking-headline")
    assert !string.contains(drawn, "so far")
  })

  // Another fragment moves the count, and the reading is fresh.
  let model =
    component.apply(model, [
      lane_fixture.fragment(generation, "thinking", "\nthird"),
    ])
  let model = at(model, clock, 9000)
  list.each(pages(model), fn(view) {
    let drawn = region(view)
    assert string.contains(drawn, "title=\"3 lines\"")
    assert string.contains(drawn, "offset=\"8000\"")
  })
}

pub fn a_headline_sits_beneath_the_reasoning_row_as_text_test() {
  let generation = lane_fixture.generation(2)
  let model =
    page([
      running(),
      lane_fixture.fragment(generation, "thinking", "a\nb"),
    ])
  list.each(pages(model), fn(view) {
    assert !string.contains(region(view), "thinking-headline")
  })

  // The summarizer's label for the stream so far (protocol 050). It is
  // text from a model, so markup in it stays text.
  let model =
    component.apply(model, [
      session_channel.Auxiliary(protocol.BlockSummarized(
        block_summary.LiveStream("main", lane_fixture.main_op(), generation),
        "Checking <b>the lock</b> order",
      )),
    ])
  list.each(pages(model), fn(view) {
    let drawn = region(view)
    assert string.contains(
      drawn,
      "<p class=\"thinking-headline\">Checking &lt;b&gt;the lock&lt;/b&gt; order</p>",
    )
    assert string.contains(drawn, "title=\"2 lines\"")
    assert !string.contains(drawn, "<b>")
  })
}

pub fn reasoning_and_the_answer_beside_it_are_both_drawn_in_order_test() {
  let generation = lane_fixture.generation(2)
  let model =
    page([
      running(),
      lane_fixture.fragment(generation, "thinking", "hm"),
      lane_fixture.fragment(generation, "text", "The answer"),
    ])
  list.each(pages(model), fn(view) {
    let drawn = region(view)
    let assert Ok(#(before, _)) = string.split_once(drawn, "The answer")
    assert string.contains(before, "Reasoning")
  })
}

// The entry event clears the record's streams before the capture that
// holds the answer arrives. The answer stays where it was until then, and
// the capture replaces it: never two copies, never none, and the committed
// row is where the live one was.
pub fn the_committed_row_replaces_the_live_one_without_a_gap_test() {
  let generation = lane_fixture.generation(2)
  let streaming =
    page([running(), lane_fixture.fragment(generation, "text", "Final answer")])
  list.each(pages(streaming), fn(view) {
    assert count(element.to_string(view), "Final answer") == 1
    assert region(view) != ""
  })

  // The entry lands and the record drops its streams, but no capture has
  // the row: the page still draws the answer, once.
  let pushed =
    component.apply(streaming, [lane_fixture.committed(2, "Final answer")])
  list.each(pages(pushed), fn(view) {
    assert count(element.to_string(view), "Final answer") == 1
    assert string.contains(region(view), "Final answer")
  })

  // A capture from before the commit (the operation still running, no
  // answer in it) changes nothing.
  let stale =
    component.apply(pushed, [lane_fixture.asked(Some(lane_fixture.main_op()))])
  list.each(pages(stale), fn(view) {
    assert count(element.to_string(view), "Final answer") == 1
    assert region(view) != ""
  })

  // The capture that holds the answer: one row, in the lane, and no region.
  let settled =
    component.apply(pushed, [lane_fixture.answered(["Final answer"])])
  list.each(pages(settled), fn(view) {
    assert count(element.to_string(view), "Final answer") == 1
    assert region(view) == ""
  })
}

// A capture can land before the entry's push. The record's streams still
// hold the answer then, and the capture already draws its row: one copy.
pub fn a_capture_before_the_push_does_not_draw_the_answer_twice_test() {
  let generation = lane_fixture.generation(2)
  let model =
    page([running(), lane_fixture.fragment(generation, "text", "Final answer")])
    |> component.apply([lane_fixture.answered(["Final answer"])])
  list.each(pages(model), fn(view) {
    assert count(element.to_string(view), "Final answer") == 1
    assert region(view) == ""
  })
}

// A page that attaches mid-answer is told the text so far as a preview. The
// first pushed fragment would replace it in the record and shrink the
// answer to that fragment, so the page keeps the preview until the pushed
// text is at least as long.
pub fn a_preview_is_kept_until_the_pushed_text_is_as_long_test() {
  let generation = lane_fixture.generation(2)
  let seeded =
    page([
      lane_fixture.previewed(running(), "Hello wor"),
    ])
  assert string.contains(region(observer(seeded)), "Hello wor")

  let short =
    component.apply(seeded, [lane_fixture.fragment(generation, "text", "ld")])
  list.each(pages(short), fn(view) {
    assert string.contains(region(view), "Hello wor")
  })

  let longer =
    component.apply(short, [
      lane_fixture.fragment(generation, "text", " and all the rest"),
    ])
  list.each(pages(longer), fn(view) {
    assert string.contains(region(view), "ld and all the rest")
    assert !string.contains(region(view), "Hello wor")
  })
}

// An answer that a capture already holds when its stream arrives late (a
// fragment the daemon replays after the record) is not drawn a second time.
pub fn a_stream_for_a_committed_answer_is_not_drawn_again_test() {
  let generation = lane_fixture.generation(2)
  let model =
    page([
      lane_fixture.answered(["Final answer"]),
      lane_fixture.committed(2, "Final answer"),
      lane_fixture.fragment(generation, "text", "Final answer"),
    ])
  list.each(pages(model), fn(view) {
    assert count(element.to_string(view), "Final answer") == 1
    assert region(view) == ""
  })
}

// An operation that ends with no answer leaves no live row behind: the
// capture that shows it over releases the region.
pub fn an_answer_that_never_commits_leaves_when_the_operation_ends_test() {
  let generation = lane_fixture.generation(2)
  let model =
    page([running(), lane_fixture.fragment(generation, "text", "half an ans")])
    |> component.apply([
      session_channel.Auxiliary(protocol.OperationChanged("main", "done")),
    ])

  // Cleared by the record, but the capture the page holds still says the
  // operation runs, so the answer stays until a capture says otherwise.
  assert string.contains(region(observer(model)), "half an ans")

  let model = component.apply(model, [lane_fixture.asked(None)])
  list.each(pages(model), fn(view) {
    assert region(view) == ""
    assert !string.contains(element.to_string(view), "half an ans")
  })
}

// A request that reserved no entry (an older daemon) has nothing to wait
// for: it leaves with the record's streams, as it did before this region.
pub fn a_stream_with_no_reserved_entry_leaves_with_the_record_test() {
  let model =
    page([
      running(),
      lane_fixture.fragment("legacy-request", "text", "old daemon"),
    ])
  assert string.contains(region(observer(model)), "old daemon")
  let cleared =
    component.apply(model, [lane_fixture.committed(2, "old daemon")])
  assert region(observer(cleared)) == ""
}

// What a batch of fragments costs on the wire. Lustre's patch for a render
// is the diff of the view against the last one, encoded as the runtime
// sends it, so its size is what the browser receives for a batch.
//
// The region is the lane's last entry and the committed rows above it are
// memoized by their pieces, so a fragment changes the tail of the answer and
// nothing else: the patch does not depend on how many rows the page holds
// and does not grow with the answer, only with the paragraph being written.
fn sizes(model, generation: String, fragments: List(String)) -> List(Int) {
  let view = observer(model)
  walk(model, first(view), view, generation, fragments, [])
}

fn walk(
  model,
  cache: Cache,
  view: Element(Nil),
  generation: String,
  fragments: List(String),
  acc: List(Int),
) -> List(Int) {
  case fragments {
    [] -> list.reverse(acc)
    [fragment, ..rest] -> {
      let next =
        component.apply(model, [
          lane_fixture.fragment(generation, "text", fragment),
        ])
      let updated = observer(next)
      let #(bytes, cache) = patched(cache, view, updated)
      walk(next, cache, updated, generation, rest, [bytes, ..acc])
    }
  }
}

pub fn a_batch_of_fragments_costs_the_tail_of_the_answer_test() {
  let generation = lane_fixture.generation(2)
  let fragments = sentences(120)
  let start = lane_fixture.fragment(generation, "text", "Sentence 0. ")

  // A page holding a hundred and fifty rows, and one holding a prompt.
  let full =
    page([lane_fixture.conversation(301, 450), start])
    |> sizes(generation, fragments)
  let bare = page([running(), start]) |> sizes(generation, fragments)

  // The rows the page holds change nothing about a batch's patch, beyond the
  // few bytes an index in the patch's path takes.
  assert list.length(full) == 120
  assert list.zip(full, bare)
    |> list.all(fn(pair) { int.absolute_value(pair.0 - pair.1) <= 8 })
}

// The bound, stated: each fragment adds a sentence of about fifty bytes to
// a paragraph of at most six, and Lustre replaces the text node of the
// paragraph being written, so a patch is that paragraph and a fixed
// envelope: under 300 bytes here, against a page of 150 rows. The answer's
// length does not enter: the largest patch of the last thirty fragments of
// a stream of a hundred and twenty sentences is no larger than the largest of
// the first thirty, to within the digits a longer sentence number adds.
pub fn a_patch_is_bounded_by_the_paragraph_being_written_test() {
  let generation = lane_fixture.generation(2)
  let start = lane_fixture.fragment(generation, "text", "Sentence 0. ")
  let patches =
    page([lane_fixture.conversation(301, 450), start])
    |> sizes(generation, sentences(120))
  let early = list.take(patches, 30)
  let late = list.drop(patches, 90)
  let assert Ok(largest_early) = list.reduce(early, int.max)
  let assert Ok(largest_late) = list.reduce(late, int.max)
  assert largest_late <= largest_early + 16
  assert largest_late < 512
}

// The committed rows are not drawn again for a fragment: the lane's memos
// hold, so a render draws the live answer's one line and no other.
pub fn a_fragment_draws_no_committed_line_again_test() {
  let drawn = process.new_subject()
  let draw = fn(line: Line) {
    process.send(drawn, Nil)
    html.text(line.text)
  }
  let generation = lane_fixture.generation(2)
  let model = page([lane_fixture.conversation(301, 450)])
  let grown = fn(text) {
    component.apply(model, [lane_fixture.fragment(generation, "text", text)])
  }
  let render = fn(model) {
    lane.rows(
      component.pieces(model),
      component.live(model),
      element.none(),
      draw,
      lane.NoReplies,
      lane.no_marks(),
      "",
    )
  }
  let one = render(grown("one"))
  let cache = first(one)
  assert received(drawn) == 151

  let two = render(grown("one two"))
  let #(_, cache) = patched(cache, one, two)
  assert received(drawn) == 1
  let #(_, _) = patched(cache, two, render(grown("one two three")))
  assert received(drawn) == 1
}

fn received(drawn: process.Subject(Nil)) -> Int {
  case process.receive(drawn, 0) {
    Ok(Nil) -> 1 + received(drawn)
    Error(Nil) -> 0
  }
}

pub fn the_live_rows_are_plain_values_test() {
  // The region takes plain values and draws them with the lane's own
  // drawing of an answer, so it can be tested apart from a page.
  let drawn =
    live.view([live.Thinking("2 lines", Some(1500), None)], fn(line: Line) {
      html.text(line.text)
    })
    |> element.to_string
  assert string.contains(
    drawn,
    "Reasoning · <loom-elapsed class=\"elapsed\" offset=\"1500\"></loom-elapsed>",
  )
  assert string.contains(drawn, "title=\"2 lines\"")
  let none =
    live.view([live.Thinking("1 line", None, None)], fn(line: Line) {
      html.text(line.text)
    })
    |> element.to_string
  assert string.contains(none, ">Reasoning</p>")
  assert !string.contains(none, "loom-elapsed")
}

// A turn that has opened and streamed nothing is not silent. The row stands
// from the strand's `assistant` phase, which is when the request goes out and
// the generation clock starts, and not from the first fragment, which a model
// that streams no reasoning text never sends before its answer.
pub fn an_opened_turn_shows_thinking_before_anything_streams_test() {
  let generation = lane_fixture.generation(2)
  let #(model, clock) = timed([running()])
  let model = at(model, clock, 1000)

  // A running operation whose strand is not in its `assistant` phase (the
  // fixture labels it with a phase the server never emits) draws no row, as
  // an idle lane does not.
  list.each(pages(model), fn(view) {
    assert region(view) == ""
  })

  let model =
    component.apply(model, [
      session_channel.Auxiliary(protocol.OperationChanged("main", "assistant")),
    ])
  let model = at(model, clock, 4000)

  // The browser counts the reading on, as it does for the reasoning row.
  list.each(pages(model), fn(view) {
    let drawn = region(view)
    assert string.contains(
      drawn,
      "Thinking · <loom-elapsed class=\"elapsed\" offset=\"3000\"></loom-elapsed></p>",
    )
    assert !string.contains(drawn, "Reasoning")
  })

  // Reasoning text arriving gives the row its old shape, and the opened row
  // is gone: one row, never both.
  let reasoning =
    component.apply(model, [
      lane_fixture.fragment(generation, "thinking", "first thought"),
    ])
  list.each(pages(reasoning), fn(view) {
    let drawn = region(view)
    assert string.contains(drawn, "Reasoning · <loom-elapsed")
    assert !string.contains(drawn, "Thinking")
  })

  // An answer streaming with no reasoning does the same.
  let answering =
    component.apply(model, [lane_fixture.fragment(generation, "text", "Hi")])
  list.each(pages(answering), fn(view) {
    let drawn = region(view)
    assert string.contains(drawn, "Hi")
    assert !string.contains(drawn, "Thinking")
    assert !string.contains(drawn, "Reasoning")
  })

  // The turn ending releases the region.
  let done =
    component.apply(model, [
      session_channel.Auxiliary(protocol.OperationChanged("main", "done")),
      lane_fixture.asked(None),
    ])
  list.each(pages(done), fn(view) {
    assert region(view) == ""
  })
}

// The opened row rides the lane's own dot, which pulses while a region
// exists, and carries no animation of its own that reduced motion would
// have to cancel.
pub fn the_opened_row_sits_beside_the_pulsing_dot_test() {
  let model =
    page([
      running(),
      session_channel.Auxiliary(protocol.OperationChanged("main", "assistant")),
    ])
  list.each(pages(model), fn(view) {
    let drawn = element.to_string(view)
    assert string.contains(drawn, "class=\"dot pulse\"")
    assert string.contains(region(view), "Thinking")
  })
}

// A page that holds only the capture's phase starts the generation clock the
// first time it sees `assistant`: the phase event that starts the terminal's
// clock is not delivered to a page, and a row with a phase and no clock said
// `Thinking` alone for the whole wait. The clock reads from that first sight,
// not from the operation's clock, which also counts earlier generations of
// the turn.
pub fn an_opened_turn_seen_in_a_capture_starts_the_generation_clock_test() {
  let #(model, clock) = timed([lane_fixture.phased(running(), "assistant")])
  let model = at(model, clock, 3000)
  list.each(pages(model), fn(view) {
    let drawn = region(view)
    assert string.contains(drawn, "Thinking · <loom-elapsed")
  })

  // The phase leaving `assistant` with nothing streaming ends the generation,
  // so the next one starts again from its own open and not from the first.
  let tool =
    component.apply(model, [
      session_channel.Auxiliary(protocol.OperationChanged("main", "tool")),
    ])
  list.each(pages(tool), fn(view) {
    assert region(view) == ""
  })
  let tool = at(tool, clock, 9000)
  let again =
    component.apply(tool, [
      session_channel.Auxiliary(protocol.OperationChanged("main", "assistant")),
    ])
  let again = at(again, clock, 10_000)
  list.each(pages(again), fn(view) {
    assert string.contains(
      region(view),
      "Thinking · <loom-elapsed class=\"elapsed\" offset=\"1000\">",
    )
  })
}

// A capture that takes the strand out of `assistant` ends the generation's
// clock, and one that brings it back with nothing streaming starts a new one
// from that sight. No phase event reaches the page, so `component.clocked` is
// the only thing that does this for a capture.
pub fn a_capture_that_leaves_and_returns_to_assistant_restarts_the_clock_test() {
  let #(model, clock) = timed([lane_fixture.phased(running(), "assistant")])
  let model = at(model, clock, 5000)
  list.each(pages(model), fn(view) {
    assert string.contains(region(view), "offset=\"5000\"")
  })

  let model = component.apply(model, [lane_fixture.asked(None)])
  list.each(pages(model), fn(view) {
    assert region(view) == ""
  })

  let model = at(model, clock, 9000)
  let model =
    component.apply(model, [lane_fixture.phased(running(), "assistant")])
  let model = at(model, clock, 10_000)
  list.each(pages(model), fn(view) {
    assert string.contains(region(view), "offset=\"1000\"")
  })
}

// The inputs the daemon holds for the strand are drawn after the streams,
// as the terminal draws them: the person's words, then how the daemon will
// run them, both as text nodes. A steer and a queued prompt have their own
// words, another strand's input is not drawn, and the row leaves with the
// first capture that no longer lists it.
pub fn held_inputs_are_drawn_after_the_streams_and_leave_when_run_test() {
  let generation = lane_fixture.generation(2)
  let holding =
    page([
      lane_fixture.holding(running(), [
        lane_fixture.steer("h1", "go <b>left</b>"),
        lane_fixture.queued("h2", "main", "then the tests"),
        lane_fixture.queued("h3", lane_fixture.child, "not on screen"),
      ]),
      lane_fixture.fragment(generation, "text", "so far"),
    ])
  list.each(pages(holding), fn(view) {
    let drawn = region(view)
    let assert Ok(#(before, after)) =
      string.split_once(drawn, "go &lt;b&gt;left&lt;/b&gt;")
      as "the steer's words are drawn as text"
    assert string.contains(before, "so far")
    assert !string.contains(drawn, "<b>")
    assert string.contains(after, "steer · runs next")
    let assert Ok(#(_, queued)) = string.split_once(after, "then the tests")
      as "the queued prompt follows the steer"
    assert string.contains(queued, "queued · after this turn")
    assert !string.contains(drawn, "not on screen")
  })

  // The daemon ran the steer: the next capture no longer lists it, and its
  // row goes with it while the queued prompt stays.
  let ran =
    component.apply(holding, [
      lane_fixture.holding(running(), [
        lane_fixture.queued("h2", "main", "then the tests"),
      ]),
    ])
  list.each(pages(ran), fn(view) {
    let drawn = region(view)
    assert !string.contains(drawn, "go &lt;b&gt;left&lt;/b&gt;")
    assert string.contains(drawn, "then the tests")
  })

  // The queued prompt ran too: the next capture lists nothing, and the
  // region holds the stream alone.
  let settled = component.apply(ran, [lane_fixture.holding(running(), [])])
  list.each(pages(settled), fn(view) {
    let drawn = region(view)
    assert string.contains(drawn, "so far")
    assert !string.contains(drawn, "then the tests")
    assert !string.contains(drawn, "class=\"held\"")
  })
}

// A held input alone is a region: a queued prompt on a strand whose answer
// has not started streaming is still on the page.
pub fn a_held_input_is_drawn_without_a_stream_test() {
  let model =
    page([
      lane_fixture.holding(lane_fixture.captured(10, None), [
        lane_fixture.queued("h2", "main", "then the tests"),
      ]),
    ])
  list.each(pages(model), fn(view) {
    let drawn = region(view)
    assert string.contains(drawn, "<div class=\"held\">")
    assert string.contains(drawn, "then the tests")
    assert string.contains(drawn, "queued · after this turn")
  })
}
