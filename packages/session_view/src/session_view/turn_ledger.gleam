//// A closed turn, kept as what a page draws of it and not as its records.
////
//// A host that retains what it draws (the web view's Lustre server runtime
//// keeps every element it rendered, #587) cannot also keep every record of
//// every turn it can show: one turn of 570 calls is over a thousand records,
//// and a window of records that holds them cannot hold the turns around it.
//// So when a turn closes the host keeps a summary of it, a `Sealed`: the
//// pieces the page draws for the turn with its fold closed (the prompt, the
//// divider with its figures, the answer), what the page needs to find the
//// turn's records again, and the boards the turn's records contributed. The
//// records themselves are dropped. A reader who opens the fold asks for the
//// steps, and the host reads that turn's newest ones through a scan
//// (`history_view.scan`, which walks the strand's own parent links), keeps them
//// while the fold is open and drops them when it closes.
////
//// ## When a turn is sealed
////
//// A turn is sealed once nothing more will be added to it, and the records
//// cannot always say when that is. A turn that is followed by another input is
//// over. The newest turn is over when its strand is idle, which the host reads
//// from the strand's operation, and an operation can lag the record that opens
//// its turn, or a turn can go on without a new input (a provider retry, a
//// restart). So the rule is not a promise: records that arrive after a turn
//// was sealed and belong to it have no input of their own, and the host reads
//// them as the end of a turn whose start it does not hold. It reads that turn
//// again from its last record down to its input, and `completed` seals the
//// whole of it in place of the partial summary. A page that watched the turn
//// and a page opened after it therefore draw the same divider once the turn
//// settles, and a prompt sealed alone is replaced the same way.
////
//// Everything here is a decision over values the engine already built
//// (`turns.Piece`, `Block`, `protocol.EntryRecord`), and it holds no clock,
//// process or host handle. The host owns the reads and the page's own state;
//// this module says what a stretch of records is once it is a closed turn,
//// and when a stretch read so far is enough.
////
//// ## Flow
////
//// `seal_all` → `older` / `completed` → `steps`
////
//// 1. `seal_all` closes turns the host already holds whole: groups of blocks
////    (`turns.grouped`) and the records they were drawn from. It is the one
////    place a `Sealed` is made, and the other two call it.
//// 2. `older` and `completed` take what a scan has read so far and say
////    whether it holds enough complete turns to seal: `older` for the turns
////    below the oldest the host holds, `completed` for the one turn whose
////    start the window did not reach.
//// 3. `steps` takes what a scan has read of one turn and says whether it holds
////    enough of the turn's steps to draw, which is the newest that fit the
////    page and not the whole turn.

import core/entry.{type Entry}
import core/ids
import core/message
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import session_view/changes_view
import session_view/fold_budget
import session_view/protocol
import session_view/trace_view
import session_view/transcript_lines.{type Block}
import session_view/turns

/// A record named by its identity and its sequence.
pub type Anchor {
  Anchor(
    /// The record's identity, which a read of its ancestry starts from.
    id: String,
    /// The record's durable sequence, which bounds the records a read starts
    /// from that the host already holds.
    seq: Int,
  )
}

/// One closed turn.
pub type Sealed {
  Sealed(
    /// What the page draws for the turn with its fold closed: the prompt, the
    /// divider and the answer. The divider holds no steps.
    pieces: List(turns.Piece),
    /// What the turn costs the page, with the rows its fold may add capped at
    /// what a read of the fold keeps (`fold_budget.fold_rows`).
    weight: fold_budget.Weight,
    /// The sequence of the turn's first record.
    first_seq: Int,
    /// The record before the turn's first, which a read of the turns below
    /// this one starts from; nothing when this turn is the strand's first.
    parent: Option(String),
    /// The turn's last record, which a read of its steps starts from, and the
    /// record the next turn's first has as its parent.
    end: Anchor,
    /// The edits the turn's records carry, folded once when the turn closed.
    changes: changes_view.Board,
    /// The programs the turn's records carry.
    trace: trace_view.Trace,
    /// The sequence of the newest tool result in the turn, or zero.
    latest_result: Int,
    /// About how many bytes of text the summary holds: its pieces, and the
    /// boards its records contributed. A host holds closed turns to a budget of
    /// these beside its budget of rows (`fold_budget.sealed_bytes`), since one
    /// row can be as long as a record may be.
    bytes: Int,
  )
}

