//// How many rows a page draws for its turns, and which of a settled turn's
//// steps it draws at all.
////
//// A host that retains what it renders (the web view's Lustre server runtime
//// keeps every element it drew, #587) holds the rows it draws to a limit, and
//// the limit has to count what is drawn. A settled turn is one divider (`Worked
//// 52s · 80 steps`) beside its prompt and its answer, and its steps are drawn
//// only while the reader has them open. So a turn of 170 calls costs the
//// rows of its prompt, its answer and one divider, the same as a turn of
//// two, and a page can hold the turns around it. Opening a fold adds its
//// steps to the count.
////
//// The rows an open fold costs are the rows of each step's line and result.
//// The expansion a step can open to (a whole program or output, cut by the
//// host's `Expansion`) is not counted here: it is bounded separately, per row,
//// where it is built (`web_view/view/expansion.capped`), and the weighing
//// reads the turn without building it.
////
//// Everything here is a decision about rows, made over values the engine
//// already built (`turns.Piece`, `Block`) and with no clock, process or
//// host handle, so a terminal could ask the same questions. The host keeps
//// the one thing that is its own: which folds the reader has open, as a list
//// of the numbers `turns.Work.id` gives them, most recently opened first.
////
//// ## Flow
////
//// `weigh` → `fit` → `draw`
////
//// 1. `weigh` costs one turn's blocks: the rows it draws with its fold
////    closed, and what its fold would add if opened.
//// 2. `fit` takes the turns' weights, newest first, with the open folds and
////    the limit, and says how many turns the page holds, and which open fold
////    could not draw all of its steps.
//// 3. `draw` takes the pieces the host built from the held blocks and leaves
////    in each fold only what the page draws: no steps for a closed one, the
////    newest steps that fit for an open one, and how many are left out.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import session_view/protocol
import session_view/transcript_lines.{type Block}
import session_view/turns.{type Item, type Piece}

/// What one turn costs the page.
pub type Weight {
  Weight(
    /// The rows the turn draws with its fold closed: its prompt, its answer,
    /// the rows kept outside the fold, and one for the divider.
    base: Int,
    /// The fold the reader may open, or nothing when the turn folds no work.
    fold: Option(Fold),
  )
}

/// A fold the reader may open.
pub type Fold {
  Fold(
    /// The number the fold is named by (`turns.Work.id`).
    id: Int,
    /// The rows its steps draw when it is open.
    rows: Int,
  )
}

/// How much of the page's history fits its limit.
pub type Fitted {
  Fitted(
    /// How many turns, counting from the newest, the page holds. At least
    /// one when there is any turn at all.
    kept: Int,
    /// The rows those turns draw with every fold closed.
    used: Int,
    /// For each open fold whose steps did not all fit, how many rows of its
    /// newest steps it may draw. A fold absent from it draws every step.
    allowance: Dict(Int, Int),
    /// The open folds that belong to a held turn and draw steps, most
    /// recently opened first. The others are closed.
    folds: List(Int),
  )
}

/// The cost of one turn, from its blocks in order. The turn is read alone,
/// as `turns.grouped` cut it, so a call and its result in different turns
/// are not joined; the figure is a bound on retention and not a layout.
///
/// ## Examples
///
/// ```gleam
/// assert fold_budget.weigh([], []) == fold_budget.Weight(0, option.None)
/// ```
pub fn weigh(turn: List(Block), strands: List(protocol.Strand)) -> Weight {
  turns.pieces(turn, strands, turns.Settled, turns.Skip)
  |> list.fold(Weight(base: 0, fold: None), fn(weight, piece) {
    case piece {
      turns.Work(id:, items:, ..) ->
        Weight(
          base: weight.base + 1,
          fold: option.map(id, fn(id) { Fold(id:, rows: item_rows(items)) }),
        )
      turns.Plain(..)
      | turns.Prompt(..)
      | turns.Commentary(..)
      | turns.Spawned(..)
      | turns.Returned(..)
      | turns.Nudged(..)
      | turns.Peer(..)
      | turns.Sibling(..)
      | turns.Missed(..)
      | turns.Decided(..) -> Weight(..weight, base: weight.base + rows(piece))
    }
  })
}

