//// Builds the transcript's `Line`s from durable entries, live streams and
//// tool traffic.
////
//// A `Line` is a speaker and a text, before Markdown and wrapping. This
//// module decides which lines a record, a stream or a tool call becomes and
//// in what order, and nothing else: it neither reads the socket nor paints
//// a buffer. What it reads of the client's state arrives as one
//// `Presentation`, so it never imports the terminal's model. The projection
//// (`tui/projection`) caches its output per record, the renderer
//// (`tui/render`) turns the lines into styled rows, and `tui/inbound`
//// uses the stream helpers as fragments arrive.
////
//// The dispatch points are `entry_lines` for one durable entry,
//// `message_lines` and `assistant_block_lines` for a message and its
//// blocks, `record_lines` for the active strand's whole history,
//// `activity_call_lines`, `tool_call_summary` and `tool_result_lines` for
//// tool calls, and `stream_lines` for live output. A new kind of transcript
//// row starts as a new arm in one of those. The advisor traffic section
//// recognizes the frames the server wraps advisor messages in and gives
//// them their own compact rows.
////
//// ## Flow
////
//// `record_lines` → `record_blocks` → `entry_lines` → `message_lines` → `assistant_block_lines` → `tool_call_summary`
////
//// 1. `record_lines` (or `keyed_record_lines` for a host that matches rows by
////    identity) takes the active strand's records and calls `record_blocks`,
////    then `separated_tool_groups` puts a blank between adjacent tool groups.
//// 2. `record_blocks` selects the strand's entries with `strand_entries`, splices
////    cache notices in at their sequence (`splice_notices`) and builds one block
////    per entry, group or notice, tagged by durable sequence.
//// 3. Expanded history draws each entry in full through `expanded_lines`;
////    compact history goes through `compact_item_lines`, which reuses a cached
////    call's rows (`cached_activity_lines`) or draws them with `activity_call_lines`.
//// 4. `entry_lines` dispatches on the entry: a compaction, a branch summary and
////    a custom entry are one row, and a message goes to `message_lines` unless
////    `harness_message_lines` or `peer_message_lines` claims it first.
//// 5. `message_lines` draws a user message, an assistant response through
////    `assistant_block_lines`, or a tool result through `tool_result_lines`.
//// 6. `assistant_block_lines` turns a reasoning block, text or a tool call into
////    rows; a call becomes `code_mode_program`, `patch_program` or the one-line
////    `tool_call_summary`.
//// 7. Live output takes a separate path: `stream_lines` draws the open streams
////    (`live_reasoning_line` for thinking) until the entry that settles them
////    lands and `clear_streams` drops them. Advisor frames reach
////    `labelled_advisor_lines` through `harness_message_lines`.

import core/entry
import core/ids
import core/json
import core/message
import core/origin
import gleam/bool
import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import session_view/advisor_history
import session_view/agent_roster
import session_view/block_summary
import session_view/call_tree.{type CallLog}
import session_view/composer
import session_view/file_read_view
import session_view/image_header
import session_view/notes_view
import session_view/protocol
import session_view/snapshot
import session_view/snapshot_view
import session_view/strand_framing
import session_view/stream_identity
import session_view/text_hygiene
import session_view/todo_board
import session_view/tool_activity
import session_view/transcript_line.{
  type CacheNotice, type Line, type Speaker, type Stream, type Submission,
  type ToolTail, Assistant, Failure, HeldPrompt, ImageRow, Interjection, Line,
  PeerMessage, ProgramFailure, ProgramRunning, Reasoning, ReasoningDigest,
  SentMessage, Spacer, StrandMessage, Stream, SummarizedAdvice,
  SummarizedReasoning, System, ToolCall, ToolDetail, ToolFailure, ToolGroup,
  ToolPatch, ToolResult, User,
}
import session_view/worktree_view

