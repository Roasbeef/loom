//// The prompt-cache miss detector, over generated pairs of usage rows.
////
//// Every test here drives `tui/cache_miss` alone: the detector is pure
//// arithmetic over two rows and two instants, so its thresholds can be
//// swept rather than sampled. The sweeps stand in for a property-based
//// framework, which this package does not depend on.

import core/message
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import tui/cache_miss

// Anthropic's published per-token rates for a mid-sized model, which is the
// shape the detector was written against: a cached read costs a tenth of
// fresh input, and a cache write costs a quarter more than it.
const input_rate = 0.000003

const cached_rate = 0.0000003

const write_rate = 0.00000375

// A priced usage row. Every cost bucket is the count at the rate above, so
// a test that changes a count changes its price with it.
fn row(input: Int, cache_read: Int, cache_write: Int) -> message.Usage {
  message.Usage(
    input:,
    output: 400,
    cache_read:,
    cache_write:,
    cache_write_1h: None,
    reasoning: None,
    total_tokens: input + cache_read + cache_write + 400,
    cost: message.UsageCost(
      input: int.to_float(input) *. input_rate,
      output: 0.006,
      cache_read: int.to_float(cache_read) *. cached_rate,
      cache_write: int.to_float(cache_write) *. write_rate,
      total: 0.0,
    ),
  )
}

// The same counts from a model with no configured pricing, which the server
// prices at zero rather than refusing.
fn unpriced(usage: message.Usage) -> message.Usage {
  message.Usage(
    ..usage,
    cost: message.UsageCost(
      input: 0.0,
      output: 0.0,
      cache_read: 0.0,
      cache_write: 0.0,
      total: 0.0,
    ),
  )
}

// The canonical Anthropic miss: a quarter-million token prefix was cached,
// the pause outlived the cache, and the whole prefix came back as a write.
fn held_prefix() -> message.Usage {
  row(12, 250_000, 0)
}

fn re_read_prefix() -> message.Usage {
  row(12, 0, 250_000)
}

fn nine_minutes() -> Int {
  9 * 60 * 1000
}

pub fn a_gap_under_the_floor_never_fires_test() {
  each_int(0, 59, fn(seconds) {
    assert cache_miss.detect(held_prefix(), 0, re_read_prefix(), seconds * 1000)
      == None
  })

  // The floor itself is inside the notice, so the sweep above stops one
  // second short of a miss rather than short of the whole detector.
  assert cache_miss.detect(
      held_prefix(),
      0,
      re_read_prefix(),
      cache_miss.idle_floor_ms,
    )
    != None
}

pub fn a_prefix_that_held_never_fires_test() {
  each_int(1, 20, fn(step) {
    let held = step * 25_000

    // A cache hit returns the whole prefix and writes only the new turn.
    assert cache_miss.detect(
        row(12, held, 0),
        0,
        row(12, held, 2000),
        3_600_000,
      )
      == None

    // A partial hit at exactly the collapse threshold is still a hit.
    assert cache_miss.detect(
        row(12, held, 0),
        0,
        row(12, held / 4, held),
        3_600_000,
      )
      == None
  })
}

pub fn a_prefix_below_the_floor_never_fires_test() {
  each_int(1, 9, fn(step) {
    let held = step * 1000
    assert cache_miss.detect(row(12, held, 0), 0, row(12, 0, held), 3_600_000)
      == None
  })
}

pub fn a_short_request_after_a_pause_never_fires_test() {
  // The prefix vanished from the cached bucket but nothing re-read it: a
  // compaction or a fresh branch, not a miss the operator paid for.
  assert cache_miss.detect(held_prefix(), 0, row(4000, 0, 0), 3_600_000) == None
}

pub fn the_canonical_anthropic_shapes_fire_test() {
  let assert Some(five_minute) =
    cache_miss.detect(held_prefix(), 0, re_read_prefix(), nine_minutes())
    as "a nine-minute pause past a five-minute cache is a miss"
  assert five_minute.idle_ms == nine_minutes()
  assert five_minute.tokens == 250_000
  assert cache_miss.idle_label(five_minute.idle_ms) == "9m"

  let assert Some(one_hour) =
    cache_miss.detect(held_prefix(), 0, re_read_prefix(), 72 * 60 * 1000)
    as "a seventy-two minute pause past a one-hour cache is a miss"
  assert one_hour.tokens == 250_000
  assert cache_miss.idle_label(one_hour.idle_ms) == "1h 12m"

  // The re-read landed in the write bucket, so the estimate is the whole
  // prefix at the cache-write rate less what the cached read would have
  // cost.
  let assert Some(estimate) = five_minute.estimate as "both rows are priced"
  assert float.loosely_equals(estimate, 0.8625, tolerating: 0.0001)
}

