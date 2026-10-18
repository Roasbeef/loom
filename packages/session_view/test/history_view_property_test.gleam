//// Model-based property test of the history window and its scan.
////
//// `history_view` is a pure state machine: a bounded, pageable window of a
//// strand's ancestry, and beside it a transient scan, each fed by replies the
//// lane delivers whenever it likes. The example tests walk its documented
//// paths once each. This test drives the shipped functions over generated
//// command lists, so the orderings nobody wrote down meet each other: a page
//// arriving after a resume, a capture while the reader is frozen, a scan
//// replaced while its read is out, a cancel between two reads.
////
//// ## The world
////
//// The store is one strand of records numbered from one, each the child of
//// the one before, so a record's ancestry is every record below it and a
//// window is a run of consecutive sequences. A run is the whole state of a
//// window: `Run(lo, hi)`. A cut is the newest hundred records up to the
//// head, trimmed the way the snapshot decoder trims a transfer (at most a
//// hundred records and 8 MiB, keeping the newest), and a page is the
//// interval a read names, trimmed the same way, which is how a transfer's
//// `evicted_through` arises. Two worlds differ in record size: a light world
//// of 100-byte records reaches the real 600-record bound, and a heavy world
//// whose records run from 100 KB to 900 KB reaches the real 16 MiB bound and
//// the scan's 32 MiB bound with a few dozen records. The light world holds
//// 4,500 records so a scan can read down toward its own 4,096-record bound.
//// The bounds are the real ones.
////
//// ## The model
////
//// The model is the abstract state a reader of the documentation would
//// expect, advanced by a pure `predict`: the head of the store, the mode,
//// the window as a run, the leaf and `before_seq` as sequences, the window's
//// read as `NoDemand | Wanted | Asked(Req)`, the requests that were retired
//// (so a late reply can be built for one), and the scan as a run with its
//// own read. After every primitive step the real state must agree with the
//// model on each field, one tag per field, and a set of laws that read only
//// the real states before and after hold independently of the model. A
//// command names nothing by value: replies refer to the outstanding or a
//// retired request by position, and a scan starts at a fraction of the
//// head, so deleting a command leaves later ones meaningful and a failure
//// shrinks to a short list. The three composite gestures a host makes in
//// one go (`ReadOlder`: ask, admit, answer; `ScanDrain`: read a scan to its
//// end) expand into primitive steps, each checked on its own.
////
//// ## The rules, by tag
////
//// - `frozen`: a capture while the reader is frozen changes nothing
////   (`capture`: "Reading -> state"; `freeze`: "Freezes the reading endpoint
////   before live traffic can move it"). A live capture is the only thing
////   that moves the endpoint up.
//// - `late`: a reply that does not match the outstanding request changes
////   nothing (`accept`: "A late reply after navigation or returning to live
////   output cannot attach to the new selection"; `resume` retires the
////   request). The same holds for a scan reply the scan did not ask for
////   (`accept_lineage`).
//// - `progress`: an accepted page lowers `before_seq` below the interval
////   it answered, so no read asks for the same interval twice.
//// - `resume`: returning to live output discards no page (`resume`: "without
////   discarding the pages already read") and retires the read.
//// - `isolation`: a scan never touches the window, its endpoint, its mode or
////   its read (module doc: "The window is never touched by a scan"; `scan`:
////   "The scan's records never enter the window"), and no window command but
////   `cancel` touches the scan.
//// - `retention`: the window holds at most 600 records and 16 MiB of
////   payload, newest first with no sequence twice (`State.window`; module
////   doc: "Retention drops the newest end when paging backward"), and a scan
////   at most 4,096 records and 32 MiB (`Scan`).
//// - `window`, `leaf`, `before_seq`, `mode`, `request`, `branch`, `scan`:
////   the real field equals the model's. The model keeps the oldest end when
////   a page is accepted and the newest when a cut is captured; a capture
////   keeps the window already paged in only when the cut still meets it (no
////   sequence lies between them), and then keeps the lower `before_seq` an
////   earlier `accept` reached unless the bound evicted something (`capture`).
////
//// The abstract state of a failing run is printed with its commands, so a
//// shrunk list reads as the host gestures that break the rule. A list is
//// reproduced from the seed and run number alone: `statem.check_run`. The
//// seeds are constants.
////
//// Records are never `Unloaded` here, because the decoder produces that only
//// for a record over 4 MiB, and then the ancestry cannot be walked past it;
//// `history_scan_test` and `tui`'s `history_view_test` hold that case. The
//// scan's `Bottomed` floor is likewise unreachable in a world where every
//// page adds a record, and its example test holds it.

import core/clock
import core/entry
import core/ids
import core/message
import core/usage_evidence
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import qcheck
import session_view/history_view
import session_view/snapshot
import session_view/snapshot_view
import statem

// --- the world --------------------------------------------------------------

// How big a record is, which decides which bound a run can reach.
type Weight {
  Light
  Heavy
}

// One strand's records among others' in a store of `last` sequences. The
// strand owns the sequences in `items`, each the child of the one before it
// in sequence order; every other sequence belongs to another strand, which
// the window never holds and which shows only as a gap in the numbers.
type World {
  World(items: Dict(Int, snapshot.Item), last: Int, weight: Weight)
}

// The window's own bounds, as `history_view` states them, and the decoder's
// per-transfer bound from `snapshot`.
const window_records = 600

const window_bytes = 16_777_216

const scan_records = 4096

const scan_bytes = 33_554_432

const transfer_records = 100

const transfer_bytes = 8_388_608

fn id(seq: Int) -> ids.EntryId {
  ids.mint_entry(ids.generator(clock.fixed(1000), seq)).0
}

fn text(seq: Int) -> String {
  ids.entry_id_to_string(id(seq))
}

fn size(weight: Weight, seq: Int) -> Int {
  case weight {
    Light -> 100
    Heavy -> 100_000 + { seq * 7919 % 9 } * 100_000
  }
}

fn record(weight: Weight, seq: Int, parent: Option(Int)) -> snapshot.Item {
  snapshot.Loaded(
    entry.MessageEntry(
      id(seq),
      option.map(parent, id),
      seq,
      1000,
      message.UserMessage([message.UserText("record", None)], 1000, None),
      False,
    ),
    size(weight, seq),
  )
}