/// What the line builders read of the client's current state.
///
/// The builders are functions of this record and of the records they are
/// handed, never of a host's whole model. A host fills it from whatever it
/// keeps: the terminal from its `Model` (`tui_model.presentation`), and a
/// host with no composer or caches from a capture and an empty cache.
pub type Presentation {
  Presentation(
    /// The strand whose transcript is drawn.
    active_strand: String,
    /// Whether details are collapsed (`Excerpt`) or expanded (`Complete`).
    extent: notes_view.Extent,
    /// The last completed cut and the view decoded from it.
    captured: Option(#(snapshot.Captured, snapshot_view.View)),
    /// The captured branch's durable records, newest first.
    records: List(protocol.EntryRecord),
    /// Pushed provider fragments not yet covered by a durable entry.
    streams: List(Stream),
    /// The rolling tails of tool calls still running.
    tool_tails: List(ToolTail),
    /// This client's held prompts and interjections, oldest first.
    queued: List(Submission),
    /// The submission whose reply has not arrived, if any.
    awaiting_outcome: Option(Submission),
    /// Prompt-cache notices already rendered as transcript rows.
    cache_notices: List(CacheNotice),
    /// Summarizer labels for long blocks (protocol 050).
    summaries: block_summary.Labels,
    /// Rows already built for a narrative entry, keyed by what they show.
    compact_entry_cache: Dict(
      #(entry.Entry, Option(message.Origin), List(#(Int, String))),
      List(Line),
    ),
    /// Rows already built for a tool call, keyed by the call and outcome.
    compact_call_cache: Dict(tool_activity.Call, List(Line)),
    /// The captured worktree diff board and its explanation.
    worktree: worktree_view.State,
    /// The local clock's offset from UTC in minutes, which a message's
    /// heading needs to show its time (`model.Shared.clock_offset`).
    clock: Option(Int),
  )
}

// A stream stays separate from durable entries because the server may replay
// the settled entry after its fragments. Keeping both in one list would render
// the same assistant answer twice at the exact moment it becomes durable.
/// The most text one live stream keeps on screen, in bytes.
///
/// The same 24 KiB the snapshot's sampled preview is clipped to, because the
/// two are representations of the same thing and a live answer that could
/// outgrow its own sample would be the only unbounded region in the model.
/// The cost of exceeding it is not only the bytes: every paint reflows the
/// whole live region, so an unbounded one makes the terminal slower the
/// longer the answer runs, until it can no longer drain its socket.
@internal
pub const live_stream_limit = 24_576

// Compact patches show enough surrounding edits to review ordinary changes
// while retaining a fixed bound; Ctrl+G exposes the complete stored patch.
const patch_preview_lines = 60

// Submitted code stays readable in compact mode; expansion retains every line.
const code_preview_lines = 6

/// How many lines of a running command's tail the transcript shows. The
/// daemon's window is a few kilobytes; a terminal wants the last screenful
/// of lines from it, not the whole window pushing the composer away.
pub const tail_lines_shown = 8

/// Maximum distinct stream tails retained across every strand and call.
/// Exact durable reconciliation normally removes a tail first; this bound
/// covers a client which misses enough captures to evict the matching result.
pub const max_tool_tails = 128

/// What the transcript draws for the active strand's running tool calls,
/// which with details collapsed is nothing at all.
///
/// A tool call that succeeds settles without changing the transcript's
/// height. The durable projection already gives a running call one row — its
/// summary followed by `· awaiting result` — and a plain successful result
/// replaces that row one for one. Drawing the command's output window beside
/// it would add a heading and up to `tail_lines_shown` more rows and take
/// them away again two hundred milliseconds later, which is what made the
/// transcript jump by eight rows on every tool call of a turn and back. The
/// window is detail, so `Ctrl+g` is where it belongs, alongside the expanded
/// result the settle will draw in its place.
///
/// A result which carries something a reader has to see still costs the rows
/// it needs: a failure draws its summary and the result text under it, and
/// `fs_edit` and `context_remaining` draw their own rows. Suppressing those
/// would be trading the reader's information for a smooth scroll, which is
/// the wrong way round. What this removes is the growth that carried no
/// information — the window that appeared and vanished within a few hundred
/// milliseconds.
///
/// Expanded, the window is one `ToolResult` line per stream, headed by the
/// stream's name and how much it has carried, followed by the last
/// `tail_lines_shown` lines of it. A tail whose text is empty — a binary
/// stream, or a command that has printed nothing to that stream yet —
/// draws its heading alone, so the reader still sees that the command is
/// alive and how much it has written.
///
/// ## Examples
///
/// ```gleam
/// // transcript_lines.tool_tail_lines(Presentation(..shown, extent: Complete))
/// //   == [Line(ToolResult, "stdout · 31 B so far\ncompiling core")]
/// ```
@internal
pub fn tool_tail_lines(presentation: Presentation) -> List(Line) {
  case presentation.extent {
    notes_view.Excerpt -> []
    notes_view.Complete -> expanded_tool_tail_lines(presentation)
  }
}

// The window itself, once the reader has asked for detail.
fn expanded_tool_tail_lines(presentation: Presentation) -> List(Line) {
  presentation.tool_tails
  |> list.filter(fn(tail) { tail.strand == presentation.active_strand })
  |> list.map(fn(tail) {
    let heading =
      tail.stream <> " · " <> byte_count(tail.total_bytes) <> " so far"
    let shown =
      tail.text
      |> string.trim_end
      |> string.split("\n")
      |> list.filter(fn(line) { line != "" })
      |> last_lines(tail_lines_shown)
    Line(ToolResult, string.join([heading, ..shown], "\n"))
  })
}

// The last `count` of `lines`, in order.
fn last_lines(lines: List(String), count: Int) -> List(String) {
  let extra = list.length(lines) - count
  case extra > 0 {
    True -> list.drop(lines, extra)
    False -> lines
  }
}

// A byte count a reader can take in at a glance: bytes up to a kilobyte,
// whole kibibytes past it. The number tells the reader the window is a
// tail of something larger, which is all the precision it needs.
fn byte_count(bytes: Int) -> String {
  case bytes < 1024 {
    True -> int.to_string(bytes) <> " B"
    False -> int.to_string(bytes / 1024) <> " KiB"
  }
}

/// Drops every live stream that belongs to `strand`.
@internal
pub fn clear_streams(streams: List(Stream), strand: String) -> List(Stream) {
  list.filter(streams, fn(stream) {
    let Stream(strand: owner, ..) = stream
    owner != strand
  })
}

// The submission still awaiting its outcome is drawn with the ones the daemon
// has already acknowledged, and last, because it is the newest. Waiting for
// the reply before drawing it would cost the echo a round trip, which is most
// of what it is for.
//
// The echoes are the newest thing on screen: they were typed after the run
// that is streaming above them started, and they run after it finishes. One
// trailer under the group says what they are waiting for, rather than a
// marker repeated beside every line of it.
fn queued_lines(
  queued: List(Submission),
  awaiting: Option(Submission),
) -> List(Line) {
  let held =
    list.filter_map(
      list.append(queued, option.values([awaiting])),
      fn(submission) {
        case submission {
          HeldPrompt(text:) -> Ok(Line(User, text))

          // An interjection is on this list to consume an entry, not to be
          // read: the run it steered is already drawing its answer above.
          Interjection -> Error(Nil)
        }
      },
    )
  case held {
    [] -> []
    [_, ..] ->
      list.append(held, [
        Line(System, "queued · runs when this turn finishes"),
      ])
  }
}

/// The inputs the daemon holds for the strand on screen, in the capture's
/// own order: a steer waiting for the running generation's next boundary,
/// or a prompt queued behind the turn. `None` when the capture predates the
/// host queue (an older recording), which a host then stands in for with its
/// own submissions (`pending_input_lines`).
///
/// ## Examples
///
/// ```gleam
/// // transcript_lines.held_inputs(presentation) == Some([])
/// ```
pub fn held_inputs(
  presentation: Presentation,
) -> Option(List(snapshot_view.PendingInput)) {
  case presentation.captured {
    Some(#(_, view)) ->
      option.map(view.pending_inputs, fn(rows) {
        list.filter(rows, fn(row) { row.strand == presentation.active_strand })
      })
    None -> None
  }
}

/// The words beneath a held input, by how the daemon will run it. The
/// terminal and the page draw the same ones.
///
/// ## Examples
///
/// ```gleam
/// assert transcript_lines.held_words(snapshot_view.Steer) == "steer · runs next"
/// ```
pub fn held_words(kind: snapshot_view.InputKind) -> String {
  case kind {
    snapshot_view.Steer -> "steer · runs next"
    snapshot_view.Queue -> "queued · after this turn"
  }
}

/// Modern cuts carry the complete host queue, including other peers' input.
/// Replacing that list also removes drained rows after reconnect or a skipped
/// idle interval, without matching repeated text against transcript entries.
@internal
pub fn pending_input_lines(presentation: Presentation) -> List(Line) {
  case held_inputs(presentation) {
    None -> queued_lines(presentation.queued, presentation.awaiting_outcome)
    Some(visible) -> {
      let queued =
        list.flat_map(visible, fn(row) {
          [Line(User, row.text), Line(System, held_words(row.kind))]
        })
      list.append(queued, queued_lines([], presentation.awaiting_outcome))
    }
  }
}

/// Captured previews are standalone observations, never stored as delta
/// history. Once pushed observations arrive they take precedence, including
/// their empty terminal marker: unequal request identities do not prove that
/// a captured preview is newer than the request whose end was just observed.
@internal
pub fn display_streams(presentation: Presentation) -> List(Stream) {
  let active =
    list.filter(presentation.streams, fn(stream) {
      stream.strand == presentation.active_strand
      && !response_recorded(presentation.records, stream.generation)
    })
  let preview = case presentation.captured {
    Some(#(_, view)) ->
      case view.preview, dict.get(view.operations, presentation.active_strand) {
        Some(sample), Ok(op) if op == sample.operation ->
          case response_recorded(presentation.records, sample.generation) {
            True -> None
            False -> Some(sample)
          }
        Some(_), Ok(_) | Some(_), Error(Nil) | None, _ -> None
      }
    None -> None
  }
  case active, preview {
    [], Some(sample) -> [preview_stream(presentation.active_strand, sample)]
    _, _ -> active
  }
}

/// The record and the live answer change ownership in one render projection.
/// Text equality cannot establish that transfer: two answers may be identical.
@internal
pub fn response_recorded(
  records: List(protocol.EntryRecord),
  generation: String,
) -> Bool {
  case stream_identity.response_entry(generation) {
    None -> False
    Some(id) -> list.any(records, fn(record) { record.entry.id == id })
  }
}

/// Whether a live response is still owed to the transcript a host draws:
/// its request reserved a durable entry that `records` do not hold yet, and
/// `operations` still shows the operation that made it running on its strand.
///
/// A pushed entry clears the strand's streams the moment it lands, but a host
/// that draws only captures has no row for it until the next capture arrives.
/// Such a host keeps drawing the stream it last saw while this is true, so
/// the answer does not leave the page and come back, and stops once the
/// capture holds the entry (the exact hand-over, as `display_streams` makes
/// it against the terminal's records) or the capture says the operation is
/// over with no entry (an interrupted answer, which no record will replace).
/// A stream whose identity names no entry is never owed: older daemons and
/// summary requests keep the behaviour they had.
///
/// ## Examples
///
/// ```gleam
/// // transcript_lines.response_awaited(branch.records, view.operations, stream)
/// ```
@internal
pub fn response_awaited(
  records: List(protocol.EntryRecord),
  operations: Dict(String, String),
  stream: Stream,
) -> Bool {
  case stream_identity.response_entry(stream.generation) {
    None -> False
    Some(_) ->
      !response_recorded(records, stream.generation)
      && dict.get(operations, stream.strand) == Ok(stream.operation)
  }
}

/// A live stream seeded from the snapshot's sampled preview of an
/// unfinished answer.
@internal
pub fn preview_stream(strand: String, sample: snapshot_view.Preview) -> Stream {
  Stream(
    strand,
    sample.operation,
    sample.generation,
    sample.kind,
    [sample.text],
    string.byte_size(sample.text),
  )
}

/// Transcript lines for the active strand's live streams, oldest first.
///
/// A reasoning stream's collapsed row also carries how long the generation
/// has run, `elapsed_s`, and the newest summarizer label for its request
/// when `labels` holds one (protocol 050).
@internal
pub fn stream_lines(
  streams: List(Stream),
  active_strand: String,
  extent: notes_view.Extent,
  labels: block_summary.Labels,
  elapsed_s: Int,
) -> List(Line) {
  streams
  |> list.filter_map(fn(stream) {
    let Stream(strand:, kind:, fragments:, generation:, ..) = stream
    case strand == active_strand && kind != "end" {
      False -> Error(Nil)
      True -> {
        let text = fragments |> list.reverse |> string.concat
        let label = block_summary.live(labels, generation)
        Ok(case kind {
          "thinking" -> live_reasoning_line(text, extent, label, elapsed_s)
          "tool_call" -> Line(ToolCall, live_tool_call_summary(text))
          _ -> Line(Assistant, text)
        })
      }
    }
  })
  |> list.map(fn(line) { [line] })
  |> separated_tool_groups(WithinResponse)
}

// The live and settled forms of one reasoning block are drawn by different
// code paths a few hundred milliseconds apart — this one from the stream
// the provider is still writing, the other from the record the daemon has
// committed — so the two functions below are deliberately the same shape.
// Collapsed without a summary, each is exactly one `ReasoningDigest` row —
// clipped to the pane rather than wrapped, so the count holds at every width
// — and the settle therefore changes the row's words and not the
// transcript's height. With a summary each is one `SummarizedReasoning`
// line: a header row and the summary beneath it. The settled block borrows
// the stream's summary until its own arrives (`labels_for`), so a block that
// showed a summary while streaming settles into the same number of rows.
fn live_reasoning_line(
  text: String,
  extent: notes_view.Extent,
  label: Option(String),
  elapsed_s: Int,
) -> Line {
  case extent, label {
    notes_view.Complete, _ -> Line(Reasoning, text)
    notes_view.Excerpt, None ->
      Line(ReasoningDigest, live_summary_digest(text, elapsed_s))
    notes_view.Excerpt, Some(label) ->
      summarized_reasoning_line(live_summary_header(text, elapsed_s), label)
  }
}

fn settled_reasoning_line(
  text: String,
  extent: notes_view.Extent,
  label: Option(String),
) -> Line {
  case extent, label {
    notes_view.Complete, _ -> Line(Reasoning, text)
    notes_view.Excerpt, None ->
      Line(ReasoningDigest, settled_reasoning_digest(text))
    notes_view.Excerpt, Some(label) ->
      summarized_reasoning_line(expand_hint, label)
  }
}

/// The collapsed stand-in for a reasoning block still streaming and not
/// yet summarized: how much of it has arrived and how long the generation
/// has run. With no clock reading it is exactly `live_reasoning_digest`'s.
///
/// The count and the clock are what change while the block streams, and a
/// counter that climbs is easier to ignore than an excerpt rewritten under
/// the reader.
///
/// ## Examples
///
/// ```gleam
/// assert tui.live_summary_digest("one\ntwo", 64) == "2 lines · 1m 04s so far"
/// ```
///
/// ```gleam
/// assert tui.live_summary_digest("one", 0) == "1 line so far"
/// ```
@internal
pub fn live_summary_digest(text: String, elapsed_s: Int) -> String {
  let lines = line_count(text)
  case elapsed_s > 0 {
    True -> lines <> " · " <> elapsed_words(elapsed_s) <> " so far"
    False -> lines <> " so far"
  }
}

/// The header of a summarized reasoning block still streaming: its line
/// count and how long the generation has run, after the
/// `∴ Reasoning (summarized)` mark the renderer draws.
///
/// ## Examples
///
/// ```gleam
/// assert tui.live_summary_header("one\ntwo", 13) == " · 2 lines · 13s"
/// ```
@internal
pub fn live_summary_header(text: String, elapsed_s: Int) -> String {
  let lines = " · " <> line_count(text)
  case elapsed_s > 0 {
    True -> lines <> " · " <> elapsed_words(elapsed_s)
    False -> lines
  }
}

/// One collapsed reasoning block that has a summary: `header` for its
/// first row, after the renderer's `∴ Reasoning (summarized)` mark, and
/// the summary as the dim secondary lines beneath it (at most
/// `summary_rows` of them).
///
/// The header names the text as summarized, so the summary itself carries
/// no prefix and is never read as the agent's own words.
///
/// ## Examples
///
/// ```gleam
/// assert tui.summarized_reasoning_line("  [Ctrl+G to expand]", "Found it.")
///   == Line(SummarizedReasoning, "  [Ctrl+G to expand]\nFound it.")
/// ```
@internal
pub fn summarized_reasoning_line(header: String, label: String) -> Line {
  Line(SummarizedReasoning, header <> "\n" <> label)
}

/// The most rows a summary's secondary lines take beneath their header.
/// A longer summary is cut with an ellipsis at the end of the last row.
pub const summary_rows = 3

/// How many lines a reasoning block holds so far, in words: `1 line`,
/// `2 lines`. A live reasoning row says this and how long the generation has
/// run, and a host that draws the clock itself takes the count from here.
///
/// ## Examples
///
/// ```gleam
/// assert transcript_lines.line_count("one\ntwo") == "2 lines"
/// ```
@internal
pub fn line_count(text: String) -> String {
  let count = text |> string.split("\n") |> list.length
  int.to_string(count)
  <> case count {
    1 -> " line"
    _ -> " lines"
  }
}

// Seconds as the row reads them: `45s`, `1m 04s`. The seconds are padded
// under a minute so the figure does not change width every ten seconds.
fn elapsed_words(seconds: Int) -> String {
  case seconds < 60 {
    True -> int.to_string(seconds) <> "s"
    False -> {
      let rest = seconds % 60
      let padded = case rest < 10 {
        True -> "0" <> int.to_string(rest)
        False -> int.to_string(rest)
      }
      int.to_string(seconds / 60) <> "m " <> padded <> "s"
    }
  }
}

/// The collapsed stand-in for a reasoning block the provider is still
/// writing: how much of it has arrived, and nothing of what it says.
///
/// An excerpt would be the obvious thing to show and is the wrong one. The
/// opening words of a block that is still growing are rewritten under the
/// reader as fragments land, and a line that changes is far harder to
/// ignore than a counter that climbs.
///
/// ## Examples
///
/// ```gleam
/// assert tui.live_reasoning_digest("one thought") == "1 line so far"
/// ```
///
/// ```gleam
/// assert tui.live_reasoning_digest("one\ntwo") == "2 lines so far"
/// ```
@internal
pub fn live_reasoning_digest(text: String) -> String {
  let count = text |> string.split("\n") |> list.length
  int.to_string(count)
  <> case count {
    1 -> " line so far"
    _ -> " lines so far"
  }
}

/// The collapsed stand-in for a reasoning block the daemon has committed.
///
/// The block no longer moves, so the reader can be given something to
/// decide on: its opening line, clipped, and the key that opens the rest.
/// The row bypasses the Markdown renderer, so a line that only opens a
/// construct — a fence, or a heading's or a quotation's marker — would reach
/// the reader as punctuation standing in for a whole block of reasoning. A
/// fence line is skipped and the markers are stripped, leaving the first
/// line that actually says something. A block of only blank lines and
/// markers has no such line, and falls back to its own text so the row is
/// never empty.
///
/// ## Examples
///
/// ```gleam
/// assert tui.settled_reasoning_digest("First.\n\nSecond.")
///   == "First.  [Ctrl+G to expand]"
/// ```
///
/// ```gleam
/// assert tui.settled_reasoning_digest("## Plan")
///   == "Plan  [Ctrl+G to expand]"
/// ```
@internal
pub fn settled_reasoning_digest(text: String) -> String {
  reasoning_opening(text) <> expand_hint
}

/// A settled reasoning block's opening line, cut to the digest's bound: the
/// digest without the terminal's key hint, for a host whose reader opens
/// the block some other way.
///
/// ## Examples
///
/// ```gleam
/// assert transcript_lines.reasoning_opening("# Plan\nstep one")
///   == "Plan"
/// ```
pub fn reasoning_opening(text: String) -> String {
  let opening =
    text
    |> string.split("\n")
    |> list.filter_map(digest_opening_line)
    |> list.first
    |> result.unwrap(text)
  compact(opening, reasoning_digest_limit)
}

// Whether one source line can open a digest, and what it reads as if it can.
// A blank line and a fence delimiter say nothing on their own; a heading or
// quotation marker says something only about the line that carries it, so it
// is shed and the remainder is judged again — a line of markers alone falls
// through to the next candidate.
fn digest_opening_line(line: String) -> Result(String, Nil) {
  let trimmed = string.trim(line)
  case trimmed {
    "" -> Error(Nil)
    "```" <> _ | "~~~" <> _ -> Error(Nil)
    "#" <> rest | ">" <> rest -> digest_opening_line(rest)
    body -> Ok(body)
  }
}

/// How much of a settled reasoning block's opening line a digest keeps.
///
/// A budget for the reader's attention, not for the layout: about a line of
/// prose is as much as a collapsed row should ask anyone to read. The row
/// holds its single row because it is clipped to the pane, so this limit
/// only decides how much of the opening line a wide terminal shows.
pub const reasoning_digest_limit = 64

/// How the transcript names the key that opens a collapsed row, in the
/// wording `composer` already uses for a bounded user turn.
pub const expand_hint = "  [Ctrl+G to expand]"

/// Bounds a partial tool call to its name until durable arguments arrive.
@internal
pub fn live_tool_call_summary(name: String) -> String {
  text_hygiene.single_line(name) <> " · preparing arguments…"
}

/// One place in a strand's transcript, once the transient rows are in it.
///
/// A transcript is durable projection with the occasional local notice
/// spliced between its items. Naming that shape lets both projections — the
/// drawn rows and the scroll anchors — walk the same sequence, so a notice
/// cannot shift one of them without shifting the other.
@internal
pub type Spliced(a) {
  /// One item of the durable projection: an entry, or a projected group.
  Projected(a)

  /// A transient system-voice row that follows the item before it.
  Transient(text: String, after_seq: Int)
}

/// Places each notice after the projected item that holds the entry it was
/// anchored to.
///
/// Anchoring by entry rather than by position is what keeps a notice from
/// landing inside a tool group: the compact projection joins a call to a
/// result that arrives several entries later, and cutting between them would
/// leave the call pending forever and the result orphaned. The item that
/// holds the anchor is followed by the row, whole. A notice whose anchor has
/// since left the retained window is held by nothing and is dropped, which is
/// the right end for a row that was never durable.
@internal
pub fn splice_notices(
  items: List(a),
  notices: List(CacheNotice),
  holds: fn(a, CacheNotice) -> Bool,
  sequence: fn(a) -> Int,
) -> List(Spliced(a)) {
  list.flat_map(items, fn(item) {
    let rows =
      notices
      |> list.filter(holds(item, _))
      |> list.map(fn(notice) { Transient(notice.text, sequence(item)) })
    [Projected(item), ..rows]
  })
}

/// Whether an expanded-history entry is the one a notice was anchored to.
@internal
pub fn entry_holds(value: entry.Entry, notice: CacheNotice) -> Bool {
  value.id == notice.after_entry
}

/// Whether a compact projection item covers the entry a notice was anchored
/// to. A tool group covers every call's own entry and every result entry it
/// has joined, so a notice raised in the middle of a group follows the whole
/// group.
@internal
pub fn item_holds(item: tool_activity.Item, notice: CacheNotice) -> Bool {
  case item {
    tool_activity.Narrative(value) -> value.id == notice.after_entry
    tool_activity.Tools(calls) ->
      list.any(calls, fn(call) {
        call.source == notice.after_entry
        || call.result_source == Some(notice.after_entry)
      })
  }
}

/// The entries of one strand, oldest first.
@internal
pub fn strand_entries(
  records: List(protocol.EntryRecord),
  strand: String,
) -> List(entry.Entry) {
  records
  |> list.reverse
  |> list.filter(fn(record) { record.strand == strand })
  |> list.map(fn(record) { record.entry })
}

/// The notices raised on the active strand, oldest first.
@internal
pub fn active_notices(presentation: Presentation) -> List(CacheNotice) {
  list.filter(presentation.cache_notices, fn(notice) {
    notice.strand == presentation.active_strand
  })
}

/// Transcript lines for the durable records of the active strand, with
/// cache notices spliced in, plus the per-call and per-entry row caches the
/// projection reuses on the next rebuild.
@internal
pub fn record_lines(
  records: List(protocol.EntryRecord),
  presentation: Presentation,
  notices: List(CacheNotice),
  advisor: advisor_history.Board,
) -> #(
  List(Line),
  Dict(tool_activity.Call, List(Line)),
  Dict(#(entry.Entry, Option(message.Origin), List(#(Int, String))), List(Line)),
) {
  let #(blocks, calls, narratives) =
    record_blocks(records, presentation, notices, advisor)
  #(
    blocks
      |> list.map(fn(block) { block.1.1 })
      |> separated_tool_groups(BetweenEntries),
    calls,
    narratives,
  )
}

/// The rows of the durable records of the active strand, each keyed by the
/// durable sequence it was drawn from, for a host whose view matches rows
/// by identity rather than by position.
///
/// The rows are exactly `record_lines`' rows, in the same order: the blocks
/// are the same, and the spacers between tool groups come from the same
/// fold. A row's key is the sequence of the entry or group that drew it,
/// which of the blocks at that sequence it belongs to (a notice spliced
/// after an entry shares its sequence), and its index within the block. A
/// spacer takes the key of the block above it. The history window drops
/// rows at its head as it moves, and a key built this way names the same
/// row across captures, so a host can drop the vanished rows instead of
/// rewriting every row after them. Keys hold digits, `.`, `:` and `~`
/// only.
///
/// ## Examples
///
/// ```gleam
/// // transcript_lines.keyed_record_lines(records, presentation, [], advisor)
/// //   == [#("7.0:0", Line(User, "hello")), ..]
/// ```
@internal
pub fn keyed_record_lines(
  records: List(protocol.EntryRecord),
  presentation: Presentation,
  notices: List(CacheNotice),
  advisor: advisor_history.Board,
) -> List(#(String, Line)) {
  keyed_record_blocks(records, presentation, notices, advisor)
  |> list.flat_map(fn(block) { block.rows })
}

/// What drew one block of the transcript: the durable entry, the tool
/// group, the local notice or the advisor board it came from, or the blank
/// the fold placed between two groups.
///
/// A host that draws the transcript as rows needs none of this. A host that
/// draws some blocks as something other than rows (a folded turn, a card
/// for a message from another session) reads the source to decide, and the
/// rows it keeps are still exactly the rows `record_lines` draws.
pub type Source {
  /// One narrative entry: a message, a compaction or a branch summary.
  FromEntry(value: entry.Entry)

  /// One compact group of tool calls and their joined results.
  FromTools(calls: List(tool_activity.Call))

  /// A transient notice this client spliced after an entry.
  FromNotice

  /// The advisor's commentary board, merged by sequence.
  FromAdvisor

  /// A blank the tool-group fold placed between two blocks.
  FromSpacer
}

/// One block of the transcript, with the rows it draws and the key each row
/// carries in `keyed_record_lines`.
pub type Block {
  Block(
    /// The block's own key, `seq.occurrence`, or the key of the block
    /// above it followed by `~` for a spacer. It holds digits, `.` and `~`
    /// only.
    key: String,
    /// What drew the block.
    source: Source,
    /// The block's rows, each keyed `key:index`.
    rows: List(#(String, Line)),
  )
}

/// The durable sequence a block was drawn at: the digits its key starts
/// with (`Block.key`, `seq.occurrence`, or a spacer's key followed by `~`).
///
/// A host that holds only the newest blocks of a lane reads it from the
/// oldest block it keeps, to drop the records older than that from its
/// history window (`history_view.retain_from`).
///
/// ## Examples
///
/// ```gleam
/// assert transcript_lines.block_seq(transcript_lines.Block("7.0", transcript_lines.FromSpacer, []))
///   == Ok(7)
/// ```
pub fn block_seq(block: Block) -> Result(Int, Nil) {
  use #(seq, _) <- result.try(string.split_once(block.key, "."))
  int.parse(seq)
}

/// The same rows as `keyed_record_lines`, grouped by the block that drew
/// them and tagged with its source.
///
/// ## Examples
///
/// ```gleam
/// // transcript_lines.keyed_record_blocks(records, presentation, [], advisor)
/// //   == [Block("7.0", FromEntry(..), [#("7.0:0", Line(User, "hello"))]), ..]
/// ```
pub fn keyed_record_blocks(
  records: List(protocol.EntryRecord),
  presentation: Presentation,
  notices: List(CacheNotice),
  advisor: advisor_history.Board,
) -> List(Block) {
  let #(blocks, _, _) = record_blocks(records, presentation, notices, advisor)

  // Each block's key is its sequence and its occurrence at that sequence,
  // and the source is looked up by that key after the spacer fold, which
  // works on keyed row lists and knows nothing of sources.
  let #(keyed, _, sources) =
    list.fold(blocks, #([], dict.new(), dict.new()), fn(acc, block) {
      let #(keyed, seen, sources) = acc
      let #(seq, #(source, lines)) = block
      let occurrence = dict.get(seen, seq) |> result.unwrap(0)
      let key = int.to_string(seq) <> "." <> int.to_string(occurrence)
      #(
        [#(key, lines), ..keyed],
        dict.insert(seen, seq, occurrence + 1),
        dict.insert(sources, key, source),
      )
    })
  keyed
  |> list.reverse
  |> separated_tool_blocks(BetweenEntries)
  |> list.fold(#([], ""), fn(acc, block) {
    let #(placed, above) = acc
    let #(key, source) = case block.0 {
      "" -> #(above <> "~", FromSpacer)
      key -> #(key, dict.get(sources, key) |> result.unwrap(FromSpacer))
    }
    let rows =
      list.index_map(block.1, fn(line, index) {
        #(key <> ":" <> int.to_string(index), line)
      })
    #([Block(key:, source:, rows:), ..placed], key)
  })
  |> fn(folded) { list.reverse(folded.0) }
}

// The durable records of the active strand as blocks, each the rows one
// entry, tool group, spliced notice or advisor block draws, tagged with its
// durable sequence and in sequence order. `record_lines` flattens them and
// `keyed_record_lines` keys them.
fn record_blocks(
  records: List(protocol.EntryRecord),
  presentation: Presentation,
  notices: List(CacheNotice),
  advisor: advisor_history.Board,
) -> #(
  List(#(Int, #(Source, List(Line)))),
  Dict(tool_activity.Call, List(Line)),
  Dict(#(entry.Entry, Option(message.Origin), List(#(Int, String))), List(Line)),
) {
  let entries = strand_entries(records, presentation.active_strand)
  let sequences = entry_sequences(entries)
  let owner = solo_owner(presentation.captured)
  case presentation.extent {
    // Expanded history alternates a response carrying a call with the entry
    // carrying its result, and both close bare, so without this fold a run
    // of calls arrives as one undivided block. The entry boundary is the
    // only place that gap can be seen: the fold inside `message_lines` sees
    // one response at a time.
    notes_view.Complete -> #(
      entries
        |> splice_notices(notices, entry_holds, fn(value) { value.seq })
        |> list.map(fn(item) {
          #(
            spliced_sequence(item, fn(value) { value.seq }),
            #(
              expanded_source(item),
              expanded_lines(
                item,
                owner,
                presentation.summaries,
                presentation.clock,
              ),
            ),
          )
        })
        |> merge_sequence_blocks(sourced_advisor_blocks(advisor)),
      dict.new(),
      dict.new(),
    )

    // Compact history places the same gap between items that expanded
    // history places between entries: a reasoning row carries no blank of
    // its own, so one opening a narrative under a group's bare last row
    // would otherwise sit welded to it.
    notes_view.Excerpt -> {
      let found = joined(entries)
      let #(reversed, calls, narratives) =
        entries
        |> tool_activity.project_split(advisor_splits(advisor))
        |> splice_notices(notices, item_holds, item_sequence(_, sequences))
        |> list.fold(#([], dict.new(), dict.new()), fn(acc, spliced) {
          case spliced {
            Transient(text, seq) -> #(
              [#(seq, #(FromNotice, [Line(System, text)])), ..acc.0],
              acc.1,
              acc.2,
            )
            Projected(item) ->
              compact_item_lines(
                acc,
                item,
                item_sequence(item, sequences),
                presentation,
                owner,
                found,
              )
          }
        })

      // A provider error that repeats on every retry is one row with a
      // count, not a wall of identical rows.
      #(
        reversed
          |> list.reverse
          |> collapse_repeats(
            fn(block) { block.1.1 },
            fn(block) { repeated_failure(block.1.1) },
            fn(block, rows) { #(block.0, #(block.1.0, rows)) },
          )
          |> merge_sequence_blocks(sourced_advisor_blocks(advisor)),
        calls,
        narratives,
      )
    }
  }
}

