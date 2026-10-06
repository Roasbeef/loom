//// Bounded scrollback owns presentation history, independently of live cuts.
////
//// Browsing freezes the ancestry endpoint. Older reads fill that ancestry in
//// sequence order without adopting their metadata. Retention drops the newest
//// end when paging backward, so a long session remains traversable at bounded
//// memory. Returning to live output follows the latest authoritative cut, and
//// keeps the ancestry already paged in whenever that cut still meets it.
////
//// A host that draws summaries instead of records (the web view) also reads
//// a second, transient stretch of ancestry beside the window: a scan. It
//// starts at one record and reads downward through the same bounded
//// intervals, holds what it found until the host has taken what it wanted
//// from it, and then is dropped. The window is never touched by a scan, so a
//// read that wanders through a turn of thousands of records cannot evict the
//// live end the page is drawing.

import core/ids
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import session_view/snapshot
import session_view/snapshot_view

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

/// A transient read of ancestry beside the window, for a host that wants to
/// look at a stretch of history without keeping it.
///
/// A scan has its own window, its own endpoint and its own demand, and shares
/// the one read lane with the window. It is bounded more generously than the
/// window (4,096 records and 32 MiB), because its host reads a whole turn
/// through it and then drops everything but a summary. A scan that reaches its
/// bound is no longer readable, and one that a page would take past it keeps
/// its newest end, which is the end its host needs.
pub type Scan {
  /// No scan is under way.
  Unscanned

  /// A scan is under way.
  Scanning(
    /// The newest record the scan reads, which its ancestry is walked from.
    leaf: Option(ids.EntryId),
    /// What the scan has read, newest first.
    window: snapshot.Window,
    /// Exclusive upper bound for the next older sequence interval.
    before_seq: Int,
    /// The scan's own outstanding or deferred read.
    request: Request,
  )

  /// A read of the scan was refused, or the lane was lost, so the scan was
  /// dropped. The host takes the fact once and ends the scan.
  Abandoned
}

// How many records, and how many payload bytes, a scan holds at most. A scan
// that reaches either stops being readable (`scan_readable`) and, if a page
// would take it past them, keeps the newest end and drops the oldest, so what it
// holds is still the stretch that ends at its leaf.
const scan_records = 4096

const scan_bytes = 33_554_432

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
    /// The transient read beside the window.
    scan: Scan,
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
  State("", Live, None, snapshot.empty(), 0, Quiet, Unscanned)
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
      let joins =
        leaf == state.leaf || newest(state.window) >= oldest(window) - 1
      let retained = case joins {
        True -> state.window
        False -> snapshot.empty()
      }
      let whole = merge(retained, window)
      let merged = bounded(whole, 600, 16 * 1024 * 1024)

      // A page read below the window can hold no record of this strand's
      // ancestry, when other strands wrote every sequence in it. `accept`
      // then lowers `before_seq` past that interval while the window's
      // oldest record stays where it was. When the kept window joins this
      // capture and the bound evicted nothing, that progress still holds,
      // so the lower of the two is kept; otherwise the next read would ask
      // for the same empty interval again. A window that did not join, or
      // lost its oldest records to the bound, starts again beneath what it
      // holds.
      let before_seq = case
        joins && state.before_seq > 0 && oldest(merged) == oldest(whole)
      {
        True -> int.min(state.before_seq, oldest(merged))
        False -> oldest(merged)
      }
      State(strand, Live, leaf, merged, before_seq, Quiet, state.scan)
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
/// The window's demand is served before the scan's, and only one is answered
/// at a time, since the lane has one read slot.
///
/// ## Examples
///
/// ```gleam
/// // history_view.range(history)
/// ```
@internal
pub fn range(state: State) -> Option(#(Int, Int)) {
  case state.request, state.scan {
    Wanted, _ -> Some(interval(state.before_seq))
    Quiet, Scanning(request: Wanted, before_seq:, ..)
    | Pending(_), Scanning(request: Wanted, before_seq:, ..)
    -> Some(interval(before_seq))
    Quiet, _ | Pending(_), _ -> None
  }
}

fn interval(before_seq: Int) -> #(Int, Int) {
  #(int.max(0, before_seq - 101), before_seq)
}

/// Records admission after the channel has allocated the exact request.
///
/// It marks the demand `range` answered: the window's when it has one, the
/// scan's otherwise.
///
/// ## Examples
///
/// ```gleam
/// // history_view.sent(history, before)
/// ```
@internal
pub fn sent(state: State, before: Int) -> State {
  case state.request, state.scan {
    Wanted, _ -> State(..state, request: Pending(before))
    _, Scanning(..) -> State(..state, scan: pending(state.scan, before))
    _, Unscanned | _, Abandoned -> State(..state, request: Pending(before))
  }
}

fn pending(scan: Scan, before: Int) -> Scan {
  case scan {
    Scanning(leaf:, window:, before_seq:, ..) ->
      Scanning(leaf:, window:, before_seq:, request: Pending(before))
    Unscanned | Abandoned -> scan
  }
}

