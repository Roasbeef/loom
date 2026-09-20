//// Bounded scrollback owns presentation history, independently of live cuts.
////
//// Browsing freezes the ancestry endpoint. Older reads fill that ancestry in
//// sequence order without adopting their metadata. Retention drops the newest
//// end when paging backward, so a long session remains traversable at bounded
//// memory. Returning to live output follows the latest authoritative cut, and
//// keeps the ancestry already paged in whenever that cut still meets it.

import core/ids
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import tui/snapshot
import tui/snapshot_view

/// Whether transcript updates follow the captured leaf or a reading endpoint.
pub type Mode {
  /// New captures may extend the displayed ancestry.
  Live

  /// The reader owns the endpoint until returning to live output.
  Reading
}

/// One bounded page demand, retained while the shared read lane is busy.
pub type Request {
  /// No history read is owed.
  Quiet

  /// The next available read slot should fetch an older page.
  Wanted

  /// The exclusive upper bound identifies the outstanding historical reply.
  Pending(before_seq: Int)
}

/// Presentation retention never supplies operation or authorization metadata.
pub type State {
  State(
    /// Selected strand whose ancestry the endpoint belongs to.
    strand: String,
    /// Current presentation following behavior.
    mode: Mode,
    /// Latest known ancestor at the newer end of the reading window.
    leaf: Option(ids.EntryId),
    /// At most six hundred descriptors and sixteen MiB of loaded payloads.
    window: snapshot.Window,
    /// Exclusive upper bound for the next older sequence interval.
    before_seq: Int,
    /// One outstanding or deferred history request.
    request: Request,
  )
}

/// Creates empty scrollback before any attachment is adopted.
///
/// ## Examples
///
/// ```gleam
/// assert history_view.empty().mode == history_view.Live
/// ```
@internal
pub fn empty() -> State {
  State("", Live, None, snapshot.empty(), 0, Quiet)
}

/// Adopts live history only while the reader follows the selected leaf.
///
/// A cut holds the newest hundred records of the whole session, and the
/// retained window can be older than that: a parked strand is not refreshed
/// while another is on screen, a reconnect keeps the window it had, and a
/// reader returning from history brings the pages they read. Merging such a
/// window with a cut that no longer reaches it would leave an interval
/// nobody read inside the result, with `before_seq` beneath it where no
/// later page would fill it.
///
/// The retained window therefore joins the merge only when one of two facts
/// rules that interval out. Either the strand's leaf has not moved, so the
/// ancestry the window already holds is still the whole answer, which is
/// what keeps a finished sub-agent's history while other strands advance the
/// cut. Or the window's newest record reaches the cut's oldest sequence, so
/// no sequence lies between them. Otherwise the cut stands alone and paging
/// starts directly beneath it. The second fact assumes the new leaf descends
/// from the old one; a peer navigating the strand to a sibling branch below
/// the cut is not detected here.
///
/// ## Examples
///
/// ```gleam
/// // history_view.capture(history, cut.window, view, "main")
/// ```
@internal
pub fn capture(
  state: State,
  window: snapshot.Window,
  view: snapshot_view.View,
  strand: String,
) -> State {
  let state = case state.strand == strand {
    True -> state
    False -> empty()
  }
  case state.mode {
    Reading -> state
    Live -> {
      let leaf = result.unwrap(dict.get(view.leaves, strand), None)
      let retained = case
        leaf == state.leaf || newest(state.window) >= oldest(window) - 1
      {
        True -> state.window
        False -> snapshot.empty()
      }

      let merged = merge(retained, window) |> bounded
      State(strand, Live, leaf, merged, oldest(merged), Quiet)
    }
  }
}

/// Freezes the reading endpoint before live traffic can move it.
///
/// ## Examples
///
/// ```gleam
/// assert history_view.freeze(history_view.empty()).mode == history_view.Reading
/// ```
@internal
pub fn freeze(state: State) -> State {
  State(..state, mode: Reading)
}

/// Returns to live output without discarding the pages already read.
///
/// A transcript shorter than its viewport is always at offset zero, so any
/// downward wheel notch is a return to the tail. Emptying the window there
/// left the reader with the selected strand's share of one cut, often a few
/// rows, and the next upward notch paid for the same pages again. Whether
/// the kept window may join the next cut is `capture`'s decision.
///
/// An outstanding request is retired: `accept` refuses a reply that finds no
/// matching `Pending`, so a late page cannot attach to the live view.
///
/// ## Examples
///
/// ```gleam
/// assert history_view.resume(history_view.empty()).mode == history_view.Live
/// ```
@internal
pub fn resume(state: State) -> State {
  State(..state, mode: Live, request: Quiet)
}

/// Requests another interval only when a parent is still missing.
///
/// ## Examples
///
/// ```gleam
/// // history_view.older(history, branch.unloaded)
/// ```
@internal
pub fn older(state: State, missing: Option(String)) -> State {
  case state.request, missing, state.before_seq > 1 {
    Quiet, Some(_), True -> State(..state, mode: Reading, request: Wanted)
    _, _, _ -> state
  }
}