// The advisor's board, tagged as its own source.
fn sourced_advisor_blocks(
  advisor: advisor_history.Board,
) -> List(#(Int, #(Source, List(Line)))) {
  advisor_history_blocks(advisor)
  |> list.map(fn(block) { #(block.0, #(FromAdvisor, block.1)) })
}

fn expanded_source(spliced: Spliced(entry.Entry)) -> Source {
  case spliced {
    Transient(..) -> FromNotice
    Projected(value) -> FromEntry(value)
  }
}

// Expanded history renders every entry in full, so a spliced place is
// either the entry itself or the transient row standing after it.
fn expanded_lines(
  spliced: Spliced(entry.Entry),
  owner: Option(message.Origin),
  labels: block_summary.Labels,
  clock: Option(Int),
) -> List(Line) {
  case spliced {
    Transient(text, _) -> [Line(System, text)]
    Projected(value) -> clocked_entry_lines(value, True, owner, labels, clock)
  }
}

// One projected item folded into the compact accumulator: each item's rows,
// newest item first, the call cache and the narrative cache. Lifted out of
// the fold so the caches it reads are parameters rather than a closure over
// the model, which is what lets the notice fold share the same accumulator
// shape.
fn compact_item_lines(
  acc: #(
    List(#(Int, #(Source, List(Line)))),
    Dict(tool_activity.Call, List(Line)),
    Dict(
      #(entry.Entry, Option(message.Origin), List(#(Int, String))),
      List(Line),
    ),
  ),
  item: tool_activity.Item,
  seq: Int,
  presentation: Presentation,
  owner: Option(message.Origin),
  found: Joined,
) -> #(
  List(#(Int, #(Source, List(Line)))),
  Dict(tool_activity.Call, List(Line)),
  Dict(#(entry.Entry, Option(message.Origin), List(#(Int, String))), List(Line)),
) {
  case item {
    // The labels the entry's rows would show are part of the key, so a
    // label arriving is a new key and the entry is projected again, while
    // every other cached narrative is reused.
    // A send's result that its call's row already draws is no rows at
    // all, and a response holding a send is drawn afresh rather than from
    // the cache, since its row changes when the result arrives later.
    tool_activity.Narrative(value) ->
      case absorbed(found, value), reads_joined(value) {
        True, _ -> #([#(seq, #(FromEntry(value), [])), ..acc.0], acc.1, acc.2)
        False, True -> #(
          [
            #(
              seq,
              #(
                FromEntry(value),
                joined_entry_lines(
                  value,
                  owner,
                  presentation.summaries,
                  found,
                  presentation.clock,
                ),
              ),
            ),
            ..acc.0
          ],
          acc.1,
          acc.2,
        )
        False, False -> {
          let key = #(value, owner, labels_for(value, presentation.summaries))
          let lines =
            dict.get(presentation.compact_entry_cache, key)
            |> result.lazy_unwrap(fn() {
              clocked_entry_lines(
                value,
                False,
                owner,
                presentation.summaries,
                presentation.clock,
              )
            })
          #(
            [#(seq, #(FromEntry(value), lines)), ..acc.0],
            acc.1,
            dict.insert(acc.2, key, lines),
          )
        }
      }
    tool_activity.Tools(calls) -> {
      let #(lines, cached) =
        cached_activity_lines(
          calls,
          presentation.compact_call_cache,
          presentation.clock,
        )
      #(
        [#(seq, #(FromTools(calls), lines)), ..acc.0],
        dict.merge(acc.1, cached),
        acc.2,
      )
    }
  }
}

// Outcome identity is part of the key, so receiving a result replaces its
// pending row. The new map contains only visible calls and releases old cuts.
fn cached_activity_lines(
  calls: List(tool_activity.Call),
  previous: Dict(tool_activity.Call, List(Line)),
  clock: Option(Int),
) -> #(List(Line), Dict(tool_activity.Call, List(Line))) {
  let #(reversed, cached) =
    list.fold(calls, #([], dict.new()), fn(acc, call) {
      let lines =
        dict.get(previous, call)
        |> result.lazy_unwrap(fn() { clocked_call_lines(call, clock) })
      #([lines, ..acc.0], dict.insert(acc.1, call, lines))
    })

  // The separation is applied to the groups and not stored in the cache:
  // whether a call needs a blank above it is a fact about its neighbours,
  // and the cached rows belong to the call alone. The heading closes itself
  // with a blank, so the first group is already separated from it.
  #(
    [
      activity_heading(calls),
      ..reversed
      |> list.reverse
      |> collapse_repeats(fn(rows) { rows }, repeated_call, fn(_, rows) { rows })
      |> separated_tool_groups(WithinResponse)
    ],
    cached,
  )
}