pub fn the_token_figure_never_exceeds_the_cached_prefix_test() {
  let held = 200_000
  each_int(1, 8, fn(step) {
    let re_read = step * 50_000
    let miss =
      cache_miss.detect(row(12, held, 0), 0, row(re_read, 0, 0), 600_000)
    case re_read * 2 >= held {
      // The lost prefix reappeared as uncached input, so the detector must
      // fire, and the tokens it reports are capped at the prefix that was
      // actually held.
      True -> {
        let assert Some(fired) = miss
          as "a re-read past half the held prefix is a miss"
        assert fired.tokens <= held
        assert fired.tokens == int.min(re_read, held)
      }

      // Below half, the request reads too little to have been the prefix
      // coming back, so it must not be reported as a miss at all.
      False -> {
        assert miss == None
      }
    }
  })
}

pub fn an_unpriced_row_on_either_side_omits_the_estimate_test() {
  let priced_pair = [
    #(held_prefix(), re_read_prefix()),
    #(held_prefix(), row(250_000, 0, 0)),
  ]
  list.each(priced_pair, fn(pair) {
    assert estimate_of(unpriced(pair.0), pair.1) == None
    assert estimate_of(pair.0, unpriced(pair.1)) == None
    assert estimate_of(unpriced(pair.0), unpriced(pair.1)) == None
    assert estimate_of(pair.0, pair.1) != None
  })
}

pub fn the_estimate_is_never_negative_test() {
  // A cached read priced above fresh input is not a rate any provider
  // publishes, but the subtraction must not put a negative dollar figure in
  // front of an operator if one ever appears.
  let inverted =
    message.Usage(
      ..held_prefix(),
      cost: message.UsageCost(
        input: 0.0,
        output: 0.0,
        cache_read: 10.0,
        cache_write: 0.0,
        total: 10.0,
      ),
    )
  let assert Some(estimate) = estimate_of(inverted, re_read_prefix())
    as "both rows are priced"
  assert estimate == 0.0
}

pub fn an_adjustment_row_leaves_the_baseline_standing_test() {
  let #(first, watch) = cache_miss.observe(None, held_prefix(), 0)
  assert first == None

  // A row with no context of its own must not become the baseline: the
  // real request after it would then be compared against nothing.
  let adjustment = row(0, 0, 0)
  assert !cache_miss.reads_context(adjustment)
  let #(second, watch) = cache_miss.observe(watch, adjustment, 60_000)
  assert second == None

  let #(third, _) = cache_miss.observe(watch, re_read_prefix(), 600_000)
  let assert Some(miss) = third
    as "the adjustment kept the cached prefix as the baseline"
  assert miss.tokens == 250_000
}

pub fn the_idle_label_reads_as_a_clock_test() {
  assert cache_miss.idle_label(45_000) == "45s"
  assert cache_miss.idle_label(nine_minutes()) == "9m"
  assert cache_miss.idle_label(60 * 60 * 1000) == "1h"
  assert cache_miss.idle_label(4_320_000) == "1h 12m"
  assert cache_miss.idle_label(-5000) == "0s"
}

// One Anthropic row: the same priced counts as `row`, with the cache write
// split reporting the one-hour head. Only the split's presence matters to
// the outlook, so the head's share of the write is a small stand-in.
fn split_row(input: Int, cache_read: Int, cache_write: Int) -> message.Usage {
  message.Usage(
    ..row(input, cache_read, cache_write),
    cache_write_1h: Some(1000),
  )
}

// A watch that read a held prefix at time zero under the stated horizon.
fn held_watch(horizon: cache_miss.HourHead) -> cache_miss.Watch {
  let usage = case horizon {
    cache_miss.Unproven -> held_prefix()
    cache_miss.Split -> split_row(12, 250_000, 0)
  }
  let assert #(_, Some(watch)) = cache_miss.observe(None, usage, 0)
  watch
}