// Every sequence is the strand's except one in seven, which another strand
// wrote, and the `gaps`, which another strand wrote in a long run: a read that
// finds none of the strand's records is what `before_seq` has to survive.
fn build(weight: Weight, last: Int, gaps: List(Run)) -> World {
  let #(items, _) =
    int.range(
      from: 1,
      to: last + 1,
      with: #(dict.new(), None),
      run: fn(acc, seq) {
        let #(items, parent) = acc
        let foreign =
          seq % 7 == 3
          || list.any(gaps, fn(gap) { gap.lo <= seq && seq <= gap.hi })
        case foreign {
          True -> acc
          False -> #(
            dict.insert(items, seq, record(weight, seq, parent)),
            Some(seq),
          )
        }
      },
    )
  World(items, last, weight)
}

// The light world: 6,500 sequences, three long runs another strand wrote, and
// about 4,900 records of the strand, so a scan can read down to its own bound.
fn light() -> World {
  build(Light, 6500, [Run(1001, 1250), Run(2001, 2300), Run(3201, 3450)])
}

// The heavy world: 1,500 sequences with one long run of another strand's.
fn heavy() -> World {
  build(Heavy, 1500, [Run(501, 760)])
}

fn item(world: World, seq: Int) -> snapshot.Item {
  case dict.get(world.items, seq) {
    Ok(found) -> found
    Error(Nil) -> record(world.weight, seq, None)
  }
}

// The strand's newest record at or below `seq`.
fn at_or_below(world: World, seq: Int) -> Option(Int) {
  case seq < 1, dict.has_key(world.items, seq) {
    True, _ -> None
    False, True -> Some(seq)
    False, False -> at_or_below(world, seq - 1)
  }
}

// The strand's record below `seq`: the parent of the record at `seq`.
fn below(world: World, seq: Int) -> Option(Int) {
  at_or_below(world, seq - 1)
}

// The strand's oldest record at or above `seq`.
fn at_or_above(world: World, seq: Int) -> Option(Int) {
  case seq > world.last, dict.has_key(world.items, seq) {
    True, _ -> None
    False, True -> Some(seq)
    False, False -> at_or_above(world, seq + 1)
  }
}

fn above(world: World, seq: Int) -> Option(Int) {
  at_or_above(world, seq + 1)
}

fn view(leaf: Int) -> snapshot_view.View {
  snapshot_view.View(
    [],
    dict.from_list([#("main", leaf_id(leaf))]),
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

// --- runs -------------------------------------------------------------------

// Records `lo` to `hi` inclusive: the whole state of a window or a scan.
type Run {
  Run(lo: Int, hi: Int)
}

// Whether a bound stopped a walk before it reached the end of its run.
type Cut {
  Whole
  Trimmed
}

fn run_bytes(world: World, run: Run) -> Int {
  list.fold(members(world, run), 0, fn(total, seq) {
    total + size(world.weight, seq)
  })
}

// The strand's records in a run, newest first.
fn members(world: World, run: Run) -> List(Int) {
  members_from(world, run, at_or_below(world, run.hi), [])
}

fn members_from(
  world: World,
  run: Run,
  at: Option(Int),
  found: List(Int),
) -> List(Int) {
  case at {
    Some(seq) if seq >= run.lo ->
      members_from(world, run, below(world, seq), [seq, ..found])
    Some(_) | None -> list.reverse(found)
  }
}

fn keep_newest(
  world: World,
  run: Run,
  records: Int,
  allowance: Int,
) -> #(Int, Cut) {
  walk_down(world, run, Some(run.hi), run.hi, 0, 0, records, allowance)
}

fn walk_down(
  world: World,
  run: Run,
  at: Option(Int),
  kept: Int,
  count: Int,
  total: Int,
  records: Int,
  allowance: Int,
) -> #(Int, Cut) {
  case at {
    Some(seq) if seq >= run.lo -> {
      let weight = size(world.weight, seq)
      case count < records && total + weight <= allowance {
        True ->
          walk_down(
            world,
            run,
            below(world, seq),
            seq,
            count + 1,
            total + weight,
            records,
            allowance,
          )
        False -> #(kept, Trimmed)
      }
    }
    Some(_) | None -> #(kept, Whole)
  }
}

fn keep_oldest(world: World, run: Run, records: Int, allowance: Int) -> Int {
  walk_up(world, run, Some(run.lo), run.lo, 0, 0, records, allowance)
}

fn walk_up(
  world: World,
  run: Run,
  at: Option(Int),
  kept: Int,
  count: Int,
  total: Int,
  records: Int,
  allowance: Int,
) -> Int {
  case at {
    Some(seq) if seq <= run.hi -> {
      let weight = size(world.weight, seq)
      case count < records && total + weight <= allowance {
        True ->
          walk_up(
            world,
            run,
            above(world, seq),
            seq,
            count + 1,
            total + weight,
            records,
            allowance,
          )
        False -> kept
      }
    }
    Some(_) | None -> kept
  }
}

fn transfer(world: World, run: Run) -> #(Run, Option(Int)) {
  let #(lo, cut) = keep_newest(world, run, transfer_records, transfer_bytes)
  case cut {
    Whole -> #(Run(lo, run.hi), None)
    Trimmed -> #(Run(lo, run.hi), below(world, lo))
  }
}

// The strand's records with sequences from `lo` to `hi`, as a run, when it
// has any.
fn between(world: World, lo: Int, hi: Int) -> Option(Run) {
  case at_or_above(world, lo), at_or_below(world, hi) {
    Some(first), Some(last) if first <= last -> Some(Run(first, last))
    _, _ -> None
  }
}

// Up to a hundred of the strand's records ending at the record `hi`: a cut
// holds the newest hundred, and a lineage read the record it names and the
// ninety-nine below it by the strand's own parent links.
fn newest_hundred(world: World, hi: Int) -> #(Run, Option(Int)) {
  transfer(world, Run(bottom(world, hi, transfer_records), hi))
}

fn bottom(world: World, seq: Int, count: Int) -> Int {
  case count > 1, below(world, seq) {
    True, Some(parent) -> bottom(world, parent, count - 1)
    _, _ -> seq
  }
}

fn items_of(world: World, run: Run) -> List(snapshot.Item) {
  list.map(members(world, run), item(world, _))
}

fn window_of(world: World, run: Run, evicted: Option(Int)) -> snapshot.Window {
  snapshot.Window(items_of(world, run), run_bytes(world, run), evicted)
}

fn cut_of(world: World, head: Int) -> #(Run, Option(Int)) {
  newest_hundred(world, option.unwrap(at_or_below(world, head), 1))
}

// --- the model --------------------------------------------------------------

