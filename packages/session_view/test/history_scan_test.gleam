//// A scan reads a stretch of a strand's ancestry beside the history window.
////
//// The web view closes a settled turn into a summary and reads its records
//// again only when the reader asks, through a scan: a read that starts at one
//// record, walks down the strand's own parent links a page at a time, and holds
//// what it found apart from the window the page is drawing. These tests read
//// what a scan holds, what it asks for, and that the window is the same after it
//// as before.

import core/clock
import core/entry
import core/ids
import core/message
import core/usage_evidence
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import session_view/history_view
import session_view/snapshot
import session_view/snapshot_view

fn id(seq: Int) -> ids.EntryId {
  ids.mint_entry(ids.generator(clock.fixed(1000), seq)).0
}

// The records one to `count` of one strand, newest first, each the child of the
// one before.
fn entries(count: Int) -> List(snapshot.Item) {
  int.range(from: 1, to: count + 1, with: [], run: fn(items, seq) {
    [
      snapshot.Loaded(
        entry.MessageEntry(
          id(seq),
          case seq {
            1 -> None
            _ -> Some(id(seq - 1))
          },
          seq,
          1000,
          message.UserMessage([message.UserText("record", None)], 1000, None),
          False,
        ),
        100,
      ),
      ..items
    ]
  })
}

fn window(items: List(snapshot.Item)) -> snapshot.Window {
  snapshot.Window(items, list.length(items) * 100, None)
}

// The page a lineage read from the record `from` returns: that record and the
// ninety-nine below it, newest first, as the lane hands them over.
fn page(all: List(snapshot.Item), from: Int) -> snapshot.Window {
  window(
    list.filter(all, fn(item) {
      snapshot.sequence(item) <= from && snapshot.sequence(item) > from - 100
    }),
  )
}

