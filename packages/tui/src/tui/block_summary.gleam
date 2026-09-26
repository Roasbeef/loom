//// Summarizer labels for long reasoning blocks and delivered advisor
//// messages, as this terminal holds them (protocol 050).
////
//// A reasoning block renders collapsed. For a long block the daemon's
//// summarizer writes a one- or two-sentence label, and the collapsed block
//// becomes a header row naming it as summarized, with the label drawn
//// beneath as dim secondary text of up to three rows. The full text is
//// still the durable entry and still one Ctrl+G away. The same labels
//// shorten long advice and nudges messages.
////
//// Labels reach the terminal two ways, and this module holds both.
//// **Stored labels** belong to committed blocks, keyed by entry id and the
//// block's index in the message. The daemon pushes each as it is written;
//// a terminal that attached after the push reads the ones it lacks by
//// exact key with `block_summaries`, at most `max_blocks` per read, once
//// per block per attachment. **Live labels** belong to a reasoning stream
//// the provider is still writing, keyed by the request identity a
//// `stream_delta` carries. They are never stored, and each replaces the
//// last. When the stream's response commits before its stored label
//// arrives, the live label carries over to the first long reasoning block
//// of that response so the row does not fall back to the first line and
//// then change again.
////
//// Everything here is optional presentation. A terminal attached to a
//// daemon without a summarizer, or to one too old to know the read, holds
//// no labels, and every row renders as it did before labels existed.

import core/ids
import core/json.{type JsonValue}
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import tui/stream_identity

/// The least source text, in bytes, a block needs before the daemon labels
/// it: eight times the 64-cell digest. A copy of the server's
/// `client/blocksummarybook.default_pace.floor_bytes`, because the terminal
/// links no server package; the gateway's tests pin the two together. The
/// terminal uses it to decide which blocks to ask about and which advisor
/// messages to collapse, so both sides agree on what counts as long.
pub const floor_bytes = 512

/// The most blocks one `block_summaries` read may name. A copy of the
/// protocol's bound, pinned the same way.
pub const max_blocks = 32

/// One committed block: an entry id in canonical text form and the block's
/// index in that entry's message content.
pub type Key {
  Key(entry: String, block: Int)
}

/// What a pushed label describes.
pub type Subject {
  /// A committed block, whose label is also stored.
  SettledBlock(key: Key)

  /// The reasoning stream of the provider request `generation`.
  LiveStream(strand: String, operation: String, generation: String)
}

/// Whether the attached daemon answers `block_summaries`.
pub type Reads {
  /// Unknown or yes: the terminal asks.
  Answered

  /// The daemon refused a read. An older daemon refuses every one, so the
  /// terminal stops asking for the rest of this attachment.
  Refused
}

/// Every label this attachment holds, and the reads it still owes.
pub opaque type Labels {
  Labels(
    stored: Dict(Key, String),
    live: Dict(String, Live),
    asked: Set(Key),
    wanted: List(Key),
    reads: Reads,
  )
}

// One live label and the committed entry its response will become, when
// the request identity names one.
type Live {
  Live(entry: Option(String), text: String)
}

/// An attachment's empty book: no labels, nothing asked.
///
/// ## Examples
///
/// ```gleam
/// assert block_summary.stored(block_summary.new(), block_summary.Key("e", 0))
///   == option.None
/// ```
///
pub fn new() -> Labels {
  Labels(
    stored: dict.new(),
    live: dict.new(),
    asked: set.new(),
    wanted: [],
    reads: Answered,
  )
}

/// The stored label of one committed block.
///
/// ## Examples
///
/// ```gleam
/// assert block_summary.stored(block_summary.new(), block_summary.Key("e", 0))
///   == option.None
/// ```
///
pub fn stored(labels: Labels, key: Key) -> Option(String) {
  dict.get(labels.stored, key) |> option.from_result
}

/// The newest live label of the stream `generation`.
///
/// ## Examples
///
/// ```gleam
/// assert block_summary.live(block_summary.new(), "g-1") == option.None
/// ```
///
pub fn live(labels: Labels, generation: String) -> Option(String) {
  dict.get(labels.live, generation)
  |> result.map(fn(found) { found.text })
  |> option.from_result
}

/// The live label of the stream whose response became `entry`, for the
/// interval between the entry committing and its own label arriving.
///
/// ## Examples
///
/// ```gleam
/// assert block_summary.carried(block_summary.new(), "e") == option.None
/// ```
///
pub fn carried(labels: Labels, entry: String) -> Option(String) {
  labels.live
  |> dict.values
  |> list.find(fn(found) { found.entry == Some(entry) })
  |> result.map(fn(found) { found.text })
  |> option.from_result
}

/// Records a pushed label.
///
/// ## Examples
///
/// ```gleam
/// // block_summary.receive(labels, block_summary.LiveStream("main", "op", "g"), "x")
/// ```
///
pub fn receive(labels: Labels, subject: Subject, text: String) -> Labels {
  case subject {
    SettledBlock(key:) ->
      Labels(..labels, stored: dict.insert(labels.stored, key, text))

    LiveStream(generation:, ..) -> {
      let entry =
        stream_identity.response_entry(generation)
        |> option.map(ids.entry_id_to_string)
      let found = Live(entry:, text:)
      Labels(..labels, live: dict.insert(labels.live, generation, found))
    }
  }
}

