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
////
//// ## Flow
////
//// `refresh_render_cache` → `refresh_diff_cache` → `refresh_record_cache`
//// → `cached_record_lines` → `rendered_layout_for` → `record_anchors_for`
//// → `rendered_lines` → `line_rows`
////
//// 1. `refresh_render_cache` compares the model before and after an event
////    and does nothing unless a revision, the width, a surface or the
////    active strand moved.
//// 2. `refresh_diff_cache` is the changes panel's own cache, kept on the
////    same before-and-after comparison and refreshed first.
//// 3. `refresh_record_cache` decides whether the cached record rows still
////    describe the records, and appends the pending ones or rebuilds.
//// 4. `cached_record_lines` wraps each record line once and keeps the
////    result keyed by the line, so a settled record reuses its rows.
//// 5. `rendered_layout_for` adds what is not a record: help, the reading
////    surface and the transient lines of the live stream.
//// 6. `record_anchors_for` pairs the rows with the durable entry each
////    belongs to, so a reader scrolled back keeps their place.
//// 7. `rendered_lines` turns the lines into rows and copy gutters together,
////    and `line_rows` sends a live answer through the live tail and
////    everything else through `render.render_line`.

import core/entry
import core/ids
import core/message
import etui/span
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import session_view/advisor_history
import session_view/composer
import session_view/image_header
import session_view/model as session_model
import session_view/notes_view
import session_view/shared_set
import session_view/tool_activity
import session_view/transcript_line.{
  type Line, type Speaker, type Stream, Assistant, Failure, ImageRow, Line,
  PeerMessage, ProgramFailure, ProgramRunning, ProgramSettled, Reasoning,
  ReasoningDigest, SentMessage, Spacer, StrandMessage, SummarizedAdvice,
  SummarizedReasoning, System, ToolCall, ToolDetail, ToolFailure, ToolGroup,
  ToolPatch, ToolResult, User,
}
import session_view/transcript_lines.{
  BetweenEntries, Projected, Transient, WithinResponse,
}
import tui/image_box
import tui/image_support
import tui/layout
import tui/live_tail
import tui/markdown
import tui/model.{type Model, Caches, Model, View} as tui_model
import tui/render
import tui/side_surfaces
import tui/transcript_anchor
import tui/view_set

