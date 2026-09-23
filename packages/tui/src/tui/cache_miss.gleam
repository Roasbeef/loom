//// The prompt cache as the terminal sees it: a miss it reconstructs,
//// and the published TTL boundary it can now warn about.
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
//// The same rows carry the forward-looking fact too. A provider that
//// reports a positive `cache_write_1h` bills one-hour retention, which only the
//// Anthropic dialect's split breakpoints produce, so that bucket is the
//// evidence for a five-minute tail and one-hour head; a provider that
//// reports none gets an idle-age label that never claims an expiry it
//// cannot know. Both readings stay here, in arithmetic over `Usage`
//// values and instants, so the thresholds are tested over generated rows
//// rather than driven through a terminal.
////
//// Everything here is arithmetic over `Usage` values and instants. It
//// holds no model and performs no I/O, which is what lets the thresholds
//// be tested over generated pairs rather than driven through a terminal,
//// and what keeps the detector out of the inliner's reach at `tui`'s call
//// sites.
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

/// The split cache's published minimum rolling-tail lifetime.
///
/// The Anthropic Messages API keeps an un-priced `ephemeral` breakpoint
/// for five minutes from its most recent write, and one hour for the
/// session-stable head's `ttl: "1h"` breakpoint. These are the horizons a
/// proven `cache_write_1h` row licenses the outlook to count down from. The
/// terminal receives usage after the request settles, while provider TTLs
/// start when the request begins. A countdown from settlement is therefore
/// an upper bound on time to the published minimum TTL boundary, never a
/// promise that the prefix is warm or that it expires at that boundary.
pub const tail_lifetime_ms = 300_000

/// The split cache's published minimum session-head lifetime.
pub const head_lifetime_ms = 3_600_000

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

/// The last usage row seen on one strand, when it arrived, and what that
/// row revealed about the provider's cache horizon.
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
    /// Whether the provider has been observed to report one-hour cache
    /// writes. The horizon is sticky: once any row on the strand carried a
    /// one-hour write, later rows from the same provider cannot un-report
    /// it, so the label keeps the horizon it already learned rather than
    /// flapping back to the idle form on a row that happened to write
    /// nothing new.
    hour_head: HourHead,
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

/// Whether a provider is known to hold an hour-long cache head.
///
/// Only a row that reports positive `cache_write_1h` proves the provider bills
/// one-hour retention, because that bucket exists solely for the
/// Anthropic dialect's `ttl: "1h"` breakpoints. Every other dialect —
/// and an Anthropic row that wrote nothing to the head this turn —
/// reports `None` or zero, which is the absence of the fact rather than a denial
/// of it, so the horizon stays sticky once learned.
pub type HourHead {
  /// No row on this strand has reported a one-hour write.
  Unproven

  /// Some row has, so the strand's prefix is covered by the split
  /// five-minute tail and one-hour head.
  Split
}

/// What the operator can be told about the active strand's cache before
/// the next prompt pays for it.
///
/// This is the forward-looking counterpart of `CacheMiss`: the miss
/// reports what a pause already cost, the outlook reports what a pause
/// is about to cost. Everything it says is derived from one `Watch` and
/// the terminal's own clock, so a label is honest about exactly as much
/// as the rows have revealed and never guesses a provider it has not
/// billed.
pub type Outlook {
  /// The strand has not yet held a prefix worth a label: its last row
  /// read and wrote less than `cached_prefix_floor`, or no row has
  /// arrived at all.
  Unheld

  /// The tail's minimum TTL boundary has passed; this many milliseconds
  /// remain at most until the head's minimum TTL boundary.
  Head(remaining_ms: Int)

  /// This many milliseconds remain at most until the split tail's minimum
  /// TTL boundary. The provider may retain the entry past that boundary.
  Held(remaining_ms: Int)

  /// The elapsed idle time for a provider whose TTL the rows have not
  /// established. It is an age, never a countdown.
  Idle(elapsed_ms: Int)

  /// The upper bound on the minimum TTL boundary has elapsed. The next
  /// request may still hit an entry retained beyond that boundary.
  /// An unproven provider never reports this.
  Expired
}

