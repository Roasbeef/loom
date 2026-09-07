//// The costing layer the adapters' `UsageCost(0.0, ...)` has always
//// pointed at: a per-model rate card, and the one pure function that
//// turns an adapter's token counts into dollars.
////
//// The adapters deliberately do not price anything. An adapter knows the
//// wire dialect, not the commercial arrangement behind the endpoint it is
//// speaking to — the same Anthropic dialect is spoken by first-party
//// Anthropic, by a reseller, and by a local proxy, at three different
//// prices. The rate card is therefore operator configuration
//// (`[models.<name>.pricing]` in `loom.toml`), and it is applied once, in
//// the gateway, at the point where an attempt's settlement leaves the
//// adapter and becomes the record the usage ledger stores.
////
//// ## What the rates mean
////
//// Every field is **US dollars per million tokens**, because that is the
//// unit every provider publishes its prices in; an operator copies the
//// number off the pricing page rather than converting it.
////
//// The four rates line up with `core/message.Usage`'s four token
//// buckets, and those buckets are *disjoint* by adapter contract:
//// `input` counts prompt tokens that were neither read from nor written
//// to the prompt cache, `cache_read` counts the tokens served from cache,
//// and `cache_write` counts the tokens written into it. Nothing is
//// double-counted, so the cost is a plain weighted sum, and
//// `reasoning`/`cache_write_1h` are subsets of buckets already priced and
//// are not charged again.

import core/message.{type Usage, Usage, UsageCost}
import gleam/int

/// One model's rate card, in US dollars per million tokens.
///
/// Constructor invariants: every rate is non-negative and finite. The
/// catalogue decoder is what enforces that, so a `Pricing` in hand is
/// already a valid rate card.
pub type Pricing {
  Pricing(
    /// Dollars per million uncached prompt tokens.
    input: Float,
    /// Dollars per million generated tokens (reasoning tokens included:
    /// providers bill them as output and `Usage.output` already contains
    /// them).
    output: Float,
    /// Dollars per million tokens served from the prompt cache.
    cache_read: Float,
    /// Dollars per million tokens written into the prompt cache.
    cache_write: Float,
  )
}

/// The zero rate card: a model with no `[models.<name>.pricing]` table.
///
/// Pricing an unpriced model is not an error, it costs nothing — which is
/// exactly what the harness recorded before this layer existed, so an
/// operator who annotates none of their models sees no change.
///
/// ## Examples
///
/// ```gleam
/// assert pricing.free().input == 0.0
/// ```
///
pub fn free() -> Pricing {
  Pricing(input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0)
}

/// Costs one usage against one rate card.
///
/// The four buckets are priced independently and `total` is their sum, so
/// a caller that adds two costed usages together gets the same number as
/// costing their summed tokens. Rounding is deliberately not applied: a
/// single call can cost a fraction of a cent, and rounding per call would
/// lose most of a session's spend to truncation.
///
/// ## Examples
///
/// ```gleam
/// let card = pricing.Pricing(3.0, 15.0, 0.3, 3.75)
/// let costed = pricing.price(usage, card)
/// // 1_000_000 input tokens at $3.00/M -> costed.cost.input == 3.0
/// ```
///
pub fn price(usage: Usage, card: Pricing) -> Usage {
  let input = per_million(usage.input, card.input)
  let output = per_million(usage.output, card.output)
  let cache_read = per_million(usage.cache_read, card.cache_read)
  let cache_write = per_million(usage.cache_write, card.cache_write)

  // The total is the sum of the four components rather than an
  // independently computed figure, so the breakdown always reconciles with
  // the headline the status bar shows.
  let total = input +. output +. cache_read +. cache_write
  Usage(
    ..usage,
    cost: UsageCost(input:, output:, cache_read:, cache_write:, total:),
  )
}

// A rate is quoted per million tokens; the division stays in floats so a
// few hundred tokens does not truncate to nothing.
fn per_million(tokens: Int, rate: Float) -> Float {
  int.to_float(tokens) *. rate /. 1_000_000.0
}