// A history read the lane was asked to make: the interval it names, which is
// exclusive at both ends.
type Req {
  Req(after: Int, before: Int)
}

// The window's own demand.
type Demand {
  NoDemand
  Wanted
  Asked(Req)
}

// The scan's read: the sequence of the record it starts at.
type Read {
  Idle
  Owed(from: Int)
  Out(from: Int)
}

type Held {
  NoScan
  Holding(leaf: Int, run: Option(Run), left_out: Option(Int), read: Read)
  Dropped
}

// What a reader of the documentation expects the state to be. A window is a
// run of consecutive records because the store is one strand and every page
// read is complete; `leaf` is 0 before the first capture.
type Abstract {
  Abstract(
    head: Int,
    mode: history_view.Mode,
    window: Option(Run),
    leaf: Int,
    before_seq: Int,
    demand: Demand,
    retired: List(Req),
    scan: Held,
    retired_reads: List(Int),
  )
}

// Where a scan's records come from at its start: the cut the host holds, or
// nothing.
type Known {
  KnownCut
  KnownNothing
}

// How a reply relates to the read it claims to answer.
type Reply {
  // The reply the lane would deliver for the outstanding read.
  Answer

  // A reply to a request that was retired, by position in the retired list.
  Replay(index: Int)

  // The outstanding request's page under an identity that is not its own.
  Skewed(by: Int)
}

type Command {
  // The head moves `advance` records and the lane delivers a live cut.
  Capture(advance: Int)
  Freeze
  Resume

  // The reader scrolls up: the window wants an older page.
  Older

  // The lane admits the window's wanted read.
  Send

  // A reply to a window read arrives.
  Page(reply: Reply)

  // The lane refuses a read or is lost.
  Cancel

  // A host that draws only the newest rows trims the window to a point
  // `percent` of the way up it.
  Retain(percent: Int)

  // A scan starts at a record `back` percent of the way down from the head.
  ScanStart(back: Int, known: Known)
  ScanMore
  ScanSend
  ScanPage(reply: Reply)
  ScanEnd

  // A host's gesture: ask, admit and answer one older page.
  ReadOlder

  // A host's gesture: read a scan until nothing is owed.
  ScanDrain
}

fn initial() -> Abstract {
  Abstract(
    head: 150,
    mode: history_view.Live,
    window: None,
    leaf: 0,
    before_seq: 0,
    demand: NoDemand,
    retired: [],
    scan: NoScan,
    retired_reads: [],
  )
}

// The steps a command is made of. Only a composite expands, and the scan
// drain reads the model to know how many rounds a real host would loop.
fn steps(world: World, model: Abstract, command: Command) -> List(Command) {
  case command {
    ReadOlder -> [Older, Send, Page(Answer)]
    ScanDrain -> drain_rounds(world, model, 60)
    Capture(_)
    | Freeze
    | Resume
    | Older
    | Send
    | Page(_)
    | Cancel
    | Retain(_)
    | ScanStart(..)
    | ScanMore
    | ScanSend
    | ScanPage(_)
    | ScanEnd -> [command]
  }
}

// Rounds of ask, admit and answer while each one moves the scan.
fn drain_rounds(world: World, model: Abstract, left: Int) -> List(Command) {
  let round = [ScanMore, ScanSend, ScanPage(Answer)]
  let after = list.fold(round, model, fn(m, step) { predict(world, m, step) })
  case left > 0 && after.scan != model.scan {
    True -> list.append(round, drain_rounds(world, after, left - 1))
    False -> []
  }
}

fn predict_all(world: World, model: Abstract, command: Command) -> Abstract {
  list.fold(steps(world, model, command), model, fn(m, step) {
    predict(world, m, step)
  })
}

// The model after one primitive step.
fn predict(world: World, model: Abstract, step: Command) -> Abstract {
  case step {
    Capture(advance) -> captured(world, model, advance)
    Freeze -> Abstract(..model, mode: history_view.Reading)
    Resume -> Abstract(..retire(model), mode: history_view.Live)
    Older -> asked_older(model)
    Send -> admitted(model)
    Page(reply) -> answered(world, model, reply)
    Cancel -> cancelled(model)
    Retain(percent) -> retained(world, model, percent)
    ScanStart(back, known) -> started(world, model, back, known)
    ScanMore -> scan_more(world, model)
    ScanSend -> scan_sent(model)
    ScanPage(reply) -> scan_answered(world, model, reply)
    ScanEnd -> scan_ended(model)
    ReadOlder | ScanDrain -> predict_all(world, model, step)
  }
}

// The window's outstanding request, if any, is no longer awaited.
fn retire(model: Abstract) -> Abstract {
  case model.demand {
    Asked(req) ->
      Abstract(
        ..model,
        demand: NoDemand,
        retired: list.take([req, ..model.retired], 4),
      )
    Wanted | NoDemand -> Abstract(..model, demand: NoDemand)
  }
}

// A live capture folds the cut in; a frozen reader's window ignores it, and
// the store grows either way. The window the reader already paged in joins
// the cut only when no sequence lies between them; a bound that evicts
// nothing keeps the lower `before_seq` an earlier page reached.
fn captured(world: World, model: Abstract, advance: Int) -> Abstract {
  let head = int.min(model.head + advance, world.last)
  case model.mode {
    history_view.Reading -> Abstract(..model, head:)
    history_view.Live -> {
      let #(cut, _) = cut_of(world, head)
      let meets = case model.window {
        Some(run) -> run.hi >= cut.lo - 1
        None -> False
      }
      let whole = case model.window, meets {
        Some(run), True -> Run(int.min(run.lo, cut.lo), cut.hi)
        _, _ -> cut
      }
      let #(lo, trimmed) =
        keep_newest(world, whole, window_records, window_bytes)
      let before_seq = case meets && model.before_seq > 0, trimmed {
        True, Whole -> int.min(model.before_seq, lo)
        _, _ -> lo
      }
      Abstract(
        ..retire(model),
        head:,
        mode: history_view.Live,
        window: Some(Run(lo, cut.hi)),
        leaf: cut.hi,
        before_seq:,
      )
    }
  }
}

// The window's records begin at `lo`, so its parent is missing when `lo` is
// above the strand's first record.
fn missing(model: Abstract) -> Bool {
  case model.window {
    Some(run) -> run.lo > 1
    None -> False
  }
}

fn asked_older(model: Abstract) -> Abstract {
  case model.demand, missing(model), model.before_seq > 1 {
    NoDemand, True, True ->
      Abstract(..model, mode: history_view.Reading, demand: Wanted)
    _, _, _ -> model
  }
}

