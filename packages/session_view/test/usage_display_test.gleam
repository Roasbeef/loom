//// Display evidence is never inferred from a numeric cost. These examples
//// exercise the words shared by session bars and goal inspectors.

import core/usage_evidence
import session_view/usage_display

pub fn missing_measurement_differs_from_no_consumption_test() {
  assert usage_display.estimate(0.0, usage_evidence.none()) == "est $0.00"
  assert usage_display.estimate(0.0, usage_evidence.unknown(usage_evidence.Api))
    == "est —"
  assert usage_display.estimate(
      0.42,
      usage_evidence.reported(usage_evidence.Api),
    )
    == "est —"
}

pub fn plan_estimates_identify_reference_rates_and_partial_coverage_test() {
  let complete =
    usage_evidence.with_price(
      usage_evidence.reported(usage_evidence.ChatGptPlan),
      usage_evidence.ChatGptReferenceRates,
    )
  let partial =
    usage_evidence.add(
      complete,
      usage_evidence.unknown(usage_evidence.ChatGptPlan),
    )
  assert usage_display.estimate(0.42, complete) == "API ref est $0.42"
  assert usage_display.estimate(0.42, partial) == "API ref partial est $0.42"
}

// A row whose label says estimate drops only the marker. Unavailable cost
// still reads as a dash and proven no expense as zero.
pub fn a_figure_is_the_estimate_without_its_marker_test() {
  let complete =
    usage_evidence.with_price(
      usage_evidence.reported(usage_evidence.ChatGptPlan),
      usage_evidence.ChatGptReferenceRates,
    )
  let partial =
    usage_evidence.add(
      complete,
      usage_evidence.unknown(usage_evidence.ChatGptPlan),
    )
  assert usage_display.figure(1.0, complete) == "API ref $1.00"
  assert usage_display.figure(1.0, partial) == "API ref partial $1.00"
  assert usage_display.figure(0.0, usage_evidence.none()) == "$0.00"
  assert usage_display.figure(0.42, usage_evidence.reported(usage_evidence.Api))
    == "—"
}

pub fn money_rounds_once_to_cents_and_never_goes_negative_test() {
  assert usage_display.money(0.456) == "0.46"
  assert usage_display.money(12.0) == "12.00"
  assert usage_display.money(-1.0) == "0.00"
}

pub fn mixed_billing_estimates_keep_their_rate_basis_test() {
  let api =
    usage_evidence.with_price(
      usage_evidence.reported(usage_evidence.Api),
      usage_evidence.ApiRates,
    )
  let plan =
    usage_evidence.with_price(
      usage_evidence.reported(usage_evidence.ChatGptPlan),
      usage_evidence.ChatGptReferenceRates,
    )
  assert usage_display.estimate(0.42, usage_evidence.add(api, plan))
    == "mixed rates est $0.42"
}
