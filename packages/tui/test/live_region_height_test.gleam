//// A successful settle changes a line's text, never the transcript's height.
////
//// Two regions of the transcript used to be drawn once while they were
//// live and again, at a different size, once the daemon had committed
//// them. A running tool showed its output window — a heading and up to
//// eight lines — on top of the durable row that already said the call was
//// awaiting a result, and gave all of it back within a few hundred
//// milliseconds of the result arriving. A reasoning block streamed through
//// the Markdown renderer at full width and stayed there. Both made the
//// transcript grow and shrink under a reader who was only following the
//// tail, seventeen times in one recorded run.
////
//// The property pinned here is the one a reader actually perceives: the
//// number of wrapped rows the transcript occupies does not change when a
//// live region becomes a durable one. It is asserted on `rendered_rows`,
//// the same projection the viewport takes its visible slice from, rather
//// than on either of the functions that build the rows, because the
//// behaviour is about the frame and has to survive a change to how the
//// rows are assembled.
////
//// The rule is about growth that carries no information, so it is scoped to
//// a result the reader does not have to see. A failing call still costs the
//// rows its failure draws, and the test below pins that number rather than
//// claiming zero.

import core/json
import etui/backend
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import tui
import tui/connection
import tui/workspace
import tui_test/gateway

// Ninety columns leaves every fixture row inside the pane, so a row count
// here is a count of transcript entries and not of wrapping decisions. The
// narrow width below is where the digest's own clipping is exercised.
const width = 90

// Narrow enough that a real opening line cannot fit beside the mark and the
// expand hint, which together cost thirty-four cells.
const narrow_width = 40

fn model() -> tui.Model {
  let base =
    tui.new_model(connection.new_inbox(), workspace.Context("/work", None))
  tui.Model(..base, transcript: [], records: [], notice: "fixture")
}

fn received(model: tui.Model, wire: String) -> tui.Model {
  tui.accept_connection_message(model, connection.Incoming(wire))
}

// Laying the rows out is what fills `rendered_rows`; a model that has only
// consumed wire frames has not been asked for a frame yet.
fn laid_out(model: tui.Model) -> tui.Model {
  tui.update(backend.Resize(width, 40), model)
}

fn rows(model: tui.Model) -> Int {
  laid_out(model).rendered_row_count
}

fn rows_at(model: tui.Model, columns: Int) -> Int {
  tui.update(backend.Resize(columns, 40), model).rendered_row_count
}

fn expanded(model: tui.Model) -> tui.Model {
  tui.Model(..model, details_expanded: True, rendered_revision: -1)
}

// One frame of a running command's output window. The v1 envelope is what
// `protocol.decode_event` accepts, and the fields are the ones the daemon
// sends: the frame carries the whole window rather than a fragment of it.
fn tool_output(text: String, total_bytes: Int) -> String {
  json.to_string(
    json.Object([
      #("v", json.Int(1)),
      #("event", json.String("tool_output")),
      #(
        "body",
        json.Object([
          #("strand", json.String("main")),
          #("op", json.String("op-1")),
          #("step", json.String("step-1")),
          #("source_index", json.Int(0)),
          #("call_id", json.String("call-1")),
          #("stream", json.String("stdout")),
          #("tail", json.String(text)),
          #("total_bytes", json.Int(total_bytes)),
        ]),
      ),
    ]),
  )
}

fn nine_lines() -> String {
  list.repeat("compiling package", 9)
  |> list.index_map(fn(text, index) { text <> " " <> int.to_string(index + 1) })
  |> string.join("\n")
}

// A strand with one committed tool call whose command is still running and
// has printed nine lines: more than the window shows, so an expanded view
// has to clip and a collapsed one has something real to leave out.
fn running() -> tui.Model {
  model()
  |> received(gateway.full_snapshot("demo"))
  |> received(gateway.user_entry("main", "build it", 1))
  |> received(gateway.tool_call_entry("main", "bash", "make check", 2))
  |> received(tool_output(nine_lines() <> "\n", 2048))
}

fn settled(model: tui.Model) -> tui.Model {
  received(model, gateway.tool_result_ok_entry("main", "build finished", 3))
}

pub fn a_running_tools_output_costs_no_rows_until_details_open_test() {
  let live = running()
  assert tui.tool_tail_lines(live) == []
    as "a collapsed transcript draws none of the running command's window"

  let assert [tui.Line(tui.ToolResult, window)] =
    tui.tool_tail_lines(expanded(live))
    as "an expanded transcript still draws the window it collected"
  let assert ["stdout · 2 KiB so far", first, ..rest] =
    string.split(window, "\n")
  assert first == "compiling package 2"
    as "the window keeps its last lines, not its first"
  assert list.length(rest) == tui.tail_lines_shown - 1
}

pub fn settling_a_tool_call_leaves_the_transcript_the_same_height_test() {
  let live = running()

  // The premise, because a check on two equal row counts passes just as
  // well on a fixture with nothing in it: this model really is a running
  // call with a window of output behind it, so a transcript which drew the
  // window would have `tail_lines_shown` rows and a heading to give back.
  assert list.length(live.tool_tails) == 1
    as "premise: the running call has collected a window of output"

  assert rows(live) == rows(settled(live))
    as "a collapsed transcript changed height when a running tool settled"
  assert laid_out(live).rendered_rows != laid_out(settled(live)).rendered_rows
    as "the settle must still replace the awaiting row with its result"
}