/// Computes a complete interval of at most one hundred sequence positions.
///
/// ## Examples
///
/// ```gleam
/// // history_view.range(history)
/// ```
@internal
pub fn range(state: State) -> Option(#(Int, Int)) {
  case state.request {
    Wanted -> Some(#(int.max(0, state.before_seq - 101), state.before_seq))
    Quiet | Pending(_) -> None
  }
}

/// Records admission after the channel has allocated the exact request.
///
/// ## Examples
///
/// ```gleam
/// // history_view.sent(history, before)
/// ```
@internal
pub fn sent(state: State, before: Int) -> State {
  State(..state, request: Pending(before))
}

/// Retires a refused or disconnected request without changing visible rows.
///
/// ## Examples
///
/// ```gleam
/// assert history_view.cancel(history_view.empty()).request == history_view.Quiet
/// ```
@internal
pub fn cancel(state: State) -> State {
  State(..state, request: Quiet)
}

/// Projects ancestry from the reader's endpoint using current metadata shape.
///
/// ## Examples
///
/// ```gleam
/// // history_view.branch(history, view)
/// ```
@internal
pub fn branch(state: State, view: snapshot_view.View) -> snapshot_view.Branch {
  snapshot_view.branch(
    snapshot_view.View(
      ..view,
      leaves: dict.insert(view.leaves, state.strand, state.leaf),
    ),
    state.window,
    state.strand,
  )
}

/// Adds an exact older reply while preserving a reachable retained endpoint.
///
/// Only an outstanding matching range can extend this view. A late reply after
/// navigation or returning to live output cannot attach to the new selection.
///
/// ## Examples
///
/// ```gleam
/// // history_view.accept(history, page, before, after, view)
/// ```
@internal
pub fn accept(
  state: State,
  page: snapshot.Window,
  before: Int,
  after: Int,
  view: snapshot_view.View,
) -> State {
  case state.request == Pending(before) {
    False -> state
    True -> {
      let combined = State(..state, window: merge(state.window, page))
      let projected = branch(combined, view)
      let ancestors = projected.records
      let known =
        dict.from_list(
          list.map(ancestors, fn(record) { #(record.entry.seq, Nil) }),
        )

      // Other strands can consume thousands of global sequences between two
      // parents. Retain only proved ancestry so those intervening pages cannot
      // evict the endpoint before its missing parent has been reached.
      let related =
        list.filter(combined.window.items, fn(item) {
          dict.has_key(known, snapshot.sequence(item))
          || case item {
            snapshot.Unloaded(id, ..) -> projected.unloaded == Some(id)
            snapshot.Loaded(..) -> False
          }
        })
      let retained =
        snapshot.Window(
          list.reverse(related),
          list.fold(related, 0, fn(sum, item) { sum + bytes(item) }),
          None,
        )
        |> bounded
      let window =
        snapshot.Window(..retained, items: list.reverse(retained.items))
      let kept =
        dict.from_list(
          list.map(window.items, fn(item) { #(snapshot.sequence(item), Nil) }),
        )
      let leaf =
        ancestors
        |> list.find(fn(record) { dict.has_key(kept, record.entry.seq) })
        |> result.map(fn(record) { Some(record.entry.id) })
        |> result.unwrap(state.leaf)

      // A transfer may retain only its newest suffix. Revisit the evicted
      // prefix rather than skipping entries that never reached this view.
      let next_before = case page.evicted_through {
        None -> after + 1
        Some(seq) -> seq + 1
      }
      State(..state, window:, leaf:, before_seq: next_before, request: Quiet)
    }
  }
}

fn merge(first: snapshot.Window, second: snapshot.Window) {
  let by_seq =
    list.append(first.items, second.items)
    |> list.map(fn(item) { #(snapshot.sequence(item), item) })
    |> dict.from_list
  let items =
    dict.values(by_seq)
    |> list.sort(fn(a, b) {
      int.compare(snapshot.sequence(b), snapshot.sequence(a))
    })
  snapshot.Window(
    items,
    list.fold(items, 0, fn(sum, item) { sum + bytes(item) }),
    None,
  )
}

// Items are held newest first, by `merge` and by `accept` alike.
fn newest(window: snapshot.Window) {
  case window.items {
    [item, ..] -> snapshot.sequence(item)
    [] -> 0
  }
}

fn oldest(window: snapshot.Window) {
  case list.last(window.items) {
    Ok(item) -> snapshot.sequence(item)
    Error(Nil) -> 0
  }
}

// Retain from the requested end in one pass. Oversized payloads remain the
// decoder's explicit Unloaded descriptors rather than allocating a second copy.
fn bounded(window: snapshot.Window) {
  let #(items, size, _) =
    list.fold(window.items, #([], 0, 0), fn(acc, item) {
      let #(items, size, count) = acc
      case count < 600 && size + bytes(item) <= 16 * 1024 * 1024 {
        True -> #([item, ..items], size + bytes(item), count + 1)
        False -> #(items, size, 600)
      }
    })
  snapshot.Window(list.reverse(items), size, None)
}

fn bytes(item) {
  case item {
    snapshot.Loaded(_, size) -> size
    snapshot.Unloaded(..) -> 0
  }
}