/// Retires a refused or disconnected request without changing visible rows.
///
/// A scan whose read is retired is abandoned: its host is told once
/// (`Abandoned`) and does not ask again until the reader does.
///
/// ## Examples
///
/// ```gleam
/// assert history_view.cancel(history_view.empty()).request == history_view.Quiet
/// ```
@internal
pub fn cancel(state: State) -> State {
  State(..state, request: Quiet, scan: case state.scan {
    Scanning(..) -> Abandoned
    Unscanned | Abandoned -> state.scan
  })
}

/// Starts a scan that reads the strand's ancestry downward from the record
/// `leaf`, whose sequence is below `before_seq`, beginning with what the host
/// already holds.
///
/// `known` is a window the host has (the capture's), and what the scan starts
/// from is the part of it, together with the history window's own records, that
/// is the leaf's ancestry below `before_seq`. A turn the host closed a moment
/// ago is still in the newest records the daemon sent, so most scans of recent
/// turns need no read at all, and a scan of older ones starts below what is
/// already here. The scan is `Quiet` after this call: the host looks at what it
/// holds, and asks for more with `scan_older` when it is not enough.
///
/// The scan's records never enter the window, so the live end the host draws
/// is unchanged whatever the scan reads. A scan already under way is replaced,
/// and an identity that is not an entry's abandons the scan, which is how the
/// window's own parse of the same text would have failed.
///
/// ## Examples
///
/// ```gleam
/// // history_view.scan(history, "0198...", 10, cut.window, view)
/// ```
@internal
pub fn scan(
  state: State,
  leaf: String,
  before_seq: Int,
  known: snapshot.Window,
  view: snapshot_view.View,
) -> State {
  case ids.parse_entry_id(leaf) {
    Error(_) -> State(..state, scan: Abandoned)
    Ok(id) -> {
      let below =
        merge(state.window, known).items
        |> list.filter(fn(item) { snapshot.sequence(item) < before_seq })
      let ancestry =
        snapshot_view.branch(
          snapshot_view.View(
            ..view,
            leaves: dict.insert(view.leaves, state.strand, Some(id)),
          ),
          snapshot.Window(below, 0, None),
          state.strand,
        ).records
      let chain =
        dict.from_list(
          list.map(ancestry, fn(record) { #(record.entry.seq, Nil) }),
        )
      let held =
        list.filter(below, fn(item) {
          dict.has_key(chain, snapshot.sequence(item))
        })
      let window = newest_within(held, scan_records, scan_bytes)
      let next = case window.items {
        [] -> before_seq
        [_, ..] -> oldest(window)
      }
      State(
        ..state,
        scan: Scanning(
          leaf: Some(id),
          window:,
          before_seq: next,
          request: Quiet,
        ),
      )
    }
  }
}

/// What the scan has read: its ancestry from its endpoint, newest first, and
/// the identity of the parent it has not reached. Nothing when no scan is
/// under way.
///
/// ## Examples
///
/// ```gleam
/// // history_view.scanned(history, view)
/// ```
@internal
pub fn scanned(
  state: State,
  view: snapshot_view.View,
) -> Option(snapshot_view.Branch) {
  case state.scan {
    Scanning(leaf:, window:, ..) ->
      Some(snapshot_view.branch(
        snapshot_view.View(
          ..view,
          leaves: dict.insert(view.leaves, state.strand, leaf),
        ),
        window,
        state.strand,
      ))
    Unscanned | Abandoned -> None
  }
}

/// Asks for the interval below what the scan holds, when a parent is still
/// missing and a sequence remains to read, and says whether it did. A scan
/// with a read already out or owed asks nothing more.
///
/// ## Examples
///
/// ```gleam
/// // history_view.scan_older(history, branch.unloaded)
/// ```
@internal
pub fn scan_older(state: State, missing: Option(String)) -> State {
  case state.scan, missing {
    Scanning(leaf:, window:, before_seq:, request: Quiet), Some(_)
      if before_seq > 1
    ->
      State(
        ..state,
        scan: Scanning(leaf:, window:, before_seq:, request: Wanted),
      )
    _, _ -> state
  }
}

/// Whether the scan can be asked for more: a sequence is left to read below
/// what it holds, it has neither reached its bound nor had to cut, and the
/// parent it is missing (`missing`, the scan's `Branch.unloaded`) is a record it
/// could ever read. A parent the scan already holds as a descriptor with no
/// payload is a record over the presentation limit, which a read below returns
/// as a descriptor again, so no interval is going to prove it and the scan would
/// otherwise walk every sequence beneath it to the strand's first. A host that
/// finds it unreadable takes what it holds as all there will be.
///
/// ## Examples
///
/// ```gleam
/// assert !history_view.scan_readable(history_view.empty(), None)
/// ```
@internal
pub fn scan_readable(state: State, missing: Option(String)) -> Bool {
  case state.scan {
    Scanning(window:, before_seq:, ..) ->
      before_seq > 1
      && window.evicted_through == None
      && list.length(window.items) + 101 <= scan_records
      && window.bytes < scan_bytes
      && !held_unloaded(window, missing)
    Unscanned | Abandoned -> False
  }
}

// Whether the window holds the record `missing` names with no payload.
fn held_unloaded(window: snapshot.Window, missing: Option(String)) -> Bool {
  case missing {
    Some(parent) ->
      list.any(window.items, fn(item) {
        case item {
          snapshot.Unloaded(id, ..) -> id == parent
          snapshot.Loaded(..) -> False
        }
      })
    None -> False
  }
}

/// Drops the scan and everything it read.
///
/// ## Examples
///
/// ```gleam
/// assert history_view.scan_end(history_view.empty()).scan == history_view.Unscanned
/// ```
@internal
pub fn scan_end(state: State) -> State {
  State(..state, scan: Unscanned)
}

/// Drops the records older than `seq` from a live window, so the window
/// holds no more than its host draws.
///
/// The terminal keeps the whole bounded window and draws from it as the
/// reader scrolls. The web view draws only the newest rows of the ancestry
/// (`web_view/component`, `live_rows` and `held_rows`), and a record it no
/// longer draws would otherwise stay here, and be projected on every
/// capture, until this module's own bound of six hundred pushed it out.
/// Trimming to the oldest sequence the host draws keeps the window, and the
/// work each capture does, in proportion to the rows on the page.
///
/// The records left are still a suffix of the ancestry, so `branch` finds
/// the oldest one's parent missing and `older` can read the interval below
/// it; `before_seq` becomes that record's sequence. Only a live window with
/// no read owed is trimmed. A read in flight was sized from `before_seq`,
/// and `accept` places its reply against the window as it stood.
///
/// ## Examples
///
/// ```gleam
/// assert history_view.retain_from(history_view.empty(), 212)
///   == history_view.empty()
/// ```
@internal
pub fn retain_from(state: State, seq: Int) -> State {
  case state.mode, state.request {
    Live, Quiet ->
      case oldest(state.window) >= seq {
        True -> state
        False -> {
          let items =
            list.filter(state.window.items, fn(item) {
              snapshot.sequence(item) >= seq
            })
          let window =
            snapshot.Window(
              items,
              list.fold(items, 0, fn(sum, item) { sum + bytes(item) }),
              None,
            )
          State(..state, window:, before_seq: oldest(window))
        }
      }
    Live, Wanted | Live, Pending(_) | Reading, _ -> state
  }
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
/// A reply is the window's when the window asked for it and the scan's when
/// the scan did; the lane has one read out at a time, so it cannot be both.
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
  case state.request == Pending(before), state.scan {
    True, _ -> accepted(state, page, before, after, view, KeepOldest)
    False, Scanning(leaf:, window:, before_seq:, request: Pending(asked))
      if asked == before
    -> {
      let reading =
        State(
          state.strand,
          Reading,
          leaf,
          window,
          before_seq,
          Pending(before),
          Unscanned,
        )
      let read = accepted(reading, page, before, after, view, KeepNewest)
      State(
        ..state,
        scan: Scanning(
          leaf: read.leaf,
          window: read.window,
          before_seq: read.before_seq,
          request: Quiet,
        ),
      )
    }
    False, _ -> state
  }
}

// Which end a window keeps when a page takes it past its bound.
type Retention {
  // The window keeps its oldest records, as a window paging backward does.
  KeepOldest

  // The scan keeps its newest, which is the end it was started at.
  KeepNewest
}

// The newest of `items` (newest first) that fit the bound, and where the ones
// left out end, so the window says it was cut.
fn newest_within(
  items: List(snapshot.Item),
  records: Int,
  allowance: Int,
) -> snapshot.Window {
  let #(kept, size, _count, left_out) =
    list.fold(items, #([], 0, 0, None), fn(acc, item) {
      let #(kept, size, count, left_out) = acc
      case left_out, count < records && size + bytes(item) <= allowance {
        None, True -> #([item, ..kept], size + bytes(item), count + 1, None)
        None, False -> #(kept, size, count, Some(snapshot.sequence(item)))
        Some(_), _ -> acc
      }
    })
  snapshot.Window(list.reverse(kept), size, left_out)
}

fn accepted(
  state: State,
  page: snapshot.Window,
  before: Int,
  after: Int,
  view: snapshot_view.View,
  keeping: Retention,
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
      let window = case keeping {
        KeepOldest ->
          snapshot.Window(
            list.reverse(related),
            list.fold(related, 0, fn(sum, item) { sum + bytes(item) }),
            None,
          )
          |> bounded(600, 16 * 1024 * 1024)
          |> fn(retained) {
            snapshot.Window(..retained, items: list.reverse(retained.items))
          }
        KeepNewest -> newest_within(related, scan_records, scan_bytes)
      }
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
fn bounded(window: snapshot.Window, records: Int, allowance: Int) {
  let #(items, size, _) =
    list.fold(window.items, #([], 0, 0), fn(acc, item) {
      let #(items, size, count) = acc
      case count < records && size + bytes(item) <= allowance {
        True -> #([item, ..items], size + bytes(item), count + 1)
        False -> #(items, size, records)
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
