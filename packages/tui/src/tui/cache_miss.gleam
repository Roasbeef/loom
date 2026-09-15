//// Recognising a prompt-cache miss from two consecutive usage rows.
////
//// A provider caches the prompt prefix for a bounded time. When a session
//// sits idle past that window the next request re-reads the whole prefix at
//// the uncached rate, and the only trace of it the terminal receives is the
//// shape of one `usage` row: the cached read collapses to nothing while the
//// input or cache-write bucket swells to roughly what used to be cached.
//// Nothing on the wire names the miss, and no TTL is needed to see it, so
//// this module reconstructs it from the pair of rows and the terminal's own
//// clock.
////
//// Everything here is arithmetic over two `Usage` values and two instants.
//// It holds no model and performs no I/O, which is what lets the thresholds
//// be tested over generated pairs rather than driven through a terminal, and
//// what keeps the detector out of the inliner's reach at `tui`'s call sites.
////
//// The dollar figure is derived from the two rows' own cost buckets rather
//// than from a price table, because the terminal has no price table: the
//// server prices every response before it emits the row. A model with no
//// pricing configured reports all-zero costs, which is not an error — it is
//// simply unpriced, and the notice then omits the money.

import core/message.{type Usage}
import gleam/bool
import gleam/float
import gleam/int
import gleam/option.{type Option, None, Some}

/// The shortest idle gap that can produce this notice.
///
/// The row is about time the operator spent away, not about a cache that
/// rolled between two back-to-back turns. A minute is well under every
/// provider's cache lifetime, so anything shorter than this which still
/// looks like a miss is a prefix change — a compaction, a branch switch —
/// and naming that "idle" would be a lie.
pub const idle_floor_ms = 60_000

/// The smallest cached prefix whose loss is worth a row.
///
/// Ten thousand tokens is a few cents at any current price and is already
/// past the size of an opening turn, so this floor is what stops a session's
/// first exchange, where the cache is legitimately cold, from reporting a
/// miss on every second prompt.
pub const cached_prefix_floor = 10_000

// How far the cached read must fall to count as collapsed.
//
// A quarter of the previous read is far below any partial-prefix hit: a
// provider that still holds the prefix returns nearly all of it, and one
// that lost it returns a handful of system tokens or none. The gap between
// those two outcomes is wide, so the threshold does not need to be tight.
const collapse_divisor = 4

// How much of the lost prefix must reappear as uncached tokens.
//
// A miss re-reads the prefix, so the tokens it lost must turn up in this
// request's input or cache-write bucket. Requiring half of them is what
// separates a miss from a genuinely shorter request — a fresh strand, a
// compacted context — which reads little and bills little.
const reread_divisor = 2

/// The last usage row seen on one strand and when it arrived.
///
/// This is the whole of the detector's memory. Its holder keys it per
/// strand, because a sub-agent's request says nothing about whether the
/// primary's prefix survived.
pub type Watch {
  Watch(
    /// The most recent row that read or wrote provider context.
    previous: Usage,
    /// The terminal-clock instant, in milliseconds, at which it arrived.
    previous_at: Int,
  )
}

/// A prompt-cache miss reconstructed from two usage rows.
pub type CacheMiss {
  CacheMiss(
    /// How long the strand sat between the two requests, in milliseconds.
    idle_ms: Int,
    /// Tokens of cached prefix billed again, never more than the prefix the
    /// previous request actually read.
    tokens: Int,
    /// The extra dollars the re-read cost, or `None` when either row came
    /// from an unpriced model.
    estimate: Option(Float),
  )
}

/// Folds one usage row into a strand's watch, reporting any miss it reveals.
///
/// The caller holds the watch per strand and replaces it with the returned
/// one. A row that neither read nor wrote provider context is a bookkeeping
/// adjustment rather than a request, so it leaves the watch standing: taking
/// it as the baseline would compare the next real request against zero.
///
/// ## Examples
///
/// ```gleam
/// observe(None, first_row, 0)
/// // -> #(None, Some(Watch(first_row, 0)))
/// ```
pub fn observe(
  watch: Option(Watch),
  usage: Usage,
  at: Int,
) -> #(Option(CacheMiss), Option(Watch)) {
  case reads_context(usage), watch {
    // An adjustment carries no request of its own to compare against, so
    // the baseline the next real request needs is the one already held.
    False, held -> #(None, held)

    // The first request of a strand has nothing before it; it becomes the
    // baseline and reports nothing.
    True, None -> #(None, Some(Watch(previous: usage, previous_at: at)))

    True, Some(held) -> #(
      detect(held.previous, held.previous_at, usage, at),
      Some(Watch(previous: usage, previous_at: at)),
    )
  }
}

