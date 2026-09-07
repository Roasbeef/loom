//// The costing function, in isolation from the gateway that applies it.
////
//// Every rate is quoted per million tokens, so the fixtures use round
//// million-token counts wherever an exact equality is asserted: a million
//// tokens at $3.00/M is exactly $3.00 in binary floating point, while a
//// fractional-cent result is not exactly anything a literal can spell.

import core/message
import gleam/option.{None}
import provider/pricing

// --- fixtures ---------------------------------------------------------------

fn usage(
  input: Int,
  output: Int,
  cache_read: Int,
  cache_write: Int,
) -> message.Usage {
  message.Usage(
    input:,
    output:,
    cache_read:,
    cache_write:,
    cache_write_1h: None,
    reasoning: None,
    total_tokens: input + output + cache_read + cache_write,
    cost: message.UsageCost(
      input: 0.0,
      output: 0.0,
      cache_read: 0.0,
      cache_write: 0.0,
      total: 0.0,
    ),
  )
}

// Rates chosen to be exactly representable so the assertions can be
// equalities rather than tolerances. The shape is Kimi K3's real card
// (`docs/examples/loom.toml`) with the cache rates rounded to whole
// dollars.
fn card() -> pricing.Pricing {
  pricing.Pricing(input: 3.0, output: 15.0, cache_read: 1.0, cache_write: 2.0)
}

// --- costing ----------------------------------------------------------------

pub fn each_bucket_is_priced_at_its_own_rate_test() {
  let costed =
    pricing.price(usage(1_000_000, 2_000_000, 4_000_000, 500_000), card())
  assert costed.cost.input == 3.0
  assert costed.cost.output == 30.0
  assert costed.cost.cache_read == 4.0
  assert costed.cost.cache_write == 1.0
}

pub fn the_total_is_the_sum_of_the_four_buckets_test() {
  let costed =
    pricing.price(usage(1_000_000, 2_000_000, 4_000_000, 500_000), card())
  let message.UsageCost(input:, output:, cache_read:, cache_write:, total:) =
    costed.cost
  assert total == input +. output +. cache_read +. cache_write
  assert total == 38.0
}

pub fn pricing_leaves_the_token_counts_alone_test() {
  // Costing rewrites the cost and nothing else: the ledger's token
  // arithmetic must not change under it.
  let before = usage(10, 4, 2, 1)
  let after = pricing.price(before, card())
  assert after.input == before.input
  assert after.output == before.output
  assert after.cache_read == before.cache_read
  assert after.cache_write == before.cache_write
  assert after.total_tokens == before.total_tokens
}

pub fn a_zero_usage_costs_nothing_test() {
  let costed = pricing.price(usage(0, 0, 0, 0), card())
  assert costed.cost.total == 0.0
}

pub fn an_unpriced_model_costs_nothing_test() {
  // The free card is what an absent `[models.<name>.pricing]` table means,
  // and it must leave the record indistinguishable from the zeros the
  // adapters write.
  let costed =
    pricing.price(usage(500_000, 250_000, 100_000, 0), pricing.free())
  assert costed.cost
    == message.UsageCost(
      input: 0.0,
      output: 0.0,
      cache_read: 0.0,
      cache_write: 0.0,
      total: 0.0,
    )
}

pub fn sub_million_token_counts_do_not_truncate_to_zero_test() {
  // The failure this guards against is integer division: a few thousand
  // tokens is a fraction of a cent, and a costing layer that floors it
  // reports nothing for a whole session of small calls.
  let costed = pricing.price(usage(1000, 0, 0, 0), card())
  assert costed.cost.total >. 0.0
  assert costed.cost.total <. 0.01
}