/// Folds each run of identical, consecutive repeatable items into the last
/// of them, with the run's length on its first row: fifteen identical
/// `✓ agent_wait · 2 subagents` rows become one `… ×15` row.
///
/// The last item is the one kept because it is the newest, so a host that
/// pairs rows with durable identities lands on the latest of the run. The
/// rows compared are the rows drawn, so two calls whose summaries differ in
/// any word are never folded together. Only compact history folds: the
/// expanded view still shows every original entry.
///
/// ## Examples
///
/// ```gleam
/// let row = [Line(ToolCall, "✓ agent_wait · 2 subagents")]
/// assert transcript_lines.collapse_repeats(
///     [row, row],
///     fn(rows) { rows },
///     transcript_lines.repeated_call,
///     fn(_, rows) { rows },
///   )
///   == [[Line(ToolCall, "✓ agent_wait · 2 subagents ×2")]]
/// ```
@internal
pub fn collapse_repeats(
  items: List(a),
  rows: fn(a) -> List(Line),
  repeatable: fn(a) -> Bool,
  rebuild: fn(a, List(Line)) -> a,
) -> List(a) {
  items
  |> list.fold([], fn(runs, item) {
    case runs {
      [#(previous, count), ..rest] ->
        case
          repeatable(item)
          && repeatable(previous)
          && rows(previous) == rows(item)
        {
          True -> [#(item, count + 1), ..rest]
          False -> [#(item, 1), ..runs]
        }
      [] -> [#(item, 1)]
    }
  })
  |> list.reverse
  |> list.map(fn(run) {
    case run.1 {
      1 -> run.0
      count -> rebuild(run.0, counted(rows(run.0), count))
    }
  })
}

// The run's length, on the first row so it reads beside the summary.
fn counted(rows: List(Line), count: Int) -> List(Line) {
  case rows {
    [first, ..rest] -> [
      Line(..first, text: first.text <> " ×" <> int.to_string(count)),
      ..rest
    ]
    [] -> []
  }
}

/// Whether a tool call's rows may fold into a run of identical calls: a
/// call that settled successfully and draws one row, as a poll such as
/// `agent_wait` does. A pending call, a failure with its preview and a call
/// with a patch or output under it keep their own rows, because a reader may
/// be looking for that one call's detail and its place in the scrollback.
///
/// ## Examples
///
/// ```gleam
/// assert transcript_lines.repeated_call([Line(ToolCall, "✓ agent_wait")])
/// ```
@internal
pub fn repeated_call(rows: List(Line)) -> Bool {
  case rows {
    [Line(speaker: ToolCall, text: "✓ " <> _)] -> True
    [] | [_, ..] -> False
  }
}

/// Whether a narrative item's rows may fold into a run: only an entry that
/// draws nothing but one failure row, such as a provider error repeated on
/// every retry. Two identical prompts or answers are two things the reader
/// has to see.
///
/// ## Examples
///
/// ```gleam
/// assert transcript_lines.repeated_failure([Line(Failure, "http 429")])
/// assert !transcript_lines.repeated_failure([Line(User, "again")])
/// ```
@internal
pub fn repeated_failure(rows: List(Line)) -> Bool {
  case rows {
    [Line(speaker: Failure, ..)] -> True
    [] | [_, ..] -> False
  }
}

/// Which first row counts as opening a tool group, which depends on the
/// boundary the fold is walking.
///
/// A `ToolFailure` row is the same speaker in two different roles. Inside one
/// assistant response it is a failed call's own summary and therefore opens a
/// group. Between durable entries it is the first row of the failed *result*
/// entry answering the call in the entry above, so treating it as an opening
/// would put a blank between a call and its own outcome.
@internal
pub type GroupOpening {
  WithinResponse

  BetweenEntries
}

/// A tool call owns the rows under it — its patch, its result, a note excerpt
/// — which is why `render_line` closes none of the tool family with a blank of
/// its own: a blank there would split a call from its own detail. Nothing then
/// separates one call from the next, so this is where that row is placed.
///
/// The test is two-sided, because most of the transcript does close itself. A
/// paragraph, a note body, a rendered program and an error all end in a blank
/// already, so a spacer above the call that follows one of them would draw the
/// same gap twice. A blank goes in only where the block above ended bare and
/// the block below opens a group.
///
/// This is also the fold `record_anchors_for` runs, block by block, to pair
/// every rendered row with the durable call it came from: a spacer added to
/// the rows has to appear there too, or each anchor below a group drifts up by
/// one row per gap. The blank belongs to no call, so it is its own idless
/// block and resolves to no anchor at all.
@internal
pub fn separated_tool_blocks(
  blocks: List(#(String, List(Line))),
  opening: GroupOpening,
) -> List(#(String, List(Line))) {
  blocks
  |> list.fold([], fn(placed, block) {
    // `placed` is newest first, and a spacer is only ever pushed
    // immediately beneath the block it precedes, so the rows consulted here
    // are never ones this fold wrote. A block that draws nothing, such as a
    // result its call's row already draws (`joined`), is passed over: the
    // block below comes to sit under the last block that drew a row.
    let drew = fn(earlier: #(String, List(Line))) { earlier.1 != [] }
    let wanted = case list.find(placed, drew) {
      Ok(#(_, previous)) ->
        block_closes_bare(previous) && opens_bare(block.1, opening)
      Error(Nil) -> False
    }

    case wanted {
      True -> [block, #("", [Line(Spacer, "")]), ..placed]
      False -> [block, ..placed]
    }
  })
  |> list.reverse
}

/// `separated_tool_blocks` over lines that are not grouped into blocks,
/// each line its own block: the transcript's own lines (the head, notices
/// and approvals), which no fold over entries has seen. A line that closes
/// bare and one that opens bare get the one blank row between them that the
/// fold gives any two blocks.
///
/// ## Examples
///
/// ```gleam
/// // transcript_lines.separated_lines(model.shared.transcript)
/// ```
@internal
pub fn separated_lines(lines: List(Line)) -> List(Line) {
  separated_tool_groups(list.map(lines, fn(line) { [line] }), BetweenEntries)
}

// The same separation over rows that carry no anchor identity.
//
// Groups are wrapped as idless blocks and run through the one fold rather
// than folded again here. Two copies of a two-sided rule drift, and the two
// projections have to agree row for row or the anchors slide.
fn separated_tool_groups(
  groups: List(List(Line)),
  opening: GroupOpening,
) -> List(Line) {
  groups
  |> list.map(fn(group) { #("", group) })
  |> separated_tool_blocks(opening)
  |> list.flat_map(fn(block) { block.1 })
}

// Whether a block ends without a blank row of its own.
//
// Only the last row decides it, because that is the row the next block comes
// to sit under. The fold never asks it of an empty block.
fn block_closes_bare(rows: List(Line)) -> Bool {
  case list.last(rows) {
    Ok(line) -> closes_bare(line.speaker)
    Error(Nil) -> False
  }
}

/// The speakers `render_line` draws with no trailing blank row of their own.
///
/// `render_line` asks this same question when it decides whether to append a
/// blank, which is why it is a function rather than a second copy of the list:
/// moving a speaker into or out of the tool family changes both the row drawn
/// and the gap the fold above owes it, and the two have to move together.
/// Everything else ends in a blank, and a `Spacer` is a blank.
@internal
pub fn closes_bare(speaker: Speaker) -> Bool {
  case speaker {
    ToolCall
    | ToolResult
    | ToolFailure
    | ToolPatch
    | ReasoningDigest
    | SummarizedReasoning
    | ProgramRunning
    | ProgramFailure
    | ImageRow(..) -> True
    System
    | ToolGroup
    | User
    | Assistant
    | Reasoning
    | ToolDetail
    | Failure
    | Spacer
    | SummarizedAdvice
    | SentMessage
    | StrandMessage
    | PeerMessage -> False
  }
}

/// A block opens bare when its first row brings no blank above itself: a
/// call's own summary, whether that call is pending, succeeded or failed, or
/// a collapsed reasoning row. The digest is drawn without a blank so that its
/// live and settled forms keep one height, which leaves the gap above it to
/// this rule, exactly as for a call.
@internal
pub fn opens_bare(rows: List(Line), opening: GroupOpening) -> Bool {
  case rows {
    [Line(speaker: ToolCall, ..), ..] -> True
    [Line(speaker: ProgramRunning, ..), ..] -> True
    [Line(speaker: ProgramFailure, ..), ..] -> True
    [Line(speaker: ReasoningDigest, ..), ..] -> True

    // A turn, an answer and a message between agents end in a blank row
    // and bring none above themselves, so whatever comes before one of them
    // is one blank row away: the blank it closed with, or a spacer under a
    // call that closed bare.
    [Line(speaker: User, ..), ..] -> True
    [Line(speaker: Assistant, ..), ..] -> True
    [Line(speaker: Reasoning, ..), ..] -> True
    [Line(speaker: SentMessage, ..), ..] -> True
    [Line(speaker: StrandMessage, ..), ..] -> True
    [Line(speaker: PeerMessage, ..), ..] -> True
    [Line(speaker: SummarizedReasoning, ..), ..] -> True

    // A harness row, such as advisor commentary, a notice or a tool group's
    // own heading, draws its blank below itself like every other speaker, so
    // under a call's bare last row it would sit welded to that call without a
    // gap of its own.
    [Line(speaker: System, ..), ..] -> True
    [Line(speaker: ToolGroup, ..), ..] -> True
    [Line(speaker: SummarizedAdvice, ..), ..] -> True

    // A provider error after a run of calls is its own entry, and like the
    // harness rows it would otherwise sit welded under the last call.
    [Line(speaker: Failure, ..), ..] -> True

    // The one row whose meaning depends on the boundary being walked; see
    // `GroupOpening`.
    [Line(speaker: ToolFailure, ..), ..] ->
      case opening {
        WithinResponse -> True
        BetweenEntries -> False
      }

    [] | [_, ..] -> False
  }
}

/// Compact mode folds arguments and results, never invocation history. Every
/// call keeps its chronological row so scrolling can recover earlier work.
@internal
pub fn activity_heading(calls: List(tool_activity.Call)) -> Line {
  let failed =
    list.count(calls, fn(call) {
      case call.outcome {
        Some(message.ToolResultMessage(is_error: True, ..)) -> True
        _ -> False
      }
    })
  let count = list.length(calls)
  let heading =
    "tools · "
    <> int.to_string(count)
    <> case count {
      1 -> " call"
      _ -> " calls"
    }
    <> case failed {
      0 -> ""
      n -> " · " <> int.to_string(n) <> " failed"
    }
    <> " · Ctrl+g expands details"
  Line(ToolGroup, heading)
}

/// The rows for one tool call: its summary, and its result or failure once
/// the outcome is known.
@internal
pub fn activity_call_lines(call: tool_activity.Call) -> List(Line) {
  clocked_call_lines(call, None)
}

/// `activity_call_lines` with the local clock's offset, so a send's row
/// shows when its recipient took it.
///
/// ## Examples
///
/// ```gleam
/// // transcript_lines.clocked_call_lines(call, Some(60))
/// ```
@internal
pub fn clocked_call_lines(
  call: tool_activity.Call,
  clock: Option(Int),
) -> List(Line) {
  call_rows(call.invocation, call.outcome, clock)
}

// The compact rows of one call and the result joined to it, if any: what a
// tool group draws for each of its calls, and what a narrative response
// draws for a call whose result `joined` found in the window.
fn call_rows(
  invocation: message.ToolCall,
  outcome: Option(message.AgentMessage),
  clock: Option(Int),
) -> List(Line) {
  // A send is its message row and a program its own rows, each drawn from
  // the call and the result the group joined to it.
  use <- result.lazy_unwrap(sent_lines(
    invocation,
    outcome,
    notes_view.Excerpt,
    clock,
  ))
  use <- result.lazy_unwrap(program_lines(invocation, outcome))

  // The invocation owns its source preview, so settling a result changes the
  // status without adding or removing code rows. Reuse the expanded entry's
  // Gleam renderer instead of displaying the transport JSON as a summary.
  let program = code_mode_program(invocation.name, invocation.arguments, False)
  let summary = program_summary(invocation, program)
  let rows = case outcome {
    None -> [Line(ToolCall, summary <> " · awaiting result")]
    Some(message.ToolResultMessage(is_error: True, content:, ..)) -> [
      Line(ToolFailure, summary),
      Line(
        ToolResult,
        content
          |> list.map(tool_result_text)
          |> string.join("\n")
          |> failure_preview,
      ),
    ]
    Some(message.ToolResultMessage(
      is_error: False,
      details: Some(json.Object(fields)),
      ..,
    ))
      if invocation.name == "fs_edit"
    -> [Line(ToolCall, "✓ " <> summary), ..edit_patch_lines(fields, False)]
    Some(message.ToolResultMessage(
      is_error: False,
      content: content,
      details: details,
      ..,
    ))
      if invocation.name == "context_remaining"
    -> [
      Line(ToolCall, "✓ " <> summary),
      ..tool_result_lines(
        "context_remaining",
        content,
        details,
        is_error: False,
        details_expanded: False,
      )
    ]

    // The pinned panel already shows the whole board, so a settled todo
    // call stays one row, which also keeps the compact height rule: the
    // pending row it replaces was one row too.
    Some(message.ToolResultMessage(is_error: False, details: Some(details), ..))
      if invocation.name == todo_board.tool_name
    -> [
      Line(
        ToolCall,
        "✓ "
          <> summary
          <> case todo_board.result_summary(details) {
          Some(progress) -> " · " <> progress
          None -> ""
        },
      ),
    ]
    Some(message.ToolResultMessage(is_error: False, ..)) -> [
      Line(ToolCall, "✓ " <> summary),
    ]
    Some(message.UserMessage(..))
    | Some(message.AssistantMessage(..))
    | Some(message.CustomMessage(..)) -> [Line(ToolCall, summary)]
  }
  let program = case outcome {
    Some(message.ToolResultMessage(is_error: False, ..)) -> None
    _ -> program
  }
  let rows = case rows, program {
    [heading, ..details], Some(source) -> [
      heading,
      Line(ToolDetail, source),
      ..details
    ]
    [], Some(_) | _, None -> rows
  }
  let images = case outcome {
    Some(message.ToolResultMessage(content:, ..)) -> result_image_lines(content)
    Some(_) | None -> []
  }
  list.flatten([
    rows,
    note_call_lines(invocation.name, invocation.arguments, notes_view.Excerpt),
    images,
  ])
}

// The placeholder rows of a tool result's images, under the rows of the
// call that returned them.
fn result_image_lines(content: List(message.ToolResultBlock)) -> List(Line) {
  content
  |> list.filter_map(fn(block) {
    case block {
      message.ToolResultImage(data:, mime_type:) -> Ok(#(mime_type, data))
      message.ToolResultText(..) -> Error(Nil)
    }
  })
  |> image_lines
}

// One placeholder row per image, numbered by its place among its row's
// images, the numbering `transcript_image` names an image by.
fn image_lines(images: List(#(String, String))) -> List(Line) {
  list.index_map(images, fn(image, index) {
    Line(
      ImageRow(image_header.picture(image.0, image.1)),
      image_header.describe(index + 1, image.0, image.1),
    )
  })
}

/// The rows the terminal's `Ctrl+g` shows for one tool call under its
/// summary: the whole program, patch or argument text the model sent,
/// then the whole result or failure once the outcome is known.
///
/// These are the same builders expanded history runs (`assistant_block_lines`
/// for the invocation, `message_lines` for the result), not a second
/// rendering, so a host that lets its reader expand one call shows what the
/// terminal shows. The invocation's own first row is left out when it is
/// the call's summary, which the host draws itself (`call_summary`). It is
/// kept when the summary was cut short (it holds the `…` `compact` leaves), because for a
/// generic tool that row is where the whole text lives: a `Bash` command
/// over the summary's limit is otherwise never fully visible. A call with nothing more to show than
/// `activity_call_lines` gives returns those same rows, and a host compares
/// the two to decide whether to offer an expansion at all.
///
/// ## Examples
///
/// ```gleam
/// // transcript_lines.expanded_call_lines(call)
/// //   == [Line(ToolDetail, "```gleam\n<the whole program>\n```"), ..]
/// ```
pub fn expanded_call_lines(call: tool_activity.Call) -> List(Line) {
  let invocation = case
    assistant_block_lines(
      message.AssistantToolCall(call.invocation),
      True,
      None,
    )
  {
    // A send's row is not its summary: it carries the whole message, which
    // is what expanding the call is for.
    [Line(speaker: SentMessage, ..) as head, ..rest] -> [head, ..rest]
    [head, ..rest] ->
      case string.contains(call_summary(call), "…") {
        True -> [head, ..rest]
        False -> rest
      }
    [] -> []
  }
  let outcome = case call.outcome {
    Some(result) -> message_lines(result, True, None, [], unjoined, None)
    None -> []
  }
  list.append(invocation, outcome)
}

/// The one-line summary of a tool call, as its compact row names it: the
/// tool and its target (`Bash(ls)`, `fs_edit · src/a.gleam`), or
/// `code_mode` for a program.
///
/// ## Examples
///
/// ```gleam
/// // transcript_lines.call_summary(call) == "fs_edit · src/app.gleam"
/// ```
pub fn call_summary(call: tool_activity.Call) -> String {
  program_summary(
    call.invocation,
    code_mode_program(call.invocation.name, call.invocation.arguments, False),
  )
}

fn program_summary(
  invocation: message.ToolCall,
  program: Option(String),
) -> String {
  case program {
    Some(_) -> "code_mode"
    None -> tool_call_summary(invocation.name, invocation.arguments, False)
  }
}

/// The newest entry one strand holds among `records`, which are newest
/// first: the entry a transient notice raised now is anchored after.
///
/// ## Examples
///
/// ```gleam
/// assert transcript_lines.newest_entry([], "main") == option.None
/// ```
pub fn newest_entry(
  records: List(protocol.EntryRecord),
  strand: String,
) -> Option(ids.EntryId) {
  records
  |> list.find(fn(record) { record.strand == strand })
  |> result.map(fn(record) { record.entry.id })
  |> option.from_result
}

/// The text of a person's message, its blocks joined line by line, before
/// the transcript's paste bound is applied.
///
/// ## Examples
///
/// ```gleam
/// assert transcript_lines.user_body([message.UserText("hi", option.None)])
///   == "hi"
/// ```
pub fn user_body(content: List(message.UserBlock)) -> String {
  content
  |> list.map(user_block_text)
  |> string.join("\n")
}

// Notes are useful output, even when ordinary tool details are collapsed.
// Known note tools expose their value; arbitrary tool JSON keeps its own schema.
fn note_call_lines(
  name: String,
  arguments: json.JsonValue,
  extent: notes_view.Extent,
) -> List(Line) {
  let value = case name, arguments {
    "agent_note", json.Object(fields) -> list.key_find(fields, "value")
    "remember", json.Object(fields) -> list.key_find(fields, "note")
    "agent_send", json.Object(fields) -> list.key_find(fields, "message")
    _, _ -> Error(Nil)
  }
  case value {
    Ok(value) -> {
      let body = notes_view.readable(json.to_string(value))
      let body = case name, extent {
        "agent_send", notes_view.Excerpt -> message_excerpt(body)
        _, _ -> body
      }
      [Line(ToolDetail, body)]
    }
    Error(Nil) -> []
  }
}

// The one row an `agent_send` call becomes, or an error when its arguments
// do not name a recipient and a message, or when the tool refused the send,
// which leaves the call to the generic rows every other tool gets, so a
// refusal's reason shows. The heading is built from the call's arguments
// and its result, which is `None` when no result is joined to the call
// here; the body is drawn beneath it and never read.
fn sent_lines(
  call: message.ToolCall,
  outcome: Option(message.AgentMessage),
  extent: notes_view.Extent,
  clock: Option(Int),
) -> Result(List(Line), Nil) {
  use fields <- result.try(case call.name, call.arguments {
    "agent_send", json.Object(fields) -> Ok(fields)
    _, _ -> Error(Nil)
  })
  use recipient <- result.try(option.to_result(string_field(fields, "to"), Nil))
  use body <- result.try(option.to_result(string_field(fields, "message"), Nil))
  use taken <- result.try(case outcome {
    None -> Ok("")
    Some(message.ToolResultMessage(
      is_error: False,
      details: Some(json.Object(fields)),
      timestamp:,
      ..,
    )) ->
      case string_field(fields, "delivery") {
        Some("started") ->
          Ok(" · started a run on it" <> clock_text(timestamp, clock))
        _ -> Ok(" · admitted to its queue" <> clock_text(timestamp, clock))
      }
    Some(message.ToolResultMessage(is_error: False, timestamp:, ..)) ->
      Ok(" · admitted to its queue" <> clock_text(timestamp, clock))
    Some(_) -> Error(Nil)
  })
  Ok([
    Line(
      SentMessage,
      "→ to "
        <> text_hygiene.single_line(recipient)
        <> " · agent_send"
        <> taken
        <> "\n"
        <> message_body(body, extent),
    ),
  ])
}

// The rows a compact `code_mode` call becomes, from its program and the
// result joined to it, or an error for a call that is not a foreground
// program, which leaves it to the generic rows. A program that completed
// is one row with its value; one that failed is a titled block with the
// error; one with no result yet is a titled block with the opening of its
// program, which is all the client receives while it runs.
fn program_lines(
  call: message.ToolCall,
  outcome: Option(message.AgentMessage),
) -> Result(List(Line), Nil) {
  use fields <- result.try(case call.name, call.arguments {
    "code_mode", json.Object(fields) -> Ok(fields)
    _, _ -> Error(Nil)
  })
  use program <- result.try(option.to_result(
    string_field(fields, "program"),
    Nil,
  ))
  case outcome {
    None -> Ok([Line(ProgramRunning, running_text(program, fields))])
    Some(message.ToolResultMessage(
      is_error: False,
      details: Some(json.Object(details)),
      content:,
      ..,
    )) -> Ok([Line(ToolCall, "✓ " <> settled_text(details, content))])
    Some(message.ToolResultMessage(
      is_error: True,
      details: Some(json.Object(details)),
      content:,
      ..,
    )) -> Ok([Line(ProgramFailure, failure_text(details, content, fields))])
    Some(_) -> Error(Nil)
  }
}

// How many of a program's lines a running block shows.
const fragment_lines = 4

// How many lines of an error a failure block shows.
const error_lines = 4

// A settled program's one row: its status and its value, cut to a row.
fn settled_text(
  details: List(#(String, json.JsonValue)),
  content: List(message.ToolResultBlock),
) -> String {
  let status = string_field(details, "status") |> option.unwrap("completed")
  let value = case list.key_find(details, "value") {
    Ok(value) -> json.to_string(value)
    Error(Nil) -> content |> list.map(tool_result_text) |> string.join("\n")
  }
  let calls = case call_tree.read(json.Object(details)) {
    Some(log) -> " · " <> call_count(log)
    None -> ""
  }
  "code_mode · " <> status <> calls <> " · result " <> compact(value, 90)
}

// A record's count as a settled row says it: `4 calls` when every call
// settled, and the record's whole summary when any did not.
fn call_count(log: CallLog) -> String {
  case log.failed + log.cancelled + log.unsettled {
    0 -> count_text(log.total, "call", "calls")
    _ -> call_tree.summary(log)
  }
}

// How many groups of calls a failure block lists.
const call_groups = 4

// The calls section of a failure block, from the host's record: a
// `CALLS · …` line and the calls grouped where consecutive calls share a
// capability and an ending, with a closing line for the groups and calls
// not listed. The arguments start in one column, after the widest glyph,
// capability and count, so a list of calls reads as a table. A failure
// names its error code in words (`failed · exit status`), and a call that
// failed, that had not settled or that took over a second says how long
// it took (`· 4.1s`). A call's argument summary is the host's redacted
// one, cut to a row.
@internal
pub fn call_section(log: CallLog) -> List(String) {
  let groups = call_groups_of(log.items)
  let shown = list.take(groups, call_groups)
  let unlisted =
    list.fold(list.drop(groups, call_groups), 0, fn(total, group) {
      total + group.count
    })
    + log.total
    - list.length(log.items)
  let labels =
    list.map(shown, fn(group) {
      let glyph = case group.call.status {
        call_tree.Settled -> "✓ "
        call_tree.Failed -> "× "
        call_tree.Cancelled -> "○ "
        call_tree.Unsettled -> "◐ "
      }
      let times = case group.count {
        1 -> ""
        n -> " ×" <> int.to_string(n)
      }
      glyph <> text_hygiene.single_line(group.call.cap) <> times
    })
  let column =
    list.fold(labels, 0, fn(widest, label) {
      int.max(widest, string.length(label))
    })
  let rows =
    list.map2(shown, labels, fn(group, label) {
      let ending = case group.call.status {
        call_tree.Settled -> ""
        call_tree.Failed ->
          "  failed"
          <> option_text(option.map(group.call.error, error_words), " · ")
        call_tree.Cancelled -> "  cancelled"
        call_tree.Unsettled -> "  not settled"
      }
      let took = case group.call.status, group.duration_ms > 1000 {
        call_tree.Failed, _ | call_tree.Unsettled, _ | _, True ->
          " · " <> seconds_text(group.duration_ms)
        call_tree.Settled, False | call_tree.Cancelled, False -> ""
      }
      string.pad_end(label, column, " ")
      <> case group.args {
        [] -> ""
        args -> "  " <> compact(string.join(args, " · "), 72)
      }
      <> ending
      <> took
    })
  let more = case unlisted {
    0 -> []
    n -> ["… " <> count_text(n, "more call", "more calls")]
  }
  ["", "CALLS · " <> call_tree.summary(log), ..list.append(rows, more)]
}

// A run of consecutive calls that share a capability, an ending and an
// error code.
type CallGroup {
  CallGroup(
    // The first call of the run, which names the capability and ending.
    call: call_tree.Call,
    // How many calls the run holds.
    count: Int,
    // Their argument summaries, in order.
    args: List(String),
    // Their durations added up, in milliseconds.
    duration_ms: Int,
  )
}

fn call_groups_of(calls: List(call_tree.Call)) -> List(CallGroup) {
  calls
  |> list.fold([], fn(groups: List(CallGroup), call) {
    let args = case call.args {
      Some(args) -> [text_hygiene.single_line(args)]
      None -> []
    }
    case groups {
      [first, ..rest]
        if first.call.cap == call.cap
        && first.call.status == call.status
        && first.call.error == call.error
      -> [
        CallGroup(
          ..first,
          count: first.count + 1,
          args: list.append(first.args, args),
          duration_ms: first.duration_ms + call.duration_ms,
        ),
        ..rest
      ]
      [] | [_, ..] -> [CallGroup(call, 1, args, call.duration_ms), ..groups]
    }
  })
  |> list.reverse
}

// A capability's error code as a reader says it: the codes the host
// writes in words, and any other code as it is.
fn error_words(code: String) -> String {
  case code {
    "exit_status" -> "exit status"
    "policy" -> "policy refused"
    "budget" -> "budget"
    "aborted" -> "aborted"
    "unauthorized" -> "unauthorized"
    "not_found" -> "not found"
    "permission_denied" -> "permission denied"
    "fs_failure" -> "file system failure"
    other -> text_hygiene.single_line(other)
  }
}

// A call's duration: tenths of a second from one second up, and whole
// milliseconds below it.
fn seconds_text(ms: Int) -> String {
  case ms >= 1000 {
    True -> {
      let tenths = { ms + 50 } / 100
      int.to_string(tenths / 10) <> "." <> int.to_string(tenths % 10) <> "s"
    }
    False -> int.to_string(ms) <> "ms"
  }
}

// A running block: the title, the foot naming the budget the call asked
// for, and the opening of the program, each shown line under its own
// number. Blank lines are skipped, so the lines shown are ones that say
// something.
fn running_text(
  program: String,
  fields: List(#(String, json.JsonValue)),
) -> String {
  let lines = string.split(string.trim_end(program), "\n")
  let shown =
    lines
    |> list.index_map(fn(line, index) { #(index + 1, line) })
    |> list.filter(fn(pair) { string.trim(pair.1) != "" })
    |> list.take(fragment_lines)
  let budget = case int_field(fields, "within_ms") {
    Some(ms) -> "budget " <> duration_text(ms)
    None -> ""
  }

  // The key that expands a response is on its heading, once; a block's
  // foot keeps only its facts.
  [
    "◐ code_mode · awaiting its result",
    budget,
    "PROGRAM · "
      <> count_text(list.length(lines), "line", "lines")
      <> ", "
      <> int.to_string(list.length(shown))
      <> " shown",
    ..numbered(shown)
  ]
  |> list.append([
    "",
    "RESULT · none yet · the result arrives when the program ends",
  ])
  |> string.join("\n")
}

/// The title a code-mode result's status is worded as: what failed, in the
/// transcript's failure block and anywhere else that names a program's end.
/// A status this does not know is a plain failure.
///
/// ## Examples
///
/// ```gleam
/// assert transcript_lines.status_title("vetting_rejected")
///   == "refused by vetting"
/// ```
@internal
pub fn status_title(status: String) -> String {
  case status {
    "compile_failed" -> "compile error"
    "vetting_rejected" -> "refused by vetting"
    "run_failed" -> "did not finish"
    "program_failed" -> "program failed"
    _ -> "failed"
  }
}

// A failure block: what failed in the title, why in the body, and how much
// more there is in the foot. A compiler's diagnostic is cut to its heading
// and the source lines it names; any other error is its opening lines.
fn failure_text(
  details: List(#(String, json.JsonValue)),
  content: List(message.ToolResultBlock),
  arguments: List(#(String, json.JsonValue)),
) -> String {
  // A program the deadline stopped says the budget it ran out of, when the
  // call named one.
  let budget = case int_field(arguments, "within_ms") {
    Some(ms) -> " · budget " <> duration_text(ms)
    None -> ""
  }
  let said = content |> list.map(tool_result_text) |> string.join("\n")
  let status = string_field(details, "status") |> option.unwrap("")
  let title = status_title(status)
  let #(foot, error) = case status {
    "compile_failed" -> #(
      "the program did not run",
      string_field(details, "detail") |> option.unwrap(said),
    )
    "vetting_rejected" -> #("the program did not run", said)
    "run_failed" -> #("the program was stopped" <> budget, said)
    "program_failed" -> #(
      "the program reported a failure",
      string_field(details, "message") |> option.unwrap(said),
    )
    _ -> #("the program did not finish", said)
  }
  let all = string.split(string.trim(text_hygiene.multiline(error)), "\n")
  let body = diagnostic(all)
  let more = case list.length(all) > list.length(body) {
    True -> " · " <> count_text(list.length(all), "line", "lines")
    False -> ""
  }
  let calls = case call_tree.read(json.Object(details)) {
    Some(log) -> call_section(log)
    None -> []
  }
  ["× code_mode · " <> title, foot <> more, ..list.append(body, calls)]
  |> string.join("\n")
}

// The rows of an error a failure block shows. A Gleam diagnostic opens with
// `error: …`, names its place on a `┌─ path:line:column` line, and quotes
// the source under numbered `│` gutters: the heading gains the line number,
// and the quoted lines follow it. Text in any other shape is shown from the
// top.
fn diagnostic(lines: List(String)) -> List(String) {
  let quoted =
    list.filter(lines, fn(line) {
      let trimmed = string.trim_start(line)
      case string.split_once(trimmed, " │") {
        Ok(#(number, _)) -> int.parse(number) |> result.is_ok
        Error(Nil) ->
          string.starts_with(trimmed, "│") && string.contains(line, "^")
      }
    })
  let place =
    list.find_map(lines, fn(line) {
      use #(_, path) <- result.try(string.split_once(line, "┌─ "))
      case list.reverse(string.split(path, ":")) {
        [_column, line, ..] -> int.parse(line)
        _ -> Error(Nil)
      }
    })
  case lines, quoted, place {
    [heading, ..], [_, ..], Ok(number) -> [
      heading <> " · line " <> int.to_string(number),
      ..list.take(quoted, error_lines - 1)
    ]
    _, _, _ ->
      lines
      |> list.filter(fn(line) { string.trim(line) != "" })
      |> list.take(error_lines)
  }
}

// Program lines under right-aligned numbers and a gutter, the form the
// renderer draws as source.
fn numbered(lines: List(#(Int, String))) -> List(String) {
  let width =
    list.fold(lines, 1, fn(widest, pair) {
      int.max(widest, string.length(int.to_string(pair.0)))
    })
  list.map(lines, fn(pair) {
    "  "
    <> string.pad_start(int.to_string(pair.0), width, " ")
    <> " │ "
    <> text_hygiene.single_line(pair.1)
  })
}

fn count_text(count: Int, one: String, many: String) -> String {
  int.to_string(count)
  <> " "
  <> case count {
    1 -> one
    _ -> many
  }
}

// A budget in milliseconds, in whole seconds when it is one.
fn duration_text(ms: Int) -> String {
  case ms % 1000 {
    0 -> int.to_string(ms / 1000) <> "s"
    _ -> int.to_string(ms) <> "ms"
  }
}

/// The results of a compact window joined to the calls they answer, for
/// responses whose calls are drawn as narrative.
///
/// A response that carries prose is narrative (`tool_activity`), so its
/// calls are drawn inside it and their results arrive as entries of their
/// own. Each call is drawn as a tool group draws it, settled, failed with
/// its reason, a send with its admission, a program with its value, an
/// image result with its image's row, which only the result knows; so the
/// call's rows are drawn from both and the result entry draws nothing.
pub opaque type Joined {
  Joined(
    // Keyed by the calling entry's identity and the provider call id.
    outcomes: Dict(#(String, String), message.AgentMessage),
    // The result entries whose content a call's row now draws.
    absorbed: Set(String),
  )
}

/// Joins each result of a joined tool in `entries`, oldest first, to the
/// latest earlier call with its provider id.
///
/// ## Examples
///
/// ```gleam
/// let found = transcript_lines.joined([])
/// ```
@internal
pub fn joined(entries: List(entry.Entry)) -> Joined {
  let #(found, _open) =
    list.fold(
      entries,
      #(Joined(dict.new(), set.new()), dict.new()),
      fn(acc, value) {
        let #(found, open) = acc
        case value {
          // A reused provider id replaces the earlier call: the next result
          // with that id answers the latest call that made it.
          entry.MessageEntry(
            message: message.AssistantMessage(content:, ..),
            ..,
          ) -> {
            let caller = ids.entry_id_to_string(value.id)
            let open =
              list.fold(content, open, fn(open, block) {
                case block {
                  message.AssistantToolCall(message.ToolCall(id:, ..)) ->
                    dict.insert(open, id, caller)
                  message.AssistantText(..) | message.AssistantThinking(..) ->
                    open
                }
              })
            #(found, open)
          }

          // A result joined to its call is drawn by the call's row, a
          // failure's included: the call's rows carry the failure and its
          // reason, as a tool group's do.
          entry.MessageEntry(
            message: message.ToolResultMessage(tool_call_id:, ..) as outcome,
            ..,
          ) ->
            case dict.get(open, tool_call_id) {
              Ok(caller) -> #(
                Joined(
                  outcomes: dict.insert(
                    found.outcomes,
                    #(caller, tool_call_id),
                    outcome,
                  ),
                  absorbed: set.insert(
                    found.absorbed,
                    ids.entry_id_to_string(value.id),
                  ),
                ),
                dict.delete(open, tool_call_id),
              )
              Error(Nil) -> #(found, open)
            }

          entry.MessageEntry(..)
          | entry.CompactionEntry(..)
          | entry.BranchSummaryEntry(..)
          | entry.CustomEntry(..) -> #(found, open)
        }
      },
    )
  found
}

/// Whether `value` is a result that its call's row already draws
/// (`joined`), and so draws no rows of its own in compact history.
///
/// ## Examples
///
/// ```gleam
/// // transcript_lines.absorbed(transcript_lines.joined(entries), result)
/// ```
@internal
pub fn absorbed(found: Joined, value: entry.Entry) -> Bool {
  set.contains(found.absorbed, ids.entry_id_to_string(value.id))
}

/// Whether drawing `value` in compact history reads a joined result, so
/// that its rows cannot be cached against the entry alone: the result
/// arrives as a later entry and changes the row of a call already drawn.
///
/// ## Examples
///
/// ```gleam
/// // transcript_lines.reads_joined(response)
/// ```
@internal
pub fn reads_joined(value: entry.Entry) -> Bool {
  case value {
    entry.MessageEntry(message: message.AssistantMessage(content:, ..), ..) ->
      list.any(content, fn(block) {
        case block {
          message.AssistantToolCall(..) -> True
          message.AssistantText(..) | message.AssistantThinking(..) -> False
        }
      })
    entry.MessageEntry(..)
    | entry.CompactionEntry(..)
    | entry.BranchSummaryEntry(..)
    | entry.CustomEntry(..) -> False
  }
}

// A message preview is its first twelve lines and the hint that expands
// it; expansion exposes the complete body from the same immutable call
// arguments. The terminal draws a message body as text, line by line, so a
// cut needs no regard for Markdown.
fn message_excerpt(body: String) -> String {
  let lines = string.split(body, "\n")
  case list.drop(lines, 12) {
    [] -> body
    _ ->
      string.join(list.take(lines, 12), "\n")
      <> "\n\n… Ctrl+g shows the complete message"
  }
}

/// These are captured tool diffs, not a claim about the worktree's current
/// contents. Retention can omit earlier edits, and later external edits are
/// outside this transcript's authority, so the panel names that boundary.
@internal
pub fn diff_content(presentation: Presentation) -> List(Line) {
  case presentation.worktree.board {
    Some(_) ->
      list.map(worktree_view.patches(presentation.worktree), fn(row) {
        case row {
          worktree_view.PatchHeading(text) -> Line(System, text)
          worktree_view.PatchBody(text) -> Line(ToolPatch, text)
        }
      })
    None -> [
      Line(System, presentation.worktree.message),
      ..captured_diff_content(presentation)
    ]
  }
}

fn captured_diff_content(presentation: Presentation) -> List(Line) {
  let edits =
    presentation.records
    |> list.reverse
    |> list.filter(fn(record) { record.strand == presentation.active_strand })
    |> list.flat_map(fn(record) {
      case record.entry {
        entry.MessageEntry(
          message: message.ToolResultMessage(
            tool_name: "fs_edit",
            is_error: False,
            details: Some(json.Object(fields)),
            ..,
          ),
          ..,
        ) ->
          case string_field(fields, "diff") {
            None -> []
            Some(diff) -> [
              Line(
                System,
                string_field(fields, "path")
                  |> option.unwrap("edited file"),
              ),
              Line(ToolPatch, diff),
            ]
          }
        _ -> []
      }
    })
  case edits {
    [] -> [
      Line(System, "No captured edit diffs in the retained history window."),
    ]
    [_, ..] -> [
      Line(
        System,
        "Captured edits in history order · PgUp/PgDn scroll · Esc returns",
      ),
      ..edits
    ]
  }
}

/// Transcript lines for one durable entry.
///
/// `labels` supplies summarizer labels for the entry's long blocks; in
/// compact mode a labelled block shows its label in place of its opening.
@internal
pub fn entry_lines(
  value: entry.Entry,
  details_expanded: Bool,
  local_owner: Option(message.Origin),
  labels: block_summary.Labels,
) -> List(Line) {
  entry_rows(value, details_expanded, local_owner, labels, unjoined, None)
}

/// `entry_lines` with the local clock's offset (`Presentation.clock`), so
/// a message's heading shows the time it was admitted.
///
/// ## Examples
///
/// ```gleam
/// // transcript_lines.clocked_entry_lines(value, False, None, labels, Some(60))
/// ```
@internal
pub fn clocked_entry_lines(
  value: entry.Entry,
  details_expanded: Bool,
  local_owner: Option(message.Origin),
  labels: block_summary.Labels,
  clock: Option(Int),
) -> List(Line) {
  entry_rows(value, details_expanded, local_owner, labels, unjoined, clock)
}

/// `entry_lines` in compact history for an entry whose sends and programs
/// have their results joined in `found` (`joined`): each such call's row
/// is drawn from its result.
///
/// ## Examples
///
/// ```gleam
/// // transcript_lines.joined_entry_lines(response, None, labels, found)
/// ```
@internal
pub fn joined_entry_lines(
  value: entry.Entry,
  local_owner: Option(message.Origin),
  labels: block_summary.Labels,
  found: Joined,
  clock: Option(Int),
) -> List(Line) {
  entry_rows(value, False, local_owner, labels, outcome_in(found, value), clock)
}

/// `assistant_block_lines` in compact history for one block of `value`,
/// with the results joined in `found`: the rows `joined_entry_lines` draws
/// for that block, for a host that keeps a response's blocks apart.
///
/// ## Examples
///
/// ```gleam
/// // transcript_lines.joined_block_lines(block, None, response, found)
/// ```
@internal
pub fn joined_block_lines(
  block: message.AssistantBlock,
  label: Option(String),
  value: entry.Entry,
  found: Joined,
) -> List(Line) {
  block_lines(block, False, label, outcome_in(found, value), None)
}

// The joined result of each of `value`'s calls.
fn outcome_in(
  found: Joined,
  value: entry.Entry,
) -> fn(message.ToolCall) -> Option(message.AgentMessage) {
  let caller = ids.entry_id_to_string(value.id)
  fn(call: message.ToolCall) {
    dict.get(found.outcomes, #(caller, call.id)) |> option.from_result
  }
}

// No result is joined to any call: expanded history draws each result as
// its own entry, and a host drawing one block alone has no window to join.
fn unjoined(_call: message.ToolCall) -> Option(message.AgentMessage) {
  None
}

fn entry_rows(
  value: entry.Entry,
  details_expanded: Bool,
  local_owner: Option(message.Origin),
  labels: block_summary.Labels,
  receipt: fn(message.ToolCall) -> Option(message.AgentMessage),
  clock: Option(Int),
) -> List(Line) {
  let found = labels_for(value, labels)
  case value {
    entry.MessageEntry(message: value, ..) ->
      value
      |> harness_message_lines(
        details_extent(details_expanded),
        block_label(found, 0),
      )
      |> option.lazy_or(fn() {
        peer_message_lines(value, details_extent(details_expanded), clock)
      })
      |> option.lazy_or(fn() {
        sibling_message_lines(value, details_extent(details_expanded), clock)
      })
      |> option.lazy_unwrap(fn() {
        message_lines(
          value,
          details_expanded,
          local_owner,
          found,
          receipt,
          clock,
        )
      })
    entry.CompactionEntry(retained_tail:, tokens_before:, ..) -> [
      Line(
        System,
        "Context compacted · ~"
          <> tokens(tokens_before)
          <> " tokens before · "
          <> int.to_string(list.length(retained_tail))
          <> " messages kept",
      ),
    ]
    entry.BranchSummaryEntry(summary:, ..) -> [
      Line(System, "branch summary · " <> summary),
    ]
    entry.CustomEntry(custom_type:, data:, ..) -> [
      Line(System, "custom/" <> custom_type <> option_json(data)),
    ]
  }
}

const agent_notes_intro = "Your own notes for strand `"

/// Extracts the server-injected notes digest from a run-start message.
///
/// Run-start context is stored as an ordinary user-role message by the frozen
/// entry schema. The TUI recognizes the server-owned fenced preamble so this
/// machine context does not masquerade as operator-authored conversation.
@internal
pub fn agent_notes_payload(value: message.AgentMessage) -> Option(String) {
  case value {
    message.UserMessage(content: [message.UserText(text:, ..)], ..) ->
      case
        string.starts_with(text, agent_notes_intro),
        string.split_once(text, "\n```agent-notes\n")
      {
        True, Ok(#(_, fenced)) ->
          case string.split_once(fenced, "\n```") {
            Ok(#(payload, _)) -> Some(payload)
            Error(Nil) -> None
          }
        _, _ -> None
      }
    _ -> None
  }
}

// The harness-authored user messages the transcript must not attribute to
// the operator. Notes have a view of their own and so contribute no
// transcript rows at all; advisor traffic has no other home and collapses
// in place.
fn harness_message_lines(
  value: message.AgentMessage,
  extent: notes_view.Extent,
  label: Option(String),
) -> Option(List(Line)) {
  case agent_notes_payload(value) {
    Some(_payload) -> Some([])

    None ->
      value
      |> advisor_payload
      |> option.map(labelled_advisor_lines(_, extent, label))
  }
}

// A message another session's agent sent to this strand. It arrives as a
// user message, but an agent wrote it and the operator did not type it, so
// it is drawn as the advisor's messages are: a system heading naming where
// it came from, then its body as Markdown, which is how both hosts draw an
// agent's prose. The web view's peer card draws the same body the same way.
fn peer_message_lines(
  value: message.AgentMessage,
  extent: notes_view.Extent,
  clock: Option(Int),
) -> Option(List(Line)) {
  case value {
    message.UserMessage(
      content:,
      origin: Some(message.PeerOrigin(session:, strand:)),
      timestamp:,
    ) ->
      Some([
        Line(
          PeerMessage,
          "⇄ peer session "
            <> short_session(text_hygiene.single_line(session))
            <> " · strand "
            <> text_hygiene.single_line(strand)
            <> " · "
            <> origin_checked
            <> clock_text(timestamp, clock)
            <> "\n"
            <> message_body(user_body(content), extent),
        ),
      ])
    _ -> None
  }
}

// A message heading's time: ` · 14:02`, the local clock time `at` (Unix
// milliseconds) falls on, or nothing when the host knows no offset. A clock
// time never goes stale, which a relative age (`12s ago`) on a cached row
// would.
fn clock_text(at: Int, clock: Option(Int)) -> String {
  case clock {
    None -> ""
    Some(offset) -> {
      let minutes = int.modulo(at / 60_000 + offset, 1440) |> result.unwrap(0)
      " · "
      <> string.pad_start(int.to_string(minutes / 60), 2, "0")
      <> ":"
      <> string.pad_start(int.to_string(minutes % 60), 2, "0")
    }
  }
}

/// The words a peer message's heading ends with. Only a `PeerOrigin` draws
/// them, and the admission host writes that origin only after it has
/// authenticated the sending session, so the claim is the daemon's and not
/// the sender's.
pub const origin_checked = "✓ origin checked by the daemon"

// A session identifier, a UUID, is named by the eight characters before
// its first dash, as the picker names one. Anything else is shown whole.
fn short_session(session: String) -> String {
  case string.slice(session, 8, 1) {
    "-" -> string.slice(session, 0, 8)
    _ -> session
  }
}

// A message another strand of this same session sent through the Agency.
// The stored origin is the only thing that selects it: the Agency's framing
// is removed from a message already known to carry `StrandOrigin`, and a
// text that merely looks framed, under any other origin, is drawn as the
// operator's input like any other. A spawn brief's result-contract trailer
// is the harness's own instruction to the child, so it follows the body as
// a line of its own.
fn sibling_message_lines(
  value: message.AgentMessage,
  extent: notes_view.Extent,
  clock: Option(Int),
) -> Option(List(Line)) {
  case value {
    message.UserMessage(
      content:,
      origin: Some(message.StrandOrigin(strand:)),
      timestamp:,
    ) -> {
      let framed = strand_framing.strip(user_body(content), strand)
      let body = case framed.trailer {
        Some(instruction) -> framed.body <> "\n\n" <> instruction
        None -> framed.body
      }
      Some([
        Line(
          StrandMessage,
          "← from "
            <> text_hygiene.single_line(strand)
            <> " · strand message"
            <> clock_text(timestamp, clock)
            <> "\n"
            <> message_body(body, extent),
        ),
      ])
    }
    _ -> None
  }
}

// A message body as its row draws it: the complete text when details are
// expanded, and otherwise its first twelve lines with the hint that expands
// it. Every kind of message is cut the same way, so a sent, a sibling's and
// a peer's message of one length preview to one height.
fn message_body(body: String, extent: notes_view.Extent) -> String {
  let body = text_hygiene.multiline(body)
  case extent {
    notes_view.Complete -> body
    notes_view.Excerpt -> message_excerpt(body)
  }
}

// --- summarizer labels -------------------------------------------------------

/// The blocks of one committed entry the daemon labels (protocol 050), by
/// their index in the message's content: every reasoning block that is not
/// redacted and holds at least `block_summary.floor_bytes` of text, and the
/// body of a delivered advice or nudges message at least that long.
///
/// The daemon also skips reasoning from a provider other than its
/// summarizer's, which this terminal cannot see; such a block is asked
/// about, answered with nothing, and keeps its first-line digest.
///
/// ## Examples
///
/// ```gleam
/// // tui.summarizable_blocks(an_entry_with_one_long_thought) == [0]
/// ```
@internal
pub fn summarizable_blocks(value: entry.Entry) -> List(Int) {
  case value {
    entry.MessageEntry(message: message.AssistantMessage(content:, ..), ..) ->
      content
      |> list.index_map(fn(block, index) { #(block, index) })
      |> list.filter_map(fn(pair) {
        case pair.0 {
          message.AssistantThinking(thinking:, redacted: False, ..) ->
            case string.byte_size(thinking) >= block_summary.floor_bytes {
              True -> Ok(pair.1)
              False -> Error(Nil)
            }
          message.AssistantThinking(redacted: True, ..)
          | message.AssistantText(..)
          | message.AssistantToolCall(..) -> Error(Nil)
        }
      })

    entry.MessageEntry(message: message.UserMessage(..) as sent, ..) ->
      case delivered_body(sent) {
        Some(body) ->
          case string.byte_size(body) >= block_summary.floor_bytes {
            True -> [0]
            False -> []
          }
        None -> []
      }

    entry.MessageEntry(message: message.ToolResultMessage(..), ..)
    | entry.MessageEntry(message: message.CustomMessage(..), ..)
    | entry.CompactionEntry(..)
    | entry.BranchSummaryEntry(..)
    | entry.CustomEntry(..) -> []
  }
}

// The advice or nudges body the daemon labels. The feed, the goal feed and
// a continuation are harness context rather than advice, and are never
// labelled.
fn delivered_body(value: message.AgentMessage) -> Option(String) {
  case advisor_payload(value) {
    Some(Advice(body:)) | Some(Nudges(body:)) -> Some(body)
    Some(Feed(..)) | Some(GoalFeed(..)) | Some(Continuation(..)) | None -> None
  }
}

/// The labels `labels` holds for the long blocks of `value`, by block
/// index. A block with no stored label of its own may borrow the live
/// label of the stream that produced the entry, but only the entry's
/// first long reasoning block does: the stream's text was that block's
/// beginning, and the borrowed label is replaced when the block's own
/// label arrives.
///
/// ## Examples
///
/// ```gleam
/// // tui.labels_for(entry, labels) == [#(1, "The agent weighs two fixes.")]
/// ```
@internal
pub fn labels_for(
  value: entry.Entry,
  labels: block_summary.Labels,
) -> List(#(Int, String)) {
  let blocks = summarizable_blocks(value)
  use <- bool.guard(when: blocks == [], return: [])

  let id = ids.entry_id_to_string(value.id)
  let first_reasoning = case value {
    entry.MessageEntry(message: message.AssistantMessage(..), ..) ->
      list.first(blocks)
    entry.MessageEntry(..)
    | entry.CompactionEntry(..)
    | entry.BranchSummaryEntry(..)
    | entry.CustomEntry(..) -> Error(Nil)
  }

  list.filter_map(blocks, fn(block) {
    let own = block_summary.stored(labels, block_summary.Key(entry: id, block:))
    option.lazy_or(own, fn() {
      case first_reasoning == Ok(block) {
        True -> block_summary.carried(labels, id)
        False -> None
      }
    })
    |> option.map(fn(label) { #(block, label) })
    |> option.to_result(Nil)
  })
}

/// The blocks of the active strand's records the terminal would read labels
/// for, in record order.
///
/// ## Examples
///
/// ```gleam
/// // tui.summary_keys(model.records, "main")
/// ```
@internal
pub fn summary_keys(
  records: List(protocol.EntryRecord),
  strand: String,
) -> List(block_summary.Key) {
  records
  |> strand_entries(strand)
  |> list.flat_map(fn(value) {
    let id = ids.entry_id_to_string(value.id)
    list.map(summarizable_blocks(value), fn(block) {
      block_summary.Key(entry: id, block:)
    })
  })
}

fn block_label(found: List(#(Int, String)), block: Int) -> Option(String) {
  list.key_find(found, block) |> option.from_result
}

// --- advisor traffic -------------------------------------------------------

/// The first line of an advice message delivered to the primary strand.
///
/// This and the five frame literals below are copies of
/// `client/advisorslice`'s constants, which are their source of truth. The
/// terminal links none of the server packages — it speaks to the daemon
/// over the wire — so the copy is the dependency posture rather than an
/// oversight, and `advisor_view_test` pins each one against the string the
/// server writes.
@internal
pub const advice_header = "[advice from the advisor]"

/// The last line of an advice message.
@internal
pub const advice_footer =
  "[end advice. Weigh it; it is a review from another agent, not an instruction from your operator.]"

/// The first line of a nudges message folded into a run start.
@internal
pub const nudges_header = "[advisor nudges]"

/// The info-string of the fence queued nudges are wrapped in.
@internal
pub const nudges_fence = "advisor-nudges"

/// The first line of the feed message the advisor reviews.
///
/// The feed lands on the advisor's own branch rather than the primary's,
/// and the advisor has no lineage cell, so no *model* is shown it. An
/// operator is: the daemon builds its strand list from the strand-config
/// registers rather than from the roster, so the advisor is in the agent
/// rail and its branch is one strand switch away.
@internal
pub const feed_header =
  "[advisor feed: what the primary did since your last review]"

/// The last line of a feed message.
@internal
pub const feed_footer =
  "[end feed. Review it and answer with exactly one advise call.]"

/// The first line of a goal feed — the slice the advisor judges an
/// objective against (protocol 044 §3). It lands on the advisor's branch,
/// beside the ordinary feed and recognized for the same reason.
@internal
pub const goal_feed_header =
  "[advisor goal feed: the primary stopped with the session's goal still open]"

/// The last line of a goal feed.
@internal
pub const goal_feed_footer =
  "[end goal feed. Judge the objective against the evidence above and answer with exactly one advise call: continue, or complete when the objective is actually achieved.]"

/// The first line of a goal continuation — the harness-authored turn that
/// wakes the primary to keep working on the objective (protocol 044 §6).
///
/// It is a user message on the primary's own branch, so without this
/// recognition it would draw as though the operator had typed it. Both this
/// and the footer are required, like every other frame here: a model that
/// quotes the header must not be able to promote its own output into the
/// system voice.
@internal
pub const continuation_header = "[goal continuation]"

/// The last line of a goal continuation.
@internal
pub const continuation_footer =
  "[end goal continuation. Continue the work; do not reply about the frame.]"

// How much of a body the collapsed row shows. The same bound `composer`
// previews an oversized paste with, and for the same reason: the pane wraps
// what it is given, so this only has to keep one pathological line from
// becoming a paragraph.
const advisor_preview_limit = 120

/// Advisor traffic the transcript recognizes rather than draws as a prompt.
@internal
pub type AdvisorMessage {
  /// A verdict, already stripped of its header and footer lines. Those
  /// frame the body for the model that reads the message and say nothing
  /// the operator needs.
  Advice(body: String)

  /// Queued nudges, as the bullet lines inside their fence.
  Nudges(body: String)

  /// A window of the primary's branch, rendered for the advisor to review.
  /// It appears on the advisor's own branch and nowhere else.
  Feed(body: String)

  /// The same window under the goal frame, which additionally names the
  /// objective and the budget. Also the advisor's branch only.
  GoalFeed(body: String)

  /// The harness-authored turn that wakes the primary to continue a goal.
  /// The one frame here that is neither advice nor a review: it is work to
  /// do, drawn in the system voice because the operator did not type it.
  Continuation(body: String)
}

/// Extracts advisor traffic from a durable message.
///
/// All three frames arrive as ordinary user turns, because a user turn is
/// the only shape a provider API has for context the harness supplies.
/// Recognizing them is what keeps a review by another model, and the
/// transcript replayed for it, from being attributed to the person at the
/// keyboard. Advice and nudges are found on the primary's branch and the
/// feed on the advisor's, but which branch is on screen is the operator's
/// choice, so the same recognizer serves both.
///
/// Each frame is recognized by its first line *and* its body delimiter, the
/// same two-token test `agent_notes_payload` makes. Attribution is what is
/// being decided here, so a turn that merely quotes a frame — an operator
/// pasting a nudge back to ask about it — has to fail the test rather than
/// be relabelled as the advisor's.
///
/// ## Examples
///
/// ```gleam
/// // tui.advisor_payload(an_ordinary_turn) == option.None
/// ```
///
@internal
pub fn advisor_payload(value: message.AgentMessage) -> Option(AdvisorMessage) {
  case value {
    message.UserMessage(content: [message.UserText(text:, ..)], ..) ->
      advisor_frame(text)

    // `advisorslice` writes every frame as a single text block, so any
    // other shape is somebody else's message.
    message.UserMessage(..)
    | message.AssistantMessage(..)
    | message.ToolResultMessage(..)
    | message.CustomMessage(..) -> None
  }
}

fn advisor_frame(text: String) -> Option(AdvisorMessage) {
  // Each frame opens with a header line of its own and only the nudges
  // frame carries a fence, so no text satisfies two of these tests and the
  // order they are tried in decides nothing.
  use <- option.lazy_or(advice_frame(text))
  use <- option.lazy_or(nudges_frame(text))
  use <- option.lazy_or(feed_frame(text))
  use <- option.lazy_or(goal_feed_frame(text))

  continuation_frame(text)
}

fn advice_frame(text: String) -> Option(AdvisorMessage) {
  text |> framed_body(advice_header, advice_footer) |> option.map(Advice)
}

fn nudges_frame(text: String) -> Option(AdvisorMessage) {
  text |> nudges_body |> option.map(Nudges)
}

fn feed_frame(text: String) -> Option(AdvisorMessage) {
  text |> framed_body(feed_header, feed_footer) |> option.map(Feed)
}

fn goal_feed_frame(text: String) -> Option(AdvisorMessage) {
  text
  |> framed_body(goal_feed_header, goal_feed_footer)
  |> option.map(GoalFeed)
}

fn continuation_frame(text: String) -> Option(AdvisorMessage) {
  text
  |> framed_body(continuation_header, continuation_footer)
  |> option.map(Continuation)
}

// The body between a header line and its footer, or nothing when the text
// does not carry both.
//
// The server writes both tokens on every frame — the footer is appended
// after the body, and its byte caps bound a slice rather than a frame — so
// requiring the pair costs nothing a reader would have seen. What it buys
// is the case this recognizer exists for: a turn that merely quotes a
// header, an operator pasting a verdict back to ask about it, stays the
// operator's own prompt instead of being redrawn as harness speech.
fn framed_body(text: String, header: String, footer: String) -> Option(String) {
  use #(first, rest) <- option.then(
    text |> string.split_once("\n") |> option.from_result,
  )
  use <- bool.guard(when: first != header, return: None)

  rest
  |> string.split_once("\n" <> footer)
  |> option.from_result
  |> option.map(fn(halves) { halves.0 })
}

// The bullet lines inside the nudges fence. A fence opened but never closed
// still renders its remainder: losing the text because a byte cap cut the
// closing fence would be worse than showing a little more than was fenced.
fn nudges_body(text: String) -> Option(String) {
  use <- bool.guard(
    when: !string.starts_with(text, nudges_header),
    return: None,
  )
  use #(_before, rest) <- option.then(
    text
    |> string.split_once("\n```" <> nudges_fence <> "\n")
    |> option.from_result,
  )

  case string.split_once(rest, "\n```") {
    Ok(#(body, _after)) -> Some(body)
    Error(Nil) -> Some(rest)
  }
}

/// Renders advisor traffic as transcript lines.
///
/// Delivered advice and nudges keep their full bodies in both detail modes.
/// Review feeds and goal continuations remain compact until expanded: they
/// are harness context, not a message from the advisor to the primary. Frame
/// lines appear in neither mode because they address the model.
///
/// ## Examples
///
/// ```gleam
/// // tui.advisor_lines(tui.Advice("rerun the test"), notes_view.Complete)
/// ```
///
@internal
pub fn advisor_lines(
  value: AdvisorMessage,
  extent: notes_view.Extent,
) -> List(Line) {
  labelled_advisor_lines(value, extent, None)
}

/// `advisor_lines` for a delivered message the summarizer may have
/// labelled (protocol 050).
///
/// Advice and nudges shorter than `block_summary.floor_bytes` keep their
/// whole body in both modes, as before labels existed. A longer one
/// collapses in compact mode to its heading and one line: the label,
/// introduced as the summarizer's, or the body's opening line while no
/// label has arrived. Detail mode shows the whole body either way.
///
/// ## Examples
///
/// ```gleam
/// // tui.labelled_advisor_lines(tui.Advice(long_body), notes_view.Excerpt,
/// //   Some("The advisor asks for a rerun."))
/// ```
@internal
pub fn labelled_advisor_lines(
  value: AdvisorMessage,
  extent: notes_view.Extent,
  label: Option(String),
) -> List(Line) {
  let heading = advisor_heading(value)
  let long = string.byte_size(value.body) >= block_summary.floor_bytes

  // `System` rather than `User` in both: the row is context the harness put
  // on this branch, and the shaded `› User` block a user turn is drawn in
  // would say the operator typed it.
  case value, extent {
    Advice(..), notes_view.Excerpt | Nudges(..), notes_view.Excerpt if long -> [
      delivered_summary_line(heading, value, label),
    ]
    Advice(..), _ | Nudges(..), _ -> [
      Line(System, heading),
      Line(ToolDetail, value.body),
    ]
    _, notes_view.Excerpt -> [
      Line(System, heading <> advisor_preview(value) <> composer.expand_hint),
    ]

    _, notes_view.Complete -> [
      Line(System, heading),
      Line(ToolDetail, value.body),
    ]
  }
}

// What the row is, in the words the operator reads. The count belongs in a
// nudges heading because the bullets are the whole of the content: a reader
// deciding whether to expand wants to know there are three of them.
fn advisor_heading(value: AdvisorMessage) -> String {
  case value {
    Advice(..) -> "Advisor · block delivered"

    Nudges(body:) ->
      "Advisor · nudges delivered (" <> int.to_string(nudge_count(body)) <> ")"

    Feed(..) -> "advisor feed"

    GoalFeed(..) -> "advisor goal feed"

    Continuation(..) -> "goal continuation"
  }
}

// The opening of a verdict or a feed, shown beside the heading while the
// row is collapsed. Nudges add nothing here; their count is already in the
// heading.
fn advisor_preview(value: AdvisorMessage) -> String {
  case value {
    Advice(body:) | Feed(body:) | GoalFeed(body:) | Continuation(body:) ->
      ": " <> compact(opening_line(body), advisor_preview_limit)

    Nudges(..) -> ""
  }
}

/// One advisor body cut to the row a collapsed view shows: its opening line,
/// compacted to the same bound the delivered rows use.
///
/// ## Examples
///
/// ```gleam
/// assert transcript_lines.advisor_body_preview("check\nmore") == "check"
/// ```
@internal
pub fn advisor_body_preview(body: String) -> String {
  compact(opening_line(body), advisor_preview_limit)
}

// A collapsed long advice or nudges message: its heading, marked as
// summarized when the summarizer's label is what follows, and then that
// label or the body's opening line as the secondary text beneath it.
fn delivered_summary_line(
  heading: String,
  value: AdvisorMessage,
  label: Option(String),
) -> Line {
  case label {
    Some(label) ->
      Line(
        SummarizedAdvice,
        heading <> " (summarized)" <> expand_hint <> "\n" <> label,
      )
    None ->
      Line(
        SummarizedAdvice,
        heading <> expand_hint <> "\n" <> opening_line(value.body),
      )
  }
}

fn opening_line(body: String) -> String {
  case string.split_once(body, "\n") {
    Ok(#(first, _rest)) -> first
    Error(Nil) -> body
  }
}

// Each nudge is written as one `- ` bullet, so counting the markers counts
// the nudges even where one of them ran to several lines.
fn nudge_count(body: String) -> Int {
  body
  |> string.split("\n")
  |> list.count(string.starts_with(_, "- "))
}

fn message_lines(
  value: message.AgentMessage,
  details_expanded: Bool,
  local_owner: Option(message.Origin),
  found: List(#(Int, String)),
  receipt: fn(message.ToolCall) -> Option(message.AgentMessage),
  clock: Option(Int),
) -> List(Line) {
  case value {
    message.UserMessage(content:, origin:, ..) -> [
      Line(
        User,
        user_author_prefix(origin, local_owner)
          <> {
          content
          |> user_body
          |> composer.transcript_text(details_expanded)
        },
      ),
      ..content
      |> list.filter_map(fn(block) {
        case block {
          message.UserImage(data:, mime_type:) -> Ok(#(mime_type, data))
          message.UserText(..) -> Error(Nil)
        }
      })
      |> image_lines
    ]
    message.AssistantMessage(content:, error_message:, stop_reason:, ..) -> {
      // Expanded history has no activity group to fold a run of parallel
      // calls into, so one response's own blocks are separated here. The gap
      // between one response and the next entry is a different boundary and
      // belongs to the fold over entries, not to this one.
      let lines =
        content
        |> list.index_map(fn(block, index) {
          block_lines(
            block,
            details_expanded,
            block_label(found, index),
            receipt,
            clock,
          )
        })
        |> separated_tool_groups(WithinResponse)

      list.append(lines, assistant_terminal_lines(stop_reason, error_message))
    }
    message.ToolResultMessage(tool_name:, content:, details:, is_error:, ..) ->
      list.append(
        tool_result_lines(
          tool_name,
          content,
          details,
          is_error,
          details_expanded,
        ),
        result_image_lines(content),
      )
    message.CustomMessage(schema:, payload:) -> [
      Line(System, schema <> " · " <> json.to_string(payload)),
    ]
  }
}

/// The durable stop reason distinguishes a user abort from a failed turn. A
/// clean abort commits no diagnostic at all, so an `Aborted` message that
/// carries one names a stop the harness could not establish: an unconfirmed
/// provider cancellation, a lost drain proof, or an orphaned response settled
/// across a restart. The provider may still be generating in all three, so the
/// text stays visible at both extents. It is dim detail rather than the failure
/// style because it describes the provider, not a failed turn.
@internal
pub fn assistant_terminal_lines(
  reason: message.StopReason,
  diagnostic: Option(String),
) -> List(Line) {
  case reason, diagnostic {
    message.Aborted, Some(text) -> [
      Line(System, "Stopped"),
      Line(ToolDetail, text),
    ]
    message.Aborted, None -> [Line(System, "Stopped")]
    _, Some(text) -> [Line(Failure, text)]
    _, None -> []
  }
}

/// Only a coherent presence cut can establish that this terminal is alone.
/// Matching the connection as well as the historical identity keeps remote
/// authors and pre-rename messages attributed even after their peers leave.
@internal
pub fn solo_owner(
  captured: Option(#(snapshot.Captured, snapshot_view.View)),
) -> Option(message.Origin) {
  use #(cut, view) <- option.then(captured)
  case cut.attachment.role, view.peers {
    snapshot.Owner, [peer]
      if peer.connection_id == cut.attachment.connection_id
      && peer.origin == cut.attachment.origin
    -> Some(cut.attachment.origin)
    _, _ -> None
  }
}

fn user_author_prefix(
  origin: Option(message.Origin),
  local_owner: Option(message.Origin),
) -> String {
  case origin {
    None -> ""
    Some(author) if Some(author) == local_owner -> ""
    Some(author) ->
      text_hygiene.single_line(origin.display_label(author)) <> ":\n"
  }
}

fn user_block_text(block: message.UserBlock) -> String {
  case block {
    message.UserText(text:, ..) -> text
    message.UserImage(mime_type:, ..) -> "[image " <> mime_type <> "]"
  }
}

/// Both questions have the same two answers: whether a row carries a whole
/// value or a cut of it. The daemon's truncation flag already names them and
/// the row builders below take that type, so the Ctrl+g state is converted to
/// it here rather than at each call site.
@internal
pub fn details_extent(details_expanded: Bool) -> notes_view.Extent {
  case details_expanded {
    True -> notes_view.Complete
    False -> notes_view.Excerpt
  }
}

/// Transcript lines for one block of an assistant message. `label` is the
/// summarizer's label for a long reasoning block, which the compact row
/// shows in place of the block's opening line.
@internal
pub fn assistant_block_lines(
  block: message.AssistantBlock,
  details_expanded: Bool,
  label: Option(String),
) -> List(Line) {
  block_lines(block, details_expanded, label, unjoined, None)
}

fn block_lines(
  block: message.AssistantBlock,
  details_expanded: Bool,
  label: Option(String),
  receipt: fn(message.ToolCall) -> Option(message.AgentMessage),
  clock: Option(Int),
) -> List(Line) {
  case block {
    message.AssistantText(text:, ..) -> [Line(Assistant, text)]
    message.AssistantThinking(thinking:, redacted:, ..) ->
      case redacted {
        // A redacted block has no text behind the marker, so expanding it
        // would show the same row again. It stays one row in both modes.
        True -> [Line(ReasoningDigest, "redacted")]

        False -> [
          settled_reasoning_line(
            thinking,
            details_extent(details_expanded),
            label,
          ),
        ]
      }

    // A call whose result the window joined to it draws the rows a tool
    // group draws for it, so a response holding prose settles its calls
    // as a group of calls does.
    message.AssistantToolCall(call:) -> {
      use <- result.lazy_unwrap(case details_expanded, receipt(call) {
        False, Some(outcome) -> Ok(call_rows(call, Some(outcome), clock))
        False, None | True, _ -> Error(Nil)
      })
      use <- result.lazy_unwrap(sent_lines(
        call,
        receipt(call),
        details_extent(details_expanded),
        clock,
      ))

      // Expanded history draws the whole program and, below it, the whole
      // result entry; compact history draws the program's own rows.
      use <- result.lazy_unwrap(case details_expanded {
        False -> program_lines(call, receipt(call))
        True -> Error(Nil)
      })
      let message.ToolCall(name:, arguments:, ..) = call
      case
        code_mode_program(name, arguments, details_expanded),
        patch_program(name, arguments, details_expanded)
      {
        Some(program), _ -> [
          Line(ToolCall, "code_mode"),
          Line(ToolDetail, program),
        ]
        None, Some(program) -> [
          Line(ToolCall, "apply_patch"),
          Line(ToolDetail, program),
        ]
        None, None -> [
          Line(ToolCall, tool_call_summary(name, arguments, details_expanded)),
          ..note_call_lines(name, arguments, details_extent(details_expanded))
        ]
      }
    }
  }
}

fn patch_program(
  name: String,
  arguments: json.JsonValue,
  details_expanded: Bool,
) -> Option(String) {
  case name, arguments {
    "apply_patch", json.Object(fields) ->
      case string_field(fields, "patch") {
        Some(patch) -> {
          let source = case details_expanded {
            True -> patch
            False -> program_preview(patch, patch_preview_lines)
          }
          Some("```diff\n" <> source <> "\n```")
        }
        None -> None
      }
    _, _ -> None
  }
}

/// Renders a structured code-mode call as bounded fenced Gleam.
///
/// This is internal because the shape belongs to the transcript projection;
/// it is public only so the executed-program display law can be pinned.
///
/// ## Examples
///
/// ```gleam
/// let arguments = json.Object([#("program", json.String("pub fn main() {}"))])
/// let assert Some(source) = tui.code_mode_program("code_mode", arguments, True)
/// ```
@internal
pub fn code_mode_program(
  name: String,
  arguments: json.JsonValue,
  details_expanded: Bool,
) -> Option(String) {
  case name, arguments {
    "code_mode", json.Object(fields) ->
      case list.key_find(fields, "program") {
        Ok(json.String(program)) -> {
          let source = case details_expanded {
            True -> program
            False -> program_preview(program, code_preview_lines)
          }
          Some(fenced_gleam(source))
        }
        Ok(_) | Error(Nil) -> None
      }
    _, _ -> None
  }
}

fn fenced_gleam(source: String) -> String {
  case string.ends_with(source, "\n") {
    True -> "```gleam\n" <> source <> "```"
    False -> "```gleam\n" <> source <> "\n```"
  }
}

fn program_preview(program: String, limit: Int) -> String {
  let lines = string.split(program, "\n")
  case list.drop(lines, limit) {
    [] -> program
    _ ->
      lines
      |> list.take(limit)
      |> list.append(["// …"])
      |> string.join("\n")
  }
}

/// Formats the operator-relevant part of a tool call without exposing the
/// transport JSON envelope as the primary UI.
@internal
pub fn tool_call_summary(
  name: String,
  arguments: json.JsonValue,
  details_expanded: Bool,
) -> String {
  // Full argument encoding belongs to the fallback. Eagerly encoding a
  // large patch or file body just to display its path wastes every repaint.
  case name, arguments {
    "bash", json.Object(fields) ->
      case string_field(fields, "command") {
        Some(command) ->
          case details_expanded {
            True -> "Bash($ " <> command <> ")"
            False -> "Bash(" <> compact(command, 112) <> ")"
          }
        None ->
          generic_tool_call(name, json.to_string(arguments), details_expanded)
      }
    "read", json.Object(fields) | "fs_read", json.Object(fields) ->
      case string_field(fields, "path") {
        Some(path) -> name <> " · " <> compact(path, 112) <> read_window(fields)
        None ->
          generic_tool_call(name, json.to_string(arguments), details_expanded)
      }
    "fs_write", json.Object(fields) | "fs_edit", json.Object(fields) ->
      case string_field(fields, "path") {
        Some(path) -> name <> " · " <> compact(path, 112)
        None ->
          generic_tool_call(name, json.to_string(arguments), details_expanded)
      }
    "agent_spawn", json.Object(fields) ->
      case string_field(fields, "purpose") {
        Some(purpose) ->
          case details_expanded {
            True ->
              "agent_spawn\npurpose: "
              <> purpose
              <> option_text(string_field(fields, "brief"), "\nbrief: ")
            False -> "agent_spawn · " <> compact(purpose, 108)
          }
        None ->
          generic_tool_call(name, json.to_string(arguments), details_expanded)
      }
    "agent_send", json.Object(fields) ->
      case string_field(fields, "to") {
        Some(recipient) -> "Message to " <> recipient
        None ->
          generic_tool_call(name, json.to_string(arguments), details_expanded)
      }
    "agent_wait", json.Object(fields) ->
      case list.key_find(fields, "handles") {
        Ok(json.Array(handles)) ->
          "agent_wait · "
          <> int.to_string(list.length(handles))
          <> case handles {
            [_] -> " subagent"
            _ -> " subagents"
          }
        _ ->
          generic_tool_call(name, json.to_string(arguments), details_expanded)
      }
    "grep", json.Object(fields) ->
      "grep"
      <> option_text(string_field(fields, "pattern"), " · ")
      <> option_text(string_field(fields, "path"), " in ")
    "agent_note", json.Object(fields) ->
      "agent_note"
      <> option_text(string_field(fields, "key"), " · ")
      <> case details_expanded {
        True -> "\n" <> json.to_string(arguments)
        False -> ""
      }
    "remember", json.Object(_) ->
      case details_expanded {
        True -> "remember\n" <> json.to_string(arguments)
        False -> "remember · durable note"
      }
    "agent_notes", json.Object(fields) ->
      "agent_notes" <> option_text(string_field(fields, "prefix"), " · ")
    "context_remaining", json.Object(_) -> "context remaining"
    "todo", json.Object(_) -> todo_board.call_summary(arguments)
    _, _ -> generic_tool_call(name, json.to_string(arguments), details_expanded)
  }
}

fn generic_tool_call(
  name: String,
  rendered: String,
  details_expanded: Bool,
) -> String {
  case details_expanded {
    True -> name <> "\n" <> rendered
    False -> name <> " · " <> compact(rendered, 120)
  }
}

fn option_text(value: Option(String), prefix: String) -> String {
  case value {
    Some(text) -> prefix <> text
    None -> ""
  }
}

fn string_field(
  fields: List(#(String, json.JsonValue)),
  name: String,
) -> Option(String) {
  case list.key_find(fields, name) {
    Ok(json.String(value)) -> Some(value)
    _ -> None
  }
}

// Diagnostics stay multiline and prominent. Extremely long errors have an
// explicit expansion path rather than retaining an unbounded compact layout.
fn failure_preview(value: String) -> String {
  let clipped = string.slice(value, 0, 1600)
  let lines = string.split(clipped, "\n")
  case list.drop(lines, 8) == [] && clipped == value {
    True -> value
    False ->
      string.join(list.take(lines, 8), "\n")
      <> "\n… Ctrl+g shows the full error"
  }
}

fn tool_result_lines(
  tool_name: String,
  content: List(message.ToolResultBlock),
  details: Option(json.JsonValue),
  is_error is_error: Bool,
  details_expanded details_expanded: Bool,
) -> List(Line) {
  let result = content |> list.map(tool_result_text) |> string.join("\n")

  // Hashline presentation belongs to the model, not the screen: a read's
  // digest and anchors go, and so does the fresh-anchor block an edit or a
  // write now carries. A failure keeps its text, since a rejection's fresh
  // anchors are the reason it failed.
  let result = case tool_name, is_error {
    "fs_read", False -> file_read_view.render(result)
    "fs_edit", False | "fs_write", False ->
      file_read_view.without_fresh_anchors(result)
    _, _ -> result
  }
  case tool_name, is_error, details {
    "code_mode", False, Some(json.Object(fields)) ->
      code_mode_result_lines(fields, result, details_expanded)

    "fs_edit", False, Some(json.Object(fields)) -> [
      Line(ToolResult, "fs_edit · " <> compact(result, 120)),
      ..edit_patch_lines(fields, details_expanded)
    ]
    "context_remaining", False, Some(json.Object(fields)) ->
      context_remaining_result_lines(
        fields,
        result,
        details_extent(details_expanded),
      )
    _, True, _ -> [
      Line(
        ToolFailure,
        tool_name
          <> "\n"
          <> case details_expanded {
          True -> result
          False -> failure_preview(result)
        },
      ),
      ..failed_call_lines(tool_name, details, details_expanded)
    ]

    // Expanded, a wait shows each child's report as the child's answer
    // rather than inside the tool's plain text; collapsed, it keeps the one
    // compact row every result has.
    "agent_wait", False, Some(json.Object(fields)) ->
      case details_expanded, list.key_find(fields, "results") {
        True, Ok(json.Array(results)) -> [
          Line(ToolResult, "agent_wait"),
          ..list.flat_map(results, waited_lines)
        ]
        _, _ -> plain_result_lines(tool_name, result, details_expanded)
      }

    // The pinned panel carries the board, so a collapsed result names only
    // the progress it left rather than the checklist flattened onto one
    // row; Ctrl+g still shows the whole list the model read back.
    "todo", False, Some(value) ->
      case details_expanded, todo_board.result_summary(value) {
        False, Some(progress) -> [Line(ToolResult, "todo · " <> progress)]
        True, _ | False, None ->
          plain_result_lines(tool_name, result, details_expanded)
      }
    _, False, _ -> plain_result_lines(tool_name, result, details_expanded)
  }
}

// One child's part of an expanded `agent_wait` result, read from the
// result's details. A ready child's report is its final answer, model prose
// like the parent's own, so it is drawn as Markdown under a heading that
// names the child and how its run ended, as the web view's result card
// draws it. A structured result and notes, when the child left them, follow
// as they are; a child still working is one row.
fn waited_lines(value: json.JsonValue) -> List(Line) {
  case value {
    json.Object(fields) -> {
      let child =
        string_field(fields, "strand")
        |> option.map(agent_roster.short_name)
        |> option.unwrap("sub-agent")
      case string_field(fields, "state") {
        Some("ready") -> ready_lines(fields, child)
        _ -> [Line(System, "sub:" <> child <> " · still working")]
      }
    }
    _ -> []
  }
}

fn ready_lines(
  fields: List(#(String, json.JsonValue)),
  child: String,
) -> List(Line) {
  let heading =
    "from sub:"
    <> child
    <> " · result · "
    <> option.unwrap(string_field(fields, "outcome"), "settled")
    <> option_text(string_field(fields, "abort_reason"), " · ")
  let report = case string_field(fields, "report") {
    Some("") | None -> "(no report: the run ended without a final answer)"
    Some(report) -> report
  }
  let notes = case list.key_find(fields, "notes") {
    Ok(json.Object([_, ..]) as notes) -> [
      Line(System, "notes · " <> json.to_string(notes)),
    ]
    _ -> []
  }
  list.flatten([
    [Line(System, heading), Line(ToolDetail, report)],
    result_lines(list.key_find(fields, "result")),
    notes,
  ])
}

// A given result is shown as its value, as the tool's own text shows it; an
// absent or unusable one keeps its whole verdict.
fn result_lines(result: Result(json.JsonValue, Nil)) -> List(Line) {
  case result {
    Ok(json.Object(verdict) as whole) ->
      case list.key_find(verdict, "state"), list.key_find(verdict, "value") {
        Ok(json.String("given")), Ok(value) -> [
          Line(System, "result · " <> json.to_string(value)),
        ]
        _, _ -> [Line(System, "result · " <> json.to_string(whole))]
      }
    Ok(other) -> [Line(System, "result · " <> json.to_string(other))]
    Error(Nil) -> []
  }
}

fn plain_result_lines(
  tool_name: String,
  result: String,
  details_expanded: Bool,
) -> List(Line) {
  [
    Line(ToolResult, case details_expanded {
      True -> tool_name <> "\n" <> result
      False -> tool_name <> " · " <> compact(result, 120)
    }),
  ]
}

// The tool's prose is guidance for the model. The transcript already has the
// measured fields, so show the operator the compact arithmetic instead.
fn context_remaining_result_lines(
  fields: List(#(String, json.JsonValue)),
  fallback: String,
  extent: notes_view.Extent,
) -> List(Line) {
  case context_remaining_summary(fields) {
    Some(summary) ->
      case extent {
        notes_view.Excerpt -> [Line(ToolResult, summary)]
        notes_view.Complete -> [
          Line(ToolResult, summary),
          Line(ToolDetail, context_remaining_boundary(fields)),
        ]
      }
    None -> [
      Line(ToolResult, case extent {
        notes_view.Complete -> "context_remaining\n" <> fallback
        notes_view.Excerpt -> "context_remaining · " <> compact(fallback, 120)
      }),
    ]
  }
}

fn context_remaining_summary(
  fields: List(#(String, json.JsonValue)),
) -> Option(String) {
  use window <- option.then(int_field(fields, "window"))
  use used <- option.then(int_field(fields, "used_tokens"))
  use capacity <- option.then(int_field(fields, "context_window"))
  use remaining <- option.then(int_field(fields, "remaining_tokens"))
  let boundary = case int_field(fields, "checkpoint_at") {
    Some(_) -> " until checkpoint"
    None -> " before context limit"
  }
  Some(
    "context remaining · window "
    <> int.to_string(window)
    <> " · "
    <> "~"
    <> tokens(used)
    <> " / "
    <> tokens(capacity)
    <> " used · ~"
    <> tokens(remaining)
    <> boundary,
  )
}

fn context_remaining_boundary(
  fields: List(#(String, json.JsonValue)),
) -> String {
  let checkpoint = case int_field(fields, "checkpoint_at") {
    Some(value) -> "checkpoint at " <> tokens(value)
    None -> "no checkpoint"
  }
  let notes = int_field(fields, "notes") |> option.unwrap(0)
  checkpoint <> " · " <> int.to_string(notes) <> " saved notes"
}

// The window a read asked for, appended to its row, and nothing at all for
// a read that asked for the whole file.
//
// The arguments are shown as they were given rather than as a derived line
// range, because the fact worth seeing is which of them the model sent. A
// stretch of rows reading one file collapses to a column of identical
// labels when the row carries only the path, and eight of those rows —
// differing only in a `limit` that shrank each time, with no `offset` at
// all — is what a real read loop looked like from here. A rendered
// `45-89` would have hidden the missing `offset` that caused it.
fn read_window(fields: List(#(String, json.JsonValue))) -> String {
  let parts =
    [
      #("offset", int_field(fields, "offset")),
      #("limit", int_field(fields, "limit")),
    ]
    |> list.filter_map(fn(pair) {
      case pair.1 {
        Some(value) -> Ok(pair.0 <> " " <> int.to_string(value))
        None -> Error(Nil)
      }
    })
  case parts {
    [] -> ""
    _ -> " · " <> string.join(parts, " ")
  }
}

fn int_field(
  fields: List(#(String, json.JsonValue)),
  name: String,
) -> Option(Int) {
  case list.key_find(fields, name) {
    Ok(json.Int(value)) -> Some(value)
    _ -> None
  }
}

// An edit renders as the unified diff its details carry — what changed,
// coloured as a diff — under the tool's one-line summary. Collapsed, the
// first stretch of the diff is enough to recognise the edit; expanded,
// the whole of it. Details without a diff (an older record) fall back to
// the summary alone.
fn edit_patch_lines(
  fields: List(#(String, json.JsonValue)),
  details_expanded: Bool,
) -> List(Line) {
  case string_field(fields, "diff") {
    Some(diff) -> {
      let shown = case details_expanded {
        True -> diff
        False -> program_preview(diff, patch_preview_lines)
      }
      [Line(ToolPatch, shown)]
    }
    None -> []
  }
}

fn code_mode_result_lines(
  fields: List(#(String, json.JsonValue)),
  fallback: String,
  details_expanded: Bool,
) -> List(Line) {
  let status = string_field(fields, "status") |> option.unwrap("completed")
  let value = case list.key_find(fields, "value") {
    Ok(value) -> value
    Error(Nil) -> json.String(fallback)
  }
  let sandbox = sandbox_summary(fields)

  // The host's record of the program's capability calls, when this result
  // carries a readable one. Results written before the record existed, and
  // ones whose record is malformed, read as no record and render exactly
  // as they always did.
  let calls = call_tree.read(json.Object(fields))
  let summary = option.map(calls, call_tree.summary)
  case details_expanded {
    False -> [
      Line(
        ToolResult,
        "code_mode · "
          <> status
          <> option_text(summary, " · ")
          <> " · result "
          <> compact(json.to_string(value), 90)
          <> option_text(sandbox, " · "),
      ),
    ]
    True -> [
      Line(ToolResult, "code_mode · " <> status <> option_text(summary, " · ")),
      Line(
        ToolDetail,
        "result\n\n```json\n" <> pretty_json(value, 0) <> "\n```",
      ),
      ..list.append(
        case calls {
          Some(log) -> call_rows_lines(log)
          None -> []
        },
        case sandbox {
          Some(summary) -> [Line(System, summary)]
          None -> []
        },
      )
    ]
  }
}

// The call record under a `code_mode` failure, when there is one. A
// program that fails or hits its deadline is where the record matters most,
// and a failure result is not a `code_mode` success, so it reaches this
// from the failure arm. A failure with no readable record, and any other
// tool's failure, gets nothing added.
fn failed_call_lines(
  tool_name: String,
  details: Option(json.JsonValue),
  details_expanded: Bool,
) -> List(Line) {
  case tool_name, details {
    "code_mode", Some(details) ->
      case call_tree.read(details) {
        Some(log) -> [
          Line(ToolResult, "code_mode · " <> call_tree.summary(log)),
          ..case details_expanded {
            True -> call_rows_lines(log)
            False -> []
          }
        ]
        None -> []
      }
    _, _ -> []
  }
}

// One row per itemised call, in admission order, and a closing row for the
// calls the host counted and did not itemise. The rows are drawn as text in
// a fence, so no field of a call, all of which derive from program-chosen
// strings, can be read as markup.
fn call_rows_lines(log: CallLog) -> List(Line) {
  case log.items {
    [] -> []
    items -> {
      let unlisted = log.total - list.length(items)
      let rows = list.map(items, call_row)
      let rows = case unlisted > 0 {
        True ->
          list.append(rows, [
            "… " <> int.to_string(unlisted) <> " more calls not itemised",
          ])
        False -> rows
      }
      [
        Line(
          ToolDetail,
          "calls\n\n```text\n" <> string.join(rows, "\n") <> "\n```",
        ),
      ]
    }
  }
}

fn call_row(call: call_tree.Call) -> String {
  let status = case call.status {
    call_tree.Settled -> "ok"
    call_tree.Failed -> "failed" <> option_text(call.error, " ")
    call_tree.Cancelled -> "cancelled"
    call_tree.Unsettled -> "unsettled"
  }
  call.cap
  <> option_text(call.args, " ")
  <> " · "
  <> status
  <> " · +"
  <> int.to_string(call.start_ms)
  <> "ms, "
  <> int.to_string(call.duration_ms)
  <> "ms"
}

/// The `sandbox · build enforced N layers; skipped M · satellite …` line a
/// `code_mode` result's `details` carry, or nothing when they name no sandbox.
/// Public so the Trace tab shows the line the lane's step detail shows.
///
/// ## Examples
///
/// ```gleam
/// assert transcript_lines.sandbox_summary([]) == None
/// ```
pub fn sandbox_summary(
  fields: List(#(String, json.JsonValue)),
) -> Option(String) {
  case list.key_find(fields, "sandbox") {
    Ok(json.Object(sandbox)) -> {
      let build = enforcement_summary(sandbox, "build")
      let node = enforcement_summary(sandbox, "node")
      Some("sandbox · build " <> build <> " · satellite " <> node)
    }
    _ -> None
  }
}

fn enforcement_summary(
  sandbox: List(#(String, json.JsonValue)),
  name: String,
) -> String {
  case list.key_find(sandbox, name) {
    Ok(json.Object(report)) -> {
      let reported = case list.key_find(report, "reported") {
        Ok(json.Bool(value)) -> value
        _ -> False
      }
      let enforced = json_array_length(report, "enforced")
      let skipped = json_array_length(report, "skipped")
      case reported {
        True ->
          "enforced "
          <> int.to_string(enforced)
          <> " layers; skipped "
          <> int.to_string(skipped)
        False -> "not launched"
      }
    }
    _ -> "not reported"
  }
}

fn json_array_length(
  fields: List(#(String, json.JsonValue)),
  name: String,
) -> Int {
  case list.key_find(fields, name) {
    Ok(json.Array(items)) -> list.length(items)
    _ -> 0
  }
}

/// Renders a JSON value with two-space indentation, starting at `depth`.
@internal
pub fn pretty_json(value: json.JsonValue, depth: Int) -> String {
  let indent = string.repeat("  ", depth)
  let child_indent = string.repeat("  ", depth + 1)
  case value {
    json.Object([]) -> "{}"
    json.Object(fields) ->
      fields
      |> list.map(fn(field) {
        let #(name, value) = field
        child_indent
        <> json.to_string(json.String(name))
        <> ": "
        <> pretty_json(value, depth + 1)
      })
      |> string.join(",\n")
      |> fn(body) { "{\n" <> body <> "\n" <> indent <> "}" }
    json.Array([]) -> "[]"
    json.Array(items) ->
      items
      |> list.map(fn(item) { child_indent <> pretty_json(item, depth + 1) })
      |> string.join(",\n")
      |> fn(body) { "[\n" <> body <> "\n" <> indent <> "]" }
    scalar -> json.to_string(scalar)
  }
}

/// Collapses `text` to one line of at most `limit` characters, ending in an
/// ellipsis when it was cut.
@internal
pub fn compact(text: String, limit: Int) -> String {
  let one_line = text_hygiene.single_line(text)
  case string.drop_start(one_line, limit) {
    "" -> one_line
    _ -> string.slice(one_line, 0, limit - 1) <> "…"
  }
}

fn tool_result_text(block: message.ToolResultBlock) -> String {
  case block {
    message.ToolResultText(text:, ..) -> text
    message.ToolResultImage(mime_type:, ..) -> "[image " <> mime_type <> "]"
  }
}

fn option_json(value: Option(json.JsonValue)) -> String {
  case value {
    Some(data) -> " · " <> json.to_string(data)
    None -> ""
  }
}

/// A token count abbreviated with `k` or `m`, as the transcript shows it.
@internal
pub fn tokens(value: Int) -> String {
  case value >= 1_000_000, value >= 1000 {
    // Millions keep one decimal: a footer reading `1m` for 1.9 million
    // tokens understates the figure by nearly half.
    True, _ -> {
      let tenths = value / 100_000
      int.to_string(tenths / 10) <> "." <> int.to_string(tenths % 10) <> "m"
    }
    False, True -> int.to_string(value / 1000) <> "k"
    False, False -> int.to_string(value)
  }
}

/// The shortest generation a rate is reported for, in milliseconds. A
/// sub-second window is dominated by request latency and by how the
/// provider batches its stream, so the quotient says nothing about
/// throughput; the footer shows no rate rather than a wrong one.
pub const output_rate_min_ms = 1000

/// Output tokens per second from a settled generation's output count and
/// the milliseconds it took. A generation shorter than
/// `output_rate_min_ms` reports `None` rather than a rate divided by a
/// window too small to mean anything.
///
/// ## Examples
///
/// ```gleam
/// assert tui.output_rate(300, 2000) == option.Some(150)
/// ```
///
/// ```gleam
/// assert tui.output_rate(126, 1) == option.None
/// ```
///
@internal
pub fn output_rate(output_tokens: Int, elapsed_ms: Int) -> Option(Int) {
  case elapsed_ms >= output_rate_min_ms {
    True -> Some(output_tokens * 1000 / elapsed_ms)
    False -> None
  }
}

/// The footer's rate piece: none until a generation has been timed.
///
/// ## Examples
///
/// ```gleam
/// assert tui.output_rate_label(option.Some(87)) == ["87 tok/s"]
/// ```
///
/// ```gleam
/// assert tui.output_rate_label(option.None) == []
/// ```
///
@internal
pub fn output_rate_label(rate: Option(Int)) -> List(String) {
  case rate {
    Some(rate) -> [int.to_string(rate) <> " tok/s"]
    None -> []
  }
}

/// The cumulative usage a session has spent, as the pieces the detailed
/// footer fits: the cache read/write pair, then the estimated cost,
/// uncached input and output. The cache piece carries the cache outlook
/// when there is one, so what the cache holds and how long it will keep it
/// read as one figure and the word "cache" is not spent twice. It comes
/// first because the outlook is the footer's one forward-looking warning,
/// and the row drops pieces from the right when it runs out of room.
///
/// ## Examples
///
/// ```gleam
/// // usage_pieces(usage, "cache idle 3m")
/// //   == #("cache 90k/123, idle 3m", ["est $0.04", "in 12k", "out 678"])
/// ```
@internal
pub fn usage_pieces(
  usage: message.Usage,
  outlook: String,
) -> #(String, List(String)) {
  let pair =
    "cache " <> tokens(usage.cache_read) <> "/" <> tokens(usage.cache_write)
  let reading = case string.split_once(outlook, "cache ") {
    Ok(#("", rest)) -> rest
    Ok(_) | Error(Nil) -> outlook
  }
  let cache = case reading {
    "" -> pair
    reading -> pair <> ", " <> reading
  }
  #(cache, [
    cost_words(usage),
    "in " <> tokens(usage.input),
    "out " <> tokens(usage.output),
  ])
}

/// The cumulative usage as one line, with no cache outlook.
///
/// ## Examples
///
/// ```gleam
/// // usage_summary(usage) == "est $0.04 · in 12k · out 678 · cache 90k/123"
/// ```
pub fn usage_summary(usage: message.Usage) -> String {
  let #(cache, spend) = usage_pieces(usage, "")
  string.join(list.append(spend, [cache]), " · ")
}

/// The estimated cost as the footer and the web bar word it: `est $0.04`,
/// or `est —` when no token was priced. A model with no price entry reports
/// a zero total, and `$0.00` after real work reads as a bug rather than as
/// "unpriced". A session that has spent nothing yet has priced nothing
/// either, so a zero total is unpriced whatever the token count: the figure
/// is not known, and `$0.00` would claim that it is.
///
/// ## Examples
///
/// ```gleam
/// // cost_words(priced) == "est $0.04"
/// // cost_words(spent_but_unpriced) == "est —"
/// // cost_words(nothing_spent_yet) == "est —"
/// ```
pub fn cost_words(usage: message.Usage) -> String {
  "est " <> cost_figure(usage)
}

/// The estimated cost as a figure alone, for a place whose label says it is
/// an estimate: `$0.04`, or `—` when no token was priced. Every surface
/// words a zero total through this rule, so a fresh session never reads
/// `$0.00` in one place and `est —` in another.
///
/// ## Examples
///
/// ```gleam
/// // cost_figure(priced) == "$0.04"
/// // cost_figure(nothing_spent_yet) == "—"
/// ```
pub fn cost_figure(usage: message.Usage) -> String {
  case usage.cost.total >. 0.0 {
    True -> "$" <> money(usage.cost.total)
    False -> "—"
  }
}

/// Currency is display data. Round once to cents before splitting the whole
/// and fractional parts, so binary floating point tails never reach the footer.
@internal
pub fn money(value: Float) -> String {
  let cents = int.max(0, float.round(value *. 100.0))
  int.to_string(cents / 100)
  <> "."
  <> string.pad_start(int.to_string(cents % 100), 2, "0")
}

fn advisor_history_label(annotation: advisor_history.Annotation) -> String {
  case annotation {
    advisor_history.AdvisorUpdate -> "Advisor · commentary"
    advisor_history.RequestedQuiet -> "Advisor · quiet requested"
    advisor_history.RequestedNudge -> "Advisor · nudge requested"
    advisor_history.RequestedBlock -> "Advisor · block requested"
    advisor_history.RequestedContinue -> "Advisor · continue requested"
    advisor_history.RequestedComplete -> "Advisor · complete requested"
  }
}

/// Compact tool groups keep the sequence of their first call. A later result
/// changes that group's contents, but cannot move the group past commentary
/// committed after the call began.
@internal
pub fn entry_sequences(entries: List(entry.Entry)) -> Dict(ids.EntryId, Int) {
  entries
  |> list.map(fn(value) { #(value.id, value.seq) })
  |> dict.from_list
}

@internal
pub fn item_sequence(
  item: tool_activity.Item,
  sequences: Dict(ids.EntryId, Int),
) -> Int {
  case item {
    tool_activity.Narrative(value) -> value.seq
    tool_activity.Tools([first, ..]) ->
      dict.get(sequences, first.source)
      |> result.unwrap(0)
    tool_activity.Tools([]) -> 0
  }
}

fn spliced_sequence(item: Spliced(a), sequence: fn(a) -> Int) -> Int {
  case item {
    Projected(value) -> sequence(value)
    Transient(_, after_seq) -> after_seq
  }
}

/// Both inputs are oldest first. The advisor block is placed after a primary
/// block at the same sequence, which keeps a local notice beside its owner.
@internal
pub fn merge_sequence_blocks(
  primary: List(#(Int, a)),
  advisor: List(#(Int, a)),
) -> List(#(Int, a)) {
  case primary, advisor {
    [], rest -> rest
    rest, [] -> rest
    [first, ..primary_rest], [next, ..advisor_rest] ->
      case first.0 <= next.0 {
        True -> [first, ..merge_sequence_blocks(primary_rest, advisor)]
        False -> [next, ..merge_sequence_blocks(primary, advisor_rest)]
      }
  }
}

/// The sequences commentary is merged at, oldest first: the places a tool
/// group must end for the commentary to land between its calls rather than
/// below all of them. The row projection and the anchor projection must both
/// split here, or their row counts part at every split.
///
/// ## Examples
///
/// ```gleam
/// assert transcript_lines.advisor_splits(advisor_history.Board([], None)) == []
/// ```
@internal
pub fn advisor_splits(board: advisor_history.Board) -> List(Int) {
  list.map(board.items, fn(item) { item.seq })
}

/// The heading travels with the first captured block, so a long advisor
/// history occupies its chronological place inside the settled row cache.
@internal
pub fn advisor_history_blocks(
  board: advisor_history.Board,
) -> List(#(Int, List(Line))) {
  case board.items {
    [] -> []
    [_, ..] -> {
      let heading = [
        Line(System, "Advisor transcript · captured, not sent to primary"),
      ]
      let missing = case board.unloaded {
        Some(_) -> [Line(System, "Earlier advisor commentary is not loaded")]
        None -> []
      }
      board.items
      |> list.index_map(fn(item, index) {
        let body = [
          Line(System, advisor_history_label(item.annotation)),
          Line(ToolDetail, item.text),
        ]
        case index {
          0 -> #(item.seq, list.append(heading, list.append(missing, body)))
          _ -> #(item.seq, body)
        }
      })
    }
  }
}