/// Whether a usage row describes a provider request rather than an adjustment.
///
/// The wire event carries the `Usage` alone, without the ledger row's own
/// adjustment flag, so the shape of the counts is what distinguishes the
/// two: every real request reads or writes context, and a caller-supplied
/// correction reads none.
///
/// ## Examples
///
/// ```gleam
/// reads_context(row_that_read_a_prefix)
/// // -> True
/// ```
pub fn reads_context(usage: Usage) -> Bool {
  usage.input + usage.cache_read + usage.cache_write > 0
}

/// Decides whether two consecutive rows on one strand describe a cache miss.
///
/// All four conditions must hold together: the gap is idle time rather than
/// a turn boundary, the previous request read a prefix large enough to be
/// worth reporting, this request's cached read collapsed, and the lost
/// prefix reappeared as uncached tokens. Any one of them alone has innocent
/// causes.
///
/// ## Examples
///
/// ```gleam
/// detect(read_250k, 0, wrote_250k, 540_000)
/// // -> Some(CacheMiss(idle_ms: 540_000, tokens: 250_000, estimate: ..))
/// ```
pub fn detect(
  previous: Usage,
  previous_at: Int,
  current: Usage,
  current_at: Int,
) -> Option(CacheMiss) {
  let idle_ms = current_at - previous_at
  use <- bool.guard(when: idle_ms < idle_floor_ms, return: None)
  use <- bool.guard(
    when: previous.cache_read < cached_prefix_floor,
    return: None,
  )

  // The cached read has to have collapsed relative to the prefix that was
  // held, and the tokens it stopped covering have to have been billed
  // somewhere. Without the second half, any short request after a pause
  // would report a miss it did not suffer.
  let held = previous.cache_read
  use <- bool.guard(
    when: current.cache_read * collapse_divisor >= held,
    return: None,
  )
  let re_read = current.cache_write + current.input
  use <- bool.guard(when: re_read * reread_divisor < held, return: None)

  // The prefix is the ceiling on what the miss can have cost. A request that
  // also carries new work bills more than this, and that excess was never
  // cached, so it is not part of what the pause lost.
  let tokens = int.min(re_read, held)
  Some(CacheMiss(
    idle_ms:,
    tokens:,
    estimate: estimate(previous, current, tokens),
  ))
}

/// Renders an idle gap the way an operator reads a clock.
///
/// Seconds below a minute, whole minutes below an hour, then hours with the
/// remaining minutes beside them. A gap that reaches a notice is always at
/// least `idle_floor_ms`, so the seconds form exists for callers testing the
/// boundary rather than for the row.
///
/// ## Examples
///
/// ```gleam
/// idle_label(4_320_000)
/// // -> "1h 12m"
/// ```
pub fn idle_label(idle_ms: Int) -> String {
  let seconds = int.max(0, idle_ms) / 1000
  let minutes = seconds / 60
  let hours = minutes / 60
  case hours > 0, minutes > 0 {
    True, _ -> int.to_string(hours) <> "h" <> trailing_minutes(minutes % 60)
    False, True -> int.to_string(minutes) <> "m"
    False, False -> int.to_string(seconds) <> "s"
  }
}

// An hour on the nose reads better as "1h" than as "1h 0m", and the minutes
// are the part a reader of an hours-long gap cares least about.
fn trailing_minutes(minutes: Int) -> String {
  case minutes {
    0 -> ""
    count -> " " <> int.to_string(count) <> "m"
  }
}

// What the re-read cost above what the cached prefix would have cost.
//
// Both rates come from the rows themselves, so a model priced at any scale
// answers in its own currency and an unpriced one answers not at all. The
// floor at zero covers the pathological ordering where a provider prices a
// cached read above fresh input: the operator lost nothing there, and a
// negative figure in a cost notice would only confuse.
fn estimate(previous: Usage, current: Usage, tokens: Int) -> Option(Float) {
  use input_rate <- option.then(uncached_rate(current))
  use cached_rate <- option.then(rate(
    previous.cost.cache_read,
    previous.cache_read,
  ))
  Some(float.max(0.0, int.to_float(tokens) *. { input_rate -. cached_rate }))
}

// The rate the re-read was billed at. A provider that returns the prefix as
// a fresh cache write bills it in that bucket and leaves input near zero, so
// the bucket that actually carried the tokens is the one to divide.
fn uncached_rate(current: Usage) -> Option(Float) {
  case current.input > 0 {
    True -> rate(current.cost.input, current.input)
    False -> rate(current.cost.cache_write, current.cache_write)
  }
}

// A dollars-per-token rate, or nothing when the division is not defined.
//
// A zero cost against a non-zero count is an unpriced model rather than a
// free one, and a zero count is a bucket this request never used. Neither
// can produce a rate, and guarding both here is what keeps every divisor in
// this module non-zero.
fn rate(cost: Float, tokens: Int) -> Option(Float) {
  case cost >. 0.0 && tokens > 0 {
    True -> Some(cost /. int.to_float(tokens))
    False -> None
  }
}
