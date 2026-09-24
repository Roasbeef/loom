//// Keeps the transcript projection and its row caches current.
////
//// Rebuilding the transcript from every durable record on each event
//// would make an idle tick cost the length of the session. The projection
//// is instead rebuilt only when a revision counter moved, and it keeps
//// the rows of each record and tool call it has already built, keyed so
//// that a settled record reuses its rows. `refresh_render_cache` compares
//// the model before and after an event and rebuilds only what changed;
//// `refresh_diff_cache` does the same for the changes panel. The rows are
//// anchored to durable identities, so a scrolled-back reader keeps their
//// place when earlier history arrives.

import core/entry
import core/ids
import core/message
import etui/span
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import tui/advisor_history
import tui/layout
import tui/markdown
import tui/model.{
  type Line, type Model, Assistant, Failure, Line, Model, Reasoning,
  ReasoningDigest, Spacer, System, ToolCall, ToolDetail, ToolFailure, ToolPatch,
  ToolResult, User,
} as tui_model
import tui/render
import tui/surfaces
import tui/tool_activity
import tui/transcript_anchor
import tui/transcript_lines.{
  BetweenEntries, Projected, Transient, WithinResponse,
}

/// Terminal polling still produces idle ticks so the websocket inbox can be
/// drained, but those ticks must not compare or wrap the durable transcript.
/// Event handlers increment a scalar revision at the mutation boundary, which
/// keeps an idle cache check constant-time regardless of session length.
@internal
pub fn refresh_render_cache(before: Model, after: Model) -> Model {
  let changed =
    after.render_revision != after.rendered_revision
    || tui_model.reading_history(before) != tui_model.reading_history(after)
    || before.width != after.width
    || before.agent_rail_visible != after.agent_rail_visible
    || before.details_expanded != after.details_expanded
    || before.help_open != after.help_open
    || before.notes_open != after.notes_open
    || before.diff_view != after.diff_view
    || layout.diff_borrow_eligible(before) != layout.diff_borrow_eligible(after)
    || before.active_strand != after.active_strand
    || before.session != after.session
    || before.nudges != after.nudges
    || viewport_height_changed(
      layout.transcript_viewport_height(before),
      layout.transcript_viewport_height(after),
    )
  case changed {
    True -> {
      let width = layout.transcript_width(after)
      let same_workspace =
        before.active_strand == after.active_strand
        && before.session == after.session
      let reading_lines = case
        tui_model.reading_history(after),
        same_workspace,
        before.reading_lines,
        after.reading_lines
      {
        False, _, _, _ -> None
        True, True, Some(lines), _ -> Some(lines)
        True, _, _, Some(lines) -> Some(lines)
        True, _, _, None -> Some(transient_lines(after))
      }
      let cached =
        refresh_diff_cache(before, Model(..after, reading_lines:))
        |> refresh_record_cache(width)
      let #(rendered_rows, rendered_gutters) =
        rendered_layout_for(cached, width)
      let rendered_row_count = list.length(rendered_rows)

      // Source anchors belong to the durable row cache. Metadata and live
      // fragments invalidate the outer projection even while reading frozen
      // history, but do not change these identities. Rebuilding them there
      // re-projects and sanitizes every retained message on every update.
      // An empty anchor list also covers entering history or returning from
      // help, whose rows have no durable identities to reuse.
      let rendered_anchors = case
        after.help_open || after.notes_open || !tui_model.reading_history(after),
        record_cache_matches(after, width)
        && list.is_empty(after.pending_records)
        && before.active_strand == after.active_strand
        && before.session == after.session,
        before.rendered_anchors
      {
        True, _, _ -> []
        False, True, [_, ..] -> before.rendered_anchors
        False, _, _ -> record_anchors_for(cached, width)
      }
      let endpoint = case after.restored_workspace {
        Some(saved) -> #(saved.anchors, saved.height, saved.prefix)
        None ->
          case
            before.active_strand == after.active_strand
            && before.session == after.session
          {
            True -> #(
              before.rendered_anchors,
              layout.transcript_viewport_height(before),
              before.rendered_row_count - list.length(before.rendered_anchors),
            )
            False -> #([], layout.transcript_viewport_height(after), 0)
          }
      }
      let anchored = case tui_model.reading_history(after) {
        False -> 0
        True ->
          transcript_anchor.relocate(
            endpoint.0,
            rendered_anchors,
            after.scroll_offset,
            endpoint.1,
            endpoint.2,
            rendered_row_count - list.length(rendered_anchors),
          )
          |> option.unwrap(after.scroll_offset)
      }

      // A notebook opens at its index and selected cell heading, rather than
      // at the end of a long value. Paging then uses the ordinary copy-safe
      // row viewport; unrelated stream updates cannot reset that position.
      let anchored = case
        after.notes_open
        && {
          !before.notes_open
          || before.note_selected != after.note_selected
          || { before.note_board == None && after.note_board != None }
        }
      {
        True -> rendered_row_count
        False -> anchored
      }

      // Reading history owns the viewport through the scroll offset, and a
      // strand or session switch replaced the rows rather than extending
      // them: neither has a tail to walk toward. Otherwise the count only
      // needs clamping, since a shrunk projection must not leave the
      // viewport claiming rows that no longer exist.
      let revealed_rows = case
        tui_model.reading_history(after)
        || after.notes_open
        || before.active_strand != after.active_strand
        || before.session != after.session
      {
        True -> rendered_row_count
        False -> int.min(after.revealed_rows, rendered_row_count)
      }
      Model(
        ..cached,
        restored_workspace: None,
        rendered_revision: cached.render_revision,
        rendered_row_count:,
        rendered_rows:,
        revealed_rows:,
        rendered_anchors:,
        rendered_gutters:,
        scroll_offset: case surfaces.notes_surface(after) {
          True -> after.scroll_offset
          False ->
            bounded_scroll_offset(
              anchored,
              rendered_row_count,
              layout.transcript_viewport_height(after),
            )
        },
      )
    }
    False -> after
  }
}

