//// Model requests can lower budgets but cannot author an independent scorer.

import cap/evolution
import client/codemode
import client/evolution/model_door
import client/evolution/rollout
import core/json
import gleam/list
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
    Ok(#(
      "admitted",
      rollout.Limits(20, 100, 1_000_000, 2.0, 65_536, 480_000, 1),
    )),
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
    Ok(#("admitted", rollout.Limits(2, 4, 1000, 0.25, 2048, 5000, 1))),
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

// `samples` is the one optional member: absent means one, the door caps it
// at three and says so, and it cannot carry anything but a counting integer.
pub fn samples_default_to_one_and_the_door_names_its_cap_test() {
  let fields = [
    #("trials", json.Int(6)),
    #("turns", json.Int(4)),
    #("tokens", json.Int(1000)),
    #("dollars", json.Float(0.25)),
    #("output_bytes", json.Int(2048)),
    #("wall_ms", json.Int(5000)),
  ]
  let request = fn(samples: List(#(String, json.JsonValue))) {
    model_door.evaluation_request(
      json.Object([
        #("taskset_id", json.String("admitted")),
        #("limits", json.Object(list.append(fields, samples))),
      ]),
    )
  }
  assert request([#("samples", json.Int(3))])
    == Ok(#("admitted", rollout.Limits(6, 4, 1000, 0.25, 2048, 5000, 3)))
  assert request([#("samples", json.Null)])
    == Ok(#("admitted", rollout.Limits(6, 4, 1000, 0.25, 2048, 5000, 1)))
  assert request([#("samples", json.Int(4))])
    == Error("Bounds: samples must be from one to three")
  assert request([#("samples", json.Int(0))])
    == Error("Bounds: samples must be from one to three")
  assert request([#("samples", json.String("3"))])
    == Error("Bounds: samples requires an integer")
}

// The exact shape `cap/evolution.compare` puts on the wire, seven members
// with `samples` last: a program asking for two samples is decoded as two,
// and one asking for four meets the door's cap of three.
pub fn cap_limits_carry_samples_test() {
  let request = fn(samples: Int) {
    model_door.evaluation_request(
      json.Object([
        #("taskset_id", json.String("admitted")),
        #("limits", native(100, 480_000, samples)),
      ]),
    )
  }
  assert request(2)
    == Ok(#(
      "admitted",
      rollout.Limits(20, 100, 1_000_000, 2.0, 65_536, 480_000, 2),
    ))
  assert request(4) == Error("Bounds: samples must be from one to three")
}

// The turn ceiling is the evaluator's own and the wall ceiling sits under the
// code-mode call that hosts the compare (protocol-change/100): a hundred
// turns and eight minutes are admitted, one more of either is refused, and
// the dollar ceiling that bounds the spend did not move.
pub fn turn_and_wall_ceilings_match_the_evaluator_and_dollars_do_not_move_test() {
  let request = fn(limits: json.JsonValue) {
    model_door.evaluation_request(
      json.Object([
        #("taskset_id", json.String("admitted")),
        #("limits", limits),
      ]),
    )
  }
  assert request(native(100, 480_000, 1))
    == Ok(#(
      "admitted",
      rollout.Limits(20, 100, 1_000_000, 2.0, 65_536, 480_000, 1),
    ))
  let over = "Bounds: rollout request exceeds native model-door ceilings"
  assert request(native(101, 480_000, 1)) == Error(over)
  assert request(native(100, 480_001, 1)) == Error(over)
  let assert json.Object(fields) = native(100, 480_000, 1)
  let dearer = json.Object(list.key_set(fields, "dollars", json.Float(2.01)))
  assert request(dearer) == Error(over)
}

fn native(turns: Int, wall_ms: Int, samples: Int) -> json.JsonValue {
  json.Object([
    #("trials", json.Int(20)),
    #("turns", json.Int(turns)),
    #("tokens", json.Int(1_000_000)),
    #("dollars", json.Float(2.0)),
    #("output_bytes", json.Int(65_536)),
    #("wall_ms", json.Int(wall_ms)),
    #("samples", json.Int(samples)),
  ])
}

// The compare runs synchronously inside one `ServedHere` capability call,
// whose worker is killed at the code-mode call timeout with the fold
// half-done. The door's wall ceiling plus the margin the fold needs after
// its wall (retire, score, cleanup, write) must therefore fit inside that
// timeout; this reads both constants so a change to either breaks the build.
pub fn the_wall_ceiling_and_its_margin_fit_inside_the_code_mode_call_timeout_test() {
  assert model_door.wall_ceiling_ms + model_door.wall_margin_ms
    <= codemode.default_call_timeout_ms
    as "the compare's wall and its teardown margin must fit one capability call"
  assert model_door.wall_margin_ms >= 60_000
    as "the margin holds at least a minute for retirement and scoring"
}

// The ceilings are literals in two places, the stub and the door; the stub's
// `native_limits()` is exactly what the door admits with nothing lowered.
pub fn the_stubs_native_limits_are_admitted_by_the_door_test() {
  let native = evolution.native_limits()
  let request =
    model_door.evaluation_request(
      json.Object([
        #("taskset_id", json.String("admitted")),
        #(
          "limits",
          json.Object([
            #("trials", json.Int(native.trials)),
            #("turns", json.Int(native.turns)),
            #("tokens", json.Int(native.tokens)),
            #("dollars", json.Float(native.dollars)),
            #("output_bytes", json.Int(native.output_bytes)),
            #("wall_ms", json.Int(native.wall_ms)),
            #("samples", json.Int(native.samples)),
          ]),
        ),
      ]),
    )
  assert request
    == Ok(#(
      "admitted",
      rollout.Limits(
        native.trials,
        native.turns,
        native.tokens,
        native.dollars,
        native.output_bytes,
        native.wall_ms,
        native.samples,
      ),
    ))
  assert native.turns == model_door.turns_ceiling
    && native.wall_ms == model_door.wall_ceiling_ms
    as "the stub names the door's own ceilings"
}
