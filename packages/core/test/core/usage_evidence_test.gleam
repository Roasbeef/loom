//// Evidence laws distinguish missing provider data from measured zero.
//// Round trips range over observations the smart constructors can create;
//// malformed claims exercise the total persistence boundary separately.

import core/json
import core/usage_evidence as evidence
import gleam/list

pub fn evidence_identity_and_unknown_partial_laws_test() {
  let known = evidence.reported(evidence.Api)
  let missing = evidence.unknown(evidence.Api)
  let values = [
    evidence.none(),
    known,
    missing,
    evidence.partial(evidence.ChatGptPlan),
  ]
  list.each(values, fn(value) {
    assert evidence.add(evidence.none(), value) == value
    assert evidence.add(value, evidence.none()) == value
  })
  assert evidence.add(known, missing) == evidence.partial(evidence.Api)
  assert evidence.add(missing, missing) == missing
  assert evidence.add(known, known) == known
}

pub fn evidence_price_availability_and_zero_rates_test() {
  let unpriced = evidence.reported(evidence.Api)
  let priced = evidence.with_price(unpriced, evidence.ApiRates)
  assert priced
    == evidence.Remote(
      evidence.Api,
      evidence.Reported(
        evidence.Complete,
        evidence.Priced(evidence.Complete, evidence.ApiRates),
      ),
    )
  assert evidence.add(priced, unpriced)
    == evidence.Remote(
      evidence.Api,
      evidence.Reported(
        evidence.Complete,
        evidence.Priced(evidence.Partial, evidence.ApiRates),
      ),
    )
  let missing = evidence.unknown(evidence.Api)
  assert evidence.with_price(missing, evidence.ApiRates) == missing
  assert evidence.with_price(evidence.partial(evidence.Api), evidence.ApiRates)
    == evidence.Remote(
      evidence.Api,
      evidence.Reported(
        evidence.Partial,
        evidence.Priced(evidence.Partial, evidence.ApiRates),
      ),
    )
  assert evidence.with_price(evidence.none(), evidence.ApiRates)
    == evidence.none()
}

pub fn evidence_mixed_subscription_reference_basis_test() {
  let api =
    evidence.with_price(evidence.reported(evidence.Api), evidence.ApiRates)
  let plan =
    evidence.with_price(
      evidence.reported(evidence.ChatGptPlan),
      evidence.ChatGptReferenceRates,
    )
  assert evidence.add(api, plan)
    == evidence.Remote(
      evidence.Other,
      evidence.Reported(
        evidence.Complete,
        evidence.Priced(evidence.Complete, evidence.MixedRates),
      ),
    )
  let missing = evidence.unknown(evidence.ChatGptPlan)
  assert evidence.add(api, missing)
    == evidence.Remote(
      evidence.Other,
      evidence.Reported(
        evidence.Partial,
        evidence.Priced(evidence.Partial, evidence.ApiRates),
      ),
    )
}

pub fn evidence_codec_and_associative_addition_test() {
  let observations = [
    evidence.none(),
    evidence.unknown(evidence.Other),
    evidence.reported(evidence.Api),
    evidence.partial(evidence.ChatGptPlan),
    evidence.with_price(evidence.reported(evidence.Api), evidence.ApiRates),
    evidence.with_price(
      evidence.partial(evidence.ChatGptPlan),
      evidence.ChatGptReferenceRates,
    ),
  ]
  list.each(observations, fn(left) {
    assert evidence.decode(evidence.encode(left)) == Ok(left)
    list.each(observations, fn(middle) {
      assert evidence.add(left, middle) == evidence.add(middle, left)
      list.each(observations, fn(right) {
        let value = evidence.add(evidence.add(left, middle), right)
        assert value == evidence.add(left, evidence.add(middle, right))
        assert evidence.decode(evidence.encode(value)) == Ok(value)
      })
    })
  })
}

fn put(
  value: json.JsonValue,
  key: String,
  replacement: json.JsonValue,
) -> json.JsonValue {
  let assert json.Object(fields) = value as "evidence fixture is an object"
  json.Object(list.key_set(fields, key, replacement))
}

pub fn evidence_malformed_and_impossible_claims_are_corruption_test() {
  let known = evidence.encode(evidence.reported(evidence.Api))
  let estimate =
    evidence.encode(evidence.with_price(
      evidence.reported(evidence.Api),
      evidence.ApiRates,
    ))
  let estimated_cost =
    json.Object([
      #("kind", json.String("estimated")),
      #("coverage", json.String("unknown")),
      #("basis", json.String("api-rates")),
    ])
  let assert json.Object(fields) = known as "known evidence has fields"
  let corpus = [
    json.Null,
    json.Int(1),
    json.Array([]),
    put(known, "version", json.Int(2)),
    put(known, "tokens", json.String("invented")),
    put(known, "billing", json.String("no-provider")),
    put(known, "cost", json.Object([#("kind", json.String("no-expense"))])),
    put(known, "cost", estimated_cost),
    put(
      known,
      "cost",
      json.Object([
        #("kind", json.String("unavailable")),
        #("basis", json.String("api-rates")),
      ]),
    ),
    put(estimate, "tokens", json.String("unknown")),
    put(estimate, "tokens", json.String("partial")),
    json.Object(list.filter(fields, fn(field) { field.0 != "tokens" })),
    json.Object([#("tokens", json.String("complete")), ..fields]),
  ]
  list.each(corpus, fn(value) {
    let assert Error(_) = evidence.decode(value)
      as "malformed evidence cannot erase or invent coverage"
  })
}
