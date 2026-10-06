//// Summarizer labels on the reasoning rows of a lane's pieces, applied when
//// the lane is drawn.
////
//// A settled reasoning block is one `ReasoningDigest` row: its first line,
//// built by `turns` from the entry's text alone. The daemon's summarizer
//// writes a one- or two-sentence label for each long block, and the label is
//// not part of the entry, so it reaches a host after the row was built and
//// after the turn holding the row may have been sealed (`turn_ledger`). A
//// label frozen into a row when the row was built would therefore be missing
//// from every turn that closed before its label arrived, and from the steps a
//// reader opened a fold to read.
////
//// This module keeps the labels out of the built rows. The rows stay what the
//// records made them, and `apply` reads the host's label book
//// (`block_summary.Labels`) over the finished pieces each time the lane is
//// drawn, replacing the digest of a labelled block with a
//// `SummarizedReasoning` row. A sealed turn, an open fold, a window turn and
//// a page of older history are all pieces, so one pass covers every place a
//// reasoning row can be drawn, and a label that arrives late shows on the
//// next draw with no turn re-sealed.
////
//// A block's label is the stored one when the book holds it, and otherwise
//// the live label of the stream that wrote the entry, carried over to the
//// entry's first long reasoning block (`transcript_lines.labels_for`), so a
//// block that showed a label while it streamed keeps it when it settles.
////
//// `keys` is the other half: the labels the pieces would show and the book
//// lacks, which a host marks wanted (`block_summary.want`) so the lane reads
//// them by exact key, once per block per attachment.
////
//// ## Flow
////
//// `apply` → `relabelled` → `swapped`; `keys` → `assistant_keys`
////
//// 1. `apply` visits the pieces that carry blocks: a plain block, and the
////    narrated blocks inside a turn's work.
//// 2. `relabelled` asks which of an assistant entry's content blocks have a
////    label, and lines each up with the row the entry drew for it.
//// 3. `swapped` replaces one digest row with the summarized form.
//// 4. `keys` collects the long reasoning blocks of the same pieces.

import core/entry
import core/ids
import core/message
import gleam/list
import gleam/option.{type Option, None, Some}
import session_view/block_summary.{type Key, type Labels}
import session_view/transcript_line.{type Line}
import session_view/transcript_lines.{type Block, Block, FromEntry}
import session_view/turns.{type Item, type Piece}

/// The pieces with each labelled reasoning block drawn as a summarized row.
///
/// A row whose block has no label is untouched, and so is every piece that
/// carries no entry's rows. The row's key and the full text kept for it
/// (`turns.Plain.thoughts`) are unchanged, so a host opens the same text
/// behind the same row.
///
/// ## Examples
///
/// ```gleam
/// assert turn_labels.apply([], block_summary.new()) == []
/// ```
pub fn apply(pieces: List(Piece), labels: Labels) -> List(Piece) {
  list.map(pieces, fn(piece) {
    case piece {
      turns.Plain(block:, thoughts:, took:) ->
        turns.Plain(block: relabelled(block, labels), thoughts:, took:)

      turns.Work(key:, worked:, items:, folding:, id:) ->
        turns.Work(
          key:,
          worked:,
          items: list.map(items, labelled_item(_, labels)),
          folding:,
          id:,
        )

      turns.Prompt(..)
      | turns.Spawned(..)
      | turns.Returned(..)
      | turns.Nudged(..)
      | turns.Commentary(..)
      | turns.Peer(..)
      | turns.Sibling(..)
      | turns.Missed(..)
      | turns.Decided(..) -> piece
    }
  })
}

