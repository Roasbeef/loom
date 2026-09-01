//// The pure branch-scan pipeline shared by every backend.
////
//// A `BranchScan` (pi §2.5) is: take the path from `start` toward the
//// root, order it, stop inclusively at the first stop match, filter by
//// kind/custom type, apply the exclusive cursor, then apply the limit.
//// Backends differ only in how they produce the ordered path — Memory
//// walks parent pointers, SQLite streams branch-index segments — so the
//// truncate/filter/page steps live here once, as an incremental state
//// machine the SQLite backend can feed page by page and abandon early.

import core/entry.{
  type Entry, BranchSummaryEntry, CompactionEntry, CustomEntry, MessageEntry,
}
import core/ids
import gleam/list
import gleam/option.{type Option, None, Some}
import storage/storage.{
  type BranchScan, type ScanOrder, NewestFirst, OldestFirst,
}

/// The incremental refinement state: the query, the rows emitted so far
/// (newest emitted last is *not* guaranteed — `taken` is reversed), and
/// whether the scan is finished.
///
/// Constructor invariants: `taken` holds emitted entries in reverse
/// emission order; `count` is its length; once `done` is `True` no further
/// `step` changes the state.
pub type Refine {
  Refine(q: BranchScan, taken: List(Entry), count: Int, done: Bool)
}

/// A fresh refinement state for one query.
///
/// ## Examples
///
/// ```gleam
/// let state = branch.new(q)
/// assert state.done == False
/// ```
///
pub fn new(q: BranchScan) -> Refine {
  Refine(q:, taken: [], count: 0, done: is_zero_limit(q.limit))
}

// A limit of zero (or below) emits nothing; treat it as immediately done
// rather than a special case in every step.
fn is_zero_limit(limit: Option(Int)) -> Bool {
  case limit {
    Some(n) if n <= 0 -> True
    _ -> False
  }
}

/// Feeds the next path entry, which must arrive in the query's scan order
/// (descending seq for `NewestFirst`, ascending for `OldestFirst`).
/// Applies, in pipeline order: the inclusive stop, the kind/custom-type
/// filter, the exclusive cursor, and the limit.
///
/// ## Examples
///
/// ```gleam
/// let state = branch.step(branch.new(q), entry)
/// ```
///
pub fn step(state: Refine, entry: Entry) -> Refine {
  case state.done {
    True -> state
    False -> {
      let q = state.q

      // The stop truncates the ordered path *before* filter and cursor:
      // a stop entry still ends the scan even when the filter or cursor
      // would drop it from the results.
      let stops = matches_stop(q, entry)
      let emit =
        matches_filter(q, entry) && matches_cursor(q.order, q.cursor, entry.seq)
      let state = case emit {
        True ->
          Refine(..state, taken: [entry, ..state.taken], count: state.count + 1)
        False -> state
      }
      let at_limit = case q.limit {
        Some(limit) -> state.count >= limit
        None -> False
      }
      Refine(..state, done: stops || at_limit)
    }
  }
}

/// Folds a fully ordered path through the pipeline. Convenience for
/// backends that materialize the path (Memory) — equivalent to `step`ping
/// every entry.
///
/// ## Examples
///
/// ```gleam
/// let rows = branch.refine_all(q, ordered_path)
/// ```
///
pub fn refine_all(q: BranchScan, path: List(Entry)) -> List(Entry) {
  list.fold(over: path, from: new(q), with: step)
  |> results
}

/// The emitted rows of a refinement state, in emission order.
///
/// ## Examples
///
/// ```gleam
/// let rows = branch.results(state)
/// ```
///
pub fn results(state: Refine) -> List(Entry) {
  list.reverse(state.taken)
}

fn matches_stop(q: BranchScan, entry: Entry) -> Bool {
  let kind_stops = case q.stop_at_kind {
    Some(kind) -> storage.kind_of(entry) == kind
    None -> False
  }
  let id_stops = case q.stop_at_id {
    Some(id) -> entry.id == id
    None -> False
  }
  kind_stops || id_stops
}

fn matches_filter(q: BranchScan, entry: Entry) -> Bool {
  let kind_ok = case q.kind {
    Some(kind) -> storage.kind_of(entry) == kind
    None -> True
  }
  let custom_ok = case q.custom_type {
    Some(name) ->
      case entry {
        CustomEntry(custom_type:, ..) -> custom_type == name
        MessageEntry(..) | CompactionEntry(..) | BranchSummaryEntry(..) -> False
      }
    None -> True
  }
  kind_ok && custom_ok
}

fn matches_cursor(
  order: ScanOrder,
  cursor: Option(ids.Seq),
  seq: ids.Seq,
) -> Bool {
  case cursor, order {
    None, _ -> True
    Some(bound), NewestFirst -> seq < bound
    Some(bound), OldestFirst -> seq > bound
  }
}
