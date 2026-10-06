//// A scan reads a stretch of a strand's ancestry beside the history window.
////
//// The web view closes a settled turn into a summary and reads its records
//// again only when the reader asks, through a scan: a read that starts at one
//// record, walks down in bounded intervals, and holds what it found apart from
//// the window the page is drawing. These tests read what a scan holds, what it
//// asks for, and that the window is the same after it as before.

import core/clock
import core/entry
import core/ids
import core/message
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

fn between(
  all: List(snapshot.Item),
  after: Int,
  before: Int,
) -> snapshot.Window {
  window(
    list.filter(all, fn(item) {
      snapshot.sequence(item) > after && snapshot.sequence(item) < before
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

fn leaf_text(seq: Int) -> String {
  ids.entry_id_to_string(id(seq))
}

// A scan reads down from the record it starts at, interval by interval, and the
// window the page draws is the same value when it is done.
pub fn a_scan_reads_below_its_leaf_and_leaves_the_window_alone_test() {
  let all = entries(1200)
  let current = view(1200)
  let before = live(all)
  let started =
    history_view.scan(before, leaf_text(500), 501, snapshot.empty(), current)

  // Nothing is held yet, so the first read is owed for the interval below the
  // record it starts from.
  let assert Some(branch) = history_view.scanned(started, current)
  assert branch.records == []
  assert branch.unloaded == Some(leaf_text(500))
  assert history_view.range(started) == None
  let wanted = history_view.scan_older(started, branch.unloaded)
  assert history_view.range(wanted) == Some(#(400, 501))

  let received =
    history_view.accept(
      history_view.sent(wanted, 501),
      between(all, 400, 501),
      501,
      400,
      current,
    )
  let assert Some(read) = history_view.scanned(received, current)
  assert list.length(read.records) == 100
  assert history_view.scan_size(received) == 100
  assert received.window == before.window
  assert received.before_seq == before.before_seq
  assert received.request == history_view.Quiet
}

// A scan starts from the records the host already has: the part of a window it
// is handed that is the leaf's ancestry below the sequence, and the read it asks
// for next is below that.
pub fn a_scan_starts_from_what_the_host_already_holds_test() {
  let all = entries(1200)
  let current = view(1200)
  let started =
    history_view.scan(
      live(all),
      leaf_text(500),
      501,
      between(all, 449, 520),
      current,
    )
  let assert Some(branch) = history_view.scanned(started, current)
  assert list.length(branch.records) == 51
  assert branch.unloaded == Some(leaf_text(449))
  let assert Ok(first) = list.first(branch.records)
  assert first.entry.seq == 500
  let wanted = history_view.scan_older(started, branch.unloaded)
  assert history_view.range(wanted) == Some(#(349, 450))
}

// A reply belongs to the demand that asked for it. The window's own demand is
// served first, and a reply for the interval the scan asked for is the scan's.
pub fn a_reply_goes_to_whoever_asked_for_it_test() {
  let all = entries(1200)
  let current = view(1200)
  let asked =
    history_view.scan(live(all), leaf_text(500), 501, snapshot.empty(), current)
    |> history_view.scan_older(Some(leaf_text(500)))
  let window_wants = history_view.older(asked, Some(leaf_text(1100)))
  let assert Some(#(window_after, window_before)) =
    history_view.range(window_wants)
  assert window_before == 1101
  assert window_after == 1000

  // The scan's reply, with the window's demand also owed, changes only the
  // scan once the scan's read is out.
  let sent = history_view.sent(asked, 501)
  let received =
    history_view.accept(sent, between(all, 400, 501), 501, 400, current)
  assert history_view.scan_size(received) == 100
  assert received.window == sent.window
}

// A read that is refused, or a lane that is lost, abandons the scan and says so
// once; the host does not read again until the reader asks.
pub fn a_refused_read_abandons_the_scan_test() {
  let all = entries(1200)
  let current = view(1200)
  let out =
    history_view.scan(live(all), leaf_text(500), 501, snapshot.empty(), current)
    |> history_view.scan_older(Some(leaf_text(500)))
    |> history_view.sent(501)
  assert out.scan != history_view.Abandoned
  let refused = history_view.cancel(out)
  assert refused.scan == history_view.Abandoned
  assert history_view.range(refused) == None
  assert history_view.scanned(refused, current) == None
  assert history_view.scan_end(refused).scan == history_view.Unscanned
}

// A scan stops being readable when no sequence is left below it, so a host that
// reaches the start of a strand does not ask for an interval that is not there.
pub fn a_scan_at_the_first_sequence_reads_no_further_test() {
  let all = entries(1200)
  let current = view(1200)
  let above =
    history_view.scan(live(all), leaf_text(1), 2, snapshot.empty(), current)
  assert history_view.scan_readable(above)
  let at =
    history_view.scan(live(all), leaf_text(1), 1, snapshot.empty(), current)
  assert !history_view.scan_readable(at)
  assert history_view.scan_older(at, Some(leaf_text(1))) == at
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