/// What a turn costs with the folds in `open` opened.
///
/// ## Examples
///
/// ```gleam
/// assert fold_budget.cost(fold_budget.Weight(4, option.Some(fold_budget.Fold(9, 30))), [9]) == 34
/// ```
pub fn cost(weight: Weight, open: List(Int)) -> Int {
  case weight.fold {
    Some(Fold(id:, rows:)) ->
      case list.contains(open, id) {
        True -> weight.base + rows
        False -> weight.base
      }
    None -> weight.base
  }
}

/// The rows the open folds have of their own, beyond the page's limit. The
/// closed turns come first and may fill the limit, which on a long session
/// they do, and a fold that drew only what they left over would draw nothing.
/// So the folds share this reserve as well as any room the closed turns
/// leave. It is a constant, so what a page retains is bounded by its limit
/// plus this, and it is not part of which turns the page holds, so it never
/// feeds back into the cut or the paging.
pub const fold_rows = 100

/// How many of the turns, given newest first, a page of `limit` rows holds,
/// and which open folds draw how much.
///
/// Which turns are held does not depend on the folds that are open: the
/// newest turn is always held, and an older one is held while its closed rows
/// fit what is left, and the first that does not ends the page, so a smaller
/// older turn is never taken past it. Opening or closing a fold therefore
/// never changes the turns a page holds, so it never moves where the page is
/// cut, trims its history or fills it. The rows the closed turns leave over
/// are the folds' room, with `fold_rows` more. `open` lists the open folds, most recently opened
/// first, and each of those that belongs to a held turn is given its steps in
/// that order while they fit. The most recently opened fold that does not
/// fit whole draws its newest steps that do, with the allowance saying how
/// many rows, and takes the rest of the room; every fold opened before it is
/// left closed. A fold opened earlier than one that fit, and that does not
/// fit itself, is left closed too.
///
/// ## Examples
///
/// ```gleam
/// assert fold_budget.fit([fold_budget.Weight(4, option.None)], [], 150).kept == 1
/// ```
pub fn fit(weights: List(Weight), open: List(Int), limit: Int) -> Fitted {
  let held = case weights {
    [] -> Fitted(kept: 0, used: 0, allowance: dict.new(), folds: [])
    [newest, ..older] ->
      fit_older(older, limit, Fitted(1, newest.base, dict.new(), []))
  }
  let rows =
    weights
    |> list.take(held.kept)
    |> list.filter_map(fn(weight) {
      option.to_result(weight.fold, Nil)
      |> result.map(fn(fold) { #(fold.id, fold.rows) })
    })
    |> dict.from_list
  let wanted = list.filter(open, dict.has_key(rows, _))
  grant(wanted, rows, int.max(limit - held.used, 0) + fold_rows, held)
}

fn fit_older(older: List(Weight), limit: Int, fitted: Fitted) -> Fitted {
  case older {
    [] -> fitted
    [weight, ..rest] ->
      case fitted.used + weight.base <= limit {
        True ->
          fit_older(
            rest,
            limit,
            Fitted(
              ..fitted,
              kept: fitted.kept + 1,
              used: fitted.used + weight.base,
            ),
          )
        False -> fitted
      }
  }
}

// Gives the open folds, most recently opened first, the room the closed turns
// left. The first that does not fit whole takes what is left as its
// allowance, so the fold the reader just opened is the last to give way.
fn grant(
  wanted: List(Int),
  rows: Dict(Int, Int),
  room: Int,
  fitted: Fitted,
) -> Fitted {
  case wanted {
    [] -> fitted
    [id, ..rest] -> {
      let size = result.unwrap(dict.get(rows, id), 0)
      case size <= room {
        True ->
          grant(
            rest,
            rows,
            room - size,
            Fitted(..fitted, folds: list.append(fitted.folds, [id])),
          )
        False ->
          case fitted.folds {
            [] ->
              Fitted(
                ..fitted,
                allowance: dict.from_list([#(id, int.max(room, 0))]),
                folds: [id],
              )
            [_, ..] -> grant(rest, rows, room, fitted)
          }
      }
    }
  }
}

/// The pieces as the page draws them: a closed fold keeps no steps, and an
/// open one keeps its newest steps within its allowance, with `hidden`
/// saying how many earlier steps were left out. The running turn's work and
/// every other piece are returned as they were.
///
/// ## Examples
///
/// ```gleam
/// assert fold_budget.draw([], [], dict.new()) == []
/// ```
pub fn draw(
  pieces: List(Piece),
  open: List(Int),
  allowance: Dict(Int, Int),
) -> List(Piece) {
  list.map(pieces, fn(piece) {
    case piece {
      turns.Work(key:, worked:, items:, folding: turns.Folded, id:) -> {
        let #(kept, folding) = case wanted(id, open) {
          Some(id) -> {
            let #(kept, hidden) = case dict.get(allowance, id) {
              Ok(allowed) -> newest(items, allowed)
              Error(Nil) -> #(items, 0)
            }
            #(kept, turns.Unfolded(hidden:))
          }
          None -> #([], turns.Folded)
        }
        turns.Work(key:, worked:, items: kept, folding:, id:)
      }
      turns.Work(folding: turns.Unfolded(_), ..)
      | turns.Work(folding: turns.Open, ..)
      | turns.Plain(..)
      | turns.Prompt(..)
      | turns.Commentary(..)
      | turns.Spawned(..)
      | turns.Returned(..)
      | turns.Nudged(..)
      | turns.Peer(..)
      | turns.Sibling(..)
      | turns.Missed(..)
      | turns.Decided(..) -> piece
    }
  })
}

// The fold's number when the reader has it open.
fn wanted(id: Option(Int), open: List(Int)) -> Option(Int) {
  case id {
    Some(id) ->
      case list.contains(open, id) {
        True -> Some(id)
        False -> None
      }
    None -> None
  }
}

// The newest items of a fold, in order, whose rows fit `allowed`, and how
// many earlier ones were left out.
fn newest(items: List(Item), allowed: Int) -> #(List(Item), Int) {
  let #(kept, _) =
    list.fold(list.reverse(items), #([], allowed), fn(acc, item) {
      let #(kept, room) = acc
      let size = item_size(item)
      case size <= room {
        True -> #([item, ..kept], room - size)
        False -> #(kept, 0)
      }
    })
  #(kept, list.length(items) - list.length(kept))
}