/// What a scan that was asked to complete a turn found.
pub type Completion {
  /// The turn is whole: its input was reached, or it is the strand's first.
  Whole(List(Sealed))

  /// The scan ended before the turn's input, at the strand's start or a
  /// bound. What it holds is not a turn, so nothing is closed and the host draws
  /// what it has of the turn, and does not ask again.
  Partial
}

/// The steps of one turn's fold that a page holds while the fold is open.
pub type Steps {
  Steps(
    /// The newest steps, oldest first, within what a page draws of one fold.
    items: List(turns.Item),
    /// How many earlier steps the page does not hold: those the cut left out
    /// and those the read stopped before reaching.
    unread: Int,
  )
}

/// Whether a scan can be asked to read further.
pub type Source {
  /// Records below what the scan holds can still be read.
  Readable

  /// The scan reached the strand's beginning, its bound or the first
  /// sequence, so what it holds is all it will hold.
  Exhausted
}

/// Closes the turns the host holds whole.
///
/// `groups` are the blocks of each turn, oldest first, as `turns.grouped`
/// cuts them, `after` are the turns that follow them and stay open (the running
/// turn), and `records` are the records the blocks were drawn from, newest
/// first. A turn is located by its blocks' sequences: its first record is the
/// one its first block was drawn from, and its last is the record the next
/// turn's first has as its parent, or the newest record when no turn follows.
/// A turn whose records cannot be found is left out, and the host sees one
/// fewer turn than it gave.
///
/// The pieces are laid out as a settled turn's are, with the fold closed, so
/// the divider's figures and keys are what a page that held the records would
/// draw.
///
/// ## Examples
///
/// ```gleam
/// assert turn_ledger.seal_all([], [], [], []) == []
/// ```
pub fn seal_all(
  groups: List(List(Block)),
  after: List(List(Block)),
  records: List(protocol.EntryRecord),
  strands: List(protocol.Strand),
) -> List(Sealed) {
  case groups {
    [] -> []
    [_, ..] -> {
      let located =
        list.filter_map(groups, fn(group) {
          first_seq(group) |> result.map(fn(seq) { #(group, seq) })
        })
      let following = case after {
        [group, ..] -> option.from_result(first_seq(group))
        [] -> None
      }
      seal_each(located, following, places(records), records, strands, [])
    }
  }
}

/// The turns a scan found below the oldest turn the host holds, when it holds
/// `wanted` of them whole or cannot read further.
///
/// A turn is whole once its input is among the records, so the turns found
/// are the ones that open at an input; the blocks before the first input are
/// the end of a turn whose start is still unread. When nothing more can be
/// read those blocks are all there is of that turn, and they close as a turn
/// of their own (`work:window-start`), so a strand's start or a bound ends the
/// scan and not the page. Oldest first.
///
/// ## Examples
///
/// ```gleam
/// assert turn_ledger.older([], [], [], 10, turn_ledger.Readable) == Error(Nil)
/// ```
pub fn older(
  blocks: List(Block),
  records: List(protocol.EntryRecord),
  strands: List(protocol.Strand),
  wanted: Int,
  source: Source,
) -> Result(List(Sealed), Nil) {
  let #(lead, opened) = turns.grouped(blocks, strands)
  case list.length(opened) >= wanted && opened != [], source {
    True, _ -> Ok(seal_all(opened, [], records, strands))
    False, Exhausted -> Ok(seal_all(headed(lead, opened), [], records, strands))
    False, Readable -> Error(Nil)
  }
}

/// The newest turn of what a scan read, when it is whole, or `Partial` when the
/// scan cannot be read further and has not reached its input: the turn a window
/// held only the end of.
///
/// The scan starts at the last record the window held of that turn, so the
/// newest group is that turn, and it is whole once the scan has reached its
/// input. Nothing else the scan found is closed, because the turns below it
/// are the host's to read when the reader asks for them.
///
/// ## Examples
///
/// ```gleam
/// assert turn_ledger.completed([], [], [], turn_ledger.Readable) == Error(Nil)
/// ```
pub fn completed(
  blocks: List(Block),
  records: List(protocol.EntryRecord),
  strands: List(protocol.Strand),
  source: Source,
) -> Result(Completion, Nil) {
  let #(_, opened) = turns.grouped(blocks, strands)
  case list.last(opened), source {
    Ok(newest), _ -> Ok(Whole(seal_all([newest], [], records, strands)))
    Error(Nil), Exhausted -> Ok(Partial)
    Error(Nil), Readable -> Error(Nil)
  }
}

/// The steps of the newest turn of what a scan read, when it holds enough of
/// them to draw or cannot be read further.
///
/// The scan starts at the turn's last record, so the newest group of blocks is
/// the turn. It holds enough when it reached the turn's input, which makes the
/// steps whole, or when its newest steps already fill what a page draws of one
/// fold (`fold_budget.fold_rows`), since the older ones would be cut. The page
/// draws the newest steps, so the read never goes further than they need. The
/// steps are laid out with `expansion`, the host's cut of what a reader can
/// expand a row to, so no step holds uncapped text. `worked_steps` is the
/// divider's count of the turn's steps, which says how many a read that
/// stopped early did not reach.
///
/// A step is a call drawn with its result, and a result never comes before its
/// call. A read that stopped early began somewhere inside the turn's records,
/// and a model that makes its calls in one message and gets the results as many
/// records can leave the read between the two: results whose call the read did
/// not reach. A result with no call names nothing, so those are not drawn, nor
/// counted toward filling a fold, and the steps they belong to are among the
/// ones the read did not reach.
///
/// ## Examples
///
/// ```gleam
/// assert turn_ledger.steps([], [], turns.Skip, 0, turn_ledger.Readable)
///   == Error(Nil)
/// ```
pub fn steps(
  blocks: List(Block),
  strands: List(protocol.Strand),
  expansion: turns.Expansion,
  worked_steps: Int,
  source: Source,
) -> Result(Steps, Nil) {
  let #(lead, opened) = turns.grouped(blocks, strands)
  let #(turn, whole) = case list.last(opened) {
    Ok(newest) -> #(newest, True)
    Error(Nil) -> #(lead, False)
  }
  let items = case whole {
    True -> work_items(turn, strands, expansion)
    False ->
      work_items(turn, strands, expansion)
      |> list.filter(fn(item) { !is_orphan(item) })
  }
  let full = fold_budget.item_rows(items) >= fold_budget.fold_rows
  case whole, full, source {
    True, _, _ -> Ok(cut(items))
    False, True, _ | False, False, Exhausted -> Ok(early(items, worked_steps))
    False, False, Readable -> Error(Nil)
  }
}

/// Where the blocks before a window's first input end: the last record the
/// window holds of the turn whose start it did not reach, which is where a read
/// of the rest of that turn starts. Nothing when the window starts at an input.
///
/// `opened` are the turns after those blocks, so the record before the first of
/// them is the one wanted, and a window with no turn after them ends where it
/// does.
///
/// ## Examples
///
/// ```gleam
/// assert turn_ledger.lead_end([], [], []) == Error(Nil)
/// ```
pub fn lead_end(
  lead: List(Block),
  opened: List(List(Block)),
  records: List(protocol.EntryRecord),
) -> Result(Anchor, Nil) {
  case lead {
    [] -> Error(Nil)
    [_, ..] -> {
      let next = case opened {
        [group, ..] -> option.from_result(first_seq(group))
        [] -> None
      }
      ending(lead, next, places(records))
    }
  }
}

/// The divider's count of a closed turn's steps, or zero for a turn that folds
/// no work.
///
/// ## Examples
///
/// ```gleam
/// // turn_ledger.worked_steps(sealed)
/// ```
pub fn worked_steps(sealed: Sealed) -> Int {
  case work_of(sealed) {
    Some(turns.Work(worked:, ..)) -> worked.steps
    Some(_) | None -> 0
  }
}

/// The number the turn's fold is named by (`turns.Work.id`), when the turn
/// folds any work.
///
/// ## Examples
///
/// ```gleam
/// // turn_ledger.fold_id(sealed)
/// ```
pub fn fold_id(sealed: Sealed) -> Option(Int) {
  case work_of(sealed) {
    Some(turns.Work(id:, ..)) -> id
    Some(_) | None -> None
  }
}

/// The sequence of the newest tool result among `records`, newest first, or
/// zero when there is none.
///
/// ## Examples
///
/// ```gleam
/// assert turn_ledger.latest_result([]) == 0
/// ```
pub fn latest_result(records: List(protocol.EntryRecord)) -> Int {
  case records {
    [] -> 0
    [
      protocol.EntryRecord(
        entry: entry.MessageEntry(
          message: message.ToolResultMessage(..),
          seq:,
          ..,
        ),
        ..,
      ),
      ..
    ] -> seq
    [_, ..rest] -> latest_result(rest)
  }
}

// The turn's own divider, which is the one `Work` its pieces hold.
fn work_of(sealed: Sealed) -> Option(turns.Piece) {
  list.find(sealed.pieces, fn(piece) {
    case piece {
      turns.Work(..) -> True
      turns.Plain(..)
      | turns.Prompt(..)
      | turns.Spawned(..)
      | turns.Returned(..)
      | turns.Nudged(..)
      | turns.Commentary(..)
      | turns.Peer(..)
      | turns.Sibling(..)
      | turns.Missed(..)
      | turns.Decided(..) -> False
    }
  })
  |> option.from_result
}

// The blocks before the first input are the start of a turn whose input the
// scan could not reach, and are a turn of their own once it cannot go on.
fn headed(lead: List(Block), opened: List(List(Block))) -> List(List(Block)) {
  case lead {
    [] -> opened
    [_, ..] -> [lead, ..opened]
  }
}

// Where the records of a window are, by sequence and by identity, and the
// newest of them.
type Places {
  Places(
    by_seq: Dict(Int, Entry),
    by_id: Dict(ids.EntryId, Entry),
    newest: Option(Entry),
  )
}

fn places(records: List(protocol.EntryRecord)) -> Places {
  let entries = list.map(records, fn(record) { record.entry })
  Places(
    by_seq: dict.from_list(list.map(entries, fn(held) { #(held.seq, held) })),
    by_id: dict.from_list(list.map(entries, fn(held) { #(held.id, held) })),
    newest: list.first(entries) |> option.from_result,
  )
}

// The sequence a turn's first block was drawn from, which is its first record.
fn first_seq(group: List(Block)) -> Result(Int, Nil) {
  case group {
    [first, ..] -> transcript_lines.block_seq(first)
    [] -> Error(Nil)
  }
}

// Closes each located turn, oldest first. A turn knows the sequence of the
// turn after it, which is what tells it where it ends: the next one given, or
// the first of the turns that follow and stay open.
fn seal_each(
  located: List(#(List(Block), Int)),
  following: Option(Int),
  places: Places,
  records: List(protocol.EntryRecord),
  strands: List(protocol.Strand),
  done: List(Sealed),
) -> List(Sealed) {
  case located {
    [] -> list.reverse(done)
    [#(group, first), ..rest] -> {
      let next = case rest {
        [#(_, seq), ..] -> Some(seq)
        [] -> following
      }
      let done = case sealed(group, first, next, places, records, strands) {
        Ok(turn) -> [turn, ..done]
        Error(Nil) -> done
      }
      seal_each(rest, following, places, records, strands, done)
    }
  }
}

// One turn closed: its pieces with the fold closed, its place among the
// records, and what its records added to the boards.
fn sealed(
  group: List(Block),
  first: Int,
  next: Option(Int),
  places: Places,
  records: List(protocol.EntryRecord),
  strands: List(protocol.Strand),
) -> Result(Sealed, Nil) {
  use opening <- result.try(dict.get(places.by_seq, first))
  use end <- result.try(ending(group, next, places))
  let held =
    list.filter(records, fn(record) {
      record.entry.seq >= first && record.entry.seq <= end.seq
    })

  let pieces =
    turns.pieces(group, strands, turns.Settled, turns.Skip)
    |> fold_budget.draw([], dict.new())
    |> list.map(keyed_by(_, first))
  let changes = changes_view.fold(held)
  let trace = trace_view.fold(held)

  Ok(Sealed(
    pieces:,
    weight: weighed(group, strands),
    first_seq: first,
    parent: option.map(opening.parent, ids.entry_id_to_string),
    end:,
    changes:,
    trace:,
    latest_result: latest_result(held),
    bytes: bytes_of(pieces, changes, trace),
  ))
}

// The divider of a turn whose input the window did not hold is keyed by the
// window's start, which would key two such turns alike. A closed turn is keyed
// by its first record, which never moves.
fn keyed_by(piece: turns.Piece, first: Int) -> turns.Piece {
  case piece {
    turns.Work(key: "work:window-start", worked:, items:, folding:, id:) ->
      turns.Work(
        key: "work:" <> int.to_string(first) <> ".0",
        worked:,
        items:,
        folding:,
        id:,
      )
    turns.Work(..)
    | turns.Plain(..)
    | turns.Prompt(..)
    | turns.Spawned(..)
    | turns.Returned(..)
    | turns.Nudged(..)
    | turns.Commentary(..)
    | turns.Peer(..)
    | turns.Sibling(..)
    | turns.Missed(..)
    | turns.Decided(..) -> piece
  }
}

// About how many bytes of text a summary holds: the text of its pieces and of
// the boards. It is a budget's measure and not an allocation's: it counts what
// a long row can make large, and not the constant overhead of a record.
fn bytes_of(
  pieces: List(turns.Piece),
  changes: changes_view.Board,
  trace: trace_view.Trace,
) -> Int {
  let drawn = list.fold(pieces, 0, fn(sum, piece) { sum + piece_bytes(piece) })
  let edits =
    list.fold(changes.files, 0, fn(sum, file) {
      sum
      + string.byte_size(file.path)
      + list.fold(file.rows, 0, fn(rows, row) {
        rows + string.byte_size(row.text)
      })
    })
  let programs =
    list.fold(trace.programs, 0, fn(sum, program) {
      sum
      + string.byte_size(program.label)
      + option_bytes(program.excerpt)
      + option_bytes(program.detail)
      + option_bytes(program.sandbox)
      + list.fold(program.calls, 0, fn(rows, call) {
        rows + string.byte_size(call)
      })
    })
  drawn + edits + programs
}

fn option_bytes(text: Option(String)) -> Int {
  case text {
    Some(text) -> string.byte_size(text)
    None -> 0
  }
}

fn block_bytes(block: Block) -> Int {
  list.fold(block.rows, 0, fn(sum, row) {
    sum + string.byte_size({ row.1 }.text)
  })
}

fn piece_bytes(piece: turns.Piece) -> Int {
  case piece {
    turns.Plain(block:, ..) | turns.Commentary(block:, ..) -> block_bytes(block)
    turns.Prompt(block:, name:, ..) ->
      block_bytes(block) + string.byte_size(name)
    turns.Spawned(purpose:, ..) -> string.byte_size(purpose)
    turns.Returned(report:, outcome:, ..) ->
      string.byte_size(report) + string.byte_size(outcome)
    turns.Nudged(preview:, body:, ..) ->
      string.byte_size(preview) + string.byte_size(body)
    turns.Peer(text:, ..) | turns.Missed(text:, ..) -> string.byte_size(text)
    turns.Sibling(text:, trailer:, ..) ->
      string.byte_size(text) + option_bytes(trailer)
    turns.Work(..) | turns.Decided(..) -> 0
  }
}

// The turn's last record. The turn after it has that record as its first's
// parent, which is exact even when the record drew no block; when no turn
// follows it is the newest record the window holds. A turn whose end cannot
// be found that way ends at its last block.
fn ending(
  group: List(Block),
  next: Option(Int),
  places: Places,
) -> Result(Anchor, Nil) {
  let successor = case next {
    Some(seq) ->
      dict.get(places.by_seq, seq)
      |> result.try(fn(following) {
        option.to_result(following.parent, Nil)
        |> result.try(dict.get(places.by_id, _))
      })
    None -> option.to_result(places.newest, Nil)
  }
  case successor {
    Ok(last) -> Ok(anchor(last))
    Error(Nil) ->
      list.last(group)
      |> result.try(transcript_lines.block_seq)
      |> result.try(dict.get(places.by_seq, _))
      |> result.map(anchor)
  }
}

fn anchor(held: Entry) -> Anchor {
  Anchor(id: ids.entry_id_to_string(held.id), seq: held.seq)
}

// What the turn costs the page, with the rows its fold may add capped at what
// a read of the fold keeps, since that is the most the page ever holds of it.
fn weighed(
  group: List(Block),
  strands: List(protocol.Strand),
) -> fold_budget.Weight {
  let weight = fold_budget.weigh(group, strands)
  fold_budget.Weight(
    ..weight,
    fold: option.map(weight.fold, fn(fold) {
      fold_budget.Fold(..fold, rows: int.min(fold.rows, fold_budget.fold_rows))
    }),
  )
}

// The items of a turn's divider, laid out as a settled turn's are.
fn work_items(
  turn: List(Block),
  strands: List(protocol.Strand),
  expansion: turns.Expansion,
) -> List(turns.Item) {
  turns.pieces(turn, strands, turns.Settled, expansion)
  |> list.flat_map(fn(piece) {
    case piece {
      turns.Work(items:, ..) -> items
      turns.Plain(..)
      | turns.Prompt(..)
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
}

// The newest items a page draws of one fold, and how many earlier items the
// cut left out.
fn cut(items: List(turns.Item)) -> Steps {
  let #(kept, left_out) = fold_budget.newest(items, fold_budget.fold_rows)
  Steps(items: kept, unread: left_out)
}

// The steps of a read that stopped before the turn's input. The divider has
// counted every step of the turn, so what the page does not show is that count
// less the steps it does, whatever else the read held. The steps drawn and the
// steps not shown add up to the divider's.
fn early(items: List(turns.Item), worked_steps: Int) -> Steps {
  let #(kept, _) = fold_budget.newest(items, fold_budget.fold_rows)
  Steps(items: kept, unread: int.max(0, worked_steps - count_steps(kept)))
}

// Whether an item is a tool result drawn on its own, because the call it
// answers is outside what was read.
fn is_orphan(item: turns.Item) -> Bool {
  case item {
    turns.Narrated(
      block: transcript_lines.Block(
        source: transcript_lines.FromEntry(entry.MessageEntry(
          message: message.ToolResultMessage(..),
          ..,
        )),
        ..,
      ),
      ..,
    ) -> True
    turns.Narrated(..) | turns.Step(..) | turns.Memory(..) -> False
  }
}

fn count_steps(items: List(turns.Item)) -> Int {
  list.count(items, fn(item) {
    case item {
      turns.Step(..) -> True
      turns.Narrated(..) | turns.Memory(..) -> False
    }
  })
}
