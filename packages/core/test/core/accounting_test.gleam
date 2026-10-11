//// A request aggregate differs from its final context observation.
//// These tests preserve cache and reasoning subsets while varying evidence,
//// pricing availability, and the existing durable details payload.

import core/accounting
import core/clock
import core/codec
import core/entry
import core/ids
import core/json
import core/message
import core/usage_evidence as evidence
import gleam/list
import gleam/option.{type Option, None, Some}

fn first() -> message.Usage {
  message.Usage(
    input: 80,
    output: 20,
    cache_read: 30,
    cache_write: 10,
    cache_write_1h: Some(4),
    reasoning: Some(7),
    total_tokens: 140,
    cost: message.UsageCost(0.8, 0.4, 0.03, 0.1, 1.33),
    evidence: evidence.with_price(
      evidence.reported(evidence.Api),
      evidence.ApiRates,
    ),
  )
}

fn last() -> message.Usage {
  message.Usage(
    input: 50,
    output: 10,
    cache_read: 40,
    cache_write: 5,
    cache_write_1h: None,
    reasoning: Some(3),
    total_tokens: 105,
    cost: message.UsageCost(0.25, 0.2, 0.04, 0.05, 0.54),
    evidence: evidence.with_price(
      evidence.reported(evidence.ChatGptPlan),
      evidence.ChatGptReferenceRates,
    ),
  )
}

fn row(
  usage: message.Usage,
  details: Option(json.JsonValue),
) -> entry.UsageRow {
  let #(id, _) = ids.mint_usage(ids.generator(clock.fixed(at: 1), seed: 9))
  entry.UsageRow(
    id:,
    seq: 1,
    entry_id: None,
    adjustment: False,
    usage:,
    details:,
  )
}

pub fn accounting_empty_identity_and_final_observation_test() {
  let report =
    accounting.empty()
    |> accounting.append(first())
    |> accounting.append(last())
  let total = accounting.total(report)
  assert accounting.attempts(report) == 2
  assert accounting.last(report) == Some(last())
  assert #(
      total.input,
      total.output,
      total.cache_read,
      total.cache_write,
      total.total_tokens,
    )
    == #(130, 30, 70, 15, 245)
  assert total.reasoning == Some(10)
  assert total.cache_write_1h == Some(4)
  assert total.cost.total == first().cost.total +. last().cost.total
  assert total.evidence
    == priced_evidence(
      evidence.Other,
      evidence.Complete,
      evidence.Complete,
      evidence.MixedRates,
    )
  assert accounting.combine(accounting.empty(), report) == report
  assert accounting.combine(report, accounting.empty()) == report
  assert accounting.add_usage(accounting.zero_usage(), first()) == first()
  assert accounting.add_usage(first(), accounting.zero_usage()) == first()

  // Reported subset counters are informative, never additional consumption.
  assert total.output == first().output + last().output
  assert accounting.last(report) != Some(total)
}

pub fn accounting_missing_usage_and_missing_price_remain_visible_test() {
  let missing =
    message.Usage(
      ..accounting.zero_usage(),
      evidence: evidence.unknown(evidence.Api),
    )
  let report = accounting.from_usage(first()) |> accounting.append(missing)
  assert accounting.attempts(report) == 2
  assert accounting.last(report) == Some(missing)
  assert accounting.total(report).evidence
    == priced_evidence(
      evidence.Api,
      evidence.Partial,
      evidence.Partial,
      evidence.ApiRates,
    )

  let unpriced =
    message.Usage(
      ..first(),
      cost: accounting.zero_usage().cost,
      evidence: evidence.reported(evidence.Api),
    )
  let zero_rates =
    message.Usage(
      ..unpriced,
      evidence: evidence.with_price(unpriced.evidence, evidence.ApiRates),
    )
  assert unpriced.cost == zero_rates.cost
  assert unpriced.evidence == evidence.reported(evidence.Api)
  assert zero_rates.evidence
    == priced_evidence(
      evidence.Api,
      evidence.Complete,
      evidence.Complete,
      evidence.ApiRates,
    )
  assert accounting.add_usage(first(), unpriced).evidence
    == priced_evidence(
      evidence.Api,
      evidence.Complete,
      evidence.Partial,
      evidence.ApiRates,
    )
}

// Builds the evidence of a remote observation whose estimate may cover less
// than its tokens, which the pricing constructors alone cannot spell.
fn priced_evidence(
  billing: evidence.Billing,
  tokens: evidence.Coverage,
  estimate: evidence.Coverage,
  basis: evidence.PriceBasis,
) -> evidence.Evidence {
  evidence.Remote(
    billing,
    evidence.Reported(tokens, evidence.Priced(estimate, basis)),
  )
}

pub fn accounting_details_keep_the_callers_fields_test() {
  let report = accounting.from_usage(first()) |> accounting.append(last())
  let details =
    accounting.details(report, [
      #("phase", json.String("distillation")),
      #("other", json.Int(1)),
    ])
  let assert json.Object(fields) = details
  assert list.key_find(fields, "phase") == Ok(json.String("distillation"))
  assert list.key_find(fields, "other") == Ok(json.Int(1))
  let usage_row = row(accounting.total(report), Some(details))
  assert accounting.decode_row(usage_row) == Ok(report)
  let assert Ok(restored) =
    codec.decode_usage_row(codec.encode_usage_row(usage_row))
    as "ledger row survives persistence"
  assert accounting.decode_row(restored) == Ok(report)

  assert accounting.decode_row(row(
      accounting.zero_usage(),
      Some(accounting.details(accounting.empty(), [])),
    ))
    == Ok(accounting.empty())
}