// File selection and received observations invalidate the render revision even
// when the conversation is unchanged. The outer render cache must admit those
// transitions before this independent patch cache can inspect its own inputs.
// Diff rows have their own width and scroll position. Reuse the projection
// while only live fragments or composer text changed: admitted records already
// invalidate the durable cache, and pending legacy entries name an append.
// Closing the view releases its rows rather than retaining a hidden history.
fn refresh_diff_cache(before: Model, after: Model) -> Model {
  let cached = case layout.diff_shown(after) {
    False ->
      Model(
        ..after,
        diff_rows: [],
        diff_line_cache: dict.new(),
        diff_row_count: 0,
        diff_worktree_source: #(None, 0),
      )
    True -> {
      let matches =
        layout.diff_shown(before)
        && after.record_cache_valid
        && after.record_cache_strand == after.active_strand
        && list.is_empty(after.pending_records)
        && after.diff_worktree_source
        == #(after.worktree.board, after.worktree.selected)
        && layout.diff_width(before) == layout.diff_width(after)
      case matches {
        True -> after
        False -> {
          let #(rows, line_cache, _) =
            transcript_lines.diff_content(after)
            |> cached_record_lines(
              layout.diff_width(after),
              previous_diff_layout(before, after),
            )
          let count = list.length(rows)
          Model(
            ..after,
            diff_rows: rows,
            diff_line_cache: line_cache,
            diff_row_count: count,
            diff_worktree_source: #(
              after.worktree.board,
              after.worktree.selected,
            ),
            diff_scroll_offset: anchored_scroll_offset(
              after.diff_scroll_offset,
              before.diff_row_count,
              count,
            ),
          )
        }
      }
    }
  }
  Model(
    ..cached,
    diff_scroll_offset: bounded_scroll_offset(
      cached.diff_scroll_offset,
      cached.diff_row_count,
      layout.diff_patch_height(cached),
    ),
  )
}

fn previous_diff_layout(
  before: Model,
  after: Model,
) -> Dict(Line, List(span.Line)) {
  case
    layout.diff_shown(before)
    && layout.diff_width(before) == layout.diff_width(after)
  {
    True -> after.diff_line_cache
    False -> dict.new()
  }
}

/// Reports whether prompt layout changed the transcript's usable height.
@internal
pub fn viewport_height_changed(before: Int, after: Int) -> Bool {
  before != after
}

// Durable rows survive live stream fragments. Compact tool groups can change
// when a result arrives, so their projection is rebuilt from current entries.
// Unchanged presentation lines reuse their wrapped rows within the same width;
// a changed outcome has a different key and cannot retain its pending label.
// Expanded append-only history still extends the row list as one small batch.
// Both wrapped rows and their source anchors share this layout key. Pending
// records are checked separately: rows can append them, while anchors need a
// complete rebuild so repeated text still names its own durable entry.
fn record_cache_matches(model: Model, width: Int) -> Bool {
  model.record_cache_valid
  && model.record_cache_width == width
  && model.record_cache_strand == model.active_strand
  && model.record_cache_details == model.details_expanded
}

