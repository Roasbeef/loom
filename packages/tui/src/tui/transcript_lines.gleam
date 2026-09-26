//// Builds the transcript's `Line`s from durable entries, live streams and
//// tool traffic.
////
//// A `Line` is a speaker and a text, before Markdown and wrapping. This
//// module decides which lines a record, a stream or a tool call becomes and
//// in what order, and nothing else: it neither reads the socket nor paints
//// a buffer, and it imports only `model`. The projection
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
import gleam/string
import tui/advisor_history
import tui/block_summary
import tui/composer
import tui/file_read_view
import tui/model.{
  type CacheNotice, type Line, type Model, type Speaker, type Stream,
  type Submission, Assistant, Failure, HeldPrompt, Interjection, Line, Reasoning,
  ReasoningDigest, Spacer, Stream, System, ToolCall, ToolDetail, ToolFailure,
  ToolPatch, ToolResult, User,
}
import tui/notes_view
import tui/protocol
import tui/snapshot
import tui/snapshot_view
import tui/stream_identity
import tui/text_hygiene
import tui/todo_panel
import tui/tool_activity
import tui/worktree_view

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
/// // tui.tool_tail_lines(tui.Model(..model, details_expanded: True))
/// //   == [tui.Line(tui.ToolResult, "stdout · 31 B so far\ncompiling core")]
/// ```
@internal
pub fn tool_tail_lines(model: Model) -> List(Line) {
  case details_extent(model.details_expanded) {
    notes_view.Excerpt -> []
    notes_view.Complete -> expanded_tool_tail_lines(model)
  }
}