// An interval of at most a hundred sequence positions below `before_seq`.
fn interval(before_seq: Int) -> Req {
  Req(int.max(0, before_seq - 101), before_seq)
}

fn admitted(model: Abstract) -> Abstract {
  case model.demand {
    Wanted -> Abstract(..model, demand: Asked(interval(model.before_seq)))
    NoDemand | Asked(_) -> model
  }
}

// The request a reply claims to answer, if the command has one.
fn claimed(model: Abstract, reply: Reply) -> Option(Req) {
  case reply, model.demand {
    Answer, Asked(req) -> Some(req)
    Skewed(by), Asked(req) -> Some(Req(req.after, req.before + by))
    Replay(index), _ -> nth(model.retired, index)
    Answer, Wanted
    | Answer, NoDemand
    | Skewed(_), Wanted
    | Skewed(_), NoDemand
    -> None
  }
}

fn nth(items: List(a), index: Int) -> Option(a) {
  case list.length(items) {
    0 -> None
    count ->
      case list.drop(items, index % count) {
        [found, ..] -> Some(found)
        [] -> None
      }
  }
}

// Whether the state awaits exactly this request: a reply is matched by the
// upper bound it names.
fn attaches(model: Abstract, claim: Option(Req)) -> Option(Req) {
  case claim, model.demand {
    Some(req), Asked(asked) if req.before == asked.before -> Some(asked)
    _, _ -> None
  }
}

fn answered(world: World, model: Abstract, reply: Reply) -> Abstract {
  case attaches(model, claimed(model, reply)), model.window {
    Some(req), Some(run) -> {
      let retired = list.take([req, ..model.retired], 4)
      case between(world, req.after + 1, req.before - 1) {
        None ->
          Abstract(
            ..model,
            demand: NoDemand,
            retired:,
            before_seq: req.after + 1,
          )
        Some(whole) -> {
          let #(page, evicted) = transfer(world, whole)
          let hi =
            keep_oldest(
              world,
              Run(page.lo, run.hi),
              window_records,
              window_bytes,
            )
          Abstract(
            ..model,
            demand: NoDemand,
            retired:,
            window: Some(Run(page.lo, hi)),
            leaf: hi,
            before_seq: case evicted {
              Some(seq) -> seq + 1
              None -> req.after + 1
            },
          )
        }
      }
    }
    _, _ -> model
  }
}

fn cancelled(model: Abstract) -> Abstract {
  let retired = retire(model)
  case model.scan {
    Holding(read: Out(from), ..) ->
      Abstract(
        ..retired,
        scan: Dropped,
        retired_reads: list.take([from, ..model.retired_reads], 4),
      )
    Holding(..) -> Abstract(..retired, scan: Dropped)
    NoScan | Dropped -> retired
  }
}

fn retained(world: World, model: Abstract, percent: Int) -> Abstract {
  case model.mode, model.demand, model.window {
    history_view.Live, NoDemand, Some(run) -> {
      let seq = run.lo + { run.hi - run.lo } * percent / 100
      case at_or_above(world, seq) {
        Some(lo) if lo > run.lo ->
          Abstract(..model, window: Some(Run(lo, run.hi)), before_seq: lo)
        _ -> model
      }
    }
    _, _, _ -> model
  }
}

// --- the scan's model -------------------------------------------------------

fn leaf_of(world: World, model: Abstract, back: Int) -> Int {
  let wanted = int.max(1, model.head - model.head * back / 100)
  option.unwrap(at_or_below(world, wanted), 1)
}

fn ancestry(world: World, leaf: Int, intervals: List(Run)) -> Option(Run) {
  case list.find(intervals, fn(run) { run.lo <= leaf && leaf <= run.hi }) {
    Ok(first) -> Some(Run(reach(world, first.lo, intervals), leaf))
    Error(Nil) -> None
  }
}

fn reach(world: World, lo: Int, intervals: List(Run)) -> Int {
  case below(world, lo) {
    Some(parent) ->
      case
        list.find(intervals, fn(run) { run.lo <= parent && parent <= run.hi })
      {
        Ok(lower) -> reach(world, lower.lo, intervals)
        Error(Nil) -> lo
      }
    None -> lo
  }
}

fn started(world: World, model: Abstract, back: Int, known: Known) -> Abstract {
  let leaf = leaf_of(world, model, back)
  let window = case model.window {
    Some(run) -> [run]
    None -> []
  }
  let held = case known {
    KnownCut -> [cut_of(world, model.head).0]
    KnownNothing -> []
  }
  let found = ancestry(world, leaf, list.append(window, held))
  let #(run, left_out) = case found {
    Some(run) -> {
      let #(lo, trimmed) = keep_newest(world, run, scan_records, scan_bytes)
      case trimmed {
        Whole -> #(Some(run), None)
        Trimmed -> #(Some(Run(lo, run.hi)), below(world, lo))
      }
    }
    None -> #(None, None)
  }
  Abstract(
    ..model,
    scan: Holding(leaf:, run:, left_out:, read: Idle),
    retired_reads: scan_out(model),
  )
}

// The reads retired when the scan goes away or is replaced.
fn scan_out(model: Abstract) -> List(Int) {
  case model.scan {
    Holding(read: Out(from), ..) -> list.take([from, ..model.retired_reads], 4)
    Holding(..) | NoScan | Dropped -> model.retired_reads
  }
}

fn scan_count(world: World, run: Option(Run)) -> Int {
  case run {
    Some(run) -> list.length(members(world, run))
    None -> 0
  }
}

fn parent_of(world: World, leaf: Int, run: Option(Run)) -> Option(Int) {
  case run {
    None -> Some(leaf)
    Some(run) -> below(world, run.lo)
  }
}

fn scan_more(world: World, model: Abstract) -> Abstract {
  case model.scan {
    Holding(leaf:, run:, left_out: None, read: Idle) ->
      case
        parent_of(world, leaf, run),
        scan_count(world, run) + 100 <= scan_records,
        scan_weight(world, run) < scan_bytes
      {
        Some(from), True, True ->
          Abstract(
            ..model,
            scan: Holding(leaf:, run:, left_out: None, read: Owed(from)),
          )
        _, _, _ -> model
      }
    Holding(..) | NoScan | Dropped -> model
  }
}

fn scan_weight(world: World, run: Option(Run)) -> Int {
  case run {
    Some(run) -> run_bytes(world, run)
    None -> 0
  }
}