fn view(leaf: Int) -> snapshot_view.View {
  snapshot_view.View(
    [],
    dict.from_list([#("main", Some(id(leaf)))]),
    dict.new(),
    dict.new(),
    message.Usage(
      0,
      0,
      0,
      0,
      None,
      None,
      0,
      message.UsageCost(0.0, 0.0, 0.0, 0.0, 0.0),
      usage_evidence.none(),
    ),
    snapshot_view.RunSettings("one_at_a_time", "parallel", None),
    [],
    [],
    None,
    None,
    None,
  )
}

// The live end of a strand of 1,200 records, as a cut brings it.
fn live(all: List(snapshot.Item)) -> history_view.State {
  history_view.capture(
    history_view.empty(),
    window(list.take(all, 100)),
    view(1200),
    "main",
  )
}

fn text(seq: Int) -> String {
  ids.entry_id_to_string(id(seq))
}

// A scan reads down from the record it starts at, a page at a time, and the
// window the page draws is the same value when it is done.
pub fn a_scan_reads_below_its_leaf_and_leaves_the_window_alone_test() {
  let all = entries(1200)
  let current = view(1200)
  let before = live(all)
  let started =
    history_view.scan(before, text(500), 501, snapshot.empty(), current)

  // Nothing is held yet, so the first read is owed from the record the scan
  // starts at, and the window asks for nothing.
  let assert Some(branch) = history_view.scanned(started, current)
  assert branch.records == []
  assert branch.unloaded == Some(text(500))
  assert history_view.lineage(started) == None
  let wanted = history_view.scan_older(started, branch.unloaded)
  assert history_view.lineage(wanted) == Some(text(500))
  assert history_view.range(wanted) == None

  let received =
    history_view.accept_lineage(
      history_view.sent_lineage(wanted, text(500)),
      page(all, 500),
      text(500),
    )
  let assert Some(read) = history_view.scanned(received, current)
  assert list.length(read.records) == 100
  assert read.unloaded == Some(text(400))
  assert received.window == before.window
  assert received.before_seq == before.before_seq
  assert received.request == history_view.Quiet
  assert history_view.lineage(received) == None

  // The next read starts at the parent the scan lacks, so no record is read
  // twice.
  let next = history_view.scan_older(received, read.unloaded)
  assert history_view.lineage(next) == Some(text(400))
}

// A scan starts from the records the host already has: the part of a window it
// is handed that is the leaf's ancestry below the sequence, and the read it asks
// for next starts at the parent of the oldest of them.
pub fn a_scan_starts_from_what_the_host_already_holds_test() {
  let all = entries(1200)
  let current = view(1200)
  let known =
    window(
      list.filter(all, fn(item) {
        snapshot.sequence(item) >= 449 && snapshot.sequence(item) < 520
      }),
    )
  let started = history_view.scan(live(all), text(500), 501, known, current)
  let assert Some(branch) = history_view.scanned(started, current)
  assert list.length(branch.records) == 52
  assert branch.unloaded == Some(text(448))
  let assert Ok(first) = list.first(branch.records)
  assert first.entry.seq == 500
  let wanted = history_view.scan_older(started, branch.unloaded)
  assert history_view.lineage(wanted) == Some(text(448))
}

// The window's own demand is served first, so the lane reads one thing at a
// time, and a reply goes to the scan that asked for it and to nothing else.
pub fn a_reply_goes_to_whoever_asked_for_it_test() {
  let all = entries(1200)
  let current = view(1200)
  let asked =
    history_view.scan(live(all), text(500), 501, snapshot.empty(), current)
    |> history_view.scan_older(Some(text(500)))
  let window_wants = history_view.older(asked, Some(text(1100)))
  let assert Some(#(window_after, window_before)) =
    history_view.range(window_wants)
  assert window_before == 1101
  assert window_after == 1000
  assert history_view.lineage(window_wants) == None

  // The scan's reply changes only the scan once the scan's read is out.
  let sent = history_view.sent_lineage(asked, text(500))
  let received = history_view.accept_lineage(sent, page(all, 500), text(500))
  let assert Some(read) = history_view.scanned(received, current)
  assert list.length(read.records) == 100
  assert received.window == sent.window

  // A reply for a read the scan did not ask for is not taken.
  let stray = history_view.accept_lineage(sent, page(all, 300), text(300))
  assert stray == sent
}

// A read that is refused, or a lane that is lost, abandons the scan and says so
// once; the host does not read again until the reader asks.
pub fn a_refused_read_abandons_the_scan_test() {
  let all = entries(1200)
  let current = view(1200)
  let out =
    history_view.scan(live(all), text(500), 501, snapshot.empty(), current)
    |> history_view.scan_older(Some(text(500)))
    |> history_view.sent_lineage(text(500))
  assert out.scan != history_view.Abandoned
  let refused = history_view.cancel(out)
  assert refused.scan == history_view.Abandoned
  assert history_view.lineage(refused) == None
  assert history_view.scanned(refused, current) == None
  assert history_view.scan_end(refused).scan == history_view.Unscanned
}

// A read that brings nothing the scan does not hold says the store has nothing
// below it, so the scan is not readable and the same entry is not asked for
// again. A strand's first record has no parent, so it is not asked for either.
pub fn a_read_that_finds_nothing_ends_the_scan_test() {
  let all = entries(1200)
  let current = view(1200)
  let asked =
    history_view.scan(live(all), text(500), 501, snapshot.empty(), current)
    |> history_view.scan_older(Some(text(500)))
    |> history_view.sent_lineage(text(500))
  let empty = history_view.accept_lineage(asked, snapshot.empty(), text(500))
  assert !history_view.scan_readable(empty, Some(text(500)))
  assert history_view.scan_older(empty, Some(text(500))) == empty
  assert history_view.lineage(empty) == None
  assert !history_view.scan_readable(
    history_view.scan(live(all), text(1), 2, snapshot.empty(), current),
    None,
  )
}

// A leaf that is not an identity abandons the scan before it reads anything.
pub fn a_leaf_that_is_not_an_entry_abandons_the_scan_test() {
  let current = view(1200)
  let started =
    history_view.scan(
      history_view.empty(),
      "not an identity",
      10,
      snapshot.empty(),
      current,
    )
  assert started.scan == history_view.Abandoned
}

// A scan's bytes are bounded, and when a page would take it past the bound it
// keeps the newest end, the one it was started at, and says it was cut: a scan
// that kept the oldest would hand its host a stretch that no longer ends at the
// record it asked about. It is not readable afterwards.
pub fn a_scan_past_its_bytes_keeps_its_newest_end_test() {
  let all = entries(1200)
  let current = view(1200)
  let heavy =
    snapshot.Window(
      list.map(page(all, 500).items, fn(item) {
        case item {
          snapshot.Loaded(entry, _) -> snapshot.Loaded(entry, 4 * 1024 * 1024)
          snapshot.Unloaded(..) -> item
        }
      }),
      0,
      None,
    )
  let asked =
    history_view.scan(live(all), text(500), 501, snapshot.empty(), current)
    |> history_view.scan_older(Some(text(500)))
    |> history_view.sent_lineage(text(500))
  let received = history_view.accept_lineage(asked, heavy, text(500))
  let assert Some(read) = history_view.scanned(received, current)
  assert list.length(read.records) == 8
  let assert Ok(newest) = list.first(read.records)
  assert newest.entry.seq == 500
  assert !history_view.scan_readable(received, Some(text(500)))
}

// Reads the scan until it can read no further, and says how many reads it took.
fn exhausted(
  scan: history_view.State,
  all: List(snapshot.Item),
  current: snapshot_view.View,
  reads: Int,
) -> #(history_view.State, Int) {
  let assert Some(branch) = history_view.scanned(scan, current)
  let wanted = history_view.scan_older(scan, branch.unloaded)
  case history_view.lineage(wanted) {
    Some(from) -> {
      let assert Ok(from_seq) =
        list.find_map(all, fn(item) {
          case snapshot.identity(item) == from {
            True -> Ok(snapshot.sequence(item))
            False -> Error(Nil)
          }
        })
      exhausted(
        history_view.accept_lineage(
          history_view.sent_lineage(wanted, from),
          page(all, from_seq),
          from,
        ),
        all,
        current,
        reads + 1,
      )
    }
    None -> #(scan, reads)
  }
}

// A record over the presentation limit reaches the page as a descriptor with no
// payload, and no read below it proves it, so a scan that runs into one stops
// there. Reading on would ask for the same record again for nothing.
pub fn a_scan_stops_at_a_record_over_the_presentation_limit_test() {
  let all =
    list.map(entries(1200), fn(item) {
      case snapshot.sequence(item) {
        300 -> snapshot.Unloaded(text(300), 300, 5 * 1024 * 1024)
        _ -> item
      }
    })
  let current = view(1200)
  let started =
    history_view.scan(live(all), text(500), 501, snapshot.empty(), current)
  let #(done, reads) = exhausted(started, all, current, 0)
  assert reads <= 4
  let assert Some(branch) = history_view.scanned(done, current)
  assert branch.unloaded == Some(text(300))
  assert !history_view.scan_readable(done, branch.unloaded)
}

// However many records other strands wrote between this strand's, a scan takes
// one read for each hundred of the strand's own: the walk never meets them. This
// is the property the interval read lacked, which needed a read for every
// hundred sequences of the whole session. The newest hundred are the live
// window's, which a scan starts from, so they are not read.
pub fn a_scan_costs_the_strands_records_and_not_the_sessions_test() {
  let all = entries(1200)
  let current = view(1200)
  let started =
    history_view.scan(live(all), text(1200), 1201, snapshot.empty(), current)
  let #(done, reads) = exhausted(started, all, current, 0)
  assert reads == 11
  let assert Some(branch) = history_view.scanned(done, current)
  assert list.length(branch.records) == 1200
  assert branch.unloaded == None
}
