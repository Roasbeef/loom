//// Focused wire invariants for asynchronous execution readiness.
////
//// Readiness is durable authority for later input, so its codec must reject
//// endpoint ambiguity rather than leave the host and satellite to disagree.

import core/clock
import core/ids
import core/json
import gleam/list
import gleam/option.{None, Some}
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

fn launched(launch) -> async_execution.Execution {
  let #(operation, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 7))
  async_execution.Execution(
    id: "abc",
    strand: "main",
    operation:,
    step: "async/abc",
    deadline_ms: 1_000_000,
    source: "program",
    seam: "orchestration",
    phase: async_execution.Running,
    launch:,
  )
}

pub fn the_launching_call_round_trips_through_the_record_test() {
  let record =
    launched(
      Some(async_execution.Launch(step: "turn-3:tools", source_index: 2)),
    )
  assert async_execution.decode(async_execution.encode(record)) == Ok(record)
  assert async_execution.decode(async_execution.encode(launched(None)))
    == Ok(launched(None))
}

pub fn a_record_from_before_the_launch_field_reads_as_none_test() {
  let assert json.Object(fields) = async_execution.encode(launched(None))
    as "a record encodes as an object"
  let older =
    json.Object(list.filter(fields, fn(field) { field.0 != "launch" }))
  assert async_execution.decode(older) == Ok(launched(None))
}

pub fn a_damaged_launch_field_is_refused_test() {
  let assert json.Object(fields) = async_execution.encode(launched(None))
    as "a record encodes as an object"
  let damaged = fn(launch) {
    json.Object(
      list.map(fields, fn(field) {
        case field.0 {
          "launch" -> #("launch", launch)
          _ -> field
        }
      }),
    )
  }
  let assert Error(_) =
    async_execution.decode(damaged(json.Object([#("step", json.String("s"))])))
    as "a launch without its source index is refused"
  let assert Error(_) =
    async_execution.decode(
      damaged(
        json.Object([
          #("step", json.String("s")),
          #("source_index", json.Int(-1)),
        ]),
      ),
    )
    as "a negative source index is refused"
  let assert Error(_) = async_execution.decode(damaged(json.String("s")))
    as "a launch that is not an object is refused"
}