// The window's own demand is served first, so the lane names the scan's read
// only when the window wants none.
fn scan_sent(model: Abstract) -> Abstract {
  case model.demand, model.scan {
    NoDemand, Holding(leaf:, run:, left_out:, read: Owed(from)) ->
      Abstract(..model, scan: Holding(leaf:, run:, left_out:, read: Out(from)))
    _, _ -> model
  }
}

// The read a scan reply claims to answer.
fn claimed_read(model: Abstract, reply: Reply) -> Option(Int) {
  case reply, model.scan {
    Answer, Holding(read: Out(from), ..) -> Some(from)
    Skewed(by), Holding(read: Out(from), ..) -> Some(from + by)
    Replay(index), _ -> nth(model.retired_reads, index)
    Answer, _ | Skewed(_), _ -> None
  }
}

fn scan_answered(world: World, model: Abstract, reply: Reply) -> Abstract {
  case claimed_read(model, reply), model.scan {
    Some(claim), Holding(leaf:, run:, read: Out(from), ..) if claim == from -> {
      let #(page, _) = newest_hundred(world, from)
      let hi = case run {
        Some(run) -> run.hi
        None -> leaf
      }
      let joined = Run(page.lo, hi)
      let #(lo, trimmed) = keep_newest(world, joined, scan_records, scan_bytes)
      let left_out = case trimmed {
        Whole -> None
        Trimmed -> below(world, lo)
      }
      Abstract(
        ..model,
        scan: Holding(leaf:, run: Some(Run(lo, hi)), left_out:, read: Idle),
        retired_reads: list.take([from, ..model.retired_reads], 4),
      )
    }
    _, _ -> model
  }
}

fn scan_ended(model: Abstract) -> Abstract {
  Abstract(..model, scan: NoScan, retired_reads: scan_out(model))
}

// --- the real state ---------------------------------------------------------

// A fresh strand as the daemon first delivered it: the cut at the initial head
// is the window, so no run starts from the empty state's blank strand.
fn bare() -> Abstract {
  initial()
}

fn start(world: World) -> Abstract {
  captured(world, bare(), 0)
}

fn new_state(world: World) -> history_view.State {
  let #(cut, evicted) = cut_of(world, bare().head)
  history_view.capture(
    history_view.empty(),
    window_of(world, cut, evicted),
    view(cut.hi),
    "main",
  )
}

// One primitive step on the real state, with the requests and replies built
// from the model's account of what is outstanding, as the lane would hold it.
fn apply(
  world: World,
  state: history_view.State,
  model: Abstract,
  step: Command,
) -> history_view.State {
  let current = view(model.leaf)
  case step {
    Capture(advance) -> {
      let head = int.min(model.head + advance, world.last)
      let #(cut, evicted) = cut_of(world, head)
      history_view.capture(
        state,
        window_of(world, cut, evicted),
        view(cut.hi),
        "main",
      )
    }
    Freeze -> history_view.freeze(state)
    Resume -> history_view.resume(state)
    Older ->
      history_view.older(state, history_view.branch(state, current).unloaded)
    Send ->
      case history_view.range(state) {
        Some(#(_, before)) -> history_view.sent(state, before)
        None -> state
      }
    Page(reply) ->
      case claimed(model, reply) {
        Some(req) -> {
          let page = case between(world, req.after + 1, req.before - 1) {
            Some(whole) -> {
              let #(kept, evicted) = transfer(world, whole)
              window_of(world, kept, evicted)
            }
            None -> snapshot.empty()
          }
          history_view.accept(state, page, req.before, req.after, current)
        }
        None -> state
      }
    Cancel -> history_view.cancel(state)
    Retain(percent) ->
      case model.window {
        Some(run) ->
          history_view.retain_from(
            state,
            run.lo + { run.hi - run.lo } * percent / 100,
          )
        None -> state
      }
    ScanStart(back, known) -> {
      let leaf = leaf_of(world, model, back)
      let #(cut, evicted) = cut_of(world, model.head)
      let held = case known {
        KnownCut -> window_of(world, cut, evicted)
        KnownNothing -> snapshot.empty()
      }
      history_view.scan(state, text(leaf), leaf + 1, held, current)
    }
    ScanMore ->
      history_view.scan_older(state, case history_view.scanned(state, current) {
        Some(branch) -> branch.unloaded
        None -> None
      })
    ScanSend ->
      case history_view.lineage(state) {
        Some(from) -> history_view.sent_lineage(state, from)
        None -> state
      }
    ScanPage(reply) ->
      case claimed_read(model, reply) {
        Some(from) -> {
          let #(page, evicted) = newest_hundred(world, from)
          history_view.accept_lineage(
            state,
            window_of(world, page, evicted),
            text(from),
          )
        }
        None -> state
      }
    ScanEnd -> history_view.scan_end(state)
    ReadOlder | ScanDrain -> state
  }
}

// --- what is checked --------------------------------------------------------

fn violation(tag: String, detail: String) -> statem.Violation {
  statem.Violation(tag:, detail:)
}

// Two values the rule says are equal.
fn same(
  actual: a,
  expected: a,
  tag: String,
  detail: String,
) -> Result(Nil, statem.Violation) {
  case actual == expected {
    True -> Ok(Nil)
    False ->
      Error(violation(
        tag,
        detail
          <> ": expected "
          <> brief(expected)
          <> ", the state has "
          <> brief(actual),
      ))
  }
}

// A value printed for a reader: a state holds whole records, so the start of
// it is enough to see which field moved.
fn brief(value: a) -> String {
  string.slice(string.inspect(value), 0, 200)
}

// A value the rule says is at most a bound.
fn at_most(
  value: Int,
  bound: Int,
  tag: String,
  detail: String,
) -> Result(Nil, statem.Violation) {
  case value <= bound {
    True -> Ok(Nil)
    False ->
      Error(violation(
        tag,
        detail
          <> ": "
          <> int.to_string(value)
          <> " exceeds the bound "
          <> int.to_string(bound),
      ))
  }
}

fn descending(seqs: List(Int)) -> Result(Nil, statem.Violation) {
  case seqs {
    [first, second, ..rest] ->
      case first > second {
        True -> descending([second, ..rest])
        False ->
          Error(violation(
            "retention",
            "items are not newest first with no sequence twice at "
              <> int.to_string(first)
              <> " then "
              <> int.to_string(second),
          ))
      }
    [_] | [] -> Ok(Nil)
  }
}

fn seqs_of(window: snapshot.Window) -> List(Int) {
  list.map(window.items, snapshot.sequence)
}

// The window and the scan hold what their bounds say, newest first.
fn retention(state: history_view.State) -> Result(Nil, statem.Violation) {
  use _ <- result.try(at_most(
    list.length(state.window.items),
    window_records,
    "retention",
    "the window holds more than 600 records",
  ))
  use _ <- result.try(at_most(
    state.window.bytes,
    window_bytes,
    "retention",
    "the window holds more than 16 MiB",
  ))
  use _ <- result.try(descending(seqs_of(state.window)))
  case state.scan {
    history_view.Scanning(window:, ..) -> {
      use _ <- result.try(at_most(
        list.length(window.items),
        scan_records,
        "retention",
        "the scan holds more than 4096 records",
      ))
      use _ <- result.try(at_most(
        window.bytes,
        scan_bytes,
        "retention",
        "the scan holds more than 32 MiB",
      ))
      descending(seqs_of(window))
    }
    history_view.Unscanned | history_view.Abandoned -> Ok(Nil)
  }
}

// Whether a window reply is one the model says the state awaits.
fn window_attached(model: Abstract, reply: Reply) -> Option(Req) {
  attaches(model, claimed(model, reply))
}

fn scan_attached(model: Abstract, reply: Reply) -> Option(Int) {
  case claimed_read(model, reply), model.scan {
    Some(claim), Holding(read: Out(from), ..) if claim == from -> Some(from)
    _, _ -> None
  }
}

// What the states before and after a step must satisfy whatever the model
// says: each reads only the two real states.
fn laws(
  before: history_view.State,
  after: history_view.State,
  model: Abstract,
  step: Command,
) -> Result(Nil, statem.Violation) {
  case step {
    Capture(_) ->
      case model.mode {
        history_view.Reading ->
          same(after, before, "frozen", "a capture moved a frozen reader")
        history_view.Live -> Ok(Nil)
      }
    Resume -> {
      use _ <- result.try(same(
        after.window,
        before.window,
        "resume",
        "returning to live output discarded pages",
      ))
      use _ <- result.try(same(
        after.leaf,
        before.leaf,
        "resume",
        "returning to live output moved the endpoint",
      ))
      same(
        after.request,
        history_view.Quiet,
        "resume",
        "returning to live output left a read outstanding",
      )
    }
    Page(reply) ->
      case window_attached(model, reply) {
        None ->
          same(
            after,
            before,
            "late",
            "a reply that was not awaited changed state",
          )
        Some(req) ->
          at_most(
            after.before_seq + 1,
            req.before,
            "progress",
            "an accepted page left the next read at the same interval",
          )
      }
    ScanPage(reply) ->
      case scan_attached(model, reply) {
        None ->
          same(
            after,
            before,
            "late",
            "a scan reply that was not asked for changed state",
          )
        Some(_) -> isolated(before, after)
      }
    ScanStart(..) | ScanMore | ScanSend | ScanEnd -> isolated(before, after)
    Cancel -> cancel_law(before, after)
    Freeze | Older | Send | Retain(_) -> kept_scan(before, after)
    ReadOlder | ScanDrain -> Ok(Nil)
  }
}

// A scan never touches the window, its endpoint, its mode or its read.
fn isolated(
  before: history_view.State,
  after: history_view.State,
) -> Result(Nil, statem.Violation) {
  same(
    #(
      after.strand,
      after.mode,
      after.leaf,
      after.window,
      after.before_seq,
      after.request,
    ),
    #(
      before.strand,
      before.mode,
      before.leaf,
      before.window,
      before.before_seq,
      before.request,
    ),
    "isolation",
    "a scan command touched the window",
  )
}