fn refresh_record_cache(model: Model, width: Int) -> Model {
  // Expanded history is append-only, so a pending record there can only add
  // rows. Compact history groups consecutive calls, and `tool_activity`
  // answers which records can rewrite a group already projected; the rest —
  // prose, a user turn, structural history — end the group with the rows it
  // already had and keep the append path.
  // A new primary record may have been committed before an advisor item
  // already in the cached window. Rebuild that mixed sequence instead of
  // prepending the primary row above every advisor row.
  let regrouped =
    {
      !model.details_expanded
      && list.any(model.pending_records, fn(record) {
        tool_activity.regroups(record.entry)
      })
    }
    || {
      model.active_strand == "main"
      && model.advisor_history.items != []
      && model.pending_records != []
    }
  let cache_matches = record_cache_matches(model, width) && !regrouped
  case cache_matches, model.pending_records {
    False, _ -> {
      let previous = case model.record_cache_width == width {
        True -> model.record_line_cache
        False -> dict.new()
      }
      let #(lines, compact_call_cache, compact_entry_cache) =
        transcript_lines.record_lines(
          model.records,
          model,
          transcript_lines.active_notices(model),
          visible_advisor_history(model),
        )
      let #(record_rows, record_line_cache, record_gutters) =
        model.transcript
        |> list.append(lines)
        |> cached_record_lines(width, previous)
      Model(
        ..model,
        record_rows:,
        record_gutters:,
        record_line_cache:,
        compact_call_cache:,
        compact_entry_cache:,
        pending_records: [],
        record_cache_valid: True,
        record_cache_width: width,
        record_cache_strand: model.active_strand,
        record_cache_details: model.details_expanded,
      )
    }
    True, [] -> model
    True, pending -> {
      let #(lines, calls, narratives) =
        transcript_lines.record_lines(
          pending,
          model,
          [],
          advisor_history.Board([], None),
        )
      let #(newest_rows, appended, newest_gutters) =
        lines
        |> separated_from_screen(model)
        |> cached_record_lines(width, model.record_line_cache)

      // Every cache here describes the current projection, and the appended
      // records have just joined it. Merging rather than replacing keeps the
      // hints for the rows already on screen, which this path never rebuilds;
      // the release of retired text belongs to the full rebuild.
      Model(
        ..model,
        record_rows: list.append(newest_rows, model.record_rows),
        record_gutters: list.append(newest_gutters, model.record_gutters),
        record_line_cache: dict.merge(model.record_line_cache, appended),
        compact_call_cache: dict.merge(model.compact_call_cache, calls),
        compact_entry_cache: dict.merge(model.compact_entry_cache, narratives),
        pending_records: [],
      )
    }
  }
}

// The entry-level separation at the one seam the fold above cannot see.
//
// `record_lines` separates the entries handed to it, but the append path
// hands it a suffix: the entry above the first new one was projected on an
// earlier pass and is no longer in reach. The row it drew is, though, and a
// drawn row answers the same question `closes_bare` answers about a speaker
// — a blank row already separates whatever follows it, a drawn one does not
// — so the seam is decided from the screen rather than from a second copy of
// the projection. Compact history applies the same rule between its items,
// so the seam is the same in both views.
//
// The live tail sits on the same seam and asks the same question of it: a
// reasoning row still streaming under a settled result must stand where its
// settled form will, or the transcript moves a row when it lands.
fn separated_from_screen(lines: List(Line), model: Model) -> List(Line) {
  let drawn = case list.first(model.record_rows) {
    Ok(row) -> span.line_width(row) > 0
    Error(Nil) -> False
  }
  let wanted = drawn && transcript_lines.opens_bare(lines, BetweenEntries)

  case wanted {
    True -> [Line(Spacer, ""), ..lines]
    False -> lines
  }
}