/// Terminal polling still produces idle ticks so the websocket inbox can be
/// drained, but those ticks must not compare or wrap the durable transcript.
/// Event handlers increment a scalar revision at the mutation boundary, which
/// keeps an idle cache check constant-time regardless of session length.
@internal
pub fn refresh_render_cache(before: Model, after: Model) -> Model {
  let changed =
    after.shared.render_revision != after.view.rendered_revision
    || tui_model.reading_history(before) != tui_model.reading_history(after)
    || before.view.width != after.view.width
    || layout.rail_columns(before) != layout.rail_columns(after)
    || before.shared.details_expanded != after.shared.details_expanded
    || before.view.help_open != after.view.help_open
    || before.view.notes_open != after.view.notes_open
    || before.view.diff_view != after.view.diff_view
    || layout.diff_borrow_eligible(before) != layout.diff_borrow_eligible(after)
    || before.shared.active_strand != after.shared.active_strand
    || before.shared.session != after.shared.session
    || before.shared.nudges != after.shared.nudges
    || viewport_height_changed(
      layout.transcript_viewport_height(before),
      layout.transcript_viewport_height(after),
    )
  case changed {
    True -> {
      let width = layout.transcript_width(after)
      let same_workspace =
        before.shared.active_strand == after.shared.active_strand
        && before.shared.session == after.shared.session
      let reading_lines = case
        tui_model.reading_history(after),
        same_workspace,
        before.view.reading_lines,
        after.view.reading_lines
      {
        False, _, _, _ -> None
        True, True, Some(lines), _ -> Some(lines)
        True, _, _, Some(lines) -> Some(lines)
        True, _, _, None -> Some(transient_lines(after))
      }
      let cached =
        refresh_diff_cache(
          before,
          Model(..after, view: View(..after.view, reading_lines:)),
        )
        |> refresh_record_cache(width)
      let #(rendered_rows, rendered_gutters, live_tail) =
        rendered_layout_for(cached, width)
      let rendered_row_count = list.length(rendered_rows)

      // Source anchors belong to the durable row cache. Metadata and live
      // fragments invalidate the outer projection even while reading frozen
      // history, but do not change these identities. Rebuilding them there
      // re-projects and sanitizes every retained message on every update.
      // An empty anchor list also covers entering history or returning from
      // help, whose rows have no durable identities to reuse.
      let rendered_anchors = case
        after.view.help_open
        || after.view.notes_open
        || !tui_model.reading_history(after),
        record_cache_matches(after, width)
        && list.is_empty(after.shared.pending_records)
        && before.shared.active_strand == after.shared.active_strand
        && before.shared.session == after.shared.session,
        before.view.rendered_anchors
      {
        True, _, _ -> []
        False, True, [_, ..] -> before.view.rendered_anchors
        False, _, _ -> record_anchors_for(cached, width)
      }
      let endpoint = case after.view.restored_workspace {
        Some(saved) -> #(saved.anchors, saved.height, saved.prefix)
        None ->
          case
            before.shared.active_strand == after.shared.active_strand
            && before.shared.session == after.shared.session
          {
            True -> #(
              before.view.rendered_anchors,
              layout.transcript_viewport_height(before),
              before.view.rendered_row_count
                - list.length(before.view.rendered_anchors),
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
            after.view.scroll_offset,
            endpoint.1,
            endpoint.2,
            rendered_row_count - list.length(rendered_anchors),
          )
          |> option.unwrap(after.view.scroll_offset)
      }

      // A notebook opens at its index and selected cell heading, rather than
      // at the end of a long value. Paging then uses the ordinary copy-safe
      // row viewport; unrelated stream updates cannot reset that position.
      let anchored = case
        after.view.notes_open
        && {
          !before.view.notes_open
          || before.view.note_selected != after.view.note_selected
          || {
            before.shared.note_board == None && after.shared.note_board != None
          }
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
        || after.view.notes_open
        || before.shared.active_strand != after.shared.active_strand
        || before.shared.session != after.shared.session
      {
        True -> rendered_row_count
        False -> int.min(after.view.revealed_rows, rendered_row_count)
      }
      Model(
        ..cached,
        view: View(
          ..{
            cached.view
            |> view_set.rendered_revision(cached.shared.render_revision)
            |> view_set.rendered_row_count(rendered_row_count)
            |> view_set.caches(
              Caches(..cached.view.caches, rendered_rows:, live_tail:),
            )
            |> view_set.revealed_rows(revealed_rows)
            |> view_set.scroll_offset(case side_surfaces.notes_surface(after) {
              True -> after.view.scroll_offset
              False ->
                bounded_scroll_offset(
                  anchored,
                  rendered_row_count,
                  layout.transcript_viewport_height(after),
                )
            })
          },
          restored_workspace: None,
          rendered_anchors:,
          rendered_gutters:,
        ),
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
        view: View(
          ..{
            after.view
            |> view_set.caches(
              Caches(
                ..after.view.caches,
                diff_rows: [],
                diff_line_cache: dict.new(),
              ),
            )
          },
          diff_row_count: 0,
          diff_worktree_source: #(None, 0),
        ),
      )
    True -> {
      let matches =
        layout.diff_shown(before)
        && after.shared.record_cache_valid
        && after.view.record_cache_strand == after.shared.active_strand
        && list.is_empty(after.shared.pending_records)
        && after.view.diff_worktree_source
        == #(after.shared.worktree.board, after.shared.worktree.selected)
        && layout.diff_width(before) == layout.diff_width(after)
      case matches {
        True -> after
        False -> {
          let #(rows, line_cache, _) =
            transcript_lines.diff_content(session_model.presentation(
              after.shared,
            ))
            |> cached_record_lines(
              layout.diff_width(after),
              previous_diff_layout(before, after),
              after.shared.active_strand,
              after.view.image_support,
              after.view.height,
            )
          let count = list.length(rows)
          Model(
            ..after,
            view: View(
              ..{
                after.view
                |> view_set.caches(
                  Caches(
                    ..after.view.caches,
                    diff_rows: rows,
                    diff_line_cache: line_cache,
                  ),
                )
                |> view_set.diff_scroll_offset(anchored_scroll_offset(
                  after.view.diff_scroll_offset,
                  before.view.diff_row_count,
                  count,
                ))
              },
              diff_row_count: count,
              diff_worktree_source: #(
                after.shared.worktree.board,
                after.shared.worktree.selected,
              ),
            ),
          )
        }
      }
    }
  }
  Model(
    ..cached,
    view: view_set.diff_scroll_offset(
      cached.view,
      bounded_scroll_offset(
        cached.view.diff_scroll_offset,
        cached.view.diff_row_count,
        layout.diff_patch_height(cached),
      ),
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
    True -> after.view.caches.diff_line_cache
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
  model.shared.record_cache_valid
  && model.view.record_cache_width == width
  && same_image_height(model)
  && model.view.record_cache_strand == model.shared.active_strand
  && model.view.record_cache_details == model.shared.details_expanded
}

// A short terminal gives a picture fewer rows, so rows built for another
// number of picture rows are not the rows of this one. The number comes from
// the terminal's height, so typing never changes it. On a terminal that draws
// nothing no row depends on it, and a resize that changes it keeps the cache.
fn same_image_height(model: Model) -> Bool {
  case model.view.image_support {
    image_support.TextOnly(..) -> True
    image_support.KittyPlaceholders(..) | image_support.Iterm2Inline(..) ->
      model.view.record_cache_height
      == image_box.picture_rows(model.view.height)
  }
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
      !model.shared.details_expanded
      && list.any(model.shared.pending_records, fn(record) {
        tool_activity.regroups(record.entry)
      })
    }
    || {
      model.shared.active_strand == "main"
      && model.shared.advisor_history.items != []
      && model.shared.pending_records != []
    }
  let cache_matches = record_cache_matches(model, width) && !regrouped
  case cache_matches, model.shared.pending_records {
    // A reducer that emptied the transcript bumped the model's epoch, and
    // rows wrapped before it describe lines that are gone, so a rebuild
    // after it starts with no hints, as the reducer used to leave it.
    False, _ -> {
      let previous = case
        model.view.record_cache_width == width
        && same_image_height(model)
        && model.view.record_cache_strand == model.shared.active_strand
        && model.view.caches.record_cache_epoch
        == model.shared.record_cache_epoch
      {
        True -> model.view.caches.record_line_cache
        False -> dict.new()
      }
      let #(lines, compact_call_cache, compact_entry_cache) =
        record_projection(model)
      let #(record_rows, record_line_cache, record_gutters) =
        transcript_lines.separated_lines(model.shared.transcript)
        |> list.append(lines)
        |> noted_images(model)
        |> cached_record_lines(
          width,
          previous,
          model.shared.active_strand,
          model.view.image_support,
          model.view.height,
        )
      Model(
        shared: model.shared
          |> shared_set.compact_call_cache(compact_call_cache)
          |> shared_set.compact_entry_cache(compact_entry_cache)
          |> shared_set.pending_records([])
          |> shared_set.record_cache_valid(True),
        view: View(
          ..{
            model.view
            |> view_set.caches(
              Caches(
                ..model.view.caches,
                record_rows:,
                record_line_cache:,
                record_cache_epoch: model.shared.record_cache_epoch,
              ),
            )
            |> view_set.record_gutters(record_gutters)
          },
          record_cache_width: width,
          record_cache_height: image_box.picture_rows(model.view.height),
          record_cache_strand: model.shared.active_strand,
          record_cache_details: model.shared.details_expanded,
        ),
      )
    }
    True, [] -> model
    True, pending -> {
      let #(lines, calls, narratives) =
        transcript_lines.record_lines(
          pending,
          session_model.presentation(model.shared),
          [],
          advisor_history.Board([], None),
        )
      let #(newest_rows, appended, newest_gutters) =
        lines
        |> separated_from_screen(model)
        |> noted_images(model)
        |> cached_record_lines(
          width,
          model.view.caches.record_line_cache,
          model.shared.active_strand,
          model.view.image_support,
          model.view.height,
        )

      // Every cache here describes the current projection, and the appended
      // records have just joined it. Merging rather than replacing keeps the
      // hints for the rows already on screen, which this path never rebuilds;
      // the release of retired text belongs to the full rebuild.
      Model(
        shared: model.shared
          |> shared_set.compact_call_cache(dict.merge(
            model.shared.compact_call_cache,
            calls,
          ))
          |> shared_set.compact_entry_cache(dict.merge(
            model.shared.compact_entry_cache,
            narratives,
          ))
          |> shared_set.pending_records([]),
        view: model.view
          |> view_set.caches(
            Caches(
              ..model.view.caches,
              record_rows: list.append(
                newest_rows,
                model.view.caches.record_rows,
              ),
              record_line_cache: dict.merge(
                model.view.caches.record_line_cache,
                appended,
              ),
            ),
          )
          |> view_set.record_gutters(list.append(
            newest_gutters,
            model.view.record_gutters,
          )),
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
  let drawn = case list.first(model.view.caches.record_rows) {
    Ok(row) -> span.line_width(row) > 0
    Error(Nil) -> False
  }
  let wanted = drawn && transcript_lines.opens_bare(lines, BetweenEntries)

  case wanted {
    True -> [Line(Spacer, ""), ..lines]
    False -> lines
  }
}

// An image's row says why the picture is not drawn when this terminal
// knows: inside Herdr, which passes no pane graphics through, or on a
// terminal that would draw it but for the image itself (too large, or a
// format its protocol cannot carry). The note is added here, to the line,
// so the rows and the anchors built from the same lines agree on the row it
// adds.
fn noted_images(lines: List(Line), model: Model) -> List(Line) {
  let #(done, _) =
    list.fold(lines, #([], AfterOther), fn(acc, line) {
      let #(done, previous) = acc
      case image_of(line.speaker) {
        None -> #([line, ..done], AfterOther)
        Some(picture) -> {
          let noted = case image_note(model, picture) {
            Some(note) -> Line(line.speaker, line.text <> "\n" <> note)
            None -> line
          }
          #([noted, ..stacked(done, previous, model)], AfterImage)
        }
      }
    })
  list.reverse(done)
}

// What the line before the one being read was: an image or anything else.
type Previous {
  AfterImage
  AfterOther
}

// One blank row between two images in a row, so two boxes (or two
// placeholder rows with their notes) do not run together. It is added only
// on a terminal that draws images, where the images are boxes.
fn stacked(done: List(Line), previous: Previous, model: Model) -> List(Line) {
  case previous, model.view.image_support {
    AfterImage, image_support.KittyPlaceholders(..)
    | AfterImage, image_support.Iterm2Inline(..)
    -> [Line(Spacer, ""), ..done]
    AfterImage, image_support.TextOnly(..) | AfterOther, _ -> done
  }
}

// The picture an image row carries, and nothing for any other speaker. Every
// speaker is named, so a new one is a compile error here rather than
// quietly not an image.
fn image_of(speaker: Speaker) -> Option(Option(image_header.Picture)) {
  case speaker {
    ImageRow(picture) -> Some(picture)
    System
    | User
    | Assistant
    | Reasoning
    | ReasoningDigest
    | SummarizedReasoning
    | SummarizedAdvice
    | ToolGroup
    | ToolCall
    | ToolResult
    | ToolDetail
    | ToolPatch
    | ToolFailure
    | Failure
    | SentMessage
    | StrandMessage
    | PeerMessage
    | ProgramRunning
    | ProgramFailure
    | ProgramSettled
    | Spacer -> None
  }
}

// The reason a picture is not drawn, when the terminal can name it.
fn image_note(
  model: Model,
  picture: Option(image_header.Picture),
) -> Option(String) {
  case model.view.herdr_reporter, picture {
    Some(_), _ -> Some("inside Herdr: pane graphics are not passed through")
    None, Some(picture) -> image_box.refusal(model.view.image_support, picture)
    None, None -> None
  }
}

// The rows of a line. An image the terminal can draw becomes a box; every
// other line, and every image it cannot draw, is the line `render_line`
// draws.
fn line_rows_for(
  line: Line,
  width: Int,
  strand: String,
  support: image_support.Support,
  height: Int,
) -> List(span.Line) {
  case image_of(line.speaker) {
    Some(Some(picture)) ->
      case image_box.verdict(support, picture, width, height) {
        image_box.Draw(drawing) ->
          image_box.rows(
            support,
            drawing,
            string.split(line.text, "\n") |> list.first |> result.unwrap(""),
            width,
          )
        image_box.Keep | image_box.Refuse(..) ->
          render.render_line(line, width, strand)
      }
    Some(None) | None -> render.render_line(line, width, strand)
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
  strand: String,
  support: image_support.Support,
  height: Int,
) -> #(List(span.Line), Dict(Line, List(span.Line)), List(Int)) {
  list.fold(lines, #([], dict.new(), []), fn(acc, line) {
    let #(rows, cached, gutters) = acc
    let rendered =
      dict.get(previous, line)
      |> result.lazy_unwrap(fn() {
        line_rows_for(line, width, strand, support, height)
      })
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
    transcript_lines.strand_entries(
      model.shared.records,
      model.shared.active_strand,
    )
  let sequences = transcript_lines.entry_sequences(entries)
  let notices =
    transcript_lines.active_notices(session_model.presentation(model.shared))
  let blocks = case model.shared.details_expanded {
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
            anchored_entry_blocks(value, model, None)
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
    False -> {
      let found = transcript_lines.joined(entries)
      entries
      |> tool_activity.project_split(
        transcript_lines.advisor_splits(visible_advisor_history(model)),
      )
      |> transcript_lines.splice_notices(
        notices,
        transcript_lines.item_holds,
        transcript_lines.item_sequence(_, sequences),
      )
      |> list.map(fn(spliced) {
        case spliced {
          Transient(text, seq) -> #(seq, [#("", [Line(System, text)])])

          // A result that its call's row draws is no rows, as
          // `record_lines` draws it, and a response's calls are drawn from
          // the results joined to them, which can change their height.
          Projected(tool_activity.Narrative(value)) ->
            case transcript_lines.absorbed(found, value) {
              True -> #(value.seq, [#(ids.entry_id_to_string(value.id), [])])
              False -> #(
                value.seq,
                anchored_entry_blocks(value, model, Some(found)),
              )
            }
          Projected(tool_activity.Tools(calls)) -> {
            let heading = [transcript_lines.activity_heading(calls)]
            let called =
              list.map(calls, fn(call) {
                #(
                  ids.entry_id_to_string(call.source)
                    <> "/call/"
                    <> call.invocation.id,
                  dict.get(model.shared.compact_call_cache, call)
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
                ..called
                |> transcript_lines.collapse_repeats(
                  fn(block) { block.1 },
                  fn(block) { transcript_lines.repeated_call(block.1) },
                  fn(block, rows) { #(block.0, rows) },
                )
                |> transcript_lines.separated_tool_blocks(WithinResponse)
              ],
            )
          }
        }
      })
      // The same fold `record_lines` applies to a repeated provider error,
      // over the same items, so the anchors stay paired with the rows.
      |> transcript_lines.collapse_repeats(
        fn(item) { list.flat_map(item.1, fn(block) { block.1 }) },
        fn(item) {
          case item.1 {
            [#(_, rows)] -> transcript_lines.repeated_failure(rows)
            [] | [_, _, ..] -> False
          }
        },
        fn(item, rows) {
          case item.1 {
            [#(id, _)] -> #(item.0, [#(id, rows)])
            [] | [_, _, ..] -> item
          }
        },
      )
      |> transcript_lines.merge_sequence_blocks(
        advisor_anchor_blocks(visible_advisor_history(model)),
      )
      |> list.flat_map(fn(group) { group.1 })
      |> transcript_lines.separated_tool_blocks(BetweenEntries)
    }
  }
  [#("", transcript_lines.separated_lines(model.shared.transcript)), ..blocks]
  |> list.flat_map(fn(block) {
    block.1
    |> noted_images(model)
    |> list.index_map(fn(line, part) { #(line, part) })
    |> list.flat_map(fn(pair) {
      let rendered =
        dict.get(model.view.caches.record_line_cache, pair.0)
        |> result.lazy_unwrap(fn() {
          line_rows_for(
            pair.0,
            width,
            model.shared.active_strand,
            model.view.image_support,
            model.view.height,
          )
        })
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
// `joined` is the compact window's joined results (`transcript_lines.joined`),
// or `None` in expanded history, which draws each result as its own entry.
fn anchored_entry_blocks(
  value: entry.Entry,
  model: Model,
  joined: Option(transcript_lines.Joined),
) {
  let details = model.shared.details_expanded
  let owner = transcript_lines.solo_owner(model.shared.captured)
  let id = ids.entry_id_to_string(value.id)
  let found = transcript_lines.labels_for(value, model.shared.summaries)
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
          let label = list.key_find(found, index) |> option.from_result
          let lines = case joined {
            Some(joined) ->
              transcript_lines.joined_block_lines(block, label, value, joined)
            None ->
              transcript_lines.assistant_block_lines(block, details, label)
          }
          #(key, lines)
        })
        |> transcript_lines.separated_tool_blocks(WithinResponse)
      let terminal =
        transcript_lines.assistant_terminal_lines(stop_reason, error_message)
      case terminal {
        [] -> blocks
        _ -> list.append(blocks, [#(id <> "/terminal", terminal)])
      }
    }
    _ -> [
      #(
        id,
        transcript_lines.entry_lines(
          value,
          details,
          owner,
          model.shared.summaries,
        ),
      ),
    ]
  }
}

// The live answer is the one line here whose text grows on every frame, so
// it is laid out by `live_tail`, which keeps what the last frame decided and
// reprocesses only what the new text can change. Every other transient line
// is rendered afresh; they are small. Frozen reading lines are not live, so
// they are rendered afresh too and leave the live cache as it was.
//
// The viewport consumes rows newest-first. Keeping that order in the cache
// makes each live frame prepend only the small transient stream projection.
fn rendered_layout_for(
  model: Model,
  width: Int,
) -> #(List(span.Line), List(Int), live_tail.Cache) {
  case model.view.help_open, model.view.notes_open {
    True, _ -> {
      let rows =
        render.help_content().lines
        |> markdown.wrap_lines(width)
        |> list.reverse
      #(rows, list.repeat(0, list.length(rows)), model.view.caches.live_tail)
    }
    False, True -> {
      // Notes render against their actual rectangle in `render_transcript`.
      #([], [], model.view.caches.live_tail)
    }
    False, False -> {
      let #(transient_rows, transient_gutters, cache) = case
        model.view.reading_lines
      {
        Some(lines) -> {
          let #(rows, gutters, _) =
            rendered_lines(
              lines,
              width,
              [],
              live_tail.begin(live_tail.new()),
              model.shared.active_strand,
            )
          #(rows, gutters, model.view.caches.live_tail)
        }
        None -> {
          let #(rows, gutters, pass) =
            rendered_lines(
              transient_lines(model),
              width,
              live_sources(model),
              live_tail.begin(model.view.caches.live_tail),
              model.shared.active_strand,
            )
          #(rows, gutters, live_tail.finish(pass))
        }
      }
      #(
        transient_rows
          |> list.reverse
          |> list.append(model.view.caches.record_rows),
        transient_gutters
          |> list.reverse
          |> list.append(model.view.record_gutters),
        cache,
      )
    }
  }
}

// Rows and copy gutters are emitted together so a live stream is parsed and
// wrapped once. The metadata is an integer per row, not another text tree.
fn rendered_lines(
  lines: List(Line),
  width: Int,
  sources: List(#(Speaker, Stream)),
  pass: live_tail.Pass,
  strand: String,
) -> #(List(span.Line), List(Int), live_tail.Pass) {
  list.fold(lines, #([], [], pass), fn(acc, line) {
    let #(rows, gutters, pass) = acc
    let #(rendered, pass) = line_rows(line, width, sources, pass, strand)
    let rendered_count = list.length(rendered)
    let line_gutters =
      list.index_map(rendered, fn(_, index) {
        copy_gutter(line, index, rendered_count)
      })
    #(list.append(rows, rendered), list.append(gutters, line_gutters), pass)
  })
}

// A line drawn from a live stream goes through the live tail, which gives
// the rows `render_line` would. The stream is found by the speaker its line
// has, and only when exactly one stream draws with that speaker, so the line
// and its fragments cannot be mismatched. Its byte count must also be the
// line's, which a stream's text always is.
fn line_rows(
  line: Line,
  width: Int,
  sources: List(#(Speaker, Stream)),
  pass: live_tail.Pass,
  strand: String,
) -> #(List(span.Line), live_tail.Pass) {
  let bytes = string.byte_size(line.text)
  case list.filter(sources, fn(source) { source.0 == line.speaker }) {
    [#(speaker, stream)] if stream.bytes == bytes -> {
      let layout =
        live_tail.Layout(
          room: render.markdown_room(speaker, width),
          finish: fn(rows, run) {
            render.finish_markdown_rows(speaker, rows, run, strand)
          },
        )
      live_tail.rows(pass, speaker, line.text, stream.fragments, layout)
    }
    _ -> #(render.render_line(line, width, strand), pass)
  }
}

// The active strand's live streams whose lines are Markdown, each with the
// speaker `transcript_lines.stream_lines` draws it as: an answer as
// `Assistant`, and a reasoning stream as `Reasoning` when details are
// expanded. A collapsed reasoning stream is a one-row digest and a tool call
// is its name, neither of which grows into many rows.
fn live_sources(model: Model) -> List(#(Speaker, Stream)) {
  let extent = transcript_lines.details_extent(model.shared.details_expanded)
  session_model.presentation(model.shared)
  |> transcript_lines.display_streams
  |> list.filter_map(fn(stream) {
    case stream.strand == model.shared.active_strand, stream.kind, extent {
      False, _, _ -> Error(Nil)
      True, "end", _ | True, "tool_call", _ -> Error(Nil)
      True, "thinking", notes_view.Complete -> Ok(#(Reasoning, stream))
      True, "thinking", notes_view.Excerpt -> Error(Nil)
      True, _, _ -> Ok(#(Assistant, stream))
    }
  })
}

// Only prefixes whose ownership is explicit in `speaker_rows` are removed.
// Assistant Markdown and user blocks can contain arbitrary leading spaces;
// those begin after these fixed cells and are never inspected here.
fn copy_gutter(line: Line, index: Int, row_count: Int) -> Int {
  case line.speaker {
    Assistant | Reasoning if index > 0 -> 2

    // A summary's rows sit under its header behind a two-cell indent.
    SummarizedReasoning | SummarizedAdvice if index > 0 -> 2
    User if index < row_count - 1 -> 2

    // A message's bar is painted in the margin, outside these cells, so
    // the gutter counts only the indent before the heading and the body.
    SentMessage | StrandMessage if index == 0 -> 1
    SentMessage | StrandMessage if index < row_count - 1 -> 3
    PeerMessage if index > 0 && index < row_count - 1 -> 4
    ToolDetail -> 2
    System
    | ToolGroup
    | User
    | Assistant
    | Reasoning
    | ReasoningDigest
    | SummarizedReasoning
    | SummarizedAdvice
    | ToolCall
    | ToolResult
    | ToolPatch
    | ToolFailure
    | Failure
    | Spacer
    | SentMessage
    | StrandMessage
    | PeerMessage
    | ProgramRunning
    | ProgramFailure
    | ProgramSettled
    | ImageRow(..) -> 0
  }
}

// The live tail is a bounded, disposable observation. Scrollback retains one
// immutable projection so later fragments cannot reflow text under the reader.
fn transient_lines(model: Model) -> List(Line) {
  let presentation = session_model.presentation(model.shared)
  transcript_lines.stream_lines(
    transcript_lines.display_streams(presentation),
    model.shared.active_strand,
    transcript_lines.details_extent(model.shared.details_expanded),
    model.shared.summaries,
    model.shared.generation_elapsed_s,
  )
  |> list.append(transcript_lines.tool_tail_lines(presentation))
  |> list.append(transcript_lines.pending_input_lines(presentation))
  |> list.append(pending_nudge_lines(model))
  |> separated_from_screen(model)
}

// Pending advice is a labeled, disposable observation in the scrollable tail.
// It is never appended to durable records, and inspecting it does not deliver
// it. Collapsed, each nudge is one preview row under the heading, which
// already names the rows as pending advice, so a row spends no width saying it
// again. A queue that grows through a
// long run would otherwise print every body in full and push the run itself
// out of view. Detail mode prints the complete bodies, the same toggle the
// delivered nudges answer to, so every received line stays readable.
fn pending_nudge_lines(model: Model) -> List(Line) {
  case model.shared.nudges {
    Some(board)
      if board.strand == model.shared.active_strand && board.pending != []
    -> {
      let heading =
        "Advisor · pending, not delivered · "
        <> int.to_string(board.total)
        <> " nudges"
      let rows = case
        transcript_lines.details_extent(model.shared.details_expanded)
      {
        notes_view.Excerpt ->
          list.map(board.pending, fn(body) {
            Line(
              System,
              "  - "
                <> transcript_lines.advisor_body_preview(body)
                <> composer.expand_hint,
            )
          })

        notes_view.Complete ->
          list.flat_map(board.pending, fn(body) {
            [Line(System, "Pending advisor nudge"), Line(ToolDetail, body)]
          })
      }
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

/// The durable records' transcript lines, before styling, with the row
/// caches the next rebuild reuses. This is the terminal's side of the parity
/// the web view is held to: the same records give the same lines through
/// `session_view`'s `transcript.project`.
///
/// ## Examples
///
/// ```gleam
/// // let #(lines, _calls, _narratives) = projection.record_projection(model)
/// ```
@internal
pub fn record_projection(
  model: Model,
) -> #(
  List(Line),
  Dict(tool_activity.Call, List(Line)),
  Dict(#(entry.Entry, Option(message.Origin), List(#(Int, String))), List(Line)),
) {
  let presentation = session_model.presentation(model.shared)
  transcript_lines.record_lines(
    model.shared.records,
    presentation,
    transcript_lines.active_notices(presentation),
    visible_advisor_history(model),
  )
}

// Advisor-only commentary is visible beside the primary's captured entries.
// Which strands show it is session_view's rule, shared with every host.
fn visible_advisor_history(model: Model) -> advisor_history.Board {
  advisor_history.visible(
    model.shared.advisor_history,
    model.shared.active_strand,
  )
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