// A window command other than a cancel leaves the scan as it was.
fn kept_scan(
  before: history_view.State,
  after: history_view.State,
) -> Result(Nil, statem.Violation) {
  same(
    after.scan,
    before.scan,
    "isolation",
    "a window command touched the scan",
  )
}

// A cancel retires the window's read and drops a scan that was under way, and
// it can do nothing else to either: the lane that refused a read cannot say
// which read it was, so a scan is abandoned whether or not its own read was
// the one out (`cancel`: "A scan whose read is retired is abandoned").
fn cancel_law(
  before: history_view.State,
  after: history_view.State,
) -> Result(Nil, statem.Violation) {
  use _ <- result.try(same(
    after.request,
    history_view.Quiet,
    "cancel",
    "a cancel left a read outstanding",
  ))
  use _ <- result.try(same(
    #(after.mode, after.leaf, after.window, after.before_seq),
    #(before.mode, before.leaf, before.window, before.before_seq),
    "cancel",
    "a cancel changed the visible rows",
  ))
  case before.scan {
    history_view.Scanning(..) ->
      same(
        after.scan,
        history_view.Abandoned,
        "cancel",
        "a cancel left a scan under way",
      )
    history_view.Unscanned | history_view.Abandoned ->
      same(
        after.scan,
        before.scan,
        "cancel",
        "a cancel changed a scan that was not under way",
      )
  }
}

fn demand_request(demand: Demand) -> history_view.Request {
  case demand {
    NoDemand -> history_view.Quiet
    Wanted -> history_view.Wanted
    Asked(req) -> history_view.Pending(req.before)
  }
}

fn lineage_of(read: Read) -> history_view.Lineage {
  case read {
    Idle -> history_view.Idle
    Owed(from) -> history_view.Owed(text(from))
    Out(from) -> history_view.Out(text(from))
  }
}

fn run_window(world: World, run: Option(Run), evicted: Option(Int)) {
  case run {
    Some(run) -> window_of(world, run, evicted)
    None -> snapshot.Window([], 0, evicted)
  }
}

fn leaf_id(seq: Int) -> Option(ids.EntryId) {
  case seq {
    0 -> None
    _ -> Some(id(seq))
  }
}

fn descending_seqs(world: World, run: Option(Run)) -> List(Int) {
  case run {
    Some(run) -> members(world, run)
    None -> []
  }
}

fn unloaded_parent(world: World, run: Option(Run)) -> Option(String) {
  case run {
    Some(run) -> option.map(below(world, run.lo), text)
    None -> None
  }
}