pub fn the_horizon_is_learned_once_and_never_unlearned_test() {
  // A first row without the split leaves the horizon unproven, and the
  // split row then proves it once and for all.
  let #(_, first) = cache_miss.observe(None, held_prefix(), 0)
  assert first
    == Some(cache_miss.Watch(
      previous: held_prefix(),
      previous_at: 0,
      hour_head: cache_miss.Unproven,
    ))

  // Anthropic reports an explicit zero when the one-hour head wrote no
  // tokens. Its presence identifies a field, not a retained head.
  let zero = message.Usage(..held_prefix(), cache_write_1h: Some(0))
  let #(_, unproven) = cache_miss.observe(first, zero, 30_000)
  let assert Some(unproven_watch) = unproven
  assert unproven_watch.hour_head == cache_miss.Unproven

  let #(_, learned) =
    cache_miss.observe(unproven, split_row(0, 250_000, 0), 60_000)
  assert learned
    == Some(cache_miss.Watch(
      previous: split_row(0, 250_000, 0),
      previous_at: 60_000,
      hour_head: cache_miss.Split,
    ))

  // A later row without the bucket cannot un-report the head, because its
  // absence is not a denial: the provider simply wrote nothing new there.
  let #(_, kept) = cache_miss.observe(learned, held_prefix(), 120_000)
  let assert Some(watch) = kept
  assert watch.hour_head == cache_miss.Split
}

pub fn a_proven_split_counts_down_the_tail_then_the_head_test() {
  let watch = held_watch(cache_miss.Split)

  // Inside the tail: the whole prefix is held, and the countdown reads as
  // the tail's remaining time.
  assert cache_miss.outlook(Some(watch), 60_000)
    == Some(cache_miss.Held(remaining_ms: 240_000))
  assert cache_miss.outlook_label(cache_miss.Held(240_000)) == "cache tail ≤4m"

  // Past the tail, inside the hour: only the head still holds.
  assert cache_miss.outlook(Some(watch), 300_000)
    == Some(cache_miss.Head(remaining_ms: 3_300_000))
  assert cache_miss.outlook_label(cache_miss.Head(3_300_000))
    == "cache head ≤55m"

  // Past the hour: nothing holds, and the label says so plainly.
  assert cache_miss.outlook(Some(watch), 3_600_000) == Some(cache_miss.Expired)
  assert cache_miss.outlook_label(cache_miss.Expired) == "cache TTL elapsed"

  // The final minute of a countdown reads in seconds, because that is the
  // resolution a send-now decision is made at.
  assert cache_miss.outlook_label(cache_miss.Held(45_000)) == "cache tail ≤45s"
  assert cache_miss.outlook_label(cache_miss.Head(30_000)) == "cache head ≤30s"

  // A displayed upper bound rounds up. The provider started its TTL before
  // the terminal received this usage row, so a shorter claim would be false.
  assert cache_miss.outlook_label(cache_miss.Held(239_999)) == "cache tail ≤4m"
  assert cache_miss.outlook_label(cache_miss.Head(29_001)) == "cache head ≤30s"
}

pub fn an_unproven_provider_only_reports_its_growing_idle_age_test() {
  let watch = held_watch(cache_miss.Unproven)

  // Nothing has been established about this provider's TTL, so there is no
  // expiry moment to name: under the floor the label says nothing at all.
  assert cache_miss.outlook(Some(watch), 30_000) == Some(cache_miss.Unheld)
  assert cache_miss.outlook_label(cache_miss.Unheld) == ""

  // Past the floor the honest reading is the pause's age, which grows
  // without end and never turns into "expired" on its own.
  assert cache_miss.outlook(Some(watch), nine_minutes())
    == Some(cache_miss.Idle(elapsed_ms: nine_minutes()))
  assert cache_miss.outlook_label(cache_miss.Idle(nine_minutes()))
    == "cache idle 9m"
  assert cache_miss.outlook(Some(watch), 24 * 3_600_000)
    == Some(cache_miss.Idle(elapsed_ms: 86_400_000))
}

pub fn a_small_prefix_or_no_watch_gives_no_label_test() {
  // A prefix under the floor is not worth a label: the reading the footer
  // would draw would cost more cells than the pause costs cents.
  let assert #(_, Some(small)) = cache_miss.observe(None, row(4, 4000, 0), 0)
  assert cache_miss.outlook(Some(small), nine_minutes())
    == Some(cache_miss.Unheld)

  // No watch at all means no row was ever seen, and the caller renders
  // nothing rather than a guess.
  assert cache_miss.outlook(None, 0) == None
}

// A closed integer sweep. `int.range` is a fold with an exclusive upper
// bound, and every sweep here is written as an inclusive range of cases.
fn each_int(from: Int, to: Int, run: fn(Int) -> Nil) -> Nil {
  int.range(from:, to: to + 1, with: Nil, run: fn(_, value) { run(value) })
}

fn estimate_of(
  previous: message.Usage,
  current: message.Usage,
) -> Option(Float) {
  case cache_miss.detect(previous, 0, current, 600_000) {
    None -> None
    Some(miss) -> miss.estimate
  }
}