// Each line is rendered independently, including its speaker prefix and
// trailing blank rows. Reusing that complete result preserves wrapping and
// styling without parsing or measuring unchanged text again. The next map is
// built only from current lines; hints from a replaced cut do not become an
// ever-growing store of discarded history.
fn cached_record_lines(
  lines: List(Line),
  width: Int,
  previous: Dict(Line, List(span.Line)),
) -> #(List(span.Line), Dict(Line, List(span.Line)), List(Int)) {
  list.fold(lines, #([], dict.new(), []), fn(acc, line) {
    let #(rows, cached, gutters) = acc
    let rendered =
      dict.get(previous, line)
      |> result.lazy_unwrap(fn() { render.render_line(line, width) })
    let rendered_count = list.length(rendered)
    let line_gutters =
      list.index_map(rendered, fn(_, index) {
        copy_gutter(line, index, rendered_count)
      })
    #(
      list.append(list.reverse(rendered), rows),
      dict.insert(cached, line, rendered),
      list.append(list.reverse(line_gutters), gutters),
    )
  })
}

// Cached wrapping is reused here; identity is supplied by the durable entry,
// never inferred from text equality. Equal user messages keep distinct anchors.
fn record_anchors_for(
  model: Model,
  width: Int,
) -> List(Option(transcript_anchor.Row)) {
  let entries =
    transcript_lines.strand_entries(model.records, model.active_strand)
  let sequences = transcript_lines.entry_sequences(entries)
  let notices = transcript_lines.active_notices(model)
  let blocks = case model.details_expanded {
    True -> {
      // The compact projection owns call/result association, including reused
      // provider IDs. Borrow that association rather than guessing it again.
      // The rewritten result block deliberately carries the call block's own
      // anchor id, which is what lets a compact row relocate into expanded
      // output; `transcript_anchor.relocate` resolves the resulting tie to the
      // result block, so the worst drift is one call block's height.
      let results =
        entries
        |> tool_activity.project
        |> list.flat_map(fn(item) {
          case item {
            tool_activity.Narrative(_) -> []
            tool_activity.Tools(calls) ->
              list.filter_map(calls, fn(call) {
                use source <- result.try(option.to_result(
                  call.result_source,
                  Nil,
                ))
                Ok(#(
                  ids.entry_id_to_string(source),
                  ids.entry_id_to_string(call.source)
                    <> "/call/"
                    <> call.invocation.id,
                ))
              })
          }
        })
        |> dict.from_list

      // The mirror of the entry-level separation `record_lines` applies in
      // this mode. It runs over the flattened blocks rather than over whole
      // entries, which reaches the same boundaries and no others: within a
      // response `anchored_entry_blocks` has already placed every spacer a
      // wider rule would ask for, and a spacer's own last row is blank, so a
      // second pass can only decline.
      entries
      |> transcript_lines.splice_notices(
        notices,
        transcript_lines.entry_holds,
        fn(value) { value.seq },
      )
      |> list.map(fn(spliced) {
        case spliced {
          Transient(text, seq) -> #(seq, [#("", [Line(System, text)])])
          Projected(value) ->
            anchored_entry_blocks(value, model)
            |> list.map(fn(block) {
              #(dict.get(results, block.0) |> result.unwrap(block.0), block.1)
            })
            |> fn(blocks) { #(value.seq, blocks) }
        }
      })
      |> transcript_lines.merge_sequence_blocks(
        advisor_anchor_blocks(visible_advisor_history(model)),
      )
      |> list.flat_map(fn(group) { group.1 })
      |> transcript_lines.separated_tool_blocks(BetweenEntries)
    }

    // The mirror of the item-level separation `record_lines` applies in
    // compact history. Inside a group or a response every spacer is already
    // placed, and a spacer's own row is blank, so this pass adds only the
    // gaps between items.
    False ->
      entries
      |> tool_activity.project
      |> transcript_lines.splice_notices(
        notices,
        transcript_lines.item_holds,
        transcript_lines.item_sequence(_, sequences),
      )
      |> list.map(fn(spliced) {
        case spliced {
          Transient(text, seq) -> #(seq, [#("", [Line(System, text)])])
          Projected(tool_activity.Narrative(value)) -> #(
            value.seq,
            anchored_entry_blocks(value, model),
          )
          Projected(tool_activity.Tools(calls)) -> {
            let heading = [transcript_lines.activity_heading(calls)]
            let called =
              list.map(calls, fn(call) {
                #(
                  ids.entry_id_to_string(call.source)
                    <> "/call/"
                    <> call.invocation.id,
                  dict.get(model.compact_call_cache, call)
                    |> result.lazy_unwrap(fn() {
                      transcript_lines.activity_call_lines(call)
                    }),
                )
              })
            #(
              transcript_lines.item_sequence(
                tool_activity.Tools(calls),
                sequences,
              ),
              [
                #("", heading),
                ..transcript_lines.separated_tool_blocks(called, WithinResponse)
              ],
            )
          }
        }
      })
      |> transcript_lines.merge_sequence_blocks(
        advisor_anchor_blocks(visible_advisor_history(model)),
      )
      |> list.flat_map(fn(group) { group.1 })
      |> transcript_lines.separated_tool_blocks(BetweenEntries)
  }
  [#("", model.transcript), ..blocks]
  |> list.flat_map(fn(block) {
    block.1
    |> list.index_map(fn(line, part) { #(line, part) })
    |> list.flat_map(fn(pair) {
      let rendered =
        dict.get(model.record_line_cache, pair.0)
        |> result.lazy_unwrap(fn() { render.render_line(pair.0, width) })
      list.index_map(rendered, fn(_, wrapped) {
        case block.0 {
          "" -> None
          id -> Some(transcript_anchor.Row(id, pair.1, wrapped))
        }
      })
    })
  })
  |> list.reverse
}

// Tool calls keep the same block identity in compact and expanded views.
// Provider IDs are qualified by their durable owner, since a later response
// may legitimately reuse them. Text and reasoning use their source index.
fn anchored_entry_blocks(value: entry.Entry, model: Model) {
  let details = model.details_expanded
  let owner = transcript_lines.solo_owner(model.captured)
  let id = ids.entry_id_to_string(value.id)
  case value {
    entry.MessageEntry(
      message: message.AssistantMessage(
        content:,
        error_message:,
        stop_reason:,
        ..,
      ),
      ..,
    ) -> {
      let blocks =
        list.index_map(content, fn(block, index) {
          let key = case block {
            message.AssistantToolCall(call) -> id <> "/call/" <> call.id
            message.AssistantText(..) | message.AssistantThinking(..) ->
              id <> "/block/" <> int.to_string(index)
          }
          #(key, transcript_lines.assistant_block_lines(block, details))
        })
        |> transcript_lines.separated_tool_blocks(WithinResponse)
      let terminal =
        transcript_lines.assistant_terminal_lines(stop_reason, error_message)
      case terminal {
        [] -> blocks
        _ -> list.append(blocks, [#(id <> "/terminal", terminal)])
      }
    }
    _ -> [#(id, transcript_lines.entry_lines(value, details, owner))]
  }
}

// The live tail is parsed afresh on every call rather than memoized: a memo
// would pin one more generation of the live region than the retained-bytes
// gate on streaming has headroom for, and it would save a few parses a
// second rather than one per frame.
//
// The viewport consumes rows newest-first. Keeping that order in the cache
// makes each live frame prepend only the small transient stream projection.
fn rendered_layout_for(
  model: Model,
  width: Int,
) -> #(List(span.Line), List(Int)) {
  case model.help_open, model.notes_open {
    True, _ -> {
      let rows =
        render.help_content().lines
        |> markdown.wrap_lines(width)
        |> list.reverse
      #(rows, list.repeat(0, list.length(rows)))
    }
    False, True -> {
      // Notes render against their actual rectangle in `render_transcript`.
      #([], [])
    }
    False, False -> {
      let lines =
        option.lazy_unwrap(model.reading_lines, fn() { transient_lines(model) })
      let #(transient_rows, transient_gutters) = rendered_lines(lines, width)
      #(
        transient_rows |> list.reverse |> list.append(model.record_rows),
        transient_gutters |> list.reverse |> list.append(model.record_gutters),
      )
    }
  }
}

// Rows and copy gutters are emitted together so a live stream is parsed and
// wrapped once. The metadata is an integer per row, not another text tree.
fn rendered_lines(
  lines: List(Line),
  width: Int,
) -> #(List(span.Line), List(Int)) {
  list.fold(lines, #([], []), fn(acc, line) {
    let #(rows, gutters) = acc
    let rendered = render.render_line(line, width)
    let rendered_count = list.length(rendered)
    let line_gutters =
      list.index_map(rendered, fn(_, index) {
        copy_gutter(line, index, rendered_count)
      })
    #(list.append(rows, rendered), list.append(gutters, line_gutters))
  })
}

// Only prefixes whose ownership is explicit in `speaker_rows` are removed.
// Assistant Markdown and user blocks can contain arbitrary leading spaces;
// those begin after these fixed cells and are never inspected here.
fn copy_gutter(line: Line, index: Int, row_count: Int) -> Int {
  case line.speaker {
    Assistant | Reasoning if index > 1 -> 2
    User if index == 1 -> 1
    User if index > 1 && index < row_count - 1 -> 3
    ToolDetail -> 2
    System
    | User
    | Assistant
    | Reasoning
    | ReasoningDigest
    | ToolCall
    | ToolResult
    | ToolPatch
    | ToolFailure
    | Failure
    | Spacer -> 0
  }
}

// The live tail is a bounded, disposable observation. Scrollback retains one
// immutable projection so later fragments cannot reflow text under the reader.
fn transient_lines(model: Model) -> List(Line) {
  transcript_lines.stream_lines(
    transcript_lines.display_streams(model),
    model.active_strand,
    transcript_lines.details_extent(model.details_expanded),
  )
  |> list.append(transcript_lines.tool_tail_lines(model))
  |> list.append(transcript_lines.pending_input_lines(model))
  |> list.append(pending_nudge_lines(model))
  |> separated_from_screen(model)
}

// Pending advice is a labeled, disposable observation in the scrollable tail.
// It is never appended to durable records, and inspecting it does not deliver
// it. Keeping its complete body here prevents a long queue from taking the
// composer offscreen while still making every received line readable.
fn pending_nudge_lines(model: Model) -> List(Line) {
  case model.nudges {
    Some(board) if board.strand == model.active_strand && board.pending != [] -> {
      let heading =
        "Advisor · pending, not delivered · "
        <> int.to_string(board.total)
        <> " nudges"
      let rows =
        list.flat_map(board.pending, fn(body) {
          [Line(System, "Pending advisor nudge"), Line(ToolDetail, body)]
        })
      let omitted = case board.total > list.length(board.pending) {
        True -> [
          Line(
            System,
            "Additional nudges were not included in this observation",
          ),
        ]
        False -> []
      }
      [Line(System, heading), ..list.append(rows, omitted)]
    }
    Some(_) | None -> []
  }
}

/// Clamps scrollback to the oldest full viewport that actually exists.
@internal
pub fn bounded_scroll_offset(
  offset: Int,
  total_rows: Int,
  viewport_rows: Int,
) -> Int {
  int.min(int.max(0, offset), int.max(0, total_rows - viewport_rows))
}

/// Keeps a historical viewport anchored as rows are appended or replaced.
///
/// A zero offset follows the live tail. A non-zero offset is measured from the
/// tail, so rows arriving below the reader must move it by the same amount or
/// the text they are reading slides up the screen.
///
/// Rows leaving the bottom are a different event. Stream fragments are
/// transient: they are replaced by the settled entry, and a detail toggle or a
/// cleared generation can retire several rows at once. Following those
/// downwards walks the reader towards the live tail a fragment at a time and,
/// from a shallow offset, drops them out of scrollback entirely. The offset
/// therefore holds when the bottom shrinks; `bounded_scroll_offset` still
/// clamps it to the rows that exist when the frame is built.
///
/// ## Examples
///
/// ```gleam
/// assert tui.anchored_scroll_offset(0, 20, 23) == 0
/// assert tui.anchored_scroll_offset(8, 20, 23) == 11
/// assert tui.anchored_scroll_offset(8, 20, 17) == 8
/// ```
@internal
pub fn anchored_scroll_offset(offset: Int, before: Int, after: Int) -> Int {
  case offset == 0, after >= before {
    True, _ -> 0
    False, True -> offset + after - before
    False, False -> offset
  }
}

// Advisor-only commentary is visible beside the primary's captured entries.
// The advisor's own branch retains its ordinary transcript instead.
fn visible_advisor_history(model: Model) -> advisor_history.Board {
  case model.active_strand {
    "main" -> model.advisor_history
    _ -> advisor_history.Board([], None)
  }
}

// The row and anchor projections merge the same captured blocks. The stable
// entry and text-block identity lets reading mode stay on an advisor update
// when a later capture extends the conversation.
fn advisor_anchor_blocks(
  board: advisor_history.Board,
) -> List(#(Int, List(#(String, List(Line))))) {
  list.map2(
    transcript_lines.advisor_history_blocks(board),
    board.items,
    fn(block, item) {
      #(block.0, [
        #(
          "advisor/"
            <> item.entry_id
            <> "/block/"
            <> int.to_string(item.block_index),
          block.1,
        ),
      ])
    },
  )
}