pub fn accounting_historical_row_is_an_observation_not_empty_test() {
  let historic =
    message.Usage(..first(), evidence: evidence.unknown(evidence.Other))
  let report = accounting.from_usage(historic)
  list.each(
    [None, Some(json.String("old details")), Some(json.Object([]))],
    fn(details) {
      assert accounting.decode_row(row(historic, details)) == Ok(report)
    },
  )
  assert accounting.attempts(report) == 1
  assert accounting.total(report).evidence == evidence.unknown(evidence.Other)
}

fn report_details(
  count: json.JsonValue,
  last: json.JsonValue,
) -> Option(json.JsonValue) {
  Some(
    json.Object([
      #(
        accounting.namespace,
        json.Object([
          #("version", json.Int(1)),
          #("attempt_count", count),
          #("last", last),
        ]),
      ),
    ]),
  )
}

pub fn accounting_malformed_count_final_and_evidence_fail_test() {
  let final = codec.encode_usage(last())
  let total = accounting.add_usage(first(), last())
  list.each(
    [
      report_details(json.Int(-1), final),
      report_details(json.Float(2.0), final),
      report_details(json.Int(0), final),
      report_details(json.Int(2), json.Null),
      report_details(json.Int(1), final),
      Some(json.Object([#(accounting.namespace, json.Null)])),
      Some(
        json.Object([
          #(
            accounting.namespace,
            json.Object([
              #("version", json.Int(2)),
              #("attempt_count", json.Int(2)),
              #("last", final),
            ]),
          ),
        ]),
      ),
      Some(
        json.Object([
          #(
            accounting.namespace,
            json.Object([
              #("version", json.Int(1)),
              #("attempt_count", json.Int(2)),
              #("last", final),
              #("attempts", json.Array([])),
            ]),
          ),
        ]),
      ),
    ],
    fn(details) {
      let assert Error(_) = accounting.decode_row(row(total, details))
        as "a malformed report cannot become a historical fallback"
    },
  )
  let assert Error(_) =
    accounting.decode_row(row(
      last(),
      report_details(json.Int(2), codec.encode_usage(first())),
    ))
    as "aggregate cannot be smaller than the final observation"
  let assert Error(_) =
    accounting.decode_row(row(
      message.Usage(..total, input: -1),
      Some(accounting.details(accounting.from_usage(total), [])),
    ))
    as "negative request aggregate counts cannot become consumption"
  let signed =
    message.Usage(
      ..total,
      input: -1,
      cost: message.UsageCost(..total.cost, total: -1.0),
    )
  assert accounting.decode_row(row(signed, None))
    == Ok(accounting.from_usage(signed))
  let assert Error(_) =
    accounting.decode_row(row(
      total,
      report_details(json.Int(2), codec.encode_usage(signed)),
    ))
    as "negative final attempt counts cannot become consumption"
  let assert json.Object(fields) = final as "final usage fixture has fields"
  let malformed = json.Object(list.key_set(fields, "evidence", json.Null))
  let assert Error(_) =
    accounting.decode_row(row(total, report_details(json.Int(2), malformed)))
    as "malformed final evidence is corruption"
}

// A final incomplete observation cannot be hidden by complete aggregate claims.
pub fn accounting_final_evidence_cannot_be_erased_by_details_test() {
  let observed =
    message.Usage(..last(), evidence: evidence.partial(evidence.ChatGptPlan))
  let total = accounting.add_usage(first(), last())
  let assert Error(_) =
    accounting.decode_row(row(
      total,
      report_details(json.Int(2), codec.encode_usage(observed)),
    ))
    as "aggregate evidence must include the final observation's uncertainty"

  let report = accounting.from_usage(first()) |> accounting.append(observed)
  assert accounting.decode_row(row(
      accounting.total(report),
      Some(accounting.details(report, [])),
    ))
    == Ok(report)
}

pub fn unknown_zero_is_not_a_context_measurement_but_stays_accounted_test() {
  let missing =
    message.Usage(
      ..accounting.zero_usage(),
      evidence: evidence.unknown(evidence.Api),
    )
  assert accounting.observed_usage(missing) == None
  let report = accounting.from_usage(missing)
  assert accounting.last(report) == Some(missing)
  assert accounting.total(report) == missing
  assert accounting.attempts(report) == 1
  let complete =
    message.Usage(..missing, evidence: evidence.reported(evidence.Api))
  let partial =
    message.Usage(..missing, evidence: evidence.partial(evidence.Api))
  assert accounting.observed_usage(complete) == Some(complete)
  assert accounting.observed_usage(partial) == Some(partial)
  list.each(
    [
      message.Usage(..missing, input: 1),
      message.Usage(..missing, output: 1),
      message.Usage(..missing, cache_read: 1),
      message.Usage(..missing, cache_write: 1),
      message.Usage(..missing, total_tokens: 1),
    ],
    fn(historical) {
      assert accounting.observed_usage(historical) == Some(historical)
    },
  )
}