// The real state against the model, one tag per field.
fn agrees(
  world: World,
  state: history_view.State,
  model: Abstract,
) -> Result(Nil, statem.Violation) {
  use _ <- result.try(same(state.mode, model.mode, "mode", "the mode differs"))
  use _ <- result.try(same(
    state.request,
    demand_request(model.demand),
    "request",
    "the window's read differs",
  ))
  use _ <- result.try(same(
    state.before_seq,
    model.before_seq,
    "before_seq",
    "the next interval differs",
  ))
  use _ <- result.try(same(
    state.leaf,
    leaf_id(model.leaf),
    "leaf",
    "the endpoint differs",
  ))
  use _ <- result.try(same(
    state.window,
    run_window(world, model.window, None),
    "window",
    "the retained records differ",
  ))
  let branch = history_view.branch(state, view(model.leaf))
  use _ <- result.try(same(
    list.map(branch.records, fn(record) { record.entry.seq }),
    descending_seqs(world, model.window),
    "branch",
    "the projected ancestry differs",
  ))
  use _ <- result.try(same(
    branch.unloaded,
    unloaded_parent(world, model.window),
    "branch",
    "the missing parent differs",
  ))
  scan_agrees(world, state, model)
}

fn scan_agrees(
  world: World,
  state: history_view.State,
  model: Abstract,
) -> Result(Nil, statem.Violation) {
  case state.scan, model.scan {
    history_view.Unscanned, NoScan | history_view.Abandoned, Dropped -> Ok(Nil)
    history_view.Scanning(leaf:, window:, request:, floor:),
      Holding(leaf: seq, run:, left_out:, read:)
    -> {
      use _ <- result.try(same(
        leaf,
        Some(id(seq)),
        "scan",
        "the scan's leaf differs",
      ))
      use _ <- result.try(same(
        window,
        run_window(world, run, left_out),
        "scan",
        "the scan's records differ",
      ))
      use _ <- result.try(same(
        request,
        lineage_of(read),
        "scan",
        "the scan's read differs",
      ))
      use _ <- result.try(same(
        floor,
        history_view.Open,
        "scan",
        "the scan's floor differs",
      ))
      let branch = history_view.scanned(state, view(model.leaf))
      same(
        option.map(branch, fn(found) {
          #(
            list.map(found.records, fn(record) { record.entry.seq }),
            found.unloaded,
          )
        }),
        Some(
          #(descending_seqs(world, run), case parent_of(world, seq, run) {
            Some(from) -> Some(text(from))
            None -> None
          }),
        ),
        "scan",
        "the scan's projection differs",
      )
    }
    history_view.Unscanned, _ | history_view.Abandoned, _ ->
      Error(violation("scan", "the scan is gone and the model holds one"))
    history_view.Scanning(..), NoScan | history_view.Scanning(..), Dropped ->
      Error(violation("scan", "the model dropped a scan the state holds"))
  }
}

// --- driving ----------------------------------------------------------------

fn run_steps(
  world: World,
  state: history_view.State,
  model: Abstract,
  pending: List(Command),
) -> Result(history_view.State, statem.Violation) {
  case pending {
    [] -> Ok(state)
    [step, ..rest] -> {
      let after = apply(world, state, model, step)
      let expected = predict(world, model, step)
      use _ <- result.try(laws(state, after, model, step))
      use _ <- result.try(retention(after))
      use _ <- result.try(agrees(world, after, expected))
      run_steps(world, after, expected, rest)
    }
  }
}

fn execute(
  world: World,
) -> fn(history_view.State, Abstract, Command) ->
  Result(history_view.State, statem.Violation) {
  fn(state, model, command) {
    run_steps(world, state, model, steps(world, model, command))
  }
}

fn spec(world: World) -> statem.Spec(Abstract, Command, history_view.State) {
  statem.Spec(
    initial: start(world),
    command: fn(_) { command() },
    precondition: fn(_, _) { statem.Admit },
    next_model: fn(model, command) { predict_all(world, model, command) },
    new_sut: fn() { new_state(world) },
    execute: execute(world),
    finish: fn(_, _) { Ok(Nil) },
    teardown: fn(_) { Nil },
  )
}

// --- generating commands ----------------------------------------------------

// How far the head moves on a capture: none (the cut of an unmoved head), a
// few records, a page, and jumps past the window that leave the cut alone.
fn advance() -> qcheck.Generator(Int) {
  qcheck.bounded_int(0, 5)
  |> qcheck.map(fn(index) {
    case index {
      0 -> 0
      1 -> 7
      2 -> 60
      3 -> 101
      4 -> 400
      _ -> 1200
    }
  })
}

fn reply() -> qcheck.Generator(Reply) {
  qcheck.from_weighted_generators(#(6, qcheck.constant(Answer)), [
    #(2, qcheck.bounded_int(0, 3) |> qcheck.map(Replay)),
    #(1, qcheck.bounded_int(1, 3) |> qcheck.map(Skewed)),
  ])
}

// Weights are per hundred. Paging is the heart of the machine, so the whole
// gesture is the commonest command and its three parts also arrive alone,
// where a read can be left half-made. Resume and capture are what bring a
// reader back to a live cut, so they are frequent; a frozen capture needs a
// read first.
fn command() -> qcheck.Generator(Command) {
  qcheck.from_weighted_generators(#(12, qcheck.map(advance(), Capture)), [
    #(3, qcheck.constant(Freeze)),
    #(8, qcheck.constant(Resume)),
    #(7, qcheck.constant(Older)),
    #(6, qcheck.constant(Send)),
    #(10, qcheck.map(reply(), Page)),
    #(3, qcheck.constant(Cancel)),
    #(5, qcheck.bounded_int(0, 100) |> qcheck.map(Retain)),
    #(
      5,
      qcheck.map2(
        qcheck.bounded_int(0, 100),
        qcheck.from_generators(qcheck.constant(KnownCut), [
          qcheck.constant(KnownNothing),
        ]),
        ScanStart,
      ),
    ),
    #(4, qcheck.constant(ScanMore)),
    #(4, qcheck.constant(ScanSend)),
    #(5, qcheck.map(reply(), ScanPage)),
    #(2, qcheck.constant(ScanEnd)),
    #(18, qcheck.constant(ReadOlder)),
    #(4, qcheck.constant(ScanDrain)),
  ])
}

// --- the tests --------------------------------------------------------------

/// Runs of the light and of the heavy world, and the seeds they come from.
/// Each run is up to sixty commands, which a paging gesture makes into a
/// hundred or more primitive steps.
const light_runs = 120

const heavy_runs = 80

const longest_run = 60

const light_seed = 20_261_017

const heavy_seed = 20_261_018