/// The long reasoning blocks of the pieces' assistant entries, by entry and
/// content index: the blocks `apply` could draw a label on.
///
/// ## Examples
///
/// ```gleam
/// assert turn_labels.keys([]) == []
/// ```
pub fn keys(pieces: List(Piece)) -> List(Key) {
  pieces
  |> list.flat_map(fn(piece) {
    case piece {
      turns.Plain(block:, ..) -> [block]
      turns.Work(items:, ..) ->
        list.filter_map(items, fn(item) {
          case item {
            turns.Narrated(block:, ..) -> Ok(block)
            turns.Memory(..) | turns.Step(..) -> Error(Nil)
          }
        })
      turns.Prompt(..)
      | turns.Spawned(..)
      | turns.Returned(..)
      | turns.Nudged(..)
      | turns.Commentary(..)
      | turns.Peer(..)
      | turns.Sibling(..)
      | turns.Missed(..)
      | turns.Decided(..) -> []
    }
  })
  |> list.flat_map(assistant_keys)
}

fn labelled_item(item: Item, labels: Labels) -> Item {
  case item {
    turns.Narrated(block:, thoughts:, took:) ->
      turns.Narrated(block: relabelled(block, labels), thoughts:, took:)
    turns.Memory(..) | turns.Step(..) -> item
  }
}

// A response entry's long reasoning blocks, or none for any other source.
fn assistant_keys(block: Block) -> List(Key) {
  case block.source {
    FromEntry(
      value: entry.MessageEntry(message: message.AssistantMessage(..), ..) as value,
    ) -> {
      let id = ids.entry_id_to_string(value.id)
      list.map(transcript_lines.summarizable_blocks(value), fn(index) {
        block_summary.Key(entry: id, block: index)
      })
    }
    FromEntry(..) -> []
    transcript_lines.FromTools(..)
    | transcript_lines.FromNotice
    | transcript_lines.FromAdvisor
    | transcript_lines.FromSpacer -> []
  }
}

// The block's rows with each labelled reasoning row replaced. A response draws
// one row for each of its content blocks that is not a call, in order
// (`turns.prose`), so the entry's labels, keyed by content index, are lined up
// with the rows by walking the two together; rows after the last content
// block, the stop's own, have no content block and are left as they are.
fn relabelled(block: Block, labels: Labels) -> Block {
  case block.source {
    FromEntry(
      value: entry.MessageEntry(
        message: message.AssistantMessage(content:, ..),
        ..,
      ) as value,
    ) ->
      case transcript_lines.labels_for(value, labels) {
        [] -> block
        found -> {
          let slots = drawn_slots(content)
          Block(..block, rows: walked(block.rows, slots, found))
        }
      }
    FromEntry(..)
    | transcript_lines.FromTools(..)
    | transcript_lines.FromNotice
    | transcript_lines.FromAdvisor
    | transcript_lines.FromSpacer -> block
  }
}

// The content index each drawn row stands for, in row order: every block of
// the response that is not a tool call.
fn drawn_slots(content: List(message.AssistantBlock)) -> List(Int) {
  content
  |> list.index_map(fn(part, index) { #(part, index) })
  |> list.filter_map(fn(pair) {
    case pair.0 {
      message.AssistantToolCall(..) -> Error(Nil)
      message.AssistantText(..) | message.AssistantThinking(..) -> Ok(pair.1)
    }
  })
}

fn walked(
  rows: List(#(String, Line)),
  slots: List(Int),
  found: List(#(Int, String)),
) -> List(#(String, Line)) {
  case rows, slots {
    [#(key, line), ..rest], [slot, ..others] -> [
      #(key, swapped(line, labelled_at(found, slot))),
      ..walked(rest, others, found)
    ]
    [], _ | _, [] -> rows
  }
}

fn labelled_at(found: List(#(Int, String)), slot: Int) -> Option(String) {
  case list.key_find(found, slot) {
    Ok(label) -> Some(label)
    Error(Nil) -> None
  }
}

// Only a digest is replaced. A full-text row (an expanded host) or a row some
// other part drew keeps its words, so a slot that does not line up is harmless.
fn swapped(line: Line, label: Option(String)) -> Line {
  case label, line.speaker == transcript_line.ReasoningDigest {
    Some(label), True ->
      transcript_lines.summarized_reasoning_line(
        transcript_lines.expand_hint,
        label,
      )
    Some(_), False | None, _ -> line
  }
}
