//// Focused wire invariants for asynchronous execution readiness.
////
//// Readiness is durable authority for later input, so its codec must reject
//// endpoint ambiguity rather than leave the host and satellite to disagree.

import core/json
import gleam/list
import runtime/async_execution

pub fn readiness_round_trips_its_idle_contract_test() {
  let readiness =
    async_execution.Readiness(
      endpoints: ["control", "review.main"],
      idle_within_ms: 30_000,
    )

  assert async_execution.decode_readiness(async_execution.encode_readiness(
      readiness,
    ))
    == Ok(readiness)
}

pub fn readiness_rejects_ambiguous_or_unbounded_endpoints_test() {
  assert !async_execution.valid_endpoints([])
  assert !async_execution.valid_endpoints(["same", "same"])
  assert !async_execution.valid_endpoints(["Uppercase"])
  assert !async_execution.valid_endpoints(["path/name"])
  assert !async_execution.valid_endpoints(list.repeat("endpoint", times: 17))
}

pub fn readiness_rejects_an_unbounded_idle_interval_test() {
  let encoded =
    json.Object([
      #("version", json.Int(1)),
      #("endpoints", json.Array([json.String("default")])),
      #("idle_within_ms", json.Int(300_001)),
    ])

  let assert Error(_) = async_execution.decode_readiness(encoded)
}

pub fn zero_idle_is_reserved_for_legacy_raw_receive_test() {
  let encoded =
    json.Object([
      #("version", json.Int(1)),
      #("endpoints", json.Array([json.String("control")])),
      #("idle_within_ms", json.Int(0)),
    ])

  let assert Error(_) = async_execution.decode_readiness(encoded)
}