/// Records the labels one `block_summaries` read returned. A block the read
/// named and did not return has no label yet; it stays asked, so it is not
/// asked about again, and a later push still delivers its label.
///
/// ## Examples
///
/// ```gleam
/// // block_summary.receive_board(labels, [#(key, "The agent reads.")])
/// ```
///
pub fn receive_board(labels: Labels, found: List(#(Key, String))) -> Labels {
  let stored =
    list.fold(found, labels.stored, fn(stored, pair) {
      dict.insert(stored, pair.0, pair.1)
    })
  Labels(..labels, stored:)
}

/// Marks blocks this terminal would like labels for. A block already
/// labelled, already asked about or already waiting is not added again,
/// and nothing is wanted once the daemon has refused a read.
///
/// ## Examples
///
/// ```gleam
/// // block_summary.want(labels, [block_summary.Key("e", 0)])
/// ```
///
pub fn want(labels: Labels, keys: List(Key)) -> Labels {
  case labels.reads {
    Refused -> labels
    Answered -> {
      let fresh =
        list.filter(keys, fn(key) {
          !dict.has_key(labels.stored, key)
          && !set.contains(labels.asked, key)
          && !list.contains(labels.wanted, key)
        })
      Labels(..labels, wanted: list.append(labels.wanted, fresh))
    }
  }
}

/// The next read to send, at most `max_blocks` blocks, with the book that
/// counts them as asked; `None` when nothing is wanted.
///
/// ## Examples
///
/// ```gleam
/// assert block_summary.next_read(block_summary.new()) == option.None
/// ```
///
pub fn next_read(labels: Labels) -> Option(#(List(Key), Labels)) {
  case labels.wanted, labels.reads {
    [], _ | _, Refused -> None
    wanted, Answered -> {
      let batch = list.take(wanted, max_blocks)
      let asked = list.fold(batch, labels.asked, set.insert)
      Some(#(
        batch,
        Labels(..labels, asked:, wanted: list.drop(wanted, max_blocks)),
      ))
    }
  }
}

/// Records that the daemon refused a read. An older daemon refuses every
/// one, so nothing more is asked for this attachment; labels already held
/// stay, and pushed labels are still received.
///
/// ## Examples
///
/// ```gleam
/// let labels = block_summary.refused(block_summary.new())
/// assert block_summary.next_read(
///     block_summary.want(labels, [block_summary.Key("e", 0)]),
///   )
///   == option.None
/// ```
///
pub fn refused(labels: Labels) -> Labels {
  Labels(..labels, wanted: [], reads: Refused)
}

/// Drops the live labels no longer worth holding: those of streams that
/// are neither on screen nor waiting to carry over to a committed entry
/// with no stored label of its own.
///
/// ## Examples
///
/// ```gleam
/// // block_summary.retain_live(labels, fn(generation) { generation == "g-1" })
/// ```
///
pub fn retain_live(labels: Labels, keep: fn(String) -> Bool) -> Labels {
  Labels(
    ..labels,
    live: dict.filter(labels.live, fn(generation, _found) { keep(generation) }),
  )
}

/// Decodes the board a `block_summaries` read answers with. Total: every
/// row is checked, and one malformed row refuses the board rather than
/// being skipped, because a board the terminal cannot read is not evidence
/// about any block.
///
/// ## Examples
///
/// ```gleam
/// assert block_summary.decode_board(json.Object([#("summaries", json.Array([]))]))
///   == Ok([])
/// ```
///
pub fn decode_board(board: JsonValue) -> Result(List(#(Key, String)), String) {
  case board {
    json.Object(fields) ->
      case list.key_find(fields, "summaries") {
        Ok(json.Array(rows)) -> list.try_map(rows, decode_row)
        Ok(_) | Error(Nil) -> Error("block_summaries board lacks summaries")
      }
    json.Null
    | json.Bool(_)
    | json.Int(_)
    | json.Float(_)
    | json.String(_)
    | json.Array(_) -> Error("block_summaries board must be an object")
  }
}

fn decode_row(row: JsonValue) -> Result(#(Key, String), String) {
  case row {
    json.Object(fields) ->
      case
        list.key_find(fields, "entry"),
        list.key_find(fields, "block"),
        list.key_find(fields, "text")
      {
        Ok(json.String(entry)), Ok(json.Int(block)), Ok(json.String(text))
          if entry != "" && block >= 0 && text != ""
        -> Ok(#(Key(entry:, block:), text))
        _, _, _ -> Error("a block summary row is malformed")
      }
    json.Null
    | json.Bool(_)
    | json.Int(_)
    | json.Float(_)
    | json.String(_)
    | json.Array(_) -> Error("a block summary row must be an object")
  }
}