// The window itself, once the reader has asked for detail.
fn expanded_tool_tail_lines(model: Model) -> List(Line) {
  model.tool_tails
  |> list.filter(fn(tail) { tail.strand == model.active_strand })
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

/// Modern cuts carry the complete host queue, including other peers' input.
/// Replacing that list also removes drained rows after reconnect or a skipped
/// idle interval, without matching repeated text against transcript entries.
@internal
pub fn pending_input_lines(model: Model) -> List(Line) {
  let pending = case model.captured {
    Some(#(_, view)) -> view.pending_inputs
    None -> None
  }
  case pending {
    None -> queued_lines(model.queued, model.awaiting_outcome)
    Some(rows) -> {
      let visible =
        list.filter(rows, fn(row) { row.strand == model.active_strand })
      let queued =
        list.flat_map(visible, fn(row) {
          [
            Line(User, row.text),
            Line(System, case row.kind {
              snapshot_view.Steer -> "steer · runs next"
              snapshot_view.Queue -> "queued · after this turn"
            }),
          ]
        })
      list.append(queued, queued_lines([], model.awaiting_outcome))
    }
  }
}

/// Captured previews are standalone observations, never stored as delta
/// history. Once pushed observations arrive they take precedence, including
/// their empty terminal marker: unequal request identities do not prove that
/// a captured preview is newer than the request whose end was just observed.
@internal
pub fn display_streams(model: Model) -> List(Stream) {
  let active =
    list.filter(model.streams, fn(stream) {
      stream.strand == model.active_strand
      && !response_recorded(model.records, stream.generation)
    })
  let preview = case model.captured {
    Some(#(_, view)) ->
      case view.preview, dict.get(view.operations, model.active_strand) {
        Some(sample), Ok(op) if op == sample.operation ->
          case response_recorded(model.records, sample.generation) {
            True -> None
            False -> Some(sample)
          }
        Some(_), Ok(_) | Some(_), Error(Nil) | None, _ -> None
      }
    None -> None
  }
  case active, preview {
    [], Some(sample) -> [preview_stream(model.active_strand, sample)]
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
// Collapsed, each is exactly one `ReasoningDigest` row — clipped to the pane
// rather than wrapped, so the count holds at every width — and the settle
// therefore changes the row's words and not the transcript's height. A
// summarizer label changes the words of that one row too, never its count.
fn live_reasoning_line(
  text: String,
  extent: notes_view.Extent,
  label: Option(String),
  elapsed_s: Int,
) -> Line {
  case extent {
    notes_view.Complete -> Line(Reasoning, text)
    notes_view.Excerpt ->
      Line(ReasoningDigest, live_summary_digest(text, elapsed_s, label))
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
      Line(ReasoningDigest, summarized_reasoning_digest(label))
  }
}

/// The collapsed stand-in for a reasoning block still streaming, with how
/// long the generation has run and the newest summarizer label.
///
/// The count and the clock come first because they are what change while
/// the block streams, and the label last, because a narrow pane cuts a row
/// from its end. With neither a clock reading nor a label the row is
/// exactly `live_reasoning_digest`'s. The label is introduced as the
/// summarizer's (`block_summary.label_prefix`), so it cannot be read as
/// the agent's own words.
///
/// ## Examples
///
/// ```gleam
/// assert tui.live_summary_digest("one\ntwo", 64, None)
///   == "2 lines · 1m 04s so far"
/// ```
///
/// ```gleam
/// assert tui.live_summary_digest("one", 0, Some("The agent reads."))
///   == "1 line so far · summary: The agent reads."
/// ```
@internal
pub fn live_summary_digest(
  text: String,
  elapsed_s: Int,
  label: Option(String),
) -> String {
  let count = text |> string.split("\n") |> list.length
  let lines =
    int.to_string(count)
    <> case count {
      1 -> " line"
      _ -> " lines"
    }
  let so_far = case elapsed_s > 0 {
    True -> lines <> " · " <> elapsed_words(elapsed_s) <> " so far"
    False -> lines <> " so far"
  }
  case label {
    None -> so_far
    Some(label) ->
      so_far
      <> " · "
      <> block_summary.label_prefix
      <> compact(label, summary_digest_limit)
  }
}

/// The collapsed stand-in for a committed reasoning block that has a
/// summarizer label: the label, introduced as the summarizer's, and the key
/// that opens the block itself.
///
/// ## Examples
///
/// ```gleam
/// assert tui.summarized_reasoning_digest("The agent weighs two fixes.")
///   == "summary: The agent weighs two fixes.  [Ctrl+G to expand]"
/// ```
@internal
pub fn summarized_reasoning_digest(label: String) -> String {
  block_summary.label_prefix
  <> compact(label, summary_digest_limit)
  <> expand_hint
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

/// How much of a summarizer label a collapsed row keeps.
///
/// A label is already bounded by the daemon to two short sentences. The row
/// is clipped to the pane in any case; this only stops an unusually long
/// label from making every cached row key carry it whole.
pub const summary_digest_limit = 240

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
  let opening =
    text
    |> string.split("\n")
    |> list.filter_map(digest_opening_line)
    |> list.first
    |> result.unwrap(text)
  compact(opening, reasoning_digest_limit) <> expand_hint
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
pub fn active_notices(model: Model) -> List(CacheNotice) {
  list.filter(model.cache_notices, fn(notice) {
    notice.strand == model.active_strand
  })
}

/// Transcript lines for the durable records of the active strand, with
/// cache notices spliced in, plus the per-call and per-entry row caches the
/// projection reuses on the next rebuild.
@internal
pub fn record_lines(
  records: List(protocol.EntryRecord),
  model: Model,
  notices: List(CacheNotice),
  advisor: advisor_history.Board,
) -> #(
  List(Line),
  Dict(tool_activity.Call, List(Line)),
  Dict(#(entry.Entry, Option(message.Origin), List(#(Int, String))), List(Line)),
) {
  let entries = strand_entries(records, model.active_strand)
  let sequences = entry_sequences(entries)
  let owner = solo_owner(model.captured)
  case model.details_expanded {
    // Expanded history alternates a response carrying a call with the entry
    // carrying its result, and both close bare, so without this fold a run
    // of calls arrives as one undivided block. The entry boundary is the
    // only place that gap can be seen: the fold inside `message_lines` sees
    // one response at a time.
    True -> #(
      entries
        |> splice_notices(notices, entry_holds, fn(value) { value.seq })
        |> list.map(fn(item) {
          #(
            spliced_sequence(item, fn(value) { value.seq }),
            expanded_lines(item, owner, model.summaries),
          )
        })
        |> merge_sequence_blocks(advisor_history_blocks(advisor))
        |> list.map(fn(block) { block.1 })
        |> separated_tool_groups(BetweenEntries),
      dict.new(),
      dict.new(),
    )

    // Compact history places the same gap between items that expanded
    // history places between entries: a reasoning row carries no blank of
    // its own, so one opening a narrative under a group's bare last row
    // would otherwise sit welded to it.
    False -> {
      let #(reversed, calls, narratives) =
        entries
        |> tool_activity.project_split(advisor_splits(advisor))
        |> splice_notices(notices, item_holds, item_sequence(_, sequences))
        |> list.fold(#([], dict.new(), dict.new()), fn(acc, spliced) {
          case spliced {
            Transient(text, seq) -> #(
              [#(seq, [Line(System, text)]), ..acc.0],
              acc.1,
              acc.2,
            )
            Projected(item) ->
              compact_item_lines(
                acc,
                item,
                item_sequence(item, sequences),
                model,
                owner,
              )
          }
        })
      #(
        reversed
          |> list.reverse
          |> merge_sequence_blocks(advisor_history_blocks(advisor))
          |> list.map(fn(block) { block.1 })
          |> separated_tool_groups(BetweenEntries),
        calls,
        narratives,
      )
    }
  }
}

// Expanded history renders every entry in full, so a spliced place is
// either the entry itself or the transient row standing after it.
fn expanded_lines(
  spliced: Spliced(entry.Entry),
  owner: Option(message.Origin),
  labels: block_summary.Labels,
) -> List(Line) {
  case spliced {
    Transient(text, _) -> [Line(System, text)]
    Projected(value) -> entry_lines(value, True, owner, labels)
  }
}

// One projected item folded into the compact accumulator: each item's rows,
// newest item first, the call cache and the narrative cache. Lifted out of
// the fold so the caches it reads are parameters rather than a closure over
// the model, which is what lets the notice fold share the same accumulator
// shape.
fn compact_item_lines(
  acc: #(
    List(#(Int, List(Line))),
    Dict(tool_activity.Call, List(Line)),
    Dict(
      #(entry.Entry, Option(message.Origin), List(#(Int, String))),
      List(Line),
    ),
  ),
  item: tool_activity.Item,
  seq: Int,
  model: Model,
  owner: Option(message.Origin),
) -> #(
  List(#(Int, List(Line))),
  Dict(tool_activity.Call, List(Line)),
  Dict(#(entry.Entry, Option(message.Origin), List(#(Int, String))), List(Line)),
) {
  case item {
    // The labels the entry's rows would show are part of the key, so a
    // label arriving is a new key and the entry is projected again, while
    // every other cached narrative is reused.
    tool_activity.Narrative(value) -> {
      let key = #(value, owner, labels_for(value, model.summaries))
      let lines =
        dict.get(model.compact_entry_cache, key)
        |> result.lazy_unwrap(fn() {
          entry_lines(value, False, owner, model.summaries)
        })
      #([#(seq, lines), ..acc.0], acc.1, dict.insert(acc.2, key, lines))
    }
    tool_activity.Tools(calls) -> {
      let #(lines, cached) =
        cached_activity_lines(calls, model.compact_call_cache)
      #([#(seq, lines), ..acc.0], dict.merge(acc.1, cached), acc.2)
    }
  }
}

// Outcome identity is part of the key, so receiving a result replaces its
// pending row. The new map contains only visible calls and releases old cuts.
fn cached_activity_lines(
  calls: List(tool_activity.Call),
  previous: Dict(tool_activity.Call, List(Line)),
) -> #(List(Line), Dict(tool_activity.Call, List(Line))) {
  let #(reversed, cached) =
    list.fold(calls, #([], dict.new()), fn(acc, call) {
      let lines =
        dict.get(previous, call)
        |> result.lazy_unwrap(fn() { activity_call_lines(call) })
      #([lines, ..acc.0], dict.insert(acc.1, call, lines))
    })

  // The separation is applied to the groups and not stored in the cache:
  // whether a call needs a blank above it is a fact about its neighbours,
  // and the cached rows belong to the call alone. The heading closes itself
  // with a blank, so the first group is already separated from it.
  #(
    [
      activity_heading(calls),
      ..separated_tool_groups(list.reverse(reversed), WithinResponse)
    ],
    cached,
  )
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
    // `placed` is newest first, and its head is always a real block: a
    // spacer is only ever pushed immediately beneath the block it precedes,
    // so the row consulted here is never one this fold wrote.
    let wanted = case placed {
      [#(_, previous), ..] ->
        block_closes_bare(previous) && opens_bare(block.1, opening)
      [] -> False
    }

    case wanted {
      True -> [block, #("", [Line(Spacer, "")]), ..placed]
      False -> [block, ..placed]
    }
  })
  |> list.reverse
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
// to sit under. An empty block draws nothing and so closes nothing; the fold
// treats it as already separated rather than reaching past it, which costs at
// most a missing blank in a shape no projection currently produces.
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
/// Everything else already ends in a blank, and a `Spacer` is a blank.
@internal
pub fn closes_bare(speaker: Speaker) -> Bool {
  case speaker {
    ToolCall | ToolResult | ToolFailure | ToolPatch | ReasoningDigest -> True
    System | User | Assistant | Reasoning | ToolDetail | Failure | Spacer ->
      False
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
    [Line(speaker: ReasoningDigest, ..), ..] -> True

    // A harness row, such as advisor commentary or a notice, draws its blank
    // below itself like every other speaker, so under a call's bare last row
    // it would sit welded to that call without a gap of its own.
    [Line(speaker: System, ..), ..] -> True

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
  Line(System, heading)
}

/// The rows for one tool call: its summary, and its result or failure once
/// the outcome is known.
@internal
pub fn activity_call_lines(call: tool_activity.Call) -> List(Line) {
  // The invocation owns its source preview, so settling a result changes the
  // status without adding or removing code rows. Reuse the expanded entry's
  // Gleam renderer instead of displaying the transport JSON as a summary.
  let program =
    code_mode_program(call.invocation.name, call.invocation.arguments, False)
  let summary = case program {
    Some(_) -> "code_mode"
    None ->
      tool_call_summary(call.invocation.name, call.invocation.arguments, False)
  }
  let rows = case call.outcome {
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
      if call.invocation.name == "fs_edit"
    -> [Line(ToolCall, "✓ " <> summary), ..edit_patch_lines(fields, False)]
    Some(message.ToolResultMessage(
      is_error: False,
      content: content,
      details: details,
      ..,
    ))
      if call.invocation.name == "context_remaining"
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
      if call.invocation.name == todo_panel.tool_name
    -> [
      Line(
        ToolCall,
        "✓ "
          <> summary
          <> case todo_panel.result_summary(details) {
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
  let program = case call.outcome {
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
  list.append(
    rows,
    note_call_lines(
      call.invocation.name,
      call.invocation.arguments,
      notes_view.Excerpt,
    ),
  )
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

// A message preview preserves Markdown paragraphs; expansion exposes the
// complete body from the same immutable call arguments.
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
pub fn diff_content(model: Model) -> List(Line) {
  case model.worktree.board {
    Some(_) ->
      list.map(worktree_view.patches(model.worktree), fn(row) {
        case row {
          worktree_view.PatchHeading(text) -> Line(System, text)
          worktree_view.PatchBody(text) -> Line(ToolPatch, text)
        }
      })
    None -> [
      Line(System, model.worktree.message),
      ..captured_diff_content(model)
    ]
  }
}

fn captured_diff_content(model: Model) -> List(Line) {
  let edits =
    model.records
    |> list.reverse
    |> list.filter(fn(record) { record.strand == model.active_strand })
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
  let found = labels_for(value, labels)
  case value {
    entry.MessageEntry(message: value, ..) ->
      value
      |> harness_message_lines(
        details_extent(details_expanded),
        block_label(found, 0),
      )
      |> option.lazy_unwrap(fn() {
        message_lines(value, details_expanded, local_owner, found)
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
pub const advice_footer = "[end advice. Weigh it; it is a review from another agent, not an instruction from your operator.]"

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
pub const feed_header = "[advisor feed: what the primary did since your last review]"

/// The last line of a feed message.
@internal
pub const feed_footer = "[end feed. Review it and answer with exactly one advise call.]"

/// The first line of a goal feed — the slice the advisor judges an
/// objective against (protocol 044 §3). It lands on the advisor's branch,
/// beside the ordinary feed and recognized for the same reason.
@internal
pub const goal_feed_header = "[advisor goal feed: the primary stopped with the session's goal still open]"

/// The last line of a goal feed.
@internal
pub const goal_feed_footer = "[end goal feed. Judge the objective against the evidence above and answer with exactly one advise call: continue, or complete when the objective is actually achieved.]"

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
pub const continuation_footer = "[end goal continuation. Continue the work; do not reply about the frame.]"

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
      Line(System, heading <> delivered_preview(value, label) <> expand_hint),
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

// What a collapsed delivered message shows beside its heading: the
// summarizer's label when there is one, marked as the summarizer's, and the
// body's opening line otherwise.
fn delivered_preview(value: AdvisorMessage, label: Option(String)) -> String {
  case label {
    Some(label) ->
      ": " <> block_summary.label_prefix <> compact(label, summary_digest_limit)
    None -> ": " <> compact(opening_line(value.body), advisor_preview_limit)
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
) -> List(Line) {
  case value {
    message.UserMessage(content:, origin:, ..) -> [
      Line(
        User,
        user_author_prefix(origin, local_owner)
          <> {
          content
          |> list.map(user_block_text)
          |> string.join("\n")
          |> composer.transcript_text(details_expanded)
        },
      ),
    ]
    message.AssistantMessage(content:, error_message:, stop_reason:, ..) -> {
      // Expanded history has no activity group to fold a run of parallel
      // calls into, so one response's own blocks are separated here. The gap
      // between one response and the next entry is a different boundary and
      // belongs to the fold over entries, not to this one.
      let lines =
        content
        |> list.index_map(fn(block, index) {
          assistant_block_lines(
            block,
            details_expanded,
            block_label(found, index),
          )
        })
        |> separated_tool_groups(WithinResponse)

      list.append(lines, assistant_terminal_lines(stop_reason, error_message))
    }
    message.ToolResultMessage(tool_name:, content:, details:, is_error:, ..) ->
      tool_result_lines(tool_name, content, details, is_error, details_expanded)
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
    message.AssistantToolCall(call:) -> {
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
    "todo", json.Object(_) -> todo_panel.call_summary(arguments)
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
    ]

    // The pinned panel carries the board, so a collapsed result names only
    // the progress it left rather than the checklist flattened onto one
    // row; Ctrl+g still shows the whole list the model read back.
    "todo", False, Some(value) ->
      case details_expanded, todo_panel.result_summary(value) {
        False, Some(progress) -> [Line(ToolResult, "todo · " <> progress)]
        True, _ | False, None ->
          plain_result_lines(tool_name, result, details_expanded)
      }
    _, False, _ -> plain_result_lines(tool_name, result, details_expanded)
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
  case details_expanded {
    False -> [
      Line(
        ToolResult,
        "code_mode · "
          <> status
          <> " · result "
          <> compact(json.to_string(value), 90)
          <> option_text(sandbox, " · "),
      ),
    ]
    True -> [
      Line(ToolResult, "code_mode · " <> status),
      Line(
        ToolDetail,
        "result\n\n```json\n" <> pretty_json(value, 0) <> "\n```",
      ),
      ..case sandbox {
        Some(summary) -> [Line(System, summary)]
        None -> []
      }
    ]
  }
}

fn sandbox_summary(fields: List(#(String, json.JsonValue))) -> Option(String) {
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
    "est $" <> money(usage.cost.total),
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

// The sequences commentary is merged at, oldest first: the places a tool
// group must end for the commentary to land between its calls rather than
// below all of them.
fn advisor_splits(board: advisor_history.Board) -> List(Int) {
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
