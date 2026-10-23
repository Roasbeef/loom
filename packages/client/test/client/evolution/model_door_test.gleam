//// Model requests can lower budgets but cannot author an independent scorer.

import client/evolution/model_door
import client/evolution/rollout
import core/json
import gleam/result
import gleeunit/should

pub fn admitted_task_set_is_required_and_requests_cannot_raise_native_ceilings_test() {
  model_door.evaluation_request(json.Object([]))
  |> result.is_error
  |> should.be_true
  model_door.evaluation_request(
    json.Object([#("taskset_id", json.String("admitted"))]),
  )
  |> should.equal(
    Ok(#("admitted", rollout.Limits(20, 20, 1_000_000, 2.0, 65_536, 120_000))),
  )
  let fields = [
    #("trials", json.Int(2)),
    #("turns", json.Int(4)),
    #("tokens", json.Int(1000)),
    #("dollars", json.Float(0.25)),
    #("output_bytes", json.Int(2048)),
    #("wall_ms", json.Int(5000)),
  ]
  let limits = json.Object(fields)
  model_door.evaluation_request(
    json.Object([
      #("taskset_id", json.String("admitted")),
      #("limits", limits),
    ]),
  )
  |> should.equal(
    Ok(#("admitted", rollout.Limits(2, 4, 1000, 0.25, 2048, 5000))),
  )
  model_door.evaluation_request(
    json.Object([
      #("taskset_id", json.String("admitted")),
      #(
        "limits",
        json.Object([#("scorer", json.String("candidate command")), ..fields]),
      ),
    ]),
  )
  |> result.is_error
  |> should.be_true
}