// Reasoning is the other live region, and it settles the same way: the
// stream the provider is writing is replaced by the record the daemon
// commits, a few hundred milliseconds later.
fn thinking() -> tui.Model {
  model()
  |> received(gateway.full_snapshot("demo"))
  |> received(gateway.user_entry("main", "explain it", 1))
  |> received(gateway.stream_delta(
    "main",
    "thinking",
    "First I will read the file.\n\nThen I will ## check it.\n\n```\nfence\n```\n",
  ))
}

fn thinking_settled(model: tui.Model) -> tui.Model {
  received(
    model,
    gateway.thinking_entry(
      "main",
      "First I will read the file.\n\nThen I will ## check it.\n\n```\nfence\n```\n",
      2,
    ),
  )
}

pub fn settling_a_reasoning_block_leaves_the_transcript_the_same_height_test() {
  let live = thinking()
  let durable = thinking_settled(live)
  assert rows(live) == rows(durable)
    as "a collapsed transcript changed height when reasoning settled"
  assert laid_out(live).rendered_rows != laid_out(durable).rendered_rows
    as "the settle must still replace the line counter with the opening words"
}

pub fn collapsed_reasoning_is_one_row_and_expanded_reasoning_is_the_block_test() {
  let quiet =
    model()
    |> received(gateway.full_snapshot("demo"))
    |> received(gateway.user_entry("main", "explain it", 1))
  let live = thinking()
  assert rows(live) == rows(quiet) + 1
    as "a live reasoning block collapses to exactly one row"
  assert rows(thinking_settled(live)) == rows(quiet) + 1
    as "a settled reasoning block collapses to exactly one row"

  // The block carries a heading and a fence, both of which the Markdown
  // renderer answers with rows of their own, so a digest which forwarded
  // its text to that renderer would not be one row and the expanded form
  // is several.
  assert rows(expanded(live)) > rows(live) + 4
    as "expanding reasoning shows the whole block, fences and all"
}

pub fn a_live_digest_counts_lines_and_a_settled_one_quotes_its_opening_test() {
  assert tui.live_reasoning_digest("one thought") == "1 line so far"
  assert tui.live_reasoning_digest("one\ntwo\nthree") == "3 lines so far"
  assert tui.settled_reasoning_digest("\n\nFirst.\nSecond.")
    == "First." <> tui.expand_hint
    as "the opening line is the first one with text in it"
}

// The transcript before either live region has anything in it, which is what
// a row count is measured against.
fn quiet() -> tui.Model {
  model()
  |> received(gateway.full_snapshot("demo"))
  |> received(gateway.user_entry("main", "explain it", 1))
}

// Reasoning routinely opens with a whole sentence, and the mark and the
// expand hint cost thirty-four cells before any of it is drawn. A limit on
// the digest text alone therefore only moves the width at which the row
// wraps; what holds the height is that the row is clipped to the pane and
// the wrapper is told to leave it alone.
fn long_reasoning() -> String {
  string.repeat("deliberating at length ", 9) <> "\nand then a second line"
}

pub fn a_long_opening_line_still_settles_into_one_row_test() {
  let base = quiet()
  let live =
    received(base, gateway.stream_delta("main", "thinking", long_reasoning()))
  let durable =
    received(live, gateway.thinking_entry("main", long_reasoning(), 2))

  assert string.length(long_reasoning()) > 200
    as "premise: the opening line is far wider than the pane"
  assert rows_at(live, narrow_width) == rows_at(base, narrow_width) + 1
    as "a live digest is one row on a pane it cannot fit"
  assert rows_at(durable, narrow_width) == rows_at(base, narrow_width) + 1
    as "a settled digest is one row on a pane it cannot fit"
}

// A redacted block is the third digest shape: the provider withheld the
// text, so there is nothing for `Ctrl+G` to reveal and the row is the same
// one row in both modes.
pub fn redacted_reasoning_is_one_row_in_both_modes_test() {
  let base = quiet()
  let durable = received(base, gateway.redacted_thinking_entry("main", 2))
  assert rows(durable) == rows(base) + 1
    as "a redacted block collapses to one row"
  assert rows(expanded(durable)) == rows(expanded(base)) + 1
    as "expanding a redacted block cannot reveal what was withheld"
}

// The height rule is about growth that carries no information, not about
// suppressing a result. A failing call settles into its failure summary plus
// the result text under it, and that is exactly what it costs; pinning the
// number keeps the claim honest as the failure row's shape changes.
pub fn a_failing_tool_settles_by_exactly_its_failure_rows_test() {
  let live = running()
  let failed =
    received(live, gateway.tool_result_entry("main", "exit status 1", 3))
  assert rows(settled(live)) == rows(live)
    as "premise: a successful settle is still height-neutral"
  assert rows(failed) == rows(live) + 1
    as "a failing settle costs exactly the rows its failure draws"
}

// The digest bypasses the Markdown renderer, so a line that only opens a
// construct would reach the reader as punctuation standing in for a whole
// block of reasoning. Both shapes are common openers in model output.
pub fn a_settled_digest_skips_a_fence_and_sheds_its_markers_test() {
  assert tui.settled_reasoning_digest("```gleam\nlet value = 1\n```")
    == "let value = 1" <> tui.expand_hint
    as "a fence delimiter is not an opening line"
  assert tui.settled_reasoning_digest("## Plan\n\nthen the work")
    == "Plan" <> tui.expand_hint
    as "a heading's marker is shed, not quoted"
  assert tui.settled_reasoning_digest("> quoted\n")
    == "quoted" <> tui.expand_hint
    as "a quotation marker is shed too"
  assert tui.settled_reasoning_digest("###\nthe real opening")
    == "the real opening" <> tui.expand_hint
    as "a line of markers alone falls through to the next candidate"
}