/// Folds one usage row into a strand's watch, reporting any miss it reveals.
///
/// The caller holds the watch per strand and replaces it with the returned
/// one. A row that neither read nor wrote provider context is a bookkeeping
/// adjustment rather than a request, so it leaves the watch standing: taking
/// it as the baseline would compare the next real request against zero.
///
/// The watch's cache horizon is learned from the row and sticky once
/// learned: a positive `cache_write_1h` proves the one-hour split, and its absence
/// on a later row is not a denial of it, so an established horizon is
/// carried forward rather than reset.
///
/// ## Examples
///
/// ```gleam
/// observe(None, first_row, 0)
/// // -> #(None, Some(Watch(previous: first_row, previous_at: 0, hour_head: Unproven)))
/// ```
pub fn observe(
  watch: Option(Watch),
  usage: Usage,
  at: Int,
) -> #(Option(CacheMiss), Option(Watch)) {
  let hour_head = case watch {
    Some(held) -> held.hour_head
    None -> Unproven
  }
  let hour_head = case usage.cache_write_1h {
    Some(count) if count > 0 -> Split
    Some(_) | None -> hour_head
  }
  case reads_context(usage), watch {
    // An adjustment carries no request of its own to compare against, so
    // the baseline the next real request needs is the one already held.
    False, held -> #(None, held)

    // The first request of a strand has nothing before it; it becomes the
    // baseline and reports nothing.
    True, None -> #(
      None,
      Some(Watch(previous: usage, previous_at: at, hour_head: hour_head)),
    )

    True, Some(held) -> #(
      detect(held.previous, held.previous_at, usage, at),
      Some(Watch(previous: usage, previous_at: at, hour_head: hour_head)),
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
@internal
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

// The rate the re-read was billed at. A real miss carries a handful of
// uncached input tokens alongside the whole re-read, which a provider bills
// as a fresh cache write, so picking the bucket with the larger count is
// what selects the one that actually carried the re-read rather than the
// input trickle that rides along with it.
fn uncached_rate(current: Usage) -> Option(Float) {
  case current.cache_write > current.input {
    True -> rate(current.cost.cache_write, current.cache_write)
    False -> rate(current.cost.input, current.input)
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

/// What the active strand's cache holds, as of one instant on the caller's
/// clock.
///
/// `None` means no watch stands — the terminal has not seen a usage row
/// for this strand — and the caller renders nothing rather than a label
/// that would guess. The horizon comes from the watch rather than from the
/// clock: a proven split counts down the five-minute tail and then the
/// one-hour head; an unproven provider only ever reports how long the
/// strand has been idle past the notice floor, never an expiry moment
/// nothing established.
///
/// ## Examples
///
/// ```gleam
/// outlook(None, 0)
/// // -> None
/// ```
pub fn outlook(watch: Option(Watch), now: Int) -> Option(Outlook) {
  use held <- option.then(watch)
  use <- bool.lazy_guard(
    when: int.max(held.previous.cache_read, held.previous.cache_write)
      < cached_prefix_floor,
    return: fn() { Some(Unheld) },
  )

  let idle_ms = now - held.previous_at
  Some(case held.hour_head {
    Split ->
      case idle_ms < tail_lifetime_ms {
        True -> Held(tail_lifetime_ms - idle_ms)
        False ->
          case idle_ms < head_lifetime_ms {
            True -> Head(head_lifetime_ms - idle_ms)
            False -> Expired
          }
      }

    // No horizon was proven, so there is no moment at which the cache
    // provably rolls. The idle age is the honest reading, and it is only
    // worth a label once it clears the floor a miss would clear.
    Unproven ->
      case idle_ms > idle_floor_ms {
        True -> Idle(idle_ms)
        False -> Unheld
      }
  })
}

/// The outlook as the footer reads it.
///
/// A proven split gives an upper bound on time to the minimum TTL boundary:
/// `cache tail ≤3m`, then `cache head ≤42m`, then
/// `cache TTL elapsed`. An unproven provider shows only elapsed idle time,
/// such as `cache idle 10m`. None of these labels promises a cache hit.
///
/// The seconds form exists only for the final stretch of a countdown: a
/// reader deciding whether to send now does not care about seconds until
/// there is under a minute of cache left to lose.
///
/// ## Examples
///
/// ```gleam
/// assert outlook_label(Held(180_000)) == "cache tail ≤3m"
/// ```
pub fn outlook_label(outlook: Outlook) -> String {
  case outlook {
    Unheld -> ""
    Expired -> "cache TTL elapsed"
    Head(remaining_ms) -> "cache head ≤" <> remaining_label(remaining_ms)
    Held(remaining_ms) -> "cache tail ≤" <> remaining_label(remaining_ms)
    Idle(elapsed_ms) -> "cache idle " <> idle_label(elapsed_ms)
  }
}

// Round a TTL upper bound upward. Rounding down would turn 3m 59s into a
// false claim that no more than 3m remains.
fn remaining_label(remaining_ms: Int) -> String {
  case remaining_ms > 60_000 {
    True -> {
      let rounded = remaining_ms + 59_999
      int.to_string(rounded / 60_000) <> "m"
    }
    False -> {
      let rounded = int.max(0, remaining_ms) + 999
      int.to_string(rounded / 1000) <> "s"
    }
  }
}