fn check(world: World, runs: Int, seed: Int) -> Nil {
  let config =
    statem.default_config(seed:)
    |> statem.with_test_count(runs)
    |> statem.with_max_commands(longest_run)
  case statem.check(spec(world), config) {
    Ok(Nil) -> Nil
    Error(failure) -> panic as statem.report(failure, string.inspect)
  }
}

pub fn the_window_and_its_scan_keep_their_rules_in_a_light_world_test() {
  check(light(), light_runs, light_seed)
}

pub fn the_window_and_its_scan_keep_their_rules_in_a_heavy_world_test() {
  check(heavy(), heavy_runs, heavy_seed)
}

// --- witnesses --------------------------------------------------------------

// A scripted list run through the same steps, checks and model as a
// generated one, answering the state it reached. A passing check proves
// nothing about a bound no run reaches, so the tests below script the way to
// each bound and read the state.
fn drive(
  world: World,
  script: List(Command),
) -> #(history_view.State, Abstract) {
  let reached =
    list.try_fold(script, #(new_state(world), start(world)), fn(acc, command) {
      let #(state, model) = acc
      case run_steps(world, state, model, steps(world, model, command)) {
        Ok(next) -> Ok(#(next, predict_all(world, model, command)))
        Error(broken) -> Error(broken)
      }
    })
  case reached {
    Ok(done) -> done
    Error(broken) ->
      panic as { "script broke " <> broken.tag <> ": " <> broken.detail }
  }
}

// The cut at a head above the first long run of another strand's records, so
// a window can page down toward it, and paging a window to its record bound
// drops its newest end: the endpoint comes down to the newest record kept.
pub fn paging_a_light_window_reaches_the_record_bound_test() {
  let world = light()
  let #(state, model) =
    drive(world, [Capture(3400), ..list.repeat(ReadOlder, 8)])
  assert list.length(state.window.items) == window_records
  assert model.leaf < cut_of(world, model.head).0.hi
}

// A reader who paged six times holds 600 records with the newest few cut
// away, and the cut still meets what is left of the top. Returning to live
// output and capturing merges the two past 600, and this time the bound keeps
// the newest end and cuts the oldest: the opposite end from the one an
// accepted page cuts.
pub fn a_capture_after_deep_paging_keeps_the_newest_records_test() {
  let world = light()
  let #(state, model) =
    drive(world, [
      Capture(3400),
      ..list.append(list.repeat(ReadOlder, 6), [Resume, Capture(0)])
    ])
  let assert Some(run) = model.window
  assert list.length(state.window.items) == window_records
  assert model.leaf == cut_of(world, model.head).0.hi
  assert run.hi == model.leaf
  assert run.lo > 2585
}

// A page that finds none of the strand's records, because another strand
// wrote every sequence in it, lowers `before_seq` past the interval while the
// window stays where it was. A later capture that joins the window keeps that
// progress, or the next read would ask for the same empty interval again.
pub fn a_capture_keeps_the_progress_of_an_empty_page_test() {
  let world = light()
  let paged = [Capture(2300), ReadOlder, ReadOlder]
  let #(before, model) = drive(world, paged)
  let assert Some(run) = model.window
  assert state_floor(before) < run.lo
  let #(after, _) = drive(world, list.append(paged, [Resume, Capture(0)]))
  assert state_floor(after) == state_floor(before)
  assert state_floor(after) < oldest_of(after)
}

fn state_floor(state: history_view.State) -> Int {
  state.before_seq
}

fn oldest_of(state: history_view.State) -> Int {
  case list.last(state.window.items) {
    Ok(oldest) -> snapshot.sequence(oldest)
    Error(Nil) -> 0
  }
}

// A heavy page is trimmed by the decoder to 8 MiB, so the window fills its
// 16 MiB in a few pages and is cut at the newest end.
pub fn paging_a_heavy_window_reaches_the_byte_bound_test() {
  let world = heavy()
  let #(state, model) =
    drive(world, [Capture(1000), ReadOlder, ReadOlder, ReadOlder, ReadOlder])
  assert state.window.bytes <= window_bytes
  assert state.window.bytes > window_bytes - 1_000_000
  assert model.leaf < model.head
}

// A scan read to its end in the light world stops being readable a page short
// of its record bound, so it never has to cut.
pub fn a_light_scan_reads_down_to_its_record_bound_test() {
  let world = light()
  let #(state, _) =
    drive(world, [
      Capture(1200),
      Capture(1200),
      Capture(1200),
      Capture(1200),
      Capture(1200),
      Capture(1200),
      ScanStart(0, KnownNothing),
      ScanDrain,
    ])
  let assert history_view.Scanning(window:, ..) = state.scan
  assert list.length(window.items) > scan_records - 200
  assert list.length(window.items) <= scan_records
  assert !history_view.scan_readable(state, Some("parent"))
}

// A heavy scan is cut by its byte bound: a page that would take it past 32 MiB
// keeps the newest end and says it was cut.
pub fn a_heavy_scan_reaches_its_byte_bound_test() {
  let world = heavy()
  let #(state, _) =
    drive(world, [Capture(1000), ScanStart(0, KnownNothing), ScanDrain])
  let assert history_view.Scanning(window:, ..) = state.scan
  assert window.bytes <= scan_bytes
  assert window.bytes > scan_bytes - transfer_bytes
}

// Every kind of command is drawn in the first runs of a campaign.
pub fn the_generator_draws_every_kind_of_command_test() {
  let world = heavy()
  let config =
    statem.default_config(seed: heavy_seed)
    |> statem.with_max_commands(longest_run)
  let drawn =
    [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19]
    |> list.flat_map(statem.commands(spec(world), config, _))
    |> list.map(kind)
    |> list.unique
    |> list.sort(string.compare)
  assert drawn
    == [
      "Cancel", "Capture", "Freeze", "Older", "Page", "ReadOlder", "Resume",
      "Retain", "ScanDrain", "ScanEnd", "ScanMore", "ScanPage", "ScanSend",
      "ScanStart", "Send",
    ]
}

fn kind(command: Command) -> String {
  case command {
    Capture(_) -> "Capture"
    Freeze -> "Freeze"
    Resume -> "Resume"
    Older -> "Older"
    Send -> "Send"
    Page(_) -> "Page"
    Cancel -> "Cancel"
    Retain(_) -> "Retain"
    ScanStart(..) -> "ScanStart"
    ScanMore -> "ScanMore"
    ScanSend -> "ScanSend"
    ScanPage(_) -> "ScanPage"
    ScanEnd -> "ScanEnd"
    ReadOlder -> "ReadOlder"
    ScanDrain -> "ScanDrain"
  }
}