fn item_rows(items: List(Item)) -> Int {
  list.fold(items, 0, fn(sum, item) { sum + item_size(item) })
}

// The rows one step of a fold draws: a call is its line and the rows of its
// result, a message the rows of its block.
fn item_size(item: Item) -> Int {
  case item {
    turns.Narrated(block:, ..) -> list.length(block.rows)
    turns.Step(detail:, ..) -> 1 + list.length(detail)
    turns.Memory(..) -> 1
  }
}

// The rows a piece draws outside a fold. A message another party wrote is its
// own lines, because that is what the page retains for it.
fn rows(piece: Piece) -> Int {
  case piece {
    turns.Plain(block:, ..) | turns.Prompt(block:, ..) ->
      list.length(block.rows)
    turns.Work(..) | turns.Spawned(..) | turns.Missed(..) | turns.Decided(..) ->
      1
    turns.Commentary(..) -> 0
    turns.Returned(report:, ..) -> 1 + lines(report)
    turns.Nudged(body:, ..) -> 1 + lines(body)
    turns.Peer(text:, ..) -> 1 + lines(text)
    turns.Sibling(text:, trailer:, ..) ->
      1
      + lines(text)
      + case trailer {
        Some(trailer) -> lines(trailer)
        None -> 0
      }
  }
}

fn lines(text: String) -> Int {
  list.length(string.split(text, "\n"))
}
